# tsproxy - Multi-Tailnet Namespace-Isolated Proxy Gateway

A Linux-based solution for accessing multiple Tailscale tailnets from a single machine using network namespace isolation. Access secondary tailnet LAN resources from your primary network without mixing the two.

## Overview

This setup allows a central Linux host to:

1. Be joined to **multiple Tailscale networks** (e.g., *home* and *work*)
2. Keep those networks **strictly isolated** via Linux network namespaces
3. Provide **SOCKS5 proxy access** to the secondary tailnet from clients on the primary tailnet
4. Access **LAN IPs** on the secondary tailnet (via Tailscale subnet routes)
5. Support **dynamic DNS** for pretty hostnames like `http://<IP>.<SUFFIX>`
6. Survive reboots (fully systemd-managed)

## Configuration

Before installation, customize these values for your environment:

| Variable | Description | Example |
|----------|-------------|---------|
| `SUFFIX` | DNS suffix for secondary tailnet (used in hostnames) | `work`, `corp`, `lab` |
| `NAMESPACE` | Linux namespace name (typically `ts<SUFFIX>`) | `tsWork`, `tsCorp` |
| `HOST_TAILNET_IP` | Your proxy host's IP on the primary tailnet | `100.x.x.x` (from `tailscale ip`) |
| `VETH_HOST_IP` | Host side of veth pair | `10.200.0.5` (default) |
| `VETH_NS_IP` | Namespace side of veth pair | `10.200.0.6` (default) |
| `SOCKS_PORT` | SOCKS5 proxy port | `11080` (default) |
| `UPSTREAM_DNS` | Your network's DNS servers | `192.168.1.1`, `8.8.8.8` |

## How It Works

The key insight is the `.<SUFFIX>` pattern. Instead of trying to route `10.0.0.50` directly (which could conflict with local networks), you access `10.0.0.50.<SUFFIX>`:

1. **DNS Resolution**: Client resolver sends `*.<SUFFIX>` queries to the proxy host
2. **CoreDNS Synthesis**: CoreDNS extracts the IP from the hostname (`10.0.0.50.<SUFFIX>` → `10.0.0.50`)
3. **SOCKS Routing**: Browser/FoxyProxy routes `*.<SUFFIX>` traffic through the SOCKS5 proxy
4. **Namespace Proxy**: The proxy runs inside a network namespace connected to the secondary tailnet
5. **Subnet Routes**: If the secondary tailnet has subnet routes advertised, LAN IPs are reachable

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Client (primary tailnet)                            │
│                                                                              │
│  Browser: http://10.0.0.50.<SUFFIX> ──► FoxyProxy ──► SOCKS5 <HOST_IP>:11080│
│  DNS: 10.0.0.50.<SUFFIX> ──► /etc/resolver/<SUFFIX> ──► <HOST_IP>:53        │
│  SSH: ssh user@10.0.0.50.<SUFFIX> ──► ProxyCommand nc -X 5 -x ...           │
└──────────────────────────────────────────┬──────────────────────────────────┘
                                           │ Tailscale (primary tailnet)
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Proxy Host                                      │
│                                                                              │
│  ┌─────────────────────────────────┐    ┌─────────────────────────────────┐ │
│  │ Host Namespace (primary)        │    │ <NAMESPACE> (secondary tailnet) │ │
│  │                                 │    │                                 │ │
│  │ tailscale0: <HOST_TAILNET_IP>   │    │ tailscale0: <SECONDARY_IP>      │ │
│  │ veth-host: 10.200.0.5/30      ◄─┼────┼─► veth-ns: 10.200.0.6/30        │ │
│  │                                 │    │                                 │ │
│  │ expose-socks (socat)            │    │ dante (SOCKS5 proxy)            │ │
│  │   <HOST_IP>:11080 ──────────────┼────┼──► 10.200.0.6:11080             │ │
│  │                                 │    │                                 │ │
│  │ coredns                         │    │ Access to:                      │ │
│  │   <HOST_IP>:53                  │    │   - Secondary tailnet IPs       │ │
│  │   Synthesizes *.<SUFFIX> DNS    │    │   - LAN subnets via routes      │ │
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
git clone https://github.com/ethans-home-lab/tsproxy.git
cd tsproxy

