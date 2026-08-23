# DS3 — `ReadWorker` (source-generic declarative reader) — implementation plan

> **Status: ready to execute.** Session 3 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§5.2a** (the worker, the trivial-case walk-through, O11 knob, the `attributes` knob — O22), **§5.2b**
> (why heterogeneous schemas fail), §3.5 (unit attributes onto the item lane), §4 (suspend SPI;
> worker-driven cursor — O20), §5.6 (whole-unit rule), §6.5 (run-graph access — D2), §8.1–8.2
> (resolve-once manifest + positional cursor), **§15** (third-pass record — C10, C11, C12, C15, D6, D12).
> Constituent plan: **—** (analysis doc is the record; delete on landing, as-built → analysis **§14**).
> Depends on **DS1, DS2**; **DS1b** should have landed (see below). Anchors verified 2026-08-21;
> **rewritten 2026-08-23** by the third-pass review. Sized **M–L**; kzen-auto-jvm + two yaml files + one
> JS ribbon entry; no client editor work (DS4). Ledger row 53. **This plus DS4 is what makes "count the
> lines of one file" three cards and no code.**
>
> **What changed 2026-08-23:** the worker drives a **`DataCursor`** one `next()` per
> `control.runBlockingIo` (the `CsvReaderWorker` precedent — not "plain iteration over a `Sequence`",
> C11); the run-time **`WorkerDataContext`** is suspend-capable and wraps `control.runBlockingIo` /
> `control.host` directly (the 2026-08-21b non-suspend `WorkerDataScope` could not, C10); parts open
> through **`DataOpenerLookup`**, not through the source (D8); `payloadFlow` reads **`staticShape(role)`**
> (no `part` exists at walk time, C12); new **`attributes: ignore | columns`** knob — the `groupBy`
> parity path (D12, O22); the O14 spike's **delete** verdict decides the blank/dangling behaviour (C15).

## Scope & goal

```
ReadWorker(source: <DataSource, nullable structural ref>, emit: items | units, role: "", attributes: ignore | columns)
    -> item lane | unit lane
```

- **`emit: items`** (default): resolve once → for each unit, open the part of `role` (default: the unit's
  only role) via `DataOpenerLookup` → drive the cursor, emitting each item as a `JobMessage` —
  `ofFlat(header, record)` when `cursor.shape is Tabular`, else `ofPayload`. The lane carries records,
  so `SummaryWorker` counts lines.
- **`attributes: columns`** (under `items`): each flat record is widened with the unit's attributes as
  **leading** columns — header = attribute names (in display order) + the part header. Under `ignore`
  (default) the unit is gone once the item is emitted. This is the unit-identity-on-the-item-lane that
  J4's grouped export consumes (analysis §3.5, §9). A `Tabular` shape is required for `columns`; an
  `Object` shape under `columns` is a validation error naming the knob (attributes have nowhere to go).
- **`emit: units`**: resolve → one `JobMessage.ofPayload(unit)` per `DataUnit`. Multi-role units are
  never split here (analysis §5.6 **[decided]**); under `items` a unit that is not single-role and has no
  `role` pinned is a **run failure naming the roles**, not a silent concatenation.
- **Resolve once** per run; the manifest is run state (§8.1). **Positional cursor** across a live edit:
  `(manifest, unitIndex, partIndex, itemIndex, open DataCursor)` carried `CsvReaderWorker`-style. The
  **manifest is carried, never re-resolved** — that closes the changed-directory hazard rather than
  detecting it — and adoption is guarded on the source's **definition digest** plus this worker's own
  config.
- **`payloadFlow`:** `units` → `payloadType = DataUnit`, columns unknown; `items` → from the opener's
  `staticShape(role)` (notation-only, null in DS2/DS3; DS6 fills it and adds the cache) — `Tabular` →
  `flatColumns` (+ attribute columns when `columns`), `Object` → `payloadType`. No IO on the walk (O3).
- Replaces `CsvReaderWorker` and `MultiFileReaderWorker` **in the ribbon**; their archetypes stay
  (the user's `notation/main/*.yaml` reference them — retirement is the user's call, see Out of scope).

