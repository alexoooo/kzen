# Flow (synchronous dataflow) improvements — remaining phases (FL3–FL6)

> **Status: planned.** Successor to `sprint-1/2026-07-06_flow-improvements.md` (Sprint 1:
> FL1–FL2 landed; this document carries FL3–FL6 forward, complete and self-contained).
> Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is self-contained: goal,
> design decisions (already made — do not re-litigate), concrete steps with file anchors, and
> verification. Phase 6 is a **decision gate**, not a build order. Phase IDs are stable across
> the sprint reorganization.
>
> All phases are **kzen-auto only** (no kzen-lib changes) — no publishToMavenLocal round-trips
> needed.
>
> Companion plans: `2026-07-16_script-client-sweep.md` (defines the client render-scoping
> conventions phase 4 here applies — those conventions are also already written up in
> `kzen-auto/docs/js-architecture.md` §2, so phase 4 need not wait on S8),
> `2026-07-16_graph-improvements.md` (G3a would further scope Flow's per-vertex closure — the
> FL2 instance-per-run fix stands on its own regardless),
> `2026-07-14_attribute-editor-improvements.md` (its AE1 owns the legacy `flow/edit/*Old.kt`
> cleanup that used to be a phase-5 bullet here).
>
> **Progress tracker** (update as phases land):
> - [ ] Phase 3 — vertex SPI generalization: capability interfaces replace concrete-class
>   special cases, message inspection on the vertex, channel contracts, multi-parameter RunLogic
> - [ ] Phase 4 — client render performance + error visibility: compute-once routing,
>   consumed-subset state, Error phase rendered, refetch scoping, display hygiene
> - [ ] Phase 5 — editing UX: move commands, auto-pipe routing tool, row/column shifting
> - [ ] Phase 6 — decision gate: expressiveness (multi-output, pipe crossing, nested-loop
>   semantics) — decide, then build or document

## Landed context (Sprint 1) — what FL3–FL6 can rely on

- **FL1 ✓ 2026-07-11 — structure core.** The geometry→DAG layer (`FlowMatrix`/`FlowDag`/
  `FlowUtils`) has a direct commonTest harness (5 test files under `paradigm/flow/`, incl.
  `FlowStructureTestBuilder`); `FlowStructureValidator` (in `objects/document/flow`) lints
  structure pre-run (compiler throws `LogicFailure` with findings; client renders a banner);
  `FlowWiring.define`'s `TODO(...)` and bad-orientation crashes became definition failures;
  signature derivation is single-sourced in `FlowConventions` (resolves the `vertices` list
  references — the compiler's instance walk survives only for childLogics discovery, which FL3
  retargets). **Readiness rule (revised same-day after a FizzBuzz Flow Loop regression):**
  required inputs are strict (wired + upstream message), a wired optional never gates on its
  own, and at least one wired input must hold a message — pinned by
  `FlowUtilsNextTest.selectLastRunsWhenOnlyOneWiredOptionalHasMessage` +
  `FlowNotationTest.selectLastMergesWhicheverBranchProducedEachIteration`. The cycle finding
  was dropped as unrepresentable (matrix-derived DAGs are acyclic by construction).
- **FL2 ✓ 2026-07-11 — server run loop.** Graph instance **per run** (not per vertex
  execution) — a contract clarification documented in `FlowVertex`'s KDoc (vertex instances
  live for the run; fresh on live-edit migration); `createInstance` became `instanceFor` (a
  lookup on the run's single `GraphInstance`); tracing is non-fatal (truncated-`toString`
  fallback, ≤1024 chars) and throttled (paused/stepping detected via a ≥50 ms checkpoint-gap
  proxy — `Execution` deliberately exposes no run-mode query; free-running per-vertex ≥100 ms
  window; error and run-end traces forced); `MutableFlowOutput.clear()` runs before every
  `process`; `FlowMessageInspector.inspectMessage` no longer throws (supertype-aware registry
  match, then toString fallback) — **the registry is still empty; FL3 deletes the class**.
  Benchmark canary: 1..2000 stream × 3-vertex chain ~1.3 s (bound 10 s) pins the N×V rebuild
  regression. `VisualFlowModel`'s dead members and `VisualVertexModel.digest` were deleted;
  **`VisualVertexModel.phase()`'s Error TODO was explicitly left for FL4.**

