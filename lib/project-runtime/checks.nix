{
  lib,
  pkgs,
  ...
}:
let
  runtime = import ../project-runtime.nix { inherit lib; };
  developmentDescriptor = ./fixtures/development.json;
  serviceDescriptor = ./fixtures/service-release.json;
  staticDescriptor = ./fixtures/static-release.json;
  action =
    name: body:
    toString (
      pkgs.writeShellScript name ''
        set -eu
        ${body}
      ''
    );
  installAction = action "runtime-fixture-install" ''
    printf 'start\n' >> "$PROJECT_STATE_DIR/preparation.log"
    ${pkgs.coreutils}/bin/sleep 0.2
    printf 'end\n' >> "$PROJECT_STATE_DIR/preparation.log"
  '';
  queryAction =
    name: endpoint:
    action name ''
      "$PROJECT_RUNTIME_QUERY" endpoint ${endpoint} listen-port
    '';
  development = runtime.mkDevelopment {
    inherit pkgs;
    descriptorPath = developmentDescriptor;
    actions = {
      install = installAction;
      serve = queryAction "runtime-fixture-serve" "web";
      bundle = queryAction "runtime-fixture-bundle" "mobile";
    };
    localParameters.flavour = "generated";
    localPortRange = {
      from = 32000;
      to = 32999;
    };
  };
  releaseAction =
    name:
    action name ''
      printf '%s\n' ${lib.escapeShellArg name} >> "$PROJECT_STATE_DIR/release.log"
    '';
  service = runtime.mkServiceRelease {
    inherit pkgs;
    descriptorPath = serviceDescriptor;
    defaultAction = "serve";
    payloads = [
      (pkgs.runCommand "runtime-service-payload" { } ''
        mkdir -p $out/share/runtime-service-fixture
        echo payload > $out/share/runtime-service-fixture/value
      '')
    ];
    actions = {
      serve = releaseAction "serve";
      backup = releaseAction "backup";
    };
    activation = releaseAction "activation";
  };
  staticRoot = pkgs.runCommand "runtime-static-root" { } ''
    mkdir -p $out
    echo '<h1>fixture</h1>' > $out/index.html
  '';
  static = runtime.mkStaticRelease {
    inherit pkgs;
    descriptorPath = staticDescriptor;
    root = staticRoot;
  };
