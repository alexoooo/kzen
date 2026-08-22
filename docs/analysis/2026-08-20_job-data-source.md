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
(§5.2a) for the declarative, no-code case; `FormulaSourceWorker` + `ExpandWorker` (§5.2–5.3) when
the resolution is an expression over run parameters. Nothing in either path knows it is a file.

## 3. The model

### 3.1 The four concerns to keep apart

| Concern | Question it answers | Lives in |
|---|---|---|
| **Query** | what do I want? | `DataQuery` — config, may reference run parameters |
| **Resolve** | what does that actually name, right now? | `DataSource.units(scope)` → `List<DataUnit>` |
| **Describe** | what shape is it? | `DataSource.schema(scope, part)` → `HeaderListing?` (columns) and `itemType(part)` → `TypeMetadata?` (the static item type) — editor- and walk-facing (§6.1, §5.5a) |
| **Open** | give me the items | `DataSource.items(scope, part)` → `DataItems`, a LAZY constrain-once `Sequence` (§4) |

Report fuses query+resolve into `FileListingAction` (edit time only) and describe into a separate
action with its own cache. Splitting them is what makes parameterized resolution and pluggable
non-file sources possible at all.

### 3.2 Value types

```kotlin
// The DURABLE identity of a source object — a value minted into the object's own notation once, at
// insert, and never rewritten by rename / move / restart. NOT an ObjectStableId (§3.3). [decided 2026-08-21b]
value class DataSourceId(val value: String)

// A reference minted BY a source and meaningful only TO that source. [decided]
data class DataRef(
    val source: DataSourceId?,                 // the DataSource object that owns it; null = ambient/plain path
    val id: String,                            // canonical, digestible, displayable
    val attributes: Map<String, String> = mapOf()   // source-specific addressing extras
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
    val attributes: Map<String, String>,       // {date: 2026-01-01} — ordered, text-canonical
    val parts: List<DataPart>                  // ordered; partsOf(role) filters
): Digestible

// The resolution of a query at a point in time.
data class DataManifest(
    val units: List<DataUnit>
): Digestible
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

What is true: the attributes reach a downstream lane through an **expression** — `emit: units` →
`ExpandWorker`/`FormulaWorker`, where the unit is in scope and its attributes can be stamped as columns
(and, in the child-Logic idiom of §5.6b, through the child's declared `unit` parameter). That is the
accepted answer; it means **`groupBy` parity depends on the expression route (DS5), not on DS3**, and
§9's parity table says so.

Against: an expression that wants `unit.date` as a real date has to parse. That is the same cost
every flat column already pays, so it is not a new class of problem. If typed attributes are ever
justified, they arrive with the column-typing arc (§6.3), not before.

## 4. `DataSource` is an object with a callable API, not a Worker **[decided]**

```kotlin
interface DataSource {
    /** Resolve the source's configured query into concrete units — a point-in-time snapshot (§8.1). */
    fun units(scope: DataScope): List<DataUnit>

    /** Open a part and read it as a LAZY, constrain-once, closeable item stream. */
    fun items(scope: DataScope, part: DataPart): DataItems

    /** The columns a part would yield, from a DECLARATION or a BOUNDED read. Null = not statically knowable. */
    fun schema(scope: DataScope, part: DataPart): HeaderListing?

    /** The static type of this part's items, answerable from NOTATION ALONE — never IO (§5.5a, O3). */
    fun itemType(part: DataPart): TypeMetadata?
}

/** The per-call environment. Nothing on [DataSource] is `suspend`; the offload lives here. [decided 2026-08-21b] */
interface DataScope {
    /** A run parameter / detached request parameter, BY NAME (never positional — O13). */
    fun argument(name: String): Any?

    /** The run's Context registry (`Execution.resourceValue`), or the design-time session. Null when absent. */
    fun contextValue(key: String): Any?

    /** Quiescence-visible blocking offload: `JobControl.runBlockingIo` at run time, identity at design time. */
    fun <R> blocking(block: () -> R): R

    /**
     * Invoke a child Logic — `JobControl.host` at run time. What `LogicDataSource` (§4.4) resolves through;
     * a design-time implementation is deferred, so a source that needs it reports "resolve requires a run"
     * in its card rather than pretending.
     */
    fun host(instructions: ObjectLocation, input: Any?): TupleValue
}

/**
 * One part's items. A `Sequence` rather than an `Iterable`: Kotlin's Sequence contract explicitly permits a
 * single-shot implementation ("can be iterated multiple times OR NOT, depending on implementation"), so
 * constrain-once is honest here where an Iterable would be a contract violation. [decided 2026-08-21b]
 *
 * `flatHeader != null` means EVERY item is a flat record (`FlatFileRecord`) under that header; null means the
 * items are payload objects. That is how a reader chooses `JobMessage.ofFlat` vs `ofPayload` without a class
 * switch (CC-17).
 */
