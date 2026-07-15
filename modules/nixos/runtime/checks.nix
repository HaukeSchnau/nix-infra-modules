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
in
{
  podman-runtime-example = pkgs.runCommand "podman-runtime-example" { } ''
    test '${if runtime.virtualisation.podman.enable then "yes" else "no"}' = 'yes'
    test '${if runtime.virtualisation.podman.dockerCompat then "yes" else "no"}' = 'yes'
    test '${runtime.virtualisation.oci-containers.backend}' = 'podman'
    test '${if runtime.vps.hostCapabilities.containerNetworking.enable then "yes" else "no"}' = 'yes'
    test ${lib.escapeShellArg runtime.systemd.services.podman-network-proxy.description} = ${lib.escapeShellArg "Create Podman network 'proxy' for VPS containers"}
    test '${runtime.systemd.timers."runtime-01-podman-prune".timerConfig.OnCalendar}' = 'daily'
    touch $out
  '';
}
