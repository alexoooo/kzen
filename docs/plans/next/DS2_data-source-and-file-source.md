# DS2 — `DataSource` + `DataScope` + `FileDataSource` + the `DataSources` document — implementation plan

> **Status: ready to execute.** Session 2 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md) **§4**
> (the SPI, the scope, why nothing is `suspend`, borrow-not-own), §4.1 (third-party loading), §4.2
> (axes), §6.2 (cache discipline), **§6.4a** (where a source lives), §9 (Report parity), §10 (package
> layering). Constituent plan: **—** (analysis doc is the record; delete this file on landing, as-built
> note → analysis **§14**). Depends on **DS0** and **DS1**. Anchors verified 2026-08-21. **Revised
> 2026-08-21b** by the second-pass review (§13 C1, C6, D1, D3, D4). Sized **M–L**; kzen-auto-common
> (API) + kzen-auto-jvm (implementation, resolver, notation, one package move) + fixtures. Ledger
> row 52.
>
> ⚠ **Start with the O14 spike** (below). One structural decision in DS3 rests on it, and it is ten
> minutes.

## Scope & goal

1. **`DataSource` SPI + `DataScope` + `DataItems`** (commonMain, `common/data/api/`). Nothing on the SPI
   is `suspend`; the offload, the named arguments and the Context borrow all live on the scope.
2. **`FileDataSource`** (jvm, `@Reflect` notation object): Report's `InputSpec` shape lifted onto an
   object — directory + filter, explicit file selection with per-file format / encoding, default format /
   encoding, a group pattern whose named captures become unit attributes, and `missing: skip | fail`.
   `units()` resolves the query; `items(part)` opens a part through the **existing** byte-stream seam
   (`FileFlatDataSource`) and **existing** format-plugin SPI (`ReportDefiner` via
   `ReportDefinitionRepository`, driven by `ReportInputChain`) — so a third-party format works in a Job
   with zero new code, closing J3a's goal. `schema()` / `itemType()` return null in this session (DS6
   fills them).
3. **The `DataSources` document + graph-wide discovery**, on the shipped `Contexts` pattern.
4. **`DataSourceId` minting** — the `id: ""` attribute on the archetype, and the resolver that maps an
   id back to an object.
5. **`DataSourceResolver`** (jvm `@Service`): **design-time only, plus one run-time fallback.** Run-time
   access comes from the run's own graph (analysis §6.5 / D2) — this resolver serves detached actions
   and the cross-Logic-boundary case where a `DataRef`'s source is not in the current run's graph.
6. **Design-time:** `FileDataSource` is a `DetachedAction` answering `action=resolve` with the lowered
   `DataManifest` — the generic card chrome in DS4 calls this on any source.
7. **Package move:** the input plumbing out of `server/objects/report/…` into `server/data/…` (§10).

After this session nothing user-facing changes yet.

## Dependencies & coordination

- **DS0 landed** — `common/data/schema/HeaderListing`. **DS1 landed** — the model types under
  `common/data/model/`.
- **DS1b is independent** but should land before DS3; nothing here needs it.
- **DS3** consumes `DataItems.flatHeader` and the structural reference; **DS4** the `resolve` detached
  action, the archetype's attribute metadata and the mint-on-insert; **DS5** the resolver's
  cross-boundary path; **DS6** adds `schema` / `itemType` / `cachedSchema`.
- **J3 supersession.** This session's `FileDataSource.items` *is* J3 Step 1's `PluginReaderWorker` core
  (the synchronous `ReportInputChain` driver over a definer), relocated from a worker into the source
  object. Read `J3_report-subsumption-a.md` § Current-state findings A–B for the verified SPI anchors
  (definer lookup, `ReportInputChain` event reuse, skip semantics) — they are still accurate — and do
  **not** build `PluginReaderWorker`. `encoding` (J3 step 4) lands as `DataPart.encoding` /
  `FileDataSource.encoding` instead of a reader attribute.
- **`FlatDataSource` name clash.** `FlatDataSource` (byte-stream seam) stays; after the §10 move it
  lives in the *same package* as `DataSource`, which is where the CC-21 reciprocal one-liners
  ("not the same seam as …") read naturally.
