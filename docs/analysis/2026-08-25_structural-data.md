# Structural data — one type language, generated access, and configurable formats

> **Status: analysis. Nothing here is built.** This is the arc
> [`2026-08-20_job-data-source.md`](2026-08-20_job-data-source.md) §6.3 deferred ("Column types —
> excluded, but the landing site already exists") and master-plan ledger row 14 parked ("declared types
> retained for future typed-lane work"). It supersedes neither: the DS model in that document's §3 —
> `DataRef` / `DataPart` / `DataUnit` / `DataManifest`, `DataSource.resolve`, `DataOpener.open` — is
> assumed correct and is not revisited. What changes is what a *shape* is, how a format is *specified*,
> and how a value is *accessed*. Per CC-20 no line numbers are cited; anchors are class / file names.
> Decisions are collected in **§13**; everything not listed there is a proposal, not a settlement.

## 1. What this is for

Five forces, stated by the user on 2026-08-25, that the current model cannot hold at once:

- **Report is a prototype, not the target.** It demonstrated the minimum capabilities; it is not a
  comprehensive solution to emulate. Its value now is the lessons — §2.
- **Nominal and structural types are two worlds with a stringly bridge.** Compiled JVM types resolved on
  the backend, versus schemas carried by the data (a CSV header, a JSON shape). Execution is entirely
  server-side, so there is no client/server reason to keep them apart — only inertia.
- **Dynamic expressions should read both uniformly.** If a structured CSV is accessed by expression, the
  same must hold for a `JobMessage.payload`, and for a nested value inside either.
- **Arbitrary structured data, not just JSON.** Nested JSON is one example. XML, Avro, Parquet, protobuf,
  YAML, fixed-width, EDI, log formats, DB rows. When the schema is known, access must be ergonomic; when
  it is not, there must be a working fallback.
- **Custom formats specified in the UI, without writing code** — at least in principle. Straight code will
  often be easier in practice, but the generality has to be there.
- **Selection is distinct from processing.** Files may come from disk or an S3 bucket; the logic that
  processes them is the same either way.

And one constraint, added the same day: **the zero-allocation flat lane is a property worth preserving.**
It cannot always be achieved, but the door must be left open as far as possible — §9.

**Out of scope.** Report's retirement sequence (J4 owns it); fan-out topology (J6); per-unit parallelism;
design-time resource lifetime for stateful sources (DS O12). This document assumes the DS execution arc as
landed.

## 2. Report is the prototype, not the target

Read as a prototype it is a success, and three of its ideas carry forward unchanged:

1. **Expressions compiled to bytecode and cached.** `CalculatedColumnEval` generates a Kotlin class per
   (expression, columns, model type, parameter types) and caches it through `CachedKotlinCompiler`. This is
   the single most valuable asset in the tree for everything below — §8.
2. **A parse pipeline SPI with a byte-framing stage.** `ReportDefiner` / `ReportDataDefinition` /
   `DataFramer` / `ReportSegmentDefinition`, driven by `ReportInputChain` over a ring buffer.
3. **Format resolution by extension with a priority fallback.** `ReportDefinitionRepository.find` prefers a
   definer claiming the extension, else the highest-priority non-`priorityAvoid` one. `FileDataOpener`
   already delegates to it rather than re-implementing it.

Four things it baked in are now the constraint:

1. **Flat-only records.** `FlatFileRecord` is the universal element and `HeaderListing` the universal
   schema. Nesting has no representation.
2. **Stringly columns.** `HeaderListing` carries names, no types; `ColumnValue` re-derives meaning at
   expression time by coercion.
3. **Format as a bare name.** `PluginCoordinate(val name: String)` — §4.3.
4. **`dataType` as a raw class name in an end-user field.** Report's Input exposes
   `InputSelectionSpec.dataType` (defaulting to `tech.kzen.auto.plugin.model.record.FlatFileRecord`) in the
   UI — a nominal type leaking into a surface where no user can supply a meaningful value.

The DS arc already replaced the fifth limitation (one monolithic document rather than composable Workers).
This document is about 1–3; 4 dissolves once shapes are structural (§5.7).

## 3. The shape already in the tree

| Concern | Where it lives today | Verdict |
|---|---|---|
| Structural shape | `DataShape.Tabular(HeaderListing)` | Names only, flat only — **generalize** (§5) |
| Nominal shape | `DataShape.Payload(TypeMetadata)` | Correct, but a *sibling* of Tabular rather than a leaf of it (§5.2) |
| Declared schema | `DataSchema` document, `DataSchemaFieldListSpec` / `DataSchemaFieldSpec` (field → `TypeMetadata`) | Right vocabulary; the types are parsed and then discarded (§4.1) |
| Element carrier | `JobMessage(payload, flat: FlatView?)` | Two halves with lossy bridges — **collapse the interface, keep both representations** (§11) |
| Flat record | `FlatFileRecord` (`char[]` + `int[]` + lazy caches) | The zero-alloc asset; becomes the depth-1 implementation (§9.4) |
| Coercing value | `ColumnValue` | Demote from universal to the `Dynamic` case (§8.4) |
| Expression compiler | `CalculatedColumnEval`, `CachedKotlinCompiler`, `RecordHeaderIndex` | Keep; drive accessor generation from the type instead of the lane (§8) |
| Parse SPI | `ReportDefiner<Output>` / `ReportDataDefinition` / `DataFramer` / `HeaderExtractor<Output>` | Keep the framing pipeline; the `HeaderExtractor` pairing is the ceiling (§4.2) |
| Format identity | `PluginCoordinate` (SPI) / `CommonPluginCoordinate` (common) | A name with no configuration — **make formats values** (§7) |
| Byte provider | `FlatDataSource` / `FlatDataStream` / `FileFlatDataSource` | Already a clean seam; not yet dispatched (§10) |
| Ref → opener | `DataOpenerLookup` | Provider-bound refs throw; one line to implement (§10.2) |
| Shape resolution | `DataSourceActions action=shape` → `staticShape` then `inspectShape` | Right order; widen `inspectShape` to "ask the format" (§6.2) |

## 4. The finding: information is destroyed at three seams

Not opinions — three places where the tree already computes the right thing and then throws it away. Each
is small, and each is a symptom of the same missing abstraction.

### 4.1 A declared schema's types are discarded at the only place they could matter

`DataSchemaDocument.shape()` is two lines:

```kotlin
fun shape(): DataShape.Tabular =
    DataShape.Tabular(HeaderListing.ofUnique(fields.fields.keys.toList()))
```

`DataSchemaFieldSpec` parses `TypeMetadata` per field — `class` / `of` / `nullable`, recursive, round-trip
pinned by `DataSchemaFieldSpecTest`. The field *names* survive into the shape; every declared type is
dropped, because `HeaderListing` is a list of names and there is nowhere else to put them. The document is
the supply and `staticShape` is the consumer, and the wire between them is one field wide.

### 4.2 Every format's shape is forced through a flat header

`ReportDefiner<Output>` is generic and `ReportDataDefinition` carries `outputModelType: Class<Output>` — the
`kzen-sample-plugin` emits its own `WcpRow`. So arbitrary structure is *expressible* today. But
`ReportDefinition` pairs every definer with a `HeaderExtractor<Output>`, and `FileDataOpener.inspect` is
declared to return `DataShape.Tabular` and constructs one unconditionally:

```kotlin
private fun <T> inspect(spec: EffectiveOpenSpec, definition: ReportDefinition<T>): DataShape.Tabular {
    val headerDefinition = FlatDataHeaderDefinition(...)
    return DataShape.Tabular(ReportHeaderReader().extract(headerDefinition))
}
```

So the only escape from flat is to go nominal, and the only way to go nominal is to compile a class.
**That is why "custom formats via the UI" is blocked — it is not a UI gap.** Structural richness has no
representation that is not a JVM type, so authoring structure means authoring code.

### 4.3 A format can be selected but never configured

The whole SPI type is:

```kotlin
data class PluginCoordinate(val name: String)
```

A coordinate carries no parameters, so "semicolon-separated with a fixed header" cannot be *said*, only
*implemented*. The tell is already in the tree: `CsvReportDefiner` and `TsvReportDefiner` are the same class
twice — same `DataEncodingSpec`, same `FlatFileRecord` output, same `FirstRecordItemHeaderExtractor`, same
`FlatPipelineHandoff(true)`, same 32K ring buffer — differing only in which lexer and parser the segment
names. Two identical definers is the shape duplication takes when the varying part has nowhere to live.

## 5. The model — one recursive type language

### 5.1 `DataType`

```
DataType = Scalar(kind: ScalarKind, nullable: Boolean)
         | Record(fields: LinkedMap<String, DataType>)     // fixed, known field set
         | Mapping(key: ScalarKind, value: DataType)       // arbitrary keys, uniform value
         | Listing(element: DataType)
         | Union(cases: List<DataType>)                    // variant / choice / oneof
         | Nominal(TypeMetadata)                           // a JVM class — opaque, reflectable
         | Dynamic                                         // shape unknown
```

`Tabular(header)` is no longer a case. It is the *view* `Record(header.map { it to Scalar(Text) })`, and a
`Record` all of whose fields are scalars can always be viewed back as a `HeaderListing`. That equivalence is
what lets every existing flat consumer keep working unchanged while the language underneath widens.

### 5.2 `Nominal` is a leaf of the structural language, and the door swings both ways

The unification is not "structural types get a nominal escape hatch". It is that a nominal type is a *leaf*
of one language:

- **Reflect** a `Nominal` and you get a `Record` — its properties become fields, on demand. That is how a
  `JobMessage.payload` becomes reachable by the same dynamic expression machinery as a CSV row, which is
  the user's requirement stated exactly.
- **Materialize** a `Record` and you can generate a class. That is how a UI-declared schema reaches the
  speed of a hand-written one.

Two parallel universes joined by `flatView()` / `boundaryValue()` string conversion is what we have now; one
language with a leaf and two conversions is what replaces it.

Reflection depth is a real hazard (cycles, `Object` graphs, lazy properties with side effects), so it must
be **lazy and depth-1 on demand** rather than eager and transitive — **ST5**.

### 5.3 `Record` and `Mapping` are different, and both are needed

A `Record` has a fixed known field set: accessors can be generated, ordinals resolved at compile time,
misspellings caught. A `Mapping` has arbitrary keys of a uniform value type: accessors cannot be generated,
lookup is by key at run time. Collapsing them costs you either static accessors (everything becomes a map)
or dynamic keys (everything must be declared). Real formats need both, frequently in the same document.

### 5.4 `Union` is not optional

Avro unions, protobuf `oneof`, XML `choice`, a JSON array of heterogeneous objects. Without `Union`, the
first variant encountered in a real schema collapses its whole subtree to `Dynamic`, and the schema stops
earning its keep exactly where the data gets interesting. `Union` also subsumes nullability cleanly if we
want it to — **ST2**.

### 5.5 Do not inherit JSON's type system

The failure mode is defining `ScalarKind` as JSON's string / number / bool / null and discovering later that
everything non-JSON degrades on contact. The minimum that does not:

- **Decimal**, distinct from floating point. Fixed-precision money is most of what ETL is for, and `double`
  is the wrong answer for it.
- **Integer**, distinct from decimal, with width.
- **Temporal** — date, time, instant, distinctly. Not "a string that looks like a date".
- **Binary** — a blob is not text and must not round-trip through a charset.
- **Enum** — a closed set of symbols, which several schema-carrying formats declare natively.
- **Text**, which is what every current column is.

XML additionally has attributes and mixed content, which are neither fields nor children. Either model them
explicitly or accept that XML round-trips lossily — a decision to make on purpose, not by omission —
**ST3**.

### 5.6 `Dynamic` is the base case, not the failure case

A format that can tell us nothing must still read, and its data must still be reachable by expression. So
`Dynamic` is a first-class terminus with a working accessor (§8.4), not an error state. Everything else in
the language is a *refinement* of `Dynamic` that buys static checking and speed. Designing it the other way
round — schema required, dynamic bolted on — is what makes tools brittle against real-world data.

### 5.7 What `DataShape` becomes

`DataShape` is replaced by `DataType`. `DataSource.staticShape(role): DataType?` and
`DataOpener.inspectShape(context, part): DataType?` keep their signatures and their contract (DS O3 — no IO
at definition time — is untouched, because it is about *when* a shape is obtained, not what it is).
`DataShape.Tabular` survives as a view function for the flat consumers; `DataShape.Payload` becomes
`Nominal`. Report's `dataType` field (§2.4) dissolves: "which record model" stops being a user-facing
question once shapes are structural, and the payload-type filter in `ReportDefinitionRepository.find`
becomes a `DataType` compatibility check.

## 6. Parsing arbitrary structure

### 6.1 A structural event stream, with flat as the degenerate case

The parse SPI's output should be a pull-style event stream — `startRecord` / `fieldName` / `scalar` /
`startList` / `end` — not a record type. Every serious format reader already *is* one internally: StAX,
Jackson's `JsonParser`, Avro's decoder, CBOR, the protobuf wire format. And **a flat CSV row is the
degenerate case**: `startRecord`, N scalars, `end`.

That matters because it collapses the reader lane instead of adding a second one. The alternative —
`FlatFileRecord` for flat formats, a tree for nested ones — reproduces the `payload` / `flat` split one
layer down, with the same lossy bridge to write and the same two code paths to keep in step.

The existing `DataFramer` + `ReportSegmentDefinition` pipeline stays underneath for byte framing, ring
buffering and throughput. What changes is what the last segment hands out.

### 6.2 Schema provenance is a chain, not a flag

Four rungs, in priority order:

1. **Declared** — a `DataSchema` document referenced by the source. No IO; the only rung the
   definition-time walk may read (DS O3).
2. **Carried** — Avro, Parquet and protobuf embed a schema; XML may have an XSD. The format knows and can
   simply be asked. This is the rung that does not exist today.
3. **Inferred** — sample N records and generalize. CSV's header row is the trivial instance; JSON needs
   real sampling, with the sample size a knob and the result explicitly provisional.
4. **`Dynamic`** — nothing is known; §5.6 applies.

`DataSourceActions action=shape` already implements rungs 1 and 4 with a narrow rung 3
(`ReportHeaderReader`). Widening `inspectShape` from "read a header row" to "ask the format what it knows"
is the extension, and it is where rung 2 lands.

Rung 3 needs a stated conflict rule: a sample that disagrees with a declaration is a *validation* result,
not a silent override — **ST6**.

### 6.3 Where the repeating unit lives is format configuration

Arbitrary structured data is usually one document containing many records at some path: `$.data.items[*]`,
`/root/row`, an Avro container's blocks, "each line" for delimited text. Without a **record-selection path**
on the format, a nested document is one enormous record and every downstream Worker sees a single element.

This sits *inside* a `DataPart` — finer-grained than the unit/part split, which is about which files belong
together — and it applies uniformly across JSON / XML / YAML / container formats. It is also what makes
UI-authored formats useful: "read this shape of file" is mostly *delimiter-or-path* plus *a schema
reference*. The path dialect per format family is **ST7**.

### 6.4 What the plugin SPI keeps

`ReportDefiner` stays the code-authored extension point and keeps its no-arg-constructor /
`META-INF/kzen/plugins.yaml` discovery, its `PluginDocument` registration, and its framing pipeline. Two
changes: `info()` gains a declared `DataType` (or "ask me", for rung 2), and the `HeaderExtractor<Output>`
pairing becomes optional — it is the flat special case of "what shape does this produce".

## 7. Formats are values, not names

### 7.1 The format object

A format becomes an ordinary notation object with attributes, not a name string:

- `DelimitedTextFormat { delimiter, quote, escape, header: firstRow | fixed(names) | none, trim }` —
  collapses `CsvReportDefiner` and `TsvReportDefiner` into one parameterized definer and immediately buys
  `;`, `|`, fixed-width, headerless, and non-standard quoting. This is the smallest complete proof of the
  idea, and it *removes* code.
- `PluginFormat { coordinate }` — wraps a JAR definer; the current behaviour, unchanged.
- `TreeFormat { codec: json | xml | yaml | …, recordPath, schema: <DataSchema ref>? }` — §6.3.

`DataPart.format` then holds a **reference to a format object** rather than a `CommonPluginCoordinate`. The
wire and digest contracts in `DataPart` / `DataRef` are unaffected in kind — a reference is still text.

### 7.2 UI-authored and code-authored formats are the same kind of node

This is the property worth protecting. A format authored in the UI is notation; a format authored in Kotlin
is a plugin object; both are objects in the graph, selected the same way, resolved by the same repository,
and offered by the same `fileFormats` catalogue the Format select already reads. Nothing in the pipeline
needs to know which kind it got. That is what "the generality needs to be there" buys without forcing every
format to be UI-authorable — the hard ones stay code, and they compose with the easy ones.

### 7.3 What this does to the format catalogue

`ReportDefinitionRepository.find(payloadType, dataLocation)` becomes
`find(compatibleWith: DataType?, dataLocation)`, and the `fileFormats` action (2026-08-25) starts returning
graph-discovered format objects alongside installed definers. The UI change is small because the select
already exists; what changes is that picking a format may now mean *creating* one.

## 8. Expression access — generated from the type

### 8.1 What `CalculatedColumnEval` already unifies

It is worth being precise about how much is already right. The generated class binds three scopes: the model
as implicit receiver with a `payload` alias, one accessor per column, one accessor per declared parameter.
Nominal members and structural columns are *already* in one scope, with Kotlin's innermost-receiver rule
resolving collisions. The compile is cached on the shape tuple, and the user's expression is generated as a
lambda-valued probe so one compile serves validation, type inference and execution.

The only thing wrong with it is that every column is generated identically:

```kotlin
private fun columnValue(columnIndex: Int): ColumnValue {
    val index = indices[columnIndex]
    val text = if (index == -1) { DataShape.missingCellValue } else { record.getString(index) }
    return ColumnValue.ofText(text)
}
```

Text, always, regardless of what is known.

### 8.2 Accessors driven by `DataType`

Generate per node kind instead:

| `DataType` | Generated accessor |
|---|---|
| `Scalar(Int / Decimal / Temporal / …)` | typed property off a typed slot — `val amount: Int` |
| `Scalar(Text)` | typed `String` / `CharSequence` accessor |
| `Record` | a nested accessor over a node index, so `order.customer.city` type-checks |
| `Listing` | `List<T>` of the same, lazily projected |
| `Mapping` | key-lookup accessor, dynamic by construction |
| `Union` | a discriminated accessor, or `Dynamic` if we choose not to model it (**ST2**) |
| `Nominal` | the implicit receiver — exactly as today |
| `Dynamic` | today's `ColumnValue`-style coercing node with `[...]` and `?.` |

`payload` and columns stop being two mechanisms. The "fallback for accessing arbitrary structured data" the
user asked for is not a mode — it is the `Dynamic` row of this table.

### 8.3 Path resolution is compile-time

`RecordHeaderIndex(columnNames)` already resolves name → position once and hands the generated class an
`IntArray` (`recordHeaderIndex.indices(headerListing)`), so column access is an int index, not a map lookup.
The generalization is **name-path → ordinal-path**, resolved the same way at compile time. Consequently
`order.customer.city` compiles to *constant child ordinals*, not nested lookups.

This is the point worth repeating in any argument about performance: **a declared schema makes nested access
cheaper, not more expensive.** Only `Dynamic` and `Mapping` pay a lookup, which is where the cost belongs.

### 8.4 `ColumnValue` demotes rather than dies

`ColumnValue`'s coercion semantics are load-bearing for existing documents — `"13.0"` compares equal to `13`
— and its interned constants (`empty`, `null`, `0`, `1`, `true`/`false`, `y`/`n`) are a real allocation
optimization. It stays, as the `Dynamic` accessor. What changes is that a *declared* type no longer routes
through it. Whether an undeclared CSV column stays `Dynamic` or becomes `Scalar(Text)` is **ST1**, and it is
the one decision in this document that can break existing expressions.

## 9. Performance — keeping the zero-allocation door open

### 9.1 The property does not come from flatness

`FlatFileRecord` stores `char[] fieldContents` + `int[] fieldEnds`: a field is addressed as
*(buffer, start, end)*, never as an object. Around that sit the three things that do the real work:

- **Lazily populated parallel caches** — `doublesCache`, `hashesCache` — with **caller-owned scratch**
  (`long[] i128` is passed *in* to `cachedDoubleOrNan` / `cachedHash`, not allocated per call).
- **A full reuse protocol** — `clear`, `clearCache`, `copy`, `clone`, `exchange`, `prototype`, `growTo`,
  `growBy` — which is what lets the 32K ring and `FlatPipelineHandoff` recycle instances.
- **Allocation as opt-in** — `getString(int)` is the *only* allocating reader, and `fieldContentsUnsafe()` /
  `fieldEndsUnsafe()` / `contentStart` / `contentEnd` sit beside it for callers that do not want it.

None of that depends on the data being flat. All of it depends on addressing by offset into a shared buffer.
**That generalizes**, and recognizing it is the difference between "nesting costs us the fast lane" and
"nesting is one more index".

### 9.2 The generalization is a tape

Nested structure becomes one contiguous scalar buffer plus a parallel node table of primitive arrays —
`int[] kind`, `int[] start`, `int[] end`, `int[] firstChild`, `int[] nextSibling`, `int[] nameId`. This is
not novel: it is simdjson's tape, Arrow's offset buffers, VTD-XML's virtual token descriptors. A `Record` is
a node, its fields are child indices, and a scalar leaf is a `(start, end)` pair in the same buffer as
today.

**A flat CSV row is the depth-1 degenerate case of that structure**, which is the same claim §6.1 makes
about the event stream, one layer down. The two agree by construction, which is the point.

Field names intern to `int` ids per lane. With a declared schema the dictionary is fixed at compile time, so
name comparison never happens at run time at all; with `Dynamic`, a per-batch interning table keeps it an
int compare.

### 9.3 The one API decision that determines everything else

If the record interface exposes `getScalar(i): Any?`, every downstream read boxes and the door is shut
permanently — no later optimization can reopen it. The interface has to mirror what `FlatFileRecord` already
proves out:

```
node(parent: Int, ordinal: Int): Int                  // navigation, no allocation
scalarDouble(node: Int, i128: LongArray): Double      // caller-owned scratch, as today
scalarChars(node: Int): (buffer, start, end)          // offset access
scalarString(node: Int): String                       // opt-in, allocating
```

Accessor return types must stay **concrete and monomorphic**. A `value class NodeRef(val index: Int)` keeps
generated code readable at zero cost, but it boxes the moment it is nullable or used generically — so a
generated accessor must not return `NodeRef?` or a generic `T`. This is a rule for the code generator, and
it is cheap to hold because the generator knows the type statically.

### 9.4 `FlatFileRecord` is the depth-1 implementation, not a casualty

Do not replace it. It already *is* a tape with an implicit single record, it is tuned, and it is on the path
that matters most today. Have it implement the general accessor interface and the flat lane keeps its exact
current code path and its ring-buffer recycling; the tape appears only where the type is genuinely nested.
One interface, two implementations, no regression risk on the existing workload.

### 9.5 This is a win on the existing path, not a tax

Today's hot loop is `record.getString(index)` → `ColumnValue.ofText(text)`: two allocations per column read,
softened only by `ColumnValue`'s interned constants. Under a declared schema, a numeric comparison compiles
straight to `cachedDoubleOrNan` with caller scratch and allocates nothing. The typed lane is *faster than
what ships*, which is the honest framing when this work is scheduled against other priorities.

### 9.6 Where allocation is unavoidable, declare it

Protobuf into generated messages, Avro `GenericRecord`, an XML DOM — these hand you objects, and that is
fine: they are `Nominal` leaves and they allocate. The rule is that **the framework never forces allocation;
a format may, and says so.** The failure mode to avoid is a lowest-common-denominator interface that drags
the tape lane down to the object lane's shape because one implementation could not do better.

### 9.7 Pin it with a test

DS3 pinned "every cursor call inside `blocking`" with an offload counter in its A/B. Same discipline: an
allocations-per-record assertion on the flat lane, so the property is a test rather than a comment that
erodes. Without it, the first well-meaning refactor that introduces a boxed getter will not be noticed.

## 10. Providers — selection is already separate from processing

### 10.1 The seam exists and is correct

`DataSource.resolve → DataManifest` (which files) versus `DataOpener.open(part) → DataCursor` (what to do
with them) is exactly the separation the user asked for, and DS built it. `FlatDataSource` /
`FlatDataStream` is the byte-provider interface below that, with `FileFlatDataSource` as its only
implementation.

### 10.2 Two couplings to break

`DataOpenerLookup` refuses provider-bound refs outright:

```kotlin
fun openerFor(ref: DataRef): DataOpener {
    val source = ref.source ?: return plainOpener
    throw IllegalStateException("provider-bound refs are not supported yet: ${source.value}")
}
```

and `FileDataOpener` hardcodes `FileFlatDataSource.instance` rather than resolving a provider for the ref.
Break those two and disk / S3 / HTTP / a blob store share the entire format, schema and expression stack
unchanged — which is precisely "the logic to process the files could be the same in both cases".

### 10.3 What an S3 source actually costs

A `FlatDataSource` implementation, a `DataSource` that resolves a bucket/prefix query into refs, and
`DataSourceId` minting (DS O15, already scoped and deferred to "the first provider-bound source"). No new
abstraction — the design anticipated this, and the two couplings above are the stubs it left. Worth noting
that `DataRef.attributes` already carries `size` / `modified`, which is what an object store gives you
cheaply and what the fingerprint cache keys on.

## 11. `JobMessage` — collapse the interface, keep the representations

`JobMessage(payload, flat)` carries the two worlds side by side with lossy bridges in both directions:
`flatView()` stringifies a payload into columns via `ColumnValue.toText` (a `Map` becomes keyed columns,
anything else becomes a single `value` column), and `boundaryValue()` materializes columns into a
`LinkedHashMap<String, String>` for a Logic boundary.

Those bridges are the visible cost of two type systems. Under `DataType` they become *representation
choices* rather than conversions: one typed value, whose accessor may be tape-backed (parsed from bytes) or
object-backed (a nominal payload). The message keeps both fields — that is what preserves the zero-alloc
flat lane and the no-array-allocation payload lane — but consumers stop asking *which half is populated* and
start asking the accessor.

The ownership-transfer rule (a receiver owns a received message and may mutate it in place) is unaffected
and remains what makes in-place materialization legal.

## 12. Naming and packages

- `DataType` and its cases: `kzen-auto-common` `common/data/schema/`, beside `HeaderListing`, which DS0
  already moved out of Report's package.
- The record accessor interface: `kzen-auto-plugin`, because third-party definers must implement it. This is
  a real widening of the SPI surface — the module deliberately has no `kzen-lib` / `kzen-auto-common`
  dependency, so `DataType` needs an SPI-side counterpart the way `PluginCoordinate` mirrors
  `CommonPluginCoordinate`. **ST8**.
- Format objects: `kzen-auto-jvm` notation under `auto-jvm/data/`, with the `DataSchema` document that
  already lives in `server/objects/data/schema/`.
- The tape: `kzen-auto-plugin` `model/record/`, beside `FlatFileRecord`.

## 13. Decisions register

Open unless stated. Numbered `ST*` so they do not collide with the DS document's `O*`.

| # | Question | Current thinking |
|---|---|---|
| ST1 | Does an **undeclared** CSV column become `Scalar(Text)` or stay `Dynamic`? | Lean `Dynamic` — `ColumnValue`'s coercion (`"13.0" == 13`) is relied on by existing expressions, and typing by default would silently change their meaning. Typed access becomes available by *declaring* a schema. **The one decision here that can break existing documents** |
| ST2 | Is `Union` modelled, or does a variant degrade to `Dynamic`? | Model it. Without it the schema stops paying exactly where real formats get interesting (§5.4). The cost is in the accessor generator, not the language |
| ST3 | XML attributes and mixed content — modelled or lossy? | Undecided. Modelling them adds two node kinds used by one format family; not modelling them means XML round-trips lossily. Decide before any XML format ships, not after |
| ST4 | Does `DataType` replace `DataShape`, or wrap it? | Replace, with `Tabular` surviving as a view function (§5.7). Wrapping keeps the disjoint union alive under a new name |
| ST5 | Is `Nominal` → `Record` reflection automatic or opt-in? | Lazy and depth-1 on demand. Eager transitive reflection of arbitrary JVM classes invites cycles, `Object` graphs and side-effecting property getters |
| ST6 | What happens when an **inferred** schema disagrees with a **declared** one? | The declaration wins and the disagreement is reported as validation. Silent override in either direction is the wrong answer; which one is *right* is the user's call |
| ST7 | One path dialect for record selection, or one per format family? | Undecided. A single dialect is learnable but fits none of JSON / XML / container formats exactly; per-family fits each but is three things to document |
| ST8 | Does `DataType` get an SPI-side counterpart in `kzen-auto-plugin`? | Yes if third-party definers declare shapes, which §6.4 assumes. Mirrors the existing `PluginCoordinate` / `CommonPluginCoordinate` split and keeps the SPI dependency-free |
| ST9 | Do `DelimitedTextFormat` and friends supersede the CSV/TSV **plugin coordinates**, or coexist? | Coexist initially — existing notation names `CSV` / `TSV` and must keep reading. A parameterized definer can *back* both coordinates before it replaces them |
| ST10 | Does the tape land as one implementation, or per-format? | One shared tape, written by the event stream (§6.1). A per-format tape reproduces the duplication `CsvReportDefiner` / `TsvReportDefiner` already demonstrates |
| ST11 | Sampling budget for inferred schemas | Undecided — needs a knob, a stated default, and an explicit "provisional" marker in the UI so an inferred shape is never mistaken for a declared one |

## 14. Build order — proposed

Sequenced so each step is independently useful and nothing is built before its consumer exists. Steps 1–2
are worth doing even if the arc stops there, because they are where information is currently destroyed.

1. **`DataType`** replaces `DataShape`; `Tabular` becomes a view; `Payload` becomes `Nominal`. Pure model
   plus round-trips (`ExecutionValue`, wire, digest), no runtime. `DataSchemaDocument.shape()` stops
   discarding declared types — §4.1 closed. **S–M**
2. **`DataSchema` gains nesting** — fields → `DataType` recursively. A widening of a shipped document with
   an existing controller and an existing notation test. **S**
3. **Accessor generation from `DataType`** in `CalculatedColumnEval` — typed accessors for known scalars,
   nested accessors for records, `ColumnValue` for `Dynamic`. Path → ordinal resolution generalizing
   `RecordHeaderIndex`. Answer **ST1** before starting. **L** — the widest blast radius in the arc
4. **The record accessor interface**; `FlatFileRecord` implements it as the depth-1 case; generated code
   binds to it; the allocation assertion of §9.7 lands with it. **M**
5. **Format objects** — `DelimitedTextFormat` collapsing `CsvReportDefiner` / `TsvReportDefiner` as the
   proof, `PluginFormat` wrapping a coordinate, `DataPart.format` becoming a reference. Independent of 1–4
   and can run in parallel. **M**
6. **Provider-bound refs** — `DataOpenerLookup` honouring `DataRef.source`, `FileDataOpener` resolving a
   provider instead of hardcoding one, `DataSourceId` minting (DS O15). Independent of everything above.
   **S–M**
7. **The tape + the structural event stream**, with a first tree format. JSON is the obvious first, but the
   design must be validated against a schema-carrying one — Avro or Parquet — before the SPI is frozen. The
   first real consumer of 1–4. **L**

Steps 5 and 6 are the cheapest and are separable from the type work entirely; step 3 is the expensive one
and the one that needs a decision first.
