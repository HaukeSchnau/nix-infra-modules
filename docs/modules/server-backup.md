# Server Backup

`nixosModules.serverBackup` defines a shared restic backup job with a file-path
secret interface.

## Public Owns

- `server.backup.repository`
- `server.backup.passwordFile`
- `server.backup.environmentFile`
- included paths, excludes, retention, and timer settings
- `server.backup.extraPaths`, where modules add paths of their own, such as a
  database dump directory
- the rendered `services.restic.backups.${networking.hostName}` job

## Private Owns

- real repository URLs
- SOPS/agenix secret names and recipients
- host-specific backup enablement
- any fleet-specific path, exclude, retention, or timer overrides

## Example

```nix
{
  networking.hostName = "core-01";
  server.backup = {
    enable = true;
    repository = "s3:https://s3.example.net/core-01";
    passwordFile = "/run/secrets/restic-password";
    environmentFile = "/run/secrets/restic-env";
  };
}
```

`paths` is the host's list: setting it, even with `mkDefault`, replaces the
default. A module that needs a path backed up adds it to `extraPaths`, which
extends `paths` either way:

```nix
{
  server.backup.extraPaths = [ "/var/backup/postgresql" ];
}
```

A private adapter can keep secret names private while setting the public file
paths:

```nix
{
  sops.secrets.restic-password.owner = "root";
  server.backup.passwordFile = config.sops.secrets.restic-password.path;
}
```
