# Move C — Relocate Task to kzen-lib (+ drop redundant ObjectStableMapper parameter)

> Third slice of the multi-step refactor described in [`2026-05-28_logic-task-trace-relocation.md`](2026-05-28_logic-task-trace-relocation.md). Moves A and B have landed. This slice relocates the `Task` abstraction (one-shot async execution) from `kzen-auto-common` to `kzen-lib-common`, and folds in the Move B out-of-scope follow-up that drops the now-redundant `objectStableMapper: ObjectStableMapper` parameter from `Logic.execute(...)`, `LogicHandle.start(...)`, `LogicHandleFacade`, and `LogicExecutionFacadeImpl`.

## Context

User direction (from the investigation doc):
- "move Logic and Task to kzen-lib (with related classes, like Trace, any related tests, etc.)"
- Task is a general execution concept, not a kzen-auto domain concept — same rationale as Logic.

Constraints surfaced during inventory:
- `TaskRepository` is constructed directly in `KzenAutoContext` (`ModelTaskRepository(graphStore, graphCreator)`). It is *not* a `DetachedAction`; no notation YAML binds it. No `LogicTraceEndpoint`-style adapter is needed for Move C.
- The Task family has no kzen-lib JVM-only coupling — every member that is moving is pure data or pure interface and fits in `commonMain`. Nothing goes to `kzen-lib-jvm` in this slice.
- `TaskModel.requestAction()` uses `tech.kzen.auto.common.api.CommonRestApi` — the only kzen-auto import in the moving set. It is **unused** (grep across kzen-auto returns only the definition). Drop the method during the move; that severs the import cleanly.
- No version bump per [CC-14](../docs/CODING_STANDARDS.md). Republish kzen-lib at the existing `0.29.1-SNAPSHOT`.
- No cross-sibling consumers outside kzen-auto: grep of `kzen-project`, `kzen-launcher`, `kzen-shell` for `tech.kzen.auto.common.paradigm.task` returns zero matches.

Move B follow-up folded in here (per Move B "out-of-scope follow-ups" section):
- `Logic.execute(...)`, `LogicHandle.start(...)`, `LogicHandleFacade(...)`, `LogicExecutionFacadeImpl.open(...)` still take an `objectStableMapper: ObjectStableMapper` parameter. The mapper is now a process-wide singleton, owned by `KzenAutoContext` and reachable via `KzenAutoContext.global().objectStableMapper`. All Logic implementations live in kzen-auto and have that access. The parameter is dead weight.

## Scope

### In
- Relocate `ManagedTask`, `TaskRepository`, `TaskRun`, `TaskHandle` from `kzen-auto-common/.../paradigm/task/**` to `kzen-lib-common/.../exec/task/**`.
- Relocate `TaskId`, `TaskProgress`, `TaskModel`, `TaskState` from `kzen-auto-common/.../paradigm/task/model/**` to `kzen-lib-common/.../exec/task/model/**`.
- Drop `TaskModel.requestAction()` (unused; severs the `CommonRestApi` import that would otherwise block the move).
- Update kzen-auto consumers' imports (6 files): `RestHandler.kt`, `ModelTaskRepository.kt`, `AdhocTask.kt`, `ClientRestApi.kt`, `ClientRestTaskRepository.kt`, `CustomObjectTask.kt`.
- Drop `objectStableMapper: ObjectStableMapper` parameter from `Logic.execute`, `LogicHandle.start`, `LogicHandleFacade` ctor, `LogicExecutionFacadeImpl` ctor. Impls (`ScriptDocument`, `AdhocLogic`, `ScriptExecution`, `ServerLogicController`, etc.) acquire the mapper from `KzenAutoContext.global().objectStableMapper` instead.
- `publishToMavenLocal` for the three kzen-lib subprojects (still at the current SNAPSHOT) so variant-suffix coords resolve against the new content.

