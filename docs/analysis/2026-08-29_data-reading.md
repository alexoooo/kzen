# Configurable, provider-neutral flat-data reading

> **Status: proposed; review amendments incorporated** (reader capability runtime, canonical config wire,
> fingerprint handshake, exact Decimal, decode-override ownership, header/syntax semantics, operational budgets,
> no unused range/rows APIs), plus the 2026-09-01 `MapExecutionValue` usage audit (unordered map identity versus
> ordered list identity).
> This analysis selects configurable typed delimited text as the first consumer of the
> project-data analysis's configured-format and provider-content seams. It is an immediate typed-flat extension,
> not DM12's first structural reader. The external 100,000-row measurements file is an acceptance and performance
> canary only: no production symbol, branch, default, field name or built-in model may mention that file or its
> domain.

## 1. Decision in one page

The flat reader must be assembled from six independently replaceable layers:

```text
DataSource
  -> DataRef / DataPart
  -> provider-neutral content capability
  -> content-coding decoder(s)
  -> character decoder
  -> configured record reader
  -> DataCursor<DataValue> + DataContract
```

Each boundary has one job:

| Layer | Owns | Must not know |
|---|---|---|
| Source selection | Which objects to read, their roles, order, provider identity and content fingerprint | Delimiter state, typed field conversion |
| Content access | How an opaque `DataRef` supplies sequential bytes, ranges or native rows | CSV, gzip, charset, Job |
| Content coding | Transforming encoded bytes, such as gzip to plain bytes | Charset, record or field syntax |
| Character decoding | BOM, charset and malformed-character policy | Compression, delimiter, schema |
| Record reading | Framing records, tokenizing fields and decoding them under a schema | Filesystem paths, S3 clients, Job channels |
| Typed emission | Stable `DataContract` plus `DataValue` items and diagnostics | Provider, compression and character-decoder choices |

The first implementation needs only local and sequential content, but the reader-facing API is provider-neutral
from its first commit. A fake object-store provider proves that neutrality without adding a production S3 client,
credential model or browser. Local plain bytes, local gzip bytes, fake-S3 plain bytes and fake-S3 gzip bytes must
all reach the same configured delimited reader.

The layers are made executable by an explicit runtime reader capability: a registered component that owns its
namespaced identity and compatibility version, decodes/validates/canonicalizes its configuration, produces the
canonical config digest, declares its required content capability, inspects bounded samples and opens the cursor
(§4.7). A registry resolves it without a `when` over reader names, and one generic composition root performs the
fixed orchestration from resolved spec to cursor.

The configured format is an immutable resolved-read specification, not a mutable coordinate consulted again
during a run. Its identity includes the reader capability and version, complete dialect, schema, typed-decode
policy, content-coding chain, and character-decoding policy. A manifest or migration key combines that identity
with the selected object's fingerprint. The schema cache uses the same combination. Changing any input that can
change emitted values therefore changes identity.

The schema is a generic Custom-creatable record-schema capability. A document archetype may wrap that capability
for users who want a dedicated schema document, but sources and formats depend on the capability, not the wrapper.
Custom creation discovers prototypes by capability/inheritance rather than by the concrete string `Prototype`, so
schema, format and source prototypes inherit their implementation metadata instead of copying it.

Job carries the complete `DataContract` through validation, cards, connectors and expression compilation. It does
not reduce typed fields to `TypeMetadata + HeaderListing`. Declared fields get typed expression accessors; unknown
structure uses explicit keyed dynamic access. A calculated field's inferred type is appended to the output contract
instead of being unconditionally converted to Text.

### 1.1 Three authoring tiers

The layers exist to serve one product gradient: simple reads are immediate, intermediate reads are configurable
in the UI, and advanced reads are code.

| Tier | User action | What supplies the rest |
|---|---|---|
| Immediate | Select a file/ref | Built-in configured instances (RFC-4180 CSV, TSV) plus hint-based preselection; header labels observed; the contract is an observed `Record` of Text fields — `Dynamic` only where member structure is genuinely unknown |
| Configured | Author or adjust format/schema notation through the UI | The same configured reader; an inspection-driven schema draft can seed the declaration |
| Code | Contribute a reader capability, schema or source as a plugin or Logic | The same capability vocabulary; no generic branch changes |

The immediate tier must stay one selection. Built-in configured instances and extension/media-type preselection
make an ordinary `.csv` readable without authoring anything; the strictness in this document (declared schemas
for typed headerless input, fail-fast decoding) applies to the typed tiers and must not remove the untyped
immediate read.

## 2. Scope and non-goals

### 2.1 Immediate scope

This proposal covers:

- a provider/content boundary with sequential-byte capability (extensible capability identities; no range/row
  APIs until a named consumer exists, FR21);
- the runtime reader capability, registry and generic composition root (§4.7);
- a local sequential provider and a fake provider used to prove object-store composition;
- explicit plain/gzip content coding;
- explicit character decoding, including BOM and malformed-character behaviour;
- one configurable delimited-text reader with header and headerless policies;
- declared typed record schemas authored as ordinary notation;
- typed `DataValue` emission through the existing `DataCursor` and Job lane;
- complete resolved-spec fingerprinting for manifests, migration and inspection caches;
- capability-based Custom prototype discovery;
- Job/UI contract display and typed expression propagation; and
- small deterministic fixtures plus the opt-in external 100,000-row canary.

### 2.2 Deferred scope

The contracts must leave room for, but this work does not implement:

- a production S3 provider, credentials, retries, pagination or S3-specific browser;
- DM12 structural readers, structural tape, JSON selectors or inferred nested shapes;
- range-oriented formats such as Parquet;
- row-native providers such as JDBC;
- ZIP archive browsing and entry selection;
- fixed-width, regex, EDI or user-programmable parser grammars;
- structured writers; or
- a universal quarantine subsystem.

Those are distinct consumers. They must not be simulated by optional branches in the flat reader.

Deferring user-programmable parser grammars does not close the advanced tier: a code-authored reader capability
(the plugin SPI) and Logic-authored sources remain the escape hatch for anything the configured reader cannot
express, using the same capability vocabulary this document defines.

## 3. Current state and the gaps this proposal closes

The source/value foundation and unified data model already establish most of the outer contract:

- `DataSource.resolve` produces ordered `DataUnit` / `DataPart` values with opaque `DataRef`s;
- `DataCursor` is already `Iterator<DataValue>` and owns a `DataShape`;
- `JobLaneDescriptor` already names one canonical `DataContract` for a lane;
- `FlatFileRecord` already implements the optimized depth-one value backing; and
- source resolution is separate from opening.

The remaining flat path has five couplings:

