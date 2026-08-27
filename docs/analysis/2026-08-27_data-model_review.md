# Unified data model — design review

> **Status: review of the proposal, not an implementation contract.** This document reviews
> [the unified data-model proposal](2026-08-27_data-model.md). It supports the proposal's central direction but
> recommends revising the model before it becomes an execution plan. No recommendation here authorizes code
> changes or alters plan status.

## 1. Verdict

The proposal identifies the right defect: kzen should not preserve parallel payload/flat carriers, opaque
`Any?` boundaries, or separate Script, Flow and Job definitions of ordinary data.

Its replacement is not yet the simplest complete model. It combines several separately decidable systems:

- typed Logic bindings;
- a semantic structural type language;
- live values over multiple physical backings;
- native Kotlin projection;
- row/cursor ownership and retention;
- graph-object traversal;
- adapter discovery;
- a richer detached wire grammar; and
- bounded graph-aware snapshotting.

Some of those systems are required. Several others are speculative, and a few of the proposed contracts cannot
currently express the behaviour their prose promises.

The central correction is:

> One value may offer more than one orthogonal projection. The target is one authoritative carrier with explicit
> capabilities, not one carrier forced to have exactly one mutually exclusive type.

A Kotlin data class can simultaneously be a native `Reading` and a structural record. A graph-created object
can simultaneously retain its native class and expose a policy-limited record. A typed database row can expose a
record without promising any useful native class. Those are real, independently useful views of one value, not
the defective `payload + flat` duplication in today's `JobMessage`.

The proposal should be revised around that distinction, then narrowed to a vertical proof using the first real
backings before the lifetime, graph-navigation and wire extensions are frozen.

## 2. Findings worth retaining

The following conclusions are strong and should survive the revision.

1. **One authoritative channel element.** Replace `JobMessage(payload, flat)` and
   `WorkerLane(payloadType, flatColumns)`; do not add `DataShape.Both`.
2. **Semantic containers remain distinct.** Record, mapping and listing have different contracts and should not
   collapse to `Map<String, Any?>`.
3. **Nullability and presence are orthogonal.** Missing, present-null and present-value must remain distinct.
4. **Shape is an observation.** `DataShape` should contain an observed semantic item type plus provenance,
   stability and diagnostics, not classify the current carrier as tabular or payload.
5. **The generic value contract is read-only.** Native, notation and durable-store mutation remain owned by their
   respective systems.
6. **Snapshots are explicit.** Wire, trace, retention and cross-process operations must not accidentally turn a
   live cursor/native/graph view into supposedly durable data.
7. **Backings remain physically specialized.** Flat rows, native objects, structural tapes and typed rows may
   share access semantics without sharing storage.
8. **Performance is an acceptance condition.** Flat rows must not become maps, primitive reads must preserve
   their fast path, and allocation claims must be benchmarked.
9. **Generic dispatch is capability-based.** New adapters and backings must not require generic code to name
   application classes.
10. **`kzen-lib-common` is the natural vocabulary owner**, provided the plugin SPI dependency consequence is
    resolved explicitly.

## 3. Blocking objections

### 3.1 One `DataType` cannot represent native and structural views simultaneously

The proposal defines `Nominal` and `Record` as alternatives in one sealed type, while later promising that a
data class or graph-created object can be consumed through both views.

Consider:

```kotlin
data class Reading(
    val sensor: String,
    val value: Double
)
```

The same value has two independently required contracts:

- generated Kotlin needs its nominal `Reading` type to call native members; and
- generic Filter, Sort, table and writer code needs a structural record with `sensor` and `value` fields.

If `DataValue.type` is `Nominal(Reading)`, the proposed `field` operation is invalid. If it is `Record`, the
native programming type is absent from the descriptor. `ValueAccess.native(node): Any` may recover the object at
runtime, but it cannot tell the expression compiler which static Kotlin type to generate.

The same contradiction recurs for graph-managed objects and nested native collections. It is not resolved by
adapter selection: the selected adapter may know both views, but the returned `DataValue` has nowhere to record
both.

The model should use a product:

```kotlin
data class DataDescriptor(
    val structural: DataType,
    val native: TypeMetadata? = null
)
```

Representative descriptors are:

| Value | Structural projection | Native projection |
|---|---|---|
| CSV row | `Record` | none promised |
| Kotlin `Reading` | `Record` | `Reading` |
| Arbitrary opaque Kotlin object | `Opaque` | declared Kotlin type |
| Typed database row | `Record` | optional provider-owned row type |
| Graph-created data object | exposure-policy `Record` | created Kotlin class |

`DataType.Nominal` can then either disappear in favour of a structural `Opaque` leaf, or be narrowed to a
genuinely semantic nominal identity. A JVM class name alone should not be asked to serve both semantic identity
and native compiler typing.

Compatibility must also be projection-specific. A native Script consumer and a structural table consumer do not
ask the same acceptance question merely because both receive a `DataValue`.

### 3.2 Borrowed cursor values cannot cross the existing Job transport safely

The proposal allows a `Borrowed` value to become stale when its cursor advances and forbids retaining it. Job
channels, however, batch and queue several domain elements. A JDBC `ResultSet` is the forcing example: after
`next()`, the previous current-row view is normally no longer readable.

A cursor cannot simultaneously:

1. emit a borrowed current-row view;
2. advance to build a batch;
3. enqueue every view for asynchronous downstream processing; and
4. promise that all enqueued views remain live.

Detaching every row would make the contract safe but contradict the no-compulsory-materialization goal. Retaining
each row is not available for many cursor APIs. Disabling batching and consuming every row fully before advancing
would change Job's scheduling and throughput contract.

The first implementation should require each `DataCursor.next()` value to be independently owned for a precisely
defined scope, such as until the cursor closes or until an explicit item lease closes. A reusable-current-row
optimization should use a separate traversal API, for example `visitBorrowed`, only after a benchmark proves it
necessary and its consumer can guarantee synchronous consumption.

This permits the foundational model to defer most of `Borrowed | Retainable | Detached`, `retain()`, and
cross-channel lease transfer. Lifetime complexity should be introduced by the first real consumer that cannot
meet the owned-item contract.

### 3.3 `Dynamic` is not dynamically accessible

`Dynamic` is described as a value whose useful structure becomes known at runtime. The proposed access methods
are valid only for nodes whose declared type is already Record, Mapping, Listing, Union or Scalar. There is no
operation that discovers a dynamic node's runtime kind, enumerates dynamic record fields, or selects the
appropriate structural operation.

The smallest resolution is to keep `Dynamic` at observation and requirement boundaries:

- a source may report `DataShape(itemType = Dynamic)`;
- a dynamic port may accept runtime values of different concrete types; and
- each present `DataValue` carries the strongest concrete type its adapter/parser knows.

A JSON object then becomes a runtime Record or Mapping, a JSON array becomes a Listing, and a scalar becomes a
Scalar. Generic access needs no parallel dynamic operation language. A cursor whose observation is Dynamic may
emit differently typed values.

If a runtime value itself must remain `Dynamic`, the proposal needs a complete dynamic-kind and dynamic-key
access surface. That is a materially larger model and should be justified by a real consumer first.

### 3.4 Union traversal and wire identity are incomplete

`ValueAccess.activeVariant` exposes the selected ID but no operation exposes the selected variant value. A union
whose active branch is a Record cannot be traversed with `field` under the stated contract because the node's
type is Union, not Record.

The wire model also carries no active `VariantId`. An adapter or decoder may select a branch authoritatively, but
snapshotting the result to an ordinary scalar/list/object loses that identity. An ambiguous union cannot recover
it on decode. Therefore canonical round-trip of every `DataType` case is not achievable with the proposed
`WireValue` hierarchy.

The unified proposal also changes the earlier project-data decision without a forcing use case. The earlier
analysis limits Union to tagged declared/carried variants and widens inferred incompatible heterogeneity to
Dynamic. The unified proposal adds undiscriminated structural selection and inferred unions.

The simpler contract is:

- unions originate in declared/carried schemas;
- the producing adapter or codec supplies the active `VariantId`;
- runtime access includes an explicit selected-value node;
- snapshots encode the active variant;
- variant order is presentation/canonicalization only; and
- structural first/unique-match inference is excluded initially.

