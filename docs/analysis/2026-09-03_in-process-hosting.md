# In-process hosting of kzen, and a sample that is worth analyzing

> **Status: analysis, not scheduled.** Started 2026-09-03 as a design conversation about hosting kzen
> *inside* a foreign JVM; reworked 2026-09-04 after the host's real constraints landed and the scope
> moved from "a Spring sample with a synthetic FIX domain" to "a substantive `kzen-sample-plugin` over
> real market data, wrapped by a Spring host". An earlier draft of this document was written as a
> phased plan (HS1–HS9) — that was premature. Nothing here is on the master ledger; the candidate
> phase outline at the end is what a plan would start from once the open questions are answered.
> Decisions are marked **[decided]** / **[open]**; per CC-20 no line numbers are cited.
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
> the in-process hosting seams and the two samples remain analysis.

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
| `WorkUtils.sibling` is a static `../work` off CWD; `processSignature` is per-process; `JobWorkPool` boot-sweeps `job/`, so a second context deletes the first's live scratch | `KzenAutoConfig.workRoot` / `logDir` with CLI args; `WorkUtils` becomes a context-owned instance with a per-context signature | yes — a limitation of kzen-auto in its own right |
| `logs/` is CWD-relative in the context and in kzen-auto-jvm's bundled `logback.xml` | config-driven dir; a host sets `logging.config` | yes |
| `GraphEnvironment` is a hardcoded builder; no host can reach a `@Service` parameter with its own object | `KzenAutoHost(services: Map<ClassName, Any>)` on `KzenAutoContext.create`, merged after kzen's entries, collision fails fast (CC-08) | yes — completes the KDoc's stated intent |
| No admission seam around a run; every `ServerLogicController` entry point is `@Synchronized` and non-suspend, called from `LogicHandler` inside `runBlocking` | **not needed in kzen** — the host gates at its own proxy (§5.3) | n/a |
| `DataOpenerLookup` ignores `DataRef.source`; `DataSourceId` is never minted | **not a blocker** — `SourceWorker` and `ReaderCapability` cover both ways in; `ProviderDataSource` stays the deferred design-time upgrade (DM11 / O15) | n/a |
| `kzenAutoInit` sets `java.awt.headless`, arms `exitProcess`, registers a shutdown hook | accepted — a host calls `create` + `ktorMain` directly | n/a |
| `ReflectionRegistry.global` / `GlobalMirror` / `ServiceEnvironmentValidation` are process-global | accepted — all workspaces in one host share one module set and one `KzenAutoHost` | n/a |
| Notation root is a CWD heuristic | already overridable via `KzenAutoConfig.moduleRoot` | — |

Three kzen-auto changes, all small, all defensible without any host existing: the Java 25 baseline,
per-context work roots, and `KzenAutoHost`. Everything else is host-side.

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
  bundled Job notation                     MemoryGovernor at the proxy
                                           host services → KzenAutoHost → @Service Workers
