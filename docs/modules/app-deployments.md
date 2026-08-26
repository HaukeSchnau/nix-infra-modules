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

Repositories that publish a [Project descriptor](project-descriptor.md)
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
        delivery = {
          mode = "cache";
          cacheStore = "https://cache.example.net/nix";
        };
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
`share/project/descriptor.json`. Before cutover, the updater binds that
candidate descriptor against host policy. Development-only and descriptive
changes do not affect Release compatibility. Parameters and Secrets are
requirements: every required candidate binding must be available and parameter
values must match the candidate type. Extra host bindings are retained so infra
can land before the repository change and old releases remain roll-backable.

Fields compiled into NixOS topology remain compatibility-sensitive: backend,
action/executable, state directories, ingress, the host-selected maintenance
job names, and OCI auxiliaries. Health policy, pre-deploy tasks, activation,
and the definitions of selected maintenance jobs are resolved from each
candidate into an immutable Release plan. Compatible changes to those fields
therefore deploy without a NixOS switch. An incompatible candidate remains
queued while the active release continues serving traffic.

With `delivery.mode = "cache"`, CI builds and verifies the Release, waits for
its output in the configured binary cache, and posts both the commit revision
and immutable `/nix/store` path to the webhook. The host realizes that concrete
path with local and remote builders disabled. It neither evaluates repository
source nor falls back to a production build. The durable request is removed
only after successful activation and health checks; timer reconciliation retries
cache lag and transient failures.

Service Releases receive one generated JSON file through
`PROJECT_RUNTIME_FILE`. It contains the Project identity, realization,
host-owned state/runtime paths, the external URL and allocated listen address,
resolved non-secret parameters, semantic Secret credential names, and any
allocated auxiliary endpoints. Secret values are exposed with systemd
`LoadCredential`; `PROJECT_SECRETS_DIR` points to that credential directory.
Repositories derive framework-specific variables such as database or auth URLs
from this small manifest rather than requiring those variables in infra.
Descriptor v2 and newer Releases use Runtime manifest v2. It marks the
service Endpoint as HTTP and exposes auxiliary TCP listeners without inventing
application-specific URLs; repository actions construct those from
`project-context`. Descriptor v1 retains its original manifest shape for
rolling compatibility. UDP auxiliaries are not supported by Runtime v2.

The updater installs that manifest in deployment state and cuts it over
atomically with the `current` package symlink. Rollback restores the previous
package and manifest together. A NixOS generation may therefore change the
Runtime Context interface without ever starting an older repository artifact
against the newer interface. The manifest is readable by the isolated service
user but contains only Secret names; values remain exclusively in systemd's
credential directory.

Schema v2 service Releases may declare `preDeployTasks`. The updater runs their
acyclic dependency graph from a GC-rooted candidate artifact and candidate
Runtime Context before it changes `current`. Each task has its own timeout and
receives only its declared systemd credentials. A failed task leaves the active
artifact, Runtime Context, and service untouched. Tasks with
`failureMode = "defer"` also leave the requested Release queued and report a
successful reconciliation, so the update timer can retry a safe cutover later.

Descriptor v3 service Releases may declare interactive commands. The module
installs the root-only `project-release-command <project> <command>
[arguments...]` adapter. It resolves the command from the active Release plan,
runs the active artifact as its service user in a transient systemd service,
loads only the command's declared credentials, and forwards the caller's
terminal and exit status. Host tooling can delegate to this adapter without
depending on deployment state paths or service account names.

The root-only `project-release-status <project> [--json]` adapter reports the remote branch,
active/previous/pending revisions, descriptor compatibility, service state and restart count,
public health checks, and the last updater result. It deliberately omits Nix store paths. Private
host tooling can present it without duplicating the deployment state model.

The reusable Gitea workflow verifies a Project, builds its immutable
Release, waits for cache publication, and promotes the exact store path. Runner
infrastructure supplies cache and promotion bindings. A project may map to
multiple promotion URLs when the same Release has several placements.

