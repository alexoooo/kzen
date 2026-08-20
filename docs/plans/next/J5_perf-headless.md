# J5 — performance + headless readiness — implementation plan

> **Status: ready to execute.** Generated 2026-07-19; the live constituent plan is now
> `../2026-07-25_job-improvements.md` Phase 5 (benchmark-first perf + headless mode). Decisions are PRE-MADE there (benchmark before
> optimizing; no record pooling; headless = a run mode, not a fork; self-managed workers recorded,
> not built) — this document elaborates them into execution-ready steps **verified against current
> code** (post SER2–SER5, Y, G5, G7, TP1/TP3/TP4). Every anchor below was re-verified 2026-07-19;
> drifted anchors are corrected and one pre-made mechanism was found unimplementable as written and
> is **rescoped with rationale** (see "Serve-gate realization" — the graph-plan-5b precedent).
> Master plan: Stage B2; no hard prerequisite; E6 multi-run is DEFERRED, so a headless run occupies
> the JVM's single active-run slot.
>
> ## ⚠️ Re-validated 2026-07-25 — read this before using any anchor below
>
> Written **before** the typed `JobMessage` element model and the `RestHandler` split. Inline
> references are updated; **any line number quoted from before 2026-07-22 should be re-checked.**
>
> | Was | Now |
> |---|---|
> | `DataRecord(headers, record)` | `JobMessage.ofFlat(headers, record)`; `Emitter.send(element: JobMessage)` |
> | `DataRecord.kt:20-22` (ownership contract) | same contract, now in `JobMessage`'s kdoc |
> | `RestHandler.logicStart(parameters, paused)` at `RestHandler.kt:1114-1165` | **`LogicHandler.logicStart(parameters, paused): LogicStartAttempt`** (`server/api/handler/LogicHandler.kt:45`); `paramPauseOnError` at :55, `paramStepMode` at :63 — the `mode` param follows the same pattern |
> | `RestHandler` calls the controller at `:1142` | the same call now lives in `LogicHandler` |
>
> **The reuse ceiling is no longer "do NOT pool" — it is "pool only if the benchmark convicts".**
> The element model's phase 4 folds into this phase and supplies the shape: batch-bounded message
> arenas / pooled `FlatFileRecord`s recycled after the consumer settles a batch, with
> **copy-on-retain** for retaining operators (Preview's window, Sort's buffer); prefer
> arena-per-batch over free-lists. ⚠️ **Hard constraint: migration carryover
> (`JobChannel.drainBuffered`) captures live messages — a pool must transfer ownership of captured
> messages, never recycle them.** Step 11's blanket "do NOT pool" is superseded by this gate.
>
> **Add a named baseline row for `FlatView`.** The element-model follow-up collapsed the nullable
> header/flat pair into `FlatView`, costing one extra 2-field allocation per flat-lane element, and
> **explicitly deferred the judgement to this benchmark.** Acquit or convict it here; do not carry
> it forward as an open question.
>
> **Sizing: M (harness + baseline) + S (fixes + headless).** If one session doesn't fit, split:
> **Session A** = steps 1–3 (harness, fixtures, baseline table); **Session B** = steps 4–8 (IO
> fixes, re-measure, mode plumbing, headless test, docs). Step 4 depends on step 3's numbers;
> steps 5–7 are independent of 3–4 and can lead Session B.

## Scope & goal

1. **Know the Job-vs-Report throughput gap** (goal 2 of the build-plan rubric): a JMH-free
   wall-clock harness in `kzen-auto-jvm/src/test` running the same data through the Job graph, the
   Report disruptor pipeline, and a single-thread inline baseline; rows/s + allocation recorded as
   a table in the constituent plan's as-built note. Re-establish the lost pre-rewrite datum
   (`JobExecutionTest.sliceThroughputBenchmark`: batched-channel Job within **~2.5% of inline at 4M
   rows** on the retired executor — shape recovered from git, see findings F9).
2. **Fix the cheap hot-path losses** after baselining: hoist per-record `runBlockingIo` to
   per-batch in both readers and both writers; presize/hand-off the channel batch buffers — without
   breaking the one-step ≈ one-batch checkpoint contract or migration losslessness.
3. **Headless run mode**: a `mode` start parameter (default interactive) gating (a) progress
   emits (finals only), (b) the external serve/duplex UI bridge, (c) nothing for checkpoints
   (already a fast path). Same Job, same artifacts, minus observability. Single-run slot (E6
   deferred).
4. **Protect**: `JobControl` (commonMain SPI) stays process-neutral — J5 adds nothing to it;
   record the self-managed-worker constraint without designing it.

NOT in scope (see § Out of scope): record pooling, substrate swap, multi-process, multi-run,
retain=false progress emits (J7), deadlock-suppression removal (J7), Report freeze/parity (J3/J4).

## Dependencies & coordination

- **No hard prerequisite.** J2 (signature) not needed — the benchmark drives engines directly.
- **J7 owns** `EngineJobControl.publishProgress` retain=false adoption (the in-code note at
  EngineJobControl.kt:106-110) and deadlock-precision (removing the `externallyServing` blanket,
  JobDeadlockMonitor.kt:69-76). J5 must not touch either. J5's headless mode *does* make the
  deadlock monitor active for serve-bearing Jobs (external clients absent in headless) — that is
  the interactive-suppression logic working as built, not a J7 change; the headless test covers it.
- **J8** owns client sweep; J5 makes zero JS changes (headless is started via REST param; no UI
  affordance in this phase — record as J8/follow-up candidate).
- **J2 landed 2026-07-21**, so `JobLogicCompiler.compile` has already grown signature derivation
  (and, since the element model, parameter/result threading via `JobParameters`) — the headless
  flag threading (step 6) composes with it trivially (different lines of the same file).
