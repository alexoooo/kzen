# DS4 — sources editing surface (Job sources section, `FileSelectionEditor`, source picker, card chrome) — implementation plan

> **Status: ready to execute.** Session 4 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§6.4** (UI binds on the source object's attributes; the two editor mechanics), **§6.4a** (where a
> source lives — graph-wide discovery; the `DataSources` document deferred), §5.2a (the trivial-case
> walk-through and the in-card source summary), §4 (the generic `DataSourceActions`), O10, O21; and
> [`../../analysis/2026-08-21_extension-points.md`](../../analysis/2026-08-21_extension-points.md) §2.1 (generic
> editors + detached protocol — this session is its first customer). Constituent plan: **—** (analysis
> doc is the record; delete on landing, as-built → analysis **§14**). Depends on **DS2**; DS3 in
> parallel is fine (the smoke needs both). Anchors verified 2026-08-21. **Revised 2026-08-21b** by the
> second-pass review (§13 C5, C6, D3) and **2026-08-23** by the third (§15 C15, D8, D10, D11). Sized
> **L** with a split point (steps 1–3 / steps 4–6). kzen-auto-js + notation yaml; minimal server code.
> Ledger row 54. **The step that makes the whole thing usable rather than expert-only.**
>
> **What changed 2026-08-23:** **no `DataSourceId` minting** (deferred past the arc, O15 — the insert
> command no longer upserts an `id`, and there is no duplicate-id report); Resolve goes through the
> generic **`DataSourceActions`** object with `source=<location>`, not a `DetachedAction` on the source
> (D10), and renders **`DataResolveResult.diagnostics`** rather than a bare skipped count; the
> **`DataSources` document is not built** (O21) — the picker is still graph-wide, so a source in another
> Job's `sources:` branch appears; the smoke adds **delete-the-bound-source** (C15, the O14 spike's
> third verdict).

## Scope & goal

1. **Job `sources:` section** in `JobController` — a list of source cards above the worker lane
   (beside the Parameters / Result controls), ribbon-insertable (new `JobGroup_Data` ribbon group with
   `FileDataSourceTool`), deletable, renameable; insert nests under `main.sources/` — chosen **by
   capability** (`DataSourceConventions.isDataSource`), not by archetype name.
2. **Source card** (`DataSourceCard`): title + rename, an `AttributeEditorManager` editor per
   non-managed attribute (exactly how `WorkerDisplayDefault.renderAttributeEditors` does it), and
   **generic chrome**: a "Resolve" control that calls `DataSourceActions` (`source=<this card's
   location>`, `action=resolve`) and renders the returned `DataResolveResult` — the manifest as a small
   table (units × attributes × parts) plus each diagnostic as a line. No file-specific code in the card,
   and **nothing implemented on the source** for it.
3. **`FileSelectionEditor`** — `MultiFileInputEditor` rewritten as `FileDataSource`'s attribute editor
   for `files` (directory / filter browse via the existing `/file-listing` route, pick/unpick/reorder,
   per-file format + encoding), writing the DS2 `FileSelectionSpec` notation; bound by `editor:` on
   the `FileDataSource` archetype. The `directory` / `filter` attributes are plain text editors that the
   browser *reads* as its starting point (one source of truth — the browser does not keep its own).
   ⚠ The `filter` field must be labelled for what it **is** (C6, below).
4. **`SelectDataSourceEditor`** — `ReadWorker.source` picker: lists sources **graph-wide** by capability
   (`DataSourceConventions.allDataSources`), so a Job's own `sources/` objects and another Job's appear
   (grouped by document; the `DataSources` document, when it lands later, will appear through the same
   query — O21); **auto-bind** when the Job has exactly one source and the attribute is blank.
5. **Smoke** of the trivial case end to end in a browser — the session's real deliverable. *(The
   2026-08-21b item 5, minting `DataSourceId` on insert, is **gone** — O15 is deferred past the arc.)*

## Dependencies & coordination

- **DS2 landed**: the `FileDataSource` archetype (with `missing`, **no `id`**, and **no `editor:`
  keys**), `FileSelectionSpec` (commonMain `common/data/file/`), `sources` meta on `Job`,
  `DataSourceConventions`, the generic `DataSourceActions` detached object, and **the O14 spike's delete
  verdict** (C15) — it decides what the Read card shows when its bound source is deleted.
  **DS3** gives the `ReadWorker` archetype; if DS3 has not landed, build the editors anyway (they are
  keyed by the `editor:` name) and smoke with DS3 later.
