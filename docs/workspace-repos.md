# Workspace Repos

`homeManagerModules.workspaceRepos` installs a `workspace-repos` command and can
optionally run it during Home Manager activation.

The module is intentionally inventory-agnostic. Public defaults use an empty
inventory and write captured inventories under
`~/.config/workspace-repos/inventory.generated.json`. Private fleet or
workstation repos should provide their own `workspaceRepos.inventoryFile` and,
if desired, a repository-local `workspaceRepos.writableInventoryPath`.

## Inventory Shape

```json
{
  "version": 1,
  "roots": ["Code"],
  "gitlab_groups": [],
  "repositories": [
    {
      "path": "Code/example",
      "url": "git@github.com:example/example.git",
      "bookmark": "main"
    }
  ]
}
```

## Commands

- `workspace-repos sync`: clone missing repositories, initialize colocated JJ
  repositories, ensure `origin`, and fetch. Pass `--discover-gitlab-groups` to
  expand and reconcile `gitlab_groups`.
- `workspace-repos fetch`: fetch every configured repository.
- `workspace-repos doctor`: report missing repositories or mismatched origins.
  Pass `--discover-gitlab-groups` to include dynamic GitLab group repositories.
- `workspace-repos capture --write`: discover repositories and update the
  configured writable inventory path.

Home Manager activation runs `workspace-repos sync --activation` and discovers
GitLab groups by default. Set
`workspaceRepos.activationSync.discoverGitLabGroups = false` when activation
should only reconcile the static `repositories` list.

Use `workspace-repos capture --commit` only when the writable inventory path
lives in a JJ repository and the only working-copy change is that inventory
file.
