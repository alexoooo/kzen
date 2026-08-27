# Unified data model — design review

> **Review target:** [Unified data model — types, values, bindings and managed-object views](2026-08-27_data-model.md),
> including the amendment that tagged Union is unconditionally in v1 with `List<String> | String` as its named
> consumer.
>
> **Status:** review findings, not an implementation contract. The target proposal remains the prospective owner
> of accepted decisions. This file records challenges and recommended changes for disposition; it does not create
> a second authoritative data-model specification.

## 1. Overall assessment

The central direction is strong:

- one recursive structural vocabulary shared across Logic flavours;
- missing distinct from null;
- read-only live values over specialized backings rather than compulsory tree materialization;
- typed, enumerable bindings;
- consumer-owned tabular projection rather than `Tabular | Payload` carrier categories; and
- explicit, bounded snapshots at wire and trace boundaries.

Those are durable improvements over `Any?`, `TupleDefinition` / `TupleValue`, `WorkerLane(payloadType,
flatColumns)` and `JobMessage(payload, flat)`.

The proposal should not yet become an execution plan. Four central claims remain unsound or underspecified:

1. Job's payload and columns are not always two projections of one semantic value.
2. A string `ClassName` cannot provide the classloader-aware native identity the native algebra requires.
3. Mutable native views can invalidate the advertised structural contract after shallow validation.
4. "Readable until the run settles" is too short for values returned by a settled hosted child or root run.

The type algebra, Flow façade and several v1 boundaries also need correction before their APIs harden.

## 2. Blocking findings

### 2.1 Job payload and columns are sometimes independent results

The proposal diagnoses `JobMessage(payload, flat)` as two authoritative representations that producers must keep
synchronized. That diagnosis is correct for a payload merely auto-flattened for a column consumer. It is not true
for every behavior the current carrier supports.

`FormulaWorker.onElement` deliberately performs two independent transformations against the incoming message:

- `formula` expressions append fields to the flat record; and
- the `payload` expression independently replaces the native payload.

Both may be configured on one Worker and both are evaluated against the incoming state. A message can therefore
leave the Worker with structural columns derived from one value, plus calculated fields, and a native payload of
an unrelated type. For example, columns derived from a `Reading` may gain `normalized`, while the payload becomes
an `Alert`.

Representing that output as `DataContract(Record(...), native = Alert)` makes two independent results look like
projections of one semantic value. A structural consumer and a native consumer observe different computations.
A structural-only snapshot drops the `Alert`; a native Logic boundary drops or ignores the calculated columns.
Today's `JobMessage.boundaryValue()` makes that choice explicit by preferring the payload.

This is not fixed by hiding both halves behind one `ValueAccess`. That would encapsulate the split while retaining
its semantics, contrary to the proposal's claim that there is one authoritative value.

#### Recommendation

Unify the value vocabulary without requiring every Job transport element to contain exactly one value:

```kotlin
class JobElement(
    val payload: DataValue?,
    val columns: DataValue?
)
```

`columns`, when present, is a structural Record. `ColumnProjection` may lazily derive it from `payload`; after a
calculated-column operation it becomes an independently derived value. A payload transform changes `payload`
only. Logic-boundary behavior then deliberately selects, rejects or maps the relevant component according to the
declared binding rather than relying on a hidden precedence rule.

An alternative is to remove the ability to produce both results in one Worker. That would simplify the carrier,
but it changes existing functionality and therefore needs an explicit product decision rather than following
silently from the new model.

### 2.2 `ClassName` cannot carry native JVM identity

The proposal correctly observes that the same fully qualified name loaded by two plugin classloaders denotes two
different JVM types. It nevertheless stores only `ClassName` in `DataContract.native` and passes two
`DataContract`s to `isAssignable(..., DataRequirement.Native)` and `selectVariant(...,
DataRequirement.Native)`.

`ClassName` is a common-platform string value. Neither contract identifies the defining classloader or actual
`Class<?>` / `KType`. The registry may select adapters by actual class identity, but that identity has been
discarded before the native algebra receives its inputs. The proposed resolver therefore cannot implement the
stated contract without an out-of-band lookup whose key is ambiguous by construction.

