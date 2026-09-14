{ lib }:
let
  fail = context: message: throw "project ${context}: ${message}";
  check =
    context: condition: message:
    condition || fail context message;
  object =
    context: value:
    assert check context (builtins.isAttrs value) "must be an object";
    value;
  keys =
    context: allowed: value:
    let
      unknown = lib.subtractLists allowed (builtins.attrNames (object context value));
    in
    assert check context (unknown == [ ]) "unknown fields: ${lib.concatStringsSep ", " unknown}";
    value;
  name =
    context: value:
    assert check context (
      builtins.isString value
      && builtins.match "^[A-Za-z0-9_.-]+$" value != null
      && !(builtins.elem value [
        "."
        ".."
      ])
    ) "must be a semantic name";
    value;
  relativePath =
    context: value:
    assert check context (
      builtins.isString value
      && builtins.match "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" value != null
      && lib.all (part: part != "." && part != "..") (lib.splitString "/" value)
    ) "must be a relative path without dot segments";
    value;
  requirement =
    resourceName: value:
    let
      context = "requirements.${resourceName}";
      raw = object context value;
      kind = raw.kind or null;
      allowed = [
        "kind"
        "description"
        "required"
        "realizations"
      ]
      ++ lib.optionals (kind == "postgresql") [
        "majorVersion"
        "majorVersions"
        "dataDirectory"
      ]
      ++ lib.optionals (kind == "directory") [
        "path"
        "persistent"
      ]
      ++ lib.optional (kind == "secret") "generate";
      attrs = keys context allowed raw;
      description = attrs.description or "";
      required = attrs.required or true;
      realizations =
        attrs.realizations or [
          "development"
          "release"
        ];
      generation = attrs.generate or null;
      generated = keys "${context}.generate" [ "bytes" ] generation;
      bytes = generated.bytes or 32;
    in
    assert check context (builtins.elem kind [
      "postgresql"
      "directory"
      "secret"
    ]) "kind must be postgresql, directory, or secret";
    assert check context (builtins.isString description) "description must be a string";
    assert check context (builtins.isBool required) "required must be a boolean";
    assert check context (
      builtins.isList realizations
      && realizations != [ ]
      && lib.all (
        value:
        builtins.elem value [
          "development"
          "release"
        ]
      ) realizations
    ) "realizations must name development and/or release";
    builtins.seq (name context resourceName) (
      {
        inherit
          kind
          description
          required
          realizations
          ;
      }
      // (
        if kind == "postgresql" then
          let
            majorVersions = attrs.majorVersions or [ (attrs.majorVersion or null) ];
          in
          assert check context (
            builtins.isList majorVersions
            && majorVersions != [ ]
            && lib.all (version: builtins.isInt version && version >= 10) majorVersions
            && !(attrs ? majorVersion && attrs ? majorVersions)
          ) "declare majorVersion or a non-empty majorVersions list of integers of at least 10";
          {
            majorVersions = lib.unique majorVersions;
            dataDirectory = relativePath "${context}.dataDirectory" (attrs.dataDirectory or resourceName);
          }
        else if kind == "directory" then
          let
            persistent = attrs.persistent or true;
          in
          assert check context (builtins.isBool persistent) "persistent must be a boolean";
          {
            inherit persistent;
            path = relativePath "${context}.path" (attrs.path or resourceName);
          }
        else
          {
            generate =
              if generation == null then
                null
              else
                assert check context (
                  builtins.isInt bytes && bytes >= 16 && bytes <= 1024
                ) "generate.bytes must be between 16 and 1024; generated values are hexadecimal";
                {
                  inherit bytes;
                };
          }
      )
    );

  environmentValue =
    context: value:
    if builtins.isString value then
      value
    else
      let
        raw = object context value;
        selectors = lib.intersectLists [ "binding" "endpoint" "parameter" "path" "secret" "instance" ] (
          builtins.attrNames raw
        );
        selector = builtins.head selectors;
        attrs = keys context (
          [ selector ]
          ++ lib.optional (builtins.elem selector [
            "binding"
            "endpoint"
          ]) "field"
          ++ lib.optional (selector == "path") "append"
        ) raw;
        selected = attrs.${selector};
        field = attrs.field or null;
      in
      assert check context (
        builtins.length selectors == 1
      ) "must select exactly one runtime binding, endpoint, parameter, path, secret, or instance field";
      assert check context (
        builtins.isString selected && selected != ""
      ) "selector must be a non-empty string";
      assert check context (
        field == null
        || builtins.elem selector [
          "binding"
          "endpoint"
        ]
      ) "field requires a binding or endpoint";
      assert check context (
        !(builtins.elem selector [
          "binding"
          "endpoint"
        ])
        || (builtins.isString field && field != "")
      ) "binding and endpoint references require a field";
      assert check context (
        selector != "path"
        || builtins.elem selected [
          "checkout"
          "state"
          "cache"
          "runtime"
        ]
      ) "unknown runtime path";
      assert check context (selector != "instance" || selected == "id") "unknown instance field";
      attrs
      // lib.optionalAttrs (attrs ? append) { append = relativePath "${context}.append" attrs.append; };

  environmentMap =
    context: values:
    lib.mapAttrs (
      variable: value:
      assert check context (
        builtins.match "^[A-Za-z_][A-Za-z0-9_]*$" variable != null
      ) "invalid environment variable ${variable}";
      environmentValue "${context}.${variable}" value
    ) (object context values);
