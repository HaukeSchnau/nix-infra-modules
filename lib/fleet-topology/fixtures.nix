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
  v2Topology = topology.v2;
  v2Id =
    kind: scope: key:
    v2Topology.mkId {
      inherit
        fleetId
        kind
        scope
        key
        ;
    };
  v2Nixos = v2Topology.projectNixos {
    topology = v2Topology;
    inherit fleetId;
    hostId = "nixos-1";
    configuration = nixosConfiguration [
      "network.target"
      "database.service"
    ];
  };
  v2NixosReordered = v2Topology.projectNixos {
    topology = v2Topology;
    inherit fleetId;
    hostId = "nixos-1";
    configuration = nixosConfiguration [
      "database.service"
      "network.target"
    ];
  };
  v2Darwin = v2Topology.projectDarwin {
    topology = v2Topology;
    inherit fleetId;
    hostId = "darwin-1";
    configuration = darwinConfiguration;
  };
  v2HostId = v2Id "host" "nixos-1" "nixos-1";
  v2DnsId = v2Id "dnsName" "fleet" "app.example.test";
  v2ExternalSystemId = v2Id "externalSystem" "fleet" "source-control";
  v2RouteId = v2Id "route" "nixos-1" "tcp-range:application";
  v2LocalRangeId = v2Id "listener" "nixos-1" "tcp:0.0.0.0:30000-30009";
  v2RemoteRangeId = v2Id "listener" "nixos-1" "tcp:127.0.0.1:40000-40009";
  v2Semantic = {
    source = "fixture:v2-semantics";
    nodes = [
      {
        id = v2DnsId;
        kind = "dnsName";
        label = "app.example.test";
        data.name = "app.example.test";
      }
      {
        id = v2ExternalSystemId;
        kind = "externalSystem";
        label = "Source control";
        data.category = "source-control";
      }
      {
        id = v2RouteId;
        kind = "route";
        label = "Application TCP range";
        data = {
          protocol = "tcp";
          visibility = "public";
          matchHostnames = [ "app.example.test" ];
          portMapping = "ordinal";
        };
      }
      {
        id = v2LocalRangeId;
        kind = "listener";
        label = "TCP 30000-30009";
        data = {
          protocol = "tcp";
          address = "0.0.0.0";
          fromPort = 30000;
          toPort = 30009;
        };
      }
      {
        id = v2RemoteRangeId;
        kind = "listener";
        label = "TCP 40000-40009";
        data = {
          protocol = "tcp";
          address = "127.0.0.1";
          fromPort = 40000;
          toPort = 40009;
        };
      }
    ];
    relations = [
      {
        kind = "contains";
        from = fleetNodeId;
        to = v2DnsId;
      }
      {
        kind = "contains";
        from = fleetNodeId;
        to = v2ExternalSystemId;
      }
      {
        kind = "contains";
        from = v2HostId;
        to = v2RouteId;
      }
      {
        kind = "contains";
        from = v2HostId;
        to = v2LocalRangeId;
      }
      {
        kind = "contains";
        from = v2HostId;
        to = v2RemoteRangeId;
      }
      {
        kind = "listensOn";
        from = v2RouteId;
        to = v2LocalRangeId;
      }
      {
        kind = "forwardsTo";
        from = v2RouteId;
        to = v2RemoteRangeId;
      }
    ];
    coverage = [
      {
        domain = "fixture.tcpForwardRanges";
        discovered = [ "application" ];
        represented.application = v2RouteId;
        excluded = { };
      }
    ];
  };
  compileV2 =
    fragments:
    v2Topology.compile {
      inherit fleetId fragments;
      schemaVersion = 2;
    };
  v2Graph = compileV2 [
    root
    v2Nixos
    v2Darwin
    v2Semantic
  ];
  v2ReorderedGraph = compileV2 [
    v2Semantic
    v2Darwin
    v2NixosReordered
    root
  ];
  v2UnitNode = unitNode // {
    data = unitNode.data // {
      management = "managed";
    };
  };
  v2Input = fragments: {
    inherit fleetId fragments;
    schemaVersion = 2;
  };
  v2ListenerId = v2Id "listener" "host" "test-listener";
  v2NegativeFragment = extraNodes: {
    source = "fixture:v2-negative";
    nodes = [
      hostNode
      v2UnitNode
    ]
    ++ extraNodes;
    relations = [
      rootContains
      hostContains
    ]
    ++ map (node: {
      kind = "contains";
      from = hostNode.id;
      to = node.id;
    }) extraNodes;
    coverage = [ ];
  };
  v2Listener = data: {
    id = v2ListenerId;
    kind = "listener";
    label = "Test listener";
    inherit data;
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

  v2 = {
    inherit
      v2Darwin
      v2DnsId
      v2ExternalSystemId
      v2Graph
      v2LocalRangeId
      v2Nixos
      v2RemoteRangeId
      v2ReorderedGraph
      v2RouteId
      ;
    expectedDigest = "88cd0dc9df70638ad41e104edba35a25a4e514900b04b24a834bc4e4a2c6faf7";
    identities = {
      appService = v2Id "unit" "nixos-1" "systemd:app.service";
      networkTarget = v2Id "unit" "nixos-1" "systemd:network.target";
    };
    negative = {
      invalidFleetChild = v2Input [
        root
        {
          source = "fixture:v2-negative";
          nodes = [
            hostNode
            v2UnitNode
          ];
          relations = [
            rootContains
            {
              kind = "contains";
              from = fleetNodeId;
              to = v2UnitNode.id;
            }
          ];
          coverage = [ ];
        }
      ];
      authoredLayer = v2Input [
        root
        (
          (v2NegativeFragment [ ])
          // {
            nodes = [
              hostNode
              (v2UnitNode // { layer = "mechanical"; })
            ];
          }
        )
      ];
      invalidManagement = v2Input [
        root
        (
          (v2NegativeFragment [ ])
          // {
            nodes = [
              hostNode
              (
                v2UnitNode
                // {
                  data = v2UnitNode.data // {
                    management = "discovered";
                  };
                }
              )
            ];
          }
        )
      ];
      hostnameElement = v2Input [
        root
        (v2NegativeFragment [
          {
            id = v2Id "route" "host" "bad-hostnames";
            kind = "route";
            label = "Bad hostnames";
            data.matchHostnames = [ 42 ];
          }
        ])
      ];
      emptyHostnames = v2Input [
        root
        (v2NegativeFragment [
          {
            id = v2Id "route" "host" "empty-hostnames";
            kind = "route";
            label = "Empty hostnames";
            data.matchHostnames = [ ];
          }
        ])
      ];
      emptyHostname = v2Input [
        root
        (v2NegativeFragment [
          {
            id = v2Id "route" "host" "empty-hostname";
            kind = "route";
            label = "Empty hostname";
            data.matchHostnames = [ "" ];
          }
        ])
      ];
      hostnameStorePath = v2Input [
        root
        (v2NegativeFragment [
          {
            id = v2Id "route" "host" "store-hostname";
            kind = "route";
            label = "Store hostname";
            data.matchHostnames = [ "/nix/store/example" ];
          }
        ])
      ];
      hostnameSecretPath = v2Input [
        root
        (v2NegativeFragment [
          {
            id = v2Id "route" "host" "secret-hostname";
            kind = "route";
            label = "Secret hostname";
            data.matchHostnames = [ "/run/secrets/example" ];
          }
        ])
      ];
      hostScopedDns = v2Input [
        root
        (v2NegativeFragment [
          {
            id = v2Id "dnsName" "host" "bad.example.test";
            kind = "dnsName";
            label = "bad.example.test";
            data.name = "bad.example.test";
          }
        ])
      ];
      hostContainedDns = v2Input [
        root
        (v2NegativeFragment [
          {
            id = v2Id "dnsName" "fleet" "misplaced.example.test";
            kind = "dnsName";
            label = "misplaced.example.test";
            data.name = "misplaced.example.test";
          }
        ])
      ];
      missingPort = v2Input [
        root
        (v2NegativeFragment [
          (v2Listener { protocol = "tcp"; })
        ])
      ];
      missingRangeEnd = v2Input [
        root
        (v2NegativeFragment [
          (v2Listener {
            protocol = "tcp";
            fromPort = 1000;
          })
        ])
      ];
      scalarAndRange = v2Input [
        root
        (v2NegativeFragment [
          (v2Listener {
            protocol = "tcp";
            port = 1000;
            fromPort = 1000;
            toPort = 1001;
          })
        ])
      ];
      reversedRange = v2Input [
        root
        (v2NegativeFragment [
          (v2Listener {
            protocol = "tcp";
            fromPort = 1001;
            toPort = 1000;
          })
        ])
      ];
    };
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
