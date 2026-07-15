# Execution control — move-to-step + structured control flow (continue/break/return) for Script — phased plan

> **Status: planned.** Written 2026-07-10 from a design session on repositioning a live Script
> run — "move execution to this step" without executing the intervening steps (backward = re-run
> from the target; forward = skip). **Revised 2026-07-14** (new user requirements): the plan now
> also covers **structured control flow** — a ControlStep with continue/break semantics (Skip
> Iteration / Finish Loop against a selected enclosing loop) and a ResultStep Keep Running /
> End Script option (return semantics) — as phases 4–5, executed **first** (order
> 4 → 5 → 1 → 2 → 3; rationale in "Flavour control flow" below: the shared nesting analysis and
> spine early-exit land with their simplest consumer, and phase 2's delicate restore surgery
> merges on top last). Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is
> self-contained: goal, design decisions (already made — do not re-litigate), concrete steps
> with file anchors, and verification.
>
> The full execution-control surface the asks cover:
> - **explicit instruction pointer** → engine-plan phase 2 (`checkpoint(at:)`, `Node.position`) —
>   planned there, prerequisite here;
> - **run up to a step (breakpoint / run-to)** → engine-plan phase 3 — planned there, sibling
>   affordance here;
> - **move execution to a step** → phases 1–3 (net-new);
> - **continue / break (ControlStep) + return (ResultStep End Script)** → phases 4–5 (net-new
>   2026-07-14; pure flavour semantics — zero engine change, see the flexibility verification in
>   "Flavour control flow").
>
> Companion plans: `2026-07-05_logic-engine-improvements.md` (engine phases 2-3 are prerequisites
> — see below) and `2026-07-06_script-improvements.md` (loop cursors, phase 5, are the v2
> extension path). This plan does not duplicate their items.
>
> **Progress tracker** (update as phases land; execution order **4 → 5 → 1 → 2 → 3** — control
> flow first, user decision 2026-07-14):
> - [ ] Phase 1 — engine carry: one-shot move target through the migration barrier (kzen-lib only)
> - [ ] Phase 2 — Script jump semantics + controller + wire (auto-common + auto-jvm + client transport)
> - [ ] Phase 3 — client affordance: draggable next-to-run arrow + "Set next step here" fallback + skipped-step display (auto-js)
> - [x] Phase 4 ✓ 2026-07-14 — control flow, server: completion signals + ControlStep + ResultStep End Script (auto-common + auto-jvm)
> - [x] Phase 5 ✓ 2026-07-14 — control flow, client: ControlStep / ResultStep editors + step displays (auto-js)

## Context

The Script flavour's resume position is **implicit**: `ScriptRunContext.runSteps`
(`kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/script/ScriptRunContext.kt:203-250`;
anchors in this doc re-verified 2026-07-14, post-S5)
walks the step list, short-circuiting any step whose stable id is in `restoredOutcomes` (:70,
seeded by `restore` :304-308 from the predecessor's capture) via `adoptCompleted` (:338-344), and
parking at the first step that isn't (its `checkpoint()` at :216). So the "current position" of a
rebuilt run is fully determined by the carried outcome set — which means **repositioning a run is
outcome-set surgery plus the existing migrate-style rebuild** (`RunEngine.migrate`, kzen-lib
`kzen-lib-jvm/src/main/kotlin/tech/kzen/lib/server/exec/engine/RunEngine.kt:418-489`): quiesce →
capture `ScriptMigrationState` (`ScriptMigrationState.kt:34-38`) → transform → rebuild → the
spine re-walk parks where the transformed state says. No coroutine surgery, no new parking
machinery, no new engine control loop.

The one genuinely new mechanism is making the rebuilt spine pass **through** things it must not
park at or produce values for:

- a **skipped step** (forward jump over it): short-circuits with *no value* — distinct from
  `adoptCompleted`, which copies a value into `stepValues` (:62). A later reference hits the
  existing hard check `referencedValue` (:114-118) *inside* the step's `recoverable {}` (:231) →
  pause-on-error parks on the referencing step. That existing backstop is the decided runtime
  policy for skipped-value references.
- a **descend step** (an ancestor `IfStep` of a branch target): must *run* (re-evaluate its
  condition, `IfStep.kt:27-32` — deterministic by design) but must *not* park at its own
  boundary, or a paused rebuild would stop at the If instead of the target. Script owns its own
  `checkpoint` call (`ScriptRunContext.kt:216`), so it can simply suppress it for descend steps —
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
   `dropReplay`, `ForEachStep.kt:100`). v2 extension path: script-plan phase 5's `LoopCursor`
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
   :318-321, DoWhileStep `steps` meta :359-362). A branch under a `rerun` attribute is
   jump-invalid in v1. Read by the shared common analysis, so client and server cannot drift, and
   a third-party loop step opts in declaratively (document next to `ScriptStep.nestedStepLists()`).
   **Lands in phase 4a** (control flow ships first and needs the same flag for enclosing-loop
   enumeration); phase 2a consumes it.
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

