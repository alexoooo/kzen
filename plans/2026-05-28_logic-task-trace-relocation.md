# Investigation — Move Logic/Task/Trace to kzen-lib + unify on a process-global ObjectStableMapper

> Strategic research document, not an action plan. The proposals here will be the basis for one or more follow-up implementation plans (Move A is plan `2026-05-28_move-a-global-object-stable-mapper.md`).

## Context

We recently landed a rename-survival fix for Script execution: ActiveScriptModel keys per-step state by `ObjectStableId`, `LogicTraceStore` stores traces under `$stable`-prefixed paths, and a per-run `ObjectStableMapper` translates back to current `ObjectLocation` at lookup. It works *while a run is active*.

Two structural gaps surfaced after that fix:

1. **Trace dies on rename after the run ends.** When `ServerLogicController.clearState()` runs, it unobserves the per-run mapper from `graphStore`. If the user then renames a step (trace still visible in the UI), the now-detached mapper does not see the rename event; subsequent lookups fail to translate the `$stable` path and the trace disappears. We added a fix-on-fix path on the client (`ScriptStore.refreshProgressAsync` on document-notation change), but the underlying identity model on the server has gone stale and re-fetching just confirms that staleness.
2. **The layering is upside-down.** `ObjectStableMapper` lives in `kzen-lib` but is consumed only from `kzen-auto`. `Logic` — the abstraction that needs the mapper — lives in `kzen-auto`. `Logic` is a general execution concept (long-running, stateful, paused/stepped), not a kzen-auto domain concept; similarly `Task` (one-shot async). The right home for both is kzen-lib.

This document inventories what would move, what stays, what changes meaning, and how to sequence the work.

## User-stated goals

