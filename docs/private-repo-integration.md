# Private Repo Integration

Keep real fleet composition in a private repository and import these modules as
a dependency.

During local migration:

```nix
inputs.nix-infra-modules.url = "path:../nix-infra-modules";
```

After publishing:

```nix
inputs.nix-infra-modules.url = "github:<owner>/nix-infra-modules";
```

The private repo should own:

- host inventory and deploy metadata
- real domains, IP addresses, and DNS decisions
- SOPS recipients and encrypted secrets
- app instances and private Git sources
- organization-specific defaults

The public repo should own reusable module interfaces and implementations.
