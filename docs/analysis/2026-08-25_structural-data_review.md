# Structural data — design review

**Date:** 2026-08-25 · **Status:** review of the analysis in
[`2026-08-25_structural-data.md`](./2026-08-25_structural-data.md). Nothing reviewed here is implemented.
Claims were checked against the current `kzen-auto` tree; per CC-20, symbols and document sections are
cited rather than source line numbers.

## Verdict

The design has the right center: one recursive type vocabulary, one expression-access story, configured
format instances, and a clean separation between selecting data and interpreting it. Its diagnosis of the
three information-loss seams is accurate. `DataSchemaDocument.shape()` discards types,
`FileDataOpener.inspectShape()` forces every plugin through `DataShape.Tabular`, and `PluginCoordinate`
cannot express configuration. Those are symptoms of one missing structural-data layer, not three isolated
bugs.

The proposal is not implementation-ready yet. It currently asks `DataType` to be a type, a schema-observation
result, a format schema, a storage layout and an expression surface at once. It also assumes one sequential
byte-framing pipeline can underlie formats whose access patterns are fundamentally different. The result is
that the center is strong while several contracts immediately around it are absent.

The main recommendation is to separate three things explicitly:

1. **`DataType`** — the semantic type of a value.
2. **`DataShape` / schema observation** — a type plus provenance, confidence and diagnostics.
3. **`DataValue` / access** — a runtime value backed by a flat record, a structural tape or a nominal object.

Once those are separate, configured formats, generated expression access, schema inference and provider
independence have clear landing sites.

## Development-phase rule — no compatibility layer

There is no released legacy contract to preserve. Existing code is evidence and useful machinery, not a
compatibility obligation. The design should choose the clean target and replace obsolete surfaces atomically.

Consequences for the structural-data analysis:

- **ST9 should not choose coexistence.** Replace the `CSV` / `TSV` coordinate model with configured format
  objects when that work lands. Temporary adapters inside one compile-green refactor are an implementation
  technique, not a product contract, and should be removed in the same change.
- **ST1 should not be decided by old `ColumnValue` comparison behavior.** An undeclared CSV field is known to
  be text, so its honest type is `Scalar(Text)`. `Dynamic` should mean structurally or nominally unknown, not
  “text with historical coercions.” If coercing text is desirable product behavior, name it as an explicit
  conversion or value policy.
- Do not retain `DataShape.Tabular`, `DataShape.Payload`, `CommonPluginCoordinate` format fields or duplicate
  SPI schema trees merely so old internal notation continues to parse. Change the fixtures and notation with
  the model.
- Current behavior still matters where it demonstrates a real requirement: duplicate input names, buffered
  value lifetime, multi-file schema drift and zero-copy scalar access are data/runtime concerns, not legacy
  concerns.

---

## F1 — `DataType` does not yet describe the values it claims to cover

**Severity: blocking before the model is written.**

The proposed grammar puts `nullable` on `Scalar`, while `Record`, `Mapping`, `Listing` and `Union` cannot be
null. `Nominal` inherits nullability indirectly through `TypeMetadata`. This makes nullability depend on the
node kind and still cannot represent the distinction between:

- a required field whose value is null;
- an optional field that is absent;
- a field with a default;
- an input field that is present but fails decoding.

Presence belongs to the field, while null belongs to the value type. Use either a `Null` type plus canonical
union normalization or one nullability modifier that applies uniformly to every `DataType`.

`Record(fields: LinkedMap<String, DataType>)` is also too narrow. `HeaderListing` deliberately represents
duplicate names with occurrence identities. Protobuf and Parquet may contribute numeric field identifiers;
Avro contributes names, namespaces, defaults and aliases. A record should therefore be an ordered list of
fields with identity separate from display name:

```
Field(
    id: FieldId?,
    name: String,
    type: DataType,
    presence: Required | Optional,
    default: DataDefault?,
    aliases: List<String>
)
```

This does not require the common access type to preserve every format-specific schema feature. It does
require the design to say whether `DataType` is a **semantic projection for access** or a **lossless universal
schema IR**. The current proposal alternates between those goals. A semantic projection is the smaller and
more achievable contract; a format may retain its native schema beside it when lossless re-emission matters.

