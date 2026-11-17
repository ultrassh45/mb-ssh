#!/usr/bin/env python3
"""mb-edge v3 — edge proxy untuk node SSH (companion Marzban)

Listen di pool port (CF-allowed) -> relay TCP ke backend:
  - dropbear  (SSH Direct)  127.0.0.1:22022
  - stunnel   (SSH TLS)     127.0.0.1:22443
  - udpgw     (per-user badvpn-udpgw, port lokal)

Fitur:
  - common ports : shared relay (tanpa per-user limit)
  - user ports   : hot add/remove via control socket, token-bucket per-user
  - RESTORE      : edge start -> auto-load users.json (port + udpgw respawn)
  - STATS        : bytes in/out, sessions, active — persist ke stats.json
  - QUOTA        : quota_gb per-user (0=unlimited), auto-block saat exceeded
  - WARP MON     : cek `warp-cli --status` tiap 60s, auto `warp-cli connect`
  - HTTP API     : /v1/health|users (direct IP, Bearer token + IP allowlist
                   + rate limit), shell-out ke mb-ssh2 CLI

Config : /etc/mb-ssh2/edge.json
Control: unix socket /run/mb-ssh/edge.sock  (JSON line)
"""
import asyncio
import hmac
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import urllib.parse
import urllib.request
import sys
import time

CFG_PATH = os.environ.get("MB_EDGE_CFG", "/etc/mb-ssh2/edge.json")
CTL_PATH = os.environ.get("MB_EDGE_CTL", "/run/mb-ssh/edge.sock")
STATE_FILE = os.environ.get("MB_EDGE_STATE", "/var/lib/mb-ssh/users.json")
STATS_FILE = os.environ.get("MB_EDGE_STATS", "/var/lib/mb-ssh/stats.json")
SSH2_BIN = os.environ.get("MB_SSH2_BIN", "/usr/local/bin/mb-ssh2")
API_LOG = os.environ.get("MB_EDGE_API_LOG", "/var/log/mb-api.log")
BADVPN_BIN = os.environ.get("MB_BADVPN_BIN", "/usr/local/bin/badvpn-udpgw")
VERSION = "mb-edge 3.0.0"
GB = 1024 ** 3

# Telegram notif (opsional). Dipakai utk alert quota-habis & multi-login.
# Sumber: edge.json "telegram": {"token", "chat_id"} → fallback env MB_TG_BOT_TOKEN/MB_TG_CHAT_ID
TG_TOKEN = os.environ.get("MB_TG_BOT_TOKEN", "")
TG_CHAT_ID = os.environ.get("MB_TG_CHAT_ID", "")

LOG = lambda m: print(f"[mb-edge {time.strftime('%F %T')}] {m}", flush=True)


def tg_send(text, token=None, chat_id=None):
    """Kirim teks ke Telegram (best-effort, stdlib). Sukses/gagal → LOG."""
    token = token or TG_TOKEN
    chat_id = chat_id or TG_CHAT_ID
    if not token or not chat_id:
        return False
    try:
        data = urllib.parse.urlencode({
            "chat_id": str(chat_id),
            "text": text,
        }).encode()
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=8) as r:
            ok = r.status == 200
        LOG(f"tg_send → {chat_id}: {'ok' if ok else 'http ' + str(r.status)}")
        return ok
    except Exception as e:
        LOG(f"tg_send gagal: {e}")
        return False


class Bucket:
    """Token bucket per arah."""

    def __init__(self, bps):
        self.bps = bps
        self.cap = max(bps / 5.0, 65536)
        self.tokens = 0.0
        self.last = time.monotonic()

    def set_rate(self, bps):
        self.bps = bps
        self.cap = max(bps / 5.0, 65536)
        self.tokens = min(self.tokens, self.cap)

    async def take(self, n):
        if self.bps <= 0:
            return
        while True:
            now = time.monotonic()
            self.tokens = min(self.cap, self.tokens + (now - self.last) * self.bps)
            self.last = now
            if self.tokens >= n:
                self.tokens -= n
                return
            wait = (n - self.tokens) / self.bps
            await asyncio.sleep(max(0.002, min(wait, 0.5)))


async def pump(src, dst, bucket, stat=None, key=None):
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            if stat is not None and key:
                stat[key] += len(data)
            await bucket.take(len(data))
            dst.write(data)
            await dst.drain()
    except (ConnectionError, asyncio.IncompleteReadError, OSError):
        pass
    finally:
        try:
            dst.close()
        except OSError:
            pass
        try:
            await dst.wait_closed()
        except OSError:
            pass


async def relay(c_reader, c_writer, b_reader, b_writer, b_down, b_up,
                stat=None, conns=None):
    try:
        if conns is not None:
            conns.add(c_writer)
        await asyncio.gather(
            pump(c_reader, b_writer, b_down, stat, "in"),
            pump(b_reader, c_writer, b_up, stat, "out"),
        )
    finally:
        if conns is not None:
            conns.discard(c_writer)
        for w in (c_writer, b_writer):
            try:
                w.close()
            except OSError:
                pass


