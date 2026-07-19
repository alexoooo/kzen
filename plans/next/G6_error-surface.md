# G6 — error surface — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from `2026-07-16_graph-improvements.md`
> **Phase 6** (master plan Track N, item N5: "failures name their origin instead of
> 'Missing: main'"). Decisions pre-made in the constituent plan — do not re-litigate. Every
> anchor re-verified against current heads: kzen-lib `3d2ef97`, kzen-auto `ceb699d0`
> (both "added NotationCodec", post-G5/G7/SER/Y/TP). One session, light. Two repos:
> **kzen-lib first, `publishToMavenLocal`, then kzen-auto** (`--refresh-dependencies`).
>
> **One material drift finding (rescope, called out in § Current-state):** the constituent
> plan's client bullet ("simplify `DefinitionErrors` to consume the structured failures
> directly") is largely *already built* — `DefinitionErrors` + `StageController` panel +
> `ProjectController` banner + `HeaderRunController` run-blocking all exist and consume
> `GraphDefinitionAttempt.failures` directly. The real remaining client gaps are (a) the
> `ReportStore` NPE (`objectDefinitions[mainLocation]!!`) and (b) the generic
> "Depends on an object that failed to define" fallback, which the new
> `transitiveFailures` API makes precise. Scope adjusted accordingly; no design change.

## Scope & goal

A failed object stops surfacing as `"Missing: <location>"` / `"Not found: <location>"` at use
time; consumers get the failure origin without reconstructing it. Concretely:

1. **kzen-lib** — `GraphInstanceAttempt` (mirror of `GraphDefinitionAttempt`) +
   `GraphCreator.tryCreateGraph` returning it (`createGraph` delegates and throws — additive);
   structured per-attribute causes on definition failures (which attribute, which reference,
   resolved against what — additive fields only); a new
   `GraphDefinitionAttempt.transitiveFailures` lazy that records *why* each object dropped out
   of `transitiveSuccessful` (today the drop is silent — see findings); locate error messages
   rebuilt around near-miss candidates instead of a full document-path dump.
2. **kzen-auto server** — `ModelTaskRepository.submit` (resolves the `// TODO: add
   GraphInstanceAttempt` at `ModelTaskRepository.kt:134`) and
   `ModelDetachedExecutor.execute`/`executeDownload` consume `tryCreateGraph` +
   `transitiveFailures` and report the originating failure in their error results.
3. **kzen-auto client** — `ReportStore`/`ReportState` `!!` unwraps get a guarded path (no more
   `window.alert("Observer error in ReportStore…")` on a broken report);
   `DefinitionErrors.runBlocker`/`all` consume `transitiveFailures` so transitively-dropped
   objects are named with their root cause.

SPI compatibility is **additive-only** throughout: no existing signature changes; new data-class
fields get defaults; new factory params get defaults.

## Dependencies & coordination

- **Prerequisite-free** (constituent plan sizing table: phase 6 independent of 3/4/5/7; master
  plan: G5/G6/G7 mutually independent, `2026-07-16_master-plan.md:118`).
- **G3 coordination (the known seam).** G3, when it lands, rewrites the *same* executor bodies
  (`ModelTaskRepository.submit`, `ModelDetachedExecutor.execute`/`executeDownload`) to
  `filterTransitive(actionLocation)` + a digest-keyed `GraphInstanceCache`. Whichever lands
  second adapts:
  - If **G6 lands first** (expected — master pick order is G6 → G3): G3 slots its cache around
    `tryCreateGraph`, caching **successful instances only** (`attempt.hasErrors()` ⇒ don't
    cache; failures are rare and recompute cheaply). G3's scope-first step must add a
    membership pre-check before `filterTransitive(actionLocation)` — `transitiveClosure`
    `require`s the root is present (`GraphDefinition.kt:59-61`) and would otherwise reintroduce
    a bare `"Missing: <loc>"` throw; the pre-check reports via `transitiveFailures` exactly as
    step 8 below does.
  - If **G3 lands first**: this plan's step 8/9 wording changes mechanically (the
    `tryCreateGraph` call goes inside/behind the cache; the origin-message helper is unchanged).
- **G5 precedent (already landed):** `CodecAttributeDefiner` reads via the nullable
  `firstAttribute`/`mergeAttribute` overloads → graceful `AttributeDefinitionFailure` when a
  spec attribute is absent/malformed. This means a broken Report spec attribute produces a
  **direct** `ObjectDefinitionFailure` with `attributeErrors` populated — which is what the
  manual UI verification below exercises.
- **SER (complete):** no wire-shape change is needed (determination in § Pre-resolved, Q6) —
  no kotlinx DTO work, no Long-as-string concerns.
- kzen-auto consumes kzen-lib from **mavenLocal**: after the kzen-lib half,
  `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`.
- `../kzen-project`: consumes kzen-auto/kzen-lib from mavenLocal; all changes here are additive
  API + message-content changes, so no coordination needed (grep for `attributeErrors` /
  `ObjectDefinitionFailure` construction there is a 1-minute due-diligence step; none expected).

## Current-state findings (anchors verified 2026-07-19)

### kzen-lib — definition side

- **`GraphDefinitionAttempt`**
  (`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/definition/GraphDefinitionAttempt.kt`):
  `objectDefinitions` / `failures: ObjectLocationMap<ObjectDefinitionFailure>` /
  `graphStructure` (:13-16); `successful()` (:18-20); `transitiveSuccessful` lazy fixpoint
  (:23-73) — for each definition's `references()`: bootstrap skipped (:38), **empty reference
  fails unless the attribute's metadata says nullable** (:43-52), otherwise
  `objectDefinitions.locateOptional(ref, host)` must resolve to a non-failed location (:55-58).
  A failing reference removes the object and re-runs the sweep. **The drop cause is discarded**
  — `failedObjectLocations` is local; nothing records which reference/attribute failed.
- **Key structural fact:** a *dangling strong reference does not fail at define time.*
  `StructuralAttributeDefiner.defineScalar` (`objects/base/StructuralAttributeDefiner.kt:116-120`)
  emits `ReferenceAttributeDefinition(ObjectReference.parse(value), false, nullable)` for any
  non-primitive scalar — no resolution check. So the object *defines successfully*, silently
  drops in `transitiveSuccessful`, and the consumer sees `"Missing: …"`/`"Not found: …"` at use
  time. This is why the constituent plan's dangling-reference test needs the **new
  `transitiveFailures`**, not an `AttributeObjectDefiner` change: the per-attribute-cause
  enrichment alone cannot catch it.
- **`ObjectDefinitionFailure`** (`model/definition/ObjectDefinitionAttempt.kt:49-54`):
  `partial: ObjectDefinition?`, `missingObjects: ObjectLocationSet`, `errorMessage: String`,
  `attributeErrors: Map<AttributeName, String>`. Companion factories `missingObjectsFailure`
  (:15-26) and `failure` (:29-39).
- **`AttributeDefinitionFailure`** (`model/definition/AttributeDefinitionAttempt.kt:23-25`):
  `errorMessage: String` only; factory `failure(error)` (:11-13).
