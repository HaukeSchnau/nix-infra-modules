{ lib, ... }:
let
  catalog = import ./service-catalog.nix { inherit lib; };
in
{
  options.vps.services = catalog.optionModules;
}
