# DM14 — constraint layer, first constraint: text symbol sets

> **Status: complete 2026-09-23 (drafted 2026-09-22).** Authority:
> [`docs/analysis/2026-08-27_data-model.md`](../../analysis/2026-08-27_data-model.md) §4.4 ("A constraint layer
> owns value restrictions"; "Enum is deliberately not a scalar kind"), §13.14, and §17 open questions 3 and 6.
> This session opens the deferred constraint layer because a declaring schema now supplies its first constraint,
> which is the trigger §4.4 names. It does not reopen the enum-as-kind decision.

## Outcome

A `DataContract` can declare that a text position holds one of a closed, ordered set of symbols. For example,
an archive listing's `kind` is `Text ∈ {file, directory, link, other}`. The declaration travels with the contract
across the wire, into lanes, through child navigation and record composition, and into the client contract view.
`DataValueAlgebra.validate` enforces it. The type algebra never reads it: access, `isAssignable`, `join`, variant
selection and the structural digest are unchanged.

The two first producers are the archive listing (`ArchiveListingCursor.kind`) and JVM enums described by the native
resolver. HS13 lowered enums to plain `Text` pending this layer.

## Decisions

1. **Constraint, not a scalar kind.** A symbol set does not change how a generic consumer reads the value; it is
   text (§4.4). `ScalarKind` gets no new case, so the ~140 `ScalarKind.Text` sites and every exhaustive `when`
   stay untouched. Enum identity in `join` (§17 Q6, the Avro reopening) stays closed.
2. **Container: path-aligned, beside `nativeByPath`.** `DataContract` gains
   `constraintsByPath: Map<DataTypePath, List<DataConstraint>>`, with at most one constraint per kind at a path.
   It follows native metadata's rules: it is defensively copied, validated at construction and rebased by
   `child()` / `expanded()`. It is part of equality and the declaration digest, but not the structural digest.
   This answers §17 Q3 for constraints only. Representation metadata (precision/scale, temporal precision,
   affinities) stays deferred, so the container is named for what it holds, not as a general metadata bag.
3. **`DataConstraint` is a sealed interface with one case, `SymbolSet(symbols: List<String>)`.**
   - The list is non-empty and holds distinct symbols in declared order. That order is presentation order: for
     a JVM enum it is ordinal order.
   - The type algebra never compares sets, so order carries no algebraic meaning and needs no canonical sort.
   - A symbol set is valid only at a path whose type is `Scalar(Text)`. That includes a mapping key, because a
     `Map<Enum, V>` key is text. Null stays governed by nullability, not by the set.
   - Paths cannot cross a `Reference`, so a constraint cannot sit inside a recursive definition. A
     `definitionConstraints` map waits for the first recursive declaring schema. Until then a producer drops
     constraints inside definitions: that states less, which is sound.
4. **Dropping a constraint is always sound; inventing one never is.** A rebuild site that does not carry
   constraints yields a weaker but truthful contract. Propagation therefore only has to be *complete* along the
   paths this session proves (see Implementation step 4), and *never fabricated*.
5. **Enforcement.**
   - `validate` checks the *expected* contract's constraints: a present, non-null text node, or mapping key,
     outside the set is a new `DataProblem.constraintViolation`, with a path.
   - Producers are not re-validated per record (hot path). A producer that declares a set is responsible for
     honouring it, and tests prove it.
   - Snapshot decoding already calls `validate`, so persisted values are checked for free.
6. **Wire stability.** The `constraints` key is omitted when empty, as `definitions` already is. Every existing
   contract therefore keeps a byte-identical encoding and declaration digest: cache identities, Job
   compatibility keys and persisted snapshots are unaffected. An unknown constraint kind on decode is
   `invalidTypeEncoding` (fail fast, CC-08).
7. **Presentation.**
   - A constrained scalar renders as `Text ∈ {file, directory, link, other}`.
   - Beyond six symbols it shows the first five plus `…`, with the full ordered list in the tooltip title and
     the details list.
   - Display order is declared order.

## Preconditions and coordination

- Confirm DM14's row is open in this README's tracker and in `docs/plans/2026-07-25_master-plan.md`.
- DM14 is independent of the J5b → J4 → J9 spine. It touches `DataReadCore` and `RecordOverlay`, so do not
  overlap it with a spine session editing those files.
- Read `../kzen-lib/AGENTS.md`, `../kzen-lib/docs/architecture.md` and `../kzen-auto/AGENTS.md` in the
  execution session, and re-check every anchor below. No release-train version bump (CC-14).
- kzen-auto's `jvmMain`/`jsMain` consume kzen-lib through mavenLocal (umbrella AGENTS.md, variant-suffix
  gotcha), so `publishToMavenLocal` from kzen-lib precedes any kzen-auto compile.
