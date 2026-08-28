# DM7b — DataValue channels, source producers, and column Workers

> **Status: ready after DM7a. One kzen-auto implementation session.** Authority: unified data model §§6.2,
> 11.4–11.5 and §14.5 step 4. Constituent tracker: `README.md`.

## Outcome

Job channels/batches move `DataValue`; data-source cursors emit `DataValue`; source and ordinary column Workers use
`ColumnProjection` directly. Formula replacement, result sinks, and nested hosts remain green through the DM7a
single-authority façade until DM7c.

## Preconditions and anchors

- Re-check `JobChannel`, producer/input batches, migration drain/adoption, `WorkerBase`/transform/source/sink loops,
  `DataCursor`, `DataReadCore`, `ReadWorker`, `ReadPartWorker`, `FormulaSourceWorker`, filters, sort, summary, preview,
  CSV/export writers, and every channel ownership test.
- DM3's `LegacyCursorItemKind` has exactly this session as deletion owner.

## Implementation

1. Change Job transport and Worker core loops to `DataValue`, preserving batching, checkpoints, deadlock counts,
   cancellation, migration, progress, and DM6's move/alias proof.
2. Change `DataCursor` to `Iterator<DataValue>` with its non-null canonical shape. Flat file cursors emit the DM5
   backing; native/formula cursors lift through the registry. Delete `LegacyCursorItemKind` and all dispatch based on
   flat-versus-payload carrier history.
3. Migrate `DataReadCore` and source Workers. Superset normalization is a `ColumnProjection`; attributes compose as
   leading record fields; optional absence is data state and `<missing>` remains display policy.
4. Migrate filters, sort, summary, preview, CSV/export writers, and other column-only Workers to
   `ColumnProjection`. Preserve `ColumnValue` coercion, header order, duplicate labels, and typed primitive paths.
5. At unmigrated Formula/sink/host boundaries, adapt through `LegacyJobElementView` backed by the same `DataValue`.
   Do not materialize a second payload/flat pair or restore `boundaryValue()` precedence.
6. Update migration/carry-over tests to prove values remain readable and exclusive ownership transfers at most once.

## Proof and exit

- Run source/cursor, channel/batch/migration, and every migrated Worker test plus the full kzen-auto build.
- Prove flat input is not eagerly materialized, field reads allocate no wrapper, and aliased/fan-out elements copy.
- `rg "LegacyCursorItemKind"` is empty; `JobMessage`/`LegacyJobElementView` uses are restricted to the named DM7c
  remainder. The repository ends green before Formula/sink/host migration begins.
