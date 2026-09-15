{ lib }:
{
  modules,
  specialArgs ? { },
}:
let
  evaluated = lib.evalModules {
    modules = [ ../modules/project ] ++ modules;
    inherit specialArgs;
  };
in
(import ./project-descriptor.nix { inherit lib; }).normalize {
  descriptor = evaluated.config.project.declaration;
}