Control-flow decisions (added 2026-07-14; normative mechanics in "Flavour control flow" below):

12. **Continue/break/return are completion signals, not exceptions.** A sealed
    `ScriptControlSignal` (`SkipIteration(target)` / `FinishLoop(target)` / `EndScript`, targets
    as `ObjectStableId` — rename-safe) is raised through `StepExecution` and held as a pending
    field on `ScriptRunContext` (like `resultValue`); the spine short-circuits, the targeted
    consumer clears it. Exceptions were considered and rejected: `Execution.recoverable`'s
    catch-all (`RunEngine.kt:676-699`) would render an unwinding control transfer as a step
    failure (error-park under pause-on-error) — the signal design keeps the engine contract
    untouched (**zero kzen-lib change**; do not add a marker-exception pass-through, it is not
    needed).
13. **ControlStep shape**: one step type (`objects/script/step/control/ControlStep.kt`), two
    attributes — `loop:` (an `ObjectLocation` reference to the target enclosing loop, like
    ForEachStep's `items:`; the client editor lists all enclosing loops, pre-filling the
    innermost on insert) and `action: skipIteration | finishLoop`. Produces no value
    (`TupleDefinition.empty`). Validation error unless `loop` resolves to an ancestor whose
    hosting attribute is `rerun`-flagged (decision 8) — so run-blocking on definition errors
    covers mistargeted steps, and the runtime backstop (a signal reaching the root unconsumed
    fails the run with a clear message) should be unreachable.
14. **Skip semantics** (`continue`): ForEach — the skipped iteration contributes **nothing** to
    the collected output list, then the loop proceeds to its next iteration through the normal
    `dropReplay` path. DoWhile — Skip proceeds to **condition evaluation** (standard `continue`);
    a condition referencing a value the skip left unproduced hits the existing `referencedValue`
    backstop (same policy as decision 2).
15. **Finish semantics** (`break`): the loop exits immediately — ForEach returns the outputs
    collected so far, DoWhile returns null — and **clears its cursor carry**
    (`recordCarry(self, null)`) on the exit path, same as normal completion, so no stale cursor
    migrates. A signal targeting an *outer* loop propagates: the inner loop returns, each
    enclosing spine short-circuits, until the targeted loop consumes it.
16. **ResultStep gains `then: keepRunning | endScript`** (default `keepRunning` = today's
    behaviour, back-compatible — last Result wins and the walk continues). `endScript` raises
    `EndScript` after `setResult`, ending the **current Script document** — in a hosted
    sub-script the sub-script returns and the caller's RunStep continues (proper `return`
    semantics; a signal never crosses a `host()` boundary). Decision 11 is unaffected.
17. **Trace display for signal-exited containers**: the raising step (ControlStep / ResultStep)
    gets its normal Done trace; a container the signal passes through (an If mid-branch) gets a
    Done *trace* whose display names the signal ("→ finish Loop X") but **no**
    `completedOutcomes` entry — replay semantics are driven by outcomes, not traces, and the
    next iteration's `dropReplay` (or the loop exit) makes the distinction moot. Implementer may
    refine the display text; the no-outcome rule is normative.

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
  the same recursion as `nestedStableIds`, ScriptRunContext.kt:326-335).
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

## Flavour control flow (continue/break/return) — completion signals (normative for phase 4)

