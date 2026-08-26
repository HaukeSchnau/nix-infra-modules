{ lib }:
let
  fail = context: message: throw "project descriptor ${context}: ${message}";
  ensure =
    context: condition: message: value:
    if condition then value else fail context message;
  isAttrs = value: builtins.isAttrs value;
  isString = value: builtins.isString value;
  isBool = value: builtins.isBool value;
  isInt = value: builtins.isInt value;
  namePattern = "^[a-z0-9][a-z0-9-]{0,62}$";
  semanticNamePattern = "^[A-Za-z0-9_.-]+$";
  executableNamePattern = "^[A-Za-z0-9._+-]+$";
  headerNamePattern = "^[A-Za-z0-9-]+$";

  checkKeys =
    context: allowed: value:
    let
      unknown = lib.subtractLists allowed (builtins.attrNames value);
    in
    ensure context (unknown == [ ]) "unknown fields: ${lib.concatStringsSep ", " unknown}" value;

  checkName =
    context: name:
    ensure context (
      isString name && builtins.match namePattern name != null
    ) "must be a lowercase kebab-case name of at most 63 characters" name;

  checkSemanticName =
    context: name:
    ensure context (
      isString name && builtins.match semanticNamePattern name != null
    ) "must contain only letters, digits, underscores, dots, and hyphens" name;

  checkStringList =
    context: values:
    ensure context (
      builtins.isList values && lib.all isString values
    ) "must be a list of strings" values;

  normalizeSecret =
    name: value:
    let
      context = "secrets.${name}";
      checkedName = checkSemanticName context name;
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [ "description" "required" ] attrs;
      description = checked.description or "";
      required = checked.required or true;
    in
    builtins.seq checkedName (
      ensure context (isString description) "description must be a string" (
        ensure context (isBool required) "required must be a boolean" {
          inherit description required;
        }
      )
    );

  parameterTypes = [
    "boolean"
    "integer"
    "number"
    "string"
  ];
  parameterMatches =
    type: value:
    if type == "boolean" then
      isBool value
    else if type == "integer" then
      isInt value
    else if type == "number" then
      isInt value || builtins.isFloat value
    else
      isString value;
  normalizeParameter =
    name: value:
    let
      context = "parameters.${name}";
      checkedName = checkSemanticName context name;
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "default"
        "description"
        "required"
        "type"
      ] attrs;
      type = checked.type or "string";
      required = checked.required or (!(checked ? default));
      description = checked.description or "";
      defaultIsValid = !(checked ? default) || parameterMatches type checked.default;
    in
    builtins.seq checkedName (
      ensure context (builtins.elem type parameterTypes)
        "type must be one of ${lib.concatStringsSep ", " parameterTypes}"
        (
          ensure context (isBool required) "required must be a boolean" (
            ensure context (isString description) "description must be a string" (
              ensure context defaultIsValid "default does not match type ${type}" (
                {
                  inherit description required type;
                }
                // lib.optionalAttrs (checked ? default) { inherit (checked) default; }
              )
            )
          )
        )
    );

  normalizeHealth =
    {
      context,
      defaults ? { },
      protocol ? "http",
      value,
    }:
    let
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      allowedFields = [
        "intervalSec"
        "requestTimeoutSec"
        "startupTimeoutSec"
      ]
      ++ lib.optional (protocol == "http") "paths";
      checked = checkKeys context allowedFields attrs;
      paths = if protocol == "http" then checked.paths or [ "/" ] else null;
      startupTimeoutSec = checked.startupTimeoutSec or (defaults.startupTimeoutSec or 60);
      intervalSec = checked.intervalSec or (defaults.intervalSec or 2);
      requestTimeoutSec = checked.requestTimeoutSec or (defaults.requestTimeoutSec or 5);
    in
    ensure context
      (
        protocol != "http"
        || (
          builtins.isList paths
          && paths != [ ]
          && lib.all (path: isString path && lib.hasPrefix "/" path) paths
        )
      )
      "paths must be a non-empty list of absolute HTTP paths"
      (
        ensure context (isInt startupTimeoutSec && startupTimeoutSec > 0)
          "startupTimeoutSec must be a positive integer"
          (
            ensure context (isInt intervalSec && intervalSec > 0) "intervalSec must be a positive integer" (
              ensure context (isInt requestTimeoutSec && requestTimeoutSec > 0)
                "requestTimeoutSec must be a positive integer"
                {
                  inherit
                    intervalSec
                    requestTimeoutSec
                    startupTimeoutSec
                    ;
                }
              // lib.optionalAttrs (protocol == "http") { inherit paths; }
            )
          )
      );

  graphTraversal =
    workloads:
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
                workloads.${name}.dependsOn;
          in
          {
            inherit (result) valid;
            visited = result.visited ++ lib.optional result.valid name;
          };
      result = lib.foldl' (state: name: if state.valid then visit name [ ] state.visited else state) {
        valid = true;
        visited = [ ];
      } (builtins.attrNames workloads);
    in
    result;

  graphIsAcyclic = workloads: (graphTraversal workloads).valid;

  graphOrder = workloads: (graphTraversal workloads).visited;

  normalizeCommand =
    {
      context,
      name,
      secrets,
      value,
      withDependencies ? false,
    }:
    let
      checkedName = checkName context name;
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context (
        [
          "action"
          "secrets"
        ]
        ++ lib.optional withDependencies "dependsOn"
      ) attrs;
      action = checked.action or name;
      secretNames = checkStringList "${context}.secrets" (checked.secrets or [ ]);
      dependsOn =
        if withDependencies then checkStringList "${context}.dependsOn" (checked.dependsOn or [ ]) else [ ];
    in
    builtins.seq checkedName (
      ensure context (isString action && action != "") "action must be a non-empty string" (
        ensure context (lib.all (secret: builtins.hasAttr secret secrets) secretNames)
          "Secrets must reference declared names"
          (
            {
              inherit action;
              secrets = secretNames;
            }
            // lib.optionalAttrs withDependencies { inherit dependsOn; }
          )
      )
    );

  normalizeDevelopment =
    schemaVersion: secrets: value:
    let
      context = "development";
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context ([
        "commands"
        "endpoints"
        "preparation"
        "workloads"
      ]) attrs;
      endpointInput = checked.endpoints or { };
      workloadInput = checked.workloads or { };
      impliedWorkloads = lib.mapAttrs (_: endpoint: {
        action = endpoint.workload or null;
      }) endpointInput;
      mergedWorkloads = lib.recursiveUpdate impliedWorkloads workloadInput;
      workloads = lib.mapAttrs (
        name: workload:
        let
          itemContext = "development.workloads.${name}";
          checkedName = checkName itemContext name;
          item = checkKeys itemContext (
            [
              "action"
              "dependsOn"
              "kind"
              "secrets"
            ]
            ++ lib.optional (schemaVersion == 3) "lifecycle"
          ) (ensure itemContext (isAttrs workload) "must be an attribute set" workload);
          action = if (item.action or null) == null then name else item.action;
          dependsOn = item.dependsOn or [ ];
          kind = item.kind or "service";
          lifecycle = item.lifecycle or "on-demand";
          secretNames = item.secrets or [ ];
          checkedDependsOn = checkStringList "${itemContext}.dependsOn" dependsOn;
          checkedSecrets = checkStringList "${itemContext}.secrets" secretNames;
        in
        builtins.seq checkedName (
          ensure itemContext (isString action && action != "") "action must be a non-empty string" (
            ensure itemContext
              (builtins.elem kind [
                "service"
                "task"
              ])
              "kind must be service or task"
              (
                ensure itemContext
                  (
                    schemaVersion != 3
                    || builtins.elem lifecycle [
                      "background"
                      "on-demand"
                    ]
                  )
                  "lifecycle must be background or on-demand"
                  (
                    ensure itemContext (schemaVersion != 3 || lifecycle != "background" || kind == "service")
                      "background lifecycle requires kind service"
                      (
                        {
                          inherit action kind;
                          dependsOn = checkedDependsOn;
                          secrets = checkedSecrets;
                        }
                        // lib.optionalAttrs (schemaVersion == 3) { inherit lifecycle; }
                      )
                  )
              )
          )
        )
      ) mergedWorkloads;
      commands = lib.mapAttrs (
        name: value:
        normalizeCommand {
          context = "development.commands.${name}";
          inherit name secrets value;
          withDependencies = true;
        }
      ) (checked.commands or { });
      endpoints = lib.mapAttrs (
        name: endpoint:
        let
          itemContext = "development.endpoints.${name}";
          checkedName = checkName itemContext name;
          item = checkKeys itemContext [
            "health"
            "protocol"
            "workload"
          ] (ensure itemContext (isAttrs endpoint) "must be an attribute set" endpoint);
          workload = item.workload or name;
          protocol = item.protocol or "http";
        in
        builtins.seq checkedName (
          ensure itemContext (isString workload && builtins.hasAttr workload workloads)
            "references unknown workload ${toString workload}"
            (
              ensure itemContext
                (
                  if schemaVersion == 1 then
                    protocol == "http"
                  else
                    builtins.elem protocol [
                      "http"
                      "tcp"
                    ]
                )
                (
                  if schemaVersion == 1 then
                    "protocol must be http in schemaVersion 1"
                  else
                    "protocol must be http or tcp"
                )
                {
                  inherit protocol workload;
                  health = normalizeHealth {
                    context = "${itemContext}.health";
                    defaults = {
                      intervalSec = 1;
                      requestTimeoutSec = 15;
                    };
                    inherit protocol;
                    value = item.health or { };
                  };
                }
            )
        )
      ) endpointInput;
      preparationInput = checked.preparation or { };
      preparationChecked =
        checkKeys "development.preparation"
          [
            "action"
            "secrets"
            "timeoutSec"
          ]
          (
            ensure "development.preparation" (isAttrs preparationInput) "must be an attribute set"
              preparationInput
          );
      preparation = {
        action = preparationChecked.action or "prepare";
        secrets = checkStringList "development.preparation.secrets" (preparationChecked.secrets or [ ]);
        timeoutSec = preparationChecked.timeoutSec or 900;
      };
      workloadReferencesValid = lib.all (
        workload:
        lib.all (dependency: builtins.hasAttr dependency workloads) workload.dependsOn
        && lib.all (secret: builtins.hasAttr secret secrets) workload.secrets
      ) (builtins.attrValues workloads);
      commandReferencesValid = lib.all (
        command: lib.all (dependency: builtins.hasAttr dependency workloads) command.dependsOn
      ) (builtins.attrValues commands);
      endpointTargetsServices = lib.all (endpoint: workloads.${endpoint.workload}.kind == "service") (
        builtins.attrValues endpoints
      );
    in
    ensure context (schemaVersion >= 3 || commands == { }) "commands require schemaVersion 3" (
      ensure "development.preparation" (isString preparation.action && preparation.action != "")
        "action must be a non-empty string"
        (
          ensure "development.preparation" (isInt preparation.timeoutSec && preparation.timeoutSec > 0)
            "timeoutSec must be a positive integer"
            (
              ensure context (workloadReferencesValid && commandReferencesValid)
                "Workload and command dependencies and Secrets must reference declared names"
                (
                  ensure context (schemaVersion == 1 || graphIsAcyclic workloads)
                    "Workload dependency graph must be acyclic"
                    (
                      ensure context endpointTargetsServices "Endpoints must target service Workloads" (
                        ensure context (lib.all (secret: builtins.hasAttr secret secrets) preparation.secrets)
                          "Preparation Secrets must reference declared names"
                          {
                            inherit
                              commands
                              endpoints
                              preparation
                              workloads
                              ;
                          }
                      )
                    )
                )
            )
        )
    );

  normalizeIngress =
    value:
    let
      context = "release.ingress";
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "cacheRules"
        "compression"
        "redirects"
        "requestBodyMaxBytes"
        "responseHeaders"
        "streamCloseDelaySec"
      ] attrs;
      compression = checked.compression or false;
      requestBodyMaxBytes = checked.requestBodyMaxBytes or null;
      responseHeaders = checked.responseHeaders or { };
      streamCloseDelaySec = checked.streamCloseDelaySec or null;
      redirects = lib.imap0 (
        index: redirect:
        let
          itemContext = "${context}.redirects[${toString index}]";
          item = checkKeys itemContext [
            "from"
            "permanent"
            "status"
            "to"
          ] (ensure itemContext (isAttrs redirect) "must be an attribute set" redirect);
          from = item.from or null;
          to = item.to or null;
          permanent = item.permanent or null;
          status =
            if item ? status then
              item.status
            else if permanent == false then
              307
            else
              308;
        in
        ensure itemContext (isString from && lib.hasPrefix "/" from) "from must be an absolute path" (
          ensure itemContext (isString to && lib.hasPrefix "/" to) "to must be an absolute path" (
            ensure itemContext (!(item ? status && item ? permanent)) "set either status or permanent, not both"
              (
                ensure itemContext (permanent == null || isBool permanent) "permanent must be a boolean" (
                  ensure itemContext
                    (builtins.elem status [
                      301
                      302
                      307
                      308
                    ])
                    "status must be 301, 302, 307, or 308"
                    {
                      inherit from status to;
                    }
                )
              )
          )
        )
      ) (checked.redirects or [ ]);
      cacheRules = lib.imap0 (
        index: rule:
        let
          itemContext = "${context}.cacheRules[${toString index}]";
          item = checkKeys itemContext [
            "paths"
            "value"
          ] (ensure itemContext (isAttrs rule) "must be an attribute set" rule);
          paths = item.paths or [ ];
          cacheValue = item.value or null;
        in
        ensure itemContext
          (
            builtins.isList paths
            && paths != [ ]
            && lib.all (path: isString path && lib.hasPrefix "/" path) paths
          )
          "paths must be a non-empty list of absolute path matchers"
          (
            ensure itemContext (isString cacheValue && cacheValue != "" && !(lib.hasInfix "\n" cacheValue))
              "value must be a non-empty single-line Cache-Control value"
              {
                inherit paths;
                value = cacheValue;
              }
          )
      ) (checked.cacheRules or [ ]);
    in
    ensure context (isBool compression) "compression must be a boolean" (
      ensure context
        (requestBodyMaxBytes == null || (isInt requestBodyMaxBytes && requestBodyMaxBytes > 0))
        "requestBodyMaxBytes must be null or a positive integer"
        (
          ensure context
            (
              isAttrs responseHeaders
              && lib.all (header: builtins.match headerNamePattern header != null) (
                builtins.attrNames responseHeaders
              )
              && lib.all (value: isString value && !(lib.hasInfix "\n" value)) (
                builtins.attrValues responseHeaders
              )
            )
            "responseHeaders must map header names to strings"
            (
              ensure context
                (streamCloseDelaySec == null || (isInt streamCloseDelaySec && streamCloseDelaySec > 0))
                "streamCloseDelaySec must be null or a positive integer"
                {
                  inherit
                    cacheRules
                    compression
                    redirects
                    requestBodyMaxBytes
                    responseHeaders
                    streamCloseDelaySec
                    ;
                }
            )
        )
    );

  normalizeJobSchedule =
    context: value:
    let
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "cadence"
        "calendar"
        "interval"
      ] attrs;
      calendar = checked.calendar or null;
      interval = checked.interval or null;
      requestedCadence = checked.cadence or null;
      cadence =
        if interval == null then
          null
        else if requestedCadence == null then
          "spaced"
        else
          requestedCadence;
    in
    ensure context ((calendar == null) != (interval == null))
      "must set exactly one of calendar or interval"
      (
        ensure context (calendar == null || (isString calendar && calendar != ""))
          "calendar must be a non-empty string"
          (
            ensure context (interval == null || (isString interval && interval != ""))
              "interval must be a non-empty string"
              (
                ensure context
                  (
                    cadence == null
                    || builtins.elem cadence [
                      "fixed"
                      "spaced"
                    ]
                  )
                  "cadence must be fixed or spaced for interval schedules"
                  (
                    ensure context (interval != null || requestedCadence == null)
                      "cadence only applies to interval schedules"
                      {
                        inherit calendar interval;
                        cadence = if interval == null then null else cadence;
                      }
                  )
              )
          )
      );

  normalizeJob =
    secrets: name: value:
    let
      context = "release.maintenanceJobs.${name}";
      checkedName = checkName context name;
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "action"
        "schedule"
        "secrets"
      ] attrs;
      action = checked.action or name;
      schedule =
        if checked ? schedule then normalizeJobSchedule "${context}.schedule" checked.schedule else null;
      secretNames = checked.secrets or [ ];
      checkedSecrets = checkStringList "${context}.secrets" secretNames;
    in
    builtins.seq checkedName (
      ensure context (isString action && action != "") "action must be a non-empty string" (
        ensure context (lib.all (secret: builtins.hasAttr secret secrets) checkedSecrets)
          "Secrets must reference declared names"
          {
            inherit action;
            secrets = checkedSecrets;
          }
        // lib.optionalAttrs (schedule != null) { inherit schedule; }
      )
    );

  normalizePreDeployTask =
    secrets: name: value:
    let
      context = "release.preDeployTasks.${name}";
      checkedName = checkName context name;
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "action"
        "dependsOn"
        "failureMode"
        "secrets"
        "timeoutSec"
      ] attrs;
      action = checked.action or name;
      dependsOn = checkStringList "${context}.dependsOn" (checked.dependsOn or [ ]);
      secretNames = checkStringList "${context}.secrets" (checked.secrets or [ ]);
      failureMode = checked.failureMode or "fail";
      timeoutSec = checked.timeoutSec or 900;
    in
    builtins.seq checkedName (
      ensure context (isString action && action != "") "action must be a non-empty string" (
        ensure context
          (builtins.elem failureMode [
            "fail"
            "defer"
          ])
          "failureMode must be fail or defer"
          (
            ensure context (isInt timeoutSec && timeoutSec > 0) "timeoutSec must be a positive integer" (
              ensure context (lib.all (secret: builtins.hasAttr secret secrets) secretNames)
                "Secrets must reference declared names"
                {
                  inherit
                    action
                    dependsOn
                    failureMode
                    timeoutSec
                    ;
                  secrets = secretNames;
                }
            )
          )
      )
    );

  normalizeOci =
    name: value:
    let
      context = "release.ociAuxiliaries.${name}";
      checkedName = checkName context name;
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "command"
        "image"
        "ports"
      ] attrs;
      image = checked.image or "";
      command = checked.command or [ ];
      checkedCommand = checkStringList "${context}.command" command;
      ports = lib.mapAttrs (
        portName: port:
        let
          portContext = "${context}.ports.${portName}";
          checkedPortName = checkName portContext portName;
          portAttrs = checkKeys portContext [
            "containerPort"
            "protocol"
          ] (ensure portContext (isAttrs port) "must be an attribute set" port);
          containerPort = portAttrs.containerPort or null;
          protocol = portAttrs.protocol or "tcp";
        in
        builtins.seq checkedPortName (
          ensure portContext (isInt containerPort && containerPort >= 1 && containerPort <= 65535)
            "containerPort must be a valid TCP or UDP port"
            (
              ensure portContext
                (builtins.elem protocol [
                  "tcp"
                  "udp"
                ])
                "protocol must be tcp or udp"
                {
                  inherit containerPort protocol;
                }
            )
        )
      ) (checked.ports or { });
    in
    builtins.seq checkedName (
      ensure context (isString image && builtins.match "^.+@sha256:[0-9a-fA-F]{64}$" image != null)
        "image must be pinned by sha256 digest"
        {
          command = checkedCommand;
          inherit image ports;
        }
    );

  normalizeRelease =
    schemaVersion: secrets: value:
    let
      context = "release";
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context ([
        "action"
        "activationExecutable"
        "backend"
        "commands"
        "executable"
        "health"
        "ingress"
        "maintenanceJobs"
        "ociAuxiliaries"
        "package"
        "preDeployTasks"
        "stateDirectories"
      ]) attrs;
      backend = checked.backend or "service";
      action = checked.action or (if backend == "service" then "web" else null);
      package = checked.package or "projectRelease";
      executable =
        checked.executable or (if backend == "service" then "project-release-runtime" else null);
      activationExecutable = checked.activationExecutable or null;
      stateDirectories = checked.stateDirectories or [ ];
      maintenanceJobs = lib.mapAttrs (normalizeJob secrets) (checked.maintenanceJobs or { });
      commands = lib.mapAttrs (
        name: command:
        normalizeCommand {
          context = "release.commands.${name}";
          inherit name secrets;
          value = command;
        }
      ) (checked.commands or { });
      preDeployTasks = lib.mapAttrs (normalizePreDeployTask secrets) (checked.preDeployTasks or { });
      preDeployReferencesValid = lib.all (
        task: lib.all (dependency: builtins.hasAttr dependency preDeployTasks) task.dependsOn
      ) (builtins.attrValues preDeployTasks);
      validRelative =
        path:
        isString path
        && builtins.match "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" path != null
        && lib.all (segment: segment != "." && segment != "..") (lib.splitString "/" path);
    in
    ensure context (schemaVersion >= 3 || commands == { }) "commands require schemaVersion 3" (
      ensure context
        (builtins.elem backend [
          "service"
          "static"
        ])
        "backend must be service or static"
        (
          ensure context (isString package && builtins.match semanticNamePattern package != null)
            "package must be a simple flake package attribute name"
            (
              ensure context
                (
                  (
                    backend == "service"
                    && isString executable
                    && builtins.match executableNamePattern executable != null
                  )
                  || (backend == "static" && executable == null)
                )
                "service releases require an executable and static releases must not define one"
                (
                  ensure context (backend == "static" || (isString action && action != ""))
                    "service releases require a non-empty action"
                    (
                      ensure context
                        (
                          activationExecutable == null
                          || (
                            isString activationExecutable && builtins.match executableNamePattern activationExecutable != null
                          )
                        )
                        "activationExecutable must be null or a simple executable name"
                        (
                          ensure context (builtins.isList stateDirectories && lib.all validRelative stateDirectories)
                            "stateDirectories must contain safe relative paths"
                            (
                              ensure context (backend == "service" || maintenanceJobs == { })
                                "maintenanceJobs require the service backend"
                                (
                                  ensure context (backend == "service" || commands == { }) "commands require the service backend" (
                                    ensure context (backend == "service" || preDeployTasks == { })
                                      "preDeployTasks require the service backend"
                                      (
                                        ensure context (schemaVersion >= 2 || preDeployTasks == { })
                                          "preDeployTasks require schemaVersion 2 or newer"
                                          (
                                            ensure context preDeployReferencesValid "preDeployTask dependencies must reference declared tasks" (
                                              ensure context (graphIsAcyclic preDeployTasks) "preDeployTask dependency graph must be acyclic" {
                                                inherit action;
                                                inherit
                                                  activationExecutable
                                                  backend
                                                  commands
                                                  executable
                                                  maintenanceJobs
                                                  package
                                                  preDeployTasks
                                                  stateDirectories
                                                  ;
                                                health = normalizeHealth {
                                                  context = "release.health";
                                                  value = checked.health or { };
                                                };
                                                ingress = normalizeIngress (checked.ingress or { });
                                                ociAuxiliaries = lib.mapAttrs normalizeOci (checked.ociAuxiliaries or { });
                                              }
                                            )
                                          )
                                      )
                                  )
                                )
                            )
                        )
                    )
                )
            )
        )
    );

  normalize =
    {
      descriptor,
      expectedProject ? null,
    }:
    let
      context = "root";
      attrs = ensure context (isAttrs descriptor) "must be an attribute set" descriptor;
      checked = checkKeys context [
        "$schema"
        "development"
        "parameters"
        "project"
        "release"
        "schemaVersion"
        "secrets"
      ] attrs;
      schemaVersion = checked.schemaVersion or null;
      project = checkName "project" (checked.project or null);
      secrets = lib.mapAttrs normalizeSecret (checked.secrets or { });
      parameters = lib.mapAttrs normalizeParameter (checked.parameters or { });
      result = {
        inherit
          parameters
          project
          schemaVersion
          secrets
          ;
        development =
          if checked ? development && checked.development != null then
            normalizeDevelopment schemaVersion secrets checked.development
          else
            null;
        release =
          if checked ? release && checked.release != null then
            normalizeRelease schemaVersion secrets checked.release
          else
            null;
      };
    in
    ensure "schemaVersion"
      (builtins.elem schemaVersion [
        1
        2
        3
      ])
      "unsupported schemaVersion ${toString schemaVersion}"
      (
        ensure "root"
          (
            schemaVersion == 1
            || (
              checked ? development && checked.development != null && checked ? release && checked.release != null
            )
          )
          "schemaVersion 2 or newer requires both Development and Release realizations"
          (
            ensure "project" (
              expectedProject == null || expectedProject == project
            ) "expected ${toString expectedProject}, got ${project}" (builtins.deepSeq result result)
          )
      );

  requireRealizations =
    {
      descriptor,
      expectedProject ? null,
    }:
    let
      normalized = normalize { inherit descriptor expectedProject; };
    in
    ensure "root" (
      normalized.development != null && normalized.release != null
    ) "Project must define both Development and Release realizations" normalized;

  resolveParameters =
    {
      allowUnknown ? false,
      descriptor,
      values ? { },
    }:
    let
      normalized = normalize { inherit descriptor; };
      unknown = lib.subtractLists (builtins.attrNames normalized.parameters) (builtins.attrNames values);
      resolved = lib.mapAttrs (
        name: definition:
        if builtins.hasAttr name values then
          ensure "parameters.${name}" (parameterMatches definition.type
            values.${name}
          ) "value does not match type ${definition.type}" values.${name}
        else if definition ? default then
          definition.default
        else if definition.required then
          fail "parameters.${name}" "a value is required"
        else
          null
      ) normalized.parameters;
    in
    ensure "parameters" (
      allowUnknown || unknown == [ ]
    ) "unknown values: ${lib.concatStringsSep ", " unknown}" resolved;

  load =
    {
      path,
      expectedProject ? null,
    }:
    normalize {
      descriptor = builtins.fromJSON (builtins.readFile path);
      inherit expectedProject;
    };

  normalizeReleaseResources =
    value:
    let
      checked = checkKeys "release policy.resources" [ "memory" ] (
        ensure "release policy.resources" (isAttrs value) "must be an attribute set" value
      );
      memory =
        checkKeys "release policy.resources.memory"
          [
            "high"
            "max"
            "swapMax"
          ]
          (
            ensure "release policy.resources.memory" (isAttrs (
              checked.memory or { }
            )) "must be an attribute set" (checked.memory or { })
          );
      checkLimit =
        name:
        let
          limit = memory.${name} or null;
        in
        ensure "release policy.resources.memory.${name}" (
          limit == null || (isString limit && limit != "" && !(lib.hasInfix "\n" limit))
        ) "must be null or a non-empty systemd size string" limit;
    in
    {
      memory = {
        high = checkLimit "high";
        max = checkLimit "max";
        swapMax = checkLimit "swapMax";
      };
    };

  releaseApp =
    {
      descriptor,
      policy,
    }:
    let
      normalized = normalize {
        inherit descriptor;
        expectedProject = policy.project or null;
      };
      release = ensure "release" (
        normalized.release != null
      ) "descriptor does not define a Release realization" normalized.release;
      allowedPolicy = [
        "approvedOci"
        "delivery"
        "domain"
        "environment"
        "environmentFiles"
        "exposeRevision"
        "healthRecovery"
        "jobs"
        "parameters"
        "path"
        "port"
        "project"
        "public"
        "resources"
        "runtime"
        "secrets"
        "source"
      ];
      checkedPolicy = checkKeys "release policy" allowedPolicy policy;
      parameters = resolveParameters {
        allowUnknown = true;
        descriptor = normalized;
        values = checkedPolicy.parameters or { };
      };
      secretBindings = checkedPolicy.secrets or { };
      missingSecrets = lib.filter (
        name: normalized.secrets.${name}.required && !(builtins.hasAttr name secretBindings)
      ) (builtins.attrNames normalized.secrets);
      approvedOci = checkStringList "release policy.approvedOci" (checkedPolicy.approvedOci or [ ]);
      requestedOci = builtins.attrNames release.ociAuxiliaries;
      unapprovedOci = lib.subtractLists approvedOci requestedOci;
      jobs = ensure "release policy.jobs" (isAttrs (
        checkedPolicy.jobs or { }
      )) "must be an attribute set" (checkedPolicy.jobs or { });
      activeJobDeclarations = lib.filterAttrs (
        name: job:
        let
          policy = jobs.${name} or { };
        in
        (policy.enable or true) && ((job ? schedule) || builtins.hasAttr name jobs)
      ) release.maintenanceJobs;
      activeJobs = lib.mapAttrs (
        name: job:
        let
          context = "release policy.jobs.${name}";
          policy = jobs.${name} or { };
          explicitCalendar = policy.calendar or null;
          explicitInterval = policy.interval or null;
          hasExplicitSchedule = explicitCalendar != null || explicitInterval != null;
          defaultSchedule = job.schedule or null;
          calendar =
            if hasExplicitSchedule then
              explicitCalendar
            else if defaultSchedule == null then
              null
            else
              defaultSchedule.calendar;
          interval =
            if hasExplicitSchedule then
              explicitInterval
            else if defaultSchedule == null then
              null
            else
              defaultSchedule.interval;
          defaultCadence = if defaultSchedule == null then "spaced" else defaultSchedule.cadence or "spaced";
          cadence = if interval == null then null else policy.cadence or defaultCadence;
        in
        ensure context ((calendar == null) != (interval == null))
          "must set exactly one of calendar or interval, either in the descriptor or host policy"
          (
            ensure context
              (
                cadence == null
                || builtins.elem cadence [
                  "fixed"
                  "spaced"
                ]
              )
              "cadence must be fixed or spaced for interval schedules"
              (
                ensure context (calendar == null || (policy.cadence or null) == null)
                  "cadence only applies to interval schedules"
                  {
                    inherit calendar cadence interval;
                    onBootSec = policy.onBootSec or "5min";
                    persistent = policy.persistent or true;
                    randomizedDelaySec = policy.randomizedDelaySec or "0";
                  }
              )
          )
      ) activeJobDeclarations;
      resources = normalizeReleaseResources (checkedPolicy.resources or { });
      exposeRevision = ensure "release policy.exposeRevision" (
        !(checkedPolicy.exposeRevision or false) || normalized.schemaVersion >= 2
      ) "requires Project descriptor schemaVersion 2 or newer" (checkedPolicy.exposeRevision or false);
    in
    ensure "release policy" (missingSecrets == [ ])
      "missing required Secret bindings: ${lib.concatStringsSep ", " missingSecrets}"
      (
        ensure "release policy" (unapprovedOci == [ ])
          "OCI auxiliaries require explicit approval: ${lib.concatStringsSep ", " unapprovedOci}"
          (
            {
              inherit (release)
                backend
                executable
                package
                ;
              health = release.health;
              project = {
                # Keep the repository form for artifact compatibility;
                # deployment bindings remain a separate host-owned input.
                inherit descriptor;
                jobs = activeJobs;
                parameterBindings = checkedPolicy.parameters or { };
                healthRecovery = checkedPolicy.healthRecovery or { };
                inherit exposeRevision;
                inherit parameters;
                approvedOci = approvedOci;
                inherit resources;
                secrets = secretBindings;
              };
              source = checkedPolicy.source;
            }
            // lib.optionalAttrs (checkedPolicy ? delivery) { inherit (checkedPolicy) delivery; }
            // lib.optionalAttrs (checkedPolicy ? domain) { inherit (checkedPolicy) domain; }
            // lib.optionalAttrs (checkedPolicy ? environment) { inherit (checkedPolicy) environment; }
            // lib.optionalAttrs (checkedPolicy ? environmentFiles) {
              inherit (checkedPolicy) environmentFiles;
            }
            // lib.optionalAttrs (checkedPolicy ? path) { inherit (checkedPolicy) path; }
            // lib.optionalAttrs (checkedPolicy ? port) { inherit (checkedPolicy) port; }
            // lib.optionalAttrs (checkedPolicy ? public) { inherit (checkedPolicy) public; }
            // lib.optionalAttrs (checkedPolicy ? runtime) { inherit (checkedPolicy) runtime; }
          )
      );
in
{
  inherit
    load
    normalize
    requireRealizations
    releaseApp
    resolveParameters
    ;
  releaseTaskOrder = release: graphOrder release.preDeployTasks;
}
