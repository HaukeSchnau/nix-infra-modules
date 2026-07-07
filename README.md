# nix-infra-modules

Reusable Nix infrastructure modules for small self-hosted fleets.

This repository is the public, reusable half of a private infrastructure setup.
It demonstrates how to keep fleet contracts, service modules, examples, and
checks shareable while leaving real host placement, domains, secrets, DNS, and
deployment state in a private repo.

## What This Demonstrates

- generated fleet contracts that let one host publish routes and another host
  consume them without duplicating inventory
- tailnet-first ingress where public exposure is explicit per route
- small operational commands generated from module metadata, such as
  `vps-services` and `vps-health-check`
- flake-based application deployment plumbing with health checks and rollback
- private adapters over public modules for token files, SOPS secrets, real
  domains, and provider policy
- secret-free examples and checks that exercise the public interfaces

## Privacy Model

Public modules own reusable interfaces and implementations. They should stay
generic, boring, and safe to import from any fleet.

Private repos own concrete adapters: real hosts, secret names, DNS, domains,
provider settings, service placement, and deployment workflows. A private repo
can pin this flake for stable changes or use `--override-input
nix-infra-modules ../nix-infra-modules` for fast local iteration.

## Module Index

```nix
{
  inputs.nix-infra-modules.url = "github:<owner>/nix-infra-modules";
}
```

| Export | Platform | Purpose | Docs / coverage |
| --- | --- | --- | --- |
| `nixosModules.fleet` | NixOS | Complete small-fleet interface and metadata contract | [fleet](docs/modules/fleet.md), `core-example`, `edge-example` |
| `nixosModules.generatedContract` | NixOS | Generated services, health units, ingress routes, and edge contracts | [fleet](docs/modules/fleet.md), `fleet-generated-services-example`, `edge-contract-example` |
| `nixosModules.fleetTooling` | NixOS | `vps-services` and `vps-health-check` commands | [fleet](docs/modules/fleet.md) |
| `nixosModules.podmanRuntime` | NixOS | Shared root Podman runtime, proxy network, and host capabilities | [podman runtime](docs/modules/podman-runtime.md), `podman-runtime-example` |
| `nixosModules.serverBackup` | NixOS | Restic backup policy with file-path secret interface | [server backup](docs/modules/server-backup.md), `server-backup-example` |
| `nixosModules.githubRunner` | NixOS | GitHub Actions runner leaf module | [runners](docs/modules/runners.md), `github-runner-example` |
| `nixosModules.giteaActionsRunner` | NixOS | Gitea Actions runner leaf module | [runners](docs/modules/runners.md), `gitea-runner-example` |
| `nixosModules.caddyIngress` | NixOS | Tailnet-first Caddy virtual hosts and internal ingress | [ingress](docs/modules/ingress.md) |
| `nixosModules.edgeIngress` | NixOS | Public edge proxy for generated upstream routes and TCP forwards | [ingress](docs/modules/ingress.md), `edge-tcp-range-example` |
| `nixosModules.appDeployments` | NixOS | Tailnet webhook and shared app deployment plumbing | [app deployments](docs/modules/app-deployments.md) |
| `darwinModules.wireguardProfiles` | nix-darwin | WireGuard profile activation helpers | [workstation](docs/modules/workstation.md) |
| `darwinModules.developerFonts` | nix-darwin | Developer font defaults | [workstation](docs/modules/workstation.md) |
| `darwinModules.developerPaths` | nix-darwin | Developer path defaults | [workstation](docs/modules/workstation.md) |
| `homeManagerModules.colors` | Home Manager | Terminal/editor color scheme leaves | [workstation](docs/modules/workstation.md) |
| `homeManagerModules.workspaceRepos` | Home Manager | Workspace repository reconciliation | [workspace repos](docs/workspace-repos.md), `workspace-repos-home` |

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
just preflight
nix flake check --all-systems
```

See `docs/private-repo-integration.md` for the intended private-repo
consumption pattern.
