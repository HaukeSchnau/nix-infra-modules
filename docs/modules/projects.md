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

  vps.services.projects = {
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
      endpoint = { hostName = "shop.example.net"; visibility = "public"; };
      secrets.apiKey.sopsKey = "shop/api-key";
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
module does not publish them itself: `vps.services.projects.routeSources`
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
secret requirements use the credential of the same name. Releases default to
`<project>.<releaseDomain>`, or `<instance>.<project>.<releaseDomain>` for a
named placement; an explicit `hostName` keeps the generated name as a redirect
alongside `endpoint.aliases`.

`vps.services.projects.resolvedReleases` and `resolvedDevelopments` summarize
the placements for other modules, such as a fleet topology.
