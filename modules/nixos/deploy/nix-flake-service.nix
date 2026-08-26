app:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  internal = app.__appDeploymentsInternal or false;
  declaredApp = builtins.removeAttrs app [
    "name"
    "__appDeploymentsInternal"
  ];
  hasSops = options ? sops;
  projectDescriptor = import ../../../lib/project-descriptor.nix { inherit lib; };
  cfg = lib.recursiveUpdate {
    enable = true;
    public = false;
    backend = "service";
    host = "127.0.0.1";
    port = null;
    package = "default";
    executable = null;
    environment = { };
    environmentFiles = [ ];
    path = [ ];
    runtime = {
      isolation = "isolated";
      user = null;
      group = null;
      home = null;
      workingDirectory = null;
      protectHome = true;
      readWritePaths = [ ];
    };
    stateDirs = [ ];
    preStart = "";
    serviceConfig = { };
    unitDependencies = {
      after = [ ];
      wants = [ ];
      requires = [ ];
    };
    project = null;
    static.extraConfig = "";
    delivery = {
      mode = "source";
      cacheStore = "https://cache.example.net/nix";
    };
    source = {
      branch = "main";
      netrcHost = "git.example.net";
      username = "deploy";
      giteaTokenSecretName = null;
    };
    health = {
      host = "127.0.0.1";
      hostHeader = null;
      headers = { };
      paths = [ "/" ];
      startupTimeoutSec = 60;
      intervalSec = 2;
      requestTimeoutSec = 5;
    };
    autoUpdate = {
      enable = true;
      interval = "10min";
      onBootSec = "2min";
    };
  } app;

  name = cfg.name;
  isService = cfg.backend == "service";
  isProject = cfg.project != null;
  descriptor =
    if isProject then
      projectDescriptor.normalize {
        descriptor = cfg.project.descriptor;
        expectedProject = name;
      }
    else
      null;
  projectRelease = if isProject then descriptor.release else null;
  projectSecrets = if isProject then cfg.project.secrets else { };
  projectActivationExecutable = if isProject then projectRelease.activationExecutable else null;
  projectStateDirectories = if isProject then projectRelease.stateDirectories else [ ];
  projectAuxiliaries = if isProject then projectRelease.ociAuxiliaries else { };
  projectAuxiliaryPorts = if isProject then cfg.project.auxiliaryPorts else { };
  projectJobs = if isProject then cfg.project.jobs else { };
  projectMemory = if isProject then cfg.project.resources.memory else { };
  projectRuntimeSchemaVersion = if isProject && descriptor.schemaVersion >= 2 then 2 else 1;
  unitName = "app-deployment-${name}";
  updateUnitName = "${unitName}-update";
  activationUnitName = "${unitName}-activate";
  generatedUserName = "app-${name}";
  userName = if cfg.runtime.user == null then generatedUserName else cfg.runtime.user;
  groupName = if cfg.runtime.group == null then userName else cfg.runtime.group;
  stateDir = "/var/lib/app-deployments/${name}";
  runtimeDir = "${stateDir}/runtime";
  homeDir = if cfg.runtime.home == null then stateDir else cfg.runtime.home;
  workingDirectory =
    if cfg.runtime.workingDirectory == null then stateDir else cfg.runtime.workingDirectory;
  needsRuntimeUser =
    isService || (isProject && (projectActivationExecutable != null || projectJobs != { }));
  runsProjectActivation = isProject && (isService || projectActivationExecutable != null);
  ociBackend = config.virtualisation.oci-containers.backend;
  projectContainerName = auxiliaryName: "project-${name}-${auxiliaryName}";
  projectContainerUnits = map (
    auxiliaryName: "${ociBackend}-${projectContainerName auxiliaryName}.service"
  ) (builtins.attrNames projectAuxiliaries);
  externalAfterUnits = lib.unique (
    cfg.unitDependencies.after ++ cfg.unitDependencies.wants ++ cfg.unitDependencies.requires
  );
  externalWantedUnits = lib.unique cfg.unitDependencies.wants;
  externalRequiredUnits = lib.unique cfg.unitDependencies.requires;
  auxiliaryRuntimeEndpoints = lib.listToAttrs (
    lib.concatLists (
      lib.mapAttrsToList (
        auxiliaryName: auxiliary:
        lib.mapAttrsToList (
          portName: port:
          let
            endpointName = "${auxiliaryName}-${portName}";
            listen = {
              host = "127.0.0.1";
              port = projectAuxiliaryPorts.${auxiliaryName}.${portName};
            };
          in
          if projectRuntimeSchemaVersion == 2 && port.protocol != "tcp" then
            throw "app-deployment/${name}: Project Runtime v2 cannot expose UDP auxiliary Endpoint ${endpointName}"
          else
            {
              name = endpointName;
              value =
                if projectRuntimeSchemaVersion == 1 then
                  {
                    url = "${port.protocol}://${listen.host}:${toString listen.port}";
                    inherit listen;
                  }
                else
                  {
                    protocol = "tcp";
                    inherit listen;
                  };
            }
        ) auxiliary.ports
      ) projectAuxiliaries
    )
  );
  defaultRuntimeEndpoint = {
    url =
      if cfg.domain != null then "https://${cfg.domain}" else "http://${cfg.host}:${toString cfg.port}";
    listen = {
      host = cfg.host;
      port = cfg.port;
    };
  }
  // lib.optionalAttrs (projectRuntimeSchemaVersion == 2) {
    protocol = "http";
    hostNames = lib.optional (cfg.domain != null) cfg.domain;
    visibility =
      if cfg.domain == null then
        "local"
      else if cfg.public then
        "public"
      else
        "tailnet";
  };
  primaryRuntimeEndpointName =
    if projectRuntimeSchemaVersion == 2 then projectRelease.action else "default";
  projectRuntimeBaseManifest = pkgs.writeText "project-release-runtime-base-${name}.json" (
    builtins.toJSON {
      schemaVersion = projectRuntimeSchemaVersion;
      project = name;
      realization = "release";
      paths = {
        state = runtimeDir;
        runtime = runtimeDir;
      };
      endpoints = {
        ${primaryRuntimeEndpointName} = defaultRuntimeEndpoint;
      }
      // auxiliaryRuntimeEndpoints;
    }
    + "\n"
  );
  projectBindingPolicy = pkgs.writeText "project-release-bindings-${name}.json" (
    builtins.toJSON {
      descriptor = descriptor;
      managedJobs = builtins.attrNames projectJobs;
      bindings = {
        parameters = cfg.project.parameterBindings;
        secrets = builtins.attrNames projectSecrets;
      };
    }
    + "\n"
  );
  projectSecretBindings = pkgs.writeText "project-release-secret-bindings-${name}.json" (
    builtins.toJSON projectSecrets + "\n"
  );
  # A flake-source path has no derivation string context, so interpolating it into a generated
  # script does not retain the source as a runtime dependency. Materialize the policy as its own
  # store object so garbage collection cannot leave deployed updater scripts with a dangling path.
  projectCompatibilityJq = pkgs.writeText "project-release-compatibility.jq" (
    builtins.readFile ./project-release-compatibility.jq
  );
  deployedProjectRuntimeManifest = "${stateDir}/project-runtime.json";
  deployedProjectReleasePlan = "${stateDir}/release-plan.json";

  shellPath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.diffutils
    pkgs.findutils
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.nix
    pkgs.openssh
    pkgs.systemd
    pkgs.util-linux
  ];

  mkFlakeRef =
    revision:
    if revision == "" then
      "${cfg.source.url}?ref=${cfg.source.branch}"
    else
      "${cfg.source.url}?rev=${revision}";

  effectiveHealthHostHeader =
    if isProject && cfg.health.hostHeader == null then cfg.domain else cfg.health.hostHeader;
  inferredHealthHeaders = lib.optionalAttrs (isProject && cfg.domain != null) {
    "X-Forwarded-Host" = cfg.domain;
    "X-Forwarded-Port" = "443";
    "X-Forwarded-Proto" = "https";
  };
  effectiveHealthHeaders = inferredHealthHeaders // cfg.health.headers;
  healthCurlArgs =
    lib.optionals (effectiveHealthHostHeader != null) [
      "-H"
      "Host: ${effectiveHealthHostHeader}"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (header: value: [
        "-H"
        "${header}: ${value}"
      ]) effectiveHealthHeaders
    );

  caddyQuote = value: ''"${lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "" ] value}"'';
  projectIngressConfig =
    if !isProject then
      ""
    else
      let
        ingress = projectRelease.ingress;
        redirects = map (
          redirect: "redir ${caddyQuote redirect.from} ${caddyQuote redirect.to} ${toString redirect.status}"
        ) ingress.redirects;
        cacheRules = lib.imap0 (
          index: rule:
          let
            matcher = "project_cache_${toString index}";
          in
          ''
            @${matcher} path ${lib.concatStringsSep " " (map caddyQuote rule.paths)}
            header @${matcher} Cache-Control ${caddyQuote rule.value}
          ''
        ) ingress.cacheRules;
        responseHeaders = lib.optional (ingress.responseHeaders != { }) ''
          header {
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (header: value: "${header} ${caddyQuote value}") ingress.responseHeaders
            )}
          }
        '';
      in
      lib.concatStringsSep "\n" (
        lib.optional ingress.compression "encode zstd gzip"
        ++ lib.optional (ingress.requestBodyMaxBytes != null) ''
          request_body {
            max_size ${toString ingress.requestBodyMaxBytes}B
          }
        ''
        ++ redirects
        ++ cacheRules
        ++ responseHeaders
      );

  serviceHealthScript =
    if isProject then
      ''
        check_service_health() {
          local plan="$1"
          local deadline startup_timeout interval request_timeout now path
          local -a paths

          IFS=$'\t' read -r startup_timeout interval request_timeout < <(
            ${pkgs.jq}/bin/jq -er '[.health.startupTimeoutSec, .health.intervalSec, .health.requestTimeoutSec] | @tsv' "$plan"
          )
          mapfile -t paths < <(${pkgs.jq}/bin/jq -er '.health.paths[]' "$plan")
          deadline=$((SECONDS + startup_timeout))

          while true; do
            for path in "''${paths[@]}"; do
              if ! ${pkgs.curl}/bin/curl -fsS --max-time "$request_timeout" \
                ${lib.escapeShellArgs healthCurlArgs} \
                "http://${cfg.health.host}:${toString cfg.port}$path" >/dev/null; then
                now=$SECONDS
                if [ "$now" -ge "$deadline" ]; then
                  echo "health check failed for http://${cfg.health.host}:${toString cfg.port}$path" >&2
                  return 1
                fi
                sleep "$interval"
                continue 2
              fi
            done
            return 0
          done
        }
      ''
    else
      ''
        check_service_health() {
          local deadline now path
          deadline=$((SECONDS + ${toString cfg.health.startupTimeoutSec}))

          while true; do
            for path in ${lib.escapeShellArgs cfg.health.paths}; do
              if ! ${pkgs.curl}/bin/curl -fsS --max-time ${toString cfg.health.requestTimeoutSec} \
                ${lib.escapeShellArgs healthCurlArgs} \
                "http://${cfg.health.host}:${toString cfg.port}$path" >/dev/null; then
                now=$SECONDS
                if [ "$now" -ge "$deadline" ]; then
                  echo "health check failed for http://${cfg.health.host}:${toString cfg.port}$path" >&2
                  return 1
                fi
                sleep ${toString cfg.health.intervalSec}
                continue 2
              fi
            done
            return 0
          done
        }
      '';

  staticHealthScript =
    if isProject then
      ''
        check_static_health() {
          local root="$1"
          local plan="$2"
          local path relative candidate
          local -a paths

          mapfile -t paths < <(${pkgs.jq}/bin/jq -er '.health.paths[]' "$plan")
          for path in "''${paths[@]}"; do
            relative="''${path#/}"
            candidate="$root/$relative"

            if [ -d "$candidate" ]; then
              candidate="$candidate/index.html"
            elif [ "$path" = "/" ] || [[ "$path" == */ ]]; then
              candidate="$candidate/index.html"
            fi

            if [ ! -f "$candidate" ]; then
              echo "static health check failed: $path does not resolve to a file under $root" >&2
              return 1
            fi
          done
        }
      ''
    else
      ''
        check_static_health() {
          local root path relative candidate
          root="$1"

          for path in ${lib.escapeShellArgs cfg.health.paths}; do
            relative="''${path#/}"
            candidate="$root/$relative"

            if [ -d "$candidate" ]; then
              candidate="$candidate/index.html"
            elif [ "$path" = "/" ] || [[ "$path" == */ ]]; then
              candidate="$candidate/index.html"
            fi

            if [ ! -f "$candidate" ]; then
              echo "static health check failed: $path does not resolve to a file under $root" >&2
              return 1
            fi
          done
        }
      '';

  gitTokenSetup =
    if cfg.source.giteaTokenSecretName == null then
      ''
        git_config_file=""
      ''
    else if hasSops then
      ''
        git_config_file="$(mktemp)"
        chmod 0600 "$git_config_file"
        git_token="$(tr -d '\r\n' < ${
          lib.escapeShellArg config.sops.secrets.${cfg.source.giteaTokenSecretName}.path
        })"
        printf '[url "https://%s:%s@%s/"]\n\tinsteadOf = https://%s/\n' \
          ${lib.escapeShellArg cfg.source.username} \
          "$git_token" \
          ${lib.escapeShellArg cfg.source.netrcHost} \
          ${lib.escapeShellArg cfg.source.netrcHost} \
          > "$git_config_file"
        unset git_token
        export GIT_CONFIG_GLOBAL="$git_config_file"
        export GIT_TERMINAL_PROMPT=0
      ''
    else
      throw "source.giteaTokenSecretName requires importing sops-nix or another module that defines options.sops";

  updateScript = pkgs.writeShellScript "app-deployment-${name}-update" ''
    set -euo pipefail

    export PATH=${lib.escapeShellArg shellPath}:$PATH
    export NIX_CONFIG=$'experimental-features = nix-command flakes\nwarn-dirty = false${
      lib.optionalString (
        cfg.delivery.mode == "cache"
      ) "\\nextra-substituters = ${cfg.delivery.cacheStore}\\nbuilders = \\nmax-jobs = 0"
    }'

    state_dir=${lib.escapeShellArg stateDir}
    requested_release_file="$state_dir/requested-release.json"
    requested_release_snapshot="$state_dir/requested-release.active.json"
    requested_revision_file="$state_dir/requested-revision"
    current_revision_file="$state_dir/current-revision"
    previous_revision_file="$state_dir/previous-revision"
    current_link="$state_dir/current"
    previous_link="$state_dir/previous"
    gcroots_dir="/nix/var/nix/gcroots/app-deployments/${name}"
    lock_file="$state_dir/update.lock"
    metadata_file="$state_dir/metadata.json"
    runtime_manifest="$state_dir/project-runtime.json"
    previous_runtime_manifest="$state_dir/previous-project-runtime.json"
    release_plan="$state_dir/release-plan.json"
    previous_release_plan="$state_dir/previous-release-plan.json"
    candidate_link="$state_dir/candidate"
    candidate_runtime_manifest="$state_dir/candidate-project-runtime.json"
    candidate_release_plan="$state_dir/candidate-release-plan.json"
    candidate_gcroot="$gcroots_dir/candidate"
    git_config_file=""

    cleanup_candidate() {
      rm -f \
        "$candidate_link" "$candidate_link.next" \
        "$candidate_runtime_manifest" "$candidate_runtime_manifest.next" \
        "$candidate_release_plan" "$candidate_release_plan.next" \
        "$candidate_gcroot" "$candidate_gcroot.next"
      rm -f "$requested_release_snapshot"
    }

    cleanup() {
      cleanup_candidate
      if [ -n "$git_config_file" ]; then
        rm -f "$git_config_file"
      fi
    }
    trap cleanup EXIT

    mkdir -p "$state_dir"
    exec 9>"$lock_file"
    if ! flock -n 9; then
      echo "app-deployment/${name}: another update is already running"
      exit 0
    fi
    cleanup_candidate

    requested_revision=""
    requested_store_path=""
    if [ -s "$requested_release_file" ]; then
      cp "$requested_release_file" "$requested_release_snapshot"
      requested_revision="$(jq -er '.revision' "$requested_release_snapshot")"
      requested_store_path="$(jq -er '.storePath' "$requested_release_snapshot")"
    elif [ -s "$requested_revision_file" ]; then
      requested_revision="$(head -n 1 "$requested_revision_file" | tr -d '\r\n')"
      rm -f "$requested_revision_file"
    fi

    if [ ${lib.escapeShellArg cfg.delivery.mode} = cache ] && [ -z "$requested_store_path" ]; then
      echo "app-deployment/${name}: no promoted cache Release is waiting"
      exit 0
    elif [ -n "$requested_revision" ]; then
      flake_ref=${lib.escapeShellArg (mkFlakeRef "__REVISION__")}
      flake_ref="''${flake_ref/__REVISION__/$requested_revision}"
    else
      flake_ref=${lib.escapeShellArg (mkFlakeRef "")}
    fi

    sync_gcroots() {
      local link name target
      mkdir -p "$gcroots_dir"

      for name in current previous; do
        link="$state_dir/$name"
        target=""
        if [ -L "$link" ]; then
          target="$(readlink "$link")"
        fi

        if [ -n "$target" ] && [ -e "$target" ]; then
          ln -sfn "$target" "$gcroots_dir/$name.next"
          mv -Tf "$gcroots_dir/$name.next" "$gcroots_dir/$name"
        else
          rm -f "$gcroots_dir/$name"
        fi
      done
    }

    ${lib.optionalString isProject ''
      bind_descriptor() {
        local descriptor="$1"
        local runtime="$2"
        local plan="$3"
        local result="$state_dir/compatibility.json.next"

        if ! jq -n \
          --slurpfile host ${lib.escapeShellArg projectBindingPolicy} \
          --slurpfile candidate "$descriptor" \
          -f ${lib.escapeShellArg projectCompatibilityJq} > "$result"; then
          rm -f "$result"
          return 1
        fi

        jq -S . "$descriptor" > "$state_dir/artifact-descriptor.json.next"
        jq -S '.descriptor' ${lib.escapeShellArg projectBindingPolicy} \
          > "$state_dir/expected-descriptor.json.next"
        if ! jq -e '.compatible' "$result" >/dev/null; then
          jq -r '.reasons[] | "app-deployment/${name}: " + .' "$result" >&2
          mv -f "$result" "$state_dir/compatibility.json"
          mv -f "$state_dir/expected-descriptor.json.next" "$state_dir/expected-descriptor.json"
          mv -f "$state_dir/artifact-descriptor.json.next" "$state_dir/artifact-descriptor.json"
          return 1
        fi

        jq -S -s '.[0] + {parameters: .[1].parameters, secrets: .[1].secrets}' \
          ${lib.escapeShellArg projectRuntimeBaseManifest} "$result" > "$runtime"
        jq -S '.releasePlan' "$result" > "$plan"
        mv -f "$result" "$state_dir/compatibility.json"
        mv -f "$state_dir/expected-descriptor.json.next" "$state_dir/expected-descriptor.json"
        mv -f "$state_dir/artifact-descriptor.json.next" "$state_dir/artifact-descriptor.json"
      }

      current_descriptor_matches() {
        local descriptor expected_runtime expected_plan
        descriptor="$current_link/share/project/descriptor.json"
        expected_runtime="$state_dir/current-project-runtime.json.next"
        expected_plan="$state_dir/current-release-plan.json.next"
        [ -f "$descriptor" ] || return 1
        bind_descriptor "$descriptor" "$expected_runtime" "$expected_plan" || return 1
        if cmp -s "$expected_runtime" "$runtime_manifest" && cmp -s "$expected_plan" "$release_plan"; then
          rm -f "$expected_runtime" "$expected_plan"
          return 0
        fi
        rm -f "$expected_runtime" "$expected_plan"
        return 1
      }

    ''}

    ${lib.optionalString (cfg.delivery.mode == "source") gitTokenSetup}

    ${
      if cfg.delivery.mode == "cache" then
        ''
          resolved_revision="$requested_revision"
          build_flake_ref=""
        ''
      else
        ''
          echo "app-deployment/${name}: resolving $flake_ref"
          nix flake metadata --refresh --json "$flake_ref" > "$metadata_file"
          resolved_revision="$(jq -r '.revision // .locked.rev // empty' "$metadata_file")"
          if [ -z "$resolved_revision" ]; then
            resolved_revision="$requested_revision"
          fi
          build_flake_ref="$flake_ref"
          if [ -n "$resolved_revision" ]; then
            build_flake_ref=${lib.escapeShellArg (mkFlakeRef "__REVISION__")}
            build_flake_ref="''${build_flake_ref/__REVISION__/$resolved_revision}"
          fi
        ''
    }

    ${if isService then serviceHealthScript else staticHealthScript}

    if [ -n "$resolved_revision" ] \
      && [ -f "$current_revision_file" ] \
      && [ "$(cat "$current_revision_file")" = "$resolved_revision" ] \
      && { [ -z "$requested_store_path" ] || [ "$(readlink "$current_link")" = "$requested_store_path" ]; }; then
      sync_gcroots
      if ${
        if isService then
          "systemctl is-active --quiet ${lib.escapeShellArg "${unitName}.service"} && [ -x \"$current_link/bin/${cfg.executable}\" ] && ${lib.optionalString isProject "current_descriptor_matches && "}check_service_health${lib.optionalString isProject " \"$release_plan\""}"
        else
          "[ -d \"$current_link\" ] && ${lib.optionalString isProject "current_descriptor_matches && "}check_static_health \"$current_link\"${lib.optionalString isProject " \"$release_plan\""}"
      }; then
        if [ -n "$requested_store_path" ]; then
          if cmp -s "$requested_release_snapshot" "$requested_release_file"; then
            rm -f "$requested_release_file"
          fi
        fi
        echo "app-deployment/${name}: already active at $resolved_revision"
        exit 0
      fi

      echo "app-deployment/${name}: $resolved_revision is active but failed deployment checks; redeploying"
    fi

    ${
      if cfg.delivery.mode == "cache" then
        ''
          echo "app-deployment/${name}: substituting promoted output $requested_store_path"
          rm -f "$state_dir/compatibility.json"
          nix-store --realise "$requested_store_path" >/dev/null
          new_store_path="$requested_store_path"
        ''
      else
        ''
          echo "app-deployment/${name}: building $build_flake_ref#${cfg.package}"
          new_store_path="$(nix build --no-link --print-out-paths "$build_flake_ref#${cfg.package}")"
        ''
    }
    ${lib.optionalString isProject ''
      descriptor_file="$new_store_path/share/project/descriptor.json"
      if [ ! -f "$descriptor_file" ]; then
        echo "app-deployment/${name}: Project artifact is missing $descriptor_file" >&2
        exit 1
      fi
      if ! bind_descriptor "$descriptor_file" "$candidate_runtime_manifest.next" "$candidate_release_plan.next"; then
        echo "app-deployment/${name}: Project artifact is waiting for compatible host bindings" >&2
        exit 1
      fi
      chmod 0644 "$candidate_runtime_manifest.next"
      mv -f "$candidate_runtime_manifest.next" "$candidate_runtime_manifest"
      chmod 0644 "$candidate_release_plan.next"
      mv -f "$candidate_release_plan.next" "$candidate_release_plan"
      candidate_activation_executable="$(jq -r '.activationExecutable // empty' "$candidate_release_plan")"
      if [ -n "$candidate_activation_executable" ] && [ ! -x "$new_store_path/bin/$candidate_activation_executable" ]; then
          echo "app-deployment/${name}: missing activation executable $new_store_path/bin/$candidate_activation_executable" >&2
          exit 1
      fi
    ''}
    ${
      if isService then
        ''
          if [ ! -x "$new_store_path/bin/${cfg.executable}" ]; then
            echo "app-deployment/${name}: missing executable $new_store_path/bin/${cfg.executable}" >&2
            exit 1
          fi
        ''
      else
        ''
          if [ ! -d "$new_store_path" ]; then
            echo "app-deployment/${name}: static package is not a directory: $new_store_path" >&2
            exit 1
          fi
          check_static_health "$new_store_path"${lib.optionalString isProject " \"$candidate_release_plan\""}
        ''
    }

    old_store_path=""
    if [ -L "$current_link" ]; then
      old_store_path="$(readlink "$current_link")"
      if [ "$new_store_path" = "$old_store_path" ] && ${
        if isService then
          "${lib.optionalString isProject "current_descriptor_matches && "}systemctl is-active --quiet ${lib.escapeShellArg "${unitName}.service"} && check_service_health${lib.optionalString isProject " \"$release_plan\""}"
        else
          "check_static_health \"$current_link\"${lib.optionalString isProject " \"$release_plan\""}"
      }; then
        printf '%s\n' "$resolved_revision" > "$current_revision_file"
        if [ -n "$requested_store_path" ]; then
          if cmp -s "$requested_release_snapshot" "$requested_release_file"; then
            rm -f "$requested_release_file"
          fi
        fi
        sync_gcroots
        echo "app-deployment/${name}: revision $resolved_revision already produces the active output"
        exit 0
      fi
    fi

    ${lib.optionalString (isProject && isService) ''
      if [ "$new_store_path" != "$old_store_path" ]; then
        mapfile -t pre_deploy_tasks < <(jq -er '.preDeployOrder[]' "$candidate_release_plan")
        if [ "''${#pre_deploy_tasks[@]}" -gt 0 ]; then
          echo "app-deployment/${name}: running pre-deploy tasks for $resolved_revision"
          mkdir -p "$gcroots_dir"
          ln -sfn "$new_store_path" "$candidate_link.next"
          mv -Tf "$candidate_link.next" "$candidate_link"
          ln -sfn "$new_store_path" "$candidate_gcroot.next"
          mv -Tf "$candidate_gcroot.next" "$candidate_gcroot"
          for task in "''${pre_deploy_tasks[@]}"; do
            timeout="$(jq -er --arg task "$task" '.preDeployTasks[$task].timeoutSec' "$candidate_release_plan")"
            credential_args=()
            while IFS=$'\t' read -r secret path; do
              credential_args+=("--property=LoadCredential=$secret:$path")
            done < <(
              jq -er --arg task "$task" \
                --slurpfile bindings ${lib.escapeShellArg projectSecretBindings} \
                '.preDeployTasks[$task].secrets[] as $secret | select($bindings[0] | has($secret)) | [$secret, $bindings[0][$secret]] | @tsv' \
                "$candidate_release_plan"
            )
            systemd_run_args=(
              --quiet
              --wait
              --collect
              --pipe
              --unit="${unitName}-pre-deploy-$task"
              --service-type=oneshot
              --uid=${lib.escapeShellArg userName}
              --gid=${lib.escapeShellArg groupName}
              --working-directory=${lib.escapeShellArg workingDirectory}
              --property="TimeoutStartSec=''${timeout}s"
              ${lib.optionalString (cfg.runtime.isolation == "isolated") ''
                --property=CapabilityBoundingSet=
                --property=LockPersonality=true
                --property=NoNewPrivileges=true
                --property=PrivateDevices=true
                --property=PrivateTmp=true
                --property=ProtectClock=true
                --property=ProtectControlGroups=true
                --property=ProtectHome=${if cfg.runtime.protectHome then "true" else "false"}
                --property=ProtectKernelLogs=true
                --property=ProtectKernelModules=true
                --property=ProtectKernelTunables=true
                --property=ProtectSystem=strict
                --property=ReadWritePaths=${
                  lib.escapeShellArg (lib.concatStringsSep " " ([ runtimeDir ] ++ cfg.runtime.readWritePaths))
                }
                --property=RemoveIPC=true
                --property="RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"
                --property=RestrictRealtime=true
                --property=RestrictSUIDSGID=true
                --property=SystemCallArchitectures=native
              ''}
              --property=TimeoutStopSec=30s
              --property=UMask=0027
              ${lib.optionalString (
                projectMemory.high != null
              ) "--property=MemoryHigh=${lib.escapeShellArg projectMemory.high}"}
              ${lib.optionalString (
                projectMemory.max != null
              ) "--property=MemoryMax=${lib.escapeShellArg projectMemory.max}"}
              ${lib.optionalString (
                projectMemory.swapMax != null
              ) "--property=MemorySwapMax=${lib.escapeShellArg projectMemory.swapMax}"}
            )
            systemd_run_args+=("''${credential_args[@]}")
            if ! systemd-run "''${systemd_run_args[@]}" \
              ${projectPreDeployTaskScript} "$task"; then
              failure_mode="$(jq -er --arg task "$task" '.preDeployTasks[$task].failureMode' "$candidate_release_plan")"
              if [ "$failure_mode" = defer ]; then
                echo "app-deployment/${name}: pre-deploy task $task deferred activation"
                exit 0
              fi
              exit 1
            fi
          done
        fi
      fi
    ''}

    if [ -n "$old_store_path" ]; then
      ln -sfn "$old_store_path" "$previous_link.next"
      mv -Tf "$previous_link.next" "$previous_link"
      if [ -f "$current_revision_file" ]; then
        cp "$current_revision_file" "$previous_revision_file"
      fi
      ${lib.optionalString isProject ''
        if [ -f "$runtime_manifest" ]; then
          cp "$runtime_manifest" "$previous_runtime_manifest.next"
          mv -f "$previous_runtime_manifest.next" "$previous_runtime_manifest"
        else
          rm -f "$previous_runtime_manifest"
        fi
        if [ -f "$release_plan" ]; then
          cp "$release_plan" "$previous_release_plan.next"
          mv -f "$previous_release_plan.next" "$previous_release_plan"
        else
          rm -f "$previous_release_plan"
        fi
      ''}
    fi

    ${lib.optionalString isProject ''
      cp "$candidate_runtime_manifest" "$runtime_manifest.next"
      chmod 0644 "$runtime_manifest.next"
      mv -f "$runtime_manifest.next" "$runtime_manifest"
      cp "$candidate_release_plan" "$release_plan.next"
      chmod 0644 "$release_plan.next"
      mv -f "$release_plan.next" "$release_plan"
    ''}
    ln -sfn "$new_store_path" "$current_link.next"
    mv -Tf "$current_link.next" "$current_link"
    printf '%s\n' "$resolved_revision" > "$current_revision_file"
    sync_gcroots

    ${lib.optionalString runsProjectActivation ''
      if [ "$new_store_path" != "$old_store_path" ]; then
        ${lib.optionalString isService "systemctl stop ${lib.escapeShellArg "${unitName}.service"}"}
        if ! systemctl start ${lib.escapeShellArg "${activationUnitName}.service"}; then
          echo "app-deployment/${name}: activation failed" >&2
          if [ -n "$old_store_path" ]; then
            echo "app-deployment/${name}: restoring and reactivating $old_store_path" >&2
            ln -sfn "$old_store_path" "$current_link.next"
            mv -Tf "$current_link.next" "$current_link"
            if [ -f "$previous_revision_file" ]; then
              cp "$previous_revision_file" "$current_revision_file"
            fi
            ${lib.optionalString isProject ''
              if [ -f "$previous_runtime_manifest" ]; then
                cp "$previous_runtime_manifest" "$runtime_manifest.next"
                mv -f "$runtime_manifest.next" "$runtime_manifest"
              else
                rm -f "$runtime_manifest"
              fi
              if [ -f "$previous_release_plan" ]; then
                cp "$previous_release_plan" "$release_plan.next"
                mv -f "$release_plan.next" "$release_plan"
              else
                rm -f "$release_plan"
              fi
            ''}
            sync_gcroots
            if ! systemctl start ${lib.escapeShellArg "${activationUnitName}.service"}; then
              echo "app-deployment/${name}: rollback activation also failed" >&2
            fi
            ${lib.optionalString isService "systemctl start ${lib.escapeShellArg "${unitName}.service"}"}
          else
            rm -f "$current_link" "$current_revision_file"
            sync_gcroots
          fi
          exit 1
        fi
      fi
    ''}
    ${lib.optionalString isService "systemctl restart ${lib.escapeShellArg "${unitName}.service"}"}

    if ${
      if isService then
        "check_service_health${lib.optionalString isProject " \"$release_plan\""}"
      else
        "check_static_health \"$current_link\"${lib.optionalString isProject " \"$release_plan\""}"
    }; then
      if [ -n "$requested_store_path" ]; then
        if cmp -s "$requested_release_snapshot" "$requested_release_file"; then
          rm -f "$requested_release_file"
        fi
      fi
      echo "app-deployment/${name}: deployed $resolved_revision"
      exit 0
    fi

    if [ -n "$old_store_path" ]; then
      echo "app-deployment/${name}: health failed, rolling back to $old_store_path" >&2
      ${lib.optionalString (
        isService && runsProjectActivation
      ) "systemctl stop ${lib.escapeShellArg "${unitName}.service"}"}
      ln -sfn "$old_store_path" "$current_link.next"
      mv -Tf "$current_link.next" "$current_link"
      ${lib.optionalString isProject ''
        if [ -f "$previous_runtime_manifest" ]; then
          cp "$previous_runtime_manifest" "$runtime_manifest.next"
          mv -f "$runtime_manifest.next" "$runtime_manifest"
        else
          rm -f "$runtime_manifest"
        fi
        if [ -f "$previous_release_plan" ]; then
          cp "$previous_release_plan" "$release_plan.next"
          mv -f "$release_plan.next" "$release_plan"
        else
          rm -f "$release_plan"
        fi
      ''}
      if [ -f "$previous_revision_file" ]; then
        cp "$previous_revision_file" "$current_revision_file"
      fi
      sync_gcroots
      ${lib.optionalString runsProjectActivation ''
        if ! systemctl start ${lib.escapeShellArg "${activationUnitName}.service"}; then
          echo "app-deployment/${name}: rollback activation failed" >&2
        fi
      ''}
      ${
        if isService then
          ''
            systemctl restart ${lib.escapeShellArg "${unitName}.service"}
            check_service_health${lib.optionalString isProject " \"$release_plan\""}
          ''
        else
          ''
            check_static_health "$current_link"${lib.optionalString isProject " \"$release_plan\""}
          ''
      }
    fi

    exit 1
  '';

  startScript = pkgs.writeShellScript "app-deployment-${name}-start" ''
    set -euo pipefail

    current=${lib.escapeShellArg stateDir}/current
    executable="$current/bin/${cfg.executable}"

    if [ ! -x "$executable" ]; then
      echo "app-deployment/${name}: no deployed executable at $executable" >&2
      exit 1
    fi

    ${lib.optionalString isProject ''
      export PROJECT_RUNTIME_FILE=${lib.escapeShellArg deployedProjectRuntimeManifest}
      export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-${runtimeDir}/secrets}"
    ''}
    exec "$executable"
  '';
  projectReleasePlanBootstrapScript = pkgs.writeShellScript "app-deployment-${name}-release-plan" ''
    set -euo pipefail

    current=${lib.escapeShellArg stateDir}/current
    descriptor="$current/share/project/descriptor.json"
    runtime=${lib.escapeShellArg deployedProjectRuntimeManifest}
    plan=${lib.escapeShellArg deployedProjectReleasePlan}
    if [ ! -f "$descriptor" ] || [ ! -f "$runtime" ]; then
      exit 0
    fi

    result="$(${pkgs.jq}/bin/jq -n \
      --slurpfile host ${lib.escapeShellArg projectBindingPolicy} \
      --slurpfile candidate "$descriptor" \
      -f ${lib.escapeShellArg projectCompatibilityJq})"
    if ! ${pkgs.jq}/bin/jq -e '.compatible' <<<"$result" >/dev/null; then
      ${pkgs.jq}/bin/jq -r '.reasons[] | "app-deployment/${name}: " + .' <<<"$result" >&2
      exit 1
    fi

    expected_runtime="$(${pkgs.jq}/bin/jq -S -s \
      '.[0] + {parameters: .[1].parameters, secrets: .[1].secrets}' \
      ${lib.escapeShellArg projectRuntimeBaseManifest} <(printf '%s\n' "$result"))"
    actual_runtime="$(${pkgs.jq}/bin/jq -S . "$runtime")"
    if [ "$expected_runtime" != "$actual_runtime" ]; then
      echo "app-deployment/${name}: cannot bootstrap a Release plan for a stale Runtime Context" >&2
      exit 1
    fi

    ${pkgs.jq}/bin/jq -S '.releasePlan' <<<"$result" > "$plan.next"
    chmod 0644 "$plan.next"
    mv -f "$plan.next" "$plan"
  '';
  projectArtifactConditionScript = pkgs.writeShellScript "app-deployment-${name}-artifact-condition" ''
    set -euo pipefail

    current=${lib.escapeShellArg stateDir}/current
    executable="$current/bin/${cfg.executable}"
    descriptor="$current/share/project/descriptor.json"

    if [ ! -x "$executable" ] || [ ! -f "$descriptor" ]${lib.optionalString isProject " || [ ! -f ${lib.escapeShellArg deployedProjectRuntimeManifest} ] || [ ! -f ${lib.escapeShellArg deployedProjectReleasePlan} ]"}; then
      echo "app-deployment/${name}: no descriptor-compatible Project artifact is deployed" >&2
      exit 1
    fi

    result="$(${pkgs.jq}/bin/jq -n \
      --slurpfile host ${lib.escapeShellArg projectBindingPolicy} \
      --slurpfile candidate "$descriptor" \
      -f ${lib.escapeShellArg projectCompatibilityJq})"
    if ! ${pkgs.jq}/bin/jq -e '.compatible' <<<"$result" >/dev/null; then
      ${pkgs.jq}/bin/jq -r '.reasons[] | "app-deployment/${name}: " + .' <<<"$result" >&2
      exit 1
    fi

    expected_runtime="$(${pkgs.jq}/bin/jq -S -s \
      '.[0] + {parameters: .[1].parameters, secrets: .[1].secrets}' \
      ${lib.escapeShellArg projectRuntimeBaseManifest} <(printf '%s\n' "$result"))"
    expected_release_plan="$(${pkgs.jq}/bin/jq -S '.releasePlan' <<<"$result")"
    actual_runtime="$(${pkgs.jq}/bin/jq -S . ${lib.escapeShellArg deployedProjectRuntimeManifest})"
    actual_release_plan="$(${pkgs.jq}/bin/jq -S . ${lib.escapeShellArg deployedProjectReleasePlan})"
    if [ "$expected_runtime" != "$actual_runtime" ] || [ "$expected_release_plan" != "$actual_release_plan" ]; then
      echo "app-deployment/${name}: deployed Runtime Context or Release plan is stale" >&2
      exit 1
    fi
  '';
  activationScript = pkgs.writeShellScript "app-deployment-${name}-activate" ''
    set -euo pipefail

    current=${lib.escapeShellArg stateDir}/current
    release_plan=${lib.escapeShellArg deployedProjectReleasePlan}
    activation_executable="$(${pkgs.jq}/bin/jq -r '.activationExecutable // empty' "$release_plan")"
    if [ -z "$activation_executable" ]; then
      exit 0
    fi
    executable="$current/bin/$activation_executable"
    if [ ! -x "$executable" ]; then
      echo "app-deployment/${name}: no deployed activation executable at $executable" >&2
      exit 1
    fi

    export PROJECT_RUNTIME_FILE=${lib.escapeShellArg deployedProjectRuntimeManifest}
    export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-${runtimeDir}/secrets}"
    exec "$executable"
  '';
  projectPreDeployTaskScript = pkgs.writeShellScript "app-deployment-${name}-pre-deploy" ''
    set -euo pipefail

    candidate=${lib.escapeShellArg stateDir}/candidate
    runtime_manifest=${lib.escapeShellArg stateDir}/candidate-project-runtime.json
    release_plan=${lib.escapeShellArg stateDir}/candidate-release-plan.json
    executable="$candidate/bin/${cfg.executable}"
    if [ ! -x "$executable" ] || [ ! -f "$runtime_manifest" ] || [ ! -f "$release_plan" ]; then
      echo "app-deployment/${name}: no complete staged Project artifact for a pre-deploy task" >&2
      exit 1
    fi

    task="$1"
    action="$(${pkgs.jq}/bin/jq -er --arg task "$task" '.preDeployTasks[$task].action' "$release_plan")"
    export PROJECT_RUNTIME_FILE="$runtime_manifest"
    export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-${runtimeDir}/secrets}"
    exec "$executable" "$action"
  '';
  projectJobScripts = lib.mapAttrs (
    jobName: _policy:
    pkgs.writeShellScript "app-deployment-${name}-job-${jobName}" ''
      set -euo pipefail

      current=${lib.escapeShellArg stateDir}/current
      release_plan=${lib.escapeShellArg deployedProjectReleasePlan}
      executable="$current/bin/${cfg.executable}"
      if [ ! -x "$executable" ] || [ ! -f "$release_plan" ]; then
        echo "app-deployment/${name}: no deployed Release executable at $executable" >&2
        exit 1
      fi

      job=${lib.escapeShellArg jobName}
      action="$(${pkgs.jq}/bin/jq -er --arg job "$job" '.maintenanceJobs[$job].action' "$release_plan")"
      export PROJECT_RUNTIME_FILE=${lib.escapeShellArg deployedProjectRuntimeManifest}
      export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-${runtimeDir}/secrets}"
      exec "$executable" "$action"
    ''
  ) projectJobs;
  projectJobServices = lib.mapAttrs' (
    jobName: policy:
    lib.nameValuePair "${unitName}-job-${jobName}" {
      description = "Run Project Release job '${name}/${jobName}'";
      after = [
        "network-online.target"
        "${unitName}-release-plan.service"
      ]
      ++ projectContainerUnits
      ++ externalAfterUnits;
      wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
      requires = [ "${unitName}-release-plan.service" ] ++ externalRequiredUnits;
      serviceConfig = {
        Type = "oneshot";
        ExecCondition = projectArtifactConditionScript;
        ExecStart = projectJobScripts.${jobName};
        User = userName;
        Group = groupName;
        WorkingDirectory = workingDirectory;
      }
      // projectServicePolicy
      // lib.optionalAttrs (projectSecrets != { }) {
        LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") projectSecrets;
      }
      // {
        IOSchedulingClass = "idle";
        Nice = 10;
      };
    }
  ) projectJobs;
  projectJobTimers = lib.mapAttrs' (
    jobName: policy:
    lib.nameValuePair "${unitName}-job-${jobName}" {
      description = "Schedule Project Release job '${name}/${jobName}'";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Persistent = policy.persistent;
        RandomizedDelaySec = policy.randomizedDelaySec;
        Unit = "${unitName}-job-${jobName}.service";
      }
      // lib.optionalAttrs (policy.calendar != null) {
        OnCalendar = policy.calendar;
      }
      // lib.optionalAttrs (policy.interval != null) {
        OnActiveSec = policy.onBootSec;
        OnUnitActiveSec = policy.interval;
      };
    }
  ) projectJobs;
  staticCaddyConfig = ''
    root * ${stateDir}/current
    ${if isProject then projectIngressConfig else cfg.static.extraConfig}
    ${lib.optionalString isProject ''
      @project_metadata path /share/project/*
      respond @project_metadata 404
    ''}
    file_server
  '';
  projectServiceCaddyConfig = ''
    ${projectIngressConfig}
    reverse_proxy ${cfg.host}:${toString cfg.port} {
      ${lib.optionalString (projectRelease.ingress.streamCloseDelaySec != null) (
        "stream_close_delay ${toString projectRelease.ingress.streamCloseDelaySec}s"
      )}
    }
  '';
  projectHealthRecoveryScript = pkgs.writeShellScript "app-deployment-${name}-health-recovery" ''
    set -euo pipefail

    release_plan=${lib.escapeShellArg deployedProjectReleasePlan}

    check_once() {
      local request_timeout path
      local -a paths
      request_timeout="$(${pkgs.jq}/bin/jq -er '.health.requestTimeoutSec' "$release_plan")"
      mapfile -t paths < <(${pkgs.jq}/bin/jq -er '.health.paths[]' "$release_plan")
      for path in "''${paths[@]}"; do
        ${pkgs.curl}/bin/curl -fsS --max-time "$request_timeout" \
          ${lib.escapeShellArgs healthCurlArgs} \
          "http://${cfg.health.host}:${toString cfg.port}$path" >/dev/null || return 1
      done
    }

    if check_once; then
      exit 0
    fi

    echo "app-deployment/${name}: periodic health failed; restarting" >&2
    ${pkgs.systemd}/bin/systemctl restart --no-block ${lib.escapeShellArg "${unitName}.service"}
    ${serviceHealthScript}
    check_service_health "$release_plan"
  '';
  projectServicePolicy = {
    TimeoutStopSec = "30s";
    UMask = "0027";
  }
  // lib.optionalAttrs (cfg.runtime.isolation == "isolated") {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = cfg.runtime.protectHome;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ runtimeDir ] ++ cfg.runtime.readWritePaths;
    RemoveIPC = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
  }
  // lib.optionalAttrs (projectMemory.high != null) { MemoryHigh = projectMemory.high; }
  // lib.optionalAttrs (projectMemory.max != null) { MemoryMax = projectMemory.max; }
  // lib.optionalAttrs (projectMemory.swapMax != null) { MemorySwapMax = projectMemory.swapMax; };

  runtimeConfig =
    if cfg.enable then
      {
        users.users = lib.optionalAttrs (needsRuntimeUser && cfg.runtime.user == null) {
          ${generatedUserName} = {
            isSystemUser = true;
            group = generatedUserName;
            home = stateDir;
          };
        };
        users.groups = lib.optionalAttrs (needsRuntimeUser && cfg.runtime.user == null) {
          ${generatedUserName} = { };
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/app-deployments 0755 root root -"
          "d ${stateDir} 0755 root root -"
        ]
        ++ lib.optionals needsRuntimeUser (
          [
            "d ${runtimeDir} 0750 ${userName} ${groupName} -"
            "d ${runtimeDir}/secrets 0700 ${userName} ${groupName} -"
          ]
          ++ (map (dir: "d ${runtimeDir}/${dir} 0750 ${userName} ${groupName} -") projectStateDirectories)
          ++ (map (dir: "d ${dir} 0750 ${userName} ${groupName} -") cfg.stateDirs)
        );

        systemd.services = projectJobServices // {
          ${unitName} = lib.mkIf isService {
            description = "App deployment '${name}'";
            after = [
              "network-online.target"
            ]
            ++ lib.optional isProject "${unitName}-release-plan.service"
            ++ projectContainerUnits
            ++ externalAfterUnits;
            wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
            requires = lib.optional isProject "${unitName}-release-plan.service" ++ externalRequiredUnits;
            environment =
              (
                if isProject then
                  { HOME = homeDir; }
                else
                  {
                    HOST = cfg.host;
                    PORT = toString cfg.port;
                    HOME = homeDir;
                  }
              )
              // cfg.environment;
            path = cfg.path;
            serviceConfig = {
              ExecStart = startScript;
              Restart = "always";
              RestartSec = "15s";
              User = userName;
              Group = groupName;
              WorkingDirectory = workingDirectory;
            }
            // lib.optionalAttrs isProject {
              ExecCondition = projectArtifactConditionScript;
            }
            // lib.optionalAttrs isProject projectServicePolicy
            // lib.optionalAttrs (isProject && projectSecrets != { }) {
              LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") projectSecrets;
            }
            // lib.optionalAttrs (cfg.environmentFiles != [ ]) {
              EnvironmentFile = cfg.environmentFiles;
            }
            // cfg.serviceConfig;
            preStart = cfg.preStart;
          };

          ${updateUnitName} = {
            description = "Update app deployment '${name}'";
            after = [ "network-online.target" ] ++ projectContainerUnits ++ externalAfterUnits;
            wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
            requires = externalRequiredUnits;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = updateScript;
            };
          };

          ${activationUnitName} = lib.mkIf runsProjectActivation {
            description = "Activate Project Release '${name}'";
            after = [ "${unitName}-release-plan.service" ] ++ projectContainerUnits ++ externalAfterUnits;
            wants = projectContainerUnits ++ externalWantedUnits;
            requires = [ "${unitName}-release-plan.service" ] ++ externalRequiredUnits;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = activationScript;
              User = userName;
              Group = groupName;
              WorkingDirectory = workingDirectory;
            }
            // projectServicePolicy
            // lib.optionalAttrs (projectSecrets != { }) {
              LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") projectSecrets;
            };
          };

          "${unitName}-release-plan" = lib.mkIf (isProject && isService) {
            description = "Reconcile the active Project Release plan for '${name}'";
            before = [ "${unitName}.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = projectReleasePlanBootstrapScript;
            };
          };

          "${unitName}-health-recovery" =
            lib.mkIf (isProject && isService && cfg.project.healthRecovery.enable)
              {
                description = "Recover unhealthy Project Release '${name}'";
                after = [ "${unitName}.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  ExecCondition = projectArtifactConditionScript;
                  ExecStart = projectHealthRecoveryScript;
                  TimeoutStartSec = "infinity";
                };
              };
        };

        systemd.timers =
          lib.optionalAttrs cfg.autoUpdate.enable {
            ${updateUnitName} = {
              description = "Reconcile app deployment '${name}'";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnActiveSec = cfg.autoUpdate.onBootSec;
                OnUnitActiveSec = cfg.autoUpdate.interval;
                Persistent = true;
                Unit = "${updateUnitName}.service";
              }
              // lib.optionalAttrs (!isProject) {
                OnBootSec = cfg.autoUpdate.onBootSec;
              };
            };

          }
          // lib.optionalAttrs (isProject && isService && cfg.project.healthRecovery.enable) {
            "${unitName}-health-recovery" = {
              description = "Periodically probe Project Release '${name}'";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnActiveSec = cfg.project.healthRecovery.onBootSec;
                OnUnitActiveSec = cfg.project.healthRecovery.interval;
                Persistent = true;
                Unit = "${unitName}-health-recovery.service";
              };
            };
          }
          // projectJobTimers;

        vps.appDeployments.webhookApps.${name} = {
          compatibilityFile = "${stateDir}/compatibility.json";
          deliveryMode = cfg.delivery.mode;
          requestedReleaseFile = "${stateDir}/requested-release.json";
          updateUnit = "${updateUnitName}.service";
          requestedRevisionFile = "${stateDir}/requested-revision";
        };

        vps.services.appDeployments.metadata.health.units = lib.optional isService "${unitName}.service";

        virtualisation.oci-containers.containers = lib.mapAttrs' (
          auxiliaryName: auxiliary:
          lib.nameValuePair (projectContainerName auxiliaryName) {
            image = auxiliary.image;
            cmd = auxiliary.command;
            ports = lib.mapAttrsToList (
              portName: port:
              "127.0.0.1:${
                toString projectAuxiliaryPorts.${auxiliaryName}.${portName}
              }:${toString port.containerPort}/${port.protocol}"
            ) auxiliary.ports;
            extraOptions = [ "--init" ];
          }
        ) projectAuxiliaries;

        vps.services.caddy.virtualHosts = lib.optionalAttrs (cfg.domain != null) {
          ${cfg.domain} =
            if isService && !isProject then
              {
                backend = {
                  address = cfg.host;
                  inherit (cfg) port;
                };
                tailscaleOnly = !cfg.public;
              }
            else if isService then
              {
                extraConfig = projectServiceCaddyConfig;
                tailscaleOnly = !cfg.public;
              }
            else
              {
                extraConfig = staticCaddyConfig;
                tailscaleOnly = !cfg.public;
              };
        };
      }
      // lib.optionalAttrs (hasSops && cfg.source.giteaTokenSecretName != null) {
        sops.secrets.${cfg.source.giteaTokenSecretName} = {
          owner = "root";
          mode = "0400";
        };
      }
    else
      { };
  runtimeModule = {
    config = runtimeConfig;
  };
in
if internal then
  runtimeModule
else
  {
    config.vps.services.appDeployments.apps.${app.name} = declaredApp;
  }
