# Project Runtime

`lib.projectRuntime` builds immutable service and static releases. It owns their
versioned runtime manifest, validation, action dispatch, context queries and
embedded descriptor.

## Development

Development tools, setup tasks and processes belong in `devenv.nix`. Shared
requirements and release policy belong in `project.nix`. See
[shared project definitions](./project-definition.md).

The former `mkDevelopment` constructor, flake development apps, local allocator
and custom process supervisor have been removed. Managed development uses a
native devenv manager with a host-supplied runtime context. The Python
`project-context` helper remains available for querying that context and resolving
environment mappings. It does not launch workloads.

## Release

```nix
release = inputs.nix-infra-modules.lib.projectRuntime.mkServiceRelease {
  inherit pkgs;
  descriptor = project;
  payloads = [ application ];
  actions = {
    web = lib.getExe serveAction;
    backup = lib.getExe backupAction;
  };
  activation = lib.getExe activationAction;
};

packages.projectRelease = release.package;
```

The default action comes from `release.action`; an explicitly passed
`defaultAction` must agree. Maintenance actions must exactly match the
descriptor. Pre-deploy task and interactive command actions must also have implementations.
`activation` must be present exactly when the descriptor declares
`activationExecutable`. The service artifact contains the dispatcher, payloads,
optional activation wrapper, and the byte-for-byte repository descriptor at
`share/project/descriptor.json`.

Service Releases use a small statically linked Go dispatcher. The Go compiler
is only a build input, and neither Go nor Python enters the Release closure.
The compiled dispatcher validates Runtime manifests, answers `project-context`
queries, selects actions and forwards arguments. Its context queries and failure
statuses agree with the Python context helper used by native development.

Static Releases use `mkStaticRelease { descriptorPath; root; ...; }`. It combines
the site root with the same exact descriptor artifact and adds no service
runtime.

## Runtime context

Infrastructure supplies a versioned JSON manifest and credential directory to
the dispatcher. Those transport variables are private Runtime Module
implementation details. The dispatcher validates Project identity and
Realization, creates allocated directories, and places `project-context` on the
action `PATH`.

Actions use that single stable query Interface and never parse JSON or read
`PROJECT_*` transport and path variables directly:

```sh
checkout="$(project-context path checkout)"
port="$(project-context endpoint web listen-port)"
protocol="$(project-context endpoint web protocol)"
origin="$(project-context endpoint web url)"
hosts="$(project-context endpoint web host-names --json)"
mode="$(project-context parameter mode --default '"development"')"
revision="$(project-context revision || true)"
instance_id="$(project-context instance-id || true)"
token_file="$(project-context secret-file authToken --required)"
```

`project-context` also supports `path <name>`. It never prints Secret values;
`secret-file` returns only a validated path beneath the credential directory.
Managed adapters bind and enforce required Secrets. Native local development
uses the repository's devenv configuration for credentials.

`project-context instance-id` returns the stable Development instance identity. It separates
telemetry, caches, and other diagnostic output from concurrent Checkouts. Release runtimes return
status 1 because their immutable revision and deployment identity already cover that role.

Release hosts may add an immutable Git revision to Runtime Context v2. Actions query it with
`project-context revision`; the command exits with status 1 when a Development adapter or an older
Release binding does not provide one. Applications should treat that absence as an explicit
development or legacy state and never infer a revision from a mutable checkout.

Release primary Endpoints use the repository-owned Release action name. A
Release with action `web` therefore queries `endpoint web` just like
Development; repositories never need an infrastructure-generated `default`
name. Digest-pinned OCI auxiliary listeners are queried by their descriptor
identity with `auxiliary <name> <port> <field>`; their flattened manifest keys
remain an implementation detail.

Runtime manifest v2 makes Endpoint transport explicit. HTTP Endpoints carry a
URL and may carry hostnames and visibility. TCP Endpoints carry only their
allocated listener; `url` is intentionally unavailable because the repository,
not infrastructure, owns application-specific connection-string construction.
For example, a database action can query `listen-host` and `listen-port`, read a
password path with `secret-file`, and derive `DATABASE_URL` without teaching the
infrastructure contract about Postgres.

## Ownership

The repository owns the descriptor and opaque executable Adapters: application
semantics, Workload graph, health contract, relative State, Secret names,
parameters, and framework translation. Infrastructure owns listener and URL
allocation, hostnames and visibility, absolute paths, Secret values, schedules,
resources, placement, and publication.

The Runtime Module owns only the Seam: manifest protocol, validation,
compatibility, context queries, dispatch, and artifact
identity. It does not infer application environment variables or package-manager
commands.

## Rolling compatibility and errors

Schemas live below `schemas/project-descriptor/` and `schemas/project-runtime/`.
A numbered schema is immutable. Descriptor v1 and runtime v1 remain supported.
Descriptor v2 introduced paired realizations and runtime v2. Descriptor v3 adds
background workload lifecycle and interactive commands without changing Runtime
Context, so it continues to use runtime v2. New producers emit
canonical `parameters`; runtime v1 consumers accept legacy `settings` only when
`parameters` is absent. Actions depend on `project-context`, not the JSON layout,
and the dispatcher normalizes both runtime versions behind that Interface.

Runtime failures use stable statuses: 64 for invocation/action errors, 65 for
invalid manifests or identity, 66 for unavailable or unsafe allocations and
credentials, and 69 when an Adapter cannot execute or a listener cannot be
allocated.

## Runtime manifest v3

Descriptor v4 uses runtime manifest v3 with an explicit stable `instanceId` and
resource `bindings`. Both the Python Development runtime and compiled Go Release
runtime validate the same bindings and resolve declarative environment mappings.
Release artifacts retain their small compiled runtime without Python dependencies.

The context interface adds `project-context binding NAME FIELD [--json]` and
`project-context environment [ACTION]`. The latter prints quoted shell exports
and unsets. `snapshot` includes binding metadata and the instance ID, never secret
contents. Existing context commands remain available.

V4 requires a host-supplied runtime manifest. Running native devenv locally uses
its normal local environment; it does not invoke a second Project allocator.
Retained release artifacts keep their pinned runtime. Older descriptor readers remain
available for production rollback.

## Generated descriptors

Service and static release helpers accept `descriptor`, an evaluated Nix
attribute set, and generate the embedded JSON during the build. Use this with
[shared project definitions](./project-definition.md) to keep production
independent of devenv. The existing `descriptorPath` argument remains supported.
