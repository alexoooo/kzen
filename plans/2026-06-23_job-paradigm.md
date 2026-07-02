# Job paradigm — implementation plan & status

> **Living document.** Inception 2026-06-23; goals-driven redesign 2026-06-24. This supersedes both the
> original M1–M5 milestone framing and the plan-mode scratch at
> `C:\Users\ostro\.claude\plans\i-want-to-define-pure-manatee.md`. Keep the **Status at a glance** and
> **Remaining — next steps** sections current as phases land; move completed work into **Completed (details)**
> with a one-paragraph summary + file pointers.

All paths are relative to `C:\Users\ostro\IdeaProjects\kzen-auto` unless noted. Verify from that directory:
```
./gradlew :kzen-auto-jvm:test --tests "*JobExecutionTest" --tests "*JobChannelTypingTest" --tests "*JobNestedLogicTest" --tests "*JobStateMigrationTest"
```
(The JVM test build rebuilds the production JS bundle as a dependency, so a green run also compiles the JS side.)

---

## What a Job is

A **Job** is a *third* logic paradigm for kzen-auto, beside **Script** (sequential `ScriptStep`s) and **Flow**
(synchronous vertex DAG). A Job is a `Logic` whose body is a graph of concurrently-running **Workers**
communicating over named **Channels**. It runs / steps / pauses / resumes through the shared
`ServerLogicController` like a Script or Flow. Strategic intent: **Job becomes the eventual SUPERSET of Report**
(reader → filter → pivot → writer as a user-composable, interactive, parallel graph); Report is removed once
parity lands.

Core types (all present):
- SPI (kzen-auto-common `paradigm/job/`): `Worker`, `ChannelInput`/`ChannelOutput` (one-way),
  `ChannelClient`/`ChannelServer` (duplex), `JobControl`, `JobLogicHost`.
- JVM runtime (kzen-auto-jvm `server/objects/job/`): `JobDocument` (the `Logic`), `JobExecution` (the run
  driver), `WorkerSupervisor` + `CountingDispatcher` (the concurrency + quiescence barrier), `JobControlImpl`,
  `JobChannelCreator` (wires channel-typed worker attributes to shared channel instances),
  `channel/{JobChannel,DuplexJobChannel}`.
- Notation: `auto-jvm/job/{job-jvm,job-worker}.yaml`, `auto-js/document/job-js.yaml`,
  common `common-document.yaml` / `common-job.yaml`.

## The five goals (the rubric every phase serves)

1. **Ergonomic & safe concurrency** — hard to write a deadlocking / unpausable worker.
2. **Performance headroom** — batching, allocation control, parallel execution.
3. **Do what Report does, and more, dynamically** — composable stages in an arbitrary DAG.
4. **Type safety**, incl. user-defined / dynamically-discovered element types.
5. **Interactive execution** — live progress (push) and on-demand state queries (pull) while running.

## Target design (direction; built incrementally)

