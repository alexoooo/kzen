# Move D — Client-side ObjectStableMapper (snapshot-sync at connect time)

> Fourth slice of the multi-step refactor in [`2026-05-28_logic-task-trace-relocation.md`](2026-05-28_logic-task-trace-relocation.md). Moves A+B+C have landed. This slice adds a process-global `ObjectStableMapper` on the client, seeded from the server via a connect-time snapshot. From that point both sides observe the same `LocalGraphStore` event stream, so the mappings stay in lock-step. Symmetrises the identity vocabulary across the wire and closes the last item the user originally flagged ("optionally per client") in the investigation doc.

> **Status: landed 2026-05-28.**

## Context

User direction (investigation doc, restated):
- "Replace per-execution ObjectStableMapper with one global mapper per server (and optionally per client)" — server side landed in Move A; this slice handles "optionally per client".

Constraints surfaced during inventory:
- **Wire-format risk** (id drift). Ids are `objectLocation.asString()` at *first encounter*. After a rename, the id stays put while the location moves — so an id created on the server before a rename does not equal the id the client would generate post-rename for the now-current location. Snapshot-sync at connect time fixes this: the client adopts the server's full `(id, location)` mapping, then both observe events from there.
- **Single mutator** (kzen-auto today). The client is the sole source of notation changes; commands go through `MirroredGraphStore` (`DirectGraphStore` locally + `RemoteGraphStore` to the server), so both sides see the same event sequence post-seeding. No WebSocket push needed for this slice.
- **Thread-safety of `ObjectStableMapper`** is intentionally minimal — backed by plain `mutableMapOf` and no synchronization, matching the existing pattern. `snapshot()` returns a defensive copy under the same caveat; if cross-thread reads/writes become a concern, that's a broader fix, not Move D's problem.
- **No version bump** per [CC-14](../docs/CODING_STANDARDS.md). Republish kzen-lib at `0.29.1-SNAPSHOT` after the mapper gains `snapshot()`/`seed(...)`.

Out of scope for this slice (deliberate): refactoring any client feature to *use* the new mapper. Move D lands the wiring only. Today's `ScriptStore.refreshProgressAsync` rename-fetch path remains unchanged; the client mapper sits ready for future consumers.

## Scope

### In
- Add `snapshot(): Map<ObjectStableId, ObjectLocation>` and `seed(snapshot: Map<ObjectStableId, ObjectLocation>)` methods to `ObjectStableMapper` (kzen-lib).
- New `CommonRestApi.objectStableMapperSnapshot = "/object-stable/snapshot"` route constant (kzen-auto-common).
- `RestHandler.objectStableMapperSnapshot(): Map<String, String>` — returns the server's current mapping as `{stable-id-string: current-location-string}` (kzen-auto-jvm).
- New route in `KzenAutoMain.routing` mounting the endpoint.
- `ClientRestApi.objectStableMapperSnapshot(): Map<ObjectStableId, ObjectLocation>` (kzen-auto-js).
- `ClientContext`: construct a client `ObjectStableMapper`; in `initAsync()` fetch the snapshot, seed the client mapper, then attach it to `mirroredGraphStore` as a `LocalGraphStore.Observer` for subsequent events.
- Unit test in `ObjectStableMapperTest` covering `snapshot()` and `seed(...)` round-trips.

### Out
- Version bumps — release-train policy (CC-14).
- Any client feature refactor to consume the new mapper. (Future PRs.)
- WebSocket / push wire — single-mutator assumption holds today; if multi-client emerges, snapshot-sync becomes insufficient and the server would need to push event streams. That's a separate change.
- Thread-safety upgrade for `ObjectStableMapper`. Existing pattern preserved.
- Removing the `ScriptStore` re-fetch-on-rename path — that fallback is the safety net; deletion is a later, deliberate change once a client consumer relies on the new mapper.

## Target package layout

No relocations in this slice. Only additions:

| Module / source set | Package | Addition |
|---|---|---|
| `kzen-lib-common/commonMain` | `tech.kzen.lib.common.service.store.normal` | `ObjectStableMapper.snapshot()` + `seed(...)` methods |
| `kzen-lib-common/commonTest` | `tech.kzen.lib.common.service.store.normal` | `ObjectStableMapperTest` — `snapshot/seed round-trip` test |
| `kzen-auto-common/commonMain` | `tech.kzen.auto.common.api` | `CommonRestApi.objectStableMapperSnapshot` constant |
| `kzen-auto-jvm` | `tech.kzen.auto.server.api` | `RestHandler.objectStableMapperSnapshot()` |
| `kzen-auto-jvm` | `tech.kzen.auto.server` | `KzenAutoMain.routeObjectStable` — new private route group |
| `kzen-auto-js` | `tech.kzen.auto.client.service.rest` | `ClientRestApi.objectStableMapperSnapshot()` |
| `kzen-auto-js` | `tech.kzen.auto.client.service` | `ClientContext.objectStableMapper` + seed in `initAsync()` |

