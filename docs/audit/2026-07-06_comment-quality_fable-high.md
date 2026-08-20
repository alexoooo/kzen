# Comment-quality audit — living document

**Task:** (1) Amend `docs/CODING_STANDARDS.md` with comment writing-style guidance (target audience =
first-time reader, not the prompter); (2) identify low-quality comments added since Claude Code use
began (cutoff 2026-05-01) across the kzen repos; (3) propose a fix for each.

**Status:**
- [x] Standards amendment written to `docs/CODING_STANDARDS.md` (CC-02 "Writing style" subsection)
- [x] Candidate verification pass (context read, verdict + proposed fix per item)
- [x] Final summary
- [x] All 39 fixes (F01–F39) applied to code (2026-07-07)
- [x] Concision pass over the same comments (2026-07-07): trimmed redundant words / irrelevant
      details; CC-02 gains a "Less is more" bullet

**Method:** extracted every comment line added since 2026-05-01 that still survives at HEAD
(`git log -p` since cutoff + grep against HEAD), across kzen-auto (3,895 surviving lines),
kzen-lib (439), kzen-launcher (57), kzen-shell (12), kzen-project (25). Filtered by smell regexes
(history-narration, deleted-code comparison, prompt-echo) → 224 + 15 supplementary candidates;
each suspect verified in context, and referenced classes checked for existence at HEAD
(`ScriptExecutionContext`, `ReportExecution`, `JobControlImpl`, `WebDriverContext`, the Context
objects, `GraphController` are all GONE; `LogicTraceStore` and both `LogicTraceHandle` impls are LIVE).

**Judgment criteria** (mirrors the CC-02 amendment):
- BAD — references code deleted from the repo ("the old regex", "replaces the former X singleton").
- BAD — change-narration ("now that", "no longer", "previously", "moved here from") — describes the
  diff, not the code.
- BAD — prompt-echo / reviewer-facing justification. (None found verbatim — the offenders here are
  all history-narration variants of talking-to-the-prompter.)
- OK — comparison against a LIVE referent: a class still in the tree, an external library's
  documented/removed API, an on-disk artifact (saved notation), or a plausible design alternative.
