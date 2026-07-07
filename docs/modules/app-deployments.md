# App Deployments

`lib.nixos.nixFlakeService` creates a NixOS module for one flake-packaged HTTP
application.

The implementation keeps deployment state under `/var/lib/app-deployments`,
builds a selected flake reference, starts the app as a dedicated system user,
checks health paths, and rolls back when the new version fails health checks.

The module does not require private Git credentials unless
`source.giteaTokenSecretName` is set by the consuming private repo.

## Ownership Boundary

Public modules own the deployment state layout, generated service wrapper,
health-check and rollback flow, and tailnet webhook plumbing.

Private repos own app instances, repository URLs, credential secret names,
webhook token secrets, branch/revision policy, and placement on real hosts.

## Invariants

- App state lives under `/var/lib/app-deployments`.
- The webhook is tailnet-only by default and requires a token when enabled.
- The update service records requested revisions separately from deployed
  revisions.
- A failed health check keeps or restores the previous working profile.

Use `lib.nixos.nixFlakeService` for ordinary flake-packaged HTTP apps. Add
private wrappers when a real app needs credentials or deployment policy that
should not be public.
