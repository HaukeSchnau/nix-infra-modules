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

  tcpForwardType = lib.types.submodule {
    options = {
      listenPort = lib.mkOption {
        type = lib.types.port;
      };
      upstreamPort = lib.mkOption {
        type = lib.types.port;
      };
    };
  };

  edgeIngressType = lib.types.submodule {
    options = {
      upstreamHost = lib.mkOption {
        type = lib.types.str;
      };
      internalIngressPort = lib.mkOption {
        type = lib.types.port;
      };
      routes = lib.mkOption {
        default = { };
        type = lib.types.attrsOf ingressRouteType;
      };
      tcpForwards = lib.mkOption {
        default = { };
        type = lib.types.attrsOf tcpForwardType;
      };
    };
  };

  mkDefaultEdgeIngress =
    {
      upstreamHost,
      internalIngressPort,
    }:
    {
      inherit upstreamHost internalIngressPort;
      routes = { };
      tcpForwards = { };
    };
in
{
  inherit
    edgeIngressType
    generatedServiceType
    ingressRouteType
    mkDefaultEdgeIngress
    tcpForwardType
    ;
}
