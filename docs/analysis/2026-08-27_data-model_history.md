# Unified data model — review history

> **Status: historical record, not a design document.** The current contract lives in
> [`2026-08-27_data-model.md`](2026-08-27_data-model.md); this file preserves the disposition of every design
> review finding folded into it, so that each review's file could be deleted without losing the trail of what
> was challenged and why the proposal answered as it did. Where a row here disagrees with the owning proposal,
> the proposal is right and the row records what was true when that review was folded.


Every review's file was removed after the revision that folded it; these tables are their permanent record.
"Adopted" means the finding is applied above as stated; "modified" means the diagnosis is accepted with a
different fix; "declined" means the finding is not applied, with the reason.

### 1 First review

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

Two first-review dispositions were later superseded by the second review: per-root `Detached | Owned` retention
(now the reachability rule, §6.2, UD23) and the native annotation as a field of `DataType` (now the recursive
`DataContract`, §4.1, UD21).

### 2 Second review

| Review finding | Disposition |
|---|---|
| Native projection is a value capability, not a structural type facet; use a recursive `DataContract(structural, native)` | Adopted — `DataContract` at every position, structural-only identity and digests, snapshots strip the facet; the facet is a bare `ClassName` rather than `TypeMetadata`, which removes the duplicated nullability / generics the review also flagged (§4, §4.1, §13.6, UD21) |
| `KType` / `TypeMetadata` mappings are not available from the proposed information; native assignability must not become class-name comparison; adapters need a static description | Adopted — JVM `KType → DataContract`, lossy `TypeMetadata → DataContract`, conditional `DataContract → TypeMetadata`, native assignability delegated to the JVM resolver, `DataAdapter.describe`, registrations keyed by class identity (§4.7, §7.3, UD33, UD34) |
| Ownership vocabulary is not enforced by its API; "until cursor closes" is too weak; append needs exclusivity, not retention inference | Adopted — run-lifetime rule replaces `Detached | Owned` and `isAlive`; unpublished-value precondition for owned-append (§6.2, §11.4, §13.19, UD23, UD27) |
| Snapshot grammar cannot represent the stated v1 contract (duplicate fields, redaction, native round-trip, string paths) | Adopted with one smaller fix — `Redacted` result, structural-only envelope, opaque values reject, `DataPathSegment`; duplicate fields lower through the shipped `HeaderLabel.render()` rule with collision rejection rather than an ordered-entries encoding, which is deferred to the grammar (§12.1, §12.2, UD14) |
| Recursive data types are not representable | Adopted — expansion stops at the recursive position with `Opaque` (§7.2, §13.21, UD36) |
| Direct `FlatFileRecord : ValueAccess` is premature; start with `FlatRecordAccess(header, record)` and protect the SPI | Declined on the SPI argument — the dependency decision was made on the absence of any external contract, not on performance; adopted on the technical point — the record carries a reference to its shared header (§6.1, §13.17, UD28) |
| Assignability and implicit selection are different relations; name them so and require selection for untagged values | Adopted — stated explicitly; the existing `selectVariant` / `validateVariant` names are kept (§4.5, §4.7) |
| Selection must construct a tagged union node | Adopted — lifting against an expected union wraps exactly once (§4.5, §7.3) |
| Structural selection cannot distinguish native alternatives | Adopted — `selectVariant` takes the caller's `DataRequirement`; Formula-declared class unions select natively (§4.5, §4.7) |
| Record-width rules are part of decoding semantics | Adopted — paired tests (§4.5, §15) |
| Union needs a named first consumer or is deferred | Declined — `List<String> \| String` (one-or-many) is the named consumer, a common authored-configuration and JSON pattern; the incremental cost over the already-specified algebra is one union-root backing plus test surface (§4.5, §15) |
| Defaults are construction policy, not runtime structural type | Adopted — `DataField.optional`; `DataPresence.Defaulted` on bindings only; reader defaults in the schema contract (§4.2, §4.3, §10, UD30) |
| Enum rationale points to a missing constraint layer | Adopted — explicit two-layer rule; enum, precision/scale-as-validation, ranges and defaults in the constraint layer (§4.4, UD32, §17 Q3) |
| `FieldId` is unique but not evolution-stable | Adopted — stable within one schema version; provider IDs for rename-stable formats (§4.2, UD25) |
| Dynamic mapping keys lack scalar identity | Adopted — a present mapping reports a concrete key kind; mixed-key native maps stay `Opaque` (§4.3, UD22) |
| Full binding-time validation conflicts with lazy access | Adopted — shallow bind checks, explicit deep `validate` (§4.7, §10, UD31) |
| Graph provenance cannot be recovered by class-based lifting | Adopted — v1 graph objects lift through the ordinary baseline and their snapshots reject; stable-reference lowering waits for the provenance seam (§8, UD10, §17 Q1) |
| Result-builder concurrency and overwrite semantics missing | Adopted — `JobResultCollector` semantics preserved verbatim (§10, UD35) |
| `DataShape` provenance does not match the project-data analysis's "chain" | Declined — that "chain" is the resolution ladder (which rung is tried first), not an evidence chain the shape retains; the single value records the winning rung and disagreement is a diagnostic. The project-data analysis's heading is reworded to "ladder" to prevent the misreading (§5) |
| Database temporal coverage needs `LocalDateTime` | Adopted — distinct kind with the first database consumer, never coerced (§4.4, UD17) |
| Unify generic boundaries, not every internal variable and transport | Adopted — `RequiredInput<T>` and step locals stay typed; cutover at generic boundaries (§11.2, §11.3, §13.22, UD38) |
| Keep tabular projection in the first consumer | Adopted — `ColumnProjection` in kzen-auto; no generic `project` (§4.7, §11.4, §13.20, UD37) |
| Defer lifetime states until a resource-backed value forces them | Adopted — with the run-lifetime rule (§6.2) |
| Defer graph-specific behaviour to the graph consumer | Adopted (§8) |
| Keep the initial scalar set consumer-driven | Modified — the sealed vocabulary stays declared because it is cheap and fixes the canonical forms; only the kinds the vertical proof exercises are gated (§4.4, §15) |
| Proposed smaller v1 (eight points) | Adopted except where the rows above say otherwise: Union kept in the language, `FlatFileRecord` direct |

