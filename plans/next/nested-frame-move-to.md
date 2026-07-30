# XC-N — nested-frame move-to (Set Next Statement inside a sub-Script)

> **Standalone scoping document** (design rationale + elaboration in one file, like
> `context-and-resource.md` — the "Constituent plan" column reads `—`, so on landing archive it as an
> as-built record rather than deleting it). **Status: SCOPED, NOT SCHEDULED** — no master-plan ledger
> row yet; the sizing in §8 is the input to that decision.
>
> Anchors captured 2026-07-29 against kzen-lib `67730a9` / kzen-auto `97543315`. Re-verify before
> editing (standing rule in `README.md`).
>
> **Extends XC** (execution control, landed Sprint 1 — `sprint-1/README.md` ledger row for
> `2026-07-10_execution-control.md`). XC shipped move-to for the **run-root document only**. This
> document scopes lifting that to any live frame. It is the *second* parked XC extension; the first
> (loop-body jump targets) is recorded at `../2026-07-25_master-plan.md` § XC — and §5 below shows
> the two are **not independent**.

## 1. Verdict

**The mechanism is largely already there; the feature is gated off.** The surgery that makes move-to
work is already written per-frame and document-scoped, and the engine already broadcasts the move
target to every frame in the rebuilt tree. Three narrow gaps stand between that and a working
nested jump, one of which is a **pre-existing defect in the shipped top-level feature** (§4.3).

Sizing: **2 sessions** for the straight-line-ancestor case, plus a separable **XS pre-session** for
the §4.3 defect. Full generality (a sub-Script hosted from inside a loop body — a common shape)
**requires the parked loop-body extension first** (§5); that is the main reason not to schedule this
as a single unit.

## 2. What already works, unchanged

Worth stating precisely, because it is most of the feature and it constrains the design.

**The engine carry is already frame-agnostic and unclaimed.** `RunEngine.migrationMoveTarget`
(kzen-lib `RunEngine.kt:198-203`) is tree-wide, not keyed by node, and
`Execution.moveTarget` (`Execution.kt:247-255`) documents reading as explicitly *not* a claim:

> Any Logic that does not support repositioning, **or a hosted child in whose structure the id does
> not resolve, MUST ignore it** … the root and hosted children may all read it during one barrier's
> rebuild.

So the ignore-contract for foreign frames is already specified and implemented.

**The flavour-side surgery is already per-frame.** `ScriptRunContext.jumpPlanFor`
(kzen-auto `ScriptRunContext.kt:673-682`) returns null when the target's document is not *this*
frame's document, falling back to a plain restore. Every Script frame — root or hosted — reaches it
through the same `ScriptLogic.run` line (`ScriptLogic.kt:81-83`):

```kotlin
execution.restoredAs<ScriptMigrationState>()?.let {
    context.restore(it, execution.moveTarget, execution.removedStableIds)
}
```

A hosted sub-Script frame would therefore apply the jump to itself, and its ancestors would
correctly fall through to a plain restore, **with no change to either file**.

**The client's advisory analysis is already per-document.** `ScriptJumpAnalysis.plan` /
`isValidTarget` take `documentPath` + that document's `ScriptTree`, and `ScriptExecutionMargin`
already calls them with the *viewed* document (`ScriptExecutionMargin.kt:407-428`). Valid-target
highlighting and the dependency-skip warn need no work.

**Breakpoints in sub-Scripts already work** — the margin's bands are built from the viewed
document's executable steps with no run-state gate, and the registry is stable-id-keyed.

## 3. The two gates that block it today

Both are one-line policy checks, and both are deliberate.

**Client** — `ScriptExecutionMargin.kt:311-313`:

```kotlin
val canDrag = logicState.isActive() && !logicState.isExecuting() &&
        frame?.objectLocation?.documentPath == documentPath
```

`frame` is the run's **root** frame, so the glyph renders inert (0.5 opacity,
`pointerEvents = none`, no `title`) in any nested frame — indistinguishable from the "run is
executing" state, which is why it reads as a bug rather than a limitation.

**Server** — `ServerLogicController.kt:730-732` gates on the recompiled **root** Logic:

