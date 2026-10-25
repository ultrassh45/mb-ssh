#!/usr/bin/env python3
"""mb-edge — edge proxy untuk node SSH (companion Marzban v2)

Listen di pool port (CF-allowed) -> relay TCP ke backend:
  - dropbear  (SSH Direct)
  - stunnel   (SSH TLS)
  - udpgw     (port local per-user badvpn-udpgw)

Fitur:
  - common ports  : shared relay ke backend default (tanpa per-user BW)
  - user ports    : hot add/remove via control socket, per-user token bucket
                    (bw_down/bw_up bytes/sec), per-user udpgw relay
  - hot reload    : tanpa restart, koneksi existing tidak putus

Config : /etc/mb-ssh/edge.json
Control: unix socket /run/mb-ssh/edge.sock  (JSON line)
  {"cmd":"add",   "user":"vpn_x", "port":2082, "backend":"127.0.0.1:22022",
   "bw_down_mbps":100, "bw_up_mbps":50, "udpgw": {"port":2052, "target":"127.0.0.1:17001"}}
  {"cmd":"remove","user":"vpn_x"}
  {"cmd":"setbw", "user":"vpn_x", "bw_down_mbps":50}
  {"cmd":"list"}
"""
import asyncio
import json
import os
import signal
import socket
import sys
import time

CFG_PATH = os.environ.get("MB_EDGE_CFG", "/etc/mb-ssh/edge.json")
CTL_PATH = os.environ.get("MB_EDGE_CTL", "/run/mb-ssh/edge.sock")
LOG = lambda m: print(f"[mb-edge {time.strftime('%F %T')}] {m}", flush=True)


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


async def pump(src, dst, bucket):
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            await bucket.take(len(data))
            dst.write(data)
            await dst.drain()
    except (ConnectionError, asyncio.IncompleteReadError, OSError):
        pass
    finally:
        for w in (dst,):
            try:
                w.close()
            except OSError:
                pass
        try:
            await dst.wait_closed()
        except OSError:
            pass


async def relay(c_reader, c_writer, b_reader, b_writer, b_down, b_up):
    try:
        await asyncio.gather(
            pump(c_reader, b_writer, b_down),
            pump(b_reader, c_writer, b_up),
        )
    finally:
        for w in (c_writer, b_writer):
            try:
                w.close()
            except OSError:
                pass


class Edge:
    def __init__(self):
        self.cfg = {}
        self.common_servers = {}   # port -> (server, backend)
        self.users = {}            # user -> {port, backend, b_down, b_up, server, udpgw:{port,target,server}}
        self.ctl_server = None
        self.loop = None

    def load_cfg(self):
        try:
            with open(CFG_PATH) as f:
                self.cfg = json.load(f)
        except FileNotFoundError:
            LOG(f"config {CFG_PATH} tidak ada — common ports kosong")
            self.cfg = {"common_ports": [], "common_backend": ""}

    # ---- common ports ----
    async def start_common(self):
        backend = self.cfg.get("common_backend", "")
        for p in self.cfg.get("common_ports", []):
            if not backend:
                LOG(f"common port {p} skip: common_backend kosong")
                continue
            server = await self._listen(p, backend, shared=True)
            if server:
                self.common_servers[p] = (server, backend)

    async def _listen(self, port, backend, shared=False, user=None):
        b_down = Bucket(0)
        b_up = Bucket(0)

        async def handler(rw_reader, rw_writer):
            peer = rw_writer.get_extra_info("peername")
            try:
                ur, uw = await asyncio.open_connection(*backend.split(":"))
            except OSError as e:
                LOG(f"backend {backend} unreachable from {peer}: {e}")
                rw_writer.close()
                return
            LOG(f"conn {peer} -> {backend}" + (f" (user={user})" if user else " (shared)"))
            await relay(rw_reader, rw_writer, ur, uw, b_down, b_up)

        try:
            server = await asyncio.start_server(handler, "0.0.0.0", port)
        except OSError as e:
            LOG(f"FAIL listen :{port}: {e}")
            return None
        return server

    # ---- per-user ----
    async def add_user(self, spec):
        user = spec["user"]
        port = int(spec["port"])
        backend = spec.get("backend", "127.0.0.1:22022")
        u = {
            "port": port,
            "backend": backend,
            "b_down": Bucket(spec.get("bw_down_mbps", 0) * 125_000),
            "b_up": Bucket(spec.get("bw_up_mbps", 0) * 125_000),
            "bw_down": spec.get("bw_down_mbps", 0),
            "bw_up": spec.get("bw_up_mbps", 0),
            "server": None,
            "udpgw": None,
        }

        async def handler(r, w, u=u):
            peer = w.get_extra_info("peername")
            try:
                ur, uw = await asyncio.open_connection(*u["backend"].split(":"))
            except OSError as e:
                LOG(f"user {user}: backend {u['backend']} unreachable: {e}")
                w.close()
                return
            LOG(f"user {user} conn {peer} -> {u['backend']}")
            await relay(r, w, ur, uw, u["b_down"], u["b_up"])

        u["server"] = await self._raw_listen(port, handler)
        if u["server"] is None:
            return f"fail: port {port} busy/unavailable"

        # udpgw relay (opsional)
        ud = spec.get("udpgw")
        if ud and ud.get("port"):
            target = ud.get("target", "127.0.0.1:17001")

            async def ud_handler(r, w, t=target):
                peer = w.get_extra_info("peername")
                try:
                    ur, uw = await asyncio.open_connection(*t.split(":"))
                except OSError as e:
                    LOG(f"user {user} udpgw target {t} unreachable: {e}")
                    w.close()
                    return
                LOG(f"user {user} udpgw conn {peer} -> {t}")
                await relay(r, w, ur, uw, u["b_down"], u["b_up"])

            u["udpgw"] = {"port": int(ud["port"]), "target": target,
                          "server": await self._raw_listen(int(ud["port"]), ud_handler)}
            if not u["udpgw"]["server"]:
                LOG(f"user {user}: udpgw port {ud['port']} gagal")

        self.users[user] = u
        LOG(f"ADD {user}: ssh :{port} -> {backend} "
            f"bw {u['bw_down']}M/{u['bw_up']}M"
            + (f" udpgw :{ud['port']} -> {ud.get('target')}" if u['udpgw'] else ""))
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
        for s in (u["server"], u["udpgw"]["server"] if u["udpgw"] else None):
            if s:
                s.close()
                await s.wait_closed()
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
        LOG(f"SETBW {user}: {u['bw_down']}M/{u['bw_up']}M")
        return "ok"

    def list_state(self):
        out = {"common": {str(p): b for p, (s, b) in self.common_servers.items()},
               "users": {}}
        for user, u in self.users.items():
            out["users"][user] = {
                "port": u["port"], "backend": u["backend"],
                "bw_down_mbps": u["bw_down"], "bw_up_mbps": u["bw_up"],
                "udpgw": ({"port": u["udpgw"]["port"], "target": u["udpgw"]["target"]}
                          if u["udpgw"] and u["udpgw"]["server"] else None),
            }
        return json.dumps(out)

    # ---- control socket ----
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

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.load_cfg()
        await self.serve_ctl()
        await self.start_common()
        LOG(f"edge up. control={CTL_PATH} cfg={CFG_PATH}")
        await self.ctl_server.serve_forever()


def main():
    edge = Edge()
    try:
        asyncio.run(edge.run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
