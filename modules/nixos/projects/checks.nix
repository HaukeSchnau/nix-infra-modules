# The projects host module: controller tests and a release-only placement.
{
  lib,
  pkgs,
  self,
  system,
  ...
}:
let
  mkFleetSystem = import ../../../checks/mk-fleet-system.nix { inherit lib self system; };
  descriptor = self.lib.projectDefinition {
    modules = [
      {
        project = {
          name = "demo";
          requirements.token.kind = "secret";
          release.health.paths = [ "/healthz" ];
        };
      }
    ];
  };
  # A development-only Project without devenv.nix: its contract comes from
  # the flake and it has no pinned bundle until its first refresh.
  developmentDescriptor = self.lib.projectDescriptor.normalize {
    descriptor = {
      schemaVersion = 4;
      project = "tool";
      development = {
        workloads.web = { };
        endpoints.web = { };
      };
    };
  };
  host = mkFleetSystem "projects-01" [
    self.nixosModules.projects
    {
      vps.services.projects = {
        defaultOwner = "demo";
        # Only the bundle builder's paths are needed; nothing builds a bundle here.
        devenv = {
          outPath = pkgs.emptyDirectory;
          packages.${system} = {
            devenv = pkgs.hello // {
              version = "2.3.1";
            };
            devenv-tasks = pkgs.hello;
          };
        };
        releaseCacheStore = "https://cache.example.net";
        repositoryRemotes.forge = {
          checkoutUrlPrefix = "git@forge.example.net:";
          releaseUrlPrefix = "git+https://forge.example.net/";
        };
      };
      vps.appDeployments.webhook.enable = false;
      projects.demo = {
        source = {
          outPath = pkgs.emptyDirectory;
          lib.project = descriptor;
        };
        repository = {
          remote = "forge";
          path = "team/demo.git";
        };
        development = null;
        release = {
          delivery.mode = "cache";
          endpoint.aliases = [ "demo-old.example.net" ];
          secrets.token.path = "/run/credentials/demo-token";
        };
      };
      users.users.demo = {
        isNormalUser = true;
        uid = 1000;
      };
      projects.tool = {
        source = {
          outPath = pkgs.emptyDirectory;
          lib.project = developmentDescriptor;
        };
        repository = {
          remote = "forge";
          path = "team/tool.git";
        };
        development.parameters = { };
        release = null;
      };
    }
  ];
  release = host.config.vps.services.projects.resolvedReleases.demo;
  app = host.config.vps.services.appDeployments.apps.demo;
in
{
  project-controller = pkgs.callPackage ./controller/package.nix { };
  projects-module =
    assert release.hostName == "demo.example.net";
    assert release.aliases == [ "demo-old.example.net" ];
    assert
      release.bindings.token == {
        kind = "secret";
        credential = "token";
      };
    assert app.delivery.cacheStore == "https://cache.example.net";
    assert host.config.vps.services.caddy.virtualHosts ? "demo-old.example.net";
    pkgs.runCommand "projects-module-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
      jq -e '
        .schemaVersion == 2
        and .developmentDomain == "dev.example.net"
        and .projects.tool.repository.checkout == "/home/demo/Code/tool"
        and .projects.tool.pinnedBundle == null
        and (has("workspaceLauncher") | not)
      ' ${host.config.environment.etc."projects/catalog-demo.json".source} >/dev/null
      touch "$out"
    '';
  projects-devenv-yaml =
    let
      read = import ./devenv-yaml.nix { inherit lib; };
      rejects = text: !(builtins.tryEval (builtins.deepSeq (read text) null)).success;
    in
    assert
      read ''
        # yaml-language-server: $schema=https://devenv.sh/devenv.schema.json
        inputs:
          projectSdk:
            url: github:owner/sdk/0123abc
            flake: false

          # Indentation only has to be consistent within one block.
          nixpkgs:
              url: github:NixOS/nixpkgs/4567def?dir=pkgs#x # pinned
        nixpkgs:
          allow_unfree: true
          android_sdk:
            accept_license: false
      '' == {
        inputs = {
          projectSdk = {
            url = "github:owner/sdk/0123abc";
            flake = false;
          };
          nixpkgs.url = "github:NixOS/nixpkgs/4567def?dir=pkgs#x";
        };
        nixpkgs = {
          allow_unfree = true;
          android_sdk.accept_license = false;
        };
      };
    assert read "# nothing yet\n" == { };
    assert lib.all rejects [
      "---\nallow_unfree: true\n"
      "imports:\n  - ./backend\n"
      "imports: [ ./backend ]\n"
      "inputs:\n  nixpkgs:\n    url: \"github:NixOS/nixpkgs\"\n"
      "require_version: 2\n"
      "allow_unfree: yes\n"
      "profile: a: b\n"
      "nixpkgs:\n\tallow_unfree: true\n"
      "inputs:\n"
      "nixpkgs: x\n  allow_unfree: true\n"
      "inputs:\n    a:\n      url: github:o/a\n  b:\n    url: github:o/b\n"
      "profile: a\nprofile: b\n"
    ];
    pkgs.runCommand "projects-devenv-yaml-check" { } ''touch "$out"'';
}
