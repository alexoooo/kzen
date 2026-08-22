# DS6 — design-time schema: `schema` / `itemType`, cache-key fix, superset normalization, editor dropdowns — implementation plan

> **Status: ready to execute.** Session 6 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§6.1** (two consumers, and the declared-schema route), **§6.2** (cache key bug), **§6.3** (column
> types and the shipped `DataFormat` document), **§5.2b + O19** (heterogeneous-header superset), §5.5a
> (`itemType` on the walk), §9 (no row preview). Constituent plan: **—** (analysis doc is the record;
> delete on landing, as-built → analysis **§14**). Depends on **DS2, DS3, DS4**. Anchors verified
> 2026-08-21. **Revised 2026-08-21b** by the second-pass review (§13 C3). Sized **M–L**; kzen-auto-jvm +
> kzen-auto-js + yaml. Ledger row 56. **Absorbs J3b** (the column pre-scan route + `JobUpstreamSchema`
> fallback + `SortSpecEditor` dropdown) — do not execute `J3_report-subsumption-a.md` steps 2–3
> separately.

## Scope & goal

1. **`FileDataSource.schema(scope, part)`** — the bounded header read (`ReportHeaderReader` behind
   `ColumnListingAction`), **cache keyed on `(ref.id, format, encoding, size, mtime)`**, never a full
   scan.
2. **The cache-key fix** in `ColumnListingAction` — today `columns.csv` is keyed on `(dataLocation,
   pluginCoordinate)` only, so an edited file serves stale columns until the cache is cleared by hand.
   Report benefits too.
3. **`itemType(part)`** — the static item type, answerable from **notation alone**, supplied by a
   declared schema document (item 6). Null for a flat/tabular source, whose shape is columns.
4. **`DataSource.cachedSchema(part)`** — read-only, cache-hit-or-null, for the payload-type walk.
   `ReadWorker.payloadFlow` under `emit: items` publishes `flatColumns` from it (never `schema()`), so
   O3 holds **by construction**.
5. **Heterogeneous-header superset normalization (O19)** — replaces DS3's loud failure: resolve the
   superset from the pre-scan and normalize every item to it, exactly as Report's
   `DatasetInfo.headerSuperset()` does.
6. **The declared-schema route** — rename the orphaned `DataFormat` document to `DataSchema` (or delete
   it) and let a source name one, so `schema` / `itemType` can answer with no IO at all.
7. **Detached `action=schema`** on the source (beside `resolve`), returning `HeaderListing` per part.
8. **Editor consumers**: `JobUpstreamSchema` gains an ordered provider list; `SortSpecEditor` (and the
   other spec editors that take column names) offer a dropdown when columns are known with no run;
   source-card **Columns** chrome beside **Resolve**.

**Not in scope, and stated as a contract:** there is no row-level data preview (§9). `schema` must be
answerable from a declaration or a *bounded* read; a source that cannot answer cheaply returns null.

## Dependencies & coordination

