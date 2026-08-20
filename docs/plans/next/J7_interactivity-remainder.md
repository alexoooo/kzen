# J7 — interactivity remainder — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from `../2026-07-25_job-improvements.md` Phase 7
> (rescoped 2026-07-16). Decisions are PRE-MADE in the constituent plan — this document elaborates
> them into execution-ready steps; it does not re-open them. Every anchor below was re-verified
> against current code on 2026-07-19 (post SER2–SER5 / Y / G5 / G7 / TP1 / TP3 / TP4 — drift found
> was minor: mostly ±2-line comment shifts; one substantive discovery is that the
> `job-missing-input-test.yaml` fixture is orphaned and ready-made for item (b), and one that the
> carryover fixture's `signal` suppression channel is already inert under the precise monitor).
> Master plan: `../2026-07-25_master-plan.md` ledger row 7. One session; if it runs long, split
> item (a) out as a micro-session (it is fully independent) and/or defer item (d)'s client half.
>
> ## ⚠️ Re-validated 2026-07-25 — three things moved under this plan
>
> **1. `RestHandler.kt` was deleted 2026-07-22 and split into handler services.** The one anchor
> here — `RestHandler.logicRequest` (was :1184-1208) — is now on **`LogicHandler`**
> (`server/api/handler/LogicHandler.kt`). No design consequence; the read-under-lock/use-off-lock
> pattern it cites is unchanged.
>
> **2. `JobChannel`'s element lane is now `JobMessage`, and the buffering internals moved with it.**
> Item (d)'s `bufferedBatches()` counter and the `drainBuffered` / `Producer.inFlight` reasoning
> below are still structurally right, but **re-read `JobChannel` before writing the counter** — the
> line anchors (`drainBuffered` 130-158, `inFlight` 170-171) predate the element model. The
> carryover contract itself is unchanged: buffered batches captured at migrate are live messages
> whose ownership transfers to the rebuilt graph.
>
> **3. A flavour-agnostic validation/status surface landed 2026-07-22 → 07-24 that did not exist
> when this was written.** `LogicValidationGlobal` + `ValidationStatusDisplay` (ribbon),
> `JobValidationStore` (Job publisher), `StageErrorIndicator` + `StageObjectLocator` (go-to-error).
> **Survey these before building items (b) and (d)'s client half** — part of the "surface a failing
> worker usefully" story may already be delivered, and any new client work must publish through the
> existing global rather than adding a parallel one.
>
> Also worth carrying: J2's as-built routed its **`retainTrace` and `callerStableId` findings** to
> this phase.

## Scope & goal

Close the observability gaps that remain after engine E7 delivered per-worker outcome chips:

- **(a)** stop Job progress emits growing the engine's retained history (`retain = false` adoption);
- **(b)** verify + pin the outcome-chip failure path for a worker throwing mid-run with
  pause-on-error OFF (E7 delivered the surface; only a test + a stale comment remain);
- **(c)** make deadlock detection real for serving Jobs (remove the blanket `externallyServing`
  suppression; three new test scenarios are the heart);
- **(d)** make channel state visible: `JobChannel.bufferedBatches()`, a throttled non-retained
  `$job-channels` root emit, a new trace address routing, and fill/blocked rendering on the pipes;
- **(e)** reduce the monitor-held external-bridge exposure: dispatch `engine.request` off the
  controller monitor (verified feasible and sanctioned by existing patterns).

Ground rules from the constituent plan apply unchanged: no Worker-type knowledge in any general
layer; a third-party Worker stays expressible with zero shared-code edits; run
`./gradlew :kzen-auto-jvm:test` (the `exec/job` + `objects/job` suites) plus the touched-area tests.

## Dependencies & coordination

- **Prereqs all landed**: E4 (`Execution.emit(retain:)` — kzen-lib `Execution.kt:34-45`,
  `RunEngine.kt:889-902`), E7 (`LogicTracePath.nodeOutcome` + `WorkerOutcome` chip), E5/TP4 (status
  wire: sequence/structureVersion gating), J1 (progress key constants in `JobConventions`). No
  dependency on J2–J6.
- **Flow is out of scope** for (a): `FlowNotationTest.tracedMessages` reads retained emits — only
  `EngineJobControl` changes; Flow's emit sites are untouched.
- **J8 coordination**: (d) adds state to `JobController`; follow the consumed-subset discipline
  (value-equality guard, primitives in `JobChannelDisplay` props) so J8's later sweep doesn't have
  to undo anything. Do NOT fix J8's items here (whole-`ClientState` storage, derive memoization,
  default literals) — J7 only adds beside them in the same style as the existing progress fetch.
- **Docs to sync on landing**: `kzen-auto/docs/architecture.md` §3 S7 note currently says "Flow and
  Job emits are unaffected (they still retain…)" — after (a) it must say Flow only; the same file's
  §3 REST table gains nothing ((d) rides existing trace queries). `kzen-lib/docs/logic-spec.md`
  needs no change (retain/transient semantics already specified in §7). Update the job plan's
  tracker + as-built note.
- **No kzen-lib changes anywhere in this phase.** Everything rides existing engine surface.

## Current-state findings (all anchors fresh, 2026-07-19)

