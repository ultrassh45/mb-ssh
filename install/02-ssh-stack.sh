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
  # CATATAN: stdout fungsi ini TIDAK dipakai (dibuang ke stderr oleh pemanggil);
  # semua log pakai >&2 supaya tidak mengotori $() di _dropbear_resolve.
  local ver="$1"
  local src="/opt/dropbear/src/dropbear-DROPBEAR_${ver}"
  rm -rf "$src"
  mkdir -p /opt/dropbear/src
  log "dropbear build DROPBEAR_${ver} ..." >&2
  if curl -fsSL -m 120 "https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_${ver}.tar.gz" 2>/dev/null \
       | tar xz -C /opt/dropbear/src 2>/dev/null; then
    (
      cd "/opt/dropbear/src/dropbear-DROPBEAR_${ver}" || exit 1
      autoreconf -i >/dev/null 2>&1
      ./configure >/dev/null 2>&1 && make -j"$(nproc)" >/dev/null 2>&1
    ) >&2
    if [[ -x "/opt/dropbear/src/dropbear-DROPBEAR_${ver}/dropbear" ]]; then
      install -m 755 "/opt/dropbear/src/dropbear-DROPBEAR_${ver}/dropbear" "$DROPBEAR_DIR/dropbear-${ver}" || return 1
      [[ -x "/opt/dropbear/src/dropbear-DROPBEAR_${ver}/dropbearmulti" ]] && \
        install -m 755 "/opt/dropbear/src/dropbear-DROPBEAR_${ver}/dropbearmulti" "$DROPBEAR_DIR/dropbearmulti-${ver}" 2>/dev/null
      log "dropbear ${ver} build OK" >&2
      return 0
    fi
  fi
  log "dropbear ${ver} build GAGAL" >&2
  return 1
}

# pilih versi: loop default → list fallback
# PENTING: semua progress ke stderr, stdout HANYA untuk nilai versi
# (kalau tidak, $(...) menangkap log build → symlink jadi rusak)
_dropbear_resolve() {
  local v="$DROPBEAR_DEFAULT"
  while :; do
    # sudah pernah di-build di mesin ini → pakai langsung (tanpa rebuild)
    if [[ -x "$DROPBEAR_DIR/dropbear-${v}" ]]; then
      echo "$v"
      return 0
    fi
    if _dropbear_build "$v" >&2; then
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
PICKED="$(_dropbear_resolve)"
# sanitasi: ambil baris terakhir yang berisi pola versi (jaga-jaga bila ada noise)
PICKED="$(printf '%s\n' "$PICKED" | grep -E '^[0-9]{4}\.[0-9]{2}$' | tail -1)"
if [[ -z "$PICKED" || ! -x "$DROPBEAR_DIR/dropbear-${PICKED}" ]]; then
  log "SEMUA versi dropbear gagal build — fallback ke apt dropbear"
  apt-get install -y -qq dropbear >/dev/null || die "dropbear gagal total"
else
  mkdir -p /usr/local/bin
  ln -sfn "$DROPBEAR_DIR/dropbear-${PICKED}" /usr/local/bin/dropbear \
    || die "symlink dropbear gagal ($DROPBEAR_DIR/dropbear-${PICKED})"
  if [[ -x "$DROPBEAR_DIR/dropbearmulti-${PICKED}" ]]; then
    ln -sfn "$DROPBEAR_DIR/dropbearmulti-${PICKED}" /usr/local/bin/dropbearmulti || true
  fi
  # dropbearkey WAJIB: pembuat host key (tanpa ini dropbear mati "No hostkeys available")
  if [[ -x "/opt/dropbear/src/dropbear-DROPBEAR_${PICKED}/dropbearkey" ]]; then
    install -m 755 "/opt/dropbear/src/dropbear-DROPBEAR_${PICKED}/dropbearkey" "$DROPBEAR_DIR/dropbearkey-${PICKED}" \
      && ln -sfn "$DROPBEAR_DIR/dropbearkey-${PICKED}" /usr/local/bin/dropbearkey || true
  fi
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

# verifikasi prebuilt: binary harus bisa mencetak help (exit 0)
_badvpn_ok() {
  [[ -x /usr/local/bin/badvpn-udpgw ]] || return 1
  timeout 5 /usr/local/bin/badvpn-udpgw --help >/dev/null 2>&1
}

if ! _badvpn_ok; then
  rm -f /usr/local/bin/badvpn-udpgw
  curl -fsSL --max-time 90 "https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/opt/badvpn/dist/badvpn-udpgw-linux-$BA" \
    -o /usr/local/bin/badvpn-udpgw 2>/dev/null || true
  chmod +x /usr/local/bin/badvpn-udpgw 2>/dev/null || true
fi

if ! _badvpn_ok; then
  log "prebuilt badvpn gagal (glibc?) — build dari source..."
  apt-get install -y -qq cmake pkg-config libssl-dev gcc make >/dev/null 2>&1 || true
  rm -rf /tmp/badvpn-1.999.130 /tmp/badvpn.tar.gz
  if curl -fsSL --max-time 120 "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -o /tmp/badvpn.tar.gz 2>/dev/null \
     && tar xzf /tmp/badvpn.tar.gz -C /tmp 2>/dev/null; then
    (
      cd /tmp/badvpn-1.999.130 || exit 1
      cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_NOTHING_BY_DEFAULT=ON -DBUILD_UDPGW=ON . >/tmp/badvpn-cmake.log 2>&1
      make -j"$(nproc)" >/tmp/badvpn-make.log 2>&1
    ) || log "build badvpn gagal (lihat /tmp/badvpn-cmake.log, /tmp/badvpn-make.log)"
    if [[ -x /tmp/badvpn-1.999.130/udpgw/badvpn-udpgw ]]; then
      install -m 755 /tmp/badvpn-1.999.130/udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
      log "badvpn build source OK"
    fi
  else
    log "unduh/extrak source badvpn gagal (jaringan?)"
  fi
  [[ -x /usr/local/bin/badvpn-udpgw ]] || log "PERINGATAN: badvpn-udpgw tidak tersedia — UDPGW akan di-skip (node tetap jalan)"
fi

if _badvpn_ok; then
  log "badvpn ok: $(/usr/local/bin/badvpn-udpgw 2>&1 | head -1 || echo terpasang)"
else
  log "badvpn TIDAK terpasang — lanjut tanpa UDPGW (bisa diulang: bash install/02-ssh-stack.sh)"
fi
rm -rf /tmp/badvpn-1.999.130 /tmp/badvpn.tar.gz 2>/dev/null || true

# ---------- dropbear client (127.0.0.1:22022) ----------
log "dropbear 127.0.0.1:22022 (client backend)..."

# Host keys WAJIB ada — tanpa ini dropbear langsung mati:
#   "Early exit: No hostkeys available. 'dropbear -R' may be useful"
mkdir -p /etc/dropbear
chmod 700 /etc/dropbear
DBKEY="$(command -v dropbearkey || echo /usr/local/bin/dropbearkey)"
[[ -x "$DBKEY" ]] || DBKEY=/usr/local/bin/dropbearmulti
# ed25519 baru ada di dropbear >= 2020.79; 2019.78 -> rsa+ecdsa saja
DB_VER_OK=0
[[ "${PICKED:-}" == 2019.* ]] || DB_VER_OK=1
KEYTYPES="rsa ecdsa"
[[ $DB_VER_OK -eq 1 ]] && KEYTYPES="rsa ecdsa ed25519"
for kt in $KEYTYPES; do
  case $kt in
    rsa)     kf=/etc/dropbear/dropbear_rsa_host_key;     arg=rsa;     bits="-s 2048" ;;
    ecdsa)   kf=/etc/dropbear/dropbear_ecdsa_host_key;   arg=ecdsa;   bits="-s 256" ;;
    ed25519) kf=/etc/dropbear/dropbear_ed25519_host_key; arg=ed25519; bits="" ;;
  esac
  if [[ ! -s "$kf" ]]; then
    if [[ "$DBKEY" == *dropbearmulti ]]; then
      "$DBKEY" dropbearkey -t $arg $bits -f "$kf" >/dev/null 2>&1 || log "hostkey $kt gagal"
    else
      "$DBKEY" -t $arg $bits -f "$kf" >/dev/null 2>&1 || log "hostkey $kt gagal"
    fi
    chmod 600 "$kf" 2>/dev/null || true
  fi
