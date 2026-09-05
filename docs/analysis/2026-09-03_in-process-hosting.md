# In-process hosting of kzen, and a sample that is worth analyzing

> **Status: design authority; implementation planned, not started.** Execution is split into sessions in
> [`../plans/in-process-hosting/README.md`](../plans/in-process-hosting/README.md).
> Started 2026-09-03 as a design conversation about hosting kzen
> *inside* a foreign JVM; reworked 2026-09-04 after the host's real constraints landed and the scope
> moved from "a Spring sample with a synthetic FIX domain" to "a substantive `kzen-sample-plugin` over
> real market data, wrapped by a Spring host". An earlier draft of this document was written as a
> phased plan (HS1–HS9) — that was premature. The session plan now owns implementation steps;
> the master ledger owns sequencing. The gates in §9 precede their dependent implementation,
> not the act of planning. Decisions are marked **[decided]**; per CC-20 no line numbers are cited.
>
> **2026-09-04, planning review and memory clarification:** symbol message data is off-heap;
> book depth/history and order lifecycles form a heap object graph using persistent data structures
> (§5.2.1). `SymbolDay` owns both lifetimes, with leak detection as a diagnostic backstop. E9 must
> protect acquisition across the blocking-dispatch return boundary and account for actual channel
> capacity, not promise one item per hop (§6a.3). P1 starts with a core-only measurement before
> the plugin/host integration and is repeated against the finished routes.
>
> **2026-09-04, review cycle closed.** Five design reviews were written against this document and
> folded in the same day; the review files were then removed. Reviews 1–4 are recoverable with
> `git show 17b959b:docs/analysis/2026-09-03_in-process-hosting_review-<n>.md`; review 5 was never
> committed and is fully absorbed by the entry below. External references the reviews contributed:
> the [NASDAQ TotalView-ITCH 5.0 specification](https://nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification.pdf),
> Nasdaq's [ITCH sample directory](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/) (gzip day files), and
> Guava's [`ClassPath`](https://guava.dev/releases/snapshot-jre/api/docs/com/google/common/reflect/ClassPath.html)
> documentation (ancestor-inclusive scanning, the reason for exact-origin notation discovery).
>
> **2026-09-04 (review 5):** folded. The **store-backed `SymbolDay` route is the
> canonical plain-library route** and the raw `ItchReader` expression is a separately named
> raw-ingestion demonstration (§5.2, §6a.3); the three-path agreement compares one named result. E9
> closes four contracts: an owned native **never escapes its run** — a Result, trace or preview
> boundary takes a run-scoped structural snapshot or fails by name; a closeable **child** a Formula
> returns is declared `Borrowed`, a new closeable transfers by default; source-ingress adoption is
> **scoped to the framework-owned pull loops** (a Kotlin `produce` body or an expression body owns its
> pre-emit interval); a processing failure stays **primary** over close failures. E2's per-context
> availability view is **initialized at creation and monotonically augmented** by lazy reflective
> resolution. Embedded context shutdown is ordered server stop → context close (cancel + join) → claim
> release, with construction rollback (§2, §6a.4).
>
> **2026-09-04 (review 4):** folded. ITCH partitioning corrected: every ITCH 5.0
> message carries a **Stock Locate**, so the derived store partitions by locate (catalogued to symbols
> by the Stock Directory), locate zero *is* the day-wide partition, and the order-reference state is
> per-symbol-day materialization state, not a full-day build map (§5.2, P1). E9 gains a **source-ingress
> adoption** boundary beside the send (a lift or projection failure closes a pulled item) and **linear
> ownership across runs**, enforced by one process-level weak identity registry that absorbs the
> tombstone (§6a.3). E2's bundled-notation discovery is **exact-origin** (§6a.3, G10), a plugin's implicit
> id is its directory name, and the test plan splits one constructed universe from a forked task for
> boot errors. The sample core gains a host-neutral **`MaterializationBudget`** seam (§5.2, §5.3), and
> the download plus derived store live in a **durable area outside `job/`** (§5.2).
>
> **2026-09-04 (review 3):** folded. The user clarified the ITCH model: the "index" is
> a **persistent symbol-partitioned derived store** built by one sequential decode, and one fully
> materialized `SymbolDay` is the closeable analytical unit (§5.2, P1 widened). E9's last gaps closed:
> adoption happens at the **run-scoped send**, not `lift`; a closed identity is **tombstoned weakly**,
> never re-adopted; ownership is an **owner set**; teardown rides `JobRun`'s existing `coroutineScope`
> join; diagnostics are proportional (counts by holder, detail on demand, a stall warning on the
> deadlock monitor's clock). E2's last gaps closed: **application classpath wins, parent-first**,
> ambiguity among folder scopes, shadowing a warning; availability is a **per-context view**;
> reader capabilities are **per-context instances** from runtime-held descriptors. E8's output-name
> convention fixed. Work-root claim ordered create → `toRealPath()` → claim, released after server and
> run stop. Stale phrases cleaned (`logDir`, "`URLClassLoader` just works", Q2, §7 title, this header).
>
> **2026-09-04 (later), user:** NASDAQ ITCH 5.0 chosen (§4); a Java-friendly blocking reader adapter
> is wanted in the SPI (§6 C); and the plugin mechanism itself is to become *general and simple* —
> data sources and arbitrary objects contributable by a third-party jar or jar set, ideally letting
> plain JDK-compatible logic be used from kzen with neither side customized for the other. That last
> point is §6a, and it lands on the existing E1–E5 extensibility plan rather than beside it.
>
> **2026-09-04 (latest):** E1 ratified; `docs/plans/2026-07-25_extensibility-improvements.md` now carries
> the verdicts as its Phase E1 as-built, E2/E3 re-elaborated to §6a, and new **E7** (plain-object data
> shape) / **E8** (object-graph paths). The plugin-system part of this document is therefore *planned*;
> the in-process hosting seams and the two samples are now covered by the session plan linked above.
>
> **2026-09-04 (review 2):** folded. E9's item ownership becomes an **explicit lease
> ledger** (the first draft's `ChannelInput`-iterator hook did not match the framework's batch-consuming
> Worker loops, and contradicted its own accumulator rule); E2's expression classpath is an **aggregate
> delegating loader plus an explicit jar union** for the compiler; a `@Reflect` name in two scopes is a
> **resolution-time ambiguity**, not a boot error; a plugin's `@Service` needs are validated **per
> context**; a `Class<?>`-keyed `KzenAutoHost` builder; process-wide work-root claims; a fixed bean
> property order; E8's null / empty-list rules. Stale pre-review-1 statements cleaned (§5 diagram, §6
> title, §6a, §9). Review 2's readiness verdict stands: planning and the Java 25 baseline + G spike can
> start; E2/E9 are now specified to the level an implementer needs.
>
> **2026-09-04 (review 1):** folded; its points are marked **[review 1]** below — the process-global extension universe
> (`KzenAutoRuntime`), the reduced diagnostics promise, cursor-driven Java sources, the `Set` / resume
> rule, and the stale-drafting spots it listed. The user added one requirement on top: **streams *and*
> individual items may be `AutoCloseable`** — that is how the host's memory arena is enforced (a
> symbol-day batch consumes the arena on open and releases it on close) — now **E9** in the E plan.

## 1. Problem statement

**kzen is designed process-per-project. A real host needs it flat, in one JVM, and kzen may not know.**

An existing Java application (Spring + Polymer/HTML, Spring MVC `@RestController` web API, packaged as
**plain jars**, targeting **Java 25**) is a full end-to-end data-processing platform with a large body of
business logic. Its owner wants to migrate that logic into kzen projects *incrementally*, which means the
host and several kzen workspaces must co-exist in one process for a long time. The host is memory-intense
and runs many reports in parallel under a **global memory-usage semaphore**; spawning kzen workspaces as
child processes (what `kzen-shell` does) would put the biggest consumers outside that governor. So the
whole thing must run in one JVM: a "portlet" in the host's UI opens the kzen UI, the kzen workspaces live
in the host's heap, and kzen Jobs analyze the host's domain model.

Three hard constraints:

1. **kzen stays completely separate.** It must not know about Spring, this host, or "being embedded".
   Any kzen-side change has to be a generic seam that a standalone `KzenAutoMain` also uses.
2. **kzen must run on JVM 25+.** It currently emits Java 26 bytecode across all five siblings.
3. **Plain jars, not Spring Boot's nested-jar layout.** The host already packages this way because it
   embeds the Kotlin compiler for dynamic expressions and the compiler fails inside Boot's nested
   jars. kzen has the identical constraint (`CachedKotlinCompiler`; `ClasspathNotationMedia` scanning
   `notation/**` through Guava `ClassPath`, which cannot see into nested jars).

**Precision [review 1].** "Designed process-per-project" overstates it: the composition root is already
instance-based, and what process isolation buys today is safe ownership of a few process-wide and
CWD-relative facilities. The precise statement is: *kzen's default deployment is one process per
project; hosting several contexts in a foreign JVM means making workspace state context-owned while
deliberately keeping the extension universe process-global.* That splits into three independently
testable outcomes, and the sample must keep their acceptance criteria distinct so that one passing
sample cannot hide an accidental coupling between them:

1. several isolated `KzenAutoContext`s run in one JVM;
2. selected live host objects enter Jobs ergonomically;
3. a third-party jar set contributes server-side code and notation without kzen source edits.

**Trust model, stated plainly [review 1].** kzen expressions execute arbitrary code. In-process hosting
and plugins preserve that model; they do not create a sandbox. The security boundary is whether a user
may run kzen on the machine at all, never which getters of a plain object happen to be visible.

**And the existing sample cannot prove any of it.** `kzen-sample-plugin` is a toy: one `ReportDefiner`
over a world-cities CSV, exercising the *legacy* Report-paradigm SPI only. It does not touch the Job
paradigm's reader SPI, ships no notation, has no domain model, and cannot put memory pressure on
anything. A sample that is going to demonstrate in-process hosting under a memory governor needs a
dataset and a domain that are actually heavy.

So this document answers three questions together, because the answers constrain each other:

- **Q-A.** What does kzen need to change so a foreign JVM can host N workspaces in-process, without
  kzen learning about the host?
- **Q-B.** What real, free dataset gives the sample plugin a non-trivial order / trade / book graph, and
  how does that plugin reach a Job?
