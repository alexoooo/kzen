# DS5 — `ExpandWorker` + objects in expression scope — implementation plan

> **Status: ready to execute.** Session 5 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§5.3** (the 1:N gap, O1, and the domain-freeness settlement), **§5.4** (emit cadence and handle
> ownership — O7), **§6.5** (objects in expression scope, A — O9, and where the instances come from),
> §5.6 (unit identity is *not* free). Constituent plan: **—** (analysis doc is the record; delete on
> landing, as-built → analysis **§14**). Depends on **DS1, DS1b, DS2**; independent of DS3/DS4.
> Anchors verified 2026-08-21. **Revised 2026-08-21b** by the second-pass review (§13 C2, C4, C8, D2).
> Sized **L**; kzen-auto-jvm + one common `JobControl` addition + yaml + ribbon entry. Ledger row 55.
> This is the **parameterized / expert route**; nothing in DS0–DS4 waits on it — but **`groupBy` parity
> does** (§9).

## Scope & goal

1. **`ExpandWorker`** — the transform-side twin of `FormulaSourceWorker`: one Kotlin expression with
   the incoming payload type as receiver (the `FormulaWorker` scope), strict-static dispatch on the
   inferred type — a **stream** type (`Iterable | Sequence | Iterator`, per DS1b) emits one output
   message per element, anything else emits one — with the emit cadence and handle ownership a 1:N
   transform needs.
2. **Objects in expression scope (A)** — the Job's declared `sources/` objects get bare, typed accessors
   in every expression the Job compiles (`FormulaSourceWorker`, `FilterWorker`, `FormulaWorker`,
   `ExpandWorker`), exactly as declared parameters do, so `sales.units()` compiles against
   `FileDataSource`'s real type. **The instances come from the run's `graphInstance`**, not from
   `GraphInstanceCache` (analysis §6.5 / D2).
3. **Expression read helpers** — `items(part)`, `DataUnit.items(role)`, dispatching through
   `DataRef.source` → `DataSourceResolver` **only for the cross-boundary case**, so a unit handed to a
   child Job is self-opening (§4.3).

After this session the §7.1 outer/inner worked shape is expressible except for the writer yielding its
ref (DS7).

## Dependencies & coordination

- **DS1b landed** — `isStreamType` (`Iterable | Sequence | Iterator`) and the `isNameable` visibility
  predicate. **Both are prerequisites, not niceties.** Without the predicate, `sales.units()` publishes
  element type `Any` and `items(payload.part("main"))` does not compile — this session's headline test
  fails for a reason that has nothing to do with this session.
- **DS2 landed** — `DataSource` / `DataScope` / `DataItems` / `DataSourceResolver` /
  `DataSourceConventions.sourcesAttributePath`.
- **XCE landed 2026-08-06** — expression fields are `KotlinCodeArea`; `ExpandWorker.code` reuses it via
  the same `multiline: true` String metadata `FormulaSourceWorker` uses (nothing new on the client).
- **`FormulaStepTest` canary** (AGENTS gotcha) — this session changes the generated class shape in
  `CalculatedColumnEval` (a second injected list plus the data-access field), so clear
  `<workdir>/code-cache` when testing cold.
- **Script's `StepExpressionCompiler`** is *not* changed here; objects-in-scope for Script is a
  follow-up (note in as-built) — the `JobControl.objects()` shape is designed so Script can mirror it.
- **J6 (fan-out)** untouched — §5.6(a) role fan-out stays demand-driven.
- **This session is what `groupBy` parity depends on** (C4). Under `ReadWorker emit: items` the unit is
  gone; unit attributes reach a lane only via `emit: units` + an expression, or via the child-Logic
  idiom. Say so in the as-built so J4 does not plan around a free path that does not exist.

## Current-state findings (anchors verified 2026-08-21)

- **Expression engine** (`…server/objects/report/exec/calc/CalculatedColumnEval.kt`): `validate(name,
  code, columnNames, modelType, classLoader, parameters)`, `create(...)` → `CalculatedColumn`,
  `inferredReturnKType(column)`, `generate(...)` emits imports (`generateImports`, via
  `ClassNames.asTopLevelImport`) + column accessors (`generateColumnAccessors`) +
  **`generateParameterAccessors(parameters: TupleDefinition)`** (a bare typed accessor per parameter
  reading `parameterValues`, injected by `CalculatedColumn.setParameters(values)` — values are
  deliberately **not** baked into the source, so the compile cache keys on shape, not data). The object
  accessors are the same shape with a second list. `collisionError` already rejects a parameter whose
  escaped name collides with a column; **objects need the same check against both**.
