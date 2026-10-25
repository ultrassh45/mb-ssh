# mb-ssh v2 — SSH product untuk node Marzban

SSH line **standalone** (tidak coupled Marzban), per-user: port CF dedicated + bandwidth limit + UDPGW + WARP opsional. Arsitektur rujuk: `superdecrypt-dev/autoscript` (pola, bukan copy kode — GPL-safe).

## Arsitektur
```
Client → Cloudflare (port pool) → mb-edge (python asyncio, 1 proses)
  ├── common ports (shared)  → dropbear 127.0.0.1:22022
  ├── user port  P1          → dropbear 127.0.0.1:22022   (SSH Direct, token-bucket per user)
  ├── user port  P2          → stunnel  127.0.0.1:22443   (SSH TLS flavor)
  └── user udpgw port U1     → badvpn-udpgw 127.0.0.1:170xx (UDP over SSH-grade tunnel)
```

- **Zero restart**: add/del/set user = hot via control socket unix. sshd/dropbear/stunnel/edge tidak pernah restart per-user.
- **Per-user bandwidth**: token-bucket di edge (bytes/sec, down/up terpisah, hot-apply) — tanpa tc/cgroup (tidak tersedia di banyak VPS image).
- **Per-user "IP"**: port dedicated per akun (model ultrassh existing). WARP per-user (uidrange → tabel routing → exit via interface WARP) = exit IP Cloudflare tanpa beli IP.
- **UDP per-user**: tiap akun punya instance `badvpn-udpgw` sendiri (spawn/kill on demand, failure terisolasi).

## File
```
v2/
├── mb-edge.py     # edge proxy (asyncio): relay + token-bucket + hot control socket
├── mb-ssh2.sh     # CLI: add/del/set/list/show/edge-*
├── node-init2.sh  # bootstrap node: Marzban + dropbear + stunnel + badvpn + edge (+ --warp)
└── README.md
```

## CLI
```
mb-ssh2 add <user> [days] [--udp] [--bw DOWN/UP] [--backend direct|tls] [--warp]
mb-ssh2 del <user>
mb-ssh2 set <user> [days] [--bw DOWN/UP]
mb-ssh2 list
mb-ssh2 show <user>
```

## Config
- `/etc/mb-ssh2/mb.conf` — PORT_POOL (default: `8080 8880 2052 2082 2086 2053 2083 2087 2096 8443`), DOMAIN, WARP_IF
- `/etc/mb-ssh2/edge.json` — common_ports + common_backend
- Port 80/443 = Marzban (xray), port 22 = admin sshd. Jangan taruh di PORT_POOL.

## Kapasitas node
- 10 port pool → 10 akun SSH (tanpa UDP) / 5 akun (SSH+UDP, 2 port per akun)
- Scale = node baru (jalankan node-init2.sh di VPS lain)

## Deploy
```bash
scp -r /root/projects/mb-ssh root@<VPS_NODE>:~/
ssh root@<VPS_NODE> 'cd ~/mb-ssh/v2 && bash node-init2.sh'   # atau + --warp
# lalu:
mb-ssh2 add budi 30 --udp --bw 100/50
cat /var/lib/mb-ssh/client-budi.txt
```

## Cloudflare
Proxy (orange) semua port pool + 80/443 di domain node. SSH client: `ssh -p <port> user@domain`.
Flavor TLS: client pakai `ProxyCommand="stunnel -connect domain:<port>"` atau import cert node (`/etc/mb-ssh2/cert.pem`).

## Status verifikasi (2026-10-25)
- relay dual-direction: PASS (echo test)
- hot add/remove user: PASS (tanpa restart, port close verified)
- rate limit: PASS (4 MB @ limit 5 Mbps → terukur 4.92 Mbps, error 1.6%)
- CLI add/del/list/show + state + client-info: PASS
- graceful degrade: edge down / badvpn absen → pesan jelas, state konsisten
- Belum di-test di node real: udpgw live, stunnel TLS, WARP (butuh environment node)
