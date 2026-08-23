# DS5 — `ReadPartWorker` + the 1:N transform cadence — implementation plan

> **Status: ready to execute.** Session 5 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§5.3** (the 1:N gap and `ReadPartWorker`; `ExpandWorker` demoted — O1), **§5.4b** (the transform emit
> cadence — the one expression-route cost that survives), §4.3 (self-opening refs; the child-Logic
> shape), §5.6 (a/b — role fan-out and the child-Logic idiom), §3.5 (attributes onto the item lane —
> O22), **§15** (third-pass record — D7, D8, D12). Constituent plan: **—** (analysis doc is the record;
> delete on landing, as-built → analysis **§14**). Depends on **DS1, DS1b, DS2, DS3**; independent of
> DS4. Anchors verified 2026-08-21; **rewritten 2026-08-23** by the third-pass review (this file was
> `DS5_expand-and-expression-scope.md`). Sized **M**; kzen-auto-jvm + yaml + ribbon entry. Ledger
> row 55. This is the **composition** reader: what the child-Logic idiom and grouped multi-role
> pipelines read with.
>
> **What changed 2026-08-23 (vs the 2026-08-21b plan):** the whole expression half is **gone** —
> objects in expression scope (`JobControl.objects()` / `obj()`, `CalculatedColumnEval.setObjects` /
> `setDataAccess`, `JobObjectScope`), the `items()` / `DataUnit.items()` expression helpers,
> `ExpressionDataAccess`, and the run-time `DataSourceResolver` fallback (D7). `ExpandWorker` as the
> data bridge is gone with it; a *generic in-memory* `ExpandWorker` is **demand-driven, not built here**
> (O1). What this session builds instead is the second data reader, **`ReadPartWorker`**, over DS3's
> lifted `DataReadCore`, plus the cadence fix both 1:N workers need.

## Scope & goal

```
ReadPartWorker(input: <unit lane>, output: <item lane>, role: "main", attributes: ignore | columns)
```

1. **`ReadPartWorker`** — a `TransformWorker`: for each incoming payload (must be a `DataUnit`), pick
   `unit.part(role)` (blank `role` = the unit's only role, else the named one; a non-single-role unit with
   blank `role` fails naming the roles), open it through `DataOpenerLookup` + DS3's `DataReadCore`, and
   emit one message per item — `ofFlat` when `cursor.shape is Tabular`, else `ofPayload`;
   `attributes: columns` widens exactly as `ReadWorker` does (same helper). `payloadFlow` validates the
   input lane's `payloadType` is `DataUnit` (⚠ needs DS1b) and publishes the opener's `staticShape(role)`.
2. **The 1:N transform emit cadence** (§5.4b) — `Emitter.expandCadence(control, onFlush)` beside
   `sourceCadence`: after every `batchSize` sends *within* `onElement`, flush and `control.checkpoint()`.
   Without it a unit that expands to a million items buffers them all before one flush and the Job cannot
   pause or cancel during the expansion.
3. **Handle ownership** — the open cursor is closed in `onClose` unless detached, and at exhaustion; the
   drive is per-item `runBlockingIo` (DS3's core, C11).
4. **Migration** — `(inputElementIndex, itemIndex, open cursor)` carried; the current unit is
   re-delivered by the channel's in-flight buffer, the carried cursor continues from `itemIndex`, driven
   by the new control. Guarded on `role` / `attributes`.

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
  `ReadPartWorker`s); **DS7**'s fixture uses the simpler `ReadWorker` variant.
- **J6 (fan-out)** untouched — §5.6(a) role fan-out with two `ReadPartWorker`s off one unit lane is
  legal today only via manually declared channels (`JobChannelDerivation` auto-wires single-output
  workers); note it in the KDoc, it is J6's ergonomic relief.
