# HS25 — Integrated acceptance, real-day pressure and documentation

> Status: complete 2026-09-05 (E2/E3 kept open on one named line; see Deferred). One implementation session; prerequisites HS24 and all prior sessions, met.
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

Executed 2026-09-05 as the closing session: separate acceptance groups, adversarial isolation, the real-day pressure
run through the governed host route, the leak detector exercised on purpose, the affected builds and canary, and
the documentation. Every group's evidence is named below; what could not be closed is named too.

**Acceptance groups (Work 1), kept apart.**
- *Standalone folder plugin* — `PluginDirectoryIT` (kzen-sample-plugin, HS22): the packaged jar set verified by
  the compatibility kit in its own JVM as a folder scope and again as plugin zero; the standalone kzen-project
  home running every template (HS22 as-built).
- *Host-object access* — `HostGovernedIT` (kzen-sample-embed-spring, HS24): the `@Service`-fed
  `HostSymbolDaySourceWorker` route over the live `SymbolDayLoader`, the host's `/host/trades` and `/host/book`
  over the same objects.
- *Two-workspace isolation* — `HostIsolationIT` (this session, 6 tests): see Work 2.
- *Three-path fixture equality* — the raw route (`ItchReader` expression), the store route (`SymbolDays`
  expression, `TradeVolumeRowsTest`) and the host route (`HostGovernedIT`, `GovernedServicesTest`) each equal the
  generator's per-symbol tally on the seeded fixture; the routes share no intermediate representation.

**Isolation, adversarially (Work 2).** `HostIsolationIT` on the packaged host with two workspaces: trading's boot
sweep and its runs leave a marker in risk's work root untouched and put no scratch there; a document written into
risk's notation appears in risk's `scan` only; a fifty-million-element run in trading is cancelled while risk runs
and finishes its own Job; trading is stopped *with that run active* — `Workspace 'trading' stopped; work root
released`, never `stays claimed` — while risk keeps serving and runs again afterwards; an aliased work root
(`<home>/trading/../trading/work`) fails the second workspace by name and rolls the first back; a second workspace
whose work root is a regular file fails *after* trading is fully up (`Workspace 'risk': cannot create`), trading is
rolled back with its root released, and the same home boots again with trading's notation intact. Duplicate root
and port failures are `HostPackagedIT` (HS23); the same failed construction inside one context is HS10's forked
test. HS10's open "run blocking in a callback while close()" item is closed by the stop-with-run-active case.

