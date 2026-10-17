# Resource holds — one disposal mechanism (RH)

> **Status: landed 2026-10-16 (RH1–RH5; as-built in §8, deviations marked there).** Follows the problem definition in
> `docs/analysis/2026-10-14_resource-policy.md` (requirements R1–R10 are cited from there). The user chose
> option A of the options presented on 2026-10-16: *one hold-counted resource entry in the engine; frames are
> holders*. Facts about the code were checked on 2026-10-16.
>
> The [master ledger](2026-07-25_master-plan.md) owns sequencing (rows RH1–RH5). Each landed row appends its
> as-built under §8.

## 1. Problem

Two mechanisms release resources today, and they answer different questions.

- **Engine scoped disposal** (kzen-lib `Execution.bind` / `onSettle` / `resource`, `RunEngine.settleFrame`)
  answers *which frame owns this, and what happens when it settles.* One owner, chosen by the export chain;
  lifetime is a region of the execution tree. Right for a browser or a process.
- **Job ledger** (kzen-auto `RunOwnershipLedger`, `OwnedNative`, `ValueLease`) answers *who is still using
  this value, and when does the last one let go.* Many concurrent holders, counted; the last release closes.
  Required for streamed items under a host memory budget (R6): no single frame is the right owner of an item
  that several concurrent Workers touch.

A scope-only model cannot express the second case without keeping every item until a Worker or the run ends.
A hold-count model can express the first: a frame's binding is one holder among others, released at settle.
That asymmetry decides the design.

**Consequences in the code today:**

1. **A Job closes its result before the caller receives it** (R7). Every ledger holder is internal to the run
   (channel slot, callback, `retain`); when the Workers join, the count is zero and `JobRun`'s `finally` closes
   everything (`JobRun.kt:296-298`). The caller was never a holder. `EngineJobControl.yieldResult` therefore
   refuses an owned value and `ResultSinkWorker.onElement` deep-copies through `DataSnapshot` — which cannot
   work for an arbitrary graph backed by native handles.
2. **The engine has the same gap in another form.** `Execution.host` returns `DataBindings` with no hold taken
   by the parent frame, so the only way a live resource leaves a document is a context export, never its return
   value. Return value and context are two paths with two rules (R1).
3. **Script and Flow values are never adopted.** A closeable becomes known only where the Job takes a hold
   (`SourceIngress`, `JobChannel.send`). `ScriptRunContext.stepValues`, Flow vertex outputs and `recordValue`
   have no such boundary (R4, R8).
4. **Value dependency is a third concern.** The ledger keys owner sets by `ValueAccess` in a `WeakHashMap`, so
   a view into an owned ITCH batch keeps the batch open, and `FormulaWorker` / `JavaTransformWorker` call
   `inherit` so a derived non-scalar keeps its input open. Any unification must keep this.
5. **Cursor-borrowed lifetime** (`LentElement`, `CursorLending`): an element valid only until its source
   advances; the source suspends on `OwnedNative.awaitClosed`. A distinct semantic built on the hold count.
6. **Two migration paths.** The ledger rides `JobCarryover` (closing everything if unclaimed); the engine lifts
   bindings and anonymous disposals by stable owner (`LiftedRegistrations`).
7. **`Recyclable` has the same shape** — hold count, last release returns to the pool, forfeit detaches — and
   is kept disjoint by not being `AutoCloseable`, at the cost of a parallel token path in `JobChannel.send`
   and `CallbackLeases`.
8. **Invented rules.** `NativeIdentityRegistry.global` is process-wide (R9) and refuses an object a second run
   adopts. (The stall timer and `JobOwnershipReport` named in the analysis were already removed by scrub step
   2, commit `7c0b87e2`; `SnapshotPolicy` is gone with them. What remains is the copy at the result boundary.)

Size: the Job ownership package is 646 lines, its Worker-side glue 522, `Recyclable` 194, tests 2,075.

## 2. Goal

- One disposal primitive for Script, Flow, Job and any Logic (R8): a hold-counted resource entry that closes
  exactly once when its last hold is released (R3).
- Frames are holders. The settlement table of logic-spec §6 (`auto` / `manual` / `keepOnFailure`, supersession,
  explicit release, retained surface) is restated in terms of holds and otherwise unchanged (R2).
- A result is handed over live: the receiving frame holds it before the producing frame settles (R7).
- Any closeable value a frame records is tracked and closes when the frame settles or the value is superseded,
  unless it was handed on (R4, R6).
