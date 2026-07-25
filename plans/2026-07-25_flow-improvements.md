# Flow (synchronous dataflow) improvements — remaining phases (FL5–FL6)

> **Status: planned.** Successor to `sprint-2/2026-07-16_flow-improvements.md` (Sprint 1: FL1–FL2;
> Sprint 2: FL3–FL4 landed 2026-07-21). This document carries FL5–FL6 forward, complete and
> self-contained. Executor: **Opus-class, one phase per session.** Each phase is self-contained:
> goal, design decisions (already made — do not re-litigate), concrete steps with file anchors,
> and verification. Phase 6 is a **decision gate**, not a build order. Phase IDs are stable across
> the sprint reorganization.
>
> Both phases are **kzen-auto only** (no kzen-lib changes) — no `publishToMavenLocal` round-trips.
>
> **Progress tracker** (update as phases land):
> - [ ] Phase 5 — editing UX: move commands, auto-pipe routing tool, row/column shifting
> - [ ] Phase 6 — decision gate: expressiveness (multi-output, pipe crossing, nested-loop
>   semantics) — decide, then build or document

## Landed context — what FL5–FL6 can rely on

**FL1 ✓ (Sprint 1).** Structure-core test harness + the dangling-pipe lint + the revised
optional-input readiness rule. **The lint is FL5's safety net**: a move that severs wiring shows
the banner immediately, which is what makes menu-first moves safe to ship without a full
constraint solver.

**FL2 ✓ (Sprint 1).** Graph instance per run; non-fatal + throttled tracing (checkpoint-gap pause
proxy); `FlowMessageInspector` defused.

**FL3 ✓ 2026-07-21 — vertex capability SPI.** Capability interfaces replaced concrete-class
special cases; message inspection moved onto the vertex; channel contracts and multi-parameter
`RunLogic` landed. Fixtures took the **reflective-mirror** path (R1 having landed) rather than a
`FlowVertexTestModule`, and the capability fixture got its own callee document so
`LinkedLogicDocumentsTest`'s three-paradigm assertion stays about the production archetypes.
**This is FL6's prerequisite — the gate is unblocked.**

**FL4 ✓ 2026-07-21 — client render perf + Error phase.** Compute-once routing, consumed-subset
state, the Error phase rendered, refetch scoping, display hygiene. As-built worth carrying:
refetch was **mostly already fixed by E5/TP4**, so only the per-document involvement gate was
added; both jvm `FlowRun` additions were required by the Error phase.

**AE1 ✓ 2026-07-19 — the `flow/edit/*Old.kt` fork is gone.** FL5's old dependency on that cleanup
is **satisfied**; do not re-plan it. `PluginController` was ported to `TextAttributeEditor` and the
`common-js.yaml` registrations were removed at the same time.

**Client conventions FL5 must honour.** The render-scoping discipline FL4 applied is written up in
`kzen-auto/docs/js-architecture.md` §2 — consumed-subset state, no whole-`ClientState` stores,
value-compare guards before `publish()`. New editing affordances follow it from the start.

**Shared editor primitives now exist** (AE3–AE6): `DebouncedSubmitter` / `AttributeCommitter` /
`CommonEditUtils.applyCommand` for commits, `SelectReferenceEditorBase` for reference selects, and
`AttributeWrapperLookup` as the single owner of the `editor:`/`summary:` metadata convention. Since
2026-07-23 the commit path also reports edit-pending through `DocumentEditActivity` into
`LogicValidationGlobal`, so the ribbon busy indicator lights on keystroke. **Any new FL5 editor
must route commits through these, not a parallel set.**

---

## Phase 5 — Editing UX: move, auto-pipe, shifting

**Goal:** a Flow can be rearranged without destroying it — move replaces delete-and-recreate, and
pipe placement gets routing assistance — all within the existing geometry model and notation
shape. kzen-auto-js (+ a common helper for path routing).

### Design decisions

- **Move commands, menu-first.** The vertex options menu (`VertexController.renderOptionsMenu` →
  `renderMenuItems`) gains Move Up / Down / Left / Right, disabled when the target cell is occupied
  (the client already holds the matrix to check), issuing `UpsertAttributeCommand`s on the vertex's
  `row`/`column`. The edge menu gains the same for its coordinate-map entries. Deliberately humble:
  correct, incremental, undo-friendly (one move = one notation command), and the FL1 lint is the
  safety net.
- **Auto-pipe tool — the high-leverage assist.** Select a source vertex then a destination vertex
  (a two-click "Connect" mode entered from the ribbon or the vertex menu); the client computes a
  pipe path — straight down when the column matches and rows are adjacent-free, otherwise
  down-then-across-then-down through the fewest unoccupied cells (simple BFS over free cells; the
  13 orientations are just the local join shapes of the resulting path) — and inserts the `edges`
  entries as **one command batch**. On no-path, say so. Put the path→orientations routing in
  commonMain beside `FlowMatrix`
  (`kzen-auto-common/.../common/paradigm/flow/model/structure/`) so it is pure and unit-testable;
  add cases to the FL1 suites.