## Dependencies & coordination

- **DS2 landed**: `DataSource` / `DataOpener` / `DataCursor` / `DataContext`, `FileDataSource`,
  `FileDataOpener` + `DataOpenerLookup`, `DataSourceConventions`, the Job `sources:` branch — **and the
  O14 spike's three verdicts**, which decide this session's `source:` attribute kind **and** its
  dangling-reference behaviour. Re-verify those names before editing.
- **DS1b should have landed.** Without it `emit: units` publishes `payloadType = Any` instead of
  `DataUnit` (analysis §5.5a): the card display and every downstream expression are wrong, though
  nothing fails loudly. If DS1b has not landed, land it first or record the wrong-type display as known
  and re-test after.
- **DS4 (editing surface) is independent** and may run in parallel, but neither is demonstrable alone:
  together they are the trivial case. ⚠ **Do not declare `editor: SelectDataSourceEditor` in this
  session's notation.** `AttributeEditorManager` falls back to `DefaultAttributeEditor` only when an
  attribute has **no `editor:` metadata**; a declared-but-unregistered name renders the literal
  `[Attribute editor not found: …]` with no input (C5). Ship `source:` with no `editor:` key — it then
  gets the default text editor, which is enough for tests and the headless smoke — and let DS4 add the
  key alongside its `@Reflect` registration.
- **DS5 (`ReadPartWorker`) shares this session's drain core** — write it as a lifted helper from the
  start (`DataReadCore` or similar: opener lookup, per-item `runBlockingIo` drive, `ofFlat`/`ofPayload`
  by shape, the attribute-column widening, the detach-on-migrate handle discipline). CC-12: DS5 must not
  copy it.
- **J3 supersession**: `ReadWorker` over `FileDataSource` + `FileDataOpener` + format plugins *is* J3a's
  reader; the A/B below is J3's A/B, re-homed. `J3_report-subsumption-a.md` is marked superseded in
  `README.md`.
- **J4 (`groupBy` export)** consumes `attributes: columns` — its `MultiFileReaderWorker` group column
  becomes the stamped attribute column. Note it in the as-built so J4 plans against the knob, not an
  expression.
- **J9 (file-backed carry-forward) overlap:** the cursor contract here is the reader half of J9's
  concern; J9's writer/pivot/explore carry is unaffected. Note it in the as-built.
- **File safety:** never edit `notation/main/`. Archetype changes additive.

## Current-state findings (anchors verified 2026-08-21, re-checked 2026-08-23)

- **Worker framework** (`…server/objects/job/worker/`): `SourceWorker(output, selfLocation)` with
  `suspend produce(emit, control)`; the framework owns end-of-stream, batching, the per-batch checkpoint
  and progress publication (`Emitter.sourceCadence`). `WorkerBase`: `onStart` / `onClose` /
  `captureMigrationState` / `loadMigrationState` / `payloadFlow(input, context)` / `progress(snapshot)`.
- **`JobControl.runBlockingIo(block: () -> R)` and `JobControl.host(…)` are both `suspend`**
  (`common/paradigm/job/control/JobControl.kt`); `runBlockingIo` offloads through `Execution.blocking` —
  counted by the `CountingDispatcher`, interruptible by cancel / migrate. **`WorkerDataContext.blocking`
  / `.host` are suspend and delegate directly** — that is the whole reason the SPI is suspend (C10).
