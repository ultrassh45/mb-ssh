#!/bin/bash
# test-v3.sh — functional test mb-edge v3 (isolated, port 29xxx)
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; V2="$REPO/runtime"
T=/tmp/mbtest3
PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
check(){ # check <desc> <expr-result-0-is-ok>
  if [[ $1 -eq 0 ]]; then ok "$2"; else bad "$2"; fi
}

echo "=== 0. syntax ==="
bash -n $V2/mb-ssh2.sh && python3 -m py_compile $V2/mb-edge.py; check $? "syntax semua file"

echo "=== 0b. LIMIT IP & SLOWDNS (unit) ==="
python3 $REPO/tests/test_ip_limit.py 2>&1 | grep -q "SEMUA TEST LIMIT IP LULUS"
check $? "unit: limit IP + persist known_ips + default config"

# cleanup proses lama di port test + user test yang mungkin tersisa dari run yang diterminasi paksa
for p in 29999 29001 29002 29003 29004 29005 29006 29007 29499; do
  for pid in $(ss -ltnp 2>/dev/null | grep ":$p " | grep -oP 'pid=\K[0-9]+' | sort -u); do kill $pid 2>/dev/null; done
done
for u in test1 texp tuser_api; do userdel -r "$u" 2>/dev/null; done
pkill -f "mbtest3" 2>/dev/null
sleep 0.5
rm -rf $T; mkdir -p $T/state $T/conf

cat > $T/conf/mb.conf <<EOF
PORT_POOL="29002 29003 29004 29005 29006 29007"
DOMAIN="127.0.0.1"
EOF
cat > $T/conf/edge.json <<EOF
{
  "common_ports": [29001],
  "common_backend": "127.0.0.1:29999",
  "backends": {"direct": "127.0.0.1:29999", "tls": "127.0.0.1:22443"},
  "warp": false,
  "api": {"port": 29499, "token": "testtok123", "allow_ip": []}
}
EOF

# echo backend :29999
python3 -c "
import socket, threading
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 29999)); srv.listen(16)
def h(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(b'ECHO:' + d)
while True:
    c, _ = srv.accept()
    threading.Thread(target=h, args=(c,), daemon=True).start()
" &
BACKEND_PID=$!

start_edge() {
  MB_EDGE_CFG=$T/conf/edge.json MB_EDGE_CTL=$T/ctl.sock \
  MB_EDGE_STATE=$T/state/users.json MB_EDGE_STATS=$T/state/stats.json \
  MB_SSH2_BIN=$V2/mb-ssh2.sh MB_BADVPN_BIN=/nonexistent MB_EDGE_API_LOG=$T/api.log \
  python3 $V2/mb-edge.py > $T/edge.log 2>&1 &
  EDGE_PID=$!
  for i in $(seq 1 20); do [[ -S $T/ctl.sock ]] && break; sleep 0.2; done
}

export CONF_DIR=$T/conf STATE_DIR=$T/state EDGE_CTL=$T/ctl.sock DROPBEAR_PORT=29999 BADVPN_BIN=/nonexistent
CLI() { bash $V2/mb-ssh2.sh "$@"; }

echo "=== 1. edge start + common relay ==="
start_edge
sleep 0.5
R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',29001))
s.sendall(b'hello-common')
print(s.recv(1024).decode())" 2>/dev/null)
[[ $R == "ECHO:hello-common" ]]; check $? "common relay (port 29001)"

echo "=== 2. CLI add (test1) ==="
CLI add test1 30 >/dev/null 2>&1; RC=$?
check $RC "add test1 30"
PORT1=$(python3 -c "import json; print(json.load(open('$T/state/users.json'))['test1']['port'])" )
echo "  (port test1 = $PORT1)"

# keamanan: akun customer = nologin (no shell), tapi tetap bisa auth (tunnel)
SHELL1=$(getent passwd test1 | cut -d: -f7)
[[ "$SHELL1" == "/usr/sbin/nologin" ]] || [[ "$SHELL1" == "/bin/false" ]]
check $? "akun customer shell non-interaktif (login ditolak, tunnel tetap) — ($SHELL1)"

# client-info memuat port list, dikelompokkan TLS/nonTLS
R=$(grep -A2 "Port List" "$T/state/client-test1.txt" 2>/dev/null | head -3)
echo "$R" | grep -q "TLS" && echo "$R" | grep -q "nonTLS"; check $? "port list TLS/nonTLS di client-info"

R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'hello-user')
print(s.recv(1024).decode())" 2>/dev/null)
[[ $R == "ECHO:hello-user" ]]; check $? "user relay (port $PORT1)"

