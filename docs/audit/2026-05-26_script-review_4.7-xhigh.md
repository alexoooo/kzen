# Script feature review — 2026-05-26 (kzen-auto)

Code-review audit of the Script document feature in kzen-auto, triggered by a user-flagged duplication of `walkValueScalar` between `ScriptDependencyOverlay.kt` and `StepDependencyGutter.kt`. Coverage spans `kzen-auto-common/.../document/script/` and `kzen-auto-js/.../document/script/` — controller, command, model, display, display/edit, step/control, step/control/mapping. Server-side step implementations (`kzen-auto-jvm/.../script/step/*`, 36 files) are out of scope.

Findings are graded against `docs/CODING_STANDARDS.md` (CC-01 through CC-11) plus design-level observations beyond the standards.

## Summary

- **Files audited:** ~25 (12 client display, 3 model, 3 progress, 2 valid, 2 command, 1 controller, 5 common, plus step subtrees)
- **Unique findings:** 23
- **Design notes:** 7 (folded into per-category fixes, not a separate section)
- **One Critical:** `ScriptStore.detectChanges` returns the wrong value on its final line, defeating the entire ChangeType signal system.
- **Dominant theme:** duplication-without-extraction. The recent dependency-visualization work copied code between Overlay and Gutter, between Then/Else/Each branches, and between Logic/Step selectors, then drifted. The audit's largest remediation (D01) extracts a single shared dependency analyzer that dissolves S02–S06 simultaneously.

### Heatmap (severity × effort/occ)

|              | Trivial | Small | Medium | Large | Blocked | **Σ** |
|--------------|--------:|------:|-------:|------:|--------:|------:|
| **Critical** |       1 |       |        |       |         |     1 |
| **High**     |         |     2 |      1 |       |         |     3 |
| **Medium**   |       7 |     1 |      1 |       |         |     9 |
| **Low**      |       7 |     1 |        |       |         |     8 |
| **Info**     |       2 |       |        |       |         |     2 |
| **Σ**        |      17 |     4 |      2 |     0 |       0 |    23 |

17 of 23 findings are mechanical IDE-quick-fix edits. The work is concentrated in 3 multi-file refactors (D01 dependency analyzer, D02 context replacement, D06 branch renderer) that together fold ~10 of the remaining findings.

### Severity rubric

- **Critical** — broken contract; behaviour is silently wrong today.
- **High** — latent correctness risk, or duplication that has already drifted between copies.
- **Medium** — meaningful maintainability cost; CC violation with non-trivial blast radius.
- **Low** — style or single-file cleanup; correct code.
- **Info** — observation worth noting; no immediate action.

### Effort rubric (per occurrence)

- **Trivial** — IDE quick-fix or single-token edit.
- **Small** — one-file edit, no API change. <30 min.
- **Medium** — multi-file refactor confined to one sibling. <2 h.
- **Large** — cross-sibling refactor. Days.
- **Blocked** — external dependency required.

### Pre-existing remediation

**S14 / D05** (switching `ScriptDependencyOverlay` from `RComponent` to `RPureComponent`) was applied in the same changeset as this audit — see the patch to `ScriptDependencyOverlay.kt`. It is kept in the findings table below for traceability and marked `[done]`.

### Remediation log (2026-05-26 follow-up)

All Critical, High, and Medium findings plus design notes D01–D03, D05–D07 were applied in the same session. Items left tracked-only (per audit recommendation): **S22** (DAG-violation TODO), **S23** (submitDebounce capture risk). **D04** (relocate dependency files to `display/dependency/`) was skipped — `display/` has 9 files, CC-06 not yet tripped, and the move would expand the diff without semantic gain.

