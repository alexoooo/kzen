# Script-document refactor review — 2026-05-29 (kzen-auto + kzen-lib)

Post-refactor code review of the Script document feature, requested after two changes landed:

1. **Logic/Task/Trace/Tuple relocation to kzen-lib** (commit `2c478bc` "logic refactor to kzen-lib done", 2026-05-28; Moves A–D of `plans/2026-05-28_logic-task-trace-relocation.md`). The execution abstractions and the process-global / client-side `ObjectStableMapper` identity layer.
2. **Script client refactor** — remediation of `docs/audit/2026-05-26_script-review_4.7-xhigh.md`: the `S01` `detectChanges` bug deleted, `ScriptGlobal` (a `WeakRef<ScriptStore>` global) replaced by `ScriptStoreContext` (React Context), and per-step UI state folded into `ScriptState.steps` via a `ScriptStepStore` sub-store.

Coverage: the Script JS client (`document/script/` — controller, model, progress, valid, step sub-stores), the Script JVM server (`server/objects/script/` — `ScriptDocument`, `ScriptExecution`, contexts, `ActiveScriptModel`), and the kzen-lib identity/trace pieces it now depends on (`ObjectStableMapper`, `LogicTraceStore`, `KzenAutoContext`/`ClientContext` wiring). Compared against the canonical `report/` document (`ReportController`/`ReportStore`). Graded against `docs/CODING_STANDARDS.md` (CC-01…CC-11) plus design-level observations.

## Summary

- **No correctness bugs found.** The refactor is high quality. The 2026-05-26 remediations held (no `ChangeType` discriminator, no `ScriptGlobal`, no dependency-walk duplication), and the relocation is clean (only `LogicConventions` — the REST wire surface — stayed in kzen-auto; no `service.v1` or `paradigm.task` source leftovers; `LogicTraceStoreRenameTest` exists as the rename-survival canary).
- **Script is, in places, *cleaner* than the documented canonical `report/`**: it uses `checkNotNull` / `check` instead of `ReportStore`'s manual `throw IllegalStateException` (CC-08); a named `refreshYieldMillis` constant with a rationale comment instead of `ReportStore`'s bare `delay(10)` (CC-01); React Context instead of a global; and carries far less commented-out debug cruft.
- **1 architectural divergence** (A01, Medium) — tracked, not applied (per scope decision).
- **4 trivial cleanups** (C01–C04, Low) — **applied** in this session.

### Severity

- **Medium** — meaningful maintainability cost or a divergence from the canonical pattern; non-trivial blast radius.
- **Low** — style / dead-code / single-file cleanup; behaviour already correct.

| ID | Severity | Effort | Status | Location |
|----|----------|--------|--------|----------|
| **A01** | Medium | Medium | tracked (deferred) | `script/ScriptController.kt` + `script/model/ScriptStore.kt` / `ScriptState.kt` |
| **C01** | Low | Trivial | **applied** | `script/ScriptController.kt` `renderSignature` |
| **C02** | Low | Trivial | **applied** | `script/progress/ScriptProgressStore.kt` |
| **C03** | Low | Trivial | **applied** | `server/objects/script/ScriptExecution.kt` + `ScriptDocument.kt` |
| **C04** | Low | Trivial | **applied** | `script/model/ScriptStore.kt` `onClientState` |

---

## A01 — `ScriptController` dual-observation (Medium, tracked)

`ScriptController` implements **both** `ScriptStore.Observer` **and** `ClientStateGlobal.Observer`, holding two state slices (`clientState` + `scriptState`) and registering two independent observer channels in `componentDidMount`:

```kotlin
override fun componentDidMount() {
    store.didMount()
    store.observe(this)
    ClientContext.clientStateGlobal.observe(this)   // <-- second, direct channel
}
```

The canonical `ReportController` observes **only** its store; `ReportStore.onClientState` folds the cross-cutting `clientLogicState` *into* `ReportState` (`ReportState(mainLocation, mainDefinition, clientState.clientLogicState)`), so the controller has a single source of truth and one re-render channel.

Why it matters:
- **Two sources of truth in one component.** `render()` reads `documentPath` from `clientState` but `mainLocation` from `scriptState`; the two arrive on separate `setState` calls and can momentarily disagree during navigation. The early-return guards cover it today, but it's fragile.
- **Diverges from the documented canonical shape**, which undercuts using Script as the reference example (see Documentation outcome below).

