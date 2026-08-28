# DM4 — live value contract, literals, snapshots, and deep validation

> **Status: ready after DM1; DM2 is required for JVM-native validation tests. One implementation session.**
> Authority: unified data model §§4.7, 6, 6.2–6.3, 7.1, 12.1, 14.5 step 3, and §15.

## Outcome

`kzen-lib-common` has the read-only `DataValue`/`ValueAccess` contract, a literal backing, explicit deep validation,
and immutable bounded snapshots. The node-handle question is closed by measurement without exposing backing layout.

## Design gate: node handles

Prototype the public `DataNode(Long)` with two literal backings: (a) direct encoded indexes/offsets and (b) a
backing-owned node table. The public rule is fixed—tokens are meaningful only to their `ValueAccess`—so choose per
backing, not globally. Retain one inline-long API if both paths avoid per-field wrappers and the literal/native
implementations can mint/check tokens safely. Split the accessor surface only if the benchmark or type-safety proof
shows a concrete failure. Record the verdict and remove the losing prototype before the session ends.

## Implementation

1. Add `DataNode`, `DataValue`, `DataState`, `DataAccessException`, and the full `ValueAccess` operations. Contract
   violations fail immediately with a `DataProblem`; successful primitive reads allocate nothing.
2. Implement an immutable literal backing and explicit `recordOf`/`RecordLiteral` authoring form. Maps remain
   mappings; record literals preserve order and unique names. Null and absent remain distinct.
3. Implement mapping-key canonicalization and rejection: null/mixed keys stay opaque, canonical-text collisions
   fail, empty untyped mappings report a non-null dynamic key.
4. Implement `DataValueAlgebra.validate` as an explicit walk over paths. It distinguishes type rejection from
   compatible-but-invalid state/presence/variant/runtime reads and never becomes an implicit accessor operation.
5. Add `DataSnapshot`, validated factories, `SnapshotPolicy`, `SnapshotResult`, and sensitivity policy. Freeze all
   containers/binary arrays; strip native metadata by construction; enforce cumulative elements, depth, text,
   binary, and best-effort duration bounds.
6. Lower records, mappings, listings, unions, scalars, null, and binary through the existing `ExecutionValue`
   grammar. Reject opaque, cycles/revisited container identities, duplicate-name records, oversized binary, and
   all partial snapshots. Never emit `binary-handle` from the generic snapshotter.
7. Provide typed snapshot decoding for `DataDefault`'s later use. No generic path may reconstruct semantic data
   from a bare `ExecutionValue` without the structural type.

## Proof

- Read one literal record through structural traversal and specialized scalar access; no child `DataValue` objects
  are created. Add a narrow allocation pin around repeated primitive field reads after setup.
- Cover absent/null/present, wrong operation, stale/wrong runtime class simulated by a hostile test backing,
  union selection, mapping key cases, and exact `DataPathSegment` diagnostics.
- Snapshot every supported case; prove source list/map/byte-array mutation cannot alter snapshot equality/digest.
  Cover cycles, shared containers, two interned strings as independent scalar leaves, limits, sensitivity, opaque,
  and duplicate names.
- Demonstrate validation is linear only when explicitly invoked; constructing/passing a `DataValue` does not walk.
- Run common JVM+JS tests and full kzen-lib build from `../kzen-lib`; publish to Maven Local.

## Exit criteria

- Open question 2 has an as-built verdict and benchmark/allocation evidence.
- Every live value is readable while reachable; no retention state or write method appears in the public API.
