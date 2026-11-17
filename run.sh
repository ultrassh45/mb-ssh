#!/bin/bash
# mb-ssh — installer node VPN (Marzban) + SSH product (edge + dropbear + stunnel + udpgw)
#
# One-liner (TANPA git di VPS — pakai arsip tar.gz):
#   curl -fsSL https://raw.githubusercontent.com/ultrassh45/mb-ssh/main/run.sh | bash
# Alternatif (kalau git tersedia):
#   git clone https://github.com/ultrassh45/mb-ssh.git /root/mb-ssh && bash /root/mb-ssh/run.sh
# Lokal:
#   bash run.sh [--warp] [--no-marzban]
#
# Arsitektur:
#   Marzban        : VLESS/VMess/Trojan/SS  (port 443/80, panel :8000)
#   mb-edge        : CF port pool → backends SSH (hot, zero restart per-user)
#   dropbear       : 127.0.0.1:22022 (SSH Direct)
#   stunnel        : 127.0.0.1:22443 (SSH TLS)
#   badvpn-udpgw   : SHARED instance 7100/7200/7300/7400/7500/7600 (systemd, semua user)

set -euo pipefail

# ---------- self-bootstrap (dua mode: tar.gz default [tanpa git], git opsional) ----------
REPO_URL="${REPO_URL:-https://github.com/ultrassh45/mb-ssh.git}"
REPO_TGZ="${REPO_TGZ:-https://codeload.github.com/ultrassh45/mb-ssh/tar.gz/refs/heads/main}"
REPO_BRANCH="${REPO_BRANCH:-main}"
SRC_DIR="${SRC_DIR:-/root/mb-ssh}"
DOWNLOAD_MODE="${DOWNLOAD_MODE:-tar}"   # tar (default, tanpa git) | git
# BASH_SOURCE kosong saat script di-pipe ke bash (curl | bash) → jangan pakai set -u di sini
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-./__piped__}")" 2>/dev/null && pwd)"
if [[ "$ROOT" != "$SRC_DIR" ]] && [[ ! -d "$ROOT/.git" ]] && [[ ! -f "$ROOT/run.sh" ]]; then
  # dijalankan lewat pipa curl (bukan repo lokal) → self-install repo
  SRC="$SRC_DIR"
  if [[ ! -f "$SRC/run.sh" ]]; then
    if [[ "$DOWNLOAD_MODE" == "git" ]]; then
      command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }
      git clone -q --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$SRC"
    else
      # Mode tar: TIDAK butuh git. fallback curl → wget → python3
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
      [[ $ok -eq 1 ]] || { echo "[mb-ssh] gagal unduh repo (curl/wget/python3 tidak ada atau jaringan)" >&2; rm -rf "$tmp"; exit 1; }
      mkdir -p "$SRC"
      tar -xzf "$tmp/repo.tar.gz" -C "$SRC" --strip-components=1 || { rm -rf "$tmp"; exit 1; }
      rm -rf "$tmp"
      # catat revisi utk cek update (tanpa git): commit sha terakhir di main
      curl -fsSL --max-time 15 "https://api.github.com/repos/ultrassh45/mb-ssh/commits/main" 2>/dev/null \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('sha','')[:7])" > "$SRC/VERSION_REV" 2>/dev/null || echo "unknown" > "$SRC/VERSION_REV"
      echo -e "\033[1;32m[mb-ssh]\033[0m repo terpasang via arsip tar.gz ($SRC, rev $(cat "$SRC/VERSION_REV"))"
    fi
  fi
  exec bash "$SRC/run.sh" "$@"
fi

log() { echo -e "\033[1;32m[mb-ssh]\033[0m $*"; }
die() { echo -e "\033[1;31m[mb-ssh]\033[0m $*" >&2; exit 1; }

# ---------- validasi OS: Ubuntu 20+ / Debian 10+ ----------
[[ -f "$ROOT/install/lib-os.sh" ]] && . "$ROOT/install/lib-os.sh"
if command -v os_check >/dev/null 2>&1; then
  OS_OK="$(os_check)" || die "OS ini tidak didukung. Minimal: Ubuntu 20+ / Debian 10+"
  log "OS terdeteksi: $OS_OK"
fi

[[ $EUID -eq 0 ]] || die "jalankan sebagai root"
command -v python3 >/dev/null || die "python3 tidak ada"

WARP=0
MARZBAN=1
for a in "$@"; do
  case $a in
    --warp) WARP=1 ;;
    --no-marzban) MARZBAN=0 ;;
    -h|--help) grep -E "^#( |$)" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "arg tidak dikenal: $a (pakai --help)" ;;
  esac
done

# ---------- 1. VPN: Marzban ----------
if [[ $MARZBAN -eq 1 ]]; then
  log "Step 1/4: Marzban (VLESS/VMess/Trojan)..."
  bash "$ROOT/install/01-marzban.sh"
