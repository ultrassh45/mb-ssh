#!/bin/bash
# mb-ssh v2 — SSH product manager (standalone, tidak coupled Marzban)
# Per-user: akun SSH (dropbear) + port CF dedicated + bandwidth limit +
#           udpgw opsional + WARP opsional
#
#   mb-ssh2 add <user> [days] [--udp] [--bw DOWN/UP] [--backend direct|tls] [--warp]
#   mb-ssh2 del <user>
#   mb-ssh2 set <user> [days] [--bw DOWN/UP] [--port P]
#   mb-ssh2 list
#   mb-ssh2 show <user>
#   mb-ssh2 edge-list / edge-add / edge-remove  (raw edge control)
#
# Config: /etc/mb-ssh2/edge.json + /etc/mb-ssh2/mb.conf
# State : /var/lib/mb-ssh/users.json

set -u

CONF_DIR=/etc/mb-ssh2
CONF="$CONF_DIR/mb.conf"
[[ -f $CONF ]] && source "$CONF"

EDGE_CFG="${EDGE_CFG:-$CONF_DIR/edge.json}"
EDGE_CTL="${EDGE_CTL:-/run/mb-ssh/edge.sock}"
STATE_DIR="${STATE_DIR:-/var/lib/mb-ssh}"
USERS_JSON="$STATE_DIR/users.json"
BADVPN_BIN="${BADVPN_BIN:-/usr/local/bin/badvpn-udpgw}"
BADVPN_PORT_BASE="${BADVPN_PORT_BASE:-17000}"
DROPBEAR_PORT="${DROPBEAR_PORT:-22022}"
STUNNEL_PORT="${STUNNEL_PORT:-22443}"
WARP_IF="${WARP_IF:-warp}"
NODE_IP="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
DOMAIN="${DOMAIN:-$NODE_IP}"

mkdir -p "$STATE_DIR"
[[ -f $USERS_JSON ]] || echo '{}' > "$USERS_JSON"

log() { echo "[mb-ssh2 $(date '+%F %T')] $*"; }
die() { echo "[mb-ssh2] ERROR: $*" >&2; exit 1; }

# pool port CF (alternate; 80/443 = Marzban, 22 = admin)
PORT_POOL="${PORT_POOL:-8080 8880 2052 2082 2086 2095 2053 2083 2087 2096 8443}"

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

udpgw_port_for() { echo $(( BADVPN_PORT_BASE + $(id -u "$1") % 500 )); }

spawn_udpgw() { # spawn_udpgw <user> <localport>
  local user="$1" lp="$2"
  [[ -x $BADVPN_BIN ]] || { log "badvpn binary tidak ada ($BADVPN_BIN) — skip udpgw"; return 1; }
  # kill lama
  pkill -f "badvpn-udpgw.*$lp" 2>/dev/null && sleep 0.3
  setsid $BADVPN_BIN --listen-addr "127.0.0.1:$lp" --max-clients 32 \
    --max-packets-per-connection 8 >/dev/null 2>&1 < /dev/null &
  sleep 0.3
  pgrep -f "badvpn-udpgw.*$lp" >/dev/null || { log "udpgw gagal start :$lp"; return 1; }
  log "udpgw $user :$lp"
}

kill_udpgw() { pkill -f "badvpn-udpgw.*$1" 2>/dev/null; }

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
  local pass port pexp bwd bwu udp wpt
  pass=$(jget "$user" "e.get('pass','')")
  port=$(jget "$user" "e.get('port','')")
  pexp=$(jget "$user" "e.get('expire_ts',0)")
  bwd=$(jget "$user" "e.get('bw_down_mbps',0)")
  bwu=$(jget "$user" "e.get('bw_up_mbps',0)")
  udp=$(jget "$user" "e.get('udpgw',{}).get('port','')")
  wpt=$(jget "$user" "e.get('udpgw',{}).get('warp_port','')")
  local expstr="unlimited"; [[ ${pexp:-0} -gt 0 ]] && expstr=$(date -u -d "@$pexp" '+%F %T UTC')
  cat > "$STATE_DIR/client-$user.txt" <<EOF
Node        : $DOMAIN
User        : $user
Password    : $pass
Expire      : $expstr
SSH Port    : $port      (dedicated, via Cloudflare)
Bandwidth   : ${bwd}M down / ${bwu}M up
EOF
  [[ -n $udp ]] && cat >> "$STATE_DIR/client-$user.txt" <<EOF
UDPGW Port  : $udp      (dedicated, via Cloudflare)
EOF
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
}

