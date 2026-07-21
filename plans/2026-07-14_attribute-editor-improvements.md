# Attribute-editor improvements — consolidate the kzen-auto-js editor landscape — phased plan

> **Status: ✅ COMPLETE 2026-07-20** (all six phases; see the tracker below for as-built notes).
> Written 2026-07-14 from a full catalogue of the ~35 attribute-editor files
> in kzen-auto-js (three parallel exploration sweeps, findings verified against source). The
> target architecture already exists — the notation-driven `AttributeEditorManager` (`editor:`
> metadata key → autowired `is: AttributeEditor` wrapper resolved by object name, hard fallback
> `DefaultAttributeEditor`) is live for Script, Job, Flow, and Custom — so this plan is pure
> consolidation around it: retire the legacy fork, extract the copied commit plumbing, compose
> instead of re-implement the leaf renders, and share the select-of-reference skeleton. **No
> feature work.** Each phase is self-contained (goal, pre-made decisions — do not re-litigate,
> concrete steps with file anchors, verification) and independently landable; execute one phase
> per session, in order 1 → 2 → 3 → 4 → 5 → 6 (6 is optional).
>
> Companion seams (reconciled with the other plans 2026-07-14; file names updated 2026-07-16
> for the Sprint-1 consolidation):
> - **This plan now owns** (supersession notes added in each): the `PluginController` port +
>   `*Old.kt` deletion (was EXT-S7 in `2026-07-06_custom-plugin-extensibility-analysis.md` and a
>   Flow plan FL5 bullet, now `2026-07-16_flow-improvements.md` → phase 1 here); the
>   select-editor "rename-echo dance" shared mixin (was Script plan 8b → phase 5 here) and the
>   `SelectLogicEditor` `RPureComponent` TODO (was Script plan 8d → phase 5 here) — the Script
>   client sweep now lives in `2026-07-16_script-client-sweep.md`.
> - **Stays elsewhere**: the Job↔Report spec-editor duplication (`FormulaMapEditor` ↔
>   `FormulaItemController`, `ValueSetFilterEditor` ↔ `FilterItemController`, Pivot/Export
>   pairs) — `2026-07-16_job-improvements.md`'s Report-subsumption arc (J2–J4/J9); the
>   add-affordance widget generalization + the spec editors' observer-guard base — Job plan
>   phase 8 item 4 (which builds on phases 3/5 here — prefer AE3+AE5 first); the Script-specific
>   predecessor/binding scope helper — script-sweep 8b (it feeds phase 5's `selectOptions()`
>   hook). Phase 3 deliberately stops at these seams (see its `FormulaMapRow` note).
>
> **Progress tracker** (update as phases land; add ✓ + date + as-built notes):
> - [x] Phase 1 — retire the `flow/edit/*Old.kt` fork (5 files + dead registrations) ✅ **2026-07-19**
>   — as-built: the `common-js.yaml` Old block was :57–81 (not :60–78); `PluginController`
>   migrated to `TextAttributeEditor` reading the value via the **nullable `AttributePath`**
>   overload of `firstAttribute` (the `AttributeName` overload throws on missing). Verified by
>   full `./gradlew build` (green, incl. `:kzen-auto-jvm:test`) plus headless-Chrome DOM dumps
>   of a Plugin / Script / Flow document (field renders pre-filled, zero console errors).
>   Interactive typing/blur-flush smoke still owed (needs a browser).
> - [x] Phase 2 — `SelectClosePolicyEditor` → `SelectValuesEditor` + `values:` metadata ✅ **2026-07-20**
>   — as-built: landed exactly as planned (166-line editor deleted, `values:` map under
>   `ResourceClosePolicy.meta.ref`, JS registration removed, 4 comment references updated).
>   **D7 correction**: the label renders **"ClosePolicy"**, not "Close Policy" —
>   `CommonEditUtils.formattedLabel` splits on non-word characters only, never camel humps; the
>   decision's substance (drop the hardcoded string, accept the standard label) stands, and
>   camel-hump splitting remains out of scope (it would change every default label app-wide).
>   Verified by full `./gradlew build` (green) plus a throwaway `NotationMetadataReader` probe
>   (since deleted) proving the `values:` map reaches `BrowserOpenStep.closePolicy`'s merged
>   `attributeMetadataNotation` through the **`meta.ref` inheritance path** — merged keys
>   `[by, editor, values, is]`, `editor = SelectValuesEditor`, all 7 entries in enum order with
>   em-dashes intact end-to-end (first non-ASCII bytes in bundled notation; file is UTF-8, no
>   BOM). Browser smoke (render/select/no-echo-write) still owed — needs the user.
> - [x] Phase 3 — shared commit primitive (`DebouncedSubmitter` / `AttributeCommitter`) + field-local
>   error capture — **done 2026-07-20**, as planned across all 8 adopters. Two shape corrections the
>   elaboration had already flagged: `KotlinExpressionEditor` is scalar-shaped (the map-shaped submit
>   in the table above is `TargetSpecEditor`), and `JobChannelNumberField` is **not** "same swap as
>   Text" — its four command shapes (`Remove`/`Upsert`/`UpdateIn`/`InsertMapEntry`) can't route
>   through `editCommand`, so it takes `DebouncedSubmitter` + a shared
>   `CommonEditUtils.applyCommand(store, command): String?` helper (added this phase; it is where the
>   `message ?: toString()` extraction lives, so `AttributeCommitter` and command-shaped editors share
>   one implementation). `commitNow` carries an explicit-value overload for event-carried values
>   (Boolean/Select toggles, reference insertion) that aren't yet readable from React state.
>   `muiAutocompleteField` gained an additive `error: Boolean = false`. `TargetSpecEditor` dropped its
>   local `submitDebounceMillis` const — the kernel's `defaultDelayMillis` owns the 1000 ms.
>   Verified by full `./gradlew build` (green, zero warnings) + 5 new `AttributeCommitterTest` cases
>   passing under ChromeHeadless. Residue after the phase is exactly the expected non-adopters:
>   `AttributePathValueEditor` (Phase 4 deletes it — the last `// TODO: handle error`), 4 Report-seam
>   debounces, 2 `ClientLogicGlobal` transport debounces. Manual browser matrix still owed —
>   needs the user.
> - [x] Phase 4 — merge `AttributePathValueEditor` into `DefaultAttributeEditor`, composing the leaf editors
>   ✅ **2026-07-20** — as-built: landed as planned (395-line editor deleted; `isValue` → `CommonEditUtils.isValueType`;
>   `DefaultAttributeEditor` now derives the value **at render** from the `attributeNotation` it already held, so the
>   duplicate `ClientStateGlobal` subscription and the value/values state are both gone, and the last hand-rolled
>   `lodash.debounce` + `// TODO: handle error` copy with them). Three amendments to the phase text:
>   **(a)** the hygiene rider went further than "trim `disabled`/`invalid`/`labelOverride`, keep `onChange`" —
>   verified `AttributeEditorManager` sets *only* `objectLocation` + `attributeName`, so `onChange` was dead too;
>   **`AutoAttributeEditorProps` is deleted outright** (user decision this session) and the component is typed on
>   `AttributeEditorProps` directly. That also deleted `formattedLabel()` — with no `labelOverride` to forward, each
>   leaf editor's own `CommonEditUtils.formattedLabel(attributePath, null)` yields the identical string (confirmed in
>   the DOM: "Name" / "Note" / "Enabled" / "Aliases (one per line)"), and it sidesteps `BooleanAttributeEditor`
>   having no plain `labelOverride` prop (only `true`/`falseLabelOverride`). Nothing is passed down but location,
>   path, value and the store. **(b)** `renderValueEditor`'s `type: TypeMetadata` parameter had to be renamed
>   **`valueType`** — inside `TextAttributeEditor::class.react { … }`, `type = …` resolves to the shadowing `val`
>   parameter, not the prop (val-reassignment compile error). **(c)** the dead `componentDidUpdate` →
>   `state.init(props)` was removed: `init` was never overridden, so it called the empty `open fun` on
>   `RPureComponent`. `AutoAttributeEditorState` renamed `DefaultAttributeEditorState`.
>   Verified: `cd ../kzen-auto && ./gradlew build` green with zero warnings (the real gate — the whole change lives
>   in kzen-auto-js; a cross-sibling grep confirms no other repo names these types), plus the umbrella's five
>   `:<sibling>:build` tasks green. **Gotcha worth recording: `./gradlew build` from the umbrella root does NOT
>   build anything** — the root has no `build` task, so Gradle abbreviation-matches it to `buildEnvironment` and
>   exits 0 in ~11 s. Use `cd ../<sibling> && ./gradlew build`, or name the included builds explicitly.
>   `:kzen-auto-test:selfTest` green; **headless-Chrome DOM dump** of a scratch Custom document exercising all four
>   branches at once (`name` String → `<input type=text value=world>`, `note` multiline String → `<textarea>` with
>   both lines, `enabled` Boolean → `<input role=switch checked>`, `aliases` List-of-String → `<textarea>`
>   named `… - aliases` with both entries) — every field **pre-filled**, zero console errors, and the notation file
>   byte-identical afterwards (**no echo write on mount**). Manual browser matrix still owed — needs the user:
>   Script/Flow/Job *hosts* (their step/vertex/worker bodies only render editors once expanded, which headless
>   can't click), the debounce race, and the D2 immediate-Boolean-commit confirmation.
> - [x] Phase 5 — select-of-reference family on a shared base (5 editors, identities preserved)
>   ✅ **2026-07-20** — as-built: `common/edit/select/SelectReferenceEditorBase.kt` (191 lines) now backs all five;
>   every class name, nested `Wrapper`, `editor:` marker and `*-js.yaml` registration is untouched. Net across the
>   five editors **1461 → 1016 lines**. Two design amendments, both decided with the user before starting:
>   **(a) the base's ONLY write path is `selectAndCommit`, reached from the field's `onSelect`.** The phase text
>   kept the `componentDidUpdate` commit with a `hydrated` flag; in practice that mechanism *conflates* "the user
>   picked this" with "the notation moved underneath us", which is why every editor carried ad-hoc
>   `renaming`/`initialized` guards — and `SelectStepEditor` re-hydrates on every `onClientState`, so an external
>   edit (raw editor, second client) round-tripped straight back out as a redundant Upsert. Hydration and rename
>   now go through `setSelected`, which never writes. **`renaming`, `initialized`/`hydrated` and all five
>   `componentDidUpdate` overrides are gone**, the phase's stated echo-write risk is closed by construction, and
>   the family gains field-local error capture (it previously discarded `apply`'s result everywhere) by reusing
>   AE3's `AttributeCommitter` explicit-value `commitNow`.
>   **(b) the `V` type parameter collapsed to nothing.** The base stores the *option key* (`SelectOption.value`)
>   and each subclass maps key→wire only in `wireValue(optionKey)`, so all four crop policies fit without a typed
>   value param; the `ObjectLocation` domain stays subclass-local. Final shape is
>   `SelectReferenceEditorBase<P: AttributeEditorProps, S: SelectReferenceEditorState>` — `P` earns its keep via
>   `SelectLogicEditor`'s `navigationGlobal`, `S` via `SelectObjectEditor`'s `constraintMissing`.
>   Mechanics worth carrying: this is the codebase's **first abstract React component base** (there were zero, and
>   zero `super.` calls) — it works, and it avoids `super` discipline entirely by making `componentDidMount`/
>   `WillUnmount` **final** and delegating to `onMount()`/`onUnmount()` hooks. The base deliberately declares **no
>   `S.init`**, which lets Channel/Object/Logic keep synchronous hydration (no first-paint flash) and dodges
>   calling an open member from a constructor. `setOptions` content-compares because `SelectOption` is an external
>   interface and `Array` equality is by reference — without it `RPureComponent`'s shallow bail-out is defeated on
>   every recompute. **A latent bug found and avoided:** in a property initializer a constructor parameter
>   *shadows* the inherited `props` member, so the base uses `this.props` in its committer lambdas — bare `props`
>   would pin the first render's props object for the component's life (these editors outlive a rename of their
>   own host). **The 8 AE3 adopters all use bare `props` and have this latent pin** — see the note under Phase 3.
>   `SelectLogicEditor`'s `// TODO: convert to RPureComponent` is resolved (Channel/Object/Logic all move
>   `RComponent` → `RPureComponent`); `SelectEnclosingLoopEditor` keeps `defaultApplied` + plain-field mirrors and
>   now performs its one-shot pre-fill as an explicit `selectAndCommit`.
>   Verified: `./gradlew build` in kzen-auto green with zero Kotlin warnings; `:kzen-auto-test:selfTest` green;
>   **headless-Chrome DOM dump** of a scratch Custom document with two `SelectObjectEditor` instances — the bound
>   one renders `value="DefaultGreeter"` **pre-selected**, the unset abstract prototype renders `value=""`, both
>   labelled "Named", zero console errors, zero server errors, and the notation file **MD5-identical afterwards
>   (no echo write on mount)**. Manual browser matrix still owed — needs the user (the Script/Job/Flow hosts only
>   render editors once a card is expanded, which headless can't click).
> - [x] Phase 6 (optional) — hygiene: manager-lookup helper; rename-editor scaffolding
>   ✅ **2026-07-20 — PLAN COMPLETE** — as-built: item 1 landed with **wider reach than planned**,
>   item 2 **dropped on a finding**, and Phase 3's parked follow-up **closed here**.
>   **(a)** The metadata read was duplicated **4×, not 2×**: besides the two managers,
>   `ScriptStepDisplayDefault.findSummaryAttributes` and `WorkerDisplayDefault.renderAttributeSummaries`
>   each inlined `attributeMetadataNotation.get(summaryAttributePath.toNesting())?.asString()` to decide
>   whether an attribute has a summary view. New `common/attribute/AttributeWrapperLookup.kt` (57 lines)
>   now owns **both keys and the read**, with two overloads — one from an already-resolved
>   `AttributeMetadata` (the two iteration sites), one from `GraphStructure` (the two managers) — and all
>   four adopted. Both return **null for a blank value**, which unified the two shapes in the tree (the
>   managers took the string verbatim, the display sites additionally required `isNotEmpty()`); accepted
>   delta: `editor: ""` now falls back to `DefaultAttributeEditor` instead of rendering
>   `[Attribute editor not found: ]`. The abstract-base variant was **considered and rejected** — 6
>   abstract members for 2 subclasses, against AE5's base which backs 5. Rider: `AttributeEditorManagerProps`
>   stopped extending `AttributeEditorProps` (it inherited a `mirroredGraphStore` **no host ever sets** —
>   every call site passes exactly `objectLocation` + `attributeName`) and declares its own dispatch
>   contract; `AttributeViewManagerProps` had no dead field and was left alone.
>   **(b) Item 2 dropped, deliberately.** Its premise is partly false: `StepNameEditor` has **no text
>   field** — it renders a reader and embeds `ObjectNameEditor`. The real pair is
>   `ObjectNameEditor` ↔ `DocumentNameEditor`, which share the TextField + Cancel/Save IconButtons +
>   `handleEnterAndEscape` + `isModified()` but diverge in container (inline `float:right` with
>   −3em/−0.5em negative margins vs. a flex row inside a `Popover`). Lifting the render needs either
>   `sx`-offset parameters (a leaky abstraction) or converting ObjectNameEditor to flex — a **visual
>   change, not hygiene**. Recorded rather than built; revisit only if that layout is being touched anyway.
>   **(c) Phase 3's pinned-`props` follow-up is CLOSED** (see the note under Phase 3): bare `props` →
>   `this.props` in the `AttributeCommitter` property-initializer lambdas of `TextAttributeEditor`,
>   `MultiTextAttributeEditor`, `BooleanAttributeEditor`, `SelectAttributeEditor`,
>   `KotlinExpressionEditor`, `TargetSpecEditor`, with the explanatory comment written once (in
>   `TextAttributeEditor`) and referenced from the other five. `FormulaMapRow` / `JobChannelNumberField`
>   were **not** affected — their `DebouncedSubmitter { onSubmitEdit() }` lambdas call an instance method,
>   so props are read live. Renaming the constructor parameter (the structural alternative) was rejected:
>   it would diverge from ~100 other components for no gain over AE5's `this.props` idiom.
>   **New test**: `kzen-auto-js/src/jsTest/.../AttributeWrapperLookupTest.kt` — 6 cases over a synthetic
>   YAML fixture (`MapNotationMedia` + `DirectGraphStore.graphStructure()`), including the **`meta.ref`
>   inheritance path** that AE2 could only prove with a throwaway probe. `NotationMetadataReader` resolves
>   from notation alone (no Kotlin classes) and degrades dangling type refs to `Any`, so the fixture is
>   self-contained. The `async {}` test idiom was **negative-controlled** — a deliberately wrong expectation
>   was confirmed to FAIL the suite before restoring it, so these assertions are not silently swallowed.
>   Verified: `cd ../kzen-auto && ./gradlew build` green with zero Kotlin warnings (12/12 jsTest cases under
>   ChromeHeadless); `:kzen-auto-test:selfTest` green; **headless-Chrome DOM dumps** against the bundled
>   notation on a throwaway port — `main/Custom.yaml` renders 4 `SelectObjectEditor`s (the two bound ones
>   pre-selected `DefaultGreeter`, the two abstract prototypes empty, all labelled "Named") plus
>   `DefaultGreeter.name` pre-filled "world", with **zero** `[Attribute editor not found]` markers;
>   `main/Script.yaml` and `main/FizzBuzz/FizzBuzz Script Loop.yaml` render collapsed-header summary rows
>   (`location: …`, `from: 1`, `to: 100`, `code: 1..200` via `TextAttributeView`) and the RunStep's
>   `ReferenceLinkAttributeView` drill-in link — i.e. all four call sites but the Job one exercised end to
>   end; zero console errors, zero server errors, and the three notation files **MD5-identical afterwards**.
>   Owed (folded into the existing smoke-debt session, no new debt): a **Job** worker card's summary row
>   (the fourth call site needs an expanded card headless can't click) and one debounce-then-rename race to
>   confirm the `this.props` sweep left the flush-before-rename ordering intact.

## Context

All paths below are under
`kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/` (client) and
`kzen-auto/kzen-auto-jvm/src/main/resources/notation/` (notation) unless said otherwise.

### The architecture that stays

- `common/attribute/AttributeEditor.kt` — abstract `ReactWrapper<AttributeEditorProps>`;
  `name()` = the wrapper's notation object name. Every selectable editor is a distinct
  `is: AttributeEditor` notation object with a `@Reflect` nested `Wrapper`.
- `common/attribute/AttributeEditorManager.kt` — reads the `editor:` key from the attribute's
  `AttributeMetadata.attributeMetadataNotation` (`editorAttributePath`, :39), resolves the
  wrapper by name from the autowired `List<AttributeEditor>`, falls back to
  `DefaultAttributeEditor.wrapperName`. Only `objectLocation` + `attributeName` cross the
  boundary — all editor richness (options, multiline, values) is read from metadata notation by
  the editor itself.
- Registrations (`is: AttributeEditor`) live in `auto-js/document/common-js.yaml` (Default,
  SelectObject), `script-js.yaml` (SelectStep, KotlinExpression, SelectLogic, RunStepArguments,
  TargetSpec, SelectClosePolicy, SelectEnclosingLoop, SelectValues), `job-js.yaml`
  (SelectChannel, FormulaMap, SortSpec, ExportSpec, MultiFileInput, ValueSetFilter, PivotSpec).
  `editor:` markers live server-side: `auto-jvm/script/script-jvm.yaml`,
  `auto-jvm/job/job-worker.yaml` (~20× SelectChannelEditor), `auto-jvm/query/flow-vertex.yaml`,
  `auto-common/common-action.yaml` (TargetSpecEditor), `main/Custom.yaml` (SelectObjectEditor).
  The mapping is a **string-name contract** resolved at runtime — this is the open-set
  third-party-extension seam and must survive every phase.
- Manager hosts: `ScriptStepDisplayDefault`, `RunStepDisplay`, `If`/`DoWhile`/`ForEach` step
  displays (hardcode the attribute *name*, but the editor is still notation-selected), Job
  `WorkerDisplayDefault` + Preview/Summary/Explore, Flow `VertexController`/`CellController`,
  Custom `CustomObject`.
- Direct (non-manager) consumers of the leaf editors, value-via-props style: Report controllers
  (`OutputExportController`, `OutputTableController`, `ReportOutputController`,
  `ReportPreviewController`, `FilterItemController`, `AnalysisFlatController`) and Job's
  `ExportSpecEditor`/`ValueSetFilterEditor`. This direct usage is legitimate and stays.

### The duplication being removed

1. **Full legacy fork** — `flow/edit/AttributeEditorOld.kt`, `AttributeEditorPropsOld.kt`,
   `AttributeEditorManagerOld.kt`, `AttributePathValueEditorOld.kt`,
   `DefaultAttributeEditorOld.kt`: a pre-refactor copy of the entire `common/attribute/` stack
   (clientState pushed via props instead of self-subscribing). Registered at
   `common-js.yaml:60–78`; `AttributeEditorManagerOld` has **no** host (dead registration); the
   sole live consumer is `plugin/PluginController.kt:212` (`AttributePathValueEditorOld` for the
   jar-path field).
2. **Commit plumbing copied 8×** — the `lodash.debounce(…, 1000)` + flush-on-blur/unmount +
   `CommonEditUtils.editCommand` → `mirroredGraphStore.apply` + `// TODO: handle error` idiom is
   hand-rolled in `TextAttributeEditor`, `MultiTextAttributeEditor`, `AttributePathValueEditor`,
   `TargetSpecEditor`, `KotlinExpressionEditor`, `job/edit/FormulaMapRow`,
   `job/JobChannelNumberField`, and `AttributePathValueEditorOld`.
3. **Leaf renders re-implemented** — `common/AttributePathValueEditor.kt` internally duplicates
   the TextField (:297), Switch (:336), and one-per-line list (:366) renders that
   `TextAttributeEditor` / `BooleanAttributeEditor` / `MultiTextAttributeEditor` already
   provide. Its only consumer is `DefaultAttributeEditor.renderValueEditor` (:176–203).
4. **Select-of-reference family ×5** — `common/edit/SelectObjectEditor`,
   `script/display/edit/SelectStepEditor`, `SelectEnclosingLoopEditor`, `SelectLogicEditor`,
   `job/edit/SelectChannelEditor` all repeat the same skeleton: hydrate current value from
   notation → autocomplete over computed candidates → `renaming` flag on refactor events →
   echo-suppressed cropped-reference `UpsertAttributeCommand` via `componentDidUpdate`. Real
   per-editor variation: candidate source (graph scan + DAG-ancestor exclusion / ScriptStore
   predecessors / enclosing loops / logic documents / channel `ObjectPath`s), crop policy
   (same-doc crop / always-crop / full reference / raw string), rename-event handling, and
   `SelectLogicEditor`'s launch button + `navigationGlobal`.
5. **Hardcoded enum select** — `script/display/edit/SelectClosePolicyEditor` is a bespoke copy
   of what the notation-driven `SelectValuesEditor` (options from `meta.<attr>.values` map) does
   declaratively; the code comment in SelectValuesEditor names this replacement intent. Single
   marker: `script-jvm.yaml:19` (type-level, `ResourceClosePolicy.meta.ref`).
6. **Error handling** — the shared editors are fire-and-forget. Not silent: any non-suppressed
   command failure hits the global red banner (`ProjectController.onCommandFailure`, :333–349 /
   :625–636). The gap is *field-local* feedback only.
7. **Near-twins / scaffolding** — `AttributeEditorManager` vs `AttributeViewManager` (same
   lookup, different metadata key `summary:`); three rename editors
   (`ObjectNameEditor`/`StepNameEditor`/sidebar `DocumentNameEditor`) share Enter/Escape +
   save/cancel shape via `ClientInputUtils`.

## Ground rules

- **Consolidate plumbing, not editor identity.** Every editor remains a distinct
  `is: AttributeEditor` notation object; the `editor:` string contract and `*-js.yaml`
  registrations change only where a phase explicitly says so (Phase 2's single marker). No
  god-objects: no per-editor branches in shared code, no Worker/Step/Vertex-specific keys in
  general components.
- **The debounce race invariant is documented behaviour**: pending edits flush on blur AND on
  unmount so a following command (e.g. a step rename) is sequenced after the write. Every
  adopter of the new primitive must keep both wirings (the comment in `TextAttributeEditor:173`
  / `AttributePathValueEditor:325` explains why).
- **`onChange` ordering is load-bearing**: callbacks fire after `mirroredGraphStore.apply` and
  trigger server recompute (Report `onRefresh`/`onPreviewRefresh`, Plugin `loadInfo`).
- Class-component idiom (`RComponent`/`RPureComponent` from `wrap/React.kt`) — no hooks/FCs.
- KSP regenerates module registration on build; deleting a `@Reflect` wrapper needs no manual
  codegen edit, but its yaml registration must go in the same phase or boot fails on a missing
  class.
- File safety: verification inspects documents under `notation/main/` **read-only**; never
  modify/delete user files there.
- Verification baseline per phase — **all of these run from `../kzen-auto`, never from the umbrella**
  (`./gradlew build` at the `kzen/` root abbreviates to `buildEnvironment` and exits 0 having compiled
  nothing; `:kzen-auto:build` from there reaches only the source-less root project — found and
  documented in AGENTS.md during phase 4): `./gradlew :kzen-auto-js:build -x test` (KSP + compile),
  then full `./gradlew build`; manual UI matrix via
  `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` (JS has no component unit tests);
  `./gradlew :kzen-auto-test:selfTest` after phases 2, 3, 5.

## Decisions (pre-made 2026-07-14 — do not re-litigate)

| # | Decision |
|---|----------|
| D1 | Phase 4 **merges** `AttributePathValueEditor` into `DefaultAttributeEditor` (single consumer; deletes a layer and a duplicate `ClientStateGlobal` subscription) rather than keeping it as a composing wrapper. |
| D2 | Boolean toggles commit **immediately** after Phase 4 (the 1s debounce via PathValue was an accident of shared plumbing). Accepted behaviour change. |
| D3 | `onCommitted`/`onChange` fires **only on successful apply** (today: unconditional). Sole observable delta: PluginController's jar listing won't refresh after a failed write. Accepted. |
| D4 | Error surfacing: keep the global banner authoritative (no `suppressErrorDisplay`); the new `onError` hook is **additive** field-local feedback. |
| D5 | `SelectEnclosingLoopEditor` **is** included in the Phase 5 base migration, done **last** (its one-shot pre-fill is the most delicate member; recently hand-tuned for continue/break). |
| D6 | Phase 6 hygiene items are in scope, as an optional final phase executed only if 1–5 land smoothly. |
| D7 | Close-policy label becomes "Close Policy" (standard `formattedLabel`). Accepted. |

---

## Phase 1 — Retire the `flow/edit/*Old.kt` fork

**Goal:** delete the 5-file legacy stack and its registrations; migrate the one live consumer.

**Steps:**

1. Migrate `plugin/PluginController.kt` `renderPathEditor` (:211–227) from
   `AttributePathValueEditorOld` to **`TextAttributeEditor`** (NOT the current
   `AttributePathValueEditor` — Phase 4 deletes it, so routing through it would be throwaway).
   The controller already observes `ClientStateGlobal` and holds `state.clientState`, so it
   supplies the leaf-editor contract's `value` itself:
   ```kotlin
   val jarPath = clientState.graphStructure().graphNotation
       .firstAttribute(mainObjectLocation, PluginConventions.jarPathAttributeName)
       ?.asString() ?: ""
   TextAttributeEditor::class.react {
       objectLocation = mainObjectLocation
       attributePath = PluginConventions.jarPathAttributeName.asAttributePath()
       value = jarPath
       labelOverride = "Plugin Jar File Path"
       onChange = { loadInfo() }
       mirroredGraphStore = props.mirroredGraphStore
   }
   ```
   (The old `valueType = TypeMetadata.long` was a latent oddity — a jar path is a String and
   `long` rendered as a plain text field anyway; moot after migration.)
2. Delete 5 files under `flow/edit/`: `AttributeEditorOld.kt`, `AttributeEditorPropsOld.kt`,
   `AttributeEditorManagerOld.kt`, `AttributePathValueEditorOld.kt`,
   `DefaultAttributeEditorOld.kt`.
3. Remove the Old block from `auto-js/document/common-js.yaml` (:60–78: the
   `AttributeEditorManagerOld` / `AttributeEditorOld` / `DefaultAttributeEditorOld` objects plus
   their section divider).

**Verify:** build gate; grep jsMain + notation for `EditorOld`/`ManagerOld` residue (expect only
`docs/js-architecture.md` history mentions); FrontendDevelopment → Plugin document → edit jar
path: debounced persist, listing refresh on change, and the blur-immediately race check (type →
click elsewhere at once → confirm the value landed).

## Phase 2 — `SelectClosePolicyEditor` → `SelectValuesEditor` + `values:` metadata

**Goal:** prove the declarative-enum mechanism by deleting the one hardcoded-enum editor.

**Steps:**

1. `auto-jvm/script/script-jvm.yaml` (:13–19, the type-level `ResourceClosePolicy` object):
   change `editor: SelectClosePolicyEditor` → `editor: SelectValuesEditor` and add the labels
   (keys verified against kzen-lib `ResourceClosePolicy.key` — note `parent`, not
   `parentDocument`; labels carried verbatim from `SelectClosePolicyEditor.optionLabel`
   :62–85):
   ```yaml
   ResourceClosePolicy:
     abstract: true
     class: tech.kzen.lib.common.exec.logic.ResourceClosePolicy
     meta:
       ref:
         by: ResourceClosePolicyDefiner
         editor: SelectValuesEditor
         values:
           auto: "Auto — close when the run finishes (success, failure, or cancel)"
           manual: "Manual — keep open; only an explicit close step disposes it"
           keepOnFailure: "Keep on failure — close on success/cancel, keep on a failed run to inspect"
           parent: "Parent — close when the calling Script (one level up) finishes"
           parentKeepOnFailure: "Parent, keep on failure — close when the caller finishes, keep if it failed"
           run: "Run — close when the whole run finishes"
           runKeepOnFailure: "Run, keep on failure — close at run end, keep if the run failed"
   ```
   This rides the same metadata-inheritance path that already delivers `editor:` from the
   type-level `ref` map to every `is: ResourceClosePolicy` attribute (`ScopedResource.meta.closePolicy`),
   so `SelectValuesEditor`'s `attributeMetadataNotation.get("values")` lookup sees it.
2. Delete `script/display/edit/SelectClosePolicyEditor.kt`.
3. Remove its registration block from `auto-js/document/script-js.yaml` (~:153–155).

**Behaviour deltas (accepted):** label "Close policy" → "Close Policy" (D7); `SelectValuesEditor`
compares raw strings (no case-tolerant `ResourceClosePolicy.parse`), so a hand-typed odd-case
value in user notation shows unselected instead of normalized — acceptable power-tool semantics.

**Verify:** FrontendDevelopment → Script → a `ScopedResource` step (e.g. BrowserOpenStep) →
closePolicy dropdown shows the 7 descriptive labels, default `auto` pre-selected, change
persists to yaml (read-only inspect); no echo write on mount (watch the document file's mtime);
`:kzen-auto-test:selfTest` (drives browser-open scripts end-to-end).

## Phase 3 — Shared commit primitive + field-local error capture

**Goal:** one implementation of the debounce/flush/commit/error idiom; adopters shed their
copies mechanically.

**New files** (plain classes — no `@Reflect`, no notation object, no yaml) under
`common/edit/`:

```kotlin
// DebouncedSubmitter.kt — the debounce+flush kernel, usable without command plumbing
class DebouncedSubmitter(
    delayMillis: Int = 1000,
    private val submit: suspend () -> Unit
) {
    private val debounce: FunctionWithDebounce = lodash.debounce({ async { submit() } }, delayMillis)
    fun schedule()      // debounce.apply()
    fun flush()         // debounce.flush() — wire to onBlur AND componentWillUnmount
    fun cancel()
}

// AttributeCommitter.kt — kernel + editCommand + apply + error capture + ordering
class AttributeCommitter(
    private val graphStore: () -> MirroredGraphStore,       // lambdas read props/state at commit time
    private val objectLocation: () -> ObjectLocation,
    private val attributePath: () -> AttributePath,
    private val pendingNotation: () -> AttributeNotation?,  // null = nothing to commit
    private val onCommitted: ((AttributeNotation) -> Unit)? = null,  // AFTER apply, success only (D3)
    private val onError: ((String?) -> Unit)? = null,       // MirroredGraphError message; null on success
    delayMillis: Int = 1000
) {
    fun schedule(); fun flush(); fun cancel()
    suspend fun commitNow()     // also callable directly by immediate-submit editors
}
```

`commitNow()` = `pendingNotation()` (bail on null) → `CommonEditUtils.editCommand(...)` →
`apply(command)` → `(result as? MirroredGraphError)?.error?.message` → `onError(message)` →
`onCommitted(notation)` on success only. **No** `suppressErrorDisplay` (D4).

**Adopters** — one editor per commit for reviewability:

| Editor | Change |
|---|---|
| `common/edit/TextAttributeEditor.kt` | replace `submitDebounce` (:64–68) + `submitEdit` (:124–134); keep `onBlur`/unmount flush; new `errorMessage` state feeds `error = props.invalid || errorMessage != null` |
| `common/edit/MultiTextAttributeEditor.kt` | same swap (:58–62, :111–132) |
| `script/display/edit/KotlinExpressionEditor.kt` | swap debounce block; its map-shaped submit body becomes the `pendingNotation` lambda |
| `script/display/edit/TargetSpecEditor.kt` | swap debounce; immediate-write branches call `commitNow()` |
| `common/edit/BooleanAttributeEditor.kt` | `commitNow()` path only (no debounce), for uniform error capture |
| `common/edit/SelectAttributeEditor.kt` | same |
| `job/JobChannelNumberField.kt` | same swap as Text |
| `job/edit/FormulaMapRow.kt` | **`DebouncedSubmitter` only** — it delegates to `props.onUpdate`, not a command; do not restructure further (Report-subsumption seam) |
| `common/AttributePathValueEditor.kt` | **skip** — deleted in Phase 4 |

Report controllers' own debounce sites (`FormulaItemController`, input controllers) stay
untouched — same seam; they adopt the kernel when Report is subsumed.

**Verify:** build gate; the debounce race (type into a Script step text attribute → immediately
rename the step → confirm the edit landed before the rename in the yaml); Report output
path/format/preview fields still commit and trigger refresh; `AnalysisFlatController`'s real
`invalid` wiring (pattern errors) still renders; force a command failure (e.g. edit an attribute
of a just-deleted object via a stale panel) → global banner still appears, TextField shows error
state where wired. `:kzen-auto-test:selfTest`.

**Follow-up found during Phase 5 — ✅ CLOSED in Phase 6 (2026-07-20):** all 8 AE3 adopters construct their
`AttributeCommitter`/`DebouncedSubmitter` as a **property initializer** whose lambdas read bare
`props` — e.g. `graphStore = { props.mirroredGraphStore }` in `TextAttributeEditor:66-72`. In a
property initializer the primary-constructor parameter **shadows** the inherited `props` member, so
those lambdas capture the *first render's* props object rather than reading the live one, defeating
the "every argument is a lambda, evaluated at commit time" contract in `AttributeCommitter`'s own
KDoc. Field reads are still deferred, but off a pinned object: a component whose `objectLocation`
changes while mounted (the manager re-renders an editor in place after its host is renamed) would
commit to the stale location. Phase 5's base uses `this.props` and is unaffected. Low observed
impact — no bug report traces to it — but the 8 adopters should each get `this.props` in a small
sweep; folding it into the S8 client sweep or a micro-session is fine.
**Closed in Phase 6**, and the count was **6, not 8**: `FormulaMapRow` and `JobChannelNumberField`
pass a method-calling lambda (`DebouncedSubmitter { onSubmitEdit() }`), which reads props live.
**S8 need not pick this up.**

## Phase 4 — Merge `AttributePathValueEditor` into `DefaultAttributeEditor`

**Goal:** delete the middle layer; the fallback editor composes the leaf editors instead of
re-implementing their renders. **Widest blast radius** — `DefaultAttributeEditor` is the
fallback for every document type.

**Steps:**

1. Move `AttributePathValueEditor.isValue(TypeMetadata)` (:70–88) to
   `CommonEditUtils.isValueType` (verified: no other callers of `isValue`).
2. Rework `DefaultAttributeEditor` (`common/attribute/DefaultAttributeEditor.kt`): it already
   self-subscribes and holds `attributeMetadata` + `attributeNotation` in state. Take over the
   `extractValues` Scalar/List/Map `when` (PathValue :153–173; carry the `MapAttributeNotation`
   branch as `TODO()` unchanged) and render leaves in `renderValueEditor`:
   - String/Int/Long/Double → `TextAttributeEditor` with
     `type = if (multiline metadata key) MultilineText else PlainText` — **not** `Type.Number`
     (would add `FormatUtils.decimalSeparator` thousands-separators: behaviour change);
     `labelOverride = formattedLabel()`;
     `onChange = { props.onChange?.invoke(ScalarAttributeNotation(it)) }`.
   - Boolean → `BooleanAttributeEditor` (`value = extracted == "true"`). Commit becomes
     immediate (D2).
   - List/Set-of-primitive → `MultiTextAttributeEditor`
     (`unique = type.className == ClassNames.kotlinSet` — preserves Set-dedup-on-submit).
   - `type == null` / `Self`-definer / non-value branches unchanged (:148–172).
   Round-trip: leaf editors sync from `props.value` in `componentDidUpdate`; Default's
   `onClientState` refreshes `attributeNotation` on store echo — same convergence as today's
   PathValue self-subscription.
3. Delete `common/AttributePathValueEditor.kt`. No yaml change (never a registered editor).
4. Hygiene rider: grep for direct `DefaultAttributeEditor::class.react` call sites; if none,
   trim the dead `AutoAttributeEditorProps` extras `disabled`/`invalid`/`labelOverride`
   (never set through the manager); keep `onChange`.

**Verify:** build gate; manual matrix — Custom document prototype attributes (the primary
metadata-driven consumer: text, multiline, boolean, list), Script step default attributes, Flow
vertex attributes (`VertexController`/`CellController`), Job worker default attributes
(`WorkerDisplayDefault`); debounce-race spot check; `:kzen-auto-test:selfTest`.

## Phase 5 — Select-of-reference family: shared base

**Goal:** one skeleton for the five reference selects; each keeps its notation identity —
**zero `editor:` marker or `*-js.yaml` changes**.

**New** `common/edit/select/SelectReferenceEditorBase.kt`:

```kotlin
external interface SelectReferenceEditorState<V: Any>: State {
    var selected: V?
    var renaming: Boolean
    var hydrated: Boolean   // standardizes SelectStepEditor's 'initialized' echo-write suppression
}

abstract class SelectReferenceEditorBase<V: Any, P: AttributeEditorProps, S: SelectReferenceEditorState<V>>(
    props: P
):
    RPureComponent<P, S>(props),
    LocalGraphStore.Observer
{
    // subclass contract:
    protected abstract fun hydrate(...): V?                    // current value from notation
    protected abstract fun selectOptions(): Array<SelectOption>?  // null = not ready; render nothing
    protected abstract fun wireValue(value: V): String         // crop policy lives per-editor
    protected open fun label(): String = CommonEditUtils.formattedLabel(AttributePath.ofName(props.attributeName))
    protected open fun renamedValue(event: NotationEvent, current: V?): V?  // non-null → adopt + renaming=true
    protected open fun onGraphChange() {}                      // refresh candidates
    protected open fun ChildrenBuilder.renderExtras() {}       // SelectLogic's launch button

    // provided (the ~120 duplicated lines per editor):
    // observe/unobserve on mount/unmount (preserve the async-observe quirk);
    // componentDidUpdate: value changed → renaming? clear flag : hydrated? commit;
    // onCommandSuccess: renamedValue(...) ?: onGraphChange();
    // commit = UpsertAttributeCommand(objectLocation, attributeName, ScalarAttributeNotation(wireValue(v)));
    // render = muiAutocompleteField(label, options, selected, onSelect, disableClearable = true) + renderExtras()
}
```

**Per-subclass residue:** candidate computation + extra observers (`ClientStateGlobal` for
Object/Loop; `ScriptStore` via `DocumentBridgeContext` for Step/Loop; graph scan for Logic;
Job-doc channels for Channel), `wireValue` (SelectObject: crop-if-same-doc; SelectStep:
always-crop; SelectLogic: full reference; SelectChannel: raw string with `V = String`),
rename-event specifics (SelectObject tracks both `RenamedDocumentRefactorEvent` and
`RenamedObjectRefactorEvent`), `SelectLogicEditor`'s `navigationGlobal` + launch button (this
migration also resolves its `// TODO: convert to RPureComponent`), and
`SelectEnclosingLoopEditor`'s one-shot innermost-loop default pre-fill (its
`latestResolvedValue`/`defaultApplied` plain-field mirrors become a protected hook on the base).

**Migration order within the phase** (D5): `SelectStepEditor` (cleanest fit) →
`SelectChannelEditor` (proves `V = String`) → `SelectObjectEditor` (DAG-ancestor exclusion
stays local) → `SelectLogicEditor` → `SelectEnclosingLoopEditor` **last**.

**Risks:** echo-write regressions (a no-op Upsert re-triggering observers — see
`TargetSpecEditor`'s hydration comment for why that matters) and rename tracking.

**Verify:** build gate; Script — If/ForEach/DoWhile condition & items step selects, ControlStep
enclosing-loop select (default pre-fill on a fresh ControlStep inside nested loops), RunStep
logic select + launch button; rename a referenced step and a referenced document → selects
follow with **no** echo write (watch document yaml, read-only); Job — channel selects across
worker cards; Custom — `SelectObjectEditor` with `is:` constraint incl. cycle exclusion;
`:kzen-auto-test:selfTest`.

## Phase 6 (optional) — hygiene

Execute only if phases 1–5 landed without surprises.

1. **Manager-lookup helper**: extract the shared "read metadata key → find autowired wrapper by
   name" logic from `AttributeEditorManager` (`editor:`) and `AttributeViewManager` (`summary:`)
   into a small function; both `Wrapper` classes remain distinct notation objects with distinct
   autowire lists (`common-js.yaml` unchanged).
   *As built: **4 call sites**, not 2 — `ScriptStepDisplayDefault.findSummaryAttributes` and
   `WorkerDisplayDefault.renderAttributeSummaries` inline the same read. `AttributeWrapperLookup`
   owns both keys and two overloads (`AttributeMetadata`-shaped and `GraphStructure`-shaped).*
2. ~~**Rename-editor scaffolding**~~ — **DROPPED 2026-07-20 on a finding.** The stated premise
   ("three rename editors share the shape") does not hold: `script/step/header/StepNameEditor`
   has **no text field** — it renders a reader and embeds `common/edit/ObjectNameEditor`. That
   leaves `ObjectNameEditor` ↔ `sidebar/DocumentNameEditor`, which do share the TextField +
   Cancel/Save IconButtons + `ClientInputUtils.handleEnterAndEscape` + `isModified()`, but sit in
   incompatible containers (inline `float:right` with −3em/−0.5em negative margins compensating for
   the float, vs. a flex row inside a `Popover` with a `textFieldTextInset` origin shift). Lifting
   the render needs either `sx`-offset parameters — a leaky abstraction — or converting
   ObjectNameEditor to flex, which is a **visual change, not hygiene**, on a surface (the step
   header's inline name editor) that headless verification can't reach. Revisit only if that layout
   is being touched for its own reasons.

3. **Also folded in here** (parked under Phase 3, closed 2026-07-20): the pinned-`props` sweep —
   bare `props` → `this.props` in the `AttributeCommitter` property-initializer lambdas of the six
   affected adopters. See the Phase 3 follow-up note.

**Verify:** build gate; editor and summary-view selection unchanged across Script/Job/Flow/Custom.

## Explicitly out of scope

- **Job↔Report spec-editor duplication** (FormulaMap/ValueSetFilter/Pivot/Export pairs) —
  reserved for `2026-07-16_job-improvements.md` Report subsumption (J2–J4/J9). The duplicated
  add-affordance UI in SortSpec/ValueSetFilter/PivotSpec/FormulaMapAdd and the spec editors'
  observer-guard base are Job plan phase 8 item 4 (coordinated: it builds on phases 3/5 here).
  Phase 3 leaves `FormulaMapRow` on the kernel-only diet and Report controllers untouched for
  this reason.
- **Renaming any registered editor object** — would ripple through ~40 `editor:` markers in
  server yaml incl. test fixtures.
- **Filling the `MapAttributeNotation` `TODO()`** in the value-extraction path — feature work.
- **`SelectObjectEditor`'s structural refactors beyond the base migration** (its DAG-cycle
  exclusion logic is intentionally local).