- OK — "was deleted/renamed" describing a RUNTIME state (e.g. "containing step was deleted, parent
  hasn't re-rendered yet").

---

## Findings — fixes (applied 2026-07-07)

Severity: ● = dead referent / pure history, delete or rewrite; ◐ = real constraint wrapped in
diff-speak, rewrite present-tense.

### kzen-auto — common

**F01 ●** `kzen-auto-common/.../script/model/ScriptDependencyAnalysis.kt:71`
`…is matched — the old plain-identifier regex missed it.`
Dead referent (replaced regex). **Fix:** end the sentence at "is matched."

**F02 ●** `…/ScriptDependencyAnalysis.kt:118`
`…skips member selectors, unlike the previous word-boundary regex (see KotlinExpressionAnalyzer).`
**Fix:** `// Lexer-derived references: respects strings/comments/back-ticks and skips member selectors (see KotlinExpressionAnalyzer).`

**F03 ◐** `kzen-auto-common/.../script/ScriptConventions.kt:53`
`…the single source of truth now that the explicit step lists are gone.`
**Fix:** `…Order is the document position of the step objects — the single source of truth (there is no separate step-list attribute). Mirrors NestedListAttributeDefiner…`

### kzen-auto — js

**F04 ◐** `kzen-auto-js/.../objects/ProjectController.kt:592-596`
`Previously the stage was window-scrolled with no container, so horizontal window scroll slid…`
Real failure mode (Selenium click-intercept) wrapped in "previously". **Fix:** present-tense
counterfactual: `Without this pane the stage would be window-scrolled, and horizontal window scroll slides the leftmost content — including the insert "+" buttons — UNDER the fixed sidebar (z-index 999), which silently intercepts clicks (Selenium "element click intercepted"). Scrolling within this pane can never move content left of \`left\`…`

**F05 ●** `kzen-auto-js/.../document/bridge/InsertionKey.kt:8`
`Replaces the former app-global InsertionGlobal singleton; any document type…`
**Fix:** delete the "Replaces…" clause: `…lazily created on first touch. Any document type (including downstream) may participate by using this same key.`

**F06 ●** `kzen-auto-js/.../document/bridge/ViewModeKey.kt:8` — same pattern as F05, same fix.

**F07 ●** `kzen-auto-js/.../document/custom/model/CustomStoreKey.kt:8`
`…Replaces the former CustomGlobal WeakRef object.` **Fix:** delete that sentence.

**F08 ●** `kzen-auto-js/.../document/script/model/ScriptDragStoreKey.kt:8`
`…Replaces the former ScriptStepDragStoreContext.` **Fix:** delete that sentence.

**F09 ●** `kzen-auto-js/.../document/script/model/ScriptStoreKey.kt:7-9`
`…Replaces the former ScriptStoreContext now that all per-document state routes through the single DocumentBridge…`
**Fix:** `// Owner-provided: ScriptController provides its store into the DocumentBridge in render(); every step display in the subtree looks it up. All per-document state routes through the single DocumentBridge, so each class component spends its one contextType slot on DocumentBridgeContext and still reaches the store by key.`

**F10 ●** `kzen-auto-js/.../document/flow/FlowController.kt:79-82`
`The modernized "graph" / "time series" UI. Renders the same vertex/edge grid as the legacy GraphController…rather than the retired VisualDataflowRepository…instead of a bespoke FAB.`
Entire header is a migration story; `GraphController` / `VisualDataflowRepository` are gone.
**Fix:** `// The Flow document UI: a vertex/edge grid (CellController) whose per-vertex VisualFlowModel is rebuilt from the logic trace store (via FlowProgressStore); run control comes from the global logic ribbon (HeaderRunController).`

**F11 ●** `kzen-auto-js/.../document/job/JobController.kt:317-319`
`The per-Worker preview-slice and summary serve-channel pulls that used to live here are now owned by each Worker's own card…so this controller no longer knows about any Worker type (see CC-17).`
A "what's no longer here" placeholder at the end of a function (CC-10). **Fix:** delete all three
lines. (The ownership design is already documented on PreviewWorkerDisplay / SummaryWorkerDisplay.)

**F12 ◐** `kzen-auto-js/.../document/job/display/SummaryWorkerDisplay.kt:56-57`
`…they are unchanged; only the producer poll moved here from JobController, so the generic controller carries no summary awareness (see CC-17).`
**Fix:** `…The value-set-filter / pivot editors downstream observe that store to source a column's distinct values; this card is the only producer, so the generic controller carries no summary awareness (see CC-17).`

**F13 ◐** `kzen-auto-js/.../script/display/dependency/ScriptBranchDisplay.kt:722-728`
`…the (formerly present) white background stays invisible. Switching this to \`sx {}\` made \`sx\` win everything…(the intended, pre-regression size)…that regression is what broke the look…`
The css-vs-sx constraint is valuable; the "formerly/pre-regression/that regression" framing is
diff-speak. **Fix:** `// NB: size overrides MUST live in a \`css {}\` block, not \`sx {}\`. An emotion \`css\` class has no competing MUI rule for width/height, so \`width\`/\`height\` win and clamp the button to the intended compact 32x32. \`padding\`/\`backgroundColor\`, by contrast, lose to \`.MuiIconButton-root\` (which sets both) — desired: MUI's 8px padding is kept and the white background stays invisible. With \`sx {}\` every property wins: the white background surfaces as an outline and padding drops to 0, breaking the look and the "Plus Circle" self-test template match.`

**F14 ◐** `kzen-auto-js/.../script/step/header/StepHeader.kt:120-121`
`…(previously the summary grew this row and, under center alignment, shoved them down on collapse).`
**Fix:** `…hold a fixed vertical position whether or not the summary is present (if the summary shared this flex line it would grow the row and, under centre alignment, shove them down on collapse).`

**F15 ●** `…/StepHeader.kt:199-200`
`Spacer matching the run icon's footprint, so the summary stays indented under the name now that it's a row below the icon/name row (rather than nested in the old name+summary column).`
**Fix:** `// Spacer matching the run icon's footprint, so the summary row below stays indented under the name.`

**F16 ●** `kzen-auto-js/.../sidebar/SidebarFolder.kt:183`
`The same invalid destinations the old picker filtered are rejected here.`
Dead referent (retired move-picker). **Fix:** delete the sentence — the `when` branches in
`canAcceptDrop` are individually commented (already-inside / own-subtree / name collision).

**F17 ●** `kzen-auto-js/.../ribbon/HeaderRunController.kt:421`
`Compact icon for a header run-control button: smaller than the former 1.5em and with no right margin…`
**Fix:** `// Compact icon for a header run-control button, with no right margin (these buttons are icon-only), to keep the single-row control cluster narrow.`

**F18 ●** `kzen-auto-js/.../service/global/NavigationGlobal.kt:48`
`NB: previously paused the retired dataflow run-loop here on a pending "return" navigation.`
Pure history over `returnPending = false`. **Fix:** delete the comment.

**F19 ●** `kzen-auto-js/.../service/logic/ClientLogicGlobal.kt:361`
`…each step's result is visible before the next (reintroduces the old paced dataflow run-loop).`
**Fix:** drop the parenthetical.

**F20 ◐** `kzen-auto-js/build.gradle.kts:116` (esbuild block)
`Icons no longer contribute to the bundle at all: they're fetched on…`
**Fix:** `Icons don't contribute to the bundle: they're fetched on…`

**F21 ◐** `kzen-auto-js/build.gradle.kts:179` + `kzen-launcher/kzen-launcher-js/build.gradle.kts:150`
`esbuild (jsEsbuildBundle) replaces webpack for this module; disable the now-unused webpack tasks so…`
"replaces webpack" is fine (webpack is the live toolchain default); "now-unused" is narration.
**Fix:** `…disable the webpack tasks (unused: esbuild bundles instead) so…`

### kzen-auto — jvm

**F22 ●** `kzen-auto-jvm/.../server/context/KzenAutoContext.kt:220-221`
`…disposes the run-scoped resources (a browser opened with closePolicy Auto/KeepOnFailure) via the engine — replacing the former WebDriverContext process-singleton shutdown quit.`
**Fix:** end at "…via the engine."

**F23 ◐** `kzen-auto-jvm/.../server/exec/flow/FlowRun.kt:496`
`…trace path (LogicTracePath.ofObjectStableId), exactly as the old store keyed it.`
`LogicTraceStore` is live — "old" is a misnomer. **Fix:** `…trace path (LogicTracePath.ofObjectStableId), matching LogicTraceStore's per-element keying.`

**F24 ●** `kzen-auto-jvm/.../server/exec/job/EngineJobControl.kt:73`
`…stays counted by the CountingDispatcher (the thread is occupied → inFlight stays positive), matching the old JobControlImpl: visible to quiescence.`
**Fix:** `…stays counted by the CountingDispatcher (the thread is occupied → inFlight stays positive), so blocking I/O remains visible to quiescence detection.`

**F25 ●** `kzen-auto-jvm/.../server/exec/job/JobDeadlockMonitor.kt:52`
`…The Job-scoped analogue of the old JobExecution deadlock grace, expressed as poll ticks.`
**Fix:** delete that sentence — the preceding sentence fully explains the threshold.

**F26 ◐** `kzen-auto-jvm/.../server/exec/report/ReportRun.kt:95-98`
`MULTI (not SINGLE, as the legacy ReportExecution used): …so SINGLE happened to work in production, but…`
**Fix:** `// MULTI, not SINGLE: the record ring is published from two threads — the input pipeline's last model-stage thread (records) and the run coroutine (the end-of-data sentinel in waitForProcessingToFinish). They are sequenced by awaitEndOfData (never concurrent), so SINGLE would appear to work, but LMAX's SingleProducerSequencer…`

**F27 ●** `…/ReportRun.kt:323`
`…throws CancellationException on cancel (the coroutine-model successor to the old \`control.pollCommand() == Cancel\`). Setting \`cancelled\`…`
**Fix:** drop the parenthetical.

**F28 ◐** `kzen-auto-jvm/.../report/exec/trace/ReportOutputTrace.kt:22-23`
`The old (LogicTraceStore-backed) handle republishes on query; the engine adapter's register is a no-op (push-only), so [nextOutput] also pushes below. Harmless on the old path (an extra set).`
Both handle impls are LIVE (`LogicTraceStore.handle` and `ExecutionLogicTraceHandle`) — "old" is a
misnomer, not a dead referent. **Fix:** `// The LogicTraceStore-backed handle republishes on query; the engine adapter (ExecutionLogicTraceHandle) registers a no-op (push-only), so [nextOutput] also pushes below. Harmless on the store-backed path (an extra set).`

**F29 ●** `kzen-auto-jvm/.../service/impl/ServerLogicController.kt:511`
`…park at the new definition's first wavefront — a bounded step-after-edit (matching the old executor's re-park-fresh-then-report-paused).`
**Fix:** drop the parenthetical.

**F30 ◐** `…/ServerLogicController.kt:569`
`…The old trace store keys per element by stable id, so…`
`LogicTraceStore` is live. **Fix:** `…The trace store keys per element by stable id, so…`

**F31 ●** `…/ServerLogicController.kt:698-699`
`…is pruned here so a hosted child that ran to completion (step-over / step-out) no longer counts toward the paused stack depth — matching the old frame tree, which removed a guest frame on close.`
**Fix:** `…is pruned here so a hosted child that ran to completion (step-over / step-out) doesn't count toward the paused stack depth.`

**F32 ●** `kzen-auto-jvm/.../script/step/eval/StepExpressionSupport.kt:74`
`…so the engine flavour can supply its own without the legacy ScriptExecutionContext.`
`ScriptExecutionContext` is gone. **Fix:** `…so any engine flavour can supply its own.`

### kzen-auto — tests

**F33 ●** `kzen-auto-jvm/src/test/.../ScriptDependencyAnalysisTest.kt:28`
`back-ticked reference (\`\`\`My Source\` + 2\`\`) — the old plain-identifier regex missed this`
**Fix:** `// back-ticked reference (\`\`\`My Source\` + 2\`\`) — an escaped step name must still resolve to a dependency`

**F34 ◐** `kzen-auto-jvm/src/test/.../JobRunWorkerTest.kt:109-111`
`…This is the old RunWorker pause-on-error capability (a nested child halts the Job for inspect + resume), regained with no explicit halt request — a child breakpoint IS a run-wide pause.`
**Fix:** `…so all three reach the sink. A nested child halts the Job for inspect + resume with no explicit halt request — a child breakpoint IS a run-wide pause.`

**F35 ◐** `kzen-auto-jvm/src/test/.../ExploreWorkerTest.kt:118`
`The output is persistent now, so the Worker no longer deletes it — the test cleans up its own dir.`
**Fix:** `// The Worker's output is persistent (it never deletes its own dir) — the test cleans up.`

**F36 ◐** `kzen-auto-jvm/src/test/.../LogicTraceStoreRenameTest.kt:68`
`Server no longer emits location-keyed paths (neither old nor new name)`
"old/new name" = the rename under test (live); "no longer" is narration.
**Fix:** `// Location-keyed paths are never emitted — neither the original nor the renamed name appears`

**F37 ◐** `kzen-auto-test/src/test/.../SmokeSelfTest.kt:16`
`(The old \`active == null\` check could pass even when a step threw; see kzen-auto-test/AGENTS.md.)`
**Fix:** `// (An \`active == null\` check alone can pass even when a step threw; see kzen-auto-test/AGENTS.md.)`

### kzen-lib

**F38 ●** `kzen-lib-jvm/.../exec/engine/RunEngine.kt:361`
`…an orphaned detached resource lingers at most one edit cycle (a deliberate simplification of the old eager per-flavour sweep).`
**Fix:** `…an orphaned detached resource lingers at most one edit cycle (deliberate: no eager sweep on every edit).`

**F39 ◐** `kzen-lib-jvm/src/test/.../RenameObjectRefactorTest.kt:233-234`
`…Before the fix the refactor tried to rewrite that synthetic list reference and threw "Not found: NestedHolder - children"; now it is skipped (the list re-derives from object paths).`
**Fix:** `// 'Second' is nested under NestedHolder.children, an auto-wired NestedList with no notation backing. The refactor must skip that synthetic list reference — it re-derives from object paths; rewriting it throws "Not found: NestedHolder - children".`

---

## Verified-OK (checked in context, no action)

- `wrap/React.kt` (kzen-auto-js, kzen-launcher-js) — "Replaces react.PureComponent (removed in
  kotlin-wrappers 2026.x)" etc. — external-library removal, verifiable outside the repo. KEEP.
