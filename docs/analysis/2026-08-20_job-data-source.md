# Job data sources — describing, resolving and reading data

> **Status: design exploration.** Written 2026-08-20 from a design conversation; the deliverable
> asked for was *the design*, not code. Nothing here is scheduled — the live plan for the Job
> flavour is [`../plans/2026-07-25_job-improvements.md`](../plans/2026-07-25_job-improvements.md)
> (phases J3/J4 are the Report-subsumption spine this feeds).
>
> Decisions are marked **[decided]** (settled in the conversation, with the argument recorded so it
> is not re-litigated) or **[open]** (a real fork still to call, with a recommendation). Per CC-20
> no line numbers are cited; anchors are class/file names.

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
why that is a separate arc); Report's retirement sequence (J4 owns it); fan-out topology (J6).

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
| Job readers | `CsvReaderWorker`, `MultiFileReaderWorker`, `MultiFileInputEditor` | Replace (§2.2) |
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
selection is not a worker at all: it is a *source object* (§4) whose resolve and read are ordinary
expression calls from workers that already exist (§5).

## 3. The model

### 3.1 The four concerns to keep apart

| Concern | Question it answers | Lives in |
|---|---|---|
| **Query** | what do I want? | `DataQuery` — config, may reference run parameters |
| **Resolve** | what does that actually name, right now? | `DataSource.units(…)` → `Iterable<DataUnit>` |
| **Describe** | what shape is it? | `DataSource.schema(part)` → `HeaderListing` — editor-facing (§6.1) |
| **Open** | give me the rows | `DataSource.rows(part)` — a LAZY `Iterable`, called from an expression |

Report fuses query+resolve into `FileListingAction` (edit time only) and describe into a separate
action with its own cache. Splitting them is what makes parameterized resolution and pluggable
non-file sources possible at all.

### 3.2 Value types

```kotlin
// A reference minted BY a source and meaningful only TO that source. [decided]
data class DataRef(
    val source: ObjectLocation?,               // the DataSource object that owns it; null = ambient/plain path
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
- `source` is an `ObjectLocation`, which is a project-global address, so a ref carried across a
  Logic boundary can still be resolved back to the object that can open it.
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
`ColumnValue` converts at expression time. A `Map`-shaped payload also already auto-flattens to
keyed columns in `JobMessage.flatView()`, so unit attributes become *columns* for free, which is how
grouped export (J4) falls out without a special case.

Against: an expression that wants `unit.date` as a real date has to parse. That is the same cost
every flat column already pays, so it is not a new class of problem. If typed attributes are ever
justified, they arrive with the column-typing arc (§6.3), not before.

## 4. `DataSource` is an object with a callable API, not a Worker **[decided]**

```kotlin
interface DataSource {
    /** Resolve the source's configured query into concrete units. Called from an expression, and by the editor. */
    suspend fun units(vararg arguments: Any?): Iterable<DataUnit>

    /** The columns a part would yield, where knowable without reading it all. Null = not statically knowable. */
    suspend fun schema(part: DataPart): HeaderListing?