Three second-review dispositions were later revised by the third review: "readable until the run settles"
(now reachability, §6.2, UD23), the `Composed` overlay with a collapse threshold (now materialize-once, §11.4,
UD27), and the enum constraint in the v1 gate (now deferred with the whole layer, §4.4, UD26).

### 3 Third review

| Review finding | Disposition |
|---|---|
| Job payload and columns are sometimes independent results (`FormulaWorker` widens and replaces in one call); carry `JobElement(payload, columns)` | Modified — the diagnosis is verified and adopted; the two-slot carrier is declined because it keeps the precedence rule at every boundary. A Worker widens *or* replaces; the combined transform becomes two Workers, and the native facet keeps the original object reachable after a widening (§11.4, §13.23, UD40) |
| `ClassName` cannot carry classloader identity; `DataContract` equality contradicts "structural identity"; replace with a structural contract plus a JVM `NativeTypeToken` sidecar | Modified — two equalities are named (structural `DataType`, full `DataContract`), the resolver takes the requiring side's classloader and the live backing's `Class`, `Native` acceptance implies structural acceptance; the recursive wrapper is kept and the sidecar declined (§4.1, §4.7, §13.6, UD21, UD33) |
| Mutable native values invalidate "valid by construction"; state a publication rule and its failure semantics | Adopted — publication rule; a read meeting a violation fails with a `DataProblem`; no invalidation machinery; "one source of truth" restated as "no second copy" (§6.2, UD43) |
| "Readable until the run settles" ends before hosted and root results are consumed | Adopted — reachability rule, verified against `RunEngine.host` (§6.2, §13.19, UD23) |
| Ordered records conflict with a commutative `join` | Adopted — conservative join; superset normalization is `ColumnProjection`'s (§4.7, UD41) |
| Union-to-union assignability incomplete; native-only acceptance unsafe | Adopted — three assignability cases, selection and construction rules, `Native` implies structural (§4.1, §4.5, UD42) |
| Mapping-key rules contradict (§4.3 vs §7.2) and leave collisions open | Adopted — concrete kind for non-empty mappings only; null / mixed keys `Opaque`; canonical-key collision fails the lift; no cross-class numeric joins (§4.3) |
| `RequiredInput<T>` cannot receive a generated accessor in a precompiled vertex | Adopted — native typed port and structural port; façades are the expression compiler's (§11.3, UD39) |
| Graph-created data classes have contradictory v1 behaviour | Adopted, option 1 — ordinary data-class behaviour; a service-valued property is an `Opaque` field that rejects the snapshot (§4.1, §8, §12.1, UD10) |
| Strict output validation exposes Report's `main: String` versus `TupleValue.empty` | Adopted — signature inventory precedes strict construction; resolved 2026-08-28: Report declares no output, so the false `main` declaration is removed before strict settlement (§10, §14.5, UD44) |
| Snapshot duration is not enforceable over one blocking accessor | Adopted — best-effort between node reads (§12.1, UD45) |
| The constraint layer is both deferred and required by the v1 gate; `Decimal(precision, scale)` has three homes | Adopted — the whole layer deferred, enum constraint out of the gate and of step 1, `Decimal` unparameterized in v1 (§4, §4.2, §4.4, §14.5, UD26, UD32) |
| Direct `FlatFileRecord : ValueAccess` rests on a disputed SPI premise; header semantics under buffer operations are new public behaviour; the allocation argument is unproven | Declined on the premise, as twice before — the in-development status is the authoritative one and the kzen-auto guide's wording is updated with the change; adopted on both technical points — header behaviour under `clear` / copy / exchange is defined, and direct versus wrapper is benchmarked in the gate (§6.1, §13.17, §14.3, UD28) |
| Composed overlays are already required by the Job cutover; materialize once, then append | Adopted — no `Composed` in v1 (§6.1, §11.4, §13.23, UD27) |
| Proposed smaller coherent model (ten points) | Adopted except point 7 (product of typed values), replaced by the widen-or-replace rule |

