# R4 — @Service FQN coupling validation — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from `2026-07-18_reflection-improvements.md`
> Phase R4 (decisions pre-made there — additive `ReflectionRegistry` enumeration accessor;
> boot-time assertion in both bootstraps naming the missing FQN + declaring class; the
> generated-service-constants alternative rejected — do not re-litigate). All anchors verified
> against current code 2026-07-19, post SER2–SER5 / Y / G5 / G7 / TP1 / TP3 / TP4 — no drift found
> in any R4-relevant anchor. **No existing FQN mismatch exists on either platform** (verified
> source-level and against the on-disk KSP output); this phase is pure future-proofing.
> Light session: kzen-lib accessor → publish → kzen-auto helper + two call sites + tests + smoke.

## Scope & goal

The silent failure mode: `ClientContext.graphEnvironment` (kzen-auto-js) keys services with
hand-written `ClassName("literal.fqn")` strings (`KClass.qualifiedName` is unavailable on JS)
that must exactly match the `@Service` parameter-type FQNs the KSP processor records
(`ReflectSymbolProcessor.kt:99-109` → `reflectionRegistry.put(fqn, argNames, serviceArgMap)`).
A typo or a package rename on either side today fails only at graph-creation time on JS, as
`MapGraphEnvironment.resolve`'s `IllegalArgumentException("Missing service: …")`
(`MapGraphEnvironment.kt:18`) deep inside `ServiceAttributeCreator.create`
(`ServiceAttributeCreator.kt:37`) — a runtime puzzle, not a named startup failure.

After R4: at boot, on **both** platforms, every `@Service` parameter type recorded in
`ReflectionRegistry.global` is checked against the host `GraphEnvironment`; a miss throws
immediately, naming the missing service FQN **and** the registered class(es) that declare it.

Deliverables:
1. kzen-lib: one additive enumeration accessor on `ReflectionRegistry`.
2. kzen-auto-common: one shared validation helper (single implementation both platforms run).
3. kzen-auto: one call at the end of `KzenAutoContext.init()` (JVM) and one at the end of
   `ClientContext.initAsync()` (JS).
4. Tests (kzen-lib commonTest for the accessor; kzen-auto-common commonTest for the helper) +
   the deliberate-misspell smoke on both platforms.

## Dependencies & coordination

- **Independent of R1–R3** (R plan sizing table: "R3 and R4 float freely"). Master plan: Sprint-2
  filler, prerequisite-free.
- **kzen-lib publishes first** (standing ground rule): after the accessor lands,
  `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`.
