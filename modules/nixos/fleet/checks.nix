{
  lib,
  nixpkgs,
  pkgs,
  self,
  system,
  ...
}:
let
  example = import ../../../examples/fleet {
    inherit nixpkgs system;
    modules = self.nixosModules;
    nixosLib = self.lib.nixos;
  };
in
{
  core-example = example.nixosConfigurations.core-01.config.system.build.toplevel;

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

}