done
_ls_keys=$(ls /etc/dropbear/*host_key 2>/dev/null | wc -l)
if [[ $_ls_keys -gt 0 ]]; then
  log "host keys siap ($_ls_keys key di /etc/dropbear)"
else
  # fallback: -R = generate otomatis saat start
  log "PERINGATAN: host key tidak terbentuk — pakai -R (generate runtime)"
fi

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
mkdir -p /etc/stunnel /var/log/stunnel /var/run/stunnel4
# 1) config utk SysV init Debian (butuh pid=, TIDAK boleh foreground)
install -m 644 "$ROOT/config/stunnel-mb-ssh.conf" /etc/stunnel/mb-ssh.conf \
  || log "PERINGATAN: config stunnel gagal dipasang (SSH TLS nonaktif)"
# 2) config utk unit systemd native kita (foreground=yes, TANPA pid=)
cat > /etc/mb-ssh2/stunnel-systemd.conf <<'STEOF'
foreground = yes
output = /var/log/stunnel/mb-ssh.log
cert = /etc/mb-ssh2/cert.pem
key = /etc/mb-ssh2/key.pem

[mb-ssh]
accept  = 127.0.0.1:22443
connect = 127.0.0.1:22022
client  = no
STEOF

# 3) unit systemd sendiri (lebih andal daripada SysV stunnel4.service)
cat > /etc/systemd/system/mb-stunnel.service <<'STUNIT'
[Unit]
Description=mb-stunnel — SSH TLS backend (127.0.0.1:22443 -> dropbear 22022)
After=network.target dropbear-client.service
Wants=dropbear-client.service

[Service]
Type=simple
ExecStart=/usr/bin/stunnel4 /etc/mb-ssh2/stunnel-systemd.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
STUNIT
systemctl daemon-reload 2>/dev/null || true
systemctl disable stunnel4 >/dev/null 2>&1 || true
log "stunnel: /etc/stunnel/mb-ssh.conf (SysV) + mb-stunnel.service (systemd)"

# ---------- WARP (optional) ----------
if [[ "$WARP" == "1" ]]; then
  log "WARP (cloudflare-warp)..."
  if ! command -v warp-cli >/dev/null; then
    apt-get install -y -qq curl gpg >/dev/null
    curl -fsSf https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
    CODENAME=$(lsb_release -cs 2>/dev/null || echo jammy)
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" \
      > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq || true
    apt-get install -y -qq cloudflare-warp >/dev/null || log "WARP gagal dipasang (skip)"
  fi
  if ! warp-cli --registered 2>/dev/null | grep -q Yes; then
    log "WARP belum diregister — jalankan: warp-cli register --activation-key <K>"
  else
    warp-cli connect >/dev/null 2>&1 || true
  fi
fi

log "ssh-stack done"
