#!/bin/bash
# node-init — bootstrap node Marzban + SSH companion di VPS fresh
# Jalankan sebagai root:  bash node-init.sh
#
# Steps:
#  1. Install Marzban (official one-liner, includes Xray core)
#  2. Deploy mb-ssh.sh ke /usr/local/bin + conf
#  3. Cron sync (fallback) + webhook service (realtime)
#  4. Print langkah manual (admin panel + set conf)

set -eu
export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n\033[1;32m[node-init]\033[0m $*"; }

[[ $EUID -eq 0 ]] || { echo "jalankan sebagai root"; exit 1; }

# ---------- 1. Marzban ----------
if [[ -d /opt/marzban ]]; then
  log "Marzban sudah ada di /opt/marzban — skip install"
else
  log "Install Marzban (official one-liner)..."
  curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o /tmp/marzban.sh
  bash /tmp/marzban.sh @ install
  rm -f /tmp/marzban.sh
fi

# ---------- 2. Deploy companion ----------
log "Deploy mb-ssh..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 755 "$SCRIPT_DIR/mb-ssh.sh" /usr/local/bin/mb-ssh
mkdir -p /var/lib/mb-ssh

if [[ ! -f /etc/mb-ssh.conf ]]; then
  cat > /etc/mb-ssh.conf <<'CONF'
# /etc/mb-ssh.conf — konfigurasi mb-ssh (SSH companion Marzban)
# API Marzban (default port backend 8000)
MB_API_BASE="http://127.0.0.1:8000/api"
MB_API_USER="admin"
MB_API_PASS=""            # ISI SETELAH bikin admin di panel Marzban (user API)
SSH_PORT="443"            # port SSH untuk client (pastikan sshd listen di sini)
USER_PREFIX="vpn_"        # client ssh = vpn_<username-marzban>
KEEP_EXPIRED_DAYS="1"     # hapus akun SSH N hari setelah expiry
NODE_IP=""                # kosong = auto-detect public IP pertama
CONF
  chmod 600 /etc/mb-ssh.conf
  log "Conf dibuat: /etc/mb-ssh.conf (ISI MB_API_PASS!)"
fi

# ---------- 3. SSHD port 443 (idempotent) ----------
if ! grep -qE "^\s*Port\s+443" /etc/ssh/sshd_config 2>/dev/null; then
  # pakai drop-in supaya tidak merusak sshd_config asli
  cat > /etc/ssh/sshd_config.d/99-client-port.conf <<'EOF'
Port 443
EOF
  log "sshd: tambahkan Port 443 (drop-in 99-client-port.conf)"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  log "sshd: Port 443 sudah ada"
fi

# ---------- 4. Cron sync fallback ----------
if ! crontab -l 2>/dev/null | grep -q "mb-ssh sync"; then
  (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/mb-ssh sync >> /var/log/mb-ssh-sync.log 2>&1") | crontab -
  log "Cron: sync tiap 5 menit"
fi

# ---------- 5. Webhook service (realtime sync) ----------
cat > /etc/systemd/system/mb-ssh-webhook.service <<'UNIT'
[Unit]
Description=mb-ssh webhook listener (Marzban realtime sync)
After=network.target

[Service]
ExecStart=/usr/local/bin/mb-ssh serve-webhook 8087
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now mb-ssh-webhook.service 2>/dev/null || log "warning: webhook service belum start (normal kalau marzban belum jalan)"

# ---------- 6. Print instruksi ----------
cat <<'END'

============================================================
 NODE INIT SELESAI — LANGKAH MANUAL:
 1. Buka panel Marzban:  http://<IP_NODE>:8000  (port bisa beda, cek log)
    Login user: admin / pass dari output install (atau /opt/marzban)
 2. Buat user API (atau pakai admin):
    isi /etc/mb-ssh.conf  →  MB_API_PASS="..."
 3. Set webhook di panel Marzban:
    URL   : http://127.0.0.1:8087/
    (realtime sync; cron 5 menit tetap jalan sebagai fallback)
 4. Test:  mb-ssh info && mb-ssh sync
 5. Buat user di Marzban (VLESS/VMess/Trojan) → akun SSH client
    otomatis muncul (prefix vpn_). Ambil kredensial:
      cat /var/lib/mb-ssh/client-vpn_<user>.txt
============================================================
END
