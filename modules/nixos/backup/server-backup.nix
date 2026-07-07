{
  config,
  lib,
  ...
}:
let
  cfg = config.server.backup;
in
{
  options.server.backup = {
    enable = lib.mkEnableOption "shared restic backup policy";

    repository = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Restic repository URL for this host.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the restic repository password file.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the restic environment file.";
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/persist"
        "/srv"
        "/var/lib"
        "/home"
      ];
      description = "Paths included in host backups.";
    };

    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/nix"
        "/var/cache"
        "/var/tmp"
        "/swap"
      ];
      description = "Paths excluded from backups.";
    };

    pruneOpts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--keep-daily 7"
        "--keep-weekly 8"
        "--keep-monthly 12"
      ];
      description = "Restic retention policy options.";
    };

    timerOnCalendar = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Calendar expression for scheduled backups.";
    };

    timerRandomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "2h";
      description = "Randomized delay applied to the backup timer.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.repository != null;
        message = "server.backup.repository must be set when server.backup.enable = true.";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "server.backup.passwordFile must be set when server.backup.enable = true.";
      }
      {
        assertion = cfg.environmentFile != null;
        message = "server.backup.environmentFile must be set when server.backup.enable = true.";
      }
    ];

    services.restic.backups.${config.networking.hostName} = {
      initialize = true;
      repository = cfg.repository;
      passwordFile = cfg.passwordFile;
      environmentFile = cfg.environmentFile;
      inherit (cfg) paths exclude;
      extraBackupArgs = [
        "--host"
        config.networking.hostName
      ];
      pruneOpts = [
        "--host ${config.networking.hostName}"
      ]
      ++ cfg.pruneOpts;
      timerConfig = {
        OnCalendar = cfg.timerOnCalendar;
        RandomizedDelaySec = cfg.timerRandomizedDelaySec;
        Persistent = true;
      };
    };
  };
}
