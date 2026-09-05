# HS25 — Integrated acceptance, real-day pressure and documentation

> Status: not started. One implementation session. Prerequisites: HS24 and all prior session acceptance criteria.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis three outcomes (§1), gates (§9) and settled contracts; full E2/E3/E7/E8/E9 matrices.

## Outcome and anchors

Both samples, affected release-train builds/docs, isolated runtime homes and final P1 measurements.

## Work

1. Run separate acceptance groups: standalone folder plugin, host-object access, two-workspace isolation and three-path fixture equality. Do not collapse them into one successful end-to-end demo.
2. Exercise isolation adversarially: boot sweep/output cleanup, notation edits, cancellation, active-run shutdown, duplicate/aliased roots and failed construction. The other workspace's work/state must remain valid.
3. Repeat P1 on the chosen real day through the governed host route, sharing the arena budget with host reports and multiple contexts. Measure native allocation/release separately from heap persistent graphs/temporaries, recorded results and snapshots. Report channel capacities, queued values, callbacks and retained leases.
4. Verify leak detector diagnostics deliberately, but require zero fallback cleanup on normal runs. Check retained-lease diagnostics for a controlled accumulator stall and successful scalar-projection recovery. Do not present Cleaner as guaranteed detection for strongly reachable leaks.
5. Publish current-version artifacts in dependency order, run affected full builds and the FormulaStepTest canary, then build/run both Maven samples on JDK 25. Use the already validated packaging and force a frontend bundle rebuild if only npm inputs changed.
6. Update sample READMEs, affected AGENTS.md/architecture and hosting instructions: Java 25 runtime, context hosting lifecycle, work/data roots, plugin folders, plain-library versus governed routes, download terms and reproducible measurement commands. Leave deferred ProviderDataSource, admission, launcher embedding, plugin upload/JS and E4 outside this arc.

## Verification and exit criteria

Every gate has evidence or a named unresolved condition; P1-early and P1-final are distinguished. Exact fixture outputs agree; ordinary shutdown leaves zero native allocations/permits and no unexpected leak diagnostics. Full-day runs use durable external inputs, never committed feed files. If a measurement cannot run, keep this session open and record the concrete limitation rather than marking a partial acceptance complete.

## Handoff

Complete HS and covered E trackers only after their proofs pass. Preserve all session files as as-built records; summarize results, deviations and any independently deferred work here.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
