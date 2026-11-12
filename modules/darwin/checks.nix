# A Mac release host: a T3-like release, cache-delivered and deferred until idle, built as a
# complete nix-darwin system, and the release options nix-darwin refuses.
{
  lib,
  nix-darwin,
  pkgs,
  self,
}:
let
  descriptor = self.lib.projectDefinition {
    modules = [
      {
        project = {
          name = "demo";
          requirements.apiKey = {
            kind = "secret";
            required = false;
            realizations = [ "release" ];
          };
          parameters.homeDirectory.required = false;
          release = {
            preDeployTasks.wait-for-idle = {
              action = "idle";
              failureMode = "defer";
              timeoutSec = 30;
            };
            health = {
              paths = [ "/healthz" ];
              startupTimeoutSec = 1800;
            };
          };
        };
      }
    ];
  };
  release = {
    delivery.cacheStore = "https://cache.example.net";
    parameters.homeDirectory = "/Users/demo";
    secrets.apiKey = "/etc/demo/api-key";
    environment.DEMO_MODE = "release";
    environmentFiles = [ "-/etc/demo/environment" ];
    runtime = {
      user = "demo";
      workingDirectory = "/Users/demo";
    };
    listen = {
      host = "100.64.0.10";
      port = 3773;
    };
  };
  macWith =
    extraRelease:
    nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        self.darwinModules.projects
        {
          system.stateVersion = 6;
          system.primaryUser = "demo";
          users.users.demo.home = "/Users/demo";
          networking.hostName = "mac-01";
          vps.appDeployments.webhook.tokenSecretName = "/etc/app-deployments/webhook-token";
          projects.demo = {
            source = {
              outPath = pkgs.emptyDirectory;
              lib.project = descriptor;
            };
            release = lib.recursiveUpdate release extraRelease;
          };
        }
      ];
    };
  mac = macWith { };
  inherit (mac) config;
  update = config.launchd.daemons.app-deployment-demo-update.command;
  agent = config.environment.userLaunchAgents."org.nixos.app-deployment-demo.plist".source;
  webhook = config.environment.launchDaemons."org.nixos.app-deployments-webhook.plist".source;
  updater = config.environment.launchDaemons."org.nixos.app-deployment-demo-update.plist".source;
  webhookApps =
    config.launchd.daemons.app-deployments-webhook.serviceConfig.EnvironmentVariables.APP_DEPLOYMENTS_APPS_FILE;
  rejected =
    extraRelease:
    !(builtins.tryEval (builtins.deepSeq (macWith extraRelease).system.drvPath true)).success;
in
{
  projects-darwin =
    pkgs.runCommand "projects-darwin"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.python3
        ];
        toplevel = mac.system;
      }
      ''
        update=${update}
        update_job="$(jq -r '.demo.updateCommand[0]' ${webhookApps})"
        jq -e --arg job "$update_job" '
          .demo.updateCommand == [$job, "run"] and .demo.updateRunningCommand == [$job, "running"]
        ' ${webhookApps} >/dev/null
        for script in "$update" "$update_job" ${config.launchd.user.agents.app-deployment-demo.command}; do
          ${pkgs.bash}/bin/bash -n "$script"
        done
        grep -Fq 'job=system/org.nixos.app-deployment-demo-update' "$update_job"
        grep -Fq '/bin/launchctl kickstart "$job"' "$update_job"
        ! grep -Fq systemctl "$update"
        ! grep -Fq systemd-run "$update"
        grep -Fq 'nix-store --realise "$requested_store_path"' "$update"
        grep -Fq 'service_target="$service_domain/org.nixos.app-deployment-demo"' "$update"
        grep -Fq 'service_plist=~demo/Library/LaunchAgents/org.nixos.app-deployment-demo.plist' "$update"
        grep -Fq '/bin/launchctl kickstart -k "$service_target"' "$update"
        grep -Fq 'if ! run_pre_deploy_task "$task" "$timeout"; then' "$update"
        grep -Fq 'timeout --kill-after=30 "$2s"' "$update"
        grep -Fq '.preDeployTasks[$task].failureMode' "$update"
        grep -Fq 'http://100.64.0.10:3773$path' "$update"
        grep -Fq '/nix/var/nix/gcroots/app-deployments/demo' "$update"

        python3 - ${agent} ${webhook} ${updater} <<'EOF'
        import plistlib, sys
        agent, webhook, updater = (plistlib.load(open(path, "rb")) for path in sys.argv[1:])
        assert agent["Label"] == "org.nixos.app-deployment-demo", agent
        assert agent["KeepAlive"] and agent["RunAtLoad"], agent
        assert agent["EnvironmentVariables"] == {"HOME": "/Users/demo", "DEMO_MODE": "release"}, agent
        assert agent["WorkingDirectory"] == "/Users/demo", agent
        assert webhook["EnvironmentVariables"]["APP_DEPLOYMENTS_SYSTEM"] == "aarch64-darwin", webhook
        assert webhook["EnvironmentVariables"]["APP_DEPLOYMENTS_TOKEN_FILE"] == "/etc/app-deployments/webhook-token", webhook
        assert webhook["EnvironmentVariables"]["APP_DEPLOYMENTS_WEBHOOK_HOST"] == "127.0.0.1", webhook
        assert webhook["EnvironmentVariables"]["PYTHONDONTWRITEBYTECODE"] == "1", webhook
        assert updater["Label"] == "org.nixos.app-deployment-demo-update", updater
        assert updater["StartInterval"] == 600 and updater["ThrottleInterval"] == 1, updater
        EOF

        jq -e '
          .demo.deliveryMode == "cache"
          and .demo.placement == null
          and .demo.requestedReleaseFile == "/var/lib/app-deployments/demo/requested-release.json"
        ' ${webhookApps} >/dev/null
        jq -e '
          .endpoints.web.listen == {host: "100.64.0.10", port: 3773}
          and .instanceId == "demo:release:mac-01:default"
          and .paths.runtime == "/var/lib/app-deployments/demo/runtime"
        ' "$(grep -o '/nix/store/[^ ]*-project-release-runtime-base-demo.json' "$update" | head -n 1)" >/dev/null
        # The service's HOME, which its tasks and activation share.
        grep -Fq "export HOME=/Users/demo" "$(grep -o '/nix/store/[^ ]*-app-deployment-demo-as-release-user' "$update" | head -n 1)"
        grep -Fq '/var/lib/app-deployments/demo/runtime/secrets/apiKey' <<< ${lib.escapeShellArg config.system.activationScripts.postActivation.text}
        ! grep -Fq '/runtime/secrets/apiKey' <<< ${lib.escapeShellArg config.system.activationScripts.extraActivation.text}
        # A switch that changes the bindings queues the active release again, after the secrets.
        post_activation=${lib.escapeShellArg config.system.activationScripts.postActivation.text}
        grep -Fq 'activating the active release again' <<< "$post_activation"
        grep -Fq '/bin/launchctl kickstart system/org.nixos.app-deployment-demo-update' <<< "$post_activation"
        test "$(grep -nF 'runtime/secrets/apiKey' <<< "$post_activation" | tail -n 1 | cut -d: -f1)" \
          -lt "$(grep -nF 'artifact-condition' <<< "$post_activation" | cut -d: -f1)"

        test ${
          lib.boolToString (rejected {
            runtime.user = "other";
          })
        } = true
        test ${
          lib.boolToString (rejected {
            delivery.cacheStore = null;
          })
        } = true
        touch $out
      '';
}
