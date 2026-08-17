# DDC — detached download content shape

> **Standalone plan** (design + elaboration in one document): there is no constituent plan behind
> this, so **archive it to the sprint README when it lands — do not delete it.** It is the only
> record of why three alternative shapes were rejected.
>
> Added **2026-08-17** on direct user request, from a `TODO` on
> `kzen-auto-jvm/.../paradigm/detached/ExecutionDownloadResult.kt:6`.
>
> **Size: S — one session.** ~12 files in `kzen-auto-jvm` only. No client change, no notation change,
> no cross-repo publish, no version bump.
>
> **Carries one standing decision beyond the refactor:** `ktor-server-test-host` enters the build as a
> test dependency (§5.1, approved by the user 2026-08-17), giving the repo its **first route-level
> tests**. Scope is held to the two download routes here; the other 22 are §6 backlog.
>
> **Revised 2026-08-17 after design review** (accepted by the user, same day): `respondDownload`
> gains a pre-commit existence guard (§2.1), and `ExecutionDownloadResult` gains construction
> ergonomics — hoisted `mimeTypeCsv` const, CSV-default `mimeType`, `ofFile` factory, and a
> deliberate `ofWriter` omission (§2.2). The const hoist adds `ReportDocument.kt` to the touched
> set (~11 → ~12 files); no other scope change.

---

## 1 Why

The TODO reads *"what is the kotlin multiplatform equivalent of InputStream? maybe use
ByteReadChannel from ktor, or ByteString from kotlinx-io"*. Investigation found the question is
aimed at the wrong problem. Three facts, each verified against the tree at `HEAD`:

**1.1 — The asymmetry the TODO implies no longer exists.** `DetachedExecutor` lived at
`kzen-auto-common/.../paradigm/detached/DetachedExecutor.kt` and was **deleted in `02716c30`**
("refactoring / cleanup", 2026-08-16). What survives is `DetachedDownloadExecutor` — an interface
with **one implementation and zero interface-typed consumers**: `KzenAutoContext.kt:225` infers the
concrete `ModelDetachedExecutor`, and `DetachedActionHandler.kt:20` declares it concretely. Its twin
(`ModelDetachedExecutor.execute`) has no interface at all. Straight **CC-10** removal, independent of
everything below.

**1.2 — `ExecutionDownloadResult` never crosses a platform boundary.** The client's entire download
contract is a **URL**: `ClientRestApi.linkDetachedDownload` (`:537`) and `linkJobDownload` (`:553`)
build an href and the browser fetches it. No `commonMain` or `jsMain` code names the type. So
"make it multiplatform" buys no cross-platform reuse today — it would only enable a *future*
`commonMain` object serving a download, the way `kzen-project-common`'s `SampleGreeting` implements
`DetachedAction`.

**1.3 — The type's shape is costing two real defects.** `InputStream` exports a resource lifetime
the type does not describe, and both consequences are live:

- **Unclosed handle.** `KzenAutoMain.kt:575` and `:589` call `ByteStreams.copy(response.data, this)`
  with no `use` — and nothing else touches `.data`. On the `IndexedCsvTable` path that is a
  `Files.newInputStream` handle released only non-deterministically. On Windows an open handle also
  pins the file against deletion, which matters for report reset.
- **A forced inversion.** `PivotBuilder.downloadCsvOffline` (`:50-110`) generates its CSV *push*-style
  but must return a *pull*-style `InputStream`, so it builds a `PipedInputStream`/`PipedOutputStream`
  pair and a raw `Thread` to bridge them. `PipedInputStream`'s default buffer is **1024 bytes** with
  `synchronized`/`wait`/`notifyAll` handoffs, while the `OutputStreamWriter` above it flushes in ~8 KB
  chunks — so every flush blocks and wakes the pair several times. The thread has no exception
  handler: a mid-export failure kills it silently and the client gets a truncated, 200-status CSV.

And the producers are not uniform. **Two of three are literally a file on disk that the caller already
holds the `Path` for**, and one of those resolves it twice:

| Producer | Shape |
|---|---|
| `IndexedCsvTable.downloadCsvOffline(dir)` `:38` | `Files.newInputStream(dir.resolve(tableFile))` — a file |
| `DetachedActionHandler.jobDownload` `:83` | resolves `tablePath`, checks `Files.exists`, then calls the above **which resolves the same path again** |
| `PivotBuilder.downloadCsvOffline(ctx)` `:50` | generated, streamed lazily |

