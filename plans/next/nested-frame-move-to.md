# XC-N — nested-frame move-to (Set Next Statement inside a sub-Script)

> **Standalone scoping document** (design rationale + elaboration in one file, like
> `context-and-resource.md` — the "Constituent plan" column reads `—`, so archive it as an as-built
> record rather than deleting it). **Status: ✅ LANDED 2026-07-30** — both master-plan ledger rows,
> **30** (Session A, kzen-lib) and **31** (Session B, kzen-auto). **Read §13 and §14 (As-built)
> first**: §13 records two additions to the kzen-lib surface this document did not foresee — one of
> them a defect the feature itself introduced — and the recursion case narrowed in both repos. **§14
> records the same-day post-smoke defect fix**, which found two more XC-N1-introduced defects and
> established that this document's own loop-transit parking rationale (§5) was **false** — loop-hosted
> *transit* shipped 2026-07-30; only loop-body *targets* remain parked. §1–§12 are the design as
> planned, not as built, and §5 in particular is now **superseded by §14.1**.
>
> Anchors captured 2026-07-29 against kzen-lib `67730a9` / kzen-auto `97543315`; re-verified
> 2026-07-30 against kzen-lib `67730a9` / kzen-auto `a313f177` (one commit later — notation-only, so
> every anchor still resolves). That review confirmed the §4.1 and §4.3 code readings by independent
> inspection (still untested — the failing tests remain step one) and **corrected four claims about
> existing code that changed the work**: `canMoveTo` widening is unnecessary and not free (§6.2),
> `LogicRunFrameInfo` is a kzen-lib type (§6.3 → Session A), `CommonRestApi.paramExecutionId` already
> exists, and the client already surfaces `Rejected` (§7 Q3). Re-verify before editing (standing rule
> in `README.md`).
>
> **Completes XC** (execution control, landed Sprint 1 — `sprint-1/README.md` ledger row for
> `2026-07-10_execution-control.md`). XC shipped move-to gated to the **run-root frame**. This
> document scopes lifting that to any live frame.
>
> ⚠️ **This is a defect, not a feature (established 2026-07-30 — see §10.2).** No spec or doc
> asserts a root-document restriction; `logic-spec.md` §4, `architecture.md` and
> `Execution.moveTarget`'s own KDoc all describe move-to frame-agnostically, and the KDoc explicitly
> says hosted children may read the target. The gate lives only in code, labelled "v1". Contrast the
> **loop-body** exclusion, which *is* a real parked extension — documented, deliberate, with an
> explicit rejection path (`../2026-07-25_master-plan.md` § XC). §5 shows the two are **not
> independent**: the loop-hosted shape of this defect cannot be fixed until that extension lands.
> So this document is one defect fix (XC-N1) plus one part that waits on a feature (XC-N2) — not
> "the second parked XC extension", which is how the 2026-07-29 draft mis-filed it.

## 1. Verdict

**The mechanism is largely already there; it is gated off in code that no spec backs.** The surgery
that makes move-to work is already written per-frame and document-scoped, the engine already
broadcasts the move target to every frame in the rebuilt tree, and breakpoints already work nested.
Move-to is the *only* execution-control verb that is not frame-agnostic — step into/over/out cross
frame boundaries as engine policies over the tree, and the run's own spec says hosted children may
read the move target. Three narrow gaps stand between that and a working nested jump, one of which
was a **second, independent defect in the shipped feature** (§4.3 — **fixed 2026-07-30**, ahead of
any decision on the rest of this document).

Read that together with §10.2: **this document fixes a defect for the straight-line and `If`-nested
shapes (XC-N1), and inherits the genuine loop-body feature gap for the rest (XC-N2).** That is a
different scheduling argument from "a parked extension competing with backlog items" — a shipped
verb does not do what its own spec says it does.

Sizing: **2 sessions** for the straight-line-ancestor case. The separable XS pre-session has
already landed, so G3 is no longer a cost. Full generality (a sub-Script hosted from inside a loop
body — a common shape) **requires the parked loop-body extension first** (§5); that is the main
reason not to schedule this as a single unit.

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
correctly fall through to a plain restore. `jumpPlanFor` needs no change; the one signature change
is that `restore` (and this call line) grows the descend parameter of §6.2.4.

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
not hosted during the paused rebuild — and the failure mode is worse than a dropped jump:
`migrationMoveTarget` persists until the next barrier (cleared only by the next `migrate` /
`sweepOrphans`), so when the user later resumes, the parent re-runs the RunStep, the re-hosted child
adopts its capture, reads the still-set target, and applies the jump **late** — mid-run, unparked,
with no visual connection to the drag that requested it. §6.1's one-shot path delivery closes this
for good.

This is exactly the problem `descendSteps` already solves *within* one frame: an enclosing `If` on
the path to the target re-runs with its checkpoint suppressed so the rebuild parks at the target
rather than the ancestor's boundary (`ScriptRunContext.kt:407-413`, and
`ScriptJumpAnalysis.ScriptJumpPlan.ancestors`). **G1 is the frame-level analogue**: every frame on
the path from the root to the target frame must suppress the boundary of the RunStep it descends
through, plus that RunStep's own in-frame ancestors.

Confirmed by inspection 2026-07-30: `RunStep.run` (`RunStep.kt:29-37`) holds no checkpoint of its
own — it resolves its arguments and calls `execution.host` — so the spine's named boundary at
`ScriptRunContext.kt:412` is the *only* thing that parks, and suppressing it is both necessary and
sufficient to descend through a RunStep.

Note this same code path governs an **ordinary nested edit-migrate**: editing while paused inside a
sub-Script should, by the same reading, pop the position out to the parent's RunStep.
`ServerLogicControllerLinkedDocumentMigrationTest` covers two shapes — the RunStep **not yet run**
at the edit (`editingHostedCalleeWhileCallerPausedMigratesTheCaller`) and the RunStep **completed**
before it (`aCompletedRunStepsSubDocumentKeepsItsExecutionStateAcrossAnEdit`, whose header says
"The rebuilt spine replay-adopts the completed RunStep instead of re-invoking it"). Neither is the
mid-flight case, which is untested. **Confirm with a test before designing.**

