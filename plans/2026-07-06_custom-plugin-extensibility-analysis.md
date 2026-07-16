# Third-party extensibility (Custom / Plugin / ObjectRegistry / DataFormat) — design analysis

> **Status: analysis (pre-plan).** Written 2026-07-06 from a design review of the four
> "Customize"-group document types — `CustomDocument` (ad-hoc notation objects with prototypes,
> tags, and exports), `PluginDocument` (JAR-based report-definer loading), `ObjectRegistryDocument`
> (JVM class-name whitelist), `DataFormatDocument` (field/type schema editor) — across the
> `kzen-auto-plugin` SPI module, the server plumbing
> (`PluginReportDefinitionRepository` / `MultiDefinitionRepository` / `HostReportDefinitionRepository`),
> the common conventions/specs, and the JS clients.
>
> This is **deliberately not a phased plan yet**: the findings split into (a) settled, plan-ready
> hygiene/bug work and (b) one strategic architecture move plus five dispositions that need
> ratification first (§ Open decisions). Once D1–D6 are decided, promote this to
> `2026-07-XX_extensibility-improvements.md` using the standard plan format (executor: Opus 4.8
> xhigh, one phase per session; decisions pre-made) — a candidate phase structure is sketched at
> the end.
>
> Companion plans (do not duplicate their work):
> - `2026-07-14_attribute-editor-improvements.md` **phase 1** owns the `PluginController` port
>   (to `TextAttributeEditor`, incl. the `long`-type fix) and the
>   `objects/document/flow/edit/*Old.kt` deletion — **S7 below is superseded** (2026-07-14;
>   previously coordinated with the Flow plan's phase 5, whose bullet is likewise superseded).
> - `2026-07-16_shell-launcher-improvements.md` owns the localhost trust / CSRF hardening
>   stance (SH1, the hardening itself, landed 2026-07-10 — see its "Landed context");
>   plugin-JAR arbitrary-code-execution is accepted under that same single-tenant-localhost
>   posture and only needs documenting here, not solving.
> - The expression-engine / `FormulaStep` inference internals landed with Script plan S1
>   (Sprint 1, 2026-07-11 — loaded-class caching + real reflective type inference; see
>   `sprint-1/2026-07-06_script-improvements.md`); this analysis only touches the
>   `ObjectRegistryScan` input to it, which S4 made a component of the validation-cache key.
> - Any change to `kzen-auto-plugin` requires `./gradlew :kzen-auto-plugin:publishToMavenLocal`
>   before non-composite consumers (`../kzen-sample-plugin`, standalone `../kzen-project`) see it.

## The cluster at a glance

| Document type | Server | Client | Live consumers | Verdict |
|---|---|---|---|---|
| **CustomDocument** | `CustomDocument.kt` — *empty* `DocumentArchetype` (8 lines) | Full modern stack (`CustomStore`/`CustomViewModel`/View+Raw) | Exports feed `SelectLogicEditor` + `SelectObjectEditor`; objects run via detached/task paradigms by tag | **B+** — the strong pillar; unfinished edges |
| **PluginDocument** | `PluginDocument` (DetachedAction) + `PluginReportDefinitionRepository` | `PluginController` (legacy-editor dependent) | Report input pipeline (`ReportRun`, `FileListingAction`, `ReportDocument`) | **C+** — works, single-purpose, several one-line bugs |
| **ObjectRegistryDocument** | `ObjectRegistryDocument` (DetachedAction + static `scan`) | `ObjectRegistryController`/Add/Edit | **Only** `FormulaStep` type inference (via `ScriptValidator.kt:48` → `ScriptDefinitionContext`) | **C** — real but narrow, misnamed, doesn't compose with Plugin |
| **DataFormatDocument** | `DataFormatDocument` (holds `FieldFormatListSpec`, nothing else) | `DataFormatController`/FieldAdd/FieldEdit | **None** — spec flows definer → document → editor and nowhere else | **D** — dead code with a UI |

As a whole: **four documents aimed at one goal ("enable third-party extendability") that don't
compose into one story.** Cluster grade C+. The user-facing grouping already exists (all four
declare `group: "Customize"` in `common-document.yaml`); the architectural grouping doesn't.

## The strategic finding — the extension ceiling is `ReflectionRegistry`, not notation

The codebase's design philosophy (the god-object rule, archetype-driven displays, autowired
registries — see AGENTS.md) promises "a third party extends kzen with zero shared-code edits."
That promise is **only redeemable by compiling against the host**, because notation can only
instantiate classes the `ReflectionRegistry` knows, and registration happens at host compile time
via KSP (`kzen-lib-reflect-ksp` → `KzenAuto{Common,Jvm,Js}Module`). The plugin JAR system bypasses
this entirely: it is a parallel, single-purpose channel — `ReportDefiner` only, discovered via a
hand-rolled service locator (`META-INF/kzen/plugins.yaml`, `PluginDocument.kt:78-107`). A plugin
JAR cannot ship a Script step, a Flow vertex, a Job worker, a WorkerDisplay-style card, or a
Custom prototype class.