- Ambient context stays a separate feature. A managed binding is a holder that has a name (R1).
- No process-wide state (R9). No caps, no modes (R10).
- The Job's unowned hot path costs what it costs today or less (§5).

## 3. Design

### 3.1 Core (kzen-lib)

Three types, moved from kzen-auto into `kzen-lib-common` `exec/engine/resource/` (JVM parts in `jvmMain`), plus
one field on `DataValue`.

```kotlin
// Resource — today's OwnedNative, with a closer instead of an AutoCloseable (a WebDriver is not one)
class Resource internal constructor(val native: Any?, private val closer: () -> Unit) {
    fun hold(holder: Holder): Hold            // fails by name once closed
    fun holds(): Map<Holder, Int>             // live view
    fun detach()                              // closed WITHOUT running the closer: someone else closed the native
    suspend fun awaitClosed()                 // LentElement's wait
    val isClosed: Boolean
}

// Hold — today's ValueLease: idempotent release; the last release across holders closes the Resource
interface Hold { val isActive: Boolean; fun release() }

// Held — a hold together with the value that carries it; the caller stores THIS value, not the one it passed in
class Held(val value: DataValue, val hold: Hold)

// ResourceRegistry — today's RunOwnershipLedger, one per run, behind ITS OWN lock
class ResourceRegistry {
    fun adopt(native: Any?, closer: () -> Unit, holder: Holder): Adoption
    fun hold(value: DataValue, holder: Holder): Held?      // null for an unowned value: no allocation
    fun live(): List<Resource>; fun holdsByHolder(): Map<Holder, Int>
}

// ResourceOwners — a DataValue's dependency on resources (today's OwnerSet), released in list order
interface ResourceOwners { val isEmpty: Boolean; fun hold(holder: Holder): Hold; fun entries(): List<Resource> }
```

