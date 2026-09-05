# Review 4 — implementation readiness after review 3

> **Status: design review only, 2026-09-04.** This reviews the latest
> `2026-09-03_in-process-hosting.md` after review 3 and the user's functional clarifications were
> incorporated. It does not amend the analysis or the extensibility plan.

## Overall verdict

The problem statement and architecture now make sense as a whole. I would not reopen the principal
decisions:

- one externally configured, process-global, startup-pinned extension universe;
- context-owned workspace state and work roots;
- host-owned synchronization, memory governance and logging, with no run-admission mechanism in kzen;
- automatic POJO support under kzen's existing trusted-code model;
- application-first class loading with ambiguity among folder-plugin peers;
- one loopback Ktor server per embedded workspace;
- a plain Java market-data core with a thin kzen adapter;
- a persistent symbol-partitioned ITCH store; and
- one fully materialized `SymbolDay` as the closeable analytical and resource unit.

The document is design-ready and several phases are directly implementation-ready. I would not yet
call the complete arc implementation-ready, however. Four contracts still need adjustment: ITCH
partition routing, E9's pre-send and cross-run ownership boundaries, plugin notation's exact resource
origin, and the generic seam through which a host arena backs `SymbolDay` materialization.

## 1. Correct the ITCH partition-routing model

The current build rule says that only Add messages carry the stock, so the full-day partition build
must maintain an order-reference-to-symbol map. That is not the best routing key for ITCH 5.0.

ITCH messages carry a two-byte **Stock Locate** field. The Stock Directory message associates that
day-local locate code with the stock symbol; order events, trades, crosses and broken trades also carry
the locate code. A sequential store builder can therefore:

1. use Stock Locate as its physical partition key while decoding;
2. record the Stock Directory mapping from locate code to canonical symbol;
3. name and expose partitions through that catalog; and
4. reserve locate zero or a separate day-wide partition for genuinely market-wide messages.

This is simpler than routing Executed, Cancel, Delete and Replace through a full-day order-reference
map. It also avoids turning arbitrary exchange symbols into filenames. The locate is day-specific,
which is exactly the scope of the derived store.

An order-reference map is still needed while **materializing one symbol-day** to reconstruct its order
graph and book. That state needs more than `reference -> symbol`: it includes remaining shares, removes
fully executed/deleted orders, and transfers the state from the old reference to the new reference on
`U`. It is then bounded to one `SymbolDay`, rather than being the store build's proposed global memory
cost.

The day-wide partition is still a sound optimization. State explicitly that storing a market-wide
message once and merging it into every applicable `SymbolDay` is **storage deduplication with logical
duplication on load**. That preserves the user's clarification that messages applying to several
symbols participate in every affected symbol's history.

P1 should consequently measure the per-symbol reconstruction state and largest `SymbolDay`, but should
not describe a full-day order-reference-to-symbol map as the build's primary memory cost unless an
additional non-ITCH requirement makes that map necessary.

