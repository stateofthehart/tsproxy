# macOS DNS Resolver Configuration

Configure macOS to route `.<SUFFIX>` DNS queries to the proxy host.

**CUSTOMIZE:**
- `<SUFFIX>`: Your DNS suffix (e.g., `work`, `corp`, `lab`)
- `<HOST_TAILNET_IP>`: Your proxy host's Tailscale IP on the primary tailnet

## Setup

```bash
# Create resolver directory if it doesn't exist
sudo mkdir -p /etc/resolver

# Create resolver file for .<SUFFIX> domain
# Replace <SUFFIX> and <HOST_TAILNET_IP> with your values
sudo tee /etc/resolver/<SUFFIX> <<EOF
nameserver <HOST_TAILNET_IP>
EOF
```

## How It Works

macOS checks `/etc/resolver/` for domain-specific DNS configurations.
The file name corresponds to the TLD being configured.

When you query any `.<SUFFIX>` hostname:
1. macOS sees the domain ends in `.<SUFFIX>`
2. It checks `/etc/resolver/<SUFFIX>`
3. DNS query goes to your proxy host
4. CoreDNS on the proxy host synthesizes the response

## Verify

```bash
# Check resolver configuration
scutil --dns | grep -A5 "resolver #[0-9]" | grep -A5 <SUFFIX>

# Test resolution (replace with your values)
dig @<HOST_TAILNET_IP> 10.0.0.50.<SUFFIX>

# Test full chain
ping 10.0.0.50.<SUFFIX>
```

## Notes

- Only `.<SUFFIX>` queries go to the proxy host
- All other DNS uses your normal resolvers
- No need to modify `/etc/hosts` or system DNS settings

