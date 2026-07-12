# Flow (synchronous dataflow) improvements — phased plan

> **Status: planned.** Written 2026-07-06 from a design review of the Flow document type — the
> synchronous, zero-parallelism dataflow paradigm (vertices + pipes on a grid, one vertex
> execution per step, run as a kzen-lib `Logic`) — across all three layers: common
> (`FlowVertex` API + channels, `FlowMatrix` / `FlowDag` / `FlowUtils`, `VisualVertexModel` /
> `VisualFlowModel`, `FlowWiring` / `EdgesDefiner` / `FlowConventions`), server
> (`FlowLogicCompiler` / `FlowLogic` / `FlowRun` + the `server/objects/flow/vertex/` impls), and
> the JS client (`FlowController` / `FlowProgressStore` / `CellController` / `VertexController` /
> `EdgeController`). Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is
> self-contained: goal, design decisions (already made — do not re-litigate), concrete steps with
> file anchors, and verification. Phases are ordered by priority; phase 6 is a **decision gate**,
> not a build order.
>
> All phases are **kzen-auto only** (no kzen-lib changes) — no publishToMavenLocal round-trips
> needed. Where the kzen-lib graph plan would also help (definition caching, scoped
> instantiation), the Flow-local fix here stands on its own and is the right fix regardless.
>
> Companion plans: `2026-07-05_logic-engine-improvements.md` (engine stepping/step-modes — Flow
> consumes them, never re-implements), `2026-07-05_graph-improvements.md` (createGraph gets
> cheaper there; phase 2 here makes Flow stop calling it per vertex regardless),
> `2026-07-06_script-improvements.md` (phase 8 there defines the client render-scoping
> conventions phase 4 here applies).
>
> **Progress tracker** (update as phases land):
> - [x] Phase 1 — structure core: FlowMatrix/FlowDag/FlowUtils test harness, OptionalInput readiness fix, definition robustness, pre-run structure lint, one signature derivation — landed 2026-07-11 (as-built note at the end of Phase 1)
> - [x] Phase 2 — server run loop: graph instance per run (not per vertex execution), non-fatal + throttleable tracing, inspection cost bounds — landed 2026-07-11 (as-built note at the end of Phase 2)
> - [ ] Phase 3 — vertex SPI generalization: capability interfaces replace concrete-class special cases, message inspection on the vertex, channel contracts, multi-parameter RunLogic
> - [ ] Phase 4 — client render performance + error visibility: compute-once routing, consumed-subset state, Error phase rendered, refetch scoping, display hygiene
> - [ ] Phase 5 — editing UX: move commands, auto-pipe routing tool, row/column shifting, legacy `flow/edit` cleanup
> - [ ] Phase 6 — decision gate: expressiveness (multi-output, pipe crossing, nested-loop semantics) — decide, then build or document

## Context — what the review found

The **execution core is strong and every phase preserves it**:

- **`FlowRun` on the RunEngine** (FlowRun.kt) — position on the coroutine stack, a vertex as the
  step boundary (`execution.checkpoint()` before each), pause-on-error via
  `execution.recoverable`, child Logic hosting via `execution.host`. Clean, well-commented,
  and the right shape. Nothing here changes the engine contract.