```kotlin
if (logic !is Repositionable || !logic.canMoveTo(targetId)) {
    return LogicRunResponse.Rejected
}
```

and `ScriptLogic.canMoveTo` (`ScriptLogic.kt:44-52`) rejects any target outside its own document.

Opening both gates alone is **not** sufficient — §4.1 and §4.2 explain what would go wrong.

## 4. The three mechanism gaps

### 4.1 G1 — frame descent: the rebuild parks at the hosting RunStep, not inside the child

This is the load-bearing gap. `migrate(paused = true)` sets `command = Command.Paused`, and with
that command **every** checkpoint parks (`RunEngine.kt:857-862`, `Command.Paused -> PauseReason.Boundary`).
On the rebuild the parent Script replays its completed steps (no checkpoint), reaches the RunStep
hosting the target's frame — which is mid-flight, so it holds no restored outcome and is not
replay-adopted — calls `execution.checkpoint(runStepStableId)`, and **parks there**. The child is
never hosted, so the jump is never applied.

This is exactly the problem `descendSteps` already solves *within* one frame: an enclosing `If` on
the path to the target re-runs with its checkpoint suppressed so the rebuild parks at the target
rather than the ancestor's boundary (`ScriptRunContext.kt:407-413`, and
`ScriptJumpAnalysis.ScriptJumpPlan.ancestors`). **G1 is the frame-level analogue**: every frame on
the path from the root to the target frame must suppress the boundary of the RunStep it descends
through, plus that RunStep's own in-frame ancestors.

