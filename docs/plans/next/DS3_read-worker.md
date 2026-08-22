# DS3 — `ReadWorker` (source-generic declarative reader) — implementation plan

> **Status: ready to execute.** Session 3 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§5.2a** (the worker, the trivial-case walk-through, O11 knob), **§5.2b** (why heterogeneous schemas
> fail), §5.6 (whole-unit rule), §6.5 (run-graph access), §8.1–8.2 (resolve-once manifest + positional
> cursor). Constituent plan: **—** (analysis doc is the record; delete on landing, as-built → analysis
> **§14**). Depends on **DS1, DS2**; **DS1b** should have landed (see below). Anchors verified
> 2026-08-21. **Revised 2026-08-21b** by the second-pass review (§13 C3, C5, C7, D2). Sized **M–L**;
> kzen-auto-jvm + two yaml files + one JS ribbon entry; no client editor work (DS4). Ledger row 53.
> **This plus DS4 is what makes "count the lines of one file" three cards and no code.**

## Scope & goal

```
ReadWorker(source: <DataSource, nullable structural ref>, emit: items | units, role: "")  -> item lane | unit lane
```

- **`emit: items`** (default): resolve → for each unit, open the part of `role` (default: the unit's only
  role) → emit each item as a `JobMessage` — `ofFlat(flatHeader, record)` when `DataItems.flatHeader !=
  null`, else `ofPayload`. The lane carries records, so `SummaryWorker` counts lines.
- **`emit: units`**: resolve → one `JobMessage.ofPayload(unit)` per `DataUnit`. Multi-role units are
  never split here (analysis §5.6 **[decided]**); under `items` a unit that is not single-role and has no
  `role` pinned is a **run failure naming the roles**, not a silent concatenation.
- **Resolve once** per run; the manifest is run state (§8.1). **Positional cursor** across a live edit:
  `(manifest, unitIndex, partIndex, itemIndex, open DataItems)` carried `CsvReaderWorker`-style. The
  **manifest is carried, never re-resolved** — that closes the changed-directory hazard rather than
  detecting it — and adoption is guarded on the source's **definition digest** plus this worker's own
  config.
- **`payloadFlow`:** `units` → `payloadType = DataUnit`, columns unknown; `items` → `payloadType =
  source.itemType(part)` (notation-only, null in DS2/DS3) and columns unknown in this session (DS6 fills
  them from the pre-scan cache). No IO on the walk (O3).
- Replaces `CsvReaderWorker` and `MultiFileReaderWorker` **in the ribbon**; their archetypes stay
  (the user's `notation/main/*.yaml` reference them — retirement is the user's call, see Out of scope).

## Dependencies & coordination

- **DS2 landed**: `DataSource` / `DataScope` / `DataItems` / `FileDataSource` / `DataSourceConventions` /
  the Job `sources:` branch — **and the O14 spike's verdict**, which decides this session's `source:`
  attribute kind. Re-verify those names before editing.
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
- **J3 supersession**: `ReadWorker` over `FileDataSource` + format plugins *is* J3a's reader; the A/B
  below is J3's A/B, re-homed. `J3_report-subsumption-a.md` is marked superseded in `README.md`.
- **J9 (file-backed carry-forward) overlap:** the cursor contract here is the reader half of J9's
  concern; J9's writer/pivot/explore carry is unaffected. Note it in the as-built.
- **File safety:** never edit `notation/main/`. Archetype changes additive.

## Current-state findings (anchors verified 2026-08-21)

- **Worker framework** (`…server/objects/job/worker/`): `SourceWorker(output, selfLocation)` with
  `produce(emit, control)`; the framework owns end-of-stream, batching, the per-batch checkpoint and
  progress publication (`Emitter.sourceCadence`). `WorkerBase`: `onStart` / `onClose` /
  `captureMigrationState` / `loadMigrationState` / `payloadFlow(input, context)` / `progress(snapshot)`.
- **`JobControl.runBlockingIo(block: () -> R)` is non-suspend** and offloads through
  `Execution.blocking` — counted by the `CountingDispatcher`, interruptible by cancel / migrate. It is
  exactly what this worker's `DataScope.blocking` delegates to.
- **The run graph already holds the source.** `JobRun` calls
  `GraphCreator.createGraph(filteredDefinition, graphEnvironment)` over
  `filterTransitive(documentPath)` — the whole filtered definition — so a source referenced structurally
  is instantiated once, in the run's own graph, and injected by kzen-lib. **No `DataSourceResolver` on
  the run path** (analysis §6.5 / D2).
