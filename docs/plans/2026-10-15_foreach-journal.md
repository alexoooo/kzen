# ForEach journal — constituent plan (FJ)

> **Status: planned 2026-10-15, not started.** Written with the user after scrub-audit step 2 (removing the
> invented limits, `docs/audit/2026-10-14_scrub_5.5-unreported.md` §9). That step left the ForEach journal's
> 100-entry limit in place, because removing it alone makes a long loop quadratic. The user asked for both:
> "efficient (avoid the N^2) and also allow the user to see everything". They chose the storage: a persistent
> list held by `RunEngine`.
>
> The [master ledger](2026-07-25_master-plan.md) owns sequencing (rows FJ1–FJ3). Each landed row appends its
> as-built under §7.

## 1. Problem

A ForEach card has an iteration counter that opens the journal: one `item → value` row per completed iteration
(`ForEachProgressButton`). The journal travels inside the loop's trace detail, `ForEachProgress.produced`.

1. **It is capped.** `ForEachProgress.maxProducedEntries = 100`. A user cannot see iteration 101 of a loop that
   is still in its first second, nor anything before the last 100 once it has finished. The popover says
   "… N earlier omitted".
2. **Without the cap it is quadratic, twice over.**
   - *Server:* every iteration copies the whole journal into a new detail (`ForEachStep.traceProgress`,
     `journal.toList()`). Iteration *i* costs *O(i)*.
   - *Transport:* about once a second, and on every structure change, the client re-fetches the run's whole
     live trace map (`ScriptProgressStore.refresh` → `lookup` / `lookup-run`; there is no delta). Each fetch
     would carry the whole journal, and so would every re-parse and re-render of the card.
3. **The client cannot show a long list.** The popover renders every entry into a 24em scrolling `div`. There is
   no windowed rendering anywhere in kzen-auto-js.

## 2. Goal

- Every iteration costs the same, however many came before.
- A trace refresh costs the same per loop, however long the journal is.
- The user can see every entry, while the loop runs, while it is paused, and after the run has finished, for as
  long as the run's trace is kept today (until the next run or *Clear all*).
- No cap of any kind. Memory is one `{item, value}` text pair per iteration, kept for the run: the price of
  seeing everything, and the Script author's call like any other resource use.

## 3. Design

### 3.1 Engine: lists beside live values (kzen-lib)

`RunEngine` keeps each node's live trace in mutable `LinkedHashMap`s under one lock, and `snapshot()` rebuilds an
immutable `RunState` by copying each node's map (`buildNode`). A list stored as a value would be copied by
reference, so the snapshot would share a list that is still growing.

**The list is a `PersistentList<ExecutionValue>`** (`tech.kzen.lib.platform.collect.PersistentList`; on the JVM a
dexx `Vector`, a 32-way trie). Adding is effectively constant time, and every version is immutable and shares
structure with the last. The owner keeps the list and emits each new version:

```kotlin
// Execution (kzen-lib-common exec/engine)
fun emitList(address: Address, entries: PersistentList<ExecutionValue>)
```

- `NodeRuntime` gains `lists: LinkedHashMap<Address, PersistentList<ExecutionValue>>` and `listSequence`, parallel
  to `live` / `liveSequence`. `emitList` replaces the entry under the lock, bumps `sequence` and marks dirty. It
  never writes history: like `emit(retain = false)`, it is live state only.
- Lists are a separate map, not values in `live`. An address can hold a value and a list, so a step's one trace
  address names both, and trace projection never ships a list by accident.
- `Node` gains `lists` and `listSequence`. `buildNode` copies the map (a reference per list, not the entries),
  so a snapshot costs the same however long its lists are and is still immutable.
- **Lifetime is the live map's, with no new rules:**
  - `resetEmitted` removes lists at the given addresses too, so an inner loop's journal resets with its trace
    at each outer iteration, as today;
  - `migrate` starts the new root with no lists, as it does with live values;
  - dispose drops them.
- Why the owner holds the list rather than the engine offering `append`: the list is an immutable value, so it
  rides a migration carry and a move-to partial commit as-is, and a resumed owner re-emits it. An engine-side
  `append` would need a separate restore call for each of those.

### 3.2 Reading a range (kzen-lib `LogicTrace`, kzen-auto `RunEngineLogicTrace`, `LogicTraceEndpoint`)

```kotlin
// LogicTrace
fun lookupRange(
    logicRunId: LogicRunId,
    executionId: LogicExecutionId?,
    path: LogicTracePath,
    offset: Int,
    count: Int?
): LogicTraceRange?

// kzen-lib-common exec/logic/trace/model
data class LogicTraceRange(val size: Int, val offset: Int, val entries: List<ExecutionValue>)
```