- **Live-edit migration** (`FlowMigrationState`, `FlowRun.kt:81-87`) — per-vertex progress +
  harvested outputs carried across pause → edit → resume, keyed by stable id, with an exact
  timing-independent test (`FlowMigrationTest`'s process-count-settles-at-exactly-5 signal).
- **Server-side test coverage of the engine path**: `FlowNotationTest` (input→output, stream
  loop, error fail vs pause-on-error park, RunLogic child hosting), `FlowControllerStepTest`
  (pins a subtle definition-identity regression on the client's null-snapshot step path),
  `FlowMigrationTest`. These are the regression baseline for phases 1–3.
- **Trace-store integration** — the server emits each vertex's `VisualVertexModel` at its
  stable-id address; `FlowProgressStore` rebuilds the client model from the trace, frame-keyed so
  re-entrant invocations of the same Flow don't merge (FlowProgressStore.kt:40-55). Sound design;
  phase 4 only scopes *when* it refetches.
- **The paradigm itself**: fully deterministic single-stepping over a stateful vertex DAG is the
  point — zero parallelism is a feature, not a gap. No phase adds concurrency.

The weaknesses live in the layers inherited unchanged from the old Graph document, plus a few
engine-adjacent gaps:

1. **The structure core (geometry → DAG) has zero direct tests and two known holes.** The DAG is
   derived purely from grid adjacency — a vertex's input *i* is fed by whatever cell sits at
   `(row-1, column+i)`, traced through hand-placed pipe glyphs (`FlowMatrix.traceVertexBackFrom`,
   FlowMatrix.kt:216-276; `FlowDag.of`, FlowDag.kt:17-32). This is the most edge-case-dense code
   in the subsystem (13 `EdgeOrientation` variants, multi-input column arithmetic,
   `findCellBelow`'s leftward multi-cell scan, FlowDag.kt:122-158) and **nothing in `commonTest`
   touches it** — it is covered only incidentally by a handful of simple end-to-end topologies.
   The two holes: **(a) OptionalInput is de facto required** — `FlowUtils` skips any vertex whose
   declared-input count ≠ wired-predecessor count and requires *all* predecessors to carry a
   message (FlowUtils.kt:114-117, :174-183, both marked TODO), so `AppendText` — whose own
   description says "possibly one" input and whose `process()` tolerates a missing optional
   (AppendText.kt:16-17) — is unreachable with one input wired; **(b) there is no structural
   validation** — a misplaced pipe silently rewires or disconnects the flow, and the first
   symptom is a stalled run or `check(populatedInputCount > 0)` blowing up mid-run
   (FlowRun.kt:319-321). Also: `FlowWiring.define` ends in `TODO("Unknown: $attributeClass")`
   (FlowWiring.kt:118-119) — malformed notation crashes definition instead of failing it — and
   the Logic signature is derived twice with drift (the compiler instantiates the whole graph to
   read `tupleComponentName` and emits `TupleComponentName("")` for an unnamed `FlowInput`,
   FlowLogicCompiler.kt:40-58, while the client's `FlowConventions.inputParameterNames` reads
   notation and filters empty names, FlowConventions.kt:60-77).
2. **The server run loop rebuilds the world per vertex execution.** `FlowRun.createInstance`
   runs `GraphCreator.createGraph(graphDefinition.filterTransitive(documentPath), ...)` — the
   entire document closure — **once per vertex execution** (FlowRun.kt:434-441) and again per
   `retrace` (FlowRun.kt:394-406). A stream loop of N items over V vertices does N×V full graph
   builds. But `graphDefinition` is immutable for the life of a `FlowRun` (a live edit builds a
   new `FlowRun` via migration), so one build per run suffices; the "clean channels" rationale is
   already satisfied deterministically (`populateInputs` sets-or-clears every wired input,
   outputs are drained by `getAndClear`/`consumeAndClear`). Tracing has an unpriced cost too:
   `traceVertex` runs twice per vertex execution and serializes the **full** `inspectState` each
   time (FlowRun.kt:126, :148, :470-500) — an `AccumulateSink` over N items costs O(N²) total
   serialization. And tracing is a **run-killer**: `FlowMessageInspector`'s registry is
   constructed empty in `KzenAutoContext` and **no registration call exists anywhere**, so a
   vertex emitting any non-basic message (`ExecutionValue.ofArbitrary` miss) hits the hard
   `throw` (FlowMessageInspector.kt:29) from `traceVertex`, which runs *outside*
   `execution.recoverable` — the run fails regardless of pause-on-error. Exact-`KClass` lookup,
   no supertype walk, no `toString` fallback.
3. **The engine special-cases three concrete vertex classes — the god-object shape.** `FlowRun`
   branches on `reference is RunLogicVertex` (FlowRun.kt:132), `is FlowInputVertex`
   (FlowRun.kt:229), `is FlowOutputVertex` (FlowRun.kt:150, :237), and `FlowLogicCompiler`
   repeats the same three-way dispatch (FlowLogicCompiler.kt:53-70). These are first-party
   vertices, but the coupling costs what it always costs: a third-party vertex can never host a
   child Logic, read run arguments, or contribute to the result tuple, because those powers are
   keyed to concrete classes rather than capabilities. Related SPI debt: `MutableFlowOutput`
   implements all four output interfaces with contracts unenforced (TODO,
   MutableFlowOutput.kt:9 — a `RequiredOutput` vertex can silently emit nothing);
   `RunLogicVertex` binds only the callee's **first** parameter (FlowRun.kt:174-182) vs Script's
   full `RunStepArgumentsEditor`; and the three vertices' KDocs still describe the retired
   `FlowExecution` and a `FlowDocument.define()` that no longer exists (RunLogicVertex.kt:16-21,
   FlowInputVertex.kt:15-19, FlowOutputVertex.kt:11-15, also FlowConventions.kt:58-59,
   FlowLogicCompiler.kt:28).
4. **The client re-derives the routing model per vertex per render, and hides errors.**
   `VertexController.renderVertex` calls the `FlowUtils.next(documentPath, graphStructure,
   visualFlowModel)` overload that rebuilds `FlowMatrix` + `FlowDag` from notation — per vertex,
   per render (VertexController.kt:286-289); `EdgeController.nextToRun()` does the same per edge
   (EdgeController.kt:112-118) — even though both already receive `flowMatrix` and `flowDag` as
   props. `FlowController` stores the whole fresh-reference `ClientState` in component state
   (FlowController.kt:170-176), defeating `RPureComponent`'s shallow-equal, so the entire grid
   re-renders on every publish — every keystroke in any attribute editor triggers O(V²) DAG
   rebuilding. **Errors are invisible**: `VisualVertexPhase.Error` is unreachable (`phase()` has
   `// TODO: add support for Error` and never returns it, VisualVertexModel.kt:95-110), so
   `VertexController`'s red-card branch is dead code and nothing anywhere renders `model.error` —
   pause-on-error parks a vertex with a populated error and the card shows nothing. Minor:
   `fetchKey` includes the global `logicStatus.time`, so an open Flow refetches its trace
   snapshot on every status poll while *any* run is active, including an unrelated document's
   (FlowController.kt:190-197); message/state render as raw unbounded
   `+"${value.get()}"` (VertexController.kt:786, :889); `VisualFlowModel`'s
   `put`/`remove`/`rename`/`move`/`isInProgress`/`digest` are dead code from the retired visual
   repository (VisualFlowModel.kt:50-117), and `VisualVertexModel.digest` omits `error`
   (VisualVertexModel.kt:114-121).
5. **Editing is insert-and-delete only.** `VertexController.renderAttributes` filters out
   `row`/`column` (VertexController.kt:494-501) and the options menu has only Delete
   (VertexController.kt:651-665) — nothing can be moved; repositioning means delete + recreate,
   losing configuration. Pipes are hand-placed from 13 orientation glyphs (flow-edge.yaml) with
   no routing assistance. The `flow/edit/*Old.kt` legacy cluster (5 files) survives only because
   `PluginController.kt:212` still uses `AttributePathValueEditorOld`.

**Covered elsewhere — do not re-do here:** engine stepping semantics and step(mode, count)
(logic-engine plan phase 5 — Flow's step boundary stays `execution.checkpoint()`, nothing more);
definition caching / scoped instantiation (graph plan — phase 2 here removes Flow's per-vertex
`createGraph` calls, which is correct with or without that work); client render-scoping
conventions (script plan phase 8 — phase 4 here applies them to Flow, doesn't re-derive them);
Logic signature/composition UX across document types (job plan — Flow's input/output vertices
already produce a signature; only the derivation dedup is done here, in phase 1).

**Deliberately out of scope** (decided; do not re-open inside a phase):
- **Replacing geometry-as-wiring with explicit named edges + auto-layout.** Scrutinized and
  settled: the grid model is deterministic, tangible, diff-able in notation, and avoids a layout
  engine. Its costs are addressed *within* the model (phase 1 validation, phase 5 move/auto-pipe)
  — not by replacing it. The `vertices`/`edges` notation shape (row/column/orientation) is
  stable; **no migration of user documents in any phase**.
- **Any parallelism** — deterministic single-stepping is the paradigm's identity.
- Drag-and-drop editing — phase 5 is command/menu-based move; DnD is a possible follow-up once
  move commands exist, not part of this plan.
- A time-series vertex library (windowing, resampling, joins) — becomes easier after phase 3's
  SPI work; none of it is built in this plan.
- Undo/redo — a kzen-lib/notation-CQRS-wide concern, not Flow's.
- Client-side unit tests for the JS controllers — the structure core moves under `commonTest`
  (phase 1) where both platforms share it; JS-side verification stays manual smoke.

## Ground rules for every phase

- **No new vertex-type-specific code in shared layers.** The three existing concrete-class
  special cases are quarantined until phase 3 dissolves them; phases 1–2 must not add branches
  on vertex types anywhere (`FlowRun`, `FlowUtils`, controllers).
- **Notation compatibility is absolute**: every existing Flow document (including the user's
  `notation/main/FizzBuzz/FizzBuzz Flow Loop.yaml` — a working document; never edit or delete
  it) keeps running unchanged through every phase.
- **Dev loop:** kzen-auto only. `./gradlew -t :kzen-auto-jvm:classes` + IDE `BackendDevelopment`
  for server phases; `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` for client phases.
- **Verification baseline (every phase):** `./gradlew :kzen-auto-jvm:test` (must include
  `FlowNotationTest`, `FlowControllerStepTest`, `FlowMigrationTest` green, plus phase 1's new
  structure tests once they exist). Client phases add a manual `frontendDevelopment` smoke
  against a scratch Flow document created through the UI (insert vertices/pipes, Run, Step,
  pause-on-error). `./gradlew :kzen-auto-test:selfTest` as the broad regression net (it does not
  drive a Flow directly, but proves the shared Logic ribbon/engine paths); **beware a stale
  tester JVM on port 18081 — kill it first.**
- Mark the phase checkbox in this file's tracker when done; append an as-built note on deviation.

---

## Phase 1 — Structure core: tests, OptionalInput, validation, one signature derivation

**Goal:** the geometry→DAG derivation becomes directly tested; optional inputs actually behave
as optional; malformed structure fails at definition/validation time with a message instead of
mid-run; the Logic signature has one derivation. kzen-auto-common + kzen-auto-jvm.

### 1a. Test harness first — pin before touching

- New `commonTest` suite (kzen-auto-common) for `FlowMatrix` / `FlowDag` / `FlowUtils`, building
  matrices from inline `ListAttributeNotation`s (no server, no graph instance — these are pure
  functions over notation + descriptors). Cover: straight chain; fan-out via
  `TopToBottomAndLeft/Right`; fan-in to a multi-input vertex (input column arithmetic,
  `FlowMatrix.get`'s colspan window, FlowMatrix.kt:177-196); horizontal pipe runs
  (`LeftToRight`/`RightToLeft` chains); `findCellBelow`'s leftward multi-cell scan
  (FlowDag.kt:139-153); layer computation + the cycle `check` (FlowDag.kt:214-216); and
  `FlowUtils.next` selection order (last-in-progress layer wins over first-ready,
  FlowUtils.kt:52-61; min-epoch tie-break within a layer, FlowUtils.kt:149-186).
- These pin current behaviour **before** 1b changes readiness. Write them against today's
  semantics, then adjust the OptionalInput cases in the same session as 1b.

### 1b. OptionalInput readiness — honour the declared contract

- Readiness distinguishes required from optional inputs. `VertexDescriptor.inputNames` currently
  conflates them (FlowWiring.findInputs returns both, FlowWiring.kt:42-57); carry the
  distinction into the descriptor (e.g. `inputNames` + `requiredInputNames`, derived from the
  same metadata `is:` segment that already distinguishes `RequiredInput` from `OptionalInput`,
  FlowWiring.kt:32-39).
- New rules in `FlowUtils` (replacing the two TODO guards, FlowUtils.kt:114-117, :174-183):
  a vertex is ready when **every required input's wired predecessor has a message** and **every
  wired optional input's predecessor has a message** (an optional input that is wired still
  gates — synchronous determinism means we never run ahead of an upstream that will produce);
  an **unwired optional input simply doesn't count**. An unwired *required* input keeps the
  vertex permanently not-ready — that becomes a validation error in 1d, not a silent stall.
- `FlowRun.populateInputs` keeps set-or-clear per wired input; the
  `check(populatedInputCount > 0)` (FlowRun.kt:319-321) stays as a backstop but should be
  unreachable once 1d validates.
- Acceptance: an `AppendText` with only `suffix` wired runs and emits (its "possibly one"
  description finally true); the 1a suite's optional-input cases assert both the one-wired and
  both-wired orders.

### 1c. Definition-layer robustness

- `FlowWiring.define`: the `TODO("Unknown: $attributeClass")` (FlowWiring.kt:118-119) becomes
  `AttributeDefinitionAttempt.failure("Unknown flow channel type: ...")`.
- `EdgeDescriptor.fromNotation`: `EdgeOrientation.valueOf` throws on a bad `orientation` string
  (CellDescriptor.kt:45-48) — tolerate with a clear failure at the definer level
  (`EdgesDefiner`, EdgesDefiner.kt:38-46) rather than an exception escaping from notation
  parsing paths shared with the client.
- Empty `FlowInput.parameter` / `FlowOutput.result`: an unnamed input/output vertex is a
  **validation error** (1d), and the signature derivation (1e) filters empty names on both
  sides identically in the meantime.

### 1d. Pre-run structure lint

- New pure function in common (beside `FlowUtils`, e.g. `FlowStructureValidator`):
  given matrix + dag + descriptors, report: required inputs with no wired predecessor; pipes
  that connect to nothing (an edge whose trace reaches no vertex in at least one direction);
  vertices unreachable from any source; more wired predecessors than declared inputs; duplicate
  `FlowInput` parameter names / `FlowOutput` result names; empty parameter/result names; cycle
  (reuse `FlowDag`'s detection, surfaced as a result instead of a `check` throw).
- Server: `FlowLogicCompiler.compile` runs the lint and throws `LogicFailure` with the full
  finding list (replacing the run-time stall / mid-run `check`).
- Client: `FlowController` runs the same lint on the current notation and renders findings in a
  banner above the grid (same visual weight as Script's validation errors) — the geometry model
  keeps its simplicity because mistakes become visible the moment they're made.
- Unit tests in the 1a suite per finding type.

### 1e. One signature derivation

- `FlowConventions.inputParameterNames` generalizes to derive the **full signature** (inputs and
  outputs, in notation order, empty names filtered) from notation only, and becomes the single
  source: `FlowLogicCompiler` uses it for the `LogicSignature` (deleting the compile-time
  signature-only use of the graph instance walk, FlowLogicCompiler.kt:48-58 — the walk itself
  survives until phase 3 for childLogics discovery), and `RunStepArgumentsEditor` keeps calling
  it. One derivation, no drift; the compiler no longer emits `TupleComponentName("")`.

**Verify:** new commonTest suite green (`:kzen-auto-common:allTests` or the aggregate build);
`:kzen-auto-jvm:test` green including a new `FlowNotationTest` case for one-wired-optional-input
`AppendText`; manual smoke: a Flow with a dangling pipe shows the lint banner and refuses to
start with the finding list; the FizzBuzz Flow Loop document (read-only) shows no findings and
still runs.

**As-built (2026-07-11).** Landed as planned with these deviations/findings:

- **`FlowStructureValidator` lives in `objects/document/flow`** (beside `FlowConventions` /
  `FlowWiring`), not beside `FlowUtils` — the name findings need document-level notation
  semantics. Geometry findings (`validateStructure(matrix)`) stay matrix-only and are
  commonTest-covered; name findings (`validateNames`) are covered by `FlowNotationTest`'s
  compile-failure cases (building inheritance-resolved `GraphNotation` in commonTest wasn't
  worth the fixture weight).
- **The cycle finding was dropped as unrepresentable**: every successor hop moves laterally
  within a pipe row or strictly downward, so a matrix-derived DAG is acyclic by construction.
  `FlowDag.of`'s `check` stays as pure defence; the client needs no dag-build guard.
- **"Unreachable from any source" was subsumed** by the per-vertex wiring findings — every
  unreachable chain contains a flagged root (unwired required input / fully-unwired vertex);
  no separate reachability sweep.
- **"More wired predecessors than declared inputs" IS representable and reported**: a source
  beyond a fan-in's column span still finds it as successor via `findCellBelow`'s leftward-scan
  arithmetic (a forward/backward asymmetry pinned by
  `FlowDagTest.leftwardScanReachesVertexBeyondItsSpan`).
- **Readiness unification details**: `isLayerReady`'s old `.any`-predecessor-message acceptance
  became the same per-input rule as `nextInLayer` (the `unify` TODO); `nextInLayer`'s
  single-vertex-layer shortcut was deliberately KEPT — an in-progress mid-stream vertex
  re-executes without fresh inputs (e.g. a repeater draining state), pinned by
  `FlowUtilsNextTest.inProgressSingleVertexLayerSelectedWithoutInputCheck`.
- **Readiness rule REVISED same-day (regression found in FizzBuzz Flow Loop)**: the plan's
  "a wired optional input still gates" contradicted the higher-priority "notation compatibility
  is absolute" ground rule — FizzBuzz's `SelectLast` has both optionals wired but per iteration
  only one branch produces (the filter drops the other), so it stalled. Final rule: required
  inputs are strict (wired + upstream message), a wired optional never gates on its own (layer
  order guarantees its upstream has settled — empty means "produced nothing this pass"), and at
  least one wired input must hold a message (sources are always ready). Pinned by
  `FlowUtilsNextTest.selectLastRunsWhenOnlyOneWiredOptionalHasMessage` and end-to-end by
  `FlowNotationTest.selectLastMergesWhicheverBranchProducedEachIteration` over
  `flow-select-last-test.yaml`, a reduced FizzBuzz-loop shape (the real document is excluded
  from the test notation scan by `AutoTestUtils.readNotation`'s `main/` exclusion).
- **1e resolves the `vertices` list references** (same resolution as `FlowMatrix`) instead of
  `directNestedObjectPaths`: the old `inputParameterNames` silently missed top-level
  (hand-written) vertices and only saw UI-created nested ones; the list order is the signature
  order. `RunStepArgumentsEditor` inherits the fix unchanged.
- Dangling-pipe detection is ingress-closure based and deliberately lenient toward stray side
  branches pointing *into* a functioning run; every cell of a severed run is reported.
- New files: 5 commonTest files under `paradigm/flow/` (`FlowStructureTestBuilder` + 4 suites),
  `FlowStructureValidator.kt`, and 3 test fixtures (`flow-optional-input-test.yaml`,
  `flow-invalid-unwired-required-test.yaml`, `flow-invalid-duplicate-parameter-test.yaml`).
  The client banner mirrors `StageController.renderDefinitionErrors`' always-emitted stable
  slot (sibling-remount hazard).
- Manual smoke (dangling-pipe banner in the dev loop; FizzBuzz Flow Loop clean) remains for the
  next dev-loop session; all automated verification is green.

---

## Phase 2 — Server run loop: instance-per-run, non-fatal + throttleable tracing

**Goal:** the run loop stops rebuilding the graph per vertex execution; tracing can never kill a
run and its cost is bounded; long headless runs stop paying for a UI nobody is watching.
kzen-auto-jvm (+ one common doc touch).

### Design decisions

- **Graph instance per run, not per vertex execution.** `FlowRun.run()` builds the
  `GraphInstance` once (where it already builds the matrix, FlowRun.kt:89) and reuses it for
  every `createInstance` lookup and every `retrace` (deleting the rebuilds at FlowRun.kt:399,
  :437-438). This is a **contract clarification, documented in `FlowVertex`'s KDoc**: vertex
  instances live for the run (fresh on live-edit migration, which builds a new `FlowRun`);
  externalized state in `initialState()`/`process(state)` remains the durable contract; injected
  channels are reset by the runner before each `process` call. Add an explicit
  channel-reset step before `process`: clear the output buffer (defensive; it is drained after
  every call today) and rely on `populateInputs`' existing set-or-clear for inputs.
- **Tracing becomes non-fatal.** Wrap `inspectState` + `inspectMessage` inside `traceVertex`
  (FlowRun.kt:478-485) in a try/catch that falls back to a `toString`-based
  `ExecutionValue` (truncated, e.g. 1 KiB with an ellipsis marker) and never throws. A trace
  must never fail a run that the vertex itself survived.
- **`FlowMessageInspector` gets an honest default**: `inspectMessage` falls back to
  `ExecutionValue.of(message.toString())` (truncated as above) instead of throwing
  (FlowMessageInspector.kt:29), and lookup walks supertypes (first exact class, then
  superclasses/interfaces) so registering for an interface works. The registration *path*
  (who calls `register`) is phase 3's SPI question — this phase only removes the landmine.
- **Trace throttling for hot loops.** `traceVertex` emits unconditionally today (twice per
  vertex execution). Add a cheap policy in `FlowRun`: always emit on `running = true→false`
  transitions **when the engine is paused/stepping or the vertex changed error state**; during
  free running, rate-limit per vertex (e.g. emit at most every N epochs or T milliseconds,
  whichever is coarser — constant in `FlowRun`, no notation surface), and **always emit the
  final state** for every vertex at run end / pause settle (the existing `clearMessagesAtEnd`
  retrace already touches every vertex — extend it to re-emit final models). Stepping fidelity
  is untouched (paused/stepping always traces); free-running throughput stops being O(trace).
- **Inspection cost note**: with throttling, `inspectState`'s O(state) serialization runs per
  throttle window, not per epoch — the AccumulateSink O(N²) collapses. Document in `FlowVertex.
  inspectState` KDoc that it is called repeatedly and should be cheap relative to state size.
- Micro-cleanups riding along: `ActiveVertexModel.epoch` is `Long` but `VisualVertexModel.epoch`
  is `Int` via `.toInt()` (FlowRun.kt:462, :492) — make both `Int` (an epoch that overflows Int
  is not a realistic Flow); delete the dead `VisualFlowModel` members
  (`put`/`remove`/`rename`/`move`/`isInProgress`/`digest`, VisualFlowModel.kt:50-117) and add
  `error` to `VisualVertexModel.digest` if the digest is kept (or delete it too if then unused).

### Steps

- Refactor `FlowRun`: hoist the graph build; delete `createInstance`'s per-call build; simplify
  `retrace` to use the run instance; add the channel-reset + trace-throttle policy; wrap
  inspection.
- `FlowMessageInspector`: fallback + supertype walk + KDoc ("registry optional; toString
  fallback").
- New tests (`kzen-auto-jvm`): a vertex whose message is an arbitrary domain object → run
  succeeds, trace carries the toString rendering (regression for the run-killer); a stream run
  asserting the sink's final traced state is present and correct after run end (throttle must
  not lose the final frame); `FlowMigrationTest` unchanged-green proves instance-per-run didn't
  break carry-forward.
- Benchmark canary (generous bound, `FormulaStepTest` style): a 1..N stream (N ~ 2000) through a
  3-vertex chain completes within a loose wall-clock bound — pins the N×V graph-build
  regression from ever coming back.

**Verify:** `:kzen-auto-jvm:test` including the new tests + benchmark bound; manual smoke:
step through FizzBuzz Flow Loop — per-vertex cards still update on every step (paused-path
tracing untouched); run it free — final state correct.

**As-built (2026-07-11).** Landed as planned with these deviations/findings:

- **Paused/stepping detection uses the checkpoint-gap proxy**, because `Execution` deliberately
  exposes no run-mode query (the engine owns stepping). `checkpoint()` only *suspends* while
  paused/stepping, so `run()` measures `System.nanoTime()` across consecutive checkpoint-returns:
  a gap ≥ 50 ms (well above a µs-scale hot-loop execution, well below human step cadence) ⇒
  `pausedOrStepping`, which forces the normal pre/post-execution traces (fidelity). First iteration
  forces (null sentinel). Free-running traces are per-vertex wall-clock throttled (≥ 100 ms window,
  first-emit-per-vertex always through). Both constants are `private companion` values in `FlowRun`
  — no notation surface. Scheduling is provably immune (`snapshotVisual` reads `activeVertices`, not
  emitted traces).
- **`traceVertex` gained a `force` flag**; the throttle gate is checked *before* building the model,
  so `inspectState`'s O(state) serialization is skipped when throttled (the AccumulateSink O(N²)
  collapses). Force is `true` at both `recoverable` error handlers (red shows immediately) and at the
  **run-end flush**; `false` for `clearIterationForLoop`'s `retrace` (forcing it would re-serialize a
  reset downstream accumulator every iteration and re-introduce O(N²); stepping still lets these
  through via the wall-clock throttle, their last emit being long ago).
- **`clearMessagesAtEnd` now force-traces *every* vertex** (clearing message, keeping state), so run
  completion always lands an accurate final frame regardless of throttling. Residual (noted acceptable):
  a manual *pause* mid-free-run — distinct from stepping — may leave one in-flight vertex ≤ 100 ms
  stale until the user steps/resumes, since `Execution` gives `FlowRun` no pause-settle callback; the
  next step/resume is a slow tick that re-emits, and completion force-flushes.
- **`MutableFlowOutput.clear()` added** and called before every `process`: under instance-per-run +
  pause-on-error retry, a `process` that `set()` then threw would otherwise leave a stale item to
  re-emit. Inputs need no extra reset (`populateInputs` set-or-clears every wired input each call).
  `createInstance` (per-execution `createGraph`) became `instanceFor` (a lookup on the run's single
  `GraphInstance`, built once in `run()` next to the matrix); `retrace` dropped its own build too.
- **`FlowMessageInspector.inspectMessage` no longer throws**: `ofArbitrary` fast path →
  supertype-aware registry match (`entries.firstOrNull { it.key.isInstance(message) }`, so an
  interface registration would work) → truncated-`toString` fallback. A shared companion
  `truncatedToString` (≤ `maxTraceChars = 1024` + ellipsis) is reused by `FlowRun.traceVertex`'s
  try/catch belt-and-suspenders around `inspectState`/`inspectMessage`. The registry stays empty
  (registration path is phase 3's SPI question) — this phase only removed the landmine.
- **Regression test needs no test-only vertex**: `FlowInputVertex`'s message is the raw run argument,
  so `flow-execution-test.yaml` re-used with a `private data class` argument exercises the run-killer
  directly. `arbitraryDomainObjectMessageDoesNotKillRun` asserts `Outcome.Success` + `out == widget`
  and reads the input vertex's rendered `toString` back from `engine.history(0)` (the run-end flush
  clears the latest message, but history retains every frame). `streamSinkFinalStateTracedAtRunEnd`
  reads the sink's final **state** from `snapshot().root.live` (state survives the flush).
  `streamRunDoesNotRebuildGraphPerVertex` (a `FlowNotationTest` method, not a separate class) ran a
  1..2000 / 3-vertex chain in ~1.3 s (bound 10 s). New fixtures: `flow-accumulate-test.yaml`,
  `flow-benchmark-test.yaml` (both use `edges: []` vertical-adjacency auto-wiring).
- **Micro-cleanups**: `ActiveVertexModel.epoch` Long → Int (redundant `.toInt()` dropped);
  `VisualFlowModel.put/remove/rename/move/isInProgress/digest` and `VisualVertexModel.digest` +
  `Digestible` deleted (grep-confirmed no external callers — only `isRunning`/`running` are live).
  `VisualVertexModel.phase()`'s Error TODO left for phase 4.
- Verification green: `:kzen-auto-common:allTests`, `:kzen-auto-js:compileKotlinJs` (the trimmed
  common models still compile the JS frontend), full `:kzen-auto-jvm:test` (incl. `FlowMigrationTest`,
  proving instance-per-run didn't break capture/restore). Manual smoke (step/free-run FizzBuzz Flow
  Loop in the dev loop) remains for the next dev-loop session.

---

## Phase 3 — Vertex SPI generalization: capabilities, not classes

**Goal:** the engine dispatches on capability interfaces, not concrete vertex classes — a
third-party vertex can host a child Logic, read run arguments, or contribute to the result
tuple with zero shared-code edits. Message inspection moves to the vertex. kzen-auto-common +
kzen-auto-jvm.

### Design decisions

- **Three capability interfaces** in `paradigm/flow/api/` (common — they are contract, not
  server detail):
  - `FlowRunInput { val tupleComponentName: TupleComponentName }` — a source vertex whose
    message is seeded from the run's input tuple. `FlowInputVertex` implements it; `FlowRun`'s
    `is FlowInputVertex` branch (FlowRun.kt:229-233) retargets to the interface.
  - `FlowRunOutput { val tupleComponentName: TupleComponentName }` — a sink vertex whose message
    is harvested into the result tuple. `FlowOutputVertex` implements it; retarget
    FlowRun.kt:150-152, :237-241.
  - `FlowLogicHost { val instructions: ObjectLocation }` — a vertex that invokes another Logic
    as a hosted child. `RunLogicVertex` implements it; retarget FlowRun.kt:132-136 and
    `FlowLogicCompiler`'s childLogics discovery (FlowLogicCompiler.kt:60-67). The compiler keeps
    its graph-instance walk for this discovery (capability detection needs instances; that walk
    is once per compile, acceptable) — or, if trivial while in there, detect via metadata
    inheritance chain like `FlowConventions.isPipeArchetype`; implementer's choice, note it.
  - `StatelessFlowVertex` gains nothing; a capability vertex may still implement
    `FlowVertex.process` for the non-capability path or throw as `RunLogicVertex` does today —
    keep `process()` throwing on host vertices but reword the message (no more "executed by
    FlowExecution").
- **Message inspection moves to the vertex**: `FlowVertex` gains
  `fun inspectMessage(message: Any): ExecutionValue? = null` (default null → runner falls back
  to basics/`toString` from phase 2). The emitting vertex knows its message types — this is the
  natural home, the same reasoning as `inspectState`. `FlowMessageInspector` is then **deleted**
  (it has no registrations to migrate — remove from `KzenAutoContext`, `LogicCompilerServices`,
  `ServerLogicController`, `FlowLogic`/`FlowRun` constructor threading, and the test call
  sites; the docs table row in `docs/architecture.md` § 4 goes too).
- **Channel contract enforcement** (`MutableFlowOutput`, MutableFlowOutput.kt): construct it
  typed by which interface the attribute declared (FlowWiring already knows,
  FlowWiring.kt:97-116): `RequiredOutput` throws at drain time if nothing was emitted;
  `OptionalOutput`/`BatchOutput`/`StreamOutput` keep current semantics; `set` called twice
  without a drain on a non-batch output throws (catches the classic accidental double-emit).
  Failures surface through the vertex's `recoverable` wrapper like any vertex error.
- **Multi-parameter `FlowLogicHost` binding**: replace the first-parameter-only rule
  (FlowRun.kt:174-182) with: the vertex's wired inputs bind to the callee's parameters **by
  declared input order → parameter order** (a `RunLogic` archetype variant with two inputs
  binds them to the callee's first two parameters), plus a notation `arguments:` map on the
  vertex (parameter name → literal) for constants — mirroring Script's
  `RunStepArgumentsEditor` model. The single-input default stays exactly today's behaviour.
  Client editing of `arguments:` reuses the existing attribute-editor machinery (the
  `SelectLogicEditor` + signature display already exist for `instructions`); keep it minimal.
- **Stale-doc sweep rides here** (these files are all being edited anyway): rewrite the KDocs of
  `RunLogicVertex` / `FlowInputVertex` / `FlowOutputVertex` (the "FlowDocument reads
  tupleComponentName" claim — false since phase 1 moved signature derivation to
  `FlowConventions`), `FlowConventions.kt:58-59` ("FlowDocument.define()"),
  `FlowLogicCompiler.kt:28` (same), and `FlowMatrix.kt:22`'s stale "TODO: optimize via mutable
  builder" if untrue after phase 1. (The retired-`FlowExecution` references in those three vertex
  KDocs + the `RunLogicVertex.process()` message were already cleaned in the FL2 session — they
  now name `FlowRun`; only the `FlowDocument`/signature staleness remains here.)
- **Third-party proof — the phase's acceptance criterion**: a synthetic capability vertex under
  `src/main` test-fixtures style (the Job synthetic-worker convention; KSP/`@Reflect` requires
  `src/main`) — e.g. a `ConstantInputVertex` implementing `FlowRunInput` with a transformed
  name, or a second `FlowLogicHost` — plus a test notation + test proving it runs **without any
  edit to `FlowRun` / `FlowLogicCompiler` / shared code**.

**Verify:** `:kzen-auto-jvm:test` — all existing Flow tests green (behaviour identical for the
three built-ins), new capability-vertex test green, new multi-parameter RunLogic test (a callee
with two parameters receives both); `AGENTS.md` god-object gotcha gains Flow vertices as a
conforming example (one sentence).

---

## Phase 4 — Client: render performance, error visibility, display hygiene

**Goal:** the grid stops re-deriving the routing model per cell per render; a failed vertex is
visibly failed; trace refetching is scoped to this document's runs. kzen-auto-js +
kzen-auto-common (one enum fix).

### Design decisions

- **Compute routing once, pass it down.** `FlowController.nonEmptyDag` already builds
  `flowMatrix` + `flowDag` once per render (FlowController.kt:358-363); also compute
  `nextToRun = FlowUtils.next(flowMatrix, flowDag, visualFlowModel)` and
  `runningVertex = visualFlowModel.running()` there, and pass both as props through
  `CellController` to `VertexController` / `EdgeController`. Delete the per-cell
  `FlowUtils.next(documentPath, graphStructure, ...)` calls (VertexController.kt:286-289,
  EdgeController.kt:112-118) — the convenience overload's only remaining callers; remove it
  (FlowUtils.kt:20-30) so the O(V²) path can't return.
- **Consumed-subset state in `FlowController`** (script plan phase 8 conventions): stop storing
  the whole `ClientState` (FlowController.kt:170-176); keep what render reads — the
  `DocumentNotation`/`GraphStructure` handle needed for matrix building (reference-stable
  between notation events), navigation path, and the derived `visualFlowModel`. Child props
  should be referentially stable so `RPureComponent` bails when nothing relevant changed. Don't
  over-engineer: the win is "attribute keystroke doesn't rebuild every card", verified in React
  DevTools' highlight-updates overlay.
- **Error becomes a real phase.** `VisualVertexModel.phase()` returns
  `VisualVertexPhase.Error` when `error != null` (resolving the TODO, VisualVertexModel.kt:96 —
  precedence: running > error > pending/remaining/done). The dead red branch in
  `VertexController` (VertexController.kt:321-322) comes alive; additionally render the error
  text in the card body (a compact red strip under the header, full text on title/tooltip) —
  pause-on-error's parked vertex is now self-explanatory. Verify the phase change doesn't
  confuse `FlowUtils` routing: the run loop's own snapshot builds models with `running=false`
  and reads only message/hasNext/epoch (FlowRun.kt:448-467) — `nextInLayer` skips
  non-Pending/Remaining phases, so an errored vertex stops being selected client-side exactly
  as it should; add a 1a-suite case for it (error vertex not `next`).
- **Refetch scoping**: include the document's own involvement in `fetchKey` — refetch per poll
  only when the active run's frame tree contains this document (`LogicRunFrames.frameForDocument`
  already answers this, FlowProgressStore.kt:43); otherwise key on run id + run presence so an
  unrelated run triggers at most one refetch on start and one on settle
  (FlowController.kt:190-197).
- **Display hygiene**: truncate the inline message text (`+"${vertexMessage.get()}"`,
  VertexController.kt:786) and state text (VertexController.kt:889) to a short single line with
  full content behind the existing title/tooltip affordance; fix `defaultIcon =
  "SettingsInputComponent"` (a legacy MUI name that only resolves via the alias map,
  VertexController.kt:81) to a `material-symbols:` name.

**Verify:** manual `frontendDevelopment` smoke — step FizzBuzz Flow Loop: next-vertex
highlighting and pipe tinting identical to before (screenshot-compare a couple of stepping
states by eye); trigger a vertex error with pause-on-error on: card turns red with the message
visible, fix + resume clears it; React DevTools highlight-updates: editing one vertex's
attribute no longer flashes every card; a Script running in another tab doesn't cause continuous
Flow refetching (network tab). `:kzen-auto-js:build` green; jvm tests green (the common enum
change is covered by the 1a suite's new error-phase case).

---

## Phase 5 — Editing UX: move, auto-pipe, shifting, legacy cleanup

**Goal:** a Flow can be rearranged without destroying it — move replaces delete-and-recreate,
and pipe placement gets routing assistance — all within the existing geometry model and notation
shape. kzen-auto-js (+ possibly a common helper for path routing).

### Design decisions

- **Move commands, menu-first.** Vertex options menu (VertexController.kt:651-665) gains
  Move Up / Down / Left / Right (disabled when the target cell is occupied — the client has the
  matrix to check), issuing `UpsertAttributeCommand`s on the vertex's `row`/`column`; the edge
  menu gains the same for its coordinate map entries. This is deliberately humble: correct,
  incremental, undo-friendly (each move is one notation command), and it makes the phase-1 lint
  the safety net (a move that severs wiring shows the banner immediately).
- **Auto-pipe tool.** The high-leverage assist: select a source vertex then a destination vertex
  (a two-click "Connect" mode entered from the ribbon or the vertex menu), and the client
  computes a pipe path — straight down when the column matches and rows are adjacent-free;
  otherwise down-then-across-then-down using the fewest cells through unoccupied grid space
  (simple BFS over free cells; the 13 orientations are just the local join shapes of the path) —
  and inserts the `edges` entries as one command batch. On no-path, say so. This removes most of
  the 13-glyph hand-placement pain without touching the model. Put the path→orientations
  routing in common beside `FlowMatrix` (pure, unit-testable — add cases to the 1a suite).
- **Row/column insert & delete shifting**: ribbon or context actions "insert row above/below" /
  "insert column left/right" / "delete empty row/column" that batch-update every affected
  vertex/edge coordinate (client-side computation over the matrix; one command list). Refuse to
  delete a non-empty row/column.
- **Legacy cleanup**: port `PluginController.kt:212` to the current attribute-editor machinery
  (`AttributePathValueEditor` — same shape the modern editors use), then delete
  `objects/document/flow/edit/` entirely (5 `*Old.kt` files; `AttributePathValueEditorOld` was
  their only live consumer). Confirms the js-architecture doc's long-standing deletion note.
- Insert-mode polish riding along: the invisible insertion `IconButton`s
  (opacity 0 when not inserting, FlowController.kt:452-473) become non-interactive when hidden
  (`pointerEvents = none`) so they can't swallow clicks.

**Verify:** manual smoke is the substance here — build a 3-layer flow from scratch using only
ribbon inserts + Connect; move a mid-flow vertex right and watch the lint flag the severed pipe,
then auto-pipe reconnects it; insert a row above the middle layer, everything shifts intact,
run still green. commonTest routing cases green; `:kzen-auto-js:build`; plugin document editor
still edits its path attribute (PluginController port).

---

## Phase 6 — Decision gate: expressiveness — multi-output, crossing, nested loops

**This phase starts with three decisions, not code.** Each expands what the paradigm can express;
each has real cost. Decide per item, record rationale here as the as-built note, build only what
is decided in.

- **Multi-output vertices.** Today one hardcoded `output` channel is drained
  (`FlowUtils.mainOutputAttributeName`, FlowRun.kt:262-263); fan-out duplicates one message to
  all successors below. Option: metadata-declared named outputs (mirror of inputs), each with
  its own column offset — the geometry generalizes cleanly (outputs occupy `column..column+k`
  on the egress side exactly as inputs do on ingress), `ActiveVertexModel.message` becomes
  per-output, and routing/tracing/harvest all grow a dimension. Sizeable (touches matrix, dag,
  run loop, visual model, both controllers); decide only with a concrete driving use case
  (e.g. a splitter/router vertex for time-series partitioning). If deferred: document the
  single-output rule explicitly in `FlowVertex`'s KDoc and `docs/architecture.md`.
- **Pipe crossing.** No orientation lets a vertical run pass over a horizontal one without
  joining, so non-planar wirings are inexpressible. Option: one new `CrossingPipe` orientation
  (top→bottom and left→right independently, no join) — small, self-contained (enum + trace
  functions + a glyph), and the 1a test suite makes it safe. This is the cheapest of the three;
  build it if any real flow has needed it, otherwise document the planarity constraint.
- **Nested-loop semantics.** With two stream sources at different layers, `clearIterationForLoop`
  resets downstream epochs/messages but not state (FlowRun.kt:331-367), so an inner source
  resumes rather than restarting — no Cartesian product. Decide whether that resume-semantics is
  the *defined* behaviour (likely yes — it matches "stateful vertices coordinated precisely")
  and pin it with a two-source test + a paragraph in `docs/architecture.md`; or spec a restart
  marker (e.g. a `resetEachIteration` flag on source archetypes) if a product need exists.
  Either way the current behaviour stops being unspecified.

Do **not** let any of these leak speculatively into phases 1–5; phase 1's tests and phase 3's
capability interfaces are all the pre-work they need.

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 1 — structure core | common + jvm | one session | low-medium (readiness semantics change) | — |
| 2 — server run loop | jvm | one session | medium (instance-lifetime contract) | 1 recommended (tests as net) |
| 3 — vertex SPI | common + jvm | one session | medium (API surface, wide but mechanical) | 2 (FlowRun already refactored) |
| 4 — client perf + errors | js + 1 common enum | one session | low | 1 (error-phase routing case) |
| 5 — editing UX | js (+ common routing helper) | one full session | medium (command batches over live docs) | 1 (lint as safety net) |
| 6 — decision gate | docs or common+jvm+js | decision + 0–1 session | n/a to medium-high | 1, 3 |

Phases 1–2 are the priority core (the untested load-bearing layer + the N×V rebuild and
trace run-killer); 3 is the architectural payoff (the same open-extension contract the rest of
the codebase honours); 4–5 are user-visible quality and can land in either order after 1;
6 is deliberately last and may be a docs-only session. Phases 1 and 5 split cleanly at their
lettered/bulleted sub-items if a session runs long — note the split in the tracker.
