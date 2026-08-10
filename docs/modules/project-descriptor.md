# Project Descriptor Schemas

A Project descriptor is repository-owned, versioned JSON. It describes what a
repository can run in Development and Release without embedding fleet policy or
NixOS implementation details.

The public helper is exported as `lib.projectDescriptor`:

- `load { path; expectedProject?; }` reads and normalizes JSON.
- `normalize { descriptor; expectedProject?; }` validates schema v1 or v2 and
  fills defaults. Normalization is idempotent.
- `requireRealizations { descriptor; expectedProject?; }` additionally requires
  both Development and Release. It supports auditing v1 repositories during a
  rolling migration; v2 enforces this invariant directly.
- `resolveParameters { descriptor; values?; }` type-checks host values and
  applies repository defaults.
- `releaseApp { descriptor; policy; }` projects a Release into the typed
  `appDeployments` interface while preserving the raw descriptor for artifact
  identity.
- `lib.projectRuntime` turns the descriptor into conventional repository
  Runtime packages, local flake apps, and exact-descriptor Release artifacts;
  see [Project Runtime](./project-runtime.md).

## Shape

Schema v2 is the complete Project contract. It requires both Development and
Release capabilities in the repository, independently of where either
realization is placed:

```json
{
  "schemaVersion": 2,
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
      "web": { "dependsOn": ["database"] }
    },
    "endpoints": {
      "database": { "protocol": "tcp" },
      "web": { "workload": "web" }
    }
  },
  "release": {
    "action": "web",
    "activationExecutable": "activate-release",
    "stateDirectories": ["data"],
    "ingress": {
      "compression": true,
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

Schema v1 remains supported without semantic changes: only `schemaVersion` and
`project` are always required, and a v1 descriptor may define either or both
realizations. New and migrated Project repositories should emit v2.

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
explicitly marked required. Workload, preparation, and maintenance-job Secret
references must name declarations at the descriptor root.

Development contains a preparation action, acyclic Workload dependency graph,
and HTTP or TCP Endpoints with health policy. HTTP health defaults to path `/`;
TCP health is a connect-only probe and therefore has no paths. Both share
`startupTimeoutSec`, `intervalSec`, and `requestTimeoutSec`. Release contains
backend/package/executable, health policy, safe relative state directories,
structured ingress, maintenance-job action declarations, an optional activation
executable, and explicitly approved digest-pinned OCI auxiliaries. Ingress
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

Maintenance jobs intentionally stop at names/actions in both schema versions.
Private host policy supplies schedules and resource policy. The generic Release
adapter then invokes the repository Release executable with the declared action
as its single argument, reusing the normal runtime manifest and credentials.
This keeps operational policy out of the portable descriptor without
duplicating runtime projection in private adapters. Maintenance actions receive
fixed low-priority CPU/IO defaults rather than an arbitrary systemd
configuration escape hatch.