⚠️ **This does not make G1's fix shared work.** §6.1 derives the descend path from the *move-to
request*; a plain edit-migrate carries no move target, so nothing proposed here descends for it.
Making it shared needs the engine to derive a default descend path from the **parked frame stack**
at the barrier — a separate, unsized feature (see §8's optional item). Treat the mid-flight test as
*characterization*: it records what a nested edit does today, and it is the same test that proves
G1's descent works once the move-to path exists. Do not discount Session A on the strength of it.

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

**This one IS worth documenting, unlike §10.2's withdrawn item** — the distinction matters and is
the general rule: document what is genuinely *undefined* (two simultaneously-live frames sharing a
stable id have no specified winner — nothing in any spec says what should happen, so recording the
boundary adds information), never what a spec already defines and the code merely fails to do
(root-frame-only, which contradicts `Execution.moveTarget`'s own contract — there, writing it down
would replace a promise with an excuse). One concrete consequence
for this plan: an addressed frame acts on the target only from inside `restore`, which runs only
when the frame adopts a capture (`ScriptLogic.kt:81-83`) — so under self-recursion the addressed
frame's jump is contingent on *winning* the capture collision. §9's recursion test is scoped
accordingly.

### 4.3 G3 — an abandoned child's capture is never discarded (pre-existing defect) — ✅ FIXED 2026-07-30

`ScriptRunContext.restore`'s move-to path computes `dropStableIds` and prunes
`restoredOutcomes` / `restoredCarries`, but **never calls `execution.discardCaptured(dropStableIds)`**
(`ScriptRunContext.kt:606-652`). The loop-iteration reset path does
(`dropReplay`, `ScriptRunContext.kt:507-516`), and its comment states precisely why:

> a fresh invocation must not adopt the pre-edit one's migration capture (logic-spec §5 "invocation
> identity").

**Consequence in shipped v1 — predicted here, then OBSERVED and fixed 2026-07-30:** a backward jump
over a *completed* RunStep drops
the RunStep's outcome so the spine re-runs it → it re-hosts the child → the child node reads
`restored`, and `restoredForNode` (`RunEngine.kt:1244-1257`) matches on
`(stableId, callSite)`, which still matches → the child adopts the pre-jump capture → its
`jumpPlanFor` returns null for the parent's target, so it takes a **plain restore** and
replay-short-circuits every completed step. Net effect: the sub-Script appears to re-run
instantaneously and returns its old values.

**Reproduced exactly as predicted, then fixed** (§10.1, landed 2026-07-30). The characterization test
`ScriptMoveToTest.backwardJumpPastACompletedRunStepAbandonsItsChildInvocation` failed
`expected:<5> but was:<4>` — the re-hosted sub-Script replay-adopted its abandoned invocation's
capture and its `CountingStep` never executed. One line in `ScriptRunContext.restore`
(`execution.discardCaptured(dropStableIds)`) turns it green; full `kzen-auto-jvm` suite 623/623.

Two supporting readings, both confirmed 2026-07-30:

- A **settled** child IS captured, so the scenario above has a capture to adopt: `migrate` captures
  every node holding a provider and orders terminal sources first so a live frame wins the key
  collision (`RunEngine.kt:530-543`). (`RunEngine.kt:165`'s comment claimed only live nodes are
  captured — stale since settled-frame carry landed, and exactly the reading the fix turns on.
  **Corrected 2026-07-30** in the same session.)
- The **duplicate settled frame needs no handling**: `supersedeRetiredFrames`
  (`RunEngine.kt:734-751`) already drops a carried terminal frame the moment its host re-invokes the
  same definition from the same call-site. So the fix really is `discardCaptured` alone, with no
  retired-frame counterpart.

**Scope decision — SETTLED 2026-07-30: discard the DROP set only, document the rest.**
`dropStableIds` covers the backward-jump case. A FORWARD jump additionally abandons the hosted
children of mid-flight steps in `plan.precedingOnPath` that become `skippedSteps`
(`ScriptRunContext.kt:629-652`) — the spine short-circuits those steps, so they never re-host, and
their children's captures sit unclaimed until the NEXT barrier's `sweepOrphans` disposes them.
Deliberately NOT discarded: nothing can adopt them (the step does not run, so no fresh invocation
exists to match `(stableId, callSite)`), and eagerly sweeping them would special-case one flavour
against the engine's own documented orphan policy — "an orphaned detached resource lingers at most
one edit cycle (deliberate: no eager sweep on every edit)" (`RunEngine.sweepOrphans`). The reasoning
is recorded in the new `restore` comment so it is not re-litigated.

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
| **XC-N1** | every hop straight-line or `If`-nested, every transit frame descent-capable | independently shippable |
| **XC-N2** | any hop inside a loop body | **needs the parked loop-body extension first** |

XC-N1 must therefore **reject** an XC-N2 target explicitly rather than half-honour it, and the client
must not offer the drag when the frame is unreachable — otherwise the failure mode is a silent no-op
(see §7 Q3).

**A second hop gate: transit-frame capability.** `RunStep.instructions` may point at any runnable
Logic, and `LogicCallGraph` deliberately matches Flow's `RunLogic` and Job's `RunWorker` too — so a
path to a Script target can route through a **Flow or Job frame**, which would ignore the descend
signal and park at its own boundary: the same silent no-op. The mechanism stays document- and
flavour-agnostic: §6.1 defines descent in the engine's generic contract and any Logic may implement
it; the gate is **capability-based, never flavour-named** — reject when any hop's Logic does not
implement the descend contract (§6.2), exactly as `Repositionable` gates the root today. XC-N1
implements the contract in Script only; Flow / Job can adopt it later with no engine or controller
change.

## 6. Proposed design

### 6.1 kzen-lib — address the move target by frame path

Keep the target a single id; make the **engine** decide who sees it. Bundle the id with its frame
path in one nullable value so the meaningless combination (a path with no target) is
unrepresentable rather than an invariant the implementation has to remember:

```kotlin
/** A move-to target plus the frame that owns it: [callSitePath] is root -> that frame's call-sites
 *  (empty = the root frame, which is the pre-XC-N behaviour). */
data class MoveTarget(
    val target: ObjectStableId,
    val callSitePath: List<ObjectStableId> = emptyList()
)

fun migrate(
    newRoot: Logic,
    paused: Boolean = true,
    moveTarget: MoveTarget? = null,
    removedStableIds: Set<ObjectStableId> = emptySet()
)
```

and to `Execution`:

```kotlin
val moveTarget: ObjectStableId?          // now delivered ONLY to the addressed frame
val moveDescendCallSite: ObjectStableId? // the call-site this frame must descend through, not park at
```

Implementation is node-local: each node carries a **remaining path suffix**, assigned at spawn. The
root starts with `MoveTarget.callSitePath` (null when `moveTarget` is null). A node with a non-empty
suffix surfaces `moveDescendCallSite = suffix.first()` and `moveTarget = null`; when it hosts a
child at that call-site the child inherits `suffix.drop(1)`. A node with an empty suffix surfaces
`moveTarget` and `moveDescendCallSite = null`. Every other node sees null for both. Two contract
points that must be explicit in the implementation: **null vs empty are different states** — a null
suffix means *not addressed* (both surfaces null), an empty suffix means *this is the addressed
frame*; and delivery is **one-shot per barrier** — the parent's suffix is consumed at the hosting
that claims it, so a second same-generation hosting at the same call-site inherits nothing, and the
§4.1 late-application hazard cannot recur through the path (the tree-wide broadcast that made it
possible is gone).

Matching is on `Execution.host`'s `callerStableId`, which is **nullable** — a host that names no
distinct call-site cannot be path-addressed. That is a controller-side gate, not an engine concern
(§6.2), but it is why the engine must treat a null `callerStableId` as "never matches the suffix"
rather than as a wildcard.

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
- **The descend contract is generic across Logic flavours.** `moveDescendCallSite` is engine
  surface, and honouring it is specified as part of the `Repositionable` contract: a Repositionable
  Logic honours an addressed `moveTarget` *and*, as a transit frame, honours `moveDescendCallSite`
  (run to the named call-site with its boundary suppressed, then host). Script is the only
  implementer in XC-N1; Flow could implement the same contract later with no engine change, and the
  §6.2 hop gate is `is Repositionable` — capability, not flavour.

**Doc surface this moves** (all four, same session):

- `logic-spec.md` §4 "Repositioning" — currently specifies the broadcast-and-ignore contract §6.1
  narrows; the amendment also defines the transit-frame descend obligation as part of the same
  contract, so hop capability (§5, §6.2) is spec-backed rather than Script-specific.
- `logic-spec.md` §5 — the migration-barrier bullet that describes move-to as a self-migration.
- `Repositionable` KDoc — add the transit-frame obligation to the interface contract.
- **`Execution.host`'s `callerStableId` KDoc** (`Execution.kt:110-114`), which today says the
  call-site is recorded "purely for trace attribution". §6.1 promotes it to load-bearing frame
  addressing; leaving that KDoc as-is invites a future change to treat it as cosmetic.

### 6.2 kzen-auto — server

**`ScriptLogic.canMoveTo` does NOT change.** The 2026-07-29 draft widened it to the transitive callee
closure; the 2026-07-30 review rejected that on two grounds, and dropping it removes a whole item:

- *Not free.* `LogicCallGraph.transitiveCallees` takes a `GraphStructure` — it reads
  `graphMetadata.objectMetadata` (`LogicCallGraph.kt:114`) — and `ScriptRunStructure` carries
  `graphNotation` / `graphDefinition` / `graphInstance` and **no metadata**
  (`ScriptRunStructure.kt:22-32`). Synthesizing one per call (via `services.notationMetadataReader`)
  is exactly the plumbing the draft claimed did not exist.
- *Not needed.* §6.2.1 below already compiles every hop's Logic. The **addressed frame's** compiled
  Logic answers the same question with the unmodified `canMoveTo`, and keeps the `Repositionable`
  KDoc honest ("the target resolves to a legal move-to element in **this Logic's** structure")
  instead of stretching one Logic's structural check across documents it does not own.

1. **`ServerLogicController.moveTo`** — accept a frame identifier from the client, resolve it against
   `state.engine.snapshot()`, and build the `MoveTarget.callSitePath` by walking root → frame
   collecting each hop's `callerStableId` (read straight off the engine `Node`, so **no wire change
   is needed for the server's own gating** — see §6.3.1 for why the client still wants it). Then, in
   order, four refusals — all before the barrier, run untouched:
   - **liveness** — reject when the named frame is absent from the live tree *or* is `Terminal`
     (`nodeToFrame` prunes terminal children from the wire tree but `snapshot()` does not, so an id
     from a stale client poll can still resolve to a settled node). Otherwise the migrate is a silent
     no-op — nobody honours the target.
   - **addressability** — reject when any hop's `callerStableId` is null (§6.1: a host naming no
     distinct call-site cannot be path-addressed).
   - **XC-N1** — reject when any hop's RunStep is inside a loop body (§5).
   - **descent capability + target validity** — compile each hop's Logic
     (`compileLogic(hopLocation, attempt, state.runExecutionId)` is already location-generic,
     `ServerLogicController.kt:929-941`) and reject when a *transit* hop is not `Repositionable`, or
     when the **addressed frame's** Logic is not `Repositionable` or its `canMoveTo(targetId)` is
     false. This subsumes today's root-only gate at `ServerLogicController.kt:730-732`.
     Capability-based, no flavour named (§5): today only Script qualifies, so a Flow / Job hop
     rejects cleanly instead of silently parking.
