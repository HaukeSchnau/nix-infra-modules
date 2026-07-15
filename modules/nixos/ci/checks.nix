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
      test '${unit.serviceConfig.MemoryMax}' = '4G'
      test '${
        if builtins.elem "gitea-runner-gitea\\x2dci.service" healthUnits then "yes" else "no"
      }' = 'yes'
      touch $out
    '';
}