So push-vs-pull is a false binary. The shape that fits the actual producers names both cases.

### 1.1 Rejected alternatives

Recorded because each is the obvious next idea, and the reasons are not recoverable from the code.

**(a) Keep `InputStream`, just add `.use {}`.** Fixes the leak in one line and is a legitimate
minimum. Rejected as the *end state* because it leaves `PivotBuilder`'s pipe-and-thread in place and
leaves ownership as a rule to remember rather than one the type enforces. **If this plan is ever
descoped, do this instead — it is strictly better than the status quo.**

**(b) Pure push — `suspend (OutputStream) -> Unit` for every producer.** Deletes the pipe and the
thread and makes the leak structurally impossible. Rejected because it erases file-ness from the two
file producers for no gain, and because it fuses *acquire* with *transfer*: `Files.newInputStream`
today throws inside the executor, **before** the route touches the response, so a missing table is a
clean 500; inside a writer lambda the same failure lands after the 200 and `Content-Type` are
committed, and the client gets a truncated success.

**(c) Move to `commonMain` on kotlinx-io `RawSource`.** The factually correct answer to the TODO as
literally worded — `RawSource`/`RawSink` are the KMP equivalents of `InputStream`/`OutputStream`, and
Ktor's `ByteReadChannel` is the async one. Rejected on cost against §1.2's zero benefit:
`kotlinx-io` is referenced **nowhere in the umbrella** except inside that TODO comment, so it would be
a new `commonMain` `api` dependency on `kzen-auto-common` landing in the JS klib graph and the esbuild
bundle for a type JS never touches. It would also move the notation `class:` FQN of any download
archetype — creating exactly the reciprocal keep-in-sync surface (**CC-21**) that the `FlowWiring`
stale-FQN bug came out of. **Reopening trigger:** a `commonMain` object that needs to serve a
download. Nothing does today.

**(d) Fold downloads into `ExecutionResult` via `BinaryExecutionValue`.** Kills the second interface
entirely and is already multiplatform. Rejected: it materializes the whole table in memory, and
report tables are file-backed and unbounded.

---

## 2 Design

A sealed content type alongside the existing metadata, both staying in
`tech.kzen.auto.server.paradigm.detached` (JVM):

```kotlin
sealed interface ExecutionDownloadContent {
    /** Already on disk: nothing is opened here, so there is no handle to own or leak. */
    data class OfFile(val path: Path): ExecutionDownloadContent

    /** Generated on demand, written straight to the response. */
    data class OfWriter(val write: suspend (OutputStream) -> Unit): ExecutionDownloadContent
}

data class ExecutionDownloadResult(
    val content: ExecutionDownloadContent,
    val fileName: String,
    val mimeType: String = mimeTypeCsv
) {
    @Suppress("ConstPropertyName")
    companion object {
        /** Every current producer is CSV — hoisted from ReportDocument's private copy (`:95`). */
        const val mimeTypeCsv = "text/csv"

        fun ofFile(path: Path, fileName: String, mimeType: String = mimeTypeCsv) =
            ExecutionDownloadResult(ExecutionDownloadContent.OfFile(path), fileName, mimeType)
    }
}
```

Consumed by **one** helper in `KzenAutoMain`, replacing two byte-identical route bodies:

```kotlin
private suspend fun ApplicationCall.respondDownload(result: ExecutionDownloadResult) {
    // Parse before touching the response, so a bad mimeType fails without headers set
    val contentType = ContentType.parse(result.mimeType)

    response.header(
        HttpHeaders.ContentDisposition,
        "attachment; filename*=utf-8''" + result.fileName)

    when (val content = result.content) {
        is ExecutionDownloadContent.OfFile -> {
            // LocalFileContent opens the file only at body transfer, after the 200 is committed;
            //  fail here pre-commit instead — the eager-failure property Files.newInputStream
            //  used to provide in the executor (§2.1)
            check(Files.exists(content.path)) {
                "Download content missing: ${content.path}"
            }
            respond(LocalFileContent(content.path.toFile(), contentType))
        }

        is ExecutionDownloadContent.OfWriter ->
            respondOutputStream(contentType) { content.write(this) }
    }
}
```