    /** Open a part and read it as a LAZY Iterable of rows — the expression-facing read (see §5.4a on Sequence). */
    fun rows(part: DataPart): Iterable<Any?>
}
```

A Worker exists only during a run, and this is needed in **two** contexts:

1. **Design time** — the editor asks "what does this query resolve to?" and "what columns?" with no
   run in sight, over a detached action (Report does exactly this today with `FileListingAction` /
   `ColumnListingAction`; J3 already plans to make them flavour-neutral).
2. **Run time** — as a **library called from expressions**: `Sales.units(from, to)` in a
   `FormulaSourceWorker`, `rows(part)` in the 1:N transform (§5.3).

Note what (2) means: there is no data-specific worker, no data-specific port, and no data-specific
notation shape. The source object supplies *configuration* (which directory, which pattern, which
connection) and *behaviour* (resolve, describe, read); the wiring is ordinary expressions over
ordinary lanes.

Being a notation object is still the customization seam and is still worth the object-ness: a
third-party source is another archetype in the graph, discovered through the object registry and
classified **by capability, never by class name** (CC-17) — the `JobServeCapability` /
`JobSignatureCapability` pattern. It also gives the editor something to bind a browse/preview UI to,
which a bare function in an expression would not.

**Definition time is deliberately absent from that list.** An earlier draft had `payloadFlow` calling
`schema()` to publish `flatColumns`; that would mean IO during the payload-type walk, which runs on
every notation revision (O3 says never). §5.5 records what is lost and what replaces it.

### 4.1 Two orthogonal extension axes, kept orthogonal

| Axis | Question | Seam | Examples |
|---|---|---|---|
| **Source** | where does the data live, and what does a query name? | `DataSource` archetype | directory glob, dated path pattern, HTTP, S3, JDBC |
| **Format** | how are those bytes parsed into records? | existing `ReportDefiner` plugin SPI, keyed by `PluginCoordinate` | CSV, TSV, fixed-width, a third-party binary format |

Report already separates these and must keep doing so: a dated-path source over a third-party format
should require no new code in either. `DataPart.format` is the join between the axes, resolved by the
source's default when the user does not pin one.

### 4.2 A `DataRef` carries its own source, so there is no `ParameterDataSource`

An earlier draft wanted a `ParameterDataSource` — a source whose "query" is a Job parameter holding a
`DataUnit` — so a child Job could read the unit its caller passed. With reading done from an
expression, that whole construct disappears: the child's parameter *is* the `DataUnit`, and each
`DataPart` names its own owning source through `DataRef.source` (§3.2). So the child simply writes
`rows(unit.parts("main"))`, and the free function dispatches on the ref's source.

This is where the opaque, source-relative `DataRef` (§3.3) stops being a display concern and starts
paying operationally: a unit handed across a Logic boundary is **self-opening**. Nothing at the
receiving end needs to be configured with where the data came from.

## 5. Workers — what already exists, and the one real gap

> **Revised.** An earlier draft proposed a `DataSourceWorker` and a `DataSplitWorker`. Both were
> wrong: the first already exists, and the second should be a domain-free expression worker rather
> than anything that knows about data sources. **No new data-specific worker is warranted.** What
> follows is what the existing workers already cover, the one capability genuinely missing, and the
> three costs of getting it by expression.

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
FormulaSourceWorker(code: "Sales.units(from, to)")     // inferred: Iterable<DataUnit>
   → unit lane, payloadType = DataUnit, known statically, no new code
```

Resolution is a function call in an expression, so a query needs no worker, no port, and no bespoke
notation shape. It even resumes across a live edit: the source carries `nextIndex` and skips the
already-delivered prefix, guarded on `code` equality.

Downstream, units are ordinary typed payloads — `FilterWorker` can drop units before anything is
opened, `FormulaWorker` can re-type them — with no framework notion of "unit" anywhere.

### 5.3 The transform side is 1:1 — the one real gap

`FormulaWorker.payload` **replaces** the payload: one message in, one message out. Nothing existing
turns one element into many.

The framework already permits it — `TransformWorker.onElement` may call `emit.send` any number of
times — but no worker exposes that to an expression. So the missing piece is **not** a `DataSplitWorker`;
it is the transform-side twin of `FormulaSourceWorker`: same expression scope, same strict-static
`Iterable` dispatch, one output message per element. Domain-free, and immediately useful for any
Iterable-valued expression:

```
ExpandWorker(code: "unit.parts(\"main\").rows()")       // inferred: Iterable<Row>
   → row lane, payloadType = Row
```

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
`isSubclassOf(Iterable::class)`, and `kotlin.sequences.Sequence` does not implement it —
`visibleBuiltins` does not list it either. So a lazy `rows(): Sequence<Row>` classifies as
*single-emission*: one message holding the Sequence object, element type lost. Since laziness is
mandatory here (a unit may be gigabytes), either the source returns a lazy custom `Iterable` — works
today, no change — or `isIterable` / `iterableElementType` / `visibleBuiltins` widen to cover
`Sequence`. **Recommend widening:** it is small, entirely general, and `FormulaSourceWorker` gains
identically.

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
with three honest options: (i) accept the re-read and have the iterable close itself at exhaustion;
(ii) make the expand worker `AutoCloseable`-aware — close the current iterable in `onClose` if it is
one; (iii) keep a declarative reader worker for the file case where positional resume matters.
Recommend (ii) plus (i): a few lines, domain-free, and it makes *any* resource-holding iterable safe.

### 5.5 The design-time schema trade-off — what the expression route costs

This is the real price, and it is worth naming plainly.

A declarative reader worker knows its source object statically, so `payloadFlow` could publish the
file's columns as `WorkerLane.flatColumns` and every downstream expression would compile against them.
An expression-driven expand cannot: the columns come from a call the walk must not make (O3 — no IO at
definition time).

What survives is the **payload type**, inferred by the compiler exactly as `FormulaSourceWorker` does
today. So the static story shifts from *text columns* to *typed rows* — and that is the half kzen
supports best: `FormulaWorker` already puts the inferred payload type in scope as the receiver, with
members bare. A source yielding typed rows gives *better* validation than a text-column CSV lane ever
did; a source yielding text rows leaves the lane statically unknown, which is exactly where today's
CSV lane already sits (`KotlinSyntaxValidator`, syntax-only).

Consequence for §6: design-time schema serves the **editor** (column dropdowns, pickers, resolved
previews) via the detached pre-scan, not the payload-type walk. That is a genuine reduction from what
§6 first claimed. It is recoverable — a declarative reader worker can be added *beside* the generic
expand later — but it should not be assumed for free.

### 5.6 Scoping a unit's processing — three mechanisms

This is the "main dataset + reference data, processed as a unit" question.

First, the weaker half, which the expression route gets for free: **unit identity** rides every row
whenever the expression carries it there — the row type includes the unit's attributes, or a
downstream `FormulaWorker` adds them as columns. That is a library/expression concern now, not a
worker step, and it is what J4's `groupBy: <column>` export consumes.

What identity does *not* give you is the unit **boundary**. A downstream worker can tell which unit a
row came from, but not that a unit has ended, without buffering or watching the attribute change.
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
expand workers, one per role, each reading `rows(unit.parts(…))` off that parameter.

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
  already gets the weaker form (group **by column value**) for free once unit attributes are stamped
  as columns (§3.5), this is not yet paying for itself.

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
does this part have?", gets the pre-scan (`ColumnListingAction` / `ReportHeaderReader` behind
`DataSource.schema`), and offers dropdowns instead of free text. This subsumes today's
`JobUpstreamSchema`, which can only find columns by walking upstream for a live `SummaryServer` — i.e.
only *after* a run. Resolution order for an editor asking "what columns can I offer?":

1. live summary (a running `SummaryServer` upstream) — most accurate, run-scoped;
2. offline persisted summary (J4) — last run's actual columns;
3. **on-demand source pre-scan** (this design) — available with no run at all;
4. free text.

**The payload-type walk** is the consumer that does *not* get static columns, per §5.5: with reading
done inside an expression, `WorkerBase.payloadFlow` has no source object to interrogate and must not
perform IO anyway. What it does get — free, and arguably better — is the expression's **inferred
payload type**, exactly as `FormulaSourceWorker` publishes today. So:

| Lane | Static scope for downstream expressions |
|---|---|
| source yields typed rows | the row type as receiver, members bare — full compile-time validation |
| source yields `Map`-ish / text rows | statically unknown; `KotlinSyntaxValidator` syntax-only, as today's CSV lane |

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

### 6.3 Column types — deliberately excluded

