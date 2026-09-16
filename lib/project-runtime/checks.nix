{
  lib,
  pkgs,
  ...
}:
let
  runtime = import ../project-runtime.nix { inherit lib; };
  descriptor = import ../project-descriptor.nix { inherit lib; };
  developmentDescriptor = ./fixtures/development.json;
  pairedV2Descriptor = ./fixtures/paired-v2.json;
  pairedDescriptor = ./fixtures/paired-v3.json;
  pairedNormalized = descriptor.normalize {
    descriptor = builtins.fromJSON (builtins.readFile pairedDescriptor);
  };
  invalidBackgroundTaskDescriptor = lib.recursiveUpdate pairedNormalized {
    development.workloads.web.kind = "task";
  };
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
  commandAction = action "runtime-command-console" ''
    state="$(project-context path state)"
    printf '%s\n' "$@" > "$state/command.log"
  '';
  releaseAction =
    name:
    action name ''
      state="$(project-context path state)"
      printf '%s\n' ${lib.escapeShellArg name} >> "$state/release.log"
    '';
  service = runtime.mkServiceRelease {
    inherit pkgs;
    descriptor = builtins.fromJSON (builtins.readFile serviceDescriptor);
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
      console = commandAction;
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
    assert pairedNormalized.development.workloads.database.lifecycle == "on-demand";
    assert pairedNormalized.development.workloads.web.lifecycle == "background";
    assert
      !(builtins.tryEval (
        builtins.deepSeq (descriptor.normalize {
          descriptor = invalidBackgroundTaskDescriptor;
        }) true
      )).success;
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
              ${pairedV2Descriptor} ${./fixtures/v2-cycle.json}
            check-jsonschema --schemafile ${../../schemas/project-descriptor/v3.json} \
              ${pairedDescriptor}
            invalid_background_task="$TMPDIR/invalid-background-task.json"
            ${pkgs.jq}/bin/jq '.development.workloads.web.kind = "task"' \
              ${pairedDescriptor} > "$invalid_background_task"
            if check-jsonschema --schemafile ${../../schemas/project-descriptor/v3.json} \
              "$invalid_background_task"; then
              echo "background task unexpectedly passed the v3 descriptor schema" >&2
              exit 1
            fi
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

            assert_status() {
              local expected="$1"
              shift
              set +e
              "$@" >/dev/null 2>&1
              local actual="$?"
              set -e
              test "$actual" = "$expected"
            }

            paired_release_manifest="$root/paired-release.json"
            ${pkgs.jq}/bin/jq -n \
              --arg state "$state" --arg runtime "$runtime_dir" \
              '{schemaVersion: 2, project: "runtime-paired-fixture", realization: "release",
                revision: "0123456789abcdef0123456789abcdef01234567",
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
              ${pairedService.package}/bin/project-context revision)" = 0123456789abcdef0123456789abcdef01234567
            PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-context snapshot \
              | ${pkgs.jq}/bin/jq -e '
                .schemaVersion == 1
                and .project == "runtime-paired-fixture"
                and .realization == "release"
                and .revision == "0123456789abcdef0123456789abcdef01234567"
                and .parameters.flavour == "release"
                and .endpoints.serve.url == "https://paired.example"
                and .endpoints["database-postgres"].listen.port == 33104
                and .secretFiles == {}
              ' >/dev/null
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

            rm -f "$state/command.log"
            PROJECT_RUNTIME_FILE="$paired_release_manifest" \
              ${pairedService.package}/bin/project-release-runtime console release-argument
            test "$(cat "$state/command.log")" = release-argument

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
            diff <(${pkgs.jq}/bin/jq --sort-keys . ${serviceDescriptor}) <(${pkgs.jq}/bin/jq --sort-keys . ${service.package}/share/project/descriptor.json)

            test -f ${static.package}/index.html
            cmp ${staticDescriptor} ${static.package}/share/project/descriptor.json

            test -x ${service.package}/bin/project-release-runtime
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
