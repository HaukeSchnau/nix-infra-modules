{
  description = "Synthetic two-host fleet using nix-infra-modules";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-infra-modules.url = "../..";
  };

  outputs =
    {
      nixpkgs,
      nix-infra-modules,
      ...
    }:
    import ./. {
      inherit nixpkgs;
      system = "x86_64-linux";
      modules = nix-infra-modules.nixosModules;
      nixosLib = nix-infra-modules.lib.nixos;
    };
}
