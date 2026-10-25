#!/bin/bash
# node-init2 — bootstrap node: Marzban (VPN) + mb-ssh v2 (SSH product)
# Jalankan sebagai root di VPS fresh:  bash node-init2.sh [--warp]
#
# Stack:
#   Marzban  → VLESS/VMess/Trojan/SS (port 443/80 via xray, panel :8000)
#   mb-edge  → CF port pool alternate → backends SSH (hot, zero restart)
#   dropbear → 127.0.0.1:22022 (SSH Direct)
#   stunnel  → 127.0.0.1:22443 (SSH TLS)
#   badvpn   → udpgw per-user (spawn on demand)
#   WARP     → optional outbound (flag --warp)

set -eu
export DEBIAN_FRONTEND=noninteractive
WARP=0
[[ "${1:-}" == "--warp" ]] && WARP=1

log() { echo -e "\n\033[1;32m[node-init2]\033[0m $*"; }
[[ $EUID -eq 0 ]] || { echo "jalankan sebagai root"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 1. Marzban ----------
if [[ -d /opt/marzban ]]; then
  log "Marzban sudah ada — skip"
else
  log "Install Marzban (official one-liner, includes Xray)..."
  curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o /tmp/marzban.sh
  bash /tmp/marzban.sh @ install
  rm -f /tmp/marzban.sh
fi

# ---------- 2. Dependensi SSH ----------
log "Install dropbear + stunnel..."
apt-get update -qq
apt-get install -y -qq dropbear stunnel4 >/dev/null

# ---------- 3. badvpn binary ----------
log "Download badvpn-udpgw (prebuilt)..."
ARCH=$(uname -m)
case $ARCH in x86_64) BA=amd64;; aarch64) BA=arm64;; *) echo "arch $ARCH tidak didukung"; exit 1;; esac
if [[ ! -x /usr/local/bin/badvpn-udpgw ]]; then
  # prebuilt dari repo autoscript (dist prebuilt, amd64/arm64)
  curl -sL "https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/opt/badvpn/dist/badvpn-udpgw-linux-$BA" \
    -o /usr/local/bin/badvpn-udpgw
  chmod +x /usr/local/bin/badvpn-udpgw
  /usr/local/bin/badvpn-udpgw 2>&1 | head -1 || true
fi

# ---------- 4. dropbear config (127.0.0.1 only) ----------
log "Setup dropbear 127.0.0.1:22022..."
sed -i 's/^#?LISTEN_PORT=.*/LISTEN_PORT=22022/' /etc/default/dropbear 2>/dev/null
echo "LISTEN_PORT=22022" >> /etc/default/dropbear
grep -q "^NO_START=" /etc/default/dropbear && sed -i 's/^NO_START=.*/NO_START=1/' /etc/default/dropbear
cat > /etc/systemd/system/dropbear-client.service <<'EOF'
[Unit]
Description=Dropbear SSH (client) 127.0.0.1:22022
After=network.target

[Service]
ExecStart=/usr/sbin/dropbear -F -p 127.0.0.1:22022
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now dropbear-client.service

# ---------- 5. stunnel config (127.0.0.1:22443 → 22022) ----------
log "Setup stunnel 127.0.0.1:22443..."
mkdir -p /var/lib/stunnel
# self-signed cert (client pakai trust-on-first-use / import cert)
if [[ ! -f /etc/mb-ssh2/cert.pem ]]; then
  mkdir -p /etc/mb-ssh2
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/mb-ssh2/key.pem -out /etc/mb-ssh2/cert.pem \
    -subj "/CN=ssh-node" 2>/dev/null
fi
cat > /etc/stunnel/mb-ssh.conf <<'EOF'
[client-ssh]
accept = 127.0.0.1:22443
connect = 127.0.0.1:22022
cert = /etc/mb-ssh2/cert.pem
key = /etc/mb-ssh2/key.pem
EOF
systemctl enable stunnel
systemctl restart stunnel

