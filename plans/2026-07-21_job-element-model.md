# Job channel element model — typed messages with a flat part

> **Status: designed (rev 2), not implemented.** Companion to `2026-07-16_job-improvements.md`
> (the live Job backlog — interactions below; NB this design **supersedes the ParameterSource
> half of its landed J2**). Rev 1 (same day) chose a flat-view-only coercion; the user expanded
> the direction to a typed-message model, and rev 1's coercion survives inside it as the
> payload→flat fallback. Phases at the end are self-contained for executor sessions
> (Opus-class, one phase per session).
>
> **Progress tracker** (update as phases land):
> - [ ] Phase 1 — `JobMessage` carrier (payload + flat part) replaces `DataRecord`
> - [ ] Phase 2 — typed parameters, parameter scope, FormulaSource as THE parameterized source
> - [ ] Phase 3 — payload formulas + type inference flowing through the graph
> - [ ] Phase 4 — performance: benchmark-gated reuse (folds into job-improvements phase 5)

## Problem

Running a Script that invokes a parameterized Job fails at run time with a bare
`Logic Failure: Class Cast: class java.lang.Double cannot be cast to class
tech.kzen.auto.server.objects.job.worker.DataRecord`. The reproducing shape (the user's
`main/Script-2.yaml` → `main/Job-3.yaml`):

```
Script: NumberLiteralStep(13) → RunStep(Job-3, arguments: {number: …}) → DisplayValueStep
Job-3:  ParameterSourceWorker(number) → FormulaWorker(foo: 2 + 2) → ResultSinkWorker
```

Root cause, two halves:

1. **Nine workers are hard-typed to `DataRecord`** — Filter, Formula, Sort, ValueSetFilter,
   Summary, Pivot (transforms) and CsvWriter, Explore, ExportWriter (sinks) extend
   `TransformWorker<DataRecord, …>` / `SinkWorker<DataRecord>`, so the framework performs
   `element as In` on their behalf (TransformWorker.kt:58, SinkWorker.kt:39).
2. **The definition-time type check is vacuous for untyped lanes.** `ChannelTypeDefiner` treats
   `Any` on either side as a wildcard (ChannelTypeDefiner.kt:192-197); the scalar/parameter
   lanes are deliberately untyped, so untyped→hard-typed wiring passes definition and detonates
   at the framework cast.

The goal is bigger than the crash: a proper data model for what flows between Workers —
**strongly typed payloads whose types are inferred and flow through the graph the way Script
step types do**, alongside the flat columnar data the Report-lineage workers are built on.

## Design evolution (analysis record)

- **Rev 1 — flat-view coercion**: keep elements arbitrary, give record workers a
  `DataRecord.viewOf(element)` lens (scalar → `value` column, Map → keyed columns). Correct as
  far as it went, but one-directional: everything becomes columns; no typed-object lane, no
  typed expressions, no typed parameters.
- **Strict typing** (definition-time rejection + converter workers) — rejected: fights the
  palette-insert-and-it-works goal; the `Any` wildcard is deliberate. One element kept: the
  framework cast should fail *descriptively* (phase 1).
- **Message envelope** — initially rejected over hot-path allocation ("a wrapper per element").
  That objection only holds for wrapping `DataRecord` *inside* an envelope. **Merging them —
  the message IS the carrier, with a payload slot and the flat part as fields — is
  allocation-neutral versus today** (one carrier object per element either way), and it is the
  model the user wants: payload like a typed Script value, plus a flat key→value part like a
  messaging platform's header map. Chosen.

## The model — `JobMessage`

One class replaces `DataRecord` as the ONLY element type crossing Job channels:

```kotlin
class JobMessage(
    var payload: Any?,              // the strongly typed domain value (null on the pure-flat lane)
    var header: HeaderListing?,     // flat-part column names — SHARED ref across a schema run
    var flat: FlatFileRecord?       // flat-part values — mutable in place by the current owner
)
```

