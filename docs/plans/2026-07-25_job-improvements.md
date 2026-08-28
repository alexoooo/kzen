# Job (concurrent dataflow Logic) improvements — remaining phases (J4–J9)

> **Status: planned; sequencing revised 2026-08-28 by the unified data-model arc.** Successor to
> `sprint-2/2026-07-16_job-improvements.md` (Sprint 1: J1; Sprint 2: J2 landed 2026-07-21). It also
> preserves `sprint-2/2026-07-21_job-element-model.md` as the pre-DM baseline in Appendix A. J5a measures that
> baseline before DM1; DM7c replaces `JobMessage` / `FlatView` / `WorkerLane`; J5b is then re-specified against
> `DataValue`, followed by J4 and J9. Carrier-specific prose below is historical wherever the section's execution
> note says to revalidate it; it is not permission to recreate the retired carrier.
> Executor: **Opus-class, one ledger row per session.** Each phase/session is self-contained: goal, design
> decisions (already made — do not re-litigate), concrete steps with file anchors, and
> verification. Phase IDs are stable across the sprint reorganization.
>
> Companion plans: `2026-07-25_core-and-verification.md` (C3 would make `JobChannelSynthesis`'s
> per-compile define cheap — measurement-gated), `2026-07-25_flow-improvements.md` (sibling
> flavour). This plan deliberately does **not** duplicate their items.
>
> **Progress tracker** (update as phases land):
> - [x] Phase 3 — Report subsumption A: **superseded and delivered by DS2/DS3/DS6 (2026-08-24)**
> - [ ] Phase 5a — pre-DM benchmark harness and untouched `JobMessage` / `FlatView` baseline
> - [ ] DM1–DM11 — tracked in `data-model/README.md`; DM7c retires the element carrier
> - [ ] Phase 5b — revalidate IO/performance work against `DataValue`, then add headless mode
> - [ ] Phase 4 — Report subsumption B: export parity, offline persistence, deprecation path, after J5b
> - [ ] Phase 6 — topology: fan-out + non-linear ergonomics — **demand-driven after DM7c**
> - [ ] Phase 7 — interactivity remainder: retain=false progress emits, deadlock precision,
>   channel occupancy; revalidate against the DM7c channel
> - [ ] Phase 8 — client sweep + hygiene; follow the master ledger and revalidate DM-changed editor seams
> - [ ] Phase 9 — live-edit carry-forward for file-backed workers (writer append, pivot/explore
>   resume), after J4

**The active spine is J5a → DM1–DM11 → J5b → J4 → J9.** J6 is demand-driven after DM7c; J7's
`JobChannel` work also waits for DM7c and is revalidated there. J8 follows the master ledger rather than being
pulled through a conflicting editor/model cutover. Exit for the arc: the composed A/B gate green (the same dataset through
Report and through Job — identical bytes), Report frozen, headless = "the same Job, minus
observability".

---

## Landed context — the pre-DM baseline

**J1 ✓ (Sprint 1)** — bounded progress-teaser wire contract; the Pivot teaser bug fixed.

**J2 ✓ 2026-07-21 — Job signature: parameters in, results out.** Composition centrepiece. As-built
worth carrying: markers landed in `common-job.yaml`, not `job-jvm.yaml`; **client step 4 was not
verify-only** — a Job callee fell into the Script branch and rendered zero rows, needing a new
`JobConventions.isJob` branch in `RunStepArgumentsEditor`; the Script round-trip fixture needed a
`ResultStep` (there is **no last-step fallback**).

**Element model phases 1–3 ✓ 2026-07-22 — the baseline J5a measures before DM1.** See Appendix A for
the full pre-DM contract. DM7c deletes it before J5b/J4/J6/J7/J8/J9 execute. In brief:
- `JobMessage(payload, flat: FlatView?)` **replaced `DataRecord`** as the only element crossing Job
  channels, and `Emitter` / `SourceWorker` / `TransformWorker` / `SinkWorker` **lost their generics
  entirely**.
- **Typed parameter declarations replaced `ParameterSourceWorker`** (retired); `FormulaSourceWorker`
  is now THE parameterized source. `ParameterBinding` moved to `…server.objects.logic`;
  `TypeMetadataDefiner` / `ParameterDefaultDefiner` to commonMain `…common.objects.document.logic`.
- **Typed results + typed flow**: a declared `results` signature map (shared with Script via
  `LogicConventions`), `JobSignatureCapability` derives outputs from it, `ResultSinkWorker` keeps a
  single element (`keep: first|last`, default `last`) in constant memory, and `TypeAssignability`
  probe-compiles declared-vs-inferred assignability.
- **The payload-type walk is a `WorkerBase` capability, not a switch**: `WorkerBase.payloadFlow(input:
  WorkerLane, context): WorkerLaneAttempt`, default identity. `WorkerLane = (payloadType,
  flatColumns)`, where null flatColumns means statically **unknown**.
- New `JobValidator` + `JobValidationCache` (mirroring `ScriptValidator`); `StepValidation` and the
  digest-key builder moved to the shared `…document/logic` home.
- **`FlatView` follow-up** collapsed the nullable header/flat pair into one type, at the cost of one
  extra 2-field allocation per flat-lane element — **explicitly deferred to phase 5's benchmark.**