| ID | Status | Where |
|----|--------|-------|
| S01 / D03 | done | ChangeType enum + `allChangeTypes` + `detectChanges` deleted; `Observer.onScriptState` collapsed to single-arg across 5 implementers |
| S02 / S03 / S04 / S05 / S06 / D01 | done | New `kzen-auto-common/.../script/model/ScriptDependencyAnalysis.kt` is the single source; helpers and walks deleted from Overlay and Gutter |
| S07 | done | `stepDependencyTrunkLineHalfMarginNeg` and `stepDependencyMarkerHalfMarginNeg` named in `StepDependencyGutter.kt` |
| S08 | done | `refreshYieldMillis = 10L` named in `ScriptStore.kt`'s companion |
| S09 / S10-ScriptGlobal / D02 | done | `ScriptGlobal.kt` deleted; new `ScriptStoreContext` (`createContext<ScriptStore?>(null)`); class-component consumers (`IfStepDisplay`, `MappingStepDisplay`, `ScriptStepDisplayDefault`, `SelectStepEditor`) read via `installContextType` + `contextValue<ScriptStore?>()` helpers added to `wrap/React.kt` |
| S10-ScriptController | done | Commented `componentDidUpdate` body removed |
| S11 | done | `checkNotNull` swap in `ScriptStore.state()`; `IllegalStateException` sites in deleted `ScriptGlobal.kt` are gone |
| S12 | done | Rewrites of Overlay and Gutter normalized to `!foo` |
| S13 | done | Wildcards replaced in `ScriptBranchDisplay.kt`; `StepDependencyGutter.kt` rewrite is wildcard-free. Open: `ScriptBranchContainer.kt` (new) uses `web.cssom.*` because `Length.minus` extension's specific symbol path could not be resolved from the IDE — same as `IfStepDisplay.kt` |
| S14 / D05 | done (prior) | `RPureComponent` switch applied in this changeset |
| S15 | done | `creating` field + `InsertionGlobal.Subscriber` removed from `ScriptController` |
| S16 / S18 / D06 | done | New `scriptBranchContainer(...)` helper in `display/ScriptBranchContainer.kt`; consumed by `IfStepDisplay.renderThenBranch / renderElseBranch` and `MappingStepDisplay.renderSteps`. The Else-only `width=100%` on the label and `2×overlapTop` outer margin are preserved via explicit parameters |
| S17 / D07 | done | New `reactSelectField(...)` helper in `wrap/select/ReactSelectField.kt`; consumed by `SelectLogicEditor`, `SelectStepEditor`, `TargetSpecEditor.renderVisualSelect`, and (bonus) `RunStepArgumentsEditor.renderParameter` |
| S19 | done | `submitDebounceMillis = 1000` named in `TargetSpecEditor` |
| S20 | done | Dead `println` / `console.log` / `+"[...]"` breadcrumbs and `imperativeState` commented blocks removed from the listed editors and step controllers. Dead `private suspend fun flush()` removed from `TargetSpecEditor` |
| S21 | tracked (Info) | React class-component signature noise; left alone |
| S22 | tracked (Info) | DAG-violation TODO in `SelectLogicEditor.options()`; left alone |
| S23 | tracked (Low) | `submitDebounce` stale-this risk; left alone per audit recommendation |
| D04 | skipped | Folder move not done; CC-06 not yet tripped |

**Open questions / follow-ups surfaced during remediation:**
1. `ScriptStore.previousDocumentNotation` (line 43) is declared but never assigned after init; the guard `if (previousDocumentNotation != documentNotation)` always fires once `documentNotation != DocumentNotation.empty`. Result: `refreshValidationAsync()` runs more often than intended. **Out of audit scope; flagging for separate review.**
2. `IfStepDisplay.renderElseBranch` had `width = 100.pct` on its inline-block label div (renderThenBranch and `MappingStepDisplay.renderSteps` did not). Preserved via the new helper's `labelFullWidth: Boolean = false` parameter, but the original asymmetry looks like a copy-paste artefact. Worth a UI-level sanity check before removing the parameter.
3. The `web.cssom.minus` extension that lets `100.pct.minus(3.em)` compile lives somewhere in the kotlin-wrappers cssom klib but resolves only via `web.cssom.*` wildcard — could not find the specific symbol path. `ScriptBranchContainer.kt` carries one wildcard import as a result; `IfStepDisplay.kt` and `MappingStepDisplay.kt` already had wildcards (preserved, not introduced). Worth resolving with a one-line specific-import fix once the symbol is located.

---

## §1 — Broken state contract

| ID  | Issue | Sev | Effort/occ | Sites |
|-----|-------|-----|-----------|-------|
| **S01** | `ScriptStore.detectChanges` computes `changes: MutableSet<ChangeType>` across 20 lines of conditional adds, then returns `allChangeTypes` unconditionally on the last line. The entire ChangeType discriminator is broken: every observer receives every change type on every notification. The `changes` local is dead code. | **Critical** | **Trivial** (fix) / **Small** (delete) | `kzen-auto-js/.../script/model/ScriptStore.kt:208-230` |

**Notes:**

