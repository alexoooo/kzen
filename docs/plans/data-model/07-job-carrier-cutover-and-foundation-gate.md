# DM7 — one-value Job carrier cutover and foundation gate

> **Status: ready after DM6. One implementation session.** Authority: unified data model §§11.4–11.5, 14.5 step 4,
> and the complete foundation gate in §15.

## Outcome

Every Job lane/channel carries one `DataValue` with one `DataContract`. `JobMessage(payload, flat)`, its hidden
boundary precedence, and `WorkerLane(payloadType, flatColumns)` are deleted. All existing Workers consume native or
column capabilities from the one value, and the measured foundation gate decides whether the wider cutover may
continue.

## Preconditions and blast-radius inventory

- DM1–DM6 are green and their benchmark records exist. Re-run `rg "JobMessage|WorkerLane|flatView|boundaryValue"`
  and enumerate every producer, transformer, sink, host, cursor, migration state, trace, and test before editing.
- Re-check source readers (`DataReadCore`, `ReadWorker`, `ReadPartWorker`, `FormulaSourceWorker`), all column Workers,
  `ResultSinkWorker`, `RunWorker`, `JobControl`, `EngineJobControl`, `JobRun`, `JobChannel`, and notation fixtures.
- Do not combine J4/J9/J6 implementation with this cutover. J5a's baseline harness is reused; it is not rewritten
  to make the new path look favourable.

## Implementation

1. Replace lane analysis with one `DataContract` (and JVM-resolved companion where static `KType` exists). Unknown
   lanes use `Dynamic`; column capability is derived by `ColumnProjection`, not stored as parallel columns.
2. Change Job channels/batches and Worker APIs to move one `DataValue`. Preserve batching cadence, checkpoints,
   cancellation, deadlock accounting, migration adoption, and progress semantics.
3. Cut every source producer over: flat parsers emit the DM5 backing; native formulas lift through the registry;
   data-source cursors become `Iterator<DataValue>` with non-null shape. Unit attributes compose as leading record
   fields rather than a second carrier.
4. Cut every column Worker over to `ColumnProjection`; preserve `ColumnValue` semantics and optional-absence
   rendering. Calculated columns use DM6 builders and exclusive transfer.
5. Cut `FormulaWorker` to publish the single value proved in DM6. Update notation/config for `carry` and explicit
   rename while preserving the existing combined-expression scope.
6. Change result sinks and `RunWorker` arguments to pass the same semantic value. Remove all map materialization and
   payload-wins rules from Logic boundaries.
7. Delete `JobMessage`, `WorkerLane`, `FlatView` if no non-legacy owner remains, DM6 bridges, and superseded tests/
   comments in the same change. Keep neutral header/column primitives still used by projection and Report.
8. Update Job/data-source architecture docs with pointers to the unified model; do not copy its rationale.

## Foundation-gate run

Execute every item in unified-model §15's foundation gate, not a representative subset:

- literal/flat/data-class parity and declared CSV type retention;
- widening, replacement, carry order/collision, combined Formula scope, and original/new native identity;
- exclusive append, sender invalidation, trace/fan-out aliasing, freeze/digests/resolved keys;
- direct-vs-wrapper result from DM5; and
- throughput/allocation: median representative Job path within five percent of the recorded current baseline,
  allocation-free primitive reads, no per-field `DataValue`, no eager flat materialization, and one native
  projection across N calculated columns.

If the five-percent gate fails, stop. Profile and either repair the implementation or return to the last green
bridge; do not waive the gate because the API is cleaner. Any justified capability cost needs user approval and an
explicit amended threshold in the authority document.

## Verification and exit

- Run focused data-source/Job/worker/migration tests, `FormulaStepTest` canary, then full `./gradlew build` from
  `../kzen-auto`. Re-run the benchmark in a fresh JVM with the same data, warmups, heap, and Java 26.
- `rg "JobMessage|WorkerLane|flatView\(|boundaryValue\("` finds no production legacy carrier use.
- Publish all kzen-auto artifacts to Maven Local and rebuild standalone `../kzen-project`; do not bump versions.
- Mark the foundation gate pass/fail with raw numbers in the as-built section. DM8 cannot start on a failed gate.
