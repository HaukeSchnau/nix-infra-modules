{ lib }:
let
  inherit (lib) mkOption types;
  optional =
    type:
    mkOption {
      type = types.nullOr type;
      default = null;
    };
  object = options: types.submodule { inherit options; };
  strings = types.listOf types.str;
  health = object {
    paths = optional strings;
    startupTimeoutSec = optional types.ints.positive;
    intervalSec = optional types.ints.positive;
    requestTimeoutSec = optional types.ints.positive;
  };
  command = {
    action = optional types.str;
    secrets = optional strings;
  };
in
object {
  backend = optional (
    types.enum [
      "static"
      "service"
    ]
  );
  action = optional types.str;
  package = optional types.str;
  executable = optional types.str;
  activationExecutable = optional types.str;
  stateDirectories = optional strings;
  health = optional health;
  commands = optional (types.attrsOf (object command));
  preDeployTasks = optional (
    types.attrsOf (
      object (
        command
        // {
          dependsOn = optional strings;
          failureMode = optional (
            types.enum [
              "fail"
              "defer"
            ]
          );
          timeoutSec = optional types.ints.positive;
        }
      )
    )
  );
  maintenanceJobs = optional (
    types.attrsOf (
      object (
        command
        // {
          schedule = optional (object {
            calendar = optional types.str;
            interval = optional types.str;
            cadence = optional (
              types.enum [
                "fixed"
                "spaced"
              ]
            );
          });
        }
      )
    )
  );
  ociAuxiliaries = optional (
    types.attrsOf (object {
      image = mkOption { type = types.strMatching "^.+@sha256:[0-9a-fA-F]{64}$"; };
      command = optional strings;
      ports = optional (
        types.attrsOf (object {
          containerPort = mkOption { type = types.port; };
          protocol = optional (
            types.enum [
              "tcp"
              "udp"
            ]
          );
        })
      );
    })
  );
  ingress = optional (object {
    compression = optional types.bool;
    requestBodyMaxBytes = optional types.ints.positive;
    streamCloseDelaySec = optional types.ints.positive;
    responseHeaders = optional (types.attrsOf types.str);
    redirects = optional (
      types.listOf (object {
        from = mkOption { type = types.str; };
        to = mkOption { type = types.str; };
        permanent = optional types.bool;
        status = optional (
          types.enum [
            301
            302
            307
            308
          ]
        );
      })
    );
    cacheRules = optional (
      types.listOf (object {
        paths = mkOption { type = strings; };
        value = mkOption { type = types.str; };
      })
    );
  });
}
