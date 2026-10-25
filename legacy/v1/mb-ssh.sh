#!/bin/bash
# mb-ssh — SSH companion untuk node Marzban
# Sinkronkan akun SSH (client) dengan user Marzban (VLESS/VMess/Trojan).
#
#用法:
#   mb-ssh add <username> [days]    buat akun SSH (days: 0 = tanpa expiry)
#   mb-ssh del <username>           hapus akun SSH
#   mb-ssh set <username> <days>    ubah expiry
#   mb-ssh list                     daftar (local + marzban)
#   mb-ssh sync                     reconcile: marzban → ssh (cron fallback)
#   mb-ssh token                    refresh token API Marzban
#   mb-ssh info                     status config/token
#   mb-ssh serve-webhook [port]     listener webhook Marzban (realtime sync)
#
# Config: /etc/mb-ssh.conf (sourced)

set -u

CONF="${MB_SSH_CONF:-/etc/mb-ssh.conf}"
if [[ -f $CONF ]]; then source $CONF; fi

# defaults (bisa di-override conf)
MB_API_BASE="${MB_API_BASE:-http://127.0.0.1:8000/api}"
MB_API_USER="${MB_API_USER:-admin}"
MB_API_PASS="${MB_API_PASS:-}"
SSH_PORT="${SSH_PORT:-443}"
USER_PREFIX="${USER_PREFIX:-}"
KEEP_EXPIRED_DAYS="${KEEP_EXPIRED_DAYS:-1}"
STATE_DIR="${STATE_DIR:-/var/lib/mb-ssh}"
NODE_IP="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

mkdir -p "$STATE_DIR"
USERS_JSON="$STATE_DIR/users.json"
TOKEN_FILE="$STATE_DIR/token"
[[ -f $USERS_JSON ]] || echo '{}' > "$USERS_JSON"

log() { echo "[mb-ssh $(date '+%F %T')] $*"; }
die() { echo "[mb-ssh] ERROR: $*" >&2; exit 1; }

json_get() { # json_get <json> <python-expr-on-d>
  echo "$1" | /usr/bin/python3 -c "
import sys, json
d = json.load(sys.stdin)
$2
" 2>/dev/null
}

# ---------- API Marzban ----------
api_token() {
  if [[ -f $TOKEN_FILE ]] && [[ $(($(date +%s) - $(stat -c %Y $TOKEN_FILE))) < 86400 ]]; then
    cat "$TOKEN_FILE"; return 0
  fi
  [[ -n $MB_API_PASS ]] || die "MB_API_PASS belum diset di $CONF"
  local resp
  resp=$(curl -s -m 10 -X POST "$MB_API_BASE/token" \
    -d "username=$MB_API_USER&password=$MB_API_PASS&scope=" \
    -H "Content-Type: application/x-www-form-urlencoded")
  local tok
  tok=$(json_get "$resp" "print(d.get('access_token',''))")
  [[ -n $tok ]] || die "gagal ambil token: $(echo "$resp" | head -c 200)"
  echo "$tok" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  cat "$TOKEN_FILE"
}

api() { # api <METHOD> <path> [json-body]
  local tok; tok=$(api_token)
  local body="${3:-}"
  if [[ -n $body ]]; then
    curl -s -m 15 -X "$1" "$MB_API_BASE$2" -H "Authorization: Bearer $tok" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -s -m 15 -X "$1" "$MB_API_BASE$2" -H "Authorization: Bearer $tok"
  fi
}

# ---------- state local ----------
state_get() { # state_get <user> → json entry
  /usr/bin/python3 -c "
import json
d = json.load(open('$USERS_JSON'))
print(json.dumps(d.get('$1', {})))
"
}
state_set() { # state_set <user> <json-entry>
  /usr/bin/python3 -c "
import json
d = json.load(open('$USERS_JSON'))
d['$1'] = $2
json.dump(d, open('$USERS_JSON','w'), indent=1)
"
}
state_del() {
  /usr/bin/python3 -c "
import json
d = json.load(open('$USERS_JSON'))
d.pop('$1', None)
json.dump(d, open('$USERS_JSON','w'), indent=1)
"
}

# ---------- core ops ----------
gen_pass() { tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12; }

sanitize() {
  local u="${1#"$USER_PREFIX"}"
  [[ $u =~ ^[a-z0-9_]{3,32}$ ]] || return 1
  echo "${USER_PREFIX}$u"
}

date_from_ts() { date -u -d "@$1" '+%Y-%m-%d'; }

