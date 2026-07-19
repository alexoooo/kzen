# J2 — Job signature: parameters in, results out — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from `2026-07-16_job-improvements.md` Phase 2
> (decisions PRE-MADE there — this document elaborates, it does not re-litigate). All file anchors
> verified against current code on 2026-07-19 (post SER2–SER5, Y, G5, G7, TP1/TP3/TP4); drift from
> the constituent plan's anchors is catalogued in § Current-state findings. Executor: one session.
> **No kzen-lib change is needed** — verified: `Execution.inputs`, `Execution.host(inputs)`,
> `RunEngine(rootInputs)`, `LogicSignature`/`TupleDefinition`/`TupleValue`, and `Outcome.Success(value)`
> all already exist (kzen-lib `exec/engine/`, `exec/tuple/`). Everything below is kzen-auto only.

## Scope & goal

A Job declares parameters and produces an output tuple, so `RunStep` (Script) / `RunLogicVertex`
(Flow) / `RunWorker` (Job) can host it with arguments and consume its result — completing the
"flavours nest each other uniformly" story (`LogicCompiler.kt:20-22` kdoc, verified current).

Deliverables:

1. **SPI**: `JobControl.parameter(name): Any?` + `JobControl.yieldResult(component, value)` with
   null/no-op defaults; inputs + result collector threaded `JobRun` → `WorkerLogic` →
   `EngineJobControl`.
2. **Built-ins**: `ParameterSourceWorker` (source; streams a Collection argument, else emits one
   element; migration cursor) + `ResultSinkWorker` (sink; collects; yields at `onComplete`; single
   element when exactly one arrived) — `src/main` classes, archetypes + `ParameterSource` /
   `ResultSink` semantic markers, palette tools.
3. **Compiler**: `JobSignatureCapability` (kzen-auto-common, `JobServeCapability` pattern);
   `JobLogicCompiler.compile` derives a real `LogicSignature` replacing `LogicSignature.empty`.
4. **Client**: Job branch in `RunStepArgumentsEditor`'s callee dispatch (see findings — the
   constituent plan's "verify, don't rebuild" is 90% true; this one ~15-line branch is the
   remainder). Flow needs zero client work.
5. **Tests**: capability classification/derivation, Script→RunStep→Job round trip, Job→RunWorker→Job
   nesting, pause/edit/resume migration completeness, plus the appendix-mandated Job-side
   frame-trace pin (missing post-rewrite — see findings).

## Dependencies & coordination

- **No hard prerequisite** (master plan Stage B2: J2 opens the strategic spine J2→J3→J4→J9).
- **J3's plan is being prepared in parallel.** J3 touches `JobLogicCompiler` / readers / editors.
  If J3 lands first, re-verify the `JobLogicCompiler.kt` anchors (esp. line 54) and the
  `job-worker.yaml` insertion points before editing — everything else here is disjoint from J3.
- **The extension rule is inviolable**: no Worker-type knowledge in `JobRun` / `WorkerLogic` /
  `EngineJobControl` / `JobChannelDerivation` / synthesis / client general layers. The compiler
  discovers Parameter/Result workers ONLY via `JobSignatureCapability`'s marker-archetype
  inheritance walk; `JobRun` seeds/harvests ONLY via the generic `parameter`/`yieldResult` SPI. A
  third-party parameter source or result sink must be expressible as `@Reflect` + `is:
  ParameterSource` / `is: ResultSink` archetype with zero shared-code edits.
- kzen-lib is consumed from mavenLocal — no kzen-lib edit here, so no publish step needed.
- Per repo rules: stage every new file by explicit path as soon as written (stage only, never
  commit); never touch `notation/main/`.

## Current-state findings (anchors verified 2026-07-19)

**Anchor verification** (constituent plan → current):

| Plan anchor | Current | Status |
|---|---|---|
| `JobLogicCompiler.kt:54` `LogicSignature.empty` | `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/job/JobLogicCompiler.kt:54` | exact |
| `JobRun.kt:183-205` worker hosting | `JobRun.kt:183-205` (`workers.map` :184, `execution.host` :194-198) | exact |
| `JobRun.kt:215` `return TupleValue.empty` | `JobRun.kt:215` | exact |
| `JobControl.kt:19` `checkpoint()` | `kzen-auto-common/.../paradigm/job/control/JobControl.kt:19` | exact |
| `EngineJobControl.kt:112-119` host single-positional bind | **drifted to `EngineJobControl.kt:115-132`** (bind comment :118-120, `execution.host` :131) | ~+3 lines |
| `JobServeCapability.kt:24-64` | `kzen-auto-common/.../objects/document/job/JobServeCapability.kt:24-65` | exact |
| `JobLogic.kt:18-19` "signature is empty in this first port" kdoc; `:34-36` `signature()` | `JobLogic.kt:17-19` and `:34-36` | exact |
| `JobRun.kt:224-241` monitor-held `route` | `JobRun.kt:224-241` (`runBlocking` :234) | exact (phase 7 concern, untouched here) |

**How the pieces sit today:**

- `JobLogic` (`exec/job/JobLogic.kt`) already carries `logicSignature` as a constructor field and
  returns it from `signature()` (:34-36); only the compiler's `LogicSignature.empty` at
  `JobLogicCompiler.kt:54` needs replacing. Both kdocs say "signature is empty in this first port"
  (`JobLogicCompiler.kt:27-28`, `JobLogic.kt:17-19`) — rewrite both.
- `JobRun.run` (`JobRun.kt:91-216`) holds the root `execution: Execution`; `execution.inputs` is
  the Job's typed argument tuple (root run: `RunEngine.rootInputs`, kzen-lib `RunEngine.kt:55-59`;
  hosted: whatever the host passed). Workers are hosted at :194-198 via
  `WorkerLogic(worker, childLogicHost, objectStableMapper, workerScratchDir, workerOutputDir)` —
  the threading seam for inputs + collector.
- `WorkerLogic.run` (`WorkerLogic.kt:52-67`) constructs `EngineJobControl(execution,
  childLogicHost, objectStableMapper, scratchDir, outputDir)` at :59 — second threading seam.
