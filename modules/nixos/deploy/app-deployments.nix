{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.vps.appDeployments;
  hasSops = options ? sops;

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

  options.vps.services.appDeployments.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable reusable application deployment plumbing.";
  };

  config = lib.mkMerge (
    [
      (lib.mkIf (config.vps.enable && config.vps.services.appDeployments.enable) {
        assertions = [
          {
            assertion = cfg.webhook.enable -> cfg.webhook.tokenSecretName != null;
            message = "vps.appDeployments.webhook.tokenSecretName must be set when the webhook is enabled.";
          }
        ];

        vps.services.appDeployments.metadata.health.units =
          lib.optional cfg.webhook.enable "app-deployments-webhook.service";

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
