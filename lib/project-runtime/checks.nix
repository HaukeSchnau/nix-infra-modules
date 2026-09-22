# Runtime behaviour of release artifacts, development context queries and
# host release planning, using a descriptor authored through the modules.
{
  lib,
  pkgs,
  ...
}:
let
  runtime = import ../project-runtime.nix { inherit lib; };
  descriptorLib = import ../project-descriptor.nix { inherit lib; };
  project = {
    project = {
      name = "runtime-fixture";
      requirements = {
        database = {
          kind = "postgresql";
          majorVersion = 17;
        };
        uploads.kind = "directory";
        token.kind = "secret";
        optional = {
          kind = "secret";
          required = false;
        };
      };
      parameters.flavour.default = "plain";
      environment = {
        DATABASE_URL = {
          binding = "database";
          field = "url";
        };
        UPLOADS = {
          binding = "uploads";
          field = "path";
        };
        INSTANCE_ID.instance = "id";
        LITERAL = "it's literal";
        OPTIONAL = {
          binding = "optional";
          field = "value";
        };
      };
      release = {
        serviceEnvironment.WEB_PORT = {
          endpoint = "web";
          field = "listen.port";
        };
        commands.console.environment.TOKEN = {
          binding = "token";
          field = "value";
        };
        preDeployTasks.migrate = { };
        ociAuxiliaries.cache = {
          image = "example.invalid/cache@sha256:${lib.fixedWidthString 64 "0" ""}";
          ports.redis.containerPort = 6379;
        };
      };
    };
  };
  descriptor = import ../project-definition.nix { inherit lib; } { modules = [ project ]; };
  developmentDescriptor = descriptorLib.normalize {
    descriptor = descriptor // {
      development = {
        workloads.web = { };
        endpoints.web = { };
      };
    };
  };
  # Every action prints the environment it received.
  action = toString (
    pkgs.writeShellScript "runtime-fixture-action" ''
      printf '%s\n' "$DATABASE_URL" "$UPLOADS" "$INSTANCE_ID" "$LITERAL" \
        "''${WEB_PORT-unset}" "''${TOKEN-unset}" "''${OPTIONAL-unset}" "$@"
    ''
  );
  service = runtime.mkServiceRelease {
    inherit pkgs descriptor;
    actions = {
      web = action;
      console = action;
      migrate = action;
    };
  };
  staticFlake = import ../project-flake.nix { inherit lib; } {
    nixpkgs = null;
    systems = [ pkgs.stdenv.hostPlatform.system ];
    pkgsFor = _: pkgs;
    modules = [
      {
        project.name = "static-fixture";
        project.release.backend = "static";
      }
    ];
    release =
      { pkgs, ... }:
      {
        root = pkgs.writeTextDir "index.html" "<h1>fixture</h1>";
      };
  };
  static.package = staticFlake.packages.${pkgs.stdenv.hostPlatform.system}.projectRelease;
  development = runtime.developmentContext {
    inherit pkgs;
    descriptor = developmentDescriptor;
  };
  hostPolicy = pkgs.writeText "runtime-fixture-policy.json" (
    builtins.toJSON {
      inherit descriptor;
      managedJobs = [ ];
      bindings = {
        parameters = { };
        secrets = [ "token" ];
        resources = {
          database = {
            kind = "postgresql";
            majorVersion = 17;
            host = "/run/postgresql";
            port = 5432;
            database = "fixture";
            user = "fixture";
            url = "postgresql:///fixture";
          };
          uploads = {
            kind = "directory";
            path = "/var/lib/fixture/uploads";
            persistent = true;
          };
          token = {
            kind = "secret";
            credential = "token";
          };
        };
      };
    }
  );
  serviceClosure = pkgs.closureInfo { rootPaths = [ service.package ]; };
