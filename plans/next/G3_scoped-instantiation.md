# G3 — scoped instantiation + instance caching — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 by a planning session from
> `2026-07-16_graph-improvements.md` Phase 3 (3a/3b/3c); the design decisions are pre-made there —
> this document elaborates them into execution-ready steps and does not re-litigate. Every anchor
> below was verified against live code on 2026-07-19 (post SER2–SER5, Y/W1–W8, G5, G7, TP1/TP3/TP4).
> The constituent plan remains the authority on rationale; **where a premise no longer holds, the
> drift is called out plainly and the sub-item rescoped** (3a — see below; same precedent as
> graph-plan 5b). Executor: one session; explicit split point at the end of Part B.

## Scope & goal

Stop building whole-project (or whole-document) instance graphs to obtain one object, and stop
re-building an unchanged object per REST call. Three sub-items, re-scoped against live code:

- **3a (Flow per-vertex closure) — RESCOPED to survey-pin + measurement, no production change.**
  The constituent plan's premise ("`FlowRun.createInstance` builds `filterTransitive(documentPath)`
  per vertex execution", anchors `FlowRun.kt:434-441` / `:394-406`) **no longer holds**: current
  `FlowRun` builds **one** graph per run (`FlowRun.kt:113-116`, comment `:86-88`) and every vertex
  execution and retrace reads from that single `runInstance` (`instanceFor` `:464-467`, `retrace`
  `:427-433`). The per-execution rebuild G3a was designed to eliminate has already been eliminated
  (by the engine-rewrite era Flow work), and per-vertex closures would now be a *de-optimization*
  for the common full-run case (N `createGraph` calls, each re-paying the bootstrap tower, vs one
  call over the same total object set). What remains of 3a: a test that **pins the structural
  invariant** the survey established (per-vertex closures are self-contained — see findings) and
  **captures the closure-vs-document measurements** for the as-built note, per the constituent
  plan's mandate. The single-object `GraphCreator.createObject` API **stays deferred**.
- **3b (detached/task executors) — the real remaining hot path, as planned.**
  `ModelDetachedExecutor.execute`/`executeDownload` and `ModelTaskRepository.submit` build the
  **entire server-allowed project graph per REST call** and discard it. Change to: serverAllowed
  filter → `filterTransitive(actionLocation)` closure → digest-keyed `GraphInstanceCache` reuse.
  Mandatory statelessness survey: **done, recorded below — all 10 implementations are stateless**;
  the archetype-attribute opt-out is implemented anyway (third-party escape hatch), and the
  statelessness contract is documented on `DetachedAction` / `DetachedDownloadAction` / `ManagedTask`.
- **3c (GraphEnvironment provider registration) — as planned, with drift corrections.**
  kzen-lib `GraphEnvironmentBuilder`/`MapGraphEnvironment` gain provider registration with memoized
  first-resolve; `KzenAutoContext` builds its environment eagerly (providers for the two cyclic
  members) and the `() -> GraphEnvironment` thunk parameters of `ServerLogicController` /
  `ModelDetachedExecutor` / `ModelTaskRepository` become plain `GraphEnvironment`. Drift: the
  constituent plan's thunk-site list included `ClientContext` and the plugin repo — **neither takes
  a thunk today** (verified; see findings) — and one *dead* thunk site exists that the plan didn't
  list (`GraphInstanceCreator`, deleted here).

## Dependencies & coordination

- **G2 ✓** — `GraphDefinition.transitiveDigest` (`GraphDefinition.kt:129-144`) is the 3b cache key
  basis. **G1 ✓** — `DirectGraphStore` caches the `GraphDefinitionAttempt` per notation digest, so
  the per-call `graphStore.graphDefinition()` in the executors is a cache hit and the digest
  recompute is cheap (memoized `ObjectNotation` digests).
- **Repo order**: kzen-lib first (Part A), `./gradlew publishToMavenLocal`, then kzen-auto with
  `--refresh-dependencies`. kzen-auto is opened as its own IntelliJ project (umbrella caveat).
- **No open-track conflicts**: G6 (error surface) touches `GraphInstanceAttempt`/locate errors —
  the `// TODO: add GraphInstanceAttempt` at `ModelTaskRepository.kt:134` is deliberately
  **preserved** (moved with the code). J-track (Report subsumption) touches `ReportDocument`'s run
  path, not the detached executors. Nothing here touches notation YAML under `notation/main/`.
- **SPI compatibility**: all kzen-lib changes are additive (a new `put` overload, kdoc). No
  `ObjectDefiner`/`ObjectCreator` signature changes.
- **kzen-project**: verified zero implementations of `DetachedAction` / `DetachedDownloadAction` /
  `ManagedTask` and zero `GraphInstanceCreator` / env-thunk references — no downstream coordination
  needed beyond the mavenLocal publish order.

## Current-state findings (all anchors verified 2026-07-19)

### The two hot-path executors (3b targets)

| Anchor | Finding |
|---|---|
| `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/exec/ModelDetachedExecutor.kt:19-23` | Constructor `(graphStore: LocalGraphStore, graphCreator: GraphCreator, environment: () -> GraphEnvironment)` |
| `ModelDetachedExecutor.kt:31-56` (`execute`) and `:59-78` (`executeDownload`) | Both build `graphStore.graphDefinition().transitiveSuccessful.filterDefinitions(AutoConventions.serverAllowed)` then `graphCreator.createGraph(<whole filtered project>, environment())` per call; instance discarded after the call. (`:47` has a pre-existing typo "Not DetachedAAction" — fix in passing.) |
| `ModelTaskRepository.kt:32-38` | Constructor with the same thunk (`:35`); `LocalGraphStore.Observer` for delete/rename bookkeeping (unrelated to instantiation). |
| `ModelTaskRepository.kt:128-141` (`submit`) | Same whole-project build; `// TODO: add GraphInstanceAttempt for error reporting` at `:134` (phase 6 — keep). |
| Construction sites | **Only** `KzenAutoContext` constructs these two and `ServerLogicController` (verified by grep); tests go through `KzenAutoContext.forTest()`. |

### GraphDefinition / GraphCreator machinery (kzen-lib)

