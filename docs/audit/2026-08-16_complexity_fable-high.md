# Complexity audit — 2026-08-16 (kzen full codebase)

**Task:** step-back review of design/complexity/content across all five Kotlin siblings before the next
feature push. Dimensions: (1) implementation bloat, (2) needlessly long comments, (3) organization,
(4) algorithmic/data-structure complexity, (5) general code smells. **Analysis only — no code changed.**

**Scope:** ~175k lines of Kotlin — kzen-auto ~130k (jvm 52k / js 59k / common 17k), kzen-lib ~35k,
kzen-launcher ~5.9k, kzen-shell ~3.5k, kzen-project ~0.5k. Note: `server/objects` is 204 files /
18,482 lines (not the 259 files a stale directory listing suggested — `feature/` is the renamed `target/`).

**Method:** scripted metrics pre-pass (per-file line counts, comment density, max contiguous comment
block, duplicate basenames) seeded 10 parallel review agents — 9 area sweeps + 1 cross-cutting
structural sweep (paradigm archaeology, layering, duplicate machinery, test topology, wire formats).
Every agent read flagged files in full and verified deadness claims by cross-sibling grep (build/
excluded). Findings below marked **✓** were additionally re-verified in the main session against the
code. Judged against `docs/CODING_STANDARDS.md` (CC-02 comments, CC-06/CC-15 packaging, CC-10 justify
every line, CC-12 sibling duplicates) and each sibling's AGENTS.md / architecture docs; declared-
deliberate designs were not flagged (see § Deliberately not flagged).

**Severity:** ● significant (worth a dedicated task) · ◐ moderate (worthwhile cleanup) · ○ minor
(opportunistic, fix on next touch).

---

## Summary

The codebase is in better structural shape than its file sizes suggest: most of the giant files
(RunEngine, KotlinExpressionAnalyzer, ScriptExecutionMargin, KotlinCodeArea, ClientRestApi,
YamlParser) are **large but cohesive**, with documented invariants — the reviews explicitly cleared
them. The real complexity debt clusters into a small number of repo-wide patterns:

1. **~2,000+ lines of verified-dead code**, dominated by *commented-out code used as a disposal
   mechanism* — including six whole files that are 100% comments and several live-but-unreferenced
   classes (one of which, `DownloadClient`, installs a process-global trust-all SSLContext).
2. **Spec restatement in comments**: logic-spec/architecture prose is re-derived at 2–5 code sites
   per rule (RunEngine, Execution, ServerLogicController, ClientLogicGlobal, JobRun) — hundreds of
   lines of dual-maintenance surface.
3. **Silent error swallowing at integration seams**: resource closers, plugin loading, client
   fire-and-forget async — failures vanish without a log line on both server and client.
4. **Copy-paste families**: drag-reorder index arithmetic ×5 in the JS client, control-verb preamble
   ×9 in ServerLogicController, atomic-move fallback ×4, zip-slip guard ×2, process-lifeline protocol
   ×4 sites — plus an *inconsistently applied* "keep in sync" marker convention for the deliberate
   no-shared-module duplicates (the unmarked copies are exactly where drift was found).
5. **One inert document type** (DataFormat, ~600 lines, registered and editable but consumed by
   nothing) and an **alternate-implementation graveyard** in the pivot machinery.
6. **Test topology gaps**: kzen-auto-js is effectively untested (58,450 main lines : 614 test lines);
   RunEngineTest is a single 3,764-line file; common code is tested on JVM only; kzen-auto-plugin's
   3,221 lines of hot-path Java have no tests.
7. A handful of **real bugs found incidentally** (§ Correctness findings) — worth fixing ahead of any
   cleanup.

---

## Correctness findings (incidental, fix first)

These surfaced while auditing complexity; they are behavior bugs, not style.

- ● **✓ `kzen-lib-jvm .../notation/FileNotationMedia.kt:527`** — `copyResourceSynchronized` passes the
  *source* `resourceLocation` to `invalidateUpsertResource` (with the *destination* file path), so the
  destination document's scan mirrors are never upserted and the source's cache entry is restamped with
  the destination's modified time. Currently masked because the rename flow's `previousMirror == null`
  branch wholesale-clears the mirrors; zero direct test coverage of `copyResource`. Fix: pass
  `destination`; add a copy case to resource CRUD tests; delete the commented `// Files.copy(...)` at :522.
- ● **✓ `kzen-auto-jvm .../service/DownloadClient.kt`** — dead class (zero references) whose companion
  `init` installs a JVM-global trust-all `SSLContext` + accept-all `HostnameVerifier` via
  `HttpsURLConnection.setDefault*` if the class ever loads. Delete the file (also closes the security
  hazard permanently).
- ◐ **✓ `kzen-launcher .../api/RestHandler.kt:61-67`** — `importProject` derives the name from the
  path's last segment and registers it *without* `ProjectNameValidation.check` (which `createProject`
  and `renameProject` both apply), so importing a directory named `main` or `shell` collides with
  kzen-shell's reserved routing prefixes.
- ◐ `kzen-auto-jvm .../report/exec/calc/ColumnValue.kt:252,258` — `plus` concatenates `asText + …`
  where `asText` is null for number-constructed values: `ofNumber(5.0) + ofText("abc")` yields
  `"nullabc"`. (Found while reading the 12-way operator duplication that invites exactly this class of
  bug.) Related: `equals` is epsilon-based while `hashCode` is `toString()`-based (:552-559) — legal
  values that compare equal can hash differently; document the no-hash-key constraint or align.
- ◐ `kzen-auto-js .../ribbon/StorageManagerController.kt:102-190` — REST failures in `refresh()` /
  `onToggleExpand` are swallowed as unhandled promise rejections and leave the spinner on forever
  (`loading` never cleared, no `errorMessage`). Also a stale-base state race between overlapping
  expands (:138-144).
- ◐ `kzen-auto-js` (pattern, ~5 sites) — `componentDidMount` registers observers inside `async { … }`
  while `componentWillUnmount` unregisters synchronously: a mount-then-unmount within one batch runs
  unobserve *before* the deferred observe, permanently leaking an observer on an unmounted component
  (`TargetController.kt:186`, `SortSpecEditor.kt:119`, `ValueSetFilterEditor.kt:151`,
  `RunStepContextsEditor.kt:166`, `FlowController.kt:181`). Guard with an `unmounted` flag or make the
  store registries tombstone-tolerant.
- ○ `kzen-auto-jvm .../api/IconCollectionHandler.kt:23` — plain `HashMap` + `getOrPut` mutated from
  concurrent Ktor request handlers; use `ConcurrentHashMap.computeIfAbsent`.
