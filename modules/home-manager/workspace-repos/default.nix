{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.workspaceRepos;

  workspaceReposScript = ./workspace-repos.py;
  inventory = builtins.fromJSON (builtins.readFile cfg.inventoryFile);

  workspaceRepos = pkgs.writeShellApplication {
    name = "workspace-repos";
    runtimeInputs = [
      pkgs.git
      pkgs.glab
      pkgs.jujutsu
      pkgs.python3
    ]
    ++ lib.optionals (!pkgs.stdenv.isDarwin) [
      pkgs.openssh
    ];
    text = ''
      ${lib.optionalString pkgs.stdenv.isDarwin ''
        export GIT_SSH_COMMAND=/usr/bin/ssh
        export PATH="$PATH:/usr/bin:/bin"
      ''}
      exec python3 ${workspaceReposScript} "$@"
    '';
  };

  configPath = "workspace-repos/config.json";
  syncArgs = [
    "sync"
    "--timeout"
    (toString cfg.activationSync.timeoutSeconds)
  ]
  ++ lib.optionals cfg.activationSync.discoverGitLabGroups [ "--discover-gitlab-groups" ]
  ++ lib.optionals (!cfg.activationSync.fetch) [ "--no-fetch" ];
  scheduledSync = pkgs.writeShellApplication {
    name = "workspace-repos-scheduled-sync";
    text = ''
      exec ${lib.getExe workspaceRepos} ${lib.escapeShellArgs syncArgs}
    '';
  };
in
{
  options.workspaceRepos = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to install and run workspace repository reconciliation.";
    };

    inventoryFile = lib.mkOption {
      type = lib.types.path;
      default = ./empty-inventory.json;
      description = "Generated workspace repository inventory read by Home Manager.";
    };

    writableInventoryPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.config/workspace-repos/inventory.generated.json";
      description = "Mutable checkout path where `workspace-repos capture --write` updates the inventory.";
    };

    activationSync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether Home Manager activation should reconcile declared repositories.";
      };

      fetch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether activation reconciliation should fetch declared repositories.";
      };

      discoverGitLabGroups = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether activation reconciliation should discover and reconcile inventory GitLab groups.";
      };

      timeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Per-command timeout for activation reconciliation.";
      };
    };

    scheduledSync = {
      enable = lib.mkEnableOption "scheduled workspace repository reconciliation";

      period = lib.mkOption {
        type = lib.types.str;
        default = "hourly";
        description = ''
          Reconciliation schedule. On Linux this is a systemd.time calendar
          expression; on macOS it uses Home Manager's launchd interval syntax.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      workspaceRepos
    ];

    xdg.configFile.${configPath}.text =
      builtins.toJSON {
        inherit inventory;
        version = 1;
        writable_inventory_path = cfg.writableInventoryPath;
      }
      + "\n";

    home.activation.workspaceReposSync = lib.mkIf cfg.activationSync.enable (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        if ! ${lib.getExe workspaceRepos} ${lib.escapeShellArgs syncArgs}; then
          echo "[workspace-repos] sync failed; continuing activation" >&2
        fi
      ''
    );

    systemd.user.services.workspace-repos-sync = lib.mkIf cfg.scheduledSync.enable {
      Unit.Description = "Reconcile workspace repositories";
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe scheduledSync;
      };
    };

    systemd.user.timers.workspace-repos-sync = lib.mkIf cfg.scheduledSync.enable {
      Unit.Description = "Periodically reconcile workspace repositories";
      Timer = {
        OnCalendar = cfg.scheduledSync.period;
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    launchd.agents.workspace-repos-sync = lib.mkIf cfg.scheduledSync.enable {
      enable = true;
      domain = lib.mkDefault "user";
      config = {
        ProgramArguments = [ (lib.getExe scheduledSync) ];
        StartCalendarInterval = lib.hm.darwin.mkCalendarInterval cfg.scheduledSync.period;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/workspace-repos.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/workspace-repos.error.log";
      };
    };

    assertions = lib.optional cfg.scheduledSync.enable (
      lib.hm.darwin.assertInterval "workspaceRepos.scheduledSync.period" cfg.scheduledSync.period pkgs
    );
  };
}
