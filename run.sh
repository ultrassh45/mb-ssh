#!/bin/bash
# mb-ssh — installer node VPN (Marzban) + SSH product (edge + dropbear + stunnel + udpgw)
#
# One-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ultrassh45/mb-ssh/main/run.sh)
# Lokal:
#   bash run.sh [--warp] [--no-marzban]
#
# Arsitektur:
#   Marzban        : VLESS/VMess/Trojan/SS  (port 443/80, panel :8000)
#   mb-edge        : CF port pool → backends SSH (hot, zero restart per-user)
#   dropbear       : 127.0.0.1:22022 (SSH Direct)
#   stunnel        : 127.0.0.1:22443 (SSH TLS)
#   badvpn-udpgw   : per-user instance (spawn on demand)

set -euo pipefail

# ---------- self-bootstrap (one-liner via curl → clone & re-exec) ----------
REPO_URL="${REPO_URL:-https://github.com/ultrassh45/mb-ssh.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$ROOT" != /opt/mb-ssh-src ]] && [[ ! -f "$ROOT/.git" && ! -d "$ROOT/.git" ]]; then
  # dijalankan lewat pipa curl (bukan clone lokal) → self-install repo
  SRC=/opt/mb-ssh-src
  if [[ ! -d "$SRC/.git" ]]; then
    command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }
    git clone -q --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$SRC"
  else
    git -C "$SRC" fetch -q origin "$REPO_BRANCH" && git -C "$SRC" reset -q --hard "origin/$REPO_BRANCH"
  fi
  exec bash "$SRC/run.sh" "$@"
fi

log() { echo -e "\033[1;32m[mb-ssh]\033[0m $*"; }
die() { echo -e "\033[1;31m[mb-ssh]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "jalankan sebagai root"
command -v python3 >/dev/null || die "python3 tidak ada"

WARP=0
MARZBAN=1
for a in "$@"; do
  case $a in
    --warp) WARP=1 ;;
    --no-marzban) MARZBAN=0 ;;
    -h|--help) grep -E "^#( |$)" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "arg tidak dikenal: $a (pakai --help)" ;;
  esac
done

# ---------- 1. VPN: Marzban ----------
if [[ $MARZBAN -eq 1 ]]; then
  log "Step 1/4: Marzban (VLESS/VMess/Trojan)..."
  bash "$ROOT/install/01-marzban.sh"
else
  log "Step 1/4: Marzban — skip (--no-marzban)"
fi

# ---------- 2. SSH stack ----------
log "Step 2/4: SSH stack (dropbear + stunnel + badvpn + rclone)..."
bash "$ROOT/install/02-ssh-stack.sh" "$WARP"
bash "$ROOT/install/03-hardening.sh"

# ---------- 3. Deploy runtime + config + systemd ----------
log "Step 3/4: Deploy runtime..."
install -m 755 "$ROOT/runtime/mb-edge.py"        /usr/local/bin/mb-edge
install -m 755 "$ROOT/runtime/mb-ssh2.sh"        /usr/local/bin/mb-ssh2
install -m 755 "$ROOT/runtime/mb-ssh2-cleanup.sh" /usr/local/bin/mb-ssh2-cleanup
install -m 755 "$ROOT/runtime/mb-tgbot.py"       /usr/local/bin/mb-tgbot
mkdir -p /etc/mb-ssh2 /var/lib/mb-ssh /run/mb-ssh

# config (jangan timpa yang sudah ada = idempotent upgrade)
[[ -f /etc/mb-ssh2/edge.json ]] || install -m 644 "$ROOT/config/edge.json" /etc/mb-ssh2/edge.json
[[ -f /etc/mb-ssh2/mb.conf ]]   || install -m 644 "$ROOT/config/mb.conf"   /etc/mb-ssh2/mb.conf
# domain auto-detect saat pertama
if grep -q '^DOMAIN=""' /etc/mb-ssh2/mb.conf 2>/dev/null; then
  DOM=$(hostname -I 2>/dev/null | awk '{print $1}')
  sed -i "s/^DOMAIN=\"\"/DOMAIN=\"$DOM\"/" /etc/mb-ssh2/mb.conf