**Landed 2026-07-22 → 07-24, outside any plan, but load-bearing for phases 3/7/8:**
- **`RestHandler.kt` (1303 lines) was DELETED** and split into `server/api/handler/`
  (`DetachedActionHandler`, `LogicHandler`, `NotationQueryHandler`, `TaskHandler`, `StorageHandler`,
  `FileListingHandler`, `ObjectStableHandler`, `RestParams`) and `server/api/handler/command/`
  (`NotationAttributeCommands`, `NotationObjectCommands`, `NotationRefactorCommands`,
  `NotationDocumentCommands`, `NotationResourceCommands`, `NotationCommandHandler`). **Every REST
  step below is anchored on the new services.**
- **Flavour-agnostic validation UI**: `LogicValidationGlobal` + `ValidationStatusDisplay` in the
  ribbon, with a Job publisher via `JobController` + `JobValidationStore`; `ValidationDigestEcho` +
  `ServerValidationFetch` fixed the stale-revision race; `StageErrorIndicator` + `StageObjectLocator`
  give go-to-error; `ExpressionValidationIndicator` and `KotlinSyntaxValidator` (syntax-only parse
  for lanes with statically unknown headers) cover the Formula surfaces. **Phase 7 and phase 8 must
  check what this already delivers before planning worker-status work.**
- `ResultWorkerDisplay` shows the kept result value on the Result card.

---

## Ground rules for every phase

- **The extension rule holds**: no general layer learns a worker type. The expression facility and
  `ensureFlat` are services any third-party worker can use.
- **One step = one batch, uniformly.** The step grain is the checkpoint cadence; `batchSize` is the
  user's granularity knob.
- **Migration is rebuild-the-whole-graph**, never in-place re-config; change detection is a
  value-equal `objectDefinitions` compare.
- **Capture-BEFORE-teardown is load-bearing** (`WorkerBase.captureMigrationState`), not stylistic.
- Run the fast gate often: `cd ../kzen-auto && ./gradlew :kzen-auto-js:compileKotlinJs` for client
  work, `:kzen-auto-jvm:test` for server work. **Never `./gradlew build` from the umbrella** — it
  abbreviation-matches `buildEnvironment` and exits 0 having compiled nothing.

---

## Phase 3 — Report subsumption A: pluggable input formats + design-time services

> ⚠️ **Superseded 2026-08-21 by the DS arc** (`docs/analysis/2026-08-20_data-source-model.md` +
> `docs/analysis/2026-08-20_job-data-source.md`;
> `docs/plans/next/DS0`–`DS8`, ledger rows 49–58). Steps 1+4 land as `FileDataSource.items` +
> `DataPart.encoding` (DS2/DS3), steps 2+3 as the source object's detached `schema` action + the
> `JobUpstreamSchema` provider list (DS6). Phase 4 re-bases on DS3/DS6/DS7 (not on this phase).

**Goal.** Close the input-side gaps: third-party format plugins, charset handling, and the
design-time actions Job editors need (file browse, column pre-scan) — without Report's document
class in the loop.

**Design decisions.**
- **Bridge the existing plugin SPI, don't invent a new one.** `ReportDefiner` / `DataFramer` /
  segment steps (kzen-auto-plugin) stay the format contract. New `PluginReaderWorker` (a
  `SourceWorker`): config = file path(s) + `PluginCoordinate` (+ optional charset); it drives the
  plugin's framer + segment steps **synchronously in a plain loop over reused event objects** — the
  step SPI (`ReportIntermediateStep.process(model, index)` / terminal step) is ring-agnostic, only
  the driver differs. No disruptor inside a Worker (a Worker is already its own concurrent unit;
  batching and backpressure come from the channel). Reuse `ReportUtils.encoding*` for charset
  resolution. Resolution via `ReportDefinitionRepository`, injected `@Service` (already in the graph
  environment via `KzenAutoContext`).
- **`PluginReaderWorker` emits flat-part `JobMessage`s, payload null** — mechanical under the
  element model; its A/B compares **flat parts**, not `DataRecord`s.
- **Extract design-time services out of `ReportDocument`.** `FileListingAction` and
  `ColumnListingAction` become flavour-neutral detached actions. **The route work is smaller than
  originally scoped**: the file-browse route already exists as `FileListingHandler`, and detached
  actions already route through `DetachedActionHandler`. What remains is making a **Job** document a
  legitimate caller and adding the column pre-scan route beside it.
- **Column pre-scan feeds `JobUpstreamSchema`.** `MultiFileInputEditor` (already reusing the browse)
  and the spec editors get columns from the pre-scan instead of requiring a live `SummaryWorker`
  upstream: `JobUpstreamSchema` falls back reader-config → pre-scanned header when no summary source
  exists. **This un-strands `SortSpecEditor` from free text.** ⚠️ **Re-derive this against
  `WorkerLane` / `WorkerBase.payloadFlow`, which did not exist when this was designed** — the walk
  now already carries `flatColumns` (null = statically unknown), so the fallback should extend that
  result rather than introduce a parallel schema path. `JobValidator`/`JobValidationCache` are the
  natural cache seam.
- **Charset on the native readers**: an optional `encoding` attribute on `CsvReaderWorker` /
  `MultiFileReaderWorker` (default UTF-8, blank = detect via `ReportUtils`), threaded to
  `Files.newBufferedReader`.
- **Migration state for `PluginReaderWorker`**: v1 = restart on edit (the safe `WorkerBase`
  default); positional resume for plugin formats is follow-up (framers are stateful — note it in the
  kdoc).

