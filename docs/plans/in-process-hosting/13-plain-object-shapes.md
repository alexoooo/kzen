# HS13 — Plain-object shapes and expression inference

> Status: not started. One implementation session. Prerequisites: HS01; independent of E2 runtime sessions, serialize shared-file edits.
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

Not executed.
