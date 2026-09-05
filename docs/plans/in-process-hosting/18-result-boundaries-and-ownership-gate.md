# HS18 — E9 result snapshots, diagnostics and acceptance

> Status: not started. One implementation session. Prerequisites: HS17; HS14 if recursive snapshot support changes the boundary implementation.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E9 boundary, failure and stall contracts.

## Outcome and anchors

JobControl.snapshot; every JobDataValues.boundary caller; ResultSinkWorker, retained traces/previews, JobDeadlockMonitor and progress payloads.

## Work

1. Inventory every result/trace/preview boundary, including retained diagnostic values. Owned natives are structurally snapshotted while leased or fail with a named boundary error; the process-wide codec stays run-blind.
2. Ensure snapshots are scalar/structural, bounded and independent after close. Do not recursively clone full native histories into a tiny preview. Keep existing identity-preserving paths only for unowned values.
3. Publish aggregated lease counts by holder; bounded item detail is on demand. Add a lower non-failing no-progress warning using the existing monitor's clock without changing its failing threshold.
4. Close outstanding leases only after Worker join; verify primary processing error and suppressed cleanup failures throughout. No successful run may need Cleaner fallback to complete its normal resource accounting.
5. Run the complete E9 verification matrix from its authoritative phase, including all earlier session tests. Measure ordinary unowned scalar throughput to detect avoidable lifecycle overhead.

## Verification and exit criteria

Require the E9 matrix to pass: result remains readable after native release, opaque owned result fails by name, borrowed parent/child and new derivative close correctly, migration retains explicit leases, blocked source plus Sort produces the delayed named warning, scalar projection avoids retention, cross-run reuse fails, and all failure paths close exactly once. Record actual capacity-dependent occupancy. No arbitrary GC timing in normal pass criteria.

## Handoff

E9 closes only here. Publish changed lib/SPI/auto artifacts before sample consumers. Document any measured unowned-path regression and fix it before handoff.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
