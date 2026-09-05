# HS04 — Persistent locate-partitioned derived store

> Status: not started. One implementation session. Prerequisites: HS03.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.2 store rules.

## Outcome and anchors

Sample core: decoder, new store writer/reader and catalog.

## Work

1. Decode once, append each frame with original feed ordinal to its Stock Locate partition, and build the Stock Directory catalog. Store locate zero once and merge it by ordinal during symbol replay.
2. Bound simultaneous partition writers with an LRU cache. Resolve symbols through the catalog rather than making symbol strings filesystem paths. No full-day order-reference map.
3. Persist counts, native storage sizing inputs and heap-estimate inputs separately. Version the parser/store format and fingerprint the source.
4. Build in a temporary sibling location and publish only complete stores. Specify single-writer/concurrent-reader behavior, stale-store handling and crash recovery; never let an incomplete store look complete.
5. Put source and store in a configurable durable data area outside job/. Preserve user inputs during rebuild; use uniquely owned staging paths and verify exact cleanup targets.

## Verification and exit criteria

Test interleaved locates and equal timestamps against original order, merged global events, stale fingerprints/versions, bounded open writers and injected mid-build failure. Readers must see a complete old/new store or a named failure. Verify a boot/run scratch sweep cannot delete the durable data.

## Handoff

Record store layout and publication behavior. HS05 consumes it; HS06 measures build time, disk size and replay without redesigning the format by assumption.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
