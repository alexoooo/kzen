# HS14 — Recursive object contracts across JVM and JS

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS13.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E7 item 5; landed data-model contracts.

## Outcome and anchors

kzen-lib-common DataType/DataContract and their serialization, validation, algebra/digests; JVM resolver; kzen-auto contract consumers.

## Work

1. Add finite named type references/definitions as specified by E7. Audit every exhaustive DataType consumer and wire serializer before editing the hierarchy; update semantics, not just compiler branches.
2. Resolve self/mutual recursion lazily and preserve deterministic equality/digests. Keep loader-local native identity separate from a structural reference name; test same-name classes in separate scopes.
3. Ensure structural snapshot/deep validation remains bounded and reports cycles/limits rather than recursing forever. Native graph navigation remains on demand.
4. Carry definitions to the browser and expression design-time contract path. Represent collapsed recursive nodes without eagerly expanding them.
5. Publish kzen-lib, then rebuild consumers from their own directories; no release-train version bump.

## Verification and exit criteria

Test self/mutual recursion, recursive collections, serialization round trip, deterministic contract identity and bounded malformed/unresolved-reference errors. JVM and JS compile/tests must cover the new variant. A cold editor can traverse a recursive shape without running the source.

## Handoff

E7 closes when HS13 and HS14 proofs pass. HS19/HS20 own projection and the interactive picker, rather than treating a recursive schema as a finished UI.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-lib-common (`commonMain` type model, serializer, algebra, snapshot, literal and
value algebra; `jvmMain` resolver, registry, materializer), kzen-auto (common bridge, JVM Job consumers, JS
presentation); kzen-lib published to mavenLocal, then kzen-auto and kzen-project rebuilt from their own
directories. No release-train version changed.

**Type model (Work 1).** `DataType.Reference(id: DefinitionId, nullable)` is a new sealed variant — a leaf naming
a definition; `DefinitionId` is a class's qualified name for native shapes (structural identity, deliberately
loader-agnostic). `DataContract` gained `definitions: Map<DefinitionId, DataType>`: `child(segment)` expands a
referenced child **one level** (its own children stay references) and `expanded()` does the same for a
reference-rooted contract, so navigation is on demand and the contract itself stays finite to walk, digest and
serialize; `unresolvedReferences()` lists dangling ids. Every exhaustive consumer was audited before the
hierarchy changed: `withNullability`, `schemaChildren` / `walk` (references are leaves), the
`ExecutionValue` codec (`case: reference`; `definitions` list on the contract, sorted by id, omitted when
empty so non-recursive encodings are byte-identical to before), `DataTypeAlgebra`, `DataSnapshot`,
`DataValueAlgebra`, `LiteralDataValues` (build / decode expand the contract; `opaqueMetadata` leaf),
`DataValueMaterializer`, and in kzen-auto `LegacyDataShapeBridge`, `JobExpressionCompiler` (three whens),
`JobDataValues.boundary`, `ColumnProjection`, `JobLaneDescriptor`, `CalculatedColumnEval`,
`DataContractPresentation`. Semantics, not just branches: the value validator now walks *contracts*
(`expectedContract.child(...)`), which is what makes a recursive expected shape checkable at all.

**Resolution (Work 2).** `DefaultNativeTypeResolver.describe` runs one `DescribeSession` per top-level type: a
class met again while open becomes `Reference(id)` (recorded as referenced), and when that class's own
description closes it is registered as the definition, so only classes that actually recur become
definitions (self recursion, recursive collections `List<Tree>`, and mutual recursion `Left ↔ Right` — the
first occurrence of the partner stays inline). Equality and digests are deterministic: definitions are
encoded sorted by id, and two constructions with different map order are equal. Loader-local identity stays
in `tokenByPath`: two loaders' `fixture.Link` describe to equal contracts (same reference name) whose
resolved forms are rejected by native token identity — tested. Assignability is contract-aware
(`DataTypeAlgebra.isAssignable(expected: DataContract, actual: DataContract)`): a reference on either side is
expanded through its own contract's definitions and a pair of references already under comparison is assumed
compatible (coinductive, hence finite), so a run-time element lifted as a full record satisfies a design-time
listing of references; the plain `DataType` overload stays nominal (same id) when definitions are absent.
Definitions are carried through runtime joins of listings and mappings, so a child navigated from a lifted
list still expands.

**Bounded validation (Work 3).** Type-level walks never enter a reference; snapshotting a cyclic *value* is
rejected with `snapshotCycle` as before (asserted on a self-referencing bean); an unresolved reference is a
named `DataProblem.unresolvedReference` at expansion, a definition that is itself a bare reference is an
`invalidContract` at construction. Native graph navigation stays on demand (`NativeObjectValueAccess` reads a
child only when asked).

**Browser and design time (Work 4).** The common codec carries definitions to the browser;
`DataContractPresentation` renders a recursive occurrence collapsed (`↻ <id>`) and lists each definition once —
nothing expands eagerly. `JobExpressionCompiler` describes through the registry (HS13), so an expression
returning a recursive class yields a contract with definitions that a cold editor can traverse level by
level (asserted in `JobExpressionCompilerTest`: root record, reference at `next`, two `child()` expansions,
wire round trip with definitions, and the run's value satisfying it).

**Verification.** kzen-lib-common: `DataContractReferenceTest` (commonTest — runs on **JVM and JS**: one-level
expansion, root reference and mutual recursion on demand, round trip and order-independent digests,
unresolved / bare-reference failures, nominal vs contract-aware assignability and join);
`RecursiveContractTest` (jvmTest: self recursion with deep navigation, recursive collections and mutual
recursion, bounded snapshot, same-name classes across loaders); old assertions that recursion was Opaque
updated. All 392 `jvmTest` and the `jsTest` suite green; `./gradlew publishToMavenLocal`. kzen-auto:
`JobExpressionCompilerTest` 9/9 (recursive case added), `FormulaStepTest` 10/10, `objects.job.*` green,
`:kzen-auto-js:compileKotlinJs` green; full `./gradlew build` of kzen-auto and `publishToMavenLocal`, then
kzen-project `./gradlew build` from its own directory. New files staged by explicit path:
`DefinitionId.kt`, `DataContractReferenceTest.kt`, `RecursiveContractTest.kt`.

**Known limits for HS19/HS20.** References are expanded only by navigation (`child` / `expanded`); a UI that
wants to descend into a recursive occurrence asks for the child contract — the picker (HS20) owns that
interaction. `join` of two different references degrades to Dynamic, as any other mismatch does.
