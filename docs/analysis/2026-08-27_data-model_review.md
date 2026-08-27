# Unified data model — design review

> **Review status:** independent critique of the [unified data-model proposal](2026-08-27_data-model.md), including
> its revised tagged-union section. This is not a competing specification or an implementation contract. The
> proposal remains the owner of accepted decisions; this document records pressure tests, objections and a
> smaller alternative for consideration.

## 1. Executive assessment

The proposal has the right architectural centre:

- one structural vocabulary rather than separate Script, Flow, Job, source and database vocabularies;
- read-only semantic access over specialized physical backings rather than compulsory tree materialization;
- named, enumerable bindings that distinguish missing from null and declaration from instance;
- ordinary Kotlin authoring at native edges; and
- explicit, bounded snapshots at wire and trace boundaries.

Those ideas should proceed. The proposed API should not yet proceed unchanged.

The main concern is not that the proposal is too ambitious in its desired functionality. It is that several
future concerns have been placed in the foundation before their first consumer exists, while a few foundational
boundaries remain internally inconsistent. In particular, native identity is treated as semantic type even
though it is a backing capability; the ownership vocabulary promises operations the API cannot enforce; the v1
snapshot grammar cannot represent every promised v1 value; and the advertised `KType` / `TypeMetadata` mappings
cannot be implemented from the information those types actually contain.

The recommended disposition is therefore:

1. accept the structural-value, specialized-backing and typed-binding direction;
2. revise the native/type, lifetime and snapshot boundaries before planning implementation; and
3. prove a smaller vertical slice before admitting unions, graph references, borrowed rows and general
   projections into the common foundation.

## 2. Findings that should block the proposed API shape

### 2.1 Native projection is a value capability, not a structural type facet

The proposal's first principle says meaning is independent of storage. Its `native` annotation then makes the
ability to return the current backing as a Kotlin object part of `DataType` equality, canonical digest and lane
identity. These two positions conflict.

`native` is defined operationally: it promises that native code can receive the original object without a copy.
That promise depends on the live backing. Consequently:

- a data-class-backed record and a row-backed record with identical fields acquire different canonical types;
- taking a snapshot of `Record(..., native = Reading)` preserves the annotation but not the original `Reading`
  instance, so the decoded snapshot cannot fulfil its advertised native capability;
- lowering an opaque graph object to a textual stable reference produces something that is no longer the native
  object described by the snapshot type; and
- changing adapters or backing representation changes the canonical type even when every structural consumer
  observes the same meaning.

The representation is also redundant. `DataType.nullable` and `TypeMetadata.nullable` can disagree, while a
native generic such as `List<Reading>` is described once by `TypeMetadata.generics` and again by
`DataType.Listing.element`. An adapter may establish an invariant at construction, but the public data classes
permit contradictory values and a mutable native object may cease to conform after lifting.

The proposal rejects a top-level `DataDescriptor(structural, native)` because it would lose native information
for nested fields and collection elements. That rejects only a non-recursive descriptor. A recursive contract
retains the information without placing a backing promise inside structural type identity:

```kotlin
data class DataContract(
    val structural: DataType,
    val native: TypeMetadata? = null
)

data class DataField(
    val id: FieldId,
    val contract: DataContract,
    val required: Boolean
)

data class ListingType(
    val element: DataContract
): DataType
```

A declaration can require both structural and native facets. A live `DataValue` can state which native
capability its backing actually supplies. A detached snapshot can retain only the structural contract unless it
genuinely supports reconstructing the native value. This is slightly more vocabulary but a simpler invariant:
semantic equality no longer changes with backing choice.

### 2.2 The `KType` and `TypeMetadata` mappings are not available from the proposed information

The proposal describes `KType -> DataType` and `TypeMetadata <-> DataType` as generic mappings with no
application-specific branches. The latter cannot be bidirectional and neither is wholly a common-platform
operation.

`TypeMetadata` currently holds only class name, generic arguments and nullability. It contains no data-class
properties, Java record components, inheritance graph, variance, adapter declaration or carried schema. Thus:

- `TypeMetadata(Reading)` cannot become `Record(sensor, value)` without loading and inspecting `Reading`;
- a structural record with no native class has no meaningful lossless conversion back to `TypeMetadata`;
- native assignability cannot be decided correctly from class-name strings; and
- the same FQN loaded by two plugin classloaders does not denote one JVM type.