| Anchor | Finding |
|---|---|
| `kzen-lib-common/.../model/definition/GraphDefinition.kt:43-54` | `filterDefinitions(allowed: Set<DocumentNesting>)` and predicate overload. |
| `GraphDefinition.kt:57-100` | `transitiveClosure(Collection<ObjectLocation>)` — **`require(objectLocation in objectDefinitions) { "Missing: …" }` on each seed (`:58-62`)**, so the 3b not-found guard must run *before* any digest/filter call. BFS over `ObjectDefinition.references()`, bootstrap refs skipped. |
| `GraphDefinition.kt:103-117` | `filterTransitive(Collection | ObjectLocation | DocumentPath)`; the DocumentPath overload seeds **all** of the document's definition keys (`documentObjectLocations`, `:147-152`) — which is why Flow uses it (the Flow root's `vertices` list is weak `NestedList` refs and can't serve as a closure root). |
| `GraphDefinition.kt:121-144` | `transitiveDigest(Collection | DocumentPath)` — ordered combine over closure members' location + coalesced `ObjectNotation` digest; missing/synthesized members digest as null. **Covers closure members' own notation only — NOT their inheritance ancestors** (see the cache-key refinement in Pre-resolved questions). |
| `ObjectDefinition.kt:54-66, 114-153` | `references()` = non-weak attribute refs + creator-related. **Weak refs excluded** (`definition.weak && !includeWeak` skip at `:121-129`); `ValueAttributeDefinition` / `ServiceAttributeDefinition` contribute nothing (verified first-hand). |
| `GraphCreator.kt:34-37` | `createGraph(graphDefinition, environment: GraphEnvironment = GraphEnvironment.empty)`. Missing scheduled definition ⇒ `"Missing object definition: …"` (`:46-47`); unsatisfiable ⇒ `"Unable to satisfy: …"` (`:157-161`). Dependency edges come from the same weak-excluding `references()` (`:109`), so a `filterTransitive(location)` set is create-complete by construction. |
| `GraphEnvironment.kt` / `GraphEnvironmentBuilder.kt` / `MapGraphEnvironment.kt` (kzen-lib-common `service/context/environment/`) | Builder has eager `put(className, service: Any)` only; `MapGraphEnvironment.resolve` self-resolves `GraphEnvironment.className` to itself (`MapGraphEnvironment.kt:13-15` — load-bearing for `ScriptValidator`'s `@Service environment: GraphEnvironment` param) and throws a named error for missing services (`:17-19`). |
| `kzen-lib-common/.../platform/PlatformSynchronized.kt` | `platformSynchronized` expect/actual exists (G1 used it for `ReflectionRegistry`) — available if needed; the provider memo below uses plain `by lazy` (common-code, SYNCHRONIZED default on JVM) instead. |

### 3c thunk-site map (drift vs constituent plan)

| Site | Status |
|---|---|
| `KzenAutoContext.kt:131-132` (`modelTaskRepository`), `:174-177` (`serverLogicController`), `:188-189` (`detachedExecutor`) | The three live `{ graphEnvironment }` thunks. Rationale comment block `:170-173`; lazy-env comment `:209-212`; `graphEnvironment` itself `by lazy` at `:213-233` (17 registrations; the cyclic ones are `serverLogicController` `:231` and `logicTrace` `:224`). |
| `ServerLogicController.kt:93` (param), `:910` (sole invocation — `LogicCompilerServices(environment(), …)` inside `compile`) | Thunk consumed exactly once per compile. Env reaches Job/Script/Flow through `LogicCompilerServices` — the "Job suite for 3c" verification (the constituent plan's "EngineJobControl" naming is loose; no env reference exists in `server/exec/job/` — env threads via the compiler services). |
| `kzen-auto-common/.../service/GraphInstanceCreator.kt:12-16` | **Dead code** — a fourth thunk site with *zero* construction sites anywhere in kzen-auto or kzen-project (verified by grep). Delete. Not `@Reflect`, so no KSP/codegen impact. |
| `kzen-auto-js/.../service/ClientContext.kt:110-122` + `Main.kt:53` | Client env is `by lazy` and passed **directly** to `createGraph` — **no thunk exists client-side**. The constituent plan's "and ClientContext register providers directly" has nothing to convert: **no ClientContext change** (record in as-built). |
| `PluginReportDefinitionRepository.kt:19-23` | Takes **no environment at all** (uses `createGraph`'s `GraphEnvironment.empty` default — `PluginDocument` has no `@Service` params) and **already scopes with `filterTransitive`** (`:83-85`, `:184-185`, `:220-221`) with its own digest cache. The kzen-auto `docs/architecture.md:185` sentence naming "the plugin repo" as a deferred-provider consumer is **stale** — corrected by the 3c doc step. No code change here. |

### 3a survey result (mandatory, per constituent plan) — per-vertex closures are self-contained

- **Channels are define-time values, not references.** `FlowWiring.define` (kzen-auto-common
  `objects/document/flow/FlowWiring.kt:111-155`) returns `ValueAttributeDefinition` wrapping a
  freshly allocated `MutableOptionalInput`/`MutableRequiredInput`/`MutableFlowOutput` —
  contributes nothing to `references()`.
- **Sibling vertices are connected by grid geometry, not references.** `EdgesDefiner`
  (kzen-auto-common `.../flow/EdgesDefiner.kt:20-61`) emits value `EdgeDescriptor`s
  (orientation + row/column ints, no `ObjectLocation`); `edges` lives on the Flow root, not on
  vertices; vertices carry only `row`/`column` scalars. Routing goes through `FlowMatrix`
  coordinates.
- **`RunLogicVertex`'s child link is weak by design.** `instructions` is `by: Nominal`
  (`kzen-auto-jvm/src/main/resources/notation/auto-jvm/flow/flow-vertex.yaml:172-191`) →
  `WeakAttributeDefiner` → `ReferenceAttributeDefinition(weak = true)` → excluded from
  `references()`/closures. The callee is compiled separately (`FlowLogicCompiler.kt:67-77`), and
  `LinkedLogicDocuments.kt:16-24` exists precisely because the callee never enters the caller's
  closure. So `filterTransitive(vertexLocation)` ≈ {the vertex itself} and `createGraph` on it
  succeeds standalone (same pattern `LogicCompiler.kt:23-29, 38-39` already relies on).
- **No vertex uses `AutowiredAttributeDefiner`** or any whole-graph create-time scan.
- **Conclusion**: `filterTransitive(vertexLocation)` *would* suffice — but the hot spot it was
  aimed at is already gone (build-once-per-run, `FlowRun.kt:113-116`), and the per-vertex
  `GraphDefinition` cache the plan sketched is subsumed by the single `runInstance` field (fixed
  for the run; a live-edit migrate builds a **new `FlowRun`** — `FlowRun.kt:86-88` — so
  invalidation-on-migrate holds by construction). Rescope per Scope & goal.

### 3b statelessness survey (mandatory, per constituent plan) — the table

Every concrete implementation in kzen-auto (kzen-project: **none**; kzen-lib: interfaces only).
All are `@Reflect`, all fields are `private val`, none has a `var`, mutable-collection field,
counter, or stored resource handle. Classification: **config** = immutable notation-derived value;
**service** = injected `@Service` singleton reference (mutable *referent* owned elsewhere is fine —
the instance itself stays stateless).

| Class (kzen-auto-jvm unless noted) | Interface(s) | Fields → classification | Cache-safe? |
|---|---|---|---|
| `server/objects/target/TargetLocateAction.kt:30` | `DetachedAction` | `graphStore` (service), `targetLocator` (service) | ✅ |
| `server/objects/target/ScreenshotTaker.kt:18` | `DetachedAction` | none (companion: `const val` only) | ✅ |
| `server/objects/logic/LogicTraceEndpoint.kt:23` | `DetachedAction` | `logicTrace` (service) | ✅ |
| `server/objects/custom/test/AdhocDetached.kt:11` | `DetachedAction` | `named: AdhocNamed` (config collaborator) | ✅ |
| `server/objects/registry/ObjectRegistryDocument.kt:18` | `DetachedAction` | `classes: ClassListSpec` (config) | ✅ |
| `server/objects/plugin/PluginDocument.kt:28` | `DetachedAction` | `jarPath: String`, `selfLocation` (config). Class loaders / jar reads are **per-call locals** — resource content is re-read at execute time, so a jar replaced under an unchanged notation digest is still picked up. | ✅ |
| `server/objects/script/ScriptValidator.kt:32` | `DetachedAction` | 4 services (`graphStore`, `graphCreator`, `environment: GraphEnvironment`, `scriptValidationCache`) | ✅ |
| `server/objects/report/ReportDocument.kt:68` | `DetachedAction`, `DetachedDownloadAction`, `LogicDocument` | 8 config specs (`input`…`output`, `selfLocation`) + 6 services | ✅ |
| `server/objects/custom/test/AdhocTask.kt:14` | `ManagedTask` | `named` (config); the mutable `Run` thread is created per `start()`, not stored | ✅ |

**Verdict: no implementation needs the opt-out.** The opt-out attribute is still implemented (a
third-party action in a Custom/registry document is the extension surface kzen promises; the
escape hatch must not require a shared-code edit — the standing god-object rule). Interface
anchors for the kdoc step: `DetachedAction` (kzen-auto-common
`paradigm/detached/DetachedAction.kt:7-11` — note: **no** `api/` subdir), `DetachedDownloadAction`
(kzen-auto-jvm `server/paradigm/detached/DetachedDownloadAction.kt:6-10`), `ManagedTask` (kzen-lib
`exec/task/ManagedTask.kt:6-11`). None currently has kdoc. Only production `ManagedTask` note:
there are **zero** production implementers (Report is `LogicDocument` now) — the task-side change
is parity/hygiene reachable via Custom-document adhoc tasks.

### Test-harness facts (for the Tests section)

- `ScriptValidationCacheTest.kt:110-141` proves `KzenAutoContext.forTest()` + `context.graphEnvironment`
  works in tests, and its comment records that **the full `ModelDetachedExecutor` graph is not
  satisfiable in the test environment** — after 3b the executor builds only the action's closure,
  so it becomes directly drivable from a test (new integration coverage for free).
- Offline-edit pattern (no store writes — `forTest`'s store would write real files):
  `AutoTestUtils.readNotation()` + `NotationReducer().applyStructural(notation, UpsertAttributeCommand(…))`
  + `AutoTestUtils.graphDefinitionAttempt(edited).transitiveSuccessful` (same file, `:149-181`).
- Test notation lives in `kzen-auto-jvm/src/test/resources/notation/test/*.yaml` (visible to both
  `AutoTestUtils.readNotation()` and `forTest()`'s classpath scan, which excludes only `main/`).
  Notation-instantiated fixture *classes* must live in `src/main` (no `kspTest` — standing gotcha);
  `AdhocDetached`/`AdhocNamedImpl`/`AdhocTask` already do.
- Fixture shape precedent: `notation/main/Custom.yaml` (read-only reference — never edit) declares
  `AdhocDetached` archetype with `meta: named: {is: AdhocNamed, …}` and instances `is: AdhocDetached`,
  `named: AdhocNamedImpl`.

## Pre-resolved questions

1. **3a verdict** — no production change (rescope, drift documented above). Deliverables: the
   invariant-pinning test + measurement capture + as-built note. `GraphCreator.createObject` stays
   deferred.
2. **3b cache shape** — `GraphInstanceCache` is a plain synchronized JVM class in
   `kzen-auto-jvm/.../server/service/exec/` that takes the **already-filtered** `GraphDefinition` as
   a call parameter (the `serverAllowed` filter-then-closure policy stays at the paradigm layer;
   the cache is generic and offline-unit-testable, mirroring `ScriptValidationCacheTest`'s harness).
   Entry = digest + the located `ObjectInstance` (as-built simplification of the plan's "holding the
   created GraphInstance" — the located instance is what both callers consume; the rest of the tiny
   scoped graph is reachable from it or garbage). Access-ordered `LinkedHashMap` LRU, `maxEntries = 32`
   (bounds stale entries from renamed/deleted actions; entries are memory-only, no resources).
3. **3b cache key — refined during planning (gap found, decision extended, not contradicted).**
   `transitiveDigest(actionLocation)` alone misses **inheritance ancestors**: an ancestor is not in
   `references()` (inheritance is flattened at define time), so editing a *user-editable* prototype's
   inherited value (e.g. a Custom-document `is: Prototype` archetype) would change the action's merged
   definition without bumping its closure digest → stale instance served. (Shipped archetypes are
   classpath-read-only, so the hole is reachable only through user-document prototypes — but Custom
   documents make that a first-class flow.) Key therefore = `transitiveDigest(listOf(location))`
   **combined with each closure member's inheritance-chain notation digests** (chain walk via
   `GraphNotation.inheritanceChain`, guarded for members absent from `coalesce` — synthesized members
   digest as absent, same convention as G2). Cheap: closures are tiny, chains short.
4. **3b opt-out** — archetype attribute (never a class `when`): `instanceCaching: "false"` read via
   `GraphNotation.firstAttribute(location, path)` (`GraphNotation.kt:277-285` — nullable,
   inheritance-chain walk, so one declaration on an archetype covers all instances). Checked
   **before** the cache lookup (and evicts any prior entry), so an archetype *gaining* the opt-out
   takes effect immediately regardless of digest coverage. Constant in `AutoConventions` beside
   `iconAttributePath` (`AutoConventions.kt:33-38`). No surveyed class needs it; it ships for third
   parties, exercised by a test fixture.
5. **3b statelessness contract** — new kdoc on all three interfaces. Key sentence: instances may be
   cached and reused across requests **including concurrent requests** (pre-3b, concurrency only ever
   hit distinct instances; post-3b the same instance can execute in parallel — the survey confirms
   all current implementations are safe, and the contract makes it binding for new ones).
6. **3c mechanism** — `GraphEnvironmentBuilder.put(serviceClassName, provider: () -> Any)` overload
   (the constituent plan's `put` name kept; trailing-lambda syntax `put(cn) { service }` reads
   naturally) storing an internal `ServiceProvider` wrapper; `MapGraphEnvironment.resolve` unwraps it
   via a `by lazy(provide)` memo (common-code; `SYNCHRONIZED` default on JVM, trivially safe on JS).
   Providers must only resolve at request/run time (after host construction) — same invariant as
   today's lazy env, now documented on the builder method.
7. **3c KzenAutoContext shape** — `graphEnvironment` becomes an **eager `val`** declared after
   `columnListingAction` (`:167`) — every registered service except the two cyclic ones is
   constructed above that point — with providers `{ serverLogicController }` and `{ logicTrace }`
   for the cyclic members (Kotlin lambdas referencing later-declared properties are fine; they
   execute at request time). `modelTaskRepository`'s declaration moves below the env (its only
   consumers are `restHandler` and `init()`'s observe — both later). Public name `graphEnvironment`
   unchanged (`ScriptValidationCacheTest:122` depends on it).
8. **Sequencing inside the phase** — 3c first (kzen-lib half, publish, then context rewiring), so 3b's
   `GraphInstanceCache` is born taking a plain `GraphEnvironment`; 3a last (test-only). Matches the
   constituent plan's "kzen-lib half first" split guidance.
9. **Measurement approach** — 3b before/after timing via the browser Network tab on `/action/detached`
   calls (no throwaway code; exact procedure in Verification) plus a **permanent** `logger.debug`
   build-time/closure-size line inside `GraphInstanceCache` (the "after" detail + future diagnosis).
   3a sizes captured by the new test's assertions/log (recorded into the as-built note).

## Step-by-step implementation

### Part A — kzen-lib (publish before any kzen-auto step)

**A1. Provider registration in `GraphEnvironmentBuilder` + `MapGraphEnvironment`.**
Files: `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/context/environment/GraphEnvironmentBuilder.kt`,
`.../MapGraphEnvironment.kt`.

`GraphEnvironmentBuilder` — add (existing eager `put` unchanged):

```kotlin
/**
 * Registers a service lazily: [provider] runs at most once, on the first [GraphEnvironment.resolve]
 * of [serviceClassName], and the result is memoized. For hosts whose environment must register
 * services that are only constructed after the environment itself (composition-root cycles) —
 * the provider must not be resolved until host construction has completed (resolution happens
 * at request/run time, inside the create chain).
 */
fun put(serviceClassName: ClassName, provider: () -> Any): GraphEnvironmentBuilder {
    check(serviceClassName !in services) {
        "Service already registered: $serviceClassName"
    }
    services[serviceClassName] = MapGraphEnvironment.ServiceProvider(provider)
    return this
}
```

`MapGraphEnvironment` — unwrap in `resolve` (memoized; `contains`/`serviceClassNames` unchanged —
provider entries are ordinary keys):

```kotlin
class MapGraphEnvironment(
    private val services: Map<ClassName, Any?>
): GraphEnvironment {
    internal class ServiceProvider(provide: () -> Any) {
        val service: Any by lazy(provide)
    }

    override fun resolve(serviceClassName: ClassName): Any? {
        if (serviceClassName == GraphEnvironment.className) {
            return this
        }
        if (serviceClassName !in services) {
            throw IllegalArgumentException("Missing service: $serviceClassName - have $serviceClassNames")
        }
        val value = services[serviceClassName]
        if (value is ServiceProvider) {
            return value.service
        }
        return value
    }
    // contains / serviceClassNames as-is
}
```

Note: a hypothetical *service value* of function type would bind the provider overload under
trailing-lambda syntax — no such caller exists (verified: builder callers are the two contexts +
`JvmGraphTestUtils.kt:36` + `ServiceInjectionTest.kt:28`); the distinct kdoc makes intent visible.

**A2. `ManagedTask` statelessness kdoc.**
File: `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/exec/task/ManagedTask.kt` (`:6-11`, currently kdoc-less):

```kotlin
/**
 * Long-running Task-paradigm entry point: [start] launches the work and reports through [handle]
 * (returning a [TaskRun] for cancellable work, or null if it completed inline).
 *
 * Statelessness contract: a ManagedTask is instantiated from notation, and the hosting runtime may
 * cache and reuse one instance across submissions — including concurrent ones. Instance fields must
 * be immutable configuration (notation-derived values, injected services); all per-run state belongs
 * in the [TaskRun] / locals created by [start].
 */
```

**A3. Provider test in `ServiceInjectionTest`.**
File: `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/ServiceInjectionTest.kt` (existing test `:20-41` is the template — same notation fixture `test/service-test.yaml` / `ServiceHolder`):

```kotlin
@Test
fun `provider-registered service is lazy and memoized across createGraph calls`() {
    // ... graphDefinition as in the existing test ...
    var invocations = 0
    val environment = GraphEnvironment.builder()
        .put(ClassName(SampleService::class.qualifiedName!!)) {
            invocations++
            SampleService("provided-token")
        }
        .build()

    assertEquals(0, invocations)                     // lazy: not resolved at build time

    val first = GraphCreator.createGraph(graphDefinition, environment)
    val second = GraphCreator.createGraph(graphDefinition, environment)

    assertEquals(1, invocations)                     // memoized across resolves
    val firstService = (first[location]?.reference as ServiceHolder).service
    val secondService = (second[location]?.reference as ServiceHolder).service
    assertSame(firstService, secondService)
}
```

**A4. kzen-lib doc note.** File: `kzen-lib/docs/architecture.md`. The doc has **no** `@Service`/
`GraphEnvironment` coverage at all today (kzen-auto's §4 pointer to it is aspirational — worth
fixing now, since 3c changes the mechanism it would describe). Add a short paragraph after the
hot-path-caching list (after `:71`, before the `meta:` gotcha at `:73`), ~4 sentences: `@Service`
constructor params resolved by `GraphCreator` from a host-supplied `GraphEnvironment` keyed by
declared type; definitions stay environment-free; `GraphEnvironment.builder()` registers services
eagerly or — for composition-root cycles — as `put(className) { service }` providers, memoized on
first resolve at create time; a `GraphEnvironment`-typed param resolves to the environment itself.

**A5. Verify + publish.**

```powershell
cd C:\Users\ostro\IdeaProjects\kzen-lib
./gradlew :kzen-lib-common:jvmTest :kzen-lib-jvm:test
./gradlew publishToMavenLocal
```

### Part B — kzen-auto 3c (thunk removal)

**B1. Consumer constructors: `() -> GraphEnvironment` → `GraphEnvironment`.**

- `ModelDetachedExecutor.kt:22` → `private val environment: GraphEnvironment`; `:41`/`:69`
  `environment()` → `environment` (this parameter is then *replaced entirely* in Part C — doing the
  type flip first keeps each step compiling and reviewable).
- `ModelTaskRepository.kt:35` → same; `:136` `environment()` → `environment` (ditto).
- `ServerLogicController.kt:93` → same; `:910` `environment()` → `environment`.

**B2. `KzenAutoContext` reordering + eager env with providers.**
File: `kzen-auto-jvm/.../server/context/KzenAutoContext.kt`.

- Delete the deferred-provider rationale comment `:170-173` and the lazy-env rationale comment
  `:209-212` (both describe the mechanism this step removes).
- Move the `graphEnvironment` declaration (currently `:213-233`) up to just after
  `columnListingAction` (`:167`), dropping `by lazy`:

```kotlin
// Runtime services exposed to @Service constructor parameters of graph-instantiated objects,
// keyed by the type each consumer declares. The two members constructed below this point
// (serverLogicController, logicTrace) are registered as memoized providers, resolved on first
// use at request/run time — long after construction completes.
val graphEnvironment: GraphEnvironment = GraphEnvironment.builder()
    .put(ClassName(KzenAutoConfig::class.qualifiedName!!), config)
    // ... the 14 other eager puts, unchanged ...
    .put(ClassName(LogicTrace::class.qualifiedName!!)) { logicTrace }
    .put(ClassName(ServerLogicController::class.qualifiedName!!)) { serverLogicController }
    .build()
```

- Pass `graphEnvironment` (plain) at the three construction sites; move `modelTaskRepository`'s
  declaration down beside `detachedExecutor` (below the env and `serverLogicController`/`logicTrace`;
  still above `restHandler` `:195`, its only construction-time consumer). `init()`'s
  `graphStore.observe(modelTaskRepository)` (`:239`) is runtime — unaffected.
- Post-condition to eyeball: **nothing resolves the env during construction** (only `createGraph`
  calls at request/run time do), preserving the old lazy semantics exactly.

**B3. Delete dead `GraphInstanceCreator`.**
File: `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/service/GraphInstanceCreator.kt`.
Verified zero references in kzen-auto (all modules incl. tests) and kzen-project; not `@Reflect`.
Plain deletion.

**B4. ClientContext — no change** (verified drift; record in as-built).

**B5. Green checkpoint.**

```powershell
cd C:\Users\ostro\IdeaProjects\kzen-auto
./gradlew :kzen-auto-jvm:test --refresh-dependencies
```

> **Session split point.** If time runs short, stop here: kzen-lib published, 3c landed, both repos
> green and shippable. Parts C–E are a self-contained second sitting.

### Part C — kzen-auto 3b (scope + digest-keyed instance cache)

**C1. `AutoConventions` opt-out constant.**
File: `kzen-auto-common/.../util/AutoConventions.kt` — beside `:33-38`:

```kotlin
val instanceCachingAttributePath = AttributePath.ofName(AttributeName("instanceCaching"))
```

**C2. `GraphInstanceCache`.**
New file: `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/exec/GraphInstanceCache.kt`.

```kotlin
/**
 * Digest-keyed cache of graph-instantiated server objects, each built from its own transitive
 * definition closure instead of the whole project (G3b). Callers pass the already-policy-filtered
 * GraphDefinition (serverAllowed filter first, closure second — never instantiate client-only
 * objects server-side); the cache is policy-agnostic.
 *
 * Key: the closure's notation digest (GraphDefinition.transitiveDigest) combined with each closure
 * member's inheritance-chain notation digests — the chain digests cover inherited-value edits on
 * user-editable prototypes, which the closure digest alone misses (ancestors are not definition
 * references). Reuse requires cached objects to be stateless per the DetachedAction / ManagedTask
 * contract; an archetype opts out with `instanceCaching: "false"` (fresh instance per request).
 */
class GraphInstanceCache(
    private val graphCreator: GraphCreator,
    private val environment: GraphEnvironment
) {
    companion object {
        private const val maxEntries = 32
        private val logger = LoggerFactory.getLogger(GraphInstanceCache::class.java)
    }

    private data class Entry(
        val digest: Digest,
        val objectInstance: ObjectInstance)

    private val entries = object: LinkedHashMap<ObjectLocation, Entry>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<ObjectLocation, Entry>): Boolean {
            return size > maxEntries
        }
    }


    /** Null when [objectLocation] has no (successful, policy-allowed) definition. */
    @Synchronized
    fun objectInstance(
        definition: GraphDefinition,
        objectLocation: ObjectLocation
    ): ObjectInstance? {
        if (objectLocation !in definition.objectDefinitions) {
            return null                                     // guard BEFORE transitiveDigest's require()
        }

        if (cachingOptedOut(definition, objectLocation)) {
            entries.remove(objectLocation)                  // honour a newly-added opt-out immediately
            return create(definition, objectLocation)
        }

        val digest = cacheKey(definition, objectLocation)
        val cached = entries[objectLocation]                // access-ordered get = LRU touch
        if (cached != null && cached.digest == digest) {
            return cached.objectInstance
        }

        val created = create(definition, objectLocation)
            ?: return null
        entries[objectLocation] = Entry(digest, created)
        return created
    }


    private fun create(definition: GraphDefinition, objectLocation: ObjectLocation): ObjectInstance? {
        val scoped = definition.filterTransitive(objectLocation)
        val startNanos = System.nanoTime()
        val graphInstance = graphCreator.createGraph(scoped, environment)
        logger.debug("built {} - {} of {} definitions in {}us",
            objectLocation, scoped.objectDefinitions.map.size, definition.objectDefinitions.map.size,
            (System.nanoTime() - startNanos) / 1_000)
        return graphInstance[objectLocation]
    }


    // Closure digest + closure members' inheritance-chain notation digests (see class kdoc).
    private fun cacheKey(definition: GraphDefinition, objectLocation: ObjectLocation): Digest {
        val closureDigest = definition.transitiveDigest(listOf(objectLocation))
        val graphNotation = definition.graphStructure.graphNotation
        val closure = definition.transitiveClosure(listOf(objectLocation))

        return Digest.build {
            addDigest(closureDigest)
            for (member in closure.sortedBy { it.asString() }) {
                if (graphNotation.coalesce[member] == null) {
                    continue                                // synthesized member: no notation, no chain
                }
                for (ancestor in graphNotation.inheritanceChain(member)) {
                    addDigestible(ancestor)
                    addDigestibleNullable(graphNotation.coalesce[ancestor])
                }
            }
        }
    }


    private fun cachingOptedOut(definition: GraphDefinition, objectLocation: ObjectLocation): Boolean {
        val attributeNotation = definition.graphStructure.graphNotation
            .firstAttribute(objectLocation, AutoConventions.instanceCachingAttributePath)
        return (attributeNotation as? ScalarAttributeNotation)?.value == "false"
    }
}
```

(Adjust `Digest.build` member names to the live API — `addDigest`/`addDigestible`/
`addDigestibleNullable` per `GraphDefinition.kt:133-138`; if `addDigest` doesn't exist, fold the
closure digest in via `addDigestible(closureDigest)` or start the build from the closure loop and
inline what `transitiveDigest` does — one source of truth preferred, so calling `transitiveDigest`
and adding it as a digestible is the first choice.)

**C3. Rewire `ModelDetachedExecutor`.**
Constructor becomes `(graphStore: LocalGraphStore, graphInstanceCache: GraphInstanceCache)` —
`graphCreator` and `environment` drop (the cache owns them). Both methods share one resolver:

```kotlin
private suspend fun actionInstance(actionLocation: ObjectLocation): Any? {
    val serverDefinition = graphStore
        .graphDefinition()
        .transitiveSuccessful
        .filterDefinitions(AutoConventions.serverAllowed)    // policy filter FIRST, closure second

    return graphInstanceCache.objectInstance(serverDefinition, actionLocation)?.reference
}


override suspend fun execute(actionLocation: ObjectLocation, request: ExecutionRequest): ExecutionResult {
    val instance = actionInstance(actionLocation)
        ?: return ExecutionFailure("Not found: $actionLocation")

    val action = instance as? DetachedAction
        ?: return ExecutionFailure("Not DetachedAction: $actionLocation - $instance")   // typo fixed in passing

    return try {
        action.execute(request)
    }
    catch (t: Throwable) {
        logger.warn("{} - {}", actionLocation, request, t)
        ExecutionFailure.ofException(t)
    }
}
```

`executeDownload` mirrors it with the existing `error(…)` style (`:71-77`).

**C4. Rewire `ModelTaskRepository.submit`.**
Constructor becomes `(graphStore: LocalGraphStore, graphInstanceCache: GraphInstanceCache)`
(`graphStore` stays — `submit` fetches the definition; the observer role is unrelated). In `submit`
(`:128-141`), replace the definition+createGraph block:

```kotlin
val serverDefinition = graphStore
    .graphDefinition()
    .transitiveSuccessful
    .filterDefinitions(AutoConventions.serverAllowed)

// TODO: add GraphInstanceAttempt for error reporting          <- preserved for phase 6
val instance = graphInstanceCache.objectInstance(serverDefinition, taskLocation)?.reference
    ?: throw IllegalArgumentException("Not found: $taskLocation")

val task = instance as ManagedTask
```

**C5. `KzenAutoContext` wiring.** After `graphEnvironment` (Part B2 position):

```kotlin
// Scoped, digest-keyed instance reuse for detached actions and tasks (G3b).
val graphInstanceCache = GraphInstanceCache(graphCreator, graphEnvironment)
```

and pass it at the two construction sites (which now sit below it, per B2's move).

**C6. Statelessness kdoc on the detached interfaces.**
`DetachedAction.kt` (kzen-auto-common) and `DetachedDownloadAction.kt` (kzen-auto-jvm) — same
contract wording as A2, kzen-auto flavoured:

```kotlin
/**
 * One-shot request/response action (Detached paradigm): executes one [ExecutionRequest] and
 * returns synchronously, with no state tracked between requests.
 *
 * Statelessness contract: implementations are instantiated from notation and may be cached and
 * reused across requests — including concurrent requests (see GraphInstanceCache). Instance fields
 * must be immutable configuration (notation-derived values, injected @Service references); all
 * per-request state belongs in locals. An implementation that cannot honour this opts out of reuse
 * by declaring `instanceCaching: "false"` on its archetype (fresh instance per request).
 */
```

### Part D — 3a (test-pin + measurement only)

**D1. `FlowVertexClosureTest`.**
New file: `kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/flow/FlowVertexClosureTest.kt`.
Pins the survey invariant that justified the rescope (and would gate any future return to
per-vertex instantiation): per-vertex closures are self-contained and standalone-creatable.

```kotlin
// Pins G3a's survey result: a Flow vertex's transitive definition closure contains no sibling
// vertices (channels are define-time values; edges are grid geometry; RunLogicVertex's
// `instructions` is weak by design — see LinkedLogicDocuments), so per-vertex instantiation
// remains structurally available. Also records closure-vs-document sizes (G3 as-built note).
class FlowVertexClosureTest {
    @Test
    fun vertexClosuresExcludeSiblingsAndAreCreatable() {
        val notation = AutoTestUtils.readNotation()
        val definition = AutoTestUtils.graphDefinitionAttempt(notation).transitiveSuccessful
        val documentPath = DocumentPath.parse("test/flow-run-test.yaml")   // contains a RunLogic vertex;
                                                                          // fall back to flow-execution-test.yaml + note if not
        val structure = definition.graphStructure
        val vertexLocations = FlowMatrix.ofDocument(documentPath, structure).verticesByLocation.keys

        val documentScopedSize = definition.filterTransitive(documentPath).objectDefinitions.map.size
        val environment = GraphEnvironment.builder()
            .put(ClassName(FlowMessageInspector::class.qualifiedName!!), FlowMessageInspector())
            .build()   // extend if createGraph names another missing @Service

        for (vertexLocation in vertexLocations) {
            val scoped = definition.filterTransitive(vertexLocation)
            val closure = scoped.objectDefinitions.map.keys

            val siblings = vertexLocations - vertexLocation
            assertTrue(closure.none { it in siblings },
                "$vertexLocation closure must not pull sibling vertices: $closure")
            assertTrue(closure.size < documentScopedSize)

            // standalone create succeeds — a RunLogicVertex builds without its (weak) child document
            val created = GraphCreator.createGraph(scoped, environment)
            assertNotNull(created[vertexLocation])

            println("G3a measurement: $vertexLocation closure=${closure.size} document=$documentScopedSize")
        }
    }
}
```

Record the printed sizes (expected: closure 1–2 vs document ≈ vertex-count + 1) in the constituent
plan's as-built note, alongside the rescope statement.

### Part E — tests for 3b, docs, tracker

**E1. Fixture `kzen-auto-jvm/src/test/resources/notation/test/detached-cache-test.yaml`** (new;
test notation, *not* `notation/main/`). Self-contained, modelled on `Custom.yaml`'s adhoc shapes:

```yaml
CacheNamedType:
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocNamed

CacheNamed:
  is: CacheNamedType
  class: tech.kzen.auto.server.objects.custom.test.AdhocNamedImpl
  name: cache-test
  meta:
    name: String

CachedActionArchetype:
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocDetached
  meta:
    named:
      is: CacheNamedType

CachedAction:
  is: CachedActionArchetype
  named: CacheNamed

FreshActionArchetype:
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocDetached
  instanceCaching: "false"
  meta:
    named:
      is: CacheNamedType

FreshAction:
  is: FreshActionArchetype
  named: CacheNamed
```

(Exact `is:`/`meta:` spelling per the working `Custom.yaml:1-32` precedent; the point of the two
archetypes is that the opt-out is declared on the **archetype**, exercising the inheritance-walking
`firstAttribute` read. Quote `"false"` — house YAML style for non-bare scalars post-Y.)

**E2. `GraphInstanceCacheTest`** (new, `kzen-auto-jvm/src/test/.../server/service/exec/`), offline
harness copied from `ScriptValidationCacheTest` (`AutoTestUtils` + `NotationReducer` edits — no
store writes). Cases, all against `GraphInstanceCache(GraphCreator, GraphEnvironment.empty)` and
`test/detached-cache-test.yaml` locations:

1. *Hit*: two calls with equal-digest definitions (even distinct `GraphDefinition` objects rebuilt
   from the same notation) → `assertSame` instance; execute returns `Hello: cache-test`.
2. *Own-notation edit invalidates*: `UpsertAttributeCommand` on `CachedAction` → `assertNotSame`.
3. *Closure-member edit invalidates*: edit `CacheNamed`'s `name` (strong ref member) →
   `assertNotSame`, and the new instance's execute reflects the new name.
4. *Inheritance-ancestor edit invalidates* (pins the cache-key refinement): edit
   `CachedActionArchetype` (e.g. its `named:` default or an added scalar) → `assertNotSame`.
5. *Unrelated edit stays cached*: edit an object in a different test document → `assertSame`.
6. *Opt-out*: `FreshAction` → two calls, `assertNotSame` both times, nothing retained.
7. *Not found*: unknown location → null.

**E3. `ModelDetachedExecutorTest`** (new, integration): `KzenAutoContext.forTest()` →
`context.detachedExecutor.execute(<CachedAction location>, ExecutionRequest(RequestParams.empty, null))`
twice → both `ExecutionSuccess` with equal values. This is coverage that **could not exist before
3b** (the whole-graph build was unsatisfiable in the test environment —
`ScriptValidationCacheTest.kt:110-114`); it proves scoping end-to-end through the real executor.
Optionally mirror once through `context.modelTaskRepository.submit` with an `AdhocTask` fixture
object (same yaml, `class: …AdhocTask`) — cheap parity check for C4.

**E4. Docs (docs-lead rule — same session).**

- `kzen-auto/docs/architecture.md` **§4** (`:185`): replace "via a deferred `() -> GraphEnvironment`
  provider for the callers that are themselves registered in it (`serverLogicController`, the plugin
  repo), to break the construction cycle" with the provider-registration mechanism (eager env;
  cyclic members as memoized `put(className) { service }` providers; consumers take plain
  `GraphEnvironment`), and drop the stale plugin-repo mention (it takes no environment and already
  scopes with `filterTransitive` + its own digest cache). Add `graphInstanceCache` to the §4 service
  table; amend the `detachedExecutor` / `modelTaskRepository` rows (closure-scoped, digest-cached).
- `kzen-auto/docs/architecture.md` **§5**: one short paragraph under `ModelDetachedExecutor` /
  `ModelTaskRepository`: per-call instantiation is scoped to the action's transitive closure
  (serverAllowed-filtered first) and reused via `GraphInstanceCache` keyed by closure +
  inheritance-chain digest; statelessness contract on the interfaces; `instanceCaching: "false"`
  opt-out.
- kzen-lib doc — done in A4.

**E5. Constituent-plan bookkeeping.** In `kzen/plans/2026-07-16_graph-improvements.md`: tick the
Phase 3 tracker box and append the as-built note: 3a rescoped (premise landed earlier —
build-once-per-run in `FlowRun`; survey table + measured sizes; `createObject` still deferred), 3b
survey table + "no opt-out needed by current implementations", the cache-key inheritance-chain
refinement, 3c drift (ClientContext no-op; plugin repo was never a thunk site; dead
`GraphInstanceCreator` deleted), and the before/after detached timings. Update the memory-index
graph-plan entry if the session touches it.

**E6. Stage new files** (`git add` by explicit path, both repos, never commit): the new
`GraphInstanceCache.kt`, `FlowVertexClosureTest.kt`, `GraphInstanceCacheTest.kt`,
`ModelDetachedExecutorTest.kt`, `detached-cache-test.yaml`; kzen-lib has only edited tracked files.

## Tests

| Test | Repo | Pins |
|---|---|---|
| `ServiceInjectionTest` (+1 case) | kzen-lib | provider laziness + memoization + injection identity |
| `GraphInstanceCacheTest` (new) | kzen-auto | hit/miss identity; own/closure/**ancestor**/unrelated edit invalidation; archetype opt-out; not-found null |
| `ModelDetachedExecutorTest` (new) | kzen-auto | executor works on closure-scoped create in the test env (impossible pre-3b); repeat-call equality |
| `FlowVertexClosureTest` (new) | kzen-auto | 3a invariant: no sibling vertices in any vertex closure; standalone create incl. `RunLogicVertex` sans child; size measurement |
| Existing suites | both | `ScriptValidationCacheTest` (env still reaches `ScriptValidator` — now through the scoped path), Job suite + `FormulaStepTest` (env threading via `LogicCompilerServices`), notation suites |

## Verification

```powershell
# Part A gate
cd C:\Users\ostro\IdeaProjects\kzen-lib
./gradlew :kzen-lib-common:jvmTest :kzen-lib-jvm:test
./gradlew publishToMavenLocal

# Part B gate + full kzen-auto baseline after C/D/E
cd C:\Users\ostro\IdeaProjects\kzen-auto
./gradlew :kzen-auto-jvm:test --refresh-dependencies      # Job suite + FormulaStepTest + new tests

# End-to-end (opt-in; opens Chrome; Flow FizzBuzz exercises per-vertex execution, Script sub-run
# exercises compile — both through the 3c env path)
./gradlew :kzen-auto-test:selfTest
```

**Manual smoke — Report detached hot path + before/after timing** (constituent-plan requirement):

1. **Before** (on pre-change master): `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`
   (or IDE `BackendDevelopment` + `-t :kzen-auto-jvm:classes`), open a Report document, open the
   browser DevTools Network tab filtered to `/action/detached`, exercise the input panel (browse
   input files, refresh column listing / filtered preview). Record 3–5 representative call
   latencies.
2. **After**: same clicks on the built change; behaviour identical, latencies recorded. Enable
   `DEBUG` for `tech.kzen.auto.server.service.exec.GraphInstanceCache` (logback) to capture the
   one-time "built … N of M definitions in …us" line — N ≪ M is the scoping measurement; subsequent
   calls log nothing (cache hits).
3. Also confirm: Script editor validation still works (ScriptValidator via detached), a Target
   document screenshot still captures (`ScreenshotTaker`), and a plugin document still
   lists/uploads (`PluginDocument`) — the three non-Report detached families.
4. Record before/after numbers in the as-built note (E5).

## Risks & gotchas

- **Same-instance concurrency is new.** Pre-3b, concurrent detached calls got distinct instances;
  post-3b they can share one. The survey proves every current implementation safe (all-`val`
  config/services); the kdoc contract + opt-out govern future ones. Do not weaken the kdoc's
  "including concurrent requests" sentence.
- **`transitiveClosure`/`transitiveDigest` `require` on absent seeds** (`GraphDefinition.kt:58-62`):
  the not-found guard must precede any digest/filter call, or an unknown action location becomes an
  `IllegalArgumentException` instead of the wire-friendly `ExecutionFailure`. (C2's ordering does
  this; keep it under refactors.)
- **Closure digest alone is not enough** — the inheritance-ancestor hole (Pre-resolved #3). If an
  implementer is tempted to "simplify" the key back to bare `transitiveDigest`, test E2 case 4
  fails; leave it in.
- **Resource content is outside every notation digest.** A `PluginDocument` jar replaced without a
  notation edit does not bump the key — safe *today* because `PluginDocument` re-reads the jar per
  call (fields are `jarPath`/`selfLocation` only). A future action that snapshots resource bytes at
  construction must opt out. Mention in the interface kdoc review if it comes up; not a blocker.
- **Providers must not resolve during construction.** The eager env + provider lambdas preserve the
  old `by lazy` semantics only because nothing calls `createGraph`/`resolve` before `init()`
  completes. A future eager `createGraph` inside `KzenAutoContext` construction would NPE on
  `serverLogicController` — the B2 comment warns; don't remove it.
- **Overload capture**: `put(className) { … }` with a trailing lambda always binds the provider
  overload. Registering a *function-typed service value* would need the eager overload with an
  explicit parameter — theoretical today (no such service), noted in the builder kdoc.
- **LRU staleness is memory-only.** Entries for renamed/deleted actions linger until evicted
  (cap 32); cached instances hold no resources (survey), so no disposal hook is needed. Don't add
  an observer for this — the cap is the design.
- **Flow value-channel sharing (pre-existing, untouched).** `FlowWiring` bakes mutable channel
  objects into *definitions*, which G1 shares across consumers of a notation version; `FlowRun`
  resets channels per execution and only one run is active. 3b's cache never touches the Logic
  path, so this stays exactly as it was — noted so the cache doesn't get blamed if channel
  weirdness ever surfaces.
- **Do not "improve" `PluginReportDefinitionRepository`** to use the new cache — it has its own
  digest/metadata cache with classloader lifecycle semantics (`.use {}` closes handles); out of
  scope.
- **`forTest()` store writes**: never drive cache-invalidation tests through
  `context.graphStore.apply(...)` — the test store writes through `FileNotationMedia` into the repo.
  Offline `NotationReducer` edits only (the `ScriptValidationCacheTest` pattern).
- **Keep `// TODO: add GraphInstanceAttempt`** in `ModelTaskRepository.submit` — phase 6 anchor.

## Out of scope (decided; do not re-open)

- `GraphCreator.createObject(location, definition, environment, baseInstance)` single-object API —
  deferred by the constituent plan; the 3a measurement (D1) is the record either way.
- Per-vertex Flow instantiation in production — rescoped away (premise landed as build-once-per-run);
  `FlowVertexClosureTest` keeps the door pinned open.
- `GraphInstanceAttempt` / structured creation failures — phase 6.
- Memoizing the per-call `filterDefinitions(serverAllowed)` map filter — micro-opt; today's calls
  already pay it and `createGraph` was the cost that mattered.
- Registering an environment for `PluginReportDefinitionRepository`, or any plugin-repo change.
- Client-side (`ClientContext`/JS) changes — verified no thunk exists.
- G4-style incremental define — separate, measurement-gated phase.