- **`AttributeObjectDefiner`** (`objects/base/AttributeObjectDefiner.kt`): *already* populates
  `attributeErrors` per attribute (:64-106) — "Unknown attribute definer: $ref" (:74),
  "Definer missing: …" (:81, + `missingObjects`), "Attribute definer expected: …" (:87), and
  the delegated definer's `errorMessage` (:103-105). What's flattened is the **object-level
  `errorMessage`**: `"Unfulfilled dependency : $attributeErrors"` (:126, a map `toString`) and
  `"Failed: ${attributeErrors.keys}"` (:134). No structured reference/host ride along.
- **`ObjectDefinition.references()`** (`model/definition/ObjectDefinition.kt:54-66`) returns
  `Set<ObjectDefinitionReference>`; **`ObjectDefinitionReference`**
  (`model/definition/ObjectDefinitionReference.kt:8-11`) carries `objectReference` +
  `attributePath: AttributePath?` (null for creator-related refs) — so the transitive pass
  already *knows* the attribute path of every failing reference; it just throws it away.
  `isNullable(hostMetadata)` (:25-33) is the nullability rule the fixpoint uses.
- **`GraphDefiner.tryDefine`** (`service/context/GraphDefiner.kt:82-220`): level loop; on
  `ObjectDefinitionFailure` records into `levelFailures` (:149-153); returns the attempt with
  the *last level's* failures when a level closes nothing (:201-206). Note `coalesce.locate`
  calls at :128-129 and :162-163 (definer/creator references) throw on dangling — they benefit
  from the improved locate message but are **not** converted to graceful failures (out of
  scope; they only fire for meta-tower objects).

### kzen-lib — creation side

- **`GraphCreator`** (`service/context/GraphCreator.kt`, `object`): `createGraph` (:34-69) —
  Kahn `constructionLevels` (:81-164) then a flat create loop with four throw sites: missing
  definition (:46-47), unresolvable creator (:49-53), non-`ObjectCreator` creator (:55-56), and
  `creator.create` itself may throw (:58-63, uncaught). `constructionLevels` ends in
  `check(open.isEmpty()) { "Unable to satisfy: $unsatisfied - Open = $open" }` (:157-161) using
  `findUnsatisfied` (:167-198) → private `UnsatisfiedSet(locations, references)` /
  `UnsatisfiedReference(host, reference)` (:17-30). `tryLocate` (:201-224) throws
  `"Ambiguous reference: … candidates: …"` (:222-223) — **pinned** by
  `GraphCreatorTest.Ambiguous reference reports all candidates`
  (`kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/GraphCreatorTest.kt:60-98`, asserts
  substring `"Ambiguous reference"`, `"kzen-base"`, `"creator-shadow-test"`).
- **`GraphInstance`** (`model/instance/GraphInstance.kt`): thin wrapper over
  `ObjectLocationMap<ObjectInstance>`. **No `GraphInstanceAttempt` exists anywhere** (grep:
  only the kzen-auto TODO comment mentions it).

### kzen-lib — locate messages (anchors exactly as the constituent plan cited)

- `ObjectLocationMap.locate` (`model/location/ObjectLocationMap.kt:37-51`):
  `"Missing: $reference | ${map.keys.map { it.documentPath }.toSet()}"` (and the host variant)
  — dumps **every document path in the graph**.
- `ObjectLocationSet.Locator.locate` (`model/location/ObjectLocationSet.kt:73-87`): same dump
  from `byName`. `Locator` keeps `private val byName: MutableMap<ObjectName,
  MutableList<ObjectLocation>>` (:17) — the exact index a near-miss needs.
  `locateAll` (:37-70) filters by `reference.path`/`nesting`, then host-document (:59-67).
- `ObjectLocator` interface (`model/location/ObjectLocator.kt`): `locateOptional` throws
  `check` on ambiguity (:36-64). `ObjectLocationMap.locator()` cache is already typed
  `ObjectLocationSet.Locator?` (:25, :63-69) — the near-miss accessor needs no cast.
- Other `"Missing: "` sites (`GraphNotation.kt:130`, `GraphDefinition.kt:60`) are **kept as-is**
  (out of scope), except `GraphDefinition.transitiveClosure`'s dependents get preempted by the
  executor-side guards (step 8).
- No test pins any of these message strings (grep `"Unable to satisfy|Unfulfilled dependency|Missing: "`
  across both repos: source sites only; kzen-auto's `"Missing: "` hits are unrelated
  `ReportWorkPool`/plugin-repo messages).

### kzen-auto — server

> ⚠️ **Drift since this plan was written — G3 landed 2026-07-19.** Both executors below now
> instantiate through `GraphInstanceCache.objectInstance(serverDefinition, location)` (closure-scoped,
> digest-keyed) instead of calling `graphCreator.createGraph` on the whole serverAllowed graph, and
> take a plain `GraphEnvironment`. The line anchors in this section are stale; the *error shapes*
> described (soft `ExecutionFailure` vs hard `error(...)`, the unwrapped creator throw, the preserved
> `// TODO: add GraphInstanceAttempt`) all survive unchanged — the creator call simply moved inside
> `GraphInstanceCache.create`. The "Not DetachedAAction" typo was fixed in passing.

- **`ModelTaskRepository.submit`**
  (`kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/exec/ModelTaskRepository.kt:128-167`):
  `graphStore.graphDefinition().transitiveSuccessful.filterDefinitions(AutoConventions.serverAllowed)`
  (:129-132), **`// TODO: add GraphInstanceAttempt for error reporting` at :134** (confirmed),
  `graphCreator.createGraph(graphDefinition, environment())` (:135-136), then
  `?: throw IllegalArgumentException("Not found: $taskLocation")` (:138-139).
- **`ModelDetachedExecutor`** (`…/server/service/exec/ModelDetachedExecutor.kt`): `execute`
  (:31-56) — same build (:35-41), soft `ExecutionFailure("Not found: $actionLocation")` (:44),
  `"Not DetachedAAction: …"` (:47, note the pre-existing typo), `action.execute` wrapped in
  try/catch (:49-55) but **`createGraph` is not** — a creator throw propagates to Ktor as a raw
  500. `executeDownload` (:59-78) — hard `error("Not found: …")` (:72) / `error("Not
  DetachedDownloadAction…")` (:75), no try/catch at all.
- **`GraphInstanceCreator`**
  (`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/service/GraphInstanceCreator.kt`,
  `objectGraph[objectLocation]!!` at :27) — **dead code**: zero callers anywhere in kzen-auto
  (whole-repo grep). ⚠️ **Already deleted by G3 (2026-07-19)** — this anchor no longer exists;
  nothing to do here.
- Other `createGraph` consumers (`LogicCompiler.kt:39`, `FlowRun.kt:116`, the per-flavour
  `*LogicCompiler`s, `PluginReportDefinitionRepository`) stay on `createGraph` — they run
  behind the client-side run gate (`HeaderRunController.runBlocker`) and are **out of scope**
  (noted in § Out of scope).

### kzen-auto — client (the drift/rescope)

- **The client computes definitions locally — nothing definition-related crosses the wire.**
  `ClientContext` builds a browser-side `DirectGraphStore` (`ClientContext.kt:70-75`) with
  `graphDefiner = GraphDefiner` (:63); `ClientStateGlobal.postConstruct(…, directGraphStore, …)`
  (:142) subscribes it, and `ClientState`
  (`kzen-auto-js/…/client/service/global/ClientState.kt`) carries the whole
  `graphDefinitionAttempt` (failures included); `graphStructure()` reads from it.
  `ClientStateGlobal.publishIfReady` fan-out wraps observers in try/catch →
  `window.alert("Observer error in ${observer::class.simpleName}: ${e.message}")`
  (`ClientStateGlobal.kt:135-136`) — the alert a broken report currently triggers.
