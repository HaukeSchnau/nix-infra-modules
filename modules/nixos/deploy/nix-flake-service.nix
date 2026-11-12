app:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  internal = app.__appDeploymentsInternal or false;
  declaredApp = builtins.removeAttrs app [
    "name"
    "__appDeploymentsInternal"
  ];
  hasSops = options ? sops;
  release = import ../../../lib/release-host/scripts.nix {
    inherit app lib pkgs;
    supervisor = systemdSupervisor;
    inherit gitTokenSetup;
  };
  inherit (release)
    cfg
    deployedProjectReleasePlan
    deployedProjectRuntimeManifest
    generatedUserName
    groupName
    healthArgs
    homeDir
    isProject
    isService
    name
    needsRuntimeUser
    placementDir
    projectAuxiliaries
    projectAuxiliaryPorts
    projectBindingPolicy
    projectJobs
    projectMemory
    projectRelease
    projectRuntimeBaseManifest
    projectSecretBindings
    projectSecrets
    projectStateDirectories
    runsProjectActivation
    runtimeDir
    serviceHealthScript
    stateDir
    userName
    workingDirectory
    ;
  inherit (release)
    activationScript
    projectArtifactConditionScript
    projectReleasePlanBootstrapScript
    projectServiceConditionScript
    startScript
    updateScript
    ;
  # The update script's systemd side: pre-deploy tasks run as transient units with the task's
  # credentials and, for isolated releases, the service's sandbox.
  systemdSupervisor = {
    path = [ pkgs.systemd ];
    serviceActive = "systemctl is-active --quiet ${lib.escapeShellArg "${unitName}.service"}";
    stopService = "systemctl stop ${lib.escapeShellArg "${unitName}.service"}";
    startService = "systemctl start ${lib.escapeShellArg "${unitName}.service"}";
    restartService = "systemctl restart ${lib.escapeShellArg "${unitName}.service"}";
    activate = "systemctl start ${lib.escapeShellArg "${activationUnitName}.service"}";
    runPreDeployTask = "run_pre_deploy_task";
    definitions = lib.optionalString (isProject && isService) ''
      run_pre_deploy_task() {
        local task="$1" timeout="$2" secret path
        local -a credential_args systemd_run_args
        credential_args=()
        while IFS=$'\t' read -r secret path; do
          credential_args+=("--property=LoadCredential=$secret:$path")
        done < <(
          jq -er --arg task "$task" \
            --slurpfile bindings "$secret_bindings" \
            '.preDeployTasks[$task].secrets[] as $secret | select($bindings[0] | has($secret)) | [$secret, $bindings[0][$secret]] | @tsv' \
            "$candidate_release_plan"
        )
        systemd_run_args=(
          --quiet
          --wait
          --collect
          --pipe
          --unit="${unitName}-pre-deploy-$task"
          --service-type=oneshot
          --uid=${lib.escapeShellArg userName}
          --gid=${lib.escapeShellArg groupName}
          --working-directory=${lib.escapeShellArg workingDirectory}
          --property="TimeoutStartSec=''${timeout}s"
          ${lib.optionalString (cfg.runtime.isolation == "isolated") ''
            --property=CapabilityBoundingSet=
            --property=LockPersonality=true
            --property=NoNewPrivileges=true
            --property=PrivateDevices=true
            --property=PrivateTmp=true
            --property=ProtectClock=true
            --property=ProtectControlGroups=true
            --property=ProtectHome=${if cfg.runtime.protectHome then "true" else "false"}
            --property=ProtectKernelLogs=true
            --property=ProtectKernelModules=true
            --property=ProtectKernelTunables=true
            --property=ProtectSystem=strict
            --property=ReadWritePaths=${
              lib.escapeShellArg (lib.concatStringsSep " " ([ runtimeDir ] ++ cfg.runtime.readWritePaths))
            }
            --property=RemoveIPC=true
            --property="RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"
            --property=RestrictRealtime=true
            --property=RestrictSUIDSGID=true
            --property=SystemCallArchitectures=native
          ''}
          --property=TimeoutStopSec=30s
          --property=UMask=0027
          ${lib.optionalString (
            projectMemory.high != null
          ) "--property=MemoryHigh=${lib.escapeShellArg projectMemory.high}"}
          ${lib.optionalString (
            projectMemory.max != null
          ) "--property=MemoryMax=${lib.escapeShellArg projectMemory.max}"}
          ${lib.optionalString (
            projectMemory.swapMax != null
          ) "--property=MemorySwapMax=${lib.escapeShellArg projectMemory.swapMax}"}
        )
        systemd_run_args+=("''${credential_args[@]}")
        systemd-run "''${systemd_run_args[@]}" \
          ${release.projectPreDeployTaskScript} "$task"
      }
    '';
  };
  unitName = "app-deployment-${name}";
  updateUnitName = "${unitName}-update";
  activationUnitName = "${unitName}-activate";
  ociBackend = config.virtualisation.oci-containers.backend;
  projectContainerName = auxiliaryName: "project-${name}-${auxiliaryName}";
  projectContainerUnits = map (
    auxiliaryName: "${ociBackend}-${projectContainerName auxiliaryName}.service"
  ) (builtins.attrNames projectAuxiliaries);
  externalAfterUnits = lib.unique (
    cfg.unitDependencies.after ++ cfg.unitDependencies.wants ++ cfg.unitDependencies.requires
  );
  externalWantedUnits = lib.unique cfg.unitDependencies.wants;
  externalRequiredUnits = lib.unique cfg.unitDependencies.requires;
  granted = isProject && isService && cfg.project.grant != null;
  placementRegistration = {
    inherit (cfg.project) grant;
    inherit (cfg) port;
    inherit stateDir;
    action = projectRelease.action;
    policy = "${projectBindingPolicy}";
    secretBindings = "${projectSecretBindings}";
    runtimeBase = "${projectRuntimeBaseManifest}";
    site = "/etc/app-deployments/sites/${name}.caddy";
    # Units that load the release's credentials.
    credentialUnits = [
      "${unitName}.service"
    ]
    ++ lib.optional runsProjectActivation "${activationUnitName}.service"
    ++ map (job: "${unitName}-job-${job}.service") (builtins.attrNames projectJobs);
    # The job timers a placement may reschedule, with what an interval needs from the host.
    jobs = lib.mapAttrs (jobName: policy: {
      timer = "${unitName}-job-${jobName}.timer";
      inherit (policy) onBootSec;
      cadence = if policy.cadence == null then "spaced" else policy.cadence;
    }) projectJobs;
  };

  caddyQuote = value: ''"${lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "" ] value}"'';
  projectIngressConfig =
    if !isProject then
      ""
    else
      let
        ingress = projectRelease.ingress;
        redirects = map (
          redirect: "redir ${caddyQuote redirect.from} ${caddyQuote redirect.to} ${toString redirect.status}"
        ) ingress.redirects;
        cacheRules = lib.imap0 (
          index: rule:
          let
            matcher = "project_cache_${toString index}";
          in
          ''
            @${matcher} path ${lib.concatStringsSep " " (map caddyQuote rule.paths)}
            header @${matcher} Cache-Control ${caddyQuote rule.value}
          ''
        ) ingress.cacheRules;
        responseHeaders = lib.optional (ingress.responseHeaders != { }) ''
          header {
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (header: value: "${header} ${caddyQuote value}") ingress.responseHeaders
            )}
          }
        '';
      in
      lib.concatStringsSep "\n" (
        lib.optional ingress.compression "encode zstd gzip"
        ++ lib.optional (ingress.requestBodyMaxBytes != null) ''
          request_body {
            max_size ${toString ingress.requestBodyMaxBytes}B
          }
        ''
        ++ redirects
        ++ cacheRules
        ++ responseHeaders
      );

  gitTokenSetup =
    if cfg.source.giteaTokenSecretName == null then
      ''
        git_config_file=""
      ''
    else if hasSops then
      ''
        git_config_file="$(mktemp)"
        chmod 0600 "$git_config_file"
        git_token="$(tr -d '\r\n' < ${
          lib.escapeShellArg config.sops.secrets.${cfg.source.giteaTokenSecretName}.path
        })"
        printf '[url "https://%s:%s@%s/"]\n\tinsteadOf = https://%s/\n' \
          ${lib.escapeShellArg cfg.source.username} \
          "$git_token" \
          ${lib.escapeShellArg cfg.source.netrcHost} \
          ${lib.escapeShellArg cfg.source.netrcHost} \
          > "$git_config_file"
        unset git_token
        export GIT_CONFIG_GLOBAL="$git_config_file"
        export GIT_TERMINAL_PROMPT=0
      ''
    else
      throw "source.giteaTokenSecretName requires importing sops-nix or another module that defines options.sops";

  projectJobScripts = lib.mapAttrs (
    jobName: _policy:
    pkgs.writeShellScript "app-deployment-${name}-job-${jobName}" ''
      set -euo pipefail

      current=${lib.escapeShellArg stateDir}/current
      release_plan=${lib.escapeShellArg deployedProjectReleasePlan}
      executable="$current/bin/${cfg.executable}"
      if [ ! -x "$executable" ] || [ ! -f "$release_plan" ]; then
        echo "app-deployment/${name}: no deployed Release executable at $executable" >&2
        exit 1
      fi

      job=${lib.escapeShellArg jobName}
      action="$(${pkgs.jq}/bin/jq -er --arg job "$job" '.maintenanceJobs[$job].action' "$release_plan")"
      export PROJECT_RUNTIME_FILE=${lib.escapeShellArg deployedProjectRuntimeManifest}
      export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-${runtimeDir}/secrets}"
      exec "$executable" "$action"
    ''
  ) projectJobs;
  projectJobServices = lib.mapAttrs' (
    jobName: policy:
    lib.nameValuePair "${unitName}-job-${jobName}" {
      description = "Run Project Release job '${name}/${jobName}'";
      after = [
        "network-online.target"
        "${unitName}-release-plan.service"
      ]
      ++ projectContainerUnits
      ++ externalAfterUnits;
      wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
      requires = [ "${unitName}-release-plan.service" ] ++ externalRequiredUnits;
      serviceConfig = {
        Type = "oneshot";
        ExecCondition = projectArtifactConditionScript;
        ExecStart = projectJobScripts.${jobName};
        User = userName;
        Group = groupName;
        WorkingDirectory = workingDirectory;
      }
      // projectServicePolicy
      // lib.optionalAttrs (projectSecrets != { }) {
        LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") projectSecrets;
      }
      // {
        IOSchedulingClass = "idle";
        Nice = 10;
      };
    }
  ) projectJobs;
  projectJobTimers = lib.mapAttrs' (
    jobName: policy:
    lib.nameValuePair "${unitName}-job-${jobName}" {
      description = "Schedule Project Release job '${name}/${jobName}'";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Persistent = policy.persistent;
        RandomizedDelaySec = policy.randomizedDelaySec;
        Unit = "${unitName}-job-${jobName}.service";
      }
      // lib.optionalAttrs (policy.calendar != null) {
        OnCalendar = policy.calendar;
      }
      // lib.optionalAttrs (policy.interval != null) {
        OnActiveSec = policy.onBootSec;
      }
      // lib.optionalAttrs (policy.interval != null && policy.cadence == "fixed") {
        OnUnitActiveSec = policy.interval;
        # If a run fails, systemd never considers the unit active. Keep the
        # normal cadence alive without changing successful fixed-rate runs.
        OnUnitInactiveSec = policy.interval;
      }
      // lib.optionalAttrs (policy.interval != null && policy.cadence == "spaced") {
        OnUnitInactiveSec = policy.interval;
      };
    }
  ) projectJobs;
  staticCaddyConfig = ''
    root * ${stateDir}/current
    ${if isProject then projectIngressConfig else cfg.static.extraConfig}
    ${lib.optionalString isProject ''
      @project_metadata path /share/project/*
      respond @project_metadata 404
    ''}
    file_server
  '';
  projectServiceCaddyConfig = ''
    ${projectIngressConfig}
    reverse_proxy ${cfg.host}:${toString cfg.port} {
      ${lib.optionalString (projectRelease.ingress.streamCloseDelaySec != null) (
        "stream_close_delay ${toString projectRelease.ingress.streamCloseDelaySec}s"
      )}
    }
  '';
  projectHealthRecoveryScript = pkgs.writeShellScript "app-deployment-${name}-health-recovery" ''
    set -euo pipefail

    release_plan=${lib.escapeShellArg deployedProjectReleasePlan}
    ${healthArgs}

    check_once() {
      local request_timeout path
      local -a paths
      request_timeout="$(${pkgs.jq}/bin/jq -er '.health.requestTimeoutSec' "$release_plan")"
      mapfile -t paths < <(${pkgs.jq}/bin/jq -er '.health.paths[]' "$release_plan")
      for path in "''${paths[@]}"; do
        ${pkgs.curl}/bin/curl -fsS --max-time "$request_timeout" \
          "''${health_args[@]}" \
          "http://${cfg.health.host}:${toString cfg.port}$path" >/dev/null || return 1
      done
    }

    if check_once; then
      exit 0
    fi

    echo "app-deployment/${name}: periodic health failed; restarting" >&2
    ${pkgs.systemd}/bin/systemctl restart --no-block ${lib.escapeShellArg "${unitName}.service"}
    ${serviceHealthScript}
    check_service_health "$release_plan"
  '';
  projectServicePolicy = {
    TimeoutStopSec = "30s";
    UMask = "0027";
  }
  // lib.optionalAttrs (cfg.runtime.isolation == "isolated") {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = cfg.runtime.protectHome;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ runtimeDir ] ++ cfg.runtime.readWritePaths;
    RemoveIPC = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
  }
  // lib.optionalAttrs (projectMemory.high != null) { MemoryHigh = projectMemory.high; }
  // lib.optionalAttrs (projectMemory.max != null) { MemoryMax = projectMemory.max; }
  // lib.optionalAttrs (projectMemory.swapMax != null) { MemorySwapMax = projectMemory.swapMax; };

  runtimeConfig =
    if cfg.enable then
      {
        users.users = lib.optionalAttrs (needsRuntimeUser && cfg.runtime.user == null) {
          ${generatedUserName} = {
            isSystemUser = true;
            group = generatedUserName;
            home = stateDir;
          };
        };
        users.groups = lib.optionalAttrs (needsRuntimeUser && cfg.runtime.user == null) {
          ${generatedUserName} = { };
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/app-deployments 0755 root root -"
          "d ${stateDir} 0755 root root -"
        ]
        ++ lib.optionals needsRuntimeUser (
          [
            "d ${runtimeDir} 0750 ${userName} ${groupName} -"
            "d ${runtimeDir}/secrets 0700 ${userName} ${groupName} -"
          ]
          ++ (map (dir: "d ${runtimeDir}/${dir} 0750 ${userName} ${groupName} -") projectStateDirectories)
          ++ (map (dir: "d ${dir} 0750 ${userName} ${groupName} -") cfg.stateDirs)
        );

        systemd.services = projectJobServices // {
          ${unitName} = lib.mkIf isService {
            description = "App deployment '${name}'";
            after = [
              "network-online.target"
            ]
            ++ lib.optional isProject "${unitName}-release-plan.service"
            ++ projectContainerUnits
            ++ externalAfterUnits;
            wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
            requires = lib.optional isProject "${unitName}-release-plan.service" ++ externalRequiredUnits;
            environment =
              (
                if isProject then
                  { HOME = homeDir; }
                else
                  {
                    HOST = cfg.host;
                    PORT = toString cfg.port;
                    HOME = homeDir;
                  }
              )
              // cfg.environment;
            path = cfg.path;
            serviceConfig = {
              ExecStart = startScript;
              Restart = "always";
              RestartSec = "15s";
              User = userName;
              Group = groupName;
              WorkingDirectory = workingDirectory;
            }
            // lib.optionalAttrs isProject {
              ExecCondition = projectServiceConditionScript;
            }
            // lib.optionalAttrs isProject projectServicePolicy
            // lib.optionalAttrs (isProject && projectSecrets != { }) {
              LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") projectSecrets;
            }
            // lib.optionalAttrs (cfg.environmentFiles != [ ]) {
              EnvironmentFile = cfg.environmentFiles;
            }
            // cfg.serviceConfig;
            preStart = cfg.preStart;
          };

          ${updateUnitName} = {
            description = "Update app deployment '${name}'";
            after = [ "network-online.target" ] ++ projectContainerUnits ++ externalAfterUnits;
            wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
            requires = externalRequiredUnits;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = updateScript;
            };
          };

          ${activationUnitName} = lib.mkIf runsProjectActivation {
            description = "Activate Project Release '${name}'";
            after = [ "${unitName}-release-plan.service" ] ++ projectContainerUnits ++ externalAfterUnits;
            wants = projectContainerUnits ++ externalWantedUnits;
            requires = [ "${unitName}-release-plan.service" ] ++ externalRequiredUnits;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = activationScript;
              User = userName;
              Group = groupName;
              WorkingDirectory = workingDirectory;
            }
            // projectServicePolicy
            // lib.optionalAttrs (projectSecrets != { }) {
              LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") projectSecrets;
            };
          };

          "${unitName}-release-plan" = lib.mkIf (isProject && isService) {
            description = "Reconcile the active Project Release plan for '${name}'";
            before = [ "${unitName}.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = projectReleasePlanBootstrapScript;
            };
          };

          "${unitName}-health-recovery" =
            lib.mkIf (isProject && isService && cfg.project.healthRecovery.enable)
              {
                description = "Recover unhealthy Project Release '${name}'";
                after = [ "${unitName}.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  ExecCondition = projectArtifactConditionScript;
                  ExecStart = projectHealthRecoveryScript;
                  TimeoutStartSec = "infinity";
                };
              };
        };

        systemd.timers =
          lib.optionalAttrs cfg.autoUpdate.enable {
            ${updateUnitName} = {
              description = "Reconcile app deployment '${name}'";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnActiveSec = cfg.autoUpdate.onBootSec;
                OnUnitActiveSec = cfg.autoUpdate.interval;
                Persistent = true;
                Unit = "${updateUnitName}.service";
              }
              // lib.optionalAttrs (!isProject) {
                OnBootSec = cfg.autoUpdate.onBootSec;
              };
            };

          }
          // lib.optionalAttrs (isProject && isService && cfg.project.healthRecovery.enable) {
            "${unitName}-health-recovery" = {
              description = "Periodically probe Project Release '${name}'";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnActiveSec = cfg.project.healthRecovery.onBootSec;
                OnUnitActiveSec = cfg.project.healthRecovery.interval;
                Persistent = true;
                Unit = "${unitName}-health-recovery.service";
              };
            };
          }
          // projectJobTimers;

        fleet.appDeployments.webhookApps.${name} = {
          bindingPolicyFile = lib.optionalString isProject "${projectBindingPolicy}";
          compatibilityFile = "${stateDir}/compatibility.json";
          deliveryMode = cfg.delivery.mode;
          requestedReleaseFile = "${stateDir}/requested-release.json";
          updateUnit = "${updateUnitName}.service";
          # systemctl start waits for the oneshot update and fails with it.
          updateCommand = [
            "systemctl"
            "start"
            "${updateUnitName}.service"
          ];
          updateRunningCommand = [
            "${pkgs.bash}/bin/bash"
            "-c"
            ''state="$(systemctl show --property=ActiveState --value "$1")"; [ "$state" = activating ] || [ "$state" = deactivating ]''
            "update-running"
            "${updateUnitName}.service"
          ];
          requestedRevisionFile = "${stateDir}/requested-revision";
          placement = if granted then placementRegistration else null;
        };

        # Placed routes import the site from here, since only the hostname is the placement's.
        environment.etc = lib.optionalAttrs granted {
          "app-deployments/sites/${name}.caddy".text = projectServiceCaddyConfig;
        };

        fleet.services.appDeployments.metadata.health.units = lib.optional isService "${unitName}.service";

        virtualisation.oci-containers.containers = lib.mapAttrs' (
          auxiliaryName: auxiliary:
          lib.nameValuePair (projectContainerName auxiliaryName) {
            image = auxiliary.image;
            cmd = auxiliary.command;
            ports = lib.mapAttrsToList (
              portName: port:
              "127.0.0.1:${
                toString projectAuxiliaryPorts.${auxiliaryName}.${portName}
              }:${toString port.containerPort}/${port.protocol}"
            ) auxiliary.ports;
            extraOptions = [ "--init" ];
          }
        ) projectAuxiliaries;

        fleet.services.caddy.virtualHosts = lib.optionalAttrs (cfg.domain != null) {
          ${cfg.domain} =
            if isService && !isProject then
              {
                backend = {
                  address = cfg.host;
                  inherit (cfg) port;
                };
                tailscaleOnly = !cfg.public;
              }
            else if isService then
              {
                extraConfig = projectServiceCaddyConfig;
                tailscaleOnly = !cfg.public;
              }
            else
              {
                extraConfig = staticCaddyConfig;
                tailscaleOnly = !cfg.public;
              };
        };
      }
      // lib.optionalAttrs (hasSops && cfg.source.giteaTokenSecretName != null) {
        sops.secrets.${cfg.source.giteaTokenSecretName} = {
          owner = "root";
          mode = "0400";
        };
      }
    else
      { };
  runtimeModule = {
    config = runtimeConfig;
  };
in
if internal then
  runtimeModule
else
  {
    config.fleet.services.appDeployments.apps.${app.name} = declaredApp;
  }
