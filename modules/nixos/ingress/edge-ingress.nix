{
  config,
  lib,
  ...
}:
let
  vps = config.vps;
  cfg = vps.services.edgeIngress;
  generatedTypes = import ../inventory/generated-types.nix { inherit lib; };
  tcpForwards = if cfg.upstream == null then { } else cfg.upstream.tcpForwards;
  sanitizeName = name: lib.replaceStrings [ "." "-" "*" ] [ "_" "_" "wildcard" ] name;

  tcpForwardPorts = map (forward: forward.listenPort) (lib.attrValues tcpForwards);

  mkTcpForwardFrontend = name: forward: ''
    frontend ${sanitizeName name}
      bind :${toString forward.listenPort}
      mode tcp
      default_backend ${sanitizeName name}_backend
  '';

  mkTcpForwardBackend = name: forward: ''
    backend ${sanitizeName name}_backend
      mode tcp
      # Bare hostnames such as "srv-1" resolve via libc search domains on the
      # host, but HAProxy's runtime DNS resolvers do not apply those suffixes.
      # Resolve once at load time and keep the stable Tailscale address.
      server upstream ${cfg.upstream.upstreamHost}:${toString forward.upstreamPort} init-addr libc
  '';
in
{
  options.vps.services.edgeIngress = {
    enable = lib.mkEnableOption "public edge ingress that fans out to a generated upstream VPS service contract";

    upstream = lib.mkOption {
      default = null;
      type = lib.types.nullOr generatedTypes.edgeIngressType;
      description = "Generated edge-ingress contract exported by the upstream application VPS.";
    };
  };

  config = lib.mkIf (vps.enable && cfg.enable) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.upstream != null;
            message = "vps.services.edgeIngress.enable requires vps.services.edgeIngress.upstream to be set.";
          }
          {
            assertion = cfg.upstream.upstreamHost != "";
            message = "vps.services.edgeIngress.upstream.upstreamHost must not be empty.";
          }
        ];

        vps.services.caddy.enable = true;

        vps.services.caddy.virtualHosts = lib.mapAttrs (_: route: {
          hostName = route.hostName;
          inherit (route) tailscaleOnly;
          extraConfig = ''
            reverse_proxy http://${cfg.upstream.upstreamHost}:${toString cfg.upstream.internalIngressPort} {
              header_up Host {host}
              header_up X-Forwarded-Host {host}
              header_up X-Forwarded-Proto {scheme}
            }
          '';
        }) cfg.upstream.routes;
      }

      (lib.mkIf (tcpForwards != { }) {
        services.haproxy = {
          enable = true;
          config = ''
            global
              log stdout format raw daemon info

            defaults
              log global
              mode tcp
              timeout connect 10s
              timeout client 5m
              timeout server 5m

            resolvers tailscale
              parse-resolv-conf

            ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList mkTcpForwardFrontend tcpForwards)}

            ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList mkTcpForwardBackend tcpForwards)}
          '';
        };

        systemd.services.haproxy.reloadTriggers = [
          config.environment.etc."haproxy.cfg".source
        ];

        networking.firewall.allowedTCPPorts = lib.mkAfter tcpForwardPorts;
      })
    ]
  );
}