- **Flow precedent for signature derivation** (the parallel the plan names): `FlowConventions`
  (`kzen-auto-common/.../objects/document/flow/FlowConventions.kt:66-112`) derives input/output
  component names from notation, shared by client and server; `FlowLogicCompiler.kt:54-59` maps
  them to `TupleComponentDefinition(TupleComponentName(name), LogicType.any)` and :83 builds
  `LogicSignature(TupleDefinition(inputs), TupleDefinition(outputs))`. Flow's archetypes
  (`flow-vertex.yaml:198-226`): `FlowInput` carries `parameter: ""` + `meta: parameter: String`;
  `FlowOutput` carries `result: ""`. `FlowRun.kt:259-262` seeds an input vertex from
  `execution.inputs.find(tupleComponentName)`; :554-556 harvests outputs into the returned tuple.
- **Port element types** are readable from metadata generics: a port declared
  `output: {is: ChannelOutput, of: DataRecord}` resolves to `attributeMetadata.type` =
  `ChannelOutput<DataRecord>`; `ChannelTypeDefiner.kt:152` reads `portType.generics.getOrNull(0)`.
  `JobChannelPorts.kindOf(type)` (`JobChannelPorts.kt:51-55`) classifies Input/Output/Server/Client.
  `LogicType` is just `LogicType(metadata: TypeMetadata)` (kzen-lib `exec/logic/model/LogicType.kt`).
- **Single-positional convention** already in place on all three host sides, keyed off
  `signature().inputs.components.firstOrNull()`:
  - Job→child: `EngineJobControl.host` :118-127 binds the single element to the child's first
    declared parameter.
  - Flow→child: `FlowLogicCompiler.kt:75` caches `firstParameterName`; `FlowRun.kt:207` binds.
  - Script→child: `RunStep.run` (`objects/script/step/control/RunStep.kt:29-37`) passes the full
    named-argument `TupleValue` (from its `arguments` map) — a Job callee's parameters just work
    once the names exist.
  So once `JobLogic.signature()` is real, **RunWorker-hosting-a-Job and RunLogicVertex-hosting-a-Job
  need zero code** — the binding activates automatically.

**Drift / rescopes found (à la graph-plan 5b):**

1. **Client step 4 "the signature shows up automatically … verify, don't rebuild" is FALSE for
   the RunStep arguments editor.** `RunStepArgumentsEditor.onClientState`
   (`kzen-auto-js/.../objects/document/script/step/control/RunStepArgumentsEditor.kt:165-247`)
   dispatches on the callee's document type: `FlowConventions.isFlow` → Flow names (:191-194),
   **else assumes the Script shape** (nested `ParameterBinding` objects under `parameters`,
   :196-212). A Job callee falls into the Script branch, finds no `parameters` branch, and renders
   **zero argument rows**. Rescope: add an `else if (JobConventions.isJob(...))` branch following
   the existing Flow precedent (~15 lines incl. type badges). This is the ONLY client edit.
   "Flow's signature editor" needs nothing: no Flow client code renders a callee's parameters
   (verified — zero signature/parameter hits under `objects/document/flow/`); Flow's binding is the
   server-side `FlowChildLogic.firstParameterName` above. `LogicSignatureEditor` /
   `ResultSignatureEditor` (`objects/document/common/signature/`) edit a **Script's own** declared
   signature (ParameterBinding objects) — not applicable to Job (a Job declares via workers) — no
   change.
2. **Appendix frame-trace pin: missing post-rewrite, and the behaviour itself drifted.** The
   retired `JobNestedLogicTest` pinned (a) re-entry fresh trace buffer, (b) parallel callers
   distinct buffers, (c) completed Job-hosted child's trace not retained. Post-rewrite pins exist
   only Script-side (`SubScriptTraceScopingTest.subScriptReEntryGetsAFreshTraceBufferPerInvocation`;
   `RunEngineLogicTraceTest` merge rule). No Job-side pin exists. Moreover (c) inverted:
   `EngineJobControl.host` (:131) uses the engine defaults — `retainTrace = true` and
   `callerStableId = null` — so completed Job-hosted children ARE retained now (one node per
   element; cf. `Execution.host` kdoc's "long streaming host passes false", kzen-lib
   `Execution.kt:116-121`), and RunWorker invocations carry no call-site attribution (Script's
   `ScriptRunContext.kt:388-393` passes `currentStableId`; Job passes nothing). **J2 adds the pin
   for what exists** (distinct executions per hosted invocation, shared stableId, retained) and
   records the retainTrace/callerStableId questions as findings routed to J7/J8 — changing them is
   a behavioural decision outside J2's pre-made scope.
3. `EngineJobControl.kt:112-119` → `:115-132` (minor line drift, table above).
4. Marker placement: the constituent plan says "semantic archetypes in job-jvm.yaml". The exact
   precedent for a semantic marker referenced by a **common** classification object is
   `SummaryServer`, which lives in **`common-job.yaml`** (:59-71, beside the `Worker` archetype the
   new markers refine). This plan puts `ParameterSource`/`ResultSink` in `common-job.yaml` — a
   file-placement refinement (both files are bundled/served identically), not a design change.
5. Everything else in phase 2's decision block verified intact: `JobChannelSynthesis` blank-port
   auto-wire will pair the new single-port workers with adjacent workers with no change
   (`JobChannelDerivation.kt:84-93`); `WorkerDisplayDefault` is inherited from the `Worker` base
   (`common-job.yaml:14`) so no display work; the palette needs one `RibbonTool` per new worker
   (`job-js.yaml:134-257` pattern); `RunStep.definition`'s non-Script return-type fallback
   `TupleDefinition.ofMain(LogicType.any)` (`RunStep.kt:49-58`) stays correct for a Job callee.

## Pre-resolved questions (decisions, with the reasoning pinned)

