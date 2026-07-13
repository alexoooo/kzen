# Script (steppable Logic) improvements — phased plan

> **Status: planned.** Written 2026-07-06 from a design review of the Script flavour — the reference
> `Logic` consumer — across all three layers: server (`ScriptLogicCompiler` / `ScriptLogic` /
> `ScriptRunContext` + the step archetypes), common (`ScriptTree` / `ScriptValidation` /
> `ScriptConventions`), and the JS client (`ScriptController` / `ScriptStore` /
> `ScriptProgressStore` / step displays). Executor: **Opus 4.8 xhigh, one phase per session.** Each
> phase is self-contained: goal, design decisions (already made — do not re-litigate), concrete
> steps with file anchors, and verification. Phases are ordered by priority; only 5 and 6 have hard
> prerequisites.
>
> Companion plans: `2026-07-05_logic-engine-improvements.md` (the engine below Script) and
> `2026-07-05_graph-improvements.md` (the graph layers below both). This plan deliberately does
> **not** duplicate their items — see "Covered elsewhere" below. Coordinate where marked.
>
> **Progress tracker** (update as phases land):
> - [x] Phase 1 — expression engine: loaded-class caching + real type inference (kzen-auto-jvm) — landed 2026-07-11
> - [ ] Phase 2 — resources survive live edit + engine-owned resource values (kzen-lib + all flavours)
> - [ ] Phase 3 — linked-document live edit (sub-script edits join the migration closure)
> - [ ] Phase 4 — validation once per notation version (digest-keyed cache)
> - [ ] Phase 5 — mid-loop migration resume (loop cursors, generic step carry-state)
> - [x] Phase 6 — step-over/out across inline branches (logical nesting depth) — landed 2026-07-12,
>   REVERTED 2026-07-13 (user decision after live use: auto-step-over blasted a whole ForEach in one
>   tick; step-out exited the branch instead of the document — step-over/out are frame-only again;
>   the ForEach iteration-counter trace detail stays; see the Phase 6 as-built note)
> - [ ] Phase 7 — trace bounding: display truncation + referenced-aware loop collection
> - [ ] Phase 8 — client sweep: hot paths, display dedup, notation-driven branch discovery

## Context — what the review found

Script's architecture is **sound and should not be restructured**. The crown jewels, all preserved
by every phase:

- **Thin flavour on a strong engine.** `ScriptLogic` is 64 lines; the whole spine
  (`ScriptRunContext.runSteps`) is ~350. Stepping, migration, pause-on-error, resources, and trace
  attribution are all inherited from `RunEngine` — Script adds only the per-step trace lifecycle
  and the replay short-circuit. This is exactly the "core vs consumer" split logic-spec §8 calls
  for.
- **Fully open step set.** No step-type `when` anywhere: the spine runs `ScriptStep.run`
  polymorphically; nested branches are exposed generically via `nestedStepLists()`; client display
  selection is notation-driven (`display:` → `StepDisplayManager`), step creation is an
  archetype→commander map. A third-party step is `@Reflect` + `is: ScriptStep` + optionally a
  display — zero shared-code edits. The god-object rule holds.
- **Typing as validation.** `ScriptStep.definition()` doubles as validator and type oracle;
  `ScriptValidator` iterates to a fixpoint so If/ForEach/DoWhile join over their branch terminals.
  In-script expressions are real compiled Kotlin with named, typed accessors for predecessors —
  a genuinely powerful design.
- **Stable-id keying end to end** (values, traces, migration carry) gives rename survival for free.

The weaknesses live in four clusters:

1. **The expression stack is the hot-and-brittle spot.** `StepExpressionSupport.evaluate`
   (StepExpressionSupport.kt:75-107) builds a **fresh `URLClassLoader` + reflective instantiation
   on every evaluation** — once per loop iteration per Formula step, once per DoWhile condition
   check. `FormulaStep.definition()` compiles each formula **up to 3 times** per validation pass
   (probe `Any?`, `Any`, `String`) and recovers the inferred type by **parsing Kotlin compiler
   diagnostic text** (~10 wording-coupled string fragments, a reachable
   `TODO("Unexpected literal")` at FormulaStep.kt:81). `CachedKotlinCompiler`'s file cache has a
   check-then-act race (CachedKotlinCompiler.kt:101-123) that becomes real under engine-plan
   phase 6 (multi-run). DoWhile duplicates the scope/Unit/defer plumbing
   (DoWhileStep.kt:106-128 vs StepExpressionSupport.kt:25-56).
2. **Live edit is incomplete in three specific ways.**
   (a) **A live edit kills open resources**: `RunEngine.migrate` teardown disposes non-detached
   node resources (RunEngine.kt:326-334, comment at :564), Script's capture carries only
   `completedOutcomes` + result (ScriptRunContext.kt:267-269) — and the replay short-circuit means
   a completed `BrowserOpenStep` **never re-runs** (ScriptRunContext.kt:177-179). Net: pause → edit
   → resume quits the browser and every subsequent browser step fails "Browser is not open". This
   violates spec §5 ("state that survives includes … open resources").
   (b) **Sub-script edits are invisible**: `pendingMigration` compares only the root document's
   transitive closure (ServerLogicController.kt:745-789), and closure walking skips weak references
   (ObjectDefinition.kt:69-71, :123) — a `RunStep.instructions` link is `by: Nominal` → weak
   (script-jvm.yaml:253-257), so editing the callee while the caller is paused never migrates, and
   `host` compiles the child from the caller's compile-time notation snapshot
   (ScriptRunContext.kt:226-229). Same gap for Flow `RunLogic` and Job `RunWorker`.
   (c) **A not-yet-completed loop restarts from iteration 0** on migration
   (ScriptMigrationState.kt:19-23, `dropReplay` at ForEachStep.kt:46) — re-running side-effectful
   iterations (browser clicks, emails). The kdoc itself calls mid-loop resume "a tracked follow-up".
