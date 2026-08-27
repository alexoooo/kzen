# Unified data model — types, values, bindings and managed-object views

> **Status: proposal for review, revised after four rounds of design review; not an implementation contract.**
> This document holds the complete current argument for a data model shared by every Logic flavour. It does not
> authorize code changes or alter the implementation status of any plan. Every 2026-08-27 design review has been
> folded in and its file removed — corrections are applied in place, and the
> [review history](2026-08-27_data-model_history.md) records the disposition of every finding so no review is a
> second source of truth. This document carries the current contract, its rationale, rejected alternatives, the
> adoption gate and the open questions; it does not carry chronology. If the proposal is accepted, this document owns
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

- one recursive structural `DataType`, carried at every node inside a `DataContract` that may additionally name
  the native Kotlin class the node's live value can be handed to;
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
| Types | Scalar, Record, Mapping, Listing, tagged Union, Opaque, Dynamic inside a recursive `DataContract(structural, native)`; conservative `join`; the scalar vocabulary declared, only the kinds the proof exercises gated | structural union inference; field discriminators in the type; the whole constraint layer (enum symbol sets, precision/scale, ranges) and its container; `Decimal` precision/scale parameters and `LocalDateTime` (first database consumer); open-ended logical/refined scalars |
| Values | read-only `DataValue` over literal, flat-record, native-object and fake typed-row backings; frozen after publication; every value readable while reachable | structural tape (first tree reader); graph structural exposure, reference navigation and stable-reference lowering (graph provenance seam); `Composed` overlays; borrowed / retainable leases and any public retention state (first JDBC source) |
| Bindings | `BindingSchema` + validated `DataBindings`; literal defaults on binding definitions; shallow bind-time checks; whole-binding display-only sensitivity | computed defaults; nested field sensitivity; sensitivity as data taint |
| Wire / trace | today's `ExecutionValue` inside a `DataSnapshot` envelope carrying the structural type only; complete, redacted or rejected; duplicate-field records reject | `WireValue` rename and versioned grammar; ordered-entries record encoding; redaction and truncation markers; identity references; reference following |
| Adapters | primitives, lists, arrays, maps, acyclic Kotlin data classes, Java records; exact-class registrations keyed by class identity, consulted first; ordered capability fallbacks; static `describe` | `Iterable` / `Sequence` / `Set` lifting (explicit streaming boundary instead); public-getter reflection (never); recursive data-class expansion |

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
runtime backing. Every position in the tree — a root, a field, a listing element, a mapping value, a union
variant — is a `DataContract`: the structural `DataType` plus an optional **native facet** naming the Kotlin
class the node's live value may be handed to without copying.

```kotlin
data class FieldId(
    val name: String,
    val occurrence: Int = 0
)

@JvmInline
value class VariantId(val value: String)

data class DataContract(
    val structural: DataType,
    val native: TypeMetadata? = null
)

data class DataField(
    val id: FieldId,
    val contract: DataContract,
    val optional: Boolean = false
)

sealed interface ScalarKind {
    data object Boolean: ScalarKind
    data class Integer(val bits: Int? = null, val signed: kotlin.Boolean = true): ScalarKind
    data object Decimal: ScalarKind
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
    val contract: DataContract
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
        val value: DataContract,
        override val nullable: Boolean = false
    ): DataType

    data class Listing(
        val element: DataContract,
        override val nullable: Boolean = false
    ): DataType

    data class Union(
        val variants: List<DataVariant>,
        override val nullable: Boolean = false
    ): DataType

    data class Opaque(
        override val nullable: Boolean = false
    ): DataType

    data class Dynamic(
        override val nullable: Boolean = true
    ): DataType
}
```

`TypeMetadata`, `ClassName` and `ExecutionValue` are existing kzen-lib types. Every other referenced type is defined above. The
syntax is a proposal rather than a frozen ABI, but the semantics and invariants below are part of the proposal; an
implementation should not silently fill them in differently. Lanes, ports, bindings, shapes and runtime values
all carry a `DataContract`; bare `DataType` appears only inside the structural tree and as a mapping key.

### 4.1 The native facet is a capability, not part of structural identity

`native` answers a different question from the structural case: not "what operations does this value support"
but "which Kotlin class may native code receive this value as, without a copy". That is a promise about the live
backing, which is why it sits beside the structural type in `DataContract` rather than inside `DataType`:

| Value | Structural facet | Native facet |
|---|---|---|
| CSV row | `Record` of `Scalar(Text)` fields | none promised |
| Kotlin `data class Reading(sensor, value)` | `Record(sensor: Text, value: Floating)` | `Reading` |
| Nested field `order.customer` of type `Customer` | `Record(...)` | `Customer` |
| Arbitrary opaque Kotlin object | `Opaque` | its declared class (required) |
| Typed database row | `Record` | optional provider-owned row type |
| Graph-created object | ordinary baseline in v1 — `Record` if a data class, else `Opaque`; exposure-policy `Record` later (§8) | its created class |
| `List<Reading>` | `Listing(element = Contract(Record(...), Reading))` | `kotlin.collections.List` |

The contract is recursive, which is why it is a per-position wrapper rather than a top-level pair: generated
Script code that reads `order.customer` needs the nested position's native class to hand `Customer` to a native
member call, and a root-only descriptor would have lost it (§13.6).

The native facet is the existing `TypeMetadata` — class name, generic arguments, nullability — rather than a
bare class name, because the structural tree cannot recover every generic argument: `Box<String>` and
`Box<Int>` are both `Opaque` with class `Box` when `Box` is not a data class, and a phantom or partially exposed
parameter is invisible to structure. Authored signatures already carry those arguments today and the model must
not lose them, and the native compiler probe needs them to enforce Kotlin's own variance rules on native
generics. Where the two halves overlap they cannot disagree, by construction rather than by discipline: the JVM
`KType → DataContract` mapping builds both from one `KType`, the constructor requires the facet's `nullable` to
equal the structural `nullable`, and for the standard collections the structural element / key / value
positions are derived from the facet's arguments. A bare-name facet was tried and reverted for losing nominal
generics.

Four rules follow from "capability, not identity":

