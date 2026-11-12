#!/bin/bash
# Daily Cloudflare WARP reconnect with key rotation.
#
# Rotates the WARP IPv6 egress address and refreshes the session. On free WARP
# the IPv4 egress is tied to the Cloudflare PoP and normally does NOT change, so
# a new IPv4 only appears after a reconnect to a different PoP.
#
# The uplink interface and the AmneziaWG transport port are detected
# automatically; both can be pinned in /etc/warp-monitor.conf.
set -u
. /etc/warp-monitor.conf 2>/dev/null || true

LOG=/var/log/warp-rotate.log
GUARD=WARP_ROTATE_GUARD
AWG_IFACE="${AWG_IFACE:-amn0}"
AWG_PORT="${AWG_PORT:-}"

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "$LOG" | logger -t warp-rotate; }

detect_uplink() {
    ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

detect_awg_port() {
    [ -n "$AWG_PORT" ] && { echo "$AWG_PORT"; return; }
    local container port
    container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^amnezia-awg' | head -1)
    if [ -n "$container" ]; then
        port=$(docker port "$container" 2>/dev/null | awk -F'[/: ]+' '/udp/ {print $1; exit}')
        [ -z "$port" ] && port=$(docker exec "$container" awg show all dump 2>/dev/null \
            | awk 'NR==1 {print $4; exit}')
    fi
    echo "${port:-44059}"
}

get_ip() {
    local v="$1"
    curl -"$v" -s --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '/^ip=/{print $2; exit}'
}

wait_connected() {
    for _ in $(seq 1 60); do
        warp-cli --accept-tos status 2>/dev/null | grep -q "Connected" && return 0
        sleep 1
    done
    return 1
}

reconnect_with_new_keys() {
    warp-cli --accept-tos disconnect >/dev/null 2>&1
    sleep 3
    warp-cli --accept-tos tunnel rotate-keys >/dev/null 2>&1
    warp-cli --accept-tos connect >/dev/null 2>&1
    wait_connected
}

cleanup_guard() {
    iptables -D FORWARD -j "$GUARD" 2>/dev/null || true
    iptables -F "$GUARD" 2>/dev/null || true
    iptables -X "$GUARD" 2>/dev/null || true
}

UPLINK=$(detect_uplink)
if [ -z "$UPLINK" ]; then
    log "ERROR: cannot detect the uplink interface"
    exit 1
fi
AWG_PORT=$(detect_awg_port)

# Remove leftovers from an interrupted previous run
cleanup_guard

# Anti-leak guard: while WARP is down, client traffic must not go out via the
# physical uplink. Inbound DNAT replies (Caddy 80/443, AWG) stay allowed, and the
# AWG transport itself may still leave so tunnels can handshake.
iptables -N "$GUARD"
iptables -A "$GUARD" -m conntrack --ctstate DNAT -j ACCEPT
iptables -A "$GUARD" -i "$AWG_IFACE" -o "$UPLINK" -p udp --sport "$AWG_PORT" -j ACCEPT
iptables -A "$GUARD" -i "$AWG_IFACE" -o "$UPLINK" -j DROP
iptables -A "$GUARD" -i docker0 -o "$UPLINK" -j DROP
iptables -A "$GUARD" -i br-+ -o "$UPLINK" -j DROP
iptables -I FORWARD 1 -j "$GUARD"
trap cleanup_guard EXIT INT TERM

OLD4=$(get_ip 4); OLD6=$(get_ip 6)
log "rotation start: uplink=${UPLINK} awg_port=${AWG_PORT} IPv4=${OLD4:-unknown} IPv6=${OLD6:-unknown}"

ok=0
reconnect_with_new_keys && ok=1

# Retry once if the IPv6 address did not change
if [ "$ok" -eq 1 ] && [ -n "${OLD6:-}" ]; then
    CUR6=$(get_ip 6)
    if [ "${CUR6:-}" = "${OLD6:-}" ]; then
        log "IPv6 unchanged, retrying with a fresh key pair"
        reconnect_with_new_keys && ok=1
    fi
fi

# WARP flushes our policy routing on reconnect: restore it
/usr/local/sbin/warp-amnezia-routing.sh >>"$LOG" 2>&1 || true
cleanup_guard

if [ "$ok" -ne 1 ]; then
    log "ERROR: WARP did not reconnect"
    exit 1
fi

sleep 2
NEW4=$(get_ip 4); NEW6=$(get_ip 6)
log "rotation done: IPv4=${NEW4:-unknown} IPv6=${NEW6:-unknown}"
[ -n "${OLD6:-}" ] && [ "${OLD6:-}" = "${NEW6:-}" ] && log "NOTE: IPv6 did not change this time"
exit 0