interface DataItems: Sequence<Any?>, AutoCloseable {
    val flatHeader: HeaderListing?
}
```

**Why nothing is `suspend`, and why there is a scope [decided 2026-08-21b].** The previous draft had
`suspend fun units(…)`, which does not compose with the one thing a Worker must use:
`JobControl.runBlockingIo` takes a **non-suspend** `block: () -> R` (it offloads through
`Execution.blocking`, which is what keeps the call counted by the `CountingDispatcher` and interruptible
by cancel / migrate). `control.runBlockingIo { source.units(…) }` therefore did not compile. Worse, the
file source's resolve was to reuse `FileListingAction.scanInfo`, which internally does
`withContext(Dispatchers.IO)` — precisely the uncounted dispatcher `JobControl`'s KDoc forbids, because
it reads as false quiescence and spuriously pauses the Job.

Making the SPI blocking and putting the offload in the scope fixes that at the right granularity: the
source decides *what* to offload, the caller decides *how*. `ReportDefinitionRepository` is already
fully non-suspend, so the read path needs nothing; `DetachedAction.execute` is `suspend` and wraps at
the action boundary, where quiescence does not apply. The one chore is splitting a blocking
`scanInfoBlocking` core out of `FileListingAction.scanInfo` and letting the existing suspend method
delegate to it, so Report's callers are untouched.

The scope earns its place three times over. `argument(name)` replaces DS8's positional-arguments
compromise (its own plan calls positional "brittle" and documents it rather than fixing it) with one
naming convention that works identically from a reader, a detached call, and an expression.
`contextValue(key)` is how a stateful source reaches a resource **without holding one** — see the
lifetime bullet below. And `blocking` is the seam above.

A Worker exists only during a run, and this is needed in **two** contexts:

1. **Design time** — the editor asks "what does this query resolve to?" and "what columns?" with no
   run in sight, over a detached action (Report does exactly this today with `FileListingAction` /
   `ColumnListingAction`; J3 already plans to make them flavour-neutral).
2. **Run time** — as a **library called from expressions**: `sales.units()` in a
   `FormulaSourceWorker` (its run parameters reach the source through `DataScope.argument`, §4),
   `items(part)` in the 1:N transform (§5.3).

Note what (2) means: there is no data-specific worker, no data-specific port, and no data-specific
notation shape. The source object supplies *configuration* (which directory, which pattern, which
connection) and *behaviour* (resolve, describe, read); the wiring is ordinary expressions over
ordinary lanes.

Being a notation object is still the customization seam and is still worth the object-ness: a
third-party source is another archetype in the graph, discovered through the object registry and
classified **by capability, never by class name** (CC-17) — the `JobServeCapability` /
`JobSignatureCapability` pattern. It also gives the editor something to bind a browse/preview UI to,
which a bare function in an expression would not.

Two consequences of "design time" being on the list, both general rather than data-specific:

- **The source object is a `DetachedAction`.** The editor's browse / resolve-preview / schema calls
  go through `ModelDetachedExecutor.execute(objectLocation, request)`, which instantiates any object
  by location from the full graph and calls it — the `FileListingAction` / `ColumnListingAction`
  precedent, now with the query *on the object*. Card chrome in the Job editor (preview the resolved
  manifest, show columns) is generic over sources because it only speaks this protocol.
- **Resource lifetime — a source BORROWS, it never OWNS [decided 2026-08-21b].** A file source is
  stateless; a JDBC / API source needs a connection. It does **not** hold one. It declares the Context
  it uses (`is: ObjectLocation, nullable: true, by: Nominal` — the `ContextBinder.binds` shape) and
  reads the value through `DataScope.contextValue`. At run time that is the Context registry the engine
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

  Design time then shrinks from "invent a resource model" to "a `DataScope` implementation whose
  `contextValue` has a project-scoped owner". v1 is request-scoped open/close inside a
  `DesignDataScope` — exactly what O12 already recommends — and **no source changes** when the explicit
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

### 4.3 A `DataRef` carries its own source, so there is no `ParameterDataSource`

An earlier draft wanted a `ParameterDataSource` — a source whose "query" is a Job parameter holding a
`DataUnit` — so a child Job could read the unit its caller passed. With reading done from an
expression, that whole construct disappears: the child's parameter *is* the `DataUnit`, and each
`DataPart` names its own owning source through `DataRef.source` (§3.2). So the child simply writes
`items(unit.part("main"))`, and the free function dispatches on the ref's source.

This is where the opaque, source-relative `DataRef` (§3.3) stops being a display concern and starts
paying operationally: a unit handed across a Logic boundary is **self-opening**. Nothing at the
receiving end needs to be configured with where the data came from.

### 4.4 Authoring a source without writing Kotlin — `LogicDataSource` **[decided in shape 2026-08-21b]**

§2 criticises `ReportDocument` for fusing query + resolve + describe. `DataSource` fuses resolve
(`units`) + describe (`schema` / `itemType`) + open (`items`), so the same criticism deserves an
answer rather than silence.

The fusion is **kept**, because for a JDBC or API source it is functionally necessary — resolution and
reading share a connection, and §4.3's self-opening `DataRef` depends on a part naming something that
can open it. But the fusion should be *available*, not *imposed*, because the three parts have very
different variability:

- **Resolve** is the variable part. It is a parameterized computation returning a list — which is
  exactly what a **Logic** is.
- **Open** is not variable at all for anything file-shaped: a byte source plus a format plugin, both of
  which already exist and work (`FlatDataSource` + `ReportDefiner` / `ReportInputChain`).
- **Describe** is a declaration (§6.3) or a bounded read.

So one shipped implementation opens the extension point:

```
LogicDataSource(instructions: <Script | Flow | Job>)
    units(scope)        = scope.host(instructions, arguments)   // main component: List<DataUnit>
    items(scope, part)  = the shared flat-file opener, via the ref
