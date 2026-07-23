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
  ) apps;

  appRuntimeValues =
    path: fallback: map (module: lib.attrByPath path fallback module.config) appRuntimeModules;

  appRuntimeConfig = {
    users.users = lib.mkMerge (appRuntimeValues [ "users" "users" ] { });
    users.groups = lib.mkMerge (appRuntimeValues [ "users" "groups" ] { });
    systemd.tmpfiles.rules = lib.mkMerge (appRuntimeValues [ "systemd" "tmpfiles" "rules" ] [ ]);
    systemd.services = lib.mkMerge (appRuntimeValues [ "systemd" "services" ] { });
    systemd.timers = lib.mkMerge (appRuntimeValues [ "systemd" "timers" ] { });
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
          tmp_path = app["requestedRevisionFile"] + ".next"
          os.makedirs(os.path.dirname(app["requestedRevisionFile"]), exist_ok=True)
          with open(tmp_path, "w", encoding="utf-8") as handle:
            handle.write(revision + "\n")
          os.replace(tmp_path, app["requestedRevisionFile"])

        try:
          subprocess.run(["systemctl", "start", app["updateUnit"]], check=True)
        except subprocess.CalledProcessError as error:
          self.send_json(500, {"accepted": False, "app": app_name, "exitCode": error.returncode})
          return

        self.send_json(202, {"accepted": True, "app": app_name, "revision": revision or None})

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
            ]) apps
          );
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
