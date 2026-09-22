# Authoring a Project with devenv

Native devenv owns development tools, setup tasks, processes, dependencies and
readiness. The Project annotations mark which processes and tasks are public
and export the normalized contract a managed host runs.

```nix
{ inputs, pkgs, ... }:
{
  imports = [
    (inputs.projectSdk + "/modules/devenv/project.nix")
    ./project.nix
  ];
  project.enable = true;
  project.requirements.database.package = pkgs.postgresql_17;

  processes.database = {
    exec = "postgres -D \"$PGDATA\"";
    project.provides.database = { };
  };
  processes.web = {
    exec = "my-server";
    after = [ "devenv:processes:database" ];
    project.endpoints.web.port = 3000;
  };
  processes.worker.project.lifecycle = "background";
  tasks."example:console" = {
    exec = "my-console";
    project.command = "console";
  };
}
```

Pin the SDK in `devenv.yaml` to a full commit SHA with `flake: false`.

- `processes.<name>.project.endpoints.<name>` publishes a listener. `port` is
  the default for plain `devenv up`; managed hosts assign their own. The
  endpoint serving the release action (`web` by default) inherits `paths` and
  `startupTimeoutSec` from `release.health`; set `health` to override fields.
  `publication = "private"` keeps an endpoint off the network.
- `lifecycle = "background"` runs a process whenever the instance is active.
- `provides.<requirement>` marks the native PostgreSQL process for a
  requirement. The host allocates its port and data directory.
- `tasks.<name>.project.command` exposes the task as `project dev <command>`.
- `project.environment` on a process or task adds action-specific variables.
  Secrets referenced by any environment the action sees are inferred;
  `project.secrets` adds more.

Do not repeat dependencies or startup commands in `project.nix`; the graph
lives in devenv only.

`config.project.contract` is the normalized descriptor with development and
release; `config.project.contractFile` is the same as JSON. Managed execution
sets `PROJECT_DEVENV_MANAGED=1`, and the annotated processes and tasks then
resolve their environment with `project-context environment <action>` before
they start. Plain local devenv keeps its own environment, so process scripts
should default variables the host would otherwise supply.