- **Inference**: after DS1b, `ExpressionReturnTypeInference.isStreamType` / `streamElementType` /
  `isNameable`. Before DS1b, `isIterable` and a whitelist — see Dependencies.
- **Transform cadence**: `TransformWorker.drive` — `control.checkpoint()` at the top of the loop, drain
  a batch, `onElement` per element, `emitter.flush()` once per *input* batch. `Emitter.send` buffers;
  `Emitter.sourceCadence(control, onFlush)` is the source-only flush+checkpoint-every-N. A 1:N
  transform emitting a million items per input element buffers them all before one flush — the Job
  cannot pause or cancel during the expansion (analysis §5.4b). `TransformWorker`'s KDoc promises "a
  parked Worker holds neither a received-but-unforwarded input element nor a buffered-but-unflushed
  output element"; a 1:N worker parks mid-expansion and must say so.
- **`FormulaWorker`** — receiver = incoming payload type (`control.payloadType()`), members bare,
  `payload` alias; two cardinality-preserving lanes; its own migration state. `FormulaSourceWorker` —
  no incoming lane, `nextIndex` cursor claimed before send, `code`-equality guard.
- **`JobControl`** (commonMain `paradigm/job/control/`): `checkpoint()`, `runBlockingIo(block: () -> R)`
  (**non-suspend block**), `scratchDir()`, `outputDir()`, `publishProgress`, `parameters()`,
  `parameter(name)`, `results()`, `payloadType()`, `yieldResult`, `host(instructions, input)`. Every
  addition has an inert default (CC-09) so a third-party control still compiles.
- **The run graph holds the sources.** `JobRun` builds `graphInstance =
  GraphCreator.createGraph(filteredDefinition, graphEnvironment)` over
  `JobLogicCompiler`'s `filterTransitive(documentPath)` — the **whole** filtered definition, so every
  object in the Job document is already instantiated, once, before the first Worker starts.
  `JobRun` also holds `jobParameters` and the `JobChildLogicHost`.
- **`WorkerLaneContext(parameters, objectRegistryScan, graphStructure, classLoader)`** is what
  `payloadFlow` / `JobValidator` compile against — the definition-time twin of the run-time scope, and
  it has **no instances**, only notation. That asymmetry is the design: the walk needs *types*, the run
  needs *values*.

## Pre-resolved questions

1. **New archetype, not an `expand:` knob on `FormulaWorker`** (O1) — the analysis's recommendation;
   shared expression plumbing is **lifted** into one helper used by `FormulaSourceWorker` and
   `ExpandWorker` (the "dispatch on inferred type, stream or single" core), not copied (CC-12).
2. **Domain-freeness vs flat emission — settled on the interface** (§5.3). `ExpandWorker` emits
   `JobMessage.ofFlat` when the stream it is draining exposes a non-null **`flatHeader`**, and
   `ofPayload` otherwise. `flatHeader` is an ordinary interface member (`DataItems`) that any
   third-party stream may expose, so this is not a class switch and CC-17 holds. Implement it as a
   `flatHeader`-bearing interface probe, and state in KDoc that the worker knows nothing about data
   sources.
3. **Object scope = the Job's `sources/` objects, by declared name.** Scope entries are
   `(name = object name, type = the archetype's `class:` as TypeMetadata)` — read from notation in one
   place (`JobObjectScope.of(graphStructure, jobMainLocation)` in commonMain beside
   `JobSignatureCapability`, capability-filtered by `DataSourceConventions.isDataSource`;
   **generalizable later** to any nested object kind without changing callers).
4. **Where the run-time values come from — the run graph** (D2). `JobRun` already holds `graphInstance`;
   build the per-run `JobObjectScopeValues` from it by looking up each scope entry's `ObjectLocation`.
   **Do not use `DataSourceResolver` here.** Going through `GraphInstanceCache` would hand the run a
   *second*, cache-shared instance of an object its own graph already built, import the cache's
   statelessness contract into the run, and put the instance outside the run's Context frame. The
   resolver's run-time job is the **cross-boundary case only** (Pre-resolved 6).
5. **How workers receive the scope** — `JobControl` gains `fun objects(): TupleDefinition` and
   `fun obj(name: String): Any?` mirroring `parameters()` / `parameter()` (so Script can mirror it
   later, and so a third-party Worker gets it with no framework change); `WorkerLaneContext` gains
   `objects: TupleDefinition`; `CalculatedColumnEval.validate/create` gain an `objects` parameter and
   `CalculatedColumn.setObjects(values)`. Every existing call site passes `TupleDefinition.empty` or the
   context's value — mechanical. Extend `collisionError` to reject an object name colliding with a
   column **or** a parameter, with a message naming both (CC-08).