- ○ `kzen-auto-jvm .../util/WorkUtils.kt:34` — `recursivelyDeleteDir` leaks its `Files.walk` stream
  (no `use {}`, unlike `deleteDirThrowing` directly below) — an open directory handle per call on Windows.
- ○ `kzen-auto-jvm .../exec/report/ReportRun.kt:391` — `getLong(previewStartKey)!!` NPEs on a
  malformed request where sibling paths return `ExecutionResult.failure`.
- ○ `kzen-auto-js .../ribbon/RibbonController.kt:163-165` — the equal-groups early return skips
  clearing `updatePending`, so the archetype filter re-runs on every update until groups change.
- ○ `kzen-lib-common .../model/structure/notation/DocumentNotation.kt:95-97` — `indexOf` on an absent
  path surfaces as "Index must not be negative: -1" from `PositionIndex`, masking the real
  "object not found" cause.
- ○ `kzen-launcher .../project/ProjectRepo.kt:153` — `rename` on a running (Windows-locked) project
  throws raw `IOException` → message-less 500, while `delete`/`upgrade` wrap the same condition into
  `IllegalStateException` → 409.

---

## Cross-cutting themes

### T1 — Commented-out code is the dominant bloat form ●

The metrics pre-pass's "comment outliers" turned out overwhelmingly to be dead code, not prose. Whole
files that are 100% comments: **✓** `BifurcanDigestIndex.kt` (132 lines) + its test (106),
`RecordHeader.kt` (66), `CsvSource.kt` (31), `ClientRestActionExecutor.kt` (48),
`ClientRestExecutionInitializer.kt` (20), `ResourceContent.kt`/`ResourceInfo.kt` (**✓** 30 + 14),
launcher/lib/auto `AsyncTest.kt` copies (~35 each). Large in-file blocks: `HeaderRunController.kt`
(~95 lines incl. the module's largest "comment block" at :878-936), `ClientInputUtils.kt` (~55),
`ObjectRegistryEdit.kt` (~55 — hiding write-only `previousError` state whose renderer is commented
out), `DocumentNameEditor.kt` (~35), `EdgeController.kt:184-204`, `VertexController.kt:847-858`,
`NotationMetadataReader.kt` (~45), plus ~25 smaller sites catalogued by the per-area reviews
(NotationCommand.kt's speculative commands, `common-action.yaml`'s ~55 commented lines,
`ReportInputPipeline`/`H2DigestIndex`/`ValueSummaryBuilder` tuning remnants, Spring-era residue in
launcher/shell). Several reference classes that no longer exist (`paradigm.imperative.*`,
pre-rename `objects.query.*`).

**Direction:** one sweep-delete pass per sibling (git history retains everything), and a
CODING_STANDARDS rule: *rejected alternatives get one line; disabled features get deleted* — the July
2026 comment audit caught history-narration but not comment-corpses, so the convention has a gap.

### T2 — Spec restatement in comments (dual-maintenance surface) ◐

logic-spec.md / architecture.md are declared the single home for behavior, yet the implementation
restates their content at nearly every site: the context-barrier rationale appears ~5× in
`RunEngine.kt` alone (field comment :140-155 + four walk sites), borrow-supersede ×4,
`Execution.kt` is 79% comments with `host()`'s 55-line KDoc restating §5/§6,
`ServerLogicController.kt`'s class KDoc + epoch field blocks re-derive architecture.md §3 (~40
trimmable lines), `JobRun.kt`'s 57-line KDoc restates the Job note + barrier a third time,
`ScriptMigrationState.kt` spends 35 lines on a 3-field data class, `ClientLogicGlobal.kt` mirrors
architecture.md §3's push-vs-poll gotchas point-for-point, and `ExploreWorker.kt` re-documents the
Worker base contract per subclass. History-narration is also re-accruing post-audit: "corrected
2026-08-03, ledger row 44" annotations in `LogicCompiler.kt:22` / `ReportLogic.kt:26`, and stale
cross-file *line-number* citations (`RunEngineParallelBindingTest.kt:162,222` cite RunEngine lines
that have drifted).

**Direction:** adopt "canonical rationale lives on the field or in the spec; other sites get a
one-line pointer"; never cite another file by line number (use symbol references). Estimated hundreds
of lines recoverable with zero information loss. Keep contract-bearing SPI KDoc as-is
(`StepExecution`, `JobControl`, `WorkerBase` were explicitly judged right-length).

### T3 — Silent error swallowing at seams ◐