There is a related identity conflict. `DataContract` is proposed as a data class, so ordinary equality includes
its `native` property. The prose instead says structural equality, canonical digests and lane identity ignore the
native facet. Yet a native requirement changes connection legality, union selection, generated Kotlin types and
likely compilation-cache identity. Two signatures requiring native `Reading` and native `Customer` cannot safely
share every identity merely because their record fields happen to be equal.

#### Recommendation

Keep the serializable common contract structural and carry runtime-native identity separately:

```kotlin
data class DataContract(
    val type: DataType
)

// JVM-local; backed by KType/Class<?> and its defining loader.
interface NativeTypeToken
```

A live node may expose a JVM-local native projection. A binding, port or generated expression may independently
require structural or native access. `ClassName` may remain client-visible diagnostic metadata, but it must not be
the key used for runtime native assignability.

If the recursive `DataContract(structural, native)` form is retained, the proposal must instead define:

- a JVM-native identity sidecar that survives from description to resolution;
- structural equality/digest separately from full boundary equality/digest;
- which identity lanes, signatures and compiler caches use; and
- whether a native requirement also checks structural compatibility.

The last item matters because native-only acceptance could admit a value whose advertised record is incompatible
with fields later assumed by a structural consumer.

### 2.3 Mutable native values invalidate "valid by construction"

The proposal says a holder of the original native object may mutate it between structural reads. It explicitly
allows a collection to change size or a field to stop matching the annotated type. The binding model then relies
on shallow validation and on values being valid by construction against their advertised contracts.

Those statements cannot all hold. A bound `List<String>` may later contain an integer; a data class may contain
mutable properties or collections; an adapter may expose state whose shape changes. The stable lane type and the
`describe` / `lift` agreement cease to describe subsequent reads.

The same issue weakens the claim that reading the contract from the backing creates one source of truth. Native
and typed-row adapters necessarily maintain a descriptor of external data. The improvement is encapsulated and
validated consistency, not elimination of the metadata/value invariant.

#### Recommendation

State an explicit publication rule:

> After a value crosses a data boundary, mutation that would invalidate its advertised contract is a contract
> violation.

Then specify the observable failure when a backing nevertheless violates it. Options are immediate accessor
failure, explicit backing invalidation/versioning, or detachment of mutable baselines. Returning the original
object through `native()` means the rule cannot be fully enforced, but responsibility and failure semantics must
still be defined.

### 2.4 The v1 lifetime guarantee ends before callers consume results

The v1 rule guarantees readability until the run settles. In the engine, a hosted child settles and its frame
cleanup runs before `Execution.host` returns `Outcome.Success.value` to the parent. A root result likewise exists
specifically to be inspected after terminal settlement.

"Run" is also ambiguous under nested hosting: the producing child invocation, the root execution tree, or some
external result-retention scope. A value that expires at its producer's settlement can already be stale when its
caller first receives it.

#### Recommendation

Use a stronger and simpler v1 rule:

> Every v1 `DataValue` is self-contained or strongly GC-owned and remains readable as long as the `DataValue` is
> reachable.

Literals, copied flat rows, ordinary native references and an owned fake row already satisfy this. Remove
"run-owned" from v1. The first JDBC or pooled-parser consumer then either copies before emission or introduces a
separate borrowed traversal/lease contract, including transfer across hosted results, batching and migration.

## 3. Type-algebra findings

### 3.1 Ordered records conflict with a commutative `join`

`DataType.Record` declares field order meaningful, while `join` must be associative, commutative and idempotent.
An inference or superset merge that keeps the first schema's order and appends newly encountered fields is
necessarily order-dependent. Sorting fields canonically restores commutativity but discards source/schema order
that column consumers and UIs preserve.

#### Recommendation

Keep the generic algebra conservative:

- recursively join records only when their ordered field identities match;
- widen incompatible ordered records to `Dynamic`; and
- keep Job's heterogeneous-header superset normalization as an intentionally order-aware `ColumnProjection`
  operation.

If the generic `join` must merge differing record widths, presentation order needs to move out of structural
identity into separate schema metadata. That is a larger model than the proposal currently acknowledges.

### 3.2 Union assignability is incomplete

Union is unconditionally in v1. The statement "a union accepts an actual contract when at least one variant
does" is sound only for a non-union actual contract.

For union-to-union compatibility, every possible actual variant must be accepted by some expected variant.
Otherwise `String | Date` would satisfy `String | Integer` merely because the string branch matches.

Before implementation, the algebra needs explicit rules and representative tests for:

- expected union versus concrete actual;
- expected union versus actual union;
- concrete expected versus actual union;
- duplicate contracts under different variant IDs;
- duplicate IDs with different contracts;
- union-root nullability;
- selection when the actual contract is already Union or Dynamic; and
- normalization ordering compatible with `join`'s stated laws.

The `Structural | Native` requirement also needs a third answer or a different formulation: when a declaration
requires a native projection, must the structural contract remain compatible as well? Native-only acceptance is
unsafe if the same boundary promises fields to downstream structural consumers.

### 3.3 Mapping-key rules have contradictions and collision gaps

Section 4.3 says every present mapping reports a concrete key kind. Section 7.2 says an empty untyped map becomes
`Mapping(Dynamic, Dynamic)`. An empty mapping is present.

The simple correction is to require a concrete key kind only for a non-empty present mapping.

The mapping baseline must also define:

- whether native maps containing null keys stay Opaque or fail lifting;
- whether different numeric key classes may join to one semantic integer/decimal kind; and
- what happens when two distinct native keys lower to the same canonical scalar key.

`keyAt` plus canonical scalar text cannot represent a native mapping faithfully until those collisions are
settled.

## 4. Boundary and façade findings

### 4.1 `RequiredInput<T>` cannot generally receive a generated accessor

A precompiled custom Flow vertex using `RequiredInput<T>` can name a known native `T` or a stable framework type.
It cannot name a runtime-generated accessor class derived from an authored schema the vertex had never seen at
compile time.

Generated structural façades fit dynamically compiled Formula and Script code. They are not a general fallback
for arbitrary precompiled vertices.

#### Recommendation

Define two honest Flow port forms:

- native typed ports use `RequiredInput<T>` and require a native projection assignable to `T`; and
- structural ports use `RequiredInput<DataValue>` or a stable `RecordView` interface.

Dynamically generated expression code may place a typed façade over the structural form without implying that
every Flow SPI can do so.

### 4.2 Graph-created data classes have contradictory v1 behavior

The automatic baseline makes Kotlin data classes structural records. The graph section acknowledges that a
graph-created data class follows that ordinary baseline because class-based lifting cannot recover its graph
provenance. The snapshot section and adoption gate nevertheless say every graph-created object is opaque and
snapshot-rejected in v1.

Both cannot be true without the deferred provenance seam. A graph-created data class may also contain
service-injected or infrastructure-valued constructor properties, so automatic data-class expansion can bypass
the later graph exposure policy.

#### Recommendation

Choose one v1 rule explicitly:

1. graph-created data classes behave exactly like ordinary data classes and may be structurally exposed and
   snapshotted; or
2. the graph boundary supplies a wrapper/provenance marker in v1 so every graph object can be forced to Opaque.

The second rule is safer but pulls a minimal provenance seam into v1. The current proposal cannot promise it
while simultaneously deferring that seam.

### 4.3 Binding validation exposes existing output-signature defects

The migration discussion calls out omitted inputs, but required-output validation also changes current behavior.
The known Report contract declares `main: String` while `ReportRun.run()` returns `TupleValue.empty`. A builder
that checks every required output at settlement will fail this existing path.

The plan must inventory and resolve input and output signature discrepancies before enabling strict binding
construction. Report's correct result is a product decision — status, row count, output reference, Unit or no
declared component — rather than something the generic binding layer should guess.

### 4.4 Snapshot duration is not enforceable over one blocking accessor

`SnapshotPolicy.maximumDurationMillis` can be checked between node reads. It cannot preempt one native getter,
row accessor or adapter call that blocks beyond the limit.

Either `ValueAccess` operations must be non-blocking by contract, or duration is best-effort unless snapshotting
runs through an interruptible/cancellable execution boundary. The policy should not promise a hard bound that
the synchronous accessor API cannot enforce.

## 5. Scope and ownership inconsistencies

### 5.1 The constraint layer is both deferred and required by v1

The v1 table defers the constraint-layer container, while the adoption gate requires a symbol-set constraint that
`validate` enforces for enums. The sequencing section also puts the container in the first foundational step.

Choose one:

- include a minimal, fully specified constraint vocabulary in v1; or
- remove enum-constraint validation from the v1 gate and add the whole layer with its first schema consumer.

The second is simpler unless the one-or-many Union consumer also needs constraints.

