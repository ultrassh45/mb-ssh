#!/usr/bin/env bash
# ============================================================
# 05-slowdns.sh — SlowDNS (SSH Tunnel over DNS) — OPTIONAL
# ============================================================
# Menyediakan SSH over DNS (port 53 UDP) untuk customer.
# Hanya aktif jika SLOWDNS_ENABLED=1 di /etc/mb-ssh2/mb.conf.
# Idempotent: aman dijalankan ulang (upgrade/re-run run.sh).
#
# Versi ini TIDAK memakai token/curl remote — semua file diambil
# dari repo ini (dist/slowdns/). Bila file tidak ada, script
# langsung skip dengan pesan jelas (tidak memblokir instalasi).
#
# Server:  run as root  → binds 53/UDP.
# Client:  customer pakai app SlowDNS (domain + pubkey dari client-<user>.txt).
# ============================================================

set -euo pipefail

CONF="${MB_SSH_CONF:-/etc/mb-ssh2/mb.conf}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${SLOWDNS_DIST_DIR:-$ROOT/dist/slowdns}"
BIN_DIR="${SLOWDNS_BIN_DIR:-/usr/local/bin}"
SYSTEMD_DIR="${SLOWDNS_SYSTEMD_DIR:-/etc/systemd/system}"

log() { printf '[slowdns] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# ---------- konfigurasi ----------
[[ -f "$CONF" ]] || die "$CONF tidak ada — jalankan bash run.sh dulu"
# shellcheck disable=SC1090
source "$CONF"

# off by default — kalau belum ada var, dianggap nonaktif
if [[ "${SLOWDNS_ENABLED:-0}" != "1" ]]; then
  log "SLOWDNS_ENABLED != 1 — skip (default off, kandungan di install/05-slowdns.sh)"
  log "Aktifkan: set SLOWDNS_ENABLED=1 + SLOWDNS_DOMAIN di $CONF, lalu jalankan ulang run.sh / script ini."
  exit 0
fi

SD_DOMAIN="${SLOWDNS_DOMAIN:-}"
SD_PORT="${SLOWDNS_PORT:-53}"
SD_PUBKEY="${SLOWDNS_PUBKEY:-}"
[[ -n "$SD_DOMAIN" ]] || die "SLOWDNS_ENABLED=1 tapi SLOWDNS_DOMAIN kosong"

# ---------- persiapan file ----------
mkdir -p "$DIST_DIR"
mkdir -p /var/lib/mb-ssh

if [[ -f "$DIST_DIR/server" ]] && [[ ! -x "$BIN_DIR/mb-slowdns-server" ]]; then
  # keygen (sekali) — menghasilkan privkey/pubkey utk signature SlowDNS
  SD_ETC="${SD_ETC:-/etc/mb-ssh2}"
  private_key_file="$SD_ETC/slowdns.key"
  if [[ ! -f "$private_key_file" ]]; then
    mkdir -p "$SD_ETC"
    "$DIST_DIR/server" -gen-key -privkey-file "$private_key_file" -pubkey-file "$SD_ETC/slowdns.pubkey" 2>/dev/null || true
    if [[ -f "$private_key_file" ]]; then
      log "keypair dibuat: $SD_ETC/slowdns.key (priv) + slowdns.pubkey (publik)"
    else
      log "keygen TIDAK memakai -gen-key — binary mungkin bukan dnstt-compatible, install key manual."
    fi
  fi
  cp -f "$DIST_DIR/server" "$BIN_DIR/mb-slowdns-server"
  chmod +x "$BIN_DIR/mb-slowdns-server"
  log "server: memakai repo dist/slowdns/server — tanpa token/curl remote"
elif [[ -x "$BIN_DIR/mb-slowdns-server" ]]; then
  log "mb-slowdns-server sudah terpasang ($BIN_DIR/mb-slowdns-server) — lewati install ulang"
else
  log "dist/slowdns/server TIDAK ADA — lewati pemasangan server (opsional)"
  log "Letakkan binary 'server' di $DIST_DIR lalu jalankan ulang script ini."
  exit 0
fi

# pubkey opsional (keypair untuk signature — lanjutkan walau kosong)
SD_KEYGEN_SRC=""
if [[ -n "$SD_PUBKEY" ]]; then
  if [[ -f "$DIST_DIR/pubkey" ]]; then
    log "pubkey: memakai repo dist/slowdns/pubkey"
    cp -f "$DIST_DIR/pubkey" /etc/mb-ssh2/slowdns.pubkey
    SD_KEYGEN_SRC="repo-pubkey"
  elif [[ -f "$SD_PUBKEY" ]]; then
    # path file keypair — dimungkinkan admin set manual
    cp -f "$SD_PUBKEY" /etc/mb-ssh2/slowdns.pubkey
    log "pubkey: memakai file $SD_PUBKEY"
    SD_KEYGEN_SRC="user-file"
  else
    log "pubkey '$SD_PUBKEY' tidak ditemukan — lanjut tanpa signature pubkey (opsional)"
  fi
fi

# ---------- unit systemd ----------
cat > "$SYSTEMD_DIR/mb-slowdns.service" <<EOF
[Unit]
Description=mb-ssh SlowDNS (dnstt DNS tunnel) — SSH over DNS ${SD_PORT}/udp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/mb-slowdns-server -udp :${SD_PORT} -privkey-file ${SD_ETC:-/etc/mb-ssh2}/slowdns.key ${SD_DOMAIN} 127.0.0.1:22022
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
log "systemd unit: mb-slowdns.service (${SD_DOMAIN}:${SD_PORT}/udp)"

# ---------- enable + start (idempotent) ----------
if systemctl enable mb-slowdns.service >/dev/null 2>&1; then
  log "unit enabled"
else
  log "systemctl enable gagal (sandbox/test?) — daemon-reload sukses bukan berarti aktif"
fi
if systemctl is-active --quiet mb-slowdns.service; then
  systemctl restart mb-slowdns.service
  log "restart mb-slowdns.service (perubahan konfig biasa)"
  log "SlowDNS server aktif: ${SD_DOMAIN}:${SD_PORT}/udp (pubkey: ${SD_KEYGEN_SRC:-tanpa})"
else
  if systemctl list-unit-files mb-slowdns.service >/dev/null 2>&1; then
    systemctl start mb-slowdns.service && log "SlowDNS server start OK: ${SD_DOMAIN}:${SD_PORT}/udp (pubkey: ${SD_KEYGEN_SRC:-tanpa})" \
      || log "gagal start — cek 'journalctl -u mb-slowdns -e' (biasanya port 53 sudah dipakai)"
  else
    log "unit belum terdaftar systemd (sandbox?) — verifikasi: cat $SYSTEMD_DIR/mb-slowdns.service"
  fi
fi