Note this same code path governs an **ordinary nested edit-migrate**: editing while paused inside a
sub-Script should, by the same reading, pop the position out to the parent's RunStep.
`ServerLogicControllerLinkedDocumentMigrationTest` covers only the case where the RunStep
**completed** before the edit (its header says so explicitly: "The rebuilt spine replay-adopts the
completed RunStep instead of re-invoking it") — the mid-flight case is untested. **Confirm with a
test before designing**; if it reproduces, G1's fix is a shared improvement, not nested-only cost.

### 4.2 G2 — frame addressing: an `ObjectStableId` cannot name a frame

`Execution.moveTarget` carries an `ObjectStableId` = `(documentPath, objectPath)`. Every frame whose
document matches applies the surgery. Under recursion that is **more than one frame**, and all of
them jump.

Recursion is not hypothetical: `LogicCallGraph` (`LogicCallGraph.kt:31-32`) states that
"self-hosting and mutual hosting are **legal at runtime**", and its callee traversal deliberately
handles cycles back to the seed document.

This hazard **already exists in the shipped top-level feature** for a self-recursive root (root `A`
with a RunStep calling `A`: the target resolves in both the root frame and the nested `A` frame).
Nested support makes it routine rather than exotic, so it must be resolved rather than inherited.

Related but separate: `RunEngine.migrationCaptured` is keyed by `ObjectStableId` alone
(`RunEngine.kt:168`), with an acknowledged collision between a terminal and a live frame of the same
id resolved by capture ordering (`RunEngine.kt:530-534`). Two *simultaneously live* frames of one
document collide with no defined winner. That is a pre-existing recursion limitation in migration
generally — **out of scope here**, but it bounds how far nested move-to can be claimed to work under
recursion, and should be stated in the docs rather than silently relied on.

### 4.3 G3 — an abandoned child's capture is never discarded (pre-existing defect)

`ScriptRunContext.restore`'s move-to path computes `dropStableIds` and prunes
`restoredOutcomes` / `restoredCarries`, but **never calls `execution.discardCaptured(dropStableIds)`**
(`ScriptRunContext.kt:606-652`). The loop-iteration reset path does
(`dropReplay`, `ScriptRunContext.kt:507-516`), and its comment states precisely why:

> a fresh invocation must not adopt the pre-edit one's migration capture (logic-spec §5 "invocation
> identity").

**Predicted consequence, in today's shipped v1:** a backward jump over a *completed* RunStep drops
the RunStep's outcome so the spine re-runs it → it re-hosts the child → the child node reads
`restored`, and `restoredForNode` (`RunEngine.kt:1244-1257`) matches on
`(stableId, callSite)`, which still matches → the child adopts the pre-jump capture → its
`jumpPlanFor` returns null for the parent's target, so it takes a **plain restore** and
replay-short-circuits every completed step. Net effect: the sub-Script appears to re-run
instantaneously and returns its old values.

**This is reasoned from the code, not observed.** It is separable from nested support, cheap, and
high value — write the failing test first (§10).

For nested move-to it becomes load-bearing rather than merely wrong: jumping in frame `B` while
parked deeper in `C` must abandon `C`'s invocation, and `discardCaptured` is the only signal that
does it (it discards transitively via `parentStableId`, `RunEngine.kt:1265-1300`).

## 5. The loop-body collision — a hard dependency for the common shape

G1's descent needs each transit frame to suppress the boundary of the RunStep it descends through
*and* that RunStep's in-frame ancestors. For an `If`-nested or straight-line RunStep, those
ancestors come straight from the existing analysis (`ScriptNestingAnalysis.enclosingPath` +
group filtering, as `ScriptJumpAnalysis.plan` already does).

**If the hosting RunStep sits inside a loop body, that breaks down.** `ScriptJumpAnalysis.plan`
rejects any path inside a `rerun`-flagged branch outright (`ScriptJumpAnalysis.kt:86-88`,
`"Inside a loop body (not supported)"`), and descending into such a RunStep additionally requires
the loop to resume **at its current iteration** rather than restart — which is exactly the
`LoopCursor` carry work parked as the XC v2 loop-body extension
(`../2026-07-25_master-plan.md:184-185`).

`ForEach → RunStep → sub-Script` is a common automation shape, so this is not an edge case. It
splits the feature:

| Variant | Ancestor chain to the target frame | Dependency |
|---|---|---|
| **XC-N1** | every hop straight-line or `If`-nested | independently shippable |
| **XC-N2** | any hop inside a loop body | **needs the parked loop-body extension first** |

XC-N1 must therefore **reject** an XC-N2 target explicitly rather than half-honour it, and the client
must not offer the drag when the frame is unreachable — otherwise the failure mode is a silent no-op
(see §7 Q3).

## 6. Proposed design

### 6.1 kzen-lib — address the move target by frame path

Keep `moveTarget` a single id; make the **engine** decide who sees it. Add to `migrate`:

```kotlin
fun migrate(
    newRoot: Logic,
    paused: Boolean = true,
    moveTarget: ObjectStableId? = null,
    moveTargetCallSitePath: List<ObjectStableId> = emptyList(),  // root -> target frame's call-sites
    removedStableIds: Set<ObjectStableId> = emptySet()
)
```

and to `Execution`:

```kotlin
val moveTarget: ObjectStableId?          // now delivered ONLY to the addressed frame
val moveDescendCallSite: ObjectStableId? // the call-site this frame must descend through, not park at
```

Implementation is node-local: each node carries a **remaining path suffix**, assigned at spawn. The
root starts with the full path. A node with a non-empty suffix surfaces
`moveDescendCallSite = suffix.first()` and `moveTarget = null`; when it hosts a child at that
call-site the child inherits `suffix.drop(1)`. A node with an empty suffix surfaces `moveTarget` and
`moveDescendCallSite = null`. Every other node sees null for both.

Why this shape:

- **G2 falls out for free** — the target is path-addressed, so a recursive document's other frames
  see null. It also retro-fixes the self-recursive-root hazard in the shipped feature.
- **`ScriptRunContext.jumpPlanFor` needs no change** — a frame that is not addressed simply receives
  null, which is the plain-restore path it already takes.
- **The empty path is exactly today's behaviour** for a root-frame target, so the existing carry
  semantics and `ScriptMoveToTest` are unaffected. (Strictly: today's broadcast semantics become
  root-only, which is the point of G2.)
- It keeps the flavour ignorant of frame topology, consistent with "no engine `when` over flavours"
  in the other direction.

Requires a `logic-spec.md` §4 "Repositioning" amendment and a `Repositionable` KDoc update — the
spec currently specifies the broadcast-and-ignore contract that §6.1 narrows.

### 6.2 kzen-auto — server

1. **`ScriptLogic.canMoveTo`** — accept a target in any document in this Logic's transitive callee
   closure (`LogicCallGraph.transitiveCallees`) that is a Script and passes `isValidTarget` against
   *that* document's `ScriptTree`. Still a static structural check, consistent with the
   `Repositionable` KDoc. `ScriptRunStructure` already carries `graphNotation` + `graphDefinition`,
   so no new plumbing.
2. **`ServerLogicController.moveTo`** — accept a frame identifier from the client, resolve it against
   `state.engine.snapshot()`, and build `moveTargetCallSitePath` by walking root → frame collecting
   each hop's `callerStableId`. Add a **liveness gate**: reject when the named frame is absent from
   the live tree (otherwise the migrate is a silent no-op — nobody honours the target). Add an
   **XC-N1 gate**: reject when any hop's RunStep is inside a loop body (§5).
3. **No-op guard** (`ServerLogicController.kt:705-709`) — currently compares `rootNode.position`;
   must compare the **addressed frame's** node position.
4. **`ScriptRunContext.restore`** — add the descend set for a transit frame: given
   `execution.moveDescendCallSite`, put that RunStep plus its in-frame ancestors
   (`ScriptNestingAnalysis.enclosingPath`, group-filtered — reuse the `ScriptJumpAnalysis.plan`
   ancestor computation, *not* its drop/preceding sets) into `descendSteps`. Also apply the §4.3
   `discardCaptured` fix.

### 6.3 kzen-auto — client + wire

1. **Wire** — `POST /logic/moveTo` gains a frame parameter. `LogicRunFrameInfo.executionId` is
   already `LogicExecutionId(node.id.value)` (`ServerLogicController.kt:901`), i.e. the engine
   `NodeId`, and the request is issued against the current pre-rebuild tree, so sending it back is
   sufficient and unambiguous. Add `CommonRestApi.paramExecutionId` and read it in
   `LogicHandler.logicMoveTo` (`LogicHandler.kt:260-276`).
2. **`ScriptExecutionMargin`** — replace the root-document `canDrag` test with "a frame exists for
   the viewed document" (`LogicRunFrames.frameForDocument`, already called for `arrowLocation`) and
   send that frame's `executionId` from `onSurfacePointerUp`. `ClientLogicGlobal.moveToAsync` grows
   the frame argument.
3. **Rejection feedback** — with XC-N1's gates, a `Rejected` response becomes reachable through
   ordinary use (loop-hosted frame). Today's client ignores the response. Minimum: surface it; see
   §7 Q3.

## 7. Open decisions (need the user)

- **Q1 — Is XC-N1 alone worth shipping?** It covers straight-line and `If`-nested sub-Script calls
  but *not* loop-hosted ones (§5). If the dominant real shape is `ForEach → RunStep`, the honest
  sequencing is loop-body extension **first**, then nested move-to once, covering both.
- **Q2 — Should a nested jump be offered when a shallower frame would also match?** Under recursion
  the client picks the deepest matching frame (`LogicRunFrames.frameForDocument`, "the invocation the
  user is stepping into"). §6.1 makes that choice honoured exactly; the alternative is to refuse
  ambiguous cases outright. Recommend: honour the deepest, document it.
- **Q3 — How should a refused jump present?** Options: (a) never offer it — client pre-computes
  reachability and renders the glyph non-draggable with an explanatory tooltip; (b) offer, then
  surface the rejection as a transient message. (a) is better UX and needs the loop-body ancestor
  test on the client (a `ScriptNestingAnalysis` call over the *frame path*, which the client has from
  `logicStatus`); (b) is cheaper. Recommend (a) for the drag affordance, (b) as the backstop.
- **Q4 — Does the §4.3 fix ship separately and immediately?** It is a correctness bug in the shipped
  feature, independent of everything else here. Recommend yes (§10).

## 8. Sizing & session split

**Pre-session (XS, separable — see §10):** the §4.3 `discardCaptured` fix + failing test.

**Session A — kzen-lib (S/M).** `Execution.moveDescendCallSite`, `migrate`'s
`moveTargetCallSitePath`, per-node suffix assignment in `RunEngine`, `logic-spec.md` §4 amendment,
`Repositionable` KDoc. `RunEngineTest` coverage for path addressing (including a recursive shape
where a non-addressed frame of the same document must see null). Gate: kzen-lib green **and
`publishToMavenLocal`** for all four subprojects — kzen-auto consumes the variant-suffix coords from
mavenLocal (AGENTS.md § KMP variant-suffix coords).

**Session B — kzen-auto (M).** §6.2 + §6.3, tests (§9), `docs/architecture.md` § Script move-to
rewrite (its current text asserts root-document-only), the client tooltip work from Q3, and the
`ScriptExecutionMarginState.draggable` comment which documents the limitation being removed
(`ScriptExecutionMargin.kt:73-76`).

**Deferred to XC-N2:** loop-hosted frames, behind the parked loop-body extension.

Confidence on sizing is **moderate** and rests on §4.1's untested prediction. If the mid-flight
nested edit-migrate turns out to already descend correctly (contradicting the `checkpoint` reading),
G1 shrinks to nothing and Session B absorbs Session A's remainder. **Establish that with a test
before committing to two sessions.**

## 9. Test plan

New, in `kzen-auto-jvm/src/test/.../impl/` alongside `ScriptMoveToTest`:

- backward jump inside a sub-Script frame re-runs from the target, parent stays parked at its RunStep
- forward jump inside a sub-Script frame skips intervening steps, parent unchanged
- jump in a middle frame (`A → B → C`, target in `B`) abandons `C`: `C`'s capture discarded, its
  frame re-hosted fresh on resume
- jump into an `If` branch **inside** a sub-Script frame (composes G1's frame descent with the
  existing in-frame `descendSteps` — the interesting interaction)
- target in a document that is **not live** → `Rejected`, run untouched
- target reached through a loop-hosted RunStep → `Rejected` with the XC-N1 reason
- recursive document (`A` hosting `A`), target in the deep frame → only the deep frame moves
- **regression:** `ScriptMoveToTest`'s twelve existing cases unchanged (empty path ≡ today)

Extend `ServerLogicControllerLinkedDocumentMigrationTest` with the **mid-flight** RunStep edit case
(§4.1) — missing today regardless of this feature.

Manual smoke (§C2 debt style): drag the arrow in a sub-Script opened from a parent's run, both
directions; confirm the parent's next-to-run stays on its RunStep and the sidebar frame indicator
does not flicker.

## 10. Separable pre-work — ship independently of everything above

1. **§4.3 `discardCaptured` on the move-to drop set.** Write the failing test first: run a parent
   with a completed RunStep whose sub-Script produced a value, jump backward past the RunStep, assert
   the sub-Script's steps re-execute (not replay-adopt) and its value is re-derived. If it
   reproduces, the fix is one line in `ScriptRunContext.restore` plus the test. XS.
2. **Document the current limitation.** Independent of any implementation, and worth doing even if
   this plan is never scheduled: `docs/architecture.md:231-233` records the loop-body v1 exclusion
   but is silent on root-document-only, and the master plan's parked XC list names only loop-body
   targets. The restriction currently lives **only** in code comments.
3. **Distinguish the inert glyph.** The nested-frame glyph renders identically to the
   "run is executing" glyph (§3). A tooltip is a one-line change that converts a bug report into a
   known limitation.

## 11. Risks

- **§4.1 is a prediction from reading `checkpoint`.** It drives the session split. Test first.
- **§4.3 is likewise predicted, not observed.** Stated as such; the failing test is step one.
- **Narrowing the engine's broadcast contract is a spec change.** `Execution.moveTarget`'s
  "root and hosted children may all read it" is load-bearing documentation; §6.1 replaces it with
  path addressing. Flow and Job are not `Repositionable` and ignore the target either way, so no
  other flavour is affected — but the spec is the authority and must move in the same session.
- **Recursion under migration is weakly defined** (§4.2, `migrationCaptured` keyed by stable id
  alone). Nested move-to should not claim recursion support beyond what path addressing gives it;
  state the boundary in the docs rather than discovering it later.
- **Scope creep into loop bodies.** XC-N1's gates must be real rejections, not best-effort, or the
  feature silently half-works in the most common nesting shape.
