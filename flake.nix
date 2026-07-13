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
          example = import ./examples/two-vps-fleet {
            inherit nixpkgs system;
            modules = self.nixosModules;
            nixosLib = self.lib.nixos;
          };
          mkFleetSystem =
            name: extraModules:
            lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.fleet
                {
                  networking.hostName = name;
                  boot.isContainer = true;
                  system.stateVersion = "25.05";
                  vps = {
                    enable = true;
                    baseDomain = "example.net";
                    caddy.acmeEmail = "admin@example.net";
                  };
                }
              ]
              ++ extraModules;
            };
          podmanSystem = mkFleetSystem "runtime-01" [
            {
              vps.services.podman.enable = true;
            }
          ];
          githubRunnerSystem = mkFleetSystem "github-ci-01" [
            {
              vps.services.githubRunner = {
                enable = true;
                url = "https://github.com/example-org/example-repo";
                tokenFile = "/run/secrets/github-runner-token";
                instanceName = "github-ci";
                runnerName = "github-ci";
                instanceCount = 2;
              };
            }
          ];
          giteaRunnerSystem = mkFleetSystem "gitea-ci-01" [
            {
              vps.services.giteaActionsRunner = {
                enable = true;
                url = "https://git.example.net";
                tokenFile = "/run/secrets/gitea-runner-token";
                instanceName = "gitea-ci";
                runnerName = "gitea-ci";
              };
            }
          ];
          gitMirrorsSystem = mkFleetSystem "git-mirror-01" [
            {
              vps.services.gitMirrors = {
                enable = true;
                mirrorAll = false;
                gitea = {
                  baseUrl = "https://git.example.net";
                  username = "mirror";
                  tokenFile = "/run/secrets/gitea-token";
                };
                github = {
                  owner = "example-org";
                  tokenFile = "/run/secrets/github-token";
                };
                repositories.demo = {
                  gitea = "example/demo";
                  githubName = "demo-mirror";
                  description = "Demo mirror";
                };
              };
            }
          ];
          caddyInternalIngressSystem = mkFleetSystem "internal-ingress-01" [
            {
              vps.services.caddy = {
                enable = true;
                publicVirtualHosts.enable = false;
                internalIngress.enable = true;
                virtualHosts."app.example.net".upstream = "127.0.0.1:8080";
              };
            }
          ];
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

          fleet-generated-services-example =
            let
              generatedServices = example.nixosConfigurations.core-01.config.vps.generated.services;
              serviceNames = map (service: service.name) generatedServices;
              healthUnits = example.nixosConfigurations.core-01.config.vps.generated.healthUnits;
            in
            pkgs.runCommand "fleet-generated-services-example" { } ''
              test '${toString (builtins.length generatedServices)}' = '2'
              test '${if builtins.elem "appDeployments" serviceNames then "yes" else "no"}' = 'yes'
              test '${if builtins.elem "caddy" serviceNames then "yes" else "no"}' = 'yes'
              test '${if builtins.elem "app-deployment-demo.service" healthUnits then "yes" else "no"}' = 'yes'
              test '${if builtins.elem "caddy.service" healthUnits then "yes" else "no"}' = 'yes'
              touch $out
            '';

          edge-contract-example =
            let
              contract = example.nixosConfigurations.core-01.config.vps.generated.edgeIngress;
              routeNames = lib.attrNames contract.routes;
            in
            pkgs.runCommand "edge-contract-example" { } ''
              test '${contract.upstreamHost}' = 'core-01'
              test '${toString contract.internalIngressPort}' = '8080'
              test '${if builtins.elem "admin.example.net" routeNames then "yes" else "no"}' = 'yes'
              test '${if builtins.elem "demo.example.net" routeNames then "yes" else "no"}' = 'yes'
              test '${toString contract.tcpForwardRanges.demo.listen.from}' = '22000'
              test '${toString contract.tcpForwardRanges.demo.upstream.to}' = '32002'
              touch $out
            '';

          caddy-internal-ingress-example =
            let
              publicVirtualHostNames = lib.attrNames caddyInternalIngressSystem.config.services.caddy.virtualHosts;
              routeNames = lib.attrNames caddyInternalIngressSystem.config.vps.services.caddy.virtualHosts;
              extraConfig = caddyInternalIngressSystem.config.services.caddy.extraConfig;
              extraConfigFile = pkgs.writeText "caddy-extra-config" extraConfig;
            in
            pkgs.runCommand "caddy-internal-ingress-example" { } ''
              test '${toString (builtins.length publicVirtualHostNames)}' = '0'
              test '${if builtins.elem "app.example.net" routeNames then "yes" else "no"}' = 'yes'
              grep -q ':8080 {' ${extraConfigFile}
              grep -q 'host app.example.net' ${extraConfigFile}
              touch $out
            '';

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

          podman-runtime-example =
            let
              runtime = podmanSystem.config;
            in
            pkgs.runCommand "podman-runtime-example" { } ''
              test '${if runtime.virtualisation.podman.enable then "yes" else "no"}' = 'yes'
              test '${if runtime.virtualisation.podman.dockerCompat then "yes" else "no"}' = 'yes'
              test '${runtime.virtualisation.oci-containers.backend}' = 'podman'
              test '${if runtime.vps.hostCapabilities.containerNetworking.enable then "yes" else "no"}' = 'yes'
              test '${runtime.systemd.services.podman-network-proxy.description}' = "Create Podman network 'proxy' for VPS containers"
              test '${runtime.systemd.timers."runtime-01-podman-prune".timerConfig.OnCalendar}' = 'daily'
              touch $out
            '';

          github-runner-example =
            let
              runners = githubRunnerSystem.config.services.github-runners;
              healthUnits = githubRunnerSystem.config.vps.services.githubRunner.metadata.health.units;
            in
            pkgs.runCommand "github-runner-example" { } ''
              test '${runners."github-ci".url}' = 'https://github.com/example-org/example-repo'
              test '${runners."github-ci".name}' = 'github-ci'
              test '${runners."github-ci-2".name}' = 'github-ci-2'
              test '${toString runners."github-ci".tokenFile}' = '/run/secrets/github-runner-token'
              test '${runners."github-ci".serviceOverrides.MemoryMax}' = '5.5G'
              test '${
                if builtins.elem "github-runner-github-ci.service" healthUnits then "yes" else "no"
              }' = 'yes'
              test '${
                if builtins.elem "github-runner-github-ci-2.service" healthUnits then "yes" else "no"
              }' = 'yes'
              touch $out
            '';

          gitea-runner-example =
            let
              runner = giteaRunnerSystem.config.services.gitea-actions-runner.instances."gitea-ci";
              unit = giteaRunnerSystem.config.systemd.services."gitea-runner-gitea\\x2dci";
              healthUnits = giteaRunnerSystem.config.vps.services.giteaActionsRunner.metadata.health.units;
            in
            pkgs.runCommand "gitea-runner-example" { } ''
              test '${runner.url}' = 'https://git.example.net'
              test '${runner.name}' = 'gitea-ci'
              test '${toString runner.tokenFile}' = '/run/secrets/gitea-runner-token'
              test '${unit.environment.DOCKER_HOST}' = 'unix:///run/docker.sock'
              test '${unit.serviceConfig.MemoryMax}' = '4G'
              test '${
                if builtins.elem "gitea-runner-gitea\\x2dci.service" healthUnits then "yes" else "no"
              }' = 'yes'
              touch $out
            '';

          git-mirrors-example =
            let
              cfg = gitMirrorsSystem.config;
              service = cfg.systemd.services.git-mirrors-sync;
              timer = cfg.systemd.timers.git-mirrors-sync;
              script = builtins.elemAt (lib.splitString " " service.serviceConfig.ExecStart) 1;
              healthUnits = cfg.vps.services.gitMirrors.metadata.health.units;
            in
            pkgs.runCommand "git-mirrors-example"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.python3
                ];
              }
              ''
                test '${service.environment.GIT_MIRRORS_GITEA_TOKEN_FILE}' = '/run/secrets/gitea-token'
                test '${service.environment.GIT_MIRRORS_GITHUB_TOKEN_FILE}' = '/run/secrets/github-token'
                test '${service.serviceConfig.User}' = 'git-mirrors'
                test '${timer.timerConfig.OnUnitActiveSec}' = '15min'
                test '${if builtins.elem "git-mirrors-sync.timer" healthUnits then "yes" else "no"}' = 'yes'
                jq -e '.userAgent == "nix-infra-modules-git-mirrors"' ${service.environment.GIT_MIRRORS_CONFIG}
                jq -e '.github.baseUrl == "https://github.com"' ${service.environment.GIT_MIRRORS_CONFIG}
                python3 -m py_compile ${script}
                grep -q '"User-Agent": self.user_agent' ${script}
                ! grep -q '"User-Agent": cfg\\["userAgent"\\]' ${script}
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
            let
              home = home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.homeManagerModules.workspaceRepos
                  {
                    home = {
                      username = "example";
                      homeDirectory = "/home/example";
                      stateVersion = "25.05";
                    };
                    workspaceRepos.scheduledSync.enable = true;
                  }
                ];
              };
            in
            pkgs.runCommand "workspace-repos-home" { } ''
              grep -q -- '--discover-gitlab-groups' ${home.activationPackage}/activate
              test '${home.config.systemd.user.timers.workspace-repos-sync.Timer.OnCalendar}' = 'hourly'
              test '${
                if home.config.systemd.user.timers.workspace-repos-sync.Timer.Persistent then "yes" else "no"
              }' = 'yes'
              touch $out
            '';

          workspace-repos-home-no-gitlab-discovery =
            let
              home = home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.homeManagerModules.workspaceRepos
                  {
                    home = {
                      username = "example";
                      homeDirectory = "/home/example";
                      stateVersion = "25.05";
                    };
                    workspaceRepos.activationSync.discoverGitLabGroups = false;
                  }
                ];
              };
            in
            pkgs.runCommand "workspace-repos-home-no-gitlab-discovery" { } ''
              ! grep -q -- '--discover-gitlab-groups' ${home.activationPackage}/activate
              touch $out
            '';

          workspace-repos-python =
            pkgs.runCommand "workspace-repos-python"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                python3 -m py_compile ${./modules/home-manager/workspace-repos/workspace-repos.py}
                touch $out
              '';

          workspace-repos-discovery-failure =
            pkgs.runCommand "workspace-repos-discovery-failure"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                mkdir -p home bin
                cp ${./modules/home-manager/workspace-repos/empty-inventory.json} inventory.json
                ${pkgs.jq}/bin/jq '.gitlab_groups = [{
                  "group": "example",
                  "base_path": "Code",
                  "include_archived": false,
                  "preserve_namespace": true
                }]' inventory.json > configured-inventory.json
                ${pkgs.jq}/bin/jq -n --slurpfile inventory configured-inventory.json '{
                  version: 1,
                  inventory: $inventory[0],
                  writable_inventory_path: "unused.json"
                }' > config.json
                printf '#!${pkgs.runtimeShell}\nexit 23\n' > bin/glab
                chmod +x bin/glab

                if HOME="$PWD/home" PATH="$PWD/bin:$PATH" \
                  python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                    --config config.json sync --discover-gitlab-groups --no-fetch \
                    2> error.log
                then
                  echo "GitLab discovery failure unexpectedly succeeded" >&2
                  exit 1
                fi
                grep -q 'GitLab discovery failed for example' error.log
                touch $out
              '';

          workspace-repos-gitlab-discovery =
            pkgs.runCommand "workspace-repos-gitlab-discovery"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                python3 - <<'PY'
                import importlib.util
                import subprocess

                spec = importlib.util.spec_from_file_location(
                    "workspace_repos",
                    "${./modules/home-manager/workspace-repos/workspace-repos.py}",
                )
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)

                captured = []
                def fake_run(args, **kwargs):
                    captured.append(args)
                    return subprocess.CompletedProcess(
                        args,
                        0,
                        stdout=(
                            '{"path_with_namespace":"example/subgroup/one",'
                            '"path":"one","ssh_url_to_repo":"git@example.test:example/subgroup/one.git",'
                            '"default_branch":"main","archived":false}\n'
                            '{"path_with_namespace":"example/two",'
                            '"path":"two","ssh_url_to_repo":"git@example.test:example/two.git",'
                            '"default_branch":"trunk","archived":false}\n'
                            '{"path_with_namespace":"example/metadata-only",'
                            '"path":"metadata-only",'
                            '"ssh_url_to_repo":"git@example.test:example/metadata-only.git",'
                            '"repository_access_level":"disabled","archived":false}\n'
                        ),
                        stderr="",
                    )

                module.run = fake_run
                module.command_exists = lambda _command: True
                repos = module.discover_gitlab_group({
                    "group": "example",
                    "host": "example.test",
                    "base_path": "Work/Repos",
                    "include_archived": False,
                    "preserve_namespace": True,
                })

                assert [repo.path for repo in repos] == [
                    "Work/Repos/subgroup/one",
                    "Work/Repos/two",
                ]
                assert [
                    module.effective_working_copy_policy(repo, module.Path(".")).base
                    for repo in repos
                ] == ["main@origin", "trunk@origin"]
                opted_out = module.repo_from_dict({
                    "path": "Code/opted-out",
                    "url": "git@example.test:example/opted-out.git",
                    "bookmark": "main",
                    "working_copy": False,
                })
                assert module.effective_working_copy_policy(
                    opted_out, module.Path(".")
                ) is None
                assert module.repo_to_dict(opted_out)["working_copy"] is False
                command = captured[0]
                assert command[:4] == ["glab", "api", "--hostname", "example.test"]
                assert "groups/example/projects?" in command[4]
                assert "include_subgroups=true" in command[4]
                assert "archived=false" in command[4]
                assert command[-3:] == ["--paginate", "--output", "ndjson"]
                PY
                touch $out
              '';

          workspace-repos-working-copy =
            pkgs.runCommand "workspace-repos-working-copy"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.jq
                  pkgs.jujutsu
                  pkgs.python3
                ];
              }
              ''
                export HOME="$PWD/home"
                export XDG_CONFIG_HOME="$PWD/config"
                mkdir -p "$HOME" "$XDG_CONFIG_HOME"

                git init -q -b main seed
                git -C seed config user.email test@example.com
                git -C seed config user.name Test
                echo initial > seed/file
                git -C seed add file
                git -C seed commit -qm initial
                git clone -q --bare seed remote.git
                jj git clone --colocate --branch main "$PWD/remote.git" "$HOME/Code/example"
                jj -R "$HOME/Code/example" new 'root()'

                jq -n --arg url "$PWD/remote.git" '{
                  version: 1,
                  writable_inventory_path: "unused.json",
                  inventory: {
                    version: 1,
                    roots: [],
                    gitlab_groups: [],
                    repositories: [{
                      path: "Code/example",
                      url: $url,
                      bookmark: "main"
                    }]
                  }
                }' > config.json

                python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                  --config config.json sync --no-fetch
                test -n "$(
                  jj -R "$HOME/Code/example" log \
                    -r 'parents(@) & main@origin' --no-graph -T commit_id
                )"

                jj -R "$HOME/Code/example" new 'root()'
                echo dirty > "$HOME/Code/example/dirty"
                python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                  --config config.json sync --no-fetch 2> error.log
                grep -q 'working copy contains changes' error.log
                test -n "$(
                  jj -R "$HOME/Code/example" log \
                    -r 'parents(@) & root()' --no-graph -T commit_id
                )"
                python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                  --config config.json doctor > doctor.log
                grep -q '\[info\].*automatic working-copy policy skipped: working copy contains changes' \
                  doctor.log
                grep -q '\[ok\]   Code/example' doctor.log

                jq '.inventory.repositories[0].bookmark = "missing"' \
                  config.json > unsupported-config.json
                python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                  --config unsupported-config.json sync --no-fetch \
                  2> unsupported-error.log
                grep -q 'skip automatic working-copy update.*missing@origin' \
                  unsupported-error.log

                jj -R "$HOME/Code/example" new 'main@origin'
                echo local > "$HOME/Code/example/local"
                jj -R "$HOME/Code/example" commit -m 'local only'
                python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                  --config config.json sync --no-fetch 2> local-error.log
                grep -q 'current parent is not an ancestor' local-error.log
                test "$(
                  jj -R "$HOME/Code/example" log \
                    -r 'parents(@)' --no-graph -T 'description.first_line()'
                )" = 'local only'

                old_change="$(
                  jj -R "$HOME/Code/example" log \
                    -r @ --no-graph -T change_id
                )"
                echo preserved > "$HOME/Code/example/preserved"
                jj -R "$HOME/Code/example" describe -m 'active work'
                jq '.inventory.repositories[0].working_copy = {mode: "snapshot-and-reset"}' \
                  config.json > aggressive-config.json
                python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                  --config aggressive-config.json sync --no-fetch > aggressive.log
                grep -q "previous change: $old_change" aggressive.log
                test -n "$(
                  jj -R "$HOME/Code/example" log \
                    -r 'parents(@) & main@origin' --no-graph -T commit_id
                )"
                test ! -e "$HOME/Code/example/preserved"

                echo on-base > "$HOME/Code/example/on-base"
                on_base_change="$(
                  jj -R "$HOME/Code/example" log \
                    -r @ --no-graph -T change_id
                )"
                python3 ${./modules/home-manager/workspace-repos/workspace-repos.py} \
                  --config aggressive-config.json sync --no-fetch > on-base.log
                grep -q "previous change: $on_base_change" on-base.log
                test ! -e "$HOME/Code/example/on-base"
                jj -R "$HOME/Code/example" edit "$on_base_change"
                test "$(cat "$HOME/Code/example/on-base")" = on-base

                jj -R "$HOME/Code/example" edit "$old_change"
                test "$(cat "$HOME/Code/example/preserved")" = preserved
                test "$(
                  jj -R "$HOME/Code/example" log \
                    -r @ --no-graph -T 'description.first_line()'
                )" = 'active work'
                test "$(
                  jj -R "$HOME/Code/example" log \
                    -r 'parents(@)' --no-graph -T 'description.first_line()'
                )" = 'local only'
                touch $out
              '';
        }
      );
    };
}
