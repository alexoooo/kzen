# S8a — Script client hot paths — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from `2026-07-16_script-client-sweep.md`
> **8a** (decisions pre-made — do not re-litigate; this document only concretizes them). Every
> anchor re-verified against current kzen-auto master (`ceb699d0`) on 2026-07-19 — i.e. **post
> TP3/TP4** (both landed 2026-07-16 and reshaped `ScriptProgressStore`; TP2 was skipped, per
> master-plan rule 6 this plan skimmed the TP as-builts). Drift from the constituent plan is
> called out inline: all four cited line anchors moved or grew, and the "two consumer sites" for
> `ScriptDependencyAnalysis.analyze` are now **four**. kzen-auto-js only; kzen-lib and
> kzen-auto-jvm untouched. One session, small.

## Scope & goal

Three independent client hot-path fixes so per-publish cost during a Script run stops scaling
with document size × run length:

1. **Memoize `ScriptDependencyAnalysis.analyze`** — today it re-lexes every value scalar in the
   document (`KotlinExpressionAnalyzer.referencedIdentifiers` per code attribute) once per
   branch per `ClientStateGlobal` publish, plus once per overlay remeasure rAF, plus once per
   signature-editor publish. One memo in `ScriptStore`, all consumers share it.
2. **Timeline append instead of re-sort** — `ScriptProgressStore` re-sorts (and re-allocates)
   the whole accumulated history list on every refresh; history arrives watermarked in sequence
   order, so append + monotonicity guard suffices (and fixes a latent duplicate-append bug).
3. **Incremental RunStep representatives** — the per-RunStep latest-screenshot map is rebuilt
   each refresh by scanning all binary events × all RunSteps; fold only the new events instead.

No behaviour change is intended anywhere: same analysis results, same timeline order, same
representative selection — only when/how they are computed, plus reference-stable published
collections as a side benefit.

## Dependencies & coordination

- **TP3/TP4 fence (master-plan rule 6) is satisfied**: TP3/TP4 ran first; this plan's
  `ScriptProgressStore` anchors are against the post-TP3/TP4 file (the TP4 structureVersion-gated
  executions cache at `ScriptProgressStore.kt:35-40,141-162` is **kept as-is** and item 3 builds
  on it). TP2 was skipped — no thin-settle-fetch code exists or is expected.
- **8b overlap, deliberate**: the small value-equality guard added to
  `ScriptBranchDisplay.onClientState` (step 3 below) is an instance of the skip-guard pattern 8b
  later extracts into a shared base. Adding it locally now is required to meet 8a's own
  verification bar ("a progress tick no longer lights up sibling branches"); 8b subsumes it
  structurally later — no conflict.
- **8d neighbourhood**: reaching the memo through `DocumentBridge` + `ScriptStoreKey` is exactly
  the mechanism 8d standardizes on (it moves `StepRowRefRegistry` there) — aligned, no ordering
  constraint.
- Independent of AE, J, FL, G tracks. Single-repo change (kzen-auto-js); no server, wire, or
  notation change; no kzen-lib publish needed.

## Current-state findings (anchors verified 2026-07-19, `ceb699d0`)

**`ScriptDependencyAnalysis.analyze`** (kzen-auto-common
`…/common/objects/document/script/model/ScriptDependencyAnalysis.kt:48-146`): pure function of
`(GraphDefinition, DocumentPath)`. Cost drivers: full `coalesce` key scan + per-in-document-object
definition walk + a **Kotlin lexer pass over every value scalar** (`:127-142`). Unchanged by this
plan (server `ScriptValueReferences` and `ScriptDependencyAnalysisTest` depend on its semantics).

**Client call sites — four, not the plan's two** (drift; the two extra landed with XC2/XC3 and
the signature editor after the sweep plan was drafted):

