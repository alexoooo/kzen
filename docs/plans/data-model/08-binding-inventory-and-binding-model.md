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