The execution core is strong and every phase preserves it: `FlowRun` on the RunEngine (vertex
as the step boundary via `execution.checkpoint()`, pause-on-error via `execution.recoverable`,
child hosting via `execution.host`), live-edit migration (`FlowMigrationState`, stable-id-keyed,
pinned by `FlowMigrationTest`), trace-store integration (per-vertex `VisualVertexModel` at
stable-id addresses, frame-keyed in `FlowProgressStore`), and the paradigm itself — fully
deterministic single-stepping over a stateful vertex DAG; zero parallelism is a feature.

The still-open weaknesses:

1. **The engine special-cases three concrete vertex classes — the god-object shape** (→ FL3).
   `FlowRun` branches on `reference is RunLogicVertex` (FlowRun.kt:132), `is FlowInputVertex`
   (:229), `is FlowOutputVertex` (:150, :237), and `FlowLogicCompiler` repeats the same
   three-way dispatch (FlowLogicCompiler.kt:53-70). A third-party vertex can never host a child
   Logic, read run arguments, or contribute to the result tuple. Related SPI debt:
   `MutableFlowOutput` implements all four output interfaces with contracts unenforced (a
   `RequiredOutput` vertex can silently emit nothing); `RunLogicVertex` binds only the callee's
   **first** parameter (FlowRun.kt:174-182) vs Script's full `RunStepArgumentsEditor`; and the
   vertex KDocs still claim `FlowDocument.define()` reads `tupleComponentName` (false since FL1
   moved signature derivation).
2. **The client re-derives the routing model per vertex per render, and hides errors** (→ FL4).
   `VertexController.renderVertex` calls the `FlowUtils.next(documentPath, graphStructure,
   visualFlowModel)` overload that rebuilds `FlowMatrix` + `FlowDag` from notation — per vertex,
   per render (VertexController.kt:286-289); `EdgeController.nextToRun()` does the same per edge
   (EdgeController.kt:112-118) — even though both already receive `flowMatrix` and `flowDag` as
   props. `FlowController` stores the whole fresh-reference `ClientState` in component state
   (FlowController.kt:170-176), defeating `RPureComponent`'s shallow-equal, so the entire grid
   re-renders on every publish — every keystroke in any attribute editor triggers O(V²) DAG
   rebuilding. **Errors are invisible**: `VisualVertexPhase.Error` is unreachable (`phase()`
   never returns it — the TODO FL2 left), so `VertexController`'s red-card branch is dead code
   and nothing renders `model.error` — pause-on-error parks a vertex with a populated error and
   the card shows nothing. Minor: `fetchKey` scoping (see FL4 — note E5 replaced
   `logicStatus.time` with epoch/sequence versioning, so re-verify the current refetch key
   before changing it); message/state render as raw unbounded `+"${value.get()}"`
   (VertexController.kt:786, :889).
3. **Editing is insert-and-delete only** (→ FL5). `VertexController.renderAttributes` filters
   out `row`/`column` (VertexController.kt:494-501) and the options menu has only Delete
   (:651-665) — repositioning means delete + recreate, losing configuration. Pipes are
   hand-placed from 13 orientation glyphs (flow-edge.yaml) with no routing assistance.

