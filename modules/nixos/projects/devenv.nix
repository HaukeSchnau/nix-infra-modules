# Builds a prepared development bundle from a repository's devenv.nix,
# devenv.yaml and devenv.lock. Managed wakeups run this bundle without
# evaluating Nix again; `project dev bundle refresh` rebuilds it.
#
# The bundle contains:
#   bin/<name>-project-runtime  the devenv manager (devenv_manager.py)
#   bin/project-context         the SDK's context runtime for development
#   share/project/bundle.json   {schemaVersion, project, entrypoint}
#   share/project/project.json  the normalized Project contract
{
  pkgs,
  devenv,
  projectRuntime,
  project,
  managerSource,
  hostname ? null,
  username ? null,
}:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  devenvPackages = devenv.packages.${system};
  # devenv_manager.py speaks the private protocol of exactly this version.
  devenvVersion =
    assert lib.assertMsg (
      devenvPackages.devenv.version == "2.3.1"
    ) "the prepared devenv manager is pinned to devenv 2.3.1's daemon-processes protocol";
    devenvPackages.devenv.version;
  root = "/tmp/project-devenv";

  yaml = lib.importJSON (
    pkgs.runCommand "project-devenv-yaml.json" { preferLocalBuild = true; } ''
      ${lib.getExe pkgs.yj} -yj < ${
        builtins.path {
          path = project.outPath + "/devenv.yaml";
          name = "project-devenv.yaml";
        }
      } > "$out"
    ''
  );
  lockPath = project.outPath + "/devenv.lock";
  lock = lib.importJSON lockPath;
  rootInputs = lock.nodes.${lock.root}.inputs;
  inputDrift = lib.filter (
    name:
    let
      input = yaml.inputs.${name};
    in
    input ? url
    && (
      !(rootInputs ? ${name})
      || builtins.parseFlakeRef input.url != lock.nodes.${rootInputs.${name}}.original
    )
  ) (lib.attrNames (yaml.inputs or { }));
  # TODO: Replace this pinned bootstrap with an upstream prepared export.
  # YAML composition and secrets are rejected rather than partly applied.
  supportedKeys = [
    "inputs"
    "nixpkgs"
    "allow_unfree"
    "allowUnfree"
    "allow_broken"
    "allowBroken"
    "allow_unsupported_system"
    "allowUnsupportedSystem"
    "profile"
    "require_version"
    "reload"
    "prompt_prefix"
    "strict_ports"
    "strictPorts"
    "shell"
  ];
  unsupported = lib.subtractLists supportedKeys (lib.attrNames yaml);
  camelCase =
    key:
    let
      parts = lib.splitString "_" key;
    in
    builtins.head parts + lib.concatMapStrings lib.toSentenceCase (builtins.tail parts);
  packageConfig = lib.mapAttrs' (
    key: value: lib.nameValuePair (if key == "android_sdk" then key else camelCase key) value
  ) (yaml.nixpkgs or { });
  evaluation =
    (import (devenv + "/devenv-nix-backend/bootstrap/bootstrapLib.nix") {
      inputs =
        (import (devenv + "/devenv-nix-backend/bootstrap/resolve-lock.nix") {
          src = project.outPath;
          lockFilePath = lockPath;
          inherit system;
        }).inputs;
    }).mkDevenvForSystem
      {
        version = devenvVersion;
        require_version_match = yaml.require_version or false;
        inherit system hostname username;
        devenv_root = root;
        git_root = root;
        devenv_lock = lockPath;
        devenv_dotfile = "${root}/.devenv";
        devenv_dotfile_path = "${root}/.devenv";
        devenv_state = "${root}/.devenv/state";
        devenv_runtime = "/tmp/devenv-runtime";
        devenv_tmpdir = "/tmp";
        devenv_direnvrc_latest_version = 1;
        active_profiles = lib.optional (yaml ? profile) yaml.profile;
        skip_local_src = true;
        devenv_inputs = yaml.inputs or { };
        nixpkgs_config = {
          allowUnfree = yaml.allow_unfree or (yaml.allowUnfree or false);
          allowBroken = yaml.allow_broken or (yaml.allowBroken or false);
          allowUnsupportedSystem = yaml.allow_unsupported_system or (yaml.allowUnsupportedSystem or false);
        }
        // packageConfig;
        cli_options = {
          imports = [
            (project.outPath + "/devenv.nix")
          ]
          ++ lib.optional (builtins.pathExists (project.outPath + "/devenv.local.nix")) (
            project.outPath + "/devenv.local.nix"
          );
          process.proxy.enable = lib.mkForce false;
          devenv.warnOnNewVersion = false;
          task.package = devenvPackages.devenv-tasks;
          tasks."project:capture-environment" = {
            after = [ "devenv:enterShell" ];
            exec = ''
              ${pkgs.python3}/bin/python -c 'import json, os; json.dump(dict(os.environ), open(os.environ["DEVENV_RUNTIME"] + "/prepared-environment.json", "w"))'
            '';
          };
        };
      };
  config =
    if unsupported != [ ] then
      throw "prepared devenv does not support YAML keys: ${lib.concatStringsSep ", " unsupported}"
    else if packageConfig ? perPlatform then
      throw "prepared devenv does not yet support nixpkgs.per_platform"
    else if inputDrift != [ ] then
      throw "run devenv update and commit devenv.lock for changed inputs: ${lib.concatStringsSep ", " inputDrift}"
    else if !(evaluation.config.project.enable or false) then
      throw "a prepared bundle needs the Project SDK's devenv module with project.enable = true"
    else
      evaluation.config;
  descriptor = config.project.contract;
  name = descriptor.project;
  contractFile = pkgs.writeText "${name}-project.json" (builtins.toJSON descriptor + "\n");

  # Nix's own shell capture includes stdenv functions and arrays; the shell
  # hook runs against the live checkout at entry.
  environment = config.shell.overrideAttrs (_: {
    name = "${name}-devenv-environment";
    builder = lib.getExe pkgs.bash;
    args = [ "${pkgs.nix.src}/src/nix/get-env.sh" ];
  });
  # Identical task scripts for preparation and the manager keep devenv's
  # input caching valid across both; only the manager passes a log fd.
  loggedTasks = pkgs.runCommand "${name}-devenv-tasks" { preferLocalBuild = true; } ''
    mkdir -p "$out"
    ${pkgs.python3}/bin/python - ${config.task.config} "$out" ${lib.getExe evaluation.bash} <<'PY'
    import json, pathlib, shlex, sys
    tasks = json.loads(pathlib.Path(sys.argv[1]).read_text())
    output = pathlib.Path(sys.argv[2])
    for index, task in enumerate(tasks):
        if task.get("type") == "process" or not task.get("command"):
            continue
        wrapper = output / f"task-{index}"
        wrapper.write_text(
            "#!" + sys.argv[3] + '\n'
            'if [[ -n "''${PROJECT_DEVENV_LOG_FD:-}" ]]; then\n'
            '  exec 1>&"$PROJECT_DEVENV_LOG_FD" 2>&1\n'
            'fi\n'
            'exec ' + shlex.quote(task["command"]) + ' "$@"\n'
        )
        wrapper.chmod(0o555)
        task["command"] = str(wrapper)
    (output / "tasks.json").write_text(json.dumps(tasks))
    PY
  '';
  managerConfig = pkgs.writeText "${name}-devenv.json" (
    builtins.toJSON {
      inherit name root environment;
      tasks = "${loggedTasks}/tasks.json";
      runner = lib.getExe config.task.package;
      devenv = lib.getExe devenvPackages.devenv;
      bash = lib.getExe evaluation.bash;
      bwrap = lib.getExe pkgs.bubblewrap;
      captureEnvironment = pkgs.writeShellScript "${name}-command-environment" ''
        exec ${pkgs.python3}/bin/python -c 'import json, os; json.dump(dict(os.environ), open(os.environ["PROJECT_COMMAND_ENVIRONMENT"], "w"))'
      '';
      workloads = lib.mapAttrs (
        workload: _: "devenv:processes:${workload}"
      ) descriptor.development.workloads;
      commands = lib.mapAttrs (_: command: command.action) descriptor.development.commands;
      background = lib.attrNames (
        lib.filterAttrs (_: workload: workload.lifecycle == "background") descriptor.development.workloads
      );
    }
  );
  context = projectRuntime.developmentContext { inherit pkgs descriptor; };
  metadata = pkgs.writeText "${name}-bundle.json" (
    builtins.toJSON {
      schemaVersion = 2;
      project = name;
      entrypoint = "bin/${name}-project-runtime";
    }
  );
in
assert lib.assertMsg (lib.all (action: config.processes ? ${action} || config.tasks ? ${action}) (
  lib.attrNames descriptor.environment.development.actions
)) "${name}: the Project environment references an unknown devenv process or task";
pkgs.runCommand "${name}-project-devenv"
  {
    preferLocalBuild = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.mainProgram = "${name}-project-runtime";
    passthru = { inherit descriptor contractFile; };
  }
  ''
    install -Dm0555 ${managerSource} $out/libexec/devenv_manager.py
    makeWrapper ${pkgs.python3}/bin/python $out/bin/${name}-project-runtime \
      --add-flags "$out/libexec/devenv_manager.py --config ${managerConfig}" \
      --prefix PATH : "$out/bin"
    ln -s ${context}/bin/project-context $out/bin/project-context
    install -Dm0444 ${metadata} $out/share/project/bundle.json
    install -Dm0444 ${contractFile} $out/share/project/project.json
  ''