2. **No-op guard** (`ServerLogicController.kt:705-709`) — currently compares `rootNode.position` and
   `rootNode.status is Suspended`. Both must move to the **addressed frame's** node: while parked
   inside a child the root node is `Running` (it is blocked in `host`, and only `park` sets
   `Suspended`), so today's guard silently never fires for a nested run.
3. **`ScriptRunContext.restore`** — add the descend set for a transit frame: given
   `execution.moveDescendCallSite`, put that RunStep plus its in-frame ancestors
   (`ScriptNestingAnalysis.enclosingPath`, group-filtered — reuse the `ScriptJumpAnalysis.plan`
   ancestor computation, *not* its drop/preceding sets) into `descendSteps`. `restore`'s signature —
   and the `ScriptLogic.kt:81-83` call — grows the `moveDescendCallSite` parameter alongside
   `moveTarget`. Also apply the §4.3 `discardCaptured` fix.

   ⚠️ **`restore` gains a THIRD path.** It is binary today: `plan == null` early-returns to a plain
   restore (`ScriptRunContext.kt:600-605`), else it does the surgery. A transit frame sees
   `moveTarget == null` (so `plan == null`) *and* a non-null `moveDescendCallSite` — it needs
   **plain restore PLUS `descendSteps`**. Seeding the descend set inside the surgery branch, or
   after the early return, silently produces the §4.1 park-at-the-RunStep behaviour with no
   test-visible signal other than the nested jump not happening.

### 6.3 kzen-auto — client + wire

