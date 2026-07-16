# Logic engine improvements — phased plan

> **Status: planned.** Written 2026-07-05 from a design review of the post-rewrite Logic framework
> (`kzen-lib` `RunEngine` core + kzen-auto flavours). Executor: **Opus 4.8 xhigh, one phase per
> session.** Each phase is self-contained: it states its goal, the design decisions (already made —
> do not re-litigate), concrete steps with file anchors, and verification. Phases are ordered by
> dependency; do not start a phase whose prerequisite is unchecked.
>
> **Progress tracker** (update as phases land):
> - [x] Phase 1 — engine correctness + hot path (kzen-lib only) ✓ 2026-07-12
> - [x] Phase 2 — boundary identity (`checkpoint(at:)`, engine-owned position) ✓ 2026-07-12
> - [x] Phase 3 — breakpoints (run-to dropped — breakpoints subsume it) ✓ 2026-07-13
> - [x] Phase 4 — trace unification (retire `LogicTraceStore` bridge) ✓ 2026-07-15
> - [x] Phase 5 — push transport (SSE) + sequence-gated fetch ✓ 2026-07-15 (step budget deferred — no
>   consumer; live-view delta fetch descoped to sequence-gating — both user decisions, see as-built)
> - [~] Phase 6 — multiple concurrent runs + per-run trace retention — **DEFERRED 2026-07-16**
>   (feature not needed this release; groundwork readiness verified — see the Phase 6 deferral note)
> - [ ] Phase 7 — hardening (`Execution.blocking`, typed capture, structured failure)

## Context

The Logic framework was recently rewritten around a single-writer **`RunEngine`**
(`kzen-lib-jvm/src/main/kotlin/tech/kzen/lib/server/exec/engine/RunEngine.kt`, ~765 lines) driven by
the spec `kzen-lib/docs/logic-spec.md`. The contract (`Logic` / `Execution` / `Run` in
`kzen-lib-common/.../exec/engine/`) is sound and should not be restructured: all four kzen-auto
flavours (Script / Flow / Job / Report) adapt to it with minimal code, and stepping / migration /
resources exist once in the engine. A 2026-07-05 review found the remaining weaknesses live **below
and around** the contract:

1. **Hot path**: `RunEngine.publish()` deep-copies the whole node tree *under the engine lock* on
   every `emit`/`log`/park/release; `history(sinceSequence)` linear-scans the full event list per
   call (and the trace bridge calls it per publish → O(N²) per run); settled nodes are never evicted
   from the engine (`nodes` / `childLogic` grow per hosted child even with `retainTrace = false`).
2. **Control gaps**: `pause()` is a no-op while a step-over/out is in flight (both in `RunEngine`
   and `ServerLogicController`); checkpoints are anonymous, so the engine cannot host breakpoints or
   report "parked at X" — each flavour invents a reserved trace-address protocol (`$next-step`,
   `$job-progress`) plus a `LogicTraceAddressRouting` decoder.
3. **Duplication**: every trace value is stored twice — engine `history` plus the legacy
   `LogicTraceStore` (whose event buffers are `CopyOnWriteArrayList` — O(n) per append), joined by
   the `ServerLogicController.mirrorTrace` bridge, which exists only to preserve the pre-rewrite
   wire format.
4. **Transport**: the client polls `/logic/status` every 1.5 s and does full-snapshot trace pulls
   for Flow/Job (only Script uses the sequence watermark the engine already provides). Slow motion
   is 2+ REST round trips per boundary.
5. **Residual singletons** (acknowledged in logic-spec §2): `ServerLogicController` holds one run;
   `LogicTraceStore` has a run-global `clearAll`.

