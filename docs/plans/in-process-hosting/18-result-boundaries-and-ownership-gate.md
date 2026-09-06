# HS18 — E9 result snapshots, diagnostics and acceptance

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS17; HS14 if recursive snapshot support changes the boundary implementation.
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

Executed 2026-09-05 in kzen-auto (`kzen-auto-common` SPI + conventions, `kzen-auto-jvm` control, result sink,
deadlock monitor, run, channel, ledger; docs). kzen-auto built (whole suite), published to mavenLocal, and
kzen-project rebuilt from its own directory. No release-train version changed. **E9 closes here.**

**Boundaries (Work 1–2).** `JobControl.snapshot(value)` is the SPI's boundary operation (default identity);
`EngineJobControl.snapshot` returns an unowned value as is and materializes an owned one through kzen-lib's
`DataSnapshot.capture` (bounded by `SnapshotPolicy`: depth, elements, text, bytes, duration) into a literal
`DataValue` — record → map, listing → list, scalars — never the native identity; a rejected snapshot (an
opaque owned native, a limit) is a named `DataAccessException` "cannot leave the run and cannot be
snapshotted". `ResultSinkWorker` keeps `control.snapshot(element)` inside `onElement` (first / last / all)
and `EngineJobControl.yieldResult` refuses a value the ledger owns, so no Result can hand out a native the
teardown will close. Inventory of the other `JobDataValues.boundary` callers: `RunWorker` /
`normalizeArguments` hand an element to a nested Logic *within* the callback (the child completes before the
callback returns, so the native is live throughout); `JavaTransformWorker` reads the native inside its
callback; Preview / Explore / the writers / Pivot / Summary render or copy scalars; Script, Flow and
LogicDataSource boundaries never see Job-owned values. The process-wide codec stays run-blind: snapshots are
ordinary literal values.

**Diagnostics (Work 3).** Aggregates only. A Worker's ordinary progress map carries `holds` (its live holds,
`JobConventions.progressHoldsKey`) when non-zero, rendered by the generic card's scalar status line.
`JobOwnershipReport` emits `$job-ownership` on the Job root — holds by holder name, queued elements per
channel (`JobChannel.queuedElements`), live and closed native counts, and a `stalled` flag — at the end of a
run and around a stall. `JobDeadlockMonitor` gained a lower, non-failing threshold on its own 50 ms clock:
`progressMark` (channel transfers + ledger adoptions/closes) unchanged for 40 polls (~2 s,
`stallIntervalMillis`) fires `onStall(true)` once; `JobRun` then, only if owned natives are held, logs a
warning naming the holders with a bounded sample (`RunOwnershipLedger.describeLive`, `ownershipDetailLimit`)
and emits the report; progress resuming emits a recovery. The failing deadlock threshold is untouched.
Bounded per-item detail is on demand (`describeLive`), never in a status publication.

**Teardown (Work 4).** Unchanged from HS15–17 and re-verified on every path here; no `Cleaner` exists.

**Two defects found by the acceptance matrix, fixed.** (1) A Worker that a migration's channel drain unparks
must re-park before producing more — the Sort's end-of-stream drain (many sends, no checkpoint) kept sending
into the old channel after the drain, so a live edit during its drain lost or duplicated elements
(pre-existing, made reachable by owned flush-on-send). `JobChannel.Producer` now reports a park
(`FrameworkChannelOutput.takeParked`) and `Emitter` checkpoints right after a flush that parked (drive loops
`attach` their control), restoring the engine's invariant for every framework loop; `SortWorker` claims each
element before sending it and captures only the unsent remainder mid-drain. (2) The per-send hold check taxed
ordinary scalars: `RunOwnershipLedger` skips the owner lookup while nothing was ever owned and decides
closeability once per native root class, so a scalar stream never reads its boxed natives.

**Verification (Work 5).** `OwnershipBoundaryTest` (6): a Result over owned scalar-only records is a map
that stays readable after the run closed them; keep=all snapshots every element; an opaque owned native at
a Result fails by name and still closes; a Borrowed child is never closed while its parent closes after the
consumer; a Sort's explicit leases survive a live edit of the sink (none closed at the cut, every element
delivered once, all closed once after the replacement completes); a two-permit arena source behind a Sort
gets no report before the interval and, after it, a `stalled` report naming the Sort with its two holds, the
run not failed, everything closed on cancel. `OwnershipOverheadTest`: best-of-5, 3 ms unbound vs 5 ms ledger-bound per 300,000 lifted scalars through a channel after the scalar fast path (it was 26 ms vs 35 ms before it, and 40 vs 64 before the class cache) (assertion guards a 2×
regression). The full E9 matrix as landed across HS15–HS18: `RunOwnershipLedgerTest` (6),
`RunOwnershipTeardownTest` (3), `OwnedRouteTest` (7), `OwnedSourceRouteTest` (9) — identity through wrappers,
competing-run adoption, closed tombstones and weak bookkeeping, owner-set close ordering, Borrowed
suppression, concurrent final releases, failure precedence, callback holds through channels and fan-out,
scalar projection avoiding retention, Sort retention, derived closeables, failing transforms, arena-backed
flush-on-send at capacities 0/1/4, source ingress on the Java cursor / expression / reader routes, `Stream`
and self-closing containers, lift failure, cancel under a permit wait and an active callback, migration of
closeable and re-evaluated streams. The whole `kzen-auto-jvm` suite: 1049 tests, 1 failure at HS18 time — the overhead guard under the whole suite's load (4 ms vs 21 ms), then hardened and re-run clean in HS19's full build: 1059 tests, 0 failures; full `./gradlew build` +
`publishToMavenLocal` of kzen-auto, then kzen-project `./gradlew build`. New files staged by explicit path:
`JobOwnershipReport`, `FrameworkChannelOutput`, the four test fixtures / suites and the six fixture documents.
`AGENTS.md` gotcha and `docs/architecture.md` § 1 Job updated; the E7 and E9 phase boxes in the
extensibility plan are ticked.

**Not done / caveats.** The stall warning is suppressed, like the deadlock verdict, while an external duplex
channel is open (the monitor does not start). Occupancy is reported, not enforced: "actual capacity-dependent
occupancy" is the `queued` map of the report (the stall test shows the source's channel at 0 with the Sort
holding two). The JS side renders `holds` through the generic status line only; the `$job-ownership` root
value has no dedicated display (HS25 may add one). Sample consumers (HS21–HS22) build against the published
artifacts.