- **Dynamic third-party loading** (extension-points §1) is *not* built here, but nothing may assume a
  compiled-in class: every lookup of "what sources exist" is by capability (inheritance chain reaches
  the `DataSource` archetype — the `ContextConventions.isContext` shape, CC-17), never by class name.
- **File safety:** `notation/main/` is the user's — never edited. New archetypes are additive.

## Current-state findings (anchors verified 2026-08-21)

- **Nullable structural references are supported by kzen-lib.** `GraphCreator.constructionLevels`, on an
  empty `objectReference`, checks `reference.isNullable(objectMetadata)` and — when nullable —
  contributes no edge and records no unsatisfied reference; `GraphDefinitionAttempt` performs the same
  nullability walk in two places; `ObjectDefinitionReference.isNullable` reads
  `attributeTypeMetadata.nullable`; `NotationMetadataReader` reads `nullable` from a map-shaped type
  notation. **There is no shipped precedent for the combination**, though — the Worker channel ports use
  `creator: JobChannelCreator` and `ContextBinder.binds` / `RunStep.contexts` use `by: Nominal`. Hence
  the spike.
- **The run graph already holds every object in the Job document.** `JobLogicCompiler` builds
  `synthesis.graphDefinition.filterTransitive(documentPath)`; `JobRun` calls
  `GraphCreator.createGraph(filteredDefinition, graphEnvironment)` — **the whole filtered definition**,
  not just workers and channels. ⚠ `createGraph` **throws** if *any* object fails to create, so a
  half-configured source in a `sources:` branch fails every run of that Job. Attributes must define when
  blank; `units()` fails with a clear message instead.
- **Detached instantiation.** `ModelDetachedExecutor.execute(actionLocation, request)`
  (`…server/service/exec/`) → `actionLookup` builds
  `graphStore.graphDefinition().transitiveSuccessful.filterDefinitions(AutoConventions.serverAllowed)`
  and calls `graphInstanceCache.tryObjectInstance(serverDefinition, location)`. `GraphInstanceCache`
  caches per `(closure digest + inheritance-chain digests, location)`, is `@Synchronized`, bounds at 32
  entries, and **reuses instances only while stateless** — which `FileDataSource` is, and which every
  source must remain (analysis §4: borrow, never own). `serverAllowed` = {`kzen/`, `auto-common/`,
  `auto-jvm/`, `main/`} — a source nested in a user's `main/…Job.yaml` is reachable; one in `test/`
  notation is **not** (the DDC plan's lesson — a detached-route test must drop its fixture into a temp
  `main/`).
- **`Contexts` is the pattern to copy.** `ContextConventions`: `contextsDocumentObjectName`,
  `contextsAttributeName`, `isContextsDocument(documentNotation)`,
  **`isContext(graphNotation, location)` = `inheritanceChain(location).drop(1).any { … }`** — the
  `drop(1)` exists precisely so the abstract archetype does not match its own filter and offer itself in
  every picker — `descriptorOrNull`, `resolveOrNull(reference, host)`, and
  **`allContexts(graphNotation)` = `coalesce.map.keys.mapNotNull { descriptorOrNull(…) }`** (graph-wide
  discovery). The `Contexts` archetype in `common-document.yaml` carries the design comment worth
  copying verbatim: *"this document is AN authoring surface, never the home."*
- **Services into objects.** `@Service` constructor injection (`FormulaSourceWorker`'s
  `CalculatedColumnEval`); registration in `KzenAutoContext` via the graph-environment
  `.put(ClassName(…), instance)` (the `ObjectStableMapper` line is the precedent). `GraphInstanceCache`,
  `graphStore` and `objectStableMapper` are all already fields of `KzenAutoContext`.
- **`JobControl.runBlockingIo(block: () -> R)` is NON-suspend** and offloads through
  `Execution.blocking`, which is what keeps the call counted by the `CountingDispatcher` and
  interruptible by cancel / migrate. Its KDoc explicitly forbids a bare `withContext(Dispatchers.IO)`
  as "false quiescence".
- **`FileListingAction.scanInfo(pattern, filter)` is `suspend` and does `withContext(Dispatchers.IO)`
  internally** around `Files.walkFileTree` — so it cannot be called from inside `runBlockingIo`, and
  calling it directly from a worker escapes quiescence accounting. It yields
  `DataLocationInfo(path, name, size, modified, dir)` from `BasicFileAttributes` (the inputs DS6's cache
  key needs, one call away).
