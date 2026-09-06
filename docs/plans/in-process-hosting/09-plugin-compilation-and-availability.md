# HS09 — Aggregate class loading, expressions and contextual availability

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS08.
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

Executed 2026-09-05 in kzen-lib-jvm (`AggregateClassLoader`, `AmbiguousClassException`,
`ReflectiveClassMirror`), kzen-auto-jvm (`KzenAutoRuntime`, `PluginDiagnostics`, `PluginAvailability`,
`ScriptKotlinCompiler`, `KzenAutoContext`).

**Loader.** `AggregateClassLoader(parent = application, scopes)` is parent-first and returns each defining
scope's *existing* `Class` (it never defines bytes itself, so no duplicate runtime classes). On an application
miss it asks every scope `findResource(name.class)` before loading: a name defined by several folders throws
`AmbiguousClassException` naming the scopes, and the finding is recorded on each scope
(`PluginDiagnostics.ambiguousClasses`); on an application hit it reports folder shadowing
(`shadowedClasses`) and serves the application copy. Findings are lazy and append-only; no class scan builds
them. `ReflectiveClassMirror` maps an `AmbiguousClassException` to `Entry.Malformed`, so the mirror serves the
ambiguity as a named failure rather than an arbitrary pick. Test: `AggregateClassLoaderTest`.

**Compiler.** `ScriptKotlinCompiler` adds `KzenAutoRuntime.currentOrDefault().pluginClasspath()` — the explicit
union of every loaded folder scope's jars, in scope then jar order, after the application classpath — since a
classpath derived from a class loader cannot see through the delegating aggregate. Runtime identity comes from
`ClassLoaderUtils.dynamicParentClassLoader()` = the aggregate; the compiled class and the mirror-created
instance therefore share one `Class`.

**Mirror and availability.** One `ReflectiveClassMirror` over the aggregate is registered via
`GlobalMirror.registerAfterGlobalRegistry`, keeping generated-first for scoped KSP registrations.
`PluginAvailability` (per context) is initialized from the runtime's explicit contributions (each scope's
generated registry checked against that context's `GraphEnvironment`) and augmented lazily by `of(className)`
(compute-if-absent). A class whose `@Service` type the environment lacks is `Unavailable(missingServices)` in
that workspace only; a class the mirror cannot serve is `Unresolvable(reason)`. Nothing here mutates runtime
state. Folder contributions flow through the runtime into the normal standalone bootstrap (`KzenAutoMain`).

**Verification (G9), `AggregateExpressionBootTest` (forked).** One expression names classes from two folders and
accepts a mirror-created instance in an identity-sensitive cast; a name two folders define fails lazily with both
scopes named and is served by the mirror as a failure; an application/folder collision serves the application
class through the aggregate (compile, reflection and execution agree) while the folder's own loader still
defines its copy; availability is per context and learns lazily — a context lacking a service reports
`Unavailable` naming it while another context is untouched; the compiled expression still works after a second
context starts. The "later notation edit first naming a reflective Worker" case was **not** wired here: nothing in
production called the lazy `of()` path. HS12 closed the gap — `PluginAvailability` now observes the graph store
and learns folder-defined classes from notation on boot and after every command, proven with a real
`CreateDocumentCommand` in `CompatibilityKitBootTest`. `./gradlew :kzen-auto-jvm:pluginUniverseTest` green.
