# DM9 — core Logic, JobControl, and DataContext binding cutover

> **Status: ready after DM8. One cross-repository implementation session.** Authority: unified data model §§10.2,
> 11.1, 14.5 step 5, and the binding/end-to-end gates in §15.

## Outcome

`Logic.signature`, `Logic.run`, `Execution.inputs`, and `Execution.host` use binding schemas/instances end to end.
Job results, named child arguments, and data-source contexts use the same model. Tuple compatibility bridges are
deleted; omission is legal only when the callee declares optional/defaulted presence.

## Preconditions and anchors

- DM8 inventory is complete, the Report choice is implemented, and kzen-lib artifacts are published.
- Re-check kzen-lib `Logic`, `LogicSignature`, `Execution`, `Outcome`, `RunEngine`, `LogicDefinition`, and trace
  projections. In kzen-auto re-check `JobLogic`, `JobRun`, `WorkerLogic`, `JobParameters`, `JobResultCollector`,
  `EngineJobControl`, `RunWorker`, `LogicDataSource`, `WorkerDataContext`, and `DesignDataContext`.
- Preserve ambient execution resources/context bindings as typed/raw Kotlin capabilities; they are not dataflow.

## Implementation

1. Change the kzen-lib core interfaces and engine storage atomically: signatures hold input/output schemas; run and
   host return/accept `DataBindings`; `Execution.inputs` is typed/enumerable.
2. Validate executable inputs before child code runs. Apply defaults once, reject required-unbound, and preserve
   optional unbound and present null. Do not deep-walk values on host/handoff.
3. Validate produced outputs at settle through the DM8 builder. Ensure failure attribution identifies the producing
   Logic/frame and binding name without snapshotting the value.
4. Migrate `Outcome.Success`, traces, controllers, requests/results, and tests. Use snapshots only at existing
   wire/trace boundaries; live in-process handoffs retain `DataValue` and native identity.
5. Change `JobControl` to expose input bindings and set output bindings/components; preserve concurrent and
   last-write-wins semantics. Remove `parameter(name): Any?` as the primary contract; native conveniences may project
   explicitly above bindings.
6. Change `DataContext.arguments` and `host` to `DataBindings`. At design time remove routing parameters first,
   preserve repeated request values as a listing, and construct against the callee schema. At runtime bind declared
   names only and fail required omissions.
7. Migrate `RunWorker`, `RunStep` host boundary plumbing needed for compilation, `LogicDataSource`, and every dynamic
   named host site according to DM8 inventory.
8. Delete tuple bridge/types if repository-wide `rg` shows no legitimate owner; otherwise stop and name the remaining
   session/consumer rather than bless parallel models.

## Proof and build order

- kzen-lib engine tests cover nested host missing/null/defaulted distinction, unknown/duplicate input, required
  output failure, hosted result readability after child settle, root result after run settle, and native identity.
- kzen-auto tests cover concurrent Job yields, migration re-yield, omitted optional/defaulted arguments, rejected
  required omission, zero/one/repeated request parameters after routing removal, and typed LogicDataSource results.
- Build/publish kzen-lib first; then full kzen-auto build and FormulaStep canary. Rebuild kzen-project standalone.
- `rg "TupleDefinition|TupleValue|TupleComponent"` across production sources is empty or each residual is documented
  as non-dataflow and explicitly approved. `argument(name): Any?` and `parameter(name): Any?` are gone.

## Exit criteria

- The bindings section of the adoption gate passes across nested Logic and Job/data-source paths.
- Update logic spec and flavour architecture documents by pointer to the unified-model authority; no duplicated
  rationale.
