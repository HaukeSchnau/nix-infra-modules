{
  lib,
  pkgs,
  self,
  system,
  ...
}:
let
  backupSystem = lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.serverBackup
      {
        networking.hostName = "core-01";
        fileSystems."/".device = "/dev/disk/by-label/nixos";
        boot.loader.grub.enable = false;
        system.stateVersion = "25.05";
        server.backup = {
          enable = true;
          repository = "s3:https://s3.example.net/example-backup";
          passwordFile = "/run/secrets/restic-password";
          environmentFile = "/run/secrets/restic-env";
        };
      }
    ];
  };
  backup = backupSystem.config.services.restic.backups.core-01;
  sharedBackup =
    (backupSystem.extendModules {
      modules = [
        {
          server.backup = {
            initialize = false;
            applyRetention = false;
          };
        }
      ];
    }).config.services.restic.backups.core-01;
  # A module's path extends the default list, and a host's own list too.
  extraPath = {
    server.backup.extraPaths = [ "/var/backup/postgresql" ];
  };
  extendedDefault =
    (backupSystem.extendModules { modules = [ extraPath ]; }).config.services.restic.backups.core-01;
  extendedHostList =
    (backupSystem.extendModules {
      modules = [
        extraPath
        { server.backup.paths = lib.mkDefault [ "/home" ]; }
      ];
    }).config.services.restic.backups.core-01;
in
{
  server-backup-example = pkgs.runCommand "server-backup-example" { } ''
    test '${backup.repository}' = 's3:https://s3.example.net/example-backup'
    test '${backup.passwordFile}' = '/run/secrets/restic-password'
    test '${backup.environmentFile}' = '/run/secrets/restic-env'
    test '${if builtins.elem "--host core-01" backup.pruneOpts then "yes" else "no"}' = 'yes'
    test '${lib.boolToString backup.initialize}' = 'true'
    test '${toString (builtins.length sharedBackup.pruneOpts)}' = '0'
    test '${lib.boolToString sharedBackup.initialize}' = 'false'
    test '${toString extendedDefault.paths}' = '/persist /srv /var/lib /home /var/backup/postgresql'
    test '${toString extendedHostList.paths}' = '/home /var/backup/postgresql'
    touch $out
  '';
}
