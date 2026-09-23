# Host policy for Projects: where each repository's contract runs, with which
# secrets, parameters, hostnames and resources. Development instances are
# managed at runtime by the `project` controller from a catalog written here;
# releases become app-deployments. Requires the fleet, appDeployments and
# caddyIngress modules; sops-nix and Home Manager are used when present.
# See docs/modules/projects.md.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.projects;
  serviceCfg = config.vps.services.projects;
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };
  projectDescriptor = import ../../../lib/project-descriptor.nix { inherit lib; };
  projectRuntime = import ../../../lib/project-runtime.nix { inherit lib; };
  hasSops = options ? sops;
  hasHomeManager = options ? home-manager;
  inherit (lib) mkOption types;
  namePattern = "^[a-z0-9][a-z0-9-]{0,62}$";
  hostNameType = types.strMatching "^[A-Za-z0-9][A-Za-z0-9.-]*$";

  secretType = types.submodule {
    options = {
      sopsKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "SOPS key; ownership and restarts follow the consumer.";
      };
      path = mkOption {
        type = types.nullOr (types.strMatching "^/.*");
        default = null;
        description = "A secret file not managed through SOPS.";
      };
    };
  };
  secretsOption = mkOption {
    type = types.attrsOf secretType;
    default = { };
    description = "Bindings for secret requirements, by requirement name.";
  };
  parametersOption = mkOption {
    type = types.attrsOf types.unspecified;
    default = { };
    description = "Values for the repository's parameters.";
  };

  developmentType = types.submodule {
    options = {
      parameters = parametersOption;
      secrets = secretsOption;
      idleTimeoutSec = mkOption {
        type = types.ints.positive;
        default = 30 * 60;
        description = "How long an endpoint stays warm after its last connection closes.";
      };
    };
  };

  jobScheduleType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      calendar = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "systemd OnCalendar expression overriding the repository schedule.";
      };
      interval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Interval overriding the repository schedule.";
      };
      cadence = mkOption {
        type = types.nullOr (
          types.enum [
            "fixed"
            "spaced"
          ]
        );
        default = null;
      };
      onBootSec = mkOption {
        type = types.str;
        default = "5min";
      };
      randomizedDelaySec = mkOption {
        type = types.str;
        default = "0";
      };
      persistent = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  releaseType = types.submodule {
    options = {
      instance = mkOption {
        type = types.strMatching namePattern;
        default = "default";
        description = "Placement identity; other than default it prefixes the generated hostname.";
      };
      endpoint = {
        hostName = mkOption {
          type = types.nullOr hostNameType;
          default = null;
          description = "Canonical hostname; defaults to <project>.<releaseDomain>.";
        };
        aliases = mkOption {
          type = types.listOf hostNameType;
          default = [ ];
          description = "Hostnames redirected to the canonical one.";
        };
        visibility = mkOption {
          type = types.enum [
            "tailnet"
            "public"
          ];
          default = "tailnet";
        };
      };
      delivery = {
        mode = mkOption {
          type = types.enum [
            "source"
            "cache"
          ];
          default = "source";
          description = "Build releases from source, or realize the CI-built output.";
        };
        cacheStore = mkOption {
          type = types.nullOr types.str;
          default = serviceCfg.releaseCacheStore;
          defaultText = lib.literalExpression "config.vps.services.projects.releaseCacheStore";
          description = "Binary cache holding CI-promoted outputs for cache delivery.";
        };
      };
      exposeRevision = mkOption {
        type = types.bool;
        default = false;
        description = "Expose the promoted revision through `project-context revision`.";
      };
      providers = mkOption {
        type = types.attrsOf (types.enum [ "host-postgresql" ]);
        default = { };
        description = "Host providers for requirements; host-postgresql creates a database owned by the release user with nightly backups.";
      };
      parameters = parametersOption;
      secrets = secretsOption;
      jobs = mkOption {
        type = types.attrsOf jobScheduleType;
        default = { };
        description = "Schedules for the repository's maintenance jobs.";
      };
      resources.memory = lib.genAttrs [ "high" "max" "swapMax" ] (
        _:
        mkOption {
          type = types.nullOr types.str;
          default = null;
        }
      );
      unitDependencies = lib.genAttrs [ "after" "wants" "requires" ] (
        _:
        mkOption {
          type = types.listOf types.str;
          default = [ ];
        }
      );
      approvedOci = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "The repository's OCI auxiliaries this host agrees to run.";
      };
      environment = mkOption {
        type = types.attrsOf types.unspecified;
        default = { };
      };
      environmentFiles = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      path = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      runtime = {
        isolation = mkOption {
          type = types.enum [
            "isolated"
            "trusted"
          ];
          default = "isolated";
          description = "trusted runs actions as the configured user without the systemd sandbox.";
        };
        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Existing user for release actions; null creates app-<project>.";
        };
        group = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        home = mkOption {
          type = types.nullOr (types.strMatching "^/.*");
          default = null;
        };
        workingDirectory = mkOption {
          type = types.nullOr (types.strMatching "^/.*");
          default = null;
        };
        protectHome = mkOption {
          type = types.bool;
          default = true;
        };
        readWritePaths = mkOption {
          type = types.listOf (types.strMatching "^/.*");
          default = [ ];
        };
      };
    };
  };

  projectType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      source = mkOption {
        type = types.path;
        description = "The pinned repository, usually a flake input, whose contract this host runs.";
      };
      repository = {
        remote = mkOption {
          type = types.str;
          description = "Name of a vps.services.projects.repositoryRemotes profile.";
        };
        path = mkOption {
          type = types.strMatching "^[^/].*";
          description = "Repository path on the remote.";
        };
        branch = mkOption {
          type = types.str;
          default = "main";
        };
        checkout = {
          owner = mkOption {
            type = types.str;
            default = serviceCfg.defaultOwner;
            defaultText = lib.literalExpression "config.vps.services.projects.defaultOwner";
          };
          path = mkOption {
            type = types.nullOr (types.strMatching "^[^/].*");
            default = null;
            description = "Checkout path in the owner's home; defaults to Code/<project> with development.";
          };
        };
      };
      development = mkOption {
        type = types.nullOr developmentType;
        default = { };
        description = "Development policy; null for a release-only placement.";
      };
      release = mkOption {
        type = types.nullOr releaseType;
        default = { };
        description = "Release policy; null for a development-only placement.";
      };
    };
  };

  resolvedReleaseType = types.submodule {
    options = {
      instance = mkOption { type = types.str; };
      instanceId = mkOption { type = types.str; };
      bindings = mkOption { type = types.attrsOf types.attrs; };
      backend = mkOption {
        type = types.enum [
          "service"
          "static"
        ];
      };
      package = mkOption { type = types.str; };
      executable = mkOption { type = types.nullOr types.str; };
      action = mkOption { type = types.nullOr types.str; };
      health = mkOption { type = types.attrsOf types.unspecified; };
      hostName = mkOption { type = hostNameType; };
      aliases = mkOption { type = types.listOf hostNameType; };
      visibility = mkOption {
        type = types.enum [
          "tailnet"
          "public"
        ];
      };
      parameters = mkOption { type = types.attrsOf types.unspecified; };
      secrets = mkOption {
        type = types.attrsOf (types.submodule { options.path = mkOption { type = types.str; }; });
      };
      unitDependencies = mkOption { type = types.attrsOf (types.listOf types.str); };
    };
  };

  enabledProjects = lib.filterAttrs (_: project: project.enable) cfg;
  developmentProjects = lib.filterAttrs (_: project: project.development != null) enabledProjects;
  releaseProjects = lib.filterAttrs (_: project: project.release != null) enabledProjects;

  # Contracts come from each Project's pinned source: the devenv bundle when
  # the repository has devenv.nix, otherwise its flake's lib.project.
  projectInput = name: cfg.${name}.source;
  bundles =
    lib.mapAttrs
      (
        name: _:
        import ./devenv.nix {
          inherit pkgs managerSource;
          inherit projectRuntime;
          inherit (serviceCfg) devenv;
          project = projectInput name;
          hostname = config.networking.hostName;
          username = cfg.${name}.repository.checkout.owner;
        }
      )
      (
        lib.filterAttrs (name: _: builtins.pathExists (projectInput name + "/devenv.nix")) enabledProjects
      );
  descriptors = lib.mapAttrs (
    name: _:
    projectDescriptor.normalize {
      descriptor =
        if bundles ? ${name} then bundles.${name}.descriptor else (projectInput name).lib.project;
      expectedProject = name;
    }
  ) enabledProjects;

  managerSource = ./controller/project_controller/devenv_manager.py;
  materializedSecretName =
    name: realization: secret:
    "projects/${name}/${realization}/${secret}";
  secretPath =
    name: realization: secretName: secret:
    if secret.path != null then
      secret.path
    else if hasSops then
      config.sops.secrets.${materializedSecretName name realization secretName}.path
    else
      throw "projects.${name}: secret ${secretName} uses sopsKey, but sops-nix is not imported";
  secretPaths =
    name: realization: secrets:
    lib.mapAttrs (secretName: secret: secretPath name realization secretName secret) secrets;

  releaseUser =
    name: project:
    if project.release.runtime.user == null then "app-${name}" else project.release.runtime.user;
  releaseGroup =
    name: project:
    if project.release.runtime.group == null then
      releaseUser name project
    else
      project.release.runtime.group;
  defaultReleaseHostName =
    name: project:
    lib.optionalString (project.release.instance != "default") "${project.release.instance}."
    + "${name}.${serviceCfg.releaseDomain}";
  releaseHostName =
    name: project:
    if project.release.endpoint.hostName == null then
      defaultReleaseHostName name project
    else
      project.release.endpoint.hostName;
  releaseAliases =
    name: project:
    lib.unique (
      project.release.endpoint.aliases
      ++ lib.optional (releaseHostName name project != defaultReleaseHostName name project) (
        defaultReleaseHostName name project
      )
    );
  postgresqlMajor = lib.toInt (lib.versions.major config.services.postgresql.package.version);
  # Host-allocated resources; secret requirements are bound by releaseApp.
  releaseBindings =
    name: project:
    let
      user = releaseUser name project;
      socket = config.services.postgresql.settings.unix_socket_directories or "/run/postgresql";
      port = config.services.postgresql.settings.port;
    in
    lib.filterAttrs (_: binding: binding != null) (
      lib.mapAttrs (
        requirementName: requirement:
        if project.release.providers.${requirementName} or null == "host-postgresql" then
          {
            kind = "postgresql";
            majorVersion = postgresqlMajor;
            host = socket;
            inherit port user;
            database = user;
            url = "postgresql:///${user}?host=${socket}&port=${toString port}";
          }
        else if requirement.kind == "directory" then
          {
            kind = "directory";
            inherit (requirement) persistent;
            path =
              if requirement.persistent then
                "/var/lib/app-deployments/${name}/runtime/${requirement.path}"
              else
                "/run/project-release/${name}/${requirement.path}";
          }
        else
          null
      ) (projectDescriptor.forRealization "release" descriptors.${name}.requirements)
    );
  postgresUsers = lib.unique (
    lib.mapAttrsToList releaseUser (
      lib.filterAttrs (_: project: project.release.providers != { }) releaseProjects
    )
  );
  releaseDependencies =
    project:
    project.release.unitDependencies
    // {
      requires = lib.unique (
        project.release.unitDependencies.requires
        ++ lib.optional (project.release.providers != { }) "postgresql.service"
      );
    };
  releaseApps = lib.mapAttrs (
    name: project:
    let
      policy = project.release;
      credential = credentialProfile name project;
    in
    projectDescriptor.releaseApp {
      descriptor = descriptors.${name};
      policy = {
        project = name;
        instanceId = "${name}:release:${config.networking.hostName}:${policy.instance}";
        bindings = releaseBindings name project;
        source = {
          url = "${(repositoryRemote name project).releaseUrlPrefix}${project.repository.path}";
          inherit (project.repository) branch;
        }
        // lib.optionalAttrs (credential != null) {
          inherit (credential) netrcHost username;
          giteaTokenSecretName = credential.tokenSecretName;
        };
        domain = releaseHostName name project;
        public = policy.endpoint.visibility == "public";
        secrets = secretPaths name "release" policy.secrets;
        inherit (policy)
          approvedOci
          delivery
          environment
          environmentFiles
          exposeRevision
          jobs
          parameters
          path
          resources
          runtime
          ;
      };
    }
    // {
      unitDependencies = releaseDependencies project;
      stateDirs = map (binding: binding.path) (
        lib.attrValues (
          lib.filterAttrs (_: binding: binding.kind == "directory") (releaseBindings name project)
        )
      );
    }
  ) releaseProjects;
  resolvedReleases = lib.mapAttrs (
    name: project:
    let
      app = releaseApps.${name};
    in
    {
      inherit (project.release) instance;
      inherit (app.project) instanceId bindings parameters;
      inherit (app)
        backend
        executable
        health
        package
        unitDependencies
        ;
      inherit (descriptors.${name}.release) action;
      secrets = lib.mapAttrs (_: path: { inherit path; }) app.project.secrets;
      hostName = releaseHostName name project;
      aliases = releaseAliases name project;
      visibility = project.release.endpoint.visibility;
    }
  ) releaseProjects;

  # What development looks like with this host's policy, for the fleet
  # topology and assertions. The controller resolves the rest at runtime.
  resolvedDevelopments = lib.mapAttrs (
    name: project:
    let
      development = descriptors.${name}.development;
      bound = lib.filter (secretName: project.development.secrets ? ${secretName});
    in
    {
      workloads = lib.mapAttrs (_: workload: {
        inherit (workload) dependsOn;
        secrets = bound workload.secrets;
      }) development.workloads;
      endpoints = lib.mapAttrs (_: endpoint: {
        inherit (endpoint) protocol workload;
        visibility =
          if endpoint.protocol == "tcp" || endpoint.publication == "private" then "local" else "tailnet";
      }) development.endpoints;
      secrets = project.development.secrets;
      preparation.secrets = bound development.preparation.secrets;
    }
  ) developmentProjects;

  repositoryRemote =
    name: project:
    serviceCfg.repositoryRemotes.${project.repository.remote}
      or (throw "projects.${name}: unknown repository remote ${project.repository.remote}");
  credentialProfile =
    name: project:
    let
      profile = (repositoryRemote name project).credentialProfile;
    in
    if profile == null then
      null
    else
      serviceCfg.repositoryCredentials.${profile}
        or (throw "projects.${name}: unknown credential profile ${profile}");
  checkoutUrl =
    name: project: "${(repositoryRemote name project).checkoutUrlPrefix}${project.repository.path}";
  checkoutRelativePath =
    name: project:
    if project.repository.checkout.path != null then
      project.repository.checkout.path
    else if project.development != null then
      "Code/${name}"
    else
      null;
  checkoutProjects = lib.filterAttrs (
    name: project: checkoutRelativePath name project != null
  ) enabledProjects;
  ownerHome = owner: config.users.users.${owner}.home or "/home/${owner}";
  owners = lib.unique (
    map (project: project.repository.checkout.owner) (lib.attrValues developmentProjects)
  );
  ownerUid = owner: toString config.users.users.${owner}.uid;
  controllerStateDir = owner: "/var/lib/project-development/${owner}";
  catalogPath = owner: "/etc/projects/catalog-${owner}.json";

  # Secrets become SOPS files owned by whoever reads them.
  secretRecords = lib.concatLists (
    lib.mapAttrsToList (
      name: project:
      let
        records =
          realization: consumer: secrets:
          lib.mapAttrsToList (secretName: secret: {
            inherit consumer secret;
            name = materializedSecretName name realization secretName;
          }) secrets;
      in
      lib.optionals (project.development != null) (
        records "development" {
          user = project.repository.checkout.owner;
          group = "users";
          restartUnits = [ "project-development-${project.repository.checkout.owner}-reconcile.service" ];
        } project.development.secrets
      )
      ++ lib.optionals (project.release != null) (
        records "release" {
          user = releaseUser name project;
          group = releaseGroup name project;
          restartUnits = [ "app-deployment-${name}.service" ];
        } project.release.secrets
      )
    ) enabledProjects
  );
  projectSopsSecrets = lib.listToAttrs (
    map (
      record:
      lib.nameValuePair record.name {
        key = record.secret.sopsKey;
        owner = record.consumer.user;
        group = record.consumer.group;
        mode = "0400";
        inherit (record.consumer) restartUnits;
      }
    ) (lib.filter (record: record.secret.sopsKey != null) secretRecords)
  );

  controller = pkgs.callPackage ./controller/package.nix { };
  projectCli = pkgs.writeShellApplication {
    name = "project";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.git
      pkgs.jujutsu
      pkgs.nix
      pkgs.systemd
    ];
    text = ''
      uid="$(id -u)"
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$uid}"
      export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
      export PROJECT_DEVELOPMENT_CATALOG="''${PROJECT_DEVELOPMENT_CATALOG:-/etc/projects/catalog-$(id -un).json}"
      exec ${lib.getExe controller} "$@"
    '';
  };

  # Builds a checkout's bundle (SOURCE OUT-LINK) or exports its contract
  # (SOURCE --export) with this host's devenv and SDK, as the calling user.
  bundleBuilder = pkgs.writeShellApplication {
    name = "project-development-bundle";
    runtimeInputs = [ pkgs.nix ];
    text = ''
      source="$1"
      if [[ "''${2:-}" == --export ]]; then
        exec nix build --no-link --print-out-paths --impure --file ${bundleExpression} \
          --argstr source "$source" --arg exportOnly true
      fi
      exec nix build --out-link "$2" --print-out-paths --impure --file ${bundleExpression} \
        --argstr source "$source" --argstr username "$(id -un)"
    '';
  };
  devenvPackages = serviceCfg.devenv.packages.${pkgs.stdenv.hostPlatform.system};
  bundleExpression = pkgs.writeText "project-development-bundle.nix" ''
    { source, username ? null, exportOnly ? false }:
    let
      system = "${pkgs.stdenv.hostPlatform.system}";
      pkgs = import ${pkgs.path} { inherit system; };
      host = name: path: (pkgs.lib.toDerivation path) // { meta.mainProgram = name; };
      bundle = import ${./devenv.nix} {
        inherit pkgs username;
        project.outPath = source;
        managerSource = ${managerSource};
        projectRuntime = import ${../../../lib}/project-runtime.nix { inherit (pkgs) lib; };
        hostname = "${config.networking.hostName}";
        # Keep the host's exact devenv binaries; rebuilding them from the
        # source path would lose revision metadata and recompile the CLI.
        devenv = {
          outPath = "${serviceCfg.devenv}";
          packages.''${system} = {
            devenv = host "devenv" "${devenvPackages.devenv}" // { version = "${devenvPackages.devenv.version}"; };
            devenv-tasks = host "devenv-tasks" "${devenvPackages.devenv-tasks}";
          };
        };
      };
    in
    if exportOnly then bundle.contractFile else bundle
  '';

  catalog =
    owner:
    pkgs.writeText "project-development-catalog-${owner}.json" (
      builtins.toJSON (
        {
          schemaVersion = 2;
          catalogFile = catalogPath owner;
          controllerExecutable = lib.getExe projectCli;
          socketProxyExecutable = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd";
          systemdUnitRoot = "/run/user/${ownerUid owner}/systemd/user";
          workspaceHostGateway = serviceCfg.workspaces.hostGateway;
          bundleBuilder = lib.getExe bundleBuilder;
          developmentDomain = "${serviceCfg.developmentLabel}.${config.vps.baseDomain}";
          inherit (serviceCfg) portRange missingGraceSec garbageCollectAfterSec;
          idleTimeoutSec = 30 * 60;
          stateRoot = "/var/lib/projects";
          cacheRoot = "/var/cache/projects";
          runtimeRoot = "/run/user/${ownerUid owner}/project-development";
          registryFile = "${controllerStateDir owner}/instances.json";
          routeSourceFile = "${controllerStateDir owner}/routes.json";
        }
        // lib.optionalAttrs (serviceCfg.workspaces.launcher != null) {
          workspaceLauncher = serviceCfg.workspaces.launcher;
        }
        // {
          # Unenrolled repositories under ~/Code may run with generated resources.
          developmentGrants = {
            workspaces = serviceCfg.workspaces.launcher != null;
            checkoutRoots = [ "${ownerHome owner}/Code" ];
            resourceKinds = [
              "directory"
              "postgresql"
            ];
            stateRoot = "${controllerStateDir owner}/projects";
            cacheRoot = "${ownerHome owner}/.cache/project-development";
            inherit owner;
            group = "users";
          };
          projects = lib.mapAttrs (name: project: {
            inherit (project.repository.checkout) owner;
            group = "users";
            repository = {
              url = checkoutUrl name project;
              checkout = "${ownerHome owner}/${checkoutRelativePath name project}";
            };
            pinnedBundle = if bundles ? ${name} then "${bundles.${name}}" else null;
            canonical = true;
            policy = {
              inherit (project.development) parameters idleTimeoutSec;
              secrets = lib.mapAttrs (_: path: { inherit path; }) (
                secretPaths name "development" project.development.secrets
              );
              endpoints = { };
            };
          }) (lib.filterAttrs (_: project: project.repository.checkout.owner == owner) developmentProjects);
        }
      )
      + "\n"
    );

  checkoutService =
    name: project:
    let
      owner = project.repository.checkout.owner;
    in
    lib.nameValuePair "project-${name}-checkout" {
      description = "Reconcile Project ${name} Checkout";
      after = [
        "home-manager-${owner}.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      environment.HOME = ownerHome owner;
      serviceConfig = {
        Type = "oneshot";
        User = owner;
        Group = "users";
        ExecStart = "${
          lib.getExe config.home-manager.users.${owner}.workspaceRepos.package
        } sync --timeout 240 --path ${lib.escapeShellArg (checkoutRelativePath name project)}";
        TimeoutStartSec = 300;
      };
    };
  controllerService =
    owner:
    let
      uid = ownerUid owner;
      checkouts = lib.optionals hasHomeManager (
        map (name: "project-${name}-checkout.service") (
          lib.attrNames (
            lib.filterAttrs (_: project: project.repository.checkout.owner == owner) developmentProjects
          )
        )
      );
    in
    lib.nameValuePair "project-development-${owner}-reconcile" {
      description = "Reconcile Project Development Instances for ${owner}";
      after = [
        "network-online.target"
        "user@${uid}.service"
      ]
      ++ checkouts;
      wants = [
        "network-online.target"
        "user@${uid}.service"
      ];
      requires = checkouts;
      environment = {
        HOME = ownerHome owner;
        XDG_RUNTIME_DIR = "/run/user/${uid}";
        DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${uid}/bus";
        PROJECT_DEVELOPMENT_CATALOG = catalogPath owner;
      };
      serviceConfig = {
        Type = "oneshot";
        User = owner;
        Group = "users";
        ExecStart = "${lib.getExe projectCli} dev reconcile";
        TimeoutStartSec = 1800;
        UMask = "0077";
      };
    };

  repositoryUrls = lib.mapAttrsToList checkoutUrl enabledProjects;
  checkoutPaths = lib.mapAttrsToList checkoutRelativePath checkoutProjects;
  releaseHostNames = lib.concatLists (
    lib.mapAttrsToList (
      name: project: [ (releaseHostName name project) ] ++ releaseAliases name project
    ) releaseProjects
  );
