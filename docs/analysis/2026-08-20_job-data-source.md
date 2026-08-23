# Job data sources — describing, resolving and reading data

> **Status: design record.** This document is the one home for the rationale behind Job data sources; the
> execution layer is `docs/plans/next/DS0`–`DS8` (master-plan ledger rows 49–58, one session each), and
> those files are deleted as they land, with their as-built notes appended to **§13** here. The Job
> flavour's other live plan is [`../plans/2026-07-25_job-improvements.md`](../plans/2026-07-25_job-improvements.md)
> (phases J3/J4 are the Report-subsumption spine this feeds). Per CC-20 no line numbers are cited;
> anchors are class / file names. Open questions are collected in **§11**; everything not listed there is
> settled, and the reason it is settled is stated where the decision lives.

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
§9); per-unit parallelism (a performance topic — `ReadWorker` reads sequentially and `RunWorker` hosts
sequentially, and J6 stays demand-driven).

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
| Job readers | `CsvReaderWorker`, `MultiFileReaderWorker`, `MultiFileInputEditor` | Replace with the source-generic `ReadWorker` (§5.2) + `FileDataSource`'s attribute editor (§6.4) |
| Expression type inference | `ExpressionReturnTypeInference` (`visibleBuiltins` + `ObjectRegistryScan`) | ⚠ **carries a bug this design would trip on** — see §5.5 |
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
(§5.2) reads a source; `ReadPartWorker` (§5.4) reads one part of a unit already on a lane. Nothing in
either knows it is a file.

## 3. The model

### 3.1 The four concerns to keep apart

| Concern | Question it answers | Lives in |
|---|---|---|
| **Query** | what do I want? | `DataQuery` — config, may reference run parameters |
| **Resolve** | what does that actually name, right now? | `suspend DataSource.resolve(context)` → `DataResolveResult(manifest, diagnostics)` (§4) |
| **Describe** | what shape is it? | `DataSource.staticShape(role)` → `DataShape?` (notation-only, walk-facing) and `suspend DataOpener.inspectShape(context, part)` → `DataShape?` (bounded read, editor-facing) (§6.1) |
| **Open** | give me the items | `suspend DataOpener.open(context, part)` → `DataCursor`, a plain pull reader the worker drives inside `runBlockingIo` (§4) |

Report fuses query+resolve into `FileListingAction` (edit time only) and describe into a separate
action with its own cache. Splitting them is what makes parameterized resolution and pluggable
non-file sources possible at all. Resolve and notation-only declaration are on the **source**;
bounded inspection and opening are on the **opener** — a file source is only a source, and a shared
file opener reads its plain refs (§4).

### 3.2 Value types

```kotlin
// The DURABLE identity of a PROVIDER-BOUND source object (JDBC, an authenticated API) — a value minted into
// the object's own notation once, at insert, never rewritten by rename / move / restart. NOT an ObjectStableId,
// which is session-scoped (§3.3). The TYPE exists so the model shape is final; NOTHING MINTS ONE in this arc —
// every v1 ref is plain.
value class DataSourceId(val value: String)

// A reference to one readable thing. PLAIN (source == null) when the ref is self-contained — a file path —
// which is every ref in v1; SOURCED when it can only be opened by its provider.
data class DataRef(
    val source: DataSourceId?,                 // null = plain / self-contained (the shared file opener reads it)
    val id: String,                            // canonical, digestible, displayable — a path for a file
    val attributes: Map<String, String> = mapOf()   // addressing extras + the FINGERPRINT a resolver stamps
                                                    // (reserved keys `size`, `modified` — §6.2, §8.1)
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
                                               // PRESENTATION ONLY (the digest canonicalizes by key — §3.5)
    val parts: List<DataPart>                  // ordered (semantic); partsOf(role) filters
): Digestible

// The resolution of a query at a point in time.
data class DataManifest(
    val units: List<DataUnit>
): Digestible

// What a resolve returns — the manifest plus what it could not / did not include.
data class DataResolveResult(
    val manifest: DataManifest,
    val diagnostics: List<DataDiagnostic>       // skipped units, unsupported extensions, warnings — text-canonical
)
```

`DataQuery` is deliberately **not** a fixed type — it is the source object's own configuration
attributes (a directory + filter; a date range + path pattern; a SQL statement + bind parameters).
Fixing a universal query shape would be the same mistake as fixing the ref shape.

### 3.3 Why `DataRef` is opaque, and why every v1 ref is plain

The alternative was to use `DataLocation` (file path | URL | unknown) directly. That fails because the
ETL port includes sources that are not location-addressable — a DB table with bind parameters, an
API cursor. Making the ref opaque means the source is the only thing that interprets it, which is
exactly the "fully general and customizable" property this design exists for.

The cost is that a `DataRef` alone is not human-meaningful without its source. Two things pay it back:

- `id` is required to be a **canonical string**: stable, digestible, displayable, and it round-trips
  through notation and `ExecutionValue` unchanged. A file source mints `C:/data/2026-01-01.csv`; a
  SQL source mints something like `orders?day=2026-01-01`. The user always sees *something*.
- `DataLocation` converts to and from a `DataRef` with `source = null` — the common case stays as
  cheap as it is today, and everything already written against `DataLocation` (browse listings,
  `FilePath` arithmetic, the `/file-listing` route) keeps working unchanged.