A worker expresses its LOGIC as execution-strategy-independent lifecycle hooks (`onStart`≈init,
`onBatch`/`onComplete`≈work, `onClose`≈close — mirroring the user's `AsyncWorker` reference), so the same
worker can run framework-driven or self-managed, have its state migrated, and host a nested Logic.

- **Execution model.** Framework-driven (default): one coroutine per worker on the `CountingDispatcher` →
  pipeline parallelism; pause/cancel via `JobControl.checkpoint`; quiescence via dispatcher inFlight; blocking
  work via `runBlockingIo`. Self-managed (future option): a worker owns its thread(s)/pool (Guava-Service
  style) exposing an observable lifecycle. **`suspend` is NOT part of the worker-logic contract** — any JVM
  concurrency tech is acceptable.
- **Invariants (every strategy):** (1) single-reader — each channel drained by ≤1 consumer (fan-out explicit);
  (2) inputs only via channel or `JobControl` (no hidden side inputs → state capture/migration sound);
  (3) cooperative pause/cancel.
- **Typed channels** — each `Channel` declares an `elementType` (`TypeMetadata`); wiring validated at
  **definition time** and surfaced through the existing `DefinitionErrors` panel (pre-run, not a runtime cast
  crash).
- **Uniform interactivity** — progress-push and query-pull read ONE framework-published immutable snapshot; no
  worker hand-rolls `@Volatile` sharing.
- **Nested Logic** — a worker may invoke another Logic per event (`RunWorker`), each child isolated.
- **State migration** — pause → edit config → continue, via Script's identity-continuity mechanism
  (`ObjectStableId` + `StatefulLogicElement.loadState`).
- **Report parity** — pivot/sort/summary as stateful operators (`onBatch` accumulate, `onComplete` emit)
  reusing Report's on-disk builders (`PivotBuilder`, `ReportSummary`).

---

## Status at a glance

| Phase | Topic | State | Tests |
|---|---|---|---|
| Foundation | core engine + 5 real workers + duplex/external bridge + minimal+authoring UI | ✅ done | `JobExecutionTest` (14) |
| Phase 0 | operator base (`WorkerBase` + Source/Transform/Sink + `Emitter`) | ✅ done 2026-06-24 | `JobExecutionTest`, no edits |
| **P1** | **typed channels** (`elementType` + `ChannelTypeDefiner`) | ✅ done 2026-06-24 | `JobChannelTypingTest` (3) |
| **P2** | **nested Logic** (`JobLogicHost` + `RunWorker`) | ✅ done 2026-06-24; step-control unified per-spine 2026-06-25 | `JobNestedLogicTest` (6), `StepNavigationTest` |
| **P3** | **state migration** (pause → edit config → continue); lossless channel carryover | ✅ done 2026-06-25 | `JobStateMigrationTest` (2), `JobMigrationCarryoverTest`, `JobChannelTest` |
| P4 | Report parity as composable Workers (pivot/summary/sort/value-set-filter/export/explore/multi-input) — see P4 sub-plan below | 🔄 in progress | P4-0 batching ✅ (`JobBatchingTest`), P4a scratch dir ✅ (`JobScratchDirTest`), P4b summary ✅ (`SummaryWorkerTest`), P4c value-set filter ✅ (`ValueSetFilterWorkerTest`), P4d pivot ✅ (`PivotWorkerTest`), P4e sort ✅ (`SortWorkerTest`), P4f export ✅ (`ExportWriterWorkerTest`), P4g explore ✅ (`ExploreWorkerTest`), P4h multi-file ✅ (`MultiFileReaderWorkerTest`), P4i editors 🔄 (SortSpecEditor ✅, ExportSpecEditor ✅) |
| P5 | performance (record pooling, self-managed workers) | ⬜ todo | — |
| P6 | interactivity hardening (idle-server vs deadlock) | ⬜ todo | — |
| — | P2 follow-ups (scalar source/sink, JS editor; frame-tree/trace ✅ 2026-06-26) | ⬜ backlog | — |

Each phase is independently shippable and keeps the prior tests green.

---

## Completed (details)

### Foundation (M1–M2 era + strip-to-real-engine, 2026-06-23 → 2026-06-24)

Core engine, five real workers, duplex channels + browser↔worker bridge, and a minimal + authoring UI.
- **Engine:** `JobExecution` drives Workers running full-speed on the `CountingDispatcher`; `inFlight == 0` is
  the quiescent wavefront powering pause-barrier / global-tick step / deadlock detection (no controller change;
  execution runs off the `@Synchronized` monitor, poll-only pause/cancel). `SupervisorJob` = fail-at-end.
- **Real workers** (`server/objects/job/worker/`): `CsvReaderWorker` (streaming RFC-4180 `CsvRecordReader`,
  headerless → synth `c0,c1,…`), `FilterWorker` (Kotlin `where` expression via the genuine
  `CalculatedColumnEval` `@Service`), `FormulaWorker` (appends calculated columns, same engine), `CsvWriterWorker`
  (delimiter-aware RFC-4180), `PreviewWorker` (live-sample sink + duplex slice-query server). Element unit =
  `RecordBatch(header: HeaderListing, records: List<FlatFileRecord>)` (freshly-allocated, ownership-transferred
  across channels — a reused mutable slot can't cross a channel).
- **Duplex + external bridge:** `DuplexJobChannel` (per-request `CompletableDeferred` → concurrent correlation);
  `external: true` channels bridged to `ExecutionRequest`/`Result` via `JobExecution.route` +
  `subscribeRequest`. Live progress pushed via `JobControl.publishProgress` on a FIXED-convention trace path
  (`JobConventions.workerProgressPath` — a `$stable` child path gets dropped by the store's id-resolution
  filter).
- **UI:** `JobController` (kzen-auto-js) renders worker/channel cards with live counts + a preview teaser table
  + per-channel duplex query control; ribbon palette inserts workers/channels; per-attribute editors incl.
  `SelectChannelEditor`. Throughput verdict: at 4M rows the batched-channel Job matches a single-thread inline
  baseline within ~2.5%.

Key learnings retained: `@Reflect` workers must live in `src/main` (KSP is main-only); never add `title:` to the
`Channel`/`DuplexChannel` archetypes (no `is:` parent → fails to define → drops every channel); palette workers
need empty-string body defaults for channel-ref attrs.

### Phase 0 — operator base (2026-06-24, behaviour-preserving)

Inverted control INSIDE the SPI so the framework owns the run loop, EOF `output.close()`, per-batch
`checkpoint`, throttled progress, and the duplex serve loop — the boilerplate every raw worker hand-rolled and
could silently get wrong. New files (kzen-auto-**jvm** `…/job/worker/`, NOT common — common has no
kotlinx-coroutines dep): `WorkerBase`, `SourceWorker<Out>`, `TransformWorker<In,Out>`, `SinkWorker<In>`,
`Emitter<T>`. The base `IS-A Worker`, so `JobExecution`/`WorkerSupervisor`/`JobChannelCreator`/notation are
unchanged. Interactivity unified on one hook set — `snapshot()` + `progress(snapshot)` + `onQuery(request,
snapshot)` — so `PreviewWorker`'s `@Volatile` triple + hand-rolled serve loop are gone, and the five per-worker
`item as T` casts collapse to ONE in the base (the spot P1 makes provably safe). Raw `Worker` SPI stays
first-class (opt-out for self-managed / nested-logic / perf workers). `JobExecutionTest` green, no edits.

### P1 — typed channels (2026-06-24)

A `Channel` declares the type it carries; miswiring is caught at **definition time** and surfaced in the UI.
- **`ChannelTypeDefiner`** (kzen-auto-common `objects/document/job`) bound to the one-way `Channel`'s
  `elementType` via `by: ChannelTypeDefiner`. Parses the declared type (scalar ref → object's `class`; inline
  `{class,generics,nullable}` map via `TypeMetadataDefiner.parse`; blank → `Any`/untyped), then scans every
  port referencing the channel and validates **type compat** (structural `TypeMetadata` equality; `Any` is a
  bidirectional wildcard so an untyped channel/port skips the check) + **single-reader** (≤1 consumer). Reads
  only notation+metadata → no instance-ordering dependency.
- Refined the plan's "definer on the port" → one definer on the **channel** (the port keeps its
  `StructuralAttributeDefiner` + `JobChannelCreator` pipeline untouched; the channel is the natural owner of
  "what flows + who's wired").
- Failure flows the EXISTING path: `AttributeDefinitionFailure` → `attributeErrors[elementType]` →
  `GraphDefinitionAttempt.failures` → `DefinitionErrors` → `StageController`.
- Notation: `Channel` got `elementType: ""` + meta; new `RecordBatch` type-only archetype; `of: RecordBatch` on
  every one-way port in `job-worker.yaml`; `notation/main/Job.yaml` raw+kept typed `RecordBatch`.
- **Wire element type is `RecordBatch`, not bare `FlatFileRecord`** — the `HeaderListing` must travel with its
  rows. This makes the base's one `item as In` cast provably safe.
- Tests: `JobChannelTypingTest` 3/3 (`typedChannelPipelineRuns`, `producerTypeMismatchFailsDefinition`,
  `multipleConsumersFailDefinition`); `JobExecutionTest` green, no edits.

### P2 — nested Logic (`RunWorker`) (2026-06-24)

A worker can invoke another Logic (Script/Flow/Job) as a child, once per event — the Job analogue of Script's
Run step. **The flagged concurrency risk is resolved by confinement.**

THE PROBLEM (confirmed by reading `ServerLogicController` / `LogicExecutionFacadeImpl` / `MutableLogicControl`):
a top-level Script/Flow drives its child frames on the SINGLE controller executor thread, sharing ONE
`MutableLogicControl` whose stepping state (`frameDepth`, step budget, step-out target — maintained by
`enterFrame`/`exitFrame`) is a single linear call-spine. A Job runs its Workers concurrently, so N workers each
driving a child through the existing `LogicHandle` (hard-wired to that shared control) would corrupt those
counters and entangle the Job's coarse pause/cancel with Script's per-step pause.

THE RESOLUTION = **confinement, not shared-state locking.** Each child runs full-speed on its OWN fresh
`MutableLogicControl` + `MutableLogicResourceScope`, sharing only the stateless `GraphCreator` (an `object`,
pure function of immutable inputs → safe to call concurrently) and the immutable `graphDefinition`. Concurrent
children are fully isolated → real parallelism, no corruption, and the Job-vs-Script pause mismatch never
arises.

Files:
- **`JobLogicHost`** (common `paradigm/job/api`): `fun run(child: ObjectLocation, input: Any?): LogicResult` —
  runs a child to completion, `input` → child's first declared param, returns its terminal result. Blocking;
  call inside `runBlockingIo`.
- **`JobControl.logicHost(): JobLogicHost`** — the run-scoped seam; most workers never call it.
- **`JobLogicHostImpl`** (jvm `objects/job`): builds the child on a private control, drives `continueOrStart` to
  terminal; tracks live child controls (`ConcurrentHashMap.newKeySet`); `cancelAll()` flips them to Cancel at
  teardown. P2 scope: child NOT in the sidebar frame tree, internal trace dropped (`NoOpLogicTraceHandle`), and
  a child may not itself start a further nested Logic (`NestedLogicUnsupported` throws).
- **`RunWorker`** (jvm `objects/job/worker`, `@Reflect`): `TransformWorker<Any?, Any?>` (element-agnostic,
  untyped channels); per element calls `control.runBlockingIo { control.logicHost().run(instructions, element) }`
  and emits `result.value.mainComponentValue()`; Cancelled→`CancellationException`, Failed→throw. Notation in
  `job-worker.yaml` (`instructions` is `is:ObjectLocation, by:Nominal, editor:SelectLogicEditor`).
- **Wiring:** `JobExecution` gained a `logicRunExecutionId` ctor param (threaded from `JobDocument.execute`),
  builds the host from the LIVE full `graphDefinition` in `launchWorkers`, and `cancelAll()`s it FIRST in
  `tearDown` (a worker blocked in synchronous `host.run` won't see the coroutine cancel until the child
  returns).
- **Relied-on semantics:** `MultiStep` returns the LAST step's value as a Script's main result;
  `StepExpressionCompiler.generateImports` emits `import <FQN>` per param type, so a child `FormulaStep` over an
  app-class param (`RecordBatch`) compiles.
- Tests: `JobNestedLogicTest` 3/3 — `concurrentChildrenRunIsolated` (8 threads × 8 = 64 concurrent child runs,
  every result == input×10), `cancelAllShortCircuitsSubsequentChildren`, `runWorkerExecutesChildPerBatchInJob`
  (end-to-end reader→RunWorker→writer through real `JobExecution → JobControlImpl.logicHost()`). The end-to-end
  test passes the UNFILTERED `transitiveSuccessful` definition (mirrors production `ServerLogicController`) so
  the host resolves the child's document. `JobChannelTypingTest` + `JobExecutionTest` green, no edits.
- **Test trap de-risked:** `CachedKotlinCompiler` is a filesystem cache keyed by code signature; concurrent
  COLD compiles of the same code race (it had only ever been hit from the single controller thread). The
  concurrency test WARMS the cache (one sequential run) before the burst, so it exercises the host's
  confinement, not the orthogonal compiler cold-start.

### P3 — state migration (pause → edit config → continue) (2026-06-25)

Editing a Job's config while paused now takes effect on resume. The driver (`ServerLogicController`) already
re-reads the live (possibly edited) notation each tick and passes it as the run's `graphDefinition` — Script
relies on the same — so `JobExecution` only had to act on a change. It now compares the incoming filtered
definition's `objectDefinitions` against the one the live Workers were built from; on a change it **rebuilds**.

THE CONSTRAINT that shaped the design: a Job's Workers are LIVE parked coroutines (not re-instantiated per tick
like a Script step), so they can't be re-pointed at new config in place. Migration is therefore all-or-nothing —
`migrate()` snapshots each Worker's state WHILE IT IS STILL PARKED (so a live handle can be detached before it's
closed), tears the old graph down (cancel + join → channels closed), then `buildAndLaunch`es from the edit with
the snapshots in hand. Identity-continuity mirrors `ScriptExecution`: each rebuilt Worker is keyed by
`ObjectStableId` (survives renames) and adopts the snapshot the previous instance captured. A Worker that
doesn't opt in restarts from scratch with the new config (the safe default — coherent for a sink that
re-truncates).