3. **Unbounded trace growth in loops.** Every `emit` appends to the run's retained history
   (RunEngine.kt:598-606); the spine emits ~4 events per step per iteration (next-step marker ×2,
   Running, Done), all on the Script's **own node**, so engine-plan 1d's frame compaction (hosted
   frames only) never touches them. Worse, a step's Done display is `value.toString()` unbounded
   (ScriptRunContext.kt:327-329) — a ForEach over 100k items whose value is a big list puts
   megabyte strings into history, the trace store, and every client poll. And `ForEachStep`
   collects every iteration's terminal value even when nothing references the loop
   (ForEachStep.kt:48-53).
4. **Inline branches are invisible to stepping.** If/ForEach/DoWhile bodies run inline on the same
   node (deliberate — keeps the frame tree lean), but the engine's step-over/out rules are pure
   node-depth comparisons (RunEngine.kt:212-219, :461-471) — so **step-over an If or a loop
   behaves as step-into**, and step-out cannot exit a branch. Only a `RunStep` (a real child node)
   is steppable-over. This is the one place the "inline branches" design decision leaks.

Client-side, the architecture is clean (no polling — edge-triggered on a logic-time watermark;
notation-driven display selection; watermarked history fetch), but the per-publish cost scales
with steps × branches: `ScriptDependencyAnalysis.analyze` runs once **per branch** per publish
*plus* once per overlay remeasure (ScriptBranchDisplay.kt:252-279,
ScriptDependencyOverlay.kt:214-227); `computeRunStepRepresentative` is O(RunSteps ×
screenshot-events) per refresh and the accumulated timeline is fully re-sorted per refresh
(ScriptProgressStore.kt:125, :204-223); the observer skip-guards are copy-pasted 4× across the
control-step displays (IfStepDisplay.kt:123-173 ≈ ForEachStepDisplay ≈ DoWhileStepDisplay ≈
ScriptStepDisplayDefault). `ScriptDependencyAnalysis` hardcodes branch attribute names
`["steps", "then", "else"]` (ScriptDependencyAnalysis.kt:31-38 — its own comment flags this as
the SwitchStep blocker), and `KotlinExpressionEditor` re-implements the server's
DoWhile-vs-Formula scoping rule by attribute-name branch (KotlinExpressionEditor.kt:194-204).

