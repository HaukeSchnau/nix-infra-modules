# The service controller: services a repository declares at runtime through `Fleet.Service`
# (@schnau/fleet), within the grants this host's configuration gives. See
# docs/modules/services.md.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.vps.services.serviceController;
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };
  hasSops = options ? sops;
  usesDatabases = lib.any (grant: grant.databases) (lib.attrValues cfg.grants);
  postgresql = config.services.postgresql;
  postgresqlPort = toString postgresql.settings.port;

  # Every process of a service runs with these: the template unit's and the systemd-run units of
  # `prepare` and the console. The drop-in adds the stable user name, credentials and memory.
  hardening = {
    DynamicUser = true;
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RemoveIPC = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    UMask = "0077";
  };
  property =
    value:
    if lib.isBool value then
      lib.boolToString value
    else if lib.isList value then
      lib.concatStringsSep " " value
    else
      toString value;

  controllerConfig = pkgs.writeText "fleet-controller.json" (
    builtins.toJSON {
      stateDir = "/var/lib/fleet";
      runtimeDir = "/run/fleet";
      unitsDir = "/run/systemd/system";
      gcrootsDir = "/nix/var/nix/gcroots/fleet";
      inherit (cfg)
        routesFile
        listen
        portRange
        addresses
        tokenFile
        grantKeyFile
        sopsFile
        ageKeyFile
        prepareTimeoutSec
        grants
        ;
      sitesDir = cfg.sitesDirectory;
      backupDir = cfg.backup.directory;
      postgresql =
        if usesDatabases then
          {
            socket = "/run/postgresql";
            port = postgresql.settings.port;
            major = lib.toInt (lib.versions.major cfg.postgresql.package.version);
          }
        else
          null;
      properties = lib.mapAttrsToList (name: value: "${name}=${property value}") hardening;
      bin = {
        nixStore = "${config.nix.package}/bin/nix-store";
        systemctl = "${config.systemd.package}/bin/systemctl";
        systemdRun = "${config.systemd.package}/bin/systemd-run";
        journalctl = "${config.systemd.package}/bin/journalctl";
        sops = lib.getExe pkgs.sops;
        age = lib.getExe pkgs.age;
        ageKeygen = "${pkgs.age}/bin/age-keygen";
        psql = if usesDatabases then "${cfg.postgresql.package}/bin/psql" else null;
      };
    }
  );
  source = pkgs.runCommand "fleet-controller" { } ''
    mkdir -p $out
    cp ${./controller.py} $out/controller.py
    cp ${./fleet.py} $out/fleet.py
  '';
  fleetCli = pkgs.writeShellScriptBin "fleet" ''
    export FLEET_CONFIG=${controllerConfig}
    exec ${pkgs.python3}/bin/python3 ${source}/fleet.py "$@"
  '';

  grantNames = lib.attrNames cfg.grants;
  grantType = lib.types.submodule {
    options = {
      hostNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "*.shop.example.net" ];
        description = "Hostnames the grant's services may claim; `*.example.org` allows every name below example.org.";
      };
      public = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the grant's services may be reachable from the internet, not only the tailnet.";
      };
      services = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "How many services the grant may run on this host.";
      };
      memoryMax = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[0-9]+[KMGT]");
        default = null;
        example = "4G";
        description = "Memory the grant's services share. Each service then sets memory.max, and their sum stays within this.";
      };
      secretPrefixes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "projects/shop/" ];
        description = "SOPS key prefixes the grant's services may read. Sealed values need no prefix.";
      };
      databases = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the grant's services may have a PostgreSQL database each.";
      };
    };
  };
