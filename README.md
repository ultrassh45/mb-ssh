# mb-ssh — node VPN (Marzban) + SSH product

Satu repo = satu node. Installer satu baris, update = `git pull && bash run.sh`.

## Layout
```
run.sh                      ← entry installer (tipis, idempotent)
install/
  01-marzban.sh             ← VPN: Marzban official one-liner (+update)
  02-ssh-stack.sh           ← dropbear + stunnel + badvpn + certs + WARP
runtime/
  mb-edge.py                ← edge proxy: CF pool, relay, token-bucket, hot control
  mb-ssh2.sh                ← CLI: add/del/set/list/show (+ --udp --bw --tls --warp)
  mb-ssh2-cleanup.sh        ← auto-del expired (cron 04:17)
config/
  mb.conf                   ← PORT_POOL, DOMAIN, WARP_IF (per node, tidak ditimpa)
  edge.json                 ← common ports + backend
  stunnel-mb-ssh.conf       ← SSH TLS backend
systemd/
  mb-edge.service
  dropbear-client.service
legacy/v1/                  ← versi lama (Marzban-sync), arsip
```

## Install (node baru)
```bash
git clone <repo> /opt/mb-ssh && cd /opt/mb-ssh
bash run.sh                  # + --warp utk exit IP Cloudflare per-user
```
One-liner (alternatif):
```bash
curl -fsSL <repo>/raw/main/run.sh | bash
```

## Update (node live — idempotent)
```bash
cd /opt/mb-ssh && git pull && bash run.sh
```
- Config existing (`/etc/mb-ssh2/*`) TIDAK ditimpa
- User existing TIDAK hilang (state: `/var/lib/mb-ssh/users.json`)
- Marzban = official `@ update`; runtime di-reinstall; service restart (±2 detik)

## Operasional
```bash
mb-ssh2 add budi 30 --udp --bw 100/50     # akun SSH + UDP, 100/50 Mbps
mb-ssh2 set budi 60 --bw 200/100          # perpanjang + naikkan BW (hot)
mb-ssh2 show budi                         # client-info (salin ke customer)
mb-ssh2 list                              # semua akun + status edge
mb-ssh2 del budi
```

## Aturan port
| Port | Fungsi |
|---|---|
| 22 | admin SSH (openssh) |
| 443, 80 | Marzban (xray) |
| 8443, 2096, 8080 | SSH shared (common, tanpa per-user limit) |
| sisanya di PORT_POOL | per-user (dedicated) |
| 170xx | badvpn-udpgw per-user (lokal) |

Kapasitas default: 7 port user → 7 akun SSH / 3 akun SSH+UDP (2 port).
Scale = tambah port di `PORT_POOL` (edge hot-reload, tidak perlu restart) atau node baru.

## Cloudflare
Orange-cloud semua port di `PORT_POOL` + 443 + 80. SSH client:
```
ssh -p <port> budi@domain
# TLS flavor: stunnel ProxyCommand → domain:<port> (import cert /etc/mb-ssh2/cert.pem)
```

## Verifikasi (2026-10-25)
Relay dual-direction ✓ · hot add/remove ✓ · rate limit 5 Mbps → terukur 4.92 ✓ ·
CLI full cycle ✓ · graceful degrade ✓. Udpgw/stunnel/WARP live: verifikasi di node real.
