# DS2 — the suspend runtime: `DataSource` / `DataOpener` / `DataCursor` / `DataContext`, `FileDataSource` + `FileDataOpener`, `DataSourceActions` — implementation plan

> **Status: ready to execute.** Session 2 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md) **§4**
> (the SPI; why `resolve` / `open` are suspend and a cursor is not; the source/opener split; the generic
> action), §3.3 (file refs are plain — `DataSourceId` deferred), §4.1 (third-party loading), §4.2 (axes),
> §6.2 (fingerprint + cost discipline), §6.5 (where a source lives), §9 (Report parity), §10 (package
> layering). Constituent plan: **—**
> (analysis doc is the record; delete this file on landing, as-built note → analysis **§13**). Depends on
> **DS0** and **DS1**. Anchors verified 2026-08-21.
> Sized **M–L**; kzen-auto-common (API) + kzen-auto-jvm (implementation, generic action, notation, one
> package move) + fixtures. Ledger row 52.
>
> ⚠ **Start with the O14 spike** (below), **including the delete case**. One structural decision in DS3
> rests on it, and it is fifteen minutes.

## Scope & goal

1. **The SPI** (commonMain, `common/data/api/`): `DataSource`, `DataOpener`, `DataCursor`, `DataContext`
   — verbatim in Pre-resolved 1.
2. **`FileDataSource`** (jvm, `@Reflect` notation object, **`DataSource` only**): Report's `InputSpec`
   shape lifted onto an object — directory + filter, explicit file selection with per-file format /
   encoding, default format / encoding, a group pattern whose named captures become unit attributes, and
   `missing: skip | fail`. `resolve()` walks / lists, stamps each ref's fingerprint (`size`, `modified`),
   stamps the effective format / encoding onto each part where the source knows them, and returns
   `DataResolveResult` with `skipped` diagnostics.
3. **`FileDataOpener`** (jvm, a plain class behind a `@Service`-injectable handle — not a notation
   object): opens **any plain ref** — coordinate = `part.format ?: infer by extension`; charset =
   `part.encoding ?: definer default / detect` — through the **existing** byte-stream seam
   (`FileFlatDataSource`) and **existing** format-plugin SPI (`ReportDefiner` via
   `ReportDefinitionRepository`, driven by `ReportInputChain`) into a `DataCursor` whose `shape` is
   `Tabular(header)`. A third-party format works in a Job with zero new code, closing J3a's goal.
   `staticShape` / `inspectShape` return null in this session (DS6 fills them).
4. **`DataOpenerLookup`** (jvm): `ref.source == null` → `FileDataOpener`; `ref.source != null` → a
   clear `IllegalStateException` ("provider-bound refs are not supported yet: <id>") — the one place the
   dispatch lives, and the one place O15's deferral is visible in code.
5. **`DataSourceActions`** (jvm `@Reflect` `DetachedAction`, one object): `source=<location>`,
   `action=resolve` → instantiate the named source from the full graph (`GraphInstanceCache`, the
   `ModelDetachedExecutor` path), build a `DesignDataContext`, call `resolve`, lower the
   `DataResolveResult`. `action=shape` lands in DS6 on the same object.
6. **The Job `sources:` branch + `DataSourceConventions`** — graph-wide discovery by capability (the
   `Contexts` pattern's *discovery* half; the `DataSources` *document* is deferred, O21).
7. **Package move:** the input plumbing out of `server/objects/report/…` into `server/data/…` (§10).

After this session nothing user-facing changes yet.

## Dependencies & coordination

- **DS0 landed** — `common/data/schema/HeaderListing` + `DataShape` (DS1). **DS1 landed** — the model
  types under `common/data/model/`, including `DataResolveResult` / `DataDiagnostic` and the reserved
  fingerprint keys.
- **DS1b is independent** but should land before DS3; nothing here needs it.
- **DS3** consumes the SPI, `FileDataOpener` / `DataOpenerLookup` and the structural reference; **DS4**
  the generic action, the archetype's attribute metadata and the conventions; **DS5** the opener lookup
  (for `ReadPartWorker`); **DS6** adds `staticShape` / `inspectShape` + `action=shape`; **DS8** adds a
  second `DataSource` that also mints plain refs and reads through the same opener.
- **J3 supersession.** `FileDataOpener.open` *is* J3 Step 1's `PluginReaderWorker` core (the
  synchronous `ReportInputChain` driver over a definer), relocated from a worker into the opener. Read
  `J3_report-subsumption-a.md` § Current-state findings A–B for the verified SPI anchors (definer lookup,
  `ReportInputChain` event reuse, skip semantics) — still accurate — and do **not** build
  `PluginReaderWorker`. `encoding` (J3 step 4) lands as `DataPart.encoding` / `FileDataSource.encoding`
  instead of a reader attribute.
