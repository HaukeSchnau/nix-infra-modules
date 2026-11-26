{
  nixpkgs,
  system,
  modules,
}:
let
  lib = nixpkgs.lib;

  mkHost =
    name: extraModules:
    lib.nixosSystem {
      inherit system;
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