**A file ref needs no provider, so it names none.** Path + effective format + encoding is enough for a
shared file opener, so `FileDataSource` and `LogicDataSource` mint **plain** refs, and a persisted file
ref is a path — durable by construction. Requiring every file ref to name its `FileDataSource` would add
identity coupling without adding read capability, and it would pull mint-on-insert, an id→location scan,
duplicate-id validation and a rename-then-restart regression into DS2/DS4/DS7 for nothing the v1 arc
exercises. A **sourced** ref reaching a reader is therefore a clear failure ("provider-bound refs are not
supported yet"), never a silent plain-path fallback.

**When a provider-bound source arrives** (JDBC, an authenticated API), `DataRef.source` is a minted
durable `DataSourceId`: the `DataSource` archetype carries an `id: ""` attribute assigned a UUID by the
editor's insert command, hidden from the card (the signature-managed-attribute pattern) and never touched
by rename or move. Resolution is a graph scan for the object whose `id` matches, cached by notation digest
(the `ObjectRegistryDocument.scanCache` shape — Caffeine keyed on `Digest`). A document copy/paste
duplicates ids; that is **reported** by validation rather than prevented (the `LogicContextAnalysis`
duplicate-key precedent). Two alternatives are ruled out and should not be revisited: an `ObjectLocation`
is not rewritten by kzen-lib's refactors when it sits inside a *value*, so it dangles on the first rename;
an `ObjectStableId` is an in-memory, session-scoped mapping (`ObjectStableMapper` mints
`ObjectStableId(location.asString())` and maintains `id ⇄ location` across renames *within the process*,
and `snapshot()` / `seed()` exist to sync the client, not to persist), so a renamed ref resolves in-session
and is dead after a restart with no refactor to catch it. Minting, the scan and the validation land with
the first provider-bound source — **O15**.

### 3.4 Why a flat list of self-describing units, not `Map<Group, Set>`

The sketch that started this was
`ResourceBatch(Map<ResourceGroup, ResourceSet>)` with `ResourceGroup(Map<ResourceAttribute, ExecutionValue>)`
as the key. It loses on four counts:

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

### 3.5 Attribute values are text-canonical

`DataUnit.attributes` and `DataRef.attributes` are `Map<String, String>`, not typed values.

For: free equality/digest (needed for the schema cache key in §6.2); free notation and `ExecutionValue`
round-trip; direct `${date}` substitution into output path patterns; and it matches how the whole flat
lane already works — `FlatFileRecord` is text and `ColumnValue` converts at expression time. Against: an
expression that wants `unit.date` as a real date has to parse. That is the same cost every flat column
already pays, so it is not a new class of problem. If typed attributes are ever justified, they arrive
with the column-typing arc (§6.3), not before.

**Order.** Insertion order is kept for display (`LinkedHashMap`), but it is **presentation only**: `Map`
equality is order-insensitive, so an order-sensitive digest would make two equal units digest
differently. The digest canonicalizes by sorted key.

**Getting attributes onto the item lane is the reader's job.** ⚠ There is no free path: under
`emit: items` the message is `JobMessage.ofFlat(fileHeader, record)`, where `flatView()` is never
consulted; under `emit: units` the payload is a `DataUnit`, which is not a `Map`, so `flatView()`
materializes only the single synthetic `value` column. So the readers carry an
`attributes: ignore | columns` knob — under `columns`, each emitted flat record is widened with the
unit's attributes as leading columns (header = attribute names + part header). The reader *knows* it is
reading a unit, so this is not a class switch; it is ~20 lines; and it is exactly what Report's `groupBy`
regex → group column did and what J4's grouped export consumes. **`groupBy` parity therefore lands with
DS3** (§9).

## 4. `DataSource` is an object with a callable API, not a Worker

```kotlin
/** RESOLVE — the variable part. Every source has one. */
interface DataSource {
    /** Resolve the configured query into a point-in-time manifest (§8.1) plus diagnostics. */
    suspend fun resolve(context: DataContext): DataResolveResult

    /** The shape of what `role` yields, answerable from NOTATION ALONE — never IO; the walk reads this (O3). */
    fun staticShape(role: DataRole?): DataShape? = null
}

/** DESCRIBE + OPEN — for reading a ref. A file source is NOT one: the shared FileDataOpener reads its plain refs (§3.3). */
interface DataOpener {
    /** Open a part. Returns a handle the CALLER drives (see [DataCursor]). */
    suspend fun open(context: DataContext, part: DataPart): DataCursor

    /** The shape of one concrete part, from a DECLARATION or a BOUNDED read (a header row, `LIMIT 0`). */
    suspend fun inspectShape(context: DataContext, part: DataPart): DataShape? = null
}

/**
 * One open part: a PLAIN PULL READER — not suspend, not a Sequence. The owning worker drives it inside
 * `JobControl.runBlockingIo`, one `next()` per blocking unit, exactly as `CsvReaderWorker` drives
 * `CsvRecordReader` today; so every read stays counted by the CountingDispatcher and interruptible by
 * cancel / migrate, the worker carries the handle across a live edit and drives it with its NEW control,
 * and an implementer wraps a BufferedReader without learning coroutines.
 *
 * `shape is Tabular` ⇒ EVERY item is a `FlatFileRecord` under that header (the reader emits `ofFlat`);
 * otherwise items are payload objects (`ofPayload`). An interface member, not a class switch (CC-17).
 */
interface DataCursor: Iterator<Any?>, AutoCloseable {
    val shape: DataShape?
}

/** The per-call environment a source / opener runs in. */
interface DataContext {
    /** A run parameter / detached request parameter, BY NAME (never positional — O13). */
    fun argument(name: String): Any?

    /** Quiescence-visible blocking offload: `JobControl.runBlockingIo` at run time, `Dispatchers.IO` at design time. */
    suspend fun <R> blocking(block: () -> R): R
}

/** Tabular structure vs Kotlin payload type — two different things, and conflating them is what made
 *  the reader API and downstream inference ambiguous. */
sealed interface DataShape {
    data class Tabular(val header: HeaderListing): DataShape      // widens to typed columns later (§6.3)
    data class Payload(val type: TypeMetadata): DataShape
}
```

`DataContext` starts with the two capabilities v1 sources use: named run arguments and counted blocking.
Its `host(instructions, arguments)` member lands with `LogicDataSource` in DS8 (§4.4), delegating to the
named `JobControl.host` overload that DS7 first needs for `RunWorker.arguments`. A Context-registry
read lands with the first stateful source, together with the `JobControl` accessor it requires. Sources
consume this interface; they do not implement it, so adding those capabilities with their consumers keeps
the initial SPI smaller without creating a third-party implementation burden.

**Why `resolve` and `open` are `suspend`, and why a cursor is not.** `JobControl.runBlockingIo` and
`JobControl.host` are both **`suspend`** (`EngineJobControl` delegates to `Execution.blocking` / the
child-logic host), so a non-suspend SPI call has no legal way to reach either — the only escapes are
`runBlocking` (holds an engine thread, defeats the offload) or wrapping the whole call in one
`runBlockingIo` from outside (then `blocking` is identity and `host` is unreachable, which kills
`LogicDataSource`). So `resolve` is suspend, and the *source* calls `context.blocking { … }` around its
own blocking parts (the directory walk, a JDBC round-trip) and `context.host(…)` when it is a Logic. That
is exactly how `RunWorker` already uses suspend `host`, and `DetachedAction.execute` is suspend, so design
time needs nothing new. ⚠ `FileListingAction.scanInfo`'s internal `withContext(Dispatchers.IO)` is the
wrong dispatcher under a run — a blocking-core split (`scanInfoBlocking`) is what the source calls through
`context.blocking`.

The **cursor** is the deliberate exception, and the existing reader is the precedent: `CsvRecordReader`'s
KDoc — "a plain pull reader the Worker drives inside `control.runBlockingIo`, one `readRecord` per
blocking unit." A `Sequence` whose `next()` did file I/O would run that I/O on the fixed engine thread,
holding it and escaping cancel/migrate interruption. A suspend `next()` would work but makes the cursor
capture a context that is **stale after a live-edit migrate** (the resumed worker has a new `JobControl`)
and makes every third-party cursor a coroutine citizen. A plain `Iterator` the *worker* drives through
*its* control solves both, and the worker may batch several `next()` calls per offload if a profile ever
asks — **O20**.

**The source / opener split.** Resolution is the variable part and every source has it; opening is needed
only where a ref cannot be read without the provider (JDBC, an authenticated API, an object store). A file
part is self-contained — path + format + encoding — so `FileDataSource` implements *only* `DataSource` and
a **shared `FileDataOpener`** reads every plain ref, from any source. One opener registry
(`DataOpenerLookup`: `ref.source == null` → the file opener; otherwise → the owning source, which must be
an opener) is the single dispatch, owned by the readers. A JDBC source implements both interfaces on one
object; `LogicDataSource` (§4.4) implements only `DataSource`, mints plain refs, and needs no `open` of its
own.

The SPI is needed in **two** contexts:

1. **Design time** — the editor asks "what does this query resolve to?" and "what columns?" with no
   run in sight, over a detached action (Report does exactly this today with `FileListingAction` /
   `ColumnListingAction`). **One generic action** — `DataSourceActions` (a detached object taking
   `source=<location>`, `action=resolve | shape`) instantiates the source through `GraphInstanceCache`,
   builds a `DesignDataContext`, calls it and lowers the result — so a source carries no UI protocol and
   the card is generic for free.
2. **Run time** — from the **two readers** (`ReadWorker` resolves and reads a source; `ReadPartWorker`
   opens one part of a unit already on a lane — §5.2, §5.4), which own the context, the handle, the
   cursor, cancellation, and quiescence accounting. **Never from an expression**: source resolution and
   reading are effects, and an expression that performed them would hide I/O, cancellation and resource
   ownership inside generated code, with nothing to own the file handle or carry a position across a
   migrate. Expressions see *materialized* values — a `DataUnit` on a lane, a record — and nothing else.

Note what (2) means: there are exactly two data-specific workers, no data-specific port, and no
data-specific notation shape beyond the source object's own attributes. The source supplies
*configuration* (which directory, which pattern, which connection), *resolution* and *declaration*; the
opener supplies *read*; the readers supply the wiring onto ordinary lanes.

Being a notation object is the customization seam and is worth the object-ness: a third-party source is
another archetype in the graph, discovered through the object registry and classified **by capability,
never by class name** (CC-17) — the `JobServeCapability` / `JobSignatureCapability` pattern. It also gives
the editor something to bind a browse/preview UI to, which a bare function would not.

Two consequences of "design time" being on the list, both general rather than data-specific:

- **The source object is NOT a `DetachedAction`; one generic action calls it.** The editor's
  resolve-preview / shape calls go through `ModelDetachedExecutor.execute(actionsLocation, request)` on
  the single `DataSourceActions` object, which instantiates the named source by location
  (`GraphInstanceCache`, the `FileListingAction` / `ColumnListingAction` precedent) and calls `resolve`,
  or answers shape with `source.staticShape(part.role) ?: opener.inspectShape(context, part)`. Its
  `resolve` / `shape` action names are constants and unknown names fail clearly; two
  operations do not justify two registered objects and two well-known locations. Card chrome in the Job editor (preview the resolved manifest, show columns) is generic
  over sources because it only speaks this one protocol, and a source author implements nothing for it.
- **Resource lifetime — a source BORROWS, it never OWNS.** A file source is stateless; a JDBC / API
  source needs a connection. It does **not** hold one. It declares the Context it uses
  (`is: ObjectLocation, nullable: true, by: Nominal` — the `ContextBinder.binds` shape) and, when the
  first such source lands, reads it through a `DataContext.contextValue` capability added in that
  session. At run time that is the Context registry the engine already
  has: `Execution.resource(key, policy,
  value, closer)` opens with a declared `ResourceClosePolicy`, `Execution.resourceValue(key)` reads, and
  the read walks ancestors (`RunEngineContextTest.resourceValueReadableFromHostedChildViaAncestorWalk`),
  so a hosted child Job sees its caller's connection. ⚠ `JobControl` exposes no Context read today; the
  first stateful source adds it together with `DataContext.contextValue` rather than shipping a null stub.

  This is what keeps the object itself stateless, which matters twice: `GraphInstanceCache`'s reuse
  contract stays satisfied at design time, and **`GraphCreator.createGraph` instantiates every object in
  the Job document on every run** — used or not — so source construction must be side-effect free
  regardless. ⚠ Corollary: an object in the `sources:` branch that *fails* to create fails the whole run,
  since `createGraph` throws on any failure. Every source attribute must define when blank, and `resolve`
  must fail with a clear message instead.

  Design time then shrinks from "invent a resource model" to "a `DataContext` implementation with a
  project-scoped owner". v1 is request-scoped open/close inside a `DesignDataContext`, and **no source
  changes** when the explicit `DesignSession` of
  [`2026-08-21_extension-points.md` §3](2026-08-21_extension-points.md) arrives — **O12**.

### 4.1 Third-party sources — dynamically loaded objects, not a source-specific SPI

A `DataSourceDefiner` SPI beside the `ReportDefiner` format SPI would be the wrong level: the need is
general — *arbitrary* third-party Custom objects, of which a source is one kind — and the server already
has the hook. `GlobalMirror.register(delegate)` appends a fallback `ClassMirror`, so a plugin jar compiled
with `kzen-lib-reflect-ksp` brings its own `ModuleReflection`, is opened on a `URLClassLoader` at project
startup (the `PluginDocument` precedent), registers its mirror, and contributes its yaml notation. Reload
the project to pick up a change. A third-party source is therefore exactly what §4 says — another
archetype — with no data-specific plumbing. The open half is the **UI** for such objects, which is the
subject of [`2026-08-21_extension-points.md`](2026-08-21_extension-points.md) §2; the short version is
that UI extension is *server-driven* (generic editors + a standard detached query protocol) with Web
Components as the escape hatch, so a source ships zero JS in the common case.

**Definition time is deliberately absent from the two contexts above.** A `payloadFlow` that called an
effectful describe would mean IO during the payload-type walk, which runs on every notation revision.
**O3 says never**: the walk reads `DataSource.staticShape(role)` (notation-only) and the schema cache, and nothing
else.

### 4.2 Two orthogonal extension axes, kept orthogonal

| Axis | Question | Seam | Examples |
|---|---|---|---|
| **Source** | where does the data live, and what does a query name? | `DataSource` archetype | directory glob, dated path pattern, HTTP, S3, JDBC |
| **Format** | how are those bytes parsed into records? | existing `ReportDefiner` plugin SPI, keyed by `PluginCoordinate` | CSV, TSV, fixed-width, a third-party binary format |

Report already separates these and must keep doing so: a dated-path source over a third-party format
should require no new code in either. `DataPart.format` is the join between the axes, resolved by the
source's default when the user does not pin one.

### 4.3 A `DataRef` is self-opening, so there is no `ParameterDataSource`

A source whose "query" is a Job parameter holding a `DataUnit` — so a child Job could read the unit its
caller passed — is unnecessary. The child's parameter *is* the `DataUnit`; `FormulaSourceWorker("unit")`
puts it on a lane as a single payload (a non-stream type emits once — existing behaviour); and
**`ReadPartWorker(role: "main")`** opens the part. The dispatch on `DataRef.source` lives in the reader's
`DataOpenerLookup` (§4) — plain ref → the shared file opener; sourced ref → its provider.

This is where the ref (§3.3) pays operationally: a unit handed across a Logic boundary is **self-opening**.
Nothing at the receiving end needs to be configured with where the data came from — and for v1, where every
ref is a plain path, "self-opening" costs nothing at all.

### 4.4 Authoring a source without writing Kotlin — `LogicDataSource`

§2 criticises `ReportDocument` for fusing query + resolve + describe. The §4 split answers that
structurally, because the three parts have very different variability:

- **Resolve** is the variable part. It is a parameterized computation returning a list — which is
  exactly what a **Logic** is.
- **Open** is not variable at all for anything file-shaped: a byte source plus a format plugin, both of
  which already exist and work (`FlatDataSource` + `ReportDefiner` / `ReportInputChain`) — the shared
  `FileDataOpener`.
- **Describe** is a declaration (§6.3) or a bounded read.

The fusion stays *available* (a JDBC source implements both interfaces on one object, because resolution
and reading share a connection) and is never *imposed*. So one shipped implementation opens the extension
point:

```
LogicDataSource(instructions: <Script | Flow | Job>, arguments: [from, to])
    resolve(context)  = context.host(instructions, named arguments from context.argument(name))
                        → main component: List<DataUnit> (plain refs) → DataResolveResult
    // no open: the parts it mints are plain, the shared file opener reads them
```

A user authors resolution as a **Script** that returns a list of `DataUnit`s, and gets tracing,
stepping, breakpoints and pause-on-error for free — `JobControl.host` already does exactly this for
`RunWorker`. The parts it mints are plain refs (`source == null`), so opening needs no Kotlin and no new
SPI.

Two prerequisites, both implied elsewhere: `DataContext.host(instructions, arguments: TupleValue)` —
added here with its first caller and delegating at run time to the **named** `JobControl.host` overload
that DS7's `RunWorker` binding first needs; and expression-constructible model types — the §5.5
visibility fix plus a small helper family
(`DataUnit.of(attributes, parts)`, `DataPart.ofPath(role, path)`).

**This is a better final session than a hand-written dated-path source** (§12): the dated case becomes a
shipped example Script over `LogicDataSource`, proving the extension point instead of adding a ninth
Kotlin class. A Kotlin `DatedPathDataSource` stays in reserve if date iteration in a Script proves
clumsy — **O16**.

## 5. Workers

There is **no file-specific worker and no I/O in expressions**. `ReadWorker` reads any source;
`ReadPartWorker` reads any part of a unit already on a lane. That is the whole worker surface this design
adds.

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

### 5.2 The declarative reader — `ReadWorker`, source-generic

The trivial case decides this. Starting from a blank Job, "count the lines of one file" must be:
insert a **File source**, pick the file in it, insert **Read**, insert **Summary**, run — **three
cards, no code**:

```
ReadWorker(source: <DataSource>, emit: items | units, role: <DataRole>?, attributes: ignore | columns)
    -> item lane or unit lane
```

Three is the honest structure: a source, a reader, an aggregator. A composite ribbon tool ("Read File"
inserting both objects in one command) was considered and **rejected**: a palette entry that expands into
several objects is a shortcut, not a simplification — the user then has two objects they did not
knowingly create, and the card they clicked is not the card they must edit. As simple as possible, not
simpler.

What *does* close the ergonomic gap, without a shortcut: (i) **auto-bind** — inserting `Read` into a
Job with exactly one source binds `source` immediately; and (ii) render the bound source **inside** the
Read card as a read-only one-line summary (`FileDataSource "input" · 1 unit · x.csv`) with an
affordance that focuses the source card. `ReferenceLinkAttributeView` already does the link half. That
removes the two-regions problem, which is the real complaint, while leaving the object model honest.

- **`source`** is a **nullable structural reference** to a `DataSource` object
  (`is: DataSource, nullable: true`), which is what makes it both blank-tolerant on palette insert and
  a real graph edge. kzen-lib supports this directly: `GraphCreator.constructionLevels` checks
  `reference.isNullable(objectMetadata)` on an empty reference and contributes no edge and no failure,
  `GraphDefinitionAttempt` does the same nullability walk, `NotationMetadataReader` reads `nullable`
  from a map-shaped type notation, and `ObjectDefinitionReference.isNullable` reads
  `attributeTypeMetadata.nullable`. So `filterTransitive` pulls the target in — **including across
  documents**, which a weak `by: Nominal` reference would not — `JobRun`'s `GraphCreator.createGraph`
  instantiates it once in the run's own graph, and kzen-lib's `ReferenceAttributeDefinition` injection
  hands the worker the instance (the channel-port precedent). ⚠ There is no *shipped*
  nullable-structural-reference precedent (the channel ports use `creator: JobChannelCreator`;
  `binds` / `contexts` use `by: Nominal`), and a dangling **hard** reference prunes the holder from
  `transitiveSuccessful` rather than warning — so pin it with a short spike covering blank, set,
  cross-document **and deleted** before building on it; the fallback is `by: Nominal` plus a resolver.
  **O14.**
- **Where the instance comes from.** The run graph, not `GraphInstanceCache`: `JobLogicCompiler` builds
  `synthesis.graphDefinition.filterTransitive(documentPath)` and `JobRun` calls
  `GraphCreator.createGraph(filteredDefinition, graphEnvironment)` over the **whole** filtered definition,
  so every object in the Job document — and everything a structural reference reaches — is instantiated
  once, in the run's own graph, before the first Worker starts. Going through the cache instead would mean
  two instances of the same object during a run (the cache filters by `AutoConventions.serverAllowed`, the
  run does not, so they can disagree), would import the cache's statelessness contract into the run, and
  would put the instance outside the run's frame where §4's Context borrow cannot reach it. So: **run time
  = the run graph; design time = the generic `DataSourceActions` over `GraphInstanceCache`.**
- **What it emits.** Whole **units** whenever a unit is not trivially single-part; **items** is the
  degenerate single-role convenience (the trivial case), and the lane carries records so Summary
  counts lines. Multi-role units are *never* split uniformly by the reader — a unit with
  `main` + `reference` parts has no single item schema; turning such a unit into a uniform stream is
  custom logic, not the reader's job (§5.6). `role:` selects the role whose `partsOf(role)` are opened
  in order under `emit: items`;
  heterogeneous schemas under `items` are a validation error, not a silent concatenation — **and the
  reason is downstream, not the reader** (§5.3).
- **`attributes: ignore | columns`** (§3.5): under `columns`, every emitted flat record is widened with
  the unit's attributes as leading columns. This is the unit-identity-on-the-item-lane the reader alone
  can provide, and it is the `groupBy` parity J4 consumes. Attribute key sets differing across units are
  heterogeneous headers — §5.3 applies. An attribute name colliding with a part column fails naming both;
  it never shadows.
- **`payloadFlow`.** Under `items`, publishes the source's `staticShape(role)` (notation-only, no IO —
  `Tabular` → `flatColumns`, `Payload` → `payloadType`) and, in DS6, the schema **cache** for explicitly
  named parts — a miss is "unknown", never IO on the walk, so O3 holds. Under `units`, `payloadType =
  DataUnit`. Nothing is resolved at walk time, so no call may take a `DataPart`.
