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
      };

      nixosModules = {
        default = self.nixosModules.fleet;
        fleet = ./modules/nixos/fleet;
        generatedContract = ./modules/nixos/fleet/generated-contract.nix;
        fleetTooling = ./modules/nixos/fleet/tooling.nix;
        podmanRuntime = ./modules/nixos/runtime/podman.nix;
        serverBackup = ./modules/nixos/backup/server-backup.nix;
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
          example = import ./examples/two-vps-fleet {
            inherit nixpkgs system;
            modules = self.nixosModules;
            nixosLib = self.lib.nixos;
          };
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

          core-example = example.nixosConfigurations.core-01.config.system.build.toplevel;
          edge-example = example.nixosConfigurations.edge-01.config.system.build.toplevel;

          edge-tcp-range-example =
            let
              haproxyConfig = pkgs.writeText "edge-example-haproxy.cfg" example.nixosConfigurations.edge-01.config.services.haproxy.config;
            in
            pkgs.runCommand "edge-tcp-range-example" { } ''
              grep -q 'bind :22000' ${haproxyConfig}
              grep -q 'server upstream core-01:32000 init-addr libc' ${haproxyConfig}
              grep -q 'bind :22001' ${haproxyConfig}
              grep -q 'server upstream core-01:32001 init-addr libc' ${haproxyConfig}
              grep -q 'bind :22002' ${haproxyConfig}
              grep -q 'server upstream core-01:32002 init-addr libc' ${haproxyConfig}
              touch $out
            '';

          server-backup-example =
            let
              backupSystem = lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.serverBackup
                  {
                    networking.hostName = "core-01";
                    fileSystems."/".device = "/dev/disk/by-label/nixos";
                    boot.loader.grub.enable = false;
                    system.stateVersion = "25.05";
                    server.backup = {
                      enable = true;
                      repository = "s3:https://s3.example.net/example-backup";
                      passwordFile = "/run/secrets/restic-password";
                      environmentFile = "/run/secrets/restic-env";
                    };
                  }
                ];
              };
              backup = backupSystem.config.services.restic.backups.core-01;
            in
            pkgs.runCommand "server-backup-example" { } ''
              test '${backup.repository}' = 's3:https://s3.example.net/example-backup'
              test '${backup.passwordFile}' = '/run/secrets/restic-password'
              test '${backup.environmentFile}' = '/run/secrets/restic-env'
              test '${if builtins.elem "--host core-01" backup.pruneOpts then "yes" else "no"}' = 'yes'
              touch $out
            '';

          workspace-repos-home =
            (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                self.homeManagerModules.workspaceRepos
                {
                  home = {
                    username = "example";
                    homeDirectory = "/home/example";
                    stateVersion = "25.05";
                  };
                  workspaceRepos.activationSync.enable = false;
                }
              ];
            }).activationPackage;

          workspace-repos-python =
            pkgs.runCommand "workspace-repos-python"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                python3 -m py_compile ${./modules/home-manager/workspace-repos/workspace-repos.py}
                touch $out
              '';
        }
      );
    };
}
