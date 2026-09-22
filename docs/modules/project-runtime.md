# Project runtime

`lib.projectRuntime` builds release artifacts around one statically linked Go
binary, `lib.projectRuntime.package pkgs`. The same binary runs release
actions, answers `project-context` queries for release and development
instances, and plans release compatibility on hosts. Neither Go nor Python
enters a release closure.

## Release artifacts

Use [`lib.projectFlake`](./project-definition.md#flakenix), or call the
builders directly with the descriptor from `lib.projectDefinition`:

```nix
mkServiceRelease {
  inherit pkgs descriptor;
  payloads = [ application ];
  actions = { web = serve; backup = backup; };
  activation = activate; # only with release.activationExecutable
}
mkStaticRelease { inherit pkgs descriptor; root = site; }
```

`actions` must implement exactly the service action, pre-deploy tasks,
maintenance jobs and commands the descriptor declares. The artifact contains
the payloads, a `bin/<executable>` dispatcher, `bin/project-context`, and the
descriptor at `share/project/descriptor.json`.

`developmentContext { pkgs; descriptor; }` builds a `project-context` for
development instances; managed hosts put it on the path of every process.

## Runtime context

Hosts write a runtime manifest (schema 3) and point `PROJECT_RUNTIME_FILE` at
it, with credential files in `PROJECT_SECRETS_DIR`. Applications never read
either; they ask `project-context`:

```sh
project-context path state            # checkout, state, cache, runtime
project-context endpoint web url      # url, protocol, listen-host, listen-port, host-names
project-context auxiliary cache redis listen-port
project-context parameter mode --default '"dev"'
project-context binding database url
project-context secret-file apiKey --required
project-context environment web       # shell exports for an action's environment
project-context revision              # status 1 without an immutable revision
project-context instance-id
project-context snapshot              # JSON summary, never secret values
```

The manifest carries the instance ID, paths, endpoints, parameters, secret
credential names and requirement bindings. The runtime validates it against
the descriptor: undeclared endpoints, parameters or secrets, missing required
bindings, a PostgreSQL major version outside the requirement, or a directory
with the wrong persistence all fail. Development manifests must also provide
`checkout` and `cache` paths. HTTP endpoints carry a URL and optional host
names; TCP endpoints carry only their listener, so applications build their
own connection strings.

Exit statuses: 64 usage, 65 invalid manifest or identity, 66 unavailable or
unsafe allocation or credential, 69 action could not execute.

## Release planning

`project-runtime plan-release --host POLICY --candidate DESCRIPTOR` decides
whether a candidate artifact fits the host. The policy is the host's pinned
descriptor with its parameter, secret and resource bindings. The candidate
must keep the release topology (backend, action, executable, state
directories, ingress, auxiliaries; plus activation for static releases),
satisfy every required parameter, secret and resource binding, declare the
maintenance jobs the host schedules, and have acyclic pre-deploy tasks. The
output lists the reasons it is incompatible and the release plan: health,
commands, jobs, pre-deploy tasks in execution order, and the activation
executable. Extra host bindings are allowed, so infrastructure can land before
the application uses it.

## Ownership

The repository owns the descriptor and its executables. Hosts own listeners,
URLs, host names, visibility, absolute paths, secret values, schedules,
resources and placement. The runtime owns only the manifest, its validation,
context queries and dispatch; it never infers application variables.
