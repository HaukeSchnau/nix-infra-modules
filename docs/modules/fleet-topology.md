# Fleet Topology

Fleet Topology compiles evaluated NixOS and Darwin configuration into a
canonical desired-state graph. The graph is a pure value: renderers and live
observation tools consume it but do not rediscover infrastructure meaning.

## Interface

The flake exports the compiler as `lib.topology`:

```nix
let
  topology = inputs.nix-infra-modules.lib.topology;
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
  schemaVersion = 1;
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

A consuming flake can expose that value as `fleetTopology`; it remains pure and
can be inspected without building or contacting a host:

```console
nix eval --json .#fleetTopology
```

`tryCompile` returns `{ success, errors, value? }`; `compile` returns the graph
or throws the same deterministically ordered errors. Platform projectors emit
Host nodes and their containment relation, while the fleet owns its one root
node.

## Inference and coverage

The NixOS projector treats `config.systemd.units` as the authoritative
mechanical inventory. Services, sockets, timers, targets, mounts, paths,
slices, and referenced units receive identities derived from canonical full
unit names. Structured dependencies, inverse dependencies, aliases, and
socket/timer activation targets become relations without parsing rendered unit
text, commands, or scripts.

The Darwin projector enumerates `launchd.daemons`, `launchd.agents`, and
`launchd.user.agents`. Both projectors serialize only closed primitive fields;
they never copy commands, scripts, environments, paths, derivations, or Secret
values.

Every mechanical source collection has a coverage claim containing its exact
discovered identities and the node representing each identity. Compilation
fails on missing, extra, overlapping, duplicate, or dangling dispositions.
There is deliberately no silent empty fallback for malformed platform roots.

Inference is structural. It does not parse shell, Caddy text, command lines, or
arbitrary configuration strings, and it does not guess semantic ownership from
unit names. Owning fleet modules can add semantic facts in later fragments.

## Identity and graph invariants

Schema v1 IDs have this canonical shape:

```text
ft:v1:<kind>/<fleet-id>/<scope>/<key>
```

Segments use uppercase percent encoding. Identity is independent of labels and
renderer presentation. Each node belongs to the graph's `fleetId`; the fleet
root uses that identity as its fleet ID and key with `fleet` scope.

The compiler requires:

- one canonical fleet root;
- globally unique node, relation, and coverage identities;
- valid relation endpoint kinds and no dangling endpoints;
- exactly one structural `contains` parent for every non-root node;
- reachability of every node from the fleet root;
- exact coverage reconciliation;
- context-free JSON-safe strings with no Nix store or Secret paths;
- deterministic node, relation, coverage, and digest ordering.

## Schema migration

The schema version is part of every node ID and graph artifact. Schema v1 is a
closed contract: changing kind data, relation endpoint rules, identity grammar,
or canonical serialization requires a new schema version and migration code.
The public contract check pins a complete fixture digest so an accidental v1
wire-format change fails review.

Adding facts that fit the existing closed kinds does not require a schema
change. Renaming an identity is delete-plus-add in v1.

## Desired state only

The canonical graph contains evaluated desired state. Current health, bound
sockets, live Development Instances, and other mutable observations do not
belong in this artifact. A future observed-state projection may refer to the
same stable identities without modifying the desired graph or its digest.
