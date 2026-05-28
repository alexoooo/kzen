# Move A — Process-global ObjectStableMapper (server-side)

> First slice of the multi-step refactor described in [`2026-05-28_logic-task-trace-relocation.md`](2026-05-28_logic-task-trace-relocation.md). Closes the "trace dies on rename after run ends" gap. No kzen-lib changes.

## Context

After landing the recent rename-survival fix, the per-run `ObjectStableMapper` is unobserved from `graphStore` when the run ends (`ServerLogicController.clearState()`). The `LogicTraceStore` retains the trace buffer past run-end, but any rename that happens *after* `clearState()` is no longer seen by the (now-detached) mapper, so `LogicTraceStore.lookup(...)` translates `$stable`-prefix paths against a stale id → location map and the trace disappears from the UI.

Fix: make the mapper a singleton owned by `KzenAutoContext`, observe `graphStore` once at boot, never unobserve. This matches the lifecycle of `modelTaskRepository`, `activeDataflowRepository`, `visualDataflowRepository` — three observers already attached at `KzenAutoContext.init()`.

## Scope

In:
- `KzenAutoContext` constructs the singleton mapper, observes it at boot, pre-warms it from the initial graph notation.
- `ServerLogicController` takes the mapper as a constructor parameter; drops per-run construction and observe/unobserve.
- `LogicTraceStore.handle(...)` continues to take a mapper but always receives the singleton.
- New jvmTest verifying rename-after-run-stop translation.

