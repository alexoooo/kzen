# HS05 — Off-heap SymbolDay and persistent analytical graph

> Status: complete 2026-09-04 (as-built below). Prerequisites: HS04.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.2.1 (canonical memory/lifetime contract).

## Outcome and anchors

Sample core: SymbolDay (name may change), book/order model, MaterializationBudget and native ownership state.

## Work

1. Implement symbol message storage off-heap and heap persistent structures for book depth/history and order lifecycles. Use feed ordinal for ties; immutable historical state must not change through later mutable builders. Retain historical orders while keeping the active-reference index limited to active state.
2. Choose a Java-friendly persistent representation with measured rationale. Expose ordinary Java getters/records and collection views where practical; do not make kzen name a collection implementation.
3. Add MaterializationBudget.acquire(weight) and an unlimited default. Reserve predictable native bytes plus estimated heap/reconstruction peak before allocation. Materialization failure/interruption unwinds partial storage and the lease.
4. Use storage accessible and closeable across threads (shared JDK Arena is the initial candidate). SymbolDay and its child views follow §5.2.1; close drops graph roots and releases native storage before returning the permit. Preserve primary failure and report unsuccessful native release accurately.
5. Implement the requested leak detector using JDK Cleaner, per §5.2.1. Detached cleanup state must not retain SymbolDay, graph nodes or callbacks capturing either. Normal close suppresses leak reporting; abandoned cleanup reports identity/size and safely attempts the same release once. Use host-neutral diagnostics in the core.
6. Make symbolDays(budget) return a closeable stream owning its store and partition handles. Define repeated iteration/close behavior explicitly.

## Verification and exit criteria

Check exact book states and order lifecycles against hand-authored fixture expectations, including historical immutability. Test cross-thread read/close, borrowed child reachability, post-close native access, failed materialization, repeated close and native-before-permit ordering. Test explicit/abandoned cleanup and cleanup failures deterministically; isolate bounded GC reachability checks from ordinary tests. A retained leak remains detectable through open/close accounting, not Cleaner timing.

## Handoff

Record concrete model/storage/collection choices, lifecycle API and weight components. Core correctness and cleanup must be green before P1.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-04 in `kzen-sample-core` (still no kzen or Kotlin dependency): packages `tech.kzen.sample.itch.model`
(the persistent graph) and `tech.kzen.sample.itch.day` (lifetime, budget, accounting, leak detection).

**Storage and model.**
- Off-heap: `SymbolDay.materialize(store, locate[, budget, coefficients])` allocates a **shared JDK Arena**
  (`Arena.ofShared()`, so construction, Worker reads and teardown may run on different threads) holding two
  segments: the symbol's frames merged with locate 0 in feed order as `[ordinal][length][bytes]`, and an
  8-byte-per-message offset index. `message(i)` decodes on demand from the segment; nothing wire-level is
  retained on the heap. (The frames are re-encoded from the store cursor's records rather than copied raw; the
  round trip is golden-tested. HS06 measures the cost.)
- Heap graph, plain Java, no library: `PersistentSortedMap` is a **persistent AVL tree** with structural
  sharing (O(log n) new nodes per update; every historical version keeps its meaning — property-tested against
  `TreeMap` over 5 000 random updates with every intermediate version re-checked afterwards). `SymbolDayGraph`
  holds `bookHistory` (one immutable `BookSnapshot` per book-affecting message, bids best-first, asks best-first,
  first entry the empty pre-open book), `orders` (every `OrderLifecycle` in add order, final state; a `U`
  replace ends one lifecycle and starts the successor with `replacedFrom`), `trades` (`TradeEvent` with kinds
  `EXECUTED` / `NON_DISPLAYED` / `CROSS`, `printable` false for non-printable `C` and zero-share `Q`),
  `brokenMatches`, and `peakActiveOrders`. The active order-reference index exists only inside the fold and
  only for live orders; historical lifecycles are retained. `OrderLifecycle` is an immutable record whose event
  list is array-copied per event (events per order are few; the measured rationale is HS06's). Queries:
  `bookBefore(ordinal)` (binary search on the history), `standingTradeEventsAndShares()` (the same named metric
  as `TradeVolumeFold`). Ordinary getters/records and `List`/`Map.Entry` views throughout — nothing here names
  a collection implementation kzen would have to know.

**Lifetime (analysis §5.2.1).** `MaterializationBudget.acquire(weight)` is taken **before** any allocation;
`canEverAdmit` rejects an oversized day before waiting; interruption inside the load unwinds arena and lease;
any load failure closes the arena and the lease (suppressed exceptions attached) before propagating. `close()`:
CAS `OPEN→CLOSED`, drop the graph root, `arena.close()`, `NativeAccounting.closed`, mark the cleanup state,
return the permit, deregister the Cleaner action — native release strictly precedes the permit (asserted inside
the lease's own `close`). **A native release failure keeps the permit** (`CLOSE_FAILED`, retried on the next
close) so the budget never reports capacity that was not freed. Post-close `message`/`graph` are the named
failure `SymbolDay X is CLOSED`; a heap child obtained earlier (a `BookSnapshot`) stays readable. Repeated close is
a no-op. `MaterializationWeight` splits **exact native bytes** (frames + index, 4 KiB-aligned) from the
**estimated heap** (linear in `PartitionStats` family counts × `Coefficients.initial`, deliberately generous
placeholders HS06 replaces). `SymbolDays.of(store[, budget])` is a single-use closeable stream that materializes
one day per `next()` in lexical symbol order; iteration after close and a second `iterator()` fail by name; the
days handed out are the caller's to close.

**Leak detector.** `SymbolDayLeakDetector` registers a JDK `Cleaner` action per day with detached state (symbol,
byte count, arena, lease, optional provenance stack) — never the day or graph. Explicit close marks the state
and runs `clean()` so the action is a no-op; an abandoned day's action reports a `LeakDiagnostic` to
`System.Logger` and registered listeners, attempts `arena.close()` and `lease.close()` exactly once, and records
the outcome in `NativeAccounting` (`leaksDetected`, `leaksReclaimed`, `releaseFailures`). Retained-but-unclosed
days never reach the Cleaner; they show as `daysLive > 0` in `NativeAccounting`, the deterministic accounting.

**Verification (`mvn -B package`, JDK 25): 31 tests, 0 failures.** `SymbolDayTest` (deterministic): hand-authored
AAPL book states through add/partial fill/full fill/replace/partial cancel/delete (9 snapshots, exact levels,
`bookBefore` the first fill), lifecycles (FILLED with 2 executions, REPLACED → successor DELETED with
`replacedFrom`, event kinds in order, peak 2 live orders), MSFT attribution / non-printable / zero-share cross /
break, GOOG depth before a non-displayed trade; historical immutability and **store-route equality with the raw
fold's generator tally for every symbol of the seeded day**; cross-thread read then close from another thread,
post-close named failure, borrowed heap child; failed materialization (corrupted partition) returns the lease and
leaves `NativeAccounting` unchanged; oversized fails before `acquire`; native-before-permit ordering and
idempotent close; explicit close suppresses the cleanup report; abandoned cleanup driven deterministically
reports symbol/bytes and reclaims once; a throwing permit release is reported as `permitReleased=false` with the
failure attached; a one-permit semaphore budget blocks the second day until the first closes; single-use stream.
`SymbolDayReachabilityTest` (isolated, bounded): an unreachable unclosed day is reported and reclaimed by the
Cleaner within the GC loop (took one collection here). Files staged by explicit path.
