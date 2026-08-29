# DM8 — Logic signature inventory and binding model

> **Status: ready after DM7c. One implementation session.** Authority: unified data model §§4.2, 10–10.1,
> 14.5 step 5, and §15 “Bindings.”

## Settled Report decision

`ReportLogicCompiler` declares `main: String`; `ReportRun.run()` returns no component. Strict output settlement
exposes that contradiction. The 2026-08-28 product decision is that **Report declares no output**, matching its
current successful execution. Remove the false `main` declaration before enabling strict settlement. Do not invent
a status, row count, or run reference from incidental implementation state; any future Report return is a separately
designed feature with an explicit consumer.

## Outcome

Every existing Logic signature is reconciled with actual supplied/produced values, and kzen-lib owns frozen
`BindingSchema`, validated `DataBindings`, structural snapshot defaults, binding state/origin, sensitivity display
policy, and the concurrent last-write-wins output builder. Engine APIs still use the tuple compatibility bridge
through DM9a/DM9b; DM9c owns its deletion.

## Inventory first

1. Enumerate every `LogicSignature`, `TupleDefinition`, `TupleValue`, `Execution.inputs`, `Execution.host`,
   `JobControl.parameter(s)/yieldResult`, both `JobControl.host(ObjectLocation, Any?)` and
   `JobControl.host(ObjectLocation, TupleValue)`, `DataContext.argument/host`, design request binding, Script
   result, Flow output, Job result, Report result, and test fixture in kzen-lib/kzen-auto. Produce a table in this
   file's as-built section: flavour, input names/types/presence/defaults, output names/types, actual producers,
   omission/null use, mismatch, and disposition. For each production positional-host caller, record the intended
   target binding and whether the positional overload survives, becomes an explicitly named call, or is removed.
2. Include dynamic callers and named host sites (`RunStep`, `RunWorker`, `LogicDataSource`), not only compiler-built
   signatures. Scan repeated request values and routing-parameter removal.
3. Resolve every mismatch before enabling strict required-output settlement. Unknown cases stop the session; they are
   not mapped to nullable `Dynamic` merely to get green tests.

## Implementation

1. Add validated/frozen `BindingName`, `DataPresence`, `DataDefault`, `BindingDefinition`, `BindingSchema`,
   `BindingState`, `BindingOrigin`, and `DataBindings` in kzen-lib commonMain. Prefer evolving tuple names only if the
   spike proves it preserves the semantics without a misleading public API; record the naming verdict.
2. Factories reject duplicate/unknown supplied names and an absent root, apply structural snapshot defaults once,
   preserve null vs unbound, align enumeration to schema order, and perform shallow structural/native/root checks.
   They never deep-walk.
3. Refuse a literal default for a declaration with any native requirement. Default decoding always carries its own
   `DataType` through `DataSnapshot`.
4. Add a synchronized produced-output builder: shallow validate on set; last write wins; completed enumeration is
   schema order; settle rejects missing required outputs. Yield chronology is trace metadata, not identity.
5. Implement whole-binding display sensitivity through `SnapshotResult.Redacted/Rejected`; document explicitly that
   it is not taint propagation.
6. Add an internal tuple bridge for DM9a–DM9c only. Name every use, prohibit new tuple call sites, and assign final
   deletion to DM9c.

## Proof and exit

- Cover schema lookup/enumeration, duplicates/unknowns, required/optional/defaulted, unbound vs present-null,
  absent-root rejection, origins, native-default refusal, shallow-not-deep binding, and sensitivity.
- Stress concurrent output yields, repeated-name last-write-wins, schema order, and missing-required settle.
- Pin Report's empty output schema and all inventory dispositions in flavour tests.
- Run common JVM+JS and full kzen-lib build, publish to Maven Local, then focused kzen-auto compiler/flavour tests.
- Exit only with a complete inventory and exactly one compatibility bridge deletion owner (DM9c).

## As-built — 2026-08-28

### Signature and runtime inventory

