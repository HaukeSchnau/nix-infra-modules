{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  vps = config.vps;
  cfg = vps.services.giteaActionsRunner;
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };

  poolInstances =
    if cfg.pools == { } then
      [
        {
          inherit (cfg) instanceName labels runnerName;
          inherit (cfg) resources;
          workspaceSlot = null;
        }
      ]
    else
      lib.concatMap (
        poolName:
        let
          pool = cfg.pools.${poolName};
        in
        map (
          index:
          let
            suffix = if pool.count == 1 then "" else "-${toString index}";
          in
          {
            instanceName = "${cfg.instanceName}-${poolName}${suffix}";
            runnerName = "${cfg.runnerName}-${poolName}${suffix}";
            inherit (pool) labels;
            resources = {
              memoryHigh =
                if pool.resources.memoryHigh == null then cfg.resources.memoryHigh else pool.resources.memoryHigh;
              memoryMax =
                if pool.resources.memoryMax == null then cfg.resources.memoryMax else pool.resources.memoryMax;
              memorySwapMax =
                if pool.resources.memorySwapMax == null then
                  cfg.resources.memorySwapMax
                else
                  pool.resources.memorySwapMax;
            };
            workspaceSlot = "${poolName}${suffix}";
          }
        ) (lib.range 1 pool.count)
      ) (builtins.attrNames cfg.pools);

  mkRunnerInstance = runner: {
    enable = true;
    name = runner.runnerName;
    url = cfg.url;
    tokenFile = cfg.tokenFile;
    labels = runner.labels;
    hostPackages = with pkgs; [
      bash
      coreutils
      curl
      docker
      gawk
      gitMinimal
      gnused
      gnutar
      gzip
      nodejs_24
      podman
      wget
    ];
    settings.runner.envs = {
      # Keep persistent workspaces outside the runner's already-deep state path.
      # Unix-domain sockets used by task runners have a small path limit.
      CI_WORKSPACE_CACHE_ROOT = "/var/cache/gitea-ci-${runner.instanceName}";
    }
    // lib.optionalAttrs (runner.workspaceSlot != null) {
      CI_WORKSPACE_SLOT = runner.workspaceSlot;
    };
  };

  mkRunnerService = runner: {
    environment = {
      CONTAINERS_CGROUP_MANAGER = "cgroupfs";
      DOCKER_HOST = "unix:///run/docker.sock";
    };
    serviceConfig = {
      CacheDirectory = "gitea-ci-${runner.instanceName}";
      SupplementaryGroups = lib.mkAfter [ "podman" ];
      PrivateUsers = false;
      ProtectProc = "default";
      # DynamicUser protects managed directories with noexec. The host executor
      # and persistent workspace both contain executable package-manager shims.
      ExecPaths = [
        "/var/lib/gitea-runner"
        "/var/cache/gitea-ci-${runner.instanceName}"
      ];
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce "5s";
      MemoryHigh = runner.resources.memoryHigh;
      MemoryMax = runner.resources.memoryMax;
      MemorySwapMax = runner.resources.memorySwapMax;
    };
  };
in
{
  imports = [ ../fleet/foundation.nix ];

  options.vps.services.giteaActionsRunner = {
    enable = lib.mkEnableOption "Gitea Actions self-hosted runner";

    metadata = serviceMetadata.mkOptions {
      displayName = "Gitea Actions Runner";
      category = "Developer";
    };

    url = lib.mkOption {
      type = lib.types.str;
      example = "https://git.example.net";
      description = "Base URL of the Gitea instance used for runner registration.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a Gitea Actions runner token file.";
    };

    instanceName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Runner instance identifier used in services.gitea-actions-runner.instances.";
    };

    runnerName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Visible runner name in the Gitea Actions UI.";
    };

    instanceNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Rendered runner instance identifiers.";
    };

    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ubuntu-22.04:host"
        "ubuntu-latest:host"
        "nixos:host"
      ];
      description = "Gitea Actions runner labels and execution backends.";
    };

    pools = lib.mkOption {
      default = { };
      description = ''
        Named runner pools. Each pool registers independently and exposes only
        its configured labels, so repositories can reserve capacity without
        coupling the module to a language or task runner. The legacy single
        runner options apply when no pools are configured.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              count = lib.mkOption {
                type = lib.types.ints.positive;
                default = 1;
                description = "Number of runner instances in this pool.";
              };

              labels = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "${name}:host" ];
                description = "Gitea labels and execution backends exposed by this pool.";
              };

              resources = {
                memoryHigh = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Optional pool-specific soft memory limit.";
                };

                memoryMax = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Optional pool-specific hard memory limit.";
                };

                memorySwapMax = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Optional pool-specific swap limit.";
                };
              };
            };
          }
        )
      );
    };

    resources = {
      memoryHigh = lib.mkOption {
        type = lib.types.str;
        default = "2.5G";
        description = "Soft memory limit for the runner service and its active job.";
      };

      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "4G";
        description = "Hard memory limit for the runner service and its active job.";
      };

      memorySwapMax = lib.mkOption {
        type = lib.types.str;
        default = "1G";
        description = "Maximum swap usage for the runner service and its active job.";
      };
    };
  };

  config = lib.mkIf (vps.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "vps.services.giteaActionsRunner.tokenFile must be set when the Gitea Actions runner is enabled.";
      }
    ]
    ++ map (poolName: {
      assertion = builtins.match "[A-Za-z0-9._-]+" poolName != null;
      message = "Gitea Actions runner pool names may contain only letters, numbers, dots, underscores, and hyphens.";
    }) (builtins.attrNames cfg.pools);

    vps.services.giteaActionsRunner.metadata.health.units = map (
      runner: "gitea-runner-${utils.escapeSystemdPath runner.instanceName}.service"
    ) poolInstances;
    vps.services.giteaActionsRunner.instanceNames = map (runner: runner.instanceName) poolInstances;

    services.gitea-actions-runner.instances = builtins.listToAttrs (
      map (runner: lib.nameValuePair runner.instanceName (mkRunnerInstance runner)) poolInstances
    );

    systemd.services = builtins.listToAttrs (
      map (
        runner:
        lib.nameValuePair "gitea-runner-${utils.escapeSystemdPath runner.instanceName}" (
          mkRunnerService runner
        )
      ) poolInstances
    );
  };
}
