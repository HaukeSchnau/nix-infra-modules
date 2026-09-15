# Shared project definitions

Author application requirements and release policy in a repository-root
`project.nix`. Development and release builds import it independently. JSON is
an evaluated artifact, not a file authors must export and commit.

```nix
# project.nix
{
  project = {
    name = "example";
    requirements.data = {
      kind = "directory";
      path = "data";
      persistent = true;
    };
    release.health.paths = [ "/healthz" ];
  };
}
```

The shared module has typed requirements, parameters, environment references,
and release settings. Normalization also checks references, task cycles and
other relationships. Secret values and concrete host bindings remain outside
these definitions.

## Development

Import the shared file alongside the SDK's devenv annotations:

```nix
{ inputs, ... }:
{
  imports = [
    (inputs.projectSdk + "/modules/devenv/project.nix")
    ./project.nix
  ];
  project.enable = true;
  processes.web = {
    exec = "my-server";
    project.endpoints.web.port = 3000;
  };
}
```

Devenv exports `config.project.contract` and `config.project.contractFile` after
combining shared requirements with native tasks and processes. Prepared hosts
consume that generated metadata directly. Refresh the prepared generation after
configuration changes; normal request wakeups continue using that generation
without evaluating mutable Nix files.

`project.environment` supplies development environment mappings;
`project.releaseEnvironment.common` supplies release mappings. Define common
mappings once in a `let` binding and assign them to both when they are identical.
Action-specific mappings belong under the respective realization.

## Production

A flake evaluates the shared definition without importing devenv:

```nix
projectDescriptor = nix-infra-modules.lib.projectDefinition {
  modules = [ ./project.nix ];
};
```

Expose this value as `lib.project` for release tooling. It is a schema-v4
release descriptor with `development = null`. The development descriptor is
generated separately from the native process definitions; production does not
need the development toolchain or its lock file to evaluate shared metadata.

Pass `descriptor = projectDescriptor` to `lib.projectRuntime.mkServiceRelease`
or `mkStaticRelease`. The helpers serialize and embed it in
`share/project/descriptor.json` during the build. They do not read generated
JSON during Nix evaluation. Existing `descriptorPath` callers remain supported
while repositories migrate.

`projectModules.default` exports the underlying module for other Nix module
consumers. `lib.projectDefinition` also accepts `specialArgs` when imported
modules need explicit dependencies.
