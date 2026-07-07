{ lib }:
let
  mkMetadataOptions =
    {
      displayName,
      category,
      healthUnits,
    }:
    {
      metadata = {
        displayName = lib.mkOption {
          type = lib.types.str;
          default = displayName;
          description = "Human-friendly name used in generated VPS inventory output.";
        };

        category = lib.mkOption {
          type = lib.types.str;
          default = category;
          description = "Grouping label used by generated VPS inventory output.";
        };

        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Primary domain shown in generated VPS inventory output.";
        };

        health.units = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = healthUnits;
          description = "Systemd units checked by the generated vps-health-check command.";
        };
      };
    };

  services = {
    caddy = {
      displayName = "Caddy";
      category = "Infrastructure";
      healthUnits = [ "caddy.service" ];
    };

    edgeIngress = {
      displayName = "Edge Ingress";
      category = "Infrastructure";
      healthUnits = [ "haproxy.service" ];
    };

    appDeployments = {
      displayName = "App Deployments";
      category = "Applications";
      healthUnits = [ ];
    };

    podman = {
      displayName = "Podman";
      category = "Infrastructure";
      healthUnits = [
        "podman.socket"
        "podman-network-proxy.service"
      ];
    };

    gitMirrors = {
      displayName = "Git Mirrors";
      category = "Developer";
      healthUnits = [ ];
    };

    githubRunner = {
      displayName = "GitHub Runner";
      category = "Developer";
      healthUnits = [ ];
    };

    giteaActionsRunner = {
      displayName = "Gitea Actions Runner";
      category = "Developer";
      healthUnits = [ ];
    };
  };
in
{
  inherit mkMetadataOptions services;

  optionModules = lib.mapAttrs (_: service: mkMetadataOptions service) services;
}
