# macOS DNS Resolver Configuration

Configure macOS to route `.fgpu` DNS queries to the proxy host.

## Setup

```bash
# Create resolver directory if it doesn't exist
sudo mkdir -p /etc/resolver

# Create resolver file for .fgpu domain
sudo tee /etc/resolver/fgpu <<EOF
nameserver 100.121.76.21
EOF
```

## How It Works

macOS checks `/etc/resolver/` for domain-specific DNS configurations.
The file name (`fgpu`) corresponds to the TLD being configured.

When you query any `.fgpu` hostname:
1. macOS sees the domain ends in `.fgpu`
2. It checks `/etc/resolver/fgpu`
3. DNS query goes to `100.121.76.21` (the proxy host)
4. CoreDNS on the proxy host synthesizes the response

## Verify

```bash
# Check resolver configuration
scutil --dns | grep -A5 "resolver #[0-9]" | grep -A5 fgpu

# Test resolution
dig @100.121.76.21 10.100.10.141.fgpu

# Test full chain
ping 10.100.10.141.fgpu
```

## Notes

- Only `.fgpu` queries go to the proxy host
- All other DNS uses your normal resolvers
- No need to modify `/etc/hosts` or system DNS settings

