# tsproxy - Multi-Tailnet Namespace-Isolated Proxy Gateway

A Linux-based solution for accessing multiple Tailscale tailnets from a single machine using network namespace isolation.

## Overview

This setup allows a central Linux host ("demon") to:

1. Be joined to **multiple Tailscale networks** (e.g. *home* and *work/fgpu*)
2. Keep those networks **strictly isolated** via Linux network namespaces
3. Provide **SOCKS5 proxy access** to the secondary tailnet from clients on the primary tailnet
4. Support **dynamic DNS** for pretty hostnames like `http://10.100.10.141.fgpu:3000`
5. Survive reboots (fully systemd-managed)

## Architecture

```
                 ┌─────────────────────────────┐
                 │           Mac client         │
                 │                              │
Browser / curl ──▶ PAC (SOCKS5 → demon:11080)  │
DNS *.fgpu ─────▶ /etc/resolver/fgpu → demon   │
                 └──────────────┬───────────────┘
                                │
                                │  Tailscale (home)
                                ▼
                     ┌───────────────────────────┐
                     │       demon (proxy host)  │
                     │    100.121.76.21 (home)   │
                     │                           │
                     │  ┌─────────────────────┐  │
                     │  │ netns: tsFGPU       │  │
                     │  │ tailscaled(fgpu)    │  │
                     │  │ 100.68.152.46       │  │
                     │  │ SOCKS5 proxy ◀──────┼──┼─── browser traffic
                     │  └─────────────────────┘  │
                     │           │               │
                     │           ▼               │
                     │   10.100.0.0/16 (fgpu)   │
                     └───────────────────────────┘
```

## Components

### System Services

| Service                     | Purpose                                              |
|-----------------------------|------------------------------------------------------|
| `ts-netns.service`          | Creates network namespace and veth pairs             |
| `tailscaled-tsFGPU.service` | Runs tailscaled inside the tsFGPU namespace          |
| `socks-tsFGPU.service`      | Runs microsocks SOCKS5 proxy inside the namespace    |
| `expose-socks-tsFGPU.service`| Exposes SOCKS proxy on host's tailnet IP via socat  |
| `coredns-fgpu.service`      | Dynamic DNS for `.fgpu` hostname resolution          |

### Network Layout

| Interface              | IP            | Purpose                           |
|------------------------|---------------|-----------------------------------|
| Host tailscale0        | 100.121.76.21 | Home tailnet connection           |
| veth-fgpu-host (host)  | 10.200.0.5/30 | Host side of veth pair            |
| veth-fgpu-ns (ns)      | 10.200.0.6/30 | Namespace side of veth pair       |
| tsFGPU tailscale0      | 100.68.152.46 | FarmGPU tailnet connection        |

## Installation

### Prerequisites

```bash
# Install required packages
sudo apt install microsocks socat

# Install CoreDNS (if not present)
# Download from https://github.com/coredns/coredns/releases
```

### Deploy Services

```bash
# Copy systemd service files
sudo cp systemd/*.service /etc/systemd/system/

# Copy setup script
sudo cp scripts/setup-ts-netns.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/setup-ts-netns.sh

# Copy CoreDNS config
sudo mkdir -p /etc/coredns
sudo cp dns/Corefile /etc/coredns/

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable --now ts-netns.service
sudo systemctl enable --now tailscaled-tsFGPU.service
sudo systemctl enable --now socks-tsFGPU.service
sudo systemctl enable --now expose-socks-tsFGPU.service
sudo systemctl enable --now coredns-fgpu.service
```

### Authenticate Tailscale in Namespace

```bash
# Get auth key from https://login.tailscale.com/admin/settings/keys
# (Use a reusable, pre-approved key for unattended operation)

sudo ip netns exec tsFGPU tailscale \
  --socket=/run/tailscale-tsFGPU/tailscaled.sock \
  up --authkey=tskey-xxxxx --accept-routes
```

## Client Configuration

### macOS

#### 1. Domain-scoped DNS

```bash
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/fgpu <<EOF
nameserver 100.121.76.21
EOF
```

#### 2. PAC File for Browser

Create a PAC file (e.g., `~/.proxy/fgpu.pac`):

```javascript
function FindProxyForURL(url, host) {
  if (dnsDomainIs(host, ".fgpu") || shExpMatch(host, "*.fgpu")) {
    return "SOCKS5 100.121.76.21:11080";
  }
  return "DIRECT";
}
```

Configure in System Preferences → Network → Proxies → Automatic Proxy Configuration.

### SSH via SOCKS

Add to `~/.ssh/config`:

```
Host *.fgpu
  ProxyCommand nc -X 5 -x 100.121.76.21:11080 %h %p
```

## Usage

Access hosts on the FarmGPU tailnet using `.fgpu` suffix:

```bash
# Web access
curl http://10.100.10.141.fgpu:3000

# SSH access
ssh user@10.100.10.141.fgpu
```

## Troubleshooting

### Check Service Status

```bash
systemctl status ts-netns tailscaled-tsFGPU socks-tsFGPU expose-socks-tsFGPU coredns-fgpu
```

### Test Namespace Connectivity

```bash
# Ping a peer on the secondary tailnet
sudo ip netns exec tsFGPU ping 100.x.x.x

# Check tailscale status in namespace
sudo ip netns exec tsFGPU tailscale --socket=/run/tailscale-tsFGPU/tailscaled.sock status
```

### Test SOCKS Proxy

```bash
# Test via exposed port
curl -x socks5://100.121.76.21:11080 http://100.100.100.100

# Test DNS resolution
dig @100.121.76.21 10.100.10.141.fgpu
```

## Design Principles

1. **Network Namespaces**: Each tailnet runs in its own isolated namespace with separate routing tables
2. **Explicit Egress**: Traffic is explicitly routed through the namespace's tailscale interface
3. **No DNS Mixing**: Client DNS goes to CoreDNS; host DNS uses its normal resolver
4. **Minimal Attack Surface**: Only SOCKS proxy is exposed; no direct routing between tailnets

## License

MIT

