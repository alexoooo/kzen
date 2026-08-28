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
