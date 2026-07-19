# S8d — Script client hygiene — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-16_script-client-sweep.md` **8d** (constituent-plan decisions pre-made — do not
> re-litigate; this plan elaborates them against current code). Master plan Stage B1
> (`2026-07-16_master-plan.md:142–147`). Every anchor re-verified against current kzen-auto
> master (`ceb699d0`) on 2026-07-19; drift from the constituent plan is called out inline
> (notably: `stateOrNull` is **not** dead — it gained a consumer; verdict adjusted from
> "remove" to "keep + justify"). The deprecated-archetype grep was **run now**; verdict:
> unreferenced → **retire** (results recorded in § Pre-resolved questions). One session, small.
> Four mutually independent items, each independently landable — commit per item.

## Scope & goal

Close out the Script client sweep's hygiene tail (kzen-auto-js, plus the notation-resource /
JVM-class edits of the archetype retirement):

1. Delete the commented debug line `StepDisplayManager.kt:114`.
2. Resolve the three open TODOs: `ScriptStore.kt:203` (`stateOrNull` YAGNI question),
   `SelectLogicEditor.kt:118` (DAG guard on callee suggestions), `SelectLogicEditor.kt:59`
   (`→ RPureComponent`, **conditional on AE5 not having landed**).
3. Scope the `StepRowRefRegistry` process-global singleton through the existing per-document
   `DocumentBridge`, following the established `ScriptDragStoreKey` owner-provided pattern.
4. Retire the deprecated `ArgumentStep` / `ForEachItemStep` archetypes (yaml blocks + JVM
   classes + the one test fixture), verdict per the grep below.

No behaviour change is intended anywhere except: (a) cycle-forming documents disappear from the
RunStep/RunLogic/RunWorker `instructions` dropdown (suggestion-filter only), and (b) the two
deprecated step archetypes are no longer definable/insertable.

## Dependencies & coordination