# Edit configuration files to match your environment:
# - config/dante-*.conf: Update IPs if using non-default veth range
# - dns/Corefile: Update HOST_TAILNET_IP and UPSTREAM_DNS
# - systemd/expose-socks-*.service: Update HOST_TAILNET_IP
# - scripts/setup-ts-netns.sh: Update namespace name if desired

# Run the install script
sudo ./scripts/install.sh
```

### Start Services

```bash
# Start in dependency order
sudo systemctl start ts-netns.service
sudo systemctl start tailscaled-<NAMESPACE>.service
sudo systemctl start dante-<NAMESPACE>.service
sudo systemctl start expose-socks-<NAMESPACE>.service
sudo systemctl start coredns-<SUFFIX>.service
```

### Authenticate Secondary Tailscale

```bash
# Get an auth key from https://login.tailscale.com/admin/settings/keys
# Use a reusable, pre-approved key for unattended operation

sudo ip netns exec <NAMESPACE> tailscale \
  --socket=/run/tailscale-<NAMESPACE>/tailscaled.sock \
  up --authkey=tskey-auth-xxxxx --accept-routes
```

The `--accept-routes` flag is important - it allows the namespace to use subnet routes advertised by other nodes on the secondary tailnet, enabling LAN IP access.

### Persist iptables Rules

The namespace requires a NAT rule for internet access. Save the rules so they persist across reboots:

```bash
# After services are running, save iptables rules
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
```

### Verify Server Setup

```bash
# Check all services are running
systemctl status ts-netns tailscaled-<NAMESPACE> dante-<NAMESPACE> expose-socks-<NAMESPACE> coredns-<SUFFIX>

# Test namespace internet connectivity
sudo ip netns exec <NAMESPACE> ping -c 2 8.8.8.8

# Check tailscale status in namespace
sudo ip netns exec <NAMESPACE> tailscale --socket=/run/tailscale-<NAMESPACE>/tailscaled.sock status

# Test SOCKS proxy
curl -x socks5h://<HOST_TAILNET_IP>:11080 https://<SECONDARY_LAN_IP>

# Test DNS synthesis
dig @<HOST_TAILNET_IP> 10.0.0.1.<SUFFIX>
```

## Client Setup (macOS)

### Step 1: DNS Resolver

Configure macOS to send `.<SUFFIX>` DNS queries to the proxy host:

```bash
# Create resolver directory
sudo mkdir -p /etc/resolver

# Create resolver for your suffix (replace <SUFFIX> and <HOST_TAILNET_IP>)
sudo tee /etc/resolver/<SUFFIX> <<EOF
nameserver <HOST_TAILNET_IP>
EOF
```

Verify it's working:

```bash
# Check resolver configuration
scutil --dns | grep -A5 <SUFFIX>

