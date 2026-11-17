#!/bin/bash
# mb-ssh v2 — SSH product manager (standalone, tidak coupled Marzban)
# Per-user: akun SSH (dropbear) + port CF dedicated + bandwidth limit +
#           udpgw opsional + WARP opsional
#
#   mb-ssh2 add <user> [days] [--udp] [--bw D/U] [--backend direct|tls] [--warp] [--quota GB]
#   mb-ssh2 del <user>
#   mb-ssh2 set <user> [days] [--bw D/U] [--add-days N] [--quota GB] [--unblock] [--reset-quota] [--warp|--no-warp]
#   mb-ssh2 list [--json]
#   mb-ssh2 show <user> [--json]
#   mb-ssh2 backup / restore   (rclone ke R2: R2_REMOTE + R2_PATH di mb.conf)
#   mb-ssh2 setup              (wizard: set R2 + bot Telegram, tulis mb.conf, enable svc)
#   mb-ssh2 schedule 30 m      (jadwal backup otomatis: 30 m / 6 j / 0 = harian 03:03)
#   mb-ssh2 menu               (menu interaktif bernomor 0-11)
#   mb-ssh2 edge-list / edge-add / edge-remove  (raw edge control)
#   mb-ssh2 apikey [--reset]          → lihat / reset API token edge (SSH)
#   mb-ssh2 marzban-token [--verify]  → dapatkan JWT API Marzban (fresh login)
#
# Bot Telegram (set via setup): /backup /restore /status /help
#
# Config: /etc/mb-ssh2/edge.json + /etc/mb-ssh2/mb.conf
# State : /var/lib/mb-ssh/users.json

set -u

CONF_DIR="${CONF_DIR:-/etc/mb-ssh2}"
CONF="$CONF_DIR/mb.conf"
[[ -f $CONF ]] && source "$CONF"

EDGE_CFG="${EDGE_CFG:-$CONF_DIR/edge.json}"
EDGE_CTL="${EDGE_CTL:-/run/mb-ssh/edge.sock}"
STATE_DIR="${STATE_DIR:-/var/lib/mb-ssh}"
USERS_JSON="$STATE_DIR/users.json"
STATS_JSON="$STATE_DIR/stats.json"
R2_REMOTE="${R2_REMOTE:-}"
R2_PATH="${R2_PATH:-mb-ssh/$(hostname)}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"
SRC_DIR="${SRC_DIR:-/root/mb-ssh}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
ROLLBACK_DIR="${ROLLBACK_DIR:-$STATE_DIR/rollback}"
UPDATE_CACHE="${UPDATE_CACHE:-/run/mb-ssh/update-available.txt}"
DROPBEAR_DIR="${DROPBEAR_DIR:-/opt/dropbear}"
DROPBEAR_DEFAULT="${DROPBEAR_DEFAULT:-2019.78}"
BADVPN_BIN="${BADVPN_BIN:-/usr/local/bin/badvpn-udpgw}"
# Model B (shared): daftar port UDPGW yang dipakai BERSAMA semua user.
# Di-set install/06-udpgw-shared.sh ke mb.conf; fallback ke pola autoscript.
UDPGW_SHARED_PORTS="${UDPGW_SHARED_PORTS:-7100 7200 7300 7400 7500 7600}"
DROPBEAR_PORT="${DROPBEAR_PORT:-22022}"
STUNNEL_PORT="${STUNNEL_PORT:-22443}"
WARP_IF="${WARP_IF:-warp}"
NODE_IP="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
DOMAIN="${DOMAIN:-$NODE_IP}"
SUPPORT="${SUPPORT:-}"

mkdir -p "$STATE_DIR"
[[ -f $USERS_JSON ]] || echo '{}' > "$USERS_JSON"

log() { echo "[mb-ssh2 $(date '+%F %T')] $*"; }
die() { echo "[mb-ssh2] ERROR: $*" >&2; exit 1; }

# pool port CF (alternate; 80/443 = Marzban, 22 = admin)
PORT_POOL="${PORT_POOL:-443 80 8080 8880 2052 2082 2086 2095 2053 2083 2087 2096 8443}"