- **`DefinitionErrors`** (`kzen-auto-js/…/client/util/DefinitionErrors.kt`, 68 lines): `Line`
  (:16-19), `all` (:24-28, **direct failures only**), `forDocument` (:32-34), `runBlocker`
  (:40-52 — `transitiveSuccessful` membership check, direct failure detail, else the generic
  `"Depends on an object that failed to define"`), `detail` (:58-67, prefers `attributeErrors`).
  Consumers: `ProjectController` banner (state `definitionErrors` :77; recompute :318/:325,
  :353/:358), `StageController` per-document red panel (state :53; recompute :148/:162; render
  `renderDefinitionErrors()` :222-258 — always-emitted container div for React child-index
  stability), `HeaderRunController` run gate (:160, :168-169).
- **`ReportStore.onClientState`**
  (`kzen-auto-js/…/objects/document/report/model/ReportStore.kt:81-136`):
  `ReportState.tryMainLocation(clientState) ?: return` (:86-87, **notation-only** — returns the
  location for any document that *is* a report in notation, defined or not), then
  `mainDefinition(clientState, reportMainLocation)` (:89) →
  `clientState.graphDefinitionAttempt.objectDefinitions[mainLocation]!!` (:139-143) — **the NPE
  when `main` failed to define**, surfacing as the observer-error alert.
- **`ReportState`** (`…/report/model/ReportState.kt`): `mainLocation`/`mainDefinition`
  non-nullable (:28-29); **`notationError: String? = null` already exists (:37)** with
  `withNotationError` (:149-152), currently fed by command-apply errors
  (`MirroredGraphError` sites in `ReportAnalysisStore.kt:127`, `InputSelectedStore.kt:275/:353`,
  `ReportOutputStore.kt:78`, `InputBrowserStore.kt:49-54`). Spec accessors `!!`-unwrap
  `mainDefinition.attributeDefinitions[…]!!` at :67, :73, :79, :93, :99, :105, :111.
- **`ReportController`**: renders nothing while `state.reportState == null` (:129-131) and
  already renders `notationError` as a crimson banner above the body (:138-147). So the
  existing `notationError` + the `StageController` panel are the natural error surfaces — no
  new UI component needed.
- **`ScriptValidator`** (`kzen-auto-jvm/…/server/objects/script/ScriptValidator.kt`) already
  returns structured per-step validation but works off `transitiveSuccessful`, so a define-time
  failure degrades to `StepValidation(null, "Not found")` (:117-118). Out of scope (noted).

## Pre-resolved questions

**Q1 — `GraphInstanceAttempt` shape.** Mirror of `GraphDefinitionAttempt`, minus
`graphStructure` (a `GraphInstance` has never carried structure; callers that need it already
hold the `GraphDefinition`):

```kotlin
// kzen-lib-common/…/model/instance/GraphInstanceAttempt.kt
data class GraphInstanceAttempt(
    val objectInstances: GraphInstance,
    val failures: ObjectLocationMap<ObjectCreationFailure>
) {
    fun successful(): GraphInstance { return objectInstances }
    fun hasErrors(): Boolean { return failures.map.isNotEmpty() }
}
```

**Q2 — `ObjectCreationFailure` ("which attribute, which reference, resolved-against-what",
creation side).** New file `model/instance/ObjectCreationFailure.kt`:

```kotlin
data class ObjectCreationFailure(
    val errorMessage: String,
    /** Strong references that could not be resolved / were required-but-empty (unsatisfiable objects). */
    val unsatisfiedReferences: List<UnsatisfiedReference> = listOf(),
    /** Locations of upstream objects whose own creation failed (this object was skipped, not attempted). */
    val failedDependencies: Set<ObjectLocation> = setOf()
) {
    data class UnsatisfiedReference(
        val objectReference: ObjectReference,
        val attributePath: AttributePath?,      // null for creator-related references
        val host: ObjectReferenceHost
    ) {
        override fun toString(): String {
            return "$objectReference at ${attributePath ?: "<creator>"} @ $host"
        }
    }
}
```

`GraphCreator`'s private `UnsatisfiedReference` (:17-24) is replaced by this public nested type
(it was private — promotion is additive). The private `UnsatisfiedSet` aggregate stays private.

**Q3 — structured per-attribute causes, definition side (additive only).**
`AttributeDefinitionFailure` gains two defaulted fields + a factory overload:

```kotlin
data class AttributeDefinitionFailure(
    val errorMessage: String,
    /** Which reference failed to resolve, when the failure is reference-shaped (else null). */
    val unresolvedReference: ObjectReference? = null,
    /** What the reference was resolved against (host scoping), when known. */
    val referenceHost: ObjectReferenceHost? = null
): AttributeDefinitionAttempt()

// companion:
fun failure(error: String): AttributeDefinitionFailure { return AttributeDefinitionFailure(error) }
fun failure(
    error: String, unresolvedReference: ObjectReference?, referenceHost: ObjectReferenceHost?
): AttributeDefinitionFailure { … }
```

`ObjectDefinitionFailure` gains one defaulted field (keyed by **`AttributePath`**, because
transitive causes live at nested paths like `addends.0`; top-level entries use
`AttributePath.ofName(attributeName)`):

```kotlin
data class ObjectDefinitionFailure(
    val partial: ObjectDefinition?,
    val missingObjects: ObjectLocationSet,
    val errorMessage: String,
    val attributeErrors: Map<AttributeName, String>,
    val attributeFailures: Map<AttributePath, AttributeDefinitionFailure> = mapOf()   // NEW
): ObjectDefinitionAttempt()
```

Both companion factories get a trailing `attributeFailures: Map<AttributePath,
AttributeDefinitionFailure> = mapOf()` parameter. `attributeErrors` stays populated exactly as
today (it is the surface `DefinitionErrors.detail` prefers) — `attributeFailures` is the
machine-readable sibling, never a replacement. Existing constructor/factory call sites compile
unchanged (defaults). Everything rebuilds from source via mavenLocal, so data-class
`copy`/`componentN` churn is a non-issue; kzen-auto-plugin (the third-party SPI) does not
expose these types.

**Q4 — where the dangling strong reference is recorded.** In a new
`GraphDefinitionAttempt.transitiveFailures` lazy (step 3), **not** in `AttributeObjectDefiner`
— define succeeds for a dangling reference by design (graceful degradation is a crown jewel;
we must not turn it into a define-time failure). `transitiveSuccessful` stays byte-identical
(hot path, memoized); `transitiveFailures` is a *separate* lazy computed on demand from the
final `transitiveSuccessful` — it re-scans only the dropped objects' references, so a clean
graph pays `O(direct failures)=0` and a broken one pays `O(dropped × refs)` once per notation
version (the `DirectGraphStore` attempt cache memoizes the instance).