- The one-line fix is `return changes` instead of `return allChangeTypes`. But before applying it, **audit each observer** for whether it actually branches on the `changes: Set<ChangeType>` parameter. If no observer does (likely — observers seen so far ignore the param), the entire ChangeType enum + `changes` parameter is vestigial and should be removed instead. This is **D03**.
- **D03 — Decide on ChangeType lifecycle.** Recommendation: delete the discriminator. The `Observer.onScriptState(scriptState, changes)` callback collapses to `onScriptState(scriptState)`; the `ChangeType` enum, the `allChangeTypes` constant, and the 20-line `detectChanges` body all go. If a future feature needs change-typed observers, reintroduce it then with the contract honoured.
- CC-10 (justify every line): the 20 lines of unreachable enum-set construction in `detectChanges` are noise that lies about the code's behaviour.
- CC-05 (single-purpose): `detectChanges` is named as if it returns detected changes; it returns a constant. The body and the return disagree.

---

## §2 — Dependency-analysis duplication

The most consequential finding cluster. Two display files implement overlapping passes over the same graph, with helpers copy-pasted between them and then drifted.

| ID  | Issue | Sev | Effort/occ | Sites |
|-----|-------|-----|-----------|-------|
| **S02** | `walkValueScalar` (37-line body, recursive walk of `AttributeDefinition` × `AttributeNotation` to extract leaf scalar strings) byte-identical in two files. | **High** | **Small** (see D01) | `ScriptDependencyOverlay.kt:405-441`, `StepDependencyGutter.kt:359-395` |
| **S03** | The same dependency-analysis pass is implemented twice with different output shapes. Both walk `documentLocations`, call `attributeReferencesIncludingWeak()`, scan value-scalar strings for identifier mentions, and filter structural-containment edges. The Overlay returns `List<CrossBranchEdge>` for polyline rendering; the Gutter returns `StepDependencyEdges` with lane assignment. Implementations have **already drifted**: the Gutter filters cross-branch endpoints by `indexByLocation` membership (line 251–261) while the Overlay routes everything through `branchOfStep` lookup (288). A future fix to one would not migrate to the other without manual cross-reference. | **High** | **Medium** (D01) | `ScriptDependencyOverlay.kt:240-349`, `StepDependencyGutter.kt:201-299` |
| **S04** | `containsWord` (3-line regex helper) duplicated identical. | **Medium** | **Trivial** (folds into S02) | `ScriptDependencyOverlay.kt:387-389`, `StepDependencyGutter.kt:341-343` |
| **S05** | Same identifier regex under two names: `validIdentifierRegex` and `stepIdentifierNameRegex`, both `^[A-Za-z_][A-Za-z0-9_]*$`. The Gutter wraps it in an extra `isValidIdentifier(name)` helper; the Overlay matches inline at the call site. Same pattern, two encodings. | **Medium** | **Trivial** (folds into S02) | `ScriptDependencyOverlay.kt:384`, `StepDependencyGutter.kt:333,336-338` |
| **S06** | Wrapper functions same purpose, different names: `walkValueScalars` (plural) vs `forEachValueScalar` (singular). Identical 10-line bodies iterating attributes and delegating to `walkValueScalar`. | **Medium** | **Trivial** (folds into S02) | `ScriptDependencyOverlay.kt:392-402`, `StepDependencyGutter.kt:346-356` |

**Notes:**

- **D01 — Unify dependency analysis.** Extract `ScriptDependencyAnalysis` returning a single graph model: `branchOfStep: Map<ObjectLocation, AttributeLocation>`, `inBranchEdges: List<Pair<ObjectLocation, ObjectLocation>>`, `crossBranchEdges: List<Pair<ObjectLocation, ObjectLocation>>`, plus `locationByIdentifier`. The Gutter then derives lane packing from `inBranchEdges` filtered to its branch; the Overlay derives polyline segments from `crossBranchEdges`. One walk, one source of truth.
- **Placement decision:** prefer `kzen-auto-common/.../script/model/ScriptDependencyAnalysis.kt` if commonMain has access to `GraphDefinitionAttempt` and `ObjectReferenceHost`. Both live in `kzen-lib-common`, so this should resolve — verify with `./gradlew :kzen-auto-common:build` after the move. Fallback: stage in a new `kzen-auto-js/.../script/display/dependency/` package (see D04). Note that the helpers `walkValueScalar`, `containsWord`, and the identifier regex are pure data-walks with no JS or React dependency — they belong in common regardless.
- **D04 — `display/dependency/` package.** The `display/` folder currently has 9 files (12 if you count `display/edit/`). CC-06 isn't tripped yet, but the dependency-rendering concern is cohesive enough to warrant its own package: `display/dependency/{ScriptDependencyOverlay.kt, StepDependencyGutter.kt, StepRowRefRegistry.kt, ScriptDependencyAnalysis.kt}`. Pair the move with D01.
- **Why this cluster ranks High, not Medium:** S02–S06 read as "obvious copy-paste duplication" but the deeper cost is S03's drift. Two implementations of the same algorithm now disagree on edge-case filtering; the next bug report ("polyline shows but lane doesn't" or vice versa) will surface this difference. Extraction prevents the drift from compounding.