- **Capture the goldens first.** Before any code change, record the encoded form and declaration digest of a
  representative set of unconstrained contracts (scalar, record with natives, recursive with definitions). These
  goldens prove Decision 6.

## Current anchors to re-verify

- kzen-lib `exec/data/type/DataContract.kt`:
  - the `nativeByPath` / `definitions` / `definitionNatives` fields;
  - `childCache` rebasing, `expanded()`, `asExecutionValue` / `ofExecutionValue`;
  - `validateNativeMetadata()`, `typeAt`, `walk`.
- kzen-lib `exec/data/value/DataValueAlgebra.kt`: `validate` / `validateNode` / `validateScalar`.
- kzen-lib `exec/data/problem/DataProblem.kt`: the code vocabulary.
- kzen-lib jvmMain `exec/data/type/DefaultNativeTypeResolver.kt`: the enum branch, plus the
  definition/`definitionNatives` emission for recursive classes. `NativeObjectValueAccess.kt` (`scalarValue`)
  already lifts an enum as its constant name.
- kzen-auto `data/read/archive/ArchiveListingCursor.kt`: `kindFile` / `kindDirectory` / `kindLink` /
  `kindOther` and `contract`.
- kzen-auto hand-rolled contract composition that rebases `nativeByPath`:
  - `objects/job/value/RecordOverlay.kt`: `compose`, `recordContract`;
  - `objects/job/worker/data/DataReadCore.kt`: `combineContract`, which also drops `definitions` today;
  - `objects/job/value/RecordOutputBuilder.kt`: `Schema.of`, root native only;
  - `objects/job/worker/JobLaneDescriptor.kt`: `fromLegacy`.
- kzen-auto-js `objects/document/job/display/DataContractPresentation.kt` (`typeLabel`, `typeTitle`, `contract`
  details) and `display/contract/ContractTreeNode.kt`.

## Implementation

1. **kzen-lib: vocabulary and container.**
   - Add `DataConstraint` (sealed) with `SymbolSet` in `exec/data/type`, with construction checks.
   - Add `constraintsByPath` to `DataContract`, then:
     - validate it in `init`: the path exists and does not cross a reference, the constraint kind suits the type
       at that path, and there is one constraint per kind;
     - include it in equality, `hashCode`, `toString`, encoding/decoding (Decision 6) and the declaration digest;
     - rebase it in `childCache` and `expanded()` exactly as natives are rebased.
   - Add `DataProblem.constraintViolation` and `DataProblem.invalidConstraint`.
2. **kzen-lib: composition primitive.**
   - Add one composition function to `DataContract`'s companion. It builds a record from ordered
     `(DataField, child DataContract)` pairs and a nullability, and carries all path-aligned metadata under each
     field prefix: natives, constraints, definitions and definition natives.
   - A conflicting definition or definition native fails with a `DataProblem`, as `RecordOverlay.compose`
     already does.
   - This is the one place prefix rebasing lives. Without it, every hand-rolled site would need a second map
     copied in step (feedback: fix the root-cause complexity).
