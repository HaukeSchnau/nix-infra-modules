# NixOS Modules

`fleet` is the complete NixOS interface for a small self-hosted VPS fleet.

The other exports are leaf modules grouped by responsibility:

- `backup/`: restic backup policy
- `ci/`: GitHub and Gitea runner leaves
- `deploy/`: app deployment and flake-service helpers
- `fleet/`: shared metadata, generated contracts, and tooling
- `ingress/`: Caddy app ingress and edge ingress
- `runtime/`: Podman runtime and host capabilities

Leaf modules can be imported directly when a private repo wants a smaller
surface, but the full `nixosModules.fleet` export is the normal starting point.
