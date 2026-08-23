# DS6 — design-time shape: `staticShape` / `inspectShape`, the schema cache service, superset normalization, editor dropdowns — implementation plan

> **Status: ready to execute.** Session 6 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§6.1** (two questions, two calls, and only one of them is the walk), **§6.2** (the stamped fingerprint
> and the cache-key bug), **§6.3** (column types and the shipped `DataFormat` document), **§5.3 + O19**
> (heterogeneous-header superset), §4 (`DataShape`, `DataOpener`), §9 (no row preview).
> Constituent plan: **—** (analysis doc is the record; delete on
> landing, as-built → analysis **§13**). Depends on **DS2, DS3, DS4**. Anchors verified 2026-08-21.
> Sized **M–L**; kzen-auto-jvm + kzen-auto-js + yaml.
> Ledger row 56. **Absorbs J3b** (the column pre-scan route + `JobUpstreamSchema` fallback +
> `SortSpecEditor` dropdown) — do not execute `J3_report-subsumption-a.md` steps 2–3 separately.

## Scope & goal

1. **`FileDataOpener.inspectShape(context, part)`** — the bounded header read (`ReportHeaderReader`
   behind `ColumnListingAction`) → `DataShape.Tabular(header)`, **through `SchemaCache` keyed on
   `(ref.id, format, encoding, size, modified)`** read from the part's stamped fingerprint
   (`DataRef.fingerprintOrNull()`); never a full scan; a part with no fingerprint is read but **not
   cached**.
2. **`SchemaCache`** (jvm service, `server/data/`) — `get(key): DataShape?` / `put(key, shape)`; the
   on-disk layout moves from `FilterIndex`'s `(location, coordinate)` path to a digest-named file under
   the same storage-managed area; **read-only for the walk** (`SchemaCache.peek(key)` — never falls
   through to a read).
3. **The cache-key fix** in `ColumnListingAction` — today `columns.csv` is keyed on `(dataLocation,
   pluginCoordinate)` only, so an edited file serves stale columns until the cache is cleared by hand.
   Report's callers pass size/mtime (they have `DataLocationInfo` / `Path` at hand) and share
   `SchemaCache`'s key; Report benefits too.
4. **`staticShape(role)`** — the static shape, answerable from **notation alone**, supplied by a declared
   schema document (item 6); null for a plain file opener with no declaration.
5. **Heterogeneous-header superset normalization (O19)** — replaces DS3's loud failure: resolve the
   superset from the pre-scan and normalize every item to it, exactly as Report's
   `DatasetInfo.headerSuperset()` does; behind `mergeSchemas: strict | superset` on both readers.
6. **The declared-schema route** — rename the orphaned `DataFormat` document to `DataSchema` (or delete
   it) and let a source name one, so `staticShape` can answer with no IO at all.
7. **`DataSourceActions` `action=shape`** (beside `resolve`) — `source=<location>`, `part=<lowered
   part>` → the opener's `inspectShape`, lowered as a `DataShape`.
8. **Editor consumers**: `JobUpstreamSchema` gains an ordered provider list; `SortSpecEditor` (and the
   other spec editors that take column names) offer a dropdown when columns are known with no run;
   source-card **Columns** chrome beside **Resolve**.

**Not in scope, and stated as a contract:** there is no row-level data preview (§9). `inspectShape`
must be answerable from a declaration or a *bounded* read; an opener that cannot answer cheaply returns
null.

## Dependencies & coordination

- **DS2–DS4 landed.** `FileDataSource` (stamping fingerprints), `FileDataOpener`, `DataOpenerLookup`,
  `DataSourceActions`, `ReadWorker`, the source card. **DS5** (`ReadPartWorker`) shares `DataReadCore`,
  so the superset normalization lands once in the core and both readers get it.
- **J3b is superseded by this session** — its findings §B–§E (definition repository, the
  `columns.csv` cache, `JobUpstreamSchema`, `SortSpecEditor` state) were verified 2026-07-19 and
  re-checked 2026-08-21; reuse them, do not duplicate the route it planned (the route is now
  `DataSourceActions action=shape`).
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
- **The fingerprint is already on the ref.** DS2's `FileDataSource.resolve` stamps `size` / `modified`
  from `DataLocationInfo` into `DataRef.attributes` (reserved keys, DS1 Pre-resolved 6); the cache key
  reads them back with `fingerprintOrNull()`. A `LogicDataSource` ref (DS8) may or may not carry them —
  unstamped → no caching, which is the honest degrade.
- **Report's superset is the precedent to copy**: `DatasetInfo.headerSuperset()` =
  `HeaderListing(items.flatMap { it.headerListing.values }.toSet().toList())`. Downstream, a record is
  read against a header via `RecordHeaderIndex.indices(headerListing)`, which returns `-1` for a column
  the record lacks and `CalculatedColumnEval`'s generated `columnValue` renders `<missing>`. So the
  machinery for a normalized wide row already exists end to end.