| Current implementation | Consequence | Required correction |
|---|---|---|
| `DataOpenerLookup` sends plain refs to `FileDataOpener` and rejects every sourced ref | A reader cannot be proven over an object-store ref | Resolve refs to content capabilities before selecting a reader |
| `FileDataOpener.effectiveSpec` converts a ref to `DataLocation`; `FileFlatDataSource` is hard-coded below it | Filesystem representation leaks into content access | Local paths belong only to the local provider |
| Gzip is inferred and opened inside `FileFlatDataStream` | Content coding is entangled with one provider | Apply an explicit content-coding wrapper to provider bytes |
| `DataPart` carries a plugin coordinate and one `encoding` value; its digest hashes only those strings | A mutable format target or changed dialect/schema can reuse a stale manifest/cache identity | Capture and fingerprint the complete resolved read spec |
| `DataSchemaDocument` owns schema implementation as a document archetype | An embedded Custom schema must duplicate or depend on document machinery | Extract a generic record-schema capability and let the document delegate |
| `CustomConventions.listPrototypes` compares direct `is` text to `Prototype` | Subtypes and other creatable capabilities are invisible | Discover by inheritance/capability |
| `JobUpstreamSchema` and `DataSourceShapeStore` project observations to `HeaderListing` | The client loses field types and observation state | Carry `DataContract` / `DataShapeResult` to the final UI projection |
| calculated columns are appended as `Scalar(Text)` after rendering | Correctly inferred Kotlin types disappear downstream | Lift the calculated result as `DataValue` and append its inferred contract |

The old `CsvReaderWorker` and `MultiFileReaderWorker` also prove the necessary parser behaviour, but they are not
the generic composition point. They own paths and contain delimiter/header configuration directly. The configured
reader must replace that product surface atomically for this path; keeping both as long-term alternatives would
leave two competing answers to where format configuration lives.

This analysis extends, rather than replaces, the existing authorities:

- [data-source model](2026-08-20_data-source-model.md) owns refs, parts, manifests, open/inspect and cache intent;
- [Job data sources](2026-08-20_job-data-source.md) owns reader execution, migration and Job editing;
- [project data](2026-08-26_database.md) owns configured-format, provider and reader policy; and
- [unified data model](2026-08-27_data-model.md) owns `DataContract`, `DataValue`, access and lifetime.

## 4. Layered contracts

The sketches in this section describe responsibilities, not final Kotlin spelling. Package placement and exact
suspend/blocking boundaries should follow the first implementation's ownership, but dependencies must point in the
shown direction.

### 4.1 Source selection stays at `DataSource`

Local and future object-store sources have different configuration:

- a local source can expose directory, filter and selected-file controls;
- an S3 source can expose bucket, prefix, selected keys, version selection and pagination; and
- a Logic source can return refs calculated by user-authored Logic.

They still resolve to the same ordered values:

```kotlin
DataUnit(
    attributes = ...,
    parts = listOf(
        DataPart(role, opaqueRef, resolvedReadSpec)
    )
)
```

`DataRef.id` stays opaque. The local provider alone interprets a plain ref as a path. An S3 provider alone
interprets its sourced ref as bucket/key/version addressing. `DataRef.attributes` may carry provider-produced
display and fingerprint metadata, but no reader reads those provider-specific keys.

Resolution produces a stable point-in-time manifest. It must not reopen browsing or re-run a prefix query while a
cursor advances. The source owns ordering and missing-object policy; the reader receives one selected part at a
time.

Format-to-part assignment is source-owned and deliberately simple in v1: a source names one configured format,
and resolution stamps that format's resolved spec onto every part it produces, so multiple files grouped by
date read identically. Per-part or per-role overrides stay open in the model — the resolved spec already
travels on `DataPart`, so a differently-configured source can assign different specs without a contract change —
but no override surface ships until multi-part use cases demand one.

### 4.2 Content access resolves refs to capabilities

Introduce one boundary approximately shaped as:

```kotlin
interface DataContentProvider {
    suspend fun describe(context: DataContext, ref: DataRef): DataContentDescriptor
    suspend fun openSequential(context: DataContext, ref: DataRef): SequentialByteContent
}

data class DataContentDescriptor(
    val capabilities: Set<DataContentCapability>,
    val fingerprint: DataContentFingerprint,
    val length: Long?,
    val mediaTypeHint: String?,
    val contentCodingHint: String?
)
```

Only supported access is callable. An implementation may instead return a typed capability object rather than a
set plus methods; the invariant is that unsupported access fails before parser work starts, and the reader declares
what it requires. The initial delimited reader requires `SequentialBytes`.

**Only `SequentialBytes` ships.** The capability *identity* vocabulary is open-ended — a later Parquet reader can
require a range capability and a relational reader can require rows without pretending its values were bytes — but
no range or row interface, method or type is declared until its first named consumer exists with actual lifetime,
batching, seek/version and cancellation requirements. Declaring them now would fix APIs without evidence. The
generic required-versus-available mismatch path is proven with a test-only unknown capability identity instead.

`SequentialByteContent` is a provider-neutral handle. It may adapt JVM `InputStream` / channels internally, but it
exposes no `Path`, AWS SDK type, bucket, HTTP response or provider client. Its owner closes it. Acquisition binds
the handle to one observed content fingerprint or immutable version for its whole lifetime, so a handle cannot
silently switch object versions mid-read (§5.2 defines the expected-versus-observed handshake).

A `DataContentProviderLookup` performs the only dispatch:

- `ref.source == null` selects the local/plain provider;
- a sourced ref resolves its durable `DataSourceId` to the provider instance; and
- an unknown provider fails with a source diagnostic before any reader is constructed.

This dispatch is by source ownership, not by a concrete provider check inside parsing code. The configured reader
cannot ask whether content is local or S3.

The first fake object-store provider should be intentionally unlike the local provider at its boundary: opaque
bucket/key-like ids, an object fingerprint, and bytes held behind the provider API. If the test passes only by
turning its id into a temporary `Path`, it has not proved the contract.

### 4.3 Content coding wraps byte capabilities

Content coding is an ordered transformation from bytes to bytes. The resolved spec names it explicitly:

```text
provider bytes -> gzip decoder -> decoded bytes
```

For the first implementation, the supported chain is `none` or one `gzip` decoder. The type should still permit a
list if composition is real and bounded; it must not claim arbitrary chains that cannot be validated or safely
opened.

Filename extensions, provider metadata and magic bytes may suggest a default while the source/format is being
resolved. They do not remain runtime precedence rules. By cursor-open time the resolved spec says `none` or
`gzip`, and its digest includes that answer. Otherwise renaming an identical object or changing a provider hint can
change interpretation without changing manifest identity.

Gzip is a transparent byte wrapper because it represents one logical content stream. ZIP is different: it is a
container with entry names, ordering, metadata and potentially several independently selectable contents. A future
archive source/browser resolves selected entries into `DataPart`s. Treating ZIP as a transparent decoder would
discard the very selection boundary `DataPart` exists to express, and would encourage unsafe implicit entry choice.