- **Payload lane**: `payload` carries an arbitrary typed object; its static type is inferred and
  flows through the graph (below). Scalar/Run/parameter streams live here.
- **Flat part**: `header` + `flat` are exactly `DataRecord`'s fields (shared header ref, schema
  change = the ref changing; fresh-or-owned `FlatFileRecord`). Nullable **as a pair** so
  pure-payload lanes pay no array allocations. The CSV lane populates the flat part and leaves
  `payload` null.
- **Ownership-transfer contract unchanged** (DataRecord.kt kdoc): the sender never touches a
  message after emitting; the receiver owns it and MAY mutate in place — which is precisely what
  makes "clear and refill instead of re-create" legal for the flat part.
- **Uniformity kills the CCE class**: every producer emits messages, every consumer receives
  messages; the framework cast is trivially safe again. Boundary workers wrap/unwrap (below).
- **Auto-flatten fallback** (rev 1's coercion, in its natural place): `message.ensureFlat()` —
  when a flat-consuming operation needs columns and the flat part is absent, materialize it IN
  PLACE from the payload (Map → keyed columns; anything else → single `value` column via
  `ColumnValue.toText`, ColumnValue.kt:71) and cache it on the message (once per message; legal
  under receiver ownership; sinks don't forward, and a forwarded materialized view carries
  equivalent information). Shared constant `value` header (Preview's `scalarColumn` migrates
  here). Palette-insert-and-it-works preserved: a Double stream through CsvWriter writes a
  `value` column.

## Expressions — one facility, three scopes

A single Job expression engine, generalizing `CalculatedColumnEval` (CalculatedColumnEval.kt) —
whose generated class **already takes a typed `model` receiver** (the user formula runs as an
extension of `modelType`, currently pinned to `Unit`/`Any` by Filter/Formula). That dormant hook
becomes the payload:

- **Payload as receiver + `payload` alias**: the expression compiles as an extension of the
  inferred payload type, so a `Person` payload's members are bare (`age > 30`); an explicit
  `payload` accessor always exists. Kotlin receiver rules mean payload members shadow same-named
  columns; `payload.x` / the column accessor are the escape hatches (documented).
- **Flat columns bare** (today's `City eq "Lviv"` ergonomics): `ColumnValue` accessors generated
  from the header, `ColumnValueConversions` operator imports preserved.
- **Parameters bare by name, typed** (Script parity): accessors generated from the Job's
  parameter declarations, values threaded once per compile (run-constant, via
  `JobControl.parameter`).

Compilation is lazy, keyed on (expression, header, payload type, parameter types), cached via
`CachedKotlinCompiler` + instance reuse, run under `runBlockingIo` — the existing
per-header-recompile discipline (FilterWorker.kt:65-71) extended by the statically-known scopes.

Consumers of the facility:
- **FormulaWorker**: a new `payload:` expression transforming the payload (empty = pass
  through), PLUS the existing `formula:` map now as *flat value formulas* (key → expression →
  flat column). Both evaluate against the INCOMING message's scope (Report precedent: formulas
  see original columns, outputs append together — no intra-worker chaining).
- **FilterWorker** `where`: same scope, truthy over payload + columns + parameters.
- **FormulaSourceWorker**: parameters in scope (no header, no payload).
- Any future/3rd-party worker can inject the same service.

## Typed parameters — declarations, not marker workers

Job parameters become Script-style declarations: a `parameters` branch on the Job document of
`ParameterBinding`-like objects (`type: TypeMetadata` + default — ParameterBinding.kt; relocate
the binding concept to a flavour-neutral package rather than duplicating it, per the
fix-root-cause rule). Consequences:

- **Signature inputs derive from the declarations** (typed — no more "Any" badges), replacing
  `JobSignatureCapability`'s Parameter role; the Result side (ResultSinkWorker + marker) stays.
- **Parameters are in scope of every expression** — accessible from any Formula / Filter /
  FormulaSource, exactly as Script expressions reference bindings by name.
- **`ParameterSourceWorker` is RETIRED** (decided): a FormulaSource whose expression is `number`
  — or `(1..number)` — is the one idiom for sourcing from parameters. This supersedes the
  ParameterSource half of J2 (landed 2026-07-21); its archetype, worker, capability role, and
  client branch go, and its migration fixtures port to FormulaSource equivalents.
- **FormulaSource inherits the stream cursor**: ParameterSource's claim-before-send cursor
  (ParameterSourceWorker.kt:42-46) exists so a mid-stream migrate doesn't re-emit delivered
  elements against a carried downstream accumulation. As THE parameterized source, FormulaSource
  gains the same cursor (guarded on code equality; requires stable re-evaluation order, same as
  ParameterSource's stably-ordered-Collection rule) — without it, retirement would regress
  `JobSignatureMigrationTest`'s exactness guarantee.

## Type inference and flow

A Job-side analogue of `ScriptValidation`'s fixpoint (StepExpressionSupport.kt:25-46,
FormulaStep.kt:49-78), computed server-side per notation version:

- Walk the wiring (`JobChannelDerivation` order — the same shared derivation the client uses).
- Each worker maps input payload type → output payload type: **FormulaSource** infers its
  expression's type via the probe-compile + `StepReturnTypeInference` reflection path (with
  parameter types in scope) — and the type makes the stream-vs-single decision STATIC: an
  `Iterable<T>`-typed expression streams elements of `T`, anything else emits one message;
  **FormulaWorker** infers its `payload:` expression (empty = identity); **Filter / ValueSet /
  Sort / Summary / Pivot / Preview** are identity; **RunWorker** takes the child signature's
  main result type; **readers** contribute no payload type (flat lane); **ResultSink**'s input
  type types the signature's output component.
