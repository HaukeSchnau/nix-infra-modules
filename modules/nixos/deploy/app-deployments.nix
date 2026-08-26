{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.vps.appDeployments;
  apps = config.vps.services.appDeployments.apps;
  hasSops = options ? sops;
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };
  nixFlakeService = import ./nix-flake-service.nix;
  projectDescriptor = import ../../../lib/project-descriptor.nix { inherit lib; };

  appType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to run and reconcile the ${name} application deployment.";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the generated Caddy route is publicly reachable.";
        };

        backend = lib.mkOption {
          type = lib.types.enum [
            "service"
            "static"
          ];
          default = "service";
          description = ''
            Runtime used for the built flake output. Service deployments run an
            executable behind Caddy; static deployments are served directly by
            Caddy from the atomically activated store path.
          '';
        };

        host = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = "Address the deployed application listens on.";
        };

        port = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "Port the deployed service listens on.";
        };

        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional domain exposed through the fleet Caddy service.";
        };

        package = lib.mkOption {
          type = lib.types.str;
          default = "default";
          description = "Package attribute built from the source flake.";
        };

        executable = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Executable expected in a service package's bin directory.";
        };

        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.unspecified;
          default = { };
          description = "Environment variables passed to the application service.";
        };

        environmentFiles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "systemd environment files loaded by the application service.";
        };

        path = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Packages added to the application service PATH.";
        };

        runtime = {
          isolation = lib.mkOption {
            type = lib.types.enum [
              "isolated"
              "trusted"
            ];
            default = "isolated";
            description = ''
              Process isolation for Release actions. trusted keeps the service
              under its configured user but does not apply the systemd sandbox.
            '';
          };

          user = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Existing user for Release actions; null creates app-<name>.";
          };

          group = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Group for Release actions; defaults to the effective user.";
          };

          home = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "^/.*");
            default = null;
            description = "HOME for Release actions; defaults to managed deployment state.";
          };

          workingDirectory = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "^/.*");
            default = null;
            description = "Working directory for Release actions; defaults to managed deployment state.";
          };

          protectHome = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether systemd hides home directories from Release actions.";
          };

          readWritePaths = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "^/.*");
            default = [ ];
            description = "Additional host paths writable by Release actions.";
          };
        };

        stateDirs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Additional state directories owned by the application's system user.";
        };

        preStart = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Shell commands run before the application starts.";
        };

        serviceConfig = lib.mkOption {
          type = lib.types.attrsOf lib.types.unspecified;
          default = { };
          description = "Additional systemd service settings for the application.";
        };

        unitDependencies = {
          after = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Host units ordered before every deployment action.";
          };

          wants = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Host units weakly required and ordered before every deployment action.";
          };

          requires = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Host units strongly required and ordered before every deployment action.";
          };
        };

        project = lib.mkOption {
          default = null;
          description = ''
            Repository-owned Project descriptor and host-owned bindings. Use
            lib.projectDescriptor.releaseApp to construct this projection
            without depending on appDeployments implementation details.
          '';
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                descriptor = lib.mkOption {
                  type = lib.types.attrs;
                  description = "Repository-authored schemaVersion 1 Project descriptor.";
                };

                parameters = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                  description = "Validated, non-secret Release parameter values.";
                };

                parameterBindings = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                  internal = true;
                  description = "Unfiltered host parameter bindings retained for future compatible descriptors.";
                };

                secrets = lib.mkOption {
                  type = lib.types.attrsOf (lib.types.strMatching "^/.*");
                  default = { };
                  description = "Semantic Secret names mapped to absolute credential source paths.";
                };

                approvedOci = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "OCI auxiliary names explicitly approved by host policy.";
                };

                auxiliaryPorts = lib.mkOption {
                  type = lib.types.attrsOf (lib.types.attrsOf lib.types.port);
                  default = { };
                  internal = true;
                  description = "Adapter-assigned localhost ports for approved OCI auxiliaries.";
                };

                healthRecovery = {
                  enable = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Restart a failed Project service after periodic HTTP probes.";
                  };

                  interval = lib.mkOption {
                    type = lib.types.str;
                    default = "1min";
                    description = "Interval between Project service recovery probes.";
                  };

                  onBootSec = lib.mkOption {
                    type = lib.types.str;
                    default = "4min";
                    description = "Delay before the first Project service recovery probe.";
                  };
                };

                exposeRevision = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Add the immutable Git revision to Runtime Context v2.";
                };

                resources.memory = {
                  high = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional systemd memory pressure threshold for Release actions.";
                  };

                  max = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional systemd hard memory limit for Release actions.";
                  };

                  swapMax = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional systemd swap limit for Release actions.";
                  };
                };

                jobs = lib.mkOption {
                  default = { };
                  description = "Host schedules for descriptor-declared Release maintenance jobs.";
                  type = lib.types.attrsOf (
                    lib.types.submodule {
                      options = {
                        calendar = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "systemd calendar expression for this job.";
                        };

                        interval = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "Monotonic interval between this job's runs.";
                        };

                        onBootSec = lib.mkOption {
                          type = lib.types.str;
                          default = "5min";
                          description = "Delay before the first interval-based run.";
                        };

                        randomizedDelaySec = lib.mkOption {
                          type = lib.types.str;
                          default = "0";
                          description = "Random delay applied to each scheduled run.";
                        };

                        persistent = lib.mkOption {
                          type = lib.types.bool;
                          default = true;
                          description = "Whether missed wall-clock runs are caught up.";
                        };

                      };
                    }
                  );
                };
              };
            }
          );
        };

        static.extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = ''
            Additional Caddy directives emitted between the generated root and
            file_server directives for a static deployment.
          '';
        };

        source = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Git-backed flake URL used to build the application.";
          };

          branch = lib.mkOption {
            type = lib.types.str;
            default = "main";
            description = "Branch reconciled when no explicit revision is requested.";
          };

          netrcHost = lib.mkOption {
            type = lib.types.str;
            default = "git.example.net";
            description = "Git host matched by the optional credential rewrite.";
          };

          username = lib.mkOption {
            type = lib.types.str;
            default = "deploy";
            description = "Git username used with the optional read token.";
          };

          giteaTokenSecretName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional SOPS secret containing a Git read token.";
          };
        };

        delivery = {
          mode = lib.mkOption {
            type = lib.types.enum [
              "source"
              "cache"
            ];
            default = "source";
            description = ''
              Source delivery evaluates the configured flake on this host.
              Cache delivery accepts an immutable store path from the
              promotion webhook and only substitutes its closure.
            '';
          };

          cacheStore = lib.mkOption {
            type = lib.types.str;
            default = "https://cache.example.net/nix";
            description = "Binary cache containing promoted immutable outputs.";
          };
        };

        health = {
          host = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Address probed after an application update.";
          };

          hostHeader = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional Host header sent by application health checks.";
          };

          headers = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Additional HTTP headers sent by application health checks.";
          };

          paths = lib.mkOption {
            type = lib.types.nonEmptyListOf (lib.types.strMatching "^/.*");
            default = [ "/" ];
            description = ''
              Absolute paths that must all pass after an update. Service
              deployments probe them over HTTP; static deployments require the
              corresponding files or directory indexes in the built output.
            '';
          };

          startupTimeoutSec = lib.mkOption {
            type = lib.types.ints.positive;
            default = 60;
            description = "Maximum time to wait for all health paths after an update.";
          };

          intervalSec = lib.mkOption {
            type = lib.types.ints.positive;
            default = 2;
            description = "Delay between application health-check attempts.";
          };

          requestTimeoutSec = lib.mkOption {
            type = lib.types.ints.positive;
            default = 5;
            description = "Timeout for each application health-check request.";
          };
        };

        autoUpdate = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to periodically reconcile the source branch.";
          };

          interval = lib.mkOption {
            type = lib.types.str;
            default = "10min";
            description = "Interval between automatic application reconciliations.";
          };

          onBootSec = lib.mkOption {
            type = lib.types.str;
            default = "2min";
            description = "Delay before the first application reconciliation after boot.";
          };
        };
      };
    }
  );

  projectServiceNames = builtins.attrNames (
    lib.filterAttrs (_: app: app.project != null && app.backend == "service" && app.port == null) apps
  );
  allocatedProjectPort =
    name:
    let
      index = lib.lists.findFirstIndex (candidate: candidate == name) null projectServiceNames;
    in
    if index == null then null else cfg.projectPortRange.from + index;

  projectDescriptors = lib.mapAttrs (
    name: app:
    projectDescriptor.normalize {
      descriptor = app.project.descriptor;
      expectedProject = name;
    }
  ) (lib.filterAttrs (_: app: app.project != null) apps);
  projectAuxiliaryPortRequests = lib.concatLists (
    lib.mapAttrsToList (
      appName: descriptor:
      lib.concatLists (
        lib.mapAttrsToList (
          auxiliaryName: auxiliary:
          map (portName: {
            inherit appName auxiliaryName portName;
            key = "${appName}/${auxiliaryName}/${portName}";
          }) (builtins.attrNames auxiliary.ports)
        ) descriptor.release.ociAuxiliaries
      )
    ) projectDescriptors
  );
  projectAuxiliaryPortAssignments = builtins.listToAttrs (
    lib.imap0 (index: request: {
      name = request.key;
      value = cfg.projectAuxiliaryPortRange.from + index;
    }) projectAuxiliaryPortRequests
  );
  auxiliaryPortsFor =
    appName:
    lib.mapAttrs (
      auxiliaryName: auxiliary:
      lib.genAttrs (builtins.attrNames auxiliary.ports) (
        portName: projectAuxiliaryPortAssignments."${appName}/${auxiliaryName}/${portName}"
      )
    ) projectDescriptors.${appName}.release.ociAuxiliaries;
  resolvedApps = lib.mapAttrs (
    name: app:
    app
    // lib.optionalAttrs (app.project != null && app.backend == "service" && app.port == null) {
      port = allocatedProjectPort name;
    }
    // lib.optionalAttrs (app.project != null) {
      project = app.project // {
        auxiliaryPorts = auxiliaryPortsFor name;
      };
    }
  ) apps;

  projectCommandApps = lib.filterAttrs (
    _: app: app.enable && app.backend == "service" && app.project != null
  ) resolvedApps;
  projectCommandRecords = lib.mapAttrs (
    name: app:
    let
      stateDir = "/var/lib/app-deployments/${name}";
      runtimeDir = "${stateDir}/runtime";
      user = if app.runtime.user == null then "app-${name}" else app.runtime.user;
      group = if app.runtime.group == null then user else app.runtime.group;
      home = if app.runtime.home == null then stateDir else app.runtime.home;
      workingDirectory =
        if app.runtime.workingDirectory == null then stateDir else app.runtime.workingDirectory;
      secretBindings = pkgs.writeText "project-release-command-secrets-${name}.json" (
        builtins.toJSON app.project.secrets + "\n"
      );
      runner = pkgs.writeShellScript "project-release-command-${name}" ''
        set -euo pipefail

        command_name="$1"
        shift
        state_dir=${lib.escapeShellArg stateDir}
        release_plan="$state_dir/release-plan.json"
        executable="$state_dir/current/bin/${app.executable}"
        action="$(${lib.getExe pkgs.jq} --exit-status --raw-output \
          --arg command "$command_name" '.commands[$command].action' "$release_plan")"

        export PROJECT_RUNTIME_FILE="$state_dir/project-runtime.json"
        export PROJECT_SECRETS_DIR="''${CREDENTIALS_DIRECTORY:-$state_dir/runtime/secrets}"
        exec "$executable" "$action" "$@"
      '';
    in
    {
      inherit
        app
        group
        home
        runner
        secretBindings
        stateDir
        runtimeDir
        user
        workingDirectory
        ;
    }
  ) projectCommandApps;
  projectReleaseCommand = pkgs.writeShellApplication {
    name = "project-release-command";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "project-release-command: must run as root" >&2
        exit 77
      fi
      if [ "$#" -lt 2 ]; then
        echo "usage: project-release-command <project> <command> [arguments...]" >&2
        exit 64
      fi

      project="$1"
      command_name="$2"
      shift 2
      case "$project" in
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: record: ''
            ${lib.escapeShellArg name})
              state_dir=${lib.escapeShellArg record.stateDir}
              runtime_dir=${lib.escapeShellArg record.runtimeDir}
              release_user=${lib.escapeShellArg record.user}
              release_group=${lib.escapeShellArg record.group}
              release_home=${lib.escapeShellArg record.home}
              working_directory=${lib.escapeShellArg record.workingDirectory}
              command_runner=${lib.escapeShellArg record.runner}
              secret_bindings=${lib.escapeShellArg record.secretBindings}
              isolation=${lib.escapeShellArg record.app.runtime.isolation}
              protect_home=${lib.escapeShellArg (if record.app.runtime.protectHome then "yes" else "no")}
              read_write_paths=${lib.escapeShellArg (lib.concatStringsSep " " record.app.runtime.readWritePaths)}
              required_units=${lib.escapeShellArg (lib.concatStringsSep " " record.app.unitDependencies.requires)}
              wanted_units=${lib.escapeShellArg (lib.concatStringsSep " " record.app.unitDependencies.wants)}
              after_units=${lib.escapeShellArg (lib.concatStringsSep " " record.app.unitDependencies.after)}
              ;;
          '') projectCommandRecords
        )}
        *)
          echo "project-release-command: unknown Project: $project" >&2
          exit 66
          ;;
      esac

      release_plan="$state_dir/release-plan.json"
      if ! jq --exit-status --arg command "$command_name" \
        '.commands[$command] != null' "$release_plan" >/dev/null; then
        echo "project-release-command: undeclared Release command: $project/$command_name" >&2
        exit 64
      fi

      properties=(
        --property=UMask=0027
        --property=TimeoutStopSec=30s
      )
      for unit in $required_units; do
        properties+=(--property="Requires=$unit" --property="After=$unit")
      done
      for unit in $wanted_units; do
        properties+=(--property="Wants=$unit" --property="After=$unit")
      done
      for unit in $after_units; do
        properties+=(--property="After=$unit")
      done

      while IFS= read -r secret; do
        source="$(jq --exit-status --raw-output --arg secret "$secret" \
          '.[$secret]' "$secret_bindings")" || {
            echo "project-release-command: Secret is not bound: $secret" >&2
            exit 66
          }
        properties+=(--property="LoadCredential=$secret:$source")
      done < <(jq --exit-status --raw-output --arg command "$command_name" \
        '.commands[$command].secrets[]' "$release_plan")

      if [ "$isolation" = isolated ]; then
        properties+=(
          --property=CapabilityBoundingSet=
          --property=LockPersonality=yes
          --property=NoNewPrivileges=yes
          --property=PrivateDevices=yes
          --property=PrivateTmp=yes
          --property=ProtectClock=yes
          --property=ProtectControlGroups=yes
          --property="ProtectHome=$protect_home"
          --property=ProtectKernelLogs=yes
          --property=ProtectKernelModules=yes
          --property=ProtectKernelTunables=yes
          --property=ProtectSystem=strict
          --property="ReadWritePaths=$runtime_dir''${read_write_paths:+ $read_write_paths}"
          --property=RemoveIPC=yes
          --property="RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"
          --property=RestrictRealtime=yes
          --property=RestrictSUIDSGID=yes
          --property=SystemCallArchitectures=native
        )
      fi

      stdio=(--pipe)
      if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then
        stdio=(--pty)
      fi

      exec systemd-run \
        --quiet \
        --wait \
        --collect \
        --service-type=exec \
        "''${stdio[@]}" \
        --uid="$release_user" \
        --gid="$release_group" \
        --working-directory="$working_directory" \
        --setenv="HOME=$release_home" \
        "''${properties[@]}" \
        "$command_runner" "$command_name" "$@"
    '';
  };

  projectStatusApps = lib.filterAttrs (_: app: app.enable && app.project != null) resolvedApps;
  projectStatusCatalog = pkgs.writeText "project-release-status-apps.json" (
    builtins.toJSON (
      lib.mapAttrs (
        name: app:
        let
          release =
            (projectDescriptor.normalize {
              descriptor = app.project.descriptor;
              expectedProject = name;
            }).release;
          tokenPath =
            if app.source.giteaTokenSecretName == null then
              null
            else
              config.sops.secrets.${app.source.giteaTokenSecretName}.path;
        in
        {
          inherit (app.source)
            branch
            netrcHost
            url
            username
            ;
          inherit tokenPath;
          backend = app.backend;
          endpoint = release.action;
          stateDir = "/var/lib/app-deployments/${name}";
          serviceUnit = lib.optionalString (app.backend == "service") "app-deployment-${name}.service";
          updateUnit = "app-deployment-${name}-update.service";
        }
      ) projectStatusApps
    )
    + "\n"
  );
  projectReleaseStatusScript = pkgs.writeText "project-release-status.py" ''
    import argparse
    import base64
    import datetime
    import json
    import os
    import pathlib
    import subprocess
    import urllib.error
    import urllib.request

    CATALOG = pathlib.Path(os.environ["PROJECT_RELEASE_STATUS_CATALOG"])

    def read_text(path):
      try:
        return pathlib.Path(path).read_text(encoding="utf-8").strip() or None
      except OSError:
        return None

    def read_json(path):
      try:
        value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
      except (OSError, json.JSONDecodeError):
        return None

    def systemd_property(unit, name):
      if not unit:
        return None
      result = subprocess.run(
        ["${pkgs.systemd}/bin/systemctl", "show", unit, f"--property={name}", "--value"],
        check=False,
        capture_output=True,
        text=True,
      )
      return result.stdout.strip() or None

    def remote_revision(app):
      environment = os.environ.copy()
      token_path = app.get("tokenPath")
      if token_path:
        token = read_text(token_path)
        if not token:
          return None
        credentials = base64.b64encode(f"{app['username']}:{token}".encode()).decode()
        environment.update({
          "GIT_CONFIG_COUNT": "1",
          "GIT_CONFIG_KEY_0": "http.extraHeader",
          "GIT_CONFIG_VALUE_0": f"Authorization: Basic {credentials}",
          "GIT_TERMINAL_PROMPT": "0",
        })
      url = app["url"].removeprefix("git+")
      result = subprocess.run(
        ["${pkgs.git}/bin/git", "ls-remote", url, f"refs/heads/{app['branch']}"],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=20,
      )
      fields = result.stdout.split()
      return fields[0] if result.returncode == 0 and fields else None

    def health(runtime, plan, endpoint_name):
      endpoint = (runtime or {}).get("endpoints", {}).get(endpoint_name, {})
      origin = endpoint.get("url")
      paths = (plan or {}).get("health", {}).get("paths", [])
      checks = []
      if not origin:
        return {"ok": False, "checks": checks, "error": "Runtime Context has no HTTP URL"}
      for path in paths:
        url = origin.rstrip("/") + "/" + path.lstrip("/")
        try:
          with urllib.request.urlopen(url, timeout=5) as response:
            body = response.read(1024 * 1024)
            parsed = None
            if "json" in response.headers.get("Content-Type", ""):
              try:
                parsed = json.loads(body)
              except json.JSONDecodeError:
                pass
            checks.append({"path": path, "status": response.status, "body": parsed})
        except urllib.error.HTTPError as error:
          checks.append({"path": path, "status": error.code})
        except (OSError, TimeoutError) as error:
          checks.append({"path": path, "status": None, "error": str(error)})
      return {"ok": bool(checks) and all(check.get("status") == 200 for check in checks), "checks": checks}

    def iso_mtime(path):
      try:
        timestamp = pathlib.Path(path).stat().st_mtime
      except OSError:
        return None
      return datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).isoformat()

    def collect(name, app):
      state = pathlib.Path(app["stateDir"])
      current = read_text(state / "current-revision")
      previous = read_text(state / "previous-revision")
      pending = read_json(state / "requested-release.json")
      compatibility = read_json(state / "compatibility.json")
      runtime = read_json(state / "project-runtime.json")
      plan = read_json(state / "release-plan.json")
      remote = remote_revision(app)
      result = {
        "project": name,
        "branch": app["branch"],
        "remoteRevision": remote,
        "activeRevision": current,
        "previousRevision": previous,
        "pendingRevision": (pending or {}).get("revision"),
        "promotionPending": pending is not None,
        "upToDate": remote is not None and current == remote and pending is None,
        "compatibility": compatibility,
        "service": {
          "activeState": systemd_property(app["serviceUnit"], "ActiveState"),
          "subState": systemd_property(app["serviceUnit"], "SubState"),
          "restarts": int(systemd_property(app["serviceUnit"], "NRestarts") or 0),
        } if app["serviceUnit"] else None,
        "lastDeploymentAt": iso_mtime(state / "current-revision"),
        "lastDeploymentResult": systemd_property(app["updateUnit"], "Result"),
        "health": health(runtime, plan, app["endpoint"]),
      }
      result["ready"] = (
        result["upToDate"]
        and result["health"]["ok"]
        and (result["service"] is None or result["service"]["activeState"] == "active")
        and (compatibility is None or compatibility.get("compatible") is True)
      )
      return result

    def print_human(value):
      short = lambda revision: revision[:12] if revision else "—"
      print(f"{value['project']}: {'ready' if value['ready'] else 'attention needed'}")
      print(f"  remote {value['branch']}: {short(value['remoteRevision'])}")
      print(f"  active / previous: {short(value['activeRevision'])} / {short(value['previousRevision'])}")
      print(f"  pending promotion: {short(value['pendingRevision'])}")
      service = value.get("service")
      if service:
        print(f"  service: {service['activeState']}/{service['subState']}, {service['restarts']} restarts")
      print(f"  public health: {'passing' if value['health']['ok'] else 'failing'}")
      print(f"  last deployment: {value['lastDeploymentResult'] or '—'} at {value['lastDeploymentAt'] or '—'}")
      compatibility = value.get("compatibility")
      if compatibility and not compatibility.get("compatible", False):
        for reason in compatibility.get("reasons", []):
          print(f"  incompatible: {reason}")

    parser = argparse.ArgumentParser(prog="project-release-status")
    parser.add_argument("project")
    parser.add_argument("--json", action="store_true")
    options = parser.parse_args()
    catalog = read_json(CATALOG) or {}
    if options.project not in catalog:
      parser.error(f"unknown Project: {options.project}")
    value = collect(options.project, catalog[options.project])
    if options.json:
      print(json.dumps(value, indent=2, sort_keys=True))
    else:
      print_human(value)
    raise SystemExit(0 if value["ready"] else 1)
  '';
  projectReleaseStatus = pkgs.writeShellApplication {
    name = "project-release-status";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "project-release-status: must run as root" >&2
        exit 77
      fi
      export PROJECT_RELEASE_STATUS_CATALOG=${lib.escapeShellArg projectStatusCatalog}
      exec ${pkgs.python3}/bin/python3 ${lib.escapeShellArg projectReleaseStatusScript} "$@"
    '';
  };

  appRuntimeModules = lib.mapAttrsToList (
    name: app:
    (nixFlakeService
      (
        app
        // {
          inherit name;
          __appDeploymentsInternal = true;
        }
      )
      {
        inherit
          config
          lib
          options
          pkgs
          ;
      }
    )
  ) resolvedApps;

  appRuntimeValues =
    path: fallback: map (module: lib.attrByPath path fallback module.config) appRuntimeModules;

  appRuntimeConfig = {
    environment.systemPackages =
      lib.optional (projectCommandApps != { }) projectReleaseCommand
      ++ lib.optional (projectStatusApps != { }) projectReleaseStatus;
    users.users = lib.mkMerge (appRuntimeValues [ "users" "users" ] { });
    users.groups = lib.mkMerge (appRuntimeValues [ "users" "groups" ] { });
    systemd.tmpfiles.rules = lib.mkMerge (appRuntimeValues [ "systemd" "tmpfiles" "rules" ] [ ]);
    systemd.services = lib.mkMerge (appRuntimeValues [ "systemd" "services" ] { });
    systemd.timers = lib.mkMerge (appRuntimeValues [ "systemd" "timers" ] { });
    virtualisation.oci-containers.containers = lib.mkMerge (
      appRuntimeValues [ "virtualisation" "oci-containers" "containers" ] { }
    );
    vps.appDeployments.webhookApps = lib.mkMerge (
      appRuntimeValues [ "vps" "appDeployments" "webhookApps" ] { }
    );
    vps.services.appDeployments.metadata.health.units = lib.mkMerge (
      appRuntimeValues [ "vps" "services" "appDeployments" "metadata" "health" "units" ] [ ]
    );
    vps.services.caddy.virtualHosts = lib.mkMerge (
      appRuntimeValues [ "vps" "services" "caddy" "virtualHosts" ] { }
    );
  }
  // lib.optionalAttrs hasSops {
    sops.secrets = lib.mkMerge (appRuntimeValues [ "sops" "secrets" ] { });
  };

  webhookAppsJson = pkgs.writeText "app-deployments-webhook-apps.json" (
    builtins.toJSON cfg.webhookApps
  );

  webhookServer = pkgs.writeText "app-deployments-webhook.py" ''
    import json
    import os
    import re
    import subprocess
    import tempfile
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    APPS_FILE = os.environ["APP_DEPLOYMENTS_APPS_FILE"]
    TOKEN_FILE = os.environ["APP_DEPLOYMENTS_TOKEN_FILE"]

    with open(APPS_FILE, "r", encoding="utf-8") as handle:
      APPS = json.load(handle)

    def read_token():
      with open(TOKEN_FILE, "r", encoding="utf-8") as handle:
        return handle.read().strip()

    class Handler(BaseHTTPRequestHandler):
      server_version = "app-deployments-webhook"

      def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

      def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

      def do_GET(self):
        if self.path == "/health":
          self.send_json(200, {"ok": True, "apps": sorted(APPS.keys())})
          return
        self.send_json(404, {"error": "not found"})

      def do_POST(self):
        expected = "Bearer " + read_token()
        if self.headers.get("Authorization", "") != expected:
          self.send_json(403, {"error": "forbidden"})
          return

        match = re.fullmatch(r"/(deploy|preflight)/([^/]+)", self.path)
        if match is None:
          self.send_json(404, {"error": "not found"})
          return

        action, app_name = match.groups()
        app = APPS.get(app_name)
        if app is None:
          self.send_json(404, {"error": "unknown app", "app": app_name})
          return

        length = int(self.headers.get("Content-Length", "0") or "0")
        payload = {}
        if length:
          try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
          except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid json"})
            return

        if action == "preflight":
          descriptor = payload.get("descriptor")
          if not isinstance(descriptor, dict):
            self.send_json(400, {"error": "preflight requires a descriptor object"})
            return
          if not app["bindingPolicyFile"] or not app["compatibilityProgram"]:
            self.send_json(400, {"error": "app does not use the Project adapter"})
            return
          with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as candidate:
            json.dump(descriptor, candidate)
            candidate.flush()
            result = subprocess.run(
              [
                "${pkgs.jq}/bin/jq",
                "-n",
                "--slurpfile", "host", app["bindingPolicyFile"],
                "--slurpfile", "candidate", candidate.name,
                "-f", app["compatibilityProgram"],
              ],
              check=False,
              capture_output=True,
              text=True,
            )
          if result.returncode != 0:
            self.send_json(500, {"error": "compatibility evaluation failed"})
            return
          compatibility = json.loads(result.stdout)
          self.send_json(200 if compatibility.get("compatible") else 409, {
            "app": app_name,
            "compatibility": compatibility,
          })
          return

        revision = str(payload.get("revision", "")).strip()
        if revision:
          if not all(ch in "0123456789abcdefABCDEF" for ch in revision) or len(revision) < 7:
            self.send_json(400, {"error": "invalid revision"})
            return
        store_path = str(payload.get("storePath", "")).strip()
        if store_path and re.fullmatch(r"/nix/store/[0-9a-df-np-sv-z]{32}-[^/]+", store_path) is None:
          self.send_json(400, {"error": "invalid storePath"})
          return

        if app["deliveryMode"] == "cache":
          if not revision or not store_path:
            self.send_json(400, {"error": "cache delivery requires revision and storePath"})
            return
          release = {
            "schemaVersion": 1,
            "revision": revision,
            "storePath": store_path,
            "source": str(payload.get("source", "promotion-webhook")),
          }
          tmp_path = app["requestedReleaseFile"] + ".next"
          os.makedirs(os.path.dirname(app["requestedReleaseFile"]), exist_ok=True)
          with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(release, handle, sort_keys=True)
            handle.write("\n")
          os.replace(tmp_path, app["requestedReleaseFile"])
        elif revision:
          tmp_path = app["requestedRevisionFile"] + ".next"
          os.makedirs(os.path.dirname(app["requestedRevisionFile"]), exist_ok=True)
          with open(tmp_path, "w", encoding="utf-8") as handle:
            handle.write(revision + "\n")
          os.replace(tmp_path, app["requestedRevisionFile"])

        try:
          subprocess.run(["systemctl", "start", app["updateUnit"]], check=True)
        except subprocess.CalledProcessError as error:
          compatibility = None
          try:
            with open(app["compatibilityFile"], "r", encoding="utf-8") as handle:
              compatibility = json.load(handle)
          except (FileNotFoundError, json.JSONDecodeError):
            pass
          status = 409 if compatibility is not None and not compatibility.get("compatible", True) else 503
          self.send_json(status, {
            "accepted": False,
            "app": app_name,
            "exitCode": error.returncode,
            "compatibility": compatibility,
          })
          return

        self.send_json(202, {
          "accepted": True,
          "app": app_name,
          "revision": revision or None,
          "storePath": store_path or None,
        })

    host = os.environ.get("APP_DEPLOYMENTS_WEBHOOK_HOST", "0.0.0.0")
    port = int(os.environ["APP_DEPLOYMENTS_WEBHOOK_PORT"])
    ThreadingHTTPServer((host, port), Handler).serve_forever()
  '';
