# kzen-auto code review

## Context

The user wants a code review of `kzen-auto` — bugs, perf problems, architecture
smells, over-complication — with both low-hanging fruit (file-and-line specific)
and bigger refactor candidates worth considering later. Scope: everything under
`C:\Users\ostro\IdeaProjects\kzen-auto\` (jvm + js + common + plugin).
Out of scope: kzen-lib, kzen-launcher, kzen-shell.

Findings below were produced by three parallel Explore-agent passes and then
fact-checked against the actual source. Findings that didn't survive
verification are not included. Each item carries a file path and line number
so a follow-up implementation session can act without re-doing the audit.

Per the user's `feedback-todo-vs-uoe` memory: read-side TODO stubs are not
flagged. UOEs/TODOs are only flagged when they appear on a write-side or
production-reachable path. Per `feedback-fix-on-fix-audit`: surfacing all
credible findings here, not piecemeal across follow-up turns.

This plan is the deliverable. Execution = a follow-up session picks items off
the list, in priority order.

---

## Status

| Tier | Done | Outstanding |
|---|---|---|
| A (critical) | A1, A2, A3 (commit `d6c54139`, pre-audit) — A4, A5, A6 (execution session) | — |
| B (major) | B1, B2, B3, B4, B5 | B6, B7, B8 |
| C (nits) | — | C1–C15 |
| R (refactor) | R2 effectively done (commit `d6c54139` introduced single-threaded daemon executor + controller close()) | R1, R3, R4, R5, R6, R7, R8 |

Note: the audit was fact-checked against a snapshot that pre-dated `d6c54139`,
so A1/A2/A3 read as outstanding in the body below — see per-item status notes.

---

## A. Critical (correctness — fix before next release)

### A1. `ServerLogicController.step()` lacks `@Synchronized`

- **Status:** ✅ done in commit `d6c54139` (pre-audit). `step()` is now
  `@Synchronized` at line 337.
- **Where:** `kzen-auto-jvm/.../server/service/v1/impl/ServerLogicController.kt:325`
- **What:** Every other state-mutating override (`status`, `start`, `request`,
  `cancel`, `pause`, `continueOrStart`, even `clearState`) has `@Synchronized`.
  `step()` does not — it reads and mutates `state.stepping`, `state.paused`,
  `state.pauseRequested`, spawns a thread, and writes `state.stepping = false`
  from that thread.
- **Why it matters:** A concurrent `cancel()` or `continueOrStart()` raced
  against `step()` can leave the controller in an invalid state, miss the
  cancel signal, or violate the `check(...)` invariants that the rest of the
  state machine relies on.
- **Fix:** one-line — add `@Synchronized` above `override fun step(...)` at
  line 325. Verify the spawned-thread block (lines 354–371) still operates
  outside the monitor as the other overrides do.

### A2. Off-thread mutations of `LogicState` race with the synchronized methods

- **Status:** ✅ done in commit `d6c54139` (pre-audit). Post-execution
  mutations in both `continueOrStart` and `step` are now wrapped in
  `synchronized(this@ServerLogicController) { ... }` (lines 320, 378).
- **Where:** `ServerLogicController.kt:310,317,365` (writes from the spawned
  `Thread { ... }.start()` block).
- **What:** `continueOrStart` and `step` start a thread that writes
  `state.running = false`, `state.paused = true`, `state.stepping = false`
  *after* the synchronized method returns. These fields are `@Volatile`
  (visibility OK) but read/written non-atomically by other synchronized
  methods. Concrete race: `pause()` reads `! state.running` at line 261 then
  sets `state.paused = true` at line 262 — the spawned thread can finish
  between those two statements and flip both `running` and `paused`.
- **Why it matters:** Pause / step / cancel can act on a stale view of run
  state and either no-op silently or fail a `check(...)`.
- **Fix:** Wrap the post-execution state transitions in
  `synchronized(this@ServerLogicController) { ... }` inside the spawned
  thread, or — preferred — refactor to a bounded executor where the
  completion handler runs back inside the controller's monitor. See
  refactor candidate R2.

### A3. Bare `Thread { ... }.start()` for Logic execution

- **Status:** ✅ done in commit `d6c54139` (pre-audit). Replaced with a
  single-threaded named daemon `ExecutorService` (line 67), owned by the
  controller and shut down via `close()` (line 421), which is invoked from
  `KzenAutoContext.close()`. This is also the R2 refactor.
- **Where:** `ServerLogicController.kt:299–319` (continueOrStart) and
  `:354–371` (step).
- **What:** Each Logic run spawns a non-daemon `Thread` with no executor, no
  pool bound, no name, and no graceful-shutdown story. `KzenAutoContext.close()`
  does not wait for these threads.
- **Why it matters:** (a) No back-pressure on rapid submissions. (b) Non-
  daemon threads keep the JVM alive past the shutdown hook registered in
  `KzenAutoMain.kt:56`. (c) On shutdown, in-flight executions are abandoned
  mid-state without `frame.execution.close(...)`.
- **Fix:** Replace with a single-threaded named `ExecutorService` (matching
  the existing single-run invariant — `stateOrNull != null` already prevents
  concurrent runs) owned by the controller, shut down from
  `KzenAutoContext.close()`. Set threads daemon. See R2.

### A4. `System.gc()` after every Logic clear

- **Status:** ✅ done in this execution session. Line removed; comment removed.
- **Where:** `ServerLogicController.kt:401` in `clearState()`.
- **What:** Explicit `System.gc()` with comment "hit to GCs to give memory
  back to the OS" (`hit` likely meant `hint`). Triggers a full GC on every
  logic-run completion.
- **Why it matters:** Forces a stop-the-world pause on every run completion.
  Modern G1/ZGC return memory adaptively; the manual call is at best
  redundant and at worst a multi-hundred-millisecond pause spike. If the
  original motivation was a real leak, this is hiding it rather than fixing
  it (`LogicTraceStore.history` is a likely candidate — see B2).
- **Fix:** Delete the line. If memory-pressure issues recur, address the
  source.

### A5. `TODO("Multipart not implemented (yet)")` crashes a write path

- **Status:** ✅ done in this execution session. Multipart path now returns
  `HttpStatusCode.UnsupportedMediaType` with a descriptive message; the
  `@Suppress("KotlinConstantConditions")` workaround was removed along with
  the `var` declarations it was hiding.
- **Where:** `kzen-auto-jvm/.../server/KzenAutoMain.kt:401` in
  `routeDetached`'s PUT handler.
- **What:** Server throws `NotImplementedError` when a client sends a
  multipart PUT to `/actionDetached`.
- **Why it matters:** Reachable by any client; turns a feature gap into a
  server-side 500. The `@Suppress("KotlinConstantConditions")` two lines
  down hints at half-baked code. Per `feedback-todo-vs-uoe`: this is on a
  write/mutation path, so the TODO is in scope.
- **Fix:** Either implement, or
  `respond(HttpStatusCode.UnsupportedMediaType)` with a clear message.

### A6. `BadRequest` responses without a body

- **Status:** ✅ done in this execution session.
  - First pass (prior session): the two 400-status logic routes now use
    `call.respondText("Unable to start logic run", status =
    HttpStatusCode.BadRequest)`.
  - Second pass (this session): `taskQuery` and `taskCancel` now return
    `HttpStatusCode.NotFound` with a `"Task not found"` body when the task
    isn't found (was 204 NoContent, which read as success). Client side:
    added `HttpStatusException(status: Int)` in `ajaxUtil.kt` (replacing the
    untyped `RuntimeException("HTTP error: $status")` at all 5 throw sites),
    and `getOrPutJsonOrNull` in `ClientRestApi.kt` now catches
    `HttpStatusException` where `status == 404` and returns null —
    preserving the existing "null = no such task" contract for the two
    callers (`taskQuery`, `taskCancel`).
  - Note on `xhr.status`: kotlin-wrappers types it as `Short`, so the
    construction sites use `xhr.status.toInt()`.
- **Where:** `KzenAutoMain.kt:126–128` (`logicStartAndRun`) and `:135–137`
  (`logicStartAndStep`).
- **What:** When `logicStart(...)` returns null the handler calls
  `call.response.status(HttpStatusCode.BadRequest)` and *does not* call
  `respond` / `respondText`. Other null-result routes in the same file
  (e.g. `taskQuery` 174–179, `taskCancel` 183–188) use `NoContent` (204)
  with the same status-only pattern — semantically misleading for a failed
  operation.
- **Why it matters:** Client has no clue *why* a 400 came back; a `NoContent`
  on a failed cancel reads as success.
- **Fix:** `call.respond(HttpStatusCode.BadRequest, "<reason>")` and rethink
  the `taskQuery`/`taskCancel` 204s.

---

## B. Major (correctness, perf, or leaks)

### B1. `PluginReportDefinitionRepository.classLoaderHandle()` skips synchronization

- **Status:** ✅ done in this execution session. `@Synchronized` added at line 162.
  Audited the other `refreshCacheIfRequired()` callers — `contains`, `metadata`,
  `listMetadata`, `define` were already synchronized; all five public methods
  now consistently hold the monitor.
- **Where:** `kzen-auto-jvm/.../server/objects/plugin/PluginReportDefinitionRepository.kt:162`
- **What:** Public method `classLoaderHandle(...)` is **not** `@Synchronized`
  but calls `refreshCacheIfRequired()` (line 166), which mutates
  `metadataByDefinerCache` and `metadataByCoordinateCache`. The other public
  methods (`contains`, `metadata`, `listMetadata`, `define`) are all
  `@Synchronized`.
- **Why it matters:** Concurrent `classLoaderHandle()` + `contains()` can hit
  `ConcurrentModificationException` while iterating, or read a partially-
  rebuilt cache. Symptoms = intermittent plugin-resolution failures under
  load.
- **Fix:** Add `@Synchronized` to `classLoaderHandle` at line 162. Audit any
  other public method that calls `refreshCacheIfRequired` directly.

### B2. `LogicTraceStore.history` and `objectLocationHistory` grow unbounded

- **Status:** ✅ done in this execution session. Added
  `LogicTraceStore.evict(logicRunId)` that removes all `history` entries whose
  key has the matching `LogicRunId` (sub-executions each get a separate
  `LogicRunExecutionId`, so eviction must match on `logicRunId` not the
  composite id) and all `objectLocationHistory` entries whose value's runId
  matches. Wired from `ServerLogicController.clearState()` — so any logic-run
  terminal path (success, failure, cancel-while-paused, cancel-after-step)
  evicts the trace buffers. Trade-off: post-termination
  `mostRecent(location)` + `lookup(id, query)` now returns no data, which the
  audit accepted as the cost of fixing the leak; bigger picture in R5.
- **Where:** `kzen-auto-jvm/.../server/objects/logic/LogicTraceStore.kt:43–44`
- **What:** Process-singleton `ConcurrentHashMap`s. `getOrCreateBuffer`
  (line 76) inserts on every Logic run; nothing removes. Buffers themselves
  hold execution-value snapshots keyed by `LogicTracePath`.
- **Why it matters:** Long-running servers accumulate trace history
  indefinitely. The fact that `clearState()` in ServerLogicController calls
  `System.gc()` (see A4) suggests memory pressure was observed but not
  diagnosed. This store is a prime suspect.
- **Fix:** Add an eviction policy tied to terminal cleanup —
  `ServerLogicController.clearState` should evict the
  `LogicRunExecutionId` entry from both maps. Bigger picture in R5.

### B3. `async()` utility unsafely `!!`-asserts `exceptionOrNull()`

- **Status:** ✅ done in this execution session. Replaced
  `reject(result.exceptionOrNull()!!)` with
  `reject(result.exceptionOrNull() ?: RuntimeException("Unknown failure"))`.
  Left the author's `// TODO: what does this really do?` and the helper itself
  alone — the "consider replacing with `MainScope().promise { ... }`"
  suggestion is a larger change out of B3's scope.
