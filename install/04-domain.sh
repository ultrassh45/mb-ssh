#!/bin/bash
# install/04-domain.sh — input manual domain + validasi pointing ke IP VPS.
# Dipanggil run.sh setelah install. Jika DOMAIN sudah terisi (non-kosong),
# lewati (idempotent). Pengguna bisa set ulang via CLI: mb-ssh2 set-domain.
set -euo pipefail
log() { echo -e "\033[1;38;5;79m[domain]\033[0m $*"; }
die() { echo -e "\033[1;31m[domain]\033[0m $*" >&2; exit 1; }

CONF="/etc/mb-ssh2/mb.conf"
[[ -f "$CONF" ]] || die "mb.conf tidak ada — jalankan run.sh dahulu"

# URI baca nilai DOMAIN dari mb.conf
CUR_DOMAIN=$(awk -F'"' '/^DOMAIN=/{print $2}' "$CONF")
VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n $VPS_IP ]] || die "IP VPS tidak terdeteksi (hostname -I kosong)"

# ---- sudah terisi (bukan IP default)? lewati ----
if [[ -n $CUR_DOMAIN ]] && [[ $CUR_DOMAIN != "$VPS_IP" ]]; then
  log "DOMAIN sudah terpasang: $CUR_DOMAIN — lewati (idempotent). Ganti via: mb-ssh2 set-domain"
  exit 0
fi

echo ""
echo "============================================================"
echo " KONFIGURASI DOMAIN"
echo "------------------------------------------------------------"
echo " IP VPS terdeteksi : $VPS_IP"
echo " (Optional) Domain utk node — mis ssh.zxpedia.net. Kosongkan utk pakai IP."
echo " Domain harus A-record → $VPS_IP. Validasi checking dilakukan."
echo "============================================================"
read -rp " Input domain (enter utk pakai IP $VPS_IP): " DOM
DOM="${DOM:-$VPS_IP}"
# trim whitespace + lower + hilangkan skema/port kalau user iseng
DOM=$(echo "$DOM" | sed -E 's|^[a-z]+://||; s|/.*$||; s|:[0-9]+$||; s|^[[:space:]]+||; s|[[:space:]]+$||')
[[ -n $DOM ]] || DOM="$VPS_IP"

if [[ $DOM != "$VPS_IP" ]]; then
  # validasi pointing: resolve domain → bandingkan dengan IP VPS.
  # Catatan: kalau domain diproxy Cloudflare → IP = Cloudflare (bukan VPS).
  # Itu normal (CF forward raw TCP ke node) → dianggap valid utk redirect.
  DOM_IP="$(getent ahosts "$DOM" 2>/dev/null | awk '{print $1; exit}')"
  case "$DOM_IP" in
    104.*|172.*|173.*)
      log "✓ $DOM → IP Cloudflare ($DOM_IP) — CF proxy, raw TCP forwarded ke node"
      # tidak perlu tanya — sudah sesuai kasus CF
      ;;
    "")
      log "⚠ domain $DOM tidak resolve (DNS A record belum ada / typo)"
      read -rp "  Tetap pakai domain ini? (y/N): " ans
      case "${ans,,}" in y|ya|yes) ;; *) log "dibatalkan — pakai IP $VPS_IP"; DOM="$VPS_IP" ;; esac
      ;;
    *)
      if [[ $DOM_IP != "$VPS_IP" ]]; then
        log "⚠ $DOM → $DOM_IP ; IP VPS = $VPS_IP (tidak sama)"
        read -rp "  Tetap pakai? (y/N): " ans
        case "${ans,,}" in y|ya|yes) ;; *) log "dibatalkan — pakai IP $VPS_IP"; DOM="$VPS_IP" ;; esac
      else
        log "✓ $DOM pointing ke $VPS_IP — valid"
      fi
      ;;
  esac
fi

# tulis ke mb.conf
sed -i -E "s|^DOMAIN=.*|DOMAIN=\"$DOM\"|" "$CONF"
log "DOMAIN tersimpan: $DOM"

# ---------- SSL cert (opsional Let's Encrypt untuk stunnel TLS) ----------
# Kalau domain = IP → self-signed (default). Kalau domain asli + port 443/80
# kosong + ter-resolve → coba certbot LE. Gagal → tetap self-signed (aman).
if [[ $DOM != "$VPS_IP" ]] && [[ -n $DOM ]]; then
  echo ""
  echo "------------------------------------------------------------"
  echo " SSL CERT — pilih metode utk stunnel (SSH TLS backend :22443)"
  echo "------------------------------------------------------------"
  echo "  1. Self-signed (default, langsung jalan, tanpa port terbuka)"
  echo "  2. Let's Encrypt (cert asli utk $DOM — butuh port 80) "
  read -rp " Pilih [1/2] (enter=1): " S
  if [[ "${S:-1}" == "2" ]]; then
    log "coba Let's Encrypt utk $DOM..."
    export DEBIAN_FRONTEND=noninteractive
    command -v certbot >/dev/null 2>&1 || apt-get install -y -qq certbot >/dev/null 2>&1 || true
    if command -v certbot >/dev/null 2>&1; then
      if certbot certonly --standalone --non-interactive --agree-tos \
         --register-unsafely-without-email -d "$DOM" \
         >/tmp/mb-le.log 2>&1; then
        CERT_LIVE="/etc/letsencrypt/live/$DOM"
        if [[ -f "$CERT_LIVE/fullchain.pem" && -f "$CERT_LIVE/privkey.pem" ]]; then
          cat "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" > /etc/mb-ssh2/cert.pem
          chmod 600 /etc/mb-ssh2/cert.pem
          log "✓ Let's Encrypt cert aktif utk $DOM"
          # auto-renew watcher
          if ! crontab -l 2>/dev/null | grep -q "mb-le-renew"; then
            (crontab -l 2>/dev/null; cat <<'EOCR'
# mb-ssh: renew LE cert 12.3.2026 utk stunnel; re-kombinasi ke cert.pem
17 3 1,19 * * certbot renew --quiet >/dev/null 2>&1 && cat /etc/letsencrypt/live/DOMAIN_REPL/fullchain.pem /etc/letsencrypt/live/DOMAIN_REPL/privkey.pem > /etc/mb-ssh2/cert.pem && systemctl restart stunnel
EOCR
            ) | sed "s|DOMAIN_REPL|$DOM|g" | crontab -
            log "renew cron terpasang (2x/bln)"
          fi
          exit 0
        fi
      fi
      log "⚠ LE gagal (lihat /tmp/mb-le.log) — pakai self-signed"
    fi
  fi
  [[ -f /etc/mb-ssh2/cert.pem ]] || \
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/mb-ssh2/key.pem -out /etc/mb-ssh2/cert.pem \
      -subj "/CN=$DOM" 2>/dev/null
else
  # domain = IP → pastikan self-signed ada (stunnel butuh cert)
  [[ -f /etc/mb-ssh2/cert.pem ]] || \
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/mb-ssh2/key.pem -out /etc/mb-ssh2/cert.pem \
      -subj "/CN=$DOM" 2>/dev/null
fi
if grep -q "BEGIN CERTIFICATE" /etc/mb-ssh2/cert.pem 2>/dev/null; then
  log "cert siap: /etc/mb-ssh2/cert.pem (CN=$(openssl x509 -in /etc/mb-ssh2/cert.pem -noout -subject 2>/dev/null | sed 's/.*CN=//'))"
fi
echo ""
echo "  (verifikasi: grep DOMAIN /etc/mb-ssh2/mb.conf)"