### 4.4 Character decoding is separate from coding and syntax

The character-decoding spec contains at least:

- charset selection (`UTF-8`, `UTF-16LE`, `UTF-16BE`, or another installed charset);
- BOM policy (detect/permit/require or reject conflicts);
- malformed-input policy; and
- unmappable-character policy where the platform distinguishes it.

`REPORT`/fail is the safe default. Replacement is allowed only when explicitly authored and must identify the
replacement behaviour in the resolved spec. Silent ignore is not a safe product default because it can merge
tokens and change keys. If retained as an expert option, it receives its own explicit value and tests.

BOM handling must have one deterministic precedence rule. Recommended:

1. an explicit endian-specific charset must agree with any BOM;
2. generic `UTF-16` uses a BOM when present and otherwise follows one documented default or fails, never platform
   default;
3. a detect-from-BOM mode fails when no supported BOM exists; and
4. the BOM is consumed as encoding metadata, not emitted into the first field.

The resolved charset and BOM policy, not merely the author's pre-resolution `auto` value, enter the resolved-spec
fingerprint. Character failures are reported with source/part and byte-offset context. They are distinct from a
well-formed character sequence whose field text cannot be decoded as the declared semantic type.

The character decoder is a contract, not necessarily a physical `Reader` layer: an implementation may fuse
decoding with byte-level tokenization (just as framing and tokenization share one state machine) provided BOM,
malformed-input and failure-offset behaviour remain exactly as specified. The tuned flat path is byte-oriented
today and should stay eligible.

### 4.5 The configured record reader owns framing and fields

One Custom-authored configured format composes:

- reader capability identity and compatibility version;
- record-framing policy;
- field dialect;
- header policy;
- record schema; and
- typed-value failure policy.

For delimited text, the dialect includes at least delimiter, quote, escape convention, record separator policy,
empty-field semantics and any trimming rule. A one-character delimiter can be the first implementation constraint;
it must be validated when the notation object is defined, not silently truncated as today's `CsvRecordReader`
does. Quote and escape may be disabled explicitly. Defaults may describe RFC-4180-style CSV, but CSV and TSV are
configured instances, not branches in the reader.

Record framing and field tokenization are conceptually distinct but may share one parser state machine. They must
share state for delimited text because an apparent newline inside quotes is field content, not a record boundary.
A generic `lineSequence()` wrapper followed by a CSV tokenizer cannot satisfy this contract.

Header policy is explicit:

| Policy | Field identities | First physical record |
|---|---|---|
| Header present | Read labels, map against a declared schema when present (rule below) | Consumed as metadata |
| Header absent | Taken from the declared ordered schema | Emitted as data |
| Infer labels | Generated positional labels only when no declaration exists | Emitted as data |

Header-to-schema mapping is explicit, not "validate/project" left open. The default for a header-bearing declared
read is **name-based mapping with exact set equality**: every declared field name must appear exactly once in the
header and vice versa; physical reordering is permitted (the mapping resolves each declared field to its observed
column ordinal once, at open time); comparison is case-sensitive with no normalization beyond the configured
trimming rule. Missing, extra or duplicate header labels fail with a diagnostic naming the labels. Any tolerant
variant (ignore-extra, case-insensitive, normalized) is a named policy value. Because these choices change emitted
values, the mapping policy is part of the resolved configuration and its digest.

The recommended typed-flat product requires a declared schema for headerless typed input. Positional labels remain
an honest dynamic/Text fallback for an undeclared ad-hoc read, but they are not a substitute for a two-field typed
contract. Automatic header guessing is excluded: a first data row is often indistinguishable from labels.

Width, duplicate-label and missing/extra-field policy belong to the configured reader. The immediate default is
strict width and unique field identity. Any tolerant projection must name its behaviour and produce diagnostics;
it cannot silently shift values after a missing delimiter.

Malformed record *syntax* is its own failure category, distinct from malformed bytes (§4.4) and from typed-value
conversion (§4.6), with its own diagnostic kind and a strict fail default. The defined syntax failures include at
least: an unterminated quoted field at end of input; a quote inside an unquoted field; unexpected characters after
a closing quote; and a bare CR or mixed record separators outside the configured separator policy. The dialect
also pins two easily-ambiguous behaviours deterministically: empty input yields zero records (it is not one blank
record), and trimming applies to unquoted values only unless a quoted-trim policy is explicitly configured.

### 4.6 Typed decoding emits the existing value contract

The reader emits one `DataValue` per logical record under one `DataContract`. Flat data continues to use the tuned
`FlatFileRecord`/flat `ValueAccess` backing; this work does not introduce structural tape. A declared schema makes
each field's semantic type authoritative, so a decimal field is a decimal accessor, not Text with a UI-only type
label.

Typed decoding needs decode options, not only a failure policy. Following the project-data schema/decoding-policy
composition, the configured format carries at least a null-token rule and (as types are added) numeric
grouping/locale, temporal patterns and boolean tokens — format-level defaults with per-field overrides. **Decode
overrides are reader-config-owned, not schema-owned**: `RecordSchema` stays purely semantic (§6.1), and
`DelimitedReadConfig` carries every decode override, keyed by field path. Reader-specific concepts such as numeric
token patterns never leak into the reader-neutral schema. The first cut needs only the null-token rule and
locale-free numeric parsing, but they are named, resolved into the resolved spec and digested like every other
member: two formats differing only in null token are different identities.

The first implementation supports an explicit kind matrix: Text, bounded integers, Floating, Decimal and Boolean.
Temporal and binary kinds are deferred; format resolution rejects a schema containing an unsupported kind before
any content is opened, rather than failing per-value at runtime.

Decimal is exact end to end. The reader validates and stores canonical exact decimal text; `scalar()` remains the
complete lossless representation; generated accessors construct/project `BigDecimal` from that canonical value;
JVM native scalar binding accepts `BigDecimal` without passing through `Double`; and Job boundary/materialization
code must not flatten Decimal to binary floating point (today `JobDataValues` routes `ScalarKind.Decimal` through
`readDouble` — that routing is corrected as part of this work, a named kzen-lib + kzen-auto change, not a DR6
discovery). Tests use values that expose precision loss, not only small exactly representable decimals.

Typed conversion failure occurs at the reader boundary early enough to attach source, unit, record index, field
path and offending-span context without retaining sensitive whole-record text. It must not be deferred until an
unrelated downstream expression happens to access the field.

The project-data analysis leaves several ST17 policies possible. For this first vertical cut:

- `fail-part` is mandatory and the default;
- `skip-record` may ship only with a counted diagnostic surfaced in trace/UI;
- null/default substitution is legal only when the field contract permits it and the configured policy names it;
- quarantine is deferred until a real lane/storage consumer defines its ownership and backpressure; and
- there is no universal `Invalid` runtime value.

