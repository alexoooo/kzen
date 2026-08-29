# DM9c — tuple API deletion and downstream proof

> **Status: complete 2026-08-28.** Authority: unified data model
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
5. Publish all kzen-auto artifacts, then rebuild kzen-project and kzen-sample-plugin as direct downstream proof.
   Rebuild kzen-launcher and kzen-shell afterward as release-train integration checks, not as evidence specific to
   tuple removal. No release-train version bump.

## Proof and exit

- Run full kzen-lib and kzen-auto builds, the direct downstream proof builds, and the release-train integration
  checks classified above.
- Repository-wide `rg "TupleDefinition|TupleValue|TupleComponent"` finds no production model use; historical docs
  and the review record are not rewritten.
- Binding/end-to-end gates pass with one public Logic boundary and no parallel legacy carrier.

## As built — 2026-08-28

- Binding-native `Logic.signature/run`, `Execution.inputs/host`, `Outcome.Success`, engine storage, and migration
  are the sole public path. The temporary capability/adapter and the complete `exec.tuple` package were deleted;
  no compatibility shim or overload remains.
- kzen-project's sample Script step and its acceptance test were migrated to `ScriptStepDefinition.ofMain`,
  `BindingName("main")`, and `DataValue` materialization. The direct kzen-project and sample-plugin proofs pass.
- Full kzen-lib and kzen-auto builds pass. kzen-auto artifacts were published, then kzen-project, launcher, shell,
  and the Maven sample plugin rebuilt successfully. No release-train version changed.
- Production-source searches for `TupleDefinition`, `TupleValue`, `TupleComponent`, `exec.tuple`, the temporary
  `BindingLogic`, and `bindingSignature` are empty. Historical review material is outside this production gate.