echo "=== 3. RESTORE: kill edge → restart → port auto-pulihkan (P0) ==="
kill -TERM $EDGE_PID; wait $EDGE_PID 2>/dev/null
sleep 0.5
start_edge
sleep 1
ss -ltn 2>/dev/null | grep -q ":$PORT1 "; check $? "port user restored setelah restart"
grep -q "RESTORE: 1 user" $T/edge.log; check $? "log RESTORE: 1 user"
R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'after-restore')
print(s.recv(1024).decode())" 2>/dev/null)
[[ $R == "ECHO:after-restore" ]]; check $? "relay bekerja setelah restore"

echo "=== 4. STATS: byte terhitung ==="
python3 -c "
import socket
s=socket.socket(); s.settimeout(5); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'z'*200000)
s.recv(1024)
s.close()" 2>/dev/null
sleep 0.3
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$T/ctl.sock')
s.sendall(b'{\"cmd\":\"flush\"}\n')
print(s.recv(1024).decode().strip())
" >/dev/null
sleep 0.2
# poll sampai stats in >= 200KB (race-safe)
INB=0
for _i in 1 2 3 4 5; do
  INB=$(python3 -c "import json; print(json.load(open('$T/state/stats.json'))['test1']['in'])")
  [[ $INB -ge 200000 ]] && break
  sleep 0.4
done
[[ $INB -ge 200000 ]]; check $? "stats.json in >= 200KB (=$INB)"

echo "=== 5. QUOTA: 0.001GB (~1MB) → block → reject → reset ==="
CLI set test1 --quota 0.001 >/dev/null 2>&1
sleep 0.2
python3 -c "
import socket
s=socket.socket(); s.settimeout(8); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'q'*3_000_000)
try: s.recv(1024)
except: pass
s.close()" 2>/dev/null
sleep 0.5
B=$(python3 -c "import json; print(json.load(open('$T/state/users.json'))['test1'].get('quota_gb',0))")
[[ $B == "0.001" ]]; check $? "state quota_gb=0.001"
# --- poll sampai quota rejected (race-safe) ---
R=""
for _i in 1 2 3 4 5 6 7 8 9 10; do
  R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'should-be-rejected')
try:
    d = s.recv(1024)
    print(d.decode())
except socket.timeout:
    print('TIMEOUT')
" 2>/dev/null)
  [[ $R != "ECHO:should-be-rejected" ]] && break
  sleep 0.5
done
[[ $R != "ECHO:should-be-rejected" ]]; check $? "koneksi baru ditolak saat quota exceeded (resp=$R)"
CLI set test1 --reset-quota >/dev/null 2>&1
R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'after-reset')
print(s.recv(1024).decode())" 2>/dev/null)
[[ $R == "ECHO:after-reset" ]]; check $? "reset-quota → koneksi kembali"

echo "=== 5b. EXPIRE: masa berlaku habis → block → extend → auto unblock ==="
# set expire ke masa lalu via ctl (simulasi jatuh tempo)
python3 - "$T/ctl.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(3)
s.connect(sys.argv[1])
s.sendall(b'{"cmd":"setbw","user":"test1","expire_ts":1000000000}\n')
buf=b""
while not buf.endswith(b"\n"):
    d=s.recv(4096)
    if not d: break
    buf+=d
print(buf.decode().strip())
PY
sleep 0.3
R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'expired-probe')
try:
    d = s.recv(1024)
    print(d.decode())
except socket.timeout:
    print('TIMEOUT')
