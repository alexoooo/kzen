# Job data sources — Job execution and editing adapter

> **Status: adapter landed; shape correction pending — see §6.3 and §13.** This document owns Job-specific
> data-source execution, editing, composition and the complete DS0–DS8 chronological record. The reusable
> values, source/opener protocol, shape rules, lowering and package ownership live in
> [`2026-08-20_data-source-model.md`](2026-08-20_data-source-model.md). The Job flavour's other live plan is
> [`../plans/2026-07-25_job-improvements.md`](../plans/2026-07-25_job-improvements.md). Per CC-20 no line
> numbers are cited; anchors are class / file names.
>
> The independent 2026-08-23 review remains incorporated: model/SPI findings moved with the generic model;
> Worker, migration, writer and composition findings remain here. The review is not a third source of truth.
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
| Schema pre-scan | `ColumnListingAction` + `ReportHeaderReader`, cached as `columns.csv` | Keep; cache key needs work ([model §4.2](2026-08-20_data-source-model.md#42-fingerprinted-schema-cache)) |
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

## 3. Generic data-source foundation

The reusable model is specified in
[`2026-08-20_data-source-model.md`](2026-08-20_data-source-model.md):

- `DataManifest` is an ordered list of `DataUnit`s; a unit has presentation-ordered text attributes and
  semantically ordered, role-labelled `DataPart`s.
- `DataRef` is either plain/self-contained (`source == null`, every landed ref) or future provider-bound.
- `DataSource` resolves a point-in-time manifest; `DataOpener` describes and opens a concrete part.
- `DataShape` is an observation envelope around one recursive semantic `DataType`; definition walks use
  notation-only `staticShape`, while bounded inspection is an explicit runtime/detached operation. `Tabular`
  and `Payload` are rejected as shape categories because they describe Job's representation choices.

Job must consume those values without changing their meaning. Under `emit: units`, one `DataUnit` is one item.
Under `emit: items`, the reader opens selected `partsOf(role)` and emits each cursor item with its `DataType` and
backing hidden behind one `DataValue`/access contract. `attributes: columns` is the Job adapter's deliberate
record transformation: it prepends unit attributes to a compatible `Record` because the reader is the last
component that still holds both the unit and item. Attribute collisions and heterogeneous records are handled
by the reader policies in §5.

The landed code still represents this as `JobMessage(payload, flat)`, `WorkerLane(payloadType, flatColumns)` and
`DataShape.Tabular | Payload`. That is an implementation discrepancy, not an alternate supported model. The
structural-data runtime phase replaces all three together so the adapter has one authoritative item value and
type.

This boundary is important: the model does not know about `JobMessage`, `WorkerLane`, channels, migration,
cards or child runs. Those are the subject of the rest of this document.
## 4. Source boundary used by Job

The callable `DataSource` / `DataOpener` / `DataCursor` / `DataContext` contracts are owned by the
[data-source model](2026-08-20_data-source-model.md#3-source-and-opener-protocol). Job supplies one runtime
implementation of the context and two read operations:

1. `ReadWorker` resolves a referenced source once, carries the manifest, and opens its selected parts.
2. `ReadPartWorker` opens selected parts from a `DataUnit` already on a lane.

Both own cursor lifetime, counted blocking, cancellation and migration. Expressions see only materialized
values; they never resolve or open a source. `FileSourceWorker` and `LogicSourceWorker` are thin inline
delegates over the `ReadWorker` engine so the ordinary stage UI does not require a detached source card.

Pure `DataSource` notation objects remain the shareable/cross-document form. They are discovered graph-wide
by capability, resolved against the compiled run snapshot, and called by the generic `DataSourceActions`
dispatcher at detached boundaries. The inline Worker UI exposes the server-wide `fileFormats` catalogue but
not Resolve/Columns inspection chrome (§6).

A source borrows resources through its caller-owned context and remains side-effect free at construction.
Provider-bound sources and design-time stateful resource lifetime remain deferred to the model's first
stateful implementation.

### 4.1 Why source I/O never appears in expressions

Source resolution and reading are effects. An expression has no owner for a cursor, position, cancellation or
quiescence, and generated code must not hide file/database/API I/O. The two readers are the only data-specific
open operations; expression code receives `DataUnit`, record or payload values after materialization.

### 4.2 Two extension axes remain orthogonal

| Axis | Question | Seam |
|---|---|---|
| Source | Where does the data live, and what does the query name? | `DataSource` archetype |
| Format | How do file-shaped bytes become values? | Existing `ReportDefiner` / `DataFramer` plugin seam |

`DataPart.format` joins the axes. A dated path over a third-party format needs no special Job Worker or
expression behavior.

### 4.3 A `DataRef` is self-opening, so there is no `ParameterDataSource`

A source whose "query" is a Job parameter holding a `DataUnit` — so a child Job could read the unit its
caller passed — is unnecessary. The child's parameter *is* the `DataUnit`; `FormulaSourceWorker("unit")`
puts it on a lane as a single payload (a non-stream type emits once — existing behaviour); and
**`ReadPartWorker(role: "main")`** opens the part. The dispatch on `DataRef.source` lives in the reader's
`DataOpenerLookup` (§4) — plain ref → the shared file opener; sourced ref → its provider.

This is where the ref ([model §2.1](2026-08-20_data-source-model.md#21-dataref-is-opaque-and-plain-refs-are-first-class)) pays operationally: a unit handed across a Logic boundary is **self-opening**.
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
- **`attributes: ignore | columns`** ([model §2.3](2026-08-20_data-source-model.md#23-attributes-are-text-canonical)): under `columns`, every emitted flat record is widened with
  the unit's attributes as leading columns. This is the unit-identity-on-the-item-lane the reader alone
  can provide, and it is the `groupBy` parity J4 consumes. Attribute key sets differing across units are
  heterogeneous headers — §5.3 applies. An attribute name colliding with a part column fails naming both;
  it never shadows.
- **Static item flow.** Under `items`, publishes the source's notation-only `staticShape(role)` without IO.
  Its single `itemType` is the downstream type; no tabular/payload dispatch occurs. An unavailable declaration
  remains unavailable even when a previous click or run populated `SchemaCache`; the validation walk never reads
  runtime cache state. Under `units`, the item type is nominal `DataUnit`. Nothing is resolved at walk time, so
  no call may take a `DataPart`. The landed `payloadFlow` projection into `flatColumns` versus `payloadType` is
  part of the pending `WorkerLane` correction, not a contract to preserve.
- **Cursor.** This is the one place a positional cursor lives — `(unitIndex, partIndex, itemIndex)` with
  the open `DataCursor` detached across a migration, exactly `CsvReaderWorker`'s pattern: the worker calls
  `control.runBlockingIo { cursor.next() }` per item, so the resumed worker drives the carried handle with
  its *new* control (§4). The resolved manifest is **carried** across the migration and never re-resolved,
  and adoption is guarded on the source's definition digest plus this worker's own config — see §8.1.
- **Mode knob vs two workers** — **O11**. A mode knob changes the card's output cardinality. That
  objection is weak here: a source worker has no incoming lane, so there is no ordering question and no
  migration state to split; only the published item type differs, which the static type flow handles
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
as `ReadWorker` (§5.2 "one implementation"). The landed implementation emits `ofFlat` / `ofPayload` by
`cursor.shape`; the corrected contract emits one typed `DataValue`, independent of its backing. It is
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
not depend on it ([model §2.3](2026-08-20_data-source-model.md#23-attributes-are-text-canonical)). Build it on demand, as a plain stream expander with **no** `flatHeader` probing
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
not because someone listed it; every first-party type including the [model §2 value types](2026-08-20_data-source-model.md#2-value-model) works; a class from a
dynamically loaded plugin jar ([model §3.4](2026-08-20_data-source-model.md#34-notation-objects-and-authored-sources)) works with no registration; and an `internal` / synthetic / local
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
record with the unit's attributes as leading columns ([model §2.3](2026-08-20_data-source-model.md#23-attributes-are-text-canonical)). That is what J4's `groupBy: <column>` export
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

## 6. Job design-time and editing surface

### 6.1 Static type flow

The generic distinction between notation-only `DataSource.staticShape(role)` and bounded
`DataOpener.inspectShape(context, part)` is specified by the
[data-source model](2026-08-20_data-source-model.md#4-shape-and-schema). Job consumes it as follows:

| Lane | Static scope for downstream expressions |
|---|---|
| `emit: units` | observed nominal `DataUnit` item type |
| declared or otherwise observed source shape | its one recursive `itemType`, including record fields and nominal leaves |
| no declaration, including a directory walk | unavailable static shape; syntax-only validation |
| explicitly dynamic declaration | observed `Dynamic`; executable but members are not statically known |
| `ReadPartWorker` output | unavailable statically because the incoming unit does not identify a source |

No definition walk resolves a source, inspects an opener, reads `SchemaCache`, or touches the filesystem.
`schemaMode: strict | superset` is a reader contract: `strict` rejects drift; default `superset` pre-inspects
selected parts, builds an ordered union and projects absent cells to `<missing>` before downstream Workers can
silently lose columns.

### 6.2 Explicit inspection is implemented but not reachable from inline Workers

`DataSourceActions`, `DataSourceResolveStore`, `DataSourceShapeStore` and the inspected-source branch in
`JobUpstreamSchema` can carry bounded source inspection to editor dropdowns. The corrected DS4 interaction
removed the detached source card, and inline File/Logic Worker cards expose no Resolve/Columns trigger. No
production UI currently invokes those stores.

The active provider order is therefore live `SummaryServer` first, the reserved offline transformed-lane slot
next, and free text when neither answers. A declared `DataSchema` still feeds server validation through
`staticShape`; restoring explicit pre-run inspection requires a channel-free description surface for inline
Workers rather than instantiating a Worker through `DataSourceActions`. Row preview remains deliberately absent.

### 6.3 Schema and cache ownership

`DataSchema`, `DataShape`, bounded inspection and the fingerprinted `SchemaCache` belong to the reusable model.
Job transforms the declared/observed `itemType` through the selected role, `attributes` mode and `schemaMode`
policy. A schema declares a typed `Record`; it is not reduced to a header by the model.

The landed implementation violates that rule in three coordinated places: `DataSchemaDocument.shape()` drops
field types, `DataShape` chooses `Tabular | Payload`, and Job projects those cases into parallel
`WorkerLane(payloadType, flatColumns)` / `JobMessage(payload, flat)` state. The structural-data plan removes the
whole split in one runtime change. None of those current representations is a compatibility requirement.

### 6.4 Where the file-selector UI lives — on ordinary attribute metadata

The browser is the `files` attribute editor shared by `FileDataSource` and `FileSourceWorker`.
`AttributeWrapperLookup`
reads an attribute's `editor:` metadata key, which names a wrapper object; `AttributeEditorManager`
resolves that name against its autowired `List<AttributeEditor>` and falls back to
`DefaultAttributeEditor`. That string contract is documented in the codebase as *the* open-set
extension seam, and `MultiFileInputEditor` is already bound through it — so the implementation
largely exists. What changes is *what it edits*: the ordered picked files and their nullable per-file format /
encoding overrides instead of a worker's raw `List<String>` ([model §2.2](2026-08-20_data-source-model.md#22-units-and-parts-are-ordered-self-describing-values)). The chooser's navigation state is separate
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
writer's yielded ref is a **plain path** (durable by construction, [model §2.1](2026-08-20_data-source-model.md#21-dataref-is-opaque-and-plain-refs-are-first-class)), and the caller that stores it is
the one who decides where. A results registry with retention and naming is optional and later.

### 7.2 Model lowering at the Logic boundary

Canonical `ExecutionValue` and wire forms belong to the
[data-source model](2026-08-20_data-source-model.md#51-canonical-lowering). Job uses those forms for run
arguments, detached requests and trace display. `ExecutionValue.ofArbitrary` does not discover domain
conversions inside a `TupleValue`, so any arbitrary result boundary must call `asExecutionValue()` explicitly.
The landed same-run child path remains in-process and therefore does not invent a persisted result API.

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
has no counterpart. With the fingerprint stamped into each ref ([model §4.2](2026-08-20_data-source-model.md#42-fingerprinted-schema-cache)), that digest also says whether the
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
| Grouped export | `attributes: columns` on the reader ([model §2.3](2026-08-20_data-source-model.md#23-attributes-are-text-canonical), §5.6): unit attributes become leading columns, which is what J4's `groupBy: <column>` consumes. The reader side landed in **DS3** |
| **Header superset across files** (`DatasetInfo.headerSuperset`) | `schemaMode: superset` (the default) pre-inspects selected parts, builds an ordered union and materializes absent cells as `<missing>`; `strict` retains exact-shape rejection (§5.3, O19) |
| Column listing (`ColumnListingAction`) | `FileDataOpener.inspectShape` provides bounded detached inspection and `staticShape` provides declarations; `ReadWorker.payloadFlow` uses declarations only. The corrected inline Worker UI has no inspection trigger (§6.1) |
| Encoding detection (`ReportUtils.encoding`) | `DataPart.encoding`, source-defaulted at resolve, opener-inferred when null |
| Multi-file as one stream | `ReadWorker` (§5.2) — one card, any source |
| Row-level data preview | ⚠ **deliberately absent.** The design-time contract stops at manifest resolution and bounded-or-declared columns; the corrected inline Worker UI currently exposes neither pre-run operation. "Read me ten rows" assumes rows are meaningful and cheap to obtain, which does not hold for a source backed by a full pipeline (§6.1–6.2) |
| — (no Report equivalent) | parameterized resolution, multi-part units, non-file sources, cross-Job composition |

**Not in scope, and deliberately so.** There is no Report → Job conversion path, and none is planned:
"supersede" here means a Job can express what a Report expressed, not that an existing Report document
migrates itself. Report's own retirement stays J4's.

## 10. Job adapter naming and packages

The generic vocabulary and package layout are owned by the
[data-source model](2026-08-20_data-source-model.md#6-naming-and-packages). Job adds only adapter names:

- `ReadWorker` resolves a referenced `DataSource`; `ReadPartWorker` opens parts of an incoming `DataUnit`.
- `FileSourceWorker` and `LogicSourceWorker` are inline source stages delegating to the same reader engine.
- `DataReadCore` contains the shared open/inspect/drain/projection mechanics.
- `ExpandingTransformWorker` is the migration-safe 1:N execution base used by `ReadPartWorker`.

Server adapters live under `server/objects/job/worker/data/`; the reusable values and protocols do not. Client
file/source editing stays in the Job document packages because it edits Worker cards and projects source state
into downstream Job editors.

DS0's neutral package moves and the reciprocal `DataSource` / `FlatDataSource` naming rationale are recorded in
the model document. Broader Job→Report decoupling remains J-arc work.

## 11. Decisions register

Settled entries are here because a plan cites them or because someone will otherwise re-open them; the
argument lives in the section named.

| # | Decision | Current answer |
|---|---|---|
| O1 | 1:N in-memory expansion — new archetype or a knob on `FormulaWorker` (§5.4) | Separate `ExpandWorker` archetype, **demand-driven** — nothing in this design needs it |
| O2 | `ResultSinkWorker keep: all` (§7.1) | **Resolved in DS7:** a separate collection-policy change, not part of the data model |
| O3 | Definition-time source/opener I/O | Owned by [model DM6](2026-08-20_data-source-model.md#7-decisions-register): never |
| O4 | Plain refs | Owned by [model DM2](2026-08-20_data-source-model.md#7-decisions-register): first-class and every landed ref |
| O5 | Nested units | Owned by [model DM3](2026-08-20_data-source-model.md#7-decisions-register): no; flatten at resolve time |
| O6 | Widen the static stream dispatch beyond `Iterable` (§5.5) | **Resolved in DS1b:** one `isStreamType` covering `Iterable \| Sequence \| Iterator`; `FormulaSourceWorker` gains independently |
| O10 | Can a source nest **inline** under `ReadWorker.source`? (§5.2) | **Resolved by the UI correction:** no hidden nested object and no separate section. File/Logic are each one true Worker that owns its source config and delegates to the shared reader engine; pure DataSource + nominal Read remains for sharing |
| O11 | `emit: items \| units` knob vs a `Resolve` + `Read` split (§5.2) | The knob — a source worker has no incoming lane, so there is no ordering or migration-state objection |
| O12 | Stateful source resource lifetime | Owned by [model DM12](2026-08-20_data-source-model.md#7-decisions-register); design-time ownership remains open |
| O13 | Argument passing into `resolve` and hosted Logic — positional or named (§4, §4.4, §7.1) | **Named.** Sources use `DataContext.argument(name)`; `RunWorker.arguments` evaluates expressions into named child parameters beside the positional input; `LogicDataSource` reuses the named `host(instructions, arguments: TupleValue)` overload |
| O14 | Is a **nullable structural reference** usable for `ReadWorker.source`? (§5.2) | **No.** Blank defines and can inject null, but `GraphDefinition.filterTransitive` throws `Missing <empty>` first. Use `by: Nominal` with a creator preserving `ObjectReference?` plus snapshot-scoped lookup/instantiation; set/cross-document works, while delete stays representable as a clear unresolved-reference validation |
| O15 | Durable provider identity | Owned by [model DM11](2026-08-20_data-source-model.md#7-decisions-register): `DataSourceId` lands operationally with the first provider-bound source |
| O16 | Is the last session a Kotlin `DatedPathDataSource` or `LogicDataSource` + an example Script? (§4.4) | **Resolved in DS8:** `LogicDataSource` plus a one-step dated Script fixture compiled and ran end to end; no ninth Kotlin source class was needed |
| O17 | Does the `ObjectRegistry` document survive the §5.5 visibility fix? | **No.** No real predicate false negative exists to test; retire the document and its scan/threading with the visibility fix rather than keep an untestable hatch |
| O18 | `DataSchema` ownership | Owned by the [model typed-record contract](2026-08-20_data-source-model.md#43-dataschema-declares-a-typed-record); DS6 renamed and consumed it, but its labels-only projection remains to be corrected |
| O19 | When and how does heterogeneous-schema **superset normalization** land? (§5.3, §9) | **Resolved in DS6:** `schemaMode: strict \| superset` on both readers, default `superset`; ordered projection materializes `<missing>`, while `strict` rejects drift |
| O20 | Cursor contract | Owned by [model DM7](2026-08-20_data-source-model.md#7-decisions-register): plain pull reader owned/offloaded by its consumer |
| O21 | When does the `DataSources` document land? (§6.5) | **After the arc**, when a project has sources belonging to no Job. Discovery is graph-wide from DS2, so the follow-up is additive; pickers must be graph-wide now |
| O22 | Unit attributes onto the item lane — reader knob or downstream expression? ([model §2.3](2026-08-20_data-source-model.md#23-attributes-are-text-canonical), §5.6) | **Reader knob `attributes: ignore \| columns`** — the reader is the only thing still holding the unit when the item is emitted |
| O23 | How may a 1:N transform checkpoint inside one input element? (§5.4) | Through an `ExpandingTransformWorker` that owns and migrates the active input batch and element position; never by adding a mid-element cadence to the 1:1 `TransformWorker` |

## 12. Landing order

DS0–DS8 landed in this order so each step was independently useful and nothing preceded its consumer. Their
temporary `docs/plans/next/DS*` elaborations were deleted on landing; §13 is the permanent as-built record.

0. ☑ **Data-layer package moves** (mechanical). Moved `HeaderListing` / `HeaderLabel` / `HeaderLabelMap`
   out of Report's document package and the input plumbing listed in the [model package record](2026-08-20_data-source-model.md#6-naming-and-packages). This package/import-
   only phase came **first**; the behavioural `FileListingAction.scanInfoBlocking` extraction stayed in DS2 with
   its first consumer.
1. ☑ **Model + lowering.** The [model §2 value types](2026-08-20_data-source-model.md#2-value-model) in kzen-auto-common — `DataRef.source` a nullable
   `DataSourceId` that nothing mints yet ([model §2.1](2026-08-20_data-source-model.md#21-dataref-is-opaque-and-plain-refs-are-first-class)), attribute order presentation-only with a canonical digest
   ([model §2.3](2026-08-20_data-source-model.md#23-attributes-are-text-canonical)), reserved fingerprint keys ([model §4.2](2026-08-20_data-source-model.md#42-fingerprinted-schema-cache)), `DataShape`, `DataResolveResult` — with `ExecutionValue`
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