1. **Wire** — `POST /logic/moveTo` gains a frame parameter. `LogicRunFrameInfo.executionId` is
   already `LogicExecutionId(node.id.value)` (`ServerLogicController.kt:901`), i.e. the engine
   `NodeId`, and the request is issued against the current pre-rebuild tree, so sending it back is
   sufficient and unambiguous. Node ids are monotone and never reused, so a stale id resolves to
   nothing and rejects cleanly.
   - `CommonRestApi.paramExecutionId` **already exists** (`CommonRestApi.kt:79`, `= "execution"`) —
     only `LogicHandler.logicMoveTo` (`LogicHandler.kt:260-276`) needs to read it.
   - ~~`LogicRunFrameInfo` grows the frame's call-site.~~ **CUT by Q3's settlement (2026-07-30) — do
     not build it.** It would have been a kzen-lib wire change
     (`kzen-lib-common/.../exec/logic/run/model/LogicRunFrameInfo.kt`, a SER4 `@Serializable` type),
     and Q3(a)'s client-side reachability pre-check was its only consumer. The server never needed
     it: §6.2.1 walks `callerStableId` off the engine `Node` directly. **XC-N therefore touches no
     wire type at all** — the only wire change is `logicMoveTo` reading an already-defined parameter.
     *If Q3 is ever reversed*: surface the field as a resolved `ObjectLocation` like the neighbouring
     `position`, resolved **leniently** (`objectLocationOrNull` → null, never a throw) —
     `nodeToFrame`'s comment (`ServerLogicController.kt:893-897`) explains that a throw there takes
     out `/logic/status` and the SSE loop, wedging the client out of the very edit that would fix it.
2. **`ScriptExecutionMargin`** — replace the root-document `canDrag` test with "a frame exists for
   the viewed document" (`LogicRunFrames.frameForDocument`, already called for `arrowLocation` at
   `ScriptExecutionMargin.kt:306`) and send that frame's `executionId` from `onSurfacePointerUp`.
   `ClientLogicGlobal.moveToAsync` grows the frame argument.
3. **Rejection feedback — already built, no work.** With XC-N1's gates a `Rejected` response becomes
   reachable through ordinary use (loop-hosted frame), but `moveToAsync` already passes a dedicated
   `rejectedLabel` ("Can't move to this step") and `controlAsync` already maps
   `LogicRunResponse.Rejected` to it (`ClientLogicGlobal.kt:704-710`, `505-548`). The 2026-07-29
   draft's "today's client ignores the response" was wrong. Q3(b) therefore ships for free; only
   Q3(a) is discretionary.

## 7. Decisions — ALL SETTLED 2026-07-30

Closed out on "get this ready for implementing". Each records what would reverse it, so a session
proceeds without re-opening any of them.

- **Q1 — Is XC-N1 alone worth shipping? → YES.** It covers straight-line and `If`-nested sub-Script
  calls but *not* loop-hosted ones (§5). Settled by the defect framing (§10.2): a shipped verb that
  does not do what its spec says gets fixed for the shapes reachable now, and XC-N2's remainder then
  reads as the *documented* loop-body exclusion rather than a second undocumented gap. The
  alternative — loop-body extension first, then nested move-to once — leaves the defect standing for
  two features' worth of work.
  *Reverse if:* real use shows `ForEach → RunStep` so dominant that XC-N1 would go unnoticed.
- **Q2 — Which frame does a nested jump address when several match? → THE DEEPEST.** Under recursion
  the client already picks the deepest matching frame (`LogicRunFrames.frameForDocument`, "the
  invocation the user is stepping into"), the trace view already scopes the same way, and §6.1
  honours that choice exactly. Refusing ambiguous cases outright was the alternative; it would make
  the common single-frame case pay for the rare recursive one.
  *Reverse if:* users report jumping in a frame they were not looking at. Note §4.2's bound — under
  self-recursion the deep frame's jump is contingent on winning the capture collision.
- **Q3 — Build the drag-time reachability pre-check? → NO. Ship (b) alone.** The backstop — offer,
  then surface the rejection — **already exists** (§6.3.3), so a refused nested jump already
  presents correctly. Option (a) (client pre-computes reachability, renders the glyph non-draggable)
  needs a client-side loop-body ancestor test over the frame path and can only approximate the
  descent-capability gate.
  **Consequence, load-bearing for Session A:** (a) was the *only* consumer of the
  `LogicRunFrameInfo` call-site field, so **that kzen-lib wire change drops out of Session A
  entirely** (§6.3.1). The server reads `callerStableId` off the engine `Node` directly, so nothing
  else needs it.
  *Reverse if:* the loop-hosted refusal proves common enough that an error message after the drag
  reads as broken rather than informative.
- **Q4 — Does the §4.3 fix ship separately and immediately? → YES, LANDED 2026-07-30** (§10.1).
  Independent of everything else here, so it shipped without waiting on Q1–Q3.

## 8. Sizing & session split

**Pre-session (XS, separable — see §10):** ✅ **LANDED 2026-07-30.** The §4.3 `discardCaptured` fix,
its characterization test + two new fixtures, and the stale `RunEngine.kt:165` comment. Actual cost
matched the XS estimate; the only deviation was needing new fixtures (§10.1 as-built).

**Session A — kzen-lib (S).** `MoveTarget` (id + call-site path), `Execution.moveDescendCallSite`,
`migrate`'s new parameter shape, per-node suffix assignment in `RunEngine` (null-vs-empty
distinction, one-shot consumption, null `callerStableId` never matches — §6.1), and the four doc
surfaces of §6.1 (`logic-spec.md` §4 + §5,
`Repositionable` KDoc, `Execution.host`'s `callerStableId` KDoc). `RunEngineTest` coverage for path
addressing (including a recursive shape where a non-addressed frame of the same document must see
null). Gate: kzen-lib green **and `publishToMavenLocal`** for all four subprojects — kzen-auto
consumes the variant-suffix coords from mavenLocal (AGENTS.md § KMP variant-suffix coords).

**Session B — kzen-auto (M).** §6.2 + §6.3, tests (§9), and the
`ScriptExecutionMarginState.draggable` comment which records the "v1" gate being removed
(`ScriptExecutionMargin.kt:73-76`). **`docs/architecture.md` needs no rewrite** — the 2026-07-29
draft claimed "its current text asserts root-document-only"; it does not (§10.2), it already
describes move-to frame-agnostically. At most add a sentence noting frames are addressed by
call-site path once §6.1 lands. Net effect
of the 2026-07-30 review + decisions on this session: **−** the `canMoveTo` widening (dropped,
§6.2), **−** the rejection-feedback work (already built, §6.3.3), **−** the reachability pre-check
(Q3 → no), **+** the three new notation fixtures of §9, which are now the largest single item.
Still M.

**Optional, not in either session — stack-derived descent.** Deriving the descend path from the
parked frame stack when NO move target is present would make a plain nested edit-migrate hold its
position instead of popping out to the parent's RunStep (§4.1). It is a genuine improvement and it
reuses G1's mechanism, but it is a separate feature with its own semantics question ("should an edit
resume inside the child, or park at the wavefront?" — the `migrate(paused)` contract currently says
the latter). **Unsized. Do not fold it into Session A silently.**

**Deferred to XC-N2:** loop-hosted frames, behind the parked loop-body extension.