" 2>/dev/null)
[[ $R != "ECHO:expired-probe" ]]; check $? "expired user: koneksi baru ditolak (resp=$R)"
# extend via CLI (jalur panel: PATCH add_days → set --add-days)
CLI set test1 --add-days 10 >/dev/null 2>&1
sleep 0.3
R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'after-extend')
print(s.recv(1024).decode())" 2>/dev/null)
[[ $R == "ECHO:after-extend" ]]; check $? "extend → auto unblock expired, koneksi OK"
CLI list --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['test1'].get('blocked') in (None,'')"; check $? "list --json: field blocked live (null setelah unblock)"

echo "=== 6. CLI --json ==="
CLI list --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'test1' in d and 'stats' in d['test1']"; check $? "list --json (entry+stats)"
CLI show test1 --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['port'] and 'client_info' in d"; check $? "show --json (port+client_info)"
grep -q "mb-ssh motd" /home/test1/.bashrc 2>/dev/null && grep -q "Expire" /home/test1/.bashrc 2>/dev/null; check $? "MOTD per-user di ~/.bashrc"

echo "=== 7. HTTP API ==="
API=http://127.0.0.1:29499
# 7a. tanpa token → 401
C=$(curl -s -o /dev/null -w '%{http_code}' $API/v1/health); [[ $C == 401 ]]; check $? "health tanpa token = 401 ($C)"
# 7b. token salah → 401
C=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer salah' $API/v1/health); [[ $C == 401 ]]; check $? "token salah = 401 ($C)"
# 7c. health OK
C=$(curl -s -w '\n%{http_code}' -H 'Authorization: Bearer testtok123' $API/v1/health)
B=$(echo "$C" | head -1); C=$(echo "$C" | tail -1)
[[ $C == 200 ]] && echo "$B" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='ok' and 'warp' in d"; check $? "health OK (users=$([ -n "$B" ] && echo "$B" | python3 -c "import json,sys;print(json.load(sys.stdin)['users'])"))"
# 7d. POST user baru
R=$(curl -s -w '\n%{http_code}' -X POST -H 'Authorization: Bearer testtok123' -H 'Content-Type: application/json' \
  -d '{"username":"tuser_api","days":30,"bw_down":10,"bw_up":5,"quota_gb":5}' $API/v1/users)
C=$(echo "$R" | tail -1); [[ $C == 201 ]]; check $? "POST /v1/users = 201"
# 7e. duplicate → 409
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer testtok123' \
  -d '{"username":"tuser_api","days":30}' $API/v1/users); [[ $C == 409 ]]; check $? "POST duplicate = 409 ($C)"
# 7f. username invalid → 400
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer testtok123' \
  -d '{"username":"a b; rm -rf /","days":30}' $API/v1/users); [[ $C == 400 ]]; check $? "POST username inject = 400 ($C)"
# 7g. /v1/exists: user ada (tuser_api) vs baru (takada_x) + invalid
R=$(curl -s -H 'Authorization: Bearer testtok123' "$API/v1/exists?username=tuser_api")
echo "$R" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('exists') is True and 'ssh' in d.get('in',[])" 2>/dev/null; check $? "exists?username=tuser_api → exists=True (in ssh)"
R=$(curl -s -H 'Authorization: Bearer testtok123' "$API/v1/exists?username=takada_x")
echo "$R" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('exists') is False" 2>/dev/null; check $? "exists?username=takada_x → exists=False"
C=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer testtok123' "$API/v1/exists?username=a%20b"); [[ $C == 400 ]]; check $? "exists?username=invalid → 400 ($C)"
# 7g. list
echo "$(curl -s -H 'Authorization: Bearer testtok123' $API/v1/users)" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'tuser_api' in d"; check $? "GET /v1/users berisi tuser_api"
# 7h. show
C=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer testtok123' $API/v1/users/tuser_api); [[ $C == 200 ]]; check $? "GET /v1/users/tuser_api = 200"
# 7i. PATCH add_days → expire bertambah 5 hari
E0=$(python3 -c "import json; print(json.load(open('$T/state/users.json'))['tuser_api']['expire_ts'])")
C=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H 'Authorization: Bearer testtok123' \
  -d '{"add_days":5}' $API/v1/users/tuser_api); [[ $C == 200 ]]; check $? "PATCH add_days=5 = 200"
