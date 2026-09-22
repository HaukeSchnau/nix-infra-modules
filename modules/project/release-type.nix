# Release settings authored in project.nix. Unset values take the defaults
# applied by the descriptor normalizer.
{ lib }:
let
  inherit (lib) mkOption types;
  projectTypes = import ./types.nix { inherit lib; };
  inherit (projectTypes) nullable;
  object = options: types.submodule { inherit options; };
  strings = types.listOf types.str;
  named =
    options:
    mkOption {
      type = types.attrsOf (object options);
      default = { };
    };
  # Commands, jobs and pre-deploy tasks run one action each. Secrets referenced
  # by their environment are added to `secrets` automatically.
  entryPoint = {
    action = nullable types.str;
    secrets = nullable strings;
    environment = mkOption {
      type = projectTypes.environment;
      default = { };
    };
  };
in
object {
  backend = nullable (
    types.enum [
      "static"
      "service"
    ]
  );
  action = nullable types.str;
  package = nullable types.str;
  executable = nullable types.str;
  activationExecutable = nullable types.str;
  stateDirectories = nullable strings;
  health = nullable projectTypes.health;
  environment = mkOption {
    type = projectTypes.environment;
    default = { };
    description = "Additional environment for every release action.";
  };
  serviceEnvironment = mkOption {
    type = projectTypes.environment;
    default = { };
    description = "Additional environment for the long-running service action only.";
  };
  commands = named entryPoint;
  preDeployTasks = named (
    entryPoint
    // {
      dependsOn = nullable strings;
      failureMode = nullable (
        types.enum [
          "fail"
          "defer"
        ]
      );
      timeoutSec = nullable types.ints.positive;
    }
  );
  maintenanceJobs = named (
    entryPoint
    // {
      schedule = nullable (object {
        calendar = nullable types.str;
        interval = nullable types.str;
        cadence = nullable (
          types.enum [
            "fixed"
            "spaced"
          ]
        );
      });
    }
  );
  ociAuxiliaries = named {
    image = mkOption { type = types.strMatching "^.+@sha256:[0-9a-fA-F]{64}$"; };
    command = nullable strings;
    ports = named {
      containerPort = mkOption { type = types.port; };
      protocol = nullable (
        types.enum [
          "tcp"
          "udp"
        ]
      );
    };
  };
  ingress = nullable (object {
    compression = nullable types.bool;
    requestBodyMaxBytes = nullable types.ints.positive;
    streamCloseDelaySec = nullable types.ints.positive;
    responseHeaders = nullable (types.attrsOf types.str);
    redirects = nullable (
      types.listOf (object {
        from = mkOption { type = types.str; };
        to = mkOption { type = types.str; };
        permanent = nullable types.bool;
        status = nullable (
          types.enum [
            301
            302
            307
            308
          ]
        );
      })
    );
    cacheRules = nullable (
      types.listOf (object {
        paths = mkOption { type = strings; };
        value = mkOption { type = types.str; };
      })
    );
  });
}