Confidence on sizing is **moderate** and rests on §4.1's untested prediction. Note the review closed
one escape hatch the 2026-07-29 draft left open: `RunStep.run` demonstrably holds no checkpoint of
its own, so the park-at-the-RunStep reading has no alternative explanation — G1 will not shrink to
nothing. **Still write the mid-flight test first**, but expect it to confirm rather than surprise.

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
- target reached through a non-`Repositionable` transit frame (a Flow / Job hop) → `Rejected` with
  the capability reason (§5)
- recursive document (`A` hosting `A`), target addressed to the deep frame → the **root frame is
  unaffected** (path addressing). The deep frame's own jump is asserted only when it adopted a
  capture: under the §4.2 single-key collision the addressed frame may restore nothing (its capture
  lost), re-running fresh from its start — legal; what the test must rule out is either frame
  applying the *other's* surgery. A guaranteed deep-frame jump under self-recursion stays out of
  scope until `migrationCaptured` is invocation-keyed (§4.2)
- **regression:** `ScriptMoveToTest`'s **eleven** existing cases unchanged (empty path ≡ today) —
  ten as of the 2026-07-29 draft, plus the §10.1 abandoned-invocation case landed 2026-07-30

Extend `ServerLogicControllerLinkedDocumentMigrationTest` with the **mid-flight** RunStep edit case
(§4.1) — missing today regardless of this feature (its two existing tests cover *not yet run* and
*completed*, never *in flight*).

**New notation fixtures — the largest single item in Session B, and absent from the 2026-07-29
draft.** `kzen-auto-jvm/src/test/resources/notation/test/` holds only two-level parent/child pairs
today (`script-moveto-*.yaml`, `script-engine-run-test.yaml` + `script-engine-child-test.yaml`).
Three of the cases above need fixtures that do not exist:

| Case | Fixture needed |
|---|---|
| middle-frame jump abandoning `C` | three-level `A → B → C` chain |
| non-`Repositionable` transit hop | `Script → Flow (RunLogicVertex) → Script` |
| recursion / path addressing | self-hosting `A` (a RunStep whose `instructions` names its own document) |

Each is a new file: `git add` it by explicit path in the sibling repo as it is written
(AGENTS.md § Stage new files you create).

Manual smoke (§C2 debt style): drag the arrow in a sub-Script opened from a parent's run, both
directions; confirm the parent's next-to-run stays on its RunStep and the sidebar frame indicator
does not flicker.

## 10. Separable pre-work — ship independently of everything above

1. ✅ **LANDED 2026-07-30 — §4.3 `discardCaptured` on the move-to drop set.** As-built:
   - **Test first, and it reproduced**: `ScriptMoveToTest`
     `backwardJumpPastACompletedRunStepAbandonsItsChildInvocation` failed `expected:<5> but was:<4>`.
   - **Fixture correction**: the pre-fix draft claimed "the existing two-level
     `script-engine-run-test.yaml` pair is enough, no new fixture" — **wrong**. That child is
     deterministic in its input, so replay-adopt and fresh-run produce the same value and the defect
     is invisible without an edit muddying the probe. Added `script-moveto-abandon-test.yaml` +
     `script-moveto-abandon-child-test.yaml`, a `CountingStep` on each side, matching
     `ScriptMoveToTest`'s established side-effect idiom — the count is a direct assertion on
     *execution*, with no edit involved.
   - **Fix**: one line + comment in `ScriptRunContext.restore`, scoped to the drop set (see §4.3's
     settled scope decision). `restore` KDoc and the class-level MOVE-TO note updated.
   - **Also**: corrected the stale `RunEngine.kt:165` capture comment.
   - **Gate**: `ScriptMoveToTest` 11/11; full `kzen-auto-jvm` suite **623 tests, 0 failures**;
     `kzen-lib-jvm` compiles (its change is comment-only, so no `publishToMavenLocal` needed).
2. ~~**Document the current limitation.**~~ **WITHDRAWN 2026-07-30 — there is no limitation to
   document, and writing one down would be the wrong move.** Verified across all three doc sets:
   `kzen-auto/docs/architecture.md` § Script move-to, `kzen-auto/docs/js-architecture.md`, and
   `kzen-lib/docs/logic-spec.md` §4/§5 — **not one of them asserts a root-document restriction.**
   Every one describes move-to frame-agnostically ("reposition a paused run to a named element"),
   and `Execution.moveTarget`'s KDoc anticipates the opposite outright: *"the root and hosted
   children may all read it during one barrier's rebuild."* The spec already promises what XC-N
   would deliver.

   That settles the character of this work: **root-document-only is a defect, not a scope
   decision.** Documenting it would enshrine an implementation gap as a designed boundary and make
   the spec retreat to match the code — backwards. The restriction exists in exactly three places,
   all code, and two of them say "v1" (deferral language, not decision language):
   `ScriptExecutionMargin.kt:311-313` + its `draggable` KDoc, and `ServerLogicController.kt:730-732`.

   Corollary that sharpens §6.2: **`ScriptLogic.canMoveTo` is not the bug.** It correctly answers
   for its own structure, exactly as `Repositionable`'s KDoc specifies. The bug is that the
   controller only ever asks the *root* Logic. That is one more reason §6.2's gate belongs on the
   addressed frame's Logic rather than on a widened `canMoveTo` — the fix restores the contract
   instead of stretching it.
3. **Distinguish the inert glyph — stopgap only, and only if rows 30–31 slip.** The nested-frame glyph
   renders identically to the "run is executing" glyph (§3) — same 0.5 opacity, same
   `pointerEvents = none`, same absent `title`. A tooltip is a one-line change, but per item 2 it
   must not be worded as a designed limitation, and if XC-N1 lands it is immediately deleted. Do it
   **only** as a stopgap if rows 30–31 slip; with Q3 settled as "(b) alone", the loop-hosted case
   that survives into XC-N1 presents as a post-drag rejection message, not as an inert glyph.

## 11. Risks

- **§4.1 is still a prediction from reading the code** — confirmed by an independent second reading
  (2026-07-30 review) but unobserved; the mid-flight test remains step one of Session A.
  **§4.3 is no longer a risk**: it was reproduced exactly as predicted and fixed the same day
  (§10.1). That the one prediction which got tested came back precisely as read is mild evidence for
  §4.1, not proof of it.
- **This document's own claims about existing code were wrong four times** (see the header note),
  each in the direction of inventing work that already existed or understating plumbing. Treat every
  "already exists" / "no new plumbing" assertion below as re-verifiable, not as settled: open the
  file. The four caught were `canMoveTo`'s closure widening, `LogicRunFrameInfo`'s home build,
  `paramExecutionId`, and the client's rejection handling.