---

## §3 — Branch / select renderer duplication

A second duplication cluster across step-control and editor render code.

| ID  | Issue | Sev | Effort/occ | Sites |
|-----|-------|-----|-----------|-------|
| **S16** | `IfStepDisplay.renderThenBranch` ↔ `IfStepDisplay.renderElseBranch` ↔ `MappingStepDisplay.renderSteps` are near-identical 50-line branch containers. Same outer flex layout, same icon styling (`fontSize = 3.em`, `marginBottom = 15.px`, `marginTop = (-40).px`), same content/exit-icon structure. Differ only in label text ("Then" / "Else" / "Each") and `attributePath`. | **High** | **Small** | `IfStepDisplay.kt:332-382`, `IfStepDisplay.kt:421-474`, `MappingStepDisplay.kt:295-345` |
| **S17** | `SelectLogicEditor` and `SelectStepEditor` share ~50 lines of ReactSelect setup: identical `styleTransformer`, `menuPortalTarget`, `onChange` shape, and label wrapper. `TargetSpecEditor.renderVisualSelect` repeats the same pattern a third time. | **Medium** | **Small** | `SelectLogicEditor.kt:233-286`, `SelectStepEditor.kt:224-272`, `TargetSpecEditor.kt:373-443` |

**Notes:**

- **D06 — Branch-renderer extraction.** Single `branchContainer(label: String, iconName: String, content: ChildrenBuilder.() -> Unit)` helper consumed by Then / Else / Each. Place under `kzen-auto-js/.../script/display/` (or `display/branch/` if a sibling D04 package is created). Folds S16 + S18 + the icon-styling repetition.
- **D07 — Shared `ReactSelectField` wrapper.** Encapsulates ReactSelect with the shared `styleTransformer` + `menuPortalTarget` + onChange shape. Each editor passes options + label + value + onChange; the wrapper owns the rest. Folds S17 + the per-editor commented `// MaterialInputLabel` blocks (S20).
- CC-04 (feature coherence): branch-rendering is a single concept currently scattered across three private render functions; extracting consolidates it where future "add a Switch step with N branches" needs would live.

---

## §4 — State management & lifecycle

| ID  | Issue | Sev | Effort/occ | Sites |
|-----|-------|-----|-----------|-------|
| **S09** | `ScriptGlobal` is a module-level mutable singleton holding a `WeakRef<ScriptStore>`. The author's own comment on line 6 says `// TODO: use React context instead?` — they're right. The pattern bypasses React's prop flow and introduces deref-may-fail surface area (the `get()` throws `IllegalStateException` if the WeakRef has been GC'd, which is an action-at-a-distance failure mode). Distinguish from `StepRowRefRegistry`: the latter is a justified global because DOM ref handles can't be passed down through layout-measuring code (its own comment on lines 7-11 explains this). | **Medium** | **Medium** | `kzen-auto-js/.../script/model/ScriptGlobal.kt` |
| **S08** | `delay(10)` twice in `ScriptStore.refreshProgressAsync` / `refreshValidationAsync` with no named binding. (CC-01) The reader can't tell whether 10 is a debounce window, a yield-to-next-frame hack, or a guess. | **Medium** | **Trivial** | `ScriptStore.kt:155,164` |
| **S11** | Manual `throw IllegalStateException(...)` instead of the idiomatic `error()` / `check()` / `requireNotNull(...) { ... }`. (CC-08) | **Low** | **Trivial** | `ScriptGlobal.kt:23,26`, `ScriptStore.kt:178` |
| **S10** | Commented-out code blocks. CC-07 (no drive-by) and CC-10 (justify every line). | **Low** | **Trivial** | `ScriptGlobal.kt:13-17,30-34`, `ScriptController.kt:159-161` |
| **S15** | `ScriptControllerState.creating` is set by `onInsertionSelected` / `onInsertionUnselected` but never read in the render method. Either thread it into `renderMain` (the only plausible consumer is the multi-step display under InsertionGlobal-managed insertion) or delete the field + handlers. | **Low** | **Trivial** | `ScriptController.kt:51,172-183` |
| **S23** | `TargetSpecEditor` holds a mutable instance field `submitDebounce` initialized at class scope (not state). The debounce closure captures `this` and the field; if the component remounts but a stale debounce timer fires before unmount-cancellation, the closure references a stale instance. Either guard with mount-flag in the closure, or move the debounce to a hook-like helper. | **Low** | **Trivial** | `TargetSpecEditor.kt:88-90` |

