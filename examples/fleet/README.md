# Fleet Example

This example is one synthetic host shaped like a small self-hosted deployment.
It is intentionally fake: domains, repositories, host names, ports, and secret
names are placeholders.

`core-01` runs a flake-deployed app and serves its own routes with Caddy. Its
routes are declared in normal service modules; the generated contract turns
them into inventory, health units and ingress routes.

## What It Demonstrates

- generated service inventory and `vps-health-check` command wiring
- tailnet-only and public Caddy routes
- flake-based app deployment plumbing

## Try It

```sh
nix flake check
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.services
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.ingressRoutes
```

The example systems are container-like NixOS configurations for evaluation and
module testing. They are not meant to be deployed as-is.

## Private Adapter Shape

A real private repo would keep concrete policy outside this example:

```nix
{
  inputs.nix-infra-modules.url = "github:example/nix-infra-modules";

  outputs = { nixpkgs, nix-infra-modules, ... }: {
    nixosConfigurations.core-01 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-infra-modules.nixosModules.fleet
        ./hosts/core-01
        ./private/sops-adapters.nix
        ./private/dns-and-provider-policy.nix
      ];
    };
  };
}
```

That adapter layer owns real domains, secret files, DNS, deploy targets, and
host placement. The public modules only see normalized options.
