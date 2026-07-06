{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.wireguardProfiles;

  fullConfigType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        secretKey = lib.mkOption {
          type = lib.types.str;
          description = "Key in the configured SOPS file containing a complete wg-quick config.";
        };

        autostart = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether launchd should bring this profile up automatically.";
        };

        description = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Human-readable profile description shown by wg-profile.";
        };
      };
    }
  );

  fullConfigPath = name: "/run/secrets/wireguard/${name}.conf";
  declarativeConfigPath = name: "/etc/wireguard/${name}.conf";

  profileLines =
    (lib.mapAttrsToList (
      name: profile:
      "full\t${name}\t${fullConfigPath name}\t${
        if profile.autostart then "yes" else "no"
      }\t${profile.description}"
    ) cfg.fullConfigs)
    ++ (map (
      name: "declarative\t${name}\t${declarativeConfigPath name}\tnative\tDeclarative WireGuard interface"
    ) cfg.declarativeNames);

  profilesFile = pkgs.writeText "wg-profile-list" (lib.concatStringsSep "\n" profileLines + "\n");

  wgProfile = pkgs.writeShellScriptBin "wg-profile" ''
    set -euo pipefail

    profiles_file=${lib.escapeShellArg profilesFile}
    wg_quick=${lib.getExe' pkgs.wireguard-tools "wg-quick"}
    wg=${lib.getExe' pkgs.wireguard-tools "wg"}

    usage() {
      cat <<'USAGE'
    Usage:
      wg-profile list
      wg-profile up <name>
      wg-profile down <name>
      wg-profile restart <name>
      wg-profile status [name]
    USAGE
    }

    find_profile() {
      local wanted="$1"
      ${lib.getExe pkgs.gawk} -F '\t' -v wanted="$wanted" '$2 == wanted { print; found = 1 } END { exit found ? 0 : 1 }' "$profiles_file"
    }

    require_profile() {
      local name="$1"
      if ! find_profile "$name"; then
        echo "wg-profile: unknown profile: $name" >&2
        echo "Available profiles:" >&2
        list_profiles >&2
        exit 1
      fi
    }

    run_wg_quick() {
      local action="$1"
      local config_path="$2"

      if [ "$(${lib.getExe' pkgs.coreutils "id"} -u)" -eq 0 ]; then
        exec "$wg_quick" "$action" "$config_path"
      fi

      exec /usr/bin/sudo "$wg_quick" "$action" "$config_path"
    }

    runtime_interface() {
      local name="$1"
      local runtime_name="/var/run/wireguard/$name.name"

      if [ -r "$runtime_name" ]; then
        ${lib.getExe' pkgs.coreutils "cat"} "$runtime_name"
        return
      fi

      if [ -e "$runtime_name" ]; then
        /usr/bin/sudo ${lib.getExe' pkgs.coreutils "cat"} "$runtime_name"
        return
      fi

      echo "$name"
    }

    run_wg_show() {
      if [ "$(${lib.getExe' pkgs.coreutils "id"} -u)" -eq 0 ]; then
        exec "$wg" show "$@"
      fi

      exec /usr/bin/sudo "$wg" show "$@"
    }

    list_profiles() {
      ${lib.getExe pkgs.gawk} -F '\t' '
        BEGIN {
          printf "%-14s %-12s %-10s %s\n", "NAME", "TYPE", "AUTOSTART", "DESCRIPTION"
        }
        {
          printf "%-14s %-12s %-10s %s\n", $2, $1, $4, $5
        }
      ' "$profiles_file"
    }

    command="''${1:-}"
    case "$command" in
      list)
        [ "$#" -eq 1 ] || { usage >&2; exit 64; }
        list_profiles
        ;;
      up|down)
        [ "$#" -eq 2 ] || { usage >&2; exit 64; }
        profile="$(require_profile "$2")"
        config_path="$(${lib.getExe' pkgs.coreutils "printf"} '%s' "$profile" | ${lib.getExe' pkgs.coreutils "cut"} -f3)"
        run_wg_quick "$command" "$config_path"
        ;;
      restart)
        [ "$#" -eq 2 ] || { usage >&2; exit 64; }
        profile="$(require_profile "$2")"
        config_path="$(${lib.getExe' pkgs.coreutils "printf"} '%s' "$profile" | ${lib.getExe' pkgs.coreutils "cut"} -f3)"
        if [ "$(${lib.getExe' pkgs.coreutils "id"} -u)" -eq 0 ]; then
          "$wg_quick" down "$config_path" || true
          exec "$wg_quick" up "$config_path"
        fi
        /usr/bin/sudo "$wg_quick" down "$config_path" || true
        exec /usr/bin/sudo "$wg_quick" up "$config_path"
        ;;
      status)
        if [ "$#" -eq 1 ]; then
          run_wg_show
        elif [ "$#" -eq 2 ]; then
          require_profile "$2" >/dev/null
          run_wg_show "$(runtime_interface "$2")"
        else
          usage >&2
          exit 64
        fi
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        usage >&2
        exit 64
        ;;
    esac
  '';

  mkSecret = name: profile: {
    name = "wireguard/${name}.conf";
    value = {
      key = profile.secretKey;
      path = fullConfigPath name;
      owner = "root";
      group = "wheel";
      mode = "0400";
    };
  };

  mkAutostartDaemon =
    name: profile:
    lib.nameValuePair "wg-quick-${name}" {
      serviceConfig = {
        EnvironmentVariables.PATH = "${pkgs.wireguard-tools}/bin:${pkgs.wireguard-go}/bin:${config.environment.systemPath}";
        KeepAlive = {
          NetworkState = true;
          SuccessfulExit = true;
        };
        ProgramArguments = [
          (lib.getExe' pkgs.wireguard-tools "wg-quick")
          "up"
          (fullConfigPath name)
        ];
        RunAtLoad = true;
        StandardErrorPath = "${cfg.logDir}/wg-quick-${name}.log";
        StandardOutPath = "${cfg.logDir}/wg-quick-${name}.log";
      };
    };
in
{
  options.wireguardProfiles = {
    enable = lib.mkEnableOption "manual WireGuard profile management for nix-darwin";

    logDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/wireguard";
      description = "Directory to save WireGuard profile launchd logs.";
    };

    fullConfigs = lib.mkOption {
      type = lib.types.attrsOf fullConfigType;
      default = { };
      description = "Complete SOPS-backed wg-quick config profiles.";
    };

    declarativeNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Native networking.wg-quick interface names to expose through wg-profile.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.fullConfigs != { } || cfg.declarativeNames != [ ];
        message = "wireguardProfiles.enable requires at least one full config or declarative interface.";
      }
    ];

    sops.secrets = builtins.listToAttrs (lib.mapAttrsToList mkSecret cfg.fullConfigs);

    launchd.daemons = lib.mapAttrs' mkAutostartDaemon (
      lib.filterAttrs (_: profile: profile.autostart) cfg.fullConfigs
    );

    system.activationScripts.postActivation.text = lib.mkAfter ''
      mkdir -p ${lib.escapeShellArg cfg.logDir}
    '';

    environment.systemPackages = [
      pkgs.wireguard-go
      pkgs.wireguard-tools
      wgProfile
    ];
  };
}
