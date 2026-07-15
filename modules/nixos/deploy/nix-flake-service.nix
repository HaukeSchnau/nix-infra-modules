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
  cfg = lib.recursiveUpdate {
    enable = true;
    public = false;
    host = "127.0.0.1";
    package = "default";
    environment = { };
    environmentFiles = [ ];
    path = [ ];
    stateDirs = [ ];
    preStart = "";
    serviceConfig = { };
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
  unitName = "app-deployment-${name}";
  updateUnitName = "${unitName}-update";
  userName = "app-${name}";
  stateDir = "/var/lib/app-deployments/${name}";
  runtimeDir = "${stateDir}/runtime";

  shellPath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.findutils
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.nix
    pkgs.systemd
    pkgs.util-linux
  ];

  mkFlakeRef =
    revision:
    if revision == "" then
      "${cfg.source.url}?ref=${cfg.source.branch}"
    else
      "${cfg.source.url}?rev=${revision}";

  healthCurlArgs =
    lib.optionals (cfg.health.hostHeader != null) [
      "-H"
      "Host: ${cfg.health.hostHeader}"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (header: value: [
        "-H"
        "${header}: ${value}"
      ]) cfg.health.headers
    );

  healthScript = ''
    check_health() {
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
    git_config_file=""

    cleanup() {
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

    ${healthScript}

    if [ -n "$resolved_revision" ] \
      && [ -f "$current_revision_file" ] \
      && [ "$(cat "$current_revision_file")" = "$resolved_revision" ] \
      && systemctl is-active --quiet ${lib.escapeShellArg "${unitName}.service"}; then
      sync_gcroots
      if [ -x "$current_link/bin/${cfg.executable}" ] && check_health; then
        echo "app-deployment/${name}: already running $resolved_revision"
        exit 0
      fi

      echo "app-deployment/${name}: $resolved_revision is active but failed store or health checks; redeploying"
    fi

    echo "app-deployment/${name}: building $build_flake_ref#${cfg.package}"
    new_store_path="$(nix build --no-link --print-out-paths "$build_flake_ref#${cfg.package}")"
    if [ ! -x "$new_store_path/bin/${cfg.executable}" ]; then
      echo "app-deployment/${name}: missing executable $new_store_path/bin/${cfg.executable}" >&2
      exit 1
    fi

    old_store_path=""
    if [ -L "$current_link" ]; then
      old_store_path="$(readlink "$current_link")"
      ln -sfn "$old_store_path" "$previous_link.next"
      mv -Tf "$previous_link.next" "$previous_link"
      if [ -f "$current_revision_file" ]; then
        cp "$current_revision_file" "$previous_revision_file"
      fi
    fi

    ln -sfn "$new_store_path" "$current_link.next"
    mv -Tf "$current_link.next" "$current_link"
    printf '%s\n' "$resolved_revision" > "$current_revision_file"
    sync_gcroots

    systemctl restart ${lib.escapeShellArg "${unitName}.service"}

    if check_health; then
      echo "app-deployment/${name}: deployed $resolved_revision"
      exit 0
    fi

    if [ -n "$old_store_path" ]; then
      echo "app-deployment/${name}: health failed, rolling back to $old_store_path" >&2
      ln -sfn "$old_store_path" "$current_link.next"
      mv -Tf "$current_link.next" "$current_link"
      if [ -f "$previous_revision_file" ]; then
        cp "$previous_revision_file" "$current_revision_file"
      fi
      sync_gcroots
      systemctl restart ${lib.escapeShellArg "${unitName}.service"}
      check_health
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

    exec "$executable"
  '';
  runtimeConfig =
    if cfg.enable then
      {
        users.users.${userName} = {
          isSystemUser = true;
          group = userName;
          home = stateDir;
        };
        users.groups.${userName} = { };

        systemd.tmpfiles.rules = [
          "d /var/lib/app-deployments 0755 root root -"
          "d ${stateDir} 0755 root root -"
          "d ${runtimeDir} 0750 ${userName} ${userName} -"
        ]
        ++ (map (dir: "d ${dir} 0750 ${userName} ${userName} -") cfg.stateDirs);

        systemd.services.${unitName} = {
          description = "App deployment '${name}'";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          environment = {
            HOST = cfg.host;
            PORT = toString cfg.port;
            HOME = stateDir;
          }
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
          // lib.optionalAttrs (cfg.environmentFiles != [ ]) {
            EnvironmentFile = cfg.environmentFiles;
          }
          // cfg.serviceConfig;
          preStart = cfg.preStart;
        };

        systemd.services.${updateUnitName} = {
          description = "Update app deployment '${name}'";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = updateScript;
          };
        };

        systemd.timers = lib.optionalAttrs cfg.autoUpdate.enable {
          ${updateUnitName} = {
            description = "Reconcile app deployment '${name}'";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnActiveSec = cfg.autoUpdate.onBootSec;
              OnBootSec = cfg.autoUpdate.onBootSec;
              OnUnitActiveSec = cfg.autoUpdate.interval;
              Persistent = true;
              Unit = "${updateUnitName}.service";
            };
          };
        };

        vps.appDeployments.webhookApps.${name} = {
          updateUnit = "${updateUnitName}.service";
          requestedRevisionFile = "${stateDir}/requested-revision";
        };

        vps.services.appDeployments.metadata.health.units = [ "${unitName}.service" ];

        vps.services.caddy.virtualHosts = lib.optionalAttrs (cfg.domain != null) {
          ${cfg.domain} = {
            upstream = "${cfg.host}:${toString cfg.port}";
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
