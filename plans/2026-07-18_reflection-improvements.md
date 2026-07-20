# Cross-platform reflection (`@Reflect` / KSP / `ReflectionRegistry`) improvements — R1–R6

> **Status: planned.** Written 2026-07-18 after an end-to-end investigation of the reflection
> codegen mechanism, prompted by (a) an AI agent observed hand-editing "generated" reflection
> code — resolved below: it was editing the deliberately hand-written test `ModuleReflection`
> fixtures, which this plan makes unnecessary — and (b) the open question of dynamically
> loadable reflection support for third-party plugins. Executor: **one phase per session.**
> Each phase is self-contained: goal, design decisions (already made — do not re-litigate
> except at the marked decision gates), concrete steps with file anchors, and verification.
>
> Companion plans: `2026-07-06_custom-plugin-extensibility-analysis.md` (EXT — plugin-channel
> specifics live there; this document owns the reflection mechanics and **reshapes D1**: with
> R1, Java plugins need no KSP); `2026-07-16_shell-launcher-improvements.md` Phase 4 (the
> kzen-project *static* registration fix — the static cousin of R5; independent code paths, no
> ordering constraint); `2026-07-16_master-plan.md` Stage B5 (sequencing; R5 is gated on the
> B5 ratification session).
>
> **Progress tracker** (update as phases land):
> - [x] Phase R1 — JVM reflective fallback mirror (kzen-lib; enables R2 + R5) — **done 2026-07-20**
> - [x] Phase R2 — test-fixture / src-main pollution cleanup (kzen-auto; after R1) — **done 2026-07-20**
> - [x] Phase R3 — processor hardening (kzen-lib; independent) — **done 2026-07-20**
> - [ ] Phase R4 — `@Service` FQN coupling validation (kzen-lib + both bootstraps; independent)
> - [ ] Phase R5 — plugin dynamic reflection (D1 execution, reflection half; **after B5
>   ratification**)
> - [ ] Phase R6 — client-side plugins (D7): record the verdict (doc-only, no build work)

## Verdict — the mechanism stays

The current mechanism: `@Reflect`-annotated classes are scanned by the KSP processor
`kzen-lib-reflect-ksp` (`ReflectSymbolProcessor.kt`, ~300 lines), which emits one
`ModuleReflection` object per Gradle module (FQN from the module-global KSP arg
`kzen.reflect.moduleClassName`) containing positional-constructor registrations:
`reflectionRegistry.put(fqn, argNames, serviceArgMap) { args -> Ctor(args[0] as T0, …) }`.
Registration is manual ordered `register()` calls in `KzenAutoContext.init` (JVM) and
`ClientContext.init` (JS); a missing entry is a hard `IllegalArgumentException` with no
fallback.

**This stays.** Alternatives considered and rejected:

- **kotlinc compiler plugin (FIR/IR)** — strictly more power (could synthesize registrations
  without a source-visible module object), but compiler-plugin APIs churn with every Kotlin
  release; KSP is the stable, supported tier, and the generated source is inspectable and
  debuggable in a way IR synthesis is not.
- **Runtime-only reflection** — impossible on JS (Kotlin/JS has no runtime reflection;
  codegen is mandatory there regardless), and the pre-KSP runtime generator's git history
  (`935cbe5` and the trail of edge-case bugfixes before it: multiline, nested, inner-object,
  generics, star-imports, trailing commas) is the argument against reviving that family.
  Runtime reflection *does* return in this plan — but as a JVM-only **fallback** (R1), not a
  replacement.