3. **kzen-lib: enforcement and native producer.**
   - `validateNode` checks the expected contract's constraint at the current path for present non-null text,
     and for mapping keys via `keyAt`.
   - `DefaultNativeTypeResolver` attaches `SymbolSet(constants by ordinal, by name)` to an enum position, except
     inside an emitted definition (Decision 3).
   - The lifted value's contract must equal the described contract: HS13's invariant, now with the constraint.
4. **kzen-auto: producer and propagation.**
   - `ArchiveListingCursor.contract` declares the symbol set on `kind` from the four existing constants: one
     source for both values and set.
   - Replace the hand-rolled rebasing in `RecordOverlay.compose` / `recordContract` and
     `DataReadCore.combineContract` with the step-2 primitive. `DataReadCore` stops dropping `definitions` as a
     side effect; record that in the as-built.
   - `RecordOutputBuilder.Schema.of` and `JobLaneDescriptor.fromLegacy` build from bare fields and keep dropping
     per-field metadata (Decision 4). List them in the as-built as known weakening sites rather than widening scope.
5. **kzen-auto-js: presentation.**
   - `DataContractPresentation.typeLabel` / `typeTitle` render the root constraint (Decision 7).
   - `contract()` details list any nested constraints by path, as it does for JVM natives.
   - `ContractTreeNode` needs no change: each child is a rebased contract.
6. **Docs (CC-20 canonical homes):**
   - the analysis doc: §4.4 "deferred" becomes "opened by DM14 for symbol sets", with §17 Q3 answered for
     constraints and Q6 unchanged;
   - `../kzen-lib/docs/architecture.md`: the contract anatomy;
   - `../kzen-auto/docs/architecture.md`: the archive listing sentence, which now says `kind` is a symbol set.

## Proof

- **kzen-lib common (`jvmTest` + `jsTest`):**
  - Construction rejections: empty or duplicate symbols; non-text path; missing path; path through a reference;
    two constraints of one kind.
  - `child` / `expanded` rebasing.
  - Structural digest equal and declaration digest different, constrained vs unconstrained.
  - Unconstrained encodings and digests byte-identical to the pre-change goldens.
  - Round trip of constrained contracts on JVM and JS.
  - `isAssignable` / `join` tables unchanged in both directions between constrained and unconstrained text.
  - `validate`: a violation with its path, a nullable null accepted, a mapping-key violation, and an unconstrained
    expected contract accepting any text.
  - The composition primitive carries all four maps and rejects conflicting definitions.
- **kzen-lib jvm:**
  - An enum property describes to `Text` plus its symbols in ordinal order, and a constant with a body resolves
    the same.
  - The lifted contract equals the described one.
  - An enum inside a recursive definition carries no constraint.
  - A snapshot round trip rejects an out-of-set value.
  - `PlainObjectShapeTest` expectations are updated to the constrained contracts.
- **kzen-auto:**
  - The archive listing contract carries the set.
  - A tar fixture with a file, a directory, a symlink and a hard link validates every produced row against the
    contract.
  - `JobValidatorTest`'s archive case (the static contract from `FilenameDetection`) sees the set.
  - A File step with file attributes, and a Formula carry, keep the constraint on `kind`.
  - A JS `DataContractPresentation` test covers the label, truncation and tooltip.
- **Commands:**
  1. `cd ../kzen-lib && ./gradlew build publishToMavenLocal`
  2. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest"` (the canary), then
     `./gradlew build`
  3. `cd ../kzen-project && ./gradlew build` (the cross-repository publication rule)
- **Manual:** the Job-1 `.tar.gz` File step's contract tree shows `kind: Text ∈ {file, directory, link, other}`.

## Exit criteria

- One constraint kind exists, with no representation metadata. No `ScalarKind` case is added, and the type
  algebra is byte-for-byte unchanged in behaviour.
- Every existing contract encodes and digests exactly as before.
- Every rebuild site either carries constraints through the step-2 primitive or is listed in the as-built as a
  known weakening site.

## Out of scope (named follow-ups)

- **Authored symbol sets.** The schema editor and `AuthoredRecordSchema`, plus the delimited reader's decode
  policy enforcing them per ST17. This is the next declaring-schema consumer.