do_add() { # do_add <user> <days>
  local user="$1" days="${2:-30}"
  id -u "$user" &>/dev/null && { log "$user sudah ada (update expiry via set)"; return 0; }
  local pass; pass=$(gen_pass)
  local now ts expire_date
  now=$(date +%s)
  if [[ $days -gt 0 ]]; then
    ts=$((now + days*86400))
    expire_date=$(date_from_ts $ts)
  else
    ts=0; expire_date=""
  fi
  useradd -m -s /bin/bash "$user" 2>/dev/null || die "useradd gagal untuk $user"
  echo "$user:$pass" | chpasswd
  [[ -n $expire_date ]] && usermod -e "$expire_date" "$user"
  state_set "$user" "{\"pass\":\"$pass\",\"expire_ts\":$ts,\"created\":$now,\"days\":$days}"
  write_client_info "$user"
  log "OK: $user (expiry: ${expire_date:-unlimited})"
}

write_client_info() {
  local user="$1"
  local entry; entry=$(state_get "$user")
  local pass exp; pass=$(json_get "$entry" "print(d.get('pass',''))")
  exp=$(json_get "$entry" "print(d.get('expire_ts') or 0)")
  local expstr="unlimited"; [[ ${exp:-0} -gt 0 ]] && expstr=$(date -u -d "@$exp" '+%F %T UTC')
  cat > "$STATE_DIR/client-$user.txt" <<EOF
Node        : $NODE_IP
SSH Port    : $SSH_PORT
User        : $user
Password    : $pass
Expire      : $expstr

Contoh tunnel (proxy local :7890 ke target):
ssh -p $SSH_PORT -L 7890:TARGET_HOST:PORT $user@$NODE_IP -N
EOF
  chmod 600 "$STATE_DIR/client-$user.txt"
}

do_del() {
  local user="$1"
  id -u "$user" &>/dev/null && userdel -r "$user" 2>/dev/null
  state_del "$user"
  rm -f "$STATE_DIR/client-$user.txt"
  log "deleted: $user"
}

do_set() { # do_set <user> <days>
  local user="$1" days="$2"
  id -u "$user" &>/dev/null || die "$user tidak ada"
  local ts expire_date="" now; now=$(date +%s)
  if [[ $days -gt 0 ]]; then
    ts=$((now + days*86400)); expire_date=$(date_from_ts $ts)
  else ts=0; fi
  [[ -n $expire_date ]] && usermod -e "$expire_date" "$user" || usermod -e "" "$user"
  local entry; entry=$(state_get "$user")
  entry=$(json_get "$entry" "d['expire_ts'] = $ts; d['days'] = $days; print(json.dumps(d))")
  state_set "$user" "$entry"
  write_client_info "$user"
  log "OK: $user expiry → ${expire_date:-unlimited}"
}

mb_list() {
  echo "=== LOCAL SSH ACCOUNTS ==="
  /usr/bin/python3 -c "
import json, datetime
d = json.load(open('$USERS_JSON'))
for u, v in sorted(d.items()):
    exp = v.get('expire_ts') or 0
    exps = 'unlimited' if exp == 0 else datetime.datetime.utcfromtimestamp(exp).strftime('%F')
    print(f\"  {u:<24} expire={exps}\")
"
  # marzban side
  local resp; resp=$(api GET /users)
  if echo "$resp" | head -c 1 | grep -q '{'; then
    echo "=== MARZBAN USERS ==="
    echo "$resp" | /usr/bin/python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
for u in d.get('users', []):
    exp = u.get('expire') or 0
    exps = 'unlimited' if exp == 0 else datetime.datetime.utcfromtimestamp(exp).strftime('%F')
    print(f\"  {u['username']:<24} status={u['status']:<8} expire={exps}\")
" 2>/dev/null || echo "  (gagal parse marzban resp)"
  else
    echo "=== MARZBAN: unreachable (${MB_API_BASE}) ==="
  fi
}

mb_sync() {
  # reconcile: marzban active → ssh ada + expiry match; expired/disabled → lock/hapus
  local resp; resp=$(api GET /users)
  echo "$resp" | head -c 1 | grep -q '{' || { log "sync skip: marzban unreachable"; return 1; }
  log "sync start"
  # build ssh users dari marzban
  echo "$resp" | /usr/bin/python3 -c "
import sys, json
d = json.load(sys.stdin)
for u in d.get('users', []):
    print(u['username'], u['status'], u.get('expire') or 0, sep='\t')
" | while IFS=$'\t' read -r mu status exp; do
      local cu; cu=$(sanitize "$mu") || continue
      case $status in
        active)
          if id -u "$cu" &>/dev/null; then
            # match expiry
            local cur_ts; cur_ts=$(json_get "$(state_get $cu)" "print(d.get('expire_ts') or 0)")
            if [[ ${cur_ts:-0} -ne ${exp:-0} ]]; then
              [[ $exp -gt 0 ]] && do_set "$cu" 0 && do_set "$cu" $(( (exp - $(date +%s)) / 86400 + 1 )) || usermod -e "" "$cu"
            fi
          else
            local days=0; [[ ${exp:-0} -gt $(date +%s) ]] && days=$(( (exp - $(date +%s)) / 86400 + 1 ))
            do_add "$cu" "$days"
          fi
          ;;
        expired|limited)
          if id -u "$cu" &>/dev/null; then
            local cur_ts; cur_ts=$(json_get "$(state_get $cu)" "print(d.get('expire_ts') or 0)")
            if [[ ${cur_ts:-0} -gt 0 && ${cur_ts} -le $(( $(date +%s) + KEEP_EXPIRED_DAYS*86400 )) ]]; then
              do_del "$cu"
            fi
          fi
          ;;
        disabled)
          id -u "$cu" &>/dev/null && usermod -L "$cu" 2>/dev/null && log "locked (disabled): $cu"
          ;;
      esac
    done
  # hapus orphans (ssh ada, marzban tidak, sudah expired lokal)
  /usr/bin/python3 -c "
