# R3 — KSP processor hardening — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-18_reflection-improvements.md` **Phase R3**. Decisions pre-made in the constituent
> plan — do not re-litigate: error on `@Reflect inner class`; fully-qualified type rendering
> (deletes the import machinery + allowlist); KDoc on `@Reflect` as the authoritative contract
> doc; KotlinPoet rejected; defaults-bypass documented, not fixed. Every anchor verified
> 2026-07-19 against kzen-lib HEAD `3d2ef97` and kzen-auto HEAD `ceb699d0`. **Zero drift**: the
> processor source was last touched 2026-06-03 (`d802916`), before the R plan was written; the
> Sprint-2 work landed since (SER2–SER5, Y, G5, G7, TP1/TP3/TP4) touched serialization, YAML,
> and trace transport — none of it touches `kzen-lib-reflect-ksp`, the generated modules'
> shape, or the `reflect/` package (confirmed by git log + reading the files). One session,
> low risk.

## Scope & goal

Make the known silent-bad-output and latent-uncompilable cases in
`ReflectSymbolProcessor.kt` loud errors or structurally impossible:

1. `@Reflect` on an `inner` class (generated `Outer.Inner(args)` call has no outer receiver —
   uncompilable generated code) → KSP `logger.error` naming the class.
2. Two constructor-param types with the same outer simple name from different packages →
   today generates conflicting imports (uncompilable generated file). Fix structurally:
   render **all** types fully qualified, deleting the import collection and the
   `isAutoImportedPackage` allowlist.
3. The `@Reflect` contract gets an authoritative KDoc (type-param erasure, defaults bypass,
   processed-source-set scope, registry-name convention, unsupported shapes).

Plus one processor-level fixture in kzen-lib-jvm's test source set pinning the
previously-clashing case, and the cross-repo regeneration check.

All code changes are in **kzen-lib** (`kzen-lib-reflect-ksp` + one KDoc in
`kzen-lib-common`); kzen-auto is rebuild-and-verify only, plus one cosmetic doc-sample touch.

## Dependencies & coordination

- **Independent — floats freely.** Master plan lists R3 as a Sprint-2 filler
  (`2026-07-16_master-plan.md:125–126`), sequencing rule 10 (`:222`): "R3/R4 float freely";
  filler row in the sprint map (`:323`).
- **R1 overlap (KDoc wording only).** R1 is planned in parallel (`next/R1_reflective-fallback-mirror.md`).
  The KDoc drafted below is worded to be correct **whether or not R1 has landed**. The one-line
  difference: **if R1 has already landed** when this session runs (check
  `GlobalMirror.kt` — R1 adds a `register(delegate)` API to the currently-immutable
  `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/reflect/GlobalMirror.kt:7–9`),
  append the marked optional sentence in step 3. If R1 lands *after* R3, R1's session owns
  adding that sentence (flag it in R3's as-built note so R1's executor sees it).
- **R4** touches `ReflectionRegistry` (new enumeration accessor) but not the processor or
  `Reflect.kt` — no file overlap with R3.
- **kzen-lib publishes first** (standing ground rule): the processor is consumed by kzen-auto
  as a published artifact `tech.kzen.lib:kzen-lib-reflect-ksp:0.30.0-SNAPSHOT` from mavenLocal
  (kzen-auto `buildSrc/src/main/kotlin/Dependencies.kt:9` — `kzenLibVersion = "0.30.0-SNAPSHOT"`;
  kzen-lib root `build.gradle.kts:8–9` — group `tech.kzen.lib`, version `0.30.0-SNAPSHOT`).
- **kzen-project / kzen-shell / kzen-launcher**: no action. kzen-project's own KSP module
  regenerates on its next build against the refreshed artifact; nothing in this phase changes
  the `ModuleReflection` SPI or wire behavior.

## Current-state findings — the processor map

**Module**: `C:\Users\ostro\IdeaProjects\kzen-lib\kzen-lib-reflect-ksp` — two source files,
no test directory (`src/main` only):

- `src/main/kotlin/tech/kzen/lib/reflect/ksp/ReflectSymbolProcessorProvider.kt` — reads the
  required KSP option `kzen.reflect.moduleClassName` (`:10–14`, constant `:25`). Untouched by R3.
