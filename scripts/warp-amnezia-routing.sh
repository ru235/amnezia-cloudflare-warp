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
# Our bypass mark must be evaluated BEFORE WARP's own ip rule. WARP has used
# priorities 9, 99 and 32765 in different versions and can change it after a
# reconnect. If our rule ends up below WARP's, marked replies (SSH, Caddy, AWG
# handshakes) fall into table 65743 and the server looks unreachable from the
# internet. Detect WARP's current priority and put our rule above it.
WARP_TABLE="${WARP_TABLE:-65743}"

rule_prios() {  # rule_prios ""|-6 -> priorities of our bypass rules
    local family="$1"
    ip $family rule show 2>/dev/null | awk -v mark="$BYPASS_MARK" '
        $1 ~ /^[0-9]+:$/ {
            prio = $1; sub(":", "", prio)
            for (i = 2; i <= NF; i++) {
                if ($i == "fwmark" && $(i+1) == mark &&
                    $(i+2) == "lookup" && $(i+3) == "main") print prio
            }
        }'
}

warp_prio_for() {  # warp_prio_for ""|-6 -> priority of WARP's rule
    local family="$1"
    ip $family rule show 2>/dev/null | awk -v table="$WARP_TABLE" '
        $1 ~ /^[0-9]+:$/ {
            for (i = 2; i <= NF; i++) {
                if ($i == "lookup" && $(i+1) == table) {
                    p = $1; sub(":", "", p); print p; exit
                }
            }
        }'
}

for family in "" "-6"; do
    wp=$(warp_prio_for "$family")
    target="$BYPASS_PRIO"
    if [ -n "$wp" ] && [ "$wp" -le "$target" ] 2>/dev/null; then
        target=$((wp - 1))
        [ "$target" -lt 1 ] && target=1
    fi

    current=$(rule_prios "$family" | tr '\n' ' ')
    case " $current " in
        *" $target "*) : ;;  # already in place
        *) ip $family rule add priority "$target" fwmark "$BYPASS_MARK" lookup main 2>/dev/null || true ;;
    esac

    # Drop stale rules only after the target rule is really there, so a failed
    # add can never leave the host without its bypass route.
    if rule_prios "$family" | grep -qx "$target"; then
        for prio in $current; do
            [ "$prio" = "$target" ] && continue
            ip $family rule del priority "$prio" fwmark "$BYPASS_MARK" lookup main 2>/dev/null || true
        done
    else
        echo "warning: could not place bypass rule at priority $target (${family:-ipv4})" >&2
    fi
    echo "policy routing (${family:-ipv4}): mark $BYPASS_MARK at priority $target (WARP rule: ${wp:-not found})"
done

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
