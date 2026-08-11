{
  lib,
  pkgs,
  ...
}:
let
  topology = import ./default.nix { inherit lib; };
  fixtures = import ./fixtures.nix { inherit lib topology; };
  graph = fixtures.graph;
  graphJson = builtins.toJSON graph;
  coverageByDomain = builtins.listToAttrs (
    map (claim: lib.nameValuePair claim.domain claim) graph.coverage
  );
  nodesById = builtins.listToAttrs (map (node: lib.nameValuePair node.id node) graph.nodes);
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
in
{
  fleet-topology-contract = pkgs.runCommand "fleet-topology-contract" { } ''
    mkdir -p "$out"
    printf '%s\n' ${lib.escapeShellArg (builtins.toJSON checkedGraph)} > "$out/graph-v1.json"
  '';
}
