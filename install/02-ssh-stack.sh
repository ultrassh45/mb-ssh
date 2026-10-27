#!/bin/bash
# install/02-ssh-stack.sh — dropbear + stunnel + badvpn + certs (+ optional WARP)
# arg: $1 = WARP (0/1)
set -euo pipefail
log() { echo -e "\033[1;34m[ssh-stack]\033[0m $*"; }
die() { echo -e "\033[1;31m[ssh-stack]\033[0m $*" >&2; exit 1; }
WARP="${1:-0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- paket ----------
# validasi OS sudah dilakukan run.sh (Ubuntu 20+/Debian 10+); source helper utk install_pkg
. "$(dirname "${BASH_SOURCE[0]}")/lib-os.sh" 2>/dev/null || die "lib-os.sh tidak ada"
log "install prereq + stunnel4..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
install_pkg stunnel4 rclone gcc make zlib1g-dev autoconf automake libtool || {
  log "paket penuh gagal — coba set minimal..."
  install_pkg stunnel4 rclone gcc make zlib1g-dev || die "instal paket gagal (cek /etc/apt/sources)"
}

# ---------- dropbear (multi-versi, default 2019) ----------
# Default: DROPBEAR_2019.78 (rilis terakhir tahun 2019 — yang familier di autoscript).
# Kalau build 2019 gagal → fallback versi lain (dari list). User bisa ganti via:
#   mb-ssh2 dropbear set <versi>   (uninstall yang terpasang, build yang dipilih)
# Ternary attack: binary di /usr/local/bin/dropbear; dropbearmulti juga.
log "dropbear multi-versi (default 2019)..."
ARCH=$(uname -m)
case $ARCH in
  x86_64)  BA=amd64 ;;
  aarch64) BA=arm64 ;;
  *) die "arch $ARCH tidak didukung" ;;
esac
DROPBEAR_DEFAULT="${DROPBEAR_DEFAULT:-2019.78}"
DROPBEAR_DIR="/opt/dropbear"
mkdir -p "$DROPBEAR_DIR"

_dropbear_build() {
  # arg: versi (mis 2019.78) → source tar.gz tag DROPBEAR_<versi> → binary
  local ver="$1"
  local src="/opt/dropbear/src/dropbear-DROPBEAR_${ver}"
  rm -rf "$src"
  mkdir -p /opt/dropbear/src
  log "dropbear build DROPBEAR_${ver} ..."
  if curl -fsSL -m 120 "https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_${ver}.tar.gz" | tar xz -C /opt/dropbear/src 2>/dev/null; then
    (
      cd "/opt/dropbear/src/dropbear-DROPBEAR_${ver}" && \
      autoreconf -i >/dev/null 2>&1
      ./configure 2>/dev/null && \
      make -j"$(nproc)" >/dev/null 2>&1
    )
    if [[ -x "/opt/dropbear/src/dropbear-DROPBEAR_${ver}/dropbear" ]]; then
      cp "/opt/dropbear/src/dropbear-DROPBEAR_${ver}/dropbear" "$DROPBEAR_DIR/dropbear-${ver}"
      cp "/opt/dropbear/src/dropbear-DROPBEAR_${ver}/dropbearmulti" "$DROPBEAR_DIR/dropbearmulti-${ver}" 2>/dev/null || true
      log "dropbear ${ver} build OK"
      return 0
    fi
  fi
  log "dropbear ${ver} build GAGAL"
  return 1
}

# pilih versi: loop default → list fallback
_dropbear_resolve() {
  local v="$DROPBEAR_DEFAULT"
  while :; do
    # sudah pernah di-build di mesin ini → pakai langsung (tanpa rebuild)
    if [[ -x "$DROPBEAR_DIR/dropbear-${v}" ]]; then
      echo "$v"
      return 0
    fi
    if _dropbear_build "$v"; then
      echo "$v"
      return 0
    fi
    case "$v" in
      "$DROPBEAR_DEFAULT") v=2020.81 ;;
      2020.81) v=2022.83 ;;
      2022.83) v=2024.85 ;;
      2024.85) v=2025.89 ;;
      2025.89) echo ""; return 1 ;;
    esac
  done
}

# install versi aktif → /usr/local/bin/dropbear (symlink)
PICKED=$(_dropbear_resolve)
if [[ -z $PICKED ]]; then
  log "SEMUA versi dropbear gagal build — fallback ke apt dropbear"
  apt-get install -y -qq dropbear >/dev/null || die "dropbear gagal total"
else
  ln -sf "$DROPBEAR_DIR/dropbear-${PICKED}" /usr/local/bin/dropbear
  ln -sf "$DROPBEAR_DIR/dropbearmulti-${PICKED}" /usr/local/bin/dropbearmulti 2>/dev/null || true
  log "dropbear aktif: ${PICKED} (${BA})"
fi

# ---------- badvpn ----------
# prebuilt dari autoscript TIDAK selalu jalan (butuh GLIBC_2.38 — Ubuntu 22 = 2.35).
# fix: verifikasi eksekusi; gagal → build dari source (ter-adaptasi glibc lokal).
log "badvpn-udpgw (prebuilt→fallback build source)..."
ARCH=$(uname -m)
case $ARCH in
  x86_64)  BA=amd64 ;;
  aarch64) BA=arm64 ;;
  *) die "arch $ARCH tidak didukung" ;;
esac
if [[ ! -x /usr/local/bin/badvpn-udpgw ]]; then
  curl -fsSL --max-time 60 "https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/opt/badvpn/dist/badvpn-udpgw-linux-$BA" \
    -o /usr/local/bin/badvpn-udpgw 2>/dev/null
  chmod +x /usr/local/bin/badvpn-udpgw 2>/dev/null
fi
# verifikasi prebuilt: harus bisa start error-free
if ! timeout 3 /usr/local/bin/badvpn-udpgw --help >/dev/null 2>&1 || \
   ! timeout 2 /usr/local/bin/badvpn-udpgw >/dev/null 2>&1; then
  log "prebuilt badvpn gagal (glibc?) — build dari source..."
  apt-get install -y -qq cmake pkg-config libssl-dev gcc make >/dev/null 2>&1
  curl -fsSL --max-time 90 "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -o /tmp/badvpn.tar.gz
  rm -rf /tmp/badvpn-1.999.130
  tar xzf /tmp/badvpn.tar.gz -C /tmp
  (
    cd /tmp/badvpn-1.999.130
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_NOTHING_BY_DEFAULT=ON -DBUILD_UDPGW=ON . >/dev/null 2>&1
    make >/dev/null 2>&1
  )
  if [[ -x /tmp/badvpn-1.999.130/udpgw/badvpn-udpgw ]]; then
    install -m 755 /tmp/badvpn-1.999.130/udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
    rm -rf /tmp/badvpn-1.999.130 /tmp/badvpn.tar.gz
    log "badvpn build source OK"
  else
    die "badvpn-udpgw: prebuilt gagal DAN build source gagal"
  fi
else
  log "badvpn prebuilt OK"
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
