#!/bin/bash
# mb-ssh2-cleanup.sh — hapus akun SSH expired (cron 04:17)
CONF="${MB_SSH_CONF:-/etc/mb-ssh2/mb.conf}"
USERS_JSON="${MB_SSH_USERS:-/var/lib/mb-ssh/users.json}"
[[ -f $CONF ]] && source "$CONF"
NOW=$(date +%s)
python3 - "$USERS_JSON" "$NOW" <<'PY'
import json, sys, subprocess
p, now = sys.argv[1], int(sys.argv[2])
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)
for u in [x for x, v in d.items() if v.get("expire_ts") and v["expire_ts"] <= now]:
    print(f"expired: {u}")
    subprocess.run(["/usr/local/bin/mb-ssh2", "del", u], capture_output=True)
PY
