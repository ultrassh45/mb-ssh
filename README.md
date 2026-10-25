# mb-ssh — node VPN (Marzban) + SSH product

Satu repo = satu node. Installer satu baris, update = `git pull && bash run.sh`.

## Layout
```
run.sh                      ← entry installer (tipis, idempotent)
install/
  01-marzban.sh             ← VPN: Marzban official one-liner (+update)
  02-ssh-stack.sh           ← dropbear + stunnel + badvpn + certs + WARP
runtime/
  mb-edge.py                ← edge proxy: CF pool, relay, token-bucket, hot control,
                                RESTORE + stats + quota + WARP monitor + HTTP API
  mb-ssh2.sh                ← CLI: add/del/set/list/show/backup/restore
                                (+ --udp --bw --tls --warp --quota --add-days --json)
  mb-ssh2-cleanup.sh        ← auto-del expired (cron 04:17)
config/
  mb.conf                   ← PORT_POOL, DOMAIN, WARP_IF, R2_REMOTE (per node, tidak ditimpa)
  edge.json                 ← common ports + backend + api (port/token/allow_ip) + warp
  stunnel-mb-ssh.conf       ← SSH TLS backend
systemd/
  mb-edge.service
  dropbear-client.service
tests/
  test.sh                     ← suite functional (26 check, port 29xxx, isolated)
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
mb-ssh2 add budi 30 --udp --bw 100/50 --quota 50   # akun SSH + UDP, 100/50 Mbps, kuota 50GB
mb-ssh2 set budi --add-days 30 --bw 200/100        # perpanjang + naikkan BW (hot)
mb-ssh2 set budi --quota 100 --reset-quota         # naikkan kuota + reset pemakaian
mb-ssh2 set budi --unblock                          # buka blokir (manual)
mb-ssh2 show budi                                    # client-info (salin ke customer)
mb-ssh2 show budi --json                             # detail + stats + quota_used (JSON)
mb-ssh2 list --json                                  # semua akun + stats (JSON)
mb-ssh2 del budi
mb-ssh2 backup                                       # push state+config ke R2
mb-ssh2 restore                                      # tarik balik dari R2
```

## Fitur per-user
- **Bandwidth** : token-bucket di edge (bytes/sec, down/up terpisah, hot-apply tanpa restart).
- **Quota (GB)** : akumulasi byte in+out per akun. Saat `quota_used >= quota_gb`, edge
  auto-blok (koneksi baru ditolak + koneksi aktif ditutup). `--reset-quota` / naikkan
  kuota untuk membuka. 0 = unlimited.
- **Stats**     : byte in/out, sesi total, sesi aktif — persist ke `stats.json` (flush 60s
  + saat remove). Dipakai `list/show --json` dan API.
- **Restore**   : saat edge (re)start, semua user port + udpgw di-load ulang otomatis dari
  `users.json` — reboot node tidak mematikan akun.
- **WARP**      : edge memonitor `warp-cli --status` tiap 60s; kalau down, auto `warp-cli connect`.

## HTTP API (untuk panel/ultrassh)
Edge juga menyerve REST JSON di `0.0.0.0:8499` (default). Auth = `Authorization: Bearer <token>`
(token di-generate `run.sh`, disimpan di `edge.json api.token`; opsional `api.allow_ip`).
Rate limit 30 req/menit/IP. Log ke `/var/log/mb-api.log`.

```
GET    /v1/health          → {status, uptime_s, users, active_sessions, warp, disk_pct}
GET    /v1/users           → {user: {..., stats, quota_used}}
POST   /v1/users           → {username, days, bw_down, bw_up, udp, backend, warp, quota_gb}
GET    /v1/users/<u>       → detail + stats + client_info
PATCH  /v1/users/<u>       → {add_days, bw_down, bw_up, quota_gb, reset_quota, unblock, warp}
DELETE /v1/users/<u>
```
Validasi ketat: username `^[a-z0-9_]{3,32}$` (anti shell-injection ke CLI), hari 0–3650,
bw 0–1000, quota 0–10000, backend `direct|tls`. Panel cukup simpan IP+token per node.

## Backup (R2)
Set `R2_REMOTE` di `/etc/mb-ssh2/mb.conf` (nama remote rclone, tipe `r2`). Cron 03:03
push `state`+`config` ke `R2_REMOTE:<R2_PATH>`. Tanpa `R2_REMOTE` = no-op (aman).

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
Suite test di `tests/test.sh` — **26/26 pass**:
- Relay dual-direction · hot add/remove · rate limit 5 Mbps → terukur 4.92
- **Restore**: kill+restart edge → user port & relay auto-pulihkan (P0)
- **Stats**: byte in terhitung di `stats.json`
- **Quota**: 0.001GB → koneksi baru ditolak saat exceeded → `--reset-quota` membuka
- **CLI `--json`** (list/show) · **HTTP API** (401/404/201/409/400/PATCH/DELETE/health)
- Graceful degrade · anti shell-injection username

Belum di-test di node real: udpgw live traffic, stunnel TLS, WARP.