**The "hand-edited generated code" finding.** No generated code is checked in or hand-edited
anywhere: all KSP output lives under gitignored `build/generated/ksp/` with do-not-edit
headers, never committed. What was being edited is the six **deliberately hand-written**
`ModuleReflection` test fixtures in `kzen-auto-jvm/src/test`
(`server/exec/script/test/ScriptStepTestModule.kt`,
`server/service/target/test/CssSelectorTargetType.kt` (`TargetTestModule`),
`server/exec/flow/test/FlowVertexTestModule.kt`, and the three Job worker test modules).
They exist because kzen-auto-jvm cannot run `kspTest` (the module-name arg is set via the
module-global `ksp { arg(…) }` block, so a test pass would emit a colliding FQN —
kzen-lib-jvm's `kspTest` works only because that module has *no* main-source KSP pass), and
the same constraint forces `@Reflect` notation-test fixtures (Flow example vertices, Job
synthetic workers) into `src/main`. Editing those fixtures by hand is *necessary* under the
current architecture; R1+R2 remove the need.

## Deliberately out of scope (decided; do not re-open inside a phase)

- **KotlinPoet adoption** — the hand-rolled renderer is ~300 lines and carries its weight;
  R3 shrinks it further (fully-qualified rendering deletes the import machinery).
- **ServiceLoader auto-discovery of `ModuleReflection`** — the processor emits a Kotlin
  `object` (no public no-arg constructor, so classpath-mode `ServiceLoader` can't instantiate
  it without a generated wrapper); JS has no ServiceLoader, so discovery would be
  JVM-asymmetric; the actual ordering risk is mild (`ReflectionRegistry.put` is
  last-write-wins and no FQN collisions exist today); and kzen-project's broken static
  registration is already planned in shell-launcher Phase 4. Explicit `register()` calls
  remain the documented pattern. Revisit only if R5 plugin loading wants discovery.
- **Constructor default-value support** — construction stays all-positional (the
  definition/notation layer always supplies every argument); documented in R3's KDoc instead.
- **Generated service-constants object** for the JS `ClassName` literals — superseded by R4's
  cheaper boot-time validation.

## Ground rules for every phase

- **kzen-lib changes publish first.** kzen-auto consumes kzen-lib from mavenLocal: after any
  kzen-lib change, `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`.
- **SPI compatibility is additive-only.** `ModuleReflection`, `ReflectionRegistry`,
  `ClassMirror`, `GlobalMirror` are implemented/consumed by kzen-auto, kzen-project, and
  third parties. New methods get defaults; never change existing signatures.
- **No flavour/type-specific branches in general layers** (the standing god-object rule).
- **Docs in the same session** as any behaviour change: kzen-auto `AGENTS.md` gotchas,
  `docs/architecture.md` § 8 (module registration), and kzen-lib architecture doc where the
  mirror model changes.
- **Verification baseline**: kzen-lib `./gradlew :kzen-lib-common:jvmTest :kzen-lib-jvm:test`
  (jvm: `AutowiredTest`, `NestedClassTest`, `ServiceInjectionTest` are the reflection-adjacent
  suites); kzen-auto `./gradlew :kzen-auto-jvm:test` (extensibility proofs:
  `ScriptExtensibilityTest`, `TargetExtensibilityTest`; plus the Job suite and
  `FormulaStepTest`). Mark the tracker checkbox when a phase lands; append an as-built note on
  deviation.

---

## Phase R1 — JVM reflective fallback mirror

**Goal:** on the JVM, a class *not* registered in `ReflectionRegistry` can still be
instantiated by the graph layer via real reflection — turning "every instantiable class must
be KSP-processed at host compile time" into "KSP is the fast/primary path; JVM has a runtime
net". This is what dissolves the hand-written test modules (R2) and the KSP-imposition on
Java plugins (R5).

**Design decisions:**

- `GlobalMirror` (`kzen-lib-common/.../reflect/GlobalMirror.kt`) currently holds an
  **immutable** `private val delegates = listOf(ReflectionRegistry.global)`. Add an additive
  registration API: `GlobalMirror.register(delegate: ClassMirror)` appending to a
  `platformSynchronized` mutable list (same synchronization idiom as `ReflectionRegistry`).
  Delegate order = registration order; `ReflectionRegistry.global` stays first, so generated
  registrations always win and the reflective path only sees genuine misses.
- New `ReflectiveClassMirror: ClassMirror` in **kzen-lib-jvm**, kotlin-reflect based:
  - `constructorArgumentNames(className)`: load the class (registry-name convention: nested
    classes join with `$` — translate to the JVM binary name, which matches directly),
    primary constructor via `KClass.primaryConstructor`, names via `KParameter.name`;
    Kotlin `object`s return the empty list and `create` returns `objectInstance`.
  - `@Service` params: detected via `KParameter.annotations` — feasibility verified:
    `@Reflect`/`@Service` have RUNTIME retention (Kotlin default; no explicit `@Retention`
    declared) and `@Service` targets `VALUE_PARAMETER`.
  - Java classes: `KParameter.name` needs `-parameters` javac output — document the caveat;
    fall back to `java.lang.reflect` with a clear error naming the flag when names are
    unavailable.
  - **Log every fallback hit** (class name + call site category) — the reflective path must
    stay visible, never a silent second registry.
  - Optional gate: only serve classes actually annotated `@Reflect` (recommended — keeps the
    net scoped to the declared surface, and R5 relies on the annotation as the plugin opt-in).
- **Decision gate R1-G — fallback-only vs JVM-primary.** *Decided: fallback-only.*
  JVM-primary (skip KSP on the JVM entirely) would silently mask registrations missing on JS,
  where the failure is runtime-only and late; fallback-only keeps JVM/JS registry parity
  observable (the log line is the tell), keeps fail-fast semantics for production classes,
  and confines the reflective path to test fixtures and non-KSP plugins. Do not re-open
  without a JS-side parity check to replace the lost signal.
- **Recorded trade-off:** kotlin-reflect (~3 MB) becomes a dependency of the published
  kzen-lib-jvm artifact (it is already on kzen-auto-jvm's and kzen-auto-test's classpaths).
  Accepted: kzen-lib placement serves kzen-lib's own tests, kzen-project, and any JVM
  consumer. (Fallback option, recorded but not chosen: host the mirror in kzen-auto-jvm —
  zero new kzen-lib deps, but unusable from kzen-lib tests and kzen-project.)
- Wire-up: `KzenAutoContext.init` (and kzen-lib's own JVM test bootstrap) calls
  `GlobalMirror.register(ReflectiveClassMirror)` after the module `register()` calls. JS is
  untouched (no reflective mirror exists there; `GlobalMirror` behaviour with a single
  delegate is unchanged).

**Steps:** kzen-lib-common `GlobalMirror` mutable delegates + `register()` → kzen-lib-jvm
`build.gradle.kts` kotlin-reflect dep → `ReflectiveClassMirror` → tests → publishToMavenLocal
→ kzen-auto wire-up.

**Verification:** new kzen-lib-jvm tests covering: Kotlin class with args, Kotlin `object`,
nested class (`$` registry name), `@Service` parameter, Java class (with `-parameters` on the
test fixture), unregistered-and-unannotated class still fails fast. Baseline suites green.
Risk: **medium** — reflective results must byte-match generated behaviour (arg order, service
map keys as FQN strings, nested-name convention); the tests above pin exactly that parity.

**As-built (2026-07-20).** Landed as planned. Deviations worth carrying forward:

- **Contingency C1 fired.** KSP2 *does* process Java sources: the `JavaServiceHolder` fixture was
  captured and emitted as a broken no-arg `JavaServiceHolder()` (KSP reports no primary constructor
  for a Java class), failing `compileTestKotlin`. Applied the pre-decided guard in
  `ReflectSymbolProcessor.process` — skip `Origin.JAVA` / `Origin.JAVA_LIB` declarations. **R3's
  executor inherits this**: the processor's `process()` now has a second `continue` guard above
  `capture()`. Registration is Kotlin-only by design; Java classes route to the fallback.
- **Test placement.** Both test files went to `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/reflect/`
  (colocated with `ReflectiveClassMirror`, CC-13) rather than flat under `server/`.
- **Registry access from tests.** `JvmGraphTestUtils.reflectionRegistry` was added — reading it
  initializes the object (so the modules and the mirror are registered) and hands back
  `ReflectionRegistry.global` for the parity assertions.
- **Log wording.** "Serving {} by JVM reflection — a generated registration is required on JS": the
  mirror cannot know whether a *generated* registration exists (a test probing a fresh instance
  directly bypasses the chain), so the message states the JS requirement instead of asserting a
  registry fact. Verification signal is unchanged — through `GlobalMirror`,
  `ReflectiveClassMirror.global` served only `JavaServiceHolder` across the whole kzen-lib-jvm
  suite, and **zero** classes across kzen-auto's 435 tests.
- **R3 KDoc sentence** on `@Reflect` was NOT added (R3 has not landed; per the coordination rule R3
  owns it). It is now applicable.
- Green: kzen-lib `:kzen-lib-common:jvmTest :kzen-lib-jvm:test` (15 new tests) and `:jsTest`;
  kzen-auto `:kzen-auto-jvm:test` — 435 tests, 0 failures.

---

## Phase R2 — test-fixture / src-main pollution cleanup (kzen-auto; after R1)

**Goal:** delete the hand-maintained mirror-of-generated-code fixtures the R1 net makes
redundant, and un-pollute `src/main` of test-only `@Reflect` fixtures.

**Steps:**

1. Retire five of the six hand-written test modules (`FlowVertexTestModule`,
   `RunWorkerTestModule`, `GatedWorkerTestModule`, `ScratchWorkerTestModule`,
   `TargetTestModule`) — their fixtures resolve via the reflective mirror. **Keep exactly
   one** (`ScriptStepTestModule`) as the pinned, documented proof that `ModuleReflection` is
   a trivially hand-implementable (including from Java) third-party contract — update its doc
   comment to say that is now its *only* purpose.
2. **Survey, then move** `@Reflect` fixtures currently forced into `src/main` (Flow example
   vertices, Job synthetic workers) to `src/test`: only those **not referenced by bundled
   notation YAML under main resources** may move — the survey is mandatory, not a blanket
   relocation. Record the resulting table (moved / stayed + why) in the as-built note.
3. Update kzen-auto `AGENTS.md` (the "`@Reflect` / KSP runs over `src/main` only" gotcha —
   now: main-source KSP + JVM reflective fallback; fixtures live in `src/test` on JVM; the
   JS module still has no test net) and `docs/architecture.md` § 8.

**Verification:** kzen-auto `:kzen-auto-jvm:test` green with the modules deleted — in
particular `ScriptExtensibilityTest` / `TargetExtensibilityTest` still prove third-party
registration (one via the kept manual module, the other via the reflective net — that
contrast is itself the coverage). Risk: **low** (deletion-heavy).

**Recorded fallback (not chosen):** a true `kspTest` pass via per-KSP-task arg override
(`KspTask`-level configuration / `CommandLineArgumentProvider`) to give the test source set a
distinct module FQN. Version-sensitive Gradle plumbing that has churned across KSP releases;
revisit only if the reflective net proves insufficient for some fixture class.

**As-built (2026-07-20).** Step 1 landed as planned; step 2's survey found nothing eligible to move;
one unplanned build fix was required.

- **KSP2 *does* process kzen-auto-jvm's test source set — the "there is no `kspTest`" premise was
  false.** The moment the fixtures gained `@Reflect`, `kspTestKotlin` emitted a **second**
  `tech.kzen.auto.server.codegen.KzenAutoJvmModule` (8 fixture registrations) which, because test
  output precedes the main classes on the test runtime classpath, **shadowed the real module and
  dropped all 74 production registrations**. The suite still passed — R1's mirror silently served
  57 production classes, i.e. exactly the JVM-primary mode R1-G rejected, arrived at by accident.
  Fixed at the root: `kzen-auto-jvm/build.gradle.kts` disables the task
  (`tasks.matching { it.name == "kspTestKotlin" }.configureEach { enabled = false }` — `named()`
  fails, KSP registers the task after configuration). **The `Serving … by JVM reflection` log is
  the assertion**: post-fix exactly the 8 fixtures appear, zero production classes. Any future
  module that grows an `@Reflect` test class needs the same guard.
- **Fixtures now carry `@Reflect`** (the mirror's gate), and the four standalone modules
  (`FlowVertexTestModule`, `GatedWorkerTestModule`, `RunWorkerTestModule`,
  `ScratchWorkerTestModule`) plus the in-file `TargetTestModule` are deleted, along with their
  `register()` calls in five tests. `ScriptStepTestModule` stays with its purpose restated.
  `TargetExtensibilityTest` now proves third-party registration through the *reflective* path while
  `ScriptExtensibilityTest` proves it through the *manual module* path — the intended contrast.
- **Step 2 survey — nothing moved.** No `@Reflect` class under `kzen-auto-jvm/src/main` is a
  relocatable test-only fixture:

  | Candidate | Verdict | Why |
  |---|---|---|
  | Flow example vertices (`IntRangeSource`, `DivisibleFilter`, `AppendText`, `CountSink`, `AccumulateSink`, `ReplaceProcessor`, `RepeatProcessor`, `SelectLast`, `RunLogicVertex`, `FlowInput/OutputVertex`) | stayed | archetypes in `notation/auto-jvm/flow/flow-vertex.yaml` — user-facing palette entries, not fixtures |
  | Job Workers (all of `objects/job/worker/`) | stayed | archetypes in `notation/auto-jvm/job/job-worker.yaml` — production |
  | `objects/custom/test/{AdhocDetached, AdhocTask, AdhocNamedImpl}` (the one `test` package under `src/main`) | stayed | referenced by bundled `notation/main/Custom.yaml`, so they must stay on the production classpath |

  The plan's premise ("Flow example vertices, Job synthetic workers were forced into `src/main`")
  did not hold — those are production types declared in bundled notation; the genuinely test-only
  fixtures were already in `src/test`, which is what step 1 addressed.
- **Surfaced, not acted on (CC-07):** `flow/vertex/PrimeFilter` and `script/step/browser/BrowserFocusStep`
  are `@Reflect` classes in `src/main` whose archetypes are commented out in notation — dead as far as
  the graph is concerned.
- Docs: kzen-auto `AGENTS.md` (the old "`src/main` only / no `kspTest`" gotcha replaced by two — the
  shadowing hazard with its grep-able symptom, and the fixture/mirror pattern) and
  `docs/architecture.md` § 8 (new "JVM reflective fallback" subsection).
- Green: `:kzen-auto-jvm:test` — 438 tests, 0 failures, 0 errors; kzen-auto `./gradlew build`.

---

## Phase R3 — processor hardening (kzen-lib; independent)

**Goal:** the known silent-bad-output and latent-uncompilable cases in
`ReflectSymbolProcessor.kt` become loud errors or go away structurally.

**Steps:**

1. **Error on `@Reflect inner class`** (KSP `logger.error` naming the class) — the current
   output `Outer.Inner(args)` doesn't compile without an outer receiver. Latent today (none
   exist); make it impossible to hit silently.
2. **Fully-qualified type rendering.** The import strategy (`renderType` collecting
   `$pkg.$outerSimple` imports + the hard-coded `isAutoImportedPackage` allowlist) breaks
   when two constructor-param types from different packages share an outer simple name (clashing
   imports, no aliasing). Render all non-auto-imported types fully qualified inside the lambda
   casts instead: deletes the import set, deletes the allowlist, immune to clashes. Generated
   files get uglier — irrelevant, nobody reads them (that's the point of this plan).
3. **KDoc on `@Reflect`** documenting the contract in one authoritative place: type
   parameters erase to `Any`/`Any?` in registrations; constructor defaults are bypassed
   (all-positional; the definition layer supplies every argument); processed-source-set scope
   (commonMain metadata + leaf-module main source sets only — an `@Reflect` class in a KMP
   module's `jvmMain`/`jsMain` is **silently unprocessed**; a Gradle-side guard isn't feasible
   from inside the processor, R1's fallback log is the JVM-side net, and the JS gap is a
   documented sharp edge).

**Verification:** regenerate all modules (`kzen-lib` + publish + `kzen-auto` full build with
`--refresh-dependencies`) — byte-diff of generated files is expected to churn (FQN rendering)
but both repos must compile and pass baseline suites; add a processor-level fixture with two
same-simple-name param types (the previously-clashing case) to the kzen-lib test module.
Risk: **low**.

**As-built (2026-07-20).** Landed as planned, with one step dropped on evidence:

- **The local-class guard was NOT added — it is unreachable.** KSP 2.3.9's
  `getSymbolsWithAnnotation` does not surface local declarations at all: a `@Reflect` local class
  inside a member function *and* inside a top-level function were both probed, and neither reached
  `capture()` (no error, no registration, absent from the generated module). A `decl.isLocal()`
  guard would therefore be code that can never run (CC-10), so only the `inner` guard shipped —
  verified firing by a scratch `@Reflect inner class`, which failed `kspTestKotlin` naming the
  class. The `@Reflect` KDoc records local classes as invisible-to-the-processor rather than as a
  processor error.
- **Fully-qualified rendering landed whole**: the per-class import sets, the framework imports, the
  same-package skip, and `isAutoImportedPackage` are all deleted; the two framework references are
  FQN constants. Generated modules now carry **zero** imports (checked `KzenAutoJvmModule`:
  74 registrations, 0 imports, `@Service` maps and registry-name strings unchanged).
- **Red step run**: with the fixture in place and the old renderer restored,
  `:kzen-lib-jvm:compileTestKotlin` fails with `Conflicting import: imported name 'Payload' is
  ambiguous` — the fixture demonstrably covers the bug.
- **R1's KDoc sentence was included** (R1 landed first): the "Processed source sets" bullet names
  the JVM reflective fallback, and a Kotlin-only bullet documents R1's Java-origin skip.
- Green: kzen-lib `./gradlew build` (incl. the new `ClashingParamsTest`) → `publishToMavenLocal`;
  kzen-auto `./gradlew build --refresh-dependencies` — 435 + 192 + 3 tests, 0 failures.

---

## Phase R4 — `@Service` FQN coupling validation (independent, light)

**Goal:** the silent JS-only runtime failure mode — `ClientContext.graphEnvironment` keys
services with hand-written `ClassName("literal.fqn")` strings (KClass.qualifiedName is
unavailable on JS) that must exactly match the KSP-recorded `@Service` parameter-type FQNs —
becomes a startup failure on both platforms.

**Steps:**

1. Additive `ReflectionRegistry` enumeration accessor — e.g.
   `fun serviceArgumentClassNames(): Set<ClassName>` (no enumeration of any kind exists
   today; keep it to exactly what validation needs).
2. Boot-time assertion in `ClientContext.initAsync` and `KzenAutoContext.init` (after all
   `register()` calls + environment construction): every registered service-argument
   `ClassName` must satisfy `graphEnvironment.contains(it)`; on failure, throw naming the
   missing FQN and the registered class that declares it. A typo in either the `@Service`
   parameter type or the JS literal now fails at startup with a name, not at graph-creation
   time on JS with a puzzle.

**Verification:** deliberately misspell one JS `ClassName` literal locally → boot fails with
the named FQN; restore → clean boot both platforms (`frontendDevelopment` smoke). Risk:
**low**.

---

## Phase R5 — plugin dynamic reflection (D1 execution, reflection half) — **after B5 ratification**

**Goal:** a plugin JAR can contribute notation-instantiable `@Reflect` classes (Script steps,
Workers, Flow vertices, Custom prototypes) — dynamically loaded reflection support on the
server, the strategic move EXT identified ("the extension ceiling is `ReflectionRegistry`,
not notation"). This phase is the *reflection mechanics*; plugin UX (upload, isolation,
listing) stays with EXT D2/D3.

**Design (updates EXT D1 by reference — record there, don't duplicate):**

- **Kotlin plugins:** the JAR ships its own KSP-generated `ModuleReflection` (the plugin
  build applies `kzen-lib-reflect-ksp` with its own `moduleClassName`), named in
  `META-INF/kzen/plugins.yaml` alongside/instead of definers; the server instantiates it from
  the plugin classloader and calls `register()` into `ReflectionRegistry.global` at plugin
  load. Archetype YAML ships as bundled notation in the JAR, merged via the existing
  classpath-overlay `ReadWriteNotationMedia`.
- **Java/Maven plugins (the actual `kzen-sample-plugin` shape): no KSP required at all.**
  With R1, `@Reflect`-annotated classes listed in `plugins.yaml` are resolved through the
  reflective mirror — the mirror just needs to consult the plugin classloader (extend
  `ReflectiveClassMirror` with additional-classloader registration, or register a
  per-plugin-loader mirror instance at load). No classpath scanning dependency; the
  `plugins.yaml` list stays the explicit manifest. This removes D1's implicit
  Kotlin+KSP-imposition on third parties.
- **Decision gate R5-G — plugin classloader lifecycle** (the under-acknowledged tension in
  D1): today's plugin loaders are deliberately **ephemeral** — `PluginDocument` /
  `PluginReportDefinitionRepository` open-and-close via `.use {}` (with the `System.gc()`
  jar-unlock nudge), fresh loader per report run. Registering constructor lambdas into the
  process-global registry **pins the classloader for JVM life**. *Recommended (matching D1):*
  pinned boot-time load + restart-to-upgrade, with the `.use{}` ephemeral pattern explicitly
  retired for registered plugins (the report-definer path can keep it until it, too, migrates).
  Ratify at B5; do not start the phase before.
- Registered plugin classes' `@Service` params resolve from the same `GraphEnvironment` —
  R4's boot validation runs *after* plugin load, extending its coverage to plugin modules
  for free.

**Verification:** the B5 acceptance criterion — `../kzen-sample-plugin` contributes a working
`@Reflect` Script step / Custom prototype usable from notation with **zero kzen-source
edits** — exercised both ways: a Kotlin test plugin with a KSP `ModuleReflection`, and the
pure-Java sample via the R1 reflective path. Risk: **high** (lifecycle change; classloader
pinning interacts with the Windows jar-lock behaviour the `.use{}` pattern existed for).

---

## Phase R6 — client-side plugins (D7): verdict only

**No build work — record the verdict in this doc and in EXT D7.**

- **The blocking fact:** a separately-compiled Kotlin/JS bundle does not share class identity
  with the host bundle — two compiled copies of kzen-lib-common mean `instanceof` checks,
  sealed hierarchies, and registry-typed lookups all fail across the boundary. "Just load
  another bundle that calls `register()`" cannot work, regardless of loader mechanics.
- **Verdict: declarative-first.** Server-registered plugin objects get client UI through the
  machinery the codebase already builds all extension on: generic attribute editors +
  notation-driven `display:` / archetype markers (the same contract Workers, Steps, Target
  types, and Flow vertices honour). This is the honest ceiling short-term, and it is a high
  ceiling — a plugin's document objects render with default chrome and structured editors
  with zero client code.
- **Real client-code plugins stay parked**, with the prerequisites named: a shared-library
  bundle-identity story for Kotlin/JS (does not exist today), a host registration hook with a
  versioned JS-facing API, or full isolation via iframes/web components (the only near-term
  escape hatch, at the cost of living outside the host component tree). Reopening trigger:
  a concrete plugin that needs more than the default chrome (same trigger EXT D7 records).

---

## Sizing and sequencing

| Phase | Repo(s) | Size | Risk | Depends on |
|---|---|---|---|---|
| R1 | kzen-lib (+ kzen-auto wire-up) | one session | medium (reflective/generated parity) | — |
| R2 | kzen-auto | one session | low (deletion-heavy; survey step) | R1 + publishToMavenLocal |
| R3 | kzen-lib | one session | low | — |
| R4 | kzen-lib + both bootstraps | light session | low | — |
| R5 | kzen-auto (+ kzen-auto-plugin SPI) | one–two sessions | **high** (classloader lifecycle) | R1; **B5 ratification** |
| R6 | docs only | — | — | — |

R3 and R4 float freely and are good filler sessions. R5 must not start before the Stage B5
decision session ratifies D1 (with R5-G folded into that ratification). R6 is recorded, not
scheduled.