fi
# API token (generate sekali) + flag warp di edge.json
python3 - "$WARP" <<'PY'
import json, os, re, secrets, sys
p = "/etc/mb-ssh2/edge.json"
d = json.load(open(p))
api = d.setdefault("api", {"port": 8499, "allow_ip": []})
tok = api.get("token", "")
if not tok or tok == "GANTI_DENGAN_TOKEN_DARI_RUN_SH":
    api["token"] = secrets.token_hex(32)
    print(f"API_TOKEN={api['token']}")
d["warp"] = (sys.argv[1] == "1")
json.dump(d, open(p, "w"), indent=2)
PY

# MOTD global (branding saat login SSH)
source /etc/mb-ssh2/mb.conf
cat > /etc/motd <<EOF
+----------------------------------------------------+
|  $DOMAIN - SSH & WARP Server                       |
|  Terima kasih sudah berlangganan.                  |
|  Support : ${SUPPORT:-zxpedia}
+----------------------------------------------------+
EOF
log "[ok] /etc/motd (branding)"

# Banner issue.net — tampil ke CUSTOMER saat konek SSH/VPN (sebelum login)
cat > /etc/issue.net <<EOF
=============================================================
  ${DOMAIN} — Terima kasih telah menggunakan layanan VPN kami.
  Support : ${SUPPORT:-zxpedia}
=============================================================
EOF
log "[ok] /etc/issue.net (banner customer)"

for unit in mb-edge dropbear-client mb-tgbot; do
  install -m 644 "$ROOT/systemd/$unit.service" "/etc/systemd/system/$unit.service"
done
systemctl daemon-reload
systemctl enable --now dropbear-client.service stunnel.service mb-edge.service
# bot TG: enable cuma kalau sudah ada token (idempotent upgrade)
if grep -Eq '^TG_BOT_TOKEN=".{5,}"' /etc/mb-ssh2/mb.conf 2>/dev/null; then
  systemctl enable --now mb-tgbot.service
  log "[ok] mb-tgbot aktif (token sudah ada di mb.conf)"
fi
sleep 1

# ---------- 4. Cron + verifikasi ----------
log "Step 4/4: Cron cleanup + verify..."
if ! crontab -l 2>/dev/null | grep -q "mb-ssh2-cleanup"; then
  (crontab -l 2>/dev/null; echo "17 4 * * * /usr/local/bin/mb-ssh2-cleanup >> /var/log/mb-ssh2-cleanup.log 2>&1") | crontab -
fi
# cron backup: idempotent — tulis ulang baris sesuai BACKUP_INTERVAL di mb.conf
/usr/local/bin/mb-ssh2 backup-cron

echo
echo "============================================================"
echo " NODE SIAP"
echo "   Marzban : http://\$(hostname -I | awk '{print \$1}'):8000"
echo "   SSH     : mb-ssh2 (CLI)"
echo "
 LANGKAH MANUAL:
   1. Panel Marzban: bikin admin + inbound (VLESS/VMess/Trojan, port 443/80)
   2. Cloudflare: proxy semua port pool + 443/80 di domain node
      (lihat PORT_POOL di /etc/mb-ssh2/mb.conf)
   3. Test akun SSH:
      mb-ssh2 add budi 30 --udp --bw 100/50 --quota 50
      cat /var/lib/mb-ssh/client-budi.txt
   4. API node (untuk panel/ultrassh):
      http://\$(hostname -I | awk '{print \$1}'):8499/v1/health
      header: Authorization: Bearer <API_TOKEN di atas / edge.json>
      simpan token di panel (ProxyNode.api_token), TIDAK akan tampil lagi
   5. Backup + bot Telegram (disarankan): jalankan:
      mb-ssh2 setup    # wizard: set R2 (rclone) + token bot @BotFather
      atau: mb-ssh2 menu — backup/restore/status dari terminal
      Setelah itu kirim /backup ke bot Telegram untuk backup on-demand.
   6. Update node (nanti): git pull + jalankan ulang: bash run.sh
============================================================"