**Steps.** (1) `PluginReaderWorker` + archetype + tests over the built-in Csv/Tsv/Text definers (the
A/B: the same file through `CsvReaderWorker` and `PluginReaderWorker(csv)` yields identical message
streams). (2) Action extraction + the column pre-scan route + client wiring for browse/columns
against a Job document. (3) `JobUpstreamSchema` fallback (on top of `WorkerLane`) + `SortSpecEditor`
column dropdown. (4) `encoding` attribute.

**Split point:** steps 1+4 (reader + charset) ship independently of steps 2+3 (design-time
services). Sized L; note the split in the tracker if the session runs long.

**Verification.** New worker tests + an editor smoke pass; `kzen-sample-plugin`'s definer loads
through a Job (manual); Report's own paths untouched (its suites green).

---

## Phase 4 — Report subsumption B: export parity, offline persistence, deprecation path

> **Execution order:** after DM11 and the re-specified J5b. Re-check every Worker/value anchor against `DataValue`;
> this phase consumes the landed carrier and must not restore `JobMessage`/`FlatView` helpers.

**Goal.** Close the output-side gaps and write down the Report retirement sequence. Its older phase-3 dependency is
satisfied by DS2/DS3/DS6, and DS7 supplies the single-container writer-result contract.

**Design decisions.**
- **Grouped export, the Job way.** Report groups by filename regex (`GroupPattern`); a Job stream is
  already merged, so grouping by *column value* is strictly more general. Add optional
  `groupBy: <column>` to `ExportWriterWorker`: on group-value change (or per distinct value), resolve
  `${group}` in the path pattern and open the next container — reusing `ExportFormatter.onNewGroup` /
  `CompressedExportWriter.openNextGroup` semantics through the shared seam (`ExportWriterWorker`
  currently pins `DataLocationGroup.empty`). DS7 supplies the capability-driven `ResultYielder` and
  the finalized single-container `DataRef`; J4 extends that contract so a yielding grouped writer
  returns one ordered `DataUnit`, with group attributes on the unit and one `main` part per finalized
  container. For Report-style per-file grouping,
  `MultiFileReaderWorker` optionally stamps a group column from a capture pattern over the source
  filename — **composition instead of a baked-in pipeline mode.**
- **Summary persists like Explore.** `SummaryWorker` gains the persistent notation-keyed `outputDir`
  (`JobControl.outputDir`; `JobWorkPool.workerOutputDir`) and writes Report's exact summary CSV
  layout on close (`ReportSummary.save` format, reused); an offline read path (REST, same shape as
  the job-download endpoint, now on `LogicHandler`/`DetachedActionHandler`) serves the
  value-set/pivot editors when no run is live. **This is what makes a Job usable for *iterative*
  report building** — configure filters against the last run's distinct values without re-running.
- **Post-run and post-restart Explore.** (a) In-card **browse after the run settles**: the live-serve
  path dies at teardown, so paging the persisted result needs a detached slice read over the
  notation-keyed `IndexedCsvTable` (which already supports offline preview); the Explore card falls
  back live-serve → detached-offline. (b) **Cross-restart visibility**: the download/browse gate
  reads the row count from the per-session trace, so after a JVM restart the on-disk result survives
  but the affordances hide until re-run — probe the persisted table itself (row count from the offset
  index) instead of the trace.
- **The end-to-end A/B gate is the acceptance test**: the same dataset through Report and through the
  equivalent Job — export bytes identical, pivot/summary results equal. The per-worker A/Bs (phase
  3's reader, this phase's grouped export) are stepping stones; **the checklist closes on the
  composed gate.**
- **Deprecation sequence** (documented here + in `kzen-auto/docs/architecture.md`, executed over
  later sessions): (i) parity checklist — each Report capability row mapped to its Job equivalent;
  (ii) **freeze Report** (no new features); (iii) a "Job from this Report" migration affordance is
  *optional* — decide by usage; (iv) retire Report's run path only after the checklist closes; the
  plugin SPI survives via phase 3's bridge. `previewAll` (stubbed even in Report) is declared
  subsumed-by-composition: wire an Explore before the filter.

**Steps.** (1) `groupBy` on `ExportWriterWorker` + tests (byte-identical A/B vs Report grouped export
over the same pre-grouped data, plus the ordered yielded `DataUnit`). (2) Summary persistence + offline REST + editor fallback — order
after phase 3's schema fallback, since summary-offline beats pre-scan when present. (3) Explore
offline slice REST + card fallback + persisted-count gate; extend `ExploreWorkerTest` (post-settle
slice equals a direct offline preview; gate visible with no trace). (4) Write the parity checklist
into `docs/architecture.md` § Job, run the composed A/B gate, and mark Report frozen there.

**Verification.** A/B export bytes equal (composed gate); restart the JVM, open the Job — the
value-set editor still offers the last run's distinct values **and** the Explore card still browses +
downloads; Report suites still green (**frozen ≠ broken**).

---

## Phase 5 — performance + headless readiness (benchmark-first)

**Goal.** Know the Job-vs-Report throughput gap; fix the cheap hot-path losses; make every
interactive-only cost gateable so a headless run is "the same Job, minus observability" — without
designing multi-process execution yet. This is two sessions separated by the DM arc: J5a records the untouched
carrier baseline; J5b starts only after DM11 and rewrites every optimization against the landed `DataValue` path.

