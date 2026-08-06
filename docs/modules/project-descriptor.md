# Project Descriptor Schema v1

A Project descriptor is repository-owned, versioned JSON. It describes what a
repository can run in Development and Release without embedding fleet policy or
NixOS implementation details.

The public helper is exported as `lib.projectDescriptor`:

- `load { path; expectedProject?; }` reads and normalizes JSON.
- `normalize { descriptor; expectedProject?; }` validates schema v1 and fills
  defaults. Normalization is idempotent.
- `resolveParameters { descriptor; values?; }` type-checks host values and
  applies repository defaults.
- `releaseApp { descriptor; policy; }` projects a Release into the typed
  `appDeployments` interface while preserving the raw descriptor for artifact
  identity.

## Shape

Only `schemaVersion` and `project` are always required. A descriptor can define
either or both realizations:

```json
{
  "schemaVersion": 1,
  "project": "example",
  "secrets": {
    "betterAuthSecret": { "description": "Signs sessions" }
  },
  "parameters": {
    "maxStorageMb": { "type": "integer", "default": 512 }
  },
  "development": {
    "endpoints": {
      "web": {}
    }
  },
  "release": {
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

Defaults are intentionally aggressive. Development endpoints imply same-named
workloads and actions. Release defaults to backend `service`, package
`projectRelease`, executable `project-release-runtime`, health path `/`, and no
state, ingress customization, jobs, or OCI auxiliaries. OCI port protocol
defaults to `tcp`.

Secrets and parameters use semantic names containing letters, digits,
underscores, dots, or hyphens. Parameter types are `string`, `boolean`,
`integer`, and `number`. A parameter with a default is optional unless
explicitly marked required. Workload, preparation, and maintenance-job Secret
references must name declarations at the descriptor root.

Development contains a preparation action, workload dependency graph, and HTTP
endpoints with health policy. Release contains backend/package/executable,
health policy, safe relative state directories, structured ingress,
maintenance-job action declarations, an optional activation executable, and
explicitly approved digest-pinned OCI auxiliaries. Ingress supports compression,
request-body limits, response headers, redirects, and Cache-Control rules; it
never accepts raw proxy configuration.

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

Maintenance jobs intentionally stop at names/actions in schema v1. Private host
policy supplies schedules and resource policy. The generic Release adapter then
invokes the repository Release executable with the declared action as its
single argument, reusing the normal runtime manifest and credentials. This
keeps operational policy out of the portable descriptor without duplicating
runtime projection in private adapters. Maintenance actions receive fixed
low-priority CPU/IO defaults rather than an arbitrary systemd configuration
escape hatch.
