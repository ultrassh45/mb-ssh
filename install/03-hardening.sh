#!/bin/bash
# install/03-hardening.sh — fail2ban (admin SSH) + hardening dasar
#
# CATATAN PENTING:
# fail2ban hanya efektif utk port 22 (openssh admin). Brute-force akun customer
# lewat port CF TIDAK bisa di-ban fail2ban (dropbear lihat 127.0.0.1 = relay) —
# itu dilindungi IpGuard di mb-edge (lihat edge.json "guard").
set -euo pipefail
log() { echo -e "\033[1;35m[hardening]\033[0m $*"; }

# ---------- fail2ban ----------
log "fail2ban..."
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s fail2ban >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq fail2ban >/dev/null
fi

mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/mb-ssh.local <<'EOF'
[sshd]
enabled  = true
port     = 22
maxretry = 3
findtime = 10m
bantime  = 1h
EOF

# pastikan log ssh tersedia utk fail2ban
if ! grep -q "auth.info" /etc/rsyslog.d/*.conf 2>/dev/null; then
  echo "auth.info,auth.privacy -syslog;auth" > /etc/rsyslog.d/10-ssh-auth.conf
  systemctl restart rsyslog 2>/dev/null || true
fi

systemctl enable --now fail2ban
sleep 1
if fail2ban-client status sshd >/dev/null 2>&1; then
  log "fail2ban sshd aktif: $(fail2ban-client status sshd | grep 'Currently banned' | awk '{print $3}')"
else
  log "WARNING: fail2ban jail sshd belum aktif (cek /var/log/fail2ban.log)"
fi

# ---------- sshd admin: hardening opsional ----------
# fail2ban di atas sudah melindungi password brute-force (3x gagal = ban 1 jam).
# Operator boleh tambah manual (pastikan punya akses key/console dulu):
#   ssh:   PermitRootLogin prohibit-password
#   ssh:   PasswordAuthentication no
# TIDAK di-set otomatis agar tidak lockout.

log "hardening done"