## Sub-tier sequencing

| Tier | Files | Where | Risk |
|---|---|---|---|
| **D1** | Add `snapshot()` / `seed(...)` to `ObjectStableMapper`; add round-trip test. | kzen-lib-common | Trivial. Defensive map copy. |
| **D2** | `cd ../kzen-lib && ./gradlew publishToMavenLocal`. Then add `CommonRestApi.objectStableMapperSnapshot` + `RestHandler.objectStableMapperSnapshot()` + new private `routeObjectStable` in `KzenAutoMain`. | kzen-auto-common + kzen-auto-jvm | Wire-format JSON map `{id-string: location-string}`. |
| **D3** | `ClientRestApi.objectStableMapperSnapshot()` deserializing the JSON map. | kzen-auto-js | Mirror of D2. |
| **D4** | `ClientContext`: construct `ObjectStableMapper`; in `initAsync()` fetch snapshot, seed, then `mirroredGraphStore.observe(objectStableMapper)`. Plumb through `ClientStateGlobal.postConstruct` if it needs visibility (it doesn't today — leave unchanged). | kzen-auto-js | Order matters: seed *before* observe, otherwise the first batch of events could race with lazy id generation. |
| **D5** | Republish kzen-lib at the existing SNAPSHOT (no bump, CC-14). Republish kzen-auto. Verify cross-sibling builds. | kzen-lib + kzen-auto | Same publish dance as Moves B/C. |

## File-by-file disposition

### `ObjectStableMapper` (kzen-lib)

Add after the existing `objectLocation(...)` accessor:

```kotlin
fun snapshot(): Map<ObjectStableId, ObjectLocation> {
    return idToLocation.toMap()
}


fun seed(snapshot: Map<ObjectStableId, ObjectLocation>) {
    check(idToLocation.isEmpty() && locationToId.isEmpty()) {
        "Mapper must be empty before seed"
    }
    for ((id, location) in snapshot) {
        idToLocation[id] = location
        locationToId[location] = id
    }
}
```

Rationale for the `check`: seeding atop existing entries would silently drop conflicts. The only intended use site (client boot, before any other call) is naturally empty. Anyone seeding a non-empty mapper has a bug.

### `ObjectStableMapperTest` (kzen-lib)

Add one test:

```kotlin
@Test
fun `snapshot then seed in a fresh mapper restores the prior mapping`() {
    val source = ObjectStableMapper()
    val a = objectLocation("doc.yaml", "A")
    val b = objectLocation("doc.yaml", "B")
    val idA = source.objectStableId(a)
    val idB = source.objectStableId(b)

    val snapshot = source.snapshot()

    val seeded = ObjectStableMapper()
    seeded.seed(snapshot)

    assertEquals(idA, seeded.objectStableId(a))
    assertEquals(idB, seeded.objectStableId(b))
    assertEquals(a, seeded.objectLocation(idA))
    assertEquals(b, seeded.objectLocation(idB))
}
```

### `CommonRestApi` (kzen-auto-common)

Add a single constant near the existing namespaced routes:

```kotlin
// stable object id mapping
const val objectStableMapperSnapshot = "/object-stable/snapshot"
```

### `RestHandler` (kzen-auto-jvm)

New method delegating to `KzenAutoContext.global().objectStableMapper`. Returns `Map<String, String>` (Jackson serializes naturally):

```kotlin
fun objectStableMapperSnapshot(): Map<String, String> {
    val snapshot = KzenAutoContext.global().objectStableMapper.snapshot()
    return snapshot.entries.associate { (id, location) ->
        id.value to location.asString()
    }
}
```

Plumbing note: the handler's existing constructor doesn't take `KzenAutoContext` directly — services are passed individually. We could either (a) thread `objectStableMapper` into `RestHandler(...)` like other services, or (b) reach via `KzenAutoContext.global()` like `LogicTraceEndpoint`. Option (b) matches the post-Move-B pattern for new endpoints that need singletons; pick that.

### `KzenAutoMain` (kzen-auto-jvm)

Add a tiny new route group and mount it:

```kotlin
routeObjectStable(context.restHandler)
```

```kotlin
private fun Routing.routeObjectStable(
    restHandler: RestHandler
) {
    get(CommonRestApi.objectStableMapperSnapshot) {
        val response = restHandler.objectStableMapperSnapshot()
        call.respond(response)
    }
}
```

### `ClientRestApi` (kzen-auto-js)

```kotlin
suspend fun objectStableMapperSnapshot(): Map<ObjectStableId, ObjectLocation> {
    val responseJson = getOrPutJson(CommonRestApi.objectStableMapperSnapshot)
    val responseMap = ClientJsonUtils.toMap(responseJson)
    return responseMap.entries.associate { (idString, locationString) ->
        ObjectStableId(idString) to ObjectLocation.parse(locationString as String)
    }
}
```

### `ClientContext` (kzen-auto-js)

```kotlin
val objectStableMapper = ObjectStableMapper()

// in initAsync():
val snapshot = restClient.objectStableMapperSnapshot()
objectStableMapper.seed(snapshot)
mirroredGraphStore.observe(objectStableMapper)
```

Order matters: **seed first, observe second**. If we observed first, the mapper could lazily generate ids during the gap, polluting the seeded map with disagreeing entries.

## Verification

After each sub-tier:
- `cd ../kzen-lib && ./gradlew compileKotlinMetadata compileKotlinJvm compileKotlinJs` (or `:kzen-lib-common:test` after D1 to run the new test).
- After D1 publishes: `cd ../kzen-lib && ./gradlew publishToMavenLocal`.
- After D2/D3/D4: `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:build` and `:kzen-auto-js:compileKotlinJs`.

Final:
- `cd ../kzen-lib && ./gradlew :kzen-lib-common:test` (snapshot/seed round-trip + existing mapper canaries).
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest" --tests "*LogicTraceStoreRenameTest"` — Move-A regression guard.
- `cd ../kzen-auto && ./gradlew build`.
- Sanity: `kzen-project`, `kzen-launcher`, `kzen-shell` compile (none reference the new mapper, but rebuild to confirm transitive coords resolve).

Manual end-to-end (in IntelliJ standalone kzen-auto session):
1. `BackendDevelopment` + `FrontendDevelopment` start cleanly.
2. Open browser dev-tools network tab → reload the page; observe the `/object-stable/snapshot` GET in the boot sequence, returning a JSON map.
3. Rename a step on the client — observe that the client mapper applies the same rename the server's does. No user-visible behaviour change yet (no consumer uses the mapper); this is wiring verification only.

## Risks

- **Race window between snapshot and observe.** If a notation event lands on the server between the snapshot response and the client's `observe(...)` call, the client mapper misses it. In the current single-mutator client architecture this can't happen — the client *initiates* changes, so its event observer fires before the change reaches the server's snapshot. Becomes a real concern in a future multi-client world.
- **JSON envelope.** Both the snapshot endpoint and `ObjectStableMapper.snapshot()` materialise the whole map in one shot. With typical kzen-auto graphs (dozens to low-hundreds of objects), the payload is a few KB. If a future user has a pathological graph (10⁵ objects), the snapshot becomes large — still bounded, but worth knowing about. Streaming is a later optimisation if it ever matters.
- **`@Reflect` not involved.** Neither `ObjectStableMapper` nor `RestHandler` are reflection-registered, so the additions don't trigger KSP-generated registration. No `:kzen-auto-plugin:publishToMavenLocal` step needed beyond the usual publish flow.
- **Cross-sibling republish ordering.** Same as Moves B/C per umbrella AGENTS.md: kzen-lib → kzen-auto (with `:kzen-auto-plugin:publishToMavenLocal`) → kzen-project ‖ kzen-launcher → kzen-shell. Version pins stay at the existing SNAPSHOT (CC-14).

## Out-of-scope follow-ups

- `LogicTraceStore.objectLocationHistory` `ObjectStableId`-keying migration — still owed from Moves B/C; deferred.
- Server push (WebSocket / SSE) for multi-client support — future architectural change, not Move D's scope.
- Refactoring `ScriptStore.refreshProgressAsync` to rely on the new client mapper instead of re-fetching on rename — landed mapper is necessary precondition; actual refactor is a separate PR once we want to stop the re-fetch.
