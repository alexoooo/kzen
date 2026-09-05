# HS24 — Live host objects and shared memory governance

> Status: not started. One implementation session. Prerequisites: HS23; HS06 sizing baseline and HS18 E9 complete.
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

Not executed.