# ---------- edge control client ----------
edge_ctl() { # edge_ctl <json>
  python3 - "$EDGE_CTL" "$1" <<'PY'
import socket, sys
ctl, payload = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(ctl)
s.sendall((payload + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
print(buf.decode().strip())
PY
}

edge_alive() { [[ -S $EDGE_CTL ]] || { log "edge tidak hidup ($EDGE_CTL)"; return 1; } }

# ---------- state ----------
jget() { # jget <user> <python-expr-on-e | ''>
  local expr="${2:-}"
  if [[ -z $expr ]]; then
    python3 -c "import json; print(json.dumps(json.load(open('$USERS_JSON')).get('$1',{})))"
  else
    python3 -c "import json; e=json.load(open('$USERS_JSON')).get('$1',{}); print($expr)"
  fi
}
jset() { python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$1']=$2
json.dump(d,open('$USERS_JSON','w'),indent=1)
"; }
jdel() { python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d.pop('$1',None)
json.dump(d,open('$USERS_JSON','w'),indent=1)
"; }

pick_port() { # pick_port [extra-json] → port bebas dari pool
  local used
  used=$(python3 -c "
import json
d=json.load(open('$USERS_JSON'))
for u,v in d.items():
    print(v.get('port',''))
    if v.get('udpgw'): print(v['udpgw'].get('port',''))
")
  for p in $PORT_POOL; do
    if ! grep -qx "$p" <<< "$used"; then echo "$p"; return 0; fi
  done
  return 1
}

udpgw_shared_pick() { # pick satu port shared utk user baru (minimal terpakai → merata)
  local used
  used=$(python3 -c "
import json,os
try:
    d=json.load(open('$USERS_JSON'))
except Exception:
    d={}
cnt={}
for u,v in d.items():
    if v.get('udpgw') and v['udpgw'].get('port'):
        cnt[str(v['udpgw']['port'])] = cnt.get(str(v['udpgw']['port']),0)+1
print(json.dumps(cnt))
")
  local least="" least_n=999999 p n
  for p in $UDPGW_SHARED_PORTS; do
    n=$(python3 -c "import json;print(json.loads('''$used''').get('$p',0))" 2>/dev/null || echo 0)
    if [[ ${n:-0} -lt $least_n ]]; then least_n=$n; least=$p; fi
  done
  echo "$least"
}

# Model B: TIDAK spawn per-user lagi. Daemon shared sudah jalan (install/06).
# Fungsi dipertahankan utk kompatibilitas API lama, tapi hanya mengembalikan port sama.
spawn_udpgw() { return 0; }
kill_udpgw() { return 0; }

warp_rule_add() { # warp_rule_add <user>
  local uid tid
  uid=$(id -u "$1")
  tid=$(( 30000 + uid % 10000 ))
  ip route add default dev "$WARP_IF" table "$tid" 2>/dev/null \
    || { log "warp: route gagal (interface $WARP_IF?)"; return 1; }
  ip rule add uidrange "$uid-$uid" lookup "$tid" 2>/dev/null \
    || { log "warp: rule gagal"; ip route del default dev "$WARP_IF" table "$tid" 2>/dev/null; return 1; }
  log "warp $1: uid $uid → table $tid via $WARP_IF"
}
warp_rule_del() {
  local uid tid
  uid=$(id -u "$1" 2>/dev/null) || return 0
  tid=$(( 30000 + uid % 10000 ))
  ip rule del uidrange "$uid-$uid" lookup "$tid" 2>/dev/null
  ip route del default dev "$WARP_IF" table "$tid" 2>/dev/null
}

write_client_info() {
  local user="$1"
  local entry; entry=$(python3 -c "import json; print(json.dumps(json.load(open('$USERS_JSON')).get('$1',{})))")
  local pass port pexp bwd bwu udp wpt ipl
  pass=$(jget "$user" "e.get('pass','')")
  port=$(jget "$user" "e.get('port','')")
  pexp=$(jget "$user" "e.get('expire_ts',0)")
  bwd=$(jget "$user" "e.get('bw_down_mbps',0)")
  bwu=$(jget "$user" "e.get('bw_up_mbps',0)")
  udp=$(jget "$user" "e.get('udpgw',{}).get('port','')")
  wpt=$(jget "$user" "e.get('udpgw',{}).get('warp_port','')")
  ipl=$(jget "$user" "e.get('ip_limit',0)")
  qta=$(jget "$user" "e.get('quota_gb',0)")
  local qstr="unlimited"; [[ ${qta:-0} -gt 0 ]] && qstr="${qta}GB (lifetime)"
  local expstr="unlimited"; [[ ${pexp:-0} -gt 0 ]] && expstr=$(date -u -d "@$pexp" '+%F %T UTC')
  local bwstr="Unlimited"
  [[ ${bwd:-0} -gt 0 || ${bwu:-0} -gt 0 ]] && bwstr="${bwd}M down / ${bwu}M up"
  local ipstr="unlimited"; [[ ${ipl:-0} -gt 0 ]] && ipstr="${ipl} IP berbeda (maksimal)"
  cat > "$STATE_DIR/client-$user.txt" <<EOF
Node        : $DOMAIN
User        : $user
Password    : $pass
Expire      : $expstr
SSH Port    : $port      (via Cloudflare)
Bandwidth   : $bwstr
Quota       : $qstr
IP Limit    : $ipstr
EOF
  # port pool lengkap, dikelompokkan TLS/nonTLS (443 & 80 utama, sisanya alternatif)
  local tls_p="443"; local n_tls_p="80"; local p
  for p in $PORT_POOL; do
    case "$p" in
      443|2053|2083|2087|8443|2096) [[ "$p" != 443 ]] && tls_p="$tls_p $p";;
      80|8080|8880|2052|2082|2086|2095) [[ "$p" != 80 ]] && n_tls_p="$n_tls_p $p";;
    esac
  done
  cat >> "$STATE_DIR/client-$user.txt" <<EOF
Port List   :
  TLS       : $tls_p
  nonTLS    : $n_tls_p
  (semua port aktif via Cloudflare — pilih salah satu; $port = port akun ini)
EOF
  [[ -n $udp ]] && cat >> "$STATE_DIR/client-$user.txt" <<EOF
UDPGW       : $udp      (shared UDP — via Cloudflare)
EOF
  # SlowDNS (aktif kalau SLOWDNS_ENABLED=1 di mb.conf) — satu akun SSH otomatis dapat slowdns
  if [[ "${SLOWDNS_ENABLED:-0}" == "1" && -n "${SLOWDNS_DOMAIN:-}" && -n "${SLOWDNS_PUBKEY:-}" ]]; then
    cat >> "$STATE_DIR/client-$user.txt" <<EOF
SlowDNS     : ${SLOWDNS_DOMAIN}:${SLOWDNS_PORT:-53}  (UDP)
  Nameserver: ${SLOWDNS_DOMAIN}
  PublicKey : ${SLOWDNS_PUBKEY}
  (Pakai aplikasi yang support SlowDNS — isi IP, domain & pubkey ini)
EOF
  fi
  [[ -n $wpt ]] && echo "WARP      : active" >> "$STATE_DIR/client-$user.txt"
  cat >> "$STATE_DIR/client-$user.txt" <<EOF

--- Koneksi ---
SSH  : ssh -p $port $user@$DOMAIN
Tunnel: ssh -p $port -L 7890:TARGET:PORT $user@$DOMAIN -N
EOF
  [[ -n $udp ]] && cat >> "$STATE_DIR/client-$user.txt" <<EOF
UDPGW: badvpn-udpgw --client --forward 127.0.0.1:53 --to-addr $DOMAIN:$udp
EOF
  chmod 600 "$STATE_DIR/client-$user.txt"
  write_motd "$user"
}

# ---------- server message (MOTD) per-user ----------
write_motd() {
  local user="$1"
  local port pexp bwd bwu qta expstr qstr bwstr
  port=$(jget "$user" "e.get('port','')")
  pexp=$(jget "$user" "e.get('expire_ts',0)")
  bwd=$(jget "$user" "e.get('bw_down_mbps',0)")
  bwu=$(jget "$user" "e.get('bw_up_mbps',0)")
  qta=$(jget "$user" "e.get('quota_gb',0)")
  qstr="unlimited"; [[ ${qta:-0} -gt 0 ]] && qstr="${qta}GB"
  expstr="unlimited"; [[ ${pexp:-0} -gt 0 ]] && expstr=$(date -u -d "@$pexp" '+%F %T UTC')
  bwstr="Unlimited"; [[ ${bwd:-0} -gt 0 || ${bwu:-0} -gt 0 ]] && bwstr="${bwd}M down / ${bwu}M up"
  local rc="/home/$user/.bashrc"
  [[ -d /home/$user ]] || return 0
  touch "$rc"
  python3 - "$rc" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"# >>> mb-ssh motd >>>.*?# <<< mb-ssh motd <<<\n?", "", s, flags=re.S)
open(p, "w").write(s.rstrip() + "\n")
PY
  cat >> "$rc" <<EOF
# >>> mb-ssh motd >>>
if [[ -z "\${MB_SSH_MOTD:-}" ]]; then
  MB_SSH_MOTD=1
  cat <<'MBMOTD'
+----------------------------------------------------+
|  Terima kasih menggunakan $DOMAIN
+----------------------------------------------------+
|  Server   : $DOMAIN
|  Akun     : $user
|  Expire   : $expstr
|  SSH Port : $port (via Cloudflare)
|  Bandwidth: $bwstr
|  Quota    : $qstr
|  Support  : ${SUPPORT:-zxpedia}
+----------------------------------------------------+
MBMOTD
fi
# <<< mb-ssh motd <<<
EOF
}

# ---------- ops ----------
do_add() {
  local user="$1" days="${2:-30}" udp=0 bwd=0 bwu=0 backend=direct warp=0 quota=0 ip_limit="-"
  shift $(( $# >= 2 ? 2 : $# )) || true
  # parse flags (sisa arg)
  while [[ $# -gt 0 ]]; do case "$1" in
    --udp) udp=1;; --warp) warp=1;;
    --bw) local bw="${2:?--bw DOWN/UP}"; IFS=/ read -r bwd bwu <<< "$bw"; shift;;
    --backend) backend="${2:?}"; shift;;
    --quota) quota="${2:?--quota GB}"; shift;;
    --pass) pass="${2:?--pass PASSWORD}"; shift;;
    --ip-limit) ip_limit="${2:?--ip-limit N}"; shift;;
  esac; shift; done
  # default dari config kalau tidak di-set via flag
  [[ "$ip_limit" == "-" ]] && ip_limit="${DEFAULT_IP_LIMIT:-0}"

  id -u "$user" &>/dev/null && die "$user sudah ada"
  local port pexp now
  : "${pass:=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)}"
  port=$(pick_port) || die "port pool habis (PORT_POOL)"
  now=$(date +%s)
  [[ $days -gt 0 ]] && pexp=$((now + days*86400)) || pexp=0

  useradd -m -s /usr/sbin/nologin "$user" || die "useradd gagal"
  echo "$user:$pass" | chpasswd
  [[ $pexp -gt 0 ]] && usermod -e "$(date -u -d "@$pexp" '+%Y-%m-%d')" "$user"

  local backend_addr="127.0.0.1:$DROPBEAR_PORT"
  [[ $backend == tls ]] && backend_addr="127.0.0.1:$STUNNEL_PORT"

  local spec="{\"cmd\":\"add\",\"user\":\"$user\",\"port\":$port,\"backend\":\"$backend_addr\",\"bw_down_mbps\":$bwd,\"bw_up_mbps\":$bwu,\"ip_limit\":${ip_limit:-0}"
  local lp="" udpport=""
  if [[ $udp -eq 1 ]]; then
    # Model B: pilih satu port shared yang paling sedikit terpakai (round-robin merata)
    udpport=$(udpgw_shared_pick)
    [[ -n $udpport ]] || die "UDPGW_SHARED_PORTS kosong (cek install/06-udpgw-shared.sh)"
    spec="$spec,\"udpgw\":{\"port\":\"$udpport\"}"
  fi
  spec="$spec,\"quota_gb\":$quota,\"expire_ts\":$pexp}"

  edge_alive || die "mb-edge tidak jalan (systemctl start mb-edge)"
  local resp; resp=$(edge_ctl "$spec")
  case "$resp" in
    ok) ;;
    *) jdel "$user"; userdel -r "$user" 2>/dev/null; die "edge add gagal: $resp";;
  esac

  [[ $warp -eq 1 ]] && warp_rule_add "$user" || true

  local udp_json=""
  [[ $udp -eq 1 ]] && udp_json=",\"udpgw\":{\"port\":\"$udpport\"}"
  jset "$user" "{\"pass\":\"$pass\",\"port\":$port,\"backend\":\"$backend\",\"expire_ts\":$pexp,\"days\":$days,\"bw_down_mbps\":$bwd,\"bw_up_mbps\":$bwu,\"ip_limit\":${ip_limit:-0},\"created\":$now,\"warp\":$warp,\"quota_gb\":$quota$udp_json}"
  write_client_info "$user"
  local extra=""
  [[ $udp -eq 1 ]] && extra="udp:$udpport"
  [[ $warp -eq 1 ]] && extra="${extra:+$extra }warp"
  log "OK $user — port $port${extra:+ ($extra)} expiry $( [[ $pexp -gt 0 ]] && date -u -d "@$pexp" '+%F' || echo unlimited )"
}

do_del() {
  local user="$1"
  local entry; entry=$(python3 -c "import json;e=json.load(open('$USERS_JSON')).get('$user',{});print(json.dumps(e))")
  local port
  port=$(jget "$user" "e.get('port','')")
  edge_ctl "{\"cmd\":\"remove\",\"user\":\"$user\"}" >/dev/null || true
  # Model B (shared udpgw): tidak ada daemon per-user yang perlu dimatikan.
  warp_rule_del "$user"
  id -u "$user" &>/dev/null && userdel -r "$user" 2>/dev/null
  jdel "$user"
  rm -f "$STATE_DIR/client-$user.txt"
  log "deleted: $user"
}

