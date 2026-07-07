# Home Manager Modules

Home Manager exports are workstation leaves:

- `colors` provides shell, editor, and terminal color configuration.
- `workspaceRepos` reconciles repository checkouts from a JSON inventory.

Private repos should provide real inventories, workspace paths, and repository
policy through adapters.