- ⚠ **`editor:` keys and their registrations land together** (C5). `AttributeEditorManager` resolves
  `AttributeWrapperLookup.wrapperName(…) ?: DefaultAttributeEditor.wrapperName` — the fallback fires when
  an attribute has **no `editor:` metadata**. A declared-but-unregistered name is a `find` miss and
  `render` emits the literal text `[Attribute editor not found: <name>]` with **no input**. So every
  `editor:` key this session adds to `data-source-jvm.yaml` / `job-worker.yaml` must be in the same
  change as its `@Reflect` wrapper registration in `job-js.yaml`.
- **AE layer (landed 2026-07-20)**: `AttributeEditorManager` / `AttributeWrapperLookup` /
  `DefaultAttributeEditor` / `SelectReferenceEditorBase` / `DebouncedSubmitter` / `AttributeCommitter` —
  build on them; the commit path reports edit-pending through `DocumentEditActivity`, keep it intact.
- **J8 (client sweep)** later dedupes editors — make `FileSelectionEditor` the smallest rewrite of
  `MultiFileInputEditor` (same Wrapper shape, same REST client injection), not a new design.
- **js-architecture.md** § 2 observer rules and § 7 commit patterns apply; the `KotlinCodeArea` is not
  involved.
- **File safety**: the user's `main/` documents are never edited; smoke on a temp project.

## Current-state findings (anchors verified 2026-08-21)

- **`AttributeEditorManager`** (`…client/objects/document/common/attribute/`): `onClientState` resolves
  the wrapper name once (`?: DefaultAttributeEditor.wrapperName`), then
  `props.attributeEditors.find { it.name() == editorWrapperName }`; `render` emits
  `+"[Attribute editor not found: ${state.attributeEditorName}]"` and returns when that find is null.
  **A name miss is not a fallback** — this is C5, and it is also worth a small defensive fix (below).
- **`JobController`** (`…client/objects/document/job/JobController.kt`): mounts `LogicSignatureEditor`
  (parameters) and `ResultSignatureEditor` top-right; renders worker cards via `JobObjectSlot` in
  document order from `directNestedObjectPaths(main, workers)`; ribbon insert-mode inserts the
  ribbon-selected archetype "under `workers`" at a clicked gap (the `JobConventions.workersAttributePath`
  call site) — **this is the branch point**: a DataSource archetype nests under `sources` and is
  appended (no gap choice needed — order among sources is not semantic).
- **Worker card attribute editing**: `WorkerDisplayDefault.renderAttributeEditors(objectMetadata)` —
  an `AttributeEditorManager` child per non-managed attribute; `renderAttributeSummaries` for
  `summary:`-bound ones. The source card mirrors these two loops and nothing else from the worker card
  (no progress, no outcome chip, no validation slice).
- **`MultiFileInputEditor`** (`…job/edit/`): `Wrapper` injects `ClientStateGlobal`,
  `MirroredGraphStore`, `ClientRestApi`; state = committed `paths` + transient browse (`directory`,
  `filter`, `entries: List<DataLocationInfo>`); writes the whole list via `UpsertAttributeCommand` on a
  `ListAttributeNotation`; browse via `ClientRestApi` → `CommonRestApi.fileListing`. Registered in
  `job-js.yaml` as `MultiFileInputEditor: {is: AttributeEditor, class: …$Wrapper}`.
- ⚠ **`FileListingAction.parseFilter` is a contains-all-words match on the file name**, lowercased and
  whitespace-split — **not a glob**. `sales csv` matches `2026-sales.csv`; `*.csv` matches nothing.
