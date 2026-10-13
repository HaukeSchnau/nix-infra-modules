# Fleet Example

`examples/fleet` is one synthetic host, `core-01`, that runs a fake app and
serves its own routes with Caddy. Use reserved example domains and addresses
only. Do not place real hostnames, IP addresses, or secret names in this
example.

## Walkthrough

`core-01` imports `lib.nixos.nixFlakeService` to describe one fake app and then
enables the app deployment and Caddy modules. From that normal service config,
the fleet contract generates:

- `vps.generated.services` for inventory and health checks
- `vps.generated.ingressRoutes` for the host's Caddy routes

Useful inspection commands:

```sh
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.services
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.ingressRoutes
```
