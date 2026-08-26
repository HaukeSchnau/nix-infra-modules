# Project Descriptor Schemas

A Project descriptor is repository-owned, versioned JSON. It describes what a
repository can run in Development and Release without embedding fleet policy or
NixOS implementation details.

The public helper is exported as `lib.projectDescriptor`:

- `load { path; expectedProject?; }` reads and normalizes JSON.
- `normalize { descriptor; expectedProject?; }` validates schema v1 through v3 and
  fills defaults. Normalization is idempotent.
- `requireRealizations { descriptor; expectedProject?; }` additionally requires
  both Development and Release. It supports auditing v1 repositories during a
  rolling migration; v2 and v3 enforce this invariant directly.
- `resolveParameters { descriptor; values?; allowUnknown?; }` type-checks host
  values and applies repository defaults. Release adapters retain unknown
  values as forward bindings when `allowUnknown` is enabled.
- `releaseApp { descriptor; policy; }` projects a Release into the typed
  `appDeployments` interface while keeping repository requirements separate
  from host bindings.
- `lib.projectRuntime` turns the descriptor into conventional repository
  Runtime packages, local flake apps, and exact-descriptor Release artifacts;
  see [Project Runtime](./project-runtime.md).

## Shape

Schema v3 is the current Project contract. It adds background Development
workloads and interactive commands to the paired Development and Release model
introduced by v2:

```json
{
  "$schema": "https://raw.githubusercontent.com/HaukeSchnau/nix-infra-modules/main/schemas/project-descriptor/v3.json",
  "schemaVersion": 3,
  "project": "example",
  "secrets": {
    "betterAuthSecret": { "description": "Signs sessions" }
  },
  "parameters": {
    "maxStorageMb": { "type": "integer", "default": 512 }
  },
  "development": {
    "workloads": {
      "database": {},
      "web": { "dependsOn": ["database"] },
      "importer": {
        "dependsOn": ["database"],
        "lifecycle": "background"
      }
    },
    "commands": {
      "console": { "dependsOn": ["database"] }
    },
    "endpoints": {
      "database": { "protocol": "tcp" },
      "web": { "workload": "web" }
    }
  },
  "release": {
    "action": "web",
    "commands": {
      "console": {}
    },
    "preDeployTasks": {
      "migrate": { "timeoutSec": 300 },
      "wait-for-idle": { "failureMode": "defer" }
    },
    "activationExecutable": "activate-release",
    "stateDirectories": ["data"],
    "ingress": {
      "compression": true,
      "streamCloseDelaySec": 300,
      "redirects": [
        { "from": "/old", "to": "/new", "permanent": false }
      ],
      "cacheRules": [
        { "paths": ["/assets/*"], "value": "public, max-age=3600" }
      ]
    },
    "ociAuxiliaries": {
      "database": {
        "image": "postgres@sha256:<digest>",
        "ports": {
          "postgres": { "containerPort": 5432 }
        }
      }
    }
  }
}
```

Repository `project.json` files should declare the numbered schema through the
standard `$schema` property shown above. Numbered schemas are immutable. The
property is authoring metadata and is omitted from the normalized descriptor.

Schema v1 and v2 remain supported without semantic changes. Only
`schemaVersion` and `project` are always required in v1, and a v1 descriptor may
define either or both realizations. New Projects should emit v3.

Defaults are intentionally aggressive. Development Endpoints imply same-named
workloads and actions. Release defaults to backend `service`, package
`projectRelease`, executable `project-release-runtime`, health path `/`, and no
state, ingress customization, jobs, or OCI auxiliaries. OCI port protocol
defaults to `tcp`.

Service Releases also default `action` to `web`. The shared Runtime Module uses
that action when the Release executable is invoked without arguments. Declare
it explicitly whenever a repository uses another name.

Secrets and parameters use semantic names containing letters, digits,
underscores, dots, or hyphens. Parameter types are `string`, `boolean`,
`integer`, and `number`. A parameter with a default is optional unless
explicitly marked required. Workload, preparation, pre-deploy task, and
maintenance-job Secret references must name declarations at the descriptor root.
Command Secret references follow the same rule. Development commands may depend
on Workloads so the host can start services such as a database before invoking
the command. Release commands reuse the active Release dependencies.

