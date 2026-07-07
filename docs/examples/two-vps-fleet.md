# Two VPS Fleet Example

The example fleet is synthetic but mirrors a common production shape:

- `core-01` owns application processes and an internal Caddy ingress.
- `edge-01` owns public TLS and forwards generated routes to `core-01`.

Use reserved example domains and addresses only. Do not place real hostnames,
IP addresses, or secret names in this example.

## Walkthrough

`core-01` imports `lib.nixos.nixFlakeService` to describe one fake app and then
enables the app deployment and Caddy modules. From that normal service config,
the fleet contract generates:

- `vps.generated.services` for inventory and health checks
- `vps.generated.ingressRoutes` for local Caddy routes
- `vps.generated.edgeIngress` for an edge host to consume

`edge-01` receives `core-01.config.vps.generated.edgeIngress` and enables
`vps.services.edgeIngress`. That module renders public Caddy reverse proxies
and HAProxy TCP listeners from the generated contract.

Useful inspection commands:

```sh
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.services
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.edgeIngress
nix eval --json .#nixosConfigurations.edge-01.config.services.haproxy.enable
nix eval .#checks.x86_64-linux.edge-tcp-range-example.drvPath
```
