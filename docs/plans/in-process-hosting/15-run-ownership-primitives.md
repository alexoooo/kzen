# HS15 — E9 ownership ledger and native lifetime primitives

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS01; refresh current DataValue and JobControl APIs. Serialize with HS13/HS14 where files overlap.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E9 identity, owner sets, Borrowed and teardown contracts.

## Outcome and anchors

JobControl/JobRun, JobDataValues; kzen-lib native value access; kzen-auto-plugin Borrowed.

## Work

1. Add the per-run identity ledger with named leases and a process-wide weak identity registry for owned-by-run/closed states. Lift remains run-blind. One native can belong to only one run for its lifetime.
2. Implement owner-set propagation and Borrowed semantics, including a borrowed closeable child versus a newly owned derivative. Lease transfer cannot hit zero between holders; a child's cleanup needing its parent happens while that parent remains live.
3. Add retain/release and named use-after-close guards with thread-safe adoption/closure and idempotent cleanup claims. Strong references must leave closed ledger entries; weak registry bookkeeping must not pin the graph.
4. Implement best-effort close-all with processing failure primary and close failures suppressed, using the JobRun post-join teardown seam. Keep these primitives additive until transport and source boundaries are wired.
5. Create reusable close-counting/cross-run/throwing-close fixtures for later sessions. Do not claim route-wide E9 support from primitive unit tests.

## Verification and exit criteria

Test identity through multiple wrappers, competing-run adoption, closed tombstones, owner-set close ordering, Borrowed suppression, concurrent final releases and cleanup failure precedence. Check weak bookkeeping permits collection. Existing unowned-value behavior must remain intact.

## Handoff

HS16 integrates channels/Worker loops; HS17 integrates streams and acquisition. E9 is not complete or externally advertised until HS18.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-auto (`kzen-auto-plugin` SPI, `kzen-auto-common` control surface, `kzen-auto-jvm`
`server.exec.job.ownership` package plus the JobRun/EngineJobControl/WorkerLogic/JobDataValues seams) and
kzen-lib-common `jvmMain` (the liveness-guard hook). kzen-lib was published to mavenLocal before kzen-auto
was built; kzen-auto was then built, published, and kzen-project rebuilt from its own directory. No
release-train version changed. Everything here is **additive**: no ingress boundary adopts anything yet, so
existing unowned-value behaviour is untouched (the 1000+ existing kzen-auto tests still pass unchanged).

**Ledger and registry (Work 1).** `RunOwnershipLedger(runId)` is created once per run in `JobRun` and shared
by every Worker of the run through `WorkerLogic` → `EngineJobControl.ledger`. It keys adopted natives by
object identity (`IdentityHashMap`), so identity is the native object through every wrapper: two values lifted
from the same native, or a child navigated from either, resolve to the same `OwnedNative` entry.
`NativeIdentityRegistry.global` is the process-wide record of `Owned(runId)` / `Closed(runId)` per identity —
`adopt` by a second run fails naming the owner and the remedy (`Borrowed`), adoption after close is the named
use-after-close error, and its `guard` (a kzen-lib `NativeLivenessGuard`) is what makes a read through a closed
native fail by name. Entries hold the object through a `WeakReference` bucketed by identity hash and cleared
entries are dropped on the next touch of the bucket, so a closed tombstone never pins the resource or its
graph. `lift` stays run-blind: only adoption touches the registry.

**Owner sets, Borrowed, leases (Work 2–3).** `OwnerSet` is the immutable set of entries a value's lifetime
depends on (its own entry first, then whatever it inherited from its parent); `lease(holder)` is one hold per
member, taken atomically (a member already closed releases the holds taken so far and fails by name), and the
composite release runs in member order — so a held child keeps its parent open and closes before it.
`OwnedNative` counts holds by `LeaseHolder` name (`producer`, a channel, a Worker's notation location) and
closes exactly once on the last release; `forceClose` (teardown) drops every hold. Closing is an atomic claim,
so concurrent final releases and a teardown racing a release cannot call `close()` twice, and a `close()` that
throws still leaves the entry closed (re-adoption is refused, `close()` is not retried). Holding a channel
lease before the producer lease is released keeps the count off zero between holders. `Borrowed.of(x)`
(kzen-auto-plugin) is unwrapped by `adopt` and never adopted; a borrowed child of an owned parent keeps only
the inherited owners, so kzen never closes it. `ValueLease` (kzen-auto-common, `AutoCloseable`, idempotent) is
the SPI-visible hold; `JobControl.retain(value)` defaults to `ValueLease.none` and `EngineJobControl` answers
with a lease held by the Worker's location. `DefaultDataAdapterRegistry(livenessGuard)` in kzen-lib consults
the guard before reading a native's members, and `JobDataValues` wires the process registry's guard, so a
closed native reads as `invalidState` "closed by run <id>". Strong references leave with the close:
`RunOwnershipLedger.onClosed` removes the entry, and only the registry's weak tombstone remembers it.

**Teardown (Work 4).** `JobRun.run` now records the processing failure and, in the `finally` that runs only
after `coroutineScope` has joined every Worker, calls `ledger.closeAll(failure)`: every live entry is
force-closed (all attempted), close failures ride along as suppressed on a primary processing failure, and
with no primary the first close failure is thrown with the rest suppressed. A Worker parked in `runBlockingIo`
delays the join until its call returns (the engine interrupts the offloaded thread but `runInterruptible`
cannot resume before the block does), so no callback can be using an owned native when the closes run.

**Fixtures (Work 5).** `CloseCountingResource` (per-instance and global close counts, close order and thread,
optional throw-on-close) and `AdoptingSourceWorker` + `adopting-source-test.yaml` (a source that adopts through
the ledger directly, with latches to park inside the blocking offload) are shared by HS16–HS18.

**Verification.** `RunOwnershipLedgerTest` (6): identity through wrappers and the tombstone read/re-adopt
errors; linear ownership across runs with the `Borrowed` remedy; owner-set close ordering
(`[child, parent]`) and the borrowed-child suppression; 16-thread concurrent final releases close exactly once;
teardown precedence (processing failure primary with two close failures suppressed; without a primary the
first close failure is primary); closed tombstones do not pin the object (collected under `System.gc()`, tracked
count returns to 0). `RunOwnershipTeardownTest` (3, real `RunEngine` runs through `JobLogicCompiler`): a
completed run closes every adopted resource exactly once after the Workers joined; a cancelled run closes
nothing while the source is parked in a blocking call and everything once it returns; a failing source stays
the run's outcome with throwing closes attempted once. kzen-lib `NativeLivenessGuardTest` covers the hook.
Ran `:kzen-auto-plugin:publishToMavenLocal` and the ownership / `*JavaAdaptersTest` / `objects.job.*` slices
(222 green), then full `./gradlew build` + `publishToMavenLocal` of kzen-auto and `./gradlew build` of
kzen-project. New files staged by explicit path: `Borrowed.kt`, `ValueLease.kt`, the five `ownership` sources,
four test sources and the YAML fixture; in kzen-lib `NativeLivenessGuard.kt` and `NativeLivenessGuardTest.kt`.

**Not claimed.** Route-wide E9 (channels, Worker loops, streams, acquisition, result snapshots, diagnostics) is
HS16–HS18; `retain` is reachable but nothing owned flows to a Worker yet, and `holdsByHolder()` is not
published to the UI. E9 is not externally advertised until HS18.
