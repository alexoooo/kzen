# DS5 — `ReadPartWorker` + migration-safe 1:N execution — implementation plan

> **Status: ready to execute.** Session 5 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§5.4** (the 1:N gap, `ReadPartWorker`, migration-safe expansion, and why `ExpandWorker` is
> demand-driven — O1), §4.3 (self-opening refs; the child-Logic
> shape), §5.6 (a/b — role fan-out and the child-Logic idiom), §3.5 (attributes onto the item lane —
> O22). Constituent plan: **—** (analysis doc is the record;
> delete on landing, as-built → analysis **§13**). Depends on **DS1, DS1b, DS2, DS3**; independent of
> DS4. Anchors verified 2026-08-21. Sized **M**; kzen-auto-jvm + yaml + ribbon entry. Ledger
> row 55. This is the **composition** reader: what the child-Logic idiom and grouped multi-role
> pipelines read with.
>
> ⚠ **`ExpandWorker` is not built here.** A *generic in-memory* stream expander is demand-driven (O1);
> nothing in this arc bridges an effectful read through an expression.

## Scope & goal

```
ReadPartWorker(input: <unit lane>, output: <item lane>, role: "main", attributes: ignore | columns)
```

1. **`ReadPartWorker`** — an `ExpandingTransformWorker`: for each incoming payload (must be a
   `DataUnit`), select `unit.partsOf(role)` (blank `role` = the unit's sole distinct role, else the named
   one; a non-single-role unit with blank `role` fails naming the roles), open the parts in order through
   `DataOpenerLookup` + DS3's `DataReadCore`, and
   emit one message per item — `ofFlat` when `cursor.shape is Tabular`, else `ofPayload`;
   `attributes: columns` widens exactly as `ReadWorker` does (same helper). `payloadFlow` validates the
   input lane's `payloadType` is `DataUnit`; its output shape is statically unknown because it holds no
   source declaration.
2. **Migration-safe 1:N execution** (§5.4) — `ExpandingTransformWorker` owns the active received batch,
   current element index and output cadence. After every output `batchSize`, it flushes and checkpoints.
   Its migration snapshot carries the current element and the unconsumed remainder because both have
   already left the input channel; `JobChannel.drainBuffered` cannot recover them.