**Notes:**

- **D02 — Replace `ScriptGlobal` with React Context.** `createContext<ScriptStore>()` at the controller; consumers (descendants of `ScriptController` that currently call `ScriptGlobal.get()`) read via `useContext` or the class-component context-type idiom. Keep `StepRowRefRegistry` as-is.
- **Why S09 is Medium, not Low:** the singleton works today *because* only one Script document is open at a time, but it encodes that constraint implicitly through a global. Multi-tab editing or any future side-by-side Script comparison would break silently. Context makes the scoping explicit.
- **Theme — idiom drift on failure paths.** S01 (silent wrong return), S11 (`throw IllegalStateException` instead of `error()`), and S10 (commented-out error guards in `ScriptGlobal`) are three flavors of CC-08 not being internalized in this feature. Audit-trail for whoever owns CC-08 enforcement.

---

## §5 — Magic constants (CC-01)

| ID  | Issue | Sev | Effort/occ | Sites |
|-----|-------|-----|-----------|-------|
| **S07** | Half-size constants inlined as magic in Gutter CSS: `marginLeft = (-1).px` for half-trunk, `marginLeft = (-5).px` for half-marker, repeated 3×. The Overlay computes the equivalents properly as `halfTrunk = stepDependencyTrunkLineWidthPx.toDouble() / 2.0`, `halfMarker = stepDependencyMarkerSizePx.toDouble() / 2.0` (Overlay lines 180-181). Bumping the trunk/marker width constants silently miscentres Gutter rendering but updates Overlay correctly. | **Medium** | **Trivial** | `StepDependencyGutter.kt:140,156,177` |
| **S18** | Repeated magic CSS in three branch renderers: `fontSize = 3.em`, `marginBottom = 15.px`, `marginTop = (-40).px` — three sites × three values × no named binding. Folds into D06 (branch helper) which can own these constants. | **Medium** | **Trivial** (with D06) | `IfStepDisplay.kt:378-379,468-469`, `MappingStepDisplay.kt:312,339-340` |
| **S19** | `TargetSpecEditor` 1000ms debounce delay with no name. (CC-01) Whether it's chosen for "feels responsive" perceptual reasons or for a specific backend characteristic is opaque. | **Medium** | **Trivial** | `TargetSpecEditor.kt:90` |

**Notes:**

- For S07 specifically, the right fix is named pixel-half constants alongside the existing width constants in `StepDependencyGutter.kt:24-32`:
  ```kotlin
  private val stepDependencyTrunkLineHalfMarginNeg = (-stepDependencyTrunkLineWidthPx / 2).px
  private val stepDependencyMarkerHalfMarginNeg = (-stepDependencyMarkerSizePx / 2).px
  ```
  After D01 + D04 the analyzer module can own these as the dependency-rendering style constants.

---

## §6 — Dead code, style nits, and tracked items

