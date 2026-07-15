{
  config,
  lib,
  ...
}:
let
  vps = config.vps;
  cfg = vps.services.edgeIngress;
  generatedTypes = import ../inventory/generated-types.nix { inherit lib; };
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };
  tcpForwards = if cfg.upstream == null then { } else cfg.upstream.tcpForwards;
  tcpForwardRanges = if cfg.upstream == null then { } else cfg.upstream.tcpForwardRanges;
  sanitizeName = name: lib.replaceStrings [ "." "-" "*" ] [ "_" "_" "wildcard" ] name;
  validRange = range: range.from <= range.to;
  equalSizedRange =
    range: (range.listen.to - range.listen.from) == (range.upstream.to - range.upstream.from);
  validTcpForwardRanges = lib.all (
    range: validRange range.listen && validRange range.upstream && equalSizedRange range
  ) (lib.attrValues tcpForwardRanges);

  tcpForwardPorts = map (forward: forward.listenPort) (lib.attrValues tcpForwards);
  tcpForwardPortRanges = map (range: range.listen) (lib.attrValues tcpForwardRanges);

  expandTcpForwardRange =
    name: range:
    let
      listenPorts = lib.range range.listen.from range.listen.to;
      upstreamPorts = lib.range range.upstream.from range.upstream.to;
    in
    lib.zipListsWith (listenPort: upstreamPort: {
      name = "${name}-${toString listenPort}";
      value = { inherit listenPort upstreamPort; };
    }) listenPorts upstreamPorts;

  expandedTcpForwardRanges = lib.listToAttrs (
    lib.optionals validTcpForwardRanges (
      lib.flatten (lib.mapAttrsToList expandTcpForwardRange tcpForwardRanges)
    )
  );
  allTcpForwards = tcpForwards // expandedTcpForwardRanges;
  allTcpForwardPorts = map (forward: forward.listenPort) (lib.attrValues allTcpForwards);

  mkTcpForwardFrontend = name: forward: ''
    frontend ${sanitizeName name}
      bind :${toString forward.listenPort}
      mode tcp
      default_backend ${sanitizeName name}_backend
  '';

  mkTcpForwardBackend = name: forward: ''
    backend ${sanitizeName name}_backend
      mode tcp
      # Short upstream hostnames can resolve via libc search domains on the
      # host, but HAProxy's runtime DNS resolvers do not apply those suffixes.
      # Resolve once at load time and keep the stable Tailscale address.
      server upstream ${cfg.upstream.upstreamHost}:${toString forward.upstreamPort} init-addr libc
  '';
in
{
  imports = [
    ../fleet/foundation.nix
    ./caddy.nix
  ];

  options.vps.services.edgeIngress = {
    enable = lib.mkEnableOption "public edge ingress that fans out to a generated upstream VPS service contract";

    metadata = serviceMetadata.mkOptions {
      displayName = "Edge Ingress";
      category = "Infrastructure";
      healthUnits = [ "haproxy.service" ];
    };

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
        ]
        ++ lib.optionals (cfg.upstream != null) [
          {
            assertion = cfg.upstream.upstreamHost != "";
            message = "vps.services.edgeIngress.upstream.upstreamHost must not be empty.";
          }
        ]
        ++ lib.flatten (
          lib.mapAttrsToList (name: range: [
            {
              assertion = validRange range.listen;
              message = "vps.services.edgeIngress.upstream.tcpForwardRanges.${name}.listen.from must be less than or equal to listen.to.";
            }
            {
              assertion = validRange range.upstream;
              message = "vps.services.edgeIngress.upstream.tcpForwardRanges.${name}.upstream.from must be less than or equal to upstream.to.";
            }
            {
              assertion = equalSizedRange range;
              message = "vps.services.edgeIngress.upstream.tcpForwardRanges.${name} must map equal-sized listen and upstream ranges.";
            }
          ]) tcpForwardRanges
        );
      }

      (lib.mkIf (cfg.upstream != null) {
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
      })

      (lib.mkIf (allTcpForwards != { }) {
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

            ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList mkTcpForwardFrontend allTcpForwards)}

            ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList mkTcpForwardBackend allTcpForwards)}
          '';
        };

        systemd.services.haproxy.reloadTriggers = [
          config.environment.etc."haproxy.cfg".source
        ];

        networking.firewall = {
          allowedTCPPorts = lib.mkAfter tcpForwardPorts;
          allowedTCPPortRanges = lib.mkAfter tcpForwardPortRanges;
        };
      })
    ]
  );
}