- **Two equalities, stated by name.** *Structural* equality is `DataType` equality: canonical digests, lane
  identity and snapshot types use it, so a data-class-backed record and a row-backed record with the same fields
  are the same lane type, and changing an adapter or backing never changes a lane's type. *Declaration*
  equality is `DataContract` equality (the data class's own), which includes the facet: signatures, port
  declarations and the expression compiler's cache keys use it, because a signature requiring native `Reading`
  and one requiring native `Customer` are different declarations even when their fields coincide. It is
  declaration equality, not JVM type identity — two declarations can be equal and still name different loaded
  classes — which is why the next rule exists. No API compares contracts without saying which equality it means.
- **The facet describes the live value.** A `DataValue` reports the native type its backing actually supplies.
  A declaration (a port, a binding, a Formula's expected result) may require one. A detached snapshot carries only
  the structural type, because the decoded tree cannot reproduce the original instance (§12.1).
- **The name is common metadata; identity is a JVM-local token.** The same fully-qualified name loaded by two
  plugin classloaders is two JVM types, so the common contract never decides native compatibility by comparing
  names, and no resolver can recover which loader supplied a name once only the name remains. Native
  assignability (§4.7) therefore works on a *declaration plus token* model: a live value supplies its actual
  `Class` (`native(node)::class`); a declaration built in-process from a `KType` — a Logic signature, a Flow
  port, a Formula's inferred result — keeps the `KType` and its defining loader beside the common `TypeMetadata`
  as a JVM-local token, so two in-process declarations are compared token to token; and a declaration that
  arrived as a name only (deserialized, client-authored) is **provisionally** compatible and confirmed against
  the first live value that crosses. `TypeMetadata` stays the client-visible, serializable rendering.
- **`Opaque` needs a native type, and accepts by it alone.** `Opaque` says "no structural contract has been
  promised", so a contract whose structural type is `Opaque` must carry a native facet; the `DataContract`
  constructor enforces it. An expected `Opaque(NativeX)` accepts any actual whose facet is assignable to
  `NativeX` — a `Record(…, NativeX)` included — because it makes no structural demand; this is what lets an
  adapter whose structure depends on the instance (`describe` returns null, §7.3) bind the richer value its
  `lift` produces. `Dynamic` and mapping keys never carry a facet.

Compatibility is projection-specific, and the native requirement is additive. A structural consumer (Sort,
Filter, a table, a writer) asks whether the structural facet accepts its requirement and ignores the native
facet. A native consumer (generated Kotlin calling members of `Reading`) asks for `DataRequirement.Native`, which
checks structural acceptance *and* that the native facet is assignable to the class it compiles against — never
native alone, because the same boundary may promise fields to a downstream structural consumer. The algebra in
§4.7 takes the requirement explicitly rather than guessing which facet a caller means.

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
it; until then, one identity shape serves both structural fields and tabular headers. The identity is stable
*within one schema version*: inserting an earlier same-named field or renaming a field changes it, so a format
whose evolution semantics need rename-stable identity (protobuf field numbers, Avro aliases) keeps its provider
IDs beside the type and maps them to `FieldId` at the boundary.

Defaults are construction policy, not runtime type. A `DataField` is required or optional and nothing more;
where a declared default exists it lives on the `BindingDefinition` that applies it (§10) or in the schema /
reader contract that fills an absent field while decoding (project-data ST17), and the value that results is an
ordinary present field. Two runtime records with the same fields are therefore the same type regardless of how an
absent input would have been constructed. `DataDefault.literal` is an `ExecutionValue` and must be recursively
self-contained: it may not contain a `binary-handle`. It is detached canonical data, not a live native object or
executable expression. Its decoded type must be accepted by the binding contract. A computed default belongs to
binding construction and must produce the same explicit `Defaulted` origin; it is not smuggled into `DataDefault`
as arbitrary code. Computed defaults are deferred unless an existing Logic contract requires them; literal
defaults are sufficient for the foundational proof.

`ScalarKind` is sealed rather than an enum because integer width and floating width carry parameters.
`Integer.bits == null` means arbitrary precision. `Decimal` is an exact decimal of unconstrained precision, not
binary floating point; declared precision and scale are constraint-layer and representation metadata (§4.4) and
arrive with the first database consumer, so the v1 kind is unparameterized.

Scalar runtime values and mapping keys are read either through allocation-free primitive accessors or as a
detached `ScalarExecutionValue` (§6). Exact integers, decimals, temporal values and UUIDs use their canonical text
form inside the existing `text` variant and are interpreted under the owning `DataType`; there is no parallel
`DataScalar`. That rule is what makes the existing `ExecutionValue` grammar sufficient for v1 (§12).

### 4.3 Records, mappings and listings are different

A record has an ordered, declared field set. A mapping has arbitrary scalar keys with a uniform value type. A
listing has ordered numeric positions. Treating all three as `Map<String, Any?>` loses order, field identity,
duplicate field handling, presence and element constraints.

`Mapping.key` must be a non-null `Scalar` or `Dynamic(nullable = false)`; records and collections cannot be
keys, and the nullable default of `Dynamic` never applies in key position. Using a `DataType` rather than a
required `ScalarKind` lets an empty or genuinely dynamic map *observation* state honestly
that its key kind is not yet known. A *non-empty* present runtime mapping node always reports a concrete key
kind, as every present node does (§4.6), because `keyAt` returns a canonical-text `ScalarExecutionValue` that is
only interpretable under an owning scalar kind — text `"1"`, integer `1` and decimal `1` are otherwise
indistinguishable; an empty mapping with no expected type honestly reports a `Dynamic` key (§7.2). The native
baseline's key rules are fixed rather than discovered: a map whose keys have no single scalar kind, or that
contains a null key, is not lifted as a `Mapping` and stays `Opaque` until an adapter states the key policy; the
key kind is that of the actual key class, and distinct numeric key classes are not joined into one kind in v1;
and two distinct native keys that lower to the same canonical scalar text (`1` and `1.0` under one kind) make
lifting fail with a `DataProblem`, because `keyAt` plus canonical text could not represent that map faithfully.

`DataField` needs a stable identity separate from its display label, its `DataContract`, and an optionality:

- required — absence is invalid; or
- optional — absence is valid and distinct from null.

Nullability belongs to `DataType`; optionality belongs to the containing field; defaults belong to the binding
or schema that applies them (§4.2). Absent, null, defaulted and present remain four distinct observations — the
first three at a field or binding, the fourth on the value, and `Defaulted` as a binding origin rather than a
field state. A field whose decoding failed is not a fifth runtime state in v1:
the reader's decode policy (project-data ST17 — fail the part, skip the record, or substitute null / default)
settles it before the value reaches a lane, and diagnostics carry source, unit, record and path. A transportable
`Invalid` state is added only with a quarantine lane that needs to carry it.

Field labels remain ordered and may require a projection policy when a tabular consumer demands unique labels.
That policy does not alter the record's semantic type.

### 4.4 Scalar kinds are semantic, not JSON-derived

The initial scalar vocabulary covers boolean, text, integral and decimal numbers, binary, UUID, and the time/date
kinds kzen actually needs. Null is a `DataState`, not a scalar kind. The type algebra does not inherit JSON's
limited number and time vocabulary merely because JSON is one wire format.

The model has two explicit layers, and the test for which layer a property belongs to is *access*:

- **`DataType` is the access shape.** A property belongs in it when a generic consumer reads the value differently
  because of it. Integer width and signedness, floating width and the decimal/integer distinction pass — an
  allocation-free `readLong` is exact only for an integer that fits, and a decimal is read through `scalar`
  rather than a primitive path.
- **A constraint layer owns value restrictions.** Symbol sets, decimal precision/scale, string length, numeric
  ranges and declared defaults change *validation*, not access. They are carried as schema metadata beside the
  `DataContract` and enforced by `validate` (§4.7) or by the reader's decode policy where a declaring schema
  supplies them; generic acceptance never compares them.

Provider-native details that change neither access nor validation — temporal precision, fixed-binary length, a
column's affinity — are representation metadata in the same container, used for lossless round-trip or migration
and never consulted by generic access.

**The whole constraint layer is deferred, with its container, until the first declaring schema supplies a
constraint** — nothing in v1 needs one, and the layer's shape is open question 3 (§17). Until then `validate`
checks structure and presence only, and precision and scale are neither in the type nor anywhere else.

**Enum is deliberately not a scalar kind**, a change from the project-data analysis's scalar list, and it is the
constraint layer's clearest case: a closed symbol set does not change how a generic consumer *accesses* the
value — it is text — and treating membership as type compatibility would make `isAssignable` and `join` reason
about symbol sets before any consumer needs it. An enum is `Scalar(Text)`; the symbol-set constraint arrives
with the layer, and the decision reopens with the first carried-schema format (Avro) whose union or default
semantics depend on enum identity.

The temporal meanings are deliberately small and explicit:

- `Date` is a calendar date without a time or zone;
- `Time` is a wall-clock time without a date or zone;
- `Instant` is an absolute point on the timeline, canonically serialized in UTC; and
- `Duration` is an elapsed amount rather than a calendar date/time.

`Instant` does not pretend to represent a local date-time. Converting "09:00 on 2026-09-01" to an instant requires
a timezone and its rules, which the value does not contain. The initial core therefore has no parameterized
`DateTime(TimeZoneSemantics)` case. Timestamp-without-timezone is nevertheless common database data and is not
provider trivia: it lands as a distinct `LocalDateTime` kind with the first database consumer, and is never
silently coerced to a UTC `Instant` in the meantime — until then it is canonical text or an opaque adapted value.
A provider's original offset, region ID and precision remain representation metadata.

The initial core also has no generic `Logical(id, storage)` extension case. `Opaque` plus the adapter registry
already provides a safe extension path for custom values. A logical/refined scalar can be added when a real type
needs generic primitive transport while retaining semantic identity; the registry is not introduced speculatively.

### 4.5 Unions are tagged at runtime, and the producer names the active variant

A union is an ordered, non-empty set of variants with unique IDs. A variant may be any `DataContract`. Null is
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
- **By selection.** Where the encoding carries no tag, `selectVariant` (§4.7) compares the value's concrete
  contract with every variant under an explicit requirement: exactly one accepting variant selects it; no
  accepting variant is a type error; more than one is ambiguous and fails unless the codec has an explicit,
  separately declared disambiguation policy. Variant order is canonical for display and digest purposes and is
  never an implicit "first match wins".

Assignability and selection are different relations, and assignability has three cases, not one:

- an expected union accepts a *concrete* actual contract when at least one variant does;
- an expected union accepts an *actual union* only when every actual variant is accepted by some expected
  variant — `String | Date` does not satisfy `String | Integer` merely because the string branch matches; and
- a concrete expected contract accepts an actual union only when it accepts every variant.

Selection *succeeds* only when exactly one variant accepts a concrete actual contract. An actual that is itself a
tagged union node is selected through its active variant's contract; a `Dynamic` actual cannot select and is
`NoMatch`. A binding or adapter receiving an untagged value must therefore call `selectVariant`, never plain
union assignability — a value can be assignable to a union and still impossible to tag implicitly. Two variants
with the same ID are a construction error; two variants with different IDs and identical contracts are legal
(a protobuf `oneof` of two strings) but untagged selection between them is always `Ambiguous`, so such a union
is usable only with an external tag. A nullable union's root may be `Null` with no active variant; the variants'
own nullability is theirs.

Selection also constructs the tagged node. Lifting a Kotlin `List<String>` or decoding a JSON array against an
expected union does not merely return a `VariantId`: the producer wraps the selected value exactly once in a
union root whose contract *is* the union and whose `activeVariant` is the selection, so that the binding schema
and the bound value agree on the root type and `selected` reaches the variant's value. Without that rule the
schema would say `Union` while the value said `Listing`, recreating the declaration / value mismatch the model
exists to remove.

`List<String> | String` is the motivating case for the second rule:

```kotlin
DataType.Union(
    variants = listOf(
        DataVariant(VariantId("many"), DataContract(DataType.Listing(DataContract(DataType.Scalar(ScalarKind.Text))))),
        DataVariant(VariantId("one"), DataContract(DataType.Scalar(ScalarKind.Text)))
    )
)
```

A JSON codec meeting an untagged array or string, and a Formula returning a Kotlin `List<String>` or `String`
against that expected type, both select unambiguously because exactly one variant accepts each; the resulting
node carries `many` or `one` from then on. A declared `Record(a) | Record(a, b)` decoded from an untagged
`{a: 1}` is the failing case — both variants may accept it under width-tolerant assignability — and the schema
author either supplies a tag or the codec declares which wins. The record-width rule the algebra eventually
settles (§4.7) is therefore part of the union codec contract, not an isolated algebra choice, and the two are
tested as a pair.

The requirement matters for native alternatives. Structural selection cannot distinguish two same-shaped Kotlin
classes, two opaque natives, or width-overlapping records. A Formula that declares a union of Kotlin classes
selects under `DataRequirement.Native`, where the runtime class is unambiguous; a codec decoding a schema-only
union selects under `Structural`. The requirement is the caller's, exactly as for `isAssignable`.

Union is in v1, with `List<String> | String` as its named consumer: one-or-many is a common data pattern in
authored configuration and JSON, and carried-schema formats (Avro, protobuf `oneof`, XML `choice`) need the same
machinery later. The incremental cost is small — the access operations, selection algebra and `{variant, value}`
lowering are specified above, and the only new backing is a union-root wrapper holding the selected value and
its `VariantId`. The real cost is test surface (ambiguity and record-width cases), which is what the vertical
proof is for (§15).

### 4.6 Opaque and Dynamic are two different kinds of "not structural"

`Opaque` means "this value is known only by its native type; no structural contract has been promised." It is not
a failure case. Native Kotlin code receives the original object without copying. A registered adapter may lift the
same object as a structurally richer node with the same native facet, which is the normal way an opaque
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
    fun isAssignable(expected: DataContract, actual: DataContract, requirement: DataRequirement): TypeAcceptance
    fun join(left: DataContract, right: DataContract): DataContract
    fun selectVariant(union: DataType.Union, actual: DataContract, requirement: DataRequirement): VariantSelection
    fun validateVariant(union: DataType.Union, variant: VariantId, actual: DataContract, requirement: DataRequirement): TypeAcceptance
}

sealed interface VariantSelection {
    data class Selected(val variant: VariantId): VariantSelection
    data class NoMatch(val problem: DataProblem): VariantSelection
    data class Ambiguous(val candidates: List<VariantId>): VariantSelection
}

interface DataValueAlgebra {
    fun validate(value: DataValue, expected: DataContract): ValueValidation
}

sealed interface TypeAcceptance {
    data object Accepted: TypeAcceptance
    data object Provisional: TypeAcceptance
    data class Rejected(val problem: DataProblem): TypeAcceptance
}

sealed interface ValueValidation {
    data object Valid: ValueValidation
    data class Invalid(val problems: List<DataProblem>): ValueValidation
}

class DataAccessException(val problem: DataProblem): RuntimeException(problem.message)

sealed interface DataPathSegment {
    data class Field(val id: FieldId): DataPathSegment
    data class Entry(val key: ScalarExecutionValue): DataPathSegment
    data class Element(val index: Int): DataPathSegment
    data class Variant(val id: VariantId): DataPathSegment
}
```

`isAssignable` answers type compatibility only, under an explicit requirement: structural assignability ignores
native facets; native assignability is structural assignability plus a facet comparison through the platform
resolver described below (§4.1), and answers `Provisional` when the actual side is a name-only declaration whose
identity the first live value will confirm; an expected `Opaque` makes no structural demand (§4.1); union cases
follow the three rules of §4.5. `selectVariant` answers the separate question for an
untagged value — unique acceptance under the caller's requirement — and returns every ambiguous candidate rather
than guessing (§4.5); `validateVariant` checks an ID that a codec resolved from an external tag. `validate` is
the explicit, possibly linear-cost walk of a present value against an expected contract, reporting absent
required fields, null in non-null positions, constraint-layer violations and variant mismatches; it is never
implied by binding a value (§10.1). One typed path vocabulary, `DataPathSegment`, addresses duplicate fields,
non-text keys, indices and union selections unambiguously in every `DataProblem` raised by validation or
snapshotting; a `List<String>` path cannot.

There is no generic `project(value, target)` in the common algebra. Reshaping — record-to-tabular flattening
under a naming policy, scalar-to-single-column, mapping-to-columns under a key policy — has exactly one consumer
today, Job's column Workers, and is owned there as a `ColumnProjection` capability (§11.4). A shared projection
API is extracted when a second consumer demonstrates shared semantics, not designed in advance (§13.20).

Before adoption the algebra must settle, with representative-pair tests: record width (does a wider actual
satisfy a narrower expected?), field identity, optional fields against required ones, numeric promotion,
listing and mapping variance, the direction of `Dynamic` (a `Dynamic` requirement accepts everything; a `Dynamic`
actual satisfies only a `Dynamic` requirement), union normalization, and the join laws. `join` must be
associative, commutative and idempotent, or sample order changes an inferred contract. Because a `Record`'s
field order is part of its identity, a join that merged differing field sets could not be commutative without
either sorting fields (discarding the source order column consumers and UIs preserve) or moving order out of the
type, so the generic join is deliberately **conservative**: two records join field-wise only when their ordered
`FieldId` lists are identical, and otherwise widen to `Dynamic`; listings and mappings join their element / key /
value positions; scalars join by numeric promotion or widen. Job's heterogeneous-header superset normalization
(`schemaMode: superset`) is an intentionally order-aware `ColumnProjection` operation (§11.4), not the generic
join. Unions follow the same rule for the same reason — variant order is part of a union's identity (§4.5) —
so two unions join only when identical and otherwise widen to `Dynamic`; `join` never synthesizes a union, and
incompatible inferred alternatives widen to `Dynamic`. A join whose inputs disagree on native facets keeps the
structural result with no facet. Flattening nested unions and removing variants that duplicate both ID and
contract is construction-time normalization of a *declared* union, not a join operation.

#### Platform seams: native types are resolved on the JVM

`TypeMetadata` holds a class name, generic arguments and nullability — nothing else. It cannot say which
properties a data class has, whether a class is a Java record, what it inherits, or which adapter describes it,
and the same fully-qualified name loaded by two plugin classloaders does not denote one JVM type. The mappings
the model needs are therefore stated for what they are, rather than as one generic bidirectional conversion:

- **`KType → DataContract` is a JVM operation** in `kzen-lib-common`'s `jvmMain`: `Int → Scalar(Integer(32))`,
  `String → Scalar(Text)`, `Map<String, String> → Mapping(Text, Contract(Scalar(Text)))`,
  `List<T> → Listing(Contract(T))` with native `List`, a Kotlin data class or Java record → `Record` with the
  class as native facet, a class with a registered adapter → whatever its `describe` returns (§7.3), anything
  else → `Opaque` with the class. It loads and inspects classes, so it is neither common-platform nor
  free of I/O. It is what types a Formula's output lane from `CalculatedColumnEval.inferredReturnKType`.
- **`TypeMetadata → DataContract` is lossy** and common-platform: primitives and the standard collection classes
  map structurally from the generic arguments; every other class maps to `Opaque` with the class as native
  facet, because the descriptor has no property information. It is enough for a client to render a declared
  port or binding; it is not enough to type a Formula lane, which is why the JVM mapping exists.
- **`DataContract → TypeMetadata` is the facet itself** where one exists; a purely structural record has no
  native counterpart and the conversion reports that, rather than inventing one.
- **Native assignability is a platform resolver**, not a class-name comparison, on the declaration-plus-token
  model of §4.1: the expected side is the requiring declaration's JVM-local token (its `KType` and loader); the
  actual side is the live backing's `Class` when a value is at hand, the producing declaration's token when both
  declarations are in-process, and provisional otherwise. On the JVM it is today's `TypeAssignability` compiler
  probe (or an equivalent over actual type identity), which already handles subtyping, generic variance and
  nullability by Kotlin's own rules — which is why the facet keeps its generic arguments; the common algebra
  delegates `DataRequirement.Native` to it and does not re-implement it over strings.

None of these contains application-specific branches. Where a capability genuinely needs a runtime value — a
fallback adapter whose predicate inspects the instance — the static lane honestly stays `Opaque` or `Dynamic`
rather than pretending the adapter's runtime result is known.

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
    val itemType: DataContract,
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
contract. `provenance` is one value because it records which rung of the project-data analysis's resolution
*ladder* (its §6.2 — declared, carried, provider-reported, inferred, dynamic, tried in that order) supplied the
type; the ladder is the resolution algorithm, not an evidence chain the shape must retain. Where a lower rung
disagreed with the winning one, that disagreement is a diagnostic, which is all the client and the writer need. A provisional `itemType` is an observation; it is not a promise that every emitted item has exactly
that type, which is why each emitted value carries its own concrete type (§4.6).

There is no `Tabular`, `Payload` or `Both` case (project-data ST4, settled 2026-08-27; data-source DM9):

- a CSV row is normally a `Record` backed by a flat record;
- a Kotlin data class is a `Record` with a native facet, backed by the native instance;
- a scalar is `Scalar`, regardless of whether a table UI projects it to a synthetic `value` column;
- a map is `Mapping`, even if one particular runtime key set can be displayed as columns; and
- an opaque Kotlin object is `Opaque`, not "payload."

Tabular access is a consumer-owned projection capability (`ColumnProjection`, §11.4). It may accept a record
directly, project a scalar to one column, or require a deliberate mapping-key policy. The value does not acquire
a second identity because a table rendered it.

`DataShape`, `DataContract` and `DataShapeResult` are client-visible: `JobUpstreamSchema` and `DataSourceShapeStore`
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
    val contract: DataContract
        get() = access.contract(root)

    val type: DataType
        get() = contract.structural
}

data class DataProblem(
    val code: String,
    val message: String,
    val path: List<DataPathSegment> = emptyList()
)

enum class DataState {
    Absent,
    Null,
    Present
}
```

`DataValue.contract` delegates to the backing rather than caching a second copy joined by an asserted invariant,
and its native facet is whatever the backing actually supplies (§4.1). The declared or expected contract lives on
the binding, port or shape that receives the value, and `isAssignable` / `validate` relate the two. A root value
is `Present` or `Null`; `Absent` belongs to a containing field or binding.

`DataNode.token` is meaningful only to the accompanying `ValueAccess`; nodes from different access instances are
never interchangeable. The constructor is public because backings implemented outside kzen-lib — a consumer
plugin's `FlatFileRecord`, a provider's row cursor — must mint the tokens their own `field`, `entry` and
`element` return. The access implementation owns the token namespace and any backing tables, which fixes the
public representation at one inline `Long` while leaving each backing free to encode offsets, row/field slots or
cached native-property plans.

The complete semantic access surface is:

```kotlin
interface ValueAccess {
    fun contract(node: DataNode): DataContract
    fun state(node: DataNode): DataState

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
```

`scalar` is the complete canonical path for every `ScalarKind`, including arbitrary-precision numbers and
temporal values. The specialized reads are allocation-free fast paths and succeed only when the scalar kind can
be represented exactly by the requested Kotlin primitive. `readBinary` returns a defensive copy; a zero-copy binary
consumer needs an explicit borrowed-buffer capability with the same lifetime rules as the backing. `native` is the
explicit native interop edge: it returns the object named by the node's native facet and fails when the node has
none rather than synthesizing one. There is no `retention` or `isAlive` on the v1 surface, because v1 has no
value that can expire before the run does (§6.2).

`activeVariant` and `selected` are valid only for a present union node; `selected` returns the node of the active
variant's value, whose own type is that variant's type, so a union whose active branch is a record is traversed
with `field` on the selected node. `field`, `entry`, `element`, `size` and `keyAt` are valid only for compatible
present structural nodes. A record enumerates fields through its ordered `DataType.Record` definition; a mapping
uses `size` plus `keyAt`. Unsupported operations fail as contract violations. The eventual source API may split
these operations into capability subinterfaces, but it must preserve these semantics and must not require
generic code to inspect concrete backing classes.

An accessor fails immediately when an operation contradicts `DataType`: reading text from a record or asking a
required missing field to masquerade as null is a contract error, not a fallback. The failure carrier is
`DataAccessException(problem)` (§4.7), thrown by the accessor that met the violation — a result type on every
read would box the allocation-free primitive paths the interface exists to keep. Successful reads return raw
values; only failures allocate.

Node identity is not a property of tokens — two paths that reach the same native object may legitimately return
different tokens, because a token is a position, not an object. Operations that need identity (cycle detection
in snapshots, §12.1; explicit content comparison) take it from `native(node)` on nodes whose contract carries a
native facet and whose type is a record, listing, mapping or opaque — reference identity of the backing object.
Scalar leaves never participate: an interned or shared `String` behind two text fields is two equal leaves, not
a revisit. Backings without native facets (flat records, tapes, rows) cannot alias and need no identity.

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
| Graph object | Notation-defined and graph-created objects | Retains graph instance/definition context; selected attributes are lazy fields | not in v1 — graph objects use the ordinary baseline; this backing arrives with the provenance seam (§8) |
| Composed | Transform output overlaying an input without copying it | Resolves unchanged fields through the input and new fields through an indexed overlay | not in v1 — column mutation over a non-appendable backing materializes once instead (§11.4) |

The list is open. Adding a backing should not add a new `DataType` case or require changes to every consumer.

The flat backing is **`FlatFileRecord` itself implementing `ValueAccess`**. It is a Java class in the JVM-only
`kzen-auto-plugin` artifact, which today depends on nothing but a hashing library; that artifact takes a
dependency on the JVM variant of `kzen-lib-common` so the record implements the contract directly over its
existing `char[]` / `int[]` spans and `cachedDoubleOrNan` / `cachedHash` caches, with no forwarding object on the
hottest read path. One consequence is accepted rather than discovered: the record today stores only cell
contents, and its header lives in the `FlatView` shared across rows, but `contract(root)` must answer with the
record's field list — so the record carries a reference to its shared header, set when the parser fills it. That
is one pointer per record, not a per-row adapter object, and it makes the shared-header relationship explicit
instead of implicit. The header reference then has defined behaviour under the record's existing buffer
operations: `clear` keeps it (the buffer is reused for the next row of the same source), a copy or clone carries
it, and an exchange of contents between two records exchanges it — a record's fields and its header always
travel together. The allocation argument for direct implementation over a `FlatRecordAccess(header, record)`
wrapper is not taken on faith: today's flat path already allocates `JobMessage` and `FlatView` per row, so both
forms are benchmarked in the vertical proof (§15) and the direct form stands only if it measures better.
Third-party `ReportDefiner` plugins then emit `DataValue` — or their own output type lifted
by a registered adapter. The plugin is in-development code with no external consumers beyond the sample plugin,
so its dependency policy changes with the model rather than constraining it (§14.3).

### 6.2 Read-only access and lifetime

`DataValue` is a read view even when its backing object is mutable. No `setField` belongs on `ValueAccess`.
Graph changes go through notation commands/reducers; durable-row changes go through a store transaction or
repository command; Kotlin object mutation remains explicit Kotlin code.

`native` is the deliberate escape hatch from that guarantee. A caller requesting the original mutable Kotlin
object may mutate it through its own API; generic structural processors never call `native` merely to read
fields. The generic API prevents write-through; it does not promise an immutable value, which is why principle 5
says read-only. What it does promise is a **publication rule**:

> **Once published — handed to any other consumer, trace, channel or binding — a value is frozen by contract.
> Mutation is legal only through an unpublished builder, or after an explicit exclusive ownership transfer.**

The rule is deliberately stronger than "mutation that keeps the contract is fine". A mutable list that changes
size mid-snapshot never violates its type, yet the snapshot is neither the state before nor the state after;
permitting the within-contract subset would oblige every mutable backing to version or lock, and
`SnapshotResult.Complete` to mean "consistent unless something moved". Frozen-by-contract removes that whole
class — concurrency, snapshot consistency, hashing, repeated validation — with one sentence, and it is already
the rule the calculated-column append path needs (§11.4). The framework still cannot stop a holder of the
`native` object from mutating it; it defines every such post-publication mutation as the mutator's contract
violation, and a read that meets a *detectable* consequence (an element of the wrong class, a null in a non-null
position) fails with `DataAccessException` at the node's path rather than coercing. v1 has no invalidation,
versioning or detach machinery, because pretending to enforce the rule fully would promise more than the API can
keep. The rule also states honestly what "the contract is read from the backing" means: it removes the *second
copy* of the type, not the descriptor. A native or typed-row adapter necessarily keeps a description of
external data, and its agreement with subsequent reads is the adapter's contract (`describe` and `lift` agree,
§7.3), enforced by construction and by the read-time failure above.