- **G3c adaptation note** (graph plan `2026-07-16_graph-improvements.md` § 3c, planned in
  parallel): G3c gives `MapGraphEnvironment` a `put(className, provider)` with memoized
  first-resolve and makes `KzenAutoContext`/`ClientContext` register providers directly, deleting
  the `() -> GraphEnvironment` thunks and (likely) the `by lazy` on both `graphEnvironment` vals.
  **Whichever lands second adapts; the assertion placement survives either shape** — end of
  `init()` / `initAsync()` is after environment construction in both worlds. Two specifics:
  - If **R4 lands first** (this plan's baseline): the assertion forces the `by lazy` at init time
    (safe — see Pre-resolved Q2). When G3c later removes the lazy, the assertion line is untouched.
  - If **G3c lands first**: drop this plan's "forces the lazy" caveat; everything else is
    identical. One requirement to carry to G3c either way: provider-registered keys must be
    visible to `contains()` / `serviceClassNames` **at registration, before first resolve**
    (natural if the provider is stored in the same `services` map) — otherwise the boot assertion
    would false-negative on provider entries.
- **R5 forward-compat**: keep the validation callable as a plain function (it is — a helper, not
  inline code), so R5's boot-time plugin load can re-invoke it after plugin `ModuleReflection`
  registration. Modules registered *before* context init are covered automatically (see
  Current-state findings, coverage).

## Current-state findings (anchors verified 2026-07-19)

### Registry internals (kzen-lib)

`ReflectionRegistry`
(`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/reflect/ReflectionRegistry.kt`):
- Storage: `private val registry = mutableMapOf<ClassName, ClassReflection>()` (line 22);
  `ClassReflection.serviceArguments: Map<String, ClassName>` (param name → declared service type;
  `ClassReflection.kt:14`). `put(className: String, constructorArgumentNames, serviceArguments:
  Map<String, String> = mapOf(), constructorFunction)` converts value strings to `ClassName`
  (lines 33–44). So yes — service arg types are FQN-keyed `ClassName`s, per registered class.
- Synchronization: every access is `platformSynchronized(registry) { … }` (lines 27, 38; JVM
  actual = `synchronized`, JS actual = pass-through). The new accessor must do the same.
- **No enumeration of any kind exists today** (confirmed — the only readers are the keyed
  `ClassMirror` methods `get`/`contains`/`constructorArgumentNames`/`serviceArguments`/`create`).
- `ReflectionRegistry` is a **class** with a `companion object { val global }` (line 17) — a fresh
  instance is constructible in tests. `ModuleReflection.register` defaults to
  `ReflectionRegistry.global` (`ModuleReflection.kt:13`).
- The definition layer consumes service args via `GlobalMirror.serviceArguments(className)`
  (`AttributeObjectDefiner.kt:112`); `GlobalMirror`'s delegate list is today exactly
  `[ReflectionRegistry.global]` (`GlobalMirror.kt:7-9`; R1 will make it extensible). Validation
  enumerates the **registry**, not the mirror — see Pre-resolved Q1.

### GraphEnvironment (kzen-lib) — contains already exists

`GraphEnvironment` (`…/service/context/environment/GraphEnvironment.kt`) already declares both
`fun contains(serviceClassName: ClassName): Boolean` (line 20) **and**
`val serviceClassNames: Set<ClassName>` (line 22). `MapGraphEnvironment` implements both
(lines 24–31). **No additive environment accessor is needed.** Two load-bearing details:
- `contains` special-cases `GraphEnvironment.className` → `true` (`MapGraphEnvironment.kt:25`,
  mirroring `resolve`'s self-reference at lines 13–15). This makes `ScriptValidator`'s
  `@Service private val environment: GraphEnvironment` (`ScriptValidator.kt:35`) validate
  cleanly with zero special-casing in R4 code.
- `serviceClassNames` (the registered key set) is what the failure message prints as "available".

### JS literal inventory — the validation targets (`ClientContext.kt:110-122`)

Nine literals, all `by lazy`-built (`ClientContext.kt:110`):

| # | `ClassName` literal (line) | Instance |
|---|---|---|
| 1 | `tech.kzen.lib.common.service.store.MirroredGraphStore` (112) | `mirroredGraphStore` |
| 2 | `tech.kzen.lib.common.service.store.normal.ObjectStableMapper` (113) | `objectStableMapper` |
| 3 | `tech.kzen.lib.common.service.parse.NotationParser` (114) | `notationParser` |
| 4 | `tech.kzen.auto.client.service.global.ClientStateGlobal` (115) | `clientStateGlobal` |
| 5 | `tech.kzen.auto.client.service.global.NavigationGlobal` (116) | `navigationGlobal` |
| 6 | `tech.kzen.auto.client.service.global.ExecutionIntentGlobal` (117) | `executionIntentGlobal` |
| 7 | `tech.kzen.auto.client.service.logic.ClientLogicGlobal` (118) | `clientLogicGlobal` |
| 8 | `tech.kzen.auto.client.service.rest.ClientRestApi` (119) | `restClient` |
| 9 | `tech.kzen.auto.client.service.rest.ClientRestTaskRepository` (120) | `clientRestTaskRepository` |

**Verified against the on-disk KSP output**
(`kzen-auto-js/build/generated/ksp/js/jsMain/kotlin/tech/kzen/auto/client/codegen/KzenAutoJsModule.kt`):
the distinct `serviceArguments` FQNs across all JS registrations are **exactly these nine** —
every literal matches, every recorded type has a literal. **No live bug.** (JS `@Service`
consumers: `ProjectController`, `SidebarController`, `RibbonController`, `HeaderController`,
`StageController`, every document controller, the script step displays/editors, the job
displays/editors, `TargetAttributeView`, etc. — ~45 declaring classes, all drawing from the same
nine types.)

### JVM environment keys (`KzenAutoContext.kt:213-233`)

Seventeen keys, all derived `ClassName(X::class.qualifiedName!!)` — **the JVM cannot drift by
literal typo**, only by "consumer declares a type nobody registered" (e.g. interface vs.
concrete), which the assertion also catches. Keys (lines 215–231): `KzenAutoConfig`,
`GraphCreator`, `ObjectStableMapper`, `CachedKotlinCompiler`, `ScriptValidationCache`,
`NotationMedia`, `TargetLocator`, `NotationMetadataReader`, `LocalGraphStore`, `LogicTrace`,
`ReportWorkPool`, `ReportDefinitionRepository`, `CalculatedColumnEval`, `FlowMessageInspector`,
`FileListingAction`, `ColumnListingAction`, `ServerLogicController`.

Distinct `@Service` parameter types recorded by the JVM-side registrations (verified from
generated `KzenAutoJvmModule` + source sweep), 13 total, **all present in the environment**:
`LocalGraphStore` + `TargetLocator` (`TargetLocateAction.kt:31-32`; the five Browser*Step),
`LogicTrace` (`LogicTraceEndpoint.kt:24`), `CachedKotlinCompiler` (`FormulaStep.kt:29`,
`ResultStep.kt:37`, `DoWhileStep.kt:33`, `FormulaSourceWorker.kt:42`), `CalculatedColumnEval`
(`FilterWorker.kt:41`, `FormulaWorker.kt:43`, `ReportDocument.kt:81`), `ReportWorkPool` /
`ReportDefinitionRepository` / `FileListingAction` / `ColumnListingAction` /
`ServerLogicController` (`ReportDocument.kt:79-84`), `GraphCreator` / `GraphEnvironment`
(self-ref, passes via the `contains` special case) / `ScriptValidationCache`
(`ScriptValidator.kt:33-36`). **No live bug on JVM either.**

Environment keys with **no** `@Service` consumer (`NotationMedia`, `NotationMetadataReader`,
`ObjectStableMapper`, `FlowMessageInspector`, and `KzenAutoConfig` in a plain server) are **not
errors**: validation is one-directional (registry → environment). They are consumed by hand
`resolve` calls (`ReportLogicCompiler.kt:68-72` resolves `ReportWorkPool` /
`ReportDefinitionRepository` / `CalculatedColumnEval` generically) or by downstream modules
(`KzenAutoConfig` → kzen-auto-test, next). Do not prune; do not validate env→registry.

### Downstream-module coverage

- **kzen-auto-test**: `StartKzenAutoStep.kt:25` declares `@Service private val config:
  KzenAutoConfig` (recorded FQN `tech.kzen.auto.server.context.KzenAutoConfig` — matches the
  env key). `TesterMain.kt:48` calls `KzenAutoTestModule.register()` **before** line 54's
  `tech.kzen.auto.server.main(…)` → `kzenAutoInit` (`KzenAutoMain.kt:93`) →
  `KzenAutoContext.create` (line 108) → `init()`. **Covered automatically** — the assertion runs
  inside `init()`, after any earlier registration into `ReflectionRegistry.global`.
- **kzen-project**: currently registers **nothing extra** — `KzenProjectMain.kt:13-18` delegates
  straight to `kzenAutoInit`/`kzenAutoMain`; JS `Main.kt:8` calls `tech.kzen.auto.client.main()`
  (its own module registration is commented out, lines 4–6). When SH4 adds real registration, it
  will (like the tester) precede context init → covered automatically, zero R4 work.
- **R5 plugins**: registered at plugin load, *after* boot — outside the boot assertion. The
  helper being a callable function is the seam R5 re-invokes (noted in R5's design). Java
  plugins served by R1's reflective mirror never enter the registry and are not enumerable —
  their `@Service` params keep today's instantiation-time failure. Accepted gap; recorded here.
- **Hand-written test modules** (kzen-auto-jvm `src/test` — `ScriptStepTestModule`,
  `TargetTestModule`, `FlowVertexTestModule`, the three Job worker modules): all use the 3-arg
  `put` (no `serviceArguments`) — verified. They cannot trip the assertion regardless of
  registration order relative to `KzenAutoContext.forTest()`.
- **kzen-lib's own JVM tests**: `ServiceHolder`/`SampleService` fixtures register into
  `ReflectionRegistry.global` in the kzen-lib test JVM only; irrelevant to kzen-auto boots.

### Boot flows (assertion insertion points)

- **JVM**: companion `init {}` runs the three `register()` calls (`KzenAutoContext.kt:71-75`) at
  first class access; `create()` → constructor → `init()` (lines 237–252: observer wiring,
  stable-id pre-warm, `initManagedStorage()`). `graphEnvironment` is `by lazy` (line 213),
  deliberately deferred past construction because it references `serverLogicController` /
  `definitionRepository` (comment lines 170–173) — but by `init()` time **every constructor `val`
  is built**, so forcing it there is cycle-safe.
- **JS**: companion `init {}` registers the three modules (`ClientContext.kt:38-42`) when
  `ClientContext.create()` first touches the companion; `create()` → constructor → `initAsync()`
  (lines 126–143). `graphEnvironment` is likewise `by lazy` (line 110), first forced today at
  `Main.kt:52-53` (`createGraph(…, clientContext.graphEnvironment)`). A throw inside
  `initAsync()` propagates out of `create()` and `Main.kt:38-42` renders `"Error: ${t.message}"`
  into the root element — the named failure is user-visible, not just console.

### Misc verified facts

- `ClassName` is an `expect class` with `data class` actuals on both platforms (jsMain verified;
  jvmMain same pattern) — safe as `Set`/`Map` key.
- KSP records the service type as `resolvedType.declaration.qualifiedName`
  (`ReflectSymbolProcessor.kt:104`) — the *declared* parameter type, which is exactly what the
  bootstraps must key.
- kzen-auto-common has `commonTest` running on JVM + JS (ChromeHeadless — `WireDtoSerializerTest`
  precedent); kzen-lib-common has `commonTest` too. Placement for the helper:
  `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/service/` (beside
  `GraphInstanceCreator.kt`).

## Pre-resolved questions

**Q1 — accessor shape.** The phase text's strawman `serviceArgumentClassNames(): Set<ClassName>`
cannot produce the mandated failure message ("naming the missing FQN **and the registered class
that declares it**") without a second enumeration API — so the single accessor returns the map:

```kotlin
fun serviceArgumentDeclarations(): Map<ClassName, Set<ClassName>>
```

service-type `ClassName` → the registered classes declaring a `@Service` parameter of that type.
*Justification (one sentence): one map-shaped accessor is the minimal surface that carries both
sides of the coupling for the error message, where a bare `Set` would force a second accessor or
a full-registry dump.* It lives on `ReflectionRegistry` (the class), **not** on the `ClassMirror`
interface — enumeration is not a mirror capability (R1's reflective mirror cannot enumerate a
classloader), and interface additions would touch third-party implementers. Snapshot is built
inside `platformSynchronized(registry) { … }`, matching `get`/`put` (registration is boot-time,
reads after — same contention-nil reasoning as the class KDoc, lines 7–10).

**Q2 — timing / placement.** "After all `register()` calls + environment construction" resolves
to:
- **JVM**: last line of `KzenAutoContext.init()` (after `initManagedStorage()`,
  `KzenAutoContext.kt:251`). All module `register()` calls ran in the companion `init` (before
  any instance exists); referencing `graphEnvironment` here **forces the lazy** — safe because
  `init()` runs post-constructor so the cyclic members are built, and the builder only captures
  references (no I/O, no instantiation). Side effect: environment construction moves from
  first-request to boot — desirable (fail-fast) and behavior-neutral. Also update the stale
  half of the comment at lines 211–212 ("first accessed at request/run time") in the same edit.
- **JS**: last line of `ClientContext.initAsync()` (after `clientStateGlobal.postConstruct`,
  `ClientContext.kt:141-142`). Registration precedes it via the companion `init`; forcing the
  lazy here (before `Main.kt:52`'s existing first-force) is equally safe — all constructor vals
  are built.
- `graphEnvironment.contains(className)` is **directly answerable** — both `contains` and
  `serviceClassNames` already exist on the `GraphEnvironment` interface (lines 20, 22). **No
  environment-side change needed.** The `GraphEnvironment` self-reference special case in
  `contains` (`MapGraphEnvironment.kt:25`) is load-bearing for `ScriptValidator` — do not
  route the check through `serviceClassNames` membership instead of `contains`.

**Q3 — where the assertion code lives.** One shared helper in kzen-auto-common commonMain
(`tech.kzen.auto.common.service.ServiceEnvironmentValidation`), called from both bootstraps.
This satisfies the pre-made decision ("boot-time assertion in both bootstraps") while keeping a
single implementation both platforms run — and makes the JVM/JS unit test test exactly the code
production runs. (Alternative — ~8 lines inlined twice — rejected only for test-duplication;
either honors the decision.)

**Q4 — failure message.** `IllegalStateException` (via `check`), e.g.:

```
@Service type not registered in GraphEnvironment: tech.kzen.auto.client.service.rest.ClientRestApi
  (declared by: tech.kzen.auto.client.objects.ribbon.HeaderController,
   tech.kzen.auto.client.objects.document.report.ReportController, ...);
  environment provides: [tech.kzen.lib.common.service.store.MirroredGraphStore, ...]
```

All missing types reported in one throw (iterate, collect misses, then one `check`) — a rename
that breaks several literals should read as one actionable list, not a fix-rerun loop.

## Step-by-step implementation

### 1. kzen-lib — the accessor

`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/reflect/ReflectionRegistry.kt` —
add after `put` (~line 45), before the `ClassMirror` overrides:

```kotlin
/**
 * Every distinct @Service parameter type across all registrations, mapped to the registered
 * class(es) declaring it. Supports host boot-time validation that a GraphEnvironment covers
 * every service type a registered class can demand (fails at startup with names, instead of
 * at graph-creation time). Snapshot taken under the registry lock.
 */
fun serviceArgumentDeclarations(): Map<ClassName, Set<ClassName>> {
    return platformSynchronized(registry) {
        val result = mutableMapOf<ClassName, MutableSet<ClassName>>()
        for ((className, classReflection) in registry) {
            for (serviceClassName in classReflection.serviceArguments.values) {
                result.getOrPut(serviceClassName) { mutableSetOf() }.add(className)
            }
        }
        result
    }
}
```

Additive only — no existing signature touched (SPI ground rule).

### 2. kzen-lib — accessor test

New `kzen-lib-common/src/commonTest/kotlin/tech/kzen/lib/common/reflect/ReflectionRegistryServiceArgumentsTest.kt`
(runs JVM + JS): fresh `ReflectionRegistry()` (not `global` — keep the process-global clean);
`put` (a) a class with two service args, (b) a second class sharing one service type,
(c) a class with none. Assert: map keys = the distinct service types; the shared type maps to
both declaring classes; empty registry → empty map.

### 3. kzen-lib — publish

```powershell
cd C:\Users\ostro\IdeaProjects\kzen-lib
./gradlew :kzen-lib-common:jvmTest
./gradlew publishToMavenLocal
```

### 4. kzen-auto-common — shared validation helper

New `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/service/ServiceEnvironmentValidation.kt`:

```kotlin
object ServiceEnvironmentValidation {
    /**
     * Asserts every @Service parameter type recorded in [reflectionRegistry] is resolvable from
     * [environment]. Call at boot, after all module register() calls and environment
     * construction (KzenAutoContext.init / ClientContext.initAsync); re-invokable after
     * late module registration (e.g. plugin load).
     */
    fun validate(
        environment: GraphEnvironment,
        reflectionRegistry: ReflectionRegistry = ReflectionRegistry.global
    ) {
        val missing = reflectionRegistry
            .serviceArgumentDeclarations()
            .filterKeys { ! environment.contains(it) }
        check(missing.isEmpty()) {
            missing.entries.joinToString("\n") { (service, declarers) ->
                "@Service type not registered in GraphEnvironment: $service" +
                        " (declared by: ${declarers.joinToString { it.asString() }})"
            } + "\nenvironment provides: ${environment.serviceClassNames}"
        }
    }
}
```

(Plain Kotlin `object`, **no** `@Reflect` — it is not graph-instantiated.)

### 5. kzen-auto — the two boot calls

- `KzenAutoContext.kt` — end of `private fun init()` (after `initManagedStorage()`, line 251):
  ```kotlin
  // Fail fast (with names) on any @Service parameter type the environment doesn't provide —
  // guards the JS-side hand-written ClassName literals' twin registration on the JVM too.
  ServiceEnvironmentValidation.validate(graphEnvironment)
  ```
  Also amend the lazy's comment (lines 211–213): construction now happens at the end of boot
  (still after the cyclic members are built), not at first request.
- `ClientContext.kt` — end of `private suspend fun initAsync()` (after
  `clientStateGlobal.postConstruct(…)`, line 142): same two lines (comment may instead point at
  the literal block above, lines 106–109).

### 6. Docs (same session, minimal)

- kzen-auto `docs/architecture.md` § 4 (`graphEnvironment` row / the construction-time DI
  paragraph): one sentence — boot-time validation asserts registry service-arg coverage on both
  platforms, naming the miss.
- kzen-auto `AGENTS.md`: no new gotcha needed (the failure is now loud and named); optional
  one-line note beside the § Gotchas `@Reflect`/KSP entry if it reads naturally.

### 7. Build kzen-auto

```powershell
cd C:\Users\ostro\IdeaProjects\kzen-auto
./gradlew build --refresh-dependencies -x test
./gradlew :kzen-auto-common:allTests :kzen-auto-jvm:test
```

## Tests

1. **Accessor** (kzen-lib commonTest, step 2 above) — shape + aggregation + empty.
2. **Helper** (new
   `kzen-auto-common/src/commonTest/kotlin/tech/kzen/auto/common/service/ServiceEnvironmentValidationTest.kt`,
   runs JVM + JS/ChromeHeadless):
   - registry entry with `serviceArguments = mapOf("svc" to "com.example.MissingService")` +
     `MapGraphEnvironment(mapOf())` → throws; message contains **both** the service FQN and the
     declaring class FQN (this is the "misregistered environment → named throw" JVM unit test the
     phase asked for, and it runs on JS too for free).
   - same registry + environment containing the key → passes.
   - registry entry whose service type is `GraphEnvironment.className` + empty environment →
     passes (pins the `contains` self-reference special case the `ScriptValidator` wiring
     depends on).
3. **Implicit regression net**: every existing kzen-auto-jvm test that goes through
   `KzenAutoContext.forTest()` now runs the assertion — a green `:kzen-auto-jvm:test` is itself
   proof the JVM environment covers the full registry.

## Verification

1. **JS deliberate-misspell smoke**: locally change one literal
   (`ClientContext.kt:119` → `"tech.kzen.auto.client.service.rest.ClientRestApiX"`), run
   `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`, load the page → root element shows
   `Error: @Service type not registered … ClientRestApi (declared by: …HeaderController, …)`.
   Revert; refresh → clean boot.
2. **JVM deliberate-miss smoke**: the JVM has no literals to misspell — instead comment out one
   env `put` (e.g. `TargetLocator`, `KzenAutoContext.kt:221`), run `BackendDevelopment` (IDE) or
   any `forTest()`-based test → boot throws naming
   `tech.kzen.auto.server.service.target.TargetLocator` and the Browser*Step /
   `TargetLocateAction` declarers. Revert; clean boot.
3. Baselines green: kzen-lib `:kzen-lib-common:jvmTest :kzen-lib-jvm:test`
   (`ServiceInjectionTest` unaffected — it builds its own environment and never boots a
   kzen-auto context); kzen-auto `:kzen-auto-common:allTests :kzen-auto-jvm:test`.
4. Optional belt-and-braces: `:kzen-auto-test:selfTest` (tester JVM exercises the
   `KzenAutoTestModule`-before-init coverage path with `KzenAutoConfig`).
5. Mark the R4 checkbox in `2026-07-18_reflection-improvements.md`'s progress tracker; as-built
   note on any deviation.

## Risks & gotchas

- **Forcing the JVM lazy at boot** moves `graphEnvironment` construction from first request to
  `init()`. Today that is a pure map build over already-constructed vals — zero behavior change.
  If a future entry does real work at construction, it now costs boot time (fine — fail-fast is
  the point). Under G3c this concern dissolves (eager env). Keep the comment fix (step 5) so the
  code doesn't claim request-time construction it no longer has.
- **Process-global registry + test ordering** (JVM): tests share `ReflectionRegistry.global`
  across a Gradle test JVM. A *future* hand-written fixture module that records
  `serviceArguments` for a type absent from `KzenAutoContext`'s environment would fail every
  *subsequent* `forTest()` boot in that JVM. Today none do (all six use the 3-arg `put`);
  the helper KDoc's "re-invokable" note plus this line are the record. If it ever bites, the
  fixture's service type belongs in the env or the fixture shouldn't use `@Service`.
- **Direction is registry → environment only.** Do not "improve" it with the reverse check —
  unused env keys are legitimate (hand-`resolve` consumers: `ReportLogicCompiler.kt:68-72`;
  downstream modules: `KzenAutoConfig` for kzen-auto-test's `StartKzenAutoStep`).
- **Do not route the check through `serviceClassNames` set membership** — only `contains` carries
  the `GraphEnvironment` self-reference special case (`MapGraphEnvironment.kt:24-27`).
- **Accessor on the class, not `ClassMirror`** — an interface addition would obligate third-party
  mirrors (and R1's reflective mirror can't implement it meaningfully).
- **R1-reflective-path plugin classes are outside this net** (not in the registry, not
  enumerable) — their `@Service` params keep instantiation-time failure. Accepted, recorded
  under Downstream-module coverage; R5 re-invokes the helper for registry-registered plugin
  modules only.
- **Doc drift found (not fixed here)**: kzen-auto's AGENTS/architecture docs refer readers to the
  kzen-lib architecture doc for the `@Service`/`GraphEnvironment` mechanism, but that doc
  currently contains **no such section** (grep: zero matches for `@Service`/`GraphEnvironment`).
  Out of R4's scope; worth a line in whichever kzen-lib doc session next touches architecture.md.

## Out of scope

- Generated service-constants object for the JS literals — **rejected** in the constituent plan
  (superseded by this cheaper validation); do not revisit.
- Reverse (environment → registry) validation / pruning the unused JVM env keys.
- Any `GraphEnvironment` / `MapGraphEnvironment` change (G3c owns provider registration).
- R1's `GlobalMirror.register` and the reflective mirror; R5's plugin-load re-validation call
  (the helper's re-invokability is provided, the call site is R5's).
- kzen-project SH4 registration work (covered automatically when it lands).
- Fixing the kzen-lib architecture-doc gap noted above.
