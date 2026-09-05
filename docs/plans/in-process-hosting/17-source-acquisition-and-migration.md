# HS17 — E9 source acquisition, streams and live-edit migration

> Status: not started. One implementation session. Prerequisites: HS11 and HS16.
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

Not executed.
