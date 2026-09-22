# Release artifact builders. Every helper takes the normalized descriptor from
# `lib.projectDefinition` and embeds it at share/project/descriptor.json.
{ lib }:
let
  fail = context: message: throw "project runtime ${context}: ${message}";

  # One Go binary serves release actions, development context queries and
  # host-side release planning.
  package =
    pkgs:
    pkgs.buildGoModule {
      pname = "project-runtime";
      version = "2";
      src = ./project-runtime/runtime;
      vendorHash = null;
      env.CGO_ENABLED = 0;
      ldflags = [
        "-s"
        "-w"
      ];
      meta.mainProgram = "project-runtime";
    };

  executableFor =
    context: value:
    if builtins.isString value || builtins.isPath value then
      toString value
    else if lib.isDerivation value then
      lib.getExe value
    else
      fail context "must be an executable path or package";
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
  descriptorFile =
    pkgs: descriptor:
    pkgs.writeTextDir "share/project/descriptor.json" (builtins.toJSON descriptor + "\n");

  # Wraps the runtime with a configuration; `project-context` answers queries
  # about the running instance.
  mkRuntimeWrapper =
    {
      pkgs,
      name,
      mainProgram,
      config,
      activationExecutable ? null,
    }:
    let
      configFile = pkgs.writeText "${name}-runtime-config.json" (builtins.toJSON config + "\n");
      runtime = lib.getExe (package pkgs);
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = mainProgram;
      }
      ''
        makeWrapper ${runtime} $out/bin/${mainProgram} \
          --add-flags "run --config ${configFile}" \
          --prefix PATH : "$out/bin"
        makeWrapper ${runtime} $out/bin/project-context \
          --add-flags "context --config ${configFile}" \
          --prefix PATH : "$out/bin"
        ${lib.optionalString (activationExecutable != null) ''
          makeWrapper ${runtime} $out/bin/${activationExecutable} \
            --add-flags "activate --config ${configFile}" \
            --prefix PATH : "$out/bin"
        ''}
      '';

  # Runtime configuration shared by release and development context queries.
  contextConfig =
    {
      descriptor,
      realization,
      endpointProtocols,
    }:
    {
      schemaVersion = 2;
      inherit (descriptor) project;
      inherit realization endpointProtocols;
      parameterDefinitions = descriptor.parameters;
      secrets = builtins.attrNames descriptor.secrets;
      requirements = descriptor.requirements;
      environment =
        descriptor.environment.${realization} or {
          common = { };
          actions = { };
        };
    };
in
{
  inherit package;

  # A `project-context` executable for a development instance.
  developmentContext =
    { pkgs, descriptor }:
    mkRuntimeWrapper {
      inherit pkgs;
      name = "${descriptor.project}-development-context";
      mainProgram = "project-context";
      config = contextConfig {
        inherit descriptor;
        realization = "development";
        endpointProtocols = lib.mapAttrs (_: endpoint: endpoint.protocol) descriptor.development.endpoints;
      };
    };

  mkServiceRelease =
    {
      pkgs,
      descriptor,
      payloads ? [ ],
      actions,
      activation ? null,
    }:
    let
      release =
        if descriptor.release == null || descriptor.release.backend != "service" then
          fail "mkServiceRelease" "descriptor does not declare a service Release"
        else
          descriptor.release;
      normalizedActions = lib.mapAttrs (name: value: executableFor "actions.${name}" value) actions;
      expectedActions = lib.unique (
        [ release.action ]
        ++ map (entry: entry.action) (
          lib.attrValues release.preDeployTasks
          ++ lib.attrValues release.maintenanceJobs
          ++ lib.attrValues release.commands
        )
      );
      checkedActions =
        requireExactActions "mkServiceRelease.actions" expectedActions
          (builtins.attrNames normalizedActions)
          normalizedActions;
      auxiliaryEndpoints = lib.mapAttrs (
        auxiliaryName: auxiliary: lib.mapAttrs (portName: _: "${auxiliaryName}-${portName}") auxiliary.ports
      ) release.ociAuxiliaries;
      endpointProtocols = {
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
      runtime = mkRuntimeWrapper {
        inherit pkgs;
        inherit (release) activationExecutable;
        name = "${descriptor.project}-release-runtime";
        mainProgram = release.executable;
        config =
          contextConfig {
            inherit descriptor endpointProtocols;
            realization = "release";
          }
          // {
            actions = checkedActions;
            defaultAction = release.action;
            activation =
              if activation == null then null else executableFor "mkServiceRelease.activation" activation;
            inherit auxiliaryEndpoints;
          };
      };
      releasePackage = pkgs.symlinkJoin {
        name = "${descriptor.project}-project-release";
        paths = payloads ++ [
          runtime
          (descriptorFile pkgs descriptor)
        ];
        meta.mainProgram = release.executable;
      };
    in
    if (activation == null) != (release.activationExecutable == null) then
      fail "mkServiceRelease.activation" "must be present exactly when release.activationExecutable is declared"
    else
      {
        package = releasePackage;
        checks.interface = pkgs.runCommand "${descriptor.project}-release-runtime-interface" { } ''
          test -x ${releasePackage}/bin/${release.executable}
          test -x ${releasePackage}/bin/project-context
          ${lib.optionalString (
            release.activationExecutable != null
          ) "test -x ${releasePackage}/bin/${release.activationExecutable}"}
          touch $out
        '';
      };

  mkStaticRelease =
    {
      pkgs,
      descriptor,
      root,
    }:
    if descriptor.release == null || descriptor.release.backend != "static" then
      fail "mkStaticRelease" "descriptor does not declare a static Release"
    else
      {
        package = pkgs.symlinkJoin {
          name = "${descriptor.project}-project-release";
          paths = [
            root
            (descriptorFile pkgs descriptor)
          ];
        };
        checks = { };
      };
}
