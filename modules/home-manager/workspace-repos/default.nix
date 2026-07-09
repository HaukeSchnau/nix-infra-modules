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
        args=(
          sync
          --activation
          --timeout ${toString cfg.activationSync.timeoutSeconds}
        )
        ${lib.optionalString cfg.activationSync.discoverGitLabGroups ''
          args+=(--discover-gitlab-groups)
        ''}
        ${lib.optionalString (!cfg.activationSync.fetch) ''
          args+=(--no-fetch)
        ''}

        if ! ${lib.getExe workspaceRepos} "''${args[@]}"; then
          echo "[workspace-repos] sync failed; continuing activation" >&2
        fi
      ''
    );
  };
}