- **The cursor precedent is `CsvReaderWorker` + `CsvRecordReader`**: `produce` does
  `control.runBlockingIo { reader.readRecord() }` **per record**; `ReaderState` holds the open reader;
  `captureMigrationState` **detaches** it (`detached = true` so `onClose` skips closing) and hands it to
  the snapshot; `loadMigrationState` adopts it when config is unchanged, else restarts.
  `MultiFileReaderWorker` adds the `(fileIndex, position)` shape and guards on `paths` / `delimiter` /
  `header` equality. `FormulaSourceWorker` guards on `code` equality and claims `nextIndex` **before**
  `emit.send` (a send parked mid-flush holds its payload in the channel's in-flight buffer).
- **The run graph already holds the source.** `JobRun` calls
  `GraphCreator.createGraph(filteredDefinition, graphEnvironment)` over
  `filterTransitive(documentPath)` — the whole filtered definition — so a source referenced structurally
  is instantiated once, in the run's own graph, and injected by kzen-lib. **No resolver on the run path**
  (analysis §6.5 / D2).
- **Flat vs payload messages**: `JobMessage.ofFlat(header: HeaderListing, record: FlatFileRecord)` /
  `ofPayload(Any?)`; `WorkerLane(payloadType: TypeMetadata?, flatColumns: HeaderListing?)` — null
  flatColumns = statically unknown; `WorkerLaneAttempt(lane, error)`.
- **Downstream workers fix their schema on first sight** — this is *why* heterogeneous headers fail
  (§5.2b): `SummaryWorker.ensureInitialized` sets its column set from the **first** record's header and
  maps later records on by name (a column first appearing in unit 2 is silently dropped);
  `CsvWriterWorker` writes the header from the first batch and then writes each record's fields (a wider
  later record makes ragged rows). Put that reason in the KDoc — the next reader will otherwise "fix"
  the failure by concatenating.
- **Widening a flat record**: `FlatFileRecord` is built via `addToField` / `commitField`; a widened record
  is a fresh `FlatFileRecord` with the attribute values committed first, then the part record's fields —
  check whether `FlatFileRecord` exposes a cheap copy/prepend (it is the `JobMessage` memory-reuse seam);
  if not, build via the safe API and note the allocation in the as-built.
- **Object-ref attribute precedents**: `RunWorker.instructions` — `is: ObjectLocation, by: Nominal,
  editor: SelectLogicEditor, summary: ReferenceLinkAttributeView` (a *value*); `ContextBinder.binds` —
  `is: ObjectLocation, nullable: true, by: Nominal`. A **nullable structural** reference
  (`is: DataSource, nullable: true`, no `by:`) has no shipped precedent — DS2's spike is what licenses it,
  and its **delete** verdict (C15) is what decides the dangling case.
- **Ribbon**: `notation/auto-js/document/job-js.yaml` — `JobGroup_Sources` with `CsvReaderTool` /
  `FormulaSourceTool` / `MultiFileReaderTool` (`is: RibbonTool, parent:, delegate: <Worker>`).
- **Tests**: `FormulaSourceWorkerTest` (direct-instantiation harness: `KzenAutoContext.forTest()`,
  capturing `ChannelOutput`, no-op `JobControl`); `MultiFileReaderWorkerTest` (`NoOpJobControl`,
  `capturingOutput`, the `carriesFileCursorAcrossLiveEdit…` migration shape); `JobNotationTest`
  (engine-level run of a `notation/test/job/*.yaml` fixture to `Outcome.Success`); `JobValidatorTest`
  (payload-type walk).
- **Progress**: `progress(snapshot)` returns an opaque `Map<String, Any?>` — keep it that way (AGENTS
  gotcha / CC-17): `units`, `unit` (current index), `emitted`.

## Pre-resolved questions