The v1 lifetime rule is the one every backing that exists today already satisfies, and nothing more:

> **Every v1 `DataValue` is self-contained or held by ordinary strong references, and remains readable for as
> long as it is reachable — after the producing cursor has advanced or closed, after the producing child
> settled, and after the run itself settled.**

A copied flat row (`FileDataCursor` prototypes every row it emits), a strongly referenced native object, a
literal and the fake typed row all meet it, because none of them is backed by anything that can be reclaimed
while a reference remains. That is why the rule is reachability and not "until the run settles": a hosted
child's result is read by its parent *after* the child frame settled (`RunEngine.host` runs the child to
settlement before returning `Outcome.Success.value`), and a root result exists precisely to be inspected after
terminal settlement, so any run-scoped phrasing expires values before their consumer receives them. Job
batching, queueing, live-edit migration (which carries physical batches and adopts a detached cursor exactly
once), Script replay (`ScriptReplayState` retains step results) and hosted results are all ordinary reachability
under this rule; none needs a special case.

What v1 deliberately does not have is a public retention vocabulary. An earlier draft declared
`DataRetention.Detached | Owned` per root with `isAlive` on every accessor; that promised more than the API
could enforce — no owner or scope identity, no transfer, detach, retain or release operation, no at-most-once
guarantee, nothing that says who expires a value — while no v1 backing could actually expire one. Principle 11
stays as the constraint: the first source that measurably cannot meet the reachability rule — a JDBC
`ResultSet` whose rows are reused, a parser slot pool — either copies before emission or introduces the
borrowed / retainable states, `retain()` leases and a separate synchronous traversal API *from measurement*,
together with the ownership-transfer protocol they need across hosted results, batching and migration (§13.19).
Until then no API implies that a `DataValue` can go stale while something still holds it.

