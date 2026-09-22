# Project annotations for native devenv processes and tasks. Devenv owns the
# development graph; these options mark its public workloads, endpoints and
# commands and export the normalized contract consumed by managed hosts.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  projectTypes = import ../project/types.nix { inherit lib; };
  inherit (projectTypes) clean nullable;
  cfg = config.project;
  descriptorLib = import ../../lib/project-descriptor.nix { inherit lib; };
  requirements = cfg.declaration.requirements;
  releaseAction =
    if cfg.release == null || cfg.release.backend == "static" then
      null
    else if cfg.release.action == null then
      "web"
    else
      cfg.release.action;

  endpointType =
    { name, ... }:
    {
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
          # The endpoint serving the release action checks the same paths with the
          # same startup budget. Polling keeps development defaults.
          type = projectTypes.healthInheriting (
            if name == releaseAction && cfg.release.health != null then
              { inherit (cfg.release.health) paths startupTimeoutSec; }
            else
              { }
          );
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
        type = projectTypes.semanticName;
        default = "postgres";
      };
      user = mkOption {
        type = projectTypes.semanticName;
        default = "postgres";
      };
    };
  };
  # Managed hosts resolve the environment immediately before each action runs.
  exportEnvironment = action: ''
    if [[ "''${PROJECT_DEVENV_MANAGED:-}" == 1 ]]; then
      project_environment="$(project-context environment ${lib.escapeShellArg action})" || exit "$?"
      eval "$project_environment"
      unset project_environment
    fi
  '';
  withEnvironment =
    name: environment: value:
    lib.optionalString (cfg.enable && environment != { }) (exportEnvironment name) + value;
  sharedOptions = {
    environment = mkOption {
      type = projectTypes.environment;
      default = { };
    };
    secrets = mkOption {
      type = types.listOf projectTypes.semanticName;
      default = [ ];
      description = "Secrets needed beyond those referenced by the environment.";
    };
  };
  processMetadata =
    { config, name, ... }:
    {
      options.project = sharedOptions // {
        lifecycle = mkOption {
          type = types.enum [
            "on-demand"
            "background"
          ];
          default = "on-demand";
        };
        endpoints = mkOption {
          type = types.attrsOf (types.submodule endpointType);
          default = { };
        };
        provides = mkOption {
          type = types.attrsOf providerType;
          default = { };
        };
      };
      options.exec = mkOption {
        type = types.str;
        apply = withEnvironment name config.project.environment;
      };
    };
  taskMetadata =
    { config, name, ... }:
    {
      options.project = sharedOptions // {
        command = nullable projectTypes.name;
      };
      options.exec = mkOption {
        type = types.nullOr types.str;
        apply =
          value: if value == null then null else withEnvironment name config.project.environment value;
      };
    };

  common = clean (cfg.environment // cfg.development.environment);
  secretReferences =
    environment:
    lib.unique (
      lib.concatMap (
        value:
        lib.optional (
          builtins.isAttrs value
          && value ? binding
          && (requirements.${value.binding}.kind or null) == "secret"
        ) value.binding
      ) (builtins.attrValues environment)
    );
  commonSecrets = secretReferences common;
  secretsFor =
    item:
    lib.unique (
      commonSecrets ++ item.project.secrets ++ secretReferences (clean item.project.environment)
    );
  commandTasks = lib.filterAttrs (_: task: task.project.command != null) config.tasks;
  actionEnvironments = lib.filterAttrs (_: value: value != { }) (
    lib.mapAttrs (_: item: clean item.project.environment) (config.processes // config.tasks)
  );
  mergeUnique =
    context: sets:
    lib.foldl' (
      result: value:
      let
        duplicate = lib.intersectLists (lib.attrNames result) (lib.attrNames value);
      in
      if duplicate != [ ] then
        throw "project ${context}: duplicate names ${lib.concatStringsSep ", " duplicate}"
      else
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
                secrets = secretsFor process;
              }) config.processes;
              commands = mergeUnique "commands" (
                lib.mapAttrsToList (name: task: {
                  ${task.project.command} = {
                    action = name;
                    secrets = secretsFor task;
                  };
                }) commandTasks
              );
              endpoints = mergeUnique "endpoints" (
                lib.mapAttrsToList (
                  workload: process:
                  lib.mapAttrs (_: endpoint: clean endpoint // { inherit workload; }) process.project.endpoints
                ) config.processes
              );
              providers = mergeUnique "providers" (
                lib.mapAttrsToList (
                  workload: process:
                  lib.mapAttrs (
                    name: provider:
                    clean provider
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
                actions = actionEnvironments;
              };
            };
          };
        };
    project.contractFile = pkgs.writeText "project.json" (builtins.toJSON cfg.contract + "\n");
    enterShell = lib.mkIf (cfg.enable && common != { }) (lib.mkAfter (exportEnvironment ""));
  };
}
