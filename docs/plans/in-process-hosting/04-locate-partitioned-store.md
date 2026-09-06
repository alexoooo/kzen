# HS04 — Persistent locate-partitioned derived store

> Status: complete 2026-09-04 (as-built below). Prerequisites: HS03.
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

Executed 2026-09-04 in `kzen-sample-core`, package `tech.kzen.sample.itch.store` (plain Java, still zero kzen deps).

**Store layout** (`StoreFormat`):

```
<name>.store/                     the root a caller names
  current                         one line: the published version directory name
  v-<pid>-<uuid>/                 one version per build; never modified after publication
    manifest.properties           formatVersion, parserVersion, sourceFileName, sourceFingerprint,
                                  messages, partitions, builtAt, complete=true — written last
    catalog.tsv                   locate, symbol, messages, bytes, adds, executions, cancels, deletes,
                                  replaces, trades, crosses, breaks, other   (PartitionStats)
    partitions/<locate>.bin       [8-byte feed ordinal][2-byte length][message bytes], feed order
```

- **Build** (`ItchStoreBuilder.build(source, store)`): one sequential decode through `ItchFrameInput` + `ItchDecoder`;
  every frame appended with its ordinal to its Stock Locate's partition; locate 0 stored **once**; the Stock Directory
  builds the catalog so symbols never become file names; per-partition `PartitionStats` (bytes = the exact native
  sizing input, family counts = the heap-estimate inputs). Simultaneously open partition writers are bounded by an LRU
  cache (`maximumOpenWriters`, default 64); an evicted partition reopens in append mode. No order-reference map.
- **Publication.** A version directory is written under the root and becomes visible only when `current` is atomically
  replaced (temporary pointer file + `ATOMIC_MOVE`/`REPLACE_EXISTING`) after the manifest with `complete=true` is
  written. **Deviation from the plan's "atomic rename of the store directory":** on Windows a directory holding a
  file a reader has open cannot be renamed (`AccessDeniedException`, reproduced by the first test run), so
  directory-swap publishing cannot support concurrent readers; the pointer scheme does, and `ItchStore` keeps the
  version it opened. Superseded and aborted versions are deleted best-effort after publication and at the start of
  the next build; one still held by a reader is left for later. Two concurrent builds of one store are unsupported
  (last pointer write wins) — single writer, concurrent readers.
- **Freshness.** `SourceFingerprint` = size + mtime + SHA-256 over the first and last MiB (cheap enough to recompute on
  every open; `fullSha256` exists for a build log). `ItchStore.open(root)` rejects a missing pointer/version, an
  incomplete manifest, and a foreign `formatVersion` or `parserVersion` by name; `requireFresh(source)` rejects a
  changed source. `ItchDataArea(root)` — `sources/` and `stores/<source name>.store` under an explicitly configured
  durable root; `ensureStore` reuses a fresh complete store and rebuilds otherwise; the source is never touched.
- **Replay.** `ItchStore.replay(locate | symbol)` returns an `ItchCursor` (now an interface over a feed
  `FrameCursor` or an adopted store cursor) merging the partition with locate 0 by ordinal, so market-wide messages
  participate in every symbol's history at their original position; `marketWide()` and `stream(locate)` beside it.

**Verification (`mvn -B package`, JDK 25): 18 tests, 0 failures.** `ItchStoreTest`: per-locate replay equals the feed
filtered to that locate plus locate 0 in strictly increasing ordinal (equal timestamps keep feed order), partition
message counts sum to the feed (market-wide stored once), catalog/stats checks; stale fingerprint, foreign format
version, `complete=false` and missing pointer all named; `maximumOpenWriters = 2` over five partitions produces
byte-identical partition files; an injected abort at ordinal 100 publishes nothing, leaves the previous version
current and removes its own staging (a first build that aborts leaves no store); a reader holding the old version
across a rebuild reads it to completion while a new opener sees the new version, and the superseded version is gone
after the next build; the data area under `<work>/data` survives a recursive sweep of the sibling `<work>/job` and a
changed source triggers a rebuild. Files staged by explicit path.