The capture-before-teardown seam (NOT a post-join `loadState`) is what lets `CsvReaderWorker` carry its **open
file reader** across the edit and continue from its position — a post-join read would see a reader the teardown
had already closed.

Files:
- **`WorkerBase`** gained the opt-in seam `captureMigrationState(): Any?` (default null) / `loadMigrationState`
  (default no-op), `internal` (the framework, not subclasses, calls them). `captureMigrationState` runs on the
  OUTGOING instance while parked & before teardown, so it can DETACH a live resource (so `onClose` skips it). If
  the captured state is `AutoCloseable`, `JobExecution` closes it when its Worker was REMOVED by the edit (orphan
  sweep) so a detached handle can't leak.
- **`PreviewWorker`** opts in (the user-nominated accumulator testbed): capture = an immutable `Snapshot`
  (header + window copy + count); load restores it, so the live view keeps its sample across an edit.
- **`CsvReaderWorker`** opts in to **resume from its file position**, gated on `path`/`delimiter`/`header`: the
  loop's `checkpoint` moved to the TOP of the batch (a parked reader holds no built-but-unsent batch); the open
  reader + position + a `pendingBatch` (the one batch handed to a parked `send`) + an EOF `finished` marker are
  hoisted to fields; `captureMigrationState` detaches the reader, `loadMigrationState` re-adopts it iff config
  matches (else closes it and re-opens fresh). Reading continues from where it left off instead of reopening +
  re-reading the whole file. (Plus a **TODO** to surface resumption status — resumed-from-row-N vs. restarted —
  on the worker's progress trace for the UI.)
- **`JobExecution`**: `launchWorkers` → `buildAndLaunch(full, filtered, capturedStates, initiallyPaused)`; added
  `migrate()` (capture → teardown → rebuild), the change-detection branch in `continueOrStart`, the orphan
  sweep, and the `launchDefinition` / `workersByStableId` fields. `initiallyPaused` parks freshly-rebuilt
  Workers at their first checkpoint on a step/pause tick so a step-after-edit stays bounded (a full resume lets
  them run).
- Notation: `test/job-migration-preview-test.yaml` (reader `batch: 2` → Preview over a non-external duplex
  serve channel — small batch so a couple of step wavefronts leave the Preview partially filled yet far from
  done).
- Tests (`JobStateMigrationTest`, 2): (a) `editingConfigWhilePausedRebuildsAndMigratesWorkerState` — pause, step
  until the Preview's count first turns > 0 (first progress publish is unthrottled, so the trace count is exact
  then), resume against a definition whose reader path is edited to an empty file → the run completes with the
  CARRIED count + header (0 / empty without migration); also asserts two independent builds of the same notation
  are `objectDefinitions`-equal (no spurious rebuild on a no-edit resume). (b)
  `editingNonReaderConfigResumesReaderFromItsPosition` — edit the Preview's `sample` (reader config UNCHANGED) →
  the reader resumes, so the Preview counts each row at most once and the final total is `<= file rows`; a
  restart would re-read the file on top of the carried count and exceed it. `JobExecutionTest` (incl. the
  reader's restructured loop) / `JobChannelTypingTest` / `JobNestedLogicTest` green, no edits.

**Known limitation (documented in `CsvReaderWorker`):** reader → preview is now exact (reader resumes from
position, preview accumulates), but a batch already BUFFERED in the channel at the cut is still lost on teardown
— the reader carries only its own in-flight `pendingBatch`, not channel contents. So it's best-effort, exact
only for a rendezvous (buffer-0) channel; a buffered channel drops up to ~buffer batches at the cut. Closing
that gap needs consumer-side coordination (a checkpoint before `receive`, so a consumer holds no received-but-
unprocessed item) — a cross-Worker snapshot, deferred. Also: carrying a source forward is only COHERENT with a
downstream that accumulates/appends; a `CsvWriterWorker` re-truncates on rebuild, so a reader→writer edit-resume
would drop the rows written before the cut (the writer needs its own append/seek carry — future work).

---

## Remaining — next steps

> Maintain this section as the forward backlog. Pick a phase per the goal it serves; each is independently
> shippable and must keep all prior tests green.

### P2 follow-ups (deferred, opt-in by value)

- ~~**Frame-tree + step integration / child trace visibility.**~~ ✅ done (frame mirroring + real trace handle
  landed with the 2026-06-25 step-control unification; the trace LIFECYCLE was fixed 2026-06-26 — see the
  frame-owned trace decision-log entry). A child is now first-class in the sidebar frame tree (per-invocation
  frame via `NestedFrameRegistry`), its steps are recorded under the Job run, re-entry shows a cleared trace,
  and parallel callers no longer interleave.
- **Grandchild nesting.** A child Logic that itself starts a further nested Logic currently throws
  (`NestedLogicUnsupported`). Lift by threading a confining `LogicHandle` into the child that recurses through
  the same per-child-control creation (so grandchildren stay confined too).
- **Scalar source/sink workers.** The only real source/sink are CSV (RecordBatch), so a non-RecordBatch
  `RunWorker` Job isn't demoable end-to-end. Add a small source (emits configured/generated scalar events) and a
  collecting sink so event-lane Jobs (and richer `RunWorker` tests) work without the RecordBatch lane.
- **JS editor for `instructions`.** `RunWorker.instructions` is notation-only today; `SelectLogicEditor` exists
  (used by RunStep/RunLogicVertex) — wire it into the Job worker card and add `RunWorker` to the ribbon palette.
- **Per-event graph-build cost.** `JobLogicHostImpl.run` builds a child graph per call — fine for correctness,
  bad for hot loops. Cache the child graph/execution per `(worker, child)` with per-child-control reuse, or
  pool. Belongs with P5.

### P3 follow-up — close the at-the-cut gaps (deferred from P3)

P3 (done, see Completed) ships the rebuild + capture/load mechanism, reader resume-from-position, AND
(2026-06-25) **lossless channel carryover** — buffered + parked-mid-send batches are now snapshotted before
teardown and re-seeded into the rebuilt channel (`JobChannel.drainBuffered`/`preload`, consumer `checkpoint`
moved before receive), so a mid-stream migration is exact, not best-effort. Remaining gaps:
- **Truncating-sink carry-forward.** A source resuming is only coherent with a downstream that accumulates/
  appends; `CsvWriterWorker` re-truncates on rebuild, so a reader→writer edit-resume drops rows written before
  the cut. Give the writer its own append/seek capture (opt-in, like the reader) so the output continues rather
  than restarts.
- **UI resumption status** (the TODO in `CsvReaderWorker.loadMigrationState`): surface resumed-from-row-N vs.
  restarted on the worker's progress trace so the user sees whether an edit preserved progress.
- Composes with the P2 follow-up (a cached paused child) once that lands. Likely sequenced with P5.

### P4 — Report parity (the point of the paradigm)

Replicate Report's ENTIRE capability set inside Job as **dynamically user-composable Workers** (an arbitrary
graph, not Report's fixed `input→formula→filter→analysis→output` pipeline), reusing Report's substrate-neutral
leaf engines (`PivotBuilder` / `ValueSummaryBuilder` / `IndexedCsvTable` / the export writer / the filter
predicate — infra, not Report "stages", and survive Report removal). Full build order + design in the P4 sub-plan
`C:\Users\ostro\.claude\plans\i-want-to-replicate-bright-sedgewick.md` (`P4-0 → P4a … → P4j`).

Progress:
- **P4-0 — framework batching (foundational) ✅ 2026-07-01.** Batching is now a general, domain-agnostic
  Channel-framework capability (generic over element `T`): Workers `send`/`receive` single ELEMENTS, the
  framework groups them into physical chunks of the channel's configurable `chunk` size. Replaces the
  `RecordBatch` hack (deleted) with a self-describing `DataRecord(header, record)`; scalar/Run lanes now batch
  too. Element-wise Source/Transform/Sink hooks; flush-before-checkpoint keeps migration carryover lossless.
  `JobBatchingTest`; whole Job + `kzen-auto-jvm` suite green.
- **P4a — scratch dir + `JobWorkPool` ✅ 2026-07-01.** `JobControl.scratchDir()` (platform-neutral `String`);
  new `JobWorkPool` `@Service` owning `<work>/job/<run-digest>/<worker-digest>` dirs (keyed on migrate-stable
  run id + Worker stable id; boot-time stale sweep). Threaded via `LogicCompilerServices` → `EngineJobControl`
  (lazy create-on-first-call); `JobRun` registers a run-root `ClosePolicy.Auto` sweep. Unblocks the file-backed
  Pivot / Explore operators. `JobScratchDirTest` (two Workers get isolated dirs, swept when the run settles).
- **P4b — `SummaryWorker` (+ optional `serve` on `TransformWorker`) ✅ 2026-07-01.** A passthrough
  `TransformWorker<DataRecord, DataRecord>` that computes a live per-column `TableSummary` (reusing Report's
  `ValueSummaryBuilder` + `RecordHeaderIndex`, bounded memory / no scratch dir) while forwarding each record
  unchanged, so it composes into any pipeline. Serves the `TableSummary` over a duplex `serve` port + pushes a
  row count; carries its builders across a live edit (like `PreviewWorker`). Framework change: `TransformWorker`
  gained an optional `serve` port (behaviour-preserving — `Filter`/`Formula`/`Run` pass none). `SummaryWorkerTest`.
- **P4c — `ValueSetFilterWorker` ✅ 2026-07-01.** A `TransformWorker<DataRecord, DataRecord>` that drops records
  failing a distinct-value WHITELIST (Report's value-set filter, not the Kotlin-expression predicate `FilterWorker`
  runs). Reuses `ReportFilterStage`'s exact `test` — `RecordHeaderIndex` column mapping, standalone
  `FlatFileRecordField` value sets, `ColumnFilterType` RequireAny/ExcludeAll — over `FilterSpec`/`ColumnFilterSpec`
  (commonMain); no serve, no scratch dir. Only adaptation: the schema is discovered in-band from each record's
  header (active columns rebuilt on header change, like `FilterWorker` recompiles), and a filter on a column absent
  from the header is ignored (as Report drops filter columns not in its static schema). `filter` attr wired via the
  existing `FilterSpec.Definer`; `editor: ValueSetFilterEditor` named for P4i (not yet registered — degrades to a
  placeholder). `ValueSetFilterWorkerTest` pins the predicate parity (whitelist/blacklist/AND/absent-column/empty/
  header-change); full Report-vs-Job byte parity is the P4j gate.
- **P4d — `PivotWorker` ✅ 2026-07-01.** A `TransformWorker<DataRecord, DataRecord>` (serve + scratch dir) that
  accumulates every record into Report's reused `PivotBuilder` (H2-backed, over a per-Worker `JobControl.scratchDir`)
  and, at end-of-stream, emits the built pivot table downstream row-by-row under a stable output header (row-key
  columns + one column per value/type), so it composes into any pipeline. Serves live `offset`/`limit` preview
  slices against the disk-backed builder — race-free because a Worker is single-threaded on its own node coroutine
  (the serve loop only runs while the work coroutine is parked). `onClose` does close-then-delete (H2 holds a
  Windows file lock); the `JobRun` run-root sweep is the backstop. Live-edit = RESTART (WorkerBase default;
  coherent since the scratch path is deterministic per migrate-stable `(runId, stableId)`). New commonMain seam:
  `PivotSpec.Definer` + `PivotSpec`/`PivotSpecDefiner` archetypes, so the worker carries a raw `pivot: PivotSpec`
  attribute (not the Report document's `analysis.pivot` nesting); `editor: PivotSpecEditor` named for P4i.
  `PivotWorkerTest` A/B-checks the emitted pivot against a direct `PivotBuilder` and asserts the scratch dir is
  swept after the run.
- **P4e — `SortWorker` ✅ 2026-07-02.** A `TransformWorker<DataRecord, DataRecord>` (no serve, no scratch dir)
  that buffers every record and, at end-of-stream, emits them re-ordered by a new commonMain `SortSpec` — an
  ORDERED map `column -> ascending` (map order = sort priority, first key primary). Comparison is a provable TOTAL
  order (so the stable sort never trips a comparator-contract violation on adversarial data): per key, both-numeric
  → numeric (via the same `FlatFileRecordField.toDoubleOrNan` the pivot/summary use, so `"1"`==`"1.0"`), numeric
  sorts BEFORE non-numeric text, both-text → lexical; ties keep arrival order (`sortedWith` is stable). In-memory
  v1 — buffers the whole stream, emits it as one flushed chunk (no mid-`onComplete` checkpoint, so the drain is
  atomic w.r.t. a cooperative pause → no double-emit); disk-spill external merge + streamed back-pressured drain is
  the documented follow-up. Live-edit CARRYOVER is UNCONDITIONAL and REQUIRED (not the WorkerBase restart default):
  an unchanged upstream `CsvReaderWorker` RESUMES from its file position, so a SortWorker that restarted empty would
  silently drop pre-pause rows — `captureMigrationState`/`loadMigrationState` carry the accumulated buffer (pure
  data, no handle, like `SummaryWorker`'s builders) and the buffer is cleared after emit so a post-completion
  rebuild re-emits nothing. New commonMain seam: `SortSpec` + `SortColumnSpec` + `SortSpec.Definer` (uses
  `firstAttribute`, not `mergeAttribute`, to preserve authored key order) + `SortSpec`/`SortSpecDefiner` archetypes;
  `editor: SortSpecEditor` named for P4i. `SortWorkerTest` covers single/multi-key asc/desc, numeric-before-text +
  stability, empty-spec passthrough, and the carryover (mid-stream interrupt → capture → rebuilt instance re-sorts
  the FULL stream).
- **P4f — `ExportWriterWorker` ✅ 2026-07-02.** A `SinkWorker<DataRecord>` (no serve, no scratch dir) that writes
  the stream to a delimited file with Report's EXACT export encoding, so a Job export is byte-identical to
  Report's (the P4j A/B gate reduces to path/plumbing). Reuses Report's leaf engines — the `RecordFormat`
  (`CsvExportFormatter` / `TsvExportFormatter`), an in-place UTF-8 encode mirroring `CharsetExportEncoder`, and
  the compression writer — but NOT the disruptor. **Refactor first (as the plan directs):** extracted
  `CompressedExportWriter.openGroup`'s none/zip/gz selection into a shared `ExportCompression.wrap(rawOut, spec,
  innerName): WrappedExportOutput` (out + finalizing closer); `CompressedExportWriter` now calls it (behaviour-
  preserving — full suite green) and the worker calls the same seam, so both compress identically. Header written
  once from the first record via `render` (matching `ExportFormatter`). Config `export: OutputExportSpec` via a
  new standalone `OutputExportSpec.Definer` (mirrors `PivotSpec.Definer`; `mergeAttribute` so an instance
  overriding one key inherits archetype defaults) + `OutputExportSpec`/`OutputExportSpecDefiner` archetypes; path
  resolved by Report's own `resolvePath(docName, group=empty, now)` (`${report}` = the worker's own document
  name, `${group}` empty for the single stream). File opened in `onStart`, container finalized in `onClose`,
  writes through `runBlockingIo`. Live edit RESTARTS / re-truncates (the WorkerBase sink default, like
  `CsvWriterWorker` — a compressed stream can't be appended mid-file; a resumable export is a follow-up).
  `editor: ExportSpecEditor` named for P4i. `ExportWriterWorkerTest` round-trips csv-none / csv-zip / csv-gz
  (comma + embedded-quote fields, decompressed and re-parsed with `CsvRecordReader`) + a tsv case.
- **P4g — `ExploreWorker` ✅ 2026-07-02.** A `SinkWorker<DataRecord>` + `serve` + scratch dir — the disk-backed,
  random-access browse over the whole result stream (the Job analogue of Report's Explore output, the heavy-duty
  counterpart to `PreviewWorker`'s bounded in-memory live tail). Reuses Report's `IndexedCsvTable` leaf engine (a
  CSV file + row-offset index; NOT the disruptor): every record is appended in `onElement`, and the browser reads
  ANY window via on-demand `offset`/`limit` slice queries answered from the LIVE table in `onQuery`. Input is
  typed `DataRecord` (the table indexes by header + fields; a schemaless scalar lane has no columns to browse).
  **No config spec** — the plan's worker table lists none and the P4i editor list omits an explore editor; the
  slice is entirely query-driven (default limit 1000), so the worker carries just `input` + `serve` +
  `selfLocation`. The header is only known at the first record, so the table is created lazily on the first
  `onElement` (its ctor writes the header row) — an empty stream leaves no table and serves an empty preview.
  Scratch dir like `PivotWorker`: opened under `JobControl.scratchDir()`, `onClose` does CLOSE-THEN-DELETE
  (`close(error = true)` skips the flush-before-delete — the run-scoped scratch is never read after settle);
  `JobRun`'s run-root sweep backstops a hard kill. Reading the disk-backed table from the serve coroutine is
  race-free by the single-threaded-Worker guarantee (`onQuery` runs only while the work coroutine is parked), and
  `IndexedCsvTable` interleaves append + random-access read on one handle by design (`preview` flushes pending,
  then seeks). Live edit RESTARTS (the WorkerBase default — re-indexes from a resuming upstream reader into a
  fresh table at the deterministic `(runId, stableId)` path). Because a sink emits nothing, `ExploreWorkerTest`
  can't A/B on output like `PivotWorkerTest` — it drives the REAL `WorkerBase` serve loop: one `offset`/`limit`
  request is fed through, coordinated by two `CompletableDeferred`s (single-threaded `runBlocking` event loop) so
  it lands after every record is indexed and before the run settles, and asserts the served `ExecutionResult`
  equals a direct `IndexedCsvTable.preview` over the same slice (+ row-count on the trace, + scratch swept).
  **Deferred:** the detached DOWNLOAD endpoint (streaming `IndexedCsvTable.downloadCsvOffline` / the Job analogue
  of Report's `DetachedDownloadAction`) is REST/controller/client work — folded into P4i with the serve plumbing,
  matching how P4b–P4f deferred all client wiring. No `editor:` (no config to edit).
- **P4h — `MultiFileReaderWorker` ✅ 2026-07-02.** A `SourceWorker<DataRecord>` — the multi-file generalization of
  `CsvReaderWorker` (same `CsvRecordReader`, same RFC-4180 parsing), the Job analogue of Report's multi-location
  input. Reads several files as ONE stream, records concatenated in `paths` order. Schema taken from the FIRST
  file: with `header=true` each subsequent file's header row is skipped and its data emitted under the shared
  `HeaderListing`; with `header=false` the schema is synthesized positionally (`c0, c1, …` from the first file's
  first record) and every row is data. **Config is flat** (matching `CsvReaderWorker`): `paths: {is: List, of:
  String}` (bound directly to a `List<String>` ctor param by the default `StructuralAttributeDefiner` — no custom
  definer; `defineList` handles the `String` generic) + `delimiter` + `header`. Directory browse / glob discovery
  is the EDITOR's job (P4i `MultiFileInputEditor`, reusing `FileListingAction`) — the worker consumes the
  resolved, ordered concrete-path list, keeping the resume cursor deterministic (the file set is fixed config,
  not re-globbed mid-run). `editor: MultiFileInputEditor` named for P4i. **Migration cursor = `(fileIndex,
  open-reader-position)`:** only one reader is open at a time; `captureMigrationState` detaches it + carries
  `fileIndex`, `loadMigrationState` re-adopts both iff `paths`/`delimiter`/`header` unchanged (else closes the
  carried reader and restarts) — so a pause/edit/continue resumes from the exact spot in the current file and
  reads the remaining files, like `CsvReaderWorker`'s single-reader carryover extended across the file list.
  `MultiFileReaderWorkerTest` covers header=true concatenation (subsequent headers skipped), header=false
  synthesized schema, and the cursor: a first instance parks mid-`fileA` (checkpoint-park via a `CompletableDeferred`
  on a single-threaded `runBlocking` loop, faithfully replicating `JobExecution`'s capture-while-parked → detach →
  teardown → load protocol), hands its cursor to a second instance that finishes `fileA`, crosses into `fileB`
  (re-skipping its header), and reconstructs the uninterrupted output exactly (no loss / duplication).
- **P4i — JS editors + palette 🔄 (in progress, one editor at a time).** Picks up the deferred client wiring
  accumulated across P4b–P4h: the five config editors (`PivotSpecEditor` / `ValueSetFilterEditor` /
  `SortSpecEditor` / `ExportSpecEditor` / `MultiFileInputEditor`), ribbon palette tools for every new worker,
  `JobController` `summaryDetail`/schema threading, and the Explore **detached download** endpoint (streaming
  `IndexedCsvTable.downloadCsvOffline`, the Job analogue of Report's `DetachedDownloadAction`).
    - **`SortSpecEditor` ✅ 2026-07-02.** Edits a `SortWorker`'s `sort` (a `SortSpec` — an ordered `column ->
      ascending` map, insertion order = multi-key priority) as add / remove / direction-toggle rows, following the
      `FormulaMapEditor` observe-`MirroredGraphStore` → read-notation → apply-canonical-command shape. Added the
      canonical command builders to `SortSpec`'s companion (`addCommand` / `removeCommand` /
      `updateAscendingCommand`, mirroring `FilterSpec` / `FormulaSpec` — map key = `HeaderLabel.asString()`,
      value = `"true"`/`"false"`) so the editor hand-rolls no notation commands; reads back via `SortSpec.ofNotation`.
      Rows are **stateless** (a direction toggle commits immediately — no debounced text like `FormulaMapRow`), so
      rows + the add-form are inlined in one self-contained file (no pointless sub-components). Columns are added
      by **free-text name** (new key = ascending, appended at lowest priority) — the documented fallback until
      upstream-schema threading lands, matching the value-set filter's degrade. Registered as a `Wrapper is:
      AttributeEditor` in `job-js.yaml` (the `editor: SortSpecEditor` binding on the archetype already existed) +
      a `SortTool` ribbon tool under `JobGroup_Transforms`. Re-prioritizing an existing key
      (`ShiftInAttributeCommand` move) is a documented follow-up; for now priority is add-order. Verified:
      `:kzen-auto-js:compileKotlinJs` green + `:kzen-auto-jvm:test --tests "*Job*Test"` green (rebuilds the
      production JS bundle, so the editor compile is gated). **No unit test** — pure JS UI, covered transitively.
    - **`ExportSpecEditor` ✅ 2026-07-02.** Edits an `ExportWriterWorker`'s `export` (an `OutputExportSpec` —
      format / compression / path-pattern, carried as a top-level map, not Report's nested `output.export`) as a
      **thin composition of the SAME reusable field editors** Report's `OutputExportController` uses — two
      `SelectAttributeEditor` dropdowns (format csv/tsv, compression none/zip/gz) + a debounced
      `TextAttributeEditor` (path) — pointed at Job-relative `export.*` paths (new `standalone*AttributePath`
      constants on `OutputExportSpec`). No new command builders: each sub-editor applies its own
      `CommonEditUtils.editCommand`. **Key correctness finding:** that's an `UpdateInAttributeCommand` on a nested
      key, and `NotationReducer.updateInAttribute` first *coalesces the merged (archetype-default) `export` map
      into the instance notation* (`mergeAttribute` → `upsertAttribute`) before the nested write — so editing one
      field works even on a freshly palette-inserted worker whose body is only `is: ExportWriterWorker`
      (AddObjectCommand.ofParent — `export` inherited-only). The editor observes `MirroredGraphStore` and feeds the
      resolved spec (read via `mergeAttribute` + `OutputExportSpec.ofNotation`) down as values. Registered as a
      `Wrapper is: AttributeEditor` in `job-js.yaml` (the `editor: ExportSpecEditor` binding already existed) + an
      `ExportTool` ribbon tool under `JobGroup_Sinks`. Verified: `:kzen-auto-js:compileKotlinJs` +
      `:kzen-auto-jvm:test --tests "*Job*Test"` green. **No unit test** — pure JS UI, covered transitively.
    - `PivotSpecEditor` / `ValueSetFilterEditor` / `MultiFileInputEditor` — todo.
- **P4j — todo.** A/B parity + Report removal (the original M5, once parity holds).

### P5 — performance

- Record pooling: `FlatFileRecord` reuse bounded by channel handoff; retaining operators (Preview) opt out by
  copying. Compose with the typed-channel "typed view over a reused buffer" direction.
- Optional self-managed / thread-based parallel workers for hot stages (the Guava-Service path the base's hook
  names already anticipate); let completion/quiescence read worker lifecycle state, not only dispatcher inFlight.
- Resolve the P2 per-event graph-build cost (above).
- Measure against `JobExecutionTest.sliceThroughputBenchmark` (`-DjobSliceRows=<n>`).

### P6 — interactivity hardening

A worker idle on an OPEN external channel reads as quiescent (`inFlight == 0`) and is currently indistinguishable
from deadlock, so deadlock detection is BLANKET-DISABLED whenever any external channel is open (see
`JobExecution`'s external-clients branch). Now that the framework owns the serve loop (Phase 0) and self-managed
workers can expose a lifecycle, classify a worker parked awaiting an external request via a distinct "idle
server" signal, restoring deadlock detection even with external channels open.

---

## Key risks / decisions log

- **[DECIDED 2026-06-26] Frame-owned trace lifecycle — a trace buffer's life = its frame's life.** A
  `RunWorker` invokes the same child once per element; re-entering it showed the prior invocation's finished
  steps ("already executed"). Root cause: `JobLogicHostImpl` cached ONE `LogicRunExecutionId` per child
  *document* for the whole run, so re-entry reused the id and bypassed `LogicTraceStore`'s same-run-new-id clear,
  and two parallel callers of one child shared a buffer (interleave). Fix: each child INVOCATION gets its own
  execution id (minted per `LogicHandle.start`, the cache removed), and its buffer is reclaimed on frame close
  via a new `LogicTraceStore.evict(LogicRunExecutionId)` called from the facade-close listener. So a re-entry is
  a brand-new empty buffer, a streaming Job is bounded to its LIVE frames (the leak the cache guarded against,
  solved at the right seam — close, not id-reuse), and parallel callers get distinct buffers. Script/Flow are
  unaffected: their children aren't evicted on close, so the retained-across-iterations film-strip survives.
  Client (Part B): a child-document view is now **frame-keyed** — `ScriptProgressStore`/`FlowProgressStore` fetch
  the trace of the active frame for that document (single-execution `actionLookup` via the new
  `LogicRunFrames.frameForDocument`, run id + `frame.executionId`), falling back to most-recent + merged
  `lookupRun` when the document isn't live (post-run inspection). This makes two parallel/sequential invocations
  of the same document each show their OWN trace deterministically, instead of the lossy run-merge.
  Regression-pinned by `JobNestedLogicTest.reEnteringAChildStartsFromAClearedTrace`; `recursivelyNestedChildRunsAndIsTraced`
  reworked to assert recording while frames are LIVE (a completed Job-hosted child is no longer retained — the
  documented trade-off). The Job's own worker-progress trace (top-level run id) is untouched.
- **[DECIDED 2026-06-26] Step Over / Step Out cross the Job boundary by mirroring the controller's step plan
  onto each confined child.** A Job's children run on their OWN `MutableLogicControl` (confinement), so the
  depth limit that the single-control Script/Flow step navigation uses (`arm(budget, depthLimit)` +
  `runningFreeByDepth`) never reached them: `JobExecution` only branched on `consumeStepBudget()` (budget≥1 =
  step, else park) and `grantStepToChildren()` blindly armed every child `arm(1)`. So Step Over (budget 1,
  finite limit) collapsed to Step Into and Step Out (budget 0, finite limit) collapsed to a no-op pause — the
  reported "auto-step-over and step-out don't work" once stepping itself became usable. Fix: `LogicControl`
  exposes the armed plan (`armedStepBudget()` / `armedDepthLimit()`, defaults 0 / `MAX`, overridden by
  `MutableLogicControl`); `JobExecution`'s Pause branch treats `budget>0 || limit≠MAX` as a step tick (so Step
  Out's 0 budget no longer falls through to a plain pause) and passes the plan to
  `grantStepToChildren(budget, depthLimit)`, which translates the global limit into each child's OWN frame
  coordinates (children attach one level below the Job, so `D → D-childAttachDepth`, `childAttachDepth = 1`)
  and arms them. Below the limit the child runs free, at it it pauses — the same depth contract Script/Flow
  already honour. Scoped to a TOP-LEVEL Job (children at depth 1); a Job nested inside another Logic degrades
  to Step-Into descent (deferred, never worse than before). Regression-pinned by
  `JobNestedLogicTest.stepOverRunsNestedChildToCompletionWithoutDescending` /
  `stepOutOfNestedChildRunsItToCompletionAndReturns` (one grant reaches the wrapper's Success, vs Step Into's
  two-grant descend-then-pause). Slow-motion "auto-step-over" is just the client re-issuing Step Over, so it is
  fixed transitively.
  - **Follow-up (same day): a child BORN mid-wavefront must inherit the plan, and Step Out AT the root runs to
    completion.** The first cut armed only children live at grant time, but stepping over at the Job level (no
    child yet) creates a FRESH child via the `RunWorker` *after* the grant — and it got the constructor default
    `(0, MAX)`, pausing at its entry → the run still descended into the wrapper. Fix: `grantStepToChildren`
    records the in-flight `childStepDepthLimit`, and `TopLevelHandle.start` arms each new control `(0,
    translate(childStepDepthLimit))` — so under Step Over / Step Out a fresh child's entry boundary is below the
    limit and it runs free (the child completes and detaches within the wavefront, so autoFollow never descends);
    under Step Into it pauses at entry (descend) as before. Separately, the Job runs as the run ROOT frame
    (depth 0), so a Step Out whose limit drops below it (`runningFreeByDepth`) is Step Out AT the root — no
    caller to return to — and `JobExecution` now runs it to completion like a full resume (granting the children
    the run-free plan first), instead of a single wavefront, matching a Script's Step Out at its root.
    Regression-pinned by `JobNestedLogicTest.stepOverAtJobLevelRunsFreshChildWithoutDescending` /
    `stepIntoAtJobLevelPausesFreshChildAtEntry` (grant-before-create order) and
    `JobExecutionTest.stepOutAtRootRunsWholeJobToCompletion`.
- **[DECIDED 2026-06-25] P3 migration is rebuild-the-whole-graph, not in-place re-config.** A Job's Workers are
  live parked coroutines, so there is no in-place "swap one Worker's config"; `migrate()` cancel+joins the old
  graph and `buildAndLaunch`es from the edit. Change is detected by comparing the incoming filtered
  `GraphDefinition.objectDefinitions` (value-equal data classes — cheap, stable) against the launched one; a
  no-edit resume is value-equal so it does NOT rebuild (guarded by a test asserting two independent builds of
  the same notation are `objectDefinitions`-equal).
- **[DECIDED 2026-06-25] Capture-BEFORE-teardown, not post-join `loadState`.** First cut used
  `StatefulLogicElement.loadState` reading the joined previous instance; reversed the SAME DAY when the reader's
  open file handle had to survive — teardown's `onClose` closes it before any post-join read. So `WorkerBase`
  exposes `captureMigrationState()` (called while the Worker is still parked, detaches live handles) +
  `loadMigrationState()`; `JobExecution` captures all Workers before tearing down, then the rebuilt Workers
  adopt by stable id, with an `AutoCloseable` orphan sweep for handles whose Worker was removed by the edit.
- **[DECIDED 2026-06-25] `CsvReaderWorker` resumes from its open reader** (gated on path/delimiter/header). Loop
  `checkpoint` is at the batch top so a parked reader holds no built-but-unsent batch; reader + position +
  `pendingFirstRecord` + EOF `finished` are fields carried by capture/load. A batch the reader is parked mid-send
  on rides the OUTPUT channel's in-flight capture (below), not the reader — the bespoke `pendingBatch` was removed.
- **[FIXED 2026-06-25] Exact mid-stream cut — channel carryover.** A migration tears the graph down, so a fast
  reader's batches sitting in a channel buffer (or parked in a `send`) were dropped — and since the reader
  resumes from its position rather than re-reading, permanently lost (the reported "total ≠ 1 billion"). NB a
  plain pause/resume is non-destructive (pause only arms a release signal); the loss is exclusively the migrate
  teardown. Fix: `JobChannel.drainBuffered()` snapshots a channel's buffered + parked-mid-send payloads
  (producer-tracked `inFlight`, dedup'd by identity) while Workers are parked and BEFORE teardown;
  `JobChannel.preload()` seeds the rebuilt channel, delivered (carryover) ahead of the live stream; `JobExecution`
  captures every one-way channel by stable id and restores after rebuild. The framework consumer loops
  (`TransformWorker`/`SinkWorker`) now `checkpoint` BEFORE receive so a parked consumer strands no
  received-but-unforwarded item. Also: a pre-armed pause/step now launches Workers parked at their first
  checkpoint (no nondeterministic free-run window at start). Tests: `JobChannelTest` (mechanism),
  `JobMigrationCarryoverTest` (free-run mid-stream pause + edit, exact count). Still open: truncating-sink carry.
- **[OPEN] Truncating-sink carry-forward (P3 follow-up).** A source resuming is only coherent with a downstream
  that accumulates/appends; `CsvWriterWorker` re-truncates on rebuild, so a reader→writer edit-resume drops rows
  written before the cut. Give the writer its own append/seek capture (opt-in, like the reader). Deferred (~P5).
- **[FIXED 2026-06-25] Step ran to completion instead of advancing one wavefront.** `JobExecution`'s step
  branch did `jobControl.resume(); awaitQuiescent(); pause()` — but a full `resume()` makes `checkpoint()`
  return forever, so a steady pipeline only reaches `inFlight == 0` at completion: one "step" ran the whole
  Job, and (because `ServerLogicController.stepInternal` keeps `state.paused = true` while the wedged step
  executes) a follow-up pause threw *"Already paused."* Fix: added `JobControlImpl.step()` (completes the
  parked Workers' captured signal once but STAYS `Pausing` and nulls the signal, so each parked Worker advances
  exactly one checkpoint then re-parks on a fresh signal = one wavefront); `checkpoint()` lost its re-park loop
  (only `resume`/`step`/`cancel` ever complete the signal, so a wake = proceed; the loop never re-parked under
  the old code → behaviour-preserving for pause/resume/cancel). Regression: `JobExecutionTest
  .singleStepDoesBoundedWorkThenStaysPaused` (pause → one step → assert still `Paused` and output not finished
  → resume completes correctly). The old test `stepEventuallyCompletesOverSlice` already described this
  behaviour in its comment; it passed before only because it asserts *eventual* completion, not boundedness.
- **[FIXED 2026-06-25] Step granularity per-checkpoint was lopsided → stepping looked "stuck", slow-motion did
  nothing.** A step advances each parked Worker by one checkpoint, BUT `CsvReaderWorker` checkpointed per RECORD
  (its KDoc said "per batch" — code/doc drift) and only published progress per BATCH, while
  `TransformWorker`/`SinkWorker` checkpoint per batch. So with `Job.yaml`'s `batch: 4096`, one step read ONE
  invisible record (no publish, nothing downstream) — you'd click step ~4096 times for one UI update, and
  slow-motion (one step / 750 ms) would take ~51 min to surface the first batch. NOT a controller hang (verified:
  `MutableLogicControl` budget/command model is sound across repeated steps; `logicStart(paused)` = start → pause
  → step; `JobExecution`'s step branch always returns) — purely imperceptible progress. Fix: moved the reader's
  `checkpoint()` to per-batch (before each emit, incl. the trailing partial), matching its own KDoc and the
  Transform/Sink unit, so **one step = one batch** uniformly and visibly. Trade-off accepted: pause/cancel now
  land per batch (a 4096-record read is ms-fast; the `batch` attr is the user's knob). Regression:
  `JobExecutionTest.steppingAdvancesByBatchNotByRecord` (8192 rows = 2 batches drains in <50 steps, not ~8192).
- **[DECIDED] Confinement for nested-Logic concurrency (P2).** Per-child private control/scope, not shared-state
  locking — preserves parallelism, isolates state, sidesteps the pause-semantics mismatch. Resolved the
  highest-uncertainty item.
- **[REVISED 2026-06-25] Step-control model unified to per-spine `(budget, depthLimit)`; a Job's per-event
  child IS now steppable.** The earlier "child not steppable, runs as a function call" decision was forced by
  `LogicControl` keeping ALL step state on ONE control shared across the frame tree (incompatible with
  concurrent Workers), which had grown a dual-mode (private full-speed vs shared steppable control) +
  `hasStepBudget()` peek + `JobChildExecution.step()` increment loop. Root-cause fix: `LogicControl`'s four
  stepping mechanisms (`stepBudget`, `suppressPause` push/pop + `stepOverActive`, `frameDepth` enter/exit +
  `stepOutTarget`/`inStepOutRegion`) collapse to TWO primitives — a `budget` (0/1) consumed by the first fresh
  boundary (`consumeStepBudget`) and a `depthLimit` beyond which a boundary runs free (`runningFreeByDepth`,
  = `frameDepth > depthLimit`). Step Into = `arm(1, MAX)`, Step Over = `arm(1, steppedDepth)`, Step Out =
  `arm(0, steppedDepth - 1)`. Step state is now PER-SPINE, so a Job confines each child to its OWN control
  (delegating only the run command to the shared control via `commandSource`) and a Step descends into a child
  via that child's own budget — the dual-mode / peek / `JobChildExecution` all deleted; `RunWorker` is now the
  RunStep-style `logicHandleFacade().start → beforeStart → continueOrStart* (checkpoint on Paused) → close`
  loop. Regression-pinned by `StepNavigationTest` (controller Step Over / Step Out, added first).
- **[DECIDED] `logicHost()` on `JobControl`** returning a dedicated `JobLogicHost` (the plan's "JobControl
  extension"); keeps hosting logic single-purpose in its own type — now exposing `logicHandleFacade()` /
  `graphDefinition()` / `argumentTuple()` rather than `open()`.
- **[DECIDED] Typing target = coarse whole-type channels** (`elementType: TypeMetadata`); structural per-field
  `FieldFormatListSpec` deferred. P1 assignability is exact-match + `Any` wildcard (commonMain `TypeMetadata`
  carries no class hierarchy).
- **[DECIDED] Parallelism from the start; `suspend` optional; workers may own their execution** (single-reader +
  inputs-only-via-channel/JobControl invariants).
- **[OPEN] Self-managed workers vs. quiescence** — worker-owned threads aren't on the `CountingDispatcher`;
  P5/P6 must let quiescence read worker lifecycle, not only inFlight.
- **[OPEN] State migration across resources** — handles migrate as position + reopen (P3 opt-in per worker).
- **[GOTCHA] `CachedKotlinCompiler`** races on concurrent cold compiles of the same signature (only ever hit
  single-threaded before). Non-issue in practice (different workers → different expressions; one worker's stream
  warms its key sequentially); warm the cache in any concurrent test.
- **[GOTCHA] Live progress can't hang off a `$stable` trace path** — use a fixed-convention path
  (`JobConventions.workerProgressPath`).
- **[GOTCHA] No `title:` on `Channel`/`DuplexChannel` archetypes** (no `is:` parent → fails to define → drops
  every channel).
