# FL3 — vertex SPI generalization: capabilities, not classes — implementation plan

> **Status: ✅ DONE 2026-07-21.** Landed as planned. Three deviations, all recorded in the
> constituent plan's tracker: (1) test fixtures use `@Reflect` + the JVM reflective mirror rather
> than extending `FlowVertexTestModule` — R1 landed first, which the plan's adaptation note
> anticipated, so there is no test module and no `register()` call; (2) the capability fixture
> hosts its own callee document (`script-capability-child-test.yaml`) instead of the shared
> `script-engine-child-test.yaml`, because `LinkedLogicDocumentsTest.everyParadigmsHostingArchetypeYieldsTheSameEdge`
> pins exactly which documents call that one and is about the three production paradigms;
> (3) the browser smoke (RunLogic2 ribbon insert + arguments editor round-trip) is unrun —
> manual debt. The `Map<String, String>` risk did not materialize: the default
> `StructuralAttributeDefiner` handles it, so no `FlowArgumentsDefiner` and no kzen-lib change.
>
> Generated 2026-07-19 from `2026-07-16_flow-improvements.md`
> **Phase 3** (master plan Stage B3 opener; FL6 depends on it). Decisions pre-made in the
> constituent plan — do not re-litigate. Every anchor re-verified against current kzen-auto
> master (`ceb699d0`) on 2026-07-19; the FL-plan anchors had drifted (SER2–SER5/Y/G5/G7/TP
> landed since) and are corrected inline. Two constituent-plan claims turned out already fixed
> (see Current-state findings § stale-doc sweep). One session. kzen-auto only — **no kzen-lib
> change is needed anywhere in this plan** (verified: the capability interfaces use only
> `ObjectLocation` / `TupleComponentName` / `ExecutionValue`, all already consumed from
> kzen-auto-common).

## Scope & goal

`FlowRun` and `FlowLogicCompiler` currently dispatch on three **concrete vertex classes**
(`RunLogicVertex`, `FlowInputVertex`, `FlowOutputVertex`) — the god-object shape: a third-party
vertex can never host a child Logic, read run arguments, or contribute to the result tuple.
This phase dissolves those branches into three **capability interfaces** in the common Flow API,
moves message inspection onto `FlowVertex` (deleting `FlowMessageInspector`), enforces the
output-channel contracts (`MutableFlowOutput`), and generalizes `RunLogicVertex`'s
first-parameter-only binding to multi-parameter (wired inputs by order + a notation
`arguments:` literal map). Acceptance criterion: a synthetic capability vertex defined entirely
in the test source set runs with **zero edits to `FlowRun` / `FlowLogicCompiler` / any shared
code**. Behaviour of the three built-ins is identical; every existing Flow document (including
`notation/main/FizzBuzz/FizzBuzz Flow Loop.yaml` — never touch it) keeps running unchanged.

Modules: kzen-auto-common + kzen-auto-jvm, plus one **small deliberate kzen-auto-js addition**
(the minimal `arguments:` editor — the phase's design decisions explicitly include "client
editing of `arguments:` … keep it minimal", even though the phase header lists only
common + jvm; the notation registrations live in kzen-auto-jvm resources regardless).

## Dependencies & coordination

- **FL2 ✓** (met): `FlowRun` is already the per-run-instance / engine-driven shape this phase
  edits. FL1 ✓ supplies the structure suites and `FlowConventions` signature single-sourcing.
- **FL6 depends on this phase** (master-plan rule 9) — the capability interfaces are its
  pre-work. Nothing here anticipates FL6 (no multi-output, no crossing, no nested-loop work).
- **FL4/FL5 independent** — no file contention worth fencing: FL4 is js + `VisualVertexModel.phase()`;
  the only shared vicinity is `VertexController`, which this phase does not edit (the new editor
  is its own file).
- **Reflection plan R1/R2 (parallel)**: the test fixtures follow the **established** convention —
  src/test class + hand-written `ModuleReflection` test module (see findings below; the
  constituent plan's "src/main test-fixtures style" is stale — the Job/Script/Flow suites all
  use src/test + hand-written modules, which is exactly what R2 will later dissolve via R1's
  reflective fallback). Adaptation note: if R1/R2 land first, register the fixtures via the
  reflective path instead of extending `FlowVertexTestModule`; nothing else in this plan changes.
- **G3a (scoped instantiation)** later shrinks the compiler's one `createGraph` per compile;
  the discovery decision below deliberately keeps that walk (rationale in Pre-resolved).
- No `../kzen-project` coordination expected: the Flow vertex SPI is not part of the
  `kzen-auto-plugin` surface (untouched). Implementer should still grep kzen-project for
  `FlowMessageInspector|RunLogicVertex|MutableFlowOutput` before deleting (expected zero).

## Current-state findings (anchors verified 2026-07-19, kzen-auto `ceb699d0`)

### The three concrete-class special cases (all in kzen-auto-jvm)

`kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/flow/FlowRun.kt`:

| Old FL-plan anchor | Verified anchor | What it is |
|---|---|---|
| :132 | **:162** | `if (reference is RunLogicVertex)` → `runChildVertex(...)` + `continue` (branch :160–166, in `run()`'s main loop, *before* the `recoverable` block :171–176) |
| :150 | **:180–182** | `if (reference is FlowOutputVertex)` → harvest `activeVertices[...].message` into `outputAccumulator[reference.tupleComponentName]` (post-vertex, in `run()`) |
| :229 | **:259–263** | `if (reference is FlowInputVertex)` → seed `activeVertexModel.message = execution.inputs.find(reference.tupleComponentName)` + early return (in `runOneVertex`, before `process`) |
| :237 | **:267–271** | `if (reference is FlowOutputVertex)` → capture `singleInputMessage(...)` as the sink's message + early return (in `runOneVertex`) |
| :174–182 | **:204–211** | first-parameter-only binding in `runChildVertex`: `singleInputMessage(...)` + `childLogic.firstParameterName` → 1-component `TupleValue` (helper `singleInputMessage` :227–237) |
| :262–263 | **:280, :296–313** | output-channel drain: pre-process `clear()` (:280) and post-process drain via `FlowUtils.mainOutputAttributeName` (:296–313) |

Imports of the three concrete classes: FlowRun.kt:14–16. `flowMessageInspector` constructor
param :64, used :531; `FlowMessageInspector.truncatedToString` static fallback :525, :534.
KDoc mentions `RunLogicVertex` :42.

`kzen-auto-jvm/.../server/exec/flow/FlowLogicCompiler.kt`:

| Old anchor | Verified | What |
|---|---|---|
| :53–70 | **:61–77** | childLogics discovery: `graphInstance[vertexLocation]?.reference is RunLogicVertex` (:69) over `matrix.verticesByLocation` ordered by `indexInContainer` (:63–65); compiles the callee via `LogicCompiler.compile` (:70–71); stores `FlowChildLogic(childStableId, logic, signature().inputs.components.firstOrNull()?.name)` (:72–75) |
| :28 | **:26, :28–31** | KDoc — see stale-doc sweep: :26 claims "a fresh instance per vertex execution" (false since FL2); the old "FlowDocument.define()" claim is **already gone** |

The graph instance built at :51–52 exists **solely** for this discovery walk (FL1 moved
signature derivation to `FlowConventions`, read at :54–59). `RunLogicVertex` import :8;
`services.flowMessageInspector` passed into `FlowLogic` at :85.

`FlowChildLogic` (`server/exec/flow/FlowChildLogic.kt:15–19`): `childStableId` + `logic` +
`firstParameterName: TupleComponentName?`.

**No other concrete-class dispatch exists anywhere** (whole-repo grep): the client has zero
`is FlowInputVertex`-style branches (RunLogic appears only in comments/yaml); `FlowUtils`,
`FlowStructureValidator`, `FlowConventions` are all metadata/notation-driven already.

### FlowWiring / channel construction

`kzen-auto-common/.../objects/document/flow/FlowWiring.kt` — the `define()` dispatch is at
**:127–151** (old anchor :97–116 drifted): `MutableFlowOutput<Any>()` constructed identically
for all four output classes at :136 (Optional), :139 (Required), :142 (Batch), :145 (Stream);
inputs :129/:132. ⚠️ The `ClassName` keys (:90–107) are `tech.kzen.auto.common.paradigm.flow.api.OptionalOutput`
etc. — **no `.input`/`.output` sub-package**, matching the notation `class:` declarations in
`notation/auto-common/common-flow.yaml:16–46`, *not* the actual Kotlin FQCNs (which live in
`api/input/` + `api/output/`). These strings are notation contract keys — do not "fix" them.

`MutableFlowOutput` (`paradigm/flow/model/channel/MutableFlowOutput.kt`): implements all four
output interfaces (:10–15) with `// TODO: enforce optional/required/stream/batch contracts` (:9).
`set` :20–23, `add` :26–28, stream `set` :31–34, `clear` :40–43, `getAndClear` :69–77,
`consumeAndClear` :63–66. Constructed **only** in FlowWiring (whole-repo grep); consumed only in
FlowRun :280/:296–313. Interface shapes: `OptionalOutput.set`; `RequiredOutput: OptionalOutput`
("Must be called exactly one time"); `BatchOutput: OptionalOutput` + `add`;
`StreamOutput: OptionalOutput` + `set(payload, hasNext)`.

### FlowMessageInspector deletion sweep — complete touchpoint census (grep-verified)

| Touchpoint | Anchor | Action |
|---|---|---|
| The class itself | `kzen-auto-common/.../paradigm/flow/service/format/FlowMessageInspector.kt` | **Delete file** (registry has zero registrations — FL2 note confirmed; the whole `service/format/` package empties) |
| `KzenAutoContext` field + comment | `kzen-auto-jvm/.../server/context/KzenAutoContext.kt:139–141` | Delete field + its 2-line comment |
| `KzenAutoContext` → controller ctor arg | `KzenAutoContext.kt:176` | Drop arg |
| `KzenAutoContext` graphEnvironment registration | `KzenAutoContext.kt:228` | Delete the `.put(ClassName(FlowMessageInspector::class...), ...)` line + import :5 |
| `ServerLogicController` ctor param | `.../server/service/impl/ServerLogicController.kt:90` (import :5) | Drop param |
| `ServerLogicController.compileLogic` | `ServerLogicController.kt:909–911` | Drop from the `LogicCompilerServices(...)` construction |
| `LogicCompilerServices` field + KDoc | `.../server/exec/LogicCompilerServices.kt:36` (import :3, KDoc sentence :22) | Drop field + the "[flowMessageInspector] is Flow's per-vertex message renderer;" clause |
| `FlowLogicCompiler` | `FlowLogicCompiler.kt:85` | Drop from the `FlowLogic(...)` construction |
| `FlowLogic` ctor param | `FlowLogic.kt:31` (import :3), pass-through :46 | Drop |
| `FlowRun` ctor param + calls | `FlowRun.kt:64` (import :12), `.inspectMessage` :531, `truncatedToString` :525/:534 | Drop param; replace calls (step 3) |
| **13 test call sites** (all `context.flowMessageInspector` inside a `LogicCompilerServices(...)` construction) | `JobNotationTest.kt:137` · `JobScratchDirTest.kt:107` · `JobExternalBridgeTest.kt:124` · `JobRunWorkerTest.kt:183` · `JobMigrationTest.kt:192` · `JobDeadlockTest.kt:96` · `ScriptControlFlowTest.kt:160` · `ScriptTraceBoundingTest.kt:166` · `ScriptNotationTest.kt:127` · `ScriptExtensibilityTest.kt:194` · `ReportNotationTest.kt:87` · `FlowMigrationTest.kt:115` · `FlowNotationTest.kt:255` (all under `kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/`) | Drop the argument line, mechanically |
| Docs table row | `kzen-auto/docs/architecture.md:196` (§ 4 service table, `flowMessageInspector` row) | Delete row |

The fallback logic the class carried lives on: `truncatedToString` is a one-liner over
`TraceDisplay.truncatedToString(value, TraceDisplay.maxFlowTraceChars)`
(`kzen-auto-common/.../common/util/TraceDisplay.kt:22, :29`) — becomes a private helper in
`FlowRun`; `ExecutionValue.ofArbitrary` (kzen-lib `ExecutionValue.kt:55`) is called directly.

### Multi-parameter context

- `RunStep` (`.../script/step/control/RunStep.kt:19–37`) is the model: `arguments:
  Map<String, ObjectLocation>` (references, resolved at call time). Its notation
  (`script-jvm.yaml:242–263`): `arguments: {}` body default + `meta: arguments: {is: Map,
  of: [String, ObjectLocation], by: Nominal, editor: RunStepArgumentsEditor}`.
- Flow's variant is **literals**, so the definer differs: `by: Nominal` = `WeakAttributeDefiner`
  (kzen-base.yaml:176–177), which makes weak *references*; a literal map instead uses the
  **default** `StructuralAttributeDefiner`, whose `defineMap` (kzen-lib
  `StructuralAttributeDefiner.kt:155–171`) requires String keys and coerces scalar values —
  `Map<String, String>` works with no `by:` at all.
- `FlowChildLogic.firstParameterName` is derived at compile from
  `childLogic.signature().inputs.components.firstOrNull()?.name` (FlowLogicCompiler.kt:75);
  the full ordered component list is equally available there.
- Wired-input order: `VertexDescriptor.inputNames` is "all declared inputs (required and
  optional), **in metadata order**" (`CellDescriptor.kt:67–71`); wiring resolved per input via
  `matrix.traceVertexBackFrom(descriptor, inputName)` (used by FlowRun :234, FlowUtils :138,
  FlowStructureValidator :41). Geometry: **one grid column per declared input, wired or not** —
  which is why the existing `RunLogic` archetype must NOT gain a second input (it would widen
  every existing document's RunLogic to two columns, breaking FizzBuzz Flow Loop's geometry).
