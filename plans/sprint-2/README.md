# Sprint 2 — consolidated record (closed 2026-07-25)

Historical archive of the plan documents whose work landed in Sprint 2 (2026-07-16 → 2026-07-25).
**Nothing here is needed for future work**: every still-open phase, decision, dependency edge and
gotcha was carried into the fresh documents at `kzen/plans/` (start at
`2026-07-25_master-plan.md`). This directory exists for as-built detail and history; it can be
deleted without losing anything load-bearing.

Sprint 2's thesis was **general-purpose platform first** — transport, wire format, notation
format, graph ergonomics before per-flavour features. It held: three tracks (T/W/N) plus fillers
all closed, and the flavour work that followed (Job signature → typed element model, Flow
capability SPI, the platform trio) landed on a materially better substrate.

## What landed, per plan

| Plan (archived file) | Landed | Headline as-builts / reversals |
|---|---|---|
| `2026-07-16_trace-payload-improvements.md` (TP) | TP1, TP3, TP4 ✓; **TP2 skipped** | Ktor `Compression` (2.45 MB → 646 KB, ~74 %), SSE excluded (TP1); trace binaries by content-addressed handle — new `BinaryHandleExecutionValue` under a sealed `BinaryValue`, `/logic/trace-binary` blob endpoint, single `pngUrl` choke point (TP3); server-computed `structureVersion` on `LogicStatus` for exact structural re-fetch, which restored per-emit descent animation for free (TP4). **TP2 was a stopgap superseded by TP3 — formally closed, never needed.** |
| `2026-07-16_serialization-improvements.md` (SER) | SER2–SER5 ✓ — **COMPLETE** | kotlinx foundation + classification survey (SER2); storage/file-listing family + **payoff gate: PROCEED** — the family was 3 wire DTOs, not the ~11 named (SER3); run/task DTOs + `LogicStatus.active` sentinel-kill, RestHandler shed Jackson (SER4); ContentNegotiation flipped to `json()`, last 4 raw-`Map` endpoints typed, **Jackson removed from kzen-auto + kzen-shell** (SER5). Same-day root-cause detour: **`Url` collapsed to a single commonMain value class** (+250/−602) after its `expect class` over two URL parsers produced two bugs and a 200-line reconciliation layer. *Lesson: when a shared abstraction needs a reconciliation layer between two platform backends, question the backends before building the layer.* |
| `2026-07-10_yaml-parser-strings-and-comments.md` (Y) | W1–W8 ✓ — **COMPLETE** | Bare strings, `'single'`, `\|-` block scalars and `"double"` on unparse; comments modeled on `YamlNode`. The mandatory legacy on-disk audit came back **clean** — zero no-space-colon keys across every `*.yaml` under `IdeaProjects`. Ran before G7b per the hot-seam rule. |
| `2026-07-16_graph-improvements.md` (G) | G3, G5, G6, G7 ✓; **G4 open** | Reducer decomposition + format-preserving deparse, so comments/formatting survive edits (G7); `NotationCodec` layer + FilterSpec/PivotSpec port — `isLogic` was **already** notation-driven so 5b became a doc fix (G5); `GraphDefinitionAttempt.transitiveFailures` + `GraphInstanceAttempt` + near-miss locate messages, and a dangling reference now **prunes** rather than failing to define (G6); scoped instantiation + instance caching, 3a rescoped to survey-pin + measurement (G3). **G4 (incremental define) remains measurement-gated — carried forward.** |
| `2026-07-14_attribute-editor-improvements.md` (AE) | AE1–AE6 ✓ — **COMPLETE** | `flow/edit/*Old.kt` fork deleted (AE1); `SelectClosePolicyEditor` → generic `SelectValuesEditor` driven by `values:` metadata through the `meta.ref` inheritance path (AE2); shared commit primitive `DebouncedSubmitter`/`AttributeCommitter`/`CommonEditUtils.applyCommand` across 8 adopters (AE3); `AttributePathValueEditor` merged into `DefaultAttributeEditor` (AE4); five reference selects onto `SelectReferenceEditorBase`, whose only write path is now a user selection (AE5); `AttributeWrapperLookup` as the single owner of the `editor:`/`summary:` convention, 4 call sites (AE6 — item 2 dropped on a finding). |
| `2026-07-18_reflection-improvements.md` (R) | R1–R4 ✓; **R5, R6 open** | JVM reflective fallback mirror — `GlobalMirror.register` + `ReflectiveClassMirror` in kzen-lib-jvm; **contingency C1 fired**, so the KSP processor now skips Java-origin declarations (R1); five hand-written test `ModuleReflection`s deleted (R2) — and **KSP2 does process kzen-auto-jvm's test source set**, whose second `KzenAutoJvmModule` shadowed the main one and silently dropped all 74 production registrations, so `kspTestKotlin` is now disabled; processor hardening, local-class guard dropped as unreachable (R3); `@Service` FQN boot validation (R4). |
| `2026-07-06_custom-plugin-extensibility-analysis.md` (EXT) | hygiene S1–S10 (−S7) ✓; **D1–D7 open** | All nine hygiene items landed with the cluster's first tests; Custom view models moved to kzen-auto-common for testability. **S9 surfaced a real gap (C7):** kzen-lib's document-rename reference rewriting only covers *root* objects, so renaming a Custom document dangles every cross-document reference to its nested exports — test committed `@Ignore`d. D7's verdict (declarative-first; separately-compiled JS bundles can't share class identity) was recorded 2026-07-18. **D1–D6 still need a ratification session.** |
| `2026-07-16_script-client-sweep.md` (S8) | 8a–8d ✓ — **COMPLETE** | `ScriptDependencyAnalysis` memo + timeline append + incremental representatives, with **four** analyze consumers sharing one `Component` extension (8a); `ScriptStepDisplayBase` + scope helper + `buildGroups` dedup (8b); **notation-driven branch discovery**, which removed the SwitchStep blocker and needed zero `ScriptTree`/nesting/jump changes — proven by a two-branch `TestSwitchStep` fixture (8c); hygiene, where the RPureComponent item was skipped because AE5 had already owned it (8d). |
| `2026-07-16_flow-improvements.md` (FL) | FL3, FL4 ✓; **FL5, FL6 open** | Vertex capability SPI replacing concrete-class special cases, plus channel contracts and multi-parameter RunLogic; fixtures took the **reflective-mirror** path (R1 having landed) instead of a test module (FL3). Client render performance + a rendered Error phase; refetch was **mostly already fixed by E5/TP4**, so only the per-document involvement gate was added (FL4). |
| `2026-07-16_shell-launcher-improvements.md` (SH) | SH2, SH3, SH4 ✓; **SH5 open** | Child exit detection surfaced to the UI — both exit callbacks use `thenAcceptAsync`, and the exited-restart test syncs on the tombstone because the two callbacks race by microseconds (SH2); atomic registries + `--project.home`, **rescoped to `ProjectRepo` only** since `ArchetypeRepo` was already directory-scan + atomic (SH3); kzen-project extension point + project upgrade path — **three** samples (one per source set, forced by empty-module suppression), and the JS sample **did** need build-file edits (SH4). |
| `2026-07-16_job-improvements.md` (J) | J2 ✓; **J3–J9 open** | Job signature — parameters in, results out. Client step 4 was **not** verify-only: a Job callee fell into the Script branch and rendered zero rows, needing a new `JobConventions.isJob` branch. Markers landed in `common-job.yaml`, not `job-jvm.yaml`. **Partly superseded same-day by the element model below.** |
| `2026-07-21_job-element-model.md` (JEM) | P1–P3 ✓; **P4 open** | `JobMessage(payload, flat: FlatView?)` replaced `DataRecord` as the only element crossing Job channels, and `Emitter`/`SourceWorker`/`TransformWorker`/`SinkWorker` **lost their generics entirely** (P1); typed parameter declarations replaced `ParameterSourceWorker`, with `FormulaSourceWorker` becoming THE parameterized source (P2); payload formulas + type inference flowing through the graph via `WorkerBase.payloadFlow` as a capability rather than a switch, plus a new `JobValidator`/`JobValidationCache` (P3). **P4 (benchmark-gated reuse) folds into the new Job plan's phase 5.** |
| `2026-07-18_desktop-app-distribution.md` (DA) | **nothing — 0/6** | Written 2026-07-18 with product decisions ratified (native tabs, 300–400 MB footprint acceptable, open-source engine primary). Verified greenfield: zero Electron/Tauri/JCEF/jpackage hits across all repos. Entire arc DA1–DA5 carried forward; DA6 (macOS) stays parked. |
| `2026-07-16_master-plan.md` | Sprint 2 + backlog stages B1–B6 | The Sprint-2 sequencing meta-plan. Superseded by `2026-07-25_master-plan.md`. |

