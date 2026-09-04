# Review 3 — implementation readiness after review 2

> **Status: design review only, 2026-09-04.** This reviews the latest
> `2026-09-03_in-process-hosting.md` after review 2 was incorporated and records the user's subsequent
> clarification of the ITCH indexing and symbol-day materialization model. It does not amend the
> analysis or the extensibility plan.

## Overall verdict

The problem statement and high-level solution now make sense. I would not reopen the principal
decisions:

- one externally configured, process-global, startup-pinned extension universe;
- context-owned workspace state and work roots;
- host-owned synchronization, memory governance and logging;
- automatic plain-object support under kzen's trusted-code model;
- one loopback Ktor server per embedded workspace;
- a Java-only market-data core with a thin kzen adapter; and
- NASDAQ ITCH as the substantive sample domain.

The work is implementation-ready in parts:

- the Java 25 retarget, per-context work roots, `KzenAutoHost`, Java-friendly reader/source adapters
  and E7 can start;
- the Spring host can start after its stated G1–G8 gates;
- E8 needs only its output-schema convention completed; and
- E2 and E9 still need the ownership and runtime details below settled before they are handed directly
  to an implementer.

The user's ITCH clarification resolves the storage objection raised during this review, provided the
clarified model is written into the sample-plugin phase.

## 1. User clarification — the ITCH index is a symbol-partitioned derived store

The user clarified the intended flow:

1. locate the source ITCH file;
2. read the source file to build an index that groups messages by symbol;
3. duplicate any messages that apply to multiple symbols into each affected symbol's group;
4. load one complete symbol-day as a single batch; and
5. materialize the complete symbol state graph for temporal analysis — for example, asking what the
   book depth was one second before each trade.

The reason for the symbol-day boundary is therefore analytical, not merely operational. Arbitrary
temporal questions may need the full order, execution, trade and book history for one symbol in memory
at once. `SymbolDay.close()` is the corresponding resource boundary: opening it acquires the host
arena allocation, and closing it releases the whole materialized graph.

This is coherent with E9. One `SymbolDay` is one closeable logical Job element, even if it contains a
large graph internally. It should not be confused with JobChannel's physical batching of several
`DataValue` elements.

### Consequence for the persisted format

The word “index” should mean a **persistent symbol-partitioned index/store**, not only a list of offsets
into the downloaded file. Nasdaq sample files are gzip-compressed, so compressed offsets are not
generally randomly seekable; a decompressed per-message offset list would also be large and could turn
symbol replay into pathological scattered I/O.

A straightforward implementation is:

- sequentially decode the source exactly once;
- route each decoded frame to its symbol partition, duplicating genuinely shared messages;
- retain the original feed ordinal as the ordering tie-breaker when timestamps are equal;
- persist per-symbol counts and an estimated materialization weight;
- publish the derived store only after a complete successful build; and
- use a source fingerprint plus parser/store format version to reject a stale derived store.

The implementation should bound simultaneously open partition writers, for example with an LRU writer
cache. Building into a temporary location and publishing by atomic rename prevents an interrupted scan
from looking complete.

The host can use the stored weight to acquire an arena allocation before materializing a `SymbolDay`.
The unavoidable case where one symbol-day exceeds the entire arena remains a host sizing/error-policy
decision.

P1 should measure more than sequential decode throughput and heap:

- derived-store build time;
- derived-store disk size;
- per-symbol replay throughput;
- the accuracy or safety margin of the stored materialization weight; and
- the largest real symbol-day's materialized footprint.

With this clarification, the ITCH storage architecture is no longer an open design issue.

### Keep order executions and trade prints distinct

The materialized temporal graph should distinguish the ITCH event families:

- `E` and `C` are executions of displayed orders and belong to an `Order` lifecycle;
- `P` represents matches involving non-displayed orders and does not change the displayed book;
- `Q` is a cross trade; and
- `B` breaks a prior execution or trade by match number.