- `wrap/iconify/iconifyReact.kt` — "Mirrors the props the former @mui IconProps exposed, so existing
  icon {} blocks keep compiling" — external referent + live compile-compat constraint. KEEP.
- `wrap/iconify/iconifyDsl.kt` / `IconNames.kt` — "legacy @mui PascalCase name from notation saved
  against the old registry" — referent is saved on-disk notation (live artifact). KEEP.
- build.gradle.kts "esbuild bundler (replaces webpack)" headers — webpack is the live Kotlin/JS
  toolchain default whose tasks still exist; the comparison orients a first-time reader. KEEP
  (only the "now-unused" phrasing is flagged, F21).
- `ForEachItemStep.kt` — "legacy notation still parses / validates" — back-compat with documents on
  disk. KEEP.
- `PreviewWorkerDisplay.kt:61` — "owned here rather than in the generic controller (see CC-17)" —
  live design-alternative + standards pointer. KEEP.
- "NB: containing step was deleted / renamed; parent hasn't re-rendered yet" family
  (DefaultAttributeEditor, TextAttributeView, ReferenceLinkAttributeView, ExportSpecEditor,
  FormulaMapEditor, SelectClosePolicyEditor, RunStepDisplay, …) — runtime state, present-tense. KEEP.
- "sequenced after this write rather than racing it" family (TextAttributeEditor,
  MultiTextAttributeEditor, FormulaItemController, KotlinExpressionEditor, …) — live async
  constraint. KEEP.
