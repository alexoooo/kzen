# Unified data model — types, values, bindings and managed-object views

> **Status: proposal for review, not an implementation contract.** This document collects the complete current
> argument for a data model shared by every Logic flavour. It deliberately does not authorize code changes or
> alter the implementation status in any plan. If the proposal is accepted, this becomes the owner of the
> generic type/value/binding contract; the [data-source model](2026-08-20_data-source-model.md),
> [Job adapter](2026-08-20_job-data-source.md), and [project-data analysis](2026-08-26_database.md) can then be
> narrowed to their own concerns.

The former `2026-08-23_job-data-source_review.md` is not present in the tree. Its surviving conclusions had
already been consolidated into the data-source and Job analyses; this document carries forward the relevant
model findings rather than depending on the missing review as a source.

## 1. Conclusion

A unified model is possible, and it changes the design materially.

The useful unification point is neither `Any?`, a generic map, nor a serialized tree. It is an immutable semantic
value with:

- one recursive `DataType` describing what the value means;
- one `ValueAccess` implementation describing how to read its current backing;
- one opaque root handle locating the value in that backing; and
- typed, enumerable `DataBindings` at named Logic boundaries.

The backing may be a Kotlin object, a literal list or map, a flat file record, a structural tape, a graph-created
object, or a durable-store row. Consumers use the same semantic operations without first copying every value into
one universal representation. Ordinary Script and Formula code continues to use ordinary Kotlin values. The
framework lifts those values automatically when they cross a processing boundary and projects them back to a
native value when that is the most natural view.

This is not a compatibility layer around the current split. The current split is the defect to remove:

- `TupleValue` preserves names but stores opaque `Any?` values;
- `DataContext.argument(name): Any?` hides the available names and collapses missing with present-null;
- Script steps and Flow ports independently traffic in `Any?`;
- Job carries `JobMessage(payload, flat)` and separately describes a lane as
  `WorkerLane(payloadType, flatColumns)`;
- today's `ExecutionValue` is a useful wire and trace tree, but its name is execution-specific and it cannot
  retain arbitrary native identity or provide lazy structural access; and
- `DataShape.Tabular | Payload` describes current carriers rather than the data.

Adding a `Both` case would preserve the same mistake. A Kotlin data class and a database row may both be records;
one being a native object and the other being row-backed is a representation difference, not a semantic type
difference.

The proposal therefore has three layers:

| Layer | Question | Proposed owner |
|---|---|---|
| `DataType` / `DataShape` | What does this value mean, and how was that type learned? | `kzen-lib-common` |
| `DataValue` / `ValueAccess` | How can this value be read without requiring one physical representation? | `kzen-lib-common`, with platform backings |
| `DataBindings` | Which named values are declared, bound, defaulted, missing or produced? | `kzen-lib-common` Logic boundary |

Data sources, Script, Flow and Job become consumers of this foundation. None owns a parallel value model.

## 2. What is wrong with the current boundary

### 2.1 `Any?` is a legitimate native edge, but a poor data contract

`Any?` is appropriate when Kotlin code calls arbitrary user code or stores an opaque resource handle. It is not
enough for a framework data boundary. Given an `Any?`, generic code cannot answer:

- whether the name was absent or explicitly bound to null;
- what names are available;
- what type was declared independently of the current runtime value;
- whether a field is absent, null, defaulted or invalid;
- whether an object may be traversed structurally;
- whether conversion would allocate or read a live resource;
- whether a value may safely outlive its cursor, transaction or execution frame; or
- how to serialize or display it without accidentally calling an arbitrary `toString()`.

The current `TupleValue.find` and `DataContext.argument` both return `Any?`. A missing component and a present
component whose value is null have the same result. `DataContext` does not expose its names, definitions or
origins at all. This prevents even a safe diagnostic such as “arguments: from: String (supplied), to: String
(defaulted)” without reaching behind the API into a particular runtime implementation.

The fact that the underlying implementations already have more information makes the loss unnecessary:
`JobControl.parameters()` has a `TupleDefinition`, while design requests already hold a name-to-values map. The
opacity is introduced by the interface rather than forced by the sources.

### 2.2 Type metadata and runtime values drift apart

`LogicType` wraps `TypeMetadata`, while `TupleComponentValue` holds an unrelated `Any?`. Job repeats the split in
`WorkerLane` versus `JobMessage`. Correctness relies on each producer updating two descriptions consistently and
each consumer knowing which physical half to inspect.

That is already visible in Job's boundary rules. A payload crosses a Logic boundary unchanged, but a flat record
crosses as a newly materialized `Map<String, String>`. A column consumer asks `flatView()` to mutate a payload
message into a second representation. This is ingenious as a local interoperability mechanism, but it is not a
stable general data model: meaning, representation, ownership and projection are all encoded in one mutable
carrier.

### 2.3 Each Logic flavour solves the same problem again

Script step results, Flow port messages, Job channel elements and Logic tuples are all values moving between
computations. Their control-flow and scheduling semantics are legitimately different. Their definitions of a
record, list, scalar, missing binding or nominal object should not be.

A data source adds another origin for values, not another kind of value. Likewise, a database adds a durable
backing and transaction semantics, not a new expression type system. A general model should let all of these
participate while preserving their distinct lifecycle rules.

### 2.4 `ExecutionValue` solves a different problem

Today's `ExecutionValue` is a small, serializable tree for requests, results and traces. That is valuable precisely
because it is detached and bounded. It is not a suitable live runtime model:

- it supports a deliberately restricted scalar/list/map vocabulary;
- conversion of an arbitrary domain object cannot preserve its Kotlin identity or methods;
- eager tree conversion defeats row, tape and lazy-object backings;
- it has no field-presence or binding-origin model; and
- it cannot carry a borrowed cursor- or transaction-scoped view safely.

The target model renames this detached tree to `WireValue` and converts `DataValue` to it at a wire or trace
boundary under explicit depth, size, cycle and redaction policies. It should not make that conversion the cost of
every in-process handoff. `ExecutionValue` remains the name of the current implementation when this document
describes existing code.

## 3. Design principles

The proposal follows these rules.

1. **Meaning is independent of storage.** A record is a record whether backed by a data class, CSV row, database
   result, structural tape or graph instance.
2. **One value crosses a boundary.** There is no parallel payload plus flat carrier and no parallel runtime value
   plus out-of-band shape that producers must keep synchronized.
3. **Native authoring stays native.** A Formula may return a data class, list, scalar or managed object without
   constructing a framework wrapper.
4. **Automatic conversion happens at framework boundaries.** Adapter registration is an infrastructure concern,
   not ceremony repeated in every Script or Worker.
5. **Views are immutable.** Reading through `DataValue` never mutates a Kotlin object, graph instance or durable
   row. Mutation remains an explicit operation owned by the relevant system.
6. **Missing is not null.** Unbound, absent, null, defaulted and invalid are observable distinct states.
7. **No compulsory universal materialization.** Backings share access semantics, not necessarily memory layout.
8. **Cheap paths remain cheap.** A flat record keeps its indexed storage and primitive caches. Reading one field
   must not allocate a nested wrapper object.
9. **Capabilities are extensible.** New structural or native integrations register adapters; generic code does
   not branch on concrete application type names.
10. **Snapshots are explicit.** Serialization, tracing, retention and cross-process transport take bounded
    snapshots. A live view is not accidentally treated as durable.
11. **Ownership remains visible.** Cursor-, transaction- and execution-scoped backings cannot be retained after
    their owner settles unless explicitly detached or copied.
12. **Existing defects are not design constraints.** A current split may explain migration cost, but it is not a
    reason to reproduce the split in the target model.

## 4. The semantic type language

