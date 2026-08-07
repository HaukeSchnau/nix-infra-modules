{ lib }:
let
  projectDescriptor = import ./project-descriptor.nix { inherit lib; };
  runtimeImplementation = ./project-runtime/runtime.py;

  fail = context: message: throw "project runtime ${context}: ${message}";
  executableFor =
    context: value:
    if builtins.isString value || builtins.isPath value then
      toString value
    else if lib.isDerivation value then
      lib.getExe value
    else
      fail context "must be an executable path or package";
  normalizeActions =
    actions: lib.mapAttrs (name: value: executableFor "actions.${name}" value) actions;
  requireExactActions =
    context: expected: actual: value:
    let
      missing = lib.subtractLists actual expected;
      extra = lib.subtractLists expected actual;
    in
    if missing != [ ] then
      fail context "missing implementations: ${lib.concatStringsSep ", " missing}"
    else if extra != [ ] then
      fail context "undeclared implementations: ${lib.concatStringsSep ", " extra}"
    else
      value;
  rawDescriptor = descriptorPath: builtins.fromJSON (builtins.readFile descriptorPath);
  descriptorPackage =
    {
      pkgs,
      descriptorPath,
      name,
    }:
    pkgs.runCommand "${name}-project-descriptor" { } ''
      install -Dm0444 ${descriptorPath} $out/share/project/descriptor.json
    '';
  mkRuntimePackage =
    {
      pkgs,
      name,
      mainProgram,
      config,
      activationExecutable ? null,
    }:
    let
      configFile = pkgs.writeText "${name}-runtime-config.json" (builtins.toJSON config + "\n");
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = mainProgram;
      }
      ''
        install -Dm0555 ${runtimeImplementation} $out/libexec/project-runtime/runtime.py
        makeWrapper ${pkgs.python3}/bin/python $out/bin/${mainProgram} \
          --add-flags "$out/libexec/project-runtime/runtime.py --config ${configFile}" \
          --set PROJECT_RUNTIME_QUERY "$out/bin/project-context"
        makeWrapper ${pkgs.python3}/bin/python $out/bin/project-context \
          --add-flags "$out/libexec/project-runtime/runtime.py --config ${configFile} context" \
          --set PROJECT_RUNTIME_QUERY "$out/bin/project-context"
        ${lib.optionalString (activationExecutable != null) ''
          makeWrapper ${pkgs.python3}/bin/python $out/bin/${activationExecutable} \
            --add-flags "$out/libexec/project-runtime/runtime.py --config ${configFile} --activate" \
            --set PROJECT_RUNTIME_QUERY "$out/bin/project-context"
        ''}
      '';
  appFor = program: {
    type = "app";
    inherit program;
  };
  mkInvocation =
    {
      pkgs,
      name,
      executable,
      arguments,
    }:
    pkgs.writeShellScript "${name}" ''
      exec ${lib.escapeShellArgs ([ executable ] ++ arguments)} "$@"
    '';
  descriptorCheck =
    {
      pkgs,
      name,
      descriptorPath,
      package,
    }:
    pkgs.runCommand "${name}-descriptor-exact-check" { } ''
      cmp ${descriptorPath} ${package}/share/project/descriptor.json
      touch $out
    '';