- **`TransformWorker`'s KDoc invariant** ("a parked Worker holds neither a received-but-unforwarded input
  element nor a buffered-but-unflushed output element") must be amended: a 1:N worker that checkpoints
  inside `onElement` parks with the input element consumed and part of its expansion emitted — that is
  exactly what its migration state records. Say so there.

## Current-state findings (anchors verified 2026-08-21, re-checked 2026-08-23)

- **Transform cadence**: `TransformWorker.drive` — `control.checkpoint()` at the top of the loop, drain
  a batch, `onElement` per element, `emitter.flush()` once per *input* batch. `Emitter.send` buffers;
  `Emitter.sourceCadence(control, onFlush)` is the source-only flush+checkpoint-every-N. A 1:N
  transform emitting a million items per input element buffers them all before one flush (analysis
  §5.4b).
- **`TransformWorker.onElement` may call `emit.send` any number of times** — the framework permits 1:N;
  no shipped worker does it.
- **`FormulaWorker`** — receiver = incoming payload type (`control.payloadType()`), 1:1; its own
  migration state. **`FormulaSourceWorker`** — a non-stream-typed expression emits exactly one message
  (`nextIndex == 0` guard), which is how a child Job's `unit` *parameter* becomes a one-element lane
  (`code: "unit"`; the parameter is typed `DataUnit` by the child's declaration — `control.parameters()`).
- **`JobControl.payloadType()`** is the input lane's statically inferred payload type (null when unknown)
  — `ReadPartWorker.payloadFlow` reads `input.payloadType` from the `WorkerLane`, and at run time the
  element is checked `is DataUnit` (a clear failure otherwise, CC-08).
- **`DataUnit.part(role)` / `isSingleRole`** (DS1) — the accessors this worker keys on.
- **Channel in-flight buffer on migrate**: `JobChannel.drainBuffered` carries a send parked mid-flush;
  the claim-before-send rule (`FormulaSourceWorker`'s KDoc) applies to `itemIndex` here too.
- **Ribbon**: `job-js.yaml` `JobGroup_Transforms` holds `FilterTool` / `FormulaTool` / …; `ReadPartTool`
  joins it.

## Pre-resolved questions

1. **A `TransformWorker`, one input port, one output port** — the standard shape; `role` + `attributes`
   are its only knobs. Not a `SourceWorker` with a parameter name: the unit arrives on a lane (from
   `ReadWorker emit: units`, or from `FormulaSourceWorker("unit")` in a child), which keeps one shape for
   both the in-Job and the child-Logic idioms.
2. **Cursor scope = one unit.** The worker never holds more than the current unit's cursor; exhaustion
   closes it; the next element opens the next. Under `items`-style multi-part units (a unit with several
   parts of the *same* role) the parts are read in order, one cursor at a time, with the header-equality
   rule of §5.2b applied across them (fail naming both).
3. **Cadence** — `Emitter.expandCadence(control, batchSize, onFlush)`: a counter inside the per-item
   loop; every `batchSize` sends → `emitter.flush()` + `control.checkpoint()`. Same class as
   `sourceCadence`, one more entry point (CC-04). `TransformWorker.drive`'s own top-of-loop checkpoint
   stays.
4. **Migration** — `ReadPartCursor(role, attributes, inputElementIndex, itemIndex, cursor: DataCursor?)`.
   On load: adopt iff `role` and `attributes` match; the worker's `onElement` for the re-delivered unit
   skips opening and continues the carried cursor from `itemIndex` (claim-before-send). Otherwise restart
   the unit (re-open, which is a re-read of the prefix for that one unit — state it in KDoc; bounded by a
   unit, not a run). The cursor is detached at capture exactly as `ReadWorker` does.
5. **`attributes: columns`** — identical semantics and helper to `ReadWorker` (DS3 Pre-resolved 4): the
   unit's attributes as leading columns, collision → fail naming both.
6. **`payloadFlow`** — input must be `DataUnit` (or unknown → "cannot verify, will check at run", no
   error — unknown stays legal); output = the opener's `staticShape(role)` → `flatColumns` /
   `payloadType`, unknown otherwise. Which opener? `DataOpenerLookup` is keyed on a *ref*, which the walk
   does not have; for v1 (every ref plain) the answer is the file opener's static shape, which is null
   until DS6's declared schema — so "unknown" is the honest v1 answer, and the code path is written
   against the lookup with a `staticShapeForPlain(role)` accessor so DS6 can fill it.
7. **`ExpandWorker`** — **not built.** If a real pipeline needs a generic in-memory stream expander, it
   is a separate small session over this cadence (O1): strict-static stream dispatch lifted from
   `FormulaSourceWorker`, no `flatHeader` / shape probing, `ofPayload` always.

## Step-by-step implementation

1. **`Emitter.expandCadence`** (jvm, `…/server/objects/job/worker/`) + the `TransformWorker` KDoc
   amendment.
2. **`ReadPartWorker`** (jvm, same package): ctor `(input, output, role: String, attributes: String,
   selfLocation, @Service DataOpenerLookup)`; `onElement` → check `is DataUnit` → `part(role)` →
   `DataReadCore.open` / `.drain` with the cadence → close at exhaustion; `onClose`; capture / load per
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
   payload fails with a clear message; **cadence**: with `batchSize = 10` and a 1000-record part, the
   control sees ≥ 99 checkpoints during one `onElement`; cancel mid-expansion (via the control) closes
   the cursor; **migration**: capture after 3 of 5 items within element 2 → load with same config resumes
   emitting the remaining 2 of element 2 then element 3 (no duplicates, no gaps), driven by a different
   control; changed `role` restarts the unit.
2. **`JobReadPartNotationTest`** (jvm, engine-level, fixture `notation/test/job/job-read-part-test.yaml`)
   — `ReadWorker(emit: units)` over a two-file `FileDataSource` → `ReadPartWorker(role: main)` →
   `CsvWriterWorker`; `Outcome.Success`; output equals the concatenation. **The first end-to-end of the
   two-reader composition.** Plus the child-Job shape: outer Job hosts `RunWorker` over a child Job
   whose parameter is `unit: DataUnit`, `FormulaSourceWorker("unit")` → `ReadPartWorker(role: main)` →
   `CsvWriterWorker(path: "out/${date}.csv")` — proves self-opening across the Logic boundary with **no
   resolver and no expression I/O**.
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
4. As-built → analysis **§14** (note that `ExpandWorker` was not built and what would trigger it); tick
   row 55; delete this file.

## Risks & gotchas

- **Do not copy the drain core.** `DataReadCore` is DS3's; a second loop here is the CC-12 violation the
  lift exists to prevent.
- **Every cursor call inside `runBlockingIo`** — same regression as DS3 (C11); the offload counter in
  test 1 is the net.
- **Cadence vs `TransformWorker` invariants** — the drive-loop KDoc promise changes for 1:N workers;
  amend it, don't just violate it.
- **Claim-before-send** on `itemIndex`; the carried cursor is live and must not be closed by the
  torn-down instance's `onClose`.
- **Do not re-grow the expression route.** No `items()` helper "just for tests", no `JobControl.obj()`.
  The child-Job fixture proves the boundary case without either.
- **`DataOpenerLookup` at walk time has no ref** — Pre-resolved 6's plain-ref static accessor is the
  seam; do not resolve to get one (O3).

## Out of scope (this session)

- A generic in-memory `ExpandWorker` (O1) — demand-driven.
- Objects in expression scope, `items()` helpers, any `CalculatedColumnEval` change — withdrawn from the
  arc (analysis §15 D7).
- Writer yielding `DataRef`, `ResultSink keep: all` — **DS7**. `LogicDataSource` + named host arguments
  — **DS8**. `LookupWorker` / role fan-out ergonomics — demand-driven / J6.
