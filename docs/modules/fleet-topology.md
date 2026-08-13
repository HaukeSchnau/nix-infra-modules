# Fleet Topology

Fleet Topology compiles evaluated NixOS and Darwin configuration into a
canonical desired-state graph. The graph is a pure value: renderers, query
tools, and live-observation adapters consume its meaning instead of
rediscovering infrastructure semantics.

## Versioned interface

The flake exports both contracts through `lib.topology`:

```nix
let
  topology = inputs.nix-infra-modules.lib.topology.v2;
  fleetId = "example";
  root = {
    source = "fleet:example";
    nodes = [
      {
        id = topology.mkId {
          inherit fleetId;
          kind = "fleet";
          key = fleetId;
        };
        kind = "fleet";
        label = "Example fleet";
        data = { };
      }
    ];
    relations = [ ];
    coverage = [ ];
  };
in
topology.compile {
  inherit fleetId;
  schemaVersion = 2;
  fragments = [
    root
    (topology.projectNixos {
      inherit topology fleetId;
      hostId = "server-1";
      configuration = self.nixosConfigurations.server-1.config;
    })
  ];
}
```

The two explicit interfaces have the same operations:

```nix
topology.v1.{ schema, mkId, tryCompile, compile, projectNixos, projectDarwin }
topology.v2.{ schema, mkId, tryCompile, compile, projectNixos, projectDarwin }
```

The unversioned `topology.{ schema, mkId, tryCompile, compile,
projectNixos, projectDarwin }` attributes remain aliases for v1. Existing
consumers therefore retain byte-identical output until they deliberately
select `topology.v2`.

`tryCompile` returns `{ success, errors, value? }`; `compile` returns the graph
or throws the same deterministically ordered errors. A consumer can expose the
result as `fleetTopology` and inspect it without building or contacting a
Host:

```console
nix eval --json .#fleetTopology
```

## Inference and exact coverage

The NixOS projector treats `config.systemd.units` as the authoritative
mechanical inventory. Services, sockets, timers, targets, mounts, paths,
slices, and structured dependency references receive identities derived from
canonical full unit names. Dependencies, inverse dependencies, aliases, and
socket/timer activation targets become relations without parsing rendered unit
text, commands, or scripts.

In v2, every Unit, Socket, and Timer has a required `data.management` value:

- `managed` means the object exists in the authoritative evaluated platform
  collection;
- `reference` means it was materialized only to preserve the endpoint of a
  structured dependency.

Management is not semantic ownership. A managed Unit may still lack an
`implements` or `owns` relation to a FleetModule or Workload. Reference-only
objects remain searchable inventory facts, but semantic views can suppress
them by default.

The Darwin projector enumerates `launchd.daemons`, `launchd.agents`, and
`launchd.user.agents`; these evaluated jobs are `managed`. Both platform
projectors serialize only closed primitive fields. They never copy commands,
scripts, environments, derivations, Secret values, Secret paths, or Nix store
paths.

Every source collection has an exact coverage claim containing its discovered
keys and the node representing each key. NixOS v2 additionally records the
derived reference-only set as `derived.systemd.references`. Compilation fails
on missing, extra, overlapping, duplicate, or dangling dispositions. There is
no silent empty fallback for malformed platform roots.

Inference is structural. It does not parse shell, Caddy text, command lines,
or arbitrary configuration strings, and it does not guess semantic ownership
from unit names. Owning modules contribute semantic facts from their typed
operational declarations.

## Host matching is not DNS authority

Schema v2 distinguishes a Route matching a hostname from the fleet managing
that hostname in DNS:

```nix
{
  kind = "route";
  data = {
    protocol = "https";
    matchHostnames = [
      "app.example.net"
      "*.preview.example.net"
    ];
  };
}
```

`route.data.matchHostnames` is an optional, non-empty list of non-empty strings.
It records typed routing policy and may include matcher syntax such as a
wildcard. A Caddy virtual host or Project Endpoint must not create a `dnsName`
merely because it names a host.

A `dnsName` represents authoritative desired DNS identity. In v2 it must use
the stable `fleet` identity scope and be directly contained by the Fleet root.
Only a projection backed by authoritative DNS configuration should emit it.
Use `resolvesTo` when that configuration also provides a known desired target.
If authoritative DNS configuration is unavailable, omit the DNS node rather
than infer one from routing policy.

## Scalar listeners and compact ranges

A v2 Listener selects exactly one port shape:

```nix
# One port
data = {
  protocol = "tcp";
  address = "0.0.0.0";
  port = 443;
};

# One compact range
data = {
  protocol = "tcp";
  address = "0.0.0.0";
  fromPort = 30000;
  toPort = 30009;
};
```

`port` is mutually exclusive with `fromPort` and `toPort`; both range bounds
are required together and `fromPort` must not exceed `toPort`. A declared TCP
forward range should compile into one Route, one local range Listener, one
upstream range Listener, and their `listensOn` and `forwardsTo` relations. It
must not expand into one canonical node per port.

A Route whose two ranges map positions one-to-one may set
`data.portMapping = "ordinal"`. Executors and specialized renderers may expand
the range when necessary, but the canonical graph preserves the operational
declaration as one fact.

## Compiler-owned abstraction layers

Every v2 node and relation receives a top-level `layer` during normalization.
Fragments cannot author or override it. The schema owns the mapping so all
consumers agree on the abstraction of a fact.

Node layers are:

| Layer | Meaning |
| --- | --- |
| `semantic` | Fleet, Host, FleetModule, Project, Realization, Workload, and ExternalSystem concepts |
| `interface` | Endpoint, DNSName, Route, Listener, FirewallExposure, and Probe surfaces |
| `resource` | State, SecretReference, Repository, and Artifact resources |
| `mechanical` | Job, Unit, Socket, and Timer implementation facts |
| `diagnostic` | Explicit Opaque modeling gaps |

Relation layers are `structural`, `semantic`, `traffic`, `mechanical`, and
`diagnostic`. For example, `contains` is structural, `routesTo` is traffic,
`implements` is semantic, and `ordersAfter` is mechanical.

Layers are presentation-neutral query facts. View names, default traversal
depth, focus rules, collapsing, layout coordinates, colors, and canvas-versus-
table choices remain downstream. The canonical compiler does not contain a
“Landscape,” “Traffic,” or “Full” preset.

## Identity and graph invariants

Canonical node IDs have this shape:

```text
ft:v<identity-version>:<kind>/<fleet-id>/<scope>/<key>
```

Segments use uppercase percent encoding. Identity is independent of labels,
schema-only metadata, fragment order, and renderer presentation. Each node
belongs to the graph's `fleetId`; the Fleet root uses that identity as both its
fleet ID and key with `fleet` scope.

Schema v2 graph artifacts contain both versions:

```nix
{
  schemaVersion = 2;
  identityVersion = 1;
}
```

`schemaVersion` selects the closed data contract. `identityVersion` selects the
node and relation identity grammar. V2 deliberately retains `ft:v1` and
`fr:v1` identities for semantically unchanged facts, preserving deep links and
meaningful desired-state diffs. See
[ADR 0001](../adr/0001-separate-topology-schema-and-identity-versions.md).

The compiler requires:

- one canonical Fleet root;
- globally unique node, relation, and coverage identities;
- valid relation endpoint kinds and no dangling endpoints;
- exactly one structural `contains` parent for every non-root node;
- reachability of every node from the Fleet root;
- exact coverage reconciliation;
- context-free JSON-safe strings with no Nix store or Secret paths;
- deterministic node, relation, coverage, and digest ordering.

## Migrating from v1 to v2

Migration is explicit:

1. Select `inputs.nix-infra-modules.lib.topology.v2` in the fleet assembler.
2. Pass that selected interface into every platform and domain projector.
3. Set `schemaVersion = 2` on `compile` or `tryCompile` input.
4. Add `management` to manually contributed Unit, Socket, and Timer nodes.
5. Move routing hostnames to `route.data.matchHostnames`; emit fleet-scoped
   `dnsName` nodes only from authoritative DNS configuration.
6. Replace expanded port-range nodes with compact range Listeners and a single
   Route.
7. Update consumers to accept `identityVersion` and compiler-owned `layer`
   fields before switching the produced artifact.
8. Compare v1 and v2 by stable ID. Treat compacted ranges and incorrectly
   inferred DNS nodes as intentional removals/additions; unchanged facts should
   retain identity.

Schema v1 remains frozen and its complete fixture digest is pinned. Additive
facts that fit a selected schema's closed kinds do not require an identity
change. A real change to what an ID denotes requires a new identity version;
renaming or repurposing an identity is never disguised as a schema migration.

## Desired state only

The canonical graph contains evaluated desired state. Current health, bound
sockets, live Development Instances, and other mutable observations do not
belong in this artifact. An observed-state projection may refer to the same
stable identities without modifying the desired graph or its digest.