They may all participate in a unified time-ordered “trade/print event” view used by temporal analysis,
but a `P` message should not be attached to a displayed `Order` merely because both are trades. The
official reference is the
[NASDAQ TotalView-ITCH 5.0 specification](https://nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification.pdf);
the gzip sample files are in Nasdaq's
[ITCH sample directory](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/).

## 2. E9 still needs an explicit run-adoption boundary

The current E9 text says that emitting an `AutoCloseable` transfers ownership to the run, but the
owning E9 phase says the ledger entry is created when `JobDataValues.lift` sees the native. Those are
different boundaries. Today `JobDataValues` is a process-lifetime singleton and `lift` has no run or
ledger argument.

Specify one run-scoped adoption path:

- lifting describes and wraps a value but does not by itself transfer ownership;
- a source adopts an owned value immediately before placing it into Job transport;
- the producer holds a lease until all successful sends have acquired their channel leases;
- a failed conversion or send closes what the producer adopted; and
- `control.retain(value)` returns the closeable `Lease` already proposed.

That closes the otherwise unowned interval between lifting and the first channel lease, and gives every
route — cursor, Java source, host source and expression source — the same entry point.

### Re-adoption after close

The proposed “fresh entry” when the same native identity is lifted after it has closed is unsafe for an
ordinary `AutoCloseable`: it can expose an already-closed object and call `close()` a second time.
Keep an identity tombstone for the run and reject re-adoption with the named use-after-close error. A
resource that genuinely reopens should return a new resource identity or use an explicit reopen
protocol.

### Multiple owners and teardown order

A Formula can return a newly created `AutoCloseable` that also conservatively inherits its input's
owner. That output has two lifetime dependencies: its own close and the parent's lease. The transport
therefore needs an owner set/composite handle (or an equivalent dependency representation), rather than
an implicitly singular owner handle.

On cancellation or failure, cancel and join Worker callbacks before force-closing the ledger. Otherwise
a callback may still be accessing an object while teardown closes it.

## 3. Keep E9 diagnostics proportional to the reduced promise

The ledger can report holder identities and counts exactly. It cannot infer that “a source is parked in
`runBlockingIo` while an accumulator holds leases” is definitely a deadlock rather than slow I/O
without a time/progress rule.

Use:

- aggregated counts by holder in ordinary run progress;
- bounded per-item details only on demand; and
- a stall warning after a defined no-progress interval, not immediately from that state combination.

This preserves useful accumulator diagnostics without promising perfect automatic diagnosis or
publishing an unbounded list of live resources.

## 4. E2 has two remaining runtime contracts

### Application-loader precedence

The aggregate-loader description says the application parent is consulted first, while also treating
the application classloader as plugin zero and saying that a class defined in two scopes is ambiguous.
Parent-first loading silently makes the application copy win.

Choose one rule:

1. application classes deliberately win, and ambiguity is checked only among folder-plugin scopes; or
2. all scopes are peers, and the aggregate checks which scopes physically define the requested name
   before asking any loader to load it.

Whichever rule is selected should be tested with an application-classpath/folder-plugin collision, not
only a collision between two folder plugins.

### Global discovery versus contextual state

Global plugin discovery status belongs to `KzenAutoRuntime`. “Unavailable in this workspace” and a
lazy missing-`@Service` failure belong to a context-specific availability view. One context must not
mutate a global scope into an unavailable state or cache a failure that poisons another context which
does provide the service.

The capability instance lifecycle also needs one sentence: either reader/capability objects are runtime
singletons required to be thread-safe, or the runtime stores provider descriptors and each context
creates its own registry instances. A global extension universe does not by itself decide whether
`ServiceLoader` provider instances are concurrent singletons.

## 5. Complete E8's output-schema convention

The null, empty-list, same-list and independent-list cross-product behavior is now specified. Before E8
implementation, also define:

- the default output name for a path — full path or leaf name;
- explicit aliases;
- duplicate output-name rejection;
- whether projection is restricted to scalar leaves; and
- whether mappings can be unnested, including key/value and ordering semantics.

These choices determine the Worker's notation and resulting `DataContract`, so they should not be
left to the implementation.

## 6. Small lifecycle and editorial corrections

For a work-root claim, create or otherwise canonically resolve the intended root before an atomic
process-wide claim, and release it only after the context's server and active run have stopped. “Use
`toRealPath()` where it exists” otherwise leaves an avoidable alias/race edge.

The analysis also retains a few stale phrases:

- the work-root blocker still proposes `logDir`, immediately before the logging row says there is no
  per-context `logDir`;
- the early expression discussion says a `URLClassLoader` “just works,” although the settled design is
  an aggregate loader plus an explicit plugin-jar union;
- Q2 says “blocking SourceWorker variant,” while the settled Java shape is cursor-driven;
- “Open questions” now contains only closed decisions; and
- the opening status says the candidate outline awaits open questions, while the conclusion says only
  gates remain.

## Readiness conclusion

The architecture review is essentially complete. The user's clarification makes the market-data sample
coherent: preprocessing creates the symbol-grouped persisted representation, and one fully materialized
`SymbolDay` is the closeable analytical/resource unit required for temporal work.

Before calling the entire body implementation-ready, settle:

1. E9's adoption point, post-close identity rule, composite ownership and teardown ordering;
2. E2's application-loader precedence, per-context availability state and capability-instance
   lifecycle; and
3. E8's output naming/alias convention.

The Java baseline, host facade, work-root isolation, Java SPI adapters, E7, and the ITCH derived-store
implementation can otherwise proceed in their stated order, with the Spring host following its gates.