Lifetime is also not mutation authority. A reachable value may be aliased through a trace snapshot, a branch or
a second consumer, so "the Worker owns this message" does not by itself make in-place append safe.
Calculated-column append (§11.4) is the publication rule's builder case: legal only for an **unpublished**
value — one the appending Worker received on its own lane and has not yet handed to any other consumer or
trace — and that exclusivity is a stated precondition of the append path, not an inference from ownership.

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
- acyclic Kotlin data classes and Java records lift as structural records with the class as native facet;
- a type with an exact registered adapter uses that adapter, *before* the built-in baselines — so a domain
  owner can override automatic data-class expansion (§7.3); and
- any other object — including a graph-created object in v1 (§8) — lifts as `Opaque` and retains native access
  only.

Structural expansion of a data class stops at recursion. `DataType` is an eagerly recursive tree, so
`data class Node(val value: String, val next: Node?)`, mutually recursive classes and named recursive Avro /
protobuf declarations cannot expand to a finite structural type; lazy *access* handles cyclic values, but the
type must be built first. The rule is that the JVM `KType → DataContract` mapping expands a class once per path
and, on meeting a class already open on that path, emits `Opaque` with that class as native facet at the
recursive position. The value is still fully readable — natively past the cut, structurally above it — and a
snapshot of it is rejected by cycle detection as §12 states. A named-type / reference system for recursive
schemas is deferred with the first carried-schema format that declares one (§13.21).

`Iterable`, `Sequence`, `Iterator` and `Set` are **not** lifted automatically. An arbitrary iterable may be lazy,
infinite, one-shot, blocking or unable to answer `size` without consuming itself, and a set promises no stable
positional order; silently treating either as a `Listing` changes its meaning. Stream-valued results keep their
existing explicit streaming boundary (the `isStreamType` dispatch that `FormulaSourceWorker` and ForEach use), and
a set needs a registered adapter that states its ordering.

The expected type participates in inference without changing the adapter owner:

- null with a nullable expected type uses that type and `DataState.Null`; null without one uses nullable
  `Dynamic`; null against a non-null type fails;
- an empty collection uses the expected element/key/value type when one exists, and otherwise
  `Listing(Dynamic)` / `Mapping(Dynamic(nullable = false), Dynamic)` — an honestly unknown element type, which
  is what `Dynamic` means, with the key position non-null as §4.3 requires;
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
    fun describe(native: KType): DataContract?
    fun lift(value: Any, expected: DataContract?): DataValue
}