**The unifying move (D1):** `kzen-lib-reflect-ksp` already generates a `ModuleReflection` for any
module — including an out-of-tree plugin module. If the plugin JAR ships its own KSP-generated
module class (named in `plugins.yaml` alongside or instead of the definers), the server registers
it into `ReflectionRegistry` at plugin load. Consequences:

- Every `@Reflect` class in the JAR becomes notation-instantiable. Archetype YAML ships in the
  same JAR as bundled notation (the classpath-overlay `ReadWriteNotationMedia` mechanism already
  merges bundled documents). Custom documents can then declare prototypes backed by plugin
  classes; Scripts get third-party steps; Jobs get third-party workers — the extension model the
  Worker/Step/Vertex SPI work has been building toward, finally reachable without forking.
- `ReportDefiner` stops being special — one interface among many (kept for compat).
- ObjectRegistry's class whitelist can auto-derive from registered plugin modules (D4).
- The acceptance criterion writes itself: **`../kzen-sample-plugin` contributes a working
  `@Reflect` Script step (or Custom prototype) usable from notation, with zero kzen-source
  edits.**

Design tensions to settle *in the decision*, not discover during execution:

1. **Classloader lifecycle.** Registry registration pins the loader for the JVM's life. Today's
   per-run open/close model already strains: `PluginDocument.definerDetails()` ends with
   `System.gc()` "to nudge the classLoader" (`PluginDocument.kt:146`) — the classic Windows
   jar-file-lock symptom. Recommendation: commit to **load-once-per-boot, restart to upgrade** as
   the stated semantics (kzen-shell/launcher fronts process restarts anyway). Dynamic
   unload/reload of registered classes is a rabbit hole (stale instances pinned in graphs,
   half-evicted registries) with almost no payoff for a single-tenant local tool.
2. **JS side.** Server-registered classes have no client `ModuleReflection`. Generic editing
   already works (`AttributeEditorManager` + `DefaultAttributeEditor`), and display selection is
   notation-driven (`display:` markers), so a plugin object is *editable and runnable* with
   default chrome out of the box. Plugin-authored **custom client UI** requires a JS code-loading
   strategy (separate Kotlin/JS bundles, web components, or iframes) — that is a **decision gate
   (D7)**, explicitly out of scope for the first iteration.
3. **Security.** Loading a JAR is arbitrary code execution by design; no regression vs today.
   One documentation sentence under the shell/launcher plan's single-tenant-localhost stance.

## Per-type findings

### CustomDocument — strong core, unfinished edges

**What's right (preserve all of it):**

- **Zero server code.** `server/objects/custom/CustomDocument.kt` is an empty
  `DocumentArchetype`. Objects run through the existing paradigms purely by location: `detached`
  and `task` `ObjectTag`s (from `meta: tags:`) get run affordances; `logic`-tagged exports are
  offered to Script's `SelectLogicEditor` (`CustomConventions.customDocumentExportedLogic`,
  consumed at `SelectLogicEditor.kt:129`); `exports` feed `SelectObjectEditor` for cross-document
  object references (`SelectObjectEditor.kt:142`). This is the kzen model working as intended —
  every future change should keep the server side at zero.
