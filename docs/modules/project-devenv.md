# Authoring a Project with devenv

Import `devenvModules.project`, or `modules/devenv/project.nix` from a pinned
non-flake devenv input. Native devenv owns packages, setup tasks, process
dependencies and readiness checks. Project annotations export the graph's public
workloads, commands, requirements and interfaces.

```nix
{ config, inputs, pkgs, ... }:
{
  imports = [ (inputs.projectSdk + "/modules/devenv/project.nix") ];
  packages = [ pkgs.postgresql_17 ];
  project = {
    enable = true;
    name = "example";
    requirements.database = {
      kind = "postgresql";
      package = pkgs.postgresql_17;
      dataDirectory = "postgres";
    };
    requirements.session = { kind = "secret"; generate.bytes = 32; };
    environment.DATABASE_URL = { binding = "database"; field = "url"; };
  };

  # Attach this metadata to the application's native PostgreSQL process.
  processes.database.project.provides.database = {};
  processes.web.project = {
    endpoints.web = { port = 3000; health.paths = [ "/health" ]; };
    environment = {
      PORT = { endpoint = "web"; field = "listen.port"; };
      SESSION_KEY = { binding = "session"; field = "value"; };
    };
  };
  tasks."example:console".project.command = "console";
}
```

The process executions and task dependencies above are supplied by the application's
existing devenv modules. Use `.project.lifecycle = "background"` to request a
process while the managed instance is active. A command annotation exposes a native
task without repeating its graph. Secret dependencies are inferred from development
environment references; explicit `.project.secrets` remains available.

`project.requirements.<name>.package` derives the PostgreSQL major version and the
native provider's actual version. Set `majorVersions = [16 17]` when the application
supports several host versions. The selected native package must belong to that set.

`project.release` declares the Release execution metadata. `project.releaseEnvironment`
provides its `common` and `actions` environment maps. Omitting Release exports a
development-only contract.

`config.project.contract` is the normalized JSON-compatible value, and
`config.project.contractFile` is its generated file. A host adapter can expose an
explicit export command and compare the committed `project.json` to this value
during preparation. Preparing a generation must not silently accept stale JSON.
Inspection and planning consume the exported JSON without evaluating repository Nix.

Managed execution sets `PROJECT_DEVENV_MANAGED=1`. The module then resolves common
environment values on shell entry and action values immediately before each process
or task. Ordinary local devenv keeps its native environment and resource lifecycle.
