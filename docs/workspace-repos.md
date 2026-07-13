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
      "bookmark": "main",
      "working_copy": {
        "base": "main@origin",
        "mode": "snapshot-and-reset"
      }
    }
  ]
}
```

`working_copy.base` is opt-in per repository. After a successful fetch,
reconciliation keeps the repository's base workspace as an empty, undescribed
change directly above that revision. The default `guarded` mode only moves the
workspace when its current change is empty and undescribed and its parent is an
ancestor of the configured base. Working-copy changes, descriptions, merge
parents, local-only commits, and diverged history are left untouched and
reported.

Set `working_copy.mode` to `snapshot-and-reset` for a more assertive base
workspace. JJ snapshots the current working copy, the reconciler reports its
change ID, and then `jj new <base>` switches the workspace to a clean change
above the configured revision. Non-empty or described prior changes and their
ancestors remain in JJ history and can be restored with `jj edit <change-id>`.
The workspace's files do change to the configured base, so editor buffers and
running processes are outside this guarantee. Dynamic GitLab repositories do
not receive a working-copy policy unless they are also declared explicitly.

GitLab group entries accept an optional `host`, recursively query all subgroup
projects through GitLab's paginated group-projects API, and preserve subgroup
paths by default:

```json
{
  "group": "example",
  "host": "gitlab.example.com",
  "base_path": "Work/Repos",
  "include_archived": false,
  "preserve_namespace": true
}
```

## Commands

- `workspace-repos sync`: clone missing repositories, initialize colocated JJ
  repositories, ensure `origin`, and fetch. Pass `--discover-gitlab-groups` to
  expand and reconcile `gitlab_groups`.
- `workspace-repos fetch`: fetch every configured repository.
- `workspace-repos doctor`: report missing repositories or mismatched origins.
  Pass `--discover-gitlab-groups` to include dynamic GitLab group repositories.
  Configured working-copy bases are also checked.
- `workspace-repos capture --write`: discover repositories and update the
  configured writable inventory path.

Home Manager activation runs `workspace-repos sync` and discovers GitLab groups
by default. A failed repository or GitLab discovery is reported, while the
surrounding Home Manager activation continues so an unavailable remote does not
prevent unrelated configuration changes from activating. Set
`workspaceRepos.activationSync.discoverGitLabGroups = false` when activation
should only reconcile the static `repositories` list.

Set `workspaceRepos.scheduledSync.enable = true` to reconcile automatically on
the schedule in `workspaceRepos.scheduledSync.period` (hourly by default). The
module creates a persistent systemd user timer on Linux and a launchd agent on
macOS. Overlapping activation and scheduled runs are serialized; a second run
exits successfully after reporting that reconciliation is already in progress.

Reconciliation is deliberately non-destructive. It clones missing repositories,
adds JJ colocation, corrects `origin`, and fetches. Apart from the explicitly
configured safe `working_copy.base` behavior, it does not move working copies.
It never fast-forwards local branches, deletes repositories that leave an
inventory or GitLab group, or overwrites local changes.

Use `workspace-repos capture --commit` only when the writable inventory path
lives in a JJ repository and the only working-copy change is that inventory
file.