The existing `TypeAssignability` uses a compiler probe precisely because Kotlin assignability is richer than
`TypeMetadata`. The new model should not silently replace that behaviour with class-name comparison.

Adapter extensibility has the same static gap. `DataAdapter` exposes only `lift(value, expected)`. A registered
adapter may turn `Money` into a structural scalar or record at runtime, but it cannot contribute that structural
contract while a Formula or port lane is being typed. Static analysis therefore sees `Opaque(Money)` and may
reject a structural consumer before the runtime adapter participates.

The foundation needs two explicit platform seams:

- a JVM native-type resolver that uses actual class identity and the appropriate Kotlin/compiler rules; and
- an adapter description operation that can contribute a contract without requiring a runtime value.

Capability fallbacks that genuinely require a value may remain runtime-only, in which case the static lane must
honestly remain `Dynamic` or opaque.

### 2.3 The ownership vocabulary is not enforced by its API

The retention section promises more than `DataRetention.Detached | Owned` can express:

- retention is described as per root but exposed as one property on `ValueAccess`;
- `Owned` carries no owner or scope identity;
- no operation transfers, detaches, retains or releases a value;
- nothing enforces the stated at-most-once transfer;
- `isAlive` detects expiry but does not define who expires the value; and
- migration transfer remains an open design question.

The cursor rule is also too weakly phrased. A value that survives until its cursor closes can still become stale
while queued Job batches are being consumed after the producer has finished and closed the cursor. The useful
contract is that an emitted item survives its actual downstream use, not merely cursor iteration.

Calculated-column append exposes a separate issue: lifetime ownership is not exclusive mutation authority. An
owned value may be aliased through another view, trace, branch or composed overlay. Mutating the backing can make
an older `DataValue.type` or field set change after publication. `Detached` values can likewise be shared.
Appendability therefore needs an explicit unpublished/exclusive builder capability, not an inference from
retention state.

The smallest v1 rule supported by today's backings is:

> Every value crossing a v1 data boundary is self-contained or strongly run-owned and remains readable until
> the run settles, including after the producing cursor closes.

Current copied flat rows and strongly referenced native objects can meet that rule. It requires no public
retention enum, per-accessor `isAlive` branch, ownership-transfer protocol or lease. The first JDBC source can
then choose, from measurement, between copied rows and an explicit borrowed/retained API.

### 2.4 The current snapshot grammar cannot represent the stated v1 contract

Keeping `ExecutionValue` for v1 is sensible, but the proposed lowering overpromises in four places.

First, a record with duplicate `FieldId(name, occurrence)` fields cannot lower losslessly to an
`ExecutionValue` map. A rendered-name escape may collide with a real field name and is not specified as part of
field identity. The existing grammar can still carry these records, but they must lower as an ordered list of
entries containing name, occurrence and value.

Second, the grammar has no redaction variant. Encoding redaction as an ordinary text value would both collide
with real data and violate a non-text `DataType`. V1 should return `SnapshotResult.Redacted`, or reject sensitive
snapshots, until the wire tree gains a real redaction marker.

Third, native and opaque values cannot round-trip as their advertised types. A snapshot of a native record loses
native identity; a graph object lowered to a reference becomes a reference value. Either snapshots carry only
the structural type they actually reproduce, or opaque/reference lowering gets an explicit surrogate contract.

Fourth, `DataProblem.path: List<String>` cannot address duplicate fields, non-text mapping keys, indices and
union selections without ambiguity. One typed path-segment vocabulary should be used by validation, projection
and snapshot failures.

A strict v1 snapshot can remain small: complete acyclic structural values only, ordered lossless record
encoding, explicit rejection of sensitive and opaque values, and no claim that detached data retains native
capabilities.

### 2.5 Recursive data types are not representable

Lazy access handles cyclic values, but `DataType` itself is an eagerly recursive tree. Automatically lifting the
following ordinary data class cannot terminate:

```kotlin
data class Node(
    val value: String,
    val next: Node?
)
```

Mutually recursive data classes and named recursive Avro/protobuf declarations have the same problem. Snapshot
cycle detection occurs too late because the structural type has already recursed while the adapter plan was
built.

V1 does not necessarily need a named-type and reference system. The simpler honest rule is that automatic
data-class structural expansion rejects recursion or stops at the recursive member and treats it as opaque.
The current proposal must choose one of those rules; it cannot promise all data classes as structural records
while omitting recursive type references.

