# S8c — notation-driven branch discovery — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-16_script-client-sweep.md` **8c**. Decisions pre-made in the constituent plan — do not
> re-litigate. Every anchor below re-verified against current kzen-auto master (`ceb699d0`) on
> 2026-07-19 (post SER2–SER5 / Y / G5 / G7 / TP1‑TP4 — near-zero drift on this item's files; the
> one real drift is that `ScriptValueReferences`'s KDoc now *documents* the hardcoded list as a
> known weakness, see findings). **Post-XC4 state audited and recorded below** as the sub-phase
> demands. Half session.

## Scope & goal

Make Script **branch discovery metadata-driven**: a branch attribute is one whose attribute
metadata declares `is: List, of: ScriptStep` — exactly how the archetypes already declare them —
discovered through the `is:` inheritance chain, instead of the hardcoded
`ScriptDependencyAnalysis.branchAttributeNames = [steps, then, else]` list. Plus the companion
notation marker `scope: body` on DoWhileStep's `condition` metadata, replacing
`KotlinExpressionEditor`'s hardcoded DoWhile-vs-Formula scope branch. Plus centralizing the
remaining attribute-name string re-declarations into `ScriptConventions`.

**Why this is the SwitchStep unblocker** (master-plan Stage B1 exit criterion,
`2026-07-16_master-plan.md:142-147`): after this change a future SwitchStep — N branch
attributes, each `is: List, of: ScriptStep, by: NestedList` — is fully expressible as archetype +
server class (`nestedStepLists()`) + display (`is: ScriptStepDisplay` card rendering N
`scriptBranchContainer`s), with **zero edits to shared code**: dependency analysis, value-reference
elision, nesting/jump analyses, drag-drop, and insertion all ride the discovery. Acceptance is
framed (and test-proven with a synthetic multi-branch fixture) here; SwitchStep itself is NOT
built in this sub-phase.

Modules touched: **kzen-auto-common** (the discovery mechanism — explicitly allowed),
**kzen-auto-js** (display/editor consumers), **kzen-auto-jvm** *notation resources + one comment +
tests only* (the `scope: body` YAML marker, a KDoc refresh in `ScriptValueReferences`, new test
fixture/class). No server *behavior* change, no wire change, no kzen-lib change.

## Dependencies & coordination

- **Independent** of 8a / 8b / 8d and everything else in Sprint 2 (sweep plan sizing table,
  `2026-07-16_script-client-sweep.md:130-139`) — safe filler session.
- **8a fence (same file, different concern):** 8a memoizes `ScriptDependencyAnalysis.analyze`
  per (documentPath, notation identity) at the call sites / `ScriptStore`. 8c changes what
  `analyze` *does* internally (walkBranch), not its signature or purity — the memo key is
  unaffected. Whichever runs second skims the other's as-built. The four client `analyze` call
  sites verified live at: `ScriptBranchDisplay.kt:270-271`, `ScriptDependencyOverlay.kt:224-226`,
  `ScriptMoveToArrow.kt:277-279`, `LogicSignatureEditor.kt:208-210` — 8c does not touch any of
  them.
- **8b fence (same display companions):** 8b extracts observer boilerplate from
  `IfStepDisplay`/`ForEachStepDisplay`/`DoWhileStepDisplay`; 8c edits the same files'
  `companion object` constants. Trivial rebase either order.
- **AE plan:** `KotlinExpressionEditor` is already on the modern `AttributeEditor` wrapper and is
  not in AE5's select-editor set (it's a text editor) — no overlap.
- kzen-lib untouched (all primitives needed — `mergeAttribute`, `firstAttribute`,
  `NotationConventions.{is,of,meta}` — already exist, verified below).

## Current-state findings (the post-XC4 audit — "what was actually left to do")

### Audit verdict

Sprint 1 (XC4) made **nesting/loop membership** notation-driven but did **not** touch branch
*discovery*. Precisely:

- **`ScriptDependencyAnalysis.branchAttributeNames` is STILL the hardcoded list** —
  `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/script/model/ScriptDependencyAnalysis.kt:31-38`
  (NB comment :31-34 explicitly says "revisit if a new branching step is introduced (e.g.
  SwitchStep with N branches)"; list :35-38 = `stepsAttributeName` + `AttributeName("then")` +
  `AttributeName("else")`). Consumed only by `walkBranch` (:149-169, the nested-name loop at
  :163-168). **This is the core remainder.**
- **`ScriptNestingAnalysis` (same dir, :25-98) is already fully notation-driven** — reads
  `meta.<branch>.rerun` through the inheritance chain via `graphNotation.firstAttribute`
  (`isReRunAttribute` :63-74) and walks `ScriptTree` structurally (`enclosingPath` :84-97). Its
  own KDoc (:15-20) states "`ScriptTree` already discovers every nested branch generically from
  object nesting, so this helper needs no hardcoded branch list". `ScriptJumpAnalysis` layers on
  it. **Nothing to do here.**
- **`ScriptTree.read` is structural, not name-based** (`ScriptTree.kt:26-57`): children are
  grouped by the next `ObjectPath` nesting segment's attribute name (:34-39), sorted by document
  position (:50-51) — no branch-name list anywhere. The sweep's "check and align" resolves to
  **no change**. Important non-change: `ScriptTree.children` deliberately includes *binding*
  branches too (`parameters`, ForEach's `item`) — `inScopeBindingPaths` (:87-96) depends on that
  — so ScriptTree must **not** be rewired onto branch discovery (which excludes bindings by
  design).
- **The server executes branches via constructor injection** (NestedList definer fills e.g.
  `DoWhileStep(condition, steps, …)` positionally; `IfStep` likewise) and walks nested steps via
  `ScriptStep.nestedStepLists()` — zero attribute-name strings in jvm main sources (grep for
  `"then"|"else"` over `**/*.kt`: only `ScriptDependencyAnalysis`, `IfStepDisplay`, and two
  Kotlin-keyword lists in `ExpressionUtils`/`KotlinExpressionAnalyzer`).
- **Display-side string re-declarations** (all verified at the cited lines — no drift):
  - `IfStepDisplay.kt:66-72` — `conditionAttributeName` (:66, private), `thenAttributeName`
    (:68, **public** val), `elseAttributeName` (:71, **public** val) + derived paths. Grep
    confirms the public vals have **no external consumers** (only :69/:72 in the same file).
  - `ForEachStepDisplay.kt:72` — `private val itemsAttributeName = AttributeName("items")`
    (duplicate of the existing `ScriptConventions.itemsAttributeName`, `ScriptConventions.kt:35`).
  - `DoWhileStepDisplay.kt:70` — `private val conditionAttributeName = AttributeName("condition")`.
  - `KotlinExpressionEditor.kt:77` — `private val conditionAttributeName =
    AttributeName("condition")`, feeding the hardcoded scope branch at **:194-204** (`if
    (props.attributeName == conditionAttributeName)` → `bodyStepPaths(…) + inScopeBindingPaths`
    else `predecessors + inScopeBindingPaths`; comments cite "Mirrors server
    DoWhileStep.conditionScopeTypes" / "FormulaStep.processorTypes"). `bodyStepPaths` (:230-236)
    additionally hardcodes that a body = the `steps` branch
    (`node.children[ScriptConventions.stepsAttributeName]`).
- **`ScriptValueReferences` (jvm, `server/exec/script/ScriptValueReferences.kt`) documents the
  weakness**: KDoc item 2 (:24-27) — "The analysis enumerates branches by a hardcoded
  attribute-name list (`branchAttributeNames`), so a step type branching under any other name is
  invisible to it" — and compensates with the `nestedStepLists` completeness backstop (:48-70:
  any walked step not in `branchOfStep` ⇒ report *all* steps referenced). The backstop **stays**
  (it also covers instantiation failures); only the KDoc wording updates.

**So the remainder is:** (1) metadata discovery replacing `branchAttributeNames` inside
`walkBranch`; (2) the `scope: body` marker + editor read; (3) constant centralization; (4) the
`ScriptValueReferences` KDoc refresh; (5) tests. Nothing else — this is genuinely the last
name-coupled seam (the graph-plan-5b "already landed" scenario did **not** materialize here).

### Archetype declarations (the discovery predicate's ground truth)

`kzen-auto-jvm/src/main/resources/notation/auto-jvm/script/script-jvm.yaml` (anchors drifted from
the plan's :305-312/:329-332 cites):

- **IfStep :288-309** — `meta.then` :302-305 and `meta.else` :306-309, both
  `is: List / of: ScriptStep / by: NestedList`.
- **ForEachStep :312-333** — `meta.steps` :326-332 (same trio + `rerun: true` :332).
- **DoWhileStep :355-376** — `meta.condition` :364-369 (`is: String, multiline: true, editor:
  KotlinExpressionEditor, summary: TextAttributeView`), `meta.steps` :370-375 (trio +
  `rerun: true` :375).
- **Root Script archetype** — `notation/auto-common/common-document.yaml:37-63`: `meta.steps`
  :47-50 is `is: List / of: ScriptStep / by: NestedList`; `meta.parameters` :51-54 is
  `is: List / of: ParameterBinding / by: NestedList`.

**Predicate nuance — exact-name `of:` matching is load-bearing, not just simple:**
`ParameterBinding` is itself `is: ScriptStep` (script-jvm.yaml :62-65), so an
inheritance-resolving predicate ("`of` reaches ScriptStep") would wrongly classify the
`parameters` binding branch as a body branch. The pre-made decision (raw scalar `of == "ScriptStep"`)
is therefore also the *correct* one. A SwitchStep declares `of: ScriptStep` directly. (Accepted
limitation, record: a fully-qualified `of:` reference like `…#ScriptStep` would not match — no
first-party or sample-plugin notation writes one.)

Also verified: `ResultStep` has a **scalar** `then:` attribute (:146, meta :153-155 `is: String`)
— the old name-based probe blindly probes `then` on every step (harmless today only because
nothing nests objects there); discovery is type-aware and removes that collision hazard outright.

### kzen-lib primitives (all exist; nothing to add)

- `GraphNotation.mergeAttribute(objectLocation, attributeName)` —
  `kzen-lib-common/.../model/structure/notation/GraphNotation.kt:218-250` — merges an attribute
  across the **full linearized inheritance chain** (C3-like, `inheritanceChain` :65-118; cached;
  dangling `is:` degrades to root :170-173, cycles guarded). This is the enumeration read the
  discovery needs (`firstAttribute` :277-288 only probes a known path — right for the `scope`
  marker, wrong for enumeration).
- `NotationConventions` (`kzen-lib-common/.../service/notation/NotationConventions.kt`):
  `isAttributeSegment`/`isKey` :32-33, `ofAttributeSegment`/`ofKey` :41-42, `metaAttributeName`
  :45. `AttributeSegment.asKey()` exists (`AttributeSegment.kt:33-35`).
- The `List` type is a kzen-base notation object (`kzen-lib-jvm/.../notation/base/kzen-base.yaml:90-92`)
  with **no Kotlin-side name constant** — the discovery helper declares its own private
  `"List"` literal (documented as referencing kzen-base).
- `GraphDefinitionAttempt.successful()` keeps the **full** `graphStructure`
  (`GraphDefinitionAttempt.kt:13-20`), so `mergeAttribute` works even for steps whose own
  definition failed — discovery never needs the definition layer.
- `ClientStateGlobal.current(): ClientState?` exists (`ClientStateGlobal.kt:142-144`) — the
  editor's scope-marker read can be synchronous at use time (no observer-ordering hazard).

### Server scope helper (for the marker's contract)

`DoWhileStep.conditionScopeTypes`
(`kzen-auto-jvm/.../server/objects/script/step/control/DoWhileStep.kt:144-150`): scope = body
steps (from the constructor's `steps` list) + `scriptTree.inScopeBindingPaths`. `FormulaStep`'s
default scope is predecessors + bindings. **Neither branches on an attribute name** — the scope
rule is each step class's own code. Consequence for the pre-made "read by both the editor and
(optionally) the server": **the server read site does not exist and none is added** — the marker
is the *client-facing declaration* of the scope semantics the step's own server class implements;
the drift surface collapses from "client code string vs server code" to "a marker adjacent to the
class that implements it" (same resolution as `rerun`, which is likewise inert server-side and
read only by `ScriptNestingAnalysis`).

## Pre-resolved questions

1. **Where does discovery live?** `ScriptConventions` (kzen-auto-common,
   `objects/document/script/ScriptConventions.kt`), next to `orderedDirectChildLocations`
   (:52-63) — the sweep plan's own suggestion. Both consumers (`ScriptDependencyAnalysis`,
   `KotlinExpressionEditor`) already import it.
2. **Predicate:** merged `meta.<attr>` is a map with scalar `is == "List"` **and** scalar
   `of == "ScriptStep"` (`ScriptConventions.stepObjectName.value`). `by:` is deliberately NOT
   part of the predicate (definer choice is orthogonal; Job's `workers`/`channels` use NestedList
   with different `of:` and are excluded by `of`, not `by`).
3. **`ScriptTree.read`:** no change (already structural; must keep binding branches — see audit).
4. **Root walk in `analyze`:** unchanged (`stepsAttributePath` then `parametersAttributePath`,
   :57-75) — `parameters` is not discoverable by the predicate (by design) and the
   EMPTY short-circuit (:62-64) depends on the steps-first order. Discovery applies to the
   *recursion* over steps.
5. **Scope-marker vocabulary:** `scope: body` (absent ⇒ default predecessors scope). Helper
   `ScriptConventions.isBodyScopedExpression(…)` mirrors `ScriptNestingAnalysis.isReRunAttribute`
   (`firstAttribute` on `meta.<attr>.scope`).
6. **What centralizes into `ScriptConventions`:** one new constant `conditionAttributeName`
   (shared by IfStepDisplay + DoWhileStepDisplay); ForEachStepDisplay switches to the *existing*
   `itemsAttributeName`. **`then`/`else` deliberately do NOT move to `ScriptConventions`** — once
   dropped from `ScriptDependencyAnalysis` they exist only in `IfStepDisplay`, the step's own
   component, which is exactly where the no-god-object rule wants them (shared code must not know
   IfStep's branch names). They become `private` there (verified zero external consumers).
   `KotlinExpressionEditor`'s `conditionAttributeName` is deleted outright (replaced by the
   marker).
7. **`ScriptValueReferences`:** comment-only KDoc refresh (jvm) — behavior and backstop
   unchanged; sanctioned as zero-behavior.

## Step-by-step implementation

### 1. `ScriptConventions` — the discovery function + scope helper + constant (kzen-auto-common)

`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/script/ScriptConventions.kt`
— add (imports to extend: `AttributeNesting`, `AttributeSegment`, `MapAttributeNotation`,
`NotationConventions` is already imported, `persistentListOf`):

```kotlin
val conditionAttributeName = AttributeName("condition")

// The kzen-base `List` type object (kzen-lib notation/base/kzen-base.yaml) — attribute metadata
// declares list-ness as `is: List`. No kzen-lib Kotlin constant exists for it.
private const val listTypeName = "List"

// Attribute-metadata key marking an expression attribute whose in-scope references are the
// declaring step's own BODY steps (children of its branch attributes) rather than its
// predecessors — e.g. DoWhileStep.condition (`scope: body`). Read by the client
// KotlinExpressionEditor; the server-side counterpart is the step class's own scope computation
// (DoWhileStep.conditionScopeTypes). Inert for definition, like `rerun`.
private const val scopeMetaKey = "scope"
private const val scopeBodyValue = "body"

/**
 * The branch attributes of [objectLocation]'s type: attributes whose merged metadata (through the
 * `is:` inheritance chain) declares `is: List, of: ScriptStep` — exactly how IfStep's then/else,
 * ForEachStep's / DoWhileStep's steps, and the root Script's steps are declared. Notation-driven,
 * so a third-party branching step (e.g. a SwitchStep with N branches) is discovered with no
 * shared-code edit. Binding branches (Script `parameters`, ForEach `item`) do not match: they are
 * `of:` a subtype (or undeclared), never `of: ScriptStep` itself.
 */
fun stepBranchAttributeNames(
    graphNotation: GraphNotation,
    objectLocation: ObjectLocation
): List<AttributeName> {
    if (objectLocation !in graphNotation.coalesce) {
        // NB: stale location (deleted/renamed) — inheritanceChain would throw
        return listOf()
    }
    val metaNotation = graphNotation.mergeAttribute(
        objectLocation, NotationConventions.metaAttributeName)
        as? MapAttributeNotation
        ?: return listOf()

    return metaNotation.map.mapNotNull { (segment, attributeMeta) ->
        val metaMap = attributeMeta as? MapAttributeNotation
            ?: return@mapNotNull null
        val isList = metaMap.map[NotationConventions.isAttributeSegment]
            ?.asString() == listTypeName
        val ofStep = metaMap.map[NotationConventions.ofAttributeSegment]
            ?.asString() == stepObjectName.value
        if (isList && ofStep) { AttributeName(segment.asKey()) } else { null }
    }
}

/**
 * Whether [attributeName] on [objectLocation]'s type is marked `scope: body` in its attribute
 * metadata (read through the inheritance chain, mirroring ScriptNestingAnalysis.isReRunAttribute).
 */
fun isBodyScopedExpression(
    graphNotation: GraphNotation,
    objectLocation: ObjectLocation,
    attributeName: AttributeName
): Boolean {
    if (objectLocation !in graphNotation.coalesce) {
        return false
    }
    val scopePath = AttributePath(
        NotationConventions.metaAttributeName,
        AttributeNesting(persistentListOf(
            AttributeSegment.ofKey(attributeName.value),
            AttributeSegment.ofKey(scopeMetaKey))))
    return graphNotation.firstAttribute(objectLocation, scopePath)?.asString() == scopeBodyValue
}
```

Notes: `mergeAttribute`'s map-merge order across the chain is not load-bearing here (consumers
treat the result as a set; `branchOfStep` is a map, `edges` a set). Cost: one cached-chain merge
per step, and — a small net *win* — leaf steps (the majority) now trigger **zero**
`orderedDirectChildLocations` document scans versus three name-probes each today.

