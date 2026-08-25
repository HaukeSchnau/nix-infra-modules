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

        prefix = "/deploy/"
        if not self.path.startswith(prefix):
          self.send_json(404, {"error": "not found"})
          return

        app_name = self.path[len(prefix):].strip("/")
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
            compatibilityFile = lib.mkOption { type = lib.types.str; };
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