- `NotationReducer` / `ObjectStableMapper` "old subtree / old content nesting" — the pre-move path
  within the rename operation being executed (runtime), not history. KEEP.
- `RunEngine.kt` "cancel + join the old tree" — the previous generation at runtime during a live
  edit. KEEP.
- `LogicTraceStore.kt` — "Document was deleted since the run", "fresh instead of the prior
  iteration's finished state" — runtime semantics. KEEP.
- Worker resume/migration comments (CsvReaderWorker, MultiFileReaderWorker, SummaryWorker,
  GatedSourceWorker, …) — "resumes rather than restarting", "if the Worker was removed by the edit" —
  runtime live-edit semantics. KEEP.
- `ServerLogicController` remaining "instead of ghosting / keeping the prior definition running /
  starts fresh" — runtime. KEEP.
- `DocumentForm.kt` "Made explicit (rather than a `directory: Boolean`)" — design-alternative
  rationale; mild narration but the referent is a plausible alternative. KEEP (borderline).
- `ProcessRegistry.kt` (kzen-shell) — "self-reap gracefully…rather than being hard-killed" —
  runtime. KEEP.
- `SmokeSelfTest` / HeaderRunController / ClientLogicGlobal step-mode comparisons ("Step Over
  instead of Step") — comparisons among live UI actions. KEEP.
- No verbatim prompt-echo comments ("as requested", quoted task wording) were found in any repo.

---

## Summary

- CC-02 in `kzen/docs/CODING_STANDARDS.md` now has a "Writing style" subsection: audience is a
  first-time reader who sees only today's tree; never narrate the change; never echo the prompt;
  comparisons only against live referents; rewrite test = "makes sense without the diff or the
  conversation".
- 39 findings (F01–F39) across kzen-auto (35), kzen-lib (2), kzen-launcher (1 shared with F21),
  each with a concrete proposed replacement. Two dominant classes: dead-referent comparisons
  ("the old X", "replaces the former Y" — 20 items) and change-narration wrapping a real constraint
  ("previously", "now that", "no longer" — 19 items, rewrite present-tense).
- All 39 fixes applied to code on 2026-07-07 (comment-only edits; no behavioural change).
