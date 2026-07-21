# FL4 — Flow client: render performance, error visibility, display hygiene — implementation plan

> **Status: ✅ DONE 2026-07-21.** Landed as planned, after FL3 — the predicted `FlowRun` overlap was
> a purely textual rebase (the two `recoverable` blocks and `snapshotVisual` survived FL3's
> capability-interface rewrite verbatim), and `VertexController.renderAttributes` still filters
> `row`/`column` as expected. Both scope corrections (§ Q2/Q3) were confirmed necessary, and Q1's
> verdict held exactly: E5/TP4 had already delivered the bulk of the refetch fix, leaving only the
> involvement gate. Three deviations, all mechanical: (1) the flaky fixture uses `@Reflect` + the JVM
> reflective mirror (R1 having landed), so steps 3b/3c collapse to one class and no
> `FlowVertexTestModule` / `register()` call; (2) `FlowOutput` names its component `result:`, not
> `parameter:` — the fixture in step 3d says otherwise; (3) the clear-on-success of steps 2b/2c is a
> shared `FlowRun.clearStaleError` helper called from both vertex paths rather than duplicated
> inline, which also lets the logic-host path force its trace instead of relying on resume timing.
> The as-built note lives in the constituent plan. Manual browser smoke (§ Verification 3) is debt.
>
> Generated 2026-07-19 from `2026-07-16_flow-improvements.md`
> Phase 4 (decisions pre-made there — compute-once routing, consumed-subset state, Error phase
> rendered with strip + tooltip, involvement-scoped refetch, display hygiene; do not re-litigate).
> All anchors verified against current code 2026-07-19, post SER2–SER5 / Y / G5 / G7 / TP1 / TP3 /
> TP4. Anchor drift is minimal (one moved line range, one off-by-one — see Current-state findings).
> **Two evidence-driven scope corrections** (both required to meet the phase's own verification):
> the routing snapshot in `FlowRun` carries `error` despite its documented contract, and
> `ActiveVertexModel.error` is never cleared — so this phase includes two small kzen-auto-jvm
> `FlowRun` edits beyond the constituent plan's "js + one common enum fix" framing (§ Pre-resolved
> Q2/Q3). kzen-auto only, no kzen-lib change, no publishToMavenLocal round-trip. One session.

## Scope & goal

Four deliverables (constituent plan Phase 4, verbatim intent):

1. **Compute-once routing** — the grid stops re-deriving `FlowMatrix` + `FlowDag` per cell per
   render. `FlowController` computes `nextToRun` + `runningVertex` once per render and threads
   them as props; the `FlowUtils.next(documentPath, graphStructure, …)` convenience overload is
   deleted so the O(V²) path can't return.
2. **Consumed-subset state** — `FlowController` stops storing the whole fresh-reference
   `ClientState`; logic-status publishes with no Flow-relevant change no longer re-render the
   grid at all. Rides along: `CellController`'s vestigial `ExecutionIntentGlobal` subscription is
   removed (every intent publish currently re-renders every cell for nothing).
3. **Error becomes a real phase** — `VisualVertexModel.phase()` returns
   `VisualVertexPhase.Error` when `error != null` (precedence running > error >
   pending/remaining/done); the dead red branch in `VertexController` comes alive (hoisted above
   `isNextToRun` so it actually wins); a compact red strip under the header shows the error text
   with the full text on tooltip. Server-side, `FlowRun` is aligned so this is display-only:
   the routing snapshot stops carrying `error`, and a successful (re-)run clears it.
4. **Refetch scoping + display hygiene** — the visual-model refetch key becomes
   involvement-aware (an unrelated run triggers ≤ 2 refetches instead of ~1/s for its whole
   duration); inline message/state text is truncated to a single line with full text behind the
   tooltip; `defaultIcon` stops depending on the legacy MUI alias table.

Modules: kzen-auto-js (bulk), kzen-auto-common (`VisualVertexModel.phase()` fix + `FlowUtils`
guard/deletion + commonTest), kzen-auto-jvm (`FlowRun` two-line-scale edits + jvm test fixtures).

## Dependencies & coordination

- **Depends on FL1 only (met).** FL4 does NOT depend on FL3; they can land in either order
  (constituent plan § Sizing).
- **FL3 is being planned/executed in parallel — same-file overlap, whichever lands second
  rebases:**
  - `FlowRun.kt` — FL3 retargets the concrete-class dispatch (`is RunLogicVertex` :162,
    `is FlowInputVertex` :259, `is FlowOutputVertex` :180/:267), rewrites `runChildVertex`'s
    binding (:204-211), moves message inspection to the vertex, and deletes
    `FlowMessageInspector` (used by `traceVertex` at :525/:531). FL4 edits the *error-handling
    seams* of the same file: the two `execution.recoverable` blocks (:171-178, :215-220) gain a
    clear-on-success, and `snapshotVisual` (:489) stops passing `error`. Different lines, same
    neighborhoods — a textual rebase, no semantic conflict. If FL3 lands first, FL4's edits
    apply to the capability-interface version unchanged.
  - `VertexController.kt` — FL3's minimal `arguments:` editing client bit may touch
    `renderAttributes` / the attribute area; FL4 touches the props interface, `renderVertex`'s
    color chain, `renderContent`, and the egress/state renderers. Again disjoint regions;
    whichever lands second re-verifies `renderAttributes` still filters `row`/`column`
    (:494-501) and rebases mechanically.
- **S8 client sweep** (`2026-07-16_script-client-sweep.md`) defines the render-scoping
  conventions; they are already written up in `kzen-auto/docs/js-architecture.md` §2 — FL4
  applies them, no waiting on S8.
