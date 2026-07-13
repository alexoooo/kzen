# Execution control — move-to-step (VB "Set Next Statement") for Script — phased plan

> **Status: planned.** Written 2026-07-10 from a design session on repositioning a live Script
> run — "move execution to this step" without executing the intervening steps (backward = re-run
> from the target; forward = skip). Executor: **Opus 4.8 xhigh, one phase per session.** Each
> phase is self-contained: goal, design decisions (already made — do not re-litigate), concrete
> steps with file anchors, and verification.
>
> The full execution-control trio the ask covers:
> - **explicit instruction pointer** → engine-plan phase 2 (`checkpoint(at:)`, `Node.position`) —
>   planned there, prerequisite here;
> - **run up to a step (breakpoint / run-to)** → engine-plan phase 3 — planned there, sibling
>   affordance here;
> - **move execution to a step** → THIS plan (net-new).
>
> Companion plans: `2026-07-05_logic-engine-improvements.md` (engine phases 2-3 are prerequisites
> — see below) and `2026-07-06_script-improvements.md` (loop cursors, phase 5, are the v2
> extension path). This plan does not duplicate their items.
>
> **Progress tracker** (update as phases land):
> - [ ] Phase 1 — engine carry: one-shot move target through the migration barrier (kzen-lib only)
> - [ ] Phase 2 — Script jump semantics + controller + wire (auto-common + auto-jvm + client transport)
> - [ ] Phase 3 — client affordance: "Set next step here" + skipped-step display (auto-js)

## Context

The Script flavour's resume position is **implicit**: `ScriptRunContext.runSteps`
(`kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/script/ScriptRunContext.kt:170-215`)
walks the step list, short-circuiting any step whose stable id is in `restoredOutcomes` (:81,
seeded by `restore` :260-263 from the predecessor's capture) via `adoptCompleted` (:293-299), and
parking at the first step that isn't (its `checkpoint()` at :184). So the "current position" of a
rebuilt run is fully determined by the carried outcome set — which means **repositioning a run is
outcome-set surgery plus the existing migrate-style rebuild** (`RunEngine.migrate`, kzen-lib
`kzen-lib-jvm/src/main/kotlin/tech/kzen/lib/server/exec/engine/RunEngine.kt:308-356`): quiesce →
capture `ScriptMigrationState` (`ScriptMigrationState.kt:25-28`) → transform → rebuild → the
spine re-walk parks where the transformed state says. No coroutine surgery, no new parking
machinery, no new engine control loop.

The one genuinely new mechanism is making the rebuilt spine pass **through** things it must not
park at or produce values for:

- a **skipped step** (forward jump over it): short-circuits with *no value* — distinct from
  `adoptCompleted`, which copies a value into `stepValues` (:73). A later reference hits the
  existing hard check `referencedValue` (:107-111) *inside* the step's `recoverable {}` (:197) →
  pause-on-error parks on the referencing step. That existing backstop is the decided runtime
  policy for skipped-value references.
- a **descend step** (an ancestor `IfStep` of a branch target): must *run* (re-evaluate its
  condition, `IfStep.kt:27-32` — deterministic by design) but must *not* park at its own
  boundary, or a paused rebuild would stop at the If instead of the target. Script owns its own
  `checkpoint` call (`ScriptRunContext.kt:184`), so it can simply suppress it for descend steps —
  the engine needs no run-to machinery for the jump itself.

Everything else is carried by machinery that already exists or is already planned: rebuild =
engine `migrate`; position display = engine-plan phase 2 (`Node.position`, retiring `$next-step`);
the sibling "run to here" affordance = engine-plan phase 3; loop-body targets (v2) = script-plan
phase 5 loop cursors.

## Ground rules

Same as the companion plans (`2026-07-05_logic-engine-improvements.md` "Ground rules" — spec
leads, no flavour-specific code in general layers, mavenLocal dev loop, verification baseline,
wire changes ship both sides in the same phase, tracker + as-built notes). One rule bears
repeating because this feature is exactly where it would be violated: **no `when` over flavours
in `RunEngine` or `ServerLogicController`** — the jump target is an opaque `ObjectStableId` in
the general layers; all interpretation lives in Script; capability detection is a generic
interface next to `Logic`.

## Design decisions (already made — do not re-litigate)

1. **Jump = move the pointer, do not execute intervening steps** (VB Set Next Statement).
   Backward jump re-runs from the target; forward jump skips over.
2. **Skipped steps produce no value.** No server-side static rejection of dangling references:
   the runtime backstop is `referencedValue`'s check inside `recoverable {}` (pause-on-error
   parks the referencing step). Client-side the affordance warns (advisory, via
   `ScriptDependencyAnalysis`) but never blocks.