- **Cursor.** This is the one place a positional cursor lives — `(unitIndex, partIndex, itemIndex)` with
  the open `DataCursor` detached across a migration, exactly `CsvReaderWorker`'s pattern: the worker calls
  `control.runBlockingIo { cursor.next() }` per item, so the resumed worker drives the carried handle with
  its *new* control (§4). The resolved manifest is **carried** across the migration and never re-resolved,
  and adoption is guarded on the source's definition digest plus this worker's own config — see §8.1.
- **Mode knob vs two workers** — **O11**. A mode knob changes the card's output cardinality. That
  objection is weak here: a source worker has no incoming lane, so there is no ordering question and no
  migration state to split; only the published payload type differs, which `payloadFlow` already handles
  per mode. The knob wins. If "every card has exactly one output shape" ever becomes a rule, the clean
  split is `Resolve` (source → units) + `Read` (source → items).
- **One implementation.** `ReadWorker` and `ReadPartWorker` (§5.4) share one open-and-drain core —
  `DataOpenerLookup` + the per-item `runBlockingIo` drive + flat-vs-payload by `cursor.shape` + the
  attribute widening + the detach-on-migrate handle discipline — lifted, not copied (CC-12). They differ
  only in where the unit comes from (resolved here; the incoming payload there) and in cursor scope
  (whole manifest vs one unit), and both KDocs say so (CC-21).