## Landed without a surviving plan document

Four arcs landed 2026-07-22 → 07-25 whose planning documents were written **and deleted in-tree**
rather than converted to as-built records, or which had no plan at all. Recorded here so the work
is not invisible; recover the full design text from git where noted.

| Work | Recover with | What landed |
|---|---|---|
| **Run-cluster validation indicator** (2026-07-22) | `git show 82e63d9:plans/2026-07-22_run-cluster-validation-indicator.md` | Flavour-agnostic `LogicValidationGlobal` (two input channels so edit-pending and validation never race) + `ValidationStatusDisplay` in the ribbon; publishers for all four paradigms (Script, Job, Flow, Report) — which **fixed the gap where a structurally-broken Flow still showed Run enabled**. Confirmed decision: `busy` indicates but does **not** disable Run; only a known `invalidReason` disables. The plan's stage-3 "broader editor wiring deferred" is **closed** — a follow-up generalized the debounce into `DocumentEditActivity` + a real `DebouncedSubmitter`, now reaching ~14 editors including Report's `FormulaItemController` / `InputBrowserFilterController` / `InputSelectedGroupController`. |
| **Validation digest handshake + `DirectGraphStore` hardening** (2026-07-23) | `git show 4bf7661:plans/2026-07-23_validation-digest-handshake.md` | Fixed the UI showing a validation result for the **wrong code revision**. Three race windows, chief among them `MirroredGraphStore.apply` running local and remote applies concurrently, so a validation GET could be served from pre-commit server notation. New `ValidationDigestEcho` (kzen-auto-common) + `ServerValidationFetch` (kzen-auto-js) fetch-until-current helper; `ScriptValidationStore` collapsed onto it; `JobValidationStore`, both validators and `JobValidationCache` take the echo. kzen-lib: `DirectGraphStore` hardening + `DirectGraphStoreCacheTest` stress case. **Its §6 manual smoke was never run — carried into the Sprint-3 smoke-debt checklist.** |
| **Document digest must cover pruned members + member order** (2026-07-23) | `git show 4bf7661:plans/2026-07-23_document-digest-pruned-members.md` | kzen-lib `GraphDefinition.transitiveDigest` was cache-key blind to pruned (undefined) members and to member order. Consequence fixed: editing a Job Worker while a run was paused did not trigger `RunEngine.migrate` — the edit was silently ignored on resume/step. New `GraphDefinitionTransitiveTest` cases + a `LinkedLogicDocumentsTest` regression. |
| **`RestHandler` service split** (2026-07-22, no plan) | — | `server/api/RestHandler.kt` **deleted (1303 lines)**; `KzenAutoMain` −197. Replaced by `server/api/handler/` (`DetachedActionHandler`, `LogicHandler`, `NotationQueryHandler`, `TaskHandler`, `StorageHandler`, `FileListingHandler`, `ObjectStableHandler`, `RestParams`) and `server/api/handler/command/` (`NotationAttributeCommands`, `NotationObjectCommands`, `NotationRefactorCommands`, `NotationDocumentCommands`, `NotationResourceCommands`, `NotationCommandHandler`). **This invalidated line anchors in four unexecuted plans — repaired during the Sprint-3 consolidation.** |
| **Go-to-error + expression validation UI** (2026-07-23 → 07-24, no plan) | — | `StageErrorIndicator` (error surfacing moved out of `ProjectController` into `StageController`), `StageObjectLocator` (click-through from an error to the offending object slot), `ExpressionValidationIndicator` (adopted by `FormulaMapEditor` + `KotlinExpressionEditor`), `StepPickingSelectEditorBase`, and `KotlinSyntaxValidator` — a syntax-only parse for lanes whose headers are statically unknown, wired into `FormulaWorker`/`FilterWorker`/`WorkerLane`/`JobValidator`. |
| **Deprecated step removal** (2026-07-25, no plan) | — | Deleted `DivisibleCheckStep`, `LogicalAndStep`, `BooleanLiteralStep`, `NumberLiteralStep`, `NumberRangeStep`, `TextLiteralStep`; ten test fixtures rewritten onto `FormulaStep`; ribbon tools and archetypes removed; kzen-project follow-on `869a15f`. |