else
  log "Step 1/4: Marzban — skip (--no-marzban)"
fi

# ---------- 2. SSH stack ----------
log "Step 2/4: SSH stack (dropbear + stunnel + badvpn + rclone)..."
bash "$ROOT/install/02-ssh-stack.sh" "$WARP"
bash "$ROOT/install/03-hardening.sh"

# ---------- 3. Deploy runtime + config + systemd ----------
log "Step 3/4: Deploy runtime..."
install -m 755 "$ROOT/runtime/mb-edge.py"        /usr/local/bin/mb-edge
install -m 755 "$ROOT/runtime/mb-ssh2.sh"        /usr/local/bin/mb-ssh2
install -m 755 "$ROOT/runtime/mb-ssh2-cleanup.sh" /usr/local/bin/mb-ssh2-cleanup
install -m 755 "$ROOT/runtime/mb-tgbot.py"       /usr/local/bin/mb-tgbot
mkdir -p /etc/mb-ssh2 /var/lib/mb-ssh /run/mb-ssh

# config (jangan timpa yang sudah ada = idempotent upgrade)
[[ -f /etc/mb-ssh2/edge.json ]] || install -m 644 "$ROOT/config/edge.json" /etc/mb-ssh2/edge.json
[[ -f /etc/mb-ssh2/mb.conf ]]   || install -m 644 "$ROOT/config/mb.conf"   /etc/mb-ssh2/mb.conf
# domain: input manual + validasi pointing (04) — auto-detect IP di dalamnya.
# lewati kalau DOMAIN sudah terisi selain IP default (idempotent).
bash "$ROOT/install/04-domain.sh" || log "konfig domain dilewati (lanjut IP)"
# API token (generate sekali) + flag warp di edge.json
python3 - "$WARP" <<'PY'
import json, os, re, secrets, sys
p = "/etc/mb-ssh2/edge.json"
d = json.load(open(p))
api = d.setdefault("api", {"port": 8499, "allow_ip": []})
tok = api.get("token", "")
if not tok or tok == "GANTI_DENGAN_TOKEN_DARI_RUN_SH":
    api["token"] = secrets.token_hex(32)
    print(f"API_TOKEN={api['token']}")
d["warp"] = (sys.argv[1] == "1")
json.dump(d, open(p, "w"), indent=2)
PY

# MOTD global (branding saat login SSH)
source /etc/mb-ssh2/mb.conf
cat > /etc/motd <<EOF
+----------------------------------------------------+
|  $DOMAIN - SSH & WARP Server                       |
|  Terima kasih sudah berlangganan.                  |
|  Support : ${SUPPORT:-zxpedia}
+----------------------------------------------------+
EOF
log "[ok] /etc/motd (branding)"

# Banner issue.net — tampil ke CUSTOMER saat konek SSH/VPN (sebelum login)
cat > /etc/issue.net <<EOF
=============================================================
  ${DOMAIN} — Terima kasih telah menggunakan layanan VPN kami.
  Support : ${SUPPORT:-zxpedia}
=============================================================
EOF
log "[ok] /etc/issue.net (banner customer)"

for unit in mb-edge dropbear-client mb-tgbot; do
  install -m 644 "$ROOT/systemd/$unit.service" "/etc/systemd/system/$unit.service"
done
systemctl daemon-reload
# stunnel: selalu pakai unit systemd sendiri (mb-stunnel.service) yang ditulis 02-ssh-stack.sh.
# (SysV stunnel4.service di Debian rapuh: butuh pid= tapi menolak foreground, dll.)
if [[ -f /etc/systemd/system/mb-stunnel.service ]]; then
  systemctl enable --now mb-stunnel.service \
    && log "[ok] mb-stunnel aktif (SSH TLS :22443)" \
    || log "PERINGATAN: mb-stunnel gagal aktif — SSH TLS nonaktif, SSH direct tetap jalan"
else
  log "PERINGATAN: unit mb-stunnel tidak ditemukan — SSH TLS tidak dipasang"
fi
printf 'STUNNEL_UNIT="mb-stunnel"\n' >> /etc/mb-ssh2/mb.conf
# bot TG: enable cuma kalau sudah ada token (idempotent upgrade)
if grep -Eq '^TG_BOT_TOKEN=".{5,}"' /etc/mb-ssh2/mb.conf 2>/dev/null; then
  systemctl enable --now mb-tgbot.service
  log "[ok] mb-tgbot aktif (token sudah ada di mb.conf)"
fi
sleep 1

# ---------- 3b. SlowDNS (opsional — hanya kalau SLOWDNS_ENABLED=1) ----------
# binary dari repo dist/slowdns/ — tanpa token/curl remote. Default off (aman).
if [ -f "$ROOT/install/05-slowdns.sh" ]; then
  bash "$ROOT/install/05-slowdns.sh" || log "SlowDNS setup skip/gagal (jangan-blokir node)"
