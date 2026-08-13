---
status: accepted
---

# Separate topology schema and identity versions

Fleet Topology versions its closed graph data contract independently from its
stable identity grammar. Schema v2 therefore emits `schemaVersion = 2` and
`identityVersion = 1`: new fields and validation rules may change the artifact
without changing what an existing node or relation denotes, so unchanged facts
retain their `ft:v1` and `fr:v1` identities, deep links survive migration, and
desired-state diffs remain meaningful.

The simpler alternative was to derive identity prefixes directly from every
schema version, as v1 originally did. We rejected that because an additive or
corrective schema migration would make the entire fleet appear deleted and
recreated even when most operational identities were unchanged. A future
identity version is required only when the identity grammar changes or an
existing identity would denote a different fact; schema evolution alone does
not justify identity churn.
