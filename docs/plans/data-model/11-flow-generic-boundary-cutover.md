# DM11 — Flow port and message-inspection cutover

> **Status: complete 2026-08-28.** Authority: unified data model §§11.3,
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

## As built — 2026-08-28

- `RequiredInput`/`OptionalInput` and output declarations expose `DataContract`. Active messages, batches,
  migration output state, queued edges, and hosted results carry `DataValue`; typed vertex authoring buffers retain
  their ergonomic `T` surface and lift immediately at the runner edge.
- Native ports project through `DefaultNativeTypeResolver` and preserve the original instance. Structural ports
  receive the same `DataValue`. A bound null is a queued value and is distinct from no message, including required
  input readiness. Capability-only run inputs/outputs are included in the compiled binding signature.
- Connection compatibility is enforced when the receiving port accepts a delivery, where both structural and
  loader-local native contracts are available. Existing graph-structure validation remains compile-time; the
  runtime seam rejects native mismatch, nullability, scalar overflow, and loader-identity mismatch before vertex
  code observes a value.
- Runner-owned bounded snapshots provide ordinary data inspection; rejection produces a trace diagnostic without
  failing execution. `FlowVertex.inspectMessage` remains only as an optional renderer for non-data capability state.
- The focused native-identity, structural-identity, and present-null channel tests pass alongside the existing
  readiness, select-last/FizzBuzz, double-emit, migration, context, closure, capability, and cross-flavour hosting
  tests. The composition proof is distributed across the existing Script↔Flow, Script→Job, Flow-hosted-Logic,
  RunWorker, and Report-hosting oracles rather than duplicating them in one four-hop fixture.

### Consolidated acceptance matrix

| Gate | Accepted evidence |
|---|---|
| Foundation DM1–DM7c | Structural/native algebra, literal/native/flat/row backings, bounded snapshots, exclusive builders, one `DataValue` Job carrier, and the post-cutover benchmark gate are green. |
| Bindings DM8–DM9c | Required/optional/default/sensitive bindings, concurrent output settlement, canonical engine API, tuple deletion, publication, and direct downstream rebuilds are green. |
| Script DM10 | Typed replay/migration/handoff, native identity, implicit/control-flow semantics, snapshot diagnostics, Formula canary, and focused/full tests are green. |
| Flow DM11 | Contracted ports, `DataValue` messages/migration, native/structural/null identity, wiring/readiness/capability/context semantics, and focused/full tests are green. |
| Consolidated builds | kzen-lib `build`; kzen-auto `build publishToMavenLocal`; kzen-project, kzen-launcher, and kzen-shell `build`; kzen-sample-plugin Maven `test` all pass. |