- **A Filter/Sort dropdown fed by a symbol set.** This is the first consumer that *reads* the constraint for UX.
- **Constraints inside recursive definitions** (`definitionConstraints`).
- **Other constraint kinds** (length, range, precision/scale), and representation metadata.
- **Enum identity in `join`** (§17 Q6), which reopens only with a carried-schema format that needs it.

## As built — 2026-09-23

- **Container and vocabulary as planned.** `DataConstraint` (sealed, one case `SymbolSet`) and
  `DataContract.constraintsByPath` in kzen-lib `exec/data/type`. The three pre-change goldens (scalar, record with
  natives, recursive with definitions) encode and digest identically (`DataContractConstraintTest`). Symbols are
  canonical scalar text, so a later non-text set needs no wire change.
- **Enforcement covers both sides.** `validate` walks the value's own contract, so it enforces the value's
  constraints *and*, alongside, the expected contract's (`declared`). A plain `Text` value validated against a
  constrained expectation is still checked. `LiteralDataValues.lift(value, expected)` now adopts `expected`'s
  constraints along with its structure.
- **Correction — snapshots do not carry constraints.** `DataSnapshot` is `{DataType, value}`, so a decoded
  snapshot has an unconstrained contract; Decision 5's "persisted values are checked for free" was wrong, and the
  proof item "a snapshot round trip rejects an out-of-set value" was dropped. Validating a decoded snapshot
  against a constrained expected contract does enforce the set.
- **Composition primitive is an instance method**, `DataContract.withFields(additions)`, not a companion builder:
  every caller already holds a base record. Collisions are `DataException(invalidRecord)` (was
  `IllegalArgumentException` in `RecordOverlay`); conflicting definitions are `invalidContract`.
  `RecordOverlay` (append, carry, scalar-to-record) and `DataReadCore.combineContract` delegate to it, so
  `DataReadCore` now carries `definitions`/`definitionNatives` it used to drop. No dedicated end-to-end test for
  the `attributes=columns` path; it is the same delegation.
- **JVM producer.** `DefaultNativeTypeResolver` attaches the ordinal-order set at every expanded enum position,
  including list elements and map keys; behind a recursive `Reference` it is dropped (sound). The runtime lift
  matches `describe`. Fixing that exposed a pre-existing gap: an enum-keyed `Map` fell back to the star-projected
  map description at runtime. `DefaultDataAdapterRegistry` now accepts enum keys as text, as design time already
  did.
- **Archive listing.** `ArchiveListingCursor.contract` declares `{file, directory, link, other}` on `kind`. Its
  tar-fixture test (directory, file, symlink, hard link, FIFO) exposed a pre-existing misclassification:
  commons-compress's `isFile` holds for FIFOs and devices, which were listed as `file`. They are now `other`.
- **Client.** `DataContractPresentation` renders `Text ∈ {…}` (first five plus `…` beyond six), the full set in the
  title, and nested constraints by path in the details. `ContractTreeNode` is unchanged.
- **Known weakening sites (Decision 4):** `RecordOutputBuilder.Schema.of` and `JobLaneDescriptor.fromLegacy` build
  from bare fields and drop per-field constraints.
- **Found, not fixed:** `DataValueAlgebra.validate` on a natively lifted record with an `Int` field reports
  `data.invalid-value` ("Scalar 40 does not conform to Integer"): native access yields a number where
  `validateScalar` expects integers as canonical text. It predates DM14 and does not touch constraints.
- **Pre-existing red test:** `JobRunWorkerTest.perUnitChildBindsNamedDateAndYieldsOrderedFingerprintedRefs` fails
  the same way with both kzen-lib and kzen-auto at HEAD (a `SingletonList` reaches the child's `String`
  `flatDate` argument). Every other kzen-auto test passes with DM14.
- **Verification:** kzen-lib `build publishToMavenLocal` green; kzen-auto `build` green apart from the red test
  above (the `FormulaStepTest` canary passes); kzen-project `build` green. Not run: the manual Job-1 contract-tree
  check.