**Engine-flexibility verification (2026-07-14, conclusion: zero kzen-lib change).**
Continue/break/return are control transfers within one Script document's coroutine **between
checkpoints**. The engine only ever sees checkpoints, recoverable units completing, and
`Logic.run` returning — so the whole feature is flavour-level, provided the transfer is **not**
an exception: `Execution.recoverable`'s catch-all (`RunEngine.kt:676-699`) would catch an
unwinding control throwable, render it as a step failure, and error-park it under pause-on-error.
Hence the interpreter-style **completion signal** (decision 12). Signals are raised and consumed
within one engine release: they never survive across a `checkpoint` (no migration carry, no
interaction with the jump algorithm's restore surgery) and never cross a `host()` boundary
(End Script in a sub-script ends only the sub-script). `logic-spec.md` therefore needs **no
amendment** for phases 4–5; only `kzen-auto/docs/architecture.md` §1 gains the Script semantics.

Mechanics (all in kzen-auto; anchors verified 2026-07-14):

- **Pending signal**: `ScriptRunContext` (`ScriptRunContext.kt`) holds `pendingSignal:
  ScriptControlSignal?` plus the raising step's stable id, next to `resultValue` (:85). New
  `StepExecution` API (`objects/script/api/StepExecution.kt`): `raiseControlSignal(signal)`
  (ControlStep / ResultStep; records `raisedBy = currentStableId`) and
  `consumeLoopSignal(selfLocation): ScriptControlSignal?` (loop steps: returns-and-clears a
  Skip/Finish targeting self, else null — part of the loop-step contract, documented next to
  `ScriptStep.nestedStepLists()` alongside the `rerun` flag). `EndScript` is consumed by
  `ScriptLogic` via a run-internal method (like `result()`, :298-300).
- **Spine short-circuit** (`runSteps` :203-250): after the recoverable unit returns, if a signal
  is pending — the raising step (`raisedBy == stableId`) gets its normal `markDone`; a container
  it passes through gets a Done trace naming the signal but no `completedOutcomes` entry
  (decision 17) — then the walk returns immediately (no further steps, no checkpoint). Container
  steps need no code: `IfStep.run` (:27-32) already returns its branch's `runSteps` result
  directly, and the enclosing spine sees the still-pending signal.
- **Loop consumption**: `ForEachStep.run` (:94-122) checks `consumeLoopSignal(selfLocation)`
  after its body `runSteps` — Skip → don't collect this iteration's output, continue (normal
  `dropReplay` next-iteration path, cursor re-recorded); Finish → exit the while, fall through
  to the existing `recordCarry(selfLocation, null)` + return collected outputs. `DoWhileStep.run`
  (:57-74) — Skip → proceed to `evaluateCondition`; Finish → exit, clear carry, return null.
  A non-matching signal → return immediately (propagate; the enclosing spine short-circuits).
- **Root consumption**: `ScriptLogic.run` (`ScriptLogic.kt:46-49`) — after the root `runSteps`,
  consume `EndScript` (if pending) and return `result() ?: TupleValue.empty`; an unconsumed
  Skip/Finish at the root fails the run with a message naming the mistargeted step (backstop —
  validation should make this unreachable, decision 13).
- **Enclosing-structure discovery**: new `ScriptNestingAnalysis` in kzen-auto-common next to
  `ScriptTree` (`objects/document/script/model/`) — path root→step (ancestors with their hosting
  attribute names), `rerun`-flag detection, enclosing-loop enumeration (innermost-first). Sits
  behind the same branch-discovery seam as `ScriptDependencyAnalysis.branchAttributeNames`
  (hardcoded today; script-plan 8c replaces it with `is: List, of: ScriptStep` metadata
  discovery — this helper must share that one function so 8c fixes all consumers at once).
  `ScriptJumpAnalysis` (phase 2a) is a **consumer** of this analysis, layered on top.

Stepping/UX falls out for free: stepping over a ControlStep parks at the next boundary control
actually reaches (next iteration's first step, the step after the loop, or — for End Script —
wherever the caller resumes); pause-on-error, breakpoints, and live edit are untouched because
the signal never lives across a park.

---

## Phase 1 — Engine carry: one-shot move target through the migration barrier (kzen-lib only)

**Goal:** the engine can carry an opaque repositioning target across a `migrate`, and a driver
can detect whether a Logic supports repositioning. No behaviour change for any existing flavour.

**Prerequisite:** engine-plan phase 2 landed (so `Execution`'s signature churn happens once and
the kdoc can reference positions).

### Steps

1. `RunEngine.migrate(newRoot: Logic, paused: Boolean = true, moveTarget: ObjectStableId? = null)`
   (RunEngine.kt:418): store in a new field `migrationMoveTarget` in migrate step 3 (:468-487),
   alongside the other migration registers (`migrationCaptured` / `migrationResources`,
   :147-155). Every migrate **overwrites** it (an ordinary
   edit-migrate passes null → cleared), so it is one-shot per barrier by construction; clear it
   in `sweepOrphans` (:497-519) too so `close()` leaves nothing behind.
2. `Execution.moveTarget: ObjectStableId?` — new read-only property in the §5 block of
   `Execution.kt` (next to `restored`, :180) wired through `ExecutionImpl`
   (RunEngine.kt:1037-1092). Not cleared on read — the root and hosted children may all read it
   during one barrier's rebuild (unlike `restored`, a read is not a claim). Kdoc contract: *advisory one-shot repositioning hint set by the driver
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
`checkpoint(stableId)`, landed 2026-07-12); phase 4 (the spine's signal short-circuit and
`ScriptNestingAnalysis` land there first — this phase's skip/descend logic merges over them).
(Script-plan phase 6's `nestingDepth` at the same call site landed 2026-07-12 but was REVERTED
2026-07-13 — stepping is frame-only again, so the call site is the simpler E2 shape.)

### 2a. Shared analysis (kzen-auto-common)

New `ScriptJumpAnalysis` next to `ScriptTree`
(`kzen-auto-common/.../objects/document/script/model/`): input = `GraphNotation` (for the `rerun`
metadata) + root `ScriptTree` + target `ObjectPath`; output =
`ScriptJumpPlan(valid, invalidReason, ancestors, precedingOnPath, dropSet)` per "The jump
algorithm" above. It is a **consumer of `ScriptNestingAnalysis`** (built in phase 4a — path
root→target with hosting attribute names, `rerun` detection, branch discovery behind the shared
`ScriptDependencyAnalysis.branchAttributeNames` seam): this phase adds only the jump-specific
set computations on top. The `rerun: true` metadata on ForEachStep/DoWhileStep `steps`
(`script-jvm.yaml:318-321` / :359-362) also landed in 4a; IfStep's `then`/`else` stay unflagged
(jump-valid).

