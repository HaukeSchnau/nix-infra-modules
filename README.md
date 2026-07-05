# nix-infra-modules

Reusable NixOS infrastructure modules for small self-hosted fleets.

The modules focus on a few opinionated interfaces:

- tailnet-first Caddy ingress with explicit public exposure
- edge-host forwarding from generated app-host contracts
- flake-based application deployments with health checks and rollback
- generated service inventory for health checks and documentation

This repository intentionally contains no real hosts, secrets, domains, or
deployment state. A private fleet repo should import these modules and own the
concrete adapters: host inventory, secret names, DNS, provider settings, and
service placement.

## Module Index

```nix
{
  inputs.nix-infra-modules.url = "github:<owner>/nix-infra-modules";
}
```

Available NixOS modules:

- `nixosModules.fleet`
- `nixosModules.caddyIngress`
- `nixosModules.edgeIngress`
- `nixosModules.appDeployments`

Available helpers:

- `lib.nixos.nixFlakeService`
- `lib.nixos.generatedInventory`
- `lib.nixos.generatedTypes`

## Example

`examples/two-vps-fleet` demonstrates a synthetic two-host layout:

- `core-01`: owns application runtime and internal ingress
- `edge-01`: owns public TLS and forwards routes to `core-01`

All domains, addresses, repos, and secret names are fake example values.

## Checks

```sh
nix flake check
gitleaks detect --source . --no-git --redact
```

See `docs/private-repo-integration.md` for the intended private-repo
consumption pattern.