in
{
  imports = [ ../fleet/foundation.nix ];

  options.vps.services.serviceController = {
    enable = lib.mkEnableOption "the service controller, which runs services repositories declare within their grants";

    metadata = serviceMetadata.mkOptions {
      displayName = "Service controller";
      category = "Applications";
      healthUnits = [ "fleet-controller.service" ];
    };

    grants = lib.mkOption {
      type = lib.types.attrsOf grantType;
      default = { };
      description = ''
        What each grant's services may do on this host. A service belongs to the grant it is named
        after: `shop` holds `shop` and `shop-<anything>`.
      '';
    };

    listen = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address the controller's API listens on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 18110;
        description = "Port of the controller's API.";
      };
    };

    firewallInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "tailscale0" ];
      description = "Interfaces the API's port opens on.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File with a token that may change every service.";
    };

    grantKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File with the key of grant tokens: a grant's token is HMAC-SHA256(key, grant), so whoever
        holds it can change that grant's services only. Placements derive project tokens the same
        way, so one key serves both.
      '';
    };

    addresses = {
      ipv4 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The host's public IPv4 address, which `Fleet.Service` returns for DNS records.";
      };
      ipv6 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The host's public IPv6 address.";
      };
    };

    portRange = {
      from = lib.mkOption {
        type = lib.types.port;
        default = 18300;
        description = "First loopback port a service may get.";
      };
      to = lib.mkOption {
        type = lib.types.port;
        default = 18499;
        description = "Last loopback port a service may get.";
      };
    };

    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if hasSops then toString config.sops.defaultSopsFile else null;
      defaultText = lib.literalExpression "config.sops.defaultSopsFile, with sops-nix";
      description = "The SOPS file secrets name keys in.";
    };

    ageKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if hasSops then config.sops.age.keyFile else null;
      defaultText = lib.literalExpression "config.sops.age.keyFile, with sops-nix";
      description = "The host's age key, which decrypts the SOPS file and seals secret values at rest.";
    };

    postgresql.package = lib.mkOption {
      type = lib.types.package;
      example = lib.literalExpression "pkgs.postgresql_18";
      description = ''
        The PostgreSQL the services' databases run on, required once a grant allows databases. It
        is set here so that the major version never follows `system.stateVersion` unnoticed.
      '';
    };

    prepareTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "How long a service's `prepare` may run before its deploy fails.";
    };

    backup = {
      directory = lib.mkOption {
        type = lib.types.str;
        default = "/var/backup/fleet";
        description = "Where the nightly dumps of the services' databases go, one file per database.";
      };
      startAt = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 23:45:00";
        description = "When the dumps run, as a systemd calendar.";
      };
    };

    routesFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/fleet/routes.json";
      description = ''
        Routes of the active services, `{name, hostName, visibility, upstreamPort, site}`, for the
        host's runtime ingress to serve. Each `site` is a Caddy snippet in `sitesDirectory`.
      '';
    };

    sitesDirectory = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/fleet/sites";
      description = "Caddy snippets the routes import, one per service.";
    };
  };

  config = lib.mkIf (config.vps.enable && cfg.enable) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.tokenFile != null || cfg.grantKeyFile != null;
            message = "vps.services.serviceController needs tokenFile or grantKeyFile, or nobody can call it.";
          }
          {
            assertion = cfg.ageKeyFile != null;
            message = "vps.services.serviceController.ageKeyFile must be set; it seals secret values.";
          }
          {
            assertion = cfg.portRange.from <= cfg.portRange.to;
            message = "vps.services.serviceController.portRange.from must be <= to.";
          }
        ]
        ++ map (name: {
          assertion = builtins.match "[a-z]([a-z0-9-]{0,23}[a-z0-9])?" name != null;
          message = "vps.services.serviceController.grants.${name}: a grant is named like a service: lowercase letters, digits and hyphens, at most 25.";
        }) grantNames
        ++ lib.concatMap (
          name:
          map (other: {
            assertion = !(lib.hasPrefix "${name}-" other);
            message = "vps.services.serviceController.grants: ${other} starts with ${name}-, so their services' names would overlap.";
          }) grantNames
        ) grantNames;

        environment.systemPackages = [ fleetCli ];

        networking.firewall.interfaces = lib.genAttrs cfg.firewallInterfaces (_: {
          allowedTCPPorts = [ cfg.listen.port ];
        });

        systemd.services."fleet-service@" = {
          description = "Fleet service %i";
          after = [ "network.target" ] ++ lib.optional usesDatabases "postgresql.service";
          # The controller's drop-in in /run/systemd/system replaces ExecStart.
          serviceConfig = hardening // {
            ExecStart = "${pkgs.coreutils}/bin/false";
            Restart = "on-failure";
            RestartSec = "2s";
            TimeoutStopSec = "30s";
          };
        };

        systemd.services.fleet-controller = {
          description = "Fleet service controller";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ] ++ lib.optional usesDatabases "postgresql.service";
          after = [ "network-online.target" ] ++ lib.optional usesDatabases "postgresql.service";
          environment.FLEET_CONFIG = controllerConfig;
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${source}/controller.py serve";
            Restart = "always";
            RestartSec = "5s";
          };
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/fleet 0700 root root -"
          "d ${cfg.sitesDirectory} 0755 root root -"
        ];
      }

      (lib.mkIf usesDatabases {
        services.postgresql = {
          enable = true;
          package = cfg.postgresql.package;
        };

        systemd.services.fleet-dump = {
          description = "Dump the fleet services' databases";
          after = [ "postgresql.service" ];
          requires = [ "postgresql.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "postgres";
            Nice = 10;
            IOSchedulingClass = "idle";
          };
          script = ''
            failed=0
            databases="$(${cfg.postgresql.package}/bin/psql -X -At -h /run/postgresql -p ${postgresqlPort} -d postgres \
              -c "SELECT datname FROM pg_database WHERE datname LIKE 'fleet-%'")"
            for database in $databases; do
              target=${lib.escapeShellArg cfg.backup.directory}/"$database.dump"
              if ${cfg.postgresql.package}/bin/pg_dump -Fc -h /run/postgresql -p ${postgresqlPort} -f "$target.next" "$database"; then
                mv "$target.next" "$target"
              else
                echo "fleet-dump: $database failed" >&2
                failed=1
              fi
            done
            exit "$failed"
          '';
        };
        systemd.timers.fleet-dump = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.backup.startAt;
            Persistent = true;
          };
        };
        systemd.tmpfiles.rules = [ "d ${cfg.backup.directory} 0700 postgres postgres -" ];
      })

      (lib.optionalAttrs (options ? server.backup) {
        server.backup.paths = lib.mkIf usesDatabases (lib.mkAfter [ cfg.backup.directory ]);
      })
    ]
  );
}
