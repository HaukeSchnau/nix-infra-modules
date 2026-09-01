# Runner Modules

The runner modules are opinionated fleet leaf modules for self-hosted CI
workers.

## GitHub Runner

```nix
{
  vps.enable = true;
  vps.services.githubRunner = {
    enable = true;
    url = "https://github.com/example-org/example-repo";
    tokenFile = "/run/secrets/github-runner-token";
  };
}
```

The public module owns the rendered `services.github-runners` instances, system
user, work directories, default labels, Podman/Docker environment, and resource
limits.

## Gitea Actions Runner

```nix
{
  vps.enable = true;
  vps.services.giteaActionsRunner = {
    enable = true;
    url = "https://git.example.net";
    tokenFile = "/run/secrets/gitea-runner-token";
    resources.memoryHigh = "3.5G";
  };
}
```

The public module owns the rendered Gitea runner instance, host packages,
labels, Podman/Docker environment, and configurable memory limits.

Named pools reserve runner capacity for independent projects or workload
classes. Pool names become labels, and `count` creates stable instances with
separate CI workspace slots:

```nix
{
  vps.services.giteaActionsRunner.pools = {
    quick = { };
    bulk.count = 2;
  };
}
```

Jobs select a pool with `runs-on: quick` or `runs-on: bulk`. Pool names and
counts describe scheduling policy only. Repositories remain responsible for
their language, tools, and task graph. Every runner instance gets a short,
persistent workspace cache root so tools that use Unix sockets do not inherit
the deeper runner state path.

## Boundary

Public modules use token file paths. Private adapters should map SOPS, agenix,
or another secret system to those paths and keep real runner registration URLs,
token secret names, and placement private.

The default labels, packages, and memory limits are intentionally opinionated.
If a consuming fleet needs different behavior, set the exposed options or wrap
the public module in a private adapter.