- **Row/column insert & delete shifting.** Ribbon or context actions — "insert row above/below",
  "insert column left/right", "delete empty row/column" — batch-updating every affected
  vertex/edge coordinate (client-side computation over the matrix, one command list). Refuse to
  delete a non-empty row/column.
- **Insert-mode polish riding along.** The invisible insertion `IconButton`s (opacity 0 when not
  inserting, in `FlowController`) become non-interactive when hidden (`pointerEvents = none`) so
  they cannot swallow clicks.
- **Drag-and-drop is explicitly NOT this phase.** It is a possible follow-up *after* the
  command/menu move exists and the routing helper is proven.

**Verify:** manual smoke is the substance — build a 3-layer flow from scratch using only ribbon
inserts + Connect; move a mid-flow vertex right and watch the lint flag the severed pipe, then
auto-pipe reconnects it; insert a row above the middle layer, everything shifts intact, run still
green. commonTest routing cases green; `:kzen-auto-js:compileKotlinJs` as the fast gate, then
`:kzen-auto-js:build`.

**Split point if the session runs long:** move commands (+ the lint proof) are shippable alone;
auto-pipe + shifting is the natural second half. Note the split in the tracker.

---

## Phase 6 — Decision gate: expressiveness — multi-output, crossing, nested loops

**This phase starts with three decisions, not code.** Each expands what the paradigm can express;
each has real cost. Decide per item, record the rationale here as the as-built note, build only
what is decided in. Depends on FL1 + FL3 — **both landed, so the gate is open.**

- **Multi-output vertices.** Today one hardcoded `output` channel is drained
  (`FlowUtils.mainOutputAttributeName` in `common/paradigm/flow/util/`, consumed at two sites in
  `FlowRun`); fan-out duplicates one message to
  all successors below. Option: metadata-declared named outputs (a mirror of inputs), each with its
  own column offset — the geometry generalizes cleanly (outputs occupy `column..column+k` on the
  egress side exactly as inputs do on ingress), `ActiveVertexModel.message` becomes per-output, and
  routing/tracing/harvest all grow a dimension. Sizeable (touches matrix, dag, run loop, visual
  model, both controllers); **decide in only with a concrete driving use case** (e.g. a
  splitter/router vertex for time-series partitioning). If deferred: document the single-output
  rule explicitly in `FlowVertex`'s KDoc and `kzen-auto/docs/architecture.md`.
- **Pipe crossing.** No orientation lets a vertical run pass over a horizontal one without joining,
  so non-planar wirings are inexpressible. Option: one new `CrossingPipe` orientation (top→bottom
  and left→right independently, no join) — small and self-contained (enum + trace functions + a
  glyph), and the FL1 suites make it safe. **Cheapest of the three**; build it if any real flow has
  needed it, otherwise document the planarity constraint.
- **Nested-loop semantics.** With two stream sources at different layers, `clearIterationForLoop`
  resets downstream epochs/messages but not state, so an inner source **resumes rather than
  restarting** — no Cartesian product. Decide whether that resume-semantics is the *defined*
  behaviour (likely yes — it matches "stateful vertices coordinated precisely") and pin it with a
  two-source test plus a paragraph in `kzen-auto/docs/architecture.md`; or spec a restart marker
  (e.g. a `resetEachIteration` flag on source archetypes) if a product need exists. **Either way
  the current behaviour stops being unspecified** — that is this item's minimum deliverable.

Do **not** let any of these leak speculatively into phase 5. FL1's tests and FL3's capability
interfaces are all the pre-work they need.

**Verify:** if docs-only, the decisions and their rationale are recorded here and in
`kzen-auto/docs/architecture.md`, and the nested-loop test exists. If anything is built in, its own
tests plus `:kzen-auto-jvm:test` + `:kzen-auto-js:build`.

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 5 — editing UX | js (+ common routing helper) | one full session (splits cleanly) | medium (command batches over live docs) | FL1 ✓ (lint), AE1 ✓ |
| 6 — decision gate | docs, or common+jvm+js | decision + 0–1 session | n/a to medium-high | FL1 ✓, FL3 ✓ |

The two are independent and can run in either order; 6 is deliberately last and may be a docs-only
session.

## Outstanding manual smoke owed by earlier Flow phases

Both FL3 and FL4 were headless-verified only. Their browser passes are consolidated into the
smoke-debt checklist in `2026-07-25_core-and-verification.md` — do **not** re-plan them here:
FL3's `RunLogic2` ribbon tool + arguments-editor round-trip, FL4's Error-phase rendering and
refetch scoping, and FL1/FL2's dangling-pipe lint banner + step/free-run FizzBuzz Flow Loop.

## Covered elsewhere — do not duplicate

- **Legacy editor cleanup** — done (AE1, 2026-07-19).
- **Client render-scoping conventions** — `kzen-auto/docs/js-architecture.md` §2 (written up by
  the S8 sweep); FL4 already applied them to Flow.
- **Flow structural validation surfacing** — landed 2026-07-22 with the flavour-agnostic
  `LogicValidationGlobal`; the Flow publisher moved findings computation out of
  `renderStructureFindings` into the state-derivation path, which fixed the "broken flow, Run
  enabled" gap. Do not re-plan it.
