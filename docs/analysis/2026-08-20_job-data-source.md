# Job data sources — describing, resolving and reading data

> **Status: design exploration.** Written 2026-08-20 from a design conversation; the deliverable
> asked for was *the design*, not code. **Scheduled 2026-08-21** as `docs/plans/next/DS1`–`DS8`, **re-cut 2026-08-21b to `DS0`–`DS8`** (master-plan ledger rows 49–58, one session each; those files are the execution layer and this document stays the design record). The prior live plan for the Job
> flavour is [`../plans/2026-07-25_job-improvements.md`](../plans/2026-07-25_job-improvements.md)
> (phases J3/J4 are the Report-subsumption spine this feeds).
>
> Decisions are marked **[decided]** (settled in the conversation, with the argument recorded so it
> is not re-litigated) or **[open]** (a real fork still to call, with a recommendation). Per CC-20
> no line numbers are cited; anchors are class/file names.
>
> **Revised 2026-08-21** after walking the trivial case ("count the lines of one file") end to end.
> The revisions: a source-generic declarative `ReadWorker` is **in** (§5.2a) — the pure expression
> route made the trivial case four things and two Kotlin expressions; the file-selector UI binds on
> the **source object's attributes**, not a parameter default (O8 reversed, §6.4–6.5);
> multi-role units flow **whole** (§5.6); and the
> cross-cutting concerns this surfaced — dynamically loaded third-party objects, UI extension without
> recompiling, and design-time resource lifetime — live in
> [`2026-08-21_extension-points.md`](2026-08-21_extension-points.md) rather than here.
>
> **Revised again 2026-08-21b** after a code-level review of the DS1–DS8 plans against the tree.
> Nine corrections and five design changes; **§13 is the compact record of what changed and why** —
> read it first if you knew the previous draft. The headline changes: the SPI is **non-suspend and
> takes a `DataScope`** (§4), which is also where a stateful source reaches a Context and where the
> design-time session will plug in; run-time source access comes from the **run graph via a nullable
> structural reference**, not from `GraphInstanceCache` (§6.5); `DataRef.source` is a **minted durable
> id**, not an `ObjectStableId`, which is session-scoped (§3.3); the type-visibility whitelist behind
> every inferred payload type is a **bug and is replaced by a predicate** (§5.5a); `DataRows` is
> renamed **`DataItems`** and is a constrain-once `Sequence` (§4); and the trivial case is **three
> cards, not two** (§5.2a).
>
> **Revised a third time 2026-08-23** after an independent design review
> ([`2026-08-23_job-data-source_review.md`](2026-08-23_job-data-source_review.md)) whose central finding
> was verified against the tree: the 2026-08-21b `DataScope` (non-suspend SPI) **cannot delegate to
> `JobControl.runBlockingIo` / `host`, which are `suspend`** — D1 fixed one compile error by creating a
> worse one, and DS2/DS3/DS5/DS8 all built on the broken bridge. **§15 is the compact record of this
> pass** — read it first if you knew the 2026-08-21b draft. The headline changes: `resolve` and `open`
> are **`suspend`** and take a `DataContext` (§4); **expressions never initiate source I/O** — the
> readers are `ReadWorker` and `ReadPartWorker`, and objects-in-expression-scope / `items()` helpers /
> `ExpandWorker` leave the critical path (§5, §6.5); **source and opener are split** and **file refs are
> plain** (`source = null`), so the `DataSourceId` minting machinery is **deferred** until a
> provider-bound source exists (§3.3, §4); `DataItems` becomes a plain pull-reader **`DataCursor`**
> driven by the worker inside `runBlockingIo` (the `CsvRecordReader` precedent, §4); schema is a
> **`DataShape`** with a notation-only `staticShape(role)` and an effectful `inspectShape` (§6.1);
> design-time resolve is **one generic detached action**, not `DetachedAction` on every source (§4);
> the `DataSources` document is **deferred** (§6.4a).

## 1. What this is for

Job is intended to subsume Report. Report's input side is a *file selection* — browse a directory,
pick files, assign each a format, optionally group them by a filename regex. That model cannot
express the cases an advanced ETL port needs:

- **Parameterized resolution.** "Process 2026-01-01 through 2026-01-31" — the file set is a
  *function of run arguments*, not a list frozen into notation at edit time.
- **Multi-part units.** A day's work is a main dataset *plus* its reference data, which must be
  resolved together and processed as a unit.
- **Non-file sources.** A DB query or an API endpoint is not a path, but it is still "a thing you
  resolve, learn the schema of, and read".
- **Composition across runs.** Invoke a Job for one input, take its output, feed that to the next
  Job. That requires a *value* that describes data, not just a config attribute.
- **Schema at design time.** Knowing a CSV's columns before running is what lets expressions be
  validated and editors offer dropdowns instead of free text.

The goal is one model that covers all five, is customizable at each seam, and stays ergonomic for
the trivial case (one CSV file, one card).

**Out of scope here.** Column *types* beyond today's text-canonical `HeaderListing` (§6.3 explains
why that is a separate arc — and which shipped, orphaned document is its landing site); Report's
retirement sequence (J4 owns it); fan-out topology (J6); a Report → Job conversion path (not wanted,
§9); per-unit parallelism (a performance topic, §13).

## 2. The shape already in the tree

Most of this exists — fused into `ReportDocument` and its spec classes rather than factored. The
factoring is the work; the concepts are largely already right.

| Concern | Where it lives today | Verdict |
|---|---|---|
| Browse a directory | `FileListingAction` (kzen-auto-jvm `…report/service/`), `/file-listing` route, `FileListingHandler` | Already flavour-neutral; keep |
| Selection config | `InputSpec` / `InputBrowserSpec` / `InputSelectionSpec` / `InputDataSpec` (kzen-auto-common) | Right split of location-vs-format; too narrow otherwise |
| Resolved dataset | `DatasetInfo` = `List<FlatDataInfo>`; `FlatDataInfo` = location+encoding, `HeaderListing`, plugin coordinate, group | **This is the abstraction to generalize** |
| Grouping | `GroupPattern` (filename regex) → `DataLocationGroup(String?)` | Concept right, shape too narrow (one nullable string) |
| Schema pre-scan | `ColumnListingAction` + `ReportHeaderReader`, cached as `columns.csv` | Keep; cache key needs work (§6.2) |
| Byte source | `FlatDataSource` / `FlatDataStream` / `FileFlatDataSource` | Already a clean seam; keep as-is |
| Format plugins | `ReportDefiner` / `ReportDefinition` / `ReportDataDefinition` / `DataFramer` (kzen-auto-plugin), driven by `ReportInputChain` | Keep; this is the "how to parse" axis |
| Job readers | `CsvReaderWorker`, `MultiFileReaderWorker`, `MultiFileInputEditor` | Replace with the source-generic `ReadWorker` (§5.2a) + `FileDataSource`'s attribute editor (§6.4) |
| Expression type inference | `ExpressionReturnTypeInference` (`visibleBuiltins` + `ObjectRegistryScan`) | ⚠ **carries a bug this design would have tripped on** — see §5.5a |
| Static schema flow | `WorkerLane(payloadType, flatColumns)` + `WorkerBase.payloadFlow` | The integration point for design-time schema |
| Element model | `JobMessage(payload, flat: FlatView?)` | The carrier a manifest rides on |
| Logic boundary | `JobControl.parameters/parameter/yieldResult/host`, `JobSignatureCapability` | Already gives parameters-in / results-out |

### 2.1 Two things Report got right, that carry forward

1. **A resolved dataset is a flat list of self-describing items, not a map keyed by group.**
   `DatasetInfo` holds `List<FlatDataInfo>` and each item carries its own `group`. Order is
   preserved, an item is meaningful alone, and nothing has to be a hashable composite key.
2. **Location is orthogonal to format.** `InputDataSpec` pairs a `DataLocation` with a
   `CommonPluginCoordinate`, and `actionDefaultFormat` infers the coordinate from the extension when
   the user does not choose. *Where* and *how to parse* are independent axes and must stay so.

### 2.2 Three gaps, and why the current Job worker is unsatisfying

Report's gaps: the group is a single nullable `String`; an item has exactly one location (no roles);
and resolution happens **only at edit time**, so nothing can be parameterized.

Job's `MultiFileReaderWorker` inherits all three and adds its own. It takes `paths: List<String>`,
and `MultiFileInputEditor` performs the directory browse at edit time, writing a frozen ordered path
list into notation with a raw `UpsertAttributeCommand` — the editor's own comment concedes there is
"no `paths` spec class". Consequences:

- The selection cannot be a function of run arguments.
- No per-file format or encoding — the worker hardcodes a `delimiter` + `header` pair for all files.
- No grouping, so per-source-file output grouping is unreachable.
- No schema, so every downstream expression falls back to `KotlinSyntaxValidator`'s syntax-only check.
- The resume cursor keys on `paths` equality, which is only coherent *because* the set is frozen —
  the moment resolution becomes dynamic, that check is comparing the wrong thing (§8.1).

**So "how do I implement Report-style file selection as a Worker?" is the wrong question.** File
selection is not worker behaviour at all: it is *configuration on a source object* (§4 — the file
source's query attributes, with the browser as that object's ordinary attribute editor, §6.4). What a
worker does with it is *resolve and read*, and that worker is **source-generic**: `ReadWorker`
(§5.2a) reads a source; `ReadPartWorker` (§5.3) reads one part of a unit already on a lane. Nothing in
either knows it is a file. *(Revised 2026-08-23: the expression route — `FormulaSourceWorker` +
`ExpandWorker` over `sales.units()` / `items(part)` — is withdrawn; §15 D7.)*

## 3. The model

### 3.1 The four concerns to keep apart

| Concern | Question it answers | Lives in |
|---|---|---|
| **Query** | what do I want? | `DataQuery` — config, may reference run parameters |
| **Resolve** | what does that actually name, right now? | `DataSource.resolve(context)` → `DataResolveResult(manifest, diagnostics)` — `suspend` (§4) |
| **Describe** | what shape is it? | `DataOpener.staticShape(role)` → `DataShape?` (notation-only, walk-facing) and `suspend inspectShape(context, part)` → `DataShape?` (bounded read, editor-facing) (§6.1) |
| **Open** | give me the items | `suspend DataOpener.open(context, part)` → `DataCursor`, a plain pull reader the worker drives inside `runBlockingIo` (§4) |

Report fuses query+resolve into `FileListingAction` (edit time only) and describe into a separate
action with its own cache. Splitting them is what makes parameterized resolution and pluggable
non-file sources possible at all. *(Revised 2026-08-23 — resolve is on the **source**, describe and
open are on the **opener**; a file source is only a source, and a shared file opener reads its plain
refs. §4, §15 D8.)*

### 3.2 Value types

```kotlin
// The DURABLE identity of a PROVIDER-BOUND source object (JDBC, an authenticated API) — a value minted into
// the object's own notation once, at insert, never rewritten by rename / move / restart. NOT an ObjectStableId
// (§3.3). [decided 2026-08-21b] The TYPE lands in DS1 so the model shape is final; NOTHING MINTS ONE until the
// first provider-bound source exists — every file ref is plain (§3.3, revised 2026-08-23).
value class DataSourceId(val value: String)

// A reference to one readable thing. PLAIN (source == null) when the ref is self-contained — a file path —
// which is every ref in v1; SOURCED when it can only be opened by its provider. [decided; revised 2026-08-23]
data class DataRef(
    val source: DataSourceId?,                 // null = plain / self-contained (the shared file opener reads it)
    val id: String,                            // canonical, digestible, displayable — a path for a file
    val attributes: Map<String, String> = mapOf()   // addressing extras + the FINGERPRINT a resolver stamps
                                                    // (reserved keys `size`, `modified` — §8.1, §6.2)
): Digestible

// One readable thing inside a unit, with its decoding.
data class DataPart(
    val role: DataRole,                        // "main", "reference", … ; a plain interned name
    val ref: DataRef,
    val format: CommonPluginCoordinate?,       // null = infer (extension / source default)
    val encoding: CommonDataEncodingSpec?      // null = source default / detect
): Digestible

// One unit of work: what gets processed together.
data class DataUnit(
    val attributes: Map<String, String>,       // {date: 2026-01-01} — text-canonical; insertion order is
                                               // PRESENTATION ONLY (digest canonicalizes by key — §15 C13)
    val parts: List<DataPart>                  // ordered (semantic); partsOf(role) filters
): Digestible

// The resolution of a query at a point in time.
data class DataManifest(
    val units: List<DataUnit>
): Digestible

// What a resolve returns — the manifest plus what it could not / did not include. [added 2026-08-23, §15 D10]
data class DataResolveResult(
    val manifest: DataManifest,
    val diagnostics: List<DataDiagnostic>       // skipped units, unsupported extensions, warnings — text-canonical
)
```

`DataQuery` is deliberately **not** a fixed type — it is the source object's own configuration
attributes (a directory + filter; a date range + path pattern; a SQL statement + bind parameters).
Fixing a universal query shape would be the same mistake as fixing the ref shape.

### 3.3 Why `DataRef` is opaque and source-relative **[decided]**

The alternative was to use `DataLocation` (file path | URL | unknown) directly. Rejected because the
ETL port includes sources that are not location-addressable — a DB table with bind parameters, an
API cursor. Making the ref opaque means the source is the only thing that interprets it, which is
exactly the "fully general and customizable" property asked for.

The cost is that a `DataRef` alone is not human-meaningful without its source. Mitigations:

- `id` is required to be a **canonical string**: stable, digestible, displayable, and round-trips
  through notation and `ExecutionValue` unchanged. A file source mints `C:/data/2026-01-01.csv`; a
  SQL source mints something like `orders?day=2026-01-01`. The user always sees *something*.
