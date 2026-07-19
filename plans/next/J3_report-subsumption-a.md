# J3 — Report subsumption A: pluggable input formats + design-time services — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from `2026-07-16_job-improvements.md`
> **Phase 3** (master plan Stage B2). Decisions pre-made in the constituent plan — do not
> re-litigate. Every anchor below re-verified against current kzen-auto master (`ceb699d0`) on
> 2026-07-19; drift from the constituent plan (written pre-SER4/SER5) is called out inline —
> notably: **the file-browse half of "design-time services" already landed** (the document-agnostic
> `/file-listing` route + `MultiFileInputEditor` browse, SER3 era), and **the "synchronous plain
> loop over reused event objects" driver already exists** (`ReportInputChain`) — both rescope their
> steps down, not up. Sized L (one full session); a natural split point is defined at the end of
> § Step-by-step. kzen-auto only; kzen-lib untouched.

## Scope & goal

Close the Job flavour's input-side gaps against Report, without Report's document class in the
loop:

1. **`PluginReaderWorker`** — a SourceWorker that reads file(s) through the existing plugin SPI
   (`ReportDefiner` / `DataFramer` / segment steps in kzen-auto-plugin), driven synchronously
   (no Disruptor inside a Worker), emitting the same `DataRecord` stream the native readers emit.
   Third-party format plugins (e.g. `../kzen-sample-plugin`) become usable in a Job.
2. **Design-time column pre-scan service** — a flavour-neutral REST route over the existing
   `ColumnListingAction`, so a Job document (which has no `DetachedAction` surface —
   `JobDocument.kt:21-30`) can ask "what columns does this input file have" at edit time.
   (The file-browse twin of this route already exists: `/file-listing`.)
3. **`JobUpstreamSchema` fallback** — spec editors resolve candidate columns
   live-summary → reader-config-pre-scan → free text; un-strands `SortSpecEditor` from
   free-text-only.
4. **`encoding` attribute** on `CsvReaderWorker` / `MultiFileReaderWorker` (charset control the
   native readers lack today).

The extension rule is inviolable throughout: no Worker-type knowledge in any general layer —
reader-config discovery is a notation-metadata capability marker (the `JobServeCapability`
pattern), never a class-name or archetype-name check.

## Dependencies & coordination

- **No hard prerequisite** (J-plan header: only J4-on-J3 and J9-after-J4 are hard). J4 builds on
  this phase's outcomes; J8 consumes step 3's editor fallback ("J8 after J3").
- **J2 is being planned/executed in parallel** (`next/J2_job-signature.md`). Overlap surface:
  `JobControl` (J2 adds `parameter(name)` / `yieldResult(component, value)`), job-worker.yaml /
  job-js.yaml (J2 adds ParameterSource/ResultSink archetypes + tools), and test fakes. J2's
  design says the new `JobControl` members get default (no-op/null) implementations — if so, J3's
  new test fakes (copies of `NoOpJobControl`, MultiFileReaderWorkerTest.kt:184-192) compile
  unchanged. **If J2 lands first with abstract members instead, add no-op overrides to the fakes
  and re-sync yaml insertion points; nothing else here touches J2's files.**
- **SER4/SER5 landed** — the constituent plan's REST anchors are stale. The current
  action-routing pattern is re-derived in Current-state findings § C below; this plan's route
  additions follow it (typed kotlinx DTO + `respondJson`), not the old Jackson shapes.
- **AE plan**: `SortSpecEditor` is one of the editors J8.4 later dedupes (prefer after AE3+AE5).
  Step 3 deliberately makes the smallest self-contained change to it (add a column-source +
  dropdown branch), mirroring `ValueSetFilterEditor`'s existing shapes so the later dedupe sees
  two-of-a-kind, not a new one-off.
- **File safety**: `notation/main/` holds the user's working documents (`Job.yaml`, `Job-2.yaml`,
  `Report.yaml` reference `is: CsvReaderWorker` / `MultiFileReaderWorker`) — never edit them.
  All archetype changes are backward-compatible additions (new attributes with archetype-body
  defaults inherit cleanly into existing instances).
- Stage new files with `git add <explicit path>` as written; never commit.

## Current-state findings (anchors verified 2026-07-19)

### A. The plugin SPI and the synchronous driver — the driver already exists

- SPI (kzen-auto-plugin, unchanged by any recent work): `ReportDefiner<Output>`
  (`definition/ReportDefiner.kt` — `info()` + `define()`, reflection-instantiated, no-arg ctor);
  `ReportDefinition` = `ReportDataDefinition` + `headerExtractorFactory`
  (`definition/ReportDefinition.kt:6-9`); `ReportDataDefinition` = `dataFramerFactory` +
  `outputModelType` + `segments` with chain-compatibility checks
  (`definition/ReportDataDefinition.kt:7-36`); segment = model factory + intermediate step
  factories + terminal step + ring size (`definition/ReportSegmentDefinition.kt`);
  `ReportIntermediateStep.process(model, index)` / `ReportTerminalStep.process(model, output)`
  are **ring-agnostic** (`api/ReportIntermediateStep.kt`, `api/ReportTerminalStep.kt`);
  `DataFramer.frame(dataBlockBuffer)` (`api/DataFramer.kt`); `PluginCoordinate(name)`
  (`model/PluginCoordinate.kt` — deliberately kzen-free; conversions in
  `server/objects/plugin/PluginUtils.kt:27-35`).
- **Every output event carries a flattened row**: `ModelOutputEvent<T>` has
  `abstract val row: FlatFileRecord` + `skip: Boolean` (`model/ModelOutputEvent.kt:20-25`).
  Both the built-in CSV terminal (`FlatPipelineHandoff.java:38-54` — clones the record into
  `row`, marks the first event `skip=true` when `skipFirst`) and the sample plugin's terminal
  (`kzen-sample-plugin .../WcpFlatten.java:37-44` — `rowOrNull.flatten(flatBuilder)`) fill it.
  Report's own downstream stages consume `event.row` and gate on skip
  (`ReportFilterStage.kt:71-75`, `PipelineSummaryStage.kt:20`). **So a generic driver reads
  `event.row` for any payload type and honors `event.skip` — no payload-type knowledge needed.**
