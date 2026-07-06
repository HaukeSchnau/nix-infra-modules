# Two VPS Fleet Example

This example is a synthetic fleet shaped like a small self-hosted deployment.
It is intentionally fake: domains, repositories, host names, ports, and secret
names are placeholders.

## Layout

- `core-01` owns application runtime and internal Caddy ingress.
- `edge-01` owns public Caddy TLS and TCP forwarding.
- The edge host consumes `core-01.config.vps.generated.edgeIngress` to avoid
  duplicating public route inventory.

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
```

The example systems are container-like NixOS configurations for evaluation and
module testing. They are not meant to be deployed as-is.
