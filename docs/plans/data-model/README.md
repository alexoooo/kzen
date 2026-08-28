# Unified data model — constituent implementation plan

> **Status: ready for execution through DM7c; later gates are named below.** Design authority:
> [`docs/analysis/2026-08-27_data-model.md`](../../analysis/2026-08-27_data-model.md). Review record:
> [`review.md`](review.md). This README owns sequencing, tracking, and arc-wide as-built coordination; each numbered
> file owns exactly one implementation session and its detailed proof.

## Goal and lifecycle

Replace the parallel `Any?`, tuple, Job payload/flat, and carrier-shaped schema boundaries with the unified
`DataType` / `DataValue` / `DataBindings` model, proving the foundation on the current flat/native Job path before
cutting Script and Flow over.

Session files persist as the execution record for this standalone multi-session arc. When a session lands:

1. mark it complete in the tracker below and in `2026-07-25_master-plan.md`;
2. append the session's measured/as-built deviations to that session file;
3. update this README only for arc-wide sequencing or a cross-session contract change; and
4. archive this directory with the sprint record when the arc closes—do not delete it as a `next/` elaboration.

## Tracker

| ID | Session file | Outcome | Status |
|---|---|---|---|
| DM1 | `01-type-contract-and-algebra.md` | Common structural type and algebra | ☐ |
| DM2 | `02-jvm-native-types-and-resolution.md` | JVM type resolution and native identity | ☐ |
| DM3 | `03-shape-and-schema-cutover.md` | Observation envelope, typed schemas, explicit legacy cursor bridge | ☐ |
| DM4 | `04-values-snapshots-and-validation.md` | Value contract, literals, snapshots, validation | ☐ |
| DM5 | `05-adapters-and-three-backing-proof.md` | Adapter registry and literal/native/flat/row proof | ☐ |
| DM6 | `06-job-projection-and-exclusive-builders.md` | Column projection and exclusive builders | ☐ |
| DM7a | `07a-job-lane-contract-and-bridge.md` | Contract-backed static lanes and green static façade | ☐ |
| DM7b | `07b-job-value-producers-and-workers.md` | Runtime bridge, DataValue channels, sources, and column Workers | ☐ |
| DM7c | `07c-job-carrier-deletion-and-foundation-gate.md` | Remaining Workers, bridge deletion, foundation gate | ☐ |
| DM8 | `08-binding-inventory-and-binding-model.md` | Reconciled signatures and binding model | ☐ |
| DM9a | `09a-core-binding-engine-and-bridge.md` | Additive kzen-lib binding engine and tuple adapter | ☐ |
| DM9b | `09b-auto-binding-migration.md` | kzen-auto Logic/Job/data-source binding migration | ☐ |
| DM9c | `09c-tuple-deletion-and-downstream-proof.md` | Tuple API deletion and downstream rebuild | ☐ |
| DM10 | `10-script-generic-boundary-cutover.md` | Script recorded-result/handoff cutover | ☐ |
| DM11 | `11-flow-generic-boundary-cutover.md` | Flow port/message cutover and consolidated gate | ☐ |
| DM12 | `12-first-structured-reader.md` | First tape-backed structured reader | ◇ consumer-gated |
| DM13 | `13-first-durable-row-source.md` | First real durable row and constraint/lifetime verdict | ◇ design-gated |

## Authoritative execution order

The master ledger uses these IDs as stable row identifiers rather than renumbering its historical numeric rows.

1. **J5a first.** Capture the unmodified Job/Report throughput and allocation baseline before DM code changes shape
   or carrier behaviour.
2. **DM1 → DM7c without J4/J9/J5b/J6/J7 overlap.** DM7c must pass the foundation gate before wider cutover.
3. **DM8 → DM11.** DM9 is split at publication boundaries so every repository ends each session green; DM9a's
   standalone kzen-auto compile against the newly published kzen-lib artifact is the proof that its bridge is real.
4. **Revalidate and execute J5b against `DataValue`, then J4, then J9.** J5b's `JobMessage`/`FlatView` pooling and
   batch sketches are stale after DM7c; keep its IO/headless goals but rewrite its carrier assumptions first.
5. **J6 remains demand-driven after DM7c** and must implement fan-out through DM6/DM7c's explicit alias/copy rule.
6. **DM12 and DM13 are not pre-scheduled.** Their selected reader/provider gates determine when they enter the
   ledger's active sequence.

J7/J8 remain separate from the data-model design, but they follow the master ledger. J7's channel work must be
revalidated after DM7c; neither session is pulled into DM1–DM7c when it touches the same Job files.

## Cross-repository publication rule

Every kzen-lib session ends with a full kzen-lib build and, when a later kzen-auto session consumes the new surface,
`publishToMavenLocal`. Every cleanup publication is followed by standalone kzen-auto and kzen-project builds. No
session changes release-train versions.

## Arc-wide stop rules

- A session ends green at its named bridge; no half-cutover is handed to the next session.
- DM7c runs the performance gate while the compatibility façade still exists. It deletes the façade only after the
  gate passes, then reruns the full build and a confirmation benchmark. A failed gate therefore has a real green
  fallback rather than a reconstruction instruction.
- DM9c does not delete tuple APIs until DM9b proves every kzen-auto production caller migrated.
- Richer wire grammar, graph provenance/exposure, recursive named types, and public retention/leases remain outside
  this arc until their named consumer gate opens.