`DataType` describes the semantic operations a consumer may perform. It is recursive and independent of the
runtime backing. The complete proposed type surface is:

```kotlin
@JvmInline
value class FieldId(val value: String)

@JvmInline
value class VariantId(val value: String)

data class DataField(
    val id: FieldId,
    val name: String,
    val type: DataType,
    val presence: DataPresence = DataPresence.Required
)

sealed interface DataPresence {
    data object Required: DataPresence
    data object Optional: DataPresence
    data class Defaulted(val default: DataDefault): DataPresence
}

sealed interface WireValue

sealed interface ScalarWireValue: WireValue

data object NullWireValue: WireValue
data class TextWireValue(val value: String): ScalarWireValue
data class BooleanWireValue(val value: Boolean): ScalarWireValue
data class IntegerWireValue(val canonical: String): ScalarWireValue
data class DecimalWireValue(val canonical: String): ScalarWireValue
data class FloatingWireValue(val value: Double): ScalarWireValue
class BinaryWireValue(val value: ByteArray): ScalarWireValue
data class ListWireValue(val values: List<WireValue>): WireValue
data class ObjectWireValue(val values: Map<String, WireValue>): WireValue

data class WireEntry(
    val key: ScalarWireValue,
    val value: WireValue
)

data class MappingWireValue(
    val entries: List<WireEntry>
): WireValue

data class BlobReferenceWireValue(
    val scope: String,
    val id: String,
    val size: Long,
    val mediaType: String? = null
): WireValue

data class DataDefault(
    val literal: WireValue
)

sealed interface ScalarKind {
    data object Boolean: ScalarKind
    data class Integer(val bits: Int? = null, val signed: kotlin.Boolean = true): ScalarKind
    data class Decimal(val precision: Int? = null, val scale: Int? = null): ScalarKind
    data class Floating(val bits: Int = 64): ScalarKind
    data object Text: ScalarKind
    data object Binary: ScalarKind
    data object Date: ScalarKind
    data object Time: ScalarKind
    data object Instant: ScalarKind
    data object Duration: ScalarKind
    data object Uuid: ScalarKind
}

data class DataVariant(
    val id: VariantId,
    val type: DataType,
    val label: String = id.value
)

data class FieldDiscriminator(
    val field: FieldId,
    val cases: List<DiscriminatorCase>
)

data class DiscriminatorCase(
    val value: ScalarWireValue,
    val variant: VariantId
)

sealed interface DataType {
    val nullable: Boolean

    data class Scalar(
        val kind: ScalarKind,
        override val nullable: Boolean = false
    ): DataType

    data class Record(
        val fields: List<DataField>,
        override val nullable: Boolean = false
    ): DataType

    data class Mapping(
        val key: DataType,
        val value: DataType,
        override val nullable: Boolean = false
    ): DataType

    data class Listing(
        val element: DataType,
        override val nullable: Boolean = false
    ): DataType

    data class Union(
        val variants: List<DataVariant>,
        val discriminator: FieldDiscriminator? = null,
        override val nullable: Boolean = false
    ): DataType

    data class Nominal(
        val className: ClassName,
        val arguments: List<DataType> = emptyList(),
        override val nullable: Boolean = false
    ): DataType

    data class Dynamic(
        override val nullable: Boolean = true
    ): DataType
}
```

`ClassName` in this sketch is an existing kzen-lib type. Every other referenced type is defined above. The syntax
is still a proposal rather than a frozen ABI, but the semantics and invariants below are part of the proposal; an
implementation should not silently fill them in differently.

Identifiers are non-empty canonical strings. A `FieldId` is unique only within its enclosing `Record`; a
`VariantId` is unique only within its enclosing `Union`. Display names and labels are not identities and may
change without changing references. An authored schema persists its IDs. Inferred records derive deterministic
IDs from structural paths and duplicate occurrence, never from process-local hashes.

`WireValue` is the proposed replacement name and generalized surface for today's `ExecutionValue`. Integer and
decimal values use normalized text so they remain exact across JVM/JS and JSON; floating values retain IEEE-754
semantics. Temporal and UUID scalar values use their canonical text form and are interpreted under the owning
`DataType`. `BinaryWireValue` owns a defensive copy and implements content equality. Lists preserve order.
`ObjectWireValue` keys are unique strings; insertion order is presentation-only, while serialization and
digesting sort keys. `MappingWireValue` carries arbitrary scalar keys, rejects duplicate keys under scalar
content equality, and stores entries in canonical key order.
Integer and decimal constructors validate their canonical strings. Non-finite floating values serialize through
canonical named tokens rather than depending on invalid JSON numeric literals.

`BlobReferenceWireValue` is the one non-self-contained leaf. `scope` identifies the resolver namespace and `id`
identifies content within it; both are non-empty opaque strings. The current trace `run`/`hash` binary handle can
lower to this generic form without making execution identity part of the foundational type. A resolver decides
whether the scope is available; merely deserializing the tree performs no I/O. `size` is non-negative and
`mediaType`, when present, is non-empty.

`DataDefault.literal` must be recursively self-contained: it may not contain `BlobReferenceWireValue`. It is
detached canonical data, not a live native object or executable expression. Its decoded type must be accepted by
the field or binding type. A computed default belongs to binding construction and must produce the same explicit
`Defaulted` origin; it is not smuggled into `DataDefault` as arbitrary code.

`ScalarKind` is sealed rather than an enum because integer width, decimal precision/scale and floating width carry
parameters. `Integer.bits == null` means arbitrary precision. `Decimal` null precision/scale means unconstrained
decimal, not binary floating point.

`ScalarWireValue` is the one detached scalar representation used for mapping keys, discriminator values and
generic scalar reads; there is no parallel `DataScalar`. Its enclosing `DataType.Scalar` supplies the semantic
kind. For example,
`TextWireValue` may carry text, a canonical date, an instant or a UUID; the owning type determines which. Runtime
code may use specialized primitive accessors instead of constructing a scalar wire value on a hot path.

Scalar content equality is variant-specific: text and booleans compare their values; integers and decimals compare
their validated canonical strings; floating values use their canonical IEEE-754 representation; and binary uses
byte content. Canonical mapping-key order sorts first by wire scalar variant and then by that variant's canonical
bytes. This ordering exists for deterministic wire/digest output and is not a user-visible data ordering claim.

### 4.1 Records, mappings and listings are different

A record has an ordered, declared field set. A mapping has arbitrary scalar keys with a uniform value type. A
listing has ordered numeric positions. Treating all three as `Map<String, Any?>` loses order, field identity,
duplicate field handling, presence and element constraints.

`Mapping.key` must be a non-null `Scalar` or non-null `Dynamic`; records and collections cannot be keys. Using a
`DataType` rather than a required `ScalarKind` lets an empty or genuinely dynamic map state honestly that its key
kind is not yet known. Every present runtime key is still a `ScalarWireValue` interpreted under `Mapping.key`.

`DataField` needs a stable identity separate from its display name, its `DataType`, and a presence rule:

- `Required` — absence is invalid;
- `Optional` — absence is valid and distinct from null; or
- `Defaulted` — absence resolves to a declared default and records `Defaulted` origin.

Field names remain ordered and may require a projection policy when a tabular consumer demands unique labels.
That policy does not alter the record's semantic type.

### 4.2 Scalar kinds are semantic, not JSON-derived

The initial scalar vocabulary should cover boolean, text, integral and decimal numbers, binary, and the time/date
kinds that kzen actually needs. Null is a `DataState`, not a scalar kind. Provider-native precision or format
metadata may accompany the semantic projection when lossless round-trip is required. The type algebra should not
inherit JSON's limited number and time vocabulary merely because JSON is one wire format.

The temporal meanings are deliberately small and explicit:

