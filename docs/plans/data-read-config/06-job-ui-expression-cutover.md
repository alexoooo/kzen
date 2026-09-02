# DR6 — Job, UI and expression cutover

> **Status: complete — landed 2026-09-01 through three green sub-boundaries (analysis §11 step 6):**
> **DR6a** server/client contract propagation (step 1), **DR6b** typed expressions and exact Decimal (step 3),
> **DR6c** shared contract rendering and authoring UI (steps 2, 4, 5). The master ledger keeps one parent row;
> this file records each sub-boundary's landing so a UI-sized tail never holds completed server type-flow work
> in an unreviewable session. Authority: configurable flat-data reading §§4.6 (Decimal), 7, 8, 10.6. Requires
> DR4; independent of DR5.

## Scope and outcome

The complete `DataContract` flows from source reader through Job validation, cards, connectors and expression
compilation — no `HeaderListing`/`TypeMetadata` reduction on the canonical path — and the source/format
selection UI composes browsing, format selection, inspection and schema-draft authoring.

## Implementation

1. Job validation (§8.1): every Worker transformation consumes and returns a `DataContract` (or
   unavailable/error attempt) via `JobLaneDescriptor.contract`; legacy `payloadType`/`flatColumns` projections
   survive only at boundaries that still require them, never as canonical-walk input. Client inspection retains
   `DataShape` instead of `LegacyDataShapeBridge.headerOrNull`; strict/superset combination reports field/path
   conflicts with both contracts rather than widening to Text. `JobUpstreamSchema`/`DataSourceShapeStore` carry
   `DataContract`/`DataShapeResult` to the final projection.
2. Shared contract renderer (§8.2): one component serves source cards, Worker output and connector
   hover/details — compact summary (`Record · 2 fields`, `Dynamic`, `Unavailable`, `Error`) expanding to ordered
   fields, scalar kinds, optional/nullable, provenance, stability/coverage, per-path diagnostics. The five
   states (contract / Dynamic / Unavailable / error / loading) render distinctly; loading is never persisted.
   No branch on a concrete Worker, provider or schema archetype.
3. Expressions (§8.3): typed accessors generated from the contract with compile-time ordinal resolution;
   provider/compression/charset never enter generated code or the compile cache key. `Dynamic` gets explicit
   keyed access only at genuinely dynamic nodes. Calculated fields are lifted under the compiler's inferred
   result contract and appended — no `ColumnValue.toText` flattening. Complete the exact Decimal path (FR19):
   generated accessors construct/project `BigDecimal` from the canonical decimal text; JVM native scalar binding
   accepts `BigDecimal` without passing through `Double`; correct `JobDataValues`' routing of
   `ScalarKind.Decimal` through `readDouble` and any other Job boundary/materialization flattening. This is a
   named kzen-lib + kzen-auto change — follow the composite publish chain.
4. Selection UI (§7): browse/select refs through the source's browser capability; select or create a configured
   format (settle shared-versus-inline ownership, analysis §13 q5); inspect a bounded sample through the real
   stack; show contract and diagnostics; persist source and format notation separately. Hints preselect,
   resolved choices display.
5. Schema draft: inspection may offer inferred field names/candidate types that the user materializes as an
   `AuthoredRecordSchema` to edit — authoring-time convenience producing a declaration, never a runtime rung.

## Proof and exit

- §10.6 end-to-end: source output is `Record(key: Text, value: Decimal)` (not two Text headers) reaching
  downstream validation and the renderer; a typed expression over `value` compiles without text coercion and
  receives exact `BigDecimal` — proven with a value a `Double` round-trip would corrupt; a calculated numeric
  field stays numeric downstream; `Dynamic` requires keyed access and runs; Unavailable and error render
  differently; swapping local↔fake-S3 or plain↔gzip changes no expression generation when the contract is
  equal.
- Each sub-boundary (DR6a/DR6b/DR6c) lands green with its own focused tests and builds; landings recorded here.
- Schema-draft flow produces an editable `AuthoredRecordSchema` document/object whose declared read then runs
  deterministically.
- Full builds including `:kzen-auto-js:compileKotlinJs` and the JVM test suites of touched siblings.

## As-built — 2026-09-01

The three boundaries landed together in the integrated arc:

- **DR6a — contract flow:** Job source resolution, validation, lane descriptors and client inspection retain
  `DataContract`/`DataShape`. Strict and superset combination preserve declared child contracts and report
  conflicts rather than widening record fields to Text. Legacy header projections remain only at Report/UI
  compatibility boundaries, not as canonical Job-walk input.
- **DR6b — typed expressions:** `JobExpressionCompiler` carries stream and element contracts and resolves record
  ordinals at compile time. Filter, Formula source and Run use contract-native access. Dynamic static lanes get
  syntax validation and compile against the actual element contract at runtime. Decimal access and JVM native
  materialization use exact `BigDecimal`, with bounded canonicalization at text boundaries.
- **DR6c — UI and authoring:** one contract presentation serves source inspection, worker cards and connectors,
  with distinct Loading, Unavailable, Error, Dynamic and Contract states plus ordered fields, native metadata,
  provenance, stability/coverage and diagnostics. Format selection discovers shared configured-format objects
  generically and persists source and format separately. Inspection can materialize an editable
  `AuthoredRecordSchema` draft.

The chosen ownership is shared notation objects for configured formats and authored schemas; no inline reader
configuration was added to file-source notation. Exact Decimal tests, forced JS coverage, the FormulaStep
compiler canary and all final builds are green; totals are recorded in DR7.