- **Where:** `kzen-auto-js/.../client/util/ajaxUtil.kt:130`
- **What:**
  ```kotlin
  reject(result.exceptionOrNull()!!)
  ```
  Inside a `Result<T>` failure branch. Author left
  `// TODO: what does this really do?` at line 121.
- **Why it matters:** If a failure path somehow has a null exception, this
  NPEs on the rejection path — losing the original failure and surfacing an
  unrelated NPE in the promise chain.
- **Fix:** `reject(result.exceptionOrNull() ?: Exception("Unknown failure"))`.
  Consider replacing the helper with `MainScope().promise { ... }`.

### B4. Debounce timers not cancelled on component unmount

- **Status:** ✅ done in this execution session. Cross-checked all 8
  React components in `kzen-auto-js` that hold a `submitDebounce` field; none
  of them released their pending timer in `componentWillUnmount`. Plan-flagged
  trio (Formula, InputSelectedGroup, InputBrowserFilter) confirmed missing;
  5 additional sites surfaced and fixed under the same pattern:
  AttributePathValueEditor, AttributePathValueEditorOld, TextAttributeEditor,
  MultiTextAttributeEditor, TargetSpecEditor. The two with existing
  `componentWillUnmount` (AttributePathValueEditor, TargetSpecEditor) had a
  flush appended; the other 6 got a new
  `override fun componentWillUnmount() { submitDebounce.flush() }`.
  Correction note: the first pass used `submitDebounce.cancel()`, which
  *discards* the user's pending edit. User pointed this out — the debounce
  buffers a server-bound modification, so the correct policy is
  `.flush()` (synchronously invokes the pending lambda, which itself
  launches the submit coroutine; the coroutine completes independently of
  the unmount). Non-component `*Debounce` holders (`ClientLogicGlobal`,
  `ReportStore`) are services / long-lived stores, not React components —
  they manage their own lifecycle and were not touched.
