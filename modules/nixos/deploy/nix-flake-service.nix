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
  projectPreDeployTasks = if isProject then projectRelease.preDeployTasks else { };
  projectPreDeployOrder =
    if isProject then projectDescriptor.releaseTaskOrder projectRelease else [ ];
  projectMemory = if isProject then cfg.project.resources.memory else { };
  projectRuntimeSchemaVersion = if isProject then descriptor.schemaVersion else 1;
  unitName = "app-deployment-${name}";
  updateUnitName = "${unitName}-update";
  activationUnitName = "${unitName}-activate";
  userName = "app-${name}";
  stateDir = "/var/lib/app-deployments/${name}";
  runtimeDir = "${stateDir}/runtime";
  needsRuntimeUser =
    isService
    || (
      isProject
      && (projectActivationExecutable != null || projectJobs != { } || projectPreDeployTasks != { })
    );
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
  projectRuntimeManifest = pkgs.writeText "project-release-runtime-${name}.json" (
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
      parameters = if isProject then cfg.project.parameters else { };
      secrets = lib.mapAttrs (secretName: _: secretName) projectSecrets;
    }
    + "\n"
  );
  expectedProjectDescriptor = pkgs.writeText "project-release-descriptor-${name}.json" (
    builtins.toJSON cfg.project.descriptor + "\n"
  );
  deployedProjectRuntimeManifest = "${stateDir}/project-runtime.json";

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

  serviceHealthScript = ''
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

  staticHealthScript = ''
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
    export NIX_CONFIG=$'experimental-features = nix-command flakes\nwarn-dirty = false'

    state_dir=${lib.escapeShellArg stateDir}
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
    candidate_link="$state_dir/candidate"
    candidate_runtime_manifest="$state_dir/candidate-project-runtime.json"
    candidate_gcroot="$gcroots_dir/candidate"
    git_config_file=""

    cleanup_candidate() {
      rm -f \
        "$candidate_link" "$candidate_link.next" \
        "$candidate_runtime_manifest" "$candidate_runtime_manifest.next" \
        "$candidate_gcroot" "$candidate_gcroot.next"
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
    if [ -s "$requested_revision_file" ]; then
      requested_revision="$(head -n 1 "$requested_revision_file" | tr -d '\r\n')"
      rm -f "$requested_revision_file"
    fi

    if [ -n "$requested_revision" ]; then
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
      record_matching_descriptor() {
        local descriptor="$1"
        jq -e -S . ${lib.escapeShellArg expectedProjectDescriptor} > "$state_dir/expected-descriptor.json.next"
        if ! jq -e -S . "$descriptor" > "$state_dir/artifact-descriptor.json.next" \
          || ! cmp -s "$state_dir/expected-descriptor.json.next" "$state_dir/artifact-descriptor.json.next"; then
          rm -f "$state_dir/expected-descriptor.json.next" "$state_dir/artifact-descriptor.json.next"
          return 1
        fi
        mv -f "$state_dir/expected-descriptor.json.next" "$state_dir/expected-descriptor.json"
        mv -f "$state_dir/artifact-descriptor.json.next" "$state_dir/artifact-descriptor.json"
      }

      current_descriptor_matches() {
        local descriptor
        descriptor="$current_link/share/project/descriptor.json"
        [ -f "$descriptor" ] || return 1
        record_matching_descriptor "$descriptor"
      }

      runtime_manifest_matches() {
        [ -f "$runtime_manifest" ] \
          && cmp -s ${lib.escapeShellArg projectRuntimeManifest} "$runtime_manifest"
      }
    ''}

    ${gitTokenSetup}

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

    ${if isService then serviceHealthScript else staticHealthScript}

    if [ -n "$resolved_revision" ] \
      && [ -f "$current_revision_file" ] \
      && [ "$(cat "$current_revision_file")" = "$resolved_revision" ]; then
      sync_gcroots
      if ${
        if isService then
          "systemctl is-active --quiet ${lib.escapeShellArg "${unitName}.service"} && [ -x \"$current_link/bin/${cfg.executable}\" ] && ${lib.optionalString isProject "current_descriptor_matches && runtime_manifest_matches && "}check_service_health"
        else
          "[ -d \"$current_link\" ] && ${lib.optionalString isProject "current_descriptor_matches && "}check_static_health \"$current_link\""
      }; then
        echo "app-deployment/${name}: already active at $resolved_revision"
        exit 0
      fi

      echo "app-deployment/${name}: $resolved_revision is active but failed deployment checks; redeploying"
    fi

    echo "app-deployment/${name}: building $build_flake_ref#${cfg.package}"
    new_store_path="$(nix build --no-link --print-out-paths "$build_flake_ref#${cfg.package}")"
    ${lib.optionalString isProject ''
      descriptor_file="$new_store_path/share/project/descriptor.json"
      if [ ! -f "$descriptor_file" ]; then
        echo "app-deployment/${name}: Project artifact is missing $descriptor_file" >&2
        exit 1
      fi
      if ! record_matching_descriptor "$descriptor_file"; then
        echo "app-deployment/${name}: Project artifact descriptor does not match host policy" >&2
        exit 1
      fi
      ${lib.optionalString (projectActivationExecutable != null) ''
        if [ ! -x "$new_store_path/bin/${projectActivationExecutable}" ]; then
          echo "app-deployment/${name}: missing activation executable $new_store_path/bin/${projectActivationExecutable}" >&2
          exit 1
        fi
      ''}
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
          check_static_health "$new_store_path"
        ''
    }

    old_store_path=""
    if [ -L "$current_link" ]; then
      old_store_path="$(readlink "$current_link")"
      if [ "$new_store_path" = "$old_store_path" ] && ${
        if isService then
          "${lib.optionalString isProject "runtime_manifest_matches && "}systemctl is-active --quiet ${lib.escapeShellArg "${unitName}.service"} && check_service_health"
        else
          "check_static_health \"$current_link\""
      }; then
        printf '%s\n' "$resolved_revision" > "$current_revision_file"
        sync_gcroots
        echo "app-deployment/${name}: revision $resolved_revision already produces the active output"
        exit 0
      fi
    fi

    ${lib.optionalString (projectPreDeployOrder != [ ]) ''
      if [ "$new_store_path" != "$old_store_path" ]; then
        echo "app-deployment/${name}: running pre-deploy tasks for $resolved_revision"
        mkdir -p "$gcroots_dir"
        ln -sfn "$new_store_path" "$candidate_link.next"
        mv -Tf "$candidate_link.next" "$candidate_link"
        ln -sfn "$new_store_path" "$candidate_gcroot.next"
        mv -Tf "$candidate_gcroot.next" "$candidate_gcroot"
        cp ${lib.escapeShellArg projectRuntimeManifest} "$candidate_runtime_manifest.next"
        chmod 0644 "$candidate_runtime_manifest.next"
        mv -f "$candidate_runtime_manifest.next" "$candidate_runtime_manifest"
        ${lib.concatMapStringsSep "\n" (
          taskName: "systemctl start ${lib.escapeShellArg "${unitName}-pre-deploy-${taskName}.service"}"
        ) projectPreDeployOrder}
        cleanup_candidate
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
      ''}
    fi

    ${lib.optionalString isProject ''
      cp ${lib.escapeShellArg projectRuntimeManifest} "$runtime_manifest.next"
      chmod 0644 "$runtime_manifest.next"
      mv -f "$runtime_manifest.next" "$runtime_manifest"
    ''}
    ln -sfn "$new_store_path" "$current_link.next"
    mv -Tf "$current_link.next" "$current_link"
    printf '%s\n' "$resolved_revision" > "$current_revision_file"
    sync_gcroots

    ${lib.optionalString (projectActivationExecutable != null) ''
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

    if ${if isService then "check_service_health" else "check_static_health \"$current_link\""}; then
      echo "app-deployment/${name}: deployed $resolved_revision"
      exit 0
    fi

    if [ -n "$old_store_path" ]; then
      echo "app-deployment/${name}: health failed, rolling back to $old_store_path" >&2
      ${lib.optionalString (
        isService && projectActivationExecutable != null
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
      ''}
      if [ -f "$previous_revision_file" ]; then
        cp "$previous_revision_file" "$current_revision_file"
      fi
      sync_gcroots
      ${lib.optionalString (projectActivationExecutable != null) ''
        if ! systemctl start ${lib.escapeShellArg "${activationUnitName}.service"}; then
          echo "app-deployment/${name}: rollback activation failed" >&2
        fi
      ''}
      ${
        if isService then
          ''
            systemctl restart ${lib.escapeShellArg "${unitName}.service"}
            check_service_health
          ''
        else
          ''
            check_static_health "$current_link"
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
  projectArtifactConditionScript = pkgs.writeShellScript "app-deployment-${name}-artifact-condition" ''
    set -euo pipefail

    current=${lib.escapeShellArg stateDir}/current
    executable="$current/bin/${cfg.executable}"
    descriptor="$current/share/project/descriptor.json"

    if [ ! -x "$executable" ] || [ ! -f "$descriptor" ]${lib.optionalString isProject " || [ ! -f ${lib.escapeShellArg deployedProjectRuntimeManifest} ]"}; then
      echo "app-deployment/${name}: no descriptor-compatible Project artifact is deployed" >&2
      exit 1
    fi

    actual="$(${pkgs.jq}/bin/jq -e -S . "$descriptor")"
    expected="$(${pkgs.jq}/bin/jq -e -S . ${lib.escapeShellArg expectedProjectDescriptor})"
    if [ "$actual" != "$expected" ]; then
      echo "app-deployment/${name}: deployed Project artifact does not match host policy" >&2
      exit 1
    fi
  '';
  activationScript = pkgs.writeShellScript "app-deployment-${name}-activate" ''
    set -euo pipefail

    current=${lib.escapeShellArg stateDir}/current
    descriptor="$current/share/project/descriptor.json"
    activation_executable="$(${pkgs.jq}/bin/jq -r '.release.activationExecutable // empty' "$descriptor")"
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
  projectPreDeployTaskScripts = lib.mapAttrs (
    taskName: task:
    pkgs.writeShellScript "app-deployment-${name}-pre-deploy-${taskName}" ''
      set -euo pipefail

      candidate=${lib.escapeShellArg stateDir}/candidate
      runtime_manifest=${lib.escapeShellArg stateDir}/candidate-project-runtime.json
      executable="$candidate/bin/${cfg.executable}"
      if [ ! -x "$executable" ] || [ ! -f "$runtime_manifest" ]; then
        echo "app-deployment/${name}: no staged Project artifact for pre-deploy task ${taskName}" >&2
        exit 1
      fi

      export PROJECT_RUNTIME_FILE="$runtime_manifest"
      export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-${runtimeDir}/secrets}"
      exec "$executable" ${lib.escapeShellArg task.action}
    ''
  ) projectPreDeployTasks;
  projectPreDeployTaskServices = lib.mapAttrs' (
    taskName: task:
    let
      taskSecrets = lib.filterAttrs (secretName: _: builtins.elem secretName task.secrets) projectSecrets;
    in
    lib.nameValuePair "${unitName}-pre-deploy-${taskName}" {
      description = "Run Project pre-deploy task '${name}/${taskName}'";
      after = [ "network-online.target" ] ++ projectContainerUnits ++ externalAfterUnits;
      wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
      requires = externalRequiredUnits;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = projectPreDeployTaskScripts.${taskName};
        User = userName;
        Group = userName;
        WorkingDirectory = stateDir;
        TimeoutStartSec = "${toString task.timeoutSec}s";
      }
      // projectHardening
      // lib.optionalAttrs (taskSecrets != { }) {
        LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") taskSecrets;
      };
    }
  ) projectPreDeployTasks;
  projectJobScripts = lib.mapAttrs (
    jobName: _policy:
    let
      action = projectRelease.maintenanceJobs.${jobName}.action;
    in
    pkgs.writeShellScript "app-deployment-${name}-job-${jobName}" ''
      set -euo pipefail

      current=${lib.escapeShellArg stateDir}/current
      executable="$current/bin/${cfg.executable}"
      if [ ! -x "$executable" ]; then
        echo "app-deployment/${name}: no deployed Release executable at $executable" >&2
        exit 1
      fi

      export PROJECT_RUNTIME_FILE=${lib.escapeShellArg deployedProjectRuntimeManifest}
      export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-${runtimeDir}/secrets}"
      exec "$executable" ${lib.escapeShellArg action}
    ''
  ) projectJobs;
  projectJobServices = lib.mapAttrs' (
    jobName: policy:
    lib.nameValuePair "${unitName}-job-${jobName}" {
      description = "Run Project Release job '${name}/${jobName}'";
      after = [ "network-online.target" ] ++ projectContainerUnits ++ externalAfterUnits;
      wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
      requires = externalRequiredUnits;
      serviceConfig = {
        Type = "oneshot";
        ExecCondition = projectArtifactConditionScript;
        ExecStart = projectJobScripts.${jobName};
        User = userName;
        Group = userName;
        WorkingDirectory = stateDir;
      }
      // projectHardening
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
    reverse_proxy ${cfg.host}:${toString cfg.port}
  '';
  projectHealthRecoveryScript = pkgs.writeShellScript "app-deployment-${name}-health-recovery" ''
    set -euo pipefail

    check_once() {
      local path
      for path in ${lib.escapeShellArgs cfg.health.paths}; do
        ${pkgs.curl}/bin/curl -fsS --max-time ${toString cfg.health.requestTimeoutSec} \
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
    check_service_health
  '';
  projectHardening = {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ runtimeDir ];
    RemoveIPC = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    TimeoutStopSec = "30s";
    UMask = "0027";
  }
  // lib.optionalAttrs (projectMemory.high != null) { MemoryHigh = projectMemory.high; }
  // lib.optionalAttrs (projectMemory.max != null) { MemoryMax = projectMemory.max; }
  // lib.optionalAttrs (projectMemory.swapMax != null) { MemorySwapMax = projectMemory.swapMax; };

  runtimeConfig =
    if cfg.enable then
      {
        users.users = lib.optionalAttrs needsRuntimeUser {
          ${userName} = {
            isSystemUser = true;
            group = userName;
            home = stateDir;
          };
        };
        users.groups = lib.optionalAttrs needsRuntimeUser {
          ${userName} = { };
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/app-deployments 0755 root root -"
          "d ${stateDir} 0755 root root -"
        ]
        ++ lib.optionals needsRuntimeUser (
          [
            "d ${runtimeDir} 0750 ${userName} ${userName} -"
            "d ${runtimeDir}/secrets 0700 ${userName} ${userName} -"
          ]
          ++ (map (dir: "d ${runtimeDir}/${dir} 0750 ${userName} ${userName} -") projectStateDirectories)
          ++ (map (dir: "d ${dir} 0750 ${userName} ${userName} -") cfg.stateDirs)
        );

        systemd.services =
          projectPreDeployTaskServices
          // projectJobServices
          // {
            ${unitName} = lib.mkIf isService {
              description = "App deployment '${name}'";
              after = [ "network-online.target" ] ++ projectContainerUnits ++ externalAfterUnits;
              wants = [ "network-online.target" ] ++ projectContainerUnits ++ externalWantedUnits;
              requires = externalRequiredUnits;
              environment =
                (
                  if isProject then
                    { HOME = stateDir; }
                  else
                    {
                      HOST = cfg.host;
                      PORT = toString cfg.port;
                      HOME = stateDir;
                    }
                )
                // cfg.environment;
              path = cfg.path;
              serviceConfig = {
                ExecStart = startScript;
                Restart = "always";
                RestartSec = "15s";
                User = userName;
                Group = userName;
                WorkingDirectory = stateDir;
              }
              // lib.optionalAttrs isProject {
                ExecCondition = projectArtifactConditionScript;
              }
              // lib.optionalAttrs isProject projectHardening
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

            ${activationUnitName} = lib.mkIf (projectActivationExecutable != null) {
              description = "Activate Project Release '${name}'";
              after = projectContainerUnits ++ externalAfterUnits;
              wants = projectContainerUnits ++ externalWantedUnits;
              requires = externalRequiredUnits;
              serviceConfig = {
                Type = "oneshot";
                ExecStart = activationScript;
                User = userName;
                Group = userName;
                WorkingDirectory = stateDir;
              }
              // projectHardening
              // lib.optionalAttrs (projectSecrets != { }) {
                LoadCredential = lib.mapAttrsToList (secretName: path: "${secretName}:${path}") projectSecrets;
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
                    TimeoutStartSec = "${toString (cfg.health.startupTimeoutSec + 10)}s";
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