- **`ReportInputChain` (kzen-auto-jvm `server/objects/report/exec/input/ReportInputChain.kt`)
  IS the "synchronous plain loop over reused event objects" the constituent plan asked for** —
  do not write a new driver. It composes `ReportInputReader` (block reads) → optional
  `ReportInputDecoder(charset)` → `ReportInputFramer(dataFramerFactory())` → `DataFrameFeeder`
  → per-segment intermediate/terminal steps over reused `ListPipelineOutput` event buffers, all
  in one thread (`poll(visitor)`, :85-103; recursive `processSegments`, :106-143; `AutoCloseable`,
  :147-149). It is already the engine behind `CsvReportDefiner.literal`
  (`CsvReportDefiner.java:42-63` → `ReportInputChain.readAll` :29-47) and
  `ReportHeaderReader.extract` (`stages/ReportHeaderReader.kt:16-35`). Note
  `ReportInputReader.poll` has `check(!endOfData)` (:34-35) — stop the loop after the first
  `false` (the final `poll` still flushes the trailing partial record through the framer). The
  Disruptor terminal-step latch (`awaitEndOfData`) is never called on this path.
- File opening: `FileFlatDataSource.open` (`connect/file/FileFlatDataSource.kt:17-27`) →
  `FileFlatDataStream` (`connect/file/FileFlatDataStream.kt:35-57`) — **auto-gunzips `*.gz` and
  strips BOM for free**. `FlatDataHeaderDefinition(flatDataLocation, flatDataSource,
  reportDefinition)` bundles location+encoding+definition and can `openInputChain(dataBlockSize)`
  (`model/data/FlatDataHeaderDefinition.kt:16-26`). `FlatDataLocation` =
  `(DataLocation, DataEncodingSpec)` (`model/data/FlatDataLocation.kt`).
  `DataBlockBuffer.defaultBytesSize = 64 * 1024` (`DataBlockBuffer.java:14`).
- Copy-out semantics: chain event objects are reused buffers, and Job's `DataRecord` contract is
  fresh-allocation ownership-transfer (`job/worker/DataRecord.kt:20-23`). `FlatFileRecord
  .prototype()` returns a compact fresh copy (`FlatFileRecord.java:561-564`) — it's what
  `CsvReportDefiner.literal` uses for exactly this purpose.

### B. Definition repository + services — all wired, `@Service`-reachable

- `ReportDefinitionRepository` (`server/service/plugin/ReportDefinitionRepository.kt:11-47`):
  `contains` / `metadata` / `listMetadata` / `classLoaderHandle(coordinates, parent)` /
  `define(coordinate, handle)`, plus **`find(payloadType, dataLocation)`** (:21-47) which
  resolves a default coordinate by payload type + file extension — reuse it for the
  column-listing route's optional-coordinate default.
- Built-ins: `CsvReportDefiner` ("CSV"), `TsvReportDefiner` ("TSV"), `TextReportDefiner`
  ("Text") — coordinates verified (`*ReportDefiner.java:29` each); wrapped in
  `HostReportDefinitionRepository` + `PluginReportDefinitionRepository` under
  `MultiDefinitionRepository` (`KzenAutoContext.kt:153-163`).
- **`ReportDefinitionRepository` is in the graph environment** (`KzenAutoContext.kt:226`), as are
  `FileListingAction` (:229) and `ColumnListingAction` (:230) — so `@Service` injection into a
  graph-instantiated Worker works today (precedent: `FormulaWorker.kt:43`, `FilterWorker.kt:41`,
  `FormulaSourceWorker.kt:42`, and `ReportDocument.kt:79-84`).
- `ClassLoaderHandle` (`server/objects/plugin/model/ClassLoaderHandle.kt`) is a caller-owned
  `AutoCloseable`; `PluginReportDefinitionRepository.classLoaderHandle` builds a fresh
  `URLClassLoader` over the plugin jars (:162-202) and `define` loads the definer through it
  (:206-237) — both call `runBlocking { graphStore.graphDefinition() }` internally, so **from a
  Worker coroutine these must be wrapped in `control.runBlockingIo { }`** (keeps the blocking
  call visible to quiescence; JobControl.kt:22-27).
- The exact resolve-definition-and-list-columns recipe to mirror is
  `ReportDocument.datasetInfo()` (`ReportDocument.kt:433-477`): `metadata(coordinate)` →
  `ReportUtils.encodingWithMetadata` → `columnListingAction.cachedHeaderListing(dataLocation,
  coordinate)` else `classLoaderHandle(setOf(coordinate), ClassLoaderUtils
  .dynamicParentClassLoader()).use { define(...); columnListingAction.headerListing(
  FlatDataHeaderDefinition(...), coordinate) }`.
- `ColumnListingAction` (`server/objects/report/service/ColumnListingAction.kt`): disk-cached
  (`columns.csv` under `filterIndex.inputIndexPath(dataLocation, coordinate)`) `HeaderListing`
  per (file, coordinate) — `cachedHeaderListing` :49-56, cache-writing `headerListing` :59-93.
- `ReportUtils` (`server/objects/report/service/ReportUtils.kt:10-41`): **premise correction —
  there is no charset *detection* anywhere in it.** `encoding(...)` resolves the plugin
  metadata's *declared* `DataEncodingSpec` (or null without metadata);
  `TextEncodingSpec.getOrDefault()` = UTF-8 (`TextEncodingSpec.kt:18-20`). The constituent
  plan's "blank = detect via ReportUtils" therefore means: blank `encoding` = the
  ReportUtils-style default resolution — plugin-declared encoding for `PluginReaderWorker`,
  plain UTF-8 for the native readers (their current behaviour). Spelled out in steps 1/4.

### C. Post-SER5 REST pattern (anchor drift — re-derived)

- The constituent plan's "`jobDownload` pattern, RestHandler.kt:1142-1164" has moved
  (`jobDownload` now at RestHandler.kt:1220, route at KzenAutoMain.kt:735-744) **and is the
  wrong precedent anyway** — it's a raw-bytes download. The right precedent is the
  **document-agnostic `/file-listing` route that already landed** (SER3 listFiles DTO work):
  - Constant + params: `CommonRestApi.fileListing` / `paramDirectory` / `paramFilter`
    (`CommonRestApi.kt:139-143`).
  - Handler: `RestHandler.fileListing(parameters): List<DataLocationInfo>`
    (`RestHandler.kt:967-981`) — `getParam`/`getParamOrNull` helpers at :1398-1424,
    `runBlocking` around suspend service calls.
  - Route: `routeFileListing` (`KzenAutoMain.kt:251-257`) — `get(...) {
    call.respondJson(restHandler.fileListing(call.parameters)) }`; installed at
    `KzenAutoMain.kt:210`. `respondJson` pre-encodes with the stock `serverJson`
    (`KzenAutoMain.kt:215-231`) — **kept deliberately over `call.respond(dto)` for
    buffered/gzip-clean output (SER5 as-built); use it, don't bypass it.**
  - Wire DTO: `@Serializable` commonMain class — `DataLocationInfo`
    (`common/util/data/DataLocationInfo.kt:22-29`; note its file-top comment on the dual
    wire/value-tree planes and the no-defaults `init`-check caveat). Long/number rule
    (architecture.md § 3): plain JSON numbers for domain-bounded values.
  - Client: `ClientRestApi.listFiles` (`ClientRestApi.kt:808-820`) —
    `clientJson.decodeFromString(getOrPut(...))`.
  - New wire DTOs get a round-trip pin in `WireDtoSerializerTest`
    (`kzen-auto-common/src/commonTest/kotlin/tech/kzen/auto/common/serialization/`).