- **`RunEngineLogicTrace.lookupRange`** reads `engine.snapshot()` with no lock, so the list it reads cannot
  change under it:
  - With an `executionId`, it reads that node, as `lookup` does.
  - Without one, it reads the highest-ordinal node holding that path, the rule `lookupRun` already uses to merge
    a run's frames.
  - The path is matched through the existing `tracePathOf`.
  - `count = null` means to the end. The server has no default and no maximum; the client asks for what it
    shows.
- **The new action `lookup-range`** on `LogicTraceEndpoint` (`LogicConventions.actionLookupRange`, params
  `offset`, `count`) goes through the same retained-engine access as the other lookups. So it works while
  running, while paused and after the run has settled.
  - `/logic/request` cannot be used here, because it refuses a settled run.
- `lookup` / `lookup-run` do not project lists. Their size travels in the owner's own detail (§3.3).

### 3.3 Script and ForEach (kzen-auto-jvm, -common)

- **`StepExecution.traceList(entries)`**, beside `traceDetail`. `ScriptRunContext` keeps it as `currentList`
  and emits it at the running step's trace address. The list stays in the engine's map, so `markDone` has
  nothing to re-emit.
- **`ForEachStep`:**
  - `journal` becomes a `PersistentList<ExecutionValue>` of `{item, value}` maps, extended at exactly the point a
    value is collected, so the committed list and the journal stay aligned index-for-index.
  - The bounded `append` and `ArrayDeque` go.
  - `traceProgress` emits the constant-size detail and then `traceList(journal)`. Both are constant-cost.
  - `LoopCursor.producedEntries` becomes the persistent list. A carry costs a reference and a restore a
    reference: today it costs an `ArrayDeque` copy.
  - `producedCount` is the list's size and stops being tracked separately.
- **`ForEachProgress`** keeps `item`, `index`, `size`, `producedCount` and `partial`. `produced`,
  `maxProducedEntries`, `omittedCount` and the "BOUNDED" KDoc go. `Entry` and `entryOf` stay, with the
  conversion to and from the wire map, because the client reads entries out of a range.
- **Move-to partial commit:** `PartialOutcome` gains `list: PersistentList<ExecutionValue>?`. `ScriptReplayState`
  keeps it beside the partial detail, and `adoptOutcome` re-emits both, so a skipped loop still shows its whole
  journal.
- **Nested loops:** no change. `dropReplay` → `resetEmitted` clears the inner loop's list with its trace.

### 3.4 Client: a windowed journal (kzen-auto-js)

- **Library:** TanStack Virtual, which kotlin-wrappers ships at the pinned catalog. Use
  `kotlin-tanstack-virtual-core` (`tanstack-virtualCore`, `2026.7.1-3.17.3`).
  - Use its `Virtualizer` class from the existing class component. The React adapter's `useVirtualizer` is a
    hook and would need the app's first function component.
  - **Rows keep their wrapping.** The virtualizer measures each rendered row (`measureElement`), so rows need not
    be cut to one line.
- **`ForEachProgressButton`:**
  - The popover's scroll box (24em) becomes the virtualizer's scroll element. Only the rows in view, plus the
    library's overscan, are in the DOM.
  - The counter and "Values produced N" read `producedCount`.
- **Fetching:**
  - The component holds one window of entries: the rows in view plus overscan, with their offset.
  - When the visible range leaves the held window, it fetches `lookup-range` for the new range (one request in
    flight; a newer range supersedes an older one).
  - On open it scrolls to the end.
  - While the view is at the end and `producedCount` grows, it fetches only `[held end, producedCount)` and
    stays at the end ("follows the tail").
  - Scrolling up stops following; scrolling back to the end resumes it.
- **Which run:** the popover is given the `runId` and the `executionId` of the trace it is showing.
  `ScriptProgressStore` already knows which one it used: `lookup` with the live document's execution, or
  `lookup-run` merged. `executionId` is passed only in the first case.
- `ClientRestApi` gains the `lookup-range` call over `performDetached`, like the other trace actions.

## 4. Cost after the change

| | Before | After |
|---|---|---|
| One iteration (server) | *O(min(i, 100))* copy | Effectively constant (persistent add + two emits) |
| One snapshot rebuild | Copies the 100-entry journal | Copies a reference |
| One trace refresh (wire) | Up to 100 entries per loop | Constant per loop |
| Opening / scrolling the journal | Nothing (already shipped) | One `lookup-range` for the rows in view |
| Memory | 100 entries per loop | Every entry, for the run's trace lifetime |