```

A user authors resolution as a **Script** that returns a list of `DataUnit`s, and gets tracing,
stepping, breakpoints and pause-on-error for free — `JobControl.host(instructions, input)` already does
exactly this for `RunWorker`. The parts it mints are plain refs (`source == null`, O4's first-class
case), so opening needs no Kotlin and no new SPI. A JDBC source, meanwhile, stays a single fused
`@Reflect` object.

Two prerequisites, both already implied elsewhere: `DataScope.host(…)` (run time = `JobControl.host`;
design time deferred — such a source honestly reports "resolve requires a run" in its card, which is
consistent with §6.2's cost discipline), and expression-constructible model types — the §5.5a
visibility fix plus a small helper family (`DataUnit.of(attributes, parts)`,
`DataPart.ofPath(role, path)`).

**This is a better final session than a hand-written dated-path source** (§12): the dated case becomes a
shipped example Script over `LogicDataSource`, proving the extension point instead of adding a ninth
Kotlin class. Keep a Kotlin `DatedPathDataSource` in reserve if date iteration in a Script proves
clumsy — **O16**.

## 5. Workers — what already exists, and the one real gap

> **Revised twice.** An earlier draft proposed a `DataSourceWorker` and a `DataSplitWorker`; the
> second should be a domain-free expression worker (§5.3). The first was then rejected as "already
> exists" (`FormulaSourceWorker`) — and the 2026-08-21 walk-through of the trivial case reinstated it
> in **source-generic** form as `ReadWorker` (§5.2a): the expression route alone makes "count the
> lines of one file" four things and two Kotlin expressions, which fails §1's ergonomics goal
> outright. The rule that survives is **no *file*-specific worker** — `ReadWorker` reads any
> `DataSource`. What follows is what the existing workers cover, the declarative reader, the one
> expression-side capability missing, and the three costs of reading by expression.

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

### 5.2 The source side already exists — `FormulaSourceWorker`

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
ReadWorker(source: <DataSource>, emit: items | units, role: <DataRole>?)   -> item lane or unit lane
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
- **`payloadFlow`.** Under `items`, publishes `itemType(part)` (notation-only, no IO) as the payload
  type and the columns from the editor's pre-scan **cache** only (keyed per §6.2) — a miss is
  "unknown", never IO on the walk, so O3 holds. Under `units`, `payloadType = DataUnit`. This is the
  static-schema story §5.5 said the expression route could not give; the declarative reader gives it.
- **Cursor.** This is the one place a positional cursor lives — `(unitIndex, partIndex, position)`
  with the open handle detached across a migration, exactly `CsvReaderWorker`'s pattern. The resolved
  manifest is **carried** across the migration and never re-resolved, and adoption is guarded on the
  source's definition digest plus this worker's own config — see §8.1, where this supersedes the
  earlier "compare the manifest digest" recommendation.
- **Mode knob vs two workers.** **[open]** O11. A mode knob changes the card's output cardinality,
  which is the objection O1 raised against folding expand into `FormulaWorker`. It is weaker here: a
  source worker has no incoming lane, so there is no ordering question and no migration state to
  split; only the published payload type differs, which `payloadFlow` already handles per mode.
  Recommendation: the knob. If the rule becomes "every card has exactly one output shape", the clean
  split is `Resolve` (source → units) + `Read` (source → items), one more archetype.
- **One implementation.** `ReadWorker`, `FormulaSourceWorker`'s `units()` call and `ExpandWorker`'s
  `items()` call all go through the *same* `DataSource` library — the two routes differ deliberately
  and only in cursor semantics (`Read` owns a positional cursor and the handle; expression reads
  re-read on migrate, §5.4c) and that difference must be stated in both workers' KDoc (CC-21) so
  resume behaviour stays predictable.

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

Scaling without changing shape: the same `Read` card with `source:` pointing at a shared `sales`
object in a `DataSources` document (§6.4a); or `Read` with `emit: units` feeding `RunWorker`; or the
expert route `FormulaSourceWorker("sales.units()")` → `ExpandWorker` for parameterized resolution.
Same objects, same lane.

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

### 5.3 The transform side is 1:1 — the one real gap

`FormulaWorker.payload` **replaces** the payload: one message in, one message out. Nothing existing
turns one element into many.

The framework already permits it — `TransformWorker.onElement` may call `emit.send` any number of
times — but no worker exposes that to an expression. So the missing piece is **not** a `DataSplitWorker`;
it is the transform-side twin of `FormulaSourceWorker`: same expression scope, same strict-static
stream dispatch, one output message per element. Domain-free, and immediately useful for any
stream-valued expression:

```
ExpandWorker(code: "items(unit.part(\"main\"))")        // inferred: DataItems : Sequence<Any?>
   → item lane
