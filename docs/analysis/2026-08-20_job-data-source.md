# Job data sources — describing, resolving and reading data

> **Status: landed — see §13.** This document is the one home for the rationale and as-built record behind
> Job data sources. The execution arc was master-plan ledger rows 49–58; its `docs/plans/next/DS0`–`DS8`
> elaborations were deleted as they landed, with the permanent outcomes appended to **§13** here. The Job
> flavour's other live plan is [`../plans/2026-07-25_job-improvements.md`](../plans/2026-07-25_job-improvements.md)
> (phases J3/J4 are the Report-subsumption spine this feeds). Per CC-20 no line numbers are cited;
> anchors are class / file names. Open questions are collected in **§11**; everything not listed there is
> settled, and the reason it is settled is stated where the decision lives.
>
> The independent 2026-08-23 design/plan review is incorporated here. Its twelve findings corrected the
> per-unit output path, substitution ownership, shape SPI, `DataContext` surface, schema policy name, package
> sequencing, expression registry, payload naming, migration-safe expansion, writer finalization, multi-part
> selection and child result name. Those reasons live in the sections that own the decisions rather than in a
> parallel review record.

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

## 2. The pre-arc shape

Before DS0–DS8, most of the needed behaviour existed — fused into `ReportDocument` and its spec classes rather
than factored. This baseline explains what the arc retained, generalized or replaced; §13 records the resulting
tree.

| Concern | Pre-arc home | Arc disposition |
|---|---|---|
| Browse a directory | `FileListingAction` (kzen-auto-jvm `…report/service/`), `/file-listing` route, `FileListingHandler` | Already flavour-neutral; keep |
| Selection config | `InputSpec` / `InputBrowserSpec` / `InputSelectionSpec` / `InputDataSpec` (kzen-auto-common) | Right split of location-vs-format; too narrow otherwise |
| Resolved dataset | `DatasetInfo` = `List<FlatDataInfo>`; `FlatDataInfo` = location+encoding, `HeaderListing`, plugin coordinate, group | **This is the abstraction to generalize** |
| Grouping | `GroupPattern` (filename regex) → `DataLocationGroup(String?)` | Concept right, shape too narrow (one nullable string) |
| Schema pre-scan | `ColumnListingAction` + `ReportHeaderReader`, cached as `columns.csv` | Keep; cache key needs work (§6.2) |
| Byte source | `FlatDataSource` / `FlatDataStream` / `FileFlatDataSource` | Already a clean seam; keep as-is |
| Format plugins | `ReportDefiner` / `ReportDefinition` / `ReportDataDefinition` / `DataFramer` (kzen-auto-plugin), driven by `ReportInputChain` | Keep; this is the "how to parse" axis |
| Job readers | `CsvReaderWorker`, `MultiFileReaderWorker`, `MultiFileInputEditor` | Replace with the source-generic `ReadWorker` (§5.2) + `FileDataSource`'s attribute editor (§6.4) |
| Expression type inference | `ExpressionReturnTypeInference` (`visibleBuiltins` + `ObjectRegistryScan`) | **Carried a bug DS1b corrected** — see §5.5 |
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

### 2.2 Three gaps, and why the pre-arc Job worker was unsatisfying

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
regex → group column did and what J4's grouped export consumes. **`groupBy` input parity landed with
DS3** (§9).

## 4. `DataSource` is an object with a callable API, not a Worker

```kotlin
/** RESOLVE — the variable part. Every source has one. */
interface DataSource {
    /** Resolve the configured query into a point-in-time manifest (§8.1) plus diagnostics. */
    suspend fun resolve(context: DataContext): DataResolveResult

    /** The shape of what `role` yields, answerable from NOTATION ALONE — never IO; the walk reads this (O3). */
    fun staticShape(role: DataRole?): DataShape? = null

    /** Weak definition references whose content affects the manifest and live-run migration. */
    fun definitionDependencies(): List<ObjectLocation> = emptyList()
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

    /** Host authored source logic; the default rejects design-time use because no run is active. */
    suspend fun host(instructions: ObjectLocation, arguments: TupleValue): TupleValue {
        throw UnsupportedOperationException("Hosting data-source logic requires an active run")
    }

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

`DataContext` contains the three capabilities used by the landed sources: named run arguments, authored-Logic
hosting and counted blocking. Runtime `host(instructions, arguments)` delegates to the named `JobControl.host`
overload shared with `RunWorker.arguments`; the default rejects design-time hosting because no active run exists.
A Context-registry read remains deferred to the first stateful source, together with the `JobControl` accessor it
requires. Sources consume this interface; they do not implement it, so that capability can land with its first
consumer without creating a third-party implementation burden.

`definitionDependencies()` names weak definition references whose content affects resolution but is not already
in the source's structural closure. `LogicDataSource` returns its hosted instructions so an edit changes the
reader's migration-compatibility digest; sources with no extra definition dependency retain the empty default.

**Why `resolve` and `open` are `suspend`, and why a cursor is not.** `JobControl.runBlockingIo` and
`JobControl.host` are both **`suspend`** (`EngineJobControl` delegates to `Execution.blocking` / the
child-logic host), so a non-suspend SPI call has no legal way to reach either — the only escapes are
`runBlocking` (holds an engine thread, defeats the offload) or wrapping the whole call in one
`runBlockingIo` from outside (then `blocking` is identity and `host` is unreachable, which kills
`LogicDataSource`). So `resolve` is suspend, and the *source* calls `context.blocking { … }` around its
own blocking parts (the directory walk, a JDBC round-trip) and `context.host(…)` when it is a Logic. That
is exactly how `RunWorker` already uses suspend `host`, and `DetachedAction.execute` is suspend, so design
time needs nothing new. DS2 split `FileListingAction.scanInfo` into a blocking core so the source calls it
through `context.blocking`, rather than selecting `Dispatchers.IO` underneath the run's counted boundary.

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

1. **Design time** — detached tooling may ask "what does this query resolve to?" or "what columns?" with no
   run in sight (the Report precedent is `FileListingAction` / `ColumnListingAction`). **One generic action** —
   `DataSourceActions` — instantiates a named source through `GraphInstanceCache`, builds a
   `DesignDataContext`, and dispatches the named `resolve` / `shape` operations. Its third operation,
   `fileFormats`, describes the server's installed file formats and encodings without instantiating a source.
   The corrected inline File/Logic Worker UI does not currently expose Resolve/Columns controls; §6.1 records
   that reachability boundary. A detached `LogicDataSource.resolve` also fails explicitly because authored
   source logic requires an active run.
2. **Run time** — from the **two readers** (`ReadWorker` resolves and reads a source; `ReadPartWorker`
   opens one part of a unit already on a lane — §5.2, §5.4), which own the context, the handle, the
   cursor, cancellation, and quiescence accounting. **Never from an expression**: source resolution and
   reading are effects, and an expression that performed them would hide I/O, cancellation and resource
   ownership inside generated code, with nothing to own the file handle or carry a position across a
   migrate. Expressions see *materialized* values — a `DataUnit` on a lane, a record — and nothing else.

Note what (2) means: there are exactly two data-specific **read operations**, no data-specific port, and no
data-specific lane type. `ReadWorker` resolves a referenced source; `ReadPartWorker` reads an incoming unit.
`FileSourceWorker` and `LogicSourceWorker` are thin, channel-free source delegates over the same `ReadWorker`
engine so the ordinary stage UI stays ergonomic; they add no third read path. The source supplies
*configuration* (which directory, which pattern, which connection), *resolution* and *declaration*; the opener
supplies *read*; the reader engine supplies the wiring onto ordinary lanes.

Being a notation object is the customization seam and is worth the object-ness: a third-party source is
another archetype in the graph, discovered through graph notation and classified **by capability,
never by class name** (CC-17) — the `JobServeCapability` / `JobSignatureCapability` pattern. It also gives
the editor something to bind a browse/preview UI to, which a bare function would not.

Two consequences of "design time" being on the list, both general rather than data-specific:

- **The source object is NOT a `DetachedAction`; one generic action calls it.** Detached callers go through
  `ModelDetachedExecutor.execute(actionsLocation, request)` on `DataSourceActions`, which instantiates a named
  source by location (`GraphInstanceCache`, following the `FileListingAction` / `ColumnListingAction` precedent)
  and calls `resolve`, or answers shape with
  `source.staticShape(part.role) ?: opener.inspectShape(context, part)`. The `resolve`, `shape` and
  source-independent `fileFormats` action names are constants; unknown names fail clearly. This keeps the
  protocol generic even though the corrected inline Worker cards presently expose only the file-format catalogue,
  not Resolve/Columns chrome (§6.1).
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
**O3 says never**: the walk reads `DataSource.staticShape(role)` from the compiled notation snapshot
and nothing else. In particular it does not resolve a source, inspect an opener, or read the schema
cache from memory or disk.

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

There is one read engine and no I/O in expressions. `ReadWorker` reads a referenced source;
`FileSourceWorker` and `LogicSourceWorker` own the corresponding source configuration on an ordinary Worker
card while delegating to that same engine; `ReadPartWorker` reads any part of a unit already on a lane.

### 5.1 Two different operations are both called "splitting"

They are unrelated, the design needs both, and conflating them costs a redesign later:

- **Element split (expand)** — ONE element becomes MANY on the SAME lane. A `DataUnit` becomes its
  rows. This is a worker concern, but not safely an ordinary `TransformWorker.onElement`: that base removes a
  physical input batch from the channel before invoking the hook, so a mid-expansion migration would strand
  local elements. DS5 added `ExpandingTransformWorker` to own and migrate that batch and position (§5.4).
- **Channel split (fan-out)** — ONE lane feeds SEVERAL lanes. Not expressible today:
  `ChannelTypeDefiner` enforces single-reader, and J6 (`TeeWorker` + list-typed ports) is the planned
  relief.

**Terminology, fixed here:** *Split* means the element operation; *fan-out* / *Tee* means the channel
one (J6 already uses `TeeWorker`). §5.6(a) is the only place fan-out appears.

### 5.2 The declarative readers — one engine, ordinary Workers

The trivial case decides this. Starting from a blank Job, "count the lines of one file" must be:
insert **File**, pick the file in that Worker, insert **Summary**, run — **two cards, no code**:

```
ReadWorker(source: <DataSource>, emit: items | units, role: <DataRole>?, attributes: ignore | columns)
    -> item lane or unit lane

