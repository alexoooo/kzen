# DM3 — `DataShape` observation envelope and typed schema cutover

> **Status: landed 2026-08-28.** Authority: unified data model
> §5, §11.5, §14.5 step 2, and the shape portions of §15; data-source model §§2.4, 4.3, and 7 retains ownership of
> source selection/inspection.

## Outcome

The shipped `DataShape.Tabular | Payload` carrier classification is replaced by the common observation envelope
around one `DataContract`. `DataSchemaDocument.shape()` preserves every declared field type, and all server/client
wire consumers decode the new vocabulary.

## Preconditions and coordination

- DM1 artifacts are published to Maven Local before standalone kzen-auto builds.
- Read `../kzen-auto/AGENTS.md`. Re-check `DataShape.kt`, `DataSchema.kt`, `DataSchemaDocument.shape`,
  `DataSource.staticShape`, `DataOpener.inspectShape`, `DataCursor.shape`, `DataSourceActions`, `SchemaCache`,
  `FileDataCursor.shape`, `FileDataOpener.inspectBlocking`, `ColumnListingAction`, `JobUpstreamSchema`, and every JS
  decoder/store found by `rg "DataShape"`.
- This session does not change `DataCursor` item type, `JobMessage`, or `WorkerLane`; temporary translation at those
  consumers is internal. Introduce one explicitly legacy cursor/opener fact—working name
  `LegacyCursorItemKind`—that says whether yielded items are flat records or payload values. It is not part of
  `DataContract`, `DataShape`, wire JSON, or client state; `DataReadCore`/`ReadWorker` are its only intended
  consumers, and DM7b owns its deletion.

## Implementation

1. Move/introduce common `ShapeProvenance`, `ShapeStability`, `SampleCoverage`, `SchemaDiagnostic`, `DataShape`, and
   `DataShapeResult` beside the DM1 type vocabulary in kzen-lib-common. Freeze diagnostics and enforce positive,
   coherent coverage values.
2. Add canonical `ExecutionValue` and kotlinx wire adapters for the envelope, reusing the DM1 type lowering. Keep
   stable machine-readable diagnostic codes and treat location as display-only.
3. Delete kzen-auto's `Tabular` and `Payload` cases. Update `DataSource.staticShape`, `DataOpener.inspectShape`,
   `DataSourceActions`, and `SchemaCache` without changing the declared-first inspection ladder or fingerprints.
4. Change `DataSchemaDocument.shape()` to project ordered `DataSchemaFieldListSpec` entries into a typed
   `DataType.Record`; it currently reads only field keys, so begin reading each entry's `TypeMetadata` and map that
   declaration into the resulting `DataContract`.
5. Inventory every `DataCursor` implementation and every `DataReadCore`/caller branch that handles `shape == null`
   before making opened `DataCursor.shape` non-null. Existing file cursors use declared/carried/provider/inferred/
   runtime provenance truthfully; if only headers are known, fields are `Scalar(Text)` rather than untyped labels.
6. Update `JobUpstreamSchema`, detached actions, client decoding, editor suggestions, and diagnostics. UI labels may
   render a type but do not learn about runtime backings or a new shape kind.
7. Route legacy cursor dispatch through `LegacyCursorItemKind` (or the as-built equivalent) and add a temporary
   adapter for the still-legacy `WorkerLane` only where compilation requires it. Keep both internal, keep the new
   common shape authoritative, and mark their exact use sites for DM7b/DM7c deletion respectively.
8. Update the data-source analysis pointer/status only where it describes the now-correct implementation; do not
   duplicate the unified model rationale (CC-20).

## Proof

- `DataSchemaDocument` declared `String`, `Int`, nullable, and ordered fields survive shape construction and
  round-trip through both wire codecs; a regression assertion specifically fails under today's labels-only shape.
- Cover unavailable, stable, provisional/coverage, each provenance, and diagnostics.
- Existing declared-first/no-I/O tests, fingerprinted cache tests, File/Logic source tests, and JS `DataShapeTest`
  remain green after adapting expected values.
- Seed `SchemaCache` with the legacy tabular/payload on-disk wire form and prove decode failure is a harmless cache
  miss that inspection replaces with the new envelope; it must not fail the request or preserve a poisoned entry.
- Build and publish `../kzen-lib` first (`./gradlew build`, then `./gradlew publishToMavenLocal`). From
  `../kzen-auto`, run focused common tests and `:kzen-auto-jvm:test` for data-source/schema packages, then
  `./gradlew build`. If JS sources changed, force `:kzen-auto-js:jsEsbuildBundle --rerun` before a client boot smoke.

## Exit criteria

- `rg "DataShape\\.(Tabular|Payload)" ../kzen-auto` finds no production use.
- No field type is reduced to a header label and no source-specific payload category exists.
- `LegacyCursorItemKind` has no wire/client/public-model presence and is confined to the enumerated cursor/read
  bridge; DM7b is recorded as its sole deletion owner.
- Publish all kzen-auto artifacts only if a downstream standalone consumer needs this intermediate state.

## As built — 2026-08-28

- Added the common observation envelope and both canonical codecs in kzen-lib. `DataShape` now carries one
  `DataContract`; provenance, stability/coverage, and diagnostics are immutable and validated.
- Replaced kzen-auto's shape cases with the shared type. `DataSchemaDocument` preserves ordered declared field
  types and nested native metadata, cursor shapes are non-null, and schema compatibility compares contracts rather
  than observation provenance.
- Added the deliberately temporary `LegacyCursorItemKind` plus `LegacyDataShapeBridge`. Their production use is
  limited to file-cursor/read dispatch, legacy Worker-lane projection, header projection, and the generated formula
  adapter that still emits the missing-cell sentinel. DM7b/DM7c remain the deletion owners.
- Legacy `shape.json` is treated as a disposable miss and is replaced atomically by the new envelope. Tests cover
  typed schema construction (`String`, `Int`, nullable, ordering), both codecs, declared-first inspection, cache
  replacement, file/logic sources, Job reader migration, and JS stores.
- Proof passed: full kzen-lib build and Maven Local publication; focused common/JVM/JS kzen-auto tests; forced
  `:kzen-auto-js:jsEsbuildBundle --rerun`; the Job integration cluster after adding the bridge import to generated
  formula source; and the full kzen-auto build (75 tasks, 7m17s).
