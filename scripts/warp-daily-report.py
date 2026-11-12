#!/usr/bin/env python3
# Daily report: renders a dashboard PNG and (optionally) sends it to Telegram.
#
# Works without Telegram: if /etc/warp-telegram.env is missing or has no token,
# the image is still generated and its path is printed.
import csv
import os
import subprocess
import time
from datetime import datetime, timedelta

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib.ticker import MaxNLocator

BG = "#0b1020"
CARD = "#141b2d"
EDGE = "#243049"
WHITE = "#e8eefc"
MUTED = "#8b98b8"
GREEN = "#22c55e"
RED = "#ef4444"
CYAN = "#22d3ee"
AMBER = "#f59e0b"

plt.rcParams["font.family"] = "DejaVu Sans"

STATE_DIR = "/var/lib/warp-monitor"
HIST = os.path.join(STATE_DIR, "history.csv")
STATE = os.path.join(STATE_DIR, "state.env")
IPLOG = os.path.join(STATE_DIR, "ipv4.log")
CONF = "/etc/warp-monitor.conf"
TG_ENV = "/etc/warp-telegram.env"


def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except Exception:
        return ""


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


def plural(n, one, few, many):
    n = abs(int(n))
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


def human_uptime(seconds):
    try:
        seconds = int(float(seconds))
    except Exception:
        return "—"
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d} д {h} ч"
    if h:
        return f"{h} ч {m} мин"
    return f"{m} мин"


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


def tcp_ok(ip, port=22, timeout=3):
    import socket
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except Exception:
        return False


def warp_ip(version):
    out = sh(f"curl -{version} -s --connect-timeout 3 --max-time 8 "
             "https://www.cloudflare.com/cdn-cgi/trace")
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
    best = 0
    best_peer = "-"
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


