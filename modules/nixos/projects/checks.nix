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
}
