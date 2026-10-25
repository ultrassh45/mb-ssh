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
#   mb-ssh2 edge-list / edge-add / edge-remove  (raw edge control)
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
BADVPN_BIN="${BADVPN_BIN:-/usr/local/bin/badvpn-udpgw}"
BADVPN_PORT_BASE="${BADVPN_PORT_BASE:-17000}"
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
  qta=$(jget "$user" "e.get('quota_gb',0)")
  local qstr="unlimited"; [[ ${qta:-0} -gt 0 ]] && qstr="${qta}GB (lifetime)"
  local expstr="unlimited"; [[ ${pexp:-0} -gt 0 ]] && expstr=$(date -u -d "@$pexp" '+%F %T UTC')
  cat > "$STATE_DIR/client-$user.txt" <<EOF
Node        : $DOMAIN
User        : $user
Password    : $pass
Expire      : $expstr
SSH Port    : $port      (dedicated, via Cloudflare)
Bandwidth   : ${bwd}M down / ${bwu}M up
Quota       : $qstr
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
  write_motd "$user"
}

# ---------- server message (MOTD) per-user ----------
write_motd() {
  local user="$1"
  local port pexp bwd bwu qta expstr qstr
  port=$(jget "$user" "e.get('port','')")
  pexp=$(jget "$user" "e.get('expire_ts',0)")
  bwd=$(jget "$user" "e.get('bw_down_mbps',0)")
  bwu=$(jget "$user" "e.get('bw_up_mbps',0)")
  qta=$(jget "$user" "e.get('quota_gb',0)")
  qstr="unlimited"; [[ ${qta:-0} -gt 0 ]] && qstr="${qta}GB"
  expstr="unlimited"; [[ ${pexp:-0} -gt 0 ]] && expstr=$(date -u -d "@$pexp" '+%F %T UTC')
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
|  Bandwidth: ${bwd}M down / ${bwu}M up
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
  local user="$1" days="${2:-30}" udp=0 bwd=100 bwu=50 backend=direct warp=0 quota=0
  shift $(( $# >= 2 ? 2 : $# )) || true
  # parse flags (sisa arg)
  while [[ $# -gt 0 ]]; do case "$1" in
    --udp) udp=1;; --warp) warp=1;;
    --bw) local bw="${2:?--bw DOWN/UP}"; IFS=/ read -r bwd bwu <<< "$bw"; shift;;
    --backend) backend="${2:?}"; shift;;
    --quota) quota="${2:?--quota GB}"; shift;;
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
  spec="$spec,\"quota_gb\":$quota,\"expire_ts\":$pexp}"

  edge_alive || die "mb-edge tidak jalan (systemctl start mb-edge)"
  local resp; resp=$(edge_ctl "$spec")
  case "$resp" in
    ok) ;;
    *) jdel "$user"; userdel -r "$user" 2>/dev/null; die "edge add gagal: $resp";;
  esac

  [[ $warp -eq 1 ]] && warp_rule_add "$user" || true

  local udp_json=""
  [[ $udp -eq 1 ]] && udp_json=\",\"udpgw\":{\"port\":$udpport,\"target\":\"127.0.0.1:$lp\"}\"
  jset "$user" "{\"pass\":\"$pass\",\"port\":$port,\"backend\":\"$backend\",\"expire_ts\":$pexp,\"days\":$days,\"bw_down_mbps\":$bwd,\"bw_up_mbps\":$bwu,\"created\":$now,\"warp\":$warp,\"quota_gb\":$quota$udp_json}"
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
  local days="" bw="" port="" adays="" quota="" unblock=0 rquota=0 warpflag="" pexp=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --bw) bw="${2:?}"; shift;;
    --port) port="${2:?}"; shift;;
    --add-days) adays="${2:?}"; shift;;
    --quota) quota="${2:?}"; shift;;
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
  if [[ -n $bw || -n $quota || -n $pexp || $unblock -eq 1 || $rquota -eq 1 ]]; then
    local spec
    spec=$(python3 -c "
import json
d = {'cmd': 'setbw', 'user': '$user'}
$([[ -n $bw ]] && echo "d['bw_down_mbps'] = $bwd
d['bw_up_mbps'] = $bwu")
$([[ -n $quota ]] && echo "d['quota_gb'] = $quota")
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

cmd="${1:-help}"
shift || true
case $cmd in
  add)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 add <user> [days] [--udp] [--bw D/U] [--backend direct|tls] [--warp]"; do_add "$@" ;;
  del)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 del <user>"; do_del "$1" ;;
  set)       [[ -n ${1:-} ]] || die "usage: mb-ssh2 set <user> [days] [--bw D/U]"; do_set "$@" ;;
  list)      do_list "$@" ;;
  show)      [[ -n ${1:-} ]] || die "usage: mb-ssh2 show <user> [--json]"; do_show "$1" "${2:-}" ;;
  backup)    do_backup ;;
  restore)   do_restore ;;
  edge-list)   edge_ctl '{"cmd":"list"}' ;;
  help|*)    grep -E "^# " "$0" | head -14 ;;
esac
