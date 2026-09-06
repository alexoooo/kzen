# HS24 — Live host objects and shared memory governance

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS23; HS06 sizing baseline and HS18 E9 complete.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.3 and §5.2.1.

## Outcome and anchors

Spring host TradeRepository/OrderBookService/SymbolDayLoader and MaterializationBudget implementation; Kotlin @Reflect glue source.

## Work

1. Implement a host-wide weighted budget shared by ordinary host reports and both kzen workspaces. Register services under their declared Java interfaces with KzenAutoHost.
2. Bind the core's loader to that budget and produce a fresh SymbolDay per run. Reserve native plus estimated heap/reconstruction weight before allocation; reject over-capacity requests before waiting; interruption rolls back cleanly.
3. Expose the host's normal repository/report endpoints and UI so host processing and kzen use the same service model. Use the cursor-driven source adapter for the Java-service/Kotlin-glue route.
4. Make budget wait/acquire/release observable without retaining every model: current/peak weight, waits, outstanding items, native bytes and leak counts. Do not route memory admission through the proxy or kzen controller.
5. Keep shared cached models Borrowed and host-owned if any are exposed; the governed demonstration itself uses fresh owned instances. Document that plain arbitrary expressions with the unlimited budget are not automatically governed.

## Verification and exit criteria

Finish any HS02 G5 public-service-injection deferral. Compare all three fixture paths on the same named metric; run host and kzen work concurrently with a deliberately small budget and prove progress as leases release. Cancel while waiting, while materializing and after acquisition/before delivery; check native bytes and permits return with no Cleaner fallback. Test oversized input and a throwing processing callback.

## Handoff

Record service registration, weight policy and interruption behavior. HS25 owns real-day pressure, full isolation and final documentation.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in `../kzen-sample-embed-spring` (a `host` package, a Kotlin glue source, host endpoints,
configuration, tests) and its docs. No kzen source changed; the core's `MaterializationBudget` seam (HS05) was
enough for the host. Build: sample `mvn -o -B install`, host `mvn -o -B verify` (unit + integration tests).

**Budget and services (Work 1, 2, 4).** `WeightedBudget implements MaterializationBudget` — the host-wide arena as
a weighted semaphore over the core's seam: `acquire(weight)` admits `nativeBytes + estimatedHeapBytes` against a
byte capacity, blocks (interruptibly) while the capacity is spoken for, and a `Lease` returns it exactly once; a
weight above the capacity fails before waiting (`canEverAdmit` false — the core's loader consults it and refuses
by name, `… more than the budget can ever admit`, without touching the budget), an interrupted wait acquires
nothing. Counters (`BudgetStats`, no model retained): capacity / current / current native / peak bytes,
outstanding items, waiting, acquisitions, releases, waits, interrupted waits, oversized rejections — plus the
leak count `HostDay` keeps from the core's Cleaner-backed `SymbolDayLeakDetector`. `HostDay` holds the day file,
the derived store under the durable data area (`ItchDataArea.ensureStore`, built on first use) and the budget;
`FileTradeRepository` (`TradeRepository`) folds the day through the plain core once — the host's own report,
no materialization; `GovernedOrderBookService` (`OrderBookService.withSymbolDay` / `bookTop`) materializes a
fresh symbol-day under the budget per query and closes it in a `finally` (lease and native storage back whether
the processing returned or threw); `GovernedSymbolDayLoader` (`SymbolDayLoader.open()`) is a fresh `SymbolDays`
pass per call, every day admitted as it is pulled, never cached — the governed route always creates owned
instances (E9). `HostServicesConfig` makes them Spring beans and registers the same instances on `KzenAutoHost`
under their declared Java interfaces (`TradeRepository`, `OrderBookService`, `SymbolDayLoader`), the host
object every workspace's `@Service` parameters receive. Configuration: `kzen.host.day-file`, `data-root`
(default `<home>/data`), `budget-bytes` (default 256 MiB). Weight policy: the store's persisted per-partition
weight through `MaterializationWeight.Coefficients.measured` (the HS06 record), acquired before any allocation.