3. **Loop bodies are out of scope v1**: a target inside a ForEach/DoWhile body is invalid (client
   disables, server rejects via the capability check). A jump *to the loop step itself* is
   allowed — the loop restarts from iteration 0 (its body's stale outcomes drop via the existing
   `dropReplay`, `ForEachStep.kt:46`). v2 extension path: script-plan phase 5's `LoopCursor`
   carry makes "jump to iteration k / into a body" expressible — one paragraph noted there, not
   built here.
4. **Prerequisites**: engine-plan **phase 2 is hard** (position vocabulary: `checkpoint(at:)`,
   `Node.position`, `$next-step` retirement — the jump UI and the no-op guard read position, and
   landing jump before phase 2 would mean adapting the `$next-step` marker protocol twice).
   Engine-plan **phase 3 is soft** (recommended first): the jump *mechanism* never calls
   breakpoints, but the two features share the per-step affordance home. (As built 2026-07-13,
   E3 shipped breakpoints only — `runTo` was dropped per user decision, "run up to a step" =
   breakpoint + Run + remove — and the affordance is a gutter dot on the step run-icon box, not
   a menu — an inline dot in the StepHeader right cluster, immediately left of Delete (the
   user-confirmed home for per-step actions); XC3's "Set next step here" joins that cluster.)
5. **The jump command lives on the controller/migrate path, not on `Run`** (rationale in "Where
   the command lives" below). Engine carries the target as an opaque one-shot value through
   `migrate`; Script interprets it at restore time where the outcome maps live.
6. **Descend-set checkpoint suppression, not engine run-to**: the rebuilt run is `paused = true`;
   ancestors of the target run with their per-step `checkpoint` suppressed by the spine; the
   target itself parks at its ordinary boundary. Considered and rejected: rebuilding `Running`
   with phase-3's one-shot `runToTarget` armed — it works for the happy path but a branch target
   whose condition re-selects the *other* branch would let the run zoom off at full speed
   re-executing everything after the If (real side effects). With paused-rebuild + suppression,
   the worst case is the run parking at the first live step after the container — never
   uncontrolled execution.
7. **If-branch target policy**: jumping to a step inside an If branch drops the If's own outcome
   (descend set), re-evaluates the condition over the same adopted values — deterministic for
   pure formulas — descends, adopts/skips pre-target branch steps, parks at the target. If the
   condition selects the **other** branch (user jumps into the branch that didn't run, or a
   nondeterministic condition flips), the target is simply never reached and the paused rebuild
   parks at the **first live step the walk does reach** (the other branch's head, or the step
   after the If — everything at/after the target was dropped, so something always parks; the run
   cannot run away). This "lands as close as it can" outcome is documented behaviour, and the
   client warns when the target's enclosing branch is not the one the trace shows as taken.
8. **Loop detection is notation-driven**, not step-type-hardcoded: a new attribute-metadata flag
   (`rerun: true`) on the loop body attributes in `script-jvm.yaml` (ForEachStep `steps` meta
   :329-332, DoWhileStep `steps` meta :371-374). A branch under a `rerun` attribute is
   jump-invalid in v1. Read by the shared common analysis, so client and server cannot drift, and
   a third-party loop step opts in declaratively (document next to `ScriptStep.nestedStepLists()`).
9. **Jump requires a settled run**: same guard as `drive` (`ServerLogicController.kt:498-499`).
   Jump while `Running`/`Stepping` is rejected (the client only enables the affordance while
   paused); auto-pause-then-jump is a possible v2, not built. Jump after terminal is refused for
   free (`stateOrNull` cleared at terminal → `NotFound`). Jump while **error-parked is allowed
   and is a headline use case** (jump *past* a failing step = forward skip from the error park).
10. **A jump always recompiles and migrates** — it shares the barrier with any concurrent
    notation edit (the `pendingMigration` concern dissolves: `moveTo` recompiles from the current
    notation unconditionally and updates `baselineNotations` — or `baselineClosureDigest`, once
    graph-plan phase 2 lands — so an edit-then-jump takes both in one rebuild).
11. **Carried `result` is kept** across a jump; a ResultStep at/after the target re-runs and
    overwrites it. Corner (documented, accepted): a forward jump that *skips* a ResultStep which
    had run before an earlier backward jump leaves the older carried result in place.

## Where the command lives (options weighed — decision 5 rationale)

- **(a) Generic `Run.moveTo(target)`**: rejected. `migrate` is deliberately *not* on `Run` (it
  needs a recompiled root `Logic` and controller-side quiescence discipline); a jump *is* a
  migrate, so putting `moveTo` on `Run` would either duplicate the barrier or leak compilation
  into the engine.
- **(b) Controller transforms the captured state** via a `reposition(state, target)` hook:
  rejected. Capture is an opaque `Any?` inside `migrate` (RunEngine.kt:315-324); a transform hook
  between capture and restore adds a second flavour seam for no gain over (c).
- **(c) Engine carries the target; the flavour interprets it at restore** — **chosen**, with one
  element of (a): a tiny generic capability interface so the controller can reject unsupported
  targets *before* tearing anything down. Concretely: `migrate(newRoot, paused, moveTarget)`
  stores a one-shot `ObjectStableId?`; `Execution.moveTarget` exposes it to the rebuilt tree;
  only a Logic whose structure resolves the target interprets it (Script); everything else
  ignores it → the contract for non-supporting flavours is **"ignored: the run rebuilds parked
  at its existing frontier"** (a plain no-op migrate).
  `Repositionable { fun canMoveTo(target): Boolean }` lives next to `Logic` in kzen-lib-common —
  a capability interface, not a flavour `when`; the controller checks
  `newLogic is Repositionable && canMoveTo(target)` and rejects otherwise, which is also how
  loop-body/unknown targets get their server-side rejection without the controller knowing what
  a loop is.

## The jump algorithm (normative for phase 2)

Given target step T in the run's root document, computed against the **current** notation
(`ScriptTree.read`, `kzen-auto-common/.../script/model/ScriptTree.kt:17-57`; document order via
`orderedDescendantObjectPaths` :65-79):

- **valid** iff T resolves to a step in the root `ScriptTree` (not a `parameters`/`item` binding
  branch) and no attribute on the path root→T is marked `rerun` (decision 8). Otherwise invalid →
  controller rejects (client already disabled it).
- **ancestors** (descend set) = the containers on the path root→T (e.g. the enclosing IfStep).
- **drop set** = ancestors ∪ {T} ∪ every step whose document-order index ≥ T's index. (Document
  order puts a container *before* its contents, hence ancestors are added explicitly; other-branch
  steps document-before T are *kept* — harmless: a re-evaluated condition either never visits
  them or adopts them.)
- **restore** = captured `completedOutcomes` minus the drop set (and minus nested-of-dropped, via
  the same recursion as `nestedStableIds`, ScriptRunContext.kt:281-290).
- **skip set** = steps document-before T on the walk path that have **no** carried outcome (never
  ran — forward jump over them; or their entries were coalesced into a container by a *previous*
  migrate/jump — see "coalescing note" below). Computed at restore time (path steps minus
  restored keys).
- Rebuild `paused = true`. The spine then: adopts kept steps (no boundary), short-circuits
  skip-set steps with **no value** and a `Skipped` trace, runs descend-set steps **with their
  checkpoint suppressed**, and parks at T's ordinary `checkpoint` — the first live boundary. If a
  condition sends the walk elsewhere, the first live step there parks instead (decision 7). If
  the target is ignored (non-Script flavour / unresolvable), the full state restores and the run
  parks at its old frontier.

**Coalescing note** (document in `ScriptMigrationState` kdoc and spec §5): `adoptCompleted`
adopts a completed *container* wholesale without re-inserting its branch contents into the new
`completedOutcomes` — so after any migrate/jump, completed branch steps' individual outcomes are
gone. A later jump back *into* such a branch therefore treats its value-less pre-target steps as
skipped (they had run; their values are no longer carried). The backstop of decision 2 covers
references to them; jumping to the earliest needed step instead re-runs everything. Accepted v1
behaviour.

---

## Phase 1 — Engine carry: one-shot move target through the migration barrier (kzen-lib only)

**Goal:** the engine can carry an opaque repositioning target across a `migrate`, and a driver
can detect whether a Logic supports repositioning. No behaviour change for any existing flavour.

**Prerequisite:** engine-plan phase 2 landed (so `Execution`'s signature churn happens once and
the kdoc can reference positions).

### Steps

1. `RunEngine.migrate(newRoot: Logic, paused: Boolean = true, moveTarget: ObjectStableId? = null)`
   (RunEngine.kt:308): store in a new field `migrationMoveTarget` in migrate step 3 (:338-354),
   alongside `migrationCaptured` (:116). Every migrate **overwrites** it (an ordinary
   edit-migrate passes null → cleared), so it is one-shot per barrier by construction; clear it
   in `sweepOrphans` (:362-375) too so `close()` leaves nothing behind.
2. `Execution.moveTarget: ObjectStableId?` — new read-only property in the §5 block of
   `Execution.kt` (next to `restored`, :129-135) wired through `ExecutionImpl`
   (RunEngine.kt:720-764). Kdoc contract: *advisory one-shot repositioning hint set by the driver
   at the migration barrier; a Logic whose structure resolves the id may interpret it when
   adopting `restored` (repositioning the rebuilt walk); any Logic that does not support
   repositioning — or a hosted child in whose structure the id does not resolve — MUST ignore it,
   in which case the rebuild is an ordinary migrate parked at the existing frontier.* Non-null
   only on a rebuilt tree; always null on a fresh run.
3. New `Repositionable` interface in
   `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/exec/engine/` (next to
   `Logic.kt`): `interface Repositionable { fun canMoveTo(target: ObjectStableId): Boolean }`.
   Kdoc: implemented by a `Logic` whose run walk can be repositioned; `canMoveTo` is a static
   structural check (target exists and is a legal v1 target), *not* a reachability guarantee.
4. Spec: `kzen-lib/docs/logic-spec.md` §4 gains a short "Repositioning (move-to)" paragraph —
   the engine's role is carrying the one-shot target through the §5 barrier; semantics are
   flavour-owned; unsupported = ignored. §5 cross-references it as "a self-migration with state
   surgery performed by the flavour at restore".

**Verify:** `./gradlew :kzen-lib-jvm:test`. New `RunEngineTest` cases: (1) `migrate(m, paused,
target)` → rebuilt root's `execution.moveTarget == target`; a second plain `migrate` → null;
(2) a root Logic that ignores `moveTarget` rebuilds and parks exactly as an ordinary paused
migrate (no-op contract); (3) `moveTarget` readable from a hosted child's `Execution` too
(documented — the child ignores unresolvable ids). `publishToMavenLocal` when green.

---

## Phase 2 — Script jump semantics + controller + wire

**Goal:** the whole server-side jump: shared analysis in common, outcome surgery + skip/descend
in `ScriptRunContext`, capability + rejection in the controller, REST endpoint, client transport
method. After this phase a jump is drivable via REST/devtools; the UI affordance is phase 3.

**Prerequisite:** phase 1 (published); engine-plan phase 2 (positions — `runSteps` already calls
`checkpoint(stableId)` by then). Coordinate with script-plan phase 6 if it landed (the same
`checkpoint` call site gains `nestingDepth` there — mechanical merge).

### 2a. Shared analysis (kzen-auto-common)

New `ScriptJumpAnalysis` next to `ScriptTree`
(`kzen-auto-common/.../objects/document/script/model/`): input = `GraphNotation` (for the `rerun`
metadata) + root `ScriptTree` + target `ObjectPath`; output =
`ScriptJumpPlan(valid, invalidReason, ancestors, precedingOnPath, dropSet)` per "The jump
algorithm" above. Branch discovery: reuse the same seam as
`ScriptDependencyAnalysis.branchAttributeNames` (`ScriptDependencyAnalysis.kt:35-38` — hardcoded
today; script-plan 8c replaces it with `is: List, of: ScriptStep` metadata discovery, and this
helper must sit behind the same function so 8c fixes both at once — note this coordination in
both plans). `rerun` flag: read from the coalesced attribute metadata notation.

Add `rerun: true` under `meta.steps` of `ForEachStep`
(`kzen-auto-jvm/src/main/resources/notation/auto-jvm/script/script-jvm.yaml:329-332`) and
`DoWhileStep` (:371-374). IfStep's `then`/`else` (:305-312) stay unflagged (jump-valid). Document
the flag in `ScriptStep` kdoc next to `nestedStepLists()` (third-party loop steps must declare it
to be excluded from jump targeting).

### 2b. ScriptRunContext: restore surgery + skip/descend spine (kzen-auto-jvm)

`ScriptRunContext.kt`:

- New per-run sets `skippedSteps: HashSet<ObjectStableId>`, `descendSteps: HashSet<ObjectStableId>`
  next to `restoredOutcomes` (:81).
- `restore(state, moveTarget: ObjectStableId?)` (extend :260-263; `ScriptLogic.run` passes
  `execution.moveTarget`, ScriptLogic.kt:49): if `moveTarget` is null or doesn't resolve to a
  valid `ScriptJumpPlan` against `structure.scriptTree` → today's behaviour (full restore; the
  ignore contract). Else: seed `restoredOutcomes` = capture minus dropSet-closure (reuse the
  `nestedStableIds` recursion :281-290, mapped through `objectStableMapper` :68), `descendSteps`
  = ancestors, `skippedSteps` = precedingOnPath minus restored keys; keep
  `resultValue = state.result` (decision 11). Then **reset stale displays**: for every dropped id
  emit `StepTrace.State.Idle`, for every skipped id emit the new `Skipped` state (via
  `emitStepTrace` :315-324) — otherwise the dropped steps' old `Done` traces linger on the same
  root-node buffer until re-run.
