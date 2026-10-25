#!/bin/bash
# install/01-marzban.sh — install/update Marzban (VPN core: VLESS/VMess/Trojan)
set -euo pipefail
log() { echo -e "\033[1;34m[marzban]\033[0m $*"; }

if [[ -d /opt/marzban ]]; then
  log "sudah terpasang — jalankan update..."
  bash -c "$(curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ update || log "update skip/gagal (node tetap jalan)"
  exit 0
fi

log "fresh install (official one-liner, includes Xray core)..."
curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o /tmp/marzban-install.sh
bash /tmp/marzban-install.sh @ install
rm -f /tmp/marzban-install.sh
log "Marzban siap: /opt/marzban (panel default :8000)"