do_set() {
  local user="$1"; shift || true
  local days="" bw="" port="" adays="" quota="" unblock=0 rquota=0 warpflag="" pexp="" ip_limit=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --bw) bw="${2:?}"; shift;;
    --port) port="${2:?}"; shift;;
    --add-days) adays="${2:?}"; shift;;
    --quota) quota="${2:?}"; shift;;
    --ip-limit) ip_limit="${2:?}"; shift;;
    --unblock) unblock=1;;
    --reset-quota) rquota=1;;
    --warp) warpflag=1;;
    --no-warp) warpflag=0;;
    *) days="$1";;
  esac; shift; done
  id -u "$user" &>/dev/null || die "$user tidak ada"
  local now; now=$(date +%s)
  if [[ -n $days ]]; then
    local pexp; [[ $days -gt 0 ]] && pexp=$((now + days*86400)) || pexp=0
    [[ $pexp -gt 0 ]] && usermod -e "$(date -u -d "@$pexp" '+%Y-%m-%d')" "$user" || usermod -e "" "$user"
    python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'expire_ts':$pexp,'days':$days})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
  fi
  if [[ -n $adays ]]; then
    local cur; cur=$(jget "$user" "e.get('expire_ts',0)")
    local base; [[ ${cur:-0} -gt $now ]] && base=$cur || base=$now
    local pexp=$((base + adays*86400))
    usermod -e "$(date -u -d "@$pexp" '+%Y-%m-%d')" "$user"
    python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'expire_ts':$pexp})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
    log "extend $user +$adays hari → $(date -u -d "@$pexp" '+%F')"
  fi
  local bwd="" bwu=""
  [[ -n $bw ]] && IFS=/ read -r bwd bwu <<< "$bw"
  if [[ -n $bw ]]; then
    python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'bw_down_mbps':$bwd,'bw_up_mbps':$bwu})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
  fi
  if [[ -n $quota ]]; then
    python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'quota_gb':$quota})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
  fi
  if [[ -n $ip_limit ]]; then
    python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'ip_limit':$ip_limit})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
  fi
  if [[ -n $bw || -n $quota || -n $pexp || -n $ip_limit || $unblock -eq 1 || $rquota -eq 1 ]]; then
    local spec
    spec=$(python3 -c "
import json
d = {'cmd': 'setbw', 'user': '$user'}
$([[ -n $bw ]] && echo "d['bw_down_mbps'] = $bwd
d['bw_up_mbps'] = $bwu")
$([[ -n $quota ]] && echo "d['quota_gb'] = $quota")
$([[ -n $ip_limit ]] && echo "d['ip_limit'] = $ip_limit")
$([[ -n $pexp ]] && echo "d['expire_ts'] = $pexp")
$([[ $unblock -eq 1 ]] && echo "d['unblock'] = True")
$([[ $rquota -eq 1 ]] && echo "d['reset_quota'] = True")
print(json.dumps(d))
")
    edge_alive && edge_ctl "$spec" || log "edge down — setbw skip"
  fi
  if [[ -n $warpflag ]]; then
    if [[ $warpflag -eq 1 ]]; then
      warp_rule_add "$user" || log "warp add gagal (WARP_IF?)"
      python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'warp':1})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
    else
      warp_rule_del "$user"
      python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'warp':0})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
    fi
  fi
  write_client_info "$user"
  log "set OK: $user"
}

do_list() {
  if [[ "${1:-}" == "--json" ]]; then
    python3 -c "
import json, os, socket
try:
    u=json.load(open('$USERS_JSON'))
except Exception:
    u={}
try:
    st=json.load(open('$STATS_JSON'))
except Exception:
    st={}
# live edge state (blocked) — edge hidup?
edge={}
ctl=os.environ.get('EDGE_CTL','/run/mb-ssh/edge.sock')
if os.path.exists(ctl):
    try:
        s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(ctl)
        s.sendall((json.dumps({'cmd':'list'})+'\n').encode())
        buf=b''
        while not buf.endswith(b'\n'):
            d=s.recv(4096)
            if not d: break
            buf+=d
        s.close()
        edge=json.loads(buf.decode().strip())
    except Exception:
        edge={}
for k, v in u.items():
    v['stats'] = st.get(k, {'in':0,'out':0,'sessions':0,'active':0})
    v['quota_used'] = v['stats']['in'] + v['stats']['out']
    e=edge.get('users',{}).get(k)
    if e:
        v['blocked']=e.get('blocked')
print(json.dumps(u, indent=1))
"
    return
  fi
  echo "=== USERS ==="
  python3 -c "
import json, datetime
d = json.load(open('$USERS_JSON'))
for u, v in sorted(d.items()):
    exp = v.get('expire_ts') or 0
    exps = 'unlimited' if exp == 0 else datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).strftime('%F')
    udp = f\"udp:{v['udpgw']['port']}\" if v.get('udpgw') else '    -'
    warp = 'warp' if v.get('warp') else '    -'
    print(f\"  {u:<22} port={v.get('port','?'):<5} {udp:<12} {warp:<5} {v.get('bw_down_mbps',0)}M/{v.get('bw_up_mbps',0)}M  expire={exps}\")
"
  edge_alive && { echo "=== EDGE ==="; edge_ctl '{"cmd":"list"}'; } || echo "=== EDGE: down ==="
}

do_show() {
  local user="$1"
  if [[ "${2:-}" == "--json" ]]; then
    python3 -c "
import json, os
try:
    u=json.load(open('$USERS_JSON')).get('$user')
except Exception:
    u=None
if u is None:
    print(json.dumps({'error':'not found'})); raise SystemExit(1)
try:
    st=json.load(open('$STATS_JSON')).get('$user', {'in':0,'out':0,'sessions':0,'active':0})
except Exception:
    st={'in':0,'out':0,'sessions':0,'active':0}
ci=''
p='$STATE_DIR/client-$user.txt'
if os.path.isfile(p):
    ci=open(p).read()
u['stats']=st
u['quota_used']=st['in']+st['out']
u['client_info']=ci
print(json.dumps(u, indent=1))
"
    return
  fi
  cat "$STATE_DIR/client-$user.txt" 2>/dev/null || die "tidak ada"
}

_mbz_backup() {
  # Marzban (VLESS/VMess/Trojan): DB SQLite online-backup + xray config → STATE_DIR
  # (ikut ter-upload ke R2 via rclone copy STATE_DIR)
  [[ -d /opt/marzban ]] || { log "marzban tidak ada — skip"; return 1; }
  local tmp; tmp=$(mktemp -d)
  local ok=0
  if [[ -f /opt/marzban/db.sqlite3 ]]; then
    if command -v sqlite3 >/dev/null && \
       sqlite3 /opt/marzban/db.sqlite3 ".backup '$tmp/marzban.db'" 2>/dev/null; then
      ok=1
    else
      # fallback: copy mentah (DR — copy mungkin inconsistent, tapi lebih baik dari tak ada)
      cp /opt/marzban/db.sqlite3 "$tmp/marzban.db" 2>/dev/null && ok=1
    fi
  fi
  [[ $ok -eq 1 ]] || { rm -rf "$tmp"; log "db.sqlite3 tidak bisa di-backup — skip"; return 1; }
  cp /opt/marzban/xray_config.json "$tmp/xray_config.json" 2>/dev/null
  tar czf "$STATE_DIR/marzban-latest.tar.gz" -C "$tmp" .
  rm -rf "$tmp"
  log "marzban backup OK ($(du -h "$STATE_DIR/marzban-latest.tar.gz" | cut -f1))"
}

_mbz_restore() {
  # kembalikan DB Marzban dari marzban-latest.tar.gz (sudah ditarik do_restore dari R2)
  [[ -f /opt/marzban/db.sqlite3 ]] || { log "marzban tidak ada — skip restore"; return 1; }
  [[ -f "$STATE_DIR/marzban-latest.tar.gz" ]] || { log "marzban-latest.tar.gz tidak ada — skip"; return 1; }
  local tmp; tmp=$(mktemp -d)
  tar xzf "$STATE_DIR/marzban-latest.tar.gz" -C "$tmp"
  if command -v marzban >/dev/null; then
    marzban down 2>/dev/null || true
  else
    docker compose -f /opt/marzban/docker-compose.yml down 2>/dev/null || true
  fi
  cp "$tmp/marzban.db" /opt/marzban/db.sqlite3
  [[ -f "$tmp/xray_config.json" ]] && cp "$tmp/xray_config.json" /opt/marzban/xray_config.json
  if command -v marzban >/dev/null; then
    marzban up || log "PERHATIAN: marzban up gagal — jalankan manual: marzban up"
  elif docker compose -f /opt/marzban/docker-compose.yml up -d 2>/dev/null; then
    :
  else
    log "PERHATIAN: start marzban otomatis gagal — jalankan manual: marzban up"
  fi
  rm -rf "$tmp"
  log "marzban restore OK"
}

