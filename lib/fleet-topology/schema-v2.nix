{ lib }:
let
  v1 = import ./schema-v1.nix { inherit lib; };
  optional = type: {
    inherit type;
    required = false;
  };
  requiredEnum = values: {
    type = "string";
    required = true;
    inherit values;
  };
  nodeLayers = {
    semantic = [
      "externalSystem"
      "fleet"
      "fleetModule"
      "host"
      "project"
      "realization"
      "workload"
    ];
    interface = [
      "dnsName"
      "endpoint"
      "firewallExposure"
      "listener"
      "probe"
      "route"
    ];
    resource = [
      "artifact"
      "repository"
      "secretReference"
      "state"
    ];
    mechanical = [
      "job"
      "socket"
      "timer"
      "unit"
    ];
    diagnostic = [ "opaque" ];
  };
  layerFor =
    groups: kind:
    builtins.head (builtins.attrNames (lib.filterAttrs (_: kinds: builtins.elem kind kinds) groups));
  relationLayers = {
    structural = [ "contains" ];
    traffic = [
      "binds"
      "exposes"
      "forwardsTo"
      "listensOn"
      "permits"
      "resolvesTo"
      "routesTo"
    ];
    mechanical = [
      "activates"
      "conflicts"
      "dependsOn"
      "ordersAfter"
      "partOf"
      "requires"
      "wants"
    ];
    diagnostic = [ "opaqueFor" ];
    semantic = [
      "backsUp"
      "consumes"
      "deploys"
      "emitsTo"
      "implements"
      "monitors"
      "owns"
      "realizes"
      "sourcedFrom"
      "storesIn"
      "triggers"
      "usesSecret"
    ];
  };
  mechanicalFields =
    kind:
    v1.nodeKinds.${kind}.fields
    // {
      management = requiredEnum [
        "managed"
        "reference"
      ];
    };
  listenerFields = v1.nodeKinds.listener.fields // {
    fromPort = optional "port";
    toPort = optional "port";
  };
  routeFields = v1.nodeKinds.route.fields // {
    matchHostnames = optional "nonEmptyStrings";
    portMapping = {
      type = "string";
      required = false;
      values = [ "ordinal" ];
    };
  };
  nodeKinds = lib.mapAttrs (
    kind: descriptor:
    descriptor
    // {
      layer = layerFor nodeLayers kind;
      fields =
        if
          builtins.elem kind [
            "unit"
            "socket"
            "timer"
          ]
        then
          mechanicalFields kind
        else if kind == "listener" then
          listenerFields
        else if kind == "route" then
          routeFields
        else
          descriptor.fields;
    }
  ) v1.nodeKinds;
  relationKinds =
    lib.mapAttrs (
      kind: descriptor:
      descriptor
      // {
        layer = layerFor relationLayers kind;
      }
    ) v1.relationKinds
    // {
      contains = v1.relationKinds.contains // {
        layer = "structural";
        pairs = v1.relationKinds.contains.pairs ++ [
          {
            from = [ "fleet" ];
            to = [
              "dnsName"
              "externalSystem"
            ];
          }
        ];
      };
    };
in
{
  version = 2;
  identityVersion = 1;
  inherit nodeKinds relationKinds;
  invariants = {
    fleetScopedKinds = [ "dnsName" ];
    fleetContainedKinds = [ "dnsName" ];
    portSelectionKinds = [
      "firewallExposure"
      "listener"
    ];
  };
}
