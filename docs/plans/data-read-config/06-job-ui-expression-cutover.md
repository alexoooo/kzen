# DR6 — Job, UI and expression cutover

> **Status: not started. One session (split only at a green boundary if the client surface proves too large).**
> Authority: configurable flat-data reading §§7, 8, 10.6. Requires DR4; independent of DR5.

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
   result contract and appended — no `ColumnValue.toText` flattening.
4. Selection UI (§7): browse/select refs through the source's browser capability; select or create a configured
   format (settle shared-versus-inline ownership, analysis §13 q5); inspect a bounded sample through the real
   stack; show contract and diagnostics; persist source and format notation separately. Hints preselect,
   resolved choices display.
5. Schema draft: inspection may offer inferred field names/candidate types that the user materializes as an
   `AuthoredRecordSchema` to edit — authoring-time convenience producing a declaration, never a runtime rung.

## Proof and exit

- §10.6 end-to-end: source output is `Record(key: Text, value: Decimal)` (not two Text headers) reaching
  downstream validation and the renderer; a typed expression over `value` compiles without text coercion; a
  calculated numeric field stays numeric downstream; `Dynamic` requires keyed access and runs; Unavailable and
  error render differently; swapping local↔fake-S3 or plain↔gzip changes no expression generation when the
  contract is equal.
- Schema-draft flow produces an editable `AuthoredRecordSchema` document/object whose declared read then runs
  deterministically.
- Full builds including `:kzen-auto-js:compileKotlinJs` and the JVM test suites of touched siblings.