```

**Domain-freeness vs flat emission, settled 2026-08-21b.** The DS5 elaboration called `ExpandWorker`
"domain-free" and, in the same breath, asserted that a `DataItems`-yielding expression "emits flat
messages" — which would have meant a class switch on a data-source type inside a general worker.
Resolve it on the **interface**, not the class: `ExpandWorker` emits `JobMessage.ofFlat` when the
stream it is draining exposes a non-null `flatHeader`, and `ofPayload` otherwise. `flatHeader` is an
ordinary interface member any third-party stream may expose, so CC-17 holds and the worker stays
domain-free for every other sequence.

**[open]** whether this is a new archetype or an `expand:` attribute on `FormulaWorker`. Against
folding it in: `FormulaWorker`'s two existing lanes are both cardinality-*preserving* and both
evaluate against the incoming message, so a third that changes cardinality raises ordering questions
(do the formula columns apply before expansion, or to each expanded element?) and needs different
migration state. Recommendation: separate archetype, with the shared expression plumbing lifted rather
than copied — it is the same concept as the source's dispatch and should read as one (CC-04, CC-12).

### 5.4 Three costs of reading inside an expression

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

### 5.5 The design-time schema trade-off — what the expression route costs

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
declarative `ReadWorker` (§5.2a) recovers it: its `payloadFlow` publishes `itemType(part)` plus the
pre-scan's **cached** columns (never IO on the walk), so the no-code path gets static columns and the
expression path gets the inferred payload type. Neither is assumed for free; both are stated.

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
  document as a **widening** escape hatch (it can only add names the predicate rejected) and empty its
  shipped `IntRange` entry. Whether to retire it entirely is a separate, smaller decision — **O17**.
- The visibility fix types the *unit*; it does **not** type a part's **items**. `items(part)` yields
  `Any?` regardless, because that is a schema question, not a Kotlin-inference one. Its answer is the
  **declared** `itemType(part)` on the SPI (§4) — notation-only, so the walk can read it with no IO —
  and, for a tabular source, the columns from `schema`. See §6.3 for where a source *gets* a
  declaration.

### 5.6 Scoping a unit's processing — three mechanisms

This is the "main dataset + reference data, processed as a unit" question.

First, the rule that makes the question well-posed **[decided]**: a multi-role unit flows **whole**.
No reader or framework piece splits it uniformly — there is no uniform way to — and making it
consumable item-by-item is custom logic (an expression in `ExpandWorker` / `FormulaWorker`, or a
third-party transform) that turns the unit into whatever uniform type that pipeline wants. The
mechanisms below are about *where* that logic runs and what boundary it sees.

First, the weaker half, which **only** the expression route gives: **unit identity** rides every item
whenever the expression carries it there — the item type includes the unit's attributes, or a
downstream `FormulaWorker` adds them as columns. That is a library/expression concern, not a worker
step, and it is what J4's `groupBy: <column>` export consumes.

⚠ **Corrected 2026-08-21b:** this is not free, and `ReadWorker` does not provide it. Under
`emit: items` the reader emits `JobMessage.ofFlat(partHeader, record)` and the unit is gone; the
`flatView()` auto-flatten that §3.5 once leaned on applies only to a `Map` payload and never runs on a
flat message at all. So identity requires `emit: units` followed by an expression
(`ExpandWorker` / `FormulaWorker`), or the child-Logic idiom (b) where the unit arrives as the child's
declared parameter. **`groupBy` parity therefore depends on the expression route (DS5), not on the
reader.**

What identity does *not* give you is the unit **boundary**. A downstream worker can tell which unit an
item came from, but not that a unit has ended, without buffering or watching the attribute change.
Anything that must act **at** a boundary — close an output container, flush a per-unit aggregate —
needs one of these:

**(a) Fan-out the unit lane to role lanes.** Feed `main` and `reference` to separate expand workers,
so they become separate lanes.

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
`JobControl.host(instructions, unit)`; the child Job declares the unit as its parameter and holds the
expand workers, one per role, each reading `items(unit.part(…))` off that parameter.

- *Expressible today?* Yes, entirely — `JobControl.host`, `RunWorker`, typed `parameters` and
  declared `results` all landed in J2. No framework change.
- Unit scoping is *structural*, which is the whole point: the child run **is** the boundary, so
  aggregators reset, writers open per-unit paths, and the child's declared result is the unit's
  output (§7.1) — none of it inferred from a changing attribute column. Breakpoints, stepping and
  pause-on-error descend into the child for free.
- The two roles are two independent expand workers inside the child, so **no fan-out is needed** —
  the unit never becomes a lane that has to be forked.
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

### 6.1 Schema: two consumers, and only one of them is the walk

**The editor** is the primary consumer, and it is well served. It asks a detached action "what columns
does this part have?", gets the declaration or the pre-scan (`ColumnListingAction` / `ReportHeaderReader`
behind `DataSource.schema`), and offers dropdowns instead of free text. This subsumes today's
`JobUpstreamSchema`, which can only find columns by walking upstream for a live `SummaryServer` — i.e.
only *after* a run. Resolution order for an editor asking "what columns can I offer?":

1. live summary (a running `SummaryServer` upstream) — most accurate, run-scoped;
2. offline persisted summary (J4) — last run's actual columns;
3. **a declared schema** on the source (§6.3) — free, and the only option a source whose reading is
   expensive can offer;
4. **on-demand source pre-scan** (this design) — available with no run at all, but bounded (§6.2);
5. free text.

Columns are the *whole* design-time data surface: there is no row preview, deliberately (§9).

**The payload-type walk** is the consumer that does *not* get static columns, per §5.5: with reading
done inside an expression, `WorkerBase.payloadFlow` has no source object to interrogate and must not
perform IO anyway. What it does get — free, and arguably better — is the expression's **inferred
payload type**, exactly as `FormulaSourceWorker` publishes today. So:

| Lane | Static scope for downstream expressions |
|---|---|
| source yields typed items | the item type as receiver, members bare — full compile-time validation (⚠ needs §5.5a, or every such type flattens to `Any`) |
| source yields `Map`-ish / text items | statically unknown; `KotlinSyntaxValidator` syntax-only, as today's CSV lane |

The declarative reader is not bound by the "no source object to interrogate" limit above: it knows its
source statically and publishes `itemType(part)`, which is answerable from notation alone. That is the
third static route, and it costs the walk nothing (§5.5a).

Unknown must remain legal at every step; it already is, and this design does not make any lane *less*
known than it is today. It simply declines to promise the walk something it cannot deliver without
doing IO at define time.

### 6.2 Caching, and a bug to fix on the way

`ColumnListingAction` caches an extracted `HeaderListing` as `columns.csv` under a path keyed on
`(dataLocation, pluginCoordinate)` — **with no size or modification time in the key**. An edited file
therefore serves stale columns until the cache is cleared by hand. Any schema cache in this design
must key on `(ref.id, format, size, mtime)` where the source can supply size/mtime, and must degrade
to "don't cache" where it cannot.

Cost discipline matters here because `schema()` may be called on every notation revision: it must be
answerable from the cache or from a bounded read (a header row, a `LIMIT 0` query), never a full scan.
`ReportHeaderReader` already reads only as far as the header, so the file case is fine.

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

1. **It is the natural supply for `itemType(part)` (§5.5a).** A source declares a schema document
   nominally and answers `itemType` / `schema` from the declaration — no IO, so the payload-type walk
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
the source as a `DetachedAction` (§4).

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

### 6.5 The gap the UI question exposes: an expression cannot name an object

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
structural reference; `graphInstance` for the expression scope, which is what A already describes);
**`DataSourceResolver` = design time** (detached, `GraphInstanceCache` as today) **plus one fallback** —
a `DataRef` whose source object is not in this run's graph, which is the cross-boundary case of §4.3 (a
unit handed to a hosted child Job whose own `filterTransitive` does not reach the parent's source). There
the resolver maps `DataRef.source` — a durable `DataSourceId` (§3.3), not an `ObjectStableId` — to a
location and instantiates. One caveat to carry: a source class loaded from a plugin jar (§4.1) must be
visible to the expression compiler's classloader (`ClassLoaderUtils.dynamicParentClassLoader()`), the
same threading the format-plugin path already does.

Note what the declarative `ReadWorker` (§5.2a) means for this section: the *trivial* case never
touches expression scope at all — the worker receives its source by kzen-lib reference injection. A is
needed for the parameterized / expert route, which is exactly where it should be needed.

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
  FormulaSourceWorker(code: "datedFiles.units()")              -> unit lane   [existing worker]
      // `from` / `to` reach the source through DataScope.argument(name) — §4, never positionally
  RunWorker(instructions: PerDayJob)                           -> result lane (one DataRef per day)
  ResultSinkWorker(result: outputs, keep: all)

PerDayJob(parameters: unit: DataUnit; results: output: DataRef)
  ExpandWorker(code: "items(unit.part(\"main\"))")             -> item lane   [the one new worker]
  LookupWorker  <- ExpandWorker(code: "items(unit.part(\"reference\"))")
  FilterWorker / FormulaWorker …
  ExportWriterWorker(path: "out/${date}.csv")  -> yields DataRef
  ResultSinkWorker(result: output)
```