| Site | Frequency | Notes |
|---|---|---|
| `ScriptBranchDisplay.onClientState` (`…/script/display/dependency/ScriptBranchDisplay.kt:252-280`, analyze at `:270-272`) | per **branch instance** per publish | hottest — N branches ⇒ N calls/publish |
| `ScriptDependencyOverlay.computeCrossBranchEdges` (`…/dependency/ScriptDependencyOverlay.kt:214-227`, analyze at `:224-226`) | per remeasure rAF (`remeasure()` `:140-200`) — scheduled by every publish, every `StepRowRefRegistry` churn, every ResizeObserver fire (`:69-73,:108`) | hot |
| `LogicSignatureEditor.onClientState` (`…/common/signature/LogicSignatureEditor.kt:203-211`, analyze at `:208-209`) | per publish, when the Script has parameters | warm; already has a `==` setState guard (`:215`) |
| `ScriptMoveToArrow.onGlyphPointerDown` (`…/script/display/ScriptMoveToArrow.kt:277-279`) | user pointer-down only | cold; included for uniformity + free memo hit on paused runs |

None of the three non-branch components installs a `contextType` (verified — grep for
`installContextType|contextValue` in each): the single class-component context slot is **free**
in all of them. `ScriptBranchDisplay` already installs `DocumentBridgeContext` (`:113-115`).
`ScriptController` provides `ScriptStoreKey` into the bridge in `render()` before any child
mounts (`ScriptController.kt:328-331`) — but **not** on the Raw-view early return (`:317-320`),
where no consumers are mounted either, and note `ScriptController` is **not remounted on a
same-archetype document switch** (comment at `:324-327`) — the same `ScriptStore` instance then
serves a different `documentPath`, so the memo key must include the path.

**Graph identity on the client** (`ClientStateGlobal.kt`): `graphDefinitionAttempt` is replaced
only on notation events (`onCommandSuccess :76-81`, `onStoreRefresh :84-87`); logic-status
publishes (`onLogic :90-93`) reuse the same reference. So during a run, every publish carries the
**same** `GraphDefinitionAttempt` object — a reference-identity memo key hits on the entire hot
path. ⚠ `GraphDefinitionAttempt.successful()` allocates a **fresh** `GraphDefinition` per call
(kzen-lib `GraphDefinitionAttempt.kt:18-20`) — the memo must key on the *attempt*, never on the
`successful()` result.

**`ScriptStore`** (`…/script/model/ScriptStore.kt`): `onClientState` at `:96-169` (anchor holds);
`documentNotationChanged` computed at `:149` — noted by the constituent plan as the invalidation
signal, but see Pre-resolved question 2 for why the memo self-keys instead.
`progressStore.refresh()` has exactly one caller: `refreshProgressAsync` (`:173-181`, 10 ms yield
then `refresh()`), fired on `traceVersion` change and initial load.

**`ScriptProgressStore`** (`…/script/progress/ScriptProgressStore.kt`) — the TP3/TP4-reshaped
file; the constituent plan's `:125` / `:204-223` anchors have drifted:

- Watermark: `sinceSequence = historyEvents.maxOfOrNull { it.sequence } ?: 0L` at `:134`.
- The re-sort: `val events = historyEvents.sortedBy { it.sequence }` at **`:139`** — O(n log n)
  + full-list allocation per refresh, forever growing with run length.
- Run-change reset at `:128-133` (clears `historyEvents` + the TP4 executions cache);
  `resetHistory()` at `:408-413`.
- TP4 executions cache: fields `:35-40`, structureVersion-gated fetch `:141-162` — **unchanged
  by this plan**.
- Ownership derivation `computeRunStepOwnedExecutions` at **`:186-214`** + subtree collector
  `:217-229` — recomputed every refresh from the cached `lastExecutions` (cheap but produces a
  fresh map reference each time).
- Representatives `computeRunStepRepresentative` at **`:232-253`**: filters **all** accumulated
  events for `it.value is BinaryValue` (the TP3 sealed supertype — `BinaryHandleExecutionValue`
  rides it; never test `BinaryExecutionValue` here), then per RunStep filters + `maxByOrNull` —
  O(events × RunSteps) per refresh.
- Error path `:105-121` publishes empty progress but does **not** clear the accumulators
  (deliberate — next success re-publishes); keep that.

