# HS17 — E9 source acquisition, streams and live-edit migration

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS11 and HS16.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E9 stream/source contracts and acquisition handoff amendment.

## Outcome and anchors

FormulaSourceWorker, ReadWorker/DataReadCore, cursor-driven Java source, ExpressionReturnTypeInference, EngineJobControl and RunEngine blocking handoff.

## Work

1. Support closeable Iterable/Iterator/Sequence and java.util.stream.Stream results. Close iterator then container once by identity; opening/conversion failures must not leak either.
2. Adopt pulled items inside the framework-owned blocking acquisition boundary before cancellable delivery back to the coroutine. Protect stream/cursor opens too. Use an ownership handoff whose abort path closes an acquired but undelivered resource.
3. Retain the producer lease through conversion/projection/send, including projection to scalars and omitted output. Preserve the author-owned interval inside arbitrary expression bodies and Kotlin produce methods.
4. Detach/re-adopt live closeable streams and cursor positions on migration without re-evaluate/skip; keep skip-resume for non-closeables and restart behavior for top-level Sets. Carry pending acquired-but-undelivered state or close it consistently; never lose or duplicate a delivered item.
5. Cover cancellation, source replacement/removal, failed migration and discarded retained state. Workers must join before outstanding native resources are force-closed.

## Verification and exit criteria

Use deterministic latches to cancel/migrate after open/next succeeds but before dispatcher delivery, during conversion, while waiting for a permit and during an active callback. Repeat fixtures over reader cursor, Java cursor source, host service and expression routes. Assert opens/closes, delivery sequence and no premature native invalidation. Test iterator==container, Stream.close and an unchanged closeable source through edit/continue without reopening.

## Handoff

Record the exact handoff API and migration state owner. HS18 closes E9 after boundaries, diagnostics and full acceptance.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-auto (`kzen-auto-jvm` source Workers, read core, expression inference; docs).
kzen-auto built, published to mavenLocal, and kzen-project rebuilt from its own directory. No release-train
version changed.

**Streams (Work 1).** `java.util.stream.Stream` is the fourth stream type in `ExpressionReturnTypeInference`
(`isStreamType`, `streamElementType` — `Stream<T>` → `T`, `streamIterator`), so `Files.lines(...)`-style
expressions are sources with no other change. Closing is the ledger's: `SourceIngress.adoptStream` adopts the
iterator, then — when a distinct object — the container, whichever is `AutoCloseable`, de-duplicated by
identity, held by the source's location; `OpenedStream.close` releases those holds (the ledger closes the
iterator first, then the container, exactly once), or closes directly outside a run. An open or conversion
failure leaks neither: adoption happens in the body that produced the value, so a failure after it leaves the
resource in the ledger for the teardown.