⚠ **As landed, the guard is hoisted ABOVE the `ContentDisposition` write** — see §7.2. This snippet sets the
header first, which leaves a failed guard answering an error status that still carries
`attachment; filename*=…`; a browser following an `<a href>` will happily save that error page as the `.csv`.
That defeats the very "clean 500" property §1.1(b) was rejected to preserve.

`LocalFileContent` is `io.ktor.server.http.content.LocalFileContent` — **verified present** in
`ktor-server-core-jvm-3.5.1`.

**Why this and not (a)–(d):** each producer says what it actually is. The file producers stay
declarative and never open a handle — Ktor does the open/copy/close, which is the one place that
already gets it right. The generated producer writes directly to the response and loses the pipe, the
thread, and the silent-failure path.

**Incidental win, worth recording in §7:** `DetachedActionHandler.actionDetachedDownload` wraps
`executeDownload` in `runBlocking` (`:69`). Today the pivot path runs `PivotBuilder.create` — which
opens file-backed stores — inside that block; with `OfWriter` (and §3.1 moving `create` into the
lambda) the handler returns a cheap descriptor and all real work happens in the response lambda. The
blocking profile on the Ktor worker is otherwise unchanged — today it parks on `ByteStreams.copy`,
after the change it generates — which is what makes §4.2's two-threads-to-one accounting hold.

### 2.1 Pre-commit existence guard

`OfFile` alone would quietly trade away the eager-failure property §1.1(b) was rejected over: today
`Files.newInputStream` throws in the *executor*, before the route touches the response, so a missing
table is a clean 500 — but `LocalFileContent` opens the file lazily at body-transfer time, **after**
status and headers are committed. `jobDownload` keeps its own `Files.exists` guard (its error names
the worker), but the flat-Report path through `ReportDocument` has no guard *except* that eager open,
and the `IndexedCsvTable` change removes it. The `check` in `respondDownload` restores the property
for every file producer, in the one consumer, keeping producers declarative. The redundancy with
`jobDownload`'s guard is deliberate: that one is the domain-level error ("No downloadable result"),
this one is the transport-level backstop.

### 2.2 Construction ergonomics

After the refactor there are exactly **two** result-assembly sites — producers return
`ExecutionDownloadContent`, and the filename is attached upstream:

- `ReportDocument.executeDownload` → `ExecutionDownloadResult(TableReportOutput.downloadCsvOffline(ctx), filename)`
  — the CSV default applies; ReportDocument's private `mimeTypeCsv` (`:95`) is **deleted** in favour
  of the hoisted const.
- `DetachedActionHandler.jobDownload` → `ExecutionDownloadResult.ofFile(tablePath, filename)`.

**`ofWriter` is deliberately omitted.** No call site constructs a writer-backed *result* directly —
`PivotBuilder` returns content and `ReportDocument` attaches the filename — so the factory would land
as dead code (same instinct as the §1.1 CC-10 removal). Reopening trigger: the first
`DetachedDownloadAction` implementor that generates its download inline; it is a two-line add then.

`mimeType` stays a `String` rather than Ktor's `ContentType`. A typed field would move parse errors
to construction time, but `DetachedDownloadAction` is an SPI-adjacent surface and a `String` keeps
implementors decoupled from `io.ktor.http` — the same coupling instinct that rejected §1.1(c).
`respondDownload` parsing before it touches the response is the compensating move.

---

## 3 What lands

All in `kzen-auto`. No client, common, notation, or plugin change.