| ID  | Issue | Sev | Effort/occ | Sites |
|-----|-------|-----|-----------|-------|
| **S12** | CC-11 space-after-`!` violations. Memory: user has called this out repeatedly. | **Low** | **Trivial** | `ScriptDependencyOverlay.kt:247`, `StepDependencyGutter.kt:40,62 (×2),79` |
| **S13** | Wildcard `import web.cssom.*` — replace with the specific imports actually used (`Color`, `LineStyle`, `NamedColor`, `BoxSizing`, `Position`, `number`, etc.). | **Low** | **Trivial** | `StepDependencyGutter.kt:20`, `ScriptBranchDisplay.kt:33` |
| **S14** | `ScriptDependencyOverlay` extends `RComponent` while controller and `ScriptBranchDisplay` extend `RPureComponent`. State-only re-renders are already gated by `updateSegments`' structural equality check; pure-component bailout adds parent-re-render protection at zero cost since the component has empty props. **[done]** — applied in this changeset. | Low | Small (done) | `ScriptDependencyOverlay.kt:76-77` (was) → `RPureComponent` (now) |
| **S20** | Debug `println` / `console.log` and large commented-out blocks scattered across the editors. (CC-10) Sweep alongside the editor consolidation in D07. | **Low** | **Trivial** | `TargetSpecEditor.kt:{106,113,242,401-416}`, `SelectLogicEditor.kt:{47,76,96,99,206,234-235,251-252}`, `SelectStepEditor.kt:194`, `RunStepArgumentsEditor.kt:{71-73,93-110,155-157}`, `IfStepDisplay.kt:{81-82,246-248,310-319,322,390-412}`, `MappingStepDisplay.kt:71-72` |
| **S21** | `componentDidUpdate(..., snapshot: Any)` parameter unread across editors. This is the React class-component signature — the parameter is framework noise, not author intent. Tracking only. | **Info** | n/a | `TargetSpecEditor.kt:174`, `SelectStepEditor.kt:89`, `SelectLogicEditor.kt:132` |
| **S22** | `// TODO: avoid suggesting DAG violation?` — a real gap in `SelectLogicEditor`'s suggestion logic (selecting a downstream logic as an upstream input would create a cycle). Tracking for future work. | **Info** | tracked | `SelectLogicEditor.kt:108` |

**Notes:**

- S12 occurs in two of the three files in the dependency cluster. Fixing as part of the D01 extraction sweeps all five sites in one diff.
- S14 is the only finding in this audit's changeset that has *already been remediated*. The patch is two lines: import swap and class-extends swap. Verified safe because (a) `ScriptDependencyOverlay`'s render reads only `state.segments`; (b) `updateSegments` already gates `setState` on structural equality, so state-driven re-renders propagate unchanged; (c) the props interface is empty, so shallow-prop-equality is always true under parent re-render — net effect is to suppress now-redundant re-renders driven by parent state churn, with no functional change.
- S20's sweep is non-trivial in editor-count but trivial per-site. Bundle with D07's editor consolidation.

---

## Proposed fixes (per category)

### Category A — Critical state-contract bug (S01 / D03)

- **Scope:** 1 file: `ScriptStore.kt`.
- **Recommended fix:** delete the `ChangeType` enum, the `allChangeTypes` constant, the `detectChanges` function, and the `changes: Set<ChangeType>` parameter on `Observer.onScriptState`. Update the one observer (`ScriptController.onScriptState`) to the new single-arg signature.
- **Fallback fix (if any downstream observer is found to genuinely need the discriminator):** change line 229 from `return allChangeTypes` to `return changes`, audit each observer to confirm it actually branches on `changes`, and rename `detectChanges` to make the semantics explicit.
- **Why delete is recommended:** the discriminator has been broken for long enough that no observer can be relying on it; reintroducing change-typed observation when an actual use case emerges is cheaper than carrying broken machinery.
- **Risk:** Low for delete (signature-narrowing refactor; compiler flags every observer call site). Medium for fix-the-return — silent semantic change to every observer's `changes` handling.

### Category B — Unify dependency analysis (S02–S06 / D01 / D04)

- **Scope:** 1 new file + 2 modified files: extract `ScriptDependencyAnalysis.kt` (preferred location `kzen-auto-common/.../document/script/model/`, fallback `kzen-auto-js/.../document/script/display/dependency/`), modify `ScriptDependencyOverlay.kt` and `StepDependencyGutter.kt` to consume it.
- **API shape (recommendation):**
  ```kotlin
  data class ScriptDependencyAnalysis(
      val branchOfStep: Map<ObjectLocation, AttributeLocation>,
      val inBranchEdges: Set<Pair<ObjectLocation, ObjectLocation>>,
      val crossBranchEdges: List<CrossBranchEdge>
  ) {
      companion object {
          fun analyze(clientState: ClientState, documentPath: DocumentPath): ScriptDependencyAnalysis
      }
  }
  ```
