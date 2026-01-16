// PAC file for routing .<SUFFIX> traffic through SOCKS proxy
// Install: System Preferences → Network → Proxies → Automatic Proxy Configuration
// Point to file:///path/to/proxy.pac or host on a web server
//
// CUSTOMIZE:
//   <SUFFIX>: Your DNS suffix (e.g., work, corp, lab)
//   <HOST_TAILNET_IP>: Your proxy host's Tailscale IP
//   <SOCKS_PORT>: SOCKS5 port (default: 11080)
//
// NOTE: Many browsers (including Chrome) don't reliably read system PAC files.
// Consider using FoxyProxy browser extension instead (see README.md).

function FindProxyForURL(url, host) {
  // Route all .<SUFFIX> traffic through the SOCKS5 proxy
  if (dnsDomainIs(host, ".<SUFFIX>") || shExpMatch(host, "*.<SUFFIX>")) {
    return "SOCKS5 <HOST_TAILNET_IP>:<SOCKS_PORT>";
  }

  // All other traffic goes direct
  return "DIRECT";
}