def ipv4_changes(since):
    entries = 0
    try:
        with open(IPLOG, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if parts:
                    try:
                        if int(parts[0]) >= since:
                            entries += 1
                    except ValueError:
                        continue
    except FileNotFoundError:
        pass
    return max(0, entries - 1) if entries else 0


def local_status(cfg):
    warp_ok = "Connected" in sh("warp-cli --accept-tos status")
    containers = sh("docker ps --format '{{.Names}}'")
    awg = [c for c in containers.splitlines() if c.startswith("amnezia-awg")]
    try:
        with open("/proc/uptime") as f:
            uptime = f.read().split()[0]
    except Exception:
        uptime = "0"
    disk = sh("df --output=pcent / | tail -1 | tr -dc '0-9'") or "0"
    peers, peers_total, last_hs, last_peer = awg_peers()
    return {
        "name": cfg.get("SELF_NAME", "Server"),
        "ip": cfg.get("SELF_IP", ""),
        "online": True,
        "warp_ok": warp_ok,
        "warp4": warp_ip(4) if warp_ok else "—",
        "warp6": warp_ip(6) if warp_ok else "—",
        "amnezia": ", ".join(awg) if awg else "не запущена",
        "uptime": human_uptime(uptime),
        "disk": int(disk),
        "peers": peers,
        "total": peers_total,
        "last_hs": last_hs,
        "last_peer": last_peer,
        "chg": ipv4_changes(time.time() - 86400),
    }


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


def peer_status(cfg):
    peer_ip = cfg.get("PEER_IP", "")
    if not peer_ip:
        return None
    data = {
        "name": cfg.get("PEER_NAME", "Peer"),
        "ip": peer_ip,
        "online": tcp_ok(peer_ip),
        "warp_ok": False,
        "warp4": "—",
        "warp6": "—",
        "amnezia": "—",
        "uptime": "—",
        "disk": 0,
        "peers": 0,
        "total": 0,
        "last_hs": 0,
        "last_peer": "-",
        "chg": 0,
        "ssh": False,
    }
    if not data["online"]:
        return data
    key = "/root/.ssh/id_ed25519_monitor"
    ssh_base = (f"ssh -i {key} -o BatchMode=yes -o ConnectTimeout=8 "
                f"-o StrictHostKeyChecking=accept-new root@{peer_ip}")
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


def read_history():
    rows = []
    try:
        with open(HIST, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                try:
                    rows.append({
                        "ts": int(row["ts"]),
                        "peer_ok": int(row["peer_ok"]),
                        "peer_ms": int(row["peer_ms"]),
                        "warp_ok": int(row["warp_ok"]),
                        "awg_ok": int(row["awg_ok"]),
                        "disk": int(row["disk"]),
                        "peers": int(row.get("peers") or 0),
                        "total": int(row.get("total") or 0),
                        "warp4": (row.get("warp4") or "").strip(),
                    })
                except Exception:
                    continue
    except FileNotFoundError:
        pass
    return rows[-24 * 60:]


def read_state():
    state = {}
    try:
        with open(STATE, encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    state[k] = v
    except FileNotFoundError:
        pass
    return state


def card(fig, x, y, w, h, title, subtitle, ok, lines, availability):
    ax = fig.add_axes([x, y, w, h])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")
    ax.add_patch(FancyBboxPatch((0.01, 0.02), 0.98, 0.96,
                                boxstyle="round,pad=0.008,rounding_size=0.05",
                                facecolor=CARD, edgecolor=EDGE, linewidth=1.2,
                                transform=ax.transAxes))
    color = GREEN if ok else RED
    ax.plot(0.065, 0.86, "o", color=color, markersize=11, transform=ax.transAxes)
    ax.text(0.10, 0.855, title, color=WHITE, fontsize=15, fontweight="bold",
            va="center", transform=ax.transAxes)
    ax.text(0.10, 0.755, subtitle, color=MUTED, fontsize=9.5,
            va="center", transform=ax.transAxes)
    ax.plot([0.06, 0.94], [0.69, 0.69], color=EDGE, lw=1, transform=ax.transAxes)
    ypos = 0.585
    step = 0.43 / max(1, len(lines) - 1)
    for label, value, vcolor in lines:
        ax.text(0.06, ypos, label, color=MUTED, fontsize=10.5, va="center", transform=ax.transAxes)
        ax.text(0.30, ypos, value, color=vcolor, fontsize=11, va="center",
                transform=ax.transAxes, fontweight="bold")
        ypos -= step
    ax.plot([0.06, 0.94], [0.045, 0.045], color=EDGE, lw=7,
            solid_capstyle="round", transform=ax.transAxes)
    fill = 0.88 * max(0.0, min(100.0, availability)) / 100.0
    if fill > 0:
        bar_color = GREEN if availability > 99 else (AMBER if availability > 80 else RED)
        ax.plot([0.06, 0.06 + fill], [0.045, 0.045], color=bar_color, lw=7,
                solid_capstyle="round", transform=ax.transAxes)
    ax.text(0.94, 0.092, f"доступность 24ч · {availability:.0f}%", color=MUTED,
            fontsize=9, ha="right", transform=ax.transAxes)


def online_label(st):
    if not st.get("ssh", True) or not st.get("total"):
        return "—"
    return f"{st['peers']} из {st['total']}"


def ipv4_label(st):
    n = st.get("chg", 0)
    return f"{st['warp4']} · {n} {plural(n, 'смена', 'смены', 'смен')}"


def activity_label(st):
    if not st.get("last_hs"):
        return "клиентов ещё не было"
    return f"клиент {human_age(time.time() - st['last_hs'])}"


def server_lines(st, color_missing):
    return [
        ("WARP", "Connected" if st["warp_ok"] else "Disconnected",
         GREEN if st["warp_ok"] else RED),
        ("IPv4", ipv4_label(st), WHITE),
        ("IPv6", st["warp6"][:26] + ("…" if len(st["warp6"]) > 26 else ""), WHITE),
        ("Онлайн", online_label(st), GREEN if st["peers"] else MUTED),
        ("Amnezia", st["amnezia"], GREEN if "amnezia" in st["amnezia"] else color_missing),
        ("Диск", f"{st['disk']}%", RED if st["disk"] >= 90 else WHITE),
    ]


def build_dashboard(cfg, me, peer, history, state):
    now = datetime.now()
    fig = plt.figure(figsize=(7.2, 11.2), dpi=150, facecolor=BG)

    fig.text(0.06, 0.982, "VPN INFRASTRUCTURE", color=CYAN, fontsize=10, fontweight="bold")
    fig.text(0.06, 0.940, "Ежедневный отчёт", color=WHITE, fontsize=27, fontweight="bold")
    fig.text(0.94, 0.982, now.strftime("%d.%m.%Y"), color=WHITE, fontsize=12, ha="right")
    fig.text(0.94, 0.952, cfg.get("REPORT_TIME", "08:00 MSK"), color=MUTED, fontsize=10, ha="right")

    peer_total = len(history)
    peer_up = sum(1 for r in history if r["peer_ok"])
    peer_pct = (peer_up / peer_total * 100) if peer_total else 0
    me_pct = 100.0 if me["warp_ok"] and "amnezia" in me["amnezia"] else 0.0

    me_sub = f"{me['ip']} · uptime {me['uptime']} · {activity_label(me)}"
    card(fig, 0.06, 0.690, 0.88, 0.230, me["name"], me_sub,
         True, server_lines(me, RED), me_pct)

    if peer is not None:
        if peer["online"]:
            peer_lines = server_lines(peer, MUTED)
        else:
            since = int(state.get("PEER_SINCE", "0") or 0)
            down_for = int(time.time()) - since if since else 0
            down_label = human_uptime(down_for) if down_for >= 60 else "только что обнаружен"
            peer_lines = [
                ("Состояние", "недоступен", RED),
                ("Простой", down_label, AMBER),
                ("Порт 22", "нет ответа", RED),
                ("Онлайн", "—", MUTED),
                ("Amnezia", "—", MUTED),
                ("Диск", "—", MUTED),
            ]
        peer_sub = peer["ip"] + (f" · uptime {peer['uptime']}" if peer["online"] and peer["uptime"] != "—" else "")
        if peer["online"]:
            peer_sub += f" · {activity_label(peer)}"
        card(fig, 0.06, 0.435, 0.88, 0.230, peer["name"], peer_sub,
             peer["online"], peer_lines, peer_pct)

    # --- charts ---------------------------------------------------------------
    now_dt = datetime.now()

    def style(ax):
        ax.set_facecolor(CARD)
        for spine in ax.spines.values():
            spine.set_color(EDGE)
        ax.tick_params(colors=MUTED, labelsize=9)
        ax.grid(True, color=EDGE, linewidth=0.7, alpha=0.7)
        ax.set_axisbelow(True)
        ax.set_xlim(now_dt - timedelta(hours=24), now_dt)
        ax.xaxis.set_major_locator(mdates.HourLocator(interval=6))
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))

    if peer is not None:
        axu_pos = [0.085, 0.268, 0.83, 0.130]
        lat_pos = [0.085, 0.070, 0.83, 0.150]
    else:
        axu_pos = [0.085, 0.090, 0.83, 0.300]
        lat_pos = None

    axu = fig.add_axes(axu_pos)
    style(axu)
    if lat_pos:
        axu.tick_params(labelbottom=False)
    axu.yaxis.set_major_locator(MaxNLocator(integer=True))
    axu.set_title("Amnezia · пользователи онлайн", color=WHITE, fontsize=12,
                  loc="left", pad=8)
    axu.set_ylabel("чел.", color=MUTED, fontsize=9)
    if history:
        times = [datetime.fromtimestamp(r["ts"]) for r in history]
        onl = [r["peers"] for r in history]
        axu.fill_between(times, 0, onl, color=CYAN, alpha=0.20, step="post", zorder=2)
        axu.step(times, onl, color=CYAN, linewidth=1.8, where="post", zorder=3)
        axu.set_ylim(0, max(2, max(onl) * 1.35))
        axu.text(0.99, 0.92, f"сейчас {onl[-1]}", color=WHITE, fontsize=9,
                 ha="right", va="top", transform=axu.transAxes)
    else:
        axu.set_ylim(0, 5)
        axu.text(0.5, 0.45, "Данные появятся после первых проверок", color=MUTED,
                 fontsize=10, ha="center", va="center", transform=axu.transAxes)

    if lat_pos:
        ax = fig.add_axes(lat_pos)
        style(ax)
        peer_short = peer["name"].split(" / ")[0]
        ax.set_title(f"Задержка до {peer_short} · 24 часа", color=WHITE, fontsize=12,
                     loc="left", pad=8)
        ax.set_ylabel("мс", color=MUTED, fontsize=9)
        if history:
            times = [datetime.fromtimestamp(r["ts"]) for r in history]
            lat = [r["peer_ms"] if r["peer_ok"] else None for r in history]
            ax.plot(times, lat, color=CYAN, linewidth=1.8, zorder=3)
            ax.fill_between(times, 0, 1, where=[r["peer_ok"] == 0 for r in history],
                            color=RED, alpha=0.22, transform=ax.get_xaxis_transform(), zorder=1)
            valid = [x for x in lat if x is not None]
            if valid:
                ax.set_ylim(0, max(50, max(valid) * 1.25))
            else:
                ax.set_ylim(0, 100)
                ax.text(0.5, 0.60, "Нет успешных проверок за 24 часа", color=MUTED,
                        fontsize=10, ha="center", va="center", transform=ax.transAxes)
        else:
            ax.set_ylim(0, 100)
            ax.text(0.5, 0.5, "Данные появятся после первых проверок", color=MUTED,
                    fontsize=10, ha="center", va="center", transform=ax.transAxes)

    fig.text(0.06, 0.025, "Cloudflare WARP · ротация IPv6 ежедневно · алерты при простое > 5 мин",
             color=MUTED, fontsize=8.5)
    fig.text(0.94, 0.025, now.strftime("%H:%M UTC"), color=MUTED, fontsize=8.5, ha="right")

    os.makedirs(STATE_DIR, exist_ok=True)
    path = os.path.join(STATE_DIR, f"report-{now.strftime('%Y%m%d-%H%M')}.png")
    fig.savefig(path, facecolor=BG)
    plt.close(fig)
    return path


def send_photo(token, chat, path, caption):
    return subprocess.run([
        "curl", "-s", "--max-time", "90", "-X", "POST",
        f"https://api.telegram.org/bot{token}/sendPhoto",
        "-F", f"chat_id={chat}",
        "-F", f"photo=@{path}",
        "-F", f"caption={caption}",
        "-F", "parse_mode=HTML",
    ], capture_output=True, text=True).stdout


def send_text(token, chat, text):
    return subprocess.run([
        "curl", "-s", "--max-time", "30", "-X", "POST",
        f"https://api.telegram.org/bot{token}/sendMessage",
        "--data-urlencode", f"chat_id={chat}",
        "--data-urlencode", "parse_mode=HTML",
        "--data-urlencode", f"text={text}",
    ], capture_output=True, text=True).stdout


def online_suffix(st):
    if not st.get("ssh", True) or not st.get("total"):
        return ""
    return f" · 👥 {st['peers']}/{st['total']}"


def server_caption(st, dot="🟢"):
    if not st["online"]:
        return f"🔴 <b>{st['name']}</b>: недоступен"
    text = (f"{dot} <b>{st['name']}</b>: WARP {'on' if st['warp_ok'] else 'off'}, "
            f"IPv4 <code>{st['warp4']}</code>{online_suffix(st)}")
    if st.get("chg"):
        text += f" · 🔄 {st['chg']}"
    if st.get("last_hs"):
        text += f" · 🕒 {human_age(time.time() - st['last_hs'])}"
    return text


def main():
    cfg = load_env(CONF)
    tg = load_env(TG_ENV)
    token = tg.get("TG_TOKEN", "")
    chat = tg.get("TG_CHAT", "")

    me = local_status(cfg)
    peer = peer_status(cfg)
    history = read_history()
    state = read_state()

    path = build_dashboard(cfg, me, peer, history, state)

    caption = (
        f"📊 <b>VPN отчёт — {datetime.now().strftime('%d.%m.%Y')}</b>\n"
        f"{server_caption(me)}\n"
    )
    if peer is not None:
        caption += f"{server_caption(peer)}\n"
    caption += (
        f"💾 Диск: {me['disk']}% · Amnezia: {'ok' if 'amnezia' in me['amnezia'] else 'нет'}\n"
        f"<i>👥 онлайн Amnezia · 🔄 смены IPv4 за 24ч · 🕒 последнее рукопожатие</i>"
    )

    if not token or not chat:
        print(f"Telegram is not configured, report saved: {path}")
        return

    result = send_photo(token, chat, path, caption)
    if '"ok":true' not in result:
        send_text(token, chat, caption + "\n\n⚠️ График не отправлен, смотрите лог.")

    reports = sorted(
        (os.path.join(STATE_DIR, f) for f in os.listdir(STATE_DIR) if f.startswith("report-")),
        key=os.path.getmtime,
    )
    for old in reports[:-7]:
        try:
            os.remove(old)
        except OSError:
            pass

    with open(os.path.join(STATE_DIR, "last-report.txt"), "w", encoding="utf-8") as f:
        f.write(caption + "\n")
    print(result)


if __name__ == "__main__":
    main()