| # | File | Change |
|---|---|---|
| 1 | `…/paradigm/detached/ExecutionDownloadContent.kt` | **New.** The sealed type above. |
| 2 | `…/paradigm/detached/ExecutionDownloadResult.kt` | `data: InputStream` → `content: ExecutionDownloadContent`; gains the `mimeTypeCsv` const, the CSV-default `mimeType`, and the `ofFile` factory (§2.2). **Replace the TODO** with the §1.2 finding: this type has no cross-platform consumer, so it stays JVM; kotlinx-io `RawSource` is the KMP equivalent if that ever changes. State the reopening trigger, not the speculation. |
| 3 | `…/paradigm/detached/DetachedDownloadExecutor.kt` | **Delete** (CC-10, §1.1). |
| 4 | `…/service/exec/ModelDetachedExecutor.kt` | Drop the `DetachedDownloadExecutor` supertype + import (`:7`, `:21`). `executeDownload` loses `override` and stays. |
| 5 | `…/report/exec/output/flat/IndexedCsvTable.kt` | `downloadCsvOffline(dir): InputStream` → **`tablePath(dir): Path`** (`:38`). Storage names its own file; it does not build a paradigm type. `Files`/`InputStream` imports likely drop. The companion fn coexists with the private *instance* `val tablePath` (`:51`) — legal, mildly shadow-y; leave both names, don't let an IDE rename "fix" it. |
| 6 | `…/report/exec/output/pivot/PivotBuilder.kt` | `downloadCsvOffline` returns `OfWriter { out -> … }` (`:50-110`). **Delete** `PipedInputStream`, `PipedOutputStream`, the `Thread`, and the manual `flush()`/`output.close()` at `:104-105` — `OutputStreamWriter(out, UTF_8).use { }` covers both. Body otherwise verbatim. |
| 7 | `…/report/exec/output/TableReportOutput.kt` | `downloadCsvOffline` returns `ExecutionDownloadContent` (`:59-69`); `FlatData` → `OfFile(IndexedCsvTable.tablePath(ctx.runDir))`, `PivotTable` unchanged in shape. |
| 8 | `…/objects/report/ReportDocument.kt` | `executeDownload` (`:163-176`) → `ExecutionDownloadResult(TableReportOutput.downloadCsvOffline(reportRunContext), filename)`; **delete** the private `mimeTypeCsv` (`:95`), hoisted to the result type (§2.2). |
| 9 | `…/api/handler/DetachedActionHandler.kt` | `jobDownload` (`:83-99`) → `ExecutionDownloadResult.ofFile(tablePath, filename)`; keeps its `Files.exists` guard — domain-level error, deliberately redundant with the §2.1 backstop. The double path resolution collapses. |
| 10 | `…/KzenAutoMain.kt` | Add `respondDownload` including the §2.1 guard; both routes (`:564-577`, `:580-591`) become one call each. **Drop the `com.google.common.io.ByteStreams` import** (`:3`) — verified unused elsewhere in the file (review 2026-08-17); it is Guava for what `InputStream.transferTo` has done in the JDK since 9, and we are on 26. |
| 11 | `…/objects/job/worker/ExploreWorker.kt` | KDoc `:38` cites `IndexedCsvTable.downloadCsvOffline` — retarget to `tablePath`. |
| 12 | `kzen-auto-jvm/build.gradle.kts` | Add `testImplementation("io.ktor:ktor-server-test-host:$ktorVersion")` by the existing Ktor block (`:72-77`). **Test scope — never ships.** See §5.1. |

### 3.1 One decision inside step 6

`PivotBuilder.create(...)` currently runs **eagerly**, before the thread starts. Moving it inside the
`OfWriter` lambda trades §1.1(b)'s acquisition-error timing for resource safety, and **inside is the
call**: `create` opens file-backed stores, and holding them open across the gap between result
construction and response streaming reintroduces exactly the ownership ambiguity being removed. The
meaningful precondition is already validated before the result is built — `ReportDocument.executeDownload`
(`:163-165`) throws on a missing run context. A pivot whose backing files are absent after a completed
run is not a reachable failure mode.

Record this in a comment at the call, not just here.

---

## 4 Two things this does *not* buy

Both were considered and neither is free. State them in the plan so a later reader does not
re-discover them as surprises.

**4.1 — No ranges; and `Content-Length` only for a client that offers no encoding.**
✅ **MEASURED 2026-08-17** — the first draft's claim was *conditionally* wrong, and the condition is the
client, not the producer. Both halves were asserted in-process (`JobDownloadRouteTest`) and re-confirmed
on a real Netty socket (§7):

| Request | `Content-Encoding` | `Content-Length` | Framing |
|---|---|---|---|
| `Accept-Encoding: gzip` | `gzip` (+ `Vary`) | **absent** | chunked |
| no `Accept-Encoding` | absent | **present, exact** | length-delimited |