Note `ResultSinkWorker` keeps `first|last` today — collecting *all* per-unit refs into a list result
is **[open]** and may want a `keep: all` mode, or the outer Job may simply write them somewhere.

### 7.2 `ExecutionValue` lowering

`DataRef` / `DataPart` / `DataUnit` / `DataManifest` each need a canonical `ExecutionValue` form
because they cross REST (detached actions, run arguments), notation defaults, and the trace display.
With text-canonical attributes (§3.5) this is a mechanical map/list lowering with no bespoke codec —
the `DataLocation` precedent (a hand-written serializer whose wire form is the value object's own
canonical string) is the pattern to follow, and `asCollection` / `ofCollection` pairs already exist
throughout for the value-tree plane.

`DataRef.source` lowers as its `DataSourceId` string (§3.3), so the `ObjectStableId` `KSerializer` the
DS1 elaboration planned is **not needed** — one fewer serializer, and kzen-lib stays untouched for a
better reason than "we chose not to edit it".

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
that no longer runs. The **expression** route keeps the (i) caveat unchanged: `FormulaSourceWorker`
re-evaluates and skips the delivered prefix, so its expression must re-produce elements in a stable
order, and a directory walk is not pure. That is documented, not solved.

The resolved manifest should also be published — as worker progress and/or trace — so a run records
what it actually read. That is both an observability win and the reproducibility story for an ETL
port.