Hosts may opt a Runtime Context v2 application into `exposeRevision`. The updater then binds the
promoted immutable Git revision into the candidate, active, and rollback manifests. It is not
enabled by default, so applications pinned to older strict Runtime Context validators continue to
work until they deliberately adopt the field.

Deployments use an isolated `app-<name>` account by default. Host policy may
instead bind an existing user, group, home, working directory, and writable
paths. This is intended for services that operate on user-owned state while
keeping those deployment choices out of the repository descriptor.

Pre-deploy tasks must be idempotent and backward-compatible with the active
service. The updater does not reverse a successful task if later activation or
HTTP health fails. Database migrations should use expand-and-contract changes
instead of destructive changes that require the new process immediately.

Host-managed dependencies belong in `unitDependencies`. `after`, `wants`, and
`requires` are applied consistently to the updater, pre-deploy tasks, service,
activation, and maintenance actions. Wanted and required units are also ordered
before those actions; callers do not need to repeat them in `after`.

An optional `activationExecutable` is resolved from the candidate Release plan
and run once when a different store output is cut over, before the service
starts and with the same manifest and credentials. A repository may add,
remove, or replace it without a NixOS switch. It is not part of ordinary
process startup. Failed activation or health checks restore the previous
output; when activation changed persistent state, the previous Release plan's
activation executable is run again as part of rollback.

Project service units receive conservative systemd hardening and periodic
health recovery. Forwarded HTTPS headers and the health-check Host header are
inferred when a domain is bound. OCI auxiliaries must use digest-pinned images
and private host policy must approve every descriptor-requested auxiliary.
Stale approvals are retained harmlessly for forward changes and rollback; their
ports bind only to localhost. Host policy may also set typed Release memory thresholds through
`resources.memory.high`, `max`, and `swapMax`, which map to the corresponding
systemd controls for repository-owned Release actions.

Applications may give descriptor-declared maintenance jobs a default `schedule`
with exactly one of `calendar` or `interval`. Interval schedules also select a
`cadence`: `fixed` measures between start times, while `spaced` measures from a
completed run to the next start. The host activates these defaults when it binds
the Project and may replace the schedule, override the cadence, add
`onBootSec`, `randomizedDelaySec`, or `persistent`, or set `enable = false`.
This keeps product polling policy beside the application action while leaving
load spreading and machine lifecycle under host control.

Project update, recovery, and interval-job timers use relative delays, so adding
or changing a Project on an already-running host never starts repository builds
or maintenance work inside a NixOS switch. Fixed-cadence jobs also retain an
inactive-unit fallback, so a failed activation does not silently stop future
runs. systemd prevents a maintenance one-shot from overlapping itself.
The generated one-shot reads the current action from the active Release plan,
then invokes the same Release executable with that action as its single
argument. A repository may change the action or its Secret requirements while
the host keeps the job's schedule. Removing a host-selected job is
incompatible. The unit reuses the exact runtime manifest, host-bound
credentials, user, hardening, memory policy, and auxiliary ordering.
Maintenance actions always run at low CPU and IO priority (`Nice=10`, idle IO
scheduling); raw systemd overrides are not part of the Project job interface.

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

Private repos own app instances, repository URLs, delivery/cache policy, credential secret names,
webhook token secrets, domains/visibility, parameter values, OCI approval,
maintenance-job operational overrides/resource policy, branch/revision policy,
and placement on real hosts. A descriptor owns maintenance job names, actions,
and default schedules;
the generic Release adapter materializes only those jobs selected by host
policy.

## Invariants

- App state lives under `/var/lib/app-deployments`.
- The webhook is tailnet-only by default and requires a token when enabled.
- Cache-delivered requests record both the exact revision and immutable store
  path separately from the deployed revision.
- A Project revision change updates its runtime manifest and restarts its service even when Nix
  reuses the same store output, so the process observes the promoted revision.
- A failed health check keeps or restores the previous working profile.
- Project artifacts must satisfy the pinned Release topology and current host
  bindings; extra infra bindings are allowed.
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