- ⚠ **`FileListingAction.parseFilter` is NOT a glob.** It trims, lowercases, splits on whitespace and
  requires the file **name** to contain **every** token (`filterParts.all { name.contains(it) }`). So
  `sales csv` matches `2026-sales.csv` and `*.csv` matches nothing. Do not label it a glob anywhere.
- **`ReportDefinitionRepository` is fully non-suspend** (`contains` / `metadata` / `listMetadata` /
  `classLoaderHandle` / `define` / `find`) — so a blocking `items()` needs no bridging.
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
- **Stable ids** (for the resolver's *location* side only): `ObjectStableMapper.objectStableId(location)`
  / `objectLocationOrNull(id)` (kzen-lib `service/store/normal/`). ⚠ Not used for `DataRef.source` —
  see DS1.

## Pre-resolved questions

1. **The SPI, verbatim** (commonMain `tech.kzen.auto.common.data.api`):

   ```kotlin
   interface DataSource {
       fun units(scope: DataScope): List<DataUnit>
       fun items(scope: DataScope, part: DataPart): DataItems
       fun schema(scope: DataScope, part: DataPart): HeaderListing?   // null in DS2
       fun itemType(part: DataPart): TypeMetadata?                    // notation-only, never IO; null in DS2
   }

   interface DataScope {
       fun argument(name: String): Any?
       fun contextValue(key: String): Any?
       fun <R> blocking(block: () -> R): R
       fun host(instructions: ObjectLocation, input: Any?): TupleValue   // DS8's LogicDataSource
   }

   interface DataItems: Sequence<Any?>, AutoCloseable {
       val flatHeader: HeaderListing?
   }
   ```
   `units` returns a resolved **list** — resolution is a point-in-time snapshot (§8.1), not a lazy walk.
   `DataItems` is a `Sequence` because Kotlin's Sequence contract permits single-shot ("can be iterated
   multiple times **or not**"); it must throw on a second `iterator()` (constrain-once), which an
   `Iterable` could not do without violating its contract. **`flatHeader != null` ⇒ every item is a
   `FlatFileRecord` under that header**; that is how DS3 and DS5 choose `ofFlat` vs `ofPayload` with no
   class switch (CC-17).
2. **Scope implementations in this session.** Only `DesignDataScope` (jvm, beside the resolver):
   `argument` reads the detached `ExecutionRequest` parameters, `contextValue` returns null (O12 — a
   request-scoped session comes later, and nothing stateful exists yet), `blocking` is identity (a
   detached call is already off the engine), `host` throws `UnsupportedOperationException` with a message
   naming the limitation ("resolve requires a run"). DS3 supplies the run-time scope over `JobControl`.
3. **`FileDataSource` attributes (its query).** `id: String` (the minted `DataSourceId`, hidden),
   `directory: String` (blank = none), `filter: String` (the **contains-all-words** match above),
   `files: List` of maps `{location, format?, encoding?}` (explicit picks; if non-empty it *is* the
   selection and directory+filter are only the browser's starting point), `format: String` (default
   coordinate; blank = infer by extension), `encoding: String` (blank = declared-by-definer / detect),
   `groupPattern: String` (regex over the file name; named groups → attributes; a single unnamed group →
   `group`; blank = no attributes), `missing: String` (`fail` default | `skip`). Parsed by a new
   commonMain `FileSelectionSpec` (`common/data/file/`) with `ofNotation` / `asNotation` in the
   `InputDataSpec` key-constant style — shared with DS4's editor so the two sides cannot drift.
4. **`missing` semantics.** `fail` = `units()` throws naming the first absent path. `skip` = the whole
   **unit** is dropped (never a partial unit — §5.6 whole-unit rule) and the dropped count is reported.
   Where reported: a `DataManifest`-adjacent field is tempting but the model is fixed (DS1) — put it in
   the **detached `resolve` result** alongside the manifest, so the DS4 card can show it, and log at run
   time. Record the shape in the as-built.
5. **Units per file, not one unit with N parts.** One `DataUnit` per selected file, one part, role
   `main`, `ref = DataRef(source = this object's DataSourceId, id = path.asString())`. Multi-part units
   come from DS8; the file source is deliberately single-role.
6. **Where `DataSourceId` comes from.** The object reads its own `id` attribute. **DS4's insert command
   mints it**; a blank `id` (hand-authored notation) degrades to resolve-by-location with a warning
   (analysis §3.3). Duplicate ids across documents are **reported** by validation, not prevented — the
   `LogicContextAnalysis` duplicate-key precedent. In this session: the attribute, the read, and the
   resolver's id→location scan; the mint and the duplicate report are DS4.
7. **Resolver semantics and scope.** `DataSourceResolver` (jvm `@Service`):
   `resolve(id: DataSourceId): DataSource?` (scan `coalesce` for the object with that `id`, cached by
   notation digest — the `ObjectRegistryDocument.scanCache` shape, Caffeine keyed on `Digest`) and
   `resolve(location: ObjectLocation): DataSource` (throws naming the location if absent or not a
   source — CC-08), both over `GraphInstanceCache`. **It is not the run-time path.** Its two customers
   are the detached actions and DS5's cross-boundary `DataRef.source` lookup. Say so in its KDoc, with
   the CC-21 pointer to `ReadWorker`'s injected reference.
8. **Where the `Job.sources` branch lives, and the `DataSources` document.** Both. The Job's own
   `sources:` branch (`is: List, of: DataSource, by: NestedList`, beside `parameters:` / `workers:` —
   never under `workers:`, which would break `JobChannelDerivation`) is the local surface and is
   automatically in the run graph; the `DataSources` document is the shared surface. Discovery is
   graph-wide and by capability, so both reach the same picker.
9. **Caching / statelessness.** A `FileDataSource` instance is stateless; `GraphInstanceCache` reuse is
   correct. `DataItems` owns the handle, never the source.

## Step-by-step implementation

### Step 0 — the O14 spike (do this first, ~10 minutes)

A throwaway archetype with `meta: { probe: { is: DataSource, nullable: true } }` and a body default of
`probe: ""`, plus a concrete subtype set on a second instance. Assert: (a) blank defines and creates
(`GraphDefinitionAttempt` has no failure, `GraphCreator.createGraph` succeeds, the ctor gets null); (b)
set pulls the target into `filterTransitive(documentPath)` **including across documents** and injects the
instance. **If it fails**, DS3 falls back to `by: Nominal` + `DataSourceResolver` — record that in the
as-built and tell DS3 before it starts. Delete the spike.

### Step 1 — SPI (commonMain)

`common/data/api/DataSource.kt`, `DataScope.kt`, `DataItems.kt`. KDoc on `DataSource`: the four calls,
the two contexts (design-time detached / run-time from a worker or expression), **why nothing is
`suspend`** (one sentence + the §4 pointer), the CC-21 pointer to `FlatDataSource`, and that
implementations are discovered **by capability**. KDoc on `DataItems`: constrain-once, and the
`flatHeader` contract.

### Step 2 — `FileSelectionSpec` (commonMain) + notation archetypes

- `common/data/file/FileSelectionSpec.kt` (+ `FileSelectionEntry` for one picked file): notation
  parse/format, constants for the keys, `Digestible`.
- `notation/auto-common/common-data-source.yaml` (new): `DataSource: {abstract: true, id: "", class:
  tech.kzen.auto.common.data.api.DataSource, meta: {id: String}}`; `DataSources` document archetype
  (`group: "Customize"`, `meta.sources: {is: List, of: DataSource, by: NestedList}`) — a direct copy of
  `Contexts`, **including its "AN authoring surface, never the home" comment**.
- `notation/auto-jvm/datasource/data-source-jvm.yaml` (new): `FileDataSource` — `is: DataSource`,
  `class:`, body defaults for **every** attribute (`directory: ""`, `filter: ""`, `files: []`,
  `format: ""`, `encoding: ""`, `groupPattern: ""`, `missing: "fail"` — the palette-insert gotcha),
  `meta` with `selfLocation: {is: ObjectLocation, by: Self}`. **No `editor:` keys yet** — they land in
  DS4 with their registrations (§6.4 / C5).
- `common-document.yaml` `Job:` gains `meta.sources: {is: List, of: DataSource, by: NestedList}`.
- `DataSourceConventions` (commonMain, beside the SPI): `dataSourceObjectName`,
  `dataSourcesDocumentObjectName`, `sourcesAttributeName` / `sourcesAttributePath`, `idAttributeName`,
  **`isDataSource(graphNotation, location)` with `.drop(1)`**, `allDataSources(graphNotation)`,
  `isDataSourcesDocument(documentNotation)`. Modelled on `ContextConventions` line for line.

### Step 3 — package move (§10)

`git mv` the input plumbing from `server/objects/report/exec/input/connect/…`,
`…/exec/input/ReportInputChain`, `…/exec/input/stages/ReportHeaderReader`, `…/report/service/
FileListingAction` + `ColumnListingAction`, and `service/plugin/ReportDefinitionRepository` into
`server/data/…`, rewriting packages. Report consumes them from the new home; **no logic changes**. Split
`FileListingAction.scanInfo` into a blocking `scanInfoBlocking` core plus the existing suspend method
delegating via `withContext(Dispatchers.IO)`, so Report's callers are untouched and `FileDataSource` can
call the core through `scope.blocking` (C1). Keep this a separate commit from Step 4 — a mixed diff here
is unreviewable.

### Step 4 — `FileDataSource` (jvm)

`kzen-auto-jvm/…/server/objects/datasource/FileDataSource.kt` (+ `FlatFileItems.kt`): `@Reflect`, ctor =
the query attributes + `selfLocation` + `@Service ReportDefinitionRepository` + `@Service
FileListingAction`. `units(scope)`: explicit files, else directory walk with filter, via
`scope.blocking { … scanInfoBlocking … }`; stable order (path-sorted, like `FlatDataInfo.compareTo`);
`missing` applied per Pre-resolved 4. `items(scope, part)`: coordinate = `part.format` ?: default ?:
infer-by-extension; charset = `part.encoding` ?: default ?: `ReportUtils`; open via `FileFlatDataSource`,
drive `ReportInputChain`, `flatHeader` from the definer, honour skip, prototype rows out, constrain-once,
`close()` releases the handle. `schema` / `itemType` return null (DS6). Implements `DetachedAction`:
`action=resolve` → `ExecutionSuccess` carrying `manifest.asExecutionValue()` plus the skipped count;
unknown action → `ExecutionFailure` naming it.

**Extract `FlatFileItems` now, not in DS8.** It is the open+parse+header+skip+close core, and DS8's
`LogicDataSource` opens plain refs through it. The previous plan deferred the lift; doing it here means
one implementation from the start (CC-12).

### Step 5 — `DataSourceResolver` (jvm) + wiring

`…/server/objects/datasource/DataSourceResolver.kt` (+ the shared `ServerGraphDefinition` helper under
`service/exec/`), registered in `KzenAutoContext`'s graph environment. `ModelDetachedExecutor` switches to
the shared helper (a three-line change; no behaviour change).

## Tests

1. **`FileDataSourceTest`** (jvm, `server/objects/datasource/`) — direct instantiation with
   `HostReportDefinitionRepository(listOf(CsvReportDefiner(), TsvReportDefiner(), TextReportDefiner()))`
   (mirrors `KzenAutoContext`) and a fake `DataScope`: `units()` over a temp directory with filter →
   expected ordered units, one part each, role `main`, `ref.id` = path, `ref.source` = the configured id;
   explicit `files` beats directory; **`filter` is contains-all-words** — `"sales csv"` matches
   `2026-sales.csv` and `"*.csv"` matches nothing (pin the dialect, C6); `groupPattern` named captures →
   attributes (`(?<date>\d{4}-\d{2}-\d{2})`), single unnamed group → `group`; `missing: fail` throws
   naming the path, `missing: skip` drops the unit and reports the count; `items()` over an RFC-4180
   edge-case CSV yields the **same records** as `CsvRecordReader` reads directly (the A/B that J3 planned
   for `PluginReaderWorker`, now at the source); `.tsv` routes to TSV by extension; explicit
   `encoding = ISO-8859-1` vs blank differ on a Latin-1 file; `.gz` transparent; an unknown coordinate
   fails clearly; **a second `iterator()` throws** (constrain-once); `close()` releases the file (delete
   succeeds on Windows afterwards); `flatHeader` is non-null for CSV.
2. **`DataSourceConventionsTest`** (commonTest) — `isDataSource` true for `FileDataSource` and a subtype,
   **false for the abstract `DataSource` archetype itself** (the `drop(1)` — this is the test that
   catches the `isChannelArchetype` copy-paste), false for a worker and for a missing location;
   `allDataSources` finds sources in a Job's `sources:` branch **and** in a `DataSources` document.
3. **`DataSourceResolverTest`** (jvm) — `KzenAutoContext.forTest()` + a notation fixture in a **temp
   `main/`** (the DDC technique: `KzenAutoConfig(moduleRoot = temp)` + `ClasspathNotationMedia(exclude =
   main/)`) holding a Job with one `sources/` `FileDataSource` and a `DataSources` document with another;
   `resolve(location)` returns a `FileDataSource` whose `units()` work; `resolve(id)` finds the same
   object and finds the one in the other document; a non-source location throws; the id scan survives an
   unrelated notation edit and re-scans on a relevant one.
4. **`FileDataSourceDetachedTest`** (jvm) — through `ModelDetachedExecutor.execute(location,
   action=resolve)` on the same temp-`main/` fixture: the result lowers back to the expected
   `DataManifest` via `DataManifest.ofExecutionValue`, and carries the skipped count.
5. **`FileSelectionSpecTest`** (commonTest) — notation round-trip, blank → null for format/encoding.
6. **`JobNotationTest`-style smoke** that a Job document carrying a `sources/` branch still compiles and
   runs its workers unchanged (the branch is invisible to derivation), **and** that a source with a blank
   required-looking attribute still *creates* (the `createGraph`-throws hazard).
7. **Report suites untouched and green** — the package move and the `scanInfo` split are the only
   Report-visible edits, and both are behaviour-preserving.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test :kzen-auto-common:jvmTest :kzen-auto-common:jsTest`.
2. Headless detached check (AGENTS.md § Headless verification): boot on a spare port against a temp
   project holding a Job with one `FileDataSource`; `curl -G …/action/detached --data-urlencode
   "path=main/X.yaml" --data-urlencode "object=main.sources/input" --data-urlencode "action=resolve"`
   returns the manifest JSON.
3. `:kzen-auto-js:compileKotlinJs` — the common-module package move crosses to the client.
4. As-built note → analysis doc **§14** (include the O14 spike's verdict and the `missing`-report shape);
   tick ledger row 52; delete this file.

## Risks & gotchas

- **The O14 spike is load-bearing.** If nullable structural references do not behave as
  `GraphCreator.constructionLevels` implies, DS3's whole `source:` design changes. Ten minutes now, a
  re-plan later.
- **`createGraph` throws on any failure** — every source attribute needs a body default, and a
  misconfigured source must fail at `units()`, not at graph creation, or it takes down runs that never
  touch it.
- **`@Reflect` in `src/main` only** (AGENTS gotcha) — test fixtures instantiated from notation are
  served by the JVM reflective mirror; `FileDataSource` itself is main code, fine.
- **Event reuse / skip semantics** — the two J3 gotchas, both still live: retaining `event.row` aliases
  every later record; forgetting `event.skip` shifts the A/B by one.
- **Do not reintroduce a `suspend`** anywhere on the SPI. If something wants to be suspend, the answer is
  `DataScope.blocking`; if that does not fit, it is a design question for the analysis doc, not a local
  fix (C1 is exactly this failure).
- **Do not call `FileListingAction.scanInfo` (the suspend one) from a source.** That is the uncounted
  dispatcher. Use the blocking core through the scope.
- **Package move discipline** — Step 3 is a separate commit, import-only. Anything else in that diff is a
  mistake (the DS0 rule, one layer up).
- **Glob vs contains-all-words** — do not "improve" `parseFilter` while moving it. One dialect; DS4
  labels it honestly.

## Out of scope (this session)

- `ReadWorker` — **DS3**. The sources editor, `SelectDataSourceEditor`, `FileSelectionEditor`, card
  chrome, and **minting `id` on insert** — **DS4**.
- `schema()` / `itemType()` bodies and the cache-key fix — **DS6**. `LogicDataSource` and the dated
  example — **DS8**.
- Dynamic jar loading of third-party sources — extension-points §1, its own arc.
- A design-time `DesignSession` (O12) — `DesignDataScope.contextValue` returns null and nothing stateful
  exists yet.