in
{
  imports = [
    ../fleet/foundation.nix
    ../ingress/caddy.nix
  ];

  options.vps.appDeployments = {
    projectPortRange = {
      from = lib.mkOption {
        type = lib.types.port;
        default = 18200;
        description = "First internal port allocated to Project-derived Release services.";
      };

      to = lib.mkOption {
        type = lib.types.port;
        default = 18999;
        description = "Last internal port allocated to Project-derived Release services.";
      };
    };

    projectAuxiliaryPortRange = {
      from = lib.mkOption {
        type = lib.types.port;
        default = 22000;
        description = "First localhost port allocated to Project Release OCI auxiliaries.";
      };

      to = lib.mkOption {
        type = lib.types.port;
        default = 22999;
        description = "Last localhost port allocated to Project Release OCI auxiliaries.";
      };
    };

    webhook = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the tailnet-only app deployment webhook.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address the deployment webhook listens on.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 18100;
        description = "Tailnet-only HTTP port for deployment webhooks.";
      };

      tokenSecretName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SOPS secret containing the bearer token accepted by the deployment webhook.";
      };
    };

    webhookApps = lib.mkOption {
      default = { };
      description = "Internal registry of app deployment webhook targets.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            bindingPolicyFile = lib.mkOption { type = lib.types.str; };
            compatibilityFile = lib.mkOption { type = lib.types.str; };
            compatibilityProgram = lib.mkOption { type = lib.types.str; };
            deliveryMode = lib.mkOption {
              type = lib.types.enum [
                "source"
                "cache"
              ];
            };
            requestedReleaseFile = lib.mkOption { type = lib.types.str; };
            updateUnit = lib.mkOption { type = lib.types.str; };
            requestedRevisionFile = lib.mkOption { type = lib.types.str; };
          };
        }
      );
    };
  };

  options.vps.services.appDeployments = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable reusable application deployment plumbing.";
    };

    metadata = serviceMetadata.mkOptions {
      displayName = "App Deployments";
      category = "Applications";
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = { };
      description = "Flake-packaged services and static sites reconciled as durable deployments.";
    };
  };

  config = lib.mkMerge (
    [
      # Application lifecycles are controlled by apps.<name>.enable. Keep them
      # independent of the shared webhook switch for compatibility with
      # lib.nixos.nixFlakeService declarations.
      appRuntimeConfig
      {
        assertions =
          lib.mapAttrsToList (name: _app: {
            assertion = builtins.match "^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$" name != null;
            message = "vps.services.appDeployments.apps.${name}: app names must contain only letters, digits, underscores, and hyphens, start with a letter or digit, and be at most 63 characters.";
          }) apps
          ++ lib.concatLists (
            lib.mapAttrsToList (name: app: [
              {
                assertion = app.backend != "service" || (app.port != null && app.executable != null);
                message = "vps.services.appDeployments.apps.${name}: service deployments require port and executable.";
              }
              {
                assertion = app.backend != "static" || (app.port == null && app.executable == null);
                message = "vps.services.appDeployments.apps.${name}: static deployments must not set port or executable.";
              }
            ]) resolvedApps
          )
          ++ lib.mapAttrsToList (name: app: {
            assertion =
              app.project == null
              ||
                (projectDescriptor.normalize {
                  descriptor = app.project.descriptor;
                  expectedProject = name;
                }).release != null;
            message = "vps.services.appDeployments.apps.${name}: Project descriptor must define the matching Release realization.";
          }) resolvedApps
          ++ lib.concatLists (
            lib.mapAttrsToList (
              name: app:
              lib.mapAttrsToList (jobName: job: {
                assertion = (job.calendar != null) != (job.interval != null);
                message = "vps.services.appDeployments.apps.${name}.project.jobs.${jobName}: set exactly one of calendar or interval.";
              }) (if app.project == null then { } else app.project.jobs)
            ) resolvedApps
          )
          ++ [
            {
              assertion = cfg.projectPortRange.from <= cfg.projectPortRange.to;
              message = "vps.appDeployments.projectPortRange.from must be <= projectPortRange.to.";
            }
            {
              assertion =
                builtins.length projectServiceNames <= cfg.projectPortRange.to - cfg.projectPortRange.from + 1;
              message = "vps.appDeployments.projectPortRange is exhausted.";
            }
            {
              assertion = lib.all (
                app:
                app.project != null
                || app.port == null
                || app.port < cfg.projectPortRange.from
                || app.port > cfg.projectPortRange.to
              ) (builtins.attrValues resolvedApps);
              message = "Legacy app deployment ports must not overlap the Project Release allocation range.";
            }
            {
              assertion = cfg.projectAuxiliaryPortRange.from <= cfg.projectAuxiliaryPortRange.to;
              message = "vps.appDeployments.projectAuxiliaryPortRange.from must be <= projectAuxiliaryPortRange.to.";
            }
            {
              assertion =
                builtins.length projectAuxiliaryPortRequests
                <= cfg.projectAuxiliaryPortRange.to - cfg.projectAuxiliaryPortRange.from + 1;
              message = "vps.appDeployments.projectAuxiliaryPortRange is exhausted.";
            }
            {
              assertion =
                cfg.projectAuxiliaryPortRange.to < cfg.projectPortRange.from
                || cfg.projectAuxiliaryPortRange.from > cfg.projectPortRange.to;
              message = "Project service and auxiliary allocation ranges must not overlap.";
            }
            {
              assertion = lib.all (
                app:
                app.project != null
                || app.port == null
                || app.port < cfg.projectAuxiliaryPortRange.from
                || app.port > cfg.projectAuxiliaryPortRange.to
              ) (builtins.attrValues resolvedApps);
              message = "Legacy app deployment ports must not overlap the Project auxiliary allocation range.";
            }
          ];
      }
      (lib.mkIf (config.vps.enable && config.vps.services.appDeployments.enable) {
        assertions = [
          {
            assertion = cfg.webhook.enable -> cfg.webhook.tokenSecretName != null;
            message = "vps.appDeployments.webhook.tokenSecretName must be set when the webhook is enabled.";
          }
        ];

        vps.services.appDeployments.metadata.health.units = lib.mkBefore (
          lib.optional cfg.webhook.enable "app-deployments-webhook.service"
        );

        networking.firewall.interfaces.tailscale0.allowedTCPPorts = lib.mkIf cfg.webhook.enable [
          cfg.webhook.port
        ];

        systemd.services.app-deployments-webhook = lib.mkIf cfg.webhook.enable {
          description = "Tailnet app deployment webhook";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            APP_DEPLOYMENTS_APPS_FILE = webhookAppsJson;
            APP_DEPLOYMENTS_TOKEN_FILE =
              if hasSops then
                config.sops.secrets.${cfg.webhook.tokenSecretName}.path
              else
                cfg.webhook.tokenSecretName;
            APP_DEPLOYMENTS_WEBHOOK_HOST = cfg.webhook.host;
            APP_DEPLOYMENTS_WEBHOOK_PORT = toString cfg.webhook.port;
          };
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${webhookServer}";
            Restart = "always";
            RestartSec = "5s";
          };
        };
      })
    ]
    ++ lib.optionals hasSops [
      (lib.mkIf (config.vps.enable && config.vps.services.appDeployments.enable && cfg.webhook.enable) {
        sops.secrets.${cfg.webhook.tokenSecretName} = {
          owner = "root";
          mode = "0400";
        };
      })
    ]
  );
}