# ---------- ops ----------
do_add() {
  local user="$1" days="${2:-30}" udp=0 bwd=100 bwu=50 backend=direct warp=0
  shift $(( $# >= 2 ? 2 : $# )) || true
  # parse flags (sisa arg)
  while [[ $# -gt 0 ]]; do case "$1" in
    --udp) udp=1;; --warp) warp=1;;
    --bw) local bw="${2:?--bw DOWN/UP}"; IFS=/ read -r bwd bwu <<< "$bw"; shift;;
    --backend) backend="${2:?}"; shift;;
  esac; shift; done

  id -u "$user" &>/dev/null && die "$user sudah ada"
  local pass port pexp now
  pass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)
  port=$(pick_port) || die "port pool habis (PORT_POOL)"
  now=$(date +%s)
  [[ $days -gt 0 ]] && pexp=$((now + days*86400)) || pexp=0

  useradd -m -s /bin/bash "$user" || die "useradd gagal"
  echo "$user:$pass" | chpasswd
  [[ $pexp -gt 0 ]] && usermod -e "$(date -u -d "@$pexp" '+%Y-%m-%d')" "$user"

  local backend_addr="127.0.0.1:$DROPBEAR_PORT"
  [[ $backend == tls ]] && backend_addr="127.0.0.1:$STUNNEL_PORT"

  local spec="{\"cmd\":\"add\",\"user\":\"$user\",\"port\":$port,\"backend\":\"$backend_addr\",\"bw_down_mbps\":$bwd,\"bw_up_mbps\":$bwu"
  local lp="" udpport=""
  if [[ $udp -eq 1 ]]; then
    udpport=$(pick_port) || die "port pool habis untuk udpgw"
    lp=$(udpgw_port_for "$user")
    if ! spawn_udpgw "$user" "$lp"; then udp=0; fi
    [[ $udp -eq 1 ]] && spec="$spec,\"udpgw\":{\"port\":$udpport,\"target\":\"127.0.0.1:$lp\"}"
  fi
  spec="$spec}"

  edge_alive || die "mb-edge tidak jalan (systemctl start mb-edge)"
  local resp; resp=$(edge_ctl "$spec")
  case "$resp" in
    ok) ;;
    *) jdel "$user"; userdel -r "$user" 2>/dev/null; die "edge add gagal: $resp";;
  esac

  [[ $warp -eq 1 ]] && warp_rule_add "$user" || true

  local udp_json=""
  [[ $udp -eq 1 ]] && udp_json=",\"udpgw\":{\"port\":$udpport,\"target\":\"127.0.0.1:$lp\"}"
  jset "$user" "{\"pass\":\"$pass\",\"port\":$port,\"backend\":\"$backend\",\"expire_ts\":$pexp,\"days\":$days,\"bw_down_mbps\":$bwd,\"bw_up_mbps\":$bwu,\"created\":$now,\"warp\":$warp$udp_json}"
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
  if [[ -n $(jget "$user" "e.get('udpgw',{}).get('target','')") ]]; then
    local lp; lp=$(jget "$user" "e.get('udpgw',{}).get('target','').split(':')[-1]")
    kill_udpgw "$lp"
  fi
  warp_rule_del "$user"
  id -u "$user" &>/dev/null && userdel -r "$user" 2>/dev/null
  jdel "$user"
  rm -f "$STATE_DIR/client-$user.txt"
  log "deleted: $user"
}

do_set() {
  local user="$1"; shift || true
  local days="" bw="" port=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --bw) bw="${2:?}"; shift;;
    --port) port="${2:?}"; shift;;
    *) days="$1";;
  esac; shift; done
  id -u "$user" &>/dev/null || die "$user tidak ada"
  local now; now=$(date +%s)
  if [[ -n $days ]]; then
    local pexp; [[ $days -gt 0 ]] && pexp=$((now + days*86400)) || pexp=0
    [[ $pexp -gt 0 ]] && usermod -e "$(date -u -d "@$pexp" '+%Y-%m-%d')" "$user" || usermod -e "" "$user"
    jget "$user" "e.update({'expire_ts':$pexp,'days':$days})" >/dev/null
    python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'expire_ts':$pexp,'days':$days})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
  fi
  if [[ -n $bw ]]; then
    local bwd bwu; IFS=/ read -r bwd bwu <<< "$bw"
    edge_ctl "{\"cmd\":\"setbw\",\"user\":\"$user\",\"bw_down_mbps\":$bwd,\"bw_up_mbps\":$bwu}"
    python3 -c "
import json
d=json.load(open('$USERS_JSON'))
d['$user'].update({'bw_down_mbps':$bwd,'bw_up_mbps':$bwu})
json.dump(d,open('$USERS_JSON','w'),indent=1)
"
  fi
  write_client_info "$user"
  log "set OK: $user"
}

do_list() {
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

cmd="${1:-help}"
shift || true
case $cmd in
  add)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 add <user> [days] [--udp] [--bw D/U] [--backend direct|tls] [--warp]"; do_add "$@" ;;
  del)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 del <user>"; do_del "$1" ;;
  set)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 set <user> [days] [--bw D/U]"; do_set "$@" ;;
  list)      do_list ;;
  show)      [[ -n ${1:-} ]] || die "usage: mb-ssh2 show <user>"; cat "$STATE_DIR/client-$1.txt" 2>/dev/null || die "tidak ada" ;;
  edge-list)   edge_ctl '{"cmd":"list"}' ;;
  help|*)    grep -E "^# " "$0" | head -14 ;;
esac