### Out
- Version bumps — same release-train policy as Move B; see [CODING_STANDARDS](../docs/CODING_STANDARDS.md) CC-14.
- `ModelTaskRepository` relocation — stays in kzen-auto per the investigation doc ("Stays in kzen-auto: ServerLogicController, LogicExecutionFacadeImpl, LogicTraceStore (in-memory), ModelTaskRepository").
- `AdhocTask` (kzen-auto-jvm) — `ManagedTask` implementation, stays in kzen-auto.
- `ClientRestTaskRepository`, `CustomObjectTask{Header,Body,Runner}` (kzen-auto-js) — client impls, stay in kzen-auto.
- `LogicTraceStore.objectLocationHistory` `ObjectStableId`-keying migration — still deferred.
- Move D (client-side `ObjectStableMapper`).
- Adding a `tracing` capability to `Task` — investigation doc explicitly defers this; user hasn't asked.

## Target package layout

| Module / source set | Package | Contents |
|---|---|---|
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.task` | `ManagedTask`, `TaskRepository`, `TaskRun`, `TaskHandle` |
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.task.model` | `TaskId`, `TaskModel` (sans `requestAction`), `TaskProgress`, `TaskState` |

Stays in kzen-auto:

| Module / source set | Package | Contents |
|---|---|---|
| `kzen-auto-jvm` | `tech.kzen.auto.server.service.exec` | `ModelTaskRepository` (impl) |
| `kzen-auto-jvm` | `tech.kzen.auto.server.objects.custom.test` | `AdhocTask` (`ManagedTask` impl) |
| `kzen-auto-js` | `tech.kzen.auto.client.service.rest` | `ClientRestTaskRepository`, `ClientRestApi` |
| `kzen-auto-js` | `tech.kzen.auto.client.objects.document.custom.view.obj` | `CustomObjectTaskHeader`, `CustomObjectTaskBody`, `CustomObjectTaskRunner` |

## Sub-tier sequencing

Each sub-tier is one compilation cycle. Build kzen-lib + `publishToMavenLocal` between tiers that flip coupled types so kzen-auto's variant-suffix coord resolution sees the new content.

| Tier | Files | Where to | Risk |
|---|---|---|---|
| **C1** | `TaskId`, `TaskProgress`, `TaskState` | kzen-lib-common/commonMain | Pure data, no external deps. |
| **C2** | `TaskRun`, `TaskHandle`, `ManagedTask`, `TaskModel` (drop `requestAction`), `TaskRepository` | kzen-lib-common/commonMain | Interfaces + `TaskModel`. `TaskModel.requestAction()` removed to sever the `CommonRestApi` dep. Verify by grep before deletion. |
| **C3** | `cd ../kzen-lib && ./gradlew publishToMavenLocal`; then update consumers' imports across kzen-auto | kzen-auto | Mechanical sed-style rewrite in 6 files. |
| **C4** | Drop `objectStableMapper` param from `Logic.execute`, `LogicHandle.start`, `LogicHandleFacade` ctor/field, `LogicExecutionFacadeImpl` ctor; rewire impls to `KzenAutoContext.global().objectStableMapper` | kzen-lib + kzen-auto | Move B follow-up. Interface changes in kzen-lib; impl rewires in kzen-auto only. |
| **C5** | Republish kzen-lib at the existing SNAPSHOT (no bump per CC-14); republish kzen-auto; verify cross-sibling builds | kzen-lib + kzen-auto | Standard publish dance. |

## File-by-file disposition

### kzen-auto-common → kzen-lib-common/commonMain

Delete after copy + reimport everywhere:
```
kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/task/
  ├─ ManagedTask.kt
  ├─ TaskHandle.kt
  ├─ TaskRepository.kt
  ├─ TaskRun.kt
  └─ model/
      ├─ TaskId.kt
      ├─ TaskModel.kt        (drop requestAction(); drop CommonRestApi import)
      ├─ TaskProgress.kt
      └─ TaskState.kt
```

