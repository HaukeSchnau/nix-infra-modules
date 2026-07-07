# Podman Runtime

`nixosModules.podmanRuntime` provides the shared root Podman runtime used by
fleet services.

## Public Owns

- `vps.services.podman.enable`
- the shared Podman network name, defaulting to `proxy`
- root Podman, Docker compatibility, and OCI container backend wiring
- kernel modules and sysctls required by container networking
- a host-scoped prune timer for stale CI artifacts

## Private Owns

- which hosts enable the runtime
- service containers and their environment
- any host-specific network policy or capacity limits

## Example

```nix
{
  vps.enable = true;
  vps.services.podman.enable = true;
}
```

Enabling Podman also enables the `containerNetworking` host capability by
default. Private repos can opt into `networkedNixBuilds` separately when a host
needs unsandboxed fixed-output-adjacent builds.
