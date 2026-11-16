#!/bin/bash
# Round-the-clock health monitor.
#
# Every minute it stores: peer reachability, WARP state, Amnezia state, disk,
# active Amnezia users, the total number of peers, the current WARP IPv4 and
# when the last client handshake happened.
#
# Optional (only when /etc/warp-telegram.env exists): sends Telegram alerts
# after 5 minutes of failure and keeps the bypass routing alive.
set -u
. /etc/warp-monitor.conf
if [ -f /etc/warp-telegram.env ]; then
    . /etc/warp-telegram.env
fi

STATE_DIR=/var/lib/warp-monitor
mkdir -p "$STATE_DIR"
HIST="$STATE_DIR/history.csv"
STATE="$STATE_DIR/state.env"
IPLOG="$STATE_DIR/ipv4.log"
LAST4="$STATE_DIR/last_warp4"
HIST_HEADER="ts,peer_ok,peer_ms,warp_ok,awg_ok,disk,peers,total,warp4"

[ -f "$STATE" ] && . "$STATE"

PEER_FAIL=${PEER_FAIL:-0}
PEER_ALERT=${PEER_ALERT:-0}
PEER_SINCE=${PEER_SINCE:-0}
PEER_LAST_NOTICE=${PEER_LAST_NOTICE:-0}
WARP_FAIL=${WARP_FAIL:-0}
WARP_ALERT=${WARP_ALERT:-0}
AWG_FAIL=${AWG_FAIL:-0}
AWG_ALERT=${AWG_ALERT:-0}
DISK_ALERT=${DISK_ALERT:-0}
ROUTE_FAIL=${ROUTE_FAIL:-0}
ROUTE_ALERT=${ROUTE_ALERT:-0}

PEER_IP=${PEER_IP:-}
PEER_NAME=${PEER_NAME:-Peer}
SELF_NAME=${SELF_NAME:-$(hostname)}
SELF_IP=${SELF_IP:-}
BYPASS_MARK=${BYPASS_MARK:-}

