{ lib, pkgs, ... }:
let
  runtime = import ../project-runtime.nix { inherit lib; };
  descriptors = import ../project-descriptor.nix { inherit lib; };
  descriptorPath = ./fixtures/requirements-v4.json;
  descriptor = lib.importJSON descriptorPath;
  developmentOnly = descriptor // {
    release = null;
    environment = builtins.removeAttrs descriptor.environment [ "release" ];
  };
  invalidProvider = lib.recursiveUpdate developmentOnly {
    development.providers.database.workload = "missing";
  };
  implementation = toString (
    pkgs.writeShellScript "binding-fixture-action" ''
      set -eu
      printf '%s\n' "$DATABASE_URL" "$UPLOADS" "$TOKEN" "$INSTANCE_ID" "$LITERAL" "$WEB_PORT" "''${OPTIONAL+unexpected}"
    ''
  );
  development = runtime.mkDevelopment {
    inherit pkgs descriptorPath;
    actions = {
      web = implementation;
      database = implementation;
      prepare = implementation;
    };
  };
  release = runtime.mkServiceRelease {
    inherit pkgs descriptorPath;
    actions.web = implementation;
  };
in
{
  project-bindings =
    assert (descriptors.normalize { descriptor = developmentOnly; }).release == null;
    assert
      !(builtins.tryEval (
        builtins.deepSeq (descriptors.normalize { descriptor = invalidProvider; }) true
      )).success;
    pkgs.runCommand "project-binding-contract-check"
      {
        nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.jsonschema ])) ];
      }
      ''
        export DEVELOPMENT_RUNTIME=${lib.getExe development.package}
        export RELEASE_RUNTIME=${lib.getExe release.package}
        export BINDING_DESCRIPTOR=${descriptorPath}
        export DESCRIPTOR_SCHEMA=${../../schemas/project-descriptor/v4.json}
        export RUNTIME_SCHEMA=${../../schemas/project-runtime/v3.json}
        export JQ=${lib.getExe pkgs.jq}
        export RELEASE_COMPATIBILITY=${../../modules/nixos/deploy/project-release-compatibility.jq}
        python ${./bindings_test.py}
        touch "$out"
      '';
}