### 2.6 Direct `FlatFileRecord : ValueAccess` ownership is premature and awkward

`FlatFileRecord` deliberately stores only cell contents and primitive caches. Its header/schema is held
separately by `FlatView` and shared across rows. A `ValueAccess` must answer `type(root)`, so a bare record cannot
implement the proposed contract without acquiring schema and lifetime responsibilities it does not currently
own.

`FlatRecordAccess(header, record)` is the natural adapter. It preserves the focused Java buffer, avoids making
every plugin depend directly on the entire evolving value contract, and keeps the shared-header relationship
explicit. The new design already allocates a `DataValue` per row; whether one additional small adapter object or
forwarding call is material should be measured rather than assumed.

The repository guide also defines `kzen-auto-plugin` as a public stable SPI. The proposal's statement that no
external ecosystem currently exists is not sufficient by itself to maximize coupling in that SPI. Start with
the narrow adapter. Move the contract into the plugin only if a representative benchmark demonstrates a cost
that matters.

## 3. Tagged-union review after clarification

The revised §4.5 is materially clearer. "Tagged" now correctly describes the runtime value and snapshot, not a
requirement that every input encoding physically contain a tag. Unique accepting-variant selection, ambiguity
failure and no first-match precedence are sound rules.

Four details still need to be closed if union remains in v1.

### 3.1 Assignability and implicit selection are different relations

The revised algebra says a union accepts an actual type when at least one variant accepts it. Implicit selection
requires exactly one accepting variant. A type can therefore be assignable to the union but impossible to tag
implicitly.

Name the operations according to those different contracts:

- `acceptsExplicitVariant(union, id, actual)` validates a tag supplied by a producer or codec; and
- `selectImplicitVariant(union, actual)` succeeds only for one uniquely accepting branch.

A binding or adapter receiving an untagged value must call the second operation, not plain union assignability.

### 3.2 Selection must construct a tagged union node

Returning a `VariantId` does not by itself turn a `Record` or `Listing` root into a union root. Downstream
`activeVariant` and `selected` operations require an actual tagged union view. The producer/adapter contract must
say that lifting against an expected union constructs that wrapper or overlay exactly once.

Otherwise the binding schema says Union while the bound value's root still says Record or Listing, recreating
the parallel declaration/value mismatch the model is intended to remove.

### 3.3 Structural selection intentionally cannot distinguish some native alternatives

Structural selection cannot uniquely choose between:

- same-shaped data classes with different Kotlin classes;
- two opaque native alternatives; or
- width-overlapping records such as `Record(a)` and `Record(a, b)`.

Ambiguity failure is reasonable, but the Formula/native case should be explicit. If a Formula declares a union
of nominal Kotlin alternatives, native assignability may be the correct selection requirement. If selection is
always structural, those unions require an explicit producer tag even when the runtime class is unambiguous.

### 3.4 Record-width rules become part of decoding semantics

Changing structural record assignability changes whether an untagged union is uniquely decodable. The eventual
record-width decision is therefore not an isolated algebra choice; it is part of the union codec contract and
needs paired tests.

Finally, the proposal should still identify a real first consumer. `List<String> | String` is a good motivating
example, but an example alone does not make union necessary to the foundational proof. If a near-term Formula or
carried-schema feature requires it, keep it. Otherwise deferring Union also removes `VariantId`, selection,
active-variant access and union snapshot encoding from v1.

## 4. Further inconsistencies and pressure points

### 4.1 Defaults are construction policy, not runtime structural type

Embedding `DataDefault` in `DataField.type` makes two otherwise identical runtime records different types based
on how an absent input would have been constructed. A data-class adapter also cannot generally recover Kotlin
constructor defaults from `KType` alone.

Binding defaults belong on `BindingDefinition`. Record defaults should live in the schema/reader contract that
applies them. The same `DefaultSpec` vocabulary can be reused without making the literal default part of a live
value's structural identity.

### 4.2 The enum rationale points to a missing constraint layer

The document's inclusion test says a property belongs in `DataType` when generic acceptance or validation
changes because of it. Enum symbol membership changes validation, just as decimal precision and integer width
do, yet enum is placed in unspecified schema metadata beside the type.

Either enum is a semantic type/constraint, or `DataType` is explicitly only an access shape and a separate
constraint schema owns precision, symbol sets and defaults. Both are defensible. Mixing the two rules is not.

### 4.3 `FieldId(name, occurrence)` is unique but not evolution-stable

