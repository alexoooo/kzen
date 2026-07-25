# Job (concurrent dataflow Logic) improvements — remaining phases (J2–J9)

> **Status: planned.** Successor to `sprint-1/2026-07-06_job-improvements.md` (Sprint 1: J1
> landed; this document carries J2–J9 forward, complete and self-contained, rescoped for what
> the engine work delivered in the meantime — see "Landed context"). Executor: **Opus 4.8
> xhigh, one phase per session.** Each phase is self-contained: goal, design decisions (already
> made — do not re-litigate), concrete steps with file anchors, and verification. Phases are
> ordered by priority; only phase 4 (on 3), phase 9 (sequence after 4 — same files), and parts
> marked "gated" have hard prerequisites. Phase IDs are stable across the sprint reorganization.
>
> Companion plans: `2026-07-16_graph-improvements.md` (graph layers; G4 would make
> `JobChannelSynthesis`'s per-compile define cheap), `2026-07-16_script-client-sweep.md`
> (sibling flavour's client sweep), `2026-07-14_attribute-editor-improvements.md` (shared
> editor plumbing — commit primitive, select-reference base; phase 8 item 4 builds on it, see
> the note there), and `2026-07-21_job-element-model.md` (channel element data model — typed
> `JobMessage` payloads + flat part replacing `DataRecord`, typed parameters, expression scope,
> type flow; fixes the untyped-lane→record-worker ClassCastException; SUPERSEDES phase 2's
> ParameterSource half and interacts with phases 3/5/6/8 — see its interactions section). This
> plan deliberately does **not** duplicate their items.
>
> The original build plan (`2026-06-23_job-paradigm.md`, the P4*/M* milestones referenced from
> code comments) is a **historical record in git history only** (recover via
> `git show ef0dbd4~1:plans/2026-06-23_job-paradigm.md` in the kzen repo). Its still-live
> content is fully consolidated here — the open backlog into phases 4/5/7/8/9, the durable
> gotchas and design rationale into the appendix — so it needs no further maintenance. Phase 8
> repoints code-comment references here.
>
> **Progress tracker** (update as phases land):
> - [x] Phase 2 — Job signature: parameters in, results out (composition centerpiece) ✓ 2026-07-21 (see as-built note below)
> - [ ] Phase 3 — Report subsumption A: pluggable input formats + design-time services
> - [ ] Phase 4 — Report subsumption B: export parity, offline persistence, deprecation path
> - [ ] Phase 5 — performance + headless readiness (benchmark-first)
> - [ ] Phase 6 — topology: fan-out + non-linear ergonomics
> - [ ] Phase 7 — interactivity remainder: retain=false progress emits, deadlock precision, channel occupancy
> - [ ] Phase 8 — client sweep + hygiene
> - [ ] Phase 9 — live-edit carry-forward for file-backed workers (writer append, pivot/explore resume)

## Landed context (Sprint 1) — what changed under this plan

- **J1 ✓ 2026-07-11 — progress wire contract + trace bounding.** Well-known progress keys +
  `progressTeaserRowCount` live in `JobConventions` (commonMain), used by JVM workers and JS
  displays alike; push is a bounded teaser, the forced end-of-stream push carries the full
  payload; the Pivot teaser bug is fixed (`progressCountKey` + a real bounded teaser via
  `builder.preview`); `WorkerBase` gained a delegating `progress(snapshot, force)` overload;
  contract tests pin the key agreement. Phases 7/8 can rely on the constants.
- **Engine plan (E) essentially complete** — several items this plan referenced as "gated on
  engine work" have resolved:
  - **E4 ✓ (trace unification + `Execution.emit(retain:)`)**: the transient-emit flag exists;
    Script adopted it for all its emits (S7). **Job has NOT adopted it yet** — the coordination
    note sits in `EngineJobControl.publishProgress` ("mark the emit non-retained when transient
    emits land"). That adoption is now **phase 7's first item** (small, mechanical).
  - **E7 ✓ (structured failure)**: **per-worker outcome chips are substantially delivered** —
    `LogicTracePath.nodeOutcome` + `JobWorkerProgress.outcome` (`WorkerOutcome`) exist and
    `WorkerDisplayDefault.cardHeader` renders a chip. The former phase-7 "outcome chips" item is
    reduced to a verification remainder (see phase 7).
  - **E3 ✓ (breakpoints)**: landed with **Script-only UI**. Per-worker run-to/breakpoints for
    Job are engine-supported but need a Job-side affordance — still deliberately not built here;
    noted in phase 7 as a demand-driven follow-up.
  - **E5 ✓ (SSE push + sequence-gated fetch)**: status transport reshaped;
    `LogicStatus.time` is gone (epoch + sequence versioning; client publish throttled). The
    old "engine 5 fixes 6c's monitor-held round-trip properly" expectation must be re-verified:
    E5 shipped push status, not necessarily an async external-request path — phase 7 checks
    whether `JobRun`'s monitor-held `runBlocking` round-trip (JobRun.kt:224-241) still stands
    and applies the interim mitigation if so.
  - **E6 (multi-run) DEFERRED** — headless background runs no longer compose with a scheduled
    multi-run phase; phase 5's headless mode stands alone (single active run per JVM for now).
- **Script plan S2/S3 ✓**: engine-carried resource values exist (S2 — evaluate folding Job's
  `JobChildLogicHost` compile cache and scratch-dir registration onto them; slot into phase 8
  if cheap, else record a decision), and **the weak `RunWorker.instructions` link is already in
  the migration closure** (S3's `LinkedLogicDocuments` fixed it generically — editing a paused
  Job's callee Script migrates the Job).
- **Graph G1 ✓**: definition caching makes `JobChannelSynthesis`'s per-compile
  `GraphDefiner.tryDefine` one-per-notation-version; G4 (incremental define) remains the
  further win and is measurement-gated in the graph plan.

## Context — what the review found

Job is the **best-engineered flavour on the engine** — materially stronger at the same age than
Script or Flow were. Do not restructure. The crown jewels, preserved by every phase:

- **One Worker = one confined engine node** (`JobRun.run` hosts each via `Execution.host`,
  JobRun.kt:183-205). Pause/step/cancel/pause-on-error/trace attribution are all inherited: a
  cooperative `checkpoint()` per batch is the whole contract (`JobControl`, JobControl.kt:19), and
  the engine's quiescent wavefront replaces the old supervisor/phase machinery outright
  (the "KEY COLLAPSE" note, JobRun.kt:37-43). Stepping is the wavefront: one step advances every
  parked Worker one batch.
- **Channels are engine-invisible bulk lanes.** Data flows Worker→Worker through
  `JobChannel` (framework batching, close-on-last-producer, blocked-endpoint tracking) — never
  through the trace. Migration carryover is genuinely lossless at the element grain:
  `drainBuffered` captures buffered + parked-mid-flush batches with identity dedup
  (JobChannel.kt:130-158), the rebuilt run `preload`s by deterministic synthesized channel
  identity (JobLogicCompiler.kt:24-28, JobConventions.autoSynthChannelName).
- **Per-Worker migration state done right**: `WorkerLogic` bridges
  `WorkerBase.captureMigrationState`/`loadMigrationState` onto the node's capture/restore
  (WorkerLogic.kt:52-57); `CsvReaderWorker` / `MultiFileReaderWorker` **detach the open reader
  and resume mid-file** with a config-changed guard (CsvReaderWorker.kt:122-155); Sort carries
  its buffer *because correctness requires it*; Preview/Summary carry accumulations; sinks
  restart coherently.
- **The extension rule holds everywhere.** No worker-type `when` in any general layer (verified
  server + client): flavour compilation is polymorphic (`LogicDocument.toLogic`), channel wiring
  dispatches on attribute *type* (JobChannelCreator), display selection on the `display:` marker
  (WorkerDisplayManager), capability discovery on archetype inheritance (`JobServeCapability`),
  editors on `editor:` metadata. `JobWorkerProgress` stays schema-agnostic.
- **Order-driven wiring with a manual escape hatch.** `JobChannelDerivation` (pure, shared
  client/server so the gold pipes and the run cannot drift) pairs adjacent workers with exactly
  one open output/input; non-blank ports are manual wires; synthesis materializes channels only
  in the ephemeral run-copy (JobChannelSynthesis.kt:22-37). Definition-time type checking +
  single-reader enforcement (`ChannelTypeDefiner`) makes the framework's one `item as In` cast
  provably safe (TransformWorker.kt:23-27).
- **A real test net**: ~30 server test classes + fixtures covering migration carryover, deadlock,
  external bridge, batching defaults, synthesis edge cases.

The build plan's five goals remain the rubric every phase serves — (1) ergonomic & safe
concurrency, (2) performance headroom, (3) do what Report does and more, dynamically, (4) type
safety, (5) interactive execution — plus a sixth from the user's direction: (6) headless-capable
without redesign.

The still-open weaknesses (post-Sprint-1 view):

1. **A Job is not yet a first-class composable Logic** (→ J2). `LogicSignature.empty`
   (JobLogicCompiler.kt:54, JobLogic.kt:18-19): no declared parameters, no harvested output. A
   Script/Flow/Worker can *host* a Job but can pass nothing in and gets `TupleValue.empty` back
   (JobRun.kt:215). This blocks Job-in-Script pipelines, parameterized runs, and headless
   invocation with arguments.
2. **Report subsumption is ~70% done with the missing 30% concentrated** (→ J3/J4). Job already
   reuses Report's substrate engines (`PivotBuilder`, `IndexedCsvTable`, `ValueSummaryBuilder`,
   `CalculatedColumnEval`, export formatters/compression) and adds things Report never had (Sort,
   arbitrary Kotlin filter, scalar lanes, mid-file resume). Missing: the **format plugin SPI**
   (`ReportDefiner`/`DataFramer` — zero references in `objects/job/`; readers are CSV-hardcoded
   with no charset control), **design-time services** (file browse, column pre-scan for editors —
   `SortSpecEditor` is stuck in free-text fallback), **grouped export fan-out** (`${group}`
   resolves empty, ExportWriterWorker.kt:82), **offline summary** (Report persists summary CSVs
   per run dir; Job's summary lives only in the in-memory trace — gone on JVM restart), and a
   **deprecation path** for Report's dual Detached+Logic surface.
3. **Topology is linear-only in practice** (→ J6). Auto-wire pairs only adjacent single-port
   workers (JobChannelDerivation.kt:84-93); fan-in works (multi-producer close tracking) but
   **fan-out has no vehicle at all** — channels are enforced single-reader (correctly), and
   there is no tee/broadcast Worker.
4. **Performance is unmeasured against the thing Job replaces** (→ J5). Report's pipeline earns
   its throughput with ring-slot flyweight reuse, columnar `FlatFileRecord` caches warmed
   off-path, and a 32K MULTI ring. Job allocates a fresh `FlatFileRecord` + `DataRecord` per row
   (ownership-transfer by design), a fresh batch `ArrayList` per flush (JobChannel.kt:193), and
   calls `runBlockingIo { reader.readRecord() }` **once per record** (CsvReaderWorker.kt:73,
   MultiFileReaderWorker.kt:81, ExportWriterWorker.kt:96). Nobody knows the gap. Headless
   ("max performance, background, maybe own process") needs the interactive costs gateable —
   none are today — but the SPI itself is already process-neutral.
5. **Interactive polish gaps** (→ J7, rescoped). (a) **Deadlock detection is disabled for
   virtually every real Job**: `JobDeadlockMonitor.start` returns immediately when any external
   serve channel exists (JobDeadlockMonitor.kt:70-74) — and Preview, Summary, Explore, and Pivot
   all have serve ports. (b) Job progress emits still append to retained history
   (`retain=false` not yet adopted — see Landed context). (c) The external UI bridge does a
   `runBlocking` round-trip **on the controller thread while holding its monitor**, 1 s worst
   case (JobRun.kt:224-241). (d) Channel state (buffered, blocked) is tracked but invisible.
   (Per-worker outcome chips: delivered by E7.)
6. **Client sweep debt** (→ J8). `JobController.onClientState` stores the **whole
   `ClientState`** and `setState`s unconditionally (JobController.kt:241-244 — the exact
   anti-pattern the render-scoping conventions warn about); `JobChannelDerivation.derive` — a
   full metadata walk — is recomputed uncached on every publish *and* per editor recompute *and*
   per serve-name resolution (JobController.kt:271, JobUpstreamSchema.kt:19-33,
   JobServeChannelResolver.kt:21-24); `JobServeChannelResolver` hardcodes
   `AttributeName("serve")` + resolves references by `substringAfterLast("/")`, contradicting
   the by-type port rule; the client duplicates the Channel archetype defaults as `"1024"`/`"0"`
   string literals six times (JobChannelDefaults.kt:84,89; JobController.kt:701-708);
   `WorkerDisplayManager` hard-throws on an unresolved `display:` name; and
   `formatCount`/`abbreviate`/add-column-form/store-observer boilerplate is copy-pasted across
   the editor family.

**Covered elsewhere — do not re-do here:** breakpoints / per-worker run-to UI (engine E3 landed
Script-only; Job affordance is demand-driven follow-up); multi-run (E6 — deferred, see master
plan); publish/history hot path + frame compaction (E1 — landed); weak `instructions` link
(S3 — landed, fixed generically); engine-carried resource values (S2 — landed; fold evaluation
in phase 8); definition caching (G1 — landed) and incremental define (G4 — measurement-gated in
the graph plan); scoped instantiation for detached actions (G3).

**Deliberately out of scope** (decided; do not re-open inside a phase):
- Replacing coroutine channels with a Disruptor ring inside Job. The coroutine model is what buys
  confined-node pause/step/migration; phase 5 closes the throughput gap by measurement and
  targeted fixes, not by substrate swap.
- Multi-process execution. Phase 5 only *protects* it (keeps `JobControl` process-neutral, makes
  interactive costs gateable); designing the process boundary is a future plan.
- A full 2D node-and-edge canvas. Phase 6 makes non-linear topologies *expressible and legible*
  in the ordered-card view; a canvas is justified only if branching becomes common.
- Retiring `ModelTaskRepository` / the Task paradigm (a separate surface with its own
  consumers — audit separately).
- Typed channel subtyping (co/contravariance). Exact-match + `Any` wildcard
  (ChannelTypeDefiner.kt:192-197) is the right v1; revisit only when a real plugin hits it.

## Ground rules for every phase

- **The extension rule is inviolable**: no Worker-type knowledge in `JobRun` / `WorkerLogic` /
  `EngineJobControl` / `JobChannelDerivation` / synthesis / the client general layers. New
  cross-cutting needs become capability markers (the `JobServeCapability` pattern) or notation
  metadata, never class-name checks.
- A 3rd-party Worker must remain fully expressible as `@Reflect` + `is: Worker` archetype +
  optional `is: WorkerDisplay` card, zero shared-code edits.
- Run every phase's verification: `./gradlew :kzen-auto-jvm:test` (the `exec/job` +
  `objects/job` suites are the safety net), plus the touched-area tests named per phase. UI
  changes: `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` and eyeball the Sample Job.
- Update this plan's tracker + add an as-built note per phase. Keep `kzen-lib/docs/logic-spec.md`
  and `kzen-auto/docs/architecture.md` in sync when behaviour changes.

---

## Phase 2 — Job signature: parameters in, results out

**Goal.** A Job declares parameters and produces an output tuple, so `RunWorker` / Script `RunStep`
/ Flow `RunLogicVertex` can host it with arguments and consume its result — completing the
"flavours nest each other uniformly" story (LogicCompiler.kt:20-22).

**Design decisions.**
- Mirror Flow's model (dedicated input/output vertices) with Workers: a **`ParameterSourceWorker`**
  (source; declares `parameter: <name>`; emits the bound argument value as a single element — or,
  if the argument is a `Collection`, streams its elements: decided, stream collections) and a
  **`ResultSinkWorker`** (sink; collects its input; result = the collected list, or the single
  element when exactly one arrived — matching `host`'s single-positional convention,
  EngineJobControl.kt:112-119).
- **Discovery is capability-based, not class-based**: the compiler must not name these classes.
  Add a `JobSignatureCapability` (the `JobServeCapability` pattern, JobServeCapability.kt:24-64)
  classifying a worker as Parameter/Result from marker archetypes (`is: ParameterSource` /
  `is: ResultSink` semantic archetypes in job-jvm.yaml), so third parties can implement their own.
- `JobLogicCompiler.compile` derives `LogicSignature` from the classified workers (parameter name
  + declared `of:` type; result type from the result worker's input `of:`), replacing
  `LogicSignature.empty` (JobLogicCompiler.kt:54). `JobRun.run` seeds each ParameterSource with
  its argument from `execution.inputs` and harvests the ResultSink's collection into the returned
  `TupleValue` (JobRun.kt:215). **Decided route: `JobControl.parameter(name: String): Any?`** —
  `JobRun` passes the run's inputs into `WorkerLogic`, which exposes them on `EngineJobControl`;
  it needs no new definers and any worker (3rd-party included) can read parameters.
- Result harvest: `JobControl.yieldResult(component: String, value: Any?)` on the SPI; `JobRun`
  aggregates yielded components into the output tuple. `ResultSinkWorker` is then a trivial
  built-in over the generic hook.
- Migration: parameter values are run-constant (no carry needed); a ResultSink's accumulated
  collection carries via the standard `WorkerBase` capture (same as Sort's buffer).

**Steps.**
1. SPI: add `parameter(name)` + `yieldResult(component, value)` to `JobControl`
   (JobControl.kt) with kdocs; implement in `EngineJobControl` (inputs threaded from `JobRun`
   through `WorkerLogic`); default to null/no-op semantics consistent with the SPI's
   platform-neutral style (not default-throw).
2. Built-ins: `ParameterSourceWorker` (SourceWorker; streams a Collection argument, else emits
   one element) + `ResultSinkWorker` (SinkWorker; collects, yields at `onComplete`), archetypes +
   semantic markers in job-jvm.yaml/job-worker.yaml, `@Reflect`, display defaults.
3. Compiler: `JobSignatureCapability` in common; `JobLogicCompiler` builds the signature;
   `JobLogic` carries it (JobLogic.kt:34-36 already returns the field).
4. Client: the signature shows up automatically wherever `LogicSignature` is rendered (Script's
   Run-step argument editor, Flow's signature editor) — verify, don't rebuild.
5. Tests: a `job-signature-test.yaml` fixture (Script hosting a parameterized Job via RunStep;
   Job hosting a parameterized Job via RunWorker); assert the argument reaches the stream and the
   result tuple round-trips. Migration test: pause mid-run, edit, resume — result still complete.

**Verification.** New fixture tests green; existing `JobRunWorkerTest` untouched; a Script
`RunStep` pointing at a parameterized Job shows its parameters in the arguments editor.

**As-built (2026-07-21, executed from `plans/next/J2_job-signature.md`).** Landed as planned;
kzen-auto only, no kzen-lib change. **Partially superseded same-day**: `2026-07-21_job-element-model.md`
(phase 2) replaces ParameterSourceWorker + the signature's Parameter-marker derivation with typed
parameter declarations (Script `ParameterBinding` style); ResultSink, `JobControl.parameter`/
`yieldResult`, and the client signature branch carry forward. Full `:kzen-auto-jvm:test` green (484 tests, 0 failures;
`:kzen-auto-js:compileKotlinJs` green). Deviations / notes:
- **Markers live in `common-job.yaml`, not `job-jvm.yaml`** (the exact `SummaryServer` precedent —
  a common-classified semantic marker sits beside the `Worker` base it refines). File-placement
  refinement, not a design change.
- **Client step 4 was NOT "verify, don't rebuild".** `RunStepArgumentsEditor.onClientState`
  dispatches on callee document type (Script `parameters` / Flow input vertices); a Job callee fell
  into the Script branch and rendered zero rows. Added a ~15-line `else if (JobConventions.isJob)`
  branch calling `JobSignatureCapability.signature` (untyped params badge "Any", Script parity).
  This was the ONLY client edit — no Flow client code renders a callee's parameters (Flow's binding
  is server-side `FlowChildLogic.firstParameterName`), and `LogicSignatureEditor`/`ResultSignatureEditor`
  edit a Script's OWN signature, so neither applies to Job.
- **Script round-trip fixture needs a `ResultStep` + `results` signature** — there is no last-step
  fallback (the established Script result contract), so `job-signature-script-test.yaml` surfaces
  the RunStep's value via a trailing `ResultStep` (the plan's fixture sketch omitted this).
- **ParameterSource carries a claim-before-send stream cursor** (`GatedSourceWorker` precedent), and
  **ResultSink carries its accumulation WITHOUT clearing on yield** (Sort's-buffer minus the clear) —
  both load-bearing: the migration test's exact-list assertion `(0 until 50)` fails on either a
  source restart (overshoot) or an accumulation loss (shortfall). Proven by `JobSignatureMigrationTest`.
- **Findings routed onward (NOT fixed here — behavioural, out of J2's pre-made scope):**
  `EngineJobControl.host` still uses the engine defaults `retainTrace = true` (a long streaming
  RunWorker retains one node per element) and passes no `callerStableId` (RunWorker invocations lack
  the call-site attribution a Script `RunStep` supplies). Route to **J7** (bounding) / **J8**
  (hygiene). The new frame-trace pin (`JobSignatureTest.hostedChildInvocationsAreDistinctRetainedExecutions`)
  asserts the CURRENT behaviour (distinct, retained) and must be updated if J7/J8 change the default.
- **Blank-parameter authoring** stays visible, not a crash (Flow parity; a J8 structure-lint candidate).

**Typed Result follow-on (2026-07-22).** The output half of the signature moved to Script parity:
the Job document now declares a typed `results` signature map (same `ResultSignatureDefiner` /
`ResultSignatureEditor` as Script — the definer + `results` conventions moved to the flavour-neutral
`document.logic` / `LogicConventions` home), and `JobSignatureCapability` derives outputs from it
instead of scanning ResultSink markers (the sink-input-port `of:` typing is gone). `ResultSinkWorker`
no longer collects the stream into a list: `keep: first|last` (default `last`, Script's
last-Result-wins parity) keeps a single element in constant memory; an empty stream is a run failure
unless the declared type is nullable (then the result is null); a sink whose `result` component is
undeclared is a validation error on its card (`payloadFlow`) and a run failure — strict Script
parity. The declared outputs reach the sink at run time via new `JobControl.results()` (threaded
`JobLogic` → `JobRun` → `WorkerLogic` → `EngineJobControl`, mirroring `parameters()`). The card's
free-text `result` field is hidden (signature-managed; notation-only for multi-result Jobs), and the
Job stage gained the ResultSignatureEditor stacked under Parameters (channel defaults moved down).
The migration proof pivoted from exact-list order to exact seen-count + kept-last (order stays
pinned by `JobMigrationTest`'s CSV lane). The initially-deferred declared-vs-inferred type check
landed same-day: new `TypeAssignability` (server `objects.logic`) probe-compiles
`fun probe(value: <inferred>): <declared>` via `CachedKotlinCompiler` — Kotlin's own assignability
(subtyping, generics, nullability), `ResultStep`'s forced-return-type mechanism transposed to a
type pair — and `ResultSinkWorker.payloadFlow` rejects a lane whose static boundary type (new
`WorkerLane.boundaryType()`: payload, else known-flat `Map<String, String>`, else unknown ⇒ check
skipped) is not assignable to the declared component type, erroring on the card before running.
The Result card now also SHOWS the kept value (2026-07-22): `ResultSinkWorker.progress()` pushes the
value's display text under `JobConventions.progressResultValueKey` (a single-element list so the
generic status line skips it), and a new per-type `ResultWorkerDisplay` (the SummaryWorkerDisplay
`bodyExtra` composition) renders it in a value box — live for `keep: last`, settled on the forced
final publish (`WorkerBase.run`).

**Goal.** Close the input-side gaps: third-party format plugins, charset handling, and the
design-time actions Job editors need (file browse, column pre-scan) — without Report's document
class in the loop.

**Design decisions.**
- **Bridge the existing plugin SPI, don't invent a new one.** `ReportDefiner`/`DataFramer`/
  segment steps (kzen-auto-plugin) stay the format contract. New `PluginReaderWorker`
  (SourceWorker): config = file path(s) + `PluginCoordinate` (+ optional charset); it drives the
  plugin's framer + segment steps **synchronously in a plain loop over reused event objects** —
  the step SPI (`ReportIntermediateStep.process(model, index)` / terminal step) is ring-agnostic;
  only the driver differs. No disruptor inside a Worker (a Worker is already its own concurrent
  unit; batching/backpressure come from the channel). Reuse `ReportUtils.encoding*` for charset
  resolution. Resolution via `ReportDefinitionRepository` injected `@Service` (already in the
  graph environment, KzenAutoContext).
- **Extract design-time services out of `ReportDocument`.** `FileListingAction` and
  `ColumnListingAction` become flavour-neutral detached actions (they already are separate
  classes; what moves is the REST/action routing so a Job document can invoke them — the same
  pattern `jobDownload` used, RestHandler.kt:1142-1164). `MultiFileInputEditor` (already reusing
  the browse) and the spec editors get columns from the new column pre-scan instead of requiring
  a live SummaryWorker upstream: `JobUpstreamSchema` falls back reader-config → pre-scanned
  header when no summary source exists. This un-strands `SortSpecEditor` from free-text
  (SortSpecEditor.kt:71-73).
- Charset on the native readers: add optional `encoding` attribute to `CsvReaderWorker` /
  `MultiFileReaderWorker` (default UTF-8, blank = detect via `ReportUtils`), threaded to
  `Files.newBufferedReader` (CsvReaderWorker.kt:91).
- Migration state for `PluginReaderWorker`: v1 = restart on edit (the safe `WorkerBase` default);
  positional resume for plugin formats is follow-up (framers are stateful; note it in the kdoc).

**Steps.** (1) `PluginReaderWorker` + archetype + tests over the built-in Csv/Tsv/Text definers
(the A/B: same file through `CsvReaderWorker` and `PluginReaderWorker(csv)` yields identical
`DataRecord` streams). (2) Action extraction + REST routes + client wiring for browse/columns
against a Job document. (3) `JobUpstreamSchema` fallback + `SortSpecEditor` column dropdown.
(4) `encoding` attribute.

**Verification.** New worker tests + an editor smoke pass; `kzen-sample-plugin`'s definer loads
through a Job (manual); Report's own paths untouched (its suites green).

---

## Phase 4 — Report subsumption B: export parity, offline persistence, deprecation path

**Goal.** Close the output-side gaps and write down the Report retirement sequence. Depends on
phase 3 (parity checklist references its outcomes).

**Design decisions.**
- **Grouped export, the Job way**: Report groups by filename regex (`GroupPattern`); a Job stream
  is already merged, so grouping by *column value* is strictly more general. Add optional
  `groupBy: <column>` to `ExportWriterWorker`: on group-value change (or per distinct value),
  resolve `${group}` in the path pattern and open the next container — reusing
  `ExportFormatter.onNewGroup` semantics / `CompressedExportWriter.openNextGroup` logic via the
  shared seam (ExportWriterWorker.kt:82 currently pins `DataLocationGroup.empty`). For
  Report-style per-file grouping, `MultiFileReaderWorker` optionally stamps a group column
  (e.g. from a capture pattern over the source filename) — composition instead of a baked-in
  pipeline mode.
- **Summary persists like Explore.** `SummaryWorker` gains the persistent notation-keyed
  `outputDir` (`JobControl.outputDir`, JobControl.kt:54; JobWorkPool.workerOutputDir) and writes
  Report's exact summary CSV layout on close (`ReportSummary.save` format, reused); an offline
  read path (REST, same shape as `jobDownload`) serves the value-set/pivot editors when no run is
  live. This is what makes a Job usable for *iterative* report building: configure filters
  against the last run's distinct values without re-running.
- **Post-run and post-restart Explore** (adopted from the build plan's P4i follow-ups, still
  open): (a) in-card **browse after the run settles** — the live serve path dies at teardown, so
  paging the persisted result needs a detached slice read over the notation-keyed
  `IndexedCsvTable` (same resolution as `RestHandler.jobDownload`; `IndexedCsvTable` already
  supports offline preview); the Explore card falls back live-serve → detached-offline.
  (b) **cross-restart visibility** — the download/browse gate reads the row count from the
  per-session trace, so after a JVM restart the on-disk result survives but the affordances hide
  until re-run; probe the persisted table itself (row count from the offset index) instead of
  the trace.
- **The end-to-end A/B gate is the acceptance test**: the same dataset through Report and
  through the equivalent Job — export bytes identical, pivot/summary results equal. The
  per-worker A/Bs (phase 3's reader, this phase's grouped export) are stepping stones; the
  checklist closes on the composed gate.
- **Deprecation sequence** (documented in the plan + architecture.md, executed over later
  sessions): (i) parity checklist — each Report capability row mapped to its Job equivalent;
  (ii) freeze Report (no new features); (iii) a "Job from this Report" migration affordance is
  *optional* — decide by usage; (iv) retire Report's run path only after the checklist closes;
  the plugin SPI survives via phase 3's bridge. `previewAll` (stubbed even in Report,
  ReportRun.kt:448) is declared subsumed-by-composition: wire an Explore before the filter.

**Steps.** (1) `groupBy` on ExportWriterWorker + tests (byte-identical A/B vs Report grouped
export over the same pre-grouped data). (2) Summary persistence + offline REST + editor fallback
(order after phase 3's schema fallback: summary-offline beats pre-scan when present).
(3) Explore offline slice REST + card fallback + persisted-count gate; extend `ExploreWorkerTest`
(post-settle slice equals a direct offline `preview`; gate visible with no trace). (4) Write the
parity checklist into `docs/architecture.md` § Job, run the composed A/B gate, and mark Report
frozen there.

**Verification.** A/B export bytes equal (composed gate); restart the JVM, open the Job —
value-set editor still offers the last run's distinct values AND the Explore card still browses +
downloads; Report suites still green (frozen ≠ broken).

---

## Phase 5 — performance + headless readiness (benchmark-first)

**Goal.** Know the Job-vs-Report throughput gap; fix the cheap hot-path losses; make every
interactive-only cost gateable so a headless run is "the same Job, minus observability" —
without designing multi-process execution yet.

**Design decisions.**
- **Benchmark before optimizing.** A JMH-free harness (plain `main` + wall clock over fixtures,
  in `kzen-auto-jvm/src/test`): (a) 1BRC-style aggregate (headerless CSV → summary/pivot),
  (b) filter + formula + export over a wide CSV. Same files through the Report pipeline and the
  Job graph. Record rows/s + allocation (via `-XX:+UseEpsilonGC` on a bounded slice or
  `GarbageCollectorMXBean` deltas). Commit the harness + a results table in the plan's as-built
  note; re-run per subsequent change. The pre-engine-rewrite harness
  (`JobExecutionTest.sliceThroughputBenchmark`, `-DjobSliceRows=<n>`) measured the batched-channel
  Job **within ~2.5% of a single-thread inline baseline at 4M rows** — that harness was lost in
  the rewrite; rebuild the equivalent and re-establish the datum on the engine.
- **Known cheap wins, apply after baseline**: hoist per-record `runBlockingIo` to per-batch
  (read up to `output.batchSize()` records inside one block — CsvReaderWorker.kt:72-77,
  MultiFileReaderWorker.kt:80-85; write a whole received batch per block —
  ExportWriterWorker.kt:94-106); presize `Producer.pending`/batch copies (JobChannel.kt:166,193).
  Do **not** pool records (ownership-transfer is the simplicity win); revisit only if the
  benchmark convicts allocation — and then use the build plan's pre-sketched shape: reuse
  bounded by channel handoff, with retaining operators (Preview, Sort) opting out by copying,
  composing with the typed-channel "typed view over a reused buffer" direction. Prefer
  arena-per-batch over free-lists.
- **Self-managed workers stay a live future direction, gated on benchmark evidence.** The raw
  `Worker` SPI deliberately keeps `suspend` out of the worker-*logic* contract, and
  `WorkerBase`'s hooks mirror an AsyncWorker lifecycle (onStart ≈ init, drive ≈ work, onClose ≈
  close) precisely so a hot stage could later be hosted by a self-managed executor (own
  thread/pool, Guava-Service style). The open problem: worker-owned threads are not on the
  engine's `CountingDispatcher`, so quiescence would have to read worker lifecycle state, not
  just `inFlight`. Do not build in this phase — record the constraint, and only design it if the
  benchmark shows a stage the coroutine model can't feed.
- **Headless = a run mode, not a fork.** A `mode` on the run start (ServerLogicController start
  param, default interactive): headless gates (a) `publishProgress` (EngineJobControl.kt:95-105
  no-ops except the final forced push), (b) the external duplex bridge + serve-channel synthesis
  (`JobChannelSynthesis.wireServe` skipped → serving workers just don't get a serve endpoint —
  `WorkerBase` already handles `serve == null`), (c) any step-wavefront affordances (nothing to
  do — checkpoint is already a fast volatile path when running). The flag rides
  `LogicCompilerServices` so flavours read it uniformly; Script/Flow ignore it for now.
  **Explicitly protect**: `JobControl` keeps zero JVM/process-coupled types so an out-of-process
  runner can implement it later. (E6 multi-run is deferred — a headless run occupies the JVM's
  single active-run slot for now; background-concurrent headless runs revive with E6.)
- Deadlock-monitor cost is fine (50 ms daemon poll of atomics); leave it.

**Steps.** (1) Harness + baseline table. (2) IO batching + presizing; re-measure. (3) `mode`
plumbing + headless gates + a headless run test (assert: no progress trace entries except finals,
no serve channels synthesized, identical output artifacts). (4) Document the measured gap and the
follow-up list (columnar batch lane? record arena?) as *data-driven* future items.

**Verification.** Benchmark table in as-built notes; headless test green; interactive Sample Job
behaviour unchanged.

---

## Phase 6 — topology: fan-out + non-linear ergonomics

**Goal.** Make branching dataflows expressible without weakening the single-reader guarantee, and
legible in the ordered-card UI. Demand-driven (master-plan push-back): the J2→J3→J4→J9 arc is
the strategic spine and should not wait on this.

**Design decisions.**
- **Fan-out via a `TeeWorker`**, not multi-reader channels. Single-reader is what makes typing,
  carryover, and close semantics tractable — keep it. `TeeWorker`: one input, `outputs:
  List<ChannelOutput>` (metadata `is: List, of: ChannelOutput`); forwards each element to every
  output. Decided: **Tee deep-copies `DataRecord`s** (`FlatFileRecord.clone` exists) and passes
  other elements by reference — correctness first, measured cost later.
- `JobChannelCreator` learns list-typed channel attributes: a `ListAttributeDefinition` of
  references → one `newProducer()` per referenced channel (JobChannelCreator.kt:94-111 dispatch
  gains the list case; `ChannelTypeDefiner` treats each list element as a producer port).
- Branch legibility without a canvas: manual channels already appear as named objects; the UI
  addition is (a) `SelectChannelEditor` shown for list ports (add/remove), (b) each *manual*
  connection rendered as a labelled chip on both endpoint cards (client derives from the same
  notation the derivation reads — no new wire format), (c) auto-wire behaviour unchanged.
  *AE coordination:* if AE5 has landed, `SelectChannelEditor` sits on `SelectReferenceEditorBase`
  — extend the migrated editor; either order works (AE5 migrates the extended editor otherwise).
- Fan-in needs nothing (multi-producer already works); worker-to-worker duplex stays manual and
  documented.

**Steps.** (1) Creator + definer list support + tests (type mismatch in one list element fails
definition; close-on-last-producer counts each endpoint). (2) `TeeWorker` + archetype + tests
(reader → tee → {explore, export}; migration carryover across both branches). (3) Client chips +
list-port editor. (4) Deadlock-monitor sanity: tee topologies with a stalled branch produce a
correct verdict (backpressure through the tee blocks the input side — assert the monitor fires).

**Verification.** New tests green; Sample Job extended with a tee branch renders sensibly.

---

## Phase 7 — interactivity remainder: transient progress emits, deadlock precision, channel occupancy

**Goal.** Close the observability gaps that remain after E7 delivered per-worker outcome chips:
stop progress emits growing history, make deadlock detection real for serving Jobs, and show
what's flowing. (Rescoped 2026-07-16 — the original "per-worker outcome chips" item was
delivered by engine phase E7: `LogicTracePath.nodeOutcome` + `JobWorkerProgress.outcome` +
the `WorkerDisplayDefault.cardHeader` chip. Verify the chip covers the kill-a-worker-mid-run
case below; only fill genuine gaps found.)

**Design decisions.**
- **Adopt `retain=false` for progress emits** (first item, mechanical): `EngineJobControl.
  publishProgress` marks the progress-marker emit non-retained per its in-code coordination note
  (the flag shipped with E4; S7 is the Script precedent — note S7 went further and made *all*
  Script emits transient because nothing read the retained ones; check the same question for
  Job's forced-final push, which the post-run card DOES read from the live map — the live map
  survives `retain=false`, history is what's skipped, so full adoption is expected safe; verify
  against `RunEngineLogicTrace` semantics). Flow's tracing emits are out of scope here (Flow
  plan owns them; `FlowNotationTest.tracedMessages` reads retained emits).
- **Outcome-chip remainder**: verify `WorkerLogic.recoverable`'s failure path routes a useful
  message into the E7 outcome surface (red chip + message on the card) for a worker that throws
  mid-run with pause-on-error off; add only what's missing (e.g. an `execution.log` of the
  failure for history/attribution if E7's outcome carries only the terminal state).
- **Deadlock precision instead of blanket suppression.** The verdict already counts only
  stream-channel blocks (JobChannel.tracked, JobChannel.kt:99-109); serve-loop coroutines park on
  the duplex channel which is *not* counted — so `blocked == active` is a true verdict even for a
  serving Job. Remove the `externallyServing` early-return (JobDeadlockMonitor.kt:70-74) **after**
  adding the missing test scenarios: serving Job idle at end-of-stream (must not fire), serving
  Job with an orphan channel (must fire), UI slice query mid-verdict-window (must not fire —
  grace absorbs). If a legitimate suppression case emerges from the tests, narrow to that case
  and document it; do not restore the blanket.
- **Channel occupancy in the pipes.** `JobChannel` gains a cheap `bufferedBatches()` estimate
  (producer-side counter incremented on send success, decremented on receive — atomics, no
  locking on the hot path beyond what exists). `JobRun` (root node) publishes a throttled
  (1/s) `$job-channels` emit — `{channelLeafName: {buffered, blocked}}` — routed via a new
  address routing in `RunEngineLogicTrace` (the E4 projection owns per-flavour address→wire
  routings now; follow the `$job-progress` precedent) to a fixed channels path;
  `JobChannelDisplay` renders fullness (thin fill bar) + blocked endpoints. Bounded payload
  (numbers only); emit non-retained from day one (the flag exists).
- **Monitor-held bridge round-trip** (JobRun.kt:224-241): E5 landed as status push, so first
  *verify* whether an async external-request path materialized; if the 1 s worst-case
  `runBlocking` under the controller monitor still stands, reduce exposure by dispatching
  `route` off the controller monitor — check feasibility; if the controller contract makes that
  unsafe, leave and record the dependency as a future engine item.
- Per-worker breakpoints/run-to: engine-supported since E3, **Script-only UI** — do not build a
  Job affordance here; demand-driven follow-up.

**Steps + verification.** As per decisions; deadlock tests are the heart (extend
`JobDeadlockTest` with the three serve scenarios); manual: kill a worker mid-run with
pause-on-error off → red chip with message (E7 surface); pipes show fill under backpressure;
history size stable across a long-running Sample Job (retain=false proof).

---

## Phase 8 — client sweep + hygiene

**Goal.** Apply the render-scoping discipline to `JobController`, kill duplicated client
boilerplate, and clear the documentation debt.

**Design decisions & steps.**
1. **Consumed-subset in `JobController`**: stop storing whole `ClientState`
   (JobController.kt:68, 241-244); keep the fields render reads (graphNotation identity for
   derivation, logicStatus bits, imperativeModel presence) with equality guards, mirroring
   ScriptController.kt:284-286. Memoize `JobChannelDerivation.derive` keyed on
   `graphNotation === last` (one helper object used by controller, `JobUpstreamSchema`, and
   `JobServeChannelResolver` alike — JobUpstreamSchema.kt:19-33, JobServeChannelResolver.kt:21-24).
2. **`JobServeChannelResolver` de-hardcode**: resolve the serve *port* by type via the shared
   derivation result (it already computes `serves`), drop `AttributeName("serve")` and the
   `substringAfterLast("/")` string surgery (JobServeChannelResolver.kt:30-31).
3. **Channel defaults from notation**: replace the six `"1024"`/`"0"` literals
   (JobChannelDefaults.kt:84,89; JobController.kt:701-708) with values resolved from the Channel
   archetype's notation (`firstAttribute` on the archetype), so job-jvm.yaml:18-19 stays the
   single source.
4. **Dedupe editor boilerplate**: shared `formatCount`/`abbreviate` utils; one add-column form
   widget (FormulaMapAdd generalized) consumed by Sort/ValueSetFilter/Pivot editors; one
   `LocalGraphStore.Observer` guard base for the seven editors. *Coordinate with
   `2026-07-14_attribute-editor-improvements.md`:* its AE3 gives
   `JobChannelNumberField`/`FormulaMapRow` the shared debounce/commit primitive and its AE5
   migrates `SelectChannelEditor` onto `SelectReferenceEditorBase` — the guard base here covers
   only the six spec editors that base doesn't, and should extend/reuse those primitives rather
   than introduce a parallel set (**prefer running this item after AE3+AE5** — master-plan
   hot-seam rule).
5. **`WorkerDisplayManager` degrades instead of throwing** on an unknown `display:` name
   (WorkerDisplayManager.kt:73-74): warn + fall back to `WorkerDisplayDefault` (a typo'd
   3rd-party marker shouldn't kill the document view).
6. **Hygiene** (note: `2026-07-21_job-element-model.md` phase 1 rewrites the
   TransformWorker/SinkWorker/ChannelTypeDefiner cast-safety kdocs — skip those here if it has
   landed): fix stale `JobExecution` references (DuplexJobChannel.kt:25-27,
   JobConventions.kt:67-76, WorkerBase.kt:88, CsvReaderWorker.kt:130+163,
   MultiFileReaderWorker.kt kdoc, job-jvm.yaml:30-32); fix the ExploreWorker YAML comment
   contradicting the persistent output dir (job-worker.yaml:381-387 vs ExploreWorker.kt:30-39);
   repoint deleted-plan references (`2026-06-23_job-paradigm.md` in JobController.kt:107-108 and
   the P4*/M* mentions in job-worker.yaml) to this plan; scope `ChannelTypeDefiner`'s port scan
   to the channel's own document instead of the whole graph (ChannelTypeDefiner.kt:127 —
   channels are document-local by construction); note duplex channels as deliberately
   un-type-checked (ChannelTypeDefiner.kt:48-49) or add the check if cheap; delete
   `JobConventions.requestParameter` if grep confirms it dead; decide `SortSpecEditor` summary
   wiring (subsumed by phase 3's schema fallback — verify, then remove its free-text apology);
   **evaluate folding `JobChildLogicHost`'s compile cache + scratch-dir registration onto the
   engine-carried resource values S2 landed** (do it if cheap, else record the decision).
7. **Pin grandchild nesting with a regression fixture.** The old `NestedLogicUnsupported`
   restriction (a hosted child could not itself host) was lifted structurally by the engine
   rewrite — `Execution.host` is uniformly recursive — but no fixture appears to exercise it.
   Add one: Job → `RunWorker` → Script whose `RunStep` hosts a further Logic; assert results,
   stepping descent, and cancellation propagate through both levels.

**Verification.** JS build + manual pass over the Sample Job (drag, insert, expand pipes, edit
specs); React DevTools highlight-updates shows no whole-document re-render on status ticks.

---

## Phase 9 — live-edit carry-forward for file-backed workers

**Goal.** Close the remaining live-edit gaps: today a pause → edit → resume is exact through
readers, channels, and in-memory accumulators, but every *file-backed* worker restarts — a
truncating writer silently **drops all rows written before the cut** (the reader resumes from
position and never re-emits them), and Pivot/Explore re-index from scratch. Sequence after
phase 4 (it touches the same Explore/Export code).

**Design decisions.**
- **The capture-before-teardown seam already exists and is the right one** — `WorkerBase.
  captureMigrationState` runs while the worker is parked, BEFORE teardown, so a live handle can
  be detached exactly as the readers do (CsvReaderWorker.kt:122-155). No framework change; this
  phase is per-worker opt-ins.
- **Writers carry an append cursor.** `CsvWriterWorker` and (uncompressed) `ExportWriterWorker`:
  capture detaches the open stream + position, config-changed guard closes and restarts (the
  readers' exact pattern). A **compressed** export cannot be appended mid-container — keep the
  restart default there, but make it *correct* instead of silent: a compressed export whose
  config is unchanged captures nothing and instead marks itself `restartRequired`, surfacing on
  the progress trace so the user knows the export file is partial and can re-run. (A
  spill-and-recompress carry is not worth the complexity.)
- **PivotWorker carries its store.** The H2-backed `PivotBuilder` lives at a deterministic
  `(runId, workerStableId)` scratch path that is migrate-stable (JobWorkPool.kt:78-80) — capture
  closes the builder (releasing the Windows file lock) *without deleting*, marks detached so
  `onClose` skips the delete (PivotWorker.kt:154-164), and the rebuilt instance reopens the same
  stores. Config-changed (pivot spec edited) → close-and-delete, restart (the accumulated pivot
  is spec-shaped).
- **ExploreWorker appends instead of clearing** on a migrate resume: capture flushes-and-detaches
  the `IndexedCsvTable`; the rebuilt instance re-adopts it and keeps appending (`onStart`'s
  clear-dir stays for genuinely fresh runs — gate on restored state being present,
  ExploreWorker.kt:88-97).
- **Surface resumed-vs-restarted on the progress trace** (adopted for *all* carrying workers): a
  `resumed` key in the first progress publish after a migrate (`"position"` / `"restarted"` /
  `"restartRequired"`), rendered by the default card — generic key, no per-type client code.
- `SortWorker`, `SummaryWorker`, `PreviewWorker` already carry (pure in-memory); readers already
  carry; `FormulaSource`/`RunWorker` correctly restart. This phase only touches the four
  file-backed workers.
- Aligns with the standing **best-effort carry-over-reset principle** (live-edit migrates state
  as-is; a stale continuation beats re-run side effects) — no validity gates beyond the
  config-changed guard.

**Steps.** (1) Writer cursor carry + tests (mid-stream migrate → output file contains every row
exactly once). (2) Pivot store carry + test (migrate mid-accumulation → final pivot equals the
un-edited run's). (3) Explore append carry + test (migrate → no duplicate/missing rows in the
persisted table). (4) `resumed` progress key + card rendering. Extend `JobMigrationTest` with
one end-to-end reader → pivot → explore → export migrate scenario.

**Verification.** New migration tests green; existing migration suites unchanged; manual: pause
a Sample Job mid-run, tweak a filter, resume — export file complete, Explore table has no gap,
cards show "resumed".

---

## Sizing

| Phase | Size | Risk | Depends on |
|---|---|---|---|
| 2 — signature/composition | M | Medium (SPI addition) | — |
| 3 — input formats + services | L | Medium | — |
| 4 — export parity + deprecation | M | Low | 3 |
| 5 — perf + headless | M (harness) + S (fixes) | Low (measure-first) | — |
| 6 — fan-out topology | M | Medium (creator/definer) | — (demand-driven) |
| 7 — interactivity remainder | M | Medium (deadlock change) | — (E4/E7 prereqs landed) |
| 8 — client sweep + hygiene | M | Low | 3 (editor fallback); prefer after AE3+AE5 |
| 9 — file-backed carry-forward | M | Medium (migration semantics) | 4 (same files) |

The strategic spine is **J2 → J3 → J4 → J9**; J5/J6/J7/J8 slot around it.

---

## Appendix — adopted from the retired build plan (2026-06-23_job-paradigm.md)

The build plan survives in git history only; everything below is the durable knowledge worth
having at hand without recovering it.

**Gotchas that will bite again if forgotten** (the first two are also in kzen-auto AGENTS.md):
- **Never add `title:` (or any attribute needing an inherited definer) to the `Channel` /
  `DuplexChannel` archetypes** — they have no `is:` parent, so an attribute that can't
  self-define fails the whole object's definition and silently **drops every channel** in the
  graph.
- **Palette-inserted workers need empty-string body defaults for channel-ref attributes** —
  a ribbon insert creates `is: <Worker>` only; without the archetype's `port: ""` body default
  the port attribute is missing rather than blank, and synthesis/derivation treat those
  differently.
- **Live progress cannot hang off a `$stable` trace path** — the trace projection resolves every
  `$stable` path's id back to a location and silently drops paths with extra segments; a
  fixed-convention path (`JobConventions.workerProgressPath`) is retained as-is. (Documented in
  JobConventions.kt:78-88; repeated here because it looks like a bug when hit.)
- **`@Reflect` workers (including test fixtures) must live in `src/main`** — KSP registration is
  main-source-set only (also in AGENTS.md).

**Design rationale to preserve (don't re-litigate in phases):**
- **Migration is rebuild-the-whole-graph, never in-place re-config.** Workers are live parked
  coroutines and cannot be re-pointed; change detection is a value-equal `objectDefinitions`
  compare, so a no-edit resume provably does not rebuild.
- **Capture-BEFORE-teardown is load-bearing**, not stylistic: it was reversed same-day from a
  post-join `loadState` because teardown's `onClose` closes a live handle before any post-join
  read could detach it. Phase 9 builds on this seam.
- **One step = one batch, uniformly.** The step grain is the checkpoint cadence; the reader once
  checkpointed per *record* while publishing per *batch*, making stepping look wedged (~4096
  clicks per visible update). Any new worker's checkpoint placement must keep the one-step ≈
  one-batch contract; `batchSize` is the user's granularity knob.
- **Channel carryover exists because pause is non-destructive but migrate teardown is** — the
  "total ≠ 1 billion" bug: buffered batches died with the torn-down graph while the resumed
  reader never re-read them. `drainBuffered`/`preload` + consumer checkpoint-before-receive is
  the exactness contract; don't weaken any of the three.
- **Frame-owned trace lifecycle**: a hosted child *invocation*'s trace buffer lives exactly as
  long as its frame — re-entry gets a fresh buffer, parallel callers get distinct buffers, and a
  completed Job-hosted child's trace is not retained (documented trade-off vs Script's
  film-strip). The pinning tests lived in the retired `JobNestedLogicTest`; when touching child
  hosting (phases 2/8), verify an equivalent pin survived the engine rewrite.
- **Known engine gap (pre-existing, out of scope here)**: concurrently-live children of the
  *same* document (possible in Job) still alias by stable id at the migration barrier — recorded
  in the S5 as-built (sprint-1 script plan); revisit if a real Job hits it.

**Superseded by the engine rewrite / later work (do not resurrect):** the step-budget model
(`MutableLogicControl`, `arm(budget, depthLimit)`, `grantStepToChildren` depth translation) →
engine node-depth step rules; `JobExecution`/`WorkerSupervisor`/`JobControlImpl`/`JobLogicHost` →
`JobRun`/`WorkerLogic`/`EngineJobControl`/`JobChildLogicHost`; the `NestedLogicUnsupported`
grandchild restriction → lifted structurally (phase 8 pins it); per-event child graph-build cost
→ `JobChildLogicHost` compile cache; scalar source/sink gap → `FormulaSourceWorker` + Preview's
untyped lane; `RunWorker` palette/editor gap → `RunTool` + `SelectLogicEditor` (job-js.yaml:196);
`RecordBatch` → framework batching + `DataRecord`; the old inFlight-only deadlock heuristic →
the channel-aware `JobDeadlockMonitor` (whose blanket serve suppression phase 7 narrows);
per-worker outcome chips → engine E7 (`nodeOutcome` + `WorkerOutcome` chip; phase 7 verifies
the remainder).