- **Where:** Confirmed in
  `kzen-auto-js/.../client/objects/document/report/formula/FormulaItemController.kt:58`
  (declares `submitDebounce`; no `componentWillUnmount`). Agent flagged
  `InputBrowserFilterController.kt` and `InputSelectedGroupController.kt`
  with the same shape; both need a final cross-check.
- **What:** lodash `debounce` returns a function whose pending timer keeps
  the closure alive. When a component unmounts before the timer fires, the
  callback runs against a destroyed instance — `setState` no-op + warning,
  or `props.*` access errors.
- **Why it matters:** Memory leak per unmount; user-visible errors in the
  browser console after rapid edit-then-navigate-away.
- **Fix:** Each component with a `*Debounce` field gets
  `override fun componentWillUnmount() { submitDebounce.cancel() }`. See R6
  for a reusable wrapper.

### B5. Observer-callback errors swallowed via `printStackTrace`

- **Status:** ✅ done. Kept the `printStackTrace()` (still useful for the
  console + sourcemap), and added a crude `window.alert(...)` after it so
  the error is no longer silent. Deliberately did NOT build a centralized
  error sink / banner — per-user direction this is a stopgap until R3/R4
  arrive. Site: `ClientStateGlobal.kt:191` (observer-dispatch loop).
- **Where:** `kzen-auto-js/.../client/service/global/ClientStateGlobal.kt`
  (agent cited ~lines 190–198 — observer-dispatch loop).