Three third-review dispositions were later revised by the fourth review: the bare `ClassName` facet and
consumer-loader resolution (now `TypeMetadata` plus a JVM-local token, unified §4.1), within-contract mutation
after publication (now frozen by contract, §6.2), and the "nothing is lost" claim for the Job split (now an
explicit decision, §11.4 — and then, on the owner's follow-up, closed entirely by the `carry` option, which
expresses the old combined result as one value with an explicit record type).

### 4 Fourth review

| Review finding | Disposition |
|---|---|
| Widen-or-replace does not preserve `FormulaWorker`; "nothing is lost" is false; keep a product or make the removal an explicit product decision | Modified — the false claim is removed; the product is declined; instead a replace takes a `carry` option that appends named previous columns to the new value's materialized projection, so the old combined result is one value with one explicit record type and native facet, and a custom Worker with the `DataValue` can build anything else through the builder (§11.4, §13.23) |
| `ClassName` cannot provide declaration-time native identity; resolving in the consumer's loader erases the producer | Adopted — declaration-plus-token model: in-process declarations keep their `KType` and loader, live values supply their `Class`, name-only declarations are `Provisional` until the first live value (§4.1, §4.7) |
| A bare native class loses arbitrary generics and native variance | Adopted — the facet is `TypeMetadata` again, with the two halves built from one `KType` and nullability agreement enforced by the constructor (§4, §4.1, §13.6) |
| `ValueAccess` lacks a failure carrier, `ValueValidation` is undefined, node identity is unspecified | Adopted — `DataAccessException`, `ValueValidation`, identity through `native(node)` on container / opaque nodes only, scalar leaves never (§4.7, §6) |
| Within-contract mutation and complete snapshots are incompatible; freeze after publication | Adopted — frozen-by-contract publication rule (§6.2) |
| Ordered unions conflict with commutative `join` | Adopted — unions join only when identical, else `Dynamic` (§4.7) |
| Union has no existing v1 consumer; defer | Declined — decided by the owner: one-or-many is in v1 (§4.5) |
| `Mapping(Dynamic, Dynamic)` uses a nullable key | Adopted — `Dynamic(nullable = false)` in key position (§4.3, §7.2) |
| Expected `Opaque(NativeX)` versus actual `Record(…, NativeX)` undefined | Adopted — `Opaque` accepts by facet alone (§4.1, §4.7) |
| Native generic variance is separate from structural variance | Adopted — the `TypeMetadata` facet carries arguments for the compiler probe (§4.1, §4.7) |
| Output order has two authorities | Adopted — schema order; yield chronology is trace metadata (§10) |
| Wholesale rename not yet justified | Adopted — working names; in-place evolution of `TupleDefinition` / `TupleValue` preferred at the spike (§10) |
| Sensitivity has no propagation semantics | Adopted — display policy for one binding, explicitly not taint (§10.1) |
| Direct `FlatFileRecord : ValueAccess` should not be the default; unknown external consumers cannot be excluded by observation | Declined on the premise, as three times before — the owner's statement that there are no external consumers is authority, not observation; the benchmark-before-exposing ordering already stands (§6.1, §13.17) |
| Graph backing row says reference lowering is v1 | Adopted — row corrected (§6.1) |
| Adapter precedence ambiguous | Adopted — exact registration, built-ins, fallbacks (§7.2, §7.3) |
| Typed decode invariant must be stated on `DataDefault` too | Adopted (§12.1) |
| Duplicate-field snapshot lowering is an expensive temporary protocol | Adopted — duplicate-field records reject in v1; ordered-entries encoding with the grammar (§12.1) |
| Project-data analysis still lists `project`; review chronology and the register obscure the design | Adopted — database doc corrected; dispositions moved to this file; the register became a decision index (unified §16) |
| Smaller v1 and a two-tier gate | Adopted in part — a foundation gate scoped to the Job / typed-flat path with cutover gates later (§15); scalar vocabulary stays declared with only exercised kinds gated (§1.2) |
| Alternative: unify semantics, not every carrier | Modified — mostly already the proposal; the residual difference is the Job product; steps 3–4 are the requested prototype (§13.24) |