in
rec {
  mkDevelopment =
    {
      pkgs,
      descriptorPath,
      actions,
      localParameters ? { },
      localPortRange ? {
        from = 30000;
        to = 39999;
      },
    }:
    let
      raw = rawDescriptor descriptorPath;
      descriptor = projectDescriptor.normalize { descriptor = raw; };
      development =
        if descriptor.development == null then
          fail "mkDevelopment" "descriptor does not declare Development"
        else
          descriptor.development;
      normalizedActions = normalizeActions actions;
      resolvedLocalParameters = projectDescriptor.resolveParameters {
        inherit descriptor;
        values = localParameters;
      };
      expectedActions = lib.unique (
        [ development.preparation.action ]
        ++ map (workload: workload.action) (lib.attrValues development.workloads)
      );
      checkedActions =
        requireExactActions "mkDevelopment.actions" expectedActions (builtins.attrNames normalizedActions)
          normalizedActions;
      portFrom = localPortRange.from or 30000;
      portTo = localPortRange.to or 39999;
      package = mkRuntimePackage {
        inherit pkgs;
        name = "${descriptor.project}-project-runtime";
        mainProgram = "${descriptor.project}-project-runtime";
        config = {
          schemaVersion = 1;
          inherit (descriptor) project;
          realization = "development";
          actions = checkedActions;
          endpoints = builtins.attrNames development.endpoints;
          parameterDefinitions = descriptor.parameters;
          secrets = builtins.attrNames descriptor.secrets;
          workloads = development.workloads;
          preparationAction = development.preparation.action;
          localPortRange = [
            portFrom
            portTo
          ];
          localParameters = resolvedLocalParameters;
        };
      };
      executable = lib.getExe package;
      prepareProgram = mkInvocation {
        inherit pkgs executable;
        name = "${descriptor.project}-prepare";
        arguments = [ development.preparation.action ];
      };
      devProgram = mkInvocation {
        inherit pkgs executable;
        name = "${descriptor.project}-dev";
        arguments = [ "dev" ];
      };
      workloadApps = lib.mapAttrs' (
        workloadName: _:
        lib.nameValuePair "dev-${workloadName}" (
          appFor (mkInvocation {
            inherit pkgs executable;
            name = "${descriptor.project}-dev-${workloadName}";
            arguments = [
              "dev"
              "--only"
              workloadName
            ];
          })
        )
      ) development.workloads;
    in
    if portFrom < 1 || portTo > 65535 || portFrom > portTo then
      fail "mkDevelopment.localPortRange" "must be a non-empty valid TCP port range"
    else
      {
        inherit package;
        apps = {
          prepare = appFor prepareProgram;
          dev = appFor devProgram;
        }
        // workloadApps;
        checks = {
          interface = pkgs.runCommand "${descriptor.project}-development-runtime-interface" { } ''
            test -x ${package}/bin/${descriptor.project}-project-runtime
            test -x ${package}/bin/project-context
            touch $out
          '';
        };
      };

  mkServiceRelease =
    {
      pkgs,
      descriptorPath,
      payloads ? [ ],
      actions,
      defaultAction ? null,
      activation ? null,
    }:
    let
      raw = rawDescriptor descriptorPath;
      descriptor = projectDescriptor.normalize { descriptor = raw; };
      release =
        if descriptor.release == null || descriptor.release.backend != "service" then
          fail "mkServiceRelease" "descriptor does not declare a service Release"
        else
          descriptor.release;
      effectiveDefaultAction = if defaultAction == null then release.action else defaultAction;
      normalizedActions = normalizeActions actions;
      expectedActions = lib.unique (
        [ effectiveDefaultAction ] ++ map (job: job.action) (lib.attrValues release.maintenanceJobs)
      );
      checkedActions =
        requireExactActions "mkServiceRelease.actions" expectedActions
          (builtins.attrNames normalizedActions)
          normalizedActions;
      activationExecutable = release.activationExecutable;
      activationAction =
        if activation == null then null else executableFor "mkServiceRelease.activation" activation;
      runtimePackage = mkRuntimePackage {
        inherit pkgs activationExecutable;
        name = "${descriptor.project}-release-runtime";
        mainProgram = release.executable;
        config = {
          schemaVersion = 1;
          inherit (descriptor) project;
          realization = "release";
          actions = checkedActions;
          defaultAction = effectiveDefaultAction;
          activation = activationAction;
          parameterDefinitions = descriptor.parameters;
          secrets = builtins.attrNames descriptor.secrets;
        };
      };
      embeddedDescriptor = descriptorPackage {
        inherit pkgs descriptorPath;
        name = descriptor.project;
      };
      package = pkgs.symlinkJoin {
        name = "${descriptor.project}-project-release";
        paths = payloads ++ [
          runtimePackage
          embeddedDescriptor
        ];
        meta.mainProgram = release.executable;
      };
    in
    if defaultAction != null && defaultAction != release.action then
      fail "mkServiceRelease.defaultAction" "must equal repository descriptor release.action"
    else if (activation == null) != (activationExecutable == null) then
      fail "mkServiceRelease.activation" "must be present exactly when release.activationExecutable is declared"
    else
      {
        inherit package;
        checks = {
          descriptorExact = descriptorCheck {
            inherit pkgs descriptorPath package;
            name = descriptor.project;
          };
          interface = pkgs.runCommand "${descriptor.project}-release-runtime-interface" { } ''
            test -x ${package}/bin/${release.executable}
            test -x ${package}/bin/project-context
            ${lib.optionalString (
              activationExecutable != null
            ) "test -x ${package}/bin/${activationExecutable}"}
            touch $out
          '';
        };
      };

  mkStaticRelease =
    {
      pkgs,
      descriptorPath,
      root,
    }:
    let
      raw = rawDescriptor descriptorPath;
      descriptor = projectDescriptor.normalize { descriptor = raw; };
      release =
        if descriptor.release == null || descriptor.release.backend != "static" then
          fail "mkStaticRelease" "descriptor does not declare a static Release"
        else
          descriptor.release;
      embeddedDescriptor = descriptorPackage {
        inherit pkgs descriptorPath;
        name = descriptor.project;
      };
      package = pkgs.symlinkJoin {
        name = "${descriptor.project}-project-release";
        paths = [
          root
          embeddedDescriptor
        ];
      };
    in
    {
      inherit package;
      checks.descriptorExact = descriptorCheck {
        inherit pkgs descriptorPath package;
        name = descriptor.project;
      };
    };
}