**Covered elsewhere — do not re-do here:** engine stepping semantics (the engine owns them;
Flow's step boundary stays `execution.checkpoint()`, nothing more); per-vertex scoped
instantiation (graph plan G3a — FL2's instance-per-run stands regardless); client
render-scoping conventions (defined in js-architecture.md §2 + refined by S8 — FL4 applies
them, doesn't re-derive them); Logic signature/composition UX across document types (job plan
J2 — Flow's input/output vertices already produce a signature); the legacy `flow/edit/*Old.kt`
cluster (**AE1 owns it** — if AE1 has not landed when FL5 runs, execute AE1 first as its own
session rather than folding it in).

**Deliberately out of scope** (decided; do not re-open inside a phase):
- **Replacing geometry-as-wiring with explicit named edges + auto-layout.** Scrutinized and
  settled: the grid model is deterministic, tangible, diff-able in notation, and avoids a layout
  engine. Its costs are addressed *within* the model (FL1 validation, FL5 move/auto-pipe) — not
  by replacing it. The `vertices`/`edges` notation shape (row/column/orientation) is stable;
  **no migration of user documents in any phase**.
- **Any parallelism** — deterministic single-stepping is the paradigm's identity.
- Drag-and-drop editing — FL5 is command/menu-based move; DnD is a possible follow-up once move
  commands exist.
- A time-series vertex library (windowing, resampling, joins) — becomes easier after FL3's SPI
  work; none of it is built in this plan.
- Undo/redo — a kzen-lib/notation-CQRS-wide concern, not Flow's.
- Client-side unit tests for the JS controllers — the structure core lives under `commonTest`
  (FL1) where both platforms share it; JS-side verification stays manual smoke.

## Ground rules for every phase

- **No new vertex-type-specific code in shared layers.** The three existing concrete-class
  special cases are quarantined until phase 3 dissolves them; no phase may add branches on
  vertex types anywhere (`FlowRun`, `FlowUtils`, controllers).
- **Notation compatibility is absolute**: every existing Flow document (including the user's
  `notation/main/FizzBuzz/FizzBuzz Flow Loop.yaml` — a working document; never edit or delete
  it) keeps running unchanged through every phase.
- **Dev loop:** kzen-auto only. `./gradlew -t :kzen-auto-jvm:classes` + IDE `BackendDevelopment`
  for server phases; `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` for client phases.
- **Verification baseline (every phase):** `./gradlew :kzen-auto-jvm:test` (must include
  `FlowNotationTest`, `FlowControllerStepTest`, `FlowMigrationTest` green, plus FL1's structure
  suites). Client phases add a manual `frontendDevelopment` smoke against a scratch Flow
  document created through the UI (insert vertices/pipes, Run, Step, pause-on-error).
  `./gradlew :kzen-auto-test:selfTest` as the broad regression net.
- Mark the phase checkbox in this file's tracker when done; append an as-built note on deviation.

---

## Phase 3 — Vertex SPI generalization: capabilities, not classes

**Goal:** the engine dispatches on capability interfaces, not concrete vertex classes — a
third-party vertex can host a child Logic, read run arguments, or contribute to the result
tuple with zero shared-code edits. Message inspection moves to the vertex. kzen-auto-common +
kzen-auto-jvm. Depends on FL2 (met — `FlowRun` already refactored).

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
    keep `process()` throwing on host vertices with an accurate message.
- **Message inspection moves to the vertex**: `FlowVertex` gains
  `fun inspectMessage(message: Any): ExecutionValue? = null` (default null → runner falls back
  to basics/`toString` from FL2). The emitting vertex knows its message types — this is the
  natural home, the same reasoning as `inspectState`. `FlowMessageInspector` is then **deleted**
  (it has no registrations to migrate — remove from `KzenAutoContext`, `LogicCompilerServices`,
  `ServerLogicController`, `FlowLogic`/`FlowRun` constructor threading, and the test call
  sites; the docs table row in `kzen-auto/docs/architecture.md` §4 goes too).
- **Channel contract enforcement** (`MutableFlowOutput`): construct it typed by which interface
  the attribute declared (FlowWiring already knows, FlowWiring.kt:97-116): `RequiredOutput`
  throws at drain time if nothing was emitted; `OptionalOutput`/`BatchOutput`/`StreamOutput`
  keep current semantics; `set` called twice without a drain on a non-batch output throws
  (catches the classic accidental double-emit). Failures surface through the vertex's
  `recoverable` wrapper like any vertex error.
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
  tupleComponentName" claim — false since FL1 moved signature derivation to `FlowConventions`),
  `FlowConventions.kt:58-59` ("FlowDocument.define()"), `FlowLogicCompiler.kt:28` (same), and
  `FlowMatrix.kt:22`'s stale "TODO: optimize via mutable builder" if untrue post-FL1. (The
  retired-`FlowExecution` references in the vertex KDocs + the `RunLogicVertex.process()`
  message were already cleaned in the FL2 session — they now name `FlowRun`.)
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
kzen-auto-common (one enum fix). Depends on FL1 (met — error-phase routing case rides the
structure suites).

### Design decisions

- **Compute routing once, pass it down.** `FlowController.nonEmptyDag` already builds
  `flowMatrix` + `flowDag` once per render (FlowController.kt:358-363); also compute
  `nextToRun = FlowUtils.next(flowMatrix, flowDag, visualFlowModel)` and
  `runningVertex = visualFlowModel.running()` there, and pass both as props through
  `CellController` to `VertexController` / `EdgeController`. Delete the per-cell
  `FlowUtils.next(documentPath, graphStructure, ...)` calls (VertexController.kt:286-289,
  EdgeController.kt:112-118) — the convenience overload's only remaining callers; remove it
  (FlowUtils.kt:20-30) so the O(V²) path can't return.
- **Consumed-subset state in `FlowController`** (js-architecture §2 conventions): stop storing
  the whole `ClientState` (FlowController.kt:170-176); keep what render reads — the
  `DocumentNotation`/`GraphStructure` handle needed for matrix building (reference-stable
  between notation events), navigation path, and the derived `visualFlowModel`. Child props
  should be referentially stable so `RPureComponent` bails when nothing relevant changed. Don't
  over-engineer: the win is "attribute keystroke doesn't rebuild every card", verified in React
  DevTools' highlight-updates overlay.
- **Error becomes a real phase.** `VisualVertexModel.phase()` returns
  `VisualVertexPhase.Error` when `error != null` (resolving the TODO FL2 left — precedence:
  running > error > pending/remaining/done). The dead red branch in `VertexController`
  (VertexController.kt:321-322) comes alive; additionally render the error text in the card
  body (a compact red strip under the header, full text on title/tooltip) — pause-on-error's
  parked vertex is now self-explanatory. Verify the phase change doesn't confuse `FlowUtils`
  routing: the run loop's own snapshot builds models with `running=false` and reads only
  message/hasNext/epoch — `nextInLayer` skips non-Pending/Remaining phases, so an errored
  vertex stops being selected client-side exactly as it should; add a structure-suite case for
  it (error vertex not `next`).
- **Refetch scoping**: the original finding was keyed on `logicStatus.time`, which **E5 deleted**
  (status is now versioned by `epoch` + `sequence`, and clients key on
  `ClientLogicState.traceVersion()` with a throttled publish — see kzen-auto architecture §3).
  First re-verify how `FlowController`/`FlowProgressStore` key refetch post-E5; the remaining
  scoping win, if still real, is including *this document's own involvement* in the fetch key —
  refetch per publish only when the active run's frame tree contains this document
  (`LogicRunFrames.frameForDocument` already answers this, FlowProgressStore.kt:43); otherwise
  key on run id + run presence so an unrelated run triggers at most one refetch on start and
  one on settle. Record what was actually needed in the as-built note.
- **Display hygiene**: truncate the inline message text (`+"${vertexMessage.get()}"`,
  VertexController.kt:786) and state text (:889) to a short single line with full content
  behind the existing title/tooltip affordance; fix `defaultIcon = "SettingsInputComponent"`
  (a legacy MUI name that only resolves via the alias map, VertexController.kt:81) to a
  `material-symbols:` name.

**Verify:** manual `frontendDevelopment` smoke — step FizzBuzz Flow Loop: next-vertex
highlighting and pipe tinting identical to before; trigger a vertex error with pause-on-error
on: card turns red with the message visible, fix + resume clears it; React DevTools
highlight-updates: editing one vertex's attribute no longer flashes every card; a Script
running in another tab doesn't cause continuous Flow refetching (network tab).
`:kzen-auto-js:build` green; jvm tests green.

---

## Phase 5 — Editing UX: move, auto-pipe, shifting

**Goal:** a Flow can be rearranged without destroying it — move replaces delete-and-recreate,
and pipe placement gets routing assistance — all within the existing geometry model and notation
shape. kzen-auto-js (+ possibly a common helper for path routing). Depends on FL1 (met — the
lint is the safety net).

### Design decisions

- **Move commands, menu-first.** Vertex options menu (VertexController.kt:651-665) gains
  Move Up / Down / Left / Right (disabled when the target cell is occupied — the client has the
  matrix to check), issuing `UpsertAttributeCommand`s on the vertex's `row`/`column`; the edge
  menu gains the same for its coordinate map entries. This is deliberately humble: correct,
  incremental, undo-friendly (each move is one notation command), and it makes the FL1 lint the
  safety net (a move that severs wiring shows the banner immediately).
- **Auto-pipe tool.** The high-leverage assist: select a source vertex then a destination vertex
  (a two-click "Connect" mode entered from the ribbon or the vertex menu), and the client
  computes a pipe path — straight down when the column matches and rows are adjacent-free;
  otherwise down-then-across-then-down using the fewest cells through unoccupied grid space
  (simple BFS over free cells; the 13 orientations are just the local join shapes of the path) —
  and inserts the `edges` entries as one command batch. On no-path, say so. This removes most of
  the 13-glyph hand-placement pain without touching the model. Put the path→orientations
  routing in common beside `FlowMatrix` (pure, unit-testable — add cases to the FL1 suites).
- **Row/column insert & delete shifting**: ribbon or context actions "insert row above/below" /
  "insert column left/right" / "delete empty row/column" that batch-update every affected
  vertex/edge coordinate (client-side computation over the matrix; one command list). Refuse to
  delete a non-empty row/column.
- **Legacy `flow/edit/*Old.kt` cleanup is owned by AE1** (`2026-07-14_attribute-editor-
  improvements.md` phase 1: the `PluginController` port to `TextAttributeEditor`, the 5-file
  deletion, the `common-js.yaml` registration removal). If AE1 has not landed by the time this
  phase runs, execute AE1 first as its own session rather than folding it in here.
- Insert-mode polish riding along: the invisible insertion `IconButton`s
  (opacity 0 when not inserting, FlowController.kt:452-473) become non-interactive when hidden
  (`pointerEvents = none`) so they can't swallow clicks.

**Verify:** manual smoke is the substance here — build a 3-layer flow from scratch using only
ribbon inserts + Connect; move a mid-flow vertex right and watch the lint flag the severed pipe,
then auto-pipe reconnects it; insert a row above the middle layer, everything shifts intact,
run still green. commonTest routing cases green; `:kzen-auto-js:build`.

---

## Phase 6 — Decision gate: expressiveness — multi-output, crossing, nested loops

**This phase starts with three decisions, not code.** Each expands what the paradigm can express;
each has real cost. Decide per item, record rationale here as the as-built note, build only what
is decided in. Depends on FL1 + FL3.

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
  functions + a glyph), and the FL1 test suites make it safe. This is the cheapest of the
  three; build it if any real flow has needed it, otherwise document the planarity constraint.
- **Nested-loop semantics.** With two stream sources at different layers, `clearIterationForLoop`
  resets downstream epochs/messages but not state (FlowRun.kt:331-367), so an inner source
  resumes rather than restarting — no Cartesian product. Decide whether that resume-semantics is
  the *defined* behaviour (likely yes — it matches "stateful vertices coordinated precisely")
  and pin it with a two-source test + a paragraph in `docs/architecture.md`; or spec a restart
  marker (e.g. a `resetEachIteration` flag on source archetypes) if a product need exists.
  Either way the current behaviour stops being unspecified.

Do **not** let any of these leak speculatively into phases 3–5; FL1's tests and FL3's
capability interfaces are all the pre-work they need.

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 3 — vertex SPI | common + jvm | one session | medium (API surface, wide but mechanical) | FL2 ✓ |
| 4 — client perf + errors | js + 1 common enum | one session | low | FL1 ✓ |
| 5 — editing UX | js (+ common routing helper) | one full session | medium (command batches over live docs) | FL1 ✓ (lint); AE1 for the legacy cleanup |
| 6 — decision gate | docs or common+jvm+js | decision + 0–1 session | n/a to medium-high | FL1 ✓, FL3 |

Phase 3 is the architectural payoff (the same open-extension contract the rest of the codebase
honours); 4–5 are user-visible quality and can land in either order after it (or before it —
they don't depend on 3); 6 is deliberately last and may be a docs-only session. Phase 5 splits
cleanly at its bulleted sub-items if a session runs long — note the split in the tracker.
