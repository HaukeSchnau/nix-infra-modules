# Fleet Modules

The fleet modules provide the shared option namespace used by the NixOS VPS
leaves.

`nixosModules.fleet` imports the complete NixOS interface. Individual exports
such as `nixosModules.caddyIngress` and `nixosModules.podmanRuntime` are leaf
modules; they are useful when a private repo wants a smaller import surface but
each imports its actual foundation and service dependencies, so it evaluates as
a truthful standalone leaf.

## Public Owns

- `vps.enable`, `vps.baseDomain`, and `vps.caddy.acmeEmail`
- service-local metadata for inventory rows and health units
- generated service inventory and edge-ingress contracts
- `vps-services` and `vps-health-check`

## Private Owns

- real host inventory and deploy metadata
- real domains and ACME account policy
- which services run on which host
- host-specific health probes beyond generated systemd checks

## Generated Contract

Application hosts publish:

```nix
config.vps.generated.edgeIngress
```

Edge hosts consume that value:

```nix
{
  vps.services.edgeIngress = {
    enable = true;
    upstream = core.config.vps.generated.edgeIngress;
  };
}
```

This keeps the public edge config derived from the app host contract instead of
copying route lists by hand.