- `source` is a **minted durable `DataSourceId`**, so a ref carried across a Logic boundary — or
  lowered into a parameter default, a persisted result, or a trace — still resolves back to the object
  that can open it **after that object is renamed, moved, or the process restarted**
  **[decided 2026-08-21b, superseding the `ObjectStableId` of the previous draft]**.

  The rejected options, and why:

  - **`ObjectLocation`.** Not rewritten by kzen-lib's refactors when it sits inside a *value* (only
    notation `ObjectReference`s are), so it dangles on the first rename.
  - **`ObjectStableId`.** The previous draft's answer, and it is **not durable**. `ObjectStableMapper`
    is an in-memory, session-scoped map: `objectStableId(location)` mints
    `ObjectStableId(location.asString())` and maintains `id ⇄ location` across renames *within the
    process*; `snapshot()` / `seed()` exist to sync the **client's** mapper (`/object-stable/snapshot`),
    not to persist. So an unrenamed ref resolves after a restart only because the id string happens to
    equal the location string — and a **renamed** one resolves in-session and is dead after a restart,
    with no refactor to catch it. That is exactly the case DS7 creates (a writer yields a `DataRef` as a
    persisted run result) and the case a notated parameter default creates.
  - **Rewrite-on-rename.** Tractable for a ref sitting in *notation*, unreachable for one already
    written to disk as a run result.

  The minted id, concretely: the `DataSource` archetype carries an `id: ""` attribute, assigned a UUID
  by the editor's insert command, hidden from the card (the signature-managed-attribute pattern) and
  never touched by rename or move. Resolution is a graph scan for the object whose `id` matches, cached
  by notation digest — the `ObjectRegistryDocument.scanCache` shape (Caffeine keyed on `Digest`). A
  document copy/paste duplicates ids; that is **reported** by validation rather than prevented (the
  `LogicContextAnalysis` duplicate-key precedent). A blank `id` (hand-authored notation) degrades to
  resolve-by-location with a warning.

  Note what this removes: DS1 no longer needs an `ObjectStableId` `KSerializer`, and kzen-lib stays
  untouched for a better reason than before.

  **Deferred 2026-08-23 [decided — §15 D8].** The mechanism above is *right* and is *not built yet*. A
  file ref needs no provider: path + effective format + encoding is enough for a shared file opener, so
  `FileDataSource` (and `LogicDataSource`) mint **plain** refs, and a persisted file ref is a path — durable
  by construction, no id needed. Requiring every file ref to name its `FileDataSource` added identity
  coupling without adding read capability, and it pulled mint-on-insert, the id→location scan, duplicate-id
  validation and a rename-then-restart regression into DS2/DS4/DS7 for nothing the v1 arc exercises. So:
  the `DataSourceId` **type** lands in DS1 (so the model shape is final and `source` is already nullable);
  the **minting, scan and validation land with the first provider-bound source** (JDBC / API) — the
  sentence that justifies them. A sourced ref reaching a reader before then is a clear failure ("provider-
  bound refs are not supported yet"), not a silent plain-path fallback.
- `DataLocation` converts to and from a `DataRef` with `source = null` — the common case stays as
  cheap as it is today, and everything already written against `DataLocation` (browse listings,
  `FilePath` arithmetic, the `/file-listing` route) keeps working unchanged.

### 3.4 Why a flat list of self-describing units, not `Map<Group, Set>` **[decided]**

The sketch that started this was
`ResourceBatch(Map<ResourceGroup, ResourceSet>)` with `ResourceGroup(Map<ResourceAttribute, ExecutionValue>)`
as the key. Rejected, for four reasons:

1. **Order is load-bearing.** Every reader's resume cursor is positional — `MultiFileReaderWorker`
   carries `(fileIndex, position)` across a live-edit migration. A map has no order to index into,
   so a resumed read would have to re-derive one, and any change in iteration order silently
   corrupts the resume.
2. **A composite key of typed values is expensive to be correct about.** Equality, hashing, digest,
   notation round-trip and wire encoding all have to be defined for the key type before the
   container is usable. A record with an attribute *field* needs none of that.
3. **`ExecutionValue` is the wrong currency at run time.** It is the wire/trace value tree; the
   run-time lane is `JobMessage(payload: Any?, flat: FlatView?)`. Putting `ExecutionValue` inside
   the run-time model would import serialization concerns into the hot path. It belongs at the
   boundary only (§7.2).
4. **A list of units *is a lane*.** One `JobMessage` per unit means the manifest flows through an
   ordinary Job channel, and everything already built composes with it — filter it, add computed
   columns to it, feed it to `RunWorker`, bind one as a parameter, display it as progress. A nested
   map has to be passed out-of-band and nothing else can touch it.

The same argument applies one level down, which is why `DataUnit.parts` is an ordered `List<DataPart>`
with the role *on* the part, rather than `Map<DataRole, List<DataPart>>`. It keeps one shape
throughout, keeps read order deterministic across roles, and `partsOf(role)` is the accessor that
makes the map form unnecessary.

Note what falls out: `DataUnit` with attributes-plus-parts is exactly `FlatDataInfo` generalized —
`DataLocationGroup(String?)` widened to an attribute map, and one location widened to a role-keyed
list. **This design is "generalize `DatasetInfo`", not "invent a parallel container".**

### 3.5 Attribute values are text-canonical **[decided, revisit only with evidence]**

`DataUnit.attributes` and `DataRef.attributes` are `Map<String, String>`, not typed values.

For: free equality/digest (needed for the resume compare in §8.1 and the schema cache key in §6.2);
free notation and `ExecutionValue` round-trip; direct `${date}` substitution into output path
patterns; and it matches how the whole flat lane already works — `FlatFileRecord` is text and
`ColumnValue` converts at expression time.

**Correction (2026-08-21b).** The previous draft added "a `Map`-shaped payload auto-flattens to keyed
columns in `JobMessage.flatView()`, so unit attributes become *columns* for free, which is how grouped
export (J4) falls out without a special case." **That is not what happens.** Under `emit: items` the
payload is a `DataUnit`, which is not a `Map`, so `flatView()` materializes the single synthetic
`value` column via `ColumnValue.toText`; under `emit: units`… same. And under `emit: items` the message
is `JobMessage.ofFlat(fileHeader, record)`, where `flatView()` is never consulted at all. **Nothing
carries unit attributes onto the item lane.** So Report's `groupBy` regex → group → grouped export has
no free path here.

What is true: the attributes reach a downstream lane only if something *puts* them there. The 2026-08-21b
answer was an expression (`emit: units` → `ExpandWorker` / `FormulaWorker`); with the expression route
withdrawn (§15 D7) the honest owner is the **reader itself**: `ReadWorker` / `ReadPartWorker` gain
`attributes: ignore | columns` — under `columns`, each emitted flat record is widened with the unit's
attributes as leading columns (header = attribute names + part header). The reader *knows* it is reading a
unit, so this is not a class switch; it is ~20 lines; and it is exactly what Report's `groupBy` regex →
group column did and what J4's grouped export consumes. **`groupBy` parity therefore lands with DS3**,
and §9's parity table says so. *(Revised 2026-08-23.)*

**Attribute order, settled 2026-08-23 (§15 C13).** Insertion order is kept for display (`LinkedHashMap`),
but it is **presentation only**: `Map` equality is order-insensitive, so an order-sensitive digest would
make two equal units digest differently. The digest canonicalizes by sorted key.

Against: an expression that wants `unit.date` as a real date has to parse. That is the same cost
every flat column already pays, so it is not a new class of problem. If typed attributes are ever
justified, they arrive with the column-typing arc (§6.3), not before.

## 4. `DataSource` is an object with a callable API, not a Worker **[decided; SPI revised 2026-08-23]**

```kotlin
/** RESOLVE — the variable part. Every source has one. */
interface DataSource {
    /** Resolve the configured query into a point-in-time manifest (§8.1) plus diagnostics. */
    suspend fun resolve(context: DataContext): DataResolveResult
}

/** DESCRIBE + OPEN — for refs that need this provider to be read. A file source is NOT one (§3.3). */
interface DataOpener {
    /** Open a part. Returns a handle the CALLER drives (see [DataCursor]). */
    suspend fun open(context: DataContext, part: DataPart): DataCursor

    /** The shape of what `role` yields, answerable from NOTATION ALONE — never IO; the walk reads this (O3). */
    fun staticShape(role: DataRole?): DataShape? = null

    /** The shape of one concrete part, from a DECLARATION or a BOUNDED read (a header row, `LIMIT 0`). */
    suspend fun inspectShape(context: DataContext, part: DataPart): DataShape? = null
}

/**
 * One open part: a PLAIN PULL READER — not suspend, not a Sequence. The owning worker drives it inside
 * `JobControl.runBlockingIo` one `next()` per blocking unit, exactly as `CsvReaderWorker` drives
 * `CsvRecordReader` today; so every read stays counted by the CountingDispatcher and interruptible by
 * cancel / migrate, the worker carries the handle across a live edit and drives it with its NEW control,
 * and an implementer wraps a BufferedReader without learning coroutines. [decided 2026-08-23, §15 D8]
 *
 * `shape is Tabular` ⇒ EVERY item is a `FlatFileRecord` under that header (the reader emits `ofFlat`);
 * otherwise items are payload objects (`ofPayload`). An interface member, not a class switch (CC-17).
 */
interface DataCursor: Iterator<Any?>, AutoCloseable {
    val shape: DataShape?
}

/** The per-call environment a source / opener runs in. [replaces `DataScope`, 2026-08-23] */
interface DataContext {
    /** A run parameter / detached request parameter, BY NAME (never positional — O13). */
    fun argument(name: String): Any?

    /** The run's Context registry (`Execution.resourceValue`), or the design-time session. Null when absent. */
    fun contextValue(key: String): Any?

    /** Quiescence-visible blocking offload: `JobControl.runBlockingIo` at run time, `Dispatchers.IO` at design time. */
    suspend fun <R> blocking(block: () -> R): R

    /** Invoke a child Logic with NAMED arguments — `JobControl.host` at run time (§4.4); design time throws. */
    suspend fun host(instructions: ObjectLocation, arguments: TupleValue): TupleValue
}

/** Tabular structure vs Kotlin payload type — two different things the 2026-08-21b SPI called "schema". */
sealed interface DataShape {
    data class Tabular(val header: HeaderListing): DataShape      // widens to typed columns later (§6.3)
    data class Object(val type: TypeMetadata): DataShape
}
```

**Why `resolve` and `open` are `suspend`, and why a cursor is not [decided 2026-08-23, reversing D1 — §15
C10/C11].** The 2026-08-21b draft made every SPI call non-suspend and put a non-suspend `blocking` /
`host` on a `DataScope`. That cannot be implemented: `JobControl.runBlockingIo` and `JobControl.host` are
both **`suspend`** (`EngineJobControl` delegates to `Execution.blocking` / the child-logic host), so a
non-suspend scope method has no legal way to reach either — the only options were `runBlocking` (holds an
engine thread, defeats the offload) or wrapping the *whole* call in one `runBlockingIo` from outside (then
`blocking` is identity and `host` is unreachable, which kills `LogicDataSource`). D1's own premise was
true — a suspend `units` cannot go *inside* `runBlockingIo` — but the conclusion was backwards. The right
reading: `resolve` is suspend; the *source* calls `context.blocking { … }` around its own blocking parts
(the directory walk, a JDBC round-trip) and `context.host(…)` when it is a Logic. That is exactly how
`RunWorker` already uses suspend `host`, and `DetachedAction.execute` is suspend, so design time needs
nothing new. `FileListingAction.scanInfo`'s internal `withContext(Dispatchers.IO)` is still the wrong
dispatcher under a run; the blocking-core split (`scanInfoBlocking`) stands and the source calls it through
`context.blocking`.

The **cursor** is the deliberate exception, and the existing reader is the precedent: `CsvRecordReader`'s
KDoc — "a plain pull reader the Worker drives inside `control.runBlockingIo`, one `readRecord` per
blocking unit." A `Sequence` whose `next()` did file I/O would run that I/O on the fixed engine thread
(DS3 said "iteration itself is plain … like `CsvReaderWorker`'s reads" — it is not; every `readRecord`
there is offloaded), holding the thread and escaping cancel/migrate interruption. A suspend `next()` (the
review's proposal) would work but makes the cursor capture a context that is **stale after a live-edit
migrate** (the resumed worker has a new `JobControl`) and makes every third-party cursor a coroutine
citizen. A plain `Iterator` the *worker* drives through *its* control solves both, and the worker may
batch several `next()` calls per offload if a profile ever asks. `DataCursor` replaces `DataItems`; with
expressions out of the read path (§5) the `Sequence` ergonomics it was chosen for no longer buy anything.

The **source / opener split** (§15 D8): resolution is the variable part and every source has it; describe
+ open are needed only where a ref cannot be read without the provider (JDBC, an authenticated API, an
object store). A file part is self-contained — path + format + encoding — so `FileDataSource` implements
*only* `DataSource` and a **shared `FileDataOpener`** reads every plain ref, from any source. One opener
registry (`DataOpenerLookup`: `ref.source == null` → the file opener; otherwise → the owning source, which
must be an opener) is the single dispatch, owned by the readers. A JDBC source implements both interfaces
on one object; `LogicDataSource` (§4.4) implements only `DataSource`, mints plain refs, and needs no
`items` of its own.

The context earns its place three times over. `argument(name)` is the one naming convention for run
parameters (O13). `contextValue(key)` is how a stateful source reaches a resource **without holding one**
— see the lifetime bullet below. And `blocking` / `host` are the seams above.

A Worker exists only during a run, and this is needed in **two** contexts:

1. **Design time** — the editor asks "what does this query resolve to?" and "what columns?" with no
   run in sight, over a detached action (Report does exactly this today with `FileListingAction` /
   `ColumnListingAction`). **One generic action** — `DataSourceActions` (a detached object taking
   `source=<location>`, `action=resolve | shape`) instantiates the source through `GraphInstanceCache`,
   builds a `DesignDataContext`, calls it and lowers the result — so a source carries no UI protocol and
   the card is generic for free. *(Revised 2026-08-23 from "every source is a `DetachedAction`" — §15 D10.)*
2. **Run time** — from the **two readers** (`ReadWorker` resolves and reads a source; `ReadPartWorker`
   opens one part of a unit already on a lane — §5.2a, §5.3), which own the context, the handle, the
   cursor, cancellation, and quiescence accounting. **Never from an expression** (§15 D7): source
   resolution and reading are effects, and an expression that performed them would hide I/O, cancellation
   and resource ownership inside generated code. Expressions see *materialized* values — a `DataUnit` on a
   lane, a record — and nothing else.

Note what (2) means: there are exactly two data-specific workers, no data-specific port, and no
data-specific notation shape beyond the source object's own attributes. The source supplies
*configuration* (which directory, which pattern, which connection) and *resolution*; the opener supplies
*describe* and *read*; the readers supply the wiring onto ordinary lanes.

Being a notation object is still the customization seam and is still worth the object-ness: a
third-party source is another archetype in the graph, discovered through the object registry and
classified **by capability, never by class name** (CC-17) — the `JobServeCapability` /
`JobSignatureCapability` pattern. It also gives the editor something to bind a browse/preview UI to,
which a bare function in an expression would not.

Two consequences of "design time" being on the list, both general rather than data-specific:

- **The source object is NOT a `DetachedAction`; one generic action calls it [revised 2026-08-23].** The
  editor's resolve-preview / shape calls go through `ModelDetachedExecutor.execute(actionsLocation,
  request)` on the single `DataSourceActions` object, which instantiates the named source by location
  (`GraphInstanceCache`, the `FileListingAction` / `ColumnListingAction` precedent) and calls `resolve` /
  `inspectShape`. Card chrome in the Job editor (preview the resolved manifest, show columns) is generic
  over sources because it only speaks this one protocol, and a source author implements nothing for it.
- **Resource lifetime — a source BORROWS, it never OWNS [decided 2026-08-21b].** A file source is
  stateless; a JDBC / API source needs a connection. It does **not** hold one. It declares the Context
  it uses (`is: ObjectLocation, nullable: true, by: Nominal` — the `ContextBinder.binds` shape) and
  reads the value through `DataContext.contextValue`. At run time that is the Context registry the engine
  already has: `Execution.resource(key, policy, value, closer)` opens with a declared
  `ResourceClosePolicy`, `Execution.resourceValue(key)` reads, and the read walks ancestors
  (`RunEngineContextTest.resourceValueReadableFromHostedChildViaAncestorWalk`), so a hosted child Job
  sees its caller's connection.

  This is what keeps the object itself stateless, which matters twice: `GraphInstanceCache`'s reuse
  contract stays satisfied at design time, and **`GraphCreator.createGraph` instantiates every object in
  the Job document on every run** — used or not — so source construction must be side-effect free
  regardless. (Corollary worth writing down: an object in the `sources:` branch that *fails* to create
  fails the whole run, since `createGraph` throws on any failure. Attributes must define when blank and
  `units` must fail with a clear message instead.)

  Design time then shrinks from "invent a resource model" to "a `DataContext` implementation whose
  `contextValue` has a project-scoped owner". v1 is request-scoped open/close inside a
  `DesignDataContext` — exactly what O12 already recommends — and **no source changes** when the explicit
  `DesignSession` of [`2026-08-21_extension-points.md` §3](2026-08-21_extension-points.md) arrives.

### 4.1 Third-party sources — dynamically loaded objects, not a source-specific SPI **[decided]**

A first draft of this revision proposed a `DataSourceDefiner` SPI beside the `ReportDefiner` format
SPI, because `@Reflect` objects are instantiated through the compile-time registry. That is the wrong
level: the need is general — *arbitrary* third-party Custom objects, of which a source is one kind —
and the server already has the hook: `GlobalMirror.register(delegate)` appends a fallback
`ClassMirror`, so a plugin jar compiled with `kzen-lib-reflect-ksp` brings its own `ModuleReflection`,
is opened on a `URLClassLoader` at project startup (the `PluginDocument` precedent), registers its
mirror, and contributes its yaml notation. Reload the project to pick up a change. A third-party
source is therefore exactly what §4 says — another archetype — with no data-specific plumbing. The
open half is the **UI** for such objects, which is the subject of
[`2026-08-21_extension-points.md`](2026-08-21_extension-points.md) §2; the short version is that UI
extension is *server-driven* (generic editors + a standard detached query protocol) with Web
Components as the escape hatch, so a source ships zero JS in the common case.

**Definition time is deliberately absent from that list.** An earlier draft had `payloadFlow` calling
`schema()` to publish `flatColumns`; that would mean IO during the payload-type walk, which runs on
every notation revision (O3 says never). §5.5 records what is lost and what replaces it.

### 4.2 Two orthogonal extension axes, kept orthogonal

| Axis | Question | Seam | Examples |
|---|---|---|---|
| **Source** | where does the data live, and what does a query name? | `DataSource` archetype | directory glob, dated path pattern, HTTP, S3, JDBC |
| **Format** | how are those bytes parsed into records? | existing `ReportDefiner` plugin SPI, keyed by `PluginCoordinate` | CSV, TSV, fixed-width, a third-party binary format |

Report already separates these and must keep doing so: a dated-path source over a third-party format
should require no new code in either. `DataPart.format` is the join between the axes, resolved by the
source's default when the user does not pin one.

### 4.3 A `DataRef` is self-opening, so there is no `ParameterDataSource` **[revised 2026-08-23]**

An earlier draft wanted a `ParameterDataSource` — a source whose "query" is a Job parameter holding a
`DataUnit` — so a child Job could read the unit its caller passed. That construct is still unnecessary,
but the mechanism changed with §15 D7: the child's parameter *is* the `DataUnit`; `FormulaSourceWorker("unit")`
puts it on a lane as a single payload (a non-stream type emits once — existing behaviour); and
**`ReadPartWorker(role: "main")`** opens the part. The dispatch on `DataRef.source` lives in the reader's
`DataOpenerLookup` (§4) — plain ref → the shared file opener; sourced ref → its provider — not in generated
expression code.

This is where the ref (§3.3) pays operationally: a unit handed across a Logic boundary is **self-opening**.
Nothing at the receiving end needs to be configured with where the data came from — and for v1, where every
ref is a plain path, "self-opening" costs nothing at all.

### 4.4 Authoring a source without writing Kotlin — `LogicDataSource` **[decided in shape 2026-08-21b]**

§2 criticises `ReportDocument` for fusing query + resolve + describe. The 2026-08-21b `DataSource` fused
resolve + describe + open too; the 2026-08-23 split (§4: `DataSource` = resolve, `DataOpener` = describe
+ open, §15 D8) answers the criticism structurally, because the three parts have very different
variability:

- **Resolve** is the variable part. It is a parameterized computation returning a list — which is
  exactly what a **Logic** is.
- **Open** is not variable at all for anything file-shaped: a byte source plus a format plugin, both of
  which already exist and work (`FlatDataSource` + `ReportDefiner` / `ReportInputChain`) — the shared
  `FileDataOpener`.
- **Describe** is a declaration (§6.3) or a bounded read — on the opener.

The fusion stays *available* (a JDBC source implements both interfaces on one object, because resolution
and reading share a connection) and is never *imposed*. So one shipped implementation opens the extension
point:

```
LogicDataSource(instructions: <Script | Flow | Job>, arguments: [from, to])
    resolve(context)  = context.host(instructions, named arguments from context.argument(name))
                        → main component: List<DataUnit> (plain refs) → DataResolveResult
    // no open / describe: the parts it mints are plain, the shared file opener reads them
```

A user authors resolution as a **Script** that returns a list of `DataUnit`s, and gets tracing,
stepping, breakpoints and pause-on-error for free — `JobControl.host` already does exactly this for
`RunWorker`. The parts it mints are plain refs (`source == null`, O4's first-class case), so opening needs
no Kotlin and no new SPI.

Two prerequisites, both already implied elsewhere: `DataContext.host(instructions, arguments: TupleValue)`
— **named** arguments, a new `JobControl.host` overload beside the single-positional one (the existing
implementation already builds a `TupleValue`; §15 C14 — the 2026-08-21b plan's "one map as the first
positional argument" did not match its own example Script, which declared two parameters); design time
throws, so such a source honestly reports "resolve requires a run" in its card, consistent with §6.2's
cost discipline. And expression-constructible model types — the §5.5a visibility fix plus a small helper
family (`DataUnit.of(attributes, parts)`, `DataPart.ofPath(role, path)`).

**This is a better final session than a hand-written dated-path source** (§12): the dated case becomes a
shipped example Script over `LogicDataSource`, proving the extension point instead of adding a ninth
Kotlin class. Keep a Kotlin `DatedPathDataSource` in reserve if date iteration in a Script proves
clumsy — **O16**.

## 5. Workers — what already exists, and the one real gap

> **Revised three times.** An earlier draft proposed a `DataSourceWorker` and a `DataSplitWorker`; the
> second should be a domain-free expression worker (§5.3, as then written). The first was then rejected
> as "already exists" (`FormulaSourceWorker`) — and the 2026-08-21 walk-through of the trivial case
> reinstated it in **source-generic** form as `ReadWorker` (§5.2a). **2026-08-23 (§15 D7):** the
> expression route — `FormulaSourceWorker("sales.units()")` + `ExpandWorker("items(…)")`, objects in
> expression scope, `items()` helpers — is **withdrawn**: resolution and reading are effects, and the
> worker is the only place that can own the handle, the cursor, cancellation and quiescence accounting.
> The rule that survives is **no *file*-specific worker and no I/O in expressions** — `ReadWorker` reads
> any source; `ReadPartWorker` reads any part of a unit already on a lane. §5.2 and §5.4 below are kept
> as the record of what the expression route would have cost and why it went.

### 5.1 Two different operations are both called "splitting"

They are unrelated, the design needs both, and conflating them costs a redesign later:

- **Element split (expand)** — ONE element becomes MANY on the SAME lane. A `DataUnit` becomes its
  rows. Purely a worker concern: `TransformWorker.onElement` may already `emit.send` any number of
  times per input element, so the framework supports this today with no change at all.
- **Channel split (fan-out)** — ONE lane feeds SEVERAL lanes. Not expressible today:
  `ChannelTypeDefiner` enforces single-reader, and J6 (`TeeWorker` + list-typed ports) is the planned
  relief.

**Terminology, fixed here:** *Split* means the element operation; *fan-out* / *Tee* means the channel
one (J6 already uses `TeeWorker`). §5.6(a) is the only place fan-out appears.

### 5.2 The source side already exists — `FormulaSourceWorker` **[withdrawn as a data reader 2026-08-23]**

> **Record only.** `FormulaSourceWorker` stays what it is — an expression source — and is still how a
> child Job puts a `DataUnit` *parameter* onto a lane (`code: "unit"`, §4.3). It is **no longer** a way
> to resolve a source: `sales.units()` would hide resolution I/O (and, for `LogicDataSource`, an
> unreachable `suspend host`) inside generated code. See §15 D7. The text below is the 2026-08-21b
> argument, kept so it is not re-litigated.

`FormulaSourceWorker` *is* the data-source worker. It compiles one Kotlin expression with the Job's
declared parameters in scope (bare and typed), dispatches **strictly on the compiler-inferred type** —
`Iterable` streams element by element, anything else emits a single message — and its `payloadFlow`
publishes the *element* type onto the lane. So the manifest lane is one attribute:

```
FormulaSourceWorker(code: "sales.units()")             // inferred: List<DataUnit>
   → unit lane, payloadType = DataUnit, known statically, no new code
```

⚠ Two things in that one line were not true of the tree as reviewed on 2026-08-21b, and both are fixed
elsewhere rather than here: `payloadType` would have been **`Any`**, not `DataUnit` (§5.5a), and the
run parameters cannot be passed positionally into a `suspend` call from a non-suspend expression — they
arrive through `DataScope.argument(name)` instead (§4, O13).

Resolution is a function call in an expression, so a query needs no worker, no port, and no bespoke
notation shape. It even resumes across a live edit: the source carries `nextIndex` and skips the
already-delivered prefix, guarded on `code` equality.

Downstream, units are ordinary typed payloads — `FilterWorker` can drop units before anything is
opened, `FormulaWorker` can re-type them — with no framework notion of "unit" anywhere.

### 5.2a The declarative reader — `ReadWorker`, source-generic **[decided]**

The trivial case decides this. Starting from a blank Job, "count the lines of one file" must be:
insert a **File source**, pick the file in it, insert **Read**, insert **Summary**, run — **three
cards, no code**. Under the pure expression route it is a source object *plus*
`FormulaSourceWorker("input.units()")` *plus* `ExpandWorker("items(unit.part(\"main\"))")` *plus*
Summary — four things and two Kotlin expressions, which fails §1's ergonomics goal. So:

```
ReadWorker(source: <DataSource>, emit: items | units, role: <DataRole>?, attributes: ignore | columns)
    -> item lane or unit lane
```

**"Three cards", corrected 2026-08-21b.** The previous draft claimed two, and that claim was doing
work it could not support: it rested on O10 (nesting the source object *inline* under the worker's
`source` attribute), which the DS4 elaboration then deferred as "recorded, not attempted" — leaving a
flow of three inserts across two UI regions while the doc still advertised two cards. **Three is the
honest structure**: a source, a reader, an aggregator. Say three, and O10 drops from load-bearing to a
genuine refinement.

A composite ribbon tool ("Read File" inserting both objects in one command) was considered and
**rejected**: a palette entry that expands into several objects is a shortcut, not a simplification —
the user then has two objects they did not knowingly create, and the card they clicked is not the card
they must edit. As simple as possible, not simpler.

What *does* close the ergonomic gap, without a shortcut: (i) **auto-bind** — inserting `Read` into a
Job with exactly one source binds `source` immediately; and (ii) render the bound source **inside** the
Read card as a read-only one-line summary (`FileDataSource "input" · 1 unit · x.csv`) with an
affordance that focuses the source card. `ReferenceLinkAttributeView` already does the link half. That
removes the two-regions problem, which was the real complaint, while leaving the object model honest.

- **`source`** is a **nullable structural reference** to a `DataSource` object
  (`is: DataSource, nullable: true`), which is what makes it both blank-tolerant on palette insert and
  a real graph edge **[decided 2026-08-21b, replacing the `by: Nominal` + resolver of the DS2/DS3
  elaborations]**. kzen-lib supports this directly: `GraphCreator.constructionLevels` checks
  `reference.isNullable(objectMetadata)` on an empty reference and contributes no edge and no failure,
  `GraphDefinitionAttempt` does the same nullability walk, `NotationMetadataReader` reads `nullable`
  from a map-shaped type notation, and `ObjectDefinitionReference.isNullable` reads
  `attributeTypeMetadata.nullable`. So `filterTransitive` pulls the target in — **including across
  documents**, which a weak `by: Nominal` reference would not — `JobRun`'s `GraphCreator.createGraph`
  instantiates it once in the run's own graph, and kzen-lib's `ReferenceAttributeDefinition` injection
  hands the worker the instance (the channel-port precedent). See §6.5 for why this matters beyond
  convenience. ⚠ There is no *shipped* nullable-structural-reference precedent (the channel ports use
  `creator: JobChannelCreator`; `binds` / `contexts` use `by: Nominal`), so pin it with a short spike
  before building on it; the fallback is the resolver, i.e. the previous plan.
- **What it emits.** Whole **units** whenever a unit is not trivially single-part; **items** is the
  degenerate single-role convenience (the trivial case), and the lane carries records so Summary
  counts lines, not units. Multi-role units are *never* split uniformly by the reader — a unit with
  `main` + `reference` parts has no single item schema; turning such a unit into a uniform stream is
  custom logic (an expression, or a third-party transform), not the reader's job (§5.6). `role:`
  selects the one role to open under `emit: items`; heterogeneous schemas under `items` are a
  validation error, not a silent concatenation — **and the reason is downstream, not the reader**
  (§5.2b).
- **`attributes: ignore | columns`** *(added 2026-08-23, §3.5)*: under `columns`, every emitted flat
  record is widened with the unit's attributes as leading columns. This is the unit-identity-on-the-item-
  lane that §3.5 / §5.6 say the reader alone must provide once expressions are out of the read path, and
  it is the `groupBy` parity J4 consumes. Attribute key sets differing across units are heterogeneous
  headers — §5.2b applies.
- **`payloadFlow`.** Under `items`, publishes the opener's `staticShape(role)` (notation-only, no IO —
  `Tabular` → `flatColumns`, `Object` → `payloadType`) and, in DS6, the schema **cache** for explicitly
  named parts — a miss is "unknown", never IO on the walk, so O3 holds. Under `units`, `payloadType =
  DataUnit`. *(Revised 2026-08-23: the 2026-08-21b `itemType(part)` took a `part` the walk does not have —
  nothing is resolved at walk time; §15 C12.)*
- **Cursor.** This is the one place a positional cursor lives — `(unitIndex, partIndex, itemIndex)` with
  the open `DataCursor` detached across a migration, exactly `CsvReaderWorker`'s pattern: the worker calls
  `control.runBlockingIo { cursor.next() }` per item, so the resumed worker drives the carried handle with
  its *new* control (§4). The resolved manifest is **carried** across the migration and never re-resolved,
  and adoption is guarded on the source's definition digest plus this worker's own config — see §8.1,
  where this supersedes the earlier "compare the manifest digest" recommendation.
- **Mode knob vs two workers.** **[open]** O11. A mode knob changes the card's output cardinality,
  which is the objection O1 raised against folding expand into `FormulaWorker`. It is weaker here: a
  source worker has no incoming lane, so there is no ordering question and no migration state to
  split; only the published payload type differs, which `payloadFlow` already handles per mode.
  Recommendation: the knob. If the rule becomes "every card has exactly one output shape", the clean
  split is `Resolve` (source → units) + `Read` (source → items), one more archetype.
- **One implementation.** `ReadWorker` and `ReadPartWorker` (§5.3) share one open-and-drain core —
  `DataOpenerLookup` + the per-item `runBlockingIo` drive + flat-vs-payload by `cursor.shape` + the
  detach-on-migrate handle discipline — lifted, not copied (CC-12). They differ only in where the unit
  comes from (resolved here; the incoming payload there) and in cursor scope (whole manifest vs one unit),
  and both KDocs say so (CC-21). *(Revised 2026-08-23 — the "expression reads re-read on migrate" contrast
  is gone with the expression route.)*

`ReadWorker` replaces `CsvReaderWorker` and `MultiFileReaderWorker`; `MultiFileInputEditor` becomes
`FileDataSource`'s attribute editor (§6.4). The worked trivial case, for the record:

1. Palette → **Data → File**. A source card appears in the Job's *Data sources* section. In it, the
   **file browser** (the `FileDataSource` attribute editor for `files`): directory, filter, listing,
   click the file. Format / encoding default from the extension. The card's generic chrome shows
   "1 unit · 1 part · `C:/data/x.csv`" and, on **Columns**, the header — via the source object's
   detached action, no run.
2. Palette → **Sources → Read**. `source` is **already bound** (auto-bind: exactly one source, blank
   attribute), and the card shows it as a one-line summary.
3. Palette → **Summary**; auto-wired by adjacency (`JobChannelDerivation`). Run. Summary's live row
   count is the line count (less the header if `header` is on).

Scaling without changing shape: the same `Read` card with `source:` pointing at a `sales` source in
another Job's `sources:` branch (discovery is graph-wide by capability, §6.4a); or `Read` with
`emit: units` feeding `RunWorker` over a per-unit child Job (§5.6b); or a `LogicDataSource` whose
resolution is a Script over run parameters (§4.4) — read by the very same `Read` card. Same objects,
same lane. *(Revised 2026-08-23: the `FormulaSourceWorker("sales.units()")` expert route is withdrawn;
parameterized resolution is a source's job, not an expression's.)*

### 5.2b Why heterogeneous item schemas fail rather than merge **[decided 2026-08-21b]**

Report *does* merge them — `DatasetInfo.headerSuperset()` unions the columns across files, and every
record is read against the superset with a missing column rendering `<missing>` (the `RecordHeaderIndex`
/ `CalculatedColumnEval.columnValue` path). So a hard failure in `ReadWorker` is a **parity gap**, and
§9 now tracks it as one.

It is nevertheless the right v1, and the reason is not the reader. At the reader, per-unit headers are
almost free: `JobMessage.ofFlat` already carries a header per message and `RecordHeaderIndex.indices`
caches by equality and recomputes when the header changes. The cost is **downstream and silent**:

- `SummaryWorker.ensureInitialized` fixes its column set from the **first** record's header and maps
  later records on by name — a column that first appears in unit 2 is **silently dropped**.
- `CsvWriterWorker` writes the header from the first batch and then writes each record's fields — a
  wider later record produces **ragged rows** under a header that does not describe them.

So emitting mixed headers converts a loud failure into silent data loss. The correct fix is Report's:
resolve the **superset** up front and normalize every item to it — which needs the pre-scan, i.e. the
design-time schema work. **DS3 fails loudly with that reason in its KDoc; DS6 adds superset
normalization** once schemas are available.

### 5.3 The transform side is 1:1 — the one real gap, and `ReadPartWorker` fills it **[revised 2026-08-23]**

`FormulaWorker.payload` **replaces** the payload: one message in, one message out. Nothing existing
turns one element into many. The framework permits it — `TransformWorker.onElement` may call
`emit.send` any number of times — but no worker does.

For data the 1:N transform that matters is *"a `DataUnit` is on my input lane; give me the items of
one of its parts"*, and it is a **data worker**, not an expression:

```
ReadPartWorker(input: <unit lane>, role: "main", attributes: ignore | columns)   → item lane
```

It takes each incoming payload (must be a `DataUnit` — `payloadFlow` validates the upstream type, which
is why DS1b matters), picks `unit.part(role)`, opens it through the same `DataOpenerLookup` + drain core
as `ReadWorker` (§5.2a "one implementation"), and emits `ofFlat` / `ofPayload` by `cursor.shape`. It is
what the child-Logic idiom (§5.6b) reads with, what a grouped main-plus-reference pipeline uses per role
(§5.6a), and the only place besides `ReadWorker` that opens anything. Its cursor is scoped to the
*current unit*: migration carries `(inputElementIndex, itemIndex, open cursor)`; the unit is re-delivered
by the channel's in-flight buffer, so no re-read.

Two prerequisites it owns, both general: **(i) the 1:N transform emit cadence** (§5.4b — the only one of
the three expression-route costs that survives the route) — `Emitter.expandCadence(control, onFlush)`
beside `sourceCadence`, flush + checkpoint every `batchSize` sends *within* `onElement`, and
`TransformWorker`'s KDoc amended to say 1:N workers opt into the finer cadence and carry mid-element
state; **(ii) handle ownership** — the open cursor closed in `onClose` unless detached, and at
exhaustion.

**`ExpandWorker` is demoted to a generic in-memory utility, off the critical path.** The 2026-08-21b
design needed it as the *bridge* for effectful reading (`ExpandWorker("items(unit.part(\"main\"))")`);
that is exactly the "effect hidden in an expression" D7 removes. A stream-valued expression over an
*already-materialized* value (`(1..payload)`, a `List` payload's elements) is still a reasonable generic
worker and would share the same cadence — but nothing in the DS arc needs it, `groupBy` parity no longer
depends on it (§3.5), and it should be built on demand, as a plain stream expander with **no**
`flatHeader` probing (it never drains a cursor). O1's "new archetype, not a knob on `FormulaWorker`"
still holds if and when it is built.

### 5.4 Three costs of reading inside an expression **[record only — the route is withdrawn, §15 D7]**

> Kept as the argument. Of the three, only **(b)** survives — it is `ReadPartWorker`'s cadence
> prerequisite (§5.3). **(a)** still lands as DS1b's `isStreamType` because `FormulaSourceWorker` gains
> from it independently (O6). **(c)** is answered by there being no expression-opened stream at all.
> The 2026-08-23 review added a fourth cost the draft missed: a `Sequence` whose `next()` does I/O runs
> that I/O on the **fixed engine thread**, outside `runBlockingIo` (§4) — which is why `DataItems` is now
> a worker-driven `DataCursor`.

None is a blocker; all three are invisible until they bite, so they belong in the design rather than
in a later debugging session.

**(a) `Sequence` is not `Iterable`.** `ExpressionReturnTypeInference.isIterable` tests
`isSubclassOf(Iterable::class)`, and `kotlin.sequences.Sequence` does not implement it. So a lazy
`items(): Sequence<Any?>` classifies as *single-emission*: one message holding the Sequence object,
element type lost. Since laziness is mandatory here (a unit may be gigabytes), the classification
widens: `isIterable` → **`isStreamType`** covering `Iterable | Sequence | Iterator`, and
`iterableElementType` → `streamElementType` projecting onto whichever supertype matches (the same
`allSupertypes.firstOrNull` mechanism, one more classifier). Small, entirely general, and
`FormulaSourceWorker` gains identically. **[decided]** — O6.

Note what this settles about `DataItems` itself (§4). The first draft made it an `Iterable` that may
only be iterated once, which is a **contract violation**: any helper doing `.toList()` and then
re-iterating, or a nested `for`, breaks silently. `Iterator` is honest but loses `for` / `map` /
`filter` in user expressions. `Sequence` is both — its own contract says a sequence "can be iterated
multiple times **or not**, depending on implementation" — so a constrain-once `Sequence` violates
nothing and keeps the expression ergonomics. **[decided 2026-08-21b]**

**(b) A transform has no emit cadence.** `Emitter.sourceCadence` is source-only. For a transform,
`send` merely buffers and `flush` runs once per *input* batch in `TransformWorker.drive`, with
`checkpoint` at the top of that loop. Expanding one unit into a million rows therefore buffers a
million messages before any flush, and the Job **cannot pause or cancel** for the whole expansion.
Any 1:N transform needs the source's flush + checkpoint cadence applied per emitted element. Small
change to `Emitter` / `TransformWorker`, not optional at ETL scale.

**(c) Nobody owns the file handle.** `CsvReaderWorker` opens its reader, closes it in `onClose`, and
*detaches* it across a migration so the resumed instance keeps its position. An expression that opens
a stream has no such hook: cancelling mid-expansion leaks the handle (exhaustion-close never runs),
and the position cannot be carried, so a migrate means re-open + re-read the skipped prefix. **[open]**,
with three honest options: (i) accept the re-read and have the stream close itself at exhaustion;
(ii) make the expand worker `AutoCloseable`-aware — close the current stream in `onClose` if it is
one; (iii) a declarative reader worker that owns the handle and a positional cursor. (iii) is now
**in** — the source-generic `ReadWorker` (§5.2a) — so the expression route needs only (ii) plus (i):
a few lines, domain-free, and it makes *any* resource-holding stream safe.

### 5.5 The design-time schema trade-off — what the expression route costs **[largely moot 2026-08-23]**

> With the expression route withdrawn (§15 D7) the trade-off below no longer has to be paid: both readers
> know their opener statically and publish `staticShape(role)` on the walk (§5.2a). What survives of this
> section is its second half — that the *payload type* of a unit lane must be `DataUnit`, not `Any`, which
> is §5.5a / DS1b and is still a hard prerequisite for `ReadPartWorker.payloadFlow` and for a downstream
> `FormulaWorker` to see `.attributes`.

This is the real price, and it is worth naming plainly.

A declarative reader worker knows its source object statically, so `payloadFlow` could publish the
file's columns as `WorkerLane.flatColumns` and every downstream expression would compile against them.
An expression-driven expand cannot: the columns come from a call the walk must not make (O3 — no IO at
definition time).

What survives is the **payload type**, inferred by the compiler exactly as `FormulaSourceWorker` does
today. So the static story shifts from *text columns* to *typed items* — and that is the half kzen
supports best: `FormulaWorker` already puts the inferred payload type in scope as the receiver, with
members bare. A source yielding typed items gives *better* validation than a text-column CSV lane ever
did; a source yielding text items leaves the lane statically unknown, which is exactly where today's
CSV lane already sits (`KotlinSyntaxValidator`, syntax-only). ⚠ That "better validation" is
conditional on §5.5a: as the tree stands, the inferred type of any non-whitelisted class is erased to
`Any` before it reaches the lane.

Consequence for §6: design-time schema serves the **editor** (column dropdowns, pickers, resolved
previews) via the detached pre-scan, not the payload-type walk — *for the expression route*. The
declarative readers (§5.2a, §5.3) recover it: their `payloadFlow` publishes `staticShape(role)` plus the
pre-scan's **cached** columns (never IO on the walk), so the no-code path gets static columns. *(With
the expression route gone, 2026-08-23, that is the only path.)*

### 5.5a The inferred payload type does not survive today — and that is a bug, not a limit **[decided 2026-08-21b]**

Everything above assumes a `DataUnit` on a lane is *typed* as a `DataUnit`. It would not have been.

`ExpressionReturnTypeInference.toTypeMetadata` approximates any classifier that is not in a hardcoded
`visibleBuiltins` set, or in the `ObjectRegistry` document's declared class list, down to `Any`
(nullability preserved). The shipped registry (`registry-jvm.yaml`) holds exactly one entry,
`kotlin.ranges.IntRange`, and `visibleBuiltins` holds eleven. So `FormulaSourceWorker("sales.units()")`
would publish element type **`Any`**, and the downstream `ExpandWorker("items(payload.part(\"main\"))")`
would not compile — `payload` is `Any?` and `part` does not resolve. The whole typed-payload half of
§5.5 rests on a whitelist that does not contain the types.

**The whitelist is a proxy for the wrong question.** Its own KDoc states the real one: is this "a type
a downstream expression could not import"? That is directly answerable —

```kotlin
kClass.qualifiedName != null &&              // excludes local / anonymous
kClass.visibility == KVisibility.PUBLIC &&   // excludes internal / private / protected
!kClass.java.isSynthetic
```

The `KType` was reflected off a class already loaded by the expression's own classloader
(`ClassLoaderUtils.dynamicParentClassLoader`), so loadability is given and the predicate reduces to
"public and nameable". Consequences: `IntRange` stays concrete because it *is* public and nameable,
not because someone listed it (the hardcoded entry, and the registry entry, both go); every
first-party type including the §3.2 model works; a class from a dynamically loaded plugin jar (§4.1)
works with no registration; and an `internal` / synthetic / local type still degrades to `Any`, which
is the property the whitelist existed to protect.

Deliberately **not** the fix: adding the data model to `visibleBuiltins` (hardcoding first-party names
into a general mechanism) or declaring it in `ObjectRegistry` (routing first-party code through a
third-party extension mechanism that is neither finished nor needed here). Both were considered and
rejected on 2026-08-21b.

Two follow-ons worth stating rather than discovering:

- `ObjectRegistryScan` loses its only consumer — `ExpressionReturnTypeInference` is the sole reader;
  `WorkerLaneContext` and `ScriptDefinitionContext` merely carry it. Keep the `ObjectRegistry`
  document as a **widening** escape hatch and empty its shipped `IntRange` entry. *Precisely what it
  widens (2026-08-23):* a class the predicate rejected **as a false negative** — e.g. a Java class for
  which `KClass.visibility` is null — not an `internal` class; generated code still cannot import an
  inaccessible type, and the registry must not be described as overriding Kotlin visibility. Whether to
  retire it entirely is a separate, smaller decision — **O17**.
- The visibility fix types the *unit*; it does **not** type a part's **items**. That is a schema question,
  not a Kotlin-inference one. Its answer is the opener's **`staticShape(role)`** (§4) — notation-only, so
  the walk can read it with no IO — a `Tabular` header or an `Object` type. See §6.3 for where a source
  *gets* a declaration.

### 5.6 Scoping a unit's processing — three mechanisms

This is the "main dataset + reference data, processed as a unit" question.

First, the rule that makes the question well-posed **[decided]**: a multi-role unit flows **whole**.
No reader or framework piece splits it uniformly — there is no uniform way to — and making it
consumable item-by-item is the pipeline author's explicit choice: one `ReadPartWorker` per role the
pipeline wants (§5.3), or a third-party transform that turns the unit into whatever uniform type that
pipeline wants. The mechanisms below are about *where* that logic runs and what boundary it sees.

First, the weaker half: **unit identity** rides every item. *Revised 2026-08-23:* the reader provides
it — `attributes: columns` on `ReadWorker` / `ReadPartWorker` widens each flat record with the unit's
attributes as leading columns (§3.5). That is what J4's `groupBy: <column>` export consumes, and it is a
reader step because the reader is the only thing that still holds the unit when the item is emitted.
(The 2026-08-21b draft routed this through an expression after `emit: units`; the `flatView()`
auto-flatten it once leaned on applies only to a `Map` payload and never runs on a flat message — that
correction stands, and is why the knob is on the reader.)

What identity does *not* give you is the unit **boundary**. A downstream worker can tell which unit an
item came from, but not that a unit has ended, without buffering or watching the attribute change.
Anything that must act **at** a boundary — close an output container, flush a per-unit aggregate —
needs one of these:

**(a) Fan-out the unit lane to role lanes.** Feed `main` and `reference` to separate `ReadPartWorker`s
(one per role), so they become separate lanes.

- *Expressible today?* Partly. A worker may declare several channel ports (`JobChannelPorts` classifies
  each attribute independently, and `JobConventions.autoSynthChannelName` is already keyed by output
  port), so a multi-output worker is legal.
- *But:* the order-driven auto-wire in `JobChannelDerivation` pairs adjacent workers **only when the
  upstream has exactly one open output and the downstream exactly one open input**. A multi-output
  worker is skipped, so its channels must be declared manually (the documented fan-in/branch escape
  hatch) and the editor draws no gold pipe. The single-reader rule in `ChannelTypeDefiner` is *not*
  the obstacle — that forbids two consumers on one channel, and this is two channels. J6 is the
  ergonomic relief.
- *Also:* once the lanes diverge nothing re-synchronizes them, and the boundary problem above is
  unaddressed — it is now two lanes' worth of implicit boundaries instead of one.

**(b) A child Logic per unit** — the manifest lane feeds `RunWorker`, which calls
`JobControl.host(instructions, unit)`; the child Job declares the unit as its parameter, puts it on a
lane with `FormulaSourceWorker("unit")`, and reads each role with its own `ReadPartWorker(role)` (§4.3).

- *Expressible today?* Yes, entirely — `JobControl.host`, `RunWorker`, typed `parameters` and
  declared `results` all landed in J2. No framework change beyond `ReadPartWorker` itself.
- The two roles are two independent `ReadPartWorker`s inside the child, so **no fan-out is needed** —
  the unit never becomes a lane that has to be forked.
- Unit scoping is *structural*, which is the whole point: the child run **is** the boundary, so
  aggregators reset, writers open per-unit paths, and the child's declared result is the unit's
  output (§7.1) — none of it inferred from a changing attribute column. Breakpoints, stepping and
  pause-on-error descend into the child for free.
- *Cost:* one child run per unit, driven sequentially by `RunWorker`. Fine for "a unit is a day";
  wrong for "a unit is a row".

**(c) In-band punctuation** — `JobMessage` gains begin-unit/end-unit markers, forwarded generically
by `TransformWorker` unless a worker opts in.

- Most powerful: single-pass grouped export, per-unit aggregates, and streaming parallelism across
  units, all without a run boundary.
- *Cost:* it changes the element model, and every worker's forwarding contract with it. Given J4
  gets the weaker form (group **by column value**) as soon as an expression stamps unit attributes as
  columns (§3.5 as corrected), this is not yet paying for itself.

**Recommendation.** (b) is the default idiom for unit-scoped work and should be what the docs teach —
it is the only one of the three that gives a *real* boundary rather than an inferred one. (a) is the
in-Job idiom when no per-unit boundary semantics are needed (a straight concatenating read of several
roles), and becomes ergonomic when J6 lands. (c) is deferred, with an explicit reopening trigger: *a
pipeline that needs per-unit boundary semantics at a grain where a child run per unit is too coarse.*

Worth stating plainly, because it is the shape of the whole model: **a single-lane split loses
boundaries by construction, and that is fine.** Recovering them costs either a run boundary (b), a
marker (c), or downstream buffering. Do not add a fourth mechanism that hides the cost.

### 5.7 Reference data as a lookup

Once `reference` is its own lane, the natural consumer is a `LookupWorker` that loads it into memory
and serves key→row over a **duplex channel** — `ChannelServer` / `ChannelClient` already exist, and
the main pipeline's transform holds the client. This needs no framework change and is a good
first-party example of the duplex facility being used for something other than the UI bridge.

The ordering constraint is real and must be stated in the worker's contract: the lookup must be fully
loaded before the main lane queries it. Under (b) that is trivially arranged inside the child Job;
under (a) it is the worker's own responsibility (drain the reference input to end-of-stream before
serving the first request).

## 6. The design-time surface

### 6.1 Schema: two consumers, two questions, and only one of them is the walk **[revised 2026-08-23]**

**Two questions the 2026-08-21b draft ran together (§15 D9).** "What columns does this part have?" is
tabular structure; "what Kotlin type is each emitted item?" is a payload type. A field map is not an
item type, and treating both as "schema" made the reader API and downstream inference ambiguous. The
vocabulary is `DataShape` — `Tabular(header)` or `Object(type)` (§4) — and the two calls are split by
**what they may do**, not by what they return:

- `DataOpener.staticShape(role): DataShape?` — answerable from **notation alone**, never I/O. This is what
  the payload-type walk reads (O3 holds by construction). A declared schema (§6.3) lives here.
- `suspend DataOpener.inspectShape(context, part): DataShape?` — a **bounded** read of one concrete part
  (a header row, `LIMIT 0`), or null when the opener cannot answer cheaply. This is what the editor asks
  for, through the generic `DataSourceActions` (`action=shape`, §4).

The walk cannot call `inspectShape` for the same reason it cannot resolve: no part exists at walk time.
A **schema cache** keyed on the part's fingerprint (§6.2) is a separate service the editor primes and the
walk may read for explicitly-named parts — not a member of the SPI.

**The editor** is the primary consumer, and it is well served. It asks the generic action "what shape
does this part have?", gets the declaration or the pre-scan (`ColumnListingAction` / `ReportHeaderReader`
behind `FileDataOpener.inspectShape`), and offers dropdowns instead of free text. This subsumes today's
`JobUpstreamSchema`, which can only find columns by walking upstream for a live `SummaryServer` — i.e.
only *after* a run. Resolution order for an editor asking "what columns can I offer?":

1. live summary (a running `SummaryServer` upstream) — most accurate, run-scoped;
2. offline persisted summary (J4) — last run's actual columns;
3. **a declared schema** on the source (§6.3) — free, and the only option a source whose reading is
   expensive can offer;
4. **on-demand source pre-scan** (this design) — available with no run at all, but bounded (§6.2);
5. free text.

Columns are the *whole* design-time data surface: there is no row preview, deliberately (§9).

**The payload-type walk** gets `staticShape(role)` from both readers (they know their opener statically)
and nothing else — never I/O. So:

| Lane | Static scope for downstream expressions |
|---|---|
| opener declares `Object(type)` | the item type as receiver, members bare — full compile-time validation (⚠ needs §5.5a, or every such type flattens to `Any`) |
| opener declares `Tabular(header)` | `flatColumns` known; expressions validate against the header |
| opener declares nothing (a directory-walk file source) | statically unknown; `KotlinSyntaxValidator` syntax-only, as today's CSV lane — until the DS6 cache is primed for explicitly-named parts |
| `emit: units` | `payloadType = DataUnit` (needs §5.5a) |

Unknown must remain legal at every step; it already is, and this design does not make any lane *less*
known than it is today. It simply declines to promise the walk something it cannot deliver without
doing IO at define time.

### 6.2 Caching, and a bug to fix on the way

`ColumnListingAction` caches an extracted `HeaderListing` as `columns.csv` under a path keyed on
`(dataLocation, pluginCoordinate)` — **with no size or modification time in the key**. An edited file
therefore serves stale columns until the cache is cleared by hand. Any schema cache in this design
must key on `(ref.id, format, encoding, size, mtime)` where the resolver can supply size/mtime, and
must degrade to "don't cache" where it cannot.

**Where size/mtime come from (2026-08-23, §15 D9):** the resolver **stamps them into the ref at resolve
time** — `DataRef.attributes[size]` / `[modified]`, reserved text-canonical keys — because
`FileListingAction.toFileInfo` already has them from `BasicFileAttributes` and the manifest is the
natural carrier. That one choice gives the cache key *and* the review's "reproducible manifest": a
manifest whose refs carry a fingerprint records what was read, and a changed file changes the digest. A
content digest is deliberately **not** stamped (a full read).

Cost discipline matters here because the editor may ask on every click: `inspectShape` must be a
bounded read (a header row, a `LIMIT 0` query), never a full scan — `ReportHeaderReader` already reads
only as far as the header, so the file case is fine — and the walk reads the cache only.

### 6.3 Column types — excluded, but the landing site already exists **[revised 2026-08-21b]**

Real ETL wants typed columns. But `HeaderListing`, `FlatFileRecord`, `ColumnValue` and
`WorkerLane.flatColumns` are text-canonical end to end, with conversion at expression time. Typing
that is its own arc with a wide blast radius, and doing it inside this change would double the risk
of both. `DataSource.schema` returning `HeaderListing` today can widen to a typed schema later
without any change to the model in §3.

**What the previous draft missed: a typed-schema document already ships.** There is a `DataFormat`
document archetype (`common-document.yaml`, `group: "Customize"`), backed by `DataFormatDocument`,
`FieldFormatListSpec` / `FieldFormatSpec` — a map of field name → **`TypeMetadata`**, i.e. exactly
typed columns — with a `DataFormatController` in `data-js.yaml` and a `FieldFormatSpecTest` pinning the
notation. **Nothing reads it.** It is a shipped-but-unconsumed authoring surface.

That changes three things:

1. **It is the natural supply for `staticShape(role)` (§6.1).** A source declares a schema document
   nominally and its opener answers `staticShape` from the declaration — no IO, so the payload-type walk
   can read it (O3 holds by construction), and a source whose reading is expensive still gets
   design-time types. This is the *declared* half of §6.1's resolution order, above the pre-scan.
2. **The name collides and the document is the one that should move.** Report's own UI labels the
   per-file plugin coordinate "Format" (`InputSelectedFormatController`), and `InputDataSpec` agrees,
   so `DataPart.format` is consistent with shipped vocabulary. Rename the *document*
   `DataFormat` → **`DataSchema`** — it declares field types, not a parse coordinate — or delete it.
   Cheap either way: one archetype, one controller, one spec package, one test. **O18.**
3. **The package placement in the DS2 elaboration is already taken.** `server/objects/data/` is
   `DataFormatDocument`'s, `data-js.yaml` exists, and `data-jvm.yaml` was proposed into the same
   namespace. Use `server/objects/datasource/` and `common-data-source.yaml` /
   `data-source-jvm.yaml`. §10's collision check covered the class names and missed the package, the
   document, and the two meanings of "format".

### 6.4 Where the file-selector UI lives — on the source object, as an ordinary attribute editor **[decided]**

The browser is **`FileDataSource`'s attribute editor** and nothing more. `AttributeWrapperLookup`
reads an attribute's `editor:` metadata key, which names a wrapper object; `AttributeEditorManager`
resolves that name against its autowired `List<AttributeEditor>` and falls back to
`DefaultAttributeEditor`. That string contract is documented in the codebase as *the* open-set
extension seam, and `MultiFileInputEditor` is already bound through it — so the implementation
largely exists. What changes is *what it edits*: the file source's selection attribute (directory,
filter, picked files, per-file format / encoding, group pattern — Report's `InputSpec` shape lifted
onto the object) instead of a worker's raw `List<String>` (§2.2). A JDBC source brings a SQL editor
the same way. **The Job editor itself has no file-specific code**: it renders each source card's
attributes through the editor manager and adds generic chrome (resolve preview, columns) that calls
the generic `DataSourceActions` detached object with the source's location (§4).

The binding can be **per type rather than per attribute**: a type-level `meta.ref` map propagates the
editor key to every attribute declared `is: <that type>` (`NotationMetadataReader.resolveMetadataRef`
— the shipped precedent is `ResourceClosePolicy` handing `SelectValuesEditor` to every `closePolicy`
attribute). Declare the editor once on the selection type and every attribute of that type, in any
archetype, first- or third-party, gets the browser.

**Where the source object lives.** See §6.4a — the answer changed on 2026-08-21b.

**Third-party sources and their UI.** The general mechanism — generic editors driven by attribute
metadata plus a standard detached query protocol (options / browse / preview / validate) that *any*
object answers, with Web Components as the escape hatch for rich editors — is in
[`2026-08-21_extension-points.md`](2026-08-21_extension-points.md) §2. The file browser is itself
the first customer of that protocol (it already browses through the generic `/file-listing` route).

**Two editor mechanics to get right, both found by review rather than by building:**

- **An `editor:` key and its registration must land together.** `AttributeEditorManager` resolves
  `AttributeWrapperLookup.wrapperName(…) ?: DefaultAttributeEditor.wrapperName` — the fallback fires
  when the attribute has **no `editor:` metadata at all**. A declared-but-unregistered name is a
  `find` miss, and `render` then emits the literal text `[Attribute editor not found: <name>]` with
  **no input**. So declaring `editor: SelectDataSourceEditor` in the reader's archetype before the
  wrapper exists bricks the field. Two fixes, both worth doing: land the key and its `@Reflect`
  registration in one change, and make the name-miss fall back to `DefaultAttributeEditor` with a small
  warning so a typo degrades instead of bricking (the "a typo is a blank UI" hazard, ~5 lines).
- **`filter` is not a glob, and must not be labelled one.** `FileListingAction.parseFilter` trims,
  lowercases, splits on whitespace and requires the file **name** to contain **every** token
  (`filterParts.all { name.contains(it) }`). So `sales csv` matches `2026-sales.csv` and `*.csv`
  matches nothing. Keep the one dialect, and put its shape in the field's placeholder — a user typing
  `*.csv` and getting an empty list is the likeliest first-five-minutes failure of the feature.

### 6.4a Where a source object lives — the `Contexts` pattern **[decided 2026-08-21b]**

The previous draft offered three placements with the Job's own `sources:` branch as primary and
cross-Job sharing as "a Custom document with `exports`", deferred. For an ETL port that is backwards:
one `sales` source used by six Jobs is the *normal* case.

There is already a shipped answer to "a user-declared nominal object that other documents name": the
**`Contexts` document**. Its design comment states the rule that should be copied verbatim —
*"this document is AN authoring surface, never the home"* — because discovery is graph-wide and by
inheritance (`ContextConventions.allContexts` scans every object in `coalesce` for a `Context`
ancestor), `by: Nominal` references resolve to it, and rename-refactor rewrites them.

So:

- **`DataSource`** — the abstract archetype, as before.
- **`DataSources`** — a document archetype, `group: "Customize"`,
  `meta.sources: {is: List, of: DataSource, by: NestedList}` — a direct copy of `Contexts`.
- **`DataSourceConventions.allDataSources(graphNotation)`** — every object whose inheritance chain,
  **dropping self**, reaches `DataSource`. The `drop(1)` is not cosmetic: `ContextConventions.isContext`
  does it so the abstract archetype does not match its own filter and offer itself in every picker. The
  DS2/DS4 elaborations anchored on `isChannelArchetype`'s bare `.any` and would have inherited that bug.
- **The Job's own `sources:` branch stays** as the local authoring surface — co-located with the
  workers that use it, and (per §5.2a) automatically in the run graph.

Cross-document sharing then works on day one, `SelectDataSourceEditor`'s candidate list is one query
rather than a document-scoped list plus a "later" item, and nothing has to migrate when a local source
graduates to a shared one.

**Deferred 2026-08-23 — the document, not the discovery [§15 D11].** `DataSourceConventions.allDataSources`
is graph-wide by capability from DS2 on, so a source in *any* Job's `sources:` branch is already visible
to every picker — cross-Job sharing works with no `DataSources` document at all, and a source "graduates"
by cut/paste. What the document adds is a home with no Job around it, and what that *costs* is a
`DataSources` controller with insert / rename / delete / duplicate behaviour and its own card rendering —
which the 2026-08-21b plans never specified (the review's point: "adding the document is not enough").
Nothing in the trivial case or the ETL fixture needs it. So: the Job `sources:` branch is the only
authoring surface in the arc; the `DataSources` document (archetype + controller + the `Contexts`-pattern
comment) lands as a follow-up when a project has sources that belong to no Job. Pickers must already be
written graph-wide so that follow-up is additive.

### 6.5 The gap the UI question exposes: an expression cannot name an object **[withdrawn from the critical path 2026-08-23]**

> **Record only — §15 D7.** The problem below is real and the mechanism (A) is sound, but the DS arc no
> longer needs it: with reading done by workers, the only thing that must name a source object is
> `ReadWorker.source`, which is an ordinary reference attribute, and expressions only ever see
> materialized payloads. Objects-in-expression-scope is a general capability worth having someday (Script
> too); it is **not** part of this arc, and nothing below is scheduled. What *survives* from this section
> is the run-time provenance rule (D2: the instance comes from the run graph, via the structural reference)
> and the O14 spike — now extended to test **deletion** of the referenced source, since a dangling hard
> reference prunes the worker from `transitiveSuccessful` rather than warning (§15 C15).

This is the real obstacle, and it is worth stating before anyone starts building.

`FormulaSourceWorker` has exactly one editable attribute — `code`, a Kotlin expression. There is
nothing to hang a file browser on, and hanging one on a free-text expression would be a category
error. The natural fix — *put the browser on the `DataSource` object and have the expression reference
it* — **does not work today**:

- An expression's scope is **receiver + flat columns + declared parameters**, and nothing else:
  `CalculatedColumnEval.generate` emits column accessors and parameter accessors, period. There is no
  way to name a notation object from an expression.
- `ParameterDefaultDefiner.coerce` handles `String` / `Boolean` / `Int` / `Long` / `Double` only, and
  its own comment lists **object refs** among the types that deliberately yield a null default.
- Even a `DataRef` carrying `source: ObjectLocation` (§3.2) needs *something* to turn that location
  into a live instance at run time. `JobControl.host` already does exactly this for a child Logic, so
  the capability exists in the right place — it is simply not reachable from expression context.

Three ways to close it:

| | Approach | Cost | Verdict |
|---|---|---|---|
| **A** | **Objects in expression scope.** A Job's declared source objects get bare typed accessors in `CalculatedColumnEval`, generated exactly as `generateParameterAccessors` does for parameters and injected through a second `setObjects(…)` list; the instances come from the run's `graphInstance`, which `JobRun` already holds. | one new scope kind in `CalculatedColumnEval` + the sources branch | **The mechanism** — general, useful well beyond data sources (Script's `StepExpressionCompiler` too) |
| **B** | **The selection is a parameter default.** Bind the browser to a parameter declaration's `default`, typed by a selection spec. | `ParameterDefaultDefiner` must coerce structured notation; **and** `LogicSignatureEditor` renders `default` with its own scalar-gated `TextField`, not through `AttributeEditorManager`, so it would need a className → editor dispatch | **Withdrawn (2026-08-21).** The query belongs on the source *object* (§6.4); parameters carry *values* (`from` / `to`, or a `DataUnit` handed down by a caller). B would have put a self-resolving file-specific value type into the model to dodge the object lookup — exactly the special case this design forbids |
| **C** | **Stringly global lookup** — `source("Sales").units(…)` via an injected `@Service`. | least code | Rejected: no static type, no editor binding, no rename safety |

**Recommendation: A, now.** And the primitive it depends on — **run-time resolution of a source to a
live instance** — is a reuse, not a build.

**Where that instance comes from, corrected 2026-08-21b.** The DS2/DS3/DS5 elaborations routed *every*
run-time lookup through a `DataSourceResolver` over `GraphInstanceCache`. That is the wrong source of
truth, and the sentence above already said so without following it: the instance **is already in
`graphInstance`**. `JobLogicCompiler` builds `synthesis.graphDefinition.filterTransitive(documentPath)`
and `JobRun` calls `GraphCreator.createGraph(filteredDefinition, graphEnvironment)` — the **whole**
filtered definition — so every object in the Job document, and everything a structural reference reaches
(§5.2a), is instantiated once, in the run's own graph, before the first Worker starts.

Going through the cache instead costs four things:

- **Two instances of the same object exist during a run** — the run graph's and the cache's — keyed on
  different definitions (the cache filters by `AutoConventions.serverAllowed`, the run does not), so they
  can disagree. That mismatch is exactly what forced the DS3 elaboration to note "the resolver must
  resolve against the *full* definition the run sees, not only `serverAllowed`" and add an overload for it.
- **`GraphInstanceCache`'s statelessness contract is imported into the run**, since the cached instance is
  shared across runs and with design-time detached calls.
- **Contexts become unreachable** — a cached instance is outside the run's frame, so §4's borrow model
  cannot work.
- It is more code than the alternative.

So the split is: **run time = the run graph** (constructor injection for `ReadWorker` via the nullable
structural reference); **design time = the generic `DataSourceActions` over `GraphInstanceCache`** (§4).
The "cross-boundary fallback" — a sourced `DataRef` reaching a reader whose run graph does not hold the
source — is **deferred with `DataSourceId` itself** (§3.3): in v1 every ref is plain and the file opener
reads it; a sourced ref is a clear failure. When provider-bound sources arrive, that fallback is a
`DataSourceId` → location scan inside `DataOpenerLookup`, and it is the only place it lives.

*(2026-08-23: the expression-scope half of this split — `graphInstance` feeding generated accessors — is
withdrawn with the expression route. The trivial case never touched it; the expert route that needed it
no longer exists.)*

## 7. The Logic boundary

### 7.1 Data flows out as well as in

"Invoke a Job for a specific input file, then take the output file" needs **both** directions:

- **In:** the Job declares a `parameters` entry typed as `DataUnit` (or `DataRef`). `JobControl.parameter`
  returns it, and each part is self-opening through `DataRef.source` (§4.3) — no configuration at the
  receiving end.
- **Out:** the Job declares a `results` component, and the *writer* yields the ref(s) it wrote.

The second half is a gap today. `ExportWriterWorker` writes to a path attribute and yields nothing;
`ResultSinkWorker` keeps a streamed element. So a writer must gain the ability to yield a `DataRef`
(or a whole `DataUnit`, when it wrote several containers under a grouping) as a declared result.
Without that, "take the output file" degrades to reconstructing a path pattern by hand at the call
site, which is exactly the kind of implicit coupling this model exists to remove.

Worked shape:

```
OuterJob(parameters: from: String, to: String)
  sources/dated: LogicDataSource(instructions: DatedSales, arguments: [from, to])
  ReadWorker(source: dated, emit: units)                       -> unit lane
      // `from` / `to` reach the Script through DataContext.argument(name) → named host arguments — §4.4
  RunWorker(instructions: PerDayJob)                           -> result lane (one DataRef per day)
  ResultSinkWorker(result: outputs, keep: all)

PerDayJob(parameters: unit: DataUnit; results: output: DataRef)
  FormulaSourceWorker(code: "unit")                            -> the unit, once   [existing worker]
  ReadPartWorker(role: main, attributes: columns)              -> item lane (with `date` stamped)
  LookupWorker  <- ReadPartWorker(role: reference)
  FilterWorker / FormulaWorker …
  ExportWriterWorker(path: "out/${date}.csv")  -> yields DataRef
  ResultSinkWorker(result: output)
```

*(Revised 2026-08-23 — no expression opens anything; §15 D7.)* Note `ResultSinkWorker` keeps `first|last`
today — collecting *all* per-unit refs into a list result is **[open]** and may want a `keep: all` mode,
or the outer Job may simply write them somewhere.

**Same-run composition vs a persisted result (2026-08-23).** The shape above is *nested* composition: the
child's `DataRef` travels to `RunWorker` in-process as a `TupleValue`. A ref that a *future, independent*
run discovers is a different feature — `OutcomeTrace` deliberately drops a success's tuple, and
`ExecutionValue.ofArbitrary` lowers scalars / lists / maps, not domain objects, so a yielded ref is not
automatically persisted anywhere a later run can query. Two things make that acceptable now: the
writer's yielded ref is a **plain path** (durable by construction, §3.3), and the caller that stores it is
the one who decides where. A "results registry" with retention and naming is **optional and later**, and
not in this arc.

### 7.2 `ExecutionValue` lowering

`DataRef` / `DataPart` / `DataUnit` / `DataManifest` each need a canonical `ExecutionValue` form
because they cross REST (detached actions, run arguments), notation defaults, and the trace display.
With text-canonical attributes (§3.5) this is a mechanical map/list lowering with no bespoke codec —
the `DataLocation` precedent (a hand-written serializer whose wire form is the value object's own
canonical string) is the pattern to follow, and `asCollection` / `ofCollection` pairs already exist
throughout for the value-tree plane.

`DataRef.source` lowers as its `DataSourceId` string (§3.3) — null for every v1 ref — so the
`ObjectStableId` `KSerializer` the DS1 elaboration planned is **not needed** — one fewer serializer, and
kzen-lib stays untouched for a better reason than "we chose not to edit it". `DataResolveResult` lowers
the same way (manifest + a list of text-canonical diagnostics).

## 8. Run-time concerns

### 8.1 Resolve once, then treat the manifest as run state

The moment resolution becomes dynamic, resolving on demand becomes a correctness hazard: two reads of
a directory can differ mid-run. `FormulaSourceWorker` evaluates its expression **once** per run, which
gives this for free — but only for the first evaluation. Its resume works by *re-evaluating* and
skipping the delivered prefix, so a mid-run migration re-resolves, and a directory that changed
underneath yields a different stream than the one already partly delivered.

`MultiFileReaderWorker` guards the equivalent hazard by comparing its `paths` attribute on
`loadMigrationState`, which is coherent only because the set is frozen config; `FormulaSourceWorker`
guards on `code` equality, which does not see a changed directory at all.

**Resolved 2026-08-21b — carry the manifest; do not re-resolve, and do not compare digests.** The
previous draft weighed (i) accept re-resolution and document it, against (ii) carry the manifest's
digest and restart when it differs, and recommended (ii). (ii) is superseded by something simpler and
strictly better for `ReadWorker`: **the resolved manifest is itself carried across the migration**, so
the resumed instance continues over the *same* list and re-resolution never happens — closing the
hazard rather than detecting it. Adoption is guarded on the source's **definition digest** plus the
worker's own config, which is also the honest guard (it does no IO at migration time, and it restarts
on an edited query even when the directory is unchanged — state that in the KDoc).

`DataManifest` stays `Digestible`, but for its surviving consumers — the run-record trace stamp (§7,
"the full digest always, even when the unit list is teased") and diagnostics — not for a resume guard
that no longer runs. With the fingerprint stamped into each ref (§6.2), that digest also says whether
the *files* were the same, not only the selection. *(The 2026-08-21b caveat about `FormulaSourceWorker`
re-evaluating a directory walk is moot — no expression resolves a source any more.)*

The resolved manifest should also be published — as worker progress and/or trace — so a run records
what it actually read. That is both an observability win and the reproducibility story for an ETL
port.

### 8.2 Cursors

`CsvReaderWorker` and `MultiFileReaderWorker` carry a real positional cursor — `(fileIndex, position)` —
detaching the open reader at `captureMigrationState` so the rebuilt instance resumes at the exact byte.
Both data readers inherit that: the open `DataCursor` is the handle, detached across the migration and
driven onward by the new instance's control (§4, §5.2a, §5.3). *(2026-08-23: there is no longer an
expression route paying a re-read — every read has an owner.)* For plugin-format readers positional resume
is out of reach either way (framers are stateful); J3 already records restart-on-edit as the acceptable
v1 for `PluginReaderWorker`, and a reader over a plugin format inherits that.

## 9. Report parity map

| Report capability | This design |
|---|---|
| Browse directory + filter | `FileDataSource`'s attribute editor over the existing `/file-listing` route (§6.4). ⚠ `filter` is a contains-all-words match on the file name, **not** a glob (§6.4) |
| Selected file list | resolved `DataManifest`, shown as a preview table in the source card (via the object's detached action) |
| Per-file format (`InputDataSpec.processorDefinitionCoordinate`) | `DataPart.format`, defaulted by the source (`actionDefaultFormat` logic) |
| Data type filter (`InputSelectionSpec.dataType`) | source-level constraint on which formats it offers |
| `groupBy` filename regex → `DataLocationGroup` | source-level attribute extraction → `DataUnit.attributes` |
| Grouped export | `attributes: columns` on the reader (§3.5, §5.6 — revised 2026-08-23): unit attributes become leading columns, which is what J4's `groupBy: <column>` consumes. Lands with **DS3** |
| **Header superset across files** (`DatasetInfo.headerSuperset`) | ⚠ **gap in v1.** `ReadWorker` **fails** on heterogeneous item schemas rather than merging them — deliberately, because the loss would otherwise be silent downstream (§5.2b). Superset normalization lands with the design-time schema work |
| Column listing (`ColumnListingAction`) | `FileDataOpener.inspectShape` — editor pre-scan through the generic action (and a declaration via `staticShape`, §6.3), plus the readers' `payloadFlow` from `staticShape` and the DS6 cache (§6.1) |
| Encoding detection (`ReportUtils.encoding`) | `DataPart.encoding`, source-defaulted at resolve, opener-inferred when null |
| Multi-file as one stream | `ReadWorker` (§5.2a) — one card, any source |
| Row-level data preview | ⚠ **deliberately absent.** Report shows rows; this design shows the **manifest** and the **columns**, and nothing else at design time. "Read me ten rows" assumes rows are a meaningful unit and that obtaining one is cheap — neither holds for a source whose items come out of a full pipeline. §6.2's bounded-or-declared rule is the contract |
| — (no Report equivalent) | parameterized resolution, multi-part units, non-file sources, cross-Job composition |

**Not in scope, and deliberately so.** There is no Report → Job conversion path, and none is planned:
"supersede" here means a Job can express what a Report expressed, not that an existing Report document
migrates itself. Report's own retirement stays J4's.

## 10. Naming **[decided]**

Avoid `Resource*`. The word is taken twice in this codebase already — notation resources
(`NotationResourceCommands`, the binary assets in a project) and run resources
(`openResource`/`releaseResource`, now largely superseded by Contexts) — and this is neither.

`Data*` aligns with what already exists (`DataLocation`, `DataLocationInfo`, `DataFramer`,
`DataInputEvent`, `DataEncodingSpec`, `DatasetInfo`) and reads correctly for a DB or API source later.
Collision check against current names: `DataRef`, `DataPart`, `DataUnit`, `DataManifest`, `DataRole`,
`DataQuery`, `DataSource`, `DataSourceId` are all free today; **2026-08-23 additions** `DataOpener`,
`DataCursor`, `DataContext`, `DataShape`, `DataResolveResult`, `DataDiagnostic`, `DataOpenerLookup`,
`FileDataOpener`, `DataSourceActions`, `ReadPartWorker` — re-checked free (`DataItems` and `DataScope` are
retired names). `DataSource` is close to Report's existing `FlatDataSource` — that one is the *byte-stream*
seam and stays, so the KDoc on each must say which is which (CC-21 reciprocal markers if they end up
genuinely paired). ⚠ `DataContext` is close to kzen's *Context* vocabulary (`ContextBinder`, the run's
Context registry): its KDoc must say it is the per-call environment a source runs in — which *includes*
`contextValue(key)` for reaching a Context — not a Context itself.

**Revised 2026-08-21b, three corrections to the check above:**

- **`DataRows` → `DataItems`.** "Rows" presumes tabular data, which a non-file source need not produce;
  Spring Batch's *item* vocabulary (`ItemReader` / `ItemProcessor` / `ItemWriter`) is the established
  neutral term for "one thing a pipeline handles at a time" and reads correctly for a row, a record, a
  document or an object. `ReadWorker`'s knob becomes `emit: items | units` and the SPI call becomes
  `items(scope, part)` accordingly.
- **The check covered class names but not the `data` *package*, and both are taken.**
  `tech.kzen.auto.server.objects.data` is `DataFormatDocument`'s,
  `tech.kzen.auto.common.objects.document.data` is its spec package, and `data-js.yaml` already exists.
  Use `server/objects/datasource/` and `common-data-source.yaml` / `data-source-jvm.yaml`, not the
  `data*` names the DS2 elaboration proposed.
- **"Format" now means two things.** `DataPart.format` (a `CommonPluginCoordinate` — how to parse) is
  consistent with Report's shipped UI label and with `InputDataSpec`; the `DataFormat` *document* (field
  → `TypeMetadata`) is the outlier and should be renamed `DataSchema` or deleted (§6.3, **O18**).

**Package layering — Job must stop reaching into Report.** `HeaderListing` lives in
`common/objects/document/report/listing/`, and putting `DataSource.schema` in a flavour-neutral
`paradigm/data/` package that imports it just deepens the inversion. Scope the fix rather than boiling
it: Job's server packages currently import ~25 distinct Report types, so full decoupling is its own
project. Move (a) the **schema vocabulary** — `HeaderListing` / `HeaderLabel` / `HeaderLabelMap` — to
`common/data/schema/`, as a mechanical import-only change **before** the model types are written, and
(b) with the file source, the **input plumbing it sits on** — `FlatDataSource` / `FileFlatDataSource` /
`FlatDataStream` / `FlatDataLocation`, `ReportInputChain`, `ReportHeaderReader`, `FileListingAction`,
`ColumnListingAction`, `ReportDefinitionRepository` — to `server/data/…`, with Report consuming them
from the new home. That second move also puts `FlatDataSource` and `DataSource` in one package, where
the CC-21 pair reads naturally. Leave the expression engine (`CalculatedColumnEval` / `ColumnValue`)
and everything pivot / export / filter alone — J-arc business.

That move also fixes the *new* code's home. `common/data/` becomes the data domain's root —
`data/schema/` (the vocabulary above + `DataShape`), `data/model/` (the §3.2 types), `data/api/`
(`DataSource` / `DataOpener` / `DataCursor` / `DataContext`), `data/file/` (the file-selection spec) — and
the server side mirrors it at `server/data/` (plumbing, `FileDataOpener`, `DataOpenerLookup`) and
`server/objects/datasource/` (the source objects + `DataSourceActions`). **Not `paradigm/data/`**,
which an earlier draft proposed: `paradigm/` holds `{detached, flow, job, logic}`, i.e. *execution
paradigms*, and a value model is not one. `util/data/` (`DataLocation`, `DataLocationInfo`, `FilePath`)
stays put — it is location arithmetic used by everything including Report, and moving it buys the arc
nothing.

## 11. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| O1 | Is the 1:N expression transform a new archetype or an `expand:` attribute on `FormulaWorker` (§5.3) | New archetype — `FormulaWorker`'s lanes are cardinality-preserving; mixing in a cardinality-changing one muddies both ordering and migration state. **2026-08-23:** `ExpandWorker` is demoted to demand-driven; the data 1:N worker is `ReadPartWorker`, which is not an expression worker at all |
| O2 | `ResultSinkWorker` gaining `keep: all` so an outer Job can collect one ref per unit (§7.1) | Yes, but it is a separate small change; do not entangle it with the model |
| O3 | Whether a `DataSource` / `DataOpener` call may run at *definition* time (during the payload-type walk) | **No IO at definition time, ever.** The walk reads `staticShape(role)` (notation-only) and the schema **cache**; `resolve` / `inspectShape` are never called from it (§6.1) |
| O4 | Whether a `DataRef` with `source == null` (a plain path) is a first-class case or a convenience conversion | First-class — it is the whole trivial case, it keeps `DataLocation` interop free, and §4.4 depends on it. **2026-08-23: it is every ref in v1** (§3.3) |
| O5 | Do units nest? (a unit whose part is itself a manifest — e.g. a month containing days) | No. Flatten at resolve time; nesting re-imports every problem §3.4 rejects |
| O6 | Widen the strict-static stream dispatch beyond `Iterable` (§5.4a) | **Decided 2026-08-21b: yes** — one `isStreamType` covering `Iterable \| Sequence \| Iterator`. Still lands (DS1b): `FormulaSourceWorker` gains from it regardless of the DS arc |
| O7 | Resource ownership for an expression-opened stream (§5.4c) | **Moot 2026-08-23** — no expression opens a stream. Both readers own their `DataCursor` (close in `onClose` unless detached; close at exhaustion) |
| O8 | Where the file-selector UI binds (§6.4–6.5) | **Decided 2026-08-21: on the source object's own attributes**, as `FileDataSource`'s attribute editor. The parameter-default binding is withdrawn — it needed a self-resolving file-specific value type |
| O9 | How an expression reaches a notation object — objects-in-scope (A), parameter default (B), or stringly lookup (C) (§6.5) | **Withdrawn from the arc 2026-08-23 (§15 D7).** A remains the right mechanism *if* it is ever needed; nothing in the DS arc needs it. B withdrawn; never C |
| O10 | Can a source object nest **inline under `ReadWorker`'s `source` attribute** (§5.2a)? | **Demoted 2026-08-21b** from load-bearing to a refinement: the trivial case is three cards either way (§5.2a), and auto-bind plus an in-card source summary carries the ergonomics. Revisit only on evidence that the section split actually hurts |
| O11 | `ReadWorker` `emit: items \| units` knob vs a `Resolve` + `Read` split (§5.2a) | The knob — a source worker has no incoming lane, so O1's ordering / migration-state objection does not apply; split only if "one output shape per card" becomes a rule |
| O12 | Design-time resource lifetime for stateful sources (§4) | **Reduced 2026-08-21b.** Run time is solved by Contexts (the source borrows via `DataContext.contextValue`, disposal by declared `ResourceClosePolicy`). What remains is only the design-time *owner*: request-scoped open/close inside `DesignDataContext` for v1, the explicit `DesignSession` ([`2026-08-21_extension-points.md` §3](2026-08-21_extension-points.md)) later — **no source changes either way** |
| O13 | Argument passing into `resolve` — positional or named (§4) | **Named**, through `DataContext.argument(name)`; and into a hosted Logic through a **named `host(instructions, arguments: TupleValue)` overload** (§4.4, 2026-08-23). Positional was the DS8 elaboration's own "brittle, document it loudly" |
| O14 | Is a **nullable structural reference** (`is: DataSource, nullable: true`) usable for `ReadWorker.source` (§5.2a, §6.5)? | Evidence says yes (`GraphCreator.constructionLevels`, `GraphDefinitionAttempt`, `ObjectDefinitionReference.isNullable`, `NotationMetadataReader`), but there is **no shipped precedent** — ports use `creator:`, `binds` / `contexts` use `by: Nominal`. **Spike it before building on it** — blank, set, set across documents, **and deleted** (a dangling hard reference prunes the worker; decide whether that is acceptable or the reference must degrade — §15 C15). Fallback is `by: Nominal` + a design-time instantiation |
| O15 | Durable identity for `DataRef.source` (§3.3) | **A minted `DataSourceId` on the source object's notation — when a provider-bound source needs one. Deferred 2026-08-23:** every v1 ref is plain; the type lands in DS1, the minting / scan / validation land with the first JDBC-style source |
| O16 | Is the final session a Kotlin `DatedPathDataSource` or `LogicDataSource` + a shipped example Script (§4.4, §12) | `LogicDataSource` — it proves the extension point instead of adding a ninth Kotlin class. Keep the Kotlin source in reserve if date iteration in a Script proves clumsy |
| O17 | Does the `ObjectRegistry` document survive the §5.5a visibility fix? | It loses its only consumer. Keep it as a **widening** escape hatch for predicate false-negatives (never for `internal` types, §5.5a) and empty its shipped `IntRange` entry; retiring it outright is a separate, smaller call |
| O18 | `DataFormat` document — rename to `DataSchema`, or delete (§6.3, §10) | Rename and consume it as the declared-schema supply for `staticShape`. Deleting is acceptable; leaving it orphaned under a colliding name is not |
| O19 | When does heterogeneous-schema **superset normalization** land (§5.2b, §9) | With the design-time schema work, since it needs the pre-scan. Until then `ReadWorker` fails loudly — never silently, because both `SummaryWorker` and `CsvWriterWorker` lose data quietly |
| O20 | `DataCursor` — suspend per item (the review's proposal) or a plain pull reader the worker drives (§4) | **Plain pull reader [decided 2026-08-23].** Matches `CsvRecordReader`, keeps the handle context-free across a migrate, and keeps third-party cursors trivial. Per-item `runBlockingIo` is the shipped cost profile; batching several `next()` per offload is a worker-side optimization if a profile asks |
| O21 | When does the `DataSources` document land (§6.4a) | **After the arc**, when a project has sources that belong to no Job. Discovery is graph-wide from DS2 so the follow-up is additive; pickers must be written graph-wide now |
| O22 | Unit attributes onto the item lane — reader knob or downstream expression (§3.5, §5.6) | **Reader knob `attributes: ignore \| columns` [decided 2026-08-23]** — the reader is the only thing still holding the unit when the item is emitted; an expression would need the objects-in-scope machinery that left the arc |

## 12. Suggested build order

Sequenced so each step is independently useful and nothing is built before its consumer exists.
**Revised 2026-08-23** (third pass, §15); the elaborations in `docs/plans/next/DS*` are the execution
layer and follow this, not the previous ordering.

0. **Schema vocabulary move** (mechanical). `HeaderListing` / `HeaderLabel` / `HeaderLabelMap`
   out of Report's document package (§10). Import-only, no behaviour, and it must come **first** or the
   model types cement the wrong import.
1. **Model + lowering.** The §3.2 value types in kzen-auto-common — `DataRef.source` a nullable
   `DataSourceId` that nothing mints yet (§3.3), attribute order presentation-only with a canonical digest
   (§3.5), reserved fingerprint keys (§6.2), `DataShape`, `DataResolveResult` — with `ExecutionValue`
   round-trips, wire form and digests, plus `DataLocation` ⇄ `DataRef` conversion and the construction
   helpers §4.4 needs. No worker depends on it yet; the tests are the exercise.
1b. **Inference visibility fix** (small). Replace `visibleBuiltins` + the registry scan with the
   public-and-nameable predicate, and `isIterable` with `isStreamType` (§5.5a, O6). A standing bug
   independent of this arc — the hardcoded `IntRange` is the tell — and the prerequisite for a unit lane
   to type as `DataUnit`. May ride inside step 1.
2. **The suspend runtime: `DataSource` + `DataOpener` + `DataCursor` + `DataContext`, `FileDataSource`
   (resolve only) + the shared `FileDataOpener` + `DataOpenerLookup`**, and the generic `DataSourceActions`
   detached object for design-time resolve (§4). Wire to the existing `FileListingAction` (splitting out a
   blocking core) and `FlatDataSource` / `ReportDefiner` rather than reimplementing either; move that
   plumbing to its new home (§10); the Job `sources:` branch + graph-wide discovery by capability.
   **Spike O14 first — including delete.** No `DataSourceId` minting, no resolver, no `DataSources`
   document.
3. **`ReadWorker`** (§5.2a) — source-generic, `source:` a nullable structural reference,
   `emit: items | units`, `role`, `attributes: ignore | columns` (the `groupBy` parity path, §3.5),
   resolved manifest carried across migration with the open cursor detached, per-item `runBlockingIo`
   drive, `payloadFlow` from `staticShape`, heterogeneous schemas failing loudly (§5.2b). A/B against
   `CsvReaderWorker` / `MultiFileReaderWorker` over the same files — identical message streams; the old
   readers stay until that is green. **This plus step 4 is the trivial case: three cards, no code.**
4. **The editing surface** (§6.4): `MultiFileInputEditor` rewritten as `FileDataSource`'s attribute
   editor (typed selection, `editor:`-bound); generic source-card chrome (resolve preview + diagnostics)
   over `DataSourceActions`; the Job `sources:` section; the graph-wide source picker with auto-bind and
   the in-card source summary (§5.2a). `editor:` keys land with their registrations (§6.4). No id minting
   (O15 deferred), no `DataSources` document (O21). Steps 3 and 4 are one deliverable in two sessions —
   neither is demonstrable alone.
5. **`ReadPartWorker` + the 1:N transform cadence** (§5.3, §5.4b) — the second reader, sharing step 3's
   drain core; `Emitter.expandCadence`; handle ownership. This is what the child-Logic idiom (§5.6b) and
   role fan-out (§5.6a) read with. `ExpandWorker` (in-memory, generic) is **not** here — demand-driven (O1).
6. **Design-time shape** (§6.1–6.2): `inspectShape` on the file opener through `DataSourceActions`
   (`action=shape`), the schema cache as a service keyed on the stamped fingerprint (fixing
   `ColumnListingAction`'s stale-key bug for Report too), the declared-schema supply for `staticShape`
   (§6.3, O18), superset normalization (O19), editor dropdowns; the readers' `payloadFlow` reads the cache
   for explicitly-named parts.
7. **The writer yielding its ref** (§7) — a plain path; `ResultSinkWorker keep: all`; the resolved
   manifest published to the trace. Same-run composition only (§7.1).
8. **`LogicDataSource` + named host arguments + the dated example** (§4.4, O16, O13) — the first
   parameterized source, the one the ETL port needs, the proof that a user can author a source, and the
   arc's acceptance fixture (the §7.1 worked shape end to end). The first *stateful* source after it is
   what exercises the Context borrow (§4) and, eventually, O12.

Later, demand-driven: the `DataSources` document + controller (O21); `ExpandWorker` (O1); `LookupWorker`
(§5.7); `DataSourceId` minting / scan / validation with the first provider-bound source (O15); objects in
expression scope (O9). Steps 0–4 are the "capture the idea of a data source, generally and ergonomically"
ask, with 5–6 completing composition and the design-time surface; 7–8 are the ETL port. Third-party
sources and their UI ride on the general extension mechanism in
[`2026-08-21_extension-points.md`](2026-08-21_extension-points.md), not on anything in this list.

## 13. Second-pass review (2026-08-21b) — what changed and why

> ⚠ **Partly superseded by §15 (2026-08-23).** D1 (`DataScope`, non-suspend SPI) is **reversed**; D2's
> run-graph provenance stands; D3 (`DataSources` document) is **deferred**; D4 stands; D5 stands in shape
> with `LogicDataSource` now resolve-only. C1's premise was right and its conclusion wrong — see §15 C10.

A code-level review of the `DS1`–`DS8` elaborations against the tree. Recorded here rather than in the
plans because the plans are deleted on landing (CC-20: this document is the one home for rationale).
Nine were **corrections** — the previous draft or its elaborations said something the code contradicts —
and five were **design changes**.

### Corrections

| # | What was wrong | Where it now lives |
|---|---|---|
| C1 | `suspend fun units(…)` could not be called from `JobControl.runBlockingIo`, whose block is **non-suspend**; and the file source's resolve reused `FileListingAction.scanInfo`, which hops to `Dispatchers.IO` — the uncounted dispatcher that reads as false quiescence | §4 — the SPI is non-suspend and the offload moves into `DataScope.blocking` |
| C2 | Every inferred payload type would have been `Any`: `toTypeMetadata` approximates anything outside an eleven-entry `visibleBuiltins` and a one-entry `ObjectRegistry`. The expression route's headline case would not have compiled | §5.5a — the whitelist is replaced by a public-and-nameable predicate |
| C3 | Heterogeneous per-file schemas were to be a hard failure, but Report **merges** them (`DatasetInfo.headerSuperset`) — an unrecorded parity gap | §5.2b + §9; failure is kept for v1, with the real (downstream) reason stated, and O19 tracks the fix |
| C4 | "Unit attributes become columns for free via `flatView()`" — they do not: a `DataUnit` is not a `Map`, and a flat message never consults `flatView()` at all. Grouped-export parity was unfunded | §3.5 + §5.6 + §9 — identity requires the expression route |
| C5 | A declared-but-unregistered `editor:` name does **not** fall back to `DefaultAttributeEditor`; it renders `[Attribute editor not found: …]` with no input, so shipping the reader's `editor:` key before its wrapper bricks the field | §6.4 |
| C6 | `filter` was documented as a glob; `parseFilter` is a contains-all-words match on the file name | §6.4 + §9 |
| C7 | `DataManifest`'s digest was to guard the resume, but the reader **carries** the manifest and never re-resolves, so the guard never runs | §8.1 |
| C8 | `DataRows` was an `Iterable` that may be iterated once — a contract violation with a silent failure mode | §4 + §5.4a — a constrain-once `Sequence`, renamed `DataItems` |
| C9 | `ObjectStableId` was called rename-safe for persisted refs; `ObjectStableMapper` is in-memory and session-scoped, so a renamed source's ref dies on restart | §3.3 — a minted durable `DataSourceId` |

### Design changes

| # | Change | Why |
|---|---|---|
| D1 | **`DataScope` on every SPI call** | One concept absorbs three open problems: the blocking offload (C1), a stateful source's Context borrow (§4), and named arguments (O13). It is also where the design-time session plugs in with no source change |
| D2 | **Run-time source access comes from the run graph**, via a nullable structural reference — not `GraphInstanceCache` | The run already instantiates the whole filtered definition. Going through the cache means two instances, an imported statelessness contract, and unreachable Contexts (§6.5) |
| D3 | **A `DataSources` document, `Contexts`-style, with graph-wide discovery** | Cross-Job sharing is the normal ETL case, not an advanced one, and the pattern is shipped (§6.4a) |
| D4 | **A stateful source borrows a Context; it never owns a resource** | Keeps the object stateless, which both `GraphInstanceCache` and per-run construction require anyway, and shrinks O12 to a design-time owner (§4) |
| D5 | **`LogicDataSource`: resolution authorable as a Script** | Answers "is `DataSource` three seams fused?" without breaking the fusion a JDBC source needs (§4.4) |

### Reviewed and left alone

Worth recording so they are not re-opened: §3.4's flat list of self-describing units (the argument
still holds, and `DatasetInfo` remains the precedent); §4.2's source/format orthogonality; §5.6's
whole-unit rule and its three mechanisms; §5.4b's transform cadence; O1's separate `ExpandWorker`
archetype; O5's no-nesting.

Two limitations were reviewed and **accepted as stated**: there is no per-unit parallelism
(`ReadWorker` reads sequentially, `RunWorker` hosts sequentially) — performance is a separate topic and
J6 stays demand-driven; and there is no Report → Job conversion path, which is not wanted (§9).

## 14. As-built

*(Sessions append here as each lands — deviations, surprises, and anything a later reader could not
recover from the code. Note for the `DS*` elaborations, which point at "§13": that is now §13's
review record — write as-built notes **here**, in §14.)*

## 15. Third-pass review (2026-08-23) — what changed and why

An independent design review
([`2026-08-23_job-data-source_review.md`](2026-08-23_job-data-source_review.md)) of this document and the
`DS0`–`DS8` elaborations, whose claims were then verified against the tree (`JobControl`,
`EngineJobControl`, `Execution`, `CsvReaderWorker` / `CsvRecordReader`, `FormulaSourceWorker`,
`OutcomeTrace`, `ExecutionValue`). Six **corrections** (the 2026-08-21b draft said something the code
contradicts) and seven **design changes**. Recorded here, as §13 was, because the plans are deleted on
landing (CC-20).

### Corrections

| # | What was wrong | Where it now lives |
|---|---|---|
| C10 | The 2026-08-21b `DataScope` had **non-suspend** `blocking` / `host`, delegating to `JobControl.runBlockingIo` / `host` — which are both **`suspend`**. A non-suspend scope method cannot call either; the only escapes (`runBlocking`, or wrapping the whole SPI call from outside) defeat the offload or make `host` unreachable. D1 fixed C1's compile error by creating an unimplementable bridge | §4 — `resolve` / `open` are suspend; `DataContext` carries suspend `blocking` / `host` |
| C11 | `DataItems: Sequence` iteration was "plain … like `CsvReaderWorker`'s reads". `CsvReaderWorker` wraps **every** `readRecord()` in `runBlockingIo`; a `Sequence.next()` doing I/O runs it on the fixed engine thread, uninterruptible by cancel/migrate. The precedent was misdescribed | §4 — `DataCursor` is a plain pull reader the worker drives inside `runBlockingIo` (O20) |
| C12 | `payloadFlow` called `itemType(part)` — but nothing is resolved at walk time, so there is no `part`. DS6 conceded this only for "explicitly named files" | §6.1 — `staticShape(role)` is the walk-facing call; `inspectShape(context, part)` the editor-facing one |
| C13 | `DataUnit.attributes` order was "significant" and digested in order, while `Map` equality is order-insensitive — equal values, different digests | §3.5 — order is presentation-only; the digest canonicalizes by key |
| C14 | DS8's example Script declared two parameters (`from`, `to`) while its host call passed one `Map` as the single positional argument — not the same call shape | §4.4 — a named `host(instructions, arguments: TupleValue)` overload (O13) |
| C15 | The O14 spike tested blank and set, not **deleted**: a dangling hard reference prunes the worker from `transitiveSuccessful`, where a `by: Nominal` reference would warn. The structural choice is right (a collaborator, not data), but the failure mode was unexamined | O14 — the spike tests delete and the plan decides the degrade |

### Design changes

| # | Change | Why |
|---|---|---|
| D6 | **Suspend SPI + `DataContext`** (replaces D1's `DataScope`) | The only shape that can reach `runBlockingIo` and `host`; the source decides what to offload and stays a good citizen of the execution model (§4) |
| D7 | **Expressions never initiate source I/O.** `sales.units()`, `items(part)` helpers, `ExpressionDataAccess`, objects-in-expression-scope (O9/A) and `ExpandWorker`-as-bridge leave the arc. The readers are `ReadWorker` + `ReadPartWorker` | Resolution and reading are effects; only a worker can own the handle, the cursor, cancellation, quiescence and migration. Removes the largest single body of plan machinery (DS5's `JobControl.objects()`, `setObjects` / `setDataAccess`, the run-time resolver fallback) and the shared-source expression-visibility question with it (§5, §6.5) |
| D8 | **Source / opener split; `DataCursor`; file refs are plain; `DataSourceId` deferred.** `FileDataSource` resolves only; a shared `FileDataOpener` reads every plain ref; `LogicDataSource` needs no `items`; a sourced ref is a clear v1 failure | A file needs no provider to be read. Requiring every file ref to name its source added identity coupling with no read capability and pulled mint-on-insert / id scan / duplicate validation / a rename-restart regression into DS2/DS4/DS7 for nothing v1 exercises (§3.3, §4) |
| D9 | **`DataShape` (Tabular \| Object)**, `staticShape` vs `inspectShape`, the schema cache as a **service** keyed on a **fingerprint stamped into the ref at resolve** (`size`, `modified`) | Two different things were both called "schema" (C12); `cachedSchema` on the SPI leaked cache policy; the resolver already has size/mtime and the manifest is the natural carrier — one choice gives the cache key and a reproducible manifest (§6.1–6.2) |
| D10 | **One generic `DataSourceActions` detached object; `DataResolveResult(manifest, diagnostics)`** | A source carries no UI protocol; the card is generic for free; DS2's "put the skipped count somewhere, record the shape" becomes a defined contract (§4, §3.2) |
| D11 | **`DataSources` document deferred** (O21) | Discovery is graph-wide by capability from DS2, so cross-Job sharing already works; the document's real cost — an authoring controller — was never planned, and nothing in the arc needs it (§6.4a) |
| D12 | **`attributes: ignore \| columns` on the readers** (O22) | With expressions out, the reader is the only thing still holding the unit when an item is emitted; it is what Report's group column did and what J4's `groupBy` consumes. `groupBy` parity moves from DS5 to DS3 (§3.5, §5.6) |

### Reviewed and left alone

§3.4's flat list of self-describing units; §4.2's source/format orthogonality; D2 (run-graph provenance
via the structural reference); D4 (borrow, never own); §5.2b's fail-loudly; §5.6's whole-unit rule and
its three mechanisms; §8.1's carried manifest; O5, O10, O11, O16, O18, O19. The review's "persisted
artifact registry" was judged **not needed** now (§7.1) because v1 refs are plain paths. The review's
suspend `DataCursor.next()` was considered and **not** adopted (O20).