FileSourceWorker(<file config>, emit: items | units, role: <DataRole>?, attributes: ignore | columns)
LogicSourceWorker(<logic config>, emit: items | units, role: <DataRole>?, attributes: ignore | columns)
```

`FileSourceWorker` and `LogicSourceWorker` are not composite insertion shortcuts: each is one persisted
Worker, one stage identity and one card. Their channel-free `DataSource` delegates keep source resolution
shared with nominal `ReadWorker`; `InlineDataSourceWorker` supplies the delegate to the common reader engine.
Pure DataSource objects remain useful for cross-document sharing, where `ReadWorker` keeps its nominal
reference, graph-wide picker and exactly-one same-document auto-bind.

- **`source`** is a nullable **nominal `ObjectReference`** to a `DataSource`, preserved verbatim by a
  narrow creator rather than resolved during worker construction. O14 disproved the intended structural
  form: nullable-aware definition/creation accepts blank, but `GraphDefinition.filterTransitive` blindly
  locates the empty reference and throws before creation. The nominal value keeps blank, valid,
  cross-document and dangling states representable so the Read card itself can report them. **O14.**
- **Where the instance comes from.** A run-scoped definition context resolves the nominal reference
  against the exact full compiled snapshot. It reuses the source instance already present in the Job run
  graph; for a cross-document source outside that filtered graph, one run-local `GraphInstanceCache`
  instantiates it from the same snapshot and shares it among readers. Design time continues through the
  generic `DataSourceActions` cache. Neither path queries the mutable current graph store mid-run.
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
  `Tabular` → `flatColumns`, `Payload` → `payloadType`). Undeclared sources remain unknown even when a
  previous click or run populated `SchemaCache`; the validation walk never reads runtime cache state.
  Under `units`, `payloadType = DataUnit`. Nothing is resolved at walk time, so no call may take a
  `DataPart`.
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

`ReadWorker` replaces `CsvReaderWorker` and `MultiFileReaderWorker`; `FileSelectionEditor` edits the same
file configuration on both `FileDataSource` and `FileSourceWorker` (§6.4). The worked trivial case:

1. Palette → **Sources → File**, then choose an ordinary stage insertion gap. The resulting Worker card uses
   the standard attribute-editor path; its file browser edits directory, filter, ordered selections and
   per-file format/encoding.
2. Palette → **Summary**; auto-wired by adjacency (`JobChannelDerivation`). Run. Summary's live row
   count is the line count (less the header if `header` is on).

Scaling without changing the engine: the same `Read` card with `source:` pointing at a `sales` source in
another Job's `sources:` branch (discovery is graph-wide by capability, §6.5); or `Read` with
`emit: units` feeding `RunWorker` over a per-unit child Job (§5.6b); or a `LogicDataSource` whose
resolution is a Script over run parameters (§4.4) — read by the very same `Read` card. Same objects,
same lane.

### 5.3 Why DS3 first failed on heterogeneous schemas, and how DS6 normalizes them

Report merges heterogeneous headers: `DatasetInfo.headerSuperset()` unions the columns across files, and every
record is read against the superset with a missing column rendering `<missing>` (the `RecordHeaderIndex` /
`CalculatedColumnEval.columnValue` path). DS3 intentionally shipped an intermediate hard failure; DS6 then
restored that parity through the default `schemaMode: superset` policy.

The DS3 failure was the right safe boundary until normalization existed, and the reason was not the reader. At
the reader, per-unit headers are almost free: `JobMessage.ofFlat` already carries a header per message and
`RecordHeaderIndex.indices` caches by equality and recomputes when the header changes. The cost is **downstream
and silent**:

- `SummaryWorker.ensureInitialized` fixes its column set from the **first** record's header and maps
  later records on by name — a column that first appears in unit 2 is **silently dropped**.
- `CsvWriterWorker` writes the header from the first batch and then writes each record's fields — a
  wider later record produces **ragged rows** under a header that does not describe them.

So emitting mixed headers without normalization converts a loud failure into silent data loss. DS6 implemented
Report's safe answer: inspect the relevant parts, resolve the **superset** up front, and project every item to it
— **O19**.

DS6 exposes the policy as `schemaMode: strict | superset`, default `superset`. This is not merely a
pre-scan cost switch: `strict` is an explicit data contract that rejects an unexpected added or removed
column, while `superset` accepts schema variation without losing later columns. The name describes the
semantic choice; its bounded-read cost is a documented consequence of `superset`, not the meaning of the
attribute.

### 5.4 Migration-safe 1:N transforms, and `ReadPartWorker`

`FormulaWorker.payload` **replaces** the payload: one message in, one message out. Calling `emit.send` several
times from an ordinary `TransformWorker.onElement` is insufficient because the worker cannot safely checkpoint
the input batch held on its coroutine stack. The landed 1:N contract therefore has a distinct execution base,
`ExpandingTransformWorker`, which owns the active batch and element index as migratable state.

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

### 5.5 The payload-inference bug DS1b corrected

The pre-DS1b implementation did not preserve `DataUnit` as the type of a unit lane.

`ExpressionReturnTypeInference.toTypeMetadata` approximated any classifier outside a hardcoded
`visibleBuiltins` set and the `ObjectRegistry` document's declared class list down to `Any` (nullability
preserved). The registry held only `kotlin.ranges.IntRange`, while `visibleBuiltins` held eleven entries. A
`ReadWorker(emit: units)` would therefore have published **`Any`**, preventing `ReadPartWorker.payloadFlow` from
validating its input and hiding `.attributes` from a downstream `FormulaWorker`.

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

The same class carried a second, related limit: `isIterable` tested `isSubclassOf(Iterable::class)`, and
`kotlin.sequences.Sequence` does not implement it. DS1b replaced that classifier with **`isStreamType`** over
`Iterable | Sequence | Iterator`, with `streamElementType` projecting onto the matching supertype. The correction
is general and applies equally to `FormulaSourceWorker` — **O6**.

Two follow-ons worth stating rather than discovering:

- `ObjectRegistryScan` lost its only consumer — `ExpressionReturnTypeInference` was the sole reader;
  `WorkerLaneContext` and `ScriptDefinitionContext` merely carried it. No real public, importable class rejected
  by the predicate could be produced, and a stubbed predicate would not prove one exists. DS1b therefore retired
  the `ObjectRegistry` document and its scan/threading instead of preserving an untestable widening hatch —
  **O17**.
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
  (a header row, `LIMIT 0`), or null when the opener cannot answer cheaply. Detached inspection reaches it
  through the generic `DataSourceActions` (`action=shape`, §4).

The walk cannot call `inspectShape` for the same reason it cannot resolve: no part exists at walk time.
A **schema cache** keyed on the part's fingerprint (§6.2) is a separate runtime service used by bounded
inspection and Report. It is not a member of the SPI and is not a validation-walk input; explicit
inspection results live in client state keyed by source and manifest digest.

The bounded-inspection path is implemented end to end: `DataSourceActions`, `DataSourceResolveStore`,
`DataSourceShapeStore` and `JobUpstreamSchema` can carry an explicitly inspected source shape to editor
dropdowns. The corrected DS4 interaction removed the detached source card, however, and the inline File/Logic
Worker cards deliberately expose no Resolve/Columns trigger. No production UI currently calls the resolve or
inspect stores, so this provider is dormant rather than a reachable pre-run feature. Restoring it requires a
channel-free description surface for inline Workers; it must not instantiate a Worker through
`DataSourceActions`.

The active paths are narrower: a declared schema feeds server validation through `staticShape`, while a live
`SummaryServer` supplies downstream editor suggestions after a run. `JobUpstreamSchema` retains this provider
precedence for when the explicit-inspection surface becomes reachable:

1. live summary (a running `SummaryServer` upstream) — most accurate, run-scoped;
2. offline persisted transformed-lane summary (reserved J4 slot) — last run's actual columns;
3. **explicit on-demand source inspection** — implemented but currently without production UI chrome; when
   invoked, it is bounded (§6.2) and projected through the Read lane's role, attributes and schema policy;
4. free text.

A declared schema feeds the server validation lane directly through `staticShape`; the client provider list does
not duplicate that declaration into a second cache.

Columns are the *whole* design-time data surface: there is no row preview, deliberately (§9).

**The payload-type walk** gets `source.staticShape(role)` and nothing else — never I/O. `ReadWorker`
already holds its source and asks it directly. `ReadPartWorker` has no source in hand, so it stays
statically unknown. So:

| Lane | Static scope for downstream expressions |
|---|---|
| declared `Payload(type)` | the item type as receiver, members bare — full compile-time validation through DS1b's public-and-nameable inference (§5.5) |
| declared `Tabular(header)` | `flatColumns` known; expressions validate against the header |
| nothing declared (including a directory-walk file source) | statically unknown; `KotlinSyntaxValidator` syntax-only. A Resolve + Columns click may offer editor choices client-side, but does not change validation |
| `emit: units` | `payloadType = DataUnit` (needs §5.5) |

Unknown must remain legal at every step; it already is, and this design does not make any lane *less*
known than it is today. It simply declines to promise the walk something it cannot deliver without
doing IO at define time.

### 6.2 Caching, and a bug to fix on the way

Before DS6, `ColumnListingAction` cached an extracted `HeaderListing` as `columns.csv` under a path keyed on
`(dataLocation, pluginCoordinate)`, with no size or modification time. An edited file could therefore serve stale
columns until the cache was cleared. DS6 replaced that identity with the shared `SchemaCache` key
`(ref.id, format, encoding, size, modified)`; refs without a complete fingerprint are inspected but not cached.

**Where size/mtime come from:** the resolver **stamps them into the ref at resolve time** —
`DataRef.attributes[size]` / `[modified]`, reserved text-canonical keys — because
`FileListingAction.toFileInfo` already has them from `BasicFileAttributes` and the manifest is the
natural carrier. That one choice gives the cache key *and* a reproducible manifest: a manifest whose refs
carry a fingerprint records what was read, and a changed file changes the digest. A content digest is
deliberately **not** stamped (a full read).

Cost discipline matters because detached tooling may inspect repeatedly: `inspectShape` is a bounded read (a
header row, a `LIMIT 0` query), never a full scan. `ReportHeaderReader` already stops at the header. The runtime
inspection path may use `SchemaCache`; the validation walk never reads the cache, resolves a source, or calls an
opener.

### 6.3 Column types remain excluded; `DataSchema` is the landing site

Real ETL wants typed columns. But `HeaderListing`, `FlatFileRecord`, `ColumnValue` and
`WorkerLane.flatColumns` are text-canonical end to end, with conversion at expression time. Typing
that is its own arc with a wide blast radius, and doing it inside this change would double the risk
of both. `DataShape.Tabular(HeaderListing)` widens to a typed schema later without any change to the
model in §3.

The pre-arc tree shipped an orphaned `DataFormat` document archetype: field name → **`TypeMetadata`**, exactly
the typed-column declaration needed here, but with a name that collided with Report's parse-format vocabulary.
DS6 renamed it end to end to `DataSchema` and made it the nullable strong structural declaration on
`FileDataSource`.

That decision matters three ways:

1. **It supplies `staticShape(role)` (§6.1).** A source answers from the compiled declaration with no I/O, so
   O3 holds by construction even when reading the source would be expensive.
2. **`format` keeps one meaning.** Report's UI and `InputDataSpec` use Format for the parse coordinate, so
   `DataPart.format` remains consistent. `DataSchema` describes fields and types instead of competing for that
   name — **O18**.
3. **Typed columns are still a separate arc.** DS6 projects only the schema's ordered labels into
   `DataShape.Tabular(HeaderListing)`; it retains each field's `TypeMetadata` without claiming a typed-column
   wire or lane model.

### 6.4 Where the file-selector UI lives — on ordinary attribute metadata

The browser is the `files` attribute editor shared by `FileDataSource` and `FileSourceWorker`.
`AttributeWrapperLookup`
reads an attribute's `editor:` metadata key, which names a wrapper object; `AttributeEditorManager`
resolves that name against its autowired `List<AttributeEditor>` and falls back to
`DefaultAttributeEditor`. That string contract is documented in the codebase as *the* open-set
extension seam, and `MultiFileInputEditor` is already bound through it — so the implementation
largely exists. What changes is *what it edits*: the ordered picked files and their nullable per-file format /
encoding overrides instead of a worker's raw `List<String>` (§2.2). The chooser's navigation state is separate
(`browser.directory` / `browser.filter`) from the source's runtime directory-query fields, so removing the last
explicit file cannot accidentally turn the last visited directory into the Worker's input. A JDBC source brings
a SQL editor the same way. **The Job controller itself has no file-specific code**: `FileSourceWorker` names a
notation-contributed `FileSourceWorkerDisplay`, which composes the ordinary Worker card, promotes the metadata-
selected `files` editor, and places execution-only attributes behind an Advanced disclosure. Pure DataSource
objects keep the same editor metadata — `browser:` included — for any future source-object authoring surface: the
marker is declared once on `FileDataSourceConfig` and inherited, so no consumer can forget it and silently write a
runtime directory query while browsing. An attribute *without* the marker (legacy `MultiFileReaderWorker.paths`,
or a third-party attribute that has not opted in) keeps navigation in component state and persists only the
selection — the safe default.

The actual browser presentation is shared with Report rather than copied. `FileBrowser` owns the breadcrumb,
search, folder/file table, checked-range state and counted Add/Remove actions behind callbacks; Report and the Job
editor remain separate persistence/network adapters because their notation and format-default semantics differ.
The Job card renders that surface **inline and first**, on Report's own rule: an empty selection pins the browser
open, any selection puts it behind a **Browser** toggle, and the chosen files read below it as a
`FileSelectionTable` — the same bordered, sticky-header, click-to-check table the browser itself uses, with the
shared look factored into `FileTableStyles` so the two halves of one card cannot drift apart. Browsing sits above
the selection because it is what feeds it. Remove and reorder act on the rows checked in that table, matching the
browser's own check-then-act Add/Remove; ordering is the one thing Report's selection lacks, so position is a
column rather than an implicit fact about row order. The stage card widened to carry all of it
(`JobObjectSlot.cardMaxWidth`, shared with `JobController`'s insertion gaps so the channel pipe stays centred). A
launcher button opening a modal was tried first and rejected — a chooser one click away behind a dialog is
strictly worse than one already on the card, and Report had the answer already.
`FileListingAction.browseInfo` keeps immediate directories visible under an active filename filter, while
runtime `scanInfo` stays files-only.

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
  `workers:`) remains the notation home for a pure source referenced by `ReadWorker`; the normal Job UI does
  not render a separate source-object region.
- **`FileSourceWorker` / `LogicSourceWorker`** live under `main.workers` like every other ribbon-inserted
  Worker. They own their source configuration directly and are deliberately not DataSource capabilities.
- **`DataSourceConventions.allDataSources(graphNotation)`** — every object whose inheritance chain,
  **dropping self**, reaches `DataSource`. ⚠ The `drop(1)` is not cosmetic: `ContextConventions.isContext`
  does it so the abstract archetype does not match its own filter and offer itself in every picker.
  (`isChannelArchetype`'s bare `.any` is the shape *not* to copy.)

Discovery for pure sources is **graph-wide by capability**: a source in any Job's `sources:` branch is visible
to every picker. Inline source Workers are intentionally absent from that list; they are executable stage
objects, not shareable source declarations.

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

DS7 closed what had been the second gap: both built-in writers may yield a plain, fingerprinted `DataRef` as a
declared result after successful finalization. J4 owns widening that single-container contract to a `DataUnit`
when grouped export writes several containers. The caller therefore receives what was actually written instead
of reconstructing the writer's path pattern by hand.

Worked shape:

```
OuterJob(parameters: from: String, to: String)
  LogicSourceWorker(instructions: DatedSales,
                    arguments: [from, to], emit: units)         -> unit lane
      // `from` / `to` reach the Script through DataContext.argument(name) → named host arguments — §4.4
  RunWorker(instructions: PerDayJob,
            arguments: {date: 'attributes["date"]'})           -> result lane (one DataRef per day)
  ResultSinkWorker(result: outputs, keep: all)

