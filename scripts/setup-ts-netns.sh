#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
#  Multi-Tailnet Namespace Setup
#  Sets up tsFGPU namespace for FarmGPU tailnet access
# ------------------------------

# Helper: delete link if exists
del_link_if_exists() {
  local name="$1"
  if ip link show "$name" &>/dev/null; then
    ip link del "$name"
  fi
}

# Figure out outbound (WAN) iface
WAN_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

if [[ -z "${WAN_IF}" ]]; then
  echo "setup-ts-netns: No default route found; cannot determine WAN_IF" >&2
  exit 1
fi

echo "setup-ts-netns: Using WAN_IF=${WAN_IF}"

# Ensure IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
mkdir -p /etc/sysctl.d
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-ip-forward.conf

# Ensure DNS for namespace
mkdir -p /etc/netns/tsFGPU
echo 'nameserver 8.8.8.8' >/etc/netns/tsFGPU/resolv.conf

# ------------------------------
#  tsFGPU namespace + veth
# ------------------------------
if ! ip netns list | grep -q '^tsFGPU\b'; then
  ip netns add tsFGPU
fi

del_link_if_exists veth-fgpu-host
ip link add veth-fgpu-host type veth peer name veth-fgpu-ns
ip link set veth-fgpu-ns netns tsFGPU

# host side
ip addr flush dev veth-fgpu-host || true
ip addr add 10.200.0.5/30 dev veth-fgpu-host
ip link set veth-fgpu-host up

# ns side
ip netns exec tsFGPU ip addr flush dev veth-fgpu-ns || true
ip netns exec tsFGPU ip addr add 10.200.0.6/30 dev veth-fgpu-ns
ip netns exec tsFGPU ip link set lo up
ip netns exec tsFGPU ip link set veth-fgpu-ns up
ip netns exec tsFGPU ip route replace default via 10.200.0.5

# ------------------------------
#  NAT for 10.200.0.4/30 via WAN_IF
# ------------------------------
if ! iptables -t nat -C POSTROUTING -s 10.200.0.4/30 -o "${WAN_IF}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s 10.200.0.4/30 -o "${WAN_IF}" -j MASQUERADE
fi

echo "setup-ts-netns: Completed successfully"

