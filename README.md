# tsproxy - Multi-Tailnet Namespace-Isolated Proxy Gateway

A Linux-based solution for accessing multiple Tailscale tailnets from a single machine using network namespace isolation. Access work LAN resources from your home network without mixing the two.

## Overview

This setup allows a central Linux host to:

1. Be joined to **multiple Tailscale networks** (e.g., *home* and *work*)
2. Keep those networks **strictly isolated** via Linux network namespaces
3. Provide **SOCKS5 proxy access** to the secondary tailnet from clients on the primary tailnet
4. Access **LAN IPs** on the secondary tailnet (via Tailscale subnet routes)
5. Support **dynamic DNS** for pretty hostnames like `http://10.100.10.141.fgpu`
6. Survive reboots (fully systemd-managed)

## How It Works

The key insight is the `.fgpu` suffix pattern. Instead of trying to route `10.100.10.141` directly (which would conflict with local networks), you access `10.100.10.141.fgpu`:

1. **DNS Resolution**: macOS resolver sends `*.fgpu` queries to the proxy host
2. **CoreDNS Synthesis**: CoreDNS extracts the IP from the hostname (`10.100.10.141.fgpu` → `10.100.10.141`)
3. **SOCKS Routing**: Browser PAC file routes `*.fgpu` traffic through the SOCKS5 proxy
4. **Namespace Proxy**: The proxy runs inside a network namespace connected to the work tailnet
5. **Subnet Routes**: If the work tailnet has subnet routes advertised, LAN IPs are reachable

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Mac Client (home tailnet)                       │
│                                                                              │
│  Browser: http://10.100.10.1.fgpu ──► PAC file ──► SOCKS5 100.121.76.21:11080│
│  DNS: 10.100.10.1.fgpu ──► /etc/resolver/fgpu ──► 100.121.76.21:53          │
│  SSH: ssh user@10.100.10.1.fgpu ──► ProxyCommand nc -X 5 -x ...             │
└──────────────────────────────────────────┬──────────────────────────────────┘
                                           │ Tailscale (home tailnet)
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Proxy Host (e.g., "demon")                           │
│                                                                              │
│  ┌─────────────────────────────────┐    ┌─────────────────────────────────┐ │
│  │ Host Namespace (home tailnet)   │    │ tsFGPU Namespace (work tailnet) │ │
│  │                                 │    │                                 │ │
│  │ tailscale0: 100.121.76.21       │    │ tailscale0: 100.68.152.46       │ │
│  │ veth-fgpu-host: 10.200.0.5/30 ◄─┼────┼─► veth-fgpu-ns: 10.200.0.6/30   │ │
│  │                                 │    │                                 │ │
│  │ expose-socks (socat)            │    │ socks-tsFGPU (microsocks)       │ │
│  │   100.121.76.21:11080 ──────────┼────┼──► 10.200.0.6:11080             │ │
│  │                                 │    │                                 │ │
│  │ coredns-fgpu                    │    │ Access to:                      │ │
│  │   100.121.76.21:53              │    │   - Work tailnet (100.x.x.x)    │ │
│  │   Synthesizes *.fgpu DNS        │    │   - LAN subnets via routes      │ │
│  └─────────────────────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Server Setup

### Prerequisites

```bash
# Install required packages
sudo apt update
sudo apt install -y dante-server socat iptables-persistent

# Install CoreDNS (download from https://github.com/coredns/coredns/releases)
# Example for amd64:
wget https://github.com/coredns/coredns/releases/download/v1.11.1/coredns_1.11.1_linux_amd64.tgz
tar -xzf coredns_1.11.1_linux_amd64.tgz
sudo mv coredns /usr/bin/
sudo chmod +x /usr/bin/coredns

# Tailscale should already be installed and running on the host (primary tailnet)
```

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/tsproxy.git
cd tsproxy