Two fourth-review dispositions were later revised by the fifth review: the `Provisional`-until-first-value rule
(now explicit resolution in the owner's loader, with `ResolvedDataContract` as the token's carrier, §4.1, §4.7)
and the typed-decode rule on `DataDefault.literal` (now `DataDefault(snapshot: DataSnapshot)`, §4.2).

### 5 Fifth review

| Review finding | Disposition |
|---|---|
| The JVM-local token has no carrier, lifetime or API path; cache keys, join, lane identity and binding validation all need it | Adopted — JVM-only `ResolvedDataContract(contract, token: NativeTypeToken?)` and `NativeTypeResolver`; the common algebra is structural; native compilation caches by the resolved key (§4.1, §4.7, §12.1) |
| A live raw `Class` cannot confirm erased generics; a name-only expected declaration has no identity; `TypeAssignability` cannot be reused as-is | Adopted — name-only declarations are structural until explicitly resolved in the owner's loader, the first value is evidence not authority, producer tokens carry generics, a token-less actual satisfies only non-generic requirements, `Provisional` removed from `TypeAcceptance`; Q7 narrowed to the generic-subtyping half; the v1 facet is the `TypeMetadata`-renderable subset with the token holding the full `KType` (§4.1, §4.7, §17) |
| Publication and in-place Job append contradict: a received element is published | Adopted — Job-internal exclusive transfer on dequeue proven by the transport, trace snapshots never retain, fan-out / replay force copy, `finish()` publishes (§6.2, §11.4, §15) |
| Native scalar interoperability unspecified; a typed cell has no boxed `Int` | Adopted — scalars project canonically through a closed exact-conversion vocabulary that rejects overflow; scalars carry no facet, records still need theirs (§4.1, §4.7) |
| Record width is no longer open — widening plus `Native` forces width-tolerant acceptance | Adopted — width-tolerant assignability (ordered subsequence, extra actual fields allowed, optional never satisfies required); equality and `join` stay exact (§4.7, §4.5) |
| `carry` from the received value does not reproduce the combined `FormulaWorker`; selector, order and collisions undefined | Modified — the review's option 1 rather than its preferred option 2: a Worker widens *or* replaces, combined configurations migrate to two Workers, and `carry: all` after a widening Worker includes its calculated columns; `FieldId` selection, replacement-then-carried order, collision rejection (§11.4, §13.23, §15) |
| `DataDefault` is under-typed and cannot satisfy native bindings | Adopted — `DataDefault(snapshot: DataSnapshot)`, structural declarations only; native-constructing defaults deferred with computed defaults (§4.2, §10, §1.2) |
| Nested-union flattening conflicts with tagged identity and the duplicate-ID error | Adopted — unions are flat in v1, no normalization (§4.5, §4.7) |
| `DataPathSegment.Entry` is not self-describing for non-text keys | Adopted — `Entry(kind, key)` (§4.7) |
| Duplicate-field snapshot rejection names the wrong invariant | Adopted — duplicate *names* (non-zero occurrences) reject; occurrences contiguous from zero in field order (§4.2, §12.1) |
| Identity-less backings need a normative tree invariant | Adopted — tree-shaped invariant; an identity capability arrives with the first DAG-shaped backing (§6) |
| Declaration collections must be frozen defensively; three identities should be named consistently | Adopted — defensive copies in every declaration / envelope constructor (§4); structural digest, declaration key, resolved key (§12.1) |
| Runtime-only collections have no representable native facet | Adopted — no facet without an expected or inferred `KType` (§4.7, §7.2) |
| `binary-handle` has no endpoint, resolver or lifetime in the envelope | Adopted — inline within `maximumBinaryBytes` or reject; external references with the deferred grammar (§12.1, §1.2) |
| `validate` is sequenced before the values it validates | Adopted — type-only step 1, deep `validate` in step 3 (§14.5) |
| The foundation gate contains the bindings cutover gate | Adopted — the nested-Logic assertion moved to the bindings gate; item 5 is now the exclusive-transfer case (§15) |
| The Job gate needs explicit alias and combined-transform cases | Adopted (§15) |
| Editorial: "three" review files, §13.18 after §13.24, stale project-data anchor, identity wording | Adopted — all four corrected |