6. **Expression helpers** — generated into the compiled class as members delegating to an injected
   `ExpressionDataAccess` (set by `setDataAccess(...)`, one more injected field):
   `fun items(part: DataPart): DataItems`, `fun DataUnit.items(role: String = "main"): DataItems`. No
   globals, no static resolver (tests build several contexts). `ExpressionDataAccess`'s implementation
   resolves `DataRef.source` by asking the **run's object scope first** and falling back to
   `DataSourceResolver.resolve(id)` — the fallback is exactly the §4.3 case (a unit handed to a hosted
   child Job whose own `filterTransitive` does not reach the parent's source). It also owns the
   `DataScope` handed to `items()`: the same `WorkerDataScope` shape DS3 defines, over the worker's
   `JobControl`.
7. **`units()` from an expression takes no arguments.** `sales.units()` — the Job's declared parameters
   reach the source through `DataScope.argument(name)`, by name (O13). There is deliberately no
   `units(from, to)` positional form: it could not have compiled anyway (the SPI is non-suspend but the
   *previous* draft's was `suspend`, and a positional convention was DS8's own "brittle" compromise).
8. **Emit cadence for a 1:N transform** (§5.4b) — `Emitter.expandCadence(control, onFlush)` used by
   `ExpandWorker` inside its per-element loop: after every `batchSize` sends, flush and
   `control.checkpoint()`. Sits beside `sourceCadence` (same class, one more entry point — CC-04),
   and `TransformWorker.drive`'s own top-of-loop checkpoint stays.
9. **Handle ownership** (O7) — `ExpandWorker` tracks the current stream; if it is `AutoCloseable`
   (`DataItems` is), `onClose` closes it, and exhaustion closes it. Migration: no positional carry —
   `(inputElementIndex, emittedWithinElement)` is captured and the resumed instance **re-reads and skips**
   the prefix within the current input element (the honest re-read; documented in KDoc with the CC-21
   marker pointing at `ReadWorker`'s positional cursor as the deliberate contrast). Guarded on `code`.
   ⚠ `DataItems` is **constrain-once**, so the re-read must re-evaluate the expression (producing a new
   stream), never re-iterate the carried one.
10. **Classloader** — the expression classloader is `WorkerLaneContext.classLoader` /
    `ClassLoaderUtils.dynamicParentClassLoader()`; first-party source classes are visible. A
    plugin-loaded source class (extension-points §1) is a follow-up; record the seam in KDoc.

## Step-by-step implementation

### Step 1 — object scope (common + jvm)

`JobObjectScope` (commonMain, beside `JobSignatureCapability`); `JobControl.objects()/obj()` with
inert defaults (CC-09); `EngineJobControl` implements from a per-run `JobObjectScopeValues` built in
`JobRun` **from `graphInstance`**; `WorkerLaneContext.objects`; `JobValidator` populates it;
`CalculatedColumnEval` generates accessors + `setObjects` + `setDataAccess` and extends
`collisionError`; all existing callers updated (`FormulaSourceWorker`, `FilterWorker`, `FormulaWorker`,
`JobValidator`, tests).

### Step 2 — `ExpressionDataAccess` (jvm)

`…/server/objects/datasource/ExpressionDataAccess.kt`: the two helpers, over the run's object scope with
a `DataSourceResolver` fallback for a ref whose source is not in this run's graph, plus the
`WorkerDataScope` it passes down.

### Step 3 — `ExpandWorker` (jvm) + notation + ribbon

`…/server/objects/job/worker/ExpandWorker.kt` (`TransformWorker`; ctor `(input, output, code,
selfLocation, @Service CalculatedColumnEval)`), shared dispatch helper lifted out of
`FormulaSourceWorker` (`ExpressionStreamDispatch` in the same package); `Emitter.expandCadence`;
flat-vs-payload by `flatHeader`; `payloadFlow` publishes the element type (stream) or the whole type
(single), receiver = input lane's payload type. `job-worker.yaml`: `ExpandWorker` (`input: ""`,
`output: ""`, `code: ""`, meta like `FormulaWorker`'s `code`); `job-js.yaml`: `ExpandTool` in
`JobGroup_Transforms`.

## Tests

1. **`ExpandWorkerTest`** (jvm, the `FormulaSourceWorkerTest` harness) — `(1..payload)` over inputs
   `[2,3]` emits `1,2,1,2,3`; a `Sequence` expression streams; a scalar expression emits one per input;
   a `DataItems`-yielding expression (hand-built `DataSource` fake with a non-null `flatHeader`) emits
   **flat** messages under that header and **closes** the stream at exhaustion; the same fake with a
   null `flatHeader` emits payload messages (the interface probe, not a class switch); cancel
   mid-expansion (via a capturing control) closes the current stream;
   **migration**: capture after 3 of 5 emits within element 2 → load with same code resumes emitting the
   remaining 2 of element 2 then element 3 (re-read via re-evaluation, no duplicates, no
   second-`iterator()` exception); changed code restarts; **cadence**: with `batchSize = 10` and a
   1000-element expansion, the control sees ≥ 99 checkpoints during one `onElement`.
2. **`JobObjectScopeTest`** (jvm, beside `JobSignatureCapabilityTest`) — a Job with two `sources/`
   objects yields two typed entries in document order; a non-source nested object is excluded; an object
   name colliding with a parameter or a column is rejected with a message naming both.
3. **`FormulaSourceWorkerTest`** addition — `input.units()` where `input` is a `FileDataSource` in scope
   (temp-`main/` fixture) streams `DataUnit`s **typed as `DataUnit`** (the DS1b dependency, visible
   here); compile error when the name is not declared (clear message naming the identifier).
4. **`JobExpressionDataAccessTest`** (jvm, engine-level fixture `notation/test/job/job-expand-test.yaml`)
   — `FormulaSourceWorker("input.units()")` → `ExpandWorker("items(payload.part(\"main\"))")` →
   `CsvWriterWorker`; `Outcome.Success`; output equals the input file. **The first end-to-end of the
   expression route.** Add the child-Job shape: outer Job hosts `RunWorker` over a child Job whose
   parameter is a `DataUnit` and whose `ExpandWorker` reads `items(unit.part("main"))` — proves
   self-opening across the Logic boundary via the **`DataSourceId` fallback path**, which is the only
   place `DataSourceResolver` is exercised at run time.
5. **Instance-provenance test** — a source object in the Job's `sources/` branch that records its own
   construction count; a run must construct it **once** and the expression scope must see **that**
   instance (identity assertion), not a second one from `GraphInstanceCache`. This is D2's pin, and it
   is cheap.
6. **`JobValidatorTest`** addition — an `ExpandWorker` lane infers the element type; a `FormulaWorker`
   downstream compiles against it.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test` — all of the above + the whole `exec/job` /
   `objects/job` / `objects/logic` nets + `FormulaStepTest` (the inference canary; clear
   `<workdir>/code-cache` first for a cold compile).
2. `:kzen-auto-js:compileKotlinJs` (ribbon yaml + the `JobControl` common change).
3. Editor smoke (if DS4 landed): an Expand card's code field validates against the upstream payload
   type; else record as smoke debt.
4. As-built → analysis **§14** (include the "objects-in-scope for Script" follow-up, the
   plugin-classloader seam, and the C4 note that `groupBy` parity now has a path); tick row 55; delete
   this file.

## Risks & gotchas

- **Generated-class shape change** — adding `setObjects` / `setDataAccess` touches every compiled
  expression; stale `code-cache` jars compiled against the old shape will fail to link — clear the
  cache in tests and note it in the as-built for users' work dirs. Check `CalculatedColumnEval`'s cache
  key and include a generator-version constant if the key is content-only (CC-01 for the constant).
- **Do not reach for `DataSourceResolver` on the run path.** The run graph is the source of truth
  (D2); the resolver is the cross-boundary fallback only. Test 5 is what stops the drift.
- **`DataItems` is constrain-once** — the O7 re-read must re-evaluate the expression, not re-iterate.
  Re-iterating throws, and it will throw only on the migration path, which is the least-tested one.
- **Cadence vs `TransformWorker` invariants** — the drive-loop KDoc promises "a parked worker holds no
  received-but-unforwarded element"; an expand checkpoint *inside* `onElement` parks with the input
  element consumed and part of its expansion emitted — that is exactly what the migration state
  (`inputElementIndex`, `emittedWithinElement`) records. Update the `TransformWorker` KDoc to say 1:N
  workers opt into the finer cadence and carry that state.
- **A non-pure expression re-reads differently** — the §8.1 caveat, documented, not solved here. Note
  the contrast: `ReadWorker` carries its manifest and never re-resolves; the expression route
  re-evaluates.
- **Don't reach for a global resolver or a global scope** — tests construct multiple
  `KzenAutoContext`s; inject.

## Out of scope (this session)

- `isStreamType` / the visibility predicate — **DS1b** (prerequisites, not this session's work).
- Writer yielding `DataRef`, `ResultSink keep: all` — **DS7**. `LogicDataSource` + the dated example —
  **DS8**.
- Objects in scope for Script expressions — follow-up. `LookupWorker` / role fan-out — demand-driven.
- Stamping unit attributes as columns automatically — **there is no such feature** (C4); it is what the
  user writes in a `FormulaWorker` expression.
