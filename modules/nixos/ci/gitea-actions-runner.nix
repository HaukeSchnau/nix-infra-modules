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
  systemdInstanceName = utils.escapeSystemdPath cfg.instanceName;
in
{
  options.vps.services.giteaActionsRunner = {
    enable = lib.mkEnableOption "Gitea Actions self-hosted runner";

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

    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ubuntu-22.04:host"
        "ubuntu-latest:host"
        "nixos:host"
      ];
      description = "Gitea Actions runner labels and execution backends.";
    };
  };

  config = lib.mkIf (vps.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "vps.services.giteaActionsRunner.tokenFile must be set when the Gitea Actions runner is enabled.";
      }
    ];

    vps.services.giteaActionsRunner.metadata.health.units = [
      "gitea-runner-${systemdInstanceName}.service"
    ];

    services.gitea-actions-runner.instances.${cfg.instanceName} = {
      enable = true;
      name = cfg.runnerName;
      url = cfg.url;
      tokenFile = cfg.tokenFile;
      labels = cfg.labels;
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
    };

    systemd.services."gitea-runner-${systemdInstanceName}" = {
      environment = {
        CONTAINERS_CGROUP_MANAGER = "cgroupfs";
        DOCKER_HOST = "unix:///run/docker.sock";
      };
      serviceConfig = {
        SupplementaryGroups = lib.mkAfter [ "podman" ];
        PrivateUsers = false;
        ProtectProc = "default";
        Restart = lib.mkForce "on-failure";
        RestartSec = lib.mkForce "5s";
        MemoryHigh = "2.5G";
        MemoryMax = "4G";
        MemorySwapMax = "1G";
      };
    };
  };
}