3. **Handle ownership** — the open cursor is closed in `onClose` unless detached, and at exhaustion; the
   drive is per-item `runBlockingIo` (DS3's core).
4. **Migration** — the base carries `(activeBatch, inputElementIndex)`; the reader composes
   `(unit, partIndex, itemIndex, open cursor)`. The current unit is replayed from the carried batch against
   the adopted cursor, driven by the new control. Guarded on `role` / `attributes`.

After this session the child-Logic idiom (§5.6b) is expressible end to end: a child Job with a
`unit: DataUnit` parameter, `FormulaSourceWorker("unit")`, and one `ReadPartWorker` per role.

## Dependencies & coordination

- **DS1b landed** — `isNameable` so the unit lane types as `DataUnit`; without it `payloadFlow`'s input
  check sees `Any` and cannot validate (nothing fails loudly — the test is the tell).
- **DS2 landed** — the SPI, `FileDataOpener`, `DataOpenerLookup`. **DS3 landed** — `DataReadCore` (the
  lifted drain core: opener lookup, per-item `runBlockingIo` drive, shape dispatch, attribute widening,
  detach discipline) and `WorkerDataContext`. **This session must not copy any of it** (CC-12); if the
  core does not fit, that is a finding about DS3's extraction, not a reason for a second copy.
- **DS8** is the first real customer (the per-day child Job reads `main` and `reference` with two
  `ReadPartWorker`s); **DS7** first uses it in the per-unit child Job with one `main` role.
- **J6 (fan-out)** untouched — §5.6(a) role fan-out with two `ReadPartWorker`s off one unit lane is
  legal today only via manually declared channels (`JobChannelDerivation` auto-wires single-output
  workers); note it in the KDoc, it is J6's ergonomic relief.
- **`TransformWorker`'s KDoc invariant** ("a parked Worker holds neither a received-but-unforwarded input
  element nor a buffered-but-unflushed output element") remains true. Do not weaken it. The distinct
  `ExpandingTransformWorker` contract owns and migrates the active input batch precisely because it may
  park mid-element.

## Current-state findings (anchors verified 2026-08-21)

- **Why `TransformWorker` cannot host this cadence**: `TransformWorker.drive` — `control.checkpoint()` at the top of the loop, drain
  a batch, `onElement` per element, `emitter.flush()` once per *input* batch. `Emitter.send` buffers;
  `Emitter.sourceCadence(control, onFlush)` is the source-only flush+checkpoint-every-N. A 1:N
  transform emitting a million items per input element buffers them all before one flush. More
  importantly, a checkpoint inside `onElement` would strand the current element and the remainder of the
  received batch on the old coroutine stack; they are no longer in `JobChannel` (analysis §5.4).
- **`TransformWorker.onElement` may call `emit.send` any number of times** — the framework permits 1:N;
  no shipped worker does it.
- **`FormulaWorker`** — receiver = incoming payload type (`control.payloadType()`), 1:1; its own
  migration state. **`FormulaSourceWorker`** — a non-stream-typed expression emits exactly one message
  (`nextIndex == 0` guard), which is how a child Job's `unit` *parameter* becomes a one-element lane
  (`code: "unit"`; the parameter is typed `DataUnit` by the child's declaration — `control.parameters()`).
- **`JobControl.payloadType()`** is the input lane's statically inferred payload type (null when unknown)
  — `ReadPartWorker.payloadFlow` reads `input.payloadType` from the `WorkerLane`, and at run time the
  element is checked `is DataUnit` (a clear failure otherwise, CC-08).
- **`DataUnit.partsOf(role)` / `isSingleRole`** (DS1) — the accessors this worker keys on.
- **Channel in-flight buffer on migrate**: `JobChannel.drainBuffered` carries a send parked mid-flush;
  the claim-before-send rule (`FormulaSourceWorker`'s KDoc) applies to `itemIndex` here too.
- **Ribbon**: `job-js.yaml` `JobGroup_Transforms` holds `FilterTool` / `FormulaTool` / …; `ReadPartTool`
  joins it.

## Pre-resolved questions

1. **An `ExpandingTransformWorker`, one input port, one output port** — the migration-safe 1:N shape;
   `role` + `attributes` are its only knobs. Not a `SourceWorker` with a parameter name: the unit arrives on a lane (from
   `ReadWorker emit: units`, or from `FormulaSourceWorker("unit")` in a child), which keeps one shape for
   both the in-Job and the child-Logic idioms.
2. **Cursor scope = one unit.** The worker never holds more than the current unit's cursor; exhaustion
   closes it; the next element opens the next. Under `items`-style multi-part units (a unit with several
   parts of the *same* role) the parts are read in order, one cursor at a time, with the header-equality
   rule of §5.3 applied across them (fail naming both).
3. **Execution base** — `ExpandingTransformWorker` is a sibling of `TransformWorker`, not an `Emitter`
   option. It receives a physical input batch into instance state, processes `activeBatch[nextIndex]`,
   and increments `nextIndex` only when that element's expansion completes. Its emitter flushes and
   checkpoints every output `batchSize`. Base migration state carries the active `List<JobMessage>` and
   `nextIndex`, and composes with subclass state through explicit capture/load hooks. At a checkpoint the
   output is flushed; the current input element remains at `nextIndex` for replay after migration.
4. **Migration** — `ReadPartCursor(role, attributes, unit, partIndex, itemIndex,
   cursor: DataCursor?)`, composed with the base's active-batch snapshot. On load with unchanged config,
   adopt the cursor and replay the current unit from the carried batch, continuing at `itemIndex`
   (claim-before-send). With changed config, close the old cursor, reopen the selected parts and skip the
   already-emitted ordinal before continuing, so the migrated output has neither duplicates nor gaps.
   The cursor is detached at capture exactly as `ReadWorker` does.
5. **`attributes: columns`** — identical semantics and helper to `ReadWorker` (DS3 Pre-resolved 4): the
   unit's attributes as leading columns, collision → fail naming both.
6. **`payloadFlow`** — input must be `DataUnit` (or unknown → "cannot verify, will check at run", no
   error — unknown stays legal); output stays unknown. Static shape belongs to `DataSource`, and this
   worker intentionally has only a unit/ref, not its originating source. Never resolve or guess a file
   opener during the walk.
7. **`ExpandWorker`** — **not built.** If a real pipeline needs a generic in-memory stream expander, it
   is a separate small session over this cadence (O1): strict-static stream dispatch lifted from
   `FormulaSourceWorker`, no `flatHeader` / shape probing, `ofPayload` always.

## Step-by-step implementation

1. **`ExpandingTransformWorker`** (jvm, `…/server/objects/job/worker/`) per Pre-resolved 3, with its
   active-batch migration snapshot and subclass state hooks. Keep `TransformWorker` unchanged except for
   a reciprocal KDoc pointer distinguishing the two bases.
2. **`ReadPartWorker`** (jvm, same package): ctor `(input, output, role: String, attributes: String,
   selfLocation, @Service DataOpenerLookup)`; `onElement` → check `is DataUnit` → `partsOf(role)` →
   `DataReadCore.open` / `.drain` each part in order with the expansion cadence → close at exhaustion;
   `onClose`; capture / load per
   Pre-resolved 4; `payloadFlow` per Pre-resolved 6; `progress` (`units`, `emitted`). KDoc: cursor scope,
   the cadence opt-in, the CC-21 reciprocal pointer to `ReadWorker` (and `ReadWorker`'s KDoc gains its
   half).
3. **Notation + ribbon**: `job-worker.yaml` `ReadPartWorker` (`input: ""`, `output: ""`, `role: ""`,
   `attributes: "ignore"`, meta mirroring `ReadWorker`'s `role` / `attributes` and the standard
   input/output port meta); `job-js.yaml` `ReadPartTool` in `JobGroup_Transforms`.

## Tests

1. **`ReadPartWorkerTest`** (jvm, the `FormulaSourceWorkerTest` harness, a capturing control that counts
   `runBlockingIo` and `checkpoint` calls) — a hand-built `DataUnit` with one plain-ref CSV part →
   emits the file's records as flat messages under its header, **at least one `runBlockingIo` per
   item**; a two-role unit with `role: reference` reads the reference file; blank `role` on a two-role
   unit fails naming both roles; `attributes: columns` stamps the unit's attributes first; a non-`DataUnit`
   payload fails with a clear message; two same-role parts emit in part order; zero matching parts fails
   naming the role; **cadence**: with `batchSize = 10` and a 1000-record part, the control sees ≥ 99
   checkpoints during one `onElement`; cancel mid-expansion closes the cursor; **migration**: use one
   physical input batch containing three units, capture after 3 of 5 items within unit 2 → load with the
   same config resumes the remaining 2 items, then processes unit 3 from the carried batch (no duplicates,
   no gaps), driven by a different control; changed `role` reopens and skips the emitted ordinal without
   duplicating the prefix. Assert `drainBuffered()` contains neither unit 2 nor unit 3, proving the base
   snapshot—not the channel—preserves them.
2. **`JobReadPartNotationTest`** (jvm, engine-level, fixture `notation/test/job/job-read-part-test.yaml`)
   — `ReadWorker(emit: units)` over a two-file `FileDataSource` → `ReadPartWorker(role: main)` →
   `CsvWriterWorker`; `Outcome.Success`; output equals the concatenation. **The first end-to-end of the
   two-reader composition.** Plus a single-unit child-Job shape: outer Job hosts `RunWorker` over a child Job
   whose parameter is `unit: DataUnit`, `FormulaSourceWorker("unit")` → `ReadPartWorker(role: main)` →
   `CsvWriterWorker(path: "out/child.csv")` — proves self-opening across the Logic boundary with **no
   resolver and no expression I/O**. DS7 owns named per-unit path binding.
3. **`JobValidatorTest`** additions — a `ReadPartWorker` downstream of `ReadWorker(emit: units)`
   validates (input typed `DataUnit`, needs DS1b); downstream of an `Int` lane → validation error naming
   the type; output lane unknown in v1 (no error).
4. **`JobMigrationTest`** addition — a Read(units) → ReadPart → Summary Job migrated mid-unit ends with
   the correct total.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test` — the above + the whole `exec/job` / `objects/job`
   nets.
2. `:kzen-auto-js:compileKotlinJs` (ribbon yaml).
3. Editor smoke (if DS4 landed): a ReadPart card downstream of a Read(units) card shows no validation
   error; downstream of a Summary it shows the input-type error. Else record as smoke debt.
4. As-built → analysis **§13** (note that `ExpandWorker` was not built and what would trigger it); tick
   row 55; delete this file.

## Risks & gotchas

- **Do not copy the drain core.** `DataReadCore` is DS3's; a second loop here is the CC-12 violation the
  lift exists to prevent.
- **Every cursor call inside `runBlockingIo`** — same regression as DS3; the offload counter in
  test 1 is the net.
- **Do not weaken `TransformWorker`'s invariant.** A mid-element checkpoint there loses the locally-held
  input batch. All such checkpoints belong to `ExpandingTransformWorker`, whose snapshot owns that batch.
- **Claim-before-send** on `itemIndex`; the carried cursor is live and must not be closed by the
  torn-down instance's `onClose`.
- **Do not put reading into an expression.** No `items()` helper "just for tests", no object accessor
  on `JobControl`: only a worker can own the handle, the cursor, cancellation and quiescence (§4).
  The child-Job fixture proves the boundary case without either.
- **Static shape is source-owned.** `ReadPartWorker` has no source, so its output stays unknown; do not
  add a lookup accessor or resolve to recover one (O3).

## Out of scope (this session)

- A generic in-memory `ExpandWorker` (O1) — demand-driven.
- Objects in expression scope, `items()` helpers, any `CalculatedColumnEval` change — no expression ever
  initiates source IO (analysis §4).
- Writer yielding `DataRef`, named child arguments, per-unit paths and `ResultSink keep: all` — **DS7**.
  `LogicDataSource` — **DS8**. `LookupWorker` / role fan-out ergonomics — demand-driven / J6.