- `Date` is a calendar date without a time or zone;
- `Time` is a wall-clock time without a date or zone;
- `Instant` is an absolute point on the timeline, canonically serialized in UTC; and
- `Duration` is an elapsed amount rather than a calendar date/time.

`Instant` does not pretend to represent a local date-time. Converting “09:00 on 2026-09-01” to an instant requires
a timezone and its rules, which the value does not contain. The initial core therefore has no parameterized
`DateTime(TimeZoneSemantics)` case. A provider's timestamp-without-zone, original offset, region ID and precision
remain representation metadata, a nominal adapted value, or canonical text until a concrete processing use case
justifies a properly specified scalar type.

The initial core also has no generic `Logical(id, storage)` extension case. Such a type would require stable
namespaced IDs, canonicalization and validation providers, compatibility rules, missing-provider behaviour and an
explicit projection to its storage scalar. `Nominal` plus the adapter registry already provides a safe extension
path for custom values. A logical/refined scalar can be added when a real type needs generic primitive transport
while retaining semantic identity; the registry is not introduced speculatively.

### 4.3 Unions do not require record fields

A union is an ordered, non-empty set of variants with unique IDs. Its variants may be any `DataType`, including
scalars, listings, mappings, records, nominal values and nested unions. Null is represented by the union's
`nullable` modifier rather than a synthetic null variant.

For example, `List<String> | String` is:

```kotlin
DataType.Union(
    variants = listOf(
        DataVariant(
            VariantId("many"),
            DataType.Listing(DataType.Scalar(ScalarKind.Text))
        ),
        DataVariant(
            VariantId("one"),
            DataType.Scalar(ScalarKind.Text)
        )
    )
)
```

No discriminator is needed because exactly one branch accepts a listing and exactly one accepts a string. For an
undiscriminated union, lifting or decoding compares the observed value type with every variant:

- exactly one accepting variant selects that variant;
- no accepting variants is a type error; and
- more than one accepting variant is ambiguous and fails unless the decoder has an explicit, separately declared
  disambiguation policy.

Variant order is canonical for display and digest purposes; it is never an implicit “first match wins” rule.

`FieldDiscriminator` is the only optional discriminator in the semantic type. It means every variant is a record
containing the named scalar field, and each `DiscriminatorCase` maps one field value to a variant ID.
Discriminator values must be unique, every referenced variant must exist, and every variant must have at least one
case. Several aliases may select one variant. The field must exist in every variant and accept each corresponding
case value. Because `FieldId` is record-local, the variant records deliberately reuse one common local ID for the
discriminator.

External keys, adjacent `{type, value}` wrappers, message headers and separate database discriminator columns are
encoding concerns. Their codec configuration maps the external representation directly to a `VariantId` and then
validates that the selected variant accepts the decoded value. No external discriminator representation appears in
`DataType`.

A union-typed runtime node exposes its active `VariantId` through `ValueAccess`. That ID is authoritative after
lifting or decoding; downstream consumers do not rediscover it by inspecting fields or encoding wrappers.

### 4.4 Nominal is intentional

`Nominal` means “this value is known by its declared native type, but no general structural contract has been
promised.” It is not a failure case. Native Kotlin code may still receive the original object without copying.
A registered adapter may additionally expose a record, listing or mapping projection.

This gives arbitrary objects a safe baseline. Reflecting every public getter would make framework behaviour
depend on methods that may be expensive, stateful, service-like or simply not data. Kotlin data classes and Java
records have a stronger data intent and are appropriate automatic structural baselines.

### 4.5 Dynamic is known uncertainty

`Dynamic` means a value exists but its usable structure is not known until runtime. It differs from a failed or
unsupported attempt to inspect a value. Consumers may accept it, defer checks, or require a stronger type.

### 4.6 The type algebra is part of the contract

The model is incomplete without deterministic operations for:

- `accepts(actual)` for boundary validation;
- `join(other)` for branches, heterogeneous streams and schema union;
- record-to-tabular projection under an explicit naming policy;
- normalization and canonical equality/digest rules; and
- `TypeMetadata` / `KType` conversion.

The proposed algebra surface makes failure and variant ambiguity explicit:

```kotlin
interface DataTypeAlgebra {
    fun accepts(expected: DataType, actual: DataType): TypeAcceptance
    fun join(left: DataType, right: DataType): DataType
    fun selectVariant(
        union: DataType.Union,
        actual: DataType,
        discriminatorValue: ScalarWireValue? = null
    ): VariantSelection
    fun validateVariant(
        union: DataType.Union,
        variant: VariantId,
        actual: DataType
    ): TypeAcceptance
}

sealed interface TypeAcceptance {
    data object Accepted: TypeAcceptance
    data class Rejected(val problem: DataProblem): TypeAcceptance
}

sealed interface VariantSelection {
    data class Selected(val variant: VariantId): VariantSelection
    data class NoMatch(val problem: DataProblem): VariantSelection
    data class Ambiguous(val candidates: List<VariantId>): VariantSelection
}
```

`accepts` answers type compatibility only: a union accepts an actual type when at least one variant does.
`selectVariant` answers the separate runtime question and may return every ambiguous candidate. When the union has
a `FieldDiscriminator`, its adapter reads that field and passes `discriminatorValue`; without a discriminator,
structural selection uses the rules in §4.3.

A codec handling an external/adjacent discriminator, or a native adapter that already knows its subtype, resolves the
`VariantId` outside this algebra and calls `validateVariant`. That operation checks that the ID belongs to the
union and its variant accepts `actual`. Callers never feed representation-specific discriminator locations into
`DataType`, infer ambiguity from an exception message, or use variant order as precedence.

`join` creates or normalizes a union only when the alternatives remain useful; it does not silently widen
incompatible values to `Dynamic`. Union normalization flattens nested undiscriminated unions, removes exact duplicate
variants, preserves stable variant IDs, and never merges variants named by different discriminator cases merely
because their value types happen to match. Record/tabular projection is a separate value operation because it may
need an adapter and may allocate; its plan and failure model should be specified with the first implementation
rather than hidden inside `accepts`.

Known primitives and collections convert structurally. A declared domain class converts to `Nominal` unless a
structural adapter provides a stronger projection. This makes the conversion mechanical rather than an expanding
list of application special cases.

## 5. `DataShape` observes a type; it does not classify a carrier

`DataType` answers what one value means. `DataShape` records how confidently that type is known:

```kotlin
enum class ShapeProvenance {
    Declared,
    Carried,
    ProviderReported,
    Inferred,
    RuntimeOnly
}

sealed interface ShapeStability {
    data object Stable: ShapeStability
    data class Provisional(val coverage: SampleCoverage): ShapeStability
}

data class SampleCoverage(
    val observedItems: Long,
    val observedBytes: Long? = null,
    val complete: Boolean = false
)

enum class DiagnosticSeverity {
    Info,
    Warning,
    Error
}

data class SchemaDiagnostic(
    val severity: DiagnosticSeverity,
    val code: String,
    val message: String,
    val location: String? = null
)

data class DataShape(
    val itemType: DataType,
    val provenance: ShapeProvenance,
    val stability: ShapeStability,
    val diagnostics: List<SchemaDiagnostic>
)

sealed interface DataShapeResult {
    data object Unavailable: DataShapeResult
    data class Observed(val shape: DataShape): DataShapeResult
}
```

`Stable` means the producer promises the type for the scope described by the calling contract; it does not mean
the source can never evolve between executions. `Provisional` reports the exact sample coverage used for
inference. `complete` means the complete bounded input represented by that observation was inspected, not that
future source contents are frozen. Diagnostics use stable machine-readable codes; `location` is an optional
provider/source path intended for display, not semantic identity.

