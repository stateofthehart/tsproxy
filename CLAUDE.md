# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

tsproxy is a Linux-based multi-Tailnet namespace-isolated proxy gateway. It allows a single Linux host to connect to multiple Tailscale networks while keeping them strictly isolated using Linux network namespaces, exposing secondary tailnets via SOCKS5 proxy.

## Commands

### Installation
```bash
sudo ./scripts/install.sh
```

### Service Management
```bash
# Start all services (in dependency order)
sudo systemctl start ts-netns tailscaled-tsFGPU dante-tsFGPU expose-socks-tsFGPU coredns-fgpu

# Check status
systemctl status ts-netns tailscaled-tsFGPU dante-tsFGPU expose-socks-tsFGPU coredns-fgpu
```

### Testing/Verification
```bash
# Test namespace connectivity
sudo ip netns exec tsFGPU tailscale --socket=/run/tailscale-tsFGPU/tailscaled.sock status

# Test SOCKS proxy
curl -x socks5://100.121.76.21:11080 http://100.100.100.100

# Test DNS resolution
dig @100.121.76.21 10.100.10.141.fgpu
```

## Architecture

```
Host Namespace (home tailnet)                 tsFGPU Namespace (fgpu tailnet)
┌─────────────────────────────────────┐      ┌─────────────────────────────────┐
│ tailscale0: 100.121.76.21           │      │ tailscale0: 100.68.152.46       │
│ veth-fgpu-host: 10.200.0.5/30       │◄────►│ veth-fgpu-ns: 10.200.0.6/30     │
│                                     │      │                                  │
│ expose-socks (socat)                │      │ dante-tsFGPU (dante SOCKS5)     │
│   100.121.76.21:11080 ──────────────┼──────┼─► 10.200.0.6:11080              │
│                                     │      │                                  │
│ coredns-fgpu                        │      │ tailscaled-tsFGPU               │
│   100.121.76.21:53 (*.fgpu DNS)     │      │   /run/tailscale-tsFGPU/...     │
└─────────────────────────────────────┘      └─────────────────────────────────┘
```

### Service Dependency Chain
```
ts-netns.service (creates namespace + veth pairs)
    ↓
tailscaled-tsFGPU.service (Tailscale in namespace)
    ↓
dante-tsFGPU.service (Dante SOCKS5 in namespace)
    ↓
expose-socks-tsFGPU.service (socat forwarding to host)

coredns-fgpu.service (independent, only needs network-online)
```

### Key Components

| Component | Purpose |
|-----------|---------|
| `scripts/setup-ts-netns.sh` | Creates tsFGPU namespace, veth pairs, NAT rules |
| `systemd/tailscaled-tsFGPU.service` | Secondary Tailscale daemon in namespace |
| `systemd/dante-tsFGPU.service` | Dante SOCKS5 server in namespace (supports hostname resolution) |
| `systemd/expose-socks-tsFGPU.service` | socat relay exposing proxy to host tailnet |
| `dns/Corefile` | CoreDNS config for `*.fgpu` dynamic DNS synthesis |
| `/etc/dante-tsFGPU.conf` | Dante configuration file |

### DNS Resolution Pattern
The CoreDNS Corefile uses regex templates to synthesize A records: `10.100.10.141.fgpu` resolves to `10.100.10.141`. This allows addressing secondary tailnet hosts by embedding their IP in the hostname.

## Key Technical Details

- **Veth pair**: 10.200.0.5 (host) ↔ 10.200.0.6 (namespace) on /30 subnet
- **SOCKS port**: 11080 (both internal and exposed)
- **Tailscale state**: `/var/lib/tailscale-tsFGPU/`
- **Tailscale socket**: `/run/tailscale-tsFGPU/tailscaled.sock`
- **Dependencies**: dante-server, socat, coredns, tailscale, iptables-persistent

## Common Issues

### NAT Rule Missing
If the namespace can't reach the internet, the NAT rule may be missing. Check and fix:
```bash
# Check if rule exists
sudo iptables -t nat -L POSTROUTING -v -n | grep 10.200.0

# Add if missing (replace eno1 with your WAN interface)
sudo iptables -t nat -A POSTROUTING -s 10.200.0.4/30 -o eno1 -j MASQUERADE

# Save for persistence
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
```

### Tailscale Health Warnings
If tailscaled-tsFGPU shows connectivity errors, ensure NAT is working then restart:
```bash
sudo systemctl restart tailscaled-tsFGPU
```
