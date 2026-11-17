#!/bin/bash
# mb-ssh — SATU command installer/updater (repo publik, TANPA git)
#
#   curl -fsSL https://raw.githubusercontent.com/ultrassh45/mb-ssh/main/install.sh | bash
#   bash install.sh               → pasang repo ke /root/mb-ssh (kalau belum ada) + jalankan installer
#   bash install.sh --update      → unduh ulang versi terbaru lalu jalankan installer
#   DEST=/opt/mb-ssh bash install.sh   → lokasi target beda (default /root/mb-ssh)
#
# Repo = satu node (atau satu source bersama); config per-node di /etc/mb-ssh2/* tak disentuh.
# Mode unduh: tar.gz (default, TIDAK butuh git) | git (DOWNLOAD_MODE=git)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/ultrassh45/mb-ssh.git}"
REPO_TGZ="${REPO_TGZ:-https://codeload.github.com/ultrassh45/mb-ssh/tar.gz/refs/heads/main}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEST="${DEST:-/root/mb-ssh}"
DOWNLOAD_MODE="${DOWNLOAD_MODE:-tar}"

log() { echo -e "\033[1;32m[mb-ssh]\033[0m $*"; }
die() { echo -e "\033[1;31m[mb-ssh]\033[0m $*" >&2; exit 1; }

is_update=0
[[ "${1:-}" == "--update" ]] && is_update=1

# sudah ada & bukan update → langsung jalankan installer
if [[ $is_update -eq 0 ]] && [[ -f "$DEST/run.sh" ]]; then
  log "repo sudah ada di $DEST — jalankan installer"
  exec bash "$DEST/run.sh" "$@"
fi

if [[ "$DOWNLOAD_MODE" == "git" ]]; then
  command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }
  if [[ -d "$DEST/.git" ]]; then
    git -C "$DEST" fetch -q origin "$REPO_BRANCH" && git -C "$DEST" reset -q --hard "origin/$REPO_BRANCH"
  else
    git clone -q --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$DEST"
  fi
else
  # Mode tar: tidak butuh git. fallback curl → wget → python3
  log "mengunduh repo (arsip tar.gz, tanpa git)..."
  tmp="$(mktemp -d)"; ok=0
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 180 "$REPO_TGZ" -o "$tmp/repo.tar.gz" && ok=1 || ok=0
  fi
  if [[ $ok -eq 0 ]] && command -v wget >/dev/null 2>&1; then
    wget -q --timeout=20 -O "$tmp/repo.tar.gz" "$REPO_TGZ" && ok=1 || ok=0
  fi
  if [[ $ok -eq 0 ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$REPO_TGZ" "$tmp/repo.tar.gz" <<'PYEOF' && ok=1 || ok=0
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PYEOF
  fi
  [[ $ok -eq 1 ]] || { rm -rf "$tmp"; die "gagal unduh repo (curl/wget/python3 tidak ada atau jaringan)"; }
  mkdir -p "$DEST"
  tar -xzf "$tmp/repo.tar.gz" -C "$DEST" --strip-components=1 || { rm -rf "$tmp"; die "gagal ekstrak arsip"; }
  rm -rf "$tmp"
  log "repo terpasang di $DEST"
fi

exec bash "$DEST/run.sh" "${@:2}"
