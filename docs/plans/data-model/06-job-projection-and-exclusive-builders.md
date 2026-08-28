# DM6 — Job column projection, exclusive transfer, and output builders

> **Status: ready after DM5. One implementation session; prototype seam, not full carrier cutover.** Authority:
> unified data model §§6.2, 11.4, 13.20, 13.23, open questions 4–5, and foundation-gate items 3–5.

## Outcome

kzen-auto owns a tested `ColumnProjection` and unpublished record/output builder. Job transport can prove or deny an
exclusive move, append in place only under that proof, and materialize a native lane once. Formula widen/replace/carry
semantics are executable before the legacy carrier is removed across DM7a–DM7c.

## Preconditions and collision control

- Freeze J4/J9/J5b/J6 work while DM6–DM7c touch `FormulaWorker`, readers/writers, channels, and element ownership.
  J6 fan-out must consume the explicit alias/copy rule after DM7c, not predate it.
- Re-check `JobChannel`, batch/migration carry-over, `JobMessage`, `FlatView`, `WorkerLane`, `FormulaWorker`,
  `CalculatedColumnEval`, filters/sorts/summaries/writers/previews, and `JobElementModelTest`.
- Keep `ColumnValue` coercion (`"13.0" == 13`) and interned constants exactly as current product behaviour.

## Implementation and decision gates

1. Define a kzen-auto-owned contract-level projection descriptor and its value-bound `ColumnProjection` access.
   The static descriptor is derived from `DataContract` before a value exists and owns ordered record fields,
   explicit scalar `value`, and mapping projection only with a declared key policy; runtime-observed mapping keys
   remain value state. Resolve open question 4 in tests: duplicate names render with `HeaderLabel.render`, nested
   fields are not flattened in v1 unless explicitly selected, and `<missing>` is a projection rendering for absent
   optional fields.
2. Add an unpublished record builder that can (a) append to an exclusively transferred appendable flat backing,
   (b) copy/materialize an aliased flat value, and (c) project a non-appendable native/row value once while retaining
   its root native facet. `finish()` freezes and publishes one wider `DataValue`.
3. Extend Job channel delivery with an internal move/alias fact. Prove exclusivity only when topology has one
   receiver, sender retained no alias, trace snapshot completed synchronously, and no replay/fan-out/live inspector
   holds the backing. Receiving alone is not proof.
4. Keep trace inspection snapshot-only. A synchronous completed snapshot permits the later move; a concurrent live
   inspection disables in-place append. Migration transfers ownership exactly once with the physical batch.
5. Implement a private Formula transformation helper over the new builder while `FormulaWorker` still publishes a
   bridged legacy element. Calculated formulas and payload expression both evaluate against the original input.
6. Implement replace `carry`: `FieldId` selection, `all`, optional explicit rename, replacement fields first,
   carried source order second, collision rejection. No carry means the previous widening is dropped.
7. Benchmark flat and native lanes with N sequential calculated columns; native must cost one projection plus N
   appends and lookup must not grow with overlay depth. Do not introduce `Composed`.

## Proof

- Projection tests cover record/scalar/mapping/opaque, duplicate display labels, optional absence, typed vs text
  reads, and no data-level `<missing>` sentinel. For every statically projectable case, prove the descriptor derived
  from the contract agrees in field IDs/order/labels with the projection bound to a conforming value.
- Ownership tests cover exclusive move, sender-use rejection, alias copy, fan-out copy, synchronous trace, concurrent
  inspector, migration, freeze-after-finish, and native-facet retention.
- Formula tests cover widen, replace without carry, selected/all carry, order/collision/rename, one published value,
  and the payload expression's inability to see same-worker calculated fields.
- Benchmark against DM5/J5a numbers and record projection/append counts as well as throughput/allocation.
- Run focused Job/worker/channel tests and full kzen-auto build.

## Exit criteria

- Open questions 4 and 5 have as-built verdicts; no public mutation leaks through `ValueAccess`.
- The bridge is named and has exactly one deletion owner: DM7c.
