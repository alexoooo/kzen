# DM9b — kzen-auto Logic, JobControl, and DataContext binding migration

> **Status: complete 2026-08-28.** Authority: unified data model §§10.2,
> 11.1 and §14.5 step 5. Constituent tracker: `README.md`.

## Outcome

Every kzen-auto Logic flavour, Job result/host boundary, and data-source context uses `BindingSchema` /
`DataBindings`. The kzen-lib tuple adapter remains published but has no kzen-auto production caller, leaving a green
cleanup point for DM9c.

## Implementation

1. Re-run the DM8 inventory and migrate `ScriptLogic`, `FlowLogic`, `JobLogic`, `WorkerLogic`, `ReportLogic`, their
   compilers, `JobParameters`, `JobResultCollector`, `EngineJobControl`, and controllers to the binding-native
   capability.
2. Change `JobControl` inputs/results/yields and **both** host overloads: positional
   `host(instructions, input: Any?)` and named `host(instructions, arguments: TupleValue)`. The binding-native API
   binds against the callee schema. Migrate or retain positional calls exactly according to DM8's recorded
   disposition; if the inventory preserves first-declared binding for the current single positional production
   caller, record that as the as-built compatibility rule rather than assuming it for arbitrary future callers.
3. Change `DataContext.arguments`/`host`, `WorkerDataContext`, `DesignDataContext`, `LogicDataSource`, `RunWorker`,
   `RunStep`, and every named/dynamic host site. Remove routing parameters before binding and preserve repeated
   request values as listings.
4. Apply defaults once, preserve optional unbound versus present null, reject required omissions before child code,
   and validate produced outputs at settle. Keep Report's settled empty output schema.
5. Migrate tests/fixtures and remove tuple projection from kzen-auto production paths. Do not delete kzen-lib bridge
   symbols in this repository.

## Proof and exit

- Cover concurrent Job yields/migration re-yield, positional and named child calls, optional/defaulted/required
  omission, zero/one/repeated requests, LogicDataSource, every flavour result, and native identity.
- `rg "TupleDefinition|TupleValue|TupleComponent"` across kzen-auto production sources has no dataflow use; any
  incidental wire/diagnostic use is classified for DM9c rather than silently retained.
- Run focused flavour/data-source tests, `FormulaStepTest`, full kzen-auto build, publish all kzen-auto artifacts,
  and rebuild kzen-project standalone. End green with the kzen-lib bridge still available.

## As built — 2026-08-28

- `ScriptLogic`, `FlowLogic`, `JobLogic`, `WorkerLogic`, and `ReportLogic` use `LogicSignature` backed by
  `BindingSchema` and return `DataBindings`. Report has matching empty input/output schemas.
- `JobControl`, `EngineJobControl`, `DataContext`, `LogicDataSource`, `RunWorker`, and `RunStep` bind named inputs
  against the callee schema. The positional host path retains the existing one-argument rule: it targets the first
  declared input; arbitrary multi-input calls use named bindings.
- Required omissions fail before child execution, defaults are applied once, present null stays distinct from
  unbound, and `ProducedBindingsBuilder` validates outputs at settlement. Concurrent Job yields retain first-yield
  binding order while same-name updates preserve their position.
- The production inventory reached zero tuple dataflow callers before the bridge was removed. Focused flavour,
  data-source, migration, native-identity, and Formula tests passed; the complete kzen-auto build and publication
  were green.
