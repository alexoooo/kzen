# Automatic data-format detection — constituent implementation plan

> **Status: complete — DR8a–DR8f landed 2026-09-03.** Design authority:
> [`docs/analysis/2026-09-02_data-format-detection.md`](../../analysis/2026-09-02_data-format-detection.md),
> including its incorporated review amendments. The completed configurable-reading arc at
> [`docs/plans/data-read-config/README.md`](../data-read-config/README.md) is the implementation baseline.
> This README owns sequencing, tracking, and arc-wide coordination. Each numbered file owns exactly one
> implementation session and its proof.

## Goal and lifecycle

Make `Automatic` the File-source default without moving inference into cursor execution. Source resolution obtains
one bounded sample per cold part, chooses a concrete `ResolvedReadSpec` using contributed probes and hint metadata,
and records explainable per-part provenance. Explicit selections stay strict. Valid unrecognized text becomes a
stable one-field line stream, while malformed structured hints, binary input, ambiguous structured matches and
operational-limit failures remain actionable failures.

The arc also activates the existing per-file `format` and `encoding` coordinates, adds format-owned correction
controls, and separates **Make explicit** from **Lock columns**. All persistence is intentional notation authoring;
preview and runtime detection never edit documents.

When a session lands:

1. mark it complete in the tracker below and in `docs/plans/2026-07-25_master-plan.md`;
2. append measured results and deviations to that session file under an `As-built` heading;
3. update this README only for an arc-wide contract or sequencing change; and
4. keep every session file as the execution record. This directory is a constituent plan, not a disposable
   `docs/plans/next/` elaboration.

## Tracker

| ID | Session file | Outcome | Status |
|---|---|---|---|
| DR8a | [`01-resolution-contracts-and-probe-spi.md`](01-resolution-contracts-and-probe-spi.md) | Common resolution/provenance/policy models, contextual format resolution, optional probe and authoring SPIs, graph-backed format registry, cache identity | ☑ 2026-09-03 |
| DR8b | [`02-built-in-probes-and-text-reader.md`](02-built-in-probes-and-text-reader.md) | Shared bounded detector, CSV/TSV/semicolon/pipe probing, safe header inference, strict delimited cleanup controls, Plain-text reader | ☑ 2026-09-03 |
| DR8c | [`03-automatic-source-integration.md`](03-automatic-source-integration.md) | `Automatic`, per-file override precedence, concrete manifests, aggregate source budgets, File-source default cutover | ☑ 2026-09-03 |
| DR8d | [`04-selection-resolution-and-correction-ui.md`](04-selection-resolution-and-correction-ui.md) | Selection-time preview, stale-response protection, per-row provenance/errors, contributed correction editor and file-local authored formats | ☑ 2026-09-03 |
| DR8e | [`05-explicit-format-and-column-locking.md`](05-explicit-format-and-column-locking.md) | Make explicit, Lock columns, schema materialization and replacement/drift repeatability proof | ☑ 2026-09-03 |
| DR8f | [`06-acceptance-performance-and-downstream-gate.md`](06-acceptance-performance-and-downstream-gate.md) | Full acceptance matrix, resource/performance measurements, plugin extensibility proof, publication and downstream builds | ☑ 2026-09-03 |

## Authoritative execution order

1. **DR8a → DR8b → DR8c** is the runtime spine. Contracts and discovery land before built-in probes; the source
   cutover waits for the detector to be independently green.
2. **DR8d requires DR8c.** Preview must call the same authoritative resolution path that runtime uses.
3. **DR8e requires DR8d.** It extends the row host and materialization seam established by correction authoring.
4. **DR8f is last.** It is the only session allowed to widen verification to the complete matrix, external
   canary, publication, sample plugin and standalone downstream build.

Do not combine DR8a–DR8c into a partially green branch. In particular, do not change the File-source default to
`Automatic` until every existing implicit CSV fixture resolves through the new service and produces the expected
concrete CSV spec.

## Cross-repository and publication rule

Planned production changes are confined to `../kzen-auto`. At the start of every session, re-read its `AGENTS.md`
and refresh the named anchors because this plan describes a live sibling repository. No session changes the
coordinated release-train version.

`ReaderProbeCapability` and `FormatAuthoringCapability` extend `kzen-auto-plugin`, so DR8a and every later session
that changes those contracts must run the plugin tests. Publication and external-consumer rebuilds are consolidated
in DR8f: publish all kzen-auto modules to Maven Local, then build `../kzen-sample-plugin` and standalone
`../kzen-project`. If implementation discovers a necessary kzen-lib change, stop that session, read
`../kzen-lib/AGENTS.md`, record the reason in the session file, and apply the umbrella's kzen-lib publication order
before continuing.

## Arc-wide implementation rules

- The only execution input is the concrete `ResolvedReadSpec` captured in `DataPart`. `ConfiguredDataOpener` does
  not detect, inspect filenames, or reopen candidates.
- Explicit per-file and source-level concrete formats are strict. Detection cannot convert their failures into
  fallback or alternate candidates.
- `Automatic`, source code, and UI code do not compare concrete reader or format names. Installed metadata and
  optional capabilities drive discovery.
- One acquisition supplies all probes and allowed character views. Each candidate owns its logical-record parsing
  and the 100-record cap; the service never presents a physical-line count as record truth.
- Detection success is cacheable only under the complete fingerprint/hint/candidate/probe/policy key. Cancellation,
  timeout, acquisition, fingerprint and budget failures are never cached.
- Selection preview is transient. Only correction, Make explicit, and Lock columns issue notation commands.
- Authored overrides are source-local objects and never mutate shared configured formats. Clearing a row reference
  leaves the authored object intact.
- Skip-leading-lines and comment-prefix are explicit parser configuration. Width padding/truncation, footer removal
  and malformed-syntax recovery stay out of this arc.
- Aggregate exhaustion returns no partial manifest and never applies a sampled majority format to unprobed files.
- Review every code diff against `docs/CODING_STANDARDS.md`, especially CC-03/04/05: a new format must register at
  the same depth without adding a branch to the resolver, File source, or shared row UI.

## Arc-wide deferred scope

JSON/NDJSON, Parquet, JDBC/native rows, ZIP browsing, `.xlsx`/`.xls`/`.ods` workbook and sheet selection,
probabilistic charset detection, semantic type inference without an authored schema, whole-dataset prevalidation,
ragged-row repair, footer removal, syntax skipping and quarantine remain separate capabilities or designs.
