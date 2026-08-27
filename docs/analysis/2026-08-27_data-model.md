# Unified data model — types, values, bindings and managed-object views

> **Status: proposal for review, revised after design review; not an implementation contract.** This document
> holds the complete current argument for a data model shared by every Logic flavour. It does not authorize code
> changes or alter the implementation status of any plan. The independent 2026-08-27 design review has been
> folded in and its file removed — corrections are applied in place, and §18 records the disposition of every
> review finding so the review is not a second source of truth. If the proposal is accepted, this document owns
> the generic type/value/binding contract: the [data-source model](2026-08-20_data-source-model.md) keeps
> source selection (refs, parts, units, manifests, resolve/open), the [Job adapter](2026-08-20_job-data-source.md)
> keeps Job execution and the DS as-built record, and the [project-data analysis](2026-08-26_database.md) keeps
> formats, providers, readers and durable storage while ceding its type-language and runtime-value sections
> here (§14.4). Per CC-20 no line numbers are cited; anchors are class / file / doc-section names.

The former `2026-08-23_job-data-source_review.md` is not present in the tree. Its surviving conclusions were
consolidated into the data-source and Job analyses; this document carries forward the relevant model findings
rather than depending on the missing review as a source.

## 1. Conclusion

A unified model is possible, and it changes the design materially.

The useful unification point is neither `Any?`, a generic map, nor a serialized tree. It is a read-only semantic
value with:

- one recursive structural `DataType`, where any node may additionally be annotated with the native Kotlin type
  it also is;
- one `ValueAccess` implementation describing how to read its current backing;
- one opaque root handle locating the value in that backing; and
- typed, enumerable `DataBindings`, validated against a `BindingSchema`, at named Logic boundaries.

The backing may be a Kotlin object, a literal list or map, a flat file record, a structural tape, a graph-created
object, or a durable-store row. Consumers use the same semantic operations without first copying every value into
one universal representation. Ordinary Script and Formula code continues to use ordinary Kotlin values. The
framework lifts those values automatically when they cross a processing boundary and projects them back to a
native value when that is the most natural view.

The central correction adopted from review is this:

> One value may offer more than one orthogonal projection — native, structural, tabular. The target is one
> authoritative value with one type and explicit projections, not one carrier forced to have exactly one
> mutually exclusive type.

A Kotlin data class is simultaneously a native `Reading` and a structural record. A graph-created object retains
its native class and exposes a policy-limited record. A typed database row exposes a record and promises no native
class. Those are derived views of one value. They are not the defective `payload + flat` pair in today's
`JobMessage`, which holds two *authoritative* representations that producers must keep synchronized by hand.

This is not a compatibility layer around the current split. The current split is the defect to remove:

- `TupleValue` preserves names but stores opaque `Any?` values, and `TupleDefinition` is a parallel structure;
- `DataContext.argument(name): Any?` and `JobControl.parameter(name): Any?` hide the available names and collapse
  missing with present-null;
