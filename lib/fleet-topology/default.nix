{ lib }:
let
  schema = import ./schema-v1.nix { inherit lib; };
  ids = import ./id.nix { inherit lib schema; };
  validation = import ./validate.nix {
    inherit lib schema ids;
  };
  sortBy = key: lib.sort (left: right: key left < key right);
  normalizeNode = fragment: node: {
    inherit (node) id kind label;
    data = node.data or { };
    source = node.source or fragment.source;
  };
  normalizeRelation =
    fragment: relation:
    let
      value = {
        inherit (relation) kind from to;
        data = relation.data or { };
        source = relation.source or fragment.source;
      };
      identity = {
        inherit (value) kind from to;
      };
    in
    value
    // {
      id = "fr:v${toString schema.version}:${value.kind}:${builtins.hashString "sha256" (builtins.toJSON identity)}";
    };
  normalizeCoverage = fragment: claim: {
    inherit (claim) domain represented excluded;
    discovered = lib.sort builtins.lessThan claim.discovered;
    source = claim.source or fragment.source;
  };
  buildGraph =
    args:
    let
      nodes = sortBy (node: node.id) (
        lib.concatMap (fragment: map (normalizeNode fragment) (fragment.nodes or [ ])) args.fragments
      );
      relations = sortBy (relation: relation.id) (
        lib.concatMap (
          fragment: map (normalizeRelation fragment) (fragment.relations or [ ])
        ) args.fragments
      );
      coverage =
        sortBy
          (
            claim:
            builtins.toJSON [
              claim.source
              claim.domain
            ]
          )
          (
            lib.concatMap (fragment: map (normalizeCoverage fragment) (fragment.coverage or [ ])) args.fragments
          );
      graph = {
        schemaVersion = schema.version;
        inherit (args) fleetId;
        inherit nodes relations coverage;
      };
    in
    graph
    // {
      digest = builtins.hashString "sha256" (builtins.toJSON graph);
    };
  tryCompile =
    args:
    let
      inputErrors = validation.validateInput args;
    in
    if inputErrors != [ ] then
      {
        success = false;
        errors = inputErrors;
      }
    else
      let
        graph = buildGraph args;
        graphErrors = validation.validateGraph graph;
      in
      if graphErrors == [ ] then
        {
          success = true;
          errors = [ ];
          value = graph;
        }
      else
        {
          success = false;
          errors = graphErrors;
        };
in
{
  inherit schema tryCompile;
  inherit (ids) mkId;

  projectNixos = import ./nixos.nix { inherit lib; };
  projectDarwin = import ./darwin.nix { inherit lib; };

  compile =
    args:
    let
      result = tryCompile args;
    in
    if result.success then
      result.value
    else
      throw "fleet topology compilation failed:\n${
        lib.concatMapStringsSep "\n" (error: "- ${error}") result.errors
      }";
}