1. **SPI signatures + defaults** (plan-decided null/no-op, NOT default-throw — contrast
   `outputDir()`'s deliberate default-throw):
   ```kotlin
   fun parameter(name: String): Any? = null
   fun yieldResult(component: String, value: Any?) {}
   ```
   Platform-neutral (String/Any only — `JobControl` stays JS-safe in commonMain). `parameter`
   returns null for unbound/unknown names (indistinguishable from a bound null — acceptable,
   matches `TupleValue.find`). `yieldResult` is last-write-wins per component name.
2. **ResultSink component naming**: `ResultSinkWorker` carries a `result: ""` attribute (Flow's
   `FlowOutput.result` parity); **blank defaults to `main`** (`TupleComponentName.main` = "main").
   Rationale: the common case (one sink, default config) must satisfy the hosts' harvest
   convention — `RunWorker.onElement` and `RunStep.run` both read `.mainComponentValue()` — with
   zero configuration. (Flow filters blank names instead; Job diverges deliberately, for the
   palette-insert-and-it-works path.) Blank `parameter` on a ParameterSource IS filtered from the
   signature (Flow parity; an unnamed source streams `parameter("")` = null — an authoring error
   that stays visible, not a crash).
3. **Single-element unwrap**: `ResultSinkWorker` yields the lone element when exactly one arrived,
   the collected `List` otherwise (0 → empty list). Mirrors the hosts' single-positional input
   convention (EngineJobControl.kt:118-127): scalar in → scalar out for the per-element
   RunWorker round trip.
4. **ParameterSource migration needs a cursor** (refinement of the plan's "parameter values are
   run-constant (no carry needed)" — the *values* need no carry because the rebuilt run re-receives
   identical `execution.inputs`; but the *stream position* must carry, or a mid-stream migrate
   re-emits already-delivered elements while the carried ResultSink accumulation keeps the old ones
   → duplicates, breaking the plan's own "result still complete" migration test). Implementation is
   the existing claim-before-send cursor precedent, verbatim from `GatedSourceWorker`
   (`src/test/.../worker/test/GatedSourceWorker.kt:54-78`): `@Volatile nextIndex`, incremented
   BEFORE `emit.send` (a send parked mid-flush holds its payload in the channel's `inFlight`,
   which `JobChannel.drainBuffered` carries — so the resumed source must not re-send it), captured
   with a config guard on the `parameter` name (readers' config-changed pattern:
   `CsvReaderWorker.kt:122-155`).
5. **ResultSink accumulation carries UNCONDITIONALLY and is NOT cleared on yield** (Sort's-buffer
   precedent, `SortWorker.kt:166-183`, minus Sort's clear-after-emit): the buffered input is valid
   whatever the `result` name; and after a migrate the rebuilt `JobRun` has a FRESH (empty)
   collector, so the relaunched sink (Job relaunches completed workers — logic-spec §5 "adopts the
   'done' state") must re-drain the (now instantly-closed) channel and **re-yield at `onComplete`**
   — which it does for free precisely because yield is an idempotent overwrite and the accumulation
   survived. Clearing on yield (Sort-style) would silently lose the result across a post-completion
   edit. (Sort clears because it re-EMITS downstream, where a duplicate is corruption; yield has no
   such hazard.)
6. **Result collector**: a new `JobResultCollector` (exec/job, ~20 lines): `@Synchronized
   yield(name: TupleComponentName, value: Any?)` into a `LinkedHashMap` (workers run concurrently
   on engine threads), `@Synchronized toTupleValue(): TupleValue`. First-yield order = component
   order; same-name overwrite keeps position. Owned per `JobRun` (rebuilt empty on migrate — see 5).
7. **Type derivation**: parameter type = the ParameterSource's first Output-kind port's
   `generics[0]` (else `LogicType.any`); result type = the ResultSink's first Input-kind port's
   `generics[0]` (else `LogicType.any`). Built-ins ship untyped ports (like `RunWorker` /
   `FormulaSourceWorker` — what flows is arbitrary); a concrete object or third-party archetype
   opting into `of: DataRecord` gets a typed signature with no code change. For a
   Collection-streaming parameter the `of:` describes the ELEMENT type (plan-decided; document in
   the capability kdoc).
8. **Marker shape**: `ParameterSource` / `ResultSink` are abstract `is: Worker` refinements (the
   `SummaryServer` pattern — semantic name, no own `class:`), each carrying the name attribute
   (`parameter: ""` / `result: ""` + String meta) so third parties inherit the declaration
   contract. Classification = `graphNotation.inheritanceChain(workerLocation).any { name match }`
   — a third-party `is: ParameterSource` worker classifies with zero shared-code edits (the
   CC-17 proof, same as `JobServeCapabilityTest.thirdPartySummarySubtypeIsRecognizedWithoutCodeChange`).
   Neither marker touches `Channel`/`DuplexChannel` (appendix gotcha 1 honoured — both have an
   `is: Worker` parent, so their attributes self-define through the normal chain).
9. **Body defaults** (appendix gotcha 2 — palette insert creates `is: <Worker>` only, so blank ≠
   missing must come from the archetype chain): `parameter: ""` (marker), `output: ""`
   (ParameterSourceWorker); `result: ""` (marker), `input: ""` (ResultSinkWorker). Verified this
   satisfies `JobChannelDerivation.isOpenPort` (blank → open → auto-wired) and definition (the
   constructors take `parameter: String` / `result: String` — blank defined values, never missing).
10. **Unbound parameter at run time**: `parameter(name)` → null → ParameterSourceWorker emits ONE
    null element (the plan's "emits the bound argument value as a single element", applied
    literally to null). No throw — a Job run bare (no host, no arguments) still completes, its
    sink yielding `[null]`-derived output. Collection detection is `is Collection<*>` (plan wording;
    NOT Iterable — leaves e.g. String and IntRange... note: `(1..3)` is an `Iterable` but also NOT
    a Collection? `IntRange` IS a Collection (extends `IntProgression : Iterable`, and `ClosedRange`)
    — actually `IntRange` implements `Iterable<Int>` only. Decision: match on `Collection<*>`
    exactly as the plan says; a range argument arrives via `listOf(...)`/`.toList()` on the caller
    side. Keep the check simple and documented.)
11. **Signature derivation is shared client/server** through the one common object (Flow's
    "the two sides cannot drift" rule): `JobSignatureCapability.signature(...)` is called by
    `JobLogicCompiler` (server) and `RunStepArgumentsEditor` (client). It reads SAVED notation +
    metadata only (ports may be blank/open — irrelevant, the `of:` lives in metadata), so it needs
    no synthesis and no instances.

## Step-by-step implementation

### Step 1 — SPI: `JobControl.parameter` / `JobControl.yieldResult`

**`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/job/control/JobControl.kt`**
— add two defaulted members (after `publishProgress`, before `host`), kdocs in the file's style:

```kotlin
/**
 * The run argument bound to a declared Job parameter [name] — the value the caller passed for the
 * ParameterSource worker that declares `parameter: <name>` (see JobSignatureCapability). Null when
 * the run was started with no such argument (or the argument is null): a parameterized Job run
 * bare still executes, its sources streaming a single null. Values are run-constant — a live-edit
 * migrate re-supplies the same arguments — so no carry is needed here (a streaming source carries
 * only its own position). Default null: an environment without argument binding.
 */
fun parameter(name: String): Any? = null


/**
 * Contribute a named component to this Job run's output tuple (the result a host — a Script
 * RunStep, a Flow Run vertex, a Job RunWorker — receives when the run completes). Harvested once
 * the run settles; last write per [component] wins, so a re-yield after a live-edit migrate is
 * idempotent. The conventional component is "main" (the hosts' single-positional harvest reads
 * it); a Job with several result sinks yields several named components. Default no-op: an
 * environment without result harvesting.
 */
fun yieldResult(component: String, value: Any?) {}
```

No `TupleComponentName` in the SPI surface (String keeps it minimal + platform-neutral, matching
`publishProgress`'s plain-map philosophy).

### Step 2 — Threading: `JobResultCollector` + `JobRun` → `WorkerLogic` → `EngineJobControl`

**New `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/job/JobResultCollector.kt`:**

```kotlin
/**
 * Aggregates the components Job Workers yield (JobControl.yieldResult) into the run's output
 * TupleValue — owned per JobRun (a migrate rebuilds it empty; carried sinks re-yield at their
 * onComplete, which is why yield is last-write-wins). Synchronized: Workers yield concurrently
 * from their own engine nodes. First-yield order is the tuple's component order.
 */
class JobResultCollector {
    private val components = LinkedHashMap<TupleComponentName, Any?>()

    @Synchronized
    fun yieldResult(component: TupleComponentName, value: Any?) {
        components[component] = value
    }

    @Synchronized
    fun toTupleValue(): TupleValue {
        return TupleValue(components.map { TupleComponentValue(it.key, it.value) })
    }
}
```

**`JobRun.kt`** (three edits):
- In `run()` (top, near the `childLogicHost` construction :95): `val resultCollector =
  JobResultCollector()`.
- Worker hosting (:196-198): pass two new args —
  `WorkerLogic(worker, childLogicHost, objectStableMapper, workerScratchDir, workerOutputDir,
  execution.inputs, resultCollector)`.
- `:215`: `return TupleValue.empty` → `return resultCollector.toTupleValue()`.
- Kdoc: extend the class kdoc's capability list with one sentence on parameter seeding / result
  harvest (inputs read off the root execution; collector returned as the run's tuple).

**`WorkerLogic.kt`** — two new constructor params `private val jobInputs: TupleValue`, `private val
resultCollector: JobResultCollector`; `:59` becomes
`EngineJobControl(execution, childLogicHost, objectStableMapper, scratchDir, outputDir, jobInputs,
resultCollector)`. (Its own `signature()` stays `LogicSignature.empty` — a Worker node has no
tuple I/O; parameters reach Workers via the SPI, results leave via yield.)

**`EngineJobControl.kt`** — two new constructor params (same names); implement:

```kotlin
override fun parameter(name: String): Any? {
    return jobInputs.find(TupleComponentName(name))
}

override fun yieldResult(component: String, value: Any?) {
    resultCollector.yieldResult(TupleComponentName(component), value)
}
```

(No throttling, no trace interaction; place after `publishProgress`, before `host`.)

### Step 3 — Notation: markers + worker archetypes + palette

**`kzen-auto-jvm/src/main/resources/notation/auto-common/common-job.yaml`** — append after the
`SummaryServer` block, with a comment block mirroring its style:

```yaml
#######################################################################################################################
# Job signature markers (semantic Worker refinements, the SummaryServer pattern): a Worker whose inheritance
# chain reaches ParameterSource declares one Job input parameter (`parameter:` names it; its output port's
# `of:` types it); one reaching ResultSink contributes one output component (`result:` names it, blank = main;
# its input port's `of:` types it). JobSignatureCapability classifies by chain membership (CC-17), so a
# third-party source/sink is recognized with no code change. The name attributes live HERE so any subtype
# inherits the declaration contract.


ParameterSource:
  abstract: true
  is: Worker
  parameter: ""
  meta:
    parameter: String


ResultSink:
  abstract: true
  is: Worker
  result: ""
  meta:
    result: String
```

**`kzen-auto-jvm/src/main/resources/notation/auto-jvm/job/job-worker.yaml`** — add
`ParameterSourceWorker` after `FormulaSourceWorker` (it is a source) and `ResultSinkWorker` after
`ExploreWorker` (a sink), header comments in the file's descriptive style:

```yaml
# Streams the Job's bound run argument for the parameter it declares (`parameter:`): a Collection
# argument is streamed element-by-element (resuming from its position across a live edit), any other
# value (including an unbound null) is emitted as a single element. The Job-side analogue of Flow's
# FlowInput vertex — what makes a Job invocable with arguments from a Script RunStep / Flow Run
# vertex / Job RunWorker. Output is untyped (any argument); a concrete object may declare `of:` to
# type the Job's signature.
ParameterSourceWorker:
  abstract: true
  is: ParameterSource
  title: "Parameter"
  class: tech.kzen.auto.server.objects.job.worker.ParameterSourceWorker
  output: ""
  meta:
    output:
      is: ChannelOutput
      creator: JobChannelCreator
      editor: SelectChannelEditor
    selfLocation:
      is: ObjectLocation
      by: Self


# Collects every incoming element and, at end-of-stream, yields the collection as the Job's named
# output component (`result:`, blank = main) — the single element itself when exactly one arrived,
# matching the hosts' single-positional convention, so a per-element RunWorker round trip is
# scalar-in / scalar-out. The Job-side analogue of Flow's FlowOutput vertex. The accumulated
# collection carries across a live edit (Sort's-buffer precedent) and the yield is re-applied on
# the rebuilt run.
ResultSinkWorker:
  abstract: true
  is: ResultSink
  title: "Result"
  class: tech.kzen.auto.server.objects.job.worker.ResultSinkWorker
  input: ""
  meta:
    input:
      is: ChannelInput
      creator: JobChannelCreator
      editor: SelectChannelEditor
    selfLocation:
      is: ObjectLocation
      by: Self
```

Note `parameter`/`result` body defaults + metas are INHERITED from the markers; `output: ""` /
`input: ""` sit on the concrete archetypes (gotcha 2 honoured — palette insert of
`is: ParameterSourceWorker` resolves every attribute blank-not-missing through the chain).

**`kzen-auto-jvm/src/main/resources/notation/auto-js/document/job-js.yaml`** — palette entries:

```yaml
ParameterSourceTool:      # under JobGroup_Sources, after MultiFileReaderTool (:152-155)
  is: RibbonTool
  parent: JobGroup_Sources
  delegate: ParameterSourceWorker

ResultSinkTool:           # under JobGroup_Sinks, after ExploreTool (:234-237)
  is: RibbonTool
  parent: JobGroup_Sinks
  delegate: ResultSinkWorker
```

No `WorkerDisplay` object needed — `display: WorkerDisplayDefault` is inherited from the `Worker`
base (`common-job.yaml:14`); the default card renders `parameter`/`result` text fields via
`AttributeEditorManager` and the generic progress scalars.

### Step 4 — Built-in workers (src/main — KSP constraint)

**New `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/ParameterSourceWorker.kt`**
(model: `FormulaSourceWorker` structure + `GatedSourceWorker` cursor; kdoc covering the
stream-vs-single rule, the claim-before-send exactness argument, and the config-guarded cursor):

```kotlin
@Reflect
class ParameterSourceWorker(
    output: ChannelOutput<Any?>,
    private val parameter: String,
    selfLocation: ObjectLocation
):
    SourceWorker<Any?>(output, selfLocation)
{
    // Next element index to emit; claimed BEFORE send (a send parked mid-flush holds its payload in
    // the channel's inFlight, carried by the migration's drainBuffered — the resumed source must not
    // re-send it). @Volatile: written on the worker coroutine, read at the capture barrier.
    @Volatile
    private var nextIndex = 0

    override suspend fun produce(emit: Emitter<Any?>, control: JobControl) {
        val argument = control.parameter(parameter)
        val elements: List<Any?> =
            when (argument) {
                is Collection<*> -> argument.toList()
                else -> listOf(argument)
            }
        while (nextIndex < elements.size) {
            val element = elements[nextIndex]
            nextIndex += 1
            emit.send(element)
        }
    }

    override fun progress(snapshot: Any?): Map<String, Any?> =
        mapOf("emitted" to nextIndex.toLong())

    override fun captureMigrationState(): Any =
        ParameterCursor(parameter, nextIndex)

    override fun loadMigrationState(captured: Any?) {
        val cursor = captured as? ParameterCursor ?: return
        if (cursor.parameter == parameter) {     // config-changed guard: renamed parameter restarts
            nextIndex = cursor.nextIndex
        }
    }

    private class ParameterCursor(val parameter: String, val nextIndex: Int)
}
```

(The `SourceWorker` cadence owns batching/checkpoint/publish — no manual loop scaffolding, per
`Emitter.sourceCadence`. `elements` is re-derived identically on the rebuilt instance because
parameter values are run-constant; the cursor indexes into the re-supplied list, which is why the
argument must be stably ordered — kdoc-note it, `List` from a RunStep argument always is.)

**New `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/ResultSinkWorker.kt`**
(model: `SinkWorker` + `SortWorker`'s `BufferState`; kdoc covering blank→main, single-unwrap,
carry-without-clear and the re-yield-after-migrate rationale from Pre-resolved 5):

```kotlin
@Reflect
class ResultSinkWorker(
    input: ChannelInput<Any?>,
    private val result: String,
    selfLocation: ObjectLocation
):
    SinkWorker<Any?>(input, selfLocation)
{
    private var collected = ArrayList<Any?>()

    override suspend fun onElement(element: Any?, control: JobControl) {
        collected.add(element)
    }

    override suspend fun onComplete(control: JobControl) {
        val component = result.ifBlank { TupleComponentName.main.value }
        val value: Any? =
            if (collected.size == 1) { collected[0] }
            else { collected.toList() }
        control.yieldResult(component, value)
        // NB: collected is deliberately NOT cleared — a post-completion live edit relaunches this
        // worker, which adopts the carried accumulation and re-yields into the rebuilt run's fresh
        // collector (yield is an idempotent overwrite; clearing would lose the result).
    }

    override fun progress(snapshot: Any?): Map<String, Any?> =
        mapOf("collected" to collected.size.toLong())

    override fun captureMigrationState(): Any =
        CollectedState(collected)

    override fun loadMigrationState(captured: Any?) {
        val state = captured as? CollectedState ?: return
        collected = state.collected
    }

    private class CollectedState(val collected: ArrayList<Any?>)
}
```

(Capture is unconditional of `result` — the buffered input is valid under any component name,
exactly Sort's argument for spec-independence. `SinkWorker`'s pre-receive checkpoint is the only
park point, so capture never cuts mid-`onComplete`.)

KSP registers both automatically (`@Reflect`, main source set) — no module edit; a build regenerates
`KzenAutoJvmModule`.

### Step 5 — `JobSignatureCapability` + compiler derivation

**New `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/job/JobSignatureCapability.kt`**
(model: `JobServeCapability`'s kdoc voice + chain walk; ~90 lines):

```kotlin
/**
 * Derives a Job document's Logic signature from its signature-marker Workers — the single source
 * shared by JobLogicCompiler (server) and the callee-parameter editors (client), so the two cannot
 * drift (the FlowConventions precedent). Classification is capability-based, never class-based
 * (CC-17): a Worker whose inheritance chain reaches the ParameterSource marker declares one input
 * parameter (its `parameter` attribute names it; its output port's `of:` element type types it —
 * for a Collection argument the type describes the ELEMENT), one reaching ResultSink declares one
 * output component (`result`, blank = main; typed by its input port's `of:`). Reads saved notation
 * + metadata only (blank/open ports are fine — no synthesis, no instances). Document order is
 * signature order; a blank parameter name is filtered (Flow parity); a blank result name maps to
 * "main" (the hosts' single-positional harvest convention).
 */
object JobSignatureCapability {
    enum class Role { Parameter, Result }

    fun roleOf(graphNotation: GraphNotation, workerLocation: ObjectLocation): Role? {
        if (workerLocation !in graphNotation.coalesce) { return null }   // stale-location guard (client observers)
        val chainNames = graphNotation.inheritanceChain(workerLocation)
            .mapTo(mutableSetOf()) { it.objectPath.name }
        return when {
            JobConventions.parameterSourceObjectName in chainNames -> Role.Parameter
            JobConventions.resultSinkObjectName in chainNames -> Role.Result
            else -> null
        }
    }

    fun signature(graphStructure: GraphStructure, jobMainLocation: ObjectLocation): LogicSignature {
        val graphNotation = graphStructure.graphNotation
        val documentNotation = graphNotation.documents[jobMainLocation.documentPath]
            ?: return LogicSignature.empty
        if (! JobConventions.isJob(documentNotation)) { return LogicSignature.empty }

        val inputs = mutableListOf<TupleComponentDefinition>()
        val outputs = mutableListOf<TupleComponentDefinition>()

        val workerPaths = documentNotation.directNestedObjectPaths(
            NotationConventions.mainObjectPath, JobConventions.workersAttributeName)
        for (workerPath in workerPaths) {
            val workerLocation = ObjectLocation(jobMainLocation.documentPath, workerPath)
            when (roleOf(graphNotation, workerLocation)) {
                Role.Parameter -> {
                    val name = graphNotation.firstAttribute(
                        workerLocation, JobConventions.parameterAttributePath)?.asString() ?: ""
                    if (name.isNotEmpty()) {
                        inputs.add(TupleComponentDefinition(
                            TupleComponentName(name),
                            portElementType(graphStructure, workerLocation, JobChannelPorts.Kind.Output)))
                    }
                }
                Role.Result -> {
                    val name = graphNotation.firstAttribute(
                        workerLocation, JobConventions.resultAttributePath)?.asString() ?: ""
                    val componentName =
                        if (name.isEmpty()) { TupleComponentName.main } else { TupleComponentName(name) }
                    outputs.add(TupleComponentDefinition(
                        componentName,
                        portElementType(graphStructure, workerLocation, JobChannelPorts.Kind.Input)))
                }
                null -> {}
            }
        }
        return LogicSignature(TupleDefinition(inputs), TupleDefinition(outputs))
    }

    // First port of the given kind whose metadata declares an `of:` element type; LogicType.any otherwise.
    private fun portElementType(
        graphStructure: GraphStructure, workerLocation: ObjectLocation, kind: JobChannelPorts.Kind
    ): LogicType {
        val objectMetadata = graphStructure.graphMetadata.get(workerLocation)
            ?: return LogicType.any
        for ((_, attributeMetadata) in objectMetadata.attributes.map) {
            if (JobChannelPorts.kindOf(attributeMetadata.type) != kind) { continue }
            val elementType = attributeMetadata.type?.generics?.getOrNull(0)
                ?: continue
            return LogicType(elementType)
        }
        return LogicType.any
    }
}
```

**`JobConventions.kt`** — add beside `summaryServerObjectName` (:31), comments in file style:

```kotlin
// Signature marker archetypes (common-job.yaml, the SummaryServer pattern): a Worker whose
// inheritance chain reaches one of these declares a Job input parameter / output component.
// JobSignatureCapability classifies by chain membership, so subtypes are recognized (CC-17).
val parameterSourceObjectName = ObjectName("ParameterSource")
val resultSinkObjectName = ObjectName("ResultSink")

// The marker-declared name attributes: a ParameterSource's `parameter` names the run argument it
// streams; a ResultSink's `result` names its output component (blank = main).
val parameterAttributeName = AttributeName("parameter")
val parameterAttributePath = AttributePath.ofName(parameterAttributeName)
val resultAttributeName = AttributeName("result")
val resultAttributePath = AttributePath.ofName(resultAttributeName)
```

**`JobLogicCompiler.kt`** — replace `:54`:

```kotlin
val logicSignature = JobSignatureCapability.signature(
    graphDefinition.graphStructure, jobLocation)
...
    logicSignature,
```

and rewrite the stale kdoc sentence (:27-28) to: signature derived from the signature-marker
Workers via `JobSignatureCapability` (parameters in document order; results harvested by JobRun).
**`JobLogic.kt`** — rewrite kdoc :17-19 likewise ("The signature is derived by JobLogicCompiler
from the document's ParameterSource / ResultSink workers").

(Note `graphDefinition.graphStructure` is the pre-synthesis structure — correct: signature reads
saved notation, matching what the client sees.)

### Step 6 — Client: Job branch in `RunStepArgumentsEditor`

**`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/script/step/control/RunStepArgumentsEditor.kt`**
— in `onClientState` (:189-213), insert between the Flow branch and the Script fallback:

```kotlin
else if (JobConventions.isJob(documentNotation)) {
    val signature = JobSignatureCapability.signature(
        clientState.graphStructure(), instructionsObjectLocation)
    instructionsParameters = signature.inputs.components.map { it.name.value }
    for (component in signature.inputs.components) {
        val metadata = component.type.metadata
        newParameterTypes[component.name.value] =
            LogicTypeOptions.simpleLabel(metadata.className.asString(), metadata.nullable)
    }
}
```

Imports: `tech.kzen.auto.common.objects.document.job.JobConventions`,
`tech.kzen.auto.common.objects.document.job.JobSignatureCapability`. Update the dispatch comment
block (:178-186) to name the three shapes (Script `parameters` branch / Flow input vertices / Job
ParameterSource workers). Untyped Job parameters badge as "Any" (Script parity — its default is
`kotlin.Any`; Flow's no-badge stays as is).

**Verified no-ops (record in as-built, don't touch):** Flow hosting a Job — binding is server-side
(`FlowLogicCompiler.kt:75` + `FlowRun.kt:207`), no Flow client editor renders callee parameters;
`SelectLogicEditor` already lists Jobs (notation-driven `isLogic`; `RunTool` exists);
`LogicSignatureEditor`/`ResultSignatureEditor` are Script-document-own editors;
`RunStep.definition`'s `LogicType.any` fallback for non-Script callees remains correct.

### Step 7 — Housekeeping

- Tick Phase 2 in `kzen/plans/2026-07-16_job-improvements.md`'s tracker + add an as-built note
  (include the drift findings from this plan: RunStepArgumentsEditor branch, missing Job-side trace
  pin now added, `retainTrace=true`/`callerStableId=null` findings routed to J7/J8).
- Strike J2 in `kzen/plans/2026-07-16_master-plan.md` (maintenance rule).
- No `logic-spec.md` change (flavour-agnostic; Job merely starts using existing §3 machinery). No
  `kzen-auto/docs/architecture.md` change required (no Job section exists; do not add one here).
- `git add` each new file by explicit path as written; stage only.

## Tests

All in `kzen-auto-jvm/src/test/` (fixtures under `src/test/resources/notation/test/`); harness
patterns copied from the named precedents. New fixtures reference production archetypes only, so no
new test modules are needed except where noted.

### Fixtures

1. **`job-signature-child-test.yaml`** — the parameterized Job (shared by tests 2–4):
   ```yaml
   main:
     is: Job
     batchSize: 1

   main.workers/params:
     is: ParameterSourceWorker
     parameter: "items"

   main.workers/collect:
     is: ResultSinkWorker
   ```
   (Blank ports → order-synthesized channel; `batchSize: 1` makes one element ≈ one step for the
   stepping/migration tests; blank `result` → `main`.)

2. **`job-signature-script-test.yaml`** — Script→RunStep→Job:
   ```yaml
   main:
     is: Script

   main.steps/Items:
     is: FormulaStep
     code: "listOf(1, 2, 3)"

   main.steps/RunJob:
     is: RunStep
     instructions: "test/job-signature-child-test.yaml#main"
     arguments:
       items: Items
   ```

3. **`job-signature-nested-test.yaml`** — Job→RunWorker→Job (RecordingSinkWorker precedent —
   requires `RunWorkerTestModule.register()`):
   ```yaml
   main:
     is: Job

   main.workers/source:
     is: FormulaSourceWorker
     code: "(1..3)"

   main.workers/run:
     is: RunWorker
     instructions: "test/job-signature-child-test.yaml#main"

   main.workers/sink:
     is: RecordingSinkWorker
   ```

4. **`job-signature-capability-test.yaml`** — classification/derivation fixture (model:
   `job-serve-capability-test.yaml`): a Job with a `ParameterSourceWorker` (`parameter: "items"`),
   a `ResultSinkWorker` (blank result), a plain worker (e.g. `FormulaSourceWorker`), a
   ParameterSource with BLANK name, a ResultSink with `result: "summary"`, plus the CC-17 proof —
   a fixture-declared third-party archetype:
   ```yaml
   TypedParamSource:            # declared in this fixture file (test-only archetype)
     abstract: true
     is: ParameterSource
     class: tech.kzen.auto.server.objects.job.worker.ParameterSourceWorker
     output: ""
     meta:
       output:
         is: ChannelOutput
         of: DataRecord
         creator: JobChannelCreator
       selfLocation:
         is: ObjectLocation
         by: Self
   ```
   (Classification tests never instantiate — notation + metadata only — so reusing the production
   class is safe and needs no test module. The `of: DataRecord` port proves typed derivation.)

### Test classes

1. **`JobSignatureCapabilityTest`**
   (`src/test/kotlin/tech/kzen/auto/common/objects/document/job/` — the `JobServeCapabilityTest`
   placement + `GraphStructure by lazy` boilerplate): `roleOf` classifies Parameter / Result /
   null; third-party `is: ParameterSource` subtype classifies with no code change; `signature()`
   asserts — names + document order; blank parameter filtered; blank result → `main`; named result
   → its name; `of: DataRecord`-typed port yields a `DataRecord`-classed `LogicType`; untyped port
   yields `LogicType.any`; non-Job document → `LogicSignature.empty`.

2. **`JobSignatureTest`** (`src/test/kotlin/tech/kzen/auto/server/exec/job/` — harness boilerplate
   from `JobRunWorkerTest.newEngine` / `JobMigrationTest.compile`):
   - `directRunSeedsParameterAndHarvestsResult` — compile `job-signature-child-test.yaml` via
     `JobLogicCompiler`; assert `jobLogic.signature()` = inputs [items], outputs [main]; run
     `RunEngine(jobLogic, stableId, TupleValue(listOf(TupleComponentValue(TupleComponentName("items"), listOf(1, 2, 3)))))`;
     assert `Outcome.Success` and `outcome.value.mainComponentValue() == listOf(1, 2, 3)` (the
     argument reached the stream AND the result tuple round-tripped, order preserved).
   - `scalarArgumentYieldsScalarResult` — same engine, `inputs = [items = 7]` (non-Collection):
     result `mainComponentValue() == 7` (single-element unwrap both directions).
   - `unboundParameterStreamsSingleNull` — no root inputs: Success, `mainComponentValue() == null`
     (one null element collected → unwrapped).
   - `scriptRunStepBindsArgumentsIntoHostedJob` — compile `job-signature-script-test.yaml#main`
     via the flavour-agnostic `LogicCompiler.compile`; run; assert Success and
     `mainComponentValue() == listOf(1, 2, 3)` (RunStep's named-argument tuple → JobRun seeding →
     harvest → RunStep value; the last-step value is the Script result).
   - `runWorkerHostsParameterizedJobPerElement` — register `RunWorkerTestModule`, reset
     `RecordingSinkWorker`; run `job-signature-nested-test.yaml`; assert Success and recorded set
     == {1, 2, 3} (each element → child's first parameter `items` via the single-positional bind at
     `EngineJobControl.kt:118-127`, streamed as one element, collected, unwrapped, yielded as
     `main`, emitted downstream).
   - **Frame-trace pin (appendix check)** — `hostedChildInvocationsAreDistinctRetainedExecutions`,
     against the existing `test/job-run-host-test.yaml` (or the nested fixture): after Success,
     walk `engine.snapshot().root` to the RunWorker's worker node; assert exactly 3 child nodes —
     distinct `NodeId`s, all sharing the child document's stableId — i.e. each hosted invocation
     was its own execution (fresh trace scope per re-entry) and settled invocations are retained
     under the current `retainTrace = true` default. (Replaces the retired `JobNestedLogicTest`
     pins at the engine grain; the Script-side ghosting pin already lives in
     `SubScriptTraceScopingTest`.)

3. **Migration test** — add to `JobSignatureTest` (or a sibling `JobSignatureMigrationTest` if it
   reads better), modeled line-for-line on
   `JobMigrationTest.migrationResumesReaderAndCarriesPreviewStateLosslessly` (step-loop + live-map
   probe) and its `edit(...)`/`compile(...)` helpers:
   - `pauseEditResumeKeepsResultComplete` — fixture `job-signature-child-test.yaml`, root inputs
     `items = (0 until 50).toList()`, `batchSize: 1` (already in fixture; channels default
     rendezvous). Step-loop (`engine.step(); engine.awaitQuiescent()`) with a guard counter until
     the sink's live progress shows `0 < collected < 50` — read via the `previewCount` pattern
     (`JobMigrationTest.kt:215-223`): the sink node's
     `live[Address.of(EngineJobControl.workerProgressAddressMarker)]` map, key `"collected"`.
     Recompile from notation edited via `UpsertAttributeCommand` on the sink's `result`:
     `"" → "main"` (a semantically-neutral notation change — same component either way — that still
     value-differs the definition and drives a real rebuild). `engine.migrate(editedLogic,
     paused = false)`; await; assert Success and `mainComponentValue() == (0 until 50).toList()` —
     EXACT list equality is the whole proof: a ParameterSource restart duplicates the prefix
     (overshoot), a dropped in-flight element falls short, an accumulation loss drops the prefix,
     and order pins the channel's FIFO carry.

Existing suites (`JobRunWorkerTest`, `JobMigrationTest`, `JobNotationTest`,
`JobChannelDefaultTest`, synthesis tests, `JobServeCapabilityTest`) are untouched and must stay
green — the new archetypes join the whole-graph test notation, which the blank-port precedents
(`job-run-host-test.yaml` et al.) already prove safe.

## Verification

1. `./gradlew :kzen-auto-jvm:test` — full suite (the `exec/job` + `objects/job` nets are the
   constituent plan's baseline), including all new tests above.
2. `./gradlew :kzen-auto-js:compileKotlinJs` (or `:kzen-auto-js:build -x test`) — client branch
   compiles.
3. Manual smoke (`./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`):
   - Sample Job renders + runs unchanged (no signature workers → empty signature → prior
     behaviour).
   - New Job: palette-insert Parameter (Sources group) + Result (Sinks group); set
     `parameter: items`; cards render via the default display.
   - Script with a RunStep pointing at that Job: the arguments editor shows an `items` row with an
     "Any" type badge; bind a prior step; run; the RunStep's value is the Job's result.
4. Confirm `KzenAutoJvmModule` regenerated with both new workers (build output; no hand edit).

## Risks & gotchas

- **Appendix gotcha 1 honoured by construction**: nothing is added to `Channel` / `DuplexChannel`;
  the markers refine `Worker` (which has an `is:` chain), so `parameter`/`result` self-define.
- **Appendix gotcha 2 honoured**: body defaults on the archetype chain (`parameter: ""`,
  `output: ""`, `result: ""`, `input: ""`) — a ribbon insert resolves blank, not missing; verified
  against `JobChannelDerivation.isOpenPort` (blank → open → auto-wired).
- **ParameterSource cursor is load-bearing** (not optional polish): without it the migration test's
  exact-list assertion fails by duplication. Claim-before-send ordering must be preserved verbatim
  (GatedSourceWorker's reasoning; JobChannel dedups a sender completing mid-drain).
- **ResultSink must NOT clear on yield** — clearing (the Sort reflex) silently loses the result
  across a post-completion migrate (fresh collector, no re-accumulation source).
- **Concurrency**: `JobResultCollector` must be synchronized — sinks yield from distinct engine
  threads; multiple ResultSinks in one Job are legal (named components).
- **J3 in parallel**: if J3 lands first, re-verify `JobLogicCompiler.kt` line anchors and
  `job-worker.yaml` insertion points; no semantic overlap expected.
- **Findings routed onward (do NOT fix here)**: `EngineJobControl.host` passes no
  `callerStableId` (RunWorker invocations lack call-site attribution, unlike Script's
  `ScriptRunContext.kt:392-393`) and uses `retainTrace = true` (a long streaming RunWorker retains
  one node per element — the retired "Job-hosted child trace not retained" trade-off inverted by
  the rewrite). Both are behavioural decisions for J7 (bounding) / J8 (hygiene); record them in the
  as-built note. The J2 pin test asserts CURRENT behaviour (retained, distinct) and should be
  updated if J7/J8 change the default.
- **Blank-parameter authoring**: a nameless ParameterSource streams null and is absent from the
  signature (Flow's blank-input parity; Flow has a structure lint, Job does not — acceptable v1,
  candidate for a J8 lint).
- **`Collection` vs `Iterable`**: matching `is Collection<*>` per the plan's wording — an
  `IntRange`/sequence argument arrives as a single element unless the caller `.toList()`s it;
  kdoc'd on the worker.
- **Stale-location guard** in `roleOf` (`!in graphNotation.coalesce`) — client observer callbacks
  can fire with a just-deleted/renamed callee (the documented `inheritanceChain` throw).

## Out of scope (deliberate — do not scope-creep)

- REST/headless "start run with arguments" surface (`ServerLogicController.start` takes no inputs;
  root runs from the UI pass `TupleValue.empty`) — a Job's parameters are exercised via hosting
  and direct-engine tests; a run-with-arguments verb is future work (J5 headless / demand-driven).
- Typed result surfacing in `RunStep.definition` for Job callees (its `LogicType.any` fallback
  stays correct); Flow client rendering of callee parameters (none exists for any flavour).
- `retainTrace`/`callerStableId` changes in `EngineJobControl.host` (routed to J7/J8, above).
- Job-side structure lint (blank parameter names, ParameterSource-not-first ordering advice).
- `JobWorkerProgress` / display changes — the built-ins use the default card and generic scalar
  progress keys only (extension rule: no Worker-specific fields in shared client code).
- Everything in phases 3–9 (format plugins, export parity, perf, fan-out, deadlock precision,
  client sweep, file-backed carry).