PerDayJob(parameters: unit: DataUnit, date: String; results: main: DataRef)
  FormulaSourceWorker(code: "unit")                            -> ReadPartWorker(role: main)
                                                               -> FilterWorker / FormulaWorker …
                                                               -> ExportWriterWorker(
                                                                    path: "out/${date}.csv", result: main)
  FormulaSourceWorker(code: "unit")                            -> ReadPartWorker(role: reference)
                                                               -> independent transform / side effect
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

`ResultSinkWorker keep: all` collects the ordered per-unit refs as `List<elementBoundaryType>`, including an
empty list for an empty stream; its unbounded-memory cost is explicit. DS7 landed this as the separate O2 change
rather than entangling collection policy with the data model.

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

`ReadWorker` publishes each fresh resolved manifest once to the trace, with digest, unit count and ref
fingerprints; an adopted manifest is not logged again. A run therefore records what it actually read, providing
the ETL arc's observability and reproducibility story.

### 8.2 Cursors

`CsvReaderWorker` and `MultiFileReaderWorker` carry a real cursor — the detached open reader itself, whose
position is implicit in its buffer, plus `MultiFileReaderWorker`'s `fileIndex` — so the rebuilt instance resumes
at the exact record. Both data readers inherit that ownership model: the open `DataCursor` is the handle,
detached across a compatible migration and driven onward by the new instance's control (§4, §5.2, §5.4).
There is deliberately no generic serialized seek position for a stateful plugin framer; exact compatible resume
comes from adopting the live cursor, while incompatible edits follow the reader's documented restart or
reopen-and-skip policy.

