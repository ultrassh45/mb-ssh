# install/lib-os.sh — deteksi OS (Ubuntu 20+/Debian 10+) — dibaca run.sh + install/*.sh
os_detect() {
  # → set OS_ID, OS_VER, OS_MAJOR
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-}"
    OS_MAJOR="${OS_MAJOR:-${VERSION_ID%%.*}}"
  else
    OS_ID=unknown; OS_VER=""; OS_MAJOR=""
  fi
  case "$OS_ID" in
    ubuntu|debian) ;;  # named
    *) OS_ID="$OS_ID";;
  esac
}

os_check() {
  # validasi minimum: Ubuntu 20+ / Debian 10+. Gagal → stderr + exit 1
  os_detect
  local ok=0
  case "$OS_ID" in
    ubuntu) [[ "$OS_MAJOR" -ge 20 ]] && ok=1 ;;
    debian) [[ "$OS_MAJOR" -ge 10 ]] && ok=1 ;;
  esac
  if [[ $ok -eq 1 ]]; then
    echo "$OS_ID $OS_VER"
    return 0
  fi
  echo "OS tidak didukung: $OS_ID $OS_VER — butuh Ubuntu 20+/Debian 10+" >&2
  return 1
}

# ---------- EOL mirror fix ----------
# Debian 10 (buster) & 11 (bullseye) sudah EOL: paket security dipindah ke
# archive.debian.org. Mirror pihak ketiga (Tencent/Aliyun/vendor) sering 404
# untuk bullseye-security -> apt install docker.io dkk GAGAL.
# Fungsi ini mengalihkan sources.list ke archive.debian.org (idempotent).
# Return 0 = diubah, 1 = tidak perlu.
os_fix_eol_mirror() {
  os_detect
  [[ "$OS_ID" == "debian" ]] || return 1
  local codename=""
  case "$OS_MAJOR" in
    10) codename=buster ;;
    11) codename=bullseye ;;
    *)  return 1 ;;   # 12+ masih didukung mirror normal
  esac

  # sudah pakai archive? -> tidak perlu
  if grep -qs "archive.debian.org" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
    # pastikan Check-Valid-Until dimatikan (arsip expired signature)
    [[ -f /etc/apt/apt.conf.d/99no-valid-until ]] || \
      echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-valid-until
    return 1
  fi

  echo "[lib-os] Debian ${OS_MAJOR} (${codename}) EOL — alihkan repo ke archive.debian.org" >&2
  [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak-$(date +%s)" 2>/dev/null

  local secsuite="${codename}/updates"
  cat > /etc/apt/sources.list <<EOF
# Diganti otomatis oleh mb-ssh: Debian ${OS_MAJOR} (${codename}) sudah EOL
deb http://archive.debian.org/debian ${codename} main contrib non-free
deb http://archive.debian.org/debian ${codename}-updates main contrib non-free
deb http://archive.debian.org/debian-security ${secsuite} main contrib non-free
EOF

  # hapus list tambahan yang menunjuk mirror vendor (sumber 404)
  local f
  for f in /etc/apt/sources.list.d/*.list; do
    [[ -e "$f" ]] || continue
    case "$f" in
      */cloudflare-client.list|*/docker.list) continue ;;   # repo pihak ketiga, biarkan
      *) mv "$f" "$f.disabled-$(date +%s)" 2>/dev/null || true ;;
    esac
  done

  echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-valid-until
  echo 'Acquire::AllowInsecureRepositories "true";' > /etc/apt/apt.conf.d/99allow-insecure
  return 0
}

install_pkg() {
  # install_pkg <pkg> ...  — apt hardcoded; dijamin Ubuntu20+/Debian10+ (sudah divalidasi)
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
}