Development contains a preparation action, acyclic Workload dependency graph,
and HTTP or TCP Endpoints with health policy. A v3 Workload defaults to the
`on-demand` lifecycle. Managed Development starts each `background` service for
every available registered instance and supervises it without requiring an
Endpoint. Tasks cannot use the background lifecycle. Local `dev` continues to
start all selected Workloads, so lifecycle changes managed autostart rather
than the repository's local process graph. HTTP health defaults to path `/`;
TCP health is a connect-only probe and therefore has no paths. Both share
`startupTimeoutSec`, `intervalSec`, and `requestTimeoutSec`. Development probes
default to a fifteen-second request timeout and one-second retry interval.
Connection-refused attempts still retry promptly, while a dev server that has
accepted the request gets enough time to finish its first route compilation
without repeated client cancellations. Release retains the five-second timeout
and two-second interval. Release contains
backend/package/executable, health policy, safe relative state directories,
structured ingress, maintenance-job action declarations, an optional activation
executable, a schema v2-or-newer pre-deploy task graph, and explicitly approved
digest-pinned OCI auxiliaries. Pre-deploy tasks default their action to their
name and their timeout to 900 seconds. Dependencies must reference other
pre-deploy tasks and form an acyclic graph. Ingress
supports compression, request-body limits, response headers, redirects, and
Cache-Control rules; it never accepts raw proxy configuration.

## Ownership Boundary

The descriptor must not contain domains, visibility, hostnames, listener ports,
absolute state paths, Secret storage paths, SOPS keys, systemd settings, Caddy
syntax, schedules, or host placement. Those are host policy.

The repository owns application semantics: its graph and actions, required
Secrets, typed parameters/defaults, health contract, relative state layout,
structured HTTP intent, package/executable names, and approved runtime
capabilities. The private infra repo binds that declaration to source, domain,
visibility, parameter values, credential paths, and explicit OCI approval.
Host Release policy may additionally bind typed memory high/max/swap limits;
these remain outside the portable descriptor because they depend on machine
capacity and placement.

Release bindings are deliberately monotonic. Infra may declare a parameter,
Secret, job schedule, or OCI approval before the pinned descriptor uses it;
stale bindings do not invalidate an older artifact. A promoted candidate may
add a required parameter or Secret only when the binding already exists.

An Endpoint protocol describes only the portable network contract. Use `http`
for HTTP applications and `tcp` for local socket dependencies. Do not encode
application or framework names such as Postgres, Redis, Expo, Vite, Docker, or
Podman as protocols. A repository action obtains its allocated listener through
`project-context` and derives application-specific environment variables or
connection strings itself.

The Release action name is also the semantic name of its primary Runtime
Endpoint. OCI auxiliary listeners retain both descriptor names at the query
Interface: auxiliary name and port name. Repository actions do not depend on
flattened manifest keys or adapter-generated endpoint names.

Pairing is a repository capability invariant, not a placement invariant. The
same paired descriptor may back one Development placement and several named
Release-only placements on different hosts. Infrastructure decides which
realizations to place and whether an HTTP Endpoint is local, Tailnet-only, or
public.

Interactive commands declare a stable user-facing name, an opaque action, and
the Secrets they require. They contain no terminal, user, path, or privilege
policy. The host adapter selects the active realization, supplies Runtime
Context and credentials, and forwards the command arguments and terminal.

Maintenance jobs intentionally stop at names/actions in every schema version.
Private host policy supplies schedules and resource policy. The generic Release
adapter then invokes the repository Release executable with the declared action
as its single argument, reusing the normal runtime manifest and credentials.
This keeps operational policy out of the portable descriptor without
duplicating runtime projection in private adapters. Maintenance actions receive
fixed low-priority CPU/IO defaults rather than an arbitrary systemd
configuration escape hatch.