**Server ordering contract — verified, load-bearing for item 2**:
- `RunEngineLogicTrace.lookupRunHistory` (kzen-auto-jvm `…/server/exec/RunEngineLogicTrace.kt:170-196`),
  comment at `:180-183`: *"history() is already sequence-ordered (single writer) and incremental
  (> sinceSequence)"* — strictly-greater-than filter.
- `RunEngine.history` (kzen-lib `…/server/exec/engine/RunEngine.kt:394-401`): binary-search on
  `sinceSequence + 1` over an append-only list; `sequence += 1` per event under the engine lock
  (`:891,:907`) ⇒ sequences are **unique and strictly increasing**.
- Live-edit migration: *"history, sequence, observers and terminal handle are preserved — the
  trace is continuous across"* (`RunEngine.kt:463`) and `runId` is unchanged ⇒ **no client
  watermark reset on migrate**. A JVM restart drops runs entirely ⇒ `mostRecent()` null ⇒ the
  existing reset path. So the only source of a non-fresh event reaching the client is a
  **concurrent in-flight refresh** that read an older watermark — a *latent duplicate-append bug
  in today's code* (two overlapping `refresh()` coroutines both `addAll` the same delta;
  `sortedBy` does not dedupe). The append design below fixes it.

**Published-state consumers** (why reference stability is worth having): `ScriptProgressState`
(`…/progress/ScriptProgressState.kt:10-55`) fields `traceEvents` / `runStepRepresentative` /
`runStepOwnedExecutions` feed `RunStepDisplay` (`:150-151` — comment *"traceEvents is sorted by
sequence; keep that order"* — append preserves it) and `PageScreenshots` (`:110`).
`ScriptStore.updateIfChanged` (`ScriptStore.kt:224-231`) bails on data-class equality — stable
references make the no-news refresh cheap and allocation-free.

**Test infrastructure**: kzen-auto-js has **no test source set** (verified — no `src/jsTest`);
kzen-auto-common's `commonTest` exists but this plan touches only kzen-auto-js (see Tests).

## Pre-resolved questions

1. **Cache placement: `ScriptStore`** (the constituent plan's first-listed option; the
   alternative "small keyed cache both consumers read" is rejected). Rationale: (a) per-mounted-
   document lifetime for free — no process-global (the direction 8d moves in), no eviction
   policy; (b) all four consumers sit in the `ScriptController` subtree and can reach the store
   through the already-established `DocumentBridge` + `ScriptStoreKey` (`DocumentBridge.kt:29-61`,
   `ScriptStoreKey.kt:9`); (c) a separate cache object would need its own bridge key + provide
   wiring for zero additional benefit.
2. **Invalidation: self-keyed on (`GraphDefinitionAttempt` reference identity, `documentPath`)**
   — a refinement of the constituent plan's "invalidated on `documentNotationChanged`", same
   intent, strictly better: (a) **ordering-free** — a reactive invalidation in
   `ScriptStore.onClientState` races consumers' own `onClientState` (observer call order within
   `ClientStateGlobal.publishIfReady :130-138` is set-iteration order, unspecified), whereas a
   self-keyed memo can never serve a value for a graph other than the one the caller passed;
   (b) **covers cross-document drift** — an edit to another document (e.g. an archetype a step
   inherits) changes this document's definitions without changing its `DocumentNotation`; the
   attempt reference catches it, the `documentNotationChanged` signal would not; (c) the hot path
   (logic-only publishes) still always hits, since the attempt reference is stable there (see
   findings). Recompute-per-edit (any document) is accepted — that is today's cost × N consumers
   reduced to × 1.