do_backup() {
  command -v rclone >/dev/null || die "rclone tidak ada (apt install rclone)"
  [[ -n $R2_REMOTE ]] || die "R2_REMOTE kosong di $CONF"
  mkdir -p "$STATE_DIR"
  _mbz_backup || true
  rclone copy "$STATE_DIR" "$R2_REMOTE:$R2_PATH/state" --transfers 4 --log-error || die "rclone state gagal"
  rclone copy "$CONF_DIR" "$R2_REMOTE:$R2_PATH/config" --transfers 4 --log-error || die "rclone config gagal"
  log "backup OK → $R2_REMOTE:$R2_PATH (ssh state + marzban + config)"
}

do_restore() {
  command -v rclone >/dev/null || die "rclone tidak ada"
  [[ -n $R2_REMOTE ]] || die "R2_REMOTE kosong di $CONF"
  mkdir -p "$STATE_DIR"
  rclone copy "$R2_REMOTE:$R2_PATH/state" "$STATE_DIR" --transfers 4 --log-error || die "rclone restore gagal"
  rclone copy "$R2_REMOTE:$R2_PATH/config" "$CONF_DIR" --transfers 4 --log-error || true
  _mbz_restore || true
  log "restore OK dari $R2_REMOTE:$R2_PATH — jalankan: systemctl restart mb-edge"
}

_update_check() {
  # Update tanpa git: bandingkan commit remote (GitHub API) vs versi lokal (file VERSION_REV).
  # Keluar 0 = update tersedia (cache rincian ditulis), 1 = sudah terbaru,
  # 2 = tak bisa cek (REPO_URL kosong / jaringan)
  [[ -z $REPO_URL ]] && { echo "REPO_URL kosong — set via setup"; return 2; }
  local api="https://api.github.com/repos/ultrassh45/mb-ssh/commits/${REPO_BRANCH:-main}"
  local remote="" cur=""
  remote=$(curl -fsSL --max-time 15 "$api" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('sha','')[:7])" 2>/dev/null || true)
  [[ -n $remote ]] || remote=$(wget -qO- --timeout=15 "$api" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('sha','')[:7])" 2>/dev/null || true)
  [[ -n $remote ]] || { echo "gagal cek remote (jaringan?)"; return 2; }
  cur=$(cat "$SRC_DIR/VERSION_REV" 2>/dev/null || echo "unknown")
  if [[ "$cur" != "$remote" ]]; then
    mkdir -p "$(dirname "$UPDATE_CACHE")" 2>/dev/null
    { echo "UPDATE:${cur}→${remote}"; echo "HEAD_NEW=$remote"; echo "HELPER_CACHE=1"; } > "$UPDATE_CACHE"
    echo "UPDATE:${cur}→${remote}"
    return 0
  fi
  rm -f "$UPDATE_CACHE" 2>/dev/null
  echo "up-to-date: $cur"
  return 1
}

_snapshot() {
  # arsip KODE + config NON-destroy saat ini → rollback/<ts>/ ; KODE asli runtime
  # disebut .ro. Digunakan do_update & do_rollback.
  local dv=bin conf
  dv="$ROLLBACK_DIR" && mkdir -p "$ROLLBACK_DIR"
  conf="$CONF_DIR"
  for f in mb-ssh2.sh mb-edge.py mb-tgbot.py mb-ssh2-cleanup.sh; do
    [[ -f "$BIN_DIR/$f" ]] && cp -a "$BIN_DIR/$f" "$ROLLBACK_DIR/$f"
  done
  for f in mb.conf edge.json stunnel-mb-ssh.conf; do
    [[ -f "$conf/$f" ]] && cp -a "$conf/$f" "$ROLLBACK_DIR/$f"
  done
  echo "$ROLLBACK_DIR"
}

_verify() {
  # verifikasi sistem setelah update — 0 = OK, 1 = gagal
  local allok=1
  # 1. syntax semua file runtime
  bash -n "$BIN_DIR/mb-ssh2.sh" && bash -n "$BIN_DIR/mb-ssh2-cleanup.sh" || allok=0
  python3 -m py_compile "$BIN_DIR/mb-edge.py" "$BIN_DIR/mb-tgbot.py" 2>/dev/null || allok=0
  # 2. systemd unit valid + services up
  systemctl daemon-reload 2>/dev/null || allok=0
  # 3. edge API :8499 (config-basis) — pakai nilai dari edge.json
  local apiport aptok
  apiport=$(python3 -c "import json; print(json.load(open('$CONF_DIR/edge.json'))['api']['port'])" 2>/dev/null || echo 8499)
  aptok=$(python3 -c "import json; print(json.load(open('$CONF_DIR/edge.json'))['api'].get('token',''))" 2>/dev/null)
  [[ $apiport == 8499 ]] || echo "API port non-default: $apiport"
  return $((!allok))
}

_restore_snapshot() {
  # tarik kembali file runtime + config dari snapshot (data user tdk tersentuh)
  local rb="$1"
  [[ -d $rb ]] || { log "snapshot $rb tidak ada"; return 1; }
  local f
  for f in mb-ssh2.sh mb-edge.py mb-tgbot.py mb-ssh2-cleanup.sh; do
    [[ -f "$rb/$f" ]] && install -m 755 "$rb/$f" "$BIN_DIR/$f"
  done
  for f in mb.conf edge.json stunnel-mb-ssh.conf; do
    [[ -f "$rb/$f" ]] && cp -a "$rb/$f" "$CONF_DIR/$f"
  done
  return 0
}