Server: `RunEngine` swallows every third-party closer/capture failure via bare
`runCatching { it() }` in six places (:730, :719/:1627, :1234, :1388, :1480, :1547) — a failing
browser/process teardown vanishes; `PluginReportDefinitionRepository.kt:119-124` drops a throwing
plugin definer with `catch (Throwable) { continue }` and no log; `TableReportOutput.kt:166-168`
returns null on any exception. Client: `ajaxUtil.async {}` (its own comment: "TODO: what does this
really do?") turns any throw into an unobserved promise rejection; most call sites don't defend
(StorageManagerController's stuck spinner above is the visible symptom; `ClientLogicGlobal`'s
"the catch is load-bearing" comment shows the authors know).

**Direction:** one logged `runCloser` helper in RunEngine (fixes six sites + the duplication); log
before every seam-level swallow; a client-side `asyncWithErrorSurface` variant or a global
`unhandledrejection` → UI handler.

### T4 — Duplicate machinery + inconsistent keep-in-sync markers ◐

The launcher/shell/auto-test "no shared module" design makes some duplication deliberate — but the
convention that makes it safe (a keep-in-sync header, as `SecurityGate` and `BuildInfo` carry) is
applied inconsistently, and the unmarked copies are where drift was found:

- **Process management ×4 sites** ●: shell `MainJarProcess.kt:203-240` ↔ auto-test
  `KzenAutoProcess.kt:182-215` near-verbatim (kill/shutdown/readiness); child-side lifeline
  `KzenAutoMain.kt:69-97` ↔ `KzenLauncherMain.kt:55-83` byte-identical; `--server.port=` arg parsing
  ×3. One protocol, four places to change it.
- **Install path ×2** ●: zip-slip guard `ArtifactInstaller.kt:234-268` ↔ `ProjectCreator.kt:232-265`
  (already stylistically drifted — a security fix to one won't reach the other); `DownloadService`
  whole-file ×2 (drifted: Guava vs stdlib copy, different logging); atomic-move-with-fallback ×4
  (three inside kzen-launcher-jvm alone — extract one util there).
- **JS client substrate**: launcher deliberately trims kzen-auto's `ajaxUtil`/`React.kt`/
  `MuiAutocompleteField` — verified byte-identical-subset, healthy; but `Pages.kt`'s splash body
  (~35 lines ×2) is unmarked.
- `SecurityGate` *tests* have drifted more than the sources (shell keeps cases launcher dropped).

**Direction:** make the keep-in-sync marker a stated convention (CODING_STANDARDS candidate); align
the two zip-slip extractors line-for-line; consider whether the process-lifeline protocol deserves the
small shared jvm-util module these repos keep re-implementing.

### T5 — Alternate-implementation graveyard (pivot machinery) ◐

Only one variant of each pivot data structure is wired (`H2DigestIndex` — **✓** verified sole
production impl), but the benchmarking era survives in main sources: **✓** `FileDigestIndex.kt`
(286 lines, consumed only by its own test), `MapDigestIndex`, `MapRowValueIndex`, the fully-dead
`stats/map/` subpackage (~85 lines, zero consumers *including* tests for `MapValueStatistics`), plus
the commented-out Bifurcan experiment (T1). ~700 lines main + ~250 test deletable, or move
reference impls under test sources if they serve as oracles.

### T6 — Dead / consumer-less API surface ○→◐

Two distinct categories that currently look identical in the code:

- **Spec-led, deliberately unconsumed** (documented): `observeFrames`/`observeResets`, Tuple `detail`.
  Fine — but `retainedBindings()`/`releaseRetained()` has no such marker and reads as live API.
  Adopt a consistent "unconsumed — awaiting X" annotation.
- **Accidentally dead** (verified zero references): **✓** `MirrorMetadataReader`, **✓**
  `Digest.OrderedCombiner`, ~8 unused `Digest.Sink` members, `YamlNode.ofMap/ofList`,
  `DocumentName.withoutExtension` (can't ever do anything — the name pattern forbids '.'),
  `PositionRelation.parse`/`PositionIndex.parse`, `DirectGraphStore.publishFailure/publishRefresh`,
  `GraphNotation.filterPaths`/`mergeObject` (test-only), `NavigationGlobal.returnTo`/`returnPending`,
  `ClientStateGlobal`'s `runningKey` branch (its only would-be writer is commented out),
  `ajaxUtil.httpDelete`, `CommonRestApi.commandBenchmark`, `ActiveFlowModel`, `VisualVertexTransition`,
  `DetachedExecutor` interface, `AutoJvmUtils`, `LogicRunFrameState`, launcher `IoUtil` (72 lines in
  commonMain shipping to JS), shell `ProcessRegistry.get/unregister(name)`, tombstone infrastructure
  whose only readers are tests, `ProjectRegistry.contains`, `RestHandler.getParamList/OrNull`,
  `RunEngine.Parked.reason`, plus ~440 lines of KMP wizard template residue
  (`getAnswer`/`getAnswerBar`/`assertEquals(42, 42)` stubs) across four siblings.

### T7 — Test topology ●

- **kzen-auto-js: 58,450 main lines vs 614 test lines (0.011)** — every document UI (script 14.4k,
  report 10.1k, job 7.0k, flow 3.1k), the ribbon, sidebar, `ClientLogicGlobal` (a genuine state
  machine), and `ClientRestApi` are untested. Same shape in kzen-launcher-js (2,704 : 52). The client
  stores and the drag-reorder arithmetic (T9) are logic, not rendering — the testable-first targets.
- **`RunEngineTest.kt` is 3,764 lines / 93 tests in one class** — its banner regions already define a
  4-way split (control / migration / context / trace) with a per-concern precedent
  (`RunEngineParallelBindingTest`); shared fixtures (`logicOf` is already duplicated between the two
  engine test classes) want a package-private fixtures file. Note the AGENTS.md pin references by
  test name when moving.
- **Common code is tested on JVM only**: kzen-lib's notation/reducer suites live in kzen-lib-jvm;
  kzen-auto keeps `tech.kzen.auto.common.*` tests inside kzen-auto-jvm — JS actuals and common paths
  never execute on JS (CC-13 wants commonTest). Older tests also sit in non-mirroring packages
  (`common.model`, `common.notation` — no such main packages).
- **Zero-test modules**: `kzen-lib-reflect-ksp` (the codegen everything depends on) and
  `kzen-auto-plugin` — whose 3,221 lines of Java (`FastDoubleMath` 1,069, `FlatFileRecord` 627) are
  hot parse-path code and third-party SPI surface: the riskiest untested code in the tree.
- Test-harness duplication: the `awaitState`/`awaitDone` poll loop is copy-pasted 22× across 12
  kzen-auto-jvm test files; `private val snapshot get() = …` recomputes a full notation disk scan +
  graph define per access in 6 files.

### T8 — Wire-format sprawl (known, tracked) ◐

Five serialization mechanisms coexist: hand-rolled notation YAML (also a command wire payload),
kotlinx JSON (40 `@Serializable` files), hand-rolled `toCollection` map codecs (16 files remain,
5 of which carry *both* codecs today), Jackson 3 YAML (launcher registry only), and the query-string
codec. This is the in-flight SER1–SER5 migration (`docs/plans/2026-07-25_core-and-verification.md:121-161`)
— the finding is *scope, not surprise*: the un-migrated tail is exactly the 16 `toCollection` files +
`LogicTraceEndpoint`'s detached payloads. Finish or explicitly park. Related layering wart flagged by
two reviews independently: `ExecutionValue.kt:22` self-identifies as
`tech.kzen.auto.common.paradigm.common.model.ExecutionValue` — a kzen-auto FQN that no longer exists
anywhere (executable metadata, not a comment; the release train makes a coordinated rename feasible —
check `../kzen-proj` notation first). Same pattern: `ObjectLocation.kt:26` pins the legacy
`model.locate` FQN — that one is load-bearing wire compat (kzen-base.yaml:137) and just needs a
"do not modernize" comment.

### T9 — Copy-paste families in the JS client ●

- **✓ Drag-reorder document-index arithmetic ×5**: `ContextsController.onReorderDrop:476-531` is
  line-for-line `LogicSignatureEditor.onReorderDrop:373-433` (verified by diff — only variable names
  differ); `IfStepDisplay`, `ScriptBranchDisplay`, `JobController.performShift` carry local variants.
  This is the package's trickiest index math (off-by-one corrupts notation order) with zero tests.
  Extract pure functions into `common/dragdrop` — or commonMain, where they become unit-testable.
- **Type picker + nullable toggle ×3** (`LogicSignatureEditor:758` / `ResultSignatureEditor:266` /
  `ContextsController:760`, ~50 lines each) with private re-declarations of `TypeMetadataDefiner`'s
  key constants; **stage float-stack CSS ×5** with magic row offsets coordinated by prose comments
  (`JobChannelDefaults.kt:65` records the shipped overlap bug this caused); **inline add-name form
  ×3** (SortSpecEditor/ValueSetFilterEditor/FormulaMapAdd, ~120 lines each, self-acknowledged
  "Mirrors FormulaMapAdd, inlined here"); `formatCount`/`abbreviateValue` ×3 alongside an existing
  `FormatUtils`; deepest-first subtree removal ×2 (self-acknowledged). Applying just the first three
  extractions shrinks `ContextsController` from 962 to ~600 lines with no new seams.
- Server-side mirror of the pattern: `ServerLogicController`'s control-verb preamble ×9 and
  drive-block ×6; `LogicHandler`'s 8 identical control verbs; the `documentPath`+`objectPath`
  extraction pair hand-rolled ~21× across handler files; `KzenAutoMain`'s ~40 near-identical route
  blocks (~120 lines mechanically removable while preserving the documented route-group structure).

### T10 — Generation gap & strategic decisions ◐

The two retired paradigms (imperative, visual-dataflow) were already excised — no whole removable
subtree remains. What's left is decision debt:

- **✓ DataFormat document type is inert**: registered, user-creatable, editable (~600 lines across
  common/js/jvm + 3 yaml blocks) — and nothing consumes what it edits (zero references outside its
  own cluster; zero in kzen-project). Wire it into Report input (apparent intent) or retire it.
- **`flow/` (client) predates the render-discipline rules and violates most of them**: hover as React
  state with a `Date.now()` dangling-timeout hack (`VertexController`/`EdgeController` — against
  js-architecture §7's CSS-`:hover` rule), grid-global edge/message sets recomputed per edge cell per
  render (O(V·E)-scale ×cells; `FlowController.nonEmptyDag:549` already fixed exactly this for
  `nextToRun` and the `// TODO: refactor` at EdgeController:332 flags the rest), dead
  `processingOption` field, `goldLight20`/`goldLight25` both `"#ffe13f"`, plus `ScriptStepDisplayDefault`
  importing its colors from `EdgeController`. Either one modernization pass or an explicit "legacy,
  don't invest" marker so audits stop re-flagging it.
- **Report vs Job**: report/ is ~10.1k JS + 96 jvm files; job/ is its declared successor-in-progress
  (~7.0k JS) sharing Report's substrate. The plans ledger owns this — structural refactors of report/
  should defer to it, but it makes report/ the single largest future deletion and argues against new
  investment there.
- **Task paradigm** (~900 lines across the stack, one test-fixture implementation) is a
  docs-declared extension point — kept, flagged for awareness only.
- Old-flow files also carry the old style (8-space continuations, stale TODOs naming retired
  concepts) — normalize on touch.

### T11 — Doc drift ○

Load-bearing docs with rotted specifics: kzen-lib architecture.md:314 lists `server/codegen/` (only a
ghost dir exists); js-architecture.md §4 shows `object ClientContext { fun init() }` vs the actual
`class … private constructor` + `create()`; launcher and shell AGENTS.md:67 both cite
"`ProjectCreator.kt:62` renames the jar" (no such rename exists); kzen-lib AGENTS.md package map still
lists the dead resource classes. Any comment or doc citing another file by line number is already
wrong (see T2).

---

## Selected per-sibling findings not covered above

### kzen-lib

- ◐ `RunEngine.kt` (1,795) — **large but mechanically cohesive**; single-writer-owns-everything under
  one lock is the documented design answer to prior sprawl, so no split is *required*. If it must
  shrink, the crispest seam is the context/binding registry (~330 lines, touches only per-node state),
  second the migration barrier (~350 lines with its five registers). Do not split the lock.
  ○ `settleNode` deep-copies a Node subtree per settle even when `frameObservers` is empty (the
  production case) — guard on `frameObservers.isNotEmpty()`. ○ `childLogic` field declared mid-file
  away from the state block. ○ `host` takes 8 positional params incl. two booleans.
- ◐ `ServerLogicController.kt` (1,168) — five concerns; two clean seams: the move-to reposition gate
  (:700-903, no LogicState mutation — extractable as `RepositionGate`, → ~950 lines) and the status
  projection (~130 lines). The run-state machine + observer fan-out + migration flags stay.
- ◐ `ScriptRunContext.kt` (969) — extract the typed-context adapter (:289-445, mechanical) and a
  `ScriptReplayState` owning the five migration maps; ~500-line core remains.
- ◐ `NotationReducerRefactor` — reference-rewriting refactors do a full-graph scan per moved object
  (O(K·G) per container, O(D·R·G) per folder move); build the reverse-reference index once per
  refactor. Interactive scale today; folder moves pay it first.
- ◐ `Digest.kt` (799) — unordered-combine boilerplate ×4 (three variants are one-liners over the
  fourth); `Builder.addBytes` hashes per byte through two virtual calls on the hot string path while
  `ofBytes` has the tight loop; two different null-encoding conventions inside one Sink API;
  plus the dead members (T6).
- ○ `ObjectNesting` ↔ `AttributePath` copy-paste escape-aware delimiter machinery (only the delimiter
  char differs); `NotationEvent.kt` repeats `documentPath get() = objectLocation.documentPath` ×13
  (the sealed intermediate that fixes it already exists for one subfamily); `ObjectNotation.get`
  re-implements a traversal that exists on `AttributeNotation`; `MapAttributeNotation.merge` makes ~5
  passes where one suffices; single/bulk reducer handler twins; `RunEngineLogicTrace.lookupBinary`
  re-hashes every retained binary per blob fetch (O(N²) per run of screenshots) — index digest→bytes
  once, or memoize the digest on `BinaryExecutionValue` (fixes producer and consumer).
- ○ `FileNotationMedia.readDocumentSynchronized` null-juggling ending in `modified!!`; suspend→
  `@Synchronized` method-pair doubling ×11 (mechanical 2× method count — a `sync {}` helper halves it);
  `ClasspathNotationMedia.readResource` is `TODO()` where siblings throw UOE; mixed JUnit4/kotlin.test
  annotations (34 vs 2 files).

### kzen-auto-jvm

- ◐ `PivotBuilder` — row-materialization duplicated between the CSV download's inline loop and
  `traverse`; the download spawns an unnamed raw Thread where an exception can strand the piped
  reader. Route download through `traverse`'s visitor.
- ◐ `PrimeFilter` vertex is compiled + `@Reflect`-registered but its notation registration is
  commented out under a pre-rename package — uninstantiable; re-register or delete.
- ○ `ScriptLogic`/`FlowLogic` context-prologue copy-paste (~35 lines each, third variant inline in
  `ScriptRunContext.checkUsedContexts`) — centralize before the next flavour makes it ×4;
  `callSiteBindings` memo duplicated FlowRun↔ScriptRunContext (move into `ContextCallSite`);
  `ScriptValidationCache` ↔ `JobValidationCache` structural twins; `ReportDocument`'s
  runId-extraction and pattern-compile helpers ×2 each; `ValueSummaryBuilder.addSample` overload
  twins + mixed `Math.random()`/seeded-Random; `ModelTaskRepository` observer handles only the first
  matching task and blocks store-observer dispatch on `awaitTerminal`.

### kzen-auto-common

- ◐ Hard-keyword set duplicated verbatim between `KotlinExpressionAnalyzer` and `ExpressionUtils`
  (drift desynchronizes escaping from tokenization); `ChannelTypeDefiner` re-spells
  `JobChannelPorts`' FQCNs with an explicit "keep the two in sync" comment (derive one from the
  other); `isFlow`/`isScript`/`isJob`/`isContextsDocument` ×4 verbatim (shared helper + thin
  domain wrappers, per the domain-scoped-conventions preference).
- ◐ `paradigm/flow` ↔ `objects/document/flow` bidirectional dependency: `FlowMatrix` (paradigm)
  imports FlowConventions/FlowWiring (objects) and reads document notation, while objects imports
  FlowMatrix/FlowDag back. Move `model/structure` under `objects/document/flow/model`, leaving
  paradigm/flow as the vertex SPI — matches the documented boundary.
- ○ `EdgeOrientation`: five predicate when-chains over 13 variants (~150 lines) where enum
  constructor booleans remove the silent `else -> false` miss mode; three near-identical
  orientation-following edge walkers with an unstated termination argument; `ChannelTypeDefiner`
  scans the whole graph per channel definition (scope to the owning document);
  `LogicConventions.isMissingError` classifies by substring-matching message prose;
  `DetachedExecutor` interface (T6); `DataLocation.parent()` per-OS string surgery that belongs in
  `FilePath`/`Url` where type discrimination lives.

### kzen-auto-js (beyond T9/T10)

- ◐ `ClientLogicGlobal` (1,073) — three separable responsibilities; the SSE+adaptive-poll transport
  (~260 lines) touches the rest only via `applyStatus`/`isExecuting` and is the extraction if it
  grows further. Not urgent; internal sectioning is clean.
- ◐ `TargetController` — implicit fetch state machine across 12 nullable fields advanced from
  `componentDidUpdate` (`Boolean?` compared with `!= true`), `setTimeout` fetch with no cancellation
  epoch; the only large document type with no `model/` store. Introduce `TargetStore` + a phase enum.
- ◐ `JobController` stores whole `ClientState` in component state — the documented anti-pattern its
  same-vintage sibling `FlowController` documents avoiding; bounded damage, easy fix.
- ○ Guard-then-assign N-field boilerplate (11-conjunct guard in `ScriptStepDisplayDefault`) — one
  immutable data-class slice per subscription; `HeaderRunController`'s 8 toggle-button render
  functions repeat the styling block (~150 lines); projection-`Builder.update` memo micro-pattern
  hand-copied ×3 (tolerable; a 4th copy justifies a shared helper).

### kzen-launcher / kzen-shell / kzen-project

- ◐ `ProjectItem.kt` (677) — the upgrade feature is a self-contained ~280-line seam (state, dialog,
  candidate logic); extract `ProjectUpgradeControl`, leaving a cohesive ~400-line item.
- ◐ Shell `ProcessRegistry` tombstone infrastructure: written/cleared in production, read only by
  tests — wire into a real consumer or remove the map + choreography protecting it.
- ○ `DesktopUi` pane triplication (logo-header + big-label blocks ×3); mutable `port`+`setPort()`
  temporal coupling on a singleton; `ProxyHandler`'s acknowledged "TODO: centralize" launcher-jar
  path computed in two places with stringly-typed attribute keys; launcher command handlers run
  blocking filesystem work on Ktor coroutines without `Dispatchers.IO` (one line in
  `respondCommand`); `listArchetypes` DTO mapping lives in the route layer while every sibling's
  lives in RestHandler; the `"unknown"` archetype sentinel defined independently in server, DTO
  default, and client; spinner-in-button block ×4 (uiDsl.kt exists for exactly this);
  `ArchetypeDetail` has `var` fields among all-`val` siblings.

---

## Deliberately not flagged

Declared-deliberate designs the reviews checked and cleared (recorded so future audits don't re-litigate):

- **RunEngine's single-owner scale** (logic-spec §8), its unreachable defence-in-depth branch, the
  deprecated-not-removed `declareExport(String)` family, `observeFrames`/`observeResets`,
  `CountingDispatcher`'s two-lock-ops design, `snapshot()` deep-copy-per-dirty-read — all
  spec-documented.
- **Large-but-cohesive files**: `YamlParser` (allocation-lean by design; only three local
  duplications flagged), `GraphNotation`, `KotlinExpressionAnalyzer` (regex alternatives explicitly
  forbidden), `KzenAutoMain`'s flat route structure, `TemplateMatcher`'s brute-force NCC,
  `CachedKotlinCompiler`, `ClientRestApi`'s flat method-per-endpoint catalogue,
  `ClientRestGraphStore`'s 30-arm exhaustive when, `ScriptExecutionMargin`, `KotlinCodeArea`,
  `ScriptBranchDisplay`, `SidebarFolder`, `ProjectController`'s auto-follow, `FlowRun`'s
  capability-interface dispatch (CC-17 compliant), `ScriptRunContext.runSteps`' invariant chain.
- **No shared run-lifecycle base** for Script/Flow/Job/Report runs — the shared lifecycle *is*
  kzen-lib's `Execution` seam; beyond it the shapes genuinely differ.
- **Contract-bearing SPI KDoc** at full length: `StepExecution`, `JobControl`, `WorkerBase`,
  kzen-auto-plugin's concurrency contracts, kzen-project's sample KDocs (declared living docs).
- **Deliberate duplication**: BuildInfo ×3 (no shared module), launcher's trimmed-subset wrap layer,
  managed-lifeline reaper (documented in code), `SecurityGate` (marked), Report↔Job editor
  parallels (declared "trimmed analogues" sharing commonMain command builders).
- **Design idioms**: mutable digest-cache slots on immutable data classes (repo-wide benign-race
  memo idiom — treat as one decision in any concurrency review), typed-map wrapper quartet (suffix
  glossary), erased-generics `empty` singletons, `SeededNotationMedia` vs `MapNotationMedia`
  (semantically distinct), GET-based command endpoints (compensated by SecurityGate + tests,
  loopback-only), `ArchetypeRepo` scan-is-the-catalogue, adaptive polling loops
  (LauncherStore, JobDeadlockMonitor, `awaitStepSettled` — each documented), `ShellSimulator` in
  main sources (config-gated), Task paradigm (extension point), `ReportController` whole-state
  storage (explicitly grandfathered — new code held to the newer rule, hence the JobController flag).
- **False positives from filename-level deadness sweeps** individually verified live:
  TargetSpec cluster (3,207 lines — consumed by 4 browser steps' notation), `VisualVertexModel`
  (FlowProgressStore), DragDropPrimitives, Notation*Commands handlers, PersistentCollections,
  wrap/* externals, and ~15 more catalogued by the cross-cutting review.

---

## Suggested sequencing

1. **Bug fixes** (§ Correctness) — small, independent, high value; `copyResource` + a test,
   `DownloadClient` deletion, `importProject` validation, `ColumnValue.plus`, StorageManager error
   surfacing, observer mount-race guard.
2. **Dead-code sweep** (T1 + T5 + T6 accidental column + template residue) — pure deletions,
   ~2,000+ lines, zero behavior risk, one commit per sibling. Includes the yaml comment-corpses and
   ghost dirs; update the two AGENTS.md/architecture.md references that name deleted files.
3. **Error-surfacing pass** (T3) — `runCloser` helper, plugin-load logging, client async convention.
   Small diffs, immediate debuggability payoff for the upcoming feature work.
4. **JS extraction pass** (T9) — drag-reorder arithmetic into commonMain *with tests* (converts the
   scariest untested logic into the best-tested), then type-picker/float-stack/add-form helpers.
5. **Comment right-sizing** (T2) — mechanical but judgment-heavy; do per-file alongside other
   touches, anchored by the "canonical home + pointer" rule; add the two conventions
   (keep-in-sync marker, no line-number citations, delete-don't-comment) to CODING_STANDARDS.
6. **Decisions to schedule, not drive-by**: DataFormat wire-or-retire; flow/ modernize-or-mark-legacy;
   SER migration tail (16 files) finish-or-park; `ExecutionValue` FQN rename (release-train
   coordinated); RunEngineTest 4-way split; `ServerLogicController`/`ScriptRunContext` seam
   extractions when those files are next under change anyway.

Intermediate metrics data was session-scratchpad-only and has been discarded; no `docs/audit/raw/`
was created.

---

# Remediation record (2026-08-16, same day)

Everything below was implemented in the same session, immediately after the audit. **Uncommitted:**
new files staged by explicit path, edits and deletions left unstaged, nothing committed in any repo.
Steps 1–5 of the suggested sequencing are done; § Decisions records what was deliberately not done.

## Corrections to this audit found by implementing it

Recorded first, because they are the most reusable output: five audit claims did not survive contact
with the code. Future audits should treat these as calibration.

| Claim | Reality |
|---|---|
| `PositionRelation.parse` / `PositionIndex.parse` are dead (T6) | kzen-auto calls `PositionRelation::parse` as a **method reference** — a `Name.member` grep cannot see it. Deleting it broke the kzen-auto build; restored. (`PositionIndex.parse` was genuinely dead.) **Lesson: verify deadness with `::member` and bare-name greps, not just `Type.member`.** |
| T8: an in-flight SER1–SER5 migration with an un-migrated tail | SER2–SER5 **landed and are marked COMPLETE** in the closed sprint-2 record (2026-07-18). Of 13 `toCollection` files (not 16): 8 are Report-domain (frozen, slated for Job subsumption — investing is counter-indicated), and the 5 dual-codec files carry both codecs *by design* because they cross the REST wire **and** the engine's `ExecutionValue` value-tree, annotated in-code (`LogicRunExecutionInfo.kt`: "SER4: VALUE-TREE only (not @Serializable)"). Nothing to migrate. |
| Observer mount-race at ~5 sites | **20 sites.** All now guarded. |
| "Mixed JUnit4/kotlin.test (34 vs 2 files) — normalize the 2 outliers" | Inverted. The 2 named outliers were already on kotlin.test; the real work was 34 JUnit4 files. All converted. |
| Copy-paste counts | Undercounts throughout: the handler `documentPath`+`objectPath` pair was **28** sites (est. ~21); the test poll-loop was **26 copies / 16 files** (est. 22 / 12); the archetype predicate was **×5** (est. ×4). |

A sixth correction was to a *verification done during remediation*, not to the audit: a main-session
grep concluded `ExecutionValue.typeMetadata` had zero consumers; it has two. The deletion was avoided
only because the task carried an explicit fallback ("if you find a consumer I missed, correct the
string instead"). **Give every delete-this instruction a fallback.**

## Bugs found while remediating (not in the audit)

- ● `FlatFileRecordField.detach()` never assigned the detached flyweight's field index, so it kept the
  `-1` marker and every numeric accessor threw `ArrayIndexOutOfBoundsException`. **Fixed** (zero call
  sites, so nothing could break).
- ◐ `FlatFileRecordField.equals(null)` threw NPE — dereferenced before any null check. **Fixed.**
- ◐ `LogicConventions.isMissingError`'s third clause is **already dead**: it matches
  `'<executionId>' not found`, but `missingExecution(...)` has zero call sites and the real producer
  (kzen-lib `RunEngine.request`) returns `"No request handler for node: <nodeId>"`. Net effect: a
  request against a vanished node surfaces to the user as an error instead of being swallowed —
  touches the Report online-preview path (architecture.md §1, ledger row 45). **Not changed**; needs
  the owner of that path. The classifier now reconstructs messages from `LogicConventions`' own
  builders, so producer and classifier cannot drift again.
- ○ `InsertedListItemInAttributeEvent.item` carried the pre-insert list instead of `command.item`
  (zero readers). Fixed incidentally.
- ○ `ObjectRegistryEdit` suppressed the global error banner with no local renderer left, so a failed
  class removal vanished silently. Now reaches the banner — the one deliberate behaviour change in
  the JS dead-code pass.
- **Not fixed, deliberately:** `DataFrameBuffer.hasFull()` returns `true` for an empty buffer, which
  reads as obviously wrong — but its only consumer depends on it: at `count == 0` the current value
  yields a drain range of `0..-1` (a no-op), whereas "correcting" it routes into
  `partialInput.addFrame(buffer, 0)` against an unwritten `lengths[0]`. Documented in place.
  Two further latent defects need author intent: `FlatFileRecord.clearWithoutCache()` leaves a stale
  parsed-value cache, and `DataRecordBuffer.setFrame()` never clears the other representation.

## What landed

**Correctness** — every § Correctness finding fixed: `copyResource` destination (with a
negative-verified regression test), `DownloadClient` deleted (closing the process-global trust-all
SSLContext), `importProject` name validation, locked-project rename → 409, `ColumnValue.plus`
`"nullabc"`, StorageManager's stuck spinner (3 sites, not 2) + stale-base race, 20 observer
mount-races, `RibbonController.updatePending`, `ConcurrentHashMap` icon cache, `Files.walk` leak,
`ReportRun` `!!` → failure result, `DocumentNotation` not-found message.

**Dead code** — ~3,400 lines across the tree (kzen-lib 592, kzen-auto-js 802, plus kzen-auto-jvm's
pivot graveyard, both 100%-comment JS files, launcher/shell tombstone + Spring residue, and KMP
wizard-template residue in four siblings).

**Error surfacing (T3)** — seven bare closer `runCatching` sites behind one logged `runCloserLogged`;
plugin-definer and preview failures logged; `ajaxUtil.async` no longer swallows rejections.

**Comments (T2)** — canonical-home-plus-pointer applied to RunEngine (context barrier ×5,
borrow-supersede ×4), `Execution.host` (55 → 33), `ServerLogicController`, `ClientLogicGlobal` (−133
comment lines), `JobRun`, `ScriptMigrationState`, `ExploreWorker`; history-narration annotations
removed from `LogicCompiler` / `ReportLogic`.

**Duplication (T4/T9)** — drag-reorder index arithmetic (5 copies → one tested commonMain function),
`FormatUtils`, `ObjectSubtreeRemoval`, `LogicTypePicker`, `AddNameForm`, `StageFloatStack`,
`AtomicMoveUtil` ×2, zip-slip and `DownloadService` aligned, control-verb preamble 9→8, drive-block
×6, LogicHandler's 8 verbs, 28 handler param-pairs, 57 route blocks, 26 test poll-loops.
CC-21 keep-in-sync markers now reciprocal on every deliberate cross-repo copy.

**Structure** — `ScriptRunContext` 969→576, `ServerLogicController` 1,168→1,023, `KzenAutoMain`
743→594, `TargetController` 827→368 (implicit 12-field machine → three sealed channels + a tested
pure transition table), `ProjectItem` 678→429, `HeaderRunController` −122, `ScriptStepDisplayDefault`
658→528, `RunEngineTest` 3,764 lines → 4 classes + shared fixtures (93 tests preserved exactly).

**Tests** — `kzen-auto-plugin` went 0 → 94 (the audit's "riskiest untested code"; it immediately
surfaced 5 latent bugs). New tested commonMain logic: 21 (drag-reorder) + 9 (subtree removal) +
9 (target fetch plan) + 8 (format) + 34 (kzen-auto-common findings). kzen-lib moved 33 tests to
`commonTest`, so they now execute on JS as well as JVM — **no JVM/JS divergence was uncovered**,
which is itself the result. Counts at last green run: kzen-lib-jvm 193, kzen-lib-common 305 ×2
(JVM+JS), kzen-auto-jvm 688, kzen-auto-common 258 ×2, kzen-auto-plugin 94.

**Conventions** — three new rules in `docs/CODING_STANDARDS.md`, each codifying a pattern this audit
found: **CC-19** commented-out code is deleted code, **CC-20** rationale has one canonical home and
never cites line numbers, **CC-21** deliberate duplicates carry reciprocal keep-in-sync markers.

**Docs (T11)** — the `main.jar` "rename" claim corrected in both launcher and shell AGENTS.md (no
rename exists; every dist zip ships it at the root and both installers only verify it), the ghost
`server/codegen/` source dir, and two stale `ClientContext` sketches in js-architecture.md.

## Decisions

- **DataFormat: parked** at the user's explicit request — revisit where it should go later.
- **`flow/`: modernized where safe, marked legacy otherwise.** The O(V·E)-per-cell recomputation was
  hoisted into `FlowEdgeRouting` (dropping `egressColor` from 9 parameters to 3), dead field and
  duplicate colour constants removed, colours moved out of `EdgeController` so a script-side file no
  longer imports a flow-side controller. Hover-as-React-state and the `Date.now()` timeout are
  deliberately untouched behind a 4-line marker naming them as the known §7 deviations.
- **SER migration: nothing to do** — see the corrections table.
- **`paradigm/flow` ↔ `objects/document/flow` cycle: deferred as one atomic change.** It is a single
  import edge, but the move reaches 8 files across kzen-auto-js and kzen-auto-jvm, `FlowUtils` must
  move too or the edge re-forms, and architecture.md §1 needs a matching correction.
- **`ServerLogicController`'s status projection: not extracted.** It derives `runState` from
  `LogicState`'s five volatile flags and mutates monitor-guarded state under the controller's
  `@Synchronized`; extracting it would move lock-guarded mutable state outside its lock's owner.
- **kzen-auto's `tech.kzen.auto.common.*` tests: not moved.** All 11 load fixtures from the on-disk
  notation corpus via `FileNotationMedia`; 7 additionally need `GraphDefiner.tryDefine` (JVM-only by
  construction). The other 4 (24 tests) are JVM by *fixture*, not by API — moving them means
  rewriting fixtures as inline YAML with stand-in archetypes, which silently deletes assertions like
  `ContextConventionsTest`'s explicit fixture anchor. That is authoring different tests, not moving
  them; recommended as its own scoped task.

## Endgame verification (2026-08-16, quiet tree)

Run single-threaded with nothing else building, in dependency order: `kzen-lib` build → `kzen-lib`
`publishToMavenLocal` → `kzen-auto` build → `kzen-project` → `kzen-launcher` → `kzen-shell`.
**All six repositories BUILD SUCCESSFUL; 2,227 tests, 0 failures, 0 errors, 1 skipped** (the
pre-existing `@Ignore`).

| Suite | Tests |
|---|---:|
| kzen-lib-jvm | 193 |
| kzen-lib-common jvmTest / jsBrowserTest | 305 / 305 |
| kzen-lib-js | 1 |
| kzen-auto-jvm (117 classes, 1 skipped) | 688 |
| kzen-auto-common jvmTest / jsBrowserTest | 258 / 258 |
| kzen-auto-js | 22 |
| kzen-auto-plugin | 94 |
| kzen-auto-test | 4 |
| kzen-launcher jvm / common ×2 / js | 38 / 11 / 11 / 1 |
| kzen-shell | 31 |
| kzen-project jvm / common / js | 3 / 1 / 3 |

Two open questions closed by this run:

- **`BinaryExecutionValue.contentHash()` landed**, not reverted. `RunEngineLogicTrace`'s three call
  sites (`lookupBinary` ×2, `toWireValue`) now call it, and the file's `Digest` import is gone. The
  memoized hash is live on both sides of the trace-binary exchange.
- **The `:kzen-auto-jvm:test` result-finalization failure did not reproduce solo** — the full build
  passed in 4m 29s with the configuration cache stored. It was induced by concurrent Gradle
  invocations, not a Gradle 9.6.1 defect on the documented command. No workaround is needed.
- The kzen-auto-common count that the two agents reported inconsistently is confirmed at **258**,
  identical on JVM and JS.

## Second pass — the deferred follow-ups (2026-08-16, same day)

All four remaining follow-ups were closed. kzen-auto ends at **1,358 tests, 0 failures**
(common 266 ×2, jvm 688 + 1 pre-existing skip, plugin 112, js 22, e2e 4).

**The three latent `kzen-auto-plugin` defects.** `DataRecordBuffer.setFrame()` now assigns *both*
lengths the way `copy()` always did — a frame is byte-content or char-content, never a mix, and
`length()` takes the max, so a stale sibling length outlived the content it described. Two
regression tests pin it in each direction, with the discarded frame deliberately longer than its
replacement so a stale count would win. `FlatFileRecord.clearWithoutCache()` was **deleted**: zero
call sites across every sibling including `kzen-sample-plugin`, and no valid call pattern existed —
it reset the content while keeping the parsed-value cache, so the next occupant of a field index
read the previous record's number. Keeping a public SPI method whose only possible effect is silent
numeric corruption is worse than a source-compat break, which a downstream plugin would hit loudly at
compile time. `LogicConventions.isMissingError`'s dead third clause and its unused
`missingExecution` builder are gone; the classifier is now explicitly scoped to the *run*, and the
KDoc records why a vanished node is **not** swallowed — `RunEngine`'s "No request handler for node"
is also what a genuinely unregistered handler emits, so treating it as a teardown would hide a
wiring defect (T3). A test pins that non-swallowing.

**Plugin coverage.** `ListPipelineOutput` and `DataFrameFeeder` — the two named gaps — went 0 → 18
tests. The slot-reuse contract is pinned by identity assertions, since a correct-looking
implementation that reallocated per flush would satisfy every value assertion. The feeder's tests
cover a record spanning three blocks and, notably, the empty end-of-data block that only works
because `DataFrameBuffer.hasFull()` answers `true` when empty — the trap documented earlier in this
audit now has a test naming it.

**`AutoTestUtils.readNotation()`** is memoized on the object, so all 114 call sites share one parse.
Measured A/B on the same three classes: **23.3s → 17.1s of test time (27% faster)**. Deliberately
*not* extended to `graphDefinitionAttempt`: an `AttributeDefiner` may embed a live object in the
definition it returns (`FlowWiring` mints `MutableRequiredInput` / `MutableFlowOutput` channels), so
definitions are not shareable across tests the way notation and metadata are.

**The CC-07 smalls.** `FlowMatrix`'s commented-out `println` block deleted, plus four more found in
`DataFrameFeeder`. `DataLocationInfoTest`'s five tests moved into `DataLocationTest`, where they
belong — they exercise `DataLocation`, not `DataLocationInfo`. `DataLocation.fileName()` now
delegates to new `FilePath.fileName()` / `Url.fileName()`, shedding the per-OS surgery exactly as
`parent()` did, with 7 new tests including the drive-root, network-share and bare-host cases that
made the surgery look necessary.

**The `paradigm/flow` ↔ `objects/document/flow` cycle is broken** — and far more cheaply than the
atomic three-module move this audit proposed. The two things `FlowMatrix` reached up for turned out
to be paradigm-level all along: the `vertices` / `edges` attribute shape, and input queries keyed on
the paradigm's own `OptionalInput` / `RequiredInput` markers. Both moved *down* into a new
`FlowStructureConventions` beside `FlowMatrix`; `FlowConventions` aliases them (the established
`ScriptConventions`-over-`LogicConventions` pattern) so no document-side call site churned, and
`FlowWiring` is left doing only what its name says. Four files, no notation-FQN rename, no 30-file
sweep. `FlowStructureValidatorTest` also moved to the package of the class it tests (CC-13).

**A live bug found while doing it.** `FlowWiring`'s six hard-coded channel `ClassName`s named
`paradigm.flow.api.OptionalInput` and friends, but those classes have lived in `api/input/` and
`api/output/` subpackages for some time. It never broke because `common-flow.yaml` carried the *same*
stale FQNs and the two are only ever compared as strings — and because every marker is
`abstract: true`, so nothing ever tried to load one. Both sides corrected together, now with
reciprocal keep-in-sync markers (CC-21). This is the shape CC-21 exists for: two copies that must
agree, where agreement alone is enforced and correctness is not.

**Target document smoke test.** Booted the built jar on a spare port against a scratch project (the
`empty-project` fixture plus a copy of `main/Action Target`), then headless Chrome. The client graph
boots (827 KB DOM, app header rendered) and the Target document renders end-to-end: all three crops
enumerated, a live capture taken, template matching run, per-crop scores and "No matches — target not
found" displayed, tolerance selector present. No server exception, no page console error. That
exercises behaviour change #1 (the store's subscription source) and the whole fetch → locate → render
wiring, which is what unit tests cannot reach. *(A `Command error: undefined - null` in the DOM dump
is a false positive worth remembering: that banner is always mounted and hidden by CSS, and
`--dump-dom` ignores `display: none` — the literal `undefined` proves the field was never assigned.)*

## Open follow-ups

1. **Three Target behaviour changes remain un-exercised at runtime** — mid-flight refresh
   re-fetching, locate re-armed while in flight, and match re-run when switching between two Target
   documents. All three are interaction-timing behaviours; their *logic* is pinned by
   `TargetFetchPlan`'s 9 commonTest tests, and the smoke test above proves the wiring reaches that
   logic, but the transitions themselves need a hands-on pass.
2. **DataFormat** (~600 lines, inert) — parked at the user's request; wire it or retire it.
3. **Report vs Job succession** — a plans-ledger decision. The 8 frozen Report-domain files are
   slated for Job subsumption, so investing in them stays counter-indicated until it is made.
4. **kzen-auto's tier-2 `commonTest` migration** (4 files, 24 tests) — JVM by *fixture*, not by API;
   moving them means re-authoring fixtures as inline YAML, which is writing different tests rather
   than moving them. Its own scoped task.
