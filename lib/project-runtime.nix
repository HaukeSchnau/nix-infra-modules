{ lib }:
let
  projectDescriptor = import ./project-descriptor.nix { inherit lib; };
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
      activationExecutable ? null,
      disallowedRequisites ? [ ],
    }:
    let
      configFile = pkgs.writeText "${name}-runtime-config.json" (builtins.toJSON config + "\n");
      runtimeExecutable = lib.getExe (releaseRuntimeImplementation pkgs);
      runtimeArguments = "--config ${configFile}";
    in
    pkgs.runCommand name
      {
        inherit disallowedRequisites;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = mainProgram;
      }
      ''
        makeWrapper ${runtimeExecutable} $out/bin/${mainProgram} \
          --add-flags "${runtimeArguments}" \
          --prefix PATH : "$out/bin"
        makeWrapper ${runtimeExecutable} $out/bin/project-context \
          --add-flags "${runtimeArguments} context" \
          --prefix PATH : "$out/bin"
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
  mkServiceRelease =
    args@{
      pkgs,
      descriptor ? null,
      descriptorPath ? pkgs.writeText "project.json" (builtins.toJSON args.descriptor + "\n"),
      payloads ? [ ],
      actions,
      defaultAction ? null,
      activation ? null,
    }:
    assert lib.assertMsg (
      (args ? descriptor) != (args ? descriptorPath)
    ) "project runtime: provide exactly one of descriptor or descriptorPath";
    let
      raw = if (args.descriptor or null) == null then rawDescriptor descriptorPath else args.descriptor;
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
          requirements = descriptor.requirements or { };
          environment = descriptor.environment.release or { };
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
    args@{
      pkgs,
      descriptor ? null,
      descriptorPath ? pkgs.writeText "project.json" (builtins.toJSON args.descriptor + "\n"),
      root,
    }:
    assert lib.assertMsg (
      (args ? descriptor) != (args ? descriptorPath)
    ) "project runtime: provide exactly one of descriptor or descriptorPath";
    let
      raw = if (args.descriptor or null) == null then rawDescriptor descriptorPath else args.descriptor;
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