`ScalarKind` also needs parameters rather than names alone: integer signedness/width, float width, decimal
precision/scale, temporal unit and zone semantics, enum symbols, and fixed-binary length. Boolean needs to be
explicit. Logical types such as UUID should be extensible without adding one central enum case per plugin.

Finally, `Union(cases: List<DataType>)` is not enough to model protobuf `oneof` or another tagged variant.
Cases need stable tags/names and the runtime accessor needs to expose the active case. Nullability may use a
normalized union internally, but a tagged sum and “T or null” are not the same authoring concept.

**Recommendation:** settle the type grammar, field identity/presence and canonical normalization before wire,
digest or UI work begins.

## F2 — `DataType` should not replace the schema-observation envelope

**Severity: blocking before `staticShape` / `inspectShape` signatures change.**

The provenance ladder in §6 is useful, but `DataType?` has nowhere to retain it. It cannot tell the caller:

- whether the type was declared, carried or inferred;
- whether an inferred type is provisional;
- how much of the input was sampled;
- whether the declaration disagreed with observed data;
- whether inspection was unavailable or succeeded with a dynamic type.

The last point makes `null` and `DataType.Dynamic` ambiguous. `null` should mean that the operation did not
produce a schema observation. `Dynamic` should mean that a runtime value is available through a dynamic
access contract even though its member set is not statically known.

Keep `DataShape` as a neutral envelope rather than its current tabular/payload sum:

```
DataShape(
    itemType: DataType,
    provenance: Declared | Carried | Inferred,
    stability: Stable | Provisional(sampleCoverage),
    diagnostics: List<SchemaDiagnostic>
)
```

An inspection API may return `Unavailable` separately from `Observed(DataShape)`. The exact names are open;
the separation is not. This is where ST6 and ST11 become representable instead of prose-only policies.

**Recommendation:** replace the cases inside `DataShape`; do not replace the concept of a shape observation
with its contained type.

## F3 — the compatibility and joining algebra is a prerequisite, not a follow-up

**Severity: blocking before inference, format matching or Worker migration.**

At least three operations need one canonical definition:

1. `accepts(expected, actual)` — declaration validation, Worker inputs and format claims.
2. `join(left, right)` — sampled records and multi-part `schemaMode=superset`.
3. `project(value, source, target)` — normalization into an effective lane shape.

The current `DataReadCore.planShape()` can union headers because every value is text. Recursive types introduce
real choices: integer plus decimal, required plus missing, records with overlapping fields, lists with
different element types, nominal versus reflected structural values, and unions that grow across samples.
`ReportDefinitionRepository.find(compatibleWith: DataType?)`, ST6, ST11, generated accessors and the existing
multi-file schema policy all depend on the same answers.

ST2 understates this by saying Union's cost sits in the accessor generator. Union participates in inference,
joining, validation, serialization, branch discrimination and Worker output typing. It should still exist,
but its whole-system cost should be acknowledged.

**Recommendation:** specify and test the algebra with a table of representative pairs before implementing
either inference or code generation.

## F4 — one output contract is right; one parser pipeline is not

**Severity: architecture correction before the plugin SPI is widened.**

A structural event stream is a useful adapter into a shared tape. It is not a universal storage-access model.

- Delimited text and Avro object containers can be consumed sequentially.
- A nested JSON/XML record selector must understand parser state before it can identify record boundaries;
  the current raw-byte `DataFramer` cannot generally perform that job.