- **What:** Per-observer try/catch wraps each `observer.onClientState(...)`
  call and calls `e.printStackTrace()`. The loop continues, swallowing the
  error to the console.
- **Why it matters:** A bug in one observer leaves the UI in a partly-
  updated state with no UI signal. Easy to miss during dev.
- **Fix (low-hang):** Replace `printStackTrace()` with a centralized error
  sink that can surface a banner. Big picture in R3/R4.

### B6. Logic command path swallows exceptions

- **Where:** `RestHandler.applyCommand` — agent flagged ~lines 757–759.
  Cross-check against the current `RestHandler.kt` before editing; the
  shape to look for: a catch-all `catch (e: Exception) { e.printStackTrace();
  ... }` followed by a digest return that looks like success.
- **What:** A command that fails (validation, definition error) is
  swallowed; the client sees a 200 + (likely stale) digest.
- **Why it matters:** Silent state divergence between client and server —
  the kind of bug that surfaces hours later as "saving doesn't work".
- **Fix:** Surface the failure as a typed error response. See R4.

### B7. `Thread.currentThread().interrupt()` of unclear intent

- **Where:** `kzen-auto-jvm/.../server/service/exec/ModelTaskRepository.kt`
  (agent cited line 337 — verify against current file).
- **What:** `terminate()` calls `completeLatch.countDown()` then
  `Thread.currentThread().interrupt()`. The "current thread" here is the
  caller's thread, not the running task — interrupting it is either dead
  code or a misunderstanding of `Thread.interrupt`.