Official reference:
[NASDAQ TotalView-ITCH 5.0 specification](https://nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification.pdf).

## 2. Split E9 adoption into source ingress and transport transfer

Review 3 correctly moved ownership out of process-global `JobDataValues.lift` and into a run-aware
boundary. The revised text still places the single adoption point immediately before send while also
promising that a conversion failure closes the item. Those two statements cannot both hold.

A source can obtain an `AutoCloseable` from `Iterator.next()` or a cursor and then fail during lift,
shape validation or projection before it calls `send`. Projection may also intentionally produce only
unowned scalars, so the original native root never reaches transport. Under a send-only adoption rule,
the source owns the object during that interval but no ledger does, and an exception leaks it.

Use two related boundaries:

1. **Source ingress adoption.** Immediately after a successful pull, a run-aware source driver adopts
   the native closeable and receives a producer lease. Lifting and conversion occur while that lease is
   held. If conversion fails or the source elects not to emit the item, releasing the producer lease
   closes it.
2. **Transport transfer.** A successful send takes the channel leases before releasing the producer
   lease. The count never reaches zero mid-hop.
3. **Worker-created closeables.** A new closeable constructed by a Transform or Formula has no earlier
   ingress boundary, so send-time adoption remains correct for it.

This keeps the important rule that lifting only describes/wraps values and never finds a process-global
ledger. It also makes “failed conversion or send closes what the producer adopted” implementable for
`DataCursor`, Java cursor, host-object and expression sources.

Add verification for:

- `next()` returns a closeable and lift fails;
- projection emits scalars and releases the original item after projection;
- send fails after successful lift; and
- a source pull is cancelled between conversion and send.

For stream containers, close the iterator and then the stream/container when applicable, but de-duplicate
by native identity if both references are the same `AutoCloseable`. Close failures should retain the
same best-effort/all-attempted rule used by ledger teardown.

## 3. Define ownership across runs, not only within one run

A per-run identity ledger correctly handles fan-out, aliasing, accumulators and migration **inside one
run**. It cannot detect the same `AutoCloseable` instance being offered to two different runs. Each run
would adopt it independently; one could close it while the other is reading it, and both could call
`close()`.

This matters in the motivating host because reports run concurrently and the same repository or host
service may be visible to several contexts. At minimum, document a linear ownership contract:

> An owned native identity is transferred to exactly one run in its lifetime. A source creates a fresh
> owned instance per run. An instance intentionally shared or cached across runs is exposed as
> `Borrowed` and remains host-managed.

The sample should create a fresh arena-backed `SymbolDay` per source/run. A cached `SymbolDay` returned
by a host repository must either be borrowed or replaced by a factory that materializes a new owned
instance.

There are two reasonable enforcement levels:

- **Contract-only first cut:** document the rule and test the sample's factories; or
- **Fail-fast enforcement:** a process-wide weak identity claim records which active run owns a native
  object and rejects adoption by another run.

The stronger option is safer, but the analysis only needs to choose explicitly. This is lifecycle
ownership, not run admission, and does not reopen the decision to leave host synchronization outside
kzen.

## 4. Make notation discovery scope-local

E2 now has a coherent class-precedence rule, but bundled notation cannot literally be discovered by
constructing today's `ClasspathNotationMedia` once per plugin loader.

`ClasspathNotationMedia` calls Guava `ClassPath.from(loader)`, which includes resources from ancestor
classloaders. It then reads a logical path through parent-first `loader.getResource`. A folder-loader
scan can therefore rediscover application notation; if a folder owns the same path as its parent, the
read may return the parent's body rather than the resource whose origin was discovered.

The E2 contract should require exact-origin discovery:

- scan plugin-folder URLs themselves, excluding ancestor-loader entries;
- retain the exact resource URL (or an equivalent scope-local handle) and read through that handle;
- scan application/plugin-zero resources separately; and
- detect duplicate logical notation paths across those actual origins as the specified boot error.

This is analogous to filtering `ServiceLoader.Provider`s by declaring loader, but resource provenance
must be retained through both scan and read. Guava's API explicitly describes `ClassPath.from` as
including the loader's ancestors:
[Guava `ClassPath`](https://guava.dev/releases/26.0-jre/api/docs/com/google/common/reflect/ClassPath.html).

Add two E2 acceptance tests:

1. parent notation is not counted again for every folder loader; and
2. an application/folder notation collision is reported with both origins, never silently read from
   the parent.

## 5. Specify the host-neutral materialization-budget seam

The plain Java core has zero kzen and Spring imports, while the analysis says that opening a
`SymbolDay` acquires the host's weighted arena permit before materialization. The missing piece is how a
host-owned arena participates without leaking host concepts into the core.

Use a small core-level capability, for example:

- `MaterializationBudget.acquire(weight)` returns an `AutoCloseable` lease;
- `ItchStore.symbolDays(budget)` or a `SymbolDayLoader` receives that capability;
- standalone use gets an unlimited/no-op budget;
- the Spring host supplies a semaphore-backed implementation; and
- a materialization failure closes the acquired lease before propagating the error, while a successful
  `SymbolDay` owns it until `SymbolDay.close()`.

The name is not important; the ownership ordering is. Acquire must happen before graph allocation, and
the closeable source returned by `ItchStore.open(...).symbolDays(...)` must itself close any store or
partition resources it owns. The current expression example should make that lifecycle apparent rather
than relying on a receiver object that becomes inaccessible after `symbolDays()` returns.

The persisted weight remains an estimate, so P1's safety-margin measurement should lead to a documented
conservative multiplier or other host policy. A symbol whose admission weight exceeds total capacity
must fail before blocking indefinitely.

## 6. Small E2 clarifications

Because `META-INF/kzen/plugin.yaml` is optional while duplicate plugin ids are boot errors, define the
implicit identity: normally the canonical plugin-directory name, plus a fixed reserved id for the
application scope. A manifest may provide display/version/compatibility metadata, but should not leave
identity undefined.

The global runtime also makes tests with genuinely different plugin universes mutually incompatible in
one JVM. E2's test plan should say whether those cases use forked JVMs or one deliberately constructed
test universe. A production reset/unload seam should not be introduced just for tests.

The downloaded source and derived store should live in a named durable area under the configured work
root, not under the transient per-run `job/` scratch tree that boot and settle cleanup sweep.

## Readiness conclusion

The architecture is coherent, and none of the corrections above changes its direction. In particular,
the review still supports global startup-pinned extensions, per-context availability, application-first
class loading, POJO access, host-owned memory governance, and no kzen run-admission mechanism.

Phase readiness is:

- **Implementation-ready now:** Java 25 retarget, per-context work roots, `KzenAutoHost`, Java-friendly
  reader/source adapters, E7, and most of E8.
- **E2:** ready after exact-origin notation discovery and implicit plugin identity are recorded.
- **E9:** ready after source-ingress adoption and cross-run ownership are settled.
- **ITCH core/sample:** ready after switching the derived-store partition key to Stock Locate and
  defining the host-neutral materialization-budget seam.
- **Spring sample:** intentionally waits on G1-G7.
- **Real-day pressure demonstration:** intentionally waits on P1.

After those boundary corrections, the analysis is sufficiently specific to turn into an execution
plan without another architectural design pass.