- `runSteps` (:170-215): before the `restoredOutcomes` check (:177), short-circuit
  `stableId in skippedSteps` → emit `Skipped` trace, **no** `stepValues`/`completedOutcomes`
  entry, no checkpoint, `continue` (the sequence's `last` value is left untouched — a skipped
  step contributes nothing). For descend steps:
  `val suppressBoundary = descendSteps.remove(stableId)`; skip the
  `execution.checkpoint(stableId)` call (:184) when set; the rest of the step lifecycle
  (recoverable, markRunning/markDone, trace) is unchanged — so a descend If whose condition
  itself fails still error-parks normally.
- `StepTrace.State` (`kzen-auto-common/.../script/model/StepTrace.kt:37-46`): add `Skipped`
  (kdoc: short-circuited by a move-to without producing a value; re-runs like Idle if execution
  comes back around).
- `ScriptLogic` implements `Repositionable` (ScriptLogic.kt:20-25): `canMoveTo` =
  `ScriptJumpAnalysis` validity against `structure` (target resolves in the root document's tree,
  no `rerun` ancestor).
- Kdoc updates: `ScriptMigrationState.kt:19-23` (the coalescing note; the loop-restart sentence
  gains "and a move-to target of the loop step restarts it identically"); `ScriptRunContext`
  class kdoc §5 paragraph (:40-43) gains the jump summary.