- **The most modern client stack in the codebase:** `CustomViewModel.Builder` reuses per-object
  entries when data-class-equal so sibling `CustomObject` props stay reference-stable under
  `RPureComponent` shallow-compare (`CustomViewModel.kt:12-15`); hover affordances via CSS not
  state (`CustomObject.kt:93-95`, `CustomObjectHeader.kt:96-98`); header/body share one store via
  `DocumentBridge` (`CustomStoreKey`); View/Raw dual mode with the `editorModified` guard
  disabling View while raw edits are unsaved (`CustomHeader.kt:84-89`); the shared raw stack
  (`objects/document/common/raw/`) reused rather than re-implemented.
- Prototype-driven creation (`is: Prototype` markers → `CustomConventions.listPrototypes` → the
  `+ Add` picker), name allocation via `NextAvailableName`, drag-reorder via `ShiftObjectCommand`
  with view-index → doc-index translation.

**Defects and gaps:**

- **C1 — debug artifact in production render.** `+"[foo bbb]"` renders in every object card
  (`CustomObject.kt:181`).
- **C2 — the out-of-box experience is a dev scratchpad.** The bundled starter document
  (`kzen-auto-jvm/src/main/resources/notation/main/Custom.yaml`) ships `foooxxxxxx`, `xxxxs`,
  duplicate `AdhocDetached`/`AdhocDetached1`/`AdhocTask`/`AdhocTask1`; and the only prototypes
  offered anywhere in a fresh install are the `server.objects.custom.test.Adhoc*` fixtures — the
  flagship "Custom" sample *is* the test fixture. Needs a small curated prototype library plus a
  clean sample document. (This file is the in-repo bundled overlay, not a user's working
  document — editable as part of a ratified cleanup; the runtime `notation/main/` remains
  untouchable per AGENTS.md file safety.)
- **C3 — full-graph scan inside render.** `CustomView.render` calls
  `CustomConventions.listPrototypes(graphNotation)` — a `directAttribute` probe over **every
  object in the graph** — on every render, and reaches into `clientStateGlobal.current()`
  mid-render to do it (`CustomView.kt:61-67`). Belongs in `CustomViewModel.Builder` (which
  already receives `graphStructure`), recomputed per notation event.
- **C4 — the prototype model is thin.** Discovery is direct `is: Prototype` only; the picker
  shows bare object names (no title/description/icon/grouping metadata — compare the sidebar's
  archetype registry, which has all four); `createObject` links the new object to the prototype
  by **bare object name** (`AddObjectCommand.ofParent(..., prototype.objectPath.name)`,
  `CustomViewStore.kt:62`), so two same-named prototypes in different documents resolve silently
  by coalesce order.
- **C5 — run results are transient; polling leaks.** `CustomObjectDetachedRunner` /
  `CustomObjectTaskRunner` live in component instances (`CustomObject.kt:49-72`): navigate away
  and back, results are gone; the task `pollLoop` keeps polling at 1s after unmount until the
  task settles (`CustomObjectTask.kt:86-97`). Also `logic`-tagged objects get a chip and **no
  affordance at all** (invocable only from a Script) — fix or document the asymmetry.
- **C6 — tag→affordance mapping is a hardcoded branch** (`CustomObject.kt:134-148`:
  `isDetached → DetachedRunner`, `isTask → TaskRunner`, `isLogic → chip`). Custom-local code, so
  not a god-object violation today — but it is exactly the seam where "proper extension point
  with custom UI" will land. The shape is an autowired per-tag (or per-archetype) card registry —
  the `WorkerDisplay` pattern.
- **C7 — `exports` rename-refactor safety is unpinned.** Entries are stored as
  `objectPath.asString()` scalars (`CustomViewStore.kt:204`) under
  `exports: {is: List, of: ObjectLocation, by: Nominal}` meta (`common-document.yaml:391-396`).
  Nominal rename rewriting should handle it; nothing tests that a rename of an exported object
  (or of the document) keeps the exports list and downstream `SelectLogicEditor` references
  intact.