# Test DNS resolution
dig @<HOST_TAILNET_IP> 10.0.0.1.<SUFFIX>
```

### Step 2: Browser Proxy

Use a browser extension to route `*.<SUFFIX>` traffic through the SOCKS5 proxy.

**Important**: Chrome does not support SOCKS5 proxy authentication. If you enable authentication on the proxy (see [Security Considerations](#security-considerations)), you must use Firefox.

#### Option A: Firefox + FoxyProxy (Recommended - supports authentication)

1. Install [FoxyProxy Standard](https://addons.mozilla.org/en-US/firefox/addon/foxyproxy-standard/) from Firefox Add-ons

2. Click the FoxyProxy icon → **Options**

3. Click **Add** to create a new proxy:
   - **Title**: `<SUFFIX>-tailnet`
   - **Type**: `SOCKS5`
   - **Hostname**: `<HOST_TAILNET_IP>`
   - **Port**: `11080`
   - **Username**: Your proxy username (if authentication enabled)
   - **Password**: Your proxy password (if authentication enabled)
   - **Important**: Check **"Send DNS through SOCKS5 proxy"**

4. Add a pattern to match your suffix:
   - Go to **Patterns** tab
   - Click **Add**
   - **Name**: `Work suffix`
   - **Pattern**: `*<SUFFIX>*`
   - **Type**: `Wildcard`
   - **Include/Exclude**: `Include`

5. **Save** and click the FoxyProxy icon → Select **"Proxy by Patterns"**

#### Option B: Chrome + FoxyProxy (no authentication support)

Chrome's SOCKS5 implementation does not support username/password authentication. Use this option only if you're running the proxy without authentication.

1. Install [FoxyProxy Standard](https://chrome.google.com/webstore/detail/foxyproxy-standard/gcknhkkoolaabfmlnjonogaaifnjlfnp) from the Chrome Web Store

2. Click the FoxyProxy icon → **Options**

3. Click **Add** to create a new proxy:
   - **Title**: `<SUFFIX>-tailnet`
   - **Type**: `SOCKS5`
   - **Hostname**: `<HOST_TAILNET_IP>`
   - **Port**: `11080`
   - **Important**: Check **"Proxy DNS"**

4. Add a pattern to match your suffix:
   - Click **Add** under Patterns
   - **Pattern**: `*<SUFFIX>*`
   - **Type**: `Wildcard`
   - **Include**: ON (not Exclude)

5. Click the FoxyProxy icon → Select **"Proxy by Patterns"**

**Alternative pattern**: For secondary LAN IPs that don't overlap with your primary network, you can add patterns like `*://10.100.*` to proxy those IPs directly without the suffix.

#### Option B: System PAC File

Create a PAC file to route traffic through the SOCKS proxy:

```bash
mkdir -p ~/.proxy

# Replace <SUFFIX> and <HOST_TAILNET_IP> with your values
cat > ~/.proxy/<SUFFIX>.pac <<EOF
function FindProxyForURL(url, host) {
  if (dnsDomainIs(host, ".<SUFFIX>") || shExpMatch(host, "*.<SUFFIX>")) {
    return "SOCKS5 <HOST_TAILNET_IP>:11080; SOCKS <HOST_TAILNET_IP>:11080";
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
5. Set URL to: `file:///Users/<USERNAME>/.proxy/<SUFFIX>.pac`
6. Click **OK** and **Apply**

**Note**: Some browsers (like Chrome) may not reliably read system PAC files. The FoxyProxy extension is more reliable.

### Step 3: SSH Configuration

Add to `~/.ssh/config`:

#### Without proxy authentication:

```
# Route all .<SUFFIX> hosts through the SOCKS proxy
# dig resolves the hostname locally, then nc connects via the proxy
Host *.<SUFFIX>
  ProxyCommand bash -c 'nc -X 5 -x <HOST_TAILNET_IP>:11080 $(dig +short %h) %p'

# Alternative: Direct IP access (no suffix needed if no LAN overlap)
Host secondary-server
  HostName 10.0.0.50
  User admin
  ProxyCommand nc -X 5 -x <HOST_TAILNET_IP>:11080 %h %p
```

#### With proxy authentication:

The standard `nc` command doesn't support SOCKS5 authentication. Use `ncat` (from the nmap package) instead:

```bash
# Install ncat
# macOS:  brew install nmap
# Ubuntu: apt install nmap
```

```
# Route all .<SUFFIX> hosts through the authenticated SOCKS proxy
Host *.<SUFFIX>
  ProxyCommand bash -c 'ncat --proxy-type socks5 --proxy <HOST_TAILNET_IP>:11080 --proxy-auth <USER>:<PASS> $(dig +short %h) %p'
```

**How it works**: The `dig +short %h` resolves the hostname locally using your Mac's DNS resolver (which queries CoreDNS via `/etc/resolver/<SUFFIX>`), then passes the resolved IP to `nc`/`ncat` for the SOCKS connection.

## Usage Examples

Once configured, access secondary tailnet resources through the proxy:

