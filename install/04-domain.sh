#!/bin/bash
# install/04-domain.sh — input domain WAJIB (bukan IP) + validasi pointing + cert
#
# Aturan (sesuai kebutuhan operator):
#   - Enter kosong / berisi IP → TOLAK (harus domain asli).
#   - Proxy Cloudflare ON (resolve = IP CF / ≠ VPS) → beri tahu matikan proxy
#     (DNS only) lalu input ulang. TIDAK ada bypass.
#   - Valid = resolve domain == IP VPS (A record langsung ke node, proxy OFF).
#   - Cert default = Let's Encrypt; self-signed jadi cadangan.
#
# Dipanggil run.sh saat install, dan `mb-ssh2 set-domain` (ganti/ulang).
# Arg $1 = "force" utk paksa prompt (set-domain); selain itu idempotent.
set -euo pipefail
log() { echo -e "\033[1;38;5;79m[domain]\033[0m $*"; }
die() { echo -e "\033[1;31m[domain]\033[0m $*" >&2; exit 1; }

CONF="/etc/mb-ssh2/mb.conf"

# nama unit stunnel: Debian/Ubuntu = stunnel4, distro lain = stunnel
stunnel_unit() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^stunnel4\.service'; then echo stunnel4
  elif systemctl list-unit-files 2>/dev/null | grep -q '^stunnel\.service'; then echo stunnel
  else echo stunnel4; fi
}
[[ -f "$CONF" ]] || { echo "[domain] mb.conf tidak ada — jalankan run.sh dahulu" >&2; exit 2; }

FORCE="${1:-}"
CUR_DOMAIN=$(awk -F'"' '/^DOMAIN=/{print $2}' "$CONF")
VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n $VPS_IP ]] || die "IP VPS tidak terdeteksi"

# idempotent: sudah ada domain valid & bukan mode force → lewati
if [[ $FORCE != force ]] && [[ -n $CUR_DOMAIN ]] && ! grep -qE '^[0-9.]+$' <<< "$CUR_DOMAIN"; then
  log "DOMAIN sudah terpasang: $CUR_DOMAIN — lewati (ganti via: mb-ssh2 set-domain)"
  exit 0
fi

# helper: deteksi IP Cloudflare (proxy ON) — prefix umum CF
is_cf_ip() {
  case "$1" in
    103.21.*|103.22.*|103.31.*|104.1[6-9].*|104.2[0-9].*|104.3[0-1].*|\
    141.101.*|162.158.*|172.6[4-9].*|172.7[0-1].*|173.245.*|197.23.*|198.41.*\
    |190.9[3-9].*|203.190.*|188.114.*|188.1[2-9].*)
      return 0 ;;
  esac
  return 1
}

echo ""
echo "============================================================"
echo " KONFIGURASI DOMAIN (wajib — bukan IP)"
echo "------------------------------------------------------------"
echo " IP VPS          : $VPS_IP"
echo " Aturan: domain harus A-record DIRECT ke $VPS_IP."
echo "   • Proxy Cloudflare HARUS OFF (DNS only) dulu — kalau ON (resolve"
echo "     jadi IP CF), kamu diminta matikan lalu input ulang."
echo "   • Isi dengan domain asli; enter kosong / IP tidak diterima."
echo "============================================================"

DOM=""
while true; do
  read -rp " Input domain utk node: " DOM
  DOM=$(echo "$DOM" | sed -E 's|^[a-z]+://||; s|/.*$||; s|:[0-9]+$||; s|^[[:space:]]+||; s|[[:space:]]+$||' | tr 'A-Z' 'a-z')
  if [[ -z $DOM ]]; then
    echo "  ✗ harus diisi — enter kosong tidak diterima."
    continue
  fi
  if grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$DOM"; then
    echo "  ✗ '$DOM' berupa IP — wajib domain asli (bukan IP)."
    continue
  fi
  # validasi pointing: resolve → banding VPS_IP
  DOM_IP="$(getent ahosts "$DOM" 2>/dev/null | awk '{print $1; exit}')"
  if [[ -z $DOM_IP ]]; then
    echo "  ✗ '$DOM' tidak resolve — periksa DNS A record, lalu input ulang."
    continue
  fi
  if is_cf_ip "$DOM_IP"; then
    echo ""
    echo "  ⚠ Proxy Cloudflare TERDETEKSI — $DOM → $DOM_IP (IP Cloudflare)."
    echo "    Matikan proxy utk subdomain ini (Cloudflare DNS → 'DNS only',"
    echo "    bukan 'Proxied') lalu tunggu propagasi & input ulang."
    echo ""
    continue
  fi
  if [[ $DOM_IP != "$VPS_IP" ]]; then
    echo "  ✗ '$DOM' → $DOM_IP (bukan $VPS_IP). A-record harus direct ke IP VPS"
    echo "    dengan proxy OFF. Perbaiki DNS lalu input ulang."
    continue
  fi
  echo "  ✓ $DOM → $VPS_IP — pointing valid (proxy OFF)."
  break
done

