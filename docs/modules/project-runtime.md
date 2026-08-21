# Project Runtime

`lib.projectRuntime` is the deep Interface between a repository-owned Project
and its Development or Release Adapter. It owns the versioned Runtime manifest,
validation, action dispatch, local allocation and supervision, Preparation
locking, conventional flake apps, and exact descriptor embedding. Repository
actions remain opaque executables, so Bun, pnpm, Expo, Vite, databases, and
application-specific environment variables never enter infrastructure.

## Development

```nix
runtime = inputs.nix-infra-modules.lib.projectRuntime.mkDevelopment {
  inherit pkgs;
  descriptorPath = ./project.json;
  actions = {
    prepare = lib.getExe prepareAction;
    web = lib.getExe webAction;
    mobile = lib.getExe mobileAction;
  };
};

packages.projectRuntime = runtime.package;
apps = runtime.apps;
checks = runtime.checks;
```

Action names must exactly match the normalized Preparation and Workload actions.
The constructor returns `prepare`, `dev`, and one `dev-<workload>` app. Local
Development allocates stable, distinct loopback listeners per physical Checkout
without putting ports in repository configuration. Infrastructure invokes the
pinned `package` against any mutable Checkout; that path never evaluates the
mutable flake.

The generated dispatcher serializes Preparation by physical Checkout. The same
lock covers canonical Checkouts, ad-hoc git worktrees, jj workspaces, and local
flake apps.

Development keeps the Python controller because it owns port allocation,
locking, and multi-process supervision. Development packages are tooling and
do not enter a production Release closure.

`dev --only <workload>` retains dependency-recursive local behavior. Managed
infrastructure uses `project-runtime workload <name>` to execute exactly one
Workload while it realizes the repository-declared dependency graph itself.
This prevents independently activated Endpoints from starting duplicate copies
of a shared dependency.

## Release

```nix
release = inputs.nix-infra-modules.lib.projectRuntime.mkServiceRelease {
  inherit pkgs;
  descriptorPath = ./project.json;
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
descriptor. Schema v2 pre-deploy task actions must also have implementations.
`activation` must be present exactly when the descriptor declares
`activationExecutable`. The service artifact contains the dispatcher, payloads,
optional activation wrapper, and the byte-for-byte repository descriptor at
`share/project/descriptor.json`.

Service Releases use a small statically linked Go dispatcher. The Go compiler
is only a build input, and neither Go nor Python enters the Release closure.
The compiled dispatcher implements the same Runtime manifest validation,
`project-context` queries, action selection, and failure statuses as the
Development controller.

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
token_file="$(project-context secret-file authToken --required)"
```

`project-context` also supports `path <name>`. It never prints Secret values;
`secret-file` returns only a validated path beneath the credential directory.
Local manifests do not claim descriptor Secrets are bound. Repository actions
may use an optional `secret-file` query and retain their ordinary local env-file
fallback; managed adapters bind and enforce required Secrets.

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
compatibility, context queries, dispatch, generic local lifecycle, and artifact
identity. It does not infer application environment variables or package-manager
commands.

## Rolling compatibility and errors

Schemas live below `schemas/project-descriptor/` and `schemas/project-runtime/`.
A numbered schema is immutable. Descriptor v1 and runtime v1 remain supported;
new Projects use paired descriptor v2 and runtime v2. New producers emit
canonical `parameters`; runtime v1 consumers accept legacy `settings` only when
`parameters` is absent. Actions depend on `project-context`, not the JSON layout,
and the dispatcher normalizes both runtime versions behind that Interface.

Runtime failures use stable statuses: 64 for invocation/action errors, 65 for
invalid manifests or identity, 66 for unavailable or unsafe allocations and
credentials, and 69 when an Adapter cannot execute or a listener cannot be
allocated.