- **Reference pickers**: `SelectLogicEditor` (`…script/display/edit/`) over `SelectReferenceEditorBase`
  (`…common/edit/select/`) — lists candidate `ObjectLocation`s by a predicate; `ReferenceLinkAttributeView`
  renders the chosen reference as a link in summary mode (the in-card summary's link half).
- **Detached call from the client**: `ClientRestApi.performDetached(objectLocation, vararg
  parameters: Pair<String, String>): ExecutionResult` — `objectLocation` is the **`DataSourceActions`**
  object (one well-known location; put it in `DataSourceConventions`), the source's location goes in as
  the `source` parameter (wire form: whatever `ObjectLocation` encoding `ModelDetachedExecutor` already
  accepts — DS2 pinned it); the result arrives as an `ExecutionValue` tree; decode with
  `DataResolveResult.ofExecutionValue` (DS1, commonMain).
- **Ribbon registration**: `job-js.yaml` `JobGroup_Sources` / `*Tool` (`is: RibbonTool, parent:,
  delegate:`), `archetype: Job` on the group.
- **Nested-object rendering precedent**: the parameters branch (`LogicSignatureEditor` rows over
  `main.parameters/*`) — rows, add/remove/rename, drag order; the sources section is the same shape
  with a card body instead of a one-line row.
- **Duplicate-report precedent**: `LogicContextAnalysis` reports duplicate Context keys graph-wide as a
  finding rather than preventing them — *not needed this session* (no ids are minted); recorded for the
  day provider-bound sources arrive (O15).

## Pre-resolved questions

1. **Section or inline (O10)?** A **section** (`main.sources/*`), not inline nesting under the Read
   card. **O10 was demoted 2026-08-21b** from load-bearing to a refinement: the trivial case is three
   cards either way (analysis §5.2a), so this is no longer a compromise, it is the shape. What carries
   the ergonomics is item 4's auto-bind plus item 2b's in-card summary. Revisit O10 only on evidence
   that the section split actually hurts.
   **A composite "Read File" ribbon tool inserting two objects was considered and rejected** (§5.2a):
   a palette entry that expands into several objects leaves the user with objects they did not knowingly
   create, and the card they clicked is not the card they must edit.
2. **(2b) The in-card bound-source summary.** The Read card renders its bound source as a read-only
   one-line summary — `FileDataSource "input" · 1 unit · x.csv` — with an affordance that focuses the
   source card. `ReferenceLinkAttributeView` already renders the link half; the unit/file teaser comes
   from the card's last Resolve result if one is cached client-side, and is simply omitted otherwise
   (**never** an implicit detached call per render — Pre-resolved 4).
3. **Where the source card's attribute editors come from** — `AttributeEditorManager` per attribute,
   which dispatches on `editor:` metadata; `FileDataSource.files` names `FileSelectionEditor`, `missing`
   uses `SelectValuesEditor`, everything else `DefaultAttributeEditor`. **Zero file-specific code in
   `DataSourceCard` or `JobController`** — that is the acceptance criterion for "general".
4. **What "Resolve" shows, and when** — the lowered `DataResolveResult`: one row per unit (attributes as
   columns, then `role: id` per part — the fingerprint keys `size` / `modified` are shown but greyed, so
   a user sees what the manifest records), capped at a teaser count with "… and N more" (the
   progress-teaser convention), plus one line per diagnostic (`skipped: <path>`); errors rendered as
   text in the card. Invoked **on click and on an explicit refresh only** — never on every render
   (analysis §4 / §6.2 discipline; a directory walk per keystroke is not acceptable, and a future
   non-file source may be far more expensive).
   **There is no row preview** (§9, deliberately): columns are the design-time data surface, and
   "read me ten rows" assumes rows are meaningful and cheap, which a source whose items come out of a
   pipeline cannot promise. The **Columns** action lands in DS6.
5. **Auto-bind rule** — on `ReadWorker` insert (the insert path in `JobController`), if exactly one
   source is visible to `allDataSources` **within this Job's document** and the new worker's `source` is
   blank, the insert command sequence also upserts `source` to that location. (Scope the auto-bind to
   the *document*, not the graph: a project with six shared sources must not silently pick one.) Also
   offered by the picker as the preselected option. Never rebinds an existing value.
6. **No id minting.** *(Removed 2026-08-23 — O15 is deferred past the arc; file refs are plain. When a
   provider-bound source arrives, the mint-on-insert helper described in the 2026-08-21b plan — one call
   site, client-side UUID, never auto-remint a duplicate — is the shape to build.)*
7. **Renaming and deleting a source** — with a **structural** `source:` reference (DS3), kzen-lib's
   rename refactor rewrites it like any other reference; verify in the browser smoke. If DS2's O14 spike
   failed and DS3 fell back to `by: Nominal`, confirm `NotationReducerRefactor` handles the weak
   reference too (the `RunWorker.instructions` rename is the precedent to test against). **Delete** (C15):
   the spike's verdict and DS3's Pre-resolved 1 decision say what happens to the Read card — the smoke
   verifies the card shows a clear "source missing" state (or degrades, if DS3 chose that) and does not
   silently vanish or throw at render. A persisted `DataRef` is unaffected either way — it is a path.

## Step-by-step implementation

### Step 1 — `DataSourceCard` + sources section (client)

`…client/objects/document/job/source/DataSourceCard.kt` (+ `DataSourceCardProps`), rendered by
`JobController` for each `directNestedObjectPaths(main, sources)` location; rename via the existing
rename command; remove via the existing remove-object command; attribute editors per Pre-resolved 3.
Section header "Data sources" with the empty state "Add a data source from the ribbon".

### Step 2 — ribbon + insert branch

`job-js.yaml`: `JobGroup_Data` (`is: RibbonGroup, title: "Data", archetype: Job`) +
`FileDataSourceTool` (`delegate: FileDataSource`). `JobController` insert handler: if
`DataSourceConventions.isDataSource(graphNotation, archetypeLocation)` → append under `sources` (no gap
mode); else the existing worker path. Keep the decision in one place (CC-05). No id upsert.

### Step 3 — `FileSelectionEditor` (client) + `editor:` bindings

`…job/edit/FileSelectionEditor.kt` from `MultiFileInputEditor` (rename via `git mv` to keep history;
the old archetype still names `MultiFileInputEditor`, so keep a one-line alias registration in
`job-js.yaml` pointing at the new wrapper). Reads `directory` / `filter` from the *object's* attributes
(observer on the source location), writes `files` as `FileSelectionSpec.asNotation`; per-file format /
encoding fields. **The `filter` field's placeholder/help says what it is** — "all of these words, e.g.
`sales csv`" — and must not say "glob" or show `*.csv` (C6). `data-source-jvm.yaml` gains
`meta.files: {…, editor: FileSelectionEditor}` and `meta.missing: {is: String, editor:
SelectValuesEditor, values: {fail: "Fail if a file is missing", skip: "Skip the unit"}}` — **in the same
change as the registrations**.

### Step 4 — `SelectDataSourceEditor` + auto-bind

`…job/edit/SelectDataSourceEditor.kt` over `SelectReferenceEditorBase`: candidates =
`DataSourceConventions.allDataSources(graphNotation)` (graph-wide, so another Job's `sources:` — and,
later, a `DataSources` document — appear), grouped by document with the current Job's own sources
first; preselect when the document has exactly one. `JobController` insert sequence per Pre-resolved 5.
`job-js.yaml` registration, and `job-worker.yaml` gains `ReadWorker.meta.source.editor:
SelectDataSourceEditor` **in the same change**.

### Step 5 — Resolve chrome + in-card summary

In `DataSourceCard`: a "Resolve" button → `performDetached(dataSourceActionsLocation, "source" to
<card location wire form>, "action" to "resolve")` → `DataResolveResult.ofExecutionValue` → teaser
table + diagnostics lines. Busy / error states. In the Read card: the one-line bound-source summary
(Pre-resolved 2b).

### Step 6 — defensive editor fallback (small, general)

`AttributeEditorManager`: on a name miss, fall back to `DefaultAttributeEditor` **and** render a small
inline warning naming the missing wrapper, instead of replacing the field with text. ~5 lines, removes a
standing footgun ("a typo is a blank UI, found only by the boot check") and makes a
`editor:`-before-registration mistake degrade instead of brick.

**Split point:** steps 1–3 ship the editing; steps 4–6 are the ergonomics + chrome. If the session
runs long, land 1–3, smoke the trivial case with a hand-typed `source`, and record 4–6 as the remainder.

## Tests

Client tests are thin in this codebase (`AttributeWrapperLookupTest` is the shape); the load-bearing
verification is the browser smoke. Still:

1. **`FileSelectionSpecTest`** (commonTest, DS2) is the parse contract the editor writes — extend with
   the exact notation the editor emits (ordered entries, blank format/encoding omitted).
2. **`DataSourceConventionsTest`** additions (commonTest, DS2) — `allDataSources` returns a Job's own
   `sources/` objects *and* another Job's, in a deterministic order; the abstract archetype is excluded
   (`drop(1)`).
3. **`AttributeEditorManager` fallback** (js test if the harness allows, else covered by the boot check)
   — an unknown `editor:` name renders the default editor plus a warning, not bare text.
4. **Client compile gate**: `./gradlew :kzen-auto-js:compileKotlinJs`; then the AGENTS "client-graph
   boot check" (headless Chrome `--dump-dom` on a fresh project) — a mis-registered `@Reflect` wrapper
   kills the client graph at boot and no JVM test sees it.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-js:compileKotlinJs :kzen-auto-jvm:test`.
2. **Browser smoke (the deliverable)** — dev loop `./gradlew :kzen-auto-jvm:frontendDevelopment
   -PjsWatch` against a temp project, DOM-inspected not eyeballed (the XCE precedent):
   - New Job → ribbon **Data → File** → a source card appears under "Data sources"; directory typed;
     the browser lists the directory; **`filter` typed as `sales csv` narrows it, and the field does not
     advertise globs**; click a CSV → `files` shows one entry; **Resolve** shows one unit, one part, the
     path, and the greyed fingerprint.
   - The source's notation carries **no `id`** (O15 deferred — if one appears, something re-grew the
     2026-08-21b shape).
   - Ribbon **Sources → Read** → card appears with `source` **already bound** and rendered as a one-line
     summary; ribbon **Read → Summary**; Run → Summary count = line count.
   - Rename the source → the Read card's `source` follows (or record the finding, Pre-resolved 7).
   - **Delete the source** → the Read card shows the state DS3 decided (C15) — a clear "source missing"
     message, not a vanished card and not a render error; undo restores it.
   - Two sources in the document → Read's picker offers both, **no** auto-bind; a source in a *second
     Job document* also appears in the picker, grouped under that document.
   - `missing: skip` over a selection with one absent file → Resolve shows the reduced unit count and a
     `skipped: <path>` diagnostic line.
   - Collapse/expand, delete source, undo — no console errors.
   - The **`MultiFileReaderWorker`** card in an existing document still shows its editor (alias
     registration) — open one of the test fixtures, not the user's `main/`.
3. If the session is headless, record every row above as manual smoke debt in the master plan (house
   precedent) — do not mark the row landed without it.
4. As-built → analysis **§14**; tick row 54; delete this file.

## Risks & gotchas

- **Client graph boot** — every new `@Reflect` wrapper must be registered in `job-js.yaml` with the
  exact `$Wrapper` class; a typo is a blank UI, found only by the boot check. Step 6 softens this but
  does not remove it (a missing *registration* is still a missing editor).
- **`editor:` key without its registration bricks the field** (C5) — the ordering rule above is the
  fix; step 6 is the belt.
- **Do not call `DataSourceActions` on render.** Resolve is click-driven. A directory walk per
  keystroke is bad; a JDBC round-trip per keystroke is unacceptable, and the card must be written now as
  if the next source is that one.
- **Do not mint an `id`, and do not add `DetachedAction` to the source.** Both are the 2026-08-21b shape;
  both left for a reason (analysis §15 D8, D10).
- **Observer rules** — the source card observes its own location; guard `objectLocation !in
  graphNotation.coalesce` on stale locations (a just-deleted source), the `SortSpecEditor` pattern.
- **Do not fetch in `onCommandSuccess`** — derive, then `async { }`.
- **`MultiFileInputEditor` alias** — removing the registration outright breaks the old archetype's card
  for every existing document; keep the alias until the archetype is retired (user decision).
- **`UpsertAttributeCommand` on `files`** — rewrite the whole list (the existing editor's robustness
  argument: inherited-only vs materialized, duplicates, reorder).

## Out of scope (this session)

- Inline-nested source under the Read card (O10) — recorded, demoted, not attempted.
- **The `DataSources` document** and its controller (O21) — deferred past the arc; the picker is
  already graph-wide, so it will be additive.
- `DataSourceId` minting / duplicate reporting (O15) — deferred past the arc.
- Column dropdowns / the **Columns** card action / schema chrome — **DS6**.
- A row-level data preview — **not planned** (§9).
- Generic editor vocabulary growth (extension-points §2.1) beyond what these two editors need — its own
  arc.
