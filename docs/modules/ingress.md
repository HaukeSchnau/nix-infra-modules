# Ingress Modules

The ingress module provides a Caddy-based interface for a host serving its
own routes from local upstreams.

Routes are tailnet-only by default. Public exposure is explicit per route.

```nix
vps.services.caddy.virtualHosts."admin.example.net" = {
  upstream = "127.0.0.1:3000";
  tailscaleOnly = true;
};

vps.services.caddy.virtualHosts."www.example.net" = {
  upstream = "127.0.0.1:8080";
  tailscaleOnly = false;
};
```

## Ownership Boundary

Public modules own the route model, generated Caddy config and validation
assertions.

Private repos own real domains, DNS records, certificate policy, host
placement, and any exceptional raw Caddy snippets.

## Invariants

- A managed virtual host sets exactly one of `upstream` or `extraConfig`.
- Tailnet-only routes restrict source ranges before proxying.

When a route does not fit the shared model, use `rawSites` in the private
adapter instead of teaching the public module private service details.