3. **How consumers reach it: `DocumentBridge` context, not props.** `ScriptBranchDisplay`
   already has the context; the other three install `DocumentBridgeContext` (slots verified
   free). Props were rejected: `ScriptController` would need to thread a stable callable (a
   `store::dependencyAnalysis` bound reference is a fresh object per render — an RPureComponent
   footgun), and `LogicSignatureEditor` would grow a `ScriptStore`-typed prop. Every consumer
   falls back to direct `analyze(...)` when the lookup returns null (bridge absent / store not
   provided) — behaviour identical to today, never a crash. `LogicSignatureEditor` already
   imports script-display types (`StepDependencyEdges`), so the `ScriptStoreKey` import is not a
   new coupling class.
4. **Duplicate events are dropped at append, not sorted away**: the server contract is strictly
   `> sinceSequence`, so anything at/below the client watermark is by definition a concurrent
   re-delivery — dropping is the correct, deterministic behaviour (and repairs the latent
   duplicate bug). The "monotonicity assertion" is a `console.warn` + one-shot repair sort
   (precedent: `IconLoader.kt:35`), **not** a `check()` — a throw inside the refresh coroutine
   would surface as an unhandled async error over a cosmetic timeline.
5. **Representatives rebuild triggers**: ownership recompute happens only when the viewed
   execution id or the (TP4-cached) executions list identity changes; a value-changed ownership
   map (or a repaired timeline) triggers one full O(events) rebuild via a reverse index —
   otherwise fold only the new tail. Equivalence with today's `maxByOrNull` holds because the
   timeline is ascending (last write wins = max sequence).
6. **`StepDependencyEdges.compute` stays per-branch per-publish** — it is a small lane-assignment
   over the (now-shared) analysis (`StepDependencyGutter.kt:172+`); memoizing it per branch is 8b
   territory if ever.

## Step-by-step implementation

### A. Memoize `analyze` in `ScriptStore`

**A1.** `ScriptStore.kt` — add after `mainLocation()` (`:209-212`):

```kotlin
//-----------------------------------------------------------------------------------------------------------------
// Single-entry memo for ScriptDependencyAnalysis.analyze, shared by every consumer in this
// document's subtree (branch gutters, overlay, signature editor, move-to arrow). Self-keyed on
// the GraphDefinitionAttempt REFERENCE (replaced only on notation events — logic-only publishes
// reuse it, so the run hot path always hits) + documentPath (ScriptController isn't remounted on
// a same-archetype document switch, so one store instance can serve successive documents).
// NB: never key on successful() — it allocates a fresh GraphDefinition per call.
private var dependencyAnalysisKeyAttempt: GraphDefinitionAttempt? = null
private var dependencyAnalysisKeyPath: DocumentPath? = null
private var dependencyAnalysisCached: ScriptDependencyAnalysis? = null

fun dependencyAnalysis(
    graphDefinitionAttempt: GraphDefinitionAttempt,
    documentPath: DocumentPath
): ScriptDependencyAnalysis {
    val cached = dependencyAnalysisCached
    if (cached != null &&
            graphDefinitionAttempt === dependencyAnalysisKeyAttempt &&
            documentPath == dependencyAnalysisKeyPath) {
        return cached
    }
    val computed = ScriptDependencyAnalysis.analyze(
        graphDefinitionAttempt.successful(), documentPath)
    dependencyAnalysisKeyAttempt = graphDefinitionAttempt
    dependencyAnalysisKeyPath = documentPath
    dependencyAnalysisCached = computed
    return computed
}
```

New imports: `GraphDefinitionAttempt` (`tech.kzen.lib.common.model.definition`), `DocumentPath`
(`tech.kzen.lib.common.model.document`), `ScriptDependencyAnalysis`
(`tech.kzen.auto.common.objects.document.script.model`). No reactive invalidation code in
`onClientState` — none is needed (Pre-resolved 2). The method touches none of the store's
nullable `state`, so it is safe pre-init and during teardown.

**A2.** `ScriptBranchDisplay.kt` — replace the direct call at `:270-272` with a lookup-or-fallback:

```kotlin
val store = contextValue<DocumentBridge?>()?.lookup(ScriptStoreKey)
val analysis = store?.dependencyAnalysis(clientState.graphDefinitionAttempt, documentPath)
    ?: ScriptDependencyAnalysis.analyze(clientState.graphDefinitionAttempt.successful(), documentPath)
```

