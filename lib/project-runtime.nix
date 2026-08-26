{ lib }:
let
  projectDescriptor = import ./project-descriptor.nix { inherit lib; };
  developmentRuntimeImplementation = ./project-runtime/runtime.py;
  releaseRuntimeImplementation =
    pkgs:
    pkgs.buildGoModule {
      pname = "project-release-runtime";
      version = "1";
      src = ./project-release-runtime;
      vendorHash = null;
      env.CGO_ENABLED = 0;
      ldflags = [
        "-s"
        "-w"
      ];
      meta.mainProgram = "project-release-runtime";
    };

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
      bundle ? null,
      activationExecutable ? null,
    }:
    let
      configFile = pkgs.writeText "${name}-runtime-config.json" (builtins.toJSON config + "\n");
      isRelease = config.realization == "release";
      runtimeExecutable =
        if isRelease then lib.getExe (releaseRuntimeImplementation pkgs) else "${pkgs.python3}/bin/python";
      runtimeArguments =
        if isRelease then
          "--config ${configFile}"
        else
          "$out/libexec/project-runtime/runtime.py --config ${configFile}";
      bundleFile =
        if bundle == null then
          null
        else
          pkgs.writeText "${name}-bundle.json" (builtins.toJSON bundle + "\n");
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = mainProgram;
      }
      ''
        ${lib.optionalString (!isRelease) ''
          install -Dm0555 ${developmentRuntimeImplementation} $out/libexec/project-runtime/runtime.py
        ''}
        makeWrapper ${runtimeExecutable} $out/bin/${mainProgram} \
          --add-flags "${runtimeArguments}" \
          --prefix PATH : "$out/bin"
        makeWrapper ${runtimeExecutable} $out/bin/project-context \
          --add-flags "${runtimeArguments} context" \
          --prefix PATH : "$out/bin"
        ${lib.optionalString (bundleFile != null) ''
          install -Dm0444 ${bundleFile} $out/share/project/bundle.json
        ''}
        ${lib.optionalString (activationExecutable != null) ''
          makeWrapper ${runtimeExecutable} $out/bin/${activationExecutable} \
            --add-flags "${runtimeArguments} --activate" \
            --prefix PATH : "$out/bin"
        ''}
      '';
  appFor = program: {
    type = "app";
    program = toString program;
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
      runtimeSchemaVersion = if descriptor.schemaVersion >= 2 then 2 else 1;
      expectedActions = lib.unique (
        [ development.preparation.action ]
        ++ map (workload: workload.action) (lib.attrValues development.workloads)
        ++ map (command: command.action) (lib.attrValues development.commands)
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
        bundle = {
          schemaVersion = 1;
          descriptorSchemaVersion = descriptor.schemaVersion;
          inherit runtimeSchemaVersion;
          inherit (descriptor) project parameters secrets;
          realization = "development";
          entrypoint = "bin/${descriptor.project}-project-runtime";
          inherit development;
        };
        config = {
          schemaVersion = 1;
          descriptorSchemaVersion = descriptor.schemaVersion;
          inherit runtimeSchemaVersion;
          inherit (descriptor) project;
          realization = "development";
          actions = checkedActions;
          endpoints = builtins.attrNames development.endpoints;
          endpointProtocols = lib.mapAttrs (_: endpoint: endpoint.protocol) development.endpoints;
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
            test -f ${package}/share/project/bundle.json
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
        [ effectiveDefaultAction ]
        ++ map (task: task.action) (lib.attrValues release.preDeployTasks)
        ++ map (job: job.action) (lib.attrValues release.maintenanceJobs)
        ++ map (command: command.action) (lib.attrValues release.commands)
      );
      checkedActions =
        requireExactActions "mkServiceRelease.actions" expectedActions
          (builtins.attrNames normalizedActions)
          normalizedActions;
      activationExecutable = release.activationExecutable;
      activationAction =
        if activation == null then null else executableFor "mkServiceRelease.activation" activation;
      auxiliaryEndpoints = lib.mapAttrs (
        auxiliaryName: auxiliary: lib.mapAttrs (portName: _: "${auxiliaryName}-${portName}") auxiliary.ports
      ) release.ociAuxiliaries;
      flattenedAuxiliaryEndpoints = lib.concatLists (
        lib.mapAttrsToList (_: ports: builtins.attrValues ports) auxiliaryEndpoints
      );
      releaseEndpoints = [ release.action ] ++ flattenedAuxiliaryEndpoints;
      releaseEndpointProtocols = {
        ${release.action} = "http";
      }
      // lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            auxiliaryName: auxiliary:
            lib.mapAttrsToList (portName: port: {
              name = auxiliaryEndpoints.${auxiliaryName}.${portName};
              value = port.protocol;
            }) auxiliary.ports
          ) release.ociAuxiliaries
        )
      );
      runtimePackage = mkRuntimePackage {
        inherit pkgs activationExecutable;
        name = "${descriptor.project}-release-runtime";
        mainProgram = release.executable;
        config = {
          schemaVersion = 1;
          descriptorSchemaVersion = descriptor.schemaVersion;
          inherit (descriptor) project;
          realization = "release";
          actions = checkedActions;
          defaultAction = effectiveDefaultAction;
          activation = activationAction;
          parameterDefinitions = descriptor.parameters;
          secrets = builtins.attrNames descriptor.secrets;
          inherit auxiliaryEndpoints;
        }
        // lib.optionalAttrs (descriptor.schemaVersion >= 2) {
          endpoints = releaseEndpoints;
          endpointProtocols = releaseEndpointProtocols;
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