- `src/main/kotlin/tech/kzen/lib/reflect/ksp/ReflectSymbolProcessor.kt` (302 lines) — the
  whole pipeline:

| Function | Lines | Role |
|---|---|---|
| `process` | :18–32 | `getSymbolsWithAnnotation(REFLECT_ANNOTATION_FQN)`; warns + skips non-class symbols (:22–25); `capture` each; collects source files for `Dependencies` |
| `finish` | :35–54 | one-shot emit; **skips emit when nothing collected** (:42–44 — the empty-test-pass collision guard); sorts by `registryName`; writes via `codeGenerator.createNewFile` with `Dependencies(aggregating = true, …)` |
| `capture` | :57–117 | builds `ReflectClass`: `registryName` (pkg + nested joined `$`, :65–67), `kotlinRef` (nested joined `.`, :69), **seeds the import set with `$pkg.${nestedSimpleNames.first()}`** (:71–75), `isObject` via `ClassKind.OBJECT` (:77), primary-ctor params → `ReflectArg(name, typeExpr, serviceTypeQualifiedName)` (:86–112); `@Service` detected by annotation-type FQN compare (:95–98); service type recorded as dotted `qualifiedName` (:104) |
| `nestedSimpleNames` | :120–128 | walks `parentDeclaration` while it's a `KSClassDeclaration` — **a local class silently yields a truncated path** (parent is a function, loop stops; no error today) |
| `renderType` | :131–175 | type-parameter → `Any`/`Any?` (:134–136); non-class declaration → `Any`/`Any?` (:138–139); **collects `$pkg.$outerSimple` into `importsOut` unless auto-imported** (:147–150); renders dotted nested ref + recursive generic args with variance (`out`/`in`, star → `*`) (:154–171); nullability suffix (:173) |
| `isAutoImportedPackage` | :178–188 | hard-coded allowlist: `kotlin`, `kotlin.collections`, `kotlin.ranges`, `kotlin.sequences`, `kotlin.text`, `kotlin.io`, `kotlin.annotation`, `kotlin.comparisons`, `kotlin.jvm` |
| `render` | :191–225 | merges per-class import sets (skipping imports whose package == the output package, :198–204) + two fixed imports (`ReflectionRegistry`, `ModuleReflection`, :196–197); emits header comment, package, imports block, `@Suppress("UNCHECKED_CAST", "KotlinRedundantDiagnosticSuppress")`, `object <Simple>: ModuleReflection { override fun register(reflectionRegistry: ReflectionRegistry) { … } }` |
| `renderRegistration` | :228–274 | three shapes: object (bare reference), no-arg (`Ctor()`), args (`args[i] as <typeExpr>` positional casts; optional `mapOf("param" to "service.Fqn")` third argument when any `@Service` params) |
| `escapeKotlinStringLiteral` | :277–279 | escapes `$` in string literals (registry names of nested classes) |
| data classes / constants | :282–301 | `ReflectClass` (carries `imports: Set<String>`), `ReflectArg`, annotation FQNs |

**KSP version**: `kspVersion = "2.3.9"` (kzen-lib `buildSrc/src/main/kotlin/Dependencies.kt:5`;
Kotlin 2.4.0 at `:4`). The processor compiles against
`com.google.devtools.ksp:symbol-processing-api:2.3.9` (`kzen-lib-reflect-ksp/build.gradle.kts:25`)
with a deliberate Java-17 target for the KSP worker JVM (`:10–19, 31–33`) — don't disturb that.
**API verification (done — from the 2.3.9 sources jar in the local Gradle cache):**
- `com.google.devtools.ksp.symbol.Modifier` includes **`INNER`** (`KSClassDeclaration.modifiers: Set<Modifier>`).
- `com.google.devtools.ksp.isLocal()` extension exists:
  `KSDeclaration.isLocal() = parentDeclaration != null && parentDeclaration !is KSClassDeclaration`.

**How the processor is exercised today** (no dedicated test module; coverage is
"consumers compile + their suites pass"):

- kzen-lib-common: `kspCommonMainMetadata` pass → `KzenLibCommonModule` (14 `@Reflect` files;
  `kzen-lib-common/build.gradle.kts:81, :85–87`, srcDir + task wiring `:94–103`).
