# The release pipeline every release host runs, whatever supervises its services: NixOS with
# systemd (modules/nixos/deploy/nix-flake-service.nix) and nix-darwin with launchd
# (modules/darwin/projects.nix). For one app it writes the update script, which binds a candidate
# descriptor, builds or realises the artifact, runs pre-deploy tasks, cuts over current/previous
# with GC roots, restarts the service, checks its health and rolls back, and the scripts its
# service, activation and tasks run.
#
# `supervisor` gives the platform's side of it:
#   path            packages its commands need
#   definitions     shell text the update script runs first, such as functions the commands call
#   serviceActive, stopService, startService, restartService, activate
#                   one-line commands for the service and the activation
#   runPreDeployTask
#                   a command run as `<it> TASK TIMEOUT_SEC` that runs a pre-deploy task of the
#                   staged artifact (preDeployTaskScript) as the release user, within the timeout
{
  lib,
  pkgs,
  app,
  supervisor,
  # Source delivery's Git credentials: shell text that may set git_config_file.
  gitTokenSetup ? "",
}:
let
  # Plans release compatibility on the host with the same runtime that serves
  # Project actions.
  projectPlanner = lib.getExe ((import ../project-runtime.nix { inherit lib; }).package pkgs);
  cfg = lib.recursiveUpdate {
    enable = true;
    public = false;
    backend = "service";
    host = "127.0.0.1";
    port = null;
    domain = null;
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
  # Normalized by lib.projectDescriptor.releaseApp.
  descriptor = if isProject then cfg.project.descriptor else null;
  projectRelease = if isProject then descriptor.release else null;
  projectSecrets = if isProject then cfg.project.secrets else { };
  projectActivationExecutable = if isProject then projectRelease.activationExecutable else null;
  projectStateDirectories = if isProject then projectRelease.stateDirectories else [ ];
  projectAuxiliaries = if isProject then projectRelease.ociAuxiliaries else { };
  projectAuxiliaryPorts = if isProject then cfg.project.auxiliaryPorts else { };
  projectJobs = if isProject then cfg.project.jobs else { };
  projectMemory = if isProject then cfg.project.resources.memory else { };
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
          if port.protocol != "tcp" then
            throw "app-deployment/${name}: Project Runtime cannot expose UDP auxiliary Endpoint ${endpointName}"
          else
            {
              name = endpointName;
              value = {
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
  projectRuntimeBaseManifest = pkgs.writeText "project-release-runtime-base-${name}.json" (
    builtins.toJSON ({
      schemaVersion = 3;
      project = name;
      realization = "release";
      paths = {
        state = runtimeDir;
        runtime = runtimeDir;
      };
      endpoints = {
        ${projectRelease.action} = defaultRuntimeEndpoint;
      }
      // auxiliaryRuntimeEndpoints;
      instanceId =
        if cfg.project.instanceId != null then
          cfg.project.instanceId
        else
          throw "app-deployments.${name}: Project v4 requires a stable instanceId";
      bindings = { };
    })
    + "\n"
  );
  projectBindingPolicy = pkgs.writeText "project-release-bindings-${name}.json" (
    builtins.toJSON {
      descriptor = descriptor;
      managedJobs = builtins.attrNames projectJobs;
      bindings = {
        parameters = cfg.project.parameterBindings;
        secrets = builtins.attrNames projectSecrets;
        resources = cfg.project.bindings;
      };
    }
    + "\n"
  );
  projectSecretBindings = pkgs.writeText "project-release-secret-bindings-${name}.json" (
    builtins.toJSON projectSecrets + "\n"
  );
  deployedProjectRuntimeManifest = "${stateDir}/project-runtime.json";
  deployedProjectReleasePlan = "${stateDir}/release-plan.json";
  # A placement (the webhook's placements.py) replaces the host's bindings at runtime. Scripts
  # that bind a descriptor read its copies of the policy, secret bindings and runtime base once
  # it has written them, and the compiled ones before.
  placementDir = "${stateDir}/placement";
  usePlacement = ''
    binding_policy=${lib.escapeShellArg projectBindingPolicy}
    secret_bindings=${lib.escapeShellArg projectSecretBindings}
    runtime_base=${lib.escapeShellArg projectRuntimeBaseManifest}
    if [ -f ${lib.escapeShellArg placementDir}/policy.json ]; then
      binding_policy=${lib.escapeShellArg placementDir}/policy.json
      secret_bindings=${lib.escapeShellArg placementDir}/secrets.json
      runtime_base=${lib.escapeShellArg placementDir}/runtime-base.json
    fi
  '';

  shellPath = lib.makeBinPath (
    [
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
    ]
    ++ supervisor.path
    ++ [ pkgs.util-linux ]
  );

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
  customHealthArgs = lib.concatLists (
    lib.mapAttrsToList (header: value: [
      "-H"
      "${header}: ${value}"
    ]) cfg.health.headers
  );
  # Sets health_args: the compiled headers, or those of the placement's hostname.
  healthArgs = ''
    health_args=(${lib.escapeShellArgs healthCurlArgs})
    ${lib.optionalString (isProject && cfg.health.hostHeader == null) ''
      if [ -s ${lib.escapeShellArg placementDir}/host ]; then
        placement_host="$(cat ${lib.escapeShellArg placementDir}/host)"
        health_args=(-H "Host: $placement_host" -H "X-Forwarded-Host: $placement_host" \
          -H "X-Forwarded-Port: 443" -H "X-Forwarded-Proto: https" ${lib.escapeShellArgs customHealthArgs})
      fi
    ''}
  '';
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

  serviceHealthScript =
    if isProject then
      ''
        ${healthArgs}
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
                "''${health_args[@]}" \
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
        ${healthArgs}
        check_service_health() {
          local deadline now path
          deadline=$((SECONDS + ${toString cfg.health.startupTimeoutSec}))

          while true; do
            for path in ${lib.escapeShellArgs cfg.health.paths}; do
              if ! ${pkgs.curl}/bin/curl -fsS --max-time ${toString cfg.health.requestTimeoutSec} \
                "''${health_args[@]}" \
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

  updateScript = pkgs.writeShellScript "app-deployment-${name}-update" ''
    set -euo pipefail

    export PATH=${lib.escapeShellArg shellPath}:$PATH
    export NIX_CONFIG=$'extra-experimental-features = nix-command flakes\nwarn-dirty = false${
      lib.optionalString (
        cfg.delivery.mode == "cache"
      ) "\\nextra-substituters = ${cfg.delivery.cacheStore}\\nbuilders = \\nmax-jobs = 0"
    }'
    ${supervisor.definitions}
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
      ${usePlacement}
      bind_descriptor() {
        local descriptor="$1"
        local runtime="$2"
        local plan="$3"
        local revision="''${4:-}"
        local result="$state_dir/compatibility.json.next"

        if ! ${projectPlanner} plan-release \
          --host "$binding_policy" \
          --candidate "$descriptor" > "$result"; then
          rm -f "$result"
          return 1
        fi

        jq -S . "$descriptor" > "$state_dir/artifact-descriptor.json.next"
        jq -S '.descriptor' "$binding_policy" \
          > "$state_dir/expected-descriptor.json.next"
        if ! jq -e '.compatible' "$result" >/dev/null; then
          jq -r '.reasons[] | "app-deployment/${name}: " + .' "$result" >&2
          mv -f "$result" "$state_dir/compatibility.json"
          mv -f "$state_dir/expected-descriptor.json.next" "$state_dir/expected-descriptor.json"
          mv -f "$state_dir/artifact-descriptor.json.next" "$state_dir/artifact-descriptor.json"
          return 1
        fi

        jq -S -s --arg revision "$revision" \
          '.[0] + {parameters: .[1].parameters, secrets: .[1].secrets}
            + {bindings: .[1].bindings}
            + (if $revision == "" then {} else {revision: $revision} end)' \
          "$runtime_base" "$result" > "$runtime"
        jq -S '.releasePlan' "$result" > "$plan"
        mv -f "$result" "$state_dir/compatibility.json"
        mv -f "$state_dir/expected-descriptor.json.next" "$state_dir/expected-descriptor.json"
        mv -f "$state_dir/artifact-descriptor.json.next" "$state_dir/artifact-descriptor.json"
      }

      current_descriptor_matches() {
        local descriptor expected_runtime expected_plan revision
        descriptor="$current_link/share/project/descriptor.json"
        expected_runtime="$state_dir/current-project-runtime.json.next"
        expected_plan="$state_dir/current-release-plan.json.next"
        [ -f "$descriptor" ] || return 1
        revision=""
        ${lib.optionalString cfg.project.exposeRevision ''
          revision="$(cat "$current_revision_file")"
        ''}
        bind_descriptor "$descriptor" "$expected_runtime" "$expected_plan" "$revision" || return 1
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
          "${supervisor.serviceActive} && [ -x \"$current_link/bin/${cfg.executable}\" ] && ${lib.optionalString isProject "current_descriptor_matches && "}check_service_health${lib.optionalString isProject " \"$release_plan\""}"
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
      candidate_revision=""
      ${lib.optionalString cfg.project.exposeRevision ''
        candidate_revision="$resolved_revision"
      ''}
      if ! bind_descriptor "$descriptor_file" "$candidate_runtime_manifest.next" "$candidate_release_plan.next" "$candidate_revision"; then
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
      if [ "$new_store_path" = "$old_store_path" ] \
        ${lib.optionalString isProject ''
          && cmp -s "$candidate_runtime_manifest" "$runtime_manifest" \
          && cmp -s "$candidate_release_plan" "$release_plan" \
        ''}&& ${
          if isService then
            "${lib.optionalString isProject "current_descriptor_matches && "}${supervisor.serviceActive} && check_service_health${lib.optionalString isProject " \"$release_plan\""}"
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
      # The tasks also gate a restart that only rebinds the running release, such as a placement's
      # redeploy: they are what waits for it to be idle. A stopped release has nothing to wait for.
      if [ "$new_store_path" != "$old_store_path" ] \
        || ${supervisor.serviceActive}; then
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
            if ! ${supervisor.runPreDeployTask} "$task" "$timeout"; then
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
        ${lib.optionalString isService supervisor.stopService}
        if ! ${supervisor.activate}; then
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
            if ! ${supervisor.activate}; then
              echo "app-deployment/${name}: rollback activation also failed" >&2
            fi
            ${lib.optionalString isService supervisor.startService}
          else
            rm -f "$current_link" "$current_revision_file"
            sync_gcroots
          fi
          exit 1
        fi
      fi
    ''}
    ${lib.optionalString isService supervisor.restartService}

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
      ${lib.optionalString (isService && runsProjectActivation) supervisor.stopService}
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
        if ! ${supervisor.activate}; then
          echo "app-deployment/${name}: rollback activation failed" >&2
        fi
      ''}
      ${
        if isService then
          ''
            ${supervisor.restartService}
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

    # A switch can move the host's contract or bindings ahead of the active release. It keeps
    # running on the plan it was activated with until an activation catches up.
    keep_active() {
      echo "app-deployment/${name}: $1" >&2
      if [ -f "$plan" ]; then
        echo "app-deployment/${name}: keeps the active release on its last plan until a compatible one is activated" >&2
        exit 0
      fi
      exit 1
    }

    ${usePlacement}
    result="$(${projectPlanner} plan-release \
      --host "$binding_policy" \
      --candidate "$descriptor")"
    if ! ${pkgs.jq}/bin/jq -e '.compatible' <<<"$result" >/dev/null; then
      keep_active "$(${pkgs.jq}/bin/jq -r '.reasons | join("; ")' <<<"$result")"
    fi

    revision=""
    ${lib.optionalString cfg.project.exposeRevision ''
      revision="$(cat ${lib.escapeShellArg stateDir}/current-revision)"
    ''}
    expected_runtime="$(${pkgs.jq}/bin/jq -S -s --arg revision "$revision" \
      '.[0] + {parameters: .[1].parameters, secrets: .[1].secrets}
        + {bindings: .[1].bindings}
        + (if $revision == "" then {} else {revision: $revision} end)' \
      "$runtime_base" <(printf '%s\n' "$result"))"
    actual_runtime="$(${pkgs.jq}/bin/jq -S . "$runtime")"
    if [ "$expected_runtime" != "$actual_runtime" ]; then
      keep_active "the Runtime Context is stale"
    fi

    ${pkgs.jq}/bin/jq -S '.releasePlan' <<<"$result" > "$plan.next"
    chmod 0644 "$plan.next"
    mv -f "$plan.next" "$plan"
  '';
  # Whether the deployed artifact may run. The service keeps running its active release while the
  # host's contract or bindings are ahead of it (see the release plan); jobs and health recovery
  # wait for a compatible one.
  mkArtifactCondition =
    scriptName: keepActive:
    pkgs.writeShellScript "app-deployment-${name}-${scriptName}" ''
      set -euo pipefail

      mismatch() {
        echo "app-deployment/${name}: $1" >&2
        ${
          if keepActive then
            ''
              echo "app-deployment/${name}: runs the active release until a compatible one is activated" >&2
              exit 0
            ''
          else
            "exit 1"
        }
      }

      current=${lib.escapeShellArg stateDir}/current
      executable="$current/bin/${cfg.executable}"
      descriptor="$current/share/project/descriptor.json"

      if [ ! -x "$executable" ] || [ ! -f "$descriptor" ]${lib.optionalString isProject " || [ ! -f ${lib.escapeShellArg deployedProjectRuntimeManifest} ] || [ ! -f ${lib.escapeShellArg deployedProjectReleasePlan} ]"}; then
        echo "app-deployment/${name}: no descriptor-compatible Project artifact is deployed" >&2
        exit 1
      fi

      ${usePlacement}
      result="$(${projectPlanner} plan-release \
        --host "$binding_policy" \
        --candidate "$descriptor")"
      if ! ${pkgs.jq}/bin/jq -e '.compatible' <<<"$result" >/dev/null; then
        mismatch "$(${pkgs.jq}/bin/jq -r '.reasons | join("; ")' <<<"$result")"
      fi

      revision=""
      ${lib.optionalString cfg.project.exposeRevision ''
        revision="$(cat ${lib.escapeShellArg stateDir}/current-revision)"
      ''}
      expected_runtime="$(${pkgs.jq}/bin/jq -S -s --arg revision "$revision" \
        '.[0] + {parameters: .[1].parameters, secrets: .[1].secrets}
          + {bindings: .[1].bindings}
          + (if $revision == "" then {} else {revision: $revision} end)' \
        "$runtime_base" <(printf '%s\n' "$result"))"
      expected_release_plan="$(${pkgs.jq}/bin/jq -S '.releasePlan' <<<"$result")"
      actual_runtime="$(${pkgs.jq}/bin/jq -S . ${lib.escapeShellArg deployedProjectRuntimeManifest})"
      actual_release_plan="$(${pkgs.jq}/bin/jq -S . ${lib.escapeShellArg deployedProjectReleasePlan})"
      if [ "$expected_runtime" != "$actual_runtime" ] || [ "$expected_release_plan" != "$actual_release_plan" ]; then
        mismatch "deployed Runtime Context or Release plan is stale"
      fi
    '';
  projectArtifactConditionScript = mkArtifactCondition "artifact-condition" false;
  projectServiceConditionScript = mkArtifactCondition "service-condition" true;
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
in
{
  inherit
    activationScript
    cfg
    deployedProjectReleasePlan
    deployedProjectRuntimeManifest
    generatedUserName
    groupName
    healthArgs
    homeDir
    isProject
    isService
    name
    needsRuntimeUser
    placementDir
    projectActivationExecutable
    projectArtifactConditionScript
    projectAuxiliaries
    projectAuxiliaryPorts
    projectBindingPolicy
    projectJobs
    projectMemory
    projectPreDeployTaskScript
    projectRelease
    projectReleasePlanBootstrapScript
    projectRuntimeBaseManifest
    projectSecretBindings
    projectSecrets
    projectServiceConditionScript
    projectStateDirectories
    runsProjectActivation
    runtimeDir
    serviceHealthScript
    startScript
    stateDir
    updateScript
    userName
    workingDirectory
    ;
}
