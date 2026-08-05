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

  workingCopyPolicyType = lib.types.submodule {
    options = {
      base = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "JJ revision on which to base a clean working copy. Defaults to the remote bookmark.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [
          "guarded"
          "snapshot-and-reset"
        ];
        default = "guarded";
        description = "How workspace-repos handles an existing working copy.";
      };
    };
  };

  repositoryType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "Checkout path, relative to the user's home directory.";
      };

      url = lib.mkOption {
        type = lib.types.str;
        description = "Canonical Git remote URL.";
      };

      bookmark = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Remote bookmark used by the automatic working-copy policy.";
      };

      workingCopy = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.oneOf [
            (lib.types.enum [ false ])
            workingCopyPolicyType
          ]
        );
        default = null;
        description = ''
          Optional working-copy policy. Null selects the automatic guarded
          policy, false opts out, and an attribute set configures it explicitly.
        '';
      };
    };
  };

  repositoryToInventory =
    repository:
    lib.filterAttrs (_: value: value != null) {
      inherit (repository) path url bookmark;
      working_copy =
        if builtins.isAttrs repository.workingCopy then
          lib.filterAttrs (_: value: value != null) repository.workingCopy
        else
          repository.workingCopy;
    };

  typedRepositories = map repositoryToInventory cfg.repositories;
  typedPaths = map (repository: repository.path) typedRepositories;
  fileRepositories = inventory.repositories or [ ];
  mergedInventory = inventory // {
    repositories =
      builtins.filter (repository: !(builtins.elem repository.path typedPaths)) fileRepositories
      ++ typedRepositories;
  };
  mergedRepositoryUrls = map (repository: repository.url) mergedInventory.repositories;
  duplicateValues =
    values:
    builtins.filter (value: lib.count (candidate: candidate == value) values > 1) (lib.unique values);

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

    repositories = lib.mkOption {
      type = lib.types.listOf repositoryType;
      default = [ ];
      description = ''
        Typed repository declarations merged into the JSON inventory. A typed
        declaration replaces an inventory-file entry with the same checkout path.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The configured workspace-repos command package.";
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
    workspaceRepos.package = workspaceRepos;

    home.packages = [
      workspaceRepos
    ];

    xdg.configFile.${configPath}.text =
      builtins.toJSON {
        inventory = mergedInventory;
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

    assertions = [
      {
        assertion = builtins.length typedPaths == builtins.length (lib.unique typedPaths);
        message = "workspaceRepos.repositories contains duplicate checkout paths: ${lib.concatStringsSep ", " (duplicateValues typedPaths)}";
      }
      {
        assertion =
          builtins.length mergedRepositoryUrls == builtins.length (lib.unique mergedRepositoryUrls);
        message = "workspaceRepos resolves the same Git URL to multiple checkout paths: ${lib.concatStringsSep ", " (duplicateValues mergedRepositoryUrls)}";
      }
    ]
    ++ lib.optional cfg.scheduledSync.enable (
      lib.hm.darwin.assertInterval "workspaceRepos.scheduledSync.period" cfg.scheduledSync.period pkgs
    );
  };
}
