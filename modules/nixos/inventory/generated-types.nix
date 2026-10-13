{ lib }:
let
  generatedServiceType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
      };
      displayName = lib.mkOption {
        type = lib.types.str;
      };
      category = lib.mkOption {
        type = lib.types.str;
      };
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
      };
      healthUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
      };
    };
  };

  ingressRouteType = lib.types.submodule {
    options = {
      hostName = lib.mkOption {
        type = lib.types.str;
      };
      tailscaleOnly = lib.mkOption {
        type = lib.types.bool;
      };
    };
  };

in
{
  inherit
    generatedServiceType
    ingressRouteType
    ;
}
