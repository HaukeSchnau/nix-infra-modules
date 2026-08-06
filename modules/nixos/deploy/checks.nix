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
  projectSystem = mkFleetSystem "project-01" [
    {
      vps.services.appDeployments = {
        enable = true;
        apps.demo-project = projectApp;
      };
      vps.appDeployments.webhook.enable = false;
    }
  ];
  projectService = projectSystem.config.systemd.services.app-deployment-demo-project;
  projectActivationService =
    projectSystem.config.systemd.services.app-deployment-demo-project-activate;
  projectRecoveryService =
    projectSystem.config.systemd.services.app-deployment-demo-project-health-recovery;
  projectUpdateScript =
    projectSystem.config.systemd.services.app-deployment-demo-project-update.serviceConfig.ExecStart;
  projectStartScript = projectService.serviceConfig.ExecStart;
  projectActivationScript = projectActivationService.serviceConfig.ExecStart;
  projectJobService = projectSystem.config.systemd.services.app-deployment-demo-project-job-cleanup;
  projectJobScript = projectJobService.serviceConfig.ExecStart;
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
        condition = projectService.unitConfig.ConditionPathIsExecutable;
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
        condition = projectRecoveryService.unitConfig.ConditionPathIsExecutable;
        inherit (projectRecoveryService.serviceConfig) TimeoutStartSec;
      };
      recoveryScript = projectRecoveryService.serviceConfig.ExecStart;
      job = {
        inherit (projectJobService) after wants;
        condition = projectJobService.unitConfig.ConditionPathIsExecutable;
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
              OnUnitActiveSec
              Persistent
              RandomizedDelaySec
              Unit
              ;
          };
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
    test '${toString normalizedProjectDescriptor.parameters.maxStorageMb.default}' = 512
    test '${
      if normalizedProjectDescriptor.secrets.betterAuthSecret.required then "required" else "optional"
    }' = required
    test '${toString (builtins.elemAt normalizedProjectDescriptor.release.ingress.redirects 0).status}' = 307
    test '${normalizedProjectDescriptor.release.ociAuxiliaries.database.ports.postgres.protocol}' = tcp

    test '${
      if descriptorEvaluationSucceeds (conciseProjectDescriptor // { schemaVersion = 2; }) then
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
    }' = rejected
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
    }' = rejected

    ${pkgs.bash}/bin/bash -n ${projectUpdateScript}
    ${pkgs.bash}/bin/bash -n ${projectStartScript}
    ${pkgs.bash}/bin/bash -n ${projectActivationScript}
    ${pkgs.bash}/bin/bash -n ${projectJobScript}
    grep -Fq 'share/project/descriptor.json' ${projectUpdateScript}
    grep -Fq 'jq -S .' ${projectUpdateScript}
    grep -Fq -- '-diffutils-' ${projectUpdateScript}
    grep -Fq 'app-deployment-demo-project-activate.service' ${projectUpdateScript}
    grep -Fq 'rollback activation' ${projectUpdateScript}
    grep -Fq 'PROJECT_RUNTIME_FILE=' ${projectStartScript}
    grep -Fq 'PROJECT_SECRETS_DIR=' ${projectStartScript}
    ! grep -Fq 'activate-release' ${projectStartScript}
    grep -Fq '.release.activationExecutable // empty' ${projectActivationScript}
    grep -Fq ' cleanup' ${projectJobScript}

    expected_descriptor="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-project-release-descriptor-demo-project.json' ${projectUpdateScript} | head -n 1)"
    runtime_manifest="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-project-release-runtime-demo-project.json' ${projectStartScript} | head -n 1)"
    job_runtime_manifest="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-project-release-runtime-demo-project.json' ${projectJobScript} | head -n 1)"
    test "$runtime_manifest" = "$job_runtime_manifest"
    ${pkgs.jq}/bin/jq -e '
      .schemaVersion == 1
      and .project == "demo-project"
      and .release.activationExecutable == "activate-release"
      and (.release | has("backend") | not)
    ' "$expected_descriptor" >/dev/null
    ${pkgs.jq}/bin/jq -e '
      .schemaVersion == 1
      and .project == "demo-project"
      and .realization == "release"
      and .endpoints.default.url == "https://demo-project.example.net"
      and .endpoints.default.listen.host == "127.0.0.1"
      and .endpoints.default.listen.port == 18200
      and .endpoints["database-postgres"].url == "tcp://127.0.0.1:22000"
      and .parameters.maxStorageMb == 512
      and .secrets.betterAuthSecret == "betterAuthSecret"
    ' "$runtime_manifest" >/dev/null

    ${pkgs.jq}/bin/jq -e '
      .service.environment.HOME == "/var/lib/app-deployments/demo-project"
      and (.service.environment | has("HOST") | not)
      and (.service.environment | has("PORT") | not)
      and .service.NoNewPrivileges == true
      and .service.ProtectSystem == "strict"
      and .service.MemoryHigh == "768M"
      and .service.MemoryMax == "1G"
      and .service.MemorySwapMax == "0"
      and (.service.condition | endswith("/current/bin/project-release-runtime"))
      and (.service.LoadCredential | index("betterAuthSecret:/run/secrets/demo-better-auth"))
      and (.service.after | index("podman-project-demo-project-database.service"))
      and .activation.Type == "oneshot"
      and .activation.User == "app-demo-project"
      and .updateTimer.OnActiveSec == "2min"
      and .updateTimer.OnUnitActiveSec == "10min"
      and .updateTimer.hasOnBootSec == false
      and (.recovery.condition | endswith("/current/bin/project-release-runtime"))
      and .recovery.TimeoutStartSec == "70s"
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
      and (.job.condition | endswith("/current/bin/project-release-runtime"))
      and (.job.LoadCredential | index("betterAuthSecret:/run/secrets/demo-better-auth"))
      and .job.timer.OnActiveSec == "15min"
      and .job.timer.OnUnitActiveSec == "1d"
      and .job.timer.RandomizedDelaySec == "30min"
      and (.staticCaddy.extraConfig | contains("@project_metadata path /share/project/*"))
      and (.staticCaddy.extraConfig | contains("respond @project_metadata 404"))
      and (.tmpfiles | map(contains("/runtime/data")) | any)
    ' ${projectRuntime} >/dev/null
    touch $out
  '';
}