in
{
  project-runtime =
    pkgs.runCommand "project-runtime-check"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.diffutils
        ];
      }
      ''
        set -euo pipefail
        root="$TMPDIR/runtime"
        mkdir -p "$root/state" "$root/runtime" "$root/secrets" "$root/checkout" "$root/cache"
        printf 'secret\n' > "$root/secrets/token"
        export PROJECT_SECRETS_DIR="$root/secrets"

        status() {
          local expected="$1"
          shift
          set +e
          "$@" >/dev/null 2>&1
          local actual="$?"
          set -e
          test "$actual" = "$expected"
        }

        release="$root/release.json"
        jq -n --arg root "$root" --slurpfile policy ${hostPolicy} '{
          schemaVersion: 3, project: "runtime-fixture", realization: "release",
          instanceId: "fixture:release", revision: "0123456789abcdef0123456789abcdef01234567",
          paths: {state: ($root + "/state"), runtime: ($root + "/runtime")},
          endpoints: {
            web: {protocol: "http", url: "https://fixture.example", listen: {host: "127.0.0.1", port: 8080}},
            "cache-redis": {protocol: "tcp", listen: {host: "127.0.0.1", port: 6379}}
          },
          parameters: {}, secrets: {token: "token"},
          bindings: $policy[0].bindings.resources
        }' > "$release"
        export PROJECT_RUNTIME_FILE="$release"
        context=${service.package}/bin/project-context

        # Actions receive common, service and command environments, and unset absent optionals.
        OPTIONAL=inherited ${lib.getExe service.package} > web.out
        diff web.out - <<'EOF'
        postgresql:///fixture
        /var/lib/fixture/uploads
        fixture:release
        it's literal
        8080
        unset
        unset
        EOF
        ${lib.getExe service.package} console argument > console.out
        test "$(sed -n 6p console.out)" = secret
        test "$(sed -n 8p console.out)" = argument

        test "$($context endpoint web url)" = https://fixture.example
        test "$($context auxiliary cache redis listen-port)" = 6379
        test "$($context parameter flavour)" = plain
        test "$($context binding token value)" = secret
        test "$($context secret-file token --required)" = "$root/secrets/token"
        test "$($context revision)" = 0123456789abcdef0123456789abcdef01234567
        $context snapshot | jq -e '.instanceId == "fixture:release" and .bindings.uploads.persistent' >/dev/null
        eval "$($context environment console)"
        test "$TOKEN" = secret && test "$LITERAL" = "it's literal"
        status 1 $context secret-file optional
        status 64 $context endpoint
        status 66 $context auxiliary cache missing listen-port

        jq '.project = "other"' "$release" > wrong.json
        PROJECT_RUNTIME_FILE=wrong.json status 65 $context path state
        jq '.bindings.uploads.persistent = false' "$release" > transient.json
        PROJECT_RUNTIME_FILE=transient.json status 65 $context path state
        jq 'del(.endpoints["cache-redis"])' "$release" > missing.json
        PROJECT_RUNTIME_FILE=missing.json status 65 $context path state

        # Development context requires checkout and cache paths.
        jq --arg root "$root" '.realization = "development" | del(.revision)
          | .paths += {checkout: ($root + "/checkout"), cache: ($root + "/cache")}
          | .endpoints = {web: .endpoints.web} | .bindings.database.dataDirectory = ($root + "/postgres")' \
          "$release" > development.json
        PROJECT_RUNTIME_FILE=development.json ${development}/bin/project-context path checkout
        jq 'del(.paths.cache)' development.json > no-cache.json
        PROJECT_RUNTIME_FILE=no-cache.json status 65 ${development}/bin/project-context path state

        # The host accepts the candidate it was compiled for and rejects topology changes.
        planner=${lib.getExe (runtime.package pkgs)}
        $planner plan-release --host ${hostPolicy} --candidate ${service.package}/share/project/descriptor.json \
          | jq -e '.compatible and .releasePlan.preDeployOrder == ["migrate"]' >/dev/null
        jq '.release.action = "serve"' ${service.package}/share/project/descriptor.json > moved.json
        $planner plan-release --host ${hostPolicy} --candidate moved.json \
          | jq -e '.compatible | not' >/dev/null

        test -f ${static.package}/index.html
        test -f ${static.package}/share/project/descriptor.json
        if grep -Eq 'python3' ${serviceClosure}/store-paths; then
          echo "service Release closure contains Python" >&2
          exit 1
        fi
        touch $out
      '';
}
