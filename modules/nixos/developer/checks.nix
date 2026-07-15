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
  gitMirrorsSystem = mkFleetSystem "git-mirror-01" [
    {
      vps.services.gitMirrors = {
        enable = true;
        mirrorAll = false;
        gitea = {
          baseUrl = "https://git.example.net";
          username = "mirror";
          tokenFile = "/run/secrets/gitea-token";
        };
        github = {
          owner = "example-org";
          tokenFile = "/run/secrets/github-token";
        };
        repositories.demo = {
          gitea = "example/demo";
          githubName = "demo-mirror";
          description = "Demo mirror";
        };
      };
    }
  ];
  cfg = gitMirrorsSystem.config;
  service = cfg.systemd.services.git-mirrors-sync;
  timer = cfg.systemd.timers.git-mirrors-sync;
  script = builtins.elemAt (lib.splitString " " service.serviceConfig.ExecStart) 1;
  healthUnits = cfg.vps.services.gitMirrors.metadata.health.units;
in
{
  git-mirrors-example =
    pkgs.runCommand "git-mirrors-example"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.python3
        ];
      }
      ''
        test '${service.environment.GIT_MIRRORS_GITEA_TOKEN_FILE}' = '/run/secrets/gitea-token'
        test '${service.environment.GIT_MIRRORS_GITHUB_TOKEN_FILE}' = '/run/secrets/github-token'
        test '${service.serviceConfig.User}' = 'git-mirrors'
        test '${timer.timerConfig.OnUnitActiveSec}' = '15min'
        test '${if builtins.elem "git-mirrors-sync.timer" healthUnits then "yes" else "no"}' = 'yes'
        jq -e '.userAgent == "nix-infra-modules-git-mirrors"' ${service.environment.GIT_MIRRORS_CONFIG}
        jq -e '.github.baseUrl == "https://github.com"' ${service.environment.GIT_MIRRORS_CONFIG}
        python3 -m py_compile ${script}
        grep -q '"User-Agent": self.user_agent' ${script}
        ! grep -q '"User-Agent": cfg\\["userAgent"\\]' ${script}
        touch $out
      '';
}
