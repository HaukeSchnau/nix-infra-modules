# Flake outputs every Project repository needs. Merge the result into the
# repository's own outputs:
#
#   outputs = { nixpkgs, nix-infra-modules, ... }:
#     nix-infra-modules.lib.projectFlake {
#       inherit nixpkgs;
#       modules = [ ./project.nix ];
#       release = { pkgs, descriptor }: { payloads = [ app ]; actions.web = serve; };
#     };
#
# `release` returns the arguments of mkServiceRelease (payloads, actions,
# activation) or mkStaticRelease (root), matching `release.backend`.
{ lib }:
let
  projectRuntime = import ./project-runtime.nix { inherit lib; };
in
{
  nixpkgs,
  modules,
  release,
  systems ? [
    "aarch64-linux"
    "x86_64-linux"
  ],
  pkgsFor ? system: nixpkgs.legacyPackages.${system},
  specialArgs ? { },
}:
let
  descriptor = import ./project-definition.nix { inherit lib; } { inherit modules specialArgs; };
  releaseFor =
    system:
    let
      pkgs = pkgsFor system;
      arguments = release { inherit pkgs descriptor; } // {
        inherit pkgs descriptor;
      };
    in
    if descriptor.release.backend == "static" then
      projectRuntime.mkStaticRelease arguments
    else
      projectRuntime.mkServiceRelease arguments;
  releases = lib.genAttrs systems releaseFor;
in
{
  lib.project = descriptor;
  packages = lib.mapAttrs (_: built: { projectRelease = built.package; }) releases;
  checks = lib.mapAttrs (
    _: built:
    {
      projectRelease = built.package;
    }
    // lib.mapAttrs' (name: lib.nameValuePair "projectRelease-${name}") built.checks
  ) releases;
}
