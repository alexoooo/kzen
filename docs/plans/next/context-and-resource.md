# Context feature: first-class provides/requires + slot-owned Resources

> **Anchors re-verified 2026-07-28** against kzen-lib and kzen-auto HEAD (three read-only sweeps: engine,
> notation/runtime, validation/UI), then **design-reviewed 2026-07-28** — a fourth sweep that re-checked ~30
> anchors (all accurate) and pushed back on the design. Its corrections are folded in below, marked **[review]**
> where they change a decision rather than add detail. A **final review 2026-07-29** (fifth sweep) re-verified
> ~60 anchors against clean kzen-lib/kzen-auto trees — all still exact — and folded four further corrections,
> marked **[final]**: the §2(b) slot-owner files move into Session A, §3 models the Manual hand-up escape and
> states the hosted-requires check, and the acceptance wording now matches what §3 actually ambers. Blast radius confirmed contained: kzen-project,
> kzen-launcher and kzen-shell have zero references to `ResourceScope`/`ResourceClosePolicy`/`openResource`, and
> `kzen-auto-plugin`'s SPI surface (`api\` = DataFramer, HeaderExtractor, ReportIntermediateStep,
> ReportTerminalStep) does not touch the resource API — that module needs nothing.
>
> **Lifecycle exception — do not delete this file when it lands.** This is a *standalone* plan: design rationale
> and execution elaboration in one document, with no constituent plan behind it. `docs/plans/next/README.md`'s
> "delete the elaboration when the phase lands" rule assumes a constituent plan holds the rationale; applying it
> here would destroy the only record of a breaking change's design. On landing, move this document to the sprint
> archive as an as-built record (README carries the same exception).

## What a user sees

Today a browser is an invisible convention: `Open browser` writes a handle under a hard-coded string, every
later step reads it back, and nothing — notation, validation, or UI — says the dependency exists. After this
change a Script **declares** it: *this document owns a browser* (a context **slot**), *this sub-script needs
one from its caller* (**requires**), *this step opens one* (**provides**). The editor shows the declarations as
chips on the document and badges on the steps, ambers any step whose requirement nothing upstream satisfies,
and a run fails such a step uniformly instead of at whatever ad-hoc `error("Browser is not open")` it happens
to reach. Ownership stops being the opener's unilateral guess (`closePolicy: parent`/`run` reaching up without
the ancestor's consent) and becomes the ancestor's own declaration.

That paragraph is also the acceptance test — see the per-phase exit criteria in §7.

## Context

Kzen already has an implicit dependency-injection pattern: a supplier step (`BrowserOpenStep`) registers a value in the engine's run-scoped resource registry under a hard-coded string key (`"browser"`); receiver steps (`BrowserClickStep` etc.) look it up at runtime with an untyped cast and `error("Browser is not open")` when absent. Nothing declares the dependency — not notation, not validation, not the UI.

The engine (`RunEngine` in kzen-lib) already tracks resource **ownership**: `ResourceScope` (Self/Parent/Root) picks the owning execution-tree node, disposal fires at that node's settle per `ClosePolicy` (Auto/Manual/KeepOnFailure), and downstream Logic reads via an ancestor-chain walk. The user-facing `ResourceClosePolicy` enum (7 flat values) is the product of those two primitives.

**Goal** (user decisions confirmed):
1. **Context keys are first-class notation objects** (e.g. `BrowserContext`: value class, title, icon, description) — plugin-extensible with zero framework changes.
2. **Full slot model now** (breaking change accepted): documents declare context *slots* they own and contexts they *require* from callers; a supplier binds into the nearest ancestor-declared slot; the scope half of `ResourceClosePolicy` (parent/run variants) is **replaced** by slot ownership. Existing notation migrates.
3. **Enforcement in editor + runtime**: static validation surfaces unsatisfied requires as editor warnings (amber — a caller may legitimately provide); the step spine uniformly fails a step whose declared requirement is absent at execution. Two deliberate boundaries on "uniformly": closer steps declare `releases:` instead of `requires:` and are never gated (§2), and the gate is family-granular, so a qualifier mismatch surfaces at read rather than at the gate (§1).
4. **Script flavour first**: engine + notation model flavour-neutral; declarations/validation/UI for Script steps only.

## Design summary

