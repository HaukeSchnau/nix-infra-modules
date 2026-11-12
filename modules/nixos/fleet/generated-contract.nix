{
  config,
  lib,
  ...
}:
let
  fleet = config.fleet;
  caddyVirtualHostList = lib.attrValues fleet.services.caddy.virtualHosts;
  generatedTypes = import ../inventory/generated-types.nix { inherit lib; };
  generatedInventory = import ../inventory/generated-inventory.nix { inherit lib; };

  generatedServices = generatedInventory.generatedServicesFor {
    baseDomain = fleet.baseDomain;
    services = fleet.services;
  };

  generatedIngressRoutes = lib.listToAttrs (
    builtins.map (
      route:
      lib.nameValuePair route.hostName {
        inherit (route) hostName tailscaleOnly;
      }
    ) caddyVirtualHostList
  );
in
{
  imports = [
    ./foundation.nix
    ../ingress/caddy.nix
  ];

  options.fleet.generated = {
    services = lib.mkOption {
      default = [ ];
      type = lib.types.listOf generatedTypes.generatedServiceType;
      description = "Resolved metadata for enabled fleet services.";
    };

    healthUnits = lib.mkOption {
      default = [ ];
      type = lib.types.listOf lib.types.str;
      description = "Unique health-check systemd units derived from enabled fleet services.";
    };

    ingressRoutes = lib.mkOption {
      default = { };
      type = lib.types.attrsOf generatedTypes.ingressRouteType;
      description = "Resolved Caddy ingress routes keyed by served hostname.";
    };
  };

  config = lib.mkIf fleet.enable {
    fleet.generated.services = generatedServices;
    fleet.generated.healthUnits = generatedInventory.healthUnitsForServices generatedServices;
    fleet.generated.ingressRoutes = generatedIngressRoutes;
  };
}
