{
  lib,
  nixpkgs,
  pkgs,
  self,
  system,
  ...
}:
let
  example = import ../../../examples/two-vps-fleet {
    inherit nixpkgs system;
    modules = self.nixosModules;
    nixosLib = self.lib.nixos;
  };
in
{
  core-example = example.nixosConfigurations.core-01.config.system.build.toplevel;
  edge-example = example.nixosConfigurations.edge-01.config.system.build.toplevel;

  fleet-generated-services-example =
    let
      generatedServices = example.nixosConfigurations.core-01.config.vps.generated.services;
      serviceNames = map (service: service.name) generatedServices;
      healthUnits = example.nixosConfigurations.core-01.config.vps.generated.healthUnits;
    in
    pkgs.runCommand "fleet-generated-services-example" { } ''
      test '${toString (builtins.length generatedServices)}' = '2'
      test '${if builtins.elem "appDeployments" serviceNames then "yes" else "no"}' = 'yes'
      test '${if builtins.elem "caddy" serviceNames then "yes" else "no"}' = 'yes'
      test '${if builtins.elem "app-deployment-demo.service" healthUnits then "yes" else "no"}' = 'yes'
      test '${if builtins.elem "caddy.service" healthUnits then "yes" else "no"}' = 'yes'
      touch $out
    '';

  edge-contract-example =
    let
      contract = example.nixosConfigurations.core-01.config.vps.generated.edgeIngress;
      routeNames = lib.attrNames contract.routes;
    in
    pkgs.runCommand "edge-contract-example" { } ''
      test '${contract.upstreamHost}' = 'core-01'
      test '${toString contract.internalIngressPort}' = '8080'
      test '${if builtins.elem "admin.example.net" routeNames then "yes" else "no"}' = 'yes'
      test '${if builtins.elem "demo.example.net" routeNames then "yes" else "no"}' = 'yes'
      test '${toString contract.tcpForwardRanges.demo.listen.from}' = '22000'
      test '${toString contract.tcpForwardRanges.demo.upstream.to}' = '32002'
      touch $out
    '';
}