1. Relocate **`Logic`**, **`Task`**, and related **`Trace`** types from kzen-auto into kzen-lib. (Detached stays in kzen-auto for now — doesn't need stable identity.)
2. All execution (Logic, Task, Trace) keyed by **`ObjectStableId`**, not `ObjectLocation`.
3. **One mapper per process** — one server-side, one client-side — observing the local graph store from boot. No more per-run mappers.
4. **Accepted limitation**: the mapper assumes one linear history of notation changes. Future revert/version-control is out of scope; would require user-driven execution restart.

## Today's shape

### Where things live

| Bucket | Module | Source set | Examples |
|---|---|---|---|
| Pure data / interface (already portable) | `kzen-auto-common` | commonMain | `LogicController`, `LogicRunId`/`ExecutionId`/`RunExecutionId`, `LogicStatus`, `LogicRunInfo`, `LogicRunFrameInfo`, `LogicRunFrameState`, `LogicRunResponse`, `LogicTrace`, `LogicTracePath`, `LogicTraceQuery`, `LogicTraceSnapshot`, all `Task*` interfaces + models |
| Server abstractions (mostly clean) | `kzen-auto-jvm` | jvmMain | `Logic`, `LogicHandle`, `LogicHandleFacade`, `LogicControl`, `LogicExecution`, `LogicExecutionFacade`, `LogicExecutionListener`, `LogicCommand`, `MutableLogicControl`, `LogicTraceHandle`, `ManagedTask`, `TaskHandle`, `TaskRepository` |
| Server impls (stay in kzen-auto) | `kzen-auto-jvm` | jvmMain | `ServerLogicController`, `LogicExecutionFacadeImpl`, `LogicTraceStore` (in-memory), `ModelTaskRepository`, `LogicFrame`, `LogicContext` |
| kzen-auto-specific surfaces | `kzen-auto-{common,jvm}` | mixed | `LogicConventions` (REST), `LogicResult` (carries `TupleValue`), `LogicDefinition`, `LogicType` |

Most of the surface is already in `commonMain` and platform-agnostic — moving it is mostly a package-rename + re-publish exercise. The real work is in the few coupling points called out below.

### Mapper today

- Constructed fresh in `ServerLogicController.start(...)` per run.
- `graphStore.observe(objectStableMapper)` at start; `graphStore.unobserve(objectStableMapper)` in `clearState()`.
- Pre-warmed at run start by iterating the transitive definition and calling `objectStableId(loc)` on each.
- Lookup-time translation in `LogicTraceStore.lookup(...)` — `$stable`-prefix path → current `ObjectLocation` via the per-run mapper.
- Write-time use in `ScriptExecutionContext` / `ScriptExecution` / `MultiStep` — `objectStableId(loc)` keys both `ActiveScriptModel.steps` and the trace path.

### Existing boot-time observer precedent

`KzenAutoContext.init()` already attaches three boot-lifetime observers to the singleton `graphStore`:

```kotlin
graphStore.observe(activeDataflowRepository)
graphStore.observe(visualDataflowRepository)
graphStore.observe(modelTaskRepository)
```

A process-global `ObjectStableMapper` would be a fourth entry. There is no greenfield wiring to invent.

### Client-side absence

`ClientStateGlobal` observes the server's graph events (via `RemoteGraphStore`). It has **no** `ObjectStableMapper`; the client keys everything by current `ObjectLocation` and survives rename via the fresh `ScriptStore` re-fetch path. A client-side mapper is *not* required to close the user-reported gap — it's an optional future improvement.

## What changes, in four moves

### Move A — Make the server mapper process-global

- Construct one `ObjectStableMapper` at `KzenAutoContext` boot (same line as `modelTaskRepository`).
- `graphStore.observe(mapper)` once, never unobserve.
- Pre-warm by iterating the initial graph notation once at boot (cheap, predictable).
- Drop the per-run mapper from `ServerLogicController`; pass the singleton through `Logic.execute(...)` instead.
- `LogicTraceStore.handle(...)` takes the singleton (instead of constructing per-run wiring around a private mapper).
- `clearState()` no longer touches the mapper.

**This alone closes the user-reported gap.** No relocation, no kzen-lib changes — Move A is a Plan-1-shaped slice that could land independently.

### Move B — Relocate Logic and Trace to kzen-lib

Target: `tech.kzen.lib.common.exec.logic.*` (run/, trace/) and `tech.kzen.lib.common.exec.task.*`. The architecture doc's package map names `exec/` explicitly as the home for "execution-layer abstractions"; `ExecutionRequest`/`ExecutionResult`/`ExecutionValue` already live there.

Sub-tiers:

- **B1 — Trivial moves (~15 files)**: commonMain pure-data types listed above. Rename packages, fix imports in kzen-auto/-project/-launcher/-shell, re-publish.
- **B2 — Strip kzen-auto refs from server abstractions (~8 files)**: `Logic`, `LogicHandle`, `LogicControl`, `LogicExecution`, `LogicExecutionFacade`, `LogicTraceHandle`. Existing imports are already minimal.
- **B3 — Move the Tuple data model too**: `TupleValue`, `TupleDefinition`, and friends are pure data and conceptually part of the Logic model — they belong in kzen-lib alongside Logic itself. `LogicResult` keeps its current shape and moves with them.
- **B4 — Drop placeholder package segments while moving.** The current `tech.kzen.auto.server.service.v1.*` location is a placeholder — when these types land in kzen-lib, the package should reflect the *actual* domain, not the legacy versioning suffix. Target `tech.kzen.lib.common.exec.logic.*` / `.trace.*` / `.task.*` (no `v1`, no `service`). Same for any other vestigial segments encountered during the move.
- **B5 — Stays in kzen-auto**: `ServerLogicController`, `LogicExecutionFacadeImpl`, `LogicTraceStore` (in-memory impl), `LogicConventions` (REST wire convention), `LogicDefinition`, `LogicType`, `ModelTaskRepository`. These embed HTTP, thread-pool, and Ktor wiring that don't belong in lib.

### Move C — Relocate Task

Same shape as B but smaller. All Task interfaces and models already live in commonMain; the impl (`ModelTaskRepository`) stays in kzen-auto. Likely a one-PR move once B has established the pattern.

### Move D — Client-side mapper (optional, future)

Mirror the server: a process-global `ObjectStableMapper` on the client observing `ClientStateGlobal`'s event stream. This lets the client survive rename without a network re-fetch and gives us symmetric identity vocabulary across the wire.

**Hazard: id-sync.** Today ids are `objectLocation.asString()` at first encounter — deterministic on location but not on time-of-first-encounter. If server and client first-encounter in different orders relative to renames, ids drift. Two paths to address:

- **Snapshot-sync at connect time** — client requests a current `(id, location)` snapshot from the server and seeds its mapper before processing further events. Simple, race-free.
- **Server as canonical id authority** — client doesn't compute ids; it asks the server. Heavier, more chatty.

Defer D entirely until A+B+C are in. The current re-fetch-on-rename approach is good enough.

## Open design questions

1. **Mapper-as-decorator or mapper-as-service?**
   - **Option 1: Decorator on `LocalGraphStore`.** Add `LocalGraphStore.objectStableMapper: ObjectStableMapper`. Conceptually the mapper is a derived view of the store, so this is cleanest. Cost: expanding a core kzen-lib interface.
   - **Option 2: Service held by context.** `KzenAutoContext.objectStableMapper` (and analogously on the client). Keeps the store interface narrow; every consumer must know how to acquire it. Matches the existing `ModelTaskRepository` precedent.
   - Lean **Option 2** because it costs nothing at the lib boundary, and the boot wiring is identical to what's already there.

2. **Cold-start: lazy vs eager.** Eager (iterate full graph at boot, assign ids in canonical name-order) gives predictable ids that survive any rename. Lazy (assign on first lookup) is cheaper at boot but means ids depend on observation order. Eager is recommended; the boot cost is once-per-process and proportional to object count.

3. ~~**`LogicResult`**: parameterize vs move TupleValue.~~ Resolved: `TupleValue`/`TupleDefinition` move to kzen-lib (Move B3).

4. **Task tracing.** Today only Logic has Trace. Should Task gain trace symmetry as part of this refactor, or stay non-traced? User hasn't asked for it; defer unless there's a concrete need.

5. **Versioning.** Move B is a non-trivial kzen-lib surface bump. **0.30.0** vs **0.29.2**. Recommend 0.30.0 — the relocation alone justifies a minor bump.

6. **Trace key.** `LogicTraceStore.objectLocationHistory` is keyed by `ObjectLocation` (root of the run). With a global mapper, it could key by `ObjectStableId` instead — making the "Reset" button survive a rename of the script's root document. Small consistency win; do it as part of Move A.

## Things worth flagging

- **The per-run pre-warm is a feature, not a quirk.** It's the only reason ids deterministically reflect names-at-run-start. Replacing with a boot-time pre-warm means ids deterministically reflect names-at-process-start, which is what we want for the global model. Lazy pre-warm would make ids order-of-observation dependent — avoid.

- **`originalObjectLocation` in `LogicHandle.start`/`LogicExecutionFacadeImpl.open` is *not* an analogue of `ObjectStableMapper`.** It's the entry-point location used as a trace scope key, not an identity-preservation mechanism. They're orthogonal.

- **`LogicConventions` (REST surface) stays in kzen-auto.** Logic-the-interface moves to lib; Logic-the-HTTP-binding stays. This is correct layering — the wire convention is an auto concern.

- **No integration test exists today for rename-during-run.** The unit-level `ObjectStableMapperTest` covers identity preservation in isolation. A new end-to-end test (rename event mid-run; rename event between-run-stop-and-clear) is the canonical demonstration that the global-mapper design works. Should land with Move A.

- **`LogicTraceStore` is in-memory and dies on restart.** The "single linear history" limitation the user accepted already applies de-facto. Moving to a global mapper doesn't change this; it just makes the identity model consistent with the storage model.

- **Project switching.** If kzen-launcher loads a different project, does that destroy and rebuild the server's `DirectGraphStore`? If yes, the global mapper resets — which is exactly what we want (new project = new identity universe). Worth confirming as part of Move A's design.

- **kzen-auto-plugin SPI.** No Logic/Task/Trace refs there today, so external plugins don't break on relocation. However, plugins compiled against `tech.kzen.auto.common.paradigm.logic.*` would need a recompile against `tech.kzen.lib.common.exec.logic.*`. Manage with a minor version bump (covered by 0.30.0).

- **Memory bounds.** A boot-lifetime mapper grows monotonically. We already handle `RemovedObjectEvent` and `DeletedDocumentEvent`. For typical usage (objects rarely deleted), growth is bounded. For pathological churn (heavy add/delete cycles), the bidirectional map could accumulate. The integration test should include a churn case.

- **Wire stability of the id format.** Ids look like `"main.steps/StepName"` initially, but after a rename the id still reads "StepName" — visually misleading if anyone reads raw ids out of a log. Today no response serializes the raw id (always translated through `objectLocation`). Worth not breaking that property; do not start emitting raw ids in JSON unless you also emit a translation alongside.

- **Logic is referenced from kzen-project (and possibly others).** Cross-sibling import paths will need updating in the relocation PRs. The umbrella's variant-suffix-coord routing means each sibling must rebuild against the bumped kzen-lib; standard publish-to-mavenLocal dance applies.

## Recommended sequencing

| Plan | Slice | Closes user-reported gap? | kzen-lib touched? |
|---|---|---|---|
| **1** | Move A — process-global server mapper | Yes | No |
| **2** | Move B (B1+B2+B3+B4) — relocate Logic + Trace + Tuple to kzen-lib, drop placeholder packages | No (already closed) | Yes (0.30.0 bump) |
| **3** | Move C — relocate Task to kzen-lib | No | Minor bump |
| **4** | Move D — client-side mapper | No (optional polish) | Yes |

Each can land as one PR-pair. Plan 1 is the highest-value, lowest-risk slice and resolves the immediate bug standalone — recommend doing it first regardless of whether you commit to the full relocation.

## Verification (cross-plan)

Manual:
1. Run a Script in pause/step mode. Step the first step to Done. Stop the script.
2. Rename the Done step — trace persists under new name.
3. Step → stop → rename → start a new run — new run sees prior trace consistently.
4. Restart server — trace is gone (expected); ids re-assigned from current names.

Automated (lands with Plan 1):
- New jvmTest exercising rename events during and after run.
- Existing `ObjectStableMapperTest` continues as the unit-level canary.
- `FormulaStepTest` remains the Kotlin-inference canary on each plan that touches the compile classpath.

Cross-sibling rebuild order for Plans 2-4:
1. `cd ../kzen-lib && ./gradlew publishToMavenLocal`
2. Bump `kzenLibVersion` in each consumer's `buildSrc/.../Dependencies.kt`.
3. Rebuild kzen-auto → kzen-project → kzen-launcher → kzen-shell, in that order, per umbrella AGENTS.md.
