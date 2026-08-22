# DS1b — expression type-visibility fix (`isNameable` predicate + `isStreamType`) — implementation plan

> **Status: ready to execute.** Session 1b of the **DS** arc, added **2026-08-21b** by the second-pass
> review. Rationale
> **[`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md) §5.5a**
> (correction C2) and **§5.4a** (O6). Constituent plan: **—** (analysis doc is the record; delete on
> landing, as-built → analysis **§14**). Anchors verified 2026-08-21. Sized **S**; kzen-auto-jvm only.
> Ledger row 51. **May ride inside DS1** — it is separate here because it is a *standing bug*
> independent of the arc, and worth landing on its own merits.
>
> **The bug, in one line:** every classifier outside an eleven-entry hardcoded whitelist is erased to
> `Any` before it reaches a lane, so a `DataUnit` on a Job channel would type as `Any` and the
> expression route's headline case (`items(payload.part("main"))`) would not compile.

## Scope & goal

Two changes in `ExpressionReturnTypeInference`, both general and neither data-source-specific:

1. **Replace the visibility whitelist with a predicate.** `visibleBuiltins` + `ObjectRegistryScan` →
   *is this class nameable from generated code?* — public, has a qualified name, not synthetic.
2. **Widen the stream classification.** `isIterable` → `isStreamType` covering
   `Iterable | Sequence | Iterator`; `iterableElementType` → `streamElementType`. This is **O6**, and
   without it every lazy read silently becomes a single message.

Deliberately **not** in scope: adding the DS model types to `visibleBuiltins` (hardcoding first-party
names into a general mechanism) or declaring them in an `ObjectRegistry` document (routing first-party
code through an unfinished third-party extension mechanism). Both were considered and rejected — see
analysis §5.5a.

## Dependencies & coordination

- **No prerequisite.** Independent of DS0/DS1; sequence it wherever convenient before **DS3** (which
  publishes `DataUnit` as a payload type) and **DS5** (which compiles expressions against it).
- **`FormulaStepTest` is the canary** (AGENTS gotcha): it reads the compiler's inferred `KType` through
  this exact class. A regression here surfaces as a *wrong inferred type*, not a build failure.
- **Script shares the mechanism.** `StepExpressionCompiler` uses the same probe contract, so a Script
  `ForEachStep` over a `Sequence` gains its element type from change 2 for free. Verify, do not assume.
- **Blast radius is every inference-mode expression** in both flavours. That is the point — it is also
  why the tests below matter more than the diff size.

## Current-state findings (anchors verified 2026-08-21)

- **`ExpressionReturnTypeInference`** (`…server/objects/logic/`):
  - `visibleBuiltins` is a `setOf(...)` of **eleven** `ClassName`s — `kotlin.Unit`, `Any`, `String`,
    `Boolean`, `Int`, `Long`, `Double`, `List`, `Set`, plus two hand-added with explanatory comments:
    `kotlin.ranges.IntRange` ("`1..100` infers to IntRange; recognize it so the expression … is typed")
    and `kotlin.collections.Iterable`.
  - `toTypeMetadata(kType, objectRegistryScan)`: if `className !in visibleBuiltins && className !in
    objectRegistryScan.classNames`, returns `TypeMetadata(kotlinAny, listOf(), nullable)`. **This is the
    erasure.** Generic arguments recurse through the same gate.
  - `isIterable(kType)` = `classifier.isSubclassOf(Iterable::class)`; `iterableElementType` projects
    onto the `Iterable` supertype via `allSupertypes.firstOrNull { it.classifier == Iterable::class }`,
    resolving one level of type-parameter substitution.
  - `inferReturnKType(clazz)` reads the `probe` property's last type argument — unchanged by this
    session.
- **The KDoc already states the real question**: a type is "visible" when it is not "an internal /
  synthetic type a downstream expression could not import". The whitelist is a proxy for that.
- **Why importability is the constraint**: `CalculatedColumnEval.generateImports` emits
  `import <qualifiedName>` for the model type and each parameter type (via `ClassNames.asTopLevelImport`)
  into generated Kotlin source, compiled by `CachedKotlinCompiler` against
  `ClassLoaderUtils.dynamicParentClassLoader()`.
- **`ObjectRegistryScan`** (`common/objects/document/registry/model/`) is a single-field
  `Set<ClassName>`. Its **only reader** is `ExpressionReturnTypeInference`; `WorkerLane`'s
  `WorkerLaneContext` and `ScriptDefinitionContext` merely carry it. It is produced by
  `ObjectRegistryDocument.scan(graphNotation)` (Caffeine cache keyed on `Digest`). The shipped
  `notation/auto-jvm/registry/registry-jvm.yaml` declares exactly one class: `kotlin.ranges.IntRange`.
- **Callers of `isIterable` / `iterableElementType`**: `FormulaSourceWorker` (both, in `produce` and
  `payloadFlow`). Script's loop typing goes through `toTypeMetadata` only. Confirm with a grep before
  renaming — a rename is safer than an overload here.
- **Tests**: `ExpressionReturnTypeInferenceTest` exists and already has an `emptyScan` and a
  registry-scan case (`ObjectRegistryScan(setOf(ClassName("java.util.UUID")))`) — that second test is
  the one whose *premise* changes.

## Pre-resolved questions

1. **The predicate.**
   ```kotlin
   private fun isNameable(kClass: KClass<*>): Boolean =
       kClass.qualifiedName != null &&              // excludes local / anonymous
       kClass.visibility == KVisibility.PUBLIC &&   // excludes internal / private / protected
       !kClass.java.isSynthetic
   ```
   No loadability check: the `KType` was reflected off a class already loaded by the expression's own
   classloader, so "can it be resolved" is given; what remains is "can generated source *name* it".
2. **Mapped builtins are the one edge to pin.** `kotlin.Int` / `kotlin.collections.List` have Kotlin
   qualified names that do not correspond to a JVM class of that name. Generation must keep using
   `qualifiedName` + `ClassNames.asTopLevelImport` (which already handles the no-import-needed cases);
   the predicate must not be tempted into a `Class.forName(qualifiedName)` check, which would reject
   them. The tests below pin this.
3. **Nested / inner classes.** `qualifiedName` uses `.` where the JVM uses `$`. Generation already uses
   the Kotlin form; a nested public class is nameable and should stay concrete.
4. **`ObjectRegistry`'s fate (O17).** Keep the document, keep the parameter threading, but make the scan
   a **widening** set — consulted only for classes the predicate rejected. Empty the shipped
   `IntRange` entry from `registry-jvm.yaml`, since the predicate now covers it. Retiring the document
   entirely is a **separate, user-facing decision** and is not taken here.
5. **Rename or overload for `isStreamType`?** Rename, and update both `FormulaSourceWorker` call sites.
   A leftover `isIterable` would be a trap: it would keep compiling and keep classifying a `Sequence` as
   single-emission.
6. **Element type for the three stream kinds.** One helper, projecting onto whichever of
   `Iterable` / `Sequence` / `Iterator` the classifier reaches, reusing the existing
   `allSupertypes.firstOrNull` + type-parameter-substitution logic verbatim. A type implementing more
   than one (e.g. `DataItems : Sequence`) resolves through the first match; the element type is the
   same either way, but fix the probe order and state it.

## Step-by-step implementation

### Step 1 — `isStreamType` / `streamElementType`

Rename `isIterable` → `isStreamType`, extend the classifier test to `Iterable | Sequence | Iterator`;
rename `iterableElementType` → `streamElementType` and generalize its supertype probe. Update
`FormulaSourceWorker`'s two call sites and its KDoc (which currently says "an `Iterable`-typed
expression is streamed").

### Step 2 — `isNameable`

Replace the `className !in visibleBuiltins && className !in objectRegistryScan.classNames` gate in
`toTypeMetadata` with `!isNameable(kClass) && className !in objectRegistryScan.classNames`. Delete
`visibleBuiltins`. Keep the `objectRegistryScan` parameter (Pre-resolved 4) and rewrite the class KDoc
to state the predicate instead of the whitelist — including *why* it is not a loadability check.

### Step 3 — empty the shipped registry

`registry-jvm.yaml`: `classes: []`. One line, and the `IntRange` test below is what proves it is safe.

## Tests

All in `ExpressionReturnTypeInferenceTest` (jvm) unless noted.

1. **Builtins stay concrete without a whitelist** — `kotlin.Int`, `kotlin.String`,
   `kotlin.collections.List<String>` (generic argument concrete too), and **`kotlin.ranges.IntRange`**
   with an **empty** registry scan. The IntRange row is the one that pins Pre-resolved 2 and licenses
   Step 3.
2. **A first-party public class stays concrete** with an empty scan — use a real one from the tree
   (after DS1, `DataUnit`; before it, any public kzen-auto value class), asserting the exact
   `ClassName`, not just "not Any".
3. **An `internal` class erases to `Any`** — declare one in the test source. This is the property the
   whitelist existed to protect and the single most important row.
4. **A local / anonymous type erases to `Any`** (`qualifiedName == null`) — an object expression.
5. **Nullability survives erasure** — an erased type keeps `isMarkedNullable`, unchanged behaviour.
6. **The registry still widens** — a class the predicate rejects but the scan declares stays concrete
   (adapt the existing `java.util.UUID` test, whose premise flips: UUID is public, so it now passes on
   the predicate alone; pick an `internal` class for the widening case instead).
7. **Stream classification** — `listOf(1)` → stream of `Int`; `sequenceOf("a")` → stream of `String`;
   `(1..5)` → stream of `Int`; `listOf(1).iterator()` → stream of `Int`; a nullable `List<String>?` →
   stream, nullable; a non-stream (`"x"`, `42`) → not a stream.
8. **`FormulaSourceWorkerTest` addition** — a `Sequence`-valued expression streams element-by-element
   rather than emitting one message holding the sequence. This is O6's user-visible effect.
9. **`JobValidatorTest` addition** — a lane whose source expression yields a first-party type publishes
   that type, not `Any`.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test` — the new/changed suites plus the whole
   `objects/logic`, `objects/job` and `exec/job` nets.
2. **`FormulaStepTest` explicitly, from a cold cache** (AGENTS canary): clear `<workdir>/code-cache`
   first, then `./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest"`. This session changes what the
   walk publishes for *every* expression, so a silently wrong inferred type is the realistic failure
   mode, not a red build.
3. **Script-side spot check** — a `ForEachStep` over a `Sequence`-valued expression gets its element
   type. If `StepExpressionCompiler` turns out not to share the path, record that in the as-built rather
   than widening scope.
4. `./gradlew :kzen-auto-js:compileKotlinJs` — `TypeMetadata` crosses to the client; nothing should
   change, and the compile is the cheap proof.
5. As-built → analysis **§14**; tick ledger row 51; delete this file.

## Risks & gotchas

- **Silent regressions are the failure mode.** Nothing here breaks a build; it changes what type a lane
  advertises. The tests must assert exact `ClassName`s, and the `FormulaStepTest` canary must run cold.
- **A newly-concrete type must actually be importable.** If a type passes the predicate but the
  generated `import` fails to compile, the symptom is a user-visible compile error in an expression that
  used to work (it would previously have been `Any`). Test 2's assertion is the guard; if a real case
  surfaces, the fix is in `ClassNames.asTopLevelImport`, not in re-adding a whitelist.
- **Do not delete `ObjectRegistry`** in this session (O17). It is user-facing, and the decision is the
  user's; emptying its shipped entry is enough to prove the predicate covers it.
- **Do not add DS model types anywhere in this file.** If the fix is correct they need no registration,
  and a registration would hide a failure of the fix.
- **`code-cache` staleness** — generated-class shape is unchanged by this session, so cached artifacts
  remain valid; that is *why* the canary must be run cold, to test the compile path rather than the
  cache.

## Out of scope (this session)

- Retiring the `ObjectRegistry` document (O17) — user's call.
- `CalculatedColumnEval` generated-class changes (object scope, `setObjects`) — **DS5**.
- Anything data-source-specific: this session must not mention `DataUnit` outside a test fixture.