(import `ScriptStoreKey`; `DocumentBridge`/`contextValue` already imported).

**A3.** `ScriptBranchDisplay.onClientState` — add the value-equality skip-guard before the
`setState` at `:276-279` (both values are freshly allocated each call, so it must be `==`, per
js-architecture §2 point 3):

```kotlin
if (state.stepLocations == stepLocations && state.dependencyEdges == dependencyEdges) {
    return
}
```

This is what actually stops a progress tick from re-rendering every branch (the memo alone only
makes the wasted render cheaper). 8b later replaces it with the shared base — fine.

**A4.** `ScriptDependencyOverlay.kt` — add `init { installContextType(DocumentBridgeContext) }`
(slot verified free) and swap `:224-226` to the same lookup-or-fallback (documentPath is already
in scope at `:215-216`). Imports: `DocumentBridge`, `DocumentBridgeContext`, `ScriptStoreKey`,
`tech.kzen.auto.client.wrap.installContextType`, `tech.kzen.auto.client.wrap.contextValue`.

**A5.** `LogicSignatureEditor.kt` — same treatment at `:208-209` (`init { installContextType(…) }`;
documentPath = `props.objectLocation.documentPath`). Its existing `==` guard (`:215`) already
prevents re-render; only the analyze cost changes.

**A6.** `ScriptMoveToArrow.kt` — same treatment at `:277-279` (cold path; uniformity + paused-run
memo hit).

### B. Timeline append (`ScriptProgressStore`)

**B1.** New fields beside `historyEvents` (`:32-33`):

```kotlin
// Immutable snapshot of historyEvents for publishing — rebuilt only when the accumulation
// actually changed, so the published reference is stable across no-news refreshes (and the
// mutable accumulator itself is never exposed to state).
private var publishedEvents: List<LogicTraceEvent> = listOf()
```

**B2.** Replace `:134` with the O(1) watermark (equivalent because the list is now append-only
ascending): `val sinceSequence = historyEvents.lastOrNull()?.sequence ?: 0L`.

**B3.** Replace `:136-139` (`addAll` + `sortedBy`) with an append helper; `refresh()` keeps the
result for step C:

```kotlin
private class HistoryAppend(val newEvents: List<LogicTraceEvent>, val repaired: Boolean)

// Append only genuinely-new events, preserving the ascending invariant. Events at/below the
// watermark are dropped: the server serves strictly > sinceSequence (RunEngineLogicTrace), so a
// re-delivery can only be a concurrent in-flight refresh that read an older watermark — dropping
// keeps the film strip duplicate-free (fixes the latent addAll duplicate). A within-batch order
// violation breaks the server's single-writer contract: warn + one-shot repair sort, and signal
// the caller to rebuild derived state.
private fun appendHistory(batch: List<LogicTraceEvent>): HistoryAppend {
    if (batch.isEmpty()) {
        return HistoryAppend(listOf(), false)
    }
    var watermark = historyEvents.lastOrNull()?.sequence ?: 0L
    var previousInBatch = Long.MIN_VALUE
    var orderViolation = false
    val appended = mutableListOf<LogicTraceEvent>()
    for (event in batch) {
        if (event.sequence <= previousInBatch) {
            orderViolation = true
        }
        previousInBatch = event.sequence
        if (event.sequence <= watermark) {
            continue
        }
        historyEvents.add(event)
        appended.add(event)
        watermark = event.sequence
    }
    if (orderViolation) {
        console.warn("ScriptProgressStore: non-monotonic history batch, repairing")
        historyEvents.sortBy { it.sequence }
    }
    if (appended.isNotEmpty() || orderViolation) {
        publishedEvents = historyEvents.toList()
    }
    return HistoryAppend(appended, orderViolation)
}
```

**B4.** The success-branch publish (`:173`) uses `traceEvents = publishedEvents`. The error path
(`:105-121`) and the no-run reset (`:61-77`) keep their hard-coded `listOf()` — unchanged
behaviour (accumulators survive a transient fetch error, exactly as today).