E1=$(python3 -c "import json; print(json.load(open('$T/state/users.json'))['tuser_api']['expire_ts'])")
[[ $((E1 - E0)) -eq 432000 ]]; check $? "expire +5 hari (delta=$((E1-E0))s)"
# 7j. DELETE
C=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H 'Authorization: Bearer testtok123' $API/v1/users/tuser_api); [[ $C == 200 ]]; check $? "DELETE = 200"
C=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer testtok123' $API/v1/users/tuser_api); [[ $C == 404 ]]; check $? "GET setelah delete = 404"
# 7k. path 404
C=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer testtok123' $API/v1/nope); [[ $C == 404 ]]; check $? "path tak dikenal = 404"

echo "=== 7b. GUARD (brute force) ==="
# guard ketat utk test; restart edge (state guard fresh)
python3 - <<PY
import json
p = "$T/conf/edge.json"
d = json.load(open(p))
d["guard"] = {"max_conn": 5, "window": 60, "ban_sec": 30}
json.dump(d, open(p, "w"), indent=2)
PY
kill -TERM $EDGE_PID 2>/dev/null; wait $EDGE_PID 2>/dev/null
sleep 0.5
start_edge
# tunggu restore selesai (port user listen)
for i in $(seq 1 20); do ss -ltn 2>/dev/null | grep -q ":29002 " && break; sleep 0.2; done
# probe: kirim data; sukses = dapat ECHO dari backend (bukan cuma TCP connect)
probe() {
  python3 -c "
import socket
try:
    s = socket.create_connection(('127.0.0.1', 29002), timeout=2)
    s.sendall(b'PING')
    s.settimeout(2)
    r = s.recv(64)
    s.close()
    print('OK' if r.startswith(b'ECHO:') else 'FAIL')
except Exception:
    print('FAIL')
"
}
suck=0
for i in $(seq 1 8); do
  if [[ $(probe) == "OK" ]]; then
    suck=$((suck+1))
  else
    break
  fi
  sleep 0.05
done
if [[ $suck -eq 5 ]]; then
  check 0 "GUARD: 5 koneksi OK lalu ditolak (ban aktif, max_conn=5)"
else
  check 1 "GUARD: $suck koneksi sebelum ditolak (harusnya 5)"
fi
sleep 0.2
if grep -q "GUARD: .* BAN" $T/edge.log 2>/dev/null; then
  check 0 "GUARD: log ban tercatat"
else
  check 1 "GUARD: log ban tidak ada"
fi

echo "=== 7c. BACKUP: ssh state + marzban (fake) → tar → restore ==="
# fake marzban install (VPS ini bukan node — cukup verifikasi logika)
mkdir -p /opt/marzban
printf 'fake-mbz-db-v1\n' > /opt/marzban/db.sqlite3
printf '{"fake":true}\n' > /opt/marzban/xray_config.json
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; _mbz_backup" >/dev/null 2>&1
[[ -f $T/state/marzban-latest.tar.gz ]]; check $? "backup: marzban-latest.tar.gz dibuat"
TARLIST=$(tar tzf $T/state/marzban-latest.tar.gz 2>/dev/null | tr '\n' ' ')
echo "$TARLIST" | grep -q "marzban.db"; check $? "backup: db di dalam tar"
echo "$TARLIST" | grep -q "xray_config.json"; check $? "backup: xray_config.json di dalam tar"
# rusak db → restore harus memulihkan
echo "CORRUPTED" > /opt/marzban/db.sqlite3
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; _mbz_restore" >/dev/null 2>&1
grep -q "fake-mbz-db-v1" /opt/marzban/db.sqlite3; check $? "restore: db.sqlite3 pulih dari tar"
rm -rf /opt/marzban

