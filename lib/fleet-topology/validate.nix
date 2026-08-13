{
  lib,
  schema,
  ids,
}:
let
  sortErrors = errors: lib.sort builtins.lessThan (lib.unique errors);
  at = path: message: "${lib.concatStringsSep "." path}: ${message}";
  exactKeys =
    path: allowed: value:
    let
      unknown = lib.subtractLists allowed (builtins.attrNames value);
    in
    lib.optional (unknown != [ ]) (at path "unknown fields: ${lib.concatStringsSep ", " unknown}");
  stringErrors =
    path: value:
    if builtins.isString value then
      let
        lower = lib.toLower value;
      in
      lib.optional (builtins.hasContext value) (at path "strings with Nix store context are forbidden")
      ++ lib.optional (lib.hasInfix "/run/secrets" lower || lib.hasInfix "%2frun%2fsecrets" lower) (
        at path "serialized secret paths are forbidden"
      )
      ++ lib.optional (lib.hasInfix "/nix/store" lower || lib.hasInfix "%2fnix%2fstore" lower) (
        at path "serialized Nix store paths are forbidden"
      )
    else if builtins.isList value then
      lib.concatLists (lib.imap0 (index: item: stringErrors (path ++ [ (toString index) ]) item) value)
    else if builtins.isAttrs value then
      lib.concatLists (
        lib.mapAttrsToList (
          name: item: stringErrors (path ++ [ "<attribute>" ]) name ++ stringErrors (path ++ [ name ]) item
        ) value
      )
    else
      [ ];
  typeMatches =
    type: value:
    if type == "string" then
      builtins.isString value
    else if type == "bool" then
      builtins.isBool value
    else if type == "port" then
      builtins.isInt value && value >= 1 && value <= 65535
    else if type == "strings" then
      builtins.isList value && lib.all builtins.isString value
    else if type == "nonEmptyStrings" then
      builtins.isList value && value != [ ] && lib.all (item: builtins.isString item && item != "") value
    else
      false;
  validateData =
    path: fields: data:
    if !builtins.isAttrs data then
      [ (at path "must be an attribute set") ]
    else
      let
        names = builtins.attrNames fields;
        missing = builtins.filter (name: fields.${name}.required && !(builtins.hasAttr name data)) names;
        invalid = builtins.filter (
          name:
          builtins.hasAttr name data
          && (
            !(typeMatches fields.${name}.type data.${name})
            || (fields.${name}.required && fields.${name}.type == "string" && data.${name} == "")
            || (fields.${name} ? values && !(builtins.elem data.${name} fields.${name}.values))
          )
        ) names;
      in
      exactKeys path names data
      ++ map (name: at path "missing required field ${name}") missing
      ++ map (
        name:
        at (path ++ [ name ]) (
          if fields.${name} ? values then
            "must be one of ${lib.concatStringsSep ", " fields.${name}.values}"
          else if fields.${name}.required && fields.${name}.type == "string" then
            "must be a non-empty string"
          else
            "must have type ${fields.${name}.type}"
        )
      ) invalid;
  validateNode =
    fragmentIndex: source: index: node:
    let
      path = [
        "fragments"
        (toString fragmentIndex)
        "nodes"
        (toString index)
      ];
    in
    if !builtins.isAttrs node then
      [ (at path "must be an attribute set") ]
    else
      let
        kindIsString = node ? kind && builtins.isString node.kind;
        kindIsKnown = kindIsString && builtins.hasAttr node.kind schema.nodeKinds;
        effectiveSource = node.source or source;
      in
      exactKeys path [
        "data"
        "id"
        "kind"
        "label"
        "source"
      ] node
      ++ lib.optional (!(node ? id) || !builtins.isString node.id) (at path "id must be a string")
      ++ lib.optional (!kindIsString) (at path "kind must be a string")
      ++ lib.optional (kindIsString && !kindIsKnown) (at path "unknown node kind ${node.kind}")
      ++ lib.optional (!(node ? label) || !builtins.isString node.label) (
        at path "label must be a string"
      )
      ++ lib.optional (!builtins.isString effectiveSource || effectiveSource == "") (
        at path "source must be a non-empty string"
      )
      ++ lib.optionals (
        kindIsKnown && node ? id && builtins.isString node.id && !(ids.validId node.kind node.id)
      ) [ (at (path ++ [ "id" ]) "does not match the stable identity grammar for kind ${node.kind}") ]
      ++ lib.optionals kindIsKnown (
        validateData (path ++ [ "data" ]) schema.nodeKinds.${node.kind}.fields (node.data or { })
      )
      ++
        lib.optionals
          (
            kindIsKnown
            && builtins.elem node.kind ((schema.invariants or { }).portSelectionKinds or [ "firewallExposure" ])
            && builtins.isAttrs (node.data or null)
          )
          (
            let
              data = node.data;
              hasPort = data ? port;
              hasFrom = data ? fromPort;
              hasTo = data ? toPort;
            in
            lib.optional (!(hasPort != (hasFrom && hasTo)) || (hasFrom != hasTo)) (
              at (path ++ [ "data" ]) "must set either port or both fromPort and toPort"
            )
            ++ lib.optional (
              hasFrom
              && hasTo
              && builtins.isInt data.fromPort
              && builtins.isInt data.toPort
              && data.fromPort > data.toPort
            ) (at (path ++ [ "data" ]) "fromPort must be less than or equal to toPort")
          )
      ++ stringErrors path node;
  validateRelation =
    fragmentIndex: source: index: relation:
    let
      path = [
        "fragments"
        (toString fragmentIndex)
        "relations"
        (toString index)
      ];
      kindIsString = builtins.isAttrs relation && relation ? kind && builtins.isString relation.kind;
      kindIsKnown = kindIsString && builtins.hasAttr relation.kind schema.relationKinds;
    in
    if !builtins.isAttrs relation then
      [ (at path "must be an attribute set") ]
    else
      exactKeys path [
        "data"
        "from"
        "kind"
        "source"
        "to"
      ] relation
      ++ lib.optional (!kindIsString) (at path "kind must be a string")
      ++ lib.optional (kindIsString && !kindIsKnown) (at path "unknown relation kind ${relation.kind}")
      ++ lib.optional (!(relation ? from) || !builtins.isString relation.from) (
        at path "from must be a string"
      )
      ++ lib.optional (!(relation ? to) || !builtins.isString relation.to) (at path "to must be a string")
      ++ lib.optional (
        !builtins.isString (relation.source or source) || (relation.source or source) == ""
      ) (at path "source must be a non-empty string")
      ++ lib.optionals kindIsKnown (
        validateData (path ++ [ "data" ]) schema.relationKinds.${relation.kind}.fields (
          relation.data or { }
        )
      )
      ++ stringErrors path relation;
  stringAttrs =
    value: builtins.isAttrs value && lib.all builtins.isString (builtins.attrValues value);
  validateCoverage =
    fragmentIndex: source: index: claim:
    let
      path = [
        "fragments"
        (toString fragmentIndex)
        "coverage"
        (toString index)
      ];
    in
    if !builtins.isAttrs claim then
      [ (at path "must be an attribute set") ]
    else
      exactKeys path [
        "discovered"
        "domain"
        "excluded"
        "represented"
        "source"
      ] claim
      ++ lib.optional (!(claim ? domain) || !builtins.isString claim.domain || claim.domain == "") (
        at path "domain must be a non-empty string"
      )
      ++ lib.optional (
        !(claim ? discovered)
        || !builtins.isList claim.discovered
        || !(lib.all builtins.isString claim.discovered)
      ) (at path "discovered must be a list of strings")
      ++ lib.optional (!(stringAttrs (claim.represented or null))) (
        at path "represented must map discovery keys to node IDs"
      )
      ++ lib.optional (!(stringAttrs (claim.excluded or null))) (
        at path "excluded must map discovery keys to reasons"
      )
      ++ lib.optionals (stringAttrs (claim.excluded or null)) (
        lib.mapAttrsToList (
          name: _:
          at (
            path
            ++ [
              "excluded"
              name
            ]
          ) "reason must not be empty"
        ) (lib.filterAttrs (_: reason: reason == "") claim.excluded)
      )
      ++ lib.optional (!builtins.isString (claim.source or source) || (claim.source or source) == "") (
        at path "source must be a non-empty string"
      )
      ++ stringErrors path claim;
  validateFragment =
    index: fragment:
    let
      path = [
        "fragments"
        (toString index)
      ];
    in
    if !builtins.isAttrs fragment then
      [ (at path "must be an attribute set") ]
    else
      let
        source = fragment.source or null;
        nodes = fragment.nodes or [ ];
        relations = fragment.relations or [ ];
        coverage = fragment.coverage or [ ];
      in
      exactKeys path [
        "coverage"
        "nodes"
        "relations"
        "source"
      ] fragment
      ++ lib.optional (!builtins.isString source || source == "") (
        at path "source must be a non-empty string"
      )
      ++ lib.optional (!builtins.isList nodes) (at (path ++ [ "nodes" ]) "must be a list")
      ++ lib.optional (!builtins.isList relations) (at (path ++ [ "relations" ]) "must be a list")
      ++ lib.optional (!builtins.isList coverage) (at (path ++ [ "coverage" ]) "must be a list")
      ++ lib.optionals (builtins.isList nodes) (
        lib.concatLists (lib.imap0 (validateNode index source) nodes)
      )
      ++ lib.optionals (builtins.isList relations) (
        lib.concatLists (lib.imap0 (validateRelation index source) relations)
      )
      ++ lib.optionals (builtins.isList coverage) (
        lib.concatLists (lib.imap0 (validateCoverage index source) coverage)
      );
  duplicateValues =
    values:
    builtins.attrNames (
      lib.filterAttrs (_: count: count > 1) (
        lib.foldl' (counts: value: counts // { "${value}" = (counts.${value} or 0) + 1; }) { } values
      )
    );
