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
in
{
  server-backup-example = pkgs.runCommand "server-backup-example" { } ''
    test '${backup.repository}' = 's3:https://s3.example.net/example-backup'
    test '${backup.passwordFile}' = '/run/secrets/restic-password'
    test '${backup.environmentFile}' = '/run/secrets/restic-env'
    test '${if builtins.elem "--host core-01" backup.pruneOpts then "yes" else "no"}' = 'yes'
    touch $out
  '';
}
