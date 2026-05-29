# Move B — Relocate Logic + Trace + Tuple to kzen-lib

> Second slice of the multi-step refactor described in [`2026-05-28_logic-task-trace-relocation.md`](2026-05-28_logic-task-trace-relocation.md). Move A landed; per-server-lifetime `ObjectStableMapper` is now wired into `KzenAutoContext`. This slice relocates the Logic abstraction, Trace abstraction, and Tuple data model from `kzen-auto` to `kzen-lib`, drops the `service.v1.*` placeholder packages, and converts `LogicTraceStore` from a global `object` singleton to a constructor-injected `class`.

> **Status: landed 2026-05-28.**

## Context

User direction:
- "move Logic and Task to kzen-lib (with related classes, like Trace, any related tests, etc.)"
- "all execution (Logic and Task with associated Trace) should be done using ObjectStableId" — already true on the server post-Move-A
- "TupleValue ... is a pure data structure and part of the Logic model. it should also move over to kzen-lib (along with TupleDefinition, etc.)"
- "feel free to change the package to be more appropriate (i.e. 'v1' is a temporary placeholder)"
- "since we're bringing things over to kzen-lib, we want to avoid any global state ... `LogicTraceStore` is currently an `object`, but when moving across it should be an instance (passed via constructor if necessary, i.e. using manual dependency injection)"

Constraints surfaced during inventory:
- Only `kzen-auto` references the moving symbols. `kzen-project`, `kzen-launcher`, `kzen-shell` only need to consume the republished kzen-lib SNAPSHOT — no source updates, no version bumps (see CC-14).
- `LogicConventions` embeds `auto-jvm/logic/logic-trace.yaml` path; it stays in `kzen-auto-common`. Bringing it across would tangle auto's `CommonRestApi` into kzen-lib for no win.
- `kzen-lib-common/jvmMain` is reserved for `expect/actual` platform glue. JVM-only Logic execution code goes in `kzen-lib-jvm` (separate subproject), alongside existing JVM-side services like `ClasspathNotationMedia`. Pure data/interfaces (no `java.util.concurrent`, no `kotlinx.coroutines`) go in `kzen-lib-common/commonMain`.

## Scope

### In
- Relocate pure-data and interface types from `kzen-auto-common/commonMain/.../paradigm/logic/**` to `kzen-lib-common/commonMain/.../exec/logic/**`.
- Relocate Tuple data model from `kzen-auto-jvm/.../service/v1/model/tuple/**` to `kzen-lib-common/commonMain/.../exec/tuple/**`.
- Relocate Logic-result + Logic-definition + Logic-type pure data from `kzen-auto-jvm/.../service/v1/model/**` to `kzen-lib-common/commonMain/.../exec/logic/model/**`.
- Relocate Logic interfaces (`Logic`, `LogicHandle`, `LogicControl`, `LogicExecution`, `LogicExecutionFacade`, `LogicHandleFacade`, `LogicExecutionListener`, `LogicTraceHandle`, `StatefulLogicElement`) to `kzen-lib-common/commonMain/.../exec/logic/**`.
- Relocate JVM-coupled implementations (`LogicFrame`, `LogicContext`, `MutableLogicControl`) to `kzen-lib-jvm/.../server/exec/logic/context/**`.
- Relocate `LogicTraceStore` to `kzen-lib-jvm/.../server/exec/logic/trace/**` **as a `class`, not `object`**. Constructor takes the singleton `ObjectStableMapper` so `handle(...)`'s `objectStableMapper` parameter goes away.
- Keep a thin `LogicTraceEndpoint: DetachedAction` wrapper in `kzen-auto-jvm` that reads `KzenAutoContext.global().logicTraceStore` and delegates the REST surface. Update `auto-jvm/logic/logic-trace.yaml` to point at the new endpoint object.
- `publishToMavenLocal` for the three kzen-lib subprojects (still at the current SNAPSHOT) so variant-suffix coords resolve against the new content.

### Out
- `Task` relocation — Move C, separate plan.
- Client-side `ObjectStableMapper` — Move D, deferred.
- Version bumps — the kzen siblings are a coordinated release train (see [CODING_STANDARDS](../docs/CODING_STANDARDS.md) CC-14). Move B lands at the current `0.29.1-SNAPSHOT` for all siblings; the release lead bumps explicitly.
- `ServerLogicController`, `LogicExecutionFacadeImpl`, `ModelTaskRepository`, `LogicConventions` stay in kzen-auto.
- Wire-format changes to `LogicTracePath` (`$stable` prefix encoding unchanged).
- Trace-key migration of `LogicTraceStore.objectLocationHistory` from `ObjectLocation` to `ObjectStableId` (small consistency win; deferred to keep scope tight).