- **File safety:** `notation/main/FizzBuzz/FizzBuzz Flow Loop.yaml` (and `Flow Item.yaml`) are
  protected user documents — the smoke opens and runs them but **never edits them**; the
  error-injection smoke uses a scratch Flow document created through the UI.
- **Git hygiene:** stage every new file by explicit path as soon as written (new test files,
  fixture yaml); never commit.

## Current-state findings (anchors verified 2026-07-19)

### Anchor verification vs the constituent plan

| Plan anchor | Verified location today | Drift |
|---|---|---|
| `VertexController.kt:286-289` per-cell `FlowUtils.next` | `VertexController.kt:286-289` | none |
| `VertexController.kt:321-322` dead red branch | `:321-322` (`VisualVertexPhase.Error -> NamedColor.red`) | none |
| `VertexController.kt:786` raw message text | `:786` (`+"${vertexMessage.get()}"`) | none |
| `VertexController.kt:889` raw state text | `:889` (`+"${vertexState.get()}"`) | none |
| `VertexController.kt:81` `defaultIcon = "SettingsInputComponent"` | `:81` | none |
| `EdgeController.kt:112-118` per-edge `FlowUtils.next` | `:112-118` (`nextToRun()`) | none |
| `FlowController.kt:170-176` whole-`ClientState` state | `:170-176` (`onClientState` → `setState { clientState }`) | none |
| `FlowController.kt:358-363` matrix+dag built once | **moved/split**: matrix at `renderGraph` :318-321, dag at `nonEmptyDag` :417-422 | cosmetic |
| `FlowUtils.kt:20-30` convenience overload | `FlowUtils.kt:21-31` | off-by-one |
| `FlowProgressStore.kt:43` `frameForDocument` | `:43` | none |

`FlowUtils.next(host, graphStructure, visualFlowModel)` has exactly **two production callers**
(VertexController:286, EdgeController:114); the only other references are the
`(matrix, dag, model)` overload — `FlowRun.kt:121/:133` and `FlowUtilsNextTest.kt:29`. Deletion
is safe.

### How refetch is keyed today (the phase's explicit re-verify item)

`FlowController.refreshVisualModelIfNeeded` (FlowController.kt:179-212) keys on
`"${documentPath}|${clientLogicState.traceVersion()}"` (:193-194). Post-E5/TP4,
`traceVersion()` = `s${structureVersion}|${active.sequence}` (ClientLogicState.kt:82-90) —
**already** version-gated, so an idle or paused run stops refetching entirely, and statuses
arrive through `ClientLogicGlobal.publishStatus`'s 1 s throttle (immediate on structure change;
`statusPublishThrottleMillis = 1_000`, ClientLogicGlobal.kt:48). The "refetch on every 1.5 s
poll forever" of the original finding is **gone** — this is the graph-plan-5b precedent, mostly
already landed by E5/TP4.

**The residual gap is real but narrow**: `traceVersion()` is global to the (single) active run,
not to this document. While ANY run executes — a Script in another tab — its `sequence` bumps
per emit and its `structureVersion` per step boundary, so every visible Flow tab's fetch key
changes on every throttled publish (~1/s) and `fetchVisualModel` fires its **not-involved
fallback** (`mostRecent` + `lookupRun`, FlowProgressStore.kt:46-55) = ~2 detached REST calls
per second per Flow tab, for the entire unrelated run, fetching the same settled snapshot every
time. `LogicRunFrames.frameForDocument` (LogicRunFrames.kt:44-64) already answers involvement
and is already used inside `fetchVisualModel` (FlowProgressStore.kt:43) — just not in the key.
The fix is the three-mode key of step 7; `FlowProgressStore` itself needs **no change**.

### Error phase — two latent server-side facts the constituent plan's claim misses

1. **The routing snapshot carries `error` despite its documented contract.**
   `FlowRun.snapshotVisual`'s KDoc says it "reads only message-presence, hasNext, epoch and
   running" (FlowRun.kt:470-473) — but the constructed model passes `model.error`
   (FlowRun.kt:489). Today that's inert (`phase()` never reads `error`); the moment `phase()`
   does, `FlowUtils.nextInLayer`'s phase check (FlowUtils.kt:178-182) would skip errored
   vertices **server-side** too. The reachable regression: live-edit during an error park
   migrates the run (`FlowMigrationState` carries `activeVertices` including `error`,
   FlowRun.kt:96-102); the rebuilt run's loop calls `FlowUtils.next` with the carried error
   still set, and in a multi-vertex layer would skip the errored vertex forever — the flow
   stalls instead of re-running it. Fix: pass `error = null` in `snapshotVisual`, aligning the
   code with its own contract. Server routing is then **provably unaffected** by the phase
   change.
2. **`ActiveVertexModel.error` is never cleared.** Grep confirms exactly two writers — both
   set it on failure (FlowRun.kt:172, :216) — and no `error = null` anywhere. After a
   pause-on-error park, resume re-enters the `recoverable` block and re-runs the vertex; on
   success the stale error would keep being emitted by `traceVertex` (:544) and the card would
   stay red forever. The constituent plan's own verification ("fix + resume clears it")
   **requires** a clear-on-success, which does not exist today. Fix in step 2.
