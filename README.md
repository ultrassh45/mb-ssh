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
  mb-ssh2-cleanup.sh        ← proses expired (cron 04:17): hapus (default) atau
                                keep+lock (AUTO_DELETE_EXPIRED=0 di mb.conf)
  mb-tgbot.py               ← bot Telegram: /backup /restore /status (allow-list chat)
config/
  mb.conf                   ← PORT_POOL, DOMAIN, WARP_IF, R2, TG bot, AUTO_DELETE_EXPIRED
  edge.json                 ← common ports + backend + api (port/token/allow_ip) + warp
  stunnel-mb-ssh.conf       ← SSH TLS backend
systemd/
  mb-edge.service
  dropbear-client.service
  mb-tgbot.service          ← enable otomatis setelah `mb-ssh2 setup` (token valid)
tests/
  test.sh                     ← suite functional (57 check, port 29xxx, isolated)
legacy/v1/                  ← versi lama (Marzban-sync), arsip
```

## Install (node baru)
SATU command — clone langsung ke lokasi kanonik, tanpa cd:
```bash
git clone https://github.com/ultrassh45/mb-ssh.git /root/mb-ssh && bash /root/mb-ssh/run.sh
# tambah --warp utk exit IP Cloudflare per-user (opsional)
```
> Repo **PRIVATE** — perlu akses (PAT/token) utk clone. Satu repo = satu node (atau
> satu source utk semua node kamu; config per-node ada di `/etc/mb-ssh2/*`, tak
> ditimpa update). **OS: Ubuntu 20+/Debian 10+** (validasi otomatis; lain → error jelas).
> `run.sh` mendeteksi lokasinya sendiri via `$BASH_SOURCE` → tak perlu `cd`.

Update node (idempotent, config user tak tersentuh) — **tanpa perlu tahu path, tanpa cd**:
```bash
mb-ssh2 update           # git pull + reinstall runtime + verify, auto-rollback kalau gagal
# kalau CLI belum terpasang: cd /root/mb-ssh && git pull && bash run.sh
```
- Config existing (`/etc/mb-ssh2/*`) TIDAK ditimpa
- User existing TIDAK hilang (state: `/var/lib/mb-ssh/users.json`)
- Marzban = official `@ update`; runtime di-reinstall; service restart (±2 detik)

## Ganti domain (setelah install)
```bash
mb-ssh2 set-domain     # prompt input domain + validasi pointing + cert
```
> Membutuhkan repo di `/root/mb-ssh` (SRC_DIR default). Kalau di path lain,
> set `SRC_DIR=/path/repo` di `/etc/mb-ssh2/mb.conf`.

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
mb-ssh2 backup                                      # backup ssh state + Marzban DB + config → R2
mb-ssh2 restore                                     # pull dari R2 → restore ssh + Marzban
mb-ssh2 setup                                       # wizard: set R2 + bot Telegram (tulis mb.conf, enable svc)
mb-ssh2 menu                                        # menu interaktif (setup/backup/restore/status/…)
mb-ssh2 status                                      # ringkasan: akun per service + config + log backup
mb-ssh2 svcheck                                     # status service systemd + versi dropbear aktif
mb-ssh2 set-domain                                  # ganti domain node (validasi pointing + cert)
```

## Menu CLI & Bot Telegram
**Menu CLI** (nomor lengkap):
```bash
mb-ssh2 menu     # header tampil total akun per service:
               #   Akun: ssh=N vless=N vmess=N trojan=N   (SSH dari users.json,
               #                                          VLESS/VMess/Trojan dari Marzban db)
               #  1) Tambah akun SSH       8) Backup sekarang
               #  2) Hapus akun            9) Restore dari R2
               #  3) Perpanjang akun      10) Status
               #  4) Daftar akun          11) Bantuan bot
               #  5) Detail akun          12) Update script + auto-rollback
               #  6) Setup R2 + bot        13) Ganti versi dropbear
               #  7) Jadwal backup         14) Cek status service + dropbear
               #                          15) Set token bot + notif
               #                          16) Ganti domain (validasi+cert)
               #                          17) Ganti banner /etc/issue.net
mb-ssh2 status   # cek singkat: akun per service + R2 set? bot jalan? jadwal?
mb-ssh2 svcheck  # status systemd mb-edge/dropbear/stunnel/bot/marzban + versi dropbear
mb-ssh2 bot <token> [chat_id]   # set token bot + restart mb-tgbot & mb-edge
mb-ssh2 banner                # edit /etc/issue.net + restart dropbear-client
mb-ssh2 set-domain              # ganti domain + validasi pointing + cert + restart stunnel
```
Non-interaktif (script/bot): 
- `mb-ssh2 setup <R2_REMOTE> [R2_PATH] <TG_BOT_TOKEN> <TG_CHAT_ID>` — token invalid = ditolak
- `mb-ssh2 schedule 30 m` / `6 j` / `0` — set jadwal backup otomatis

**Jadwal backup otomatis** (menit/jam, tersimpan di mb.conf `BACKUP_INTERVAL`):
| Setting | Cron | Efek |
|---|---|---|
| `0` | `3 3 * * *` | tiap hari 03:03 (default) |
| `30 m` | `*/30 * * * *` | tiap 30 menit |
| `6 j` | `0 */6 * * *` | tiap 6 jam |

Set dari menu (item 7), CLI `mb-ssh2 schedule`, atau bot ` /schedule 30 m` — semua idempotent, tanpa restart.

**Bot Telegram** (setelah `setup`): service `mb-tgbot` aktif (systemd, restart on-failure).
Kirim ke bot:
| Perintah | Aksi di node |
|---|---|
| `/backup` | `mb-ssh2 backup` — balas = output asli CLI |
| `/schedule 30 m` | backup tiap 30 menit (`6 j` = jam, `0` = harian 03:03) |
| `/restore` | `mb-ssh2 restore` (menimpa state + DB Marzban) |
| `/status` | node + total akun per service (ssh/vless/vmess/trojan) + R2 + jadwal |
| `/help` | daftar perintah |

Keamanan: hanya chat_id di `TG_CHAT_ID` (allow-list, boleh koma-separated) yang diproses.

## Dropbear multi-versi
Default saat install = **DROPBEAR 2019.78** (rilis terakhir 2019). Kalau build gagal →
otomatis fallback berurutan (2020.81 → 2022.83 → 2024.85 → 2025.89 → apt dropbear).
Semua versi dibangun dari source resmi mkj/dropbear (autotools, ±1 menit).

| Perintah | Fungsi |
|---|---|
| `mb-ssh2 dropbear` | versi aktif + daftar versi tersedia |
| `mb-ssh2 dropbear set 2022.83` | ganti: build versi pilihan → pasang → **hapus versi lain** → restart service |
| `mb-ssh2 dropbear status` | versi dropbear yang berjalan |
| menu → 13 | sama, interaktif |

Versi yang tersedia: `2019.78` (default) · `2020.81` · `2022.83` · `2024.85` · `2025.89`.
Binary symlink di `/usr/local/bin/dropbear` → service `dropbear-client` restart otomatis.

## Banner `/etc/issue.net` (customer)
Saat install (`run.sh`), dibuat `/etc/issue.net` — **banner sambutan yang tampil ke
customer sebelum login SSH/VPN**:
```
=============================================================
  <domain> — Terima kasih telah menggunakan layanan VPN kami.
  Support : zxpedia