Provenance and stability are orthogonal. A declared type is normally stable, while inferred or runtime-only
knowledge may be provisional. Diagnostics record conflicts or lossy projections without mutating the declared
contract.

There is no `Tabular`, `Payload` or `Both` case:

- a CSV row is normally a `Record` backed by a flat record;
- a Kotlin data class may be a `Record` view backed by the native instance;
- a scalar is `Scalar`, regardless of whether a table UI projects it to a synthetic `value` column;
- a map is `Mapping`, even if one particular runtime key set can be displayed as columns; and
- an opaque Kotlin object is `Nominal`, not “payload.”

Tabular access is a projection capability requested by a consumer. It may accept a record directly, project a
scalar to one column, or require a deliberate mapping-key policy. The value does not acquire a second identity
because a table rendered it.

## 6. Runtime values and multiple backings

The runtime value is a small immutable view:

```kotlin
@JvmInline
value class DataNode internal constructor(val token: Long)

class DataValue(
    val type: DataType,
    val access: ValueAccess,
    val root: DataNode
)

data class DataProblem(
    val code: String,
    val message: String,
    val path: List<String> = emptyList()
)

enum class DataRetention {
    Detached,
    Borrowed,
    Retainable
}

interface RetainedDataValue: AutoCloseable {
    val value: DataValue
}
```

`DataNode.token` is meaningful only to the accompanying `ValueAccess`; nodes from different access instances are
never interchangeable. The access implementation owns the token namespace and any backing tables. This fixes the
public representation at one inline `Long` while leaving each backing free to encode offsets, row/field slots or
cached native-property plans. The root invariant is `access.type(root) == type`.

The complete semantic access surface is:

```kotlin
interface ValueAccess {
    val retention: DataRetention

    fun type(node: DataNode): DataType
    fun state(node: DataNode): DataState
    fun origin(node: DataNode): ValueOrigin?
    fun problem(node: DataNode): DataProblem?
    fun isAlive(node: DataNode): Boolean
    fun retain(node: DataNode): RetainedDataValue

    fun activeVariant(node: DataNode): VariantId

    fun field(node: DataNode, field: FieldId): DataNode
    fun entry(node: DataNode, key: ScalarWireValue): DataNode
    fun element(node: DataNode, index: Int): DataNode
    fun size(node: DataNode): Int
    fun keyAt(node: DataNode, index: Int): ScalarWireValue

    fun scalar(node: DataNode): ScalarWireValue

    fun readBoolean(node: DataNode): Boolean
    fun readLong(node: DataNode): Long
    fun readDouble(node: DataNode): Double
    fun readText(node: DataNode): String
    fun readBinary(node: DataNode): ByteArray

    fun native(node: DataNode): Any
}
```

`scalar` is the complete canonical path for every `ScalarKind`, including arbitrary-precision numbers and
temporal values. The specialized reads are allocation-free fast paths and succeed only when the scalar
kind can be represented exactly by the requested Kotlin primitive. `readBinary` returns a defensive copy; a
zero-copy binary consumer needs an explicit borrowed-buffer capability with the same lifetime rules as the
backing. `native` is the explicit native interop edge; it fails when the backing has no native projection rather
than synthesizing one.

`activeVariant` is valid only for a present union node. `field`, `entry`, `element`, `size` and `keyAt` are valid
only for compatible present structural nodes. A record enumerates fields through its ordered `DataType.Record`
definition; a mapping uses `size` plus `keyAt`. Unsupported operations fail as contract violations. The eventual
source API may split these operations into capability subinterfaces, but it must preserve these semantics and
must not require generic code to inspect concrete backing classes.

Retention is explicit rather than inferred from a backing class:

- `Detached` values are self-contained and remain live independently of a cursor or execution frame;
- `Borrowed` values are valid only while their owner says so and cannot be retained; callers must consume them or
  request a detached snapshot; and
- `Retainable` values may outlive the current handoff only through `retain`, whose returned lease owns the retained
  value until `close`.

`isAlive` permits a deterministic stale-view failure; every accessor operation checks the same lifetime state.
Calling `retain` on `Borrowed` fails. Calling it on `Detached` returns a no-op lease over the same value. A
`Retainable` backing may increment a shared lease, pin a row/page or make a bounded copy, but that cost occurs only
at the explicit retention boundary. The engine, not Formula code, owns these leases during ordinary processing.

`DataValue` intentionally has reference identity rather than generated structural equality. Content comparison
and digesting are explicit operations with depth, type and lifetime policies; comparing two access/root handles
would not establish semantic equality.

`DataState`, `ValueOrigin` and `problem` keep the information that `Any?` collapses without allocating a state
wrapper on every successful field read:

```kotlin
enum class DataState {
    Absent,
    Null,
    Present,
    Invalid
}

enum class ValueOrigin {
    Literal,
    Backing,
    Defaulted,
    Derived
}
```

An accessor fails immediately when an operation contradicts `DataType`: reading text from a record or asking a
required missing field to masquerade as null is a contract error, not a fallback. `Invalid` contains detached,
display-safe information through `problem(node)` rather than a live `Throwable`; source exceptions may be
retained separately by their owner for logging. `origin(node)` is non-null for `Null` and `Present`, and null for
`Absent` and `Invalid`. A field resolved from `DataPresence.Defaulted` reports `Defaulted`; derived projections
report `Derived`. This origin concerns the node's value, while `BindingOrigin` separately records how a named
binding was populated.

### 6.1 Required backing implementations

The shared contract should allow at least:

| Backing | Purpose | Materialization rule |
|---|---|---|
| Literal | Scalars and lightweight list/map/record literals | Owns its small immutable value tree |
| Flat record | CSV/TSV and Report/Job column paths | Retains indexed storage, shared headers and primitive caches |
| Structural tape | Streaming JSON/XML-like structures | Nodes index the tape; subtrees are not copied |
| Native object | Formula results and ordinary Kotlin objects | Retains the original reference; adapter reads supported members |
| Graph object | Notation-defined and graph-created objects | Retains graph instance/definition context; selected attributes are lazy fields |
| Typed row | Database/query/store results | Reads driver/store cells through a row-scoped view |
| Composed | Formula/transform output overlaying an input | Resolves unchanged fields through the input and new fields through the overlay |

The list is open. Adding a backing should not add a new `DataType` case or require changes to every consumer.

### 6.2 Immutability and lifetime

`DataValue` is a read view even when its backing object is mutable. No `setField` belongs on `ValueAccess`.
Graph changes go through notation commands/reducers; durable-row changes go through a store transaction or
repository command; Kotlin object mutation remains explicit Kotlin code.

`native` is the deliberate escape hatch from that guarantee. A caller requesting the original mutable Kotlin
object may mutate it through its own API; generic structural processors never call `native` merely to read fields.
The immutable guarantee applies to the data access contract, not to every method on an object the caller
explicitly requested by native type.

A view may borrow its backing. A row may be valid only until the cursor advances; a database value may depend on
a transaction; a graph object may belong to one compiled graph snapshot. The engine therefore owns boundary
lifetimes and chooses among:

- consume within the current scope;
- transfer ownership exactly once;
- retain the live backing under an explicit managed lifetime; or
- detach to a bounded literal/wire snapshot.

No API should imply that every `DataValue` is safe to cache indefinitely.

### 6.3 Performance is part of correctness

The abstraction is acceptable only if it preserves the existing fast paths:

- no eager conversion of each row to maps or nested objects;
- no per-field `DataValue` allocation during expression evaluation;
- allocation-free primitive reads after cursor setup;
- no reflection lookup per field read—adapters cache or generate access plans;
- stable shared `DataType` and field descriptors across rows; and
- explicit accounting when a consumer requests a materialized map, object or wire snapshot.

