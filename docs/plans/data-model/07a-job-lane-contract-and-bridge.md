# DM7a — Job lane contract and green static façade

> **Status: landed 2026-08-28.** Authority: unified data model §11.4 and
> §14.5 step 4. Constituent tracker: `README.md`.

## Outcome

Static Job analysis has one authoritative `DataContract`, while the runtime remains green through a temporary
single-authority compatibility façade. `WorkerLane` no longer owns parallel payload/column descriptions; legacy
callers can read their old view only by projecting the canonical contract.

## Preconditions and inventory

- DM1–DM6 and J5a are green. J4/J9/J5b/J6 are frozen through DM7c.
- Re-run `rg "WorkerLane|payloadType|flatColumns|consumerFlatColumns|boundaryType"` across production and tests.
- Re-check `JobValidator`, every `payloadFlow` override, `WorkerLaneContext`, `CalculatedColumnEval`, source shape
  propagation, editor lane summaries, and dynamic-loader cache keys.

## Implementation

1. Introduce the canonical Job lane descriptor around `DataContract` plus an optional JVM-resolved companion.
   Unknown lanes use `Dynamic`; no field stores a second header/payload authority.
2. Convert the static worker walk and connection validation to structural/native acceptance. Formula result lanes
   use the inferred `KType` mapper from DM2; source lanes use DM3 shapes.
3. Keep `WorkerLane` only as a temporary façade over the canonical lane descriptor for unmigrated Worker overrides.
   Its payload/column accessors derive through native metadata and DM6's contract-level projection descriptor; they
   never retain independent mutable state. Name DM7c as deletion owner and prohibit new production callers.
4. Pin static cache/digest identity to the structural/declaration/resolved keys named by the design. Preserve current
   validation error attribution and editor behaviour.

## Proof and exit

- Existing lane-walk tests remain green through the façade; new tests prove façade results change only when the
  canonical contract changes and cannot drift independently.
- Cover flat record, native record, scalar, mapping, dynamic, union, widened record, and native-requiring lane.
- Compile every Worker override and run focused validator/expression/editor-provider tests, then full kzen-auto build.
- End with channels and `JobMessage` unchanged, one canonical static lane, and only the actively used `WorkerLane`
  façade named for DM7c. DM7b introduces its runtime bridge at the first production use rather than landing dead
  production code here.

## As built

- `JobLaneDescriptor` is the sole owner of the lane `DataContract` and optional `ResolvedDataContract`; its legacy
  construction path immediately projects payload and columns into that contract.
- `WorkerLane` retains only the descriptor. Its payload and flat-column members are derived compatibility accessors
  explicitly owned for deletion by DM7c, so they cannot drift from the canonical contract.
- source shapes and inferred formula `KType`s now enter the descriptor through structural/native resolution, while
  declaration, structural, and resolved identities have separate stable cache keys.
- descriptor, validator, formula-source, sink, run-worker, and formula inference tests passed, followed by the full
  kzen-auto build (`75` tasks, `BUILD SUCCESSFUL`).
