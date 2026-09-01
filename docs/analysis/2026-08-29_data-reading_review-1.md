# Review 1 — configurable, provider-neutral data reading

> **Review outcome: sound direction; revise before implementation.** Reviewed authority:
> [data reading](2026-08-29_data-reading.md) and its
> [constituent implementation plan](../plans/data-read-config/README.md). The layered architecture is a strong
> basis for general-purpose data reading, but several runtime, identity and typed-value contracts need to become
> explicit before DR1 starts.

## 1. Overall assessment

The central decomposition is correct:

```text
source selection
  -> provider-neutral content
  -> content coding
  -> character decoding
  -> configured reader
  -> DataCursor<DataValue> + DataContract
```

It separates independent reasons for change, keeps provider objects and filesystem paths out of parsing, preserves
the tuned flat-record backing, and makes interpretation configuration part of cache and migration identity. The
three authoring tiers are also coherent: built-in configured instances keep simple reads immediate, notation owns
ordinary customization, and plugins own new reader capabilities.

The design should proceed after one amendment pass. The most important missing piece is the runtime reader
capability and registry that makes `ReaderCapabilityIdentity` executable. Stable content identity at open time and
exact Decimal projection are the next two blocking issues. The remaining findings tighten semantics and make the
session plan safer to execute; none requires changing the six-layer direction.

## 2. What is already strong

### 2.1 The abstraction converges at the right boundary

Unifying providers at bytes, ranges or rows would be too early, and unifying everything as files would be too
late. The proposal instead lets providers advertise content capabilities while all readers converge on the
existing `DataValue` / `DataContract` model. That preserves representation-specific fast paths without creating a
second semantic data model.

### 2.2 Resolution and execution are correctly separated

Capturing a resolved read specification rather than repeatedly consulting mutable notation is the right model for
deterministic runs, inspection caching and live migration. Separating the content fingerprint from the read-spec
digest also correctly distinguishes “the selected object changed” from “the same object would now be interpreted
differently.”

### 2.3 Compression and character decoding have distinct ownership

Treating gzip as a byte-to-byte content coding, rather than a local-file feature, is necessary for provider
neutrality. Keeping charset, BOM and malformed-character policy separate from gzip and delimited syntax avoids an
eventual reader/provider cross-product. The ZIP rejection is also correct: ZIP is a selectable container, not a
transparent content coding.

### 2.4 The typed-flat scope is disciplined

Using `FlatFileRecord` as the depth-one backing is consistent with the unified model. This work does not need
structural tape, Parquet, JDBC or a universal invalid-value carrier. The fake object-store provider is an
appropriate architectural proof without pulling production S3 credentials and lifecycle into the first slice.

### 2.5 The acceptance approach is concrete

The fixture matrix covers the important cross-product without making the external 100,000-row file a product
dependency. Measuring before introducing pooling or leases is the right performance discipline.

## 3. Required design amendments

### 3.1 Define the runtime reader capability and composition root

The analysis defines `ReaderCapabilityIdentity` and a capability-owned `ReaderConfig`, but does not define the
runtime component that makes those values executable. A general-purpose implementation needs an explicit contract
approximately responsible for:

- its stable, namespaced identity and compatibility version;
- decoding, validating and canonicalizing its configuration;
- producing the canonical configuration digest;
- declaring the content capability required by a resolved configuration;
- inspecting a bounded sample; and
- opening the cursor over an acquired provider-neutral handle.

A registry or graph-discovered lookup must resolve this capability without a `when` over reader names. The generic
composition root then performs the fixed orchestration:

```text
resolve reader capability
  -> verify required content capability
  -> acquire provider content at the expected version
  -> apply content codings
  -> let the reader apply its reader-owned decoding/configuration
  -> transfer the completed stack to the cursor
```

Without this contract, `ConfiguredDelimitedReader` can become another directly wired special case even though its
configuration carries a generic identity.

This amendment must also define reader identity collision rules. A logical name plus compatibility token needs an
owning namespace or plugin coordinate; a runtime class name is neither durable nor sufficient across classloaders.

### 3.2 Give capability-owned configuration an extensible canonical wire form

`DataPart` currently serializes concrete `format` and `encoding` strings in common code. An arbitrary plugin-owned
Kotlin `ReaderConfig` subtype cannot be embedded in that wire without a closed polymorphic serializer or a generic
canonical representation.

DR1 should settle the complete snapshot representation, not only the spelling of `ReaderCapabilityIdentity`. A
good boundary is:

- generic envelope: reader identity, content-coding specifications, canonical reader-config data and digest;
- capability boundary: decode and validate that data into its runtime configuration;
- common/client wire: only canonical values understood without loading the reader implementation; and
- run state: the validated immutable runtime snapshot, resolved once.

