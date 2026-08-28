# DM7c — remaining Job cutover, carrier deletion, and foundation gate

> **Status: ready after DM7b. One kzen-auto implementation session.** Authority: unified data model §11.4,
> §14.5 step 4, and the complete foundation gate in §15. Constituent tracker: `README.md`.

## Outcome

Formula transformation, result sinks, and nested Logic hosts publish/pass one `DataValue`; all temporary Job
carrier/lane façades are deleted after the measured foundation gate passes.

## Preconditions and final inventory

- Re-run `rg "JobMessage|WorkerLane|LegacyJobElementView|flatView|boundaryValue"` and classify every remaining
  production/test use. No unclassified caller is migrated by guess.
- Re-check `FormulaWorker`, `ResultSinkWorker`, `RunWorker`, `JobControl`, `EngineJobControl`, trace inspection,
  custom/test Workers, downstream `SampleExtensionTest`, and notation carrying Formula `carry` configuration.

## Implementation

1. Cut `FormulaWorker` to DM6's builder: both expressions see the original input; formula-only widens; payload
   replacement drops widening unless `carry` selects fields; order/collision/rename/native rules stay exact.
2. Cut result sinks and both nested-host forms to the same semantic value. Do not materialize maps or choose a hidden
   payload half. Custom Workers build arbitrary outputs through the unpublished builder.
3. Migrate remaining first-party/test/plugin Workers from the façade. Update sample-plugin sources and
   kzen-project's `SampleExtensionTest`.
4. Run the entire foundation gate while `WorkerLane` and `LegacyJobElementView` still exist but have zero active
   production callers. If throughput exceeds the five-percent regression limit or any allocation/ownership pin
   fails, stop with this green bridge intact and profile; do not waive or delete it.
5. After the gate passes, delete `JobMessage`, `WorkerLane`, `LegacyJobElementView`, `FlatView` where no neutral
   Report owner remains, all conversion bridges, and superseded tests/comments. Run the full build and a confirmation
   benchmark against the same baseline.
6. Update Job/data-source architecture pointers and record raw before/after numbers and deletions in the as-built.

## Foundation proof

- Literal/flat/data-class parity and declared CSV type retention.
- Widen/replace/carry order/collision and same-Worker Formula scope.
- Exclusive move, sender invalidation, snapshot/fan-out aliasing, freeze/digests/resolved keys.
- Native identity, direct-versus-wrapper DM5 verdict, no eager map conversion, allocation-free primitive reads, no
  per-field `DataValue`, one native projection across N calculated columns, and median throughput within five percent.

## Exit criteria

- `rg "JobMessage|WorkerLane|LegacyJobElementView|flatView\(|boundaryValue\("` finds no production use.
- Focused Job/data-source/worker/migration tests, `FormulaStepTest`, full kzen-auto build, sample-plugin build, and
  standalone kzen-project build pass. Publish all kzen-auto artifacts; no version bump.
- Mark the foundation gate pass/fail in `README.md`; DM8 cannot start on failure.
