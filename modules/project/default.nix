# Shared application requirements and release policy, independent of devenv.
# Evaluated by `lib.projectDefinition` for releases and imported by the devenv
# module for development; both produce the same normalized descriptor.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  projectTypes = import ./types.nix { inherit lib; };
  inherit (projectTypes) clean nullable;
  cfg = config.project;

  requirementType = types.submodule {
    options = {
      kind = mkOption {
        type = types.enum [
          "postgresql"
          "directory"
          "secret"
        ];
      };
      description = mkOption {
        type = types.str;
        default = "";
      };
      required = mkOption {
        type = types.bool;
        default = true;
      };
      realizations = mkOption {
        type = types.listOf (
          types.enum [
            "development"
            "release"
          ]
        );
        default = [
          "development"
          "release"
        ];
      };
      majorVersion = nullable types.ints.positive;
      majorVersions = nullable (types.listOf types.ints.positive);
      package = nullable types.package;
      dataDirectory = nullable types.str;
      path = nullable types.str;
      persistent = nullable types.bool;
      generate = nullable (
        types.submodule {
          options.bytes = mkOption {
            type = types.ints.between 16 1024;
            default = 32;
          };
        }
      );
    };
  };

  # A PostgreSQL package pins the declared major version unless a range is given.
  requirements = lib.mapAttrs (
    name: value:
    let
      declared = clean (builtins.removeAttrs value [ "package" ]);
      major =
        if value.package == null then null else lib.toInt (lib.versions.major value.package.version);
    in
    if value.package != null && value.kind != "postgresql" then
      throw "project.requirements.${name}: package is only supported for postgresql"
    else if major == null then
      declared
    else if
      (value.majorVersion != null && value.majorVersion != major)
      || (value.majorVersions != null && !(builtins.elem major value.majorVersions))
    then
      throw "project.requirements.${name}: the PostgreSQL package must satisfy majorVersion"
    else
      declared // lib.optionalAttrs (value.majorVersions == null) { majorVersion = major; }
  ) cfg.requirements;

  # Secret requirements referenced by an environment map. Actions need them
  # bound, so they never have to be listed separately.
  secretReferences =
    environment:
    lib.unique (
      lib.concatMap (
        value:
        lib.optional (
          builtins.isAttrs value
          && value ? binding
          && (cfg.requirements.${value.binding}.kind or null) == "secret"
        ) value.binding
      ) (builtins.attrValues environment)
    );

  release = cfg.release;
  releaseCommon = clean (cfg.environment // release.environment);
  # Every release entry point with its own environment, keyed by action name.
  releaseEntryPoints =
    lib.optional (release.backend != "static") {
      action = if release.action == null then "web" else release.action;
      environment = release.serviceEnvironment;
    }
    ++
      lib.concatMap
        (
          group:
          lib.mapAttrsToList (name: entry: {
            action = if entry.action == null then name else entry.action;
            inherit (entry) environment;
          }) release.${group}
        )
        [
          "commands"
          "maintenanceJobs"
          "preDeployTasks"
        ];
  releaseActions = lib.foldl' (
    result: entry:
    let
      environment = clean entry.environment;
    in
    if environment == { } then
      result
    else if result ? ${entry.action} && result.${entry.action} != environment then
      throw "project.release: action ${entry.action} is declared with two different environments"
    else
      result // { ${entry.action} = environment; }
  ) { } releaseEntryPoints;
  withSecrets =
    entries:
    lib.mapAttrs (
      name: entry:
      let
        action = if entry.action == null then name else entry.action;
        explicit = if entry.secrets == null then [ ] else entry.secrets;
        inferred = secretReferences (releaseCommon // (releaseActions.${action} or { }));
        secrets = lib.unique (explicit ++ inferred);
      in
      clean (builtins.removeAttrs entry [ "environment" ])
      // lib.optionalAttrs (secrets != [ ]) { inherit secrets; }
    ) entries;
  releaseDeclaration =
    clean (
      builtins.removeAttrs release [
        "environment"
        "serviceEnvironment"
      ]
    )
    // {
      commands = withSecrets release.commands;
      maintenanceJobs = withSecrets release.maintenanceJobs;
      preDeployTasks = withSecrets release.preDeployTasks;
    };
in
{
  options.project = {
    name = nullable projectTypes.name;
    requirements = mkOption {
      type = types.attrsOf requirementType;
      default = { };
    };
    parameters = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            type = mkOption {
              type = types.enum [
                "string"
                "integer"
                "number"
                "boolean"
              ];
              default = "string";
            };
            description = mkOption {
              type = types.str;
              default = "";
            };
            required = nullable types.bool;
            default = nullable (
              types.oneOf [
                types.str
                types.int
                types.float
                types.bool
              ]
            );
          };
        }
      );
      default = { };
    };
    environment = mkOption {
      type = projectTypes.environment;
      default = { };
      description = "Environment shared by every development and release action.";
    };
    development.environment = mkOption {
      type = projectTypes.environment;
      default = { };
      description = "Additional environment for every development process and task.";
    };
    release = nullable (import ./release-type.nix { inherit lib; });
    declaration = mkOption {
      type = types.attrs;
      readOnly = true;
      internal = true;
    };
  };

  config.project.declaration = {
    schemaVersion = 4;
    project = cfg.name;
    inherit requirements;
    parameters = lib.mapAttrs (_: clean) cfg.parameters;
    release = if release == null then null else releaseDeclaration;
    environment = lib.optionalAttrs (release != null) {
      release = {
        common = releaseCommon;
        actions = releaseActions;
      };
    };
  };
}
