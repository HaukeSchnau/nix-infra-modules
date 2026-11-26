# Fleet Example

`examples/fleet` is one synthetic host, `core-01`, that runs the shared Podman
runtime and serves its own routes with Caddy. Use reserved example domains and addresses
only. Do not place real hostnames, IP addresses, or secret names in this
example.

## Walkthrough

`core-01` enables the Podman and Caddy modules and declares two Caddy routes.
From that normal service config, the fleet contract generates:

- `fleet.generated.services` for inventory and health checks
- `fleet.generated.ingressRoutes` for the host's Caddy routes

Useful inspection commands:

```sh
nix eval --json .#nixosConfigurations.core-01.config.fleet.generated.services
nix eval --json .#nixosConfigurations.core-01.config.fleet.generated.ingressRoutes
```
