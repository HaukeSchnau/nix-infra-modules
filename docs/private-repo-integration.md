# Private Repo Integration

Keep real fleet composition in a private repository and import these modules as
a dependency.

Use the published input in the private repo:

```nix
inputs.nix-infra-modules.url = "github:<owner>/nix-infra-modules";
```

During local module development, keep the lock pinned and override the input at
the command line:

```sh
nix build --override-input nix-infra-modules ../nix-infra-modules .#checks.x86_64-linux.edge-example
darwin-rebuild switch --flake . --override-input nix-infra-modules ../nix-infra-modules
```

Private repos can wrap those commands in host-aware recipes; for example:

```sh
just validate-local-modules-drvs edge-runtime srv-2
just apply-host-dev srv-2
just verify-host srv-2
```

The private repo should own:

- host inventory and deploy metadata
- real domains, IP addresses, and DNS decisions
- SOPS recipients and encrypted secrets
- app instances and private Git sources
- organization-specific defaults

The public repo should own reusable module interfaces and implementations.