in
{
  project-runtime =
    assert lib.all (app: builtins.isString app.program) (lib.attrValues development.apps);
    pkgs.runCommand "project-runtime-interface-check"
      {
        nativeBuildInputs = [
          pkgs.check-jsonschema
          pkgs.coreutils
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail

            check-jsonschema --schemafile ${../../schemas/project-descriptor/v1.json} \
              ${developmentDescriptor} ${serviceDescriptor} ${staticDescriptor}

            root="$TMPDIR/runtime-check"
            checkout="$root/checkout"
            state="$root/state"
            cache="$root/cache"
            runtime_dir="$root/runtime"
            secrets="$root/secrets"
            mkdir -p "$checkout" "$state" "$cache" "$runtime_dir" "$secrets"
            printf 'secret\n' > "$secrets/token"

            write_development_manifest() {
              local file="$1" project="$2" realization="$3" parameter_key="$4"
              ${pkgs.jq}/bin/jq -n \
                --arg project "$project" \
                --arg realization "$realization" \
                --arg checkout "$checkout" \
                --arg state "$state" \
                --arg cache "$cache" \
                --arg runtime "$runtime_dir" \
                --arg parameter_key "$parameter_key" \
                '{
                  schemaVersion: 1,
                  project: $project,
                  realization: $realization,
                  paths: {checkout: $checkout, state: $state, cache: $cache, runtime: $runtime},
                  endpoints: {
                    web: {url: "http://127.0.0.1:32101", listen: {host: "127.0.0.1", port: 32101}},
                    mobile: {url: "http://127.0.0.1:32102", listen: {host: "127.0.0.1", port: 32102}}
                  },
                  ($parameter_key): {flavour: "compatibility"},
                  secrets: {token: "token"}
                }' > "$file"
            }

            manifest="$root/development.json"
            write_development_manifest "$manifest" runtime-fixture development parameters
            check-jsonschema --schemafile ${../../schemas/project-runtime/v1.json} "$manifest"

            test "$(PROJECT_RUNTIME_FILE="$manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${development.package}/bin/runtime-fixture-project-runtime serve)" = 32101
            test "$(PROJECT_RUNTIME_FILE="$manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${development.package}/bin/project-context parameter flavour)" = compatibility
            test "$(PROJECT_RUNTIME_FILE="$manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${development.package}/bin/project-context secret-file token --required)" = "$secrets/token"

            legacy="$root/legacy-settings.json"
            write_development_manifest "$legacy" runtime-fixture development settings
            test "$(PROJECT_RUNTIME_FILE="$legacy" PROJECT_SECRETS_DIR="$secrets" \
              ${development.package}/bin/project-context parameter flavour)" = compatibility

            assert_status() {
              local expected="$1"
              shift
              set +e
              "$@" >/dev/null 2>&1
              local actual="$?"
              set -e
              test "$actual" = "$expected"
            }

            invalid_project="$root/invalid-project.json"
            write_development_manifest "$invalid_project" wrong-project development parameters
            assert_status 65 env PROJECT_RUNTIME_FILE="$invalid_project" \
              ${development.package}/bin/runtime-fixture-project-runtime serve
            invalid_realization="$root/invalid-realization.json"
            write_development_manifest "$invalid_realization" runtime-fixture release parameters
            assert_status 65 env PROJECT_RUNTIME_FILE="$invalid_realization" \
              ${development.package}/bin/runtime-fixture-project-runtime serve
            assert_status 64 env PROJECT_RUNTIME_FILE="$manifest" \
              ${development.package}/bin/runtime-fixture-project-runtime undeclared

            unsafe="$root/unsafe-secret.json"
            ${pkgs.jq}/bin/jq '.secrets.token = "../token"' "$manifest" > "$unsafe"
            assert_status 66 env PROJECT_RUNTIME_FILE="$unsafe" PROJECT_SECRETS_DIR="$secrets" \
              ${development.package}/bin/project-context secret-file token --required

            rm -f "$state/preparation.log"
            PROJECT_RUNTIME_FILE="$manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${development.package}/bin/runtime-fixture-project-runtime install &
            first=$!
            PROJECT_RUNTIME_FILE="$manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${development.package}/bin/runtime-fixture-project-runtime install &
            second=$!
            wait "$first" "$second"
            test "$(tr '\n' ' ' < "$state/preparation.log")" = 'start end start end '

            local_home="$root/local-home"
            local_runtime="$root/local-runtime"
            mkdir -p "$local_home" "$local_runtime"
            web_port="$(cd "$checkout" && env -u PROJECT_RUNTIME_FILE \
              HOME="$local_home" XDG_RUNTIME_DIR="$local_runtime" \
              ${development.package}/bin/project-context endpoint web listen-port)"
            mobile_port="$(cd "$checkout" && env -u PROJECT_RUNTIME_FILE \
              HOME="$local_home" XDG_RUNTIME_DIR="$local_runtime" \
              ${development.package}/bin/project-context endpoint mobile listen-port)"
            test "$web_port" != "$mobile_port"
            (cd "$checkout" && assert_status 1 env -u PROJECT_RUNTIME_FILE \
              HOME="$local_home" XDG_RUNTIME_DIR="$local_runtime" \
              ${development.package}/bin/project-context secret-file token)
            (cd "$checkout" && assert_status 66 env -u PROJECT_RUNTIME_FILE \
              HOME="$local_home" XDG_RUNTIME_DIR="$local_runtime" \
              ${development.package}/bin/project-context secret-file token --required)
            second_checkout="$root/second-checkout"
            mkdir -p "$second_checkout"
            second_web_port="$(cd "$second_checkout" && env -u PROJECT_RUNTIME_FILE \
              HOME="$local_home" XDG_RUNTIME_DIR="$local_runtime" \
              ${development.package}/bin/project-context endpoint web listen-port)"
            test "$second_web_port" != "$web_port"
            test "$second_web_port" != "$mobile_port"

            release_manifest="$root/release.json"
            ${pkgs.jq}/bin/jq -n \
              --arg state "$state" --arg runtime "$runtime_dir" \
              '{schemaVersion: 1, project: "runtime-service-fixture", realization: "release",
                paths: {state: $state, runtime: $runtime},
                endpoints: {default: {url: "https://fixture.example", listen: {host: "127.0.0.1", port: 32103}}},
                parameters: {}, secrets: {}}' > "$release_manifest"
            check-jsonschema --schemafile ${../../schemas/project-runtime/v1.json} "$release_manifest"
            PROJECT_RUNTIME_FILE="$release_manifest" ${service.package}/bin/project-release-runtime
            PROJECT_RUNTIME_FILE="$release_manifest" ${service.package}/bin/project-release-runtime backup
            PROJECT_RUNTIME_FILE="$release_manifest" ${service.package}/bin/activate-release
            test "$(tr '\n' ' ' < "$state/release.log")" = 'serve backup activation '
            test -f ${service.package}/share/runtime-service-fixture/value
            cmp ${serviceDescriptor} ${service.package}/share/project/descriptor.json

            test -f ${static.package}/index.html
            cmp ${staticDescriptor} ${static.package}/share/project/descriptor.json

            test -x ${development.package}/bin/runtime-fixture-project-runtime
            test -x ${service.package}/bin/project-release-runtime
            touch $out
      '';
}
