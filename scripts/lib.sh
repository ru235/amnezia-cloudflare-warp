# Shared helpers for the installer and runtime scripts.
# Sourced by install.sh and warp-rotate.sh; the runtime scripts keep their own
# minimal copies so they never depend on files outside /usr/local/sbin.

CONF_PATH=/etc/warp-monitor.conf
TG_ENV_PATH=/etc/warp-telegram.env
WARP_IF_NAME=CloudflareWARP

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run this script as root (sudo)"
}

detect_uplink() {
    ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

detect_self_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

detect_awg_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep '^amnezia-awg' | head -1
}

detect_awg_port() {
    local container="$1" port=""
    if [ -n "$container" ]; then
        port=$(docker port "$container" 2>/dev/null | awk -F'[/: ]+' '/udp/ {print $1; exit}')
        if [ -z "$port" ]; then
            port=$(docker exec "$container" awg show all dump 2>/dev/null \
                | awk 'NR==1 {print $4; exit}')
        fi
    fi
    echo "$port"
}

warp_connected() {
    warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"
}
