{
  description = "Reusable Nix infrastructure modules for small self-hosted fleets";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      linuxSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      lib.nixos = {
        nixFlakeService = import ./modules/nixos/deploy/nix-flake-service.nix;
        generatedInventory = import ./modules/nixos/inventory/generated-inventory.nix;
        generatedTypes = import ./modules/nixos/inventory/generated-types.nix;
        serviceMetadata = import ./modules/nixos/fleet/service-metadata.nix { inherit lib; };
      };

      nixosModules = {
        default = self.nixosModules.fleet;
        fleet = ./modules/nixos/fleet;
        generatedContract = ./modules/nixos/fleet/generated-contract.nix;
        fleetTooling = ./modules/nixos/fleet/tooling.nix;
        podmanRuntime = ./modules/nixos/runtime/podman.nix;
        serverBackup = ./modules/nixos/backup/server-backup.nix;
        gitMirrors = ./modules/nixos/developer/git-mirrors.nix;
        githubRunner = ./modules/nixos/ci/github-runner.nix;
        giteaActionsRunner = ./modules/nixos/ci/gitea-actions-runner.nix;
        caddyIngress = ./modules/nixos/ingress/caddy.nix;
        edgeIngress = ./modules/nixos/ingress/edge-ingress.nix;
        appDeployments = ./modules/nixos/deploy/app-deployments.nix;
      };

      darwinModules = {
        wireguardProfiles = ./modules/darwin/wireguard-profiles.nix;
        developerFonts = ./modules/darwin/developer-fonts.nix;
        developerPaths = ./modules/darwin/developer-paths.nix;
      };

      homeManagerModules = {
        colors = ./modules/home-manager/colors;
        workspaceRepos = ./modules/home-manager/workspace-repos;
      };

      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.writeShellApplication {
          name = "nix-infra-modules-fmt";
          runtimeInputs = [
            pkgs.findutils
            pkgs.nixfmt
          ];
          text = ''
            targets=("$@")
            if [ "''${#targets[@]}" -eq 0 ]; then
              targets=(.)
            fi
            find "''${targets[@]}" -type f -name '*.nix' -print0 | xargs -0 nixfmt
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              gitleaks
              just
              nixfmt
              ripgrep
            ];
          };
        }
      );

      checks = lib.genAttrs linuxSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          checkArgs = {
            inherit
              home-manager
              lib
              nixpkgs
              pkgs
              self
              system
              ;
          };
          domainChecks = lib.mergeAttrsList (
            map (path: import path checkArgs) [
              ./modules/nixos/fleet/checks.nix
              ./modules/nixos/deploy/checks.nix
              ./modules/nixos/ingress/checks.nix
              ./modules/nixos/runtime/checks.nix
              ./modules/nixos/ci/checks.nix
              ./modules/nixos/developer/checks.nix
              ./modules/nixos/backup/checks.nix
              ./modules/home-manager/workspace-repos/checks.nix
              ./modules/home-manager/colors/checks.nix
            ]
          );
        in
        {
          format =
            pkgs.runCommand "nix-infra-modules-format"
              {
                nativeBuildInputs = [
                  pkgs.findutils
                  pkgs.nixfmt
                ];
              }
              ''
                find ${./.} -type f -name '*.nix' -print0 | xargs -0 nixfmt --check
                touch $out
              '';
        }
        // domainChecks
      );
    };
}