Create:
```
kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/exec/task/
  ├─ ManagedTask.kt
  ├─ TaskHandle.kt
  ├─ TaskRepository.kt
  ├─ TaskRun.kt
  └─ model/
      ├─ TaskId.kt
      ├─ TaskModel.kt
      ├─ TaskProgress.kt
      └─ TaskState.kt
```

### Consumers to update (import-path rewrite)

```
kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/api/RestHandler.kt
  - tech.kzen.auto.common.paradigm.task.model.TaskId → tech.kzen.lib.common.exec.task.model.TaskId
  - tech.kzen.auto.common.paradigm.task.model.TaskModel → tech.kzen.lib.common.exec.task.model.TaskModel

kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/exec/ModelTaskRepository.kt
  - tech.kzen.auto.common.paradigm.task.* → tech.kzen.lib.common.exec.task.*
  - tech.kzen.auto.common.paradigm.task.model.* → tech.kzen.lib.common.exec.task.model.*

kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/custom/test/AdhocTask.kt
  - tech.kzen.auto.common.paradigm.task.{ManagedTask,TaskHandle,TaskRun} → tech.kzen.lib.common.exec.task.{ManagedTask,TaskHandle,TaskRun}

kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/rest/ClientRestApi.kt
  - tech.kzen.auto.common.paradigm.task.model.{TaskId,TaskModel} → tech.kzen.lib.common.exec.task.model.{TaskId,TaskModel}

kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/rest/ClientRestTaskRepository.kt
  - tech.kzen.auto.common.paradigm.task.TaskRepository → tech.kzen.lib.common.exec.task.TaskRepository
  - tech.kzen.auto.common.paradigm.task.model.{TaskId,TaskModel} → tech.kzen.lib.common.exec.task.model.{TaskId,TaskModel}

kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/custom/view/obj/CustomObjectTask.kt
  - tech.kzen.auto.common.paradigm.task.model.{TaskModel,TaskState} → tech.kzen.lib.common.exec.task.model.{TaskModel,TaskState}
```

## Drop-redundant-ObjectStableMapper-parameter details

The mapper is owned by `KzenAutoContext.global().objectStableMapper` after Move A, and indirectly by `LogicTraceStore` after Move B. Logic implementations in kzen-auto already reach `KzenAutoContext.global()` for other services (e.g. `ScriptExecution.continueOrStart` calls `KzenAutoContext.global().graphCreator`). Threading the mapper through the `Logic` interface chain is redundant.

Signature changes (kzen-lib-common):

```kotlin
// Before
interface Logic {
    fun define(): LogicDefinition
    fun execute(
        logicHandle: LogicHandle,
        logicTraceHandle: LogicTraceHandle,
        logicRunExecutionId: LogicRunExecutionId,
        logicControl: LogicControl,
        objectStableMapper: ObjectStableMapper       // ← drop
    ): LogicExecution
}

interface LogicHandle {
    fun start(
        logicRunExecutionId: LogicRunExecutionId,
        originalObjectLocation: ObjectLocation,
        objectStableMapper: ObjectStableMapper       // ← drop
    ): LogicExecutionFacade
}

class LogicHandleFacade(
    private val logicRunExecutionId: LogicRunExecutionId,
    private val logicHandle: LogicHandle,
    private val objectStableMapper: ObjectStableMapper  // ← drop field + ctor param
) {
    fun start(originalObjectLocation: ObjectLocation): LogicExecutionFacade {
        return logicHandle.start(logicRunExecutionId, originalObjectLocation, objectStableMapper)
    }
}
```

Impl-side changes (kzen-auto-jvm):