```

### 5.1 kzen-auto — three generic seams **[decided in shape]**

Exactly the three rows of §3 marked generic: Java 25 baseline; `KzenAutoConfig.workRoot` / `logDir` with a
context-owned `WorkUtils`; `KzenAutoHost(services)` merged into the `GraphEnvironment`. Nothing else. Each
has a standalone default `KzenAutoMain` uses unchanged; none names a host.

One SPI question sits beside them — **§6 gap C** (Java-implementability of the `suspend` reader methods).

### 5.2 `kzen-sample-plugin` — from toy to the substantive piece **[decided in shape]**

The plugin becomes the place where the market-data logic lives, so that it works in *any* kzen (standalone
kzen-project, kzen-shell-spawned, or embedded), not only in the Spring host:

- **`ItchReaderCapability`** (+ `ReaderProbeCapability` keyed on the file's first bytes / `.NASDAQ_ITCH50`
  name) registered through `META-INF/services`. Each message becomes one record `DataValue`: message type,
  timestamp (ns since midnight), order reference, symbol, side, shares, price, match number, MPID.
  Reader config: symbol filter, message-type filter, time window — so the same file serves a small Job and
  the pressure run.
- **Domain model** (Java): `Instrument`, `Order` (with the replace chain — ITCH `U` links old and new
  reference numbers), `Execution`, `Trade`, `BookLevel` / `Book`, and a **book-reconstruction library** that
  folds the message stream into per-symbol book state and can emit snapshots at a cadence.
- **Analysis Workers** (`@Reflect`, `@Service`-free): `ItchBookSnapshotWorker` (stream → top-N book
  snapshots per symbol per interval), `ItchOrderLifecycleWorker` (stream → one row per order with fill
  ratio, resting time, replace count). These are what "push the reporting capabilities" — they hold state
  per symbol across a whole day, which is the memory profile the governor is for.
- **Bundled notation** under `notation/auto-jvm/kzen-sample-plugin/…`: archetypes for the Workers and one
  ready-made Job (`ItchDay.yaml`: File worker over the day file → lifecycle Worker → aggregate by symbol
  and hour → CSV). Discovered off the classpath like kzen-project's samples.
- **Test tree**: the seeded synthetic ITCH writer and exact-assertion tests over it.
- The existing `WorldCitiesPopProcessorDefiner` **[open, §7 Q3]**: keep beside the new code as the only
  `ReportDefiner` example, or retire it.

### 5.3 `kzen-sample-embed-spring` — the host, and the *second* way in **[decided in shape]**

Depends on `kzen-sample-plugin` as an ordinary Maven dependency, so the reader, domain and Workers arrive
on the classpath and register themselves. What the host adds is everything that is *embedding-specific*:

- **Workspaces.** `kzen.workspaces[]` in `application.yaml`; each is one `KzenAutoContext` + one CIO
  server on a loopback port, under `SmartLifecycle`. Two in the sample (`trading`, `risk`) so isolation is
  proven, not assumed. The launcher UI is not embedded — the host's portlet page *is* the workspace list.
- **Proxy.** `@RequestMapping("/kzen/{workspace}/**")` returning `StreamingResponseBody`, JDK `HttpClient`
  with `BodyHandlers.ofInputStream()`, kzen-shell's header rules, `spring.mvc.async.request-timeout=-1`,
  flush per chunk (SSE).
- **Admission at the proxy.** A `MemoryGovernor` permit is taken when a request to `…/logic/startRun`
  passes and released when `…/logic/status` reports the run settled (timeout backstop). Covers every
  HTTP-initiated run including the Run button in the kzen UI. Coupling to kzen's URL shape is already
  implied by proxying at all. What it cannot see — programmatic starts, a run's memory profile up front —
  is why a kzen-side `RunAdmission` remains a *possible* later seam, recorded in §8, not proposed.
- **The host's own domain services.** The host loads a day (through the plugin's reader) into its own
  in-memory services — `OrderBookService`, `TradeRepository` — exposes them on its own `@RestController`s
  for its own UI, and hands them to kzen through `KzenAutoHost.services`. A Kotlin-glue
  `@Reflect HostTradeSourceWorker(@Service TradeRepository)` extends `SourceWorker` over them.

**Where the two mechanisms overlap, and why both belong.** The same trades reach a Job two ways:

| Way in | Mechanism | Works where | Proves |
|---|---|---|---|
| file → `ItchReaderCapability` | plugin SPI, `ServiceLoader` | any kzen | a third-party format and analysis logic, portable |
| live host object → `@Service` `SourceWorker` | `KzenAutoHost` | embedded only | the host's *own* object graph is analyzable in place — the migration story |

They are not redundant: the first is what the plugin mechanism is for; the second is what in-process
hosting is for. And they give the e2e test its strongest assertion for free — **the two paths must
agree**: a Job over the file and a Job over the host's repository produce the same per-symbol aggregate.
That replaces the earlier draft's "seeded generator → exact equality" with a cross-check over real data.

## 6. Gaps found while checking — the ones that need a decision

- **A. `ReaderCapability` through `PluginDocument`.** The runtime jar-path loader scans only for
  `ReportDefiner`, and `ReaderCapabilityRegistry` is built once per context. A jar on the *classpath* is
  fine (the sample's case); a jar added *at runtime* via a Plugin document contributes no reader.
  **Superseded by §6a** — the user wants the plugin system itself reworked, not this one path patched.
- **B. Java 25 and the plugin.** `kzen-sample-plugin` already compiles with `maven.compiler.release=25`,
  but against `kzen-auto-plugin` bytecode at 26 — it builds and cannot run on 25. The retarget is the
  first thing to do regardless of anything else here.
- **C. The reader SPI is not Java-friendly. [decided 2026-09-04, user: add the adapter]**
  `ReaderCapability.open` / `inspect` and `SourceWorker.produce` are `suspend`. A Java class *can*
  implement a `suspend` interface method (accept the `Continuation` parameter, return the value
  directly) but it is boilerplate a third-party author should not have to know. `kzen-auto-plugin`
  gains a `BlockingReaderCapability` (abstract class: non-suspend `openBlocking` / `inspectBlocking`,
  the `suspend` pair implemented once on top) and, for the same reason, a blocking `SourceWorker`
  variant for Java Workers. Generic SPI improvements justified on their own terms — the SPI's only
  sample is Java. The plugin stays Java-only.
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
edits". It has been waiting since July on **E1, a ratification session that needs the user** (D1–D6 +
gate R5-G). The user saying "perhaps now is the right time" is that session. What follows is what this
analysis adds to E1's table, having read the code since.

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
   `KzenAutoConfig` / `--plugin.root=`), loaded into one `URLClassLoader` per directory at **boot**, parent
   kzen-auto-jvm's loader. A set of related jars is the normal case; shading stops being required. The
   application classloader is plugin zero. Restart to upgrade (R5-G's recommended verdict; the jar-lock
   problem disappears with boot-time pinning because nothing ever tries to replace a loaded jar).
2. **Per loader, three contribution channels, all existing:**
   - `ServiceLoader` for SPI capabilities — `ReaderCapability` (and probe / authoring), and **`ReportDefiner`
     moves here too**, retiring `plugins.yaml`'s class list;
   - a `ReflectiveClassMirror(loader)` registered on `GlobalMirror` — `@Reflect` classes become
     constructible (Workers, steps, vertices, prototypes, data sources), `@Service` parameters resolved from
     the `GraphEnvironment`, R4 boot validation covering them for free;
   - bundled `notation/**` merged like kzen-project's — archetypes, ribbon tools, ready-made documents.
3. **A manifest only for what cannot be discovered**: `META-INF/kzen/plugin.yaml` with a plugin id and
   version (for diagnostics and the §6a.3 allow-list), nothing else mandatory.
4. **`PluginDocument` becomes a read-only view** of what loaded and what failed (E3's per-definer
   diagnostics), not the loading mechanism. Jar upload (D3) is dropped: a plugin folder is the install.

This is E2 + E3 with D2 answered "per directory", D3 answered "no", and two additions E2 does not have
today: `ServiceLoader` capabilities per plugin loader, and the app classloader treated as a plugin.

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
  its classpath** — E2 must thread the plugin loader in (`ScriptKotlinCompiler` derives its classpath from
  the loader, so a `URLClassLoader` just works); and the static record shape, next.
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
     public fields are fields; order = declaration order then alphabetical (reflection guarantees neither);
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
     refused (lists only); accept as an unordered Listing — **XS**; `Sequence` / `Iterator` stay refused
     as *values* (only an expression result streams); (c) a **path-projection / unnest Worker** — Filter
     and Formula already see the whole native object in Kotlin (`it.executions.sumOf { e -> e.qty }`
     works now), but aggregate and the CSV writer need flat columns: a Worker taking paths
     (`instrument.symbol`, `executions[*].price`) that yields columns and explodes a nested list into one
     row per element, with a design-time path picker over the contract — **M**. This is the one genuinely
     new Worker for object-graph reporting.

  Nothing here dispatches on a library's class name (CC-17): records, data classes, lists and scalars are
  JDK/Kotlin capabilities.

**What this means for the sample plugin (§5.2 revised).** The ITCH parser, domain model and book library
are written as a **plain Java library with zero kzen imports** — `ItchReader implements Iterable<ItchMessage>`
over a `Path`, `ItchMessage` a Java record, `BookBuilder` a plain fold. Then two thin layers over it,
demonstrating both routes: (a) the *first-class format* route — a `BlockingReaderCapability` + probe +
authoring, so the File worker sees `.NASDAQ_ITCH50` files with detection and config UI; (b) the
*plain-library* route — no plugin code at all, a notation document whose expression source is
`ItchReader(Path.of(file))` and whose columns come from the `ItchMessage` record. The e2e assertion that
both routes agree (§5.3) extends naturally to three paths: file-through-reader, plain-library-through-
expression, and host-object-through-`@Service`.

**Limits, stated up front.** The expression route has no probe/detection and no config UI beyond the
expression itself; it is the *entry* route, and `ReaderCapability` is what a format graduates to. Nothing
here touches JS — a plain-library object gets the generic editors of `2026-08-21_extension-points.md`
§2.1, which is the intended default.

### 6a.4 What E1 now has to ratify (this analysis's amendments to its D-table)

| E1 item | Recommendation as amended |
|---|---|
| D1 plugin module registration | **Ratified 2026-09-04:** yes, per loader: mirror + `ServiceLoader` + bundled notation; **KSP never required** (Java has none); a KSP `ModuleReflection` may add ergonomics when present |
| R5-G loader lifecycle | **Ratified:** boot-time pinned, restart to upgrade — the jar-lock objection dissolves because a loaded jar is never replaced |
| D2 isolation unit | **Ratified:** one loader per plugin directory (jar set); no plugin-to-plugin dependency for now |
| D3 jar upload | **Ratified as "not now":** a folder is the install; `PluginDocument` becomes the diagnostics view. **Do not preclude upload** — keep "a plugin = a directory the loader is pointed at", so an uploaded jar set can later be materialized into such a directory |
| D4 `ObjectRegistry` | **Moot** — `ObjectRegistryScan` is no longer in the tree (removed in the Job data-source work); E5 closes with a doc check |
| D7 plugin client UI | **Ratified:** out of scope; declarative editors only |
| ~~new D8~~ allow-listed plain classes | **Dropped** — the expression Workers already do this (§6a.3); the only work is threading the plugin loader into the expression compiler (part of D1/E2) |
| **D9** class-model mapping | **Ratified 2026-09-04.** Mostly shipped (records / data classes / List / Map / scalars, recursive, lazy navigation). First cut: design-time shape via the adapter registry (S); enums (XS); ordinary-class shape by convention, no wrapper required (S); per-class native-token cache (XS); `Set` as Listing (XS); recursive type references (M); path-projection / unnest Worker + path picker (M); P1 measurement |
| D10 app classloader as plugin zero | **No decision needed** — it is an implementation rule for E2 (one discovery code path over every loader, the app loader included), recorded so it is not forgotten |

## 7. Open questions for the user

- ~~Q1 — dataset.~~ **Decided: NASDAQ ITCH 5.0.**
- ~~Q2 — Java-only plugin or Kotlin?~~ **Decided: Java-only, with `BlockingReaderCapability` (and a
  blocking `SourceWorker` variant) added to the SPI.**
- ~~Q3 — retire the world-cities `ReportDefiner`?~~ **Decided 2026-09-04: keep the logic as the *simple*
  case beside ITCH's complex one, but expose it Job-only** — re-cut as a `BlockingReaderCapability`;
  `ReportDefiner` support is not carried forward (Job is to replace Report entirely).
- **Clarified 2026-09-04 — two tiers, both wanted:** (1) a plugin *implements kzen SPI interfaces*
  (data source / reader, step, Worker) — the ergonomic route; (2) *standard Java code never written for
  kzen* is usable too, less ergonomically and with an extra wrapper where needed — the absorb-external-
  functionality route. §6a.3's adapters serve tier 2; a wrapper class (tier 1 over a tier-2 library) is
  an acceptable answer where the adapters fall short.
- ~~Q6 — ratify §6a.4 as E1?~~ **D1, R5-G, D2, D3, D7 ratified 2026-09-04** (table above). Remaining
  before the E plan is rewritten: **Q7** below.
- ~~Q7 — D9 first cut.~~ **Decided 2026-09-04:** the full list in §6a.3 item D9 — ordinary classes by
  convention (no wrapper), enums, `Set`, per-class token cache, recursive references, and the
  path-projection / unnest Worker for object graphs.
- ~~Q8 — where does the allow-list live?~~ **Moot** — no allow-list (D8 dropped).
- **Q4 — analysis logic in plugin Workers, or in notation over generic Workers?** §5.2 proposes stateful
  Workers in the plugin (book reconstruction cannot be expressed with today's generic Workers). If a
  generic "fold by key" Worker is wanted in kzen instead, that is a kzen feature and out of scope here.
- **Q5 — name.** `kzen-sample-embed-spring` as the user wrote it, or `kzen-sample-spring` from the earlier
  draft. Either way it is a new sibling and an `includeBuild` in the umbrella like `kzen-sample-plugin`.

## 8. Recorded, not proposed

- **`RunAdmission` inside kzen.** If admission ever has to cover runs the proxy cannot see, the only sound
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

## 9. Gates — answer before planning, record either way

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
| D1 / D2 | §6 | web / vendor docs |
| P1 | Throughput of a `DataInputStream` ITCH reader on one real day, and the heap of a full-day book reconstruction across all symbols — is it actually heavy enough to make the governor visible? | measure on the real file, once |

## 10. Candidate phase outline (input to a future plan, not a plan)

1. Java 25 baseline across the release train + republish — the hard prerequisite for everything, including
   the *existing* sample plugin.
2. Throwaway spike answering G1–G7 (no kzen code, answers recorded here).
3. Per-context work / log roots; `KzenAutoHost`; `BlockingReaderCapability` + blocking `SourceWorker` —
   three small kzen-auto sessions, each defensible alone.
4. **E1 ratified → E2/E3 re-elaborated per §6a** (plugin = loader; folder discovery; `ServiceLoader` +
   mirror + notation per loader; manifest allow-list; JDK-type adapters). This is the kzen-side arc the
   sample plugin then rides on; it is L and the riskiest item here.
5. `kzen-sample-plugin`: plain Java ITCH library (reader, records, book fold) + fixture writer + tests;
   the `BlockingReaderCapability` route; the manifest + notation zero-customization route; bundled
   `ItchDay` Job; verified standalone in kzen-project from a plugin folder (P1 measured here).
6. `kzen-sample-embed-spring`: scaffold, workspaces, proxy, governor, host services + Kotlin glue Worker,
   portlet; `@SpringBootTest` driving `startRun` / `status` / trace query through the proxy, the
   three-paths agreement assertion, admission, isolation, SSE.
7. Docs-to-truth: Java 25 in the toolchain sections; "process-per-project is the shell's default, in-process
   hosting is supported through `KzenAutoHost`"; `SourceWorker` and `ReaderCapability` named as the two
   code-as-source extension points; the plugin README rewritten around the new content.

## 11. Settled

- **[decided]** kzen never names a host; every seam has a standalone default.
- **[decided]** Unit of embedding is `KzenAutoContext` + `ktorMain` per workspace over a loopback proxy;
  the host replaces `kzen-shell`; CIO engine.
- **[decided]** Plain jars; Java 25 bytecode target; Spring MVC `@RestController` proxy.
- **[decided]** Admission is host-side at the proxy; no kzen seam.
- **[decided]** The domain enters a Job by `SourceWorker` (host objects) and `ReaderCapability` (files);
  `ProviderDataSource` is deferred.
- **[decided]** The dataset is real exchange order-level data; no real data is ever committed; a seeded
  synthetic fixture in the same binary format covers tests.
- **[decided]** The market-data logic lives in `kzen-sample-plugin`; the Spring sample depends on it and adds
  only what is embedding-specific.
- **[decided 2026-09-04]** NASDAQ ITCH 5.0; Java-only plugin; `BlockingReaderCapability` in the SPI.
- **[decided in direction 2026-09-04]** The plugin system is reworked to be general and simple, through
  the existing E1–E5 arc; §6a.4 is the amended E1 table awaiting ratification.
- **[open]** Q3, Q6–Q8 above.