**Design decisions.**
- **Benchmark before optimizing.** A JMH-free harness (plain `main` + wall clock over fixtures, in
  `kzen-auto-jvm/src/test`): (a) a 1BRC-style aggregate (headerless CSV → summary/pivot), (b) filter
  + formula + export over a wide CSV. The same files through the Report pipeline and the Job graph.
  Record rows/s + allocation (via `-XX:+UseEpsilonGC` on a bounded slice, or `GarbageCollectorMXBean`
  deltas). Commit the harness + a results table as the as-built; re-run per subsequent change. The
  pre-engine-rewrite harness measured the batched-channel Job **within ~2.5 % of a single-thread
  inline baseline at 4M rows** — that harness was lost in the rewrite; **rebuild the equivalent and
  re-establish the datum on the current engine.**
- **`FlatView` is a named J5a baseline row.** The element model's follow-up added one extra 2-field
  allocation per flat-lane element and explicitly deferred the judgement here. **Acquit or convict it
  by measurement, but do not optimize or pool the pre-DM carrier** — DM7c removes it and records the replacement's
  own foundation benchmark.
- **Known cheap wins, revalidate in J5b after DM11**: hoist per-record `runBlockingIo` to per-batch (read up
  to `output.batchSize()` records inside one block, in `CsvReaderWorker` / `MultiFileReaderWorker`;
  write a whole received batch per block in `ExportWriterWorker`); presize `Producer.pending` / batch
  copies in `JobChannel`. Names and batching seams are hypotheses until the post-DM revalidation.
- **The reuse ceiling is re-decided over `DataValue`, not inherited from the element model.** Apply an optimization
  only where J5a plus DM7c's confirmation benchmark convicts the landed path. DM6/DM7c's exclusive-transfer and
  alias/copy rules are authoritative. Migration carryover (`JobChannel.drainBuffered`) transfers ownership of live
  values and never licenses recycling an aliased or retained backing. The old message-arena/`FlatView` sketch is
  explicitly non-executable after DM7c.
- **Self-managed workers stay a live future direction, gated on benchmark evidence.** The raw
  `Worker` SPI deliberately keeps `suspend` out of the worker-*logic* contract, and `WorkerBase`'s
  hooks mirror an AsyncWorker lifecycle precisely so a hot stage could later be hosted by a
  self-managed executor. The open problem: worker-owned threads are not on the engine's
  `CountingDispatcher`, so quiescence would have to read worker lifecycle state, not just `inFlight`.
  **Do not build in this phase** — record the constraint, and only design it if the benchmark shows a
  stage the coroutine model cannot feed.
- **Headless = a run mode, not a fork.** A `mode` on the run start (default interactive); headless
  gates (a) `EngineJobControl.publishProgress` (no-ops except the final forced push), (b) the
  external duplex bridge + serve-channel synthesis, (c) any step-wavefront affordances (nothing to
  do — checkpoint is already a fast volatile path when running). The flag rides
  `LogicCompilerServices` so flavours read it uniformly; Script/Flow ignore it for now.
  ⚠️ **Pre-recorded rescope (finding F5): the serve-gate as literally specified is unsatisfiable** —
  skipping `JobChannelSynthesis.wireServe` outright breaks derivation. **Headless instead stamps the
  synthesized duplex channels non-external**, which achieves the same observability gating.
  **Explicitly protect**: `JobControl` keeps zero JVM/process-coupled types so an out-of-process
  runner can implement it later. (E6 multi-run is deferred — a headless run occupies the JVM's single
  active-run slot for now.)
- Deadlock-monitor cost is fine (50 ms daemon poll of atomics); leave it.

**Steps.** **J5a, before DM1** — harness + baseline table, including the `FlatView` row; no carrier optimization.
**J5b, after DM11** — first rewrite this section's concrete anchors against `DataValue`; then apply IO batching and
presizing, re-measure, add only benchmark-convicted reuse consistent with DM6/DM7c, add `mode` plumbing/headless
gates and a headless run test, and record the measured gap plus data-driven follow-ups.

**Verification.** Benchmark table in the as-built; headless test green; interactive Sample Job
behaviour unchanged.

---

## Phase 6 — topology: fan-out + non-linear ergonomics

> ⚠️ **PRIORITY — DEMAND-DRIVEN AFTER DM7c.** Nothing in the active spine depends on it. Re-elaborate its carrier
> mechanics against `DataValue` and DM6/DM7c's alias/copy rule when a real flow needs fan-out.

**Goal.** Make branching dataflows expressible without weakening the single-reader guarantee, and
legible in the ordered-card UI.

**Design decisions.**
- **Fan-out via a `TeeWorker`, not multi-reader channels.** Single-reader is what makes typing,
  carryover and close semantics tractable — keep it. `TeeWorker`: one input, `outputs: List<ChannelOutput>`
  (metadata `is: List, of: ChannelOutput`); forwards each element to every output.
  Under `DataValue`, the tee follows the landed rule: transfer at most one exclusive value and alias/copy every
  additional branch as required by backing lifetime. It does not recreate payload/flat-specific copying.
- `JobChannelCreator` learns list-typed channel attributes: a `ListAttributeDefinition` of references
  → one `newProducer()` per referenced channel; `ChannelTypeDefiner` treats each list element as a
  producer port. ⚠️ **Re-read `ChannelTypeDefiner` first** — the typed-flow work (`TypeAssignability`,
  `WorkerLane`) reshaped its neighbourhood after this was designed.
- **Branch legibility without a canvas**: (a) `SelectChannelEditor` shown for list ports (add/remove),
  (b) each *manual* connection rendered as a labelled chip on both endpoint cards (derived from the
  same notation the derivation reads — no new wire format), (c) auto-wire behaviour unchanged.
  `SelectChannelEditor` now sits on `SelectReferenceEditorBase` (AE5) — **extend it, don't fork it.**
