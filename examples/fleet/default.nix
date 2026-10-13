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

in
{
  nixosConfigurations.core-01 = mkHost "core-01" [
    ./hosts/core-01/configuration.nix
  ];
}
