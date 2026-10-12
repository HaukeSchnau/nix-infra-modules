{
  lib,
  nixpkgs,
  pkgs,
  self,
  system,
  ...
}:
let
  mkFleetSystem = import ../../../checks/mk-fleet-system.nix {
    inherit lib self system;
  };
  example = import ../../../examples/two-vps-fleet {
    inherit nixpkgs system;
    modules = self.nixosModules;
    nixosLib = self.lib.nixos;
  };
  caddyInternalIngressSystem = mkFleetSystem "internal-ingress-01" [
    {
      vps.services.caddy = {
        enable = true;
        publicVirtualHosts.enable = false;
        internalIngress.enable = true;
        virtualHosts."app.example.net".backend.port = 8080;
      };
    }
  ];
in
{
  caddy-internal-ingress-example =
    let
      publicVirtualHostNames = lib.attrNames caddyInternalIngressSystem.config.services.caddy.virtualHosts;
      routeNames = lib.attrNames caddyInternalIngressSystem.config.vps.services.caddy.virtualHosts;
      extraConfig = caddyInternalIngressSystem.config.services.caddy.extraConfig;
      extraConfigFile = pkgs.writeText "caddy-extra-config" extraConfig;
    in
    pkgs.runCommand "caddy-internal-ingress-example" { } ''
      test '${toString (builtins.length publicVirtualHostNames)}' = '0'
      test '${if builtins.elem "app.example.net" routeNames then "yes" else "no"}' = 'yes'
      grep -q ':8080 {' ${extraConfigFile}
      grep -q 'host app.example.net' ${extraConfigFile}
      touch $out
    '';

  edge-tcp-range-example =
    let
      haproxyConfig = pkgs.writeText "edge-example-haproxy.cfg" example.nixosConfigurations.edge-01.config.services.haproxy.config;
    in
    pkgs.runCommand "edge-tcp-range-example" { } ''
      grep -q 'bind :22000' ${haproxyConfig}
      grep -q 'server upstream core-01:32000 init-addr libc' ${haproxyConfig}
      grep -q 'bind :22001' ${haproxyConfig}
      grep -q 'server upstream core-01:32001 init-addr libc' ${haproxyConfig}
      grep -q 'bind :22002' ${haproxyConfig}
      grep -q 'server upstream core-01:32002 init-addr libc' ${haproxyConfig}
      touch $out
    '';

  edge-tcp-forward-firewall =
    let
      edge = mkFleetSystem "edge-02" [
        {
          vps.services.edgeIngress = {
            enable = true;
            upstream = {
              upstreamHost = "core-01";
              internalIngressPort = 18081;
              routes = { };
              tcpForwards = {
                public = {
                  listenPort = 2201;
                  upstreamPort = 3201;
                };
                private = {
                  listenPort = 2202;
                  upstreamPort = 3202;
                  tailscaleOnly = true;
                };
              };
              tcpForwardRanges = { };
            };
          };
        }
      ];
      inherit (edge.config.networking) firewall;
    in
    assert builtins.elem 2201 firewall.allowedTCPPorts;
    assert !(builtins.elem 2202 firewall.allowedTCPPorts);
    assert builtins.elem 2202 firewall.interfaces.tailscale0.allowedTCPPorts;
    pkgs.runCommand "edge-tcp-forward-firewall" { } "touch $out";
}
