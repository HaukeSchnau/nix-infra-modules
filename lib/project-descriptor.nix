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
      startupTimeoutSec = checked.startupTimeoutSec or 60;
      intervalSec = checked.intervalSec or 2;
      requestTimeoutSec = checked.requestTimeoutSec or 5;
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

  graphIsAcyclic =
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
    result.valid;

  normalizeDevelopment =
    schemaVersion: secrets: value:
    let
      context = "development";
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "endpoints"
        "preparation"
        "workloads"
      ] attrs;
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
          item = checkKeys itemContext [
            "action"
            "dependsOn"
            "secrets"
          ] (ensure itemContext (isAttrs workload) "must be an attribute set" workload);
          action = if (item.action or null) == null then name else item.action;
          dependsOn = item.dependsOn or [ ];
          secretNames = item.secrets or [ ];
          checkedDependsOn = checkStringList "${itemContext}.dependsOn" dependsOn;
          checkedSecrets = checkStringList "${itemContext}.secrets" secretNames;
        in
        builtins.seq checkedName (
          ensure itemContext (isString action && action != "") "action must be a non-empty string" {
            inherit action;
            dependsOn = checkedDependsOn;
            secrets = checkedSecrets;
          }
        )
      ) mergedWorkloads;
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
    in
    ensure "development.preparation" (isString preparation.action && preparation.action != "")
      "action must be a non-empty string"
      (
        ensure "development.preparation" (isInt preparation.timeoutSec && preparation.timeoutSec > 0)
          "timeoutSec must be a positive integer"
          (
            ensure context workloadReferencesValid
              "workload dependencies and Secrets must reference declared names"
              (
                ensure context (schemaVersion == 1 || graphIsAcyclic workloads)
                  "Workload dependency graph must be acyclic"
                  (
                    ensure context (lib.all (secret: builtins.hasAttr secret secrets) preparation.secrets)
                      "Preparation Secrets must reference declared names"
                      {
                        inherit endpoints preparation workloads;
                      }
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
      ] attrs;
      compression = checked.compression or false;
      requestBodyMaxBytes = checked.requestBodyMaxBytes or null;
      responseHeaders = checked.responseHeaders or { };
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
            {
              inherit
                cacheRules
                compression
                redirects
                requestBodyMaxBytes
                responseHeaders
                ;
            }
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
        "secrets"
      ] attrs;
      action = checked.action or name;
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
    secrets: value:
    let
      context = "release";
      attrs = ensure context (isAttrs value) "must be an attribute set" value;
      checked = checkKeys context [
        "action"
        "activationExecutable"
        "backend"
        "executable"
        "health"
        "ingress"
        "maintenanceJobs"
        "ociAuxiliaries"
        "package"
        "stateDirectories"
      ] attrs;
      backend = checked.backend or "service";
      action = checked.action or (if backend == "service" then "web" else null);
      package = checked.package or "projectRelease";
      executable =
        checked.executable or (if backend == "service" then "project-release-runtime" else null);
      activationExecutable = checked.activationExecutable or null;
      stateDirectories = checked.stateDirectories or [ ];
      maintenanceJobs = lib.mapAttrs (normalizeJob secrets) (checked.maintenanceJobs or { });
      validRelative =
        path:
        isString path
        && builtins.match "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" path != null
        && lib.all (segment: segment != "." && segment != "..") (lib.splitString "/" path);
    in
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
                              {
                                inherit action;
                                inherit
                                  activationExecutable
                                  backend
                                  executable
                                  maintenanceJobs
                                  package
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
            normalizeRelease secrets checked.release
          else
            null;
      };
    in
    ensure "schemaVersion"
      (builtins.elem schemaVersion [
        1
        2
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
          "schemaVersion 2 requires both Development and Release realizations"
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
      unknown == [ ]
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
        "domain"
        "healthRecovery"
        "jobs"
        "parameters"
        "port"
        "project"
        "public"
        "resources"
        "secrets"
        "source"
      ];
      checkedPolicy = checkKeys "release policy" allowedPolicy policy;
      parameters = resolveParameters {
        descriptor = normalized;
        values = checkedPolicy.parameters or { };
      };
      secretBindings = checkedPolicy.secrets or { };
      missingSecrets = lib.filter (
        name: normalized.secrets.${name}.required && !(builtins.hasAttr name secretBindings)
      ) (builtins.attrNames normalized.secrets);
      unknownSecrets = lib.subtractLists (builtins.attrNames normalized.secrets) (
        builtins.attrNames secretBindings
      );
      approvedOci = checkStringList "release policy.approvedOci" (checkedPolicy.approvedOci or [ ]);
      requestedOci = builtins.attrNames release.ociAuxiliaries;
      unapprovedOci = lib.subtractLists approvedOci requestedOci;
      staleOciApprovals = lib.subtractLists requestedOci approvedOci;
      jobs = ensure "release policy.jobs" (isAttrs (
        checkedPolicy.jobs or { }
      )) "must be an attribute set" (checkedPolicy.jobs or { });
      unknownJobs = lib.subtractLists (builtins.attrNames release.maintenanceJobs) (
        builtins.attrNames jobs
      );
      resources = normalizeReleaseResources (checkedPolicy.resources or { });
    in
    ensure "release policy" (missingSecrets == [ ])
      "missing required Secret bindings: ${lib.concatStringsSep ", " missingSecrets}"
      (
        ensure "release policy" (unknownSecrets == [ ])
          "unknown Secret bindings: ${lib.concatStringsSep ", " unknownSecrets}"
          (
            ensure "release policy" (unapprovedOci == [ ])
              "OCI auxiliaries require explicit approval: ${lib.concatStringsSep ", " unapprovedOci}"
              (
                ensure "release policy" (staleOciApprovals == [ ])
                  "OCI approvals do not match descriptor auxiliaries: ${lib.concatStringsSep ", " staleOciApprovals}"
                  (
                    ensure "release policy" (unknownJobs == [ ])
                      "unknown maintenance jobs: ${lib.concatStringsSep ", " unknownJobs}"
                      (
                        {
                          inherit (release)
                            backend
                            executable
                            package
                            ;
                          health = release.health;
                          project = {
                            # Preserve the repository-authored representation so the
                            # built artifact can be checked against exactly what host
                            # policy pinned. The adapter normalizes this internally.
                            inherit descriptor jobs;
                            healthRecovery = checkedPolicy.healthRecovery or { };
                            inherit parameters;
                            approvedOci = approvedOci;
                            inherit resources;
                            secrets = secretBindings;
                          };
                          source = checkedPolicy.source;
                        }
                        // lib.optionalAttrs (checkedPolicy ? domain) { inherit (checkedPolicy) domain; }
                        // lib.optionalAttrs (checkedPolicy ? port) { inherit (checkedPolicy) port; }
                        // lib.optionalAttrs (checkedPolicy ? public) { inherit (checkedPolicy) public; }
                      )
                  )
              )
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
}
