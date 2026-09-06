# HS16 — E9 leases through channels and Worker callbacks

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS15.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E9 transport, retention and flush rules.

## Outcome and anchors

JobChannel, Emitter, TransformWorker/SinkWorker/ExpandingTransformWorker drive loops; raw receive paths; Sort/Pivot/Summary and other retaining Workers.

## Work

1. Inventory every framework batch loop and raw receive path. Take channel leases before relinquishing the producer; transfer to callback leases before releasing transport ownership.
2. Hold callback leases through processing and failure. Add explicit retain/release to Workers that keep values beyond a callback, including state retained during accumulation. Track holder by Worker location.
3. Propagate owner sets through navigation and Formula/Filter non-scalar outputs; independent closeables adopt at send, Borrowed children preserve the inherited parent. Scalars and deliberately copied projections stay unowned.
4. Flush owned values immediately, including mixed buffers, but preserve configured channel capacities. Compute occupancy from actual queued batches/elements, parked producers, callbacks and retained state.
5. Wire drainBuffered/preload ownership transfers without close/re-adopt. Audit failed/cancelled sends and undelivered channel values. Complete production integration coherently; if a boundary still cannot be made safe, document it and keep owned-value acceptance gated rather than claiming a partial guarantee.

## Verification and exit criteria

Use source → transform → writer, fan-out, filtered-to-scalar, mixed batches and failing sends. Prove exact-once close after the final holder; Sort retention closes only after release. For channel capacities 0, 1 and greater than 1, prove immediate flush prevents the partial-buffer deadlock without asserting one item per hop. Existing migration tests stay green.

## Handoff

Record the exhaustive Worker/receive-path inventory and outstanding source integration. HS17 proves migration with live owned streams/items.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-auto (`kzen-auto-jvm` channel, Worker and run seams; `kzen-auto-common` SPI doc;
docs). kzen-auto built, published to mavenLocal, and kzen-project rebuilt from its own directory. No
release-train version changed.

**Inventory (Work 1).** Every path a `DataValue` takes through transport was enumerated and given a lease
rule. *Send:* `JobChannel.Producer.send` is the transport-transfer boundary — with the run's ledger bound
(`JobChannel.bindOwnership`, from `JobRun` per stream channel, holder = the channel's location) it calls
`RunOwnershipLedger.adoptEmitted`: a root native that is an `AutoCloseable` the run does not own yet is
adopted there (a Worker-created closeable; `Borrowed` is never adopted), and the channel takes one hold on
everything the value depends on *before* the sender lets go of its own. A fan-out Worker holds once per
channel; fan-in producers each hold their own send. *Framework receive:* `TransformWorker`, `SinkWorker` and
`ExpandingTransformWorker` now drain through `FrameworkChannelInput.receiveFrameworkBatch` → `ReceivedBatch`
(elements + channel leases); a non-`JobChannel` input (tests) falls back to the SPI batch, unowned. *Raw
receive:* the SPI `receiveBatch` / `receive` / `iterator` paths release the element(s) handed out previously
on each further pull and at end-of-stream. *Migration:* `drainBuffered` / `preload` move `ChannelCarryover`
(elements with their leases) — no close, no re-adoption — and now also capture a framework loop's
not-yet-dispatched remainder and a raw reader's partially consumed batch.

**Callback holds and retention (Work 2).** `CallbackLeases.transferring` (Transform / Sink) takes the
per-callback lease through `JobControl.retain` — holder = the Worker's location — *then* releases the
channel's, and releases the callback lease when `onElement` returns, on success or failure (a close failure
on that last release is the callback's outcome, or rides suppressed on the callback's own failure);
`OwnedNative` now throws the close failure from the release that closed. The expanding transform holds the
channel lease until an element's expansion has completed (its batch travels with its leases in
`ExpansionState`; an orphaned state releases them) and holds a callback lease alongside. `SortWorker` takes an
explicit `retain` lease per owned element and releases them after `onComplete` has sent the sorted stream
(the output channel holds each first); the leases ride its `BufferState`, which releases them when the engine
closes it as an orphan. Pivot, Summary, Preview, Explore, the writers and ValueSetFilter materialize scalars
and hold nothing. Framework Workers reach the ledger through the control's declared `RunOwnershipControl`
capability (`JobControl.ownership()`), never its concrete type.