- Parquet readers read footer metadata and then navigate selected column chunks. The official
  [Parquet file-format documentation](https://parquet.apache.org/docs/file-format/) describes this
  metadata-first, column-oriented layout. A forward-only `FlatDataStream` is the wrong mandatory seam.
- Ordinary protobuf wire messages do **not** carry their schema and are not even self-delimiting as a stream.
  They require a `.proto`, a descriptor set or an explicit self-describing envelope; see the official
  [Protocol Buffers techniques documentation](https://protobuf.dev/programming-guides/techniques/).

Define storage capabilities beneath readers, for example sequential bytes, seekable/range-readable content,
and native row/object cursors. The existing Report pipeline can become the sequential framed-reader adapter.
New readers should not be forced through `DataFramer` merely to share the `DataValue` they produce.

The event vocabulary itself also needs to distinguish a **record boundary** from a nested record/object node.
`startRecord` currently appears to mean both. A tape builder can consume structural events, while a format
reader separately decides which completed node is one cursor item.

**Recommendation:** unify at the emitted value/access interface, not at the lowest byte-parsing mechanism.

## F5 — the runtime `DataValue` contract is missing

**Severity: blocking before accessor generation.**

The document says consumers stop choosing between `payload` and `flat` and ask an accessor, but it never
defines where that accessor lives. Today `DataCursor` emits `Any?`, while `JobMessage` contains only mutable
`payload` and `flat` fields. Neither carries a backing representation, active union case, effective type or
access object.

Define the runtime value contract before generating Kotlin against it. It must answer:

- Is the effective type cursor-wide/lane-wide, or may it vary per value?
- How are missing, null and decoding failure observed distinctly?
- How does a Union expose its active case?
- How is a nominal object projected structurally without eagerly invoking getters?
- How does a Formula append fields or replace the root while keeping one authoritative value?
- What is the dynamic syntax? Kotlin cannot resolve an unknown `.field`; unknown structure needs an explicit
  lookup such as `value["field"]`, followed by typed/coercing conversion methods.

Generated *accessor façades* over a tape are sufficient for typed expressions. Generating a materialized JVM
domain class for every structural schema is a separate capability with classloader/metaspace and identity
costs. It should land only with a concrete consumer that requires a nominal object, not as the symmetric half
of reflection by default.

Nominal reflection also needs a member policy: Kotlin properties versus JavaBean getters/fields, visibility,
serialization-name annotations, generic substitution, plugin classloaders, side-effecting getters and cycles.
“Lazy and depth-1” controls traversal depth but does not decide which members form the structural view.

**Recommendation:** add `DataValue` / `ValueAccess` and nominal-projection decisions to the design before
`CalculatedColumnEval` is generalized.

## F6 — the zero-allocation claim needs a precise boundary and lifetime protocol

**Severity: blocking before the tape API is frozen.**

`FlatFileRecord` proves that scalar text and cached numeric reads can avoid allocation. The Job file lane does
not currently prove zero allocation per record: `FileDataCursor.fill()` calls `event.row.prototype()` for
every emitted row, and `DataReadCore.message()` allocates another projected record in the superset path.

The design must say which invariant is intended:

- zero allocation inside parsing into a reusable slot;
- zero allocation per scalar read after a record exists; or
- zero allocation per record end-to-end through Job channels.

The third requires a release/pool protocol. Messages can be batched, queued, forwarded, sorted or retained;
ownership transfer permits mutation but does not say when the backing arrays may return to a pool. An
allocation assertion without that lifecycle will either fail immediately or pin only the parser while being
described as a lane-wide property.

The proposed “one contiguous scalar buffer” is also text-shaped. Avro and Parquet expose encoded or decoded
primitive values that should not be round-tripped through characters. A shared tape may need typed primitive
buffers alongside byte/character spans. Decimal access may allocate a `BigDecimal`; binary and temporal
decoding have different cache requirements; `cachedDoubleOrNan` cannot implement exact integers or decimal
precision.

In Kotlin, a `(buffer, start, end)` tuple would itself allocate. The actual accessor must use separate methods,
an out-parameter/caller-owned scratch object, or another representation whose allocation behavior is tested.

**Recommendation:** state the measured boundary, benchmark it, and design value release before claiming the
flat Job lane is zero-allocation.

## F7 — format, record selection and schema are three composable concerns

**Severity: important before format objects land.**

`TreeFormat { codec, recordPath, schema }` combines concerns with different reuse and identity:

- **codec/dialect** — JSON, XML, Avro, CSV quoting and delimiters;
- **record selection** — `$.items[*]`, an XML path, lines, blocks;
- **logical schema and text decoding** — field types, null tokens, temporal patterns, locale and overflow
  policy.

There is also a representation concept immediately above the codec that the design currently models only
indirectly. `DataPart.format` plus `DataPart.encoding` is a less systematic reconstruction of a media type and
its parameters: `application/json` / `text/csv` identify a representation family, while `charset` is a
media-type parameter where that subtype defines it. HTTP `Content-Encoding` is a separate transformation
layer such as gzip and should not be conflated with character encoding. A source such as HTTP or S3 may
already supply a media type as object metadata, so discarding it and repeating the conclusion as a plugin
coordinate loses useful provenance.

Media type, configured format and `DataType` remain separate axes:

```
bytes + media type/content encoding
    -> configured codec/dialect/record selector
    -> DataValue + structural DataType
    -> optional nominal JVM projection
```

The relation is many-to-many: one structural type can be represented as JSON, XML, Avro or Parquet, while
`application/json` can carry innumerable structural types. A domain subtype such as
`application/vnd.example.order+json` adds a nominal representation identity and a `+json` syntax hint, but
still does not replace a field schema or JVM type. The format capability should advertise which media types
it accepts/emits; media type should help select a format, not become the format configuration itself.

A systematic `DataPart` representation contract therefore needs to distinguish an optional declared/detected
media type, any content coding, and an explicit configured format reference. The current `encoding` should be
renamed to its actual role (for example character encoding) or absorbed into the effective media-type/codec
configuration. Resolution should prefer an explicit format, then a trustworthy declared media type, then
content/magic detection, extension and finally fallback. Arbitrary kzen knobs such as delimiter and
`recordPath` should not be invented as private MIME parameters.

A JSON codec can be reused across many record paths and schemas. A dataset schema is usually source-specific,
not an intrinsic property of JSON. Conversely, fixed-width layout is physical schema: offsets, widths,
padding, alignment and overflow are needed to parse it. `DelimitedTextFormat` does not “immediately buy”
fixed-width.

`TreeFormat.codec: json | xml | yaml` also risks a central closed `when`, contrary to CC-17. A codec should be
a contributed capability/reference so a plugin adds one without editing the generic format engine.

The phrase “custom formats specified in the UI” needs a narrower promise. The proposed objects let users
configure instances of supported format families. They do not let a user define an arbitrary EDI, log or
binary grammar. The latter requires a parser-combinator/grammar DSL, bounded execution and a diagnostic
model. “Configurable format instances” is already valuable and should be the first explicit target.

**Recommendation:** add media type/content coding as representation metadata, then compose codec, record
selector and schema/decoding policy beneath it; defer arbitrary grammar authoring until it has its own design.

## F8 — a format object reference changes manifest identity

**Severity: correctness issue for runs, migration and schema caching.**

Today `DataPart.digest()` hashes the coordinate string. If `DataPart.format` becomes a graph-object reference
and the referenced object's contents change, an identical manifest can open differently without changing its
digest. The same defect reaches the schema-cache key and live-run migration.

Choose one:

- Snapshot the effective immutable format configuration into `DataPart`; or
- Carry the object reference plus its resolved definition digest/version in `DataPart`.

The opener must use that captured effective configuration rather than resolving mutable current graph state
halfway through a run. A reference being text does not make the digest contract unchanged.

Format discovery also needs deterministic default selection when several configured instances claim the same
extension. “Compatible with a type” cannot be the sole selection rule because the format may be needed to
discover that type. Separate selection hints—extension, media/magic detection, explicit source default and
priority—from post-selection schema validation.

**Recommendation:** define immutable effective-format identity before changing `DataPart.format`.

## F9 — provider-bound reading needs a content-access capability

**Severity: architecture gap; independent of the type work.**

The selection/processing split is correct, but supporting S3 requires more than removing two throws.
`FlatDataSource` accepts `FlatDataLocation`, exposes only sequential reading and size, and receives neither the
full provider-bound `DataRef` nor a context/client. The runtime also needs to resolve `DataSourceId` to the
provider instance that owns credentials and resource lifetime.

The missing seam is approximately “open this resolved ref as content,” with capabilities such as sequential
and range/seek access. It should take the complete `DataRef`, retain cancellation/close ownership and allow
the provider to borrow its client/context. Parquet over S3 is the forcing case: selection remains independent
from parsing, but the parser needs range access supplied by the provider.

This does not invalidate `DataSource.resolve -> DataManifest` versus `DataOpener.open -> DataCursor`. It adds
the provider-aware content layer needed for that split to work beyond local files.

**Recommendation:** design `DataRef` content access and provider resolution with the first provider-bound
source; do not describe the current `FlatDataSource` as already sufficient.

## F10 — the Worker type-flow migration is absent from the plan

**Severity: blocking for the proposed build order.**

`WorkerLane` is another manifestation of the same two-world model: `payloadType` plus `flatColumns`.
Replacing `DataShape` without replacing Worker-lane typing leaves the most important disjoint union intact.

Each Worker needs a type transformation contract:

- filters preserve the input type;
- formulas may append record fields and/or replace the root;
- pivots, sorts, summaries and writers require particular structural capabilities;
- a boundary lowers a structural value to a declared Logic result type;
- dynamic input weakens validation without making execution impossible.

`JobMessage` mutation is particularly important. `FormulaWorker` can currently append to the flat record and
replace `payload` in the same call. Under one-value semantics there must be one authoritative result and one
output `DataType`, not two representations that can drift.

Step 1 therefore cannot be “pure model, no runtime,” and accessor generation should not precede the value and
Worker contracts it targets. This is not an argument for compatibility shims; it is an argument for grouping
the real consumers into the same replacement phase.

**Recommendation:** schedule `WorkerLane`, `JobMessage`, boundary lowering and expression generation as one
coherent runtime phase.

## F11 — duplicating the recursive type tree in the plugin contradicts “one language”

**Severity: design choice before the public SPI changes.**

Mirroring `PluginCoordinate` / `CommonPluginCoordinate` is tolerable because the value is one string. Mirroring
a recursive type system means two sealed trees, two serializers, two equality/digest implementations and an
exhaustive conversion that must change for every new type feature. That is exactly the split the design is
trying to remove.

Prefer a small canonical schema artifact usable by both `kzen-auto-common` and `kzen-auto-plugin`, or another
dependency arrangement that leaves one model. If module constraints make a JVM SPI representation necessary,
name it as an SPI transport projection and pin lossless conversions exhaustively; do not describe the result
as one type language without acknowledging two representations.

Because there is no compatibility obligation, the current dependency-free plugin-module constraint may be
reconsidered if it creates a permanently duplicated foundation.

**Recommendation:** resolve module ownership before ST8 defaults to duplication.

## F12 — inference, validation failures and resource limits need first-class policies

**Severity: required before the first inferred or tree format ships.**

Sampling needs more than a record count:

- byte/time/depth/field-count budgets;
- deterministic field ordering;
- numeric promotion and overflow rules;
- empty/null-only collections;
- optional-field inference when a field appears in only some samples;
- a policy for widening into Union versus Dynamic;
- cache keys that include effective format, selector, schema and inference configuration.

Declared typing also creates data-quality failures that do not exist while everything is text. The runtime
must define whether a malformed value fails the part, skips the record, substitutes null/default, or enters a
quarantine/error lane, and diagnostics need source, unit, record and path locations.

Tree readers require defensive limits: maximum nesting, record size and collection size; XML external-entity
disablement; YAML alias expansion limits; protobuf recursion limits; and selector/regex execution bounds.

Finally, writer and round-trip support is ambiguous. §5 discusses XML round-trip loss, but the build order is
reader-only. Either declare structured writing out of scope or define writer capabilities, ordering, variant
discriminators and preservation of native schema metadata.

**Recommendation:** add explicit inference, decode-error, security-budget and writer-scope decisions to the
register.

---

## Recommended decision changes

| Decision | Recommendation |
|---|---|
| ST1 | **Resolve to `Scalar(Text)`** for undeclared delimited fields. No compatibility-driven coercion. |
| ST2 | Model tagged variants and nullable types deliberately; do not use an untagged list as the only sum type. |
| ST3 | Decide whether `DataType` is an access projection or lossless schema IR first. Keep XML-native details beside the projection if needed. |
| ST4 | Replace current `DataShape` cases, but retain a shape/observation envelope around `DataType`. |
| ST5 | Lazy nominal projection, plus an explicit member/naming/generic/classloader policy. |
| ST6 | Declaration is the contract; observation produces diagnostics through `DataShape`, never a silent override. |
| ST7 | Use a shared selector abstraction only if it can express a streaming-safe subset honestly; codecs may contribute their own selector dialect. |
| ST8 | Prefer one canonical type artifact over a duplicated recursive SPI tree. |
| ST9 | **Replace CSV/TSV coordinates atomically. Do not coexist for compatibility.** |
| ST10 | One shared structural access/tape implementation where representations agree; allow native typed/object backings behind the same access contract. |
| ST11 | Record count plus byte/time/depth budgets; return coverage and provisional status in the shape observation. |

Add decisions for field presence/nullability, scalar parameters, type joining/assignability, runtime value
lifetime/release, effective-format digesting, decode-error policy, provider content capabilities, dynamic
expression syntax, media-type precedence/content coding, writer scope and resource limits.

## Proposed build order

This sequence targets the clean end state directly; it does not preserve old internal contracts as shims.

1. **Semantic contract:** `DataType`, ordered `Field`, presence/nullability, scalar parameters, tagged variants,
   normalization, `accepts` and `join`, with wire/digest tests.
2. **Shape observation:** replace current `DataShape` with the provenance/stability/diagnostic envelope; update
   declared and inspected schema paths together.
3. **Representation and configured-format proof:** add media type/content coding with explicit precedence,
   then compose delimited codec/dialect, record selection and text-decoding policy; replace CSV/TSV coordinates
   and update all notation/fixtures in the same change. Capture effective-format identity in manifests and
   cache keys.
4. **Runtime value:** define `DataValue` / `ValueAccess`, lifetime and release; adapt `FlatFileRecord` as the flat
   backing and pin the exact allocation boundary.
5. **Job type flow and expressions:** replace `WorkerLane(payloadType, flatColumns)`, collapse authoritative
   `JobMessage` value state, define Worker transformations and generate typed/dynamic accessors.
6. **First structural reader:** JSON with a deliberately bounded, streaming-safe selector and explicit dynamic,
   declared and inferred cases.
7. **SPI validation:** Avro for sequential carried schema, then Parquet for columnar/range access before the
   reader/content SPI freezes.
8. **Provider-bound content:** implement provider resolution and range/sequential content access with the first
   S3-like source, reusing the format and value layers unchanged above it.
9. **Structured writers**, if in scope; otherwise record their exclusion explicitly.

## Checked and worth preserving

- Selection (`DataSource.resolve`) and processing (`DataOpener.open`) are correctly separate.
- `Record` and `Mapping` are semantically different and both belong in the type vocabulary.
- Unknown structure must remain executable through an explicit dynamic-access contract.
- Declared, carried and inferred schema are distinct provenance sources; declarations are contracts, not hints
  silently overwritten by samples.
- Compile-time name-path to ordinal-path resolution is the right fast path for known records.
- `FlatFileRecord` should survive as the optimized flat backing, even if its surrounding Job-lane lifetime
  changes.
- Configured formats and code-contributed codecs should resolve through the same capability-oriented graph
  mechanism.
- The first structural SPI must be tested against both a schema-carrying sequential format and a
  random-access columnar format before being called general.

## Editorial corrections to the analysis

- §1 says “Five forces” but lists six.
- References to “§2.4” appear to mean item 4 of §2; there is no §2.4 subsection.
- Protobuf should be removed from the list of formats that ordinarily carry their own schema.
- `DelimitedTextFormat` should not claim fixed-width support.
- “The UI change is small” should be withdrawn. Creating/editing graph format objects introduces naming,
  shared-versus-inline ownership, deletion, stale references and recursive schema UX.
- “Signatures stay the same” should say that the call sites/roles stay the same; changing the return type from
  `DataShape?` to `DataType?` is a signature change.
- “One interface, two implementations, no regression risk” should be replaced with a measurable claim after
  runtime value lifetime is designed. `FileDataCursor` and superset projection currently allocate/copy rows.
