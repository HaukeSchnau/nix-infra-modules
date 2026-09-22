# Normalizes a Project declaration into the schema-v4 descriptor that hosts
# and release tooling consume. Declarations come from the typed modules in
# modules/project and modules/devenv, so this file applies defaults and checks
# only what option types cannot express: references between sections, cycles,
# and path and name safety. Normalizing a normalized descriptor is a no-op.
{ lib }:
let
  fail = context: message: throw "project descriptor ${context}: ${message}";
  # Returns value when every check holds and reports the first failure otherwise.
  checked =
    context: checks: value:
    let
      failed = lib.findFirst (item: !item.ok) null checks;
    in
    if failed == null then value else fail context failed.message;
  check = ok: message: { inherit ok message; };

  isName = value: builtins.match "^[a-z0-9][a-z0-9-]{0,62}$" value != null;
  isSemanticName = value: builtins.match "^[A-Za-z0-9_.-]+$" value != null;
  isExecutableName = value: builtins.match "^[A-Za-z0-9._+-]+$" value != null;
  isAbsolutePath = value: lib.hasPrefix "/" value;
  isRelativePath =
    value:
    builtins.match "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" value != null
    && lib.all (part: part != "." && part != "..") (lib.splitString "/" value);
  isSingleLine = value: value != "" && !(lib.hasInfix "\n" value);
  namesValid = values: lib.all isName (builtins.attrNames values);
  allDeclared = declared: names: lib.all (name: declared ? ${name}) names;

  # Depth-first order of nodes with `dependsOn`; `valid` is false for a cycle.
  graphTraversal =
    nodes:
    let
      visit =
        name: visiting: visited:
        if builtins.elem name visiting then
          {
            valid = false;
            inherit visited;
          }
        else if builtins.elem name visited then
          {
            valid = true;
            inherit visited;
          }
        else
          let
            result =
              lib.foldl'
                (
                  state: dependency:
                  if state.valid then visit dependency ([ name ] ++ visiting) state.visited else state
                )
                {
                  valid = true;
                  inherit visited;
                }
                nodes.${name}.dependsOn;
          in
          {
            inherit (result) valid;
            visited = result.visited ++ lib.optional result.valid name;
          };
    in
    lib.foldl' (state: name: if state.valid then visit name [ ] state.visited else state) {
      valid = true;
      visited = [ ];
    } (builtins.attrNames nodes);

  parameterMatches =
    type: value:
    {
      boolean = builtins.isBool value;
      integer = builtins.isInt value;
      number = builtins.isInt value || builtins.isFloat value;
      string = builtins.isString value;
    }
    .${type};

  normalizeParameter =
    name: value:
    let
      type = value.type or "string";
      normalized = {
        inherit type;
        description = value.description or "";
        required = value.required or (!(value ? default));
      }
      // lib.optionalAttrs (value ? default) { inherit (value) default; };
    in
    checked "parameters.${name}" [
      (check (isSemanticName name) "invalid parameter name")
      (check (
        !(value ? default) || parameterMatches type value.default
      ) "default does not match type ${type}")
    ] normalized;

  normalizeRequirement =
    name: value:
    let
      context = "requirements.${name}";
      common = {
        inherit (value) kind;
        description = value.description or "";
        required = value.required or true;
        realizations =
          value.realizations or [
            "development"
            "release"
          ];
      };
      majorVersions = value.majorVersions or [ (value.majorVersion or null) ];
      specific =
        {
          postgresql = {
            majorVersions = lib.unique majorVersions;
            dataDirectory = value.dataDirectory or name;
          };
          directory = {
            persistent = value.persistent or true;
            path = value.path or name;
          };
          secret.generate =
            if (value.generate or null) == null then null else { bytes = value.generate.bytes or 32; };
        }
        .${value.kind};
    in
    checked context (
      [
        (check (isSemanticName name) "invalid requirement name")
        (check (common.realizations != [ ]) "realizations must not be empty")
      ]
      ++ lib.optionals (value.kind == "postgresql") [
        (check (
          lib.all (version: builtins.isInt version && version >= 10) majorVersions
          && !(value ? majorVersion && value ? majorVersions && value.majorVersion != null)
        ) "declare majorVersion or a non-empty majorVersions list of integers of at least 10")
        (check (isRelativePath specific.dataDirectory) "dataDirectory must be a relative path")
      ]
      ++ lib.optional (value.kind == "directory") (
        check (isRelativePath specific.path) "path must be a relative path"
      )
    ) (common // specific);

  forRealization =
    realization: requirements:
    lib.filterAttrs (_: requirement: builtins.elem realization requirement.realizations) requirements;

  normalizeHealth =
    {
      context,
      protocol ? "http",
      defaults ? { },
      value,
    }:
    let
      paths = value.paths or [ "/" ];
    in
    checked context
      [
        (check (
          protocol != "http" || (paths != [ ] && lib.all isAbsolutePath paths)
        ) "paths must be a non-empty list of absolute HTTP paths")
      ]
      (
        {
          startupTimeoutSec = value.startupTimeoutSec or 60;
          intervalSec = value.intervalSec or (defaults.intervalSec or 2);
          requestTimeoutSec = value.requestTimeoutSec or (defaults.requestTimeoutSec or 5);
        }
        // lib.optionalAttrs (protocol == "http") { inherit paths; }
      );

  normalizeProvider =
    requirements: workloads: name: value:
    let
      requirement = requirements.${name} or { };
      normalized = {
        workload = value.workload or name;
        port = value.port or 5432;
        database = value.database or "postgres";
        user = value.user or "postgres";
        majorVersion = value.majorVersion or (builtins.head requirement.majorVersions);
      };
    in
    checked "development.providers.${name}" [
      (check (
        (requirement.kind or null) == "postgresql"
      ) "must implement a declared PostgreSQL requirement")
      (check (builtins.elem normalized.majorVersion (
        requirement.majorVersions or [ ]
      )) "provider majorVersion must satisfy the PostgreSQL requirement")
      (check (
        (workloads.${normalized.workload}.kind or null) == "service"
      ) "workload must name a native service")
    ] normalized;

  normalizeDevelopment =
    {
      secrets,
      requirements,
      value,
    }:
    let
      workloads = lib.mapAttrs (name: workload: {
        action = workload.action or name;
        kind = workload.kind or "service";
        dependsOn = workload.dependsOn or [ ];
        secrets = workload.secrets or [ ];
        lifecycle = workload.lifecycle or "on-demand";
      }) (value.workloads or { });
      commands = lib.mapAttrs (name: command: {
        action = command.action or name;
        dependsOn = command.dependsOn or [ ];
        secrets = command.secrets or [ ];
      }) (value.commands or { });
      endpoints = lib.mapAttrs (
        name: endpoint:
        let
          protocol = endpoint.protocol or "http";
        in
        {
          inherit protocol;
          workload = endpoint.workload or name;
          port = endpoint.port or null;
          publication = endpoint.publication or "preview";
          health = normalizeHealth {
            context = "development.endpoints.${name}.health";
            inherit protocol;
            defaults = {
              intervalSec = 1;
              requestTimeoutSec = 15;
            };
            value = endpoint.health or { };
          };
        }
      ) (value.endpoints or { });
      preparation = {
        action = value.preparation.action or "prepare";
        secrets = value.preparation.secrets or [ ];
        timeoutSec = value.preparation.timeoutSec or 900;
      };
      providers = lib.mapAttrs (normalizeProvider (forRealization "development" requirements) workloads) (
        value.providers or { }
      );
      secretLists = map (item: item.secrets) (
        builtins.attrValues workloads ++ builtins.attrValues commands ++ [ preparation ]
      );
    in
    checked "development"
      [
        (check (
          namesValid workloads && namesValid commands && namesValid endpoints
        ) "workload, command and endpoint names must be lowercase kebab-case")
        (check (lib.all (workload: workload.kind == "service" || workload.lifecycle == "on-demand") (
          builtins.attrValues workloads
        )) "background lifecycle requires kind service")
        (check (lib.all (item: allDeclared workloads item.dependsOn) (
          builtins.attrValues workloads ++ builtins.attrValues commands
        )) "dependencies must reference declared workloads")
        (check (lib.all (allDeclared secrets) secretLists) "Secrets must reference declared names")
        (check (graphTraversal workloads).valid "workload dependency graph must be acyclic")
        (check (lib.all (endpoint: (workloads.${endpoint.workload}.kind or null) == "service") (
          builtins.attrValues endpoints
        )) "endpoints must target declared service workloads")
      ]
      {
        inherit
          commands
          endpoints
          preparation
          providers
          workloads
          ;
      };

  normalizeIngress =
    value:
    let
      redirects = map (redirect: {
        inherit (redirect) from to;
        status =
          if (redirect.status or null) != null then
            redirect.status
          else if (redirect.permanent or null) == false then
            307
          else
            308;
      }) (value.redirects or [ ]);
      cacheRules = map (rule: { inherit (rule) paths value; }) (value.cacheRules or [ ]);
      responseHeaders = value.responseHeaders or { };
    in
    checked "release.ingress"
      [
        (check (lib.all (
          redirect: isAbsolutePath redirect.from && isAbsolutePath redirect.to
        ) redirects) "redirects must use absolute paths")
        (check (lib.all (
          redirect: (redirect.status or null) == null || (redirect.permanent or null) == null
        ) (value.redirects or [ ])) "set either status or permanent on a redirect, not both")
        (check (lib.all (
          rule: rule.paths != [ ] && lib.all isAbsolutePath rule.paths && isSingleLine rule.value
        ) cacheRules) "cache rules need absolute paths and a single-line value")
        (check (
          lib.all (header: builtins.match "^[A-Za-z0-9-]+$" header != null) (
            builtins.attrNames responseHeaders
          )
          && lib.all isSingleLine (builtins.attrValues responseHeaders)
        ) "responseHeaders must map header names to single-line values")
      ]
      {
        inherit cacheRules redirects responseHeaders;
        compression = value.compression or false;
        requestBodyMaxBytes = value.requestBodyMaxBytes or null;
        streamCloseDelaySec = value.streamCloseDelaySec or null;
      };

  normalizeSchedule =
    context: value:
    let
      calendar = value.calendar or null;
      interval = value.interval or null;
      cadence = value.cadence or null;
    in
    checked context
      [
        (check ((calendar == null) != (interval == null)) "must set exactly one of calendar or interval")
        (check (interval != null || cadence == null) "cadence only applies to interval schedules")
      ]
      {
        inherit calendar interval;
        cadence =
          if interval == null then
            null
          else if cadence == null then
            "spaced"
          else
            cadence;
      };

  normalizeRelease =
    secrets: value:
    let
      backend = value.backend or "service";
      isService = backend == "service";
      entryPoint = name: entry: {
        action = entry.action or name;
        secrets = entry.secrets or [ ];
      };
      commands = lib.mapAttrs entryPoint (value.commands or { });
      maintenanceJobs = lib.mapAttrs (
        name: job:
        entryPoint name job
        // lib.optionalAttrs ((job.schedule or null) != null) {
          schedule = normalizeSchedule "release.maintenanceJobs.${name}.schedule" job.schedule;
        }
      ) (value.maintenanceJobs or { });
      preDeployTasks = lib.mapAttrs (
        name: task:
        entryPoint name task
        // {
          dependsOn = task.dependsOn or [ ];
          failureMode = task.failureMode or "fail";
          timeoutSec = task.timeoutSec or 900;
        }
      ) (value.preDeployTasks or { });
      ociAuxiliaries = lib.mapAttrs (_: auxiliary: {
        inherit (auxiliary) image;
        command = auxiliary.command or [ ];
        ports = lib.mapAttrs (_: port: {
          inherit (port) containerPort;
          protocol = port.protocol or "tcp";
        }) (auxiliary.ports or { });
      }) (value.ociAuxiliaries or { });
      normalized = {
        inherit
          backend
          commands
          maintenanceJobs
          ociAuxiliaries
          preDeployTasks
          ;
        action = value.action or (if isService then "web" else null);
        package = value.package or "projectRelease";
        executable = value.executable or (if isService then "project-release-runtime" else null);
        activationExecutable = value.activationExecutable or null;
        stateDirectories = value.stateDirectories or [ ];
        health = normalizeHealth {
          context = "release.health";
          value = value.health or { };
        };
        ingress = normalizeIngress (value.ingress or { });
      };
      entryPoints =
        builtins.attrValues commands
        ++ builtins.attrValues maintenanceJobs
        ++ builtins.attrValues preDeployTasks;
    in
    checked "release" [
      (check (isSemanticName normalized.package) "package must be a simple flake package attribute name")
      (check
        (
          if isService then
            normalized.executable != null && isExecutableName normalized.executable && normalized.action != ""
          else
            (value.executable or null) == null
            && commands == { }
            && maintenanceJobs == { }
            && preDeployTasks == { }
        )
        "service releases need an action and executable; static releases declare neither nor entry points"
      )
      (check (
        normalized.activationExecutable == null || isExecutableName normalized.activationExecutable
      ) "activationExecutable must be a simple executable name")
      (check (lib.all isRelativePath normalized.stateDirectories) "stateDirectories must contain safe relative paths")
      (check (
        namesValid commands
        && namesValid maintenanceJobs
        && namesValid preDeployTasks
        && namesValid ociAuxiliaries
        && lib.all (auxiliary: namesValid auxiliary.ports) (builtins.attrValues ociAuxiliaries)
      ) "command, job, task and auxiliary names must be lowercase kebab-case")
      (check (lib.all (
        entry: allDeclared secrets entry.secrets
      ) entryPoints) "Secrets must reference declared names")
      (check (lib.all (task: allDeclared preDeployTasks task.dependsOn) (
        builtins.attrValues preDeployTasks
      )) "preDeployTask dependencies must reference declared tasks")
      (check (graphTraversal preDeployTasks).valid "preDeployTask dependency graph must be acyclic")
    ] normalized;

  bindingFields = {
    postgresql = [
      "kind"
      "majorVersion"
      "host"
      "port"
      "database"
      "user"
      "url"
      "dataDirectory"
    ];
    directory = [
      "kind"
      "path"
      "persistent"
    ];
    secret = [
      "kind"
      "file"
      "value"
      "credential"
    ];
  };
  endpointFields = [
    "url"
    "protocol"
    "listen.host"
    "listen.port"
    "hostNames"
  ];

  # Endpoints and actions a realization's environment may refer to.
  realizationTargets =
    realization: definition:
    if realization == "development" then
      {
        endpoints = builtins.attrNames definition.endpoints;
        actions = null;
      }
    else
      {
        endpoints =
          lib.optional (definition.action != null) definition.action
          ++ lib.concatLists (
            lib.mapAttrsToList (
              auxiliary: value: map (port: "${auxiliary}-${port}") (builtins.attrNames value.ports)
            ) definition.ociAuxiliaries
          );
        actions =
          lib.optional (definition.action != null) definition.action
          ++ map (entry: entry.action) (
            builtins.attrValues definition.preDeployTasks
            ++ builtins.attrValues definition.maintenanceJobs
            ++ builtins.attrValues definition.commands
          );
      };

  normalizeEnvironmentValue =
    {
      context,
      requirements,
      parameters,
      endpoints,
    }:
    value:
    let
      selectors = lib.intersectLists [ "binding" "endpoint" "parameter" "path" "instance" ] (
        builtins.attrNames value
      );
      selector = builtins.head selectors;
      field = value.field or null;
      needsField = builtins.elem selector [
        "binding"
        "endpoint"
      ];
    in
    if builtins.isString value then
      value
    else
      checked context [
        (check (
          builtins.length selectors == 1
          &&
            builtins.length (builtins.attrNames value)
            == 1 + (if needsField then 1 else 0) + (if value ? append then 1 else 0)
        ) "must select exactly one binding, endpoint, parameter, path or instance field")
        (check (needsField == (field != null)) "binding and endpoint references need a field")
        (check (
          !(value ? append) || (selector == "path" && isRelativePath value.append)
        ) "append must be a relative path on a path reference")
        (check (
          selector != "binding"
          || (
            requirements ? ${value.binding}
            && builtins.elem field bindingFields.${requirements.${value.binding}.kind}
          )
        ) "references an undeclared requirement or unknown binding field")
        (check (
          selector != "parameter" || parameters ? ${value.parameter}
        ) "references an undeclared parameter")
        (check (
          selector != "endpoint"
          || (builtins.elem value.endpoint endpoints && builtins.elem field endpointFields)
        ) "references an unknown endpoint or field")
      ] value;

  normalizeEnvironment =
    descriptor: environment:
    lib.mapAttrs (
      realization: value:
      let
        context = "environment.${realization}";
        definition = descriptor.${realization} or null;
        targets = realizationTargets realization definition;
        normalizeMap =
          mapContext: values:
          lib.mapAttrs (
            variable:
            normalizeEnvironmentValue {
              context = "${mapContext}.${variable}";
              requirements = forRealization realization descriptor.requirements;
              inherit (descriptor) parameters;
              inherit (targets) endpoints;
            }
          ) values;
        actions = value.actions or { };
        variables =
          builtins.attrNames (value.common or { })
          ++ lib.concatMap builtins.attrNames (builtins.attrValues actions);
      in
      checked context
        [
          (check (definition != null) "requires the corresponding realization")
          (check (lib.all (
            name: builtins.match "^[A-Za-z_][A-Za-z0-9_]*$" name != null
          ) variables) "invalid environment variable name")
          # The devenv adapter checks development actions against its native task graph.
          (check (
            targets.actions == null
            || lib.all (action: builtins.elem action targets.actions) (builtins.attrNames actions)
          ) "references an undeclared action")
        ]
        {
          common = normalizeMap "${context}.common" (value.common or { });
          actions = lib.mapAttrs (action: normalizeMap "${context}.actions.${action}") actions;
        }
    ) environment;

  normalize =
    {
      descriptor,
      expectedProject ? null,
    }:
    let
      requirements = lib.mapAttrs normalizeRequirement (descriptor.requirements or { });
      secrets = lib.mapAttrs (_: requirement: { inherit (requirement) description required; }) (
        lib.filterAttrs (_: requirement: requirement.kind == "secret") requirements
      );
      realizations = {
        inherit (descriptor) project schemaVersion;
        inherit requirements secrets;
        parameters = lib.mapAttrs normalizeParameter (descriptor.parameters or { });
        development =
          if (descriptor.development or null) == null then
            null
          else
            normalizeDevelopment {
              inherit secrets requirements;
              value = descriptor.development;
            };
        release =
          if (descriptor.release or null) == null then null else normalizeRelease secrets descriptor.release;
      };
      result = realizations // {
        environment = normalizeEnvironment realizations (descriptor.environment or { });
      };
    in
    checked "root" [
      (check (
        descriptor.schemaVersion or null == 4
      ) "unsupported schemaVersion; regenerate with the current SDK")
      (check (
        builtins.isString descriptor.project && isName descriptor.project
      ) "project must be a lowercase kebab-case name")
      (check (
        expectedProject == null || expectedProject == descriptor.project
      ) "expected project ${toString expectedProject}, got ${toString descriptor.project}")
      (check (
        result.development != null || result.release != null
      ) "declare development, release, or both")
    ] (builtins.deepSeq result result);

  resolveParameters =
    {
      allowUnknown ? false,
      descriptor,
      values ? { },
    }:
    let
      unknown = lib.subtractLists (builtins.attrNames descriptor.parameters) (builtins.attrNames values);
      resolved = lib.mapAttrs (
        name: definition:
        if values ? ${name} then
          checked "parameters.${name}" [
            (check (parameterMatches definition.type
              values.${name}
            ) "value does not match type ${definition.type}")
          ] values.${name}
        else if definition ? default then
          definition.default
        else if definition.required then
          fail "parameters.${name}" "a value is required"
        else
          null
      ) descriptor.parameters;
    in
    checked "parameters" [
      (check (allowUnknown || unknown == [ ]) "unknown values: ${lib.concatStringsSep ", " unknown}")
    ] resolved;

  # Projects a normalized descriptor and typed host policy into the settings
  # consumed by the app-deployments module.
  releaseApp =
    {
      descriptor,
      policy,
    }:
    let
      release =
        if descriptor.release == null then
          fail "release" "descriptor does not define a Release realization"
        else
          descriptor.release;
      secretBindings = policy.secrets or { };
      releaseSecrets = lib.filterAttrs (
        name: _: builtins.elem "release" descriptor.requirements.${name}.realizations
      ) descriptor.secrets;
      # A bound secret requirement is satisfied by the credential of the same name.
      resourceBindings =
        lib.mapAttrs (name: _: {
          kind = "secret";
          credential = name;
        }) (lib.intersectAttrs releaseSecrets secretBindings)
        // (policy.bindings or { });
      missingSecrets = lib.filter (name: releaseSecrets.${name}.required && !(secretBindings ? ${name})) (
        builtins.attrNames releaseSecrets
      );
      approvedOci = policy.approvedOci or [ ];
      unapprovedOci = lib.subtractLists approvedOci (builtins.attrNames release.ociAuxiliaries);
      jobPolicies = policy.jobs or { };
      activeJobs =
        lib.mapAttrs
          (
            name: job:
            let
              jobPolicy = jobPolicies.${name} or { };
              explicit = (jobPolicy.calendar or null) != null || (jobPolicy.interval or null) != null;
              schedule = job.schedule or null;
              calendar = if explicit then jobPolicy.calendar or null else schedule.calendar or null;
              interval = if explicit then jobPolicy.interval or null else schedule.interval or null;
              # A host interval keeps the repository cadence unless it overrides it.
              repositoryCadence = if schedule == null then "spaced" else schedule.cadence or "spaced";
              cadence =
                if interval == null then
                  null
                else if (jobPolicy.cadence or null) == null then
                  repositoryCadence
                else
                  jobPolicy.cadence;
            in
            checked "release policy.jobs.${name}"
              [
                (check (
                  (calendar == null) != (interval == null)
                ) "must set exactly one of calendar or interval, either in the descriptor or host policy")
                (check (
                  calendar == null || (jobPolicy.cadence or null) == null
                ) "cadence only applies to interval schedules")
              ]
              {
                inherit calendar cadence interval;
                onBootSec = jobPolicy.onBootSec or "5min";
                persistent = jobPolicy.persistent or true;
                randomizedDelaySec = jobPolicy.randomizedDelaySec or "0";
              }
          )
          (
            lib.filterAttrs (
              name: job: (jobPolicies.${name}.enable or true) && (job ? schedule || jobPolicies ? ${name})
            ) release.maintenanceJobs
          );
    in
    checked "release policy"
      [
        (check (
          missingSecrets == [ ]
        ) "missing required Secret bindings: ${lib.concatStringsSep ", " missingSecrets}")
        (check (
          unapprovedOci == [ ]
        ) "OCI auxiliaries require explicit approval: ${lib.concatStringsSep ", " unapprovedOci}")
      ]
      (
        {
          inherit (release) backend executable package;
          inherit (release) health;
          project = {
            inherit descriptor approvedOci;
            jobs = activeJobs;
            parameterBindings = policy.parameters or { };
            healthRecovery = policy.healthRecovery or { };
            exposeRevision = policy.exposeRevision or false;
            parameters = resolveParameters {
              allowUnknown = true;
              inherit descriptor;
              values = policy.parameters or { };
            };
            resources.memory = {
              high = policy.resources.memory.high or null;
              max = policy.resources.memory.max or null;
              swapMax = policy.resources.memory.swapMax or null;
            };
            secrets = secretBindings;
            bindings = resourceBindings;
            instanceId = policy.instanceId or null;
          };
          inherit (policy) source;
        }
        // lib.getAttrs (lib.intersectLists [
          "delivery"
          "domain"
          "environment"
          "environmentFiles"
          "path"
          "port"
          "public"
          "runtime"
        ] (builtins.attrNames policy)) policy
      );
in
{
  inherit
    forRealization
    normalize
    releaseApp
    resolveParameters
    ;
  releaseTaskOrder = release: (graphTraversal release.preDeployTasks).visited;
}
