# Structural data — one type language, generated access, and configurable formats

> **Status: analysis. Nothing here is built.** This is the arc
> [`2026-08-20_job-data-source.md`](2026-08-20_job-data-source.md) §6.3 deferred ("Column types —
> excluded, but the landing site already exists") and master-plan ledger row 14 parked ("declared types
> retained for future typed-lane work"). It supersedes neither: the DS model in that document's §3 —
> `DataRef` / `DataPart` / `DataUnit` / `DataManifest`, `DataSource.resolve`, `DataOpener.open` — is
> assumed correct and is not revisited. What changes is what a *shape* is, how a format is *specified*,
> and how a value is *accessed*. Per CC-20 no line numbers are cited; anchors are class / file names.
> Decisions are collected in **§13**; everything not listed there is a proposal, not a settlement.
> Reviewed in [`2026-08-25_structural-data_review.md`](2026-08-25_structural-data_review.md). Its findings
> are folded into this document: in particular, semantic type, schema observation and runtime value are now
> separate contracts; reader pipelines unify at their output rather than at byte framing; and the format,
> provider and Worker migrations include the identity and lifetime rules they require. The review remains as
> the audit trail for those corrections, not as a second half of the design.

## 1. What this is for

Six forces, stated by the user on 2026-08-25, that the current model cannot hold at once:

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
- **Configurable format instances specified in the UI, without writing code.** Delimiters, quoting, record
  selectors, schemas and decoding policy should be configurable for supported format families. Arbitrary
  EDI, binary or log grammars are a separate parser-DSL problem, not a promise of this arc.
- **Selection is distinct from processing.** Files may come from disk or an S3 bucket; the logic that
  processes them is the same either way.

And one constraint, added the same day: **the flat path's allocation-free scalar access and reuse machinery
are properties worth preserving.** The current Job lane is not zero-allocation end to end; §9 makes the
measurable boundaries explicit.

**Out of scope.** Report's retirement sequence (J4 owns it); fan-out topology (J6); per-unit parallelism;
design-time resource lifetime for stateful sources (DS O12); arbitrary user-authored grammar DSLs; and
structured writers / lossless format round-tripping. This document is reader-first and assumes the DS
execution arc as landed.

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
| Element carrier | `JobMessage(payload, flat: FlatView?)` | Two authoritative halves with lossy bridges — **replace with one value over optimized backings** (§11) |
| Flat record | `FlatFileRecord` (`char[]` + `int[]` + lazy caches) | Allocation-free scalar-read / reuse asset; becomes the depth-1 backing (§9.4) |
| Coercing value | `ColumnValue` | Keep as the `Scalar(Text)` accessor; declared non-text types bypass it (§8.5) |
| Expression compiler | `CalculatedColumnEval`, `CachedKotlinCompiler`, `RecordHeaderIndex` | Keep; drive accessor generation from the type instead of the lane (§8) |
| Parse SPI | `ReportDefiner<Output>` / `ReportDataDefinition` / `DataFramer` / `HeaderExtractor<Output>` | Keep the framing pipeline; the `HeaderExtractor` pairing is the ceiling (§4.2) |
| Format identity | `PluginCoordinate` (SPI) / `CommonPluginCoordinate` (common) | A name with no configuration — **make formats values** (§7) |
| Byte provider | `FlatDataSource` / `FlatDataStream` / `FileFlatDataSource` | Useful sequential seam, but insufficient for provider context and range/seek readers (§10) |
| Ref → opener | `DataOpenerLookup` | Provider-bound refs throw; needs provider resolution plus content capabilities, not just dispatch (§10.2) |
| Shape resolution | `DataSourceActions action=shape` → `staticShape` then `inspectShape` | Right order; replace the cases inside `DataShape` with a provenance-bearing observation (§6.2) |

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
**That is why configurable structural format instances in the UI are blocked — it is not merely a UI
gap.** Structural richness has no representation that is not a JVM type, so authoring structure means
authoring code.

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
DataType = Scalar(kind: ScalarKind)
         | Record(fields: List<Field>)                     // fixed, ordered field set
         | Mapping(key: ScalarKind, value: DataType)       // arbitrary keys, uniform value
         | Listing(element: DataType)
         | Union(cases: List<UnionCase>)                   // tagged variant / choice / oneof
         | Nominal(TypeMetadata)                           // a JVM class — opaque, reflectable
         | Dynamic                                         // shape unknown

Field = id + displayName + occurrence + type + presence + default + aliases
```

The sum omits a repeated `nullability` parameter for readability; it applies uniformly to every case.
Field presence is separate. A required field whose
value is null, an optional absent field, a defaulted field and a present value that failed decoding are four
different states. `Record` therefore cannot be a `Map<String, DataType>`: `HeaderListing` deliberately
preserves duplicate names by occurrence, while protobuf / Parquet can contribute numeric identities and
Avro can contribute defaults and aliases. The common `Field` contract is ordered and keeps identity separate
from display name.

`ScalarKind` is parameterized rather than a short enum: signedness and width for integers, width for floats,
precision / scale for decimals, temporal unit and zone semantics, enum symbols and fixed-binary length.
Boolean is explicit, and logical types such as UUID need an extension mechanism that does not add a central
case for every plugin.

`Tabular(header)` is no longer a type case. It projects to a `Record` whose occurrence-aware fields are
`Scalar(Text)`. A record of scalar fields can project back to a tabular view under an explicit naming policy;
that projection, rather than a claim of automatic equivalence, is what lets flat consumers participate in a
wider language (§5.8).

### 5.2 `Nominal` is a leaf of the structural language

The unification is not "structural types get a nominal escape hatch". It is that a nominal type is a *leaf*
of one language:

- **Reflect** a `Nominal` and you get a `Record` — its properties become fields, on demand. That is how a
  `JobMessage.payload` becomes reachable by the same dynamic expression machinery as a CSV row, which is
  the user's requirement stated exactly.

The reverse direction — generating a JVM class from a `Record` — is deliberately *not* part of the model.
Generated accessor façades over a typed record (§8) already give a UI-declared schema the speed of a
hand-written one; a materialized domain class has classloader, metaspace and identity costs and no consumer
today. It can be added when one appears.

Two parallel universes joined by `flatView()` / `boundaryValue()` string conversion is what we have now; one
semantic language with lazy nominal projection is what replaces it.

Reflection depth is a real hazard (cycles, `Object` graphs, lazy properties with side effects), so it must
be **lazy and depth-1 on demand** rather than eager and transitive. That is necessary but not sufficient:
the projection also needs a policy for Kotlin properties versus JavaBean getters / fields, visibility,
serialization names, generic substitution, plugin classloaders and side-effecting getters — **ST5**.

### 5.3 `Record` and `Mapping` are different, and both are needed

A `Record` has a fixed known field set: accessors can be generated, ordinals resolved at compile time,
misspellings caught. A `Mapping` has arbitrary keys of a uniform value type: accessors cannot be generated,
lookup is by key at run time. Collapsing them costs you either static accessors (everything becomes a map)
or dynamic keys (everything must be declared). Real formats need both, frequently in the same document.

### 5.4 `Union` is tagged and deliberate

Avro unions, protobuf `oneof`, XML `choice`, a JSON array of heterogeneous objects. Without `Union`, the
first variant encountered in a real schema collapses its whole subtree to `Dynamic`, and the schema stops
earning its keep exactly where declared formats get interesting. But tagged variants and inferred,
heterogeneous JSON are different things. `Union` cases have stable tags / names and come only from a
declaration or carried schema; inference that observes incompatible variants widens that position to
`Dynamic`. Nullability remains a uniform authoring modifier rather than a union case. This bounds the
joining and accessor problem without erasing real `oneof` semantics — **ST2**.

### 5.5 Do not inherit JSON's type system

The failure mode is defining `ScalarKind` as JSON's string / number / bool / null and discovering later that
everything non-JSON degrades on contact. The minimum that does not:

- **Integer**, distinct from decimal, with width.
- **Floating point**, with width, distinct from exact numeric values.
- **Decimal**, with precision and scale. Fixed-precision money is most of what ETL is for, and `double` is
  the wrong answer for it.
- **Boolean**, not an enum or a numeric convention.
- **Temporal** — date, time, instant, distinctly. Not "a string that looks like a date".
- **Binary** — a blob is not text and must not round-trip through a charset.
- **Enum** — a closed set of symbols, which several schema-carrying formats declare natively.
- **Text**, which is what every current column is.

`DataType` is the **semantic projection used for access**, not a lossless universal schema IR. A format may
retain its native schema beside that projection when exact re-emission matters. XML attributes and mixed
content, Avro namespaces / aliases and Parquet physical annotations therefore do not have to distort the
common access language. This arc is reader-only; a future writer design must say how native metadata is
preserved before promising lossless round-trips — **ST3**.

### 5.6 `Dynamic` is the base case, not the failure case

A format that can tell us nothing must still read, and its data must still be reachable by expression. So
`Dynamic` is a first-class terminus with a working accessor (§8.3), not an error state. Everything else in
the language is a *refinement* of `Dynamic` that buys static checking and speed. Designing it the other way
round — schema required, dynamic bolted on — is what makes tools brittle against real-world data.

### 5.7 `DataShape` is the observation envelope

`DataType` replaces the *cases inside* today's `DataShape`, not the concept of a shape observation:

```
DataShape(
    itemType: DataType,
    provenance: Declared | Carried | Inferred | RuntimeOnly,
    stability: Stable | Provisional(sampleCoverage),
    diagnostics: List<SchemaDiagnostic>
)
```

`DataSource.staticShape(role)` and `DataOpener.inspectShape(context, part)` keep their call-site roles (DS
O3 — no IO at definition time — is untouched), but return an observation rather than a tabular / payload
sum. Inspection unavailability must remain distinct from an observed `Dynamic`: the former produced no
answer; the latter uses `RuntimeOnly` provenance and promises an executable runtime value whose members are
not statically known. (An explicit declaration may also choose `Dynamic`, in which case its provenance is
still `Declared`.)

Report's `dataType` field (§2, constraint 4) dissolves: "which record model" stops being a user-facing
question once `Nominal` is in the same semantic language. Format selection uses independent representation
hints first and validates the resulting shape with the type algebra; it cannot select solely by a type that
the format may itself be needed to discover (§7.3).

### 5.8 The algebra is part of the type contract

Three operations must share one canonical definition before inference, Worker migration or format matching:

1. `accepts(expected, actual)` — declaration validation, Worker requirements and format claims.
2. `join(left, right)` — sampled records and multi-part `schemaMode=superset`.
3. `project(value, source, target)` — normalization into an effective lane type.

The representative-pair table must cover numeric promotion, required versus missing fields, overlapping
records, list elements, nominal-to-structural projection and tagged variants. Flattening is the first
`project` case: it needs a deterministic nested-field naming rule and explicit `Listing` / `Mapping`
behaviour before a tree reader can feed any existing column Worker. `KType → DataType` is the other named
mapping: Formula already obtains an inferred `KType`, and its output lane needs defined mappings for Kotlin
scalars, lists, maps and nominal classes.

## 6. Parsing arbitrary structure

### 6.1 Unify at emitted values, not byte parsing

A structural event stream — object/list start and end, field identity, typed scalar — is a useful producer
contract for building a shared structural backing. Record-item boundaries are separate events: a nested
object is not automatically one cursor element. Delimited rows and Avro object containers can use a
sequential adapter; JSON / XML selectors must understand parser state; Parquet reads footer metadata and
selected column chunks through range access; protobuf needs a declaration and explicit message framing.

The existing `DataFramer` + `ReportSegmentDefinition` pipeline therefore stays as the optimized
**sequential framed-reader adapter**, not as a mandatory foundation for every reader. Readers may expose
sequential bytes, seek / range-readable content or a native row/object cursor. They unify at `DataValue` /
`ValueAccess` (§8), and an event-to-tape adapter is one implementation of that output contract.

### 6.2 Schema provenance is a chain, not a flag

Four rungs, in priority order:

1. **Declared** — a `DataSchema` document referenced by the source. No IO; the only rung the
   definition-time walk may read (DS O3).
2. **Carried** — Avro and Parquet embed a schema; XML may have an XSD. (Protobuf does *not*: a wire message
   needs a `.proto` or descriptor set, which makes it a *declared* schema in a different notation.) The
   format knows and can simply be asked. This is the rung that does not exist today.
3. **Inferred** — sample N records and generalize. CSV's header row is the trivial instance; JSON needs
   real sampling, with the sample size a knob and the result explicitly provisional.
4. **`Dynamic`** — nothing is known; §5.6 applies.

`DataSourceActions action=shape` already implements rungs 1 and 4 with a narrow rung 3
(`ReportHeaderReader`). Widening `inspectShape` from "read a header row" to "ask the reader what it knows"
is the extension, and it is where rung 2 lands. The returned `DataShape` retains provenance, sampling
coverage, provisional status and diagnostics (§5.7). A declaration is the contract; observed disagreement
is a validation diagnostic, never a silent override — **ST6**.

### 6.3 Record selection is composed with the format

Arbitrary structured data is usually one document containing many records at some path: `$.data.items[*]`,
`/root/row`, an Avro container's blocks, "each line" for delimited text. Without a **record-selection path**
on the format, a nested document is one enormous record and every downstream Worker sees a single element.

This sits *inside* a `DataPart` — finer-grained than the unit/part split, which is about which files belong
together — but it is not intrinsically part of a JSON / XML codec or of the dataset schema. Codec / dialect,
record selection and schema / decoding policy have different reuse and identity and should compose beneath
the effective configured format (§7.1). A shared selector abstraction is worthwhile only for the subset it
can stream honestly; codecs may contribute a dialect when their structure requires it — **ST7**.

### 6.4 What the plugin SPI keeps

`ReportDefiner` stays the code-authored sequential extension point and keeps its no-arg-constructor /
`META-INF/kzen/plugins.yaml` discovery and `PluginDocument` registration. Its framing pipeline is a
capability, not the reader SPI itself. Reader capabilities declare the content access they need and emit
`DataValue`; shape inspection can return a carried / inferred observation independently. The
`HeaderExtractor<Output>` pairing becomes the flat special case of shape observation rather than a required
pairing for every output.

### 6.5 Inference and decoding are policies, not reader accidents

Sampling needs record, byte, time, depth and field-count budgets; deterministic field ordering; numeric
promotion / overflow rules; handling for empty and null-only collections; optional-field inference; and the
ST2 rule that incompatible inferred heterogeneity widens to `Dynamic`. Its cache key includes the effective
format, selector, declared schema and inference configuration, and its `DataShape` reports coverage and
provisional status.

Declared typing introduces data-quality failures that text-only input did not distinguish. Before typed
decoding ships, choose whether a malformed value fails the part, skips the record, substitutes null /
default, or enters a quarantine lane. Diagnostics carry source, unit, record and structural path.

Tree readers also require defensive budgets: maximum nesting, record and collection size; XML external
entity disablement; YAML alias-expansion limits; protobuf recursion limits; and bounds for selectors and
regular expressions. These are shipping gates for the first structural reader, not later hardening —
**ST11**, **ST17**, **ST20**.

## 7. Formats are values, not names

### 7.1 The effective format is a composition

A configured format becomes an ordinary notation object assembled from three concerns:

- **Codec / dialect** — for example `DelimitedTextCodec { delimiter, quote, escape, header, trim }`, or a
  contributed JSON / XML / Avro capability. `DelimitedTextCodec` collapses `CsvReportDefiner` and
  `TsvReportDefiner` and buys `;`, `|`, headerless input and non-standard quoting. Fixed-width remains a
  separate physical layout with offsets, widths, padding, alignment and overflow.
- **Record selector** — rows, lines, blocks, or a bounded codec-specific path (§6.3).
- **Schema / decoding policy** — a `DataSchema` reference plus null tokens, temporal patterns, locale,
  overflow and malformed-value policy.

Code-contributed codecs are references / capabilities rather than members of a closed `json | xml | yaml`
enum; adding one must not require editing a generic central `when`. A `PluginFormat` wraps code-authored JAR
definers, while CSV / TSV coordinates are removed atomically rather than preserved as a parallel product
contract (**ST9**).

`DataPart.format` holds an effective configured-format identity rather than only a
`CommonPluginCoordinate`. Because graph objects are mutable, the manifest must either snapshot the immutable
effective configuration or carry the reference plus its resolved definition digest / version. The opener
uses that captured value throughout the run, and manifest / migration / schema-cache digests include codec,
selector, schema and inference configuration — **ST16**.

### 7.2 UI-authored and code-authored formats are the same kind of node

This is the property worth protecting. A configured format authored in the UI is notation; a codec authored
in Kotlin is a contributed capability; both resolve through the same graph and appear in the same catalogue.
Nothing downstream of resolution needs to know which kind supplied the codec. This enables configurable
instances of supported families; it deliberately does **not** claim that the UI can define an arbitrary EDI,
log or binary grammar without a separately designed, bounded parser DSL.

### 7.3 What this does to the format catalogue

The `fileFormats` action starts returning graph-discovered configured formats alongside installed codec
capabilities. Selection separates pre-parse hints from post-parse validation: an explicit format wins; in the
current file-only world extension and priority choose the default; future providers may add a trustworthy
media-type hint or content / magic detection. Type compatibility is checked *after* selection because the
reader may be needed to discover the type.

Representation vocabulary stays honest without building speculative precedence machinery: rename
`DataPart.encoding` to **character encoding**; name content coding explicitly (`innerExtension()` already
recognizes gzip in embryonic form); reserve a media-type hint in `DataRef.attributes` for a future provider.
Arbitrary delimiter and selector knobs do not become private MIME parameters — **ST19**.

Picking a format may mean creating one, which brings naming, shared-versus-inline ownership, deletion, stale
references and recursive schema UX. The UI change is not small; the select is the small part.

## 8. Expression access — generated from the type

### 8.1 The runtime contract comes first

`DataType` describes a semantic value; generated Kotlin needs a runtime value to read. The missing contract
is approximately:

```
DataValue(type: DataType, access: ValueAccess, root: NodeHandle)
```

`ValueAccess` is implemented by a `FlatFileRecord`, a structural tape or a nominal-object projection. It
distinguishes absent, null and decode failure; exposes the active tagged-union case; supports ordinal
navigation and dynamic keyed lookup; and offers primitive / span reads without forcing `Any?` boxing or
`String` allocation. The effective lane type is stable enough to compile against, while runtime state tells
the accessor which optional fields and union cases are present.

This also establishes one authoritative value for Formula mutation. Appending fields or replacing the root
produces one output `DataValue` and one output `DataType`; it does not update parallel payload and flat
representations that can drift. Backing lifetime and release are part of this interface, not an optimization
to add after queues and retaining Workers exist (§9.3).

### 8.2 What `CalculatedColumnEval` already unifies

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

### 8.3 Accessors driven by `DataType`

Generate per node kind instead:

| `DataType` | Generated accessor |
|---|---|
| `Scalar(Int / Decimal / Temporal / …)` | typed property off a typed slot — `val amount: Int` |
| `Scalar(Text)` | `ColumnValue` — coercing text, so `amount > 5` on an undeclared column keeps meaning what it means today (ST1) |
| `Record` | a nested accessor over a node index, so `order.customer.city` type-checks |
| `Listing` | typed lazy list façade over child ordinals; materialize a Kotlin `List<T>` only on request |
| `Mapping` | key-lookup accessor, dynamic by construction |
| `Union` | discriminated accessor exposing the active tagged case (**ST2**) |
| `Nominal` | the implicit receiver plus lazy structural projection under the member policy (**ST5**) |
| `Dynamic` | explicit lookup — `value["field"]` — followed by typed / coercing conversions; Kotlin cannot resolve an unknown `.field` |

`payload` and columns stop being two mechanisms. The "fallback for accessing arbitrary structured data" the
user asked for is not a mode — it is the `Dynamic` row of this table. It is also narrower than it looks: an
*inferred* schema (§6.2 rung 3) yields a `Record`, so every field the sample saw gets a generated `.field`
accessor, and only what the sample did not see is `Dynamic`.

### 8.4 Path resolution is compile-time

`RecordHeaderIndex(columnNames)` already resolves name → position once and hands the generated class an
`IntArray` (`recordHeaderIndex.indices(headerListing)`), so column access is an int index, not a map lookup.
The generalization is **name-path → ordinal-path**, resolved the same way at compile time. Consequently
`order.customer.city` compiles to *constant child ordinals*, not nested lookups.

This is the point worth repeating in any argument about performance: **a declared schema turns nested name
resolution into constant ordinal navigation.** Only `Dynamic` and `Mapping` pay a lookup, which is where the
cost belongs.

### 8.5 `ColumnValue` is the `Scalar(Text)` accessor

`ColumnValue`'s coercion semantics are product behaviour, not a compatibility artefact — comparing a text
column to a number (`"13.0" == 13`) is the bread-and-butter ETL expression — and its interned constants
(`empty`, `null`, `0`, `1`, `true`/`false`, `y`/`n`) are a real allocation optimization. It stays, as the
accessor generated for `Scalar(Text)`, which is what it already is today. What changes is that a *declared*
non-text type no longer routes through it, and `Dynamic` gets an explicit lookup rather than a coercing
node. An undeclared CSV column is `Scalar(Text)` (**ST1**, settled) — the type is honest and
no existing expression changes meaning.

## 9. Performance — preserve fast paths with measured boundaries

### 9.1 State the boundary honestly

`FlatFileRecord` stores `char[] fieldContents` + `int[] fieldEnds`: a field is addressed as
*(buffer, start, end)*, never as an object. Around that sit the three things that do the real work:

- **Lazily populated parallel caches** — `doublesCache`, `hashesCache` — with **caller-owned scratch**
  (`long[] i128` is passed *in* to `cachedDoubleOrNan` / `cachedHash`, not allocated per call).
- **A full reuse protocol** — `clear`, `clearCache`, `copy`, `clone`, `exchange`, `prototype`, `growTo`,
  `growBy` — which is what lets the 32K ring and `FlatPipelineHandoff` recycle instances.
- **Allocation as opt-in** — `getString(int)` is the *only* allocating reader, and `fieldContentsUnsafe()` /
  `fieldEndsUnsafe()` / `contentStart` / `contentEnd` sit beside it for callers that do not want it.

This proves zero-allocation scalar access and reuse **inside Report's ring-buffer pipeline**, not a
zero-allocation Job lane. `FileDataCursor.fill()` prototypes every emitted row, and superset projection
currently creates another record plus a `String` per cell. The first performance target is therefore
measured improvement against that baseline. The design must name which invariant a test covers: parser-slot
reuse, allocation-free scalar reads, or end-to-end per-record Job execution.

### 9.2 Structural tape is one backing, not the universal representation

For nested textual data, one contiguous byte / character buffer plus primitive node tables is a strong
candidate: kind, offsets, child links and interned field ids. But Avro and Parquet expose typed primitives
that should not round-trip through characters, and nominal readers may naturally yield objects. A structural
tape therefore may carry typed primitive buffers alongside spans, while native typed and object backings
remain valid implementations of the same `ValueAccess` contract.

The common claim is **one access interface with several backings**, not one character tape or one parser
pipeline. Event streams produce structure; tapes store one representation; `FlatFileRecord` supplies another.
Where a declared schema fixes field identities, generated access uses constant ordinals regardless of the
backing. `Dynamic` and `Mapping` alone pay name / key lookup.

### 9.3 API shape and lifetime determine the allocation boundary

If the record interface exposes `getScalar(i): Any?`, every downstream read boxes and the door is shut
permanently — no later optimization can reopen it. The interface has to mirror what `FlatFileRecord` already
proves out, without allocating tuples for spans:

```
node(parent: Int, ordinal: Int): Int                  // navigation, no allocation
scalarDouble(node: Int, i128: LongArray): Double      // caller-owned scratch, as today
scalarChars(node: Int, destination: CharSpan)         // caller-owned span / separate primitive getters
scalarString(node: Int): String                       // opt-in, allocating
```

Accessor return types must stay **concrete and monomorphic**. A `value class NodeRef(val index: Int)` keeps
generated code readable at zero cost, but it boxes the moment it is nullable or used generically — so a
generated accessor must not return `NodeRef?` or a generic `T`. This is a rule for the code generator, and
it is cheap to hold because the generator knows the type statically.

Reuse beyond the parser requires a release / pool protocol. Messages may be queued, batched, forwarded,
sorted or retained, so ownership transfer alone does not say when backing arrays can return to a pool.
`DataValue` must define retain / release or another explicit lifetime before an end-to-end zero-allocation
claim is meaningful — **ST15**.

### 9.4 `FlatFileRecord` is the depth-1 backing, not a casualty

Do not replace it. It is a tuned depth-1 span-backed record on the path
that matters most today. Have it implement `ValueAccess`; preserve its primitive caches and ring-buffer
protocol; and measure the adapter against the current workload. The structural tape appears only where the
type is genuinely nested. Compatibility of the interface does not itself prove absence of regression.

### 9.5 Typed flat is an optimization opportunity

Today's hot loop is `record.getString(index)` → `ColumnValue.ofText(text)`: two allocations per column read,
softened only by `ColumnValue`'s interned constants. Under a declared schema, a numeric comparison can compile
straight to a primitive cached read with caller scratch. That is a credible improvement hypothesis against
what ships; a benchmark and allocation profile must establish its actual boundary.

### 9.6 Where allocation is unavoidable, declare it

Protobuf into generated messages, Avro `GenericRecord`, an XML DOM — these hand you objects, and that is
fine: their backings allocate. Decimal, binary and temporal access have different costs too. The framework
must not force boxing or text conversion on a backing that can avoid it; each reader / backing should declare
its capability and lifetime rather than pretending every format shares one allocation profile.

### 9.7 Pin it with a test

DS3 pinned "every cursor call inside `blocking`" with an offload counter in its A/B. Same discipline here:
benchmark the current Job-lane baseline, then pin allocation-free primitive / span reads and any stronger
parser-slot or end-to-end target separately. A single vague allocations-per-record assertion would conceal
which layer regressed.

## 10. Providers — selection is already separate from processing

### 10.1 The seam exists and is correct

`DataSource.resolve → DataManifest` (which files) versus `DataOpener.open(part) → DataCursor` (what to do
with them) is exactly the separation the user asked for, and DS built it. `FlatDataSource` /
`FlatDataStream` is a useful sequential local-file seam below that, with `FileFlatDataSource` as its only
implementation; it is not yet the provider-neutral content contract.

### 10.2 Two couplings to break

`DataOpenerLookup` refuses provider-bound refs outright:

```kotlin
fun openerFor(ref: DataRef): DataOpener {
    val source = ref.source ?: return plainOpener
    throw IllegalStateException("provider-bound refs are not supported yet: ${source.value}")
}
```

and `FileDataOpener` hardcodes `FileFlatDataSource.instance` rather than resolving a provider for the ref.
Removing those throws is necessary but insufficient: `FlatDataSource` receives only a `FlatDataLocation`,
not the full provider-bound `DataRef`, execution context / client, credentials or resource lifetime.

### 10.3 What an S3 source actually costs

A provider-bound source needs a content-access capability approximately "open this resolved `DataRef` as
content." It resolves `DataSourceId` to the provider instance that owns credentials and clients, retains
cancellation / close ownership, and advertises sequential and range / seek access. Parquet over S3 is the
forcing case: selection remains independent from interpretation, but the reader needs footer and column
range reads supplied by the provider.

That capability, a `DataSource` resolving bucket / prefix queries and `DataSourceId` minting (DS O15) land
with the first provider-bound source rather than speculatively. Disk / S3 / HTTP can then share the format,
schema and expression stack above content access. `DataRef.attributes` already carries cheap object-store
metadata such as size / modified and has the reserved media-type-hint landing site from §7.3 — **ST18**.

## 11. Worker type flow — one authoritative value

`JobMessage(payload, flat)` carries the two worlds side by side with lossy bridges in both directions:
`flatView()` stringifies a payload into columns via `ColumnValue.toText` (a `Map` becomes keyed columns,
anything else becomes a single `value` column), and `boundaryValue()` materializes columns into a
`LinkedHashMap<String, String>` for a Logic boundary.

Those bridges are the visible cost of two type systems. The clean target replaces the parallel authoritative
fields with one `DataValue`; its `ValueAccess` may be flat-record-backed, tape-backed, composed or
object-backed. Representation choice stays internal to the value rather than leaking into every consumer.
The ownership-transfer rule remains useful, but mutation produces one new authoritative root / type and
obeys the backing's lifetime protocol.

`WorkerLane(payloadType, flatColumns)` must change in the same runtime phase. Each Worker declares a type
transformation: filters preserve input; Formula appends record fields or replaces the root using
`KType → DataType`; pivot / sort / summary / writers require structural capabilities; a Logic boundary
projects into its declared result type; `Dynamic` weakens validation without preventing execution.

Existing column Workers consume a flatten `project`, not an implicit `flatView()`. Its nested naming,
listing and mapping rules are part of the semantic algebra (§5.8). This is why a tree reader cannot precede
the Worker and projection contract even if its parser is independently ready.

## 12. Naming and packages

- `DataType` and its cases: `kzen-auto-plugin` `commonMain`, once the module is KMP (**ST8**, settled).
  `HeaderListing`, which DS0 moved out of Report's package into `kzen-auto-common`
  `common/data/schema/`, moves down with it; the `DataShape` observation envelope lives beside the type;
  `kzen-auto-common` depends on the plugin and the `PluginCoordinate` / `CommonPluginCoordinate` mirror
  collapses.
- `DataValue` / `ValueAccess`: common semantic surface in the plugin where possible, with JVM backing and
  nominal-projection implementations in `jvmMain`. Third-party readers emit the same value contract. With
  the type language in the same module there is no SPI-side schema counterpart to keep in step.
- Format objects: `kzen-auto-jvm` notation under `auto-jvm/data/`, with the `DataSchema` document that
  already lives in `server/objects/data/schema/`.
- Structural tape and typed backing implementations: `kzen-auto-plugin` `jvmMain`, beside
  `FlatFileRecord`; neither is the public parser pipeline.

## 13. Decisions register

Settled only where stated; **Current proposal** records conclusions adopted by this analysis but still open
to an implementation decision. Numbered `ST*` so they do not collide with the DS document's `O*`.

| # | Question | Current thinking |
|---|---|---|
| ST1 | Type and accessor for an undeclared delimited field | **Settled: `Scalar(Text)`**, accessed as coercing `ColumnValue` (§8.5). Declared non-text types bypass it; `Dynamic` means unknown structure |
| ST2 | Tagged and inferred variants | **Current proposal:** `Union` is tagged and comes from declared / carried schema; inferred incompatible heterogeneity widens to `Dynamic`; nullability is a uniform modifier (§5.4) |
| ST3 | Semantic access projection or lossless schema IR | **Current proposal:** `DataType` is the semantic access projection; native schema metadata may live beside it. Structured writing / lossless round-trip is out of scope (§5.5) |
| ST4 | Does `DataType` replace `DataShape`? | **Current proposal:** replace today's `Tabular` / `Payload` cases, but retain `DataShape` as the provenance / stability / diagnostic observation envelope (§5.7) |
| ST5 | Nominal → structural projection policy | Lazy and depth-1 on demand; member source, naming annotations, visibility, generics, classloader and side-effect policy remain to specify before implementation (§5.2) |
| ST6 | Observation disagrees with declaration | Declaration is the contract; observation produces location-aware validation diagnostics in `DataShape`, never a silent override (§6.2) |
| ST7 | Record-selector dialect | Share only an honestly streaming-safe subset; a codec may contribute its own bounded dialect (§6.3) |
| ST8 | Owner of the recursive type tree | **Settled:** `kzen-auto-plugin` becomes KMP; dependency-free `commonMain` owns one tree, while the existing JVM SPI remains in `jvmMain`; no schema mirror (§12) |
| ST9 | Configured delimited formats versus CSV / TSV coordinates | **Replace atomically.** Existing `format: CSV` / `TSV` notation breaks intentionally and all fixtures move in the same change (§7.1) |
| ST10 | One tape or one access contract | **Current proposal:** one `ValueAccess` contract with flat, structural-tape, native typed and object backings. Share a tape where representations agree; do not force readers through it (§9.2) |
| ST11 | Inference budget and result | Record count plus byte / time / depth / field-count budgets; deterministic join rules; coverage and provisional status returned in `DataShape`. Defaults remain to choose |
| ST12 | Field presence and nullability | Presence / default belong to ordered `Field`; nullability applies uniformly to `DataType`; absent, null, defaulted and decode failure remain distinct (§5.1) |
| ST13 | Scalar and variant detail | Parameterized scalar kinds, extensible logical types, stable tags on union cases. Exact wire grammar and normalization remain to specify (§5.1) |
| ST14 | Type algebra | `accepts`, `join`, flatten-`project` and `KType → DataType` are prerequisites with representative-pair and wire / digest tests (§5.8) |
| ST15 | Runtime value lifetime | A reusable backing needs explicit retain / release or equivalent ownership. Choose and measure it before claiming end-to-end zero allocation (§9.3) |
| ST16 | Effective-format identity | Snapshot immutable effective configuration or capture reference + resolved digest / version; manifests and caches include codec, selector, schema and inference settings (§7.1) |
| ST17 | Decode-error policy | Decide fail-part, skip-record, null / default substitution and quarantine semantics; diagnostics include source, unit, record and path before typed decoding ships |
| ST18 | Provider content access | Resolve the full `DataRef` through its provider and advertise sequential plus range / seek capabilities; land with the first provider-bound source (§10.3) |
| ST19 | Representation metadata | Rename character encoding; model content coding explicitly; reserve provider media type as a hint without building precedence before a supplier exists (§7.3) |
| ST20 | Security and writer scope | Structured writers are excluded from this reader arc. Before a tree reader ships, set nesting / record / collection / selector limits and format-specific protections |
| ST21 | Dynamic expression surface | Explicit keyed / indexed lookup followed by typed or coercing conversions; unknown `.field` is not generated (§8.3) |

## 14. Build order — proposed

The arc has two separately decidable halves. Typed flat closes the immediate information-loss seam and
validates the generated-access design over `FlatFileRecord`; structural readers can be scheduled later on
their own merit. Configured formats and provider content sit beside either half.

### Step 0 — module preparation

0. **`kzen-auto-plugin` → KMP.** Mechanical and independently green: dependency-free `commonMain` becomes
   the type owner; the existing SPI / `FlatFileRecord` remain in `jvmMain`; `kzen-auto-common` gains the
   dependency; `data/schema/` moves down; coordinate mirrors collapse; and release / publish-order docs move
   with it. Everything below lands into the single owner selected by ST8.

### Half 1 — typed flat

1. **Semantic contract.** `DataType`, ordered `Field`, presence / nullability, parameterized scalars,
   tagged variants, normalization, `accepts`, `join`, flatten-`project` and `KType → DataType`, with
   representative-pair and wire / digest tests.
2. **Shape observation.** Replace current `DataShape` cases with provenance / stability / diagnostics;
   update declared and inspected paths together. `DataSchemaDocument.shape()` stops discarding types.
3. **Runtime value.** Define `DataValue` / `ValueAccess`, absent / null / failure states and lifetime;
   adapt `FlatFileRecord`; benchmark the current Job lane and pin the precise primitive-read / parser-slot
   allocation boundaries claimed.
4. **Job type flow and expressions.** Replace `WorkerLane(payloadType, flatColumns)` and parallel
   `JobMessage` state; define Worker transformations and boundary projection; generate typed,
   `ColumnValue` and dynamic accessors in `CalculatedColumnEval`.

### Beside either half

5. **Configured-format proof.** Compose delimited codec / dialect, record selection and text-decoding
   policy; replace CSV / TSV coordinates and fixtures atomically; capture immutable effective-format
   identity in manifests and cache keys; apply the representation decisions in ST19.
6. **Provider-bound content.** Add provider resolution and sequential / range content access with the first
   S3-like source; mint `DataSourceId` here (DS O15).

### Half 2 — structural readers

7. **Structural backing + first reader.** JSON through a bounded streaming selector, covering declared,
   inferred and dynamic shapes. Use the flatten `project` from step 1 for existing column Workers; impose
   ST11, ST17 and ST20 policies before shipping it.
8. **Validate the reader / content SPI.** Avro exercises sequential carried schema; Parquet exercises
   metadata-first columnar and range access. Do not freeze the SPI before both.
9. **Structured writers only under a separate scope decision.** If introduced, specify ordering, variant
   discriminators and native-schema preservation rather than assuming the reader projection round-trips.