Out:
- No relocation of any types to kzen-lib (that's Move B).
- No client-side mapper (that's Move D).
- No kzen-lib version bump.
- `Logic.execute(...)`, `LogicHandle.start(...)`, `LogicExecutionFacadeImpl.open(...)` keep their `objectStableMapper: ObjectStableMapper` parameter — the parameter just always receives the singleton now. (Deferring the simplification of these signatures to Move B, where the types are moving anyway.)

## Critical files

### `kzen-auto-jvm` — `KzenAutoContext.kt`

Add (next to `modelTaskRepository`):

```kotlin
val objectStableMapper = ObjectStableMapper()
```

Pass to `ServerLogicController`:

```kotlin
val serverLogicController = ServerLogicController(
    graphStore, graphCreator, objectStableMapper)
```

In `init()`, after the existing `graphStore.observe(...)` calls, register the mapper and pre-warm it:

```kotlin
runBlocking {
    graphStore.observe(activeDataflowRepository)
    graphStore.observe(visualDataflowRepository)
    graphStore.observe(modelTaskRepository)
    graphStore.observe(objectStableMapper)

    // Pre-warm so ids reflect names-at-boot deterministically, independent of
    // first-access order during run execution.
    val initialDefinition = graphStore.graphDefinition().successful()
    for (location in initialDefinition.objectDefinitions.map.keys) {
        objectStableMapper.objectStableId(location)
    }
}
```

(Verify `successful()` is safe here — if the initial graph has definition errors, we may need to iterate `objectDefinitions.map.keys` of the partial result; either way the pre-warm is best-effort.)

### `kzen-auto-jvm` — `ServerLogicController.kt`

Constructor:

```kotlin
class ServerLogicController(
    private val graphStore: LocalGraphStore,
    private val graphCreator: GraphCreator,
    private val objectStableMapper: ObjectStableMapper
): LogicController
```

In `start(...)`:
- Delete `val objectStableMapper = ObjectStableMapper()` (line ~123).
- Delete the per-run `graphStore.observe(objectStableMapper)` block (lines ~185-187).
- Delete the `observerCommitted` flag and the `try { ... } finally { if (!observerCommitted) graphStore.unobserve(objectStableMapper) }` envelope (lines ~188-224). Keep the body of the try block as straight-line code.
- Keep the pre-warm-during-start loop? **No** — the boot-time pre-warm covers existing objects; objects added mid-run still get lazy-warmed via `objectStableMapper.objectStableId(loc)` calls during execution. The pre-warm-during-start was guarding against a now-impossible "mapper just constructed, hasn't seen anything yet" situation.
- The `LogicState` data class still holds `objectStableMapper` for convenience (it's passed into `frame.toInfo(...)`), but it's now just a reference to the singleton — could be dropped from `LogicState` and reached via `this.objectStableMapper` instead. Recommend dropping from `LogicState` to make the singleton nature explicit.

In `clearState()`:
- Delete the `try { state.frame.control.close() } finally { graphStore.unobserve(state.objectStableMapper) }` envelope. Replace with plain `state.frame.control.close()`. (The mapper outlives clearState — no cleanup needed.)

### `kzen-auto-jvm` — `LogicTraceStore.kt`

No structural change. `handle(...)` still accepts a mapper; the caller now always supplies the singleton.

(Could later simplify `TraceBuffer` to hold a single mapper reference instead of one per buffer, but that's cosmetic.)

### Test — `kzen-auto-jvm/src/test/kotlin/.../LogicTraceStoreRenameTest.kt` (new file)

Focused unit test, no server boot. Demonstrates the closed gap.

```kotlin
class LogicTraceStoreRenameTest {
    @Test
    fun `trace lookup survives rename event arriving after run ends`() {
        val mapper = ObjectStableMapper()
        val rootLocation = objectLocation("a.yaml", "MyScript")
        val stepLocation = objectLocation("a.yaml", "MyScript.steps", "Step1")

        // Pre-warm (simulating boot)
        mapper.objectStableId(rootLocation)
        mapper.objectStableId(stepLocation)

        val runExecutionId = LogicRunExecutionId(
            LogicRunId(arbitraryId()), LogicExecutionId(arbitraryId()))

        // Simulate an active run: store a trace entry under the step's stable id
        val handle = LogicTraceStore.handle(runExecutionId, rootLocation, mapper)
        handle.set(
            LogicTracePath.ofObjectStableId(mapper.objectStableId(stepLocation)),
            ExecutionValue.of("done"))

        // Simulate run end (no unobserve in the new model)

        // Simulate rename event arriving at the mapper (as if from graphStore)
        mapper.apply(RenamedObjectEvent(stepLocation, ObjectName("Step1Renamed")))

        // Trace lookup should resolve under the new name
        val snapshot = LogicTraceStore.lookup(rootLocation, LogicTraceQuery.all())
        val renamedLocation = objectLocation("a.yaml", "MyScript.steps", "Step1Renamed")
        val renamedPath = LogicTracePath.ofObjectLocation(renamedLocation)
        assertEquals(ExecutionValue.of("done"), snapshot?.values?.get(renamedPath))
    }
}
```

(Helper `objectLocation(documentPath, ...nestedPath, name)` constructs the location. Specifics align with existing test utility patterns.)

Add a second test case for the symmetry: rename arriving *between* `clearState` and `lookup` (the explicit user-reported scenario). Same shape, just remove the active-handle setup if the buffer-retention path differs.

Optional third test: churn — register many ids, delete them all via `DeletedDocumentEvent`, assert the mapper's internal maps shrink. Guards against the memory-bound concern.

## Verification

Build:
```powershell
cd C:\Users\ostro\IdeaProjects\kzen-auto
./gradlew :kzen-auto-jvm:test --tests "*LogicTraceStoreRenameTest"
./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest"   # Kotlin-inference canary
./gradlew :kzen-auto-jvm:build
```

Manual end-to-end (open kzen-auto standalone in IntelliJ per umbrella AGENTS.md):
1. Run `BackendDevelopment` + `FrontendDevelopment`.
2. Open a Script (e.g. `Script.yaml` with `Browse to URL x`).
3. Enter pause/step mode. Step once so first step is Done.
4. Stop execution (so `clearState` runs).
5. Rename the executed step via `StepNameEditor`. **Expected**: trace still visible under the new name without page refresh.
6. Repeat the cycle (rename → run again → stop → rename) to verify the singleton mapper accumulates state correctly.
7. Restart the server. **Expected**: trace cleared (in-memory store reset); ids re-assigned from current names.

## Risks

- **Pre-warm against a failing graph definition**: `graphDefinition().successful()` throws if the initial graph has errors. If we want the server to boot even with a broken notation, swap to `graphDefinition().attemptedSuccessful()` / catch-and-log. Confirm what existing code does at the same point.
- **Singleton lifetime vs project switch**: if kzen-launcher tears down and rebuilds `KzenAutoContext` (and therefore `DirectGraphStore` + the mapper) on project switch, ids reset for the new project — desired. If `KzenAutoContext` is reused across projects, ids leak across project boundaries — undesired. Quick check during implementation: confirm `KzenAutoContext.close()` plus reconstruction on project switch.
- **Backward compatibility with prior fix's `$stable`-prefix paths**: the `$stable` decoding in `LogicTraceStore.lookup` and `LogicTracePath.ofObjectStableId` is unchanged; the only thing that shifts is *which* mapper does the translation. No wire-format change.

## Out-of-scope follow-ups (note for Move B)

- `Logic.execute(...)`, `LogicHandle.start(...)`, `LogicExecutionFacadeImpl.open(...)` could drop the `objectStableMapper` parameter once the singleton is reachable via `KzenAutoContext.global()`. Deferring because Move B is going to rewrite all of these signatures during relocation anyway — no point churning them twice.
- Trace-key migration (`LogicTraceStore.objectLocationHistory` keyed by `ObjectStableId` instead of `ObjectLocation`) — could land here for symmetry; deferred to keep this slice tight.
