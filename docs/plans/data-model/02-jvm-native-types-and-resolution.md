# DM2 — JVM native contracts, resolution, and static description

> **Status: ready after DM1. One implementation session.** Authority: unified data model §§4.1, 4.7 “Platform
> seams,” 7.2–7.3, 14.5 step 1, and the native portions of the adoption gate.

## Outcome

`kzen-lib-common/jvmMain` maps a `KType` to a structural `DataContract` plus loader-local tokens at every native
path, resolves name-only declarations explicitly in their owner's loader, and applies native requirements only
after structural acceptance. The session closes open question 7 with executable evidence.

## Preconditions and current anchors

- DM1 is green. Re-read `../kzen-lib/AGENTS.md`; publish nothing until the session is green.
- `kzen-lib-common/build.gradle.kts` already has `kotlin("reflect")` in `jvmMain`.
- In kzen-auto, `ExpressionReturnTypeInference.toTypeMetadata`, `FormulaStep.definition`,
  `CalculatedColumnEval.inferredReturnKType`, and `TypeAssignability` are the current inference/compile seams.
  They are read-only in this session; DM7a consumes the static lane contract and DM7c completes the runtime
  mapper cutover.
- Do not compare class names for executable acceptance and do not move the existing kzen-auto compiler probe into
  kzen-lib.

## Implementation

1. Add `NativeTypeToken`, `ResolvedDataContract`, `NativeTypeResolver`, and `JvmNativeValueAccess` in `jvmMain`.
   Freeze token maps and validate one-to-one alignment with the common metadata paths.
2. Implement `KType -> ResolvedDataContract` for primitives, standard maps/lists/arrays, Kotlin data classes, Java
   records, and the opaque fallback. Data-class properties contribute their own `returnType` tokens; recursive
   expansion stops at `Opaque` on the open path.
3. Implement the lossy common `TypeMetadata -> DataContract` mapping: primitives/standard collections become
   structural; other names become `Opaque` plus metadata. It never manufactures a JVM token.
4. Implement explicit `resolve(contract, ownerLoader)`. A name-only declaration remains structurally usable but
   cannot impose a native requirement before this operation succeeds in its owning module's loader.
5. Spike generic subtyping with `kotlin.reflect.full.isSubtypeOf`, using tokens whose classifiers have already
   been proven loader-identical/related. Keep this local implementation if tests cover variance, nullability,
   nested generics, and plugin loaders. If kotlin-reflect cannot express a required case, stop and record a narrow
   provider seam for kzen-auto's probe; do not create an upward dependency or fall back to rendered names.
6. Implement resolved assignability and variant selection: structural check first, then token compatibility at
   every required native path. Scalar requirements use the closed exact projection table with overflow/precision
   rejection; records/collections/opaque nodes require actual tokens or native identity as specified.
7. Scope resolver and any compilation caches to an explicit plugin/module load-generation owner with a release
   operation. A cache must not retain superseded loaders.

## Proof

- Map primitives, nullable/generic collections, nested data classes, Java records, recursive data classes, exact
  adapter descriptions (a test adapter may be local), and opaque objects.
- Prove the nested property token comes from its property `KType`; root metadata is insufficient.
- Load two same-FQN fixture classes in sibling loaders: reject token-to-token. Load an implementation in a child
  loader and a shared interface in the parent: accept. Replace a generation and prove old loader/cache keys are
  collectible using weak references and bounded GC retries.
- Reject unresolved native declarations, generic requirements against token-less values, and same-name evidence
  from the first runtime value. Accept the same declarations structurally where their structure allows it.
- Prove native union selection distinguishes same-shaped classes and scalar `Int` projection rejects overflow.
- Run `./gradlew :kzen-lib-common:jvmTest`, then the full `./gradlew build` from `../kzen-lib`.

## Exit criteria

- Open question 7 has an as-built verdict with evidence; no name-based executable compatibility remains.
- Publish all kzen-lib artifacts to Maven Local (`./gradlew publishToMavenLocal`) for DM5 and later kzen-auto work.
