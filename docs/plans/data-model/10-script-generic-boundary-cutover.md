# DM10 — Script recorded-result and handoff cutover

> **Status: complete 2026-08-28.** Authority: unified data model §§7, 11.2,
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

## As built — 2026-08-28

- `ScriptReplayState`, `ScriptMigrationState`, completed outcomes, and generic step-to-step handoffs carry
  `DataValue?`. A completed step is lifted against the `DataContract` derived from its declared or compiler-inferred
  `TypeMetadata`; Script outputs are settled directly as `DataBindings`.
- Native/generated consumers project through `JobDataValues.boundary`, preserving native identity and exact scalar
  width. Structural access remains on `DataNode`; no per-field `DataValue` wrapper is introduced.
- Early Result, implicit terminal results, loops, branches, pause/resume, live-edit migration, hosted Script calls,
  optional/default/null inputs, and the product-specific `IfStep` join rules remain pinned by the full suite.
- Trace previews use bounded `DataSnapshot` capture. Redaction, opaque/cyclic values, or policy rejection produce a
  diagnostic and cannot fail the Script.
- The compiler continues to use inferred `KType`/`TypeMetadata` as its cache authority and derives the common
  `DataContract` at the execution boundary; loader-local resolved tokens are checked when JVM consumers project a
  value rather than being serialized into common Script definitions. Typed step-private carry state remains
  `Any?`; it is opaque user state, not generic result transport.
- The Formula inference canary, focused Script tests, all 888 JVM tests (one skipped), and the aggregate kzen-auto
  build/publication passed. `StepExpressionCompiler`'s generated shape did not change, so the AGENTS cold-cache
  condition did not apply and no code-cache format migration was required.