Canonical `ExecutionValue` or an equivalently constrained JSON tree would preserve plugin extensibility. Whichever
representation is chosen must define ordering, scalar spelling, Unicode handling and absent-versus-null semantics
well enough for cross-process/platform digest stability.

The DR1 promise that the current opener remains unmodified also needs an explicit transition rule. Replacing
`DataPart` identity while leaving the active opener unchanged otherwise risks two simultaneous sources of truth.
Either DR1 carries additive shadow state with a tested invariant, or it includes the minimum opener integration
needed to make the resolved snapshot canonical.

### 3.3 Bind opening to the resolved content fingerprint

The proposal states that resolution produces a point-in-time manifest, but a path plus size and modified time is
only useful if opening verifies it. A local file can change between resolution and cursor construction, causing new
bytes to be read under the old manifest/cache identity. The same race exists for an unversioned object-store ref.

The provider/opening contract should therefore require:

1. `DataPart` carries the fingerprint expected from resolution;
2. acquisition returns a handle bound to an observed fingerprint or immutable version;
3. the composition root compares expected and observed identity before parser work; and
4. a mismatch fails with a source diagnostic and requires re-resolution.

Sequential content needs the same stable-object guarantee already proposed for a range handle. For local files,
the first implementation can open a file handle and validate its attributes against the resolved fingerprint. The
acceptance matrix should mutate a file between resolve and open and prove that stale identity is rejected rather
than cached or parsed.

Size plus modified time may remain an explicitly weak local freshness token, but it must not be described as a
content digest. Providers that offer immutable version IDs should use them.

### 3.4 Complete the exact Decimal path

The target contract promises a Decimal field and generated `BigDecimal` accessor. The current flat backing emits a
canonical text `ScalarExecutionValue` for Decimal, which is semantically valid, but existing Job boundary helpers
also route Decimal through `readDouble`. That loses the exactness promised by `ScalarKind.Decimal`. The JVM native
resolver recognizes `BigDecimal` as Decimal metadata but does not currently project a Decimal value to
`BigDecimal` in its scalar-acceptance path.

DR4 and DR6 must specify the exact path end to end:

- the reader validates and stores canonical exact decimal text;
- `scalar()` remains the complete lossless representation;
- generated accessors construct/project `BigDecimal` from that canonical value;
- native scalar binding accepts `BigDecimal` without passing through `Double`;
- Job boundary/materialization code does not flatten Decimal to binary floating point; and
- tests use values that would expose precision loss, not only small exactly representable decimals.

This is likely a focused kzen-lib plus kzen-auto change and should be named in the publication/build plan rather
than discovered during DR6.

### 3.5 Reconcile semantic schema with per-field decode options

DR2 describes `RecordSchema` as only `contract(): DataContract`, while DR4 places per-field decode overrides in
the schema. Those two statements leave no representation for the overrides.

Choose one canonical ownership:

1. `RecordSchemaSnapshot` contains the semantic `DataContract` plus reader-neutral field construction/default
   information and delimited decode overrides; or
2. `RecordSchema` remains purely semantic and `DelimitedReadConfig` owns every decode override, keyed by
   `DataTypePath` / `FieldId`.

Reader-specific concepts such as numeric token patterns should not leak into a supposedly reader-neutral schema
unless the schema model deliberately defines a reusable decoding-policy layer. The resolved snapshot and digest
must include whichever representation is selected.

The first implementation also needs an explicit supported-kind matrix. If it supports Text, bounded integers,
Decimal and Boolean but defers temporal and binary values, format resolution must reject a schema containing an
unsupported kind before opening content.

### 3.6 Specify header-to-schema mapping and syntax failures

“Validate/project header against a declaration” is ambiguous. The default needs to say whether a header-bearing
declared read requires exact ordered equality or maps fields by name and permits reordering. Name-based projection
also needs explicit missing, extra, duplicate, case and normalization policies. These choices change emitted values
and therefore belong in the resolved configuration and digest.

The syntax matrix should add:

- an unterminated quoted field at end of input;
- a quote inside an unquoted field;
- unexpected characters after a closing quote;
- empty input versus one blank record;
- bare CR and mixed record separators; and
- trimming behavior for quoted versus unquoted values.

Malformed record syntax is distinct from malformed bytes and typed-value conversion. It needs its own diagnostic
category and strict default.

The immediate-tier result should also be described precisely. A header-bearing untyped CSV can produce an
observed `Record` with Text fields; it is not structurally `Dynamic`. `Dynamic` is appropriate only where member
structure remains unknown. Replacing “Text/dynamic” with explicit cases will keep expression behavior and UI state
unambiguous.

### 3.7 Add operational budgets

A streaming parser is not automatically memory-bounded. One unterminated quoted record can grow without limit,
and a small gzip input can expand into a large decoded stream. General-purpose reading needs explicit budgets for
at least:

- maximum decoded bytes, or an equivalent run/input budget;
- maximum record size;
- maximum field size;
- maximum field count;
- bounded inspection records/bytes/time; and
- cancellation checks during long records and decompression.

The design should decide which limits are resolved semantic configuration and which are execution policy. A limit
that changes whether the same part succeeds can affect migration compatibility even when it does not change values
below the limit. Gzip integrity/trailing-data behavior should also be deterministic and tested.

### 3.8 Keep Custom discovery open-ended

Capability-based prototype discovery is correct only if generic code does not enumerate `RecordSchema`,
`ConfiguredRecordFormat` and `DataSource` as a closed set. The catalogue should discover a generic contributed
creation descriptor/category from inherited metadata. A new feature then declares its own category, label,
implementation/editor metadata and creation defaults without changing `CustomConventions` or `CustomCreate`.

The regression test should contribute a completely new test capability/category, not merely another
`RecordSchema` subtype. That proves both subtype inheritance and open-ended category discovery.

### 3.9 Do not ship unused range/rows APIs

The first implementation consumes sequential bytes. Declaring `Rows` and operational range interfaces before a
JDBC or Parquet consumer fixes APIs without evidence and conflicts with the repository's concrete-observable-
behavior rule. An extensible capability identity can leave the vocabulary open without adding empty methods or
types now.

Implement `SequentialBytes` fully. Add range or row access with the first named consumer and its actual lifetime,
batching, seek/version and cancellation requirements. If a generic required/available mismatch test is desired
now, a test-only unknown capability identity can prove early rejection without pretending the future range API is
known.

## 4. Recommended plan changes

### 4.1 DR1 — identity, reader capability and wire

Expand DR1 to settle:

- the runtime reader-capability/registry contract;
- the canonical extensible configuration wire;
- reader identity namespace and compatibility version;
- content-fingerprint handshake semantics;
- the one canonical `DataPart` transition; and
- digest/cache/migration tests over canonical data.

Keep only content capabilities with an implemented consumer.

### 4.2 DR2 — schema and Custom discovery

Retain DR2's position, but first settle where per-field decode configuration lives. Test both a third-party schema
subtype and a novel Custom creation category. Generic catalogue code must not import or enumerate the data-reading
capabilities.

### 4.3 DR3 — content stack plus a minimal provider-bound proof

DR3 should include a minimal opaque in-memory provider and sourced ref. This proves provider lookup, fingerprint
verification, acquisition cancellation and lifetime before the configured reader depends on the stack. The later
fake-object-store phase can still run the full delimited-reader conformance matrix.

Waiting until DR5 for the first provider-bound implementation would allow an unproven provider-neutral abstraction
to shape DR4.

### 4.4 DR4 — parser/conformance and atomic product cutover

DR4 is a large but coherent boundary. If it does not fit safely in one session, split it into:

- an inactive but fully tested configured parser/typed-value implementation; and
- configured-format archetypes, built-in CSV/TSV instances and the atomic product cutover.

The first half has observable tests and does not create a second user-visible mode. The cutover still removes the
legacy product answer atomically.

### 4.5 DR5 — full provider conformance

Keep DR5 as the full fake-object-store proof over plain and gzip input, capability mismatch and cancellation. It
becomes a reader/provider conformance suite rather than the first proof that a sourced ref can open.

### 4.6 Split DR6 at known green boundaries

DR6 currently combines three broad concerns that can land independently:

1. canonical `DataContract` / `DataShapeResult` propagation through server and client Job projection;
2. exact typed expression access and calculated-field contract retention; and
3. shared contract rendering plus source/format/schema-draft authoring UI.

Plan these as DR6a/DR6b/DR6c, even if the master ledger keeps one parent row. This makes failures attributable and
prevents a UI-sized tail from holding completed server type-flow work in an unreviewable session.

### 4.7 DR7 — acceptance and measurement

Retain DR7, adding:

- stale-fingerprint rejection;
- pathological-record and decompression-budget cases;
- exact Decimal precision cases; and
- parser syntax failures.

The performance comparison should distinguish parsing throughput from Job end-to-end throughput so a regression
can be assigned to the reader, typed projection or lane machinery before optimization begins.

## 5. Recommended decision

Proceed with the architecture after updating the authority and constituent plans for the amendments above. The
six-layer decomposition, resolved identity model, typed-flat target and fake-provider strategy should remain.

The implementation-ready gate is:

1. a concrete open-ended reader capability and canonical config wire;
2. expected-versus-opened content identity verification;
3. exact Decimal projection;
4. unambiguous schema/decode/header/syntax semantics;
5. bounded operational policy; and
6. a minimal provider-bound proof before the configured reader cutover.

Once those are written into DR1–DR4, the remaining work is primarily execution risk and session sizing rather than
an architectural uncertainty.