- **DS2–DS4 landed.** `FileDataSource`, `ReadWorker`, the source card.
- **J3b is superseded by this session** — its findings §B–§E (definition repository, the
  `columns.csv` cache, `JobUpstreamSchema`, `SortSpecEditor` state) were verified 2026-07-19 and
  re-checked 2026-08-21; reuse them, do not duplicate the route it planned (the route is now the
  source's detached action).
- **J4** later adds the offline persisted summary as a higher-priority column source — design
  `JobUpstreamSchema`'s resolution list so J4 inserts an entry, not a branch.
- **J8** dedupes the spec editors — touch `SortSpecEditor` minimally (add the column-source + dropdown
  branch mirroring `ValueSetFilterEditor`), exactly as J3 step 3 intended.
- **The `DataFormat` rename (O18) is user-facing.** It is a shipped document archetype with a controller
  and a ribbon/sidebar presence, even though nothing reads it. Confirm the rename (or the deletion)
  before doing it; if the answer is "leave it", implement item 6 against a new declaration attribute and
  record the collision as unresolved.
- **DS3's superset deferral lands here.** Re-read `ReadWorker`'s heterogeneous-header failure and its
  KDoc reason before replacing it.

## Current-state findings (anchors verified 2026-08-21)

- **`ColumnListingAction`** (after DS2's move, `server/data/`): `columnsCsvFilename = "columns.csv"`,
  `cachedHeaderListing(dataLocation, processorPluginCoordinate)` derives the cache path through
  `FilterIndex.inputIndexPath(...)` — **no size/mtime** — and parses the cached CSV back into a
  `HeaderListing` via `CsvReportDefiner.literal(...)`. `headerListing(...)` extracts via the definer's
  header extractor (`ReportHeaderReader`), reading only as far as the header.
- **`FileListingAction.toFileInfo`** already reads `BasicFileAttributes` (size, mtime) into
  `DataLocationInfo` — the inputs for the new key are one call away, on both the browse and the resolve
  paths.
- **Report's superset is the precedent to copy**: `DatasetInfo.headerSuperset()` =
  `HeaderListing(items.flatMap { it.headerListing.values }.toSet().toList())`. Downstream, a record is
  read against a header via `RecordHeaderIndex.indices(headerListing)`, which returns `-1` for a column
  the record lacks and `CalculatedColumnEval`'s generated `columnValue` renders `<missing>`. So the
  machinery for a normalized wide row already exists end to end.
- **Why DS3 failed instead** (§5.2b, and the reason this session can fix it): the reader was never the
  problem — `SummaryWorker.ensureInitialized` fixes its column set from the **first** record's header
  and `CsvWriterWorker` writes the header from the first batch, so mixed headers lose data *silently*
  downstream. A **superset resolved up front** removes that, which is why it needs the pre-scan and
  therefore this session.
- **`WorkerLane.flatColumns`** (null = unknown) and `JobValidator` / `JobValidationCache` — the walk is
  cached per graph-definition digest and shared with the editor's detached validation; `ReadWorker`'s
  `payloadFlow` runs inside it, so "cache only" is what keeps the walk IO-free.
- **`JobUpstreamSchema`** (`…client/objects/document/job/edit/`): `nearestUpstreamSummaryWorker(
  graphStructure, from)` — finds a live `SummaryServer` upstream via `JobServeCapability`; that is the
  only column source today. `SortSpecEditor` is free text when none exists.
- **Client validation slice**: `JobValidationStore` fetches the server's per-worker validation
  (inferred payload type + expression error) — the natural carrier for "known columns on this lane" if
  the walk publishes them; check whether the Job slice already carries `flatColumns` (J3 findings §E
  said the walk result reaches the card; verify the field).
- **The `DataFormat` document** (`common-document.yaml`, `group: "Customize"`): `DataFormatDocument`
  (`fields: FieldFormatListSpec`), `FieldFormatSpec` = a **`TypeMetadata`** per field, `ClassListSpec`-
  style `meta.ref` definer binding, `DataFormatController` in `data-js.yaml`, and `FieldFormatSpecTest`
  pinning the notation. **Its only reader is itself** — nothing in the app consumes `fields`.
- **Detached from the client**: `ClientRestApi.performDetached(location, "action" to "schema", "part"
  to <lowered part>)`; `HeaderListing` has an `ExecutionValue` form already (used by Report).

## Pre-resolved questions

1. **Cache key** — `(ref.id, format coordinate, encoding, size, mtime)`; where the source cannot supply
   size/mtime (a non-file source later), **don't cache**. The key is computed in one place
   (`SchemaCacheKey` helper beside `ColumnListingAction`) and the on-disk layout moves from
   `FilterIndex`'s `(location, coordinate)` path to a digest-named file — migrating old `columns.csv`
   entries is not worth it; they are simply unused (note in as-built; the storage manager can purge).
2. **Who owns the cache** — `ColumnListingAction` (existing, shared with Report), injected into
   `FileDataSource` as a `@Service`; `schema()` = declaration → cache hit → bounded read → store.
   `cachedSchema(part)` is a **new method on `DataSource` with a default `null`** (most sources have
   nothing cached) and **must not** fall through to a read.
3. **`itemType` supply** — a source may declare a schema document nominally
   (`schema: {is: ObjectLocation, nullable: true, by: Nominal}` on `DataSource`), read as data through a
   conventions object (the `ContextConventions.descriptorOrNull` shape). `FileDataSource` returns null
   from `itemType` (its shape is columns, not an object type) but answers `schema()` from the
   declaration when present, skipping the read entirely. This is what makes a source whose reading is
   expensive still typed at design time.
4. **Resolution order in `JobUpstreamSchema`** — an ordered list of column providers evaluated until
   one answers: live summary → (J4 slot) → **declared schema** → pre-scan via the validation slice's
   `flatColumns` on the upstream lane → none. The editor asks "columns on my input lane", not "columns of
   that file" — the lane is the unit of schema, which is what the walk already computes.
5. **When the cache is primed** — by the source card's "Columns" action, by `Resolve` (optionally: also
   prime the first part of each unit, bounded), and by any run. A fresh document with no click and no run
   shows free text — acceptable and stated; the card makes priming one click.
6. **Superset semantics** — the superset is computed from the **pre-scan of every part in the resolved
   manifest** for the selected role, in manifest order, de-duplicated (Report's `toSet().toList()`).
   Every emitted item is normalized to it. If any part's schema is **unknown** (cache miss and the source
   declines a bounded read), fall back to DS3's behaviour: fail rather than guess. Add a
   `mergeSchemas: strict | superset` knob on `ReadWorker` (**default `superset`** once this lands) so a
   pipeline that *wants* the strict failure keeps it — and so the DS3 → DS6 behaviour change is visible
   in notation rather than silent.
7. **Cost** — the superset costs one bounded read per part at resolve time. For a many-file selection
   that is a real cost; it is bounded (header only), cached, and only paid under `mergeSchemas:
   superset`. Measure on a 100-file selection and record the number in the as-built either way.

## Step-by-step implementation

1. **`ColumnListingAction` key fix** (jvm) + `SchemaCacheKey`; Report's callers pass size/mtime (they
   have `DataLocationInfo` / `Path` at hand). Report's suites prove no behaviour change except
   staleness.