These are benchmarkable acceptance conditions, not optional optimizations. The existing planned Job benchmark
harness is sufficient; a new benchmark framework is not required.

## 7. Native and literal ergonomics

The normal authoring experience should be:

```kotlin
data class Reading(val sensor: String, val value: Double)

// Formula result: ordinary Kotlin, no DataValue construction.
Reading(sensorId, measuredValue)
```

At the Formula/step/port boundary, the configured `DataAdapterRegistry.lift(result, declaredType)` selects an
adapter and creates the root view. When another native Kotlin expression consumes the value, the native backing
returns the original `Reading` instance. When a generic Sort, Filter, table or writer consumes it, the data-class
adapter exposes the same instance as a record with `sensor` and `value` fields.

### 7.1 Lightweight record literals are not arbitrary maps

A lightweight object literal is a useful authoring form, but it still needs a semantic distinction from a map.
The proposed rule is:

- a notation/JSON object or explicit Kotlin `recordOf("name" to value, ...)` literal lifts as an ordered
  `Record`, with field types inferred or checked against the expected `Record` type;
- a `Map<K, V>` lifts as `Mapping`, because its key set is runtime data rather than a declaration; and
- a string-keyed map may satisfy an expected `Record` only through an explicit checked projection that reports
  missing, extra and duplicate fields.

`recordOf` is a literal constructor, not a `DataValue` wrapper: callers describe the object they want, while the
framework still performs lifting. A future Formula object-literal syntax may lower to the same value without
changing the model. Treating every `Map<String, *>` as a record would look convenient initially but would make
schema depend on each instance's keys and recreate the current runtime-header ambiguity.

This gives small ad hoc values a concise form while data classes and managed objects remain the natural forms for
reused domain structure.

The authoring surface can remain small and explicit:

```kotlin
data class RecordLiteralField(
    val name: String,
    val value: Any?
)

class RecordLiteral internal constructor(
    val fields: List<RecordLiteralField>
)

fun recordOf(vararg fields: Pair<String, Any?>): RecordLiteral
```

The factory allows an empty record, preserves order, requires each name to be non-empty and names to be unique,
and defensively copies the field list. Its adapter
derives deterministic `FieldId`s from those names and lifts each value recursively. `Any?` is appropriate here as
the native authoring input; the resulting boundary value is typed and stateful. A literal needing duplicate
display names must use a schema-aware record builder rather than object-literal syntax.

### 7.2 Automatic baseline

The baseline should be predictable:

- null and primitive values lift as scalar/null literals;
- lists, sets, iterables and arrays lift as listings when their lifetime is safe;
- maps lift as mappings, not records merely because their current keys are strings;
- Kotlin data classes lift as structural records on the JVM;
- Java records lift as structural records on the JVM;
- graph-created objects use the graph adapter described below;
- a type with a registered adapter uses that adapter; and
- any other object lifts as `Nominal` and retains native access only.

The expected/declared type participates in inference without changing the adapter owner:

- null with a nullable expected type uses that type and `DataState.Null`; null without one uses nullable
  `Dynamic`; null against a non-null type fails;
- an empty collection with an expected listing/mapping type uses its declared element/key/value types;
- an untyped empty list becomes `Listing(Dynamic(nullable = false))`;
- an untyped empty map becomes
  `Mapping(Dynamic(nullable = false), Dynamic(nullable = false))`;
- a non-empty homogeneous collection uses the joined observed element/value type; and
- heterogeneous elements use the deterministic `join` algebra, including a union when its variants remain
  distinguishable.

Common code owns the model and adapter protocol. Platform modules own reflection or generated access. The common
contract must not pretend Kotlin/JS offers JVM reflection. On platforms without a safe automatic structural
adapter, literals remain structural and arbitrary objects remain nominal; generated or explicitly registered
adapters can add structural access without changing caller code.

### 7.3 Extensibility without caller ceremony

An application or plugin may register one adapter for its domain type. Every Script, Flow, Job and data-source
boundary then uses it automatically. This is different from requiring every Formula author to call
`DataValue.of(...)` or annotate every handoff.

Adapter selection must be deterministic. Exact type adapters win over assignable/capability adapters; conflicting
adapters at the same priority fail during registry construction. Generic framework code asks the registry for a
capability and never names application classes.

The conceptual adapter boundary is:

```kotlin
@JvmInline
value class DataAdapterId(val value: String)

sealed interface AdapterMatch {
    data object Exact: AdapterMatch
    data class Assignable(val distance: Int): AdapterMatch
    data class Capability(val priority: Int): AdapterMatch
}

interface DataAdapter {
    val id: DataAdapterId
    fun match(value: Any): AdapterMatch?
    fun lift(value: Any, expected: DataType? = null): DataValue
}

interface DataAdapterRegistry {
    fun lift(value: Any?, expected: DataType? = null): DataValue
    fun adapter(value: Any): DataAdapter
}
```

`Any` appears here deliberately: this is the native-to-data interop edge. Null is handled by the registry before
adapter selection. Exact matches outrank assignable matches; among assignable matches the smallest non-negative
distance wins; capability matches are considered only when neither exists, with highest priority winning. Any tie
at the winning rank is a configuration error naming every conflicting adapter. `expected` validates or selects a
projection offered by the winning adapter; it does not let a desired result type silently change which adapter
owns the native value.

Built-in literal, collection, data-class, Java-record and graph integrations participate through the same
registry contract, although a platform implementation may inline their hot paths. `DataAdapterId` is a non-empty
stable identifier used in diagnostics; it is not a concrete-class dispatch key exposed to consumers.

### 7.4 Cycles and identity

Native and graph objects may be cyclic. Lifting therefore does not recursively materialize them. A view retains
identity and resolves fields on demand. Snapshot conversion detects revisited identities and applies its explicit
cycle policy—normally a diagnostic/reference marker or failure—not unbounded recursion.

## 8. Graph-managed object interaction

“Graph-managed” here means an object instantiated through kzen's Notation → Definition → Instance pipeline. It
does not mean a database graph, and it does not make every object in `GraphInstance` globally available as data.

The interaction occurs only when a graph-created object is explicitly passed or returned across a data boundary.
At that point the adapter has both:

- `ObjectInstance.reference`, the actual Kotlin object; and
- its `ObjectDefinition` plus `ObjectInstance.constructorAttributes`, which describe how the graph created it.

The resulting value has a nominal identity and may offer two views:

1. **Native view.** Kotlin code requesting the declared class receives the original reference, with no copy.
2. **Structural view.** Generic data processing sees only attributes admitted by the graph-data exposure policy.

### 8.1 Structural exposure policy

`constructorAttributes` alone is not a safe public-record definition. It may contain services, creator inputs,
self-location infrastructure and resolved object references. The graph adapter must use definition metadata and
an explicit exposure policy rather than reflect every constructor argument indiscriminately.

The baseline policy is:

- expose authored/defaulted value attributes as fields;
- preserve nested list and map definitions structurally;
- expose an authored object reference as a lazy nominal/reference field, without recursively expanding the
  target by default;
- exclude `ServiceAttributeDefinition` values;
- exclude creator dependencies and creator/runtime infrastructure; and
- exclude self-location or equivalent framework-injected parameters unless metadata explicitly marks them as
  data.

The current definition model distinguishes service and reference attributes, but does not fully label “authored
data” versus every creator-supplied value. Accepting this proposal therefore implies adding declarative exposure
metadata or an equivalent graph adapter policy before generic structural traversal is implemented. Guessing from
names or reflecting all public properties is not acceptable.

### 8.2 References stay lazy and bounded