- **`Holder`** is a name (today's `LeaseHolder`): a frame's stable id, a channel location, a Worker location.
- **`DataValue.owners: ResourceOwners?`** sits beside `metadata`. `withMetadata` and navigation copy it, so a
  view into an owned value depends on the same resources by construction. This replaces the ledger's
  `WeakHashMap<ValueAccess, OwnerSet>`, `attach` and `owners(value)`: a read of `owners` is a field read.
  `inherit(child, parent)` becomes `child.withOwners(child.owners + parent.owners)` — the child's own entries
  first, as `OwnerSet.of(entry) + inherited` orders them today, so a holder releasing both closes the child
  before the parent. **Close order is a guarantee:** owners are released in list order.
- **The identity index stays.** `DataValue` is immutable, so an adoption cannot write `owners` into the value
  the caller already has; it returns a new value, and the caller stores that one (`Held.value`). The registry
  therefore keeps today's `IdentityHashMap<native, Resource>` (`RunOwnershipLedger.entries`) as the index that
  makes adoption idempotent: a fresh `DataValue` wrapped around a native the run already owns (a lift, a
  boundary re-wrap, a navigated child that is itself closeable) **attaches** the existing entry instead of
  adopting twice. What goes is the weak side-table and its `WeakReference` churn, not the index — the index is
  also what `live()`, `Borrowed` marking and the double-adoption refusal (§4) read.
- **The one rule.** Taking a hold on a value whose native is an `AutoCloseable` adopts it when the index does
  not know it (closer = `close`) and attaches the known entry when it does; either way the returned value
  carries `owners`. A `Borrowed` adopts as an entry with no closer, so it is visible in the live view and nobody
  closes it. Nothing else creates a `Resource`. The fast paths stay: a `Scalar` type is never adopted,
  closeability is decided once per native root class, and `hold` returns `null` for an unowned value.
- **`Resource` is at-most-once by a CAS claim**, as `OwnedNative` is today; a closer that throws leaves the
  entry closed and the failure goes to whoever released last (or is aggregated by a frame settle). `detach()`
  wins the same claim without running the closer: the entry reads as closed, holders' native reads fail by
  name, and their later releases are no-ops.
- **Use-after-close.** `NativeLivenessGuard` and `NativeIdentityRegistry.guard` go. `DataValue` reads through
  `owners`: a native read of a value whose owners include a closed `Resource` fails by name. Unowned values
  (owners `null`) pay nothing.

### 3.2 Frames are holders (kzen-lib `RunEngine`)

`NodeRuntime.bindings` keeps its map; each `Binding` carries a `Hold?` and a `ClosePolicy` instead of a
`FrameDisposal` closure. `NodeRuntime.settleDisposals` becomes a list of frame holds.

**A hold is never dropped.** Every path out of a frame does exactly one of four things with each hold: release
it, hand it to the parent, move it to `retained`, or detach the resource. Today a closer that is never claimed
simply vanishes; under a count a vanished hold would keep the entry in `live()` forever and stop a co-holder's
last release from closing. The table has no "drop" row for that reason.

| Today | Under RH |
|---|---|
| `bind(key, value, disposal)` stores a closer | adopts `value` with `disposal.closer` (or `::close`), takes a frame hold with the policy, stores it with the binding |
| `onSettle(policy, closer)` stores a closer | adopts an anonymous `Resource(closer)` and takes a frame hold |
| `resource(key, policy, value, closer)` | same as `bind`; the raw-string layer is unchanged |
| same-key re-bind supersedes: run displaced closer | release the displaced hold |
| `releaseBinding(key)` runs the disposal | releases the hold (closes only if last) |
| `releaseResource(key)` removes without disposing | removes the binding and **detaches** the resource — the caller declares it already closed the native itself, so the entry reads closed and no closer ever runs; same contract as today, now visible to co-holders |
| settle, `Auto` | release the hold |
| settle, `Manual`, non-root | hand the hold to the parent frame (`putIfAbsent`, as today); when the parent already has that key, the hold goes to `retained` instead of being lost (today the displaced closer leaks silently) |
| settle, `Manual`, root or barrier | move the hold to `retained` |
| settle, `KeepOnFailure`, failed | move the hold to `retained`; anonymous too (`Retained.key` becomes nullable) — the side effect stays, as today, and is now findable and closeable on the inspection surface |
| settle, `KeepOnFailure`, otherwise | release |
| LIFO; anonymous before bindings | unchanged |

New member, the only addition to `Execution`:

```kotlin
/** A frame hold on [value]'s resources, released at this frame's settle unless released earlier. Null when
 *  the value owns nothing. The caller stores and passes on [Held.value], which carries the owners. */
fun hold(value: DataValue): Held?
```

`settleFrame` releases the frame's value holds with its anonymous ones. **Lock discipline is unchanged:**
`settleFrame` today decides under the engine lock and runs the closers after leaving it (`RunEngine.kt:1292-1347`);
under RH it collects the holds to release under the lock and releases them outside it, because a release can
run a closer. Hold and release themselves never take the engine lock: they go to the registry's own lock and
the entry's atomics (§5).

### 3.3 The host boundary (R7)

The hook is in `RunEngine.runNode`, not `hostChild`: the child frame settles inside `runNode` (`settleNode`,
`RunEngine.kt:946`) before `hostChild` ever sees the bindings (`:1048`). So in `runNode`, after
`settleOutputs(outputSchema, returned)` and **before** `settleNode`: for every bound value in the returned
`DataBindings` with non-null `owners`, the **parent** frame takes a hold. The count never touches zero between
the child's last hold and the parent's first. The parent's hold is an ordinary frame value hold: it releases at
the parent's settle, or earlier when the parent records something else in its place.

**The root has no receiver, so its returned owned values close at its settle.** A resource lives exactly as
long as some holder holds it; after the root frame settles there is no frame left in the run, so nothing is kept
open "until the next run". The run's review surface does not need the live native: trace events are
`ExecutionValue`s built from display text (`DataSnapshot` stays for that, §4), so a finished run is fully
readable with every resource closed. An out-of-engine consumer that wants a top-level result live (an embedding
host; none exists today) is simply another holder: it takes a hold through the run API before the root settles
and releases it when done — the same mechanism, no root-specific rule. `retained` is the one deliberate way to
keep something open after the Logic is done (`Manual` at root, `KeepOnFailure` on failure): the user's explicit
choice, unchanged, surviving `dispose()` as today and closed only through `releaseRetained`. `dispose()` releases
whatever holds the run itself still has (orphaned migration captures, a run torn down mid-flight), as logic-spec
§7 asks.

Inside a Job the same rule applies one level down: `EngineJobControl.yieldResult` takes a Job-root-frame hold on
the yielded value (`execution.hold`), because the callback hold that covers the yield is released when the
callback returns. The Job frame's settle releases it, after `host` has given the parent its hold.

### 3.4 Script and Flow adopt what they record (R4, R8)

- `ScriptRunContext.recordValue(stableId, value)`: `execution.hold(value)` and **store `Held.value`** in
  `stepValues`, so later steps read the value that carries its owners; the previous hold under that stable id
  (a loop body re-recording) is released, so a superseded closeable step value closes if nothing else holds it.
  The hold rides `ScriptMigrationState` with the value it belongs to (it is never released by a migration).
- `FlowRun`: the same at the point a vertex's output is recorded, and for `outputBindings()`.
- `RunStep` needs no change: `execution.host` hands it a value the Script frame now holds.
- `BrowserOpenStep`, `BindStep`, `DisposeAtSettleStep`, `ScriptStepContexts` and `ScriptRunContext.openResource`
  are unchanged at the call site; `bind` with a disposal now means "adopt and hold".

### 3.5 Job holders (kzen-auto)

The kzen-auto side shrinks to holder implementations over the registry, reached through `Execution`:

- `JobChannel.send`: `registry.hold(element, channelHolder)` and the channel carries `Held.value`, so the
  consumer receives the value with its owners; `bindOwnership` goes (the channel asks its control). `SourceIngress`
  likewise hands the Worker the held value.
- `CallbackLeases`, `SourceIngress`, `AcquiredItem`, `OpenedStream`, `CursorLending`, `LentElement`: unchanged in
  logic, retyped to `Hold` / `Resource` / `ResourceOwners`. `awaitClosed` is `Resource.awaitClosed`.
- `EngineJobControl.retain` unchanged; `holdForCallback` unchanged; `snapshot` returns the value as it is (its
  only remaining job is forfeiting a `Recyclable`, which §3.6 removes, so the member goes from `JobControl`).
- `ResultSinkWorker` keeps the element (no copy). Of `yieldResult`'s two refusals the owned-value one goes; the
  lent-element one stays as the single check, because a `LentElement` cannot outlive its callback by definition.
- Deleted: `RunOwnershipLedger`, `OwnedNative`, `OwnerSet`, `ValueLease`, `ValueLeases`, `CompositeLease`,
  `LeaseHolder`, `RunOwnershipControl`, `JobControlOwnership`, `NativeIdentityRegistry`, `JobCarryover.ledger`,
  `JobRun`'s `closeAll` (the Job frame's settle releases its holds; nothing else is the run's to close).
- `Borrowed` (plugin API) stays, meaning what it means today.

### 3.6 `Recyclable` is a resource whose close returns to the pool

`Recyclable` becomes a `Resource` with closer `pool.recycle(this)`; `forfeit` is `Resource.detach()` (close becomes
a no-op; the object is an ordinary value the GC reclaims). `RecyclableAccess` sets the value's `owners` to that
entry. `JobChannel.send`'s special branch, `Recyclable.Token`, `CallbackLeases.transferring`'s token case and
`Recyclable.of` / `forfeit` / `forfeitDerived` go; the pool's intrusive return stack stays. The rule "a pooled
object may leak but must never recycle early" holds because a hold count is exactly that rule.

### 3.7 Live edit

The registry is run state, not node state: it lives on the `RunEngine` run and survives `migrate` as the
ledger survives today through `JobCarryover`. Frame holds travel with their frames as `LiftedRegistrations`
already lifts bindings and anonymous disposals; value holds in a flavour's capture travel in that capture. An
unclaimed capture **releases its holds** (today: closes `AutoCloseable` captures), and the orphan sweep for a
removed owner releases rather than closes — the same at-most-once close, reached through the count.

### 3.8 Visibility (R5, during a run)

`RunEngine.snapshot` exposes `registry.live()` with holds by holder: what is open, who holds it, how many holds.
This generalizes the Job's per-Worker `holds` in progress to every flavour. The static overlay (resource flow over
the dependency DAG without running) is out of scope here — see §6.

