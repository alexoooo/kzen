# HS09 — Aggregate class loading, expressions and contextual availability

> Status: not started. One implementation session. Prerequisites: HS08.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E2: compiler classpath, reflection and per-context availability; gate G9.

## Outcome and anchors

ClassLoaderUtils.dynamicParentClassLoader, ScriptKotlinCompiler, ReflectiveClassMirror, ServiceEnvironmentValidation and KzenAutoContext.

## Work

1. Implement the parent-first aggregate delegating loader returning each defining scope's existing Class. On application miss, detect duplicate folder definitions before loading; on application hit, report folder shadowing.
2. Supply the compiler's explicit application/plugin jar classpath in consistent precedence order. A flat replacement loader must not create duplicate runtime classes. Exercise compile-time resolution and runtime identity together.
3. Register one reflective mirror over the aggregate; preserve generated-first behavior for scoped KSP contributions. Do not scan all classes to build diagnostics.
4. Initialize each context's availability view from explicit contributions; augment it lazily per resolved class name. Missing plugin services affect only that workspace/contribution. Core generated validation retains its existing startup behavior.
5. Wire folder contributions end-to-end through the runtime and normal standalone bootstrap. Record resolution errors contextually without changing immutable global discovery state.

## Verification and exit criteria

G9: one expression names classes from two folders, accepts a mirror-created instance in an identity-sensitive call, and still works after a second context starts. Folder duplicates fail lazily; app/folder collision consistently uses the app class during compile, reflection and execution. Create a lacking-service context first, then a providing context; neither poisons the other. A later notation edit first naming a reflective Worker updates only that context's availability.

## Handoff

Record loader/compilation precedence and actual tests. HS10 supplies the public host service builder; HS12 exposes diagnostics.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