3. **`nextInLayer`'s single-vertex shortcut bypasses the phase check.**
   `FlowUtils.nextInLayer` returns `layer.first()` unconditionally for a 1-vertex layer
   (FlowUtils.kt:167-169) — pinned by
   `FlowUtilsNextTest.inProgressSingleVertexLayerSelectedWithoutInputCheck` (the shortcut must
   NOT gate on `inputsReady`; a mid-stream vertex re-executes without fresh inputs). So the
   plan's claim "an errored vertex stops being selected client-side" holds only for
   multi-vertex layers unless the shortcut gets a minimal Error-only guard (step 1). Without
   the guard, in the very common single-vertex-layer shape the errored vertex would still be
   `nextToRun` and — worse — the current cardColor when-chain tests `isNextToRun` *before* the
   phase fallback (VertexController.kt:298-329), so the card would render gold-light, not red.
   Both fixed: guard the shortcut (client-visible only, server-inert after finding 1's fix) and
   hoist the Error branch above `isNextToRun` (step 8).

### Render path today (what consumed-subset + compute-once actually buy)

- `FlowController` stores the whole `ClientState` (:71-76, :170-176). Every
  `ClientStateGlobal` publish — including every throttled logic-status publish during ANY run,
  every breakpoint/slow-loop/pending transition — is a fresh `ClientState` reference, so
  `RPureComponent`'s shallow-equal never bails and the entire grid re-renders. Within that
  re-render, **every** `VertexController` calls the notation-rebuilding `FlowUtils.next`
  overload (:286-289) and every `EdgeController` does the same (:112-118) — each call is a full
  `FlowMatrix.ofDocument` + `FlowDag.of` from notation: O(V²)-scale work per grid paint.
- Reference stability is favorable: `ClientStateGlobal` replaces `graphDefinitionAttempt` only
  on notation events (ClientStateGlobal.kt:76-87) and `navigationRoute` only on navigation
  (:54-66); a logic-only publish reuses both references (:122-126). So storing
  `graphStructure` + `documentPath` gives a shallow-equal that correctly bails on logic-only
  publishes and correctly fires on notation/navigation changes.
- Attribute edits are debounced (lodash 1000 ms + flush-on-blur,
  AttributePathValueEditor.kt:133-137, TextAttributeEditor.kt:64) — so the constituent plan's
  "every keystroke triggers O(V²)" is really "every committed edit"; per-keystroke typing only
  re-renders the editor itself. The win at commit time is the per-cell O(V²) derivation → one
  O(V) derivation; the grid still repaints once (cards legitimately render notation).
- `CellController` implements `ExecutionIntentGlobal.Observer` and `setState`s `intentToRun` on
  every intent publish (CellController.kt:57-58, :90-105) — but its `render()` reads **none** of
  its state fields (:115-146). Every intent publish re-renders every cell for nothing.
  `VertexController` has its own, genuinely-used subscription (:111-126). Pure removal.
- `EdgeControllerProps.graphStructure` (:45) has exactly one use — the deleted overload call —
  and can be dropped entirely.

### Display hygiene facts

- `defaultIcon = "SettingsInputComponent"` (VertexController.kt:81) currently renders only via
  `IconNames.legacyMaterialAlias["SettingsInputComponent"] → "settings-input-component"`
  (IconNames.kt:105). The fix `"material-symbols:settings-input-component"` is glyph-identical
  (qualified names pass through `IconNames.resolve` unchanged, IconNames.kt:24) — pure hygiene,
  zero visual change.
- Message text renders into a `width = 0` absolutely-positioned div (:773-787) that overflows
  rightward unbounded; state text into a normal padded block (:873-892). FL2 bounded only the
  *fallback* trace rendering at ≤1024 chars — a successful `inspectState`/`inspectMessage` can
  still return arbitrarily large text. `TextOverflow.ellipsis` has precedent in this codebase
  (TextAttributeView.kt:97 et al.).

## Pre-resolved questions

**Q1 — Refetch scoping: what's left post-E5/TP4?** *Answer: the per-document involvement gate,
and only that.* E5/TP4 already deliver "no refetch while nothing changed" (idle/parked runs are
free) and the 1 s publish throttle. What remains is that an **unrelated** active run still
drives ~2 REST calls/s per visible Flow tab for its whole duration (evidence above). Implement
the three-mode fetch key (step 7): involved → per-emit `traceVersion()` (today's behavior,
unchanged where it matters); unrelated active run → key on run id only (exactly one refetch at
run start — needed because starting a run implicitly clears the prior retained trace, so the
display must repaint, likely to empty); no active run → key on `structureVersion()` (one
refetch on settle; preserves the "Clear all traces" repaint, which moves `structureVersion`
even with no active run). `FlowProgressStore` is untouched. Record in the as-built note that
most of the original finding was already fixed by E5/TP4 (the anticipated graph-plan-5b
situation) and only the involvement gate was added.

**Q2 — Is the `phase()` fix safe for server routing?** *Yes, after one alignment edit.* The
run loop consumes `FlowUtils.next` via `snapshotVisual`, which — contra its own KDoc — passes
`model.error` through (FlowRun.kt:489). Passing `null` instead makes the Error phase
unreachable server-side, so routing behavior is byte-identical before/after the common change
(including the migrate-during-error-park path, where the carried error would otherwise stall a
multi-vertex layer — finding 3 above). Display is unaffected: `traceVertex` (the client-visible
emit) still carries `model.error` (:544), and migration capture carries `activeVertices`
directly, not `snapshotVisual`.

**Q3 — How does "fix + resume clears it" work?** *Clear `error` on successful completion of
each `recoverable` block, with a forced trace.* Today nothing ever clears it (finding 2). On
resume the engine re-runs the recoverable block in place ("parks the vertex Suspended(Error)
for fix + resume and re-runs it on resume", FlowRun.kt:168-170); when the block finally returns
normally, a still-set `error` is by construction stale → null it and force the follow-up trace
(mirrors FL2's "error and run-end traces forced" rule; also covers the migrated-run path where
the re-run happens in a fresh engine without a preceding park in that engine). Same for
`runChildVertex`'s recoverable. This is the smallest change that makes the red card subside
exactly when the vertex succeeds again; pause-on-error OFF keeps today's behavior (failure
propagates, run fails, error stays visible for post-run inspection — desired).

**Q4 — Single-vertex-layer shortcut: guard it or not?** *Guard it, Error-only.* Rationale in
finding 3. The guard must NOT touch `inputsReady` or other phases (the shortcut's
no-input-gating behavior is load-bearing and pinned by
`inProgressSingleVertexLayerSelectedWithoutInputCheck`). Server-inert per Q2. Both layer shapes
get a structure-suite case.

**Q5 — Error card color.** The dead branch's `NamedColor.red` becomes reachable, hoisted above
`isNextToRun`. Recommended refinement (cosmetic, not a re-litigation — "red card + strip +
tooltip" stands): use a light error tint `Color("#ffcdd2")` for the card background so the
black-text attribute editors stay legible, with the strip carrying the saturated red
(`NamedColor.firebrick` background, white text). If the implementer prefers strict adherence,
keeping `NamedColor.red` for the card is acceptable; the strip + tooltip are the
non-negotiables.

**Q6 — Truncation mechanics.** Message text (absolute-positioned `width = 0` div): hard char
truncation — `truncate(text, 20)` with `"…"` suffix — keeps the odd overflow layout intact
while bounding it to roughly half a card width; `title` gets the full text capped at 1000
chars. State box (normal block): CSS single-line ellipsis (`whiteSpace = WhiteSpace.nowrap`,
`overflow = Overflow.hidden`, `textOverflow = TextOverflow.ellipsis`) plus a defensive
1000-char DOM cap, `title` same cap. One private `truncate(text: String, max: Int)` helper in
`VertexController`. Exact numbers are implementer-tunable; single-line is the contract.

**Q7 — Icon name.** `"material-symbols:settings-input-component"` — glyph-identical today via
the alias table, so zero visual change and one less legacy-alias dependency.

**Q8 — Does `nextToRun` prop threading change semantics anywhere?** No. `VertexController`
today uses the *pure* `FlowUtils.next` result (no `running()` fallback, :286-289);
`EdgeController` uses `visualFlowModel.running() ?: FlowUtils.next(...)` (:112-118). Preserve
exactly: thread both `nextToRun` (pure) and `runningVertex` (`visualFlowModel.running()`) as
props; `VertexController` consumes `props.nextToRun` alone, `EdgeController` computes
`props.runningVertex ?: props.nextToRun`. `FlowMatrix.ofDocument` ≡
`verticesNotation`/`edgesNotation` + `cellDescriptorLayers` (FlowMatrix.kt:31-43), which is
exactly what `renderGraph` already builds — same matrix, same result.

## Step-by-step implementation

Order: common → jvm → jvm tests → js. Each step compiles independently.

### 1. common — Error phase + routing guard (`kzen-auto-common`)

**1a.** `VisualVertexModel.phase()`
(`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/flow/model/exec/VisualVertexModel.kt:91-106`):
remove the `// TODO: add support for Error` and insert error precedence after `running`:

```kotlin
fun phase(): VisualVertexPhase {
    return when {
        running ->
            VisualVertexPhase.Running

        error != null ->
            VisualVertexPhase.Error

        epoch == 0 ->
            VisualVertexPhase.Pending

        hasNext ->
            VisualVertexPhase.Remaining

        else ->
            VisualVertexPhase.Done
    }
}
```

**1b.** `FlowUtils.nextInLayer` single-vertex guard
(`kzen-auto-common/.../paradigm/flow/util/FlowUtils.kt:164-169`): replace the
`layer.size == 1` branch body:

```kotlin
else if (layer.size == 1) {
    // Error-only guard: an errored (parked) vertex must not display as next-to-run. Deliberately
    // no inputsReady / other-phase gating here — a mid-stream vertex re-executes without fresh
    // inputs (see inProgressSingleVertexLayerSelectedWithoutInputCheck). Server routing never
    // sees the Error phase (FlowRun.snapshotVisual passes error = null), so this is client-only.
    val only = layer.first()
    val phase = (visualFlowModel.vertices[only] ?: VisualVertexModel.empty).phase()
    return if (phase == VisualVertexPhase.Error) null else only
}
```

**1c.** Delete the convenience overload `FlowUtils.next(host, graphStructure, visualFlowModel)`
(FlowUtils.kt:21-31) and its now-unused imports (`DocumentPath`, `GraphStructure`). Do this in
the same commit as step 4 (its two callers) so the tree always compiles; listed here because
the file is common.

### 2. jvm — `FlowRun` alignment (`kzen-auto-jvm/.../server/exec/flow/FlowRun.kt`)

**2a.** `snapshotVisual` (:483-490): pass `null` for the error component, and note it:

```kotlin
VisualVertexModel(
    false,
    null,
    if (model.message != null) NullExecutionValue else null,
    model.hasNext(),
    model.epoch,
    // Deliberately NOT model.error: routing must never see the Error phase — an errored vertex
    // stays selectable (a migrated-in carried error would otherwise stall the layer; the
    // recoverable re-run is the fix path). The KDoc contract above ("reads only
    // message-presence, hasNext, epoch and running") is now enforced, not just documented.
    null)
```

Update the KDoc (:470-473) to mention error exclusion explicitly.

**2b.** Clear-on-success in `run()` (:171-178). Replace:

```kotlin
execution.recoverable({ t ->
    activeVertices[nextStableId]?.error = ExceptionUtils.message(t)
    traceVertex(nextStableId, instance, running = false, force = true)
}) {
    runOneVertex(next, nextStableId, instance, matrix)
}

traceVertex(nextStableId, instance, running = false, force = pausedOrStepping)
```

with:

```kotlin
execution.recoverable({ t ->
    activeVertices[nextStableId]?.error = ExceptionUtils.message(t)
    traceVertex(nextStableId, instance, running = false, force = true)
}) {
    runOneVertex(next, nextStableId, instance, matrix)
}

// The recoverable block returned normally: any still-set error is stale (a pause-on-error park
// that was fixed + resumed, or an error carried across live-edit migration) — clear it and
// force the trace so the client's red card subsides even under throttling.
val clearedError = activeVertices[nextStableId]?.error != null
if (clearedError) {
    activeVertices[nextStableId]?.error = null
}

traceVertex(nextStableId, instance, running = false, force = pausedOrStepping || clearedError)
```

**2c.** Same in `runChildVertex` (:215-224): after the `recoverable` returns, before
`activeVertexModel.message = …`:

```kotlin
if (activeVertexModel.error != null) {
    activeVertexModel.error = null
}
```

(The trailing `traceVertex` for this branch at :164 keeps `force = pausedOrStepping`; a resume
happens on human timescales so the ≥100 ms per-vertex window has always elapsed since the
forced error trace, and a migrated fresh engine has an empty `lastTraceNanos` — the cleared
trace always lands.)

### 3. jvm tests (`kzen-auto-jvm/src/test`)

**3a.** Extend `FlowNotationTest.vertexErrorPausesWhenPauseOnError`
(`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/flow/FlowNotationTest.kt:82-99`):
after the `PauseReason.Error` assertion, pin that the client-visible trace carries the error
(what feeds the red card):

```kotlin
val traced = assertNotNull(tracedVertex(engine, "test/flow-error-test.yaml", "FerrDivide"))
assertNotNull(traced.error)
```

**3b.** New transient-failure vertex `FlakyProcessorVertex` at
`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/flow/test/FlakyProcessorVertex.kt`
(beside `CountingSinkVertex`; no `@Reflect` — the test source set has no KSP pass): a
`StatelessFlowVertex` with `RequiredInput<Any>` + `OptionalOutput<Any>` (mirror
`ReplaceProcessor`'s channel shape, ReplaceProcessor.kt:10-21) and `FlakyStep`'s fail-once
static `AtomicInteger` + `reset()` (FlakyStep.kt:29-35): first `process()` globally throws
`IllegalStateException("flaky failure")`, thereafter `output.set(input.get())`.

**3c.** Register it in `FlowVertexTestModule`
(`.../server/exec/flow/test/FlowVertexTestModule.kt`): second `reflectionRegistry.put` entry,
`listOf("input", "output")`, mirroring the `CountingSinkVertex` entry's factory shape.

**3d.** New fixture `kzen-auto-jvm/src/test/resources/notation/test/flow-flaky-test.yaml`,
mirroring `flow-migration-test.yaml`'s test-archetype pattern (archetype `abstract: true`,
`is: FlowVertex`, `class:`, `meta.input: {is: RequiredInput, by: FlowWiring}`,
`meta.output: {is: OptionalOutput, by: FlowWiring}`) and `flow-error-test.yaml`'s document
shape: `FlowInput(parameter: x)` @ (0,0) → `FlakyProcessorVertex` @ (1,0) →
`FlowOutput(parameter: out)` @ (2,0), `edges: []` (vertical adjacency wires them). Lazy
instantiation means the unregistered class cannot break other tests that read the shared test
notation (precedent: `flow-migration-test.yaml`'s `CountingSinkVertex`).

**3e.** New test `FlowNotationTest.errorClearsOnResumeAfterTransientFailure`:

```kotlin
FlowVertexTestModule.register()          // idempotent — mirrors FlowMigrationTest:60
FlakyProcessorVertex.reset()
val engine = engineFor("test/flow-flaky-test.yaml", argument("x", 5))
try {
    engine.pauseOnError(true)
    engine.resume()
    engine.awaitQuiescent()

    // Parked at the flaky vertex, error traced (the red card's data)
    assertEquals(PauseReason.Error,
        assertIs<NodeStatus.Suspended>(engine.snapshot().root.status).reason)
    assertNotNull(assertNotNull(
        tracedVertex(engine, "test/flow-flaky-test.yaml", "<FlakyName>")).error)

    // Resume re-runs the recoverable block; success clears the error and completes the flow
    val outcome = runBlocking {
        engine.resume()
        engine.await()
    }
    assertEquals(5, assertIs<Outcome.Success>(outcome).value.find(TupleComponentName("out")))
    assertNull(assertNotNull(
        tracedVertex(engine, "test/flow-flaky-test.yaml", "<FlakyName>")).error)
}
finally {
    engine.close()
}
```

(`<FlakyName>` = the fixture's vertex object name, e.g. `FflkFlaky`. Follow the file's existing
resume/await idioms exactly — `vertexErrorPausesWhenPauseOnError` for the park half,
`arbitraryDomainObjectMessageDoesNotKillRun` for the runBlocking half.)

### 4. js — compute-once routing

**4a.** `FlowController.nonEmptyDag`
(`kzen-auto-js/.../objects/document/flow/FlowController.kt:417-422`): after
`val flowDag = FlowDag.of(flowMatrix)` add:

```kotlin
// Routing derived ONCE per render and threaded down — never recomputed per cell (each per-cell
// FlowUtils.next used to rebuild FlowMatrix + FlowDag from notation: O(V²) per grid paint).
val nextToRun = FlowUtils.next(flowMatrix, flowDag, visualFlowModel)
val runningVertex = visualFlowModel.running()
```

and pass both through `cell(…)` (:535-559) into `CellController` props.

**4b.** `CellControllerProps` (CellController.kt:28-41): add
`var nextToRun: ObjectLocation?` and `var runningVertex: ObjectLocation?`; forward both to
`VertexController` (:117-130) and `EdgeController` (:133-144).

**4c.** `VertexControllerProps` (VertexController.kt:46-60): add the same two;
`renderVertex` replaces the `FlowUtils.next(props.documentPath, props.clientState.graphStructure(), props.visualFlowModel)`
call (:286-289) with `val nextToRun = props.nextToRun` (pure value — no `running()` fallback,
per Q8; `runningVertex` is accepted for prop-shape uniformity even though the vertex color
chain reads phase directly).

**4d.** `EdgeController` (EdgeController.kt:112-118): `nextToRun()` body becomes
`props.runningVertex ?: props.nextToRun`; delete the `graphStructure` prop (:45) — its only
consumer was the deleted call — and the `FlowUtils` + `GraphStructure` imports.

**4e.** Delete the `FlowUtils` convenience overload (step 1c). Full-text search for
`FlowUtils.next(` afterward must show only `FlowRun`, `FlowUtilsNextTest`, and
`FlowController.nonEmptyDag`.

### 5. js — consumed-subset state in `FlowController`

Replace `FlowControllerState` (:71-76):

```kotlin
external interface FlowControllerState: State {
    var graphStructure: GraphStructure?
    var documentPath: DocumentPath?
    var creating: Boolean
    var visualFlowModel: VisualFlowModel?
}
```

`onClientState` (:170-176):

```kotlin
override fun onClientState(clientState: ClientState) {
    // Consumed subset only (js-architecture §2): graphStructure is reference-stable across
    // logic-status publishes (ClientStateGlobal replaces graphDefinitionAttempt only on notation
    // events) and navigationRoute across everything but navigation — so RPureComponent's
    // shallow-equal bails on the ~1/s status publishes of any active run.
    setState {
        graphStructure = clientState.graphStructure()
        documentPath = clientState.navigationRoute.documentPath
    }

    refreshVisualModelIfNeeded(clientState)
}
```

Mechanical rewrites of the other `state.clientState` readers:
- `documentNotation()` (:231-241) → `state.graphStructure` + `state.documentPath`.
- `onCreate` (:245-303) → `state.graphStructure!!.graphNotation`, containing location from
  `state.documentPath!!`.
- `renderGraph` (:315-358) → `state.graphStructure!!` for `cellDescriptorLayers`.
- `renderStructureFindings` (:367-380) → `state.documentPath` / `state.graphStructure`.
- `nonEmptyDag` / `cell` (:417-486, :535-559): drop the `clientState` parameter; pass
  `graphStructure` to `CellController` (see 5a below) and `documentPath = state.documentPath!!`.

**5a.** `CellControllerProps` / `VertexControllerProps`: replace `var clientState: ClientState`
with `var graphStructure: GraphStructure`. In `VertexController`, replace all nine
`props.clientState.graphStructure()` reads (:281, :331, :492, :498, :551, :557, :672, :816,
:822) with `props.graphStructure`. `EdgeController` already lost its copy in 4d.

**5b.** Value-equal guard on the refetch result (js-architecture §2 point 3 — `VisualFlowModel`
is a fresh allocation per fetch but a data class, so `==` is cheap and meaningful): in
`refreshVisualModelIfNeeded`'s async block, skip the `setState` when
`visualFlowModel == state.visualFlowModel`.

### 6. js — `CellController` vestigial-observer removal

CellController.kt: delete the `ExecutionIntentGlobal.Observer` supertype (:57-58),
`componentDidMount`/`componentWillUnmount` (:90-97), `onExecutionIntent` (:101-105), the
`CellControllerState` fields + `init` (:44-50, :77-86 — render reads none of them), and the
now-unused `setState`/`ObjectLocation` imports. Use bare `react.State` as the state type param
(precedent: `TopIngress`, TopIngress.kt:26). Keep the `executionIntentGlobal` prop — it is
forwarded to `VertexController`, whose own subscription (:111-126) is the real consumer.

### 7. js — involvement-scoped refetch key

`FlowController.refreshVisualModelIfNeeded` (:179-212): replace the fetch-key computation
(:190-194) with:

```kotlin
// Three-mode fetch key (see plan FL4 / as-built): E5/TP4 already stopped idle re-fetching;
// what this adds is DOCUMENT INVOLVEMENT — an unrelated run must not drive per-publish
// refetches of this document's settled snapshot.
val clientLogicState = clientState.clientLogicState
val activeRun = clientLogicState.logicStatus?.active
val involved = LogicRunFrames.frameForDocument(activeRun?.frame, documentPath) != null

val fetchKey = when {
    // This document is live in the run (own run, or hosted as a child): per-emit refresh —
    // traceVersion() moves exactly when a new trace value can exist.
    involved ->
        "${documentPath.asString()}|involved|${clientLogicState.traceVersion()}"

    // Some OTHER document's run is active: exactly one refetch at run start (starting a run
    // implicitly clears the prior retained trace, so this repaints — likely to empty), then
    // nothing until the run settles or this document joins the frame tree (key mode switches).
    activeRun != null ->
        "${documentPath.asString()}|other|${activeRun.id.value}"

    // No active run: structureVersion moves on run settle and on "Clear all traces" (even with
    // no run — the epoch fold-in), so post-run final state and clear-to-empty both repaint.
    else ->
        "${documentPath.asString()}|idle|${clientLogicState.structureVersion()}"
}
```

Import `tech.kzen.auto.client.service.logic.LogicRunFrames`. `FlowProgressStore` is unchanged
(it already resolves the frame itself, FlowProgressStore.kt:43). Transition audit (all
verified against `ClientLogicState.kt:82-109` semantics): idle→own-run start (involved,
per-emit), idle→other-run start (one fetch, sees cleared trace), other-run stepping (no
fetches), other-run hosts this Flow mid-run (mode switch other→involved re-keys → per-emit
while hosted, reverts after), other-run settles (idle mode, structureVersion advanced → one
fetch of own most-recent), clear-all-traces while idle (structureVersion bumps → repaint
empty), navigation (documentPath prefix changes).

### 8. js — error visibility

**8a.** `VertexController.renderVertex` cardColor chain (:298-329): hoist Error above
`isNextToRun`:

```kotlin
val cardColor = when {
    phase == VisualVertexPhase.Running ->
        NamedColor.gold

    // Error must outrank next-to-run highlighting: keep the precedence explicit regardless of
    // whether routing still selects the errored vertex in any layer shape.
    phase == VisualVertexPhase.Error ->
        errorCardColor

    isNextToRun ->
        EdgeController.goldLight50
    // ... rest unchanged; the inner when(phase) keeps its (now unreachable) Error branch for
    // exhaustiveness, returning errorCardColor.
}
```

with `private val errorCardColor = Color("#ffcdd2")` in the companion (per Q5).

**8b.** Error strip: in `renderContent` (:468-485), between `renderHeader(phase)` and
`renderAttributes()`:

```kotlin
visualVertexModel()?.error?.let { renderError(it) }
```

```kotlin
private fun ChildrenBuilder.renderError(error: String) {
    div {
        css {
            backgroundColor = NamedColor.firebrick
            color = NamedColor.white
            borderRadius = 2.px
            margin = Margin(0.em, 0.5.em, 0.5.em, 0.5.em)
            padding = Padding(0.25.em, 0.5.em, 0.25.em, 0.5.em)
            whiteSpace = WhiteSpace.nowrap
            overflow = Overflow.hidden
            textOverflow = TextOverflow.ellipsis
        }
        title = truncate(error, 1000)
        +truncate(error, 200)
    }
}
```

Gated on `error != null` (not `phase == Error`) so the strip persists through the brief
running-again window — the fetched model still carries the park's error until the success trace
arrives, so the two gates render identically in practice and this one is simpler.

### 9. js — display hygiene

**9a.** Helper in `VertexController`:

```kotlin
private fun truncate(text: String, maxLength: Int): String =
    if (text.length <= maxLength) text else text.take(maxLength) + "…"
```

**9b.** Message text (:773-787): `val messageText = "${vertexMessage.get()}"`; render
`+truncate(messageText, 20)`; `title = truncate(messageText, 1000)` (replacing the static
`"Message content"`).

**9c.** State text (:873-892): inner div gains the single-line CSS
(`whiteSpace = WhiteSpace.nowrap`, `overflow = Overflow.hidden`,
`textOverflow = TextOverflow.ellipsis`), renders `+truncate("${vertexState.get()}", 1000)`, and
`title = truncate("${vertexState.get()}", 1000)`.

**9d.** `defaultIcon` (:81) → `"material-symbols:settings-input-component"`.

### 10. Wrap-up

Tick the Phase 4 checkbox in `kzen/plans/2026-07-16_flow-improvements.md` and append the
as-built note — it MUST record the refetch verdict (Q1: E5/TP4 had already fixed the bulk;
involvement gate added) and the two FlowRun scope additions (Q2/Q3), per the constituent plan's
explicit instruction. Stage all new files by explicit path.

## Tests

**commonTest** (`kzen-auto-common/src/commonTest/.../paradigm/flow/`) — the structure suites
FL1 built:

1. `FlowStructureTestBuilder`: add
   `fun errored(epoch: Int = 0): VisualVertexModel = VisualVertexModel(false, null, null, false, epoch, "test failure")`
   (KDoc: "Failed: parked under pause-on-error, or settled failed").
2. `FlowUtilsNextTest.erroredVertexNotSelectedWithinLayer` — two no-input sources in one layer
   (`left` = `errored()`, `right` = `VisualVertexModel.empty`): next == `right` (the errored
   sibling is skipped by `nextInLayer`'s phase check).
3. `FlowUtilsNextTest.erroredSingleVertexLayerNotSelected` — `source` @ (0,0) `produced()`,
   `sink` @ (1,0, "input") `errored()`: next == null (the single-vertex shortcut's new guard;
   contrast `successorSelectedAfterSourceProduces`, which is this exact topology with a healthy
   sink).
4. New `VisualVertexModelPhaseTest` (same package, compact): running+error → `Running`
   (precedence); error+epoch 0 → `Error`; error+epoch 1+hasNext → `Error`; the three no-error
   phases unchanged (`Pending`/`Remaining`/`Done`).
5. Existing suites (`FlowUtilsNextTest`'s 11 cases, `FlowMatrixTest`, `FlowDagTest`,
   `FlowStructureValidatorTest`) must stay green untouched — all their fixtures have
   `error = null`, so the phase change is invisible to them; any failure is a real regression.

**jvm** (`:kzen-auto-jvm:test`): steps 3a–3e above — the traced-error-at-park assertion and the
transient-failure clear-on-resume test. Existing `FlowNotationTest` (13 cases, incl. the
benchmark canary), `FlowControllerStepTest`, `FlowMigrationTest` must stay green — in
particular `FlowMigrationTest` proves the routing snapshot change didn't disturb
carried-progress adoption.

**js**: no unit tests (constituent plan: client verification stays manual smoke; the structure
core is the shared-commonTest layer above).

## Verification

1. `./gradlew :kzen-auto-common:allTests :kzen-auto-jvm:test` — `FlowNotationTest`,
   `FlowControllerStepTest`, `FlowMigrationTest`, `FlowUtilsNextTest` + all new cases green.
2. `./gradlew :kzen-auto-js:build` green (KSP + full bundle).
3. Manual smoke — `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`:
   - **FizzBuzz Flow Loop (read-only — open, Run, Step; never edit):** next-vertex highlighting
     and pipe tinting identical to before (compute-once must be behavior-neutral); step through
     an iteration watching card/edge golds.
   - **Error card (scratch document created through the UI — NOT FizzBuzz):** insert
     `IntRangeSource` → `DivisibleFilter` with `divisor: 0`; pause-on-error ON; Run → the run
     parks, the filter card turns red with the message visible in the strip and full text on
     hover; edit `divisor` to `3` (live-edit migration) and Resume → the run completes and the
     red clears (Q3's clear-on-success + Q2's routing guard both exercised end-to-end).
   - **React DevTools highlight-updates:** typing in one vertex's attribute editor flashes only
     that editor; the commit (~1 s debounce) repaints the grid once (each cell now cheap — no
     per-cell DAG derivation); with a Script running in another tab, the Flow grid does not
     flash at all (consumed-subset bail).
   - **Network tab:** with a Script running in another tab, the Flow tab issues at most one
     trace fetch at that run's start and one at settle — no continuous ~1/s
     `mostRecent`/`lookupRun` pairs. With the Flow's own run stepping, per-step refetch still
     immediate (structure change bypasses the throttle).
4. `./gradlew :kzen-auto-test:selfTest` as the broad regression net (optional per ground rules,
   recommended since FlowRun changed).

## Risks & gotchas

- **The `snapshotVisual` error exclusion is the linchpin.** If someone later "fixes" it back to
  passing `model.error` (it looks like an accidental omission), the migrate-during-error-park
  stall (finding 3 in Current-state) returns silently. The inline comment (2a) + the KDoc
  update are the guard; `FlowMigrationTest` does not currently cover the error-carry case —
  out of scope here, but noted for FL6-era hardening.
- **Do not extend the single-vertex-layer guard beyond `Error`.**
  `inProgressSingleVertexLayerSelectedWithoutInputCheck` pins why: the shortcut deliberately
  skips `inputsReady` (mid-stream re-execution without fresh inputs). An "obvious cleanup" to
  route it through the general loop breaks stream draining.
- **Prop-threading completeness:** `nextToRun`/`runningVertex` must flow
  FlowController → CellController → {Vertex,Edge}Controller. A missed hop compiles (nullable
  props default to undefined/null) and silently renders "nothing is next" — the FizzBuzz
  highlight smoke is the catch.
- **Shallow-equal traps** (js-architecture §2): store only `graphStructure`/`documentPath`
  in `FlowControllerState`, never the `ClientState`; `VisualFlowModel` needs the `==` guard
  (5b) because each fetch allocates a fresh instance.
- **`onClientState` stale-location hazard:** `refreshVisualModelIfNeeded` runs against the
  *passed* `clientState` (fresh), and `FlowMatrix.ofDocument` tolerates a missing document
  (returns `empty`, FlowMatrix.kt:35-36) — keep it that way; don't move the matrix build onto
  `state.` reads inside the async block.
- **Kotlin exhaustiveness:** after hoisting Error in the cardColor chain, the inner
  `when (phase)` still requires its `Error` branch (nullable-enum exhaustiveness) — it becomes
  dead but mandatory; return `errorCardColor` there, don't delete it.
- **FL3 rebase:** if FL3 lands mid-session, re-run the step-2 edits against the
  capability-interface `FlowRun` (the recoverable blocks survive verbatim; `runChildVertex` may
  be renamed/regrouped) and re-verify VertexController's attribute area (Dependencies §).
- **Fixture yaml is shared:** `flow-flaky-test.yaml` loads into every jvm test's notation scan;
  keep the archetype `abstract: true` and self-contained (lazy instantiation keeps the
  unregistered class harmless to other tests — the `CountingSinkVertex` precedent).
- **Message-div layout:** the message text lives in a `width = 0` absolutely-positioned div —
  char-truncate (Q6), do not switch it to CSS ellipsis without giving it a real width (that's a
  layout change beyond this phase's scope).

## Out of scope (decided — do not fold in)

- Editing UX (move/auto-pipe/shifting) → FL5; the `flow/edit/*Old.kt` cluster → AE1.
- Vertex SPI capabilities, `FlowMessageInspector` deletion, multi-parameter RunLogic → FL3.
- Per-cell prop narrowing beyond `graphStructure` (cards legitimately read inherited notation;
  memoizing matrix/dag across renders buys almost nothing once per-cell derivation is gone —
  revisit only if the highlight-updates smoke still shows a problem).
- Insert-mode `pointerEvents` polish (FlowController.kt:511-532 insertion buttons) → FL5 rides
  it explicitly.
- `FlowMigrationTest` error-carry coverage (noted in Risks) — candidate for FL6-era hardening.
- Any change to `FlowProgressStore`'s fetch strategy (frame-keyed vs run-merged) — the key
  scoping happens entirely in `FlowController`.
- Multi-output / crossing / nested-loop semantics → FL6 decision gate.