do_update() {
  # update script dari git repo (REPO_URL/REPO_BRANCH di mb.conf)
  # alur: --check → snapshot → pasang → _verify → gagal? auto-rollback (data utuh)
  local rc rb
  _update_check; rc=$?
  if [[ $rc -eq 1 || $rc -eq 2 ]]; then
    log "tidak ada update tersedia (rc=$rc)"
    return 0
  fi
  [[ $rc -eq 0 ]] || { log "update --check gagal (rc=$rc)"; return 1; }
  rb=$(_snapshot)
  log "update tersedia — snapshot $rb"
  # unduh repo versi terbaru via arsip tar.gz (TANPA git)
  local tgz="https://codeload.github.com/ultrassh45/mb-ssh/tar.gz/refs/heads/${REPO_BRANCH:-main}"
  local tmp; tmp="$(mktemp -d)"
  local ok=0
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 180 "$tgz" -o "$tmp/repo.tar.gz" && ok=1 || ok=0
  fi
  if [[ $ok -eq 0 ]] && command -v wget >/dev/null 2>&1; then
    wget -q --timeout=20 -O "$tmp/repo.tar.gz" "$tgz" && ok=1 || ok=0
  fi
  if [[ $ok -eq 0 ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$tgz" "$tmp/repo.tar.gz" <<'PYEOF' && ok=1 || ok=0
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PYEOF
  fi
  if [[ $ok -ne 1 ]]; then
    log "unduh update gagal (jaringan) — abort, tidak ada yang berubah"
    rm -rf "$tmp"; return 1
  fi
  mkdir -p "$SRC_DIR"
  tar -xzf "$tmp/repo.tar.gz" -C "$SRC_DIR" --strip-components=1 || { log "ekstrak gagal — abort"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  local newrev
  newrev=$(cat "$SRC_DIR/VERSION_REV" 2>/dev/null || echo "?")
  # pasang runtime baru (config TIDAK pernah ditimpa — run.sh sudah idempotent)
  local f
  for f in mb-ssh2.sh mb-edge.py mb-tgbot.py mb-ssh2-cleanup.sh; do
    [[ -f "$SRC_DIR/runtime/$f" ]] && install -m 755 "$SRC_DIR/runtime/$f" "$BIN_DIR/$f"
  done
  # unit systemd baru (tidak sentuh conffile user)
  for u in mb-edge dropbear-client mb-tgbot; do
    [[ -f "$SRC_DIR/systemd/$u.service" ]] && install -m 644 "$SRC_DIR/systemd/$u.service" "$UNIT_DIR/$u.service"
  done
  if _verify; then
    rm -f "$UPDATE_CACHE"
    log "verifikasi OK — selesai (runtime ${newrev:-?})"
    if [[ ${MB_TEST:-0} != 1 ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload
      systemctl restart mb-edge dropbear-client mb-tgbot 2>/dev/null || true
    fi
  else
    log "VERIFIKASI GAGAL — rollback otomatis dari snapshot $rb"
    _restore_snapshot "$rb"
    log "rollback selesai — data user TIDAK tersentuh, kembali ke versi lama"
    rm -f "$UPDATE_CACHE"
    return 1
  fi
}

do_rollback() {
  # rollback manual: mb-ssh2 rollback <path-snapshot>
  local rb="${1:-}"
  [[ -n $rb ]] || die "usage: mb-ssh2 rollback <snapshot>  (lihat: ls $ROLLBACK_DIR)"
  _restore_snapshot "$rb"
  if _verify; then
    log "rollback OK ke $rb — restart service"
    if [[ ${MB_TEST:-0} != 1 ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload
      systemctl restart mb-edge dropbear-client mb-tgbot 2>/dev/null || true
    fi
  else
    log "rollback juga gagal verifikasi — periksa log update"
    return 1
  fi
}

do_apikey() {
  #   mb-ssh2 apikey            → print API token edge (dari $EDGE_CFG api.token)
  #   mb-ssh2 apikey --reset    → regenerate token acak, tulis edge.json, restart mb-edge
  local cfg="${EDGE_CFG:-$CONF_DIR/edge.json}"
  [[ -f $cfg ]] || die "edge config tidak ada: $cfg"
  local cur=$(python3 -c "import json,sys; print(json.load(open('$cfg'))['api']['token'])" 2>/dev/null)
  if [[ "${1:-}" == "--reset" ]]; then
    local new="${2:-}"
    [[ -z $new ]] && new=$(python3 -c "import secrets; print('mb'+secrets.token_hex(24))")
    python3 - "$cfg" "$new" <<'PY'
import json, sys
p, tok = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d['api']['token'] = tok
json.dump(d, open(p, 'w'), indent=2, ensure_ascii=False)
print("tersimpan")
PY
    # restart mb-edge supaya token baru dipakai (UI admin panel juga wajib pakai yg ini)
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q mb-edge; then
      systemctl restart mb-edge && log "mb-edge restart — token baru aktif (update panel: Server → API Token Node = $new)"
    else
      log "mb-edge bukan systemd — restart manual / edge relaod: kill -HUP $(pidof mb-edge.py 2>/dev/null) (token lama: $cur)"
    fi
    echo "TOKEN BARU: $new"
    return 0
  fi
  curl -s -m 10 "http://127.0.0.1:8499/v1/health" -H "Authorization: Bearer $cur" >/dev/null 2>&1 && echo "OK" || echo "TIDAK TERVERIFIKASI (node mati/remote?)"
  echo "API Token (SSH): $cur"
  echo "Lokasi: $cfg"
  echo "Gunakan token ini di panel: Server → Add/Edit → API Token Node"
}

do_marzban_token() {
  # baca kredensial admin dari /opt/marzban/.env → login → print JWT fresh
  #   mb-ssh2 marzban-token              → token (JWT) utk dashboard API
  #   mb-ssh2 marzban-token --creds      → print username + (password didapat dari .env db)
  local env="/opt/marzban/.env"
  [[ -f $env ]] || die "Marzban .env tidak ada: $env — node belum install Marzban?"
  local sudouser=$(grep -E "^SUDO_USERNAME=" "$env" | cut -d= -f2- | tr -d '"')
  local sudopass=$(grep -E "^SUDO_PASSWORD=" "$env" | cut -d= -f2- | tr -d '"' | base64 -d 2>/dev/null || grep -E "^SUDO_PASSWORD=" "$env" | cut -d= -f2- | tr -d '"')
  [[ -n $sudouser ]] || die "SUDO_USERNAME kosong di .env"
  [[ -n $sudopass ]] || die "SUDO_PASSWORD kosong di .env"
  local base="${MBZ_BASE:-http://127.0.0.1:8000}"
  curl -s -m 10 -X POST "$base/api/admin/token" -u "${sudouser}:${sudopass}" \
    > /tmp/mbz-token.json 2>/dev/null || die "post gagal"
  python3 - <<'PY'
import json, time
try:
    d = json.load(open('/tmp/mbz-token.json'))
    tok = d.get('access_token', d.get('token'))
    if not tok:
        print('RESPON TANPA access_token:'); print(json.dumps(d, indent=2)[:500]); raise SystemExit(1)
    print("ACCESS_TOKEN (Marzban):"); print(tok)
    exp = d.get('expires_in')
    if exp: print(f"expire {int(exp)} detik ({d.get('expires_in')})")
except Exception as e:
    print(f"parse gagal: {e}"); raise SystemExit(1)
PY
  # opsional: cek valid token / ketik "--verify"
  if [[ "${1:-}" == "--verify" ]]; then
    curl -s -m 10 "$base/api/admin/" -H "Authorization: Bearer $(python3 -c "import json; print(json.load(open('/tmp/mbz-token.json')).get('access_token',''))")" >/dev/null 2>&1 && echo "VERIFIED: token aktif utk API admin" || echo "WARNING: token tak aktif"
  fi
}

do_login_check() {
  # dipanggil tiap login interaktif (via bashrc hook). Tampilkan UPDATE TERSEDIA
  # + rincian + pilihan Y/N. Up-to-date / tak bisa cek = diam (MOTD normal).
  local rc line ans
  _update_check; rc=$?
  [[ $rc -ne 0 ]] && return 0
  echo ""
  echo "============================================================"
  echo "  ⚠  UPDATE TERSEDIA — mb-ssh2"
  echo "============================================================"
  echo "  Rincian perubahan:"
  while IFS= read -r line; do
    [[ $line == HEAD_NEW* || $line == HELPER_CACHE* ]] && continue
    echo "    • $line"
  done < "$UPDATE_CACHE"
  echo "============================================================"
  read -rp "  Jalankan update sekarang? (y/N): " ans
  case "${ans,,}" in
    y|ya|yes)
      do_update
      echo "  (selesai — login berikutnya normal)"
      ;;
    *)
      echo "  Dilewati. Update tersedia — kapan pun ketik: mb-ssh2 update"
      ;;
  esac
  echo ""
}

_install_login_hook() {
  # pasang hook cek-update ke bashrc user admin (idempotent)
  local u="$1" rcfile
  [[ -n $u ]] || return 0
  if [[ $u == root ]]; then
    rcfile=/root/.bashrc
  else
    [[ -d /home/$u ]] || { log "user $u tidak ada — hook login skip"; return 1; }
    rcfile="/home/$u/.bashrc"
  fi
  grep -q "mb-ssh2 login-check" "$rcfile" 2>/dev/null && { log "hook login sudah ada di $rcfile"; return 0; }
  cat >> "$rcfile" <<'EOF'

# mb-ssh: cek update script saat login (Y = update, N = lewati)
[ -t 0 ] && [ -x /usr/local/bin/mb-ssh2 ] && /usr/local/bin/mb-ssh2 login-check
EOF
  log "hook login terpasang di $rcfile"
}

_tg_notify() {
  # kirim teks ke chat allow-list via Bot API; no-op kalau bot belum diset
  # atau caller = bot (MB_TG_BOT) agar tidak double-message
  [[ -n $TG_BOT_TOKEN && -n $TG_CHAT_ID ]] || return 0
  [[ -z ${MB_TG_BOT:-} ]] || return 0
  local chat payload
  for chat in $(echo "$TG_CHAT_ID" | tr ',' ' '); do
    payload=$(python3 -c "
import json, sys
cid = sys.argv[1]
print(json.dumps({'chat_id': int(cid) if cid.lstrip('-').isdigit() else cid,
                  'text': sys.argv[2]}))" "$chat" "$1" 2>/dev/null) || continue
    curl -s -m 10 -H 'Content-Type: application/json' -X POST \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "$payload" >/dev/null 2>&1 || true
  done
}

do_status() {
  local nu
  nu=$(python3 -c "import json; print(len(json.load(open('$USERS_JSON'))))" 2>/dev/null || echo "?")
  echo "=== MB-SSH STATUS ==="
  echo "Node      : $(hostname)"
  echo "Akun      : $(_count_all)"
  echo "R2_REMOTE : ${R2_REMOTE:-<belum diset>}"
  echo "R2_PATH   : ${R2_PATH}"
  echo "Backup    : ${BACKUP_INTERVAL:-0} (0 = tiap hari 03:03)"
  if [[ -n $TG_BOT_TOKEN ]]; then
    echo "Bot TG    : tersambung (chat: ${TG_CHAT_ID})"
    command -v systemctl >/dev/null 2>&1 && \
      echo "bot svc   : $(systemctl is-active mb-tgbot 2>/dev/null || echo 'tidak jalan')"
  else
    echo "Bot TG    : <belum diset> (mb-ssh2 menu → 1)"
  fi
  echo ""
  echo "Log backup (3 terakhir):"
  tail -3 /var/log/mb-ssh2-backup.log 2>/dev/null || echo "  (belum ada)"
}

_conf_set() {
  # tulis KEY=VALUE ke $CONF (append kalau baris belum ada)
  local key="$1" val="$2"
  if grep -q "^${key}=" "$CONF" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONF"
  else
    echo "${key}=\"${val}\"" >> "$CONF"
  fi
}

do_setup() {
  # wizard setup backup R2 + bot Telegram (bisa juga non-interaktif:
  #   mb-ssh2 setup <R2_REMOTE> [R2_PATH] <TG_BOT_TOKEN> <TG_CHAT_ID>)
  local r="${1:-}" p="${2:-}" tok="${3:-}" cid="${4:-}"
  echo "=== SETUP BACKUP & BOT TELEGRAM ==="
  if [[ -z $r ]]; then
    echo ""
    echo "--- [1/2] Backup R2 ---"
    echo "R2 = nama remote rclone (buat dulu: rclone config → type: s3 → provider: Cloudflare)"
    echo "Remote yang tersedia: $(rclone listremotes 2>/dev/null | tr '\n' ' ' || echo '(rclone tidak ada)')"
    read -rp "R2_REMOTE [${R2_REMOTE:-<kosong>}:]: " r; r="${r:-$R2_REMOTE}"
    read -rp "R2_PATH [${R2_PATH}]: " p; p="${p:-$R2_PATH}"
  fi
  if [[ -n $r ]]; then
    command -v rclone >/dev/null || die "rclone tidak ada — apt install rclone"
    rclone listremotes 2>/dev/null | grep -q "^${r}:" || \
      die "rclone remote '$r' tidak ada — buat dulu: rclone config"
    _conf_set R2_REMOTE "$r"
    _conf_set R2_PATH "$p"
    log "R2 tersimpan: $r:$p (cron 03:03 aktif)"
  else
    log "R2 dilewati"
  fi
  if [[ -z $tok ]]; then
    echo ""
    echo "--- [2/2] Bot Telegram ---"
    echo "1) Buat bot: chat @BotFather → /newbot → salin token"
    echo "2) Chat id: kirim pesan ke bot kamu, buka:"
    echo "   https://api.telegram.org/bot<TOKEN>/getUpdates → cari \"chat\":{\"id\":123...}"
    read -rp "TG_BOT_TOKEN [${TG_BOT_TOKEN:***}]: " tok; tok="${tok:-$TG_BOT_TOKEN}"
    read -rp "TG_CHAT_ID [${TG_CHAT_ID:-<kosong>}]: " cid; cid="${cid:-$TG_CHAT_ID}"
  fi
  if [[ -n $tok ]]; then
    local who
    who=$(curl -s -m 10 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null | \
      python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print('@'+d['result']['username'] if d.get('ok') else 'GAGAL: '+str(d.get('description','?'))[:80])
except Exception:
    print('GAGAL cek (network?)')" 2>/dev/null)
    [[ $who == @* ]] || die "TG_BOT_TOKEN tidak valid ($who) — cek token dari @BotFather"
    _conf_set TG_BOT_TOKEN "$tok"
    _conf_set TG_CHAT_ID "$cid"
    log "bot tersimpan: $who (chat: $cid)"
    if [[ -f /etc/systemd/system/mb-tgbot.service ]]; then
      systemctl daemon-reload 2>/dev/null
      systemctl enable --now mb-tgbot 2>/dev/null && \
        log "service mb-tgbot aktif" || log "start service gagal — cek: systemctl status mb-tgbot"
    else
      log "unit mb-tgbot.service belum ada — update node (bash run.sh) lalu: systemctl enable --now mb-tgbot"
    fi
    echo "Kirim /help ke bot untuk daftar perintah."
  else
    log "bot dilewati"
  fi
  # [3/3] update script: REPO_URL + pasang hook login
  if [[ -z ${1:-} && -z ${2:-} && -z ${3:-} && -z ${4:-} ]]; then
    echo ""
    echo "--- [3/3] Update script (auto-rollback) ---"
    echo "REPO_URL = sumber update script (repo GitHub). Biarkan kosong utk skip."
    read -rp "REPO_URL [${REPO_URL:-<kosong>}]: " repou; repou="${repou:-$REPO_URL}"
  else
    repou="${REPO_URL:-}"
  fi
  if [[ -n $repou ]]; then
    _conf_set REPO_URL "$repou"
    _conf_set REPO_BRANCH "$REPO_BRANCH"
    _install_login_hook "$(logname 2>/dev/null || echo root)"
    log "REPO_URL tersimpan — saat login akan muncul prompt update (Y/N)"
  else
    log "update script dilewati (REPO_URL kosong)"
  fi
  echo ""
  echo "Verifikasi: mb-ssh2 status"
}

_cron_spec() {
  # dari BACKUP_INTERVAL: "30m"|30→menit, "6j"→jam, "0"/kosong→har 03:03
  local iv="${BACKUP_INTERVAL:-0}"
  iv=$(echo "$iv" | tr -d ' ')
  case "$iv" in
    0|"") echo "3 3 * * *" ;;
    *m) local n=${iv%m}
        [[ $n =~ ^[0-9]+$ ]] && [[ $n -ge 1 ]] && [[ $n -le 59 ]] && \
          echo "*/$n * * * *" || echo "3 3 * * *" ;;
    *j) local h=${iv%j}
        [[ $h =~ ^[0-9]+$ ]] && [[ $h -ge 1 ]] && [[ $h -le 23 ]] && \
          echo "0 */$h * * *" || echo "3 3 * * *" ;;
    *)  if [[ $iv =~ ^[0-9]+$ ]] && [[ $iv -ge 1 ]] && [[ $iv -le 59 ]]; then
          echo "*/$iv * * * *"
        else
          echo "3 3 * * *"
        fi ;;
  esac
}

apply_backup_cron() {
  # tulis ulang baris cron 'mb-ssh2 backup' sesuai BACKUP_INTERVAL (idempotent)
  local spec cronline
  spec=$(_cron_spec)
  cronline="$spec /usr/local/bin/mb-ssh2 backup >> /var/log/mb-ssh2-backup.log 2>&1"
  python3 - "$cronline" <<'PY'
import subprocess, sys
line = sys.argv[1]
r = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
cur = r.stdout if r.returncode == 0 else ""
keep = [l for l in cur.splitlines() if "mb-ssh2 backup" not in l and l.strip()]
keep.append(line)
c = "\n".join(keep) + "\n"
subprocess.run(["crontab", "-"], input=c, text=True)
PY
  log "cron backup: ${spec} (BACKUP_INTERVAL=${BACKUP_INTERVAL:-0})"
}

do_schedule() {
  # atur jadwal backup via CLI/bot (non-interaktif):
  #   mb-ssh2 schedule 30 m   → tiap 30 menit
  #   mb-ssh2 schedule 6 j    → tiap 6 jam
  #   mb-ssh2 schedule 0      → jam 03:03 tiap hari (default)
  # tulis BACKUP_INTERVAL ke mb.conf + apply cron (idempotent, tanpa restart)
  local n="${1:-}" unit="${2:-}" iv
  if [[ -z $n ]]; then
    echo "=== JADWAL BACKUP ==="
    echo "Sekarang: ${BACKUP_INTERVAL:-0}   (0 = tiap hari 03:03)"
    echo "Contoh: '30 m' = tiap 30 menit | '6 j' = tiap 6 jam | '0' = tiap hari 03:03"
    read -rp "Jadwal (mis. 30 m / 6 j / 0): " iv
    set -- $iv
    n="${1:-}"; unit="${2:-$([ "$n" == "0" ] && echo 0)}"
  fi
  if [[ -z $n || $n == 0 ]]; then
    _conf_set BACKUP_INTERVAL "0"
    BACKUP_INTERVAL="0"
    apply_backup_cron
    log "jadwal backup: MATI (tiap hari 03:03)"
    return 0
  fi
  unit="${unit:-m}"
  [[ $n =~ ^[0-9]+$ && $n -ge 1 ]] || die "angka interval tidak valid: '$n'"
  case "$unit" in
    m|menit)  iv="${n}m" ;;
    j|jam)    iv="${n}j" ;;
    *)        iv="${n}m" ;;
  esac
  _conf_set BACKUP_INTERVAL "$iv"
  BACKUP_INTERVAL="$iv"
  apply_backup_cron
  log "jadwal backup: tiap $n ${unit} (BACKUP_INTERVAL=$iv)"
}