- **`FlatDataSource` name clash.** `FlatDataSource` (byte-stream seam) stays; after the §10 move it
  lives in the *same package* as `FileDataOpener`, which is where the CC-21 reciprocal one-liners ("not
  the same seam as …") read naturally.
- **Dynamic third-party loading** (extension-points §1) is *not* built here, but nothing may assume a
  compiled-in class: every lookup of "what sources exist" is by capability (inheritance chain reaches
  the `DataSource` archetype — the `ContextConventions.isContext` shape, CC-17), never by class name.
- **File safety:** `notation/main/` is the user's — never edited. New archetypes are additive.

## Current-state findings (anchors verified 2026-08-21)

- **`JobControl.runBlockingIo` and `JobControl.host` are both `suspend`**
  (`common/paradigm/job/control/JobControl.kt`): `suspend fun <R> runBlockingIo(block: () -> R): R`
  (offloads through `Execution.blocking` — counted by the `CountingDispatcher`, interruptible by cancel /
  migrate; its KDoc forbids a bare `withContext(Dispatchers.IO)` as "false quiescence") and
  `suspend fun host(instructions, input): TupleValue`. **This is why the SPI is suspend** — a
  non-suspend method has no legal way to call either.
- **`CsvReaderWorker` / `CsvRecordReader` are the cursor precedent.** `CsvRecordReader`'s KDoc: "a plain
  pull reader the Worker drives inside `control.runBlockingIo`, one `readRecord` per blocking unit";
  `CsvReaderWorker.produce` does `control.runBlockingIo { reader.readRecord() }` per record and detaches
  the reader across a migration. **`DataCursor` is that, generalized** (O20).
- **Nullable structural references are supported by kzen-lib.** `GraphCreator.constructionLevels`, on an
  empty `objectReference`, checks `reference.isNullable(objectMetadata)` and — when nullable — contributes
  no edge and records no unsatisfied reference; `GraphDefinitionAttempt` performs the same nullability
  walk in two places; `ObjectDefinitionReference.isNullable` reads `attributeTypeMetadata.nullable`;
  `NotationMetadataReader` reads `nullable` from a map-shaped type notation. **No shipped precedent for
  the combination** (ports use `creator: JobChannelCreator`; `binds` / `contexts` use `by: Nominal`), and
  **a dangling hard reference (target deleted) prunes the host from `transitiveSuccessful`** rather than
  warning. Hence the spike.
- **The run graph already holds every object in the Job document.** `JobLogicCompiler` builds
  `synthesis.graphDefinition.filterTransitive(documentPath)`; `JobRun` calls
  `GraphCreator.createGraph(filteredDefinition, graphEnvironment)` — **the whole filtered definition**,
  not just workers and channels. ⚠ `createGraph` **throws** if *any* object fails to create, so a
  half-configured source in a `sources:` branch fails every run of that Job. Attributes must define when
  blank; `resolve()` fails with a clear message instead.
- **Detached instantiation.** `ModelDetachedExecutor.execute(actionLocation, request)`
  (`…server/service/exec/`) → `actionLookup` builds
  `graphStore.graphDefinition().transitiveSuccessful.filterDefinitions(AutoConventions.serverAllowed)`
  and calls `graphInstanceCache.tryObjectInstance(serverDefinition, location)`. `GraphInstanceCache`
  caches per `(closure digest + inheritance-chain digests, location)`, is `@Synchronized`, bounds at 32
  entries, and **reuses instances only while stateless** — which `FileDataSource` is, and which every
  source must remain (analysis §4: borrow, never own). `serverAllowed` = {`kzen/`, `auto-common/`,
  `auto-jvm/`, `main/`} — a source nested in a user's `main/…Job.yaml` is reachable; one in `test/`
  notation is **not** (the DDC plan's lesson — a detached-route test must drop its fixture into a temp
  `main/`). `DataSourceActions` instantiates the *source* the same way, from inside the action.
- **`Contexts` is the pattern to copy for discovery.** `ContextConventions`:
  **`isContext(graphNotation, location)` = `inheritanceChain(location).drop(1).any { … }`** — the
  `drop(1)` exists precisely so the abstract archetype does not match its own filter — and
  **`allContexts(graphNotation)` = `coalesce.map.keys.mapNotNull { descriptorOrNull(…) }`** (graph-wide).
- **Services into objects.** `@Service` constructor injection (`FormulaSourceWorker`'s
  `CalculatedColumnEval`); registration in `KzenAutoContext` via the graph-environment
  `.put(ClassName(…), instance)`. `GraphInstanceCache`, `graphStore` are already fields of
  `KzenAutoContext`.
- **`FileListingAction.scanInfo(pattern, filter)` is `suspend` and does `withContext(Dispatchers.IO)`
  internally** around `Files.walkFileTree` — so a source must not call it under a run (uncounted
  dispatcher). It yields `DataLocationInfo(path, name, size, modified, dir)` from `BasicFileAttributes`
  — **the fingerprint the resolver stamps (§6.2) is right there.**
- ⚠ **`FileListingAction.parseFilter` is NOT a glob.** It trims, lowercases, splits on whitespace and
  requires the file **name** to contain **every** token (`filterParts.all { name.contains(it) }`). So
  `sales csv` matches `2026-sales.csv` and `*.csv` matches nothing. Do not label it a glob anywhere.
- **`ReportDefinitionRepository` is fully non-suspend** (`contains` / `metadata` / `listMetadata` /
  `classLoaderHandle` / `define` / `find`).
- **Open + parse.** `FileFlatDataSource` opens a `FlatDataLocation(dataLocation, dataEncoding)` into a
  `FlatDataStream`; `ReportInputChain(inputReader, reportDataDefinition, textCharset, blockSize)` drives
  the definer's framer + segment steps synchronously and yields reusable event objects — **never retain
  `event.row`; always `prototype()` out** (the J3 gotcha). Header comes from the definer's
  `headerExtractorFactory`; CSV skips the header row via the definer's skip flag — the driver must
  honour `event.skip`.
- **Group pattern.** `GroupPattern` (`…server/objects/report/model/`) — filename regex → one
  `DataLocationGroup(String?)`. The generalization is *named* captures → `attributes` map.
- **Job archetype** (`common-document.yaml` `Job:`): `meta.workers` / `meta.channels` are
  `is: List, of: …, by: NestedList`; `JobDocument` takes no ctor args for them. `sources` follows the
  same shape. `JobChannelDerivation.derive` / `JobLogicCompiler.workerLocations` read
  `directNestedObjectPaths(main, workers)` only — a `sources` branch is invisible to auto-wiring.

## Pre-resolved questions

1. **The SPI, verbatim** (commonMain `tech.kzen.auto.common.data.api`):

   ```kotlin
   interface DataSource {
       suspend fun resolve(context: DataContext): DataResolveResult
   }

   interface DataOpener {
       suspend fun open(context: DataContext, part: DataPart): DataCursor
       fun staticShape(role: DataRole?): DataShape? = null                                  // null in DS2
       suspend fun inspectShape(context: DataContext, part: DataPart): DataShape? = null    // null in DS2
   }

   interface DataCursor: Iterator<Any?>, AutoCloseable {
       val shape: DataShape?     // Tabular ⇒ every item is a FlatFileRecord under that header
   }

   interface DataContext {
       fun argument(name: String): Any?
       fun contextValue(key: String): Any?
       suspend fun <R> blocking(block: () -> R): R
       suspend fun host(instructions: ObjectLocation, arguments: TupleValue): TupleValue   // DS8
   }
   ```
   `resolve` returns a resolved **list** — a point-in-time snapshot (§8.1), not a lazy walk. `DataCursor`
   is an `Iterator` (single-pass, honest) — **not suspend, not a `Sequence`**: the worker calls `next()`
   inside `runBlockingIo`, one item per blocking unit; a cursor implementation does plain blocking reads
   and captures **no context** (it must survive a live-edit migrate and be driven by the *new* worker's
   control — O20). `shape is Tabular` ⇒ `FlatFileRecord` items; that is how DS3/DS5 choose `ofFlat` vs
   `ofPayload` with no class switch (CC-17).
2. **Why `open` is suspend but the cursor is not** — stated in `DataOpener`'s KDoc in two sentences:
   `open` may need `context.blocking` (a JDBC connect) or `context.host`; a cursor is a *handle*, and
   handles are driven by their owner. One sentence on `DataCursor` pointing at `CsvRecordReader` as the
   precedent (CC-21).
3. **Context implementations in this session.** Only `DesignDataContext` (jvm, beside the action):
   `argument` reads the detached `ExecutionRequest` parameters, `contextValue` returns null (O12 — a
   request-scoped session comes later, and nothing stateful exists yet), `blocking` =
   `withContext(Dispatchers.IO)` (a detached call is off the engine; the uncounted dispatcher is fine
   *here*), `host` throws `UnsupportedOperationException` with a message naming the limitation ("resolve
   requires a run"). DS3 supplies the run-time context over `JobControl`.
4. **`FileDataSource` attributes (its query).** `directory: String` (blank = none), `filter: String` (the
   **contains-all-words** match above), `files: List` of maps `{location, format?, encoding?}` (explicit
   picks; if non-empty it *is* the selection and directory+filter are only the browser's starting point),
   `format: String` (default coordinate; blank = opener infers by extension), `encoding: String` (blank =
   opener default / detect), `groupPattern: String` (regex over the file name; named groups →
   attributes; a single unnamed group → `group`; blank = no attributes), `missing: String` (`fail`
   default | `skip`). **No `id` attribute** (O15 deferred). Parsed by a new commonMain `FileSelectionSpec`
   (`common/data/file/`) with `ofNotation` / `asNotation` in the `InputDataSpec` key-constant style —
   shared with DS4's editor so the two sides cannot drift.
5. **`missing` semantics.** `fail` = `resolve()` throws naming the first absent path. `skip` = the whole
   **unit** is dropped (never a partial unit — §5.6 whole-unit rule) and one `DataDiagnostic(kind =
   skipped, message = <path>)` per dropped unit goes into `DataResolveResult.diagnostics`. The DS4 card
   renders diagnostics; the run logs them.
6. **Units per file, not one unit with N parts.** One `DataUnit` per selected file, one part, role
   `main`, `ref = DataRef(source = null, id = path.asString(), attributes = {size, modified})` —
   **plain**, with the fingerprint stamped from `DataLocationInfo` (§6.2). `part.format` /
   `part.encoding` = the explicit per-file pick, else the source's default, else **null** (the opener
   infers). Multi-part units come from DS8; the file source is deliberately single-role.
7. **`FileDataOpener` — who owns it and how it is reached.** A plain jvm class
   (`server/data/FileDataOpener.kt`) constructed once in `KzenAutoContext` with the
   `ReportDefinitionRepository`, reachable by workers through **`DataOpenerLookup`**, which is the
   `@Service` they inject. `DataOpenerLookup.openerFor(ref: DataRef): DataOpener` — plain → the file
   opener; sourced → throw (Scope 4). Not a notation object: nothing configures it, and the readers must
   not depend on a source object to read a plain ref (a `LogicDataSource`'s refs have none).
8. **Where the `Job.sources` branch lives.** The Job's own `sources:` branch (`is: List, of: DataSource,
   by: NestedList`, beside `parameters:` / `workers:` — never under `workers:`, which would break
   `JobChannelDerivation`) is **the** authoring surface for this arc and is automatically in the run
   graph. Discovery is graph-wide by capability, so a source in another Job's branch is already pickable
   (§6.5). The `DataSources` document is **not** built (O21).
9. **Caching / statelessness.** A `FileDataSource` instance is stateless; `GraphInstanceCache` reuse is
   correct. The `DataCursor` owns the file handle, never the source or the opener.
10. **Extract the open+parse core once.** `FileDataCursor` (open + `ReportInputChain` drive + header +
    skip + prototype-out + close) is the opener's whole body; it is what DS8's `LogicDataSource` refs
    read through with no second copy (CC-12).

## Step-by-step implementation

### Step 0 — the O14 spike (do this first, ~15 minutes)

A throwaway archetype with `meta: { probe: { is: DataSource, nullable: true } }` and a body default of
`probe: ""`, plus a concrete subtype set on a second instance. Assert: (a) blank defines and creates
(`GraphDefinitionAttempt` has no failure, `GraphCreator.createGraph` succeeds, the ctor gets null); (b)
set pulls the target into `filterTransitive(documentPath)` **including across documents** and injects the
instance; **(c) delete the target** — observe whether the host is pruned from `transitiveSuccessful` (a
hard-reference dangling) and what the editor would show. Record the verdict for (c) in the as-built and
**decide in DS3**: prune-on-delete may be acceptable (the Read card shows a definition error naming the
missing source) or may need the `by: Nominal` fallback. **If (a)/(b) fail**, DS3 falls back to
`by: Nominal` + design-time instantiation in the worker — record that and tell DS3 before it starts.
Delete the spike.

### Step 1 — SPI (commonMain)

`common/data/api/DataSource.kt`, `DataOpener.kt`, `DataCursor.kt`, `DataContext.kt`. KDoc on
`DataSource`: the two contexts (design-time via `DataSourceActions` / run-time from a reader), **why it
is suspend** (one sentence + the §4 pointer), that implementations are discovered **by capability**, and
the CC-21 pointer to `FlatDataSource`. KDoc on `DataOpener` / `DataCursor` per Pre-resolved 2. KDoc on
`DataContext`: that it is *not* a kzen Context (§10 naming caveat).

### Step 2 — `FileSelectionSpec` (commonMain) + notation archetypes + conventions

- `common/data/file/FileSelectionSpec.kt` (+ `FileSelectionEntry` for one picked file): notation
  parse/format, constants for the keys, `Digestible`.
- `notation/auto-common/common-data-source.yaml` (new): `DataSource: {abstract: true, class:
  tech.kzen.auto.common.data.api.DataSource}` — **no `id` attribute**.
- `notation/auto-jvm/datasource/data-source-jvm.yaml` (new): `FileDataSource` — `is: DataSource`,
  `class:`, body defaults for **every** attribute (`directory: ""`, `filter: ""`, `files: []`,
  `format: ""`, `encoding: ""`, `groupPattern: ""`, `missing: "fail"` — the palette-insert gotcha),
  `meta` with `selfLocation: {is: ObjectLocation, by: Self}`. **No `editor:` keys yet** — they land in
  DS4 with their registrations (§6.4). Also `DataSourceActions: {is: DetachedAction-style
  archetype, class: …}` — check how `FileListingAction` is declared and mirror it.
- `common-document.yaml` `Job:` gains `meta.sources: {is: List, of: DataSource, by: NestedList}`.
- `DataSourceConventions` (commonMain, beside the SPI): `dataSourceObjectName`, `sourcesAttributeName` /
  `sourcesAttributePath`, **`isDataSource(graphNotation, location)` with `.drop(1)`**,
  `allDataSources(graphNotation)`. Modelled on `ContextConventions` line for line, minus the document
  half.

### Step 3 — package move (§10)

`git mv` the input plumbing from `server/objects/report/exec/input/connect/…`,
`…/exec/input/ReportInputChain`, `…/exec/input/stages/ReportHeaderReader`, `…/report/service/
FileListingAction` + `ColumnListingAction`, and `service/plugin/ReportDefinitionRepository` into
`server/data/…`, rewriting packages. Report consumes them from the new home; **no logic changes**. Split
`FileListingAction.scanInfo` into a blocking `scanInfoBlocking` core plus the existing suspend method
delegating via `withContext(Dispatchers.IO)`, so Report's callers are untouched and `FileDataSource` can
call the core through `context.blocking`. Keep this a separate commit from Step 4 — a mixed diff here is
unreviewable.

### Step 4 — `FileDataOpener` + `FileDataCursor` + `DataOpenerLookup` (jvm)

`server/data/FileDataOpener.kt`, `FileDataCursor.kt`, `DataOpenerLookup.kt`. `open(context, part)`:
coordinate = `part.format` ?: infer-by-extension; charset = `part.encoding` ?: definer default /
`ReportUtils`; open via `FileFlatDataSource` (inside `context.blocking`), build the `ReportInputChain`,
return a `FileDataCursor` whose `shape = Tabular(header)` from the definer, whose `next()` drives the chain
one record (honouring skip, prototyping rows out), and whose `close()` releases the handle. `staticShape`
/ `inspectShape` return null (DS6). Register the lookup in `KzenAutoContext`'s graph environment.

### Step 5 — `FileDataSource` (jvm)

`kzen-auto-jvm/…/server/objects/datasource/FileDataSource.kt`: `@Reflect`, ctor = the query attributes
+ `selfLocation` + `@Service FileListingAction` (for the blocking core). `resolve(context)`: explicit
files, else directory walk with filter, via `context.blocking { … scanInfoBlocking … }`; stable order
(path-sorted, like `FlatDataInfo.compareTo`); one unit per file per Pre-resolved 6 (fingerprint stamped);
`missing` per Pre-resolved 5. Implements **nothing else** — no `DetachedAction`, no `DataOpener`.

### Step 6 — `DataSourceActions` (jvm) + wiring

`…/server/objects/datasource/DataSourceActions.kt`: `@Reflect`, `DetachedAction`, `@Service
GraphInstanceCache` + the graph store (reuse/lift `ModelDetachedExecutor`'s server-definition helper into
a shared `ServerGraphDefinition` under `service/exec/` — a three-line change there, no behaviour change).
`execute(request)`: `source` parameter → `ObjectLocation` → instantiate → must be a `DataSource` (else
`ExecutionFailure` naming the location, CC-08) → `DesignDataContext(request)` → `resolve` →
`ExecutionSuccess(result.asExecutionValue())`. Unknown `action` → `ExecutionFailure` naming it.

## Tests

1. **`FileDataSourceTest`** (jvm, `server/objects/datasource/`) — direct instantiation with a fake
   `DataContext` (`blocking` = identity): `resolve()` over a temp directory with filter → expected
   ordered units, one part each, role `main`, `ref.source == null`, `ref.id` = path, **fingerprint keys
   stamped** and equal to the file's size/mtime; explicit `files` beats directory; **`filter` is
   contains-all-words** — `"sales csv"` matches `2026-sales.csv` and `"*.csv"` matches nothing (pin the
   dialect); `groupPattern` named captures → attributes (`(?<date>\d{4}-\d{2}-\d{2})`), single
   unnamed group → `group`; `missing: fail` throws naming the path, `missing: skip` drops the unit and
   emits one `skipped` diagnostic per unit; per-file explicit format/encoding land on the part, blank
   leaves them null.
2. **`FileDataOpenerTest`** (jvm, `server/data/`) — with
   `HostReportDefinitionRepository(listOf(CsvReportDefiner(), TsvReportDefiner(), TextReportDefiner()))`
   (mirrors `KzenAutoContext`): `open()` over an RFC-4180 edge-case CSV yields the **same records** as
   `CsvRecordReader` reads directly (the A/B that J3 planned for `PluginReaderWorker`, now at the
   opener); `.tsv` routes to TSV by extension when `part.format` is null; an explicit coordinate wins;
   explicit `encoding = ISO-8859-1` vs null differ on a Latin-1 file; `.gz` transparent; an unknown
   coordinate fails clearly; `shape` is `Tabular` with the header for CSV; `close()` releases the file
   (delete succeeds on Windows afterwards); `hasNext()` false at EOF, and the cursor **captures no
   context** (construct it with one fake context, drive `next()` after that context is invalidated).
3. **`DataOpenerLookupTest`** (jvm) — a plain ref → the file opener; a sourced ref → throws naming the
   id and saying provider-bound refs are not supported.
4. **`DataSourceConventionsTest`** (commonTest) — `isDataSource` true for `FileDataSource` and a subtype,
   **false for the abstract `DataSource` archetype itself** (the `drop(1)` — this is the test that
   catches the `isChannelArchetype` copy-paste), false for a worker and for a missing location;
   `allDataSources` finds sources in two different Jobs' `sources:` branches.
5. **`DataSourceActionsTest`** (jvm) — `KzenAutoContext.forTest()` + a notation fixture in a **temp
   `main/`** (the DDC technique: `KzenAutoConfig(moduleRoot = temp)` + `ClasspathNotationMedia(exclude =
   main/)`) holding a Job with one `sources/` `FileDataSource`; through
   `ModelDetachedExecutor.execute(actionsLocation, source=…, action=resolve)`: the result lowers back to
   the expected `DataResolveResult` via `ofExecutionValue`, diagnostics included; a non-source location →
   `ExecutionFailure` naming it; unknown action → failure naming it.
6. **`FileSelectionSpecTest`** (commonTest) — notation round-trip, blank → null for format/encoding.
7. **`JobNotationTest`-style smoke** that a Job document carrying a `sources/` branch still compiles and
   runs its workers unchanged (the branch is invisible to derivation), **and** that a source with a blank
   required-looking attribute still *creates* (the `createGraph`-throws hazard).
8. **Report suites untouched and green** — the package move and the `scanInfo` split are the only
   Report-visible edits, and both are behaviour-preserving.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test :kzen-auto-common:jvmTest :kzen-auto-common:jsTest`.
2. Headless detached check (AGENTS.md § Headless verification): boot on a spare port against a temp
   project holding a Job with one `FileDataSource`; `curl -G …/action/detached --data-urlencode
   "path=<actions doc>" --data-urlencode "object=<DataSourceActions>" --data-urlencode
   "source=main/X.yaml#main.sources/input" --data-urlencode "action=resolve"` returns the result JSON
   (check the exact parameter encoding `ModelDetachedExecutor` expects for an `ObjectLocation` — the
   `SelectLogicEditor` / `RunWorker.instructions` wire form is the precedent).
3. `:kzen-auto-js:compileKotlinJs` — the common-module package move crosses to the client.
4. As-built note → analysis doc **§13** (include the O14 spike's three verdicts — especially **delete** —
   and the diagnostics shape); tick ledger row 52; delete this file.

## Risks & gotchas

- **The O14 spike is load-bearing, and delete is the new part.** If nullable structural references do not
  behave as `GraphCreator.constructionLevels` implies, or if prune-on-delete is unacceptable for the
  Read card, DS3's `source:` design changes. Fifteen minutes now, a re-plan later.
- **`createGraph` throws on any failure** — every source attribute needs a body default, and a
  misconfigured source must fail at `resolve()`, not at graph creation, or it takes down runs that never
  touch it.
- **`@Reflect` in `src/main` only** (AGENTS gotcha) — test fixtures instantiated from notation are
  served by the JVM reflective mirror; `FileDataSource` / `DataSourceActions` are main code, fine.
- **Event reuse / skip semantics** — the two J3 gotchas, both still live: retaining `event.row` aliases
  every later record; forgetting `event.skip` shifts the A/B by one.
- **Do not make the cursor suspend, and do not let it capture a context.** It is driven by whoever owns
  it, inside *their* `runBlockingIo`. A cursor that offloads for itself puts the read back on the
  engine thread one layer down; a cursor that holds a context is dead after a live-edit migrate (O20).
- **Do not add `DetachedAction` to `FileDataSource`**, and do not give it an `id`. One generic action
  calls every source (analysis §4), and a file ref is plain (§3.3).
- **Do not call `FileListingAction.scanInfo` (the suspend one) from a source.** That is the uncounted
  dispatcher. Use the blocking core through `context.blocking`.
- **Package move discipline** — Step 3 is a separate commit, import-only. Anything else in that diff is a
  mistake (the DS0 rule, one layer up).
- **Glob vs contains-all-words** — do not "improve" `parseFilter` while moving it. One dialect; DS4
  labels it honestly.

## Out of scope (this session)

- `ReadWorker` — **DS3**. The sources editor, `SelectDataSourceEditor`, `FileSelectionEditor`, card
  chrome — **DS4**. `ReadPartWorker` — **DS5**.
- `staticShape` / `inspectShape` bodies, `action=shape`, the schema cache — **DS6**. `LogicDataSource`
  and named host arguments — **DS8**.
- **`DataSourceId` minting, the id→location scan, duplicate-id validation, and any run-time resolver**
  — deferred past the arc, with the first provider-bound source (O15, analysis §3.3).
- **The `DataSources` document** and its controller — deferred (O21).
- Dynamic jar loading of third-party sources — extension-points §1, its own arc.
- A design-time `DesignSession` (O12) — `DesignDataContext.contextValue` returns null and nothing stateful
  exists yet.