- **Helpers also move:** `walkValueScalar`, `walkValueScalars` (pick one name — recommend `forEachValueScalar` for parity with Kotlin stdlib idiom), `containsWord`, and the identifier regex.
- **Sequence:** (1) write the analyzer + tests in commonMain if available; (2) switch the Gutter to consume `inBranchEdges` (lane packing stays in the Gutter — it's view-specific); (3) switch the Overlay to consume `crossBranchEdges`; (4) delete the duplicated helpers; (5) verify Gutter and Overlay both render dependency markers and polylines on a Script with cross-branch references; (6) optionally relocate to `display/dependency/` (D04).
- **Risk:** Medium. The two existing implementations have drifted (see S03 Notes); the merged analyzer's filter rules need to encode the union of correct behaviour, not arbitrarily one side's. Reproduce the drift with a test before consolidating.

### Category C — ScriptGlobal → React Context (S09 / D02)

- **Scope:** 1 file delete (`ScriptGlobal.kt`) + new context declaration + consumer updates.
- **Recommended approach:** declare a `ScriptStoreContext = createContext<ScriptStore?>(null)` near `ScriptController`. Wrap the controller's `body()` render in `ScriptStoreContext.Provider value={store}`. Replace `ScriptGlobal.get()` callers with `useContext(ScriptStoreContext)` (functional consumers) or the class-component `contextType` pattern.
- **Verification:** ensure no race where a descendant reads context before `ScriptController.componentDidMount` runs. The current `ScriptGlobal.upsertWeak(store)` already runs in `componentDidMount`, so context (which is set during the provider's render, *before* its children mount) is strictly safer.
- **Risk:** Low. Context is the standard React idiom; the author's own TODO confirms the direction.

### Category D — Branch renderer extraction (S16 / S18 / D06)

- **Scope:** 1 new helper file + 2 modified files (`IfStepDisplay.kt`, `MappingStepDisplay.kt`).
- **Helper signature:**
  ```kotlin
  fun ChildrenBuilder.scriptBranchContainer(
      label: String,
      iconName: String,
      attributeLocation: AttributeLocation,
      content: ChildrenBuilder.() -> Unit
  )
  ```
  All three callers pass label / icon / `AttributeLocation` and provide the content slot. The repeated magic-CSS constants (S18) become file-private constants in the helper.
- **Risk:** Low — purely view-layer extraction with no semantic change.

### Category E — Shared ReactSelect wrapper (S17 / D07)

- **Scope:** 1 new helper component + 3 modified files.
- **Notes:** Bundle with the S20 dead-code sweep — the editors have ~40 lines of commented-out `MaterialInputLabel` blocks that should go in the same diff.
- **Risk:** Low.

### Category F — Style / dead-code sweep (S07, S08, S10–S13, S15, S19–S23)

- **Scope:** trivial per-site edits across ~10 files. Bundle in one cleanup PR after Categories B/D land so the diffs don't compete for the same lines.
- **Specific items:**
  - S07 — name the half-pixel constants alongside the existing widths in `StepDependencyGutter.kt:24-32`.
  - S08 — name the `delay(10)` constant or remove the delays if they're debug artefacts (suspected — neither call site has an explanatory comment).
  - S11 — `error(...)` / `check(...) { ... }` swap (5 sites).
  - S12 — `! ` → `!` (5 sites).
  - S13 — replace `web.cssom.*` wildcards.
  - S15 — read `state.creating` somewhere or delete the field + handlers.
  - S19 — name the 1000ms debounce.
  - S20 — sweep commented-out debug code.
  - S22 / S23 — leave tracked; address in follow-up.

---

## Critical Files

- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\model\ScriptStore.kt` — S01
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\display\ScriptDependencyOverlay.kt` — S02–S06, S12, S14 [done]
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\display\StepDependencyGutter.kt` — S02–S07, S12, S13
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\model\ScriptGlobal.kt` — S09, S10, S11
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\ScriptController.kt` — S10, S15
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\step\control\IfStepDisplay.kt` — S16, S18, S20
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\step\control\mapping\MappingStepDisplay.kt` — S16, S18
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\display\edit\TargetSpecEditor.kt` — S17, S19, S20, S21, S23
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\display\edit\SelectLogicEditor.kt` — S17, S20, S21, S22
- `C:\Users\ostro\IdeaProjects\kzen-auto\kzen-auto-js\src\jsMain\kotlin\tech\kzen\auto\client\objects\document\script\display\edit\SelectStepEditor.kt` — S17, S20, S21