| Task | With suffix | Direct IP (if no LAN overlap) |
|------|-------------|-------------------------------|
| SSH | `ssh user@10.0.0.50.<SUFFIX>` | `ssh secondary-server` (using SSH config) |
| Browse web UI | `https://10.0.0.50.<SUFFIX>:8006` | `https://10.0.0.50:8006` (with FoxyProxy pattern) |
| curl via proxy | `curl -x socks5h://<HOST_IP>:11080 https://10.0.0.1.<SUFFIX>` | `curl -x socks5h://<HOST_IP>:11080 https://10.0.0.1` |

**When to use the suffix:**
- Your primary and secondary networks have overlapping IP ranges
- You want automatic proxy routing via URL pattern matching

**When you can skip it:**
- No IP overlap between networks
- You configure FoxyProxy to match IP ranges (e.g., `*://10.100.*`)

## Components Reference

### Services

| Service | Purpose |
|---------|---------|
| `ts-netns.service` | Creates namespace, veth pairs, NAT rules |
| `tailscaled-<NAMESPACE>.service` | Tailscale daemon inside namespace (secondary tailnet) |
| `dante-<NAMESPACE>.service` | Dante SOCKS5 server inside namespace (supports hostname resolution) |
| `expose-socks-<NAMESPACE>.service` | socat relay exposing proxy to host tailnet |
| `coredns-<SUFFIX>.service` | Dynamic DNS synthesis for `*.<SUFFIX>` domains |

### Network Layout

| Interface | IP | Purpose |
|-----------|-----|---------|
| Host tailscale0 | `<HOST_TAILNET_IP>` | Primary tailnet connection |
| veth-host | 10.200.0.5/30 | Host side of veth pair |
| veth-ns | 10.200.0.6/30 | Namespace side of veth pair |
| Namespace tailscale0 | `<SECONDARY_IP>` | Secondary tailnet connection |

### Ports

| Port | Service | Binding |
|------|---------|---------|
| 11080 | SOCKS5 proxy | `<HOST_TAILNET_IP>` (exposed), 10.200.0.6 (internal) |
| 53 | CoreDNS | `<HOST_TAILNET_IP>`, 127.0.0.1, 10.200.0.5 |

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
sudo systemctl restart tailscaled-<NAMESPACE>
```

### Can't reach LAN IPs through proxy

Verify subnet routes are advertised on the secondary tailnet:

```bash
sudo ip netns exec <NAMESPACE> tailscale --socket=/run/tailscale-<NAMESPACE>/tailscaled.sock status --json | \
  jq '[.Peer | to_entries[] | select(.value.PrimaryRoutes) | {name: .value.HostName, routes: .value.PrimaryRoutes}]'
```

Ensure `--accept-routes` was used when authenticating.

### DNS not resolving

Check CoreDNS is running and listening:

```bash
systemctl status coredns-<SUFFIX>
dig @<HOST_TAILNET_IP> 10.0.0.1.<SUFFIX>
```

### Browser not using proxy

1. Verify FoxyProxy is set to "Proxy by Patterns" mode
2. Check the pattern matches your suffix (e.g., `*work*` for `.work`)
3. Ensure "Proxy DNS" is checked in the proxy settings
4. Test with curl directly: `curl -x socks5h://<HOST_IP>:11080 https://10.0.0.1.<SUFFIX>`

### DNS Rebind Attack warnings

Some security-conscious applications (like OPNsense) may show "DNS Rebind Attack" warnings because the HTTP Host header contains the `.<SUFFIX>` hostname. Options:
- Add the hostname to the application's allowed hostnames list
- Access the service using the raw IP (without suffix) through the proxy

## Security Considerations

### Architecture Security

| Layer | Protection |
|-------|------------|
| **Network Isolation** | Each tailnet runs in a completely separate Linux namespace with its own routing table. No direct path exists between tailnets. |
| **No Direct Routing** | Traffic must go through the SOCKS proxy - no raw IP routing between tailnets. |
| **Minimal Exposure** | Only the SOCKS proxy (port 11080) and DNS (port 53) are exposed to the primary tailnet. |
| **Restricted Binding** | Services bind to specific Tailscale IPs, not `0.0.0.0`. The proxy is not accessible from the internet. |
| **Tailscale Auth** | Each tailnet uses separate Tailscale authentication with WireGuard encryption. |