A reference field may expose its stable reference and, while the owning graph snapshot is live, permit explicit
navigation to the referenced object's view. It is not automatically expanded into the parent record. This avoids
cycles, enormous accidental snapshots and hidden graph walks.

Snapshot serialization chooses deliberately whether to emit only the reference, follow it to a bounded depth, or
reject it. That choice belongs to the snapshot request, not the graph object itself.

### 8.3 No write-through

Changing a field in a structural graph view would be ambiguous: should it mutate the live Kotlin instance, write
notation, rerun definition and creation, or affect only a temporary copy? The read model therefore has no such
operation. A graph mutation remains a notation command/reducer followed by normal graph refresh.

### 8.4 Conversion is intentionally asymmetric

A graph-managed object can be read as native or structural data because its definition, creator, dependencies,
identity and lifecycle already exist. An arbitrary record-shaped `DataValue` cannot automatically become a
graph-managed object. Doing so would have to invent:

- an object location and notation;
- a definer and creator;
- reference/dependency resolution;
- service injection;
- persistence and refresh behaviour; and
- ownership of the resulting instance.

That operation, when needed, is an explicit graph creation/import command with a target archetype and mapping.
It is not the inverse of reading a value.

## 9. Durable rows and managed project data

A durable project store fits the same read model. A typed row exposes a `Record` through a row-backed
`ValueAccess`; a query exposes a cursor of those values; storage-native schema details may accompany the semantic
`DataType` when needed for migration or lossless writing.

The same immutability rule applies. Reading a field does not silently issue an update. Mutations use an explicit
store operation with transaction, validation and authorization semantics. A successful write may return a new
row view or stable row reference.

Graph notation and project data remain different persistence tiers:

- notation defines configured objects, inheritance and executable structure;
- the durable store holds potentially large, mutable application records; and
- a stable reference may connect the tiers without embedding a live row or graph instance in the other.

The unified model lets both tiers feed the same Logic without pretending that they share write lifecycle or
storage mechanics.

## 10. Enumerable, typed Logic bindings

The replacement for `TupleDefinition` plus `TupleValue` is one ordered binding set whose declaration and state
cannot drift:

```kotlin
@JvmInline
value class BindingName(val value: String)

class DataBindings private constructor(
    val entries: List<DataBinding>
) {
    operator fun get(name: BindingName): DataBinding
    fun find(name: BindingName): DataBinding?
    fun names(): List<BindingName>
    fun requireValue(name: BindingName): DataValue
}

data class DataBinding(
    val definition: DataBindingDefinition,
    val state: BindingState
)

data class DataBindingDefinition(
    val name: BindingName,
    val type: DataType,
    val presence: DataPresence = DataPresence.Required,
    val sensitive: Boolean = false
)

sealed interface BindingState {
    data object Unbound: BindingState
    data class Bound(
        val value: DataValue,
        val origin: BindingOrigin
    ): BindingState
}

enum class BindingOrigin {
    Supplied,
    Defaulted,
    Produced
}
```

`BindingName` is a non-empty canonical string unique within the binding set. `DataPresence` and `DataDefault` are
the same definitions used by record fields: omission, nullability and defaulting therefore have one meaning
throughout the model. Nullability belongs to `DataType`; presence belongs to the containing field or binding.

`DataBindings` has validated factories rather than a public constructor. A factory takes ordered definitions and
supplied name/value pairs, rejects duplicate definitions and supplied names, rejects unknown supplied names,
checks each value against its declaration, and applies detached or computed defaults. The exact factory names may
change before implementation; those construction rules should not.

### 10.1 Behaviour

- Definitions and values share one entry, so they cannot be reordered independently.
- Iteration is stable and safe for UI/diagnostics.
- Lookup returns a binding state, not `Any?`.
- A bound null is a `Bound` value whose root state is `Null`; it is not `Unbound`.
- Defaults are applied once by binding construction and record `Defaulted` origin.
- Unknown supplied names and duplicates fail at the boundary that creates the set.
- Type acceptance is checked when a value is bound, not deferred until a consumer casts it.
- Sensitive values expose names, types, states and origins but redact previews.

Omitted optional inputs remain present as `Unbound`, because enumeration describes the whole signature. An
unbound required input is representable while editing or assembling a request, but validation for execution fails.
A defaulted input is never unbound after successful execution validation: the factory binds its default and marks
the origin `Defaulted`.

### 10.2 `DataContext`

The source context becomes:

```kotlin
interface DataContext {
    val arguments: DataBindings

    suspend fun host(
        instructions: ObjectLocation,
        arguments: DataBindings
    ): DataBindings

    suspend fun <R> blocking(block: () -> R): R
}
```

A convenience lookup may return `DataBinding` or require a typed `DataValue`; it must not restore
`argument(name): Any?` as the primary contract.

At design time, routing parameters such as action/source identifiers are removed before constructing argument
bindings. Repeated request values bind as a listing, not through `singleOrNull()`. Missing, one-valued and
multi-valued request parameters therefore remain distinguishable.

At runtime, `LogicDataSource` binds only declared argument names, uses the callee's definition to apply defaults,
and fails on a required unbound input. Optional source-side renaming is an explicit name mapping. It does not
inspect or cast arbitrary `Any?` values.

## 11. End-to-end use by Logic flavours

### 11.1 Core Logic

`Logic.signature()` declares `DataBindings` definitions for input and output. `Execution.inputs` and
`Execution.host` use bound `DataBindings`. A Logic may still call arbitrary Kotlin or resource APIs internally;
the unified model governs values entering or leaving the computation, not every local variable.

Opaque execution resources—browser handles, database connections, migration state—remain `Any` or typed Context
bindings because they are capabilities, not dataflow values. Removing `Any?` from dataflow does not imply turning
every resource into `DataValue`.

### 11.2 Script

Generated step code receives the most ergonomic supported view:

- a native-backed value of the requested type is passed as the original object;
- a structural backing is read through generated accessors derived from `DataType`; and
- a step result is automatically lifted when recorded or handed to another step.

This preserves ordinary Formula expressions while allowing a value from CSV, JSON, a row or a graph object to be
consumed through the same typed expression surface.

### 11.3 Flow

Flow ports declare `DataType` and carry `DataValue` (or engine batches of it). Port connection validation uses
`accepts`; runtime delivery does not erase the element to an unrelated `Any?`. A custom vertex can request native
projection where available or structural access otherwise.

### 11.4 Job

Job channels carry one `DataValue` per domain element. Batching remains a channel transport concern and can keep
its existing ownership/cadence behaviour.

`JobMessage(payload, flat)` and `WorkerLane(payloadType, flatColumns)` cease to be the target design. A Worker
receives one value and one semantic type. Column-oriented Workers request a record/tabular projection:

- records expose their ordered fields;
- scalars may project to an explicit synthetic `value` field;
- mappings require a declared or observed key projection; and
- nominal values require a structural adapter or fail with a useful capability error.

A calculated-column Worker returns a composed record value rather than mutating a second flat half into a
message. A result sink or nested Logic host passes the same semantic value across the boundary instead of choosing
between payload and materialized map rules.

### 11.5 Data sources

The source model remains responsible for resolving manifests, selecting parts and opening cursors. Its generic
data boundary becomes:

```kotlin
interface DataCursor: Iterator<DataValue>, AutoCloseable {
    val shape: DataShape
}
```

`DataUnit`, `DataPart` and `DataRef` remain source-selection values; they can themselves lift through the native
adapter when passed through Logic. An opener chooses the most appropriate backing for emitted items. A CSV opener
uses flat-record access; a database opener uses row access; an authored Logic source receives and returns typed
bindings.

No source-specific payload category is introduced.

## 12. Wire, trace and diagnostic boundaries

### 12.1 Why the detached tree is `WireValue`

