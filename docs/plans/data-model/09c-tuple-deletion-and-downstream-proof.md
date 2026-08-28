# DM9c — tuple API deletion and downstream proof

> **Status: ready after DM9b. One cleanup/publication session led from kzen-lib.** Authority: unified data model
> §§10–11.1 and §14.5 step 5. Constituent tracker: `README.md`.

## Outcome

The temporary binding-native capability is promoted to the ordinary `Logic`/`Execution` API and the tuple model and
all binding bridges are deleted. Every downstream sibling proves the clean published surface.

## Implementation

1. Verify DM9b's repository-wide inventory: no production consumer requires `TupleDefinition`, `TupleValue`, tuple
   host overloads, or the temporary capability names.
2. In kzen-lib, make binding-native `Logic.signature/run`, `Execution.inputs/host`, `Outcome.Success`, and related
   request/result surfaces canonical under their final names. Delete tuple types, adapters, overloads, tests, and
   comments; do not leave deprecated shims or commented code.
3. Update kzen-lib logic spec/architecture by pointer to the unified-model authority and record final symbol names.
4. Publish all kzen-lib artifacts. Rebuild kzen-auto against the clean artifacts and fix only genuine missed tuple
   callers; a miss reopens DM9b's inventory rather than adding a shim.
5. Publish all kzen-auto artifacts, then rebuild kzen-project, kzen-launcher, kzen-shell, and kzen-sample-plugin in
   dependency order. No release-train version bump.

## Proof and exit

- Run full kzen-lib and kzen-auto builds plus standalone downstream builds.
- Repository-wide `rg "TupleDefinition|TupleValue|TupleComponent"` finds no production model use; historical docs
  and the review record are not rewritten.
- Binding/end-to-end gates pass with one public Logic boundary and no parallel legacy carrier.