## 9. Report parity map

| Report capability | This design |
|---|---|
| Browse directory + filter | `FileDataSource`'s attribute editor over the existing `/file-listing` route (§6.4). ⚠ `filter` is a contains-all-words match on the file name, **not** a glob |
| Selected file list | authored `FileSelectionSpec`, shown and reordered in the ordinary File Worker's attribute editor; the resolved manifest is recorded in the run trace |
| Per-file format (`InputDataSpec.processorDefinitionCoordinate`) | `DataPart.format`, defaulted by the source (`actionDefaultFormat` logic) |
| Data type filter (`InputSelectionSpec.dataType`) | source-level constraint on which formats it offers |
| `groupBy` filename regex → `DataLocationGroup` | source-level attribute extraction → `DataUnit.attributes` |
| Grouped export | `attributes: columns` on the reader (§3.5, §5.6): unit attributes become leading columns, which is what J4's `groupBy: <column>` consumes. The reader side landed in **DS3** |
| **Header superset across files** (`DatasetInfo.headerSuperset`) | `schemaMode: superset` (the default) pre-inspects selected parts, builds an ordered union and materializes absent cells as `<missing>`; `strict` retains exact-shape rejection (§5.3, O19) |
| Column listing (`ColumnListingAction`) | `FileDataOpener.inspectShape` provides bounded detached inspection and `staticShape` provides declarations; `ReadWorker.payloadFlow` uses declarations only. The corrected inline Worker UI has no inspection trigger (§6.1) |
| Encoding detection (`ReportUtils.encoding`) | `DataPart.encoding`, source-defaulted at resolve, opener-inferred when null |
| Multi-file as one stream | `ReadWorker` (§5.2) — one card, any source |
| Row-level data preview | ⚠ **deliberately absent.** The design-time contract stops at manifest resolution and bounded-or-declared columns; the corrected inline Worker UI currently exposes neither pre-run operation. "Read me ten rows" assumes rows are meaningful and cheap to obtain, which does not hold for a source backed by a full pipeline (§6.1–6.2) |
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
The pre-arc collision check found the selected names free; they are now the landed vocabulary: `DataRef`,
`DataPart`, `DataUnit`, `DataManifest`, `DataRole`, `DataSource`, `DataSourceId`, `DataOpener`, `DataCursor`,
`DataContext`, `DataShape`, `DataResolveResult`, `DataDiagnostic`, `DataOpenerLookup`, `FileDataOpener`,
`DataSourceActions`, `ReadWorker` and `ReadPartWorker`. `DataQuery` remains a concept rather than a fixed type
(§3.2).

Two names need a KDoc disambiguation:

- `DataSource` is close to Report's existing `FlatDataSource` — that one is the *byte-stream* seam and
  stays. Each KDoc must say which is which (CC-21 reciprocal markers).
- `DataContext` is close to kzen's *Context* vocabulary (`ContextBinder`, the run's Context registry):
  its KDoc must say it is the per-call environment a source runs in — which is how a source *reaches* a
  Context — not a Context itself.

**"Format" has one parse-side meaning.** `DataPart.format` (a `CommonPluginCoordinate` — how to parse) is
consistent with Report's shipped UI label and `InputDataSpec`. The field → `TypeMetadata` document is
`DataSchema`, resolving the former collision (§6.3, O18).

**Package layering — the data model does not belong to Report.** DS0 moved the flavour-neutral schema and input
plumbing before the new model landed, avoiding a new dependency on Report-owned packages while leaving broader
Job→Report decoupling to its own project:

- the **schema vocabulary** — `HeaderListing` / `HeaderLabel` / `HeaderLabelMap` — lives in
  `common/data/schema/`;
- the **input plumbing** — `FlatDataSource` / `FileFlatDataSource` / `FlatDataStream` /
  `FlatDataLocation`, `ReportInputChain`, `ReportHeaderReader`, `FileListingAction`,
  `ColumnListingAction`, `ReportDefinitionRepository` — lives under `server/data/`, with Report consuming it
  from the neutral home. The two concrete stream implementations remain in Report's input subtree, as §13
  records.

Leave the expression engine (`CalculatedColumnEval` / `ColumnValue`) and everything pivot / export /
filter alone — J-arc business. `util/data/` (`DataLocation`, `DataLocationInfo`, `FilePath`) stays put —
it is location arithmetic used by everything including Report.

The landed code's home follows from that move: `common/data/` is the data domain's root —
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
| O2 | `ResultSinkWorker keep: all` (§7.1) | **Resolved in DS7:** a separate collection-policy change, not part of the data model |
| O3 | May a source / opener call run at *definition* time (the payload-type walk)? (§4.1, §6.1) | **No IO at definition time, ever.** The walk reads only `staticShape(role)` from notation; no resolve, opener inspection, or schema-cache access |
| O4 | Is a plain ref (`source == null`) first-class or a convenience? (§3.3) | First-class — it is the trivial case, it keeps `DataLocation` interop free, and it is **every ref in v1** |
| O5 | Do units nest? (§3.4) | No. Flatten at resolve time; nesting re-imports every problem §3.4 rejects |
| O6 | Widen the static stream dispatch beyond `Iterable` (§5.5) | **Resolved in DS1b:** one `isStreamType` covering `Iterable \| Sequence \| Iterator`; `FormulaSourceWorker` gains independently |
| O10 | Can a source nest **inline** under `ReadWorker.source`? (§5.2) | **Resolved by the UI correction:** no hidden nested object and no separate section. File/Logic are each one true Worker that owns its source config and delegates to the shared reader engine; pure DataSource + nominal Read remains for sharing |
| O11 | `emit: items \| units` knob vs a `Resolve` + `Read` split (§5.2) | The knob — a source worker has no incoming lane, so there is no ordering or migration-state objection |
| O12 | Design-time resource lifetime for stateful sources (§4) | **Open, and deferred.** Run time is solved by Contexts (borrow, never own). DS8's `LogicDataSource` holds no connection and therefore does not exercise this seam; the first JDBC/API source decides whether request-scoped `DesignDataContext` is enough or an explicit `DesignSession` is needed |
| O13 | Argument passing into `resolve` and hosted Logic — positional or named (§4, §4.4, §7.1) | **Named.** Sources use `DataContext.argument(name)`; `RunWorker.arguments` evaluates expressions into named child parameters beside the positional input; `LogicDataSource` reuses the named `host(instructions, arguments: TupleValue)` overload |
| O14 | Is a **nullable structural reference** usable for `ReadWorker.source`? (§5.2) | **No.** Blank defines and can inject null, but `GraphDefinition.filterTransitive` throws `Missing <empty>` first. Use `by: Nominal` with a creator preserving `ObjectReference?` plus snapshot-scoped lookup/instantiation; set/cross-document works, while delete stays representable as a clear unresolved-reference validation |
| O15 | Durable identity for `DataRef.source` (§3.3) | A minted `DataSourceId` on the source's notation — **when a provider-bound source needs one**. The type lands in DS1; minting, the scan and duplicate validation land with the first JDBC-style source |
| O16 | Is the last session a Kotlin `DatedPathDataSource` or `LogicDataSource` + an example Script? (§4.4) | **Resolved in DS8:** `LogicDataSource` plus a one-step dated Script fixture compiled and ran end to end; no ninth Kotlin source class was needed |
| O17 | Does the `ObjectRegistry` document survive the §5.5 visibility fix? | **No.** No real predicate false negative exists to test; retire the document and its scan/threading with the visibility fix rather than keep an untestable hatch |
| O18 | `DataFormat` document — rename to `DataSchema`, or delete? (§6.3, §10) | **Resolved in DS6:** renamed to `DataSchema` and consumed as `FileDataSource`'s nullable strong structural declaration; its field `TypeMetadata` is retained |
| O19 | When and how does heterogeneous-schema **superset normalization** land? (§5.3, §9) | **Resolved in DS6:** `schemaMode: strict \| superset` on both readers, default `superset`; ordered projection materializes `<missing>`, while `strict` rejects drift |
| O20 | `DataCursor` — suspend per item, or a plain pull reader the worker drives? (§4) | **Plain pull reader.** Matches `CsvRecordReader`, keeps the handle context-free across a migrate, keeps third-party cursors trivial. Batching several `next()` per offload is a worker-side optimization if a profile asks |
| O21 | When does the `DataSources` document land? (§6.5) | **After the arc**, when a project has sources belonging to no Job. Discovery is graph-wide from DS2, so the follow-up is additive; pickers must be graph-wide now |
| O22 | Unit attributes onto the item lane — reader knob or downstream expression? (§3.5, §5.6) | **Reader knob `attributes: ignore \| columns`** — the reader is the only thing still holding the unit when the item is emitted |
| O23 | How may a 1:N transform checkpoint inside one input element? (§5.4) | Through an `ExpandingTransformWorker` that owns and migrates the active input batch and element position; never by adding a mid-element cadence to the 1:1 `TransformWorker` |

