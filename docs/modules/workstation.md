# Workstation Modules

The workstation exports are small nix-darwin and Home Manager leaves. They are
designed to be wrapped by a private workstation profile rather than imported as
a complete desktop distribution.

## nix-darwin

- `darwinModules.wireguardProfiles` renders profile activation helpers.
- `darwinModules.developerFonts` installs developer font defaults.
- `darwinModules.developerPaths` configures developer path defaults.

## Home Manager

- `homeManagerModules.colors` provides terminal and editor color leaves.
- `homeManagerModules.workspaceRepos` reconciles workspace repositories from a
  JSON inventory.

## Boundary

Public modules own reusable mechanics and fake defaults.

Private repos own real profile names, private repositories, workspaces, account
paths, secrets, and machine-specific policy.