## 4. What is deleted

| Removed | Why |
|---|---|
| `NativeIdentityRegistry.global` | process-wide; the per-run registry already refuses a double adoption within a run, and a host object shared across runs is `Borrowed` by contract |
| `NativeLivenessGuard` plumbing in `DefaultDataAdapterRegistry` / `JobDataValues.adapters` | use-after-close is read off the value's `owners` |
| `DataSnapshot` at the Job result boundary; `JobControl.snapshot` | results are handed over live. `DataSnapshot` itself stays for display text (`ScriptRunContext`, `FlowRun`, `LogicParameter`) |
| `yieldResult`'s owned-value refusal | superseded by the Job-root hold |
| `JobRun` `closeAll`; `JobCarryover.ledger` | the frame settle and the run-scoped registry do it |
| `FrameDisposal` closures, `runCloserLogged`, the engine's closer lists | holds |
| `Recyclable.Token`, `Recyclable.of/forfeit/forfeitDerived`, the `JobChannel` token branch | §3.6 |
| the whole `exec/job/ownership` package | moved to kzen-lib as §3.1 |

## 5. Performance

**Unowned hot path unchanged or better.** Per element, `JobChannel.send` does today: an `is Scalar` check, a
class-cache lookup, a volatile `anyOwners` read, and only for an owned value a synchronized `WeakHashMap` lookup
plus a CAS. Under RH the first three are identical and the fourth is a field read of `DataValue.owners`,
dropping the weak-map lookup and its reference churn. Owned items still pay one CAS per hold and one per
release. The existing gate `OwnershipOverheadTest` (300,000 lifted scalars through a channel; 3 ms unbound vs
5 ms bound at HS18) stays as the gate, unchanged.