- `ServerLogicController` (`LogicHandle` impl): drop `objectStableMapper` parameter from `start(...)`; the controller already has the singleton via its constructor (post-Move-A).
- `LogicExecutionFacadeImpl(...)`: drop ctor param; the controller already passes it; can compute via `KzenAutoContext.global()` or inject in Move A's wiring style.
- `ScriptDocument.execute(...)` (`Logic` impl): drop the param; acquire `KzenAutoContext.global().objectStableMapper` inside when constructing `ScriptExecution`. `ScriptExecution`'s own ctor field stays (it uses the mapper from multiple methods).
- `AdhocLogic.execute(...)`: same — drop the param, acquire from `KzenAutoContext.global()` when needed.
- `LogicHandleFacade` construction sites in kzen-auto (e.g. `ScriptExecution.logicHandleFacade`): drop the third argument.

`LogicFrame` (kzen-lib-jvm) currently captures the mapper as a field — keep, since it's a JVM-side execution helper that is constructed with explicit dependencies, not an interface seam. Same for `LogicContext` and `MutableLogicControl` if they touch the mapper.

## Verification

After each sub-tier:
- `cd ../kzen-lib && ./gradlew compileKotlinMetadata compileKotlinJvm compileKotlinJs` (or full `build`).
- After C2 / C3: `cd ../kzen-lib && ./gradlew publishToMavenLocal` (same SNAPSHOT) so variant-suffix coord resolution picks up the new content.
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:build`.

Final:
- `cd ../kzen-lib && ./gradlew publishToMavenLocal` (final SNAPSHOT republish — CC-14).
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:build` (incl. tests).
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest" --tests "*LogicTraceStoreRenameTest"` (Kotlin-inference canary + Move-A regression guard).
- `cd ../kzen-auto && ./gradlew :kzen-auto-js:build -x test`.
- (sanity) `cd ../kzen-project && ./gradlew build` *if convenient* — neither kzen-project nor kzen-launcher nor kzen-shell references the moving Task package, so green = noop, but confirms no transitive break.

Manual end-to-end (in IntelliJ standalone kzen-auto session):
1. `BackendDevelopment` + `FrontendDevelopment` start cleanly.
2. Open a Script, step it, stop, rename a step → trace still resolves under new name (Move A behaviour preserved; the mapper-parameter drop is pure plumbing).
3. Open a Custom Object that surfaces an `AdhocTask`, run it via the `▶` button, watch the partial result tick — exercises the full Task path through `ClientRestTaskRepository` → `RestHandler` → `ModelTaskRepository`.

## Risks

- **`CommonRestApi` import severance via dropping `TaskModel.requestAction()`.** Verified unused by grep; if the deletion uncovers a JS call site that the grep missed, restore the method as a free function in `kzen-auto-common` that takes a `TaskModel` and returns the action — don't re-introduce the kzen-lib → kzen-auto dependency.
- **`ObjectStableMapper` parameter drop is observable on Logic SPI.** Any out-of-tree `Logic` implementation in a plugin recompiles with one fewer parameter. Accept as a breaking change at the existing SNAPSHOT.
- **kzen-auto-plugin SPI doesn't expose `Logic`** (see investigation doc). Plugin source unaffected.
- **Cross-sibling republish ordering.** Same as Move B per umbrella AGENTS.md: kzen-lib → kzen-auto (with `:kzen-auto-plugin:publishToMavenLocal`) → kzen-project ‖ kzen-launcher → kzen-shell. Version pins stay at the existing SNAPSHOT (CC-14).
- **`Logic` impls that today use the mapper through the parameter** must switch to `KzenAutoContext.global().objectStableMapper`. The relevant impls (`ScriptDocument`, `AdhocLogic`) already reach `KzenAutoContext.global()` for `graphCreator` — no new coupling.

## Out-of-scope follow-ups (note for future work)

- `LogicTraceStore.objectLocationHistory` still keyed by `ObjectLocation`. Migrating to `ObjectStableId` survives rename of the script root document on the "Reset" path. Defer.
- Move D — client-side `ObjectStableMapper`. Defer; current `ScriptStore.refreshProgressAsync` re-fetch is good enough.
- `originalObjectLocation` in `LogicHandle.start` / `LogicExecutionFacadeImpl` is the *entry-point object* used as a trace scope key, **not** an analogue of `ObjectStableMapper`. Leave it.