in
{
  validateInput =
    args:
    sortErrors (
      if !builtins.isAttrs args then
        [ "input: must be an attribute set" ]
      else
        exactKeys
          [ "input" ]
          [
            "fleetId"
            "fragments"
            "schemaVersion"
          ]
          args
        ++ lib.optional ((args.schemaVersion or 1) != schema.version) (
          "input.schemaVersion: only schema version ${toString schema.version} is supported"
        )
        ++ lib.optional (!(args ? fleetId) || !builtins.isString args.fleetId || args.fleetId == "") (
          "input.fleetId: must be a non-empty string"
        )
        ++ lib.optional (!(args ? fragments) || !builtins.isList args.fragments) (
          "input.fragments: must be a list"
        )
        ++ lib.optionals (args ? fragments && builtins.isList args.fragments) (
          lib.concatLists (lib.imap0 validateFragment args.fragments)
        )
        ++ stringErrors [ "input" ] args
    );

  validateGraph =
    graph:
    let
      nodeIds = map (node: node.id) graph.nodes;
      nodeById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) graph.nodes);
      relationIds = map (relation: relation.id) graph.relations;
      coverageIds = map (
        claim:
        builtins.toJSON [
          claim.source
          claim.domain
        ]
      ) graph.coverage;
      identityErrors = lib.concatMap (
        node:
        let
          identity = ids.parseId node.id;
        in
        lib.optional (identity == null) "node ${node.id} is not a canonical topology ID"
        ++ lib.optional (identity != null && identity.fleetId != graph.fleetId) (
          "node ${node.id} belongs to fleet ${identity.fleetId}, expected ${graph.fleetId}"
        )
      ) graph.nodes;
      fleetScopeErrors = lib.concatMap (
        node:
        let
          identity = ids.parseId node.id;
          fleetScopedKinds = (schema.invariants or { }).fleetScopedKinds or [ ];
        in
        lib.optional (
          identity != null && builtins.elem node.kind fleetScopedKinds && identity.scope != "fleet"
        ) "node ${node.id} kind ${node.kind} must use fleet scope"
      ) graph.nodes;
      dangling = lib.concatMap (
        relation:
        lib.optional (!(builtins.hasAttr relation.from nodeById)) (
          "relation ${relation.id} has dangling from ${relation.from}"
        )
        ++ lib.optional (!(builtins.hasAttr relation.to nodeById)) (
          "relation ${relation.id} has dangling to ${relation.to}"
        )
      ) graph.relations;
      endpointErrors = lib.concatMap (
        relation:
        if !(builtins.hasAttr relation.from nodeById) || !(builtins.hasAttr relation.to nodeById) then
          [ ]
        else
          let
            rule = schema.relationKinds.${relation.kind};
            fromKind = nodeById.${relation.from}.kind;
            toKind = nodeById.${relation.to}.kind;
            allowed =
              builtins.elem fromKind rule.from
              && builtins.elem toKind rule.to
              && (
                !(rule ? pairs)
                || lib.any (pair: builtins.elem fromKind pair.from && builtins.elem toKind pair.to) rule.pairs
              );
          in
          lib.optional (!allowed) (
            "relation ${relation.id} kind ${relation.kind} does not allow ${fromKind} -> ${toKind}"
          )
      ) graph.relations;
      fleetNodes = builtins.filter (node: node.kind == "fleet") graph.nodes;
      fleetRoot = if builtins.length fleetNodes == 1 then (builtins.head fleetNodes).id else null;
      fleetRootIdentity = if fleetRoot == null then null else ids.parseId fleetRoot;
      canonicalFleetRoot =
        fleetRootIdentity != null
        && fleetRootIdentity.fleetId == graph.fleetId
        && fleetRootIdentity.scope == "fleet"
        && fleetRootIdentity.key == graph.fleetId;
      structuralRelations = builtins.filter (relation: relation.kind == "contains") graph.relations;
      parentsOf =
        nodeId:
        map (relation: relation.from) (
          builtins.filter (relation: relation.to == nodeId) structuralRelations
        );
      parentErrors = lib.concatMap (
        node:
        let
          parents = parentsOf node.id;
          expected = if node.kind == "fleet" then 0 else 1;
        in
        lib.optional (builtins.length parents != expected) (
          "node ${node.id} must have exactly ${toString expected} contains parents, got ${toString (builtins.length parents)}"
        )
      ) graph.nodes;
      fleetParentErrors = lib.concatMap (
        node:
        let
          fleetContainedKinds = (schema.invariants or { }).fleetContainedKinds or [ ];
        in
        lib.optional (
          fleetRoot != null
          && builtins.elem node.kind fleetContainedKinds
          && parentsOf node.id != [ fleetRoot ]
        ) "node ${node.id} kind ${node.kind} must be contained by the fleet root"
      ) graph.nodes;
      walk =
        visited: frontier:
        let
          next = lib.unique (
            map (relation: relation.to) (
              builtins.filter (relation: builtins.elem relation.from frontier) structuralRelations
            )
          );
          unseen = lib.subtractLists visited next;
        in
        if unseen == [ ] then visited else walk (lib.unique (visited ++ unseen)) unseen;
      reachable = if fleetRoot == null then [ ] else walk [ fleetRoot ] [ fleetRoot ];
      orphans = map (node: "node ${node.id} is not reachable from the fleet root through contains") (
        builtins.filter (node: node.kind != "fleet" && !(builtins.elem node.id reachable)) graph.nodes
      );
      coverageErrors = lib.concatMap (
        claim:
        let
          discovered = lib.sort builtins.lessThan (lib.unique claim.discovered);
          represented = builtins.attrNames claim.represented;
          excluded = builtins.attrNames claim.excluded;
          missing = lib.subtractLists (represented ++ excluded) discovered;
          extra = lib.subtractLists discovered (represented ++ excluded);
          overlap = lib.intersectLists represented excluded;
          danglingRepresentations = lib.filterAttrs (
            _: nodeId: !(builtins.hasAttr nodeId nodeById)
          ) claim.represented;
          prefix = "coverage ${claim.source}:${claim.domain}";
        in
        lib.optional (builtins.length discovered != builtins.length claim.discovered) (
          "${prefix} has duplicate discovered keys"
        )
        ++ map (name: "${prefix} is missing disposition for ${name}") missing
        ++ map (name: "${prefix} has disposition for undiscovered key ${name}") extra
        ++ map (name: "${prefix} both represents and excludes ${name}") overlap
        ++ lib.mapAttrsToList (
          name: nodeId: "${prefix} represents ${name} with dangling node ${nodeId}"
        ) danglingRepresentations
      ) graph.coverage;
    in
    sortErrors (
      map (id: "duplicate node id ${id}") (duplicateValues nodeIds)
      ++ map (id: "duplicate relation ${id}") (duplicateValues relationIds)
      ++ map (id: "duplicate coverage claim ${id}") (duplicateValues coverageIds)
      ++ lib.optional (builtins.length fleetNodes != 1) "graph must contain exactly one fleet root"
      ++ lib.optional (fleetRoot != null && !canonicalFleetRoot) (
        "fleet root must use fleetId as both fleet identity and key with scope fleet"
      )
      ++ identityErrors
      ++ fleetScopeErrors
      ++ dangling
      ++ endpointErrors
      ++ parentErrors
      ++ fleetParentErrors
      ++ orphans
      ++ coverageErrors
    );
}