# simpan domain
sed -i -E "s|^DOMAIN=.*|DOMAIN=\"$DOM\"|" "$CONF"
log "DOMAIN tersimpan: $DOM"

# regenerasi MOTD + banner issue.net (branding pakai domain baru) hanya saat
# set-domain (post-install); saat install run.sh sudah regenerasi setelah ini.
if [[ $FORCE == force ]]; then
  local STATE_DIR_="${STATE_DIR:-/var/lib/mb-ssh}" SSH2_BIN_="${SSH2_BIN:-/usr/local/bin/mb-ssh2}"
  # MOTD global (pakai mb.conf DOMAIN baru)
  . "$CONF" 2>/dev/null || true
  {
    echo "+----------------------------------------------------+"
    echo "|  $DOM - SSH & WARP Server                       |"
    echo "|  Terima kasih sudah berlangganan.                  |"
    echo "|  Support : ${SUPPORT:-zxpedia}"
    echo "+----------------------------------------------------+"
  } > /etc/motd
  # banner issue.net (customer)
  {
    echo "============================================================="
    echo "  ${DOM} — Terima kasih telah menggunakan layanan VPN kami."
    echo "  Support : ${SUPPORT:-zxpedia}"
    echo "============================================================="
  } > /etc/issue.net
  log "MOTD + /etc/issue.net di-regenerasi (domain $DOM)"
  # client-info per user di-update (host/domain baru)
  if [[ -x $SSH2_BIN_ ]]; then
    for uf in "$STATE_DIR_"/client-*.txt; do
      [[ -e $uf ]] || continue
      local u="$(basename "$uf" | sed 's/^client-//; s/\.txt$//')"
      "$SSH2_BIN_" show "$u" >/dev/null 2>&1 && "$SSH2_BIN_" show "$u" --json >/dev/null 2>&1
    done
    log "client-info user di-refresh"
  fi
fi

# ---------- SSL cert: default Let's Encrypt ----------
echo ""
echo "------------------------------------------------------------"
echo " SSL CERT (utk stunnel — SSH TLS backend :22443)"
echo "  1. Let's Encrypt (default — cert asli $DOM, butuh port 80)"
echo "  2. Self-signed   (cadangan — tanpa port terbuka)"
echo "------------------------------------------------------------"
read -rp " Pilih [1/2] (enter=1): " S
if [[ "${S:-1}" != "2" ]]; then
  log "Let's Encrypt utk $DOM (default)..."
  export DEBIAN_FRONTEND=noninteractive
  command -v certbot >/dev/null 2>&1 || apt-get install -y -qq certbot >/dev/null 2>&1 || true
  if command -v certbot >/dev/null 2>&1; then
    if certbot certonly --standalone --non-interactive --agree-tos \
       --register-unsafely-without-email -d "$DOM" >/tmp/mb-le.log 2>&1; then
      CERT_LIVE="/etc/letsencrypt/live/$DOM"
      if [[ -f "$CERT_LIVE/fullchain.pem" && -f "$CERT_LIVE/privkey.pem" ]]; then
        cat "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" > /etc/mb-ssh2/cert.pem
        chmod 600 /etc/mb-ssh2/cert.pem
        log "✓ Let's Encrypt cert aktif utk $DOM"
        if ! crontab -l 2>/dev/null | grep -q "$DOM.*fullchain.pem.*cert.pem"; then
          (crontab -l 2>/dev/null; echo "17 3 1,19 * * certbot renew --quiet >/dev/null 2>&1 && cat /etc/letsencrypt/live/$DOM/fullchain.pem /etc/letsencrypt/live/$DOM/privkey.pem > /etc/mb-ssh2/cert.pem && systemctl restart $(stunnel_unit)") | crontab -
          log "renew cron terpasang (2x/bln) utk $DOM"
        fi
        # restart stunnel agar cert baru aktif
        systemctl restart "$(stunnel_unit)" 2>/dev/null && log "stunnel di-restart (cert baru aktif)" \
          || log "restart stunnel gagal (amankah? cek: systemctl status $(stunnel_unit))"
        log "SELESAI — domain & cert siap."
        exit 0
      fi
    fi
    log "⚠ LE gagal (lihat /tmp/mb-le.log) — fallback self-signed"
  fi
fi

# self-signed (opsi 2 / fallback LE gagal)
[[ -f /etc/mb-ssh2/cert.pem ]] || \
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/mb-ssh2/key.pem -out /etc/mb-ssh2/cert.pem \
    -subj "/CN=$DOM" 2>/dev/null
# restart stunnel agar cert (self-signed/lama) ter-load
systemctl restart "$(stunnel_unit)" 2>/dev/null && log "stunnel di-restart (cert aktif)" \
  || log "restart stunnel gagal — cek: systemctl status $(stunnel_unit)"
log "cert siap: /etc/mb-ssh2/cert.pem (self-signed CN=$DOM) — pakai opsi 1 (Let's Encrypt) utk cert asli."
echo ""
echo "  (verifikasi: grep DOMAIN /etc/mb-ssh2/mb.conf)"