The identifier distinguishes duplicates within one record definition. Inserting an earlier same-named field,
or renaming a field, changes it. Describe it as stable within one schema version rather than as an independently
stable field identity. Provider-native IDs remain necessary for formats whose evolution semantics require them.

### 4.4 Dynamic mapping keys lack enough scalar identity

`keyAt` returns only `ScalarExecutionValue`, while exact decimal, temporal and UUID values are interpreted under
an owning scalar type. When `Mapping.key` is `Dynamic`, that owning type is unavailable. Text `"1"`, integer
`1`, decimal `1` and other canonical-text scalars can no longer be distinguished reliably.

Either mapping keys always have a concrete scalar kind, heterogeneous-key mappings widen to a fully dynamic
value rather than `Mapping(Dynamic, ...)`, or the key handle carries both scalar type and scalar value.

### 4.5 Full binding-time validation conflicts with lazy access

Recursively walking every value when it is bound can consume large collections, revisit cycles, touch live rows
and double work already performed by a decoder or adapter. It also makes every Flow/Job handoff potentially
linear in the size of the value.

Prefer values valid by construction against their own advertised type:

- readers enforce decode policy while reading;
- adapters guarantee the contracts they publish;
- bindings check expected-versus-actual type, root nullability and presence; and
- deep validation is explicit for an untrusted backing or a consumer that needs it.

Mutable native objects remain capable of violating their view after lifting, but an unconditional deep walk at
every boundary does not solve mutation after the walk.

### 4.6 Graph provenance cannot be recovered by class-based lifting

`ObjectInstance.reference` is the actual Kotlin object, not a stable graph identifier. Once that raw object is
passed across a boundary, a class-based adapter cannot know whether it was graph-created or constructed normally,
nor recover its `ObjectDefinition`, location and stable-mapper context. A data-class baseline may also win before
a graph-specific adapter sees it.

Graph lowering therefore needs an identity/context registry or an explicit graph-value wrapper at the boundary.
That is a distinct design problem. V1 can keep graph objects as opaque native values and reject their snapshots
rather than promise stable-reference lowering before the provenance seam exists.

### 4.7 Result-builder concurrency and overwrite semantics are missing

`JobResultCollector` currently permits concurrent Workers and implements synchronized last-write-wins behavior;
the first yield establishes component order. A `DataBindings` output builder must explicitly preserve or replace
that behavior. Generic statements about rejecting duplicate supplied names do not settle repeated produced
components.

### 4.8 `DataShape` provenance does not match the related analysis

The project-data analysis describes provenance as a chain, while the unified proposal models one enum value. If
the client only needs the primary basis plus conflict diagnostics, rename the field accordingly and keep the
simpler model. If migration or writer behavior depends on the evidence chain, the single enum loses required
information.

### 4.9 Database temporal coverage will need local date-time

`Date`, `Time`, `Instant` and `Duration` are coherent, but timestamp-without-timezone is common database data and
is not an `Instant`. A distinct `LocalDateTime` should be introduced with the first database consumer rather than
silently coercing the value to UTC or treating a common semantic value as provider trivia.

## 5. Scope simplifications

### 5.1 Unify generic boundaries, not every internal variable and transport

The proposal begins by correctly saying `Any?` is legitimate at arbitrary Kotlin edges, but later treats most
existing `Any?` traffic as a cutover target. Not every occurrence represents the same defect.

Job needs a unified carrier because generic Workers compose structural and native values dynamically. Logic
bindings need enumeration, presence and validation. Script's generated native locals and Flow's
`RequiredInput<T>`, however, provide useful typed authoring APIs. They need not expose `DataValue` merely for
architectural symmetry.

The runtime may carry or retain a `DataValue` underneath, and generic hosting/inspection can lift at its boundary.
A custom Flow vertex should continue receiving `T` when its port is statically typed. This preserves ergonomics
and reduces the cutover surface without reintroducing competing semantic models.

### 5.2 Keep tabular projection in the first consumer

Job needs specific column behavior:

- record fields in order;
- scalar as synthetic `value`;
- a configured policy for mapping keys;
- duplicate-label rendering; and
- `<missing>` for absent optional fields.

That is a `ColumnProjection` capability owned by kzen-auto. It does not yet justify a general
`project(value, target: DataType)` algebra in kzen-lib capable of arbitrary reshaping. A general projection API
can be extracted when a second consumer demonstrates shared semantics.