import json, datetime, os
d = json.load(open('$USERS_JSON'))
now = datetime.datetime.now(datetime.timezone.utc).timestamp()
keep = $((KEEP_EXPIRED_DAYS * 86400))
for u, v in list(d.items()):
    exp = v.get('expire_ts') or 0
    if exp and exp + keep < now and not os.path.exists(f'/run/mb-ssh-keep-{u}'):
        print(u)
" | while read -r u; do do_del "$u"; done
  log "sync done"
}

mb_webhook() {
  # payload Marzban webhook: {"action": "user_created", "user": {...}}
  local payload action u status exp
  payload=$(cat)
  action=$(json_get "$payload" "print(d.get('action',''))")
  u=$(json_get "$payload" "print((d.get('user') or {}).get('username',''))")
  [[ -z $u ]] && { log "webhook: no username (action=$action)"; return 0; }
  local cu; cu=$(sanitize "$u") || return 0
  case $action in
    user_created|user_enabled)
      exp=$(json_get "$payload" "print((d.get('user') or {}).get('expire') or 0)")
      local days=0; [[ ${exp:-0} -gt $(date +%s) ]] && days=$(( (exp - $(date +%s)) / 86400 + 1 ))
      id -u "$cu" &>/dev/null || do_add "$cu" "$days"
      ;;
    user_updated)
      exp=$(json_get "$payload" "print((d.get('user') or {}).get('expire') or 0)")
      status=$(json_get "$payload" "print((d.get('user') or {}).get('status',''))")
      if [[ $status == "active" && -n ${exp:-} && ${exp:-0} -gt 0 ]]; then
        [[ $(id -u "$cu" 2>/dev/null) ]] && do_set "$cu" $(( (exp - $(date +%s)) / 86400 + 1 ))
      fi
      ;;
    user_deleted|user_disabled)
      [[ $action == user_disabled ]] && usermod -L "$cu" 2>/dev/null || do_del "$cu"
      ;;
    user_expired)
      do_del "$cu"
      ;;
    *) log "webhook: action tidak dikenali: $action" ;;
  esac
}

mb_serve_webhook() { # mb_serve_webhook [port]
  local port="${1:-8087}"
  log "webhook listener :$port (mb-ssh)"
  exec /usr/bin/python3 - "$port" "$USERS_JSON" <<'PYEOF'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[1])

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(ln)
        try:
            payload = json.loads(body)
            action = payload.get('action', '')
            user = (payload.get('user') or {}).get('username', '')
            print(f"[mb-ssh-webhook] {action} {user}", flush=True)
            import subprocess
            subprocess.run(['mb-ssh', 'webhook'], input=body, check=False, timeout=60)
        except Exception as e:
            print(f"[mb-ssh-webhook] ERR {e}", flush=True)
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'alive')
    def log_message(self, *a): pass

HTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
}

# ---------- dispatch ----------
cmd="${1:-help}"
shift || true
case $cmd in
  add)   [[ -n ${1:-} ]] || die "usage: mb-ssh add <username> [days]"; cu=$(sanitize "$1") || die "username invalid (a-z 0-9 _, 3-32 char)"; do_add "$cu" "${2:-30}" ;;
  del)   [[ -n ${1:-} ]] || die "usage: mb-ssh del <username>"; do_del "$(sanitize "$1")" ;;
  set)   [[ -n ${1:-} && -n ${2:-} ]] || die "usage: mb-ssh set <username> <days>"; do_set "$(sanitize "$1")" "$2" ;;
  list)  mb_list ;;
  sync)  mb_sync ;;
  token) api_token >/dev/null && log "token OK" ;;
  info)  echo "MB_API_BASE=$MB_API_BASE"; echo "SSH_PORT=$SSH_PORT"; echo "USER_PREFIX=$USER_PREFIX"; echo "KEEP_EXPIRED_DAYS=$KEEP_EXPIRED_DAYS"; echo "STATE_DIR=$STATE_DIR"; [[ -f $TOKEN_FILE ]] && echo "token: ada ($(stat -c %y $TOKEN_FILE | cut -d. -f1))" || echo "token: BELUM" ;;
  webhook) mb_webhook ;;
  serve-webhook) mb_serve_webhook "${1:-8087}" ;;
  help|*) grep -E "^#( |$)|用法" "$0" | head -16 ;;
esac