### 8.2 Cursors

This is the part the expression route gives up, and it should be said plainly. `CsvReaderWorker` and
`MultiFileReaderWorker` carry a real positional cursor — `(fileIndex, position)` — detaching the open
reader at `captureMigrationState` so the rebuilt instance resumes at the exact byte. An expression
that opens a stream exposes no such handle, so the 1:N transform can only carry an *element count* and
re-read the skipped prefix (§5.4c).

For a day's file that is a cheap re-read; for a very large unit it is not. That is one of the three
reasons the declarative `ReadWorker` (§5.2a) is in: it is the one place a positional cursor lives, so
the no-code path resumes exactly and only the expression path pays the re-read. For plugin-format
readers positional resume is out of reach either way (framers are stateful); J3 already records
restart-on-edit as the acceptable v1 for `PluginReaderWorker`, and `ReadWorker` over a plugin format
inherits that.

## 9. Report parity map

| Report capability | This design |
|---|---|
| Browse directory + filter | `FileDataSource`'s attribute editor over the existing `/file-listing` route (§6.4). ⚠ `filter` is a contains-all-words match on the file name, **not** a glob (§6.4) |
| Selected file list | resolved `DataManifest`, shown as a preview table in the source card (via the object's detached action) |
| Per-file format (`InputDataSpec.processorDefinitionCoordinate`) | `DataPart.format`, defaulted by the source (`actionDefaultFormat` logic) |
| Data type filter (`InputSelectionSpec.dataType`) | source-level constraint on which formats it offers |
| `groupBy` filename regex → `DataLocationGroup` | source-level attribute extraction → `DataUnit.attributes` |
| Grouped export | ⚠ **not free.** Unit attributes do not reach the item lane by themselves (§3.5, §5.6 as corrected): it takes `emit: units` + an expression, or the child-Logic idiom. So J4's `groupBy: <column>` depends on the **expression route**, not on the reader |
| **Header superset across files** (`DatasetInfo.headerSuperset`) | ⚠ **gap in v1.** `ReadWorker` **fails** on heterogeneous item schemas rather than merging them — deliberately, because the loss would otherwise be silent downstream (§5.2b). Superset normalization lands with the design-time schema work |
| Column listing (`ColumnListingAction`) | `DataSource.schema` — editor pre-scan (and a declaration where one exists, §6.3), plus `ReadWorker.payloadFlow` from its cache (§5.5, §6) |
| Encoding detection (`ReportUtils.encoding`) | `DataPart.encoding`, source-defaulted |
| Multi-file as one stream | `ReadWorker` (§5.2a) — one card; or `FormulaSourceWorker` (units) → `ExpandWorker` (items) when resolution is an expression |
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
`DataQuery`, `DataSource`, `DataItems`, `DataScope`, `DataSourceId` are all free today. `DataSource` is
close to Report's existing `FlatDataSource` — that one is the *byte-stream* seam and stays, so the KDoc
on each must say which is which (CC-21 reciprocal markers if they end up genuinely paired).

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
`data/schema/` (the vocabulary above), `data/model/` (the §3.2 types), `data/api/` (`DataSource` /
`DataScope` / `DataItems`), `data/file/` (the file-selection spec) — and the server side mirrors it at
`server/data/` (plumbing) and `server/objects/datasource/` (the source objects). **Not `paradigm/data/`**,
which an earlier draft proposed: `paradigm/` holds `{detached, flow, job, logic}`, i.e. *execution
paradigms*, and a value model is not one. `util/data/` (`DataLocation`, `DataLocationInfo`, `FilePath`)
stays put — it is location arithmetic used by everything including Report, and moving it buys the arc
nothing.

## 11. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| O1 | Is the 1:N expression transform a new archetype or an `expand:` attribute on `FormulaWorker` (§5.3) | New archetype — `FormulaWorker`'s lanes are cardinality-preserving; mixing in a cardinality-changing one muddies both ordering and migration state |
| O2 | `ResultSinkWorker` gaining `keep: all` so an outer Job can collect one ref per unit (§7.1) | Yes, but it is a separate small change; do not entangle it with the model |
| O3 | Whether a `DataSource` call may run at *definition* time (during the payload-type walk) | **No IO at definition time, ever.** The walk reads `itemType(part)` (notation-only) and the schema **cache**; `schema()` itself is never called from it (§5.5a, §6.1) |
| O4 | Whether a `DataRef` with `source == null` (a plain path) is a first-class case or a convenience conversion | First-class — it is the whole trivial case, it keeps `DataLocation` interop free, and §4.4 depends on it |
| O5 | Do units nest? (a unit whose part is itself a manifest — e.g. a month containing days) | No. Flatten at resolve time; nesting re-imports every problem §3.4 rejects |
| O6 | Widen the strict-static stream dispatch beyond `Iterable` (§5.4a) | **Decided 2026-08-21b: yes** — one `isStreamType` covering `Iterable \| Sequence \| Iterator`. Without it every lazy read silently becomes a single message |
| O7 | Resource ownership for an expression-opened stream (§5.4c) | `AutoCloseable`-aware expand worker + close-at-exhaustion; accept re-read on migrate — positional resume lives in `ReadWorker` |
| O8 | Where the file-selector UI binds (§6.4–6.5) | **Decided 2026-08-21: on the source object's own attributes**, as `FileDataSource`'s attribute editor. The parameter-default binding is withdrawn — it needed a self-resolving file-specific value type |
| O9 | How an expression reaches a notation object — objects-in-scope (A), parameter default (B), or stringly lookup (C) (§6.5) | **Decided 2026-08-21: A now**; B withdrawn; never C. **Amended 2026-08-21b:** the instances come from the run's `graphInstance`, **not** from `GraphInstanceCache` — the cache is design-time plus the cross-boundary fallback only |
| O10 | Can a source object nest **inline under `ReadWorker`'s `source` attribute** (§5.2a)? | **Demoted 2026-08-21b** from load-bearing to a refinement: the trivial case is three cards either way (§5.2a), and auto-bind plus an in-card source summary carries the ergonomics. Revisit only on evidence that the section split actually hurts |
| O11 | `ReadWorker` `emit: items \| units` knob vs a `Resolve` + `Read` split (§5.2a) | The knob — a source worker has no incoming lane, so O1's ordering / migration-state objection does not apply; split only if "one output shape per card" becomes a rule |
| O12 | Design-time resource lifetime for stateful sources (§4) | **Reduced 2026-08-21b.** Run time is solved by Contexts (the source borrows via `DataScope.contextValue`, disposal by declared `ResourceClosePolicy`). What remains is only the design-time *owner*: request-scoped open/close inside `DesignDataScope` for v1, the explicit `DesignSession` ([`2026-08-21_extension-points.md` §3](2026-08-21_extension-points.md)) later — **no source changes either way** |
| O13 | Argument passing into `units` — positional or named (§4) | **Named**, through `DataScope.argument(name)`. Positional was the DS8 elaboration's own "brittle, document it loudly"; a scope makes named cost nothing and work identically from a reader, a detached call and an expression |
| O14 | Is a **nullable structural reference** (`is: DataSource, nullable: true`) usable for `ReadWorker.source` (§5.2a, §6.5)? | Evidence says yes (`GraphCreator.constructionLevels`, `GraphDefinitionAttempt`, `ObjectDefinitionReference.isNullable`, `NotationMetadataReader`), but there is **no shipped precedent** — ports use `creator:`, `binds` / `contexts` use `by: Nominal`. **Spike it before building on it**; fallback is the resolver |
| O15 | Durable identity for `DataRef.source` (§3.3) | **A minted `DataSourceId` on the source object's notation.** `ObjectStableId` is session-scoped and dies on restart-after-rename, which is exactly the persisted-result case DS7 creates. Consider promoting the mechanism to kzen-lib once a second kind of object needs it |
| O16 | Is the final session a Kotlin `DatedPathDataSource` or `LogicDataSource` + a shipped example Script (§4.4, §12) | `LogicDataSource` — it proves the extension point instead of adding a ninth Kotlin class. Keep the Kotlin source in reserve if date iteration in a Script proves clumsy |
| O17 | Does the `ObjectRegistry` document survive the §5.5a visibility fix? | It loses its only consumer. Keep it as a **widening** escape hatch and empty its shipped `IntRange` entry; retiring it outright is a separate, smaller call |
| O18 | `DataFormat` document — rename to `DataSchema`, or delete (§6.3, §10) | Rename and consume it as the declared-schema supply for `itemType` / `schema`. Deleting is acceptable; leaving it orphaned under a colliding name is not |
| O19 | When does heterogeneous-schema **superset normalization** land (§5.2b, §9) | With the design-time schema work, since it needs the pre-scan. Until then `ReadWorker` fails loudly — never silently, because both `SummaryWorker` and `CsvWriterWorker` lose data quietly |

## 12. Suggested build order

Sequenced so each step is independently useful and nothing is built before its consumer exists.
**Revised 2026-08-21b**; the elaborations in `docs/plans/next/DS*` are the execution layer and follow
this, not the previous ordering.

0. **Schema vocabulary move** (new, mechanical). `HeaderListing` / `HeaderLabel` / `HeaderLabelMap`
   out of Report's document package (§10). Import-only, no behaviour, and it must come **first** or the
   model types cement the wrong import.
1. **Model + lowering.** The §3.2 value types in kzen-auto-common — `DataRef.source` a minted
   `DataSourceId` (§3.3), `DataItems` a constrain-once `Sequence` (§4) — with notation and
   `ExecutionValue` round-trips and digests, plus `DataLocation` ⇄ `DataRef` conversion and the
   construction helpers §4.4 needs. No worker depends on it yet; the tests are the exercise.
1b. **Inference visibility fix** (new, small). Replace `visibleBuiltins` + the registry scan with the
   public-and-nameable predicate, and `isIterable` with `isStreamType` (§5.5a, O6). Everything typed
   downstream depends on it, and it is a standing bug independent of this arc — the hardcoded `IntRange`
   is the tell. May ride inside step 1.
2. **`DataSource` + `DataScope` + `DataItems` + `FileDataSource`**, with `units` / `items` /
   `schema` / `itemType`, and the object doubling as a `DetachedAction` for browse / resolve / schema
   (§4). Wire it to the existing `FileListingAction` (splitting out a blocking core, §4) and
   `FlatDataSource` rather than reimplementing either; move that plumbing to its new home (§10).
   `DataSources` document + graph-wide discovery (§6.4a). **Spike O14 first.**
3. **`ReadWorker`** (§5.2a) — source-generic, `source:` a nullable structural reference,
   `emit: items | units`, resolved manifest carried across migration with a positional cursor,
   `payloadFlow` from `itemType` + the pre-scan cache, heterogeneous schemas failing loudly (§5.2b).
   A/B against `CsvReaderWorker` / `MultiFileReaderWorker` over the same files — identical message
   streams; the old readers stay until that is green. **This plus step 4 is the trivial case: three
   cards, no code.**
4. **The editing surface** (§6.4): `MultiFileInputEditor` rewritten as `FileDataSource`'s attribute
   editor (typed selection, `editor:`-bound, ideally per type via `meta.ref`); generic source-card
   chrome (resolve preview, columns) over the detached protocol; the Job `sources:` section and the
   `DataSources` document; auto-bind and the in-card source summary (§5.2a). `editor:` keys land with
   their registrations (§6.4). Steps 3 and 4 are one deliverable in two sessions — neither is
   demonstrable alone.
5. **The 1:N expression transform** (`ExpandWorker`, per O1) with its prerequisites: the transform emit
   cadence (§5.4b) and `AutoCloseable` awareness (O7) — and **objects in expression scope** (A, §6.5),
   built over the run's `graphInstance`. This is the parameterized / expert route; nothing in 0–4 waits
   on it. It is also what `groupBy` parity depends on (§9).
6. **`schema()` + the design-time route** (§6.1–6.2), including the cache-key fix, the declared-schema
   supply (§6.3) and superset normalization (O19). Editor dropdowns and pickers; `ReadWorker.payloadFlow`
   reads the same cache.
7. **The writer yielding its ref** (§7). This closes the composition loop; the acceptance test is the
   §7.1 worked shape running end to end.
8. **Role fan-out + `LookupWorker`** (§5.6a, §5.7) — the in-Job multi-role idiom. Worth waiting
   for a real pipeline that needs it, and cheaper after J6.
9. **`LogicDataSource` + the dated example** (§4.4, O16) — the first parameterized source, the one the
   ETL port needs, and the proof that a user can author a source. The first *stateful* source after it
   is what exercises the Context borrow (§4) and, eventually, O12.

Steps 0–4 are the "capture the idea of a data source, generally and ergonomically" ask, with 5–6
completing the design-time and expert surfaces; 7–9 are the ETL port. Third-party sources and their UI
ride on the general extension mechanism in
[`2026-08-21_extension-points.md`](2026-08-21_extension-points.md), not on anything in this list.

## 13. Second-pass review (2026-08-21b) — what changed and why

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