- **Cursor precedent**: `CsvReaderWorker` — `ReaderState` holds the open reader; `captureMigrationState`
  **detaches** it (`detached = true` so `onClose` skips closing) and hands it to the snapshot;
  `loadMigrationState` adopts it when config is unchanged, else restarts. `MultiFileReaderWorker` adds
  the `(fileIndex, position)` shape and guards on `paths` / `delimiter` / `header` equality.
  `FormulaSourceWorker` guards on `code` equality and claims `nextIndex` **before** `emit.send` (a send
  parked mid-flush holds its payload in the channel's in-flight buffer).
- **Flat vs payload messages**: `JobMessage.ofFlat(header: HeaderListing, record: FlatFileRecord)` /
  `ofPayload(Any?)`; `WorkerLane(payloadType: TypeMetadata?, flatColumns: HeaderListing?)` — null
  flatColumns = statically unknown; `WorkerLaneAttempt(lane, error)`.
- **Downstream workers fix their schema on first sight** — this is *why* heterogeneous headers fail
  (§5.2b): `SummaryWorker.ensureInitialized` sets its column set from the **first** record's header and
  maps later records on by name (a column first appearing in unit 2 is silently dropped);
  `CsvWriterWorker` writes the header from the first batch and then writes each record's fields (a wider
  later record makes ragged rows). Put that reason in the KDoc — the next reader will otherwise "fix"
  the failure by concatenating.