- **Q-C.** How does a Spring host consume that plugin *and* expose its own live objects to kzen, and
  where do those two mechanisms overlap?

## 2. What already exists (verified in code, 2026-09-03/04)

The pleasant surprise of this analysis is how much is already there. Each item below was read, not
assumed.

**Composition root is instance-based.** `KzenAutoContext.create(config)` builds every service as a
constructor `val`; `Application.ktorMain(context)` is a public extension; the test suite constructs many
contexts per JVM via `forTest()`. `KzenProjectMain` is the precedent for wrapping kzen-auto's server in
another main.

**The prefix contract is client-side and relative.** `kzen-shell`'s `ProxyHandler` strips `/<name>/`
and forwards to a loopback port; the frontend derives `ClientContext.baseUrl` from
`window.location.pathname`; assets and the root redirect are relative; the only push channel is SSE. A
host proxy that drops `Host` and the hop-by-hop headers, forwards `Accept-Encoding`, relays
`Content-Encoding`, streams bodies with no request timeout and does not follow redirects is
indistinguishable from the shell.

**Host classes as kzen objects is the designed path.** `GlobalMirror` consults the KSP registry first
and `ReflectiveClassMirror` second; the mirror resolves any `@Reflect` class, **including a Java class**
(it requires `javac -parameters` and uses the primary or single constructor), and fills `@Service`
constructor parameters by qualified type name from the `GraphEnvironment`. Bundled notation under
`auto-common/` / `auto-jvm/` / `auto-js/` is discovered from any plain jar on the classpath —
kzen-project's `SampleExtensionTest` pins exactly this.

**Code-as-a-Job-source exists: `SourceWorker`.** One abstract `suspend produce(emit, control)`; the
framework owns batching, checkpointing, cancellation and end-of-stream. Workers take `@Service`
parameters (`LogicSourceWorker` takes `@Service openerLookup`); `ScratchProbeSourceWorker` shows
`@Reflect` without a KSP pass. The only missing piece is a way for a *host* to put its own services into
the `GraphEnvironment` — §5.1.

**The Job-side plugin SPI exists too, and it is `ServiceLoader`-discovered.** This is the fact that
reshapes the sample. `kzen-auto-plugin` has grown a second face beside the legacy `ReportDefiner`:
`tech.kzen.auto.plugin.api.data.ReaderCapability` (a complete reader family: config
decode / validate / canonicalize / encode, `requiredContent`, `open` → `DataCursor`, `inspect` →
`DataShape`), with optional `ReaderProbeCapability` (automatic format detection) and
`FormatAuthoringCapability` (UI controls). `ReaderCapabilityRegistry.withConfiguredReaders()` adds the
built-in delimited and plain-text readers and then **`ServiceLoader.load(ReaderCapability::class.java,
contextClassLoader)`**. kzen-auto-jvm's own test tree registers three fixture capabilities through
`META-INF/services`, so the path is exercised. `DataCursor` is a plain `Iterator<DataValue>`; only
`open` and `inspect` are `suspend`.

Consequences: a plugin jar on the process classpath contributes a new file format to every File worker
in every Job with **zero kzen changes**, gets auto-detected if it ships a probe, and can bundle a ready-made
Job document as notation. What it cannot do today is arrive through `PluginDocument`'s runtime jar path
— that loader only scans for `ReportDefiner`, and the reader registry is built once at context creation
(§6, gap D).

**`GraphEnvironment` already calls itself host-supplied.** Its KDoc: *"Host-supplied registry of runtime
services … values that can't be expressed in notation."* Today the only host that can supply one is
`KzenAutoContext` itself.

## 3. What blocks in-process hosting today

