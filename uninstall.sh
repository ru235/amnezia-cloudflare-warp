#!/bin/bash
# Remove amnezia-cloudflare-warp from this server.
#
#   sudo ./uninstall.sh                # remove services and scripts, keep data/config
#   sudo ./uninstall.sh --purge        # also remove /var/lib/warp-monitor and configs,
#                                      # and flush the routing rules
#   sudo ./uninstall.sh --flush-routing # only remove the WARP/Amnezia routing rules
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR=/usr/local/sbin
UNIT_DIR=/etc/systemd/system
CONF_PATH=/etc/warp-monitor.conf
TG_ENV_PATH=/etc/warp-telegram.env
STATE_DIR=/var/lib/warp-monitor

PURGE=0
FLUSH=0
DRY_RUN=0

info() { echo -e "\033[36m[*]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[x]\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
amnezia-cloudflare-warp uninstaller

  sudo ./uninstall.sh [--purge] [--flush-routing] [--dry-run]

  --purge          Also delete monitor data and configuration files
  --flush-routing  Remove the iptables/ip rule entries created by the project
  --dry-run        Print actions, change nothing
  -h, --help       This help
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)         PURGE=1; FLUSH=1; shift ;;
        --flush-routing) FLUSH=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run as root: sudo ./uninstall.sh"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] $*"
    else
        "$@" || true
    fi
}

flush_routing() {
    [ -f "$CONF_PATH" ] || { warn "$CONF_PATH not found, cannot read routing settings"; return; }
    # shellcheck disable=SC1090
    . "$CONF_PATH" || true

    AWG_IFACE="${AWG_IFACE:-amn0}"
    WARP_IF="${WARP_IF:-CloudflareWARP}"
    BYPASS_MARK="${BYPASS_MARK:-0x100cf}"
    BYPASS_PRIO="${BYPASS_PRIO:-10}"
    AWG_PORT="${AWG_PORT:-44059}"

    info "removing routing rules"
    run ip rule del priority "$BYPASS_PRIO" fwmark "$BYPASS_MARK" lookup main
    run ip -6 rule del priority "$BYPASS_PRIO" fwmark "$BYPASS_MARK" lookup main

    run iptables -t mangle -D PREROUTING -i "$AWG_IFACE" -p udp --sport "$AWG_PORT" -j MARK --set-mark "$BYPASS_MARK"
    run iptables -t mangle -D PREROUTING -m conntrack --ctstate DNAT -j MARK --set-mark "$BYPASS_MARK"
    run iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark "$BYPASS_MARK"
    run iptables -t mangle -D OUTPUT -p tcp --sport 80 -j MARK --set-mark "$BYPASS_MARK"
    run iptables -t mangle -D OUTPUT -p tcp --sport 443 -j MARK --set-mark "$BYPASS_MARK"
    run iptables -t mangle -D OUTPUT -p udp --sport 443 -j MARK --set-mark "$BYPASS_MARK"
    run iptables -t mangle -D OUTPUT -p icmp --icmp-type echo-reply -j MARK --set-mark "$BYPASS_MARK"
    run iptables -t mangle -D FORWARD -o "$WARP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    for src in "$AWG_IFACE" docker0 'br-+'; do
        run iptables -D FORWARD -i "$src" -o "$WARP_IF" -j ACCEPT
        run iptables -D FORWARD -i "$WARP_IF" -o "$src" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    done
    run iptables -t nat -D POSTROUTING -s 172.16.0.0/12 -o "$WARP_IF" -j MASQUERADE
    warn "nftables rules added to 'inet cloudflare-warp' stay until WARP restarts"
}

info "stopping services"
for unit in bot-guard.timer peer-monitor.timer warp-daily-report.timer warp-rotate.timer \
            warp-bot.service bot-guard.service peer-monitor.service \
            warp-daily-report.service warp-rotate.service warp-amnezia-routing.service; do
    if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        run systemctl disable --now "$unit"
    fi
done

info "removing systemd units"
for unit in warp-amnezia-routing.service peer-monitor.service peer-monitor.timer \
            warp-daily-report.service warp-daily-report.timer \
            warp-rotate.service warp-rotate.timer \
            warp-bot.service bot-guard.service bot-guard.timer; do
    run rm -f "$UNIT_DIR/$unit"
done
run systemctl daemon-reload

info "removing scripts"
for script in warp-amnezia-routing.sh peer-monitor.sh warp-rotate.sh bot-guard.sh \
              warp-daily-report.py warp-bot.py; do
    run rm -f "$BIN_DIR/$script"
done

if [ "$FLUSH" -eq 1 ]; then
    flush_routing
fi

if [ "$PURGE" -eq 1 ]; then
    info "removing data and configuration"
    run rm -rf "$STATE_DIR"
    run rm -f "$CONF_PATH" "$CONF_PATH.bak" "$TG_ENV_PATH"
    run rm -f /var/log/warp-rotate.log
else
    echo
    warn "kept: $STATE_DIR, $CONF_PATH, $TG_ENV_PATH, /var/log/warp-rotate.log"
    warn "use --purge to delete them, --flush-routing to remove traffic rules"
fi

echo
info "done"