| Flavour / site | Declared inputs | Declared outputs | Actual binding and production | Reconciled disposition |
|---|---|---|---|---|
| Core `Logic` and test fixtures | Ordered `TupleDefinition`; most fixtures use empty | Ordered `TupleDefinition`; several fixtures falsely used empty while returning `main` | Engine accepted arbitrary tuple names and did not settle required outputs | DM9a makes the engine canonical on `DataBindings`. Each fixture must declare what it returns or return empty; there is no fixture-only waiver. |
| Script | Parameter names in document order, but every type was `Any`; `LogicParameter` separately retained a typed binding and optional default | Parsed result map | Callers bind by name. Runtime can produce only `main`, explicitly or from the terminal step. Parameter lookup used `find ?: default`, conflating omission with supplied null. | DM9b lowers each real parameter contract and uses `Defaulted` for a valid authored default, otherwise `Optional` to preserve callable top-level/bare Scripts. Supplied null remains bound null. Script now rejects a non-`main` result during compilation; `main`, when declared, is required. |
| Flow | Input/output vertex names, all typed `Any` | Output vertex names, all typed `Any` | Wired child arguments were paired positionally with the child's leading parameters; missing root inputs became null. Every output vertex emits its named component, including null. | DM9b uses nullable `Dynamic` contracts: optional inputs and required outputs. Local wire order is resolved to explicit target binding names before hosting. |
| Job | `JobSignatureCapability` parameter contracts plus separately parsed defaults | Typed named result declarations | `JobControl.parameter` used `find ?: default`; concurrent Workers can yield any declared result name, and the collector was chronological | DM9b uses each declared contract; valid defaults are `Defaulted`, other inputs remain `Optional` for compatibility. Outputs are required. The produced builder provides synchronized last-write-wins updates and schema-order settlement; chronology remains trace data only. |
| Worker logic | Empty | Empty | Worker execution is driven by Job channels, not Logic arguments/results | Remains empty-to-empty. |
| Report | Empty | Falsely declared `main: String` | `ReportLogic.run` successfully returned empty | Product decision applied: Report is empty-to-empty. Its hosted-data behavior remains separately tested; no invented status or row-count result was added. |
| `LogicDataSource` request | Configured argument names, dynamically supplied from a design request | Hosted Logic signature | `DesignDataContext.argument` used `getSingle`, so both zero and repeated values collapsed to null; action/source routing parameters shared the request payload | DM9b binds configured names explicitly, preserves repeated values from the request listing, and removes routing-only parameters before binding. |

### Host-call inventory

| Production call site | Previous call | Intended target binding | Disposition |
|---|---|---|---|
| `RunWorker` boundary value | `JobControl.host(ObjectLocation, Any?)` | First declared child input | DM9b resolves that first `BindingName`, sends an explicitly named binding, and removes the positional overload in DM9c. |
| `RunWorker` additional values | Named `TupleValue` components | Matching declared Job inputs | Convert to exact named bindings; unknown/duplicate/missing-required validation is centralized. |
| `RunStep` | Named tuple map | Matching child Script/Logic inputs | Convert one-for-one to named bindings. |
| Flow Logic-host vertex | Positional wired prefix plus named literals | Child signature names in declaration order | Resolve the local positional wiring to explicit names at the Flow boundary, then host only `DataBindings`. No positional engine API survives DM9c. |
| `LogicDataSource` | Configured request names | Same configured child input names | Assemble named bindings after routing removal and repeated-value preservation. |
| `WorkerDataContext` / `EngineJobControl` | Forwarded or normalized named tuples | Exact child names | Forward/rebind as `DataBindings`; do not introduce a second normalization model. |
| Root `RunEngine` callers | Root tuple | Root signature names | DM9a adapts once through `TupleBindingBridge`; DM9c deletes that constructor after downstream callers migrate. |

### Model and proof

- Chose new names (`BindingName`, `BindingSchema`, `DataBindings`) rather than evolving tuple names: tuples imply a
  positional carrier and cannot honestly express unbound state, origin, defaults, sensitivity, or settlement.
- Added frozen duplicate-rejecting schemas, required/optional/defaulted presence, snapshot defaults, unbound versus
  bound-null state, supplied/defaulted/produced origins, schema-ordered enumeration, shallow structural/native/root
  checks, and whole-binding sensitive snapshot policy. Sensitivity is display policy, not taint propagation.
- Literal defaults are refused whenever any native requirement appears in the declared contract. Defaults retain
  their own `DataType` in `DataSnapshot` and are decoded independently for each binding assembly.
- Added a synchronized produced-output builder. Set validates shallowly, repeated names are last-write-wins, settle
  enumerates in schema order, and a missing required output fails. Concurrent yield chronology is deliberately not
  binding identity.
- Added exactly one internal `TupleBindingBridge`, documented as DM9a/DM9b-only with DM9c as its deletion owner. No
  production call site was converted to tuple during this session.
- Common JVM and JS tests passed (365 JVM / 341 JS in the combined gate); the full kzen-lib build passed (57 tasks),
  and `publishToMavenLocal` passed (59 tasks). Focused Report, Job-signature, Script-engine, Flow-notation, and hosted
  Report tests passed (153 tests). The added non-main Script compiler pin also passes.
