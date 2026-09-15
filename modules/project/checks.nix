{ lib, pkgs, ... }:
let
  evaluate = import ../../lib/project-definition.nix { inherit lib; };
  shared = {
    project = {
      name = "definition-fixture";
      requirements = {
        data = {
          kind = "directory";
          path = "data";
          persistent = true;
        };
        passcode.kind = "secret";
      };
      release = {
        health.paths = [ "/healthz" ];
        ingress.compression = true;
      };
      releaseEnvironment.common.PASSCODE_FILE = {
        binding = "passcode";
        field = "file";
      };
    };
  };
  release = evaluate { modules = [ shared ]; };
  valid =
    module:
    (builtins.tryEval (
      builtins.deepSeq (evaluate {
        modules = [
          shared
          module
        ];
      }) true
    )).success;
  native =
    (lib.evalModules {
      modules = [
        ../devenv/project.nix
        shared
        {
          options.enterShell = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
          config = {
            project.enable = true;
            processes.web = {
              exec = "true";
              project.endpoints.web.port = 8080;
            };
          };
        }
      ];
    }).config.project.contract;
in
{
  project-definition =
    assert release.development == null;
    assert native.development.endpoints.web.port == 8080;
    assert native.release == release.release;
    assert native.requirements == release.requirements;
    assert !(valid { project.release.health.startupTimeoutSec = 0; });
    assert !(valid { project.release.ingress.compresson = true; });
    assert
      !(valid {
        project.releaseEnvironment.common.BROKEN = {
          binding = "missing";
          field = "file";
        };
      });
    assert
      !(valid {
        project.release.preDeployTasks = {
          a.dependsOn = [ "b" ];
          b.dependsOn = [ "a" ];
        };
      });
    pkgs.runCommand "project-definition-check" { } ''
      touch "$out"
    '';
}