in
{
  options = {
    projects = mkOption {
      type = types.attrsOf projectType;
      default = { };
      description = "Projects placed on this host.";
    };

    vps.services.projects = {
      enable = lib.mkEnableOption "declarative Project realizations";
      repositoryCredentials = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              netrcHost = mkOption { type = types.str; };
              username = mkOption {
                type = types.str;
                default = "deploy";
              };
              tokenSecretName = mkOption {
                type = types.str;
                description = "SOPS secret with a repository read token.";
              };
            };
          }
        );
        default = { };
      };
      repositoryRemotes = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              checkoutUrlPrefix = mkOption { type = types.str; };
              releaseUrlPrefix = mkOption {
                type = types.str;
                description = "Nix-fetchable URL prefix for release sources.";
              };
              credentialProfile = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
            };
          }
        );
        default = { };
      };
      portRange = {
        from = mkOption {
          type = types.port;
          default = 21000;
        };
        to = mkOption {
          type = types.port;
          default = 21999;
        };
      };
      developmentLabel = mkOption {
        type = types.strMatching "^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$";
        default = "dev";
        description = "DNS label under the base domain for development hostnames.";
      };
      releaseDomain = mkOption {
        type = types.str;
        default = config.vps.baseDomain;
      };
      missingGraceSec = mkOption {
        type = types.ints.positive;
        default = 3600;
        description = "How long a missing ad-hoc checkout may stay absent before its instance stops.";
      };
      garbageCollectAfterSec = mkOption {
        type = types.ints.positive;
        default = 7 * 24 * 60 * 60;
        description = "How long a missing ad-hoc checkout may stay absent before its instance is retired.";
      };
      resolvedReleases = mkOption {
        type = types.attrsOf resolvedReleaseType;
        internal = true;
        readOnly = true;
      };
      resolvedDevelopments = mkOption {
        type = types.attrsOf types.unspecified;
        internal = true;
        readOnly = true;
      };
      defaultOwner = mkOption {
        type = types.str;
        description = "User whose home holds checkouts and who runs development instances.";
      };
      devenv = mkOption {
        type = types.raw;
        description = ''
          The devenv flake (cachix/devenv) whose CLI and bootstrap build prepared
          bundles. The devenv manager is pinned to its 2.3.1 protocol.
        '';
      };
      releaseCacheStore = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default binary cache for cache-delivered releases.";
      };
      workspaces = {
        launcher = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Workspace runtime that isolates ad-hoc checkouts (`environment`,
            `bind-project`, `unbind-project` and `project-run` commands). Without
            one, workspaces run directly on the host.
          '';
        };
        hostGateway = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "10.0.2.2";
          description = "Address at which a workspace reaches the host's loopback services; loopback URLs in parameters are rewritten to it.";
        };
      };
      routeSources = mkOption {
        type = types.attrsOf types.attrs;
        readOnly = true;
        description = "Per-owner files listing development routes for an ingress to publish.";
      };
      metadata = serviceMetadata.mkOptions {
        displayName = "Projects";
        category = "Applications";
      };
    };
  };

  config = lib.mkMerge [
    {
      vps.services.projects = {
        enable = lib.mkDefault (enabledProjects != { });
        inherit resolvedReleases resolvedDevelopments;
        routeSources = lib.genAttrs owners (owner: {
          registryFile = "${controllerStateDir owner}/routes.json";
          inherit (serviceCfg) portRange;
        });
      };
      vps.services.appDeployments.enable = lib.mkDefault (releaseProjects != { });
    }
    (lib.mkIf (config.vps.enable && serviceCfg.enable) {
      assertions = [
        {
          assertion = serviceCfg.portRange.from <= serviceCfg.portRange.to;
          message = "vps.services.projects.portRange.from must be <= portRange.to.";
        }
        {
          assertion = lib.allUnique repositoryUrls;
          message = "Each Project must own a unique repository URL.";
        }
        {
          assertion = lib.allUnique checkoutPaths;
          message = "Project checkout paths must be unique on a host.";
        }
        {
          assertion = lib.allUnique releaseHostNames;
          message = "Project release hostnames must be unique on a host.";
        }
        {
          assertion =
            lib.all (range: serviceCfg.portRange.to < range.from || serviceCfg.portRange.from > range.to)
              [
                config.vps.appDeployments.projectPortRange
                config.vps.appDeployments.projectAuxiliaryPortRange
              ];
          message = "The Project Development port range must not overlap the release port ranges.";
        }
        {
          assertion = serviceCfg.garbageCollectAfterSec > serviceCfg.missingGraceSec;
          message = "Project Development garbage collection must occur after the missing-checkout grace.";
        }
        {
          assertion =
            serviceCfg.releaseDomain == config.vps.baseDomain
            || lib.hasSuffix ".${config.vps.baseDomain}" serviceCfg.releaseDomain;
          message = "vps.services.projects.releaseDomain must be the base domain or beneath it.";
        }
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: project:
          let
            descriptor = descriptors.${name};
            required =
              realization: bound:
              lib.filter (secretName: !(bound ? ${secretName})) (
                lib.attrNames (
                  lib.filterAttrs (
                    _: requirement:
                    requirement.kind == "secret" && requirement.required && requirement.generate or null == null
                  ) (projectDescriptor.forRealization realization descriptor.requirements)
                )
              );
            secrets =
              (if project.development == null then { } else project.development.secrets)
              // (if project.release == null then { } else project.release.secrets);
          in
          [
            {
              assertion = builtins.match namePattern name != null;
              message = "projects.${name}: Project names must be lowercase kebab-case and at most 63 characters.";
            }
            {
              assertion = project.development == null || descriptor.development != null;
              message = "projects.${name}: the repository declares no development.";
            }
            {
              assertion = project.release == null || descriptor.release != null;
              message = "projects.${name}: the repository declares no release.";
            }
            {
              assertion =
                project.development == null || required "development" project.development.secrets == [ ];
              message = "projects.${name}.development.secrets: missing ${lib.concatStringsSep ", " (required "development" project.development.secrets)}.";
            }
            {
              assertion =
                project.release == null
                || lib.all (
                  requirementName:
                  let
                    requirement = descriptor.requirements.${requirementName} or { };
                  in
                  requirement.kind or null == "postgresql" && builtins.elem postgresqlMajor requirement.majorVersions
                ) (lib.attrNames project.release.providers);
              message = "projects.${name}.release.providers must satisfy declared PostgreSQL versions.";
            }
            {
              assertion = lib.all (secret: (secret.path == null) != (secret.sopsKey == null)) (
                lib.attrValues secrets
              );
              message = "projects.${name}: every secret binding sets exactly one of sopsKey or path.";
            }
            {
              assertion = lib.all (secretName: builtins.match "^[A-Za-z0-9_.-]+$" secretName != null) (
                lib.attrNames secrets
              );
              message = "projects.${name}: secret names must be valid systemd credential names.";
            }
          ]
        ) enabledProjects
      );

    })
    (lib.mkIf (config.vps.enable && serviceCfg.enable) (
      lib.optionalAttrs hasHomeManager {
        home-manager.users = lib.mkMerge (
          lib.mapAttrsToList (name: project: {
            ${project.repository.checkout.owner}.workspaceRepos.repositories = [
              {
                path = checkoutRelativePath name project;
                url = checkoutUrl name project;
                bookmark = project.repository.branch;
              }
            ];
          }) checkoutProjects
        );
        systemd.services = lib.listToAttrs (lib.mapAttrsToList checkoutService checkoutProjects);
      }
      // lib.optionalAttrs hasSops { sops.secrets = projectSopsSecrets; }
      // lib.optionalAttrs (options ? server.backup) {
        server.backup.paths = lib.mkIf (postgresUsers != [ ]) (lib.mkAfter [ "/var/backup/postgresql" ]);
      }
    ))
    (lib.mkIf (config.vps.enable && serviceCfg.enable) {
      users.users = lib.genAttrs owners (_: {
        linger = lib.mkDefault true;
      });
      environment.systemPackages = [ projectCli ];
      environment.etc =
        lib.listToAttrs (
          map (owner: lib.nameValuePair "projects/catalog-${owner}.json" { source = catalog owner; }) owners
        )
        // {
          "projects/releases.json".text = builtins.toJSON resolvedReleases + "\n";
        };
      systemd.services = lib.listToAttrs (map controllerService owners);
      systemd.timers =
        lib.genAttrs (map (owner: "project-development-${owner}-reconcile") owners)
          (unit: {
            description = "Periodically reconcile Project Development instances";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnActiveSec = "1m";
              OnUnitActiveSec = "5m";
              Persistent = true;
              Unit = "${unit}.service";
            };
          });
      systemd.tmpfiles.rules = [
        "d /var/lib/project-development 0755 root root -"
      ]
      ++ lib.concatMap (
        owner:
        let
          group = config.users.users.${owner}.group;
        in
        [
          "d ${controllerStateDir owner} 0700 ${owner} ${group} -"
          "f ${controllerStateDir owner}/instances.json 0600 ${owner} ${group} -"
          "f ${controllerStateDir owner}/routes.json 0644 ${owner} ${group} -"
        ]
      ) owners
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: project:
          map (path: "d ${path} 0700 ${project.repository.checkout.owner} users -") [
            "/var/lib/projects/${name}"
            "/var/lib/projects/${name}/instances"
            "/var/cache/projects/${name}"
            "/var/cache/projects/${name}/instances"
          ]
        ) developmentProjects
      );

      vps.services.projects.metadata.health.units =
        map (owner: "project-development-${owner}-reconcile.timer") owners
        ++ lib.mapAttrsToList (name: _: "app-deployment-${name}.service") (
          lib.filterAttrs (_: app: app.backend == "service") releaseApps
        );

      vps.services.appDeployments.apps = releaseApps;
      services.postgresql = lib.mkIf (postgresUsers != [ ]) {
        enable = true;
        ensureDatabases = postgresUsers;
        ensureUsers = map (name: {
          inherit name;
          ensureDBOwnership = true;
        }) postgresUsers;
      };
      # Logical backups survive provider removal; data and roles are retained too.
      services.postgresqlBackup = lib.mkIf (postgresUsers != [ ]) {
        enable = true;
        databases = postgresUsers;
        compression = lib.mkDefault "zstd";
        startAt = lib.mkDefault "*-*-* 23:30:00";
      };
      vps.services.caddy.virtualHosts = lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            name: project:
            map (alias: {
              name = alias;
              value = {
                tailscaleOnly = project.release.endpoint.visibility != "public";
                extraConfig = "redir https://${releaseHostName name project}{uri} 308";
              };
            }) (releaseAliases name project)
          ) releaseProjects
        )
      );
    })
  ];
}