- **Why it matters:** If `terminate()` is called from a Ktor request
  handler, the request thread is interrupted, propagating an unexpected
  `InterruptedException` back into Ktor. If from an executor thread,
  similar story.
- **Fix:** Inspect call sites; the interrupt is either redundant
  (already-counted latch) or pointed at the wrong thread.

### B8. `mutableSetOf<Observer>()` in `VisualDataflowRepository` is not safe under coroutine cancellation

- **Where:** `kzen-auto-common/.../paradigm/dataflow/service/visual/VisualDataflowRepository.kt:30`
- **What:** Observers are added/removed from a `mutableSetOf<Observer>()`
  in `observe`/`unobserve` (both suspend). The `for (observer in observers)`
  loops in `publishModel` / `publishBeforeExecution` iterate the same set,
  and each iteration suspends on observer callbacks.
- **Why it matters:** If `unobserve` runs while a publish loop iterates,
  the iteration can `ConcurrentModificationException` even in single-
  threaded coroutine dispatch — because the loop suspends mid-iteration
  and a different coroutine wins.
- **Fix:** Iterate over a snapshot (`observers.toList()`) in the publish
  helpers, or switch to a `CopyOnWriteArraySet` (matches the
  `CopyOnWriteArrayList` already used elsewhere in the package).

---

## C. Minor / nits (file-and-line specific)

| # | Where | What |
|---|---|---|
| C1 | `KzenAutoMain.kt:429–456` | Entire `routeScript` function (50 lines) commented out — dead since the call site at line 112 is also commented out. Delete. |
| C2 | `kzen-auto-common/.../api/CommonRestApi.kt:28` | `commandAttributeClear` commented out with no `@Deprecated` tombstone. Either restore with `@Deprecated` or audit references and remove. |
| C3 | `VisualDataflowRepository.kt:134–138` | Dead branch — `if (event.documentPath == documentPath)` is always true because the function returned at line 113 if they didn't match. Collapse. |
| C4 | `VisualDataflowRepository.kt:225–246` | `execute()` accepts `waitBeforeRunningMillis` / `waitAfterRunningMillis` — test concerns leaking into production API. Move delays to a test wrapper. |
| C5 | `VisualVertexTransition.kt` | Field named `iteration`, serialized under key `epochKey` (lines ~23 vs ~13). Rename one for consistency — the mismatch is a footgun if anyone hand-edits the JSON. |
| C6 | `HeaderListing.kt:117–129` | `data class` with custom `equals` / `hashCode` keyed off a lazily-cached digest. Safe today (`values` is `val`, digest is deterministic), but the combination is surprising. Add a one-line comment, or drop the `data class` qualifier. |
| C7 | `kzen-auto-js/.../objects/document/graph/edit/*Old.kt` (5 files) | Agent found 5 `*Old.kt` siblings still referenced from `GraphController.kt:18`. Verify dead-vs-active and either delete or document why both live in tree. |
| C8 | `kzen-auto-js/.../objects/document/common/edit/TextAttributeEditor.kt:7–15` and `MultiTextAttributeEditor.kt:7–15` | Five duplicate `import tech.kzen.auto.client.wrap.setState` lines each — leftover of the 2026.5.3 migration mass-add. Dedup. |
| C9 | `ClientStateGlobal.kt:59–77, 82–104, 117–135` | Three large commented-out blocks. Either restore with a tracking TODO or delete and rely on git history. |
| C10 | `kzen-auto-js/.../client/util/ajaxUtil.kt:107` | `// console.log("^^^ httpGet - xhr.response", xhr.response)` left in. Strip. |
| C11 | `kzen-auto-plugin/.../model/DataInputEvent.kt:6–9` and `ModelOutputEvent.kt:6–18` | SPI abstract classes expose `var` fields publicly. Encapsulating with controlled setters is a breaking change but worth scheduling — these are the contract surface downstream plugins see. |
| C12 | `kzen-auto-plugin/.../helper/ListPipelineOutput.kt:12–13` | Mutable buffer + `nextIndex` without documented thread-safety. SPI helpers should be explicitly annotated `@ThreadSafe` / `@NotThreadSafe`. |
| C13 | `PluginCoordinate.kt` (plugin SPI) vs `CommonPluginCoordinate.kt` (common) | Two near-identical coordinate classes with no conversion utilities. Consolidate or document the split. |
| C14 | `kzen-auto-common/.../paradigm/dataflow/util/DataflowUtils.kt:42–235` | 195-line `next()` mixing graph traversal and dataflow state-transition logic, plus 6 commented debug lines. Extract layer-classification into a testable pure function. Maintainability time-bomb. |
| C15 | `ModelTaskRepository.kt` (~line 350) | `awaitTerminal()` catches `InterruptedException` and silently discards. Either re-interrupt at the end of `catch` so callers see the signal, or document the swallow. |