### 2b. ScriptRunContext: restore surgery + skip/descend spine (kzen-auto-jvm)

`ScriptRunContext.kt`:

- New per-run sets `skippedSteps: HashSet<ObjectStableId>`, `descendSteps: HashSet<ObjectStableId>`
  next to `restoredOutcomes` (:70).
- `restore(state, moveTarget: ObjectStableId?)` (extend :304-308; `ScriptLogic.run` passes
  `execution.moveTarget`, ScriptLogic.kt:37): if `moveTarget` is null or doesn't resolve to a
  valid `ScriptJumpPlan` against `structure.scriptTree` → today's behaviour (full restore; the
  ignore contract). Else: seed `restoredOutcomes` = capture minus dropSet-closure (reuse the
  `nestedStableIds` recursion :326-335, mapped through `objectStableMapper` :57), `descendSteps`
  = ancestors, `skippedSteps` = precedingOnPath minus restored keys; keep
  `resultValue = state.result` (decision 11). Then **reset stale displays**: for every dropped id
  emit `StepTrace.State.Idle`, for every skipped id emit the new `Skipped` state (via
  `emitStepTrace` :354-366) — otherwise the dropped steps' old `Done` traces linger on the same
  root-node buffer until re-run.
- `runSteps` (:203-250; by this phase it also carries phase 4's pending-signal short-circuit —
  the two early-exits are orthogonal: skip/descend act *before* a step runs (replay concerns),
  the signal check acts *after* (runtime control transfer); merge, don't entangle): before the
  `restoredOutcomes` check (:210), short-circuit
  `stableId in skippedSteps` → emit `Skipped` trace, **no** `stepValues`/`completedOutcomes`
  entry, no checkpoint, `continue` (the sequence's `last` value is left untouched — a skipped
  step contributes nothing). For descend steps:
  `val suppressBoundary = descendSteps.remove(stableId)`; skip the
  `execution.checkpoint(stableId)` call (:216) when set; the rest of the step lifecycle
  (recoverable, markRunning/markDone, trace) is unchanged — so a descend If whose condition
  itself fails still error-parks normally.
- `StepTrace.State` (`kzen-auto-common/.../script/model/StepTrace.kt:37-46`): add `Skipped`
  (kdoc: short-circuited by a move-to without producing a value; re-runs like Idle if execution
  comes back around).
- `ScriptLogic` implements `Repositionable` (ScriptLogic.kt:20-25): `canMoveTo` =
  `ScriptJumpAnalysis` validity against `structure` (target resolves in the root document's tree,
  no `rerun` ancestor).
- Kdoc updates: `ScriptMigrationState.kt:15-32` (the coalescing note; the stepCarry/loop-resume
  paragraph gains "and a move-to target of the loop step restarts it identically");
  `ScriptRunContext` class kdoc §5 paragraph (:40-45) gains the jump summary.

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

**Goal:** a **draggable VB-style next-to-run arrow** as the primary move-to affordance
(user-ratified 2026-07-14), plus "Set next step here" as a per-step fallback action, both
enabled while paused; skipped steps render distinctly; advisory warning for value-skipping
jumps.

**Prerequisite:** phase 2. Coordinate with engine-plan phase 3's UI (landed 2026-07-13 as a
breakpoint dot in the StepHeader right cluster, immediately left of Delete — rendered by
`StepHeader.renderBreakpointDot`; placement user-confirmed after two rejected gutter attempts;
no "run to here" action — runTo was dropped, breakpoints subsume it): the fallback "Set next
step here" should join the same right cluster (`StepHeader.renderRightCluster`,
`kzen-auto-js/.../script/step/header/StepHeader.kt`; `props.objectLocation`), keeping the
breakpoint dot's hover-reveal idiom.