- **C8 — stale docs.** `docs/architecture.md` § 6 still describes a `main.logic` list; reality is
  `exports` + tags. `docs/js-architecture.md` § 3 still says "custom/ is the exception — no
  sub-stores, no model/ directory"; it now has the full store stack.

### PluginDocument — working, single-purpose, several one-line bugs

- **P1 — reports-only SPI.** The strategic gap (D1 above).
- **P2 — "upload" is a server filesystem path in a text field.** `jarPath` is a notation string
  pointing at the server's disk. kzen-lib's resource machinery (`/command/resource/add`, used by
  Feature documents for PNGs) could make the JAR a **document-owned resource**: real browser
  upload, no absolute-path coupling, artifact travels with the workspace. (docs § 7's "user
  uploads the JAR via the plugin document UI" describes this intent, not the current code.)
- **P3 — dead cache fast-path.** `PluginReportDefinitionRepository.cachedStructureDigest` is
  declared and compared but **never assigned** (`PluginReportDefinitionRepository.kt:41,50`), so
  the early-return can never fire; every `contains`/`metadata`/`listMetadata` call does
  `runBlocking { graphStore.graphStructure() }` + whole-structure digest + all-documents filter.
  Correctness survives via the per-plugin notation-digest checks (`:65-75`); the intended
  top-level cache is just dead. One-line fix plus a test. (Also reconsider `@Synchronized` +
  `runBlocking` on request threads while at it.)
- **P4 — two parallel jar-loading paths, inconsistent failure surfacing.** The UI listing
  (`PluginDocument.execute` → fresh `URLClassLoader` → instantiate → `define()` per definer →
  `System.gc()`) duplicates what the repository already loads and caches. Serving the listing
  from `PluginReportDefinitionRepository` metadata would delete the second loader, the gc nudge
  (`PluginDocument.kt:146`), and the inconsistency: the repository **silently skips** a definer
  whose `define()` throws (`catch … continue`, `PluginReportDefinitionRepository.kt:108-113`)
  while the listing path fails wholesale — either way the plugin author gets no per-definer
  diagnostic. Surface load errors per definer in the listing.
- **P5 — isolation is coarse.** All coordinates in one repository share a single `URLClassLoader`
  ("plugin", `PluginReportDefinitionRepository.kt:196-199`); `MultiDefinitionRepository
  .classLoaderHandle` chains repositories parent→child (`MultiDefinitionRepository.kt:40-62`), so
  a plugin's effective classpath can include unrelated plugins' jars, order-dependent. For
  multi-jar support (D2) decide the isolation unit — per-`PluginDocument` loader is the
  defensible default, merging only when one run genuinely spans coordinates from multiple jars.
- **P6 — small stuff.** `"Name found: $coordinate"` should be "Not found"
  (`PluginReportDefinitionRepository.kt:214`). `PluginController.kt:219` passes
  `valueType = TypeMetadata.long` for the **jar path** — renders as a text field only by accident
  of the editor's shared string/int/long/double branch. `PluginController` stores the whole
  `ClientState` (the anti-pattern js-architecture § 2 warns about). `plugins.yaml` vs
  `java.util.ServiceLoader`: either is fine — keep the explicit yaml, but write the format down
  in `kzen-auto-plugin` docs once D1 extends it to module classes.
- **P7 — last consumer of the legacy editor.** `PluginController.kt:13,212` is the only live use
  of `objects/document/flow/edit/AttributePathValueEditorOld`. *Ownership moved 2026-07-14:*
  `2026-07-14_attribute-editor-improvements.md` phase 1 does the port (to `TextAttributeEditor`,
  fixing the `long` type) and deletes the directory.

### ObjectRegistry — real but misnamed, and it doesn't compose

Its sole live role: a class-name whitelist consumed by **`FormulaStep` type inference**
(`ScriptValidator.kt:48` builds `ObjectRegistryScan` into `ScriptDefinitionContext`;
`FormulaStep.kt:102-116` matches inferred simple names against it) so Script expressions can be
typed beyond the built-ins.

- **R1 — name/docs mismatch.** docs § 6 calls it "browse / add custom objects from the library";
  the title is "Object Registry"; the function is a type-inference whitelist. Nobody could guess.
- **R2 — doesn't compose with Plugin.** `ObjectRegistryDocument.reflect` uses host-classpath
  `Class.forName` (`ObjectRegistryDocument.kt:45`; `IterableElementTypeReflect` likewise via
  `dynamicParentClassLoader`) — plugin-JAR types cannot be registered or recognized. The two
  extension mechanisms are blind to each other.
- **R3 — uncached, per-validation reflection.** `scan()` re-filters all documents and re-reflects
  every registered class on **every Script validation**; a stale entry means repeated
  `ClassNotFoundException` construction. Cache by notation digest.
- **R4 — already partially redundant.** The one bundled registration
  (`registry-jvm.yaml` → `kotlin.ranges.IntRange`) is also hardcoded in
  `FormulaStep.simpleClassNames` (`FormulaStep.kt:96-98`, with a comment) — double coverage.

It is **not** superseded by CustomDocument — different axis (JVM type names vs notation objects).
But it should not remain a standalone document type for a one-consumer whitelist (D4).

### DataFormat — dead code with a UI

- **F1 — zero consumers.** `FieldFormatListSpec` flows definer → document object → editor and
  nowhere else (grep-verified: 7 matching files, all inside its own loop). The document edits
  field-name → `TypeMetadata` pairs that no run reads.
- **F2 — verbose notation shape.** Nested `class` / `of` / `nullable` maps per type level
  (`FieldFormatSpec.kt:28-64`) where a compact type-expression string would do.
- **F3 — minor:** `DataFormatController` extends `RComponent` rather than `RPureComponent`.

Disposition is D5. The trap to avoid: redesigning a schema document **before** a consumer exists
is how it got here.

## Cross-cutting

- **Zero tests across all four types** — server, common, and client logic alike. Highest-value
  candidates: `PluginReportDefinitionRepository` cache behaviour (P3 regression pin),
  `CustomViewModel.Builder` reference-stability, `CustomViewStore.onDrop`'s view-index →
  doc-index translation (`CustomViewStore.kt:119-146` — classic silent-regression material),
  `ClassListSpec` / `FieldFormatSpec` notation round-trips, C7's rename pin.
- **Stale docs**: architecture.md § 6 (Custom `main.logic`; registry description), § 7 (upload
  claim); js-architecture § 3 (custom/ structure). Refresh alongside whichever work lands first.
- **Performance is a non-issue at this scale** except the three cheap fixes already named: P3
  (dead fast-path), C3 (per-render prototype scan), R3 (per-validation reflection).

## Settled findings — plan-ready now (no ratification needed)

These are correctness/hygiene items; any future plan's phase 1, or an opportunistic cleanup
session, can execute them directly:

- **S1** Remove the `+"[foo bbb]"` artifact (C1).
- **S2** Assign `cachedStructureDigest` after refresh + regression test (P3).
- **S3** Fix `"Name found"` typo (P6).
- **S4** Move prototype listing out of render into `CustomViewModel.Builder` (C3).
- **S5** Cache `ObjectRegistryDocument.scan` by notation digest (R3).
- **S6** Stop the orphan task poll after unmount; guard `pollLoop` on runner observers or an
  explicit cancel (C5, the leak half only — persistence is D6).
- ~~**S7** Port `PluginController` off `AttributePathValueEditorOld`~~ — **superseded
  2026-07-14** by `2026-07-14_attribute-editor-improvements.md` phase 1 (P6/P7; the S-item count
  in headers stays for stable numbering). The other P6 bits (the "Name found" message,
  whole-`ClientState` storage) remain here.
- **S8** Docs refresh (C8, R1's doc half, P2's doc half).
- **S9** First tests for the cluster (list above).
- **S10** Replace the bundled `Custom.yaml` scratch content with a clean sample (C2 — content of
  the curated prototype library can start minimal: the two Adhoc runners renamed/tidied, real
  descriptions).

## Open decisions — ratify before promoting to a plan

- **D1 — Plugin module registration (the strategic move).** Adopt plugin-shipped KSP
  `ModuleReflection` + bundled archetype notation, registered at plugin load?
  **Recommend: yes**, with **load-once-per-boot / restart-to-upgrade** lifecycle semantics
  stated up front. Acceptance: sample plugin contributes an `@Reflect` step/prototype with zero
  kzen-source edits. This decision reshapes D2–D4.
- **D2 — Isolation unit for multi-jar support.** Per-`PluginDocument` `URLClassLoader`
  (recommended) vs today's per-repository merge + cross-repo chaining. If D1 lands with
  boot-time loading, the loader set is fixed at boot and this simplifies further.
- **D3 — JAR as document resource (upload UX).** Reuse `/command/resource/add` so the JAR lives
  in the document (recommended) vs keep server-path with better validation. Interacts with D1
  lifecycle (a resource edit implies restart-to-apply messaging in the UI).
- **D4 — ObjectRegistry disposition.** Options: (a) auto-derive the type-inference whitelist
  from D1-registered plugin modules + host introspection and **retire** the document type;
  (b) keep it as a manual "extra host-classpath types" escape hatch with an honest
  rename/description; (c) status quo + docs fix only. Recommend (a) if D1 lands, else (b).
  Either way delete the redundant bundled `IntRange` registration (R4).
- **D5 — DataFormat disposition.** Options: (a) **consumer-first rework** — pick the first real
  consumer (Report input `dataType`, currently a raw `ClassName`; or Job channel `elementType`;
  or Script tuple/record types) and spec DataFormat as the dynamic record schema those
  reference; (b) formally park/retire until that consumer is concrete. Recommend (b) now, with
  the consumer choice recorded as the reopening trigger — don't redesign in a vacuum.
- **D6 — Custom run-result persistence.** Keep transient component-held results (documented), or
  move detached/task results into a store keyed by stable id (survives navigation), or full
  trace-store integration like Script/Flow. Recommend the middle option — cheap, matches user
  expectation, no server change.
- **D7 — plugin custom client UI (decision gate; park).** Generic editors + notation-driven
  display markers are the honest ceiling short-term. Choosing a JS-loading strategy (separate
  Kotlin/JS bundles / web components / iframes) is a large, separable investment — decide only
  when a concrete plugin needs more than the default chrome. C6's per-tag card registry is the
  in-tree seam that keeps this future open.

## Candidate phase structure (not ratified — sketch for the eventual plan)

1. **Hygiene + truth** — S1–S10.
2. **Plugin module registration** (D1) — SPI extension in `kzen-auto-plugin` (module-class list
   in `plugins.yaml`), boot-time load + register, bundled-notation merge from plugin JARs,
   sample-plugin acceptance test. Requires `:kzen-auto-plugin:publishToMavenLocal` discipline.
3. **Plugin UX** — D2 isolation, D3 upload, listing served from repository cache (P4), per-definer
   diagnostics.
4. **Custom power** — prototype metadata for the picker (C4), per-tag affordance registry seam
   (C6), run-result persistence per D6, exports rename pin (C7).
5. **Registry disposition** — execute D4; migrate `FormulaStep` whitelist sourcing.
6. **DataFormat decision gate** — execute D5; record D7's reopening trigger.

## Verification baseline

No dedicated tests exist for this cluster (see Cross-cutting), so until S9 lands the baseline is:
`./gradlew build` (all modules; KSP regen included), plus `:kzen-auto-jvm:test` for the Script
tests that transit `ObjectRegistryScan` (`FormulaStepTest` — also the Kotlin-diagnostic canary,
see AGENTS.md), plus a manual `frontendDevelopment` smoke of each of the four documents
(create-from-sidebar, edit, and for Custom: add-from-prototype / toggle export / run detached +
task / Raw round-trip). `selfTest` does not drive any of these document types directly — broad
regression net only (mind the stale-tester-on-18081 footgun). Plugin-path changes need a manual
check with `../kzen-sample-plugin` built and registered via a Plugin document.
