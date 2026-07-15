{
  home-manager,
  pkgs,
  self,
  ...
}:
let
  mkHome =
    extraModule:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeManagerModules.workspaceRepos
        {
          home = {
            username = "example";
            homeDirectory = "/home/example";
            stateVersion = "25.05";
          };
        }
        extraModule
      ];
    };
  workspaceReposScript = ./workspace-repos.py;
in
{
  workspace-repos-home =
    let
      home = mkHome { workspaceRepos.scheduledSync.enable = true; };
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
      home = mkHome { workspaceRepos.activationSync.discoverGitLabGroups = false; };
    in
    pkgs.runCommand "workspace-repos-home-no-gitlab-discovery" { } ''
      ! grep -q -- '--discover-gitlab-groups' ${home.activationPackage}/activate
      touch $out
    '';

  workspace-repos-python =
    pkgs.runCommand "workspace-repos-python" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        python3 -m py_compile ${workspaceReposScript}
        touch $out
      '';

  workspace-repos-discovery-failure =
    pkgs.runCommand "workspace-repos-discovery-failure" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        mkdir -p home bin
        cp ${./empty-inventory.json} inventory.json
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
          python3 ${workspaceReposScript} \
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
    pkgs.runCommand "workspace-repos-gitlab-discovery" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        python3 - <<'PY'
        import importlib.util
        import subprocess

        spec = importlib.util.spec_from_file_location(
            "workspace_repos",
            "${workspaceReposScript}",
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
        jj -R "$HOME/Code/example" config set --repo \
          revsets.short-prefixes '(missing..@)::'

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

        python3 ${workspaceReposScript} --config config.json sync --no-fetch
        jj -R "$HOME/Code/example" config unset --repo revsets.short-prefixes
        test -n "$(
          jj -R "$HOME/Code/example" log \
            -r 'parents(@) & main@origin' --no-graph -T commit_id
        )"

        jj -R "$HOME/Code/example" new 'root()'
        echo dirty > "$HOME/Code/example/dirty"
        python3 ${workspaceReposScript} --config config.json sync --no-fetch 2> error.log
        grep -q 'working copy contains changes' error.log
        test -n "$(
          jj -R "$HOME/Code/example" log \
            -r 'parents(@) & root()' --no-graph -T commit_id
        )"
        python3 ${workspaceReposScript} --config config.json doctor > doctor.log
        grep -q '\[info\].*automatic working-copy policy skipped: working copy contains changes' \
          doctor.log
        grep -q '\[ok\]   Code/example' doctor.log

        jq '.inventory.repositories[0].bookmark = "missing"' \
          config.json > unsupported-config.json
        python3 ${workspaceReposScript} \
          --config unsupported-config.json sync --no-fetch 2> unsupported-error.log
        grep -q 'skip automatic working-copy update.*missing@origin' unsupported-error.log

        jj -R "$HOME/Code/example" new 'main@origin'
        echo local > "$HOME/Code/example/local"
        jj -R "$HOME/Code/example" commit -m 'local only'
        python3 ${workspaceReposScript} --config config.json sync --no-fetch 2> local-error.log
        grep -q 'current parent is not an ancestor' local-error.log
        test "$(
          jj -R "$HOME/Code/example" log \
            -r 'parents(@)' --no-graph -T 'description.first_line()'
        )" = 'local only'

        old_change="$(jj -R "$HOME/Code/example" log -r @ --no-graph -T change_id)"
        echo preserved > "$HOME/Code/example/preserved"
        jj -R "$HOME/Code/example" describe -m 'active work'
        jq '.inventory.repositories[0].working_copy = {mode: "snapshot-and-reset"}' \
          config.json > aggressive-config.json
        python3 ${workspaceReposScript} \
          --config aggressive-config.json sync --no-fetch > aggressive.log
        grep -q "previous change: $old_change" aggressive.log
        test -n "$(
          jj -R "$HOME/Code/example" log \
            -r 'parents(@) & main@origin' --no-graph -T commit_id
        )"
        test ! -e "$HOME/Code/example/preserved"

        echo on-base > "$HOME/Code/example/on-base"
        on_base_change="$(jj -R "$HOME/Code/example" log -r @ --no-graph -T change_id)"
        python3 ${workspaceReposScript} \
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