**Two things would regress it, and are design requirements, not hopes:**

1. **The registry has its own lock.** `RunEngine` has one lock with about sixty synchronized sites (emit,
   checkpoint, settle). Holds must never take it: `ResourceRegistry` has its own lock for adoption and the live
   list, and `Resource` uses per-entry atomics for hold and release, as `OwnedNative` does today.
2. **Holds at `host` are per call, not per element.** A `RunWorker` in a loop pays one hold per iteration; a
   Script step pays one per step.

**One new cost, bounded by the live set.** `settleFrame` walks the frame's value holds. A Script that re-recorded
a step in a loop released each previous hold at the re-record, so the walk is what is live, not history.

**What becomes cheaper.** No structural copy at the Result boundary, no `WeakReference` tombstones, no weak-map
lookup per hold on an owned value. The identity index is touched once per adoption or re-wrap of a closeable
native (§3.1), never per hold and never on the unowned path.

## 6. Out of scope

- **Static resource overlay (R5 before running).** Needs design-time knowledge that a step or Worker output type is
  `AutoCloseable`; the VM plan's data-derived types are the input. A separate plan once RH has landed.
- **Report** (legacy): keeps its own closeables.
- **kzen-sample**: `Borrowed` and `JobControl` members other than `snapshot` are unchanged; the spring-embed
  sample is rebuilt against the published artifacts in RH5 and edited only where `snapshot` was called.
- **Cross-engine sharing of one object without `Borrowed`**: not detected (the global registry did this). The
  host's contract is `Borrowed`; two engines adopting one object is a host bug and double close is idempotent (R3).

## 7. Rows and verification

**RH1 — core and engine (kzen-lib).**
- Work: §3.1 types in `kzen-lib-common` (`Resource`, `Hold`, `Holder`, `ResourceRegistry`, `ResourceOwners`,
  `DataValue.owners`); §3.2 `RunEngine` bindings and anonymous disposals over holds, `Execution.hold`; §3.3
  parent hold in `host` before the child settles; §3.7 lifting and orphan release; §3.8 live view in the snapshot;
  `NativeLivenessGuard` removed, owners-based closed check in native reads.
