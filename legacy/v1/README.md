# mb-ssh — Marzban + SSH Companion

Node VPN full protocol (VLESS/VMess/Trojan via Marzban + akun SSH per client, lifecycle auto-sync).

## Arsitektur
```
node-init.sh (one-liner di VPS kosong)
 ├── Marzban (Docker-less, /opt/marzban) — panel + Xray core
 │     protokol: VLESS(+Reality), VMess, Trojan, SS, Hysteria2
 │     API: http://127.0.0.1:8000/api (OAuth2 token)
 └── mb-ssh (companion)
       ├── sync: webhook Marzban (realtime, port 8087) + cron 5 menit (fallback)
       ├── create: user SSH = vpn_<username-marzban>, expiry shadow-sync
       ├── cleanup: expired/disabled → auto delete (KEEP_EXPIRED_DAYS)
       └── output: /var/lib/mb-ssh/client-<user>.txt (host/port/user/pass + contoh tunnel)
```

## Install node baru
```bash
# di VPS fresh (root), taruh folder mb-ssh dulu:
scp -r mb-ssh/ root@<VPS>:~/
ssh root@<VPS> 'cd ~/mb-ssh && bash node-init.sh'
```
Lalu manual (1x):
1. Buka panel Marzban `http://<VPS>:8000` → login (kredensial dari output install)
2. `nano /etc/mb-ssh.conf` → isi `MB_API_PASS`
3. Panel Marzban → setting webhook: URL `http://127.0.0.1:8087/`
4. `mb-ssh info && mb-ssh sync`

## CLI
```
mb-ssh add <user> [days]    # manual (biasanya auto dari sync/webhook)
mb-ssh set <user> <days>    # ubah expiry
mb-ssh del <user>
mb-ssh list                 # local + marzban
mb-ssh sync                 # reconcile manual
mb-ssh token                # refresh token API
mb-ssh info                 # status
```

## Alur client
1. Admin buat user di Marzban (VLESS/VMess/Trojan + expiry)
2. Auto: akun SSH `vpn_<user>` dibuat, expiry sync, kredensial di `client-vpn_<user>.txt`
3. Client dapat: link subscription Marzban (VPN) + user/pass SSH (tunnel fallback)
4. Expired → SSH account auto-delete; disabled → account dikunci

## Conf (`/etc/mb-ssh.conf`)
| Var | Default | Fungsi |
|---|---|---|
| `MB_API_BASE` | `http://127.0.0.1:8000/api` | API Marzban |
| `MB_API_USER/PASS` | `admin`/`""` | kredensial API |
| `SSH_PORT` | `443` | port SSH client |
| `USER_PREFIX` | `vpn_` | prefix akun SSH |
| `KEEP_EXPIRED_DAYS` | `1` | hapus N hari pasca-expiry |

## Catatan
- sshd drop-in port 443 dipasang idempotent (`/etc/ssh/sshd_config.d/99-client-port.conf`)
- Akun client = user biasa, no sudo, password random 12 char, expiry di `/etc/shadow` (sshd auto-lock saat expire)
- Username Marzban harus `[a-z0-9_]` (3-32 char) — default Marzban sudah begitu