### SOCKS5 Proxy Authentication

The Dante proxy can be configured with or without username/password authentication.

#### Configuration A: No Authentication (Default)

```
socksmethod: none
```

**Trust model**: Any device on your primary tailnet that knows the proxy IP:port can use it.

**When this is acceptable**:
- Your primary tailnet contains only your personal, trusted devices
- You trust all users/devices that can join your primary tailnet
- You rely on Tailscale's device authentication as the security boundary

**Attack surface**:
- If an attacker compromises any device on your primary tailnet, they can access secondary tailnet resources through the proxy
- Tailscale ACLs on the primary tailnet can limit which devices can reach the proxy host

#### Configuration B: Username/Password Authentication

```
socksmethod: username
```

To enable authentication:

```bash
# 1. Create a system user for proxy auth
sudo useradd -r -s /usr/sbin/nologin proxyuser
sudo passwd proxyuser

# 2. Update Dante config
sudo sed -i 's/socksmethod: none/socksmethod: username/' /etc/dante-<NAMESPACE>.conf

# 3. Restart the proxy
sudo systemctl restart dante-<NAMESPACE>
```

**Trust model**: Devices must both (1) be on your primary tailnet AND (2) know the proxy credentials.

**When to use this**:
- Your primary tailnet has devices you don't fully control
- Multiple people share your primary tailnet
- You want defense-in-depth beyond Tailscale authentication
- Compliance requirements mandate authentication at each layer

**Attack surface**:
- If an attacker compromises your primary tailnet, they must still brute-force or steal the proxy credentials
- Credentials are transmitted inside the already-encrypted Tailscale tunnel
- Password can be rate-limited via PAM/fail2ban if desired

**Client compatibility**:
| Client | Auth Support |
|--------|--------------|
| Firefox + FoxyProxy | Yes |
| Chrome + FoxyProxy | **No** - Chrome doesn't support SOCKS5 auth |
| SSH with `ncat` | Yes (`--proxy-auth user:pass`) |
| SSH with `nc` | No |
| curl | Yes (`socks5h://user:pass@host:port`) |

### Potential Attack Vectors

| Attack | Without Auth | With Auth |
|--------|--------------|-----------|
| Malicious device joins primary tailnet | Can use proxy freely | Must brute-force credentials |
| Proxy host compromised | Full access to both tailnets | Full access to both tailnets |
| Credential theft (keylogger, etc.) | N/A | Attacker gains proxy access |
| Network sniffing on primary tailnet | Cannot sniff (WireGuard encrypted) | Cannot sniff (WireGuard encrypted) |
| Brute-force proxy credentials | N/A | Possible, but requires tailnet access first |

### Recommendations

1. **Minimal setup (personal use)**: No authentication is reasonable if your primary tailnet only contains your own devices. Tailscale's device authentication is already strong.

2. **Shared tailnet**: Enable authentication if others can join your primary tailnet.

3. **High-security environments**: Enable authentication + consider Tailscale ACLs to restrict which devices can reach the proxy host.

4. **Protect the proxy host**: The proxy host is the bridge between networks. Keep it updated, use strong SSH keys, and monitor for compromise.

5. **Use separate auth keys**: The secondary tailnet should use its own Tailscale auth key, not your personal login, so it can be revoked independently.

## Adding Another Tailnet

To add a third tailnet, duplicate the pattern:

1. Choose a new suffix (e.g., `lab`) and namespace name (e.g., `tsLab`)
2. Copy and modify `setup-ts-netns.sh` with new namespace name
3. Use a different veth IP range (e.g., `10.200.0.9/30` and `10.200.0.10/30`)
4. Create new systemd services with the new namespace name
5. Add a new CoreDNS zone for the new suffix
6. Use a different SOCKS port (e.g., `11081`)

## License

MIT
