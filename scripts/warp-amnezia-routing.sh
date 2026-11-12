#!/bin/bash
# Route AmneziaWG client traffic through Cloudflare WARP,
# while keeping management (SSH/ICMP) and the AWG transport on the physical uplink.
#
# Idempotent: safe to run on every boot, on every WARP reconnect and from cron.
set -u
. /etc/warp-monitor.conf 2>/dev/null || true

WARP_IF="${WARP_IF:-CloudflareWARP}"
BYPASS_MARK="${BYPASS_MARK:-0x100cf}"
BYPASS_PRIO="${BYPASS_PRIO:-10}"
AWG_PORT="${AWG_PORT:-}"

# --- locate the AmneziaWG transport port (needed to mark its replies) --------
if [ -z "$AWG_PORT" ]; then
    container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^amnezia-awg' | head -1)
    if [ -n "$container" ]; then
        AWG_PORT=$(docker port "$container" 2>/dev/null | awk -F'[/: ]+' '/udp/ {print $1; exit}')
        [ -z "$AWG_PORT" ] && AWG_PORT=$(docker exec "$container" awg show all dump 2>/dev/null \
            | awk 'NR==1 {print $4; exit}')
    fi
fi
AWG_PORT="${AWG_PORT:-44059}"

# --- make sure WARP is up ----------------------------------------------------
if ! warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
fi

for _ in $(seq 1 60); do
    ip link show "$WARP_IF" >/dev/null 2>&1 && break
    sleep 1
done
if ! ip link show "$WARP_IF" >/dev/null 2>&1; then
    echo "WARP interface $WARP_IF not found"
    exit 1
fi

# --- policy routing ----------------------------------------------------------
# Our bypass mark must be evaluated BEFORE WARP's own ip rule. Depending on the
# version WARP installs it at priority 99 or 32765; with the mark falling through
# to WARP's table 65743, replies (SSH, Caddy, AWG handshakes) get routed into the
# tunnel and dropped as martians.
ip rule del priority 100 fwmark "$BYPASS_MARK" lookup main 2>/dev/null || true
ip -6 rule del priority 100 fwmark "$BYPASS_MARK" lookup main 2>/dev/null || true
ip rule add priority "$BYPASS_PRIO" fwmark "$BYPASS_MARK" lookup main 2>/dev/null || true
ip -6 rule add priority "$BYPASS_PRIO" fwmark "$BYPASS_MARK" lookup main 2>/dev/null || true

add_rule() {  # add_rule <table> <chain> <args...>
    local table="$1" chain="$2"
    shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -I "$chain" 1 "$@"
}

# 1. The AWG transport itself must leave via the physical uplink
add_rule mangle PREROUTING -i amn0 -p udp --sport "$AWG_PORT" -j MARK --set-mark "$BYPASS_MARK"

# 2. Replies to Docker-published ports (Caddy 80/443, AWG) must leave directly
add_rule mangle PREROUTING -m conntrack --ctstate DNAT -j MARK --set-mark "$BYPASS_MARK"

# 3. Host SSH / web replies must leave directly
add_rule mangle OUTPUT -p tcp --sport 22 -j MARK --set-mark "$BYPASS_MARK"
add_rule mangle OUTPUT -p tcp --sport 80 -j MARK --set-mark "$BYPASS_MARK"
add_rule mangle OUTPUT -p tcp --sport 443 -j MARK --set-mark "$BYPASS_MARK"
add_rule mangle OUTPUT -p udp --sport 443 -j MARK --set-mark "$BYPASS_MARK"

# 4. ICMP echo replies must leave directly, otherwise ping breaks
add_rule mangle OUTPUT -p icmp --icmp-type echo-reply -j MARK --set-mark "$BYPASS_MARK"

# 5. Clamp TCP MSS for traffic entering the tunnel (WARP MTU < AWG MTU)
add_rule mangle FORWARD -o "$WARP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 6. Forwarding from Amnezia/Docker into WARP and back
add_rule filter FORWARD -i amn0 -o "$WARP_IF" -j ACCEPT
add_rule filter FORWARD -i docker0 -o "$WARP_IF" -j ACCEPT
add_rule filter FORWARD -i br-+ -o "$WARP_IF" -j ACCEPT
add_rule filter FORWARD -i "$WARP_IF" -o amn0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
add_rule filter FORWARD -i "$WARP_IF" -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
add_rule filter FORWARD -i "$WARP_IF" -o br-+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# 7. NAT all private Docker/Amnezia subnets behind WARP
add_rule nat POSTROUTING -s 172.16.0.0/12 -o "$WARP_IF" -j MASQUERADE

# 8. Cloudflare WARP installs an nftables table with "policy drop" on the
#    input/output hooks. Allow inbound SSH and ICMP, otherwise the server looks
#    completely offline from the internet while the VPN keeps working.
NFT_TABLE="inet cloudflare-warp"
if nft list chain $NFT_TABLE input >/dev/null 2>&1; then
    nft list chain $NFT_TABLE input  | grep -q 'tcp dport 22 accept' || \
        nft insert rule $NFT_TABLE input tcp dport 22 accept
    nft list chain $NFT_TABLE output | grep -q 'tcp sport 22 accept' || \
        nft insert rule $NFT_TABLE output tcp sport 22 accept
    nft list chain $NFT_TABLE output | grep -q 'ip protocol icmp accept' || \
        nft insert rule $NFT_TABLE output ip protocol icmp accept
fi

echo "WARP/Amnezia routing rules applied"