- **kzen-lib-jvm: `kspTest` only** (`kzen-lib-jvm/build.gradle.kts:29`, module FQN
  `tech.kzen.lib.server.codegen.KzenLibJvmTestModule` at `:35–37`) — this is the processor's
  de-facto test bed, and it works **only because kzen-lib-jvm has no main-source KSP pass**
  (a main pass would emit a colliding FQN; the empty-main guard at processor `:42–44` is the
  other half of that). 24 `@Reflect` fixture files under
  `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/objects/`; registration happens in
  `JvmGraphTestUtils.init` (`kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/util/JvmGraphTestUtils.kt:28–31`
  — `KzenLibCommonModule.register()` + `KzenLibJvmTestModule.register()`); notation-driven
  assertion pattern in `NestedClassTest` / `AutowiredTest` / `ServiceInjectionTest` /
  `GraphCreatorTest`.
- kzen-auto: four consumers — common `kspCommonMainMetadata` (22 files), jvm `ksp` main
  (79 files → 74 registrations in the current generated `KzenAutoJvmModule.kt`), js `kspJs`
  (61 files), test `ksp` main (3 files) — ksp args at `kzen-auto-common/build.gradle.kts:79–80`,
  `kzen-auto-jvm/build.gradle.kts:205–206`, `kzen-auto-js/build.gradle.kts:101–102`,
  `kzen-auto-test/build.gradle.kts:51–52`.

**Confirmed latent (not live) bugs:** no `@Reflect inner class` exists anywhere in kzen-lib /
kzen-auto today (grepped all source sets), and no same-simple-name param-type clash exists
(all current generated modules compile). No `@Reflect` outside commonMain in any KMP module.

**Real generated output** (current, from
`kzen-lib-jvm/build/generated/ksp/test/kotlin/tech/kzen/lib/server/codegen/KzenLibJvmTestModule.kt`)
— used as the before-sample below. Useful existing edge-case fixtures visible in it: nested
(`NestedObject$Nested`), companion object (`CustomModel$Definer` → bare `CustomModel.Definer`
reference), type-param erasure (`Nested2(args[0] as List<Any?>)`), `@Service` map
(`ServiceHolder`), `$`-escaping, keyword param name (`EscapedObject`, `listOf("else")`).

## Pre-resolved questions

1. **Inner-class detection**: `Modifier.INNER in decl.modifiers` on the `KSClassDeclaration`
   — available in pinned KSP 2.3.9 (verified in the sources jar). No resolver call needed.
2. **Local classes ride along** (in-goal, not scope creep): `nestedSimpleNames` silently
   truncates a local class's path today — the same "silent bad output" class of bug R3 exists
   to kill, and the guard is two lines at the same site (`decl.isLocal()` from
   `com.google.devtools.ksp`). Latent (none exist); make it loud alongside `inner`.
3. **Extent of FQN rendering**: *everything* — the constituent plan says "deletes the
   allowlist", so `kotlin.*` types render fully qualified too (`kotlin.String`,
   `kotlin.collections.List<…>` — all valid Kotlin type references). The generated file ends up
   with **zero imports**: the two fixed imports (`ModuleReflection`, `ReflectionRegistry`) are
   also inlined as FQ references in the object header, so the entire import block, the
   per-class import sets, the same-package skip, and the allowlist are all deleted. The
   type-parameter erasure branch renders `kotlin.Any`/`kotlin.Any?` for uniformity (cosmetic).
4. **Fixture placement**: kzen-lib-jvm `src/test` (the `kspTest` bed) — new package
   `tech.kzen.lib.server.objects.clash` with sub-packages `alpha`/`omega` each holding a
   `Payload` class, plus one `@Reflect` holder taking both. Assertion is registry-direct (no
   notation YAML needed): the *compile* of the generated module is the real proof; the test
   pins registration + positional construction on top.
5. **Red step is optional but recommended**: adding the fixture *before* the rendering change
   makes `:kzen-lib-jvm:compileTestKotlin` fail with `Conflicting import: imported name
   'Payload' is ambiguous` inside the generated file — a 2-minute demonstration that the
   fixture actually covers the bug. Do it if convenient; not required.