- Script step results (`ScriptLogic.implicitResult`, `ScriptReplayState`'s outcome and carry maps) and Flow ports
  (`RequiredInput<T>` / `FlowVertex.inspectMessage(message: Any)`) independently traffic in `Any?`;
- Job carries `JobMessage(payload, flat)` and separately describes a lane as `WorkerLane(payloadType, flatColumns)`,
  with lossy bridges in both directions (`flatView()`, `boundaryValue()`);
- `DataSchemaDocument.shape()` parses a field's `TypeMetadata` and then discards it, because `HeaderListing` has
  nowhere to hold a type;
- today's `ExecutionValue` is a useful wire and trace tree, but it cannot retain native identity or provide lazy
  structural access; and
- `DataShape.Tabular | Payload` describes current carriers rather than the data.

Adding a `Both` case would preserve the same mistake. A Kotlin data class and a database row may both be records;
one being a native object and the other being row-backed is a representation difference, not a semantic type
difference.

### 1.1 Three layers

| Layer | Question | Proposed owner |
|---|---|---|
| `DataType` / `DataShape` | What does this value mean, which native type is it also, and how was that learned? | `kzen-lib-common` |
| `DataValue` / `ValueAccess` | How can this value be read without requiring one physical representation? | `kzen-lib-common` contract; JVM backings in platform / consumer modules |
| `BindingSchema` / `DataBindings` | Which named values are declared, bound, defaulted, missing or produced? | `kzen-lib-common` Logic boundary |

Data sources, Script, Flow and Job become consumers of this foundation. None owns a parallel value model.

### 1.2 The v1 target is smaller than the complete model

The review's second correction is also adopted: the first cut proves the foundation vertically with the backings
that exist today, and defers every extension until a named consumer forces it. Deferral is not rejection — each
row's right-hand column names what reopens it.

| Area | v1 — foundational proof | Deferred until a named consumer |
|---|---|---|
| Types | Scalar, Record, Mapping, Listing, tagged Union, Opaque, Dynamic; optional native annotation on every node | structural union inference; field discriminators in the type; enum kind; open-ended logical/refined scalars |
| Values | read-only `DataValue` over literal, flat-record, native-object and fake typed-row backings; independently owned cursor items | structural tape (first tree reader); graph structural exposure and reference navigation; composed overlay chains; borrowed / retainable leases (first JDBC source) |
| Bindings | `BindingSchema` + validated `DataBindings`; literal defaults; whole-binding sensitivity | computed defaults; nested field sensitivity |
| Wire / trace | today's `ExecutionValue` inside a typed `DataSnapshot` envelope; complete-or-rejected snapshots | `WireValue` rename and versioned grammar; truncation markers; identity references; reference following |
| Adapters | primitives, lists, arrays, maps, Kotlin data classes, Java records; exact-class registrations; ordered capability fallbacks | `Iterable` / `Sequence` / `Set` lifting (explicit streaming boundary instead); public-getter reflection (never) |

## 2. What is wrong with the current boundary

### 2.1 `Any?` is a legitimate native edge, but a poor data contract

`Any?` is appropriate when Kotlin code calls arbitrary user code or stores an opaque resource handle. It is not
enough for a framework data boundary. Given an `Any?`, generic code cannot answer:

- whether the name was absent or explicitly bound to null;
- what names are available;
- what type was declared independently of the current runtime value;
- whether a field is absent, null or defaulted;
- whether an object may be traversed structurally;
- whether conversion would allocate or read a live resource;
- whether a value may safely outlive its cursor, transaction or execution frame; or
- how to serialize or display it without accidentally calling an arbitrary `toString()`.

The current `TupleValue.find` and `DataContext.argument` both return `Any?`. A missing component and a present
component whose value is null have the same result. `DataContext` does not expose its names, definitions or
origins at all. This prevents even a safe diagnostic such as "arguments: from: String (supplied), to: String
(defaulted)" without reaching behind the API into a particular runtime implementation.

The fact that the underlying implementations already have more information makes the loss unnecessary:
`JobControl.parameters()` has a `TupleDefinition`, while design requests already hold a name-to-values map. The
opacity is introduced by the interface rather than forced by the sources.

### 2.2 Type metadata and runtime values drift apart

`LogicType` wraps `TypeMetadata`, while `TupleComponentValue` holds an unrelated `Any?`. Job repeats the split in
`WorkerLane` versus `JobMessage`. Correctness relies on each producer updating two descriptions consistently and
each consumer knowing which physical half to inspect.

That is already visible in Job's boundary rules. A payload crosses a Logic boundary unchanged, but a flat record
crosses as a newly materialized `Map<String, String>`. A column consumer asks `flatView()` to mutate a payload
message into a second representation, and `FormulaWorker.onElement` appends to the flat part and replaces the
payload in the same call. This is ingenious as a local interoperability mechanism, but it is not a stable general
data model: meaning, representation, ownership and projection are all encoded in one mutable carrier.

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

`ExecutionValue` is retained in v1 as the detached tree, reached only through an explicit typed snapshot
conversion (§12). The eventual `WireValue` rename and richer grammar are deferred until a demonstrated boundary
cannot lower through the existing tree. That conversion is never the cost of an in-process handoff.

## 3. Design principles

1. **Meaning is independent of storage.** A record is a record whether backed by a data class, CSV row, database
   result, structural tape or graph instance.
2. **One value crosses a boundary.** There is no parallel payload plus flat carrier and no parallel runtime value
   plus out-of-band shape that producers must keep synchronized.
3. **Native authoring stays native.** A Formula may return a data class, list, scalar or managed object without
   constructing a framework wrapper.
4. **Automatic conversion happens at framework boundaries.** Adapter registration is an infrastructure concern,
   not ceremony repeated in every Script or Worker.
5. **Views are read-only.** Reading through `DataValue` never mutates a Kotlin object, graph instance or durable
   row. "Immutable" is reserved for snapshots and for backings that own frozen data; a live view over a mutable
   native object is read-only, not immutable.
6. **Missing is not null.** Unbound, absent, null and defaulted are observable distinct states.
7. **No compulsory universal materialization.** Backings share access semantics, not necessarily memory layout.
8. **Cheap paths remain cheap.** A flat record keeps its indexed storage and primitive caches. Reading one field
   must not allocate a nested wrapper object.
9. **Capabilities are extensible.** New structural or native integrations register adapters; generic code does
   not branch on concrete application type names (CC-17).
10. **Snapshots are explicit.** Serialization, tracing, retention and cross-process transport take bounded
    snapshots. A live view is not accidentally treated as durable.
11. **Ownership remains visible.** Cursor-, transaction- and execution-scoped backings cannot be retained after
    their owner settles unless explicitly detached or copied.
12. **Existing defects are not design constraints.** A current split may explain migration cost, but it is not a
    reason to reproduce the split in the target model.
13. **Static knowledge comes first.** The declared type of a binding, port or schema, or the compiler-inferred
    `KType` of a Formula, is the primary source of a boundary type. Runtime inspection of the value refines or
    validates it; it is not the primary source when a static type exists.

## 4. The semantic type language

`DataType` describes the semantic operations a consumer may perform. It is recursive and independent of the
runtime backing. Every node carries two orthogonal facets: its structural case, and an optional **native
annotation** naming the Kotlin type the node's runtime value may also be handed to without copying.

```kotlin
data class FieldId(
    val name: String,
    val occurrence: Int = 0
)

@JvmInline
value class VariantId(val value: String)

data class DataField(
    val id: FieldId,
    val type: DataType,
    val presence: DataPresence = DataPresence.Required
)

sealed interface DataPresence {
    data object Required: DataPresence
    data object Optional: DataPresence
    data class Defaulted(val default: DataDefault): DataPresence
}

data class DataDefault(
    val literal: ExecutionValue
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
    val type: DataType
)

sealed interface DataType {
    val nullable: Boolean
    val native: TypeMetadata?

    data class Scalar(
        val kind: ScalarKind,
        override val nullable: Boolean = false,
        override val native: TypeMetadata? = null
    ): DataType

    data class Record(
        val fields: List<DataField>,
        override val nullable: Boolean = false,
        override val native: TypeMetadata? = null
    ): DataType

    data class Mapping(
        val key: DataType,
        val value: DataType,
        override val nullable: Boolean = false,
        override val native: TypeMetadata? = null
    ): DataType

    data class Listing(
        val element: DataType,
        override val nullable: Boolean = false,
        override val native: TypeMetadata? = null
    ): DataType

    data class Union(
        val variants: List<DataVariant>,
        override val nullable: Boolean = false,
        override val native: TypeMetadata? = null
    ): DataType

    data class Opaque(
        override val native: TypeMetadata,
        override val nullable: Boolean = false
    ): DataType

    data class Dynamic(
        override val nullable: Boolean = true
    ): DataType {
        override val native: TypeMetadata? get() = null
    }
}
```

`TypeMetadata` and `ExecutionValue` are existing kzen-lib types. Every other referenced type is defined above. The
syntax is a proposal rather than a frozen ABI, but the semantics and invariants below are part of the proposal; an
implementation should not silently fill them in differently.

### 4.1 The native annotation

`native` answers a different question from the structural case: not "what operations does this value support"
but "which Kotlin type may native code receive this value as, without a copy". The two facets are set together by
the adapter that lifted the value, so they cannot drift, and either may be absent:

| Value | Structural facet | Native facet |
|---|---|---|
| CSV row | `Record` of `Scalar(Text)` fields | none promised |
| Kotlin `data class Reading(sensor, value)` | `Record(sensor: Text, value: Floating)` | `Reading` |
| Nested field `order.customer` of type `Customer` | `Record(...)` | `Customer` |
| Arbitrary opaque Kotlin object | `Opaque` | its declared class |
| Typed database row | `Record` | optional provider-owned row type |
| Graph-created data object | exposure-policy `Record` | its created class |
| `List<Reading>` | `Listing(Record(..., native = Reading))` | `kotlin.collections.List` |

The annotation is recursive, which is why it is a per-node facet rather than a top-level
`DataDescriptor(structural, native)` pair: generated Script code that reads `order.customer` needs the nested
node's native type to hand `Customer` to a native member call, and a top-level descriptor would have lost it.

Compatibility is projection-specific. A native consumer (generated Kotlin calling members of `Reading`) asks
whether the annotation is assignable to the type it compiles against. A structural consumer (Sort, Filter, a
table, a writer) asks whether the structural facet accepts its requirement and ignores the annotation. The
algebra in §4.7 takes the requirement explicitly rather than guessing which facet a caller means.

Canonical equality and digests include the annotation: `Record(...)` with `native = Reading` and the same record
with no annotation are different lane types, because a native consumer compiled against the first breaks on the
second. Structural comparison, used by `isAssignable` under a structural requirement, ignores it.

### 4.2 Identifiers and the wire tree

Identifiers are non-empty canonical strings. A `FieldId` is unique only within its enclosing `Record`; a
`VariantId` is unique only within its enclosing `Union`. Display labels are derived from identity, not the other
way round.

`FieldId(name, occurrence)` deliberately reuses the identity shape of today's `HeaderLabel`, which two shipped
contracts already depend on (`DataReadCore.planShape`'s superset union and `JobMessage.boundaryValue()`'s key
rendering). Authored schemas — `DataSchemaFieldListSpec` keys fields by name — always use occurrence zero;
inferred CSV headers with duplicate names use the occurrence, and `HeaderLabel.render()` remains the display
rule. Provider-native numeric IDs and aliases (protobuf, Parquet, Avro) live beside `DataType` as lossless schema
metadata. An independently persisted opaque field ID is added only when a rename-or-reference consumer requires
it; until then, one identity shape serves both structural fields and tabular headers.

`DataDefault.literal` is an `ExecutionValue` and must be recursively self-contained: it may not contain a
`binary-handle`. It is detached canonical data, not a live native object or executable expression. Its decoded
type must be accepted by the field or binding type. A computed default belongs to binding construction and must
produce the same explicit `Defaulted` origin; it is not smuggled into `DataDefault` as arbitrary code. Computed
defaults are deferred unless an existing Logic contract requires them; literal defaults are sufficient for the
foundational proof.

`ScalarKind` is sealed rather than an enum because integer width, decimal precision/scale and floating width carry
parameters. `Integer.bits == null` means arbitrary precision. `Decimal` null precision/scale means unconstrained
decimal, not binary floating point.

Scalar runtime values and mapping keys are read either through allocation-free primitive accessors or as a
detached `ScalarExecutionValue` (§6). Exact integers, decimals, temporal values and UUIDs use their canonical text
form inside the existing `text` variant and are interpreted under the owning `DataType`; there is no parallel
`DataScalar`. That rule is what makes the existing `ExecutionValue` grammar sufficient for v1 (§12).

### 4.3 Records, mappings and listings are different

A record has an ordered, declared field set. A mapping has arbitrary scalar keys with a uniform value type. A
listing has ordered numeric positions. Treating all three as `Map<String, Any?>` loses order, field identity,
duplicate field handling, presence and element constraints.

`Mapping.key` must be a non-null `Scalar` or non-null `Dynamic`; records and collections cannot be keys. Using a
`DataType` rather than a required `ScalarKind` lets an empty or genuinely dynamic map state honestly that its key
kind is not yet known.

`DataField` needs a stable identity separate from its display label, its `DataType`, and a presence rule:

- `Required` — absence is invalid;
- `Optional` — absence is valid and distinct from null; or
- `Defaulted` — absence resolves to a declared default and records `Defaulted` origin.

Nullability belongs to `DataType`; presence belongs to the containing field or binding. Absent, null, defaulted
and present remain four distinct observations. A field whose decoding failed is not a fifth runtime state in v1:
the reader's decode policy (project-data ST17 — fail the part, skip the record, or substitute null / default)
settles it before the value reaches a lane, and diagnostics carry source, unit, record and path. A transportable
`Invalid` state is added only with a quarantine lane that needs to carry it.

Field labels remain ordered and may require a projection policy when a tabular consumer demands unique labels.
That policy does not alter the record's semantic type.

### 4.4 Scalar kinds are semantic, not JSON-derived

The initial scalar vocabulary covers boolean, text, integral and decimal numbers, binary, UUID, and the time/date
kinds kzen actually needs. Null is a `DataState`, not a scalar kind. The type algebra does not inherit JSON's
limited number and time vocabulary merely because JSON is one wire format.

The test for whether a parameter belongs in `DataType` at all: a generic consumer must observe different
acceptance or access behaviour because of it. Integer width and signedness, decimal precision/scale and floating
width pass — a 64-bit integer does not fit a 32-bit requirement, and an allocation-free `readLong` is only exact
for an integer that fits. Provider-native details that do not change generic behaviour — temporal precision,
fixed-binary length, a column's affinity — are representation metadata beside the semantic projection, used for
lossless round-trip or migration and never consulted by generic access.

**Enum is deliberately not a scalar kind in v1**, a change from the project-data analysis's scalar list. A closed
symbol set does not change how a generic consumer *accesses* the value — it is text — and treating membership as
type compatibility would make `accepts` and `join` reason about symbol sets before any consumer needs it. In v1
an enum is `Scalar(Text)` plus a symbol-set constraint carried as schema metadata; membership is checked by value
validation (§4.7) where a declaring schema supplies it. The decision reopens with the first carried-schema format
(Avro) whose union or default semantics depend on enum identity.

The temporal meanings are deliberately small and explicit:

- `Date` is a calendar date without a time or zone;
- `Time` is a wall-clock time without a date or zone;
- `Instant` is an absolute point on the timeline, canonically serialized in UTC; and
- `Duration` is an elapsed amount rather than a calendar date/time.

`Instant` does not pretend to represent a local date-time. Converting "09:00 on 2026-09-01" to an instant requires
a timezone and its rules, which the value does not contain. The initial core therefore has no parameterized
`DateTime(TimeZoneSemantics)` case. A provider's timestamp-without-zone, original offset, region ID and precision
remain representation metadata, an opaque adapted value, or canonical text until a concrete processing use case
justifies a properly specified scalar type.

The initial core also has no generic `Logical(id, storage)` extension case. `Opaque` plus the adapter registry
already provides a safe extension path for custom values. A logical/refined scalar can be added when a real type
needs generic primitive transport while retaining semantic identity; the registry is not introduced speculatively.

### 4.5 Unions are tagged at runtime, and the producer names the active variant

A union is an ordered, non-empty set of variants with unique IDs. Variants may be any `DataType`. Null is
represented by the union's `nullable` modifier rather than a synthetic null variant.

"Tagged" is a statement about runtime values and snapshots, not about encodings: every present union node
carries an active `VariantId`, runtime access exposes that ID and the selected value (§6), snapshots encode it
(§12), and downstream consumers never rediscover it by inspecting fields or wrappers. Unions originate in
declared or carried schemas — an Avro union, a protobuf `oneof`, an XML `choice`, an authored `DataSchema`, a
Formula's declared result type; they are never synthesized by inference over heterogeneous samples, which widens
the position to `Dynamic` instead (project-data ST2).

The producer that lifts or decodes a value against a declared union determines the ID in one of two ways:

- **From an external tag.** Where a format stores its tag — a member field, an adjacent `{type, value}` wrapper,
  a message header, a separate database column — the codec's configuration maps that representation to a
  `VariantId` and then checks through `validateVariant` that the selected variant accepts the decoded value. No
  discriminator layout, including a shared member field, appears in `DataType`; a `FieldDiscriminator` case is
  deferred until a declared schema needs to *express* one rather than merely decode one.
- **By structural selection.** Where the encoding carries no tag, `selectVariant` (§4.7) compares the value's
  concrete type with every variant under structural assignability: exactly one accepting variant selects it; no
  accepting variant is a type error; more than one is ambiguous and fails unless the codec has an explicit,
  separately declared disambiguation policy. Variant order is canonical for display and digest purposes and is
  never an implicit "first match wins".

`List<String> | String` is the motivating case for the second rule:

```kotlin
DataType.Union(
    variants = listOf(
        DataVariant(VariantId("many"), DataType.Listing(DataType.Scalar(ScalarKind.Text))),
        DataVariant(VariantId("one"), DataType.Scalar(ScalarKind.Text))
    )
)
```

A JSON codec meeting an untagged array or string, and a Formula returning a Kotlin `List<String>` or `String`
against that expected type, both select unambiguously because exactly one variant accepts each; the resulting
node carries `many` or `one` from then on. A declared `Record(a) | Record(a, b)` decoded from an untagged
`{a: 1}` is the failing case — both variants may accept it under width-tolerant assignability — and the schema
author either supplies a tag or the codec declares which wins.

### 4.6 Opaque and Dynamic are two different kinds of "not structural"

`Opaque` means "this value is known only by its native type; no structural contract has been promised." It is not
a failure case. Native Kotlin code receives the original object without copying. A registered adapter may lift the
same object as a structurally richer node with the same native annotation, which is the normal way an opaque
baseline becomes a record.

This gives arbitrary objects a safe baseline. Reflecting every public getter would make framework behaviour
depend on methods that may be expensive, stateful, service-like or simply not data. Kotlin data classes and Java
records have a stronger data intent and are appropriate automatic structural baselines.

`Dynamic` means "a value will exist, but its usable structure is not known until runtime." It is an
observation-and-requirement type, not a runtime-value type:

- a source may report `DataShape(itemType = Dynamic)`;
- a port or binding may be declared `Dynamic` to accept runtime values of different concrete types; and
- every present runtime node carries the strongest concrete type its adapter or parser knows — a JSON object
  becomes a `Record` or `Mapping`, an array a `Listing`, a leaf a `Scalar`.

`ValueAccess.type(node)` therefore never returns `Dynamic` for a present node. Generic access needs no parallel
dynamic operation language: a consumer holding a `Dynamic`-typed lane reads the concrete type of each value and
dispatches on it, which is exactly what the project-data analysis's `value["field"]` accessor (ST21) does. The
statically generated `.field` accessors exist only where the lane type is a `Record`.

### 4.7 The type algebra is part of the contract

The model is incomplete without deterministic operations. Three different questions are kept apart, because type
compatibility cannot establish value conformance — a value may carry a compatible type while its root is null, a
required child is absent, or a node is stale:

```kotlin
enum class DataRequirement {
    Structural,
    Native
}

interface DataTypeAlgebra {
    fun isAssignable(expected: DataType, actual: DataType, requirement: DataRequirement): TypeAcceptance
    fun join(left: DataType, right: DataType): DataType
    fun selectVariant(union: DataType.Union, actual: DataType): VariantSelection
    fun validateVariant(union: DataType.Union, variant: VariantId, actual: DataType): TypeAcceptance
}

sealed interface VariantSelection {
    data class Selected(val variant: VariantId): VariantSelection
    data class NoMatch(val problem: DataProblem): VariantSelection
    data class Ambiguous(val candidates: List<VariantId>): VariantSelection
}

interface DataValueAlgebra {
    fun validate(value: DataValue, expected: DataType): ValueValidation
    fun project(value: DataValue, target: DataType): ProjectionResult
}

sealed interface TypeAcceptance {
    data object Accepted: TypeAcceptance
    data class Rejected(val problem: DataProblem): TypeAcceptance
}
```

`isAssignable` answers type compatibility only, under an explicit requirement: structural assignability ignores
native annotations; native assignability compares them through `TypeMetadata`; a union accepts an actual type
when at least one variant does. `selectVariant` answers the separate runtime question for an untagged value and
returns every ambiguous candidate rather than guessing (§4.5); `validateVariant` checks an ID that a codec
resolved from an external tag. `validate` walks a present value
against an expected type and reports absent required fields, null in non-null positions and variant mismatches.
`project` is the separately named, possibly allocating operation that produces a value of a different shape —
record-to-tabular flattening under an explicit naming policy, scalar-to-single-column, mapping-to-columns under a
declared key policy; its plan and failure model are specified with the first implementation, not hidden inside
`isAssignable`.

Before adoption the algebra must settle, with representative-pair tests: record width (does a wider actual
satisfy a narrower expected?), field identity, optional/defaulted fields against required ones, numeric promotion,
listing and mapping variance, the direction of `Dynamic` (a `Dynamic` requirement accepts everything; a `Dynamic`
actual satisfies only a `Dynamic` requirement), union normalization, and the join laws. `join` must be
associative, commutative and idempotent, or sample order changes an inferred contract. It creates or normalizes a
tagged union only from declared/carried variants; incompatible inferred alternatives widen to `Dynamic`. Union
normalization flattens nested unions, removes exact duplicate variants and preserves stable variant IDs.

Two named mappings complete the algebra. `KType → DataType` — `Int → Scalar(Integer(32))`,
`String → Scalar(Text)`, `Map<String, String> → Mapping(Text, Scalar(Text))`, `List<T> → Listing`, a data class
→ `Record` with the class as native annotation, anything else → `Opaque` — is what types a Formula's output lane
from `CalculatedColumnEval.inferredReturnKType`. `TypeMetadata ↔ DataType` is the same mapping over kzen's
existing cross-platform descriptor. Neither contains application-specific branches.

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
contract. A provisional `itemType` is an observation; it is not a promise that every emitted item has exactly
that type, which is why each emitted value carries its own concrete type (§4.6).

There is no `Tabular`, `Payload` or `Both` case (project-data ST4, settled 2026-08-27; data-source DM9):

- a CSV row is normally a `Record` backed by a flat record;
- a Kotlin data class is a `Record` with a native annotation, backed by the native instance;
- a scalar is `Scalar`, regardless of whether a table UI projects it to a synthetic `value` column;
- a map is `Mapping`, even if one particular runtime key set can be displayed as columns; and
- an opaque Kotlin object is `Opaque`, not "payload."

Tabular access is a `project` capability requested by a consumer. It may accept a record directly, project a
scalar to one column, or require a deliberate mapping-key policy. The value does not acquire a second identity
because a table rendered it.

`DataShape`, `DataType` and `DataShapeResult` are client-visible: `JobUpstreamSchema` and `DataSourceShapeStore`
already decode today's shape in Kotlin/JS. They therefore live in `commonMain` with a canonical `ExecutionValue`
lowering inside the existing `{type, value}` grammar, the same way the DS1 aggregate types own their own narrow
wire adapters. `DataCursor.shape` becomes non-null: an open cursor always has at least a `RuntimeOnly` observation.

## 6. Runtime values and multiple backings

The runtime value is a small read-only view with one source of truth for its type:

```kotlin
@JvmInline
value class DataNode(val token: Long)

class DataValue(
    val access: ValueAccess,
    val root: DataNode
) {
    val type: DataType
        get() = access.type(root)
}

data class DataProblem(
    val code: String,
    val message: String,
    val path: List<String> = emptyList()
)

enum class DataState {
    Absent,
    Null,
    Present
}
```

`DataValue.type` delegates to the backing rather than caching a second copy joined by an asserted invariant. The
declared or expected type lives on the binding, port or shape that receives the value, and `validate` relates the
two. A root value is `Present` or `Null`; `Absent` belongs to a containing field or binding.

`DataNode.token` is meaningful only to the accompanying `ValueAccess`; nodes from different access instances are
never interchangeable. The constructor is public because backings implemented outside kzen-lib — a consumer
plugin's `FlatFileRecord`, a provider's row cursor — must mint the tokens their own `field`, `entry` and
`element` return. The access implementation owns the token namespace and any backing tables, which fixes the
public representation at one inline `Long` while leaving each backing free to encode offsets, row/field slots or
cached native-property plans.

The complete semantic access surface is:

```kotlin
interface ValueAccess {
    val retention: DataRetention

    fun type(node: DataNode): DataType
    fun state(node: DataNode): DataState
    fun isAlive(node: DataNode): Boolean

    fun activeVariant(node: DataNode): VariantId
    fun selected(node: DataNode): DataNode

    fun field(node: DataNode, field: FieldId): DataNode
    fun entry(node: DataNode, key: ScalarExecutionValue): DataNode
    fun element(node: DataNode, index: Int): DataNode
    fun size(node: DataNode): Int
    fun keyAt(node: DataNode, index: Int): ScalarExecutionValue

    fun scalar(node: DataNode): ScalarExecutionValue

    fun readBoolean(node: DataNode): Boolean
    fun readLong(node: DataNode): Long
    fun readDouble(node: DataNode): Double
    fun readText(node: DataNode): String
    fun readBinary(node: DataNode): ByteArray

    fun native(node: DataNode): Any
}

enum class DataRetention {
    Detached,
    Owned
}
```

`scalar` is the complete canonical path for every `ScalarKind`, including arbitrary-precision numbers and
temporal values. The specialized reads are allocation-free fast paths and succeed only when the scalar kind can
be represented exactly by the requested Kotlin primitive. `readBinary` returns a defensive copy; a zero-copy binary
consumer needs an explicit borrowed-buffer capability with the same lifetime rules as the backing. `native` is the
explicit native interop edge: it returns the object named by the node's native annotation and fails when the node
has none rather than synthesizing one.

`activeVariant` and `selected` are valid only for a present union node; `selected` returns the node of the active
variant's value, whose own type is that variant's type, so a union whose active branch is a record is traversed
with `field` on the selected node. `field`, `entry`, `element`, `size` and `keyAt` are valid only for compatible
present structural nodes. A record enumerates fields through its ordered `DataType.Record` definition; a mapping
uses `size` plus `keyAt`. Unsupported operations fail as contract violations. The eventual source API may split
these operations into capability subinterfaces, but it must preserve these semantics and must not require
generic code to inspect concrete backing classes.

An accessor fails immediately when an operation contradicts `DataType`: reading text from a record or asking a
required missing field to masquerade as null is a contract error, not a fallback.

`DataValue` intentionally has reference identity rather than generated structural equality. Content comparison
and digesting are explicit operations with depth, type and lifetime policies; comparing two access/root handles
would not establish semantic equality.

### 6.1 Required backing implementations

The shared contract should allow at least:

| Backing | Purpose | Materialization rule | v1 |
|---|---|---|---|
| Literal | Scalars and lightweight list/map/record literals | Owns its small immutable value tree | yes |
| Flat record | CSV/TSV and Report/Job column paths | Retains indexed storage, shared headers and primitive caches | yes |
| Native object | Formula results and ordinary Kotlin objects | Retains the original reference; adapter reads supported members through a cached plan | yes |
| Typed row | Database/query/store results | Reads driver/store cells through a row-scoped view | fake in v1; real with the first JDBC source |
| Structural tape | Streaming JSON/XML-like structures | Nodes index the tape; subtrees are not copied | with the first tree reader |
| Graph object | Notation-defined and graph-created objects | Retains graph instance/definition context; selected attributes are lazy fields | native + reference lowering in v1; structural exposure later (§8) |
| Composed | Transform output overlaying an input that cannot be appended in place | Resolves unchanged fields through the input and new fields through an indexed overlay | when a non-appendable backing needs it (§11.4) |

The list is open. Adding a backing should not add a new `DataType` case or require changes to every consumer.

The flat backing is **`FlatFileRecord` itself implementing `ValueAccess`**. It is a Java class in the JVM-only
`kzen-auto-plugin` artifact, which today depends on nothing but a hashing library; that artifact takes a
dependency on the JVM variant of `kzen-lib-common` so the record implements the contract directly over its
existing `char[]` / `int[]` spans and `cachedDoubleOrNan` / `cachedHash` caches, with no forwarding object on the
hottest read path. Third-party `ReportDefiner` plugins then emit `DataValue` — or their own output type lifted by
a registered adapter. The plugin is in-development code with no external consumers beyond the sample plugin, so
its dependency policy changes with the model rather than constraining it (§14.3).

### 6.2 Read-only access and lifetime

`DataValue` is a read view even when its backing object is mutable. No `setField` belongs on `ValueAccess`.
Graph changes go through notation commands/reducers; durable-row changes go through a store transaction or
repository command; Kotlin object mutation remains explicit Kotlin code.

`native` is the deliberate escape hatch from that guarantee. A caller requesting the original mutable Kotlin
object may mutate it through its own API; generic structural processors never call `native` merely to read
fields. A holder of the native object can therefore change it between two structural reads — a collection may
change size, a field may stop matching the annotated type. The generic API prevents write-through; it does not
promise an immutable value, which is why principle 5 says read-only.

Retention is declared per root value, not per accessor class, because one composed value may mix backings and an
engine needs one deterministic transfer rule. v1 recognizes two states:

- `Detached` — self-contained; stays live independently of any cursor or execution frame; and
- `Owned` — valid for one explicit scope named by its producer, transferred at most once, and never retained
  past that scope.

The v1 lifetime contract for cursors is the simplest one that the existing Job transport can honour: **each value
a `DataCursor` emits is independently owned until the cursor closes**, so Job batching, queueing and live-edit
migration (which carries physical batches and adopts a detached cursor exactly once) hold values that remain
readable after the cursor has advanced. That is already how `FileDataCursor` behaves — it prototypes every row it
emits. A reusable-current-row optimization, and the `Borrowed | Retainable` states with `retain()` leases that a
JDBC `ResultSet` would force, are introduced by the first source that measurably cannot meet the owned-item
contract, together with a separate synchronous traversal API for the consumer that can guarantee it.

`isAlive` permits a deterministic stale-view failure for `Owned` values after their scope closes; every accessor
checks the same state. No API implies that every `DataValue` is safe to cache indefinitely. Two consumers must be
named in the contract in addition to channel batching, because both already retain values across engine events:

- **Live-edit migration.** Job carries in-flight batches and Script carries `ScriptReplayState` outcomes across a
  migration; a value in either must be `Detached`, or `Owned` by a scope that the migration transfers.
- **Script replay.** A step result recorded for replay is retained until the run completes; a cursor-scoped value
  cannot be a step result without an explicit detach at the step boundary.

### 6.3 Performance is part of correctness

The abstraction is acceptable only if it preserves the existing fast paths:

- no eager conversion of each row to maps or nested objects;
- no per-field `DataValue` allocation during expression evaluation;
- allocation-free primitive reads after cursor setup, with caller-owned scratch as `FlatFileRecord` does today;
- no reflection lookup per field read — adapters cache or generate access plans;
- stable shared `DataType` and field descriptors across rows;
- generated accessor return types that stay concrete and monomorphic (a nullable or generic `DataNode` boxes);
- bounded lookup cost under many sequential calculated-column transforms (§11.4); and
- explicit accounting when a consumer requests a materialized map, object or wire snapshot.

These are benchmarkable acceptance conditions, not optional optimizations. The existing planned Job benchmark
harness is sufficient; a new benchmark framework is not required. The first session that claims an allocation
property builds a narrow pin for it and names which invariant the pin covers — parser-slot reuse, allocation-free
scalar reads, or end-to-end per-record execution.

## 7. Native and literal ergonomics

The normal authoring experience should be:

```kotlin
data class Reading(val sensor: String, val value: Double)

// Formula result: ordinary Kotlin, no DataValue construction.
Reading(sensorId, measuredValue)
```

At the Formula/step/port boundary, `DataAdapterRegistry.lift(result, expected)` selects an adapter and creates the
root view. When another native Kotlin expression consumes the value, the native backing returns the original
`Reading` instance. When a generic Sort, Filter, table or writer consumes it, the data-class adapter exposes the
same instance as a record with `sensor` and `value` fields.

`expected` comes from static knowledge first (principle 13). At a Formula boundary it is
`KType → DataType` over `CalculatedColumnEval.inferredReturnKType`, so an empty `List<String>` result lifts as
`Listing(Scalar(Text))` because the compiler said so, not as a listing of unknown element type because no element
was there to inspect. At a port or binding boundary it is the declared type. Runtime inspection of the value is
the fallback for a genuinely untyped edge (`Any`), and validates the static type otherwise.

### 7.1 Lightweight record literals are not arbitrary maps

A lightweight object literal is a useful authoring form, but it still needs a semantic distinction from a map.
The rule is:

- a notation/JSON object or explicit Kotlin `recordOf("name" to value, ...)` literal lifts as an ordered
  `Record`, with field types inferred or checked against the expected `Record` type;
- a `Map<K, V>` lifts as `Mapping`, because its key set is runtime data rather than a declaration; and
- a string-keyed map may satisfy an expected `Record` only through an explicit checked projection that reports
  missing, extra and duplicate fields.

`recordOf` is a literal constructor, not a `DataValue` wrapper: callers describe the object they want, while the
framework still performs lifting. A future Formula object-literal syntax may lower to the same value without
changing the model. Treating every `Map<String, *>` as a record would look convenient initially but would make
schema depend on each instance's keys and recreate the current runtime-header ambiguity.

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
and defensively copies the field list. Its adapter derives `FieldId(name, 0)` from those names and lifts each
value recursively. `Any?` is appropriate here as the native authoring input; the resulting boundary value is
typed and stateful. A literal needing duplicate display names must use a schema-aware record builder rather than
object-literal syntax.

### 7.2 Automatic baseline

The baseline should be predictable:

- null and primitive values lift as scalar/null literals;
- `List` and arrays lift as listings; `Map` lifts as a mapping, not a record merely because its current keys are
  strings;
- Kotlin data classes and Java records lift as structural records with the class as native annotation;
- graph-created objects use the graph adapter described in §8;
- a type with a registered adapter uses that adapter; and
- any other object lifts as `Opaque` and retains native access only.

`Iterable`, `Sequence`, `Iterator` and `Set` are **not** lifted automatically. An arbitrary iterable may be lazy,
infinite, one-shot, blocking or unable to answer `size` without consuming itself, and a set promises no stable
positional order; silently treating either as a `Listing` changes its meaning. Stream-valued results keep their
existing explicit streaming boundary (the `isStreamType` dispatch that `FormulaSourceWorker` and ForEach use), and
a set needs a registered adapter that states its ordering.

The expected type participates in inference without changing the adapter owner:

- null with a nullable expected type uses that type and `DataState.Null`; null without one uses nullable
  `Dynamic`; null against a non-null type fails;
- an empty collection uses the expected element/key/value type when one exists, and otherwise
  `Listing(Dynamic)` / `Mapping(Dynamic, Dynamic)` with the default nullable `Dynamic` — an honestly unknown
  element type, which is what `Dynamic` means;
- a non-empty homogeneous collection uses the joined observed element/value type; and
- heterogeneous elements use the deterministic `join`, widening to `Dynamic` when the alternatives are not
  declared variants.

Common code owns the model and adapter protocol. JVM modules own reflection or generated access. Execution is
entirely server-side, so **no Kotlin/JS `ValueAccess` implementation is required or planned**: the `DataValue`
contract may be declared in `commonMain` for symmetry, while every backing and adapter is JVM. The client consumes
`DataType`, `DataShape`, snapshots and binding *definitions* only.

### 7.3 Extensibility without caller ceremony

An application or plugin registers one adapter for its domain type. Every Script, Flow, Job and data-source
boundary then uses it automatically. This is different from requiring every Formula author to call
`DataValue.of(...)` or annotate every handoff.

Adapter selection must be deterministic and its conflicts detectable without a runtime value:

```kotlin
@JvmInline
value class DataAdapterId(val value: String)

interface DataAdapter {
    val id: DataAdapterId
    fun lift(value: Any, expected: DataType?): DataValue
}

interface DataAdapterRegistry {
    fun lift(value: Any?, expected: DataType? = null): DataValue
}
```

A registry is built from two inspectable lists: **exact native-class registrations** (`ClassName → DataAdapter`;
a duplicate class is a construction-time error naming both adapters) and an **explicitly ordered list of
capability fallbacks**, each a predicate over the runtime class plus an adapter, consulted in declaration order
after the built-in data-class and Java-record baselines. There is no "assignability distance": multiple-interface
inheritance has no single correct distance, JVM generics are erased, and a `match(value)` callback cannot be
audited for collisions at registry construction. `Any` appears here deliberately as the native-to-data interop
edge; null is handled by the registry before adapter selection. `expected` validates or selects a projection
offered by the winning adapter; it never changes which adapter owns the native value.

Built-in literal, collection, data-class, Java-record and graph integrations participate through the same
registry contract, although a platform implementation may inline their hot paths. `DataAdapterId` is a non-empty
stable identifier used in diagnostics; it is not a concrete-class dispatch key exposed to consumers.

### 7.4 Cycles and identity

Native and graph objects may be cyclic. Lifting therefore does not recursively materialize them. A view retains
identity and resolves fields on demand. Snapshot conversion detects revisited identities and fails under the v1
policy (§12); a reference marker is a deferred wire extension.

## 8. Graph-managed object interaction

"Graph-managed" here means an object instantiated through kzen's Notation → Definition → Instance pipeline. It
does not mean a database graph, and it does not make every object in `GraphInstance` globally available as data.

The interaction occurs only when a graph-created object is explicitly passed or returned across a data boundary.
At that point the adapter has both:

- `ObjectInstance.reference`, the actual Kotlin object; and
- its `ObjectDefinition` plus `ObjectInstance.constructorAttributes`, which describe how the graph created it.

The resulting value has the created class as its native annotation and may offer two views:

1. **Native view.** Kotlin code requesting the declared class receives the original reference, with no copy.
   This, plus lowering the object to its stable reference in snapshots, is the whole of v1.
2. **Structural view.** Generic data processing sees only attributes admitted by the graph-data exposure policy.
   Deferred until a concrete processor needs to traverse a graph object generically.

### 8.1 Structural exposure policy

`constructorAttributes` alone is not a safe public-record definition. It may contain services, creator inputs,
self-location infrastructure and resolved object references. The graph adapter must use definition metadata and
an explicit exposure policy rather than reflect every constructor argument indiscriminately.

The baseline policy is:

- expose authored/defaulted value attributes as fields;
- preserve nested list and map definitions structurally;
- expose an authored object reference as a lazy reference field, without recursively expanding the target by
  default;
- exclude `ServiceAttributeDefinition` values;
- exclude creator dependencies and creator/runtime infrastructure; and
- exclude self-location or equivalent framework-injected parameters unless metadata explicitly marks them as
  data.

The current definition model distinguishes service and reference attributes, but does not fully label "authored
data" versus every creator-supplied value. Structural exposure therefore requires declarative exposure metadata or
an equivalent graph adapter policy before generic traversal is implemented. Guessing from names or reflecting all
public properties is not acceptable.

### 8.2 References stay lazy and bounded

A reference field may expose its stable reference and, while the owning graph snapshot is live, permit explicit
navigation to the referenced object's view. It is not automatically expanded into the parent record. This avoids
cycles, enormous accidental snapshots and hidden graph walks. Navigation remains outside the generic model until
a concrete processor needs it; v1 snapshots emit only the stable reference or fail.

### 8.3 No write-through

Changing a field in a structural graph view would be ambiguous: should it mutate the live Kotlin instance, write
notation, rerun definition and creation, or affect only a temporary copy? The read model therefore has no such
operation. A graph mutation remains a notation command/reducer followed by normal graph refresh.

### 8.4 Conversion is intentionally asymmetric

A graph-managed object can be read as native or structural data because its definition, creator, dependencies,
identity and lifecycle already exist. An arbitrary record-shaped `DataValue` cannot automatically become a
graph-managed object. Doing so would have to invent an object location and notation, a definer and creator,
reference/dependency resolution, service injection, persistence and refresh behaviour, and ownership of the
resulting instance. That operation, when needed, is an explicit graph creation/import command with a target
archetype and mapping. It is not the inverse of reading a value.

## 9. Durable rows and managed project data

A durable project store fits the same read model. A typed row exposes a `Record` through a row-backed
`ValueAccess`; a query exposes a cursor of those values; storage-native schema details accompany the semantic
`DataType` as representation metadata when needed for migration or lossless writing.

The same read-only rule applies. Reading a field does not silently issue an update. Mutations use an explicit
store operation with transaction, validation and authorization semantics. A successful write may return a new
row view or stable row reference.

Graph notation and project data remain different persistence tiers: notation defines configured objects,
inheritance and executable structure; the durable store holds potentially large, mutable application records; and
a stable reference may connect the tiers without embedding a live row or graph instance in the other. The unified
model lets both tiers feed the same Logic without pretending that they share write lifecycle or storage mechanics.
The project-data analysis owns the store itself (its PS decisions); the generic database source there is the
consumer that turns the fake typed-row backing of §6.1 into a real one, and its measured cursor behaviour is what
decides whether §6.2's deferred lease states are needed.

## 10. Enumerable, typed Logic bindings

The replacement for `TupleDefinition` plus `TupleValue` keeps declaration and instance as two concepts that
cannot drift, without pretending a declaration is an incomplete runtime binding:

```kotlin
@JvmInline
value class BindingName(val value: String)

data class BindingDefinition(
    val name: BindingName,
    val type: DataType,
    val presence: DataPresence = DataPresence.Required,
    val sensitive: Boolean = false
)

class BindingSchema private constructor(
    val definitions: List<BindingDefinition>
) {
    operator fun get(name: BindingName): BindingDefinition
    fun find(name: BindingName): BindingDefinition?
}

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

class DataBindings private constructor(
    val schema: BindingSchema,
    private val states: List<BindingState>
) {
    operator fun get(name: BindingName): BindingState
    fun requireValue(name: BindingName): DataValue
    fun entries(): List<Pair<BindingDefinition, BindingState>>
}
```

`BindingName` is a non-empty canonical string unique within the schema. `DataPresence` and `DataDefault` are the
same definitions used by record fields: omission, nullability and defaulting therefore have one meaning
throughout the model. `LogicSignature` becomes a pair of `BindingSchema`s and is a pure declaration — it holds no
`Unbound` runtime states and is not re-created per execution.

`DataBindings` has validated factories rather than a public constructor. A factory takes a schema and supplied
name/value pairs, rejects duplicate supplied names, rejects unknown supplied names, checks each value against its
declaration under the structural requirement (native where the declaration carries an annotation), applies
literal defaults, and aligns states by schema index. A builder form exists for incrementally produced outputs,
because `JobControl.yieldResult` publishes result components during a run rather than all at once; it validates
each component as it is set and the completed set at settle. The exact factory names may change before
implementation; those construction rules should not.

### 10.1 Behaviour

- Enumeration follows schema order and is safe for UI/diagnostics without materializing values.
- Lookup returns a binding state, not `Any?`.
- A bound null is a `Bound` value whose root state is `Null`; it is not `Unbound`. A `Bound` value whose root is
  `Absent` is a construction error.
- Defaults are applied once by binding construction and record `Defaulted` origin.
- Unknown supplied names and duplicates fail at the boundary that creates the set.
- Type acceptance is checked when a value is bound, not deferred until a consumer casts it.
- Sensitive bindings expose names, types, states and origins but redact previews. Sensitivity is whole-binding
  only; nested field sensitivity needs an explicit schema policy and path-aware tests before it is promised.

Omitted optional inputs remain present as `Unbound`, because enumeration describes the whole signature. An
unbound required input is representable while editing or assembling a request, but validation for execution
fails. A defaulted input is never unbound after successful execution validation.

This tightens today's engine behaviour, and the change must be migrated deliberately rather than discovered:
`JobControl.host(instructions, arguments)` currently permits omitted inputs (DS7 as-built), leaving the callee to
see null through `parameter(name)`. Under this model an omission is legal only where the callee's schema declares
the input `Optional` or `Defaulted`. Existing Script/Flow named calls that rely on null-for-omitted either declare
that presence on the callee or bind the value explicitly; `RunWorker.arguments`, already stricter, is unchanged.

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

A convenience lookup may return a `BindingState` or require a typed `DataValue`; it must not restore
`argument(name): Any?` as the primary contract.

At design time, routing parameters such as action/source identifiers are removed before constructing argument
bindings. Repeated request values bind as a listing, not through `singleOrNull()`. Missing, one-valued and
multi-valued request parameters therefore remain distinguishable.

At runtime, `LogicDataSource` binds only declared argument names, uses the callee's schema to apply defaults, and
fails on a required unbound input. Optional source-side renaming is an explicit name mapping. It does not inspect
or cast arbitrary `Any?` values.

## 11. End-to-end use by Logic flavours

### 11.1 Core Logic

`Logic.signature()` declares input and output `BindingSchema`s. `Execution.inputs` and `Execution.host` use bound
`DataBindings`. A Logic may still call arbitrary Kotlin or resource APIs internally; the unified model governs
values entering or leaving the computation, not every local variable.

Opaque execution resources — browser handles, database connections, migration state — remain `Any` or typed
Context bindings because they are capabilities, not dataflow values. Removing `Any?` from dataflow does not imply
turning every resource into `DataValue`.

### 11.2 Script

Generated step code receives the most ergonomic supported view:

- a value whose node carries a native annotation of the requested type is passed as the original object;
- a structural backing is read through generated accessors derived from `DataType`; and
- a step result is automatically lifted when recorded or handed to another step, with `expected` from the step's
  declared result type or the compiler-inferred `KType`.

A step result recorded for replay (`ScriptReplayState`) must be `Detached` or owned by a scope the run controls
(§6.2). Native-only local variables inside a step are not wrapped merely to satisfy architectural symmetry; the
cutover applies where generic data actually crosses a step boundary.

### 11.3 Flow

Flow ports declare `DataType` and carry `DataValue` (or engine batches of it). Port connection validation uses
`isAssignable`; runtime delivery does not erase the element to an unrelated `Any?`. A custom vertex can request
native projection where available or structural access otherwise. `FlowVertex.inspectMessage` stops being a
per-vertex hand-written renderer for data-carrying messages: the runner snapshots a `DataValue` message through
the bounded policy of §12, and the vertex override remains for non-data state.

### 11.4 Job

Job channels carry one `DataValue` per domain element. Batching remains a channel transport concern and keeps its
existing ownership/cadence behaviour; the ownership-transfer rule remains useful.

`JobMessage(payload, flat)` and `WorkerLane(payloadType, flatColumns)` cease to be the target design. A Worker
receives one value and one semantic type. Column-oriented Workers request a record/tabular `project`:

- records expose their ordered fields;
- scalars may project to an explicit synthetic `value` field;
- mappings require a declared or observed key projection; and
- opaque values require a structural adapter or fail with a useful capability error.

Three existing behaviours are preserved by construction rather than by a second carrier:

- **Undeclared delimited fields are `Scalar(Text)` read through `ColumnValue`** (project-data ST1, settled). Its
  coercion semantics — `"13.0" == 13` — are product behaviour, and its interned constants are a real allocation
  optimization. A declared non-text field bypasses it with a typed primitive read. No existing expression changes
  meaning.
- **`<missing>` becomes a projection policy, not data.** Superset normalization (`schemaMode: superset`) today
  materializes the `DataShape.missingCellValue` sentinel into absent cells. Under this model a superset field is
  `Optional`, an absent cell is `DataState.Absent`, and the tabular `project` used by column Workers renders
  `<missing>` as its display of absence — so `Summary` and the writers keep their output while a typed consumer
  sees absence honestly.
- **Owned-append stays the hot path for calculated columns.** A Worker that received a message owns it and may
  append fields to an appendable backing (the flat record) before publishing one new `DataValue` whose `Record`
  type is wider — exactly today's `FormulaWorker` mechanics, legal because the mutation is by the owner before
  publication, not through `ValueAccess`. A `Composed` overlay is used only where the input backing cannot be
  appended (a native object, a row), carries an indexed field plan so lookup does not degrade with each prior
  transform, and collapses to an owned copy past a declared threshold. The benchmark gate includes many
  sequential calculated columns, not one overlay.

A result sink or nested Logic host passes the same semantic value across the boundary instead of choosing
between payload and materialized-map rules. `attributes: columns` becomes a record composition that prepends the
unit's attribute fields; a `DataUnit` on a unit lane lifts through the data-class baseline, so `attributes["date"]`
in a `RunWorker.arguments` expression keeps its native meaning while a column consumer sees the same unit as a
record.

### 11.5 Data sources

The source model remains responsible for resolving manifests, selecting parts and opening cursors. Its generic
data boundary becomes:

```kotlin
interface DataCursor: Iterator<DataValue>, AutoCloseable {
    val shape: DataShape
}
```

`DataUnit`, `DataPart` and `DataRef` remain source-selection values; they lift through the data-class baseline
when passed through Logic. An opener chooses the most appropriate backing for emitted items. A CSV opener uses
the flat-record backing; a database opener uses row access; an authored Logic source receives and returns typed
bindings. Every emitted value is independently owned until the cursor closes (§6.2).

No source-specific payload category is introduced.

## 12. Wire, trace and diagnostic boundaries

### 12.1 v1 keeps `ExecutionValue` behind a typed envelope

`ExecutionValue` stays the one detached tree in v1. What changes is that a live value reaches it only through an
explicit, policy-bound conversion that returns a typed envelope, because an `ExecutionValue` map cannot by itself
distinguish a `Record` from a `Mapping(Text, ...)` or say which union variant is active:

```kotlin
data class DataSnapshot(
    val type: DataType,
    val value: ExecutionValue
)

sealed interface SnapshotResult {
    data class Complete(val snapshot: DataSnapshot): SnapshotResult
    data class Rejected(val problems: List<DataProblem>): SnapshotResult
}

data class SnapshotPolicy(
    val maximumDepth: Int,
    val maximumElements: Int,
    val maximumTextLength: Int,
    val maximumBinaryBytes: Int,
    val maximumDurationMillis: Long,
    val sensitive: SensitiveSnapshotPolicy
)

enum class SensitiveSnapshotPolicy {
    Redact,
    Reject
}
```

All numeric limits are strictly positive and `maximumElements` is cumulative across the snapshot. The v1 policy
is strict: exceeding any bound rejects; a cycle or revisited identity rejects; a graph reference lowers to its
stable reference or rejects; an opaque node with no registered lowering rejects rather than falling back to
`toString()`; `Redact` emits a canonical redaction marker at whole-binding scope and `Reject` refuses the binding.
No partial tree masquerades as complete data.

Within the existing grammar the lowering is mechanical: records and text-keyed mappings lower to `map`; other
mappings lower to a `list` of `{key, value}` maps; a union lowers to `{variant, value}`; exact integers, decimals,
temporal values and UUIDs lower to canonical `text` interpreted under the envelope's `type`; binary lowers to
`binary` or, where the calling protocol supplies a blob endpoint, `binary-handle`. `DataDefault` and other
permanently self-contained locations reject `binary-handle` recursively.

A snapshot taken for the trace must never fail the run: `Execution.emit`, `FlowVertex.inspectState` and
`inspectMessage` already run under trace throttling with the rule that a trace failure is swallowed, so a
`Rejected` result there becomes a structured trace diagnostic, not an exception. Routine diagnostics should not
materialize data at all — a binding summary displays ordered names, declared types, bound/unbound state and
origin; value previews are separate, bounded requests.

Digest and equality rules distinguish semantic contracts from live identity: `DataType` and `BindingSchema` have
canonical structural digests; a `DataSnapshot` has a content digest; a live native, graph or row view does not
claim content equality unless its adapter explicitly supplies it; and source manifests retain their existing
point-in-time digest semantics.

### 12.2 The deferred wire grammar

A `WireValue` rename and a versioned grammar are deferred until a demonstrated boundary cannot lower through the
tree above. When one arrives, the grammar is designed as one explicit protocol rather than accreted: exact
`integer` / `decimal` leaves, an arbitrary-scalar-keyed mapping container, a record container keyed by field
identity, an active-variant tag, a stable identity reference for repeated or cyclic objects, a redaction marker, a
truncation marker with its diagnostic, and a resolver-scoped blob reference generalizing today's `run` / `hash`
handle. `WireValue` is the intended name because the value is canonical boundary data even when temporarily held
in memory; `StructuralValue` would collide with the live model, `ValueTree` names the representation but not the
role, and `SnapshotValue` is too narrow for authored defaults and requests. The rename lands with that protocol,
never as a standalone cosmetic change across the current call sites. Real immutability is part of that design:
today's `BinaryExecutionValue` carries a mutable cache and exposes its `ByteArray`, and public read-only `List` /
`Map` interfaces may still wrap mutable collections.

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

### 13.4 Use the detached tree everywhere

Renaming today's `ExecutionValue` does not make it the live runtime model. Using it everywhere would still impose
eager copying, lose native identity, narrow the type system and damage streaming/row performance. It would
confuse a boundary format with a runtime value.

### 13.5 Add `DataShape.Both`

`Both` says a carrier currently has two views, not what the value means. Every new backing would invite another
case or combination. A record plus capability-driven projections expresses the same useful access without
encoding transport history into the type language.

### 13.6 A top-level `DataDescriptor(structural, native)` pair

This correctly separates the two facets but records the native type only at the root. Generated code reading a
nested data-class field needs that field's native type too, and a listing of data classes needs its element's.
A per-node annotation is the same idea made recursive; `Opaque` is then simply a node whose only information is
its annotation.

### 13.7 Materialize every value into one universal tree

This simplifies one accessor while imposing allocations and retention on every producer. It discards the main
benefit of flat rows, streaming tapes, native objects and driver-backed rows. One access contract with multiple
backings provides semantic consistency without physical uniformity.

### 13.8 Reflect every public property

Public APIs contain behaviour as well as data. Getters may perform I/O, mutate state, reveal services or expose an
unstable implementation detail. Automatic structure is restricted to strong data signals — data classes, Java
records, graph exposure metadata — or an adapter explicitly registered by the owner.

### 13.9 Require wrappers in Formula and plugin code

This would make the framework mechanically pure at the expense of every user-facing handoff. Since the engine
already owns step, port, channel and Logic boundaries, it can lift values once at those boundaries. Adapter
registration is acceptable infrastructure ceremony; repeated value wrapping is not.

### 13.10 Make views write through

There is no universal meaning for a field assignment across native objects, notation-defined graph objects,
cursor rows and durable records. A read-only common contract with explicit system-owned mutation preserves
transactions, CQRS and lifecycle semantics.

### 13.11 Automatically create graph objects from records

A record does not contain the graph identity, creator, services, dependency rules or notation lifecycle needed
to create a managed object. An explicit import/create operation can supply those choices. Hiding them in ordinary
value conversion would be unpredictable and unsafe.

### 13.12 Keep separate Script, Flow and Job data models

Their execution mechanics differ, but separate value models force conversion at every composition boundary and
allow type rules to drift. A foundational model costs one deliberate cross-repository sequence of cutovers and
removes that permanent duplication.

### 13.13 Parameterize one `DateTime` by timezone semantics

Local, offset, region-zoned and absolute timestamps are different meanings rather than configuration modes of one
scalar. A `None | Offset | Region` parameter still omits the actual zone/offset and conflates semantic comparison
with representation preservation. The initial core uses `Instant` for absolute timestamps and does not claim that
it represents local date-time.

### 13.14 Add an open-ended `Logical(id, storage)` scalar, or an `Enum` kind now

A storage kind would make a custom scalar transportable but would not define its validation, canonicalization,
compatibility, provider lookup or explicit projection rules. An enum kind would make `accepts` and `join` reason
about symbol sets before any consumer observes different access behaviour. `Opaque` plus adapters, and
`Scalar(Text)` plus a symbol-set constraint, are sufficient for the current requirements.

### 13.15 Inferred unions, or ambiguity-tolerant structural selection

Synthesizing a union from heterogeneous samples would make every consumer reason about variants that no schema
declared, and its identity would shift with the sample; inferred heterogeneity widens to `Dynamic` instead. A
separate temptation is to let structural selection tolerate overlap by taking the first accepting variant — that
is deterministic only until the variant list is reordered, and it hides a schema ambiguity the author should
resolve with a tag. Selection by *unique* accepting variant is kept (§4.5): it is the only way an untagged
`List<String> | String` can name its variant, and the resulting node carries the ID from then on, so snapshots
round-trip.

### 13.16 Put discriminator layouts in `DataType`

An external key, adjacent wrapper, message header or discriminator column describes where one format stores
selection information; it is not part of the selected value's semantic type. Encoding those layouts in
`DataType.Union` would couple every consumer to representation policy. A codec resolves its own layout to a
`VariantId` and validates that choice against the semantic union.

### 13.17 Keep the plugin artifact dependency-free and adapt `FlatFileRecord` from outside

An adapter in `kzen-auto-jvm` over the record's unsafe span accessors would preserve the plugin's current
no-dependency policy and defer the SPI question. It was considered and declined: the policy protects nothing —
there is no external plugin ecosystem or released contract, only in-development code and a sample plugin that
recompiles — and it would put a forwarding object on the hottest read path and a mirrored or adapted contract
between third-party readers and the value model. The dependency is taken instead (§6.1, §14.3).

### 13.18 Per-node value origins and a universal `Invalid` state

`Literal | Backing | Derived` is unstable through snapshots and composed projections, and "backing" describes
almost every value; a transportable `Invalid` would oblige every consumer to handle decode failure in-band before
any lane needed to carry it. Binding and default origins have identified consumers and stay; node origins and
`Invalid` return with a trace, UI or quarantine consumer that needs them.

## 14. Consequences if accepted

### 14.1 Ownership

The natural owner of the vocabulary — `DataType`, `DataShape`, `DataValue` / `ValueAccess`, `BindingSchema` /
`DataBindings`, the snapshot envelope — is `kzen-lib-common`: `Logic`, `Execution`, tuples and graph definitions
already live there, every Logic flavour depends on it, and the bindings that replace `TupleValue` cannot live
anywhere else. JVM reflection, native and row backings live in `kzen-lib-common`'s `jvmMain` or in consumer
modules while implementing the common contract; `FlatFileRecord` implements it in `kzen-auto-plugin` (§6.1).

One practical cost is stated rather than discovered: the composite build substitutes kzen-lib for kzen-auto's
`commonMain` only, so JVM backings in kzen-lib reach kzen-auto through `publishToMavenLocal`. Placing the
fast-iterating type and value contracts in `commonMain` keeps the dev loop inside the composite; only the JVM
backing implementations pay the publish step, and those change less often once the contract settles.

### 14.2 Platform scope

`DataType`, `DataShape`, `DataSnapshot` and binding definitions are `commonMain` because the client consumes
them. `ValueAccess` may be declared in `commonMain`; no Kotlin/JS backing or adapter exists or is planned, because
execution is server-side. The open question of common-platform adapters in the original proposal is thereby
closed for v1.

### 14.3 The plugin SPI depends on the value contract

`kzen-auto-plugin` is a JVM-only artifact that today depends on nothing but a hashing library. That policy is
dropped rather than worked around: the artifact depends on the JVM variant of `kzen-lib-common`, `FlatFileRecord`
implements `ValueAccess` directly (§6.1), and readers written against the SPI emit `DataValue`. Of the four
options the project-data analysis listed (project-data ST8 — plugin depends on kzen-lib, vocabulary in kzen-lib,
a new neutral artifact, or a mirrored plugin-local contract), the first two are taken together; the others exist
only to protect a dependency-free SPI, and there is no external plugin ecosystem or released contract to protect
— the code is in development and `kzen-sample-plugin` recompiles. Publication order follows: kzen-lib before
`kzen-auto-plugin` before the rest of kzen-auto, at the existing coordinated version.

### 14.4 Document ownership

Accepting this proposal narrows three documents to their own concerns, with pointers here for the ceded parts:

- the [data-source model](2026-08-20_data-source-model.md) keeps refs, parts, units, manifests, the
  resolve/open/inspect protocol and the schema cache; the cursor item contract, `DataContext` arguments and the
  shape argument are owned here;
- the [Job adapter](2026-08-20_job-data-source.md) keeps Workers, migration, writers, composition and the DS
  as-built record; its pending shape/carrier correction is specified here; and
- the [project-data analysis](2026-08-26_database.md) keeps formats-as-values, providers and content access,
  structural readers and their policies (ST7, ST11, ST16–ST20), expression-accessor generation and its
  compile-time path resolution, the performance baseline and pins, and durable storage; its type language (its
  §5), runtime contract (§8.1, §9.3) and Worker carrier (§11) now point here, and its §5 records the deliberate
  departures — no enum kind, `Opaque` for `Nominal` with native as a per-node annotation,
  `FieldId(name, occurrence)`, concrete runtime types under `Dynamic`, no runtime decode-failure state, and
  ST8 settled by the plugin depending on kzen-lib.

### 14.5 Sequencing

This is a foundational replacement, not a Job feature, and it is landed as a sequence of vertical cutovers with
temporary internal bridges that are deleted once their consumers have crossed — not as one all-repository
cutover, and not as a supported parallel legacy model. The order is driven by dependencies: bindings hold
`DataValue`s, so the value must exist before the bindings; the shape envelope needs only `DataType`, so it can
close the type-loss seam early.

1. **Settle the type and its algebra** — `DataType` with native annotations, `FieldId`, presence, tagged unions,
   `isAssignable` / `validate` / `project` / `join` with representative-pair and wire/digest tests, and the
   `KType` / `TypeMetadata` mappings.
2. **Move `DataShape` to the observation envelope.** Replace `Tabular | Payload`, make `DataSchemaDocument.shape()`
   stop discarding types, and update the client decoders. Declared and inspected sources use the same vocabulary.
3. **Prove the value over three backings.** `kzen-auto-plugin` takes its kzen-lib dependency and
   `FlatFileRecord` implements `ValueAccess`; the same record is read from it, a Kotlin data class and a fake
   typed row; a data-class instance retains its native type and exposes fields without copying; no per-field
   `DataValue` allocation on the flat path.
4. **Replace the Job carrier.** One `DataValue` crosses the lane; `WorkerLane` becomes a lane `DataType`; column
   Workers request `project`; `<missing>` moves to the projection; owned-append is benchmarked against the current
   path and under many sequential calculated columns.
5. **Land `BindingSchema` and `DataBindings`.** Replace `TupleDefinition` / `TupleValue` in `LogicSignature`,
   `Execution`, `JobControl` and `DataContext`, with the omission-semantics migration of §10.1.
6. **Cut Script and Flow over where generic data actually crosses** — step results and ports — with the replay
   lifetime rule and snapshot-based message inspection.
7. **Add the first structured reader.** Its requirements decide the structural tape and the `Dynamic` runtime
   behaviour; ST11, ST17 and ST20 policies gate it.
8. **Add the first real durable-row source.** Its measured cursor behaviour decides whether borrowed/retainable
   lifetime machinery is necessary.
9. **Design the richer wire grammar separately** (§12.2), and **graph structural exposure separately** (§8),
   each with the consumer that forces it.

This ordering is evidence for feasibility, not an approved execution plan. Exact package layout and rollout work
belong in a constituent plan only after this analysis is accepted. No version bump follows automatically (CC-14);
cross-repository publication order is kzen-lib before kzen-auto and its consumers, at the existing coordinated
development version.

## 15. Adoption gate

The proposal should not be accepted on API aesthetics alone. It is ready to become a plan when a prototype proves
the following together.

### Semantic model

- canonical `ExecutionValue` lowering and digest round-trips for every `DataType` case, including native
  annotations, exact integers and decimals as canonical text, and tagged unions with their active variant;
- representative `isAssignable` pairs under both requirements, including nullability, optional fields, record
  width, numeric promotion, collection variance and `Dynamic` direction;
- `validate` distinguishing compatible-type-but-nonconforming-value cases from type mismatches;
- `join` laws — associative, commutative, idempotent — and widening of inferred heterogeneity to `Dynamic`;
- canonical `Date`, `Time`, `Instant` and `Duration` values, including rejection of local date-times where an
  `Instant` is required;
- structural selection of `List<String> | String` from an untagged JSON value and from a native Kotlin value,
  external-tag decoding through `validateVariant`, and deterministic rejection of overlapping untagged variants;
- stable `FieldId(name, occurrence)` identity and duplicate display-label projection; and
- `KType` / `TypeMetadata` conversion with no application-specific branches.

### Bindings

- schema enumeration and lookup without runtime states; instance validation against one schema;
- unknown and duplicate name failures; required, optional and defaulted inputs;
- a present-null binding distinct from unbound; `Bound` with `Absent` root rejected;
- incremental produced outputs through the builder;
- origin and whole-binding redaction behaviour; and
- design request handling for zero, one and repeated values after routing parameters are removed.

### Adapters

- primitives, lists, arrays and maps; Kotlin data classes and Java records with native annotations;
- `Iterable` / `Sequence` / `Set` refused by the automatic baseline;
- arbitrary opaque objects with native access but no accidental reflection;
- exact-class conflict detection at registry construction and deterministic capability-fallback order;
- graph values lowered to stable references; and
- cycles rejected by the snapshot policy without arbitrary `toString()`.

### End-to-end composition

- a Formula returns an ordinary data class without wrapping, typed from its inferred `KType`;
- Script → Flow → Job → nested Logic preserves the value's type and native identity;
- the same structural consumer reads a flat row, a data class and a fake typed row;
- a tagged union exposes its active ID and selected value and round-trips through a typed snapshot;
- column projection works without a second carrier, and `<missing>` appears only in the projection;
- data-source arguments enumerate correctly and hosted results return typed bindings; and
- missing/default/null behaviour is identical across every Logic flavour.

### Lifetime and performance

- cursor items survive the actual Job batching, queueing and live-edit migration cadence under the owned-item
  contract, and Script replay retains only detached or run-owned values;
- cursor advance, close, cancellation and ownership transfer leave no usable dangling views;
- primitive field reads allocate nothing after setup, pinned by a narrow allocation test that names its layer;
- field traversal creates no per-field `DataValue` objects;
- flat input is not eagerly materialized;
- repeated calculated-column overlays retain bounded lookup cost and backing lifetime; and
- the representative Job data path stays within five percent of its current median throughput unless an
  explicitly measured capability justifies the cost.

## 16. Recommendation register

These are recommendations for review, not landed decisions. Entries changed by the folded review are marked.

| # | Question | Recommendation |
|---|---|---|
| UD1 | One model for every Logic flavour? | Yes; execution mechanics remain flavour-specific |
| UD2 | Foundation owner? | `kzen-lib-common`; JVM backings in `jvmMain` or consumer modules; `kzen-auto-plugin` depends on kzen-lib and emits the contract directly |
| UD3 | Runtime representation? | One read-only `DataValue` over multiple `ValueAccess` backings; type read from the backing, not cached beside it *(revised)* |
| UD4 | `Tabular`, `Payload`, or both? | None as type cases; use semantic types and explicit projections |
| UD5 | Must every union have a discriminator field? | No. Unions are declared/carried and every runtime node carries its active `VariantId`, taken from an external tag where the encoding has one and otherwise by unique-accepting-variant structural selection (ambiguity fails); no union inference from samples; no discriminator layout in `DataType` *(revised)* |
| UD6 | Normal Formula experience? | Return ordinary Kotlin objects; lift automatically at the boundary, typed from the inferred `KType` first |
| UD7 | Automatic structural native baseline? | Primitives, lists, arrays, maps, Kotlin data classes and Java records; no `Iterable` / `Sequence` / `Set`; arbitrary objects remain opaque *(revised)* |
| UD8 | Arguments/results? | Ordered, enumerable, typed `DataBindings` validated against a separate `BindingSchema`; no primary `Any?` lookup *(revised)* |
| UD9 | Missing versus null? | Always distinct |
| UD10 | Graph object read? | Original native instance plus stable-reference lowering in v1; policy-limited structural view later |
| UD11 | Graph object write? | Explicit notation command; never `DataValue` write-through |
| UD12 | Record → managed graph object? | Explicit import/create operation only |
| UD13 | Durable row read/write? | Row-backed read-only view; explicit transactional mutation |
| UD14 | Wire and trace model? | Keep `ExecutionValue` behind a typed `DataSnapshot` envelope with strict complete-or-rejected snapshots; `WireValue` rename and versioned grammar deferred *(revised)* |
| UD15 | Performance strategy? | Primitive handles, cached/generated adapters, no eager materialization, benchmark gate including many-overlay and typed-row paths |
| UD16 | Migration style? | Sequenced vertical cutovers with temporary internal bridges, then deletion; no supported parallel legacy model *(revised)* |
| UD17 | Temporal baseline? | `Date`, `Time`, `Instant`, `Duration`; no parameterized timezone mode |
| UD18 | Open-ended logical scalars? | Exclude initially; use `Opaque` plus adapters until a concrete refined-scalar contract is needed |
| UD19 | Separate detached `DataScalar`? | No; `ScalarExecutionValue` with canonical text under the owning `DataType` |
| UD20 | External discriminator layouts? | Codec-owned; they resolve to `VariantId` and do not appear in `DataType` |
| UD21 | Native and structural facets? | Orthogonal: every `DataType` node carries an optional native annotation; `Opaque` replaces `Nominal` *(new)* |
| UD22 | Runtime `Dynamic` access language? | None; `Dynamic` is an observation/requirement type and every present node carries a concrete type *(new)* |
| UD23 | Cursor item lifetime? | Independently owned until the cursor closes; borrowed/retainable leases only with the first source that cannot meet that *(new)* |
| UD24 | Universal `Invalid` state and per-node origins? | Not in v1; decode failure is settled by reader policy, origins exist at binding level only *(new)* |
| UD25 | Field identity? | `FieldId(name, occurrence)`, the `HeaderLabel` shape; provider IDs beside the type *(new)* |
| UD26 | Enum? | `Scalar(Text)` plus a symbol-set constraint in schema metadata; reopen with the first carried-schema format *(new)* |
| UD27 | Calculated columns? | Owned-append on appendable backings; indexed `Composed` overlay with a collapse threshold otherwise *(new)* |
| UD28 | Flat backing? | `FlatFileRecord` implements `ValueAccess` directly; the plugin's dependency-free policy is dropped, not worked around *(new)* |
| UD29 | Omitted Logic inputs? | Legal only under `Optional` / `Defaulted` presence; existing null-for-omitted callers migrate deliberately *(new)* |

## 17. Questions that remain legitimately open

Before an execution plan is approved, the following need prototypes or explicit decisions:

1. **Graph exposure metadata.** Which existing metadata can reliably distinguish authored data from injected
   constructor infrastructure, and what minimal new marker is required where it cannot? Needed for the deferred
   structural view, not for v1.
2. **Node-handle layout.** The token encoding and accessor split that support flat, native and row backings
   without allocation, and how a backing built outside kzen-lib mints tokens safely.
3. **Lossless schema metadata.** Which provider-specific details (enum symbols, temporal precision, numeric IDs,
   affinities) live beside `DataType` for migrations and structured writers, and in what container.
4. **Tabular projection policy.** Exact duplicate-label, nested-field and mapping-key rules for consumers that
   explicitly request columns, and where the `<missing>` rendering is configured.
5. **Owned-append threshold.** When a `Composed` overlay collapses to an owned copy, and how `FlatFileRecord`
   exposes append to its owner without exposing it through `ValueAccess`.
6. **Migration carry of owned values.** Exactly which scope a migration transfers for in-flight `Owned` values,
   and how `isAlive` observes a superseded frame.
7. **Enum reopening condition.** Whether the first carried-schema format needs enum identity in `join` or only
   in value validation.

Those are reasons to review and prototype the proposal before implementation. They are not reasons to retain the
current opaque and duplicated boundaries.

## 18. Disposition of the 2026-08-27 design review

The review's file was removed after this revision; this table is its permanent record. "Adopted" means the
finding is applied above as stated; "modified" means the diagnosis is accepted with a different fix; "declined"
means the finding is not applied, with the reason.

| Review finding | Disposition |
|---|---|
| Ten retained findings (one carrier, distinct containers, presence ≠ nullability, shape is an observation, read-only contract, explicit snapshots, specialized backings, performance gate, capability dispatch, `kzen-lib-common` owner) | Adopted — §1, §3, §5, §6, §14 |
| One `DataType` cannot be native and structural at once; use `DataDescriptor(structural, native)` | Modified — the diagnosis is right, but a top-level pair loses nested native types; the native facet is a per-node annotation and `Opaque` replaces `Nominal` (§4.1, §13.6) |
| Borrowed cursor values cannot cross Job batching; require independently owned items first | Adopted — §6.2, UD23; noted that `FileDataCursor` already behaves this way and that live-edit migration and Script replay are two further consumers of the rule |
| `Dynamic` is not dynamically accessible; keep it at observation boundaries | Modified — the conclusion is adopted (§4.6, UD22), but the missing piece was not an operation (`ValueAccess.type(node)` existed) — it was the root-type invariant, resolved by reading the type from the backing (§6, UD3) |
| Union traversal and wire identity incomplete; tagged-only, producer-selected, no `FieldDiscriminator`, no structural selection | Modified — active-variant traversal (`selected`), the snapshot tag, no inference and no `FieldDiscriminator` are adopted; excluding *all* structural selection is declined, because a declared `List<String> \| String` decoded from an untagged encoding or lifted from a native value has no other way to name its variant. The original unique-accepting-variant rule stays, with ambiguity failing (§4.5, §13.15) |
| Snapshot policy promises what the grammar cannot express; strict `DataSnapshot` / `SnapshotResult` first | Adopted — §12.1; the deferred grammar is listed in §12.2 |
| Signature schemas and binding instances are different; `BindingSchema` + validated `DataBindings` | Adopted — §10, plus a builder for incrementally produced outputs |
| One `accepts` is underspecified; separate assignability, validation and projection | Adopted — §4.7, with an explicit `DataRequirement` selecting the facet |
| Root type stored twice | Adopted — `DataValue.type` delegates to the backing |
| External backings cannot construct `DataNode` | Adopted — public constructor; token namespace owned by the backing |
| Retention declared at the wrong granularity | Adopted — per root value; v1 `Detached | Owned` |
| Read-only, not immutable | Adopted — principle 5 |
| Automatic collection lifting too broad | Adopted — §7.2; empty untyped collections still use `Dynamic`, which is the honestly unknown element type the review asked for, with the compiler-inferred `KType` preferred where one exists |
| Record identity vs wire encoding; reuse name + occurrence | Adopted — `FieldId(name, occurrence)`, §4.2 |
| Scalar scope drifted; decide enum | Adopted — enum excluded from `ScalarKind` in v1, recorded as a deliberate departure (§4.4, UD26) |
| Per-node origins speculative | Adopted — binding origins only (§13.18) |
| Sensitivity only whole-binding | Adopted — §10.1 |
| Adapter conflicts undetectable from `match(value)` | Adopted — exact-class map plus ordered capability fallbacks (§7.3) |
| `kzen-lib-common` ownership does not settle the plugin SPI | Adopted and settled — `kzen-auto-plugin` depends on kzen-lib and `FlatFileRecord` implements `ValueAccess`; the dependency-free policy protected no external contract (§6.1, §13.17, §14.3) |
| Repeated composed overlays need a flattening rule | Adopted, with a stronger default — owned-append on appendable backings is the hot path; `Composed` is the exception (§11.4, UD27) |
| Smaller target: keep `ExecutionValue`, defer rename | Adopted — §2.4, §12, UD14 |
| Recommended sequence (descriptor → algebra → bindings → backings → carrier → shape → …) | Modified — bindings hold values, so they follow the value proof; the shape envelope needs only the type, so it moves up to close the `DataSchemaDocument.shape()` type-loss seam early (§14.5) |
| Adoption gate | Adopted and merged into §15 |