## Target package layout

| Module / source set | Package | Contents |
|---|---|---|
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.logic` | `Logic`, `LogicHandle`, `LogicHandleFacade`, `LogicControl`, `LogicExecution`, `LogicExecutionFacade`, `LogicExecutionListener`, `StatefulLogicElement` |
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.logic.model` | `LogicCommand`, `LogicDefinition`, `LogicResult` (+ subclasses), `LogicType` |
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.logic.run` | `LogicController` |
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.logic.run.model` | `LogicRunId`, `LogicExecutionId`, `LogicRunExecutionId`, `LogicStatus`, `LogicRunInfo`, `LogicRunFrameInfo`, `LogicRunFrameState`, `LogicRunResponse`, `LogicRunState` |
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.logic.trace` | `LogicTrace`, `LogicTraceHandle` |
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.logic.trace.model` | `LogicTracePath`, `LogicTraceQuery`, `LogicTraceSnapshot` |
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.exec.tuple` | `TupleValue`, `TupleDefinition`, `TupleComponentValue`, `TupleComponentDefinition`, `TupleComponentName` |
| `kzen-lib-jvm` | `tech.kzen.lib.server.exec.logic.context` | `LogicFrame`, `LogicContext`, `MutableLogicControl` |
| `kzen-lib-jvm` | `tech.kzen.lib.server.exec.logic.trace` | `LogicTraceStore` (now a `class`) |

Stays in kzen-auto:

| Module / source set | Package | Contents |
|---|---|---|
| `kzen-auto-common/commonMain` | `tech.kzen.auto.common.paradigm.logic` | `LogicConventions` (HTTP wire convention; embeds `auto-jvm/logic/logic-trace.yaml` resource path) |
| `kzen-auto-jvm` | `tech.kzen.auto.server.service.impl` | `ServerLogicController`, `LogicExecutionFacadeImpl` (drops `v1` segment per B6) |
| `kzen-auto-jvm` | `tech.kzen.auto.server.objects.logic` | `LogicTraceEndpoint` (NEW — `DetachedAction` adapter for `LogicTraceStore`; replaces the old `object LogicTraceStore: LogicTrace, DetachedAction`) |
| `kzen-auto-jvm` | `tech.kzen.auto.server.service.exec` | `ModelTaskRepository` (already there) |

## Sub-tier sequencing

Each sub-tier is one Kotlin compilation cycle. Build kzen-lib + publishToMavenLocal between tiers if a tier flips coupled types (i.e. anything kzen-auto sources will newly import). Do **not** flip kzen-auto consumers' imports until the symbol exists in the new location.

| Tier | Files | Where to | Risk |
|---|---|---|---|
| **B1** | `LogicRunId`, `LogicExecutionId`, `LogicRunExecutionId`, `LogicStatus`, `LogicRunInfo`, `LogicRunFrameInfo`, `LogicRunFrameState`, `LogicRunResponse`, `LogicRunState`, `LogicTracePath`, `LogicTraceQuery`, `LogicTraceSnapshot` | kzen-lib-common/commonMain | Mechanical — pure data, no kzen-auto deps. |
| **B2** | `Logic`, `LogicHandle`, `LogicHandleFacade`, `LogicControl`, `LogicExecution`, `LogicExecutionFacade`, `LogicExecutionListener`, `LogicTraceHandle`, `LogicTrace`, `LogicController`, `StatefulLogicElement` | kzen-lib-common/commonMain | Interfaces. Some reference types still in kzen-auto (`LogicDefinition`, `TupleValue`, `LogicResult`) — order with B3 carefully. Solution: do B3 before B2 to avoid forward dangling refs. |
| **B3** | `TupleValue`, `TupleDefinition`, `TupleComponentValue`, `TupleComponentDefinition`, `TupleComponentName`, `LogicResult` (sealed + 4 subclasses), `LogicDefinition`, `LogicType`, `LogicCommand` | kzen-lib-common/commonMain | Pure data. `LogicType` uses `TypeMetadata` (already kzen-lib); `LogicDefinition` uses `TupleDefinition` (also moving same tier). |
| **B4** | `LogicFrame`, `LogicContext`, `MutableLogicControl` | kzen-lib-jvm | First non-platform code in kzen-lib-jvm's main bucket (`server.exec.logic.context.*`). Uses `CopyOnWriteArrayList`. |
| **B5** | `LogicTraceStore` (converted to `class`) | kzen-lib-jvm | Drop `@Reflect`, drop `object`, drop `DetachedAction` impl; constructor takes `ObjectStableMapper`. Drop `objectStableMapper` parameter from `handle(...)`. |
| **B6** | Adapter + plumbing in kzen-auto | kzen-auto-jvm | New `LogicTraceEndpoint: DetachedAction` (object — singleton via notation) that delegates to `KzenAutoContext.global().logicTraceStore`. Update `logic-trace.yaml` `ObjectName("LogicTraceStore")` → `ObjectName("LogicTraceEndpoint")` and `LogicConventions.logicTraceStoreName` to match. `KzenAutoContext` constructs `LogicTraceStore(objectStableMapper)`. `ServerLogicController` takes `LogicTraceStore` via constructor; `start(...)` calls `logicTraceStore.handle(runExecutionId, root)` (without mapper). |
| **B7** | Move `ServerLogicController` + `LogicExecutionFacadeImpl` out of `service.v1.impl` to `service.impl`. Move test class `LogicTraceStoreRenameTest` to track LogicTraceStore's new home (still in kzen-auto-jvm test, with updated imports) or relocate to kzen-lib-jvm's test subproject. | kzen-auto-jvm + kzen-lib-jvm | Drop placeholder segment. Test placement: keep in kzen-auto-jvm — it exercises the wire-format gap end-to-end. Add a parallel pure-store unit test in kzen-lib-jvm if useful. |
| **B8** | Republish kzen-lib at the existing SNAPSHOT version so consumers pick up the moved symbols. **Do not bump versions** (CC-14). | kzen-lib | `cd ../kzen-lib && ./gradlew publishToMavenLocal`. |

## File-by-file disposition

### kzen-auto-common → kzen-lib-common/commonMain

Delete after copy + reimport everywhere:
```
kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/logic/
  ├─ run/
  │   ├─ LogicController.kt
  │   └─ model/
  │       ├─ LogicExecutionId.kt
  │       ├─ LogicRunExecutionId.kt
  │       ├─ LogicRunFrameInfo.kt
  │       ├─ LogicRunFrameState.kt
  │       ├─ LogicRunId.kt
  │       ├─ LogicRunInfo.kt
  │       ├─ LogicRunResponse.kt
  │       ├─ LogicRunState.kt
  │       └─ LogicStatus.kt
  └─ trace/
      ├─ LogicTrace.kt
      └─ model/
          ├─ LogicTracePath.kt
          ├─ LogicTraceQuery.kt
          └─ LogicTraceSnapshot.kt