- Tests (`RunEngine*Test`, moved `RunOwnershipLedgerTest` as `ResourceRegistryTest`):
  - every row of the settlement table (today's `RunEngineContextTest` cases pass unchanged);
  - a child's returned owned value is live in the parent and closes at the parent's settle;
  - a parent re-recording the same slot releases the previous hold;
  - two frames holding one resource: closes at the second release only;
  - supersession, explicit release and settle race to one close;
  - a fresh `DataValue` over an already-owned native attaches the existing entry (no second adoption, one close);
  - a derived value closes its own entries before its inherited ones;
  - `releaseResource` detaches: no closer runs, a co-holder's read fails by name, its release is a no-op;
  - `Manual` hand-up onto an occupied key and anonymous `KeepOnFailure` on failure both land in `retained`;
    `live()` never shows an entry nobody can reach;
  - a root's returned owned value closes at the root's settle (no holder remains), while a hosted child's is
    live in its parent; `retained` survives `dispose()` as today;
  - migrate carries frame holds, releases an unclaimed capture's holds once;
  - a read through a closed owner fails by name; an unowned value's `owners` is null and reads pay no check.
- Build: `./gradlew build publishToMavenLocal` in kzen-lib (all four subprojects).

**RH2 — Job holders over the registry (kzen-auto).**
- Work: §3.5; delete the `ownership` package, `NativeIdentityRegistry`, `JobCarryover.ledger`, `closeAll`,
  `yieldResult`'s owned refusal, `JobControl.snapshot` and `ResultSinkWorker`'s copy; `FormulaWorker` /
  `JavaTransformWorker` (`objects/job/worker`) derive owners via `withOwners`;
  `:kzen-auto-plugin:publishToMavenLocal`.
- Tests: the E9 matrix (`OwnershipBoundaryTest`, `OwnedRouteTest`, `OwnedSourceRouteTest`,
  `RunOwnershipTeardownTest`, `CursorSourceWorkerTest`) retargeted. The result test inverts: a Result over
  owned records is **the live value**, readable in the caller, and closes when the caller's frame settles.
  `OwnershipOverheadTest` unchanged. `FormulaStepTest` canary.
- Build: `./gradlew build` in kzen-auto.

**RH3 — Script and Flow adopt (kzen-auto).**
- Work: §3.4 `recordValue`, Flow vertex outputs and `outputBindings`; `ScriptMigrationState` carries holds.
- Tests: a step returning an `AutoCloseable` closes at Script settle; passed to a later step it is live there
  (R4); a loop body's superseded value closes each iteration; a sub-Script's returned closeable is live in the
  caller and closes with the caller; a Flow vertex likewise; `BrowserOpenStep` behaviour unchanged
  (`ScriptExtensibilityTest`, `ResourceDisposalLog` fixtures).

**RH4 — `Recyclable` as a resource (kzen-auto).**
- Work: §3.6.
- Tests: `RecyclableTest`, `RecyclablePoolTest`, `RecyclableRouteTest`, `JobChannelRecyclableTest`,
  `FormatAllocationTest` retargeted; the allocation pins hold.

**RH5 — docs and downstream.**
- kzen-lib `docs/logic-spec.md` §6 rewritten around holds (the settlement table stays; the anonymous
  `keep-on-failure` note changes from "nothing is retained" to retained-and-closeable); `docs/architecture.md`.
- kzen-auto `AGENTS.md` E9 gotcha and `docs/architecture.md` § Job ownership; `docs/plugin-authoring` wherever
  `snapshot` or `Borrowed` is described.
- `docs/analysis/2026-10-14_resource-policy.md`: status line points here.
- kzen-project rebuilt from its own directory; kzen-sample spring-embed rebuilt against mavenLocal, `snapshot`
  call sites edited.

## 8. As-built

### RH1 — core and engine (kzen-lib), 2026-10-16

- `exec/engine/resource/`: `Resource(native?, closer?, onClosed?)` (hold-counted, close is a single claim, a
  throwing closer leaves the entry closed and the failure is thrown from the closing release; `detach()`;
  `Resource.borrowed(native)` has no closer and never closes), `Hold` (+ `none`, `releaseAll`), `Holder(name)`,
  `Held(value, hold)`, `ResourceOwners` (identity set; `plus`, `hold` with rollback through an internal
  `CompositeHold`), `ResourceRegistry(onChange)` (`adopt`, `register`, `hold(value, holder): Held?`, `entryOf`,
  `live`, `holdsByHolder`, `holdsOf`). All in `commonMain` over a new `platform/collect/identityMap()`
  expect/actual (JVM `IdentityHashMap`, JS `HashMap`), so `Execution.hold(value)` / `Execution.resources` sit on
  the common interface. **Deviation:** only an `AutoCloseable` native is identity-indexed (attach on re-adoption,
  first closer wins); a non-closeable native with an explicit closer and an anonymous teardown are separate
  unindexed live entries — this keeps today's "two closers for the same string" `RunEngineContextTest` behaviour.
- `DataValue(access, root, metadata?, owners?)`; `withOwners`, `child` and `withMetadata` keep owners, an
  overlay record merges its base's and values' owners; `requireOpen()` fails by name through a closed owner;
  `native()` checks first. `NativeLivenessGuard` and `DefaultDataAdapterRegistry.livenessGuard` are gone.
  `FrameDisposal(policy, closer)` has no `claim`; `RetainedBinding.key` is nullable (anonymous keep-on-failure
  is retained and closeable via `releaseRetained(node, null)` — the old "nothing is retained" is gone).
- `RunEngine`: `FrameHold(policy, resource?, hold)` per binding / anonymous disposal / value hold, frame holder
  `"<stableId>@<nodeId>"`, `registry` dirty-flags the snapshot, `settleFrame` restated over holds (Auto release,
  Manual `putIfAbsent` else retained, root/barrier retained, KeepOnFailure retained on failure), `settleOutputs`
  takes the receiver's hold on every returned value before the child settles (an unrecorded `AutoCloseable` is
  adopted there; the root has no receiver so its owned returns close at its settle), `holdFor` off-lock,
  `dispose()` releases live frames' holds and leaves `retained`, migrate lifts frame holds and `sweepOrphans`
  releases an unclaimed capture's. `RunState.resources: List<ResourceState>` (description, borrowed, holds by
  holder name). `Resource` allocates its holder map on the first hold and no close signal unless awaited (RH4's
  per-trip cost).
