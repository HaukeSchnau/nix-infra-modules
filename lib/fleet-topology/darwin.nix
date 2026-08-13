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
  fail = path: message: throw "fleet topology Darwin projector ${path}: ${message}";
  expectAttrs =
    path: value: if builtins.isAttrs value then value else fail path "must be an attribute set";
  requireAttr =
    path: name: value:
    if builtins.hasAttr name value then value.${name} else fail "${path}.${name}" "is required";
  checkedConfiguration = expectAttrs "configuration" configuration;
  launchd = expectAttrs "configuration.launchd" (
    requireAttr "configuration" "launchd" checkedConfiguration
  );
  launchdUser = expectAttrs "configuration.launchd.user" (
    requireAttr "configuration.launchd" "user" launchd
  );

  source = "platform:darwin:${hostId}";
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

  collections = [
    {
      domain = "config.launchd.daemons";
      jobs = expectAttrs "configuration.launchd.daemons" (
        requireAttr "configuration.launchd" "daemons" launchd
      );
      unitType = "launchd-daemon";
    }
    {
      domain = "config.launchd.agents";
      jobs = expectAttrs "configuration.launchd.agents" (
        requireAttr "configuration.launchd" "agents" launchd
      );
      unitType = "launchd-agent";
    }
    {
      domain = "config.launchd.user.agents";
      jobs = expectAttrs "configuration.launchd.user.agents" (
        requireAttr "configuration.launchd.user" "agents" launchdUser
      );
      unitType = "launchd-user-agent";
    }
  ];
  jobId = unitType: name: mkId "unit" "${unitType}:${name}";
  jobNodes = lib.concatMap (
    collection:
    map (name: {
      id = jobId collection.unitType name;
      kind = "unit";
      label = name;
      data = {
        unitType = collection.unitType;
      }
      // lib.optionalAttrs (topology.schema.version >= 2) {
        management = "managed";
      };
    }) (builtins.attrNames collection.jobs)
  ) collections;
in
{
  inherit source;

  nodes = [
    {
      id = hostNodeId;
      kind = "host";
      label = hostId;
      data.platform = "darwin";
    }
  ]
  ++ jobNodes;

  relations = [
    {
      kind = "contains";
      from = fleetNodeId;
      to = hostNodeId;
    }
  ]
  ++ map (node: {
    kind = "contains";
    from = hostNodeId;
    to = node.id;
  }) jobNodes;

  coverage = map (
    collection:
    let
      names = builtins.attrNames collection.jobs;
    in
    {
      inherit (collection) domain;
      discovered = names;
      represented = lib.genAttrs names (jobId collection.unitType);
      excluded = { };
    }
  ) collections;
}
