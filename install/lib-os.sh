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

install_pkg() {
  # install_pkg <pkg> ...  — apt hardcoded; dijamin Ubuntu20+/Debian10+ (sudah divalidasi)
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
}
