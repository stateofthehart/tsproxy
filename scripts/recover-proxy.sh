#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------
#  tsproxy recovery script
#
#  Diagnoses and recovers the proxy service chain.
#  Run this whenever the proxy goes down.
#
#  Usage: sudo ./scripts/recover-proxy.sh
# --------------------------------------------------

NAMESPACE="tsFGPU"
VETH_HOST="veth-fgpu-host"
VETH_HOST_IP="10.200.0.5"
VETH_NS_IP="10.200.0.6"
VETH_SUBNET="10.200.0.4/30"
TAILSCALE_SOCKET="/run/tailscale-${NAMESPACE}/tailscaled.sock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fix()  { echo -e "  ${YELLOW}→ Fixing:${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

echo "=== tsproxy Recovery ==="
echo ""
FIXED=0

# ---- 1. Check namespace exists ----
echo "[1/7] Namespace"
if ip netns list | grep -q "^${NAMESPACE}\b"; then
    ok "Namespace ${NAMESPACE} exists"
else
    fail "Namespace ${NAMESPACE} missing"
    fix "Running setup script"
    /usr/local/sbin/setup-ts-netns.sh
    FIXED=1
fi

# ---- 2. Check veth pair ----
echo "[2/7] Veth pair"
if ip link show "${VETH_HOST}" &>/dev/null; then
    ok "Veth host interface ${VETH_HOST} exists"
else
    fail "Veth host interface missing"
    fix "Restarting ts-netns service"
    systemctl restart ts-netns
    sleep 2
    FIXED=1
fi

# ---- 3. Check NAT rules ----
echo "[3/7] NAT rules"
WAN_INTERFACES=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | sort -u)
for WAN_IF in ${WAN_INTERFACES}; do
    if iptables -t nat -C POSTROUTING -s "${VETH_SUBNET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null; then
        ok "NAT rule for ${WAN_IF} exists"
    else
        fail "NAT rule for ${WAN_IF} missing"
        fix "Adding NAT rule"
        iptables -t nat -A POSTROUTING -s "${VETH_SUBNET}" -o "${WAN_IF}" -j MASQUERADE
        FIXED=1
    fi
done

# ---- 4. Check namespace internet ----
echo "[4/7] Namespace internet"
if ip netns exec "${NAMESPACE}" ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
    ok "Namespace can reach internet"
else
    fail "Namespace cannot reach internet"
    fix "Re-running setup script and saving iptables"
    /usr/local/sbin/setup-ts-netns.sh
    iptables-save > /etc/iptables/rules.v4
    sleep 2
    if ip netns exec "${NAMESPACE}" ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        ok "Internet restored"
    else
        fail "Internet still down - check WAN interface and routing"
        exit 1
    fi
    FIXED=1
fi

# ---- 5. Check tailscaled ----
echo "[5/7] Tailscale daemon"
if systemctl is-active tailscaled-${NAMESPACE} &>/dev/null; then
    # Check if tailscale0 has an IP
    if ip netns exec "${NAMESPACE}" ip -4 addr show tailscale0 2>/dev/null | grep -q "inet "; then
        TS_IP=$(ip netns exec "${NAMESPACE}" ip -4 addr show tailscale0 | grep -oP 'inet \K[0-9.]+')
        ok "tailscale0 has IP ${TS_IP}"

        # Check if actually connected (not logged out)
        TS_STATUS=$(ip netns exec "${NAMESPACE}" tailscale --socket="${TAILSCALE_SOCKET}" status 2>&1 | head -1 || true)
        if echo "${TS_STATUS}" | grep -q "logged out\|Health check"; then
            fail "Tailscale is logged out or unhealthy"
            fix "Restarting tailscaled"
            systemctl restart tailscaled-${NAMESPACE}
            echo "  Waiting for reconnection (30s)..."
            sleep 30
            FIXED=1
        else
            ok "Tailscale is connected"
        fi
    else
        warn "tailscale0 has no IPv4 yet"
        fix "Restarting tailscaled"
        systemctl restart tailscaled-${NAMESPACE}
        echo "  Waiting for tailscale0 IPv4 (30s)..."
        sleep 30
        if ip netns exec "${NAMESPACE}" ip -4 addr show tailscale0 2>/dev/null | grep -q "inet "; then
            ok "tailscale0 now has IP"
        else
            fail "tailscale0 still has no IP - may need manual 'tailscale up'"
            exit 1
        fi
        FIXED=1
    fi
else
    fail "tailscaled-${NAMESPACE} is not running"
    fix "Starting tailscaled"
    systemctl restart tailscaled-${NAMESPACE}
    echo "  Waiting for startup (30s)..."
    sleep 30
    FIXED=1
fi

# ---- 6. Check Dante ----
echo "[6/7] Dante SOCKS proxy"
if systemctl is-active dante-${NAMESPACE} &>/dev/null; then
    ok "Dante is running"
    # Test if it can actually connect outbound
    if ip netns exec "${NAMESPACE}" timeout 5 bash -c 'echo | nc -w 3 8.8.8.8 53' &>/dev/null; then
        ok "Dante can reach external hosts"
    else
        warn "Dante running but outbound may be degraded"
        fix "Restarting Dante"
        systemctl restart dante-${NAMESPACE}
        sleep 3
        FIXED=1
    fi
else
    fail "Dante is not running"
    fix "Starting Dante"
    systemctl restart dante-${NAMESPACE}
    sleep 3
    if systemctl is-active dante-${NAMESPACE} &>/dev/null; then
        ok "Dante started"
    else
        fail "Dante failed to start - check: journalctl -u dante-${NAMESPACE}"
        exit 1
    fi
    FIXED=1
fi

# ---- 7. Check expose-socks ----
echo "[7/7] Expose-socks relay"
if systemctl is-active expose-socks-${NAMESPACE} &>/dev/null; then
    ok "expose-socks is running"
else
    fail "expose-socks is not running"
    fix "Starting expose-socks"
    systemctl restart expose-socks-${NAMESPACE}
    sleep 2
    if systemctl is-active expose-socks-${NAMESPACE} &>/dev/null; then
        ok "expose-socks started"
    else
        fail "expose-socks failed to start - check: journalctl -u expose-socks-${NAMESPACE}"
        exit 1
    fi
    FIXED=1
fi

# ---- Save iptables if anything was fixed ----
if [[ $FIXED -eq 1 ]]; then
    echo ""
    fix "Saving iptables rules"
    iptables-save > /etc/iptables/rules.v4
    ok "iptables saved"
fi

echo ""
echo "=== Status ==="
S_NETNS=$(systemctl is-active ts-netns 2>&1)
S_TS=$(systemctl is-active tailscaled-${NAMESPACE} 2>&1)
S_DANTE=$(systemctl is-active dante-${NAMESPACE} 2>&1)
S_EXPOSE=$(systemctl is-active expose-socks-${NAMESPACE} 2>&1)
S_DNS=$(systemctl is-active coredns-fgpu 2>&1)
echo "  ts-netns: ${S_NETNS} | tailscaled: ${S_TS} | dante: ${S_DANTE} | expose-socks: ${S_EXPOSE} | coredns: ${S_DNS}"

if [[ $FIXED -eq 0 ]]; then
    echo ""
    ok "Everything looks healthy - no fixes needed"
else
    echo ""
    warn "Applied fixes. Test from your client now."
fi
