{ lib, ... }:
{
  options.colors = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = "Shared color schemes and palettes used across this config.";
  };

  imports = [
    ./palettes.nix
    ./schemes.nix
    ./terminal.nix
    ./editors.nix
    ./starship.nix
  ];
}