What is deliberately **not** on this plan: per-message checkpoints or intra-batch observability
(the batch-as-boundary pattern — Job at 1024/batch, Report per Disruptor feed poll — is the correct
speed/steppability trade and stays); distribution/cross-process; revert/branching of mid-run edits
(spec'd out).

## Ground rules for every phase

- **The spec leads.** `kzen-lib/docs/logic-spec.md` is a living spec; behaviour changes in a phase
  must update the relevant § in the same session (breakpoints and step budget are *new*
  requirements — add them, don't bolt them on silently). Update `kzen-lib/docs/architecture.md` and
  `kzen-auto/docs/architecture.md` §1/§3 where wire/control behaviour changes.
- **No flavour-specific code in general layers.** No `when` over Script/Flow/Job/Report in
  `RunEngine`, `ServerLogicController`, `LogicCompiler`, or any shared client code. Extension points
  are archetypes (`LogicDocument`), autowired lists (`LogicTraceAddressRouting`), and notation. This
  is the project's standing "god object" rule.
- **Dev loop**: kzen-auto consumes kzen-lib from **mavenLocal**. After any kzen-lib change:
  `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`. Open kzen-auto as its own IntelliJ project (not via the umbrella).
- **Verification baseline** (every phase): kzen-lib `./gradlew :kzen-lib-jvm:test`
  (`RunEngineTest` is the engine's behavioural suite — 12 tests covering stepping, quiescence,
  migration, resources, retainTrace); kzen-auto `./gradlew :kzen-auto-jvm:test` (Job suite:
  `JobNotationTest`, `JobDeadlockTest`, `JobExternalBridgeTest`, `JobMigrationTest`,
  `JobBatchingTest`, `JobChannelCarryoverTest`, `JobRunWorkerTest`, `JobScratchDirTest`).
  UI-facing phases: `./gradlew :kzen-auto-test:selfTest` (opt-in, opens Chrome; **beware a stale
  tester JVM already bound to port 18081 — kill it first or failures are baffling**), plus a manual
  `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` smoke of Script + Job pause/step.
- **Wire changes** ship both sides in the same phase (server + `CommonRestApi` + JS client) —
  there is no cross-version compatibility requirement, but never leave the client reading a path the
  server stopped writing.
- Mark the phase checkbox in this file's tracker when done, and append a short "as-built" note to
  the phase section if the implementation deviated from the plan.

---

## Phase 1 — Engine correctness + hot path (kzen-lib only)

**Goal:** make boundaries and emits cheap and fix the pause-during-stepping gap, without any
contract change visible to flavours. Entirely in `kzen-lib` (+ a two-line kzen-auto controller fix).

**Why first:** everything later (denser checkpoints, engine-served traces, push transport) assumes
`emit`/`checkpoint` are near-free and engine memory is bounded.

### 1a. Pause overrides stepping

`RunEngine.pause()` currently only acts `if (command == Command.Running)` (RunEngine.kt:185) — a
long step-over (e.g. over a `RunStep` running a 10-minute sub-script) cannot be paused, only
cancelled. Change: `Paused` overwrites `SteppingOver`/`SteppingOut` too (any non-cancelling
command). Mirror the fix in `ServerLogicController.pause()`
(`kzen-auto-jvm/.../server/service/impl/ServerLogicController.kt:327-351`): the `state.running`
branch must also cover `state.stepping` (set `pauseRequested`, call `engine.pause()`; the in-flight
drive task's `awaitQuiescent` then converges as usual). Add a `RunEngineTest` case: step-over a
child that loops many boundaries, pause mid-step, assert the run settles `Suspended(Boundary)`
before the child completes.

### 1b. Lazy snapshot (kill publish-per-event tree rebuild)

`publish()` (RunEngine.kt:694-701) rebuilds the entire immutable tree under `lock` on **every**
emit/log/park/release. Replace with a dirty flag:

- `emit`/`log`/`park`/release/settle set `dirty = true` under the lock (still bump `sequence`,
  still append history) and notify observers **without building a snapshot**.
- `snapshot()` builds (and caches) the tree under the lock only when dirty. `@Volatile published`
  stays as the cache.
- Change `Run.observe` to a payload-free signal: `fun observe(listener: () -> Unit): AutoCloseable`
  (deliberate contract simplification — the only production observer,
  `ServerLogicController.mirrorTrace`, already ignores the passed snapshot and re-pulls by
  watermark; consumers that want state call `snapshot()`). Update `Run.kt` kdoc: notifications are
  coalescing-safe, may arrive concurrently, and carry no ordering guarantee — pull `snapshot()` /
  `history()` for state. Fix `RunEngineTest` observers accordingly.

This also dissolves the pre-existing out-of-order observer delivery race (snapshots were built
under the lock but delivered off it).

### 1c. Watermark index for `history(sinceSequence)`

The list is sequence-ordered (single writer); replace the full `filter` (RunEngine.kt:270-274) with
a binary search for the first index `> sinceSequence` + `subList` copy. Called per publish by the
bridge, so this turns O(N²)/run into O(N log N).

### 1d. Engine-side frame compaction (bound streaming runs)

Settled nodes currently stay in `nodes` / `childLogic` / `parent.children` forever — a streaming
host (`RunWorker`: one hosted child per element, `retainTrace = false`) leaks a `NodeRuntime` + a
compiled `Logic` per element, and every retained `live` map inflates every snapshot build. Design
decision (coordination with the trace bridge is the subtle part — the bridge currently *scans
snapshots* for terminal `retainTrace = false` nodes, so the engine must not remove them before the
bridge has seen their final events):

- Extend the observer contract with an explicit frame-close signal instead of snapshot-scanning:
  `RunEngine` invokes, at `settleNode` time and after the final events are in `history`, a
  registered `onFrameClosed(node: Node)` callback (second parameter of `observe`, or a dedicated
  `observeFrames` — implementer's choice) carrying the closed node (id, stableId, retainTrace,
  status).
- In the same settle, for **every** settled child: remove its `childLogic` entry (the compiled
  Logic is never used after `host` returns; `migrate` already clears the map wholesale). For
  settled children with `retainTrace = false` only: remove the `NodeRuntime` from `nodes` and its
  id from the parent's `children` (full compaction — it disappears from subsequent snapshots; its
  history events remain in `history` untouched).
- `ServerLogicController`: replace `evictClosedFrames` + `LogicState.evictedNodes`
  (ServerLogicController.kt:608-631) with the frame-close callback → `logicTraceStore.evict(...)`.
  Note the callback fires on an engine dispatcher thread — keep the store eviction lock-cheap.
- Retained frames (default, `retainTrace = true`) are **not** compacted — the RunStep screenshot
  strip and post-run review depend on them; the run root is retained by construction.

Add `RunEngineTest` cases: (1) a host loop of 1000 `retainTrace = false` children leaves `nodes`
size O(live frames) and the snapshot tree without the settled children; (2) `retainTrace = true`
children still appear in snapshots after settling; (3) frame-close fires exactly once per frame
with final status. In kzen-auto, re-run `JobRunWorkerTest` + a manual streaming Job to confirm
trace-store eviction still happens.

### 1e. Micro: cache immutable per-node fields

`ExecutionImpl.checkpoint()` takes the lock twice per boundary (`depthOf` then `checkpoint`);
`inputs` locks per access. `depth`, `inputs` are immutable per node — capture them in
`ExecutionImpl` at construction (RunEngine.kt:720-764).

### 1f. Event-driven live-edit detection

`ServerLogicController.pendingMigration` recomputes and compares the whole transitive-closure
notation map on **every** drive (ServerLogicController.kt:745-768) — slow motion pays it per tick.
Add a `graphStore.observe(...)` subscription in `ServerLogicController` (it already receives
`graphStore`) that sets a `@Volatile editDirty = true` on any notation command; `pendingMigration`
returns null immediately when clean, does the (unchanged) closure compare + recompile when dirty,
and clears the flag when the compare says no effective change or a migration is taken. Coarse
over-triggering (an edit to an unrelated document sets the flag) is fine — the closure compare is
the precise second stage.

**Out of scope for phase 1:** any `Execution`/wire signature change beyond `observe`; trace store
internals; client code.

**Verify:** full baseline suite; add a coarse perf guard to `RunEngineTest` (e.g. 100k emits on a
10-node tree completes in single-digit seconds — generous bound, just catches O(N²) regressions).

**As-built (2026-07-12):** landed as planned, with these implementation choices: the frame-close
observer is a dedicated `RunEngine.observeFrames` (jvm-only; the common `Run` contract stays minimal —
the controller holds a `RunEngine`-typed field), gated on `!migrating` like publish (migration
supersedes frames, it doesn't close them); compaction removes the settled subtree from `nodes` +
`childLogic` via `removeSubtree` after `disposeResources` (which reads the node map); an `internal
nodeCount()` accessor supports the bounding test. 1f: `ServerLogicController` implements
`LocalGraphStore.Observer` itself (matching the `objectStableMapper` precedent), registered in
`KzenAutoContext.init()`; the flag is cleared before the closure compare and re-set on the recompile
catch path. The two controller migration tests fabricate edits out-of-band (local `NotationReducer`,
never through the store), so they now hand the controller the store notification production would have
delivered (`runBlocking { controller.onStoreRefresh(edited) }`) before the edited release — note the
Job-flavour one passed vacuously without it (its sample-size edit doesn't change the row count).

---

## Phase 2 — Boundary identity: `checkpoint(at:)` + engine-owned position

**Goal:** checkpoints carry the stable id of the element they settle on, so the engine — not each
flavour — knows each node's current position. Retires the `$next-step` reserved-marker protocol.

**Prerequisite:** Phase 1.

### Design decisions

- `Execution.checkpoint(at: ObjectStableId? = null)` (default keeps every existing call site
  compiling). The engine records `at` on the `NodeRuntime` as `position` **whether or not it
  parks** — position = last boundary reached; exposed as `Node.position: ObjectStableId?`.
- `LogicRunFrameInfo` (kzen-lib-common `exec/logic/run/model/`) gains
  `position: ObjectLocation?` (resolved via `ObjectStableMapper` in
  `ServerLogicController.nodeToFrame`, same as the frame's own location). Extend the LogicStatus
  wire serialization both sides (`LogicConventions` / whatever `CommonRestApi` carries it in — find
  the existing to/from-collection codecs next to `LogicRunFrameInfo` and extend symmetrically).
- **Script**: `ScriptRunContext.runSteps` passes the step's stable id:
  `execution.checkpoint(stableId)` (ScriptRunContext.kt:184). Delete `publishNextStep`, the
  `$next-step` constant (ScriptRunContext.kt:58), and `ScriptTraceAddressRouting`; remove that
  routing from the composition-root list (`KzenAutoContext`). JS: the "next to run" highlight
  (`ScriptProgressStore` / `ScriptStore` — grep for the next-step trace path constant in
  `kzen-auto-common` `ScriptConventions` or equivalent) switches to reading `position` off the
  frame in `LogicStatus`. Note the client gets position for free on every status poll now — no
  trace fetch needed for the highlight.
- **Flow**: `FlowRun` passes the about-to-run vertex's stable id at its checkpoint
  (FlowRun.kt:120). If the Flow UI derives "next vertex" from vertex trace models today, leave that
  rendering as is (positions become available for later use); do not refactor Flow display beyond
  compiling.
- **Job**: workers keep `checkpoint()` (null `at`) — a worker node's position is itself; no change.
- Spec: update logic-spec §4 "What a boundary is" — a boundary *may* name the element it settles
  on; the engine records it as the node's position and surfaces it in the run snapshot.

**Out of scope:** breakpoints (phase 3); any trace-store change.

**Verify:** baseline suites; `RunEngineTest` addition asserting `position` tracks across
park/release and shows in snapshots; manual UI check that the Script next-step highlight behaves
identically (including inside `MultiStep` branches and after rename-while-paused — position is
stable-id-keyed so rename survival must hold); selfTest.

**As-built (2026-07-12):** landed as planned, with two clarifications. (1) Anonymous checkpoints
(`at = null`) **preserve** the last recorded position rather than clearing it — the `StepExecution`
SPI forward (`ScriptRunContext.checkpoint()`) is no-arg, so a step's internal pausability checkpoint
must not blank the highlight; position clears only by node settling (terminal frames are pruned from
the status frame tree, which is what clears the client highlight after completion). (2)
`StepNavigationTest.assertNextToRun` turned out to be a *functional* reader of the retired marker
(not just a comment): rewritten to read `LogicRunFrameInfo.position` off `status()` via a local
deepest-frame-per-document search mirroring the client's `LogicRunFrames.frameForDocument`. Client
side, `ScriptProgressStore.refresh` stashes `activeFrame?.position` as `ScriptProgressState.nextToRun`
(null on the inactive/post-run and error paths) and `computeStepTraceInfo` compares it against the
step's `ObjectLocation`. The Job/Report reserved-marker routings (`$job-progress`, `$trace-path`)
are untouched. Baseline + selfTest green; the manual `FrontendDevelopment` highlight smoke
(MultiStep branches, rename-while-paused) remains for the operator.

---

## Phase 3 — Breakpoints + run-to-element

**Goal:** engine-level breakpoints (click-the-gutter) and "run to here", as pure engine policy over
the positions introduced in phase 2. Small phase.

**Prerequisite:** Phase 2.

### Design decisions

- Engine state: `breakpoints: Set<ObjectStableId>` (replace-set semantics) + an optional one-shot
  `runToTarget: ObjectStableId?`. `Run` gains `setBreakpoints(ids: Set<ObjectStableId>)` and
  `runTo(target: ObjectStableId)` (= set one-shot target + resume, atomically under the lock).
- Check in `checkpoint(nodeId, depth, at)` inside the existing `synchronized` block: if `at != null`
  and (`at == runToTarget` → clear target, park `Explicit`) or (`at in breakpoints` and the command
  is `Running` or a stepping command whose rule would *not* park here) → park with
  `PauseReason.Explicit`. Explicit is deliberate: the client's auto-step loop stops on Explicit
  (spec §4), so slow motion halts at breakpoints for free.
- Breakpoints are **run-scoped and volatile** (cleared with the run, not persisted to notation) —
  the UI re-pushes them on run start. Document this in the spec §4 addition.
- REST: two endpoints in `CommonRestApi` + `RestHandler` + `KzenAutoMain` route wiring
  (`/logic/breakpoints` PUT with a stable-id list resolved from ObjectLocations via
  `ObjectStableMapper`; `/logic/runTo`). `ServerLogicController` passthroughs (addressed by runId
  like every other command).
- JS: gutter toggle on Script step displays (a dot on the step card header; state kept in
  `ScriptStore` per document, pushed on toggle and on run start via `ClientLogicGlobal`), and a
  "run to here" action in the step's context/hover menu enabled while paused. Flow vertices can get
  the same affordance if trivial; otherwise Script-only this phase and note it.

**Verify:** `RunEngineTest`: breakpoint parks a full-speed run with `Explicit` at the right
position; run-to skips other boundaries and clears its one-shot; breakpoint inside a hosted child
(stepping command active) still parks. Manual UI: toggle a breakpoint mid-run; slow-motion stops on
it; selfTest.

**Cross-reference:** the move-to-step plan (`2026-07-10_execution-control.md`) composes with this
phase's positions and shares the per-step affordance home ("Run to here" / "Set next step here"
are adjacent menu items — coordinate whichever lands second).

**As-built (2026-07-13):** landed with these deviations. (1) **runTo dropped entirely** (user
decision): no `runToTarget`, no `/logic/runTo`, no "run to here" UI — breakpoints subsume it (add
a breakpoint at the target, Run, remove it); the XC plan's phase-3 coordination note was updated
accordingly. (2) **Breakpoint hit parks `Explicit` regardless of the in-flight command** — the
design bullet's "or a stepping command whose rule would *not* park here" contradicted its own
rationale: the slow-motion loop only halts on `isHaltPaused()` (Explicit/Error), so a would-be
Boundary settle on a breakpointed element is upgraded to Explicit. Accepted side effect: a manual
Pause that settles exactly on a breakpointed boundary reports ExplicitPaused. (3) **Stop-the-world**
(user decision): the breakpoint park also drops the engine command to Paused, so concurrent spines
park at their next boundary and the run settles quiescent (mirrors `pause()`). (4) **Start-time
breakpoints ride `/logic/startRun`/`/logic/startStep`** as repeated `breakpoint` params set between
`start()` and the drive — race-free for the earliest steps; the `PUT/GET /logic/breakpoints`
endpoint handles mid-run replace-sets; PUT twins added for the start routes (long lists overflow
the GET URL limit). (5) **Client state is stable-id-keyed in `ClientLogicState.breakpoints`**
(registry + push in `ClientLogicGlobal`, dot rendered by `StepHeader`/`ScriptStepDisplayDefault`),
NOT per-step `ScriptStepState`: the `steps` map's ObjectLocation keys are never migrated on rename
and the unmount-when-gone prune fires on rename, which would silently detach a dot from a step the
engine still stops at; the client `ObjectStableMapper` rename-tracks ids for free. `setBreakpoints`
sits on the common `Run` interface (a §4 control verb); the controller passthrough is non-interface
(the `startStep`/`setPauseOnError` precedent); `ObjectStableMapper.objectLocationOrNull` was added
for the deleted-step prune at push time. (6) **Script-only UI** (user decision): Flow works at the
engine/REST level (vertices checkpoint stable ids since phase 2) but has no toggle UI; If/Loop/
DoWhile branch headers (`DoWhileStepDisplay`/`BranchHeaderSlab` StepHeader hosts) also not wired —
the dot renders only where the new optional StepHeader props are passed. Both are trivial
follow-ups.

---

## Phase 4 — Trace unification: retire the `LogicTraceStore` bridge

**Goal:** one trace store — the engine. Delete the double storage
(`mirrorTrace` / `LogicTraceStore` buffers / `LogicTraceHandle`), serving the existing REST trace
queries from `RunEngine` history + node tree. **This is the riskiest phase; budget a full session
and lean on the survey step before touching anything.**

**Prerequisite:** Phase 2 (the `$next-step` marker is already gone; fewer routings to translate).

### Design decisions

- **Wire compatibility, translate at query time.** Keep the existing REST endpoints and the wire
  model (`LogicTraceSnapshot` / `LogicTraceEvent` / `LogicTracePath` / `LogicTraceQuery`,
  `lookupRun` / `lookupRunHistory` / `lookupRunExecutions` / `mostRecent`) so the JS client is
  untouched except where noted. The per-flavour path conventions currently applied at *write* time
  by `mirrorTrace` + `LogicTraceAddressRouting` (`$job-progress` → `workerProgressPath`, Report's
  paths) move to *query* time: the same autowired routing objects translate engine
  `(nodeId, stableId, address)` → wire `LogicTracePath` when answering a query. No flavour `when`.
- **The engine outlives its run** (this is what makes retirement possible — today post-run review
  is served by the store after `clearState` drops the engine). Split `RunEngine.close()` into
  `shutdown()` (stop the `CountingDispatcher` pools; called when the run settles terminal — a
  settled engine's history/tree stay readable, all reads are lock-or-volatile, no threads needed)
  and `dispose()` (full teardown incl. `sweepOrphans`; called when the run is replaced or the
  controller closes). `ServerLogicController.settleAfterDrive` stops clearing state on terminal;
  the retained `LogicState` *is* the most-recent-run record; `start()` disposes the prior one
  (preserving today's "new run wipes the old trace" semantics — now for free, no `clearAll`).
- **Rename survival**: events and nodes carry `ObjectStableId`; resolve to current
  `ObjectLocation` at query time via `ObjectStableMapper` (exactly what the store does today).
- **Re-entry ghost-clearing** falls out structurally: each invocation of a sub-logic is its own
  node with its own `live` map, and frame-keyed queries hit that node. The **run-merged** view
  (`lookupRun`) = fold of all nodes' live maps, latest `sequence` wins.
- **Transient emits ship here** (recorded per script-plan phase 7 and job-plan phases 1/7, which
  adopt it): once traces are engine-served, `Execution.emit` gains `retain: Boolean = true` — a
  non-retained emit updates the node's `live` projection (and notifies) without appending to
  retained history. This phase adds only the flag + engine semantics + a `RunEngineTest` case
  (non-retained emit visible in `live`/run-merged views, absent from `history`); Script's
  Running/marker emits and Job's throttled progress-marker emits flip to `false` in their own
  plans' phases, not here.
- **Survey first, then cut.** Step 1 of the session: enumerate *every* caller of `LogicTrace`,
  `LogicTraceHandle` (including `handle.clearAll(prefix)` — the "Clear all traces" UI action and
  any loop-iteration live-reset), the `LogicTraceEndpoint` detached actions, and the JS call sites
  (`ScriptProgressStore`, `FlowProgressStore`, `JobProgressStore`, `ClientLogicGlobal` trace
  clearing). Produce the semantics table, then implement the engine-backed `LogicTrace` against it.
  Any behaviour that has no engine equivalent (e.g. a prefix live-clear) gets an explicit engine
  affordance (`RunEngine.clearLive(nodeId, addressPrefix)` writing a tombstone event so the
  history/live projection stays one stream) — do not silently drop semantics.
- Deletions when green: `LogicTraceStore`, `mirrorTrace`, `handleForNode`/`nodeHandles`,
  `bridgeLock`/`bridgedSequence`, the store side of `evict`. `LogicTraceHandle` goes if the survey
  finds no remaining writer (flavours write via `Execution.emit`/`log` already).
- Spec: update the §7 appendix rows (trace store → engine-served) and the architecture docs' trace
  sections.

**Verify:** the full baseline suite plus, manually: Script per-step values + screenshot film strip
(incl. a loop — history retention across iterations), RunStep-scoped strips (execution-tree
attribution via `callerStableId`), Flow vertex displays, Job worker progress + Preview pull path,
post-run review after terminal, rename-while-paused, "Clear all traces". selfTest. Watch heap on a
long streaming Job (should be ~half of pre-phase).

**As-built (2026-07-15):** landed as designed (see `kzen/plans/2026-07-10_master-plan.md` executor
notes → the E4 plan file). Key realizations:
- **Value projection source = `Node.live`, not a history fold.** `resetEmitted` clears `live` but keeps
  history, so folding history would ghost reset values. Added a **parallel** `Node.liveSequence:
  Map<Address, Long>` (trailing defaulted; `Node.live` type unchanged so its ~20 `RunEngineTest` + 3
  kzen-auto readers stayed untouched), maintained beside `live` in `emit`/`resetEmitted`/
  `clearLiveSubtree`/`buildNode`. Wire `LogicTraceEntry.sequence` comes from it; `time` is **synthesized
  at query time** (`Clock.System.now()`) — the client orders by sequence, never time, and the engine hot
  path stays clock-free (Phase-1 intent). `TraceEvent.time` deferred as a trivial follow-up if ever needed.
- **`emit(retain: Boolean = true)`** added (transient live-only emit; `retain=false` skips `history.add`).
  Ships the flag + one `RunEngineTest` case only; flavours flip specific emits in S7/J7.
- **`RunEngine.shutdown()` (pools only) / `dispose()` (`sweepOrphans` + pools)** split; `close()` →
  `dispose()`. A settled engine's `snapshot`/`history` are pure locked reads, so the controller **retains**
  the settled run (a new `LogicState.settled` flag; `settleAfterDrive` calls `shutdown()` and keeps
  `stateOrNull`; `start()` disposes a retained-terminal state, refuses only an active one). `status()`
  reports a `settled` run as no-active-run (load-bearing: `KzenAutoContext.anyRunActive` storage-eviction
  gate + ~13 `awaitDone` test loops). Control methods guard via `stateOrNull?.takeIf { !it.settled }`.
- **The whole observer bridge retired** (`mirrorTrace` + `onTraceReset` + `onFrameClosed` +
  `handleForNode`/`nodeHandles`/`bridgeLock`/`bridgedSequence` + the 3 bridge fields). Trace queries are
  served by a new **`RunEngineLogicTrace : LogicTrace`** (kzen-auto `server/exec/`) that projects the
  controller's retained engine — `tracePathOf` + `retainStoredPath` ported verbatim; `lookupRun` keeps
  **only the latest node per stable id** (the generic reproduction of the store's re-entry clearing —
  necessary for non-loop sequential re-invocation, redundant-but-harmless for loops where `dropReplay`
  already cleared). `LogicTraceEndpoint` changed only its `@Service` type (`LogicTraceStore` → `LogicTrace`).
- **`LogicTraceHandle` STAYS** (Report's `ExecutionLogicTraceHandle` write adapter). Deleted:
  `LogicTraceStore` + `LogicTraceStoreResetTest` (kzen-lib), `LogicTraceStoreExecutionTreeTest` (kzen-auto,
  pure store unit test); rewrote `LogicTraceStoreRenameTest` → `RunEngineLogicTraceTest` (hand-driven
  engine + fake `RunTraceAccess`); redirected 8 integration tests' `context.logicTraceStore` →
  `context.logicTrace`. `:kzen-lib-jvm:test`, `:kzen-auto-jvm:test`, and `:kzen-auto-test:selfTest` green.
- **Deferred to S7/Phase 5** (noted, not a regression): the engine keeps `log` events of compacted
  `retainTrace=false` frames in `history`, so `lookupRunHistory` includes them (the store evicted them).
  Low impact today (Job workers emit progress via `emit`, not `log`); history bounding is S7.

---

## Phase 5 — Push transport + incremental fetch + slow-motion step budget

**Goal:** the "visually iterative" latency work: replace 1.5 s polling with server push, make
Flow/Job trace fetches incremental, and let slow motion run at engine pace.

**Prerequisite:** Phase 4 (engine-served traces make the watermark universal).

### Design decisions

- **SSE, not WebSocket** (one-directional server→client is all that's needed; SSE rides the
  existing HTTP/proxy path incl. kzen-shell prefixing). New Ktor route `/logic/events` streaming
  small JSON events: run state transitions and a trace high-water `sequence` per active run —
  signals only, no payloads; the client reacts by running its existing fetch logic. Server side:
  the phase-1 `observe` callback feeds a conflating channel per SSE connection (drop intermediate
  signals, latest wins).
- Client (`ClientLogicGlobal`): subscribe via `EventSource` when a run is active; on signal, run
  the same refresh that the 1.5 s timer runs today. **Keep the poll loop as fallback** at a relaxed
  10 s cadence (SSE drop / proxy buffering resilience). Trigger stores off the sequence
  high-water instead of `LogicStatus.time` where they currently key on wall-clock
  (`ScriptStore`/`JobController.refreshProgressIfNeeded`).
- **Incremental everywhere**: `FlowProgressStore` and `JobProgressStore` adopt the same
  `sinceSequence` watermark pattern `ScriptProgressStore` already uses (reset watermark on run-id
  change; the engine-backed store from phase 4 serves it uniformly).
- **Step budget**: `Run.step(mode, count: Int = 1)` — the engine executes N park/release cycles
  server-side (each qualifying spine advancing one boundary per cycle, settling between) before
  reporting settled. `ServerLogicController.drive` + REST gain the count parameter. The client's
  slow-motion loop can then issue one REST call per N boundaries at high speed settings while
  keeping its 750 ms dwell pacing at human settings. Phase-1's pause-override makes a large budget
  interruptible; a breakpoint/Explicit/Error park aborts the remaining budget (checked between
  cycles). Spec §4: auto-run stays client-*paced*; the budget is an amortization, not an engine
  auto-run.
- Update `kzen-auto/docs/architecture.md` §3 ("no WebSocket or SSE channels" and the poll-based
  gotcha) — this phase changes both statements.

**Verify:** baseline; manual: live Script run updates visibly faster than 1.5 s; kill the SSE
connection (devtools) and confirm fallback polling keeps the UI alive; slow motion at max speed
visibly outpaces the old 2-RTT-per-step ceiling; Job worker progress stays smooth (server-side
200 ms/worker throttle in `EngineJobControl` unchanged). selfTest.

**As-built (2026-07-15).** Transport decision (SSE) held; the phase's *shape* changed after exploration.

- **The 1.5 s poll was not the cost driver — a wall clock was.** `status()` stamped
  `time = Clock.System.now()` per call and **eight** client sites (not the two this plan named) keyed
  trace/progress re-fetch on it, so every poll re-pulled full trace snapshots regardless of whether
  anything happened, and each 50 ms `awaitStepSettled` poll did too (~`1 + N + 4N` requests per
  slow-motion boundary). **Ordering consequence: this had to land before push**, or push would have
  *amplified* traffic (a full re-fetch per pushed event). It is also the bigger win alone — an idle or
  paused run went from ~5–9 requests/1.5 s to **zero**.
- **`time` → `epoch` + `LogicRunInfo.sequence`, and a plain delete would have regressed.** Two of the
  eight sites (`HeaderRunController` Clear-button enablement, `ProjectController` sidebar markers) plus
  the clear-trace repaint *depend* on the timestamp bumping: `status()` reports `active == null` both
  before and after a clear, so a `(runId, sequence, state)` key alone is identical across it and nothing
  repaints to empty. Hence the controller **epoch**, which bumps with no active run. One shared client
  rule, `ClientLogicState.traceVersion()`. Both `Long`s serialize as strings (the existing
  `LogicTraceEvent.sequence` convention, which dodges JS `Long` round-tripping).
- **Observe the CONTROLLER, not an engine** (this plan said "the phase-1 `observe` callback feeds a
  conflating channel per SSE connection"): an engine-scoped subscription cannot see run replacement /
  clear / no-run-yet, and `shutdown()`/`dispose()` never clear observer lists, so per-connection engine
  subscriptions would miss their run *and* leak. The controller holds one subscription per run and fans
  out via `observeStatus`.
- **The settle needs its own announcement.** The engine publishes its park *before* `settleAfterDrive`
  runs, while `stepping` is still set — so the engine signal reports Stepping, never Paused, and the
  `Stepping → Paused` edge (what the slow-motion loop waits on) would never be pushed. Every accepted
  control verb also announces, via a uniform `submitted()` helper; over-announcing is free because the
  route re-sends only when the serialized status differs.
- **Payload = the full `LogicStatus`, not "signals only"** — a bare signal costs a status RTT per event,
  reintroducing exactly the round trip this phase removes. It reuses the existing codec, so SER4 still
  migrates it once.
- **Fallback is delivery-proven, never connection-proven** — a buffering intermediary opens the stream
  and delivers nothing, indistinguishable from healthy-idle. Health is set only by an arriving message
  (the server's on-connect status is the probe); 3 s probe, 45 s `ping` watchdog, and the degraded floor
  is exactly the pre-push 1.5 s. Heartbeat hand-rolled at 15 s (Ktor's *default* 30 s would race a 30 s
  socket timeout). Subscription is **visibility-gated** — the ~6-per-origin HTTP/1.1 cap is shared across
  every tab of the origin (the shell serves the launcher and every project from one).
- **Cross-repo: kzen-shell needed a fix this plan did not know about.** Its shared CIO client had no
  `HttpTimeout`, so CIO's default `requestTimeout = 15000` truncated *any* proxied response at 15 s
  (its SSE/upgrade exemptions all miss a plain `prepareRequest`). SSE would have worked perfectly in the
  dev loop and died every 15 s in the packaged product. Now `INFINITE_TIMEOUT_MS` + a finite 60 s socket
  timeout; also fixes proxied downloads >15 s. Pinned by `ProxyHttpClientTimeoutTest` (mutation-checked:
  it fails with `HttpRequestTimeoutException` without the fix).
- **HTTP/2 is permanently unavailable** (would have dissolved the connection cap): no browser speaks
  cleartext h2c, and the shell plan's loopback-only contract rules out HTTPS. Long-polling was considered
  and rejected — it pays the *identical* one-connection-per-tab cost, so it buys nothing on the cap.
- **New tests**: `ServerLogicControllerStatusObserverTest` (start/settle announcement — mutation-checked;
  unsubscribe; epoch/sequence monotonicity), kzen-shell `ProxyHttpClientTimeoutTest`.
- **Deferred**: the step budget (`Run.step(mode, count)`) — no consumer, since `slowPacingMillis = 750`
  is hardcoded with no speed UI and one call per boundary is already free at that dwell; revisit only if
  a speed control appears. **Descoped**: incremental live views — `lookup`/`lookupRun` stay full
  snapshots, now sequence-*gated*; a delta fetch would need engine reset tombstones (`resetEmitted`
  clears live values a delta pass would miss and ghost). `ScriptProgressStore`'s history watermark, the
  only pre-existing one, is untouched.
- **Not verified in-session** (needs a human at a browser): the packaged through-proxy leg and the
  in-browser `EventSource`. The server stream itself was verified with curl (headers, on-connect status,
  15 s heartbeats, survives past 15 s), and `selfTest` passes — but selfTest would also pass if the
  browser's EventSource silently failed and the fallback carried it, which is the design's whole point.

**Post-landing measurement (2026-07-15, HAR capture of a 46.6 s FizzBuzz run + a 60 s stepped WaitStep).**
This is the measurement decision 4 above deferred ("Measure after; revisit only if it still hurts"). The
transport verified clean in-browser: the stream held open 45.6 s across the whole run, only 5 `logic/status`
GETs fired (the 10 s relaxed net — i.e. `sseHealthy` stayed true), and the stepped WaitStep produced **5
byte-identical statuses and zero trace re-fetches across 60 s** where pre-E5 would have issued ~200 requests.
`settleAfterDrive`'s explicit announcement beat the armed fallback poll by ~820 ms. **The idle/paused axis
delivered as designed.**

But the same capture showed the **run** axis regressed ~3× (≈186 → ≈577 requests over 46 s), and the cause is
worth recording because it is not what it looks like:

| query | calls | distinct responses | reading |
|---|---|---|---|
| `lookup` | 142 | **142** | every response differs — but see below, that is not the same as *needed* |
| `lookup-run-history` | 143 | 75 | correct — watermark advances 0→347; the 68 repeats return nothing |
| `traced` | 143 | **15** | 90 % redundant |
| `lookup-run-executions` | 143 | **17** | 88 % redundant |

**Push did not create this waste — it uncapped it.** Pre-E5 the wall clock re-fetched all four on every poll
too; the 1.5 s cadence merely capped it at ~31 rounds, and push runs at ~3.4/s. Version-gating cannot help:
the version legitimately changes that fast.

**First attempt, and why it was wrong** (recorded because the reasoning error is the reusable part): a
`LogicStructureGate` rate-limited only `traced` + `lookupRunExecutions`, on the argument that `lookup`
"earns" its calls since 142/142 responses differ. That argument is bogus — it measures whether a response
*differs*, not whether the UI has any use for it. Nobody reads three trace repaints a second. Cut 433 → ~383;
user pushed back correctly.

**Landed instead — throttle the PUBLISH, not the queries** (kzen-auto-js only, no wire change).
`ClientLogicGlobal.publishStatus`: a status arriving from the transport (pushed or polled, one rule) publishes
immediately if `ClientLogicState.structureVersion()` changed (`traceVersion` minus the sequence — run started
/ settled / state changed / cleared; **every step boundary is one**), else through a 1 s `lodash.throttle`.
All four queries are publish-driven, so one decision replaces four clocks; ~433 → ~200. Points worth keeping:

- **`throttle`, not `debounce`** — a run is a *continuous* stream, so trailing-only debounce fires nothing
  until the run stops. Needed a new `lodash.throttle` binding; the trailing edge is what makes deferral safe
  (a run going quiet mid-flight can't strand its last value unshown).
- **Per-query gating was the wrong layer**: N queries ⇒ N clocks that drift apart, and two callers asking the
  same question then miss the shared `tracedDocuments` memo. The gate was deleted; the memo (which only ever
  existed to dedupe those two callers) stayed.
- **`structureVersion` deliberately excludes the frame.** A Script's frame position changes nearly every step,
  so including it would mark a plain run structure-changing throughout and defeat the throttle. Cost:
  intra-step intermediate frames (a stepped-over RunStep descending) repaint on the throttle's cadence, not
  per emit — still animated, since the boundary resets the clock and the first intermediate lands at once.
- `awaitStepSettled` reads `clientLogicState` directly, not the published state, so no throttle can delay a
  settle; its degraded 50 ms poll now routes through the same rule (was publishing 20/s ⇒ ~80 REST calls/s).

**Still open — do not lose these:**

1. **Server-side structural version on `LogicStatus`** (the principled version of the client throttle). A
   counter the controller bumps only when the execution tree actually changes would let `traced` /
   `lookupRunExecutions` re-fetch *exactly* when their answer changed (~15–17× per run) instead of riding the
   1 s publish cadence (~48×), and would let `structureVersion` include frame changes without defeating the
   throttle — recovering per-emit intra-step frame animation. Deferred: it is a kzen-lib wire change and wants
   its own small phase. The remaining floor after it would be `lookup` + `lookupRunHistory` alone.
   → **Scheduled as TP4** in `2026-07-16_trace-payload-improvements.md` (pulled in 2026-07-16).
2. **`lookup-run` returns a ~10 MB single response** on post-run review (measured: 10.25 MB, one call), and
   `lookup-run-history` moved 10.75 MB across the run — ~98 % of all traffic, and both are the run's real
   screenshot volume rather than over-fetch (history is correctly incremental). **This is pre-existing and
   independent of E5** — the wall-clock bug masked it by making everything expensive. Nothing here is *waste*,
   but a single 10 MB response is a latency and memory cliff that will get worse as scripts get longer, and it
   is served through a proxy. Wanted a decision on whether trace values should carry screenshots inline at all,
   or be referenced by handle and fetched per-thumbnail. → **Decision taken 2026-07-16** (referenced-by-handle);
   scheduled as **TP3** (+ **TP1** compression, **TP2** interim thin fetch) in
   `2026-07-16_trace-payload-improvements.md`.

---

## Phase 6 — Multiple concurrent runs + per-run trace retention

> **DEFERRED 2026-07-16 — groundwork readiness verified; feature implementation deferred to a later
> release.** Multi-run is not needed yet. A review this date confirmed **nothing precludes it** and
> the migration surface is deliberately concentrated (master-plan hot-seam rule 1: everything else
> was written single-run so E6's audit migrates it once). This note captures what is already ready
> and the friction a future E6 session must handle, so the deferral costs nothing later.
>
> **Already multi-run-ready (no action):**
> - Engine core — `RunEngine` owns one run + all its state, *no process-global singletons*; N
>   engines coexist by construction.
> - `runId` (`LogicRunId`) is a first-class key on **every** control verb and per-run trace query;
>   the server already validates it (`RunIdMismatch` guard — dead today, present). Guards become map
>   lookups.
> - Per-run flags (`running`/`paused`/`stepping`/`settled`/`engineSubscription`…) already live on
>   `ServerLogicController.LogicState` (105–154), not process-global — cleanly relocatable when
>   `stateOrNull` becomes a `Map<LogicRunId, LogicState>`.
> - `LogicRunInfo` payload is already fully `runId`-addressed — only the *container*
>   `LogicStatus.active`'s cardinality is single.
> - Browser/WebDriver is a per-run engine resource (`WebDriverSupport`); `ObjectStableMapper` is
>   shared *identity* infra (correct to keep singleton); Job scratch dirs are keyed by `runId`
>   (`JobWorkPool.runDir`); one controller per process is the correct shape (it becomes the run
>   registry); the client already resolves per-document views via `frameForDocument` +
>   `LogicRunExecutionId`-keyed lookups.
>
> **Friction a future E6 must handle (NOT covered by the design bullet below):**
> 1. **`anyRunActive` eviction gate** — `KzenAutoContext.kt:255`
>    (`{ serverLogicController.status().active != null }`, fed to `FilterIndexStorageArea` /
>    `JobOutputStorageArea`) — derived from the single active run; must become "no run active *at
>    all*". Conservative today (blocks eviction), so not a correctness hazard, but a single-run
>    coupling that needs the status model to expose all runs.
> 2. **Content-addressed work dirs — a design decision, not a mechanical migration.**
>    `JobWorkPool.workerOutputDir(workerLocation)` (notation-keyed, last-run-wins) and
>    `ReportWorkPool.resolveRunDir(reportRunSignature.digest())` (content-keyed, resume/reuse) are
>    **not** partitioned by `runId`; two concurrent runs of the *same* document/config collide.
>    Cross-document runs are already safe. Decide: partition by `runId`, or keep content-addressing
>    and forbid concurrent same-document runs.
> 3. **This design bullet predates E5.** "`LogicStatus` currently carries one optional
>    `LogicRunInfo`" is pre-E5 wording — E5 (2026-07-15) already reshaped the wire (controller
>    `epoch` + `LogicRunInfo.sequence`; SSE ships the full `LogicStatus`). The single→list change now
>    builds on E5's as-built shape; only `LogicStatus.active`'s cardinality + its codec change
>    (`LogicRunInfo` is already `runId`-addressed). Client `traceVersion()`/`structureVersion()`
>    already fold in `active.id.value`, so they disambiguate runs the moment there is more than one.
> 4. **`logic-spec.md` §2 residual note is stale** — it still names the retired `LogicTraceStore`
>    (E4 retired it 2026-07-15). The residual is now `ServerLogicController.stateOrNull` (single run)
>    + `RunEngineLogicTrace` projecting a single retained run via `activeRun()`. (Refreshed
>    2026-07-16 with a deferral pointer; the residual itself stays until E6 lands.)
> 5. **Thread-budget config hook does not exist yet** — the per-run `threads` lowering the design
>    bullet calls for must be added by E6; `RunEngine.migrate`'s `runBlocking`-not-on-a-dispatcher-
>    thread invariant is preserved by per-run executors — assert it.
> 6. **The `CachedKotlinCompiler` race the Script plan earmarked for E6 is already fixed** — a
>    per-signature `Striped.lock` + Caffeine cache landed 2026-07-11 (commit `09120a1e`), after that
>    plan was written. The report pipeline already compiles concurrently within one run through this
>    shared cache, so multi-run adds no new race there. Nothing to carry into E6.

**Goal:** close the last spec §2 residual: N independent runs per JVM, independently controllable,
with bounded retention of settled runs.

**Prerequisite:** Phase 4 (single-store retirement means no shared `clearAll` to untangle);
phase 5 recommended (per-run SSE signals).

### Design decisions

- `ServerLogicController.stateOrNull` → `LinkedHashMap<LogicRunId, LogicState>` (insertion-ordered
  for retention); every command already carries `runId` — the guards change from "is it the run" to
  map lookup. `start()` stops refusing when a run exists. One driving executor **per run** (the
  single-thread drive/quiesce discipline is per-run; a shared executor would serialize unrelated
  runs).
- **Wire**: `LogicStatus` currently carries one optional `LogicRunInfo`. Change to a list (or add
  `/logic/status?run=` alongside a summary list — implementer's choice, but the client must be able
  to cheaply ask "which run, if any, has root document X", which is how every document UI binds
  today via `mostRecent`). JS `ClientLogicGlobal` keys its state per root document rather than
  globally; the run ribbon binds to the current document's run. Audit
  `ClientLogicState`/`clientLogicGlobal` consumers — this is the widest client touchpoint of the
  plan.
- **Retention**: keep the active runs plus the most recent **settled** run *per root document*
  (that preserves today's post-run review semantics exactly, per document); dispose older settled
  engines on each start. No global wipe remains.
- **Thread budget**: each `RunEngine` owns a `CountingDispatcher` with `cores − 1` threads —
  unacceptable at N runs. Make `threads` a constructor default the controller lowers (e.g.
  `max(2, cores / 2)` per run, or configurable via `KzenAutoContext` config). Do **not** attempt a
  shared dispatcher: quiescence counting (`inFlight == 0`) is per-dispatcher and sharing would break
  `awaitQuiescent` isolation between runs. (A shared-executor/per-engine-counter dispatcher is a
  possible future refinement — note it, don't build it.)
- Concurrency gotcha to preserve: `RunEngine.migrate` uses `runBlocking` and must never run on a
  dispatcher thread — per-run executors keep that invariant; assert it.
- Spec: strike the §2 residual-gap note; update the §8 headline-tension resolution and both
  architecture docs (`ServerLogicController` singleton descriptions).

**Verify:** baseline; new controller test: two concurrent runs (two different documents), step one
while the other runs free, cancel one — the other unaffected; per-document post-run review
retained; selfTest; manual two-tab session driving two documents.

---

## Phase 7 — Hardening: `Execution.blocking`, typed capture, structured failure

**Goal:** close the remaining sharp edges. Independent items — can be executed as one session or
split; none blocks the others.

**Prerequisite:** Phase 1 (nothing else).

### 7a. `Execution.blocking { }`

Blocking third-party calls (Selenium, JDBC, big file I/O) currently occupy one of the fixed
dispatcher threads — enough blocking spines starve the pool and stall `awaitQuiescent` (which
wedges the driving executor). Add:

```kotlin
suspend fun <R> blocking(block: () -> R): R
```

Implementation: run `block` via `runInterruptible` on an elastic pool (a per-engine
`Executors.newCachedThreadPool` exposed as a dispatcher, owned/closed by `RunEngine`), **wrapped in
an in-flight count increment/decrement on the `CountingDispatcher`** so quiescence stays truthful —
a blocking call reads as "busy", exactly as it does today, but no longer holds an engine thread,
and engine `cancel` reaches it through thread interrupt (`runInterruptible` converts interrupt →
`CancellationException`). Adopt it in kzen-auto where the win is real: the Selenium steps
(`BrowserOpenStep` and the action steps' waits) and Report/Job file I/O loops — survey
`objects/script/step/` for candidates rather than converting exhaustively. Spec §2 note on
blocking-work visibility gets the mechanism named.

### 7b. Typed migration capture

Every capture/restore seam is an unchecked cast (`execution.restored as? ScriptMigrationState`,
`as? Map<ObjectStableId, List<Any?>>` in `JobRun.kt`). Minimal, non-breaking: add a reified helper
on `Execution` (`inline fun <reified T> restoredAs(): T?` — returns null on type mismatch instead
of a CCE) and adopt it at the Script/Flow/Job seams. Kdoc on `onCapture`: captured states should be
self-contained value types, `AutoCloseable` if they hold detached resources (already spec'd).

### 7c. Structured failure

`Outcome.Failed(message: String)` loses where a failure came from, and `host()` flattens a child
failure into `LogicFailure(message)`. Extend `Outcome.Failed(message, at: ObjectStableId? = null)`
— `at` is the failing node's stable id (engine fills it at `settleNode`; a re-thrown child failure
carries the *child's* id up unchanged, matching the spec's pause-reason propagation principle).
Surface it in `LogicRunFrameInfo` alongside the existing status so the UI can badge the failing
element post-run. Keep the wire change small; per-worker outcome chips in the Job UI (a known
display gap noted in `JobRun.kt:71`) become possible and may be done here if time allows.

### 7d. Sweep

- Fix stale kdoc referencing the retired `tech.kzen.auto.server.objects.job.JobExecution`
  (`WorkerBase.kt:88`, JS `JobProgressStore.kt:19`, `DuplexJobChannel.kt:25-27`, others by grep).
- `JobRun.route`'s `runBlocking` + 1 s timeout under the controller monitor
  (`JobRun.kt:224-249`): document as a known bounded seam or move the wait off-monitor if phase 6
  made the controller per-run (cheap then). Don't redesign the duplex bridge.

**Verify:** baseline; `RunEngineTest` additions: `blocking` counts as busy for `awaitQuiescent`,
cancel interrupts a parked-in-blocking spine; `Failed.at` propagates through `host`. Manual: pause
during a Selenium wait converges once the blocking call returns; cancel during one converges
immediately.

---

## Sequencing summary

```
Phase 1 (engine hot path + pause fix)        kzen-lib            ── foundation
   └─ Phase 2 (checkpoint identity)          kzen-lib + auto     ── contract, small
        └─ Phase 3 (breakpoints/run-to)      all layers          ── small
        └─ Phase 4 (trace unification)       kzen-lib + auto-jvm ── largest, riskiest
             └─ Phase 5 (SSE + watermarks + step budget)         ── UX latency
                  └─ Phase 6 (multi-run + retention)             ── widest client impact
   └─ Phase 7 (blocking/typed capture/failure)                   ── anytime after 1
```

Rough sizing (Opus 4.8 xhigh sessions): 1, 2, 3, 7 — one comfortable session each; 4 — one full
session with the survey step done before any deletion; 5 — one session; 6 — one session, mostly
client-side care. If a phase runs long, land it engine-first (kzen-lib green + published) and note
the remainder here rather than leaving both repos half-migrated.