class IpGuard:
    """Limit koneksi baru per client-IP (brute-force guard)."""

    def __init__(self, max_conn=20, window=60, ban_sec=600):
        self.max_conn = max_conn
        self.window = window
        self.ban_sec = ban_sec
        self.hits = {}   # ip -> [ts]
        self.bans = {}   # ip -> until

    def allow(self, ip):
        now = time.time()
        ban = self.bans.get(ip)
        if ban:
            if now < ban:
                return False
            del self.bans[ip]
        hits = [t for t in self.hits.get(ip, []) if now - t < self.window]
        if len(hits) >= self.max_conn:
            self.bans[ip] = now + self.ban_sec
            LOG(f"GUARD: {ip} BAN {self.ban_sec}s (>={self.max_conn} conn/{self.window}s)")
            return False
        hits.append(now)
        self.hits[ip] = hits
        return True


class Edge:
    def __init__(self):
        self.cfg = {}
        g = self.cfg.get("guard", {}) if isinstance(self.cfg, dict) else {}
        self.guard = None  # dibuat di run() setelah load_cfg
        self.common_servers = {}   # port -> (server, backend)
        self.users = {}            # user -> state
        self.stats = {}            # user -> {"in","out","sessions","active"}
        self.ctl_server = None
        self.api_server = None
        self.warp_status = "off"
        self.started = time.time()
        self._api_hits = {}        # ip -> [timestamps]
        self._pending_known_ips = {}   # user -> set(ip) dipersist dari stats.json utk restore
        self._stopping = False

    def load_cfg(self):
        try:
            with open(CFG_PATH) as f:
                self.cfg = json.load(f)
        except FileNotFoundError:
            LOG(f"config {CFG_PATH} tidak ada")
            self.cfg = {"common_ports": [], "common_backend": ""}
        # Telegram notif: edge.json "telegram" {token, chat_id} → override env kalau kosong
        global TG_TOKEN, TG_CHAT_ID
        t = (self.cfg or {}).get("telegram", {}) if isinstance(self.cfg, dict) else {}
        if isinstance(t, dict):
            if t.get("token"):
                TG_TOKEN = str(t["token"])
            if t.get("chat_id"):
                TG_CHAT_ID = str(t["chat_id"])
        # fallback: baca mb.conf (sumber utama bot) — TG_BOT_TOKEN / TG_CHAT_ID
        if not TG_TOKEN or not TG_CHAT_ID:
            try:
                conf = re.search(r"^TG_BOT_TOKEN=\"([^\"]+)\"", open("/etc/mb-ssh2/mb.conf").read(), re.M)
                conf_c = re.search(r"^TG_CHAT_ID=\"([^\"]+)\"", open("/etc/mb-ssh2/mb.conf").read(), re.M)
                if conf and conf.group(1):
                    TG_TOKEN = conf.group(1)
                if conf_c and conf_c.group(1):
                    TG_CHAT_ID = conf_c.group(1)
            except OSError:
                pass
        # dedup notif per user per event (quota, multilogin) supaya tak spam
        if not hasattr(self, "_ntf_dedup"):
            self._ntf_dedup = {}  # key -> ts
        # SlowDNS config (dari mb.conf — sumber utama, diisi lewat menu 19)
        sd = {"enabled": False}
        try:
            conf_txt = open("/etc/mb-ssh2/mb.conf").read()
            def _g(key):
                m = re.search(rf"^{key}=\"([^\"]*)\"", conf_txt, re.M)
                return m.group(1) if m else ""
            enabled = _g("SLOWDNS_ENABLED")
            dom = _g("SLOWDNS_DOMAIN")
            port = _g("SLOWDNS_PORT")
            pub = _g("SLOWDNS_PUBKEY")
            if enabled == "1" and dom:
                sd = {"enabled": True, "host": dom,
                      "port": int(port) if port.isdigit() else 53,
                      "nameserver": dom,
                      "pubkey": pub}
        except OSError:
            pass
        self.slowdns_cfg = sd

    def backend_addr(self, name_or_addr):
        if ":" in name_or_addr:
            return name_or_addr
        return self.cfg.get("backends", {}).get(
            name_or_addr, self.cfg.get("common_backend", "127.0.0.1:22022"))

    # ---------- stats ----------
    def stat(self, user):
        return self.stats.setdefault(user, {"in": 0, "out": 0, "sessions": 0, "active": 0})

    def check_ip_limit(self, user, u, ip):
        """Limit jumlah IP unik per akun. 0 = unlimited.
        Kembalikan True kalau IP diterima, False kalau ditolak (limit penuh)."""
        limit = u.get("ip_limit", 0) or 0
        if limit <= 0:
            return True
        if not ip:
            return True
        known = u.setdefault("known_ips", set())
        if ip in known:
            return True
        if len(known) >= limit:
            LOG(f"REJECT {user} {ip}: ip_limit tercapai ({len(known)}>={limit})")
            return False
        return True

    def note_ip(self, user, u, ip):
        """Catat IP unik yang pernah connect (untuk limit IP)."""
        if not ip:
            return
        known = u.setdefault("known_ips", set())
        if ip not in known:
            known.add(ip)
            LOG(f"IPNEW {user}: {ip} (total {len(known)})")

    def quota_used(self, user):
        s = self.stat(user)
        return s["in"] + s["out"]

    def flush_stats(self):
        try:
            os.makedirs(os.path.dirname(STATS_FILE), exist_ok=True)
            # simpan known_ips per user (set → list) supaya limit IP survive restart
            dump = {u: dict(s) for u, s in self.stats.items()}
            for name, ustate in self.users.items():
                dump.setdefault(name, {})["known_ips"] = sorted(ustate.get("known_ips", set()))
                dump[name].pop("known_ips_count", None)
            with open(STATS_FILE, "w") as f:
                json.dump(dump, f, indent=1)
        except OSError as e:
            LOG(f"flush stats gagal: {e}")

    def load_stats(self):
        try:
            with open(STATS_FILE) as f:
                loaded = json.load(f)
            self.stats = {}
            restored_ip = 0
            for name, s in loaded.items():
                if not isinstance(s, dict):
                    continue
                st = {"in": s.get("in", 0), "out": s.get("out", 0),
                      "sessions": s.get("sessions", 0), "active": 0}
                self.stats[name] = st
                kips = s.get("known_ips") or []
                if isinstance(kips, list) and kips:
                    ustate = self.users.get(name)
                    if ustate is None:
                        # edge belum restore user ini — simpan sementara untuk dipakai restore add_user
                        self._pending_known_ips[name] = set(kips)
                    else:
                        ustate["known_ips"] = set(kips)
                    restored_ip += len(kips)
            LOG(f"stats dipulihkan: {len(self.stats)} user, {restored_ip} known-ip")
        except (FileNotFoundError, json.JSONDecodeError):
            self.stats = {}

    def recover_stats(self):
        """Tarik known_ips yang tersimpan (dari stats.json) ke self.users.
        Dipanggil setelah restore() — reload field lanjutan yang tersimpan."""
        recovered = 0
        for name, kips in self._pending_known_ips.items():
            ustate = self.users.get(name)
            if ustate is not None:
                ustate["known_ips"] = set(kips)
                recovered += len(kips)
                LOG(f"RECOVER known_ips {name}: {len(kips)}")
        self._pending_known_ips = {}
        if recovered:
            LOG(f"known_ips dipulihkan total: {recovered}")

    async def stats_loop(self):
        while not self._stopping:
            try:
                await asyncio.sleep(60)
                self.flush_stats()
                await self.enforce_quota()
            except asyncio.CancelledError:
                break

    def _ntf(self, key, text, cooldown=3600):
        """Kirim notif TG sekali per key per cooldown (default 1 jam)."""
        now = time.time()
        last = self._ntf_dedup.get(key, 0)
        if now - last < cooldown:
            return
        self._ntf_dedup[key] = now
        tg_send(text)

    # ---------- quota + expire ----------
    def _check_expire(self, user, u):
        exp = u.get("expire_ts", 0) or 0
        if not u.get("blocked") and exp > 0 and time.time() >= exp:
            u["blocked"] = "expired"
            LOG(f"EXPIRE {user}: masa berlaku habis — BLOCKED")
            self._ntf(
                f"expired:{user}",
                f"⚠ *AKUN EXPIRED*\nUser: `{user}`\nMasa berlaku habis — diblokir otomatis.",
            )
        return u.get("blocked")

    def _check_quota(self, user, u):
        self._check_expire(user, u)
        if not u.get("blocked") and u.get("quota_bytes", 0) > 0 \
                and self.quota_used(user) >= u["quota_bytes"]:
            u["blocked"] = "quota"
            LOG(f"QUOTA {user}: {self.quota_used(user)} >= {u['quota_bytes']} — BLOCKED")
            gb = u.get("quota_gb", 0)
            self._ntf(
                f"quota:{user}",
                f"⛔ *BANDWIDTH HABIS*\nUser: `{user}`\nKuota {gb}GB terpakai — diblokir otomatis.",
            )
        return u.get("blocked")

    async def enforce_quota(self):
        for user, u in list(self.users.items()):
            self._check_expire(user, u)
            if u.get("quota_bytes", 0) > 0 \
                    and not u.get("blocked") and self.quota_used(user) >= u["quota_bytes"]:
                u["blocked"] = "quota"
                LOG(f"QUOTA {user}: {self.quota_used(user)} >= {u['quota_bytes']} — BLOCKED")
            if u.get("blocked"):
                for w in list(u.get("conns", set())):
                    try:
                        w.close()
                    except OSError:
                        pass

    # ---------- common ports ----------
    async def start_common(self):
        backend = self.cfg.get("common_backend", "")
        for p in self.cfg.get("common_ports", []):
            if not backend:
                LOG(f"common port {p} skip: common_backend kosong")
                continue
            server = await self._listen(p, backend, shared=True)
            if server:
                self.common_servers[p] = (server, backend)

    async def _listen(self, port, backend, shared=False, user=None, u=None):
        b_down = Bucket(0)
        b_up = Bucket(0)

        async def handler(rw_reader, rw_writer):
            peer = rw_writer.get_extra_info("peername")
            if self.guard and not self.guard.allow(peer[0]):
                LOG(f"REJECT {peer}: guard ban")
                rw_writer.close()
                return
            if u is not None:
                if u.get("blocked"):
                    LOG(f"REJECT {user} {peer}: blocked={u['blocked']}")
                    rw_writer.close()
                    return
                st = self.stat(user)
                st["sessions"] += 1
                st["active"] += 1
                u["conns"].add(rw_writer)
                # multi-login alert (aktif >= 2 sesi bersamaan)
                if st["active"] >= 2:
                    self._ntf(
                        f"ml:{user}",
                        f"👥 *LOGIN BERGANDA*\nUser: `{user}`\n{st['active']} sesi aktif bersamaan.",
                        cooldown=600,
                    )
            try:
                ur, uw = await asyncio.open_connection(*backend.split(":"))
            except OSError as e:
                LOG(f"backend {backend} unreachable from {peer}: {e}")
                rw_writer.close()
                return
            LOG(f"conn {peer} -> {backend}" + (f" (user={user})" if user else " (shared)"))
            await relay(rw_reader, rw_writer, ur, uw,
                        u["b_down"] if u else b_down,
                        u["b_up"] if u else b_up,
                        stat=self.stat(user) if user else None,
                        conns=u["conns"] if u else None)
            if u is not None:
                st["active"] -= 1
                u["conns"].discard(rw_writer)

        try:
            server = await asyncio.start_server(handler, "0.0.0.0", port)
        except OSError as e:
            LOG(f"FAIL listen :{port}: {e}")
            return None
        return server

    # ---------- udpgw ----------
    async def ensure_udpgw(self, user, localport):
        """Pastikan badvpn-udpgw listening di 127.0.0.1:<lp> (restore/restart)."""
        try:
            r, w = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", int(localport)), timeout=1.0)
            w.close()
            return True
        except OSError:
            pass
        if not os.path.isfile(BADVPN_BIN):
            LOG(f"udpgw {user}: binary {BADVPN_BIN} tidak ada — skip")
            return False
        try:
            proc = await asyncio.create_subprocess_exec(
                BADVPN_BIN, "--listen-addr", f"127.0.0.1:{localport}",
                "--max-clients", "32", "--max-packets-per-connection", "8",
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                start_new_session=True)
            await asyncio.sleep(0.4)
            ok = proc.returncode is None
            if ok:
                LOG(f"udpgw {user} di-spawn ulang :{localport}")
            else:
                LOG(f"udpgw {user} gagal spawn :{localport}")
            return ok
        except OSError as e:
            LOG(f"udpgw {user} spawn error: {e}")
            return False

    # ---------- per-user ----------
    async def add_user(self, spec):
        user = spec["user"]
        port = int(spec["port"])
        backend = self.backend_addr(spec.get("backend", "127.0.0.1:22022"))
        ip_limit = int(spec.get("ip_limit", 0) or 0)
        if ip_limit <= 0:
            g = self.cfg.get("guard", {}) if isinstance(self.cfg, dict) else {}
            ip_limit = int(g.get("default_ip_limit", self.cfg.get("default_ip_limit", 0)) or 0)
        u = {
            "port": port,
            "backend": backend,
            "b_down": Bucket(spec.get("bw_down_mbps", 0) * 125_000),
            "b_up": Bucket(spec.get("bw_up_mbps", 0) * 125_000),
            "bw_down": spec.get("bw_down_mbps", 0),
            "bw_up": spec.get("bw_up_mbps", 0),
            "server": None,
            "udpgw": None,
            "conns": set(),
            "quota_bytes": int(float(spec.get("quota_gb", 0)) * GB),
            "expire_ts": int(spec.get("expire_ts", 0) or 0),
            "blocked": None,
            "ip_limit": max(0, ip_limit),   # 0 = unlimited
            "known_ips": self._pending_known_ips.pop(user, set()),
        }

        async def handler(r, w, u=u):
            peer = w.get_extra_info("peername")
            if self.guard and not self.guard.allow(peer[0]):
                LOG(f"REJECT {user} {peer}: guard ban")
                w.close()
                return
            blocked = self._check_quota(user, u)
            if blocked:
                LOG(f"REJECT {user} {peer}: blocked={blocked}")
                w.close()
                return
            st = self.stat(user)
            st["sessions"] += 1
            st["active"] += 1
            u["conns"].add(w)
            try:
                ur, uw = await asyncio.open_connection(*u["backend"].split(":"))
            except OSError as e:
                LOG(f"user {user}: backend {u['backend']} unreachable: {e}")
                w.close()
                return
            LOG(f"user {user} conn {peer} -> {u['backend']}")
            await relay(r, w, ur, uw, u["b_down"], u["b_up"],
                        stat=st, conns=u["conns"])
            st["active"] -= 1
            u["conns"].discard(w)

        u["server"] = await self._raw_listen(port, handler)
        if u["server"] is None:
            return f"fail: port {port} busy/unavailable"

        ud = spec.get("udpgw")
        if ud and ud.get("port"):
            # Model B (shared): udpgw.port = port shared publik (7100/7200/...).
            # Daemon badvpn-udpgw jalan via systemd (install/06-udpgw-shared.sh) —
            # edge TIDAK spawn per-user, TIDAK buka listener sendiri.
            # Enforcement IP limit / bw / quota tetap di jalur TCP (relay di atas).
            u["udpgw"] = {"port": int(ud["port"]), "target": None, "server": None}

        self.users[user] = u
        LOG(f"ADD {user}: ssh :{port} -> {backend} "
            f"bw {u['bw_down']}M/{u['bw_up']}M "
            f"quota {spec.get('quota_gb', 0)}GB"
            + (f" udpgw :{ud['port']} -> {ud.get('target')}" if u["udpgw"] else ""))
        return "ok"

    async def _raw_listen(self, port, handler):
        try:
            return await asyncio.start_server(handler, "0.0.0.0", port)
        except OSError as e:
            LOG(f"FAIL listen :{port}: {e}")
            return None

    async def remove_user(self, user):
        u = self.users.pop(user, None)
        if not u:
            return "not_found"
        for w in list(u.get("conns", set())):
            try:
                w.close()
            except OSError:
                pass
        for s in (u["server"], u["udpgw"]["server"] if u["udpgw"] else None):
            if s:
                s.close()
                await s.wait_closed()
        self.stats.pop(user, None)
        self.flush_stats()
        LOG(f"REMOVE {user}")
        return "ok"

    async def set_bw(self, user, spec):
        u = self.users.get(user)
        if not u:
            return "not_found"
        if "bw_down_mbps" in spec:
            u["b_down"].set_rate(spec["bw_down_mbps"] * 125_000)
            u["bw_down"] = spec["bw_down_mbps"]
        if "bw_up_mbps" in spec:
            u["b_up"].set_rate(spec["bw_up_mbps"] * 125_000)
            u["bw_up"] = spec["bw_up_mbps"]
        if "quota_gb" in spec:
            u["quota_bytes"] = int(float(spec["quota_gb"]) * GB)
            LOG(f"SETQUOTA {user}: {spec['quota_gb']}GB")
        if "ip_limit" in spec:
            u["ip_limit"] = max(0, int(spec["ip_limit"] or 0))
            LOG(f"SETIPLIMIT {user}: {u['ip_limit']} ({len(u.get('known_ips', set()))} IP known)")
        if spec.get("reset_quota"):
            s = self.stat(user)
            s["in"] = 0
            s["out"] = 0
            u["blocked"] = None
            self.flush_stats()
            LOG(f"RESETQUOTA {user}")
        if spec.get("unblock"):
            u["blocked"] = None
            LOG(f"UNBLOCK {user}")
        if "expire_ts" in spec:
            u["expire_ts"] = int(spec["expire_ts"] or 0)
            # perpanjangan → auto-unblock jika tadinya blocked karena expired
            if u.get("blocked") == "expired" and (u["expire_ts"] == 0 or u["expire_ts"] > time.time()):
                u["blocked"] = None
                LOG(f"UNBLOCK {user}: diperpanjang (expire={u['expire_ts']})")
        LOG(f"SETBW {user}: {u['bw_down']}M/{u['bw_up']}M")
        return "ok"

    def list_state(self):
        out = {"common": {str(p): b for p, (s, b) in self.common_servers.items()},
               "users": {}, "warp": self.warp_status}
        for user, u in self.users.items():
            s = self.stat(user)
            out["users"][user] = {
                "port": u["port"], "backend": u["backend"],
                "bw_down_mbps": u["bw_down"], "bw_up_mbps": u["bw_up"],
                "udpgw": ({"port": u["udpgw"]["port"], "target": u["udpgw"]["target"]}
                          if u["udpgw"] else None),
                "quota_bytes": u["quota_bytes"],
                "quota_used": self.quota_used(user),
                "blocked": u["blocked"],
                "ip_limit": u.get("ip_limit", 0),
                "known_ips_count": len(u.get("known_ips", set())),
                "stats": s,
            }
        return json.dumps(out)

    # ---------- RESTORE (P0) ----------
    async def restore(self):
        try:
            with open(STATE_FILE) as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            LOG(f"restore: state {STATE_FILE} kosong/tidak ada")
            return 0
        n = 0
        for user, e in data.items():
            port = e.get("port")
            if not port:
                continue
            spec = {
                "user": user,
                "port": port,
                "backend": e.get("backend", "direct"),
                "bw_down_mbps": e.get("bw_down_mbps", 0),
                "bw_up_mbps": e.get("bw_up_mbps", 0),
                "quota_gb": e.get("quota_gb", 0),
                "expire_ts": e.get("expire_ts", 0),
                "ip_limit": e.get("ip_limit", 0),
            }
            if e.get("udpgw"):
                spec["udpgw"] = e["udpgw"]
            resp = await self.add_user(spec)
            if resp == "ok":
                n += 1
            else:
                LOG(f"restore {user} gagal: {resp}")
        LOG(f"RESTORE: {n} user port aktif")
        return n

    # ---------- WARP monitor ----------
    async def warp_loop(self):
        if not self.cfg.get("warp"):
            return
        self.warp_status = "up"
        while not self._stopping:
            try:
                st = await asyncio.create_subprocess_exec(
                    "warp-cli", "--status",
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
                out, _ = await asyncio.wait_for(st.communicate(), timeout=10)
                connected = b"Connected" in out
                if not connected and self.warp_status == "up":
                    LOG("WARP down — mencoba connect ulang...")
                    await asyncio.create_subprocess_exec(
                        "warp-cli", "connect",
                        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                        start_new_session=True)
                    await asyncio.sleep(5)
                    st2 = await asyncio.create_subprocess_exec(
                        "warp-cli", "--status",
                        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
                    out2, _ = await asyncio.wait_for(st2.communicate(), timeout=10)
                    connected = b"Connected" in out2
                self.warp_status = "up" if connected else "down"
                if not connected:
                    LOG(f"WARP masih down")
            except (OSError, asyncio.TimeoutError) as e:
                self.warp_status = "error"
                LOG(f"warp check error: {e}")
            await asyncio.sleep(60)

    # ---------- control socket ----------
    async def ctl_handler(self, reader, writer):
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    spec = json.loads(line)
                except json.JSONDecodeError:
                    resp = "error: bad json"
                else:
                    cmd = spec.get("cmd")
                    if cmd == "add":
                        resp = await self.add_user(spec)
                    elif cmd == "remove":
                        resp = await self.remove_user(spec.get("user", ""))
                    elif cmd == "setbw":
                        resp = await self.set_bw(spec.get("user", ""), spec)
                    elif cmd == "list":
                        resp = self.list_state()
                    elif cmd == "flush":
                        self.flush_stats()
                        resp = "ok"
                    else:
                        resp = f"error: unknown cmd {cmd}"
                writer.write((resp + "\n").encode())
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()

    async def serve_ctl(self):
        try:
            os.unlink(CTL_PATH)
        except FileNotFoundError:
            pass
        usock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        usock.bind(CTL_PATH)
        usock.listen()
        usock.setblocking(False)
        self.ctl_server = await asyncio.start_server(self.ctl_handler, sock=usock)

    # ---------- HTTP API ----------
    def api_cfg(self):
        return self.cfg.get("api", {})

    def _api_log(self, ip, method, path, status):
        try:
            with open(API_LOG, "a") as f:
                f.write(f"{time.strftime('%F %T')} {ip} {method} {path} {status}\n")
        except OSError:
            pass

    def _api_auth(self, headers, peer_ip):
        a = self.api_cfg()
        token = a.get("token", "")
        if not token:
            return "error: api token tidak di-set (edge.json api.token)"
        hauth = headers.get("authorization", "")
        if not hauth.startswith("Bearer "):
            return None
        if not hmac.compare_digest(hauth[7:].strip(), token):
            return None
        allow = a.get("allow_ip", [])
        if allow and peer_ip not in allow:
            return "ip_not_allowed"
        return "ok"

    def _api_rate(self, ip):
        now = time.time()
        hits = [t for t in self._api_hits.get(ip, []) if now - t < 60]
        if len(hits) >= 30:
            return False
        hits.append(now)
        self._api_hits[ip] = hits
        return True

    async def _cli(self, *args, timeout=15):
        env = dict(os.environ)
        # pastikan CLI melihat ctl socket + state + config yang SAMA dengan edge ini
        env["EDGE_CTL"] = CTL_PATH
        env["STATE_DIR"] = os.path.dirname(STATE_FILE)
        env["CONF_DIR"] = os.path.dirname(CFG_PATH)
        try:
            p = await asyncio.create_subprocess_exec(
                SSH2_BIN, *args,
                env=env,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            out, err = await asyncio.wait_for(p.communicate(), timeout=timeout)
            return p.returncode, out.decode().strip(), err.decode().strip()
        except (OSError, asyncio.TimeoutError) as e:
            return 1, "", f"cli error: {e}"

    @staticmethod
    def _json_resp(reason, obj):
        body = json.dumps(obj).encode()
        return (f"HTTP/1.1 {reason}\r\n"
                f"Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\n"
                f"Connection: close\r\n\r\n").encode() + body

    USER_RE = re.compile(r"^[a-z0-9_]{3,32}$")

    async def _send(self, writer, resp):
        writer.write(resp)
        await writer.drain()
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass

    async def api_handler(self, reader, writer):
        ip = writer.get_extra_info("peername")
        ip = ip[0] if ip else "?"
        try:
            raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10)
        except (asyncio.LimitOverrunError, asyncio.TimeoutError, OSError):
            writer.close()
            return
        try:
            head = raw.decode("latin1")
            lines = head.split("\r\n")
            method, path, _ = lines[0].split(" ")
            headers = {}
            for ln in lines[1:]:
                if ":" in ln:
                    k, v = ln.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            cl = int(headers.get("content-length", 0) or 0)
            body = b""
            if cl:
                body = await asyncio.wait_for(reader.readexactly(cl), timeout=10)
        except (ValueError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            self._api_log(ip, "?", "?", 400)
            await self._send(writer, self._json_resp("400 Bad Request", {"error": "bad request"}))
            return

        self._api_log(ip, method, path, 0)
        if not self._api_rate(ip):
            resp = self._json_resp("429 Too Many Requests", {"error": "rate limit"})
            self._api_log(ip, method, path, 429)
            await self._send(writer, resp)
            return

        auth = self._api_auth(headers, peer_ip=ip)
        if auth != "ok":
            if auth == "ip_not_allowed":
                code, msg, why = 403, "Forbidden", {"error": "ip not allowed"}
            elif isinstance(auth, str) and auth.startswith("error:"):
                code, msg, why = 500, "Server Error", {"error": auth}
            else:
                code, msg, why = 401, "Unauthorized", {"error": "bad token"}
            self._api_log(ip, method, path, code)
            await self._send(writer, self._json_resp(f"{code} {msg}", why))
            return

        # ---------- routing ----------
        status, payload = await self._api_route(method, path, body)
        self._api_log(ip, method, path, status)
        await self._send(writer, self._json_resp(
            f"{status} OK" if 200 <= status < 300 else f"{status} Error", payload))

    async def _api_route(self, method, path, body):
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            return 400, {"error": "bad json body"}

        if path == "/v1/health" and method == "GET":
            return await self._health()
        if path == "/v1/users" and method == "GET":
            return await self._users_list()
        if path == "/v1/users" and method == "POST":
            return await self._user_create(data)
        if path.split("?")[0] == "/v1/exists" and method == "GET":
            # query: ?username=x — parse dari path raw
            q = path.split("?", 1)[1] if "?" in path else ""
            usr = ""
            for kv in q.split("&"):
                if kv.startswith("username="):
                    usr = kv[9:]
                    break
            return await self._user_exists(usr)
        m = re.fullmatch(r"/v1/users/([a-z0-9_]{3,32})", path)
        if m:
            user = m.group(1)
            if method == "GET":
                return await self._user_show(user)
            if method == "PATCH":
                return await self._user_patch(user, data)
            if method == "DELETE":
                return await self._user_delete(user)
        return 404, {"error": "not found"}

    async def _health(self):
        du = shutil.disk_usage("/")
        total_active = sum(s["active"] for s in self.stats.values())
        return 200, {
            "status": "ok", "version": VERSION,
            "uptime_s": int(time.time() - self.started),
            "users": len(self.users), "active_sessions": total_active,
            "common_ports": sorted(self.common_servers.keys()),
            "warp": self.warp_status,
            "slowdns": getattr(self, "slowdns_cfg", {"enabled": False}),
            "disk_pct": round(100 * du.used / du.total),
        }

    async def _users_list(self):
        rc, out, err = await self._cli("list", "--json")
        if rc != 0:
            return 500, {"error": err or out}
        try:
            return 200, json.loads(out)
        except json.JSONDecodeError:
            return 500, {"error": "cli output bukan json"}

    async def _user_exists(self, user):
        """Cek username sudah dipakai di node ini (lintas protokol).
        - SSH        : users.json (akun mb-ssh) ATAU user UNIX (/etc/passwd)
        - VLESS/VMess/Trojan : Marzban db.sqlite3 (users table)
        Return: 200 {exists: bool, in: [ssh|marzban|unix]}
        """
        user = str(user or "").strip().lower()
        if not self.USER_RE.match(user):
            return 400, {"error": "username harus 3-32 char [a-z0-9_]"}
        found = []
        # 1. SSH state
        if self.users.get(user):
            found.append("ssh")
        # 2. user UNIX
        try:
            import pwd
            pwd.getpwnam(user)
            found.append("unix")
        except KeyError:
            pass
        # 3. Marzban db
        try:
            import sqlite3, os
            db = "/opt/marzban/db.sqlite3"
            if os.path.exists(db):
                con = sqlite3.connect(db)
                cur = con.execute("SELECT 1 FROM users WHERE username LIKE ?", (user,))
                if cur.fetchone():
                    found.append("marzban")
                con.close()
        except Exception:
            pass
        return 200, {"exists": bool(found), "in": found}

    async def _user_create(self, d):
        user = str(d.get("username", "")).lower()
        if not self.USER_RE.match(user):
            return 400, {"error": "username harus 3-32 char [a-z0-9_]"}
        days = d.get("days", 30)
        bw_down, bw_up = d.get("bw_down", 0), d.get("bw_up", 0)
        quota = d.get("quota_gb", 0)
        backend = d.get("backend", "direct")
        password = d.get("password", "")
        if not (isinstance(days, int) and 0 <= days <= 3650):
            return 400, {"error": "days harus int 0-3650"}
        if not (isinstance(bw_down, int) and 0 <= bw_down <= 1000):
            return 400, {"error": "bw_down harus int 0-1000"}
        if not (isinstance(bw_up, int) and 0 <= bw_up <= 1000):
            return 400, {"error": "bw_up harus int 0-1000"}
        if not (isinstance(quota, (int, float)) and 0 <= quota <= 10000):
            return 400, {"error": "quota_gb harus int 0-10000"}
        if backend not in ("direct", "tls"):
            return 400, {"error": "backend harus direct|tls"}
        if password and not isinstance(password, str):
            return 400, {"error": "password harus string"}
        args = ["add", user, str(days), "--bw", f"{bw_down}/{bw_up}",
                "--backend", backend]
        if password:
            args += ["--pass", password]
        if d.get("udp"):
            args.append("--udp")
        if d.get("warp"):
            args.append("--warp")
        if quota:
            args += ["--quota", str(quota)]
        rc, out, err = await self._cli(*args, timeout=30)
        if rc != 0:
            code = 409 if ("sudah ada" in err or "sudah ada" in out) else 400
            return code, {"error": err or out}
        return 201, {"user": user, "created": True, "info": out}

    async def _user_show(self, user):
        rc, out, err = await self._cli("show", user, "--json")
        if rc != 0:
            return 404, {"error": err or out}
        try:
            return 200, json.loads(out)
        except json.JSONDecodeError:
            return 500, {"error": "cli output bukan json"}

    async def _user_patch(self, user, d):
        args = ["set", user]
        if "add_days" in d:
            ad = d["add_days"]
            if not (isinstance(ad, int) and 1 <= ad <= 3650):
                return 400, {"error": "add_days harus int 1-3650"}
            args += ["--add-days", str(ad)]
        if "bw_down" in d or "bw_up" in d:
            cur = self.users.get(user, {})
            bd = d.get("bw_down", cur.get("bw_down", 0))
            bu = d.get("bw_up", cur.get("bw_up", 0))
            if not (0 <= bd <= 1000 and 0 <= bu <= 1000):
                return 400, {"error": "bw harus 0-1000"}
            args += ["--bw", f"{bd}/{bu}"]
        if "quota_gb" in d:
            q = d["quota_gb"]
            if not (isinstance(q, (int, float)) and 0 <= q <= 10000):
                return 400, {"error": "quota_gb harus int 0-10000"}
            args += ["--quota", str(q)]
        if d.get("reset_quota"):
            args.append("--reset-quota")
        if d.get("unblock"):
            args.append("--unblock")
        if d.get("warp") is not None:
            args.append("--warp" if d["warp"] else "--no-warp")
        if len(args) == 2:
            return 400, {"error": "body kosong (add_days/bw_down/bw_up/quota_gb/...)"}
        rc, out, err = await self._cli(*args, timeout=30)
        if rc != 0:
            return 404 if "tidak ada" in (err or "") else 400, {"error": err or out}
        return 200, {"user": user, "updated": True, "info": out}

    async def _user_delete(self, user):
        rc, out, err = await self._cli("del", user, timeout=30)
        if rc != 0:
            return 404, {"error": err or out}
        return 200, {"user": user, "deleted": True}

    async def serve_api(self):
        a = self.api_cfg()
        port = int(a.get("port", 8499))
        try:
            self.api_server = await asyncio.start_server(self.api_handler, "0.0.0.0", port)
            LOG(f"HTTP API up :{port}"
                + (f" allow_ip={a.get('allow_ip')}" if a.get("allow_ip") else ""))
        except OSError as e:
            LOG(f"FAIL API listen :{port}: {e}")

    # ---------- main ----------
    async def run(self):
        self.load_cfg()
        g = self.cfg.get("guard", {})
        self.guard = IpGuard(g.get("max_conn", 20), g.get("window", 60),
                             g.get("ban_sec", 600))
        self.load_stats()
        await self.serve_ctl()
        await self.start_common()
        await self.restore()
        self.recover_stats()    # tarik known_ips tersimpan ke self.users setelah restore
        await self.serve_api()
        LOG(f"edge up. control={CTL_PATH} cfg={CFG_PATH} ver={VERSION}")
        tasks = [asyncio.create_task(self.stats_loop()),
                 asyncio.create_task(self.warp_loop())]
        try:
            await self.ctl_server.serve_forever()
        finally:
            self._stopping = True
            for t in tasks:
                t.cancel()
            self.flush_stats()
            LOG("edge stopped (stats di-flush)")


def main():
    edge = Edge()
    try:
        asyncio.run(edge.run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