Real ETL wants typed columns. But `HeaderListing`, `FlatFileRecord`, `ColumnValue` and
`WorkerLane.flatColumns` are text-canonical end to end, with conversion at expression time. Typing
that is its own arc with a wide blast radius, and doing it inside this change would double the risk
of both. `DataSource.schema` returning `HeaderListing` today can widen to a typed schema later
without any change to the model in §3.

### 6.4 Where the file-selector UI lives — no new extension mechanism needed

The browse UI is an ordinary **attribute editor**. `AttributeWrapperLookup` reads an attribute's
`editor:` metadata key, which names a wrapper object; `AttributeEditorManager` resolves that name
against its autowired `List<AttributeEditor>` and falls back to `DefaultAttributeEditor`. That string
contract is documented in the codebase as *the* open-set third-party-extension seam, and
`MultiFileInputEditor` is already bound through it — so the implementation largely exists. What it
needs is to write a typed selection spec instead of a raw `List<String>` (§2.2).

Better still, the binding can be **per type rather than per attribute**: a type-level `meta.ref` map
propagates the editor key to every attribute declared `is: <that type>`
(`NotationMetadataReader.resolveMetadataRef` — the shipped precedent is `ResourceClosePolicy` handing
`SelectValuesEditor` to every `closePolicy` attribute). Declare the editor once on the selection spec
type and every attribute of that type, in any archetype, first- or third-party, gets the browser.

