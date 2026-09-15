{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.project;
  descriptorLib = import ../../lib/project-descriptor.nix { inherit lib; };
  omitNull = lib.filterAttrs (_: value: value != null);
  semanticName = types.strMatching "^[A-Za-z0-9_.-]+$";
  nullable =
    type:
    mkOption {
      type = types.nullOr type;
      default = null;
    };
  environmentType = types.attrsOf (
    types.either types.str (
      types.submodule {
        options = {
          binding = nullable semanticName;
          endpoint = nullable semanticName;
          parameter = nullable semanticName;
          secret = nullable semanticName;
          path = nullable (
            types.enum [
              "checkout"
              "state"
              "cache"
              "runtime"
            ]
          );
          instance = nullable (types.enum [ "id" ]);
          field = nullable types.str;
          append = nullable types.str;
        };
      }
    )
  );
  environment = lib.mapAttrs (_: value: if builtins.isAttrs value then omitNull value else value);
  environmentOption = mkOption {
    type = environmentType;
    default = { };
  };
  requirements = cfg.declaration.requirements;
  endpointType = types.submodule {
    options = {
      protocol = mkOption {
        type = types.enum [
          "http"
          "tcp"
        ];
        default = "http";
      };
      port = nullable types.port;
      publication = mkOption {
        type = types.enum [
          "private"
          "preview"
        ];
        default = "preview";
      };
      health = mkOption {
        type = types.attrs;
        default = { };
      };
    };
  };
  providerType = types.submodule {
    options = {
      majorVersion = nullable types.ints.positive;
      port = mkOption {
        type = types.port;
        default = 5432;
      };
      database = mkOption {
        type = semanticName;
        default = "postgres";
      };
      user = mkOption {
        type = semanticName;
        default = "postgres";
      };
    };
  };
  exportEnvironment = action: ''
    if [[ "''${PROJECT_DEVENV_MANAGED:-}" == 1 ]]; then
      project_environment="$(project-context environment ${lib.escapeShellArg action})" || exit "$?"
      eval "$project_environment"
      unset project_environment
    fi
  '';
  processMetadata = { config, name, ... }: {
    options.project = {
      lifecycle = mkOption {
        type = types.enum [
          "on-demand"
          "background"
        ];
        default = "on-demand";
      };
      endpoints = mkOption {
        type = types.attrsOf endpointType;
        default = { };
      };
      provides = mkOption {
        type = types.attrsOf providerType;
        default = { };
      };
      environment = environmentOption;
      secrets = mkOption {
        type = types.listOf semanticName;
        default = [ ];
      };
    };
    options.exec = mkOption {
      type = types.str;
      apply =
        value:
        lib.optionalString (cfg.enable && config.project.environment != { }) (exportEnvironment name)
        + value;
    };
  };
  taskMetadata = { config, name, ... }: {
    options.project = {
      command = nullable (types.strMatching "^[a-z0-9][a-z0-9-]{0,62}$");
      environment = environmentOption;
      secrets = mkOption {
        type = types.listOf semanticName;
        default = [ ];
      };
    };
    options.exec = mkOption {
      type = types.nullOr types.str;
      apply =
        value:
        if value == null then
          null
        else
          lib.optionalString (cfg.enable && config.project.environment != { }) (exportEnvironment name)
          + value;
    };
  };
  commandTasks = lib.filterAttrs (_: task: task.project.command != null) config.tasks;
  common = environment cfg.environment;
  secretReferences =
    values:
    lib.unique (
      lib.concatMap (
        value:
        if !builtins.isAttrs value then
          [ ]
        else if value ? secret then
          [ value.secret ]
        else if value ? binding && requirements.${value.binding}.kind or null == "secret" then
          [ value.binding ]
        else
          [ ]
      ) (lib.attrValues values)
    );
  commonSecrets = secretReferences common;
  processEnvironment = lib.mapAttrs (
    _: process: environment process.project.environment
  ) config.processes;
  taskEnvironment = lib.mapAttrs (_: task: environment task.project.environment) (
    lib.filterAttrs (_: task: task.project.environment != { }) config.tasks
  );
  mergeUnique =
    context: sets:
    lib.foldl' (
      result: value:
      let
        duplicate = lib.intersectLists (lib.attrNames result) (lib.attrNames value);
      in
      assert lib.assertMsg (
        duplicate == [ ]
      ) "project ${context}: duplicate names ${lib.concatStringsSep ", " duplicate}";
      result // value
    ) { } sets;
in
{
  imports = [ ../project ];
  options = {
    project = {
      enable = lib.mkEnableOption "exporting a Project contract from native devenv processes and tasks";
      contract = mkOption {
        type = types.attrs;
        readOnly = true;
        internal = true;
      };
      contractFile = mkOption {
        type = types.package;
        readOnly = true;
        internal = true;
      };
    };
    processes = mkOption { type = types.attrsOf (types.submodule processMetadata); };
    tasks = mkOption { type = types.attrsOf (types.submodule taskMetadata); };
  };

  config = {
    project.contract =
      if !cfg.enable then
        { }
      else
        descriptorLib.normalize {
          descriptor = cfg.declaration // {
            development = {
              preparation.secrets = commonSecrets;
              workloads = lib.mapAttrs (name: process: {
                action = name;
                inherit (process.project) lifecycle;
                secrets = lib.unique (
                  commonSecrets ++ process.project.secrets ++ secretReferences processEnvironment.${name}
                );
              }) config.processes;
              commands = mergeUnique "commands" (
                lib.mapAttrsToList (name: task: {
                  ${task.project.command} = {
                    action = name;
                    secrets = lib.unique (
                      commonSecrets ++ task.project.secrets ++ secretReferences (environment task.project.environment)
                    );
                  };
                }) commandTasks
              );
              endpoints = mergeUnique "endpoints" (
                lib.mapAttrsToList (
                  workload: process:
                  lib.mapAttrs (_: endpoint: endpoint // { inherit workload; }) process.project.endpoints
                ) config.processes
              );
              providers = mergeUnique "providers" (
                lib.mapAttrsToList (
                  workload: process:
                  lib.mapAttrs (
                    name: provider:
                    omitNull provider
                    // {
                      inherit workload;
                    }
                    // lib.optionalAttrs (provider.majorVersion == null && cfg.requirements.${name}.package != null) {
                      majorVersion = lib.toInt (lib.versions.major cfg.requirements.${name}.package.version);
                    }
                  ) process.project.provides
                ) config.processes
              );
            };
            environment = cfg.declaration.environment // {
              development = {
                inherit common;
                actions = lib.filterAttrs (_: value: value != { }) (processEnvironment // taskEnvironment);
              };
            };
          };
        };
    project.contractFile = pkgs.writeText "project.json" (builtins.toJSON cfg.contract + "\n");
    enterShell = lib.mkIf (cfg.enable && common != { }) (lib.mkAfter (exportEnvironment ""));
  };
}
