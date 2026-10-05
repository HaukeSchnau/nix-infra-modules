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
}