- **Why DS3 failed instead** (§5.3, and the reason this session can fix it): the reader was never the
  problem — `SummaryWorker.ensureInitialized` fixes its column set from the **first** record's header
  and `CsvWriterWorker` writes the header from the first batch, so mixed headers lose data *silently*
  downstream. A **superset resolved up front** removes that, which is why it needs the pre-scan and
  therefore this session.
- **`WorkerLane.flatColumns`** (null = unknown) and `JobValidator` / `JobValidationCache` — the walk is
  cached per graph-definition digest and shared with the editor's detached validation; the readers'
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
- **Detached from the client**: `ClientRestApi.performDetached(dataSourceActionsLocation, "source" to …,
  "action" to "shape", "part" to <lowered part>)`; `DataShape` has an `ExecutionValue` form (DS1).

## Pre-resolved questions

1. **Cache key** — `SchemaCacheKey(refId, format coordinate, encoding, size, modified)`; where the ref
   carries no fingerprint, **don't cache**. Computed in one place (`SchemaCacheKey.of(part)` beside
   `SchemaCache`); the on-disk layout is a digest-named file under the same storage-managed area
   `FilterIndex` uses, so Report's "clear cache" purge still reaches it — migrating old `columns.csv`
   entries is not worth it; they are simply unused (note in as-built).
2. **Who owns the cache** — `SchemaCache` (jvm, `server/data/`, a `@Service`), used by
   `FileDataOpener.inspectShape` (declaration → cache hit → bounded read → store) and by
   `ColumnListingAction` for Report (same key, same store). **`SchemaCache.peek(key)`** is the walk's
   read-only entry and **must not** fall through to a read. Nothing is added to the `DataOpener` SPI for
   caching.
3. **`staticShape` supply** — a source may declare a schema document nominally
   (`schema: {is: ObjectLocation, nullable: true, by: Nominal}` on the `DataSource` archetype), read as
   data through a conventions object (the `ContextConventions.descriptorOrNull` shape). The *opener*
   answers `staticShape(role)` from it — for the shared `FileDataOpener`, which has no source object,
   the declaration reaches it how? **Decision:** `DataOpenerLookup` gains a `staticShape(source:
   DataSource?, role)` entry that consults the *source's* declaration when the source is known (the
   `ReadWorker` case — it holds its source) and returns null otherwise (the `ReadPartWorker` case — no
   source in hand; its lane stays unknown until a declaration mechanism for plain refs is wanted, which
   is not now). `FileDataOpener` itself returns null from `staticShape`. Record this asymmetry in KDoc; it
   is §5.5's honest reduction.
4. **Resolution order in `JobUpstreamSchema`** — an ordered list of column providers evaluated until
   one answers: live summary → (J4 slot) → **declared schema** → pre-scan via the validation slice's
   `flatColumns` on the upstream lane → none. The editor asks "columns on my input lane", not "columns of
   that file" — the lane is the unit of schema, which is what the walk already computes.
5. **When the cache is primed** — by the source card's "Columns" action, by `Resolve` (optionally: also
   prime the first part of each unit, bounded), and by any run. A fresh document with no click and no run
   shows free text — acceptable and stated; the card makes priming one click.