`ReadWorker` replaces `CsvReaderWorker` and `MultiFileReaderWorker`; `MultiFileInputEditor` becomes
`FileDataSource`'s attribute editor (§6.4). The worked trivial case, for the record:

1. Palette → **Data → File**. A source card appears in the Job's *Data sources* section. In it, the
   **file browser** (the `FileDataSource` attribute editor for `files`): directory, filter, listing,
   click the file. Format / encoding default from the extension. The card's generic chrome shows
   "1 unit · 1 part · `C:/data/x.csv`" and, on **Columns**, the header — via the generic detached
   action, no run.
2. Palette → **Sources → Read**. `source` is **already bound** (auto-bind: exactly one source, blank
   attribute), and the card shows it as a one-line summary.
3. Palette → **Summary**; auto-wired by adjacency (`JobChannelDerivation`). Run. Summary's live row
   count is the line count (less the header if `header` is on).

Scaling without changing shape: the same `Read` card with `source:` pointing at a `sales` source in
another Job's `sources:` branch (discovery is graph-wide by capability, §6.5); or `Read` with
`emit: units` feeding `RunWorker` over a per-unit child Job (§5.6b); or a `LogicDataSource` whose
resolution is a Script over run parameters (§4.4) — read by the very same `Read` card. Same objects,
same lane.

### 5.3 Why heterogeneous item schemas fail rather than merge

Report *does* merge them — `DatasetInfo.headerSuperset()` unions the columns across files, and every
record is read against the superset with a missing column rendering `<missing>` (the `RecordHeaderIndex`
/ `CalculatedColumnEval.columnValue` path). So a hard failure in `ReadWorker` is a **parity gap**, and
§9 tracks it as one.

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
normalization** — **O19**.

DS6 exposes the policy as `schemaMode: strict | superset`, default `superset`. This is not merely a
pre-scan cost switch: `strict` is an explicit data contract that rejects an unexpected added or removed
column, while `superset` accepts schema variation without losing later columns. The name describes the
semantic choice; its bounded-read cost is a documented consequence of `superset`, not the meaning of the
attribute.

### 5.4 The transform side is 1:1 — the one real gap, and `ReadPartWorker` fills it

`FormulaWorker.payload` **replaces** the payload: one message in, one message out. Nothing existing
turns one element into many. The framework permits it — `TransformWorker.onElement` may call
`emit.send` any number of times — but no worker does.

For data the 1:N transform that matters is *"a `DataUnit` is on my input lane; give me the items of
one of its parts"*, and it is a **data worker**, not an expression:

```
ReadPartWorker(input: <unit lane>, role: "main", attributes: ignore | columns)   → item lane
```

It takes each incoming payload (must be a `DataUnit` — `payloadFlow` validates the upstream type, which
is why §5.5 matters), selects `unit.partsOf(role)` in order, opens them through the same
`DataOpenerLookup` + drain core
as `ReadWorker` (§5.2 "one implementation"), and emits `ofFlat` / `ofPayload` by `cursor.shape`. It is
what the child-Logic idiom (§5.6b) reads with, what a grouped main-plus-reference pipeline uses per role
(§5.6a), and the only place besides `ReadWorker` that opens anything. Its cursor is scoped to the
*current unit*: migration carries the active input batch, its element index, the unit, part/item position
and open cursor.

Two prerequisites it owns, both general:

- **A migration-safe 1:N transform base.** `TransformWorker` removes a whole input batch from its
  channel before calling `onElement`; a checkpoint inside that hook would strand the current element
  and the rest of the local batch during migration. `ExpandingTransformWorker` therefore owns the
  active batch and element index as fields, includes them in its migration snapshot, and flushes +
  checkpoints every output `batchSize` while expanding the current element. The current element is
  replayed against the adopted cursor after migration; the remaining elements come from the carried
  batch, not from `JobChannel.drainBuffered`. This is the general 1:N execution strategy and the future
  `ExpandWorker`'s base, not an `Emitter` mode bolted onto the 1:1 transform contract.
- **Handle ownership** — the open cursor closed in `onClose` unless detached, and at exhaustion.