1. **`source:` attribute kind** — a **nullable structural reference**: `meta.source: {is: DataSource,
   nullable: true}`, body default `source: ""`. The instance arrives by constructor injection from the
   run graph. **Contingent on DS2's O14 spike**; if (a)/(b) failed, fall back to `is: ObjectLocation,
   by: Nominal` + design-time-style instantiation in the worker, and record the deviation prominently.
   **If (c) showed prune-on-delete**: decide here whether that is acceptable — recommendation: **yes**,
   provided the editor surfaces it (the Read card shows the definition error naming the missing source;
   DS4 smokes it), because a reader whose source was deleted *should* not run. Record the decision.
2. **Knob vs split (O11)** — the `emit` knob, per the analysis recommendation. The card's published type
   differs per mode and nothing else does.
3. **`role` attribute** — `String`, blank = "the unit's only role" (`DataUnit.isSingleRole`), else the
   named role; under `emit: units` it is ignored (units flow whole). A non-single-role unit under
   `items` with blank `role` → `IllegalStateException` listing the roles (CC-08).
4. **`attributes` attribute (O22)** — `String`, `ignore` (default) | `columns`; `SelectValuesEditor`.
   Under `columns`: attribute names become leading header labels in the unit's display order; values are
   the text attribute values. **Collision** between an attribute name and a part column → fail naming
   both (CC-08), never shadow. Under `units` it is ignored.
5. **The run-time `DataContext`.** `WorkerDataContext(control)` in this package — a small class, not an
   object: `argument(name)` → `control.parameter(name)` (**named**, per O13); `contextValue(key)` → the
   run's Context registry via `control` (a `JobControl` addition if none exists — keep it to a read, and
   if it is more than a few lines, defer it with a `null` return and record it: nothing in DS2–DS8 needs
   a Context yet); `blocking { }` → `control.runBlockingIo { }` (**suspend → suspend**, direct); `host(…)`
   → the named `JobControl.host` overload when DS8 adds it, until then `UnsupportedOperationException`.
   Built once in `produce`, passed to `resolve` and every `open`. **Never handed to a cursor.**
6. **The drain loop** — `while (control.runBlockingIo { cursor.hasNext() }) { val item =
   control.runBlockingIo { cursor.next() }; claim itemIndex; emit }` — or one offload per
   `hasNext+next` pair; either way **every cursor call is inside `runBlockingIo`** (C11). The source
   cadence checkpoints per batch as today. (A future batch-per-offload optimization is a worker-side
   change; note the seam in KDoc.)
7. **Cursor guard** — `ReadCursor(sourceDefinitionDigest, emit, role, attributes, manifest, unitIndex,
   partIndex, itemIndex, cursor: DataCursor?)`. On load: adopt iff the digest, `emit`, `role` and
   `attributes` all match; then continue over the **carried** manifest (no re-resolve) and the carried
   open `DataCursor` (claim-before-send on `itemIndex` as `FormulaSourceWorker` does), driven by the
   **new** control. Otherwise restart. Document in KDoc that a changed source *config* restarts even if
   the directory contents are the same — the honest guard is the definition digest, not the filesystem —
   and that the manifest is carried precisely so a changed directory cannot corrupt a resume (C7, §8.1).
8. **Where the definition digest comes from.** `GraphInstanceCache.cacheKey(definition, location)`
   computes exactly the right thing (closure digest + inheritance-chain digests). Make that helper
   internal-visible and reuse it rather than duplicating (CC-12); it is a pure function of the
   definition, so it does no IO and is safe at capture time.
9. **`emit: items` header handling** — take `cursor.shape` per part; if a later part's `Tabular` header
   differs from the first, **fail** naming both headers and the unit (§5.2b) rather than re-synthesize.
   A mix of `Tabular` and `Object` shapes, or of `Object` types, across parts → fail the same way.
   `MultiFileReaderWorker`'s per-file header-skip semantics are the opener's concern (`FileDataOpener`
   honours the definer's skip). DS6 replaces the failure with superset normalization (O19).
10. **Where the ribbon tools go** — `ReadTool` joins `JobGroup_Sources`; `CsvReaderTool` and
    `MultiFileReaderTool` are **removed from the ribbon** in this session (archetypes kept). The ribbon is
    the only discoverability surface, so this is the deprecation step.

## Step-by-step implementation

### Step 1 — `DataReadCore` + `WorkerDataContext` (jvm)

`…/server/objects/job/worker/DataReadCore.kt` (the lifted drain core, DS5 reuses it verbatim):
`open(context, lookup, part)`, `drain(control, cursor, fromItemIndex, unitAttributes?, emit)` doing
the per-item `runBlockingIo` drive, `ofFlat`/`ofPayload` by shape, attribute widening, claim-before-send;
plus the detach/close discipline helpers. `WorkerDataContext.kt` per Pre-resolved 5.

### Step 2 — `ReadWorker` (jvm)

`…/server/objects/job/worker/ReadWorker.kt`: `SourceWorker`; ctor `(output, source: DataSource?,
emit: String, role: String, attributes: String, selfLocation, @Service DataOpenerLookup)`. `produce`:
build the context → `source.resolve(context)` once (log diagnostics) → iterate units/parts through the
core. A null `source` fails at `produce` with "no data source selected". `onClose` closes the open
cursor unless detached. `captureMigrationState` / `loadMigrationState` per Pre-resolved 7. `payloadFlow`
per Scope. `progress`. KDoc: the cursor contract, the carried-manifest rationale, the heterogeneous-header
reason, the `attributes` knob, and the CC-21 pointer to `ReadPartWorker` (DS5) once it exists.

### Step 3 — notation

`job-worker.yaml`: `ReadWorker` — `is: Worker`, `title: "Read"`, `output: ""`, `source: ""`,
`emit: "items"`, `role: ""`, `attributes: "ignore"`, `meta`: `output` (ChannelOutput / JobChannelCreator
/ SelectChannelEditor), `source: {is: DataSource, nullable: true}` (**no `editor:` key — DS4**),
`emit: {is: String, editor: SelectValuesEditor, values: {items: "Items", units: "Units"}}`, `role:
String`, `attributes: {is: String, editor: SelectValuesEditor, values: {ignore: "Ignore", columns: "As
columns"}}`, `selfLocation`. `job-js.yaml`: `ReadTool` in `JobGroup_Sources`; delete `CsvReaderTool` +
`MultiFileReaderTool` entries.

### Step 4 — validation hook

`JobValidator`'s walk already calls `payloadFlow`; nothing to add. Confirm `JobValidator` enumerates
`workers` only, so the `sources/` branch is invisible to it (no change expected).

## Tests

1. **`ReadWorkerTest`** (jvm, `server/objects/job/worker/`) — direct instantiation with a
   `FileDataSource` (constructed directly, as `FileDataSourceTest` does), the real `FileDataOpener` via a
   test `DataOpenerLookup`, and a capturing control that **counts `runBlockingIo` calls**:
   **A/B vs `CsvReaderWorker`** over the RFC-4180 edge-case CSV — identical `record.toList()` streams and
   equal `HeaderListing` on every message, **and at least one `runBlockingIo` per record** (C11 — this
   is the row that catches a plain-iteration regression); **A/B vs `MultiFileReaderWorker`** over two
   headered CSVs with the **same** header — same concatenation order, header-skip agreement; two CSVs
   with **different** headers → fails naming both (the deliberate divergence, §5.2b); `emit: units` over
   three files → three `DataUnit` payloads in path order with `ref.id` = path; `role` pins a role on a
   two-role unit (hand-built `DataSource` + `DataOpener` fakes); blank `role` on a two-role unit under
   `items` fails naming both roles; **`attributes: columns`** over a `groupPattern` source → each record
   has the `date` column first, then the file's columns, header accordingly; attribute/column name
   collision fails naming both; `columns` over an `Object`-shaped fake → validation error;
   **migration**: capture mid-file → load with same config resumes at the exact record (no duplicates, no
   gaps — mirror `carriesFileCursorAcrossLiveEdit…`) **driven by a different control instance**, **the
   carried manifest is reused even when the directory changed underneath** (add a file between capture
   and load; the resumed stream must not see it), changed source digest restarts, changed `emit` /
   `attributes` restarts; `onClose` after capture does not close the detached cursor (file deletable only
   after the resumed instance closes); a null `source` fails with a clear message.
2. **`JobReadNotationTest`** (jvm, `server/exec/job/`, modeled on `JobNotationTest`) + fixture
   `notation/test/job/job-read-test.yaml`: `main: {is: Job}` with `sources/input: {is:
   FileDataSource, files: [build/job-read/input.csv]}` and `workers/read: {is: ReadWorker, source:
   main.sources/input}` → `CsvWriterWorker`; run to `Outcome.Success`, output equals input. **This is
   what proves the archetype, the structural-reference injection through the real run graph, and that a
   `sources/` branch coexists with channel synthesis.** Note the contrast with DS2's detached test:
   `ModelDetachedExecutor` cannot see `test/` notation, but the **run** path can, because `JobRun`
   instantiates the run's own filtered definition rather than the `serverAllowed` subset — which is
   exactly D2's point, and this fixture is where it is visible.
3. **`JobValidatorTest`** addition — a `ReadWorker(emit: units)` lane infers `DataUnit` (⚠ requires
   **DS1b**; without it this asserts `Any` and the test is the tell); `items` lane is unknown-columns, no
   error; a blank `source` yields `WorkerLane.unknown` **plus a validation message** ("no data source
   selected") rather than a definition drop; **a deleted source** yields whatever Pre-resolved 1 decided
   — pin it.
4. **`JobMigrationTest`** addition — a Read → Summary Job migrated mid-stream ends with the correct total.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test` (new suites + `exec/job` + `objects/job` nets
   green); `:kzen-auto-js:compileKotlinJs` (ribbon yaml only, but the client graph must still build —
   AGENTS "client-graph boot check" if the ribbon renders blank).
2. **Headless trivial case** (no DS4 yet, so by notation): temp project with a Job whose `sources/input`
   is a `FileDataSource` over a 1000-line CSV and `workers/read` → `workers/summary`; run via the
   logic REST route; the Summary trace shows count 1000 (minus header). Record the curl lines in the
   as-built — they are DS4's smoke baseline.
3. Report suites green; `FormulaSourceWorkerTest` / `MultiFileReaderWorkerTest` untouched and green
   (the old readers are not deleted).
4. As-built → analysis **§14** (include the Pre-resolved 1 delete decision); tick row 53; delete this
   file.

## Risks & gotchas

- **Every cursor call inside `runBlockingIo`.** The one regression the A/B's offload counter exists to
  catch (C11). "It's only `hasNext()`" is how it creeps back.
- **Never hand the context to the cursor.** The carried cursor is driven by the *resumed* worker's
  control; a captured context would be the torn-down one (O20).
- **Claim-before-send** — `itemIndex` must advance *before* `emit.send` (the parked-mid-flush buffer rule
  in `FormulaSourceWorker`'s KDoc); the migration test is the canary.
- **Detached cursor across migration** — the carried `DataCursor` is a live handle; `onClose` on the
  torn-down instance must not close it (the `CsvReaderWorker.detached` flag pattern). Forgetting it
  resumes on a closed stream.
- **Carry the manifest; never re-resolve.** A resume that re-walks the directory is the §8.1 hazard, and
  the test in row 1 is what pins it. Re-resolution is also IO at migration time, which is forbidden.
- **Palette-insert defaults** — every attribute needs a body default (`source: ""`, `emit: "items"`,
  `role: ""`, `attributes: "ignore"`). With a **nullable** structural reference a blank `source` defines
  and injects null; the worker checks and fails at `produce`, and `payloadFlow` returns
  `WorkerLane.unknown` + the same message so the card shows it before a run. ⚠ Also remember
  `GraphCreator.createGraph` throws on *any* creation failure in the document — a blank source must never
  be a failure.
- **No `editor:` key this session** (C5). It is one line and it would brick the field.
- **Progress map opacity** — keys are plain strings; the client mirror (`JobWorkerProgress`) must not
  learn them (CC-17).
- **Lift the core now.** DS5's `ReadPartWorker` is the second customer; if the drain loop is inline in
  `ReadWorker`, DS5 copies it.

## Out of scope (this session)

- `SelectDataSourceEditor`, source cards, the sources section, `editor:` keys, auto-bind — **DS4**.
- `ReadPartWorker` and the 1:N transform cadence — **DS5** (uses this session's `DataReadCore`).
- Static columns under `items` from `staticShape` / the schema cache, and **superset normalization**
  replacing the heterogeneous-header failure (O19) — **DS6**.
- Publishing the resolved manifest to the trace — **DS7** (it belongs with "data out").
- Deleting `CsvReaderWorker` / `MultiFileReaderWorker` archetypes — **user decision** after DS4 is
  smoked; the user's `main/` documents reference them. Record as an open item in the as-built.
