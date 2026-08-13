{
  lib,
  pkgs,
  ...
}:
let
  topology = import ./default.nix { inherit lib; };
  fixtures = import ./fixtures.nix { inherit lib topology; };
  graph = fixtures.graph;
  v2Graph = fixtures.v2.v2Graph;
  graphJson = builtins.toJSON graph;
  coverageByDomain = builtins.listToAttrs (
    map (claim: lib.nameValuePair claim.domain claim) graph.coverage
  );
  nodesById = builtins.listToAttrs (map (node: lib.nameValuePair node.id node) graph.nodes);
  v2NodesById = builtins.listToAttrs (map (node: lib.nameValuePair node.id node) v2Graph.nodes);
  relationsResolve = lib.all (
    relation: builtins.hasAttr relation.from nodesById && builtins.hasAttr relation.to nodesById
  ) graph.relations;
  relationsOfKind = kind: builtins.filter (relation: relation.kind == kind) graph.relations;
  errorsContain =
    needle: input:
    let
      result = topology.tryCompile input;
    in
    !result.success && lib.any (error: lib.hasInfix needle error) result.errors;
  v2ErrorsContain =
    needle: input:
    let
      result = topology.v2.tryCompile input;
    in
    !result.success && lib.any (error: lib.hasInfix needle error) result.errors;
  forceFails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  contextInput = fixtures.negative.storePath // {
    fragments = map (
      fragment:
      fragment
      // {
        nodes = map (
          node: if node.label == "/nix/store/example" then node // { label = "${pkgs.hello}"; } else node
        ) (fragment.nodes or [ ]);
      }
    ) fixtures.negative.storePath.fragments;
  };
  v2ContextInput = fixtures.v2.negative.hostnameStorePath // {
    fragments = map (
      fragment:
      fragment
      // {
        nodes = map (
          node:
          if node.label == "Store hostname" then
            node // { data.matchHostnames = [ "${pkgs.hello}" ]; }
          else
            node
        ) (fragment.nodes or [ ]);
      }
    ) fixtures.v2.negative.hostnameStorePath.fragments;
  };
  v2RelationsOfKind = kind: builtins.filter (relation: relation.kind == kind) v2Graph.relations;
  v2NodeLayers = [
    "diagnostic"
    "interface"
    "mechanical"
    "resource"
    "semantic"
  ];
  v2RelationLayers = [
    "diagnostic"
    "mechanical"
    "semantic"
    "structural"
    "traffic"
  ];
  v2RangeListeners = builtins.filter (
    node: node.kind == "listener" && builtins.hasAttr "fromPort" node.data
  ) v2Graph.nodes;
  relationFromTo =
    relations: kind: from: to:
    builtins.head (
      builtins.filter (
        relation: relation.kind == kind && relation.from == from && relation.to == to
      ) relations
    );
  fleetNodeId = builtins.head (
    map (node: node.id) (builtins.filter (node: node.kind == "fleet") graph.nodes)
  );
  nixosHostId = builtins.head (
    map (node: node.id) (
      builtins.filter (node: node.kind == "host" && node.label == "nixos-1") graph.nodes
    )
  );
  checkedGraph =
    assert graph.schemaVersion == 1;
    assert graph.digest == fixtures.expectedDigest;
    assert builtins.toJSON graph == builtins.toJSON fixtures.reorderedGraph;
    assert graph.nodes == lib.sort (left: right: left.id < right.id) graph.nodes;
    assert graph.relations == lib.sort (left: right: left.id < right.id) graph.relations;
    assert relationsResolve;
    assert !(lib.hasInfix "deliberately-not-serialized" graphJson);
    assert
      coverageByDomain."config.systemd.units".discovered == [
        "app.service"
        "app.socket"
        "app.timer"
        "data.mount"
        "database.service"
      ];
    assert
      builtins.attrNames coverageByDomain."config.systemd.units".represented
      == coverageByDomain."config.systemd.units".discovered;
    assert
      coverageByDomain."config.systemd.services".discovered == [
        "app"
        "database"
      ];
    assert coverageByDomain."config.systemd.sockets".discovered == [ "app" ];
    assert coverageByDomain."config.systemd.timers".discovered == [ "app" ];
    assert coverageByDomain."config.launchd.daemons".discovered == [ "netbird" ];
    assert coverageByDomain."config.launchd.agents".discovered == [ "menu" ];
    assert coverageByDomain."config.launchd.user.agents".discovered == [ "backup" ];
    assert builtins.length (relationsOfKind "activates") == 2;
    assert lib.all (relation: relation.to == fixtures.identities.appService) (
      relationsOfKind "activates"
    );
    assert builtins.hasAttr fixtures.identities.networkTarget nodesById;
    assert !(lib.any (node: node.label == "web.service") graph.nodes);
    assert lib.all (kind: relationsOfKind kind != [ ]) [
      "activates"
      "binds"
      "conflicts"
      "contains"
      "ordersAfter"
      "partOf"
      "requires"
      "wants"
    ];
    assert errorsContain "only schema version 1" fixtures.negative.unsupportedSchema;
    assert errorsContain "stable identity grammar" fixtures.negative.invalidId;
    assert errorsContain "stable identity grammar" fixtures.negative.noncanonicalId;
    assert errorsContain "belongs to fleet another-fleet" fixtures.negative.wrongFleetId;
    assert errorsContain "duplicate node id" fixtures.negative.duplicateNode;
    assert errorsContain "duplicate relation" fixtures.negative.duplicateRelation;
    assert errorsContain "duplicate coverage claim" fixtures.negative.duplicateCoverage;
    assert errorsContain "dangling" fixtures.negative.dangling;
    assert errorsContain "not reachable" fixtures.negative.orphan;
    assert errorsContain "contains parents, got 2" fixtures.negative.multipleParent;
    assert errorsContain "missing disposition" fixtures.negative.coverageGap;
    assert errorsContain "both represents and excludes" fixtures.negative.coverageOverlap;
    assert errorsContain "does not allow unit -> unit" fixtures.negative.endpointMismatch;
    assert errorsContain "serialized secret paths are forbidden" fixtures.negative.secretPath;
    assert errorsContain "serialized Nix store paths are forbidden" fixtures.negative.storePath;
    assert errorsContain "strings with Nix store context are forbidden" contextInput;
    assert forceFails (topology.projectNixos fixtures.malformed.nixos);
    assert forceFails (topology.projectDarwin fixtures.malformed.darwin);
    graph;
  checkedV2Graph =
    assert v2Graph.schemaVersion == 2;
    assert v2Graph.identityVersion == 1;
    assert v2Graph.digest == fixtures.v2.expectedDigest;
    assert builtins.toJSON v2Graph == builtins.toJSON fixtures.v2.v2ReorderedGraph;
    assert fixtures.identities.appService == fixtures.v2.identities.appService;
    assert fixtures.identities.networkTarget == fixtures.v2.identities.networkTarget;
    assert
      (relationFromTo graph.relations "contains" fleetNodeId nixosHostId).id
      == (relationFromTo v2Graph.relations "contains" fleetNodeId nixosHostId).id;
    assert lib.all (node: lib.hasPrefix "ft:v1:" node.id && node ? layer) v2Graph.nodes;
    assert lib.all (relation: lib.hasPrefix "fr:v1:" relation.id && relation ? layer) v2Graph.relations;
    assert lib.all (node: builtins.elem node.layer v2NodeLayers) v2Graph.nodes;
    assert lib.all (relation: builtins.elem relation.layer v2RelationLayers) v2Graph.relations;
    assert v2NodesById.${fixtures.v2.identities.appService}.data.management == "managed";
    assert v2NodesById.${fixtures.v2.identities.networkTarget}.data.management == "reference";
    assert lib.all (node: node.data.management == "managed") (
      builtins.filter (node: lib.hasPrefix "launchd-" (node.data.unitType or "")) v2Graph.nodes
    );
    assert builtins.length v2RangeListeners == 2;
    assert lib.all (
      node: !(node.data ? port) && node.data.fromPort < node.data.toPort
    ) v2RangeListeners;
    assert v2NodesById.${fixtures.v2.v2RouteId}.data.matchHostnames == [ "app.example.test" ];
    assert v2NodesById.${fixtures.v2.v2RouteId}.data.portMapping == "ordinal";
    assert
      (relationFromTo v2Graph.relations "contains" fleetNodeId fixtures.v2.v2DnsId).layer == "structural";
    assert
      (relationFromTo v2Graph.relations "contains" fleetNodeId fixtures.v2.v2ExternalSystemId).layer
      == "structural";
    assert
      builtins.length (
        builtins.filter (
          relation: relation.from == fixtures.v2.v2RouteId && relation.kind == "listensOn"
        ) v2Graph.relations
      ) == 1;
    assert
      builtins.length (
        builtins.filter (
          relation: relation.from == fixtures.v2.v2RouteId && relation.kind == "forwardsTo"
        ) v2Graph.relations
      ) == 1;
    assert lib.any (
      claim:
      claim.domain == "derived.systemd.references"
      && claim.represented."network.target" == fixtures.v2.identities.networkTarget
    ) v2Graph.coverage;
    assert v2ErrorsContain "must be one of managed, reference" fixtures.v2.negative.invalidManagement;
    assert v2ErrorsContain "does not allow fleet -> unit" fixtures.v2.negative.invalidFleetChild;
    assert v2ErrorsContain "unknown fields: layer" fixtures.v2.negative.authoredLayer;
    assert v2ErrorsContain "must have type nonEmptyStrings" fixtures.v2.negative.hostnameElement;
    assert v2ErrorsContain "must have type nonEmptyStrings" fixtures.v2.negative.emptyHostnames;
    assert v2ErrorsContain "must have type nonEmptyStrings" fixtures.v2.negative.emptyHostname;
    assert v2ErrorsContain "serialized Nix store paths are forbidden"
      fixtures.v2.negative.hostnameStorePath;
    assert v2ErrorsContain "serialized secret paths are forbidden"
      fixtures.v2.negative.hostnameSecretPath;
    assert v2ErrorsContain "strings with Nix store context are forbidden" v2ContextInput;
    assert v2ErrorsContain "must use fleet scope" fixtures.v2.negative.hostScopedDns;
    assert v2ErrorsContain "must be contained by the fleet root" fixtures.v2.negative.hostContainedDns;
    assert v2ErrorsContain "must set either port or both fromPort and toPort"
      fixtures.v2.negative.missingPort;
    assert v2ErrorsContain "must set either port or both fromPort and toPort"
      fixtures.v2.negative.missingRangeEnd;
    assert v2ErrorsContain "must set either port or both fromPort and toPort"
      fixtures.v2.negative.scalarAndRange;
    assert v2ErrorsContain "fromPort must be less than or equal to toPort"
      fixtures.v2.negative.reversedRange;
    v2Graph;
in
{
  fleet-topology-contract = pkgs.runCommand "fleet-topology-contract" { } ''
    mkdir -p "$out"
    printf '%s\n' ${lib.escapeShellArg (builtins.toJSON checkedGraph)} > "$out/graph-v1.json"
    printf '%s\n' ${lib.escapeShellArg (builtins.toJSON checkedV2Graph)} > "$out/graph-v2.json"
  '';
}