**B5.** Unify the two reset sites — extract `resetRunAccumulators(newRunId: LogicRunId?)`
clearing `historyEvents`, `publishedEvents`, `lastExecutions`, `lastExecutionsStructureVersion`,
**and the step-C fields**, setting `historyRunId = newRunId`; call it from the run-change branch
(`:128-133`, with `logicRunId`) and from `resetHistory()` (`:408-413`, with `null` — or replace
`resetHistory` outright, it has one caller at `:62`). Watermark-reset semantics, for the record:
new run ⇒ full reset here; live-edit migration ⇒ same runId, continuous sequence ⇒ deliberately
**no** reset (see findings); JVM restart ⇒ no run ⇒ the null-reset path.

### C. Incremental RunStep representatives (`ScriptProgressStore`)

**C1.** New fields (beside the TP4 cache, `:35-40`):

```kotlin
// Ownership memo: recomputed only when the viewed execution or the (TP4-cached) executions list
// identity changes; kept value-stable so the published references survive a same-content refetch.
private var ownershipViewedExecutionId: LogicExecutionId? = null
private var ownershipExecutions: List<LogicRunExecutionInfo>? = null
private var ownershipByStep: Map<ObjectStableId, Set<String>> = mapOf()
// Reverse index of ownershipByStep (owned sets are disjoint — the execution tree is a tree and
// same-caller subtrees merge into one set), so a new event resolves its RunStep in O(1).
private var stepByExecutionId: Map<String, ObjectStableId> = mapOf()

private var representativeByStep: Map<ObjectStableId, LogicTraceEvent> = mapOf()
```

**C2.** Ownership refresh, replacing the unconditional call at `:163-164`:

```kotlin
private fun refreshOwnership(
    viewedExecutionId: LogicExecutionId,
    executions: List<LogicRunExecutionInfo>
): Boolean {
    if (viewedExecutionId == ownershipViewedExecutionId && executions === ownershipExecutions) {
        return false
    }
    ownershipViewedExecutionId = viewedExecutionId
    ownershipExecutions = executions
    val computed = computeRunStepOwnedExecutions(viewedExecutionId, executions)
    if (computed == ownershipByStep) {
        return false    // refetch yielded identical content — keep the stable references
    }
    ownershipByStep = computed
    stepByExecutionId = buildMap {
        for ((stepId, owned) in computed) {
            for (executionId in owned) {
                put(executionId, stepId)
            }
        }
    }
    return true
}
```

`computeRunStepOwnedExecutions` (`:191-214`) and `collectExecutionSubtree` (`:217-229`) stay
as-is (they are cheap and only run on structural change now).

**C3.** Rebuild + fold, replacing `computeRunStepRepresentative` (`:232-253`):

```kotlin
// Full pass — only on ownership change / timeline repair. Ascending order ⇒ last write wins ⇒
// identical selection to the old per-step maxByOrNull.
private fun rebuildRepresentatives() {
    val out = mutableMapOf<ObjectStableId, LogicTraceEvent>()
    for (event in historyEvents) {
        if (event.value !is BinaryValue) {
            continue
        }
        val owner = stepByExecutionId[event.executionId.value]
            ?: continue
        out[owner] = event
    }
    representativeByStep = out
}

// Per-refresh path: fold only this refresh's appended tail; copy-on-write so the published map
// reference is stable when no screenshot landed.
private fun foldRepresentatives(newEvents: List<LogicTraceEvent>) {
    var updates: MutableMap<ObjectStableId, LogicTraceEvent>? = null
    for (event in newEvents) {
        if (event.value !is BinaryValue) {
            continue
        }
        val owner = stepByExecutionId[event.executionId.value]
            ?: continue
        val target = updates
            ?: mutableMapOf<ObjectStableId, LogicTraceEvent>().also { updates = it }
        target[owner] = event
    }
    val changed = updates
        ?: return
    representativeByStep = representativeByStep + changed
}
```

