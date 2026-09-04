# DR8e — Make explicit, Lock columns and repeatability

> **Status: complete — landed 2026-09-03.** Authority: automatic data-format detection §§4.4, 5.2–5.3, 8.3, 10 and 12.4. Requires DR8d.

## Outcome

Give automatically resolved rows two distinct intentional actions. **Make explicit** freezes reader, coding,
dialect, header and character choices without claiming a fixed schema. **Lock columns** additionally materializes
the bounded observed record contract as a `RecordSchema` and attaches strict header/width mapping. Both actions use
the DR8d source-local authoring path and keep future runs deterministic under their stated guarantees.

## Preflight and current anchors

- DR8d's row host, preview store and materialization action;
- `kzen-auto-js/.../document/job/source/DataSourceShapeStore.kt`;
- `kzen-auto-js/.../document/job/source/DataSourceAttributeView.kt` existing schema-draft flow;
- `kzen-auto-common/.../data/schema/AuthoredRecordSchemaDraft.kt`, `RecordSchema.kt` and conventions;
- `kzen-auto-jvm/.../objects/data/schema/DataSchemaDocument.kt`;
- `ConfiguredDelimitedFormat` schema mapping and configured-reader inspection tests; and
- Read worker migration/adoption tests.

## Implementation

1. Add **Make explicit** only when the resolution detail identifies an automatic result and its format has an
   authoring capability. The request carries source/row identity and expected fingerprint/epoch; the server
   revalidates or reuses the exact cached result rather than trusting client-supplied opaque config.
2. Materialize the complete canonical choice: concrete reader config, coding chain, delimiter/framing, header
   policy, character encoding/BOM policy and explicit cleanup controls. Assign the resulting format coordinate and
   encoding to that row. Leave schema absent when the detected result was schema-free.
3. After Make explicit, preview and runtime use strict explicit resolution and perform no probe acquisition. Replace
   the file with one having a different delimiter/header and prove the explicit format fails instead of adapting.
   Replace it with a same-dialect file having different valid columns and prove the schema-free format may observe
   the new contract; UI copy must state this limit.
4. Add **Lock columns** only when the format supports authoring and bounded inspection yields an authorable record
   contract. Reuse the current `DataPart`/shape cache where identity matches; otherwise inspect through
   `ConfiguredDataOpener` under existing inspection budgets. Scalar/dynamic/unrepresentable shapes disable the
   action with a specific explanation.
5. Convert the observed contract with `AuthoredRecordSchemaDraft`, create a source-local `RecordSchema`, and create
   or reuse a source-local explicit format referencing it. Header-present formats use exact-name mapping and strict
   width; positional/headerless formats lock ordered fields according to the reader's existing declared-schema
   rules. Do not infer stronger semantic field types than inspection produced.
6. Apply schema object, format object and row coordinate/encoding in one `SetDocumentObjectsCommand`. Use
   deterministic collision-free names and value-identical reuse. Do not modify or delete shared formats/schemas,
   and do not delete orphaned source-local objects when an override is later cleared.
7. In row details, distinguish the results: `Explicit format` versus `Columns locked`. Explain that Make explicit
   prevents redetection but permits column change, while Lock columns rejects header/width/type drift. Both actions
   are disabled during stale/loading/failure states and revalidate the fingerprint at apply time.
8. Preserve migration semantics. A captured manifest already holds a concrete resolved spec and is unaffected by
   later notation or file replacement. A fresh run uses the authored override and, for locked columns, fails drift
   before emitting incompatible records.
9. Reconcile the older `DataSourceAttributeView` “Create editable schema” path with the new capability. Keep it for
   shared user-authored formats where it remains useful, but share schema-draft/name/command helpers rather than
   duplicating format-specific logic. Do not broaden this session into unrelated editor cleanup.

## Proof and exit

- Make-explicit tests verify zero detection bytes on future resolution, exact canonical choice preservation,
  strict dialect/header/encoding failure, and honest schema-free column variation.
- Lock-columns tests verify notation round-trip and strict rejection of renamed/missing/extra/reordered-as-policy-
  dictates fields, width drift and typed drift; an unchanged replacement remains readable.
- Apply-time fingerprint/epoch mismatch rejects without graph edits. Repeated identical actions reuse value-identical
  objects; name collisions create deterministic alternatives.
- Two rows prove no shared mutation. Clearing either override returns to Automatic while leaving authored objects
  untouched. Captured migration continues with its original manifest.
- UI tests distinguish action availability and copy for authorable, non-authorable, unrepresentable, loading,
  stale and failed results.
- Focused common/JVM/JS tests and full `../kzen-auto` build pass, including configured-reader schema mapping and
  Read worker migration suites.

## Handoff to DR8f

All product behaviour is present. DR8f performs the adversarial matrix, performance/resource measurements,
external extensibility proof and downstream compatibility gate without adding opportunistic features.

## As-built

- Extended the single materialization contract with `Override`, `MakeExplicit` and `LockColumns` intents. The server
  revalidates the exact source, row, fingerprint, current part/spec and automatic provenance before authoring.
- Make explicit materializes the authoritative full `ResolvedReadSpec`, including reader, ordered content-coding
  chain, canonical configuration, charset/BOM policy and cleanup controls. Future resolution is strict and performs
  zero detection reads, while the schema-free contract honestly permits compatible column changes.
- Lock columns reuses the exact-part shape cache or inspects through `ConfiguredDataOpener` under existing bounds.
  Dynamic, scalar and unrepresentable results are rejected. `AuthoredRecordSchemaNotation` converts the observed
  record contract without strengthening inferred types.
- The source-local materializer allocates/reuses the schema first, binds its final coordinate into the explicit
  format body, and returns schema, format and row change for one atomic document command. Header formats use exact
  names; headerless formats use stable positions and strict width.
- Delimited formats support both intents; Plain text supports Make explicit and reports Lock columns unavailable.
  Authored children set `catalogVisible: false`, remain directly coordinate-resolvable and never become global
  catalog/detection candidates. Coding chains remain stable even when later filenames change.
- Generic UI actions are driven by catalog/provenance/shape state. Copy distinguishes `Explicit format` from
  `Columns locked`, disables stale/loading/failure/unrepresentable states and offers bounded Inspect columns when a
  shape is not already cached.

Common DR8e tests passed 9/9; the focused JVM suite passed 50/50; JS compile and the eight-class browser gate passed
in 2m21s. Acceptance tests then proved delimiter/header drift strictness, schema-free compatible variation,
missing/extra/renamed column rejection, exact-name reorder behavior, unchanged replacement, captured-manifest
continuity and fresh locked-contract adoption.