_dropbear_build() {
  # arg: versi (mis 2019.78) → build dari source tag DROPBEAR_<versi>
  local ver=$1
  [[ -x "$DROPBEAR_DIR/dropbear-${ver}" ]] && { log "dropbear ${ver} sudah ter-build"; return 0; }
  local sdir="$DROPBEAR_DIR/src"
  mkdir -p "$sdir"
  rm -rf "$sdir/dropbear-DROPBEAR_${ver}"
  log "dropbear build DROPBEAR_${ver} ..."
  curl -fsSL -m 180 "https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_${ver}.tar.gz" \
    | tar xz -C "$sdir" 2>/dev/null || { log "download/tar gagal"; return 1; }
  (
    cd "$sdir/dropbear-DROPBEAR_${ver}" || exit 1
    # source GitHub TIDAK termasuk ./configure — harus generation dulu (autotools)
    autoreconf -i >/dev/null 2>&1
    ./configure --disable-lastlog --disable-lastlog 2>/dev/null \
      || ./configure 2>/dev/null
    make -j"$(nproc)" PROGRAMS=dropbear >/dev/null 2>&1
  ) || { log "build gagal"; rm -rf "$sdir/dropbear-DROPBEAR_${ver}"; return 1; }
  if [[ -x "$sdir/dropbear-DROPBEAR_${ver}/dropbear" ]]; then
    cp "$sdir/dropbear-DROPBEAR_${ver}/dropbear" "$DROPBEAR_DIR/dropbear-${ver}"
    log "dropbear ${ver} build OK"
    return 0
  fi
  rm -rf "$sdir/dropbear-DROPBEAR_${ver}"
  log "dropbear ${ver} build GAGAL"
  return 1
}