```

Keep:
```
kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/logic/
  └─ LogicConventions.kt    (stays — embeds auto-jvm yaml path)
```

### kzen-auto-jvm → kzen-lib-common/commonMain (data) + kzen-lib-jvm (execution)

Move to `kzen-lib-common/commonMain/.../exec/`:
```
service/v1/Logic.kt                              → exec/logic/Logic.kt
service/v1/LogicHandle.kt                        → exec/logic/LogicHandle.kt
service/v1/LogicHandleFacade.kt                  → exec/logic/LogicHandleFacade.kt
service/v1/LogicControl.kt                       → exec/logic/LogicControl.kt
service/v1/LogicExecution.kt                     → exec/logic/LogicExecution.kt
service/v1/LogicExecutionFacade.kt               → exec/logic/LogicExecutionFacade.kt
service/v1/LogicExecutionListener.kt             → exec/logic/LogicExecutionListener.kt
service/v1/StatefulLogicElement.kt               → exec/logic/StatefulLogicElement.kt
objects/logic/LogicTraceHandle.kt                → exec/logic/trace/LogicTraceHandle.kt
service/v1/model/LogicCommand.kt                 → exec/logic/model/LogicCommand.kt
service/v1/model/LogicDefinition.kt              → exec/logic/model/LogicDefinition.kt
service/v1/model/LogicResult.kt                  → exec/logic/model/LogicResult.kt
service/v1/model/LogicType.kt                    → exec/logic/model/LogicType.kt
service/v1/model/tuple/TupleValue.kt             → exec/tuple/TupleValue.kt
service/v1/model/tuple/TupleDefinition.kt        → exec/tuple/TupleDefinition.kt
service/v1/model/tuple/TupleComponentValue.kt    → exec/tuple/TupleComponentValue.kt
service/v1/model/tuple/TupleComponentDefinition.kt → exec/tuple/TupleComponentDefinition.kt
service/v1/model/tuple/TupleComponentName.kt     → exec/tuple/TupleComponentName.kt
```

Move to `kzen-lib-jvm`:
```
service/v1/model/context/LogicFrame.kt           → server/exec/logic/context/LogicFrame.kt
service/v1/model/context/LogicContext.kt         → server/exec/logic/context/LogicContext.kt
service/v1/model/context/MutableLogicControl.kt  → server/exec/logic/context/MutableLogicControl.kt
objects/logic/LogicTraceStore.kt                 → server/exec/logic/trace/LogicTraceStore.kt
                                                    (CONVERTED: object → class; constructor injection; drop DetachedAction)
