{
  config,
  lib,
  ...
}:
let
  vps = config.vps;
  caddyVirtualHostList = lib.attrValues vps.services.caddy.virtualHosts;
  generatedTypes = import ../inventory/generated-types.nix { inherit lib; };
  generatedInventory = import ../inventory/generated-inventory.nix { inherit lib; };

  generatedServices = generatedInventory.generatedServicesFor {
    baseDomain = vps.baseDomain;
    services = vps.services;
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

  options.vps.generated = {
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

  config = lib.mkIf vps.enable {
    vps.generated.services = generatedServices;
    vps.generated.healthUnits = generatedInventory.healthUnitsForServices generatedServices;
    vps.generated.ingressRoutes = generatedIngressRoutes;
  };
}