- **AE5 conditional (item 2c).** AE5 (`2026-07-14_attribute-editor-improvements.md` Phase 5,
  `SelectReferenceEditorBase`) migrates `SelectLogicEditor` onto an `RPureComponent` base and
  "also resolves its `// TODO: convert to RPureComponent`" (:374–375). **As of 2026-07-19 AE5
  has NOT landed**: no `SelectReferenceEditorBase` anywhere in kzen-auto, and
  `SelectLogicEditor.kt:59` still carries the TODO with the class extending `RComponent`
  (:61–64). **Explicit gate at execution time** (Stage B1 orders AE3→AE4→AE5 before S8d, so it
  may have landed by then): grep `SelectReferenceEditorBase` under `kzen-auto-js/src` **and**
  open `SelectLogicEditor.kt`. If the base exists / the class no longer extends `RComponent` /
  the :59 TODO is gone → **skip item 2c entirely** (AE5 owned it). Otherwise implement 2c here;
  the conversion is forward-compatible (AE5's base is itself `RPureComponent`, and the
  value-equality guard 2c adds matches the base's contract).
- **AE5 interplay with 2b (DAG guard).** AE5 keeps candidate computation per-editor ("graph
  scan for Logic" is listed per-subclass residue, AE plan :369–374), so the guard added here
  survives the later base migration unchanged. If AE5 lands first, `options()` may have moved
  into a `selectOptions()` hook — the guard function ports verbatim.
- **8b coordination (display dedup).** 8d's item 3 touches `ScriptBranchDisplay`,
  `ScriptDependencyOverlay`, `ScriptMoveToArrow`, `LogicSignatureEditor` — none of 8b's
  copy-paste cluster (`IfStepDisplay`/`ForEachStepDisplay`/`DoWhileStepDisplay`/
  `ScriptStepDisplayDefault` observer guards). No conflict; whichever of 8b/8d runs second
  skims the other's as-built (constituent-plan standing rule).
- **Single-repo** (kzen-auto). kzen-lib untouched. `../kzen-project` grepped for the retired
  archetypes — zero references (see below); no downstream coordination. No wire/server behaviour
  change (item 4 deletes server classes but they were unreachable except via the retired
  notation).
- Ground rule from the constituent plan: 8d is otherwise kzen-auto-js only; item 4 is the
  sanctioned exception (notation resources + the two JVM classes + one JVM test fixture).

## Current-state findings (anchors verified 2026-07-19)

**Bridge machinery (the pattern to follow, item 3):**

- `DocumentBridge` (`kzen-auto-js/.../objects/document/bridge/DocumentBridge.kt`): keyed
  container; `channel()` self-constructs via `BridgeKey.create()` (:37–41), `provide()` is an
  idempotent owner write from `render()` (:49–51), `lookup()` returns null when absent (:58–60).
- `DocumentBridgeContext` (`bridge/DocumentBridgeContext.kt:15`): the single per-document React
  context; provided by `ProjectController` (`ProjectController.kt:497`), **recreated per
  document-path change** (`ProjectController.kt:142–143` field; `:369–372` in
  `handleNavigation` — same-document param changes keep it).
- Owner-provided keys precedent: `ScriptStoreKey` / `ScriptDragStoreKey` /
  `ScriptStepReferenceStoreKey` (all in `script/model/`, all `object … : BridgeKey<T>` with no
  `create()`), instances held as `ScriptController` **fields** (`ScriptController.kt:181`
  `dragStore`, `:185` `stepReferenceStore`) and provided in `render()`
  (`ScriptController.kt:328–331`) — the comment there records why: idempotent, re-provides into
  a fresh bridge after a **same-archetype document switch** (ScriptController is *not*
  remounted then), and runs before any child's `componentDidMount`.
- Consumer precedent: `ScriptBranchDisplay` installs the context in `init`
  (`ScriptBranchDisplay.kt:113–115`) and reaches stores through tiny private helpers
  (`:141–150`, e.g. `dragStore(): ScriptStepDragStore? = contextValue<DocumentBridge?>()?.lookup(ScriptDragStoreKey)`).
- Helpers: `installContextType` / `contextValue` in `wrap/React.kt` (`contextValue` at :139–141).

**`StepRowRefRegistry` (item 3):** `script/display/dependency/StepRowRefRegistry.kt` — the
process-global `object` at :12, singleton rationale comment at :10–11 ("only one Script
document is open at a time"). API: `register`/`unregister` (element-matched), `get`,
`observe(listener): unsubscribe`. Consumers (complete census, whole-repo grep):

| Site | Role |
|---|---|
| `ScriptGutterRow.kt:33–37` (`scriptGutterRow`, a plain `ChildrenBuilder` fn) | the **only registration site** — React-19 callback ref with cleanup, on the outer row div when `rowLocation != null` |
| `ScriptBranchDisplay.kt:472` (`computeInsertionFromCursor`) | read: drag-drop insertion index from row rects |
| `ScriptBranchDisplay.kt:631` (`renderRowWithGutter`) | calls `scriptGutterRow(stepLocation, gutter, body, trailing)` |
| `LogicSignatureEditor.kt:453–456` (`common/signature/`, Script-only — sole render site `ScriptController.kt:401`) | calls `scriptGutterRow(parameter.location, …)` for parameter rows; class installs **no** contextType today (:107–110) |
| `ScriptDependencyOverlay.kt:71` (observe), `:159–161` (reads in `remeasure`) | cross-branch polylines; installs no contextType today |
| `ScriptMoveToArrow.kt:120` (observe), `:207`, `:266`, `:322`, `:401` (reads) | next-to-run arrow + drag targets; installs no contextType today |
| `ScriptController.kt:368` | comment mentioning "the shared StepRowRefRegistry" |

`JobCardRowRegistry` (`objects/document/job/JobCardRowRegistry.kt`) is a trimmed **sibling
copy** for the Job document — out of 8d's scope (see § Out of scope).

**TODO anchors (item 2):** all three at exactly the constituent plan's lines — no drift:
`ScriptStore.kt:203`, `SelectLogicEditor.kt:59`, `SelectLogicEditor.kt:118`; debug line
`StepDisplayManager.kt:114` (`//        +"[scriptStepDisplayWrapper - …] - ${props.common}"`).

**Drift — `stateOrNull` is used:** `ScriptStore.stateOrNull()` (:204–206) has one live
consumer: `StepImageFullscreen.scriptState()` (`script/display/image/StepImageFullscreen.kt:137–138`),
called from `render()` (:182) **and** from `navigate()` (:150) which fires off a
window-`keydown` listener — i.e. outside React's lifecycle guarantees, where the store can be
mid-teardown (`willUnmount` nulls `state`, `ScriptStore.kt:88–92`) or the throwing `state()`
(:196–198) would be unsafe. `CustomStore.stateOrNull()` (`custom/model/CustomStore.kt:110–112`)
is the established sibling. Verdict below.

**`SelectLogicEditor` (item 2b/2c):** `script/display/edit/SelectLogicEditor.kt`. It is the
notation-registered editor (`script-js.yaml:133–135`) for **three** flavours' callee attribute:
Script `RunStep.instructions` (`script-jvm.yaml:255`), Flow `RunLogic` (`flow-vertex.yaml:184`),
Job `RunWorker` (`job-worker.yaml:435`) — so the guard must stay flavour-agnostic.
`options()` (:113–135) excludes only the editor's own document (:117–120, with the :118 TODO)
and adds every `AutoConventions.isLogic` document's `main` plus Custom-document exported logic
(:128–131). `updateOptions()` (:204–211) rebuilds a **fresh list on every notation command**
(`onCommandSuccess` :170–193), with no equality guard. Precedents for the guard:
`LinkedLogicDocuments` (`kzen-auto-jvm/.../server/service/impl/LinkedLogicDocuments.kt:36–104`,
JVM-only — metadata-driven `is: ObjectLocation` edge discovery, `resolveLink` filtering by
`isLogic`, "self-hosting and mutual hosting are legal" :31) and `SelectObjectEditor`'s
object-level DAG guard (`common/edit/SelectObjectEditor.kt:156–161` exclusion,
`:187–256` `buildReferencedByMap` + `computeAncestors` reverse-edge BFS). `ObjectLocation.className`
is kzen-lib-common (`ObjectLocation.kt:26–27`) — usable from JS.

**Deprecated archetypes (item 4) — grep executed now, full results:**

Searched: all of kzen-auto (every source set + all notation yaml, incl.
`kzen-auto-test/**` and both extra `notation/main` dirs under kzen-auto-test), the user's
working documents `kzen-auto-jvm/src/main/resources/notation/main/**` (read-only), and the
downstream `../kzen-project` (read-only). `work/`/`logs/` contain no yaml. Complete hit list:

| Hit | Kind |
|---|---|
| `script-jvm.yaml:79–91` | `ArgumentStep` archetype block (deprecation comment :79–80) |
| `script-jvm.yaml:344–353` | `ForEachItemStep` archetype block (deprecation comment :344–345; trailing empty `meta:` :352–353) |
| `script-jvm.yaml:57–58` | `ParameterBinding` comment "(replaces the old ArgumentStep)" — prose only |
| `script-js.yaml:225–228` | **`ArgumentStepTool`** ribbon tool (`delegate: ArgumentStep`) — the "deprecated" step is still palette-insertable today |
| `ArgumentStep.kt` (`server/objects/script/step/value/`, 39 lines) | the class, `@Reflect` |
| `ForEachItemStep.kt` (`server/objects/script/step/control/foreach/`, 24 lines) | the class, `@Reflect`, extends `ScriptValueBinding` |
| `script-tree-test.yaml:14–15` (test resource) | `is: ForEachItemStep` — **sole fixture use**, consumed by `ScriptTreeTest` |
| `FlowInputVertex.kt:12` | KDoc **link** `[tech.kzen.auto.server.objects.script.step.value.ArgumentStep]` — would dangle after deletion |
| `ParameterBinding.kt:13–14`, `ForEachItemBinding.kt:20` | prose "(replaces the old …)" — harmless historical mentions |
| `FlowDagTest`-era comment `IterableElementTypeReflectTest.kt:13` | mentions ForEachItemBinding**Test** — not the deprecated class |

**Zero references in any user document** (`notation/main/**` here, kzen-auto-test fixtures,
kzen-project) → per the constituent plan, retirement proceeds; no dated-comment fallback
needed.

**Docs lag (not 8d's to fix):** `docs/js-architecture.md` §3 still describes
`ScriptStoreContext` — superseded by `DocumentBridge`/`DocumentBridgeContext` per
`DocumentBridge.kt:22–27`. See § Out of scope.

## Pre-resolved questions

1. **Registry scoping design (item 3) — owner-provided controller field, not a channel key.**
   New `object StepRowRefRegistryKey : BridgeKey<StepRowRefRegistry>` (no `create()` override),
   instance held as a `ScriptController` field and `provide()`d in `render()` — exactly the
   `ScriptDragStoreKey` shape. **Why not channel-style `create()`:** the bridge is recreated on
   every document-path change (`ProjectController.kt:369–372`) while `ScriptController` — and
   its children `ScriptDependencyOverlay` / `ScriptMoveToArrow`, which subscribe to the
   registry in `componentDidMount` — persist across a *same-archetype* switch. A
   channel-created registry would be a **fresh instance in the fresh bridge**, leaving the
   not-remounted overlay/arrow subscribed to the orphaned old instance (missed row
   registrations → missing polylines/arrow until an unrelated remeasure trigger). A
   controller-field instance is the *same object* re-provided into each fresh bridge, so
   mount-time subscriptions stay valid — the exact semantics `dragStore`/`stepReferenceStore`
   already rely on, and behaviourally identical to today's singleton (React ref-cleanup handles
   row turnover across document switches; cross-archetype switches unmount everything). Key
   file lives in `script/model/` beside the other three keys (they import display-package types
   already — `ScriptDragStoreKey` precedent).
2. **`scriptGutterRow` gets the registry as a parameter** (it's a plain function — no context
   slot). Nullable (`registry: StepRowRefRegistry?`); null skips ref registration (only occurs
   with no bridge upstream, which doesn't happen in practice). `LogicSignatureEditor` installs
   `DocumentBridgeContext` (its contextType slot is free — verified) rather than taking the
   registry as a prop, per the bridge doc's "every per-document class component installs
   exactly this one contextType" convention (`DocumentBridgeContext.kt:8–11`).
3. **TODO (a) — `stateOrNull` verdict: KEEP, delete the TODO line, tighten the comment.** The
   constituent plan's "YAGNI" framing is stale: `StepImageFullscreen.scriptState()` is a real
   consumer that reads outside the observer flow (window-keydown navigation + render during
   teardown), where the throwing `state()` is unsafe and lifecycle-proving would be brittle.
   `CustomStore.stateOrNull()` is the same pattern. Resolution is comment-only — no code
   change, no consumer change.
4. **TODO (b) — DAG-guard semantics: callee-closure ("linked logic documents"), NOT
   document-path nesting.** Folder nesting has nothing to do with the call graph. "Exclude
   self/descendant" concretely means: exclude any candidate document **whose own callee-closure
   reaches the editor's document** — i.e. the editor document's transitive *callers* (the
   documents it is a "descendant" of in the call tree) — because selecting one closes a call
   cycle `D → X → … → D`. Edge definition mirrors `LinkedLogicDocuments` (kzen-auto-jvm — not
   reusable from JS, and 8d's ground rules forbid a kzen-auto-common addition, so a small
   client-local mirror is the decided shape): any attribute whose **metadata** declares
   `is: ObjectLocation` (`attributeMetadata.type?.className == ObjectLocation.className`),
   value resolving via `coalesce.locateOptional` into **another** document whose main is
   `AutoConventions.isLogic` — flavour-agnostic, no step-type names (extensibility rule).
   Reverse-edge BFS from the editor's document, mirroring `SelectObjectEditor.computeAncestors`.
   **Suggestion-filter only**: `LinkedLogicDocuments` records that self/mutual hosting is
   *legal at runtime* (deliberate recursion), and the existing code already suppresses only the
   *suggestion* of self — raw-YAML editing remains the escape hatch, and the currently-set
   value stays rendered even when excluded (step 2b-iv below).
5. **TODO (c) — RPureComponent conversion: conditional, gate specified** in § Dependencies.
   When implemented here: base-class swap + a value-equality guard in `updateOptions()`
   (fresh `List` per notation event would otherwise defeat the shallow-equal — and, worse,
   make the conversion a no-op). The `componentDidUpdate` commit flow is safe under
   `shouldComponentUpdate`: every meaningful transition (`value` change, `renaming` flip)
   changes state, so only true no-op updates are skipped.
6. **Archetype retirement verdict: GO** (grep recorded above; zero user-notation references
   anywhere reachable). Follows the Flow-retirement precedent (clean removal, no compat
   archetype — architecture.md Flow note). A hypothetical stray document on another machine
   would surface a definition error for that one object and is recoverable via the raw-YAML
   editor. The `ScriptTreeTest` fixture is modernized minimally (step 4d) rather than
   restructured: swap the body-row `Item` to `BooleanLiteralStep` — same object path, same
   `ScriptStep` parentage, attribute-free — so all five predecessor assertions
   (`ScriptTreeTest.kt:23–52`) hold unchanged (`DivisibleCheckStep.number` is
   `is: ObjectLocation by: Nominal`, `script-jvm.yaml:202–204` — a weak ref, indifferent to
   the target's archetype).

## Step-by-step implementation

Ordered for reviewability: trivial deletions first, then self-contained TODO resolutions, then
the registry move (widest js diff), then the retirement (only cross-module item). Each item is
one commit-sized unit; any can be dropped/deferred without affecting the others.

### Item 1 — delete the debug line

- `script/display/StepDisplayManager.kt:114`: delete the commented-out render-debug line.
  (Optional rider while in the file: fix the malformed divider at :109 — it has a stray
  interior space.)

### Item 2 — TODO resolutions

**2a — `ScriptStore.stateOrNull` (comment-only).** Replace `ScriptStore.kt:201–203` (the
two-line comment + TODO) with a comment stating the decided rationale, e.g.:

```kotlin
// Non-throwing snapshot read (mirrors ClientStateGlobal.current() and CustomStore.stateOrNull),
// for consumers outside the observer flow that can fire before initialization or during
// teardown — e.g. StepImageFullscreen.scriptState() (render + window-keydown navigation).
```

**2b — DAG guard in `SelectLogicEditor.options()`.**

1. Add a private helper (documented as mirroring `LinkedLogicDocuments` + the
   `SelectObjectEditor` ancestors guard, and as a suggestion-filter — cite runtime legality of
   recursion):
   ```kotlin
   private fun ancestorDocuments(
       graphNotation: GraphNotation,
       graphMetadata: GraphMetadata
   ): Set<DocumentPath>
   ```
   Implementation: one pass over `graphNotation.coalesce.map` building a reverse-edge map
   `referencedBy: Map<DocumentPath, MutableSet<DocumentPath>>` — for each object, for each
   attribute whose `graphMetadata.objectMetadata.map[objectLocation]` metadata has
   `type?.className == ObjectLocation.className`: skip blank values; `ObjectReference.parse`
   inside a try/catch; `coalesce.locateOptional`; skip null / same-document targets; require
   `AutoConventions.isLogic(graphNotation, target.documentPath)`; record edge
   `target.documentPath ← objectLocation.documentPath`. Then `ArrayDeque` BFS from
   `props.objectLocation.documentPath` over `referencedBy` (shape of
   `SelectObjectEditor.computeAncestors`, :238–256).
2. In `options()` (:113–135): compute `val excluded = ancestorDocuments(…)` once; replace the
   :117–120 self-check + TODO with
   `if (path == props.objectLocation.documentPath || path in excluded) continue` — covering
   both the `isLogic` branch and the Custom-exported-logic branch (the check is at the top of
   the document loop, before either).
3. `options()` gains the `graphMetadata` it already receives — no signature change needed
   (it takes `(graphNotation, graphMetadata)` today). Both call sites (`init` :109,
   `updateOptions` :209) unchanged.
4. **Preserve the current selection's display**: in `render()` (:252–260), after mapping
   `selectOptions`, if `state.value != null` and no option matches
   `state.value?.asString()`, prepend a `SelectOption` for it (value `asString()`, label
   `documentPath.name.value`). Prevents a pre-existing deliberately-recursive setup from
   rendering as a blank field.

**2c — RPureComponent conversion (run the AE5 gate first — § Dependencies).** If gated in:

1. `SelectLogicEditor.kt:59`: delete the TODO line. `:64`: `RComponent` →
   `RPureComponent` (swap the import at :16).
2. Add the fresh-list guard in `updateOptions()` (:204–211):
   ```kotlin
   val newOptions = options(graphNotation, graphMetadata)
   if (newOptions == state.options) {
       return
   }
   setState { options = newOptions }
   ```
   (Value-equality per js-architecture.md §2 rule 3 — the list is freshly allocated each call,
   so a `===` shallow-equal alone never bails.)

### Item 3 — `StepRowRefRegistry` onto the `DocumentBridge`

1. `script/display/dependency/StepRowRefRegistry.kt`: `object` → `class` (:12). Rewrite the
   :7–11 comment: no longer "process-global singleton / only one Script document open"; now
   "one instance per mounted ScriptController (like ScriptStepDragStore), provided into the
   per-document DocumentBridge under StepRowRefRegistryKey; the same instance is re-provided
   into the fresh bridge on a same-archetype document switch, so mount-time observers stay
   valid; React ref cleanup keeps the map tight as rows unmount." Body unchanged.
2. New `script/model/StepRowRefRegistryKey.kt` (mirror `ScriptDragStoreKey.kt` verbatim
   incl. comment style):
   ```kotlin
   object StepRowRefRegistryKey : BridgeKey<StepRowRefRegistry>
   ```
3. `ScriptController.kt`: add field beside `stepReferenceStore` (:185)
   `private val stepRowRefRegistry = StepRowRefRegistry()` (comment: shared row-rect registry
   for the dependency overlay / move-to arrow / drag insertion); add
   `bridge?.provide(StepRowRefRegistryKey, stepRowRefRegistry)` to the provide block
   (:328–331); update the :366–369 comment's "shared StepRowRefRegistry" wording to
   "bridge-provided StepRowRefRegistry".
4. `ScriptGutterRow.kt`: add parameter
   `scriptGutterRow(rowLocation: ObjectLocation?, registry: StepRowRefRegistry?, gutter, body, trailing = null)`;
   guard the ref block (:30–38) with `if (rowLocation != null && registry != null)`; the ref
   callback and cleanup closure call `registry.register/unregister` (the closure captures the
   instance — correct across bridge swaps since the instance is controller-scoped). Drop the
   now-stale "singleton" wording in the :12–17 header comment.
5. `ScriptBranchDisplay.kt`: add helper beside `dragStore()` (:141–150):
   `private fun rowRegistry(): StepRowRefRegistry? = contextValue<DocumentBridge?>()?.lookup(StepRowRefRegistryKey)`.
   Use it at :472 (`rowRegistry()?.get(stepLocation) ?: continue`) and pass it at :631
   (`scriptGutterRow(stepLocation, rowRegistry(), gutter, body, trailing)`).
6. `LogicSignatureEditor.kt`: add `init { installContextType(DocumentBridgeContext) }`
   (imports: `DocumentBridge`, `DocumentBridgeContext`, `StepRowRefRegistryKey`,
   `tech.kzen.auto.client.wrap.installContextType`/`contextValue` as needed); add the same
   `rowRegistry()` helper; pass it in the :453–456 call.
7. `ScriptDependencyOverlay.kt`: add `init { installContextType(DocumentBridgeContext) }` +
   `rowRegistry()` helper. `componentDidMount` (:71):
   `unsubscribeRegistry = rowRegistry()?.observe { scheduleRemeasure() }` (unmount handling
   :86–93 unchanged — the stored closure unsubscribes the right instance). Reads (:159–161):
   `rowRegistry()?.get(edge.source) ?: continue`, same for target.
8. `ScriptMoveToArrow.kt`: same treatment — `init` + helper; observe at :120; reads at :207
   (`?: return hideArrow()` still types out — `rowRegistry()?.get(x)` is null both when
   unprovided and when unregistered), :266 (`filter { rowRegistry()?.get(it) != null }` —
   hoist `val registry = rowRegistry() ?: return` at the top of `onGlyphPointerDown` to avoid
   per-element lookups), :322, :401 (same hoist pattern where a local is natural).
9. Whole-repo grep `StepRowRefRegistry` afterwards: remaining hits must be the class file, the
   key file, and comments (`ScriptGutterRow` header, `ScriptController:368`,
   `ScriptBranchDisplay:464/:615`, `ScriptMoveToArrow:68` — update wording where it says
   "singleton"; `JobCardRowRegistry`'s "Trimmed from StepRowRefRegistry" note stays, see Out
   of scope).

### Item 4 — retire `ArgumentStep` / `ForEachItemStep`

1. `script-jvm.yaml`: delete the `ArgumentStep` block **:79–91** (incl. the :79–80 deprecation
   comment) and the `ForEachItemStep` block **:344–353** (incl. the :344–345 comment and the
   dangling empty `meta:`); normalize surrounding blank lines. Leave the `ParameterBinding`
   (:57–58) and `ForEachItemBinding` prose mentions as historical text.
2. `script-js.yaml`: delete the `ArgumentStepTool` block **:225–229** (ribbon tool — its
   presence meant the deprecated step was still insertable; removal is part of the point).
   `ScriptGroup_InputOutput` keeps four tools (Boolean/Text literal, Formula, Result).
3. Delete `kzen-auto-jvm/.../server/objects/script/step/value/ArgumentStep.kt` and
   `.../step/control/foreach/ForEachItemStep.kt`. KSP regenerates `KzenAutoJvmModule` without
   them automatically — no hand edit.
4. Test fixture `kzen-auto-jvm/src/test/resources/notation/test/script-tree-test.yaml:14–15`:
   `is: ForEachItemStep` → `is: BooleanLiteralStep` (object path/name `Item` unchanged;
   rationale in Pre-resolved question 6 — `ScriptTreeTest` assertions untouched).
5. `FlowInputVertex.kt:12`: the KDoc link
   `[tech.kzen.auto.server.objects.script.step.value.ArgumentStep]` would dangle — reword to
   reference the live counterpart, e.g. "analogous to a Script parameter
   ([ParameterBinding][tech.kzen.auto.server.objects.script.binding.ParameterBinding]), but as
   a graph vertex".
6. Re-run the item-4 grep (`ArgumentStep|ForEachItemStep`, whole repo): remaining hits must be
   prose-only (`ParameterBinding.kt`, `ForEachItemBinding.kt`).

## Tests

- **No new unit tests.** The js items are UI plumbing with no existing component-test harness
  (jsTest holds only `AsyncTest`/`ClientTest`); coverage is the build gate + selfTest + the
  manual matrix below, per the constituent plan's baseline.
- **Existing tests that must stay green:** `ScriptTreeTest` (fixture edit, assertions
  unchanged); the script-engine suites (all use `ForEachItemBinding`, untouched — verified
  fixture census); `:kzen-auto-jvm:test` wholesale.
- Optional (skip by default — out of 8d's sizing): a selfTest scenario for the DAG guard is
  not warranted for a suggestion-filter; the manual check below suffices.

## Verification

1. `./gradlew :kzen-auto-js:build` — compile gate for items 1–3 (and item 4's yaml is consumed
   at runtime, not compile).
2. `./gradlew :kzen-auto-jvm:test` — item 4 (ScriptTreeTest + engine suites; also proves the
   deleted classes had no lingering compile references).
3. `./gradlew :kzen-auto-test:selfTest` — end-to-end (Script feature drives steps, screenshots,
   run flow through Chrome).
4. **Manual matrix** (dev loop, constituent-plan baseline + item-specific):
   - Registry (item 3): open a Script with cross-branch dependencies and parameters (e.g.
     `FizzBuzz Script Loop`) — dependency polylines render incl. parameter→step; expand/collapse
     and insert-step still reposition lines; drag/drop reorder across branches unchanged
     (insertion index follows cursor); run → pause: move-to arrow appears, drags, highlights
     candidates; **switch between two Script documents** (same archetype — exercises the
     fresh-bridge/same-instance path): overlay + arrow still track the newly opened document;
     rename-while-open behaves as before.
   - Ribbon (item 4): Script ribbon's Input/Output group no longer offers "Argument"; existing
     documents (`Script.yaml`, FizzBuzz set) load and run unchanged.
   - DAG guard (2b): scratch Scripts A→B (RunStep in A calls B): in **B**, add a RunStep — its
     instructions dropdown must not offer A (caller) nor B (self) but still offers unrelated
     scripts; in **A**, the dropdown still offers B and the existing selection still displays.
     Delete the scratch documents afterwards (do not disturb the user's working docs).
   - RPure conversion (2c, if executed): editing unrelated notation (e.g. rename an unrelated
     document) no longer re-renders the RunStep select (React DevTools highlight-updates);
     select + launch button + rename-follow (rename the callee document → selection tracks, no
     echo write) unchanged.
5. Mark the 8d checkbox in `2026-07-16_script-client-sweep.md` (:19) and append an as-built
   note on any deviation (notably the stateOrNull keep-verdict).

## Risks & gotchas

- **Channel-vs-provide trap (item 3).** If someone "simplifies" the key to a `create()`
  channel, same-archetype document switches silently break overlay/arrow re-measure (stale
  subscription to the orphaned bridge's instance) — the failure is intermittent-looking
  (ResizeObserver/ClientState publishes mask it). The key must stay owner-provided with a
  controller-field instance. This is also why the observe-in-`componentDidMount` pattern is
  safe here and must not be "fixed" to re-resolve per publish.
- **Ref-callback churn:** `scriptGutterRow` creates a fresh callback ref each render (React 19
  cleanup semantics) — pre-existing behaviour, unchanged by the parameter; don't try to
  stabilize it in this item.
- **`rowRegistry()` returning null** hides rows from overlay/arrow/drag rather than crashing —
  acceptable degenerate (no bridge upstream never happens under `ProjectController`); don't
  add `error()` throws in render paths.
- **2b cost:** `ancestorDocuments` runs per notation event (via `updateOptions`) — one pass
  over all objects' attribute metadata + BFS; same order as the existing `isLogic`-per-document
  scan in `options()`. If profiling ever flags it, memoize per notation identity — do not
  pre-optimize now.
- **2b correctness edge:** the metadata lookup must use `coalesce` object metadata
  (`graphMetadata.objectMetadata.map[objectLocation]`) with missing-metadata objects skipped —
  mid-edit broken documents must not throw (mirror `LinkedLogicDocuments`' best-effort
  `resolveLink`, incl. the try/catch around `ObjectReference.parse`).
- **2c without the equality guard** is worse than not converting (adds `shouldComponentUpdate`
  overhead while every notation event still re-renders via the fresh list). The guard is part
  of the conversion, not optional.
- **Item 4 is load-order sensitive in review only**: yaml block deletions must take the whole
  block incl. its deprecation comment (a stranded comment above `BooleanLiteralStep` /
  `DoWhileStep` would mislabel them as deprecated).
- **Stray third-party documents** referencing the retired archetypes (none found anywhere
  reachable) would show a definition error on that object after upgrade — raw-YAML edit is the
  recovery; consistent with the Flow retirement precedent. Do not add a compat archetype.
- **File safety:** the `notation/main/**` inspection was read-only; nothing there is touched by
  this plan. Scratch documents created during manual verification must be deleted via the UI.

## Out of scope

- `JobCardRowRegistry` — the Job-document sibling singleton (same pattern, no observe
  machinery). Scoping it through the bridge is a Job-plan concern (J-series); its "Trimmed from
  StepRowRefRegistry" comment stays accurate.
- `ViewModeKey` subscription staleness: `ScriptController` subscribes to the bridge's
  `ViewModeKey` channel in `componentDidMount` (:211) and never re-subscribes on a
  same-archetype bridge swap — a channel (bridge-lifetime) key, so the Raw-tab signal from the
  *new* bridge's ribbon may not reach a persisted controller. Pre-existing, orthogonal to 8d
  (observed while designing item 3); if confirmed reproducible, file under the AE/8b follow-ups
  rather than widening this session.
- `docs/js-architecture.md` §3's stale `ScriptStoreContext` description (superseded by
  `DocumentBridge`) — doc refresh belongs to whichever session next touches that doc's subject
  matter wholesale, not this hygiene pass.
- AE5's `SelectReferenceEditorBase` migration itself (only the narrow RPureComponent TODO is
  conditionally handled here).
- Any 8a/8b/8c content (hot-path memoization, display dedup, notation-driven branch discovery).
- `ScriptStore.state()`'s throwing contract and other stores' `stateOrNull` siblings — no
  harmonization pass.
