#!/usr/bin/env python3
# Telegram control bot. Requires /etc/warp-telegram.env with TG_TOKEN and TG_CHAT.
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

CFG_PATH = "/etc/warp-monitor.conf"
TG_PATH = "/etc/warp-telegram.env"
KEY = "/root/.ssh/id_ed25519_monitor"


def load_env(path):
    data = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    data[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return data


CFG = load_env(CFG_PATH)
TG = load_env(TG_PATH)
TOKEN = TG.get("TG_TOKEN", "")
CHAT = str(TG.get("TG_CHAT", ""))
SELF_IP = CFG.get("SELF_IP", "")

SERVERS = []
if CFG.get("SERVER1_IP"):
    SERVERS.append({"id": "s1", "name": CFG.get("SERVER1_NAME", "Server 1"),
                    "ip": CFG["SERVER1_IP"], "rotate": CFG.get("ROTATE_S1", "")})
if CFG.get("SERVER2_IP"):
    SERVERS.append({"id": "s2", "name": CFG.get("SERVER2_NAME", "Server 2"),
                    "ip": CFG["SERVER2_IP"], "rotate": CFG.get("ROTATE_S2", "")})

_CACHE = {}
_CACHE_TTL = 30

REMOTE_CMD = r"""
echo "WARP=$(warp-cli --accept-tos status | tr '\n' ' ')"
echo "W4=$(curl -4 -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')"
echo "W6=$(curl -6 -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')"
echo "AWG=$(docker ps --format '{{.Names}}' | grep '^amnezia-awg' | tr '\n' ' ')"
echo "DISK=$(df --output=pcent / | tail -1 | tr -dc '0-9')"
echo "UP=$(cut -d' ' -f1 /proc/uptime)"
C=$(docker ps --format '{{.Names}}' | grep '^amnezia-awg' | head -1)
D=$(docker exec "$C" awg show all dump 2>/dev/null)
echo "ONL=$(printf '%s\n' "$D" | awk -v now=$(date +%s) 'NF==9 && $6>0 && (now-$6)<180 {c++} END{print c+0}')"
echo "TOT=$(printf '%s\n' "$D" | awk 'NF==9 {c++} END{print c+0}')"
echo "HS=$(printf '%s\n' "$D" | awk 'NF==9 && $6>0 && $6>m {m=$6} END{print m+0}')"
echo "HSP=$(printf '%s\n' "$D" | awk 'NF==9 && $6>0 && $6>m {m=$6; p=$5} END{print (p?p:"-")}')"
echo "CHG=$(n=$(awk -v t=$(($(date +%s)-86400)) '$1>=t' /var/lib/warp-monitor/ipv4.log 2>/dev/null | wc -l); echo $(( n > 0 ? n - 1 : 0 )))"
"""


def sh(cmd, timeout=20):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except Exception:
        return ""


def tcp_ok(ip, port=22, timeout=3):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except Exception:
        return False


def human_uptime(seconds):
    try:
        seconds = int(float(seconds))
    except Exception:
        return "—"
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    return f"{d} д {h} ч" if d else f"{h} ч {m} мин"


def human_age(seconds):
    try:
        seconds = int(seconds)
    except Exception:
        return "—"
    if seconds < 60:
        return "только что"
    if seconds < 3600:
        return f"{seconds // 60} мин назад"
    if seconds < 86400:
        return f"{seconds // 3600} ч назад"
    return f"{seconds // 86400} д назад"


def warp_ip(version):
    out = sh(f"curl -{version} -s --connect-timeout 3 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace")
    for line in out.splitlines():
        if line.startswith("ip="):
            return line.split("=", 1)[1]
    return "—"


def awg_peers():
    """Return (active, total, last_handshake_epoch, last_peer_ip)."""
    name = sh("docker ps --format '{{.Names}}' | grep '^amnezia-awg' | head -1")
    if not name:
        return 0, 0, 0, "-"
    dump = sh(f"docker exec {name} awg show all dump")
    now = time.time()
    active = total = 0
    best, best_peer = 0, "-"
    for line in dump.splitlines():
        parts = line.split("\t")
        if len(parts) != 9:
            continue
        total += 1
        try:
            hs = int(parts[5])
        except ValueError:
            continue
        if hs > 0:
            if hs > best:
                best, best_peer = hs, parts[4]
            if now - hs < 180:
                active += 1
    return active, total, best, best_peer


def ipv4_changes():
    since = time.time() - 86400
    n = 0
    try:
        with open("/var/lib/warp-monitor/ipv4.log", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if not parts:
                    continue
                try:
                    if int(parts[0]) >= since:
                        n += 1
                except ValueError:
                    continue
    except FileNotFoundError:
        return 0
    return max(0, n - 1)


def local_status(name, ip):
    warp_ok = "Connected" in sh("warp-cli --accept-tos status")
    containers = sh("docker ps --format '{{.Names}}'")
    awg = [c for c in containers.splitlines() if c.startswith("amnezia-awg")]
    try:
        with open("/proc/uptime") as f:
            uptime = f.read().split()[0]
    except Exception:
        uptime = "0"
    peers, peers_total, last_hs, last_peer = awg_peers()
    return {
        "name": name, "ip": ip, "online": True, "ssh": True,
        "warp_ok": warp_ok,
        "warp4": warp_ip(4) if warp_ok else "—",
        "warp6": warp_ip(6) if warp_ok else "—",
        "amnezia": ", ".join(awg) if awg else "не запущена",
        "disk": int(sh("df --output=pcent / | tail -1 | tr -dc '0-9'") or 0),
        "uptime": human_uptime(uptime),
        "peers": peers,
        "total": peers_total,
        "last_hs": last_hs,
        "last_peer": last_peer,
        "chg": ipv4_changes(),
    }


def peer_status(name, ip):
    data = {
        "name": name, "ip": ip, "online": False, "ssh": False,
        "warp_ok": False, "warp4": "—", "warp6": "—",
        "amnezia": "—", "disk": 0, "uptime": "—",
        "peers": 0, "total": 0, "last_hs": 0, "last_peer": "-", "chg": 0,
    }
    if not tcp_ok(ip):
        return data
    data["online"] = True
    if not os.path.exists(KEY):
        return data
    ssh_base = (f"ssh -i {KEY} -o BatchMode=yes -o ConnectTimeout=6 "
                f"-o StrictHostKeyChecking=accept-new root@{ip}")
    out = sh(f"{ssh_base} 'bash -s' <<'EOF'\n{REMOTE_CMD}\nEOF", timeout=40)
    if "WARP=" not in out:
        return data
    data["ssh"] = True
    for line in out.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == "WARP":
            data["warp_ok"] = "Connected" in v
        elif k == "W4":
            data["warp4"] = v or "—"
        elif k == "W6":
            data["warp6"] = v or "—"
        elif k == "AWG":
            data["amnezia"] = v or "не запущена"
        elif k == "DISK":
            data["disk"] = int(v or 0)
        elif k == "UP":
            data["uptime"] = human_uptime(v or 0)
        elif k == "ONL":
            data["peers"] = int(v or 0)
        elif k == "TOT":
            data["total"] = int(v or 0)
        elif k == "HS":
            data["last_hs"] = int(v or 0)
        elif k == "HSP":
            data["last_peer"] = v or "-"
        elif k == "CHG":
            data["chg"] = int(v or 0)
    return data


def get_server(server):
    ip = server["ip"]
    now = time.time()
    if ip in _CACHE and now - _CACHE[ip][0] < _CACHE_TTL:
        return _CACHE[ip][1]
    status = local_status(server["name"], ip) if ip == SELF_IP else peer_status(server["name"], ip)
    _CACHE[ip] = (now, status)
    return status


def short_name(server):
    return server["name"].split(" / ")[0].split()[0]


def api(method, **params):
    data = json.dumps(params).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TOKEN}/{method}",
        data=data, headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        if e.code == 400 and ("message is not modified" in body or "query is too old" in body):
            return {"ok": False}
        print(f"HTTP {e.code}: {body}", flush=True)
        try:
            return json.loads(body)
        except Exception:
            return {"ok": False}
    except Exception as e:
        print(f"API error: {e}", flush=True)
        return {"ok": False}


def send(text, kb=None):
    params = {"chat_id": CHAT, "text": text, "parse_mode": "HTML",
              "disable_web_page_preview": True}
    if kb:
        params["reply_markup"] = kb
    return api("sendMessage", **params)


def edit(mid, text, kb=None):
    params = {"chat_id": CHAT, "message_id": mid, "text": text,
              "parse_mode": "HTML", "disable_web_page_preview": True}
    if kb:
        params["reply_markup"] = kb
    return api("editMessageText", **params)


def main_kb():
    rows = [
        [{"text": "📊 Отчёт", "callback_data": "report"},
         {"text": "🔄 Обновить", "callback_data": "status"}],
    ]
    nav = [{"text": "🖥 " + short_name(s), "callback_data": s["id"]} for s in SERVERS]
    for i in range(0, len(nav), 2):
        rows.append(nav[i:i + 2])
    rows.append([{"text": "🌐 WARP", "callback_data": "warp"},
                 {"text": "📡 Ping", "callback_data": "ping"}])
    return {"inline_keyboard": rows}


def back_kb():
    return {"inline_keyboard": [[{"text": "⬅️ В меню", "callback_data": "menu"}]]}


def online_str(st):
    if not st.get("ssh", True) or not st.get("total"):
        return "—"
    return f"{st['peers']} из {st['total']}"


def activity_str(st):
    if not st.get("last_hs"):
        return "клиентов ещё не было"
    return f"{human_age(time.time() - st['last_hs'])} ({st.get('last_peer', '-')})"


def summary(s):
    st = get_server(s)
    if not st["online"]:
        return f"🔴 <b>{s['name']}</b> · <code>{s['ip']}</code>\nSSH: нет ответа"
    if not st.get("ssh", True):
        return f"🟡 <b>{s['name']}</b> · <code>{s['ip']}</code>\nонлайн · метрики по SSH недоступны"
    warp = "on" if st["warp_ok"] else "off"
    people = f" · 👥 {st['peers']}/{st['total']}" if st.get("total") else ""
    return (f"🟢 <b>{s['name']}</b> · <code>{s['ip']}</code>\n"
            f"WARP {warp} · IPv4 <code>{st['warp4']}</code>{people}")


def status_text():
    now = datetime.now().strftime("%d.%m %H:%M UTC")
    parts = [f"🛰 <b>Статус серверов</b>\n<i>{now}</i>\n"]
    for s in SERVERS:
        parts.append(summary(s))
    parts.append("\n<i>Проверка: каждую минуту</i>")
    return "\n\n".join(parts)


def detail_text(s):
    st = get_server(s)
    if not st["online"]:
        return (f"🖥 <b>{s['name']}</b>\n<code>{s['ip']}</code>\n\n"
                f"🔴 <b>недоступен</b>\nПорт 22: нет ответа\n\n"
                f"<i>Ротация IPv6: {s['rotate']}</i>")
    if not st.get("ssh", True):
        return (f"🖥 <b>{s['name']}</b>\n<code>{s['ip']}</code>\n\n"
                f"🟡 онлайн, но метрики по SSH недоступны\n\n"
                f"<i>Ротация IPv6: {s['rotate']}</i>")
    return (
        f"🖥 <b>{s['name']}</b>\n<code>{s['ip']}</code>\n\n"
        f"WARP: <b>{'Connected' if st['warp_ok'] else 'Disconnected'}</b>\n"
        f"IPv4: <code>{st['warp4']}</code>\n"
        f"IPv6: <code>{st['warp6']}</code>\n"
        f"Amnezia: <b>{st['amnezia']}</b>\n"
        f"👥 Онлайн: <b>{online_str(st)}</b>\n"
        f"🕒 Последний клиент: <b>{activity_str(st)}</b>\n"
        f"🔄 Смены IPv4: <b>{st['chg']}</b> за 24ч\n"
        f"Диск: <b>{st['disk']}%</b>\n"
        f"Uptime: {st['uptime']}\n\n"
        f"<i>Ротация IPv6: {s['rotate']}</i>"
    )


def warp_text():
    parts = ["🌐 <b>Cloudflare WARP</b>\n"]
    for s in SERVERS:
        st = get_server(s)
        if st["online"] and st.get("ssh", True):
            parts.append(f"<b>{s['name']}</b>\n"
                         f"{'🟢 Connected' if st['warp_ok'] else '🔴 Disconnected'}\n"
                         f"IPv4 <code>{st['warp4']}</code>\n"
                         f"IPv6 <code>{st['warp6']}</code>\n"
                         f"🔄 смен IPv4 за 24ч: <b>{st['chg']}</b>")
        else:
            parts.append(f"<b>{s['name']}</b>\n⚪ нет данных")
    parts.append("<i>Смены IPv4 пишутся в журнал, IPv6 ротируется ежедневно.</i>")
    return "\n\n".join(parts)


def ping_text():
    lines = ["📡 <b>Проверка задержки</b>\n"]
    for s in SERVERS:
        if s["ip"] == SELF_IP:
            lines.append(f"<b>{s['name']}</b>: локально")
            continue
        t0 = time.time()
        ok = tcp_ok(s["ip"])
        ms = int((time.time() - t0) * 1000)
        lines.append(f"<b>{s['name']}</b>: {'🟢' if ok else '🔴'} {ms} мс")
    t0 = time.time()
    res = api("getMe")
    lines.append(f"<b>Telegram API</b>: {'🟢' if res.get('ok') else '🔴'} {int((time.time() - t0) * 1000)} мс")
    return "\n".join(lines)


def run_report():
    try:
        r = subprocess.run(["/usr/local/sbin/warp-daily-report.py"],
                           capture_output=True, text=True, timeout=240)
        return r.returncode == 0, (r.stderr or r.stdout)[-500:]
    except Exception as e:
        return False, str(e)


def handle_message(msg):
    if str(msg.get("chat", {}).get("id")) != CHAT:
        return
    text = (msg.get("text") or "").strip()
    cmd = text.split()[0].lower().split("@")[0] if text else ""

    if cmd in ("/start", "/menu"):
        send("🛰 <b>VPN Control</b>\nУправление и мониторинг серверов.\nВыберите действие:", main_kb())
    elif cmd in ("/help",):
        send("🛰 <b>Команды</b>\n\n"
             "/menu — главное меню\n"
             "/status — статус серверов\n"
             + "".join(f"/{s['id']} — {short_name(s)}\n" for s in SERVERS) +
             "/warp — состояние WARP\n"
             "/report — отчёт с графиком\n"
             "/ping — задержка", back_kb())
    elif cmd == "/status":
        send(status_text(), main_kb())
    elif cmd.startswith("/") and cmd[1:] in [s["id"] for s in SERVERS]:
        s = next(s for s in SERVERS if s["id"] == cmd[1:])
        send(detail_text(s), back_kb())
    elif cmd == "/warp":
        send(warp_text(), back_kb())
    elif cmd == "/ping":
        send(ping_text(), back_kb())
    elif cmd == "/report":
        send("📊 Готовлю отчёт…")
        ok, err = run_report()
        send("✅ Отчёт отправлен." if ok else f"❌ Ошибка отчёта:\n<code>{err}</code>", main_kb())
    else:
        send("Неизвестная команда. Вот меню:", main_kb())


def handle_callback(cb):
    msg = cb.get("message", {})
    if str(msg.get("chat", {}).get("id")) != CHAT:
        return
    mid = msg.get("message_id")
    data = cb.get("data", "")
    api("answerCallbackQuery", callback_query_id=cb.get("id"))

    if data in ("status", "refresh"):
        edit(mid, status_text(), main_kb())
    elif data in [s["id"] for s in SERVERS]:
        s = next(s for s in SERVERS if s["id"] == data)
        edit(mid, detail_text(s), back_kb())
    elif data == "warp":
        edit(mid, warp_text(), back_kb())
    elif data == "ping":
        edit(mid, ping_text(), back_kb())
    elif data == "report":
        send("📊 Готовлю отчёт…")
        ok, err = run_report()
        send("✅ Отчёт отправлен." if ok else f"❌ Ошибка отчёта:\n<code>{err}</code>", main_kb())
    elif data == "menu":
        edit(mid, "🛰 <b>VPN Control</b>\nВыберите действие:", main_kb())


def should_notify_start():
    path = "/var/lib/warp-monitor/bot-last-start"
    now = time.time()
    try:
        with open(path) as f:
            last = float(f.read().strip())
    except Exception:
        last = 0
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(str(now))
    except Exception:
        pass
    return now - last > 600


def main():
    commands = [
        {"command": "menu", "description": "Главное меню"},
        {"command": "status", "description": "Статус серверов"},
    ] + [{"command": s["id"], "description": f"Сервер {short_name(s)}"} for s in SERVERS] + [
        {"command": "warp", "description": "Состояние WARP"},
        {"command": "report", "description": "Отчёт с графиком"},
        {"command": "ping", "description": "Задержка"},
    ]
    api("setMyCommands", commands=commands)
    if should_notify_start():
        send("🤖 <b>VPN Control запущен</b>\nВыберите действие:", main_kb())

    offset = 0
    while True:
        res = api("getUpdates", offset=offset, timeout=30,
                  allowed_updates=["message", "callback_query"])
        if not res.get("ok"):
            time.sleep(30 if res.get("error_code") == 409 else 5)
            continue
        for upd in res.get("result", []):
            offset = upd["update_id"] + 1
            try:
                if "message" in upd:
                    handle_message(upd["message"])
                elif "callback_query" in upd:
                    handle_callback(upd["callback_query"])
            except Exception as e:
                print(f"handler error: {e}", flush=True)


if __name__ == "__main__":
    if not TOKEN or not CHAT:
        print("Telegram is not configured: /etc/warp-telegram.env is missing or empty.")
        sys.exit(0)
    if "--test" in sys.argv:
        print(status_text())
        for s in SERVERS:
            print(f"\n--- {s['id']} ---")
            print(detail_text(s))
        print("\n--- warp ---")
        print(warp_text())
        print("\n--- ping ---")
        print(ping_text())
    else:
        main()
