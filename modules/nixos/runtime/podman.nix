{
  config,
  lib,
  pkgs,
  ...
}:
let
  vps = config.vps;
  cfg = vps.services.podman;
  hostCapabilities = vps.hostCapabilities;
  pruneUnitName = "${config.networking.hostName}-podman-prune";
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };
in
{
  imports = [ ../fleet/foundation.nix ];

  options.vps = {
    services.podman = {
      enable = lib.mkEnableOption "Podman runtime for VPS services";

      metadata = serviceMetadata.mkOptions {
        displayName = "Podman";
        category = "Infrastructure";
        healthUnits = [
          "podman.socket"
          "podman-network-proxy.service"
        ];
      };

      networkName = lib.mkOption {
        type = lib.types.str;
        default = "proxy";
        description = "Shared Podman network used by VPS containers.";
      };
    };

    hostCapabilities = {
      networkedNixBuilds.enable = lib.mkEnableOption ''
        remote Nix builds that need network access during fixed-output-adjacent dependency work
      '';

      containerNetworking.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable kernel modules and forwarding sysctls required by container networking.";
      };
    };
  };

  config = lib.mkIf vps.enable (
    lib.mkMerge [
      {
        vps.hostCapabilities.containerNetworking.enable = lib.mkDefault cfg.enable;

        nix.settings = lib.mkIf hostCapabilities.networkedNixBuilds.enable {
          sandbox = lib.mkForce false;
        };

        boot.kernelModules = lib.mkIf hostCapabilities.containerNetworking.enable [
          "br_netfilter"
          "overlay"
          "nf_conntrack"
        ];

        boot.kernel.sysctl = lib.mkIf hostCapabilities.containerNetworking.enable {
          "net.bridge.bridge-nf-call-iptables" = 1;
          "net.ipv4.ip_forward" = 1;
        };
      }

      (lib.mkIf cfg.enable {
        virtualisation.containers.enable = true;
        virtualisation.podman = {
          enable = true;
          dockerCompat = true;
          dockerSocket.enable = true;
          defaultNetwork.settings.dns_enabled = true;
        };
        virtualisation.oci-containers.backend = "podman";

        systemd.services = {
          podman-network-proxy = {
            description = "Create Podman network '${cfg.networkName}' for VPS containers";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "podman.socket"
            ];
            wants = [
              "network-online.target"
              "podman.socket"
            ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };

            script = ''
              ${pkgs.podman}/bin/podman network inspect ${cfg.networkName} >/dev/null 2>&1 || \
                ${pkgs.podman}/bin/podman network create ${cfg.networkName}
            '';
          };

          "${pruneUnitName}" = {
            description = "Prune stale Podman CI artifacts";
            serviceConfig = {
              Type = "oneshot";
            };
            script = ''
              set -eu

              install -d -m 0755 /run/lock
              lock_file="/run/lock/${pruneUnitName}.lock"
              exec 9>"$lock_file"
              if ! ${pkgs.util-linux}/bin/flock -n 9; then
                exit 0
              fi

              ${pkgs.podman}/bin/podman container prune --force --filter "until=168h"
              ${pkgs.podman}/bin/podman image prune --all --force --filter "until=168h"
            '';
          };
        };

        systemd.timers.${pruneUnitName} = {
          description = "Schedule stale Podman CI artifact pruning";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "45m";
          };
        };
      })
    ]
  );
}