# Run the install script
sudo ./scripts/install.sh
```

Or manually:

```bash
# Copy namespace setup script
sudo cp scripts/setup-ts-netns.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/setup-ts-netns.sh

# Copy systemd service files
sudo cp systemd/*.service /etc/systemd/system/

# Copy CoreDNS config
sudo mkdir -p /etc/coredns
sudo cp dns/Corefile /etc/coredns/

# Create Tailscale state directory for namespace
sudo mkdir -p /var/lib/tailscale-tsFGPU

# Reload systemd and enable services
sudo systemctl daemon-reload
sudo systemctl enable ts-netns.service
sudo systemctl enable tailscaled-tsFGPU.service
sudo systemctl enable socks-tsFGPU.service
sudo systemctl enable expose-socks-tsFGPU.service
sudo systemctl enable coredns-fgpu.service
```

### Start Services

```bash
# Start in dependency order
sudo systemctl start ts-netns.service
sudo systemctl start tailscaled-tsFGPU.service
sudo systemctl start socks-tsFGPU.service
sudo systemctl start expose-socks-tsFGPU.service
sudo systemctl start coredns-fgpu.service
```

### Authenticate Secondary Tailscale

```bash
# Get an auth key from https://login.tailscale.com/admin/settings/keys
# Use a reusable, pre-approved key for unattended operation

sudo ip netns exec tsFGPU tailscale \
  --socket=/run/tailscale-tsFGPU/tailscaled.sock \
  up --authkey=tskey-auth-xxxxx --accept-routes
```

The `--accept-routes` flag is important - it allows the namespace to use subnet routes advertised by other nodes on the work tailnet, enabling LAN IP access.

### Persist iptables Rules

The namespace requires a NAT rule for internet access. Save the rules so they persist across reboots:

```bash
# After services are running, save iptables rules
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
```

### Verify Server Setup

```bash
# Check all services are running
systemctl status ts-netns tailscaled-tsFGPU socks-tsFGPU expose-socks-tsFGPU coredns-fgpu

# Test namespace internet connectivity
sudo ip netns exec tsFGPU ping -c 2 8.8.8.8

# Check tailscale status in namespace
sudo ip netns exec tsFGPU tailscale --socket=/run/tailscale-tsFGPU/tailscaled.sock status

# Test SOCKS proxy
curl -x socks5://100.121.76.21:11080 http://100.100.100.100

# Test DNS synthesis
dig @100.121.76.21 10.100.10.141.fgpu
```

## Client Setup (macOS)

### Step 1: DNS Resolver

Configure macOS to send `.fgpu` DNS queries to the proxy host:

```bash
# Create resolver directory
sudo mkdir -p /etc/resolver

# Create resolver for .fgpu domain
sudo tee /etc/resolver/fgpu <<EOF
nameserver 100.121.76.21
EOF
```

Verify it's working:

```bash
# Check resolver configuration
scutil --dns | grep -A5 fgpu

# Test DNS resolution
dig @100.121.76.21 10.100.10.141.fgpu
```

### Step 2: Browser Proxy

You can use either a browser extension (recommended) or a system-wide PAC file.

#### Option A: FoxyProxy Extension (Recommended for Chrome)

1. Install [FoxyProxy Standard](https://chrome.google.com/webstore/detail/foxyproxy-standard/gcknhkkoolaabfmlnjonogaaifnjlfnp) from the Chrome Web Store

2. Click the FoxyProxy icon → **Options**

3. Click **Add** to create a new proxy:
   - **Title**: `fgpu-tailnet`
   - **Type**: `SOCKS5`
   - **Hostname**: `100.121.76.21`
   - **Port**: `11080`
   - **Important**: Check **"Proxy DNS"** (this sends hostnames to the proxy for resolution)

4. Add a pattern to match `.fgpu` URLs:
   - Click **Add** under Patterns
   - **Pattern**: `*fgpu*`
   - **Type**: `Wildcard`
   - **Include**: ON (not Exclude)
   - You do NOT need any exclude patterns - unmatched URLs automatically go direct

5. **Enable pattern-based proxying**:
   - Click the FoxyProxy icon in Chrome's toolbar
   - Select **"Proxy by Patterns"** (NOT "Use fgpu-tailnet for all URLs")
   - The icon should change color to indicate it's active

Now only URLs containing `fgpu` will go through the proxy. All other traffic (google.com, etc.) goes direct.

**Alternative pattern**: For work LAN IPs that don't overlap with your home network, you can add patterns like `*://10.100.*` to proxy those IPs directly without the `.fgpu` suffix.

#### Option B: System PAC File

Create a PAC file to route `.fgpu` traffic through the SOCKS proxy:

```bash
mkdir -p ~/.proxy

cat > ~/.proxy/fgpu.pac <<'EOF'
function FindProxyForURL(url, host) {
  if (dnsDomainIs(host, ".fgpu") || shExpMatch(host, "*.fgpu")) {
    return "SOCKS5 100.121.76.21:11080; SOCKS 100.121.76.21:11080";
  }
  return "DIRECT";
}
EOF
```

Configure macOS to use the PAC file:

1. **System Settings** → **Network** → Select your network (Wi-Fi/Ethernet)
2. Click **Details...**
3. Go to **Proxies** tab
4. Check **Automatic Proxy Configuration**
5. Set URL to: `file:///Users/YOURUSERNAME/.proxy/fgpu.pac`
6. Click **OK** and **Apply**

**Note**: Some browsers (like Chrome) may not reliably read system PAC files. The FoxyProxy extension is more reliable.

### Step 3: SSH Configuration

Add to `~/.ssh/config`:

```
# Route all .fgpu hosts through the SOCKS proxy
# dig resolves the hostname locally, then nc connects via the proxy
Host *.fgpu
  ProxyCommand bash -c 'nc -X 5 -x 100.121.76.21:11080 $(dig +short %h) %p'

# Optional: Define specific hosts for convenience
Host workserver
  HostName 10.100.10.50.fgpu
  User admin
  ProxyCommand bash -c 'nc -X 5 -x 100.121.76.21:11080 $(dig +short %h) %p'

# Alternative: Direct IP access (no .fgpu suffix needed)
Host work-proxmox
  HostName 10.100.10.91
  Port 22
  User root
  ProxyCommand nc -X 5 -x 100.121.76.21:11080 %h %p
```

**How it works**: The `dig +short %h` resolves the `.fgpu` hostname locally using your Mac's DNS resolver (which queries CoreDNS via `/etc/resolver/fgpu`), then passes the resolved IP to `nc` for the SOCKS connection.

**Note**: If your home and work LANs don't have overlapping IP ranges, you can skip the `.fgpu` suffix entirely and just use raw IPs with the proxy.

## Usage Examples

Once configured, access work resources through the proxy:

| Task | With `.fgpu` suffix | Direct IP (if no LAN overlap) |
|------|---------------------|-------------------------------|
| SSH | `ssh user@10.100.10.50.fgpu` | `ssh work-proxmox` (using SSH config) |
| Browse web UI | `https://10.100.10.91.fgpu:8006` | `https://10.100.10.91:8006` (with FoxyProxy pattern) |
| curl via proxy | `curl -x socks5h://100.121.76.21:11080 https://10.100.10.1.fgpu` | `curl -x socks5h://100.121.76.21:11080 https://10.100.10.1` |

**When to use the `.fgpu` suffix:**
- Your home and work networks have overlapping IP ranges
- You want automatic proxy routing via URL pattern matching

**When you can skip it:**
- No IP overlap between networks
- You configure FoxyProxy to match IP ranges (e.g., `*://10.100.*`)

## Components Reference

### Services

| Service | Purpose |
|---------|---------|
| `ts-netns.service` | Creates tsFGPU namespace, veth pairs, NAT rules |
| `tailscaled-tsFGPU.service` | Tailscale daemon inside namespace (work tailnet) |
| `dante-tsFGPU.service` | Dante SOCKS5 server inside namespace (supports hostname resolution) |
| `expose-socks-tsFGPU.service` | socat relay exposing proxy to host tailnet |
| `coredns-fgpu.service` | Dynamic DNS synthesis for `*.fgpu` domains |

### Network Layout

| Interface | IP | Purpose |
|-----------|-----|---------|
| Host tailscale0 | 100.121.76.21 | Home tailnet connection |
| veth-fgpu-host | 10.200.0.5/30 | Host side of veth pair |
| veth-fgpu-ns | 10.200.0.6/30 | Namespace side of veth pair |
| tsFGPU tailscale0 | 100.68.152.46 | Work tailnet connection |

### Ports

| Port | Service | Binding |
|------|---------|---------|
| 11080 | SOCKS5 proxy | 100.121.76.21 (exposed), 10.200.0.6 (internal) |
| 53 | CoreDNS | 100.121.76.21, 127.0.0.1, 10.200.0.5 |

## Troubleshooting

### Namespace can't reach internet

Check the NAT rule exists for your WAN interface(s):

```bash
sudo iptables -t nat -L POSTROUTING -v -n | grep 10.200.0
```

**Multi-homed hosts**: If your server has multiple network interfaces with default routes, you need NAT rules for ALL of them. Check which interfaces have default routes:

```bash
ip route show default
```

Add NAT rules for each interface:

```bash
# Replace INTERFACE with each WAN interface name
sudo iptables -t nat -A POSTROUTING -s 10.200.0.4/30 -o INTERFACE -j MASQUERADE
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
```

### Tailscale in namespace shows health warnings

Restart the service after ensuring network connectivity:

```bash
sudo systemctl restart tailscaled-tsFGPU
```

### Can't reach LAN IPs through proxy

Verify subnet routes are advertised on the work tailnet:

```bash
sudo ip netns exec tsFGPU tailscale --socket=/run/tailscale-tsFGPU/tailscaled.sock status --json | \
  jq '[.Peer | to_entries[] | select(.value.PrimaryRoutes) | {name: .value.HostName, routes: .value.PrimaryRoutes}]'
```

Ensure `--accept-routes` was used when authenticating.

### DNS not resolving .fgpu

Check CoreDNS is running and listening:

```bash
systemctl status coredns-fgpu
dig @100.121.76.21 10.100.10.141.fgpu
```

### Browser not using proxy

1. Verify PAC file URL is correct in System Preferences
2. Test with curl directly: `curl -x socks5://100.121.76.21:11080 http://10.100.10.1.fgpu`
3. Some browsers (Firefox) have their own proxy settings - check browser preferences

## Security Considerations

- **Network Isolation**: Each tailnet runs in a completely separate namespace with its own routing table
- **No Direct Routing**: Traffic must go through the SOCKS proxy - no raw routing between tailnets
- **Minimal Exposure**: Only the SOCKS proxy and DNS are exposed to the home tailnet
- **Restricted Binding**: Services bind to specific IPs, not 0.0.0.0
- **Tailscale Auth**: Each tailnet uses separate Tailscale authentication

## Customization

### Adding Another Tailnet

To add a third tailnet, duplicate the pattern:

1. Copy and modify `setup-ts-netns.sh` with new namespace name (e.g., `tsOther`)
2. Use a different veth IP range (e.g., `10.200.0.9/30`)
3. Create new systemd services with the new namespace name
4. Add a new CoreDNS zone (e.g., `*.other`)
5. Use a different SOCKS port (e.g., `11081`)

### Changing IPs

If your Tailscale IPs differ, update:

- `dns/Corefile` - bind address
- `systemd/expose-socks-tsFGPU.service` - TCP-LISTEN address
- Client PAC file and SSH config - proxy address

## License

MIT
