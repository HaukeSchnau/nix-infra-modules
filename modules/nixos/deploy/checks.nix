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
  demoApp = {
    domain = "demo.example.net";
    public = false;
    port = 18080;
    package = "default";
    executable = "demo-server";
    source = {
      url = "git+https://git.example.net/example/demo-app.git";
      branch = "main";
    };
    health.paths = [ "/" ];
  };
  legacySystem = mkFleetSystem "app-01" [
    (self.lib.nixos.nixFlakeService (demoApp // { name = "demo"; }))
  ];
  typedSystem = mkFleetSystem "app-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo = demoApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  staticSystem = mkFleetSystem "static-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.docs = {
          backend = "static";
          domain = "docs.example.net";
          public = true;
          package = "site";
          static.extraConfig = ''
            encode zstd gzip
          '';
          source = {
            url = "git+https://git.example.net/example/docs.git";
            branch = "main";
          };
          health.paths = [
            "/"
            "/guide/"
            "/manual.pdf"
          ];
        };
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  stoppedSystem = mkFleetSystem "app-stopped" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo = demoApp // {
          enable = false;
        };
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  invalidNameSystem = mkFleetSystem "app-invalid-name" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps."bad.name" = demoApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  invalidHealthSystem = mkFleetSystem "app-invalid-health" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo = demoApp // {
          health = {
            intervalSec = 0;
            paths = [ ];
          };
        };
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  invalidStaticSystem = mkFleetSystem "app-invalid-static" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo = demoApp // {
          backend = "static";
        };
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  configurationSucceeds =
    systemConfig:
    (builtins.tryEval (builtins.deepSeq systemConfig.config.system.build.toplevel.drvPath true))
    .success;
  appRuntimeProjection =
    config:
    let
      service = config.systemd.services.app-deployment-demo;
      updateService = config.systemd.services.app-deployment-demo-update;
      timer = config.systemd.timers.app-deployment-demo-update;
    in
    {
      user = {
        inherit (config.users.users.app-demo) isSystemUser group home;
      };
      groupDeclared = builtins.hasAttr "app-demo" config.users.groups;
      service = {
        inherit (service)
          description
          environment
          path
          preStart
          ;
        serviceConfig = {
          inherit (service.serviceConfig)
            ExecStart
            Group
            Restart
            RestartSec
            User
            WorkingDirectory
            ;
        };
      };
      updateService = {
        inherit (updateService) description;
        serviceConfig = {
          inherit (updateService.serviceConfig) ExecStart Type;
        };
      };
      timer = {
        inherit (timer) description wantedBy;
        inherit (timer.timerConfig)
          OnActiveSec
          OnBootSec
          OnUnitActiveSec
          Persistent
          Unit
          ;
      };
      tmpfiles = builtins.filter (lib.hasInfix "/var/lib/app-deployments") config.systemd.tmpfiles.rules;
      webhook = config.vps.appDeployments.webhookApps.demo;
      caddy = config.vps.services.caddy.virtualHosts."demo.example.net";
      healthUnits = config.vps.services.appDeployments.metadata.health.units;
    };
  legacyRuntime = pkgs.writeText "legacy-app-runtime.json" (
    builtins.toJSON (appRuntimeProjection legacySystem.config)
  );
  typedRuntime = pkgs.writeText "typed-app-runtime.json" (
    builtins.toJSON (appRuntimeProjection typedSystem.config)
  );
  staticRuntime = pkgs.writeText "static-app-runtime.json" (
    builtins.toJSON {
      hasAppService = builtins.hasAttr "app-deployment-docs" staticSystem.config.systemd.services;
      hasUpdateService = builtins.hasAttr "app-deployment-docs-update" staticSystem.config.systemd.services;
      hasUpdateTimer = builtins.hasAttr "app-deployment-docs-update" staticSystem.config.systemd.timers;
      hasUser = builtins.hasAttr "app-docs" staticSystem.config.users.users;
      caddy = staticSystem.config.vps.services.caddy.virtualHosts."docs.example.net";
      webhook = staticSystem.config.vps.appDeployments.webhookApps.docs;
      healthUnits = staticSystem.config.vps.services.appDeployments.metadata.health.units;
    }
  );
  serviceUpdateScript =
    typedSystem.config.systemd.services.app-deployment-demo-update.serviceConfig.ExecStart;
  staticUpdateScript =
    staticSystem.config.systemd.services.app-deployment-docs-update.serviceConfig.ExecStart;
  conciseProjectDescriptor = {
    schemaVersion = 1;
    project = "demo-project";
    secrets.betterAuthSecret = {
      description = "Signs application sessions.";
    };
    parameters.maxStorageMb = {
      type = "integer";
      default = 512;
    };
    release = {
      activationExecutable = "activate-release";
      stateDirectories = [ "data" ];
      maintenanceJobs.cleanup = {
        action = "cleanup";
        schedule = {
          cadence = "fixed";
          interval = "6h";
        };
        secrets = [ "betterAuthSecret" ];
      };
      ingress = {
        compression = true;
        requestBodyMaxBytes = 1048576;
        redirects = [
          {
            from = "/old";
            to = "/new";
            permanent = false;
          }
        ];
        cacheRules = [
          {
            paths = [ "/assets/*" ];
            value = "public, max-age=3600";
          }
        ];
        responseHeaders.X-Content-Type-Options = "nosniff";
      };
      ociAuxiliaries.database = {
        image = "postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        ports.postgres.containerPort = 5432;
      };
    };
  };
  normalizedProjectDescriptor = self.lib.projectDescriptor.normalize {
    descriptor = conciseProjectDescriptor;
  };
  renormalizedProjectDescriptor = self.lib.projectDescriptor.normalize {
    descriptor = normalizedProjectDescriptor;
  };
  normalizedCalendarJobDescriptor = self.lib.projectDescriptor.normalize {
    descriptor = conciseProjectDescriptor // {
      release = conciseProjectDescriptor.release // {
        maintenanceJobs.cleanup.schedule = {
          calendar = "*-*-* 03:15:00";
        };
      };
    };
  };
  renormalizedCalendarJobDescriptor = self.lib.projectDescriptor.normalize {
    descriptor = normalizedCalendarJobDescriptor;
  };
  normalizedDevelopmentHealthDescriptor = self.lib.projectDescriptor.normalize {
    descriptor = conciseProjectDescriptor // {
      schemaVersion = 2;
      development.endpoints.web = { };
    };
  };
  projectPolicy = {
    project = "demo-project";
    source = {
      url = "git+https://git.example.net/example/demo-project.git";
      branch = "main";
    };
    domain = "demo-project.example.net";
    public = true;
    secrets.betterAuthSecret = "/run/secrets/demo-better-auth";
    approvedOci = [ "database" ];
    jobs.cleanup = {
      cadence = "spaced";
      interval = "1d";
      onBootSec = "15min";
      randomizedDelaySec = "30min";
    };
    resources.memory = {
      high = "768M";
      max = "1G";
      swapMax = "0";
    };
  };
  projectApp = self.lib.projectDescriptor.releaseApp {
    descriptor = conciseProjectDescriptor;
    policy = projectPolicy;
  };
  defaultScheduleProjectApp = self.lib.projectDescriptor.releaseApp {
    descriptor = conciseProjectDescriptor;
    policy = builtins.removeAttrs projectPolicy [ "jobs" ];
  };
  nullCadenceScheduleProjectApp = self.lib.projectDescriptor.releaseApp {
    descriptor = conciseProjectDescriptor;
    policy = builtins.removeAttrs projectPolicy [ "jobs" ] // {
      jobs.cleanup.cadence = null;
    };
  };
  disabledScheduleProjectApp = self.lib.projectDescriptor.releaseApp {
    descriptor = conciseProjectDescriptor;
    policy = projectPolicy // {
      jobs.cleanup.enable = false;
    };
  };
  trustedProjectApp = projectApp // {
    runtime = (projectApp.runtime or { }) // {
      isolation = "trusted";
    };
  };
  pairedProjectDescriptor = conciseProjectDescriptor // {
    schemaVersion = 2;
    development = { };
    release = conciseProjectDescriptor.release // {
      ingress = conciseProjectDescriptor.release.ingress // {
        streamCloseDelaySec = 300;
      };
      preDeployTasks.migrate = {
        failureMode = "defer";
        secrets = [ "betterAuthSecret" ];
        timeoutSec = 120;
      };
    };
  };
  pairedProjectApp =
    self.lib.projectDescriptor.releaseApp {
      descriptor = pairedProjectDescriptor;
      policy = projectPolicy // {
        exposeRevision = true;
      };
    }
    // {
      delivery = {
        mode = "cache";
        cacheStore = "https://cache.example.net/nix";
      };
    };
  projectSystem = mkFleetSystem "project-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = projectApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  defaultScheduleProjectSystem = mkFleetSystem "project-default-schedule-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = defaultScheduleProjectApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  nullCadenceScheduleProjectSystem = mkFleetSystem "project-null-cadence-schedule-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = nullCadenceScheduleProjectApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  disabledScheduleProjectSystem = mkFleetSystem "project-disabled-schedule-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = disabledScheduleProjectApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  trustedProjectSystem = mkFleetSystem "project-trusted-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = trustedProjectApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  pairedProjectSystem = mkFleetSystem "paired-project-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = pairedProjectApp // {
          unitDependencies = {
            after = [ "prepared.service" ];
            wants = [ "collector.service" ];
            requires = [ "database.service" ];
          };
        };
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  noActivationProjectSystem = mkFleetSystem "no-activation-project-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = self.lib.projectDescriptor.releaseApp {
          descriptor = pairedProjectDescriptor // {
            release = builtins.removeAttrs pairedProjectDescriptor.release [ "activationExecutable" ];
          };
          policy = projectPolicy;
        };
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  projectService = projectSystem.config.systemd.services.app-deployment-demo-project;
  projectActivationService =
    projectSystem.config.systemd.services.app-deployment-demo-project-activate;
  projectRecoveryService =
    projectSystem.config.systemd.services.app-deployment-demo-project-health-recovery;
  projectReleasePlanService =
    projectSystem.config.systemd.services.app-deployment-demo-project-release-plan;
  projectUpdateScript =
    projectSystem.config.systemd.services.app-deployment-demo-project-update.serviceConfig.ExecStart;
  projectStartScript = projectService.serviceConfig.ExecStart;
  projectActivationScript = projectActivationService.serviceConfig.ExecStart;
  projectJobService = projectSystem.config.systemd.services.app-deployment-demo-project-job-cleanup;
  projectJobScript = projectJobService.serviceConfig.ExecStart;
  trustedProjectService = trustedProjectSystem.config.systemd.services.app-deployment-demo-project;
  trustedProjectActivationService =
    trustedProjectSystem.config.systemd.services.app-deployment-demo-project-activate;
  trustedProjectJobService =
    trustedProjectSystem.config.systemd.services.app-deployment-demo-project-job-cleanup;
  trustedProjectUpdateScript =
    trustedProjectSystem.config.systemd.services.app-deployment-demo-project-update.serviceConfig.ExecStart;
  sandboxProperties = [
    "CapabilityBoundingSet"
    "LockPersonality"
    "NoNewPrivileges"
    "PrivateDevices"
    "PrivateTmp"
    "ProtectClock"
    "ProtectControlGroups"
    "ProtectHome"
    "ProtectKernelLogs"
    "ProtectKernelModules"
    "ProtectKernelTunables"
    "ProtectSystem"
    "ReadWritePaths"
    "RemoveIPC"
    "RestrictAddressFamilies"
    "RestrictRealtime"
    "RestrictSUIDSGID"
    "SystemCallArchitectures"
  ];
  presentSandboxProperties =
    service: lib.filter (name: builtins.hasAttr name service.serviceConfig) sandboxProperties;
  pairedProjectStartScript =
    pairedProjectSystem.config.systemd.services.app-deployment-demo-project.serviceConfig.ExecStart;
  pairedProjectUpdateScript =
    pairedProjectSystem.config.systemd.services.app-deployment-demo-project-update.serviceConfig.ExecStart;
  projectReleaseCommandPackage =
    lib.findFirst (package: lib.getName package == "project-release-command")
      (throw "project-release-command is absent from the Project host")
      pairedProjectSystem.config.environment.systemPackages;
  projectReleaseCommand = lib.getExe projectReleaseCommandPackage;
  projectReleaseStatusPackage =
    lib.findFirst (package: lib.getName package == "project-release-status")
      (throw "project-release-status is absent from the Project host")
      pairedProjectSystem.config.environment.systemPackages;
  projectReleaseStatus = lib.getExe projectReleaseStatusPackage;
  staticProjectDescriptor = {
    schemaVersion = 1;
    project = "static-project";
    release.backend = "static";
  };
  staticProjectSystem = mkFleetSystem "project-static-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.static-project = self.lib.projectDescriptor.releaseApp {
          descriptor = staticProjectDescriptor;
          policy = {
            project = "static-project";
            source.url = "git+https://git.example.net/example/static-project.git";
            domain = "static-project.example.net";
            public = true;
          };
        };
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  projectRuntime = pkgs.writeText "project-app-runtime.json" (
    builtins.toJSON {
      service = {
        inherit (projectService) after wants environment;
        condition = projectService.serviceConfig.ExecCondition;
        inherit (projectService.serviceConfig)
          CapabilityBoundingSet
          LoadCredential
          NoNewPrivileges
          ProtectSystem
          ReadWritePaths
          MemoryHigh
          MemoryMax
          MemorySwapMax
          ;
      };
      activation = {
        inherit (projectActivationService) after wants;
        inherit (projectActivationService.serviceConfig)
          LoadCredential
          Type
          User
          ;
      };
      caddy = projectSystem.config.vps.services.caddy.virtualHosts."demo-project.example.net";
      container =
        projectSystem.config.virtualisation.oci-containers.containers.project-demo-project-database;
      recoveryTimer =
        let
          timer = projectSystem.config.systemd.timers.app-deployment-demo-project-health-recovery;
        in
        {
          inherit (timer) wantedBy;
          inherit (timer.timerConfig)
            OnActiveSec
            OnUnitActiveSec
            Persistent
            Unit
            ;
        };
      updateTimer =
        let
          timer = projectSystem.config.systemd.timers.app-deployment-demo-project-update;
        in
        {
          inherit (timer.timerConfig) OnActiveSec OnUnitActiveSec;
          hasOnBootSec = timer.timerConfig ? OnBootSec;
        };
      recovery = {
        condition = projectRecoveryService.serviceConfig.ExecCondition;
        inherit (projectRecoveryService.serviceConfig) TimeoutStartSec;
      };
      recoveryScript = projectRecoveryService.serviceConfig.ExecStart;
      releasePlan = {
        inherit (projectReleasePlanService) before;
        inherit (projectReleasePlanService.serviceConfig) ExecStart Type;
      };
      job = {
        inherit (projectJobService) after wants;
        condition = projectJobService.serviceConfig.ExecCondition;
        inherit (projectJobService.serviceConfig)
          LoadCredential
          IOSchedulingClass
          Nice
          NoNewPrivileges
          Type
          User
          ;
        timer =
          let
            timer = projectSystem.config.systemd.timers.app-deployment-demo-project-job-cleanup;
          in
          {
            inherit (timer) wantedBy;
            inherit (timer.timerConfig)
              OnActiveSec
              OnUnitInactiveSec
              Persistent
              RandomizedDelaySec
              Unit
              ;
          };
      };
      trusted = {
        serviceSandbox = presentSandboxProperties trustedProjectService;
        activationSandbox = presentSandboxProperties trustedProjectActivationService;
        jobSandbox = presentSandboxProperties trustedProjectJobService;
        serviceUMask = trustedProjectService.serviceConfig.UMask;
        updaterUsesSandbox = lib.hasInfix "--property=NoNewPrivileges=true" trustedProjectUpdateScript;
      };
      staticCaddy =
        staticProjectSystem.config.vps.services.caddy.virtualHosts."static-project.example.net";
      tmpfiles = builtins.filter (lib.hasInfix "/var/lib/app-deployments/demo-project") projectSystem.config.systemd.tmpfiles.rules;
    }
  );
  descriptorEvaluationSucceeds =
    descriptor:
    (builtins.tryEval (
      builtins.deepSeq (self.lib.projectDescriptor.normalize { inherit descriptor; }) true
    )).success;
  releaseProjectionSucceeds =
    descriptor: policy:
    (builtins.tryEval (
      builtins.deepSeq (self.lib.projectDescriptor.releaseApp { inherit descriptor policy; }) true
    )).success;
  compatibilityPolicy = pkgs.writeText "project-release-compatibility-policy.json" (
    builtins.toJSON {
      descriptor = self.lib.projectDescriptor.normalize { descriptor = pairedProjectDescriptor; };
      managedJobs = [ "cleanup" ];
      bindings = {
        parameters.futureInteger = 42;
        secrets = [
          "betterAuthSecret"
          "futureSecret"
        ];
      };
    }
  );
  compatibleCandidate = pkgs.writeText "project-release-compatible-candidate.json" (
    builtins.toJSON (
      pairedProjectDescriptor
      // {
        development.endpoints.preview = { };
        parameters = pairedProjectDescriptor.parameters // {
          futureInteger = {
            type = "integer";
            description = "Added after the host binding was declared.";
          };
        };
        secrets = pairedProjectDescriptor.secrets // {
          futureSecret.description = "Added after the host binding was declared.";
        };
      }
    )
  );
  missingBindingCandidate = pkgs.writeText "project-release-missing-binding-candidate.json" (
    builtins.toJSON (
      pairedProjectDescriptor
      // {
        parameters = pairedProjectDescriptor.parameters // {
          unbound = {
            type = "string";
            required = true;
          };
        };
      }
    )
  );
  changedHealthCandidate = pkgs.writeText "project-release-changed-health-candidate.json" (
    builtins.toJSON (
      pairedProjectDescriptor
      // {
        release = pairedProjectDescriptor.release // {
          health.paths = [ "/different" ];
          preDeployTasks = pairedProjectDescriptor.release.preDeployTasks // {
            warmup = {
              action = "warm-cache";
              dependsOn = [ "migrate" ];
              timeoutSec = 30;
            };
          };
        };
      }
    )
  );
  changedTopologyCandidate = pkgs.writeText "project-release-changed-topology-candidate.json" (
    builtins.toJSON (
      pairedProjectDescriptor
      // {
        release = pairedProjectDescriptor.release // {
          ingress.compression = true;
        };
      }
    )
  );
  changedActionsCandidate = pkgs.writeText "project-release-changed-actions-candidate.json" (
    builtins.toJSON (
      pairedProjectDescriptor
      // {
        secrets = pairedProjectDescriptor.secrets // {
          futureSecret.description = "Used by the new maintenance implementation.";
        };
        release = pairedProjectDescriptor.release // {
          activationExecutable = "activate-v2";
          maintenanceJobs.cleanup = {
            action = "prune";
            secrets = [ "futureSecret" ];
          };
        };
      }
    )
  );
  missingManagedJobCandidate = pkgs.writeText "project-release-missing-managed-job-candidate.json" (
    builtins.toJSON (
      pairedProjectDescriptor
      // {
        release = pairedProjectDescriptor.release // {
          maintenanceJobs = { };
        };
      }
    )
  );
