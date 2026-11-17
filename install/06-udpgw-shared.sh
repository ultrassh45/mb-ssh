#!/bin/bash
# install/06-udpgw-shared.sh — UDPGW SHARED (Model B, pola vip.zip)
#
# 6 daemon badvpn-udpgw dipakai BERSAMA semua user (127.0.0.1:7100..7600).
# Client connect: badvpn-udpgw --client --to-addr <DOMAIN>:<port-udp>
#   port UDP publik di-forward (iptables REDIRECT) → 127.0.0.1:<port>
#
# Kelebihan vs model lama (per-user):
#   - TIDAK ada limit 32-client per user (shared, --max-clients 999 tiap daemon)
#   - Tidak butuh 1 port per user → cocok untuk trial massal
#   - Tidak spawn/teardown daemon per add/del (lebih ringan, no race)
#
# Trade-off (sesuai kesepakatan):
#   - IP limit / bandwidth / quota TETAP di-enforce di layer TCP SSH (edge relay).
#   - UDP tunnel sendiri tidak di-throttle per-user (badvpn tidak mengenal user).
#
# Idempotent: aman dijalankan ulang (update run.sh).
set -euo pipefail
log() { echo -e "\033[1;36m[udpgw-shared]\033[0m $*"; }

BADVPN_BIN="${BADVPN_BIN:-/usr/local/bin/badvpn-udpgw}"
# port shared pool (default pola autoscript: 7100 7200 7300 7400 7500 7600)
UDPGW_SHARED_PORTS="${UDPGW_SHARED_PORTS:-7100 7200 7300 7400 7500 7600}"
MAX_CLIENTS="${UDPGW_MAX_CLIENTS:-999}"

[[ -x "$BADVPN_BIN" ]] || { log "badvpn-udpgw tidak ada ($BADVPN_BIN) — jalankan dulu install/02-ssh-stack.sh"; exit 1; }

# ---------- 1. buka port UDP publik di firewall (REDIRECT ke 127.0.0.1) ----------
for p in $UDPGW_SHARED_PORTS; do
  # iptables masquerade/redirect: UDP publik :$p → 127.0.0.1:$p
  iptables -t nat -C PREROUTING -p udp --dport "$p" -j DNAT --to-destination "127.0.0.1:$p" 2>/dev/null \
    || iptables -t nat -A PREROUTING -p udp --dport "$p" -j DNAT --to-destination "127.0.0.1:$p"
  iptables -C FORWARD -p udp -d 127.0.0.1 --dport "$p" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -p udp -d 127.0.0.1 --dport "$p" -j ACCEPT
done
log "IPTables: UDP publik ${UDPGW_SHARED_PORTS// /,} → 127.0.0.1 (REDIRECT)"

# ---------- 2. systemd unit per port (RemainAfterExit, spawn 1 daemon tiap port) ----------
for p in $UDPGW_SHARED_PORTS; do
  unit="/etc/systemd/system/udpgw-${p}.service"
  cat > "$unit" <<EOF
[Unit]
Description=mb-ssh UDPGW shared :${p} (badvpn-udpgw, semua user)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BADVPN_BIN} --listen-addr 127.0.0.1:${p} --max-clients ${MAX_CLIENTS} --max-connections-for-client 64
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "udpgw-${p}.service" >/dev/null 2>&1 || true
  systemctl restart "udpgw-${p}.service" || log "udpgw-${p} restart gagal — cek journalctl -u udpgw-${p}"
done
log "systemd: udpgw-7100..7600 enabled + restarted"

# ---------- 3. simpan daftar port ke mb.conf (dipakai CLI/bot) ----------
CONF="${MB_SSH_CONF:-/etc/mb-ssh2/mb.conf}"
if [[ -f "$CONF" ]]; then
  grep -q "^UDPGW_SHARED_PORTS=" "$CONF" \
    || printf 'UDPGW_SHARED_PORTS="%s"\n' "$UDPGW_SHARED_PORTS" >> "$CONF"
  [[ -n $(grep "^UDPGW_SHARED_PORTS=" "$CONF") ]] \
    && sed -i "s|^UDPGW_SHARED_PORTS=.*|UDPGW_SHARED_PORTS=\"$UDPGW_SHARED_PORTS\"|" "$CONF"
fi
log "UDPGW_SHARED_PORTS=$UDPGW_SHARED_PORTS ditulis ke mb.conf"

# ---------- 4. verifikasi ----------
ok=1
for p in $UDPGW_SHARED_PORTS; do
  systemctl is-active --quiet "udpgw-${p}.service" || { ok=0; log "udpgw-${p} TIDAK AKTIF"; }
done
[[ $ok -eq 1 ]] && log "Semua daemon UDPGW shared aktif: ${UDPGW_SHARED_PORTS// /,}"
log "udpgw-shared done"