### 2c. Controller + REST + client transport

- `ServerLogicController.moveTo(runId, target: ObjectLocation, snapshotGraphDefinitionAttempt): LogicRunResponse`
  — modelled on `drive` (:486-523): guards `NotFound`/`RunIdMismatch`,
  `check(!running && !stepping)`, `check(!cancelRequested)`, plus `check(state.launched)` (an
  unlaunched run has no state to reposition — the client can't offer it anyway). **No-op guard**:
  if the root node is `Suspended` and its phase-2 `position == targetId` → return `Submitted`
  without rebuilding (a rebuild is not free and is lossy per the coalescing note). Then:
  recompile unconditionally from the current notation (`graphDefinitionAttempt` :708-718 +
  `compileLogic` :721-733 — shares the barrier with concurrent edits, decision 10; update
  `state.baselineNotations` like `pendingMigration` does :758-759); capability check
  `logic is Repositionable && logic.canMoveTo(targetId)` else return the new response value; on
  accept: `executor.execute { awaitQuiescent; engine.migrate(logic, paused = true, moveTarget = targetId); awaitQuiescent; settleAfterDrive }`
  with `state.stepping = true` for the in-flight display. Compile failure → rejected (unlike
  `pendingMigration`'s keep-running fallback — a jump is refusable, the run keeps its old state).
- `LogicRunResponse` (`kzen-lib-common/.../logic/run/model/LogicRunResponse.kt:4-9`): add
  `Rejected` (wire enum — ships both sides this phase; the JS client parses `valueOf`).
- Wire: `CommonRestApi.logicMoveTo = "${logicPrefix}moveTo"` (CommonRestApi.kt:99-110); route in
  `KzenAutoMain.routeLogic` (KzenAutoMain.kt:216-276); `RestHandler.logicMoveTo(parameters)`
  modelled on `logicContinueStep` (RestHandler.kt:1225-1235) parsing `paramRunId` +
  `paramDocumentPath`/`paramObjectPath` → `ObjectLocation`.
- JS transport (same phase, per the wire ground rule): `ClientRestApi.logicMoveTo(runId, target)`
  next to `logicStep` (ClientRestApi.kt:749-758); `ClientLogicGlobal.moveToAsync(target)`
  modelled on `stepAsync` (ClientLogicGlobal.kt:257-291) — set the in-flight flag, call,
  re-`lookupStatus` (:81). No UI yet.
- Docs: `kzen-auto/docs/architecture.md` §1 (Script semantics: move-to, skipped steps) and §3
  (the new `/logic/moveTo` wire action); logic-spec already updated in phase 1 — extend §5 with
  the Script-side surgery sentence if phase 1's wording deferred it.

**Verify:** kzen-lib + kzen-auto baselines (`RunEngineTest`; Job suite). New controller-level
`ScriptMoveToTest` (kzen-auto-jvm): (1) **backward**: run A,B,C paused at D → moveTo B → parks
at B (position check), resume → B,C,D re-run (side-effect counter), values correct;
(2) **forward**: paused at B → moveTo D → parks at D, B/C traces `Skipped`, resume with
pause-on-error on → a D that references C error-parks with "No value produced" (backstop); a D
that doesn't → completes; (3) **If-branch target** on the taken branch → parks exactly there; on
the untaken branch → parks at the first live step after the If (decision 7); (4) **loop step
target** mid-loop → restarts at iteration 0; loop-body target → `Rejected`; (5) moveTo ==
frontier → `Submitted`, no rebuild (engine sequence unchanged); (6) **edit + jump**: apply a
notation command then moveTo → both take (edited literal visible after resume); (7) moveTo while
running → rejected; after terminal → `NotFound`; while error-parked → works (jump past the
failing step).

---

## Phase 3 — Client affordance + skipped-step display (kzen-auto-js only)

**Goal:** "Set next step here" on every step card, enabled while paused; skipped steps render
distinctly; advisory warning for value-skipping jumps.

**Prerequisite:** phase 2. Coordinate with engine-plan phase 3's UI (landed 2026-07-13 as a
breakpoint dot in the StepHeader right cluster, immediately left of Delete — rendered by
`StepHeader.renderBreakpointDot`; placement user-confirmed after two rejected gutter attempts;
no "run to here" action — runTo was dropped, breakpoints subsume it): "Set next step here"
should join the same right cluster (`StepHeader.renderRightCluster`,
`kzen-auto-js/.../script/step/header/StepHeader.kt`; `props.objectLocation`), keeping the
breakpoint dot's hover-reveal idiom.

### Steps

- **Affordance**: a hover/context action "Set next step here" per step, rendered only when
  `ClientLogicState` shows a settled paused run whose root document is this document. Enabled
  iff `ScriptJumpAnalysis` (the common helper from 2a — runs client-side against the client's
  notation) says valid; disabled with a tooltip reason for loop-body targets. On click →
  `ClientLogicGlobal.moveToAsync`; a `Rejected` response surfaces as a snackbar/tooltip, not an
  exception.
- **Advisory warning** (decision 2): when the jump would leave path steps value-less (forward
  skip: steps between the current position — phase-2 `position` off `LogicStatus` — and the
  target), and `ScriptDependencyAnalysis.edges` (ScriptDependencyAnalysis.kt:22-24) contains an
  edge from a to-be-skipped step to a step at/after the target, style the menu item
  warning-orange with a tooltip naming the affected steps. Also warn when the target's enclosing
  If branch is not the branch the trace shows as taken (decision 7). Advisory only — never
  disable for these.
- **Skipped display**: `ScriptStepDisplayDefault.statusBorderColor`
  (`ScriptStepDisplayDefault.kt:108-140`, applied :316-336) gains a `Skipped` arm (grey border +
  a small "skipped" chip, implementer's choice); `StepTrace.State.Skipped` already parses via
  `valueOf`. The next-step highlight needs no change (phase-2 position-driven).
- Docs: `kzen-auto/docs/js-architecture.md` if the affordance introduces a new shared menu
  component.

**Verify:** `:kzen-auto-js:build`; manual `frontendDevelopment -PjsWatch` smoke: pause
mid-script → jump backward (steps re-run, borders repaint), jump forward (skipped steps grey,
warning shows when a later step references one, error-park lands on the referencing step on
resume), jump onto a ForEach (restarts), loop-body targets disabled, jump while running not
offered, jump inside an If branch parks correctly, rename-while-paused then jump (stable-id
keying must survive). selfTest (kill any stale tester JVM on port 18081 first).

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 1 — engine carry | kzen-lib | small session | low (additive: one field + one property + interface) | engine-plan 2 |
| 2 — Script jump + controller + wire | auto-common + auto-jvm (+ client transport) | one full session | medium (restore-surgery subtleties; branch/coalescing edges) | 1; engine-plan 2 (hard); coordinate script-plan 6 |
| 3 — client affordance | auto-js | small session | low | 2; engine-plan 3 (soft — shared affordance home) |

```
engine-plan 2 (positions) ── hard ─┐
engine-plan 3 (run-to)  ── soft ───┤
                                   ├─ Phase 1 (kzen-lib carry) ─ Phase 2 (Script + wire) ─ Phase 3 (UI)
script-plan 5 (loop cursors) ──────┘  (v2 only: loop-body targets — not a v1 dependency)
```

If phase 2 runs long, land 2a+2b with `ScriptMoveToTest` green and defer 2c's wire to a
follow-up session — never leave the REST endpoint shipped without the client transport method.
