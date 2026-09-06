# HS13 — Plain-object shapes and expression inference

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS01; independent of E2 runtime sessions, serialize shared-file edits.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E7 items 1–4 and 6.

## Outcome and anchors

kzen-lib-jvm DefaultNativeTypeResolver, DefaultDataAdapterRegistry, NativePropertyPlans and native-token creation; kzen-auto JobExpressionCompiler.

## Work

1. Implement E7's exact ordinary-class property convention, including lexical order, getter/field precedence, inheritance, boolean isX, excluded members, nullability and named conflicting-type/getter errors.
2. Add enum-to-text and Set-as-unordered-Listing in both description and access. Preserve record/data-class component order. Iterator/Sequence remain streaming-only, not automatic nested values.
3. Cache native type tokens by Class identity, keeping equal class names from different loaders distinct.
4. Describe the JVM expression's inferred KType through the adapter registry so design-time and runtime shapes agree without constructing a sample object or invoking getters.
5. Publish changed kzen-lib artifacts before kzen-auto validation. Keep recursive occurrences finite under the current behavior until HS14 introduces named references.

## Verification and exit criteria

Test ordinary Java classes, inherited fields/getters, nullability, conflicts and throwing getters; enums/Sets in describe and lift; loader-local token identity. A Job expression returning a POJO collection shows columns before any execution and emits those columns. Run the FormulaStepTest canary and affected JVM tests.

## Handoff

E7 remains partial pending recursive contracts in HS14. Record actual adapter/inference APIs so HS19 need not rediscover them.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-lib-common `jvmMain` (`exec/data/value`, `exec/data/type`) and kzen-auto-jvm
(`objects/job/expression`, `objects/job/value`); kzen-lib published to mavenLocal before kzen-auto ran.

**Convention (Work 1) — `BeanShape` (new, kzen-lib-common jvmMain).** One analysis per `Class` identity (a
`ClassValue`), shared by the resolver (types, nullability) and the reader plans (values):
- a property is a public, non-static, non-synthetic, non-bridge `getX()` / `isX()` (`isX` only for primitive
  `boolean`) or a public non-static field, declared by the class or a supertype of its own; members declared by
  the JDK or the Kotlin stdlib (`java.*`, `javax.*`, `jdk.*`, `kotlin.*`: `getClass`, a collection's
  `isEmpty`, a `Throwable`'s `getMessage`) are not data — this exclusion, rather than special-casing
  `CharSequence`, is what keeps `List<CharSequence>` assignable from `List<String>` as before;
- names by JavaBeans decapitalization (`getURL()` → `URL`, `getId()` → `id`); **order lexical by final name**
  (records and data classes keep component order and do not go through here);
- precedence: getter over field, `getX` over `isX`, most-derived declaration across the hierarchy (`Class.getMethods`
  already returns the override; hiding fields are chosen by declaring-class assignability); a getter and a
  field of one name with different types is `DataProblem.nativeShapeConflict` (new code) naming the class;
- nullability: primitives non-null; a Kotlin-declared member keeps its declared nullability (getters are mapped
  to their `KProperty` via `memberProperties`/`javaGetter`, since a Kotlin property getter is not a `KFunction`);
  a Java member reads a runtime-visible `@Nullable` / `@NonNull` (JSpecify, JSR-305) on the getter, then the
  field, then JSpecify `@NullMarked` on the class, an enclosing class or the package; otherwise every
  reference-typed property is optional. **Deviation recorded:** the plan named JetBrains annotations too, but
  `org.jetbrains.annotations.Nullable/NotNull` have class retention and cannot be seen by reflection, so they
  are not honoured (documented on the class);
- a throwing getter is a `DataAccessException` naming the property, class and cause, carrying the field path;
  a class with no property has no bean shape and stays Opaque (`Any` is now described as Dynamic, matching
  the transport's `TypeMetadata.toDataContract`).
`DefaultNativeTypeResolver.describe` falls through data class → record → bean; `NativePropertyPlans` (now a
`ClassValue`) reads beans through the same shape.

**Enum and Set (Work 2).** An enum (including a constant with a body, whose class is an anonymous subclass) is
`ScalarKind.Text` in describe and lift (`scalar()` / `readText()` return the constant name). `Set` /
`MutableSet` are an unordered `Listing` in describe, lift and the registry's built-in/refused tables
(`Sequence`, `Iterator` and other `Iterable`s stay refused as values); element access snapshots the set once
per node so indexes stay consistent within a value, and the order is documented as unstable. Record and
data-class component order is unchanged.

**Token cache (Work 3).** `NativeTypeTokens` caches the `NativeTypeToken` per `Class` identity (a `ClassValue`,
loader-local, released with the loader) instead of computing `starProjectedType` per child value.

**Design-time inference (Work 4, kzen-auto).** `JobDataValues.describe(KType)` exposes the run-time adapter
registry's description; `JobExpressionCompiler.compile` now describes a non-stream inferred type and a stream's
element type through it (the stream container itself stays named through `TypeMetadata`), so a record, bean,
enum or Set typed expression shows the columns the run will emit — without constructing a sample or invoking a
getter (the registry describes types, not values). A refused or conflicting type is the compile error text.

**Verification.** kzen-lib-common `jvmTest` (all green): new `PlainObjectShapeTest` — lexical order with
getter/field precedence and excluded members, most-derived override and hiding field across a hierarchy
(with an enum property, a `Set` property and a `List` of beans), conflicting getter/field types naming the
class, a throwing getter as a named access failure with the field path, nullability from JSpecify annotations /
`@NullMarked` / optional by default, a Kotlin class keeping declared nullability, no-property classes opaque,
enums and Sets in describe and lift (snapshot stability), and per-loader token identity for two loaders of one
class name (`javax.tools`-compiled). `DefaultDataAdapterRegistryTest`'s refusal case now covers Sequence /
Iterator / other Iterables (Set moved to the accepted side). kzen-auto: `JobExpressionCompilerTest` gained
the POJO stream case (columns `id`, `name` before execution; the lifted instance's type equals the design-time
record; a single-value expression agrees; a conflicting class is a compile error) — 8/8; **`FormulaStepTest`
canary 10/10**; `tech.kzen.auto.server.objects.job.*` green. Commands: `cd ../kzen-lib && ./gradlew
publishToMavenLocal`, `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*JobExpressionCompilerTest"
--tests "*FormulaStepTest" --tests "tech.kzen.auto.server.objects.job.*"`. Recursive occurrences remain finite
under the existing open-class rule (Opaque at the recursive node) until HS14. New files staged by explicit path.

**APIs for HS19:** `JobDataValues.describe(KType): DataContract`; `DefaultDataAdapterRegistry.describe(KType)` /
`lift(Any?, expected)`; `BeanShape.of(Class)` (internal to kzen-lib-common jvm) with `properties` in lexical
order; `DataProblem.nativeShapeConflict`.
