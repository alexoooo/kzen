# DM11 — Flow port and message-inspection cutover

> **Status: ready after DM10. One kzen-auto implementation session.** Authority: unified data model §§11.3,
> 13.22, 14.5 step 6, and Flow/end-to-end portions of §15.

## Outcome

Flow ports declare `DataContract`; runtime edges carry `DataValue`. Native typed ports still deliver their original
`T`, structural ports receive `DataValue`, and generic message inspection is snapshot-based. Scheduling, readiness,
capability dispatch, and migration are unchanged.

## Implementation

1. Re-check `FlowLogicCompiler`, `FlowLogic`, `FlowRun`, `FlowWiring`, `FlowVertex`, `RequiredInput`, `OptionalInput`,
   mutable channel implementations, output interfaces, trace inspection, and every first-party/test vertex.
2. Add explicit native and structural port declarations. Native ports capture/resolved `KType`; structural ports
   declare `DataContract`. Do not promise synthesized arbitrary `T` for schema-only records.
3. Validate connections structurally and, where the expected declaration is resolved-native, through the JVM
   resolver. Runtime delivery carries `DataValue` underneath and projects original `T` only at native SPI entry.
4. Lift raw vertex outputs at the edge using the declared/inferred contract. Preserve batches/queues, readiness,
   optional-input behaviour, recoverable execution, context semantics, and migration.
5. Replace per-vertex data renderers with bounded snapshots in the runner. Keep `FlowVertex.inspectMessage` override
   only for non-data state/capabilities; snapshot rejection becomes a trace diagnostic and never fails execution.
6. Delete generic `Any?` channel transport and bridges. Preserve capability-based dispatch—no `when` on concrete
   vertices (CC-17).

## Proof

- Native `RequiredInput<Reading>` gets the identical instance; structural input gets the same value as `DataValue`;
  typed scalar cell projects to `Int` and overflow rejects.
- Port mismatch, unresolved native declaration, same-FQN loader mismatch, union port, nullability, and dynamic port
  cases fail or accept at the correct phase.
- Existing Flow wiring/readiness, FizzBuzz select-last oracle, double emit, migration, context, closure, and
  capability tests stay green.
- Add Script → Flow → Job → nested Logic composition proving contract/native identity and identical
  missing/default/null behaviour.
- Run common Flow tests, full JVM tests, full kzen-auto build, and a client graph boot smoke if common notation or JS
  decoding changed.

## Exit criteria

- Generic Flow channels do not carry `Any?`; typed authoring APIs still expose `T`.
- All foundation plus bindings/Script/Flow cutover gates pass. Record a consolidated acceptance matrix in this
  file's as-built section.