- Downstream expressions compile against the inferred payload type (the receiver); inference
  failures / expression compile errors surface as validation errors on the worker card (the
  DefinitionErrors precedent), not as run-time crashes.
- Channel `of:` / `elementType` now describe the PAYLOAD type. `ChannelTypeDefiner` is
  mechanically unchanged (declared-type checking + single-reader); inferred types feed
  expression compilation and the signature/editor display in v1, with inferred-vs-declared
  cross-checking a possible later tightening.

## Boundary rules

`JobMessage` (like `DataRecord` before it) never crosses a Logic boundary:

- **Outbound** (`ResultSinkWorker.onComplete`): yield the payload when present; a flat-only
  message materializes to an ordered `Map<String, String>` (column → text, header order).
  Buffer keeps raw messages (materialize at yield) so carryover is untouched. Worked example:
  Job-3 yields `13.0` (payload passes through Formula); to return the computed value, the user
  writes a `payload:` formula — flat columns are auxiliary unless explicitly promoted.
- **Inbound**: a Script `RunStep` argument binds a declared parameter (typed in the signature);
  workers read it via expression scope. **RunWorker** unwraps per the same rule (child gets
  payload if present, else the materialized map) and wraps the child's result as a fresh
  message's payload.

## Worker impact summary

| Worker | Change |
|---|---|
| CsvReader / MultiFileReader / (J3 PluginReader) | emit flat-part messages, payload null — mechanical |
| FormulaWorker | + `payload:` expression; `formula:` becomes flat formulas; both new scopes |
| FilterWorker / ValueSetFilter | `where`/match over new scope; forward the received message |
| SortWorker / SummaryWorker / PivotWorker | keys/accumulation read `ensureFlat()`; forward/buffer messages |
| CsvWriter / Explore / ExportWriter / Preview | consume `ensureFlat()`; Preview's hand-rolled dual-lane `when` (PreviewWorker.kt:65-84) collapses into it |
| FormulaSourceWorker | parameters in scope; static stream-vs-single; stream cursor |
| ParameterSourceWorker | RETIRED (phase 2) |
| RunWorker / ResultSink | wrap/unwrap per boundary rules |

