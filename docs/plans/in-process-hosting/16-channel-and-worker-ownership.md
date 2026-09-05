# HS16 — E9 leases through channels and Worker callbacks

> Status: not started. One implementation session. Prerequisites: HS15.
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

Not executed.