- Tests: `ResourceRegistryTest` (8, replaces `RunOwnershipLedgerTest`), `RunEngineHoldTest` (9),
  `RunEngineContextTest` adjusted for the retained anonymous keep-on-failure. `build publishToMavenLocal` green.

### RH2 + RH4 — Job holders and `Recyclable` (kzen-auto), 2026-10-16

- Deleted: `exec/job/ownership/*`, `ValueLease`, `JobControlOwnership`, `JobControl.snapshot`, the owned-result
  refusal, `JobCarryover.ledger` / `closeAll`, `Recyclable.of` / `forfeitDerived` / `Token`,
  `RecyclableAllocationTest`. `JobControl.retain(value): Hold` (default `Hold.none`).
- New: `exec/job/RunResourceControl` (`resources`, `holdForCallback`), `JobControl.resources()`,
  `BlockingAcquisitions.runBlockingIoAcquiring` (releases owned acquisitions when a cancel discards the
  blocking body's return — the ledger's `closeAll` used to cover that), `WorkerBase.releaseCarried()` (a
  failed or cancelled expanding transform's detached batch), `JobChannel.bindResources` / `releaseHeld` /
  `onUndeliveredElement` (a cancelled receiver's batch holds, unless `Batch.carried`). Holders: channels and
  Workers by their notation location, source streams by the Worker's, `"producer"` for items pulled before
  send, `"forfeited"` for forfeits. `JobDataValues.adapters = DefaultDataAdapterRegistry()`; `native` /
  `boundary` / `callbackObject` call `requireOpen()`, navigation via `child`; `lift(Borrowed)` wraps a
  `Resource.borrowed` owner. `FormulaWorker` / `JavaTransformWorker` outputs inherit input owners via
  `withOwners`.
- Semantics landed as planned: a top-level Result over an owned native is the live value, closed at the Job
  root's settle (`aRootResultIsTheLiveOwnedValueClosedOnceAtTheRootsSettle`); a hosted Result is live in the
  hosting frame; owned elements (pooled included) flush through `JobChannel.send` at once; a close failure at a
  Worker frame's settle is logged by the engine rather than folded into the failure.
- **Deviation (RH4):** `forfeit` is a permanent hold under `Holder("forfeited")`, not `detach()` — a detached
  owner would make the still-valid value's `requireOpen()` fail while its callback is reading it; a forfeited
  object is simply never recycled. A `Recyclable` reissues a fresh `Resource` per trip out of the pool (a closed
  entry refuses holds, which is the never-read-after-recycle rule), so `FormatAllocationTest`'s steady-state
  budget is per chunk rather than zero (zero per record): 640 B per chunk measured after the `Resource` trim,
  budget twice that.
  A pooled object's resource is built by the `Recyclable`, not adopted through the registry (it is not
  `AutoCloseable`), so pooled buffers are absent from `live()` / `RunState.resources` and from a Worker's
  progress `holds` — the live view shows real resources, not every chunk in flight.
- **Deviations (RH2):** `JobRun` still releases the channels' own holds at teardown (`releaseChannelHolds` →
  `JobChannel.releaseHeld`, skipped when migrating) — narrower than the old `closeAll` (channel holds only,
  never "every live entry"), needed because a channel is not a frame and has no settle. `retain` is a frame
  hold (holder `<stableId>@<nodeId>`) while `holdForCallback` holds under the Worker's location, so progress
  `holds` counts callback holds only. `yieldResult` lifts the kept element through `JobDataValues.boundary`
  (forfeiting a pooled one) and re-attaches its owners with `withOwners`; the single remaining refusal in
  `retain` / `yieldResult` is a `LentElement`.
- Tests: fixtures moved to `objects/job/worker/test/`, route tests to `exec/job/` (`ResourceBoundaryTest`,
  `ResourceTeardownTest`, `OwnedRouteTest`, `OwnedSourceRouteTest`, `PathProjectionRouteTest`),
  `OwnershipOverheadTest` in `objects/job/channel/` (4.0x gate, measured 3 ms vs 4 ms over 300,000 elements),
  `JobChannelRecyclableTest` / `RecyclableRouteTest` gained cancel cases, new yamls
  `owned-boundary-hosted-child.yaml`, `owned-boundary-hosted-result.yaml`, `recycle-cancel-expanding.yaml`.
  `FormulaStepTest` canary, `:kzen-auto-plugin:publishToMavenLocal`, full `./gradlew build` green.