- **Narrowing the engine's broadcast contract is a spec change — but not a retreat.** Worth stating
  precisely, because §10.2 leans on the *same* sentence: `Execution.moveTarget`'s "the root and
  hosted children may all read it" is what proves nested repositioning was always intended, and
  §6.1 replaces that delivery mechanism with path addressing. The **promise** (a hosted frame can be
  repositioned) is kept and finally implemented; only the **mechanism** (broadcast-and-ignore →
  precise addressing) changes, because broadcast cannot survive recursion (§4.2). Do not read the
  narrowing as walking back the frame-agnostic contract — it is what makes it real.

  Blast radius is nil: Flow and Job are not `Repositionable`, so they neither honour a target nor
  qualify as transit hops (the §6.2 capability gate rejects paths through them); no other flavour is
  affected. The spec is the authority and must move in the same session — including the new
  transit-frame descend obligation.
- **Recursion under migration is weakly defined** (§4.2, `migrationCaptured` keyed by stable id
  alone). Nested move-to should not claim recursion support beyond what path addressing gives it;
  state the boundary in the docs rather than discovering it later — this is the *undefined*
  category, which documenting genuinely informs, not the §10.2 category, where documenting would
  have papered over a defect.
- **Scope creep into loop bodies.** XC-N1's gates must be real rejections, not best-effort, or the
  feature silently half-works in the most common nesting shape.

## 12. Execution checklist

Ordered. Ledger rows 30 (Session A) and 31 (Session B) in `../2026-07-25_master-plan.md`. Every
decision is settled (§7); nothing here needs the user. Re-verify anchors before editing — this
document's own claims were wrong four times (§11).

### Session A — kzen-lib (row 30)

1. **Characterization test FIRST** — extend `ServerLogicControllerLinkedDocumentMigrationTest`
   (kzen-auto) with the **mid-flight** RunStep edit: pause *inside* the sub-Script, edit, migrate,
   assert where the run parks. §4.1 predicts it pops out to the parent's RunStep. Record the result
   either way; it is the same test that proves G1's descent in Session B.
   *This one test lives in kzen-auto but belongs to A — it is the evidence A's design rests on.*
2. `MoveTarget(target, callSitePath)` + `RunEngine.migrate`'s new parameter shape (§6.1).
3. `Execution.moveDescendCallSite`; `moveTarget` becomes addressed-frame-only.
4. Per-node remaining-suffix assignment in `RunEngine` — assigned at spawn in `host`, under lock.
   Three invariants, each with its own `RunEngineTest` case: **null ≠ empty** (null = not addressed,
   empty = addressed); **one-shot consumption** at the hosting that claims it; **null
   `callerStableId` never matches** a suffix entry.
5. `RunEngineTest` — path addressing, plus a **recursive shape** where a non-addressed frame of the
   same document must see null on both surfaces.
6. Docs, all four (§6.1): `logic-spec.md` §4 + §5, `Repositionable` KDoc, and `Execution.host`'s
   `callerStableId` KDoc (promoted from "purely for trace attribution" to load-bearing addressing).
7. **Gate:** `cd ../kzen-lib && ./gradlew build` green, then `./gradlew publishToMavenLocal` — all
   four subprojects. kzen-auto consumes the variant-suffix coords from mavenLocal, so B cannot start
   until this lands (AGENTS.md § KMP variant-suffix coords).

**Not in scope:** the `LogicRunFrameInfo` call-site field (cut by Q3), and stack-derived descent
(§8, unsized). XC-N touches **no wire type**.

### Session B — kzen-auto (row 31)

1. **Fixtures first** (§9) — three new files, none of which exist: `A → B → C`,
   `Script → Flow → Script`, and a self-hosting `A`. `git add` each by explicit path as written.