`ExecutionValue` is too narrow for its existing role: the type already carries detached-action responses,
data-source models, requests, results, traces, serialization payloads and digest input. Using it for defaults would
make the mismatch more visible. The target name is `WireValue` because the value is canonical boundary data even
when it is temporarily held in memory rather than immediately sent over a network.

`StructuralValue` is rejected because it would collide conceptually with `DataValue` and `ValueAccess`, the live
structural model. `ValueTree` accurately describes the representation but not its boundary role. `SnapshotValue`
is too narrow because authored defaults and requests are not snapshots of a live value.

The rename includes the variants (`TextWireValue`, `ObjectWireValue`, and so on) and moves the model out of the
execution-specific package. It should land with the unified-model cutover rather than as a standalone cosmetic
rename across the current call sites.

### 12.2 Conversion and snapshot policy

`WireValue` is the canonical detached wire/trace vocabulary. Conversion from `DataValue` is explicit and
policy-bound:

```kotlin
sealed interface ReferenceSnapshotPolicy {
    data object Reject: ReferenceSnapshotPolicy
    data object IdentityOnly: ReferenceSnapshotPolicy
    data class Follow(val maximumReferences: Int): ReferenceSnapshotPolicy
}

enum class SensitiveSnapshotPolicy {
    Redact,
    Reject
}

enum class SnapshotLimitPolicy {
    Fail,
    TruncateWithDiagnostic
}

data class SnapshotPolicy(
    val maximumDepth: Int,
    val maximumElements: Int,
    val maximumTextLength: Int,
    val maximumBinaryBytes: Int,
    val maximumDurationMillis: Long,
    val referencePolicy: ReferenceSnapshotPolicy,
    val sensitivePolicy: SensitiveSnapshotPolicy,
    val limitPolicy: SnapshotLimitPolicy = SnapshotLimitPolicy.Fail
)
```

All numeric limits are strictly positive. `maximumElements` is cumulative across the snapshot, not per
collection. `IdentityOnly` emits a stable reference only when the backing supplies one and otherwise fails.
`Follow` follows at most `maximumReferences` distinct identities while still respecting every global limit.
`Redact` emits a canonical redaction marker; `Reject` refuses to snapshot a sensitive binding. Truncation always
emits a diagnostic identifying the exceeded limit, so a truncated snapshot cannot be mistaken for complete data.

`BlobReferenceWireValue` does not make every conversion reference-capable. It is emitted only when the policy and
calling protocol provide a resolver scope. `DataDefault`, canonical type definitions and other permanently
self-contained locations reject it recursively. A trace may emit it for large binary content because its trace
blob endpoint supplies the corresponding scope.

`ObjectWireValue` is the efficient JSON-object-shaped container for protocol objects, record encodings with
unique text keys, and `Mapping(Scalar(Text), ...)`. It is not the universal encoding of `DataType.Mapping`.
Mappings with any other scalar key type lower to `MappingWireValue`, whose entries retain each key as a
`ScalarWireValue`. The distinction prevents dates, integers or binary keys from being silently stringified and
then misread as text.

The conversion must:

- preserve absent versus null where the destination protocol supports it, or report the loss explicitly;
- bound depth, collection size, text/binary size and traversal time;
- detect cycles and repeated identities;
- avoid arbitrary `toString()` fallback for unknown nominal objects;
- redact sensitive bindings before preview generation; and
- fail or emit a structured diagnostic when a value has no permitted representation.

Routine diagnostics should not materialize data. A binding summary can safely display ordered names, declared
types, bound/unbound state and origin. Value previews are separate, bounded requests.

Digest and equality rules also distinguish semantic contracts from live identity:

- `DataType` and binding definitions have canonical structural digests;
- a literal/snapshot value may have a content digest;
- a live native, graph or row view does not claim content equality unless its adapter explicitly supplies it;
  and
- source manifests retain their existing point-in-time digest semantics.

## 13. Alternatives considered

### 13.1 Keep `Any?`, add `arguments()`

Enumeration would improve display, but every value would remain untyped and missing would still collapse with
null unless a second lookup-state API were added. Definitions, values and origins would remain parallel data
structures. This fixes the most visible symptom but not the boundary.

### 13.2 Use `Map<String, Any?>`

A map enumerates names but loses declarations, stable component order, defaults, origin and state. It also makes
the runtime type of every value an unchecked convention. It is `TupleValue` with less domain vocabulary.

### 13.3 Make `DataContext.argument<T>(name)` generic

An inline/reified convenience can improve a caller's cast, but it cannot tell the caller what names exist, carry
a cross-platform structural type, represent an unbound value, or validate a dynamic host call before lookup. It
may sit above `DataBindings`; it cannot replace them.

### 13.4 Use `WireValue` everywhere

Renaming today's `ExecutionValue` does not make it the live runtime model. Using `WireValue` everywhere would
still impose eager copying, lose native identity, narrow the type system and damage streaming/row performance. It
would confuse a boundary format with a runtime value.

### 13.5 Add `DataShape.Both`

`Both` says a carrier currently has two views, not what the value means. Every new backing would invite another
case or combination. A record plus capability-driven projections expresses the same useful access without
encoding transport history into the type language.

### 13.6 Materialize every value into one universal tree

This simplifies one accessor while imposing allocations and retention on every producer. It discards the main
benefit of flat rows, streaming tapes, native objects and driver-backed rows. One access contract with multiple
backings provides semantic consistency without physical uniformity.

### 13.7 Reflect every public property

Public APIs contain behaviour as well as data. Getters may perform I/O, mutate state, reveal services or expose an
unstable implementation detail. Automatic structure is restricted to strong data signals—data classes, Java
records, graph exposure metadata—or an adapter explicitly registered by the owner.

### 13.8 Require wrappers in Formula and plugin code

This would make the framework mechanically pure at the expense of every user-facing handoff. Since the engine
already owns step, port, channel and Logic boundaries, it can lift values once at those boundaries. Adapter
registration is acceptable infrastructure ceremony; repeated value wrapping is not.

### 13.9 Make views write through

There is no universal meaning for a field assignment across native objects, notation-defined graph objects,
cursor rows and durable records. A read-only common contract with explicit system-owned mutation preserves
transactions, CQRS and lifecycle semantics.

### 13.10 Automatically create graph objects from records

A record does not contain the graph identity, creator, services, dependency rules or notation lifecycle needed
to create a managed object. An explicit import/create operation can supply those choices. Hiding them in ordinary
value conversion would be unpredictable and unsafe.

### 13.11 Keep separate Script, Flow and Job data models

Their execution mechanics differ, but separate value models force conversion at every composition boundary and
allow type rules to drift. A foundational model costs one deliberate cross-repository cutover and removes that
permanent duplication.

### 13.12 Parameterize one `DateTime` by timezone semantics

Local, offset, region-zoned and absolute timestamps are different meanings rather than configuration modes of one
scalar. A `None | Offset | Region` parameter still omits the actual zone/offset and conflates semantic comparison
with representation preservation. The initial core uses `Instant` for absolute timestamps and does not claim that
it represents local date-time. Additional temporal types require a concrete processing contract before joining
the core.

### 13.13 Add an open-ended `Logical(id, storage)` scalar

A storage kind would make a custom scalar transportable but would not define its validation, canonicalization,
compatibility, provider lookup or explicit projection rules. Shipping only the two fields would hide a registry
contract. `Nominal` plus adapters is sufficient for the current requirements; a refined-scalar extension should
land only with a concrete consumer that settles the whole contract.

### 13.14 Keep a separate `DataScalar`