### RH3 — Script and Flow adopt (kzen-auto), 2026-10-16

- `ScriptRunContext.record(stableId, value)` is the one write to the value graph (`recordValue`, `markDone`,
  `adoptOutcome`): `execution.hold(value)`, store `Held.value` in `stepValues`, keep the `Hold` in `stepHolds`,
  then release the slot's previous hold (hold-before-release). `FlowRun.produced` does the same per vertex
  (`vertexHolds`: message plus undrained batch remainder as one list), released when the vertex next produces;
  message clears at a loop iteration or run end touch no hold. `outputBindings()` unchanged — it reads held
  values. `RunStep`, `BrowserOpenStep`, `BindStep`, `DisposeAtSettleStep`, `openResource` unchanged.
- Migration: the engine already lifts the holds (`LiftedRegistrations.frameHolds`); `ScriptMigrationState.stepHolds`
  / `FlowMigrationState.vertexHolds` carry the references so the rebuilt run releases the stale hold on
  re-record (`adoptOutcome` re-records a replayed outcome, net one hold).
- **Bounds found:** the host-boundary hold on a `RunStep`'s result is the caller frame's, released at the
  caller's settle — a sub-Script hosted inside a loop keeps each iteration's returned closeable open until the
  loop's Script settles (engine-side follow-up, not RH3); the Script boundary (`boundary()` + `lift()`) re-attaches
  an `AutoCloseable` root by identity but drops a derived non-closeable value's owners (pre-existing).
- Tests: `ScriptResourceHoldTest` (live downstream + closes at settle; loop supersession closes each iteration;
  sub-Script result live in caller, closes with caller; survives a live edit; carried loop hold released on
  re-record after a live edit), `FlowResourceHoldTest` (owned vertex output live downstream, closes at settle),
  `ScriptExtensibilityTest` unchanged; fixtures under `notation/test/script/resource/` and
  `flow-closeable-test.yaml`, test steps/vertices under `exec/script/test/`, `exec/flow/test/`.
  `FormatAllocationTest` re-measured at 640 B per chunk, budget `2 × chunks × 640 B`. `:kzen-auto-plugin:publishToMavenLocal`
  then full `./gradlew build` green (2168 tests).

### RH5 — docs and downstream, 2026-10-16

- kzen-lib `docs/logic-spec.md` §5/§6/§7 and appendix restated over holds (settlement table kept; anonymous
  keep-on-failure retained-and-closeable; host boundary; `RunState.resources`; type table gains the `resource/`
  row), `docs/architecture.md` (Resource holds concept row, data model, package map). kzen-auto `AGENTS.md`
  (E9 / WR2 / Result bullets rewritten, new Script-and-Flow bullet), `docs/architecture.md` § 1 Job E9 + WR2
  block and a new "Script and Flow hold what they record" note, browser-handle sentence. Analysis status line
  points here. Master ledger RH1–RH5 ticked.
- kzen-project: rebuilt green from its own directory after `kotlinUpgradeYarnLock` — its stored lock predated
  FJ3's `@tanstack/virtual-core` (an FJ3 leftover, not RH); the regenerated `kotlin-js-store/yarn.lock` is the
  only kzen-project change.
- kzen-sample: no `snapshot` call sites existed. `itch-plugin/plugin` `mvnw install` green; `spring-embed/frontend`
  published; `spring-embed/backend` compiles after one pre-existing fix — `KzenWorkspace` now passes the
  `codeCacheRoot` argument `KzenAutoConfig` gained on 2026-09-25. Two backend ITs still fail for reasons older
  than RH, left for their owners: `HostPackagedIT.catalogPreparesAndRunsDatedTypedAnalysisThroughTheProxy`
  reads `test` / `checked` as preview children while `PreviewNode` has carried them in its `metadata` node since
  2026-09-24 (VM1–VM3); `HostGovernedIT.accumulatorRetainingOwnedSymbolDaysStalls…` awaits the
  `stalled: No progress while owned natives are held` warning that scrub step 2 (`7c0b87e2`) removed — under
  the current rule a run that cannot progress simply waits until cancelled, so the test's first half needs a new
  assertion, which is the sample's call.

