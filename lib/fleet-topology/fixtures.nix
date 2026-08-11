{
  lib,
  topology,
}:
let
  fleetId = "fixture-fleet";
  id =
    kind: scope: key:
    topology.mkId {
      inherit
        fleetId
        kind
        scope
        key
        ;
    };
  fleetNodeId = id "fleet" "fleet" fleetId;
  root = {
    source = "fixture:root";
    nodes = [
      {
        id = fleetNodeId;
        kind = "fleet";
        label = "Fixture fleet";
        data = { };
      }
    ];
    relations = [ ];
    coverage = [ ];
  };
  emptyUnit = {
    after = [ ];
    before = [ ];
    requires = [ ];
    wants = [ ];
    bindsTo = [ ];
    conflicts = [ ];
    partOf = [ ];
  };
  nixosConfiguration = dependencyOrder: {
    systemd = {
      units = {
        "app.service" = {
          aliases = [ "web.service" ];
          wantedBy = [ "multi-user.target" ];
        };
        "app.socket".aliases = [ ];
        "app.timer" = {
          aliases = [ ];
          requiredBy = [ "timers.target" ];
        };
        "data.mount".aliases = [ ];
        "database.service".aliases = [ ];
      };
      services = {
        app = emptyUnit // {
          after = dependencyOrder;
          before = [ "database.service" ];
          requires = [ "database.service" ];
          wants = [ "app.socket" ];
          bindsTo = [ "data.mount" ];
          conflicts = [ "legacy.service" ];
          partOf = [ "application.target" ];
        };
        database = emptyUnit;
      };
      sockets.app = emptyUnit // {
        socketConfig.Service = "web.service";
      };
      timers.app = emptyUnit // {
        timerConfig.Unit = "app.service";
      };
    };
  };
  darwinConfiguration = {
    launchd = {
      daemons.netbird.serviceConfig.ProgramArguments = [ "/deliberately-not-serialized" ];
      agents.menu.serviceConfig.EnvironmentVariables.UNSAFE = "deliberately-not-serialized";
      user.agents.backup.script = "deliberately-not-serialized";
    };
  };
  nixos = topology.projectNixos {
    inherit topology fleetId;
    hostId = "nixos-1";
    configuration = nixosConfiguration [
      "network.target"
      "database.service"
    ];
  };
  nixosReordered = topology.projectNixos {
    inherit topology fleetId;
    hostId = "nixos-1";
    configuration = nixosConfiguration [
      "database.service"
      "network.target"
    ];
  };
  darwin = topology.projectDarwin {
    inherit topology fleetId;
    hostId = "darwin-1";
    configuration = darwinConfiguration;
  };
  compile =
    fragments:
    topology.compile {
      inherit fleetId fragments;
      schemaVersion = 1;
    };
  graph = compile [
    root
    nixos
    darwin
  ];
  reorderedGraph = compile [
    darwin
    nixosReordered
    root
  ];

  mkNode = kind: scope: key: label: data: {
    id = id kind scope key;
    inherit kind label data;
  };
  hostNode = mkNode "host" "host" "host" "Host" { platform = "nixos"; };
  unitNode = mkNode "unit" "host" "unit.service" "unit.service" { unitType = "systemd-service"; };
  hostContains = {
    kind = "contains";
    from = hostNode.id;
    to = unitNode.id;
  };
  rootContains = {
    kind = "contains";
    from = fleetNodeId;
    to = hostNode.id;
  };
  fragment =
    overrides:
    {
      source = "fixture:negative";
      nodes = [
        hostNode
        unitNode
      ];
      relations = [
        rootContains
        hostContains
      ];
      coverage = [ ];
    }
    // overrides;
  input = fragments: {
    inherit fleetId fragments;
    schemaVersion = 1;
  };
in
{
  inherit
    darwin
    fleetId
    graph
    nixos
    reorderedGraph
    root
    ;

  expectedDigest = "061591f167410043b8dce808d27baa5b63cbefc7d85fb462c7c9e9893cdf72d7";

  identities = {
    appService = id "unit" "nixos-1" "systemd:app.service";
    appSocket = id "socket" "nixos-1" "systemd:app.socket";
    appTimer = id "timer" "nixos-1" "systemd:app.timer";
    networkTarget = id "unit" "nixos-1" "systemd:network.target";
  };

  negative = {
    unsupportedSchema = (input [ root ]) // {
      schemaVersion = 2;
    };
    invalidId = input [
      root
      (fragment {
        nodes = [
          (unitNode // { id = "not-a-topology-id"; })
          hostNode
        ];
      })
    ];
    noncanonicalId = input [
      root
      (fragment {
        nodes = [
          (unitNode // { id = "ft:v1:unit/fixture-fleet/host/bad%2fkey"; })
          hostNode
        ];
      })
    ];
    wrongFleetId = input [
      root
      (fragment {
        nodes = [
          hostNode
          (
            unitNode
            // {
              id = topology.mkId {
                fleetId = "another-fleet";
                kind = "unit";
                scope = "host";
                key = "unit.service";
              };
            }
          )
        ];
      })
    ];
    duplicateNode = input [
      root
      (fragment {
        nodes = [
          hostNode
          unitNode
          unitNode
        ];
      })
    ];
    duplicateRelation = input [
      root
      (fragment {
        relations = [
          rootContains
          hostContains
          hostContains
        ];
      })
    ];
    duplicateCoverage = input [
      root
      (fragment {
        coverage = [
          {
            domain = "units";
            discovered = [ ];
            represented = { };
            excluded = { };
          }
          {
            domain = "units";
            discovered = [ ];
            represented = { };
            excluded = { };
          }
        ];
      })
    ];
    dangling = input [
      root
      (fragment {
        relations = [
          rootContains
          (hostContains // { to = id "unit" "host" "missing.service"; })
        ];
      })
    ];
    orphan = input [
      root
      (fragment { relations = [ rootContains ]; })
    ];
    multipleParent = input [
      root
      (fragment {
        relations = [
          rootContains
          hostContains
          (hostContains // { from = fleetNodeId; })
        ];
      })
    ];
    coverageGap = input [
      root
      (fragment {
        coverage = [
          {
            domain = "units";
            discovered = [ "unit.service" ];
            represented = { };
            excluded = { };
          }
        ];
      })
    ];
    coverageOverlap = input [
      root
      (fragment {
        coverage = [
          {
            domain = "units";
            discovered = [ "unit.service" ];
            represented."unit.service" = unitNode.id;
            excluded."unit.service" = "temporary";
          }
        ];
      })
    ];
    endpointMismatch = input [
      root
      (fragment {
        relations = [
          rootContains
          hostContains
          {
            kind = "activates";
            from = unitNode.id;
            to = unitNode.id;
          }
        ];
      })
    ];
    secretPath = input [
      root
      (fragment {
        nodes = [
          hostNode
          (unitNode // { label = "/run/secrets/example"; })
        ];
      })
    ];
    storePath = input [
      root
      (fragment {
        nodes = [
          hostNode
          (unitNode // { label = "/nix/store/example"; })
        ];
      })
    ];
  };

  malformed = {
    nixos = {
      inherit topology fleetId;
      hostId = "bad-nixos";
      configuration.systemd = {
        units = [ ];
        services = { };
        sockets = { };
        timers = { };
      };
    };
    darwin = {
      inherit topology fleetId;
      hostId = "bad-darwin";
      configuration.launchd = {
        daemons = [ ];
        agents = { };
        user.agents = { };
      };
    };
  };
}
