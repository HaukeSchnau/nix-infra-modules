{
  lib,
  pkgs,
  self,
  system,
  ...
}:
let
  mkFleetSystem = import ../../../checks/mk-fleet-system.nix {
    inherit lib self system;
  };
  githubRunnerSystem = mkFleetSystem "github-ci-01" [
    {
      vps.services.githubRunner = {
        enable = true;
        url = "https://github.com/example-org/example-repo";
        tokenFile = "/run/secrets/github-runner-token";
        instanceName = "github-ci";
        runnerName = "github-ci";
        instanceCount = 2;
      };
    }
  ];
  giteaRunnerSystem = mkFleetSystem "gitea-ci-01" [
    {
      vps.services.giteaActionsRunner = {
        enable = true;
        url = "https://git.example.net";
        tokenFile = "/run/secrets/gitea-runner-token";
        instanceName = "gitea-ci";
        runnerName = "gitea-ci";
        resources = {
          memoryHigh = "3.5G";
          memoryMax = "5G";
          memorySwapMax = "2G";
        };
      };
    }
  ];
  giteaRunnerPoolsSystem = mkFleetSystem "gitea-pools-01" [
    {
      vps.services.giteaActionsRunner = {
        enable = true;
        url = "https://git.example.net";
        tokenFile = "/run/secrets/gitea-runner-token";
        instanceName = "gitea-ci";
        runnerName = "gitea-ci";
        pools = {
          quick = { };
          bulk = {
            count = 2;
            resources.memoryMax = "6G";
          };
        };
      };
    }
  ];
in
{
  github-runner-example =
    let
      runners = githubRunnerSystem.config.services.github-runners;
      healthUnits = githubRunnerSystem.config.vps.services.githubRunner.metadata.health.units;
    in
    pkgs.runCommand "github-runner-example" { } ''
      test '${runners."github-ci".url}' = 'https://github.com/example-org/example-repo'
      test '${runners."github-ci".name}' = 'github-ci'
      test '${runners."github-ci-2".name}' = 'github-ci-2'
      test '${toString runners."github-ci".tokenFile}' = '/run/secrets/github-runner-token'
      test '${runners."github-ci".serviceOverrides.MemoryMax}' = '5.5G'
      test '${
        if builtins.elem "github-runner-github-ci.service" healthUnits then "yes" else "no"
      }' = 'yes'
      test '${
        if builtins.elem "github-runner-github-ci-2.service" healthUnits then "yes" else "no"
      }' = 'yes'
      touch $out
    '';

  gitea-runner-example =
    let
      runner = giteaRunnerSystem.config.services.gitea-actions-runner.instances."gitea-ci";
      unit = giteaRunnerSystem.config.systemd.services."gitea-runner-gitea\\x2dci";
      healthUnits = giteaRunnerSystem.config.vps.services.giteaActionsRunner.metadata.health.units;
    in
    pkgs.runCommand "gitea-runner-example" { } ''
      test '${runner.url}' = 'https://git.example.net'
      test '${runner.name}' = 'gitea-ci'
      test '${toString runner.tokenFile}' = '/run/secrets/gitea-runner-token'
      test '${unit.environment.DOCKER_HOST}' = 'unix:///run/docker.sock'
      test '${runner.settings.runner.envs.CI_WORKSPACE_CACHE_ROOT}' = '/var/cache/gitea-ci-gitea-ci'
      test '${unit.serviceConfig.CacheDirectory}' = 'gitea-ci-gitea-ci'
      test '${builtins.concatStringsSep ":" unit.serviceConfig.ExecPaths}' = '/var/lib/gitea-runner:/var/cache/gitea-ci-gitea-ci'
      test '${unit.serviceConfig.MemoryHigh}' = '3.5G'
      test '${unit.serviceConfig.MemoryMax}' = '5G'
      test '${unit.serviceConfig.MemorySwapMax}' = '2G'
      test '${
        if builtins.elem "gitea-runner-gitea\\x2dci.service" healthUnits then "yes" else "no"
      }' = 'yes'
      touch $out
    '';

  gitea-runner-pools =
    let
      runners = giteaRunnerPoolsSystem.config.services.gitea-actions-runner.instances;
      bulkUnit =
        giteaRunnerPoolsSystem.config.systemd.services."gitea-runner-gitea\\x2dci\\x2dbulk\\x2d2";
      healthUnits = giteaRunnerPoolsSystem.config.vps.services.giteaActionsRunner.metadata.health.units;
    in
    pkgs.runCommand "gitea-runner-pools" { } ''
      test '${runners."gitea-ci-quick".name}' = 'gitea-ci-quick'
      test '${builtins.concatStringsSep ":" runners."gitea-ci-quick".labels}' = 'quick:host'
      test '${runners."gitea-ci-bulk-2".settings.runner.envs.CI_WORKSPACE_SLOT}' = 'bulk-2'
      test '${
        runners."gitea-ci-bulk-2".settings.runner.envs.CI_WORKSPACE_CACHE_ROOT
      }' = '/var/cache/gitea-ci-gitea-ci-bulk-2'
      test '${bulkUnit.serviceConfig.CacheDirectory}' = 'gitea-ci-gitea-ci-bulk-2'
      test '${bulkUnit.serviceConfig.MemoryHigh}' = '2.5G'
      test '${bulkUnit.serviceConfig.MemoryMax}' = '6G'
      test '${toString (builtins.length healthUnits)}' = '3'
      test '${builtins.concatStringsSep ":" giteaRunnerPoolsSystem.config.vps.services.giteaActionsRunner.instanceNames}' = 'gitea-ci-bulk-1:gitea-ci-bulk-2:gitea-ci-quick'
      test '${
        if builtins.elem "gitea-runner-gitea\\x2dci\\x2dquick.service" healthUnits then "yes" else "no"
      }' = 'yes'
      touch $out
    '';
}