**`Custom` is not the mechanism, but it may be the home.** A Custom document holds user-defined objects
built from `Prototype` archetypes, with an `exports` list that makes them referenceable from other
documents and `ObjectTag`s for discovery — a plausible place for a project's shared `DataSource`
objects to live. But it is a *container* for objects, not an editor-extension seam. The extension seam
is `editor:`, above.

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
| **A** | **Objects in expression scope.** A worker declares the objects it uses; the compiler generates bare typed accessors for them exactly as `generateParameterAccessors` does for parameters, backed by a second injected list. | one new scope kind in `CalculatedColumnEval` + a `uses` convention | The general mechanism — useful well beyond data sources (Script's `StepExpressionCompiler` too) |
| **B** | **The selection is a parameter default.** Declare `parameters: { input: DataQuery }` and bind the browser to that declaration's `default` attribute by type (§6.4). The expression just reads `input` — already in scope, no compiler change. | `ParameterDefaultDefiner` must coerce structured notation, not only 5 scalars | **Recommended home for the UI** |
| **C** | **Stringly global lookup** — `source("Sales").units(…)` via an injected `@Service`. | least code | Rejected: no static type, no editor binding, no rename safety |

**Recommendation: B for the UI, A as the general mechanism.** B is not a workaround — it is where the
semantics already point. A file selection *is* an input to the Job, so putting it on a parameter
declaration means one Job can be run interactively against a browsed selection **and** invoked by a
caller that overrides the argument (§7.1), with no second configuration surface and no divergence
between the two paths. The parameters branch already renders in the Job editor, so the browser appears
exactly where a reader would look for it.

Both A and B rest on the same primitive: **run-time resolution of an `ObjectLocation` to an object
instance, reachable from expression context.** That is the one genuinely new capability this whole
design needs, and `JobControl.host`'s existing Logic resolution is the precedent to follow.

## 7. The Logic boundary

### 7.1 Data flows out as well as in

"Invoke a Job for a specific input file, then take the output file" needs **both** directions:

- **In:** the Job declares a `parameters` entry typed as `DataUnit` (or `DataRef`). `JobControl.parameter`
  returns it, and each part is self-opening through `DataRef.source` (§4.2) — no configuration at the
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
  FormulaSourceWorker(code: "DatedFiles.units(from, to)")      -> unit lane   [existing worker]
  RunWorker(instructions: PerDayJob)                           -> result lane (one DataRef per day)
  ResultSinkWorker(result: outputs, keep: all)

PerDayJob(parameters: unit: DataUnit; results: output: DataRef)
  ExpandWorker(code: "rows(unit.parts(\"main\"))")             -> row lane    [the one new worker]
  LookupWorker  <- ExpandWorker(code: "rows(unit.parts(\"reference\"))")
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

## 8. Run-time concerns

### 8.1 Resolve once, then treat the manifest as run state

The moment resolution becomes dynamic, resolving on demand becomes a correctness hazard: two reads of
a directory can differ mid-run. `FormulaSourceWorker` evaluates its expression **once** per run, which
gives this for free — but only for the first evaluation. Its resume works by *re-evaluating* and
skipping the delivered prefix, so a mid-run migration re-resolves, and a directory that changed
underneath yields a different stream than the one already partly delivered.

`MultiFileReaderWorker` guards the equivalent hazard by comparing its `paths` attribute on
`loadMigrationState`, which is coherent only because the set is frozen config; `FormulaSourceWorker`
guards on `code` equality, which does not see a changed directory at all. **[open]** — the honest
options are (i) accept re-resolution and document it (the expression must be effectively pure, which
a directory walk is not), or (ii) let the source worker carry the resolved manifest's digest and
restart rather than silently resume when it differs. Recommend (ii); this is why `DataManifest` is
`Digestible`.

The resolved manifest should also be published — as worker progress and/or trace — so a run records
what it actually read. That is both an observability win and the reproducibility story for an ETL
port.

### 8.2 Cursors

This is the part the expression route gives up, and it should be said plainly. `CsvReaderWorker` and
`MultiFileReaderWorker` carry a real positional cursor — `(fileIndex, position)` — detaching the open
reader at `captureMigrationState` so the rebuilt instance resumes at the exact byte. An expression
that opens a stream exposes no such handle, so the 1:N transform can only carry an *element count* and
re-read the skipped prefix (§5.4c).

For a day's file that is a cheap re-read; for a very large unit it is not. If positional resume turns
out to matter, that is the case for keeping a declarative reader worker beside the generic expand
(§5.4c option iii) — decided by evidence, not upfront. For plugin-format readers positional resume is
out of reach either way (framers are stateful); J3 already records restart-on-edit as the acceptable
v1 for `PluginReaderWorker`.

## 9. Report parity map

| Report capability | This design |
|---|---|
| Browse directory + filter | `DataSource` implementation over the existing `/file-listing` route |
| Selected file list | resolved `DataManifest`, shown as a preview table in the source card |
| Per-file format (`InputDataSpec.processorDefinitionCoordinate`) | `DataPart.format`, defaulted by the source (`actionDefaultFormat` logic) |
| Data type filter (`InputSelectionSpec.dataType`) | source-level constraint on which formats it offers |
| `groupBy` filename regex → `DataLocationGroup` | source-level attribute extraction → `DataUnit.attributes` |
| Grouped export | attributes stamped as columns → J4's `groupBy: <column>` on the writer |
| Column listing (`ColumnListingAction`) | `DataSource.schema` feeding `WorkerLane.flatColumns` (§6) |
| Encoding detection (`ReportUtils.encoding`) | `DataPart.encoding`, source-defaulted |
| Multi-file as one stream | `FormulaSourceWorker` (units) → `ExpandWorker` (rows) — one existing worker plus one generic new one |
| — (no Report equivalent) | parameterized resolution, multi-part units, non-file sources, cross-Job composition |

## 10. Naming **[decided]**

Avoid `Resource*`. The word is taken twice in this codebase already — notation resources
(`NotationResourceCommands`, the binary assets in a project) and run resources
(`openResource`/`releaseResource`, now largely superseded by Contexts) — and this is neither.

`Data*` aligns with what already exists (`DataLocation`, `DataLocationInfo`, `DataFramer`,
`DataInputEvent`, `DataEncodingSpec`, `DatasetInfo`) and reads correctly for a DB or API source later.
Collision check against current names: `DataRef`, `DataPart`, `DataUnit`, `DataManifest`, `DataRole`,
`DataQuery`, `DataSource` are all free today. `DataSource` is close to Report's existing
`FlatDataSource` — that one is the *byte-stream* seam and stays, so the KDoc on each must say which is
which (CC-21 reciprocal markers if they end up genuinely paired).

## 11. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| O1 | Is the 1:N expression transform a new archetype or an `expand:` attribute on `FormulaWorker` (§5.3) | New archetype — `FormulaWorker`'s lanes are cardinality-preserving; mixing in a cardinality-changing one muddies both ordering and migration state |
| O2 | `ResultSinkWorker` gaining `keep: all` so an outer Job can collect one ref per unit (§7.1) | Yes, but it is a separate small change; do not entangle it with the model |
| O3 | Whether a `DataSource` call may run at *definition* time (during the payload-type walk) | **No IO at definition time, ever.** The editor resolves on demand and caches; the walk sees only compiler-inferred types (§5.5, §6.1) |
| O4 | Whether a `DataRef` with `source == null` (a plain path) is a first-class case or a convenience conversion | First-class — it is the whole trivial case, and it keeps `DataLocation` interop free |
| O5 | Do units nest? (a unit whose part is itself a manifest — e.g. a month containing days) | No. Flatten at resolve time; nesting re-imports every problem §3.4 rejects |
| O6 | Widen the strict-static stream dispatch to cover `kotlin.sequences.Sequence` (§5.4a) | Yes — small, general, and `FormulaSourceWorker` benefits identically. Without it every lazy read silently becomes a single message |
| O7 | Resource ownership for an expression-opened stream (§5.4c) | `AutoCloseable`-aware expand worker + close-at-exhaustion; accept re-read on migrate |
| O8 | Where the file-selector UI binds (§6.5) | On a **parameter declaration's `default`**, typed by the selection spec — run-interactively and invoked-by-caller then share one surface |
| O9 | How an expression reaches a notation object — objects-in-scope (A), parameter default (B), or stringly lookup (C) (§6.5) | B now, A when a second use case appears; never C. Both need run-time `ObjectLocation` → instance resolution from expression context |

## 12. Suggested build order

Sequenced so each step is independently useful and nothing is built before its consumer exists.

1. **Model + lowering.** The §3.2 value types in kzen-auto-common, with notation and `ExecutionValue`
   round-trips and digests, plus `DataLocation` ⇄ `DataRef` conversion. No worker depends on it yet;
   the tests are the exercise.
2. **`DataSource` SPI + the file-glob implementation**, with `units` and `rows` only. Wire it to the
   existing `FileListingAction` and `FlatDataSource` rather than reimplementing either. At this point
   `FormulaSourceWorker` can already emit a unit lane with **no new worker code at all** — that is the
   first thing to demonstrate.
3. **The 1:N expression transform** (`ExpandWorker`, per O1) with its three prerequisites: the
   transform emit cadence (§5.4b), `Sequence` support (O6), and `AutoCloseable` awareness (O7). A/B
   against `MultiFileReaderWorker` over the same files — identical message streams; `MultiFileReaderWorker`
   stays until that is green.
4. **The editing surface** (§6.4, §6.5): structured parameter defaults in `ParameterDefaultDefiner`, the
   selection spec type with its `editor:` binding, and `MultiFileInputEditor` rewritten to write that spec
   instead of a raw `List<String>`. **This is the step that makes the whole thing usable rather than
   expert-only**, and it is independent of steps 2–3 — it can be pulled forward.
5. **`schema()` + the design-time route** (§6.1–6.2), including the cache-key fix. Editor dropdowns and
   pickers — note this no longer feeds the payload-type walk (§5.5).
6. **The writer yielding its ref** (§7). This closes the composition loop; the acceptance test is the
   §7.1 worked shape running end to end.
7. **Role fan-out + `LookupWorker`** (§5.6a, §5.7) — the in-Job multi-role idiom. Worth waiting
   for a real pipeline that needs it, and cheaper after J6.
8. **Dated-path source** — the first source that proves the parameterized case, and the one the ETL
   port actually needs.

Steps 1–5 are the "capture the idea of a data source, generally and ergonomically" ask; 6–8 are the
ETL port.