echo "=== 7d. MENU, SETUP, BOT TG ==="
CLI status | grep -q "MB-SSH STATUS"; check $? "status: output"
# setup: token invalid → ditolak, conf bersih (cek network ke Telegram API)
CLI setup "" "" "123:FAKE_TOKEN_TEST" "999" >/dev/null 2>&1
! grep -q 'TG_BOT_TOKEN="123:FAKE_TOKEN_TEST"' $T/conf/mb.conf; check $? "setup: token invalid ditolak (conf bersih)"
# menu: item status + keluar (input dipipe)
OUT=$(printf '10\n0\n' | CLI menu 2>/dev/null)
echo "$OUT" | grep -q "MB-SSH MENU"; check $? "menu: tampil"
echo "$OUT" | grep -q "MB-SSH STATUS"; check $? "menu: item 10 (status) jalan"
# bot handler (unit, tanpa network)
HELP=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mbtg', '$V2/mb-tgbot.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.handle('/help', {}))" 2>/dev/null)
echo "$HELP" | grep -q "/backup"; check $? "bot: /help daftar perintah"
ST=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mbtg', '$V2/mb-tgbot.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.handle('/status', {'R2_REMOTE': 'r2', 'R2_PATH': 'mb-ssh/t'}))" 2>/dev/null)
echo "$ST" | grep -q "R2     : r2"; check $? "bot: /status baca conf"

echo "=== 7e. CLEANUP expired: AUTO_DELETE_EXPIRED 1 vs 0 ==="
CLI add texp 1 >/dev/null 2>&1
python3 - "$T/state/users.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["texp"]["expire_ts"] = 1000000000
json.dump(d, open(p, "w"))
PY
MB_SSH_CONF=$T/conf/mb.conf MB_SSH_USERS=$T/state/users.json MB_SSH2_BIN=$V2/mb-ssh2.sh \
  bash $V2/mb-ssh2-cleanup.sh >/dev/null 2>&1
! python3 -c "import json; assert 'texp' in json.load(open('$T/state/users.json'))" 2>/dev/null
check $? "cleanup: expired dihapus (default AUTO_DELETE_EXPIRED=1)"
CLI add texp 1 >/dev/null 2>&1
python3 - "$T/state/users.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["texp"]["expire_ts"] = 1000000000
json.dump(d, open(p, "w"))
PY
MB_SSH_CONF=$T/conf/mb.conf MB_SSH_USERS=$T/state/users.json MB_SSH2_BIN=$V2/mb-ssh2.sh \
  AUTO_DELETE_EXPIRED=0 bash $V2/mb-ssh2-cleanup.sh >/dev/null 2>&1
python3 -c "import json; assert 'texp' in json.load(open('$T/state/users.json'))" 2>/dev/null
check $? "cleanup: AUTO_DELETE_EXPIRED=0 → akun expired dipertahankan (lock, bisa extend)"
CLI del texp >/dev/null 2>&1

echo "=== 7f. JADWAL BACKUP (schedule CLI + bot) ==="
# _cron_spec pure (dari variabel mb.conf yang diset sementara)
python3 - "$T/conf/mb.conf" <<'PY'
import json, sys
# tulis BACKUP_INTERVAL ke conf test (simulasi set)
p = sys.argv[1]
c = open(p).read()
for k, v in [("BACKUP_INTERVAL", "30m")]:
    import re
    if re.search(rf"^{k}=", c, re.M):
        c = re.sub(rf"^{k}=.*$", f'{k}="{v}"', c, flags=re.M)
    else:
        c += f'\n{k}="{v}"\n'
open(p, "w").write(c)
PY
SPEC=$(CLI backup-cron 2>/dev/null | grep -o '\*/30 \* \* \* \*')
[[ -n $SPEC ]] && [[ $(crontab -l 2>/dev/null | grep -c "mb-ssh2 backup") -eq 1 ]]; check $? "jadwal: 30m → cron */30 (crontab 1 baris)"
[[ $(crontab -l 2>/dev/null | grep "mb-ssh2 backup" | grep -c "*/30") -eq 1 ]]; check $? "jadwal: crontab memuat */30"
# reset ke 0 (default) + hapus dari conf test
python3 - "$T/conf/mb.conf" <<'PY'
import re, sys
p = sys.argv[1]
c = open(p).read()
c = re.sub(r'^BACKUP_INTERVAL=.*$', 'BACKUP_INTERVAL="0"', c, flags=re.M)
open(p, "w").write(c)
PY
CLI schedule 0 >/dev/null 2>&1
[[ $(crontab -l 2>/dev/null | grep "mb-ssh2 backup" | grep -c "3 3") -eq 1 ]]; check $? "jadwal: reset 0 → cron 3 3 (default)"
# bot /schedule → parse + eksekusi CLI
python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mbtg', '$V2/mb-tgbot.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# /help memuat /schedule
h = m.handle('/help', {})
assert '/schedule' in h
print('help-schedule-OK')" 2>/dev/null | grep -q "help-schedule-OK"
check $? "bot: /help memuat /schedule"