6. **Docs**: the KDoc is the deliverable (pre-made decision — authoritative contract doc on
   `@Reflect`). One cosmetic follow-on: the representative generated entry in kzen-auto
   `docs/architecture.md:325–333` shows simple-name rendering
   (`DataFormatDocument(args[0] as FieldFormatListSpec)`) — update it to the FQ shape in the
   same session (ground rule: docs move with behavior). kzen-lib's architecture doc does not
   describe the rendering internals (checked) — no other doc drift. The kzen-auto AGENTS.md
   "`@Reflect` / KSP runs over `src/main` only" gotcha stays as-is (R2 owns rewording it).

## Step-by-step implementation

All edits in `C:\Users\ostro\IdeaProjects\kzen-lib` unless noted. Stage each new file
(`git add <explicit path>`, stage only) as soon as written.

### Step 1 — guards in `capture` (`ReflectSymbolProcessor.kt`)

Add import `com.google.devtools.ksp.isLocal`. At the top of `capture` (`:57`, before the
`pkg`/`nestedSimpleNames` computation):

```kotlin
private fun capture(decl: KSClassDeclaration): ReflectClass? {
    if (decl.isLocal()) {
        logger.error(
            "@Reflect is not supported on local classes (no stable class name): " +
                decl.simpleName.asString(),
            decl)
        return null
    }
    if (Modifier.INNER in decl.modifiers) {
        logger.error(
            "@Reflect is not supported on inner classes (the generated constructor call " +
                "would require an outer receiver): " + decl.qualifiedName?.asString(),
            decl)
        return null
    }
    // ... existing body unchanged
```

Notes: `logger.error` marks the round failed — KSP aborts the build after the round, so the
`return null` just keeps this run consistent (other diagnostics still surface). The local
check runs first because `qualifiedName`/`registryName` are meaningless for a local class.
`Modifier` and `KSClassDeclaration` are already imported via the existing
`com.google.devtools.ksp.symbol.*` import (`:4`).

### Step 2 — fully-qualified rendering (`ReflectSymbolProcessor.kt`)

Concrete edits, function by function:

- **`capture`** (`:57–117`): delete the `imports` sorted set and the `outerTopLevelImport`
  seed (`:71–75`). Change `kotlinRef` (`:69`) to the fully qualified constructor reference:
  ```kotlin
  val kotlinRef =
      if (pkg.isEmpty()) nestedSimpleNames.joinToString(".")
      else "$pkg.${nestedSimpleNames.joinToString(".")}"
  ```
  Call `renderType(resolvedType)` without the `importsOut` argument (`:93`). Construct
  `ReflectClass` without the `imports` argument (`:116`).
- **`renderType`** (`:131–175`): drop the `importsOut: MutableSet<String>` parameter; delete
  the import-collection block (`:147–150`); render the FQ reference:
  ```kotlin
  private fun renderType(type: KSType): String {
      val nullableSuffix = if (type.nullability == Nullability.NULLABLE) "?" else ""

      val decl = type.declaration
      if (decl is KSTypeParameter) {
          return "kotlin.Any$nullableSuffix"
      }
      val classDecl = decl as? KSClassDeclaration
          ?: return "kotlin.Any$nullableSuffix"

      val pkg = classDecl.packageName.asString()
      val nested = nestedSimpleNames(classDecl)
      if (nested.isEmpty()) {
          return "kotlin.Any$nullableSuffix"
      }

      val ref =
          if (pkg.isEmpty()) nested.joinToString(".")
          else "$pkg.${nested.joinToString(".")}"

      // generic-args block unchanged except the recursive call loses importsOut
      ...
      return "$ref$argsStr$nullableSuffix"
  }
  ```
  Variance rendering (`out`/`in`/`*`) and nullability stay exactly as-is.