- **Engine (kzen-lib)**: replace `ResourceScope` with **declared slots**. A node declares slot keys via new `Execution.declareSlot(key)`; `Execution.resource(key, policy, value, closer)` (scope param removed) binds into the nearest self→root ancestor declaring the key — **falling back to Self when none does** (preserves today's behaviour for undeclared keys: `JobRun`'s `"job-scratch"`, raw test steps, plugins). `ClosePolicy` stays **per-registration** (the opener owns the closer and its semantics). Dynamic keys supported as **families**: slot `"sut"` owns `"sut:main"` (`:` separator — already the SUT registry's format). New `hasResourceInFamily(family)` for the uniform requires check.
- **Notation (kzen-auto)**: abstract `Context` archetype + concrete `BrowserContext`/`SutContext`; Script documents declare `context: { slots: [...], requires: [...] }` as **inert data** (no metadata entry ⇒ never defined, so a dangling reference degrades to a validation message instead of breaking definition — mechanism and the `meta:` trap in §2); supplier steps get a `ContextProvider` mix-in (evolves `ScopedResource`: `provides: <Context>` + `closePolicy`); receiver archetypes declare `requires: [<Context>]` and closer archetypes `releases: <Context>`, all inherited via `is:`. `ResourceClosePolicy` shrinks to 3 values (auto/manual/keepOnFailure).
- **Validation**: shared-common `LogicContextAnalysis` walks the step tree tracking provided contexts; issues surface as new `StepValidation.warningMessage` (amber in editor), computed server-side by `ScriptValidator`, reaching the client over the existing wire. A hosted document's escaping provides count only where an enclosing slot actually owns them — otherwise the RunStep warns (§3), so the analysis never certifies a configuration the runtime disposes early.
- **Runtime**: `ScriptRunContext.runSteps` fails a step with absent requires uniformly (inside `recoverable` → Error trace + pause-on-error park + re-check on resume); `StepExecution` gains typed `provideContext`/`contextValue`/`context<T>()`, resolving argument-free off the step's sole declared context (`provides` ∪ `requires` ∪ `releases`); raw string API survives as escape hatch.
- **UI**: document-level context panel (slot/requires chips), step provides/requires/releases badges with Context icons, amber unsatisfied-requires warning, 3-value closePolicy dropdown (auto-updates from the `values:` map — zero editor code change).

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

/** True when a live registration exists on the ancestor chain whose key is [family] or "[family]:...".
 *  Family-level by design: it answers "is SOME sut open", never "is sut:formula-error-sut open". */
fun hasResourceInFamily(family: String): Boolean
```

- Current signature (Execution.kt:139-144): `resource(key, policy, scope: ResourceScope = ResourceScope.Self, value: Any? = null, closer)` — dropping `scope` yields exactly the proposed shape. Call-site audit: `JobRun.kt:174` (kzen-auto, `resource("job-scratch", ClosePolicy.Auto) { … }`) omits `scope` and compiles unchanged; `ScriptRunContext.openResource` (ScriptRunContext.kt:262-265) passes `scope` explicitly and is rewritten in phase 2 anyway. No other external call sites pass `scope`.
- **Delete** `ResourceScope.kt`; remove the `scope` param. `resourceValue`/`releaseResource` unchanged (exact-key ancestor walk). `ClosePolicy` unchanged (`exec\engine\ClosePolicy.kt`: Auto/Manual/KeepOnFailure).
- Name check done: `declareSlot`/`hasResourceInFamily`/`hasResource` collide with nothing in any sibling.
- Slots declared by **the Logic itself at run start** (each `ScriptLogic` reads its own document's notation) — no `host(...)` signature churn, no engine-constructor churn, ordering guaranteed (parent declares before hosting children), and migration re-declaration is free (rebuilt tree re-runs each `Logic.run`).
- `RunEngine.kt` (kzen-lib-jvm, 1358 lines): `NodeRuntime` (line **84**; sibling `Registration(policy, value, closer)` at 77) gains `declaredSlots = LinkedHashSet<String>()`; `registerResource` (1122; `when (scope)` at 1128-1131) replaces the scope switch with a `slotOwner(nodeId, key)` ancestor walk (exact or family match, fallback opener); new `declareSlot`/`hasResourceInFamily` plumbed through the `Execution` impl overrides (`resource` 1331, `resourceValue` 1334, `releaseResource` 1337).
- **Untouched by design** (all keyed by node/stable-id, not scope): migration lift/re-adopt (`migrate` 511, `adoptLiftedResources` 640 — slot-owned resource carries by the slot-declaring node's stable id; `declaredSlots` not lifted, re-declared on rebuild), Manual hand-up at settle (`disposeResources` 1021, hand-up `putIfAbsent` at 1041), orphan sweep (`sweepOrphans` 607), descendant release (`releaseResource(nodeId, key)` 1153), ancestor read (`resourceValueFor` 1138). Edge case to document: an edit removing a slot declaration leaves an already-bound resource on that node until settle (ownership fixed at bind time); new opens resolve against new declarations.
- `ResourceClosePolicy.kt` (kzen-lib-common `exec\logic\`, 47 lines): trim to `Auto("auto")`/`Manual("manual")`/`KeepOnFailure("keepOnFailure")` — deleting constants `ParentDocument`, `ParentDocumentKeepOnFailure`, `Run`, `RunKeepOnFailure`; add `fun toEngine(): ClosePolicy`. Keep the class (notation-facing seam with `key` ctor param + `Companion.parse`). Its definer is NOT in kzen-lib: `ResourceClosePolicyDefiner` lives in kzen-auto-common `objects.document.script` (wired at script-jvm.yaml:19/31) and needs no change — it parses by wire key. **[review] Rewrite the class KDoc too**: it currently opens "*which document's lifetime it is bound to*" and describes the scope+rule decomposition, both of which the slot model deletes. Under slots `auto` no longer means "this document" — it means *the owning slot's* document, possibly several levels up. Three surfaces carry that sentence and all three change together: this KDoc, the `values:` map in script-jvm.yaml (§2), and logic-spec §6 (§6 below).
- **[review] Qualifier-blindness is a deliberate, documented limitation.** Both the runtime gate (`hasResourceInFamily`) and the static analysis (§3) reason at *family* granularity — the qualifier is a step parameter and may be computed, so neither layer can know that `BrowserGetSutStep(name = "other")` wants `sut:other` specifically. A step requiring a qualifier no registration matches therefore passes the uniform gate and then fails at read, with the same shape of message as today. This is the one place the feature's "uniform enforcement" promise does not reach; state it in the logic-spec §6 rewrite rather than discovering it mid-implementation.
- **[review] Only `ScriptLogic` declares slots.** The other two `Logic` implementations — `JobRun` (kzen-auto-jvm `exec\job\`) and `FlowLogic` (kzen-auto-jvm `exec\flow\FlowLogic.kt`) — declare none and ride the Self fallback unchanged; that is the whole point of the fallback. No Flow/Job work in this change.

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

**[review] `key` is author-specified, so Contexts can alias — decided deliberately.** Deriving the resource key from the Context object's `ObjectLocation` would make collisions impossible by construction, but it would break the raw-string API's interop, which is the whole escape hatch: `WebDriverSupport.resourceKey` (`"browser"`), `KzenAutoSubprocessRegistry.resourceKey(name)` (`"sut:$name"`), `JobRun`'s `"job-scratch"` and `OpenResourceTestStep`'s notated `key:` all name keys as plain strings, and "same key ⇒ same registration" is what lets typed and raw steps share one resource. The cost is that two Context objects declaring `key: browser` silently share a registration. Mitigation: the §3 analysis flags duplicate keys **graph-wide** (not per document — a plugin's Context aliasing a first-party one is exactly the case worth catching), and the logic-spec §6 rewrite states that a Context `key` is a global namespace.

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

`BrowserOpenStep` (archetype at script-jvm.yaml:299-308, currently `is: [ScriptStep, ScopedResource]` with an empty trailing `meta:`): becomes `is: [ScriptStep, ContextProvider]`, `provides: BrowserContext`. Receivers get inert `requires: [BrowserContext]` **on each concrete archetype** — there is no shared browser-target base archetype in notation, only the Kotlin abstract class: `BrowserGetStep`, `BrowserClickStep` (337), `BrowserReadStep` (353), `BrowserWriteStep` (374), `BrowserSubmitStep` (400), `BrowserEnterStep`, `BrowserEscapeStep`. `BrowserFocusStep` exists in Kotlin but its archetype is **commented out** (script-jvm.yaml:434-444, and the commented block points at the wrong class) — leave it commented, do not resurrect in this change. SUT: `StartKzenAutoStep` provides `SutContext` (qualifier = its `name` param, notation default `"main"`); **`BrowserGetSutStep` requires BOTH** — `requires: [BrowserContext, SutContext]`, since it reads the driver (BrowserGetSutStep.kt:44) *and* the handle (47) — which also makes it the fixture that exercises `context<T>()`'s type disambiguation (§4).

**[review] Closer steps declare `releases:`, not `requires:`** — a third inert marker, decided once for the category rather than per step. The earlier draft gave `BrowserCloseStep` a `requires: [BrowserContext]`; that is reversed here, because the uniform spine gate changes both closers for the worse: `StopKzenAutoStep` has an *explicit, deliberate* tolerant branch (StopKzenAutoStep.kt:29-32 traces `"no SUT registered as '$name', nothing to stop"` and returns), which the gate would convert into a hard failure plus a pause-on-error park; `BrowserCloseStep` (24-37) is tolerant for the same reason. A closer's job is to make the absence true, so "already absent" is success, not an error.

```yaml
BrowserCloseStep:
  abstract: true
  is: ScriptStep
  releases: BrowserContext     # inert, like provides/requires
```

`releases:` earns its keep three times over rather than being a special case bolted onto `requires`: it (i) supplies the descriptor so `contextValueOrNull` / `releaseContext` resolve argument-free (§4 — a step with *no* declared context has nothing to infer from); (ii) is never gated at run time and never ambers, which is correct — a Close step is not a consumer; and (iii) lets the §3 analysis **remove** the context from `available` after the closer, so a browser step placed *after* a Close correctly ambers, which nothing catches today. `BrowserCloseStep` and `StopKzenAutoStep` are its only two first-party users.

`provides`/`requires`/`releases`/`context` stay **out of `meta:`** — inert, so not constructor-injected and not body-rendered. **[review] The mechanism, and a trap:** an attribute is defined only if it appears in the object's *metadata* — `AttributeObjectDefiner.define` iterates `objectMetadata.attributes.map` and nothing else — so a top-level notation attribute with no `meta:` entry is simply never defined. Do **not** follow the `rerun`/`scope`/`group` precedent literally when writing these: those three live *inside* `meta:` as attribute-**metadata** keys (script-jvm.yaml 170/230/261/267 are all nested under a `meta: <attr>:` block), which is a different layer. Writing `meta: { provides: … }` here would define the attribute and defeat the whole point.

**[as-built 2026-07-29] Omitting `meta:` is NOT sufficient for inertness — the declarations must be written
as LISTS.** The paragraph above is right about `AttributeObjectDefiner` and wrong about what reaches it:
metadata is not only *declared*, it is **inferred**. `NotationMetadataReader.inferMetadata`
(kzen-lib-common `service\metadata\`, called from `readObjectImpl` for every attribute the `meta:` blocks
along the inheritance chain do not cover) promotes any undeclared **scalar** attribute whose value resolves
to a graph object into a synthesized `is: <that object>` attribute — with the referenced object's `class:`
as its type. A scalar `releases: BrowserContext` therefore becomes a real object reference, drags
`BrowserContext` into the declaring step's definition closure, and — because a Context is `abstract` and
names a class the graph cannot instantiate — the step is dropped from `GraphDefinitionAttempt`
`transitiveSuccessful`, surfacing at run time as `"Not a ScriptStep: …"`. `ListAttributeNotation` is not a
scalar, so inference skips it; that is why `requires:` (written as a list from the start) never showed the
fault while `provides:` / `releases:` did. All three are lists now, single-entry included, and
`LogicContextConventions` reads either shape so the list is purely a hazard-avoidance convention.

**[as-built 2026-07-29] A concrete Context must also declare `abstract: true`** (as `ResourceClosePolicy`
and `TypeMetadata` do). `class:` is kzen's *instantiation* key, so a non-abstract `BrowserContext` makes
`GraphCreator` try to construct a `RemoteWebDriver` — `"Unknown: org.openqa.selenium.remote.RemoteWebDriver"`,
failing the whole graph. Abstract carries the type without instantiating it, which is all a Context needs.

**Kotlin readers** (kzen-auto-common, new subpackage `tech.kzen.auto.common.objects.document.logic.context` — note: the originally-planned `objects\document\common\` does not exist in kzen-auto-common (only in kzen-auto-js's client tree); `document\logic\` is the existing flavour-neutral home (StepValidation, ParameterDefaultDefiner live there), so nest under it. Usable from JVM + JS):
- `ContextDescriptor(location, key, valueClass, title, icon, description)` + `ContextConventions` (resolve reference via `graphNotation.coalesce.locateOptional` — valid common API, `ObjectLocator.locateOptional`; read attributes via `firstAttribute` — use the **nullable `AttributePath` overload** (GraphNotation.kt:277) for optional attributes, the `AttributeName` overload throws when absent).
- `LogicContextConventions`: `documentSlots`/`documentRequires`/`stepProvides`/`stepRequires`/`stepReleases`. **Inheritance comes free**: `GraphNotation.firstAttribute(objectLocation, attributePath)` (GraphNotation.kt:277) already walks the *linearized* inheritance chain and returns the closest ancestor's value, so a user's step object `is: BrowserClickStep` reads the archetype's `requires` with no manual walk. Note the semantics that follow from "closest wins": a concrete archetype declaring its own `requires` **replaces** an inherited list rather than extending it. That is the intended rule (there is no first-party case that needs merging), but it must be stated, since a plugin author combining two requiring mix-ins would silently get only one.

**`values:` map** in `script-jvm.yaml` (archetype block lines 14-28, the 7 entries at 22-28) → 3 entries reworded around the slot owner.

**Notation migration.** **[review] The earlier draft's table covered only the four files whose `closePolicy` *value* changes; that is a third of the real surface.** The feature's new obligation is `context.slots` on the owners and `context.requires` on every hosted document that consumes a context it does not itself provide — neither was inventoried. Full surface below; ignore mirror copies under `build\resources\`.

**(a) `closePolicy` value changes** — the only four, verified by `grep -rn "closePolicy" --include=*.yaml` (the remaining hits are archetype definitions and already-valid `auto`/`manual`/`keepOnFailure`):

| File | Old | New |
|---|---|---|
| `kzen-auto-test\...\main\FizzBuzz\Open Kzen and Browser.yaml` | line 8 `parent` (Start SUT), line 15 `parentKeepOnFailure` (Open Browser) | `auto` / `keepOnFailure` |
| `kzen-auto-test\...\main\FormulaError\Open Kzen and Browser.yaml` | line 11 `parent` (Start SUT), line 15 `manual` (Open Browser) | `auto`; `manual` **unchanged** |
| `kzen-auto-jvm\src\test\resources\notation\test\script-resource-run-scope-leaf-test.yaml` | line 10 `run` | `auto` |
| `...\script-resource-parent-scope-child-test.yaml` | line 10 `parent` | `auto` |
| `script-resource-{success,failure,migration}-test.yaml` | auto/manual/keepOnFailure | unchanged |

The `manual` in FormulaError is genuinely unchanged, not merely tolerated: Self fallback registers it on the sub-document's node, and `disposeResources`' Manual hand-up (`putIfAbsent`, RunEngine.kt:1041) walks it to the parent at that node's settle — reproducing today's reach exactly.

**(b) Slot owners — the documents that must gain `context: { slots: [...] }`.** None of these were named before; they are the *callers*, and they are what makes (a) safe:

| File | Gains |
|---|---|
| `kzen-auto-test\...\main\FizzBuzz\FizzBuzz.yaml` (root) | `slots: [SutContext, BrowserContext]` |
| `kzen-auto-test\...\main\FormulaError\FormulaError.yaml` (root) | `slots: [SutContext]` (the browser there is `manual`, self-bound then handed up — no slot needed) |
| `...\test\script-resource-parent-scope-test.yaml` | `slots: [TestSutContext]` |
| `...\test\script-resource-run-scope-test.yaml` (root of root→mid→leaf) | `slots: [TestSutContext]` |

**[final] (b) lands in Session A, with (a) — not Session B as the earlier session split had it.** "They are
what makes (a) safe" is not just an annotation concern: migrating FizzBuzz's `parent`/`parentKeepOnFailure` to
`auto`/`keepOnFailure` without the root's slots binds the SUT and browser to the provider sub-document (Self
fallback) and disposes them at *its* settle — the later sub-scripts then find nothing, so the suite is
semantically broken between the sessions, not merely amber. Likewise `script-resource-parent-scope-child-test.yaml`'s
migrated `auto` needs its owner's `TestSutContext` slot for the kzen-auto-jvm resource tests to keep asserting
parent reach — without it, Session A's "`./gradlew build` green" exit criterion is unachievable. The runtime
that reads `documentSlots` ships in phase 2 (Session A) anyway; these are 4 small yaml edits.

**(c) `context.requires` sweep — 17 self-test documents contain browser/SUT steps.** Reproduce with, from `kzen-auto-test\src\main\resources\notation`:

```
grep -rln "BrowserOpenStep\|BrowserGetStep\|BrowserClickStep\|BrowserReadStep\|BrowserWriteStep\
\|BrowserSubmitStep\|BrowserEnterStep\|BrowserEscapeStep\|BrowserCloseStep\|BrowserGetSutStep\
\|StartKzenAutoStep\|StopKzenAutoStep" .
```

`main\Actions\Insert Last.yaml`; `main\FizzBuzz\{Open Kzen and Browser, Close Browser and Kzen}.yaml`; `main\FizzBuzz\Item\{Create Item Script, Add number Parameter, Add Result Type, Add Result Step, FizzBuzz Formula}.yaml`; `main\FizzBuzz\Loop\{Create Loop Script, Insert Range, Insert Loop, Insert Display, Insert Run}.yaml`; `main\FizzBuzz\Run\Run and Await.yaml`; `main\FormulaError\{Open Kzen and Browser, Run and Read Error, Close Browser and Kzen}.yaml`. (The 18th grep hit, `auto-jvm\script-test.yaml`, is the archetype file — §2 above, not a migration.)

Every one of these except the two `Open Kzen and Browser.yaml` providers needs `context: { requires: [BrowserContext] }` (plus `SutContext` where it navigates by SUT name). `Insert Last.yaml` is the load-bearing case: a shared library script hosted from five call sites (`Add Result Step`, `FizzBuzz Formula`, `Insert Display`, `Insert Loop`, and `main\Script.yaml`).

Two consequences to decide before starting, not during:
- **`main\Script.yaml` is a bare harness** (`main.steps/Run` → `Insert Last.yaml`, nothing else) that provides no browser. Once `Insert Last` declares `requires`, its RunStep there warns permanently. That is arguably correct — the harness genuinely cannot run standalone — so the intended resolution is to leave the warning and note it in the self-test README, not to weaken the analysis.
- **Skipping (c) is a legitimate scope cut, but must be explicit.** Without it the run still works (warnings never block Run, §3) but the self-test notation shows amber on ~15 documents the moment anyone opens it. If (c) slips to a follow-up, say so in the landing note; do not let it slip silently.

**(d) Test archetypes.** Add `TestSutContext` to `kzen-auto-jvm\src\test\resources\notation\test\script-step-test-archetypes.yaml` with **`key: sut`** — matching the `key: sut` the four resource fixtures already open under, which is what makes the raw/typed interop assertion real. Keep `OpenResourceTestStep` on the **raw string API** deliberately: it pins both halves — same key ⇒ binds to the ancestor's declared slot, and no declaring ancestor ⇒ Self.

**JVM-only test-graph trap** (OpenResourceTestStep.kt:17-20 KDoc): an inline test archetype whose `meta` binds `ResourceClosePolicy` drags the JS-only `SelectValuesEditor`/`AttributeEditorManager` reference into the JVM-only test graph, which fails to resolve — that is why `OpenResourceTestStep` takes `closePolicy` as a plain String parsed in Kotlin. Any new typed-provider **test fixture** step must do the same (plain-string closePolicy, no `ContextProvider` mix-in with meta-declared policy) — `TestSutContext` itself is safe (pure Context data object, no meta). The real `ContextProvider` mix-in is only exercised through the full notation graph (kzen-auto-test selfTest / dev instance).

## 3. Static validation

`LogicContextAnalysis` (kzen-auto-common, pure `GraphNotation`):
- `analyze(graphNotation, documentPath): Map<ObjectPath, ContextIssue>` — linear step walk over document C tracking an `available` set seeded from C's `documentRequires`; per step: unsatisfied `stepRequires` → warning; then add `stepProvides` and drop `stepReleases`. Conditional branches resolve **in the direction that suppresses warnings**, since these are advisory: a `provides` inside an If/loop branch counts as available afterwards, and a `releases` inside one does **not** remove availability. Recursed through branches via `ScriptConventions.stepBranchAttributeNames` (exact name confirmed, ScriptConventions.kt:93-121), cycle-guarded. A step in C that provides X directly is unambiguous: with no slot anywhere it binds to C itself (Self fallback = today's `auto`), so it is available for the rest of C either way.
- **[review] The cross-document case is where the earlier draft was unsound.** It added a hosted document's `escapingProvides` (provides minus *its own* slots) to the caller's `available` unconditionally — but §1's runtime rule binds an unslotted provide to **Self**, i.e. to the hosted document's own node, where it dies at that document's settle. So for caller C hosting H with neither declaring a slot, the analysis said "available" and the run said "disposed": clean validation, failure at run time — in exactly the forgotten-slot case this migration is most likely to produce. Corrected rule at a RunStep (hosted document read from its `instructions` attribute — `ScriptConventions.instructionsAttributeName`, `runStepObjectName` at ScriptConventions.kt:24), for each context X that H provides and H's own slots do not own:
  - **[final]** the providing step's `closePolicy` is `manual` → the engine's Manual hand-up (`putIfAbsent` at
    RunEngine.kt:1041) walks the registration to the caller at H's settle, so it escapes *without* any slot —
    exactly FormulaError's browser (§2 b: "no slot needed"). Add to `available`. No warning. The policy is a
    notated step attribute, read statically via `firstAttribute` (inheritance supplies the `auto` default); if
    several steps in H provide X, treat X as escaping when *any* of them is `manual`. Without this branch the
    analysis emits a factually wrong "disposed when ‹H› finishes" on FormulaError's provider RunStep plus a
    knock-on hosted-requires warning on the next one — Manual hand-up is the *second* runtime escape mechanism,
    and the analysis must model both for the same reason it models the Self fallback (see the escaping-provides
    rationale in §Key decisions).
  - C declares a slot for X → it binds in C. Add to `available`. No warning.
  - else C's `documentRequires` contains X → the author has asserted an outer owner (which the local analysis cannot see, and which is the legitimate escape hatch). Already in `available` from the seed. No warning.
  - else → **warn on the RunStep**: *"‹H› provides BrowserContext but no enclosing slot owns it — it is disposed when ‹H› finishes. Declare a BrowserContext slot on this document, or on a caller plus a `requires` here."* Do **not** add X to `available`.

  This is decidable purely from C's own notation plus H's declarations, so it works when C is the document open in the editor and no caller is known. It is also the single most valuable diagnostic the feature adds: it catches the migration mistake, not just the authoring mistake.

  **[final] The same RunStep pass also checks the hosted side's needs**: warn for each of H's `documentRequires` not in `available` at that point. This is the "RunStep hosted-requires" case the §6 test list already names and the Session B zero-warnings criterion depends on — previously implied by both, stated by neither. It is also what actually ambers when a caller's slot is deleted (see the corrected acceptance wording in §7): the requiring sub-script's *own* steps stay clean, because its `context.requires` seeds its local analysis.
- Also flag **dangling Context references** (a `provides:` / `requires:` / `releases:` / `context.slots` entry that resolves to nothing) and **duplicate `key:` across Context objects graph-wide** — see §2's note on `key` being a global namespace; per-document duplicate detection would miss the plugin-aliases-first-party case, which is the one worth catching.
- Surface: `StepValidation` (kzen-auto-common `objects\document\logic\StepValidation.kt:19-70`) gains `warningMessage: String? = null` (wire key `"warning"`). The codec is **manual ExecutionValue encoding** (`asExecutionValue` 62-69 / `ofMapExecutionValue` 28-57) and the existing keys decode **strictly** (throw when absent, lines 30/44) — the new key must use a nullable lookup (`map[warningKey]` → absent ⇒ null), not copy the existing pattern. `StepValidation` is shared with the Job flavour (`JobValidation`/`JobValidator`/`WorkerDisplayDefault`) — the field simply stays null there; no Job-side change.
- `ScriptValidator.validate` (kzen-auto-jvm `objects\script\ScriptValidator.kt`, companion `validate` at 41-102) merges analysis output. **[review] Merge specifics, previously left as "merges":** the analysis reads notation only — it does not depend on inferred types — so run it **after** the type fixpoint *and* after the survivor loop (98), immediately before `return ScriptValidation(stepValidationBuffer)` (102), mutating the same buffer. Two cases, both real: a step that already has an entry merges via `copy(warningMessage = …)`; a step with **no** entry (the fixpoint's `putIfAbsent` survivors are covered, but a step whose `definition()` returned null at 121 gets `continue`d and never lands in the buffer) needs a fresh `StepValidation(null, null, warning)`. Write it as `buffer[path] = (buffer[path] ?: StepValidation(null, null)).copy(warningMessage = …)` and neither case can be missed.
- **Cache: confirmed sound — and record *why*, so it is not optimized away later.** `ScriptValidationCache` is Caffeine-keyed on `LogicValidationDigest.documentClosureKey`, and that key does cover inert notation, by two mechanisms that must both hold: (i) `GraphDefinition.transitiveDigest(documentPath)` widens the closure to *every notated member* and digests `coalesce[location]` — the whole `ObjectNotation`, defined attributes and inert ones alike — so editing a document's `context:` invalidates it; (ii) `LinkedLogicDocuments.transitiveDigest` folds in every linked logic document's closure (`LogicCallGraph.transitiveCallees`), so editing a *callee's* `context.requires` invalidates the *caller's* entry — which the RunStep rule above depends on. Context archetypes themselves are classpath notation, static per process. If anyone ever narrows `notationDigest` to defined members only, this feature's caching breaks silently.
- JS stores pick the field up over the existing wire (`ScriptValidationStore` → `ScriptValidation.ofExecutionValue` → per-step `StepValidation.ofMapExecutionValue`).
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

**[review] Resolution rule when `context == null`: the step's sole *declared* context — `provides` ∪ `requires` ∪ `releases`** — with a uniform-failure `error(...)` when the step declares zero, or more than one (pass the location explicitly then). The `releases` term is what lets the two closer steps resolve argument-free (§2). The `provides` term is the correction to the earlier draft, which said "sole **required** descriptor" — self-contradictory, because `BrowserOpenStep` declares zero `requires` (it is the provider) yet the step-changes paragraph below has it call `contextValueOrNull()` + `releaseContext()` on its replace-existing path, which would hit the zero-descriptor error. Nor can that be patched by giving `BrowserOpenStep` a `requires: [BrowserContext]`: the spine gate would then fail the step *before* it ever opens a browser. Widening to all three declaration kinds resolves it cleanly and keeps every first-party call site argument-free. `context<T>()` resolves the same way, filtered to the unique declared descriptor whose `valueClass` is `T` (same zero/ambiguous failure) — `BrowserGetSutStep`, which declares two, is what exercises it. `provideContext` still needs no descriptor argument: it resolves the current step's own `provides`.

`ScriptRunContext`:
- At run start (`ScriptLogic.run`, kzen-auto-jvm `exec\script\ScriptLogic.kt:54` — it already holds `structure.graphNotation` and `structure.scriptLocation`, so no plumbing): `documentSlots` → `execution.declareSlot(descriptor.key)` for each, before the step walk. Every document's own Logic does this, root and hosted alike; a migrate rebuild re-runs `Logic.run`, so re-declaration is free.
- **[review] Add `currentStepLocation` alongside `currentStableId`.** `ScriptRunContext` tracks only the stable id today (declaration at 126, set at 315, restored in the `finally` at 355) — but `provideContext` / `contextValue()` / `context<T>()` resolve the *current step's* `provides`/`requires` from notation, which needs its `ObjectLocation`. `runSteps` already has `stepLocation` in hand, so this is a three-line change: declare it beside 126, save-and-set it beside 315, restore it in the same `finally` as 355 (a nested branch must not clobber it, exactly as for the stable id). Small, but omitting it stalls the session at the first typed call.
- In `runSteps` (line 279; the `recoverable` block is at 322-336, `step.run(this)` at 335), **inside** `recoverable`, before `step.run`: for each cached required descriptor, `if (!execution.hasResourceInFamily(required.key)) error("Requires ${required.title}: not provided")` — free uniform framing (Error trace, pause-on-error park, re-check on resume). The gate fires only on declared `requires`, so the closer steps (§2) are untouched by it; and it is family-level, so a qualifier mismatch still surfaces at read (§1).
- `provideContext`: resolve current step's `provides` → key (+`:qualifier`) → `execution.resource(key, closePolicy.toEngine(), value, closer)`. The existing `private fun ResourceClosePolicy.toEngine(): Pair<ResourceScope, ClosePolicy>` at ScriptRunContext.kt:660-668 is deleted, replaced by the enum's own 3-value `toEngine(): ClosePolicy` (§1); `openResource` override at 262-265 drops its `scope` argument.

Step changes: `BrowserOpenStep` (replace-existing at BrowserOpenStep.kt:29-33, registration at 52) → `contextValueOrNull()`+`releaseContext()` for replace-existing (resolving off its own `provides`, per the corrected rule above), then `provideContext(driver, closePolicy) { quitQuietly }`; receivers → `execution.context<RemoteWebDriver>()` (the ad-hoc `?: error("Browser is not open")` pattern removed at its 5 sites: BrowserTargetStep.kt:38-39 — covers all 5 subclasses including the Kotlin-only `BrowserFocusStep` — BrowserGetStep.kt:29-30, BrowserEnterStep.kt:28-29, BrowserEscapeStep.kt:28-29, and BrowserGetSutStep.kt:44-45 in kzen-auto-test); SUT steps use `qualifier = name` (StartKzenAutoStep.kt:66 registration, BrowserGetSutStep.kt:44-47 lookup, StopKzenAutoStep.kt:23-27 release — note Start also maintains the process-global `KzenAutoSubprocessRegistry` map, which is orthogonal and stays). `WebDriverSupport.resourceKey` retires from the open path.

**Closers stay tolerant** (§2's `releases:` category): `BrowserCloseStep` → `contextValueOrNull()` → quit if non-null → `releaseContext()`; `StopKzenAutoStep` keeps its `if (!stopped) { traceDetail("nothing to stop"); return null }` branch verbatim and just swaps `releaseResource(resourceKey(name))` for `releaseContext(qualifier = name)`. Both resolve argument-free off their `releases:` declaration — which is why that marker exists rather than leaving closers with no declared context and hence nothing to infer from. Nothing about their observable behaviour changes: that is the point.

## 5. UI (kzen-auto-js)

1. **Document context panel** (`ScriptController.kt` — parameters/results render via `renderSignature` at 388-402): slot + requires chips (icon/title from `ContextDescriptor`, computed client-side from notation); add/remove picker listing all `is: Context` objects (the client holds the whole notation graph, jvm archetype bundles included, so the scan is a client-side `inheritanceChain` filter). **[review] Model the write path on `ResultSignatureEditor`** — the sibling `renderSignature` already renders, and the closest analogue: it writes with `UpsertAttributeCommand` (lines 146 and 166) over a whole map attribute. Upserting the entire `context` map per edit is both simpler than list-item commands and necessary, because `context` does not exist on a document's `main` object until the first edit — the value is inherited from the `Script` archetype, so a list-insert against `context.slots` has no local attribute to insert into. "Writes via existing structural commands on the plain list attributes" understated this. **Placement constraint**: the document-level error `div` at ScriptController.kt:343-348 is deliberately ALWAYS emitted to keep `MultiStepDisplay`'s child index stable — the panel must render inside `renderSignature`'s output or as another always-emitted div, never as a new conditional sibling (a conditional sibling remounts the step subtree).
2. **Step badges** (`step\header\StepHeader.kt` / `ScriptStepDisplayDefault.kt`): "provides ⟨icon⟩" badge (closePolicy in tooltip; tooltip states "bound to: this document / a calling document" from whether own document declares the slot), per-requires badges, and a distinct "releases ⟨icon⟩" badge for the closers (§2) — visually a third state, never ambered. Additive to the existing right-cluster mechanism — `StepHeader.renderRightCluster()` (248-353) already hosts the validation-error icon-in-Tooltip (260-280) and Skipped/Partial/type `Chip`s; new props go in `StepHeaderProps` (31-58).
3. **Amber unsatisfied-requires** warning from `StepValidation.warningMessage` via `ScriptValidationStore` (distinct from red definition-error tint). Mechanics: new colour constant beside `validationErrorColour = Color("#d84315")` (ScriptStepDisplayDefault.kt:72); widen `statusBorderColor(...)` (89-102 — run status wins, then error, then warning, then white) and its 4 call sites: ScriptStepDisplayDefault.kt:289, DoWhileStepDisplay.kt:86, ForEachStepDisplay.kt:165, IfStepDisplay.kt:374.
4. closePolicy dropdown: unchanged code, 3 options from the updated `values:` map.

## 6. Testing & docs

- **kzen-lib** `RunEngineTest.kt:1698-2063` rewrite (the `//------ tree-scoped resources (ResourceScope)` block: 11 tests from `parentScopedResourceOutlivesItsChildAndDisposesAtParentSettle` at 1716 through `releaseResourceFromDescendantRemovesAncestorScopedRegistration` at 2033; file is 2208 lines): parent-declared slot outlives child; root-declared from depth two; nearest-ancestor-wins; **undeclared key defaults to Self** (pins JobRun-style usage); family matching (slot `"sut"` owns `"sut:a"`/`"sut:b"` independently); KeepOnFailure at failed slot owner; Manual hand-up past slot owner; migration lift/re-adopt with re-declaration; descendant release. `cancelSettlesCancelledAndDisposesResources` (379) is outside the block and should keep passing unchanged.
- **kzen-auto**: `ScriptExtensibilityTest.kt:72-153` + fixtures per §2; new `ScriptContextValidationTest` (unsatisfied / satisfied-by-document-requires / RunStep hosted-requires / dangling reference / duplicate key); new runtime test (uniform spine failure + pause-on-error resume-after-fix; typed provide/consume across RunStep; qualified SutContext round trip); FizzBuzz selfTest end-to-end.
- **[review] Five tests that pin the corrections specifically** (four from the design review, the fifth **[final]**) — each one is a case an earlier draft of this plan got wrong, so none of them is optional:
  - **Unslotted cross-document provide warns and is NOT available** (§3): caller hosts a sub-document that provides BrowserContext; neither declares a slot; assert a warning on the RunStep *and* that a later browser step in the caller also warns. The inverse fixture (caller declares the slot) asserts silence. This is the pair that pins the soundness fix.
  - **`contextValueOrNull` resolves off `provides`** (§4): `BrowserOpenStep`'s replace-existing path, argument-free, on a step that declares zero `requires`. Would have thrown under the old "sole required descriptor" rule.
  - **Closers stay tolerant** (§2/§4): run `StopKzenAutoStep` with no SUT started and assert the step **succeeds** with the `"nothing to stop"` trace — not an Error trace, not a pause-on-error park. Same for `BrowserCloseStep` with no browser.
  - **`releases:` removes availability** (§2/§3): a browser step placed after a Close step warns. New diagnostic, so it has no prior behaviour to regress against — it needs a test or it does not exist.
  - **[final] Manual provide escapes without a slot** (§3): the FormulaError shape — a hosted document provides BrowserContext with `closePolicy: manual`, neither it nor the caller declares a slot; assert **no** warning on the provider's RunStep and that BrowserContext is in `available` for the caller's later steps. Without the §3 manual branch this fixture shows two false warnings.
- **Docs**: `kzen-lib\docs\logic-spec.md` `## 6. Resources` (lines 459-503) rewritten around slots — and the rewrite must land four things the old §6 either states wrongly or omits: (i) `auto` means *the owning slot's* settle, not "this document"; (ii) the flat `parent`/`run` value list is gone; (iii) a Context `key` is a **global namespace** (§2's aliasing note); (iv) enforcement is **family-granular**, so a qualifier mismatch surfaces at read, not at the gate (§1). The confinement material is a bullet inside `## 2. Execution model` ("Heterogeneous composition", 99-108, with the §6 exception noted at 106-108) — update that cross-ref too. Also `ResourceClosePolicy`'s own KDoc (§1). Both `architecture.md` files (Context type objects beside the `ResourceClosePolicy` precedent; the inert-attribute mechanism — `AttributeObjectDefiner` iterating metadata only — stated in its own right rather than by analogy to `rerun`/`scope`/`group`, which are a *different* layer, see §2); `js-architecture.md` for badges/panel; AGENTS.md files if they enumerate the resource API.

