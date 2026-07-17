{
  lib,
  pkgs,
  self,
  system,
  ...
}:
let
  mkFleetSystem = import ../../../checks/mk-fleet-system.nix {
    inherit lib self system;
  };
  podmanSystem = mkFleetSystem "runtime-01" [
    { vps.services.podman.enable = true; }
  ];
  runtime = podmanSystem.config;
  pruneScript = runtime.systemd.services."runtime-01-podman-prune".script;
in
{
  podman-runtime-example = pkgs.runCommand "podman-runtime-example" { } ''
    test '${if runtime.virtualisation.podman.enable then "yes" else "no"}' = 'yes'
    test '${if runtime.virtualisation.podman.dockerCompat then "yes" else "no"}' = 'yes'
    test '${runtime.virtualisation.oci-containers.backend}' = 'podman'
    test '${if runtime.vps.hostCapabilities.containerNetworking.enable then "yes" else "no"}' = 'yes'
    test ${lib.escapeShellArg runtime.systemd.services.podman-network-proxy.description} = ${lib.escapeShellArg "Create Podman network 'proxy' for VPS containers"}
    test '${runtime.systemd.timers."runtime-01-podman-prune".timerConfig.OnCalendar}' = 'daily'
    test '${if lib.hasInfix "podman ps --all --external" pruneScript then "yes" else "no"}' = 'yes'
    test '${if lib.hasInfix "podman volume prune --force" pruneScript then "yes" else "no"}' = 'yes'
    test '${if lib.hasInfix ''--filter "until=168h"'' pruneScript then "yes" else "no"}' = 'yes'
    test '${if lib.hasInfix "podman system prune --build" pruneScript then "yes" else "no"}' = 'no'
    test '${if lib.hasInfix "podman volume prune --all" pruneScript then "yes" else "no"}' = 'no'
    touch $out
  '';
}
