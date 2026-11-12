# Project Releases on a Mac: the nix-darwin side of a release host. CI promotes releases to it
# through the same webhook as to NixOS hosts, and the same update pipeline
# (lib/release-host/scripts.nix) activates them; launchd takes systemd's place. The options mirror
# the NixOS projects module's `projects.<name>.release` and `vps.appDeployments.webhook`, as far as
# they apply here.
#
# A Mac runs a narrower release: cache delivery, a trusted runtime as the primary user, and the
# service as a launchd agent in that user's GUI session. The host routes traffic to its listen
# address itself; there are no placements, ingress, OCI auxiliaries or maintenance jobs.
# See docs/modules/projects.md.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  projectDescriptor = import ../../lib/project-descriptor.nix { inherit lib; };
  hostConfig = config;
  webhookCfg = config.vps.appDeployments.webhook;
  hasSops = options ? sops;
  enabledProjects = lib.filterAttrs (_: project: project.enable) config.projects;
  launchctl = "/bin/launchctl";
  sudo = "/usr/bin/sudo";
  logDir = "/Library/Logs/app-deployments";
  # Where a user's home is, for a release's default HOME.
  userHome =
    user:
    let
      home = config.users.users.${user}.home or null;
    in
    if home == null then "/Users/${user}" else toString home;

  releaseType =
    name:
    types.submodule (
      { config, ... }:
      {
        options = {
          instance = mkOption {
            type = types.strMatching "^[a-z0-9][a-z0-9-]{0,62}$";
            default = "default";
            description = "Identity of this host's release of the project, in its instance id.";
          };
          # A Mac realizes the CI-built output only, as NixOS does with delivery.mode = "cache".
          delivery = {
            cacheStore = mkOption {
              type = types.nullOr types.str;
              default = hostConfig.vps.services.projects.releaseCacheStore;
              defaultText = lib.literalExpression "config.vps.services.projects.releaseCacheStore";
              description = "Binary cache holding CI-promoted outputs. The host's Nix must trust its key.";
            };
          };
          exposeRevision = mkOption {
            type = types.bool;
            default = false;
            description = "Expose the promoted revision through `project-context revision`.";
          };
          parameters = mkOption {
            type = types.attrsOf types.unspecified;
            default = { };
            description = "Values for the repository's parameters.";
          };
          secrets = mkOption {
            type = types.attrsOf (types.strMatching "^/.*");
            default = { };
            description = ''
              Files bound to the repository's secret requirements, by requirement name. Activation
              copies them into the release's secrets directory, readable by the release user only.
              On NixOS a grant's placement binds these instead.
            '';
          };
          environment = mkOption {
            type = types.attrsOf types.unspecified;
            default = { };
            description = "Environment variables of the service.";
          };
          environmentFiles = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              KEY=VALUE files the service sources before it starts; a leading `-` makes one optional,
              as in systemd's EnvironmentFile.
            '';
          };
          path = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = "Packages added to the service's PATH.";
          };
          # A Mac has no sandbox for releases: they run as their user, as `trusted` ones on NixOS.
          runtime = {
            user = mkOption {
              type = types.nullOr types.str;
              default = hostConfig.system.primaryUser;
              defaultText = lib.literalExpression "config.system.primaryUser";
              description = "User the release runs as: the primary user, in whose GUI session it runs.";
            };
            group = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Group of the release's state; the user's primary group when null.";
            };
            home = mkOption {
              type = types.nullOr (types.strMatching "^/.*");
              default = if config.runtime.user == null then null else userHome config.runtime.user;
              defaultText = lib.literalExpression "the user's home";
              description = "HOME of the service, its pre-deploy tasks and its activation.";
            };
            workingDirectory = mkOption {
              type = types.nullOr (types.strMatching "^/.*");
              default = null;
              description = "Working directory of release actions; the deployment state directory when null.";
            };
          };
          listen = {
            host = mkOption {
              type = types.str;
              default = "127.0.0.1";
              example = "100.64.0.10";
              description = "Address the service's endpoint listens on, such as the host's tailnet address.";
            };
            port = mkOption {
              type = types.port;
              description = "Port the service's endpoint listens on.";
            };
          };
          autoUpdate.intervalSec = mkOption {
            type = types.ints.positive;
            default = 600;
            description = "Interval between retries of a queued release, such as one deferred until idle.";
          };
          label = mkOption {
            type = types.str;
            default = "${hostConfig.launchd.labelPrefix}.app-deployment-${name}";
            defaultText = lib.literalExpression ''"''${config.launchd.labelPrefix}.app-deployment-<name>"'';
            description = "launchd label of the service's agent.";
          };
        };
      }
    );

  projectType = types.submodule (
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
        };
        source = mkOption {
          type = types.path;
          description = "The pinned repository, usually a flake input, whose `lib.project` contract this host runs.";
        };
        release = mkOption {
          type = releaseType name;
          description = "Release policy.";
        };
      };
    }
  );

  descriptors = lib.mapAttrs (
    name: project:
    projectDescriptor.normalize {
      descriptor =
        project.source.lib.project
          or (throw "projects.${name}: the source flake has no lib.project contract");
      expectedProject = name;
    }
  ) enabledProjects;

  # The release as the shared pipeline reads it, the way NixOS's projects module projects one.
  releaseApp =
    name: project:
    let
      policy = project.release;
      probeHost =
        if
          builtins.elem policy.listen.host [
            "0.0.0.0"
            "::"
          ]
        then
          "127.0.0.1"
        else
          policy.listen.host;
      app = projectDescriptor.releaseApp {
        descriptor = descriptors.${name};
        policy = {
          project = name;
          instanceId = "${name}:release:${config.networking.hostName}:${policy.instance}";
          # Cache delivery never reads the source.
          source.url = "";
          port = policy.listen.port;
          delivery = {
            mode = "cache";
            inherit (policy.delivery) cacheStore;
          };
          runtime = policy.runtime // {
            isolation = "trusted";
          };
          inherit (policy)
            environment
            environmentFiles
            exposeRevision
            parameters
            path
            secrets
            ;
        };
      };
    in
    app
    // {
      inherit name;
      host = policy.listen.host;
      health = app.health // {
        host = probeHost;
      };
    };

  hosts = lib.mapAttrs (
    name: project:
    let
      policy = project.release;
      user = policy.runtime.user;
      group =
        if policy.runtime.group == null then
          ''"$(id -gn ${lib.escapeShellArg user})"''
        else
          lib.escapeShellArg policy.runtime.group;
      inherit (policy) label;
      plist = "~${user}/Library/LaunchAgents/${label}.plist";
      release = import ../../lib/release-host/scripts.nix {
        inherit lib pkgs;
        app = releaseApp name project;
        supervisor = launchdSupervisor;
      };
      # Runs a command as the release user, as systemd runs release actions on NixOS, with the
      # service's HOME.
      asReleaseUser = pkgs.writeShellScript "app-deployment-${name}-as-release-user" ''
        umask 0027
        export HOME=${lib.escapeShellArg release.homeDir}
        cd ${lib.escapeShellArg release.workingDirectory} || exit
        exec "$@"
      '';
      # The update script's launchd side. The service is an agent in the user's GUI session, so the
      # update needs that session: without one, bootstrap fails and so does the update.
      launchdSupervisor = {
        path = [ ];
        definitions = ''
          service_domain="gui/$(id -u ${lib.escapeShellArg user})"
          service_target="$service_domain/${label}"
          service_plist=${plist}
          service_loaded() {
            ${launchctl} print "$service_target" >/dev/null 2>&1
          }
          service_active() {
            local state
            state="$(${launchctl} print "$service_target" 2>/dev/null)" || return 1
            grep -Eq '^[[:space:]]*state = running$' <<<"$state"
          }
          # Loading the agent starts it (RunAtLoad).
          start_service() {
            if service_loaded; then
              ${launchctl} kickstart "$service_target"
            else
              ${launchctl} bootstrap "$service_domain" "$service_plist"
            fi
          }
          restart_service() {
            if service_loaded; then
              ${launchctl} kickstart -k "$service_target"
            else
              ${launchctl} bootstrap "$service_domain" "$service_plist"
            fi
          }
          as_release_user() {
            ${sudo} -u ${lib.escapeShellArg user} -- ${asReleaseUser} "$@"
          }
          run_pre_deploy_task() {
            timeout --kill-after=30 "$2s" \
              ${sudo} -u ${lib.escapeShellArg user} -- ${asReleaseUser} \
              ${release.projectPreDeployTaskScript} "$1"
          }
        '';
        serviceActive = "service_active";
        stopService = "if service_loaded; then ${launchctl} bootout \"$service_target\"; fi";
        startService = "start_service";
        restartService = "restart_service";
        activate = "as_release_user ${release.activationScript}";
        runPreDeployTask = "run_pre_deploy_task";
      };
      service = pkgs.writeShellScript "app-deployment-${name}-service" ''
        set -euo pipefail
        export PATH=${
          lib.escapeShellArg (
            lib.makeBinPath (
              policy.path
              ++ [
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnugrep
                pkgs.gnused
              ]
            )
          )
        }:/usr/bin:/bin:/usr/sbin:/sbin
        for file in ${lib.escapeShellArgs policy.environmentFiles}; do
          if [[ "$file" == -* ]]; then
            file="''${file#-}"
            [ -r "$file" ] || continue
          fi
          set -a
          # shellcheck disable=SC1090
          . "$file"
          set +a
        done
        exec ${release.startScript}
      '';
      secretsDir = "${release.runtimeDir}/secrets";
      # What systemd-tmpfiles and the release-plan unit do on NixOS.
      activation = ''
        echo "setting up app deployment ${name}..." >&2
        ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g wheel /var/lib/app-deployments ${lib.escapeShellArg release.stateDir}
        ${pkgs.coreutils}/bin/install -d -m 0750 -o ${lib.escapeShellArg user} -g ${group} ${
          lib.escapeShellArgs (
            [ release.runtimeDir ] ++ map (dir: "${release.runtimeDir}/${dir}") release.projectStateDirectories
          )
        }
        ${pkgs.coreutils}/bin/install -d -m 0700 -o ${lib.escapeShellArg user} -g ${group} ${lib.escapeShellArg secretsDir}
        ${pkgs.coreutils}/bin/install -d -m 0755 -o ${lib.escapeShellArg user} -g ${group} ${lib.escapeShellArg "${logDir}/${name}"}
        ${release.projectReleasePlanBootstrapScript} || echo "app-deployment/${name}: the active release plan is stale" >&2
      '';
      # After the secrets are in place: what LoadCredential, the release-plan unit and a placement's
      # redeploy do on NixOS. A switch that changes the host's bindings, such as a secret, parameter
      # or listen address, queues the active release again; the update binds it anew and restarts
      # the service once its pre-deploy tasks allow. A queued request, such as one whose update a
      # reload of the update daemon killed, is retried at once. Otherwise a changed secret only
      # restarts the service.
      releaseActivation = ''
        secrets_changed=
        if [ -n "$(${pkgs.findutils}/bin/find ${lib.escapeShellArg secretsDir} -mindepth 1 -maxdepth 1 ${
          lib.concatMapStringsSep " " (secret: "! -name ${lib.escapeShellArg secret}") (
            builtins.attrNames release.projectSecrets
          )
        } -print -delete)" ]; then
          secrets_changed=1
        fi
        ${lib.concatStrings (
          lib.mapAttrsToList (secret: source: ''
            if ! ${pkgs.diffutils}/bin/cmp -s ${lib.escapeShellArg source} ${lib.escapeShellArg "${secretsDir}/${secret}"}; then
              if ${pkgs.coreutils}/bin/install -m 0400 -o ${lib.escapeShellArg user} -g ${group} ${lib.escapeShellArg source} ${lib.escapeShellArg "${secretsDir}/${secret}"}; then
                secrets_changed=1
              else
                echo "app-deployment/${name}: cannot read secret ${secret} from ${source}" >&2
              fi
            fi
          '') release.projectSecrets
        )}
        state_dir=${lib.escapeShellArg release.stateDir}
        queued=
        if [ -s "$state_dir/requested-release.json" ]; then
          queued=1
        elif [ -L "$state_dir/current" ] && [ -s "$state_dir/current-revision" ] \
          && ! ${release.projectArtifactConditionScript}; then
          echo "app-deployment/${name}: host bindings changed; activating the active release again" >&2
          ${pkgs.jq}/bin/jq -n \
            --arg revision "$(${pkgs.coreutils}/bin/head -n 1 "$state_dir/current-revision")" \
            --arg storePath "$(${pkgs.coreutils}/bin/readlink "$state_dir/current")" \
            '{schemaVersion: 1, revision: $revision, storePath: $storePath, source: "activation"}' \
            > "$state_dir/requested-release.json.next"
          ${pkgs.coreutils}/bin/mv -f "$state_dir/requested-release.json.next" "$state_dir/requested-release.json"
          queued=1
        fi
        if [ -n "$queued" ]; then
          ${launchctl} kickstart system/${updateLabel} || true
        elif [ -n "$secrets_changed" ] && ${launchctl} print "gui/$(id -u ${lib.escapeShellArg user})/${label}" >/dev/null 2>&1; then
          echo "app-deployment/${name}: restarting onto changed secrets" >&2
          ${launchctl} kickstart -k "gui/$(id -u ${lib.escapeShellArg user})/${label}" || true
        fi
      '';
      # The update runs as its own daemon, so that a reload of the webhook doesn't kill it. The
      # webhook asks launchd, as it asks systemd on NixOS: `running` while the daemon is spawning or
      # running, and `run` starts it and waits for the run, whose exit code launchd records.
      updateLabel = "${config.launchd.labelPrefix}.app-deployment-${name}-update";
      updateJob = pkgs.writeShellScript "app-deployment-${name}-update-job" ''
        job=system/${updateLabel}
        # A top-level field of the job, such as `state`, `runs` or `last exit code`.
        field() {
          ${launchctl} print "$job" 2>/dev/null \
            | /usr/bin/awk -F ' = ' -v key="$1" '$1 == "\t" key { print $2; exit }'
        }
        state="$(field state)"
        case "$1" in
          running)
            [ -n "$state" ] && [ "$state" != "not running" ]
            ;;
          run)
            runs="$(field runs)"
            wanted=$((''${runs:-0} + 1))
            # A run that is already under way read the request too.
            if [ -n "$state" ] && [ "$state" != "not running" ]; then
              wanted=''${runs:-0}
            fi
            # Waits out launchd's throttle before it returns.
            ${launchctl} kickstart "$job"
            waited=0
            while true; do
              state="$(field state)"
              runs="$(field runs)"
              if [ "$state" = "not running" ] && [ "''${runs:-0}" -ge "$wanted" ]; then
                code="$(field "last exit code")"
                case "$code" in
                  "" | *[!0-9]*)
                    echo "app-deployment/${name}: the update ended by $(field "last terminating signal")" >&2
                    exit 1
                    ;;
                esac
                exit "$code"
              fi
              # A reload resets the counter, and a job that doesn't spawn never raises it.
              if [ "$state" = "not running" ] || [ -z "$state" ]; then
                waited=$((waited + 1))
                if [ "$waited" -ge 30 ]; then
                  echo "app-deployment/${name}: the update daemon didn't run" >&2
                  exit 1
                fi
              else
                waited=0
              fi
              sleep 1
            done
            ;;
          *)
            echo "usage: $0 running|run" >&2
            exit 64
            ;;
        esac
      '';
    in
    {
      inherit
        activation
        label
        release
        releaseActivation
        updateJob
        updateLabel
        service
        user
        ;
    }
  ) enabledProjects;

  webhookModule = pkgs.runCommand "app-deployments-webhook" { } ''
    mkdir -p $out
    cp ${../../lib/release-host/webhook.py} $out/webhook.py
    cp ${../nixos/deploy/placements.py} $out/placements.py
  '';
  webhookApps = lib.mapAttrs (name: host: {
    bindingPolicyFile = "${host.release.projectBindingPolicy}";
    compatibilityFile = "${host.release.stateDir}/compatibility.json";
    deliveryMode = "cache";
    requestedReleaseFile = "${host.release.stateDir}/requested-release.json";
    requestedRevisionFile = "${host.release.stateDir}/requested-revision";
    updateUnit = "";
    updateCommand = [
      "${host.updateJob}"
      "run"
    ];
    updateRunningCommand = [
      "${host.updateJob}"
      "running"
    ];
    placement = null;
  }) hosts;
  tokenFile =
    if hasSops then
      config.sops.secrets.${webhookCfg.tokenSecretName}.path
    else
      webhookCfg.tokenSecretName;
