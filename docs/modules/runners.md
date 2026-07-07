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
  };
}
```

The public module owns the rendered Gitea runner instance, host packages,
labels, Podman/Docker environment, and resource limits.

## Boundary

Public modules use token file paths. Private adapters should map SOPS, agenix,
or another secret system to those paths and keep real runner registration URLs,
token secret names, and placement private.

The default labels, packages, and memory limits are intentionally opinionated.
If a consuming fleet needs different behavior, set the exposed options or wrap
the public module in a private adapter.