If only `fail-part` is implemented initially, notation rejects the other policy values rather than accepting
no-op configuration.

The cursor's `shape` is the resolved observation. A declaration is `Declared/Stable`; an inferred header-only
shape is an observation with its honest provenance/stability. Runtime records are checked against the declared
contract rather than silently replacing it.

### 4.7 Reader capability runtime and composition root

`ReaderCapabilityIdentity` and capability-owned `ReaderConfig` are values; a runtime component makes them
executable. Each reader family contributes one capability implementation responsible for:

- its stable, namespaced identity and compatibility version;
- decoding, validating and canonicalizing its configuration from the generic envelope;
- producing the canonical configuration digest;
- declaring the content capability a resolved configuration requires;
- inspecting a bounded sample; and
- opening the cursor over an acquired provider-neutral handle.

A registry (or graph-discovered lookup) resolves the capability from its identity — never a `when` over reader
names. One generic composition root then performs the fixed orchestration:

```text
resolve reader capability
  -> verify required content capability against the descriptor
  -> acquire provider content at the expected fingerprint/version (§5.2 handshake)
  -> apply content codings
  -> let the reader apply its reader-owned decoding/configuration
  -> transfer the completed stack to the cursor (§9)
```

Without this contract, `ConfiguredDelimitedReader` would become another directly wired special case even though
its configuration carries a generic identity — the very coupling §3 removes.

Identity collision rules: a reader identity is a logical name qualified by an owning namespace or plugin
coordinate, plus a capability-supplied compatibility token. A runtime class name is neither durable nor sufficient
across classloaders and never participates in identity. Registering a second capability under an existing
identity fails loudly at registration, not at first open. The capability SPI lives where third-party readers
compile against it (module ownership is confirmed at DR1 start, since it determines the cross-repo publication
chain).

## 5. Resolved-read identity

### 5.1 One immutable resolved specification

Use one immutable value approximately containing:

```kotlin
data class ResolvedReadSpec(
    val reader: ReaderCapabilityIdentity,
    val contentCodings: List<ContentCodingSpec>,
    val readerConfig: ReaderConfig
)

data class DelimitedReadConfig(
    val framing: RecordFramingSpec,
    val dialect: FieldDialectSpec,
    val header: HeaderPolicy,
    val characters: CharacterDecodingSpec,
    val schema: RecordSchemaSnapshot?,
    val typedDecode: TypedDecodePolicy
): ReaderConfig
```

The snapshot contains resolved values after defaults and references have resolved. It is not a live graph object.
Two safe representations are acceptable:

1. embed the canonical immutable snapshot in `DataPart`; or
2. carry a reference plus a resolved definition digest/version and retain the resolved snapshot in run state.

The opener must never resolve the mutable reference a second time midway through a run. The resolved spec's
canonical digest includes every member. Collection order is represented deliberately rather than inferred from
whichever concrete collection happens to retain insertion order.
Reader capability identity includes a compatibility/version token supplied by the capability, not an unstable
runtime class name alone.

