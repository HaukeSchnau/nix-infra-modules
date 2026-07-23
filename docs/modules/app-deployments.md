# App Deployments

`vps.services.appDeployments.apps` is the primary interface for durable,
flake-packaged services and static sites:

```nix
{
  vps.services.appDeployments = {
    enable = true;
    apps.demo = {
      domain = "demo.example.net";
      public = true;
      port = 8080;
      executable = "demo-server";
      source.url = "git+https://git.example.net/example/demo.git";
    };
  };

  vps.appDeployments.webhook.tokenSecretName = "app-deployments/webhook-token";
}
```

Static sites use the same exact-revision build, activation, rollback, timer,
and webhook machinery without creating an application process:

```nix
{
  vps.services.appDeployments.apps.docs = {
    backend = "static";
    domain = "docs.example.net";
    public = true;
    package = "site";
    static.extraConfig = ''
      encode zstd gzip
    '';
    source.url = "git+https://git.example.net/example/docs.git";
    health.paths = [
      "/"
      "/guide/"
      "/manual.pdf"
    ];
  };
}
```

The app attribute name becomes the deployment name, unit suffix,
state-directory suffix, and webhook target. Service deployments also use it as
their system-user suffix. App declarations are typed, so invalid ports,
packages, health settings, and update settings fail during module evaluation.

`lib.nixos.nixFlakeService` remains available as a compatibility adapter for
existing callers. It contributes the supplied app to the same typed registry;
new configurations should declare the app directly.

Each application's `enable` option controls its lifecycle. The surrounding
`vps.services.appDeployments.enable` option controls shared deployment plumbing
such as the webhook, so disabling that shared service does not stop explicitly
declared applications. This preserves the compatibility adapter's established
behavior.

The implementation keeps deployment state under `/var/lib/app-deployments` and
builds a selected flake reference. Service deployments run the selected
executable as a dedicated system user and probe health paths over HTTP. Static
deployments atomically point Caddy at the selected store output and verify that
each health path resolves to a file or directory index. Both backends preserve
the previous output for rollback.

The module does not require private Git credentials unless
`source.giteaTokenSecretName` is set by the consuming private repo.

## Ownership Boundary

Public modules own the deployment state layout, generated service wrapper,
health-check and rollback flow, and tailnet webhook plumbing.

Private repos own app instances, repository URLs, credential secret names,
webhook token secrets, branch/revision policy, and placement on real hosts.

## Invariants

- App state lives under `/var/lib/app-deployments`.
- The webhook is tailnet-only by default and requires a token when enabled.
- The update service records requested revisions separately from deployed
  revisions.
- A failed health check keeps or restores the previous working profile.
- Static deployments do not create an application user or long-running
  application systemd service.

Declare ordinary flake-packaged HTTP apps under
`vps.services.appDeployments.apps`. Add private wrappers when a real app needs
credentials or deployment policy that should not be public.