- Readiness (`FlowUtils.inputsReady` :130–156): required inputs are strict (wired + message),
  so a two-`RequiredInput` host runs only when both upstream messages are present; the
  structure lint (`FlowStructureValidator.kt:44–47`) refuses an unwired required input at
  compile ("Required input '…' of '…' is not connected").
- Client: `SelectLogicEditor` (`.../script/display/edit/SelectLogicEditor.kt`) already edits
  `instructions` for the Flow RunLogic archetype (flow-vertex.yaml:184) via
  `AttributeEditorManager` (`.../common/attribute/AttributeEditorManager.kt:84–94` resolves the
  `editor:` metadata name against the autowired `attributeEditors` list — an open registry;
  Flow vertex cards render every editable attribute through it, `VertexController.kt:488–535`).
  `RunStepArgumentsEditor` (`.../script/step/control/RunStepArgumentsEditor.kt`) already
  **enumerates callee parameters for both Script and Flow callees** (:178–216 — Script:
  `parameters` branch objects + type badges; Flow: `FlowConventions.inputParameterNames`) but
  is otherwise Script-bound (values are `ObjectLocation`s picked from the `ScriptStore` lexical
  step tree, :250–269) — not reusable as-is; its parameter-enumeration block is the part to copy.
- Editor registrations are notation objects `is: AttributeEditor` (script-js.yaml:123–165);
  a Flow-side registration goes in flow-js.yaml (currently controllers + ribbon tools only;
  `FlowRunLogicTool` :90–93).

### Test-fixture convention (the "Job synthetic-worker convention", as it exists today)

**Drift from the constituent plan**: fixtures do NOT live in src/main any more. The current,
thrice-established convention is **src/test class + hand-written `ModuleReflection` object +
test-only archetype declared in the test yaml**, registered idempotently by the test before
graph build:

- Flow already has it: `kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/flow/test/`
  — `CountingSinkVertex` + `FlowVertexTestModule` (no `@Reflect`; "the test source set has no
  KSP pass"), archetype declared inside
  `src/test/resources/notation/test/flow-migration-test.yaml:12–23`,
  `FlowVertexTestModule.register()` called by `FlowMigrationTest` (:60).
- Job: `ScratchProbeSourceWorker`/`ScratchWorkerTestModule`, `GatedSourceWorker`/`GatedWorkerTestModule`
  (same package shape under `.../objects/job/worker/test/`).
- Script's extensibility proof: `ShoutStep` + `ScriptStepTestModule`, driven by
  `ScriptExtensibilityTest.thirdPartyStepRunsWithNoCompilerChange` (:64–68) — the direct
  template for this phase's acceptance test.

This is *stronger* for the acceptance proof than src/main: the fixture classes are not in the
product KSP registry at all, so "zero shared-code edits" includes zero KSP/module edits.
(AGENTS.md's "test fixtures must live in src/main" gotcha describes the older `AdhocTask`-era
convention; the R plan's R1/R2 will reconcile that text — do not update the KSP gotcha here.)

### Stale-doc sweep — claim-by-claim verification

| Claimed stale item | Verdict | Action |
|---|---|---|
| `RunLogicVertex` KDoc (`.../objects/flow/vertex/RunLogicVertex.kt:10–22`) | **Stale-to-be**: "The single [input] is passed as the callee's first declared parameter" (:13–14); "FlowRun special-cases this vertex (like it does [FlowInputVertex]/[FlowOutputVertex])" (:17–18) | Rewrite for capability dispatch + multi-param binding (step 5) |
| `FlowInputVertex` KDoc :18–19: "[FlowDocument] reads [tupleComponentName] to build the logic signature's inputs" | **Confirmed false** — the signature derives from notation via `FlowConventions.inputParameterNames` (FlowConventions.kt:66–73), read by `FlowLogicCompiler.kt:54–56`; the class val is read only by FlowRun's seeding | Rewrite: `tupleComponentName` is the `FlowRunInput` capability contract FlowRun seeds from; the signature is notation-derived by FlowConventions |
| `FlowOutputVertex` KDoc :14–15 (same FlowDocument claim) | **Confirmed false** (same reason; `outputResultNames` :77–84) | Same rewrite, output side |
| `FlowConventions.kt:58–59` ("FlowDocument.define()") | **Already fixed** — current :52–59 is `isPipeArchetype`; the signature comment (:30–32) correctly names notation + flow-vertex.yaml; no FlowDocument.define() mention anywhere in the file | Drop from sweep (drift noted) |
| `FlowLogicCompiler.kt:28` ("FlowDocument.define()") | **Already fixed**, but a *different* stale claim sits at **:26**: "the per-vertex mechanics are deferred to [FlowRun] at run time (a fresh instance per vertex execution, matching the old engine)" — false since FL2 (instance per run) | Fix :26 (and :30–31's "[RunLogicVertex] callees" → capability wording) while editing the file |
| `FlowMatrix.kt:22` `// TODO: optimize via mutable builder` | **Confirmed present**; construction is once per compile/run + per client render (FL4's business), no builder ever materialized, FL1's suites pin the semantics | Delete the TODO line |
| *(new)* `ScriptLogicCompiler.kt:79–81` comment: "a Flow RunLogicVertex passing its single upstream message to the callee's first parameter" | Becomes stale with multi-param | Reword: "e.g. a Flow logic-host vertex binding its wired inputs to the leading parameters" |
| *(new)* `FlowChildLogic.kt:8–14` KDoc (`firstParameterName`) | Reshaped by step 4 | Rewrite with the field |
| *(new)* `FlowRun.kt` class KDoc :42 ("a [RunLogicVertex] is hosted via …") | Concrete-class mention in the engine file this phase de-couples | Reword to `FlowLogicHost` |

The FL2-era cleanups (retired-`FlowExecution` references; `RunLogicVertex.process()` naming
FlowRun) are confirmed done — `process()` throws `"RunLogicVertex is executed by FlowRun, not
process()"` (:32), which stays accurate (step 5).

## Pre-resolved questions

1. **Compiler childLogics discovery: keep the graph-instance walk** (the implementer's-choice
   item, decided here). The capability is a *Kotlin interface*, and the only authority on
   whether a class implements an interface is an instance of it — the same `is FlowLogicHost`
   check FlowRun performs at run time, so compiler and runner can never disagree. A
   metadata-inheritance detection (à la `FlowConventions.isPipeArchetype`) would require a
   parallel notation marker archetype that a third party could get half-right — interface
   without marker compiles to a host that runs but was never child-compiled (`LogicFailure` at
   run time), marker without interface to a compiled child no branch ever hosts — i.e. it
   reintroduces two sources of truth, the exact defect this phase removes. The walk's cost (one
   `createGraph` per compile, `FlowLogicCompiler.kt:51–52`) is already paid today, is once per
   run rather than per vertex (FL2), and G3a will scope it later. The walk also hands the
   compiler `reference.instructions` and `reference.arguments` for free (compile-time
   validation, step 4).
2. **`FlowChildLogic` carries the full ordered parameter list** — `parameterNames:
   List<TupleComponentName>` replaces `firstParameterName` (derived at compile from
   `childLogic.signature().inputs.components`, the same place :75 derives first-only today).
3. **Binding algorithm (rule A — wired-positional first, arguments fill by name, overlap is an
   error)**: (i) wired inputs — the subset of `VertexDescriptor.inputNames` (metadata order)
   with an upstream per `traceVertexBackFrom` — bind positionally to the callee's leading
   parameters (wired input *i* → parameter *i*); (ii) each `arguments:` entry binds its literal
   to the *named* parameter; (iii) an `arguments:` key that names a positionally-bound
   parameter, or no parameter at all, is a **compile-time `LogicFailure`** (fail-fast, matching
   the structure-lint philosophy); (iv) parameters bound by neither are simply absent from the
   `TupleValue` (the callee's `ParameterBinding` default applies — today's behaviour for extra
   params); (v) wired messages beyond the parameter count are dropped (today's behaviour for a
   0-param callee). **Single-input default check**: a `RunLogic` vertex has one required wired
   input (unwired refuses compile via the lint) with a non-null message at run time (readiness),
   binding the first parameter — byte-identical to today's `firstParameterName` path, and a
   0-param callee still gets `TupleValue.empty`.
4. **`arguments:` literals are verbatim `String`s** (`Map<String, String>`, default
   `StructuralAttributeDefiner`, no `by:`). No type coercion in v1 — Script parameter types are
   advisory (`ScriptLogicCompiler.kt:81` "Types stay any; the binding is by name") and a Flow
   callee has untyped parameters. Coercion-by-declared-parameter-type is a recorded follow-up,
   not built. Document the String-ness in the archetype `description` and KDoc.
5. **`arguments` lives on the `FlowLogicHost` interface with a defaulted getter**
   (`val arguments: Map<String, String> get() = mapOf()`) so FlowRun and the compiler stay
   fully generic and a minimal third-party host needn't declare it.
6. **Two-input variant = new product archetype `RunLogic2` + new class `RunLogicVertex2`** —
   NOT a second input on the existing `RunLogic` (geometry: one column per declared input;
   widening `RunLogic` would corrupt every existing document, incl. FizzBuzz Flow Loop). Both
   inputs `RequiredInput`, named `first`/`second` (the `SelectLast` naming precedent), so
   readiness is strict-deterministic. Registered in the palette (`FlowRunLogic2Tool`).
7. **Capability precedence**: a vertex implementing several capabilities is dispatched
   host-first (`FlowLogicHost` → `FlowRunInput` → `FlowRunOutput`, matching the branch order in
   FlowRun); documented in the interfaces' KDoc, not enforced.
8. **Signature derivation stays notation-driven** (FL1's single-sourcing, deliberately NOT
   generalized here): a third-party `FlowRunInput`/`FlowRunOutput` participates in run-time
   seeding/harvest by capability, but appears in the *declared* `LogicSignature` only if its
   archetype chains to `FlowInput`/`FlowOutput` in notation
   (`FlowConventions.signatureComponentNames` :87–112 is inheritance-chain-based, so
   `is: FlowInput` subtypes are found). The engine accepts arbitrary `TupleValue` inputs
   regardless of declared signature, so the acceptance test drives the fixture by named
   argument directly. One KDoc sentence on `FlowRunInput` records this split.
9. **Channel-contract enforcement placement**: the double-set guard lives inside
   `MutableFlowOutput.set` (the channel knows; it carries a construction-time label for the
   message); the required-emitted check lives in FlowRun's drain (the runner knows the vertex
   location; only the generic `process` path ever reaches it, so capability vertices whose
   declared `output` channel is never written — `FlowInputVertex`, `RunLogicVertex`, both
   early-return — are naturally exempt, exactly as today).
10. **Fixture placement**: src/test + `FlowVertexTestModule` extension (see findings). The
    constituent plan's src/main instruction is superseded by the on-the-ground convention.

## Step-by-step implementation

### Step 1 — capability interfaces + `inspectMessage` (kzen-auto-common)

New files in `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/flow/api/`:

- `FlowRunInput.kt` — `interface FlowRunInput { val tupleComponentName: TupleComponentName }`.
  KDoc: source-vertex capability; FlowRun seeds the vertex's message from the run's input tuple
  (`execution.inputs.find(tupleComponentName)`) instead of calling `process`; note the
  signature-derivation split (pre-resolved 8) and host-first precedence (pre-resolved 7).
- `FlowRunOutput.kt` — `interface FlowRunOutput { val tupleComponentName: TupleComponentName }`.
  KDoc: sink-vertex capability; FlowRun captures the single upstream message as the vertex's
  message and harvests it into the result tuple under `tupleComponentName`.
- `FlowLogicHost.kt` —
  ```kotlin
  interface FlowLogicHost {
      val instructions: ObjectLocation
      val arguments: Map<String, String> get() = mapOf()
  }
  ```
  KDoc: hosted-child capability (`Execution.host`); binding rule A verbatim (pre-resolved 3–4);
  note that `instructions` should be declared `is: ObjectLocation` in the vertex's metadata so
  `LinkedLogicDocuments` (`.../server/service/impl/LinkedLogicDocuments.kt:16–24, :62–67`)
  discovers the callee for live-edit migration — notation-driven, no registration needed.

`FlowVertex.kt` gains (after `inspectState`, :38):
```kotlin
/**
 * Non-functional structured view of an emitted [message], like [inspectState] for the message
 * channel — the emitting vertex knows its message types. Default null: the runner falls back
 * to ExecutionValue.ofArbitrary (basics) then a truncated toString. Must be cheap and must not
 * mutate; called under trace throttling. A thrown exception is swallowed by the runner
 * (a trace must never fail a run the vertex itself survived).
 */
fun inspectMessage(message: Any): ExecutionValue? = null
```
(`ExecutionValue` is already imported at :3.)

### Step 2 — channel contract enforcement (kzen-auto-common)

New `FlowOutputKind.kt` in `paradigm/flow/model/channel/`:
`enum class FlowOutputKind { Optional, Required, Batch, Stream }`.

`MutableFlowOutput.kt`: constructor becomes
`class MutableFlowOutput<T>(val kind: FlowOutputKind, private val label: String)`; delete the
`// TODO: enforce ...` (:9). Guards:
- `set(payload)` (:20–23) and `set(payload, hasNext)` (:31–34): when `kind != Batch`, prepend
  `check(buffer.isEmpty()) { "Output '$label' already set without being consumed (a non-batch
  output emits at most one item per execution; use BatchOutput for multiple)" }`.
- `add` (:26–28) unguarded (the BatchOutput contract).
- No other behaviour change (`clear`/`getAndClear`/`consumeAndClear`/`streamHasNext` as-is);
  the pre-process `clear()` (FlowRun:280) means the guard is naturally per-execution.

`FlowWiring.define` (:127–151): construct with the declared kind + a location label computed
once before the `when` (`val label = "${attributeName.value} of $objectLocation"`):
```kotlin
optionalOutputClass -> MutableFlowOutput<Any>(FlowOutputKind.Optional, label)
requiredOutputClass -> MutableFlowOutput<Any>(FlowOutputKind.Required, label)
batchOutputClass    -> MutableFlowOutput<Any>(FlowOutputKind.Batch, label)
streamOutputClass   -> MutableFlowOutput<Any>(FlowOutputKind.Stream, label)
```

### Step 3 — FlowRun retargets (kzen-auto-jvm)

All in `FlowRun.kt`; net effect: **imports :14–16 disappear entirely** (no
`server.objects.flow.vertex` dependency remains) — replaced by the three capability interfaces
and `FlowOutputKind`.

- :162 `reference is RunLogicVertex` → `reference is FlowLogicHost` (comment :160–161 and KDoc
  :42 reworded; helper KDoc :188–193 reworded).
- :180 and :267 `reference is FlowOutputVertex` → `reference is FlowRunOutput`.
- :259 `reference is FlowInputVertex` → `reference is FlowRunInput`.
- `runChildVertex` (:194–224) — generalized binding per pre-resolved 3:
  - replace the `singleInputMessage` use (:204) with a new
    `wiredInputMessages(vertexLocation, matrix): List<Any?>` (walk `descriptor.inputNames` in
    order, include only inputs with a `traceVertexBackFrom` hit, take each source's
    `activeVertices[...]?.message`);
  - build the `TupleValue`: positional zip of `childLogic.parameterNames` with the wired
    messages, then append each `(reference as FlowLogicHost).arguments` entry as
    `TupleComponentValue(TupleComponentName(name), literal)` (compile already validated names);
  - `LogicFailure` message :202 generalized: `"Logic-host vertex child not compiled: $vertexLocation"`.
- `singleInputMessage` (:227–237) stays (still used by the `FlowRunOutput` capture :268) — its
  KDoc gains "(sink capture; hosts use wiredInputMessages)".
- **Required-output check** in `runOneVertex`'s drain: after :297 resolves `output`, before the
  buffered reads:
  ```kotlin
  if (output != null && output.kind == FlowOutputKind.Required && output.bufferIsEmpty()) {
      throw IllegalStateException(
          "Required output of $vertexLocation was not set (RequiredOutput must emit exactly once per execution)")
  }
  ```
  This sits inside the `recoverable` wrapper (:171–176) like any vertex error → renders the
  error on the card and parks Suspended(Error) under pause-on-error, else fails the run. The
  double-set guard (step 2) throws inside `process()` → same surfacing. Capability vertices
  never reach this path (early returns), so `FlowInputVertex`/`RunLogicVertex`'s decorative
  never-written `RequiredOutput` channels stay legal — note this in the check's comment.
- **`inspectMessage` dispatch** in `traceVertex` (:529–536):
  ```kotlin
  val messageValue = model.message?.let { message ->
      try {
          @Suppress("UNCHECKED_CAST")
          (instance.reference as FlowVertex<Any?>).inspectMessage(message)
              ?: ExecutionValue.ofArbitrary(message)
              ?: truncatedToString(message)
      }
      catch (e: Exception) {
          truncatedToString(message)
      }
  }
  ```
  with a private `truncatedToString(value: Any): ExecutionValue =
  ExecutionValue.of(TraceDisplay.truncatedToString(value, TraceDisplay.maxFlowTraceChars))`
  replacing both `FlowMessageInspector.truncatedToString` calls (:525, :534). Drop the
  `flowMessageInspector` constructor param (:64).

### Step 4 — compiler + carrier (kzen-auto-jvm)

- `FlowChildLogic.kt`: `firstParameterName: TupleComponentName?` →
  `parameterNames: List<TupleComponentName>`; KDoc rewritten (binding-rule reference).
- `FlowLogicCompiler.kt`:
  - :69 `reference is RunLogicVertex` → `is FlowLogicHost` (import swap :8 → the common
    interface; no `server.objects.flow.vertex` import remains);
  - :75 store `childLogic.signature().inputs.components.map { it.name }`;
  - **compile-time argument validation** (new, inside the discovery loop): with
    `parameterNames` and the wired-input count (walk the vertex descriptor's `inputNames` with
    `traceVertexBackFrom`, count hits), for each `reference.arguments` key: unknown name →
    `LogicFailure("Argument '<name>' of '<vertexName>' does not match a parameter of
    <instructions>: <parameterNames>")`; name within the first wired-count parameters →
    `LogicFailure("Argument '<name>' of '<vertexName>' conflicts with a wired input (parameter
    is already bound by position)")`;
  - :85 drop `services.flowMessageInspector`; KDoc :26 + :28–31 fixed (per the stale-doc sweep).
- `FlowLogic.kt`: drop the param (:31), import (:3), pass-through (:46); KDoc :18 reword
  "RunLogicVertex callees" → "logic-host callees".
- FlowMessageInspector deletion sweep — execute the touchpoint table from Current-state
  findings verbatim (context, controller, services, docs row, 13 test sites, file deletion).

### Step 5 — built-in vertices implement the capabilities (kzen-auto-jvm)

- `FlowInputVertex.kt`: `: StatelessFlowVertex, FlowRunInput`; `tupleComponentName` gains
  `override`. KDoc rewritten (drop the false FlowDocument claim :18–19; name the capability).
- `FlowOutputVertex.kt`: `: StatelessFlowVertex, FlowRunOutput`; `override val
  tupleComponentName`. KDoc rewritten (:14–15 claim).
- `RunLogicVertex.kt`: `: StatelessFlowVertex, FlowLogicHost`; ctor
  `(override val instructions: ObjectLocation, override val arguments: Map<String, String>,
  input, output)` — attribute name = property name for reflection. `process()` keeps throwing
  its existing accurate message (:31–33). KDoc rewritten per sweep. (KSP regenerates the
  `KzenAutoJvmModule` entry automatically — the attribute list grows `arguments`.)
- New `RunLogicVertex2.kt` beside it:
  ```kotlin
  @Reflect
  class RunLogicVertex2(
      override val instructions: ObjectLocation,
      override val arguments: Map<String, String>,
      @Suppress("unused") private val first: RequiredInput<Any?>,
      @Suppress("unused") private val second: RequiredInput<Any?>,
      @Suppress("unused") private val output: RequiredOutput<Any?>
  ): StatelessFlowVertex, FlowLogicHost {
      override fun process() {
          throw IllegalStateException("RunLogicVertex2 is executed by FlowRun, not process()")
      }
  }
  ```
  KDoc: the two wired inputs bind the callee's first two parameters (rule A).

### Step 6 — notation (kzen-auto-jvm resources)

`notation/auto-jvm/flow/flow-vertex.yaml`:
- `RunLogic` (:172–191): add body default `arguments: {}` (palette-insert body-default rule —
  the Job gotcha) and meta entry:
  ```yaml
  arguments:
    is: Map
    of:
      - String
      - String
    editor: RunLogicArgumentsEditor
  ```
  (no `by:` — default `StructuralAttributeDefiner`; `by: Nominal` would make references).
  Description gains "; 'arguments' binds literal text to named parameters".
- New `RunLogic2` archetype after it: `is: FlowVertex`, class `...RunLogicVertex2`, icon
  `"material-symbols:play-arrow"`, title `"Run (2 inputs)"`, body defaults `instructions: ""`
  + `arguments: {}`, meta: `instructions` (same `is: ObjectLocation, by: Nominal, editor:
  SelectLogicEditor, summary: ReferenceLinkAttributeView` — the ObjectLocation metadata is what
  keeps `LinkedLogicDocuments` live-edit widening working), `arguments` (as above),
  `first`/`second` `{is: RequiredInput, by: FlowWiring}`, `output` `{is: RequiredOutput,
  by: FlowWiring}`.

`notation/auto-js/document/flow-js.yaml`:
- `FlowRunLogic2Tool: {is: RibbonTool, parent: FlowInsertGroup, delegate: RunLogic2}` (after
  :90–93).
- Editor registration: `RunLogicArgumentsEditor: {is: AttributeEditor, class:
  tech.kzen.auto.client.objects.document.flow.edit.RunLogicArgumentsEditor$Wrapper}`.

**Existing-document compatibility**: existing `is: RunLogic` objects inherit the archetype's
new `arguments: {}` body default — no user yaml changes, the constructor receives an empty map,
binding degenerates to today's single-input rule. Never edit `notation/main/**`.

### Step 7 — minimal client `arguments:` editor (kzen-auto-js)

New `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/flow/edit/RunLogicArgumentsEditor.kt`
(the `flow/edit/` package is otherwise AE1's demolition zone — this is a NEW modern-style file,
not part of the Old fork; AE1 only deletes `*Old.kt`, so coordination is trivial):
- Modeled on `RunStepArgumentsEditor`'s shell: `AttributeEditor` `@Reflect` `Wrapper`
  (autowired into `AttributeEditorManager`'s list), `ClientStateGlobal.Observer`.
- `onClientState`: guard `props.objectLocation !in graphNotation.coalesce`; resolve the sibling
  `instructions` value; **copy the callee-parameter enumeration block from
  RunStepArgumentsEditor.kt:178–216** (it already handles Script + Flow callees); read the
  current `arguments` `MapAttributeNotation` into `Map<String, String>`.
- Render: one MUI `TextField` row per callee parameter (label = parameter name, value = literal
  or empty; skip the type badge for minimal), plus the unused-key + remove affordance copied
  from :433–459. No ScriptStore, no predecessors, no autocomplete.
- Commit on change (debounced like `TextAttributeEditor`, or commit-on-blur — implementer's
  pick, smallest wins): `UpsertAttributeCommand(objectLocation, attributeName,
  MapAttributeNotation(entries mapped to ScalarAttributeNotation(literal)))`, dropping
  empty-string entries so an untouched field adds no notation.
- What already exists and is reused untouched: `SelectLogicEditor` (instructions),
  `AttributeEditorManager` routing by `editor:` metadata, `TextAttributeEditor` styling
  conventions, `FlowConventions.inputParameterNames` (the Flow-callee signature source).

### Step 8 — test fixtures + acceptance tests (kzen-auto-jvm src/test)

Extend `.../server/exec/flow/test/` + `FlowVertexTestModule.register()` with (no `@Reflect`):
- `AliasInputVertex(alias: String, output: RequiredOutput<Any?>)`: `StatelessFlowVertex,
  FlowRunInput`; `tupleComponentName = TupleComponentName("aliased-$alias")` (the "transformed
  name" — proves FlowRun honours the interface val, not any notation convention); overrides
  `inspectMessage` (e.g. `ExecutionValue.of("inspected:$message")`) to pin the new dispatch.
- `DelegateHostVertex(instructions: ObjectLocation, input: RequiredInput<Any?>,
  output: RequiredOutput<Any?>)`: `StatelessFlowVertex, FlowLogicHost` (defaulted `arguments`
  deliberately not overridden — proves the interface default).
- `AliasOutputVertex(input: RequiredInput<Any?>, alias: String)`: `StatelessFlowVertex,
  FlowRunOutput`; `tupleComponentName = TupleComponentName("aliased-$alias")`.
- `SilentRequiredVertex(input: RequiredInput<Any?>, output: RequiredOutput<Any?>)`: process()
  emits nothing.
- `DoubleEmitVertex(input: RequiredInput<Any?>, output: OptionalOutput<Any?>)`: process() calls
  `set` twice.

Test notation (`src/test/resources/notation/test/`), each declaring its test-only archetypes
in-file per the `flow-migration-test.yaml:12–23` convention (`abstract: true`, `is: FlowVertex`,
`class:`, `meta:` channels `by: FlowWiring`; the host archetype's `instructions` meta
`{is: ObjectLocation, by: Nominal}`):
- `flow-capability-test.yaml`: `AliasInputVertex(alias: x)` row 0 → `DelegateHostVertex
  (instructions: test/script-engine-child-test.yaml#main)` row 1 → `AliasOutputVertex(alias: out)`
  row 2, column 0.
- `flow-run-two-param-test.yaml`: `FlowInput(x)` (0,0) + `FlowInput(y)` (0,1) → `RunLogic2`
  (1,0) (occupies columns 0–1 via its two inputs) → `FlowOutput(out)` (2,0); callee = new
  `script-two-param-child-test.yaml` (`parameters/number` Int + `parameters/label` String,
  `ResultStep code: '"" + number + label'`).
- `flow-run-arguments-test.yaml`: `FlowInput(x)` → `RunLogic` + `arguments: {label: "!"}` →
  `FlowOutput(out)`, same two-param callee.
- `flow-run-bad-argument-test.yaml`: `RunLogic` + `arguments: {bogus: "1"}` (unknown-name
  compile failure).
- `flow-required-output-test.yaml` / `flow-double-emit-test.yaml`: FlowInput → contract-violator
  → FlowOutput.

New `FlowCapabilityTest` (beside FlowNotationTest, reusing its `engineFor`/`runFlow`/
`tracedMessages` harness shape, calling `FlowVertexTestModule.register()` first):
- `thirdPartyCapabilityVerticesRunWithNoSharedCodeEdit`: run `flow-capability-test.yaml` with
  `argument("aliased-x", 6)`; assert `Outcome.Success` and
  `value.find(TupleComponentName("aliased-out")) == 7`. One test proves all three interfaces
  end-to-end (seed → host → harvest) with fixture classes absent from every product registry —
  the phase's acceptance criterion, mirroring
  `ScriptExtensibilityTest.thirdPartyStepRunsWithNoCompilerChange`.
- `vertexInspectMessageRendersTrace`: same run; `tracedMessages(engine, ..., "<input vertex>")`
  contains `"inspected:6"`.
- `requiredOutputNotSetFailsTheVertex`: `flow-required-output-test.yaml` → `Outcome.Failed`;
  and with `pauseOnError(true)` parks `Suspended(Error)` (the `vertexErrorPausesWhenPauseOnError`
  pattern, FlowNotationTest:82–99); optionally assert the traced vertex's `error` contains
  "Required output".
- `doubleSetWithoutDrainFailsTheVertex`: `flow-double-emit-test.yaml` → `Outcome.Failed`,
  error contains "already set".

In `FlowNotationTest` (product archetypes only, no module registration needed):
- `runLogic2BindsTwoWiredInputsToFirstTwoParameters`: `flow-run-two-param-test.yaml` with
  `x=6, y="!"` → `"6!"`.
- `runLogicArgumentsLiteralBindsNamedParameter`: `flow-run-arguments-test.yaml` with `x=6` →
  `"6!"`.
- `unknownArgumentNameRefusesToCompile`: `assertFailsWith<LogicFailure>` on
  `flow-run-bad-argument-test.yaml`, message contains `"does not match a parameter"`.

### Step 9 — docs

- `kzen-auto/docs/architecture.md:196`: delete the `flowMessageInspector` service-table row.
- `kzen-auto/AGENTS.md`, the god-object gotcha bullet ("**A Worker's progress is an opaque
  `Map<String, Any?>` …** zero edits to shared code."): append one sentence — e.g. *"Flow
  vertices honour the same contract: `FlowRun`/`FlowLogicCompiler` dispatch on the capability
  interfaces (`FlowRunInput`/`FlowRunOutput`/`FlowLogicHost` in `paradigm/flow/api/`), never on
  concrete vertex classes."*
- Execute the stale-doc sweep table (Current-state findings) — all files already being edited.
- Tick the Phase 3 checkbox in `kzen/plans/2026-07-16_flow-improvements.md`'s tracker + strike
  FL3 in the master plan (maintenance rule), with an as-built note recording the src/test
  fixture-convention deviation and the discovery-mechanism decision.

## Tests

- **Existing suites stay green, behaviour identical for the built-ins**: `FlowNotationTest`
  (all 13 — `runLogicVertexHostsChildScript` :141–149 is the single-input regression pin;
  `arbitraryDomainObjectMessageDoesNotKillRun` :152–174 is the inspection-fallback canary
  proving the FlowMessageInspector deletion lost nothing;
  `appendTextRunsWithOnlyOptionalSuffixWired` + `selectLastMergesWhicheverBranchProducedEachIteration`
  pin that the new channel guards don't fire for compliant vertices), `FlowControllerStepTest`,
  `FlowMigrationTest` (its `CountingSinkVertex` fixture untouched), FL1's commonTest structure
  suites (`FlowMatrixTest`/`FlowDagTest`/`FlowUtilsNextTest`/`FlowStructureValidatorTest`), and
  the 11 Script/Job/Report suites whose only change is the mechanical `LogicCompilerServices`
  arg drop.
- **New**: `FlowCapabilityTest` (4 tests, step 8) + 3 additions to `FlowNotationTest`
  (multi-parameter positive ×2, compile-validation negative ×1).
- Client: no JS unit tests (per the FL ground rules — JS verification stays manual smoke).

## Verification

```powershell
./gradlew :kzen-auto-common:jvmTest          # FL1 structure suites + FlowWiring/MutableFlowOutput common changes
./gradlew :kzen-auto-jvm:test                # incl. FlowNotationTest, FlowControllerStepTest, FlowMigrationTest, FlowCapabilityTest
./gradlew :kzen-auto-js:compileKotlinJs      # commonMain changes + the new editor compile on JS
./gradlew :kzen-auto-test:selfTest           # broad regression net (opt-in, opens Chrome)
```

Manual smoke (dev loop `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`): open FizzBuzz
Flow Loop, Run + Step — unchanged; insert a `RunLogic2` from the ribbon, point `instructions`
at a two-parameter Script, confirm the arguments editor shows a text field per parameter and a
typed literal round-trips through notation. (If the user isn't at the browser this session,
add this to the master plan's smoke-debt list in the as-built note.)

Docs check: `grep -r FlowMessageInspector` across kzen-auto returns nothing;
`kzen-auto/AGENTS.md` god-object bullet carries the Flow sentence.

## Risks & gotchas

- **`Map<String, String>` through the default definer is the one unproven mechanism** (RunStep's
  precedent uses `by: Nominal` references). `StructuralAttributeDefiner.defineMap` (kzen-lib
  :155–171) reads clean for `of: [String, String]`, but verify early with
  `flow-run-arguments-test.yaml`; if the creator side balks, the fallback is a tiny
  `FlowArgumentsDefiner` in kzen-auto-common (the `ParameterDefaultDefiner` precedent) — still
  no kzen-lib change. **Flag loudly if a kzen-lib change ever looks needed; it shouldn't.**
- **Do not add a second input to the existing `RunLogic` archetype** — one grid column per
  declared input means it rewrites every existing document's geometry (FizzBuzz breaks). This
  is why `RunLogic2` is a separate archetype + class (pre-resolved 6).
- **The required-output check must live only on the generic `process` drain path** —
  `FlowInputVertex`/`RunLogicVertex` declare decorative `RequiredOutput` channels that are
  never written and early-return before the check; a blanket post-vertex check would fail every
  input/host vertex.
- **FlowWiring `ClassName` strings are notation keys, not FQCNs** (`…paradigm.flow.api.RequiredOutput`
  with no `.output` segment), matching `common-flow.yaml:16–46`. Don't "correct" them while in
  the file; a mismatch silently turns every channel definition into a failure.
- **`MutableFlowOutput` constructor change is common code** — JS compiles it too
  (`:kzen-auto-js:compileKotlinJs` in verification); the only construction site is FlowWiring
  (grep-verified: no test constructs one directly today).
- **Definition-identity is not the change-detection key** (`FlowControllerStepTest` KDoc:19–25)
  — the new kind/label constructor params churn definition equality per build, which is exactly
  the already-fixed hazard that test pins; it must stay green.
- **13 test files** lose a `LogicCompilerServices` argument — a missed one is a compile error,
  not a silent failure; use the census table, don't re-grep from memory.
- **Fixture registration is idempotent-by-convention** — `FlowVertexTestModule.register()` must
  stay safe to call from both `FlowMigrationTest` and `FlowCapabilityTest` in one JVM (follow
  `ScratchWorkerTestModule`'s pattern verbatim).
- **Argument-literal typing**: a literal bound to an Int-typed Script parameter arrives as
  `String` (pre-resolved 4). The two-param test callee deliberately types its argument-bound
  parameter as `String`. Recorded follow-up: coerce by declared parameter type (not in FL3).
- **`RunLogicVertex` gains a constructor param** (`arguments`) — its KSP registration
  regenerates automatically, but the *archetype* must gain the `arguments: {}` body default in
  the same commit, or every existing document's RunLogic fails definition (missing attribute —
  the Job palette-insert gotcha, silent-failure mode 2).
- **Precedence when capabilities combine** is documented, not enforced (pre-resolved 7) — don't
  add runtime checks for pathological multi-capability vertices.

## Out of scope

- Multi-output vertices, pipe crossing, nested-loop semantics — FL6's decision gate (this
  phase's interfaces are its pre-work; nothing speculative leaks in).
- Client render performance / Error-phase rendering (`VisualVertexPhase.Error`,
  `VertexController`'s dead red branch) — FL4.
- Move/auto-pipe editing UX — FL5; the `flow/edit/*Old.kt` cluster — AE1 (the new
  `RunLogicArgumentsEditor` deliberately does not touch those files).
- Generalizing signature derivation beyond the notation-driven `FlowInput`/`FlowOutput` chains
  (pre-resolved 8 — one KDoc sentence records the split).
- Argument-literal type coercion by callee parameter type (recorded follow-up).
- Per-vertex scoped instantiation / compile-cost reduction — G3a.
- Any kzen-lib change, any `notation/main/**` edit, any engine stepping-semantics change.