**P1-final on the real day (Work 3).** The same day as HS06 (Nasdaq TotalView-ITCH 5.0, 2019-12-30, 268 744 780
messages, 8 906 symbols; source and the 9.9 GiB derived store under `C:\Users\ostro\kzen-data\itch\`, outside git,
the store reused because its fingerprint was fresh), on the packaged Spring host (`-Xmx16g`, G1, JDK 25.0.4.1,
i7-13700H, 64 GiB) with a **4 GiB budget** shared by the host's reports and both workspaces:
- a governed host query `/host/book/QQQ?levels=2` materialized the largest symbol-day in **4.46 s**, weight
  **1 615 350 232 bytes** (1.50 GiB: 104 MiB native + the estimated graph), returned it (`outstandingItems` 0);
- the trading workspace's Job `HostSymbolDaySourceWorker → SymbolDayTradeVolumeWorker → CSV` materialized **all
  8 906 symbol-days** fresh, one at a time, and wrote 8 906 rows; wall time 13 m 55 s, of which about ten minutes
  were spent blocked behind a deliberate 3 GiB host hold (below) — the unblocked rate was ≈ 2 700 symbol-days in
  the first minute and the tail (the S–Z symbols, SPY among them) about a minute;
- **arena sharing:** with the Job running, a host report holding 3 GiB (`POST /kzen-host/budget/hold`) plus a
  governed `/host/book/SPY` query made both the Job's next large symbol-day and the query wait (`waiting` 2,
  `waits` 2, `currentBytes` = the hold, `currentNativeBytes` 0 — nothing allocated while waiting); releasing the
  hold let both proceed (peak **3 672 431 720 bytes** = the hold plus a 430 MiB day);
- at the end: `acquisitions` 8 909 = `releases` 8 909 (8 906 days + QQQ + SPY + the hold), `outstandingItems` 0,
  `currentNativeBytes` 0, `oversizedRejections` 0, **`leaks` 0**, no Cleaner fallback, no error in the log;
- ordinary shutdown (`POST /kzen-host/shutdown`) with the budget empty: Tomcat's graceful stop, then
  `Workspace 'trading' stopped; work root released`, `'risk'` likewise, every port free.
- **Whole-day host report vs the governed route:** the first comparison disagreed and found the defect below;
  the corrected numbers agree exactly.
Channel capacities / queued values / callbacks / retained leases: the Job ran with the Job's default channel
(capacity 0, batch 1 024) and one owned element in flight — the per-run ownership report (`$job-ownership`, HS18)
is the instrument; this run's `outstandingItems` never exceeded 1 beyond the host hold. The retained-lease
diagnostics for a stalled accumulator and the scalar-projection recovery are exercised at host level on the
synthetic day (Work 4), not repeated on the real day.

**A core defect the real day found — one named metric, two definitions.** `TradeVolumeFold` threw
`Match number 50460 occurs twice, at ordinal 5265120`: a real day reports one match number once per displayed order
it executed against — both sides resting — and, twelve times for AAPL alone, with a non-printable `C` on one side
and a printable `E` on the other, none of which the synthetic day ever did. The whole-day report then still
disagreed with the governed route on 797 of 7 744 symbols (7 034 157 vs 7 038 481 events; AAPL 67 677 vs 67 689):
the fold kept the first side's printable flag. The fold now keys a match by (symbol, number) — the same number on
another symbol is that symbol's trade — counts it once whichever side prints, and breaks it once;
`SymbolDayGraph.standingTradeEventsAndShares` counts a standing match number once as well (the day's numbers were
already per match there). `bothSidesOfOneMatchCountOnceAndBreakOnce` pins the cases (`TradeVolumeFoldTest`); a direct
probe over the store (`Probe.java`, temp) shows fold and graph agreeing on AAPL at 67 689 / 7 330 969 before the
whole-day rerun. Book, lifecycles and event lists are untouched (per order, both sides wanted). **Re-measured after the fix,
unblocked:** the governed Job materialized all 8 906 symbol-days in **243 s** (≈ 37 symbol-days/s over 268 M
messages of derived store), peak **1 631 055 168 bytes** (QQQ's day alone), `acquisitions` 8 906 = `releases`,
zero outstanding, zero leaks; the host's whole-day report took 363 s (a single sequential decode of the 3.5 GB
gzip through the fold, no budget); the two agree on **all 7 744 symbols with trades: 7 038 481 events,
971 016 019 shares** (QQQ 24 328 / 4 246 822, SPY 48 923 / 7 392 032, IWM 22 323 / 2 812 018, AAPL 67 689 /
7 330 969), and the 1 162 symbols without a print are absent from the report and zero rows in the route.

**Leak detector, deliberately (Work 4).** `LeakDiagnosticTest` (host): a symbol-day materialized under the budget
and abandoned without close is reported by the core's Cleaner once unreachable (`leaks` 1), and the fallback
returns its lease exactly once (`outstandingItems` back to 0, `releases` 1); a day closed normally is never
reported. Normal runs above reported zero. The Cleaner catches unreachable unclosed models only; a model kept
alive by a lease is E9's holder diagnostics' business, as documented.

**Controlled stall and recovery (Work 4).** `HostGovernedIT` gained a dedicated host on a budget of one and a half
symbol-days (the largest synthetic day's weight × 3 / 2): `HostSymbolDaySourceWorker → SortWorker (by symbol) →
PreviewWorker` retains the first owned day in the Sort, the source's second lease waits on the budget (`waiting` 1,
`outstandingItems` 1, `leaks` 0, run `Running`), and after ~2 s the run logs `Job … stalled: No progress while
owned natives are held — workers/Sort: 1` — the holder named, no failure; cancel returns the lease
(`acquisitions` = `releases`, `outstandingItems` 0). The same Sort over the scalar projection
(`SymbolDayTradeVolumeWorker` before it) completes on the same budget: every symbol's tally, rows sorted, natives
back to zero, no stall warning. **Two kzen-auto fixes this surfaced.** (1) `JobDeadlockMonitor` used to skip its
whole schedule while the run served an external duplex channel — the Preview — so the E9 stall warning went quiet
for exactly the interactive shape it was meant for; now only the failing verdict is suspended for a serving run
and the progress clock keeps ticking (`JobDeadlockMonitorTest`). (2) The scalar route stalled too: a
`JavaTransformWorker`'s non-scalar outputs inherit the element's owners (E9 item 3, conservative), so the
trade-volume rows carried each symbol-day's lease and the Sort retained the days through them — HS16's
"deliberately copied projections stay unowned" had no way to be declared from plain Java. `independentOutputs()`
is that declaration: the three sample row Workers override it, `SymbolDayOrdersWorker` (pass-through core
records) keeps the default; `OwnershipBoundaryTest` gained the copied-projection route on a one-permit arena
(`CopyingTransformWorker`, `owned-boundary-copied.yaml`) beside the retention stall it already had. A Formula
producing a record from an owned element still inherits — the generic-Worker analogue is a named follow-up.

**Builds and canary (Work 5).** Republish chain today in dependency order: kzen-lib `publishToMavenLocal`
(unchanged this session, up to date), kzen-auto `build` (10 m 29 s, green; HS22's count of 1 061 JVM tests stands
— the canary `--rerun` afterwards replaced the XML), `FormulaStepTest` canary 10 / 0, kzen-auto `publishToMavenLocal`,
kzen-project / kzen-launcher / kzen-shell `build` green; after the monitor fix, `:kzen-auto-jvm:build` +
`publishToMavenLocal` + `copyDependencies` again (11 m 16 s, 1 064 JVM tests); kzen-sample-plugin `mvn -o -B clean install`
(34 + 13 + 2) and kzen-sample-embed-spring `mvn -o -B verify` (17 ITs — HostPackagedIT 5, HostIsolationIT 6, HostGovernedIT 6 — and 10 unit tests, 1 m 09 s) on JDK 25.0.4.1. No release-train
version changed. The JS bundle was rebuilt by the kzen-auto `build` (no npm-only change).

**Documentation (Work 6).** Sample README (readers, Workers, templates, install, kit), Spring host README and
AGENTS (layout, lifecycle, proxy, work/data roots, budget, governed vs plain routes, the real-day measurement
commands), kzen-auto `docs/architecture.md` § 8 (Java plugin rules, detection, embedding), kzen-auto AGENTS gotchas,
kzen-auto AGENTS gotchas and the E9 note (the stall warning stays on for a serving run), the sample README's
*Real market data* section (source, terms, the three routes and who governs memory, the benchmark command),
umbrella AGENTS (the new sibling), HS10/HS12 closure notes. Download terms for the real day are in HS03/HS06.

**Deferred, named.** (1) E2's matrix keeps one unmet line — kzen-project's `SampleExtensionTest` extended with the
folder case — so **E2 and E3 stay unticked**; every other line has evidence in HS12/HS21/HS22/HS24 (the `@Service`
Worker is the host's Kotlin glue; plugin zero is the Spring host's Maven dependency). (2) A sealed interface's
records are opaque to E7's static walk (`OrderLifecycle.events[*]`), a kzen-lib follow-up. (2b) A `FormulaWorker`
record computed from an owned element inherits its owners with no copy declaration, so a Sort after such a
Formula retains natives; the Java hook above has no generic-Worker counterpart yet. (3) `ProviderDataSource`,
memory admission at the proxy, launcher embedding, plugin upload / JS and E4 stay outside this arc, as planned.
