{
  nixpkgs,
  system,
  modules,
  nixosLib,
}:
let
  lib = nixpkgs.lib;

  mkHost =
    name: extraModules:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit nixosLib;
      };
      modules = [
        modules.fleet
        ./hosts/common.nix
        {
          networking.hostName = name;
        }
      ]
      ++ extraModules;
    };

  core = mkHost "core-01" [
    ./hosts/core-01/configuration.nix
  ];
in
{
  nixosConfigurations = {
    core-01 = core;
    edge-01 = mkHost "edge-01" [
      {
        vps.services.edgeIngress.upstream = core.config.vps.generated.edgeIngress;
      }
      ./hosts/edge-01/configuration.nix
    ];
  };
}