2. `ServerLogicController.moveTo` — resolve the client's frame id against `engine.snapshot()`, walk
   `callerStableId` root → frame to build `MoveTarget.callSitePath`, then the four ordered refusals:
   **liveness** (absent *or* `Terminal`), **addressability** (null call-site on any hop),
   **XC-N1** (loop-hosted hop), **capability + validity** (each transit hop `is Repositionable`; the
   *addressed* frame's Logic `is Repositionable` and `canMoveTo(targetId)`). This subsumes the
   root-only gate at `ServerLogicController.kt:730-732`. **Do not touch `ScriptLogic.canMoveTo`** —
   it is correct (§10.2 corollary).
3. No-op guard (`ServerLogicController.kt:705-709`) — move both the position *and* the `Suspended`
   check to the addressed frame's node.
4. `ScriptRunContext.restore` — the **third path** (§6.2.3): `moveTarget == null` +
   `moveDescendCallSite != null` ⇒ plain restore **plus** `descendSteps` = that RunStep + its
   in-frame ancestors. Grow the signature and the `ScriptLogic.kt:81-83` call site.
5. Wire — `LogicHandler.logicMoveTo` reads the already-defined `CommonRestApi.paramExecutionId`.
6. Client — `ScriptExecutionMargin` `canDrag` becomes "a frame exists for the viewed document";
   send that frame's `executionId`; `ClientLogicGlobal.moveToAsync` grows the argument. Update the
   `ScriptExecutionMarginState.draggable` KDoc, which records the "v1" gate being removed.
7. Tests (§9) — all eight nested cases plus the eleven-case `ScriptMoveToTest` regression.
8. `docs/architecture.md` — at most one sentence on call-site-path addressing. **No rewrite**, and
   **nothing about a root-document restriction** (§10.2).
9. **Gate:** `cd ../kzen-auto && ./gradlew build` green. Manual smoke per §9 (drag the arrow in a
   sub-Script opened from a parent's run, both directions).

## 13. As-built — LANDED 2026-07-30 (both sessions)

Gates: **kzen-lib** `./gradlew build` green, `RunEngineTest` **71/71**, published to mavenLocal at
`0.30.0-SNAPSHOT` (matching kzen-auto's `kzenLibVersion` pin). **kzen-auto** `./gradlew build` green,
JVM suite **634 tests, 0 failures** across 109 classes (`ScriptMoveToTest` 11/11 byte-for-byte
unmodified, new `ScriptNestedMoveToTest` 10/10). Manual smoke (§9) **not run — the user's to perform**.

### §4.1 was confirmed by observation before any design work

The characterization test (`ServerLogicControllerLinkedDocumentMigrationTest`
`editingWhileParkedInsideTheSubScriptPopsThePositionOutToTheRunStep`) reproduced the prediction
exactly: after an edit-migrate while parked inside the sub-Script, the root frame's `position` is the
parent's `Call` RunStep and `dependencies` is **empty** — the child is never re-hosted. So G1 was real
and did not shrink. The test asserts position as well as the empty frame list, because a plain step
would also leave `dependencies` empty; only the position discriminates a migrate from a step.

### Two additions to the kzen-lib surface the plan did not foresee

1. **`Repositionable.canDescendThrough(callSite)`** — a second interface member, symmetric with
   `canMoveTo`. §6.2.1 specified the loop-body refusal but not where it lives; putting it in
   `ServerLogicController` would have made a flavour-agnostic controller call `ScriptNestingAnalysis`,
   its first flavour leak, and would have contradicted §5's own rule that the gate is "capability-based,
   **never flavour-named**". Asking each frame about its own structure keeps the driver blind to
   flavours: a Script alone knows a call-site inside a loop body cannot carry a descent. `logic-spec` §4
   and the `Repositionable` KDoc were written against this shape.
2. **A transit-frame `position` write in `RunEngine.host`** — a defect *this feature introduced*, found
   by the new test suite, not predicted anywhere in this document. A transit frame reaches its call-site
   with the boundary suppressed, and `Execution.checkpoint(at)` is the only writer of `Node.position`,
   which starts null on every rebuild. So after a nested jump the hosting document reported **no**
   next-to-run element: no step highlight, and no drag handle, since the handle *is* that marker. Fixed
   by writing `parent.position = callerStableId` when a hosting **claims a descent hop**. Scoping it to
   the claimed hop is load-bearing — an unconditional write in `host` would newly give a Job frame a
   position, which `Node.position`'s own KDoc says it deliberately has none of. Covered by
   `RunEngineTest.transitFrameTakesItsPositionFromTheDescentCallSiteItSuppressed` (mutation-verified:
   deleting the write fails that test and only that test) and by a transit-position assertion on every
   positive `ScriptNestedMoveToTest` case. **This is exactly what §9's manual-smoke line was watching
   for** ("confirm the parent's next-to-run stays on its RunStep") — the automated suite caught it first.

### Smaller deviations

- **`ScriptRunContext.restore`'s `state` parameter became nullable.** A transit frame with no carried
  capture must still seed its descend set; a non-null-only signature would let the descent fail silently
  in exactly the §4.1 way. (In practice every live Script frame does capture, so this is defence, not a
  live path.)
- **`ScriptJumpAnalysis` gained two members, not one.** Public `descendAncestors(...)` (nullable, what a
  transit frame calls) delegating to a private `containerAncestors(path)` that `plan` calls with the path
  it already holds — a single extracted function would have made `plan` walk the tree twice and carry an
  unreachable invalid-return. Plus `isDescendableCallSite(...)`, a thin named entry point so `canDescendThrough`
  does not call something named `isValidTarget` for a question that is not about a target.
- **`ServerLogicController.moveTo` takes `executionId` LAST, defaulted null.** Null addresses the root
  frame, so §9's eleven-case regression holds literally — the existing tests were not touched at all.
- **`LogicHandler` used the existing `RestParams.getParamOrNull`**, not the `getAll(...)?.singleOrNull()`
  idiom; an absent `execution` param means the root frame.
- **Nine fixtures, not three** (§9 counted three *scenarios*; each needs a document pair or triple). The
  loop-hosted rejection needed **no** new fixture — `test/script/engine/script-engine-run-loop-test.yaml`
  already has a RunStep hosting a sub-Script inside a `ForEach` body.
- **Tests went in a new sibling `ScriptNestedMoveToTest`** rather than extending `ScriptMoveToTest`,
  keeping the "empty call-site path ≡ today" regression story unblurred.
- **The Flow transit hop trips the capability gate first**, not addressability: the hop's Logic is asked
  `is Repositionable` before it is asked to carry a call-site. (`FlowRun` also hosts without a
  `callerStableId`, so the path is unaddressable too — either refusal is correct.)

### The recursion case (§9 bullet 8) — narrowed, in both repos

- **kzen-lib.** The plan asked for "the root frame must see null on both surfaces". That is
  **unsatisfiable by construction**: if the addressed frame is nested, the root *is* a transit frame and
  must read `moveDescendCallSite` — reading null on both would mean the descent was never delivered. The
  landed test uses a four-frame self-hosting shape with the frame two hops down addressed, so an
  **off-path** frame sharing the same stable id is the one reading null on both. That is the G2 assertion,
  and it is clean and deterministic.
- **kzen-auto.** The outcome assertion the plan wanted cannot be made. Addressing the deep frame collapses
  the tree to a single frame parked at the root's own first step, because the deep frame wins the
  `migrationCaptured` stable-id collision and the root then rebuilds capture-less — observationally
  identical to the root having wrongly claimed the jump. No assertion separates the two, so none was
  written. What **is** deterministic, and is now covered by
  `deepFrameOfASelfHostingScriptIsAddressable`, is that such a frame is *addressable*: two invocations of
  one document are separately nameable on the wire, and a jump addressed to the deeper one clears all four
  gates (notably `canDescendThrough` on a `SelfCall` RunStep nested in an `If` branch). The test parks the
  deep frame **away** from the target deliberately — parking it at the target returns `Submitted` via
  `moveTo`'s no-op short-circuit and would prove nothing.

### Not done, deliberately

- **Manual smoke (§9)** — ~~the user's to run~~ **RUN 2026-07-30 by the user; it found three defects.**
  See §14. The prediction that it was "worth doing even though the automated suite now guards that one
  case" held: 634 green tests did not stop the flagship sample from silently doing nothing.
- ~~**XC-N2** (loop-hosted hops) — still behind the parked loop-body `LoopCursor` extension.~~
  **SUPERSEDED 2026-07-30 — loop-hosted *transit* shipped; see §14.** The claim that it was "a real
  rejection, not a silent no-op" was **false in the UI**: two client defects swallowed the message
  entirely. And the parking rationale itself was wrong — see §14.1.
- **Stack-derived descent** (§8, unsized) — a plain nested edit-migrate still pops the position out to the
  parent's RunStep. The characterization test records that behaviour, so the day someone builds it, the
  test that must change is already written and named.
- **Invocation-keyed `migrationCaptured`** (§4.2) — out of scope, now documented as genuinely *undefined*
  in `logic-spec` §5 rather than silently relied on.

---

## 14. Post-smoke defect fix — 2026-07-30 (same day)

The user ran the §9 manual smoke on `notation/main/FizzBuzz/FizzBuzz Script Loop.yaml`, stepped into
`FizzBuzz Script Item`, and reported: *"I see the drag/drop indicator, but moving the next-to-run does
nothing. also when I look at FizzBuzz Script Loop it says 'Can't move to this step'."*

Both symptoms were **one** event. Three defects, two of them introduced by XC-N1 itself.

### 14.1 The loop-transit parking rationale was false

`FizzBuzz Script Loop`'s only Script-to-Script call is `main.steps/Loop.steps/Run`, inside a `ForEachStep`
body — so the flagship sample is exactly the shape XC-N1 refused. Worse, the reason it refused did not
survive contact with the code.

§5 of this plan, `kzen-auto/docs/architecture.md`, `kzen-lib/docs/logic-spec.md` §4, and the KDoc on both
`isDescendableCallSite` and kzen-lib's `Repositionable` all justified the refusal with *"the walk cannot be
resumed mid-iteration."* **It already could.** `ForEachStep` re-records its `LoopCursor` carry at every
iteration start; `ScriptRunContext.restore`'s transit branch keeps carries wholesale; the resumed iteration
skips `execution.dropReplay(bodySteps)` so its completed body prefix replay-adopts. There was already a
passing regression test on the identical `ForEach → RunStep → sub-Script` shape —
`ServerLogicControllerLoopMigrationTest.forEachHostedChildResumesAcrossMidChildEdit`, whose class KDoc calls
it "the FizzBuzz Script Loop regression". And `descendAncestors`, which computes the actual descend set,
never had a loop check at all: it would have returned the `ForEachStep` ancestor already.

Two different features had been conflated under one parking notice. Loop-body **targets** genuinely need new
machinery (which iteration do you land in? re-point the cursor at it) and stay parked. Loop-body **transit**
inherited the refusal only because `isDescendableCallSite` delegated wholesale to `plan`, loop clause and
all. `ScriptJumpAnalysis` now splits a private `walkedElement(...)` out of `plan`: both roles share the
structural checks, `isValidTarget` alone keeps the `rerun` clause. **The machinery was loop-ready; only the
gate refused.** Pinned by `ScriptNestedMoveToTest`'s ForEach / DoWhile / nested-loop transit cases (12/12,
was 10) and unit-pinned in `ScriptJumpAnalysisTest` (10/10, was 8).

> **Lesson for §11's list.** That list already recorded four wrong "already exists" claims in this document.
> This is a fifth failure of the same kind, one level up: a *rationale* asserted without checking whether the
> code still agreed. §11 says re-verify every claim about existing code. It should also say re-verify every
> claim about why something is impossible — especially one this plan is about to inherit into four KDocs.

### 14.2 Rejections were invisible (regression introduced by XC-N1)

`ClientLogicGlobal.controlError` stamped every error with `logicStatus.active.frame`'s document — the **root**
frame — and `StageController.renderControlError` renders only when that matches the viewed document. Correct
while only the root could move; XC-N1 made viewed ≠ root and did not follow through. So the refusal fired,
tagged itself with the parent, and rendered nowhere — then appeared later when the user navigated to the
parent. That is the whole of "does nothing" *and* the confusing message on the other document.

Fixed: `controlAsync` takes an explicit `documentPath`; `moveTo` passes the target's, run-wide verbs
(pause/step/stop/continue) keep the run-root attribution the scoping existed to provide.

### 14.3 The drag affordance promised the impossible (introduced by XC-N1)

`ScriptExecutionMargin` gated `canDrag` on "is there a live frame for this document" but computed
`validTargets` from `isValidTarget` against the **viewed** document only — never asking whether the transit
hops could be descended through. Every target painted valid against a guaranteed refusal.

Fixed: `LogicRunFrames.spineForDocument` + `ScriptExecutionMargin.spineRefusal` evaluate the whole spine at
pointer-down. This was answerable **only because of the `RunEngine.host` transit-position write** added in
§13 — the wire `LogicRunFrameInfo` carries no `callerStableId`, so `position` is the call-site proxy, and it
is sound precisely because that write re-establishes it on a claimed descent hop. A defect fix from the
first pass paid for a feature in the second.

### 14.4 Refusals now say why

The reason existed all along and was discarded: `ScriptJumpPlan.invalidReason` never left the server, because
`canMoveTo`/`canDescendThrough` return a bare `Boolean` and `/logic/moveTo` responded with the enum name.

- `LogicControlReply` (kzen-auto-common) — `(response, reason?)`, wire-identical when there is no reason;
  only `moveTo` emits one. **kzen-lib untouched, so no republish.**
- `RepositionDiagnostic` (kzen-auto-jvm) — reasons asked for **by capability, not concrete type**, so a
  non-`Repositionable` Flow/Job hop gets an honest sentence naming its document instead of a fabricated cause.
- `MoveToRefusal` (kzen-auto-common) — one source of wording for both sides, so a client-caught and a
  server-caught refusal read identically.
- `ScriptJumpRefusal` (kzen-auto-common) — classifies from the two public predicates, never by matching
  `invalidReason` prose. Written as a **sibling file**: `ScriptJumpAnalysis.kt` was another agent's concurrently.

In-document refusals speak too, on drop and never on hover. Dropping on `Run` inside `Loop` now reads:
*"That step is inside Loop, which can't be sent to a different iteration. Move to Loop itself to restart it."*
Scoped in deliberately: the top level of `FizzBuzz Script Loop` is only `Loop`/`Display`/`ForEach`/`Display 2`,
so **every** step a user would plausibly aim at lives inside a `rerun` branch — the silent-grey path would
have been the very next click.

### 14.5 Residual hazard — traced, not guarded

An edit sharing the barrier with a jump could delete-and-recreate the loop at the same object path, leaving a
`descendSteps` claim armed while the loop restarts at iteration 0. Traced to **inert**, not dangerous: a plain
delete is refused at the gate (the call site is absent from the recompiled tree); the delete-and-recreate case
has iteration 0 call `dropReplay` *before* the body runs, which `discardCaptured`s the child's capture, so the
re-hosted child reads `restored == null` and `moveDescendCallSite == null` and `ScriptLogic.run` never calls
`restore` — the jump is silently dropped per the logic-spec §4 ignore-contract. Net effect: parks one level
deeper. Recorded as a code note at `seedDescendThrough` rather than a speculative guard.

### Still not done

- **XC-N2 loop-body TARGETS** — genuinely parked, unchanged. `canMoveTo` still refuses; jump to the loop
  step instead and it restarts at iteration 0.
- **Flow/Job transit hops** — permanently refused until another flavour implements `Repositionable`
  (`FlowRun` also hosts without a `callerStableId`, so its hops are unaddressable regardless). Now says so.
- **Re-smoke** — the user's to run: `FizzBuzz Script Loop` → step into `FizzBuzz Script Item` → drag, both
  directions. Requires a **dev-server restart**; the running instance predates all of this.
