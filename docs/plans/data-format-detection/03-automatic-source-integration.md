# DR8c — Automatic source resolution, overrides and aggregate budgets

> **Status: open.** Authority: automatic data-format detection §§2–3, 5.1, 5.3–5.4, 6.1, 8.3, 10 and
> 12.4–12.5. Requires DR8b. This is the runtime cutover session.

## Outcome

Make contextual format resolution the sole File-source path, activate per-file override precedence, capture one
concrete `ResolvedReadSpec` and provenance entry per part, enforce aggregate cold-resolution budgets, and switch the
File-source default to `Automatic` only after compatibility fixtures are green. Cursor execution remains unchanged.

## Preflight and current anchors

- `kzen-auto-jvm/.../objects/datasource/FileDataSource.kt` — current fixed format and ignored overrides;
- `kzen-auto-common/.../data/file/FileSelectionEntry.kt` and round-trip tests;
- `kzen-auto-jvm/.../objects/datasource/DataSourceActions.kt` and `DesignDataContext.kt`;
- `kzen-auto-jvm/.../data/ConfiguredDataOpener.kt`, schema cache and adoption identity;
- `kzen-auto-jvm/.../objects/job/worker/data/FileSourceWorker.kt`;
- `auto-jvm/datasource/data-source-jvm.yaml`, configured-format notation and migrated Job fixtures; and
- `FileDataSourceTest`, `DataSourceActionsTest`, Read worker migration/schema-mode tests.

## Resolution precedence

For each selected/scanned file, implement exactly this order:

1. a per-file concrete format override, if present;
2. otherwise a concrete source-level format, if selected;
3. otherwise source-level `Automatic` using any per-file encoding override; and
4. no other fallback outside the Automatic resolver.

Concrete choices bypass probing and remain strict. Clearing the per-file fields restores source policy. A stored
coordinate that cannot resolve is an actionable failure and remains visible to the client; it is never discarded.

## Implementation

1. Add the built-in `Automatic` configured format. Its contextual resolution delegates to
   `AutomaticFormatResolver`; it has no fixed execution spec, is catalog-visible, is excluded from candidates and
   declares no static shape.
2. Inject the DR8a format registry/resolution service into `FileDataSource`. Resolve each non-missing regular file
   after listing/fingerprinting and before constructing its `DataPart`. Delete the current “overrides unsupported”
   diagnostic and make `format`/`encoding` effective without changing `FileSelectionEntry` notation shape.
3. Build each `DataPart` only from the concrete result. Add the matching resolution detail to
   `DataResolveResult`; verify one-to-one identity by ref/role rather than parallel list position alone. Do not put
   provenance in part digest or ask `ConfiguredDataOpener` to understand Automatic.
4. Keep explicit selection order, missing-file policy and group extraction unchanged. Mixed formats produce honest
   per-part contracts and flow to the existing `superset`/`strict` reconciliation without coercion.
5. Add a source-resolution budget owner around cold detections: maximum four acquisitions in flight, 256 cold
   parts, 64 MiB decoded samples and 15 seconds wall time. Cache hits consume none of the cold-part/sample-byte
   allowance. Listing/fingerprinting and explicit concrete formats do not masquerade as cold probe work, while the
   overall resolution deadline still governs the source operation.
6. On aggregate exhaustion, cancel/close in-flight work and fail the whole resolution. The error states completed
   count and limit, and recommends narrowing the filter, choosing a concrete source-level format, or raising the
   policy. Return no partial manifest/manifest-derived shape. Never probe a subset and extrapolate a majority.
7. Preserve deterministic output order despite bounded parallel detection: directory scans remain path-sorted and
   explicit selections authored-order. Completion order cannot affect manifests, candidate ranking or details.
8. Confirm runtime authority: a fresh source resolution reuses cache only on the complete key; changed fingerprint
   redetects. Once a Worker captures the manifest, migration/resume retains its concrete parts and does not redetect
   mid-run. `ConfiguredDataOpener.open/inspectShape` stay byte-for-byte free of hint/probe logic.
9. Handle `staticShape`: a concrete source format may still expose its declared shape when no per-file override can
   contradict it; Automatic or heterogeneous per-file formats return no static shape and use bounded inspection.
   Do not advertise a source-wide schema derived from only one detected part.
10. Change `FileDataSourceConfig.format` in notation from Configured CSV to Automatic only after the preceding tests
    pass with existing implicit `.csv` fixtures. Update built-in examples whose semantics require an explicit
    concrete format; do not rewrite user files under `notation/main/`.

## Proof and exit

- Precedence tests cover per-file format+encoding, each independently, source-level concrete format, Automatic,
  clearing overrides, missing/unavailable coordinates and strict explicit failure.
- Ordinary implicit `.csv` sources still produce concrete CSV specs; regional `.csv`, generic/semantic text and
  mixed CSV/TSV/text sources produce correct per-part details.
- `superset` accepts a compatible mixed selection and `strict` rejects differing contracts through existing logic.
- Aggregate tests use delayed/counting fake providers to prove the four-acquisition ceiling, deterministic order,
  cache-hit exemption and each 256-part/64-MiB/15-second failure. Every failure returns no partial result and closes
  all owned handles.
- Fingerprint change redetects in a fresh run; unchanged warm resolution reads zero sample bytes; captured Worker
  migration retains the manifest.
- A contributed test-only candidate works through `FileDataSource` with no source-specific branch.
- Focused common/JVM source, opener, Read worker and migration tests pass, followed by the full `../kzen-auto` build.
- The committed default is Automatic and no production caller uses the deprecated fixed format method.

## Handoff to DR8d

Runtime source resolution and `DataSourceActions.resolve` now return authoritative per-part detail. DR8d may add a
single-file preview action but must delegate to this exact contextual path and cache.

