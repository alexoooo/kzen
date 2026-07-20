# R1 — JVM reflective fallback mirror — implementation plan

> **✅ DONE 2026-07-20.** Landed in one session, all 8 steps. Trackers ticked in
> `../2026-07-18_reflection-improvements.md` (Phase R1, carries the as-built note) and
> `../2026-07-16_master-plan.md` (Sprint-2 filler list). Verification: kzen-lib
> `:kzen-lib-common:jvmTest :kzen-lib-jvm:test` green (15 new tests) plus `:kzen-lib-common:jsTest`;
> `publishToMavenLocal`; kzen-auto `:kzen-auto-jvm:test --refresh-dependencies` — 435 tests, 0
> failures, and **zero** fallback INFO lines there, as predicted.
>
> Deviations: **contingency C1 fired** — KSP2 *does* process Java sources and emitted a broken
> no-arg `JavaServiceHolder()`, so the pre-decided `Origin.JAVA`/`Origin.JAVA_LIB` guard went into
> `ReflectSymbolProcessor.process` (R3's executor must re-verify its anchors there). Test files went
> to `server/reflect/` for CC-13 colocation rather than flat under `server/`; `JvmGraphTestUtils`
> gained a `reflectionRegistry` accessor for the parity assertions; the fallback log line states the
> JS requirement rather than asserting a registry fact the mirror cannot know. The R3-owned
> `@Reflect` KDoc sentence was **not** added here and is now applicable.
>
> ---
>
> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-18_reflection-improvements.md` **Phase R1**. Decisions pre-made in the constituent
> plan — do not re-litigate: **decision gate R1-G is decided — fallback-only** (generated
> registrations always win; do not make the JVM reflective-primary); the `@Reflect`-annotated-only
> gate is adopted; kotlin-reflect on kzen-lib-jvm is accepted; every fallback hit is logged.
> Every anchor verified 2026-07-19 against kzen-lib HEAD `3d2ef97` and kzen-auto HEAD
> `ceb699d0`. **Zero drift**: the `reflect/` package was last touched 2026-07-12 (`cb5f20e`),
> before the R plan was written; the Sprint-2 work landed since (SER2–SER5, Y, G5, G7,
> TP1/TP3/TP4) touched serialization, YAML codecs, and trace transport — none of it touches
> `reflect/`, `GlobalMirror`, the generated modules' shape, or either bootstrap's `register()`
> sequence (confirmed by git log + reading the files). One session, **medium risk**
> (reflective/generated parity — pinned by the tests below).

## Scope & goal

On the JVM, a class **not** registered in `ReflectionRegistry` can still be served by the graph
layer via real reflection — turning "every instantiable class must be KSP-processed at host
compile time" into "KSP is the fast/primary path; the JVM has a runtime net". Deliverables:

1. `GlobalMirror.register(delegate: ClassMirror)` — additive delegate-chain API in
   kzen-lib-common (`platformSynchronized` mutable list; `ReflectionRegistry.global` stays
   first; JS behaviour unchanged).
2. `ReflectiveClassMirror` in **kzen-lib-jvm** (`tech.kzen.lib.server.reflect`, new package) —
   kotlin-reflect based, `@Reflect`-gated, caching, logging every class it serves.
3. Parity tests in kzen-lib-jvm pinning "byte-match generated behaviour" (arg order, service-map
   keys, nested `$` names, `object` semantics, Java `-parameters`), plus fail-fast preservation.
4. Wire-up: `KzenAutoContext` + both repos' test bootstraps register the mirror; kzen-lib
   architecture-doc note.

**Not** in scope: deleting kzen-auto's hand-written test modules (R2), multi-classloader/plugin
support (R5), processor changes (R3 — except the named contingency below), `@Service` FQN boot
validation (R4).

## Dependencies & coordination

- **Chain opener.** Master plan: Sprint-2 filler chain **R1 → R2** (`2026-07-16_master-plan.md:127–130`),
  B5 pre-work item 0 (`:171–174`), sequencing rule 10 (`:220–223`): R2 and R5 both consume R1's
  mirror; R1 publishes kzen-lib to mavenLocal first. **R5 is additionally gated on the B5
  ratification session — not this session's concern beyond this note.**
- **R2 runs next session** (kzen-auto side). Two couplings R2's executor must know, recorded here
  because R1 creates them:
  - The `@Reflect`-only gate means R2's module deletions require **adding `@Reflect` to the
    kzen-auto test fixture classes** the deleted modules covered (safe: kzen-auto-jvm declares no
    `kspTest`, so no processor sees `src/test` — confirmed, `kzen-auto-jvm/build.gradle.kts:35`
    has only the main `ksp(...)` line; the `ScriptStepTestModule` doc comment says the fixtures
    "carry no `@Reflect` annotation",
    `kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/script/test/ScriptStepTestModule.kt:13–14`).
  - R1 wires the mirror into **both** kzen-auto bootstraps (`KzenAutoContext` companion init *and*
    `AutoTestUtils`), so R2's fixture resolution works under every test entry path.
- **R3 overlap (KDoc sentence only).** R3 is planned in parallel (`next/R3_processor-hardening.md`,
  its "Dependencies" §): whichever of R1/R3 lands **second** adds the one marked sentence to the
  `@Reflect` KDoc noting the JVM reflective fallback. If R3 has not landed when R1 runs, R1 adds
  nothing to `Reflect.kt` (R3 owns the KDoc) — just flag in R1's as-built note that the sentence
  is now applicable. Also: R1's **contingency C1** (below) would touch `ReflectSymbolProcessor.kt`
  — if it triggers and R3 has landed, apply it against R3's refactored file (trivial).
- **R4** touches `ReflectionRegistry` (new enumeration accessor) — no file overlap with R1's
  changes (R1 does not modify `ReflectionRegistry.kt`).
- **kzen-lib publishes first** (standing ground rule): kzen-auto consumes
  `tech.kzen.lib:kzen-lib-jvm:0.30.0-SNAPSHOT` from mavenLocal (kzen-auto
  `buildSrc/src/main/kotlin/Dependencies.kt:9`; kzen-lib root `build.gradle.kts:8–9` sets group
  `tech.kzen.lib`, version `0.30.0-SNAPSHOT`). After the kzen-lib half:
  `./gradlew publishToMavenLocal`, then kzen-auto builds with `--refresh-dependencies`.
- **kzen-project / kzen-shell / kzen-launcher: no action.** kzen-project boots through
  kzen-auto's `KzenAutoContext`, so it inherits the wire-up; its *static registration* problem is
  SH Phase 4 (independent code path, no ordering constraint — R plan header).
- **JS untouched**: `ClientContext.init` (kzen-auto-js `service/ClientContext.kt:39–40`) keeps its
  two `register()` calls; no reflective mirror exists on JS.

## Current-state findings

**The mirror chain (kzen-lib-common `src/commonMain/kotlin/tech/kzen/lib/common/reflect/`):**

- `ClassMirror.kt:6–14` — the 4-method interface: `contains`, `constructorArgumentNames`,
  `serviceArguments`, `create`.
- `GlobalMirror.kt:6–9` — `object GlobalMirror: ClassMirror` with **immutable**
  `private val delegates = listOf(ReflectionRegistry.global)`. Read methods loop delegates and
  dispatch to the first whose `contains` is true; `constructorArgumentNames`/`create` throw
  `IllegalArgumentException("Unknown: $className")` on total miss (`:28`, `:48`);
  `serviceArguments` returns `mapOf()` on total miss (`:38`) — **no throw**, preserve this.
- `ReflectionRegistry.kt:11–67` — the `platformSynchronized(registry) { … }` idiom R1's mutable
  list must follow exactly: every read (`get`, `:27–29`) and write (`put`, `:38–43`) wraps the
  shared mutable map. `put(className: String, constructorArgumentNames, serviceArguments:
  Map<String, String> = mapOf(), constructorFunction)` maps service values to `ClassName`
  (`:41`). `ReflectionRegistry.global` at `:17`.
- `platformSynchronized` expect/actual: expect
  `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/platform/PlatformSynchronized.kt:8`;
  JVM actual = `synchronized(lock, block)` (`jvmMain/.../PlatformSynchronized.kt:4–6`); **JS
  actual = bare `block()`** (`jsMain/.../PlatformSynchronized.kt:4–6`) — so the mutable-list
  change is free on JS, where nothing registers and the list stays single-delegate.

**GlobalMirror's only consumers (all in kzen-lib-common commonMain; kzen-auto has zero direct
`GlobalMirror`/`ClassMirror` references — grep-verified):**

- `objects/base/AttributeObjectCreator.kt:41` (`constructorArgumentNames` — defines arg order),
  `:75` (`create`).
- `objects/base/AttributeObjectDefiner.kt:112` (`serviceArguments` — routes `@Service` params to
  `ServiceAttributeDefinition` at **definition** time; notation-declared attribute of the same
  name wins, `:114–116`).
- `objects/bootstrap/DefaultConstructorObjectCreator.kt:24–25` (`create` with `emptyList()`).
- `service/metadata/MirrorMetadataReader.kt:26` (`constructorArgumentNames`).
- **Nobody calls `GlobalMirror.contains` externally** — so the fallback widening `contains` to
  "any loadable `@Reflect` class" changes no consumer's branch.

**Generated-registration ground truth** (sample:
`kzen-lib-jvm/build/generated/ksp/test/kotlin/tech/kzen/lib/server/codegen/KzenLibJvmTestModule.kt`,
regenerated by `kspTest` — `kzen-lib-jvm/build.gradle.kts:29` + module FQN arg `:35–37`):

| Behaviour | Evidence |
|---|---|
| Registry name = `pkg` + `.` + nested simple names joined `$` (== JVM binary name) | processor `ReflectSymbolProcessor.kt:65–67`; generated `"tech.kzen.lib.server.objects.custom.CustomModel\$Definer"` (`KzenLibJvmTestModule.kt:181`), `NestedObject\$Nested` (`:188`); notation uses the same form — `class: tech.kzen.lib.server.objects.nested.NestedObject$Nested` (`kzen-lib-jvm/src/test/resources/notation/test/nested-test.yaml:107`) |
| Kotlin `object` → `listOf()` arg names, factory returns the object reference | processor `:77–80`, `:233–240`; generated `CustomModel.Definer` (`:180–185`) |
| Arg names = primary-ctor params in declaration order, keyword names included | generated `listOf("else")` for `EscapedObject` (`:47–52`); `listOf("label", "service")` for `ServiceHolder` (`:217`) |
| No primary ctor **or** empty params → `listOf()` + `Ctor()` call | processor `:82–84`, `:241–248` |
| `@Service` map = param name → **dotted** declaration `qualifiedName` (no `$`, no `?`) | processor `:104` (`resolvedType.declaration.qualifiedName?.asString()`); generated `mapOf("service" to "tech.kzen.lib.server.objects.service.SampleService")` (`:215–221`); `put` wraps values in `ClassName` (`ReflectionRegistry.kt:41`) |
| Casts are positional `args[i] as T` — nullable types cast `as T?` (null passes) | generated `:72`, `:79` |
| Type params erase to `Any`/`Any?` | processor `:134–136` |

**Annotations** (kzen-lib-common `reflect/`):

- `Reflect.kt:4–9` — `annotation class Reflect` with **no explicit `@Retention` and no
  `@Target`** → Kotlin defaults: **`AnnotationRetention.RUNTIME`**, applicable to any
  declaration. Runtime-visible from both Kotlin and Java. ✓ (constituent-plan claim confirmed.)
- `Service.kt:11–12` — `@Target(AnnotationTarget.VALUE_PARAMETER)`, no explicit retention →
  **RUNTIME**. ✓ Because `VALUE_PARAMETER` is the *only* target, `@Service val x: T` in a primary
  constructor lands on the parameter (no use-site ambiguity), so `KParameter.annotations` sees it.

**Dependencies / toolchain:**

- `kzen-lib-jvm/build.gradle.kts:21–32` — deps today: `kzen-lib-common` (implementation),
  coroutines (api), guava, dexx, `kspTest(project(":kzen-lib-reflect-ksp"))`,
  `testImplementation(kotlin("test"))`. **No kotlin-reflect, no logging of any kind** (grep: zero
  slf4j/`LoggerFactory`/JUL anywhere in kzen-lib).
- **Trade-off already half-paid**: kzen-lib-common's jvmMain already declares
  `implementation(kotlin("reflect"))` (`kzen-lib-common/build.gradle.kts:55`) — kotlin-reflect is
  *already in the published runtime dependency graph* of every JVM consumer (though currently
  unused: the only `kotlin.reflect` import in kzen-lib is stdlib's `KClass`,
  `GraphDefiner.kt:27`). R1 adds only a compile-scope declaration in kzen-lib-jvm. kzen-auto-jvm
  also declares kotlin-reflect explicitly (`kzen-auto-jvm/build.gradle.kts:45`, versioned
  `$kotlinVersion`).
- Version idiom: kzen-lib uses the plugin-versioned `kotlin("test")` form; buildSrc constants for
  third-party versions (`kzen-lib/buildSrc/src/main/kotlin/Dependencies.kt` — `kotlinVersion =
  "2.4.0"`, no slf4j const yet).
- Logging downstream: kzen-auto-jvm ships `logback-classic` (`build.gradle.kts:51`, api) and uses
  slf4j `LoggerFactory` throughout (8+ files); **no JUL bridge anywhere** — so JUL/System.Logger
  output would bypass kzen-auto's log files. slf4j-api is the idiomatic pick (see Q4).

**Bootstraps (wire-up targets):**

- kzen-auto prod: `KzenAutoContext.kt:70–75` — companion `init { KzenLibCommonModule.register();
  KzenAutoCommonModule.register(); KzenAutoJvmModule.register() }`.
- kzen-auto tests: `AutoTestUtils.kt:30–34` — same three calls.
- kzen-lib-jvm tests: `JvmGraphTestUtils.kt:28–31` — `init { KzenLibCommonModule.register();
  KzenLibJvmTestModule.register() }`; also holds `testEnvironment` with a `SampleService`
  keyed `ClassName(SampleService::class.qualifiedName!!)` (`:36–38`) — note the **dotted**
  `qualifiedName` convention on the environment side too.

**Test conventions** (kzen-lib-jvm `src/test/kotlin/tech/kzen/lib/server/`): JUnit-4 style
(`org.junit.Test`, `org.junit.Assert.*` — `NestedClassTest.kt`, `ServiceInjectionTest.kt`,
`AutowiredTest.kt`); fixtures under `tech.kzen.lib.server.objects.*`; notation YAML under
`src/test/resources/notation/test/` (e.g. `service-test.yaml:5–9` — `class:` FQN + `meta:`,
`@Service` param deliberately undeclared). No `src/test/java` directory exists yet (the Kotlin
JVM plugin applies `java`, so `src/test/java` is picked up automatically once created).

**kzen-lib architecture doc**: no reflection section today — only the package-map line
`reflect/ — ClassMirror, ReflectionRegistry` (`kzen-lib/docs/architecture.md:209`) and the
codegen mention in the `meta:` gotcha (`:73`). The "SPI / extension points" section ends at
`:154` with the bootstrap definer/creator paragraph — the natural host for the new note (step 6).

## Pre-resolved questions

- **Q1 — retention/target claims: confirmed** (see findings). `@Reflect` RUNTIME by Kotlin
  default, any target; `@Service` RUNTIME, `VALUE_PARAMETER` only.
- **Q2 — registry-name → JVM name translation: identity.** The registry convention (`$`-joined
  nested names, dotted package) *is* the JVM binary name; `Class.forName(className.get(), …)`
  needs no transformation. (JS `ClassName` is likewise an opaque string; untouched.)
- **Q3 — `@Service` FQN form: dotted `qualifiedName`, both sides.** KSP records
  `declaration.qualifiedName` (dotted, even for nested types, no nullability suffix);
  kotlin-reflect's `KClass.qualifiedName` is identically dotted. Use
  `(param.type.classifier as? KClass<*>)?.qualifiedName` — **never `java.name`** (which would
  emit `$` and break `GraphEnvironment` key equality; keys are built from `qualifiedName` at
  `JvmGraphTestUtils.kt:37` and kzen-auto's `ClassName(...)` literals). Caveat recorded: a
  `@Service` param typed as a Kotlin-mapped platform type (e.g. `java.lang.String` vs
  `kotlin.String`) could diverge — no such param exists and none is plausible (services are
  domain classes); not worth code.
- **Q4 — logging mechanism: slf4j-api** (new `implementation` dep of kzen-lib-jvm + buildSrc
  const `slf4jVersion = "2.0.17"`, matching what logback `1.5.37` pulls into kzen-auto), plus
  `testRuntimeOnly("org.slf4j:slf4j-simple:$slf4jVersion")` so kzen-lib's own test runs show the
  fallback lines (without a binding, slf4j-api NOPs — the hits would be invisible exactly where
  the parity tests run). Rejected: JUL / `System.Logger` (zero-dep but bypasses kzen-auto's
  logback — no bridge installed, so hits would miss the `logs/` files); `println` (uncontrollable).
  "Log every fallback hit" is implemented as: **INFO once per class name on first successful
  resolution** (create/lookup paths then serve from cache without re-logging — graph rebuilds
  re-create objects on every notation edit, so per-call logging would spam), WARN once for an
  annotated-but-unusable class, DEBUG for a non-served probe. The mirror stays visible, never a
  silent second registry.
- **Q5 — mirror shape: class + well-known instance, not an `object`.**
  `class ReflectiveClassMirror(private val classLoader: ClassLoader = …)` with
  `companion object { val global = ReflectiveClassMirror() }`. R5's seam is then "register one
  mirror per plugin classloader" with zero R1 rework. All standard wire-ups register
  `ReflectiveClassMirror.global`, which together with `register()`'s identity-idempotence makes
  double-boot registration harmless.
- **Q6 — `GlobalMirror.register` semantics** (specified precisely in step 1): append-order chain;
  seeded head `ReflectionRegistry.global` is permanently first (generated registrations always
  win — R1-G); identity-deduped; reads snapshot the list under `platformSynchronized` and iterate
  outside the lock (no user constructor code runs under the monitor). JS: API exists but nothing
  calls it; single-delegate behaviour byte-identical; `platformSynchronized` JS actual is a
  passthrough.
- **Q7 — where the fallback is active in tests.** `JvmGraphTestUtils` and `AutoTestUtils` register
  the mirror in their `init` — so **both baseline suites run fallback-active**, which is itself
  the no-regression proof that registry-first precedence holds under the full graph load.
- **Q8 — end-to-end fixture strategy.** The genuine-registry-miss fixture must not be a Kotlin
  `src/test` class: kzen-lib-jvm *has* a `kspTest` pass, so any `@Reflect` Kotlin test class gets
  a generated registration and the fallback would never fire for it. The Java fixture
  (`src/test/java`) is the genuine miss — **expected** not to be captured by the KSP test pass,
  and the test suite **pins that expectation loudly** (`assertFalse(ReflectionRegistry.global
  .contains(...))`) so a KSP behaviour change can't silently rot the coverage. Contingency C1
  (risks section) covers the other outcome. The end-to-end notation test merges a **literal
  in-test document** into the scanned notation rather than adding a resource YAML, so the shared
  full-scan graph (used by every existing test) never depends on the Java fixture / `-parameters`
  config.
- **Q9 — parity-test strategy: compare against the generated module itself.** For every pinned
  behaviour, assert the reflective answer **equals `ReflectionRegistry.global`'s answer for the
  same class** (arg names, service map, object identity). Parity by construction — no
  hand-maintained expected values that could drift from the processor.

## Step-by-step implementation

### Step 1 — `GlobalMirror` mutable delegate chain (kzen-lib-common)

`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/reflect/GlobalMirror.kt` — replace
the immutable list (`:7–9`) and thread every read through a snapshot:

```kotlin
object GlobalMirror: ClassMirror {
    private val delegates = mutableListOf<ClassMirror>(
        ReflectionRegistry.global
    )


    /**
     * Append a fallback delegate to the mirror chain. Delegates are consulted in registration
     * order; [ReflectionRegistry.global] is seeded first and always wins, so generated (KSP)
     * registrations shadow any fallback and a fallback only sees genuine misses (decision R1-G:
     * fallback-only, never JVM-primary). Registering the same instance again is a no-op.
     * JS never registers anything here (no runtime reflection exists there): the chain stays
     * single-delegate and behaviour is unchanged.
     */
    fun register(delegate: ClassMirror) {
        platformSynchronized(delegates) {
            if (delegates.none { it === delegate }) {
                delegates.add(delegate)
            }
        }
    }


    private fun delegateSnapshot(): List<ClassMirror> {
        return platformSynchronized(delegates) {
            delegates.toList()
        }
    }

    // contains / constructorArgumentNames / serviceArguments / create:
    //  identical bodies to today, but `for (delegate in delegateSnapshot())`
}
```

Semantics preserved exactly: first-`contains` delegate wins each call;
`constructorArgumentNames`/`create` still throw `IllegalArgumentException("Unknown: $className")`
on total miss; `serviceArguments` still returns `mapOf()` on total miss. Import
`tech.kzen.lib.platform.platformSynchronized` (same as `ReflectionRegistry.kt:4`). Snapshot-then-
iterate keeps delegate calls (which may run user constructors) outside the monitor. This is the
only kzen-lib-common change — additive, SPI-safe (`ClassMirror`, `ModuleReflection`,
`ReflectionRegistry` untouched).

### Step 2 — build wiring (kzen-lib buildSrc + kzen-lib-jvm)

`kzen-lib/buildSrc/src/main/kotlin/Dependencies.kt` — add:

```kotlin
const val slf4jVersion = "2.0.17"
```

(2.0.17 = the slf4j-api that kzen-auto's logback 1.5.37 pulls; any 2.0.x aligns. Check the actual
transitive version with `./gradlew :kzen-auto-jvm:dependencies --configuration runtimeClasspath`
if in doubt and match it.)

`kzen-lib-jvm/build.gradle.kts` — in `dependencies { }` (after `:27`):

```kotlin
implementation(kotlin("reflect"))                          // version = Kotlin plugin (2.4.0), same idiom as kzen-lib-common:55
implementation("org.slf4j:slf4j-api:$slf4jVersion")        // fallback-hit logging; binding supplied by consumers (kzen-auto: logback)
testRuntimeOnly("org.slf4j:slf4j-simple:$slf4jVersion")    // make fallback hits visible in kzen-lib's own test runs
```

and after the existing `tasks.compileJava` block (`:40–42`):

```kotlin
tasks.compileTestJava {
    // The Java parity fixture (JavaServiceHolder) needs runtime-visible parameter names for the
    // reflective mirror; without -parameters, KParameter.name is null for Java constructors.
    options.compilerArgs.add("-parameters")
}
```

### Step 3 — `ReflectiveClassMirror` (kzen-lib-jvm, new package)

New file
`kzen-lib-jvm/src/main/kotlin/tech/kzen/lib/server/reflect/ReflectiveClassMirror.kt`
(package `tech.kzen.lib.server.reflect` — sibling of `server.notation` / `server.exec`).
Specification (executor writes the file from this; all behaviours are pinned by step 5's tests):

```kotlin
class ReflectiveClassMirror(
    private val classLoader: ClassLoader = ReflectiveClassMirror::class.java.classLoader
): ClassMirror {
    companion object {
        val global = ReflectiveClassMirror()
        private val logger = LoggerFactory.getLogger(ReflectiveClassMirror::class.java)
    }

    private sealed interface Entry {
        data class Instantiable(
            val constructorArgumentNames: List<String>,
            val serviceArguments: Map<String, ClassName>,
            val factory: (List<Any?>) -> Any
        ): Entry
        /** Loadable and @Reflect-annotated, but unusable — contains() is TRUE, methods throw [reason]. */
        data class Malformed(val reason: String): Entry
        /** Not loadable, or loadable but not @Reflect — contains() is FALSE (the gate). */
        data object NotServed: Entry
    }

    private val entries = mutableMapOf<ClassName, Entry>()   // guarded by synchronized(entries)
}
```

Resolution algorithm (`resolve(className)`, cached — **both positives and negatives**, since
`GlobalMirror` consults delegates on every graph define/create cycle):

1. `Class.forName(className.get(), false, classLoader)` — registry name IS the binary name (Q2).
   `ClassNotFoundException` (or `LinkageError`) → `NotServed` (DEBUG log).
2. **Gate**: `!clazz.isAnnotationPresent(Reflect::class.java)` → `NotServed` (DEBUG). (Java-level
   check — works identically for Kotlin and Java classes; `@Reflect` is RUNTIME, Q1.)
3. `val kClass = clazz.kotlin`. **Kotlin `object`**: `kClass.objectInstance != null` →
   `Instantiable(emptyList(), emptyMap(), { kClass.objectInstance!! })` — matches the generated
   shape (arg names `listOf()`, factory returns the singleton; `KzenLibJvmTestModule.kt:180–185`).
   (`objectInstance` initializes the class lazily here, mirroring generated first-touch.)
4. Constructor: `kClass.primaryConstructor ?: kClass.constructors.singleOrNull()` — the second
   arm is the Java path (Java classes have no primary constructor in kotlin-reflect). Neither →
   `Malformed("no primary constructor and ${n} constructors (ambiguous)")`.
5. Arg names: `ctor.parameters.map { it.name ?: return Malformed("constructor parameter names
   unavailable — for a Java class, compile it with javac -parameters") }` — declaration order,
   matching KSP order. (For a Java ctor, kotlin-reflect yields names only when `-parameters` was
   used; the message names the flag, per the constituent plan. A belt-and-braces
   `javaConstructor.parameters.all { it.isNamePresent }` check via `java.lang.reflect` is
   permitted if `KParameter.name` proves to return synthetic `arg0…` instead of null.)
6. Service args: params where `param.annotations.any { it.annotationClass == Service::class }`,
   `associate { it.name!! to ClassName(kClassOf(it.type).qualifiedName!!) }` where `kClassOf` is
   `type.classifier as? KClass<*>` (non-class classifier — a type parameter — → `Malformed`,
   matching the processor's own error on an unqualifiable service type,
   `ReflectSymbolProcessor.kt:105–108`). Dotted `qualifiedName`, never `java.name` (Q3).
7. Factory: `{ args -> try { ctor.call(*args.toTypedArray()) } catch (e:
   InvocationTargetException) { throw e.cause ?: e } }` — `call` is all-positional (defaults
   bypassed, same as generated code; never `callBy`), and unwrapping `InvocationTargetException`
   restores generated-code behaviour where a throwing constructor propagates its own exception.
8. On first resolution: `Instantiable` → `logger.info("Serving {} via JVM reflection (no
   generated registration)", className)`; `Malformed` → `logger.warn(...reason...)`.

`ClassMirror` methods on top of the cache: `contains` = entry is `Instantiable || Malformed`;
`constructorArgumentNames`/`serviceArguments`/`create` on `Malformed` throw
`IllegalArgumentException("$className: $reason")`; on `NotServed` throw
`IllegalArgumentException("Not found: $className")` (mirrors `ReflectionRegistry.kt:55`;
unreachable via `GlobalMirror`, which only dispatches after `contains`). `Malformed` deliberately
reports `contains == true` so the specific error (e.g. the `-parameters` hint) surfaces instead
of `GlobalMirror`'s generic `Unknown:` (the constituent plan's "clear error naming the flag").

KDoc the class with: purpose (JVM fallback net behind KSP registrations — R plan Phase R1),
the R1-G fallback-only rule, the `@Reflect` gate, the per-classloader-instance seam for plugin
loaders (R5), and the parity contract with generated registrations.

### Step 4 — test fixtures (kzen-lib-jvm)

1. **Java parity fixture** — new file
   `kzen-lib-jvm/src/test/java/tech/kzen/lib/server/objects/reflective/JavaServiceHolder.java`:

```java
package tech.kzen.lib.server.objects.reflective;

import tech.kzen.lib.common.reflect.Reflect;
import tech.kzen.lib.common.reflect.Service;
import tech.kzen.lib.server.objects.service.SampleService;

/**
 * Pure-Java @Reflect fixture served ONLY by the reflective fallback (never KSP-registered):
 * pins Java classloading, -parameters name extraction, and @Service detection on a Java
 * constructor — the R5 Java-plugin shape. See GlobalMirrorFallbackTest.
 */
@Reflect
public class JavaServiceHolder {
    private final String label;
    private final SampleService service;

    public JavaServiceHolder(String label, @Service SampleService service) {
        this.label = label;
        this.service = service;
    }

    public String getLabel() { return label; }
    public SampleService getService() { return service; }
}
```

   (Java→Kotlin test-source reference is fine — joint compilation; `SampleService` is an existing
   Kotlin test class, `objects/service/SampleService.kt`.)

2. **Unannotated fail-fast fixture**: none needed — reuse `SampleService` (verified: no
   `@Reflect`, absent from the generated module).

3. **Kzen-lib test bootstrap**: `JvmGraphTestUtils.kt:28–31` — append to `init`:

```kotlin
GlobalMirror.register(ReflectiveClassMirror.global)
```

   (+ imports). The whole kzen-lib-jvm suite now runs fallback-active (Q7).

4. **After first build, inspect** the regenerated
   `kzen-lib-jvm/build/generated/ksp/test/.../KzenLibJvmTestModule.kt`: `JavaServiceHolder` must
   **not** appear. If it does — or the generated file fails to compile — apply contingency C1.

### Step 5 — tests

Two new files in `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/` (JUnit-4 style, matching
`NestedClassTest` / `ServiceInjectionTest`). Full inventory in the Tests section; both reference
`JvmGraphTestUtils` so its `init` (module registrations + mirror) has run.

### Step 6 — kzen-lib docs

`kzen-lib/docs/architecture.md`:

1. Package-map line `:209` → `reflect/ — @Reflect/@Service, ClassMirror, GlobalMirror,
   ReflectionRegistry`.
2. Append a short block to "SPI / extension points" (after the bootstrap paragraph ending `:154`),
   titled **"Class instantiation — `GlobalMirror` and the JVM reflective fallback"**, covering
   (≈8–10 lines): notation `class:` FQN (nested classes `$`-joined = JVM binary name) →
   `GlobalMirror`, a delegate chain consulted in registration order with KSP-generated
   `ReflectionRegistry.global` seeded first and always winning; hosts append fallbacks via
   `GlobalMirror.register(...)`; on the JVM, `ReflectiveClassMirror` (kzen-lib-jvm
   `server/reflect/`) serves classes annotated `@Reflect` that have no generated registration —
   kotlin-reflect primary-constructor introspection, `@Service` params detected at runtime, Kotlin
   `object`s honoured, Java classes supported when compiled with `-parameters` — logging every
   class it serves (fallback-only by design: a log line means a registration is missing on JS,
   where no runtime net exists and codegen is mandatory); registered by `KzenAutoContext` and the
   test bootstraps, and per-classloader instances are the plugin seam (R5).
3. `Reflect.kt` KDoc: only per the R3 coordination rule (Dependencies section) — if R3 already
   landed, add its marked fallback sentence; otherwise touch nothing.

### Step 7 — publish + kzen-auto wire-up

1. kzen-lib: `./gradlew publishToMavenLocal` (root — publishes common/jvm/js/ksp, all
   `0.30.0-SNAPSHOT`).
2. kzen-auto edits (both bootstraps, symmetric one-liners + imports
   `tech.kzen.lib.common.reflect.GlobalMirror`, `tech.kzen.lib.server.reflect.ReflectiveClassMirror`):
   - `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/context/KzenAutoContext.kt` companion
     `init` (`:71–75`) — after `KzenAutoJvmModule.register()`:
     `GlobalMirror.register(ReflectiveClassMirror.global)`, with a brief comment (JVM fallback net
     for classes with no generated registration — test fixtures, non-KSP plugins; generated
     registrations always win).
   - `kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/util/AutoTestUtils.kt` `init`
     (`:30–34`) — same line (R2's fixture resolution depends on this path too).
3. kzen-auto build: `./gradlew :kzen-auto-jvm:test --refresh-dependencies`.

### Step 8 — bookkeeping

- Tick the R1 checkbox in `2026-07-18_reflection-improvements.md:19`; append an as-built note
  (deviations, the C1 outcome, whether the R3 KDoc sentence was added here or deferred).
- Do **not** touch kzen-auto `AGENTS.md` / `docs/architecture.md` § 8 — R2 owns those (its step 3).
- Stage new/edited files per the staging rule (explicit paths, both repos, never commit).

## Tests (the parity pins)

**File A — `ReflectiveClassMirrorTest.kt`** (fresh `ReflectiveClassMirror()` instance; every
assertion compares against `ReflectionRegistry.global`'s answer for the same `ClassName` where
one exists — parity by construction, Q9):

| # | Pin | Fixture | Assertions |
|---|---|---|---|
| A1 | Kotlin class, arg order | `StringHolder` | `constructorArgumentNames == registry's (listOf("value"))`; `create(listOf("hello"))` yields equal state to registry-created |
| A2 | Keyword param name | `EscapedObject` | names `== listOf("else")` == registry's |
| A3 | Nested `$` name | `NestedObject$Nested`, `NestedUser$Nested2` | `contains` true; names parity; `create(listOf(42))` → `foo() == 42` |
| A4 | Kotlin `object` | `CustomModel$Definer` | names empty; `create(emptyList())` **`assertSame`** registry's `create` result (both = `objectInstance`) |
| A5 | `@Service` map keys/values | `ServiceHolder` | `serviceArguments == registry's == mapOf("service" to ClassName("tech.kzen.lib.server.objects.service.SampleService"))`; names `== listOf("label", "service")`; `create(listOf("x", SampleService("t")))` works |
| A6 | Nullable arg | `StringHolderNullableRef` | `create(listOf(null))` succeeds |
| A7 | Generic ctor param (erasure) | `NestedObject$Nested2` | `create(listOf(listOf(11, 22)))` succeeds |
| A8 | Gate: unannotated | `SampleService` | `contains` **false** |
| A9 | Gate: not loadable | `ClassName("tech.kzen.does.not.Exist")` | `contains` false |
| A10 | Java class + `-parameters` + `@Service` on Java param | `JavaServiceHolder` | `contains` true; names `== listOf("label", "service")`; `serviceArguments == mapOf("service" to ClassName(...SampleService))`; `create` returns working instance |

**File B — `GlobalMirrorFallbackTest.kt`** (goes through `GlobalMirror`; `JvmGraphTestUtils`
bootstrap = modules + `ReflectiveClassMirror.global` registered):

| # | Pin | Mechanism |
|---|---|---|
| B1 | Registration order / registry-first (R1-G) | Register a stub `ClassMirror` claiming `StringHolder` with distinguishable answers → `GlobalMirror.constructorArgumentNames(StringHolder)` still returns the registry's `listOf("value")` |
| B2 | Fallback routing | Same stub claims a fictional `ClassName("tech.kzen.test.StubOnly")` → `GlobalMirror` serves the stub's answers (stubs must claim only names no other test uses — the chain is process-global with no unregister) |
| B3 | Genuine miss is fallback-served | `assertFalse(ReflectionRegistry.global.contains(javaServiceHolderCn))` — **the loud pin that kspTest did not capture the Java fixture** — then `GlobalMirror.create(javaServiceHolderCn, listOf("a", SampleService("b")))` succeeds |
| B4 | Fail-fast preserved | `GlobalMirror.create(ClassName(...SampleService), listOf("x"))` throws `IllegalArgumentException` (`Unknown:`) — unregistered **and** unannotated still fails fast with the mirror active |
| B5 | End-to-end graph path | `JvmGraphTestUtils.readNotation()` + an **in-test literal document** (`YamlNotationParser().parseDocumentObjects(...)`, modeled on `service-test.yaml:5–9`: `class: tech.kzen.lib.server.objects.reflective.JavaServiceHolder`, `label: "hello"`, `meta: { label: String }`, `service` undeclared) appended to the `DocumentPathMap` → `newObjectGraph(notation)` (default `testEnvironment` supplies the `SampleService`) → instance has `label == "hello"` and the injected service. Exercises `AttributeObjectDefiner:112` (fallback `serviceArguments` at definition time) **and** `AttributeObjectCreator:41/:75` (fallback names + create) |

Existing suites double as regression pins (Q7): `NestedClassTest`, `ServiceInjectionTest`,
`AutowiredTest`, `ObjectGraphTest`, … all now run with the fallback registered — any precedence
or behaviour leak shows up there.

## Verification

1. kzen-lib: `./gradlew :kzen-lib-common:jvmTest :kzen-lib-jvm:test` — new tests green, baseline
   (`AutowiredTest`, `NestedClassTest`, `ServiceInjectionTest` + full suite) green with the
   fallback active. Watch stdout for the mirror's INFO lines (slf4j-simple): expect
   `JavaServiceHolder` only — **any other class** appearing means a generated registration is
   unexpectedly missing.
2. Inspect regenerated `KzenLibJvmTestModule.kt` (step 4.4): no `JavaServiceHolder` entry, file
   compiles. Else → C1.
3. Optional sanity: `./gradlew :kzen-lib-common:jsTest` (GlobalMirror change compiles/behaves on
   JS; the publish in step 7 builds the JS klib regardless).
4. `./gradlew publishToMavenLocal` (kzen-lib root).
5. kzen-auto: `./gradlew :kzen-auto-jvm:test --refresh-dependencies` — baseline per ground rules
   (`ScriptExtensibilityTest`, `TargetExtensibilityTest`, Job suite, `FormulaStepTest`). The
   hand-written test modules still exist and still register (last-write-wins `put` is idempotent);
   the mirror sits behind them, unused by kzen-auto until R2 annotates the fixtures. Expect **zero
   fallback INFO lines** in kzen-auto's test output (nothing `@Reflect`-annotated is unregistered
   there yet).
6. Optional: `./gradlew :kzen-auto-js:compileKotlinJs` (proves the additive common API doesn't
   disturb the JS client compile; full JS build lands with R2's session anyway).

## Risks & gotchas

- **Parity (the headline risk, medium).** Every divergence channel is pinned: arg order (A1),
  keyword names (A2), nested `$` (A3), `object` identity (A4), service keys as dotted FQN
  (A5/A10/B5), positional-no-defaults construction (`ctor.call`, A1–A7), Java names (A10). Two
  accepted, documented non-parities: wrong-arity/wrong-type errors differ in exception *type*
  (kotlin-reflect `IllegalArgumentException` vs generated `ClassCastException`/NPE — both
  fail-fast); a Kotlin class with only secondary constructors is served if it has exactly one
  ctor (the processor would emit a broken `Foo()` no-arg call for that shape — R3 territory; the
  mirror is strictly more correct there).
- **C1 — kspTest captures the Java fixture** (KSP2's Java-source handling is the one genuinely
  uncertain behaviour; detected loudly by step 4.4 / test B3 / an uncompilable generated file).
  Contingency, pre-decided: add a one-line guard to `ReflectSymbolProcessor.process` (skip
  declarations with `origin == Origin.JAVA || origin == Origin.JAVA_LIB`, commented "Java classes
  are served by the JVM reflective fallback (R1); KSP registration is Kotlin-only"), regenerate,
  record in the as-built note (coordinate with R3 if it landed first — trivial merge). Principled,
  not a dodge: R5's Java plugins bypass KSP entirely by design.
- **`-parameters` and non-Gradle builds.** IntelliJ's default "Build and run using Gradle"
  honours `compileTestJava` args; a switched-to-IDEA-javac run would lose Java param names and
  fail A10/B3/B5 in-IDE only. The mirror's `Malformed` message names the flag, so the failure
  self-explains. Kotlin classes are unaffected (names live in `@Metadata`).
- **Process-global chain, no unregister.** `GlobalMirror.register` is append-only for JVM life —
  fine for the singleton bootstraps (idempotent by identity, Q5/Q6); test stubs must claim only
  fictional names (B2 note). Don't add an unregister "for tests" — it would invite registry
  mutation in prod code paths.
- **Negative caching is per-mirror-instance.** `NotServed` for a name later served by a
  *different* classloader is not poisoned (R5 registers fresh per-loader instances); within one
  loader the classpath is fixed for process life, so negatives are safe. Registry-registered
  names never reach the mirror at all (registry-first).
- **`contains` semantics widen** (true for any loadable `@Reflect` class) — verified zero
  external callers of `GlobalMirror.contains`, and `GlobalMirror.serviceArguments`'s no-throw
  miss behaviour is preserved, so no consumer branch changes.
- **Do not log per `create` call.** Graph creation re-instantiates on every notation edit; the
  once-per-class INFO (Q4) is the deliberate noise floor. Resist "upgrading" it in review.
- **slf4j in bare consumers**: a JVM consumer without a binding gets slf4j's one-time NOP notice —
  acceptable, standard; kzen-auto/kzen-project ship logback via `kzen-auto-jvm` (api `:51`).
- **Inner classes**: kotlin-reflect surfaces an inner class's ctor without the outer receiver as
  a VALUE param inconsistently with the processor's (broken) output — both sides are unsupported;
  R3 makes the processor error loudly. Don't special-case them in the mirror.

## Out of scope (pre-decided — do not re-open)

- **JVM-primary reflection** (R1-G decided fallback-only; re-opening requires a JS-side parity
  check to replace the lost log-line signal).
- **Deleting hand-written test modules / annotating kzen-auto fixtures / moving `src/main`
  fixtures** — R2 (needs this session's publish; couplings recorded in Dependencies).
- **Processor hardening** (inner-class error, FQN rendering, `@Reflect` KDoc) — R3; only C1's
  one-line guard may touch the processor, and only if triggered.
- **`ReflectionRegistry` enumeration / `@Service` FQN boot validation** — R4.
- **Plugin classloaders, `plugins.yaml`, classloader lifecycle** — R5, after B5 ratification
  (R1 only leaves the per-loader-instance seam, Q5).
- **ServiceLoader discovery, KotlinPoet, constructor defaults** — rejected in the constituent
  plan's out-of-scope list.
- **kzen-auto docs** (`AGENTS.md` gotcha, `architecture.md` § 8) — R2 step 3.
