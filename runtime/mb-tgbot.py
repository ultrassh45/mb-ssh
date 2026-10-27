#!/usr/bin/env python3
"""mb-tgbot.py — bot Telegram utk backup/restore mb-ssh (stdlib only).

Long polling getUpdates; hanya memproses chat_id di allow-list
(TG_CHAT_ID di /etc/mb-ssh2/mb.conf, boleh koma-separated).
Eksekusi CLI mb-ssh2, balas output ke chat.

Perintah:
  /backup   → mb-ssh2 backup   (upload state+Marzban+config ke R2)
  /restore  → mb-ssh2 restore  (tarik dari R2, tarung DB Marzban)
  /status   → ringkasan node + config backup
  /help

Tanpa TG_BOT_TOKEN/TG_CHAT_ID = bot exit 1 (log jelas, tidak loop restart
karena unit pakai Restart=on-failure).
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

CONF = os.environ.get("MB_CONF", "/etc/mb-ssh2/mb.conf")
CLI = os.environ.get("MB_SSH2_BIN", "/usr/local/bin/mb-ssh2")
STATE = os.environ.get("STATE_DIR", "/var/lib/mb-ssh")
POLL_TIMEOUT = 30
MAX_REPLY = 3500


def load_conf():
    d = {}
    try:
        for line in open(CONF):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return d


def tg_call(token, method, **kw):
    data = json.dumps(kw).encode()
    req = urllib.request.Request(
        "https://api.telegram.org/bot%s/%s" % (token, method),
        data, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def run_cli(args):
    env = dict(os.environ, MB_TG_BOT="1")  # bot = caller → CLI tidak double-notify
    p = subprocess.run(["bash", CLI] + args,
                       capture_output=True, text=True, timeout=900, env=env)
    out = (p.stdout or "") + (("\n" + p.stderr) if p.stderr else "")
    return p.returncode, out.strip() or "(tanpa output)"


def fmt(s, n=MAX_REPLY):
    if len(s) <= n:
        return s
    half = n // 2
    return s[:half] + "\n\n... [%d char dipotong] ...\n\n" % (len(s) - n) + s[-half:]


def handle(text, conf):
    """Kembalikan teks balasan. Dipisah dari main() agar bisa di-test."""
    t = (text or "").strip()
    cmd = t.split()[0].lower() if t else ""
    if cmd in ("/help", "help", "?"):
        return ("Perintah:\n"
                "/backup        — backup ke R2 sekarang\n"
                "/schedule N m  — backup tiap N menit (contoh: /schedule 30 m)\n"
                "/schedule N j  — backup tiap N jam (contoh: /schedule 6 j)\n"
                "/schedule 0    — backup tiap hari 03:03 (default)\n"
                "/restore       — restore dari R2 (menimpa state + DB Marzban)\n"
                "/status        — status node + config backup\n\n"
                "Balasan saya = output asli dari CLI node.")
    if cmd in ("/backup", "backup"):
        rc, out = run_cli(["backup"])
        return ("[OK] BACKUP\n\n" if rc == 0 else "[GAGAL] BACKUP (rc=%d)\n\n" % rc) + fmt(out)
    if cmd in ("/restore", "restore"):
        rc, out = run_cli(["restore"])
        return ("[OK] RESTORE\n\n" if rc == 0 else "[GAGAL] RESTORE (rc=%d)\n\n" % rc) + fmt(out)
    if cmd in ("/schedule", "schedule"):
        # /schedule 30 m → tiap 30 menit | /schedule 6 j → tiap 6 jam | /schedule 0 → hari 03:03
        args = t.split()[1:]
        n = args[0] if args else ""
        unit = args[1] if len(args) > 1 else ""
        rc, out = run_cli(["schedule", n, unit])
        return ("[OK] JADWAL\n\n" if rc == 0 else "[GAGAL] JADWAL (rc=%d)\n\n" % rc) + fmt(out)
    if cmd in ("/status", "status"):
        # total per service (reuse CLI status: 'Akun: ssh=N vless=N vmess=N trojan=N')
        total = ""
        try:
            # pars baris 'Akun:' dari output mb-ssh2 status
            out = subprocess.run(
                [CLI, "status"], capture_output=True, text=True, timeout=15
            ).stdout
            for ln in out.splitlines():
                if ln.startswith("Akun"):
                    total = ln.split(":", 1)[1].strip()
                    break
        except Exception:
            total = ""
        if not total:
            try:
                nu = len(json.load(open(os.path.join(STATE, "users.json"))))
                total = "ssh=%s" % nu
            except Exception:
                total = "ssh=?"
        # status service (kalau systemctl ada)
        svc = ""
        try:
            r = subprocess.run(["systemctl", "is-active", "mb-edge", "dropbear-client", "stunnel", "mb-tgbot", "marzban"],
                               capture_output=True, text=True, timeout=10)
            names = ["mb-edge", "dropbear-client", "stunnel", "mb-tgbot", "marzban"]
            acts = r.stdout.split()
            svc = " / ".join("%s:%s" % (names[i], acts[i] if i < len(acts) else "?") for i in range(len(names)))
        except Exception:
            svc = "n/a"
        return ("Node   : %s\n"
                "Akun   : %s\n"
                "Servis : %s\n"
                "R2     : %s\n"
                "Path   : %s\n"
                "Bot    : tersambung (chat allow-list)") % (
                    os.uname().nodename, total, svc,
                    conf.get("R2_REMOTE") or "<belum diset>",
                    conf.get("R2_PATH") or "-")
    return "Perintah tidak dikenal: %s\nKetik /help" % (t or "(kosong)")


def main():
    conf = load_conf()
    token = conf.get("TG_BOT_TOKEN", "")
    chats = [c.strip() for c in conf.get("TG_CHAT_ID", "").split(",") if c.strip()]
    if not token or not chats:
        print("mb-tgbot: TG_BOT_TOKEN/TG_CHAT_ID kosong di %s — bot off." % CONF,
              file=sys.stderr)
        print("mb-tgbot: set via: mb-ssh2 setup (wizard) atau mb-ssh2 menu", file=sys.stderr)
        sys.exit(1)
    try:
        me = tg_call(token, "getMe")
    except Exception as e:
        print("mb-tgbot: token TIDAK VALID atau network gagal: %r" % (e,), file=sys.stderr)
        print("mb-tgbot: cek token di @BotFather lalu ulangi: mb-ssh2 setup", file=sys.stderr)
        sys.exit(1)
    print("mb-tgbot: on sebagai @%s, allow chat: %s" % (
        me["result"]["username"], ",".join(chats)), flush=True)
    offset = None
    while True:
        try:
            kw = {"timeout": POLL_TIMEOUT, "allowed_updates": ["message"]}
            if offset is not None:
                kw["offset"] = offset
            r = tg_call(token, "getUpdates", **kw)
            for up in r.get("result", []):
                offset = up["update_id"] + 1
                m = up.get("message", {})
                chat_id = str(m.get("chat", {}).get("id", ""))
                if chat_id not in chats:
                    print("mb-tgbot: abaikan dari chat %s (bukan allow-list)" % chat_id,
                          flush=True)
                    continue
                print("mb-tgbot: perintah %r dari %s" % (m.get("text"), chat_id), flush=True)
                reply = handle(m.get("text", ""), conf)
                tg_call(token, "sendMessage", chat_id=chat_id, text=reply[:4096])
        except Exception as e:
            print("mb-tgbot: error %r — retry 5s" % (e,), flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
