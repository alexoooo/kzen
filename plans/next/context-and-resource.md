# Context feature: first-class provides/requires + slot-owned Resources

> **Anchors re-verified 2026-07-28** against kzen-lib and kzen-auto HEAD (three read-only sweeps: engine,
> notation/runtime, validation/UI). Corrections are folded in below. Blast radius confirmed contained:
> kzen-project and kzen-launcher have zero references to `ResourceScope`/`ResourceClosePolicy`/the resource API.

## Context

Kzen already has an implicit dependency-injection pattern: a supplier step (`BrowserOpenStep`) registers a value in the engine's run-scoped resource registry under a hard-coded string key (`"browser"`); receiver steps (`BrowserClickStep` etc.) look it up at runtime with an untyped cast and `error("Browser is not open")` when absent. Nothing declares the dependency — not notation, not validation, not the UI.

The engine (`RunEngine` in kzen-lib) already tracks resource **ownership**: `ResourceScope` (Self/Parent/Root) picks the owning execution-tree node, disposal fires at that node's settle per `ClosePolicy` (Auto/Manual/KeepOnFailure), and downstream Logic reads via an ancestor-chain walk. The user-facing `ResourceClosePolicy` enum (7 flat values) is the product of those two primitives.

**Goal** (user decisions confirmed):
1. **Context keys are first-class notation objects** (e.g. `BrowserContext`: value class, title, icon, description) — plugin-extensible with zero framework changes.
2. **Full slot model now** (breaking change accepted): documents declare context *slots* they own and contexts they *require* from callers; a supplier binds into the nearest ancestor-declared slot; the scope half of `ResourceClosePolicy` (parent/run variants) is **replaced** by slot ownership. Existing notation migrates.
3. **Enforcement in editor + runtime**: static validation surfaces unsatisfied requires as editor warnings (amber — a caller may legitimately provide); the step spine uniformly fails a step whose requirement is absent at execution.
4. **Script flavour first**: engine + notation model flavour-neutral; declarations/validation/UI for Script steps only.

## Design summary

