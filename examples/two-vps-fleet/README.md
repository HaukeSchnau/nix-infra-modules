# Two VPS Fleet Example

This example is a synthetic fleet shaped like a small self-hosted deployment.
It is intentionally fake: domains, repositories, host names, ports, and secret
names are placeholders.

## Layout

- `core-01` owns application runtime and internal Caddy ingress.
- `edge-01` owns public Caddy TLS and TCP forwarding.
- `edge-01` consumes `core-01.config.vps.generated.edgeIngress` to avoid
  duplicating public route inventory.

`core-01` declares routes in normal service modules. The generated contract
turns those routes into a small data shape containing an upstream host,
internal ingress port, HTTP routes, TCP forwards, and TCP forward ranges.
`edge-01` receives that data shape and renders public Caddy and HAProxy config.

## What It Demonstrates

- generated service inventory and `vps-health-check` command wiring
- tailnet-only internal routes
- public edge forwarding
- flake-based app deployment plumbing
- TCP range expansion for services that need paired listener/upstream ranges

## Try It

```sh
nix flake check
nix eval .#checks.x86_64-linux.edge-tcp-range-example.drvPath
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.services
nix eval --json .#nixosConfigurations.core-01.config.vps.generated.edgeIngress
nix eval --json .#nixosConfigurations.edge-01.config.services.haproxy.enable
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