do_dropbear() {
  # kelola versi dropbear: list / set <versi>
  #   mb-ssh2 dropbear            → tampilkan versi aktif + daftar versi tersedia
  #   mb-ssh2 dropbear set <v>    → switch: build versi <v>, pasang, restart service
  local action="${1:-}" ver="${2:-}" bin
  bin="${DROPBEAR_BIN:-/usr/local/bin/dropbear}"
  if [[ $action == list || -z $action ]]; then
    echo "=== DROPBEAR ==="
    echo "Aktif : $("$bin" -h 2>&1 | head -1 | grep -o 'Dropbear sshd [0-9.]*\|[0-9.]*' | head -1 || echo '?') ($bin)"
    echo ""
    echo "Tersedia (build lokal /opsi):"
    for v in 2019.78 2020.81 2022.83 2024.85 2025.89; do
      if [[ -x "$DROPBEAR_DIR/dropbear-$v" ]]; then
        echo "  • $v  (ter-build ✓)"
      else
        echo "  • $v"
      fi
    done
    echo ""
    echo "Ganti: mb-ssh2 dropbear set <versi>" 2>/dev/null || echo "Ganti: mb-ssh2 dropbear set <versi>"
    return 0
  fi
  if [[ $action == set ]]; then
    [[ -n $ver ]] || die "usage: mb-ssh2 dropbear set <versi>  (2019.78 / 2020.81 / 2022.83 / 2024.85 / 2025.89)"
    case "$ver" in
      2019.78|2020.81|2022.83|2024.85|2025.89) ;;
      *) die "versi tidak dikenal '$ver' — list: mb-ssh2 dropbear list" ;;
    esac
    _dropbear_build "$ver" || die "build ${ver} gagal"
    # pasang versi yang dipilih
    ln -sf "$DROPBEAR_DIR/dropbear-${ver}" /usr/local/bin/dropbear
    ln -sf "$DROPBEAR_DIR/dropbearmulti-${ver}" /usr/local/bin/dropbearmulti 2>/dev/null || true
    # "uninstall" versi lama: hapus binary non-aktif (kecuali yang dipakai), keep src
    local v
    for v in 2019.78 2020.81 2022.83 2024.85 2025.89; do
      [[ $v == "$ver" ]] && continue
      rm -f "$DROPBEAR_DIR/dropbear-$v" "$DROPBEAR_DIR/dropbearmulti-$v"
      rm -rf "$DROPBEAR_DIR/src/dropbear-DROPBEAR_${v}"
    done
    if command -v systemctl >/dev/null 2>&1; then
      systemctl restart dropbear-client 2>/dev/null || true
    fi
    log "dropbear switch ke ${ver} — versi lain dihapus, service direstart"
    return 0
  fi
  if [[ $action == status ]]; then
    "$bin" -h 2>&1 | head -3 || true
    return 0
  fi
  die "subcommand dropbear tidak dikenal: '$action' (list/set/status)"
}

_count_all() {
  # total akun per service: SSH (users.json) + VLESS/VMess/Trojan (Marzban db)
  # → baris "ssh=3 vless=5 vmess=2 trojan=1" (0 utk kosong; marzban absent → 0)
  python3 - "$USERS_JSON" /opt/marzban/db.sqlite3 <<'PY'
import json, os, sys
out = {}
try:
    out["ssh"] = len(json.load(open(sys.argv[1])))
except Exception:
    out["ssh"] = 0
# Marzban db → hitung per protocol
db = sys.argv[2]
if os.path.exists(db):
    try:
        import sqlite3
        con = sqlite3.connect(db)
        rows = con.execute("SELECT protocol, COUNT(*) FROM users GROUP BY protocol")
        for proto, cnt in rows:
            out[proto.strip().lower()] = cnt
        con.close()
    except Exception:
        pass
for proto in ("ssh", "vless", "vmess", "trojan"):
    print(f"{proto}={out.get(proto, 0)}", end=" ")
print()
PY
}

do_svcheck() {
  # 14) status service + versi dropbear aktif
  echo "=== CEK STATUS SERVICE ==="
  for svc in mb-edge dropbear-client stunnel mb-tgbot marzban; do
    if command -v systemctl >/dev/null 2>&1; then
      local act; act=$(systemctl is-active "$svc" 2>/dev/null || echo "n/a")
      local en; en=$(systemctl is-enabled "$svc" 2>/dev/null || echo "?")
      echo "  $svc  : $act (enabled=$en)"
    else
      echo "  $svc  : systemctl tidak ada"
    fi
  done
  # versi dropbear aktif
  local bin="${DROPBEAR_BIN:-/usr/local/bin/dropbear}"
  echo "  dropbear aktif : $("$bin" -h 2>&1 | head -1 || echo '?')"
  # versi tersedia lokal
  echo "  versi build    : $(ls /opt/dropbear/dropbear-* 2>/dev/null | grep -oE 'dropbear-[0-9.]+' | tr '\n' ' ')"
  # listen port SSH (22 admin, 22022 direct, 22443 tls)
  echo "  listen (ss):"
  (ss -ltnp 2>/dev/null | grep -E ":22022|:22443|:8000" | awk '{print "    "$4}' | head -6) || true
  echo "  client-info : $STATE_DIR (per-akun .txt)"
}

do_bot() {
  # set token bot telegram (+chat_id) lalu restart mb-tgbot
  #   mb-ssh2 bot <token> [chat_id]   (non-interaktif)
  #   mb-ssh2 bot                     (prompt interaktif)
  local tok="${1:-}" cid="${2:-}"
  if [[ -z $tok ]]; then
    echo "--- SET BOT TELEGRAM ---"
    echo "1) Buat bot: @BotFather → /newbot → salin token"
    echo "2) Chat id: kirim pesan ke bot → https://api.telegram.org/bot<TOKEN>/getUpdates"
    read -rp "TG_BOT_TOKEN [${TG_BOT_TOKEN:***}]: " tok; tok="${tok:-$TG_BOT_TOKEN}"
    read -rp "TG_CHAT_ID [${TG_CHAT_ID:-<kosong>}]: " cid; cid="${cid:-$TG_CHAT_ID}"
  fi
  [[ -n $tok ]] || die "token kosong"
  local who
  who=$(curl -s -m 10 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null | \
    python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print('@'+d['result']['username'] if d.get('ok') else 'GAGAL: '+str(d.get('description','?'))[:80])
except Exception:
    print('GAGAL cek (network?)')" 2>/dev/null)
  [[ $who == @* ]] || die "TG_BOT_TOKEN tidak valid ($who) — cek token dari @BotFather"
  [[ -z $cid ]] && cid="${TG_CHAT_ID:-}"
  _conf_set TG_BOT_TOKEN "$tok"
  [[ -n $cid ]] && _conf_set TG_CHAT_ID "$cid"
  log "bot tersimpan: $who (chat: ${cid:-<kosong>})"
  # restart bot (dan edge agar baca TG utk notif quota/multilogin)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now mb-tgbot 2>/dev/null && log "service mb-tgbot aktif" \
      || log "start mb-tgbot gagal — cek: systemctl status mb-tgbot"
    systemctl restart mb-edge 2>/dev/null && log "mb-edge di-restart (baca notif TG)" \
      || log "restart mb-edge gagal"
  fi
}

do_banner() {
  # edit /etc/issue.net (banner customer saat konek SSH) + restart dropbear
  #   mb-ssh2 banner            → nano editor
  #   mb-ssh2 banner <string>   → tulis langsung
  echo "--- SET BANNER (/etc/issue.net) ---"
  if [[ -n $1 ]]; then
    printf '%s\n' "$*" > /etc/issue.net
    log "banner ditulis: ${*:0:50}..."
  else
    command -v nano >/dev/null 2>&1 || { log "nano tidak ada — pakai cat/tee manual /etc/issue.net"; }
    # prompt per-baris (tanpa nano — lebih aman)
    echo "Masukkan baris banner (enter kosong = selesai):"
    > /etc/issue.net
    local line i=0
    while true; do
      read -rp "  L${i}: " line
      [[ -z $line ]] && break
      echo "$line" >> /etc/issue.net
      i=$((i+1))
    done
    [[ $i -eq 0 ]] && log "banner kosong (biarkan /etc/issue.net awal)?" 
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart dropbear-client 2>/dev/null && log "dropbear-client di-restart (banner baru aktif)" \
      || log "restart dropbear-client gagal"
  fi
  log "banner siap:"
  cat /etc/issue.net
}

do_menu() {
  local choice c u d
  while true; do
    local counts; counts="$(_count_all)"
    echo ""
    echo "================ MB-SSH MENU ================"
    echo " R2  : ${R2_REMOTE:-<belum diset>}  (${R2_PATH})"
    echo " Bot : ${TG_BOT_TOKEN:+tersambung${TG_CHAT_ID:+ (chat $TG_CHAT_ID)}}${TG_BOT_TOKEN:-<belum diset>}"
    echo " Back: ${BACKUP_INTERVAL:-0} (0 = tiap hari 03:03)"
    echo " Upd : ${REPO_URL:+sumber update ✓}${REPO_URL:-<belum set — setup>}"
    echo " Akun: $counts"
    echo "=============================================="
    echo " 1)  Tambah akun SSH"
    echo " 2)  Hapus akun SSH"
    echo " 3)  Perpanjang akun (hari)"
    echo " 4)  Daftar akun"
    echo " 5)  Detail akun + client-info"
    echo " 6)  Setup backup R2 + bot Telegram (wizard)"
    echo " 7)  Jadwal backup otomatis (menit/jam)"
    echo " 8)  Backup SEKARANG"
    echo " 9)  Restore dari R2"
    echo " 10) Status"
    echo " 11) Bantuan bot Telegram"
    echo " 12) Update script + auto-rollback"
    echo " 13) Ganti versi dropbear (2019.78 default, bebas pilih)"
    echo " 14) Cek status service (mb-edge/dropbear/stunnel/bot)"
    echo " 15) Set token bot telegram + notif (restart bot/edge)"
    echo " 16) Ganti domain node (validasi pointing + cert + restart stunnel)"
    echo " 17) Ganti banner /etc/issue.net (restart dropbear)"
    echo " 18) Lihat/reset API token (SSH edge) + token Marzban"
    echo " 19) Setup SlowDNS (aktif/nonaktif + domain + pubkey)"
    echo " 0)  Keluar"
    read -rp "Pilih [0-19]: " choice
    case $choice in
      1) read -rp "Username: " u
         read -rp "Durasi (hari, kosong=30): " d; d="${d:-30}"
         [[ -n $u ]] && do_add "$u" "$d" || log "batal — username kosong" ;;
      2) read -rp "Hapus user: " u
         read -rp "HAPUS $u? (y/N): " c
         [[ $c == [yY]* ]] && [[ -n $u ]] && do_del "$u" || echo "batal" ;;
      3) read -rp "User: " u
         read -rp "Tambah hari: " d
         [[ -n $u && -n $d ]] && do_set "$u" --add-days "$d" || echo "batal" ;;
      4) do_list ;;
      5) read -rp "User: " u
         [[ -n $u ]] && do_show "$u" ;;
      6) do_setup ;;
      7) echo "Format interval (masuk cron):"
         echo "  30m → tiap 30 menit    6j → tiap 6 jam    0 → tiap hari 03:03"
         read -rp "BACKUP_INTERVAL [${BACKUP_INTERVAL:-0}]: " iv; iv="${iv:-${BACKUP_INTERVAL:-0}}"
         python3 - "$iv" <<'PY'