- **`MultiFileInputEditor` browse wiring: verified, nothing to do.** It already browses via
  `restClient.listFiles` against `/file-listing` (`MultiFileInputEditor.kt:79-94` kdoc,
  Wrapper `@Service restClient: ClientRestApi` :103-120) — so the constituent plan's
  "`FileListingAction` … what moves is the REST/action routing" is **already landed for the
  file-browse half**. Step 2 rescopes to the **column pre-scan route only**.
- `RestHandler` construction: `KzenAutoContext.kt:195-206` (it already receives
  `fileListingAction`; it does **not** yet receive `columnListingAction` or
  `definitionRepository`).

### D. Job readers + worker framework

- `CsvReaderWorker` (`server/objects/job/worker/CsvReaderWorker.kt`): ctor `(output, path,
  delimiter, header, selfLocation)` :36-44; opens via
  `CsvRecordReader(Files.newBufferedReader(toFilePath(path)), delimiter)` — **platform-default
  UTF-8, no charset parameter — at :91**; migration `ReaderState` :165-178 with config-changed
  guard `state.path == path && state.delimiter == delimiter && state.header == header` :141;
  progress `mapOf("read" to count)` :158-159.
- `MultiFileReaderWorker` (`.../MultiFileReaderWorker.kt`): ctor `(output, paths, delimiter,
  header, selfLocation)` :40-48; open at :105-107; guard `state.paths == paths && …` :163;
  `ReaderState` :188-203.
- Framework: `SourceWorker.drive` = leading checkpoint + `produce(emitter, control)` + flush +
  close-output (`SourceWorker.kt:30-43`); `Emitter.sourceCadence` auto-flushes / checkpoints /
  publishes every `output.batchSize()` sends (`Emitter.kt:32-50`) — **a reader only emits;
  one step ≈ one batch is preserved by construction**. `WorkerBase.captureMigrationState`
  default null = restart-on-migrate (`WorkerBase.kt:85-102`). `JobControl` surface:
  `checkpoint` / `runBlockingIo` / `scratchDir` / `outputDir` / `publishProgress` / `host`
  (`common/paradigm/job/control/JobControl.kt:12-85`).
- Archetypes (`notation/auto-jvm/job/job-worker.yaml`): `CsvReaderWorker` :16-36,
  `MultiFileReaderWorker` :48-71 (`paths` carries `editor: MultiFileInputEditor` :63-66 —
  the editor is generic over any List-of-String attribute, reusable by `PluginReaderWorker`
  as-is). Body defaults present for every attribute (the palette-insert gotcha). Ribbon tools in
  `notation/auto-js/document/job-js.yaml` — Sources group :134-155 (`CsvReaderTool` :140-143 is
  the template). `Worker` base archetype + `display:` marker in
  `notation/auto-common/common-job.yaml:8-27`; `Channel`/`DataRecord` type objects in
  `notation/auto-jvm/job/job-jvm.yaml` (DataRecord :58-60).
- Notation-level test harness: `JobNotationTest` (`server/exec/job/JobNotationTest.kt`) —
  `KzenAutoContext.forTest()` + `AutoTestUtils.readNotation()` + `JobLogicCompiler.compile` +
  `RunEngine` (:122-143); fixtures under `src/test/resources/notation/test/`, relative
  `build/...` file paths shared between test and Workers (:38-45). Direct-instantiation worker
  test harness: `MultiFileReaderWorkerTest` (`capturingOutput` :171-179, `NoOpJobControl`
  :184-192).

### E. Client editor state

- `JobUpstreamSchema` — **location drift**: it lives at
  `kzen-auto-js/.../objects/document/job/edit/JobUpstreamSchema.kt` (not `job/`). Today it is
  summary-only: `nearestUpstreamSummaryWorker` walks `JobChannelDerivation.derive(...)
  .connections` upstream and returns the first worker whose capability is
  `JobServeCapability.Capability.Summary` (:17-34).
- `JobServeCapability` (kzen-auto-common `objects/document/job/JobServeCapability.kt:34-64`) is
  the capability-classifier pattern to copy: per-attribute metadata (`attributeMetadata
  .attributeMetadataNotation.map[...]`) + inheritance-chain walk; JVM-tested
  (`kzen-auto-jvm/src/test/.../common/objects/document/job/JobServeCapabilityTest.kt`).
  Attribute metadata provably carries arbitrary extra keys (`editor:`, `creator:`, `summary:`,
  `multiline:`) — a new `scan:` key rides the same mechanism.
- `SortSpecEditor` (`.../job/edit/SortSpecEditor.kt`) — the constituent plan's ":71-73
  free-text fallback" anchor still holds approximately: the kdoc note "free-text entry, the
  documented fallback until upstream-schema threading lands (P4i JobController schema plumbing)"
  is at :70-73; the free-text add field is `renderAddName` :361-388; adds commit
  `HeaderLabel(name, 0)` via `SortSpec.addCommand` (:209-221, :168-173). Wrapper (`@Service
  clientStateGlobal + mirroredGraphStore`) :82-97; props are the shared `AttributeEditorProps`
  (`common/attribute/AttributeEditorProps.kt:10-16` — no restClient; extend per-editor as
  `MultiFileInputEditorProps` does, `MultiFileInputEditor.kt:55-61`).
- The dropdown pattern to mirror: `ValueSetFilterEditor.renderColumnAdd` uses
  `muiAutocompleteField(label, options, onSelect, …)` over `SelectOption`s labelled
  `HeaderLabel.render()` (`ValueSetFilterEditor.kt:379-398`), with a separate free-text branch
  when no summary is live. Its summary source is `JobSummaryStore` via the DocumentBridge
  (`JobSummaryStore.kt:8-29`) — live-run only.
