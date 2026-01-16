#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
#  Multi-Tailnet Namespace Setup
#  Creates an isolated network namespace for a secondary Tailscale tailnet
#
#  CUSTOMIZE THESE VALUES:
#    NAMESPACE: The namespace name (e.g., tsWork, tsCorp, tsLab)
#    VETH_HOST: Host-side veth name (e.g., veth-work-host)
#    VETH_NS: Namespace-side veth name (e.g., veth-work-ns)
#    SUFFIX: DNS suffix used in Corefile (e.g., work, corp, lab)
# ------------------------------

# Configuration - EDIT THESE FOR YOUR SETUP
NAMESPACE="tsFGPU"
VETH_HOST="veth-fgpu-host"
VETH_NS="veth-fgpu-ns"
VETH_HOST_IP="10.200.0.5"
VETH_NS_IP="10.200.0.6"
VETH_SUBNET="10.200.0.4/30"

# Helper: delete link if exists
del_link_if_exists() {
  local name="$1"
  if ip link show "$name" &>/dev/null; then
    ip link del "$name"
  fi
}

# Get ALL interfaces with default routes (handles multi-homed hosts)
WAN_INTERFACES=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | sort -u)

if [[ -z "${WAN_INTERFACES}" ]]; then
  echo "setup-ts-netns: No default route found; cannot determine WAN interfaces" >&2
  exit 1
fi

echo "setup-ts-netns: Found WAN interfaces: ${WAN_INTERFACES//$'\n'/ }"

# Ensure IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
mkdir -p /etc/sysctl.d
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-ip-forward.conf

# Configure DNS for namespace
# Primary: CoreDNS on the veth (for .<suffix> resolution)
# Fallback: 8.8.8.8 (for general internet DNS)
mkdir -p "/etc/netns/${NAMESPACE}"
cat > "/etc/netns/${NAMESPACE}/resolv.conf" <<EOF
nameserver ${VETH_HOST_IP}
nameserver 8.8.8.8
EOF

# ------------------------------
#  Create namespace + veth pair
# ------------------------------
if ! ip netns list | grep -q "^${NAMESPACE}\b"; then
  ip netns add "${NAMESPACE}"
fi

del_link_if_exists "${VETH_HOST}"
ip link add "${VETH_HOST}" type veth peer name "${VETH_NS}"
ip link set "${VETH_NS}" netns "${NAMESPACE}"

# Host side
ip addr flush dev "${VETH_HOST}" || true
ip addr add "${VETH_HOST_IP}/30" dev "${VETH_HOST}"
ip link set "${VETH_HOST}" up

# Namespace side
ip netns exec "${NAMESPACE}" ip addr flush dev "${VETH_NS}" || true
ip netns exec "${NAMESPACE}" ip addr add "${VETH_NS_IP}/30" dev "${VETH_NS}"
ip netns exec "${NAMESPACE}" ip link set lo up
ip netns exec "${NAMESPACE}" ip link set "${VETH_NS}" up
ip netns exec "${NAMESPACE}" ip route replace default via "${VETH_HOST_IP}"

# ------------------------------
#  NAT for namespace via ALL WAN interfaces
#  This handles multi-homed hosts where traffic may egress
#  through different interfaces based on routing metrics
# ------------------------------
for WAN_IF in ${WAN_INTERFACES}; do
  if ! iptables -t nat -C POSTROUTING -s "${VETH_SUBNET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "${VETH_SUBNET}" -o "${WAN_IF}" -j MASQUERADE
    echo "setup-ts-netns: Added NAT rule for ${WAN_IF}"
  else
    echo "setup-ts-netns: NAT rule for ${WAN_IF} already exists"
  fi
done

echo "setup-ts-netns: Namespace ${NAMESPACE} setup completed successfully"