Three fifth-review dispositions were later revised by the sixth review: the recursive `DataContract` per
position (now a pure `DataType` with native metadata and tokens aligned by `DataTypePath`, §4, §4.7), the single
root token (now per path), and the two-Worker `FormulaWorker` migration (now one combined Worker publishing one
value, §11.4).

### 6 Sixth review

| Review finding | Disposition |
|---|---|
| `DataType` equality still includes nested native facets through `DataField` / `Listing` / `Mapping` / `DataVariant` contracts; structural equality, digests and snapshot types are false for nested native values | Adopted — pure structural `DataType`; `DataContract(structural, nativeByPath: Map<DataTypePath, TypeMetadata>)` validated by the constructor and rebased at schema time (§4, §4.1, §13.6) |
| One root token cannot reach data-class properties or union variants; no actual-side token path; executable boundaries carry no resolved form | Adopted — `ResolvedDataContract(contract, tokenByPath)`, `JvmNativeValueAccess.nativeToken(node)`, resolved companion held by each JVM owner beside the common declaration (§4.7, §6, §10) |
| Common `join` cannot be idempotent while dropping facets | Adopted — the whole common algebra takes bare `DataType`; `join(t, t) == t` (§4.7) |
| Cross-loader assignability is not loader equality; a plugin class implementing a parent-loader interface must accept | Adopted — classifier identity and subtype relation per position, never loader equality; both cases gated (§4.7, §15) |
| Two Workers change the payload expression's column scope | Adopted, the review's option 2 — the combined `FormulaWorker` stays one Worker evaluating against the original input and publishing one value; two authored Workers remain possible (§11.4, §14.5, §15) |
| Unresolved `Opaque` is structurally indistinguishable from `Dynamic` | Adopted — `Opaque` is never satisfied by the structural algebra, only through the resolver (§4.1, §4.7) |
| `DataSnapshot` is typed but not frozen | Adopted — private constructor with a recursively freezing, validating factory (§12.1) |
| Resolved caches need a classloader lifecycle | Adopted — scoped to the plugin / module load generation (§4.7) |
| Union ambiguity example uses the wrong actual | Adopted — `{a, b}` is the ambiguous actual (§4.5) |
| `DataRequirement` and requirement wording survive the API split | Adopted — enum removed; the declaration decides (§4.1, §4.5, §4.7, §10, §11.3) |
| Synchronous trace snapshots should not disable the exclusive transfer | Adopted (§6.2, §15) |
| Recursive data-class snapshots reject at the opaque cut | Adopted — stated in the gate (§15) |
| Document-ownership summary still says "per-node annotation" | Adopted (§14.4) |
| Twelve gate additions | Adopted — folded into §15 |
