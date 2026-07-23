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
in
{
  app-deployments-contract = pkgs.runCommand "app-deployments-contract" { } ''
    ${pkgs.bash}/bin/bash -n ${serviceUpdateScript}
    ${pkgs.bash}/bin/bash -n ${staticUpdateScript}
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
}