```

Stays in kzen-auto-jvm (drop `v1` placeholder):
```
service/v1/impl/ServerLogicController.kt         → service/impl/ServerLogicController.kt
service/v1/impl/LogicExecutionFacadeImpl.kt      → service/impl/LogicExecutionFacadeImpl.kt
```

New in kzen-auto-jvm:
```
objects/logic/LogicTraceEndpoint.kt
  - DetachedAction adapter (object — singleton via Kzen notation)
  - Delegates to KzenAutoContext.global().logicTraceStore for the REST surface
```

### Notation updates (kzen-auto-jvm resources)

Edit:
```
kzen-auto-jvm/src/main/resources/notation/auto-jvm/logic/logic-trace.yaml
  - ObjectName "LogicTraceStore" → "LogicTraceEndpoint"
  - Class binding follows
```

Edit `LogicConventions.logicTraceStoreName` accordingly (`ObjectName("LogicTraceEndpoint")`) — and rename the const, e.g. `logicTraceEndpointName`/`logicTraceEndpointLocation`. The "LogicTrace" *name* is what's in user-visible YAML registration — keep it consistent with the new file.

## LogicTraceStore conversion details

Today:
```kotlin
@Reflect
object LogicTraceStore: LogicTrace, DetachedAction {
    fun handle(runExecutionId, objectLocation, objectStableMapper): LogicTraceHandle { ... }
    override suspend fun execute(request): ExecutionResult { ... }   // DetachedAction binding
    override fun mostRecent(...): LogicRunExecutionId? { ... }
    override fun clear(...): Boolean { ... }
    override fun lookup(...): LogicTraceSnapshot? { ... }
    fun evict(logicRunId): Unit { ... }
}
```

After:
```kotlin
// kzen-lib-jvm
class LogicTraceStore(
    private val objectStableMapper: ObjectStableMapper
): LogicTrace {
    fun handle(runExecutionId: LogicRunExecutionId, objectLocation: ObjectLocation): LogicTraceHandle { ... }
    override fun mostRecent(...): LogicRunExecutionId? { ... }
    override fun clear(...): Boolean { ... }
    override fun lookup(...): LogicTraceSnapshot? { ... }
    fun evict(logicRunId: LogicRunId): Unit { ... }
}
```

```kotlin
// kzen-auto-jvm
@Reflect
object LogicTraceEndpoint: DetachedAction {
    override suspend fun execute(request: ExecutionRequest): ExecutionResult {
        val store = KzenAutoContext.global().logicTraceStore
        // ... action dispatch, same shape as old LogicTraceStore.execute()
    }
}
```

`KzenAutoContext`:
```kotlin
val logicTraceStore = LogicTraceStore(objectStableMapper)
val serverLogicController = ServerLogicController(
    graphStore, graphCreator, objectStableMapper, logicTraceStore)