A generic in-memory **`ExpandWorker`** — a stream-valued expression over an *already-materialized* value
(`(1..payload)`, a `List` payload's elements) — is a reasonable worker and would share the same cadence,
but nothing in this design needs it: it is not a bridge for effectful reading, and `groupBy` parity does
not depend on it (§3.5). Build it on demand, as a plain stream expander with **no** `flatHeader` probing
(it never drains a cursor), and as a separate archetype rather than a knob on `FormulaWorker` —
`FormulaWorker`'s lanes are cardinality-preserving, and mixing in a cardinality-changing mode muddies both
ordering and migration state. **O1.**

### 5.5 The inferred payload type does not survive today — and that is a bug, not a limit

Everything above assumes a `DataUnit` on a lane is *typed* as a `DataUnit`. It is not.

`ExpressionReturnTypeInference.toTypeMetadata` approximates any classifier that is not in a hardcoded
`visibleBuiltins` set, or in the `ObjectRegistry` document's declared class list, down to `Any`
(nullability preserved). The shipped registry (`registry-jvm.yaml`) holds exactly one entry,
`kotlin.ranges.IntRange`, and `visibleBuiltins` holds eleven. So `ReadWorker(emit: units)` would publish
payload type **`Any`**, `ReadPartWorker.payloadFlow` could not validate its input, and a downstream
`FormulaWorker` could not see `.attributes`.

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
not because someone listed it; every first-party type including the §3.2 model works; a class from a
dynamically loaded plugin jar (§4.1) works with no registration; and an `internal` / synthetic / local
type still degrades to `Any`, which is the property the whitelist existed to protect.

Deliberately **not** the fix: adding the data model to `visibleBuiltins` (hardcoding first-party names
into a general mechanism) or declaring it in `ObjectRegistry` (routing first-party code through a
third-party extension mechanism that is neither finished nor needed here).

The same class carries a second, related limit: `isIterable` tests `isSubclassOf(Iterable::class)`, and
`kotlin.sequences.Sequence` does not implement it — so a lazy `Sequence`-valued expression classifies as
*single-emission*, one message holding the sequence object, element type lost. The classification widens
to **`isStreamType`** covering `Iterable | Sequence | Iterator`, with `iterableElementType` →
`streamElementType` projecting onto whichever supertype matches (the same `allSupertypes.firstOrNull`
mechanism). Small, entirely general, and `FormulaSourceWorker` gains identically — **O6**.

Two follow-ons worth stating rather than discovering:

- `ObjectRegistryScan` loses its only consumer — `ExpressionReturnTypeInference` is the sole reader;
  `WorkerLaneContext` and `ScriptDefinitionContext` merely carry it. No real public, importable class
  rejected by the predicate has been produced, and a stubbed predicate would not prove one exists.
  Retire the `ObjectRegistry` document and its scan/threading in this session rather than preserving an
  untestable widening hatch — **O17**.
- The visibility fix types the *unit*; it does **not** type a part's **items**. That is a schema question,
  not a Kotlin-inference one, and its answer is the source's `staticShape(role)` (§4) — notation-only, so the
  walk can read it with no IO. See §6.3 for where a source *gets* a declaration.

### 5.6 Scoping a unit's processing — three mechanisms

This is the "main dataset + reference data, processed as a unit" question.

First, the rule that makes the question well-posed: a multi-role unit flows **whole**. No reader or
framework piece splits it uniformly — there is no uniform way to — and making it consumable item-by-item
is the pipeline author's explicit choice: one `ReadPartWorker` per role the pipeline wants (§5.4), or a
third-party transform that turns the unit into whatever uniform type that pipeline wants. The mechanisms
below are about *where* that logic runs and what boundary it sees.

The weaker half is **unit identity**, and the reader provides it: `attributes: columns` widens each flat
record with the unit's attributes as leading columns (§3.5). That is what J4's `groupBy: <column>` export
consumes, and it is a reader step because the reader is the only thing that still holds the unit when the
item is emitted.

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
  gets the weaker form (group **by column value**) from `attributes: columns` alone, this is not yet
  paying for itself.

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
Demand-driven; not part of the arc.

The ordering constraint is real and must be stated in the worker's contract: the lookup must be fully
loaded before the main lane queries it. Under (b) that is trivially arranged inside the child Job;
under (a) it is the worker's own responsibility (drain the reference input to end-of-stream before
serving the first request).

## 6. The design-time surface

### 6.1 Schema: two consumers, two questions, and only one of them is the walk

"What columns does this part have?" is tabular structure; "what Kotlin type is each emitted item?" is a
payload type. A field map is not an item type, and treating both as "schema" makes the reader API and
downstream inference ambiguous. The vocabulary is `DataShape` — `Tabular(header)` or `Payload(type)`
(§4) — and the two calls are split by **what they may do**, not by what they return:

- `DataSource.staticShape(role): DataShape?` — answerable from **notation alone**, never I/O. This is what
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

**The payload-type walk** gets `source.staticShape(role)` and nothing else — never I/O. `ReadWorker`
already holds its source and asks it directly. `ReadPartWorker` has no source in hand, so it stays
statically unknown. So:

| Lane | Static scope for downstream expressions |
|---|---|
| declared `Payload(type)` | the item type as receiver, members bare — full compile-time validation (needs §5.5, or every such type flattens to `Any`) |
| declared `Tabular(header)` | `flatColumns` known; expressions validate against the header |
| nothing declared (a directory-walk file source) | statically unknown; `KotlinSyntaxValidator` syntax-only, as today's CSV lane — until the DS6 cache is primed for explicitly-named parts |
| `emit: units` | `payloadType = DataUnit` (needs §5.5) |

Unknown must remain legal at every step; it already is, and this design does not make any lane *less*
known than it is today. It simply declines to promise the walk something it cannot deliver without
doing IO at define time.

### 6.2 Caching, and a bug to fix on the way

⚠ `ColumnListingAction` caches an extracted `HeaderListing` as `columns.csv` under a path keyed on
`(dataLocation, pluginCoordinate)` — **with no size or modification time in the key**. An edited file
therefore serves stale columns until the cache is cleared by hand. Any schema cache in this design
must key on `(ref.id, format, encoding, size, modified)` and must degrade to "don't cache" where it
cannot.

**Where size/mtime come from:** the resolver **stamps them into the ref at resolve time** —
`DataRef.attributes[size]` / `[modified]`, reserved text-canonical keys — because
`FileListingAction.toFileInfo` already has them from `BasicFileAttributes` and the manifest is the
natural carrier. That one choice gives the cache key *and* a reproducible manifest: a manifest whose refs
carry a fingerprint records what was read, and a changed file changes the digest. A content digest is
deliberately **not** stamped (a full read).

Cost discipline matters here because the editor may ask on every click: `inspectShape` must be a
bounded read (a header row, a `LIMIT 0` query), never a full scan — `ReportHeaderReader` already reads
only as far as the header, so the file case is fine — and the walk reads the cache only.

### 6.3 Column types — excluded, but the landing site already exists

Real ETL wants typed columns. But `HeaderListing`, `FlatFileRecord`, `ColumnValue` and
`WorkerLane.flatColumns` are text-canonical end to end, with conversion at expression time. Typing
that is its own arc with a wide blast radius, and doing it inside this change would double the risk
of both. `DataShape.Tabular(HeaderListing)` widens to a typed schema later without any change to the
model in §3.

**A typed-schema document already ships.** There is a `DataFormat` document archetype
(`common-document.yaml`, `group: "Customize"`), backed by `DataFormatDocument`, `FieldFormatListSpec` /
`FieldFormatSpec` — a map of field name → **`TypeMetadata`**, i.e. exactly typed columns — with a
`DataFormatController` in `data-js.yaml` and a `FieldFormatSpecTest` pinning the notation. **Nothing
reads it.** It is a shipped-but-unconsumed authoring surface.

That matters three ways:

1. **It is the natural supply for `staticShape(role)` (§6.1).** A source declares a schema document
   nominally and answers `staticShape` from the declaration — no IO, so the payload-type walk can read it
   (O3 holds by construction), and a source whose reading is expensive still gets design-time types. This
   is the *declared* half of §6.1's resolution order, above the pre-scan.
2. **The name collides, and the document is the one that should move.** Report's own UI labels the
   per-file plugin coordinate "Format" (`InputSelectedFormatController`), and `InputDataSpec` agrees,
   so `DataPart.format` is consistent with shipped vocabulary. Rename the *document*
   `DataFormat` → **`DataSchema`** — it declares field types, not a parse coordinate — or delete it.
   Cheap either way: one archetype, one controller, one spec package, one test. It is user-facing, so it
   is the user's call — **O18**. Leaving it orphaned under a colliding name is the one unacceptable
   outcome.
3. **It owns a package this design would otherwise take.** `server/objects/data/` is
   `DataFormatDocument`'s and `data-js.yaml` exists — see §10.

### 6.4 Where the file-selector UI lives — on the source object, as an ordinary attribute editor