Recommended fix (deferred — needs run/test verification, so left out of this session's applied set):
- Fold what the controller actually needs from `clientState` into `ScriptState` — principally `clientLogicState.isActive()` for `renderRunController` (mirror `ReportState`'s `clientLogicState` field; `ScriptStore.onClientState` already reads `clientState.clientLogicState`).
- Rely on `scriptState != null` for the script-validity guard (the store already validates `ScriptConventions.isScript` in `tryMainLocation`, so a non-null `ScriptState` *is* the "this is a valid script document" signal).
- Drop `ClientStateGlobal.Observer` from `ScriptController` and the direct `observe`/`unobserve` calls.

Risk: Low–Medium. Behaviour-preserving in intent, but it changes the re-render trigger graph; verify with a run (open script, run/pause/step, rename) before committing.

---

## C01–C04 — Trivial cleanups (Low, applied)

- **C01 — dead commented scaffolding.** `ScriptController.renderSignature` wrapped the live `LogicSignatureEditor` call in ~17 commented-out lines (`foo4` / `DummyComponent` / `bar` div scaffolding). Removed; the live call remains. (CC-07, CC-10.)
- **C02 — commented-out duplicate.** `ScriptProgressStore` carried a fully commented-out second copy of `mostRecent()` (~25 lines) below the live one. Removed. (CC-10.)
- **C03 — redundant init + leftover fragments.** `ScriptExecution.init(logicControl)` re-zeroed two fields that are already initialized at declaration, took an `@Suppress("UNUSED_PARAMETER") logicControl`, and was the object's only post-construction mutation of `activeScriptModel`. Since `ScriptDocument.execute` constructs a fresh `ScriptExecution` per run, `init` was pure redundancy — removed (along with its call site in `ScriptDocument.execute`), and `activeScriptModel` tightened to `val`. Also removed the leftover `//topLevel` comment fragments in `beforeStart` and the `ScriptExecutionContext(...)` call. (CC-10.) The `Logic.execute` override signature is unchanged (`logicControl` stays — it's dictated by the interface).
- **C04 — redundant refresh on first state change.** `ScriptStore.onClientState` did not seed `previousDocumentNotation` / `previousLogicTime` in the `initial` branch, so the first subsequent `onClientState` saw `documentNotationChanged == true` (baseline still `DocumentNotation.empty`) and re-fired `refreshValidationAsync()` — and a redundant `refreshProgressAsync()` if a run was already active — duplicating what the initial load just did. Now seeds both baselines on the initial branch.

---

## Positive notes — why Script is a good pattern reference

These justify documenting Script (in `kzen-auto/docs/js-architecture.md` § 3) as the reference for two patterns `report/` doesn't exercise:

- **Keyed-map dynamic sub-state.** `ScriptStepState` under `ScriptState.steps: Map<ObjectLocation, ScriptStepState>`, written through one `ScriptStepStore` that prunes default-valued entries so the map never accumulates orphans. The right shape for per-entity UI state keyed by a *dynamic* collection (vs Report's fixed sections), and correctly kept distinct from the network-backed `progressStore` / `validationStore` siblings.
- **React-Context store propagation.** `ScriptStoreContext = createContext<ScriptStore?>(null)`, provided by the controller, read by deep class-component descendants via the `installContextType` / `contextValue` helpers — replacing the deleted `WeakRef` global. Scopes the store explicitly with no deref-may-fail surface.
- **Server-side rename survival.** `ActiveScriptModel.steps` and `LogicTraceStore` key by `ObjectStableId`, and `ScriptExecution.continueOrStart` carries stateful-element state forward across renames by stable id with a `javaClass` guard before `loadState`. Clean use of the relocated identity layer.
- **Idiomatic failure paths and named, commented constants** throughout (`checkNotNull`/`check`; `refreshYieldMillis` with its event-loop-yield rationale).

---

## Documentation outcome

Updated alongside this review (the docs had not caught up to either change):

- `kzen-lib/docs/architecture.md` — expanded the `exec/` package map; added an **Execution model (Logic / Task / Trace)** section and a **Stable identity (`ObjectStableMapper`)** section.
- `kzen-auto/docs/architecture.md` — § 1 paradigm table (Logic/Task types now in kzen-lib `exec/`, only the binding stays), § 3 `LogicTraceStore` relocation + stable-id keying, § 4 `KzenAutoContext` `objectStableMapper`/`logicTraceStore` rows, and the critical-files list.
- `kzen-auto/docs/js-architecture.md` — § 3 documents Script as the reference for the two patterns above (Report stays canonical for breadth), plus a client-side `ObjectStableMapper` note and a one-line A01 caveat.
- `kzen/AGENTS.md` and the `plans/2026-05-28_*` research docs — accuracy/status touch-ups.

---

## Verification

- JVM compile + canaries: `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*LogicTraceStoreRenameTest" --tests "*FormulaStepTest" --tests "*ScriptTreeTest"` (C03 touches `ScriptExecution`/`ScriptDocument`; the rename test exercises the identity path the docs now describe).
- JS compile: `cd ../kzen-auto && ./gradlew :kzen-auto-js:compileKotlinJs` (C01/C02/C04).

## Critical files

- `kzen-auto-js/.../document/script/ScriptController.kt` — A01, C01
- `kzen-auto-js/.../document/script/progress/ScriptProgressStore.kt` — C02
- `kzen-auto-js/.../document/script/model/ScriptStore.kt` — A01, C04
- `kzen-auto-jvm/.../server/objects/script/ScriptExecution.kt`, `ScriptDocument.kt` — C03
- Reference (read, unchanged): `kzen-auto-js/.../document/report/{ReportController,model/ReportStore,model/ReportState}.kt`; `kzen-lib-common/.../service/store/normal/ObjectStableMapper.kt`; `kzen-lib-jvm/.../server/exec/logic/trace/LogicTraceStore.kt`