Paths are relative to `C:\Users\ostro\IdeaProjects\` (repos `kzen-auto`, `kzen-lib`).

**Engine semantics (kzen-lib, read-only):**
- `RunEngine.emit` (`kzen-lib-jvm/.../exec/engine/RunEngine.kt:889-902`): under the single
  `synchronized(lock)` it bumps `sequence`, writes `runtime.live[address]` + `liveSequence`
  unconditionally, and appends to `history` **only when `retain`** (897-899). Two consequences this
  plan relies on: (1) the live latest-value map fully survives `retain = false` — history is the
  only thing skipped; (2) `emit` is safe from **any** thread (the sampler in (d) calls it from a
  daemon thread), and even a transient emit bumps `sequence` → the client's sequence-gated refetch
  still sees "run moved" (E5 contract intact).
- `RunEngine.recoverable` (737-760): on throw with pause-on-error off, `onError(e)` then rethrow;
  `runNode` (597-620) maps it to `Outcome.Failed(ExceptionUtils.message(e), stableId)` and settles
  the node `Terminal(Failed)`. `host` (634-661) rethrows a child failure as
  `LogicFailure(message, at)` preserving the originating node's id; siblings cancelled by structured
  concurrency settle `Cancelled` (605-609).
- `RunEngine.request` (385-391): reads the handler under the engine lock, **invokes it off-lock**.
  `Execution.onRequest`'s kdoc (`Execution.kt:163-167`) already requires handlers to be
  thread-safe — load-bearing for (e).

**Trace projection (kzen-auto):**
- `RunEngineLogicTrace` (`kzen-auto-jvm/.../server/exec/RunEngineLogicTrace.kt`):
  `nodeEntries` (281-310) projects each node's **live map** to wire paths and synthesizes the
  `nodeOutcome` entry from `node.status` at read time (303-308) — outcome needs no emit and
  survives post-run via the retained engine. `lookupRunHistory` (170-196) filters
  `address == null` — an addressed progress emit **never appears in the film strip anyway**, so
  retained Job progress history is dead weight nothing reads. Marker routing `tracePathOf`
  (333-338) dispatches on the address's first segment via `routingByMarker`; a non-marker,
  non-stable-id path passes `retainStoredPath` (345-356) through unchanged — a fixed
  channels path needs no mapper entry.
- Routing registration is a **hand-built list**, not autowired:
  `KzenAutoContext.kt:182-186` — `RunEngineLogicTrace(objectStableMapper,
  listOf(JobTraceAddressRouting, ReportTraceAddressRouting), …)`. The `$job-progress` precedent:
  `JobTraceAddressRouting` (`kzen-auto-jvm/.../server/exec/job/JobTraceAddressRouting.kt:12-18`)
  pairs `marker = EngineJobControl.workerProgressAddressMarker` with
  `JobConventions.workerProgressPath(stableId)`.

**Job server:**
- `EngineJobControl.publishProgress` (`kzen-auto-jvm/.../server/exec/job/EngineJobControl.kt:98-112`)
  — the coordination NOTE at 107-110 ("then mark this emit non-retained"), the emit at 111
  (`execution.emit(progressAddress, ExecutionValue.of(value))`, default retain). 200 ms per-worker
  throttle at 100-103; `force` bypasses it. The forced final push is `WorkerBase.run`'s
  `publish(control, force = true)` after `drive` (`WorkerBase.kt:63`) — it lands in the live map,
  and Job worker nodes are hosted with default `retainTrace = true` (`JobRun.kt:192-198`, no
  override), so the final payload stays readable post-run.
- `WorkerLogic` (`kzen-auto-jvm/.../server/exec/job/WorkerLogic.kt:59-66`): whole worker run
  wrapped in `execution.recoverable({ }) { worker.run(control) }`. The comment at 61-62 ("per-Worker
  error chips are a separate display gap") is **stale** — E7 delivered the chips.
- `JobRun` (`kzen-auto-jvm/.../server/exec/job/JobRun.kt`): channel resolution 106-118 (leaf name
  available as `channelLocation.objectPath.name.value`, the same keying `externalClients` uses at
  112); deadlock monitor construction 163-171 (passes `externalClients.isNotEmpty()`); worker
  launch 176-208 (monitor + clients closed in `finally` 210-213); `route` 224-241 (`runBlocking` +
  `withTimeoutOrNull` 234-240); companion `externalRequestTimeoutMillis = 1000` with the
  "KNOWN BOUNDED SEAM" note 245-252.
- `JobDeadlockMonitor` (`kzen-auto-jvm/.../server/exec/job/JobDeadlockMonitor.kt`): the
  `externallyServing` early-return is `start()` at 69-76 (constructor param 40; suppression kdoc
  28-32); `poll` 85-113 — verdict `blocked >= active` sustained `graceThreshold = 4` polls of 50 ms.
- `JobChannel` (`kzen-auto-jvm/.../server/objects/job/channel/JobChannel.kt`): `blocked` counter 66,
  `blockedCount()` 94-96, `tracked` bracket 101-109 used **only** by `Producer.flush`'s
  `channel.send` (198) and `Input.receiveBatch`'s `channel.receiveCatching` (241) — stream-channel
  ops only. `DuplexJobChannel` has **no blocked tracking at all** (its `Client.request` /
  `Server.receive` suspensions are invisible to the monitor). The serve loop is a sibling coroutine
  inside `WorkerBase.run` (46-58) parked on the duplex channel, cancelled in the `finally` when
  `drive` ends — it neither counts as blocked nor keeps the worker alive at end-of-stream. Paused
  consumers park at checkpoints, not in receives (`SinkWorker.kt:29-45` checkpoints **before**
  `receiveBatch`), which is what keeps `blocked < active` at pause wavefronts (monitor kdoc 20-26).
  `drainBuffered` 130-158 and `Producer.inFlight` 170-171 define the migration view of "what the
  channel holds".
- Channel archetype defaults (`kzen-auto-jvm/src/main/resources/notation/auto-jvm/job/job-jvm.yaml`,
  `Channel:` block): **`capacity: 0` (rendezvous is the default!), `batchSize: 1024`** — the fill
  bar in (d) must handle capacity-0 channels as the common case.
- `ServerLogicController` (`kzen-auto-jvm/.../server/service/impl/ServerLogicController.kt`):
  `request` is `@Synchronized` (421-436) and calls `state.engine.request(...)` at 435 — the whole
  worker round-trip holds the controller monitor. E5 did **not** materialize an async
  external-request path. The sanctioned read-under-lock/use-off-lock pattern already exists:
  `retainedTraceAccess` 831-840 ("the caller then reads the engine off-lock (the engine has its own
  lock)"). `statusObservers` contract 197-212: listeners are cheap thread-agnostic handoffs — safe
  to fire from (d)'s sampler thread. REST entry: **`LogicHandler.logicRequest`**
  (`server/api/handler/LogicHandler.kt` — was `RestHandler.logicRequest` 1184-1208).

**Job client:**
- `JobProgressStore` (`kzen-auto-js/.../objects/document/job/JobProgressStore.kt:33-68`): one
  `mostRecent` + one `lookupRun(LogicTraceQuery(LogicTracePath.root))` per refresh; reads per-worker
  progress from the **live merged view** (never history) and the outcome from
  `LogicTracePath.nodeOutcome(stableId)` (57-60). (d) piggybacks the channels path onto this same
  snapshot — **zero new REST round trips**.
- `JobController.refreshProgressIfNeeded` (`kzen-auto-js/.../objects/document/job/JobController.kt:288-317`):
  keyed on `clientState.clientLogicState.traceVersion()` (296) + document path; value-equality
  guard before `setState` (309-315). Channel pipes render per gap at 647-710 —
  `JobChannelDisplay::class.react` receives connection identity + effective/override
  batchSize/capacity strings (the "1024"/"0" archetype literals at 698/701/703/705 are J8's item,
  not ours).
- `JobChannelDisplay` (`kzen-auto-js/.../objects/document/job/JobChannelDisplay.kt`): pure
  `RPureComponent`; props 45-80 (all primitives/stable refs); collapsed chevron 163-229 (override
  caption 214-227), expanded card 239-354. This is where the fill bar + blocked badge land.
- `WorkerDisplayDefault` (`kzen-auto-js/.../objects/document/job/display/WorkerDisplayDefault.kt`):
  outcome chip render 158-160 + `renderOutcomeChip` 230-251 — red "Failed" chip with the failure
  message as hover `title` (247-249). `JobWorkerProgress` / `WorkerOutcome` are schema-agnostic as
  required.
- Derivation: `JobChannelDerivation.derive`
  (`kzen-auto-common/.../objects/document/job/JobChannelDerivation.kt:66-100`) returns **auto-wire
  connections only** (blank/dangling ports; manual wires excluded) — so the client-side occupancy
  key for a rendered pipe is exactly `JobConventions.autoSynthChannelName(upstreamWorker.objectPath,
  outputPort)` (`JobConventions.kt:119-121`).

**Tests & fixtures:**
- `JobDeadlockTest` (`kzen-auto-jvm/src/test/.../exec/job/JobDeadlockTest.kt`): one scenario
  (orphan-channel sink, no serve → fires), fixture `test/job-deadlock-csv-test.yaml`, driven via
  `JobLogicCompiler.compile` + raw `RunEngine` (81-102 — the template for the new scenarios).
- `JobExternalBridgeTest` (same dir): serve fixture `test/job-bridge-test.yaml` (Preview with
  manual external channel `queries`), step-to-mid-stream + `engine.request` on the root (59-109) —
  the template for (c) scenario 3 and (e)'s test. Reads live progress via
  `Address.of(EngineJobControl.workerProgressAddressMarker)` (133-141).
- `test/job-missing-input-test.yaml` is **orphaned** (no test references it) — reader with a
  nonexistent file + writer; ready-made for (b)'s failing-worker pin.
- `test/job-migration-carryover-test.yaml` carries an external `signal` duplex channel whose stated
  purpose is "only to suspend deadlock detection while the gated state is quiescent". Under the
  current precise monitor this is **already inert**: the gated sink parks in `awaitCancellation()`
  in `onStart` (`GatedCountingSinkWorker.kt:61-69` — not a channel op, not counted) while the
  source parks mid-send (counted), so `blocked(1) < active(2)` and the armed monitor would not fire
  anyway. Fixture comment is stale; test stays green after (c).
- Test-only workers use the hand-written `GatedWorkerTestModule` pattern (src/test, manual
  `ReflectionRegistry` registration — no KSP in the test source set); new fixtures for (c)/(e)
  follow it.
- `RunEngineLogicTraceTest.kt:255-295` already pins the generic `nodeOutcome` projection.

## Pre-resolved questions (the five verify-first items, answered)

### (a) retain=false adoption — VERDICT: full adoption, safe, one-line change

Evidence chain: the live map survives `retain = false` (`RunEngine.kt:889-902` — only the
`history.add` is gated); the forced final push writes the live map (`WorkerBase.kt:63` →
`EngineJobControl.publishProgress` force path → emit at 111); Job worker frames are retained
(`JobRun.kt:194-198`, default `retainTrace = true`), and the post-run card reads exactly that live
map + read-time outcome via `lookupRun` → `RunEngineLogicTrace.nodeEntries` (281-310) — never
history. Nothing reads Job progress from history: `lookupRunHistory` filters to `address == null`
events (186-187) so addressed progress emits were **already invisible** to every history consumer;
no Job client code calls `lookupRunHistory` (verified: zero hits under
`kzen-auto-js/.../document/job/`); server tests read live maps (`JobExternalBridgeTest:133-141`,
JobMigrationTest same pattern). Sequence still bumps on transient emits, so the client refetch
cadence is unchanged. S7 is the precedent (Script made *all* its step-trace emits transient for the
same "storage no reader consults" reason). Flow untouched.

**Change**: `EngineJobControl.kt:111` → `execution.emit(progressAddress, ExecutionValue.of(value),
retain = false)`, replacing the NOTE at 107-110 with a comment stating the live-map/post-run-card
contract. **Keep the teaser bounding** (`JobConventions.progressTeaserRowCount`,
`WorkerBase.progress(snapshot, force)` kdoc): the bound now protects the live-map payload and the
per-fetch wire cost (each `lookupRun` serializes the full live payload), not history — re-anchor
the three comment sites that cite "every emit is retained in engine history"
(`WorkerBase.kt:120-126`, `JobConventions.kt:108-110`, and the EngineJobControl NOTE itself).

**Proof method (history-size-stable)**: extend `JobNotationTest` (fixture
`test/job-engine-linear-test.yaml`, many batches): after the run settles, assert
`engine.history(0L).none { it.address == Address.of(EngineJobControl.workerProgressAddressMarker) }`
— and, since pure-worker Jobs emit nothing else, `engine.history(0L).isEmpty()` for this fixture —
plus the final live payload still present (writer node's live progress `count` == expected rows).
This assertion is red before the change, green after.

### (b) outcome-chip remainder — VERDICT: nothing structural missing; pin + comment only

Traced end-to-end for a worker throwing mid-run with pause-on-error OFF:
`WorkerLogic.recoverable({ }) { worker.run }` (WorkerLogic.kt:63-65) → `RunEngine.recoverable`
rethrows (749-751) → `runNode` settles the worker node `Terminal(Failed(message, stableId))`
(610-617) → `host` rethrows `LogicFailure(message, at=worker)` (656-659) → `JobRun`'s
`coroutineScope` cancels siblings (settle `Cancelled`) and the root settles
`Failed(at = failing worker)` → `RunEngineLogicTrace.nodeEntries` synthesizes
`nodeOutcome(workerStableId)` with kind+message (303-308) → `JobProgressStore` reads it (57-60) →
`WorkerDisplayDefault.renderOutcomeChip` renders the red "Failed" chip with the message as tooltip
(230-251). All present and correct; survives post-run via the retained engine.

**Decision on `execution.log`**: skip it. Job renders no history film strip (no client consumer),
the outcome already survives post-run retention, and a new run clears the prior trace by design —
a log event would be write-only. Record this in the as-built note.

**Remainder to do**: (1) a pinning test using the orphaned `test/job-missing-input-test.yaml` —
pause-on-error OFF, run → root `Outcome.Failed` with `at == reader stableId`; reader node
`Terminal(Failed)` whose message names the missing file; writer node `Terminal(Cancelled)`;
optionally one `lookupRun` assertion that `nodeOutcome(readerStableId)` carries kind=failed +
message (the wire the chip reads). (2) Fix the stale comment at `WorkerLogic.kt:61-62` to point at
the delivered surface (`nodeOutcome` → `JobWorkerProgress.outcome` → chip). (3) The manual
kill-a-worker smoke (Verification section).

### (c) deadlock precision — VERDICT: suppression removable; counting already supports it

`JobChannel.tracked` brackets **only** stream-channel `send`/`receiveBatch` (101-109 / 198 / 241).
Serve-loop parks (duplex receive in `WorkerBase.run:53-58`), duplex client waits, `host` waits,
`Execution.blocking` offloads, checkpoint parks, and test-gate latches are all invisible to
`blockedCount()` — so `blocked >= active` is a true no-progress verdict **even for a serving Job**.
The serving worker's drive is an ordinary channel consumer; at end-of-stream it settles like any
sink (the serve coroutine is cancelled in the worker's `finally`), so a completed serving run hits
`active <= 0` (poll early-out, JobDeadlockMonitor.kt:90-95) rather than a false verdict, and a
paused serving run keeps `blocked < active` because consumers checkpoint before receiving
(SinkWorker.kt:31-33). The known false-negative — a worker-to-worker duplex cycle (untracked
waits) — is accepted and documented; the monitor is stream-channel-scoped by design.

**Change**: delete the `externallyServing` constructor param (JobDeadlockMonitor.kt:40) + the
`start()` early-return (70-73) + the suppression kdoc paragraph (28-32); drop the
`externalClients.isNotEmpty()` argument at JobRun.kt:165-167 and rewrite JobRun's
"suppression signal" comment (66-67 and 158-162, 147: "Also tells the engine the run is externally
serviceable…" sentence goes). Update the stale fixture comment in
`job-migration-carryover-test.yaml` (the `signal` channel is kept but no longer suppresses
anything — verified inert above).

**The three test scenarios** (extend `JobDeadlockTest`, same compile+RunEngine template 81-102):
1. **Serving Job idle at end-of-stream must NOT fire** — fixture `test/job-bridge-test.yaml`
   as-is: `engine.resume(); engine.await()` → assert `Outcome.Success` (pre-change this proved
   nothing — the monitor never started; post-change it runs armed the whole way, including the
   EOF drain where preview is the last active worker briefly blocked on the closing channel —
   grace absorbs).
2. **Serving Job with an orphan channel MUST fire** — new fixture
   `test/job-deadlock-serve-test.yaml` = the bridge fixture (reader → preview with external
   `queries` serve channel) **plus** an orphan-channel `CsvWriterWorker` (port wired to a Channel
   no worker produces to, exactly like `job-deadlock-csv-test.yaml` — remember its
   `Files.createDirectories` preamble so the writer fails by blocking, not by open-error).
   Reader+preview complete; the writer stays `active=1, blocked=1` → assert `Outcome.Failed` with
   "deadlock" in the message. This is the case the blanket suppression silently disabled for every
   real Job (Preview/Summary/Explore/Pivot all have serve ports).
3. **UI slice query mid-verdict-window must NOT fire** — bridge fixture; step to a mid-stream
   paused wavefront exactly as `JobExternalBridgeTest:70-91`, issue the slice
   `engine.request(root, …)` (the monitor is polling throughout — a served query never increments
   `blocked`, and the paused wavefront holds `blocked < active`), then `resume()` + `await()` →
   assert `Outcome.Success` and the slice reply was served. Grace (4 × 50 ms) absorbs any
   transient all-blocked handoff during the live phase.

**If a legitimate suppression case emerges** from these tests (none is predicted by the analysis
above): narrow the guard to that precise condition (e.g. a specific endpoint-state predicate on
`JobChannel`, never a run-wide boolean), pin it with its own test, document the narrowed rule in
`JobDeadlockMonitor`'s kdoc + this plan's as-built note in the job plan, and record the decision in
the job plan's appendix (the "durable gotchas" list). Do not restore the blanket.

Implicit regressions now running monitor-armed: `JobExternalBridgeTest`, `JobMigrationTest`
(preview fixture is non-external, was already armed), `JobMigrationCarryoverTest` (verified safe
above), `JobNotationTest` — all must stay green with zero edits.

### (d) channel occupancy — full specification

**`JobChannel.bufferedBatches()`** (JobChannel.kt): add
`private val buffered = AtomicInteger(0)`; increment **after** a successful `channel.send(batch)`
in `Producer.flush` (i.e. inside the `tracked { channel.send(batch) }` bracket's success path —
after `send` returns, before `finally` clears `inFlight`); decrement after
`channel.receiveCatching().getOrNull()` returns non-null in `Input.receiveBatch` (241). Expose
`fun bufferedBatches(): Int = buffered.get().coerceAtLeast(0)` — the clamp covers the benign
rendezvous race where the receiver's decrement lands before the sender's increment.
Deliberate exclusions, documented in the kdoc: a parked-mid-send batch is NOT counted (it is
visible as a blocked producer instead — the send hasn't completed); migration `carryover` elements
are NOT counted (they drain ahead of the live stream within the first batches after resume;
`drainBuffered` runs on the dying instance whose counter dies with it, and the rebuilt channel
starts at 0). Unit-test in `JobChannelTest` (send → 1, receive → 0, multi-batch fill to capacity,
close/EOF leaves 0).

**The `$job-channels` root emit** — new class
`kzen-auto-jvm/.../server/exec/job/JobChannelOccupancySampler.kt` (AutoCloseable), the
`JobDeadlockMonitor` shape (own single-thread daemon `ScheduledExecutorService`, poll cadence
`1000 ms`):
- Constructed in `JobRun.run` with the root `execution` and a
  `LinkedHashMap<String, JobChannel>` keyed by channel **leaf name**
  (`channelLocation.objectPath.name.value` — built in the existing 106-118 resolution loop beside
  `streamChannels`; synthesized channels carry the deterministic
  `JobConventions.autoSynthChannelName` names shared with the client derivation). Not started when
  the map is empty. Closed in the same `finally` as the deadlock monitor (210-213).
- Each tick builds `Map<String, Map<String, Any?>>`:
  `{leafName: {buffered: channel.bufferedBatches(), blocked: channel.blockedCount()}}` and emits
  `execution.emit(channelsAddress, ExecutionValue.of(payload), retain = false)` — **non-retained
  from day one** — but only when the map differs from the last emitted (plain `==`): a paused/idle
  run emits nothing, so it causes no sequence churn, no SSE re-sends, no client refetch while
  parked. On `close()`, one final forced emit of the current (normally drained/zero) state so the
  post-run pipes don't freeze on a stale mid-run reading.
- The tick body is wrapped in a catch-all + a `@Volatile closed` guard: an emit racing migrate
  teardown can hit `nodes.getValue` on a cleared map (`RunEngine.kt:892`) — swallow it (an uncaught
  throw would also silently kill the `scheduleWithFixedDelay` task). This is the one real
  concurrency hazard; see Risks.
- Marker `const val channelsAddressMarker = "\$job-channels"` lives in the sampler's companion
  (mirroring `EngineJobControl.workerProgressAddressMarker` at EngineJobControl.kt:45).

**Address routing** — new object
`kzen-auto-jvm/.../server/exec/job/JobChannelTraceAddressRouting.kt`, verbatim the
`JobTraceAddressRouting` shape (JobTraceAddressRouting.kt:12-18):
`marker = JobChannelOccupancySampler.channelsAddressMarker`;
`tracePath(address, stableId) = JobConventions.jobChannelsPath()` — a **fixed** single-segment path
(only the root emits this marker, one root per run, so it is collision-free; a fixed-convention
path survives `retainStoredPath` per RunEngineLogicTrace.kt:342-356, same as the Report literal
paths — and per the appendix gotcha, a `$stable`-keyed path with extra segments would be silently
dropped, which is exactly why this is fixed-convention like `workerProgressPath`). Register it in
the hand-built list at `KzenAutoContext.kt:184`:
`listOf(JobTraceAddressRouting, JobChannelTraceAddressRouting, ReportTraceAddressRouting)`.

**Shared constants** (`JobConventions`, commonMain — beside `workerProgressPath` at 84-93):
`private const val channelsTraceSegment = "jobChannels"`,
`fun jobChannelsPath(): LogicTracePath = LogicTracePath(listOf(channelsTraceSegment))`,
`const val channelBufferedKey = "buffered"`, `const val channelBlockedKey = "blocked"`.

**Client** — zero new REST calls; all data rides the existing per-refresh `lookupRun` snapshot:
- `JobProgressStore`: add a small client-side data class
  `JobChannelOccupancy(val buffered: Long, val blocked: Long)` and change `fetchWorkerProgress` to
  return a combined result (e.g. `JobProgressSnapshot(workers: Map<ObjectLocation,
  JobWorkerProgress>, channels: Map<String, JobChannelOccupancy>)`), parsing
  `snapshot.values[JobConventions.jobChannelsPath()]` with the same numeric coercion style as
  `JobWorkerProgress.longValue` (values arrive as Long/Int/Double over the detached map codec).
  This is framework channel state, not a Worker payload — the schema-agnostic rule
  (JobWorkerProgress.kt kdoc) is not implicated; channels are not third-party-extensible.
- `JobController`: hold `channelOccupancy: Map<String, JobChannelOccupancy>` in state beside
  `workerProgress`, same value-equality guard (309-315 pattern); in the channel-gap render
  (647-710) compute the connection's leaf name via
  `JobConventions.autoSynthChannelName(connection.upstreamWorker.objectPath, connection.outputPort)`
  and thread two nullable primitive props into `JobChannelDisplay`. Manual-wire channels have no
  rendered pipe today (derive returns auto connections only) — their occupancy is emitted but
  unrendered; recorded as a known limitation resolved by J6's manual-connection chips.
- `JobChannelDisplay`: new optional props `buffered: Double?` / `blockedEndpoints: Double?` /
  keep the existing `capacity: String` (primitives so the RPureComponent shallow-equal keeps
  bailing). Collapsed chevron (163-229): a thin horizontal fill bar across the chevron's top edge —
  fill fraction `buffered / capacity` when `capacity > 0`; for the default rendezvous
  (`capacity == 0`, the archetype default per job-jvm.yaml) there is no buffer to fill, so render
  no bar and rely on the blocked badge. `blockedEndpoints > 0` → a small accent badge
  ("⏸ n" or `n blocked`) under the chevron beside the override caption, tooltip extended with
  `buffered m/N · k blocked`. Expanded card: one caption line with the same numbers. No new
  components; keep it inside the existing two render paths.

### (e) monitor-held bridge — VERDICT: E5 did not fix it; off-monitor dispatch is feasible — do it

Verified: `ServerLogicController.request` is `@Synchronized` (421-436) and invokes
`state.engine.request` (435) inline, so `JobRun.route`'s `runBlocking` +
`withTimeoutOrNull(1000)` (JobRun.kt:234-240) still runs on the HTTP thread **while holding the
controller monitor** — a slow/paused serving worker stalls `status()`/`pause()`/`cancel()` up to
1 s. E5 shipped push status only; there is no async external-request path.

Feasibility of dispatching off the monitor — **safe, by existing contracts**:
- The engine handler contract already requires thread-safety
  (`Execution.onRequest` kdoc, Execution.kt:163-167), and `RunEngine.request` reads the handler
  under the engine's own lock, invoking off-lock (385-391) — so no handler (Job, Report) may
  assume controller-monitor serialization today.
- The read-state-under-lock / use-engine-off-lock pattern is already sanctioned and documented at
  `retainedTraceAccess` (831-840).
- New races introduced are all bounded-benign: a concurrent `disposeState` (new run start / clear)
  kills the serving coroutines → the in-flight `client.request` never gets a reply → the existing
  1 s timeout returns a failure; a concurrent migrate tears the old node down → engine returns
  "No request handler for node" failure. The sharper pre-existing race (run settles while a request
  is in flight → `externalClients` closed → `requests.send` throws `ClosedSendChannelException`
  out of `route`) exists **today** (workers settle on engine threads, not under the controller
  monitor) — harden `route` with a catch-all returning `ExecutionResult.failure("External channel
  closed: …")` as part of this item.

**Change**: in `ServerLogicController`, replace `request`'s `@Synchronized` with a
`@Synchronized private fun activeState(runId): LogicState?` helper (state + settled + runId checks
under the monitor), then call `state.engine.request(NodeId(...), request)` outside it. In `JobRun`:
wrap `route`'s body in the catch-all; update the two comments that assert monitor-held execution
(224-227 "Runs on the controller thread while it holds its monitor…" and the companion note
245-252 — the timeout stays, now bounding the HTTP thread and the disposal race rather than the
monitor). Keep `externalRequestTimeoutMillis = 1000` unchanged.

**Test**: new fixture worker `SlowServeWorker` (src/test, `GatedWorkerTestModule`-pattern manual
registration) whose `onQuery` blocks ~500 ms on a latch/sleep; controller-level test: start the Job
via `ServerLogicController`, step to mid-stream, fire `controller.request` on thread A, and assert
`controller.status()` returns from thread B well before A completes (e.g. < 250 ms). Red before the
change (status waits for the monitor), green after. If writing the controller-level Job drive
proves disproportionate mid-session, the fallback pin is a pure-controller test with a synthetic
`Logic` registering a slow `onRequest` — same assertion, no Job fixture.

## Step-by-step implementation

Order: a → b → c → e → d ((a)/(b) are minutes; (d) is the bulk and lands last so a long session can
stop after (e) with everything landed still coherent).

1. **(a) retain=false** — `EngineJobControl.kt:111` add `retain = false`; rewrite the NOTE
   (107-110); re-anchor the two stale "every emit is retained" comments
   (`WorkerBase.kt:120-126` kdoc, `JobConventions.kt:108-110`); extend `JobNotationTest` with the
   history-empty + live-final-payload assertions (proof method above).
2. **(b) outcome pin** — new test (in `JobRunWorkerTest` or a small `JobWorkerFailureTest`) on the
   orphaned `test/job-missing-input-test.yaml` (assertions per (b) above); fix
   `WorkerLogic.kt:61-62` comment.
3. **(c) deadlock precision** — remove `externallyServing` (JobDeadlockMonitor.kt:40, 69-76,
   kdoc 28-32; JobRun.kt:165-167 + comments 66-67/147/158-162); add the three scenarios to
   `JobDeadlockTest` + fixture `test/job-deadlock-serve-test.yaml`; update the stale
   `signal`-channel comment in `test/job-migration-carryover-test.yaml`; run the full
   `exec/job` + `objects/job` suites (the armed-monitor implicit regressions).
4. **(e) off-monitor bridge** — `ServerLogicController.request` split (activeState helper);
   `JobRun.route` catch-all + comment updates; the slow-serve non-blocking test.
5. **(d) server** — `JobChannel.buffered` counter + `bufferedBatches()` + `JobChannelTest` unit
   coverage; `JobChannelOccupancySampler` + wiring in `JobRun.run` (leaf-name map, start-if-nonempty,
   close in finally, final emit on close); `JobChannelTraceAddressRouting` + registration at
   `KzenAutoContext.kt:184`; `JobConventions` path/key constants.
6. **(d) integration test** — gated fixture (the `job-migration-carryover-test.yaml` pattern:
   `GatedSourceWorker` → capacity-N channel → `GatedCountingSinkWorker`): resume, await the stable
   `sendsStarted == N+1` gated state (the deterministic wait the fixture was built for), then poll
   the root live map (`Address.of(channelsAddressMarker)`) up to ~5 s for the sampler tick; assert
   the leaf entry shows `buffered == N`, `blocked == 1`; assert the emit is absent from
   `engine.history(0L)` (non-retained).
7. **(d) client** — `JobProgressStore` combined snapshot + occupancy parse; `JobController` state +
   guard + gap-render threading; `JobChannelDisplay` fill bar / blocked badge / tooltip.
8. **Docs + tracker** — architecture.md §3 S7 sentence ("Flow emits still retain; Job's are
   transient since J7"); job-plan tracker checkbox + as-built note (including the (b) no-log and
   (c) no-legitimate-suppression-found decisions, or the narrowed rule if one emerged).

## Tests

The deadlock scenarios are the heart; full inventory:

| Item | Test | Fixture | Asserts |
|---|---|---|---|
| a | `JobNotationTest` (extended) | `job-engine-linear-test.yaml` | `history(0L)` empty / no `$job-progress` events; final live progress payload intact post-settle |
| b | new failing-worker pin | `job-missing-input-test.yaml` (orphaned, adopted) | root Failed `at`=reader; reader node Failed w/ message; writer Cancelled; `nodeOutcome` wire entry |
| c1 | `JobDeadlockTest.servingJobCompletesWithoutVerdict` | `job-bridge-test.yaml` | run-to-completion → Success (monitor armed throughout) |
| c2 | `JobDeadlockTest.servingJobWithOrphanChannelFailsAsDeadlock` | new `job-deadlock-serve-test.yaml` | Failed, message contains "deadlock" |
| c3 | `JobDeadlockTest.sliceQueryDoesNotTriggerVerdict` | `job-bridge-test.yaml` | mid-stream request served; resume → Success |
| c (implicit) | existing `JobExternalBridgeTest`, `JobMigrationTest`, `JobMigrationCarryoverTest`, `JobNotationTest`, `JobDeadlockTest.sinkOnUnfedChannelFailsAsDeadlock` | unchanged | all green with the monitor armed, zero edits |
| d | `JobChannelTest` (extended) | — | `bufferedBatches()` transitions incl. capacity fill, EOF→0, clamp |
| d | new sampler integration test | gated fixture pattern | `$job-channels` live entry `{buffered: N, blocked: 1}` at the deterministic gated state; absent from history |
| e | new slow-serve controller test | new `SlowServeWorker` (test module pattern) or synthetic Logic | `status()` returns while a 500 ms serve request is in flight |

Run: `./gradlew :kzen-auto-jvm:test` (whole `exec/job` + `objects/job` net), plus
`RunEngineLogicTraceTest` and the `ServerLogicController*Test` family for (e).

## Verification

- Full JVM test suite green (above).
- JS build: `./gradlew :kzen-auto-js:build -x test` (client half of (d)).
- **Manual** (`./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`, Sample Job):
  1. **Kill-a-worker red chip**: pause-on-error OFF; point a reader at a nonexistent file (or
     delete the input mid-configuration) and run → the failing worker's card shows the red
     "Failed" chip, hover shows the message; siblings show "Cancelled"; chips survive after the
     run settles (retained engine) until the next run.
  2. **Pipes fill under backpressure**: set a channel capacity override (e.g. 4) with a slow
     downstream (Sort/Pivot on a large file) → the pipe's fill bar rises and the blocked badge
     appears on the producer side while the source outruns the consumer; goes quiet (no repaint
     churn) while paused — and the default rendezvous pipe shows the blocked badge only, no bar.
  3. **Stable history size**: run a long streaming Job; the run's `lookupRunHistory` stays empty
     (observable via the REST trace action, or simply by the (a) test — no browser affordance
     renders Job history) and memory stays flat vs pre-change on the same input.
  4. **Serve still works**: expand a Preview slice mid-run (the bridge path) — slices served, no
     deadlock verdict, and `status()`/pause stay snappy while a slice is in flight.

## Risks & gotchas

- **Sampler emit vs teardown race** (d): `RunEngine.emit` → `nodes.getValue(nodeId)` throws after
  migrate clears the node map; `shutdownNow` does not await an in-flight tick. Mitigation is
  specified (volatile closed guard + catch-all in the tick); an uncaught tick exception would also
  silently kill the periodic task — the catch-all covers both.
- **Do not "optimize away" the sequence bump on transient emits** — it is what makes the client
  see fresh progress at all (E5 sequence gating). Conversely, the sampler's emit-on-change-only
  rule is what keeps a paused run from generating 1/s sequence churn (SSE re-sends + client
  refetches). Both halves are load-bearing.
- **Teaser bounding must survive (a)** — the bound now protects live-map size and per-fetch wire
  cost; dropping `progressTeaserRowCount` because "history is safe now" would regress every
  `lookupRun` response.
- **Monitor false-negatives are accepted, not bugs** (c): worker-to-worker duplex waits and
  `Execution.blocking` offloads are untracked → a duplex-cycle deadlock is not detected. Scope is
  stream channels only; say so in the kdoc.
- **Default channels are rendezvous** (`capacity: 0`, job-jvm.yaml) — the fill bar must not divide
  by zero and must still communicate backpressure (blocked badge) on the default pipe.
- **Leaf-name keying** (d): the client can only key derived (auto-wire) pipes via
  `autoSynthChannelName`; manual wires' occupancy is emitted but unrendered until J6. Do not
  invent a second name-resolution path (that's J8's `JobServeChannelResolver` complaint in
  reverse).
- **(e) race hardening is part of the change**: without the `route` catch-all, the
  closed-channel race (which exists today) becomes easier to hit once requests overlap disposal.
  The 1 s timeout must stay.
- **Fixture safety**: new/edited fixtures live under `kzen-auto-jvm/src/test/resources/notation/test/`
  — never under any `notation/main/`. `job-deadlock-serve-test.yaml`'s writer needs the
  `Files.createDirectories` preamble in the test (else it fails on open, not deadlock — the
  existing test's own gotcha, JobDeadlockTest.kt:54-58).
- **Stale-comment sweep is small but real**: EngineJobControl NOTE, WorkerBase/JobConventions
  teaser rationale, WorkerLogic chip gap, JobRun monitor-held route comments, JobDeadlockMonitor
  suppression kdoc, carryover-fixture `signal` comment — all identified above with lines; missing
  one leaves the next reader re-deriving this session.

## Out of scope

- **Per-worker breakpoints / run-to UI for Job** — engine-supported since E3 (Script-only UI);
  demand-driven follow-up, explicitly not built here.
- **Flow emit retention** (`FlowNotationTest.tracedMessages` reads retained emits) — Flow plan owns
  any change there.
- **Headless gating of `publishProgress` / serve synthesis** — J5's `mode` flag.
- **Producer-vs-consumer split of `blockedCount()`** — the decided wire shape is
  `{buffered, blocked}`; a per-side split is a possible later refinement if the badge's
  side-inference proves confusing, noted only.
- **Occupancy for manual-wire channels in the UI** — emitted but unrendered until J6's
  manual-connection chips.
- **Making the controller/trace surface per-run** (the real fix class for (e)'s remaining
  exposure) — engine plan E6, deferred; the off-monitor dispatch here is the full interim measure,
  and the JobRun companion note is updated rather than removed.
- **J8's client sweep items** touched in passing (whole-`ClientState`, derive memoization, default
  literals) — deliberately left for J8.