in
{
  options = {
    projects = mkOption {
      type = types.attrsOf projectType;
      default = { };
      description = "Projects whose releases this Mac runs.";
    };

    vps.services.projects.releaseCacheStore = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Default binary cache for cache-delivered releases.";
    };

    vps.appDeployments.webhook = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the deployment webhook CI promotes releases through.";
      };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        example = "100.64.0.10";
        description = "Address the deployment webhook listens on, such as the host's tailnet address. nix-darwin opens no firewall, so this is all that keeps it off other networks.";
      };
      port = mkOption {
        type = types.port;
        default = 18100;
        description = "HTTP port of the deployment webhook.";
      };
      tokenSecretName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "SOPS secret with the webhook's bearer token, or without sops-nix the token file's path.";
      };
    };
  };

  config = lib.mkIf (enabledProjects != { }) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = config.networking.hostName != null;
            message = "projects: a release's instance id needs networking.hostName.";
          }
          {
            assertion = webhookCfg.enable -> webhookCfg.tokenSecretName != null;
            message = "vps.appDeployments.webhook.tokenSecretName must be set when the webhook is enabled.";
          }
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (
            name: project:
            let
              policy = project.release;
              inherit (descriptors.${name}) release;
              otherRequirements = builtins.attrNames (
                lib.filterAttrs (_: requirement: requirement.kind != "secret") (
                  projectDescriptor.forRealization "release" descriptors.${name}.requirements
                )
              );
            in
            [
              {
                assertion = builtins.match "^[a-z0-9][a-z0-9-]{0,62}$" name != null;
                message = "projects.${name}: Project names must be lowercase kebab-case and at most 63 characters.";
              }
              {
                assertion = release != null && release.backend == "service";
                message = "projects.${name}: nix-darwin runs service releases only.";
              }
              {
                assertion = policy.delivery.cacheStore != null;
                message = "projects.${name}.release.delivery.cacheStore: nix-darwin realizes CI-built releases; set the cache they come from.";
              }
              {
                assertion = policy.runtime.user != null && policy.runtime.user == config.system.primaryUser;
                message = "projects.${name}.release.runtime.user: the release runs as a launchd agent of system.primaryUser; set it to that user.";
              }
              {
                assertion = release == null || release.ociAuxiliaries == { };
                message = "projects.${name}: nix-darwin runs no OCI auxiliaries.";
              }
              {
                assertion =
                  release == null || lib.all (job: !(job ? schedule)) (builtins.attrValues release.maintenanceJobs);
                message = "projects.${name}: nix-darwin schedules no maintenance jobs.";
              }
              {
                assertion = otherRequirements == [ ];
                message = "projects.${name}: nix-darwin binds secret requirements only, not ${lib.concatStringsSep ", " otherRequirements}.";
              }
            ]
          ) enabledProjects
        );

        launchd.user.agents = lib.mapAttrs' (
          name: host:
          lib.nameValuePair "app-deployment-${name}" {
            command = "${host.service}";
            serviceConfig = {
              Label = host.label;
              EnvironmentVariables = lib.mapAttrs (_: toString) (
                {
                  HOME = host.release.homeDir;
                }
                // host.release.cfg.environment
              );
              WorkingDirectory = host.release.workingDirectory;
              RunAtLoad = true;
              KeepAlive = true;
              ThrottleInterval = 15;
              ExitTimeOut = 30;
              ProcessType = "Interactive";
              # 0027
              Umask = 23;
              StandardOutPath = "${logDir}/${name}/service.log";
              StandardErrorPath = "${logDir}/${name}/service.log";
            };
          }
        ) hosts;

        launchd.daemons =
          lib.mapAttrs' (
            name: host:
            lib.nameValuePair "app-deployment-${name}-update" {
              command = "${host.release.updateScript}";
              serviceConfig = {
                Label = host.updateLabel;
                # A request right after a periodic run starts at once, not 10 s later.
                ThrottleInterval = 1;
                StartInterval = enabledProjects.${name}.release.autoUpdate.intervalSec;
                StandardOutPath = "${logDir}/${name}-update.log";
                StandardErrorPath = "${logDir}/${name}-update.log";
              };
            }
          ) hosts
          // lib.optionalAttrs webhookCfg.enable {
            app-deployments-webhook = {
              command = "${pkgs.python3}/bin/python3 ${webhookModule}/webhook.py";
              serviceConfig = {
                RunAtLoad = true;
                KeepAlive = true;
                ThrottleInterval = 5;
                EnvironmentVariables = {
                  APP_DEPLOYMENTS_APPS_FILE = "${pkgs.writeText "app-deployments-webhook-apps.json" (
                    builtins.toJSON webhookApps
                  )}";
                  APP_DEPLOYMENTS_PLANNER = lib.getExe (
                    (import ../../lib/project-runtime.nix { inherit lib; }).package pkgs
                  );
                  APP_DEPLOYMENTS_SYSTEM = pkgs.stdenv.hostPlatform.system;
                  APP_DEPLOYMENTS_TOKEN_FILE = tokenFile;
                  APP_DEPLOYMENTS_WEBHOOK_HOST = webhookCfg.host;
                  APP_DEPLOYMENTS_WEBHOOK_PORT = toString webhookCfg.port;
                };
                StandardOutPath = "${logDir}/webhook.log";
                StandardErrorPath = "${logDir}/webhook.log";
              };
            };
          };

        # Before launchd loads the agents, so they start on current plans and log to existing
        # directories.
        system.activationScripts.extraActivation.text = ''
          ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g wheel ${logDir}
          ${lib.concatMapStrings (host: host.activation) (builtins.attrValues hosts)}
        '';
        # After sops-nix, which decrypts its secrets with mkAfter in postActivation.
        system.activationScripts.postActivation.text = lib.mkOrder 2000 (
          lib.concatMapStrings (host: host.releaseActivation) (builtins.attrValues hosts)
        );
      }
      (lib.optionalAttrs hasSops {
        sops.secrets = lib.mkIf webhookCfg.enable {
          ${webhookCfg.tokenSecretName} = {
            owner = "root";
            mode = "0400";
          };
        };
      })
    ]
  );
}