## 7. Sequencing (composite-build aware)

1. **Phase 1 — engine (kzen-lib)**: Execution API, RunEngine slots, delete ResourceScope, trim ResourceClosePolicy, RunEngineTest, logic-spec §6. Then `cd ../kzen-lib && ./gradlew publishToMavenLocal` (all 4 subprojects) **before any kzen-auto compile**.
2. **Phase 2 — notation + runtime (kzen-auto)**: Context/ContextProvider archetypes, conventions readers, StepExecution API, ScriptRunContext, browser + SUT steps, yaml migrations, fixtures.
3. **Phase 3 — validation**: LogicContextAnalysis, StepValidation.warningMessage, ScriptValidator merge, tests.
4. **Phase 4 — UI (kzen-auto-js)**: panel, badges, amber warnings.
5. **Phase 5 — docs + FizzBuzz selfTest** end-to-end.

**[review] Two corrections to the phase story, and a session split.**

**Phase 1 alone leaves the umbrella red — say so rather than implying otherwise.** "Phase 1 is independently green in kzen-lib" is true of kzen-lib and misleading about the tree: composite substitution routes kzen-auto-common's `commonMain` at the included kzen-lib project, so the moment `ResourceScope` is deleted, `ScriptRunContext.toEngine()` (660-668) and `openResource` (262-265) stop compiling. Phases 1 and 2 are therefore **one commit**, not two. (The mavenLocal publish between them is still mandatory — kzen-auto's `jvmMain`/`jsMain` reach kzen-lib through variant-suffix coords, which resolve from mavenLocal, not the composite. No version bump: same-version `publishToMavenLocal` overwrites, and a coordinated-release-train bump is a separate explicit request per CC-14.)