| Blocker | Resolution | Generic? |
|---|---|---|
| All five siblings emit class-file 70 (Java 26); host runs 25 | retarget `jvmTargetVersion` / `javaVersion` to 25 in the five `Dependencies.kt`; keep building on the newest JDK (toolchain stays 26 unless Kotlin's consistency check objects) | yes — strictly widening |
| `WorkUtils.sibling` is a static `../work` off CWD; `processSignature` is per-process; `JobWorkPool` boot-sweeps `job/`, so a second context deletes the first's live scratch | `KzenAutoConfig.workRoot` with a CLI arg (no `logDir` — next row); `WorkUtils` becomes a context-owned instance with a per-context signature (root claim + UUID); the runtime claims each live context's root — created, then `toRealPath()`, then one atomic claim — and a duplicate fails fast; the claim is released after the context's server and run have stopped — the host's order is **server stop → context close (cancel + join the run) → claim release** in `close`'s `finally`, and a context whose initialization fails after claiming releases it on the way out [reviews 2, 3, 5] | yes — a limitation of kzen-auto in its own right |
| `logs/` is CWD-relative in the context (a managed storage area) and in kzen-auto-jvm's bundled `logback.xml` | **[review 1]** kzen logs through SLF4J; the *host* owns the backend and its configuration. No per-context `logDir` — the `logs` managed-storage area becomes config-suppressible, and the bundled `logback.xml` stays a surfaced defect (§8) | yes |
| `GraphEnvironment` is a hardcoded builder; no host can reach a `@Service` parameter with its own object | `KzenAutoHost` (`Map<ClassName, Any>` inside; a `Class<?>`-keyed builder for Java hosts, so a Spring proxy registers under the interface the Worker declares [review 2]) on `KzenAutoContext.create`, merged after kzen's entries, collision fails fast (CC-08) | yes — completes the KDoc's stated intent |
| No admission seam around a run; every `ServerLogicController` entry point is `@Synchronized` and non-suspend, called from `LogicHandler` inside `runBlocking` | **not needed in kzen** — the host governs memory inside its own closeable objects (§5.3); kzen's only obligation is E9's close discipline | n/a |
| `DataOpenerLookup` ignores `DataRef.source`; `DataSourceId` is never minted | **not a blocker** — `SourceWorker` and `ReaderCapability` cover both ways in; `ProviderDataSource` stays the deferred design-time upgrade (DM11 / O15) | n/a |
| `kzenAutoInit` sets `java.awt.headless`, arms `exitProcess`, registers a shutdown hook | accepted — a host calls `create` + `ktorMain` directly | n/a |
| `ReflectionRegistry.global` / `GlobalMirror` / `ServiceEnvironmentValidation` are process-global; the mirror is registered once in the context's companion `init`; `ClassLoaderUtils.dynamicParentClassLoader()` is static | **[review 1] embrace it as a contract:** one externally configured, JVM-global, startup-pinned *extension universe* — plugin loaders, mirrors, reader discovery, the expression classpath — initialized exactly once before any context (`KzenAutoRuntime`, E2); a second initialization with a conflicting configuration fails fast. Contexts own graph, host services, work roots, controller and server | yes — E2 |
| Notation root is a CWD heuristic | already overridable via `KzenAutoConfig.moduleRoot` | — |

Three kzen-auto changes, all small, all defensible without any host existing: the Java 25 baseline,
per-context work roots, and `KzenAutoHost`. The fourth — the explicit `KzenAutoRuntime` — belongs to
E2, and the close discipline to E9. Everything else is host-side.

## 4. The dataset — real market data, and what "orders" means in each

**Direct answer to "can we get free FIX data": real FIX logs are not public, structurally.** FIX is a
bilateral session protocol; a log carries counterparty identity and order flow. Only didactic samples exist
([FIXsim](https://www.fixsim.com/sample-fix-messages),
[NYSE CCG sample PDF](https://www.nyse.com/publicdocs/nyse/markets/nyse/NYSE_CCG_FIX_Sample_Messages.pdf)).
The exchange **market-data** feeds carry the same order / execution / book structure and *are* free.
Two of them are worth considering seriously; the crux is that "depth of book" and "order-level" are
different products.

| Source | Granularity | Container | Per-day size (gz) | Symbols | Terms |
|---|---|---|---|---|---|
| **IEX HIST — DEEP** | **price-level aggregated** book + last sale; no order ids | pcap over IEX-TP | ~11 GB (2026-09-01) | all IEX | free, no registration; redistribution allowed with the attribution line *"Data provided for free by IEX…"* |
| **IEX HIST — DEEP+** | **order-by-order** displayed resting orders with `OrderID`, plus last sale; non-displayed excluded | pcap over IEX-TP | ~10–12 GB each; the 2026-09-01 listing shows two files, `DPLC` and `DPLS`, that are *probably* the DEEP+ split — **unverified, gate D1** | all IEX (~2–3 % of US volume) | same as DEEP |
| **IEX HIST — TOPS** | top of book + trades | pcap | ~10 GB | all IEX | same |
| **NASDAQ TotalView-ITCH 5.0 samples** ([emi.nasdaq.com/ITCH](https://emi.nasdaq.com/ITCH/)) | **order-by-order**: Add, Add-with-MPID, Executed, Executed-with-price, Cancel, Delete, Replace, Trade, Cross | plain length-prefixed binary message stream, no packet framing | 3.5–16 GB; files from 2018 through Dec 2025 | all NASDAQ-listed (~ a third of US volume) | published as developer samples; **redistribution terms not found — gate D2** |
| LOBSTER samples | order-level CSV reconstructed from ITCH | CSV | small | 6 symbols, 1 day | licence unchecked |
| Databento | MBO with queue position | API | — | — | free *credits*, not free data |
| Synthetic generator (earlier draft's decision) | anything | — | dial | — | none |

**What this means for "IEX HIST sounds best":** yes, with one correction — **DEEP is not orders.** It is
the aggregate size at each price level, so the graph it yields is *book state over time + trades*, not
order → fill → trade. For the order lifecycle the file is **DEEP+**, which IEX added to HIST later and
which is the larger of the two. Both are real, both are free, both are on the same page.

**[decided 2026-09-04, user] NASDAQ ITCH 5.0 sample days — order-level and real.** IEX DEEP+ stays a
possible second reader; D1 is moot until then. The reasons, kept for the record:

1. **Richer lifecycle.** ITCH carries the full displayed-order lifecycle including replaces and
   executions-at-price, across a venue with roughly ten times IEX's volume. It is the dataset LOBSTER and
   most academic order-book work are built on — the canonical "pressure test" for book reconstruction.
2. **Simpler container.** An ITCH file is `[2-byte length][message]` repeated; a reader is a
   `DataInputStream` loop over ~20 fixed-width message types. IEX HIST is pcap → IEX-TP segments →
   messages, so an IEX reader carries two more framing layers before the first message, and the DEEP+
   message spec must be obtained (D1).
3. **Recency and continuity.** NASDAQ's directory has a Dec 2025 week; IEX rolls a trailing twelve months.
   Either is fine; neither is a differentiator.

**Data-handling policy [decided]:** no real market-data file is ever committed to a repo. The sample
plugin ships a **tiny synthetic fixture in the same binary format**, generated by a seeded writer in the
test tree (a few thousand messages, exact-assertable), and a **download-on-demand step** that fetches one
real day into the workspace's `work/` root for the pressure run. Both binary formats are safely truncatable
at a message boundary, so an "excerpt" mode is trivial if it is ever wanted — but the fixture covers CI
without a licence question, and the real day covers the governor demo without a repo-size question.

**Why not the synthetic FIX generator from the earlier draft.** It gave exact assertions and a message-count
dial, and lost realism. The policy above keeps both properties (the fixture is seeded; the real file is the
dial) and gains a real distribution of order sizes, replace chains, cancels and prints — which is the whole
point of a pressure test.

## 5. Proposed shape — three pieces, two ways into a Job

```text
kzen-auto-plugin (public SPI)            kzen-auto-jvm (KzenAutoHost, per-context roots)
        ▲                                          ▲
        │ ReaderCapability + @Reflect Workers      │ create(config, host) + ktorMain
        │                                          │
kzen-sample-plugin  ◄──── Maven dep ────  kzen-sample-embed-spring
  ITCH reader + probe                      Spring Boot, plain jars, Java 25
  domain: Order / Execution / Book         N workspaces = N contexts + CIO servers
  book-reconstruction library              @RestController proxy  /kzen/<ws>/**
  bundled Job notation                     memory arena inside host objects (E9)
                                           host services → KzenAutoHost → @Service Workers
```

### 5.1 kzen-auto — three generic seams **[decided in shape]**

Exactly the three rows of §3 marked generic: Java 25 baseline; `KzenAutoConfig.workRoot` with a
context-owned `WorkUtils` (no `logDir` — logging is host-owned, review 1); `KzenAutoHost(services)`
merged into the `GraphEnvironment`. Nothing else. Each has a standalone default `KzenAutoMain` uses
unchanged; none names a host. The `KzenAutoRuntime` split (§3) is E2's, and the E9 close discipline is
what lets the host's memory governance stay entirely on its side.

One SPI question sits beside them — **§6 gap C** (Java-implementability of the `suspend` reader methods).

### 5.2 `kzen-sample-plugin` — from toy to the substantive piece **[decided in shape]**

The plugin becomes the place where the market-data logic lives, so that it works in *any* kzen (standalone
kzen-project, kzen-shell-spawned, or embedded), not only in the Spring host. **[review 1] Two Maven
modules, not one:** a plain Java **core** with no kzen dependency at all, and a thin kzen **adapter**
module (reader, Workers, notation) — a build-level dependency boundary is a stronger proof of "neither
side customized" than a package convention inside one jar. The Spring sample consumes the core directly
and the adapter as plugin zero.

**Core (plain Java, zero kzen imports):**

- **Decoded wire messages.** `ItchReader implements Iterable<ItchMessage>` over a `Path` (a
  `DataInputStream` loop over the ~20 fixed-width message types); `ItchMessage` is a sealed family of Java
  records per message kind, **not one wide nullable record** — replay and book reconstruction need the
  event distinctions [review 1]. A normalized flat row projection exists beside it for generic Jobs.
- **Symbol-partitioned derived store and symbol-day batches [user, 2026-09-04; clarified in review
  3].** The intended flow: locate the source file → read it **once, sequentially**, building a
  **persistent symbol-partitioned store** (not an offset list: the Nasdaq samples are gzip, so
  compressed offsets are not seekable, and a decompressed per-message offset list would be large and
  turn symbol replay into scattered I/O) → load one **complete symbol-day** as a single batch →
  materialize the **full symbol state graph** (orders, executions, trades, book history) for temporal
  questions such as "the book depth one second before each trade". The symbol-day boundary is
  therefore *analytical*, not merely operational, and `SymbolDay implements AutoCloseable` is the
  matching resource boundary: open acquires the host's allocation and close ends the model's usable
  lifetime; native release and heap reclamation are distinguished in §5.2.1.
  One `SymbolDay` is one closeable logical Job element (E9), however large inside — not to be
  confused with `JobChannel`'s physical batching of several `DataValue`s.

  Build rules [review 4 corrects the routing key]: decode each frame once and route it by its
  **Stock Locate** — every ITCH 5.0 message carries the two-byte locate after the type byte (Add,
  Executed, Cancel, Delete, Replace, Trade, Cross, Broken Trade, Trading Action, Reg SHO alike), and the
  Stock Directory message (`R`) maps the day-local locate to the symbol — so the **physical partition
  key is the locate**, a **catalog** (locate → symbol, from the directory) names and exposes the
  partitions, and arbitrary exchange symbols never become file names. No order-reference map is needed
  at build time; the earlier "only Add carries the stock" confused the symbol *string* with the locate.
  Market-wide messages (system events, MWCB levels and status) carry **locate zero by the spec's own
  convention**, so locate zero *is* the day-wide partition, stored **once** and merged into every
  `SymbolDay` on load — **storage de-duplication with logical duplication on load**, which preserves
  the user's rule that a message applying to several symbols participates in each one's history. The
  original feed ordinal is retained as the tie-breaker for equal timestamps; per-symbol counts and an
  **estimated materialization weight** (counts × per-message-type constants) are persisted so the
  host can acquire its arena allocation *before* materializing; the store is built in a temporary
  location and **published by atomic rename** only after a complete build; a **source fingerprint plus
  parser / store format version** rejects a stale store; simultaneously open partition writers are
  bounded (an LRU writer cache). The **order-reference state lives in materialization**, bounded to one
  `SymbolDay`: reconstructing its order graph and book needs reference → order with remaining shares,
  removal on delete or full fill, and transfer from old to new reference on `U` — that per-symbol peak
  is what P1 measures, not a full-day map. A symbol-day larger than the whole arena stays a host
  sizing / error-policy decision. **Location [review 4]:** the downloaded source and the derived store
  are durable inputs, not run scratch — they live in a **named durable area** (host-configured; default
  a `data/` sibling of the persistent per-Worker base under the work root), never under the transient
  `job/` tree that `JobWorkPool` boot-sweeps and run-settle cleanup deletes.

  Event families stay distinct in the materialized graph: `E` / `C` are executions of *displayed*
  orders and belong to an `Order` lifecycle; `P` is a non-displayed match and does not change the
  displayed book; `Q` is a cross trade; `B` breaks a prior execution or trade by match number. A
  unified time-ordered trade / print view may include all of them, but a `P` is never attached to a
  displayed `Order` merely because both are trades. Reference:
  [NASDAQ TotalView-ITCH 5.0](https://nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification.pdf);
  samples: [emi.nasdaq.com/ITCH/Nasdaq ITCH](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/).
- **Reconstructed order lifecycle** (`Order` with the replace chain — ITCH `U` links old and new
  reference numbers — `Execution`, `Trade`) and **reconstructed book state** (`BookLevel` / `Book`, a fold
  over the message stream with snapshots at a cadence). Kept distinct from the wire messages and from
  the flat projections.

**Adapter (the kzen plugin, both routes demonstrated):**

- **`ItchReaderCapability`** (a `BlockingReaderCapability`, + `ReaderProbeCapability` keyed on the file's
  first bytes / `.NASDAQ_ITCH50` name) registered through `META-INF/services`; config: symbol filter,
  message-type filter, time window — so the same file serves a small Job and the pressure run.
- **Analysis Workers** (`@Reflect`, `@Service`-free, Java-friendly callbacks per §6 C): `ItchBookSnapshotWorker`
  (stream → top-N book snapshots per symbol per interval), `ItchOrderLifecycleWorker` (stream → one row
  per order with fill ratio, resting time, replace count). Stateful per symbol across a day — the memory
  profile the governor is for. Book reconstruction stays in the core; the Workers are thin (§7 Q4).
- **Bundled notation** under `notation/auto-jvm/kzen-sample-plugin/…`: archetypes for the Workers and
  ready-made Jobs — `ItchDay.yaml` (File worker over the day file → lifecycle Worker → aggregate by
  symbol and hour → CSV), and the **plain-library route** with no plugin code at all: an expression
  source `ItchStore.open(Path.of(store)).symbolDays()` streaming `SymbolDay` batches from the derived
  store (E9 closes each). **This store-backed route is the canonical plain-library route [review 5]**
  — it is what exercises `SymbolDay`, the budget and E9's item lifetime; the raw
  `ItchReader(Path.of(file))` expression with columns from the `ItchMessage` record stays as a
  separately named **raw-ingestion demonstration**, smaller and flat. **The budget seam, host-neutral [review 4]:** the core defines a tiny
  `MaterializationBudget` — `acquire(weight): AutoCloseable` — and `symbolDays(budget)` takes it;
  the no-arg form is the **unlimited no-op budget**, which is what the expression route above gets
  (an expression has no way to receive a host object). Acquire happens *before* graph allocation; a
  materialization failure closes the acquired lease before the error propagates; a successful
  `SymbolDay` owns its lease until `SymbolDay.close()`. The stream `symbolDays(...)` returns is itself
  closeable and **closes the store and partition handles it holds** — the `ItchStore` receiver is
  unreachable once the expression returns, so the stream must carry that lifecycle (E9 item 1 closes
  it). The **governed** path is the host-service route in §5.3, not this one.
- **The world-cities logic** stays as the *simple* case beside ITCH, re-cut as a
  `BlockingReaderCapability` — Job-only; the `ReportDefiner` is retired (§7 Q3, decided).
- **Test tree**: the seeded synthetic ITCH writer, exact-assertion tests over it, and the three-path
  agreement test on the *fixture* — comparing **one named result [review 5]**, the per-symbol trade
  count and shares traded (from `P`, `E`, `C` and `Q`, less `B` breaks), which raw reader rows,
  store-backed `SymbolDay` objects and the host repository can each produce; the paths share no
  intermediate representation, and a book-derived aggregate cannot come from the raw route — the real
  day is measured separately (P1); never keep two full-day representations alive just to prove
  equality [review 1].

### 5.2.1 Symbol-day storage, lifetime and leak detection **[decided 2026-09-04]**

**Representation.** Store the symbol's message bytes off-heap. Build a heap object graph for book
depth/history and order lifecycles using persistent data structures: successive states share unchanged
nodes, while historical states retain the meaning they had at their feed ordinal. Domain nodes can
refer to message offsets/views instead of duplicating the decoded payload on the heap. This is the
intended implementation of the materialized `SymbolDay`, not a requirement to retain one heap wire
record per message. Choose and measure the persistent collection representation in the core; it must
be usable from plain Java with no kzen dependency.

**Lifetime.** `SymbolDay` owns the native storage and roots of the persistent graph. All downstream
arena-backed views remain protected by its E9 owner. Explicit close invalidates access, releases the
native storage, drops the model's graph roots and only then returns the budget permit. The graph's
remaining heap objects are reclaimed by GC when unreachable; close does not promise immediate heap
reclamation or invalidate detached scalar copies. Use a cross-thread closeable allocation mechanism:
construction, Worker access and teardown can occur on different threads. A shared JDK foreign-memory
arena is the initial candidate; a confined arena cannot satisfy that execution model. See the
[JDK 25 Arena contract](https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/foreign/Arena.html).
Child views must keep the lifetime owner reachable while usable; safe native access must also hold
under plain-library use, outside kzen. Persistent structure sharing stays within a symbol-day's owned
lifetime unless an explicit separate owner is introduced; do not share arena-backed nodes across runs.

**Accounting.** The stored weight distinguishes predictable native allocation (including alignment
and shared day-wide messages) from an estimate of the peak heap graph, indexes and reconstruction
temporaries. The host's multiplier applies to the estimated component with documented headroom;
acquire the combined reservation before materialization. Measure native bytes, live reservations,
peak heap and retained heap separately. Structural snapshots and copied results use heap outside the
native arena: bounded previews and aggregate outputs must not accidentally copy the full history and
present a returned native permit as proof of a global heap bound. A release failure is visible and
must not report successfully freed native capacity. Oversized symbol-days fail before blocking.

**Leak detector (user's “Closer” requirement).** Use JDK `Cleaner` for detection of a model abandoned
without explicit close, unless the user identifies a specific `Closer` utility. Normal release remains
deterministic through explicit close and E9. Register detached cleanup state that cannot retain the
model or its graph; distinguish explicit close from abandoned cleanup, emit a named leak diagnostic
(symbol/day, native bytes and optional allocation provenance), and attempt safe fallback native and
permit release exactly once. Report cleanup failures explicitly. This catches unreachable unclosed
models; a model still retained by a bad lease cannot trigger GC cleanup, so E9's holder diagnostics and
end-of-run open/close accounting remain necessary. Test the cleanup action deterministically and use
a bounded, separate reachability test; ordinary correctness tests must not depend on GC timing. See
[JDK Cleaner](https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/ref/Cleaner.html).

### 5.3 `kzen-sample-embed-spring` — the host, and the *second* way in **[decided in shape]**

Depends on `kzen-sample-plugin`'s core and adapter modules as ordinary Maven dependencies, so the plain
library, the reader and the Workers arrive on the classpath and register themselves (plugin zero). What
the host adds is everything that is *embedding-specific*:

- **Workspaces.** `kzen.workspaces[]` in `application.yaml`; each is one `KzenAutoContext` + one CIO
  server on a loopback port, under `SmartLifecycle`, all created against the one `KzenAutoRuntime` the
  host initializes first — plugin directories and classpath are the host's choice ("external
  management", review 1). Two in the sample (`trading`, `risk`). The launcher UI is not embedded — the
  host's portlet page *is* the workspace list. The host also owns the SLF4J backend.
- **Proxy.** `@RequestMapping("/kzen/{workspace}/**")` returning `StreamingResponseBody`, JDK `HttpClient`
  with `BodyHandlers.ofInputStream()`, kzen-shell's header rules, `spring.mvc.async.request-timeout=-1`,
  flush per chunk (SSE).
- **Memory governance lives in the host's own objects, not at the proxy [user, 2026-09-04].** The
  host's arena is a semaphore weighted by batch size: a `SymbolDay` takes its permit — sized from the
  store's persisted materialization weight (§5.2) — *before* it materializes (a blocking acquire —
  kzen drives it through `JobControl.runBlockingIo`, so quiescence detection still sees it) and
  releases it in `close()`. **How the host's arena reaches the core [review 4]:** the host implements
  the core's `MaterializationBudget` over its weighted semaphore and hands kzen a budget-bound
  `SymbolDayLoader` as a `@Service`; that host-service route is the governed one, and it creates a
  **fresh `SymbolDay` per run** (E9's linear ownership — a cached instance would have to be
  `Borrowed`). The glue Worker over that loader is the **cursor-driven source adapter**, not a
  hand-written `produce` [review 5], so the route gets E9's full ingress guarantee: adoption right
  after `next()`, a producer lease through lift / projection / send, deterministic close on failure. The persisted weight is an estimate, so P1's safety-margin measurement yields a
  documented **conservative multiplier** as host policy, and a symbol-day whose weight exceeds the
  arena's total capacity **fails before acquiring**, never blocks forever. kzen needs no admission
  concept at all; it only has to **honour `AutoCloseable` on the streams and items it is handed, with
  defined close timing** — E9. The earlier
  proxy-level permit around `…/logic/startRun` / `status` is demoted to an optional whole-run backstop.
- **The host's own domain services.** The host loads a day through the plain core into its own
  services — `OrderBookService`, `TradeRepository` — exposes them on its own `@RestController`s for its own
  UI, and hands them to kzen through `KzenAutoHost.services` (type-keyed, like `@Service` today, built
  with the `Class<?>`-keyed Java builder [review 2]; named or
  qualified bindings would be a later extension, not a reason to complicate the first API — review 1).
  Tier 1 is a Kotlin-glue `@Reflect HostTradeSourceWorker(@Service TradeRepository)`. Tier 2 — a *named
  host iterable plus its item type*, served by one generic host-source Worker with no Worker class per
  repository — is the smallest concrete form of the deferred `ProviderDataSource`, a later expansion.
- **Isolation test** covers more than two successful starts: one context's boot sweep, output cleanup,
  notation edit, run cancellation and shutdown must not touch the other's work or state [review 1];
  and the negative case — two workspaces configured on the same work root — must fail the second
  context's start by name, not silently share the root [review 2].

**Where the two mechanisms overlap, and why both belong.** The same trades reach a Job two ways:

| Way in | Mechanism | Works where | Proves |
|---|---|---|---|
| file → `ItchReaderCapability` | plugin SPI, `ServiceLoader` | any kzen | a third-party format and analysis logic, portable |
| live host object → `@Service` `SourceWorker` | `KzenAutoHost` | embedded only | the host's *own* object graph is analyzable in place — the migration story |

They are not redundant: the first is what the plugin mechanism is for; the second is what in-process
hosting is for. And they give the e2e test its strongest assertion for free — **the two paths must
agree**: a Job over the file and a Job over the host's repository produce the same per-symbol aggregate.
The agreement is asserted on the seeded fixture (exact); the real day is measured separately for
throughput and arena footprint (P1) [review 1].

## 6. Gaps found while checking — all decided, superseded or moot as of 2026-09-04 (kept as the record)

- **A. `ReaderCapability` through `PluginDocument`.** The runtime jar-path loader scans only for
  `ReportDefiner`, and `ReaderCapabilityRegistry` is built once per context. A jar on the *classpath* is
  fine (the sample's case); a jar added *at runtime* via a Plugin document contributes no reader.
  **Superseded by §6a** — the user wants the plugin system itself reworked, not this one path patched.
- **B. Java 25 and the plugin.** `kzen-sample-plugin` already compiles with `maven.compiler.release=25`,
  but against `kzen-auto-plugin` bytecode at 26 — it builds and cannot run on 25. The retarget is the
  first thing to do regardless of anything else here.
- **C. The reader SPI is not Java-friendly. [decided 2026-09-04, user: add the adapter; shape per review 1]**
  `ReaderCapability.open` / `inspect` and `SourceWorker.produce` are `suspend`. A Java class *can*
  implement a `suspend` interface method (accept the `Continuation` parameter, return the value
  directly) but it is boilerplate a third-party author should not have to know. `kzen-auto-plugin`
  gains a `BlockingReaderCapability` (abstract class: non-suspend `openBlocking` / `inspectBlocking`,
  the `suspend` pair implemented once on top) and a **cursor-driven `SourceWorker`** for Java Workers:
  Java opens an `Iterator` (+ `AutoCloseable`) and kzen owns the pulls, batching, checkpoints,
  cancellation and close. Checked: `Emitter.send` and `JobControl.checkpoint` have no non-suspend forms,
  so the first draft's "blocking `produce(emit, control)`" cannot be written from Java — the cursor
  inverts control instead and routes each pull through `JobControl.runBlockingIo`. Generic SPI
  improvements justified on their own terms — the SPI's only sample is Java. The plugin stays Java-only.
  **Planning anchor correction:** `TransformWorker.onElement` / `onComplete` are also suspend;
  the analysis Workers consume an input stream and cannot use a source base as their transform API.
  HS11 provides the minimal Java bridge for those callbacks (ordinary methods returning output
  iterators, framework-owned emission/closure), exercised by HS22. Worker bases stay in the JVM
  Worker module if their dependencies require it; the reader adapter lives in the public plugin SPI.
- **D1. IEX DEEP+ in HIST.** The `DPLC` / `DPLS` files on the HIST listing are presumably the DEEP+ feed
  split in two, but no document found says so; the DEEP+ message spec must be obtained before an IEX reader
  is sized. Moot if ITCH is chosen.
- **D2. NASDAQ sample-file terms.** Not found on the listing page. Irrelevant under the never-commit policy
  for CI, but the README's download step should state what the user is agreeing to.
- **E. The `notation/` scan under two classloaders.** Everything above assumes the plugin jar sits on the
  same classpath as kzen-auto-jvm. If the host ever isolates plugins in their own loader, `ServiceLoader`
  and `ClasspathNotationMedia` both need that loader as the context classloader — the same threading rule
  `PluginDocument` already follows. Note, not a blocker.

## 6a. A general, simple plugin system — where this lands

**This is not a new arc.** `docs/plans/2026-07-25_extensibility-improvements.md` (E1–E5, ledger rows
9–13) already exists for exactly this: its strategic finding is that *the extension ceiling is
`ReflectionRegistry`, not notation*, and E2's goal is "a plugin JAR contributes notation-instantiable
`@Reflect` classes — Script steps, Job Workers, Flow vertices, Custom prototypes — with zero kzen-source
edits". It had been waiting since July on **E1, a ratification session that needed the user** (D1–D6 +
gate R5-G); the user saying "perhaps now is the right time" was that session, and E1 was ratified on
2026-09-04. What follows is what this analysis added to E1's table, having read the code since.

### 6a.1 What today's mechanism is, and why it is neither general nor simple

`PluginDocument` holds one **`jarPath`** on the server filesystem; opens a fresh `URLClassLoader` per
query (parent: `ClassLoaderUtils.dynamicParentClassLoader()`, i.e. kzen-auto-jvm's own loader — the
comment there notes it did not work under Spring Boot's `LaunchedURLClassLoader`, which is one more
reason plain jars are right); reads `META-INF/kzen/plugins.yaml`, a bare **list of `ReportDefiner` class
names**; instantiates each with a no-arg constructor; closes the loader (`.use {}` + `System.gc()` for
the Windows jar-lock). So: one jar (hence `kzen-sample-plugin` **shades** its dependencies), one SPI
(the legacy Report one), ephemeral loaders, no notation, no `@Reflect` objects, no readers. Meanwhile
two *other* contribution channels exist and are better: `ServiceLoader` for `ReaderCapability`, and
`@Reflect`-via-mirror + bundled notation for anything on the classpath. Three mechanisms, none
complete.

### 6a.2 The shape proposed for E1 **[proposed]**

One concept — a **plugin = a classloader** — with one uniform contribution protocol applied to each,
including the application classloader itself (so "jar on the classpath" and "jar in a plugin folder"
are the same case, which is what makes the embedded host and standalone kzen behave identically):

1. **Discovery.** A plugin is a **directory** (`<project home>/plugins/<name>/*.jar`, configurable via
   `--plugin.root=`), loaded into one `URLClassLoader` per directory at **boot**, parent kzen-auto-jvm's
   loader. A set of related jars is the normal case; shading stops being required. The application
   classloader is plugin zero. Restart to upgrade (R5-G's recommended verdict; the jar-lock problem
   disappears with boot-time pinning because nothing ever tries to replace a loaded jar).
   **[review 1] The loader set is process-global**, initialized exactly once by `KzenAutoMain` or the
   embedding host *before* any context (`KzenAutoRuntime`, E2) — not a per-context `pluginRoot`, which
   would register N mirror sets on the one `GlobalMirror`. Directory and jar order is deterministic
   (sorted by name); duplicate plugin ids, reader identities and notation paths are boot errors; a
   `@Reflect` name defined in two scopes is a **resolution-time ambiguity error** [review 2 — boot
   cannot know the names without the class scan review 1 removed]; a broken plugin fails *its* scope
   with a named diagnostic and does not hide the others; a live context's work root is claimed on the
   runtime and a duplicate fails fast [review 2].
2. **Per loader, three contribution channels, all existing:**
   - `ServiceLoader` for SPI capabilities — `ReaderCapability` (and probe / authoring), with providers
     de-duplicated by *declaring* loader so a parent's providers are not re-counted per child;
     `ReportDefiner` is **not** carried forward (Job replaces Report — §7 Q3), which retires
     `plugins.yaml`;
   - **one** `ReflectiveClassMirror` over the runtime's **aggregate delegating loader** on `GlobalMirror`
     [review 2 — not one per loader: the aggregate resolves a name through the scope that defines it,
     returns that scope's `Class` (never a copy), and raises the ambiguity when two scopes define it;
     `GlobalMirror`'s first-match chain never arbitrates between plugins] — `@Reflect` classes become
     constructible (Workers, steps, vertices, prototypes, data sources), `@Service` parameters resolved
     from the `GraphEnvironment`. **[review 1] The mirror is lazy**, so R4's boot validation (which
     iterates the *generated* `ReflectionRegistry.global`) does not cover plugin classes — a malformed
     class or a missing `@Service` surfaces when notation first references it; E3's view shows it then.
     A Kotlin plugin's KSP `ModuleReflection` participates only through an explicit rule (a
     `ServiceLoader` provider for it), since a folder plugin cannot "call `register()`" on its own.
     **[review 2] A plugin's `@Service` needs are per context:** `ServiceEnvironmentValidation` throws
     at every context creation for the whole global registry, so a KSP-generated plugin Worker needing
     `TradeRepository` would stop a workspace that never uses it; instead plugin contributions keep
     their scope, kzen's own generated registry keeps boot validation, and an unsatisfied plugin
     contribution is listed as *unavailable in this workspace* with the missing type named — never a
     blocked workspace. The **expression compiler** gets the aggregate loader for loading and the
     explicit plugin-jar union for its classpath (`classpathFromClassloader` cannot see through a
     delegating loader), so a workspace expression, which has no owning plugin, can name types from two
     plugins at once with class identity preserved;
   - bundled `notation/**` merged like kzen-project's — archetypes, ribbon tools, ready-made documents.
3. **A manifest only for what cannot be discovered**: `META-INF/kzen/plugin.yaml` with a plugin id,
   version and **[review 1] a kzen plugin-SPI compatibility version or range** (a boot-time compatibility
   error beats a later linkage failure) — metadata, never a class allow-list; nothing in it mandatory.
4. **`PluginDocument` becomes a read-only view** of what loaded and what failed (E3's per-contribution
   diagnostics), not the loading mechanism — and only of what *discovery* saw plus what the mirror was
   actually asked for (review 1's reduced promise; no class index or scan exists for the screen). Jar
   upload (D3) is deferred, not precluded: a plugin folder is the install.

This is E2 + E3 with D2 answered "per directory", D3 answered "not now", two additions E2 did not have
(`ServiceLoader` capabilities per plugin loader, and the app classloader treated as a plugin), and, from
review 1, the process-level runtime and the reduced diagnostics promise.

### 6a.3 "JDK-compatible logic with neither side customized" **[proposed — the genuinely new part]**

Everything above still asks the library author for `@Reflect`, `@Service`, and `-parameters`. The user's
further ask is to use **plain** Java — a class that has never heard of kzen — from a Job, less
ergonomically and with a wrapper where needed. **Checked 2026-09-04 (second pass): most of this already
exists, and the first draft's manifest allow-list and method-call Worker are unnecessary.**

- **Binding = a Kotlin expression, which kzen already compiles at run time (D8).** `FormulaSourceWorker`
  evaluates one user expression, classifies it *statically* on the compiler's inferred type, and streams an
  `Iterable` / `Sequence` / `Iterator` element by element (anything else is one value). So
  `ItchReader(Path.of(file)).messages()` is a data source today, with no manifest, no `-parameters` (Kotlin
  calls Java constructors positionally), no coercion layer (Kotlin's own), and the same security posture
  as every existing expression. `FormulaWorker` / `FilterWorker` give the per-element step case
  (`library.enrich(it)`). Two gaps, both small: the expression compiler is handed
  `ClassLoaderUtils.dynamicParentClassLoader()` (kzen-auto-jvm's loader), so **plugin classes are not on
  its classpath** — E2's answer [reviews 2, 3] is that this function returns the runtime's parent-first
  **aggregate delegating loader** and `ScriptKotlinCompiler` receives the explicit plugin-jar union
  (`classpathFromClassloader` cannot see through a delegating loader); and the static record shape,
  next.
- **Type- and shape-aware mapping of a class model (D9) — largely shipped in kzen-lib-jvm.**
  `DefaultDataAdapterRegistry` + `DefaultNativeTypeResolver` treat **Java records and Kotlin data classes
  as built-in**: a record becomes `DataType.Record` with one typed `DataField` per component, recursively
  (nested records nest; a cycle degrades to Opaque), `List` → Listing, `Map` → Mapping, and a rich scalar
  set (all integer widths, `BigInteger`/`BigDecimal`, `String`, `ByteArray`, `LocalDate`/`LocalTime`/
  `Instant`/`Duration`, `UUID`). `NativeObjectValueAccess` reads record components reflectively at run
  time. There is also an explicit adapter SPI (`ExactDataAdapter` per class, `CapabilityDataAdapter` by
  predicate) for anything not built-in. What is **missing**:
  1. **Design-time shape.** `JobExpressionCompiler` derives the inferred type's contract through the
     common `TypeMetadata.toDataContract()`, which knows scalars, List and Map only — a record-typed stream
     is *Opaque* to the editor even though run time lifts it as a typed Record. Fix: on the JVM, describe
     the inferred `KType` through the adapter registry instead. **S.** This is what makes a plain library's
     class model show its columns before the first run.
  2. **Enums** are not scalars today (→ Opaque). Add enum → Text. **XS.**
  3. **Ordinary Java classes (no `record`) — the "bean" shape. [decided 2026-09-04: built in, no wrapper
     required.]** Records and data classes are built in because they *declare* their components; an
     ordinary class's shape is inferred by convention instead: public no-arg `getX()` / `isX()` methods and
     public fields are fields; order **lexical by final property name** [review 2 — reflection
     guarantees no declaration order; records / data classes keep component order], JavaBeans
     decapitalization, getter over field, `getX()` over `isX()`, most-derived wins, conflicting types an
     error, static / synthetic / bridge excluded (the full convention is E7 item 1);
     nullability from `@Nullable` / `@NonNull` (JSpecify / JetBrains) when present, otherwise every
     reference-typed field optional; `getClass` excluded; superclass properties included. Two code sites:
     the resolver's `isRecord` / `isData` branch and `NativePropertyPlans.create` (which today throws
     "limited to Kotlin data classes and Java records"). **S.** A wrapper is then a user's choice
     (utility methods, renames), never a requirement.
  4. **Per-row cost.** Reader plans are already cached **per class** (`NativePropertyPlans`); a row costs
     an accessor call plus a node allocation. One avoidable extra: each child value computes a
     kotlin-reflect `starProjectedType` for its native-type token — cache per class. **XS**, then P1
     measures allocation / boxing on a full ITCH day, not reflection.
  5. **Object graphs and arbitrary paths [user requirement 2026-09-04].** Runtime navigation is lazy and
     on demand (`field` / `element` / `entry` resolve children as asked), so depth is not the issue. Three
     gaps: (a) **recursive types** — the describer guards cycles by making the recursive occurrence
     Opaque, which stops a path at `order.executions[].order`; the contract needs a *named type reference*
     so a design-time picker can keep descending (the value side already can) — **M**; (b) **`Set`** is
     refused (lists only); accept as an unordered Listing — **XS** (a *top-level* `Set` source is not
     resumable — E9, below); `Sequence` / `Iterator` stay refused
     as *values* (only an expression result streams); (c) a **path-projection / unnest Worker** — Filter
     and Formula already see the whole native object in Kotlin (`it.executions.sumOf { e -> e.qty }`
     works now), but aggregate and the CSV writer need flat columns: a Worker taking paths
     (`instrument.symbol`, `executions[*].price`) that yields columns and explodes a nested list into one
     row per element, with a design-time path picker over the contract — **M**. This is the one genuinely
     new Worker for object-graph reporting.

  Nothing here dispatches on a library's class name (CC-17): records, data classes, lists and scalars are
  JDK/Kotlin capabilities.

- **Streams that own resources, and items that own resources [user, 2026-09-04 — E9].** Review 1 found
  that an expression-created iterator over a file has *no close path* today (`FormulaSourceWorker` never
  closes anything), and that its live-edit resume — re-evaluate and skip the already-delivered prefix —
  assumes a stable, re-openable stream. The user's requirement goes further: **individual items** are
  `AutoCloseable` too, because that is how the host's memory arena works (a symbol-day batch consumes the
  arena on open and releases it on close). So:
  1. **Streams:** `Iterable` / `Iterator` / `Sequence` and `java.util.stream.Stream` (a fourth stream
     type — `Files.lines(...)`-style APIs become sources in one change): close the iterator, then the
     stream object, whichever of them is `AutoCloseable`, on completion, cancellation and failure. A
     closeable stream is **detached and re-adopted across a live-edit migration** (the `DataReadCore`
     cursor precedent), never re-evaluated-and-skipped; a non-closeable stream keeps skip-resume; a
     top-level `Set` is not resumable at all (restart on edit) because its order is not stable.
  2. **Items:** emitting an `AutoCloseable` native **transfers its ownership to the run** (a host object
     kzen must not close is wrapped as borrowed) — at **source ingress** for a pulled item (the
     framework's pull loop adopts it right after `next()`, before any cancellable return from the
     blocking dispatcher, and holds a producer lease through lift,
     projection and send, so a lift failure or a projection to scalars closes it) and at the
     **run-scoped send** for a Worker-created one [reviews 3, 4] — ingress exists **only where the
     framework owns the pull** (`ReadWorker`, `FormulaSourceWorker` over the returned stream, the
     cursor-driven Java adapter); a Kotlin `produce` body or an expression body owns what it acquires
     until it emits or returns [review 5]; an owned native **never escapes the run** — a Result,
     retained trace or preview boundary takes a run-scoped structural snapshot while the lease is
     held, or fails by name [review 5]; a closeable **child** a Formula returns is declared
     `Borrowed`, a new closeable transfers by default [review 5]; ownership is **linear across runs**,
     enforced fail-fast by a process-level weak identity registry (owned-by-run or closed) that also
     serves as the post-close tombstone [review 4]; the run's ledger, keyed by native identity, counts
     **leases with named holders** [review 2 — the first draft's "decrement in `ChannelInput`'s
     iterator, no Worker cooperation" did not match the framework loops, which consume batches through
     `receiveBatch()`, and could not see an accumulator's retained reference]: a channel holds a lease
     from `send` until the consumer's loop hands the element to `onElement`; the Worker holds an
     implicit lease for the duration of that callback; a Worker that keeps the element beyond it takes
     an **explicit lease** (`control.retain`) naming itself; the last release closes. The lease holder is
     the Worker location, so migration re-adoption is a no-op; **owner
     propagation** so aliases cannot outlive the parent — navigation children inherit the owner, and a
     non-scalar Formula / Filter output inherits its input's owner while scalars never do [decided
     2026-09-04, user]; **flush on send** for owned elements, or the producer's pending buffer would
     deadlock against the arena; flushing does not remove channel capacity — buffered singleton
     batches, blocked producers, active callbacks and explicit retention all count toward occupancy;
     migration carryover (`drainBuffered` / `preload`) transfers ownership
     without closing; teardown, cancel and failure close every outstanding element, a processing
     failure staying primary with close failures suppressed [review 5]; access after close
     is a named error. Accumulating Workers (Sort, Pivot, Summary) over owned elements can stall the
     source against the arena — inherent, not incidental, so no rule: the ledger surfaces open items and
     their holders (exact, from the explicit leases) and names the accumulator in a stall diagnostic
     [decided 2026-09-04, user; made precise by review 2].

  **Acquisition handoff [planning review].** Cancellation can discard a successfully acquired resource
  during return from the blocking dispatcher. E9's acquisition-handoff contract in the
  [extensibility plan](../plans/2026-07-25_extensibility-improvements.md) covers framework-owned
  stream opening and item pulls; HS11/HS17 implement and test it.

  This is route-independent — the same ledger serves `DataCursor` items, cursor-driven Java Workers,
  host-object sources and expression streams — and it is what turns "kzen needs no admission concept"
  (§5.3) from a hope into a mechanism. **M–L.**

**What this means for the sample plugin (§5.2 revised).** The ITCH parser, domain model and book library
are written as a **plain Java library with zero kzen imports** — `ItchReader implements Iterable<ItchMessage>`
over a `Path`, `ItchMessage` a Java record, `BookBuilder` a plain fold. Then two thin layers over it,
demonstrating both routes: (a) the *first-class format* route — a `BlockingReaderCapability` + probe +
authoring, so the File worker sees `.NASDAQ_ITCH50` files with detection and config UI; (b) the
*plain-library* route — no plugin code at all, a notation document whose expression source is
`ItchStore.open(Path.of(store)).symbolDays()` streaming `SymbolDay` batches from the derived store
(§5.2) — the **canonical** plain-library route [review 5: this paragraph had reverted to the raw
reader, which exercises neither `SymbolDay`, the budget nor E9's item lifetime]; the raw
`ItchReader(Path.of(file))` expression with columns from the `ItchMessage` record stays as a separately
named *raw-ingestion demonstration*. The e2e assertion that
both routes agree (§5.3) extends naturally to three paths: file-through-reader, plain-library-through-
expression, and host-object-through-`@Service`, compared on the one named result in §5.2.

**Limits, stated up front.** The expression route has no probe/detection and no config UI beyond the
expression itself; it is the *entry* route, and `ReaderCapability` is what a format graduates to. Nothing
here touches JS — a plain-library object gets the generic editors of `2026-08-21_extension-points.md`
§2.1, which is the intended default.

### 6a.4 The E1 table as ratified (2026-09-04), plus what review 1 added

| E1 item | Recommendation as amended |
|---|---|
| D1 plugin module registration | **Ratified 2026-09-04:** yes, per loader: mirror + `ServiceLoader` + bundled notation; **KSP never required** (Java has none); a KSP `ModuleReflection` may add ergonomics when present |
| R5-G loader lifecycle | **Ratified:** boot-time pinned, restart to upgrade — the jar-lock objection dissolves because a loaded jar is never replaced |
| D2 isolation unit | **Ratified:** one loader per plugin directory (jar set); no plugin-to-plugin dependency for now |
| D3 jar upload | **Ratified as "not now":** a folder is the install; `PluginDocument` becomes the diagnostics view. **Do not preclude upload** — keep "a plugin = a directory the loader is pointed at", so an uploaded jar set can later be materialized into such a directory |
| D4 `ObjectRegistry` | **Moot** — `ObjectRegistryScan` is no longer in the tree (removed in the Job data-source work); E5 closes with a doc check |
| D7 plugin client UI | **Ratified:** out of scope; declarative editors only |
| ~~new D8~~ allow-listed plain classes | **Dropped** — the expression Workers already do this (§6a.3); the only work is the aggregate loader plus the explicit plugin-jar union handed to the compiler [review 2] (part of D1/E2) |
| **D9** class-model mapping | **Ratified 2026-09-04.** Mostly shipped (records / data classes / List / Map / scalars, recursive, lazy navigation). First cut: design-time shape via the adapter registry (S); enums (XS); ordinary-class shape by convention, no wrapper required (S); per-class native-token cache (XS); `Set` as Listing (XS); recursive type references (M); path-projection / unnest Worker + path picker (M); P1 measurement |
| D10 app classloader as plugin zero | **No decision needed** — it is an implementation rule for E2 (one discovery code path over every loader, the app loader included), recorded so it is not forgotten |
| Extension universe scope (review 1) | **Process-global, externally configured, startup-pinned** — `KzenAutoRuntime` initialized once before any context; per-context loaders were the first re-elaboration's mistake |
| Diagnostics promise (review 1) | **Reduced:** installed scopes, contributions found through explicit protocols, `@Reflect` classes actually resolved, and named failures — never an exhaustive class inventory or reflective boot validation |
| Java `SourceWorker` shape (review 1) | **Cursor-driven** (Java opens an iterator, kzen pulls) — `Emitter` / `JobControl` are `suspend`-only, so a blocking emitter cannot be written from Java |
| **E9** closeable streams and items (user) | **Added 2026-09-04** — §6a.3 last bullet; the mechanism behind host-side memory governance |
| Item ownership (review 2) | **Explicit leases** — the framework's batch loops lease implicitly per `onElement`, an accumulator leases explicitly and is named as the holder; emitting an `AutoCloseable` transfers ownership; a borrowed host object is wrapped |
| Expression classloader (review 2) | **Aggregate delegating loader** over the per-directory loaders (returns the defining scope's `Class`, raises ambiguity), plus the explicit jar union for the compiler; one mirror over the aggregate |
| Duplicate `@Reflect` names (review 2) | **Resolution-time ambiguity**, not a boot error; plugin ids, reader identities and notation paths stay boot errors |
| Plugin `@Service` validation (review 2) | **Per context**: an unsatisfied plugin contribution is *unavailable in this workspace*, named; kzen's own generated registry keeps boot validation |
| Host facade, root uniqueness, bean order, path semantics (review 2) | `Class<?>`-keyed `KzenAutoHost` builder; the runtime claims live real-path work roots; lexical bean property order with stated precedence; null intermediate → null leaf and keep the row, empty list → zero rows |
| ITCH storage model (user, review 3) | **Symbol-partitioned derived store** built by one sequential decode (~~order-ref → symbol map~~ — routing key corrected to Stock Locate by review 4, below; market-wide messages once in a day-wide partition; feed ordinal tie-break; persisted weights; atomic publish; fingerprint + format version); one materialized `SymbolDay` is the closeable analytical unit |
| E9 adoption, tombstones, owner set, teardown (review 3) | Adopt at the **run-scoped send**, never `lift` (a process-wide singleton with no run) — review 4 adds the source-ingress boundary, below; a closed identity is a **weak tombstone** (absorbed into the process-level registry by review 4) and re-adoption is the named use-after-close error; the owner is an **immutable set**; force-close runs in `JobRun`'s `finally` after the existing `coroutineScope` join |
| E9 diagnostics (review 3) | **Proportional**: counts by holder in progress, bounded per-item detail on demand, a stall *warning* on the deadlock monitor's no-progress clock at a lower non-failing threshold |
| Aggregate loader precedence (review 3) | **Application classpath wins, parent-first** (each folder loader is parent-first already; a peer rule would break identity with the mirror); ambiguity checked among folder scopes only; a folder class shadowed by the app classpath is a named warning; tested with an app / folder collision |
| Global discovery vs contextual availability; capability lifecycle (review 3) | Runtime state is immutable after init; "unavailable in this workspace" is a **per-context view** computed once at creation (augmented lazily per review 5, below); the runtime holds `ServiceLoader` provider **descriptors** and each context instantiates its own capability instances (already the case today) — no SPI thread-safety demand |
| E8 output-schema convention (review 3) | Default name = **full dotted path, wildcards dropped**; explicit `as` alias; duplicate names rejected; scalar leaves only; maps unnest via `[*]` with `key` / `value` in `ValueAccess.entries` order |
| ITCH partition key (review 4) | **Stock Locate**, not an order-reference map — every ITCH 5.0 message carries it; the Stock Directory catalogues locate → symbol; locate zero is the day-wide partition (spec convention), stored once, logically duplicated on load; order-reference state is per-`SymbolDay` materialization state; source + store live in a durable area outside `job/` |
| E9 adoption boundaries (review 4) | **Source ingress** for pulled items (scoped to framework-owned pull loops by review 5, below; producer lease from `next()` through lift / projection / send; releasing it without a channel lease closes) and **send** for Worker-created closeables; iterator + container closed once by identity |
| E9 cross-run ownership (review 4) | **Linear**: one run per owned identity for its lifetime, fresh instance per run, shared / cached instances are `Borrowed`; **fail-fast** via one process-level weak `NativeIdentityRegistry` (owned-by-run / closed) that absorbs the per-run tombstone; `lift` never touches it |
| Exact-origin notation discovery (review 4) | `ClassPath.from` walks ancestors and `getResource` is parent-first, so each folder scope is scanned over its own jar URLs only and read through the exact resource URL; the application scope separately; duplicate logical paths across origins = the boot error, both origins named; a scope-local `ClasspathNotationMedia` variant in kzen-lib-jvm |
| Plugin identity and test universes (review 4) | Implicit id = canonical directory name, reserved `application` id for plugin zero, manifest `id` overrides; one constructed test universe for live negative cases, a forked-JVM Gradle task for boot-error cases, no reset seam |
| Materialization-budget seam (review 4) | Core-level `MaterializationBudget.acquire(weight): AutoCloseable`, taken by `symbolDays(budget)`; unlimited no-op default (the expression route), host semaphore implementation through a `@Service` loader (the governed route); acquire before allocation, failure closes the lease, over-capacity fails before blocking; P1's margin becomes a documented multiplier |
| Canonical plain-library route (review 5) | The **store-backed `SymbolDay` route** wherever the substantive sample says "plain-library"; the raw `ItchReader` expression is a separately named raw-ingestion demonstration; the three-path test compares one named result (per-symbol trade count and shares) and implies no shared intermediate representation |
| E9 Job-result boundary (review 5) | An owned native **never escapes its run**: `ResultSinkWorker` and every other `JobDataValues.boundary` caller convert an owned value through a **run-scoped snapshot** (`JobControl.snapshot`, so the process-lifetime codec stays run-blind) — structural / scalar only, taken while the lease is held; an opaque owned native fails with a named boundary error; unowned values keep today's identity-preserving path; transferring ownership to the result rejected |
| E9 closeable alias (review 5) | A Formula's `AutoCloseable` output **transfers independent ownership by default** (the existing rule); a closeable **child** whose lifetime the parent governs is returned as `Borrowed.of(child)`, which suppresses adoption and preserves the inherited parent owner; consistency chosen over the leak / double-close trade-off, carried by the Formula KDoc and tests |
| E9 ingress scope (review 5) | Source-ingress adoption exists **only where the framework owns the pull** — `ReadWorker`, `FormulaSourceWorker` over the returned stream, the cursor-driven Java adapter; a Kotlin `produce` body, and an expression body before it returns its stream, own what they acquire until emitted or returned (send-time adoption protects it afterwards); the host route goes through the cursor-driven adapter and gets the full guarantee |
| Per-context availability learns lazily (review 5) | The context view is **initialized at creation** from explicit descriptors and **monotonically augmented** per class name (compute-if-absent) as reflective references are first resolved — safe because the context's service environment is fixed at creation; the global scope list stays immutable; a notation edit that first names such a class is an E2/E3 acceptance case |
| Failure precedence and embedded shutdown (review 5) | A processing failure stays **primary** and close failures attach as suppressed; if only closing failed the first close failure is primary. Host shutdown order: **server stop → context close (cancel + join the run) → claim release** in `close`'s `finally`; construction rollback releases a claim if initialization fails after it; encoded by the Spring `SmartLifecycle`; touches nothing process-global |

## 7. Questions put to the user — all closed (kept as the record)

- ~~Q1 — dataset.~~ **Decided: NASDAQ ITCH 5.0.**
- ~~Q2 — Java-only plugin or Kotlin?~~ **Decided: Java-only, with `BlockingReaderCapability` (and the
  cursor-driven `SourceWorker` — review 1's shape, since `Emitter` is `suspend`-only) added to the SPI.**
- ~~Q3 — retire the world-cities `ReportDefiner`?~~ **Decided 2026-09-04: keep the logic as the *simple*
  case beside ITCH's complex one, but expose it Job-only** — re-cut as a `BlockingReaderCapability`;
  `ReportDefiner` support is not carried forward (Job is to replace Report entirely).
- **Clarified 2026-09-04 — two tiers, both wanted:** (1) a plugin *implements kzen SPI interfaces*
  (data source / reader, step, Worker) — the ergonomic route; (2) *standard Java code never written for
  kzen* is usable too, less ergonomically and with an extra wrapper where needed — the absorb-external-
  functionality route. §6a.3's adapters serve tier 2; a wrapper class (tier 1 over a tier-2 library) is
  an acceptable answer where the adapters fall short.
- ~~Q6 — ratify §6a.4 as E1?~~ **D1, R5-G, D2, D3, D7 ratified 2026-09-04** (table above); the E plan was rewritten the same day.
- ~~Q7 — D9 first cut.~~ **Decided 2026-09-04:** the full list in §6a.3 item D9 — ordinary classes by
  convention (no wrapper), enums, `Set`, per-class token cache, recursive references, and the
  path-projection / unnest Worker for object graphs.
- ~~Q8 — where does the allow-list live?~~ **Moot** — no allow-list (D8 dropped).
- ~~Q4 — analysis logic in plugin Workers, or in notation over generic Workers?~~ **Decided 2026-09-04
  (review 1's answer, adopted):** stateful analysis stays in thin plugin Workers over the plain core; no
  generic "fold by key" Worker until a second domain shows the same need — ordering, eviction, spilling
  and checkpoint semantics make it much larger than the market case suggests.
- ~~Q5 — name.~~ **Decided: `kzen-sample-embed-spring`** (review 1: not architectural; keep the user's
  name). A new sibling and an `includeBuild` in the umbrella like `kzen-sample-plugin`.

## 8. Recorded, not proposed

- **`RunAdmission` inside kzen.** Further from needed after E9 — governance rides on item lifetimes
  (§5.3). If whole-run admission ever has to cover runs the host cannot see, the only sound
  design is *deferred launch* with a queued `LogicStatus` state: every controller entry point is
  `@Synchronized`, `settleAfterDrive` fires at every pause boundary (so "release on settle" is wrong), and
  five sites launch a run. Blocking in `LogicHandler` or on the driving executor were both considered and
  rejected.
- **`ProviderDataSource` + minted `DataSourceId`.** The design-time upgrade to `SourceWorker` (columns without
  executing, units/parts addressing, `ReadPartWorker` composability). Its first question is lookup wiring:
  `dataOpenerLookup` is registered eagerly while `GraphInstanceCache` is a memoized provider declared after
  it. Closes DM11 / O15 / the `DataSourceId` KDoc together when it lands.
- **Ktor servlet-engine mounting** instead of a loopback proxy; **E6 multi-run** per context (the host runs
  N contexts instead); embedding the launcher UI; any change to `kzen-shell`.
- **Surfaced defects (CC-07):** `System.gc()` on every plugin definer query in `PluginDocument`;
  kzen-auto-jvm shipping a `logback.xml` that any consumer inherits; kzen-launcher `AGENTS.md` describing
  `work/` as inside the project home when `WorkUtils` resolves it to the parent; kzen-project `AGENTS.md`
  naming a `CommonServer.kt` that does not exist.

## 9. Gates — resolve before dependent implementation, record either way

These are executable sessions and acceptance gates, not prerequisites for writing the plan.
G1–G7 are the host spike; G8 is the baseline build; G9/G10 are E2 acceptance. P1 starts in the
plain core before host/plugin integration and is repeated on the finished routes. The session
plan's README maps each gate to its owner. No gate is recorded as passed by this document change.

| # | Question | How |
|---|---|---|
| G1 | Which Spring Boot GA runs on JDK 25 with plain-jar packaging (`copy-dependencies` + `Class-Path` manifest, no repackage)? | throwaway spike in `$env:TEMP` |
| G2 | Do Spring's BOM and kzen-auto-jvm's Ktor / Netty / Guava converge under Maven? CIO keeps Netty inert | spike |
| G3 | Does `ClasspathNotationMedia` see kzen's and the plugin's `notation/**` under plain jars? | spike — expected yes |
| G4 | kzen-auto-jvm as a library: its `logback.xml`, the JS bundle resource name for `jsModuleName` | spike |
| G5 | `ReflectiveClassMirror` resolves a *Java* `@Reflect` Worker from the plugin jar with `-parameters`, and a Kotlin glue class with a Java `@Service` type | spike |
| G6 | `ServiceLoader` picks up the plugin's `ReaderCapability` inside a context created by the host (context classloader at creation) | spike |
| G7 | SSE survives `StreamingResponseBody` on Tomcat unbuffered | spike; fallback `SseEmitter` for that one path |
| G8 | Does anything in the five siblings use a Java-26-only API? | the retarget itself |
| ~~D1~~ / D2 | §6 — D1 moot (ITCH chosen, no IEX reader); D2 is the README's terms note | vendor docs |
| G9 | Aggregate loader: one expression over two plugin directories compiles, a mirror-built instance passes an identity-sensitive call, a name in two folder scopes reports ambiguity, an application-classpath / folder collision resolves to the application copy everywhere and is listed as shadowed (review 3), and the expression survives a second context (review 2) | E2 acceptance test |
| G10 | Exact-origin notation: with two folder plugins installed, the application's bundled notation is discovered once, a folder / application collision on one logical path is reported with both origins and never read from the parent, and a folder's documents read back byte-identical to the jar entry (review 4) | E2 acceptance test |
| P1 | On one real day: sequential decode throughput and heap; derived-store build time/disk size; per-symbol replay; **native allocation separately from peak/retained heap for the persistent book/history, order indexes and reconstruction temporaries**; weight-estimate margin and host multiplier; largest symbol-day; native release and leak diagnostics; final pipeline occupancy including actual channel capacities — is the governor visible and the representation practical? | early core-only measurement, then integrated confirmation |

## 10. Implementation plan

The session files in [`../plans/in-process-hosting/`](../plans/in-process-hosting/README.md)
replace this document's candidate phase outline. E2/E3/E7/E8/E9 retain their design authority in the
extensibility plan; the new directory splits their execution into sessions alongside the hosting and
sample work. The broad outline below is historical context only; the session tracker defines the
actual dependencies, early measurement and acceptance gates.

1. Java 25 baseline across the release train + republish — the hard prerequisite for everything, including
   the *existing* sample plugin.
2. Throwaway spike answering G1–G7 (no kzen code, answers recorded here).
3. Per-context work roots (no `logDir`; created → `toRealPath()` → claimed on the runtime, duplicates
   fail fast, released after server stop and run join in that order, with construction rollback
   [review 5]); `KzenAutoHost` with its `Class<?>`-keyed builder;
   `BlockingReaderCapability` + cursor-driven `SourceWorker` — three small kzen-auto sessions, each
   defensible alone.
4. **E2/E3 per §6a** (plugin = loader; `KzenAutoRuntime`; folder discovery; `ServiceLoader` + notation
   per loader; one mirror over the aggregate loader; explicit compilation classpath; per-context plugin
   service availability; reduced diagnostics) and **E9** (closeable streams and items — explicit leases)
   — the kzen-side arc the sample rides on; E2 is L and the riskiest item here. E7/E8 (typed plain
   objects, object-graph paths) run beside it. The three contracts review 2 asked to settle before
   E2/E9 are handed to an implementer — lease ownership, aggregate loader + compilation classpath,
   resolution-time ambiguity — are written into the E plan, as are the smaller ones (host builder, root
   uniqueness, bean order, path semantics), review 3's closing details (owner set, teardown order,
   proportional diagnostics; parent-first precedence, per-context availability view, per-context
   capability instances; E8 output names), and review 4's boundary corrections (source-ingress
   adoption beside send; linear cross-run ownership through one process-level weak identity registry;
   exact-origin notation discovery; directory-name plugin identity; the constructed-universe /
   forked-task test split), and review 5's closing details (a run-scoped result snapshot so no owned
   native escapes a run; `Borrowed` for a cascaded closeable child; ingress scoped to the framework's
   pull loops; a processing failure primary over close failures; a lazily augmented availability
   view).
5. `kzen-sample-plugin`: **core** module (reader, sealed message records, the locate-partitioned
   derived store with its symbol catalog, `MaterializationBudget`, `SymbolDay` materialization, book
   fold) + **adapter** module; durable data area outside `job/`; fixture writer + tests;
   the `BlockingReaderCapability` route; the **canonical** store-backed expression route over
   `SymbolDay` batches (E9) plus the raw-reader ingestion demonstration [review 5]; bundled
   `ItchDay` Job; verified standalone in kzen-project from a
   plugin folder (P1 measured here) — through the **plugin compatibility test kit** (review 1: a reusable
   entry point in `kzen-auto-plugin`'s test fixtures that runs any plugin directory through loader
   creation, discovery, reflective construction, expression visibility, duplicate detection and
   expected diagnostics).
6. `kzen-sample-embed-spring`: scaffold, workspaces, proxy, a semaphore-backed `MaterializationBudget`
   behind a `SymbolDayLoader` service (fresh `SymbolDay` per run), host services reached through the
   cursor-driven source adapter [review 5], a `SmartLifecycle` encoding server stop → context close →
   claim release, portlet; **separate acceptance tests per outcome** (review 1): plugin
   in standalone kzen; host-object access; two-workspace isolation; three-path equality on the fixture
   (per-symbol trade count and shares);
   real-day pressure — never one large test whose success cannot be interpreted.
7. Docs-to-truth: Java 25 in the toolchain sections; "process-per-project is the shell's default, in-process
   hosting is supported through `KzenAutoHost`"; `SourceWorker` and `ReaderCapability` named as the two
   code-as-source extension points; the plugin README rewritten around the new content.

## 11. Settled

- **[decided]** kzen never names a host; every seam has a standalone default.
- **[decided]** Unit of embedding is `KzenAutoContext` + `ktorMain` per workspace over a loopback proxy;
  the host replaces `kzen-shell`; CIO engine.
- **[decided]** Plain jars; Java 25 bytecode target; Spring MVC `@RestController` proxy.
- **[decided]** Memory governance is host-side, inside the host's own closeable objects; kzen's only
  obligation is E9's close discipline; no admission seam (a proxy-level whole-run permit is optional).
- **[decided 2026-09-04, review 1 — the four contracts a plan must state]** (1) one externally
  configured, JVM-global, startup-pinned extension universe; (2) context-owned workspace state and work
  roots; (3) host-owned synchronization, memory governance and logging, with no Spring concepts in kzen;
  (4) discovery-based diagnostics, not an exhaustive class inventory or reflective boot validation.
- **[decided]** The domain enters a Job by `SourceWorker` (host objects) and `ReaderCapability` (files);
  `ProviderDataSource` is deferred.
- **[decided]** The dataset is real exchange order-level data; no real data is ever committed; a seeded
  synthetic fixture in the same binary format covers tests.
- **[decided]** The market-data logic lives in `kzen-sample-plugin`; the Spring sample depends on it and adds
  only what is embedding-specific.
- **[decided 2026-09-04]** NASDAQ ITCH 5.0; Java-only plugin (core + adapter modules);
  `BlockingReaderCapability` and a cursor-driven `SourceWorker` in the SPI.
- **[decided 2026-09-04]** The plugin system is reworked to be general and simple through the E arc:
  E1 ratified, E2/E3 re-elaborated, E7/E8/E9 added (§6a.4).
- **[decided 2026-09-04, review 2]** Item ownership is a lease ledger (implicit per callback in the
  framework's batch loops, explicit for retention, holder = Worker location); the expression classpath
  is one aggregate delegating loader plus the explicit plugin-jar union; a `@Reflect` name in two scopes
  is a resolution-time ambiguity; a plugin's `@Service` needs are validated per context and surfaced as
  unavailable, never blocking; work roots are claimed process-wide; bean property order is lexical.
- **[decided 2026-09-04, review 3]** The ITCH "index" is a symbol-partitioned derived store and one
  materialized `SymbolDay` is the closeable analytical unit; E9 adopts at the run-scoped send, tombstones
  closed identities weakly, carries an owner set, force-closes after `JobRun`'s scope join, and warns on
  stalls from the deadlock monitor's clock; E2's aggregate loader is parent-first with the application
  winning, availability is a per-context view, capabilities are per-context instances; E8's output
  names are the full dotted path with aliases.
- **[decided 2026-09-04, review 4]** The derived store partitions by Stock Locate with a symbol
  catalog, locate zero as the day-wide partition, and order-reference state confined to `SymbolDay`
  materialization; the source and store live in a durable area outside `job/`; E9 adopts pulled items
  at source ingress and Worker-created ones at send, and enforces linear cross-run ownership through
  one process-level weak identity registry; E2's notation discovery is exact-origin, a plugin's implicit
  id is its directory name, and boot-error tests run in a forked task against their own universe; the
  sample core exposes a host-neutral `MaterializationBudget`, unlimited by default and
  semaphore-backed in the Spring host.
- **[decided 2026-09-04, review 5]** The store-backed `SymbolDay` route is the canonical plain-library
  route and the raw reader a separately named demonstration, agreement measured on per-symbol trade
  count and shares; an owned native never escapes its run (run-scoped structural snapshot at every
  result / trace / preview boundary, or a named failure); a closeable child a Formula returns is
  `Borrowed`, a new closeable transfers; source-ingress adoption only where the framework owns the
  pull, the author owning the pre-emit interval otherwise; a processing failure is primary over close
  failures; the per-context availability view is initialized at creation and augmented lazily; embedded
  shutdown is server stop → context close → claim release, with construction rollback.
- **[decided 2026-09-04]** Off-heap symbol message data plus a heap graph using persistent data
  structures for book history and order lifecycles; `SymbolDay` lifetime, budget accounting and leak
  detection are specified in §5.2.1. Blocking acquisition handoff and actual channel occupancy are
  E9 acceptance requirements (§6a.3).
- **[decided 2026-09-04]** Q1–Q8 all closed (§7). The gates in §9 are assigned to implementation
  sessions; none is implicitly passed by planning.
