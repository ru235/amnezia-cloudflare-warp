#!/bin/bash
# Install the TSPU probe on a host inside Russia (behind TSPU).
#
# Usage: sudo ./probe/install-probe.sh [root@server]
#
# The host needs no open ports: it connects out to the monitoring server.
set -eu

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
BIN_DIR=/usr/local/sbin
UNIT_DIR=/etc/systemd/system
CONF=/etc/tspu-probe.conf
KEY=/root/.ssh/id_ed25519_tspu
SERVER="${1:-}"

info() { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*" >&2; }
die()  { warn "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

if ! command -v perl >/dev/null 2>&1; then
    info "installing perl"
    DEBIAN_FRONTEND=noninteractive apt-get install -y perl >/dev/null
fi

info "installing tspu-check.pl"
bash "$SRC_DIR/../scripts/install-tspu-check.sh"

install -m 755 "$SRC_DIR/tspu-probe.sh" "$BIN_DIR/tspu-probe.sh"
ok "installed $BIN_DIR/tspu-probe.sh"

if [ ! -f "$CONF" ]; then
    install -m 644 "$SRC_DIR/tspu-probe.conf.example" "$CONF"
    ok "created $CONF"
    if [ -n "$SERVER" ]; then
        sed -i "s|^PROBE_SERVER=.*|PROBE_SERVER=\"$SERVER\"|" "$CONF"
    fi
else
    ok "keeping existing $CONF"
fi

install -m 644 "$SRC_DIR/tspu-probe.service" "$UNIT_DIR/tspu-probe.service"
install -m 644 "$SRC_DIR/tspu-probe.timer"   "$UNIT_DIR/tspu-probe.timer"
systemctl daemon-reload
ok "systemd units installed"

install -d -m 700 /root/.ssh
if [ ! -f "$KEY" ]; then
    ssh-keygen -t ed25519 -N "" -C "tspu-probe@$(hostname)" -f "$KEY" >/dev/null
    ok "generated $KEY"
fi

systemctl enable --now tspu-probe.timer >/dev/null
ok "timer enabled (every 4 hours)"

echo
info "Add this key on the monitoring server (root's authorized_keys):"
echo
echo "restrict,command=\"/usr/local/sbin/tspu-ingest.sh\" $(cat "$KEY.pub")"
echo
info "Then check it once by hand:"
echo "    systemctl start tspu-probe.service"
echo "    journalctl -u tspu-probe -n 20 --no-pager"