**Covered elsewhere — do not re-do here** (reference the companion plans instead):
`$next-step` marker retirement + engine-owned position (engine 2); breakpoints / run-to (engine 3);
trace-store unification (engine 4); polling → SSE + step budget (engine 5); multi-run (engine 6);
pause-during-stepping, publish/history hot path, hosted-frame compaction (engine 1);
`ModelDetachedExecutor` whole-project-graph-per-call — which today makes every validation request
build the entire server graph (graph 3b); definition caching (graph 1); closure content digest
(graph 2 — phase 4 here reuses it if landed); notation-driven `isLogic` marker (graph 5b);
move execution to a step ("Set Next Statement"): `2026-07-10_execution-control.md` (loop-body
targets there extend on this plan's phase 5 cursors).

**Deliberately out of scope** (decided; do not re-open inside a phase):
- Restructuring inline branches into hosted child frames (would give stepping for free but bloats
  the frame tree, breaks the flat trace addressing, and costs a node per branch per iteration —
  phase 6's logical depth achieves the stepping win without it).
- A Script-specific interpreter for formulas (replacing the Kotlin compiler) — the compiled-Kotlin
  design is a feature (full language, real types); phase 1 makes it cheap instead.
- Typed scalar notation, expression sandboxing/security, cross-process execution.
- Retiring the deprecated `ArgumentStep` / `ForEachItemStep` archetypes — cheap but touches user
  documents; bundle into phase 8's hygiene only if grep shows no user notation references them.

## Ground rules for every phase

- **The spec leads.** Behaviour changes to engine semantics (phases 2, 6) must update
  `kzen-lib/docs/logic-spec.md` in the same session; Script-level behaviour changes update
  `kzen-auto/docs/architecture.md` §1/§3 and `docs/js-architecture.md` where client behaviour
  changes.
- **No flavour-specific code in general layers, and no step-specific code in Script's shared
  layers.** Extension stays: archetypes, autowired lists, notation metadata. (Watch phase 3 and
  phase 8c especially — both replace hardcoded lists with notation-driven discovery.)
- **Dev loop**: kzen-auto consumes kzen-lib from **mavenLocal**. After any kzen-lib change:
  `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`. Open kzen-auto as its own IntelliJ project (not via the umbrella).
- **Verification baseline** (every phase): kzen-lib `./gradlew :kzen-lib-jvm:test`
  (`RunEngineTest`); kzen-auto `./gradlew :kzen-auto-jvm:test` (**`FormulaStepTest` is the
  expression-stack canary** + the Job suite). UI-facing phases: `./gradlew :kzen-auto-test:selfTest`
  (opt-in, opens Chrome; **beware a stale tester JVM on port 18081 — kill it first**), plus a
  manual `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` smoke of Script run / step /
  pause / edit-while-paused.
- Mark the phase checkbox in this file's tracker when done; append an as-built note on deviation.

---

## Phase 1 — Expression engine: loaded-class caching + real type inference

**Goal:** expression evaluation becomes O(map-lookup) per iteration instead of
O(classloader + reflection), and type inference stops depending on compiler diagnostic wording.
Entirely kzen-auto-jvm; highest value-to-risk of the plan.

### 1a. In-memory loaded-class cache + per-run instance reuse

`StepExpressionSupport.evaluate` (StepExpressionSupport.kt:75-107) per call: `tryCompile` (disk
probe), `tryLoad` (**fresh `URLClassLoader`**, CachedKotlinCompiler.kt:85-92), `loadClass`,
`getDeclaredConstructor().newInstance()`. Inside a ForEach body this is per element; a DoWhile
condition pays it per iteration (DoWhileStep.kt:62-69).

- `CachedKotlinCompiler`: add an in-memory `ConcurrentHashMap<String /*signature*/, Class<*>>`
  in front of `tryLoad` (the signature is already content-addressed — KotlinCode.signature() =
  className + source digest — so the cache can never serve stale bytecode). One `URLClassLoader`
  per signature for the process lifetime; note the deliberate trade (loaded classes are never
  unloaded — bounded by distinct expression texts, same as the disk cache).
- Per-run **instance** reuse: the generated class stores `predecessorValues` in a mutable field
  (StepExpressionCompiler.kt:46, :50-55), so an instance is single-threaded-reusable but not
  shareable. Cache instances in `ScriptRunContext` (`HashMap<String, StepExpression>` keyed by
  signature — the context is confined to the run coroutine, ScriptRunContext.kt:29-33 kdoc), and
  pass the cache through `StepExpressionSupport.evaluate` (new optional parameter or an
  `ExpressionEvaluator` handle the context owns — implementer's choice; keep `evaluate`'s
  resolver-based decoupling).
- While here: make the generated `evaluate` take its values as a constructor-free call without the
  field write if trivial (pass-through local) — optional, don't force it.

### 1b. Replace diagnostic-parsing type inference with reflective `KType` extraction

`FormulaStep.definition()` (FormulaStep.kt:186-249) probes 3 compiles and parses `"actual '"` /
`"The … literal "` / `"IntegerLiteralType["` out of the error text (constants at FormulaStep.kt:33-38),
with a reachable `TODO()` (FormulaStep.kt:81) and a hand-rolled type-string parser
(`parseTypeMetadata`, FormulaStep.kt:119-164). Replace:

- Generate a **type-probe variant** of the expression class: same accessors, but the user code as
  an *inferred* member — `fun probe(predecessorValues: List<Any?>) = run { <code> }` (no declared
  return type; it need not implement `StepExpression`). **One** compile.
- Load it (through 1a's cache) and read the return type via **kotlin-reflect** (already a
  dependency, kzen-auto-jvm/build.gradle.kts:37): `clazz.kotlin.declaredFunctions` →
  `KFunction.returnType` → map `KType` (classifier, `arguments`, `isMarkedNullable`) to
  `TypeMetadata`, resolving class names against the existing `objectRegistryScan` path only for
  the registry-visibility check `findClassName` does today (FormulaStep.kt:102-117).
- A compile **error** (user code broken) short-circuits exactly as today (the first probe's error
  becomes `validationError`); flexible/intersection types approximate to their bound erasure —
  document the mapping in the kdoc.
- Delete: `parseInferredType`, `parseLiteralType`, `parseTypeMetadata`, the string constants, the
  `TODO`, the commented debug `println` (FormulaStep.kt:244). Update the AGENTS.md gotcha entry
  (the "FormulaStep type inference is coupled to Kotlin compiler diagnostic text" bullet becomes
  historical).
- **Extend `FormulaStepTest`** before switching: nullable inference, `List<Int>`-style generics, a
  registry (`ObjectRegistryDocument`) custom type, a `Long`/`Char` literal (today's `TODO` path),
  and a Unit-typed expression. Green on old path where it can be (nullable/generics), then green
  on new path for all.

### 1c. Compile-cache concurrency + shared plumbing dedup + validator diagnostics

- **Striped lock per signature** around `tryCompile`'s check-then-act
  (CachedKotlinCompiler.kt:101-123) so two concurrent compiles of the same source don't race the
  cache directory (`ConcurrentHashMap<String, Any>` monitor objects; keep the crash-recovery
  delete path). Needed at latest by engine-plan phase 6; cheap now.
- **DoWhile onto the shared plumbing**: replace `conditionScopeTypes`/`nonUnitScope`
  (DoWhileStep.kt:106-128) with `StepExpressionSupport.inScopeTypes`/`resolveNonUnit` extended to
  take an explicit path list (DoWhile's scope is body children + bindings, not predecessors — pass
  the paths in, share the null-defer/Unit-drop logic).
- **Fixpoint silent drop**: when `ScriptValidator.validate`'s loop exits with `remainingSteps`
  non-empty (ScriptValidator.kt:78-89), emit `StepValidation(null, "Unresolved: circular or
  unavailable dependency")` for each survivor instead of leaving them absent — today they get no
  entry and the UI shows nothing.
- `ScriptLogicCompiler.compile` builds `ScriptTree.read` and then `ScriptValidator.validate`
  rebuilds it again (ScriptLogicCompiler.kt:54, ScriptValidator.kt:50) — pass it through.
- Doc rot in the same files: `ResultStep` kdoc references the retired `ScriptExecutionContext`
  (ResultStep.kt:24); `StepExpressionSupport.kt:74` calls it "legacy"; fix while touching.

**Out of scope:** the `ExpressionUtils.escapeKotlinVariableName` second-order collision TODO
(ExpressionUtils.kt:25) — note it in the as-built if observed, don't redesign naming.

**Verify:** baseline + extended `FormulaStepTest`; a micro-benchmark assert in a test (ForEach of
1000 iterations over a Formula body completes in < a generous bound — catches classloader-per-
iteration regressions); manual: DoWhile FizzBuzz script steps correctly; validation errors still
render per step.

**As-built (landed 2026-07-11, all green: full `:kzen-auto-jvm:test`):**

- **1a class cache + instance reuse.** `CachedKotlinCompiler` gained an in-memory loaded-class cache
  in front of `tryLoad` — a **bounded Caffeine cache** (`maximumSize`, not an unbounded map: each retained
  `Class` pins its `URLClassLoader` in Metaspace, and a long-lived process compiles far more distinct
  expressions than are live at once; an evicted entry transparently reloads from the durable on-disk
  jar). Caffeine (`com.github.ben-manes.caffeine:caffeine`, declared explicitly in `kzen-auto-jvm`) is
  the maintained successor to Guava's now-deprecated `com.google.common.cache`. The 1c compile lock is a
  fixed-size Guava `Striped<Lock>` (a concurrency utility, not a cache — no Caffeine equivalent) rather
  than a monitor-per-signature map, so the lock table stays bounded. Per-run instance reuse threads through a
  new generic
  `StepExecution.perRunSingleton<T>(key, factory)` (backed by a `HashMap<String, Any>` in
  `ScriptRunContext`) — chosen over exposing a `MutableMap<String, StepExpression>` so no eval-package
  type leaks into `script.api`. `StepExpressionSupport.evaluate` took an optional `instanceCache`
  lambda (default = fresh instance); the three expression steps pass `execution::perRunSingleton`.
- **1b merged single-class (refined the plan's separate-probe sketch).** `StepExpressionCompiler`
  emits, for FormulaStep, a class whose user code is an inferred `probe()` member with `evaluate`
  delegating to it — so definition (reflect the type) and run (call `evaluate`) share one content
  signature and compile once. `StepReturnTypeInference` reads `clazz.kotlin.declaredFunctions`'
  `probe` return `KType` and maps it with the registry-visibility filter (builtin whitelist ∪
  `objectRegistryScan.classNames`, by full `ClassName` equality; outside → `Any`, nullability
  preserved). Deleted FormulaStep's `parseInferredType`/`parseLiteralType`/`parseTypeMetadata`,
  string constants, the reachable `TODO`, and the 3-probe dance.
- **Load-bearing deviation — `ScriptKotlinCompiler` had to become `open`.** The reflect call
  (`clazz.kotlin.declaredFunctions`) resolves the generated class's enclosing **script facade
  `__`**, which the scripting compiler emits as `class __ extends ScriptKotlinCompiler`. That base
  had been `final` since 2022 and worked for years only because the old expression path used the
  compiled class **purely via Java `newInstance()`/`evaluate()`, never kotlin-reflect** — so `__` was
  never loaded. The first kotlin-reflect use forced `__` to load and a final base threw
  `IncompatibleClassChangeError: class __ cannot inherit from final class ScriptKotlinCompiler`.
  A warm on-disk `code-cache` had masked this (the failure only appears on a cold recompile, which
  the source-shape change forced). Confirmed pre-existing and reflect-specific by: `CalculatedColumnEvalTest`
  (uses only **explicit** return types → no reflect on the generated class) passes cold; DoWhile's
  **forced-Boolean** form passes; only the **inferred `probe()`** form failed. Fix: `open class
  ScriptKotlinCompiler` (a `@KotlinScript` template being extendable is standard). Low-risk, still
  instantiable; both Script and Report (CalculatedColumn) suites green after.
- **1c.** Striped compile lock (above); DoWhile's `conditionScopeTypes` now delegates to shared
  `StepExpressionSupport.typesOf` + `resolveNonUnit` (deleted its `nonUnitScope`); `ScriptValidator`
  emits `StepValidation(null, "Unresolved: circular or unavailable dependency")` for fixpoint
  survivors; `ScriptValidator.validate` takes an optional `scriptTree` the compiler passes through;
  doc rot fixed in `ResultStep`/`StepExecution` (`ScriptExecutionContext` references).
- **Tests.** Extended `FormulaStepTest` (nullable → `String?`, `List<Int>`, `Unit`, `Long`, `Char`→`Any`
  visibility fallback, and an unresolved-dependency diagnostic); a `ScriptNotationTest` 1000-iteration
  ForEach benchmark (asserts value `1001000`, wall-clock < 20 s — well under a second in practice).
  Registry positive-case test deferred (no `ObjectRegistry` test fixture exists; the `Char`→`Any`
  case exercises the "outside whitelist ∪ registry" branch). `escapeKotlinVariableName` collision
  TODO left as-is (not observed).
- **Note on the `code-cache` caveat**: because compiled-formula jars persist under `<workdir>/code-cache`
  and are content-addressed by source only, a change to the generated-class *shape* forces cold
  recompiles — clear the cache when changing `StepExpressionCompiler` output. Reflect-on-`__` now
  works because the base is `open`, so this is a one-time hazard for this phase.

---

## Phase 2 — Resources survive live edit + engine-owned resource values

**Goal:** fix the "edit-while-paused quits the browser" correctness bug at the engine level, and
collapse Script's parallel resource value registry into the engine's, making resource *reading*
work across flavours. kzen-lib + mechanical kzen-auto adoption.

**The bug (repro):** Script opens a browser (`BrowserOpenStep` → `execution.openResource`,
BrowserOpenStep.kt:49-51) → pause → edit anything in the document → resume. `pendingMigration`
fires, `RunEngine.migrate` tears down the old tree and **disposes every non-detached node
resource** (RunEngine.kt:326-334; comment at :564: "a node torn down by an in-progress migrate
still disposes its (non-detached) resources"). The rebuilt run restores `completedOutcomes` and
**short-circuits the completed `BrowserOpenStep` without re-executing it**
(ScriptRunContext.kt:177-179) — so the browser is gone and can never come back; every subsequent
browser step fails. Spec §5 explicitly lists "open resources" among state that survives migration;
the capture-detach affordance exists (Execution.kt:110-126) but no flavour uses it, and per-flavour
detach code would violate "migration must not be re-implemented per flavour" (spec §5 header).

### Design decisions

- **The engine preserves resource registrations across `migrate`, keyed by owner stable id** —
  mirroring `migrationCaptured`/`claimedCaptures` exactly (RunEngine.kt:338-354):
  1. In `migrate` step 2, instead of disposing, **lift** each node's `resources` map into
     `migrationResources: Map<ObjectStableId, Map<String, Registration>>` before teardown
     (teardown's `disposeResources` skips lifted entries; the `migrating` flag already
     distinguishes the path).
  2. On node spawn in the rebuilt tree, a node whose `stableId` has lifted resources **adopts**
     them (marks them claimed).
  3. `sweepOrphans` also disposes unclaimed lifted resources (a removed document's browser closes
     after one edit cycle — same policy as captured state, RunEngine.kt:359-374).
- **The engine stores the resource *value*, not just the closer.** `Execution.resource` gains a
  `value: Any?` parameter; new `Execution.resourceValue(key: String): Any?` walks the ancestor
  chain (same walk as `releaseResource`, RunEngine.kt:633-643). This is what makes step 2 above
  sufficient — the *handle* travels with the registration.
- **kzen-auto adoption (mechanical):** `ScriptRunContext.openResource`/`resource`/`releaseResource`
  (ScriptRunContext.kt:148-166) delegate wholly to the engine; **delete `ScriptRunResources`**, the
  `ScriptLogic.inheritedResources` setter hack (ScriptLogic.kt:29-35), and the
  `if (child is ScriptLogic)` special case in `host` (ScriptRunContext.kt:234-236) — inheritance
  falls out of the ancestor-chain walk, so **a hosted Flow or Job child can now read the parent's
  browser too** (today's comment "a Flow / Job child has no Script resources to inherit" stops
  being true). `StepExecution`'s surface (StepExecution.kt:78-93) is unchanged for steps.
- Note the scope nuance: Script steps run inline on the Script's node, so `ResourceScope.Self`
  registrations sit on the Script frame — the stable id keying in step 1 is the *frame's* id,
  which survives migration by construction (it is the root/host identity the rebuild matches on).
- Spec §5: add "open resources migrate with their owning frame's stable identity; a removed
  frame's resources are disposed at the next migration barrier or close". Fix the stale
  `ServerLogicController` kdoc ("a Script / Flow registers no capture yet" — ScriptLogic *does*
  register capture, ServerLogicController.kt:72-73).

**Verify:** new `RunEngineTest` cases: (1) resource registered → migrate → closer NOT called,
`resourceValue` readable in the rebuilt tree; (2) owner stable id absent from rebuilt definition →
disposed at next sweep; (3) `releaseResource` from a descendant still deregisters a lifted+adopted
resource. kzen-auto: manual browser Script — open, pause, **edit an unrelated step**, resume,
click step still drives the same browser window; then edit that *deletes* the open step's document
→ browser closes on next edit cycle. selfTest.

---

## Phase 3 — Linked-document live edit: sub-script edits join the migration closure

**Goal:** editing a hosted document (a `RunStep`'s sub-script, a Flow `RunLogic` callee, a Job
`RunWorker` callee) while the caller's run is paused triggers migration, exactly like editing the
caller. kzen-auto-jvm only.

### Design decisions

- **Root cause:** the change signal is `closureNotations(attempt, rootDocumentPath)`
  (ServerLogicController.kt:779-789) over `filterTransitive`, which follows only strong references
  (ObjectDefinition.kt:69-71 — `attributeReferences()` hardcodes `includeWeak = false`;
  GraphDefinition.kt:55-100). `instructions` is `by: Nominal` → weak by design (it must not pull
  the whole callee graph into the caller's instantiation) — so the callee never enters the signal.
  Keep the reference weak; **extend the signal, not the reference semantics**.
- **Generic linked-document discovery, notation-driven** (no flavour `when`): a "linked Logic
  document" is any object in the closure with an attribute whose *metadata* declares
  `is: ObjectLocation` (read via the `notationMetadataReader` the controller already has,
  ServerLogicController.kt:732-733), whose value parses to a location in **another** document
  whose `main` is a runnable logic document (`AutoConventions.isLogic` today; the graph-plan 5b
  notation marker when it lands). This matches `RunStep.instructions`, Flow `RunLogic.instructions`,
  and Job `RunWorker.instructions` (script-jvm.yaml:253-257, flow-vertex.yaml:181-185,
  job-worker.yaml:432-436) purely from notation — a third-party hosting step gets the behaviour
  for free.
- `closureNotations` becomes: root closure ∪ (recursively) each linked document's closure, with a
  visited-document cycle guard (self-hosting and mutual hosting are legal). The per-object values
  stay the parsed notations — the compare semantics are unchanged, only the key set widens.
  Unresolvable links (blank `instructions`, dangling path) are skipped, matching the "recompile
  failure falls back to keep-running" policy (ServerLogicController.kt:738-744).
- **Coordinate with graph-plan phase 2** (it replaces `closureNotations`/`baselineNotations` with
  `transitiveDigest`/`baselineClosureDigest`): if that has landed first, implement the widened
  signal in the digest domain — the linked-document discovery above stays exactly as specified,
  but the compare becomes a combined digest over root closure + each linked document's closure,
  rather than resurrecting the notation-map compare.
- Migration already handles the rest: `pendingMigration` recompiles the root, the rebuilt
  `ScriptRunContext` gets a fresh `childLogics` cache and a fresh `structure.graphNotation`
  (ScriptRunContext.kt:84, :226-229), so the next `host` compiles the edited callee. Completed
  `RunStep`s short-circuit and do **not** re-run the callee — correct (the edit affects future
  invocations; a mid-flight hosted child migrates as part of the same barrier since it is in the
  same engine tree).
- Cost note: the closure widens only when links exist; the compare is still map-equality over
  parsed notation. Engine-plan 1f (event-driven edit detection) is complementary — with it, this
  computation only runs after an actual notation command.

**Verify:** kzen-auto-jvm test at the controller level (start a Script hosting a sub-script, pause
mid-parent, apply a notation command to the **sub**-document, release → assert migration took
(e.g. the sub-script's edited literal shows in the child's next outcome). Manual: pause parent at
a step before a RunStep, edit the sub-script's formula, resume → new behaviour; same for a Flow
RunLogic callee. Baseline + Job suite (`JobMigrationTest` guards the Job side) + selfTest.

---

## Phase 4 — Validation once per notation version

**Goal:** stop re-running the full fixpoint (with its per-formula Kotlin compiles) on every
validation request and every run compile when nothing changed. kzen-auto-jvm only; small phase.

- Today: the client requests validation on **every committed notation edit**
  (ScriptStore.kt:165-167 → `ScriptValidationStore.refresh` → detached action), and the **run
  compile path recomputes the identical validation** (`ScriptLogicCompiler.compile` →
  `ScriptValidator.validate`, ScriptLogicCompiler.kt:55) — including per hosted-child compile.
  Phase 1 makes each validation much cheaper (1 compile per formula, cached loads); this phase
  makes repeats free.
- Add a small server-side cache (in `KzenAutoContext`, alongside the compiler): key =
  document path + a **digest over the document's closure notations** (reuse
  `GraphDefinition.transitiveDigest` if graph-plan phase 2 has landed; else compute locally from
  `closureNotations`-style pairs with the existing `Digest` utilities — note in the as-built which
  path was taken); value = the `ScriptValidation`. Both `ScriptValidator.execute`
  (ScriptValidator.kt:137-161) and `ScriptLogicCompiler.compile` consult it.
- `ScriptValidation` must be safely shareable: it is (immutable map of value types) — but
  `validate` currently seeds the context with a mutable-backed view (ScriptValidator.kt:56-58);
  return a defensive copy into the cache.
- Do **not** cache the `GraphInstance` here — graph-plan 3b owns executor-level instance caching;
  this cache sits above it and is correct independently.

**Verify:** baseline; a test asserting `validate` runs once for two identical requests and re-runs
after an edit (count via a test hook or by instrumenting the compile count through
`CachedKotlinCompiler`); manual: editor validation latency visibly drops on large scripts.

---

## Phase 5 — Mid-loop migration resume (loop cursors)

**Goal:** a paused-mid-loop edit resumes at the loop's current iteration instead of restarting
from iteration 0 — closing the documented gap (ScriptMigrationState.kt:19-23) and the side-effect
re-execution hazard. kzen-auto-jvm only.

**Prerequisite:** none hard, but do after phase 2 (its `ScriptMigrationState` shape settles first).

### Design decisions

- **Generic step carry-state, not loop-special-cased in the spine.** `StepExecution` gains:
  `fun recordCarry(location: ObjectLocation, state: Any?)` and
  `fun restoredCarry(location: ObjectLocation): Any?` — opaque per-step migration sub-state keyed
  by stable id, exactly parallel to the engine's `onCapture`/`restored` but at step granularity.
  `ScriptRunContext` stores them in a `carryStates: LinkedHashMap<ObjectStableId, Any?>`;
  `captureState()`/`restore()` (ScriptRunContext.kt:259-269) carry it in a new
  `ScriptMigrationState.stepCarry: Map<ObjectStableId, Any?>`. Any step type — including
  third-party — can now carry mid-flight state; loops are just the first adopters.
- **ForEachStep** (ForEachStep.kt:33-54): record `LoopCursor(iterationIndex, collectedOutputs)`
  after each completed iteration. On entry with a restored cursor **and** a re-iterable `items`
  value (`Collection`; the carried `completedOutcomes` already preserves the *same* items object
  in memory): skip the first N elements, seed `output`, and **do not** `dropReplay` up front — the
  in-flight iteration's body prefix is in `restoredOutcomes` and replays to the frontier; call
  `dropReplay(bodySteps)` at the **start of each subsequent iteration** instead (idempotent).
  Fallback (no cursor, or `items` not a `Collection`): today's restart, unchanged.
- **DoWhileStep** (DoWhileStep.kt:42-54): same pattern minus outputs — a cursor marks "mid-flight";
  when restored, skip the up-front `dropReplay` so the current iteration replays to the frontier;
  per-iteration `dropReplay` thereafter.
- Bound: cursors are in-memory within one JVM run (like all migration state); document that a
  cursor is dropped (→ restart) when the loop step itself was edited — cheapest correct rule:
  drop a step's carry when its own notation changed (compare available in the migration path), or
  accept replay-from-cursor against the edited body (the body prefix short-circuit already handles
  step-level edits: an edited body step's id keeps its outcome only if unchanged... **decision:**
  keep it simple — cursor survives any edit; body steps the edit *added* run live, removed ones
  drop out, which is exactly the §5 element-level contract. Note this in the kdoc).
- Update `ScriptMigrationState` kdoc (the "mid-loop resume parity is a tracked follow-up" sentence
  lands here) and architecture doc §1.

**Verify:** kzen-auto-jvm controller-level tests: (1) pause at iteration 2 of 4 (side-effect
counter step in the body), edit an unrelated step, resume → counter shows no re-execution of
iterations 0-1 and the run completes with 4 outputs; (2) DoWhile equivalent; (3) non-Collection
items (a Sequence-producing formula) still restarts cleanly; (4) loop-completed-pre-edit still
short-circuits wholesale. Manual UI smoke + selfTest.

---

## Phase 6 — Step-over/out across inline branches (logical nesting depth)

**Goal:** step-over an If/ForEach/DoWhile runs the whole branch/loop and parks after it; step-out
from inside a branch exits the branch — debugger-grade stepping without giving branches their own
frames. kzen-lib + kzen-auto.

**Prerequisite:** coordinate with engine-plan phase 2 (`checkpoint(at:)`) — same signature is
being extended; land together or immediately after.

### Design decisions

- **Boundaries gain a logical depth within their frame.** `Execution.checkpoint` gains
  `nestingDepth: Int = 0` (alongside phase-2-engine's `at:`). The engine's park records the pair;
  the step-over/out comparisons (RunEngine.kt:212-219 `minOf`, :461-471 depth tests) become
  lexicographic over `(nodeDepth, nestingDepth)`. Default 0 keeps every existing flavour bit-exact
  (Flow vertices, Job workers, Report feeds — all flat).
- **The spine supplies it for free**: `ScriptRunContext.runSteps` already recurses per branch —
  track a `branchDepth` counter (increment on entry when invoked from a step's `run`, i.e. depth =
  recursion level − 1) and pass it to the per-step `checkpoint()` (ScriptRunContext.kt:184). No
  step-type knowledge: any control step composing via `runSteps` nests automatically; a
  third-party step calling `checkpoint()` directly inside its own loop stays at its step's depth
  (documented behaviour: its internal boundaries are "at the step").
- Engine semantics to specify (logic-spec §4 addition): step-over's limit is the parked boundary's
  `(nodeDepth, nestingDepth)`; boundaries strictly deeper run free; step-out's limit excludes the
  current nesting level. A hosted child's boundaries remain "deeper" by nodeDepth alone —
  cross-flavour stepping is untouched.
- UI: no changes required (the three step buttons already exist; they just start doing the
  expected thing at branches). The next-step highlight is orthogonal (engine-plan 2 position).
- **Nice-to-have in the same session** (skip if tight): loop progress detail — `ForEachStep.run`
  calls `execution.traceDetail("${i + 1} of $size")` at iteration start (the loop *is* the current
  step at that moment, so attribution is automatic via ScriptRunContext.kt:130-144); gives the
  collapsed loop card a live iteration counter.

**Verify:** `RunEngineTest`: boundaries at nesting 0/1/2 on one node — step-over at nesting 0 runs
nested boundaries free and parks at the next nesting-0 boundary; step-out from nesting 2 parks at
nesting 1; hosted-child stepping unchanged. Manual: step-over a ForEach runs the whole loop;
step-into still descends; step-over a RunStep still runs the sub-script to completion; selfTest.

> **As built (2026-07-12):** landed as planned, plus three notes. (1) The engine tracks each
> node's last checkpoint nesting (`NodeRuntime.nesting`, updated by every checkpoint) so
> nesting-less parks — explicit pause / pause-on-error — park at the failing step's nesting;
> otherwise a step-over after an error park inside a branch would run to the end of the enclosing
> branch instead of the next body step. Step limits are a private lexicographic `Frontier(depth,
> nesting)` in `RunEngine`. (2) The nice-to-have loop counter deviated: the client's
> `ForEachStepDisplay.renderCurrentItem` already renders the loop's trace detail as
> `item: <detail>` (the server-side emit was dropped in the engine rewrite, 4bc9bcf2), so
> `ForEachStep` now emits `"$item (i of n)"` — restoring the live item display with the counter
> folded in — rather than a bare counter that would render mislabelled. (3) selfTest's fizzBuzz
> fails on clean HEAD too (verified by stash-bisect): `Click Text "Script"` now matches 2 elements
> and the new `TargetMatchPolicy.Unique` default (target commits 5f1b62da/66cd9200) rejects the
> ambiguity the old first-match behaviour tolerated — pre-existing, orthogonal to this phase.
> New tests: `RunEngineTest.stepOverAndOutRespectNestingDepth`; `StepNavigationTest`
> `stepOverForEachRunsWholeLoop` / `stepIntoForEachDescendsIntoBody` / `stepOutOfLoopBodyExitsLoop`.
>
> **REVERTED (2026-07-13), user decision after live use.** The nesting-aware limits collided with
> real stepping workflows: the client's slow loop only issues step-over, so parked AT a ForEach it
> ran the entire loop in one tick (iterations no longer watchable), and step-out from inside an If
> branch exited just the branch where exiting the document was expected. Step-over/out are
> frame-only again (classic debugger semantics: step-over skips calls/frames, not loop bodies) —
> `checkpoint(nestingDepth:)`, `Frontier`, `NodeRuntime.nesting`, and the spine's `branchDepth`
> are all removed; note (1) above is moot. The ForEach iteration-counter detail (note 2) stays.
> The three `StepNavigationTest` cases were reworked to pin the frame-only semantics
> (`stepOverWalksForEachOneBoundaryAtATime` / `stepIntoForEachDescendsIntoBody` /
> `stepOutOfLoopBodyExitsDocument`); `stepOverAndOutRespectNestingDepth` was dropped with the
> engine revert. The selfTest failure (note 3) was root-caused the same day: the second "Script"
> match is the "New Script..." MenuItem still mounted during the MUI menu's ~300ms closing
> transition — fixed by a new `delaySeconds: Double` attribute on the browser target steps: a
> post-action settle delay (act, wait, then screenshot — the causing step owns the settle time),
> set to 0.5 on the two "New Script..." menu clicks; plus the Unique ambiguity error now naming
> each matched element.

---

## Phase 7 — Trace bounding: display truncation + referenced-aware loop collection

**Goal:** long/large-value runs stop bloating history, the trace store, and the wire. kzen-auto-jvm
(+ one engine-coordinated follow-up flagged, not built).

- **Truncate step display values at emit.** `displayOf` (ScriptRunContext.kt:327-329) is
  `value.toString()` unbounded and lands in every Done trace → engine history → mirrored store →
  client polls. Cap it (~2k chars, `"… (${'$'}n more chars)"` suffix; constant in
  `ScriptRunContext`). The *value graph* (`stepValues`) is untouched — downstream expressions and
  results see the full value; only the human-facing display is bounded. Apply the same cap to
  `adoptCompleted`'s replay emit (ScriptRunContext.kt:293-299).
- **Collect loop outputs only when referenced.** `ForEachStep` unconditionally accumulates every
  iteration's terminal value (ForEachStep.kt:48-53). At compile time, derive the set of steps whose
  *value* is consumed — an expression references it (`ScriptDependencyAnalysis` already computes
  these edges in common code), an attribute reference targets it (`items`, `condition`,
  `arguments`), or it is the terminal step of a branch (its value is the branch's value) — into
  `ScriptRunStructure`; expose `StepExecution.isValueReferenced(location): Boolean`. An
  unreferenced ForEach collects nothing (returns an empty list; its Done display says "n
  iterations"). Conservative: any analysis uncertainty ⇒ referenced.
- **Flag, don't build: transient emits.** The per-step Running / next-step-marker emits are
  live-state, not history — but today the trace transport is history-driven
  (`mirrorTrace` pulls by watermark), so they *must* stay in history until engine-plan phase 4
  serves live values from the engine's `Node.live` directly. Record in the engine plan (phase 4
  section) that after unification, `Execution.emit` should gain `retain: Boolean = true` and
  Script's Running/marker emits set false — cutting Script-loop history growth by ~3/4. Do not
  implement before engine-4.
- Housekeeping in the same area: `ScriptTraceAddressRouting` and the `$next-step` constant are
  deleted by engine-plan phase 2 — if that has landed, confirm nothing here regressed it.

**Verify:** baseline; a test: ForEach over 10k ints with an unreferenced body — assert the run's
history event count stays O(iterations) with bounded event sizes (no megabyte display strings) and
the loop's outcome is not a 10k-element list; a referenced loop still yields its list. Manual: big
loop in the UI stays responsive; step display shows the truncation ellipsis.

---

## Phase 8 — Client sweep: hot paths, display dedup, notation-driven branches

**Goal:** the per-publish client cost stops scaling with steps × branches; the 4-way copy-paste
collapses; the SwitchStep blocker dissolves. kzen-auto-js only.

### 8a. Hot paths

- **Memoize `ScriptDependencyAnalysis.analyze`** per (documentPath, notation identity): today it
  runs once per branch per `ClientStateGlobal` publish (ScriptBranchDisplay.kt:252-279) *plus*
  once per overlay remeasure rAF (ScriptDependencyOverlay.kt:214-227). Cache the result in
  `ScriptStore` (or a small keyed cache both consumers read), invalidated on
  `documentNotationChanged` — the store already computes that signal (ScriptStore.kt:96-169).
- **Stop re-sorting the accumulated timeline** per refresh (ScriptProgressStore.kt:125): history
  events arrive watermarked in sequence order — append and assert monotonic instead of
  `sortedBy` over the whole list.
- **Incremental RunStep representatives** (ScriptProgressStore.kt:204-223): fold the new events of
  this refresh into the previous per-RunStep representative map instead of re-scanning all binary
  events × all RunSteps.

### 8b. Display/editor dedup

- Extract the copy-pasted observer skip-guards and `Wrapper`/mount/unmount boilerplate
  (IfStepDisplay.kt:123-173 ≈ ForEachStepDisplay.kt:123-192 ≈ DoWhileStepDisplay.kt:129-179 ≈
  ScriptStepDisplayDefault.kt:211-240) into a shared base (`ScriptStepDisplayBase` extending
  `RPureComponent` with the consumed-slice state + value-equal guards from
  `ScriptStepObserverHelpers`) — this also *enforces* the js-architecture.md render-scoping
  discipline instead of relying on hand-copied guards.
- Dedupe: predecessor/binding scope computation (SelectStepEditor.kt:152-166 ≈
  RunStepArgumentsEditor.kt:255-269 → one helper next to `ScriptTree`); the rename-echo dance
  (4 editors — SelectStepEditor.kt:170-185 etc. → a small shared mixin/helper); the screenshot
  `buildGroups` grouping (RunStepDisplay vs PageScreenshots — both marked "Mirrors").

### 8c. Notation-driven branch discovery

- `ScriptDependencyAnalysis.branchAttributeNames = ["steps", "then", "else"]`
  (ScriptDependencyAnalysis.kt:31-38) — replace with metadata discovery: a branch attribute is one
  whose metadata is `is: List, of: ScriptStep` (exactly how the archetypes declare them —
  script-jvm.yaml IfStep :305-312, ForEachStep :329-332). Same discovery serves `ScriptTree.read`'s
  child grouping if it is currently name-based — check and align. This removes the documented
  SwitchStep blocker and the `then`/`else`/`items`/`condition` string re-declarations scattered
  across display files (IfStepDisplay.kt:66-72, ForEachStepDisplay.kt:72, DoWhileStepDisplay.kt:70,
  KotlinExpressionEditor.kt:77) — centralize what remains into `ScriptConventions`.
- `KotlinExpressionEditor`'s hardcoded DoWhile-vs-Formula scope branch
  (KotlinExpressionEditor.kt:194-204) mirrors server scoping by attribute name — drive it from a
  notation marker on the attribute metadata (e.g. `scope: body` on DoWhile's `condition`), read by
  both the editor and (optionally) the server scope helpers, so client/server can't drift.

### 8d. Hygiene

- `StepRowRefRegistry` process-global singleton (StepRowRefRegistry.kt:10-11 "only one Script
  document open at a time") → scope through the existing per-document `DocumentBridge` context.
- Resolve the three open TODOs: `ScriptStore.kt:203` (stateOrNull YAGNI), `SelectLogicEditor.kt:59`
  (→ RPureComponent), `SelectLogicEditor.kt:118` (exclude self/descendant documents from callee
  suggestions — cheap DAG guard). Delete the commented debug line StepDisplayManager.kt:114.
- Grep-check the deprecated `ArgumentStep`/`ForEachItemStep` archetypes for user-notation
  references; retire them (+ their yaml) only if unreferenced, else leave with a dated comment.

**Verify:** `:kzen-auto-js:build` + selfTest; manual with React DevTools "highlight updates": a
per-step expand/collapse or a progress tick no longer lights up sibling branches; drag/drop, the
dependency overlay, reference insertion, rename-while-open all behave as before. Fast run of a
40-step script stays smooth.

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 1 — expression engine | auto-jvm | one session | low-medium (inference swap is well-tested) | — |
| 2 — resource survival | kzen-lib + auto | one session | medium (migration semantics) | — |
| 3 — linked-doc live edit | auto-jvm | small session | low | — (2 recommended first) |
| 4 — validation cache | auto-jvm | small session | low | 1 (recommended); graph-2 (optional reuse) |
| 5 — mid-loop resume | auto-jvm | one session | medium (replay subtleties) | 2 |
| 6 — inline-branch stepping | kzen-lib + auto | one session | medium (step-rule change) | engine-plan 2 (coordinate) |
| 7 — trace bounding | auto-jvm | small session | low | — (transient emits gated on engine-4) |
| 8 — client sweep | auto-js | one full session | low-medium (wide but mechanical) | — |

Phases 1–4 are the high-priority core (hot path + two live-edit correctness gaps + validation
cost); 5–7 are capability/efficiency; 8 is independent and can interleave anywhere. If a session
runs long, land kzen-lib first (publishToMavenLocal keeps kzen-auto buildable) and note the split
in the tracker.
