# Authoring semantics of project.nix and the devenv annotations.
{ lib, pkgs, ... }:
let
  descriptorLib = import ../../lib/project-descriptor.nix { inherit lib; };
  evaluate = import ../../lib/project-definition.nix { inherit lib; };
  shared = {
    project = {
      name = "definition-fixture";
      requirements = {
        data = {
          kind = "directory";
          path = "data";
        };
        passcode.kind = "secret";
        token = {
          kind = "secret";
          realizations = [ "release" ];
        };
      };
      environment.DATA_DIR = {
        binding = "data";
        field = "path";
      };
      release = {
        health = {
          paths = [ "/healthz" ];
          startupTimeoutSec = 30;
        };
        ingress.compression = true;
        environment.PASSCODE_FILE = {
          binding = "passcode";
          field = "file";
        };
        maintenanceJobs.sync = {
          schedule.interval = "1h";
          environment.TOKEN = {
            binding = "token";
            field = "value";
          };
        };
      };
    };
  };
  release = evaluate { modules = [ shared ]; };
  fails =
    module:
    !(builtins.tryEval (
      builtins.deepSeq (evaluate {
        modules = [
          shared
          module
        ];
      }) true
    )).success;
  stubOptions = {
    options.enterShell = lib.mkOption {
      type = lib.types.lines;
      default = "";
    };
  };
  native =
    (lib.evalModules {
      modules = [
        ../devenv/project.nix
        shared
        stubOptions
        {
          _module.args.pkgs = pkgs;
          project.enable = true;
          project.development.environment.DEBUG = "1";
          processes.web = {
            exec = "true";
            project.endpoints.web.port = 8080;
          };
        }
      ];
    }).config.project.contract;
in
{
  project-definition =
    assert release.development == null;
    # Normalizing a normalized descriptor changes nothing.
    assert descriptorLib.normalize { descriptor = release; } == release;
    # Shared environment reaches both realizations; development adds its own.
    assert
      release.environment.release.common ? DATA_DIR && release.environment.release.common ? PASSCODE_FILE;
    assert
      native.environment.development.common ? DATA_DIR && native.environment.development.common ? DEBUG;
    assert !(native.environment.development.common ? PASSCODE_FILE);
    # Secrets referenced by an entry point's environment are bound for it.
    assert
      release.release.maintenanceJobs.sync.secrets == [
        "passcode"
        "token"
      ];
    assert release.environment.release.actions.sync ? TOKEN;
    # The release action's development endpoint checks the release health paths.
    assert native.development.endpoints.web.health.paths == [ "/healthz" ];
    assert native.development.endpoints.web.health.startupTimeoutSec == 30;
    assert native.development.endpoints.web.health.intervalSec == 1;
    assert native.development.endpoints.web.port == 8080;
    assert native.release == release.release;
    assert native.requirements == release.requirements;
    assert fails { project.release.health.startupTimeoutSec = 0; };
    assert fails { project.release.ingress.compresson = true; };
    assert fails {
      project.release.environment.BROKEN = {
        binding = "missing";
        field = "file";
      };
    };
    assert fails { project.environment.BROKEN.secret = "passcode"; };
    assert fails {
      project.release.preDeployTasks = {
        a.dependsOn = [ "b" ];
        b.dependsOn = [ "a" ];
      };
    };
    assert fails {
      project.release = {
        backend = "static";
        commands.console = { };
      };
    };
    pkgs.runCommand "project-definition-check" { } ''
      touch "$out"
    '';
}