- `ClientRestApi` client json: `clientJson` in `client/util/ajaxUtil.kt`; call pattern
  `ClientRestApi.kt:812-820`.

### F. Premise corrections / drift summary

| Constituent-plan premise | Reality (2026-07-19) | Consequence |
|---|---|---|
| "the same pattern jobDownload used, RestHandler.kt:1142-1164" | SER4/SER5 reshaped RestHandler; `/file-listing` (typed DTO + respondJson) is the live precedent | Step 2 follows § C |
| Design-time actions need extraction "so a Job document can invoke them" | File-browse half already extracted + consumed by `MultiFileInputEditor` | Step 2 = column pre-scan only |
| "drives the plugin's framer + steps synchronously in a plain loop" (to be built) | `ReportInputChain` already is that driver | Step 1 composes, doesn't build |
| "blank = detect via ReportUtils" | ReportUtils resolves declared encodings; no detection exists | blank = declared/UTF-8 default (steps 1, 4) |
| `ReportDefinitionRepository` "already in the graph environment" (check) | Confirmed, KzenAutoContext.kt:226 | `@Service` injection as planned |
| SortSpecEditor.kt:71-73 | Now the :70-73 kdoc note + :361-388 free-text field | Step 3 |
| JobUpstreamSchema.kt:19-33 | Moved to `job/edit/`, same shape | Step 3 |

## Pre-resolved questions

