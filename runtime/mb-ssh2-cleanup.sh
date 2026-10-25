#!/bin/bash
# mb-ssh2-cleanup.sh — proses akun expired (cron 04:17)
# AUTO_DELETE_EXPIRED=1 (default) : hapus akun expired
# AUTO_DELETE_EXPIRED=0           : TIDAK hapus — akun tetap ada (sudah di-lock
#                                   edge dengan blocked="expired"), bisa di-extend
CONF="${MB_SSH_CONF:-/etc/mb-ssh2/mb.conf}"
USERS_JSON="${MB_SSH_USERS:-/var/lib/mb-ssh/users.json}"
MB2_BIN="${MB_SSH2_BIN:-/usr/local/bin/mb-ssh2}"
[[ -f $CONF ]] && source "$CONF"
AUTO_DELETE_EXPIRED="${AUTO_DELETE_EXPIRED:-1}"
NOW=$(date +%s)
python3 - "$USERS_JSON" "$NOW" "$AUTO_DELETE_EXPIRED" "$MB2_BIN" <<'PY'
import json, sys, subprocess
p, now, autodel, bin2 = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)
for u in [x for x, v in d.items() if v.get("expire_ts") and v["expire_ts"] <= now]:
    if autodel == "1":
        print(f"expired → del: {u}")
        subprocess.run([bin2, "del", u], capture_output=True)
    else:
        print(f"expired (keep — AUTO_DELETE_EXPIRED=0): {u}")
PY