### 2. `ScriptDependencyAnalysis` — replace the list with discovery (kzen-auto-common)

`ScriptDependencyAnalysis.kt`:

- **Delete** :31-38 (the NB comment + `branchAttributeNames`). Replace with a short comment:
  branch recursion is metadata-driven via `ScriptConventions.stepBranchAttributeNames` (the former
  SwitchStep blocker).
- **`walkBranch` (:149-169):** replace the `for (nestedName in branchAttributeNames)` loop
  (:163-168) with:

```kotlin
for (step in steps) {
    for (nestedName in ScriptConventions.stepBranchAttributeNames(graphNotation, step)) {
        val nestedAttrLocation = AttributeLocation(step, AttributePath.ofName(nestedName))
        walkBranch(nestedAttrLocation, graphDefinition, branchOfStep)
    }
}
```

  and update the method comment (:154-155 "probing a branch a step doesn't have (e.g. Run.steps)
  just yields an empty list" → discovery only recurses into declared branches).
- `analyze` (:48-146) is otherwise untouched — root walk, parameters walk, identifier scan,
  `classifyEdge`, and every derived query (`crossBranchEdges`, index-pair helpers) unchanged.

Behavioral equivalence for well-formed documents: per-type discovery yields exactly
`then`+`else` for IfStep, `steps` for ForEach/DoWhile, nothing for leaf steps — the same
`branchOfStep` the fixed list produced. The only delta is for malformed/power-edited docs nesting
objects under an *undeclared* attribute of a step (previously classified if the attribute
happened to be named `steps`/`then`/`else`, now not) — the safe direction on the server
(`ScriptValueReferences`' backstop reports all-referenced when the walk sees an unclassified
step) and a cosmetic-only gap on the client (no overlay line for a step the engine wouldn't run
anyway).

### 3. `scope: body` marker — YAML + editor read (kzen-auto-jvm resources + kzen-auto-js)

**YAML** — `script-jvm.yaml` DoWhileStep `meta.condition` (:364-369); add one line + comment
after `summary: TextAttributeView` (:369):

```yaml
    condition:
      is: String
      multiline: true
      editor: KotlinExpressionEditor
      summary: TextAttributeView
      # The condition's in-scope references are this loop's own body steps, not its predecessors
      # (read by the client KotlinExpressionEditor via ScriptConventions.isBodyScopedExpression;
      # the server counterpart is DoWhileStep.conditionScopeTypes itself). Inert for definition,
      # like `rerun` below.
      scope: body
```

(This file is a notation *resource* under `src/main/resources/notation/auto-jvm/` — not a user
`notation/main/` directory. Extra metadata keys are ignored by definers and merged harmlessly by
`NotationMetadataReader.readAttribute` — same mechanism that carries `rerun`.)

**`KotlinExpressionEditor.kt`:**

- Delete the companion `conditionAttributeName` (:76-78).
- `onScriptState` (:190-213): replace the name test (:195) with the marker read, synchronous via
  `ClientStateGlobal.current()`:

```kotlin
val graphNotation = props.clientStateGlobal.current()
    ?.graphStructure()?.graphNotation

val bodyScoped = graphNotation != null &&
    ScriptConventions.isBodyScopedExpression(
        graphNotation, props.objectLocation, props.attributeName)

val candidatePaths =
    if (bodyScoped) {
        // A `scope: body` expression (e.g. DoWhileStep.condition) references the step's own
        // body steps plus in-scope bindings — NOT predecessors.
        bodyStepPaths(graphNotation, scriptTree, targetPath) +
            scriptTree.inScopeBindingPaths(targetPath)
    }
    else {
        // Default: prior steps plus in-scope bindings (parameters / loop items) — e.g.
        // FormulaStep.code / ResultStep.code.
        scriptTree.predecessors(targetPath) + scriptTree.inScopeBindingPaths(targetPath)
    }
```

- `bodyStepPaths` (:230-236): generalize from the hardcoded `steps` branch to **all discovered
  branch attributes** of the node (removes the :233 `ScriptConventions.stepsAttributeName`
  hardcode and makes body-scope correct for an N-branch third-party loop):

```kotlin
// The direct body steps of the node at `target`: children under each of its DISCOVERED branch
// attributes (metadata `is: List, of: ScriptStep`), in tree order.
private fun bodyStepPaths(
    graphNotation: GraphNotation,
    scriptTree: ScriptTree,
    target: ObjectPath
): List<ObjectPath> {
    val node = findNode(scriptTree, target)
        ?: return listOf()
    val branchNames = ScriptConventions.stepBranchAttributeNames(
        graphNotation, props.objectLocation.documentPath.toObjectLocation(target))
    return branchNames.flatMap { branchName ->
        node.children[branchName]?.map { it.objectPath } ?: listOf()
    }
}
```

  (No observer-ordering hazard: the read happens inside `onScriptState` at use time against the
  synchronous `current()`; when `current()` is still null — impossible in practice once a
  ScriptState exists, but guarded — the editor falls back to the default scope and self-corrects
  on the next publish.)

### 4. Centralize the remaining constants (kzen-auto-js)

- `ScriptConventions`: `conditionAttributeName` added in step 1.
- **`IfStepDisplay.kt` :66-72:** drop the local `conditionAttributeName` (use
  `ScriptConventions.conditionAttributeName` at :191); make `thenAttributeName` /
  `elseAttributeName` **private** (they stay here — IfStep's own display legitimately owns its
  branch names; verified no external consumers).
- **`ForEachStepDisplay.kt` :72:** delete the local `itemsAttributeName`; use
  `ScriptConventions.itemsAttributeName` at its single use site (the items editor render).
- **`DoWhileStepDisplay.kt` :70:** delete the local `conditionAttributeName`; use
  `ScriptConventions.conditionAttributeName`.

### 5. `ScriptValueReferences` KDoc refresh (kzen-auto-jvm, comment-only)

`server/exec/script/ScriptValueReferences.kt` :24-27 — reword item 2: the analysis now discovers
branches from attribute metadata (`is: List, of: ScriptStep`), so the invisible case is a step
type whose branch metadata is missing/undeclared (raw-YAML power edits, a plugin authoring
mistake) rather than "any name outside the hardcoded list"; the `nestedStepLists` completeness
backstop is unchanged and still the reason wrong results can't slip through.

## Tests

All in **kzen-auto-jvm/src/test** via the established `AutoTestUtils` pattern
(`readNotation()` + `graphDefinitionAttempt()`, `AutoTestUtils.kt:38-88`; test notation under
`kzen-auto-jvm/src/test/resources/notation/test/`). Common code is already tested from here
(`ScriptDependencyAnalysisTest.kt` in
`src/test/kotlin/tech/kzen/auto/common/objects/document/script/model/`).

1. **New fixture** `notation/test/script-branch-discovery-test.yaml` — the SwitchStep acceptance
   proof, self-contained (archetype declared in the fixture doc itself — single-doc use, so no
   ambiguity with the shared `script-step-test-archetypes.yaml`; note its header comment's
   warning about *duplicate* cross-file declarations, which doesn't apply here). Shape:

   ```yaml
   # A branching step type kzen-auto's shared code has never heard of: two branch attributes
   # discovered purely from `is: List, of: ScriptStep` metadata (S8c). No backing class — the
   # dependency analysis is notation-level; definition failure of the Switch instance is
   # tolerated (analyze skips undefined objects' edge scan, walkBranch needs only notation).
   TestSwitchStep:
     abstract: true
     is: ScriptStep
     meta:
       caseA:
         is: List
         of: ScriptStep
         by: NestedList
       caseB:
         is: List
         of: ScriptStep
         by: NestedList

   main:
     is: Script
   main.steps/Switch:
     is: TestSwitchStep
   main.steps/Switch.caseA/ProduceA:
     is: FormulaStep
     code: 1
   main.steps/Switch.caseB/UseA:
     is: FormulaStep
     code: ProduceA + 1
   # a rerun-flagged loop body, proving `steps` discovery via ForEach/DoWhile still works
   main.steps/Loop:
     is: DoWhileStep
     condition: "false"
   main.steps/Loop.steps/Body:
     is: FormulaStep
     code: 2
   ```

2. **New test class** `ScriptBranchDiscoveryTest` (next to `ScriptDependencyAnalysisTest`):
   - `branchOfStep` classifies `…Switch.caseA/ProduceA` under
     `AttributeLocation(Switch, caseA)` and `…caseB/UseA` under `(Switch, caseB)` — the
     zero-shared-code-edit discovery assertion.
   - the `ProduceA → UseA` edge exists and appears in `crossBranchEdges()` (different branch
     attributes of the same container).
   - `…Loop.steps/Body` classifies under `(Loop, steps)` (DoWhile body discovery).
   - `ScriptConventions.stepBranchAttributeNames`: returns `[caseA, caseB]` for the Switch
     instance, `[steps]` for the Loop instance and for `main`, `[]` for a FormulaStep instance
     (leaf) — asserting the `parameters`/`item` exclusion implicitly via `main`.
   - `ScriptConventions.isBodyScopedExpression`: true for `(Loop, condition)` (reads the new
     `scope: body` through the `is: DoWhileStep` chain), false for `(ProduceA, code)` and for
     `(Loop, steps)`.
3. **Regression via existing tests** (must stay green, no edits): `ScriptDependencyAnalysisTest`
   — `namesCollidingOnOneIdentifierAllBecomeSources` exercises If-`then` discovery through the
   new path (`main.steps/Branch.then/…` in `script-name-collision-test.yaml`);
   `detectsParameterReferencedByStepAsCrossBranchEdge` proves the `parameters` branch still
   classifies (root walk) yet is not treated as a body branch. `ScriptNestingAnalysisTest`,
   `ScriptJumpAnalysisTest`, and the script engine/control tests cover the untouched layers.

(No JS unit tests exist for components — `KotlinExpressionEditor`'s behavior is covered by the
manual pass below plus the common-side `isBodyScopedExpression`/`stepBranchAttributeNames` tests
that pin both inputs it composes.)

## Verification

1. `./gradlew :kzen-auto-jvm:test --tests "*ScriptBranchDiscoveryTest" --tests
   "*ScriptDependencyAnalysisTest" --tests "*ScriptNestingAnalysisTest" --tests
   "*ScriptJumpAnalysisTest"` — then the full `:kzen-auto-jvm:test` (the engine/control suites
   exercise `ScriptValueReferences` through runs).
2. `./gradlew :kzen-auto-js:build` (sweep baseline; compiles common for JS too).
3. `./gradlew :kzen-auto-test:selfTest` (opt-in; opens Chrome, two JVMs).
4. **Manual** (dev loop, `-PjsWatch`): on a Script containing If + ForEach + DoWhile —
   - drag-drop steps into/out of `then`/`else`/loop bodies behaves as before;
   - the dependency overlay + gutters draw the same lines (incl. a parameter → step edge and a
     cross-branch edge into an If branch);
   - reference insertion: FormulaStep's picker offers predecessors+bindings; DoWhileStep's
     condition picker offers **body steps**+bindings (the `scope: body` path);
   - rename-while-open of a referenced step still rewrites expressions without errors;
   - React DevTools "highlight updates": no new sibling-branch lighting (no observer changes made).

## Risks & gotchas

- **Malformed-doc delta** (step 2 note): objects nested under an undeclared branch attribute are
  no longer classified. Server-safe by the `ScriptValueReferences` backstop; client-side the
  overlay simply omits those edges. Accepted — the step tree/metadata is authoritative.
- **`mergeAttribute` on broken notation**: a *malformed* `is:` (map-typed) throws in
  `inheritanceParents` (`GraphNotation.kt:157-159`) where the old name-probe didn't walk the
  chain at all. Dangling `is:` is safe (degrades to root, :170-173). Same exposure class as every
  existing client inheritance lookup (see the js-architecture stale-location gotcha); the
  `!in coalesce` guard in the helper covers the stale-location case.
- **Do not rewire `ScriptTree` onto discovery** — its children must keep binding branches
  (`parameters`/`item`) for `inScopeBindingPaths`. Discovery filters happen at the consumers.
- **Ordering of discovered branches** follows the merged-meta map order (archetype declaration
  order for the common case). Nothing consumes branch order today (`branchOfStep` map / `edges`
  set / `bodyStepPaths` scope set); don't introduce a consumer that does without pinning it.
- **`of:` exact-name match**: a qualified `of:` reference or an `of:` naming a ScriptStep
  *subtype* does not match — the latter is deliberate (that's what excludes `parameters`; a
  branch must say `of: ScriptStep`). Document in the helper KDoc (done in step 1's text).
- **Perf**: net neutral-to-better (leaf steps drop 3 document scans each; one cached-chain merge
  added per step). 8a's memo bounds the call frequency regardless.
- **Visibility change**: `IfStepDisplay.thenAttributeName`/`elseAttributeName` public → private —
  verified zero external consumers at `ceb699d0`; if 8b landed in between and moved them, re-grep.
- **YAML edit discipline**: `script-jvm.yaml` is a bundled resource (fine to edit); never touch
  any `notation/main/` user directory.

## Out of scope

- **Building SwitchStep** — this sub-phase only removes its blocker and proves the seam with the
  test fixture. The archetype/class/display of a real SwitchStep is future work (unscheduled).
- Engine-side anything: `ScriptStep.nestedStepLists`, `ScriptRunContext`, validator, wire formats.
- `ScriptTree`/`ScriptNestingAnalysis`/`ScriptJumpAnalysis` changes (already notation-driven).
- 8a memoization, 8b display-base extraction, 8d hygiene items (`StepRowRefRegistry`, TODOs,
  deprecated `ArgumentStep`/`ForEachItemStep` retirement — note `ForEachItemStep` at
  script-jvm.yaml :346-352 is 8d's, not ours, even though it sits amid our anchors).
- Migrating `SelectStepEditor`'s predecessor scope (8b's helper extraction) — IfStep's
  `condition` (`is: ObjectLocation`, `editor: SelectStepEditor`) is untouched by the `scope`
  marker, which applies only to `KotlinExpressionEditor` expression attributes.