- **Engine (kzen-lib)**: replace `ResourceScope` with **declared slots**. A node declares slot keys via new `Execution.declareSlot(key)`; `Execution.resource(key, policy, value, closer)` (scope param removed) binds into the nearest self→root ancestor declaring the key — **falling back to Self when none does** (preserves today's behaviour for undeclared keys: `JobRun`'s `"job-scratch"`, raw test steps, plugins). `ClosePolicy` stays **per-registration** (the opener owns the closer and its semantics). Dynamic keys supported as **families**: slot `"sut"` owns `"sut:main"` (`:` separator — already the SUT registry's format). New `hasResourceInFamily(family)` for the uniform requires check.
- **Notation (kzen-auto)**: abstract `Context` archetype + concrete `BrowserContext`/`SutContext`; Script documents declare `context: { slots: [...], requires: [...] }` as **inert data** (the `rerun`/`scope`/`group` marker precedent — no definer, so a dangling reference degrades to a validation message instead of breaking definition); supplier steps get a `ContextProvider` mix-in (evolves `ScopedResource`: `provides: <Context>` + `closePolicy`); receiver archetypes declare `requires: [<Context>]`, inherited via `is:`. `ResourceClosePolicy` shrinks to 3 values (auto/manual/keepOnFailure).
- **Validation**: shared-common `LogicContextAnalysis` walks the step tree tracking provided contexts; issues surface as new `StepValidation.warningMessage` (amber in editor), computed server-side by `ScriptValidator`, reaching the client over the existing wire.
- **Runtime**: `ScriptRunContext.runSteps` fails a step with absent requires uniformly (inside `recoverable` → Error trace + pause-on-error park + re-check on resume); `StepExecution` gains typed `provideContext`/`contextValue`/`context<T>()`; raw string API survives as escape hatch.
- **UI**: document-level context panel (slot/requires chips), step provides/requires badges with Context icons, amber unsatisfied-requires warning, 3-value closePolicy dropdown (auto-updates from the `values:` map — zero editor code change).

## 1. Engine (kzen-lib)

`kzen-lib-common\...\exec\engine\Execution.kt`:

```kotlin
/** Declare that THIS node owns a context slot for [key]: any descendant registering a resource under
 *  [key] or "[key]:<qualifier>" binds here, so disposal follows this node's settle. Call at Logic run
 *  start, before hosting children. Idempotent. */
fun declareSlot(key: String)

/** Ownership: nearest self→root ancestor declaring a slot matching [key] (exact, or the family before
 *  the first ':'); fallback: the opening node itself. */
fun resource(key: String, policy: ClosePolicy, value: Any? = null, closer: () -> Unit)

/** True when a live registration exists on the ancestor chain whose key is [family] or "[family]:...". */
fun hasResourceInFamily(family: String): Boolean
```

- Current signature (Execution.kt:139-144): `resource(key, policy, scope: ResourceScope = ResourceScope.Self, value: Any? = null, closer)` — dropping `scope` yields exactly the proposed shape. Call-site audit: `JobRun.kt:174` (kzen-auto, `resource("job-scratch", ClosePolicy.Auto) { … }`) omits `scope` and compiles unchanged; `ScriptRunContext.openResource` (ScriptRunContext.kt:262-265) passes `scope` explicitly and is rewritten in phase 2 anyway. No other external call sites pass `scope`.
- **Delete** `ResourceScope.kt`; remove the `scope` param. `resourceValue`/`releaseResource` unchanged (exact-key ancestor walk). `ClosePolicy` unchanged (`exec\engine\ClosePolicy.kt`: Auto/Manual/KeepOnFailure).
- Name check done: `declareSlot`/`hasResourceInFamily`/`hasResource` collide with nothing in any sibling.
- Slots declared by **the Logic itself at run start** (each `ScriptLogic` reads its own document's notation) — no `host(...)` signature churn, no engine-constructor churn, ordering guaranteed (parent declares before hosting children), and migration re-declaration is free (rebuilt tree re-runs each `Logic.run`).
- `RunEngine.kt` (kzen-lib-jvm, 1358 lines): `NodeRuntime` (line **84**; sibling `Registration(policy, value, closer)` at 77) gains `declaredSlots = LinkedHashSet<String>()`; `registerResource` (1122; `when (scope)` at 1128-1131) replaces the scope switch with a `slotOwner(nodeId, key)` ancestor walk (exact or family match, fallback opener); new `declareSlot`/`hasResourceInFamily` plumbed through the `Execution` impl overrides (`resource` 1331, `resourceValue` 1334, `releaseResource` 1337).
- **Untouched by design** (all keyed by node/stable-id, not scope): migration lift/re-adopt (`migrate` 511, `adoptLiftedResources` 640 — slot-owned resource carries by the slot-declaring node's stable id; `declaredSlots` not lifted, re-declared on rebuild), Manual hand-up at settle (`disposeResources` 1021, hand-up `putIfAbsent` at 1041), orphan sweep (`sweepOrphans` 607), descendant release (`releaseResource(nodeId, key)` 1153), ancestor read (`resourceValueFor` 1138). Edge case to document: an edit removing a slot declaration leaves an already-bound resource on that node until settle (ownership fixed at bind time); new opens resolve against new declarations.
- `ResourceClosePolicy.kt` (kzen-lib-common `exec\logic\`, 47 lines): trim to `Auto("auto")`/`Manual("manual")`/`KeepOnFailure("keepOnFailure")` — deleting constants `ParentDocument`, `ParentDocumentKeepOnFailure`, `Run`, `RunKeepOnFailure`; add `fun toEngine(): ClosePolicy`. Keep the class (notation-facing seam with `key` ctor param + `Companion.parse`). Its definer is NOT in kzen-lib: `ResourceClosePolicyDefiner` lives in kzen-auto-common `objects.document.script` (wired at script-jvm.yaml:19/31) and needs no change — it parses by wire key.

## 2. Notation (kzen-auto)

**`Context` archetype** — `notation\auto-common\common-document.yaml` (flavour-neutral):

```yaml
Context:
  abstract: true
  key: ""
  title: ""
  icon: ""
  description: ""
```

(`common-document.yaml` = `kzen-auto-jvm\src\main\resources\notation\auto-common\common-document.yaml`, 462 lines; `Script` at line 86, `ScriptStep` at 119 — both live here, not in script-jvm.yaml.)

Concrete in `script-jvm.yaml` (= `kzen-auto-jvm\src\main\resources\notation\auto-jvm\script\script-jvm.yaml`): `BrowserContext` (`is: Context`, `class: org.openqa.selenium.remote.RemoteWebDriver`, `key: browser`, icon/title/description). In kzen-auto-test `script-test.yaml` (= `kzen-auto-test\src\main\resources\notation\auto-jvm\script-test.yaml` — no `script\` subdir, unlike kzen-auto-jvm): `SutContext` (`class: ...SutHandle`, `key: sut` — family-qualified per name, matching `KzenAutoSubprocessRegistry.resourceKey(name) == "sut:$name"`, KzenAutoSubprocessRegistry.kt:27-29).

**Document-level** — `Script` archetype gains inert `context: {}`; usage:

```yaml
main:
  is: Script
  context:
    slots: [BrowserContext]      # this document OWNS — disposal at its settle
    requires: [SutContext]       # a caller must have provided
```

**Step-level** — replace `ScopedResource` (`script-jvm.yaml:36`) with:

```yaml
ContextProvider:
  abstract: true
  provides: ""
  closePolicy: auto
  meta:
    closePolicy: ResourceClosePolicy   # stays meta-declared: constructor param + dropdown
```

`BrowserOpenStep` (archetype at script-jvm.yaml:299-308, currently `is: [ScriptStep, ScopedResource]` with an empty trailing `meta:`): becomes `is: [ScriptStep, ContextProvider]`, `provides: BrowserContext`. Receivers get inert `requires: [BrowserContext]` **on each concrete archetype** — there is no shared browser-target base archetype in notation, only the Kotlin abstract class: `BrowserGetStep`, `BrowserClickStep` (337), `BrowserReadStep` (353), `BrowserWriteStep` (374), `BrowserSubmitStep` (400), `BrowserEnterStep`, `BrowserEscapeStep`, **and `BrowserCloseStep`** (a Close with no possible open upstream is a script bug — runtime becomes stricter than today's tolerant close, BrowserCloseStep.kt:24-37; note in changelog). `BrowserFocusStep` exists in Kotlin but its archetype is **commented out** (script-jvm.yaml:434-444, and the commented block points at the wrong class) — leave it commented, do not resurrect in this change. SUT pair: `StartKzenAutoStep` provides `SutContext` (qualifier = its `name` param, notation default `"main"`); `BrowserGetSutStep`/`StopKzenAutoStep` require it. `provides`/`requires`/`context` stay **out of meta** (inert → not constructor-injected, not body-rendered).

**Kotlin readers** (kzen-auto-common, new subpackage `tech.kzen.auto.common.objects.document.logic.context` — note: the originally-planned `objects\document\common\` does not exist in kzen-auto-common (only in kzen-auto-js's client tree); `document\logic\` is the existing flavour-neutral home (StepValidation, ParameterDefaultDefiner live there), so nest under it. Usable from JVM + JS):
- `ContextDescriptor(location, key, valueClass, title, icon, description)` + `ContextConventions` (resolve reference via `graphNotation.coalesce.locateOptional` — valid common API, `ObjectLocator.locateOptional`; read attributes via `firstAttribute` — use the **nullable `AttributePath` overload** (GraphNotation.kt:277) for optional attributes, the `AttributeName` overload throws when absent).
- `LogicContextConventions`: `documentSlots`/`documentRequires`/`stepProvides`/`stepRequires` (first-wins through the `is:` chain).

**`values:` map** in `script-jvm.yaml` (archetype block lines 14-28, the 7 entries at 22-28) → 3 entries reworded around the slot owner.

**Notation migration** (complete inventory — kzen-auto-test has exactly two documents with parent/run policies, verified by grep; ignore mirror copies under `build\resources\`):

| File | Old | New |
|---|---|---|
| `kzen-auto-test\...\notation\main\FizzBuzz\Open Kzen and Browser.yaml` | line 8 `closePolicy: parent` (Start SUT), line 15 `parentKeepOnFailure` (Open Browser) | `auto` / `keepOnFailure`; caller document gains `context: { slots: [SutContext, BrowserContext] }` |
| `kzen-auto-test\...\notation\main\FormulaError\Open Kzen and Browser.yaml` | line 11 `closePolicy: parent`, line 15 `manual` | `parent` → `auto` + caller slot; `manual` unchanged |
| `kzen-auto-jvm\src\test\resources\notation\test\script-resource-run-scope-test.yaml` + `-run-scope-mid-test.yaml` + `-run-scope-leaf-test.yaml` | leaf `closePolicy: run` | root declares slot; leaf `auto` |
| `script-resource-parent-scope-test.yaml` + `-parent-scope-child-test.yaml` | child `closePolicy: parent` | parent declares slot; child `auto` |
| `script-resource-{success,failure,migration}-test.yaml` | auto/manual/keepOnFailure | unchanged |

Add `TestSutContext` to test archetypes; keep `OpenResourceTestStep` on the **raw string API** deliberately — pins raw/typed interop (same key ⇒ binds to declared slot) and the Self default.

**JVM-only test-graph trap** (OpenResourceTestStep.kt:17-20 KDoc): an inline test archetype whose `meta` binds `ResourceClosePolicy` drags the JS-only `SelectValuesEditor`/`AttributeEditorManager` reference into the JVM-only test graph, which fails to resolve — that is why `OpenResourceTestStep` takes `closePolicy` as a plain String parsed in Kotlin. Any new typed-provider **test fixture** step must do the same (plain-string closePolicy, no `ContextProvider` mix-in with meta-declared policy) — `TestSutContext` itself is safe (pure Context data object, no meta). The real `ContextProvider` mix-in is only exercised through the full notation graph (kzen-auto-test selfTest / dev instance).

## 3. Static validation

`LogicContextAnalysis` (kzen-auto-common, pure `GraphNotation`):
- `analyze(graphNotation, documentPath): Map<ObjectPath, ContextIssue>` — linear step walk tracking `available` set seeded from `documentRequires`; per step: unsatisfied `stepRequires` → warning; add `stepProvides` (conditional branches count conservatively — warnings only); RunStep (hosted document read from its `instructions` attribute — `ScriptConventions.instructionsAttributeName`, `runStepObjectName` at ScriptConventions.kt:24) → check hosted document's `documentRequires ⊆ available` and add its `escapingProvides` (provides minus own-declared slots, recursed through branches via `ScriptConventions.stepBranchAttributeNames` — exact name confirmed, ScriptConventions.kt:93-121 — cycle-guarded). Also flag dangling Context references and duplicate keys.
- Surface: `StepValidation` (kzen-auto-common `objects\document\logic\StepValidation.kt:19-70`) gains `warningMessage: String? = null` (wire key `"warning"`). The codec is **manual ExecutionValue encoding** (`asExecutionValue` 62-69 / `ofMapExecutionValue` 28-57) and the existing keys decode **strictly** (throw when absent, lines 30/44) — the new key must use a nullable lookup (`map[warningKey]` → absent ⇒ null), not copy the existing pattern. `StepValidation` is shared with the Job flavour (`JobValidation`/`JobValidator`/`WorkerDisplayDefault`) — the field simply stays null there; no Job-side change.
- `ScriptValidator.validate` (kzen-auto-jvm `objects\script\ScriptValidator.kt`, companion `validate` at 41-102) merges analysis output. `ScriptValidationCache` already invalidates on notation change (Caffeine keyed by `LogicValidationDigest.documentClosureKey` over the full transitive definition). JS stores pick the field up over the existing wire (`ScriptValidationStore` → `ScriptValidation.ofExecutionValue` → per-step `StepValidation.ofMapExecutionValue`).
- **Run gate**: `ScriptStore.currentValidationErrors()` (kzen-auto-js, ScriptStore.kt:239-250) keys the Run gate off `errorMessage != null` — leave it untouched; warnings are advisory and must NOT block Run.

## 4. Runtime (Script spine)

`StepExecution` (kzen-auto-jvm, `tech.kzen.auto.server.objects.script.api.StepExecution` — 202 lines; existing raw members `openResource`/`resource`/`releaseResource` at 161/164/170 stay as the escape hatch; no name collisions with the new members — `contextValue` exists only as an unrelated React helper in kzen-auto-js):

```kotlin
fun provideContext(value: Any?, closePolicy: ResourceClosePolicy, qualifier: String? = null, closer: () -> Unit)
fun contextValue(context: ObjectLocation? = null, qualifier: String? = null): Any        // uniform failure if absent
fun contextValueOrNull(context: ObjectLocation? = null, qualifier: String? = null): Any?
fun releaseContext(context: ObjectLocation? = null, qualifier: String? = null)
// + inline fun <reified T: Any> StepExecution.context(qualifier: String? = null): T
```

Resolution rule when `context == null`: the step's **sole** required context descriptor (uniform-failure `error(...)` if the step declares zero or more than one — pass the location explicitly then). `context<T>()` resolves to the unique required descriptor whose `valueClass` is `T` (same zero/ambiguous failure). `provideContext` needs no descriptor argument — it resolves the current step's own `provides` reference.

`ScriptRunContext`:
- At run start (`ScriptLogic.run` / context init): `documentSlots` → `execution.declareSlot(descriptor.key)` for each — every document's own Logic does this (root and hosted alike).
- In `runSteps` (line 279; the `recoverable` block is at 322-336, `step.run(this)` at 335), **inside** `recoverable`, before `step.run`: for each cached required descriptor, `if (!execution.hasResourceInFamily(required.key)) error("Requires ${required.title}: not provided")` — free uniform framing (Error trace, pause-on-error park, re-check on resume).
- `provideContext`: resolve current step's `provides` → key (+`:qualifier`) → `execution.resource(key, closePolicy.toEngine(), value, closer)`. The existing `private fun ResourceClosePolicy.toEngine(): Pair<ResourceScope, ClosePolicy>` at ScriptRunContext.kt:660-668 is deleted, replaced by the enum's own 3-value `toEngine(): ClosePolicy` (§1); `openResource` override at 262-265 drops its `scope` argument.

Step changes: `BrowserOpenStep` (replace-existing at BrowserOpenStep.kt:29-33, registration at 52) → `contextValueOrNull`+`releaseContext` for replace-existing, then `provideContext(driver, closePolicy) { quitQuietly }`; receivers → `execution.context<RemoteWebDriver>()` (the ad-hoc `?: error("Browser is not open")` pattern removed at its 4 sites: BrowserTargetStep.kt:38-39 — covers all 5 subclasses — BrowserGetStep.kt:29-30, BrowserEnterStep.kt:28-29, BrowserEscapeStep.kt:28-29); `BrowserCloseStep` → `contextValueOrNull` → quit → `releaseContext`; SUT steps use `qualifier = name` (StartKzenAutoStep.kt:66 registration, BrowserGetSutStep.kt:44-47 lookup, StopKzenAutoStep.kt:23-27 release — note Start also maintains the process-global `KzenAutoSubprocessRegistry` map, which is orthogonal and stays). `WebDriverSupport.resourceKey` retires from the open path.

## 5. UI (kzen-auto-js)

1. **Document context panel** (`ScriptController.kt` — parameters/results render via `renderSignature` at 388-402): slot + requires chips (icon/title from `ContextDescriptor`, computed client-side from notation); add/remove picker listing all `is: Context` objects; writes via existing structural commands on the plain list attributes. **Placement constraint**: the document-level error `div` at ScriptController.kt:343-348 is deliberately ALWAYS emitted to keep `MultiStepDisplay`'s child index stable — the panel must render inside `renderSignature`'s output or as another always-emitted div, never as a new conditional sibling (a conditional sibling remounts the step subtree).
2. **Step badges** (`step\header\StepHeader.kt` / `ScriptStepDisplayDefault.kt`): "provides ⟨icon⟩" badge (closePolicy in tooltip; tooltip states "bound to: this document / a calling document" from whether own document declares the slot) + per-requires badges. Additive to the existing right-cluster mechanism — `StepHeader.renderRightCluster()` (248-353) already hosts the validation-error icon-in-Tooltip (260-280) and Skipped/Partial/type `Chip`s; new props go in `StepHeaderProps` (31-58).
3. **Amber unsatisfied-requires** warning from `StepValidation.warningMessage` via `ScriptValidationStore` (distinct from red definition-error tint). Mechanics: new colour constant beside `validationErrorColour = Color("#d84315")` (ScriptStepDisplayDefault.kt:72); widen `statusBorderColor(...)` (89-102 — run status wins, then error, then warning, then white) and its 4 call sites: ScriptStepDisplayDefault.kt:289, DoWhileStepDisplay.kt:86, ForEachStepDisplay.kt:165, IfStepDisplay.kt:374.
4. closePolicy dropdown: unchanged code, 3 options from the updated `values:` map.

## 6. Testing & docs

- **kzen-lib** `RunEngineTest.kt:1698-2063` rewrite (the `//------ tree-scoped resources (ResourceScope)` block: 11 tests from `parentScopedResourceOutlivesItsChildAndDisposesAtParentSettle` at 1716 through `releaseResourceFromDescendantRemovesAncestorScopedRegistration` at 2033; file is 2208 lines): parent-declared slot outlives child; root-declared from depth two; nearest-ancestor-wins; **undeclared key defaults to Self** (pins JobRun-style usage); family matching (slot `"sut"` owns `"sut:a"`/`"sut:b"` independently); KeepOnFailure at failed slot owner; Manual hand-up past slot owner; migration lift/re-adopt with re-declaration; descendant release. `cancelSettlesCancelledAndDisposesResources` (379) is outside the block and should keep passing unchanged.
- **kzen-auto**: `ScriptExtensibilityTest.kt:72-153` + fixtures per §2; new `ScriptContextValidationTest` (unsatisfied/satisfied-by-document-requires/RunStep hosted-requires/escaping provides/dangling reference); new runtime test (uniform spine failure + pause-on-error resume-after-fix; typed provide/consume across RunStep; qualified SutContext round trip); FizzBuzz selfTest end-to-end.
- **Docs**: `kzen-lib\docs\logic-spec.md` `## 6. Resources` (lines 459-503) rewritten around slots; the confinement material is a bullet inside `## 2. Execution model` ("Heterogeneous composition", 99-108, with the §6 exception noted at 106-108) — update that cross-ref too. Both `architecture.md` files (Context type objects beside the ResourceClosePolicy precedent; inert markers beside `rerun`/`scope`/`group` — precedent lives at script-jvm.yaml lines 170/230/261/267); `js-architecture.md` for badges/panel; AGENTS.md files if they enumerate the resource API.

## 7. Sequencing (composite-build aware)

1. **Phase 1 — engine (kzen-lib)**: Execution API, RunEngine slots, delete ResourceScope, trim ResourceClosePolicy, RunEngineTest, logic-spec §6. Then `cd ../kzen-lib && ./gradlew publishToMavenLocal` (all 4 subprojects) **before any kzen-auto compile**.
2. **Phase 2 — notation + runtime (kzen-auto)**: Context/ContextProvider archetypes, conventions readers, StepExecution API, ScriptRunContext, browser + SUT steps, yaml migrations, fixtures.
3. **Phase 3 — validation**: LogicContextAnalysis, StepValidation.warningMessage, ScriptValidator merge, tests.
4. **Phase 4 — UI (kzen-auto-js)**: panel, badges, amber warnings.
5. **Phase 5 — docs + FizzBuzz selfTest** end-to-end.

Phases 2–4 land as one atomic change from kzen-auto's perspective (the enum shrinks); phase 1 is independently green in kzen-lib. Verification per phase: `cd ../kzen-lib && ./gradlew build`; `cd ../kzen-auto && ./gradlew build` (+ `:kzen-auto-js:compileKotlinJs` fast gate); UI smoke via own dev instance on a spare port (never the user's running 8080).

## Key decisions & rationale (made during design)

- **Slot declaration by the Logic at run start**, not via `host(...)` params: flavour-neutral, no layering inversion (hosting side needn't read the child's notation), migration re-declaration free.
- **Undeclared key → Self**: confinement-safe default preserving all existing undeclared usage; the old parent/run reach-up *without the ancestor's consent* is exactly what the feature removes.
- **ClosePolicy stays per-registration**: opener owns the closer and its semantics; per-slot defaults can layer on later.
- **Dynamic keys as `family:qualifier`**: makes the SUT pair fully typed instead of leaving the second first-party pair invisible to the feature; matches its existing key format.
- **Inert notation data over meta-declared**: no definer → dangling references degrade to validation messages, not definition failures (sidesteps the notation-wiring traps at kzen-auto `docs\architecture.md:123-128` — a `by:` in `meta` needs a sibling `is:` or it silently falls back to `StructuralAttributeDefiner`, and `firstAttribute(AttributeName)` throws when absent).