The extension rule holds: no general layer learns a worker type; the expression facility and
`ensureFlat` are services/helpers any 3rd-party worker can use.

## Performance

Explicit requirement: a HIGH performance ceiling. Position:

- **Now (phases 1–3), allocation parity or better**: `JobMessage` replaces `DataRecord` 1:1 on
  the hot CSV lane (a null payload field is free); nullable flat part spares pure-payload lanes
  the array allocations; headers stay shared refs; `ensureFlat` materializes at most once per
  message; in-place mutation under ownership transfer (Formula clears/refills or appends to the
  received flat part rather than re-creating); compiled expression instances cached
  (per-header lazy compile as today). Scalar lanes gain one carrier object per element (they
  are low-volume; noted honestly).
- **Ceiling (phase 4, benchmark-gated per job-improvements phase 5)**: batch-bounded message
  arenas / pooled `FlatFileRecord`s recycled after the consumer settles a batch, with
  **copy-on-retain** for retaining operators (Preview's window, Sort's buffer) — the phase-5
  appendix's pre-sketched shape. Hard constraint recorded: **migration carryover
  (`drainBuffered`, JobChannel.kt:130-158) captures live messages — a pool must transfer
  ownership of captured messages, never recycle them.** Do not build reuse before the phase-5
  benchmark convicts allocation; the model above is deliberately reuse-ready (mutable carrier,
  nullable flat, ownership discipline).

## Known limitations / future directions (recorded, not built)

- **Empty stream ⇒ no schema for writers** (element-carried schema has no elements to ride on;
  true today too). Channel-level schema metadata if it ever bites.
- **Cross-cutting message metadata** (provenance, correlation ids): the flat part largely covers
  it in-band (the grouped-export precedent — stamp a column); a dedicated headers-map field on
  `JobMessage` is a compatible later addition if a real need appears.
- **Richer flatten rules** (data classes via reflection → columns; TupleValue components) — add
  to `ensureFlat` on demand.