in
{
  app-deployments-contract = pkgs.runCommand "app-deployments-contract" { } ''
    ${pkgs.bash}/bin/bash -n ${serviceUpdateScript}
    ${pkgs.bash}/bin/bash -n ${staticUpdateScript}
    grep -Fq ${lib.escapeShellArg "${pkgs.openssh}/bin"} ${serviceUpdateScript}
    grep -Fq ${lib.escapeShellArg "${pkgs.openssh}/bin"} ${staticUpdateScript}
    grep -Fq 'already produces the active output' ${serviceUpdateScript}
    grep -Fq 'already produces the active output' ${staticUpdateScript}
    cmp ${legacyRuntime} ${typedRuntime}
    test '${
      if builtins.hasAttr "app-deployment-demo" legacySystem.config.systemd.services then
        "present"
      else
        "absent"
    }' = present
    test '${
      if builtins.hasAttr "app-deployment-demo" stoppedSystem.config.systemd.services then
        "present"
      else
        "absent"
    }' = absent
    test '${if configurationSucceeds invalidNameSystem then "accepted" else "rejected"}' = rejected
    test '${if configurationSucceeds invalidHealthSystem then "accepted" else "rejected"}' = rejected
    test '${if configurationSucceeds invalidStaticSystem then "accepted" else "rejected"}' = rejected
    ${pkgs.jq}/bin/jq -e '
      .hasAppService == false
      and .hasUpdateService == true
      and .hasUpdateTimer == true
      and .hasUser == false
      and .caddy.tailscaleOnly == false
      and (.caddy.extraConfig | contains("root * /var/lib/app-deployments/docs/current"))
      and (.caddy.extraConfig | contains("encode zstd gzip"))
      and (.caddy.extraConfig | contains("file_server"))
      and .webhook.updateUnit == "app-deployment-docs-update.service"
      and .healthUnits == []
    ' ${staticRuntime} >/dev/null
    touch $out
  '';

  project-descriptor-contract = pkgs.runCommand "project-descriptor-contract" { } ''
    test '${
      if normalizedProjectDescriptor.release.backend == "service" then "service" else "other"
    }' = service
    test '${normalizedProjectDescriptor.release.package}' = projectRelease
    test '${normalizedProjectDescriptor.release.executable}' = project-release-runtime
    test '${normalizedProjectDescriptor.release.maintenanceJobs.cleanup.schedule.interval}' = 6h
    test '${normalizedProjectDescriptor.release.maintenanceJobs.cleanup.schedule.cadence}' = fixed
    test '${renormalizedProjectDescriptor.release.maintenanceJobs.cleanup.schedule.interval}' = 6h
    test '${renormalizedCalendarJobDescriptor.release.maintenanceJobs.cleanup.schedule.calendar}' = '*-*-* 03:15:00'
    test '${defaultScheduleProjectSystem.config.systemd.timers.app-deployment-demo-project-job-cleanup.timerConfig.OnUnitActiveSec}' = 6h
    test '${defaultScheduleProjectSystem.config.systemd.timers.app-deployment-demo-project-job-cleanup.timerConfig.OnUnitInactiveSec}' = 6h
    test '${nullCadenceScheduleProjectSystem.config.systemd.timers.app-deployment-demo-project-job-cleanup.timerConfig.OnUnitActiveSec}' = 6h
    test '${
      if
        builtins.hasAttr "app-deployment-demo-project-job-cleanup" disabledScheduleProjectSystem.config.systemd.timers
      then
        "present"
      else
        "absent"
    }' = absent
    test '${toString normalizedProjectDescriptor.parameters.maxStorageMb.default}' = 512
    test '${
      if normalizedProjectDescriptor.secrets.betterAuthSecret.required then "required" else "optional"
    }' = required
    test '${toString (builtins.elemAt normalizedProjectDescriptor.release.ingress.redirects 0).status}' = 307
    test '${
      toString
        (self.lib.projectDescriptor.normalize { descriptor = pairedProjectDescriptor; })
        .release.ingress.streamCloseDelaySec
    }' = 300
    test '${
      (self.lib.projectDescriptor.normalize { descriptor = pairedProjectDescriptor; })
      .release.preDeployTasks.migrate.failureMode
    }' = defer
    test '${normalizedProjectDescriptor.release.ociAuxiliaries.database.ports.postgres.protocol}' = tcp
    test '${toString normalizedDevelopmentHealthDescriptor.development.endpoints.web.health.intervalSec}' = 1
    test '${toString normalizedDevelopmentHealthDescriptor.development.endpoints.web.health.requestTimeoutSec}' = 15
    test '${toString normalizedDevelopmentHealthDescriptor.release.health.intervalSec}' = 2
    test '${toString normalizedDevelopmentHealthDescriptor.release.health.requestTimeoutSec}' = 5
    test '${
      lib.concatStringsSep "," (
        self.lib.projectDescriptor.releaseTaskOrder
          (self.lib.projectDescriptor.normalize { descriptor = pairedProjectDescriptor; }).release
      )
    }' = migrate

    test '${
      if descriptorEvaluationSucceeds (conciseProjectDescriptor // { schemaVersion = 2; }) then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if
        descriptorEvaluationSucceeds (
          pairedProjectDescriptor
          // {
            release = pairedProjectDescriptor.release // {
              preDeployTasks = {
                first.dependsOn = [ "second" ];
                second.dependsOn = [ "first" ];
              };
            };
          }
        )
      then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if
        releaseProjectionSucceeds conciseProjectDescriptor (
          projectPolicy
          // {
            approvedOci = [
              "database"
              "stale"
            ];
          }
        )
      then
        "accepted"
      else
        "rejected"
    }' = accepted
    test '${
      if descriptorEvaluationSucceeds (conciseProjectDescriptor // { project = "Bad Project"; }) then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if descriptorEvaluationSucceeds (conciseProjectDescriptor // { secrets."bad/name" = { }; }) then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if
        descriptorEvaluationSucceeds (
          conciseProjectDescriptor // { release.stateDirectories = [ "/absolute" ]; }
        )
      then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if
        descriptorEvaluationSucceeds (
          conciseProjectDescriptor // { release.ingress.extraConfig = "raw caddy"; }
        )
      then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if
        descriptorEvaluationSucceeds (
          conciseProjectDescriptor // { release.ociAuxiliaries.database.image = "postgres:latest"; }
        )
      then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if
        releaseProjectionSucceeds conciseProjectDescriptor (
          builtins.removeAttrs projectPolicy [ "approvedOci" ]
        )
      then
        "accepted"
      else
        "rejected"
    }' = rejected
    test '${
      if
        releaseProjectionSucceeds conciseProjectDescriptor (
          projectPolicy // { jobs.unknown.interval = "1d"; }
        )
      then
        "accepted"
      else
        "rejected"
    }' = accepted

    ${pkgs.bash}/bin/bash -n ${projectUpdateScript}
    ${pkgs.bash}/bin/bash -n ${projectStartScript}
    ${pkgs.bash}/bin/bash -n ${projectActivationScript}
    ${pkgs.bash}/bin/bash -n ${projectJobScript}
    ${pkgs.bash}/bin/bash -n ${projectReleasePlanService.serviceConfig.ExecStart}
    ${pkgs.bash}/bin/bash -n ${projectReleaseCommand}
    ${pkgs.bash}/bin/bash -n ${projectReleaseStatus}
    grep -Fq 'share/project/descriptor.json' ${projectUpdateScript}
    test '${
      if
        builtins.hasAttr "app-deployment-demo-project-activate" noActivationProjectSystem.config.systemd.services
      then
        "present"
      else
        "absent"
    }' = present
    grep -Fq 'current_descriptor_matches' ${projectUpdateScript}
    grep -Fq -- '-diffutils-' ${projectUpdateScript}
    grep -Fq 'project-release-compatibility.jq' ${projectUpdateScript}
    grep -Fq 'app-deployment-demo-project-activate.service' ${projectUpdateScript}
    grep -Fq 'rollback activation' ${projectUpdateScript}
    grep -Fq 'PROJECT_RUNTIME_FILE=' ${projectStartScript}
    grep -Fq 'PROJECT_SECRETS_DIR=' ${projectStartScript}
    grep -Fq '/project-runtime.json' ${projectStartScript}
    ! grep -Fq -- '-project-release-runtime-demo-project.json' ${projectStartScript}
    grep -Fq 'runtime_manifest.next' ${projectUpdateScript}
    grep -Fq 'chmod 0644 "$runtime_manifest.next"' ${projectUpdateScript}
    grep -Fq 'previous_runtime_manifest' ${projectUpdateScript}
    grep -Fq 'candidate_revision="$resolved_revision"' ${pairedProjectUpdateScript}
    grep -Fq 'cmp -s "$candidate_runtime_manifest" "$runtime_manifest"' ${pairedProjectUpdateScript}
    grep -Fq 'cmp -s "$candidate_release_plan" "$release_plan"' ${pairedProjectUpdateScript}
    grep -Fq '/release-plan.json' ${projectReleasePlanService.serviceConfig.ExecStart}
    grep -Fq '.releasePlan' ${projectReleasePlanService.serviceConfig.ExecStart}
    ! grep -Fq 'activate-release' ${projectStartScript}
    grep -Fq '.activationExecutable // empty' ${projectActivationScript}
    grep -Fq '.maintenanceJobs[$job].action' ${projectJobScript}
    ! grep -Fq 'activate-release' ${projectActivationScript}
    ! grep -Fq 'exec "$executable" cleanup' ${projectJobScript}
    grep -Fq '/candidate-project-runtime.json' ${pairedProjectUpdateScript}
    grep -Fq '/candidate-release-plan.json' ${pairedProjectUpdateScript}
    grep -Fq 'systemd-run' ${pairedProjectUpdateScript}
    grep -Fq 'systemd_run_args=(' ${pairedProjectUpdateScript}
    grep -Fq 'systemd-run "''${systemd_run_args[@]}"' ${pairedProjectUpdateScript}
    grep -Fq -- '--property=LoadCredential=$secret:$path' ${pairedProjectUpdateScript}
    grep -Fq -- '--property=NoNewPrivileges=true' ${pairedProjectUpdateScript}
    grep -Fq '.preDeployOrder[]' ${pairedProjectUpdateScript}
    grep -Fq '.preDeployTasks[$task].failureMode' ${pairedProjectUpdateScript}
    grep -Fq 'systemd-run' ${projectReleaseCommand}
    grep -Fq '.commands[$command].secrets[]' ${projectReleaseCommand}
    grep -Fq -- '--working-directory="$working_directory"' ${projectReleaseCommand}
    grep -Fq 'stream_close_delay 300s' <<< ${
      lib.escapeShellArg
        pairedProjectSystem.config.vps.services.caddy.virtualHosts."demo-project.example.net".extraConfig
    }
    grep -Fq 'cleanup_candidate' ${pairedProjectUpdateScript}
    grep -Fq 'requested-release.json' ${pairedProjectUpdateScript}
    grep -Fq 'nix-store --realise "$requested_store_path"' ${pairedProjectUpdateScript}
    ! grep -Fq 'nix build --no-link' ${pairedProjectUpdateScript}
    ! grep -Fq 'nix flake metadata' ${pairedProjectUpdateScript}

    pre_deploy_line="$(${pkgs.gnugrep}/bin/grep -nF 'systemd-run' ${pairedProjectUpdateScript} | cut -d: -f1)"
    cutover_line="$(${pkgs.gnugrep}/bin/grep -nF 'mv -Tf "$current_link.next" "$current_link"' ${pairedProjectUpdateScript} | head -n 1 | cut -d: -f1)"
    test "$pre_deploy_line" -lt "$cutover_line"

    binding_policy="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-project-release-bindings-demo-project.json' ${projectUpdateScript} | head -n 1)"
    runtime_manifest="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-project-release-runtime-base-demo-project.json' ${projectUpdateScript} | head -n 1)"
    paired_runtime_manifest="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-project-release-runtime-base-demo-project.json' ${pairedProjectUpdateScript} | head -n 1)"
    grep -Fq '/project-runtime.json' ${projectStartScript}
    grep -Fq '/project-runtime.json' ${projectJobScript}
    ${pkgs.check-jsonschema}/bin/check-jsonschema \
      --schemafile ${../../../schemas/project-runtime/v2.json} \
      "$paired_runtime_manifest"
    ${pkgs.jq}/bin/jq -e '
      .descriptor.schemaVersion == 1
      and .descriptor.project == "demo-project"
      and .descriptor.release.activationExecutable == "activate-release"
      and .descriptor.release.backend == "service"
    ' "$binding_policy" >/dev/null

    compatibility() {
      ${pkgs.jq}/bin/jq -n \
        --slurpfile host ${compatibilityPolicy} \
        --slurpfile candidate "$1" \
        -f ${./project-release-compatibility.jq}
    }
    compatibility ${compatibleCandidate} > compatible.json
    ${pkgs.jq}/bin/jq -e '
      .compatible
      and .parameters.futureInteger == 42
      and .secrets.futureSecret == "futureSecret"
    ' compatible.json >/dev/null
    compatibility ${missingBindingCandidate} > missing.json
    ${pkgs.jq}/bin/jq -e '
      (.compatible | not)
      and (.reasons | index("missing required parameter binding: unbound"))
    ' missing.json >/dev/null
    compatibility ${changedTopologyCandidate} > topology.json
    ${pkgs.jq}/bin/jq -e '
      (.compatible | not)
      and (.reasons | index("Release topology differs from the host-compatible contract"))
    ' topology.json >/dev/null
    compatibility ${changedHealthCandidate} > health.json
    ${pkgs.jq}/bin/jq -e '
      .compatible
      and .releasePlan.health.paths == ["/different"]
      and .releasePlan.preDeployOrder == ["migrate", "warmup"]
      and .releasePlan.preDeployTasks.migrate.action == "migrate"
      and .releasePlan.preDeployTasks.migrate.timeoutSec == 120
      and .releasePlan.preDeployTasks.migrate.failureMode == "defer"
      and .releasePlan.preDeployTasks.warmup.action == "warm-cache"
    ' health.json >/dev/null
    compatibility ${changedActionsCandidate} > actions.json
    ${pkgs.jq}/bin/jq -e '
      .compatible
      and .releasePlan.activationExecutable == "activate-v2"
      and .releasePlan.maintenanceJobs.cleanup.action == "prune"
      and .releasePlan.maintenanceJobs.cleanup.secrets == ["futureSecret"]
      and (.candidateContract.release | has("activationExecutable") | not)
      and (.candidateContract.release | has("maintenanceJobs") | not)
    ' actions.json >/dev/null
    compatibility ${missingManagedJobCandidate} > missing-job.json
    ${pkgs.jq}/bin/jq -e '
      (.compatible | not)
      and (.reasons | index("host-managed maintenance job is not declared by the candidate: cleanup"))
    ' missing-job.json >/dev/null
    ${pkgs.jq}/bin/jq -e '
      .schemaVersion == 1
      and .project == "demo-project"
      and .realization == "release"
      and .endpoints.default.url == "https://demo-project.example.net"
      and .endpoints.default.listen.host == "127.0.0.1"
      and .endpoints.default.listen.port == 18200
      and .endpoints["database-postgres"].url == "tcp://127.0.0.1:22000"
      and (.parameters | not)
      and (.secrets | not)
    ' "$runtime_manifest" >/dev/null
    ${pkgs.jq}/bin/jq -e '
      .schemaVersion == 2
      and .project == "demo-project"
      and .realization == "release"
      and .endpoints.web.protocol == "http"
      and .endpoints.web.url == "https://demo-project.example.net"
      and .endpoints.web.hostNames == ["demo-project.example.net"]
      and .endpoints.web.visibility == "public"
      and .endpoints.web.listen.host == "127.0.0.1"
      and .endpoints.web.listen.port == 18200
      and .endpoints["database-postgres"].protocol == "tcp"
      and .endpoints["database-postgres"].listen.host == "127.0.0.1"
      and .endpoints["database-postgres"].listen.port == 22000
      and (.endpoints["database-postgres"] | has("url") | not)
      and (.endpoints["database-postgres"] | has("visibility") | not)
    ' "$paired_runtime_manifest" >/dev/null
    ${pkgs.jq}/bin/jq -e '
      .bindings.parameters == {}
      and .bindings.secrets == ["betterAuthSecret"]
      and .descriptor.parameters.maxStorageMb.default == 512
    ' "$binding_policy" >/dev/null

    ${pkgs.jq}/bin/jq -e '
      .service.environment.HOME == "/var/lib/app-deployments/demo-project"
      and (.service.environment | has("HOST") | not)
      and (.service.environment | has("PORT") | not)
      and .service.NoNewPrivileges == true
      and .service.ProtectSystem == "strict"
      and .service.MemoryHigh == "768M"
      and .service.MemoryMax == "1G"
      and .service.MemorySwapMax == "0"
      and (.service.condition | endswith("-app-deployment-demo-project-artifact-condition"))
      and (.service.LoadCredential | index("betterAuthSecret:/run/secrets/demo-better-auth"))
      and (.service.after | index("podman-project-demo-project-database.service"))
      and (.service.after | index("app-deployment-demo-project-release-plan.service"))
      and .releasePlan.Type == "oneshot"
      and (.releasePlan.before | index("app-deployment-demo-project.service"))
      and .activation.Type == "oneshot"
      and .activation.User == "app-demo-project"
      and (.activation.after | index("app-deployment-demo-project-release-plan.service"))
      and .updateTimer.OnActiveSec == "2min"
      and .updateTimer.OnUnitActiveSec == "10min"
      and .updateTimer.hasOnBootSec == false
      and (.recovery.condition | endswith("-app-deployment-demo-project-artifact-condition"))
      and .recovery.TimeoutStartSec == "infinity"
      and .recoveryTimer.OnActiveSec == "4min"
      and (.caddy.extraConfig | contains("reverse_proxy 127.0.0.1:18200"))
      and (.caddy.extraConfig | contains("redir \"/old\" \"/new\" 307"))
      and (.caddy.extraConfig | contains("Cache-Control \"public, max-age=3600\""))
      and .container.image == "postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      and (.container.ports | index("127.0.0.1:22000:5432/tcp"))
      and .job.Type == "oneshot"
      and .job.User == "app-demo-project"
      and .job.NoNewPrivileges == true
      and .job.Nice == 10
      and .job.IOSchedulingClass == "idle"
      and (.job.condition | endswith("-app-deployment-demo-project-artifact-condition"))
      and (.job.after | index("app-deployment-demo-project-release-plan.service"))
      and (.job.LoadCredential | index("betterAuthSecret:/run/secrets/demo-better-auth"))
      and .job.timer.OnActiveSec == "15min"
      and .job.timer.OnUnitInactiveSec == "1d"
      and .job.timer.RandomizedDelaySec == "30min"
      and .trusted.serviceSandbox == []
      and .trusted.activationSandbox == []
      and .trusted.jobSandbox == []
      and .trusted.serviceUMask == "0027"
      and .trusted.updaterUsesSandbox == false
      and (.staticCaddy.extraConfig | contains("@project_metadata path /share/project/*"))
      and (.staticCaddy.extraConfig | contains("respond @project_metadata 404"))
      and (.tmpfiles | map(contains("/runtime/data")) | any)
    ' ${projectRuntime} >/dev/null
    touch $out
  '';
}