---

## D. Bigger refactor candidates

Each item below is motivated by an observed smell, not a single bug. None is
urgent; each unlocks compounding wins.

### R1. Make `RestHandler` suspend-native; eliminate `runBlocking`

- **Smell:** `RestHandler` methods (and helpers like
  `ServerLogicController.graphDefinitionAttempt` line 385,
  `PluginReportDefinitionRepository.classLoaderHandle` line 179, etc.) use
  `runBlocking { graphStore.graphDefinition() }` to bridge from a
  non-suspend context.
- **Cost of inaction:** Each Ktor handler blocks a Netty event-loop thread
  for the duration of the request rather than suspending. Throughput is
  capped at the event-loop pool size.
- **Refactor:** Make `RestHandler` methods `suspend`; plumb suspension
  through `KzenAutoMain.routeRequests`. Where a non-suspend caller
  legitimately needs a blocking bridge (e.g. JVM SPI), isolate the
  `runBlocking` to one place.

### R2. Replace bare `Thread {}` in `ServerLogicController` with a managed executor

- **Status:** ✅ done in commit `d6c54139` (pre-audit). See A1/A2/A3 status.
- **Smell:** A1/A2/A3 together — spawned threads with no lifecycle, races
  against the synchronized state, no shutdown hook.
- **Refactor:** A single-threaded named daemon `ExecutorService` owned by
  the controller; completion callback re-enters the controller's monitor
  (eliminates A2); `KzenAutoContext.close()` calls `shutdown` +
  `awaitTermination` (closes the A3 hole). Bonus: drops the `System.gc()`
  rationale.

### R3. Scoped observer lifecycle for JS components

- **Smell:** B4 (debounce leaks) and the broader pattern in `kzen-auto-js`
  — every component manually `observe()`s in `componentDidMount` and
  `unobserve()`s in `componentWillUnmount`. Forgetting either is a memory
  leak; the codebase has 100+ such pairs and at least 3 known omissions.
- **Refactor:** A small `ObserverLifecycle` helper (member of
  `RPureComponent` or composed-in) that registers cleanup actions and
  fires them all in `componentWillUnmount`. Reduces boilerplate; makes
  cleanup mandatory.

### R4. Typed REST response envelope (Success | Failure | Validation)

- **Smell:** A6 (status-without-body), B6 (silent command failures),
  inconsistent 204 vs 400 vs 200-with-empty-string across the same file.
- **Refactor:** Introduce a `sealed class RestResponse<T>` with `Success`,
  `Validation`, `Failure` variants and a Ktor extension that maps each to
  the right status code + body. Forces handlers to handle the failure
  case rather than swallowing.

### R5. Eviction policy for Logic trace history

- **Smell:** B2 (unbounded `LogicTraceStore` history). Compounds with A4
  (System.gc as workaround).
- **Refactor:** Bound the `history` and `objectLocationHistory` maps —
  either by capping size (e.g. last N runs) or by tying buffer lifetime to
  `ServerLogicController.clearState`'s terminal callback. Also worth
  considering whether `LogicTraceStore` needs to be an `object` singleton
  at all (it's the only piece of process-wide state that doesn't live
  inside `KzenAutoContext`).

### R6. Reusable debounce-with-lifecycle wrapper

- **Smell:** B4 plus C8 (the migration left scattered manual
  `submitDebounce` fields). Each component re-implements the same
  declare-field-then-(maybe)-cancel pattern.
