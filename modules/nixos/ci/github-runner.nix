{
  config,
  lib,
  pkgs,
  ...
}:
let
  vps = config.vps;
  cfg = vps.services.githubRunner;
  runnerIndices = lib.range 1 cfg.instanceCount;
  runnerSuffix = index: if cfg.instanceCount == 1 || index == 1 then "" else "-${toString index}";
  runnerInstanceName = index: "${cfg.instanceName}${runnerSuffix index}";
  runnerDisplayName = index: "${cfg.runnerName}${runnerSuffix index}";
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };
in
{
  imports = [ ../fleet/foundation.nix ];

  options.vps.services.githubRunner = {
    enable = lib.mkEnableOption "GitHub Actions self-hosted runner";

    metadata = serviceMetadata.mkOptions {
      displayName = "GitHub Runner";
      category = "Developer";
    };

    url = lib.mkOption {
      type = lib.types.str;
      example = "https://github.com/example-org/example-repo";
      description = "GitHub repository or organization URL for runner registration.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a long-lived GitHub auth token for runner registration.
        This must be a PAT/OAuth token (for example `gho_`, `ghp_`, or
        `github_pat_`), not a short-lived registration token from the Actions
        UI/API.
      '';
    };

    instanceName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Runner instance identifier used in services.github-runners.";
    };

    runnerName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Visible runner name in the GitHub Actions UI.";
    };

    instanceCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = ''
        Number of same-label runner services to start on this host.
        When greater than 1, the first runner keeps the base name and
        additional runners use numeric suffixes like `-2`, `-3`, etc.
      '';
    };

    extraLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nixos"
        "vps"
      ];
      description = "Extra labels added to this runner.";
    };
  };

  config = lib.mkIf (vps.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "vps.services.githubRunner.tokenFile must be set when the GitHub runner is enabled.";
      }
    ];

    vps.services.githubRunner.metadata.health.units = map (
      index: "github-runner-${runnerInstanceName index}.service"
    ) runnerIndices;

    users.groups.github-runner = { };
    users.users.github-runner = {
      isSystemUser = true;
      group = "github-runner";
      extraGroups = [ "podman" ];
      home = "/var/lib/github-runner";
      createHome = true;
      linger = true;
      subUidRanges = [
        {
          startUid = 231072;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 231072;
          count = 65536;
        }
      ];
    };

    systemd.tmpfiles.rules = map (
      index:
      "d /var/lib/github-runner-work/${runnerInstanceName index} 0700 github-runner github-runner - -"
    ) runnerIndices;

    services.github-runners = builtins.listToAttrs (
      map (
        index:
        let
          instanceName = runnerInstanceName index;
        in
        {
          name = instanceName;
          value = {
            enable = true;
            url = cfg.url;
            name = runnerDisplayName index;
            workDir = "/var/lib/github-runner-work/${instanceName}";
            replace = true;
            tokenFile = cfg.tokenFile;
            nodeRuntimes = [ "node24" ];
            extraLabels = cfg.extraLabels;
            extraPackages = [
              pkgs.bun
              pkgs.docker
            ];
            user = "github-runner";
            group = "github-runner";
            extraEnvironment = {
              CONTAINERS_CGROUP_MANAGER = "cgroupfs";
              DOCKER_HOST = "unix:///run/docker.sock";
              XDG_RUNTIME_DIR = "/run/github-runner";
            };
            serviceOverrides = {
              SupplementaryGroups = [ "podman" ];
              RuntimeDirectory = "github-runner";
              RuntimeDirectoryMode = "0700";
              PrivateUsers = false;
              ProtectProc = "default";
              Restart = lib.mkForce "on-failure";
              RestartSec = "5s";
              MemoryHigh = "4.5G";
              MemoryMax = "5.5G";
              MemorySwapMax = "1.5G";
            };
          };
        }
      ) runnerIndices
    );
  };
}