interface DataAdapterRegistry {
    fun describe(native: KType): DataContract
    fun lift(value: Any?, expected: DataContract? = null): DataValue
}
```

An adapter has a static half and a runtime half. `describe` contributes the structural contract a native type
will have *without a value* — it is what lets a Formula whose inferred `KType` is `Money` type its lane as the
record the adapter will produce, rather than as `Opaque(Money)` that static analysis would reject before the
runtime adapter ever ran. `lift` is the runtime half and must honour what `describe` promised. An adapter whose
structure genuinely depends on the instance returns null from `describe`, and its lane stays `Opaque`.

A registry is built from two inspectable lists: **exact native-class registrations** — keyed on the JVM by
actual class identity, not by name, because the same fully-qualified name loaded by two plugin classloaders is
two types; `ClassName` is the diagnostic rendering of that key, and a duplicate class is a construction-time error
naming both adapters — and an **explicitly ordered list of capability fallbacks**, each a predicate over the
runtime class plus an adapter. Precedence is fixed: exact class registration first, then the built-in primitive,
collection, data-class and Java-record baselines, then the capability fallbacks in declaration order. There is
no "assignability distance": multiple-interface inheritance has no single correct distance,
JVM generics are erased, and a `match(value)` callback cannot be audited for collisions at registry construction.
`Any` appears here deliberately as the native-to-data interop edge; null is handled by the registry before
adapter selection. `expected` validates or selects a projection offered by the winning adapter, and against an
expected union it is what makes the adapter construct the tagged root (§4.5); it never changes which adapter
owns the native value.

Built-in literal, collection, data-class and Java-record integrations participate through the same registry
contract, although a platform implementation may inline their hot paths. `DataAdapterId` is a non-empty
stable identifier used in diagnostics; it is not a concrete-class dispatch key exposed to consumers.

### 7.4 Cycles and identity

Native and graph objects may be cyclic. Lifting therefore does not recursively materialize them. A view retains
identity and resolves fields on demand. Snapshot conversion detects revisited identities and fails under the v1
policy (§12); a reference marker is a deferred wire extension.

## 8. Graph-managed object interaction

"Graph-managed" here means an object instantiated through kzen's Notation → Definition → Instance pipeline. It
does not mean a database graph, and it does not make every object in `GraphInstance` globally available as data.

The interaction occurs only when a graph-created object is explicitly passed or returned across a data boundary.
What crosses is `ObjectInstance.reference` — the actual Kotlin object, typed `Any`. Once it has crossed, a
class-based adapter cannot tell that it was graph-created rather than constructed normally, cannot recover its
`ObjectDefinition`, `constructorAttributes`, location or stable-mapper context, and — if the class happens to be
a data class — the data-class baseline lifts it first. Graph-aware behaviour therefore needs a provenance seam
that does not exist yet: an identity registry that maps a live reference back to its graph instance, or an
explicit graph-value wrapper handed across the boundary instead of the bare reference. That is a distinct design
problem, owned by the graph consumer that first needs it.

The v1 position follows from the missing seam:

1. **Ordinary baseline only.** A graph-created object lifts exactly as a normally constructed one: a data class
   is a structural record with its class as native facet and may be snapshotted like any other data class; any
   other class is `Opaque` with its class, and its snapshot is rejected like any other opaque value (§12.1).
   Kotlin code requesting the declared class receives the original reference, with no copy. A graph-created
   data class whose constructor holds a service or other infrastructure value exposes that property as an
   `Opaque` field, which the snapshot policy rejects — so automatic expansion cannot leak a service through the
   wire, and the later exposure policy (§8.1) only ever narrows what is exposed. This is the whole of v1, and it
   is truthful: nothing promises graph identity that the value cannot carry.
2. **Stable-reference lowering and the structural view** are deferred together with the provenance seam. When
   the seam exists, the adapter has both the reference and the definition, and the exposure policy below
   applies.

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
a concrete processor needs it, and stable-reference lowering arrives with the provenance seam; a v1 snapshot of
a non-data-class graph object fails.

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

sealed interface DataPresence {
    data object Required: DataPresence
    data object Optional: DataPresence
    data class Defaulted(val default: DataDefault): DataPresence
}

data class DataDefault(
    val literal: ExecutionValue
)

data class BindingDefinition(
    val name: BindingName,
    val contract: DataContract,
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

`BindingName` is a non-empty canonical string unique within the schema. `DataPresence` lives here, on the
binding, and not on `DataField`: a record field is required or optional (§4.3), while a binding may additionally
be `Defaulted`, because defaulting is a construction policy of the boundary that binds the value, not a property
of the value's type (§4.2). Omission and nullability nevertheless keep one meaning throughout the model.
`LogicSignature` becomes a pair of `BindingSchema`s and is a pure declaration — it holds no `Unbound` runtime
states and is not re-created per execution.

`DataBindings` has validated factories rather than a public constructor. A factory takes a schema and supplied
name/value pairs, rejects duplicate supplied names, rejects unknown supplied names, checks each value against its
declaration, applies literal defaults, and aligns states by schema index. The check is **shallow by design**:
`isAssignable(declared, value.contract, requirement)` — native where the declaration carries a native facet,
structural otherwise — plus the root's `DataState` and the binding's presence. It does not walk the value. A
recursive walk at every Flow / Job / Logic handoff would consume large collections, touch live rows, revisit
cycles, repeat work the decoder or adapter already did, and make every boundary linear in the value's size — and
it would still not protect against a mutable native object changing after the walk. Values are instead valid by
construction against their own advertised contract: readers enforce decode policy while reading, adapters
guarantee the contracts they publish (`describe` and `lift` agree), and the deep `validate` of §4.7 is an explicit
request by a consumer that needs it or by a boundary that receives an untrusted backing.

A builder form exists for incrementally produced outputs, because `JobControl.yieldResult` publishes result
components during a run rather than all at once. It preserves `JobResultCollector`'s concurrency and overwrite
semantics: yields are synchronized because Workers yield concurrently from their own engine nodes, and a
repeated produced name is **last-write-wins**, because carried sinks re-yield at their `onComplete` after a
migrate rebuilds the collector empty. It does *not* preserve the collector's first-yield component order: a
completed `DataBindings` is aligned to its schema and enumerates in schema order, and there cannot be a second
authority for the same order. Yield chronology, where anyone wants it, is trace metadata of the builder, not
binding identity. "Reject duplicate supplied names" is a rule about *supplied* inputs at construction and says
nothing about repeated *produced* components. The builder validates each component shallowly as it is set and
the completed set — every required output produced — at settle. That last check is new behaviour and exposes
existing signature defects: Report declares `main: String` (`ReportLogicCompiler` builds
`TupleDefinition.ofMain(LogicType.string)`) while `ReportRun.run()` returns `TupleValue.empty`. Every input and
output signature is inventoried and reconciled *before* strict construction is enabled (§14.5); what Report's
result should be — a status, a row count, a run-directory reference, or no declared component — is a product
decision (§17), not something the binding layer guesses. The type names here are working names: whether the
implementation introduces `BindingSchema` / `DataBindings` as new classes or evolves `TupleDefinition` /
`TupleValue` in place to these semantics is decided at the implementation spike — in-place evolution is the
default preference, because IDE-driven refactoring carries every call site — and neither choice changes the
construction rules, which are the contract.

### 10.1 Behaviour

- Enumeration follows schema order and is safe for UI/diagnostics without materializing values.
- Lookup returns a binding state, not `Any?`.
- A bound null is a `Bound` value whose root state is `Null`; it is not `Unbound`. A `Bound` value whose root is
  `Absent` is a construction error.
- Defaults are applied once by binding construction and record `Defaulted` origin.
- Unknown supplied names and duplicates fail at the boundary that creates the set.
- Contract acceptance (shallow: assignability, root state, presence) is checked when a value is bound, not
  deferred until a consumer casts it; deep validation is explicit.
- Sensitive bindings expose names, types, states and origins but redact previews. Sensitivity is **display
  policy for exactly one binding**, not data taint: it says how that binding is previewed and snapshotted, and
  nothing about the value once it is passed to a step, emitted on an edge, returned under another output or
  rebound under a non-sensitive name. Callers must not infer leak prevention from it. Propagation with
  declassification rules is a security model of its own and is deferred; so is nested field sensitivity, which
  needs an explicit schema policy and path-aware tests before it is promised.

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

- a value whose contract carries a native facet of the requested class is passed as the original object;
- a structural backing is read through generated accessors derived from `DataType`; and
- a step result is automatically lifted when recorded or handed to another step, with `expected` from the step's
  declared result type or the compiler-inferred `KType`.

A step result recorded for replay (`ScriptReplayState`) is covered by the reachability rule (§6.2). Generated
native locals inside a step are a typed authoring API and are not wrapped merely to satisfy architectural
symmetry; the cutover applies where generic data actually crosses a step boundary — the recorded result and the
handoff to another step — and the engine may carry a `DataValue` underneath while the step body sees `T`.

### 11.3 Flow

Flow ports declare a `DataContract`; the runtime carries `DataValue` (or engine batches of it) on the edge. Port
connection validation uses `isAssignable`; runtime delivery does not erase the element to an unrelated `Any?`.
`RequiredInput<T>` stays, in two honest forms. A **native typed port** — `RequiredInput<Reading>` — requires a
contract whose native facet is assignable to `T` under `DataRequirement.Native`, and the vertex receives the
original object. A **structural port** — `RequiredInput<DataValue>`, or a stable framework view such as a
`RecordView` interface — accepts by structural assignability and reads through the value. A precompiled vertex
cannot name an accessor class generated from a schema it never saw, so there is no third form in which a
structural value arrives as a synthetic `T`; generated typed façades over structural values belong to the
expression compiler (Formula and Script bodies, §11.2), which compiles against the lane's contract, and are not
a promise every Flow SPI can make. `FlowVertex.inspectMessage` stops being a per-vertex hand-written renderer for data-carrying
messages: the runner snapshots a `DataValue` message through the bounded policy of §12, and the vertex override
remains for non-data state. The unification target is the *generic* boundary — port, channel, step result,
Logic binding — not every internal variable and transport (§13.22).

### 11.4 Job

Job channels carry one `DataValue` per domain element. Batching remains a channel transport concern and keeps its
existing ownership/cadence behaviour; the ownership-transfer rule remains useful.

`JobMessage(payload, flat)` and `WorkerLane(payloadType, flatColumns)` cease to be the target design. A Worker
receives one value and one `DataContract`. That is only true if every Worker produces one value, and today one
does not: `FormulaWorker.onElement` runs two independent transforms against the *received* message — `formula`
entries append columns to the flat part while the `payload` expression replaces the payload — so a message can
leave with columns derived from a `Reading` and a payload that is an `Alert`, two unrelated results that
`JobMessage.boundaryValue()`'s hidden "payload wins" rule later arbitrates. The model does not carry that
combination as two results; it expresses it as one. **A Worker produces one value, by widening the element or
by replacing it**: calculated columns produce a wider record whose native facet is still the original object
(the `Reading` is not gone — native consumers receive it, structural consumers see its fields plus the new
column); a payload transform produces a new value whose columns project from the new object, plus whatever the
transform explicitly carries from the received value (next paragraph). A pipeline may also write the two as
separate Workers, and the order — which the single Worker had to fix by convention (formulas see the original
payload) — is then explicit.

What a replace does is stated exactly: **a replace starts a fresh value and carries forward exactly the
columns it is told to carry — nothing implicitly, nothing impossibly.** A widened value is already "a flat
record of fields plus a native facet" (below), and nothing requires every field to come *from* the native
object — a calculated column does not. So the payload transform takes a `carry` option, named columns or all,
applied after the replace: the new value's projection is materialized once and the carried columns are
appended to it from the received value, giving `{Alert's fields + normalized, native = Alert}`. A native
consumer receives the `Alert`; a structural consumer sees every field; a snapshot takes the record; and the
contract lists the carried fields explicitly instead of a second carrier implying them. That is the old
combined `FormulaWorker` result, expressed as one value with one type — and it is why the carrier's defect was
never the *existence* of two useful results but their implicit interpretation. Without `carry`, a replace
drops the previous widening; with `carry` it keeps what it names; a custom Kotlin Worker holding the
`DataValue` can build any output through the unpublished builder, the same route a plugin reader uses to emit
values, so anything a projection can read can be carried. A union is not the mechanism — a union node holds
one active variant, never both. Every affected Job migrates explicitly when the carrier is replaced (§14.5),
and the precedence rule disappears with the second carrier (§13.23).

Column-oriented Workers request a **`ColumnProjection`**, a
kzen-auto-owned capability over `DataValue` (there is no generic `project` in kzen-lib — §4.7):

- records expose their ordered fields;
- scalars may project to an explicit synthetic `value` field;
- mappings require a declared or observed key projection;
- duplicate labels render through `HeaderLabel.render()`; and
- opaque values require a structural adapter or fail with a useful capability error.

Three existing behaviours are preserved by construction rather than by a second carrier:

- **Undeclared delimited fields are `Scalar(Text)` read through `ColumnValue`** (project-data ST1, settled). Its
  coercion semantics — `"13.0" == 13` — are product behaviour, and its interned constants are a real allocation
  optimization. A declared non-text field bypasses it with a typed primitive read. No existing expression changes
  meaning.
- **`<missing>` becomes a projection policy, not data.** Superset normalization (`schemaMode: superset`) today
  materializes the `DataShape.missingCellValue` sentinel into absent cells. Under this model a superset field is
  optional, an absent cell is `DataState.Absent`, and the `ColumnProjection` used by column Workers renders
  `<missing>` as its display of absence — so `Summary` and the writers keep their output while a typed consumer
  sees absence honestly.
- **Calculated columns materialize once, then append.** A Worker that received an *unpublished* message — one
  no other consumer or trace has been handed (§6.2) — may append fields to an appendable backing (the flat
  record) before publishing one new `DataValue` whose `Record` type is wider — exactly today's `FormulaWorker`
  mechanics, legal because the mutation precedes publication and happens through the backing's own builder
  surface, not through `ValueAccess`. Where the input backing cannot be appended — a native object, a typed
  row — the *first* column-adding Worker materializes the value's column projection once into an owned flat
  record and keeps the original object beside it as the native facet; every later column-adding Worker appends
  to that record. The shape after N calculated columns is therefore always "one flat record of the projected
  fields plus N added, native facet intact", with lookup cost independent of N and no nested `Composed`
  overlays (§6.1). The one-time projection is the same work today's auto-flatten does; what it gives up is
  laziness over unread fields of the original object, which a column-mutating pipeline does not need. The
  benchmark gate includes many sequential calculated columns on both a flat and a native lane.

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
bindings. Every emitted value is self-contained or strongly held and stays readable while reachable (§6.2); the
first opener that cannot honour that from measurement copies before emission or introduces leases.

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
    data object Redacted: SnapshotResult
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

All numeric limits are strictly positive and `maximumElements` is cumulative across the snapshot.
`maximumDurationMillis` is checked between node reads and is therefore best-effort: the synchronous
`ValueAccess` API cannot preempt one native getter, row accessor or adapter call that blocks past the limit, and
the policy does not pretend to. A hard bound needs snapshotting to run under an interruptible execution
boundary, which is a caller's choice, not a property of the policy. The v1 policy is strict, and it promises only
what the existing grammar can express:

- **The envelope carries the structural `DataType`, never a native facet.** A decoded tree cannot reproduce the
  original `Reading` instance, so a snapshot of a native-backed record is a record and nothing more; a consumer
  that needs the native object holds the live value, not the snapshot.
- exceeding any bound rejects; a cycle or revisited identity rejects;
- an opaque node — a non-data-class graph object, or a service held by a data-class property (§8) — rejects
  rather than falling back to `toString()` or inventing a reference; a surrogate contract for opaque lowering
  arrives with the wire grammar;
- the grammar has no redaction marker, so a sensitive binding under `Redact` yields `SnapshotResult.Redacted`
  at whole-binding scope — a *result*, not a text value that could collide with real data or violate a non-text
  type — and `Reject` refuses the binding; a marker inside the tree is a §12.2 item.

No partial tree masquerades as complete data.

Within the existing grammar the lowering is mechanical: records and text-keyed mappings lower to `map`; other
mappings lower to a `list` of `{key, value}` maps; a union lowers to `{variant, value}`; exact integers, decimals,
temporal values and UUIDs lower to canonical `text` interpreted under the envelope's `type`; binary lowers to
`binary` or, where the calling protocol supplies a blob endpoint, `binary-handle`. `DataDefault` and other
permanently self-contained locations reject `binary-handle` recursively. A record with duplicate `FieldId`s
**rejects** in v1: the only in-grammar alternative is rendering keys through `HeaderLabel.render()`, which would
make a temporary wire encoding depend on a display rule and need envelope-aware inverse mapping, and nothing in
the vertical proof needs the round-trip — the Logic boundary now passes the `DataValue` itself, not a rendered
map, so `boundaryValue()`'s rendering has no successor. Runtime flat access supports duplicate occurrences
regardless; the ordered-entries record encoding that snapshots them is a §12.2 grammar item. The decode-side
invariant is the same for every consumer of the tree: because a text leaf may be text, an integer, a decimal, a
temporal value or a UUID and a map may be a record or a text-keyed mapping, **every API that accepts a
`DataDefault.literal` or a `DataSnapshot.value` takes its `DataType` with it**, and no generic `ExecutionValue`
path reconstructs semantic data without one. Every problem a snapshot reports addresses its node through
`DataPathSegment` (§4.7), and cycle and revisit detection uses the identity rule of §6.

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
identity (ordered entries, no rendered-label escape), an active-variant tag, a stable identity reference for
repeated or cyclic objects, an opaque-surrogate contract, a redaction marker, a truncation marker with its
diagnostic, and a resolver-scoped blob reference generalizing today's `run` / `hash` handle. `WireValue` is the intended name because the value is canonical boundary data even when temporarily held
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

### 13.6 A top-level `DataDescriptor(structural, native)` pair, or `native` as a field of `DataType`

A root-only descriptor correctly separates the two facets but records the native type only at the root.
Generated code reading a nested data-class field needs that field's native type too, and a listing of data
classes needs its element's. The first revision therefore made `native` a field of every `DataType` node — but
that put a backing capability inside structural identity: two records with identical fields became different
lane types because one was data-class-backed, a snapshot preserved an annotation it could not honour, and a
`TypeMetadata` annotation duplicated nullability and generics that the tree already held. The recursive
`DataContract(structural, native: TypeMetadata?)` wrapper keeps the nested information, keeps `DataType` a plain
structural data class with structural equality, and holds the native facet exactly once per position (§4.1).
`Opaque` is then a structural case whose contract must carry a class.

Two later revisions narrowed the facet and were reverted. A bare `ClassName` facet lost nominal generics
(`Box<String>` versus `Box<Int>` over an opaque `Box`) and native variance, and resolving names in the
consumer's loader erased the producer's identity; the facet is `TypeMetadata` again, with agreement between the
two halves enforced at construction rather than by discipline (§4.1). A purely structural contract with a
JVM-local `NativeTypeToken` sidecar was also proposed; the token is adopted for *identity* — every in-process
declaration keeps its `KType` and loader beside the common facet — but the sidecar does not replace the
recursive facet, because nested positions still need their native type and a separate sidecar would have to be
threaded through every position to reach information the wrapper already holds.

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
recompiles — and it would put a mirrored or adapted contract between third-party readers and the value model.
The dependency is taken instead (§6.1, §14.3). The one technical point in favour of the external adapter — that
a bare record holds no header and so cannot answer `contract(root)` — is met by the record carrying a reference
to its shared header (§6.1), with defined behaviour under the record's buffer operations. The allocation
argument is left to measurement: a `FlatRecordAccess(header, record)` wrapper may be allocation-neutral against
today's per-row `JobMessage` + `FlatView`, so both forms are benchmarked before the direct form is exposed from
the plugin (§15). Two reviews raised the kzen-auto guide's "public, stable SPI" wording against this decision;
that wording predates the decision and is superseded by it — the guide is updated when the dependency lands
(§14.3) rather than the model bending to a contract nobody consumes.

### 13.19 A public `Detached | Owned` retention state in v1

Declaring retention per root with `isAlive` on every accessor described a lifecycle the API could not enforce
and no v1 backing could exercise: no owner identity, no transfer or release operation, nothing that expires a
value. A "readable until the run settles" rule was the next draft and was also wrong, because hosted-child and
root results are read *after* settlement. The reachability rule (§6.2) is what today's backings actually
provide. Retention states, leases and the transfer protocol are designed by the first source that needs them,
from measured cursor behaviour.

### 13.20 A generic `project(value, target: DataType)` in the common algebra

Job's column Workers are the only consumer of reshaping, and their rules — field order, synthetic `value`,
mapping-key policy, duplicate-label rendering, `<missing>` for absent optional fields — are product behaviour
of that consumer. A kzen-lib projection algebra capable of arbitrary reshaping would be designed against one
example. `ColumnProjection` stays in kzen-auto (§11.4) until a second consumer shows shared semantics.

### 13.21 Named recursive types in v1

A named-type / reference system would let `Node(next: Node?)` and recursive Avro / protobuf declarations expand
structurally. It is a schema-language feature with its own identity, digest and wire rules, and no v1 consumer
declares a recursive schema. Expansion stops at the recursive position with `Opaque` (§7.2); the reference system
lands with the first carried-schema format that needs it.

### 13.22 Cut every internal Script / Flow transport over to `DataValue`

Architectural symmetry would have generated step locals and `RequiredInput<T>` expose `DataValue`. Those are
typed authoring APIs, and forcing the wrapper on them costs ergonomics without removing a competing semantic
model — the engine can carry or lift a `DataValue` underneath and hand the vertex or step its `T`. The cutover
applies to generic boundaries: Job channels, Logic bindings, recorded step results and port delivery (§11.2,
§11.3).

### 13.23 A `JobElement(payload, columns)` product, or a `Composed` overlay chain

Keeping two slots per Job element would preserve `FormulaWorker`'s ability to replace the payload and append
columns in one step, at the price of keeping the "which slot does this boundary mean" rule at every sink, host
and snapshot — the precedence rule the model exists to remove — and of a second carrier every Worker must keep
consistent. Stacking `Composed` overlays per calculated column would keep laziness over the original object at
the price of lookup cost growing with each Worker and a collapse-threshold policy to bound it. Both are declined
for the simpler rule of §11.4: one Worker widens or replaces, the first widening over a non-appendable backing
materializes once, and the native facet keeps the original object reachable. Nothing is given up: a replace
with `carry` produces previous-value columns beside a new native object as *one* value whose record type lists
those columns explicitly (§11.4). That is not the `JobMessage` defect under another name — the defect was a
second carrier whose relationship to the first was implicit and arbitrated by `boundaryValue()`; a carried
column is a declared field of the one contract, no different from a calculated one.

### 13.24 Unify semantics only, and leave every carrier specialized

The fourth review proposed sharing `DataType`, `DataShape`, field identity, compatibility and the binding
states while leaving each transport as it is — Script locals and native Flow ports as Kotlin values, Job owning
a typed `JobElement` with explicit projections, readers emitting structural values through the backing
interface for the processors that opt in. Most of that is already this proposal: locals and native ports stay
typed (§11.2, §11.3, §13.22), the cutover applies only where generic data crosses, and Job and the readers are
the consumers that drive the value contract. The remaining difference is the Job product, which is §13.23. The
review's request that the universal carrier win a prototype comparison rather than be assumed is met by the
sequencing itself: steps 3 and 4 of §14.5 are that prototype, on the one path (typed flat rows and Job) where a
structural consumer exists today, and the first gate (§15) is scoped to it.

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
anywhere else. JVM reflection, native and row backings, the `KType → DataContract` mapping and the native
assignability resolver live in `kzen-lib-common`'s `jvmMain` or in consumer modules while implementing the
common contract; `FlatFileRecord` implements it in `kzen-auto-plugin` (§6.1); `ColumnProjection` is kzen-auto's.

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
— the code is in development and `kzen-sample-plugin` recompiles. The kzen-auto guide's description of the
artifact as a "public, stable contract" is superseded by this decision and is rewritten to "in-development SPI,
versioned with the release train" when the dependency lands, so later reviewers do not re-litigate it.
Publication order follows: kzen-lib before `kzen-auto-plugin` before the rest of kzen-auto, at the existing
coordinated version.

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

1. **Settle the type and its algebra** — `DataContract` over a structural `DataType`, `FieldId`, optionality,
   tagged unions in the type language, `isAssignable` (both equalities, union-to-union) / `validate` /
   conservative `join` / `selectVariant` with representative-pair and wire/digest tests, the JVM
   `KType → DataContract` mapping with its recursion rule, the lossy `TypeMetadata` mapping, and the native
   resolver seam on the declaration-plus-token model.
2. **Move `DataShape` to the observation envelope.** Replace `Tabular | Payload`, make `DataSchemaDocument.shape()`
   stop discarding types, and update the client decoders. Declared and inspected sources use the same vocabulary.
3. **Prove the value over three backings.** `kzen-auto-plugin` takes its kzen-lib dependency and
   `FlatFileRecord` implements `ValueAccess` with its header reference, benchmarked against a
   `FlatRecordAccess(header, record)` wrapper; the same record is read from it, a Kotlin data class and a fake
   typed row; a data-class instance retains its native class and exposes fields without copying; no per-field
   `DataValue` allocation on the flat path; every value readable while reachable, including a hosted child's
   result after the child settled.
4. **Replace the Job carrier.** One `DataValue` crosses the lane; `WorkerLane` becomes a lane `DataContract`;
   `FormulaWorker` splits into widen-or-replace (§11.4); column Workers request `ColumnProjection`; `<missing>`
   moves to the projection; owned-append under the unpublished-value rule and materialize-once over a native
   lane are benchmarked against the current path and under many sequential calculated columns.
5. **Land `BindingSchema` and `DataBindings`.** First inventory every Logic signature against what its run
   actually binds and produces (Report's `main: String` versus `TupleValue.empty` is the known case) and resolve
   each discrepancy; then replace `TupleDefinition` / `TupleValue` in `LogicSignature`, `Execution`,
   `JobControl` and `DataContext`, with shallow bind-time checks, the result builder's preserved
   last-write-wins semantics, and the omission-semantics migration of §10.1.
6. **Cut Script and Flow over where generic data actually crosses** — step results and ports — with the replay
   lifetime rule and snapshot-based message inspection.
7. **Add the first structured reader.** Its requirements decide the structural tape and the `Dynamic` runtime
   behaviour; ST11, ST17 and ST20 policies gate it. External-tag union decoding from a carried schema lands
   here; the untagged selection path is already proven in step 3.
8. **Add the first real durable-row source.** Its measured cursor behaviour decides whether retention states,
   leases and a transfer protocol are necessary; it also brings `LocalDateTime`, `Decimal` precision/scale and
   the constraint / representation-metadata container.
9. **Design the richer wire grammar separately** (§12.2), and **graph provenance, stable-reference lowering and
   structural exposure separately** (§8), each with the consumer that forces it.

This ordering is evidence for feasibility, not an approved execution plan. Exact package layout and rollout work
belong in a constituent plan only after this analysis is accepted. No version bump follows automatically (CC-14);
cross-repository publication order is kzen-lib before kzen-auto and its consumers, at the existing coordinated
development version.

## 15. Adoption gate

The proposal should not be accepted on API aesthetics alone. The gate is in two tiers. The **foundation gate** is
what the first prototype must prove before any cutover is planned, and it is scoped to the one path where a
generic structural consumer exists today — literal, flat-record and data-class backings under the Job column
path — so that it tests the foundation rather than a multi-repository migration:

1. one typed record is read identically from literal, flat and data-class backings;
2. declared CSV field types are no longer discarded (`DataSchemaDocument.shape()`);
3. calculated fields append without eager row-to-map conversion, and N of them cost one projection plus N
   appends on a native lane;
4. a widen followed by a replace drops the widening without `carry` and keeps the named columns with it, on
   one value whose native facet is the new object;
5. a nested Logic boundary sees missing, null and defaulted distinctly;
6. a data-class native consumer receives the original instance, and a structural consumer reads the same
   instance without copying;
7. direct `FlatFileRecord : ValueAccess` is measured against `FlatRecordAccess(header, record)`; and
8. the representative Job path stays within five percent of its current median throughput and meets the
   allocation pins below.

The **cutover gates** below are proven as each later step of §14.5 lands — bindings with step 5, Script and
Flow with step 6 — not by the first prototype.

### Semantic model

- canonical `ExecutionValue` lowering and digest round-trips for every `DataType` case, with exact integers and
  decimals as canonical text, structural type only in the envelope, duplicate-field records rejected, and every
  decode path shown to require its `DataType`;
- structural equality and digest unchanged by the native facet, declaration equality distinguishing facets and
  generic arguments; representative `isAssignable` pairs under both requirements, including nullability,
  optional fields, record width, numeric promotion, structural collection variance versus native generic
  variance, `Dynamic` direction, expected `Opaque` accepting a richer actual with an assignable facet, and
  `Native` proven to imply structural acceptance; native assignability delegated to the JVM resolver, with a
  same-name class from two loaders rejected token-to-token and a name-only declaration answering
  `Provisional` until its first live value;
- union assignability in all three cases — expected union versus concrete actual, union versus union, concrete
  expected versus actual union — plus duplicate-contract variants, duplicate IDs rejected, root nullability, and
  selection through a tagged actual and `NoMatch` for a `Dynamic` actual;
- `validate` distinguishing compatible-type-but-nonconforming-value cases from type mismatches, with
  `DataPathSegment` paths, and binding a value proven *not* to walk it;
- `join` laws — associative, commutative, idempotent — over records and unions with identical ordered members,
  widening of differing records, differing unions and inferred heterogeneity to `Dynamic`, and superset
  normalization shown to be a `ColumnProjection` operation rather than `join`;
- mapping keys: an empty mapping with a `Dynamic` key, a non-empty one with a concrete kind, null and mixed keys
  staying `Opaque`, and a canonical-text key collision failing the lift;
- canonical `Date`, `Time`, `Instant` and `Duration` values, including rejection of local date-times where an
  `Instant` is required;
- selection of `List<String> | String` from an untagged JSON value and from a native Kotlin value producing a
  union root, external-tag decoding through
  `validateVariant`, native-requirement selection between same-shaped classes, and deterministic rejection of
  overlapping untagged variants paired with the record-width tests;
- stable `FieldId(name, occurrence)` identity within one schema version and duplicate display-label projection;
- the JVM `KType → DataContract` mapping over primitives, collections, data classes, Java records, a registered
  adapter's `describe`, and a recursive data class stopping at `Opaque`; and the lossy `TypeMetadata` mapping.

### Bindings

- schema enumeration and lookup without runtime states; instance validation against one schema;
- unknown and duplicate name failures; required, optional and defaulted inputs;
- a present-null binding distinct from unbound; `Bound` with `Absent` root rejected;
- incremental produced outputs through the builder, with concurrent yields, last-write-wins on a repeated
  produced name, schema-order enumeration regardless of yield order, and a missing required output failing at
  settle — after the signature inventory has reconciled every existing Logic;
- origin and whole-binding redaction behaviour, redaction surfacing as `SnapshotResult.Redacted`; and
- design request handling for zero, one and repeated values after routing parameters are removed.

### Adapters

- primitives, lists, arrays and maps; Kotlin data classes and Java records with native facets;
- `Iterable` / `Sequence` / `Set` refused by the automatic baseline;
- arbitrary opaque objects — a non-data-class graph-created object among them — with native access, no
  accidental reflection, and a rejected snapshot; a graph-created data class behaving exactly as an ordinary
  one, its service-valued property rejecting the snapshot;
- a native list whose element changes class after publication failing that read with `DataAccessException`,
  not coercing; a cyclic native object rejected by identity of its container nodes while two fields sharing one
  interned `String` snapshot as two leaves;
- exact registration overriding the data-class baseline for a registered class, and fallback order
  deterministic;
- exact-class conflict detection at registry construction, keyed by class identity, and deterministic
  capability-fallback order;
- `describe` and `lift` agreeing for a registered adapter, and a Formula lane typed from `describe`; and
- cycles rejected by the snapshot policy without arbitrary `toString()`.

### End-to-end composition

- a Formula returns an ordinary data class without wrapping, typed from its inferred `KType`;
- Script → Flow → Job → nested Logic preserves the value's contract and native identity, with a native typed
  Flow port still receiving `T` and a structural port receiving `DataValue`;
- the same structural consumer reads a flat row, a data class and a fake typed row;
- a tagged union exposes its active ID and selected value and round-trips through a typed snapshot;
- column projection works without a second carrier, and `<missing>` appears only in the projection;
- a calculated column over a native lane widens the record while a downstream native consumer still receives
  the original object; a payload transform followed by a calculated column composes as two Workers; a replace
  with `carry` keeps the named previous columns beside the new native object; and a custom Worker builds an
  arbitrary output from a received `DataValue` through the builder;
- data-source arguments enumerate correctly and hosted results return typed bindings; and
- missing/default/null behaviour is identical across every Logic flavour.

### Lifetime and performance

- every value stays readable while reachable under the actual Job batching, queueing and live-edit migration
  cadence — including batches consumed after the producing cursor closed — through Script replay, and as a
  hosted child's result read after the child settled and a root result read after the run settled;
- cursor advance, close and cancellation leave no unreadable value behind, without any retention API;
- owned-append is exercised only on unpublished values, and an aliased value cannot be appended in place;
- primitive field reads allocate nothing after setup, pinned by a narrow allocation test that names its layer;
- field traversal creates no per-field `DataValue` objects;
- flat input is not eagerly materialized;
- direct `FlatFileRecord : ValueAccess` measured against a `FlatRecordAccess(header, record)` wrapper on the
  representative flat path, the direct form kept only if it wins;
- N sequential calculated columns on a native lane cost one projection plus N appends, with field lookup
  independent of N; and
- the representative Job data path stays within five percent of its current median throughput unless an
  explicitly measured capability justifies the cost.

## 16. Decision index

One line per decision, pointing at the section that owns it; the section is authoritative and this index carries
no content of its own. Rationale and the review trail are in the [history](2026-08-27_data-model_history.md).

- **Scope.** One model for every Logic flavour, execution mechanics flavour-specific (§1, §2.3); v1 is the
  vertical proof of §1.2, extensions wait for a named consumer; owner is `kzen-lib-common` with JVM backings in
  `jvmMain` or consumer modules (§14.1–14.2).
- **Types.** Recursive `DataContract(structural, native: TypeMetadata?)`; two named equalities (§4.1); no
  `Tabular | Payload | Both` (§5); `FieldId(name, occurrence)` stable within one schema version (§4.2);
  required/optional fields, defaults on bindings and reader contracts (§4.2, §4.3, §10); non-empty mappings
  report a concrete key kind, null / mixed / colliding keys stay `Opaque` or fail the lift (§4.3); scalar kinds
  are semantic, `Decimal` unparameterized, no enum kind, `LocalDateTime` with the first database consumer,
  the whole constraint layer deferred (§4.4); tagged unions in v1 with `List<String> | String` as consumer,
  selection by unique acceptance under the caller's requirement, three assignability cases, no inference, no
  discriminator layout (§4.5); `Opaque` requires a native facet and accepts by facet alone, `Dynamic` is
  observation / requirement only (§4.6, §4.7); conservative `join` (§4.7); JVM `KType → DataContract`, lossy
  `TypeMetadata → DataContract`, native resolver with classloader and live token (§4.7).
- **Values.** One read-only `DataValue` over `ValueAccess` backings, contract read from the backing, no per-field
  allocation, failure through `DataAccessException`, identity through `native(node)` on container nodes (§6);
  literal, flat-record, native-object and fake typed-row backings in v1, `FlatFileRecord` direct with a header
  reference and benchmarked against a wrapper (§6.1); frozen after publication, readable while reachable, no
  retention API (§6.2); performance as correctness (§6.3).
- **Adapters.** Automatic baseline for primitives, collections, data classes and Java records, recursion stops
  at `Opaque`, no `Iterable` / `Sequence` / `Set` (§7.2); `describe` beside `lift`, exact registrations first,
  then built-ins, then ordered fallbacks (§7.3).
- **Graph and rows.** Ordinary baseline in v1, provenance seam deferred (§8); read-only row views, explicit
  mutation (§9).
- **Bindings.** `BindingSchema` + validated `DataBindings` in schema order, shallow bind checks, deep `validate`
  explicit, presence and literal defaults, whole-binding display-only sensitivity, builder preserving
  `JobResultCollector`'s concurrency and last-write-wins, omitted inputs legal only under declared presence,
  strict outputs after the signature inventory, naming settled at the spike (§10, §10.1, §10.2).
- **Flavours.** Generic boundaries only; `RequiredInput<T>` in native and structural forms; step locals stay
  typed (§11.2, §11.3, §13.22); one Job element is one value, a Worker widens or replaces (a replace carrying
  named columns forward), materialize once then append, `ColumnProjection` owned by kzen-auto (§11.4, §4.7);
  cursors emit `DataValue` (§11.5).
- **Wire.** `ExecutionValue` behind a `DataSnapshot` envelope with the structural type only; complete, redacted
  or rejected; opaque, cyclic and duplicate-field values reject; duration best-effort; richer grammar deferred
  (§12).
- **Sequencing and gate.** Vertical cutovers with temporary bridges (§14.5); foundation gate first, cutover
  gates later (§15).

## 17. Questions that remain legitimately open

Before an execution plan is approved, the following need prototypes or explicit decisions:

1. **Graph provenance seam.** Identity registry or explicit graph-value wrapper at the boundary; and, for the
   later structural view, which existing metadata can reliably distinguish authored data from injected
   constructor infrastructure. Needed for stable-reference lowering and structural exposure, not for v1.
2. **Node-handle layout.** The token encoding and accessor split that support flat, native and row backings
   without allocation, and how a backing built outside kzen-lib mints tokens safely.
3. **Constraint-layer and representation-metadata container.** Which provider-specific details (enum symbols,
   precision/scale, temporal precision, numeric IDs, affinities) live beside `DataContract` for validation,
   migrations and structured writers, and in what container. Deferred with the layer; not needed for v1.
4. **Tabular projection policy.** Exact duplicate-label, nested-field and mapping-key rules for
   `ColumnProjection`, and where the `<missing>` rendering is configured.
5. **Append builder surface.** How `FlatFileRecord` exposes append to its owner as an unpublished-value builder
   without exposing it through `ValueAccess`, and how the materialize-once record over a native lane holds its
   native facet.
6. **Enum reopening condition.** Whether the first carried-schema format needs enum identity in `join` or only
   in value validation.
7. **Native resolver in the composite.** Whether the JVM native-assignability resolver reuses
   `TypeAssignability`'s compiler probe as-is (which lives in kzen-auto) or a class-identity implementation moves
   down to kzen-lib's `jvmMain` so kzen-lib does not depend upward.
8. **Report's declared result.** What `main` should be once outputs are validated at settle — status, row
   count, run-directory reference, or no declared component. A product decision, needed before step 5 of §14.5.

Those are reasons to review and prototype the proposal before implementation. They are not reasons to retain the
current opaque and duplicated boundaries.