`FieldDiscriminator` can also remain codec/adapter policy rather than foundational type metadata. Whether a
format stores a tag in a member, wrapper, header or adjacent column does not change the semantic fact that one
variant is active.

### 3.5 Snapshot policies promise values the wire grammar cannot express

The snapshot policy says conversion may emit:

- a stable identity for repeated or referenced objects;
- a canonical redaction marker;
- a truncated value with a diagnostic; and
- followed graph/native references.

The proposed `WireValue` hierarchy contains no generic identity reference, redaction marker, truncation marker,
or result envelope carrying diagnostics and completeness. `BlobReferenceWireValue` is a resolver-backed binary
reference, not a general object-identity reference.

A smaller initial contract is:

```kotlin
data class DataSnapshot(
    val type: DataType,
    val value: WireValue
)

sealed interface SnapshotResult {
    data class Complete(
        val snapshot: DataSnapshot
    ): SnapshotResult

    data class Rejected(
        val problems: List<DataProblem>
    ): SnapshotResult
}
```

Initially:

- exceeding any bound fails;
- cycles fail;
- graph references lower to a stable scalar/opaque reference or fail;
- sensitivity is enforced by the binding caller; and
- no partial tree masquerades as complete data.

Truncation, repeated-identity encoding and reference following can be added together with the wire variants and
consumer protocol that make them meaningful.

The typed envelope is also needed because an `ObjectWireValue` cannot independently distinguish a Record from a
`Mapping(Text, ...)`, and it cannot preserve active union identity.

### 3.6 Signature schemas and binding instances are different concepts

The proposal combines binding definitions and runtime states so they cannot drift. That makes design-time
`LogicSignature` declarations collections of artificial `Unbound` runtime states and risks recreating the
same definition entries for every execution.

Validated separation is simpler:

```kotlin
data class BindingSchema(
    val definitions: List<BindingDefinition>
)

class DataBindings private constructor(
    val schema: BindingSchema,
    private val values: List<BoundValue?>
)
```

The constructor/factory owns:

- name uniqueness;
- ordering;
- unknown-name rejection;
- default application;
- type/value conformance; and
- index alignment with the schema.

This prevents drift without pretending a declaration is an incomplete runtime binding.

The runtime invariants must additionally forbid a Bound binding whose root state is Absent. Whether Invalid may
cross a Logic boundary must be decided explicitly; otherwise every consumer inherits an implicit obligation to
handle decode failures.

### 3.7 One `accepts` operation is underspecified

Several different compatibility questions are currently collapsed into `accepts(expected, actual)`:

- Does a record with extra fields satisfy a consumer requiring a subset?
- Does an optional actual field satisfy a required expected field?
- Are Listing and Mapping parameters covariant?
- Does Dynamic accept everything, or is it accepted by everything?
- Does a currently present value of nullable type satisfy a non-null input?
- Does compatible type metadata imply that every required value is present and valid?
- Does native assignability or structural compatibility govern a particular consumer?

Type compatibility cannot establish value conformance. A value may carry compatible type metadata while its root
is null, a required child is absent, a node is stale, or a child is invalid.

The foundation needs distinct operations:

```kotlin
fun isAssignable(
    expected: DataDescriptor,
    actual: DataDescriptor,
    requirement: DataRequirement
): TypeAcceptance

fun validate(
    value: DataValue,
    expected: DataDescriptor
): ValueValidation

fun project(
    value: DataValue,
    target: DataType
): ProjectionResult
```

The exact API names are secondary. The separation between compatibility, current-value validation and possibly
allocating projection is not.

Before adoption, the algebra must settle record width, field identity, optional/defaulted fields, numeric
promotion, collection variance, Dynamic direction, union normalization, and join laws. Inference requires join
to be associative, commutative and idempotent, or sample order will change the inferred contract.

## 4. Additional inconsistencies and unnecessary commitments

### 4.1 The root type is stored twice

`DataValue.type` and `ValueAccess.type(root)` are parallel descriptions joined by an asserted invariant. This
recreates the kind of drift the proposal aims to remove. Use one source of truth, or make any cached root type
private and validate it during internal construction.

Likewise, a cursor's provisional `DataShape.itemType` is an observation and cannot simultaneously promise to be
the exact type of every emitted item.