`DataScalar(kind, canonical)` originally gave map keys and discriminator values a portable identity, but
`WireValue` now has the same responsibility. Keeping both would create two detached scalar vocabularies and
conversion rules. The model instead uses `ScalarWireValue`; the enclosing `DataType` supplies semantic meaning,
while specialized `ValueAccess` reads preserve allocation-free hot paths.

### 13.15 Put external discriminator layouts in `DataType`

An external key, adjacent wrapper, message header or discriminator column describes where one format stores
selection information; it is not part of the selected value's semantic type. Encoding those layouts in
`DataType.Union` would couple every consumer to representation policy. A codec resolves its own layout to a
`VariantId` and validates that choice against the semantic union. Only a discriminator field that is itself part
of every variant record belongs in `DataType`.

## 14. Consequences if accepted

The natural owner is `kzen-lib-common`: `Logic`, `Execution`, tuples and graph definitions already live there,
and every Logic flavour depends on it. JVM reflection/native/row adapters may live in platform source sets or in
consumer modules while implementing the common capability contract.

This is a foundational replacement, not a Job feature. The implementation should be sequenced conceptually as:

1. define and test `DataType`, shape observations, values/access, bindings and bounded `WireValue` snapshots in
   `kzen-lib-common`;
2. add literal, native, graph and flat-record backings plus generated expression access, validating allocation
   and lifetime behaviour before changing public Logic APIs;
3. cut Logic, Script, Flow, Job and data-source boundaries over together, then delete tuples and the
   payload/flat split rather than maintain two dataflow models; and
4. add the real durable-row backing when project storage lands, first proving the seam with a fake typed-row
   access implementation.

This ordering is evidence for feasibility, not an approved execution plan. Exact package layout and rollout work
belong in a constituent plan only after this analysis is accepted.

No version bump follows automatically. Cross-repository publication order would be kzen-lib before kzen-auto and
its consumers, at the existing coordinated development version.

## 15. Validation required before adoption

The proposal should not be accepted on API aesthetics alone. A prototype or implementation plan needs to prove:

### Semantic model

- canonical wire/digest round-trips for every `DataType` case;
- canonical `WireValue` round-trips for every leaf/container, non-finite floating values and blob references;
- scalar wire equality/order and mappings with text, integer, date and binary keys;
- recursive rejection of blob references in `DataDefault.literal`;
- canonical `Date`, `Time`, `Instant` and `Duration` values, including rejection of local date-times where an
  `Instant` is required;
- representative `accepts` and `join` pairs, including nullability, optional fields and unions;
- undiscriminated scalar/list unions, field discriminators and aliases, externally decoded variant IDs, and
  deterministic rejection of overlapping undiscriminated variants;
- stable field identity and duplicate display-name projection;
- distinct absent, null, defaulted and invalid states; and
- `TypeMetadata`/`KType` conversion with no application-specific branches.

### Bindings

- deterministic enumeration and lookup;
- unknown and duplicate name failures;
- required, optional and defaulted inputs;
- a present-null binding distinct from unbound;
- origin and sensitive-redaction behaviour; and
- design request handling for zero, one and repeated values after routing parameters are removed.

### Adapters

- primitives, literal collections, maps and arrays;
- Kotlin data classes and Java records;
- arbitrary nominal objects with native access but no accidental reflection;
- custom adapter precedence/conflict detection;
- graph values with services/infrastructure excluded and references lazy;
- cycles and repeated identities; and
- bounded snapshot diagnostics without arbitrary `toString()`.

### End-to-end composition

- a Formula returns an ordinary data class without wrapping;
- Script → Flow → Job → nested Logic preserves its semantic type and value;
- the same record is consumable from a native object, CSV row, structural tape and fake typed row;
- column projection works without adding a second payload/flat carrier;
- data-source arguments enumerate correctly and hosted results return typed bindings; and
- missing/default/null behaviour is identical across every Logic flavour.

### Lifetime and performance

- cursor advance, close, cancellation, migration and ownership transfer do not leave usable dangling views;
- retained results detach or retain their backing explicitly;
- primitive field reads allocate nothing after setup;
- field traversal creates no per-field `DataValue` objects;
- flat input is not eagerly materialized; and
- the representative Job data path stays within five percent of its current median throughput unless an
  explicitly measured capability justifies the cost.

## 16. Recommendation register

These are recommendations for review, not landed decisions.

| # | Question | Recommendation |
|---|---|---|
| UD1 | One model for every Logic flavour? | Yes; execution mechanics remain flavour-specific |
| UD2 | Foundation owner? | `kzen-lib-common` |
| UD3 | Runtime representation? | One immutable `DataValue` over multiple `ValueAccess` backings |
| UD4 | `Tabular`, `Payload`, or both? | None as type cases; use semantic types and explicit projections |
| UD5 | Must every union have a discriminator field? | No; arbitrary variants are allowed, a field discriminator is optional, and ambiguous structural selection fails |
| UD6 | Normal Formula experience? | Return ordinary Kotlin objects; lift automatically at the boundary |
| UD7 | Automatic structural native baseline? | Primitives/collections plus Kotlin data classes and Java records; arbitrary objects remain nominal |
| UD8 | Arguments/results? | Ordered, enumerable, typed `DataBindings`; no primary `Any?` lookup |
| UD9 | Missing versus null? | Always distinct |
| UD10 | Graph object read? | Original native instance plus policy-limited immutable structural view |
| UD11 | Graph object write? | Explicit notation command; never `DataValue` write-through |
| UD12 | Record → managed graph object? | Explicit import/create operation only |
| UD13 | Durable row read/write? | Row-backed immutable view; explicit transactional mutation |
| UD14 | Wire and trace model? | Rename `ExecutionValue` to `WireValue`; keep it as an explicit bounded boundary tree |
| UD15 | Performance strategy? | Primitive handles, cached/generated adapters, no eager materialization, benchmark gate |
| UD16 | Migration style? | One coordinated cutover; do not preserve a parallel legacy dataflow model |
| UD17 | Temporal baseline? | `Date`, `Time`, `Instant`, `Duration`; no parameterized timezone mode |
| UD18 | Open-ended logical scalars? | Exclude initially; use `Nominal` plus adapters until a concrete refined-scalar contract is needed |
| UD19 | Separate detached `DataScalar`? | No; use `ScalarWireValue` for keys, discriminator values and generic scalar reads |
| UD20 | External discriminator layouts? | Codec-owned; they resolve to `VariantId` and do not appear in `DataType` |

## 17. Questions that remain legitimately open

The proposal is coherent without pretending every implementation detail is settled. Before an execution plan is
approved, the following need prototypes or explicit decisions:

1. **Graph exposure metadata.** Which existing metadata can reliably distinguish authored data from injected
   constructor infrastructure, and what minimal new marker is required where it cannot?
2. **Common-platform adapters.** Whether Kotlin data-class adapters outside the JVM should be compiler-generated,
   serialization-derived, or remain nominal until a concrete JS consumer requires structural access.
3. **Node-handle layout.** The primitive encoding and accessor split that support native, tape and row backings
   without allocation or unsafe lifetime leakage.
4. **Identity in snapshots.** The canonical wire representation for repeated/cyclic graph or native references,
   including whether the default is reference markers or a hard failure.
5. **Lossless schema metadata.** Which provider-specific details live beside `DataType` for database migrations
   and structured writers without polluting the semantic access language.
6. **Tabular projection policy.** Exact duplicate-name, nested-field and mapping-key rules for consumers that
   explicitly request columns.
7. **`WireValue` JSON grammar.** Whether the implementation preserves the current `{type, value}` envelope or
   introduces a versioned grammar for exact integers, decimals and blob references. The semantic variants and
   canonical round-trip requirements above do not depend on that spelling.

Those are reasons to review and prototype the proposal before implementation. They are not reasons to retain the
current opaque and duplicated boundaries.