## Session ledger — what actually ran

One line per executed session, in order. This is the per-session record the Sprint-3 master plan
points at.

| # | Session | Landed |
|---|---|---|
| 1 | TP1 — HTTP response compression | 2026-07-16 |
| 2 | TP3 — trace binaries by content-addressed handle | 2026-07-16 |
| 3 | TP4 — structural version on `LogicStatus` | 2026-07-16 |
| 4 | SER2 — kotlinx foundation + classification survey | 2026-07-16 |
| 5 | SER3 — storage/file-listing family + payoff gate (**PROCEED**) | 2026-07-17 |
| 6 | `Url` collapse to a single value class (SER3 fallout) | 2026-07-17 |
| 7 | SER4 — run/task/trace DTOs + `LogicStatus.active` sentinel-kill | 2026-07-17 |
| 8 | SER5 — ContentNegotiation flip + Jackson removal | 2026-07-18 |
| 9 | Y (W1–W8) — yaml strings, comments, block scalars + legacy audit | 2026-07-18 |
| 10 | G7 — reducer split + format-preserving deparse | 2026-07-19 |
| 11 | G5 — `NotationCodec` + notation-driven `isLogic` | 2026-07-19 |
| 12 | G6 — structured definition/creation failure surface | 2026-07-19 |
| 13 | G3 — scoped instantiation + instance caching | 2026-07-19 |
| 14 | AE1 — retire the `flow/edit/*Old.kt` fork | 2026-07-19 |
| 15 | AE2 — `SelectClosePolicyEditor` → `SelectValuesEditor` | 2026-07-20 |
| 16 | AE3 — shared commit primitive (8 adopters) | 2026-07-20 |
| 17 | AE4 — merge `AttributePathValueEditor` into `DefaultAttributeEditor` | 2026-07-20 |
| 18 | AE5 — `SelectReferenceEditorBase` behind five reference selects | 2026-07-20 |
| 19 | AE6 — `AttributeWrapperLookup` metadata-key owner | 2026-07-20 |
| 20 | R1 — JVM reflective fallback mirror | 2026-07-20 |
| 21 | R2 — test-fixture / src-main pollution cleanup | 2026-07-20 |
| 22 | R3 — KSP processor hardening | 2026-07-20 |
| 23 | R4 — `@Service` FQN boot validation | 2026-07-20 |
| 24 | EXT-H — extensibility hygiene S1–S10 (−S7) | 2026-07-20 |
| 25 | S8a — Script client hot paths | 2026-07-21 |
| 26 | S8b — display/editor dedup | 2026-07-21 |
| 27 | S8c — notation-driven branch discovery | 2026-07-21 |
| 28 | S8d — Script client hygiene | 2026-07-21 |
| 29 | FL3 — vertex capability SPI | 2026-07-21 |
| 30 | FL4 — Flow client perf + Error phase | 2026-07-21 |
| 31 | SH2 — child exit detection + UI surfacing | 2026-07-21 |
| 32 | SH3 — atomic registries + `--project.home` | 2026-07-21 |
| 33 | SH4 — kzen-project extension point + upgrade path | 2026-07-21 |
| 34 | J2 — Job signature: parameters in, results out | 2026-07-21 |
| 35 | JEM P1 — `JobMessage` carrier replaces `DataRecord` | 2026-07-22 |
| 36 | JEM P2 — typed parameters; `ParameterSourceWorker` retired | 2026-07-22 |
| 37 | JEM P3 — typed result + typed flow (`JobValidator`, `TypeAssignability`) | 2026-07-22 |
| 38 | Job result value displayed in the UI (`ResultWorkerDisplay`) | 2026-07-22 |
| 39 | `RestHandler` split into handler services | 2026-07-22 |
| 40 | Run-cluster validation indicator (`LogicValidationGlobal`) | 2026-07-22 |
| 41 | `DocumentEditActivity` + real `DebouncedSubmitter` (edit immediacy) | 2026-07-23 |
| 42 | Document digest covers pruned members + member order (kzen-lib) | 2026-07-23 |
| 43 | Validation digest handshake + `DirectGraphStore` hardening | 2026-07-23 |
| 44 | `StageErrorIndicator` + select-step editor consolidation | 2026-07-23 |
| 45 | Go-to-error (`StageObjectLocator`) | 2026-07-23 |
| 46 | `KotlinSyntaxValidator` — FormulaWorker code validation | 2026-07-24 |
| 47 | `ExpressionValidationIndicator` | 2026-07-24 |
| 48 | Deprecated step removal (6 step types) | 2026-07-25 |

