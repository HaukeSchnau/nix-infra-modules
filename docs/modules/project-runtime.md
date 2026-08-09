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
descriptor. `activation` must be present exactly when the descriptor declares
`activationExecutable`. The service artifact contains the dispatcher, payloads,
optional activation wrapper, and the byte-for-byte repository descriptor at
`share/project/descriptor.json`.

Static Releases use `mkStaticRelease { descriptorPath; root; ...; }`. It combines
the site root with the same exact descriptor artifact and adds no service
runtime.

## Runtime context

Infrastructure supplies a versioned JSON manifest through
`PROJECT_RUNTIME_FILE` and Secret values through a credential directory. The
dispatcher validates Project identity and realization, creates allocated
directories, and exports:

- `PROJECT_CHECKOUT` for Development
- `PROJECT_STATE_DIR`, `PROJECT_CACHE_DIR`, and `PROJECT_RUNTIME_DIR`
- `PROJECT_SECRETS_DIR`
- `PROJECT_RUNTIME_QUERY`, the absolute `project-context` executable

Actions should not parse JSON directly. They use the stable query Interface:

```sh
port="$($PROJECT_RUNTIME_QUERY endpoint web listen-port)"
protocol="$($PROJECT_RUNTIME_QUERY endpoint web protocol)"
origin="$($PROJECT_RUNTIME_QUERY endpoint web url)"
hosts="$($PROJECT_RUNTIME_QUERY endpoint web host-names --json)"
mode="$($PROJECT_RUNTIME_QUERY parameter mode --default '"development"')"
token_file="$($PROJECT_RUNTIME_QUERY secret-file authToken --required)"
```

`project-context` also supports `path <name>`. It never prints Secret values;
`secret-file` returns only a validated path beneath the credential directory.
Local manifests do not claim descriptor Secrets are bound. Repository actions
may use an optional `secret-file` query and retain their ordinary local env-file
fallback; managed adapters bind and enforce required Secrets.

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