=============================================================
```
Dropbear memberikannya via `-b /etc/issue.net` (unit `dropbear-client.service`).
Ubah teksnya bebas di `/etc/issue.net` → berlaku setelah
`systemctl restart dropbear-client`.

## Backup & Restore (otomatis)
**Cron** (pasang `run.sh`): `3 3 * * *` → `mb-ssh2 backup` → `rclone copy` ke R2
(`R2_REMOTE` + `R2_PATH` di `/etc/mb-ssh2/mb.conf`; kosong = off).

Yang di-backup (per node, path R2: `$R2_PATH/{state,config}`):
| Isi | Asalnya | Cakupan |
|---|---|---|
| `users.json` + `stats.json` | `$STATE_DIR` | semua akun **SSH** (port, bw, quota, expire, warp, udp) |
| `marzban-latest.tar.gz` | `sqlite3 .backup` (online, konsisten) `db.sqlite3` + `xray_config.json` | semua client **VLESS/VMess/Trojan/SS** + config core |
| `mb.conf` + `edge.json` | `$CONF_DIR` | pool port, backend, WARP, guard, token API |

**Restore** — 2 skenario:
1. **Node rusak, VPS sama**: `mb-ssh2 restore` → tarik state+config+Marzban dari R2 →
   DB Marzban ditukar otomatis (`marzban down`/`up`) → `systemctl restart mb-edge`.
2. **Pindah VPS baru**: install fresh (`bash run.sh`) → set `R2_REMOTE`/`R2_PATH` yang sama →
   `mb-ssh2 restore` → `systemctl restart mb-edge`. Semua akun SSH + client VPN kembali,
   port & kuota & expire utuh (edge re-load dari `users.json` saat start).

## Fitur per-user
- **UDPGW (telfon/video call)**: `--udp` saat `add` → dedicated port CF + `badvpn-udpgw`
  lokal per-user. Client (HTTP Custom / SSH-UDP mode) pakai port itu untuk WhatsApp,
  Telegram, video call. Auto-respawn saat edge restart. Binary: prebuilt → **auto
  fallback build source** (prebuilt butuh GLIBC 2.38, gagal di Ubuntu 22) — build
  badvpn 1.999.130 `-DBUILD_UDPGW=ON`, selalu jalan di glibc lokal.
- **Bandwidth** : token-bucket di edge (bytes/sec, down/up terpisah, hot-apply tanpa restart).
  **Default UNLIMITED** (0/0 = tak dibatasi — utk kenyamanan user). Opsional `--bw D/U`
  kalau mau batasi kecepatan, atau `set --bw 0/0` utk kembalikan unlimited.
- **Quota (GB)** : akumulasi byte in+out per akun. Saat `quota_used >= quota_gb`, edge
  auto-blok (koneksi baru ditolak + koneksi aktif ditutup). `--reset-quota` / naikkan
  kuota untuk membuka. 0 = unlimited.
- **Expire**    : tiap akun punya `expire_ts` (dari `add <days>` / `--add-days`). Saat
  `now >= expire_ts`, edge auto-blok dengan alasan `expired` (koneksi baru ditolak,
  koneksi aktif ditutup, loop 60s). `set <user> --add-days N` / PATCH `add_days`
  memperpanjang → auto unblock `expired`. 0 = unlimited.
  Setelah itu cron 04:17: **default MENGHAPUS** akun expired
  (`AUTO_DELETE_EXPIRED=1`); set `0` di mb.conf = akun **dipertahankan** (tetap
  locked, bisa langsung di-extend) — pilihan operator.
- **Stats**     : byte in/out, sesi total, sesi aktif — persist ke `stats.json` (flush 60s
  + saat remove). Dipakai `list/show --json` dan API.
- **Blocked live**: `list --json` & API `/v1/users` menyertakan `blocked`
  (`null`|`"quota"`|`"expired"`) yang dibaca langsung dari edge (bukan snapshot state).
- **Restore**   : saat edge (re)start, semua user port + udpgw di-load ulang otomatis dari
  `users.json` — reboot node tidak mematikan akun.
- **WARP**      : edge memonitor `warp-cli --status` tiap 60s; kalau down, auto `warp-cli connect`.

## HTTP API (untuk panel/ultrassh)
Edge juga menyerve REST JSON di `0.0.0.0:8499` (default). Auth = `Authorization: Bearer <token>`
(token di-generate `run.sh`, disimpan di `edge.json api.token`; opsional `api.allow_ip`).
Rate limit 30 req/menit/IP. Log ke `/var/log/mb-api.log`.

```
GET    /v1/health          → {status, uptime_s, users, active_sessions, warp, disk_pct}
GET    /v1/users           → {user: {..., stats, quota_used, blocked, expire_ts}}
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

## Verifikasi (2026-10-26)
Suite test di `tests/test.sh` — **57/57 pass** (poll-based, race-safe):
- Relay dual-direction · hot add/remove · rate limit 5 Mbps → terukur 4.92
- **Restore**: kill+restart edge → user port & relay auto-pulihkan (P0)
- **Stats**: byte in terhitung di `stats.json`
- **Quota**: 0.001GB → koneksi baru ditolak saat exceeded → `--reset-quota` membuka
- **CLI `--json`** (list/show) · **HTTP API** (401/404/201/409/400/PATCH/DELETE/health)
- Graceful degrade · anti shell-injection username

Belum di-test di node real: udpgw live traffic, stunnel TLS, WARP.
