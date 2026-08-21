{
  lib,
  pkgs,
  ...
}:
let
  runtime = import ../project-runtime.nix { inherit lib; };
  descriptor = import ../project-descriptor.nix { inherit lib; };
  developmentDescriptor = ./fixtures/development.json;
  pairedDescriptor = ./fixtures/paired-v2.json;
  serviceDescriptor = ./fixtures/service-release.json;
  staticDescriptor = ./fixtures/static-release.json;
  cycleDescriptor = builtins.fromJSON (builtins.readFile ./fixtures/v2-cycle.json);
  incompleteDescriptor = builtins.fromJSON (builtins.readFile ./fixtures/v2-missing-release.json);
  tcpPathsDescriptor = builtins.fromJSON (builtins.readFile ./fixtures/v2-tcp-paths.json);
  action =
    name: body:
    toString (
      pkgs.writeShellScript name ''
        set -eu
        ${body}
      ''
    );
  installAction = action "runtime-fixture-install" ''
    state="$(project-context path state)"
    test -z "''${PROJECT_RUNTIME_QUERY+x}"
    test -z "''${PROJECT_STATE_DIR+x}"
    printf 'start\n' >> "$state/preparation.log"
    ${pkgs.coreutils}/bin/sleep 0.2
    printf 'end\n' >> "$state/preparation.log"
  '';
  queryAction =
    name: endpoint:
    action name ''
      project-context endpoint ${endpoint} listen-port
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
  pairedWorkloadAction =
    name:
    action "runtime-paired-${name}" ''
      state="$(project-context path state)"
      printf '%s\n' ${lib.escapeShellArg name} >> "$state/workloads.log"
      ${pkgs.coreutils}/bin/sleep 0.2
    '';
  pairedDevelopment = runtime.mkDevelopment {
    inherit pkgs;
    descriptorPath = pairedDescriptor;
    actions = {
      install = installAction;
      database = pairedWorkloadAction "database";
      serve = pairedWorkloadAction "web";
    };
    localParameters.flavour = "generated";
    localPortRange = {
      from = 33000;
      to = 33999;
    };
  };
  releaseAction =
    name:
    action name ''
      state="$(project-context path state)"
      printf '%s\n' ${lib.escapeShellArg name} >> "$state/release.log"
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
  pairedService = runtime.mkServiceRelease {
    inherit pkgs;
    descriptorPath = pairedDescriptor;
    actions = {
      serve = releaseAction "paired-release";
      prepare-release = releaseAction "prepare-release";
      migrate = releaseAction "migrate";
    };
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
  serviceClosure = pkgs.closureInfo {
    rootPaths = [ service.package ];
  };
in
{
  project-runtime =
    assert lib.all (app: builtins.isString app.program) (lib.attrValues development.apps);
    assert lib.all (app: builtins.isString app.program) (lib.attrValues pairedDevelopment.apps);
    assert
      !(builtins.tryEval (
        builtins.deepSeq (descriptor.normalize {
          descriptor = cycleDescriptor;
        }) true
      )).success;
    assert
      !(builtins.tryEval (
        builtins.deepSeq (descriptor.normalize {
          descriptor = incompleteDescriptor;
        }) true
      )).success;
    assert
      !(builtins.tryEval (
        builtins.deepSeq (descriptor.normalize {
          descriptor = tcpPathsDescriptor;
        }) true
      )).success;
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
            check-jsonschema --schemafile ${../../schemas/project-descriptor/v2.json} \
              ${pairedDescriptor} ${./fixtures/v2-cycle.json}
            if check-jsonschema --schemafile ${../../schemas/project-descriptor/v2.json} \
              ${./fixtures/v2-missing-release.json}; then
              echo "incomplete v2 descriptor unexpectedly passed its schema" >&2
              exit 1
            fi
            if check-jsonschema --schemafile ${../../schemas/project-descriptor/v2.json} \
              ${./fixtures/v2-tcp-paths.json}; then
              echo "TCP health paths unexpectedly passed the v2 descriptor schema" >&2
              exit 1
            fi

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

            paired_manifest="$root/paired-development.json"
            ${pkgs.jq}/bin/jq -n \
              --arg checkout "$checkout" \
              --arg state "$state" \
              --arg cache "$cache" \
              --arg runtime "$runtime_dir" \
              '{
                schemaVersion: 2,
                project: "runtime-paired-fixture",
                realization: "development",
                paths: {checkout: $checkout, state: $state, cache: $cache, runtime: $runtime},
                endpoints: {
                  database: {protocol: "tcp", listen: {host: "127.0.0.1", port: 33101}},
                  web: {
                    protocol: "http",
                    url: "https://paired.example",
                    hostNames: ["paired.example"],
                    visibility: "tailnet",
                    listen: {host: "127.0.0.1", port: 33102}
                  }
                },
                parameters: {flavour: "compatibility"},
                secrets: {token: "token"}
              }' > "$paired_manifest"
            check-jsonschema --schemafile ${../../schemas/project-runtime/v2.json} "$paired_manifest"
            test "$(PROJECT_RUNTIME_FILE="$paired_manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${pairedDevelopment.package}/bin/project-context endpoint database protocol)" = tcp
            test "$(PROJECT_RUNTIME_FILE="$paired_manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${pairedDevelopment.package}/bin/project-context endpoint web protocol)" = http
            assert_status 66 env PROJECT_RUNTIME_FILE="$paired_manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${pairedDevelopment.package}/bin/project-context endpoint database url

            rm -f "$state/workloads.log"
            PROJECT_RUNTIME_FILE="$paired_manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${pairedDevelopment.package}/bin/runtime-paired-fixture-project-runtime workload web
            test "$(cat "$state/workloads.log")" = web

            rm -f "$state/workloads.log" "$state/preparation.log"
            PROJECT_RUNTIME_FILE="$paired_manifest" PROJECT_SECRETS_DIR="$secrets" \
              ${pairedDevelopment.package}/bin/runtime-paired-fixture-project-runtime dev --only web
            grep -qx database "$state/workloads.log"
            grep -qx web "$state/workloads.log"

            invalid_tcp_publication="$root/invalid-tcp-publication.json"
            ${pkgs.jq}/bin/jq '.endpoints.database.url = "tcp://127.0.0.1:33101"' \
              "$paired_manifest" > "$invalid_tcp_publication"
            if check-jsonschema --schemafile ${../../schemas/project-runtime/v2.json} \
              "$invalid_tcp_publication"; then
              echo "published TCP Endpoint unexpectedly passed the v2 runtime schema" >&2
              exit 1
            fi
            assert_status 65 env PROJECT_RUNTIME_FILE="$invalid_tcp_publication" \
              ${pairedDevelopment.package}/bin/project-context endpoint database listen-port

            missing_http_url="$root/missing-http-url.json"
            ${pkgs.jq}/bin/jq 'del(.endpoints.web.url)' "$paired_manifest" > "$missing_http_url"
            if check-jsonschema --schemafile ${../../schemas/project-runtime/v2.json} \
              "$missing_http_url"; then
              echo "HTTP Endpoint without URL unexpectedly passed the v2 runtime schema" >&2
              exit 1
            fi
            assert_status 65 env PROJECT_RUNTIME_FILE="$missing_http_url" \
              ${pairedDevelopment.package}/bin/project-context endpoint web listen-port

            mismatched_protocol="$root/mismatched-protocol.json"
            ${pkgs.jq}/bin/jq '.endpoints.database = {
              protocol: "http",
              url: "http://127.0.0.1:33101",
              listen: .endpoints.database.listen
            }' "$paired_manifest" > "$mismatched_protocol"
            assert_status 65 env PROJECT_RUNTIME_FILE="$mismatched_protocol" \
              ${pairedDevelopment.package}/bin/project-context endpoint database listen-port

            paired_local_home="$root/paired-local-home"
            paired_local_runtime="$root/paired-local-runtime"
            mkdir -p "$paired_local_home" "$paired_local_runtime"
            test "$(cd "$checkout" && env -u PROJECT_RUNTIME_FILE \
              HOME="$paired_local_home" XDG_RUNTIME_DIR="$paired_local_runtime" \
              ${pairedDevelopment.package}/bin/project-context endpoint database protocol)" = tcp
            (cd "$checkout" && assert_status 66 env -u PROJECT_RUNTIME_FILE \
              HOME="$paired_local_home" XDG_RUNTIME_DIR="$paired_local_runtime" \
              ${pairedDevelopment.package}/bin/project-context endpoint database url)

            paired_release_manifest="$root/paired-release.json"
            ${pkgs.jq}/bin/jq -n \
              --arg state "$state" --arg runtime "$runtime_dir" \
              '{schemaVersion: 2, project: "runtime-paired-fixture", realization: "release",
                paths: {state: $state, runtime: $runtime},
                endpoints: {
                  serve: {protocol: "http", url: "https://paired.example",
                    listen: {host: "127.0.0.1", port: 33103}},
                  "database-postgres": {protocol: "tcp",
                    listen: {host: "127.0.0.1", port: 33104}}
                },
                parameters: {flavour: "release"}, secrets: {}}' > "$paired_release_manifest"
            check-jsonschema --schemafile ${../../schemas/project-runtime/v2.json} "$paired_release_manifest"
            test "$(PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context endpoint serve url)" = https://paired.example
            test "$(PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context endpoint serve host-names --json)" = '[]'
            test "$(PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context parameter flavour)" = release
            test "$(PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context auxiliary database postgres listen-port)" = 33104
            assert_status 66 env PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context auxiliary database missing listen-port
            assert_status 1 env PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context secret-file token
            assert_status 66 env PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context secret-file token --required
            invalid_release_project="$root/invalid-release-project.json"
            ${pkgs.jq}/bin/jq '.project = "wrong-project"' "$paired_release_manifest" \
              > "$invalid_release_project"
            assert_status 65 env PROJECT_RUNTIME_FILE="$invalid_release_project" \
              ${pairedService.package}/bin/project-context endpoint serve url
            invalid_release_protocol="$root/invalid-release-protocol.json"
            ${pkgs.jq}/bin/jq '.endpoints["database-postgres"].protocol = "http" 
              | .endpoints["database-postgres"].url = "http://127.0.0.1:33104"' \
              "$paired_release_manifest" > "$invalid_release_protocol"
            assert_status 65 env PROJECT_RUNTIME_FILE="$invalid_release_protocol" \
              ${pairedService.package}/bin/project-context endpoint serve url
            rm -f "$state/release.log"
            PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-release-runtime
            test "$(cat "$state/release.log")" = paired-release
            cmp ${pairedDescriptor} ${pairedService.package}/share/project/descriptor.json

            release_manifest="$root/release.json"
            ${pkgs.jq}/bin/jq -n \
              --arg state "$state" --arg runtime "$runtime_dir" \
              '{schemaVersion: 1, project: "runtime-service-fixture", realization: "release",
                paths: {state: $state, runtime: $runtime},
                endpoints: {default: {url: "https://fixture.example", listen: {host: "127.0.0.1", port: 32103}}},
                parameters: {}, secrets: {}}' > "$release_manifest"
            check-jsonschema --schemafile ${../../schemas/project-runtime/v1.json} "$release_manifest"
            rm -f "$state/release.log"
            PROJECT_RUNTIME_FILE="$release_manifest" ${service.package}/bin/project-release-runtime
            PROJECT_RUNTIME_FILE="$release_manifest" ${service.package}/bin/project-release-runtime backup
            PROJECT_RUNTIME_FILE="$release_manifest" ${service.package}/bin/activate-release
            test "$(tr '\n' ' ' < "$state/release.log")" = 'serve backup activation '
            test -f ${service.package}/share/runtime-service-fixture/value
            cmp ${serviceDescriptor} ${service.package}/share/project/descriptor.json

            test -f ${static.package}/index.html
            cmp ${staticDescriptor} ${static.package}/share/project/descriptor.json

            test -x ${development.package}/bin/runtime-fixture-project-runtime
            test -x ${pairedDevelopment.package}/bin/runtime-paired-fixture-project-runtime
            test -x ${service.package}/bin/project-release-runtime
            test -f ${development.package}/libexec/project-runtime/runtime.py
            test ! -e ${service.package}/libexec/project-runtime/runtime.py
            grep -Fq -- '-project-release-runtime-1/bin/project-release-runtime' \
              ${service.package}/bin/project-release-runtime
            if grep -Eq '/[^/]*python3[^/]*/?$' ${serviceClosure}/store-paths; then
              echo "service Release closure still contains Python" >&2
              exit 1
            fi
            touch $out
      '';
}
