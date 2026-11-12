#!/bin/bash
# Passive bot guard: run the Telegram bot on this server only while the peer is
# down. On a two-server setup the bot lives on one server (BOT_ROLE=active) and
# this guard on the other (BOT_ROLE=passive) takes over if the active one dies.
#
# Without Telegram (or without a peer) the script exits immediately.
set -u
. /etc/warp-monitor.conf

[ "${BOT_ROLE:-active}" = "passive" ] || exit 0
[ -n "${PEER_IP:-}" ] || exit 0
command -v systemctl >/dev/null 2>&1 || exit 0

STATE=/var/lib/warp-monitor/bot-guard.state
mkdir -p "$(dirname "$STATE")"

FAIL=0
[ -f "$STATE" ] && . "$STATE"

if timeout 5 bash -c "exec 3<>/dev/tcp/${PEER_IP}/22" 2>/dev/null; then
    if systemctl is-active --quiet warp-bot.service; then
        systemctl stop warp-bot.service
    fi
    FAIL=0
else
    FAIL=$((FAIL + 1))
    if [ "$FAIL" -ge 5 ] && ! systemctl is-active --quiet warp-bot.service; then
        systemctl start warp-bot.service
    fi
fi

echo "FAIL=$FAIL" > "$STATE"