import re, sys
iv = sys.argv[1].strip()
if iv in ("0", ""):
    print('BACKUP_INTERVAL="0"')
elif re.fullmatch(r'[1-9][0-9]*m', iv):
    n = int(iv[:-1]); assert 1 <= n <= 59, "menit 1-59"
    print(f'BACKUP_INTERVAL="{n}m"')
elif re.fullmatch(r'[1-9][0-9]*j', iv):
    h = int(iv[:-1]); assert 1 <= h <= 23, "jam 1-23"
    print(f'BACKUP_INTERVAL="{h}j"')
elif re.fullmatch(r'[1-9][0-9]*', iv):
    n = int(iv); assert 1 <= n <= 59, "menit 1-59"
    print(f'BACKUP_INTERVAL="{n}m"')
else:
    sys.exit("format salah — pakai 30m / 6j / 0")
PY
         if [[ $? -eq 0 ]]; then
           _conf_set BACKUP_INTERVAL "$iv"
           BACKUP_INTERVAL="$iv"
           apply_backup_cron
         fi ;;
      8) do_backup; _tg_notify "✅ Backup OK — $(date '+%d %b %Y %H:%M') — $(hostname)" ;;
      9) read -rp "RESTORE menimpa state + DB Marzban dari R2. Yakin? (y/N): " c
         [[ $c == [yY]* ]] && { do_restore; _tg_notify "✅ Restore OK — $(date '+%d %b %Y %H:%M') — $(hostname)"; } || echo "batal" ;;
      10) do_status ;;
      11) echo "Perintah bot: /backup  /restore  /status  /help"
          echo "(hanya chat dari TG_CHAT_ID yang diproses)" ;;
      12) do_update ;;
      13) do_dropbear ;;
      14) do_svcheck ;;
      15) do_bot ;;
      16) bash "$SRC_DIR/install/04-domain.sh" force ;;
      17) do_banner ;;
      18) echo "---"; do_apikey; echo ""; echo "--- Marzban ---"; do_marzban_token || true ;;
      19) do_slowdns ;;
      0) echo "bye"; break ;;
      *) echo "Pilihan tidak valid"; sleep 1 ;;
      esac
  done
}

cmd="${1:-help}"
shift || true
case $cmd in
  add)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 add <user> [days] [--udp] [--bw D/U] [--backend direct|tls] [--warp]"; do_add "$@" ;;
  del)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 del <user>"; do_del "$1" ;;
  set)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 set <user> [days] [--bw D/U]"; do_set "$@" ;;
  list)      do_list "$@" ;;
  show)      [[ -n ${1:-} ]] || die "usage: mb-ssh2 show <user> [--json]"; do_show "$1" "${2:-}" ;;
  apikey)     do_apikey "$@" ;;
  marzban-token) do_marzban_token "$@" ;;
  restore)   do_restore ;;
  status)    do_status ;;
  svcheck)   do_svcheck ;;
  set-domain) do_set_domain ;;
  set-token) do_set_token ;;
  set-banner) do_set_banner ;;
  setup)     do_setup "$@" ;;
  menu)      do_menu ;;
  backup-cron) apply_backup_cron ;;
  schedule)  do_schedule "$@" ;;
  update)    [[ ${1:-} == --check ]] && _update_check || do_update ;;
  set-domain) bash "$SRC_DIR/install/04-domain.sh" force ;;
  bot)       do_bot "$@" ;;
  banner)    do_banner "$@" ;;
  rollback)  do_rollback "$@" ;;
  login-check) do_login_check ;;
  dropbear)  do_dropbear "$@" ;;
  edge-list)   edge_ctl '{"cmd":"list"}' ;;
  help|*)    grep -E "^# " "$0" | head -18 ;;
esac


do_slowdns() {
  # Setup SlowDNS — aktif/nonaktif + domain + pubkey (disimpan di mb.conf)
  # SLOWDNS_ENABLED=1 → setiap akun SSH baru otomatis dpt blok SlowDNS di client-info.
  # Server slowdns di-install terpisah (install/05-slowdns.sh); di sini cuma config.
  echo "--- SETUP SLOWDNS ---"
  echo "Status: $([ "${SLOWDNS_ENABLED:-0}" == "1" ] && echo AKTIF || echo NONAKTIF)"
  echo "  Domain  : ${SLOWDNS_DOMAIN:-<kosong>}"
  echo "  Port    : ${SLOWDNS_PORT:-53}"
  echo "  Pubkey  : ${SLOWDNS_PUBKEY:+${SLOWDNS_PUBKEY:0:20}...}${SLOWDNS_PUBKEY:-<kosong>}"
  echo ""
  read -rp "Aktifkan SlowDNS untuk semua akun SSH? (y/N): " on
  case "${on,,}" in
    y|yes)
      read -rp "SlowDNS domain (mis. ns.domain.com): " dm
      dm="${dm:-$SLOWDNS_DOMAIN}"
      [[ -n $dm ]] || { log "domain kosong — batal"; return 1; }
      read -rp "UDP port [${SLOWDNS_PORT:-53}]: " pt; pt="${pt:-${SLOWDNS_PORT:-53}}"
      read -rp "Public key (/etc/mb-ssh2/slowdns.pubkey, enter=baca otomatis): " pk
      if [[ -z $pk && -f /etc/mb-ssh2/slowdns.pubkey ]]; then
        pk=$(tr -d '\r\n' < /etc/mb-ssh2/slowdns.pubkey)
      fi
      _conf_set SLOWDNS_ENABLED "1"
      _conf_set SLOWDNS_DOMAIN "$dm"
      _conf_set SLOWDNS_PORT "$pt"
      [[ -n $pk ]] && _conf_set SLOWDNS_PUBKEY "$pk"
      log "SlowDNS AKTIF: $dm:$pt (pubkey ${pk:+tersimpan}${pk:-BELUM})"
      if [[ -z $pk ]]; then
        echo "  !! Pubkey belum tersimpan. Baca dari server: cat /etc/mb-ssh2/slowdns.pubkey"
      fi
      ;;
    *)
      _conf_set SLOWDNS_ENABLED "0"
      log "SlowDNS NONAKTIF"
      ;;
  esac
  echo ""
  echo "Catatan:"
  echo " 1) Install server slowdns: bash install/05-slowdns.sh — binary & pubkey dari repo dist/slowdns/, dipasang otomatis saat run.sh"
  echo " 2) Binary: /usr/local/bin/mb-slowdns-server — unit: systemctl status mb-slowdns"
  echo " 3) Upstream slowdns = 127.0.0.1:22022 (dropbear) — sama dgn jalur SSH biasa."
  echo " 4) Limit IP & bandwidth TETAP berlaku."
}
