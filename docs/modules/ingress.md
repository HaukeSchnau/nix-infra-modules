# Ingress Modules

The ingress modules provide a Caddy-based module interface for two common
patterns:

- app hosts serving local upstreams
- edge hosts forwarding generated routes to an app host over a trusted network

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
