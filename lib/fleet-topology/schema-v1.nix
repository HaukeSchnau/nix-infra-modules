{ lib }:
let
  optional = type: {
    inherit type;
    required = false;
  };
  required = type: {
    inherit type;
    required = true;
  };
  nodeKinds = {
    fleet = { };
    host = {
      system = optional "string";
      platform = optional "string";
      role = optional "string";
      address = optional "string";
    };
    fleetModule = {
      category = optional "string";
    };
    project = {
      description = optional "string";
    };
    realization = {
      backend = optional "string";
    };
    workload = {
      runtime = optional "string";
    };
    job = {
      schedule = optional "string";
    };
    unit = {
      unitType = required "string";
      description = optional "string";
    };
    socket = { };
    timer = {
      schedule = optional "string";
    };
    listener = {
      protocol = required "string";
      address = optional "string";
      port = optional "port";
    };
    endpoint = {
      protocol = required "string";
      address = optional "string";
      port = optional "port";
      path = optional "string";
      visibility = optional "string";
    };
    dnsName = {
      name = required "string";
    };
    route = {
      protocol = optional "string";
      visibility = optional "string";
    };
    firewallExposure = {
      protocol = required "string";
      port = optional "port";
      fromPort = optional "port";
      toPort = optional "port";
      interface = optional "string";
    };
    state = {
      path = optional "string";
    };
    secretReference = {
      name = required "string";
      delivery = optional "string";
      required = optional "bool";
    };
    repository = {
      provider = optional "string";
      url = optional "string";
    };
    artifact = {
      artifactType = required "string";
      revision = optional "string";
    };
    externalSystem = {
      category = required "string";
      url = optional "string";
    };
    probe = {
      protocol = required "string";
      path = optional "string";
    };
    opaque = {
      domain = required "string";
      reason = required "string";
    };
  };
  allKinds = builtins.attrNames nodeKinds;
  relation = from: to: {
    inherit from to;
    fields = { };
  };
  broadRelations = lib.genAttrs [
    "backsUp"
    "consumes"
    "deploys"
    "emitsTo"
    "exposes"
    "forwardsTo"
    "implements"
    "listensOn"
    "monitors"
    "opaqueFor"
    "owns"
    "permits"
    "realizes"
    "resolvesTo"
    "routesTo"
    "sourcedFrom"
    "storesIn"
    "triggers"
  ] (_: relation allKinds allKinds);
  mechanicalKinds = [
    "unit"
    "socket"
    "timer"
  ];
  secretConsumers = [
    "fleetModule"
    "project"
    "realization"
    "workload"
    "job"
    "unit"
    "socket"
    "timer"
  ];
  hostChildren = lib.remove "fleet" (lib.remove "host" allKinds);
  moduleChildren = lib.remove "fleet" (lib.remove "host" (lib.remove "fleetModule" allKinds));
  realizationChildren = [
    "workload"
    "job"
    "unit"
    "socket"
    "timer"
    "listener"
    "endpoint"
    "state"
    "secretReference"
    "artifact"
    "probe"
    "opaque"
  ];
  relationKinds = broadRelations // {
    contains =
      (relation [
        "fleet"
        "host"
        "fleetModule"
        "project"
        "realization"
        "workload"
      ] (lib.remove "fleet" allKinds))
      // {
        pairs = [
          {
            from = [ "fleet" ];
            to = [ "host" ];
          }
          {
            from = [ "host" ];
            to = hostChildren;
          }
          {
            from = [ "fleetModule" ];
            to = moduleChildren;
          }
          {
            from = [ "project" ];
            to = [ "realization" ];
          }
          {
            from = [ "realization" ];
            to = realizationChildren;
          }
          {
            from = [ "workload" ];
            to = [
              "job"
              "unit"
              "socket"
              "timer"
              "listener"
              "endpoint"
              "state"
              "secretReference"
              "probe"
              "opaque"
            ];
          }
        ];
      };
    dependsOn = relation mechanicalKinds mechanicalKinds;
    ordersAfter = relation mechanicalKinds mechanicalKinds;
    requires = relation mechanicalKinds mechanicalKinds;
    wants = relation mechanicalKinds mechanicalKinds;
    conflicts = relation mechanicalKinds mechanicalKinds;
    partOf = relation mechanicalKinds mechanicalKinds;
    binds = (relation (mechanicalKinds ++ [ "endpoint" ]) (mechanicalKinds ++ [ "listener" ])) // {
      pairs = [
        {
          from = mechanicalKinds;
          to = mechanicalKinds;
        }
        {
          from = [ "endpoint" ];
          to = [ "listener" ];
        }
      ];
    };
    activates =
      relation
        [
          "socket"
          "timer"
        ]
        [ "unit" ];
    usesSecret = relation secretConsumers [ "secretReference" ];
  };
in
{
  version = 1;
  nodeKinds = lib.mapAttrs (_: fields: { inherit fields; }) nodeKinds;
  inherit relationKinds;
}