tg() {
    [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
    curl -s --max-time 20 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

# --- diagnostics for an unreachable peer -------------------------------------
tcp_probe() {
    timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

icmp_probe() {
    ping -c 2 -W 2 "$1" >/dev/null 2>&1
}

diagnose_peer() {
    local ip="$1"
    local p80=0 p443=0 icmp=0 trace_last="" tspu="" diag="" label="ТСПУ"
    tcp_probe "$ip" 80 && p80=1
    tcp_probe "$ip" 443 && p443=1
    icmp_probe "$ip" && icmp=1

    if command -v traceroute >/dev/null 2>&1; then
        trace_last=$(timeout 25 traceroute -T -p 22 -m 12 -w 2 -q 1 "$ip" 2>/dev/null \
            | awk 'NR > 1 && $0 !~ /^[[:space:]]*$/ { last = $0 } END { print last }')
    fi

    if [ "${TSPU_ENABLE:-0}" = "1" ] && [ -x /usr/local/sbin/tspu-check.sh ]; then
        [ -n "${TSPU_PROBE_HOST:-}" ] && label="ТСПУ (точка РФ)" || label="ТСПУ (локально)"
        tspu=$(timeout 110 /usr/local/sbin/tspu-check.sh --target "$ip" --fresh 2>/dev/null \
            | awk -F'\t' -v ip="$ip" '$1 == ip { print $2 "\t" $3; exit }')
    fi

    if [ "$p443" -eq 1 ] || [ "$p80" -eq 1 ]; then
        diag="сервер жив: порт 443/80 отвечает, но SSH/22 недоступен"
    elif [ "$icmp" -eq 1 ]; then
        diag="ICMP отвечает, TCP-порты 22/80/443 молчат — фильтрация или перегрузка"
    elif [ -n "$trace_last" ]; then
        diag="пакеты не доходят; трассировка: ${trace_last}"
    else
        diag="нет ответа ни по ICMP, ни по TCP"
    fi

    if [ -n "$tspu" ]; then
        local status="${tspu%%$'\t'*}"
        local detail="${tspu#*$'\t'}"
        if [ "$status" = "blocked" ]; then
            diag="${label}: ${detail}"
        else
            diag="${diag}; ${label}: блокировка не обнаружена"
        fi
    fi

    printf '%s' "$diag" | tr '\n' ' '
}

# --- history file + schema migration (older files had 6 columns) -------------
if [ ! -f "$HIST" ]; then
    echo "$HIST_HEADER" > "$HIST"
elif [ "$(head -1 "$HIST")" != "$HIST_HEADER" ]; then
    awk -v h="$HIST_HEADER" 'NR==1 {print h; next} {print $0 ",0,0,-"}' "$HIST" > "$HIST.tmp" \
        && mv "$HIST.tmp" "$HIST"
fi

now=$(date +%s)

# --- peer reachability (TCP/22) ---------------------------------------------
peer_ok=1
peer_ms=0
if [ -n "$PEER_IP" ]; then
    t0=$(date +%s%3N)
    if timeout 5 bash -c "exec 3<>/dev/tcp/${PEER_IP}/22" 2>/dev/null; then
        peer_ok=1
    else
        peer_ok=0
    fi
    t1=$(date +%s%3N)
    peer_ms=$((t1 - t0))
    [ "$peer_ok" -eq 0 ] && peer_ms=0
fi

# --- local checks ------------------------------------------------------------
if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then warp_ok=1; else warp_ok=0; fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^amnezia-awg'; then awg_ok=1; else awg_ok=0; fi
disk=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
[ -z "$disk" ] && disk=0

# --- WARP IPv4 + change log --------------------------------------------------
warp4="-"
if [ "$warp_ok" -eq 1 ]; then
    warp4=$(curl -4 -s --connect-timeout 3 --max-time 8 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
fi
[ -z "$warp4" ] && warp4="-"

if [ "$warp4" != "-" ]; then
    last4=""
    [ -f "$LAST4" ] && last4=$(cat "$LAST4" 2>/dev/null)
    if [ "$warp4" != "$last4" ]; then
        echo "$now $(date -u +%Y-%m-%dT%H:%M:%SZ) $warp4" >> "$IPLOG"
        echo "$warp4" > "$LAST4"
    fi
    if [ -f "$IPLOG" ] && [ "$(wc -l < "$IPLOG")" -gt 2000 ]; then
        tail -1000 "$IPLOG" > "$IPLOG.tmp" && mv "$IPLOG.tmp" "$IPLOG"
    fi
fi

# --- active Amnezia peers + last handshake ----------------------------------
awg_name=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^amnezia-awg' | head -1)
peers=0
peers_total=0
last_hs=0
last_hs_peer="-"
if [ -n "$awg_name" ]; then
    dump=$(docker exec "$awg_name" awg show all dump 2>/dev/null)
    if [ -n "$dump" ]; then
        read -r peers peers_total last_hs last_hs_peer <<< "$(printf '%s\n' "$dump" | \
            awk -v now="$now" '
                NF==9 {
                    total++
                    if ($6 > 0) {
                        if (best == 0 || $6 > best) { best = $6; best_peer = $5 }
                        if (now - $6 < 180) active++
                    }
                }
                END { printf "%d %d %d %s", active + 0, total + 0, best + 0, (best_peer ? best_peer : "-") }
            ')"
    fi
fi

echo "${now},${peer_ok},${peer_ms},${warp_ok},${awg_ok},${disk},${peers},${peers_total},${warp4}" >> "$HIST"

# --- peer alert --------------------------------------------------------------
if [ -n "$PEER_IP" ] && [ "$peer_ok" -eq 0 ]; then
    PEER_FAIL=$((PEER_FAIL + 1))
    [ "$PEER_FAIL" -eq 1 ] && PEER_SINCE=$now
    if [ "$PEER_FAIL" -ge 5 ] && [ "$PEER_ALERT" -eq 0 ]; then
        mins=$(( (now - PEER_SINCE) / 60 ))
        tg "🔴 <b>Сервер недоступен</b>
<code>${PEER_NAME} (${PEER_IP})</code>
Нет ответа уже ${mins} мин. Проверяю причину…"
        diag=$(diagnose_peer "$PEER_IP")
        printf '%s\n' "$diag" > "$STATE_DIR/peer-last-diag.txt"
        tg "🔎 <b>Почему недоступен ${PEER_NAME}</b>
${diag}"
        PEER_ALERT=1
        PEER_LAST_NOTICE=$now
    elif [ "$PEER_ALERT" -eq 1 ] && [ $((now - PEER_LAST_NOTICE)) -ge 1800 ]; then
        mins=$(( (now - PEER_SINCE) / 60 ))
        diag=$(diagnose_peer "$PEER_IP")
        printf '%s\n' "$diag" > "$STATE_DIR/peer-last-diag.txt"
        tg "⏱ <b>${PEER_NAME} всё ещё недоступен</b>
Простой: ~${mins} мин.
${diag}"
        PEER_LAST_NOTICE=$now
    fi
else
    if [ "$PEER_ALERT" -eq 1 ]; then
        mins=$(( (now - PEER_SINCE) / 60 ))
        diag=""
        [ -f "$STATE_DIR/peer-last-diag.txt" ] && diag=$(cat "$STATE_DIR/peer-last-diag.txt" 2>/dev/null)
        if [ -n "$diag" ]; then
            tg "🟢 <b>Сервер снова доступен</b>
<code>${PEER_NAME} (${PEER_IP})</code>
Простой: ~${mins} мин.
Причина: ${diag}"
        else
            tg "🟢 <b>Сервер снова доступен</b>
<code>${PEER_NAME} (${PEER_IP})</code>
Простой: ~${mins} мин."
        fi
        rm -f "$STATE_DIR/peer-last-diag.txt"
    fi
    PEER_FAIL=0; PEER_ALERT=0; PEER_SINCE=0; PEER_LAST_NOTICE=0
fi

# --- local WARP alert --------------------------------------------------------
if [ "$warp_ok" -eq 0 ]; then
    WARP_FAIL=$((WARP_FAIL + 1))
    if [ "$WARP_FAIL" -ge 5 ] && [ "$WARP_ALERT" -eq 0 ]; then
        tg "⚠️ <b>WARP не подключён</b>
<code>${SELF_NAME} (${SELF_IP})</code>
Уже 5 минут. Трафик клиентов может идти напрямую."
        WARP_ALERT=1
    fi
else
    if [ "$WARP_ALERT" -eq 1 ]; then
        tg "✅ <b>WARP снова подключён</b>
<code>${SELF_NAME} (${SELF_IP})</code>"
    fi
    WARP_FAIL=0; WARP_ALERT=0
fi

# --- Amnezia container alert -------------------------------------------------
if [ "$awg_ok" -eq 0 ]; then
    AWG_FAIL=$((AWG_FAIL + 1))
    if [ "$AWG_FAIL" -ge 5 ] && [ "$AWG_ALERT" -eq 0 ]; then
        tg "⚠️ <b>Amnezia контейнер не запущен</b>
<code>${SELF_NAME} (${SELF_IP})</code>
Уже 5 минут."
        AWG_ALERT=1
    fi
else
    if [ "$AWG_ALERT" -eq 1 ]; then
        tg "✅ <b>Amnezia контейнер снова работает</b>
<code>${SELF_NAME} (${SELF_IP})</code>"
    fi
    AWG_FAIL=0; AWG_ALERT=0
fi

# --- disk alert --------------------------------------------------------------
if [ "$disk" -ge 90 ]; then
    if [ "$DISK_ALERT" -eq 0 ]; then
        tg "💾 <b>Мало места на диске</b>
<code>${SELF_NAME} (${SELF_IP})</code>
Занято ${disk}%."
        DISK_ALERT=1
    fi
elif [ "$disk" -lt 85 ]; then
    DISK_ALERT=0
fi

# --- re-apply routing rules (WARP flushes them on reconnect) -----------------
if [ "$warp_ok" -eq 1 ]; then
    /usr/local/sbin/warp-amnezia-routing.sh >/dev/null 2>&1 || true
fi

# --- bypass route health: replies (SSH, Caddy, AWG) must never enter WARP ----
if [ "$warp_ok" -eq 1 ] && [ -n "$BYPASS_MARK" ]; then
    if ip route get 1.1.1.1 mark "$BYPASS_MARK" 2>/dev/null | grep -q "CloudflareWARP"; then
        # WARP moved its own ip rule above ours: re-apply the routing script,
        # which places the bypass rule above WARP's current priority.
        /usr/local/sbin/warp-amnezia-routing.sh >/dev/null 2>&1 || true
    fi
    if ip route get 1.1.1.1 mark "$BYPASS_MARK" 2>/dev/null | grep -q "CloudflareWARP"; then
        ROUTE_FAIL=$((ROUTE_FAIL + 1))
        if [ "$ROUTE_FAIL" -ge 2 ] && [ "$ROUTE_ALERT" -eq 0 ]; then
            tg "⚠️ <b>Ответы сервера уходят в WARP</b>
<code>${SELF_NAME} (${SELF_IP})</code>
Маршрут с меткой ${BYPASS_MARK} перехвачен WARP — Amnezia, SSH и сайты могут не работать. Пробую исправить."
            ROUTE_ALERT=1
        fi
    else
        if [ "$ROUTE_ALERT" -eq 1 ]; then
            tg "✅ <b>Маршруты ответов восстановлены</b>
<code>${SELF_NAME} (${SELF_IP})</code>"
        fi
        ROUTE_FAIL=0; ROUTE_ALERT=0
    fi
fi

# --- persist state -----------------------------------------------------------
tmp="$STATE.tmp"
{
    echo "PEER_FAIL=$PEER_FAIL"
    echo "PEER_ALERT=$PEER_ALERT"
    echo "PEER_SINCE=$PEER_SINCE"
    echo "PEER_LAST_NOTICE=$PEER_LAST_NOTICE"
    echo "WARP_FAIL=$WARP_FAIL"
    echo "WARP_ALERT=$WARP_ALERT"
    echo "AWG_FAIL=$AWG_FAIL"
    echo "AWG_ALERT=$AWG_ALERT"
    echo "DISK_ALERT=$DISK_ALERT"
    echo "ROUTE_FAIL=$ROUTE_FAIL"
    echo "ROUTE_ALERT=$ROUTE_ALERT"
    echo "LAST_HS=$last_hs"
    echo "LAST_HS_PEER=$last_hs_peer"
} > "$tmp" && mv "$tmp" "$STATE"