## Cross-cutting discoveries worth remembering (all recorded in live docs)

- **Question the backends before building the reconciliation layer** (SER3): `Url` was an
  `expect class` wrapping two different URL parsers; the divergence it produced was self-inflicted,
  and collapsing to one commonMain value class deleted the two "fixes" *and* the machinery they fixed.
- **A dangling reference should prune, not fail** (G6): the old "Missing: main" error was the
  symptom of treating every unresolved reference as a definition failure.
- **KSP2 processes test source sets** (R2): a second `ModuleReflection` in `src/test` shadowed the
  main one and silently dropped all 74 production registrations. `kspTestKotlin` is disabled in
  `kzen-auto-jvm` for this reason — grep the test log for `Serving … by JVM reflection`; only
  fixtures may appear.
- **Merging the carrier beats wrapping it** (JEM): the message-envelope objection ("an allocation
  per element") only held for wrapping `DataRecord` *inside* an envelope. Making the message *be*
  the carrier, with a payload slot and the flat part as fields, is allocation-neutral.
- **Capability, not switch** (JEM P3 / FL3): both the payload-type walk and the Flow vertex SPI
  landed as an overridable default on the base class rather than a type dispatch — the default is
  already correct for most implementors.
- **Concurrent local/remote apply races validation** (validation handshake): `MirroredGraphStore`
  publishes local success before the remote write completes, so any fetch triggered by that publish
  can observe pre-commit server state. The fix is a digest echo and fetch-until-current, not a delay.
- **Deleting a plan loses its deferrals** — three plans were deleted rather than archived on
  2026-07-23, taking their deferred scope and pending manual smoke with them. Recovering them for
  this README is why the § above exists. Convert plans to as-built records; delete only the
  elaborations under `plans/next/`.

## Where the live work is now

All open work lives flat in `kzen/plans/`:
`2026-07-25_master-plan.md` (**start here** — one line per session) · `2026-07-25_job-improvements.md`
· `2026-07-25_flow-improvements.md` · `2026-07-25_extensibility-improvements.md` ·
`2026-07-25_desktop-and-hosting.md` · `2026-07-25_core-and-verification.md`, with execution-ready
elaborations for the independent items under `plans/next/`.