## 12. Landing order

DS0–DS8 landed in this order so each step was independently useful and nothing preceded its consumer. Their
temporary `docs/plans/next/DS*` elaborations were deleted on landing; §13 is the permanent as-built record.

0. ☑ **Data-layer package moves** (mechanical). Moved `HeaderListing` / `HeaderLabel` / `HeaderLabelMap`
   out of Report's document package and the input plumbing listed in §10 to `server/data/`. This package/import-
   only phase came **first**; the behavioural `FileListingAction.scanInfoBlocking` extraction stayed in DS2 with
   its first consumer.
1. ☑ **Model + lowering.** The §3.2 value types in kzen-auto-common — `DataRef.source` a nullable
   `DataSourceId` that nothing mints yet (§3.3), attribute order presentation-only with a canonical digest
   (§3.5), reserved fingerprint keys (§6.2), `DataShape`, `DataResolveResult` — with `ExecutionValue`
   round-trips, wire form and digests, plus `DataLocation` ⇄ `DataRef` conversion and the construction
   helpers §4.4 needs. No worker depends on it yet; the tests are the exercise.
1b. ☑ **Inference visibility fix + registry retirement** (medium). Replaced `visibleBuiltins` with the
   public-and-nameable predicate, retired `ObjectRegistry` / `ObjectRegistryScan` and their threading, and
   replaced `isIterable` with `isStreamType` (§5.5). This was a standing bug
   independent of this arc — the hardcoded `IntRange` is the tell — and the prerequisite for a unit lane
   to type as `DataUnit`.
2. ☑ **The suspend runtime: `DataSource` + `DataOpener` + `DataCursor` + `DataContext`, `FileDataSource`
   (resolve only) + the shared `FileDataOpener` + `DataOpenerLookup`**, and the generic `DataSourceActions`
   detached object for design-time resolve (§4). Reused `FileListingAction` (with a blocking core) and
   `FlatDataSource` / `ReportDefiner` rather than reimplementing either, plus the Job `sources:` branch and
   graph-wide discovery by capability. O14 was spiked first, including delete. No
   `DataSourceId` minting, no resolver, no `DataSources` document.
3. ☑ **`ReadWorker`** (§5.2) — source-generic, `source:` a nullable nominal `ObjectReference` resolved
   against the compiled run snapshot (O14),
   `emit: items | units`, `role`, `attributes: ignore | columns` (the `groupBy` parity path),
   resolved manifest carried across migration with the open cursor detached, per-item `runBlockingIo`
   drive, `payloadFlow` from `staticShape`, heterogeneous schemas failing loudly (§5.3). A/B comparison with
   `CsvReaderWorker` / `MultiFileReaderWorker` over the same files produced identical message streams; the old
   readers stayed until that was green. **The ordinary File Worker plus the next Worker is the trivial case:
   two stage cards, no detached composition.**
4. ☑ **The editing surface** (§6.4): `FileSelectionEditor` provides typed, ordered file selection on the
   ordinary File Worker card. File and Logic live in the existing Sources ribbon and use the same
   select-tool → choose-stage-gap interaction, `WorkerDisplayDefault`, ordering, channel synthesis, validation,
   and progress paths as every Worker. Pure source objects, `DataSourceActions`, the graph-wide source picker,
   auto-bind, and the source-field summary remain for authored nominal `DataSource` + `ReadWorker` composition;
   no separate Job `sources:` section is rendered.
5. ☑ **`ReadPartWorker` + migration-safe 1:N execution** (§5.4) — the second reader, sharing step 3's
   drain core; an `ExpandingTransformWorker` that carries its active input batch across migration;
   ordered `partsOf(role)` reading; handle ownership. This is what the child-Logic idiom (§5.6b) and
   role fan-out (§5.6a) read with.