# ---------- 6. Deploy mb-edge + config ----------
log "Deploy mb-edge..."
install -m 755 "$SCRIPT_DIR/mb-edge.py" /usr/local/bin/mb-edge
install -m 755 "$SCRIPT_DIR/mb-ssh2.sh" /usr/local/bin/mb-ssh2
mkdir -p /etc/mb-ssh2 /var/lib/mb-ssh /run/mb-ssh

[[ -f /etc/mb-ssh2/edge.json ]] || cat > /etc/mb-ssh2/edge.json <<'EOF'
{
  "common_ports": [2095],
  "common_backend": "127.0.0.1:22022"
}
EOF

[[ -f /etc/mb-ssh2/mb.conf ]] || cat > /etc/mb-ssh2/mb.conf <<'EOF'
# /etc/mb-ssh2/mb.conf
EDGE_CTL=/run/mb-ssh/edge.sock
STATE_DIR=/var/lib/mb-ssh
PORT_POOL="8080 8880 2052 2082 2086 2053 2083 2087 2096 8443"
DROPBEAR_PORT=22022
STUNNEL_PORT=22443
WARP_IF=warp
DOMAIN=""
NODE_IP=""
EOF

# ---------- 7. systemd mb-edge ----------
cat > /etc/systemd/system/mb-edge.service <<'EOF'
[Unit]
Description=mb-edge — CF port pool edge proxy (SSH node)
After=network.target dropbear-client.service stunnel.service
Wants=dropbear-client.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/mb-edge
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now mb-edge.service
sleep 1
systemctl is-active mb-edge.service >/dev/null && log "mb-edge: active" || log "WARNING: mb-edge belum active"

# ---------- 8. Cron cleanup expired ----------
if ! crontab -l 2>/dev/null | grep -q "mb-ssh2-cleanup"; then
  (crontab -l 2>/dev/null; echo "17 4 * * * /usr/local/bin/mb-ssh2-cleanup >> /var/log/mb-ssh2-cleanup.log 2>&1 # mb-ssh2-cleanup") | crontab -
fi
cat > /usr/local/bin/mb-ssh2-cleanup <<'EOF'
#!/bin/bash
# hapus akun SSH yang sudah expired (shadow expiry lewat)
while read -r user; do
  /usr/local/bin/mb-ssh2 del "$user" >/dev/null 2>&1
done < <(python3 -c "
import json, time, datetime
d = json.load(open('/var/lib/mb-ssh/users.json'))
now = time.time()
for u, v in d.items():
    exp = v.get('expire_ts') or 0
    if exp and exp + 86400 < now:
        print(u)
")
EOF
chmod +x /usr/local/bin/mb-ssh2-cleanup

# ---------- 9. WARP (optional) ----------
if [[ $WARP -eq 1 ]]; then
  log "Setup WARP (warp-cli)..."
  apt-get install -y -qq curl >/dev/null
  curl -sSf https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs 2>/dev/null || echo jammy) main" > /etc/apt/sources.list.d/cloudflare-client.list
  apt-get update -qq && apt-get install -y -qq cloudflare-warp >/dev/null
  warp-cli register --activation-key="" || log "WARP: isi activation key manual (warp-cli register)"
  warp-cli connect || true
fi

# ---------- 10. Print instruksi ----------
cat <<'END'

============================================================
 NODE INIT2 SELESAI
 VPN  : Marzban panel http://<IP>:8000  (user VLESS/VMess/Trojan di sini)
 SSH  : mb-ssh2  (CLI produk SSH, port CF dedicated per akun)

 LANGKAH MANUAL:
 1. Panel Marzban → bikin admin + inbound (VLESS/VMess/Trojan)
    default port 443/80 = milik Marzban
 2. Test SSH product:
    mb-ssh2 add budi 30 --udp --bw 100/50
    cat /var/lib/mb-ssh/client-budi.txt
 3. Cloudflare: proxy (orange) semua port pool di domain:
    8080 8880 2052 2082 2086 2095 2053 2083 2087 2096 8443 + 443 80
 4. WARP (jika --warp): warp-cli mode proxy / per-user via mb-ssh2 --warp
============================================================
END
