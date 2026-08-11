{
  lib,
}:
{
  topology,
  fleetId,
  hostId,
  configuration,
  ...
}:
let
  fail = path: message: throw "fleet topology NixOS projector ${path}: ${message}";
  expectAttrs =
    path: value: if builtins.isAttrs value then value else fail path "must be an attribute set";
  expectString = path: value: if builtins.isString value then value else fail path "must be a string";
  expectStringList =
    path: value:
    if builtins.isList value && lib.all builtins.isString value then
      value
    else
      fail path "must be a list of strings";
  requireAttr =
    path: name: value:
    if builtins.hasAttr name value then value.${name} else fail "${path}.${name}" "is required";

  checkedConfiguration = expectAttrs "configuration" configuration;
  systemd = expectAttrs "configuration.systemd" (
    requireAttr "configuration" "systemd" checkedConfiguration
  );
  units = expectAttrs "configuration.systemd.units" (
    requireAttr "configuration.systemd" "units" systemd
  );
  services = expectAttrs "configuration.systemd.services" (
    requireAttr "configuration.systemd" "services" systemd
  );
  sockets = expectAttrs "configuration.systemd.sockets" (
    requireAttr "configuration.systemd" "sockets" systemd
  );
  timers = expectAttrs "configuration.systemd.timers" (
    requireAttr "configuration.systemd" "timers" systemd
  );

  source = "platform:nixos:${hostId}";
  mkId =
    kind: key:
    topology.mkId {
      inherit fleetId kind key;
      scope = hostId;
    };
  fleetNodeId = topology.mkId {
    inherit fleetId;
    kind = "fleet";
    key = fleetId;
  };
  hostNodeId = mkId "host" hostId;

  unitSuffixes = [
    "automount"
    "device"
    "mount"
    "path"
    "scope"
    "service"
    "slice"
    "socket"
    "swap"
    "target"
    "timer"
  ];
  suffixFor =
    unitName:
    let
      matches = builtins.filter (suffix: lib.hasSuffix ".${suffix}" unitName) unitSuffixes;
    in
    if matches == [ ] then "service" else builtins.head matches;
  canonicalNameFor =
    unitType: name: if lib.hasSuffix ".${unitType}" name then name else "${name}.${unitType}";
  canonicalDependencyName =
    name:
    let
      checked = expectString "systemd dependency" name;
      hasKnownSuffix = lib.any (suffix: lib.hasSuffix ".${suffix}" checked) unitSuffixes;
    in
    if hasKnownSuffix then checked else "${checked}.service";
  kindFor =
    unitName:
    if suffixFor unitName == "socket" then
      "socket"
    else if suffixFor unitName == "timer" then
      "timer"
    else
      "unit";
  idFor = unitName: mkId (kindFor unitName) "systemd:${unitName}";
  dataFor =
    unitName:
    if kindFor unitName == "unit" then { unitType = "systemd-${suffixFor unitName}"; } else { };

  unitNames = builtins.attrNames units;
  serviceNames = builtins.attrNames services;
  socketNames = builtins.attrNames sockets;
  timerNames = builtins.attrNames timers;

  unitValue = unitName: expectAttrs "configuration.systemd.units.${unitName}" units.${unitName};
  aliasEntries = lib.concatMap (
    unitName:
    map
      (alias: {
        name = canonicalDependencyName alias;
        value = unitName;
      })
      (
        expectStringList "configuration.systemd.units.${unitName}.aliases" (
          (unitValue unitName).aliases or [ ]
        )
      )
  ) unitNames;
  counts =
    values: lib.foldl' (result: value: result // { ${value} = (result.${value} or 0) + 1; }) { } values;
  duplicateAliases = builtins.attrNames (
    lib.filterAttrs (_: count: count > 1) (counts (map (entry: entry.name) aliasEntries))
  );
  primaryAliasCollisions = map (entry: entry.name) (
    builtins.filter (entry: builtins.hasAttr entry.name units && entry.name != entry.value) aliasEntries
  );
  aliases =
    if duplicateAliases != [ ] then
      fail "configuration.systemd.units" "aliases resolve to multiple primary units: ${lib.concatStringsSep ", " duplicateAliases}"
    else if primaryAliasCollisions != [ ] then
      fail "configuration.systemd.units" "aliases collide with primary units: ${lib.concatStringsSep ", " primaryAliasCollisions}"
    else
      builtins.listToAttrs aliasEntries;
  resolveName =
    rawName:
    let
      canonical = canonicalDependencyName rawName;
    in
    aliases.${canonical} or canonical;

  canonicalForCollection =
    unitType: domain: name:
    let
      canonical = canonicalNameFor unitType name;
    in
    if builtins.hasAttr canonical units then
      canonical
    else
      fail "${domain}.${name}" "canonical unit ${canonical} is absent from configuration.systemd.units";
  serviceUnitName = canonicalForCollection "service" "configuration.systemd.services";
  socketUnitName = canonicalForCollection "socket" "configuration.systemd.sockets";
  timerUnitName = canonicalForCollection "timer" "configuration.systemd.timers";
  ensureDistinctCollection =
    domain: names:
    let
      duplicates = builtins.attrNames (lib.filterAttrs (_: count: count > 1) (counts names));
    in
    if duplicates == [ ] then
      names
    else
      fail domain "canonical identity collisions: ${lib.concatStringsSep ", " duplicates}";
  serviceUnitNames = ensureDistinctCollection "configuration.systemd.services" (
    map serviceUnitName serviceNames
  );
  socketUnitNames = ensureDistinctCollection "configuration.systemd.sockets" (
    map socketUnitName socketNames
  );
  timerUnitNames = ensureDistinctCollection "configuration.systemd.timers" (
    map timerUnitName timerNames
  );

  dependencySpecs = [
    {
      field = "after";
      kind = "ordersAfter";
      inverse = false;
    }
    {
      field = "before";
      kind = "ordersAfter";
      inverse = true;
    }
    {
      field = "requires";
      kind = "requires";
      inverse = false;
    }
    {
      field = "wants";
      kind = "wants";
      inverse = false;
    }
    {
      field = "bindsTo";
      kind = "binds";
      inverse = false;
    }
    {
      field = "conflicts";
      kind = "conflicts";
      inverse = false;
    }
    {
      field = "partOf";
      kind = "partOf";
      inverse = false;
    }
  ];
  collectionEntries =
    (lib.imap0 (index: name: {
      unitName = builtins.elemAt serviceUnitNames index;
      value = expectAttrs "configuration.systemd.services.${name}" services.${name};
      path = "configuration.systemd.services.${name}";
    }) serviceNames)
    ++ (lib.imap0 (index: name: {
      unitName = builtins.elemAt socketUnitNames index;
      value = expectAttrs "configuration.systemd.sockets.${name}" sockets.${name};
      path = "configuration.systemd.sockets.${name}";
    }) socketNames)
    ++ (lib.imap0 (index: name: {
      unitName = builtins.elemAt timerUnitNames index;
      value = expectAttrs "configuration.systemd.timers.${name}" timers.${name};
      path = "configuration.systemd.timers.${name}";
    }) timerNames);
  directDependencies = lib.concatMap (
    entry:
    lib.concatMap (
      spec:
      map (
        target:
        let
          resolvedTarget = resolveName target;
        in
        if spec.inverse then
          {
            kind = spec.kind;
            from = resolvedTarget;
            to = entry.unitName;
          }
        else
          {
            kind = spec.kind;
            from = entry.unitName;
            to = resolvedTarget;
          }
      ) (expectStringList "${entry.path}.${spec.field}" (entry.value.${spec.field} or [ ]))
    ) dependencySpecs
  ) collectionEntries;
  inverseDependencies = lib.concatMap (
    unitName:
    let
      value = unitValue unitName;
      requiredBy = expectStringList "configuration.systemd.units.${unitName}.requiredBy" (
        value.requiredBy or [ ]
      );
      wantedBy = expectStringList "configuration.systemd.units.${unitName}.wantedBy" (
        value.wantedBy or [ ]
      );
    in
    (map (target: {
      kind = "requires";
      from = resolveName target;
      to = unitName;
    }) requiredBy)
    ++ (map (target: {
      kind = "wants";
      from = resolveName target;
      to = unitName;
    }) wantedBy)
  ) unitNames;

  activationTarget =
    unitType: name: value:
    let
      configName = if unitType == "socket" then "socketConfig" else "timerConfig";
      targetName = if unitType == "socket" then "Service" else "Unit";
      structured = expectAttrs "configuration.systemd.${unitType}s.${name}.${configName}" (
        value.${configName} or { }
      );
      fallback = "${lib.removeSuffix ".${unitType}" name}.service";
    in
    resolveName (
      if builtins.hasAttr targetName structured then
        expectString "configuration.systemd.${unitType}s.${name}.${configName}.${targetName}"
          structured.${targetName}
      else
        fallback
    );
  activations =
    (map (name: {
      kind = "activates";
      from = socketUnitName name;
      to = activationTarget "socket" name (
        expectAttrs "configuration.systemd.sockets.${name}" sockets.${name}
      );
    }) socketNames)
    ++ (map (name: {
      kind = "activates";
      from = timerUnitName name;
      to = activationTarget "timer" name (
        expectAttrs "configuration.systemd.timers.${name}" timers.${name}
      );
    }) timerNames);
  allSemanticRelations = builtins.attrValues (
    builtins.listToAttrs (
      map (relation: lib.nameValuePair (builtins.toJSON relation) relation) (
        directDependencies ++ inverseDependencies ++ activations
      )
    )
  );
  referencedUnitNames = lib.sort builtins.lessThan (
    lib.unique (
      lib.concatMap (
        relation:
        lib.filter (name: !(builtins.hasAttr name units)) [
          relation.from
          relation.to
        ]
      ) allSemanticRelations
    )
  );
  allUnitNames = unitNames ++ referencedUnitNames;
  mechanicalNodes = map (unitName: {
    id = idFor unitName;
    kind = kindFor unitName;
    label = unitName;
    data = dataFor unitName;
  }) allUnitNames;
  collectionCoverage = domain: names: canonicalNames: {
    inherit domain;
    discovered = names;
    represented = lib.listToAttrs (
      lib.imap0 (index: name: lib.nameValuePair name (idFor (builtins.elemAt canonicalNames index))) names
    );
    excluded = { };
  };
in
{
  inherit source;
  nodes = [
    {
      id = hostNodeId;
      kind = "host";
      label = hostId;
      data.platform = "nixos";
    }
  ]
  ++ mechanicalNodes;
  relations = [
    {
      kind = "contains";
      from = fleetNodeId;
      to = hostNodeId;
    }
  ]
  ++ (map (node: {
    kind = "contains";
    from = hostNodeId;
    to = node.id;
  }) mechanicalNodes)
  ++ (map (relation: {
    inherit (relation) kind;
    from = idFor relation.from;
    to = idFor relation.to;
  }) allSemanticRelations);
  coverage = [
    {
      domain = "config.systemd.units";
      discovered = unitNames;
      represented = lib.genAttrs unitNames idFor;
      excluded = { };
    }
    (collectionCoverage "config.systemd.services" serviceNames serviceUnitNames)
    (collectionCoverage "config.systemd.sockets" socketNames socketUnitNames)
    (collectionCoverage "config.systemd.timers" timerNames timerUnitNames)
  ];
}