- **Inferred-vs-declared channel type cross-checking**; co/contravariance stays out of scope
  (job-improvements' standing decision).

## Interactions with `2026-07-16_job-improvements.md`

- **J2 (landed)**: SUPERSEDED in part — parameter declarations replace ParameterSource markers
  as the signature's input source (phase 2 here); `ResultSink`, `JobControl.parameter`/
  `yieldResult`, and the client signature branch survive. Noted inline in that plan.
- **Phase 3 (PluginReaderWorker)**: emits flat-part messages — mechanical; its A/B ("identical
  streams") compares flat parts.
- **Phase 5 (perf)**: phase 4 here IS its Job-element slice — benchmark first, arena/reuse only
  if convicted; protect the carryover-ownership constraint above.
- **Phase 6 (TeeWorker)**: tee deep-copies the flat part (`FlatFileRecord.clone`) and forwards
  payloads by reference — consistent with receiver-ownership.
- **Phase 8 (hygiene)**: the TransformWorker/SinkWorker/ChannelTypeDefiner kdoc rewrites happen
  in phase 1 here — skip there if landed.

---

## Phase 1 — `JobMessage` carrier

**Goal.** The uniform message replaces `DataRecord`; the reproducing Script→Job run completes.

**Steps.**
1. `JobMessage` (payload + nullable header/flat pair) + `ensureFlat()` + shared `value` header
   constant; delete `DataRecord` (its kdoc's batching/ownership content moves here).
2. Migrate all workers per the impact table (readers emit flat messages; Formula's existing
   column formulas write through the received message's flat part; Preview onto `ensureFlat`;
   Sort buffers messages — no pair bookkeeping needed since the message carries both halves).
3. Boundary: ResultSink yield rule (payload wins, flat-only → ordered Map, buffer raw);
   RunWorker unwrap/wrap; ParameterSource (still alive this phase) wraps its argument as a
   payload message.
4. Framework: TransformWorker/SinkWorker generic collapses to `JobMessage`; descriptive failure
   on a non-message element (names worker, expected/actual class — E7 outcome chip) instead of
   a bare CCE.
5. Notation: port `of:` generics now mean payload type — drop `of: DataRecord` from
   job-worker.yaml (flat-ness is not in the type system); check the typed-channel fixtures
   (`job-typed-channel-test.yaml`, `job-channel-type-mismatch-test.yaml`) still exercise a
   genuine payload-type mismatch. Kdoc pass: TransformWorker/SinkWorker/ChannelTypeDefiner/
   Filter/Formula headers.
6. Tests: fixture mirroring Script-2→Job-3 under `test/` notation (run completes; ResultSink
   yields the payload); Double stream through Filter/Preview/CsvWriter via `ensureFlat`; Map
   payload flattens to keyed columns; existing `exec/job` + `objects/job` suites green (note:
   `SortWorkerTest`/`PivotWorkerTest`/`MultiFileReaderWorkerTest` harnesses cast `as DataRecord`
   — update to `JobMessage`).

**Verification.** `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test`; manual: Script-2 → Job-3
runs clean, Display shows `13`.

## Phase 2 — typed parameters + FormulaSource as THE parameterized source

**Goal.** Parameters are typed declarations in every expression's scope; ParameterSource retires.

**Steps.**
1. Flavour-neutral parameter binding (relocate Script's `ParameterBinding` concept); Job
   `parameters` branch archetype + client editing (reuse Script's parameter editor patterns).
2. Signature: inputs from declarations (`JobSignatureCapability` Parameter role removed, Result
   kept); `JobLogicCompiler`/`JobRun` seeding unchanged (`JobControl.parameter`).
3. Expression facility: parameter accessors (typed, bare by name) added to the
   `CalculatedColumnEval`-lineage codegen; values threaded at compile; Filter/Formula/
   FormulaSource adopt.
4. FormulaSource: stream cursor carry (claim-before-send, code-equality guard — port from
   ParameterSourceWorker before deleting it).
5. Retire ParameterSourceWorker: worker, archetypes/markers, client branch; port J2 fixtures
   (`job-signature-*-test.yaml`, `JobSignatureMigrationTest`) to FormulaSource + declarations.
6. Tests: parameter referenced from a Filter `where` and a FormulaSource; typed signature shows
   in the Script RunStep arguments editor; migration exactness test green via FormulaSource.

**Verification.** Full suites + manual: a Script passes a typed parameter, the Job's editors
show the typed signature, expressions reference it bare.

## Phase 3 — payload formulas + type flow

**Goal.** Typed payloads transform via expressions and their types flow through the graph.

**Steps.**
1. `payload:` expression on FormulaWorker (inference via probe + `StepReturnTypeInference`,
   receiver + `payload` alias scope); Filter `where` gains the payload scope.
2. The validation pass: per-notation-version payload-type walk over `JobChannelDerivation`
   (rules per the Type-inference section); expression compile errors → worker-card validation
   surface (DefinitionErrors precedent); FormulaSource static stream-vs-single from its
   inferred type; RunWorker from child signature.
3. Client: payload types render in the signature/editors (minimal v1 — types + errors; no new
   canvas affordances).
4. Tests: typed payload chain (FormulaSource `(1..n)` → Formula payload expr → ResultSink)
   round-trips with inferred types asserted; shadowing rule (payload member vs column) pinned;
   a broken expression is a validation error, not a run failure.

**Verification.** Suites + manual: the Job-3 rework — `payload: foo`-style expression returns
the computed value to Script-2's Display.

## Phase 4 — performance (benchmark-gated)

Execute as part of job-improvements phase 5: baseline harness first; apply the reuse ceiling
(arenas / pooled flat parts, copy-on-retain, carryover ownership transfer) ONLY where the
benchmark convicts allocation; re-measure; record the table in that plan's as-built notes.