So the draft's "goes out chunked with no length **however it was produced**" is false as written:
`LocalFileContent` advertises an exact length, and it is `install(Compression)` (`KzenAutoMain.kt`) that
drops it — only when the client offered an encoding. `respondOutputStream` could never advertise one, so
`OfFile` **does** buy an observable `Content-Length`, for identity clients. Every browser sends
`Accept-Encoding`, so the user-facing download is still lengthless in practice — but the kzen-shell proxy,
`curl` without `--compressed`, and any future non-browser consumer get a length they did not get before.

Ranges are unchanged: `PartialContent` is **not installed** and is not in `ktor-server-core` (it is a
separate `ktor-server-partial-content` artifact). Both properties become fully available if compression is
tuned per content type; that is a separate decision, not part of this.

**4.2 — `PivotBuilder` loses producer/consumer overlap.** Today the pipe genuinely pipelines:
generation runs on its own thread while the socket writes. `OfWriter` serializes them. This is the one
axis on which the new shape can be *slower*, and it is **not** a memory regression — push drops a whole
thread, and the current design occupies **two** threads per pivot download (the Ktor worker parked on
`ByteStreams.copy`, plus the producer) where push occupies one.

**Gate it, do not assume it.** Per the C1→C3 precedent — measure first, build only if it still hurts,
record the number either way.

✅ **GATE RESOLVED 2026-08-17 — direct write wins; no overlap is reintroduced.** 200,000 distinct pivot
rows, two aggregates, 3,268,288 bytes of CSV, both arms driving the *same* generation body over the *same*
materialized pivot in one JVM, one warm-up then three timed runs:

| Arm | Runs (ms) | Median |
|---|---|---|
| direct write (`OfWriter` → sink) | 2974 / 3123 / 3176 | **3123 ms** |
| piped thread (the shape replaced) | 3754 / 3974 / 3358 | **3754 ms** |

~17 % faster at the median, and understated: both arms pay the same constant `PivotBuilder.create` store-open
cost inside the timed region, so the transfer-topology share of the win is larger than the totals suggest.
The prediction held — a 1 KB pipe window with per-flush thread wakeups costs more than the overlap wins.

Had the after-number been materially worse, the fix would have been to reintroduce overlap *inside*
`OfWriter` — a `PipedInputStream(64 * 1024)` or a producer coroutine feeding a `Channel`, with real
cancellation and exception propagation. `OfWriter` permits this; `InputStream` *forced* it, in the cheapest
and least tunable form available.

---

## 5 Verification

- `cd ../kzen-auto && ./gradlew build` — green, from the sibling's own directory. Full suite, since
  `KzenAutoMain` and the report output path are both touched.
- **New unit tests** (there are none for the download path today — `ModelDetachedExecutorTest` covers
  only `execute`):
  - `OfWriter` invoked against a `ByteArrayOutputStream` produces the expected CSV bytes for a small
    pivot fixture — this is the branch that changes most and has never had a test.
  - `OfFile` from a completed flat run names a path that exists and whose contents match the table.
  - `PivotBuilder`'s writer closes its `PivotBuilder` even when the sink throws mid-write (the
    silent-thread-death case, now surfaceable).