- Benchmark results feed the **C1 define-cost measurement gate** indirectly
  (`JobChannelSynthesis`'s per-compile define cost shows up in start latency, not steady-state
  rows/s — out of J5's measured window). See `../2026-07-25_core-and-verification.md`.

## Current-state findings (anchors verified 2026-07-19)

### F1 — per-record blocking-IO sites (all confirmed, one addition)

| Site | Anchor (fresh) | Shape |
|---|---|---|
| `CsvReaderWorker.produce` | CsvReaderWorker.kt:72-77 (`readRecord` inside `runBlockingIo` at :73) | one elastic-pool round trip **per record** |
| `MultiFileReaderWorker.produce` | MultiFileReaderWorker.kt:80-83 (`readRecord` at :81) | same, per record per file |
| `ExportWriterWorker.onElement` | ExportWriterWorker.kt:94-106 (block at :96-105) | one round trip per record (header-once + row) |
| **`CsvWriterWorker.onElement`** | CsvWriterWorker.kt:52-62 | **same shape — NOT in the original plan's list; add to scope** (it is the writer both the slice benchmark and the aggregate pipeline use) |

Cost structure (why the hoist is the win): `JobControl.runBlockingIo` →
`Execution.blocking` (EngineJobControl.kt:71-78) → `RunEngine.blocking`
(kzen-lib `RunEngine.kt:768-775`) does `dispatcher.enterBlocking()` +
`runInterruptible(elasticDispatcher)` **per call** — i.e. two pool handoffs and a dispatch per
record today. Hoisting to per-batch removes ≥ 99.9% of them at the default batchSize 1024.
(Note: the pre-rewrite 2.5% datum predates this engine seam; expect the un-fixed engine-era gap to
be *larger* than 2.5% — that is the point of re-baselining before fixing.)

### F2 — channel allocation sites (confirmed)

- `JobChannel.Producer.pending = ArrayList<Any?>()` — JobChannel.kt:166. Default capacity;
  grows to batchSize on first fill only (`clear()` keeps capacity) — presize is free but minor.
- `Producer.flush` — JobChannel.kt:186-203: `val batch = ArrayList<Any?>(pending)` (:193) then
  `pending.clear()` — **one full copy per batch**. The real win is hand-off-and-replace (step 4c),
  not presizing the copy (the copy-constructor already sizes exactly).
- `Input.receiveBatch` carryover slicing (:234-239) and `held = ArrayDeque(batch)` (:253, :282)
  are cold/element-mode paths — leave unless the benchmark convicts them.
- `drainBuffered`'s identity-dedup (:130-158) relies on the **same list object** riding
  `inFlight` and the channel buffer — the hand-off design preserves this (the sent list *is* the
  former `pending`).

### F3 — framework cadence (the contract the hoist must not break)

- **Source**: `SourceWorker.drive` (SourceWorker.kt:30-43) — leading checkpoint at :36, then
  `produce`, then trailing `emitter.flush()`. `Emitter.send` (Emitter.kt:37-50) counts sends and,
  at every `output.batchSize()`-th send, does `flush → checkpoint → onFlush(publish)` — the
  checkpoint (= pause/migrate park point) happens **inside `send`**. Therefore a reader that
  pre-reads a block of records must never hold locally-buffered records when a cadence checkpoint
  fires, or a migration would lose them (the reader's file position is already past them, and they
  are in neither `pending` nor the channel). **Alignment rule**: each blocking read-block must be
  exactly the number of sends remaining until the next flush boundary — see step 4a's
  `Emitter.sendsUntilFlush()`.
- **Sink**: `SinkWorker.drive` (SinkWorker.kt:29-45) — checkpoint **before** `receiveBatch`
  (:31), then per-element `onElement` dispatch (:36-40), then `publish`. A whole-batch write hook
  (step 4b) changes nothing about checkpoint placement — the contract is untouched.
- **Transform**: TransformWorker.kt:45-72 — CPU-only workers (Filter/Formula/ValueSetFilter) do no
  IO; out of the hoist's scope.
- Appendix contract (constituent plan): **one step ≈ one batch**; `drainBuffered`/`preload` +
  checkpoint-before-receive is the exactness contract — JobBatchingTest /
  JobChannelCarryoverTest / JobMigrationTest pin it and must stay green.

### F4 — progress push path (headless gate a)

`WorkerBase.run` (WorkerBase.kt:46-69): serve loop launched only when `serve != null` (:48-58);
`drive`; **forced final publish** at :63 (`publish(control, force = true)`); serve job cancelled in
`finally` (:66). `WorkerBase.publish` (:138-148) → `JobControl.publishProgress(location, value,
force)` → `EngineJobControl.publishProgress` (**EngineJobControl.kt:98-112** — drifted from the
plan's 95-105): 200 ms throttle (:100-103), `execution.emit(progressAddress, …)` at :111. The
retain=false coordination note at :106-110 is **J7's** — do not touch it. Gate (a) is a guard at
the top of this method: `if (!interactive && !force) return` — the forced final still lands, so
the post-run cards (which read the live map / finals) keep working.

### F5 — serve synthesis & the serve-gate realization (VERIFIED DRIFT — rescope required)

The pre-made decision says: *"skip `wireServe` synthesis → serving workers just don't get a serve
endpoint — `WorkerBase` already handles serve == null"*. Verification result:

- `WorkerBase` **does** handle null (WorkerBase.kt:37, :48-58). BUT nothing can deliver null
  today: all four serving workers declare **non-nullable** serve constructor params —
  `PreviewWorker` (PreviewWorker.kt:42), `SummaryWorker`, `PivotWorker`, `ExploreWorker`
  (archetype body default `serve: ""` at job-worker.yaml:201, :236, :364, :395).
- With `wireServe` skipped, the port stays `""`; `JobChannelCreator.create` **throws on an empty
  reference** (JobChannelCreator.kt:83-85), and before that, a non-nullable empty channel-port
  reference is **unsatisfiable at `createGraph` time — GraphCreator never schedules the worker**
  (recorded in JobChannelSynthesis.kt:27-33). `JobRun` then *silently drops* the unscheduled
  worker (`as? Worker ?: return@mapNotNull null`, JobRun.kt:152-156) — its input channel loses its
  single consumer, upstream blocks, and the (now-active, see below) deadlock monitor fails the
  run. **The literal skip breaks every serve-bearing Job in headless mode.**

**Rescoped realization (decided here, smallest verified change):** headless keeps `wireServe` but
stamps the synthesized duplex channel **`external: "false"`** instead of `"true"`
(JobChannelSynthesis.kt:163-165 builds the notation; the flag is read only by the bridge —
DuplexJobChannel.kt:24-32). Everything the decision *wants* then falls out of existing code with
zero further edits:

- `JobRun` opens **no external client** (`if (channel.external)` — JobRun.kt:110-113) → no
  `onRequest` router registered (:148-150) → a `/logic/request` against the run fails cleanly.
- `JobDeadlockMonitor` runs with `externallyServing = false` (JobRun.kt:165-166,
  JobDeadlockMonitor.kt:69-76) → **deadlock detection is active in headless runs** (a bonus, and
  the correct semantic: nothing external can un-stick a headless run).
- The serving worker constructs unchanged; its serve loop parks on the never-fed duplex channel
  and is cancelled at settle (WorkerBase.kt:65-68; no client ever opens, so the request stream
  never closes on its own — the cancel is the existing backstop, same as interactive teardown).
- Cost: one inert `DuplexJobChannel` + one parked coroutine per serving worker — negligible.

The literal-skip alternative (make the four serve params nullable + teach `JobChannelCreator`
blank→null + verify GraphCreator schedules an object with an empty nullable reference) touches
worker constructors and kzen-lib creation semantics for zero additional behavior — **rejected**;
recorded here so it isn't re-litigated. The headless test asserts the *behavioral* contract ("no
external serve surface, requests fail, artifacts identical"), not the literal absence of channel
objects.

### F6 — mode plumbing seams (all verified)

- **Wire**: `GET/PUT /logic/startRun` + `/logic/startStep` (CommonRestApi.kt:110, :119; routes
  KzenAutoMain.kt:362-405 — GET + PUT twins both parse via the same `Parameters`, so a new param
  needs **zero route changes**). **`LogicHandler.logicStart(parameters, paused)`**
  (`server/api/handler/LogicHandler.kt:45`) already parses `paramPauseOnError` (:55) and
  `paramStepMode` (:63) — the `mode` param follows the same pattern. Param constants live at
  CommonRestApi.kt:82-86.
- **Controller**: `ServerLogicController.start(root, snapshot, pauseOnError)` — the *concrete*
  overload at ServerLogicController.kt:354-418 (the kzen-lib `LogicController` interface override
  at :345-351 delegates to it; **the interface is untouched** by adding a param to the concrete
  overload, which is what `LogicHandler` calls). `compileLogic`
  (ServerLogicController.kt:900-912) constructs `LogicCompilerServices` (:909-911) and is called
  from **three** sites: `start` (:380), `moveTo`'s recompile (:706), and `pendingMigration`
  (:946) — so the mode must persist on `LogicState` (:105-154) to survive live-edit migration and
  move-to.
- **Compiler services**: `LogicCompilerServices` (LogicCompilerServices.kt:31-40) currently has 8
  fields and **no mode** — add one; flavours read it uniformly (the pre-made decision); Script /
  Flow / Report ignore it.
- **Job threading**: `JobLogicCompiler.compile` (JobLogicCompiler.kt:31-58) calls
  `JobChannelSynthesis(…).synthesize(graphDefinition, documentPath)` at :39-41 —
  the serve-external stamp needs an `interactive` parameter on `synthesize` (default `true`;
  callers: JobLogicCompiler + `JobChannelDefaultTest`; **no JS caller** — the only kzen-auto-js
  reference is a comment in JobChannelDefaults.kt:36). `JobLogic` (JobLogic.kt:25-50) already
  carries `services` → `JobRun` (JobRun.kt:74-90) reads it → `WorkerLogic`
  (WorkerLogic.kt:40-67, `EngineJobControl` constructed at :59) needs the flag threaded into
  `EngineJobControl` (constructor at EngineJobControl.kt:33-39).
- **Checkpoint gate (c) — nothing to do, confirmed**: `RunEngine.checkpoint` (kzen-lib
  RunEngine.kt:664+) is a short `synchronized(lock)` block that returns without suspending while
  the run is running; per-node state is captured lock-free (RunEngine.kt:1124-1130). One lock
  acquisition per batch (not per record) via the cadence — already fine.

### F7 — how each side runs headlessly today (benchmark entry points, verified)

- **Job, engine-direct** (no controller, no REST): `KzenAutoContext.forTest()` +
  `AutoTestUtils.readNotation()` / `graphDefinitionAttempt(…)` + `JobLogicCompiler.compile(main,
  notation, definition, LogicCompilerServices(…, LogicRunExecutionId.random()))` +
  `RunEngine(jobLogic, stableId)` → `engine.resume(); engine.await()` — the exact recipe of
  `JobNotationTest.newEngine()` (JobNotationTest.kt:122-143) and its run pattern (:67-81).
- **Report, engine-direct**: identical shape via `ReportLogicCompiler.compile` —
  `ReportNotationTest` (ReportNotationTest.kt:57-113) is the recipe, including the offline output
  assertion `ReportRun.outputInfoOffline(reportRunContext, context.reportWorkPool)` (:110-112).
  **The Task paradigm is NOT needed** for headless Report execution — the Logic path runs it to
  completion engine-direct. (Report's UI-triggered background path still exists separately;
  irrelevant here.)
- **Controller-level** (for the mode-plumbing test): `context.serverLogicController.start(…)` +
  `continueOrStart` + await helpers — pattern in ServerLogicControllerTest.kt:59-100.
- Test notation fixtures auto-load from `kzen-auto-jvm/src/test/resources/notation/test/*.yaml`
  (AutoTestUtils.readNotation scans file + classpath media — AutoTestUtils.kt:38-75). Blank-port
  fixtures rely on synthesis (job-engine-linear-test.yaml is the model). All benchmark workers are
  built-ins → **no new `@Reflect` classes, no KSP concern**.

### F8 — worker/spec shapes needed by the fixtures (verified)

- `CsvReaderWorker(path, delimiter, header)` — `header: false` synthesizes positional `c0, c1, …`
  (CsvReaderWorker.kt:18-23) — the headerless 1BRC lane.
- `FilterWorker` `where:` = Kotlin boolean expression (job-worker.yaml:100-123);
  `ValueSetFilterWorker` `filter:` = FilterSpec map — **reuses Report's exact predicate**
  (job-worker.yaml:126-155): YAML shape `filter: { <column>: { type: RequireAny, values: [a, b] } }`
  (ColumnFilterSpec.kt:20-51, ColumnFilterType RequireAny/ExcludeAll).
- `FormulaWorker` `formula:` = column→Kotlin map (job-worker.yaml:158-184; example
  job-report-formula-test.yaml:17-22).
- `PivotWorker` `pivot: { rows: […], values: { <col>: [Min, Average, Max] } }`
  (job-worker.yaml:222-260); it is a **transform** that streams the built pivot table downstream
  at end-of-stream (PivotWorker.kt:102-117) — so `reader → pivot → CsvWriterWorker` yields a
  **file artifact** of the aggregate, ideal for A/B sanity checks. Aggregate types: Count / Sum /
  Average / Min / Max (1BRC ⇒ Min/Average/Max).
- `ExportWriterWorker` `export:` = OutputExportSpec (format/compression/path;
  ExportWriterWorker.kt:52-58) — resolves `${time}` at `onStart` (:79-83): **pin the fixture's
  path pattern to a literal path (no `${time}`)** so A/B byte-compare and re-runs are
  deterministic. `${group}` resolves empty (DataLocationGroup.empty, :81-82) — unchanged (J4's
  concern).
- Report document spec shape: common-document.yaml:214-256 (`input.selection.locations`,
  `formula: {}`, `filter: {}`, `analysis: {type: FlatData|…, pivot: {rows, values}}`,
  `output: {type: Explore|Export, explore, export{format,compression,path}, work}`);
  OutputType = Explore | Export (OutputType.kt:4-7). Working example fixture:
  report-engine-test.yaml. Report's `previewAll` is stubbed (`TODO` at ReportRun.kt:448-450) —
  keep `previewAll: false` in fixtures (the archetype default).

### F9 — the lost pre-rewrite harness (recovered from git, cheap)

`git log --all -S sliceThroughputBenchmark --oneline` → added `7c100826`, deleted by `4bc9bcf2`
("new Logic progress"). Recovered via
`git show 4bc9bcf2~1:kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/objects/job/JobExecutionTest.kt`
(method at old :128). Shape to reproduce: **@Test, default 100_000 rows, `-DjobSliceRows=<n>`
scaling; Job slice (reader→filter→writer) timed vs a single-thread inline baseline (BufferedReader
line-split filter write) over the same generated file; perf logged only (nondeterministic), the
assertion is byte-identical output (`assertEquals(baselineLines, jobLines)`); rows/s helper.**
The ~2.5%-of-inline datum was measured at 4M rows on the retired re-entrant executor.

### F10 — headless status/transport interplay (nothing to build)

A headless run still occupies `ServerLogicController`'s single slot, bumps epoch/structureVersion,
and announces over SSE — harmless (an idle browser just sees a run). `status()` cost is
per-request, not per-emit. No client change needed; the UI can even watch a headless run's
worker cards via the finals. Do not gate status/SSE on mode.

## Pre-resolved questions (from the task's "resolve NOW" list)

| Question | Resolution |
|---|---|
| Where does `mode` ride? | New `CommonRestApi.paramRunMode = "mode"` (beside :82-86); parsed in **`LogicHandler.logicStart`** like `paramPauseOnError`; value `interactive` (default) / `headless`. Rides both GET and PUT twins of `/logic/startRun` + `/logic/startStep` for free (same `Parameters` parse). |
| Where does the flag live server-side? | Enum `LogicRunMode { Interactive, Headless }` in kzen-auto-common `paradigm/logic/` (commonMain, JS-visible for a later UI affordance). Concrete overload `ServerLogicController.start(root, snapshot, pauseOnError, runMode = Interactive)`; stored on `LogicState`; threaded through `compileLogic` (all 3 call sites) into `LogicCompilerServices.runMode` (default Interactive). kzen-lib `LogicController` interface untouched. |
| How do flavours read it? | Off `LogicCompilerServices` (pre-made). Only `JobLogicCompiler` consumes it in J5; Script/Flow/Report ignore. |
| Gate (a) publishProgress | Guard in `EngineJobControl.publishProgress` (:98): non-forced emits return early in headless; forced finals land. SPI (`JobControl`) unchanged. |
| Gate (b) serve bridge | **Rescoped** (F5): `wireServe` stamps `external: "false"` in headless (new `interactive: Boolean = true` param on `JobChannelSynthesis.synthesize`); no client, no `onRequest`, deadlock monitor active. WorkerBase serve==null verified handled but unreachable — literal skip rejected (breaks worker instantiation). |
| Gate (c) checkpoint | Confirmed nothing to do (F6): fast synchronized path, once per batch. |
| How does Report run headlessly today? | Engine-direct via `ReportLogicCompiler` + `RunEngine` (ReportNotationTest recipe) — not Task-paradigm (F7). |
| How does a Job run without the UI? | Engine-direct via `JobLogicCompiler` + `RunEngine` (JobNotationTest recipe) or `serverLogicController.start` (F7). |
| Old harness shape? | Recovered (F9); rebuild to the same intent on the engine. |
| Measurement method | Wall clock (1 warmup + 3 measured, median) → rows/s; allocation: `-XX:+UseEpsilonGC` on a bounded slice in a dedicated JVM (heap-used delta = exact total allocation) + always-on `GarbageCollectorMXBean` collection count/time deltas in normal runs. |
| Where results recorded | As-built table in `../2026-07-25_job-improvements.md` Phase 5 tracker note (per its ground rules) — the harness stays committed for re-runs. |
| JobControl process-neutrality check | J5 adds zero members to `JobControl`; verification step greps `import java`/`import tech.kzen.auto.server` in `kzen-auto-common/**/paradigm/job/` → must stay empty (today: JobControl.kt imports only TupleValue + ObjectLocation — verified). |

## Step-by-step implementation

### Step 1 — benchmark fixtures (data + notation)

New files (all under kzen-auto-jvm; stage each with `git add <path>` as written):

1. `src/test/kotlin/tech/kzen/auto/server/exec/job/bench/BenchmarkData.kt` — deterministic
   (fixed-seed `Random(42)`) generators writing under `build/bench/`:
   - `writeStations(rows, path, header: Boolean)`: `station,value` CSV, 400 distinct stations
     (`s000`…`s399`), value = one-decimal double in [-99.9, 99.9] (1BRC-style aggregate shape);
     headered and headerless variants share content modulo the header line.
   - `writeWide(rows, path)`: 12-column CSV `id,flag,cat,qty,price,c5..c11`, `flag` ∈
     {yes,no} alternating, `cat` ∈ 8 values — wide-ish rows for filter+formula+export.
   - `writeFlagged(rows, path)`: the old harness's `id,flag,value` shape (S1 continuity).
2. Notation fixtures in `src/test/resources/notation/test/` (blank ports — synthesis wires them;
   modeled on job-engine-linear-test.yaml / job-report-formula-test.yaml / report-engine-test.yaml):
   - `bench-job-slice.yaml`: `main: {is: Job}` + workers `reader` (CsvReaderWorker,
     path `build/bench/slice/input.csv`) → `filter` (FilterWorker, `where: 'flag eq "yes"'` —
     copy the operator syntax from job-engine-linear-test.yaml verbatim) → `writer`
     (CsvWriterWorker, `build/bench/slice/output.csv`).
   - `bench-job-aggregate.yaml`: `reader` (header: true, `build/bench/agg/input.csv`) →
     `pivot` (PivotWorker, `pivot: {rows: [station], values: {value: [Min, Average, Max]}}`) →
     `writer` (CsvWriterWorker, `build/bench/agg/job-output.csv`).
   - `bench-job-aggregate-headerless.yaml`: same but `reader` `header: false`, input
     `build/bench/agg/input-headerless.csv`, pivot over `c0`/`c1` (**Job-only lane** — no Report
     twin; Report's CSV input reads a header row).
   - `bench-job-export.yaml`: `reader` (`build/bench/exp/input.csv`) → `vfilter`
     (ValueSetFilterWorker, `filter: {flag: {type: RequireAny, values: [yes]}}`) → `formula`
     (FormulaWorker, `formula: {total: "qty * price"}`) → `export` (ExportWriterWorker,
     `export: {format: csv, compression: none, path: "build/bench/exp/job-export.csv"}` —
     **literal path, no ${time}**).
   - `bench-report-aggregate.yaml`: Report over `build/bench/agg/input.csv`, `analysis: {type:
     Pivot…, pivot: {rows: [station], values: {value: [Min, Average, Max]}}}`, `output: {type:
     Explore, work: "build/bench/agg/report-work"}`. Mirror report-engine-test.yaml's input block;
     mirror the `analysis` enum value name from `AnalysisType` (FlatData's sibling) when writing.
   - `bench-report-export.yaml`: Report over `build/bench/exp/input.csv` with the same
     value-set `filter:` and `formula:` specs, `output: {type: Export, export: {format: csv,
     compression: none, path: "build/bench/exp/report-export.csv"}, work: "build/bench/exp/report-work"}`.

   Fairness/equality notes to encode in the harness comments: ValueSetFilterWorker and
   FormulaWorker reuse Report's exact predicate/eval engines (job-worker.yaml:126-130, :158-159),
   and ExportWriterWorker reuses Report's formatter (ExportWriterWorker.kt:25-32) — so the export
   scenario is meaningfully byte-comparable; the pivot scenario compares row count + spot values
   (byte-exact composed A/B is J4's gate, not J5's).

### Step 2 — harness

3. `src/test/kotlin/tech/kzen/auto/server/exec/job/bench/JobReportBenchmark.kt` — an `object`
   with `@JvmStatic fun main(args)` plus per-scenario functions, reusing the F7 recipes:
   - Scenarios: **S1** slice (Job vs inline baseline — the F9 shape, including the byte-identical
     assertion); **S2** aggregate (Job pivot vs Report pivot vs inline HashMap min/mean/max
     baseline); **S2h** aggregate headerless (Job only); **S3** filter+formula+export (Job vs
     Report; assert export files byte-identical via `Files.mismatch == -1L` — flag any diff loudly
     but keep timing, since byte parity is J4's gate).
   - Protocol per scenario: generate data (once), 1 warmup run discarded, 3 measured runs, median;
     each run = fresh `KzenAutoContext.forTest()` + fresh engine, `engine.resume(); engine.await()`;
     assert Success; `engine.close()` + `context.close()` per run.
   - Metrics per run: wall ms, rows/s; GC deltas (`GarbageCollectorMXBean` collectionCount /
     collectionTime summed across beans, before/after); print one aligned table row per
     (scenario, impl) with the median + the run spread.
   - Knobs (system properties): `benchRows` (default 1_000_000; use 4_000_000 for the S1
     continuity datum), `benchScenarios` (csv filter), `benchRuns`.
   - Report side reads its result via `ReportRun.outputInfoOffline` (row count) as
     ReportNotationTest does; Job aggregate reads its own output CSV. Sanity equalities: S2 job
     pivot CSV row count == 400 == report table rowCount; spot-check one station's Min/Max
     against the inline baseline's map.
4. `src/test/kotlin/tech/kzen/auto/server/exec/job/bench/JobBenchmarkSmokeTest.kt` — @Test per
   scenario at tiny rows (e.g. 2_000), asserting the correctness/equality halves only — keeps the
   harness compiling and semantically pinned in CI without timing noise. (This is also the
   `-DbenchRows=` scaled entry point for JUnit-driven big runs, mirroring the old
   `-DjobSliceRows` usage.)
5. Gradle: add a `benchJob` task to `kzen-auto-jvm/build.gradle.kts` —
   `JavaExec`, `classpath = sourceSets["test"].runtimeClasspath`, `mainClass =
   "tech.kzen.auto.server.exec.job.bench.JobReportBenchmark"`, forwarding `bench*` system
   properties, `maxHeapSize` settable. Epsilon variant is the same task with
   `-PbenchEpsilon` adding `-XX:+UnlockExperimentalVMOptions -XX:+UseEpsilonGC -Xmx16g` and
   defaulting `benchRows` down to 250_000 (**bounded slice** — Epsilon never collects, the heap
   must hold the run's entire allocation; the harness prints
   `MemoryMXBean.heapMemoryUsage.used` delta = exact bytes allocated → bytes/row).

### Step 3 — baseline table (measure BEFORE fixing)

6. Run: `./gradlew :kzen-auto-jvm:benchJob` at 1M; S1 additionally at 4M
   (`-DbenchRows=4000000`); one Epsilon pass at 250K for bytes/row. Record the table (scenario ×
   impl × rows → wall ms, rows/s, ratio vs baseline/Report, GC count/ms, bytes/row) in the
   constituent plan's Phase-5 as-built note **before touching any production code**. This is the
   phase's gate: if the Job side is already within noise of Report/inline, steps 4a-4d shrink to
   "presize only" and the rest of the budget goes to headless.

### Step 4 — cheap wins (production edits, contract-preserving)

7. **4a — `Emitter.sendsUntilFlush()`** (Emitter.kt): new
   `fun sendsUntilFlush(): Int = if (cadence == null) output.batchSize() else output.batchSize() - sinceFlush`
   — the alignment primitive (F3). Generic framework API, no worker-type knowledge.
8. **4b — reader hoist** (CsvReaderWorker.kt:72-77, MultiFileReaderWorker.kt:80-83): replace the
   per-record loop with a block loop:
   ```kotlin
   val block = ArrayList<FlatFileRecord>(output-batch-size)   // reused instance field or local
   while (true) {
       val n = emit.sendsUntilFlush()
       block.clear()
       control.runBlockingIo {
           repeat(n) {
               val record = reader.readRecord() ?: return@runBlockingIo
               block.add(record)
           }
       }
       for (record in block) { emit.send(JobMessage.ofFlat(headers, record)); count += 1 }
       if (block.size < n) break   // EOF inside the block
   }
   ```
   Because each block is exactly `sendsUntilFlush()`, the cadence checkpoint (which fires on the
   n-th send) always lands with the local block fully drained — no record is ever held outside
   `pending`/channel at a park point, so migration capture (reader-at-position + channel
   carryover) stays exact even with `pendingFirstRecord` having consumed one send. MultiFile: same
   loop per file; the per-file open/header-skip blocks (MultiFileReaderWorker.kt:105-130) stay
   as-is (once per file). Kdoc: update both classes' "File IO runs through runBlockingIo" note to
   "per output batch".
9. **4c — sink batch hook + writer hoist** (SinkWorker.kt, CsvWriterWorker.kt,
   ExportWriterWorker.kt): add to `SinkWorker` an open
   `protected open suspend fun onBatch(batch: List<In>, control: JobControl) { for (e in batch) onElement(e, control) }`
   and have `drive` call `onBatch(cast-batch, control)` instead of the inline per-element loop
   (checkpoint placement unchanged). Both writers override `onBatch`: **one** `runBlockingIo`
   wrapping header-once + a loop of `writeRow`/`writeRecord`; keep their `onElement` as a
   one-element delegate to `onBatch` semantics (or leave it writing via the same private helper)
   so the class remains usable element-wise. No worker-type knowledge enters the framework — the
   hook is generic (extension rule preserved).
10. **4d — channel buffers** (JobChannel.kt:162-203): `pending` becomes
    `private var pending = ArrayList<Any?>(batchSize)`; `flush` hands off instead of copying:
    ```kotlin
    val batch = pending
    pending = ArrayList(batchSize)
    inFlight = batch
    try { tracked { channel.send(batch) } } finally { inFlight = null }
    ```
    Identity semantics preserved: the sent list is the same object `inFlight` exposes, so
    `drainBuffered`'s IdentityHashMap dedup (:130-158) is untouched; `pending` stays confined to
    the worker coroutine (reassignment happens in `flush`, same confinement as before). Update the
    :189-193 comment.
11. **Do not pool `JobMessage`/`FlatFileRecord` *before* the step-5 table convicts allocation** —
    ownership-transfer is the simplicity win (the contract is in `JobMessage`'s kdoc). If it does
    convict, apply the element-model phase-4 shape from the re-validation header (arena-per-batch,
    copy-on-retain, **carryover transfers ownership rather than recycling**). Do not touch
    `Input.receiveBatch`/`held` unless step 5 shows them (they are cold/element-lane).

### Step 5 — re-measure

12. Re-run step 3's matrix; append the after-rows to the same table; compute the delta. Record
    the data-driven follow-up list (columnar batch lane? record arena? element-lane `held`
    dedup?) in the as-built note as *candidates gated on these numbers* — build none of them.

### Step 6 — headless mode plumbing (per F5/F6)

13. **Enum**: `LogicRunMode { Interactive, Headless }` in kzen-auto-common
    `common/paradigm/logic/LogicRunMode.kt` (commonMain; wire value = lowercase name).
14. **Wire**: `CommonRestApi.paramRunMode = "mode"`; **`LogicHandler.logicStart`** parses it
    (the `LogicHandler.kt:55`/:63 pattern; unknown value → 400 via null return or default —
    prefer explicit `LogicRunMode.entries.firstOrNull { it.name.equals(v, true) }` + reject
    unknown) and passes it to the controller start.
15. **Controller**: `ServerLogicController.start(root, snapshot, pauseOnError, runMode:
    LogicRunMode = Interactive)` (concrete overload :354; the 2-arg interface override :345-351
    keeps delegating with defaults); `LogicState` gains `val runMode`; `compileLogic(root,
    attempt, runExecutionId, runMode)` — the two recompile sites (:706, :946) pass
    `state.runMode`, so **live-edit migration and move-to preserve headlessness**;
    `LogicCompilerServices` gains `val runMode: LogicRunMode = LogicRunMode.Interactive`
    (update the two test constructions in JobNotationTest/ReportNotationTest only if a default
    isn't used — with the default they compile unchanged).
16. **Job gates**:
    - `JobChannelSynthesis.synthesize(graphDefinition, jobDocumentPath, interactive: Boolean =
      true)`; `wireServe` stamps `externalAttributeName` = `interactive.toString()`
      (JobChannelSynthesis.kt:163-165). One-way `wireOneWay` untouched.
    - `JobLogicCompiler.compile` passes `services.runMode == Interactive` into synthesize
      (JobLogicCompiler.kt:39-41).
    - Thread `interactive: Boolean` `JobRun` → `WorkerLogic` → `EngineJobControl` (constructors
      JobRun.kt:192-198, WorkerLogic.kt:40-46/:59, EngineJobControl.kt:33-39);
      `publishProgress` gains the leading guard `if (!interactive && !force) return`
      (EngineJobControl.kt:98-103 — before the throttle bookkeeping; leave the :106-110 J7 note
      verbatim).
    - Script/Flow/Report compilers: no change (they never read `runMode`).
17. **JS client**: untouched (headless is started via REST/tests; a UI affordance is a recorded
    follow-up, J8-adjacent).

### Step 7 — headless run test

18. `src/test/kotlin/tech/kzen/auto/server/exec/job/JobHeadlessRunTest.kt` + fixture
    `notation/test/job-headless-test.yaml`: reader (≥ 50_000 generated rows — enough that
    interactive mode provably emits multiple throttled progress pushes) → summary (SummaryWorker,
    serve-bearing) → preview (PreviewWorker, serve-bearing) → writer (CsvWriterWorker).
    Engine-direct, run twice — interactive `LogicCompilerServices(runMode = Interactive)` and
    headless — assert:
    - **(i) progress finals only**: count engine history events at the progress address
      (`engine.history(0)` filtering `TraceEvent.address == Address.of("$job-progress")` — the
      marker const EngineJobControl.kt:45): headless count == number of progress-publishing
      workers (the forced finals, WorkerBase.kt:63); interactive count strictly greater
      (throttled stream). Also assert each worker's final live value is present (post-run card
      contract intact) via `context.logicTrace`/engine snapshot.
    - **(ii) no external serve surface**: headless run's synthesized duplex channels carry
      `external: false` → simplest probe: a `JobChannelSynthesis.synthesize(…, interactive =
      false)` unit assertion (channel notation has `external: "false"`), plus a run-level probe —
      start-stepped run parked at first wavefront, `engine.request(rootNodeId,
      preview-slice-request)` → interactive: success; headless: failure (no `onRequest`
      registered, JobRun.kt:148-150).
    - **(iii) identical artifacts**: writer output byte-identical across the two modes
      (`Files.mismatch == -1L`).
    - **(iv) deadlock monitor sane**: the headless serve-bearing run completes Success (monitor
      active but no false positive) — this doubles as the F5 regression pin.
19. `ServerLogicControllerHeadlessTest` (beside ServerLogicControllerTest): `start(root, snapshot,
    pauseOnError = false, runMode = Headless)` on the same fixture → run to completion; then a
    second run: start-step → apply a small notation edit (any `UpsertAttributeCommand` through
    `context.graphStore`) → resume → assert the **migrated** run still behaves headless (progress
    finals only) — pins `LogicState.runMode` threading through `pendingMigration`.

### Step 8 — documentation + protection checks

20. `kzen-auto/docs/architecture.md` § 3 (REST table, Logic row): add `mode=interactive|headless`
    to the `/logic/startRun`//`startStep` description with one sentence on the semantics (finals
    only; no external serve bridge; single-run slot until E6). No logic-spec change (background
    runs are already §2's no-global-singleton requirement; headless is a kzen-auto controller
    mode, not an engine concept — note this in the as-built).
21. Constituent plan (`../2026-07-25_job-improvements.md`): tick Phase 5 in the tracker; as-built
    note = benchmark table (before/after), the F5 rescope rationale (serve-gate realized as
    `external: false`), the re-established S1 datum vs the historical 2.5%, and the data-driven
    follow-up list.
22. **Process-neutrality check** (the "protect" item): assert by inspection + grep that
    `kzen-auto-common/**/paradigm/job/` gained no imports beyond kzen-lib common types
    (`Grep "import java" → 0 hits`; `JobControl` diff must be empty this phase). Record in the
    as-built that the headless gates live entirely in `EngineJobControl`/`JobRun`/compiler — an
    out-of-process runner can implement `JobControl` unchanged.
23. **Self-managed workers** (record only, pre-made): note in the as-built, verbatim intent —
    the raw `Worker` SPI + `WorkerBase`'s AsyncWorker-shaped hooks (onStart/drive/onClose,
    WorkerBase.kt:11-34) remain the seam for a future self-managed executor; the open problem is
    that worker-owned threads are not on the engine's `CountingDispatcher`, so quiescence would
    have to read worker lifecycle state, not just `inFlight`; design it **only** if the step-3/5
    numbers show a stage the coroutine model can't feed.

## Tests

New: `JobBenchmarkSmokeTest` (correctness halves of S1-S3 at tiny rows),
`JobHeadlessRunTest` (finals-only, no-serve-surface, identical-artifacts, monitor-sane),
`ServerLogicControllerHeadlessTest` (REST-level mode + migration carry), synthesis unit assert
(`external: false` when non-interactive — extend `JobChannelDefaultTest` or a sibling).

Must stay green (the contract net): `JobBatchingTest`, `JobChannelTest`,
`JobChannelCarryoverTest`, `JobMigrationTest` (reader/preview carry across the hoist),
`JobNotationTest` (incl. pause/resume), `MultiFileReaderWorkerTest`, `ExportWriterWorkerTest`,
`SortWorkerTest`/`PivotWorkerTest`/`SummaryWorkerTest`/`PreviewWorkerTest`/`ExploreWorkerTest`,
`JobDeadlockTest`, `JobExternalBridgeTest`, `JobRunWorkerTest`, `JobChannelDefaultTest`,
`ReportNotationTest`, and the `ServerLogicController*` suites.

## Verification

1. `./gradlew :kzen-auto-jvm:test` — full suite green (the exec/job + objects/job nets are the
   safety net per the constituent plan's ground rules).
2. `./gradlew :kzen-auto-jvm:benchJob` (1M) + `-DbenchRows=4000000` S1 + one Epsilon pass —
   before/after table lands in the as-built note; the S1 datum is re-established.
3. Headless: both new tests green; manual (optional, needs user): start the Sample Job with
   `curl "...:<port>/logic/startRun?path=...&object=main&mode=headless"` and observe the document
   completes with only final cards populated; interactive Sample Job behaviour unchanged
   (`./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`, eyeball progress/preview/pipes).
4. Process-neutrality grep (step 22) clean; `git status` shows only intended files, all new files
   staged individually (never `-A`; both repos checked — kzen-lib should show **no** changes this
   phase).

## Risks & gotchas

- **Cadence-alignment stranding (the real trap of step 4b).** A read-block larger than
  `sendsUntilFlush()` leaves file-consumed records in a local buffer at a cadence checkpoint —
  invisible to both reader-position capture and channel carryover → silent row loss on migrate.
  The `sendsUntilFlush` alignment removes the window entirely (checkpoints only ever fire on the
  block's last send). Keep `JobMigrationTest` + `JobChannelCarryoverTest` as the tripwire; if a
  new mid-read pause scenario is cheap, add it.
- **One-step ≈ one-batch must survive** (appendix contract): neither hoist moves a checkpoint —
  sources still checkpoint via the cadence, sinks still checkpoint before receive. Do not "just
  read the whole file" in one block; the block is bounded by the batch, which is the user's
  stepping granularity knob.
- **Error-park exposure window widens slightly**: a worker failing mid-block under pause-on-error
  has read up to a batch of records whose replay semantics on resume are the same as today's
  single-record case (recoverable wraps the whole `worker.run`, WorkerLogic.kt:63-65) — no new
  class of problem, but note it in the 4b kdoc.
- **F5 is load-bearing**: skipping `wireServe` outright silently drops serving workers from the
  run (unsatisfiable → unscheduled → `mapNotNull`). Any future "true skip" needs the nullable
  serve chain **and** a verified GraphCreator schedulability story — don't half-do it.
- **`${time}` in export paths** breaks A/B determinism and re-runs — benchmark fixtures pin
  literal paths (F8). Job vs Report export byte-diff is *reported*, not hard-failed, in the
  timing path (byte parity is J4's composed gate; the smoke test may hard-assert on the tiny run).
- **Epsilon sizing**: no GC means the bounded slice must fit `-Xmx` (start 250K rows / 16g;
  the harness prints heap headroom so an OOM is diagnosable, and Epsilon runs are optional
  corroboration, not the primary datum).
- **Benchmark noise**: Windows Defender scans `build/` writes; fixed seed, median-of-3, and
  same-JVM-per-scenario ordering keep the table stable enough for a gap-finding (not
  publication-grade) measurement. Run with the machine otherwise idle.
- **Deadlock monitor newly active in headless** (F5 fallout, intended): a serve-bearing Job that
  legitimately idles mid-run >200 ms with every worker channel-parked would false-positive only
  if it was *already* a monitor bug interactive-suppression was hiding — the headless test's
  serve-bearing completion run is the canary; anything it surfaces belongs to J7's precision
  work, not a J5 re-suppression.
- **Mode must ride recompiles**: `compileLogic` has three call sites (:380, :706, :946) — miss
  one and a live-edit or move-to silently flips a headless run interactive (or vice versa). The
  `ServerLogicControllerHeadlessTest` migration case pins it.
- **`JobChannelSynthesis` is commonMain**: the new `interactive` param defaults `true`, so the JS
  bundle and every existing caller compile unchanged (only a comment references it client-side).
- **Don't gate the forced final** — the post-run worker cards read it; gating it "for purity"
  breaks the headless-run post-mortem story (finals are the whole observability budget).

## Out of scope (pre-decided; do not re-open)

- **Message pooling / arena.** Ownership-transfer stays (the contract is in `JobMessage`'s kdoc).
  If (and only if) the step-3/5 table convicts allocation, the follow-up uses the pre-sketched shape:
  reuse bounded by channel handoff, retaining operators (Preview/Sort) opt out by copying,
  arena-per-batch over free-lists — recorded in the as-built, not built.
- **Self-managed workers** — constraint recorded (step 23), design gated on benchmark evidence.
- **Multi-process execution** — J5 only protects it (step 22); the process boundary is a future plan.
- **Multi-run (E6)** — deferred; headless occupies the single active-run slot.
- **Disruptor-in-Job / substrate swap** — explicitly rejected in the constituent plan.
- **retain=false progress emits, deadlock blanket removal, channel occupancy** — J7.
- **Grouped export, offline summary, Report parity/freeze** — J3/J4.
- **Fan-out / TeeWorker** — J6. **Client sweep** — J8. **UI affordance for headless start** —
  follow-up, not this phase.