**Owner propagation (Work 3).** Owner sets are keyed by `ValueAccess`, which a child navigated from a value
shares, so navigation inherits for free. `RunOwnershipLedger.inherit(child, parent)` carries a parent's
owners onto a fresh non-scalar derivative; `FormulaWorker` (both output paths) and `JavaTransformWorker`
(per-element outputs) apply it, `FilterWorker` / `ValueSetFilterWorker` forward the same value. A Worker-created
closeable derived from an owned input therefore has two lifetime dependencies (its own entry first, then the
inherited parent) and closes before its parent when the consumer lets both go. `JobDataValues.lift` unwraps
`Borrowed` and records the identity as `NativeIdentityRegistry.State.Borrowed`, so neither the send nor any
later boundary adopts it; a `Borrowed` reaching `adopt` directly is marked the same way.

**Flush on send (Work 4).** An owned element flushes at `send` together with whatever unowned elements were
buffered before it (mixed batch), through the ordinary `flush` — so channel capacity and the batch cadence
are unchanged; `Emitter` / `ChannelOutput` docs say `send` may now suspend for an owned element. A plain
`TransformWorker` can therefore park mid-batch: an element counts as consumed at dispatch and the channel
captures the undispatched remainder, so a migration re-delivers exactly the elements no callback saw (the
parked element's own output is already in the output channel's parked batch). Occupancy is now computable:
`JobChannel.queuedElements()` counts buffered, parked-mid-flush, undelivered-carryover and undispatched
elements, beside the ledger's `holdsByHolder()`; HS18 publishes them.

**Migration and failed sends (Work 5).** The ledger outlives the graph instance: `JobRun` puts it in the
root's capture (`JobCarryover`, `AutoCloseable` so an unclaimed carryover closes everything) and skips the
post-join close-all at a migration barrier; the rebuilt run resumes the same ledger, and every carried
element is still held by its channel or Worker. A `flush` that fails releases the batch's leases (a failed
send closes what it adopted) except under cancellation, where the teardown or the carryover owns them;
undelivered channel values at run end are closed by the teardown.

**Verification.** `OwnedRouteTest` (7, real `RunEngine` runs, one Job per fixture document): linear
source → transform → sink closes each element once after the sink is done, and both the transform and the sink
see it open; a projection to a scalar closes the element when the projecting callback returns (the sink
receives closed sources' names, nothing owned); a fan-out to two sinks holds once per channel and closes after
both; a Sort's retention keeps every element open until its own emission and the sink still sees them open,
sorted; a derived closeable closes with its consumer and its parent only after it (close order asserted);
a transform failing mid-stream keeps its failure primary while everything closes; an arena-backed source
(one permit, returned only by the item's close) behind a batch of four completes at channel capacities 0, 1
and 4 — the partial-buffer deadlock the immediate flush removes. `RunOwnershipLedgerTest` /
`RunOwnershipTeardownTest` (9) still green. Existing suites unchanged and green: `JobMigrationTest`,
`JobChannelTest` / `JobChannelCarryoverTest` / `JobBatchingTest` (updated to `ChannelCarryover`),
`ReadPartWorkerTest`, all `objects.job.worker.*`; the whole `kzen-auto-jvm` suite: 1033 tests, 0 failures. Full
`./gradlew build` + `publishToMavenLocal` of kzen-auto, then kzen-project `./gradlew build`. New files staged
by explicit path: `JobCarryover`, `CompositeLease`, `ValueLeases`, `RunOwnershipControl`, `ChannelCarryover`,
`FrameworkChannelInput`, `ReceivedBatch`, `CallbackLeases`, `JobControlOwnership`, the five test fixtures /
suite and the ten fixture documents. `docs/architecture.md` § 1 Job and `AGENTS.md` gotchas updated.

**Outstanding for HS17.** Source ingress is not adopted yet: `CursorSourceWorker` / `ReadWorker` /
`FormulaSourceWorker` pull natives that are only adopted when they reach `send` (a lift, conversion or
projection failure before the send leaves the item to the author's own close path), and no stream container
is closed by the ledger; migration with live owned items is asserted only at the channel level here
(`JobMigrationTest` stays green on unowned values). A send that fails for a reason other than cancellation is
covered by code, not by a test (a `JobChannel` cannot be failed from the consumer side). E9 acceptance stays
gated until HS18.
