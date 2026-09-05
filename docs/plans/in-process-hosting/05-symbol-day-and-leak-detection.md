# HS05 — Off-heap SymbolDay and persistent analytical graph

> Status: not started. One implementation session. Prerequisites: HS04.
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

Not executed.