**C4.** Wire into the success branch (order matters — append **before** ownership/rebuild so a
rebuild covers the new tail):

```kotlin
val append = /* B3 */ if (historyResult is ClientSuccess) appendHistory(historyResult.value)
             else HistoryAppend(listOf(), false)
// … TP4 executions block unchanged (:141-161) …
val ownershipChanged = refreshOwnership(logicRunExecutionId.logicExecutionId, lastExecutions)
if (ownershipChanged || append.repaired) {
    rebuildRepresentatives()
}
else {
    foldRepresentatives(append.newEvents)
}
```

and publish `runStepRepresentative = representativeByStep`,
`runStepOwnedExecutions = ownershipByStep` (`:174-175`).

Semantics preserved, by construction: **loop iterations** — new executions under the same
RunStep bump `structureVersion` ⇒ executions refetch ⇒ ownership recompute (value-changed ⇒
rebuild; the new iteration's screenshots then fold normally); **re-entry of the viewed document**
(its own executionId changes) ⇒ ownership key miss ⇒ rebuild against the new seed root —
preserving the "no strip before it runs" scoping; **re-runs** ⇒ run-id reset (B5) clears
everything; **settle** ⇒ `mostRecent()` resolves the same execution and the refetched executions
are value-equal ⇒ stable references, no rebuild. An owned event arriving one refresh before its
execution shows in the (raced) executions fetch converges on the next structural refresh —
identical to today's convergence.

### D. Bookkeeping

- **Docs touch-up** (one line): `kzen-auto/docs/js-architecture.md` §2's RunStep-strip paragraph
  says the store derives ownership "each refresh" — amend to "on structural change (memoized;
  representatives fold incrementally)". No architecture.md change (no wire/server change).
- **Tracker**: tick 8a in `kzen/plans/2026-07-16_script-client-sweep.md` with date + as-built
  note (four analyze consumers, not two; attempt-identity memo key; the duplicate-append latent
  bug fixed by the watermark filter; anchor drift recorded here).
- Git hygiene: no new source files expected (all edits to existing files — nothing to stage
  beyond the tracked diff). Stage only, never commit.

## Tests

- **No new unit tests**: kzen-auto-js has no test source set (verified), and the touched logic
  is client-only. Extracting the append/fold helpers into kzen-auto-common purely to gain
  commonTest coverage was considered and **declined** — it would move view-model logic into the
  shared module for a small session; record as a future option if this code grows.
- **Existing suites are the regression net**: `ScriptDependencyAnalysisTest` (kzen-auto-jvm)
  pins `analyze` semantics — untouched by the memo; `selfTest` drives real Script runs
  (screenshots, film strip, trace detection) end-to-end through this exact store.

## Verification

1. **Build gate**: `./gradlew :kzen-auto-js:build` (KSP + JS compile + any js checks). Nothing
   server-side changed, but `./gradlew build` is cheap insurance if time allows.
2. **selfTest**: `./gradlew :kzen-auto-test:selfTest` (opens Chrome, two JVMs) — exercises run
   traces, screenshots, and pass/fail detection through the reshaped store.
3. **Manual, with the user at the browser** — `./gradlew :kzen-auto-jvm:frontendDevelopment
   -PjsWatch`, React DevTools → Components → gear → "Highlight updates when components render".
   Use existing documents or create scratch ones via the UI; never touch `notation/main/` files
   directly. Script needs: a Script with ≥2 branches (an IfStep), a cross-branch reference (a
   FormulaStep naming a step in another branch — dependency line visible), parameters (signature
   gutter), and a RunStep invoking a screenshot-taking sub-script; plus a ~40-step fast script
   (FizzBuzz-style loop).
   - **Sibling-branch quiescence**: start the 40-step run; during progress ticks the sibling
     `ScriptBranchDisplay` subtrees must NOT highlight (the A3 guard); expand/collapse a step —
     still no sibling highlight (regression).
   - **Hot-path cost**: DevTools Performance (or React Profiler) over ~10 s of the run — no
     recurring `analyze` / `referencedIdentifiers` frames between edits (they should appear only
     when the document is edited); main thread quiet between publishes; the run visibly smooth.
   - **Memo invalidation**: pause the run, edit a step's expression to add/remove a cross-branch
     reference — the dependency polyline/gutter updates immediately (memo keyed on the new
     graph); resume works.
   - **Film strip / representatives**: the RunStep's thumbnail updates to the latest screenshot
     while running; its expanded strip accumulates frames per iteration in execution order, **no
     duplicates**; after settle the strip and each step's Done state persist; run a second time —
     the strip resets to the new run.
   - **Cold paths**: move-to arrow drag on the paused run still shows valid/warn targets;
     parameter→step dependency lines still draw in the signature gutter; rename a step mid-run —
     no observer errors, thumbnail follows (stable-id keying).
   - **Console**: no `non-monotonic history` warnings during normal runs.

