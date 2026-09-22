# Project definitions

A Project repository describes what the application needs in `project.nix`.
Development adds tools and processes in `devenv.nix`
([Project devenv](./project-devenv.md)); `flake.nix` builds the immutable
release ([Project runtime](./project-runtime.md)). Hosts bind secrets,
parameters, domains and placement.

## project.nix

```nix
{
  project = {
    name = "example";
    requirements = {
      data = { kind = "directory"; path = "data"; };
      apiKey.kind = "secret";                          # bound by the host
      session = { kind = "secret"; generate.bytes = 32; }; # generated per development instance
    };
    parameters.publicName = { description = "Title"; default = "Example"; };

    # Shared by every development and release action.
    environment = {
      DATA_DIR = { binding = "data"; field = "path"; };
      PUBLIC_NAME.parameter = "publicName";
    };
    development.environment.DEBUG = "1";

    release = {
      health.paths = [ "/healthz" ];
      environment.MODE = "production";                   # every release action
      serviceEnvironment.PORT = { endpoint = "web"; field = "listen.port"; };
      maintenanceJobs.sync = {
        schedule.interval = "1h";
        environment.API_KEY = { binding = "apiKey"; field = "value"; };
      };
    };
  };
}
```

Requirement kinds are `directory`, `secret` and `postgresql`. `realizations`
limits a requirement to `development` or `release`. A PostgreSQL requirement
takes `majorVersion`, `majorVersions`, or a `package` whose major version is
used.

An environment value is a literal string or one reference:
`{ binding; field; }` for a requirement, `{ endpoint; field; }` with `url`,
`protocol`, `hostNames`, `listen.host` or `listen.port`, `{ parameter; }`,
`{ path; append?; }` for `checkout`, `state`, `cache` or `runtime`, or
`{ instance = "id"; }`. Secret requirements expose `file` and `value`; read
secrets from files where the application allows it.

Environment attaches to where it is used. `environment` reaches everything,
`development.environment` every development process and task,
`release.environment` every release action, `release.serviceEnvironment` only
the long-running service, and `commands`, `maintenanceJobs` and
`preDeployTasks` their own action. An entry point needs the secrets its
environment references; they are added to its `secrets` list automatically.

Other release settings: `backend` (`service` or `static`), `action` (service
action name, default `web`), `activationExecutable`, `stateDirectories`,
`health`, `ingress` (compression, body limits, headers, redirects, cache
rules), `ociAuxiliaries` (digest-pinned containers), `preDeployTasks` with
`dependsOn`, `failureMode` and `timeoutSec`, and `commands` for
`project prod <command>`.

## flake.nix

```nix
outputs = { nixpkgs, nix-infra-modules, ... }:
  let
    project = nix-infra-modules.lib.projectFlake {
      inherit nixpkgs;
      modules = [ ./project.nix ];
      release = { pkgs, descriptor }:
        let
          src = nix-infra-modules.lib.projectSource { root = ./.; exclude = [ "docs" ]; };
          app = pkgs.callPackage ./nix/app.nix { inherit src; };
        in
        { payloads = [ app ]; actions.web = "${app}/bin/serve"; };
    };
  in
  project // { checks = /* merge further checks */ project.checks; };
```

`projectFlake` returns `lib.project`, `packages.<system>.projectRelease` and
checks that build it. `release` returns the arguments of `mkServiceRelease` or
`mkStaticRelease`, matching `release.backend`. `projectSource` drops Project,
devenv and CI files from the build source so editing them does not rebuild the
application. The shared CI workflow builds `projectRelease` and reads
`lib.project`.

## Normalized descriptor

`lib.projectDefinition { modules; }` evaluates the module and returns the
schema-v4 descriptor that hosts consume and release artifacts embed at
`share/project/descriptor.json`. `lib.projectDescriptor` exposes:

- `normalize { descriptor; expectedProject?; }` applies defaults and checks
  references, cycles, names and paths. Types are checked by the modules, so
  descriptors should come from them. Normalizing twice changes nothing.
- `resolveParameters { descriptor; values; allowUnknown?; }` type-checks host
  values against parameter definitions.
- `releaseApp { descriptor; policy; }` projects a normalized release and typed
  host policy into the `appDeployments` app settings. A bound secret
  requirement is satisfied by the credential of the same name.
- `forRealization` and `releaseTaskOrder` for host adapters.

Hosts reject a release whose topology (backend, action, executable, state
directories, ingress, auxiliaries) differs from the one they were compiled
for; see [Project runtime](./project-runtime.md#release-planning).