### 4.2 External backings cannot construct `DataNode`

`DataNode` has an `internal` constructor, but platform/consumer/plugin modules are expected to implement
`ValueAccess` and return child nodes. An implementation outside the kzen-lib compilation module cannot mint the
tokens required by its own `field`, `entry`, or `element` methods.

The node construction boundary must be public, supplied by a kzen-lib allocator, or hidden behind a different
backing implementation protocol. The proposed API and intended module ownership do not currently compile
together.

### 4.3 Retention is declared at the wrong granularity

`ValueAccess.retention` applies to the entire accessor, while the Composed backing can contain literal,
borrowed, native and graph-backed children. Either:

- retention is a property of a root/value;
- a composed value inherits the strictest lifetime and retains/detaches as a unit; or
- mixed-lifetime composition is forbidden.

The proposal should not leave that choice to each backing because engines need one deterministic transfer rule.

### 4.4 The contract is read-only, not immutable

Preserving a mutable native object's identity means another holder—or a caller using `native()`—can mutate the
object between reads. A collection may change size after lifting; a field value may stop matching the cached
`DataType`. The generic API prevents write-through but cannot promise an immutable value.

The document should use “read-only view” for live values and reserve “immutable/detached” for snapshots and
backings that actually own frozen data.

The proposed wire/data classes also need real immutability if that is promised. Public read-only `List` and
`Map` interfaces may still wrap mutable collections, and a public `ByteArray` property exposes the supposedly
owned bytes for mutation.

### 4.5 Automatic collection lifting is too broad

An arbitrary `Iterable` may be:

- lazy or infinite;
- one-shot;
- blocking;
- stateful; or
- unable to answer `size` without consuming itself.

A Set also does not necessarily promise stable positional semantics, so silently treating every Set as Listing
changes its meaning.

Automatic baseline lifting should initially cover primitives, lists, arrays and maps. Other iterable/stream
capabilities should use an explicit streaming boundary or registered adapter.

An untyped empty list also does not justify `Listing(Dynamic(nullable = false))`. Prefer an expected element type,
an inferred Kotlin generic type, or an honestly unknown element type.

### 4.6 Record identity and wire encoding do not yet agree

The structural model permits duplicate display names through stable `FieldId`, while `ObjectWireValue` requires
unique string keys. A record containing duplicate names cannot round-trip through that container without a
field-ID/occurrence encoding.

The existing `HeaderLabel(name, occurrence)` contract is sufficient for the current duplicate-column
requirement. The simplest v1 choice is to reuse that identity shape for structural fields and keep
provider-native numeric IDs/aliases beside `DataType` as lossless schema metadata. A new independently persisted
`FieldId` should be added only when a rename/reference consumer requires it.

If independent IDs remain, WireValue needs a distinct record container keyed by those IDs.

### 4.7 Scalar scope has drifted from the project-data analysis

The project-data analysis calls out enum symbols and fixed/provider scalar constraints, while the unified
vocabulary omits enums and moves unspecified details beside the semantic type. That may be the right
simplification, but it must be stated as a deliberate change.

In particular, choose one of:

- enum is semantically Text and its closed symbol set is provider/schema metadata; or
- enum membership participates in generic validation and therefore belongs in `ScalarKind`.

The same test should be applied to integer width, floating width, decimal precision/scale, UUID and temporal
precision. A parameter belongs in `DataType` only if a generic consumer observes different acceptance or access
behaviour because of it.

### 4.8 Per-node origins appear speculative

`BindingOrigin.Supplied | Defaulted | Produced` has clear diagnostic behaviour. Field default origin can also be
useful. `ValueOrigin.Literal | Backing | Derived`, however, is unstable through snapshots and composed
projections, and “Backing” describes almost every value.

Keep only origins with an identified consumer. Add provenance for derived nodes later if trace/UI functionality
requires it.

### 4.9 Sensitive snapshotting is only defined at whole-binding scope

`DataBindingDefinition.sensitive` can redact an entire binding. Nothing in `DataField`, `DataType`, or
`ValueAccess` marks a nested field sensitive, so a snapshotter cannot implement recursive sensitivity policy as
currently implied.