- **`isAutoImportedPackage`** (`:178–188`): **delete the function.**
- **`render`** (`:191–225`): delete the imports merge (`:195–205`) and the `importsBlock`;
  qualify the two framework references inline:
  ```kotlin
  private fun render(moduleFqn: String, classes: List<ReflectClass>): String {
      val outputPkg = moduleFqn.substringBeforeLast('.', missingDelimiterValue = "")
      val outputSimple = moduleFqn.substringAfterLast('.')

      val registrations = classes.joinToString("\n\n") { c -> renderRegistration(c) }
      val body = if (classes.isEmpty()) "" else "\n$registrations\n"

      return buildString {
          append("// **DO NOT EDIT, CHANGES WILL BE LOST** - automatically generated by ReflectSymbolProcessor (KSP)\n")
          if (outputPkg.isNotEmpty()) {
              append("package $outputPkg\n")
          }
          append("\n\n")
          append("@Suppress(\"UNCHECKED_CAST\", \"KotlinRedundantDiagnosticSuppress\")\n")
          append("object $outputSimple: tech.kzen.lib.common.reflect.ModuleReflection {\n")
          append("    override fun register(reflectionRegistry: tech.kzen.lib.common.reflect.ReflectionRegistry) {")
          append(body)
          append("    }\n")
          append("}\n")
      }
  }
  ```
- **`ReflectClass`** (`:282–288`): remove the `imports: Set<String>` field.
- **`renderRegistration`** (`:228–274`) and **`escapeKotlinStringLiteral`** (`:277–279`):
  unchanged — `kotlinReference` and `typeExpr` arrive already fully qualified; registry-name
  `$`-escaping and the `@Service` map (already FQN strings) are untouched.

**Before/after generated-registration sample** (real entries from the current
`KzenLibJvmTestModule.kt`; whitespace as generated):

Before — imports at file head, simple-name references:

```kotlin
import tech.kzen.lib.common.model.location.ObjectLocation
import tech.kzen.lib.common.reflect.ModuleReflection
import tech.kzen.lib.common.reflect.ReflectionRegistry
import tech.kzen.lib.server.objects.nested.NestedObject
import tech.kzen.lib.server.objects.nested.user.NestedUser
import tech.kzen.lib.server.objects.service.SampleService
import tech.kzen.lib.server.objects.service.ServiceHolder

@Suppress("UNCHECKED_CAST", "KotlinRedundantDiagnosticSuppress")
object KzenLibJvmTestModule: ModuleReflection {
    override fun register(reflectionRegistry: ReflectionRegistry) {
reflectionRegistry.put(
    "tech.kzen.lib.server.objects.nested.user.NestedUser\$Nested",
    listOf("objectLocation", "delegate")
) { args ->
    NestedUser.Nested(args[0] as ObjectLocation, args[1] as NestedObject.Nested)
}

reflectionRegistry.put(
    "tech.kzen.lib.server.objects.service.ServiceHolder",
    listOf("label", "service"),
    mapOf("service" to "tech.kzen.lib.server.objects.service.SampleService")
) { args ->
    ServiceHolder(args[0] as String, args[1] as SampleService)
}
    }
}
```

After — no imports at all, FQ everywhere (`kotlin.*` included):

```kotlin
@Suppress("UNCHECKED_CAST", "KotlinRedundantDiagnosticSuppress")
object KzenLibJvmTestModule: tech.kzen.lib.common.reflect.ModuleReflection {
    override fun register(reflectionRegistry: tech.kzen.lib.common.reflect.ReflectionRegistry) {
reflectionRegistry.put(
    "tech.kzen.lib.server.objects.nested.user.NestedUser\$Nested",
    listOf("objectLocation", "delegate")
) { args ->
    tech.kzen.lib.server.objects.nested.user.NestedUser.Nested(args[0] as tech.kzen.lib.common.model.location.ObjectLocation, args[1] as tech.kzen.lib.server.objects.nested.NestedObject.Nested)
}

reflectionRegistry.put(
    "tech.kzen.lib.server.objects.service.ServiceHolder",
    listOf("label", "service"),
    mapOf("service" to "tech.kzen.lib.server.objects.service.SampleService")
) { args ->
    tech.kzen.lib.server.objects.service.ServiceHolder(args[0] as kotlin.String, args[1] as tech.kzen.lib.server.objects.service.SampleService)
}
    }
}
```