6. ☑ **Design-time shape** (§6.1–6.2): `DataSourceActions action=shape` tries the source's static
   declaration before bounded `inspectShape` on the file opener; the schema cache is a runtime service
   keyed on the stamped fingerprint (fixing `ColumnListingAction`'s stale-key bug for Report too), the
   declared-schema supply feeds `staticShape` (§6.3, O18), and `schemaMode: strict | superset`
   normalization landed for both readers (O19). `ReadWorker.payloadFlow` remains declaration-only; explicit
   inspected columns have a client-state provider but no production inline-Worker trigger (§6.1).
7. ☑ **The writer yielding its ref + generic hosted-argument/path binding** (§7) — a plain path,
   finalized before it is fingerprinted and yielded; `RunWorker.arguments` expressions + the named `JobControl.host`
   overload; one shared path-substitution helper; `ResultSinkWorker keep: all`; the resolved manifest
   published to the trace. Same-run composition only.
8. ☑ **`LogicDataSource` + `DataContext.host` + the dated example** (§4.4) — the first parameterized
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

*(Permanent outcomes, deviations and surprises that a later reader could not recover from the code.)*

### DS0 — data-layer package moves (2026-08-23)

Landed as a package/import-only move in `kzen-auto`: the three header vocabulary types now live in
`common/data/schema`, and the nine named JVM input-plumbing types live together in `server/data`.
Kotlin and Java consumers were rewritten, Report's listing wildcard was expanded, and the existing
`ListPipelineOutput` KDoc link follows `ReportInputChain` to its new package. The two concrete stream
implementations (`InputStreamFlatDataStream`, `FileFlatDataStream`) remain in Report's input subtree,
as the execution plan's exact move list required; `server.data` therefore retains two explicit imports
to those implementations. No notation or method bodies changed. The full `kzen-auto` build passed.
An isolated empty-project client-graph boot rendered the full UI with no browser console errors.

### DS1 — data-source value model and lowering (2026-08-23)

Landed the model under `common/data/model` and `DataShape` under `common/data/schema`, with canonical
digests, strict `ExecutionValue` forms, kotlinx wire forms, plain `DataLocation` interop, fingerprints,
role accessors and construction helpers. The existing coordinate, encoding, header and type-metadata
values are not kotlinx-serializable, so the new aggregate types own narrow wire adapters instead of
widening those shared contracts. `DataShape` uses an explicit `kind` field, and its payload decoder
validates every nested `TypeMetadata` key strictly. `fingerprintOrNull()` returns the reserved
`size`/`modified` text pair only when both are present; an empty unit is not single-role. Attribute
maps preserve supplied/decoded iteration order for display while their digests sort keys. The common
JVM and ChromeHeadless JS suites and downstream JVM/JS compiles passed.

### DS1b — expression visibility and registry retirement (2026-08-23)

Replaced the hardcoded inference whitelist with the reflected classifier predicate pinned by the design:
qualified name present, public visibility, and non-synthetic JVM class. `ExpressionReturnTypeInference`
now classifies and projects `Iterable`, `Sequence`, and `Iterator` through one `isStreamType` /
`streamElementType` contract, and both Job and Script runtimes convert those values through the same
iterator helper. Predicate-observed canaries are explicit: `Char` remains `kotlin.Char`, while the
compiler's `Nothing` probe reflects as `java.lang.Void`. First-party `DataUnit` lane typing is covered.

The now-redundant `ObjectRegistry` was removed end to end: common model/spec, server document and cache
threading, client controllers, tests, notation registrations, and architecture/cache documentation.
Sequence and Iterator fixtures pin both `FormulaSourceWorker` and ForEach behavior. The focused DS1b
matrix, an independent review run, the cold `FormulaStepTest`, and the full 75-task `kzen-auto` build
passed. An isolated empty-project browser boot rendered the full client with no console errors and no
Object Registry surface. Operational caveat: the cold-canary preparation deleted the regenerable
repo-local `work/code-cache` instead of moving it aside; the canary recreated a partial cache, but the
pre-run cache contents could not be restored.

### DS2 — suspend data-source runtime and file source (2026-08-23)

Landed the common `DataSource` / `DataOpener` / `DataCursor` / `DataContext` SPI, capability-based
`DataSourceConventions`, and the notation-round-trippable file-selection model. The JVM implementation
adds the stateless `FileDataSource`, generic `FileDataOpener`, context-free `FileDataCursor`,
`DataOpenerLookup`, and one detached `DataSourceActions` dispatcher. File resolution emits one unit per
file with plain refs, exact `size` / `modified` fingerprints, ordered regex-capture attributes, and
`skipped` diagnostics shaped as one `{kind, message}` entry per omitted file. Optional format/encoding
overrides are omitted from notation when absent; null encoding uses the selected plugin's default.

The existing Report input path remains the implementation seam: file listing now exposes a counted
blocking core and exact stat, while the opener infers formats from generic plugin metadata, opens header
and content separately, honours reusable-event skip/prototype semantics, buffers every row emitted by a
poll (including a final false-return poll), and keeps the dynamic classloader alive until cursor close.
Header-extractor failures now close their input chain in `finally`, pinned by a Windows file-deletion
regression. `DataOpenerLookup` accepts the plain opener through the `DataOpener` interface for DS3 tests.

O14 did not support the planned structural reference verbatim. A blank nullable reference defines and
can inject null when creation receives an equivalent nullable-aware closure, but
`GraphDefinition.filterTransitive` throws `Missing <empty>` before that point. A set reference pulls and
injects its target across documents; deleting the target prunes the host from `transitiveSuccessful` and
records a clear unresolved-reference failure. The spike was removed, kzen-lib was unchanged, and DS3
therefore uses the planned `by: Nominal` fallback with explicit lookup/instantiation.

The focused common/JVM/JS suites, full JVM suite, Report input regressions, and full 75-task build passed.
An isolated Java 26 server on a spare port returned a lowered manifest through the real detached-action
route, and the client rendered the scratch Job/source document with no console errors. Scratch files and
the verified server process were removed afterward.

### DS3 — source-generic declarative reader (2026-08-23)

Landed `ReadWorker` with the O14 nominal fallback: its nullable source stays an `ObjectReference` through
graph construction, then a run-bound `WorkerDefinitionContext` resolves it against the exact compiled
snapshot. Same-document sources reuse the run graph; cross-document sources use one unbounded run-local
cache and instantiate once even when their ordinary detached-service metadata opts out of caching. Blank,
dangling, wrong-type and creation-failure references survive long enough to become card validation errors.
The migration compatibility digest includes the resolved location, its closure/inheritance cache key, and
the reader's `emit`, `role` and `attributes` configuration.

Item mode resolves and carries one manifest, selects all parts for the pinned/default role, opens them through
`DataOpenerLookup`, and enforces one effective shape across parts and units. Tabular cursors must emit
`FlatFileRecord`; payload cursors preserve nullable values. `attributes: columns` prepends display-ordered
unit attributes and fails on collisions; unit mode emits each `DataUnit` whole and ignores item-only knobs.
Mixed shapes still fail deliberately because downstream consumers establish their schema from the first
message; DS6 owns superset normalization. The old CSV and multi-file readers remain usable archetypes but
were removed from the ribbon.

`DataReadCore` is the DS5-ready shared seam: role selection, one blocking `hasNext`+`next` pull that preserves
null, reopened-cursor skipping, shape/message conversion, and pull → convert → claim → send ordering. An open
cursor and its manifest/position/shape baseline transfer one way across migration, are driven by the new
control, and close on rejection/removal. `FileDataOpener` also closes a cursor acquired concurrently with
prompt cancellation before ownership reaches the caller, suppressing any close failure onto the original
cause instead of masking it.

Focused DS3 verification passed 69 tests; the full JVM suite passed 766 tests in 129 suites (zero failures or
errors, one skip), and the integrated 75-task `kzen-auto` build passed. Coverage includes RFC-4180 and
multi-file A/Bs against both old readers, stable lexical file/unit order, real manifest mutation plus live
cursor adoption after the path is deleted, 1,000 rows, roles, attributes, nullable payloads, nominal
same/cross-document resolution, cancellation handoff, validator failures, notation execution, and a gated
Read → Summary live migration. An isolated Java 26 run on port 18135 returned retained trace values
`read.emitted=1000`, `summary.count=1000`, and `write.written=1000`; the output held 1,000 records plus its
header. Headless Chrome rendered the scratch Job and its completed Read/Summary cards with no console
exception. The verified JVM and scratch directory were removed afterward.

### DS4 — sources editing surface (2026-08-24)

The initial implementation put a generic Data sources section before the Worker stage and inserted
`FileDataSource` / `LogicDataSource` objects there. That interaction was rejected in review: a Job ribbon tool
selects a Worker, and the user chooses that Worker's position in the one stage. The corrected surface removes
the detached section and its `DataSourceCard`. **File** and **Logic** are ordinary Sources-ribbon Workers,
remain selected until an insertion gap is chosen, render through `WorkerDisplayDefault`, and participate in the
same ordering, drag/drop, channel synthesis, validation and progress paths. Both reuse `ReadWorker`'s
manifest/projection/cursor/migration engine through channel-free `DataSource` delegates; they are not
notation-discoverable DataSource objects or inspected-source providers. Pure `FileDataSource` /
`LogicDataSource` objects plus nominal `ReadWorker` remain available for authored cross-document sources,
without a special Job-editor region.

The original generic source-object editing work also landed before that correction.
`SelectDataSourceEditor` discovers sources across the graph in deterministic current-document-first
groups. Worker insertion auto-binds only when exactly one same-document source and exactly one blank
DataSource-typed attribute exist; a sole picker option is otherwise display-only and never rewrites an
existing blank or dangling value. Bound Worker cards show a defensive source link/teaser, and deletion
leaves a clear missing-reference state. No source id is minted and neither `JobController` nor the card
contains file-source-specific branching.

`FileSelectionEditor` owns ordered `FileSelectionSpec` editing, per-file format/encoding overrides,
contains-all-words filtering, selection and reorder. The inline File Worker renders a compact selected-file
summary plus **Choose files**; the button opens the same wide breadcrumb/search/metadata-table presentation as
Report, and the remaining emit/schema/runtime-query settings stay available under **Advanced**. Chooser-only
navigation persists under `browser.directory` / `browser.filter`; runtime `directory` / `filter` remain blank
unless deliberately configured, including after the last explicit file is removed. Request epochs prevent an
older listing from replacing a newer one, and debounced per-file commits clear only their matching pending value.
The legacy `MultiFileInputEditor` alias remains functional with transient directory/filter controls for empty
`paths` workers and persists only the paths list. Resolve epochs are globally monotonic across delete/recreate ABA
cycles, and the generic editor fallback degrades unknown registrations to the default editor with a warning
instead of bricking the client graph.

The initial detached-source implementation's review and test evidence remains useful for the pure authored
`DataSource` + `ReadWorker` path: it closed resolve ABA, missing attribute-summary loop, legacy-empty-path,
debounce, listing-order and no-op draft-cleanup defects, and covered graph-wide selection, rename/delete,
manifest fingerprints, diagnostics and execution. It is not evidence for the corrected Job interaction.

The corrected interaction was re-verified on a fresh production JS bundle and isolated Java 26 server. Clicking
File or Logic changed only ribbon selection and exposed the normal stage gaps; choosing a gap persisted exactly
one `main.workers/*` object (`FileSourceWorker` / `LogicSourceWorker`) and rendered it through the ordinary
Worker card. The Sources tab retained File / Logic / Read / Formula Source, while no Data tab, `Data sources`
heading or detached card existed. Both File and Logic cards were inserted in one stage and the browser console
was clean. Compiled notation fixtures execute both inline Workers; the Logic fixture also pins migration identity
to the hosted Logic definition closure, so editing a query cannot adopt a stale manifest/cursor. The verified
process and isolated scratch project were removed.

A second UI review rejected the inline File card's raw wall of fields. The follow-up retained the same Sources-
ribbon Worker and insertion flow, but contributed `FileSourceWorkerDisplay` through the existing `display:` seam.
At rest the card now shows **Choose files**, a compact ordered-name summary, and a collapsed **Advanced** section.
The wide chooser is the extracted `FileBrowser` also used by Report: breadcrumbs, editable path, contains-all-
words search, folders-first table, Selected/Modified/Size columns, range/select-all state, and counted Add/Remove.
Browser acceptance selected and removed multiple files, kept a child folder visible under an active filter, and
proved the persisted empty-selection notation contained only `browser.directory` / `browser.filter` plus
`files: []`—never the runtime directory query. The Report input rendered the shared surface without console
warnings or errors. The isolated port-18109 process and scratch project were removed.

The post-correction integrated `kzen-auto` build passed all 75 tasks in 4m01s, including the JVM, common-JVM,
common-JS browser and application-JS browser suites. Independent re-review found no remaining concrete issue.

The corrected inline Workers deliberately omit the removed source card's click-only Resolve/Columns chrome.
Their declared schemas still participate in server validation; downstream editor suggestions come from a live
Summary. Restoring pre-run inspection requires a channel-free source-description capability rather than
instantiating a Worker through `DataSourceActions`.

**Correction (2026-08-24): the chooser dialog is gone.** User testing rejected the **Choose files** launcher
outright — a modal is a worse interface than the inline browsing Report already ships, and card narrowness was
not a good enough reason to differ. `FileSelectionEditor` now has one render path for every consumer, Report's:
the ordered selection table, then the shared `FileBrowser` inline — pinned open while the selection is empty,
behind a **Browser** toggle once it is not, listing lazily on first open. That removed both the dialog *and* the
hand-rolled second listing the non-marker branch used, about 180 lines. The stage card widened from 40em to 56em
to carry it; the width is now one constant, `JobObjectSlot.cardMaxWidth`, which `JobController`'s insertion gaps
also read so the gold channel pipe cannot drift out from under the cards.

The same pass closed a latent hazard the old inline branch carried: `FileDataSourceConfig` had no `browser:`
marker, so browsing a pure `FileDataSource` persisted into its **runtime** `directory` / `filter` and silently
armed a directory scan — exactly what `FileSelectionBrowserConventions` documents must not happen. The marker and
its `browser: {directory, filter}` value block moved onto `FileDataSourceConfig`; `FileSourceWorker`'s duplicated
copies were dropped and are now inherited. One rule remains in the editor — marker present means navigation
persists there, marker absent (legacy `paths`, third-party opt-outs) means it stays in component state — so
`browserPaths()` returns null instead of falling back to the runtime attribute names, and the `separate` flag is
gone. `updateFilter` had also been writing a `filter` attribute for the legacy `paths` case, which no longer
happens.

**Follow-up (2026-08-24): the selection had to match the browser too.** Testing the inline card next showed its
two halves were mismatched — the browser was Report's shared table while the selection under it was still a bare
row of icon buttons — and the browser sat *below* the thing it fills. The order was flipped (browser first,
selection below) and the selection became `FileSelectionTable`, a presentation-only component sharing
`FileBrowser`'s frame, sticky header and hover/checked palette (extracted to `FileTableStyles`) plus its
shift-range checking (`FileBrowserSelection`). Per-row up / down / delete icon buttons gave way to Report's
check-then-act bar — **Remove (n)**, **Up**, **Down** — alongside Report's **Details** toggle, which reveals the
full path and the per-file format / encoding overrides that are what make a row wide. `moveChecked` is a pure
companion function: checked entries travel as a block, and an entry already against the edge it is moving towards
holds back the rest of its run, so a multi-row move cannot scramble itself against the boundary.

**Follow-up (2026-08-24): four things the first real use of the card found.** Running a Job against it surfaced
one genuine data-layer regression and three interface faults, fixed together.

The regression: selecting a file whose extension no reader claims — a `.md` — failed the run outright, because
`FileDataOpener.inferCoordinate` had re-implemented extension matching locally and dropped the fallback the shared
`ReportDefinitionRepository.find` has always applied (prefer an extension match, else the highest-priority
non-avoid definition, i.e. Text). A Report reading the same file simply read it as text. `inferCoordinate` now
delegates to that shared resolution, so an unclaimed extension reads as one Text column and the row's **Format**
under Details is right there to override; the remaining throw names the registered extensions. DS3's "fail loudly"
principle is untouched — this was never schema variation, only a missing default.

The failure was also *unreadable*. `Outcome.Failed.message` already travelled the whole way
(`OutcomeTrace` → `RunEngineLogicTrace` → `JobProgressStore` → `WorkerOutcome.message`) but was rendered only as
the chip's raw `title` attribute, so every run failure read as a bare red badge; and `RunEngine` stringified the
throwable without ever logging it, so `run.log` held nothing either. The Worker card now renders the reason under
its header — the Script step card's long-standing `renderError`, which Workers never got — and the engine logs the
throwable before discarding it (the one kzen-lib change).

The **Browser** toggle moved into the card's title bar, where Report has always kept it. That crosses a real seam:
the toggle's openness lives in an attribute editor mounted generically through `AttributeEditorManager`, whose
props contract is deliberately fixed at `{objectLocation, attributeName}`. Rather than widen that contract for one
Worker, the two ends meet through a `DocumentBridge` channel (`FileBrowserToggleChannel`) — the seam that exists
for exactly this — with `WorkerDisplayDefault` gaining a generic `headerRight` slot beside `bodyBefore`/`bodyExtra`.
A header claims a card by hosting it; an unclaimed card (a plain `FileDataSource`, the legacy `paths` attribute)
keeps drawing its own toggle unchanged.

Two spacing repairs completed it: the Advanced field stack was using the label-to-field margin between whole
fields, so adjacent outlined legends collided (restored to `ScriptStepDisplayDefault`'s value); and the stage's
top-right float stack (Parameters / Result / Channel defaults) reserved no horizontal space, so below ~1400px it
sat *on* the first card and, being the only thing there with a z-index, swallowed that card's clicks — including
its own Delete. `StageFloatStack` now also owns the width it claims, applied to the Job stage as padding. Because
an absolutely positioned element resolves against its ancestor's padding box, this moves the stack not at all and
merely stops the content growing underneath it.

**Follow-up (2026-08-25): the card said less, and its two hardest fields became selectable.** A second pass over
the same card removed three things that were only taking up room. The selection editor's `Files` caption repeated
the heading of the card it fills, and is gone; the card header's `—` status placeholder, shown by every Worker
before its first run, is now simply absent (a dash beside a name reads as part of the name until the eye rules it
out); and the browser's "matches names containing all of these words" line became the search field's own
placeholder and hover, so the hint appears exactly while the field is empty and costs no line.

The substantive half: **Format** and **Encoding** were free-text on both the Worker (its defaults, under Advanced)
and each selected file (its overrides, under Details), which asked the user to know a plugin coordinate or a
charset name by heart and turned a typo into a failed run with no hint of the spelling that would have worked.
Both are now selects, fed by a new `fileFormats` action on `DataSourceActions`. It answers *before* a source is
resolved — the catalogue describes the server's installed definitions, not one configured source, so it stays
available on a source that cannot currently be instantiated, which is exactly when someone is in its editor. The
formats are scoped to the payload type `FileDataOpener` resolves among, so what can be chosen and what can be read
cannot drift apart; the encodings are every charset this JVM installs, ordered by how often a real input file turns
out to be in one. `DataFormatStore` fetches it once per mounted document through the `DocumentBridge`, so a Job
with ten File Workers asks once. Blank is a real option labelled **Default** rather than an empty field, and a
value the catalogue no longer offers is still listed, so an existing configuration reads back as what it says
instead of looking unset. One component (`DataFormatEditor`) sits behind both notation registrations; a Details
pick now commits at once rather than debouncing, since choosing from a list is a finished decision.

**Follow-up (2026-08-25, second): the browser says where it is.** The chooser's path opened on `.` — the notation
default `./`, shown verbatim — which names no place a reader recognizes and has no parent to walk up to, so the
browser's default location was both unreadable and a dead end. Report never had this: its `browserInfo` action
returns the directory *normalized*, and the Input browser shows that rather than the stored value. The Job path
went through the document-agnostic `GET /file-listing` route, which returned only the file list. It now returns
`DataListing` — the files plus the absolute directory that was actually read — because only the server knows what
a relative path resolves against. `FileSelectionEditor` displays the resolved directory when one has arrived for
the current request and the stored value otherwise, dropping it whenever the directory changes (a filter change
keeps it: the directory has not moved). Nothing is written back, so notation still holds `./` and stays portable;
what is stored and what is shown are simply allowed to differ, exactly as in Report.

### DS5 — `ReadPartWorker` and migration-safe 1:N execution (2026-08-24)

Landed `ExpandingTransformWorker` as a distinct execution base without changing `TransformWorker`'s
whole-input-batch semantics. The expanding base freezes and owns each received physical batch, its current
element index, and an output cadence that flushes before every checkpoint. Its composite migration state is
`AutoCloseable`, so an unadopted detached subclass resource closes on worker removal or type replacement.
`Emitter` now exposes the shared flush cadence used by sources and expanding transforms, and an explicit flush
resets the cadence before touching the channel. A final base lifecycle hook closes the output exactly once after
subclass cleanup on normal completion, setup failure, or cancellation.

`ReadPartWorker` consumes non-null `DataUnit` payloads, selects every part of the requested/default role in
order, and reuses `DataReadCore` for opening, blocking cursor operations, message conversion, shape enforcement,
claim-before-send, skipping, and closure. It keeps one shape baseline across parts and units, counts completed
units and emitted items, and carries the active unit, part/item positions, cumulative unit ordinal, baseline,
progress, and a one-way detached cursor. Same-configuration migration adopts the live cursor. A role or
attributes change closes it, reopens from the first selected part, and skips the cumulative emitted ordinal;
the retained effective-shape baseline permits a semantically identical change and rejects a real schema change
before another message is sent. Static output remains unknown, and only a known non-null `DataUnit` input is
accepted; no resolution or opener inspection occurs in the validation walk.

Independent review found and closed overly broad attributes-change rejection, incompatible captured-state
leaks in both Read/ReadPart replacement directions, setup-failure output closure, and several migration test
gaps. Coverage now includes a real `JobChannel` proof that a three-unit physical batch has left the input while
a rendezvous output flush owns the in-flight prefix, exact-final-item migration, changed-role skipping across
multiple parts, safe and incompatible attributes changes, cross-unit and migrated shape baselines, orphan and
cross-type cursor disposal, 1,000-item cadence, cancellation, real CSV composition, a hosted child Job, validator
lanes, and engine migration mid-unit. The focused repair gate passed 71 tests across seven suites; the final full
JVM plus JS compile gate passed in 12m42s (44 tasks, seven executed). `ExpandWorker` was deliberately not built:
a concrete demand for generic in-memory stream expansion remains the trigger, and expressions still initiate no
source I/O.

### DS6 — design-time shape, schema policy and editor columns (2026-08-24)

Landed the two shape questions as separate contracts. `DataSource.staticShape(role)` is answered from
the compiled notation snapshot, while `DataOpener.inspectShape(context, part)` may perform one bounded
runtime inspection. `DataSourceActions action=shape` accepts a structured `DataPart` body and asks the
source declaration first, so a declared shape wins without looking up or opening the ref. File inspection
shares one effective format/encoding resolution path with opening and reads only the header boundary. No
current coordinate has a headerless positional mode: CSV/TSV declare their first record as the header and
Text declares the literal `Text` column, so the applicable acceptance covers those supported semantics.

The shipped field/type document was renamed end to end from `DataFormat` to `DataSchema`. A
`FileDataSource` may hold a nullable strong structural schema reference; blank remains representable, while
source and schema edits both widen the Job validation digest through the capability-marked provider closure.
The schema still retains each field's `TypeMetadata`, but DS6 projects only its ordered labels into the
tabular lane and makes no typed-column wire claim. This resolves O18 and the parked EXT-D5/E6 gate without a
release version bump.

`SchemaCache` is an exact persistent runtime cache keyed only after defaults are resolved by
`(ref.id, format, encoding, size, modified)`. Unfingerprinted refs are inspected but never cached; corrupt
disk entries are misses; writes replace atomically; managed storage deletion invalidates memory. Report's
`ColumnListingAction` now shares that identity, closing its stale-columns bug. The Job validation walk is
stricter than the original draft: it reads only `staticShape` and performs zero resolve, opener-inspection,
cache or filesystem calls. The validator's capability-driven dependency digest uses effective inherited
source attributes and the source's strong schema closure, including cross-document providers.

Both readers now expose `schemaMode: strict | superset`, default `superset`. `ReadWorker` pre-inspects every
selected manifest part; `ReadPartWorker` pre-inspects the current streamed unit and requires later units to
match the established worker-wide lane. Ordered superset projection places every first-seen unit-attribute
key before every first-seen data label, rejects collisions across the whole selection, and materializes every
absent cell as canonical `<missing>`. `strict` retains the exact-shape contract. Cursor open verifies the
shape observed during pre-inspection, and the inspection plan/baseline participates in migration state.

Client inspection remains explicit and click-only. `DataSourceShapeStore` is keyed by source plus manifest
digest, uses monotonic epochs across delete/recreate ABA and unmount, and retains per-part results. The source
card renders Columns beside Resolve, while `JobUpstreamSchema` resolves providers in the order live summary →
reserved J4 transformed-lane slot → explicitly inspected source → none. Inspected shapes are projected through
the capability provider's effective inherited Read configuration, including selected role,
`attributes=columns`, strict/superset policy and units-mode exclusion; failures in unselected roles do not hide
a valid selected lane. Sort, value-set and pivot editors therefore offer known columns without a run and stay
free text when no provider answers. No row preview was added.

Independent review found and closed a stale physical strict expectation, raw all-role client aggregation,
inherited-source cache invalidation, and an unselected-role settlement gate. Focused gates finished with 105
JVM tests across nine suites, 15 common JVM tests, and 37 unfiltered browser tests, all with zero failures or
skips; the deterministic 100-part pre-scan took 0.014 seconds. The coordinator's full JVM plus JS production
compile gate passed in 15m56s. On an isolated Java 26 server, browser acceptance showed per-part chips and the
ordered union, a pre-run Sort dropdown, directory-walk free-text fallback, a 103-row heterogeneous Read → Sort
→ Preview run with `[id, name, qty, price]` and `<missing>` projection, and immediate column refresh after the
disposable file's fingerprint changed. A direct detached POST returned the structured tabular shape. The
verified process and scratch project were removed afterward; J3b and the standalone E6 gate are absorbed.

### DS7 — writer refs, named child arguments and per-unit paths (2026-08-24)

Landed generic named child hosting without narrowing the engine's existing default/null semantics.
`JobControl.host(instructions, arguments)` has a one-component compatibility default; the engine rejects
duplicates and unknown names, orders supplied components by the child signature, and deliberately permits
omissions. `RunWorker.arguments` is the stricter Job-facing boundary: a nonempty map must bind every additional
Job input, while the empty map retains positional hosting and Script/Flow named calls may remain partial.
Expressions compile lazily per received flat header with the incoming payload, the exact received columns and
outer Job parameters in scope, and preserve raw String, Char, Boolean and Number values.

`PathPatternSubstitution` is the one neutral `${name}` / `$$` grammar. Report exports retain reserved variables,
filename sanitization and whole-path underscore collapse outside the helper; writers resolve only referenced
scalar Job parameters and preserve inserted dollars, separators and repeated underscores. Both built-in writers
now create parents, finalize successfully before exact stat, validate that their declared result accepts a
non-null `DataRef`, and yield one plain fingerprinted ref. Their shared retryable ownership keeps failed or
cancelled cleanup reachable. ZIP entry and stream closure track independent phases, so a failure cannot skip the
underlying close or repeat a completed entry close. Writer live migration still restarts and truncates; J9 owns
file-backed carry-forward. J4 extends this single-container contract to grouped containers and an ordered
`DataUnit`; DS7 did not add grouping.

The capability-driven `ResultYielder` marker covers `ResultSink` and writer subtypes. Validation resolves blank
ResultSink output to `main`, treats a blank writer result as inactive, checks declarations, reports every
collision participant, and joins collision text with existing worker errors. `ResultSink keep: all` returns an
ordered `List<elementBoundaryType>` including `emptyList()` for an empty stream and documents its unbounded
memory; migration restoration is defensive and same-mode only. A fresh `ReadWorker` resolution logs exactly one
bounded manifest record with full digest/count and complete teaser fingerprints; an adopted manifest does not
log again.

The engine-level fixture runs three dated units through outer Read → named Run → child ReadPart/transform/write
and outer `keep: all`, then asserts three retained child invocations, ordered in-process `DataRef` results,
canonical paths, final fingerprints and file contents. No completed-result REST route lowers a `TupleValue`, so
the acceptance pins the in-process boundary and adds no invented persistence API. Independent review found and
closed runtime argument-completeness, writer cleanup ownership, result-type validation and ZIP retry defects.
The final focused matrix passed 75 JVM tests plus common/JS compilation; the coordinator's unfiltered gate passed
836 JVM tests across 137 suites with zero failures/errors (one existing skip) and compiled the JS application in
13m10s. Same-run composition is complete; no cross-run result registry was added.

### DS8 — authored `LogicDataSource` and dated ETL acceptance (2026-08-24)

Landed `DataContext.host(instructions, arguments)` with the runtime context delegating unchanged to DS7's named
Job host. The design context fails explicitly because resolving authored source logic requires an active run; no
hidden detached run competes with the interactive controller. `LogicDataSource` implements only `DataSource`.
It defensively copies its ordered argument names, rejects duplicates, reads each value by name (including null),
hosts exactly once, and preserves engine omissions/defaults for names it does not declare. Missing or null main
is an empty manifest. Otherwise the result must be an eager `Iterable` whose materialized elements are indexed
and validated as `DataUnit`; Sequence, Iterator, scalar and mixed results fail clearly. Units and their plain refs
pass through unchanged, diagnostics are empty, and only the optional declared main schema contributes a static
shape. The shared `FileDataOpener` reads those refs identically to file-source refs; no opener, source id or
catch-and-relabel layer was added.

The one-step dated Script was the real gate. Before the repair, its forced `List<DataUnit>` Result signature
generated code without importing the nested `DataUnit` classifier and failed compilation. `ResultStep` now
threads the declared `TypeMetadata` through validation and execution code generation, and the generic expression
compiler imports every recursive `classNames()` entry from scope plus the forced return type. No LocalDate,
DataUnit or data-source case exists. A second generic correction makes `RunWorker` validate a known typed payload
against an empty header when no flat columns exist, matching its runtime expression compilation instead of
falling back to syntax-only validation.

The dated Script remains a test fixture rather than a user-visible project archetype, matching the plan's
default. The arc fixture extends DS7: an outer ordinary `LogicSourceWorker` resolves and emits three dated units,
Run binds each date, and a child uses two independent FormulaSource(unit) branches. The main ReadPart lane writes
and yields one fingerprinted ref; the reference ReadPart lane performs a separate transform and output side
effect, proving it is live without adding fan-out, Lookup or expression I/O. The test asserts three retained
child invocations, ordered plain refs, exact files/fingerprints and both branches' contents.

Independent review was clean. The final gate passed 850 JVM tests across 140 suites (zero failures/errors, one
existing skip), 294 common JVM tests and 294 browser-backed common JS tests, plus JS application compilation, in
14m20s. The pre-correction browser acceptance inserted a detached Logic source, selected the authored dated
Script, configured `from`/`to`, and showed the active-run Resolve message; that interaction is superseded and is
retained only as runtime evidence. The full three-day ETL then
completed twice — once before and once after editing the Script expression — with 3 units, 3 child runs, 3
collected refs, three main files and three independent reference-effect files; the console was clean. The
verified process and scratch project were removed. O12 remains open because this resolve-only source owns no
connection; the first JDBC/API source is still the correct decision point. The DS execution arc is landed.