- **Refactor:** A `DebouncedAction(this, intervalMs, callback)` helper that
  auto-cancels via R3's observer-lifecycle hook. Eliminates the entire
  class of bug surfaced in B4.

### R7. Consolidate paradigm serialization

- **Smell:** Common-module agent found 5 paradigms (task, logic, dataflow,
  detached, reactive) each re-implementing `toCollection` / `fromCollection`
  with subtly different patterns (`!!`-asserts, manual `"null"` string
  checks, silent `?.let {}` defaults).
- **Refactor:** Extract a `Marshallable<T>` interface; apply to all paradigm
  model classes. Reduces drift; one bug = one fix instead of five.

### R8. Sealed-class state hierarchies replace enum-plus-nullable-wrapper

- **Smell:** Each paradigm has `XxxState` (enum) + `XxxModel` (data class
  wrapping the enum + a nullable info field). Sealed-class hierarchies
  encode the same domain with exhaustiveness checking and no nullable
  optionals.
- **Refactor:** Convert `TaskState` + `TaskModel`, `LogicRunState` +
  `LogicStatus`, etc. to `sealed class TaskState { object Idle : ...;
  data class Running(val info: ...) : ... }`. Larger change — downstream
  callers shift from null-checks to `when` clauses.

---

## Files this plan references

JVM:
- `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/v1/impl/ServerLogicController.kt`
- `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/logic/LogicTraceStore.kt`
- `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/plugin/PluginReportDefinitionRepository.kt`
- `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/KzenAutoMain.kt`
- `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/api/RestHandler.kt`
- `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/exec/ModelTaskRepository.kt`
- `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/context/KzenAutoContext.kt`

JS:
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/util/ajaxUtil.kt`
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/global/ClientStateGlobal.kt`
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/report/formula/FormulaItemController.kt`
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/report/input/browse/InputBrowserFilterController.kt`
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/report/input/select/InputSelectedGroupController.kt`
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/common/edit/TextAttributeEditor.kt`
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/common/edit/MultiTextAttributeEditor.kt`
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/graph/edit/*Old.kt`

Common / plugin:
- `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/api/CommonRestApi.kt`
- `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/dataflow/service/visual/VisualDataflowRepository.kt`
- `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/dataflow/util/DataflowUtils.kt`
- `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/dataflow/model/exec/VisualVertexTransition.kt`
- `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/report/listing/HeaderListing.kt`
- `kzen-auto-plugin/src/main/kotlin/tech/kzen/auto/plugin/model/DataInputEvent.kt`
- `kzen-auto-plugin/src/main/kotlin/tech/kzen/auto/plugin/model/ModelOutputEvent.kt`
- `kzen-auto-plugin/src/main/kotlin/tech/kzen/auto/plugin/helper/ListPipelineOutput.kt`
- `kzen-auto-plugin/src/main/kotlin/tech/kzen/auto/plugin/model/PluginCoordinate.kt`

---

## Verification

A code review doesn't get a build-green check; verification is per-fix.
Recommended cadence when picking items off the list:

1. **For each A-tier fix:** add or extend a test that would have caught the
   bug (race tests via concurrent submissions for A1/A2/A3; a PUT to
   `/actionDetached` with a multipart body for A5; etc.). Then
   `cd ../kzen-auto && ./gradlew test`.
2. **For each B-tier fix:** smoke-test the affected paradigm in dev-mode
   (`BackendDevelopment` + `FrontendDevelopment` per umbrella AGENTS.md),
   since most B-tier items are UX-visible.
3. **For each refactor (R-tier):** land behind a feature flag or in a
   contained slice first (e.g. R1 — start by making one route group
   suspend-native, not all six in one PR).

Re-verify any file-and-line citation before editing — line numbers drift
fast; the *file* + *symbol* combination is more durable.

---

## What's not in this plan

- Style nits (val-vs-var preferences, formatting).
- `TODO` comments on read-only paths (per `feedback-todo-vs-uoe`).
- Anything in `kzen-lib`, `kzen-launcher`, `kzen-shell`, `kzen-project`,
  `kzen-sample-plugin` — out of scope.
- Anything in the kzen-auto build files (`build.gradle.kts`, `buildSrc/`).
  Build/toolchain concerns are documented in umbrella AGENTS.md.