1. **Payload-type generality**: `PluginReaderWorker` emits from `ModelOutputEvent.row` (always a
   `FlatFileRecord`, filled by every terminal step — § A) and skips `event.skip` events. Works
   identically for `FlatFileRecord` definers (CSV/TSV/Text) and custom-payload definers
   (sample plugin's `WcpRow`). The typed payload `model` is not consumed — Job's record lane is
   `DataRecord`; that is the subsumption contract, not a loss.
2. **Header resolution**: a separate bounded pre-pass via `ReportHeaderReader().extract(
   FlatDataHeaderDefinition(...))` over the **first** file (opens its own chain, closes —
   exactly Report's `datasetInfo` behaviour). The resulting `HeaderListing` is shared by every
   emitted `DataRecord` (same as the native readers). Multi-file: subsequent files run fresh
   chains; the definer's own skip semantics (CSV marks each file's first record skip) handle
   per-file header rows — no header=true/false attribute on this worker (the plugin owns header
   semantics).
3. **Worker config surface** (per plan: "file path(s) + PluginCoordinate + optional charset"):
   `paths: List<String>` (reuses `MultiFileInputEditor`), `coordinate: String` (plugin
   coordinate name, e.g. "CSV"; plain-text edited v1 — a coordinate dropdown needs a
   list-metadata route, noted as follow-up), `encoding: String` (blank = plugin-declared
   encoding; else `Charset.forName`).
4. **ClassLoader lifetime**: the handle opens once per run inside `produce` and closes in
   `onClose` — the plugin classes execute for the whole stream, so a `.use{}` around resolution
   only would be wrong. On migrate teardown `onClose` closes it; the rebuilt instance opens a
   fresh one (consistent with restart-on-edit). Repository calls wrap in
   `control.runBlockingIo { }` (§ B).
5. **Migration v1 = restart on edit** (`WorkerBase` default — capture returns null). Kdoc must
   state both halves: framers/segment steps are stateful so positional resume is a follow-up,
   and an unchanged-config live-edit resume restarts the stream from the top (rows already
   carried in channel buffers can be duplicated downstream) — mirror the honesty of the
   compressed-export restart caveat. Do not build skip-N resume now.
6. **Column pre-scan route shape**: GET `/column-listing?input=<file>&coordinate=<name>&
   encoding=<charset>`, `coordinate`/`encoding` optional. Missing coordinate → resolve by
   payload type `FlatFileRecord` + extension via `ReportDefinitionRepository.find` (the same
   default Report's `actionDefaultFormat` uses). Cache: reuse `ColumnListingAction`'s
   columns.csv cache for the no-encoding-override path; an explicit `encoding` override
   **bypasses the cache both ways** (reads via `ReportHeaderReader` directly) so it can neither
   read nor pollute the (file, coordinate)-keyed cache.
7. **Reader-config discovery is a notation capability marker**: a new attribute-metadata key
   `scan:` — `scan: files` on the attribute holding input path(s) (scalar or list),
   `scan: coordinate` / `scan: encoding` on the attributes holding those values (only
   `PluginReaderWorker` has them). A general-layer walk reads only the marker + attribute
   values; no worker-type names anywhere. No `scan: coordinate` attribute ⇒ the pre-scan sends
   no coordinate and the server resolves by extension — so `CsvReaderWorker` /
   `MultiFileReaderWorker` need only `scan: files`. Known accepted v1 gaps, documented not
   solved: a native reader with a non-default `delimiter` may mis-scan (dropdown is assistive;
   free text remains), and formula-added columns between reader and consumer are invisible to
   the pre-scan (the live-summary tier sees them).
8. **Fallback chain owner**: the *classifier* (`scan:` reader) goes in kzen-auto-common beside
   `JobServeCapability` (JVM-testable, shared so client and any future server consumer cannot
   drift); the *walk + chain composition* stays in the JS `JobUpstreamSchema` (existing
   pattern). Chain in the editor: live upstream summary (if any) → pre-scanned header (REST) →
   free text.
9. **Native-reader `encoding` semantics**: blank = UTF-8 exactly as today
   (`Files.newBufferedReader(path)` default) — behaviour-preserving; non-blank =
   `Files.newBufferedReader(path, Charset.forName(encoding.trim()))`; unknown charset name
   fails the worker at open with the standard failure surface (E7 chip). `encoding` joins the
   config-changed guard and `ReaderState` in both readers. BOM stripping is *not* added (the
   native readers never did it; `FileFlatDataStream` does it for the plugin path) — note in
   kdoc, don't build.
10. **A/B comparison method**: value-equality on `record.toList()` streams + shared
    `HeaderListing` equality, direct-instantiation harness (capturing `ChannelOutput` +
    `NoOpJobControl`), per `MultiFileReaderWorkerTest`. Byte-level identity is meaningless at
    this seam (both sides emit parsed `FlatFileRecord`s; bytes reappear at export, which is
    J4's composed gate).

## Step-by-step implementation

### Step 1 — `PluginReaderWorker` (server + notation)

**1a. New class** `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/PluginReaderWorker.kt`:

```kotlin
@Reflect
class PluginReaderWorker(
    output: ChannelOutput<Any?>,
    private val paths: List<String>,
    private val coordinate: String,
    private val encoding: String,
    selfLocation: ObjectLocation,
    @Service private val definitionRepository: ReportDefinitionRepository
):
    SourceWorker<DataRecord>(output, selfLocation)
```

Fields: `classLoaderHandle: ClassLoaderHandle?`, `openChain: ReportInputChain<*>?`,
`count: Long`, plus a small `finished` flag mirroring `CsvReaderWorker` (a resumed-after-EOF
instance emits nothing; without carry this only matters for the no-edit resume path — keep it
for symmetry).

`produce(emit, control)` outline (all repository/file calls through `control.runBlockingIo`):
1. Validate config: `coordinate.isNotBlank()` and `paths.isNotEmpty()`, else
   `error("...")` (standard worker-failure surface).
2. `val pluginCoordinate = PluginCoordinate(coordinate.trim())`;
   `metadata = definitionRepository.metadata(pluginCoordinate) ?: error("Unknown format: ...")`.
3. Resolve `DataEncodingSpec`: blank `encoding` → `metadata.reportDefinitionInfo.dataEncoding`;
   else `DataEncodingSpec(TextEncodingSpec(Charset.forName(encoding.trim())))`.
4. Open `classLoaderHandle = definitionRepository.classLoaderHandle(setOf(pluginCoordinate),
   ClassLoaderUtils.dynamicParentClassLoader())` (field; closed in `onClose`);
   `definition = definitionRepository.define(pluginCoordinate, handle)` (star-projected —
   one `@Suppress("UNCHECKED_CAST")` to `ReportDefinition<Any>` at the seam, same dance as
   `ReportDocument.datasetInfo`).
5. Header pre-pass over `paths.first()`: build
   `FlatDataHeaderDefinition(FlatDataLocation(dataLocation(paths.first()), dataEncoding),
   FileFlatDataSource(), definition)` → `ReportHeaderReader().extract(...)` → shared
   `HeaderListing`. (`dataLocation(path)` helper:
   `DataLocation.ofFile(FilePath.of(toFilePath(path).toAbsolutePath().normalize().toString()))`
   — reuse `toFilePath` from `WorkerFilePath.kt` for quote-stripping.)
6. Per path, in order: open `chain = flatDataHeaderDefinition-for-this-path.openInputChain(
   DataBlockBuffer.defaultBytesSize)` (or construct `ReportInputChain` directly over
   `FileFlatDataSource().open(...)` — equivalent; prefer `openInputChain` for one code path),
   store in `openChain`; loop:
   ```kotlin
   val batch = ArrayList<FlatFileRecord>()
   val hasNext = control.runBlockingIo {
       chain.poll { event -> if (!event.skip) batch.add(event.row.prototype()) }
   }
   for (record in batch) {
       emit.send(DataRecord(header, record))     // Emitter cadence: flush/checkpoint/publish
       count += 1
   }
   if (!hasNext) break
   ```
   then `chain.close()`, `openChain = null`.
7. `finished = true`.

`onClose()`: close `openChain` (if mid-stream teardown) then `classLoaderHandle`.
`progress(snapshot) = mapOf("read" to count)` (mirrors CsvReaderWorker :158-159).
No `captureMigrationState` override (restart default) — kdoc per Pre-resolved 5, plus notes:
gzip + BOM handled by `FileFlatDataStream`; one step ≈ one batch via `Emitter.sourceCadence`.

**1b. Archetype** — append to `job-worker.yaml` (after `MultiFileReaderWorker`, :71):

```yaml
# Reads file(s) through a format plugin (the kzen-auto-plugin ReportDefiner/DataFramer SPI —
# built-in CSV/TSV/Text or a jar-loaded third-party definer), emitting the same DataRecord
# stream the native readers emit. `coordinate` names the plugin (e.g. CSV); `encoding` blank =
# the plugin's declared text encoding. Gzip (.gz) input and BOM handled automatically. Live
# edit RESTARTS the stream (plugin framers are stateful; positional resume is a follow-up).
PluginReaderWorker:
  abstract: true
  is: Worker
  title: "Plugin Reader"
  class: tech.kzen.auto.server.objects.job.worker.PluginReaderWorker
  output: ""
  paths: []
  coordinate: ""
  encoding: ""
  meta:
    output:
      is: ChannelOutput
      of: DataRecord
      creator: JobChannelCreator
      editor: SelectChannelEditor
    paths:
      is: List
      of: String
      editor: MultiFileInputEditor
      scan: files
    coordinate:
      is: String
      scan: coordinate
    encoding:
      is: String
      scan: encoding
    selfLocation:
      is: ObjectLocation
      by: Self
```

Every attribute has an empty-string/empty-list body default (the appendix palette-insert
gotcha). `@Service` params are not notation attributes (no meta entry — precedent
`FormulaWorker`).

**1c. Ribbon tool** — `job-js.yaml`, Sources group (after `MultiFileReaderTool`, :155):
`PluginReaderTool: { is: RibbonTool, parent: JobGroup_Sources, delegate: PluginReaderWorker }`
(in expanded yaml form matching the neighbours, :140-143).

KSP picks up `@Reflect` automatically (src/main). No shared-code edits anywhere — the
extension-rule acceptance for this worker.

### Step 2 — design-time column pre-scan route (server + client plumbing)

**2a. Wire DTO** — new `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/util/data/ColumnListingInfo.kt`:

```kotlin
@Serializable
data class ColumnLabelInfo(val name: String, val occurrence: Int)

@Serializable
data class ColumnListingInfo(val columns: List<ColumnLabelInfo>)
```

(Wire-only, no value-tree twin needed; plain numbers per the architecture.md § 3 Long rule. Add
a round-trip case to `WireDtoSerializerTest` incl. a duplicate-name occurrence>0 fixture.)

**2b. Constants** — `CommonRestApi.kt`, next to the `/file-listing` block (:139-143):

```kotlin
// Column pre-scan of one input file (document-agnostic design-time service) —
// GET /column-listing?input=...&coordinate=...&encoding=... reuses ColumnListingAction +
// ReportDefinitionRepository; coordinate optional (server resolves by extension), encoding
// optional (blank = plugin-declared). Used by the Job spec editors' column dropdowns.
const val columnListing = "/column-listing"
const val paramInputFile = "input"
const val paramPluginCoordinate = "coordinate"
const val paramTextEncoding = "encoding"
```

(NB `paramDocumentName` already claims the wire string `"file"` — hence `"input"`.)

**2c. Handler** — `RestHandler`: add ctor params `columnListingAction: ColumnListingAction` and
`definitionRepository: ReportDefinitionRepository` (imports from
`server/objects/report/service/` + `server/service/plugin/` — classes stay where they are; the
constituent plan moves routing, not packages). New method next to `fileListing` (:967-981):

```kotlin
fun columnListing(parameters: Parameters): ColumnListingInfo {
    val input: String = parameters.getParam(CommonRestApi.paramInputFile) { it }
    val coordinateName: String? = parameters.getParamOrNull(CommonRestApi.paramPluginCoordinate) { it }
    val encodingName: String? = parameters.getParamOrNull(CommonRestApi.paramTextEncoding) { it }

    val dataLocation = DataLocation.of(input)
    val coordinate = coordinateName?.let { PluginCoordinate(it) }
        ?: definitionRepository.find(flatFileRecordType, dataLocation).firstOrNull()?.coordinate
        ?: error("No format found for: $input")
    val metadata = definitionRepository.metadata(coordinate)
        ?: error("Unknown format: ${coordinate.name}")

    val headerListing =
        if (encodingName.isNullOrBlank()) {
            columnListingAction.cachedHeaderListing(dataLocation, coordinate)
                ?: withDefinition(coordinate) { definition ->
                    columnListingAction.headerListing(
                        headerDefinition(dataLocation, metadata.reportDefinitionInfo.dataEncoding, definition),
                        coordinate)
                }
        }
        else {
            // Explicit override: bypass the (file, coordinate)-keyed cache entirely.
            val dataEncoding = DataEncodingSpec(TextEncodingSpec(Charset.forName(encodingName.trim())))
            withDefinition(coordinate) { definition ->
                ReportHeaderReader().extract(headerDefinition(dataLocation, dataEncoding, definition))
            }
        }

    return ColumnListingInfo(headerListing.values.map { ColumnLabelInfo(it.text, it.occurrence) })
}
```

with two private helpers — `withDefinition(coordinate) { ... }` =
`definitionRepository.classLoaderHandle(setOf(coordinate),
ClassLoaderUtils.dynamicParentClassLoader()).use { handle ->
block(definitionRepository.define(coordinate, handle)) }`, and `headerDefinition(...)` =
`FlatDataHeaderDefinition(FlatDataLocation(dataLocation, dataEncoding), FileFlatDataSource(),
definition)` — mirroring `ReportDocument.datasetInfo` :450-470. `flatFileRecordType =
ClassName("tech.kzen.auto.plugin.model.record.FlatFileRecord")` (the same FQN
`common-document.yaml:222` pins as Report's default dataType). Failures propagate as HTTP
errors; the client degrades (2e / 3d).

**2d. Route + wiring** — `KzenAutoMain.routeFileListing` (:251-257) gains
`get(CommonRestApi.columnListing) { call.respondJson(restHandler.columnListing(call.parameters)) }`
(update the fn's doc comment to "file-system design-time services");
`KzenAutoContext` passes `columnListingAction` + `definitionRepository` into the `RestHandler`
constructor (:195-206). (`KzenAutoContext.forTest()` flows through the same construction —
compile catches any second site.)

**2e. Client** — `ClientRestApi`, next to `listFiles` (:808-820):

```kotlin
suspend fun listColumns(inputFile: String, coordinate: String?, encoding: String?): ColumnListingInfo
```

building the param list conditionally and `clientJson.decodeFromString`-ing the response.

### Step 3 — `JobUpstreamSchema` fallback + `SortSpecEditor` dropdown (client)

**3a. Capability classifier** — new
`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/job/JobScanCapability.kt`,
modeled line-for-line on `JobServeCapability` (:34-64): for a worker location, iterate
`objectMetadata.attributes.map`; an attribute whose `attributeMetadataNotation.map` carries
`AttributeSegment.ofKey("scan")` with value `files` / `coordinate` / `encoding` fills the
corresponding slot of

```kotlin
data class ScanSource(
    val filesAttribute: AttributeName,
    val coordinateAttribute: AttributeName?,
    val encodingAttribute: AttributeName?)

fun of(graphStructure: GraphStructure, workerLocation: ObjectLocation): ScanSource?  // null when no scan: files
```

Add a companion value-reader (also here, so JVM tests pin it):
`fun scanConfig(graphNotation, workerLocation, scanSource): ScanConfig?` — reads
`graphNotation.firstAttribute(workerLocation, attr)`; `files` accepts a
`ScalarAttributeNotation` (single path) or `ListAttributeNotation` of scalars (list); blank/empty
→ null; `ScanConfig(files: List<String>, coordinate: String?, encoding: String?)` with
blank-collapsed-to-null coordinate/encoding.

**3b. Walk** — `JobUpstreamSchema` (js, `job/edit/JobUpstreamSchema.kt`) gains
`nearestUpstreamScanConfig(graphStructure, from): ScanConfig?` — same `upstreamOf` walk as
`nearestUpstreamSummaryWorker` (:18-33), returning the first non-null
`JobScanCapability.of(...)?.let { JobScanCapability.scanConfig(...) }`. (Also check `from`'s own
scan source first, so a future reader-side consumer works; harmless for sort/filter/pivot which
are never scan sources.)

**3c. Native readers opt in** — job-worker.yaml: expand `CsvReaderWorker`'s `path: String`
(:31) to `path: { is: String, scan: files }` (expanded yaml form) and `MultiFileReaderWorker`'s
`paths` meta (:63-66) gains `scan: files`. (`PluginReaderWorker` already carries all three
markers from step 1b. No `scan: coordinate` on the native readers — extension-resolved default,
Pre-resolved 7.) After step 4, add `scan: encoding` to both native readers' new `encoding`
attributes.

**3d. `SortSpecEditor` dropdown** — smallest change honoring existing shapes:
- Own props interface `SortSpecEditorProps : AttributeEditorProps { var restClient:
  ClientRestApi }`; Wrapper gains `@Service restClient` (mirror `MultiFileInputEditor.kt:103-120`).
- New state: `candidateColumns: List<HeaderLabel>?` + a private `scanKey: String?` memo.
- On mount and on every `refreshColumns` (:151-163) pass: derive
  `JobUpstreamSchema.nearestUpstreamScanConfig(...)`; compute key =
  `files.first() + "|" + coordinate + "|" + encoding`; if changed, `async { restClient
  .listColumns(...) }` → `setState { candidateColumns = info.columns.map {
  HeaderLabel(it.name, it.occurrence) } }`; on any failure or null config →
  `candidateColumns = null` (free-text fallback). One small GET per reader-config change; no
  debounce needed.
- `renderAddName` (:361-388): when `candidateColumns` is non-null render
  `muiAutocompleteField` over options labelled `HeaderLabel.render()` (excluding
  already-added keys), `onSelect` → `applyAdd(headerLabel)` (committing the real occurrence —
  fixing the occurrence-0-only limitation noted at :237-242 for scanned columns); when null
  keep the existing TextField path unchanged. Mirror `ValueSetFilterEditor.kt:379-398`.
- Retire the stale ":70-73 free-text apology" kdoc (it names this exact threading as the
  pending work).
- **Live-summary tier for SortSpecEditor (optional, time-permitting)**: observe
  `JobSummaryStore` via DocumentBridge exactly as `ValueSetFilterEditor` does (:127-150) and
  prefer live summary columns (includes formula-added ones) over the pre-scan. Skip cleanly if
  the session runs long — the pre-scan tier alone satisfies the phase goal.
- **ValueSetFilter/Pivot column-name adoption of the pre-scan**: out of scope here (their
  free-text add works; J8.4 dedupes the family) — note only.

### Step 4 — `encoding` on the native readers (server + notation)

- `CsvReaderWorker`: ctor gains `private val encoding: String` (after `header`); `ensureOpen`
  (:91) becomes `CsvRecordReader(Files.newBufferedReader(toFilePath(path), charset()), delimiter)`
  with `private fun charset(): Charset = if (encoding.isBlank()) StandardCharsets.UTF_8 else
  Charset.forName(encoding.trim())`; `ReaderState` (:165-178) gains `encoding`; the guard
  (:141) adds `state.encoding == encoding`. Same treatment for `MultiFileReaderWorker`
  (open :105-107, guard :163, `ReaderState` :188-203).
- job-worker.yaml: both archetypes gain body default `encoding: ""` + meta
  `encoding: { is: String, scan: encoding }` (expanded form; see 3c).
- Update both workers' kdoc STATE MIGRATION lists ("path / delimiter / header" →
  "+ encoding") and the archetype comments; note BOM non-handling (Pre-resolved 9).
- Existing user documents and test fixtures inherit `encoding: ""` from the archetype — no
  instance edits, no compat shim. (KSP regenerates the ModuleReflection ctor signature
  automatically.)

**Split point if the session can't fit everything**: Step 1 + Step 4 (+ their tests) are a
self-contained server-side session ("pluggable formats + charset"); Steps 2 + 3 (+ editor smoke)
are a self-contained design-time-services session. Step 2 has no dependency on Step 1 except
the `scan:` markers (1b) landing with whichever session runs first.

## Tests

All in kzen-auto-jvm `src/test` unless noted; new fakes copy `NoOpJobControl` /
`capturingOutput` from `MultiFileReaderWorkerTest.kt:171-192` (watch the J2 adaptation note).

1. **`PluginReaderWorkerTest`** (new, `server/objects/job/worker/`) — direct instantiation with
   `HostReportDefinitionRepository(listOf(CsvReportDefiner(), TsvReportDefiner(),
   TextReportDefiner()))` (mirrors `KzenAutoContext.kt:153-156`; the `@Service` param passed by
   hand):
   - **`abParityWithCsvReaderWorker` (the phase's A/B gate)**: one temp CSV exercising RFC-4180
     edge cases (quoted field, embedded delimiter, embedded newline, doubled quotes, non-ASCII
     UTF-8 text) + a plain wide file; run `CsvReaderWorker(path, ",", header=true)` and
     `PluginReaderWorker([path], "CSV", "")` to completion; assert **identical**
     `map { it.record.toList() }` streams and equal `HeaderListing` on every record.
   - **`abParityMultiFile`**: two headered CSVs through `MultiFileReaderWorker` vs
     `PluginReaderWorker` — asserts concatenation order + subsequent-file header-row skipping
     agree (CSV definer skips each file's first record via `FlatPipelineHandoff(skipFirst)`).
   - **`tsvCoordinate`**: a `.tsv` file through `PluginReaderWorker([f], "TSV", "")` splits on
     tabs.
   - **`encodingOverride`**: an ISO-8859-1 file (e.g. `Zürich` content written with
     `Charsets.ISO_8859_1`) read with `encoding = "ISO-8859-1"` yields correct text; with blank
     encoding yields a different (mojibake) stream — assert the difference, proving the
     override is live.
   - **`gzipTransparent`**: `file.csv.gz` yields the same records as the plain file.
   - **`unknownCoordinateFails`** / **`blankConfigFails`**: clear failures (assertFailsWith).
2. **`JobPluginReaderNotationTest`** (new, `server/exec/job/`, modeled on
   `JobNotationTest.kt:122-143`) + fixture
   `src/test/resources/notation/test/job-plugin-reader-test.yaml`: `main: {is: Job}` with
   `PluginReaderWorker(paths=[build/job-plugin-reader/input.csv], coordinate: CSV)` →
   `CsvWriterWorker` (blank ports, order-derived channel); run on the engine to
   `Outcome.Success`; output file equals input data. **This is what proves the archetype
   definition, the `@Service ReportDefinitionRepository` injection through the real
   graph-environment path, and channel synthesis** — the direct test can't.
3. **`ReaderEncodingTest`** (new, `server/objects/job/worker/`) for step 4: CsvReaderWorker +
   MultiFileReaderWorker each read an ISO-8859-1 file correctly with `encoding="ISO-8859-1"`;
   blank keeps UTF-8 behaviour (stream unchanged for a UTF-8 file); a migration capture/load
   with **changed** encoding closes the carried reader and restarts (assert re-read from top —
   mirror `carriesFileCursorAcrossLiveEdit...`, `MultiFileReaderWorkerTest.kt:96-148`), while
   unchanged encoding still resumes mid-file.
4. **`RestHandler` column-listing coverage** — a focused test constructing
   `KzenAutoContext.forTest()` and calling `restHandler.columnListing(parametersOf(...))` for:
   explicit CSV coordinate; coordinate omitted on a `.csv` (extension default); explicit
   `encoding` override on a Latin-1 file; duplicate column names → occurrence 1 in the DTO.
5. **`JobScanCapabilityTest`** (new, `kzen-auto-jvm/src/test/.../common/objects/document/job/`,
   beside `JobServeCapabilityTest`): asserts `of()` finds `scan: files` on scalar-`path` and
   list-`paths` attributes, coordinate/encoding slots only on PluginReaderWorker, null for a
   non-reader worker; and `scanConfig` value extraction (scalar vs list, blank → null).
6. **`WireDtoSerializerTest`** (kzen-auto-common commonTest): `ColumnListingInfo` round-trip
   (runs under ChromeHeadless too — pins JS decode).
7. **Report suites untouched-and-green**: no Report source file changes at all in this phase
   (RestHandler / KzenAutoMain / CommonRestApi / KzenAutoContext are shared plumbing, not
   Report's); full `:kzen-auto-jvm:test` is the proof.

## Verification

1. `./gradlew :kzen-auto-jvm:test` — new suites + the whole `exec/job` + `objects/job` +
   report nets green.
2. `./gradlew :kzen-auto-common:jvmTest :kzen-auto-common:jsTest` (WireDtoSerializerTest both
   planes) and `./gradlew :kzen-auto-js:compileKotlinJs` (client compiles).
3. **Editor smoke** (dev loop, `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`):
   - Sample Job: insert a Plugin Reader from the Sources ribbon (palette-insert produces a
     well-formed card — the empty-string-defaults gotcha check), browse-pick a CSV via the
     paths editor, type coordinate `CSV`, run → Preview/Explore show rows.
   - Sort card: with a reader upstream (fresh document, **no run started**), the add-sort-key
     field offers the file's columns in a dropdown; with a blank-path reader it degrades to
     free text. `curl "localhost:<port>/column-listing?input=<file>"` returns the typed JSON.
   - CsvReader card: set `encoding` to `ISO-8859-1` over a Latin-1 file → correct characters in
     Preview.
   - If the session is headless, record these three as manual smoke debt in the master plan's
     smoke-debt list (house precedent: TP/SER phases).
4. **kzen-sample-plugin manual check** (read-only repo — the verification target, never edited):
   build/obtain its jar, upload via a Plugin document, then a Job with
   `PluginReaderWorker(coordinate: "World Cities Population (worldcitiespop)")` over a
   worldcitiespop-format file (ISO-8859-1 — the definer declares it,
   `WorldCitiesPopProcessorDefiner.java:28-35`; blank `encoding` must pick it up automatically)
   streams rows into a Preview. Proves the third-party path end-to-end with zero kzen-source
   edits. (If no wcp data file is at hand, a 3-line hand-written file in its column shape
   suffices.)
5. Tick Phase 3 in `2026-07-16_job-improvements.md`'s tracker + as-built note; strike J3 in the
   master plan. Docs sync per ground rules: the `/column-listing` contract is documented at its
   `CommonRestApi` constants (2b), matching how `/file-listing` is documented; architecture.md's
   § 3 route table enumerates groups, not these listing routes — no table edit required.
   `PluginReaderWorker` prose in architecture.md waits for J4's parity-checklist § Job write-up.

## Risks & gotchas

- **`runBlocking` inside repository calls** (`PluginReportDefinitionRepository` :46-48,
  :180-182, :216-218): from a Worker coroutine these must run inside `control.runBlockingIo`,
  which parks an IO-counted thread — quiescence stays honest, but a deadlock against the
  engine dispatcher is conceivable if the store callback ever hops dispatchers. The
  notation-level test (Tests 2) is the canary; if it wedges, resolve the definition in
  `onStart` via the same `runBlockingIo` and re-check (same contract, earlier timing).
- **Skip semantics are per-definer**: the driver must filter `event.skip` (CSV's header row) —
  forgetting it shifts the A/B by one row (the A/B test catches it). Conversely Text/literal
  header extractors emit no skip rows — don't special-case anything.
- **Event-object reuse**: never retain `event.row` — always `prototype()` out (Job's
  ownership-transfer contract, `DataRecord.kt:20-23`). A retained reference aliases every
  subsequent record in the block (manifests as "all rows identical to the last").
- **Palette-insert gotcha** (J-plan appendix): every new archetype attribute needs a body
  default (`output: ""`, `paths: []`, `coordinate: ""`, `encoding: ""`). Never touch the
  `Channel` / `DuplexChannel` archetypes.
- **`scan:` metadata key**: additive and inert to `NotationMetadataReader` (like `editor:` /
  `summary:`), but keep it inside `meta:` only — it must not become a notation *attribute*
  (no definer exists for it).
- **Cache staleness**: columns.csv is keyed (file, coordinate) and never invalidated on file
  edit (Report-inherited behaviour; deletable via the storage manager's FilterIndex area). The
  encoding-override path bypasses it (Pre-resolved 6) — don't "improve" it into the cache.
- **`FlatFileRecord` A/B nuance**: `CsvRecordReader` (Job-native) and the definer's
  `CsvPipelineLexer`/`CsvPipelineParser` are independent RFC-4180 implementations — the A/B
  test exists precisely because they could disagree on an edge. A disagreement is a finding,
  not a test bug; fix direction = whichever side is RFC-wrong, in its own follow-up if
  non-trivial.
- **RestHandler ctor change** fans into `KzenAutoContext` only (single construction site,
  :195-206); compile catches any other.
- **J2 parallel-landing**: see Dependencies — `JobControl` test fakes and the two yaml
  insertion points are the only expected merge friction.
- **SortSpecEditor observer rules**: keep the `objectLocation !in graphNotation.coalesce`
  guard (:152-155) intact when adding the scan-key recompute, and don't call the REST fetch
  synchronously inside `onCommandSuccess` — derive the key, then `async { }` (the
  js-architecture § 2 observer rules).

## Out of scope (this phase)

- Grouped export / `${group}`, offline summary persistence, post-run Explore, parity checklist,
  Report freeze — **J4**.
- Positional/skip-N resume for `PluginReaderWorker`; file-backed writer/pivot/explore carry —
  **J9** (kdoc note only here).
- Coordinate dropdown editor (needs a coordinate-list route) and plugin-coordinate validation
  UI — follow-up; record in the as-built note.
- ValueSetFilter/Pivot adopting the pre-scan for column names; editor-family dedupe — **J8.4**
  (after AE3+AE5).
- BOM handling / charset *sniffing* in the native readers (no detection exists anywhere;
  Pre-resolved 9).
- Any Report-side change (its Detached actions, `ReportDocument`, pipeline) — explicitly
  untouched; its suites are the regression net.
- Package moves of `FileListingAction` / `ColumnListingAction` (constituent plan: routing
  moves, classes stay).