6. **Superset semantics** — the superset is computed from the **pre-scan of every part in the resolved
   manifest** for the selected role, in manifest order, de-duplicated (Report's `toSet().toList()`), with
   the `attributes: columns` attribute names prepended once. Every emitted item is normalized to it. If
   any part's shape is **unknown** (cache miss and the opener declines a bounded read), fall back to
   DS3's behaviour: fail rather than guess. `mergeSchemas: strict | superset` on **both** readers
   (**default `superset`** once this lands) so a pipeline that *wants* the strict failure keeps it — and
   so the DS3 → DS6 behaviour change is visible in notation rather than silent. Implemented once in
   `DataReadCore`.
7. **Cost** — the superset costs one bounded read per part at resolve time. For a many-file selection
   that is a real cost; it is bounded (header only), cached, and only paid under `mergeSchemas:
   superset`. Measure on a 100-file selection and record the number in the as-built either way.
8. **`Object` shapes and the superset** — the superset applies to `Tabular` parts only; mixed
   `Tabular`/`Object` or differing `Object` types across parts keep DS3's failure under both modes.

## Step-by-step implementation

1. **`SchemaCache` + `SchemaCacheKey`** (jvm, `server/data/`) + the `ColumnListingAction` key fix;
   Report's callers pass size/mtime. Report's suites prove no behaviour change except staleness.
2. **`FileDataOpener.inspectShape`** (jvm) over the cache; `DataSourceActions action=shape`.
3. **The declared-schema route** — O18's rename (or its deferral), the `schema:` nominal attribute on
   the `DataSource` archetype, the conventions read, `DataOpenerLookup.staticShape(source, role)`.
4. **Readers**: `payloadFlow` under `items` publishes `staticShape` → `flatColumns` / `payloadType` and,
   for a source whose query **names its parts statically** (explicit `files`) and whose cache is primed,
   `SchemaCache.peek` columns; `mergeSchemas` knob on both; superset resolution + per-item normalization
   in `DataReadCore` replacing the failure. ⚠ A directory-walk source is unknown at walk time even when
   primed, because the walk must not resolve. Document it.
5. **Client**: `JobUpstreamSchema` provider list; `SortSpecEditor` dropdown branch; source-card
   "Columns" action rendering a chip list per part (calls `action=shape` per part of the last Resolve
   result; nothing if no Resolve has run — state it in the empty state).

## Tests

1. **`SchemaCacheTest` / `ColumnListingActionTest`** (jvm) — same file, same coordinate, edited content
   (size or mtime change) → fresh columns; unchanged → cache hit (no extractor call — count via a spy
   definer); an unfingerprinted part is read and **not** stored; `peek` never reads (spy asserts zero
   extractor calls).
2. **`FileDataOpenerTest`** additions — `inspectShape(part)` on a headered CSV returns
   `Tabular(header)`; on a headerless coordinate returns positional names; a second call is a cache hit;
   a **declared** schema (via the lookup) answers `staticShape` with **zero** file reads.
3. **`DataSourceActionsTest`** addition — `action=shape`.
4. **`JobValidatorTest`** additions — `ReadWorker(items)` over a source with explicit `files` and a
   primed cache publishes `flatColumns`; unprimed → unknown; directory-walk source → unknown even when
   primed. **A spy opener asserting zero `inspectShape` / `resolve` calls during `JobValidator.validate`**
   is what pins O3 structurally.
5. **`ReadWorkerTest` / `ReadPartWorkerTest`** additions — `mergeSchemas: superset` over two CSVs with
   different headers emits every item under the union header with `<missing>` for absent columns, in
   manifest order (attribute columns first under `columns`); `mergeSchemas: strict` still fails naming
   both headers; one part's shape unknown under `superset` fails rather than guessing; **an A/B against
   Report** over the same two files (Report's `headerSuperset` path vs the reader's) yields the same
   column set.
6. **Report suites** green (the key change is the only Report-visible edit).

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test :kzen-auto-js:compileKotlinJs`.
2. Browser smoke (DS4's loop): fresh Job, File source with one explicit CSV, **Resolve**, click
   **Columns** → chips; insert Read → Sort: the sort-key field offers the columns **with no run**; a
   directory-walk source → free text (stated behaviour); edit the CSV's header on disk → **Resolve** then
   **Columns** again shows the new header (the staleness fix, visible — the fingerprint changed); a
   two-file selection with different headers runs green under `superset` and shows the union in Summary.
3. Headless: `curl … action=shape` returns the shape JSON.
4. As-built → analysis **§13** (including the superset cost number and O18's outcome); tick row 56;
   mark J3 rows 1–2 superseded in the master ledger if not already; delete this file.

## Risks & gotchas

- **IO on the walk** is the failure mode to guard structurally — `peek` must not fall through to a
  read; test 4's spy pins it. If a future opener is tempted to "just peek", the answer is `staticShape`,
  which is notation-only.
- **The superset changes DS3's behaviour.** Ship it behind `mergeSchemas` with the default flipped in
  this session, so the change is visible in notation and revertible per document.
- **`FilterIndex` path coupling** — Report's storage-manager "clear cache" UI lists that area; the new
  digest-named files must land under the same managed area so the purge still reaches them.
- **Size/mtime on network or virtual paths** — `BasicFileAttributes` may be unavailable at resolve; DS2's
  resolver then stamps nothing, and this session's rule is "no fingerprint → don't cache", never "cache
  without the key".
- **Do not put caching on the SPI.** A `cachedSchema` member would leak cache policy into every opener.
  The cache is a service the file opener *uses*.
- **Do not add a row preview.** It will be asked for; §9 records why it is not there, and a source whose
  items come from a pipeline cannot serve one cheaply.
- **O18 is user-facing** — do not rename or delete a shipped document archetype without confirming.

## Out of scope (this session)

- Column *types* end to end (§6.3) — this session **consumes** a declared `TypeMetadata` for
  `DataShape.Object` / a declared header for `Tabular`; it does not make `HeaderListing` /
  `FlatFileRecord` / `ColumnValue` typed.
- A declaration mechanism for plain refs without a source in hand (`ReadPartWorker`'s static shape) —
  noted in Pre-resolved 3, not built.
- Offline persisted summary as a column source — **J4** (the provider list leaves it a slot).
- Positional-name synthesis changes — none.