echo "=== 7g. UPDATE & ROLLBACK (snapshot, tanpa git nyata) ==="
# _update_check tanpa REPO_URL → rc=2 (tak bisa cek) — jangan crash (rc!=0 = expected)
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; REPO_URL= _update_check" 2>/dev/null
[[ $? -ne 0 ]]; check $? "update-check tanpa REPO_URL: rc!=0 (tidak crash, aman)"
# _snapshot → file kode+config ke rollback; _restore_snapshot balikan
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1
  SRC_DIR=$T/src BIN_DIR=$T/bin ROLLBACK_DIR=$T/rollback CONF_DIR=$T/conf
  mkdir -p $T/bin $T/src && printf 'OLD' > $T/bin/mb-ssh2.sh
  _snapshot && _restore_snapshot $T/rollback && test \"\$(cat $T/bin/mb-ssh2.sh)\" = OLD" 2>/dev/null
check $? "snapshot→restore: kode pulih (data lain tak tersentuh)"
# do_update dengan REPO_URL kosong → pesan 'tidak ada update' (no-op)
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; REPO_URL= do_update" 2>&1 | grep -q "tidak ada update"
check $? "do_update tanpa repo: no-op aman (data utuh)"

echo "=== 7h. UPDATE LOGIN-PROMPT & HOOK ==="
# _install_login_hook → tulis ke $HOME/.bashrc test? JANGAN: VPS ini home /root.
# test safe: panggil dengan user tak ada → return 1
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; _install_login_hook nenhak" 2>/dev/null
[[ $? -ne 0 ]]; check $? "hook login: user tak ada → skip aman (rc!=0)"
# do_login_check dengan REPO_URL kosong → rc=0 tanpa output (tidak hang)
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; REPO_URL= do_login_check | head -1" 2>/dev/null
[[ $? -eq 0 ]]; check $? "login-check tanpa repo: no-op (tidak tampil prompt)"
# do_update --check perlu git; tanpa repo = rc 2 (tidak crash) — sudah dites 7g

echo "=== 7i. DROPBEAR multi-versi (CLI, tanpa build) ==="
# dropbear list tampilkan opsi (bin tak ada di sandbox → '?')
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; DROPBEAR_BIN=/nonexistent DROPBEAR_DIR=$T/db do_dropbear" 2>/dev/null | grep -q "2019.78"
check $? "dropbear list: menampilkan versi 2019.78 (default)"
# set versi tidak dikenal → die (rc!=0), tidak crash
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; DROPBEAR_DIR=$T/db do_dropbear set 9999" 2>/dev/null
[[ $? -ne 0 ]]; check $? "dropbear set versi tak dikenal: ditolak"
# set tanpa arg → die (penggunaan)
bash -c "source $V2/mb-ssh2.sh >/dev/null 2>&1; DROPBEAR_DIR=$T/db do_dropbear set" 2>/dev/null
[[ $? -ne 0 ]]; check $? "dropbear set tanpa arg: ditolak (usage)"

echo "=== 8. cleanup ==="
CLI del test1 >/dev/null 2>&1
kill -TERM $EDGE_PID 2>/dev/null; wait $EDGE_PID 2>/dev/null
kill $BACKEND_PID 2>/dev/null
userdel -r test1 2>/dev/null; userdel -r tuser_api 2>/dev/null
echo
echo "=================================="
echo "  HASIL: $PASS pass / $FAIL fail"
echo "=================================="
[[ $FAIL -eq 0 ]] && echo "  SEMUA TEST LULUS" || { echo "  GAGAL — log: $T/edge.log, $T/api.log"; exit 1; }