The canonical wire form is **canonical `ExecutionValue`**. An arbitrary plugin-owned `ReaderConfig` subtype cannot
ride a wire of concrete `format`/`encoding` strings (today's `DataPart`) or a closed polymorphic serializer, so
the boundary is:

- **generic envelope**: reader identity, content-coding specifications, canonical reader-config data
  (`ExecutionValue` tree) and its digest — understood without loading the reader implementation;
- **capability boundary**: the reader capability (§4.7) decodes, validates and canonicalizes that data into its
  runtime configuration type;
- **common/client wire**: carries only the canonical envelope; and
- **run state**: the validated immutable runtime snapshot, resolved once.

`ExecutionValue` is chosen because kzen-lib's digest machinery is common-code and its typed scalar/null variants
avoid bespoke JSON canonicalization. Its collection contract is explicit:

- `MapExecutionValue` is an **unordered** string-keyed association. Map equality and digest ignore entry iteration
  order. A supplied insertion-preserving map may retain order for serialization or display, but that order is not
  functional and cannot affect cache, migration or config identity.
- `ListExecutionValue` is ordered. Reordering elements changes equality/digest and therefore semantic identity.
- ordered key/value entries are represented as a `ListExecutionValue` of entry maps. A distinct
  `OrderedMapExecutionValue` is introduced only when a named consumer requires both keyed lookup and semantic
  entry order.
- an absent map member and an explicitly present `NullExecutionValue` remain different configurations.

The 2026-09-01 usage audit covered all direct `MapExecutionValue` producers and consumers in kzen-lib and
kzen-auto (with no uses in kzen-project, kzen-launcher or kzen-shell). They are named-field envelopes,
dictionaries, or record/mapping payloads whose semantic ordering already lives in a `ListExecutionValue` or the
ordered `DataType` definition. Ranked matches and ordered manifest units likewise use lists. No current use needs
ordered associative identity, so adding an ordered-map subtype now would be speculative. DR1 runs fixed digest
vectors on JVM and JS to establish cross-platform stability; this is a tested contract, not an incidental property
of a map implementation.

**Transition rule**: replacing `DataPart` identity is not done as additive shadow state alongside an unmodified
opener — two simultaneous sources of truth is exactly the dual mode this arc's stop rules prohibit. The identity
session includes the minimum opener integration needed to make the resolved snapshot canonical immediately;
today's coordinate-string `format`/`encoding` members and their digest are replaced, not shadowed.

`ReaderConfig` is capability-owned and canonically digestable; the envelope's only generic members are reader
identity and content codings. Each reader family contributes its own config type — a JDBC or Parquet reader's
config has no `characters`, `header` or `framing` member at all — and `DelimitedReadConfig` is the delimited-text
family's, whose record selector is trivially "each record". This keeps the spec aligned with the project-data
composition of codec/dialect, record selector and schema/decoding policy without forcing every future reader
through text-shaped fields. (The project-data analysis calls this snapshot the effective configured format;
"resolved" names the same concept once defaults and references have settled.)

### 5.2 Content fingerprint and read-spec fingerprint are different identities

The selected content fingerprint answers “did the selected bytes/object change?”:

- local may use canonical ref id + size + modified time initially;
- S3 may use version id, or ETag plus size when its provider defines that combination as stable; and
- another provider may use its own opaque canonical token.

Size plus modified time is an explicitly **weak freshness token**, never described as a content digest. Providers
that offer immutable version IDs use them.

A resolved fingerprint is only useful if opening verifies it — a local file can change between resolution and
cursor construction, and the same race exists for an unversioned object-store ref. The handshake is therefore:

1. `DataPart` carries the fingerprint expected from resolution;
2. acquisition returns a handle bound to an observed fingerprint or immutable version;
3. the composition root compares expected and observed identity before any parser work; and
4. a mismatch fails with a source diagnostic and requires re-resolution — it is never cached or parsed under the
   stale identity.

For local files, the first implementation opens the file handle and validates its attributes against the resolved
fingerprint. The acceptance matrix mutates a file between resolve and open and proves stale identity is rejected.

The resolved-read digest answers “would the same bytes be interpreted the same way?” They combine into the
semantic part identity used by manifests and as the base for caches/migration:

```text
part identity = role + canonical ref + content fingerprint + resolved-read digest
```

Operational policy is intentionally layered onto that base rather than folded into it (§9.1): live-cursor
compatibility also requires equal effective run-policy identity, and an inspection-cache key also includes the
effective inspection-policy identity.

Changing any of the following invalidates inspection and migration compatibility:

| Change | Why values/shape may change |
|---|---|
| Object fingerprint | Bytes changed under the same ref |
| Reader capability/version | Parsing semantics changed |
| Delimiter, quote, escape, framing or header policy | Record/field boundaries changed |
| Schema or typed-decode policy | Field identity, type or acceptance changed |
| Content coding | Different bytes reach character decoding |
| Charset/BOM/malformed-character policy | Different characters or failure behaviour result |

Extension, media type and provider name are not independently included after they have resolved to the same
resolved values. They are selection inputs, not semantic identity once resolution is complete.

### 5.3 Migration compatibility

A live cursor may transfer across an edit only when the selected part identity (which includes the resolved-read
digest) and effective run-policy identity are equal. A delimiter, schema, gzip, charset or safety-limit edit
restarts rather than adopting the existing parser position. This is stricter than comparing a format coordinate
and prevents a cursor parsed under one dialect or operational limit from continuing under another object that
happens to share the same reference.

## 6. Schema and Custom authoring

### 6.1 Extract the schema capability from its document wrapper

`DataSchemaDocument.shape()` currently contains the reusable operation but couples it to `DocumentArchetype`.
Split the roles:

```kotlin
interface RecordSchema {
    fun contract(): DataContract
}

class AuthoredRecordSchema(...): RecordSchema

class DataSchemaDocument(
    private val schema: RecordSchema
): DocumentArchetype() {
    fun shape(): DataShape = declaredShape(schema.contract())
}
```

Exact names may change, but dependencies follow the capability:

- configured formats refer to `RecordSchema`;
- sources that declare a result refer to `RecordSchema`;
- shape inspection consumes `RecordSchema.contract()`;
- a dedicated schema document wraps or contains a schema; and
- a Custom document can contain the same `AuthoredRecordSchema` implementation directly.

The ordered field model remains `DataContract(DataType.Record(...))`, including native metadata rebased by path.
No new parallel `ColumnType` model is introduced.

`RecordSchema` is purely semantic: `contract(): DataContract` and nothing reader-shaped. Per-field decode
overrides (null tokens, numeric patterns and the like) live in the reader's own config keyed by field path
(§4.6), so the schema stays reusable by any future reader family.

### 6.2 Discover Custom prototypes by capability

The Custom “Add” catalogue currently scans for objects whose direct `is` text equals `Prototype`. That makes the
catalogue a concrete-name check and misses inherited capabilities. Replace it with graph capability discovery:

```text
candidate is CustomCreatable through its inheritance chain
and candidate contributes one or more capabilities such as
RecordSchema / ConfiguredRecordFormat / DataSource
```

`Prototype` may remain the base archetype that supplies `CustomCreatable`; the generic client must ask inheritance
membership or graph metadata, not compare a leaf name. A third-party subtype then appears without editing
`CustomConventions`.

Implementation and editor metadata live on the capability archetype. A creatable prototype inherits them and
supplies only author-facing defaults such as title, description and initial values. Creating an instance copies
configuration, not `class`, definer, creator or editor metadata. This prevents a schema prototype, a configured
format prototype and a source prototype from each duplicating the Kotlin implementation they share.

The catalogue should group/filter by contributed capability while retaining one generic creation mechanism. A
new capability adds one metadata declaration at its owning archetype, not a new branch in `CustomCreate`.
Generic catalogue code must not enumerate `RecordSchema`, `ConfiguredRecordFormat` and `DataSource` as a closed
set (and must not import them): it discovers a contributed creation descriptor/category — label, implementation
and editor metadata, creation defaults — from inherited graph metadata. The regression test contributes a
completely new test-only capability/category, not merely another `RecordSchema` subtype, proving both subtype
inheritance and open-ended category discovery.

### 6.3 Illustrative user-authored composition

The following is target notation for illustration; final attribute spelling follows the implemented archetypes.
Every object and field name is user notation. None is a built-in domain model.

```yaml
main:
  is: CustomDocument

TwoFieldSchema:
  is: AuthoredRecordSchema
  fields:
    key: String
    value: BigDecimal

SemicolonRecords:
  is: ConfiguredDelimitedFormat
  delimiter: ";"
  quote: '"'
  escape: doubledQuote
  recordSeparator: newline
  header: absent
  schema: TwoFieldSchema
  contentCoding: none
  characters:
    charset: UTF-8
    bom: permit
    malformed: fail
  typedMalformed: failPart

Input:
  is: LocalDataSource
  files: []
  format: SemicolonRecords
```

An author can point `Input.files` at any matching two-field data. A gzip variant changes only
`contentCoding: gzip`; an object-store source changes only `Input`. Neither change creates a new reader class or
changes expressions over `key` and `value`.

## 7. Browsing and source/format selection

Browsing stays outside the reader because it answers which refs exist, not how bytes become records.

| Browser | Request/response specifics | Common result consumed by selection UI |
|---|---|---|
| Local | Directory, filename filter, filesystem metadata | Page/tree of selectable refs and display metadata |
| S3 | Provider/source id, bucket, prefix, continuation token, object metadata | Page/tree of selectable refs and display metadata |

The generic detached browse protocol carries opaque selection values and pagination. The local UI may render
directories and the S3 UI may render buckets/prefixes, but both write source configuration that later resolves to
`DataRef`s. They do not hand a `Path` or AWS object directly to a format editor.

Source selection and format selection may share one composed UI:

1. browse/select refs through the source's browser capability;
2. select or create a configured format;
3. inspect a bounded sample through source → content → reader;
4. show the resulting contract and diagnostics; and
5. persist source and format notation separately.

Provider media type, extension and content-coding hints may preselect suggestions. The user-visible resolved
choice remains explicit, and inspection reports what was actually resolved.

Inspection may additionally offer a schema draft — field names and candidate types inferred from the bounded
sample — that the user materializes as an `AuthoredRecordSchema` and can then edit. Inference is an
authoring-time convenience that produces a declaration; it is never a runtime rung that silently types a read,
so runs stay deterministic under the declared contract.

## 8. Job, UI and expressions

### 8.1 Full contracts flow through Job validation

`JobLaneDescriptor.contract` is the authoritative value. Every Worker transformation consumes and returns a
`DataContract` (or an unavailable/error attempt), including source readers, filter preservation, projection and
formula append/replace. Legacy `payloadType` and `flatColumns` projections may remain only at a boundary that still
requires them; they cannot be input to the canonical walk.

The client-side source inspection path must likewise retain `DataShape`, not immediately call
`LegacyDataShapeBridge.headerOrNull`. Strict/superset operations combine ordered `DataField`s with their complete
contracts. A conflict reports the field/path and both contracts. It does not widen everything to Text merely to
keep a header list usable.

These states remain distinct:

- **available declared/observed contract** — show its field tree and provenance;
- **Dynamic** — execution is valid but member structure is unknown;
- **Unavailable** — no static or bounded observation was obtained;
- **error** — resolution, inspection or validation failed, with diagnostics; and
- **loading** — a UI request is outstanding, never persisted as a type.

### 8.2 Worker cards and connectors expose the contract

Cards and data-flow connectors show a compact summary such as `Record · 2 fields`, `Decimal`, `Dynamic`,
`Unavailable`, or `Error`. Expanding it shows:

- ordered nested fields and scalar kinds;
- optional versus nullable state;
- native facets where meaningful to the user;
- declared/carried/provider/inferred/runtime provenance;
- stable versus provisional observation and sampling coverage; and
- diagnostics attached to their field/path.

The same shared renderer should serve a source card, Worker output and connector hover/details surface. Features
contribute the contract; generic Job UI renders it. It must not branch on `CsvReaderWorker`, a source provider or a
particular schema archetype.

### 8.3 Expressions compile from `DataContract + DataValue`

For the illustrative contract, expressions receive typed accessors equivalent to:

```kotlin
val key: String
val value: BigDecimal
```

The generated accessor resolves field paths to ordinals once at compile time and reads each `DataValue` through
its `ValueAccess`. Provider, compression and charset do not enter generated code or the compile cache key; if they
produce the same contract, expressions are identical.

`Dynamic` exposes explicit keyed access such as `value["field"]` followed by explicit/coercing conversion. Kotlin
cannot safely synthesize `.field` for an unknown structure. A partially known record gets typed accessors for its
declared/inferred fields and dynamic access only at a node whose contract is actually `Dynamic`.

A calculated field is lifted under the Kotlin compiler's inferred result contract and appended through the
existing value builder. It is not rendered through `ColumnValue.toText` and declared as Text. This preserves, for
example, an arithmetic decimal result as Decimal for the next filter, card and connector.

Compile and runtime validation use the same contract keys already defined by the unified model:

- structural identity for generated structural access;
- declaration identity where native facets affect compilation; and
- resolved identity where classloader-bound native types participate.

## 9. Ownership, closing and cancellation

Opening constructs a wrapper stack:

```text
DataCursor
  owns configured parser
    owns character decoder
      owns content decoder (gzip or identity)
        owns provider content handle
```

Ownership transfers outward only after each layer constructs successfully. Closing the cursor closes the complete
stack exactly once, in reverse order. Exhaustion may close eagerly, but an explicit later `close()` remains safe.
Failure during construction closes every already-acquired inner layer and suppresses secondary close failures on
the primary failure.

Cancellation has two races to cover:

1. cancellation while the provider is acquiring the handle; and
2. acquisition completes while cancellation wins before ownership reaches the caller.

The provider/opening boundary follows the existing `FileDataOpener` rule: the acquiring side closes a handle that
was never returned. Once returned, the cursor owner closes on normal completion, failure, cancellation or rejected
migration. No wrapper captures a stale `DataContext`; the current owner drives blocking pulls through current run
control.

Tests use close-counting wrappers at every layer and assert one close per acquired resource. A finalizer or garbage
collector is never part of correctness.

### 9.1 Operational budgets

A streaming parser is not automatically memory-bounded: one unterminated quoted record can grow without limit, a
record can contain unboundedly many tiny fields, and a small gzip input can expand into a very large decoded
stream. The first implementation therefore carries every budget with a real failure mode:

- maximum expanded bytes emitted by the content-coding layer before character decoding, protecting both full
  reads and inspection from decompression expansion;
- maximum decoded characters per record and per field, failing with the record index and configured limit;
- maximum fields per record, applied before an undeclared/ad-hoc record can grow an unbounded field collection;
- cancellation checks inside long records and inside decompression, not only at record boundaries; and
- bounded inspection by records, expanded bytes and maximum elapsed duration, with cancellation/timeout checks
  inside acquisition, decompression and parsing. Record/byte exhaustion returns the deliberately bounded sample;
  elapsed timeout aborts inspection rather than returning a scheduling-dependent partial success.

Gzip integrity and trailing-data behaviour are deterministic and tested: a truncated or corrupt stream fails with
a content-coding diagnostic, and trailing bytes after the gzip stream are an error, not silently ignored.

Budgets are **execution policy, not semantic configuration**: they are excluded from the resolved-read digest
because they do not change values below the limit. They still have explicit operational identity:

- the effective policy digest participates in live-cursor adoption, so a cursor constructed under different
  limits is never transferred into the new run;
- the inspection-policy digest participates in the inspection-cache key because record/byte bounds can change the
  successful observed sample and inferred shape; the configured timeout duration participates too, but the
  derived wall-clock deadline instant never does; and
- a limit/timeout failure is never cached, so relaxing the policy cannot be defeated by a stale failure.

This distinction keeps semantic read identity stable without silently reusing an execution built under different
safety limits.

## 10. Acceptance matrix

### 10.1 Composition and provider neutrality

| Case | Setup | Required observation |
|---|---|---|
| Local plain UTF-8 | Local ref, `none`, UTF-8, configured delimited format | Expected typed values and declared contract |
| Local gzip UTF-8 | Local ref, `gzip`, same charset/format/schema | Same values and contract as plain case |
| Fake-S3 plain | Sourced opaque ref served by fake provider, `none` | Same configured reader instance/capability; no path conversion |
| Fake-S3 gzip | Same fake provider, gzip object, `gzip` | Same values/contract; provider has no gzip branch |
| Capability mismatch | Reader requiring a test-only unknown capability over a sequential-only handle | Fails before parser construction with required/available capabilities |
| Stale fingerprint | File mutated between resolve and open | Open fails with source diagnostic; stale identity never cached or parsed |
| Truncated/trailing gzip | Corrupt gzip stream; bytes after the gzip stream | Deterministic content-coding failure; trailing data is an error |

The fake provider test should fail if production parsing imports a filesystem or S3 SDK type. A focused dependency
or package test can pin that architectural rule in addition to behavioural tests.

### 10.2 Character decoding

| Case | Required observation |
|---|---|
| UTF-8 without BOM | First field contains no synthetic marker |
| UTF-8 with permitted BOM | BOM consumed, values unchanged |
| UTF-16 with BOM | Endianness resolved deterministically; values equal UTF-8 fixture |
| Explicit endian conflicts with BOM | Clear character-decoding failure before record emission |
| Malformed byte sequence with fail policy | Source/part and byte offset diagnostic; cursor closes stack |
| Malformed byte sequence with replace policy | Replacement is observable and resolved-spec digest differs |

### 10.3 Framing and tokenization

Small fixtures cover each behaviour independently and in combinations:

| Case | Required observation |
|---|---|
| Headerless input | First record emitted; declared schema supplies field ids/types |
| Header-bearing input | First record consumed as labels; labels checked against declaration |
| Quoted delimiter | Delimiter remains field content |
| Quoted newline | Physical newline remains field content and does not increment record index |
| Escaped quote | Configured doubled-quote/escape policy produces one quote |
| Empty field | Empty versus null follows configured null-token/schema policy |
| Final record without newline | Final field and record emitted exactly once |
| CRLF and LF | Both behave as configured, with no extra empty record |
| Wrong width | Strict diagnostic names record and expected/actual width |
| Malformed typed value | ST17 policy applied with record index and field path |
| Unterminated quoted field at end of input | Record-syntax diagnostic; no partial record emitted |
| Quote inside an unquoted field | Record-syntax diagnostic under the strict default |
| Characters after a closing quote | Record-syntax diagnostic naming the offset |
| Empty input | Zero records, not one blank record |
| Bare CR / mixed record separators | Behaviour follows configured separator policy; deviation is a record-syntax diagnostic |
| Trimming | Applies to unquoted values only unless quoted-trim explicitly configured |
| Oversized record/field | Budget failure (§9.1) names record index and configured limit; never cached |
| Too many fields | Field-count budget fails before retaining an unbounded record |
| Gzip expansion limit | Expanded-byte budget fails inside content decoding and closes the stack |
| Header reordered vs declaration | Name-based mapping resolves ordinals; values land under declared fields |
| Header missing/extra/duplicate label | Mapping failure naming the labels |
| Decimal precision | Values that a `Double` round-trip would corrupt survive exactly (§4.6) |

A useful checked-in headerless fixture is deliberately generic:

```text
alpha;1.5
"beta;two";2.75
"multi
line";3
```

Additional one- or two-record fixtures pin empty fields, escaping, final-no-newline, malformed bytes and malformed
numbers. Gzip fixtures may be generated deterministically from checked-in plain bytes during the test so the
semantic input has one canonical source.

### 10.4 Identity, inspection and migration

Start with a cached successful inspection, then change exactly one dimension per test:

- content fingerprint;
- delimiter/dialect;
- schema field name or type;
- typed-decode policy;
- content coding; and
- charset/BOM/malformed-character policy.

Each semantic change must miss the old schema cache entry and reject live-cursor adoption. Re-resolving an
unchanged graph to the same canonical snapshot must retain the key even if irrelevant notation or
`MapExecutionValue` insertion order changed; reversing an ordered config list must change it.

Operational-policy tests change one run/inspection limit at a time. The resolved-read digest remains equal, but
live-cursor adoption is rejected. An inspection records/bytes/configured-timeout change misses the
inspection-cache entry, and a prior budget/timeout failure is never reused after the policy is relaxed.

### 10.5 Resource lifetime

Exercise success, exhaustion, explicit early close, parser failure, character failure, typed-value failure,
cancellation during acquisition, cancellation during pull and incompatible migration. At every acquired layer:

- close count is exactly one;
- close order is outside-in;
- the provider handle is not retained after cursor close; and
- already-emitted `DataValue`s remain readable while reachable, per the unified data model.

### 10.6 Job/UI/expression propagation

An end-to-end Job test and a client projection test prove:

- the source output is `Record(key: Text, value: Decimal)`, not two Text headers;
- the same contract reaches downstream validation and the connector/card renderer;
- a typed expression using `value` compiles and runs without text coercion;
- a Decimal field reaches the expression as exact `BigDecimal` — no `Double` on the path (§4.6) — proven with a
  precision-losing value;
- a calculated numeric field retains its inferred numeric contract downstream;
- a `Dynamic` source requires explicit keyed access and still runs against each concrete value;
- Unavailable and inspection error render differently; and
- changing local to fake-S3 or plain to gzip does not change expression generation when the contract is equal.

### 10.7 External 100,000-row canary

The existing external measurements file is an opt-in integration/performance input, never a checked-in fixture or
built-in default. A generic canary harness accepts path/ref, configured format, expected row count and optional
performance threshold from test arguments. Its production dependencies see only the ordinary local source,
resolved format and record schema.

Acceptance for that invocation is:

- exactly 100,000 records;
- exactly the two user-authored fields under the configured schema;
- typed access to the numeric field;
- correct final record and aggregate/checksum chosen by the test harness;
- bounded streaming memory; and
- throughput recorded against the current flat-reader/Job baseline before deciding whether an allocation or
  buffering optimization is necessary — measured separately for parsing and for Job end-to-end, so a regression
  can be assigned to the reader, typed projection or lane machinery before optimization begins.

Automated CI relies on the small checked-in fixtures. Absence of the external file skips only the explicitly
labelled canary; it cannot turn ordinary reader tests green by skipping them.

## 11. Implementation sequence

This is a multi-concern design and should land through green vertical boundaries:

1. **Identity, reader capability and wire.** Add the resolved-read snapshot/digest, the reader capability/registry
   contract (§4.7), the canonical `ExecutionValue` config wire with unordered-map/ordered-list vectors, operational
   policy identity and fingerprint-handshake semantics (§5/§9.1), plus cache-key tests over canonical data —
   including the minimum opener integration that makes the resolved snapshot canonical (no shadow identity). Only
   content capabilities with an implemented consumer ship.
2. **Schema composition and Custom discovery.** Extract `RecordSchema` (purely semantic), delegate from the
   document, make source references capability-based, and change prototype listing to inheritance/capability
   discovery — tested with both a third-party schema subtype and a novel creation category.
3. **Sequential content stack plus minimal provider-bound proof.** Adapt local refs to provider-neutral sequential
   handles; add identity and gzip wrappers, expanded-byte/inspection limits, character decoding and
   close/cancellation tests; include a minimal opaque in-memory provider and sourced ref proving provider lookup,
   fingerprint verification and acquisition cancellation before the configured reader depends on the stack.
4. **Configured delimited reader.** Parameterize framing/dialect/header/schema, enforce record/field/field-count
   and inspection-record limits, emit typed flat `DataValue`s, and atomically migrate built-in CSV/TSV configured
   instances and fixtures. If one session is unsafe, split at the green boundary: an inactive but fully tested
   parser/typed-value implementation first, then archetypes, built-in instances and the atomic product cutover.
5. **Fake-provider conformance.** Run the same reader suite over opaque fake-S3 refs, including gzip, capability
   mismatch and cancellation — a full reader/provider conformance suite, not the first proof a sourced ref opens.
6. **Job/UI/expression cutover** — three independently landable green boundaries: (a) canonical
   `DataContract`/`DataShapeResult` propagation through server and client Job projection; (b) typed expression
   access and calculated-field contract retention (including the exact Decimal path); (c) shared contract
   rendering plus source/format/schema-draft authoring UI.
7. **Acceptance/performance gate.** Run focused fixtures (including stale-fingerprint rejection, syntax failures,
   every budget/policy-identity case and Decimal precision), full relevant sibling builds and the opt-in external
   canary; record parsing and end-to-end measurements separately before adding pools or leases.

The exact session split may change with dependency direction. Each step ends with one active canonical contract;
there is no long-lived “legacy CSV versus configured format” mode.

## 12. Explicit rejections

The following designs violate the composition boundary:

- a reader class, Worker, schema, default path or branch named for the measurements file or its domain;
- hard-coded field names or a hard-coded semicolon chosen from a filename/domain check;
- `if (provider is S3)` or `if (ref.source == ...)` inside parsing, gzip, character or expression code;
- reader APIs accepting `Path`, bucket/key or provider SDK objects;
- gzip hidden in the local provider or inferred again after the resolved spec is captured;
- ZIP opened by selecting the first entry implicitly;
- framing input with `readLine()` before quote-aware tokenization;
- direct-name checks in generic Custom prototype discovery;
- a second schema type parallel to `DataContract`;
- reducing the Job lane to `TypeMetadata + HeaderListing` before validation/UI;
- converting every calculated field to Text;
- silently accepting unsupported malformed-value policies;
- declaring range/row content APIs before their first named consumer exists;
- a `when` over reader names in place of the capability registry, or reader identity derived from a runtime class
  name;
- routing `ScalarKind.Decimal` through `Double` anywhere between reader and expression;
- treating `MapExecutionValue` iteration order as semantic identity, or encoding an ordered sequence as a map;
- generic Custom catalogue code importing or enumerating a closed set of creatable capabilities;
- parsing or caching content whose observed fingerprint does not match the resolved expectation;
- omitting the expanded-byte/record/field/field-count/inspection bounds, caching a limit/timeout failure, or
  adopting a cursor built under different effective safety limits; and
- adding leases, eager materialization or pooling without the specified lifetime/performance measurement.

## 13. Decisions and remaining implementation questions

| # | Decision | Answer |
|---|---|---|
| FR1 | First format | Configured typed delimited text; this is typed-flat work, not DM12 |
| FR2 | Provider boundary | Resolve opaque `DataRef` to advertised content capabilities; readers never receive provider types |
| FR3 | First provider work | Local sequential adapter plus fake provider proof; production S3 deferred |
| FR4 | Compression | Explicit content-coding layer; gzip wrapper now, ZIP as future container/parts |
| FR5 | Encoding | Separate character-decoding spec with deterministic BOM and malformed-input policy |
| FR6 | Format identity | Immutable canonical `ResolvedReadSpec`: reader identity + content codings + capability-owned reader config (for delimited text: framing, dialect, header, characters, schema, typed policy) |
| FR7 | Cache/migration identity | Semantic part identity is content fingerprint + complete resolved-read digest; inspection cache and live migration additionally require their effective operational-policy identity |
| FR8 | Schema ownership | Generic `RecordSchema` capability; document is an optional wrapper |
| FR9 | Custom discovery | Inheritance/capability-based `CustomCreatable`, never direct concrete-name equality |
| FR10 | Runtime values | Existing flat `ValueAccess`/`DataValue`; no structural tape |
| FR11 | Job contract | Complete `DataContract` through validation, UI and expressions |
| FR12 | Browsing | Source/provider capability outside the reader; local and S3 return opaque selectable refs |
| FR13 | External file | Opt-in generic canary only; no production knowledge or checked-in dependency |
| FR14 | Format-to-part assignment | One source-level format stamped on every part in v1; per-part overrides remain possible through `DataPart`'s carried spec, deferred until real multi-part use cases |
| FR15 | Reader capability runtime | Registered capability component + registry + generic composition root (§4.7); namespaced identity with compatibility token, never a runtime class name |
| FR16 | Canonical config wire | Canonical `ExecutionValue` envelope; capability decodes/validates; minimum opener integration makes the snapshot canonical immediately — no shadow identity |
| FR17 | Open-time verification | `DataPart` carries the expected fingerprint; acquisition binds an observed one; mismatch fails before parser work; size+mtime is a weak freshness token, not a digest |
| FR18 | Decode-override ownership | `RecordSchema` purely semantic; reader config owns all decode overrides keyed by field path; v1 kinds Text/Integer/Floating/Decimal/Boolean, unsupported kinds rejected at resolution |
| FR19 | Exact Decimal | Canonical decimal text in the backing; `BigDecimal` accessors and native binding; no `Double` on the path; `JobDataValues` Decimal routing corrected |
| FR20 | Operational budgets | Expanded-byte, record-character, field-character and field-count limits; bounded inspection records/bytes/timeout; budgets stay outside semantic digest but policy identity gates cursor adoption/inspection cache; failures never cached |
| FR21 | API restraint | Only `SequentialBytes` ships; range/row APIs wait for their first named consumer; mismatch path proven via a test-only unknown capability |
| FR22 | Execution-value ordering | `MapExecutionValue` is unordered in equality/digest; `ListExecutionValue` carries semantic order; ordered entry lists cover current uses, so an ordered-map subtype waits for a named consumer |

The implementation still needs to settle a few narrow details before its first code session:

1. whether provider-neutral sequential handles live in common code as small byte interfaces or in JVM code as
   wrappers over channels;
2. which module owns the reader-capability SPI (it determines the cross-repo publication chain — confirmed at
   DR1 start);
3. the exact BOM option names and generic UTF-16 no-BOM behaviour;
4. whether v1 exposes only `fail-part` or also fully implements `skip-record` and substitution;
5. the Custom UI ownership of shared versus inline configured formats; and
6. the measured baseline and acceptable regression threshold for the external canary.

(The canonical wire form, previously open, is settled by FR16: canonical `ExecutionValue` with a
capability-supplied compatibility token and namespaced identity.)

None changes the architectural decision: source selection, content access, coding, character decoding, record
reading and typed emission remain separate, and every composition converges on the same `DataContract` /
`DataValue` boundary.
