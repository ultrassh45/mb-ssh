#!/bin/bash
# install/02-ssh-stack.sh — dropbear + stunnel + badvpn + certs (+ optional WARP)
# arg: $1 = WARP (0/1)
set -euo pipefail
log() { echo -e "\033[1;34m[ssh-stack]\033[0m $*"; }
die() { echo -e "\033[1;31m[ssh-stack]\033[0m $*" >&2; exit 1; }
WARP="${1:-0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- paket ----------
log "install dropbear + stunnel4..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dropbear stunnel4 rclone >/dev/null

# ---------- badvpn ----------
log "badvpn-udpgw (prebuilt)..."
ARCH=$(uname -m)
case $ARCH in
  x86_64)  BA=amd64 ;;
  aarch64) BA=arm64 ;;
  *) die "arch $ARCH tidak didukung" ;;
esac
if [[ ! -x /usr/local/bin/badvpn-udpgw ]]; then
  curl -fsSL "https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/opt/badvpn/dist/badvpn-udpgw-linux-$BA" \
    -o /usr/local/bin/badvpn-udpgw
  chmod +x /usr/local/bin/badvpn-udpgw
fi
log "badvpn ok: $(/usr/local/bin/badvpn-udpgw 2>&1 | head -1 || echo terpasang)"

# ---------- dropbear client (127.0.0.1:22022) ----------
log "dropbear 127.0.0.1:22022 (client backend)..."
# disable sistem dropbear default (admin sshd tetap di port 22 via openssh)
if grep -qE "^NO_START=" /etc/default/dropbear 2>/dev/null; then
  sed -i 's/^NO_START=.*/NO_START=1/' /etc/default/dropbear
else
  echo "NO_START=1" >> /etc/default/dropbear
fi
systemctl disable dropbear 2>/dev/null || true

# ---------- stunnel cert + config ----------
log "stunnel cert + config..."
mkdir -p /etc/mb-ssh2
if [[ ! -f /etc/mb-ssh2/cert.pem ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/mb-ssh2/key.pem -out /etc/mb-ssh2/cert.pem \
    -subj "/CN=ssh-node" 2>/dev/null
  chmod 600 /etc/mb-ssh2/key.pem
fi
install -m 644 "$ROOT/config/stunnel-mb-ssh.conf" /etc/stunnel/mb-ssh.conf

# ---------- WARP (optional) ----------
if [[ "$WARP" == "1" ]]; then
  log "WARP (cloudflare-warp)..."
  if ! command -v warp-cli >/dev/null; then
    apt-get install -y -qq curl gpg >/dev/null
    curl -fsSf https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
    CODENAME=$(lsb_release -cs 2>/dev/null || echo jammy)
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" \
      > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq
    apt-get install -y -qq cloudflare-warp >/dev/null
  fi
  if ! warp-cli --registered 2>/dev/null | grep -q Yes; then
    log "WARP belum diregister — jalankan: warp-cli register --activation-key <K>"
  else
    warp-cli connect >/dev/null 2>&1 || true
  fi
fi

log "ssh-stack done"
