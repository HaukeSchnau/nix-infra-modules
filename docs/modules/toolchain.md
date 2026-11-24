# Toolchain

`lib.toolchain { pkgs }` returns the Node and pnpm every TypeScript project shares:

- `nodejs` is Node 26 (`nodejs-slim_26`, without npm and corepack).
- `pnpm` is pnpm 12. Its `nodejs-slim` is the same Node, which `fetchPnpmDeps` runs.

This SDK picks the major versions. The exact versions come from the `pkgs` a repository passes, so
they move with its nixpkgs. That nixpkgs, in the flake and in devenv, must have `nodejs-slim_26`
and `pnpm_12`; an older one fails evaluation on the missing attribute. A new major lands here and
reaches a repository when it updates its `nix-infra-modules` input to it and its nixpkgs to one
that has it.

## In a repository

devenv and the flake share `nix/toolchain.nix`, which adds the repository's own tools to the SDK's:

```nix
# `sdk` is the nix-infra-modules source: the flake's input or devenv's `inputs.projectSdk`.
{ pkgs, sdk }:
import "${sdk}/lib/toolchain.nix" { inherit pkgs; }
// {
  postgresql = pkgs.postgresql_18;
}
```

The flake passes its input:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-infra-modules = {
      url = "github:<owner>/nix-infra-modules/<rev>";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, nix-infra-modules, ... }:
    let
      toolchain = pkgs: import ./nix/toolchain.nix { inherit pkgs; sdk = nix-infra-modules; };
    in
    {
      devShells.x86_64-linux.ci = nixpkgs.legacyPackages.x86_64-linux.mkShellNoCC {
        packages = builtins.attrValues (toolchain nixpkgs.legacyPackages.x86_64-linux);
      };
    };
}
```

devenv passes `projectSdk`, the same SDK pinned in `devenv.yaml` with `flake: false`:

```nix
{ pkgs, inputs, ... }:
{
  packages = builtins.attrValues (import ./nix/toolchain.nix { inherit pkgs; sdk = inputs.projectSdk; });
}
```

A repository without extra tools calls `nix-infra-modules.lib.toolchain { inherit pkgs; }` in the
flake and `import (inputs.projectSdk + "/lib/toolchain.nix") { inherit pkgs; }` in devenv.

Pin `devenv.yaml` to the flake's SDK revision and nixpkgs revision. The pnpm version comes from
nixpkgs, and `package.json` names exactly one.

## packageManager

When `packageManager` in `package.json` names another pnpm than the one running, pnpm 12 downloads
the named version and runs that instead, without a word. A shell whose field has drifted no longer
runs the Nix pnpm. Make pnpm refuse instead, in `pnpm-workspace.yaml`:

```yaml
pmOnFail: error
```

pnpm then refuses to run in the project with `ERR_PNPM_BAD_PM_VERSION`, naming both versions. Nix
builds don't check: `fetchPnpmDeps` and `pnpmConfigHook` export `pnpm_config_pm_on_fail=ignore`, which
wins over the file. After a toolchain update, write the Nix pnpm's version into the field:

```sh
pnpm --pm-on-fail=ignore pkg set "packageManager=pnpm@$(pnpm --pm-on-fail=ignore --version)"
```

In Nix the same version is `toolchain.pnpm.version`.