Other representative transforms: `PlusOperation(args[0] as List<DoubleExpression>)` →
`…PlusOperation(args[0] as kotlin.collections.List<tech.kzen.lib.server.objects.ast.DoubleExpression>)`;
type-param erasure `Nested2(args[0] as List<Any?>)` →
`…Nested2(args[0] as kotlin.collections.List<kotlin.Any?>)`; companion object reference
`CustomModel.Definer` → `tech.kzen.lib.server.objects.custom.CustomModel.Definer`.

### Step 3 — KDoc on `@Reflect`

`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/reflect/Reflect.kt` currently has
no KDoc (`:4–9`; keep the companion object untouched). Insert above `annotation class Reflect`:

```kotlin
/**
 * Marks a class (or Kotlin `object`, including companion objects) as instantiable by the kzen
 * graph layer through the cross-platform reflection registry. The KSP processor
 * (`kzen-lib-reflect-ksp`) scans each consuming Gradle module for `@Reflect` classes and
 * generates one [ModuleReflection] object per module (FQN set by the module's
 * `kzen.reflect.moduleClassName` KSP arg) whose `register()` records, per class: the registry
 * name, the ordered primary-constructor parameter names, any [Service] parameter types (by
 * fully-qualified name), and an all-positional constructor lambda.
 *
 * The contract:
 *
 * - **Primary constructor only, all-positional, defaults bypassed.** Instantiation supplies
 *   every parameter of the primary constructor, in declaration order — constructor default
 *   values are never used (the definition/notation layer is responsible for supplying every
 *   argument). Secondary constructors are ignored.
 * - **Type parameters erase to `Any` / `Any?`.** A use of a type parameter in a constructor
 *   parameter type renders as `kotlin.Any` (nullable: `kotlin.Any?`) in the generated cast;
 *   generics carry no runtime checking beyond that cast.
 * - **Registry name convention:** package plus the nested-class path joined with `$`
 *   (e.g. `com.example.Outer$Nested`), matching the JVM binary-name shape.
 * - **Processed source sets — sharp edge.** The processor runs only where the consuming build
 *   wires it: a multiplatform module's `commonMain` (via `kspCommonMainMetadata`) and a
 *   single-target module's main source set (via `ksp` / `kspJs` / `kspTest`). An `@Reflect`
 *   class in a KMP module's `jvmMain` or `jsMain` is **silently unprocessed** — it compiles,
 *   but is absent from the registry and fails at instantiation time
 *   (`IllegalArgumentException: Not found`). There is no Gradle-side guard; keep
 *   platform-specific `@Reflect` classes in single-target modules.
 * - **Not supported (processor error):** `inner` classes (the generated constructor call has
 *   no outer receiver) and local classes (no stable class name).
 *
 * See [Service] for constructor parameters supplied by the host's environment rather than
 * resolved from notation, and [ReflectionRegistry] / [ModuleReflection] for the runtime side.
 */
```

**R1-conditional sentence** — append to the "Processed source sets" bullet **only if R1 has
landed** (check `GlobalMirror` for a `register(delegate)` API):
`On the JVM, a host may install a reflective fallback mirror (see [GlobalMirror]) that serves
unregistered classes at runtime, logging each hit; Kotlin/JS has no such net.`
If R1 has not landed, omit it and note the handoff in the as-built note.

### Step 4 — clash fixture + test (kzen-lib-jvm `src/test`)

New files (stage each; JUnit 4 style like `NestedClassTest`):

- `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/objects/clash/alpha/Payload.kt`
  ```kotlin
  package tech.kzen.lib.server.objects.clash.alpha

  class Payload(val value: String)
  ```
- `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/objects/clash/omega/Payload.kt` — same
  shape, package `…clash.omega`.
