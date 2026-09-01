# Configurable data reading — constituent implementation plan

> **Status: not started.** Design authority:
> [`docs/analysis/2026-08-29_data-reading.md`](../../analysis/2026-08-29_data-reading.md)
> as amended per [review 1](../../analysis/2026-08-29_data-reading_review-1.md)
> (which extends the data-source model, Job data sources, project data, and unified data model analyses). This
> README owns sequencing, tracking, and arc-wide as-built coordination; each numbered file owns exactly one
> implementation session and its detailed proof.

## Goal and lifecycle

Replace the hard-coded CSV/TSV read path with the layered, provider-neutral composition: source selection →
content capabilities → content coding → character decoding → configured record reader → typed
`DataCursor<DataValue>` + `DataContract`. Simple reads stay one selection (built-in configured instances),
intermediate reads are UI-authored notation (format + schema), and advanced reads are code-authored capabilities
(§1.1 of the analysis).

Session files persist as the execution record for this multi-session arc. When a session lands:

1. mark it complete in the tracker below and in `2026-07-25_master-plan.md`;
2. append the session's measured/as-built deviations to that session file;
3. update this README only for arc-wide sequencing or a cross-session contract change; and
4. archive this directory with the sprint record when the arc closes — do not delete it as a `next/` elaboration.

## Tracker

| ID | Session file | Outcome | Status |
|---|---|---|---|
| DR1 | `01-resolved-read-identity.md` | `ResolvedReadSpec`/`ReaderConfig` snapshot, reader capability runtime/registry, canonical `ExecutionValue` wire, fingerprint handshake, digests and cache/migration identity | ☐ |
| DR2 | `02-schema-capability-and-custom-discovery.md` | `RecordSchema` capability extraction and open-ended capability-based Custom prototype discovery | ☐ |
| DR3 | `03-sequential-content-stack.md` | Provider-neutral sequential content, gzip/identity coding, character decoding, lifetime/cancellation, minimal in-memory provider-bound proof | ☐ |
| DR4 | `04-configured-delimited-reader.md` | Configured delimited reader with typed emission; atomic CSV/TSV cutover (may split at the green parser/cutover boundary) | ☐ |
| DR5 | `05-fake-provider-proof.md` | Fake object-store provider runs the full reader/provider conformance suite; neutrality pinned | ☐ |
| DR6 | `06-job-ui-expression-cutover.md` | Full `DataContract` through Job validation, cards/connectors, expressions; schema-draft authoring — executed as three green sub-boundaries (server type flow / typed expressions incl. exact Decimal / UI) | ☐ |
| DR7 | `07-acceptance-and-performance-gate.md` | Fixture matrix incl. stale-fingerprint, syntax, budget and Decimal-precision cases; full sibling builds; opt-in 100k-row canary with split parsing/end-to-end baseline | ☐ |

## Authoritative execution order

1. **DR1 → DR3 → DR4** is the load-bearing spine; DR4 must not start before the identity model (DR1) and
   content stack (DR3) it composes are green.
2. **DR2 is independent of DR1/DR3** and may land anywhere before DR4 (DR4's configured format references
   `RecordSchema` and ships as a Custom-creatable prototype). DR2 touches `CustomConventions` — coordinate with
   the E4 (Custom power) master-ledger row if that lands first.
3. **DR5 and DR6 both require DR4** and are independent of each other; numbered order is the default.
4. **DR7 last** — it is the arc gate and the only session that may motivate optimization work.
5. This arc is deliberately **not DM12**: it is typed-flat over the existing `FlatFileRecord` backing, no
   structural tape. DM12/DM13 stay gated in the data-model arc.

Open implementation questions from analysis §13 are settled inside sessions: handle placement (common vs JVM)
and BOM option names in DR3; SPI module ownership in DR1 (the wire form itself is settled: canonical
`ExecutionValue`, FR16); v1 malformed-value policy surface in DR4; shared-versus-inline format UI ownership in
DR6; canary baseline and threshold in DR7.

## Cross-repository publication rule

Sessions confirm code ownership at their start (the affected surfaces live mostly in kzen-auto; any kzen-lib
change follows the composite rule). Every kzen-lib session ends with a full kzen-lib build and, when a later
kzen-auto session consumes the new surface, `publishToMavenLocal` for all subprojects. Each session ends with the
focused tests it names plus a full build of every sibling it modified. No session changes release-train versions.

Two known cross-repo consequences: DR1 names the module that owns the reader-capability SPI at session start —
if it lands in `kzen-auto-plugin` (where third-party readers compile against it), the
`:kzen-auto-plugin:publishToMavenLocal` rule applies to DR1 and every later session touching the SPI. The exact
Decimal path (FR19) is a named kzen-lib + kzen-auto change and triggers the full kzen-lib publish chain in
whichever session lands it (DR4 reader side, DR6 accessor/binding side).

## Arc-wide stop rules

- A session ends green; no half-cutover is handed to the next session.
- DR4's CSV/TSV replacement is atomic — there is no long-lived "legacy reader versus configured format" mode
  (analysis §3), and built-in configured instances must keep the one-selection immediate tier working (§1.1).
- No pooling, leases, or eager materialization before DR7's measurement (analysis §12).
- The external measurements file stays an opt-in canary; no production symbol, default, or fixture may reference
  it or its domain (analysis header note, §10.7).
- Every explicit rejection in analysis §12 is a review gate for every session.
