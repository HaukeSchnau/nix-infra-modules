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
  normalized = descriptors.normalize { inherit descriptor; };
  contextConfig = pkgs.writeText "binding-fixture-context.json" (
    builtins.toJSON {
      schemaVersion = 1;
      descriptorSchemaVersion = 4;
      runtimeSchemaVersion = 3;
      inherit (normalized) project requirements;
      realization = "development";
      endpoints = builtins.attrNames normalized.development.endpoints;
      endpointProtocols = lib.mapAttrs (_: endpoint: endpoint.protocol) normalized.development.endpoints;
      parameterDefinitions = normalized.parameters;
      secrets = builtins.attrNames normalized.secrets;
      environment = normalized.environment.development;
    }
  );
  # Exercise the context/environment interface consumed by the native adapter.
  development = pkgs.writeShellScript "binding-fixture-native-context" ''
    set -eu
    context() {
      ${pkgs.python3}/bin/python ${./.}/runtime.py --config ${contextConfig} context "$@"
    }
    if [ "$1" = context ]; then
      shift
      context "$@"
    else
      exports="$(context environment "$1")"
      eval "$exports"
      exec ${implementation}
    fi
  '';
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
        export DEVELOPMENT_RUNTIME=${development}
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
