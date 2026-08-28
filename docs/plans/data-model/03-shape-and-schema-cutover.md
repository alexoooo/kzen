# DM3 — `DataShape` observation envelope and typed schema cutover

> **Status: ready after DM1; may execute before DM2. One implementation session.** Authority: unified data model
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
  `JobUpstreamSchema`, and every JS decoder/store found by `rg "DataShape"`.
- This session does not change `DataCursor` item type, `JobMessage`, or `WorkerLane`; temporary translation at those
  consumers is internal and must be named for deletion in DM7.

## Implementation

1. Move/introduce common `ShapeProvenance`, `ShapeStability`, `SampleCoverage`, `SchemaDiagnostic`, `DataShape`, and
   `DataShapeResult` beside the DM1 type vocabulary in kzen-lib-common. Freeze diagnostics and enforce positive,
   coherent coverage values.
2. Add canonical `ExecutionValue` and kotlinx wire adapters for the envelope, reusing the DM1 type lowering. Keep
   stable machine-readable diagnostic codes and treat location as display-only.
3. Delete kzen-auto's `Tabular` and `Payload` cases. Update `DataSource.staticShape`, `DataOpener.inspectShape`,
   `DataSourceActions`, and `SchemaCache` without changing the declared-first inspection ladder or fingerprints.
4. Change `DataSchemaDocument.shape()` to project ordered `DataSchemaFieldListSpec` entries into a typed
   `DataType.Record`; preserve `TypeMetadata` by mapping it to a `DataContract` rather than discarding it.
5. Make an opened `DataCursor.shape` non-null. Existing file cursors use declared/carried/provider/inferred/runtime
   provenance truthfully; if only headers are known, fields are `Scalar(Text)` rather than untyped labels.
6. Update `JobUpstreamSchema`, detached actions, client decoding, editor suggestions, and diagnostics. UI labels may
   render a type but do not learn about runtime backings or a new shape kind.
7. Add a temporary adapter for the still-legacy `WorkerLane` only where compilation requires it; mark it with DM7
   deletion ownership and keep the new common shape authoritative.
8. Update the data-source analysis pointer/status only where it describes the now-correct implementation; do not
   duplicate the unified model rationale (CC-20).

## Proof

- `DataSchemaDocument` declared `String`, `Int`, nullable, and ordered fields survive shape construction and
  round-trip through both wire codecs; a regression assertion specifically fails under today's labels-only shape.
- Cover unavailable, stable, provisional/coverage, each provenance, and diagnostics.
- Existing declared-first/no-I/O tests, fingerprinted cache tests, File/Logic source tests, and JS `DataShapeTest`
  remain green after adapting expected values.
- Build and publish `../kzen-lib` first (`./gradlew build`, then `./gradlew publishToMavenLocal`). From
  `../kzen-auto`, run focused common tests and `:kzen-auto-jvm:test` for data-source/schema packages, then
  `./gradlew build`. If JS sources changed, force `:kzen-auto-js:jsEsbuildBundle --rerun` before a client boot smoke.

## Exit criteria

- `rg "DataShape\\.(Tabular|Payload)" ../kzen-auto` finds no production use.
- No field type is reduced to a header label and no source-specific payload category exists.
- Publish all kzen-auto artifacts only if a downstream standalone consumer needs this intermediate state.