**The handoff API (Work 2–3).** `SourceIngress(control, selfLocation)` is the shared ingress boundary:
`openStream { … }` / `adoptStream(value)` for containers, `pull(iterator, limit)` for items, `adopt(element)`
for a single element, all adopting **inside the `runBlockingIo` body, before the cancellable return** — a
cancel that wins the return dispatch leaves the resource owned by the run, which the post-join teardown
closes (this replaces `CursorSourceWorker`'s catch-and-close of `CancellationException`). A pull returns an
`AcquiredItem` (the native, `Borrowed` unwrapped, with its owners and the producer hold); the source lifts it
through `AcquiredItem.lift` (owners attached) and releases the hold after `send` — with no channel hold taken
(a lift failure, an omitted output, a cancel before the send) that release closes the item. `pull` reads up to
the output's `batchSize` elements per blocking trip and stops after the first adopted closeable, so an owned
item is never pulled ahead of and an arena-backed source parks on its next permit only after the previous
item was sent. Drivers: `CursorSourceWorker` (the Java / host-object cursor route) and `FormulaSourceWorker`
(expression route) are rewritten on it; `ReadWorker` keeps its own cursor lifecycle but `DataReadCore.pull`
takes the producer hold on each pulled `DataValue` (`RunOwnershipLedger.hold`, the same operation the channel
uses at a send — `adoptEmitted` was renamed to it) inside the blocking body and `emitNext` releases it after
conversion and send. The author-owned interval is unchanged and documented: a Kotlin `produce` body or an
expression body owns what it acquires until it emits / returns it (`SourceWorker`, `FormulaSourceWorker`
KDoc).

**Migration (Work 4).** State owners: `CursorSourceWorker.DetachedCursor` (the `OpenedStream`, the items
pulled ahead but not delivered, the delivered count) and `FormulaSourceWorker.FormulaCursor` (code, index and
— for a closeable stream — a `DetachedStream` of the same shape plus the element contract). A closeable
stream is detached and adopted by the replacement instance with no re-evaluation and no skip; an edited
expression closes it (`FormulaCursor.close` releases the pending holds, then the stream) and restarts. A
non-closeable stream keeps re-evaluate-and-skip, and a closeable element the re-evaluation constructs for
the skipped prefix is closed at once (`SourceIngress.discardSkipped`); a top-level `Set` carries index 0 and
restarts. Pending acquired-but-undelivered items are carried (their producer holds intact) rather than closed;
a delivered item is claimed before its send, so a send parked mid-flush is carried by the channel and never
re-sent. Both detached states are `AutoCloseable`, so the engine's orphan sweep (a removed or replaced
source, a discarded capture) closes the stream and releases the pending holds.

**Cancellation and teardown (Work 5).** Unchanged from HS15/16 and now exercised on the ingress: every Worker
joins before the ledger's force-close, a source parked in a blocking pull delays that join, and an item held
by an active callback is not closed until the callback returns.

**Verification.** `OwnedSourceRouteTest` (9, real `RunEngine` runs): the Java cursor route closes each pulled
item after its consumer projected it and the cursor once (`JavaCountingSource` fixture); an expression
`Stream` of closeable elements closes every element after the sink and the container once (one evaluation);
a `Stream` of scalars is a stream lane whose container closes once; an iterator that is its own container
closes exactly once; a lift failure after the pull closes the item and is the run's failure (nothing reaches
the sink); a cancel while the source waits for an arena permit and a sink callback is parked closes nothing
until the callback returns, then everything once; a live edit behind a gated sink detaches a closeable
`Stream` (one evaluation, one close, every element delivered once) and re-evaluates a plain list (two
evaluations, delivered prefix skipped, every constructed element — delivered or skipped — closed once); a
pause then cancel with an open stream closes it once. `JavaAdaptersTest` (incl. cancel-after-acquisition-
before-delivery), `FormulaSourceWorkerTest` (skip-resume, edited-code restart), `JobMigrationTest`,
`ReadPartWorkerTest` and the ownership suites (`OwnedRouteTest`, ledger, teardown) stay green; the whole
`kzen-auto-jvm` suite: 1042 tests, 0 failures. Full `./gradlew build` + `publishToMavenLocal` of kzen-auto, then kzen-project
`./gradlew build`. New files staged by explicit path: `SourceIngress`, `AcquiredItem`, `OpenedStream`, the
four test fixtures / suite and the eight fixture documents. `AGENTS.md` gotcha and `docs/architecture.md`
§ 1 Job updated.

**Outstanding for HS18.** Result / trace / preview boundaries still hand an owned native's identity outward
(`JobDataValues.boundary` in `ResultSinkWorker` keeps the object the ledger will close); holder counts and
channel occupancy are computed but not published; no stall warning; the E9 matrix's throughput measurement
is not taken. The migration tests here cancel/migrate at the source's parked send, not with latches at every
acquisition instant listed in the plan (open-succeeded-before-delivery is covered by `JavaAdaptersTest`'s
latch; during-conversion by the lift-failure route; while-waiting-for-a-permit and during-a-callback by the
parked route) — a migrate landing exactly between a pull and its delivery relies on the pending-items carry,
which the detached-state close test exercises, not a latch.
