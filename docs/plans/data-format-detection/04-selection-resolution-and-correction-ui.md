# DR8d — selection-time resolution and format-owned correction UI

> **Status: open.** Authority: automatic data-format detection §§4.3, 5.2–5.3, 8.1–8.2, 9 and 12.4. Requires
> DR8c. This session owns preview, presentation and the explicit quick-correction command; it does not implement
> Make explicit or Lock columns.

## Outcome

Selected-file rows resolve as soon as they are added or changed, show the server's concrete result/provenance, and
offer installed per-file format and encoding overrides. A format can contribute its own correction editor. The
built-in delimited editor materializes a source-local configured format for delimiter/header/encoding/skip/comment
changes without adding delimited branches to shared UI code.

## Preflight and current anchors

- `kzen-auto-js/.../document/job/edit/FileSelectionEditor.kt` and its JS tests;
- `kzen-auto-js/.../document/common/file/FileSelectionTable.kt`;
- `kzen-auto-js/.../document/job/source/DataSourceResolveStore.kt`, `DataFormatStore.kt` and bridge wiring;
- `kzen-auto-common/.../data/format/FileFormatCatalog.kt` and `DataSourceConventions.kt`;
- `kzen-auto-jvm/.../objects/datasource/DataSourceActions.kt`; and
- existing notation command patterns in `DataSourceAttributeView.kt` and Custom editors.

## Implementation

1. Add a detached `resolveFile` action that accepts source location plus row identity/current selection values. It
   resolves the source instance and delegates to the same contextual resolver and cache used by full source
   resolution. It returns the common resolution detail and concrete materialization identity; the client does not
   infer extensions, delimiters, encodings or warnings.
2. Add a row-resolution store keyed by source, stable file location and authored format/encoding values. Start work
   on add/replace and invalidate it on remove, reorder replacement, source-format change or per-row override change.
   Use per-row epochs so a late response cannot repaint a newer row. Retain unaffected row results across reorder.
3. Extend catalog/detail models with contributed override-editor marker and authoring availability. Persisted format
   or encoding values absent from the current catalog remain displayed as unavailable choices and can be replaced;
   loading/catalog failure cannot erase them.
4. Enable per-entry format and encoding controls in `FileSelectionTable`. Preserve row selection/shift selection,
   authored order and Details behaviour. A format override triggers a new preview and bypasses Automatic strictly;
   an encoding override triggers a new preview with no fallback.
5. Present four explicit row states: loading, resolved, warning and failure. The compact line shows filename,
   `Automatic → <format>` or explicit format, and basis. Details shows full path, resolved encoding, evidence or
   rejection, warning consequence and corrective controls. Use product terms and one-based rows/columns; never show
   capability class names or raw `FieldId` failures.
6. Define one shared `FormatOverrideEditorHost` selected from the contributed marker. The host passes only common
   resolution/editor state and callbacks. It contains no delimiter/header conditionals. A format with no editor
   still exposes ordinary format/encoding selects and explains why quick controls are unavailable.
7. Implement the built-in delimited editor with delimiter conveniences plus exact single-character entry,
   first-row-header toggle, encoding, non-negative skip-leading-lines and optional comment prefix. Preview makes it
   clear whether row one is consumed and surfaces skipped counts. Do not expose ragged-width/syntax recovery.
8. On Apply, call the DR8a authoring capability through a detached materialization action. Validate against the
   current fingerprint/resolution epoch, return a source-local configured-format notation body, choose a stable
   collision-free child name under the source, and update the row's `format` coordinate. Build the final document
   object map and apply one `SetDocumentObjectsCommand` so a partial edit cannot leave a dangling reference. Set the
   row encoding consistently with the materialized config.
9. Reuse an existing source-local format only when its complete canonical body is value-identical. Never mutate a
   shared format or another row's object. Clearing the row override removes only the coordinate/encoding fields and
   does not silently delete an authored object.
10. Ensure graph changes invalidate preview state and re-resolve through the server. Detection success by itself
    issues no notation command; verify the graph remains byte-for-byte unchanged after selecting and previewing.

## Proof and exit

- Store tests cover initial resolution, per-row concurrency, stale success/failure suppression, removal, reorder,
  changed source format, changed row overrides and cache-compatible rerender.
- UI tests cover loading/resolved/warning/failure copy, exact provenance/encoding, unavailable persisted options,
  and no raw internal type names.
- Applying each delimited control produces a resolvable file-specific format and survives `FileSelectionEntry`
  notation round-trip. Two rows starting from one shared format prove editing one changes only that row.
- Detection preview alone emits no notation command. Apply emits one coherent document transition; injected failure
  leaves the original document intact.
- A test-only contributed format/editor marker mounts through the generic host without editing
  `FileSelectionEditor`, `FileSelectionTable`, or the host. A detectable format without authoring shows the intended
  unavailable explanation.
- Focused common, JVM detached-action and JS store/component tests pass, followed by the full `../kzen-auto` build.
- Run the isolated client-graph boot check from `../kzen-auto/AGENTS.md` so a notation/editor registration mismatch
  cannot ship behind green JVM tests. Do not use or restart the user's running server.

## Handoff to DR8e

The row host can request server-validated materialization and atomically add source-local notation. DR8e reuses
that seam for pinning and schema authoring; it does not create a second command path.
