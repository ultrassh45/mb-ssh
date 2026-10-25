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

# cleanup proses lama di port test
for p in 29999 29001 29002 29003 29499; do
  for pid in $(ss -ltnp 2>/dev/null | grep ":$p " | grep -oP 'pid=\K[0-9]+' | sort -u); do kill $pid 2>/dev/null; done
done
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
PORT1=$(python3 -c "import json; print(json.load(open('$T/state/users.json'))['test1']['port'])")
echo "  (port test1 = $PORT1)"

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
INB=$(python3 -c "import json; print(json.load(open('$T/state/stats.json'))['test1']['in'])")
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
R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'should-be-rejected')
try:
    d = s.recv(1024)
    print(d.decode())
except socket.timeout:
    print('TIMEOUT')
" 2>/dev/null)
[[ $R != "ECHO:should-be-rejected" ]]; check $? "koneksi baru ditolak saat quota exceeded (resp=$R)"
CLI set test1 --reset-quota >/dev/null 2>&1
R=$(python3 -c "
import socket
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$PORT1))
s.sendall(b'after-reset')
print(s.recv(1024).decode())" 2>/dev/null)
[[ $R == "ECHO:after-reset" ]]; check $? "reset-quota → koneksi kembali"

echo "=== 6. CLI --json ==="
CLI list --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'test1' in d and 'stats' in d['test1']"; check $? "list --json (entry+stats)"
CLI show test1 --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['port'] and 'client_info' in d"; check $? "show --json (port+client_info)"

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