fi

# ---------- 3c. UDPGW shared (Model B — pola autoscript) ----------
# 6 daemon badvpn-udpgw dipakai BERSAMA semua user (Model B). Trade-off (diketahui):
#   - enforce IP limit/bandwidth/quota tetap di layer TCP SSH (edge relay)
#   - UDP tunnel tidak di-throttle per-user (badvpn tidak kenal user)
# Idempotent, aman dijalankan ulang.
if [ -f "$ROOT/install/06-udpgw-shared.sh" ]; then
  bash "$ROOT/install/06-udpgw-shared.sh" || log "UDPGW shared setup skip/gagal (node tetap jalan)"
fi

# ---------- 4. Cron + verifikasi ----------
log "Step 4/4: Cron cleanup + verify..."
if ! crontab -l 2>/dev/null | grep -q "mb-ssh2-cleanup"; then
  (crontab -l 2>/dev/null; echo "17 4 * * * /usr/local/bin/mb-ssh2-cleanup >> /var/log/mb-ssh2-cleanup.log 2>&1") | crontab -
fi
# cron backup: idempotent — tulis ulang baris sesuai BACKUP_INTERVAL di mb.conf
/usr/local/bin/mb-ssh2 backup-cron

# ---------- 4b. Update script: set REPO_URL + pasang hook login-check ----------
# agar saat admin login SSH, muncul "UPDATE TERSEDIA + rincian + Y/N" & update
# auto-rollback kalau gagal. Idempotent: hanya set kalau kosong, hook sekali.
source /etc/mb-ssh2/mb.conf 2>/dev/null || true
if [[ -z "${REPO_URL:-}" ]]; then
  sed -i "/^REPO_URL=/d" /etc/mb-ssh2/mb.conf
  printf 'REPO_URL="%s"\n' "https://github.com/ultrassh45/mb-ssh.git" >> /etc/mb-ssh2/mb.conf
  grep -q '^REPO_BRANCH=' /etc/mb-ssh2/mb.conf || printf 'REPO_BRANCH="main"\n' >> /etc/mb-ssh2/mb.conf
  log "REPO_URL diset — update script aktif (git pull && bash run.sh)"
fi
# Upgrade idempotent: tambahkan var baru kalau belum ada (TIDAK menimpa nilai exist)
for _kv in "DEFAULT_IP_LIMIT=0" "SLOWDNS_ENABLED=0" "SLOWDNS_DOMAIN=" "SLOWDNS_PORT=53" "SLOWDNS_PUBKEY="; do
  _k="${_kv%%=*}"
  grep -q "^${_k}=" /etc/mb-ssh2/mb.conf 2>/dev/null || printf '%s\n' "${_k}=\"${_kv#*=}\"" >> /etc/mb-ssh2/mb.conf
done
# pasang hook login-check ke /root/.bashrc (dan user admin saat itu) — idempotent
MB_TEST=1 /usr/local/bin/mb-ssh2 _install_login_hook root 2>/dev/null \
  || grep -q "login-check" /root/.bashrc || cat >> /root/.bashrc <<'EOF'

# mb-ssh: cek update script saat login (Y = update, N = lewati)
[ -t 0 ] && [ -x /usr/local/bin/mb-ssh2 ] && /usr/local/bin/mb-ssh2 login-check
EOF
log "[ok] hook login-check /root/.bashrc (update prompt saat login)"

echo
echo "============================================================"
echo " NODE SIAP"
echo "   Marzban : http://\$(hostname -I | awk '{print \$1}'):8000"
echo "   SSH     : mb-ssh2 (CLI)"
echo "
 LANGKAH MANUAL:
   1. Panel Marzban: bikin admin + inbound (VLESS/VMess/Trojan, port 443/80)
   2. Cloudflare: proxy semua port pool + 443/80 di domain node
      (lihat PORT_POOL di /etc/mb-ssh2/mb.conf)
   3. Test akun SSH:
      mb-ssh2 add budi 30 --udp --bw 100/50 --quota 50
      cat /var/lib/mb-ssh/client-budi.txt
   4. API node (untuk panel/ultrassh):
      http://\$(hostname -I | awk '{print \$1}'):8499/v1/health
      header: Authorization: Bearer <API_TOKEN di atas / edge.json>
      simpan token di panel (ProxyNode.api_token), TIDAK akan tampil lagi
   5. Backup + bot Telegram (disarankan): jalankan:
      mb-ssh2 setup    # wizard: set R2 (rclone) + token bot @BotFather
      atau: mb-ssh2 menu — backup/restore/status dari terminal
      Setelah itu kirim /backup ke bot Telegram untuk backup on-demand.
   6. Update node (nanti): git pull + jalankan ulang: bash run.sh
============================================================"