## 5. Out of scope

- **A finished loop's detail after a live edit.** `migrate` rebuilds the live map, and `adoptOutcome` re-emits a
  completed step's Done trace without its detail (only a move-to partial keeps one). So a loop that had finished
  shows no progress after an edit, and under this plan it will show no journal either. This is unchanged
  existing behaviour; a fix would keep each completed step's detail and list in its replay outcome.
- **The whole-map trace refresh.** The client still re-fetches every live address about once a second. With the
  journal out of it, that costs *O(steps)*, not *O(iterations)*.
- **Other trace consumers.** `emitList` is general, but only ForEach uses it. No other flavour is converted.

## 6. Rows and verification

**FJ1 — engine lists and range read (kzen-lib).**
- Work: `Execution.emitList`; `NodeRuntime` / `Node` lists; `resetEmitted`, `migrate` and dispose;
  `LogicTrace.lookupRange` and `LogicTraceRange` (with its `ExecutionValue` codec).
- Tests (`RunEngine`):
  - a snapshot shares the list it read, unchanged by later emits;
  - `resetEmitted` and `migrate` drop lists;
  - `listSequence` orders a merge;
  - no history event is written.
- Build: `./gradlew build publishToMavenLocal` in kzen-lib.

**FJ2 — Script and ForEach, server (kzen-auto-jvm, -common).**
- Work: `StepExecution.traceList`; `ForEachStep` / `ForEachProgress` / `LoopCursor` / `PartialOutcome`;
  `RunEngineLogicTrace.lookupRange`; `lookup-range` on `LogicTraceEndpoint`.
- Tests:
  - `ScriptTraceBoundingTest`'s journal-cap tests become: a 10,000-iteration loop's journal holds all 10,000
    entries in order, and the detail it emits is the same size at iteration 10 and at iteration 10,000;
  - `lookup-range` mid-run, while paused at a breakpoint, and after the run settled;
  - with and without `executionId` (a ForEach inside a RunStep sub-script);
  - an inner loop's journal resets at each outer iteration (`ServerLogicControllerLoopTraceResetTest`);
  - a live-edit resume keeps the journal and keeps appending;
  - a move-to partial commit keeps a journal aligned with the committed value (`ScriptMoveToTest`).

**FJ3 — windowed journal (kzen-auto-js) and docs.**
- Work: the `tanstack-virtualCore` dependency; `ForEachProgressButton`'s virtualized list and range fetching;
  `ClientRestApi`; `ScriptProgressStore` passing `runId` / `executionId`.
- Browser, on a scratch project at port 8099 (never 8080 / 18081): a 200,000-iteration loop.
  - Open the journal while running: it follows the tail.
  - Scroll to the middle: rows fill in, and the tail stops following.
  - Pause: the journal is still readable.
  - After the run: scroll from the first entry to the last.
  - A wrapped long value measures correctly.
  - Network: one range request per scroll stop, and trace refreshes the same size throughout.
- Docs:
  - kzen-lib `docs/logic-spec.md` §7 (lists beside live values) and `docs/architecture.md`;
  - kzen-auto `docs/architecture.md` (the S7 paragraph on the journal) and `docs/js-architecture.md` (the
    virtualizer);
  - the audit doc §3 row, which is resolved by this plan.
- Build: full `./gradlew build` in kzen-auto.

## 7. As-built

### FJ1 — engine lists and range read (kzen-lib), 2026-10-15

- `Execution.emitList(address, PersistentList<ExecutionValue>)`; `RunEngine` keeps `NodeRuntime.lists` and
  `listSequence` under the engine lock (each emit takes the next sequence and publishes), copies both into
  `Node.lists` / `Node.listSequence` in `buildNode`, and drops them in `resetEmitted` and `clearLiveSubtree`.
  `migrate` builds the new root without them. Never history.
- `LogicTraceRange(size, offset, entries)` (`asExecutionValue` / `ofExecutionValue`, counts as
  `LongExecutionValue`) and `LogicTrace.lookupRange(runId, executionId?, path, offset, count?)`.
- Tests: `RunEngineTraceTest.aSnapshotKeepsTheListVersionItSaw`, `resetEmittedClearsLists`;
  `RunEngineMigrationTest.migrateStartsTheRebuiltRootWithNoLists`; `LogicTraceRangeTest` (JVM and JS).
  `build publishToMavenLocal` green.

### FJ2 — ForEach journal, server (kzen-auto), 2026-10-15