The initial contract should promise whole-binding sensitivity only. Nested sensitivity should arrive with an
explicit field/schema policy and path-aware tests.

### 4.10 Adapter conflicts cannot all be detected at registry construction

`DataAdapter.match(value)` discovers matching only for a concrete runtime value. A registry cannot pre-compute
every assignable/capability collision from that interface. Multiple-interface inheritance also has no single
universally correct “distance,” and generic arguments are erased on the JVM.

Either adapters declare their match keys and priority in inspectable metadata, or a tie is detected and rejected
at lift time. Exact native-class adapters plus an explicitly ordered set of capability fallbacks would be a
smaller first contract.

### 4.11 `kzen-lib-common` ownership does not settle the plugin SPI

`kzen-auto-plugin` is deliberately dependency-free, but the structural-reader plan expects third-party readers
and backing implementations to emit the shared value contract. Moving the vocabulary to kzen-lib requires one of:

- allow the plugin artifact to depend on kzen-lib;
- keep plugin outputs dependency-free and adapt them at the kzen-auto boundary;
- extract a smaller neutral artifact; or
- accept a narrow mirrored plugin contract.

The unified proposal selects the owner but does not select the dependency/SPI consequence. This remains an
ownership gate, not a mechanical move.

### 4.12 Repeated composed overlays need a flattening rule

A calculated-column Worker returning a composed record is attractive, but an unbounded chain of overlays can make
field lookup and retention proportional to the number of prior transforms while retaining every prior backing.

The backing needs an indexed field plan, a collapse threshold, or an owned mutable builder inside one Worker that
publishes an immutable/read-only result. The benchmark gate must include many sequential calculated columns, not
only a single overlay.

## 5. Recommended smaller target

The minimum coherent model is:

### 5.1 Types and descriptors

- `DataType` describes structural semantics only.
- `DataDescriptor` records the structural type plus an optional native programming type.
- Structural cases initially include Scalar, Record, Mapping, Listing, declared/tagged Union, Opaque and Dynamic.
- Dynamic is primarily an observation/requirement type; runtime values prefer concrete types.
- Field identity initially reuses name plus duplicate occurrence unless an authored stable-ID consumer is proven.
- Provider-native schema details remain beside the semantic projection.

### 5.2 Values and access

- One read-only `DataValue` crosses a data boundary.
- Literal, flat-record and native-object backings prove the access contract first.
- A fake typed-row backing proves that the contract is not accidentally tied to flat files.
- Native and structural projections coexist in the descriptor.
- Runtime root values are Present or Null; Absent belongs to a containing field or binding.
- Decode failure is initially a source/result diagnostic rather than a universally transportable Invalid value.
- Cursor values are independently owned under a simple, explicit scope.
- No generic graph-reference following or retainable live-row leasing in the first contract.

### 5.3 Bindings

- `BindingSchema` owns ordered declarations.
- `DataBindings` owns values validated against one schema.
- Missing, null and defaulted remain distinct.
- Whole-binding sensitivity is supported.
- Computed defaults are deferred unless an existing Logic contract requires them; literal defaults are sufficient
  for the foundational proof.

### 5.4 Wire and snapshots

- Keep today's `ExecutionValue` during the runtime-model proof.
- Convert through a typed `DataSnapshot(type, value)` envelope.
- Bounds and cycles fail rather than truncate initially.
- Do not follow graph/native references.
- Add exact integer/decimal or arbitrary-key containers only when a demonstrated boundary cannot lower safely
  through the existing tree.
- Rename/redesign `ExecutionValue` only after the new requirements and compatibility grammar are settled.

### 5.5 Adapters

- Built-in primitives, lists, arrays, maps, Kotlin data classes and Java records.
- Exact registered native-class adapters.
- Explicit capability fallbacks with deterministic order.
- No arbitrary public-getter reflection.
- No general Iterable/Set lifting.
- Platform-specific adapter mechanics stay outside the common semantic contract.

## 6. Recommended proof and sequencing

The proposal's coordinated cutover is too large. A temporary internal bridge does not have to become a supported
compatibility layer; it can isolate risk while the final model is proved.

Recommended sequence:

1. **Settle the descriptor.** Prove that one value can retain native Kotlin typing and expose a structural record.
2. **Settle the algebra needed by current records.** Scalar, record, mapping, listing, nullability, presence,
   assignment, validation and explicit projection.
3. **Land schema plus bindings.** Replace opaque Logic argument lookup without depending on cursor retention or
   graph traversal.
4. **Prove three backings vertically.** The same record is read from `FlatFileRecord`, a Kotlin data class and a
   fake typed database row.
5. **Replace the Job carrier.** One value crosses the lane; flat consumers request a structural/tabular
   projection; benchmark current and many-overlay paths.
6. **Move DataShape to the observation envelope.** Declared and inspected sources use the same type vocabulary.
7. **Cut Script and Flow boundaries over where generic data actually crosses.** Native-only local variables need
   not be wrapped merely to satisfy architectural symmetry.
8. **Add the first structured reader.** Its requirements decide structural tape and Dynamic behaviour.
9. **Add the first real durable-row source.** Its measured behaviour decides whether borrowed/retainable lifetime
   machinery is necessary.
10. **Design the richer wire grammar separately.** Union tags, arbitrary mapping keys, exact numerics, references,
    redaction and truncation land only with an explicit versioned protocol.
11. **Add graph structural exposure separately.** First prove exposure metadata and stable reference lowering;
    navigation remains outside the generic model until a concrete processor needs it.
12. **Delete each temporary bridge once its consumers have crossed.** The completed architecture still has one
    dataflow model, without requiring one unreviewable all-repository cutover.

## 7. Recommendation register

| # | Question | Review recommendation |
|---|---|---|
| DR1 | One carrier for every Logic flavour? | Yes |
| DR2 | Exactly one mutually exclusive type per value? | No; structural and native projections are orthogonal |
| DR3 | Structural vocabulary owner? | Prefer `kzen-lib-common`, after resolving plugin dependency policy |
| DR4 | `DataShape.Tabular | Payload | Both`? | None; retain the observation envelope |
| DR5 | Native Kotlin values? | Preserve native type/identity as an optional projection |
| DR6 | Runtime Dynamic access language? | Avoid initially; emit concrete runtime value types |
| DR7 | Union inference? | No initially; declared/carried variants with producer-selected IDs |
| DR8 | Field discriminator in `DataType`? | No initially; codec/adapter resolves representation to VariantId |
| DR9 | Cursor lifetime? | Independently owned emitted values first; specialized borrowed traversal later |
| DR10 | Universal Invalid state? | No initially; decode failures use explicit source/result diagnostics |
| DR11 | Binding schema and values one class? | Separate schema and validated instance |
| DR12 | Wire rename in the foundational cut? | No; retain `ExecutionValue` until the versioned grammar is justified |
| DR13 | Truncating/reference-following snapshots? | Defer; strict bounded complete-or-rejected snapshots first |
| DR14 | Graph reference navigation? | Defer; stable identity/reference lowering only |
| DR15 | Automatic Iterable/Set lifting? | No |
| DR16 | Per-node generic origin? | Defer except binding/default origins with identified consumers |
| DR17 | Migration style? | Sequenced vertical cutovers with temporary internal bridges, then deletion |
| DR18 | Performance proof? | Flat, native, typed-row, batching and repeated-overlay benchmarks |

## 8. Adoption gate

The revised proposal is ready to become a plan when a prototype proves all of the following together:

- one data-class instance retains its native Kotlin type and exposes record fields without copying;
- the same structural consumer reads a flat row, data class and typed row;
- Logic binding enumeration distinguishes unbound, null and defaulted values;
- compatibility and value validation produce different, deterministic results where appropriate;
- a tagged union exposes both its active ID and selected value and round-trips through a typed snapshot;
- cursor items survive the actual Job batching/channel cadence under the chosen ownership contract;
- repeated calculated-column overlays retain bounded lookup cost and backing lifetime;
- no per-field `DataValue` allocation occurs on the flat hot path;
- the plugin SPI dependency/adapter decision is explicit; and
- the representative Job throughput remains inside its accepted regression budget.

Until those gates are met, the current `Any?` and payload/flat split remain defects to remove, but they should not
be replaced by a broader contract whose native projection, dynamic traversal, union wire identity and lifetime
semantics are still contradictory.