- Fan-in needs nothing (multi-producer already works); worker-to-worker duplex stays manual and
  documented.

**Steps.** (1) Creator + definer list support + tests (a type mismatch in one list element fails
definition; close-on-last-producer counts each endpoint). (2) `TeeWorker` + archetype + tests (reader
→ tee → {explore, export}; migration carryover across both branches). (3) Client chips + list-port
editor. (4) Deadlock-monitor sanity: tee topologies with a stalled branch produce a correct verdict
(backpressure through the tee blocks the input side — assert the monitor fires).

**Verification.** New tests green; the Sample Job extended with a tee branch renders sensibly.

---

## Phase 7 — interactivity remainder: transient progress emits, deadlock precision, channel occupancy

**Goal.** Close the observability gaps remaining after E7 delivered per-worker outcome chips: stop
progress emits growing history, make deadlock detection real for serving Jobs, and show what is
flowing.

⚠️ **Check the 2026-07-22→24 validation arc first.** `LogicValidationGlobal`, `ValidationStatusDisplay`,
`StageErrorIndicator` and `JobValidationStore` landed after this phase was written and may already
cover part of items (b) and (d)'s client half. Survey before building.

**Design decisions.**
- **(a) Adopt `retain=false` for progress emits** — first item, mechanical, **extractable as a
  micro-session.** `EngineJobControl.publishProgress` marks the progress-marker emit non-retained per
  its in-code coordination note (the flag shipped with E4; S7 is the Script precedent — note S7 went
  further and made *all* Script emits transient because nothing read the retained ones). Check the
  same question for Job's forced-final push, which the post-run card **does** read from the live map:
  the live map survives `retain=false` and only history is skipped, so full adoption is expected safe
  — verify against `RunEngineLogicTrace` semantics. Flow's tracing emits are out of scope (the Flow
  plan owns them; `FlowNotationTest.tracedMessages` reads retained emits).
