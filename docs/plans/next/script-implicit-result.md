# SIR — Script implicit result (`ResultStep` always ends the Script)

> ✅ **LANDED 2026-08-06** — all three sessions, each gated on a green `cd ../kzen-auto && ./gradlew build`.
> See **§10 As-built** for the deviations, the findings, what the smoke actually covered, and the one
> open presentational question (`Script-1.yaml`'s fall-through Result value).
>
> **Standalone plan** (design + elaboration in one document, like `context-and-resource.md` — the
> "Constituent plan" column reads `—`, so on landing **archive it as an as-built record, do not
> delete**). Not a phase of any constituent plan: it is a language-semantics change to the Script
> flavour, requested directly by the user on **2026-08-05**.
>
> Anchors captured 2026-08-05 against kzen-auto `23d81b6b`. Re-verify before editing (standing rule
> in `README.md`).
>
> Executor: Opus-class. **Three sessions**, boundaries are hard build gates:
> **A** = semantics (shared analysis + `ResultStep` + runtime + notation + docs), ends with kzen-auto
> green; **B** = validation (the new errors/warnings + the two documents they newly flag), ends green;
> **C** = the client Result chip + the manual smoke of all three.
>
> ⚠ **kzen-auto has uncommitted user WIP at plan time**: `notation/main/Script.yaml` (modified) and
> `notation/main/Contexts.yaml` (untracked). Neither declares a `results:` signature, so both are
> unaffected — **do not touch them** (AGENTS.md § File safety). If either has grown a `results:` block
> by execution time, surface it rather than editing it.

---

## 1. Why (design rationale — this document is the only record)

Today a Script's result comes **only** from a `ResultStep`, and `ResultStep` carries
`then: keepRunning | endScript` (default `keepRunning`, last-Result-wins, Visual-Basic style).
`ScriptLogic.run` discards the root step sequence's value outright, and `docs/architecture.md` states
the contract flatly: *"there is no last-step fallback, so a Script consumed via `RunStep` /
`ForEachStep` returns void until a ResultStep is added."*

Two problems the user is closing:

- **A Script is not expression-shaped.** Every other value-producing construct in the flavour takes its
  terminal step's value — `IfStep` returns its taken branch's last step, `ForEachStep` collects its
  body's last step (`ForEachStep.bodyTerminalType`, and `ScriptRunContext.runSteps` returns `last`).
  The Script document alone required ceremony to produce the value it already computed.
- **`then` made "does this step return?" a per-step setting** rather than a language rule. A `Result`
  that does not end the script is a *write to a result slot*, not a `return`; keeping both behaviours
  behind a dropdown made the Script's control flow unreadable from its step list.

After this change: `ResultStep` is `return`, and a Script that just ends yields its last step's value.

### 1.1 Rejected: exempting a Script that has a `ResultStep` anywhere

The first draft suppressed the implicit type check whenever *any* `ResultStep` existed in the document
(including nested in a branch or a loop body), on the grounds that it "may set the result at run time",
so the implicit path is a fallback rather than a claim. That would have kept two in-tree documents
green with no edits.

**The user rejected it: "this is not a special case, all Result steps must have a type that matches
what is declared in the Script."** The rule is uniform — every value that can become the Script's
result must satisfy the declared type. A `ResultStep` already satisfies it *by construction*
(`ResultStep.definition` compiles its expression with the declared type as the **forced** return type),
so it needs no exemption; the implicit last step is simply held to the same standard.

The suppression also had a real hole: a nested `Result` is a *conditional* early return, so the
fall-through path still reaches the last root step. Exempting it would let a Script whose loop never
matched return a `Unit` (or a wrong-typed) value into a slot declared `Int`, silently.

The only trimming that survives is **reachability**, which is not a type rule: a **root-level**
`ResultStep` ends the Script, so root steps after it never run. They get an unreachable *warning*, and
the implicit result is taken from the last **reachable** root step — which in that case is the Result
step itself, passing trivially. No exemption branch appears anywhere in the code.

---

## 2. Semantics to implement

Root step list = document order, `ScriptConventions.orderedDirectChildLocations` over
`main` / `ScriptConventions.stepsAttributePath`.

| Situation | Outcome |
|---|---|
| Root steps **after** a root-level `ResultStep` | Unreachable — **warning** each (amber, never gates Run) |
| Script declares no `main` result | No findings; runtime returns `TupleValue.empty`, last value discarded |
| Declared result, **no root steps** | **Error** on the document's `main` object path |
| Declared result, last reachable root step is `Unit` | **Error** on that step — "produces no value" |
| Declared result, last reachable root step not assignable | **Error** on that step — type mismatch |
| Declared result, last reachable root step **is** a `ResultStep` | Passes — its type *is* the declared type; no special case |

**Runtime** (`ScriptLogic.run`): `context.result() ?: (declaresMain ? TupleValue.ofMain(lastStepValue) : TupleValue.empty)`.
A `ResultStep` that ran anywhere — including nested — still wins, because it sets `result()` before
raising `EndScript`.

**Copy** (mirrors `ResultSinkWorker.payloadFlow`, the Job-side analogue):

```
unreachable  Never runs — the Result step above ends the Script.
mismatch     Result declares ${declared.toSimple()} but this step produces ${actual.toSimple()}
no value     Result declares ${declared.toSimple()} but this step produces no value — end with a step
             that produces one, or add a Result step.
no steps     Result declares ${declared.toSimple()} but this Script has no steps.
```

The Unit case is a strict subset of "not assignable", but gets its own branch: `Unit → Any` is *legal*
Kotlin, and "Unit is not assignable to Int" reads as noise to someone who simply ended on a `Display`.

---

## 3. Shared analysis — one rule, two consumers

The reachability + implicit-step derivation is shared so the server validator and the client chip
cannot drift. Pure notation — no definition, no instantiation — same discipline as `ScriptTree.read`
and `LogicContextAnalysis.analyze`, and it sits beside them.

**New** `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/script/model/ScriptResultAnalysis.kt`:

```kotlin
data class ScriptResultAnalysis(
    val rootSteps: List<ObjectLocation>,
    val unreachableRootSteps: List<ObjectLocation>,
    val implicitResultStep: ObjectLocation?,   // last reachable root step when it is NOT a ResultStep
    val declaresMainResult: Boolean
) {
    companion object {
        fun analyze(graphNotation: GraphNotation, documentPath: DocumentPath): ScriptResultAnalysis {
            val mainLocation = documentPath.toObjectLocation(NotationConventions.mainObjectPath)

            val rootSteps = ScriptConventions.orderedDirectChildLocations(
                graphNotation,
                AttributeLocation(mainLocation, ScriptConventions.stepsAttributePath))

            val declaresMainResult = ResultSignatureDefiner
                .parse(graphNotation.firstAttribute(mainLocation, ScriptConventions.resultsAttributePath))
                .find(TupleComponentName.main) != null

            // A root-level Result step ends the Script, so everything after it never runs. Reachability
            // only — NOT a type exemption: the terminal below is type-checked either way (§1.1).
            val endIndex = rootSteps.indexOfFirst { ScriptConventions.isResultStep(graphNotation, it) }
            val reachable = if (endIndex < 0) rootSteps else rootSteps.subList(0, endIndex + 1)
            val unreachable = if (endIndex < 0) listOf() else rootSteps.subList(endIndex + 1, rootSteps.size)

            val terminal = reachable.lastOrNull()
            val implicit = terminal?.takeIf {
                declaresMainResult && ! ScriptConventions.isResultStep(graphNotation, it) }

            return ScriptResultAnalysis(rootSteps, unreachable, implicit, declaresMainResult)
        }
    }
}
```

`ObjectLocation` not `ObjectPath`: `orderedDirectChildLocations` yields locations and
`ScriptValueReferences` needs locations; the validator takes `.objectPath`.

Use the **nullable `AttributePath` overload** of `firstAttribute` — the `AttributeName` overload throws
when absent (AGENTS.md notation-wiring trap), and `results:` is optional.

`ScriptConventions` gains, verbatim the shape of the existing `runStepObjectName` / `isRunStep`
(kzen-auto-common `ScriptConventions.kt` ~line 209 — inheritance-chain membership, so a subtype matches):

```kotlin
val resultStepObjectName = ObjectName("ResultStep")

/** Whether [stepLocation] is a ResultStep — by inheritance chain, so a subtype matches. */
fun isResultStep(graphNotation: GraphNotation, stepLocation: ObjectLocation): Boolean {
    if (stepLocation !in graphNotation.coalesce) {
        return false
    }
    return graphNotation
        .inheritanceChain(stepLocation)
        .any { it.objectPath.name == resultStepObjectName }
}
```

> **Discussion item, do not build.** The fully extensible form is an archetype metadata marker
> (`endsScript: true`) so a third-party terminal step joins declaratively, matching the `rerun` /
> `scope` / `group` branch markers. That is future-proofing with one caller (CC-10), and `isRunStep`
> sets the precedent for the concrete-name form. Raise it if a second caller ever appears.

---

## 4. Session A — semantics (`then` removal + implicit result)

Ends with a Script that returns its last step's value. Nothing validates it yet, so no document starts
erroring — A is independently shippable.

### A.1 kzen-auto-common

1. `…/objects/document/script/ScriptConventions.kt` — add `resultStepObjectName` + `isResultStep` (§3).
2. **New** `…/objects/document/script/model/ScriptResultAnalysis.kt` (§3).
3. **New** `kzen-auto-common/src/commonTest/…/objects/document/script/model/ScriptResultAnalysisTest.kt`
   (CC-13 — pure notation, no server): implicit last step; root Result last (implicit is null, nothing
   unreachable); root Result with two tails (both unreachable, implicit null); **nested Result does not
   exempt** (implicit is still the tail); no `results:` declared (`declaresMainResult` false, implicit
   null); empty step list (all empty, implicit null).

### A.2 `ResultStep` always ends the Script

4. `kzen-auto-jvm/.../server/objects/script/step/eval/ResultStep.kt` — drop the `then` ctor param, the
   `keepRunning` / `endScript` consts, and the `then` guard at the top of `definition()`; make
   `execution.raiseControlSignal(ScriptControlSignal.EndScript)` **unconditional** after `setResult`.
   Rewrite the KDoc: no VB / last-wins language; state that it captures the result and ends the current
   Script document (a hosted sub-Script returns to its caller — a signal never crosses a `host()`
   boundary), and that a Script with no `ResultStep` yields its last step's value.
5. `kzen-auto-jvm/src/main/resources/notation/auto-jvm/script/script-jvm.yaml` (110–134) — delete
   `then: "keepRunning"` and the whole `meta.then` block; rewrite the comment above `ResultStep:`.
6. **Delete** `kzen-auto-js/.../client/objects/document/script/display/view/ResultThenAttributeView.kt`
   **and** its `AttributeView` registration in `notation/auto-js/document/script-js.yaml` (~192–194).
   Both in the same session — a dangling registration kills the client graph at boot and **no JVM test
   catches it** (verified in Session C's smoke).

### A.3 Runtime

7. `kzen-auto-jvm/.../server/exec/script/ScriptLogic.kt` (174–181):

```kotlin
val lastStepValue = context.runSteps(rootStepLocations)
context.consumeRootSignalOrFail()

// A Result step's captured value wins; otherwise the last root step's value IS the result, mirroring
// how a ForEachStep collects its body's terminal value. A Script declaring no `main` result is void,
// so the last step's value is discarded.
return context.result()
    ?: implicitResult(lastStepValue)
```
```kotlin
private fun implicitResult(lastStepValue: Any?): TupleValue =
    when (structure.resultSignature.find(TupleComponentName.main)) {
        null -> TupleValue.empty
        else -> TupleValue.ofMain(lastStepValue)
    }
```
   Rewrite the class KDoc (lines 23–26) — "there is no last-step fallback" is now false.

8. `kzen-auto-jvm/.../server/exec/script/ScriptValueReferences.kt` — **load-bearing, silent-wrong-answer
   risk.** Its KDoc bullet 1 (lines 19–23) justifies excluding the root list *because* `ScriptLogic.run`
   discards it. That justification dies: a trailing root `ForEachStep` would compute `collecting = false`
   (`ForEachStep.run` ~line 112), collect nothing, and return **`[]`** as the Script's result.
   Add an `implicitResultStep: ObjectLocation?` parameter and seed it beside the existing
   `analysis.valueReferencedSources()` seed (line 45) — exactly symmetric with the nested-branch terminal
   the `walk` already adds at line 62. Null when the Script is void or ends in a `ResultStep`, so the
   optimization is kept everywhere it is still sound. Rewrite bullet 1.

9. `kzen-auto-jvm/.../server/exec/script/ScriptLogicCompiler.kt` — compute
   `ScriptResultAnalysis.analyze(graphNotation, documentPath)` once and pass `implicitResultStep` into
   `ScriptValueReferences.analyze` (line 58). *(The `ScriptValidator.validate` compiler argument lands in
   Session B — do not add it here.)*

### A.4 Notation carrying `then:` (3 files — the attribute ceases to exist)

10. `kzen-auto-jvm/src/test/resources/notation/test/script/control/script-control-endscript-test.yaml:14`
    and `…/script-control-endscript-child-test.yaml:14` — drop the `then:` line and rewrite the leading
    comments (the behaviour is unchanged; only the spelling is).
11. `kzen-auto-jvm/src/main/resources/notation/main/Script-1.yaml:27` — drop `then: endScript`.
    **User-owned sample notation** — stage it deliberately by explicit path. Its *other* problem (a
    valueless last root step) is Session B's, not A's.

### A.5 Fixtures whose semantics invert (root Result no longer last)

12. `test/…/script/result/result-step-last-wins-test.yaml` → rename
    **`result-step-first-ends-test.yaml`**; the **first** Result now ends the Script, so the result is
    `1` and `Second` never runs. Rewrite the header comment.
13. `test/…/script/result/result-step-test.yaml` — roots are `Base | Result | After`; `After` never runs.
    Rewrite the header comment (its unreachable *warning* arrives in Session B).
14. `ScriptControlFlowTest.kt` — class KDoc line ~25 and the test-method KDoc at ~101 both name
    `ResultStep 'then: endScript'`. Rewrite to "a Result step ends the Script".

### A.6 Prose sweep + docs

15. Now-false claims: `ScriptMigrationState.kt` (~line 13), `StepExecution.setResult` KDoc (~line 91),
    `ScriptControlSignal.EndScript` KDoc, `script-jvm.yaml:111`, and
    `test/…/job/signature/job-signature-script-test.yaml:4` (comment only — the fixture itself is fine,
    it ends with a root `ResultStep`).
16. `kzen-auto/docs/architecture.md` — § *Script document model* (~138–141): the result signature is no
    longer `ResultStep`-only; state the implicit-last-step rule and that it mirrors `ForEachStep`'s body
    terminal. § *Script control flow* (~195–206): drop the `then: keepRunning | endScript` sentence; a
    `ResultStep` always raises `EndScript` after capturing the result.

### A.7 New runtime tests

17. Fixtures in `kzen-auto-jvm/src/test/resources/notation/test/script/result/`:
    - `implicit-result-test.yaml` — `results: Int`; `Base` (Formula `21`), `Doubled` (Formula `Base * 2`); no Result step.
    - `implicit-result-loop-test.yaml` — `results: List<Int>`; `Range` (Formula `1..3`), `Loop` (ForEach, body Formula `Item * 2`) as the **last** root step.
    - `implicit-result-void-test.yaml` — no `results:`; trailing Formula `7`.
    - `implicit-result-nested-result-test.yaml` — `results: Int`; `Flag`, `Branch` (If with a Result in one branch), `Tail` (Formula `0`) last.
    - `implicit-result-child-test.yaml` + `implicit-result-parent-test.yaml` — child declares `results: Int` and ends implicitly; parent is `Call` (RunStep) then `Sum` (Formula `Call + 1`).
18. **New** `kzen-auto-jvm/src/test/kotlin/…/server/exec/script/ScriptImplicitResultTest.kt` — mirror
    `ScriptControlFlowTest`'s `runScript` harness:
    - `lastStepValueIsTheResultWhenNoResultStep` → 42
    - `trailingLoopIsCollectedWhenItIsTheImplicitResult` → `[2, 4, 6]` ← **the A.3 step 8 guard**
    - `voidScriptDiscardsTheLastStepValue` → `TupleValue.empty`
    - `nestedResultStepStillWinsOverTheImplicitLastStep`
    - `hostedSubScriptReturnsItsImplicitResult` → 8 (also exercises `RunStep.definition` typing the
      callee from its declared `results`)
19. Extend `ScriptControlFlowTest` — `resultStepAlwaysEndsTheScript` over the renamed
    `result-step-first-ends-test.yaml` → 1. Pins the `then` removal as *behaviour*, and closes an
    existing gap: `grep -rn "result-step" --include=*.kt` currently returns **nothing**, so none of the
    `test/script/result/*.yaml` fixtures is driven by any test today.

**Gate A:** `cd ../kzen-auto && ./gradlew build` green.

---

## 5. Session B — validation

Ends with the new errors and warnings live in the editor and gating Run. This is the session where two
existing documents start failing, so their migration belongs here.

### B.1 Thread the compiler into the validator

1. `kzen-auto-jvm/.../server/objects/script/ScriptValidator.kt` — the companion
   `validate(...)` gains a **required** `cachedKotlinCompiler: CachedKotlinCompiler` parameter, placed
   before the defaulted `scriptTree`. No nullable-skip escape hatch: that would let the editor and the
   run-compile path disagree about validity (CC-08/CC-10).
2. The `@Reflect` class gains `@Service private val cachedKotlinCompiler: CachedKotlinCompiler` and
   forwards it inside the `scriptValidationCache.scriptValidation { … }` lambda.
3. `ScriptLogicCompiler.compile` — pass `services.cachedKotlinCompiler`.
4. The five test call sites, one argument each (`context.cachedKotlinCompiler`, already on
   `KzenAutoContext.forTest()`): `ScriptIfChainTest:278`, `ScriptContextCallSiteTest:232`,
   `FormulaStepTest:150`, `ForEachItemsTest:235`, `ContextStepValidationTest:169`.
5. **Canary:** `ScriptValidationCacheTest.detachedValidationPathInjectsCacheAndRepeatsIdentically` builds
   `ScriptValidator` from `filterTransitive(ScriptConventions.scriptValidatorLocation)` alone; the new
   `@Service` widens that closure. It should resolve (`KzenAutoContext.forTest()` supplies the compiler),
   and that test failing is exactly how a missing registration would surface.

`ScriptValidationCache` needs **no change** — its key is the document's transitive digest, which already
covers root step order, the `results:` map, and the `ResultStep` archetype's own notation.

### B.2 The findings pass

Add a private `resultFindings(...)` and merge it **after** the existing `LogicContextAnalysis` merge
(lines 107–121) — it consumes the fixpoint's resolved `typeMetadata`, so it cannot run earlier.

⚠ **The existing warning merge OVERWRITES where the error merge joins** (`copy(warningMessage = warning)`
at line 120 vs `joinToString(" ")` at line 114). Merge the result findings joining **both** channels, or
a step carrying a context warning *and* an unreachable warning silently loses one:

```kotlin
for ((objectPath, finding) in resultFindings) {
    val existing = stepValidationBuffer[objectPath] ?: StepValidation(null, null)
    stepValidationBuffer[objectPath] = existing.copy(
        errorMessage = listOfNotNull(existing.errorMessage, finding.error)
            .joinToString(" ").takeIf { it.isNotEmpty() },
        warningMessage = listOfNotNull(existing.warningMessage, finding.warning)
            .joinToString(" ").takeIf { it.isNotEmpty() })
}
```

`resultFindings` body, per §2:

```kotlin
val analysis = ScriptResultAnalysis.analyze(graphNotation, documentPath)

// Advisory only — Run is never gated on reachability.
for (unreachable in analysis.unreachableRootSteps) { warn(unreachable.objectPath, unreachableMessage) }

if (! analysis.declaresMainResult) { return findings }                       // void Script
val declaredType = resultSignature.find(TupleComponentName.main)!!.metadata

if (analysis.rootSteps.isEmpty()) {
    error(NotationConventions.mainObjectPath, noStepsMessage(declaredType))
    return findings
}

val implicit = analysis.implicitResultStep ?: return findings                 // a Result step supplies it

// Mirrors ForEachStep.bodyTerminalType: a validated step with no value is Unit. After the survivor
// pass every step has an entry, so the elvis is a backstop for the "Not found" row, which already
// carries its own error.
val actualType = stepValidationBuffer[implicit.objectPath]?.typeMetadata ?: TypeMetadata.unit

if (actualType == TypeMetadata.unit) {
    error(implicit.objectPath, noValueMessage(declaredType))
}
else if (! TypeAssignability.isAssignable(
        actualType, declaredType, cachedKotlinCompiler, ClassLoaderUtils.dynamicParentClassLoader())) {
    error(implicit.objectPath, mismatchMessage(declaredType, actualType))
}
```

`TypeAssignability` (`server/objects/logic/`) is the established probe compile — same call shape as
`RunStep.callBindingMismatch:120` and `ResultSinkWorker.payloadFlow:143`, and `CachedKotlinCompiler` is
content-keyed so a repeated probe is a cache hit.

### B.3 Documents that newly fail (2 — both have a nested Result and a valueless last root step)

A full scan of all 48 `is: ResultStep` occurrences found exactly these two; every other document already
ends with a root-level `ResultStep`.

6. `test/…/script/control/script-engine-dowhile-test.yaml` — the only root step is `Loop` (a
   `DoWhileStep`, Unit-typed); the `ResultStep` is its **body** step; declared result `kotlin.Int`. Add a
   trailing root-level Result so the fall-through path has a value. This makes it a *stronger* fixture —
   it now also proves the nested Result wins over the fall-through. `ScriptNotationTest.doWhileRunsBodyAndCapturesResult`
   must still assert **7**.
7. `kzen-auto-jvm/src/main/resources/notation/main/Script-1.yaml` — roots are `ForEach | Display`;
   `DisplayValueStep` declares `Unit`, and the declared result is `kotlin.Any`. Add a trailing root-level
   Result (the "not found" fall-through the document is currently missing). **User-owned sample notation** —
   stage by explicit path; if the shape is contentious, surface it rather than guessing.

Unchanged, verified: `notation/main/FizzBuzz/FizzBuzz Script Item.yaml` and kzen-project's
`sample-step-test.yaml` both already end with a root-level `ResultStep`.

### B.4 New validation tests

8. Fixtures in `test/resources/notation/test/script/result/`:
   - `implicit-result-mismatch-test.yaml` — `results: Int`; last step yields `"text"`.
   - `implicit-result-unit-test.yaml` — `results: Int`; `Value` (Formula), `Show` (DisplayValueStep) last.
   - `implicit-result-no-steps-test.yaml` — `results: Int`, no `main.steps` at all.
   - `result-unreachable-test.yaml` — `results: Int`; `Answer` (Result), `Tail`, `Tail 2`.
9. **New** `kzen-auto-jvm/src/test/kotlin/…/server/objects/script/ScriptResultValidationTest.kt` —
   mirror `FormulaStepTest.scriptValidationFor`:
   - `implicitTypeMismatchIsAnErrorOnTheLastStep`
   - `unitLastStepWithDeclaredResultIsAnError`
   - `declaredResultWithNoStepsIsAnErrorOnMain` — assert the key is `ObjectPath.parse("main")`
   - `stepsAfterARootResultStepWarnAndDoNotError` — assert `warningMessage != null && errorMessage == null` on **both** tails
   - `nestedResultStepDoesNotExemptTheTail` — the §1.1 rule, asserted as an error
   - `voidScriptWithATrailingValueStepHasNoFindings`
   - reuse `implicit-result-nested-result-test.yaml` from A.7 for the nested case, extended with a
     valueless tail if A's version ends in a typed Formula.

**Gate B:** `cd ../kzen-auto && ./gradlew build` green.

---

## 6. Session C — client Result chip + docs sweep + smoke

The implicit result is invisible in the editor until this lands, so C is what makes the feature legible.

### C.1 Compute once in the store, not per step

Both stores publish full state to **every** subscriber on **every** change; a per-step whole-document
analysis would be O(N²) inheritance-chain walks. Compute it exactly where `scriptTree` is already
recomputed.

1. `…/client/objects/document/script/model/ScriptState.kt` — add `implicitResultStep: ObjectLocation?`
   beside `scriptTree` (line 21), threaded through `initial(...)` (line 57) and
   `withDocumentNotation(...)` (line 150). Follow `scriptTree`'s reference-preservation idiom (line 158)
   so unchanged values don't churn downstream equality guards.
2. `…/client/objects/document/script/model/ScriptStore.kt` `onClientState` — compute
   `ScriptResultAnalysis.analyze(clientState.graphStructure().graphNotation, mainLocation.documentPath).implicitResultStep`
   in **both** recompute branches (the initial branch at ~115 and the
   `documentNotation != previousState.documentNotation` branch at ~125–128), alongside `ScriptTree.read`.

### C.2 One derivation covers all four displays

3. `…/script/display/ScriptStepDisplayBase.kt` — add `var isResult: Boolean?` to the state interface and
   derive `scriptState.implicitResultStep == props.common.objectLocation` in `onScriptState`, folded into
   the existing value-equality guard next to `stepValidation` (~126–151).
   `ScriptStepDisplayDefault`, `IfStepDisplay`, `ForEachStepDisplay` and `DoWhileStepDisplay` all extend
   this base, so a root-level `ForEachStep` / `IfStep` as the last step gets the chip too. Nested steps
   compare false automatically — `implicitResultStep` is only ever a root step. `RunStepDisplay` inherits
   it via `ScriptStepDisplayDefault`.
4. `…/script/step/header/StepHeader.kt` — add `var isResult: Boolean?` to the props and render a `Chip`
   in the right cluster **before** the Skipped/Partial/type chips (it is an identity marker, so it reads
   first). Copy the Skipped chip verbatim (~350–360): `size = Size.small`,
   `variant = ChipVariant.outlined`, `marginRight = 0.5.em`, `label = ReactNode("Result")`.
   The error/warning icons keep their existing worst-first ordering — do not reorder them.
5. `…/script/display/ScriptStepDisplayDefault.kt` — pass `isResult = state.isResult` in the `StepHeader`
   block (~409–435).
6. `…/script/display/branch/BranchHeaderSlab.kt` — add `isResult: Boolean = false` and forward it; add
   the argument at its three call sites: `IfStepDisplay.kt:~378`, `foreach/ForEachStepDisplay.kt:~168`,
   `DoWhileStepDisplay.kt:~101`.

`ScriptStepSlot` and `ScriptBranchDisplay` need no change.

### C.3 Smoke (this is the session's real deliverable)

7. **Client-graph boot check** — the `ResultThenAttributeView` deletion in A.2 has **no JVM coverage**; a
   dangling `script-js.yaml` registration only shows as a dead client at boot.
8. Sweep `notation/main/**` through the `ScriptValidator` detached action — `AutoTestUtils.readNotation`
   excludes those, so they get no other coverage. Diff error counts against a pre-change baseline.
9. On a **spare port** (never the user's 8080 / 18081 — AGENTS.md; verify any JVM you stop is one you
   started), open a Script and confirm:
   - the Result step card no longer offers a `then` dropdown, and the old "End script" chip is gone;
   - the last step shows a **Result** chip, and it moves when steps are reordered or appended;
   - setting the result signature to a mismatched type reddens that step's border and gates Run;
   - adding a step after a root-level Result shows an amber unreachable warning and does **not** gate Run;
   - a root-level `ForEachStep` as the last step shows the chip on its branch header slab.

**Gate C:** `./gradlew build` green + the smoke above.

---

## 7. Dependencies & coordination

- **Publish before any standalone kzen-project build** picks up the archetype change:
  `cd ../kzen-auto && ./gradlew publishToMavenLocal`. kzen-project's `sample-step-test.yaml` is
  source-compatible (trailing `ResultStep`, no `then:`) — rebuild only.
- **No version bumps** (CC-14).
- `ResultSinkWorker` / the Job flavour need **no change** — separate validator, separate signature path.
  Its KDoc calls itself "the Job-side analogue of Script's Result step"; that stays true.
- `RunStep` is unaffected and strictly **improves**: it types a hosted callee by the callee's *declared*
  `results` regardless of how the value is produced. Today a callee declaring `results` with no
  `ResultStep` is typed `Int` at the call site yet returns void at run time; the implicit result closes
  that, and B's no-steps / Unit errors make the remainder loud instead of silent.
- **Live-edit migration** needs no new capture state: the last root step's outcome is already in
  `completedOutcomes`, carried, and replay-adopted, so `runSteps` returns it on a rebuild. A migration
  that deletes the last root step promotes its predecessor, whose adopted value is what `runSteps` then
  returns — correct by construction.
- **Move-to / skip-set**: a forward jump can only skip steps *before* its target, so the last root step
  is never skipped on a run that completes; a backward jump re-runs it. `ScriptRunContext.restore`'s
  decision-11 sentence (the carried `result` is kept) is unaffected — it concerns `resultValue` only —
  but deserves one clause noting the implicit path re-derives from the last step's carried outcome.

## 8. Known frictions (accepted)

- **Ending a Script with a `Display` step becomes a hard error.** That is the rule as specified and the
  most likely source of user friction, hence the actionable "or add a Result step" clause in the copy.
  (`DisplayValueStep` declares `Unit` although it returns a String at run time — a pre-existing
  inconsistency, out of scope, CC-07.)
- **`main`-anchored *warnings* are invisible today**: `ScriptStepDisplayBase` looks up by its own step's
  `objectPath`, which never equals `main`. `LogicContextAnalysis` already emits some (lines ~423/429) and
  nothing renders them. The no-steps **error** does surface, via `StageController.validationLinesFor`.
  Do not add a `main`-anchored warning expecting it to render. Pre-existing gap, out of scope.

## 9. Verification

```powershell
cd ../kzen-auto
./gradlew :kzen-auto-common:jvmTest                                    # ScriptResultAnalysisTest
./gradlew :kzen-auto-jvm:test --tests "*Script*"                       # validator + engine suites
./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest"               # the toolchain canary
./gradlew :kzen-auto-js:compileKotlinJs                                # fast JS gate (Session C)
./gradlew build                                                        # per-session gate
./gradlew publishToMavenLocal                                          # before any kzen-project build
```

Never `./gradlew build` from the umbrella — it abbreviation-matches `buildEnvironment` and exits 0
having compiled nothing.

---

## 10. As-built (landed 2026-08-06)

All three sessions landed in one pass. Each gate was a full `cd ../kzen-auto && ./gradlew build`, green:
**A** 28m43s, **B** 27m40s, **C** 28m27s.

### Deviations from the plan

1. **`result-step-void-test.yaml` — an inverted fixture the blast-radius scan missed.** §5 B.3's scan
   enumerated documents by `is: ResultStep`, so a fixture with *no* Result step was invisible to it. It
   declares `results: Int` with a single root Formula (`99`) and a comment asserting the Script "returns
   void" — false under the implicit rule; it returns 99. Comment rewritten. Its **filename is now
   misleading** and was deliberately left alone (it is the canonical implicit-result case, and renaming
   it is a separate call). Lesson for the next semantics change: scan by the *declared signature*, not
   only by the construct being changed.
2. **§5 B.4's fixture reuse does not work as written.** It said to reuse
   `implicit-result-nested-result-test.yaml` for `nestedResultStepDoesNotExemptTheTail`, "extended with
   a valueless tail if A's version ends in a typed Formula". A's version *does* end in a typed Formula
   (`Tail`, `0`), which satisfies the declared `Int` and so produces no finding at all. Rather than
   mutate a fixture another test asserts on, a sibling `implicit-result-nested-unit-tail-test.yaml` was
   added with the same nested-Result shape and a Unit tail.
3. **`ForEachStep.kt`'s `collecting` comment was a fourth load-bearing false claim**, not in §4 A.6's
   sweep list. It justified `collecting = false` with "[ScriptLogic] discards the root sequence's
   value". Corrected to name the void-Script case, which is the condition that still holds.
4. **`ScriptResultAnalysisTest` gained a 7th case** beyond §4 A.1's six: a `CustomResultStep:
   is: ResultStep` subtype, since the inheritance-chain rule was otherwise only exercised at depth 1.

### Findings worth keeping

5. **A dangling `is:` does not throw.** `GraphNotation.inheritanceParent` degrades to
   `BootstrapConventions.rootObjectLocation` so startup survives — so a mistyped archetype name in a
   test fixture makes `isResultStep` quietly return false and the test pass **vacuously**.
   `ScriptResultAnalysisTest` is self-guarding: three of its cases assert `isResultStep` returns *true*,
   so a broken chain fails three tests instead of passing silently. Any future notation-level test
   should be built the same way.
6. **`notation/main/**` is not served from the jar.** `KzenAutoContext` builds
   `ClasspathNotationMedia(exclude = autoMainDocumentNesting)`, so `main/` resolves only from the CWD's
   `src/main/resources/notation` — the `empty-project` fixture yields zero `main/` documents, and a
   validator sweep of the user documents must boot the server with its working directory at the repo (or
   a copy of it). The server also caches its notation scan at boot, so a document added afterwards
   returns "Document not found" until restart.
7. **`FizzBuzz Script Loop.yaml` declares `results: {}`** — an *empty* map — and ends on a Unit
   `Display 2`. It is correctly void today because `find(TupleComponentName.main)` returns null, but it
   is the single in-tree document where a change to how an empty `results:` parses would flip a clean
   document into a hard error.
8. **The §4 A.3 step-8 guard was real, not theoretical.** Before `ScriptValueReferences` seeded the
   implicit result step, `ScriptImplicitResultTest.trailingLoopIsCollectedWhenItIsTheImplicitResult`
   failed; the seeding is what makes a trailing root `ForEachStep` return `[2, 4, 6]` rather than `[]`.
9. **§8's "`main`-anchored warnings are invisible" holds**, and the no-steps *error* does surface, as
   predicted.

### Smoke (§6 C.3) — what was verified automatically

Two spare ports (8097 pristine fixture, 8096 a read-only scratch copy of `notation/main`); the user's
own servers untouched. Findings:

- **Client-graph boot: clean.** `#root` renders the full app; zero `CONSOLE` error lines. The production
  bundle contains **0** occurrences of `ResultThenAttributeView` / `Keep Running` / `End Script`, while
  `ScriptStepDisplayDefault` *is* present — proving reflection-name literals survive minification, so
  the zero counts are meaningful rather than an artefact.
- **Notation sweep: all 6 `main/**` Scripts return errors=0, warnings=0**, matching §5 B.3's prediction
  exactly (`Script-1.yaml` clean with its new trailing Result; `Script.yaml` void; FizzBuzz unaffected).
- **Positive controls** were added in the scratch copy, because no real document exercises the new
  findings — a root-Result-then-tail probe produced the `Never runs …` warning, and a declared-`Any`
  ends-on-`Display` probe (the exact shape `Script-1.yaml` had *before* the fix) produced the "produces
  no value" error. Without these the green sweep would have been vacuous.
- **UI, in the DOM:** the Result step card renders `code` only, with no `then` control; the **Result**
  chip renders as `MuiChip-label` ahead of the type chip; the chip is correctly *absent* when the
  terminal root step is itself a Result step; the unreachable warning reaches the UI as an amber
  triangle with `aria-label="Never runs — the Result step above ends the Script."`.

**Still owed — live-interaction checks a DOM dump cannot make** (§6 C.3 item 9): that the chip *moves*
when steps are reordered or appended; that a mismatched result signature reddens the step border and
**gates Run**; and that a root-level `ForEachStep` as the last step shows the chip on its branch header
slab (the code path exists and compiles — `BranchHeaderSlab` forwards `isResult` — but was not observed
rendering).

### Open — wants the user's call

**`Script-1.yaml`'s trailing Result value.** The document is a "find the first `Item == 4`" sample whose
Result is nested in an If inside a ForEach; the fall-through (not-found) path needed a root-level Result.
It landed as `main.steps/Result 2` with `code: '"not found"'` — a String into the declared `kotlin.Any`,
matching the sibling `FizzBuzz Script Item.yaml`'s quoting style and its root-`Result`-after-`Display`
structure. A numeric sentinel (`-1`) would instead keep the result type homogeneous with the found
path's `Item: Int`. This is user-owned sample notation and the choice is presentational — one line either
way.