The browser is **`FileDataSource`'s attribute editor** and nothing more. `AttributeWrapperLookup`
reads an attribute's `editor:` metadata key, which names a wrapper object; `AttributeEditorManager`
resolves that name against its autowired `List<AttributeEditor>` and falls back to
`DefaultAttributeEditor`. That string contract is documented in the codebase as *the* open-set
extension seam, and `MultiFileInputEditor` is already bound through it — so the implementation
largely exists. What changes is *what it edits*: the file source's selection attributes (directory,
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

**Third-party sources and their UI.** The general mechanism — generic editors driven by attribute
metadata plus a standard detached query protocol (options / browse / preview / validate) that *any*
object answers, with Web Components as the escape hatch for rich editors — is in
[`2026-08-21_extension-points.md`](2026-08-21_extension-points.md) §2. The file browser is itself
the first customer of that protocol (it already browses through the generic `/file-listing` route).

**Two editor mechanics to get right:**

- ⚠ **An `editor:` key and its registration must land together.** `AttributeEditorManager` resolves
  `AttributeWrapperLookup.wrapperName(…) ?: DefaultAttributeEditor.wrapperName` — the fallback fires
  when the attribute has **no `editor:` metadata at all**. A declared-but-unregistered name is a
  `find` miss, and `render` then emits the literal text `[Attribute editor not found: <name>]` with
  **no input**. So declaring `editor: SelectDataSourceEditor` before the wrapper exists bricks the
  field. Two fixes, both worth doing: land the key and its `@Reflect` registration in one change, and
  make the name-miss fall back to `DefaultAttributeEditor` with a small warning so a typo degrades
  instead of bricking (~5 lines).
- ⚠ **`filter` is not a glob, and must not be labelled one.** `FileListingAction.parseFilter` trims,
  lowercases, splits on whitespace and requires the file **name** to contain **every** token
  (`filterParts.all { name.contains(it) }`). So `sales csv` matches `2026-sales.csv` and `*.csv`
  matches nothing. Keep the one dialect, and put its shape in the field's placeholder — a user typing
  `*.csv` and getting an empty list is the likeliest first-five-minutes failure of the feature.

### 6.5 Where a source object lives

- **`DataSource`** — the abstract archetype.
- **The Job's own `sources:` branch** (`is: List, of: DataSource, by: NestedList`, beside `parameters:` /
  `workers:` — never under `workers:`, which would break `JobChannelDerivation`) is **the** authoring
  surface. It is co-located with the workers that use it and is automatically in the run graph.
