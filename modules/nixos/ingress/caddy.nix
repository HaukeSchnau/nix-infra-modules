{ config, lib, ... }:
let
  vps = config.vps;
  cfg = vps.services.caddy;
  virtualHostList = lib.attrValues cfg.virtualHosts;
  virtualHostNames = map (route: route.hostName) virtualHostList;
  rawSiteList = lib.attrValues cfg.rawSites;
  rawSiteLabels = map (site: site.siteLabel) rawSiteList;
  extraConfigImports = map (path: "import ${path}") cfg.extraConfigImports;

  sanitizeMatcherName = name: "vps_" + lib.replaceStrings [ "." "-" "*" ] [ "_" "_" "wildcard" ] name;

  mkHandlerConfig =
    route:
    if route.extraConfig != "" then
      route.extraConfig
    else
      ''
        reverse_proxy ${route.upstream}
      '';

  mkRouteConfig =
    name: route:
    let
      matcherName = sanitizeMatcherName name;
      handlerConfig = mkHandlerConfig route;
      sourceRanges = lib.concatStringsSep " " (
        if route.sourceRanges == null then cfg.tailscaleSourceRanges else route.sourceRanges
      );
    in
    if route.tailscaleOnly then
      ''
        @${matcherName}Allowed remote_ip ${sourceRanges}
        handle @${matcherName}Allowed {
          ${handlerConfig}
        }

        respond 403
      ''
    else
      handlerConfig;
in
{
  options.vps.services.caddy = {
    enable = lib.mkEnableOption "Caddy reverse proxy";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/persist/caddy";
      description = "Caddy persistent state directory.";
    };

    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "203.0.113.10"
        "127.0.0.1"
      ];
      description = "Host interfaces to bind generated HTTPS virtual hosts to.";
    };

    tailscaleSourceRanges = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "127.0.0.1/32"
        "100.64.0.0/10"
        "::1/128"
        "fd7a:115c:a1e0::/48"
      ];
      description = "Source IP ranges allowed to reach tailnet-only VPS routes.";
    };

    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              hostName = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Hostname served by this Caddy virtual host.";
              };

              upstream = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "127.0.0.1:3000";
                description = "Reverse proxy upstream used when extraConfig is not set.";
              };

              tailscaleOnly = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Restrict this virtual host to configured Tailscale source ranges.";
              };

              sourceRanges = lib.mkOption {
                type = lib.types.nullOr (lib.types.listOf lib.types.str);
                default = null;
                description = "Source ranges for this route when tailscaleOnly is true; defaults to the VPS Caddy ranges.";
              };

              extraConfig = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Caddyfile directives placed inside the route handler.";
              };
            };
          }
        )
      );
      default = { };
      description = "VPS virtual hosts managed by the shared Caddy reverse proxy.";
    };

    rawSites = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              siteLabel = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Literal Caddy site label for a raw site block (for example `http://host:port`).";
              };

              extraConfig = lib.mkOption {
                type = lib.types.lines;
                description = "Raw Caddyfile directives placed inside the site block.";
              };
            };
          }
        )
      );
      default = { };
      description = "Raw Caddy site blocks for exceptional cases that do not fit the shared virtual host abstraction.";
    };

    extraConfigImports = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra Caddyfile fragments imported at top level.";
    };

    internalIngress = {
      enable = lib.mkEnableOption "tailnet-only internal Caddy ingress";

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Plain HTTP port exposed for trusted upstream ingress proxies on the tailnet.";
      };

      sourceRanges = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cfg.tailscaleSourceRanges;
        description = "Source ranges allowed to access the internal ingress port.";
      };
    };
  };

  config = lib.mkIf (vps.enable && cfg.enable) {
    assertions = [
      {
        assertion = lib.all (route: (route.extraConfig != "") != (route.upstream != null)) virtualHostList;
        message = "Each vps.services.caddy.virtualHosts entry must set exactly one of upstream or extraConfig.";
      }
      {
        assertion = lib.length virtualHostNames == lib.length (lib.unique virtualHostNames);
        message = "Each vps.services.caddy.virtualHosts entry must use a unique hostName.";
      }
      {
        assertion = lib.length rawSiteLabels == lib.length (lib.unique rawSiteLabels);
        message = "Each vps.services.caddy.rawSites entry must use a unique siteLabel.";
      }
      {
        assertion = lib.intersectLists virtualHostNames rawSiteLabels == [ ];
        message = "vps.services.caddy.rawSites siteLabel values must not overlap with virtual host hostName values.";
      }
    ];

    services.caddy = {
      enable = true;
      dataDir = toString cfg.dataDir;
      email = vps.caddy.acmeEmail;

      virtualHosts = lib.mapAttrs (_: route: {
        hostName = route.hostName;
        inherit (cfg) listenAddresses;
        extraConfig = mkRouteConfig route.hostName route;
      }) cfg.virtualHosts;

      extraConfig = lib.concatStringsSep "\n\n" (
        (lib.mapAttrsToList (_: site: ''
          ${site.siteLabel} {
            ${site.extraConfig}
          }
        '') cfg.rawSites)
        ++ extraConfigImports
      );
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = lib.mkIf cfg.internalIngress.enable [
      cfg.internalIngress.port
    ];

    systemd.tmpfiles.rules = [
      "d ${toString cfg.dataDir} 0750 caddy caddy -"
    ];

    vps.services.caddy.rawSites = lib.mkIf cfg.internalIngress.enable {
      "internal-ingress" = {
        siteLabel = ":${toString cfg.internalIngress.port}";
        extraConfig =
          let
            sourceRanges = lib.concatStringsSep " " cfg.internalIngress.sourceRanges;
          in
          lib.concatStringsSep "\n\n" (
            lib.mapAttrsToList (
              name: route:
              let
                matcherName = sanitizeMatcherName name;
              in
              ''
                @${matcherName}_host host ${route.hostName}
                @${matcherName}_allowed remote_ip ${sourceRanges}

                handle @${matcherName}_host {
                  handle @${matcherName}_allowed {
                    ${mkHandlerConfig route}
                  }

                  respond 403
                }
              ''
            ) cfg.virtualHosts
          );
      };
    };
  };
}