### Steps

- **Arrow affordance** (primary): a narrow margin strip on the Script step list holding a single
  positional arrow marker at the next-to-run step — position driven by phase-2's engine
  `Node.position` off `LogicStatus` (the same signal as today's next-to-run border highlight,
  `ScriptStepDisplayDefault.statusBorderColor`). While a settled paused run of this document
  exists, the arrow is draggable (pointer events); drop targets are step cards, validated live
  by `ScriptJumpAnalysis` (loop-body targets render as no-drop with a tooltip reason); drop →
  `ClientLogicGlobal.moveToAsync`. NB the E3 history: two *per-step gutter* placements were
  rejected in favour of an inline dot — the arrow differs (one stateful positional marker, the
  classic debugger idiom, explicitly requested), but keep the strip minimal and confirm the
  look with the user early.
- **Fallback action**: "Set next step here" per step in the StepHeader right cluster, rendered
  only when `ClientLogicState` shows a settled paused run whose root document is this document
  (covers long scripts where dragging across scrolled content is awkward, and accessibility).
  Enabled iff `ScriptJumpAnalysis` (the common helper from 2a — runs client-side against the
  client's notation) says valid; disabled with a tooltip reason for loop-body targets. On click →
  `ClientLogicGlobal.moveToAsync`; a `Rejected` response surfaces as a snackbar/tooltip, not an
  exception.
- **Advisory warning** (decision 2): when the jump would leave path steps value-less (forward
  skip: steps between the current position — phase-2 `position` off `LogicStatus` — and the
  target), and `ScriptDependencyAnalysis.edges` (ScriptDependencyAnalysis.kt:22-24) contains an
  edge from a to-be-skipped step to a step at/after the target, style the affordance
  (drop-target highlight and menu item alike) warning-orange with a tooltip naming the affected
  steps. Also warn when the target's enclosing
  If branch is not the branch the trace shows as taken (decision 7). Advisory only — never
  disable for these.
- **Skipped display**: `ScriptStepDisplayDefault.statusBorderColor`
  (`ScriptStepDisplayDefault.kt:108-140`, applied :316-336) gains a `Skipped` arm (grey border +
  a small "skipped" chip, implementer's choice); `StepTrace.State.Skipped` already parses via
  `valueOf`. The next-step highlight needs no change (phase-2 position-driven).
- Docs: `kzen-auto/docs/js-architecture.md` if the affordance introduces a new shared menu
  component.

**Verify:** `:kzen-auto-js:build`; manual `frontendDevelopment -PjsWatch` smoke: pause
mid-script → jump backward by dragging the arrow (steps re-run, borders repaint), jump forward
via the fallback action (skipped steps grey,
warning shows when a later step references one, error-park lands on the referencing step on
resume), jump onto a ForEach (restarts), loop-body targets no-drop/disabled, jump while running
not offered (arrow static), jump inside an If branch parks correctly, rename-while-paused then
jump (stable-id keying must survive). selfTest (kill any stale tester JVM on port 18081 first).

---

## Phase 4 — Control flow, server: completion signals + ControlStep + ResultStep End Script

**Goal:** continue/break/return as Script semantics, end-to-end on the server: the completion-
signal mechanism in the spine, the new ControlStep (Skip Iteration / Finish Loop against a
selected enclosing loop), the ResultStep `then: endScript` option, loop-step consumption, and
the shared `ScriptNestingAnalysis` + `rerun` metadata that phase 2 later consumes. **Runs
first** (before phases 1–3). No wire/controller/engine change — this is notation + runtime
semantics only (see "Flavour control flow" for the normative mechanics and the engine-
flexibility verification; do not re-litigate exceptions-vs-signals).

**Prerequisite:** none (E2 positions already landed; independent of phase 1's engine carry).

### 4a. Shared analysis + metadata (kzen-auto-common + notation)

- `rerun: true` under `meta.steps` of `ForEachStep`
  (`kzen-auto-jvm/src/main/resources/notation/auto-jvm/script/script-jvm.yaml:318-321`) and
  `DoWhileStep` (:359-362); document the flag in `ScriptStep` kdoc next to `nestedStepLists()`
  (a third-party loop step declares it to join loop semantics: ControlStep targeting here,
  jump-target exclusion in phase 2).
- New `ScriptNestingAnalysis` next to `ScriptTree`
  (`kzen-auto-common/.../objects/document/script/model/`): path root→step (each ancestor with
  its hosting attribute name), `rerun`-flag detection from coalesced attribute metadata,
  enclosing-loop enumeration (innermost-first). Branch discovery sits behind the same seam as
  `ScriptDependencyAnalysis.branchAttributeNames` (`ScriptDependencyAnalysis.kt` — hardcoded
  today; script-plan 8c replaces it with `is: List, of: ScriptStep` metadata discovery, and this
  helper must share that one function so 8c fixes all consumers at once). Used server-side for
  ControlStep validation here, client-side for the loop dropdown in phase 5, and by
  `ScriptJumpAnalysis` in phase 2.

### 4b. Signals + spine + steps (kzen-auto-jvm)

Per the "Flavour control flow" section (normative): sealed `ScriptControlSignal`;
`pendingSignal`/`raisedBy` on `ScriptRunContext` (next to `resultValue` :85);
`StepExecution.raiseControlSignal` / `consumeLoopSignal`; the `runSteps` short-circuit
(raising step markDone'd, containers get a no-outcome Done trace, decision 17); ForEach/DoWhile
consumption (Skip = no collected output / condition still evaluates; Finish = exit + clear
cursor carry, decisions 14–15); `ScriptLogic` EndScript consumption + unconsumed-signal
backstop.

- **ControlStep**: new `@Reflect` step
  `kzen-auto-jvm/.../objects/script/step/control/ControlStep.kt` + archetype in
  `script-jvm.yaml` (attributes `loop:` `is: ObjectLocation, by: Nominal` like ForEachStep's
  `items:` :314-317, and `action:` with values `skipIteration | finishLoop`; icon/title
  implementer's choice, e.g. `material-symbols:step-out` / "Loop control").
  `definition()` = `TupleDefinition.empty`, or a validation error when `loop` doesn't resolve
  to a `rerun`-flagged ancestor (via `ScriptNestingAnalysis`; decision 13). `run()` =
  `raiseControlSignal` with the loop's stable id (mapped like other locations), returning a
  short display value.
- **ResultStep** (`kzen-auto-jvm/.../objects/script/step/eval/ResultStep.kt:43-59` + archetype
  `script-jvm.yaml:139-152`): new `then:` attribute (`keepRunning` default | `endScript`,
  decision 16); on `endScript`, raise `EndScript` after `setResult` (:57).
- Docs: `kzen-auto/docs/architecture.md` §1 gains the Script control-flow semantics
  (ControlStep/ResultStep, signal-not-exception, loop-step contract). `logic-spec.md` is
  deliberately untouched (no engine change — state this in the commit/as-built note).

**Verify:** kzen-auto-jvm baseline suites. New controller-level `ScriptControlFlowTest`
(fixture yaml under `src/test/resources/notation/test/`, steps in `src/main` per the KSP
gotcha): (1) Skip in a ForEach body → iteration's remaining steps don't run, nothing collected
for it, next iteration runs; (2) Finish in a ForEach body → loop exits with outputs-so-far,
following step runs, loop cursor carry cleared; (3) nested loops: ControlStep targeting the
**outer** loop from the inner body → inner loop unwinds, outer consumes; (4) Skip in DoWhile →
condition evaluates; a condition referencing the skipped value error-parks per the backstop;
(5) ControlStep under an If inside the loop → signal passes the If (container no-outcome Done
trace); (6) ResultStep `endScript` at root → run ends with the result, later steps never run;
(7) `endScript` in a RunStep-hosted sub-script → sub-script returns, caller continues; (8)
ControlStep whose `loop` is not an ancestor → validation error (run-blocked); (9) pause inside
an iteration → edit → resume → Skip still works (signal machinery vs. migration replay).

### As built (2026-07-14)

Landed as designed; anchors were re-verified against the code first (several line refs had
drifted). Deltas worth recording:

- **Signal target = `ObjectLocation`, compared in stable-id space.** Decision 12 says
  `ObjectStableId`, but no step holds the mapper (steps work in `ObjectLocation`). Reconciliation:
  `ScriptControlSignal.SkipIteration`/`FinishLoop` carry `ObjectLocation`; `consumeLoopSignal`
  compares `objectStableMapper.objectStableId(target) == …(self)` — rename-safe, and moot anyway
  (a signal never survives a checkpoint). Same guarantee, simpler API.
- **`StepExecution` surface**: `raiseControlSignal(signal)` + `consumeLoopSignal(selfLocation)`
  **plus** `pendingControlSignal()` (peek) — the third method lets a loop distinguish "no signal"
  from "a foreign signal to propagate". `ScriptControlSignal` lives in `…/objects/script/api/`.
- **Spine short-circuit** merged over the E2-shaped `runSteps`: after the `recoverable` unit, a
  passed-through container gets a no-outcome `Done` trace + return; the raiser gets its normal
  `markDone` + return. Review hardening: the `recoverable` **error handler also clears the pending
  signal** (invariant: no signal coexists with a park). Root consumption is
  `ScriptRunContext.consumeRootSignalOrFail()` from `ScriptLogic.run`.
- **`action` / `then` are plain `String` attributes** (validated in `definition()`), not new
  enum+definer types — keeps XC4 minimal; phase 5 picks the select editor.
- **EndScript needs no per-step capture** (review Finding 1 resolved): EndScript unwinds to the
  root and `ScriptLogic.run` returns → the run is *terminal* (no park), and terminal runs are never
  migrated/replayed (decision 9). Documented as an invariant in the `ScriptRunContext` kdoc.
- **`ScriptNestingAnalysis`** (kzen-auto-common) is built on `ScriptTree` (already generic branch
  discovery) and reads `meta.<branch>.rerun` via `GraphNotation.firstAttribute` (the `is:`
  inheritance chain) — fully notation-driven, no hardcoded branch list, and did **not** need to
  touch `ScriptDependencyAnalysis.branchAttributeNames` (that seam's refactor stays script-plan 8c).
- **Deferred**: test case (9) (pause→edit→resume→Skip) — covered by the release-local invariant (a
  signal never coexists with a park, so a migration barrier never sees a pending signal); a
  dedicated migration test would only re-assert that. Cases 1–8 are green in `ScriptControlFlowTest`
  (8) + `ScriptNestingAnalysisTest` (4); full `:kzen-auto-jvm:test` = 396 green.

---

## Phase 5 — Control flow, client: editors + step displays (kzen-auto-js only)

**Goal:** ControlStep and the ResultStep option are creatable and editable in the Script UI.

**Prerequisite:** phase 4.

### Steps

- **ControlStep editor**: loop selection dropdown = the enclosing `rerun`-flagged ancestors from
  `ScriptNestingAnalysis` (client-side, against the client's notation), labelled by step
  name/title, pre-filled to the **innermost** enclosing loop on insert; `action:` select
  (Skip Iteration / Finish Loop). Follow the existing notation-driven editor pattern
  (`editor:` metadata → shared editors under `objects/document/common/`; a bespoke
  `is: AttributeEditor` object only if the ancestor-scoped dropdown can't be expressed with
  `SelectStepEditor`-style filtering). Client archetype/display registration in `script-js.yaml`
  next to the other step entries; ControlStep offered in the insert ribbon's control group.
- **ResultStep editor**: `then:` as a select (Keep Running / End Script), default Keep Running.
- **Step display**: default card display with a summary line ("Skip iteration → Loop X" /
  "Finish loop → Loop X"; "End script" chip on ResultStep when `endScript`). No new
  `WorkerDisplay`-style machinery — the default step display + attribute summaries suffice.
- Validation surfacing needs no new work: ControlStep's definition error (mistargeted `loop`)
  renders through the existing per-step validation display and blocks Run like any definition
  error.

**Verify:** `:kzen-auto-js:build`; `frontendDevelopment -PjsWatch` smoke: insert ControlStep
inside nested loops (dropdown lists both, innermost pre-selected), Skip/Finish live runs behave
per phase 4, ResultStep End Script ends the run from the UI, mistargeted ControlStep shows the
validation error and blocks Run, rename the target loop (reference follows — `by: Nominal`).
selfTest (kill any stale tester JVM on port 18081 first).

### As built (2026-07-14)

Landed as designed. Four new kzen-auto-js components under
`.../objects/document/script/display/` + notation wiring, no display component (both steps inherit
`ScriptStepDisplayDefault`), no server/kzen-lib change. Deltas worth recording:

- **Enum editor is generic, not bespoke** (user decision this session). A single
  `SelectValuesEditor` (`edit/`) reads its options+labels from `meta.<attr>.values` (a
  `MapAttributeNotation`, via the same `graphMetadata → attributeMetadataNotation.get(nesting)` idiom
  `AttributeEditorManager` uses for `editor:`) and delegates the render/write to the
  `SelectClosePolicyEditor` shape. `ControlStep.action` and `ResultStep.then` both point at it and
  declare their `values:` maps in `script-jvm.yaml` — labels live in YAML, and any future/third-party
  enum String attribute reuses it declaratively.
- **Loop dropdown** `SelectEnclosingLoopEditor` (`edit/`) is `SelectStepEditor` with the candidate
  source swapped to `ScriptNestingAnalysis.enclosingLoops(...)` (identical to server validation).
  It needs graphNotation (ClientState) + scriptTree (ScriptStore), cached as plain fields and
  recomputed when both present. **Pre-fill innermost on insert**: when `loop` is empty and ≥1
  candidate, it writes the innermost once (run-once flag, via the existing `componentDidUpdate` write
  path) so a freshly inserted+expanded ControlStep is valid by default. `meta.loop.editor` repointed
  from `SelectStepEditor`.
- **Summary views** (`view/`, user chose polished): `ControlSummaryAttributeView` (tagged `summary:`
  on `meta.action`) resolves the loop step's *name* (not document name) and renders
  "Skip iteration → *LoopName*" / "Finish loop → *LoopName*"; `ResultThenAttributeView` (on
  `meta.then`) renders an "End script" chip only for `endScript` (nothing for `keepRunning`, so the
  default ResultStep card is unchanged).
- **Ribbon**: `ControlTool` added under `ScriptGroup_LogicControl` (delegate `ControlStep`).
- **Verification**: `:kzen-auto-js:compileKotlinJs` + `kspKotlinJs` green (4 new `@Reflect`
  Wrappers registered); `jsEsbuildBundle` green; `:kzen-auto-jvm:test` (ScriptControlFlowTest +
  ScriptNestingAnalysisTest) green, confirming the `script-jvm.yaml` metadata additions still load.
  Interactive browser smoke (dropdowns list the loops, chip renders) not run headlessly — leave for
  a live pass.

---

## Sizing and sequencing

Execution order: **4 → 5 → 1 → 2 → 3** (control flow first, user decision 2026-07-14 — the
nesting analysis, `rerun` metadata, and spine early-exit land with their simplest consumer;
phase 2's restore surgery merges on top last).

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 4 — control flow, server | auto-common + auto-jvm | one full session | medium (spine short-circuit; two loop steps; signal edges) | none |
| 5 — control flow, client | auto-js | small session | low | 4 |
| 1 — engine carry | kzen-lib | small session | low (additive: one field + one property + interface) | engine-plan 2 |
| 2 — Script jump + controller + wire | auto-common + auto-jvm (+ client transport) | one full session | medium (restore-surgery subtleties; branch/coalescing edges) | 1; 4 (nesting analysis + spine merge); engine-plan 2 (hard) |
| 3 — client affordance (arrow + fallback) | auto-js | small-to-medium session (drag interaction) | low-medium | 2; engine-plan 3 (soft — shared affordance home) |

```
Phase 4 (signals + ControlStep + ResultStep) ── Phase 5 (editors)
   │ (lands ScriptNestingAnalysis + rerun metadata + spine early-exit)
   └───────────────────────────────────────────────┐
engine-plan 2 ── hard ──┐                           ▼
engine-plan 3 ── soft ──┼─ Phase 1 (kzen-lib carry) ─ Phase 2 (Script + wire) ─ Phase 3 (arrow UI)
script-plan 5 ──────────┘  (v2 only: loop-body targets — not a v1 dependency)
```

If phase 2 runs long, land 2a+2b with `ScriptMoveToTest` green and defer 2c's wire to a
follow-up session — never leave the REST endpoint shipped without the client transport method.
If phase 4 runs long, land 4a+4b's signal spine + ControlStep with `ScriptControlFlowTest`
green and defer the ResultStep `then:` option to ride with phase 5.
