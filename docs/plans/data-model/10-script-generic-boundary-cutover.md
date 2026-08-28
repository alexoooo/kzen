# DM10 — Script recorded-result and handoff cutover

> **Status: ready after DM9c. One kzen-auto implementation session.** Authority: unified data model §§7, 11.2,
> 13.22, 14.5 step 6, and Script portions of §15.

## Outcome

Ordinary Script code keeps ordinary Kotlin locals/results, while every generic recorded step result and inter-step/
nested-Logic handoff is a `DataValue` lifted from static knowledge first. Replay retains readable values and native
consumers receive original objects.

## Scope boundary

Do not change every `ScriptStep.run(): Any?` to expose framework wrappers. The engine/replay layer owns lifting and
projection. Generated code receives the most ergonomic native or generated structural view; the generic boundary is
the recorded result and handoff.

## Implementation

1. Re-check `ScriptLogic`, `ScriptRunContext`, `ScriptReplayState`, `ScriptMigrationState`, `StepExecution`,
   `ScriptStepDefinition`, `ScriptValueBinding`, `FormulaStep`, `ResultStep`, `RunStep`, and generated expression
   compiler/cache keys. Include the existing nominal `IfStep.joinBranchTypes` consumer in the migration inventory.
2. Thread DM2 `ResolvedDataContract` from declared/inferred `KType` through step definitions and compiler cache keys.
   `FormulaStep`/implicit results use the compiler-inferred type; empty typed collections retain element type.
3. At step completion, lift raw Kotlin output with `DataAdapterRegistry.lift(result, expected)`. Store `DataValue` in
   replay/outcome/carry structures; preserve early Result, implicit terminal, loop, branch, and migration semantics.
4. When a generated/native consumer requests `T`, resolve acceptance and pass `native(node)` or canonical scalar
   projection. Structural generated accessors operate on `DataNode` without per-field `DataValue` allocations.
5. Update `RunStep` and Script result construction to use `DataBindings` directly. Snapshot trace previews under a
   bounded policy; rejected/redacted previews never fail the run.
6. Remove Script-local `Any?` maps only where they are generic transport. Typed locals and resource/context APIs stay
   native. Delete temporary bridges.
7. Migrate `IfStep.joinBranchTypes` deliberately: pin its current rules (Unit dominance, exact class/generic
   agreement with nullability widening, otherwise Any) in regression tests, then express the equivalent decision at
   the new structural/native boundary. Do not silently replace this product behaviour with the general-purpose
   `DataTypeAlgebra.join` merely because both operations are called “join.”

## Proof

- Formula returns an ordinary data class/list/scalar without wrapping; structural and native consumers see the same
  value, and empty `List<String>` retains `String` element type.
- Replay, pause/resume, loop carry, live-edit migration, hosted Script results, present null, optional/defaulted
  inputs, and implicit-result rules remain pinned.
- A post-publication element changing to the wrong class fails on read; no per-field wrapper allocation.
- Snapshot preview rejection/redaction/cycle/opaque never changes Script outcome.
- Run all Script-focused tests including `FormulaStepTest`, then full kzen-auto build. Clear the test code cache for
  the cold inference canary as required by `../kzen-auto/AGENTS.md`.

## Exit criteria

- `ScriptReplayState` and generic handoffs contain no untyped value maps; user-authored step bodies remain ergonomic.
- Script portion of the end-to-end/lifetime gate passes.
