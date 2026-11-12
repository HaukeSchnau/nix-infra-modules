# Projects host module

`nixosModules.projects` runs [Project repositories](./project-definition.md)
on a host: development instances of live checkouts, and releases through
[app deployments](./app-deployments.md). It needs the fleet, appDeployments
and caddyIngress modules. With sops-nix, secret bindings may name SOPS keys;
with Home Manager and `homeManagerModules.workspaceRepos`, canonical checkouts
are cloned and kept up to date.

```nix
{
  imports = [ inputs.nix-infra-modules.nixosModules.projects ];

  fleet.services.projects = {
    defaultOwner = "alice";
    devenv = inputs.devenv; # cachix/devenv at 2.3.1
    releaseCacheStore = "https://cache.example.net";
    repositoryRemotes.forge = {
      checkoutUrlPrefix = "git@forge.example.net:";
      releaseUrlPrefix = "git+https://forge.example.net/";
    };
  };

  projects.shop = {
    source = inputs.shop;
    repository = { remote = "forge"; path = "team/shop.git"; };
    development.secrets.apiKey.sopsKey = "shop/api-key";
    release = {
      delivery.mode = "cache";
      grant = {
        hostNames = [ "shop.example.net" ];
        public = true;
        secretPrefix = "shop/";
        default = {
          endpoint = { hostName = "shop.example.net"; visibility = "public"; };
          secrets.apiKey = "shop/api-key";
        };
      };
      providers.database = "host-postgresql";
    };
  };
}
```

`source` is the pinned repository. A repository with `devenv.nix` gets a
prepared development bundle built from it; otherwise the host reads the
flake's `lib.project`. `development = null` places a release only;
`release = null` places development only.

## Development

The host writes `/etc/projects/catalog-<owner>.json` with each Project's
pinned bundle and policy, and installs the `project` command. The controller
(`controller/project_controller`, run as the owner) binds a bundle's contract
to policy, allocates ports, directories, generated credentials and native
PostgreSQL, writes a runtime manifest per instance and installs user units:
one devenv manager and a socket-activated proxy per endpoint. Endpoints wake
on the first request and sleep after `development.idleTimeoutSec`. Waking
never evaluates Nix; `project dev bundle refresh` builds a bundle from a
checkout's tracked files.

Development hostnames are `<project>[-<endpoint>].<developmentLabel>.<baseDomain>`
for canonical instances and `<instance>[-<endpoint>].…` for ad-hoc ones. The
module does not publish them itself: `fleet.services.projects.routeSources`
lists, per owner, the route file the controller maintains, for an ingress to
serve.

`workspaces.launcher` names a workspace runtime that isolates ad-hoc checkouts
in their own namespaces. It is called as `LAUNCHER environment --cwd DIR`
(JSON describing the workspace), `bind-project`, `unbind-project` and
`project-run`. `workspaces.hostGateway` is the address at which a workspace
reaches the host's loopback; loopback URLs in parameters are rewritten to it.
Unenrolled repositories under `~/Code` and workspaces run with generated
resources only.

## Release

Each placed release becomes an app deployment with the repository's topology
and this host's bindings. Directory requirements live under
`/var/lib/app-deployments/<project>/runtime`, `host-postgresql` creates a
database owned by the release user with nightly logical backups, and bound
secret requirements use the credential of the same name.

A release's hostname and secrets come only from a placement. `release.grant` sets the
limits a placement must stay within: hostnames, public or not, a SOPS key prefix
(`projects/<project>/` by default) and a memory ceiling. See
[Placements](./app-deployments.md#placements). The repository places the release through
its stack, or the host places it itself with `grant.default`, the placement that applies
while the repository has placed none:

```nix
projects.t3code.release.grant = {
  hostNames = [ "t3.example.net" ];
  secretPrefix = "t3code/";
  default = {
    endpoint.hostName = "t3.example.net";
    secrets.apnsPrivateKey = "t3code/apns-private-key";
    parameters.apnsTeamId = "TEAM";
  };
};
```

A release without a grant has no hostname and no secrets.

`fleet.services.projects.resolvedReleases` and `resolvedDevelopments` summarize
the placements for other modules.

## nix-darwin

`darwinModules.projects` makes a Mac a release host. CI promotes releases to it through the same
webhook and the same update pipeline as on NixOS
([Release hosts](./app-deployments.md#release-hosts)), so a release behaves the same there:
the candidate is bound against host policy, pre-deploy tasks run in order with their timeout and
failure mode, `current` and `previous` switch with GC roots, and a failed health check rolls
back. A release deferred by a task stays queued, and the update daemon retries it every
`release.autoUpdate.intervalSec`.

The options mirror the NixOS ones where they apply. `listen`, `secrets`, `label` and
`autoUpdate.intervalSec` are darwin's own:

```nix
{
  imports = [ inputs.nix-infra-modules.darwinModules.projects ];

  system.primaryUser = "alice";
  fleet.services.projects.releaseCacheStore = "https://cache.example.net";
  fleet.appDeployments.webhook = {
    host = "100.64.0.10"; # 127.0.0.1 by default; nix-darwin opens no firewall
    port = 18100;
    tokenSecretName = "/etc/app-deployments/webhook-token";
  };

  projects.shop = {
    source = inputs.shop;
    release = {
      parameters.homeDirectory = "/Users/alice";
      secrets.apiKey = "/etc/shop/api-key";
      environment.SHOP_MODE = "release";
      runtime.workingDirectory = "/Users/alice";
      listen = {
        host = "100.64.0.10";
        port = 3773;
      };
    };
  };
}
```

A Mac runs a narrower release:

- The service is a launchd agent of `system.primaryUser` in its GUI session (`release.label`,
  `org.nixos.app-deployment-<project>` by default), so it can drive the desktop. Releases need that
  session: turn on automatic login for the user, since without a login the agent can't load and
  every update fails.
- Releases arrive by cache delivery only (`release.delivery.cacheStore`) and run as
  `release.runtime.user` without a sandbox, like a `trusted` release on NixOS. The service, its
  pre-deploy tasks and its activation share `release.runtime.home`, the user's home by default.
- Secret bindings are files (`release.secrets`). Activation copies them into
  `/var/lib/app-deployments/<project>/runtime/secrets`, readable by the release user only, after
  sops-nix has decrypted its secrets.
- A switch that changes a release's bindings, such as a secret, parameter or listen address,
  queues the active release again, as a placement's redeploy does on NixOS: the update binds it
  anew and restarts the service once its pre-deploy tasks allow. The switch also retries a queued
  release at once, such as one whose update the reload of the update daemon stopped. A changed
  secret alone restarts the service.
- The service listens on `release.listen` itself; the host routes traffic to it. There are no
  grants or placements, ingress, OCI auxiliaries, maintenance jobs, health recovery or providers,
  so nix-darwin has none of their options.
- `source` is a flake whose `lib.project` is the contract.

State lives under `/var/lib/app-deployments/<project>`, as on NixOS, so host tooling finds the
active release at the same path on both. The webhook and update daemons run as root, because only
a trusted Nix client may substitute from the release cache, and log to
`/Library/Logs/app-deployments`. The webhook starts the update daemon and waits for its result,
so reloading the webhook doesn't kill an update in flight. The host's Nix must trust the cache's signing key.

nix-darwin reloads the agent when its plist changes, which restarts the service outside the
release flow. The plist changes only with the release's host policy, not with a release.
