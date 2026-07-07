# Ingress Modules

The ingress modules provide a Caddy-based module interface for two common
patterns:

- app hosts serving local upstreams
- edge hosts forwarding generated routes to an app host over a trusted network

Routes are tailnet-only by default. Public exposure is explicit per route.
When an app host is only reached through a separate public edge host, set
`vps.services.caddy.publicVirtualHosts.enable = false` on the app host. The
route registry and internal ingress stay available, but the app host does not
try to manage public TLS certificates.

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

Public modules own the route model, generated Caddy config, edge contract, TCP
forward expansion, and validation assertions.

Private repos own real domains, DNS records, certificate policy, host
placement, and any exceptional raw Caddy snippets.

## Invariants

- A managed virtual host sets exactly one of `upstream` or `extraConfig`.
- Tailnet-only routes restrict source ranges before proxying.
- Edge ingress requires an upstream contract and a non-empty upstream host.
- TCP forward ranges must map equal-sized listen and upstream ranges.

When a route does not fit the shared model, use `rawSites` in the private
adapter instead of teaching the public module private service details.
