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

## Project Release Adapter

Repositories that publish a schema v1 [Project descriptor](project-descriptor.md)
can keep application-specific runtime knowledge in the repository and pass only
host policy through private infrastructure:

```nix
let
  descriptor = builtins.fromJSON (builtins.readFile ./project.json);
in
{
  vps.services.appDeployments.apps.studienbuch =
    inputs.nix-infra-modules.lib.projectDescriptor.releaseApp {
      inherit descriptor;
      policy = {
        project = "studienbuch";
        source.url = "git+https://git.example.net/example/studienbuch.git";
        domain = "studienbuch.example.net";
        public = true;
        secrets.betterAuthSecret = config.sops.secrets."studienbuch/better-auth".path;
        approvedOci = [ "database" ];
        jobs.cleanup = {
          interval = "1d";
          onBootSec = "15min";
          randomizedDelaySec = "30min";
        };
        resources.memory = {
          high = "768M";
          max = "1G";
          swapMax = "0";
        };
      };
    };
}
```

The adapter infers the package, executable, health policy, state directories,
and structured ingress behavior from the descriptor. It allocates loopback
ports deterministically, so private configuration normally does not contain an
application or auxiliary port. `projectPortRange` and
`projectAuxiliaryPortRange` are fleet-level escape hatches, not per-project
configuration.

The built Release package must carry the repository-authored descriptor at
`share/project/descriptor.json`. Before cutover, the updater compares its
JSON value with the raw descriptor pinned by host evaluation. Normalization is
used internally but is deliberately not used for that identity check, so a
concise descriptor that relies on defaults remains valid.

Service Releases receive one generated JSON file through
`PROJECT_RUNTIME_FILE`. It contains the Project identity, realization,
host-owned state/runtime paths, the external URL and allocated listen address,
resolved non-secret parameters, semantic Secret credential names, and any
allocated auxiliary endpoints. Secret values are exposed with systemd
`LoadCredential`; `PROJECT_SECRETS_DIR` points to that credential directory.
Repositories derive framework-specific variables such as database or auth URLs
from this small manifest rather than requiring those variables in infra.

An optional `activationExecutable` is run once when a different store output is
cut over, before the service starts and with the same manifest and credentials.
It is not part of ordinary process startup. Failed activation or health checks
restore the previous output; when activation changed persistent state, the
previous activation executable is run again as part of rollback.

Project service units receive conservative systemd hardening and periodic
health recovery. Forwarded HTTPS headers and the health-check Host header are
inferred when a domain is bound. OCI auxiliaries must use digest-pinned images
and private host policy must approve exactly the descriptor's named auxiliary
set, so both missing and stale approvals fail evaluation; their ports bind only
to localhost. Host policy may also set typed Release memory thresholds through
`resources.memory.high`, `max`, and `swapMax`, which map to the corresponding
systemd controls for repository-owned Release actions.

Host policy may schedule descriptor-declared maintenance jobs by name. Each job
sets exactly one of `calendar` or `interval`; interval jobs may set
`onBootSec`, and all jobs may set `randomizedDelaySec` and `persistent`.
The generated one-shot invokes the same Release executable with the descriptor
action as its single argument and reuses the exact runtime manifest,
credentials, user, hardening, memory policy, and auxiliary ordering. Maintenance
actions always run at low CPU and IO priority (`Nice=10`, idle IO scheduling);
raw systemd overrides are not part of the Project job interface.

Legacy declarations keep their existing environment, ports, raw Caddy
configuration, systemd overrides, update timer, exact-revision webhook,
activation symlinks, health checks, and rollback behavior. The Project adapter
is additive.

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
health-check and rollback flow, Project runtime manifest, port allocation,
generic service hardening, structured ingress rendering, approved OCI runtime,
and tailnet webhook plumbing.

Private repos own app instances, repository URLs, credential secret names,
webhook token secrets, domains/visibility, parameter values, OCI approval,
maintenance-job schedules/resource policy, branch/revision policy, and
placement on real hosts. A descriptor owns maintenance job names and actions;
the generic Release adapter materializes only those jobs selected by host
policy.

## Invariants

- App state lives under `/var/lib/app-deployments`.
- The webhook is tailnet-only by default and requires a token when enabled.
- The update service records requested revisions separately from deployed
  revisions.
- A failed health check keeps or restores the previous working profile.
- Project artifacts must contain the exact pinned descriptor JSON value.
- Project activation runs on a new cutover, never on an ordinary restart.
- Project and OCI listener ports are deterministically allocated and remain on
  loopback.
- Static Project routes return 404 for `/share/project/*`, keeping the artifact
  descriptor out of the served site.
- Static deployments do not create an application user or long-running
  application systemd service.

Declare ordinary flake-packaged HTTP apps under
`vps.services.appDeployments.apps`. Add private wrappers when a real app needs
credentials or deployment policy that should not be public.