**Only phase 2 is forced to be atomic with the enum shrink; phases 3 and 4 are additive.** Phase 3 adds a nullable wire field and a new analysis class; phase 4 adds UI. Neither breaks anything if it lands later. "Phases 2–4 land as one atomic change" over-constrained the work into one impossible session.

**Session split** — every other plan in `docs/plans/next/` carries one (J3 "L with a split point", J5 "Session A = 1–3, B = 4–8", J7's extractable micro-session); this one needs it more than any of them, spanning an engine API change, an 11-test rewrite in a 2208-line file, two notation bundles, four new runtime members, a cross-document analysis, a wire field, four UI surfaces, ~21 notation documents and four doc files.

| Session | Scope | Exit criteria |
|---|---|---|
| **A** | Phases 1 + 2, one commit — including the kzen-lib doc surfaces (logic-spec §6 + §2 cross-ref, `ResourceClosePolicy` KDoc), since they ship with the enum, and the §2 **(a) + (b) + (d)** notation migrations — **[final]** (b) must ride with (a), see §2(b) | `cd ../kzen-lib && ./gradlew build` green (rewritten `RunEngineTest` block incl. the undeclared-key-to-Self test); `publishToMavenLocal` for all 4 subprojects; `cd ../kzen-auto && ./gradlew build` green; `ScriptExtensibilityTest` green against migrated fixtures (§2 a/b/d), the 4 slot owners declaring `context.slots`; the closer-tolerance and `contextValueOrNull`-off-`provides` tests from §6 pass |
| **B** | Phase 3 + the §2 (c) requires sweep | `ScriptContextValidationTest` green incl. both unslotted-provide fixtures, the `releases:` case and the manual-escape case; all 17 self-test documents carry their declarations (15 `context.requires`, 2 providers); opening FizzBuzz **and FormulaError** in the editor shows **zero** unexpected warnings (the `main\Script.yaml` harness warning is expected and documented) |
| **C** | Phases 4 + 5 | `:kzen-auto-js:compileKotlinJs` green; panel + provides/requires/releases badges + amber render on an own dev instance on a spare port (never the user's 8080); `:kzen-auto-test:selfTest` FizzBuzz end-to-end green; kzen-auto `architecture.md` + `js-architecture.md` and any AGENTS.md enumerating the resource API updated |

**Acceptance for the whole item** — the §"What a user sees" paragraph, demonstrable end to end: open FizzBuzz, see the root's slot chips and each sub-script's requires chips; delete a slot declaration and watch the **caller's RunSteps** amber — the provider's RunStep reporting the unowned provide, the consumers' RunSteps their unsatisfied hosted requires (**[final]** corrected from "the sub-script's browser steps amber": a sub-script declaring `context.requires` seeds its own local analysis from it, so its inner steps never amber in their own document view — the caller's RunStep is where the breakage surfaces, per §3); run it and see a requires-less document fail its first browser step with the uniform message instead of `error("Browser is not open")`.

Per-phase verification commands: `cd ../kzen-lib && ./gradlew build`; `cd ../kzen-auto && ./gradlew build` (+ `:kzen-auto-js:compileKotlinJs` as the fast JS gate).

## As-built (2026-07-29)

**Superseded in part by CTX2 (`context-moved-ownership.md`).** The nearest-ancestor-slot binding
this plan delivered is replaced by an explicit export chain: a document declares `context.exports`
to offer a resource upward, an un-exported provide is private to its opening frame, and
`context.slots` is retired. Everything else here — the Context archetype, the typed step API,
`closePolicy` as a pure disposal rule, the declaration badges — stands.

All three sessions executed. `cd ../kzen-lib && ./gradlew build` green (rewritten `RunEngineTest` slot block,
14 tests), `publishToMavenLocal` for all four subprojects, `cd ../kzen-auto && ./gradlew build` green
(12 `ScriptContextRuntimeTest` + 9 `ScriptContextValidationTest` + `ScriptExtensibilityTest` against the
migrated fixtures + `SelfTestContextDeclarationsTest`), `:kzen-auto-js:compileKotlinJs` green.

**`:kzen-auto-test:selfTest` — `formulaErrorIsDetected` PASSES, `fizzBuzz` fails on a PRE-EXISTING defect
unrelated to this change.** The passing half is the more informative one: it exercises the whole feature end
to end through a real browser — a SUT provided into the root's `SutContext` slot, a browser provided
`manual` with no slot (the §3 Manual-escape path), `BrowserGetSutStep` reading both typed contexts, and both
closers. `fizzBuzz` gets as far as Build Loop → Insert Range, so Open Kzen and Browser plus five Build Item
sub-scripts plus Create Loop Script all ran green — i.e. the browser and SUT survived many sub-script
boundaries under the new slot ownership, which is exactly what the migration had to deliver.

It then fails at `Insert Range`'s `Click [add] target in script`, whose `Visual` target
(`main/Actions/Plus Circle/~main.yaml`) matches **more than one** element. Diagnosis: that target carries
three capture PNGs, and the stale `20260525_172137_719.png` matches the add-circle-outline buttons of
`LogicSignatureEditor` (Parameters) and `ResultSignatureEditor` (Result) at score 1.0 — two components this
change does not touch — as well as the intended in-script button (`20260614_235714_194.png`). Verified by
disabling the new `ContextSignatureEditor` float and re-running: the match list drops from four to three and
the step still fails. So the target was already ambiguous; the new float adds a third instance of the same
glyph but is not the cause. **Fixing it means re-capturing or scoping the user's own visual-target asset —
out of scope here, and deliberately not taken unilaterally.**

Deviations from the plan as written, beyond the two notation corrections folded into §2 above:

- **`ContextConventions` / `LogicContextConventions` split.** §2 named one reader; it landed as two — a
  flavour-neutral `ContextConventions` (reads an `is: Context` object as a `ContextDescriptor`, resolves a
  reference, enumerates the graph's Contexts for the picker) plus `LogicContextConventions` (the
  document- and step-level declarations). The seam is real: the picker and the analysis's duplicate-key
  check need the former without the latter.
- **`contextDescriptor<T>()` / `contextOrNull<T>()` beside `context<T>()`.** §4 listed only `context<T>()`.
  `BrowserGetSutStep` needs a *nullable* typed read for the SUT (it keeps its own "is there a preceding
  Start SUT step with this name?" diagnostic, which the family-level gate cannot produce), so the reified
  descriptor lookup was factored out and a nullable form added over it.
- **`ScriptTree.read` gained a `GraphNotation` overload.** The analysis is notation-only by design; the tree
  walk was already notation-only in fact, so the overload just states it rather than duplicating the walk.
- **A `SelfTestContextDeclarationsTest` in kzen-auto-test.** §7's Session B exit criterion ("opening FizzBuzz
  and FormulaError shows zero unexpected warnings") had no automated form. It has one now: a plain unit test
  that runs the analysis over every `main/` document and asserts the warning set is exactly
  `{main/Script.yaml}` — the harness warning §2(c) predicted and documented. Declarations are inert notation,
  so nothing else in the build would have noticed them drifting.
- **§2(c) covers 15 documents, not 13 + 2.** The sweep as specified named the leaves; the two intermediate
  aggregators (`FizzBuzz/Item/Build Item.yaml`, `FizzBuzz/Loop/Build Loop.yaml`) also need
  `context.requires`, because §3's hosted-requires check fires at *their* RunSteps. Pure-RunStep documents
  are not exempt from the sweep — a document that hosts only requiring documents requires too.
- **UI placement.** §5's context panel landed as `ContextSignatureEditor`, an absolute float in the stage's
  top-right stack beside the Parameters and Result editors, emitted unconditionally from `renderSignature` —
  satisfying the child-index-stability constraint with zero flow footprint. Its write path deliberately edits
  the *raw* reference strings rather than round-tripping through resolved descriptors, so a dangling entry
  (the thing §3's dangling-reference warning asks the user to fix) is not silently deleted by an unrelated
  edit.
- **Context badges are wired for leaf steps only.** `If` / `ForEach` / `DoWhile` displays pass the amber
  warning (so their bar and header icon respond) but not the declaration props; no first-party control step
  declares a Context. Lifting the derivation into `ScriptStepDisplayBase` is the fix if one ever does.

## Key decisions & rationale (made during design)

- **Slot declaration by the Logic at run start**, not via `host(...)` params: flavour-neutral, no layering inversion (hosting side needn't read the child's notation), migration re-declaration free.
- **Undeclared key → Self**: confinement-safe default preserving all existing undeclared usage; the old parent/run reach-up *without the ancestor's consent* is exactly what the feature removes.
- **ClosePolicy stays per-registration**: opener owns the closer and its semantics; per-slot defaults can layer on later.
- **Dynamic keys as `family:qualifier`**: makes the SUT pair fully typed instead of leaving the second first-party pair invisible to the feature; matches its existing key format.
- **Inert notation data over meta-declared**: no definer → dangling references degrade to validation messages, not definition failures (sidesteps the notation-wiring traps at kzen-auto `docs\architecture.md:123-128` — a `by:` in `meta` needs a sibling `is:` or it silently falls back to `StructuralAttributeDefiner`, and `firstAttribute(AttributeName)` throws when absent).
- **[review] Inert also means renames are not tracked — accepted, but state it.** `NotationReducerRefactor.locateReferences` builds its rewrite set from `objectDefinition.attributeReferencesIncludingWeak()` plus a special case for `is:`. An attribute with no metadata produces no attribute definition and therefore no reference, so **renaming a Context object leaves every `provides:` / `requires:` / `releases:` / `context.slots` entry dangling, silently.** For first-party archetypes in classpath notation that is inert trivia; for a plugin author's own Context objects in a project it is a real papercut, mitigated only by §3's dangling-reference warning.
  The alternative was weighed and rejected: `by: Nominal` — the same weak-reference mechanism RunStep's `instructions` uses (see `LinkedLogicDocuments`' KDoc on why the callee must not join the caller's instantiation) — *is* included in `attributeReferencesIncludingWeak`, so it would get rename-rewriting and reference validation for free, and it would not force constructor changes (`ScriptStep` meta-declares `icon`/`title`/`description`/`display` while no step class takes them as constructor params, so the creator tolerates meta-declared attributes the class ignores). It was rejected because a dangling `Nominal` fails the attribute definition, which fails the object, which turns the step **red and unrunnable** — trading a silent dangle for a hard break, in a feature whose whole enforcement stance is "advisory in the editor, strict at execution". Revisit only if untracked renames actually bite.
- **[review] `releases:` as a third marker rather than a special case on `requires`**: it is what makes closers resolvable argument-free, keeps them out of the runtime gate and the amber path, and buys the "browser step after a Close step" diagnostic — three jobs one flag does cleanly and a `requires`-with-exemptions would not.
- **[review] Escaping provides are slot-gated**: the static model must agree with §1's Self fallback or it certifies the exact configuration that fails at run time. Gating on the caller's own declared slot keeps the rule decidable from one document's notation, which is all the editor has.

## As-built addendum (2026-07-29, second pass): inert-by-omission superseded by `by: Nominal`

The "inert notation data over meta-declared" decision above was **reversed** the same day, on review
("that seems like a very convoluted and error prone design"). The five declaration attributes are now
declared in their archetypes' `meta:` with **`by: Nominal`** (`WeakAttributeDefiner`) — the standard kzen
mechanism for object-naming data attributes (`Custom.exports`, `RunStep.instructions`,
`IfStepCommander.branchArchetype`):

- `ScriptStep` meta-declares `requires` (`is: List, of: ObjectLocation`) and `releases`
  (`is: ObjectLocation, nullable: true`) with empty body defaults; `ContextProvider` meta-declares
  `provides` likewise; `Script` meta-declares `context`
  (`is: Map, of: [String, {is: List, of: ObjectLocation}]`); `Context` meta-declares its own
  `key`/`title`/`icon`/`description` as `String` (closing the latent hazard of a `key:` value colliding
  with an object name).
- The list-shape hack is gone: `provides` / `releases` are back to scalars (`provides: BrowserContext`),
  matching their single-valued semantics; `requires` / `context.slots` / `context.requires` stay lists.
  `LogicContextConventions.referenceList` still reads either shape.
- The rejection rationale recorded above was **factually wrong**: a dangling `Nominal` does *not* fail the
  attribute definition. `WeakAttributeDefiner` emits the `ReferenceAttributeDefinition(weak = true)`
  without resolving it, weak edges are invisible to `transitiveSuccessful`, and the creation-time hard
  throw (`DefinitionAttributeCreator`) fires only for constructor parameters — which none of these are.
  The only genuine definition-time failure is an *empty* reference on a non-nullable type, addressed with
  `nullable: true` on `provides`/`releases`. So `by: Nominal` delivers everything inert-by-omission did,
  **plus** rename propagation (`ContextRenameTest`) and reference validation, with none of the hazards.
- Root cause hardened in kzen-lib: `NotationMetadataReader.inferMetadata` now returns null when the
  scalar's target is `abstract: true` (`MetadataInferenceAbstractTargetTest`) — an inferred hard reference
  to an abstract object could only ever get the host pruned, so the entire trap class behind the original
  `Not a ScriptStep` failure is structurally gone.
- The step-body editor skips the now-meta-declared attributes via
  `LogicContextConventions.isContextDeclaration` (`ScriptStepDisplayDefault.renderBody`) — they are managed
  by the header badges and `ContextSignatureEditor`.
- Second kzen-lib fix uncovered by `ContextRenameTest`: `NotationReducerRefactor.isReferenced` located
  the rename target in `objectDefinitions` / `failures` only — an `abstract: true` target is in neither,
  so renaming an abstract object (every Context; also `IfBranch`-style archetypes) silently rewrote
  nothing. It now falls back to the notation coalesce (`RenameAbstractTargetTest` in kzen-lib-jvm).
- Known scope edge: the rename scan rewrites references held by *defined* objects only, so an
  `abstract: true` archetype's own declaration (e.g. `RequireContextTestStep.requires`) is not rewritten —
  irrelevant for classpath notation (never renamed), noted in `ContextRenameTest`'s KDoc.