`Decimal(precision, scale)` currently compounds the ambiguity. Precision and scale are described as an access
type's storage hint, validation constraints and provider representation metadata. That risks three homes for the
same facts. Since generic decimal access is unchanged and the first database provider is deferred, v1 can use an
unparameterized `Decimal` and add validation/provider metadata with their consumers.

### 5.2 Direct `FlatFileRecord : ValueAccess` rests on a disputed SPI premise

The proposal says `kzen-auto-plugin` has no external contract worth protecting beyond the sample plugin. The
kzen-auto guide and architecture instead call it the public, stable contract for third-party plugins. One premise
must become authoritative before this dependency decision is used as design evidence.

Direct implementation also moves header/type lifecycle into a mutable record buffer whose existing `copy`,
`clone`, `exchange`, empty-record and append operations currently manipulate contents independently. Whether each
operation copies, preserves or swaps the header becomes new public behavior.

The allocation argument against `FlatRecordAccess(header, record)` is not established. Today's pure-flat path
already allocates `JobMessage` and `FlatView` per row. Replacing them with `DataValue` plus a dedicated access
object may be allocation-neutral while keeping storage and semantic access separate.

#### Recommendation

Prototype and benchmark both forms before exposing `ValueAccess` directly from the plugin record. Prefer the
wrapper unless direct implementation demonstrates a material end-to-end benefit. It is easier to remove a proven
wrapper later than to retract a foundational interface from a public Java SPI.

### 5.3 Composed overlays are already required by the stated Job cutover

The v1 summary appears to defer composed overlay chains, but the Job section requires a `Composed` backing for a
calculated column over a native object or typed row, and the adoption gate benchmarks repeated overlays. Existing
payload-lane Formula behavior makes this a current consumer, not a hypothetical database extension.

This can be simplified alongside the explicit `JobElement` recommendation: materialize a non-flat column
projection once into an owned flat record when the first column-mutating Worker needs it, then retain the existing
append hot path. The independent payload remains in its own slot. That removes composed overlay chains from v1
without losing the existing dual transformation behavior.

## 6. Proposed smaller coherent model

The following shape preserves the required behavior while reducing cross-cutting policy:

1. **`DataType` is purely structural and common/serializable.** It includes tagged Union in v1.
2. **`DataValue` provides read-only structural access over specialized backings.** It has no compulsory detached
   tree representation.
3. **Native projection is a JVM-local capability.** Runtime identity uses `KType` / `Class<?>` plus the defining
   classloader. `ClassName` is diagnostic metadata only.
4. **Boundary requirements are explicit.** A consumer asks for structural compatibility, native compatibility,
   or both; it is not inferred merely from the presence of a class-name annotation.
5. **All v1 values are reachability-owned.** Borrowed values use a later, distinct API rather than an unenforced
   run-lifetime promise.
6. **`BindingSchema` / `DataBindings` remain.** Enumeration, defaults, origins, sensitivity and missing/null
   distinction justify the separate boundary vocabulary.
7. **Job transport is allowed to be a product of typed values.** Its payload and columns remain distinct where
   existing Workers make them distinct; each uses the unified value model.
8. **Column mutation materializes once, then appends.** No composed overlay chain is needed in v1.
9. **Generic record `join` is conservative.** Order-aware superset normalization remains consumer-owned.
10. **Flow distinguishes native typed ports from structural ports.** Generated façades remain an expression
    compiler feature rather than a universal SPI promise.

This keeps the valuable unification point — types, values and bindings — while dropping the stronger and
currently false claim that every native payload, structural view and evolving Job column set is one semantic
value.

## 7. Recommended disposition before planning

The proposal is ready to become a plan after it:

- resolves Job's independent payload/column behavior;
- replaces or augments `ClassName` with classloader-aware runtime identity;
- defines full versus structural contract equality and digesting;
- states the post-publication mutation contract;
- strengthens v1 lifetime to cover returned results;
- completes Union-to-Union assignability and ordered-record join rules;
- separates native and structural Flow port façades;
- chooses truthful graph-data-class behavior;
- settles whether the plugin artifact is a stable public SPI; and
- removes the constraint/composed-overlay/output-validation inconsistencies from the v1 scope.

The structural type/value/binding direction should be retained. The strongest pushback is against using
`DataContract.native` and "one Job element = one semantic value" as the mechanisms that deliver it: those two
choices currently hide distinctions the required behavior still needs.
