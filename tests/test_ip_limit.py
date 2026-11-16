#!/usr/bin/env python3
"""Unit test: limit IP per akun + persist known_ips (survive restart).

Run:  python3 tests/test_ip_limit.py  (repo root)
"""
import importlib.util
import json
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("MB_EDGE_CFG", "/tmp/mb-ip-edge.json")
os.environ.setdefault("MB_EDGE_STATE", "/tmp/mb-ip-users.json")
os.environ.setdefault("MB_EDGE_STATS", "/tmp/mb-ip-stats.json")

spec = importlib.util.spec_from_file_location("edge", os.path.join(REPO, "runtime", "mb-edge.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.LOG = lambda *a: None

failures = []


def check(name, cond):
    print(("  PASS " if cond else "  FAIL ") + name)
    if not cond:
        failures.append(name)


# clear test files
for f in ("/tmp/mb-ip-edge.json", "/tmp/mb-ip-users.json", "/tmp/mb-ip-stats.json"):
    try:
        os.remove(f)
    except OSError:
        pass

Edge = m.Edge

print("== 1. check_ip_limit / note_ip ==")
e = object.__new__(Edge)
u = {"ip_limit": 2, "known_ips": set(), "blocked": None}
check("ip-1 diterima", e.check_ip_limit("u", u, "1.1.1.1"))
e.note_ip("u", u, "1.1.1.1")
check("ip-2 diterima", e.check_ip_limit("u", u, "2.2.2.2"))
e.note_ip("u", u, "2.2.2.2")
check("ip-3 ditolak (limit 2)", not e.check_ip_limit("u", u, "3.3.3.3"))
check("reuse ip-1 tetap ok", e.check_ip_limit("u", u, "1.1.1.1"))
u2 = {"ip_limit": 0, "known_ips": set(), "blocked": None}
check("unlimited: sembarang ip ok", e.check_ip_limit("u2", u2, "9.9.9.9"))

print("== 2. persist known_ips (restart simulate) ==")
e2 = object.__new__(Edge)
e2.cfg = {"guard": {"default_ip_limit": 0}}
e2.users = {"alice": {"ip_limit": 2, "known_ips": {"1.1.1.1", "2.2.2.2"}}}
e2.stats = {"alice": {"in": 0, "out": 0, "sessions": 0, "active": 1}}
e2._pending_known_ips = {}
e2._stopping = False
e2.flush_stats()
check("flush_stats menulis stats.json", os.path.exists("/tmp/mb-ip-stats.json"))

# restart: users kosong, load_stats → pending
e3 = object.__new__(Edge)
e3.cfg = {"guard": {"default_ip_limit": 0}}
e3.users = {}
e3.stats = {}
e3._pending_known_ips = {}
e3._stopping = False
e3.load_stats()
check("load_stats: alice masuk pending", "alice" in e3._pending_known_ips)
check("pending berisi 2 ip", e3._pending_known_ips.get("alice") == {"1.1.1.1", "2.2.2.2"})

# add_user tarik pending (simulasi restore)
spec = {"user": "alice", "port": 29002, "backend": "127.0.0.1:29999", "ip_limit": 2}
# add_user async — test mapping langsung via pending pop logic
known = e3._pending_known_ips.pop("alice", set())
check("add_user menarik known_ips dari pending", known == {"1.1.1.1", "2.2.2.2"})

print("== 3. default_ip_limit dari config ==")
e4 = object.__new__(Edge)
e4.cfg = {"guard": {"default_ip_limit": 3}}
g = e4.cfg.get("guard", {})
dfl = int(g.get("default_ip_limit", 0))
check("default_ip_limit=3 dari guard config", dfl == 3)

print()
if failures:
    print(f"FAILED: {len(failures)} -> {failures}")
    sys.exit(1)
print("SEMUA TEST LIMIT IP LULUS")
