#!/usr/bin/env bash
set -euo pipefail

# tsproxy Installation Script
# Run with: sudo ./install.sh

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
for cmd in microsocks socat coredns; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Please install it first."
        echo "  microsocks: apt install microsocks  (or build from source)"
        echo "  socat:      apt install socat"
        echo "  coredns:    download from https://github.com/coredns/coredns/releases"
        exit 1
    fi
done
echo "All dependencies found."

# Install setup script
echo "Installing namespace setup script..."
cp "$REPO_DIR/scripts/setup-ts-netns.sh" /usr/local/sbin/
chmod +x /usr/local/sbin/setup-ts-netns.sh

# Install systemd services
echo "Installing systemd services..."
cp "$REPO_DIR/systemd/"*.service /etc/systemd/system/

# Install CoreDNS config
echo "Installing CoreDNS configuration..."
mkdir -p /etc/coredns
cp "$REPO_DIR/dns/Corefile" /etc/coredns/

# Create state directories
echo "Creating state directories..."
mkdir -p /var/lib/tailscale-tsFGPU
mkdir -p /run/tailscale-tsFGPU

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable services
echo "Enabling services..."
systemctl enable ts-netns.service
systemctl enable tailscaled-tsFGPU.service
systemctl enable socks-tsFGPU.service
systemctl enable expose-socks-tsFGPU.service
systemctl enable coredns-fgpu.service

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Start the namespace service:"
echo "   sudo systemctl start ts-netns"
echo ""
echo "2. Start the tailscale daemon:"
echo "   sudo systemctl start tailscaled-tsFGPU"
echo ""
echo "3. Authenticate tailscale in the namespace:"
echo "   sudo ip netns exec tsFGPU tailscale \\"
echo "     --socket=/run/tailscale-tsFGPU/tailscaled.sock \\"
echo "     up --authkey=tskey-xxxxx --accept-routes"
echo ""
echo "4. Start the SOCKS proxy and DNS services:"
echo "   sudo systemctl start socks-tsFGPU expose-socks-tsFGPU coredns-fgpu"
echo ""
echo "5. Configure your client (see client/ directory)"