2. **`DataSource.cachedSchema(part)`** (common API, default null) + **`FileDataSource.schema` /
   `cachedSchema` / `itemType`** (jvm) + `action=schema` in its `DetachedAction`.
3. **The declared-schema route** — O18's rename (or its deferral), the `schema:` nominal attribute on
   the `DataSource` archetype, and the conventions read.
4. **`ReadWorker`**: `payloadFlow` under `items` publishes `cachedSchema` columns (and `itemType` as the
   payload type); `mergeSchemas` knob; superset resolution + per-item normalization replacing the
   failure. ⚠ Static columns are published only when the source's query **names its parts statically**
   (explicit `files`) *and* the cache has them; a directory-walk source is unknown at walk time even when
   primed, because the walk must not resolve. Document it — this is §5.5's honest reduction.
5. **Client**: `JobUpstreamSchema` provider list; `SortSpecEditor` dropdown branch; source-card
   "Columns" action rendering a chip list per part.

## Tests

1. **`ColumnListingActionTest`** (jvm, extend/add) — same file, same coordinate, edited content (size or
   mtime change) → fresh columns; unchanged → cache hit (no extractor call — count via a spy definer).
2. **`FileDataSourceTest`** additions — `schema(part)` on a headered CSV returns the header; on a
   headerless coordinate returns positional names; `cachedSchema` null before any call, non-null after
   `schema`; a **declared** schema answers with **zero** file reads (spy the definer).
3. **`FileDataSourceDetachedTest`** addition — `action=schema`.
4. **`JobValidatorTest`** additions — `ReadWorker(items)` over a source with explicit `files` and a
   primed cache publishes `flatColumns`; unprimed → unknown; directory-walk source → unknown even when
   primed. **A spy source asserting zero `schema()` calls during `JobValidator.validate`** is what pins
   O3 structurally.
5. **`ReadWorkerTest`** additions — `mergeSchemas: superset` over two CSVs with different headers emits
   every item under the union header with `<missing>` for absent columns, in manifest order;
   `mergeSchemas: strict` still fails naming both headers; one part's schema unknown under `superset`
   fails rather than guessing; **an A/B against Report** over the same two files (Report's
   `headerSuperset` path vs the reader's) yields the same column set.
6. **Report suites** green (the key change is the only Report-visible edit).

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test :kzen-auto-js:compileKotlinJs`.
2. Browser smoke (DS4's loop): fresh Job, File source with one explicit CSV, click **Columns** → chips;
   insert Read → Sort: the sort-key field offers the columns **with no run**; a directory-walk source →
   free text (stated behaviour); edit the CSV's header on disk → **Columns** again shows the new header
   (the staleness fix, visible); a two-file selection with different headers runs green under
   `superset` and shows the union in Summary.
3. Headless: `curl … action=schema` returns the header JSON.
4. As-built → analysis **§14** (including the superset cost number and O18's outcome); tick row 56;
   mark J3 rows 1–2 superseded in the master ledger if not already; delete this file.

## Risks & gotchas

- **IO on the walk** is the failure mode to guard structurally — `cachedSchema` must not fall through
  to a read; test 4's spy pins it. If a future source is tempted to "just peek", the answer is
  `itemType`, which is notation-only.
- **The superset changes DS3's behaviour.** Ship it behind `mergeSchemas` with the default flipped in
  this session, so the change is visible in notation and revertible per document.
- **`FilterIndex` path coupling** — Report's storage-manager "clear cache" UI lists that area; the new
  digest-named files must land under the same managed area so the purge still reaches them.
- **Size/mtime on network or virtual paths** — `BasicFileAttributes` may be unavailable; degrade to
  "don't cache", never to "cache without the key".
- **Do not add a row preview.** It will be asked for; §9 records why it is not there, and a source whose
  items come from a pipeline cannot serve one cheaply.
- **O18 is user-facing** — do not rename or delete a shipped document archetype without confirming.

## Out of scope (this session)

- Column *types* end to end (§6.3) — this session **consumes** a declared `TypeMetadata` for
  `itemType`, it does not make `HeaderListing` / `FlatFileRecord` / `ColumnValue` typed.
- Offline persisted summary as a column source — **J4** (the provider list leaves it a slot).
- Positional-name synthesis changes — none.