- `ForEachProgress` is `item, index, size, producedCount, partial`; `produced`, `maxProducedEntries` and
  `omittedCount` are gone. `Entry.asExecutionValue` / `entryOfExecutionValueOrNull` are the list's entry form.
- `StepExecution.traceList`; `ScriptRunContext.traceList` emits at the current step's stable-id address.
  **Deviation:** no `currentList` on `ScriptRunContext` — the list lives in the engine, so nothing there needs
  to re-emit it when the step is done. `adoptOutcome` re-emits `ScriptReplayState.partialListOrNull`, set from
  the new `PartialOutcome.list`.
- `ForEachStep`: `journal` is a `PersistentList`, one entry per completed iteration, carried by `LoopCursor`
  and `PartialOutcome`; `traceProgress` emits the detail (with `journal.size`) and then the list.
- `LogicConventions.actionLookupRange = "lookup-range"` with `paramPath = "trace-path"`, `paramOffset`,
  `paramCount`; `LogicTraceEndpoint` serves it. **Correction found in the browser:** the plan's parameter
  name `path` collides with the detached request's own document `path` (`CommonRestApi.paramDocumentPath`),
  and the server refused every request; the JVM tests call `lookupRange` directly and could not see it.
- `RunEngineLogicTrace.lookupRange` reads one snapshot: the named execution's node, or the run's latest nodes
  (the new `latestNodes`, shared with `lookupRun`), the highest `listSequence` at the path winning; the range
  is clamped, and entries go through `toWireValue`.
- Tests: `ScriptTraceBoundingTest.aLongLoopJournalsEveryIterationBesideAFixedSizeDetail` (10,000 entries,
  detail holds no list), `unreferencedLoopStillJournalsItsValues`; `ScriptMoveToTest` (the committed partial
  value's journal); `ServerLogicControllerLoopMigrationTest` (journal while paused, across a live edit, after
  the run); new `ForEachJournalTest` (nested reset keeps the last outer pass only; a sub-Script loop read with
  and without its execution, and not from the host's; a middle range and a range past the end) with fixtures
  `script-loop-journal-test.yaml` / `script-loop-journal-child-test.yaml`.

### FJ3 — windowed journal, client (kzen-auto-js), 2026-10-15

- `kotlinWrappers.tanstack.virtualCore` added to kzen-auto-js; `kotlin-js-store/yarn.lock` gains
  `@tanstack/virtual-core` (resolved 3.19.5 from the wrapper's `^3.17.3`).
- New `ForEachJournal` (the virtualized list) in the popover of `ForEachProgressButton`, which keeps the counter
  and the "Values produced N" header. New `TraceListRef(runId, executionId?, path)`, built by
  `ForEachStepDisplay` from `ScriptProgressState.traceExecutionId` (new: the live frame's execution, null for
  the run merge) and passed through `forEachItemRow`. `ScriptProgressStore.lookupRange` makes the call
  (the store already holds the other trace queries, so not `ClientRestApi`).
- **Deviation — reads.** Rather than fetching `[held end, producedCount)` while following, the window is
  re-read whenever the rows in view leave it, and with every new trace snapshot while open: a list can change
  in place (an inner loop's journal resets each outer pass and can refill to the same length between two
  refreshes), so appending to a held window could show a stale pass. A read is a viewport and a page either
  side; one at a time, the latest wanted next, none while scrolling. Measured: about two reads per refresh
  while following, one per scroll stop after the run.
- **Deviation — following.** Not TanStack's `followOnAppend`: it acts only with `anchorTo = end`, which undid
  the opening scroll, and it needs the view within 1 px of the end, which measuring the newest (wrapped) rows
  breaks on every tick. The journal follows while the last row is among those rendered, and scrolls to the end
  when the count grows.
- A failed read is shown above the rows until a read succeeds, whether the server refused it ("No traced
  list at …", e.g. the run is gone) or there was no answer; the queued next read still runs. Before, a refusal
  was dropped without a trace and a failed request skipped the queued read. Browser-checked both by stopping
  and restarting the scratch server under an open popover.
- The item column keeps its width (up to 40%) beside a long value; before, a long value squeezed it to a
  character per line.
- Browser, scratch project on 8099, 200,000-iteration loop with a 150-character value every 7th iteration:
  follows the tail from open to finish; paused, readable at the end; after the run, the middle and the first
  entry each fill in after one read; wrapped rows measured.
- Docs: kzen-lib `architecture.md` (write modes) and `logic-spec.md` §7; kzen-auto `architecture.md` § 3 and
  `js-architecture.md` (ForEach journal); scrub audit §3.