- **New route tests**, via the test host approved in §5.1 — the first in the repo:
  - `GET actionDetachedDownload` on a completed Report → 200, body is the CSV, and
    `Content-Disposition` carries the `attachment; filename*=utf-8''…` form with the sanitized,
    timestamped name. The header has never been asserted. **Comment on the test:** the un-percent-encoded
    `filename*` form is technically malformed under RFC 5987 for non-ASCII names — it is safe here
    only because `FormatUtils.sanitizeFilename` collapses everything to `[a-zA-Z0-9_-]`. Say so, so
    the assertion is read as safe-by-sanitization, not enshrined as spec-correct in general.
  - **The §2.1 guard:** on a completed flat run, delete `table.csv` from the (test-owned, under
    `logs/`) run dir and re-request → the failure lands **pre-commit** (an error status, not a
    committed 200 with a truncated body). If standing that up in the test host proves heavy, cover
    the guard branch at unit level against a temp dir instead — the property is the point, not the
    vehicle.
  - `GET jobDownload` on a settled Job Explore run → 200 and correct body (the
    downloadable-after-the-run-ends property, which is `jobDownload`'s entire reason to exist).
  - `GET jobDownload` with **no persisted table** → assert the status the client actually gets today.
    `DetachedActionHandler.jobDownload:88` calls `error(...)`, so this is a bare `IllegalStateException`
    out of a route; the test records the real behaviour. **If it is an unhandled 500 with a stack
    trace, note it in §7 — do not fix it here**, it is pre-existing and out of scope.
  - **The §4.1 compression probe:** request with and without `Accept-Encoding: gzip` and record what
    comes back — `Content-Encoding`, and whether any `Content-Length` survives. This is the assertion
    that converts §4.1 from argument to fact, and it is worth writing even though it tests Ktor's
    behaviour rather than ours, because a design claim in this plan rests on it.
### 5.1 `ktor-server-test-host` — approved 2026-08-17

The first draft told this session **not** to add it. **That is reversed on the user's decision**, on
the stated condition that it be well supported and open the door to new functional assurance. Both
were checked before accepting, and the entry cost turned out to be far lower than the first draft
assumed:

- **It resolves.** `io.ktor:ktor-server-test-host-jvm:3.5.1` is present on Maven Central (HTTP 200),
  and every transitive is a Ktor module at the same version plus `kotlinx-coroutines-core`. It is
  Ktor's own official testing artifact, released in lockstep — the version can never drift from
  `ktorVersion`.
- **No production code has to move.** `fun Application.ktorMain(context: KzenAutoContext)`
  (`KzenAutoMain.kt:148`) is already **public** and already takes the context, so
  `testApplication { application { ktorMain(KzenAutoContext.forTest()) } }` stands up the **real**
  plugin stack — `ContentNegotiation`/kotlinx, `SSE`, `Compression` — and all **24** routes as
  configured. `routeRequests` stays private. `KzenAutoContext.forTest()` (`:102`) already exists and
  is already proven in the test environment by `ModelDetachedExecutorTest`.

Add as `testImplementation("io.ktor:ktor-server-test-host:$ktorVersion")` in
`kzen-auto-jvm/build.gradle.kts` alongside the existing Ktor block (`:72-77`). Test scope only —
nothing ships.

**What it opens that nothing covers today.** There are 24 routes and **zero** route-level tests; the
layer between unit tests and the blackbox suite is empty. It is genuinely new assurance, not a
duplicate of `kzen-auto-test:selfTest` — that suite spawns a tester JVM, a SUT JVM and Chrome to test
the *product*, runs `maxParallelForks = 1`, and is deliberately excluded from `build`. This runs
in-process in the ordinary `test` task and tests the *server contract*: status codes, content types,
parameter handling, `Content-Disposition` filename encoding, error-path statuses, the SSE stream, and
— directly relevant here — whether `Compression` does to `text/csv` what §4.1 claims.

**What it does not cover, and must not be trusted for.** `testApplication` runs an in-process engine,
**not Netty**. Real socket streaming, chunked transfer framing and backpressure are not exercised. For
a streaming download that is exactly the interesting part, so the test host proves the *handler
contract* and the manual smoke below still proves the *wire*. Neither replaces the other.

**Two constraints for whoever writes the first one:**

- `KzenAutoContext.forTest()` builds real file media through `GradleLocator` and must be `close()`d
  (`ModelDetachedExecutorTest` does this in a `finally`). Share **one context per test class**
  via `@BeforeAll`/`@AfterAll` — not a lazy singleton, because a context owns live resources — or
  suite time balloons.
- That context reads notation from the **source tree** and writes to `logs/`. Keep route tests to
  **read-only** routes; anything that mutates notation must go through the in-memory media path, or
  the tests will edit the working tree.

### 5.2 Scope discipline

Take the dependency in this session, but land only **the download-route tests plus the §4.1
compression probe** with it. Broad coverage of the other 22 routes is a real opportunity and is
explicitly **out of scope here** (§6) — it gets its own ledger row rather than being allowed to
sprawl an S-sized refactor.

### 5.3 Manual smoke

Still required — the DOM cannot see these, and per §5.1 the test host does not exercise the wire.
A browser must actually download:
  1. Report → run to completion → download → CSV opens, content correct, filename timestamped.
  2. A **pivot** Report → download → same. This is the changed branch; do not skip it for the flat one.
  3. Job with an Explore Worker → run → **let the run settle** → download → CSV correct (the
     after-the-run-ends property is the whole point of `jobDownload`).
  4. Server log clean, no truncated file, no exception.

---

## 6 Out of scope

- Moving anything to `commonMain` (§1.1(c)) — reopening trigger recorded there.
- Tuning `Compression` per content type, or installing `PartialContent` (§4.1).
- **Route coverage beyond the two download routes.** The test host (§5.1) makes 24 routes testable and
  22 of them stay untested here — deliberately. That backlog is real and worth its own ledger row:
  the highest-value targets are the **SSE run-status stream** (`/logic/events`, today reachable only
  by the full blackbox suite), the notation read/write commands, and error-path statuses across the
  board. **Do not start it in this session.**
- Fixing whatever status `jobDownload` returns for a missing table (§5) — record it, leave it.
- `DetachedAction` / `DetachedDownloadAction` themselves: the split is **correct and stays**, and it
  should now read as a stated rule rather than an accident — *common holds what a `commonMain` object
  can implement (`SampleGreeting`); server holds what needs a JVM stream.* Say so in
  `DetachedDownloadAction`'s KDoc, one sentence, while the file is open.

---

## 7 As-built

**Landed 2026-08-17**, one session, on a green full `kzen-auto` build (120 test classes, 0 failures).
All twelve files in §3 changed as specified, plus §6's one-sentence KDoc on `DetachedDownloadAction`;
one deviation inside `respondDownload` (§7.2). `kzen-project` / `kzen-launcher` / `kzen-shell` /
`kzen-sample-plugin` were swept for every touched symbol and reference **none** of them, so the blast
radius was `kzen-auto-jvm` exactly as predicted.

Five test files are new: `TableReportOutputDownloadTest`, `JobDownloadRouteTest`,
`DetachedDownloadRouteTest`, and two `@Reflect` fixture actions under `…/api/handler/test/`
(`StreamedCsvDownloadAction`, `MissingFileDownloadAction`).

### 7.1 The two gates, resolved

**§4.2 measure-first — direct write wins, no overlap reintroduced.** Numbers in §4.2. Method deviation
worth stating: the before/after was **not** two git revisions against a localhost client. It was a
single-JVM A/B over one materialized 200,000-row pivot, both arms driving the *identical* generation body,
the "before" arm reconstructed by handing the new `OfWriter` a `PipedOutputStream` on a raw `Thread` and
draining the `PipedInputStream` — which *is* the replaced topology, default 1 KB window and all. That is a
better-controlled comparison than across revisions (same JVM, same data, same fixture, no build variance),
and it isolates the one axis that changed. The harness was temporary and is not in the tree.

**§4.1 — the draft's claim was conditionally wrong, and §4.1 is corrected in place.** See the table there.
The short version: `Content-Length` survives for a client that sends no `Accept-Encoding`, and
`respondOutputStream` could never advertise one — so `OfFile` bought an observable property the plan
predicted it would not. Browsers always negotiate encoding, so nothing changes for the UI.

### 7.2 What the plan got wrong

**The §5 route test for `GET /action/download` "on a completed Report" is unsatisfiable as written.**
`AutoConventions.serverAllowed` is `{kzen/, auto-common/, auto-jvm/, main/}` — it excludes `test/`, so
`ModelDetachedExecutor` can never reach a `DetachedDownloadAction` declared in test notation, and the
only concrete Report documents live in `main/` (the user's working tree, off limits) or `test/`. §5 was
written as if a `test/` Report fixture would be reachable; it is not. Resolved by a route-test fixture in
a **temp module root** — see §7.3.

**The §2.1 guard is not reachable from either real route.** Both file producers guard upstream of it:
`jobDownload` has its own `Files.exists` check, and the flat-Report path is only reachable through the
executor. So the `check` in `respondDownload` is a genuine backstop with no naturally-occurring caller —
covered only via the temp-module-root fixture. Worth knowing before anyone "simplifies" it away as dead.

**§2's snippet sets `Content-Disposition` before the guard runs, and that is wrong** — found by writing the
guard's own route test, which had to note that the attachment header was still on the wire beside the error
status. A browser following an `<a href>` saves an error page as `table.csv` on the strength of that header,
which is exactly the "clean 500 vs truncated success" distinction §1.1(b) exists to protect; the guard was
buying the status back while the header gave it away. **Landed with the parse and the existence check both
hoisted above every write to the response**, so a refusal carries no download framing at all. Treated as
implementing §2's stated intent rather than as a design change.

**§2.2's `ofWriter` omission was right, and the first implementor proved it.** The reopening trigger — "a
`DetachedDownloadAction` that generates its download inline" — arrived immediately, as the
`StreamedCsvDownloadAction` test fixture. Constructing `ExecutionDownloadResult(OfWriter { … }, fileName)`
directly is two readable lines; a factory would have saved nothing. Leave it omitted.

**A pre-existing quirk the new tests pin, deliberately not fixed (CC-07).** The pivot export header renders
`headerLabel.render()` and drops `OutputPivotHeaderLabel.pivotValueType`, so one column carrying two
aggregates exports two identically-named header cells (`city,amount,amount`). Pre-existing at `HEAD`;
`TableReportOutputDownloadTest` asserts it as-is with a comment. Candidate for its own row.

**`GET /job/download` with no persisted table answers 500** (Ktor's default failure path; `error(...)` with
no `StatusPages` installed). Recorded per §5, **not fixed** — out of scope per §6.

### 7.3 Verification as landed

- `cd ../kzen-auto && ./gradlew build` — green.
- **Unit** — `TableReportOutputDownloadTest` (3): flat run resolves to the on-disk table and its bytes
  match; pivot run generates the exact expected CSV into a `ByteArrayOutputStream`; a sink that throws
  mid-write **propagates** the failure (the old detached thread swallowed it) and still releases the
  builder — proven by deleting the run dir afterwards, which Windows refuses while a handle is open.
- **Route** (the repo's first) — `JobDownloadRouteTest` (3) and `DetachedDownloadRouteTest` (2), both
  through the real `Application.ktorMain` stack via `testApplication`. Between them they cover both content
  branches, the attachment header, the §2.1 pre-commit guard, the missing-table status, and the §4.1
  compression probe.
- **Wire** — the test host is not Netty, so the `OfFile` branch was additionally exercised against a real
  server: `kzen-auto-jvm-0.30.0-SNAPSHOT.jar` on port 8099, booted in a **throwaway cwd** with
  `--module.root=` pointing at the module, so its `../work` was a temp tree and the user's live `:8080`
  dev server and real `work/` were untouched. Results confirmed the in-process assertions exactly:
  identity client → `200`, `Content-Type: text/csv`, `Content-Length: 5747`, body byte-identical;
  gzip client → `Content-Encoding: gzip`, `Vary: Accept-Encoding`, chunked, no length, decoded body
  byte-identical; missing table → `500`.
- **§5.3 manual smoke — NOT done, and it is the one outstanding item.** It needs a browser plus real input
  data and a completed run, i.e. the user's own documents; a headless agent cannot stand it up without
  writing into the working tree. The wire check above covers `OfFile` end-to-end on a real socket; what
  remains genuinely unverified is the **`OfWriter` branch over Netty** (a pivot Report download) and the
  browser's own attachment handling. Run §5.3's four steps before treating the pivot path as smoked.

### 7.4 Standing decision honoured, and what it opened

`ktor-server-test-host` entered as test scope only, and §5.1's promise held exactly: **no production code
moved.** `Application.ktorMain` was already public and already took the context.

One technique is worth carrying forward, because it turns the whole `/action/download` surface testable and
was not in the plan: `KzenAutoConfig(moduleRoot = <temp dir>)` makes `GradleLocator` scan only that temp
tree, while `ClasspathNotationMedia(exclude = main/)` still supplies the framework archetypes. So a test can
drop a `@Reflect` fixture action into `main/` **in the temp root** — inside `serverAllowed`, served by
`ReflectiveClassMirror`, colliding with nothing — and reach any detached route hermetically. It also stops
`forTest()` reading the user's live `notation/main/**`, which is what makes the `AutoTestUtils.readNotation`
race in kzen-auto's AGENTS.md possible.

Scope was held per §5.2: the other 22 routes remain untested and stay §6 backlog.