**Q5 — locate near-miss computation (cheap).** Only ever computed on the throw path. The
`Locator.byName` map gives same-name candidates in O(1); `ObjectLocationMap` reuses its cached
`locator()`. Near-miss = (a) same name, different document ("same name elsewhere"), (b) same
name, same document, different nesting. No fuzzy name matching (pre-made: same name only).
Message spec (exact strings are implementer's choice; tests assert substrings):

```
Missing: <reference> (host: <host>); same name at: doc-a.yaml#Foo, doc-b.yaml#nested/Foo   [cap 5, "+N more"]
Missing: <reference> (host: <host>); no object named 'Foo' among 342 objects
```

Same-document-different-nesting candidates listed first. The old full document-path dump is
deleted. The `"Missing: "` prefix is **kept** (log continuity; nothing string-parses it — the
client guards are `!in coalesce` membership checks per `docs/js-architecture.md`).

**Q6 — wire shape: NO addition needed.** Definition failures never cross the wire: the client
runs `GraphDefiner` itself on the mirrored notation (`ClientContext.kt:63,70-75`) and renders
its own local `GraphDefinitionAttempt` — after this phase it additionally reads the new
`transitiveFailures` member of the same local object. Creation failures are server-side only
and reach the client through the **existing** `ExecutionFailure` / task-model DTOs (already
kotlinx post-SER5) — G6 improves the *message content* those DTOs carry, not their shape. No
new DTO, no `Long` fields, no serializer registration.

**Q7 — client guarded path.** Reuse what exists: on a broken report `main`,
`ReportStore.onClientState` publishes the failure through the **existing
`ReportState.notationError`** when a previous good state exists (frozen body + crimson banner +
StageController panel), and early-returns when none does (blank body; the StageController
panel above it names object/attribute — verified render path). `ReportState.mainDefinition`
stays **non-nullable** (an error-only `ReportState` cannot be constructed, which is fine —
the body is not rendered without a good definition). The seven spec-accessor `!!`s become a
shared guarded helper that throws a *named* error (belt-and-braces; unreachable once the store
guards).

**Q8 — `createGraph` delegation semantics (accepted behaviour deltas).** `createGraph` becomes
`tryCreateGraph` + throw-on-errors. Deltas: (a) a creator exception no longer propagates raw —
it is aggregated into the thrown `IllegalStateException` message (with the per-location
detail); (b) independent objects *after* a failing one still get created before the throw
(creators are construction-pure by contract); (c) the unsatisfied-set case still throws
`IllegalStateException` (was `check`), message now built from the same per-object failures.
Ambiguity (`tryLocate`) still **propagates as `IllegalArgumentException` out of both**
`createGraph` and `tryCreateGraph` — it is a leveling-time graph-shape error, not attributable
per-object, only reachable via global-host resolution (G1 as-built note), and pinned by
`GraphCreatorTest`. Audited callers (`ModelDetachedExecutor`, `ModelTaskRepository`, `FlowRun`,
`LogicCompiler`, JvmGraphTestUtils, tests): none catch a specific exception type from
`createGraph`.

**Q9 — `GraphInstanceCreator` (kzen-auto-common).** Dead code, zero callers — **deleted by G3
(2026-07-19)**; the file is gone, so nothing to leave untouched.

## Step-by-step implementation

### kzen-lib (steps 1–7)

**Step 1 — `AttributeDefinitionFailure` structured fields.**
`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/definition/AttributeDefinitionAttempt.kt`
per Q3. Import `ObjectReference`, `ObjectReferenceHost`.

**Step 2 — `ObjectDefinitionFailure.attributeFailures` + `AttributeObjectDefiner` population.**
- `ObjectDefinitionAttempt.kt` per Q3 (field + both factory defaults).
- `objects/base/AttributeObjectDefiner.kt`: alongside the existing
  `attributeErrors: MutableMap<AttributeName, String>` add
  `attributeFailures: MutableMap<AttributePath, AttributeDefinitionFailure>`; populate at each
  of the four failure sites —
  - :74 `"Unknown attribute definer: …"` → also
    `attributeFailures[path] = AttributeDefinitionFailure(msg, attributeDefinerRef, ObjectReferenceHost.global)`
    (definer refs resolve against the global coalesce);
  - :81 `"Definer missing: …"` → `AttributeDefinitionFailure(msg, attributeDefinerRef, ObjectReferenceHost.global)`;
  - :87 `"Attribute definer expected: …"` → same pattern;
  - :103-105 delegated failure → put the delegated `AttributeDefinitionFailure` **object**
    through unchanged (it may carry its own structured fields, e.g. from
    `WeakAttributeDefiner`'s `"Empty object reference - …"` at
    `objects/general/WeakAttributeDefiner.kt:97` — enriching Weak/Structural's own `failure(…)`
    calls with reference/host is optional polish, only where the values are at hand).
  where `path = attributeName.asAttributePath()` (i.e. `AttributePath.ofName`).
- De-flatten the object-level messages (cosmetic, nothing pins them):
  :126 `"Unfulfilled dependency : $attributeErrors"` →
  `"Unfulfilled dependency for: ${attributeErrors.keys.joinToString { it.value }}"`;
  :134 `"Failed: ${attributeErrors.keys}"` →
  `"Failed attribute(s): ${attributeErrors.keys.joinToString { it.value }}"`.
  Pass `attributeFailures` into both factory calls.

**Step 3 — `GraphDefinitionAttempt.transitiveFailures`.** New lazy on
`GraphDefinitionAttempt.kt` (leave `transitiveSuccessful` untouched):

```kotlin
/**
 * Why each object in notation is absent from [transitiveSuccessful]: direct definition
 * failures pass through as-is; an object that defined but was pruned gets a synthesized
 * failure naming, per reference, which attribute path, which reference, and what it was
 * resolved against (host). Derivative drops (reference resolves to another failed object)
 * carry that object in [ObjectDefinitionFailure.missingObjects] — follow it for the root cause.
 */
val transitiveFailures: ObjectLocationMap<ObjectDefinitionFailure> by lazy {
    val successfulKeys = transitiveSuccessful.objectDefinitions.map.keys
    val dropped = objectDefinitions.map.keys - successfulKeys
    if (dropped.isEmpty() && failures.isEmpty()) {
        return@lazy ObjectLocationMap.empty()
    }

    val builder = mutableMapOf<ObjectLocation, ObjectDefinitionFailure>()
    builder.putAll(failures.map)

    for (objectLocation in dropped) {
        val definition = objectDefinitions[objectLocation]!!
        val host = ObjectReferenceHost.ofLocation(objectLocation)
        val objectMetadata = graphStructure.graphMetadata.get(objectLocation)

        val attributeFailures = mutableMapOf<AttributePath, AttributeDefinitionFailure>()
        val missingObjects = mutableSetOf<ObjectLocation>()

        for (reference in definition.references()) {
            val objectReference = reference.objectReference
            if (GraphDefiner.isBootstrap(objectReference)) { continue }

            val attributePath = reference.attributePath

            if (objectReference.isEmpty()) {
                val nullable = /* same metadata walk as transitiveSuccessful :44-50 */
                if (!nullable && attributePath != null) {
                    attributeFailures[attributePath] = AttributeDefinitionFailure(
                        "Required reference is empty", objectReference, host)
                }
                continue
            }

            val location = objectDefinitions.locateOptional(objectReference, host)
            when {
                location == null -> {
                    val message = "Unresolved reference: $objectReference"
                    if (attributePath != null) {
                        attributeFailures[attributePath] =
                            AttributeDefinitionFailure(message, objectReference, host)
                    }
                    // creator-related (attributePath == null): folded into errorMessage below
                }
                location !in successfulKeys -> {
                    missingObjects.add(location)
                    if (attributePath != null) {
                        attributeFailures[attributePath] = AttributeDefinitionFailure(
                            "References failed object: $location", objectReference, host)
                    }
                }
            }
        }

        val attributeErrors = attributeFailures.entries.associate {
            it.key.attribute to "${it.key.asString()}: ${it.value.errorMessage}" }
        builder[objectLocation] = ObjectDefinitionFailure(
            definition,
            ObjectLocationSet(missingObjects),
            summarize(attributeFailures, missingObjects),   // e.g. "Dropped: unresolved 'X' at addends.0"
            attributeErrors,
            attributeFailures)
    }
    ObjectLocationMap(builder.toMutableMap().toPersistentMap())
}
```

Notes for the implementer: the nullability walk is copy-of `:43-52` (metadata may be null —
default non-nullable); `locateOptional` may throw the ambiguity `check` — identical to what
`transitiveSuccessful` already does on the same data, so no new throw surface; multiple bad
references per attribute name collide in `attributeErrors` (map keyed by `AttributeName`) —
last-wins is fine, `attributeFailures` keeps them all (distinct paths); keep the pass
allocation-light but don't micro-optimize — it only runs for broken graphs.

**Step 4 — locate near-miss messages.**
- `ObjectLocationSet.kt` — add to `Locator`:

```kotlin
internal fun missingMessage(reference: ObjectReference, host: ObjectReferenceHost?): String {
    val objectName = reference.name.objectName
    val sameName = objectName?.let { byName[it] }.orEmpty()
    return LocateErrors.missingMessage(
        reference, host, sameName, byName.values.sumOf { it.size })
}
```

  and rewrite both `locate` overloads (:73-87) to
  `?: throw IllegalArgumentException(missingMessage(reference, null-or-host))`.
- New `model/location/LocateErrors.kt` — `internal object LocateErrors` with the single
  formatter per Q5: header `"Missing: $reference"` + `" (host: $host)"` when host non-null and
  not global; then either the candidate clause (same-document-different-nesting first —
  candidate matches `reference.path ?: host?.documentPath` — then others; cap 5 with
  `"+N more"`) or the `"no object named '<name>' among <total> objects"` clause (also covers
  the empty-reference case: `reference.name.objectName == null` ⇒
  `"reference is empty"` clause instead).
- `ObjectLocationMap.kt` — narrow `private fun locator(): ObjectLocator` (:63) to return
  `ObjectLocationSet.Locator`, and rewrite both `locate` overloads (:37-51) to delegate:
  `?: throw IllegalArgumentException(locator().missingMessage(reference, host))`.

**Step 5 — `GraphInstanceAttempt` + `ObjectCreationFailure`.** New files
`model/instance/GraphInstanceAttempt.kt` and `model/instance/ObjectCreationFailure.kt` per
Q1/Q2.

**Step 6 — `GraphCreator.tryCreateGraph` + delegation.**
`service/context/GraphCreator.kt`:

1. Refactor `constructionLevels` to **return instead of throw** on unsatisfiable leftovers:
   change the tail (:157-163) to return a private
   `Leveling(levels: List<List<ObjectLocation>>, open: Set<ObjectLocation>, closed: Set<ObjectLocation>)`
   (drop the `check`; `closed` = `bootstrapLocations + (objectDefinitions.keys - open)` as
   today). The `tryLocate` ambiguity throw inside stays (Q8).
2. New public `tryCreateGraph(graphDefinition, environment = GraphEnvironment.empty):
   GraphInstanceAttempt`:

```kotlin
fun tryCreateGraph(
    graphDefinition: GraphDefinition,
    environment: GraphEnvironment = GraphEnvironment.empty
): GraphInstanceAttempt {
    val graphStructure = graphDefinition.graphStructure
    var partialObjectGraph = GraphDefiner.bootstrapObjects
    val locator = ObjectLocationSet.Locator()
    val leveling = constructionLevels(locator, graphDefinition, graphStructure.graphMetadata)

    val failures = mutableMapOf<ObjectLocation, ObjectCreationFailure>()
    failures.putAll(unsatisfiedFailures(leveling.open, leveling.closed, locator, graphDefinition))

    for (objectLocation in leveling.levels.flatten()) {
        val objectDefinition = graphDefinition.objectDefinitions[objectLocation]
        if (objectDefinition == null) {
            failures[objectLocation] = ObjectCreationFailure("Missing object definition")
            continue
        }

        if (failures.isNotEmpty()) {
            val failedDependencies = failedDependencies(
                objectDefinition, objectLocation, locator, failures.keys)
            if (failedDependencies.isNotEmpty()) {
                failures[objectLocation] = ObjectCreationFailure(
                    "Dependency creation failed: ${failedDependencies.joinToString()}",
                    failedDependencies = failedDependencies)
                continue
            }
        }

        val creatorPath = tryLocate(locator, objectDefinition.creator, ObjectReferenceHost.global)
        if (creatorPath == null) { failures[objectLocation] = ObjectCreationFailure(
            "Unable to resolve creator: ${objectDefinition.creator}"); continue }

        val creator = partialObjectGraph[creatorPath]?.reference as? ObjectCreator
        if (creator == null) { failures[objectLocation] = ObjectCreationFailure(
            "ObjectCreator expected: ${objectDefinition.creator}"); continue }

        val instance =
            try {
                creator.create(objectLocation, graphStructure, objectDefinition,
                    partialObjectGraph, environment)
            }
            catch (t: Throwable) {
                failures[objectLocation] = ObjectCreationFailure(
                    "Creation failed: ${t::class.simpleName}: ${t.message}")
                continue
            }
        partialObjectGraph = partialObjectGraph.put(objectLocation, instance)
    }

    return GraphInstanceAttempt(
        partialObjectGraph,
        ObjectLocationMap(failures.toPersistentMap()))
}
```

   - `unsatisfiedFailures(open, closed, locator, graphDefinition)`: per open location, walk
     `definition.references()` exactly as `findUnsatisfied` (:167-198) does, but attributed
     per-object and carrying `attributePath` — a `tryLocate == null` (or empty-required)
     reference becomes an `ObjectCreationFailure.UnsatisfiedReference`; a resolved-but-open/
     not-closed target becomes an entry in `failedDependencies`. Message e.g.
     `"Unsatisfiable: unresolved 'Foo' at addends.0"` / `"Blocked by unsatisfiable: <loc>"`
     (cycles surface as mutual `failedDependencies`).
   - `failedDependencies(definition, location, locator, failedKeys)`: guarded by
     `failures.isNotEmpty()` (zero cost on the happy path); resolve each of
     `definition.references()` via `tryLocate` with the object's host and collect resolutions
     in `failedKeys`.
   - `findUnsatisfied`/`UnsatisfiedSet` can be deleted once `unsatisfiedFailures` subsumes them
     (the old check-message is gone; see delegation below), or kept — implementer's call;
     prefer deletion (no dead code).
3. `createGraph` (:34-69) becomes the delegate:

```kotlin
fun createGraph(
    graphDefinition: GraphDefinition,
    environment: GraphEnvironment = GraphEnvironment.empty
): GraphInstance {
    val attempt = tryCreateGraph(graphDefinition, environment)
    check(! attempt.hasErrors()) {
        "Unable to create graph: ${attempt.failures.map.entries.joinToString { (loc, f) ->
            "$loc - ${f.errorMessage}" }}"
    }
    return attempt.objectInstances
}
```

**Step 7 — kzen-lib docs + tests + build.**
- `kzen-lib/docs/architecture.md`: in the three-layer flow section (around :38-65), update the
  `GraphCreator` line to mention `tryCreateGraph → GraphInstanceAttempt` (mirror of
  `GraphDefinitionAttempt`; `createGraph` delegates and throws), add one bullet for
  `transitiveFailures` (drop causes recorded; `transitiveSuccessful` unchanged), and note the
  near-miss locate messages where the Kahn/ambiguity bullet lives (:62-64). Keep it to ~6-8
  lines total — this doc is a map, not a spec.
- Tests: see § Tests (write them in this step, kzen-lib side).
- Build + publish:
  `cd kzen-lib && ./gradlew :kzen-lib-common:jvmTest :kzen-lib-common:jsTest :kzen-lib-jvm:test`
  then `./gradlew publishToMavenLocal`.

### kzen-auto (steps 8–11)

**Step 8 — server executors consume `tryCreateGraph` + `transitiveFailures`.**
New private helper (either duplicated ~10 lines in each file, or one `internal object
ExecutionGraphErrors` in `kzen-auto-jvm/…/server/service/exec/` — prefer the shared object):

```kotlin
internal object ExecutionGraphErrors {
    fun describe(
        location: ObjectLocation,
        definitionAttempt: GraphDefinitionAttempt,
        instanceAttempt: GraphInstanceAttempt
    ): String {
        val creationFailure = instanceAttempt.failures[location]
        if (creationFailure != null) {
            return "Could not create $location: ${creationFailure.errorMessage}"
        }
        val definitionFailure = definitionAttempt.transitiveFailures[location]
        if (definitionFailure != null) {
            val detail = definitionFailure.attributeErrors.entries
                .joinToString("; ") { "${it.key.value}: ${it.value}" }
                .ifEmpty { definitionFailure.errorMessage }
            return "$location failed to define: $detail"
        }
        return "Not found: $location"    // genuinely absent (not server-allowed / bad path)
    }
}
```

- `ModelTaskRepository.submit` (:128-139): keep the definition attempt in scope, switch to
  `tryCreateGraph`, delete the `:134` TODO:

```kotlin
val definitionAttempt = graphStore.graphDefinition()
val graphDefinition = definitionAttempt
    .transitiveSuccessful
    .filterDefinitions(AutoConventions.serverAllowed)

val instanceAttempt = graphCreator.tryCreateGraph(graphDefinition, environment())

val instance = instanceAttempt.objectInstances[taskLocation]?.reference
    ?: throw IllegalArgumentException(
        ExecutionGraphErrors.describe(taskLocation, definitionAttempt, instanceAttempt))
```

- `ModelDetachedExecutor.execute` (:31-56): same restructure;
  `?: return ExecutionFailure(ExecutionGraphErrors.describe(actionLocation, definitionAttempt, instanceAttempt))`.
  (Optionally fix the `"Not DetachedAAction"` typo at :47 while here — cosmetic, nothing pins it.)
- `ModelDetachedExecutor.executeDownload` (:59-78): same;
  `?: error(ExecutionGraphErrors.describe(…))` (download surface stays hard-fail — it returns a
  file body, not an `ExecutionResult`).

**Step 9 — client `DefinitionErrors` consumes `transitiveFailures`.**
`kzen-auto-js/…/client/util/DefinitionErrors.kt`:

- `detail(failure)` — unchanged logic (prefers `attributeErrors`); make it non-private if
  needed by the store guard below.
- `runBlocker(attempt, root)` (:40-52) — replace the generic fallback with a bounded
  root-cause chase over `transitiveFailures`:

```kotlin
fun runBlocker(attempt: GraphDefinitionAttempt, root: ObjectLocation): String? {
    if (root in attempt.transitiveSuccessful.objectDefinitions) { return null }

    var location = root
    val visited = mutableSetOf<ObjectLocation>()
    while (visited.add(location)) {
        val failure = attempt.transitiveFailures[location]
            ?: return "Failed to define"    // unreachable backstop
        val next = failure.missingObjects.values.firstOrNull { it !in visited }
        if (next == null || attempt.failures[location] != null) {
            return if (location == root) { detail(failure) }
                   else { "Blocked by $location: ${detail(failure)}" }
        }
        location = next
    }
    return "Failed to define (circular): $root"
}
```

  (Semantics: follow `missingObjects` toward the root cause; stop at a direct failure or a
  leaf; name the blocking object when it isn't `root` itself.)
- `all(attempt)` (:24-28) — extend to also list **root-cause transitive drops** (an entry in
  `transitiveFailures` that is not a direct failure and whose `attributeFailures` contain an
  own-reference cause, i.e. `missingObjects` empty ⇒ dangling/empty-required) while *skipping
  purely derivative drops* (`missingObjects` non-empty and no own unresolved reference) — a
  cascade of N dependents must not flood the `ProjectController` banner / `StageController`
  panel with N derivative lines. Keep the sort. `forDocument` inherits the improvement free.
- Update the file's header comment (:9-13) — the "silently drop" description is now stale.

**Step 10 — client `ReportStore`/`ReportState` guarded path.**
- `ReportStore.kt` — `mainDefinition` (:139-143) returns nullable
  (`objectDefinitions[mainLocation]` without `!!`); `onClientState` (:86-104) guards:

```kotlin
val reportMainDefinition = mainDefinition(clientState, reportMainLocation)
if (reportMainDefinition == null) {
    // Report failed to define: surface the origin instead of NPE-ing the observer chain.
    // StageController's definition-errors panel names object/attribute above the (blank or
    // frozen) body; when a previous good state exists, also pin the reason to the report UI.
    val blocker = DefinitionErrors.runBlocker(
        clientState.graphDefinitionAttempt, reportMainLocation)
    val previousState = state
    if (previousState != null && previousState.mainLocation == reportMainLocation) {
        val withError = previousState.withNotationError(
            blocker ?: "Report failed to define")
        if (state != withError) {
            state = withError
            observer?.onReportState(withError)
        }
    }
    return
}
```

  and the happy path must **clear** a definition-sourced `notationError` on recovery — the
  simplest correct form: when building `nextState` from `previousState` (:100-103), also
  `notationError = null` *only if* the previous error was set by this guard. Track that with a
  private `var definitionBlocked = false` flag in the store (set in the guard, cleared+error
  wiped on the next successful pass) so command-apply `notationError`s from the sub-stores are
  never clobbered.
- `ReportState.kt` — replace the seven `attributeDefinitions[…]!!` unwraps (:67, :73, :79,
  :93, :99, :105, :111) with one guarded helper:

```kotlin
private fun attributeDefinition(attributeName: AttributeName): AttributeDefinition {
    return mainDefinition.attributeDefinitions[attributeName]
        ?: throw IllegalStateException(
            "Report attribute '${attributeName.value}' is not defined for $mainLocation " +
            "- fix the document notation")
}
// e.g.:
fun inputSpec(): InputSpec {
    val definition = attributeDefinition(ReportConventions.inputAttributeName)
    return (definition as ValueAttributeDefinition).value as InputSpec
}
```

- `ReportController` — no change (null-state renders nothing :129-131; `notationError` banner
  :138-147 already renders the guard's message).

**Step 11 — trackers + docs.**
- Tick Phase 6 in `kzen/plans/2026-07-16_graph-improvements.md`'s progress tracker + append an
  as-built note (include the drift rescope from this plan's status block and any deviation);
  strike N5 in `2026-07-16_master-plan.md`; delete (or mark done) this file per
  `plans/next/README.md`.
- kzen-auto docs: no architecture-doc section describes the executor error paths or the report
  client guard — no kzen-auto doc change required (the kzen-lib doc change in step 7 is the
  doc-lead for this phase). If the implementer touches `DefinitionErrors`' header comment
  (step 9) that suffices client-side.
- Stage every new file as it is written (`git add <explicit path>` in each repo; stage only,
  never commit).

## Tests

### kzen-lib-jvm — `GraphDefinitionTransitiveFailureTest.kt` (new)

`kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/GraphDefinitionTransitiveFailureTest.kt`,
modeled on `GraphCreatorTest` (inline `document(body)` + `JvmGraphTestUtils.readNotation()
.withNewDocument(...)` + `JvmGraphTestUtils.graphDefinition(notation)`). Fixtures already
exist: `StringHolderRef` (`kzen-lib-jvm/src/test/…/objects/StringHolderRef.kt` — strong
non-nullable `stringHolder: StringHolder` reference, metadata via KSP class mirror, archetype
pattern in `src/test/resources/notation/test/kzen-test.yaml:40-42`).

1. **`dangling strong reference names attribute and reference`** (the constituent plan's test
   #1): document `Dangling: {class: tech.kzen.lib.server.objects.StringHolderRef, stringHolder:
   NoSuchObject}`. Assert: `attempt.failures` does **not** contain `Dangling` (defines fine —
   pins the graceful-degradation crown jewel); `Dangling !in attempt.transitiveSuccessful
   .objectDefinitions`; `attempt.transitiveFailures[danglingLocation]` non-null with
   `attributeFailures[AttributePath.parse("stringHolder")]` whose `unresolvedReference ==
   ObjectReference.parse("NoSuchObject")` and whose `referenceHost` names the document; and
   `attributeErrors[AttributeName("stringHolder")]` contains `"NoSuchObject"`.
2. **`empty required reference is named`**: same but `stringHolder: ""`. Assert
   `transitiveFailures` entry with message containing `"Required reference is empty"` at
   `stringHolder`.
3. **`derivative drop carries the failed dependency`**: `Bad: {…, stringHolder: NoSuchObject}`
   + `Dependent: {…, stringHolder: Bad}` (StringHolderRef→StringHolderRef is type-loose at
   definition level — fine, nothing is created). Assert `transitiveFailures[dependent]` has
   `missingObjects == {badLocation}` and `attributeFailures[stringHolder].errorMessage`
   contains `"failed object"` — and that a healthy sibling (e.g. `is: StringHolder` +
   `value: ok`) is still in `transitiveSuccessful` (no over-pruning regression).

### kzen-lib-jvm — `GraphCreatorTryCreateTest.kt` (new) + fixture

New fixture `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/objects/ThrowingInit.kt`
(kzen-lib-jvm *does* run KSP over test sources — `kspTest(project(":kzen-lib-reflect-ksp"))`
with `KzenLibJvmTestModule`, `kzen-lib-jvm/build.gradle.kts:29,35-36` — unlike kzen-auto's
no-kspTest gotcha, which does not apply here):

```kotlin
@Reflect
class ThrowingInit {
    init { throw IllegalStateException("deliberate construction failure") }
}
```

Tests (inline documents, `JvmGraphTestUtils.graphDefinition(notation)` for the attempt):

1. **`throwing creator yields failure without aborting the graph`** (the constituent plan's
   test #2): document with `Bad: {class: …ThrowingInit}` + an unrelated healthy object (e.g.
   `Good: {is: StringHolder, value: ok}` — wait, `StringHolder` is abstract; use
   `Good: {is: HelloWorldHolder}`-style or `class: …StringHolder` + `value` + `meta` as in
   `kzen-test.yaml:2-12`). `GraphCreator.tryCreateGraph(attempt.transitiveSuccessful
   .filterTransitive-or-full, JvmGraphTestUtils.testEnvironment)`. Assert:
   `instanceAttempt.failures[badLocation]` non-null, `errorMessage` contains
   `"deliberate construction failure"`; `Good`'s location **is** in
   `instanceAttempt.objectInstances`; no exception escaped.
2. **`dependent of a throwing creator is skipped with failedDependencies`**: add
   `DependsOnBad: {class: …StringHolderRef, stringHolder: Bad}`. Assert
   `failures[dependsLocation].failedDependencies == setOf(badLocation)` and it is absent from
   `objectInstances`.
3. **`createGraph delegates and throws an aggregate`**: same notation,
   `assertFailsWith<IllegalStateException> { GraphCreator.createGraph(…) }`, message contains
   the bad location string and `"deliberate construction failure"`.
4. **`unsatisfied reference becomes a per-object failure instead of a throw`**: use
   `attempt.successful()` (the **unpruned** definition — contains the dangling-ref object) of
   a `Dangling` document from above; `tryCreateGraph` must **not** throw; assert
   `failures[danglingLocation].unsatisfiedReferences` names `NoSuchObject` at
   `stringHolder`.
5. **Regression guard**: the existing
   `GraphCreatorTest.Ambiguous reference reports all candidates` must still pass unchanged
   (ambiguity propagates through the delegation — do not catch `tryLocate`'s throw).

### kzen-lib-common — `LocateErrorMessageTest.kt` (new, commonTest)

`kzen-lib-common/src/commonTest/kotlin/tech/kzen/lib/common/model/LocateErrorMessageTest.kt`
(package `tech.kzen.lib.common.model`, beside `ObjectLocationTest`). Pure
`ObjectLocationSet.Locator` — no fixtures. Cases (assert substrings, not full messages):

1. Same name in two other documents; locate with a path-qualified reference that matches
   neither → message contains the reference, both candidate locations, and **not** an
   unrelated document that holds no same-name object.
2. Same document, different nesting (`a.yaml#steps/Foo` exists, locate `Foo` with nesting
   root + host `a.yaml`… note: root-nesting reference does not match nested candidate) →
   message lists the nested near-miss.
3. No such name at all → message contains `"no object named"` and the total count.
4. `ObjectLocationMap.locate` produces the same class of message (build a small map directly).

### kzen-auto — automated

No new automated kzen-auto tests (per the constituent plan's verification section — the
kzen-auto proof is the UI smoke). The existing suites are the regression net:
`:kzen-auto-jvm:test` (Job suite + `FormulaStepTest` drive `tryDefine`/`createGraph`-adjacent
paths heavily) and the `kzen-auto-js` compilation (browser test task) prove the client still
binds against the new kzen-lib API.

## Verification

kzen-lib (run from `C:\Users\ostro\IdeaProjects\kzen-lib`):

```powershell
./gradlew :kzen-lib-common:jvmTest :kzen-lib-common:jsTest :kzen-lib-jvm:test
./gradlew publishToMavenLocal
```

(Baseline suites named in the constituent plan's ground rules — `StructuralNotationTest`,
`AddObjectTest`, `RenameObjectTest`, `SetDocumentObjectsTest`, `MultipleInheritanceTest`,
`YamlNotationParserTest`, `GraphDefinitionTransitiveTest`, `AutowiredTest`, `LocateTest`,
`NestedClassTest`, `ServiceInjectionTest`, `RunEngineTest`, `GraphCreatorTest` — all ride the
two commands above. `RunEngineTest.migrateConcurrentChildren…` has a known flake; re-run in
isolation if it trips.)

kzen-auto (from `C:\Users\ostro\IdeaProjects\kzen-auto`):

```powershell
./gradlew :kzen-auto-jvm:test --refresh-dependencies
./gradlew :kzen-auto-js:build -x test -PjsWatch
```

Manual UI smoke (the constituent plan's kzen-auto verification — needs the browser):

```powershell
./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch
```

1. Create a **new scratch Report document** via the UI (its yaml lands under
   `notation/main/` as the user's working doc — the implementer created it this session, so
   editing **that one file** is in-scope; touch nothing else there).
2. Break it: stop the server (or edit live — the file watcher picks it up), open the scratch
   report's yaml and set `filter: ""` on `main` (a spec attribute the G5
   `CodecAttributeDefiner` will reject → **direct** `ObjectDefinitionFailure` with
   `attributeErrors = {filter: …}`), save, reload the browser.
3. Confirm: **no** `window.alert("Observer error in ReportStore…")`; the `StageController`
   red panel names `<doc>#main` and the `filter` attribute; `ProjectController`'s banner shows
   the same line; the report body is blank (or frozen with the crimson
   `Error: …` banner if it was open before the break); the Run control (if the doc is
   logic-gated) is disabled with the reason.
4. Transitive case: create a scratch **Script**, add a step, then break a reference (e.g. a
   ControlStep `loop:` naming a nonexistent step, or raw-edit a step's strong reference to a
   missing name via the Script Raw tab). Confirm the run gate / panel now names the step and
   reference (`"Blocked by <step>: …Unresolved reference…"`) instead of
   "Depends on an object that failed to define".
5. Detached-path check: with the broken report from (2), trigger a report panel action that
   hits the detached executor (e.g. input browse against the broken doc) and confirm the
   server responds with the named `"… failed to define: filter: …"` message rather than
   `"Not found: …"` (visible in the network tab / server log).
6. Delete the scratch documents via the UI when done.

Optional (UI-facing phase per ground rules): `./gradlew :kzen-auto-test:selfTest` (opens
Chrome, spawns two JVMs) — proves the happy-path run pipeline end-to-end after the executor
rewiring.

## Risks & gotchas

- **`transitiveSuccessful` must stay byte-identical.** All new definition-side analysis lives
  in the *separate* `transitiveFailures` lazy; do not refactor the fixpoint "while you're
  there" — it is the hot path G1 cached, and `GraphDefinitionTransitiveTest` pins its digest
  semantics only indirectly.
- **Do not turn dangling references into define-time failures.** Graceful degradation on broken
  notation (startup must survive) is a crown jewel; the dangling object must still *define*
  (test 1 asserts `failures` stays empty for it).
- **`GraphCreatorTest`'s ambiguity pin.** `tryLocate`'s `"Ambiguous reference"` throw must keep
  propagating out of both `createGraph` and `tryCreateGraph` (don't wrap the leveling phase in
  a catch-all).
- **`createGraph` behaviour deltas (Q8) are accepted, but watch two things**: (a)
  `ModelDetachedExecutor.execute` currently lets a `createGraph` throw escape as a raw 500 —
  after step 8 creation failures for *the requested action* become soft `ExecutionFailure`s;
  a creation failure of an **unrelated** object in the (still whole-project, pre-G3) graph no
  longer aborts the call at all, which is a strict improvement but means a broken unrelated
  document no longer blocks every detached action — mention it in the as-built note; (b) the
  aggregate exception message can get long on a badly broken graph — that's fine (server log
  only).
- **Client fan-out alert discipline.** The `ReportStore` guard must not throw under any input
  (the `ClientStateGlobal.publishIfReady` catch turns any throw into a modal alert, and the
  initial `observe()` replay at `ClientStateGlobal.kt:103` isn't even wrapped). Early-return
  is the failure mode of choice.
- **`notationError` ownership.** The report guard shares `ReportState.notationError` with the
  command-apply error path (`MirroredGraphError` sites) — the `definitionBlocked` flag in
  step 10 is what stops the guard's *clear* from wiping a sub-store's error. Keep it.
- **`attributeErrors` map-key collisions** (`AttributeName`-keyed) when several nested paths
  under one attribute fail: accepted — `attributeFailures` (path-keyed) holds the full set.
- **`locateOptional` ambiguity `check` inside `transitiveFailures`**: same call the existing
  fixpoint makes on the same data — no new throw surface, but don't "improve" it to
  `locateAll` with different semantics.
- **JS side compiles against the new API**: `transitiveFailures` and the new fields are
  commonMain — no expect/actual, no JS-specific work; but forgetting
  `--refresh-dependencies` after `publishToMavenLocal` yields confusing "unresolved reference:
  transitiveFailures" errors in kzen-auto.
- **Message-content churn**: `"Unfulfilled dependency : {…}"` → new summary; the old text is
  documented in kzen-auto's `ChannelTypeDefiner` comment and the graph-plan prose but pinned
  by no test. `DefinitionErrors.detail` prefers `attributeErrors`, so the UI text mostly
  changes only where it was the flattened fallback.
- **File safety in the manual smoke**: only the scratch documents the implementer creates may
  be edited/deleted under `notation/main/`; everything else there is the user's working data.

## Out of scope (decided — do not creep)

- **Run-compile path** (`LogicCompiler`, `FlowRun`, per-flavour compilers,
  `ServerLogicController`) staying on `createGraph`/`filterTransitive`: the client run gate
  (`HeaderRunController.runBlocker`) already blocks broken roots pre-run, and G6's improved
  messages reach the residual throw paths anyway. Converting the compile pipeline to
  attempt-typed results is a different (heavier) change with no pre-made decision.
- **`ScriptValidator`'s `"Not found"` degrade** for define-failed steps — a natural follow-up
  consumer of `transitiveFailures`, but not in the phase's scope.
- **`GraphDefiner.tryDefine`'s internal `coalesce.locate` throws** (:128, :162) for dangling
  definer/creator references in the meta tower: message improves via step 4; graceful-failure
  conversion is out.
- **`GraphNotation` "Missing: $objectLocation"** (`GraphNotation.kt:130`) and other non-locate
  "Missing" sites (kzen-auto `ReportWorkPool` etc.): unrelated surfaces.
- **`GraphInstanceCreator`** (dead code): leave.
- **Wire-shape additions** (Q6: none needed) and any command-taxonomy / reference-resolution
  semantics changes (constituent plan's standing exclusions — host-document scoping stays; the
  `TODO: reverse breadth first search` at `ObjectLocationSet.kt:58` stays).
- **Near-miss fuzzy matching** (edit-distance name suggestions): same-name-only, per the
  pre-made decision.
