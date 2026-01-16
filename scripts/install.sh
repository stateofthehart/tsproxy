#!/usr/bin/env bash
set -euo pipefail

# tsproxy Installation Script
# Run with: sudo ./install.sh
#
# IMPORTANT: Before running this script:
# 1. Edit the configuration files to replace placeholders with your values:
#    - scripts/setup-ts-netns.sh: Set NAMESPACE, VETH names
#    - dns/Corefile: Set HOST_TAILNET_IP, SUFFIX, upstream DNS
#    - config/dante-*.conf: Set VETH_NS_IP, SOCKS_PORT (or use defaults)
#    - systemd/*.service: Set NAMESPACE, HOST_TAILNET_IP, SOCKS_PORT
# 2. Rename files to match your namespace/suffix:
#    - systemd/tailscaled-<NAMESPACE>.service
#    - systemd/dante-<NAMESPACE>.service
#    - systemd/expose-socks-<NAMESPACE>.service
#    - systemd/coredns-<SUFFIX>.service
#    - config/dante-<NAMESPACE>.conf

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== tsproxy Installation ==="

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

# Check dependencies
echo "Checking dependencies..."
for cmd in danted socat coredns; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Please install it first."
        echo "  danted:   apt install dante-server"
        echo "  socat:    apt install socat"
        echo "  coredns:  download from https://github.com/coredns/coredns/releases"
        exit 1
    fi
done
echo "All dependencies found."

# Detect namespace from setup script
NAMESPACE=$(grep '^NAMESPACE=' "$REPO_DIR/scripts/setup-ts-netns.sh" | cut -d'"' -f2)
if [[ -z "$NAMESPACE" || "$NAMESPACE" == *"<"* ]]; then
    echo "ERROR: NAMESPACE not configured in scripts/setup-ts-netns.sh"
    echo "Please edit the configuration files before running install."
    exit 1
fi
echo "Detected namespace: $NAMESPACE"

# Install setup script
echo "Installing namespace setup script..."
cp "$REPO_DIR/scripts/setup-ts-netns.sh" /usr/local/sbin/
chmod +x /usr/local/sbin/setup-ts-netns.sh

# Install systemd services
echo "Installing systemd services..."
for svc in "$REPO_DIR/systemd/"*.service; do
    if grep -q '<NAMESPACE>\|<HOST_TAILNET_IP>\|<SUFFIX>\|<SOCKS_PORT>\|<VETH' "$svc" 2>/dev/null; then
        echo "WARNING: $svc contains unconfigured placeholders - skipping"
    else
        cp "$svc" /etc/systemd/system/
    fi
done

# Install Dante config
echo "Installing Dante configuration..."
for conf in "$REPO_DIR/config/dante-"*.conf; do
    if grep -q '<VETH_NS_IP>\|<SOCKS_PORT>' "$conf" 2>/dev/null; then
        echo "WARNING: $conf contains unconfigured placeholders - skipping"
    else
        cp "$conf" /etc/
    fi
done

# Install CoreDNS config
echo "Installing CoreDNS configuration..."
mkdir -p /etc/coredns
if grep -q '<HOST_TAILNET_IP>\|<SUFFIX>\|<UPSTREAM_DNS' "$REPO_DIR/dns/Corefile" 2>/dev/null; then
    echo "WARNING: dns/Corefile contains unconfigured placeholders - skipping"
else
    cp "$REPO_DIR/dns/Corefile" /etc/coredns/
fi

# Create state directories
echo "Creating state directories for $NAMESPACE..."
mkdir -p "/var/lib/tailscale-${NAMESPACE}"
mkdir -p "/run/tailscale-${NAMESPACE}"

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

echo ""
echo "=== Installation Complete ==="
echo ""
echo "IMPORTANT: If you saw 'unconfigured placeholders' warnings above,"
echo "you need to edit those files and re-run this script."
echo ""
echo "Next steps:"
echo "1. Enable and start the namespace service:"
echo "   sudo systemctl enable --now ts-netns"
echo ""
echo "2. Enable and start the tailscale daemon:"
echo "   sudo systemctl enable --now tailscaled-${NAMESPACE}"
echo ""
echo "3. Authenticate tailscale in the namespace:"
echo "   sudo ip netns exec ${NAMESPACE} tailscale \\"
echo "     --socket=/run/tailscale-${NAMESPACE}/tailscaled.sock \\"
echo "     up --authkey=tskey-xxxxx --accept-routes"
echo ""
echo "4. Start the SOCKS proxy and DNS services:"
echo "   sudo systemctl enable --now dante-${NAMESPACE} expose-socks-${NAMESPACE} coredns-<SUFFIX>"
echo ""
echo "5. Save iptables rules for persistence:"
echo "   sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null"
echo ""
echo "6. Configure your client (see README.md for FoxyProxy and SSH setup)"
