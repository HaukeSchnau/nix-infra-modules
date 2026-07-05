# App Deployments

`lib.nixos.nixFlakeService` creates a NixOS module for one flake-packaged HTTP
application.

The implementation keeps deployment state under `/var/lib/app-deployments`,
builds a selected flake reference, starts the app as a dedicated system user,
checks health paths, and rolls back when the new version fails health checks.

The module does not require private Git credentials unless
`source.giteaTokenSecretName` is set by the consuming private repo.