- **Object-ref attribute precedents**: `RunWorker.instructions` — `is: ObjectLocation, by: Nominal,
  editor: SelectLogicEditor, summary: ReferenceLinkAttributeView` (a *value*); `ContextBinder.binds` —
  `is: ObjectLocation, nullable: true, by: Nominal`. A **nullable structural** reference
  (`is: DataSource, nullable: true`, no `by:`) has no shipped precedent — DS2's spike is what licenses it.
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
   run graph. **Contingent on DS2's O14 spike**; if it failed, fall back to `is: ObjectLocation,
   by: Nominal` + `@Service DataSourceResolver`, and record the deviation prominently — it changes the
   run-time instance's provenance (analysis §6.5) and the as-built must say so.
2. **Knob vs split (O11)** — the `emit` knob, per the analysis recommendation. The card's published type
   differs per mode and nothing else does.
3. **`role` attribute** — `String`, blank = "the unit's only role" (`DataUnit.isSingleRole`), else the
   named role; under `emit: units` it is ignored (units flow whole). A non-single-role unit under
   `items` with blank `role` → `IllegalStateException` listing the roles (CC-08).
4. **The run-time `DataScope`.** A small `WorkerDataScope(control, jobParameters)` in this package:
   `argument(name)` → `control.parameter(name)` (**named**, per O13 — the Job's declared parameters are
   the source's arguments by name, so a dated source asks for `from` / `to` and gets them);
   `contextValue(key)` → the run's Context registry via `control` (a `JobControl` addition if none
   exists — keep it to a read, and if it is more than a few lines, defer it with a `null` return and
   record it: nothing in DS2–DS8 needs a Context yet); `blocking { }` → `control.runBlockingIo { }`;
   `host(...)` → `control.host(...)`. Called once in `produce`, reused for every `items()` open.
5. **Cursor guard** — `ReadCursor(sourceDefinitionDigest, emit, role, manifest, unitIndex, partIndex,
   itemIndex, items: DataItems?)`. On load: adopt iff the digest, `emit` and `role` all match; then
   continue over the **carried** manifest (no re-resolve) and the carried open `DataItems`
   (claim-before-send on `itemIndex` as `FormulaSourceWorker` does). Otherwise restart. Document in KDoc
   that a changed source *config* restarts even if the directory contents are the same — the honest
   guard is the definition digest, not the filesystem — and that the manifest is carried precisely so a
   changed directory cannot corrupt a resume (C7, §8.1).
6. **Where the definition digest comes from.** `GraphInstanceCache.cacheKey(definition, location)`
   computes exactly the right thing (closure digest + inheritance-chain digests). Make that helper
   internal-visible and reuse it rather than duplicating (CC-12); it is a pure function of the
   definition, so it does no IO and is safe at capture time.
7. **`emit: items` header handling** — take `DataItems.flatHeader` per part; if a later part's header
   differs from the first, **fail** naming both headers and the unit (§5.2b) rather than re-synthesize.
   `MultiFileReaderWorker`'s per-file header-skip semantics become the source's concern
   (`FileDataSource.items` honours the definer's skip). DS6 replaces the failure with superset
   normalization (O19).
8. **Where the ribbon tools go** — `ReadTool` joins `JobGroup_Sources`; `CsvReaderTool` and
   `MultiFileReaderTool` are **removed from the ribbon** in this session (archetypes kept). The ribbon is
   the only discoverability surface, so this is the deprecation step.

## Step-by-step implementation

### Step 1 — `ReadWorker` (jvm)

`…/server/objects/job/worker/ReadWorker.kt`: `SourceWorker`; ctor `(output, source: DataSource?,
emit: String, role: String, selfLocation)`. `produce`: build the scope → `source.units(scope)` once →
iterate units/parts → emit; each `items()` open goes through the scope's `blocking`; iteration itself is
plain (the source cadence checkpoints per batch). A null `source` fails at `produce` with "no data source
selected". `onClose` closes the open `DataItems` unless detached. `captureMigrationState` /
`loadMigrationState` per Pre-resolved 5. `payloadFlow` per Scope. `progress`. KDoc: the cursor contract,
the carried-manifest rationale, the heterogeneous-header reason, and the deliberate difference from the
expression route (DS5) — CC-21 reciprocal markers once `ExpandWorker` exists.

### Step 2 — notation

`job-worker.yaml`: `ReadWorker` — `is: Worker`, `title: "Read"`, `output: ""`, `source: ""`,
`emit: "items"`, `role: ""`, `meta`: `output` (ChannelOutput / JobChannelCreator / SelectChannelEditor),
`source: {is: DataSource, nullable: true}` (**no `editor:` key — DS4**), `emit: {is: String,
editor: SelectValuesEditor, values: {items: "Items", units: "Units"}}`, `role: String`, `selfLocation`.
`job-js.yaml`: `ReadTool` in `JobGroup_Sources`; delete `CsvReaderTool` + `MultiFileReaderTool` entries.

### Step 3 — validation hook

`JobValidator`'s walk already calls `payloadFlow`; nothing to add. Confirm `JobValidator` enumerates
`workers` only, so the `sources/` branch is invisible to it (no change expected).

## Tests

1. **`ReadWorkerTest`** (jvm, `server/objects/job/worker/`) — direct instantiation with a
   `FileDataSource` (constructed directly, as `FileDataSourceTest` does) and a fake scope:
   **A/B vs `CsvReaderWorker`** over the RFC-4180 edge-case CSV — identical `record.toList()` streams and
   equal `HeaderListing` on every message; **A/B vs `MultiFileReaderWorker`** over two headered CSVs with
   the **same** header — same concatenation order, header-skip agreement; two CSVs with **different**
   headers → fails naming both (the deliberate divergence, §5.2b); `emit: units` over three files → three
   `DataUnit` payloads in path order with `ref.id` = path; `role` pins a role on a two-role unit
   (hand-built `DataSource` fake); blank `role` on a two-role unit under `items` fails naming both roles;
   **migration**: capture mid-file → load with same config resumes at the exact record (no duplicates, no
   gaps — mirror `carriesFileCursorAcrossLiveEdit…`), **the carried manifest is reused even when the
   directory changed underneath** (add a file between capture and load; the resumed stream must not see
   it), changed source digest restarts, changed `emit` restarts; `onClose` after capture does not close
   the detached items (file deletable only after the resumed instance closes); a null `source` fails with
   a clear message.
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
   selected") rather than a definition drop.
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
4. As-built → analysis **§14**; tick row 53; delete this file.

## Risks & gotchas

- **Claim-before-send** — `itemIndex` must advance *before* `emit.send` (the parked-mid-flush buffer rule
  in `FormulaSourceWorker`'s KDoc); the migration test is the canary.
- **Detached items across migration** — the carried `DataItems` is a live handle; `onClose` on the
  torn-down instance must not close it (the `CsvReaderWorker.detached` flag pattern). Forgetting it
  resumes on a closed stream. And `DataItems` is **constrain-once**: a resumed instance must continue the
  *carried* iterator, never call `iterator()` again on it.
- **Carry the manifest; never re-resolve.** A resume that re-walks the directory is the §8.1 hazard, and
  the test in row 1 is what pins it. Re-resolution is also IO at migration time, which is forbidden.
- **`blocking` discipline** — `units()` and each `items()` open block; route both through the scope.
  Iteration over an open `DataItems` is plain IO per item and rides the source cadence like
  `CsvReaderWorker`'s reads.
- **Palette-insert defaults** — every attribute needs a body default (`source: ""`, `emit: "items"`,
  `role: ""`). With a **nullable** structural reference a blank `source` defines and injects null; the
  worker checks and fails at `produce`, and `payloadFlow` returns `WorkerLane.unknown` + the same message
  so the card shows it before a run. ⚠ Also remember `GraphCreator.createGraph` throws on *any* creation
  failure in the document — a blank source must never be a failure.
- **No `editor:` key this session** (C5). It is one line and it would brick the field.
- **Progress map opacity** — keys are plain strings; the client mirror (`JobWorkerProgress`) must not
  learn them (CC-17).

## Out of scope (this session)

- `SelectDataSourceEditor`, source cards, the sources section, `editor:` keys, auto-bind, minting
  `DataSourceId` — **DS4**.
- Static columns under `items` from the pre-scan cache, and **superset normalization** replacing the
  heterogeneous-header failure (O19) — **DS6**.
- Publishing the resolved manifest to the trace — **DS7** (it belongs with "data out").
- Deleting `CsvReaderWorker` / `MultiFileReaderWorker` archetypes — **user decision** after DS4 is
  smoked; the user's `main/` documents reference them. Record as an open item in the as-built.