```

`ServerLogicController.start(...)`:
```kotlin
val logicTraceHandle = logicTraceStore.handle(runExecutionId, root)   // mapper held by store
```

`TraceBuffer` internal data class loses its `var objectStableMapper` field; `getOrCreateBuffer` simplifies; `matchesPrefix` / `resolveStoredPath` take the store's `objectStableMapper` directly.

## Verification

After each sub-tier:
- `cd ../kzen-lib && ./gradlew build` (or at minimum `compileKotlin*` for the touched module).
- After tiers that move kzen-lib symbols consumed by kzen-auto: `cd ../kzen-lib && ./gradlew publishToMavenLocal` so variant-suffix coords resolve.
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:build`.

Final:
- `cd ../kzen-lib && ./gradlew kotlinUpgradeYarnLock` (if any common moves shift transitive JS deps — likely not, but cheap to confirm; commit any regenerated `kotlin-js-store/yarn.lock`).
- `cd ../kzen-lib && ./gradlew publishToMavenLocal` (final republish at the existing SNAPSHOT — see CC-14).
- `cd ../kzen-auto && ./gradlew build` (end-to-end).
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest" --tests "*LogicTraceStoreRenameTest"` (canaries — FormulaStep for Kotlin inference, LogicTraceStoreRenameTest for the Move-A gap that we must not regress).
- `cd ../kzen-project && ./gradlew build`.
- `cd ../kzen-launcher && ./gradlew build`.
- `cd ../kzen-shell && ./gradlew build`.

Manual end-to-end (in IntelliJ standalone kzen-auto session):
1. `BackendDevelopment` + `FrontendDevelopment` start cleanly.
2. Open a Script, step the first step, stop, rename → trace still resolves under new name (Move A behaviour preserved).
3. REST `/main/run/api/v1/trace/recent` (or whatever path `LogicTraceEndpoint` is mounted at) still answers — `LogicConventions.logicTraceEndpointLocation` is what the client uses to dispatch.

## Risks

- **kzen-lib-jvm becomes a non-trivial business-logic host.** Today it only has notation/media JVM glue. Adding Logic execution code formally promotes kzen-lib-jvm to "service implementations live here too". This isn't bad — `ClasspathNotationMedia`, `GradleLocator` are already similar — but it's worth a one-line note in `kzen-lib/AGENTS.md` after this lands.
- **`@Reflect` + `object` registration** assumes the YAML names a singleton. The notation YAML for the trace endpoint must be edited to name `LogicTraceEndpoint` instead of `LogicTraceStore`. KSP-generated reflection (`@Reflect`) is regenerated on next build. If the YAML still names `LogicTraceStore` when nothing claims that name anymore, definition resolution will fail at boot.
- **`LogicConventions.logicTraceStoreLocation`** is used by client code (e.g. `RibbonLogicRun`) to dispatch REST. Renaming the const requires updating all call sites. Search and replace.
- **Cross-sibling republish ordering.** Per umbrella AGENTS.md, the order is kzen-lib → kzen-auto (with `:kzen-auto-plugin:publishToMavenLocal`) → kzen-project ‖ kzen-launcher → kzen-shell. Version pins stay at the existing SNAPSHOT (CC-14); each republish overwrites the SNAPSHOT artifact in mavenLocal so downstream variant-suffix coord resolution picks up the new content at the unchanged version.
- **`LogicTraceStoreRenameTest` import drift.** The test currently imports `tech.kzen.auto.common.paradigm.logic.*`. Update to the new `tech.kzen.lib.common.exec.logic.*` packages. Also: the test invokes `LogicTraceStore.evict(...)` and `LogicTraceStore.clear(...)` as singleton calls in `@After`. With the conversion to `class`, the test must construct (or reuse) an instance — refactor `@After` to evict via the test's own store reference rather than a singleton. The three test cases already construct `ObjectStableMapper` directly; they likewise construct `LogicTraceStore(mapper)` directly.

## Out-of-scope follow-ups (note for Move C / Move D)

- `Logic.execute(...)`, `LogicHandle.start(...)`, `LogicExecutionFacadeImpl.open(...)` still take an `objectStableMapper: ObjectStableMapper` parameter. With the mapper now a server-wide singleton reachable via `KzenAutoContext.global()` (or via the store's already-injected mapper), the parameter is redundant. Drop in Move C or as a tidy-up step after Move B if scope permits.
- `LogicTraceStore.objectLocationHistory` is keyed by `ObjectLocation`. Migrating to `ObjectStableId` would make the "Reset" path survive a rename of the script root — minor consistency win. Deferred.
- Move C — Task relocation, same pattern.
- Move D — client-side mapper (optional polish).