- `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/objects/clash/ClashingParamsHolder.kt`
  ```kotlin
  package tech.kzen.lib.server.objects.clash

  import tech.kzen.lib.common.reflect.Reflect
  import tech.kzen.lib.server.objects.clash.alpha.Payload as AlphaPayload
  import tech.kzen.lib.server.objects.clash.omega.Payload as OmegaPayload

  @Reflect
  class ClashingParamsHolder(
      val first: AlphaPayload,
      val second: OmegaPayload
  )
  ```
  (The fixture source may alias; the *generated* code couldn't — that asymmetry is the bug.)
- `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/ClashingParamsTest.kt`
  ```kotlin
  package tech.kzen.lib.server

  // JUnit 4 asserts, per existing suites

  class ClashingParamsTest {
      @Test
      fun `same simple name param types register and construct`() {
          KzenLibJvmTestModule.register()

          val className = ClassName(
              "tech.kzen.lib.server.objects.clash.ClashingParamsHolder")
          assertTrue(ReflectionRegistry.global.contains(className))
          assertEquals(
              listOf("first", "second"),
              ReflectionRegistry.global.constructorArgumentNames(className))

          val instance = ReflectionRegistry.global.create(
              className, listOf(AlphaPayload("a"), OmegaPayload("b"))
          ) as ClashingParamsHolder
          assertEquals("a", instance.first.value)
          assertEquals("b", instance.second.value)
      }
  }
  ```
  Direct `KzenLibJvmTestModule.register()` is fine — `ReflectionRegistry.put` is
  last-write-wins (`ReflectionRegistry.kt:33–44`), so double registration with
  `JvmGraphTestUtils`-using suites is harmless. No notation YAML involved. The load-bearing
  assertion is that `:kzen-lib-jvm:compileTestKotlin` compiles the generated module at all;
  the runtime asserts pin names + positional order.

*Optional red step:* add these fixtures first and run
`./gradlew :kzen-lib-jvm:compileTestKotlin` — expect `Conflicting import` in the generated
file — then apply step 2 and watch it go green.

### Step 5 — kzen-auto doc-sample touch (kzen-auto repo)

`kzen-auto/docs/architecture.md:325–333` — update the representative `KzenAutoJvmModule.kt`
entry to the post-R3 shape (FQ constructor + FQ cast, no import assumption), e.g.
`tech.kzen.auto.server.objects.data.DataFormatDocument(args[0] as
tech.kzen.auto.common.objects.document.data.spec.FieldFormatListSpec)` — verify the actual
generated text after the rebuild and paste from it rather than hand-composing.

### Step 6 — bookkeeping

Tick `- [x] Phase R3` in `kzen/plans/2026-07-18_reflection-improvements.md:21`; strike R3 in
the master plan's filler list (`:125–126` / `:323`); delete (or mark done)
`kzen/plans/next/R3_processor-hardening.md`; append an as-built note on any deviation —
including whether the R1 KDoc sentence was included (step 3 handoff).

## Tests

- **New:** `ClashingParamsTest` (kzen-lib-jvm) — the previously-clashing case compiles,
  registers, constructs (step 4).
- **Existing edge-case coverage rides the regeneration** — the kzen-lib-jvm test fixture set
  already exercises nested (`NestedClassTest`), companion object + custom definer
  (`CustomModel$Definer`), type-param erasure (`Nested2`), `@Service` map
  (`ServiceInjectionTest`), autowiring (`AutowiredTest`), `$`-escaping and keyword param
  names (`EscapedObject`) — all must stay green against the FQ-rendered module.
- **No processor-unit tests** are added (no test infrastructure exists in
  `kzen-lib-reflect-ksp`, and standing up compile-testing harnessing is out of scope — the
  `kspTest` bed is the pinned strategy). The inner/local guards therefore ship without an
  automated negative test; verify them once manually (below) and rely on the loud-error
  property thereafter.

## Verification

From `C:\Users\ostro\IdeaProjects\kzen-lib` (Gradle JVM must be the JDK-26 toolchain —
`JAVA_HOME` / `-Dorg.gradle.java.home` → `C:\Users\ostro\.jdks\temurin-26.0.1`):

1. *(optional red step — see step 4)*
2. `./gradlew build` — regenerates `KzenLibCommonModule` + `KzenLibJvmTestModule` with FQ
   rendering; compiles all targets (common metadata/JVM/JS consume the regenerated commonMain
   module via the srcDir wiring); runs `:kzen-lib-common:jvmTest` + `:kzen-lib-jvm:test`
   including the new `ClashingParamsTest` and the reflection-adjacent suites
   (`AutowiredTest`, `NestedClassTest`, `ServiceInjectionTest`).
3. **Manual negative probe (one-off):** temporarily add `inner` to a nested test fixture
   (e.g. make a scratch `@Reflect inner class` inside `NestedObject`) →
   `./gradlew :kzen-lib-jvm:compileTestKotlin` must fail with the step-1 error message naming
   the class; revert. Repeat once with a local `@Reflect` class if cheap. (Scratch edits only
   — do not commit/stage them.)
4. `./gradlew publishToMavenLocal` — publishes kzen-lib-common/jvm/js **and**
   `kzen-lib-reflect-ksp` (all have mavenLocal publishing).
5. From `C:\Users\ostro\IdeaProjects\kzen-auto`:
   `./gradlew build --refresh-dependencies` — all four generated modules
   (`KzenAutoCommonModule`, `KzenAutoJvmModule` (74 registrations), `KzenAutoJsModule`,
   `KzenAutoTestModule`) regenerate under the new renderer; `:kzen-auto-jvm:test` (incl.
   `ScriptExtensibilityTest`, `TargetExtensibilityTest`, `FormulaStepTest`, Job suite) and
   `:kzen-auto-common` JS/JVM tests run as part of `build`. `selfTest` is NOT required
   (opt-in, opens Chrome; R3 doesn't touch runtime behavior).
6. Spot-read one regenerated file (e.g.
   `kzen-auto-jvm/build/generated/ksp/main/kotlin/tech/kzen/auto/server/codegen/KzenAutoJvmModule.kt`):
   zero imports, FQ references, registry-name strings and `@Service` map **byte-identical to
   before** (only the Kotlin-reference/cast rendering may differ — the registry runtime
   surface is unchanged).

Expected churn: every generated `ModuleReflection` file differs textually (imports gone, FQ
casts) — **cosmetic only**; registry names, argument-name lists, service maps, and
construction semantics are bit-identical.

## Risks & gotchas

- **Generated-file churn is expected, not a regression** — nothing hashes or diffs these files
  (all under gitignored `build/generated/ksp/`; no golden-file tests exist).
- **mavenLocal staleness**: forgetting `--refresh-dependencies` on the kzen-auto rebuild
  leaves the old processor artifact in play and the verification proves nothing. SNAPSHOT +
  refresh is the standing rule (kzen-auto consumes `0.30.0-SNAPSHOT` from mavenLocal).
- **Gradle JVM ≥ 25 constraint** (kzen-auto buildSrc pin) — build kzen-auto with the JDK-26
  toolchain or `:buildSrc` fails to resolve.
- **Don't disturb the reflect-ksp module's Java-17 target** (`build.gradle.kts:10–19`) — the
  processor jar runs in the KSP worker JVM, which lags the main toolchain.
- **The `finish()` empty-collection guard (`:42–44`) must survive untouched** — it's what lets
  kzen-lib-jvm's `kspTest` coexist with main-source passes elsewhere (and R2's future work
  leans on the same behavior).
- **KSP `logger.error` fails the build after the round completes**, not at the call site — the
  guard's `return null` plus the error is the correct pattern (already used at `:61, :89`);
  don't throw.
- **`kotlin.Any` uniformity change** in the type-parameter branch is deliberate but
  behavior-neutral; if any doubt arises mid-session, leaving those two branches as bare
  `Any`/`Any?` is equally correct — don't burn time on it.
- **R1 parallelism**: the only interaction is one KDoc sentence (step 3). If both sessions run
  the same day, whoever lands second reconciles `Reflect.kt` (trivial-merge territory).
- kzen-auto-test's generated module regenerates via `:kzen-auto-test:classes` during the full
  build even though `selfTest` isn't run — that compile *is* its verification here.

## Out of scope (pre-decided — do not re-open)

- KotlinPoet adoption (rejected; the hand-rolled renderer shrinks instead).
- Constructor default-value support (documented in the KDoc as bypassed; the
  definition/notation layer supplies every argument).
- A Gradle-side guard for `jvmMain`/`jsMain` `@Reflect` classes (infeasible from inside the
  processor; documented sharp edge + R1's JVM fallback log is the net).
- `kspTest` for modules with a main-source KSP pass (R2's recorded fallback, not R3's).
- ServiceLoader auto-discovery of `ModuleReflection` (rejected in the constituent plan).
- Any `ReflectionRegistry` / `ModuleReflection` / `ClassMirror` SPI change (R1/R4 territory).