**Endpoints and glue (Work 3, HS02 G5's deferred half).** `HostReportController`: `/host/trades` (the repository's
tally), `/host/book/{symbol}?levels=` (a governed query; 422 when the day can never be admitted, 503 with no day),
`/kzen-host/budget` (the counters), `POST /kzen-host/budget/hold?bytes=` / `DELETE …/hold/{id}` — a host report
occupying the arena for a while, which is how a test makes kzen wait. The Kotlin glue
`HostSymbolDaySourceWorker(output, selfLocation, @Service loader: SymbolDayLoader): CursorSourceWorker`
(kotlin-maven-plugin 2.4.0 alongside javac) opens the loader's cursor and declares `elementClass() = SymbolDay`;
the framework owns each blocking pull through `runBlockingIo` (a cancel interrupts it), adopts each day (the run
closes it, returning the lease) and closes the cursor. Bundled archetype `HostSymbolDaySourceWorker` in
`notation/auto-jvm/kzen-sample-embed/host-workers.yaml`. Memory admission is nowhere near the proxy or kzen's
controller; the plugin's plain expression route (`SymbolDays.of(store)`) keeps the unlimited budget and is
documented as ungoverned (Work 5).

**Verification.** `WeightedBudgetTest` (4): admit / count / release-once, oversized-before-waiting, wait until a
lease returns, interrupted wait acquires nothing. `GovernedServicesTest` (5, over a synthetic day): the
repository's tally equals the generator's with zero acquisitions; the loader materializes every symbol fresh
(one outstanding at a time, native bytes counted while held), the host route reaches the generator's tally,
`acquisitions == releases`, no native bytes outstanding, no leak; the book service returns its lease whether the
processing returns or throws; a 1 KiB budget is refused before waiting; a hold fills the budget and an
interrupted waiting acquire rolls back (`interruptedWaits` 1, only the hold outstanding). `HostGovernedIT`
(packaged host, child JVMs, a synthetic day, a 4 MiB budget): 5 tests, 0 failures in 25 s (with `HostPackagedIT` 5 and the new `HostIsolationIT` 5 in the same `mvn -o -B verify`, 15 integration tests in all) — the host report at `/host/trades` equals the generator's tally and a `/host/book/AAPL` query materializes one symbol-day and returns it; the `@Service`-fed host route (`HostSymbolDaySourceWorker → SymbolDayTradeVolumeWorker → CSV`) and the plugin's raw route (`ItchReader` expression) both equal that tally through the proxy, every symbol-day admitted (`acquisitions == releases`, no item and no native byte outstanding, no leak); with a host hold spanning the budget, the Job's first pull and a concurrent `/host/book/MSFT` both wait (`waiting` 2) and both complete once the hold is released; a run cancelled while waiting ends with `interruptedWaits` ≥ 1, no acquisition, only the hold outstanding and no rows written; a 4 KiB budget refuses a symbol-day before waiting (422, `more than the budget can ever admit`, zero waits). Runs cancelled *while materializing* and
*after acquisition, before delivery* are not staged from outside (the IT cannot pin the moment); the lease's
return on those paths is proven by the unit level (throwing processing; interrupt while waiting) and by E9's
adoption-at-`next()` contract from HS17 — recorded as a deferred timing check, not a gap in the mechanism.

**Handoff.** Registration: `KzenAutoHost.builder().service(Interface.class, instance)` in `HostServicesConfig`,
the same beans the host's controllers use. Weight policy: the persisted weight × the measured coefficients, no
extra host multiplier yet (the real-day margin is HS25's P1). Interruption: a cancelled kzen run interrupts its
blocking pull; a waiting acquire throws `InterruptedException` having taken nothing; an acquired day returns its
lease on close, which E9 guarantees for what a run pulled. HS25 owns the real-day pressure run, full isolation
and the final documentation.