- **`DataSourceConventions.allDataSources(graphNotation)`** — every object whose inheritance chain,
  **dropping self**, reaches `DataSource`. ⚠ The `drop(1)` is not cosmetic: `ContextConventions.isContext`
  does it so the abstract archetype does not match its own filter and offer itself in every picker.
  (`isChannelArchetype`'s bare `.any` is the shape *not* to copy.)

Discovery is therefore **graph-wide by capability**: a source in *any* Job's `sources:` branch is visible
to every picker, so cross-Job sharing — the normal ETL case — works with no extra document, and a source
"graduates" by cut/paste.

A **`DataSources` document** (`group: "Customize"`, `meta.sources: {is: List, of: DataSource, by:
NestedList}` — a direct copy of `Contexts`, whose design comment states the rule to reuse verbatim:
*"this document is AN authoring surface, never the home"*) adds a home for sources belonging to no Job.
What it *costs* is a controller with insert / rename / delete / duplicate behaviour and its own card
rendering. Nothing in the trivial case or the ETL fixture needs it, so it lands as a follow-up — **O21**.
Pickers are written graph-wide from the start, so that follow-up is purely additive.

## 7. The Logic boundary

### 7.1 Data flows out as well as in

"Invoke a Job for a specific input file, then take the output file" needs **both** directions:

- **In:** the Job declares a `parameters` entry typed as `DataUnit` (or `DataRef`). `JobControl.parameter`
  returns it, and each part is self-opening (§4.3) — no configuration at the receiving end.
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
  RunWorker(instructions: PerDayJob,
            arguments: {date: 'attributes["date"]'})           -> result lane (one DataRef per day)
  ResultSinkWorker(result: outputs, keep: all)

PerDayJob(parameters: unit: DataUnit, date: String; results: main: DataRef)
  FormulaSourceWorker(code: "unit")                            -> the unit, once   [existing worker]
  ReadPartWorker(role: main, attributes: columns)              -> item lane (with `date` stamped)
  LookupWorker  <- ReadPartWorker(role: reference)
  FilterWorker / FormulaWorker …
  ExportWriterWorker(path: "out/${date}.csv", result: main)    -> yields DataRef
```

The per-unit path is explicit and generic. `RunWorker.arguments` is a map from child parameter name to a
Kotlin expression evaluated against the incoming message with the same receiver/column/Job-parameter scope
as `FormulaWorker.payload`; the incoming boundary value still binds the child's first parameter. Here
`attributes["date"]` binds the child's named `date` parameter. Both writers resolve non-reserved `${name}`
placeholders from `JobControl.parameter(name)` in `onStart`, so an empty unit still creates and yields its
file. `RunWorker` knows nothing about `DataUnit`; it only evaluates declared bindings and hosts a named
`TupleValue`.

One neutral commonMain `PathPatternSubstitution` performs `${name}` replacement. `OutputExportSpec`
prepares its sanitized `${report}` / `${group}` / `${time}` / `${extension}` values and delegates to it;
the writers add scalar Job parameters. Unknown placeholders fail clearly. This is one substitution grammar,
not a second writer-specific dialect.

A writer yields only after successful finalization: close/finish the buffered or compressed container,
stat the completed path, then publish its `DataRef`. `onClose` remains an idempotent fallback for failure or
cancellation. Yielding or fingerprinting from `SinkWorker.onComplete` before the writer is finalized would
publish an incomplete container.

`ResultSinkWorker` keeps `first|last` today; collecting *all* per-unit refs into a list result wants a
`keep: all` mode — **O2**, a separate small change, not entangled with the model.

**Same-run composition, not a persisted result.** The shape above is *nested* composition: the child's
`DataRef` travels to `RunWorker` in-process as a `TupleValue`. A ref that a *future, independent* run
discovers is a different feature — `OutcomeTrace` deliberately drops a success's tuple, and
`ExecutionValue.ofArbitrary` lowers scalars / lists / maps, not domain objects, so a yielded ref is not
automatically persisted anywhere a later run can query. Two things make that acceptable now: the
writer's yielded ref is a **plain path** (durable by construction, §3.3), and the caller that stores it is
the one who decides where. A results registry with retention and naming is optional and later.

### 7.2 `ExecutionValue` lowering

`DataRef` / `DataPart` / `DataUnit` / `DataManifest` / `DataResolveResult` each need a canonical
`ExecutionValue` form because they cross REST (detached actions, run arguments), notation defaults, and
the trace display. With text-canonical attributes (§3.5) this is a mechanical map/list lowering with no
bespoke codec — the `DataLocation` precedent (a hand-written serializer whose wire form is the value
object's own canonical string) is the pattern to follow, and `asCollection` / `ofCollection` pairs already
exist throughout for the value-tree plane.

`DataRef.source` lowers as its `DataSourceId` string — null for every v1 ref — so no `ObjectStableId`
serializer is needed and kzen-lib stays untouched. ⚠ `ExecutionValue.ofArbitrary` does **not**
auto-lower a domain object sitting inside a `TupleValue`; callers must call `asExecutionValue()`
explicitly at any boundary that lowers a result tuple.

## 8. Run-time concerns

### 8.1 Resolve once, then treat the manifest as run state

The moment resolution becomes dynamic, resolving on demand becomes a correctness hazard: two reads of
a directory can differ mid-run. So `ReadWorker` resolves **once** per run, and **the resolved manifest is
carried across a live-edit migration** — the resumed instance continues over the *same* list and
re-resolution never happens, closing the hazard rather than detecting it. Adoption is guarded on the
source's **definition digest** plus the worker's own config, which is also the honest guard: it does no IO
at migration time, and it restarts on an edited query even when the directory is unchanged. State that in
the KDoc.

(For contrast with the existing readers: `MultiFileReaderWorker` guards the equivalent hazard by comparing
its `paths` attribute on `loadMigrationState`, coherent only because the set is frozen config;
`FormulaSourceWorker` re-evaluates its expression on resume and guards on `code` equality, which does not
see a changed directory at all.)

`DataManifest` stays `Digestible`, but for its surviving consumers — the run-record trace stamp and
diagnostics — not for a resume guard that no longer runs. Do not restore a manifest-digest comparison: it
has no counterpart. With the fingerprint stamped into each ref (§6.2), that digest also says whether the
*files* were the same, not only the selection.

The resolved manifest should also be published — as worker progress and/or trace — so a run records
what it actually read. That is both an observability win and the reproducibility story for an ETL
port.

### 8.2 Cursors

`CsvReaderWorker` and `MultiFileReaderWorker` carry a real positional cursor — `(fileIndex, position)` —
detaching the open reader at `captureMigrationState` so the rebuilt instance resumes at the exact byte.
Both data readers inherit that: the open `DataCursor` is the handle, detached across the migration and
driven onward by the new instance's control (§4, §5.2, §5.4). For plugin-format readers positional resume
is out of reach either way (framers are stateful); J3 already records restart-on-edit as the acceptable
v1, and a reader over a plugin format inherits that.

## 9. Report parity map

| Report capability | This design |
|---|---|
| Browse directory + filter | `FileDataSource`'s attribute editor over the existing `/file-listing` route (§6.4). ⚠ `filter` is a contains-all-words match on the file name, **not** a glob |
| Selected file list | resolved `DataManifest`, shown as a preview table in the source card (via the generic detached action) |
| Per-file format (`InputDataSpec.processorDefinitionCoordinate`) | `DataPart.format`, defaulted by the source (`actionDefaultFormat` logic) |
| Data type filter (`InputSelectionSpec.dataType`) | source-level constraint on which formats it offers |
| `groupBy` filename regex → `DataLocationGroup` | source-level attribute extraction → `DataUnit.attributes` |
| Grouped export | `attributes: columns` on the reader (§3.5, §5.6): unit attributes become leading columns, which is what J4's `groupBy: <column>` consumes. Lands with **DS3** |
| **Header superset across files** (`DatasetInfo.headerSuperset`) | ⚠ **gap in v1.** `ReadWorker` **fails** on heterogeneous item schemas rather than merging them — deliberately, because the loss would otherwise be silent downstream (§5.3). Superset normalization lands with the design-time schema work (O19) |
| Column listing (`ColumnListingAction`) | `FileDataOpener.inspectShape` — editor pre-scan through the generic action (and a declaration via `staticShape`, §6.3), plus `ReadWorker`'s `payloadFlow` from `staticShape` and the DS6 cache (§6.1) |
| Encoding detection (`ReportUtils.encoding`) | `DataPart.encoding`, source-defaulted at resolve, opener-inferred when null |
| Multi-file as one stream | `ReadWorker` (§5.2) — one card, any source |
| Row-level data preview | ⚠ **deliberately absent.** Report shows rows; this design shows the **manifest** and the **columns**, and nothing else at design time. "Read me ten rows" assumes rows are a meaningful unit and that obtaining one is cheap — neither holds for a source whose items come out of a full pipeline. §6.2's bounded-or-declared rule is the contract |
| — (no Report equivalent) | parameterized resolution, multi-part units, non-file sources, cross-Job composition |

**Not in scope, and deliberately so.** There is no Report → Job conversion path, and none is planned:
"supersede" here means a Job can express what a Report expressed, not that an existing Report document
migrates itself. Report's own retirement stays J4's.

## 10. Naming and packages

Avoid `Resource*`. The word is taken twice in this codebase already — notation resources
(`NotationResourceCommands`, the binary assets in a project) and run resources
(`openResource`/`releaseResource`, now largely superseded by Contexts) — and this is neither.

`Data*` aligns with what already exists (`DataLocation`, `DataLocationInfo`, `DataFramer`,
`DataInputEvent`, `DataEncodingSpec`, `DatasetInfo`) and reads correctly for a DB or API source later.
Collision check: `DataRef`, `DataPart`, `DataUnit`, `DataManifest`, `DataRole`, `DataQuery`,
`DataSource`, `DataSourceId`, `DataOpener`, `DataCursor`, `DataContext`, `DataShape`,
`DataResolveResult`, `DataDiagnostic`, `DataOpenerLookup`, `FileDataOpener`, `DataSourceActions`,
`ReadWorker`, `ReadPartWorker` are all free.

Two names need a KDoc disambiguation:

- `DataSource` is close to Report's existing `FlatDataSource` — that one is the *byte-stream* seam and
  stays. Each KDoc must say which is which (CC-21 reciprocal markers).
- `DataContext` is close to kzen's *Context* vocabulary (`ContextBinder`, the run's Context registry):
  its KDoc must say it is the per-call environment a source runs in — which is how a source *reaches* a
  Context — not a Context itself.

**"Format" means two things**, and both are legitimate: `DataPart.format` (a `CommonPluginCoordinate` —
how to parse) is consistent with Report's shipped UI label and with `InputDataSpec`; the `DataFormat`
*document* (field → `TypeMetadata`) is the outlier and should be renamed `DataSchema` or deleted (§6.3,
O18).

**Package layering — Job must stop reaching into Report.** `HeaderListing` lives in
`common/objects/document/report/listing/`, and putting a flavour-neutral data model in a package that
imports it just deepens the inversion. ⚠ The `data` *package* is also already taken:
`tech.kzen.auto.server.objects.data` is `DataFormatDocument`'s, `tech.kzen.auto.common.objects.document.data`
is its spec package, and `data-js.yaml` exists. Scope the fix rather than boiling it — Job's server
packages currently import ~25 distinct Report types, so full decoupling is its own project. Move:

- (a) the **schema vocabulary** — `HeaderListing` / `HeaderLabel` / `HeaderLabelMap` — to
  `common/data/schema/`, as a mechanical import-only change **before** the model types are written, or
  they cement the wrong import;
- (b) the **input plumbing** — `FlatDataSource` / `FileFlatDataSource` / `FlatDataStream` /
  `FlatDataLocation`, `ReportInputChain`, `ReportHeaderReader`, `FileListingAction`,
  `ColumnListingAction`, `ReportDefinitionRepository` — to `server/data/…`, with Report consuming them
  from the new home. That also puts `FlatDataSource` and `DataSource` in one package, where the CC-21
  pair reads naturally.

Leave the expression engine (`CalculatedColumnEval` / `ColumnValue`) and everything pivot / export /
filter alone — J-arc business. `util/data/` (`DataLocation`, `DataLocationInfo`, `FilePath`) stays put —
it is location arithmetic used by everything including Report.

The new code's home follows from that move: `common/data/` is the data domain's root —
`data/schema/` (the vocabulary above + `DataShape`), `data/model/` (the §3.2 types), `data/api/`
(`DataSource` / `DataOpener` / `DataCursor` / `DataContext`), `data/file/` (the file-selection spec) — and
the server side mirrors it at `server/data/` (plumbing, `FileDataOpener`, `DataOpenerLookup`, the schema
cache) and `server/objects/datasource/` (the source objects + `DataSourceActions`), with
`notation/auto-common/common-data-source.yaml` and `notation/auto-jvm/datasource/data-source-jvm.yaml`.
**Not `paradigm/data/`**: `paradigm/` holds `{detached, flow, job, logic}`, i.e. *execution paradigms*,
and a value model is not one.

## 11. Decisions register

Settled entries are here because a plan cites them or because someone will otherwise re-open them; the
argument lives in the section named.

| # | Decision | Current answer |
|---|---|---|
| O1 | 1:N in-memory expansion — new archetype or a knob on `FormulaWorker` (§5.4) | Separate `ExpandWorker` archetype, **demand-driven** — nothing in this design needs it |
| O2 | `ResultSinkWorker keep: all` (§7.1) | Yes, as a separate small change; do not entangle it with the model |
| O3 | May a source / opener call run at *definition* time (the payload-type walk)? (§4.1, §6.1) | **No IO at definition time, ever.** The walk reads `staticShape(role)` and the schema cache only |
| O4 | Is a plain ref (`source == null`) first-class or a convenience? (§3.3) | First-class — it is the trivial case, it keeps `DataLocation` interop free, and it is **every ref in v1** |
| O5 | Do units nest? (§3.4) | No. Flatten at resolve time; nesting re-imports every problem §3.4 rejects |
| O6 | Widen the static stream dispatch beyond `Iterable` (§5.5) | Yes — one `isStreamType` covering `Iterable \| Sequence \| Iterator`; `FormulaSourceWorker` gains independently |
| O10 | Can a source nest **inline** under `ReadWorker.source`? (§5.2) | A refinement, not a requirement — the trivial case is three cards either way. Revisit only on evidence that the section split hurts |
| O11 | `emit: items \| units` knob vs a `Resolve` + `Read` split (§5.2) | The knob — a source worker has no incoming lane, so there is no ordering or migration-state objection |
| O12 | Design-time resource lifetime for stateful sources (§4) | **Open, and deferred.** Run time is solved by Contexts (borrow, never own). v1 design time is request-scoped open/close inside `DesignDataContext`; the explicit `DesignSession` later — no source changes either way |
| O13 | Argument passing into `resolve` and hosted Logic — positional or named (§4, §4.4, §7.1) | **Named.** Sources use `DataContext.argument(name)`; `RunWorker.arguments` evaluates expressions into named child parameters beside the positional input; `LogicDataSource` reuses the named `host(instructions, arguments: TupleValue)` overload |
| O14 | Is a **nullable structural reference** usable for `ReadWorker.source`? (§5.2) | **Open — spike it first.** Evidence says yes, but there is no shipped precedent, and a deleted target prunes the holder from `transitiveSuccessful` rather than warning. Test blank / set / cross-document / **deleted**; fallback is `by: Nominal` + a resolver |
| O15 | Durable identity for `DataRef.source` (§3.3) | A minted `DataSourceId` on the source's notation — **when a provider-bound source needs one**. The type lands in DS1; minting, the scan and duplicate validation land with the first JDBC-style source |
| O16 | Is the last session a Kotlin `DatedPathDataSource` or `LogicDataSource` + an example Script? (§4.4) | `LogicDataSource` — it proves the extension point instead of adding a ninth Kotlin class. Kotlin source in reserve if date iteration in a Script proves clumsy |
| O17 | Does the `ObjectRegistry` document survive the §5.5 visibility fix? | **No.** No real predicate false negative exists to test; retire the document and its scan/threading with the visibility fix rather than keep an untestable hatch |
| O18 | `DataFormat` document — rename to `DataSchema`, or delete? (§6.3, §10) | **Open — user-facing.** Rename and consume it as the declared-schema supply is the recommendation; deleting is acceptable; leaving it orphaned under a colliding name is not |
| O19 | When and how does heterogeneous-schema **superset normalization** land? (§5.3, §9) | With the design-time schema work, since it needs the pre-scan. `schemaMode: strict \| superset` names the semantic contract; default `superset`, while `strict` deliberately rejects schema drift |
| O20 | `DataCursor` — suspend per item, or a plain pull reader the worker drives? (§4) | **Plain pull reader.** Matches `CsvRecordReader`, keeps the handle context-free across a migrate, keeps third-party cursors trivial. Batching several `next()` per offload is a worker-side optimization if a profile asks |
| O21 | When does the `DataSources` document land? (§6.5) | **After the arc**, when a project has sources belonging to no Job. Discovery is graph-wide from DS2, so the follow-up is additive; pickers must be graph-wide now |
| O22 | Unit attributes onto the item lane — reader knob or downstream expression? (§3.5, §5.6) | **Reader knob `attributes: ignore \| columns`** — the reader is the only thing still holding the unit when the item is emitted |
| O23 | How may a 1:N transform checkpoint inside one input element? (§5.4) | Through an `ExpandingTransformWorker` that owns and migrates the active input batch and element position; never by adding a mid-element cadence to the 1:1 `TransformWorker` |

## 12. Build order

Sequenced so each step is independently useful and nothing is built before its consumer exists. The
elaborations in `docs/plans/next/DS*` are the execution layer and follow this.

0. **Data-layer package moves** (mechanical). Move `HeaderListing` / `HeaderLabel` / `HeaderLabelMap`
   out of Report's document package and move the input plumbing listed in §10 to `server/data/`.
   Package/import-only, no behaviour, and it must come **first**; the `FileListingAction.scanInfoBlocking`
   extraction remains in DS2 because that is a behavioural seam for its first consumer.
1. **Model + lowering.** The §3.2 value types in kzen-auto-common — `DataRef.source` a nullable
   `DataSourceId` that nothing mints yet (§3.3), attribute order presentation-only with a canonical digest
   (§3.5), reserved fingerprint keys (§6.2), `DataShape`, `DataResolveResult` — with `ExecutionValue`
   round-trips, wire form and digests, plus `DataLocation` ⇄ `DataRef` conversion and the construction
   helpers §4.4 needs. No worker depends on it yet; the tests are the exercise.
1b. **Inference visibility fix + registry retirement** (medium). Replace `visibleBuiltins` with the
   public-and-nameable predicate, retire `ObjectRegistry` / `ObjectRegistryScan` and their threading, and replace
   `isIterable` with `isStreamType` (§5.5). A standing bug
   independent of this arc — the hardcoded `IntRange` is the tell — and the prerequisite for a unit lane
   to type as `DataUnit`.
2. **The suspend runtime: `DataSource` + `DataOpener` + `DataCursor` + `DataContext`, `FileDataSource`
   (resolve only) + the shared `FileDataOpener` + `DataOpenerLookup`**, and the generic `DataSourceActions`
   detached object for design-time resolve (§4). Wire to the existing `FileListingAction` (splitting out a
   blocking core) and `FlatDataSource` / `ReportDefiner` rather than reimplementing either; the Job
   `sources:` branch + graph-wide discovery by capability. **Spike O14 first — including delete.** No
   `DataSourceId` minting, no resolver, no `DataSources` document.
3. **`ReadWorker`** (§5.2) — source-generic, `source:` a nullable structural reference,
   `emit: items | units`, `role`, `attributes: ignore | columns` (the `groupBy` parity path),
   resolved manifest carried across migration with the open cursor detached, per-item `runBlockingIo`
   drive, `payloadFlow` from `staticShape`, heterogeneous schemas failing loudly (§5.3). A/B against
   `CsvReaderWorker` / `MultiFileReaderWorker` over the same files — identical message streams; the old
   readers stay until that is green. **This plus step 4 is the trivial case: three cards, no code.**
4. **The editing surface** (§6.4): `MultiFileInputEditor` rewritten as `FileDataSource`'s attribute
   editor (typed selection, `editor:`-bound); generic source-card chrome (resolve preview + diagnostics)
   over `DataSourceActions`; the Job `sources:` section; the graph-wide source picker with auto-bind and
   the in-card source summary (§5.2). `editor:` keys land with their registrations (§6.4). Steps 3 and 4
   are one deliverable in two sessions — neither is demonstrable alone.
5. **`ReadPartWorker` + migration-safe 1:N execution** (§5.4) — the second reader, sharing step 3's
   drain core; an `ExpandingTransformWorker` that carries its active input batch across migration;
   ordered `partsOf(role)` reading; handle ownership. This is what the child-Logic idiom (§5.6b) and
   role fan-out (§5.6a) read with.
6. **Design-time shape** (§6.1–6.2): `DataSourceActions action=shape` tries the source's static
   declaration before bounded `inspectShape` on the file opener; the schema cache is a service keyed on the stamped fingerprint (fixing
   `ColumnListingAction`'s stale-key bug for Report too), the declared-schema supply for `staticShape`
   (§6.3, O18), `schemaMode: strict | superset` normalization (O19), editor dropdowns; `ReadWorker`'s `payloadFlow` reads the
   cache for explicitly-named parts.
7. **The writer yielding its ref + generic hosted-argument/path binding** (§7) — a plain path,
   finalized before it is fingerprinted and yielded; `RunWorker.arguments` expressions + the named `JobControl.host`
   overload; one shared path-substitution helper; `ResultSinkWorker keep: all`; the resolved manifest
   published to the trace. Same-run composition only.
8. **`LogicDataSource` + `DataContext.host` + the dated example** (§4.4) — the first parameterized
   source, the one the ETL port needs, the proof that a user can author a source, and the arc's acceptance
   fixture (the §7.1 worked shape end to end). The first *stateful* source after it is what exercises the
   Context borrow (§4) and O12.

Later, demand-driven: the `DataSources` document + controller (O21); `ExpandWorker` (O1); `LookupWorker`
(§5.7); `DataSourceId` minting / scan / validation with the first provider-bound source (O15). Steps 0–4
are the "capture the idea of a data source, generally and ergonomically" ask, with 5–6 completing
composition and the design-time surface; 7–8 are the ETL port. Third-party sources and their UI ride on
the general extension mechanism in
[`2026-08-21_extension-points.md`](2026-08-21_extension-points.md), not on anything in this list.

## 13. As-built

*(Sessions append here as each lands — deviations, surprises, and anything a later reader could not
recover from the code.)*