### 5.3 Defer lifetime states until a resource-backed value forces them

The fake typed-row backing can prove that `ValueAccess` is open without pretending to model a live JDBC lease.
Require it to be self-contained for the prototype. Let the first real driver and measured batching behavior
determine whether rows copy, retain, pin a transaction or expose a synchronous traversal path.

### 5.4 Defer graph-specific behavior to the graph consumer

Native opaque access already lets a graph-created object cross a Kotlin boundary. Structural exposure,
reference navigation and stable lowering require graph provenance and policy that do not yet exist. Removing
them from v1 makes the opaque baseline truthful and deletes several special adoption-gate cases.

### 5.5 Keep the initial scalar set consumer-driven

The parameterized scalar design is reasonable, but the first implementation need only freeze the kinds exercised
by the vertical proof. Precision, unsigned arithmetic, temporal canonicalization and carried-schema constraints
should not all become foundational algebra merely because likely future formats contain them.

## 6. Proposed smaller v1

The smallest coherent vertical model is:

1. **Pure structural `DataType`.** Scalar, Record, Mapping, Listing, Dynamic and Opaque; Union only if a named
   first consumer uses it.
2. **Recursive `DataContract`.** A structural type plus an optional native requirement, recursively used by
   fields and collection elements.
3. **Read-only `DataValue`.** One access/root pair over literal, native-object, flat-record adapter and fake
   typed-row backings.
4. **Run-lifetime validity.** Every v1 value remains readable through run settlement. No public lease or transfer
   machinery.
5. **Validated named bindings.** `BindingSchema` and `DataBindings` distinguish unbound, null, supplied,
   defaulted and produced; defaults are schema policy.
6. **Job-owned column view.** No second authoritative payload/flat carrier and no universal projection algebra.
7. **Strict structural snapshots.** Complete or rejected; lossless ordered record encoding; sensitive and opaque
   values reject in v1.
8. **Typed native façades remain.** Script and Flow lift only where generic infrastructure needs semantic access.

The proof should exercise one real path rather than one example per speculative capability:

```text
CSV flat row
  -> structural calculated-column read/write
  -> nested Logic binding
  -> result/writer

Formula-produced data class
  -> native consumer without copying
  -> the same structural consumer used by the flat row
```

That proves the valuable claims: one semantic record, no eager map conversion, native identity retained in
process, missing distinct from null, and named typed composition across Logic. A fake typed row proves backing
extensibility. It does not require graph identity, recursive schemas, JDBC leases, union selection or a future
wire grammar to be designed in advance.

## 7. Recommendation register

| Area | Review recommendation |
|---|---|
| One structural vocabulary | Accept |
| Read-only access over multiple backings | Accept |
| Typed enumerable bindings | Accept, after result overwrite/concurrency semantics are settled |
| Native annotation inside `DataType` | Revise to a recursive contract/value capability split |
| `TypeMetadata <-> DataType` | Reject as stated; replace with explicit lossy/platform mappings |
| Native assignability in common algebra | Move to JVM/platform resolver |
| Adapter registry | Add static description; key exact registrations by actual class identity |
| `Detached | Owned` v1 retention | Defer; require run-lifetime values first |
| Direct `FlatFileRecord : ValueAccess` | Start with a narrow adapter; measure before coupling the SPI |
| Tagged unions | Clarification accepted; close tagging construction and selection relations; defer absent a consumer |
| General `project(value, target)` | Keep Job column projection local until a second consumer exists |
| Snapshot envelope | Accept after lossless record, redaction and native-capability corrections |
| Graph structural/reference behavior | Defer until graph provenance and exposure metadata exist |
| Automatic data classes | Accept for acyclic data classes; define recursive-type behavior |
| Script/Flow wholesale carrier cutover | Reject as a blanket rule; preserve typed façades and lift at generic boundaries |

## 8. Conclusion

The proposal's most important insight survives this critique: the system should share semantic data operations,
not force every value into one physical carrier. The same restraint should be applied one level higher. Sharing a
semantic contract does not require every internal transport to expose the same wrapper, and supporting future
backings does not require their lifecycle and wire protocols to be frozen before they exist.

The recommended design is therefore not a retreat to `Any?`, maps or `JobMessage(payload, flat)`. It is a smaller
and stricter version of the proposal: structural meaning in one place, native capability kept honest, values
valid for a simple v1 lifetime, bindings explicit, and specialization left with the consumer until real reuse is
demonstrated.
