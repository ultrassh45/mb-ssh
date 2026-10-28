#!/bin/bash
# mb-ssh — SATU command installer/updater (private repo friendly)
#
#   bash install.sh               → clone ke /root/mb-ssh (kalau belum ada) + jalankan installer
#   bash install.sh --update      → sama, tapi selalu git pull dulu (update node)
#   DEST=/opt/mb-ssh bash install.sh   → lokasi target beda (default /root/mb-ssh)
#
# Private repo: token/auth git sudah dikonfig di mesin (bukan di script ini).
# Repo = satu node (atau satu source bersama); config per-node di /etc/mb-ssh2/* tak disentuh.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/ultrassh45/mb-ssh.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEST="${DEST:-/root/mb-ssh}"

command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }

if [[ "${1:-}" == "--update" || -d "$DEST/.git" ]]; then
  git -C "$DEST" fetch -q origin "$REPO_BRANCH" 2>/dev/null || {
    echo "[mb-ssh] $DEST belum repo git — clone baru" >&2
    git clone -q --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$DEST"
  }
  git -C "$DEST" reset -q --hard "origin/$REPO_BRANCH"
else
  git clone -q --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$DEST"
fi

exec bash "$DEST/run.sh" "${@:2}"
