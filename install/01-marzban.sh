#!/bin/bash
# install/01-marzban.sh — install/update Marzban (VPN core: VLESS/VMess/Trojan/SS)
#
# Marzban berjalan di Docker. Script ini:
#   1. pastikan Docker + docker compose tersedia (install kalau belum)
#   2. pastikan /opt/marzban berisi instalasi Marzban yang VALID (docker-compose.yml)
#   3. install fresh / update, dengan verifikasi container benar-benar jalan
set -euo pipefail
log() { echo -e "\033[1;34m[marzban]\033[0m $*"; }
die() { echo -e "\033[1;31m[marzban]\033[0m $*" >&2; exit 1; }

# ---------- 1. Docker ----------
_docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

if ! _docker_ok; then
  log "Docker belum ada/berjalan — install docker.io + compose plugin..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y -qq docker.io curl ca-certificates >/dev/null 2>&1 || \
    die "gagal install docker.io (cek /etc/apt/sources.list)"
  systemctl enable --now docker >/dev/null 2>&1 || true
  sleep 2
  if ! _docker_ok; then
    # fallback: pakai installer resmi Docker (repo docker.com)
    log "docker.io gagal start — coba installer resmi Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null || die "tidak bisa unduh get.docker.com"
    sh /tmp/get-docker.sh >/dev/null 2>&1 || log "installer resmi Docker gagal"
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker >/dev/null 2>&1 || true
    sleep 2
  fi
  _docker_ok || die "Docker tidak bisa dijalankan — Marzban butuh Docker. Cek: systemctl status docker"
  log "Docker siap: $(docker --version)"
fi

# docker compose (plugin v2 atau docker-compose v1)
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  log "docker compose belum ada — install plugin..."
  apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || \
    apt-get install -y -qq docker-compose >/dev/null 2>&1 || \
    log "PERINGATAN: docker compose tidak terpasang (Marzban mungkin gagal start)"
fi

# ---------- 2. Marzban: valid? ----------
MARZBAN_VALID=0
if [[ -f /opt/marzban/docker-compose.yml ]]; then
  MARZBAN_VALID=1
fi

if [[ $MARZBAN_VALID -eq 1 ]]; then
  log "Marzban sudah terpasang — jalankan update..."
  bash -c "$(curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ update \
    || log "update skip/gagal (node tetap jalan)"
else
  # folder ada tapi tidak valid (mis. sisa container/instalasi gagal) -> bersihkan
  if [[ -d /opt/marzban ]] && [[ ! -f /opt/marzban/docker-compose.yml ]]; then
    log "/opt/marzban ada tapi bukan instalasi valid — dibersihkan"
    rm -rf /opt/marzban
  fi
  log "fresh install (official one-liner, includes Xray core)..."
  curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o /tmp/marzban-install.sh \
    || die "gagal unduh marzban.sh"
  bash /tmp/marzban-install.sh @ install || log "installer Marzban keluar non-zero — cek manual"
  rm -f /tmp/marzban-install.sh
fi

# ---------- 3. Verifikasi ----------
if [[ -f /opt/marzban/docker-compose.yml ]]; then
  ( cd /opt/marzban && (docker compose up -d || docker-compose up -d) >/dev/null 2>&1 ) || true
  sleep 3
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi marzban; then
    log "Marzban siap: /opt/marzban (panel :8000) — container jalan"
  else
    log "PERINGATAN: container Marzban tidak terdeteksi jalan (cek: cd /opt/marzban && docker compose logs)"
  fi
else
  log "PERINGATAN: /opt/marzban/docker-compose.yml tidak ada — Marzban tidak terpasang"
  log "           SSH product tetap bisa dipakai; ulangi: bash install/01-marzban.sh"
fi
