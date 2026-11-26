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
  `fleet-services` and `fleet-health-check`
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

| Export                              | Platform     | Purpose                                                          | Docs / coverage                                                            |
| ----------------------------------- | ------------ | ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `nixosModules.fleet`                | NixOS        | Complete small-fleet interface and metadata contract             | [fleet](docs/modules/fleet.md), `core-example`                             |
| `nixosModules.generatedContract`    | NixOS        | Generated services, health units and ingress routes              | [fleet](docs/modules/fleet.md), `fleet-generated-services-example`         |
| `nixosModules.fleetTooling`         | NixOS        | `fleet-services` and `fleet-health-check` commands               | [fleet](docs/modules/fleet.md)                                             |
| `nixosModules.podmanRuntime`        | NixOS        | Shared root Podman runtime, proxy network, and host capabilities | [podman runtime](docs/modules/podman-runtime.md), `podman-runtime-example` |
| `nixosModules.serverBackup`         | NixOS        | Restic backup policy with file-path secret interface             | [server backup](docs/modules/server-backup.md), `server-backup-example`    |
| `nixosModules.gitMirrors`           | NixOS        | Periodic Gitea-to-GitHub repository mirrors                      | [git mirrors](docs/modules/git-mirrors.md), `git-mirrors-example`          |
| `nixosModules.githubRunner`         | NixOS        | GitHub Actions runner leaf module                                | [runners](docs/modules/runners.md), `github-runner-example`                |
| `nixosModules.caddyIngress`         | NixOS        | Tailnet-first Caddy virtual hosts                                | [ingress](docs/modules/ingress.md)                                         |
| `darwinModules.wireguardProfiles`   | nix-darwin   | WireGuard profile activation helpers                             | [workstation](docs/modules/workstation.md)                                 |
| `darwinModules.developerFonts`      | nix-darwin   | Developer font defaults                                          | [workstation](docs/modules/workstation.md)                                 |
| `darwinModules.developerPaths`      | nix-darwin   | Developer path defaults                                          | [workstation](docs/modules/workstation.md)                                 |
| `homeManagerModules.colors`         | Home Manager | Terminal/editor color scheme leaves                              | [workstation](docs/modules/workstation.md)                                 |
| `homeManagerModules.workspaceRepos` | Home Manager | Workspace repository reconciliation                              | [workspace repos](docs/workspace-repos.md), `workspace-repos-home`         |

Available helpers:

- `lib.nixos.generatedInventory`
- `lib.nixos.generatedTypes`
- `lib.nixos.serviceMetadata`

Projects (repositories that describe what they need, and the host modules that
run them: development instances, releases, app deployments and the service
controller) live in the separate `projects-sdk` repository. Its host modules
put their routes into `nixosModules.caddyIngress`.

## Example

`examples/fleet` demonstrates one synthetic host, `core-01`, that runs the
shared Podman runtime and serves its own routes.

All domains, addresses, repos, and secret names are fake example values.

## Checks

```sh
just preflight
nix flake check --all-systems
```

The TypeScript packages under `packages/` form one pnpm workspace with Vite+ at the root.
`pnpm check` runs `vp check`: oxfmt, oxlint and the tsrs type check.

```sh
nix develop -c pnpm install
nix develop -c pnpm check
```

See `docs/private-repo-integration.md` for the intended private-repo
consumption pattern.
