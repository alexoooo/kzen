# DM9a — additive kzen-lib binding engine and tuple bridge

> **Status: ready after DM8. One kzen-lib implementation session.** Authority: unified data model §§10–11.1 and
> §14.5 step 5. Constituent tracker: `README.md`.

## Outcome

RunEngine stores and validates `DataBindings` canonically while the published kzen-lib API keeps a temporary
capability adapter for tuple-based downstream Logic implementations. The session ends with current kzen-auto still
source-compatible and a new binding-native path DM9b can adopt.

## Implementation

1. Re-check `Logic`, `LogicSignature`, `Execution`, `Outcome`, `RunEngine`, `LogicDefinition`, request/result and trace
   projections, plus every tuple test/caller found by DM8's inventory.
2. Add a temporary binding-native Logic capability and execution/host overloads. RunEngine dispatches by capability:
   binding-native implementations receive/return `DataBindings`; legacy `Logic` is adapted at one boundary through
   DM8's tuple bridge. No generic code branches on concrete Logic types.
3. Make engine storage, input validation/default application, hosted results, and produced-output settlement use
   `DataBindings`. Legacy tuple projection is derived only at the adapter edge and never becomes a second authority.
4. Preserve failure attribution, pause/migrate/host behaviour, trace retention, ambient context/resources, and
   readable hosted/root results after settlement.
5. Mark every temporary capability/overload with DM9c deletion ownership. Do not deprecate it as a supported release
   compatibility contract; it is an in-arc bridge at the current SNAPSHOT.

## Proof and exit

- Engine tests cover binding-native and legacy Logic, nested missing/null/defaulted inputs, required-output failure,
  native identity, hosted/root post-settlement reads, and identical failure attribution.
- Existing kzen-lib tests remain green. Build and publish all kzen-lib artifacts to Maven Local.
- Run a standalone kzen-auto compile against the published artifact without source edits. DM9b starts only if it is
  green, proving the bridge is real.

## As-built — 2026-08-28

- Added the temporary `BindingLogic` / `BindingLogicSignature` capability, `Execution.inputBindings`,
  `Execution.hostBindings`, and the binding-root `RunEngine` constructor. Every temporary name and overload carries
  the DM9c deletion/promotion owner in source.
- `NodeRuntime` now stores only `DataBindings`. Root and hosted input validation/default application, binding-native
  dispatch, output collection, required-output settlement, and child return values remain binding-native. The
  public `Outcome.Success` and legacy `Execution.inputs/host` tuple views are projected only at the adapter edge.
- Legacy `Logic` dispatch uses `TupleBindingBridge` in one engine location. The old contract permitted undeclared
  returned tuple components (including many long-standing kzen-lib fixtures with an empty signature and a `main`
  return), so the bridge creates run-local declarations for those produced components. This is deliberately the
  sole source-compatibility concession; binding-native Logic is always settled against its exact schema, and DM9c
  deletes the concession with the tuple model.
- JVM projection preserves a native root's exact object identity and materializes structural literals only for the
  temporary readable tuple view. The engine-owned adapter registry is closed exactly once on shutdown/disposal.
- Added binding-engine tests for defaulted and supplied-null origin, nested required-input rejection before child
  code, missing required output, native identity, hosted/root reads after settlement, and binding/legacy child
  failure attribution. Existing pause, migrate, host, trace, ambient-context, resource, and retention tests remain
  green because those mechanics were left on the same node lifecycle.
- Full kzen-lib build passed (57 tasks), `publishToMavenLocal` passed (59 tasks), and an unchanged standalone
  `:kzen-auto-jvm:compileKotlin` against the published artifact passed (13 tasks, 35 seconds). This is the required
  proof that DM9b begins from a real additive bridge rather than a coordinated half-cutover.
