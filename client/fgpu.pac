// PAC file for routing .fgpu traffic through SOCKS proxy
// Install: System Preferences → Network → Proxies → Automatic Proxy Configuration
// Point to file:///path/to/fgpu.pac or host on a web server

function FindProxyForURL(url, host) {
  // Route all .fgpu traffic through the SOCKS5 proxy
  if (dnsDomainIs(host, ".fgpu") || shExpMatch(host, "*.fgpu")) {
    // Replace with your proxy host's tailnet IP
    return "SOCKS5 100.121.76.21:11080";
  }
  
  // All other traffic goes direct
  return "DIRECT";
}