in
rec {
  normalize = values: lib.mapAttrs requirement (object "requirements" values);

  forRealization =
    realization: requirements:
    lib.filterAttrs (_: requirement: builtins.elem realization requirement.realizations) requirements;

  secretDefinitions =
    requirements:
    lib.mapAttrs (_: definition: {
      inherit (definition) description required;
    }) (lib.filterAttrs (_: definition: definition.kind == "secret") requirements);

  normalizeProviders =
    {
      requirements,
      workloads,
      providers,
    }:
    lib.mapAttrs (
      resourceName: value:
      let
        context = "development.providers.${resourceName}";
        attrs = keys context [ "workload" "port" "database" "user" "majorVersion" ] value;
        workload = attrs.workload or resourceName;
        port = attrs.port or 5432;
        database = attrs.database or "postgres";
        user = attrs.user or "postgres";
        majorVersion = attrs.majorVersion or (builtins.head requirements.${resourceName}.majorVersions);
      in
      assert check context (
        requirements ? ${resourceName} && requirements.${resourceName}.kind == "postgresql"
      ) "must implement a declared PostgreSQL requirement";
      assert check context (builtins.elem majorVersion
        requirements.${resourceName}.majorVersions
      ) "provider majorVersion must satisfy the PostgreSQL requirement";
      assert check context (
        workloads ? ${workload} && workloads.${workload}.kind == "service"
      ) "workload must name a native service";
      assert check context (
        builtins.isInt port && port >= 1 && port <= 65535
      ) "port must be between 1 and 65535";
      {
        inherit workload port majorVersion;
        database = name "${context}.database" database;
        user = name "${context}.user" user;
      }
    ) (object "development.providers" providers);

  normalizeEnvironment =
    values:
    lib.mapAttrs (
      realization: value:
      let
        context = "environment.${realization}";
        attrs = keys context [ "common" "actions" ] value;
      in
      assert check context (builtins.elem realization [
        "development"
        "release"
      ]) "unknown realization";
      {
        common = environmentMap "${context}.common" (attrs.common or { });
        actions = lib.mapAttrs (action: environmentMap "${context}.actions.${action}") (
          attrs.actions or { }
        );
      }
    ) (object "environment" values);

  validateEnvironment =
    { descriptor, environment }:
    lib.mapAttrs (
      realization: definitions:
      let
        context = "environment.${realization}";
        realizationDefinition = descriptor.${realization};
        requirements = forRealization realization descriptor.requirements;
        endpoints =
          if realizationDefinition == null then
            [ ]
          else if realization == "development" then
            builtins.attrNames realizationDefinition.endpoints
          else
            lib.optional (realizationDefinition.action != null) realizationDefinition.action
            ++ lib.concatLists (
              lib.mapAttrsToList (
                auxiliary: value: map (port: "${auxiliary}-${port}") (builtins.attrNames value.ports)
              ) realizationDefinition.ociAuxiliaries
            );
        actions =
          if realizationDefinition == null then
            [ ]
          else if realization == "development" then
            [ realizationDefinition.preparation.action ]
            ++ map (value: value.action) (
              lib.attrValues realizationDefinition.workloads ++ lib.attrValues realizationDefinition.commands
            )
          else
            lib.optional (realizationDefinition.action != null) realizationDefinition.action
            ++ map (value: value.action) (
              lib.attrValues realizationDefinition.preDeployTasks
              ++ lib.attrValues realizationDefinition.maintenanceJobs
              ++ lib.attrValues realizationDefinition.commands
            );
        validate =
          variable: value:
          let
            prefix = "${context}.${variable}";
          in
          if builtins.isString value then
            true
          else if value ? binding then
            assert check prefix (
              requirements ? ${value.binding}
            ) "references an undeclared requirement ${value.binding}";
            check prefix (builtins.elem value.field (
              {
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
              }
              .${requirements.${value.binding}.kind}
            )) "references an unknown binding field"
          else if value ? parameter then
            check prefix (descriptor.parameters ? ${value.parameter}) "references an undeclared parameter"
          else if value ? secret then
            check prefix (descriptor.secrets ? ${value.secret}) "references an undeclared secret"
          else if value ? endpoint then
            check prefix (
              builtins.elem value.endpoint endpoints
              && builtins.elem value.field [
                "url"
                "protocol"
                "listen.host"
                "listen.port"
                "hostNames"
              ]
            ) "references an unknown endpoint or field"
          else
            true;
      in
      assert check context (realizationDefinition != null) "requires the corresponding realization";
      # The devenv adapter checks development action names against its native task graph.
      assert check context (
        realization == "development"
        || lib.all (action: builtins.elem action actions) (builtins.attrNames definitions.actions)
      ) "references an undeclared action";
      {
        common = lib.mapAttrs validate definitions.common;
        actions = lib.mapAttrs (_: lib.mapAttrs validate) definitions.actions;
      }
    ) environment;
}