- **(b) Outcome-chip remainder**: verify `WorkerLogic.recoverable`'s failure path routes a useful
  message into the E7 outcome surface (red chip + message on the card) for a worker that throws
  mid-run with pause-on-error off; add only what is missing (e.g. an `execution.log` of the failure
  for history/attribution if E7's outcome carries only the terminal state).
- **(c) Deadlock precision instead of blanket suppression.** The verdict already counts only
  stream-channel blocks (`JobChannel.tracked`); serve-loop coroutines park on the duplex channel,
  which is **not** counted — so `blocked == active` is a true verdict even for a serving Job. Remove
  `JobDeadlockMonitor`'s `externallyServing` early-return **after** adding the missing scenarios:
  serving Job idle at end-of-stream (must not fire), serving Job with an orphan channel (must fire),
  UI slice query mid-verdict-window (must not fire — grace absorbs). If a legitimate suppression case
  emerges from the tests, narrow to that case and document it; **do not restore the blanket.**
- **(d) Channel occupancy in the pipes.** `JobChannel` gains a cheap `bufferedBatches()` estimate
  (producer-side counter incremented on send success, decremented on receive — atomics, no new
  hot-path locking). `JobRun` (root node) publishes a throttled (1/s) `$job-channels` emit —
  `{channelLeafName: {buffered, blocked}}` — routed via a new address routing in
  `RunEngineLogicTrace` (the E4 projection owns per-flavour address→wire routings; follow the
  `$job-progress` precedent) to a fixed channels path; `JobChannelDisplay` renders fullness (a thin
  fill bar) + blocked endpoints. Bounded payload (numbers only); **emit non-retained from day one.**
  ⚠️ DM7b reshapes `JobChannel` around `DataValue` — re-verify `bufferedBatches()` against the landed
  `drainBuffered`. The client half is the deferrable tail if the session runs long.
- **(e) Monitor-held bridge round-trip**: E5 landed as status push, so first *verify* whether an
  async external-request path materialized; if the 1 s worst-case `runBlocking` under the controller
  monitor still stands, reduce exposure by dispatching `route` off the controller monitor — check
  feasibility; if the controller contract makes that unsafe, leave it and record the dependency as a
  future engine item.
- **Also routed here from J2's as-built**: the `retainTrace` and `callerStableId` findings.
- Per-worker breakpoints/run-to: engine-supported since E3 but **Script-only UI** — do not build a
  Job affordance here; demand-driven follow-up.

**Steps + verification.** As per the decisions; **the deadlock tests are the heart** (extend
`JobDeadlockTest` with the three serve scenarios). Manual: kill a worker mid-run with pause-on-error
off → red chip with message; pipes show fill under backpressure; history size stable across a
long-running Sample Job (the `retain=false` proof).

---

## Phase 8 — client sweep + hygiene

**Goal.** Apply the render-scoping discipline to `JobController`, kill duplicated client
boilerplate, and clear the documentation debt. The old phase-3 dependency is satisfied; execute in master-ledger
order and re-check DM3/DM7a changes to upstream schema, lane summaries, and editor vocabulary first.

**Design decisions & steps.**
1. **Consumed-subset in `JobController`**: stop storing whole `ClientState`; keep the fields render
   reads (graphNotation identity for derivation, logicStatus bits, imperativeModel presence) with
   equality guards, mirroring `ScriptController`. Memoize `JobChannelDerivation.derive` keyed on
   `graphNotation === last` (one helper object used by the controller, `JobUpstreamSchema` and
   `JobServeChannelResolver` alike).
2. **`JobServeChannelResolver` de-hardcode**: resolve the serve *port* by type via the shared
   derivation result (it already computes `serves`); drop `AttributeName("serve")` and the
   `substringAfterLast("/")` string surgery.
3. **Channel defaults from notation**: replace the six `"1024"`/`"0"` literals in
   `JobChannelDefaults` / `JobController` with values resolved from the `Channel` archetype's notation
   (`firstAttribute` on the archetype), so `job-jvm.yaml` stays the single source.
4. **Dedupe editor boilerplate**: shared `formatCount`/`abbreviate` utils; one add-column form widget
   (`FormulaMapAdd` generalized) consumed by the Sort/ValueSetFilter/Pivot editors; one
   `LocalGraphStore.Observer` guard base for the seven editors. **AE3–AE6 all landed**, so build on
   `DebouncedSubmitter` / `AttributeCommitter` / `SelectReferenceEditorBase` /
   `AttributeWrapperLookup` — the guard base here covers only the spec editors those don't, and must
   **extend rather than parallel** them. Note the commit path now also reports through
   `DocumentEditActivity`; keep that wiring intact.
5. **`WorkerDisplayManager` degrades instead of throwing** on an unknown `display:` name: warn + fall
   back to `WorkerDisplayDefault` (a typo'd third-party marker shouldn't kill the document view).
6. **Hygiene.** ⚠️ **The `TransformWorker` / `SinkWorker` / `ChannelTypeDefiner` cast-safety kdoc
   rewrites already landed with element-model phase 1 — skip them.** ⚠️ **The
   `2026-06-23_job-paradigm.md` comment repointing already happened during the Sprint-3 consolidation
   — skip it too.** What remains: fix stale `JobExecution` references (`DuplexJobChannel`,
   `JobConventions`, `WorkerBase`, `CsvReaderWorker`, `MultiFileReaderWorker` kdoc, `job-jvm.yaml`);
   fix the `ExploreWorker` YAML comment contradicting the persistent output dir (`job-worker.yaml` vs
   `ExploreWorker.kt`); repoint the remaining P4*/M* mentions in `job-worker.yaml` to this plan; scope
   `ChannelTypeDefiner`'s port scan to the channel's own document instead of the whole graph (channels
   are document-local by construction); note duplex channels as deliberately un-type-checked or add
   the check if cheap; delete `JobConventions.requestParameter` if grep confirms it dead; decide
   `SortSpecEditor` summary wiring (subsumed by phase 3's schema fallback — verify, then remove its
   free-text apology); **evaluate folding `JobChildLogicHost`'s compile cache + scratch-dir
   registration onto the engine-carried resource values S2 landed** (do it if cheap, else record the
   decision).
7. **Pin grandchild nesting with a regression fixture.** The old `NestedLogicUnsupported` restriction
   (a hosted child could not itself host) was lifted structurally by the engine rewrite —
   `Execution.host` is uniformly recursive — but no fixture appears to exercise it. Add one: Job →
   `RunWorker` → Script whose `RunStep` hosts a further Logic; assert results, stepping descent and
   cancellation propagate through both levels.

**Verification.** JS build + a manual pass over the Sample Job (drag, insert, expand pipes, edit
specs); react-scan shows no whole-document re-render on status ticks.

---

## Phase 9 — live-edit carry-forward for file-backed workers

**Goal.** Close the remaining live-edit gaps: today a pause → edit → resume is exact through readers,
channels and in-memory accumulators, but every *file-backed* worker restarts — a truncating writer
silently **drops all rows written before the cut** (the reader resumes from position and never
re-emits them), and Pivot/Explore re-index from scratch. **Sequence after J4** (it touches the same
Explore/Export code) and consume the landed `DataValue` carrier.

**Design decisions.**
- **The capture-before-teardown seam already exists and is the right one** —
  `WorkerBase.captureMigrationState` runs while the worker is parked, BEFORE teardown, so a live
  handle can be detached exactly as the readers do. No framework change; this phase is per-worker
  opt-ins.
- **Writers carry an append cursor.** `CsvWriterWorker` and (uncompressed) `ExportWriterWorker`:
  capture detaches the open stream + position; the config-changed guard closes and restarts (the
  readers' exact pattern). A **compressed** export cannot be appended mid-container — keep the restart
  default there, but make it *correct* instead of silent: a compressed export whose config is
  unchanged captures nothing and instead marks itself `restartRequired`, surfacing on the progress
  trace so the user knows the export file is partial and can re-run. (A spill-and-recompress carry is
  not worth the complexity.)
- **`PivotWorker` carries its store.** The H2-backed `PivotBuilder` lives at a deterministic
  `(runId, workerStableId)` scratch path that is migrate-stable (`JobWorkPool`) — capture closes the
  builder (releasing the Windows file lock) *without deleting*, marks detached so `onClose` skips the
  delete, and the rebuilt instance reopens the same stores. Config-changed (pivot spec edited) →
  close-and-delete, restart (the accumulated pivot is spec-shaped).
- **`ExploreWorker` appends instead of clearing** on a migrate resume: capture flushes-and-detaches
  the `IndexedCsvTable`; the rebuilt instance re-adopts it and keeps appending (`onStart`'s clear-dir
  stays for genuinely fresh runs — gate on restored state being present).
- **Surface resumed-vs-restarted on the progress trace** for *all* carrying workers: a `resumed` key
  in the first progress publish after a migrate (`"position"` / `"restarted"` / `"restartRequired"`),
  rendered by the default card — a generic key, no per-type client code.
- `SortWorker`, `SummaryWorker`, `PreviewWorker` already carry (pure in-memory); readers already
  carry; `FormulaSourceWorker` / `RunWorker` correctly restart. **This phase touches only the four
  file-backed workers.**
- Aligns with the standing **best-effort carry-over-reset principle** (live-edit migrates state as-is;
  a stale continuation beats re-run side effects) — no validity gates beyond the config-changed guard.

**Steps.** (1) Writer cursor carry + tests (mid-stream migrate → the output file contains every row
exactly once). (2) Pivot store carry + test (migrate mid-accumulation → the final pivot equals the
un-edited run's). (3) Explore append carry + test (migrate → no duplicate or missing rows in the
persisted table). (4) `resumed` progress key + card rendering. Extend `JobMigrationTest` with one
end-to-end reader → pivot → explore → export migrate scenario.

**Verification.** New migration tests green; existing migration suites unchanged; manual: pause a
Sample Job mid-run, tweak a filter, resume — the export file is complete, the Explore table has no
gap, cards show "resumed".

---

## Sizing

| Phase | Size | Risk | Depends on |
|---|---|---|---|
| 3 — input formats + services | L (splits 1+4 / 2+3) | Medium | — |
| 4 — export parity + deprecation | M | Low | DM11, J5b |
| 5a — baseline harness | M | Low (measurement only) | before DM1 |
| 5b — perf + headless | S after re-elaboration | Low (measure-first) | DM11 |
| 6 — fan-out topology | M after re-elaboration | Medium (creator/definer) | DM7c (**demand-driven**) |
| 7 — interactivity remainder | M after anchor revalidation | Medium (deadlock change) | DM7c |
| 8 — client sweep + hygiene | M after anchor revalidation | Low | active spine / DM editor seams |
| 9 — file-backed carry-forward | M | Medium (migration semantics) | J4 (same files) |

---

## Appendix A — the pre-DM `JobMessage` baseline contract

Carried from `sprint-2/2026-07-21_job-element-model.md`, whose phases 1–3 landed 2026-07-22. This is the behaviour
J5a measures and remains current only until DM7c deletes it. Later J phases must not treat this appendix as their
execution contract; it stays here as the before-state needed to interpret the benchmark and migration history.

**The model.** One class is the ONLY element type crossing Job channels:

```kotlin
class JobMessage(
    var payload: Any?,       // the strongly typed domain value (null on the pure-flat lane)
    var flat: FlatView?      // header ref + FlatFileRecord, materialized on demand
)
```

- **Payload lane**: `payload` carries an arbitrary typed object; its static type is inferred and
  flows through the graph. Scalar / Run / parameter streams live here.
- **Flat part**: `FlatView(var header, val record)` — the pair invariant lives in the type. Nullable
  as a whole, so pure-payload lanes pay no array allocations. The CSV lane populates the flat part and
  leaves `payload` null. Accessor: `flatView()`.
- **Ownership transfer**: the sender never touches a message after emitting; the receiver owns it and
  MAY mutate in place — which is what makes "clear and refill instead of re-create" legal.
- **Auto-flatten fallback** (`ensureFlat()`): when a flat-consuming operation needs columns and the
  flat part is absent, materialize it IN PLACE from the payload (Map → keyed columns; anything else →
  a single `value` column via `ColumnValue.toText`) and cache it on the message. **Palette-insert-and-
  it-works is preserved**: a Double stream through CsvWriter writes a `value` column. A null payload
  flattens to `"null"`, not `""`.

**Expressions — one facility, three scopes.** A single engine (a generalized `CalculatedColumnEval`)
whose generated class takes a typed receiver:
- **Payload as receiver + a `payload` alias** — a `Person` payload's members are bare (`age > 30`).
  Kotlin receiver rules mean payload members **shadow same-named columns**; `payload.x` and the column
  accessor are the documented escape hatches.
- **Flat columns bare** (`City eq "Lviv"`), via `ColumnValue` accessors generated from the header.
- **Parameters bare by name, typed** (Script parity), threaded once per compile.
Compilation is lazy, keyed on (expression, header, payload type, parameter types), cached via
`CachedKotlinCompiler`, run under `runBlockingIo`. The generated body is a **lambda-valued `probe`
property**, so ONE compile serves validation, the type walk and execution. A parameter/column name
collision fails **before** compile with a descriptive message.

**Type inference and flow.** A Job-side analogue of `ScriptValidation`'s fixpoint, computed
server-side per notation version, walking `JobChannelDerivation` order:
- **`FormulaSourceWorker`** infers its expression's type via probe-compile +
  `ExpressionReturnTypeInference` (flavour-neutral, gained `isIterable` / `iterableElementType`).
  **Stream-vs-single is strict static dispatch** — an `Iterable<T>`-typed expression streams elements
  of `T`; anything else emits one message. User-confirmed.
- **`FormulaWorker`** infers its `payload:` expression (empty = identity); **Filter / ValueSet / Sort /
  Summary / Pivot / Preview** are identity; **`RunWorker`** takes the child signature's main result
  type; **readers** contribute no payload type; **`ResultSink`**'s input types the signature's output.
- The walk is `WorkerBase.payloadFlow(input: WorkerLane, context): WorkerLaneAttempt`, default
  identity. `WorkerLane = (payloadType, flatColumns)`; **null flatColumns = statically UNKNOWN**,
  which is what `KotlinSyntaxValidator` exists to serve.
- Failures surface as validation errors on the worker card, not run-time crashes.

**Strict-static consequences pinned by test** (do not "fix" these):
- A bare run's null parameter is an **EMPTY stream** (it was "streams a single null").
- A scalar bound to a List-typed parameter **fails at the typed accessor's checkcast**.
- An untyped `Any` parameter bound to a List **single-emits the whole list**.

**Boundary rules.** `JobMessage` never crosses a Logic boundary:
- **Outbound** (`ResultSinkWorker`): yield the payload when present; a flat-only message materializes
  to an ordered `Map<String, String>` (column → text, header order). The buffer keeps raw messages
  (materialize at yield) so carryover is untouched. **Flat columns are auxiliary unless explicitly
  promoted** — to return a computed value, the user writes a `payload:` formula.
- **Inbound**: a Script `RunStep` argument binds a declared parameter (typed in the signature);
  workers read it via expression scope. `RunWorker` unwraps per the same rule and wraps the child's
  result as a fresh message's payload.

**Known limitations (recorded, not built).** Empty stream ⇒ no schema for writers (channel-level
schema metadata if it ever bites); cross-cutting message metadata (a dedicated headers-map field is a
compatible later addition); richer flatten rules (data classes via reflection, TupleValue
components); inferred-vs-declared channel type cross-checking (co/contravariance stays out of scope).

**Out-of-repo migration note:** any notation outside these repos using `is: ParameterSourceWorker`
needs a hand edit to a `parameters` declaration + `FormulaSourceWorker`.

---

## Appendix B — durable knowledge from the retired build plan

`2026-06-23_job-paradigm.md` survives in git history only (`git show ef0dbd4~1:plans/2026-06-23_job-paradigm.md`
in the kzen repo). Everything durable is here.

**Gotchas that will bite again if forgotten** (the first two are also in `kzen-auto/AGENTS.md`):
- **Never add `title:` (or any attribute needing an inherited definer) to the `Channel` /
  `DuplexChannel` archetypes** — they have no `is:` parent, so an attribute that can't self-define
  fails the whole object's definition and silently **drops every channel** in the graph.
- **Palette-inserted workers need empty-string body defaults for channel-ref attributes** — a ribbon
  insert creates `is: <Worker>` only; without the archetype's `port: ""` body default the port
  attribute is *missing* rather than blank, and synthesis/derivation treat those differently.
- **Live progress cannot hang off a `$stable` trace path** — the trace projection resolves every
  `$stable` path's id back to a location and silently drops paths with extra segments; a
  fixed-convention path (`JobConventions.workerProgressPath`) is retained as-is. It looks like a bug
  when hit.
- **`@Reflect` workers (including test fixtures) must live in `src/main`** — KSP registration is
  main-source-set only.

**Design rationale to preserve (don't re-litigate in phases):**
- **Migration is rebuild-the-whole-graph, never in-place re-config.** Workers are live parked
  coroutines and cannot be re-pointed; change detection is a value-equal `objectDefinitions` compare,
  so a no-edit resume provably does not rebuild.
- **Capture-BEFORE-teardown is load-bearing**, not stylistic: it was reversed same-day from a
  post-join `loadState` because teardown's `onClose` closes a live handle before any post-join read
  could detach it. Phase 9 builds on this seam.
- **One step = one batch, uniformly.** The reader once checkpointed per *record* while publishing per
  *batch*, making stepping look wedged (~4096 clicks per visible update).
- **Channel carryover exists because pause is non-destructive but migrate teardown is** — the
  "total ≠ 1 billion" bug: buffered batches died with the torn-down graph while the resumed reader
  never re-read them. `drainBuffered` / `preload` + consumer checkpoint-before-receive is the
  exactness contract; **don't weaken any of the three.**
- **Frame-owned trace lifecycle**: a hosted child *invocation*'s trace buffer lives exactly as long as
  its frame — re-entry gets a fresh buffer, parallel callers get distinct buffers, and a completed
  Job-hosted child's trace is not retained (a documented trade-off vs Script's film strip). The
  pinning tests lived in the retired `JobNestedLogicTest`; when touching child hosting (phase 8),
  verify an equivalent pin survived the engine rewrite.
- **Known engine gap (pre-existing, out of scope here)**: concurrently-live children of the *same*
  document (possible in Job) still alias by stable id at the migration barrier.

**Superseded — do not resurrect:** the step-budget model (`MutableLogicControl`,
`arm(budget, depthLimit)`, `grantStepToChildren`) → engine node-depth step rules;
`JobExecution`/`WorkerSupervisor`/`JobControlImpl`/`JobLogicHost` →
`JobRun`/`WorkerLogic`/`EngineJobControl`/`JobChildLogicHost`; the `NestedLogicUnsupported` grandchild
restriction → lifted structurally (phase 8 pins it); per-event child graph-build cost →
`JobChildLogicHost` compile cache; scalar source/sink gap → `FormulaSourceWorker` + Preview's untyped
lane; `RunWorker` palette/editor gap → `RunTool` + `SelectLogicEditor`; `RecordBatch` → framework
batching + `JobMessage`; the old inFlight-only deadlock heuristic → the channel-aware
`JobDeadlockMonitor` (whose blanket serve suppression phase 7 narrows); per-worker outcome chips →
engine E7 (phase 7 verifies the remainder).
