# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

tsproxy is a Linux-based multi-Tailnet namespace-isolated proxy gateway. It allows a single Linux host to connect to multiple Tailscale networks while keeping them strictly isolated using Linux network namespaces, exposing secondary tailnets via SOCKS5 proxy.

## Configuration Variables

The following placeholders are used throughout the codebase and should be customized:

| Variable | Description | Default/Example |
|----------|-------------|-----------------|
| `<SUFFIX>` | DNS suffix for secondary tailnet | `work`, `corp`, `lab` |
| `<NAMESPACE>` | Linux namespace name | `tsWork`, `tsCorp`, `tsLab` |
| `<HOST_TAILNET_IP>` | Proxy host's primary tailnet IP | `100.x.x.x` |
| `<VETH_HOST_IP>` | Host side of veth pair | `10.200.0.5` |
| `<VETH_NS_IP>` | Namespace side of veth pair | `10.200.0.6` |
| `<SOCKS_PORT>` | SOCKS5 proxy port | `11080` |
| `<UPSTREAM_DNS>` | Upstream DNS servers for CoreDNS | `192.168.1.1`, `8.8.8.8` |

## Commands

### Installation
```bash
sudo ./scripts/install.sh
```

### Service Management
```bash
# Start all services (in dependency order)
sudo systemctl start ts-netns tailscaled-<NAMESPACE> dante-<NAMESPACE> expose-socks-<NAMESPACE> coredns-<SUFFIX>

# Check status
systemctl status ts-netns tailscaled-<NAMESPACE> dante-<NAMESPACE> expose-socks-<NAMESPACE> coredns-<SUFFIX>
```

### Testing/Verification
```bash
# Test namespace connectivity
sudo ip netns exec <NAMESPACE> tailscale --socket=/run/tailscale-<NAMESPACE>/tailscaled.sock status

# Test SOCKS proxy (use socks5h:// for hostname resolution via proxy)
curl -x socks5h://<HOST_TAILNET_IP>:11080 https://<SECONDARY_LAN_IP>

# Test DNS resolution
dig @<HOST_TAILNET_IP> 10.0.0.1.<SUFFIX>
```

## Architecture

```
Host Namespace (primary tailnet)              <NAMESPACE> (secondary tailnet)
┌─────────────────────────────────────┐      ┌─────────────────────────────────┐
│ tailscale0: <HOST_TAILNET_IP>       │      │ tailscale0: <SECONDARY_IP>      │
│ veth-host: 10.200.0.5/30            │◄────►│ veth-ns: 10.200.0.6/30          │
│                                     │      │                                  │
│ expose-socks (socat)                │      │ dante-<NAMESPACE> (SOCKS5)      │
│   <HOST_IP>:11080 ──────────────────┼──────┼─► 10.200.0.6:11080              │
│                                     │      │                                  │
│ coredns-<SUFFIX>                    │      │ tailscaled-<NAMESPACE>          │
│   <HOST_IP>:53 (*.<SUFFIX> DNS)     │      │   /run/tailscale-<NAMESPACE>/   │
└─────────────────────────────────────┘      └─────────────────────────────────┘
```

### Service Dependency Chain
```
ts-netns.service (creates namespace + veth pairs)
    ↓
tailscaled-<NAMESPACE>.service (Tailscale in namespace)
    ↓
dante-<NAMESPACE>.service (Dante SOCKS5 in namespace)
    ↓
expose-socks-<NAMESPACE>.service (socat forwarding to host)

coredns-<SUFFIX>.service (independent, only needs network-online)
```

### Key Components

| Component | Purpose |
|-----------|---------|
| `scripts/setup-ts-netns.sh` | Creates namespace, veth pairs, NAT rules |
| `systemd/tailscaled-<NAMESPACE>.service` | Secondary Tailscale daemon in namespace |
| `systemd/dante-<NAMESPACE>.service` | Dante SOCKS5 server in namespace (supports hostname resolution) |
| `systemd/expose-socks-<NAMESPACE>.service` | socat relay exposing proxy to host tailnet |
| `dns/Corefile` | CoreDNS config for `*.<SUFFIX>` dynamic DNS synthesis |
| `config/dante-<NAMESPACE>.conf` | Dante configuration file |

### DNS Resolution Pattern
The CoreDNS Corefile uses regex templates to synthesize A records: `10.0.0.50.<SUFFIX>` resolves to `10.0.0.50`. This allows addressing secondary tailnet hosts by embedding their IP in the hostname.

## Key Technical Details

- **Veth pair**: 10.200.0.5 (host) ↔ 10.200.0.6 (namespace) on /30 subnet
- **SOCKS port**: 11080 (both internal and exposed)
- **Tailscale state**: `/var/lib/tailscale-<NAMESPACE>/`
- **Tailscale socket**: `/run/tailscale-<NAMESPACE>/tailscaled.sock`
- **Dependencies**: dante-server, socat, coredns, tailscale, iptables-persistent

## Common Issues

### NAT Rule Missing
If the namespace can't reach the internet, the NAT rule may be missing. Check and fix:
```bash
# Check if rule exists
sudo iptables -t nat -L POSTROUTING -v -n | grep 10.200.0

# Add if missing (replace INTERFACE with your WAN interface)
sudo iptables -t nat -A POSTROUTING -s 10.200.0.4/30 -o INTERFACE -j MASQUERADE

# Save for persistence
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
```

### Multi-homed Hosts
If the server has multiple network interfaces with default routes, NAT rules are needed for ALL of them:
```bash
ip route show default  # Lists all WAN interfaces
```

### Tailscale Health Warnings
If tailscaled shows connectivity errors, ensure NAT is working then restart:
```bash
sudo systemctl restart tailscaled-<NAMESPACE>
```

### Browser Proxy Not Working
1. Ensure FoxyProxy is set to "Proxy by Patterns" mode
2. Check "Proxy DNS" is enabled in FoxyProxy settings
3. Verify pattern matches your suffix (e.g., `*work*` for `.work`)