## Risks & gotchas

- **Never publish the mutable accumulator**: `historyEvents` must not leak into
  `ScriptProgressState` — a mutated list held in published state breaks data-class equality and
  the store's `updateIfChanged` bail. `publishedEvents` snapshots exist precisely for this.
- **Memo key discipline**: key on the `GraphDefinitionAttempt` reference — `successful()` is a
  fresh allocation per call (`GraphDefinitionAttempt.kt:18-20`); keying on it would never hit.
  And keep `documentPath` in the key — same-archetype document switches reuse the
  `ScriptController`/`ScriptStore` instance.
- **`BinaryValue`, not `BinaryExecutionValue`** (TP3): the fold/rebuild gates must use the sealed
  supertype, as current `:238` does — a `BinaryExecutionValue` test would silently drop every
  handle-projected screenshot.
- **contextType single slot**: `installContextType` is idempotent but one-per-class — verified
  free in the three components gaining it; if any grows a different context later, the bridge IS
  the context (house pattern), route through it.
- **Fallback must remain**: every consumer keeps the direct-`analyze` fallback for a null bridge
  or unprovided store (Raw-view timing, future non-Script `LogicSignatureEditor` hosts) —
  removing it turns a render-order edge into a blank gutter or crash.
- **Repair path must force rebuild**: after a repair sort the appended "tail" is no longer the
  tail — `repaired == true` must route to `rebuildRepresentatives()`, never the fold (already
  wired in C4; don't "optimize" it away).
- **Don't touch the TP4 block** (`:141-162`): the structureVersion gate + error-path
  cache-invalidation subtleties are TP4's as-built; item 3 only *reads* `lastExecutions`.
- **The A3 guard needs `==`**, not `===`: `stepLocations` and `dependencyEdges` are freshly
  allocated every `onClientState` (js-architecture §2 point 3) — a reference guard would never
  bail and the verification criterion would silently fail.
- **Overlay remeasure stays rAF-driven**: the memo removes the analyze cost from `remeasure()`
  but the `getBoundingClientRect` walk remains by design (it is the measurement, not overhead) —
  do not "fix" the rAF cadence here.
- **Latent-bug framing**: the watermark drop changes behaviour only in the concurrent-refresh
  overlap case, where today duplicates frames — if a film-strip diff shows *fewer* frames than a
  pre-change capture, check for exact-duplicate sequences before suspecting a regression.

## Out of scope

- 8b (display/editor dedup — shared observer base, scope helper, buildGroups), 8c
  (notation-driven branch discovery — `branchAttributeNames` stays hardcoded here), 8d
  (`StepRowRefRegistry` scoping, TODOs) — including any structural extraction of the A3 guard.
- Any server, wire, or kzen-lib change; TP2 (skipped; superseded by TP3).
- Memoizing `StepDependencyEdges.compute` per branch, `ScriptController.stepLocations`, or
  re-architecting `ScriptStore.publish()` broadcast.
- Moving append/fold helpers to kzen-auto-common for testability (recorded option, declined).
- `ScriptValueReferences` (server) — shares `analyze` but runs per compile, not per publish.
- Anything under `notation/main/` (user working documents — read-only during smoke).
