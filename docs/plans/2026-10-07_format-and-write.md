# Format and Write: records to bytes as a chain of Workers — constituent plan (WR)

> **Status: planned 2026-10-07; WR1–WR6 landed 2026-10-07; WR7 closed by its gate; follow-ups WR8–WR10 landed; WR11–WR13 landed; WR14–WR16 queued.** Written with the user after combining two flat files in a Job
> (`File → Parse → Write`) failed with *Write expects file content; received java.util.LinkedHashMap*.
>
> **Relation to other documents:**
> - **Extends** [borrowed elements](2026-09-16_borrowed-elements.md): `Content` stays the handle to bytes that
>   already exist; this plan adds bytes that a Worker *produces*, and teaches `Write` to accept them.
> - **Extends** [data-read-config](data-read-config/README.md): a configured format gains a write side. The
>   delimited format writes first; CSV and TSV are its presets.
> - **Takes over the reuse half of J5b** ([job plan](2026-07-25_job-improvements.md) Phase 5). J5b keeps
>   IO batching and headless mode. The constraint J5b set stays binding here: reuse is benchmark-convicted, obeys
>   DM6/DM7c's exclusive-transfer and alias/copy rules, and migration carryover transfers live values rather than
>   recycling them.
> - **Touches J4's ground.** J4's grouped export parity could later be expressed as `Format → Write`; WR does not
>   change Report or Export, so J4 is unaffected until it chooses to.
>
> The [master ledger](2026-07-25_master-plan.md) owns sequencing (rows WR1–WR7). WR2 writes its design as §4.6's
> replacement for the user's review before implementing; the other rows implement the design below. Each landed
> row appends its as-built under §9.

## 1. Symptoms (observed)

1. **Records cannot reach `Write`.** `File → Parse → Write` passes validation and fails at run time on the first
   row: `Write` accepts only a `Content` (`WriteWorker.kt:128`). Nothing in a Job turns records into bytes for it.
2. **Encoding is buried inside sinks.** Choosing an output format means choosing a sink: `Export` (csv / tsv,
   Report's encoder) or `CSV Writer` (any delimiter). Each re-implements formatting, compression and file handling,
   and neither composes with `Write`'s naming, `existing` policy or atomic publication.
3. **No output format beyond those two sinks**, and none that uses the project's own configured formats, although
   `Parse` reads through them.
4. **Parse allocates heavily per row.** One delimited row allocates, among others: a `String` and a `RawField`
   (with a `LongRange`) per field, a `StringBuilder`, two lists, a decode result per field, the `FlatFileRecord`,
   a new `FlatRecordHeader` (identical for every row of a file), a `BooleanArray`, a
   `NullAwareFlatRecordAccess`, a `DelimitedRecord`, and two `DataValue`s (`ConfiguredDelimitedReader.kt:170-184`,
   `Parser.readRecord` from :298, `ParseWorker.kt:385`). Projection to a combined column set allocates a second
   set (`DataReadCore.message`, `DataReadCore.kt:449-485`). Report does the same work over one reused
   `FlatFileRecord` per ring slot.

## 2. Root causes

- **A. `Content` is the only way to carry bytes, and it means "a whole file that already exists".** It is a pull
  handle (`Content.open()`); its consumer reads at its own pace. Bytes that are still being *produced* cannot be
  a `Content` without either writing them all down first (spooling: twice the IO, unbounded disk) or a live pipe
  inverting the lending protocol (heavy machinery per chunk). Report never needs either: its bytes travel
  in-band through the ring, and the file boundary is a field on each event (`ExportFormatter` stamps the path,
  `CompressedExportWriter` reopens when it changes).
- **B. Encoding, compression and file handling are one sink, three times** (`ExportWriterWorker`,
  `CsvWriterWorker`, and Report's own stages), instead of separate steps.
- **C. A Job value has no cheap "done" signal.** Report's ring reuses a slot once the last stage passes it; the
  stages are fixed and keep nothing. A Job value goes to whatever Workers are wired, some of which keep it (Sort,
  a channel batch, migration carryover), so readers copy every row (`FileDataCursor.kt:45`
  `event.row.prototype()`). The run's ownership ledger *can* tell when a value is released, but it is built for
  closeable resources: a synchronized identity map, a weak per-value owner map, a process-wide identity registry,
  and an owned element skips batching (`JobChannel.kt:50`, `:315-327`). Per row or per chunk, that is the
  heavyweight path the user rejected.
- **D. The configured delimited reader was written for correctness first** (DR4): it builds strings per field
  and per-row wrappers that a reusable buffer would not need.

## 3. Requirements

From the user (2026-10-07):

- **R1 — Modular and chainable**, like a Unix pipeline or ETL: one Worker turns records into bytes (`Format`),
  another puts bytes in files (`Write`). `File → Parse → Format → Write` combines files into one.
- **R2 — Bytes are written once.** No spooling to disk; memory is bounded by the channel between `Format` and
  `Write`, as Report's is bounded by its ring.
- **R3 — No per-chunk heavyweight machinery.** A chunk of bytes is not a lent element and does not go through the
  ownership ledger's closeable path.
- **R4 — `Bytes` are recycled**: steady state allocates no new buffers.
- **R5 — General formats.** The delimited format gains write support; CSV and TSV are its preconfigured
  presets, and a project format (e.g. `AuthoredDelimitedFormat`) writes as it reads.
- **R6 — The header is known before the run**, as in Report: `Parse` already merges every file's columns before
  Run (VM3), and `Format` writes the header from its input contract, not from the first record.
- **R7 — `Export` and `CSV Writer` stay** for now; they are removed in a later plan.
- **R8 — Parse allocates less per row, then reuses rows**, as Report reuses `FlatFileRecord`.

**Non-goals.** Removing `Export` / `CSV Writer`; writers for non-delimited formats (the capability seam allows
them later); feeding `Bytes` into `Parse` or `Extract` (they need a `Content` they can sample); carrying an open
output across a live edit (J9's writer-append item applies to `Write` exactly as to `Export`); Report changes.

## 4. Design

### 4.1 Two ways bytes travel

| | `Content` (exists) | `Bytes` (produced) |
|---|---|---|
| What it is | a handle to a file, an archive member, later an HTTP body | one chunk of encoded bytes, in-band in the stream |
| Who drives | the consumer pulls (`open()`), at its own pace | the producer pushes, element by element |
| One output is | one element | a run of consecutive elements with the same `name` |
| Read by | `Parse`, `Extract`, `Write` | `Write` |
| Lifetime | file-owned, or lent by a cursor | recycled into its producer's pool after release (§4.6) |

`Bytes` is an opaque native, like `Content`: it exposes no properties, so the plain-object shape convention does
not lift it into a record. Kotlin: `objects/job/worker/content/Bytes.kt` (a byte array, a length, its pool slot).

### 4.2 Output boundaries: consecutive `name`

The file boundary is metadata, as in Report:

- `Format` stamps each `Bytes` with metadata `{name, parent}`: `name` resolved from its `name` template, `parent`
  the record's own metadata (so `${parent.name}` is the source file).
- An output is a maximal run of consecutive `Bytes` with the same `name`. `Format` writes the header at the start
  of each run; `Write` opens a file at the start and publishes it at the end (a different `name`, or end of
  stream).
- A `name` that comes back after a different one is refused by name in `Write` (*'x.csv' was already written in
  this run; sort by what the name is built from first*), never silently truncated or interleaved.
- No records means no output file. (`Export` writes an empty container; `Format` cannot know a `name` without a
  record.)

`Format`'s `name` template decides the grouping: a constant is one output (the user's case); `${parent.name}` is
one per source file; a column reference splits by value.

### 4.3 Delimited write capability (WR1)

A format declares whether it writes, and with what: `ConfiguredRecordFormat` gains `writerCapabilityIdentity:
String?` (common, so the catalog can mark writable formats for the picker), and a JVM `RecordWriterCapability`
registry maps it to an encoder, as `ReaderCapabilityRegistry` does for readers. The encoder appends one record's
bytes to a caller-supplied reusable buffer; it allocates nothing per record.

**Rule: round trip.** Writing rows with a format and parsing them back with the same format yields the same rows.
A value that cannot round-trip fails by name (as Report's TSV writer does for a tab).

| Setting | When writing |
|---|---|
| `delimiter`, `quote`, `escape` | minimal quoting: a field is quoted when it contains the delimiter, the quote, CR or LF; `escape: double-quote` doubles quotes. Empty `quote` or `escape: none`: such a value fails by name |
| `recordSeparator` | `lf` / `crlf` terminates each record |
| `header` | `present` writes the header; `absent` and `infer-labels` write none |
| `charset`, `unmappable` | encodes in the charset; `report` fails on an unmappable character, `replace` substitutes |
| `bom` | `require` writes a BOM; `permit`, `forbid`, `detect` write none |
| `nullToken` | a null cell is written as the token. A non-null value equal to the token must still read back as itself: WR1 settles how (quote it, or fail by name) against the reader's actual null rule |
| `schema` | when present, the input's columns must equal it (checked before Run) |
| `trimming`, `malformed`, `skipLeadingLines`, `commentPrefix`, `contentCodings` | read-only; ignored |

**Report parity.** `ConfiguredCsv` (`,` / `"` / doubled / `lf`) writes byte-for-byte what Report's
`CsvExportFormatter` writes. `ConfiguredTsv` keeps its quoting, so a value containing `"` is quoted where Report's
TSV writer writes it raw (and Report rejects tab / CR / LF, which here are quoted). Export is unchanged, so this
divergence is confined to `Format`.

Values reach the encoder through the column projection `Export` already uses (DM6's
`ColumnProjectionDescriptor`; `WriterColumnSpec` for `columns`), so non-text scalars render as they do in
`Export` (`DataReadCore.scalarText`).

### 4.4 `Format` Worker (WR3)

Transforms palette. Attributes: `input`, `output`, `format` (writable configured formats only; default
`ConfiguredCsv`), `name` (template; `${extension}` is the format's first extension; default `output${extension}`),
`columns` (`WriterColumnSpec`, as `Export`).

- **Header from the input contract** (`control.inputContract()`, as Filter and Formula bind), so it is the
  combined column set `Parse` validated before Run. Archive members read by `Parse` are the one case typed from
  the first member; the contract still holds by then, since every later member must match it.
- Per record: resolve `name`; on a change, encode the header first; encode the record into a pooled `Bytes`;
  emit it. One record per chunk at first (coalescing is a later, measured optimization: buffering across
  callbacks interacts with checkpoints).
- Output lane type: `Bytes` with metadata `{name, parent}`.

### 4.5 `Write` over `Bytes` (WR4)

`Write` accepts either `Content` or `Bytes`, decided by its input lane type before Run; any other type is a
validation error that names the fix (*Write writes files or bytes; to write rows, add Format before it*).

For `Bytes`: resolve the destination from the first chunk of a run (its existing `name` template, default
`${name}${extension}`, already fits), apply `existing` (fail / replace / skip — skip drops the run), open a
temporary in the target directory through the compression `Write` already has, append each chunk, and on the
run's end finalize, publish by atomic move and emit one `Written`. Failure or cancellation deletes the temporary
and publishes nothing, as today. A live edit restarts the open output, as `Export` does (J9).

The `Content` path is unchanged.

### 4.6 Recyclable values (WR2 — design-first)

> Design for review, 2026-10-07. Anchors are kzen-auto-jvm paths under `tech/kzen/auto/server/` unless noted.
>
> **Approved by the user 2026-10-07**, with these choices: keeping a value forfeits it (at `retain`, `snapshot`,
> `boundary` and the inherit sites); the raw receive paths forfeit at hand-out; one shared, non-idempotent token per
> object (zero allocation), with misuse caught by the generation stamp; the generation stamp is checked in tests
> only; Result keeps forfeiting (a hold-and-swap only if a later measurement justifies it).

**Problem.** A pooled object (a `Bytes` buffer, later a row) may go back to its producer's pool only once nothing
can read it again. Today every unowned value is immutable, so any code may keep one silently — in a field, a
collection, or a value handed to a child Logic — and the framework never needs to know. A recyclable is the
first value for which keeping it silently is unsafe. The ownership ledger (E9, `exec/job/ownership/RunOwnershipLedger.kt`)
already tracks who can still read an owned value. But it is too heavy per value: a synchronized identity map, a
weak map keyed by access, the process-wide registry, and a flush on every owned `send` (`JobChannel.kt:321-325`).
It also exists for natives whose release a producer may wait on, and a pool never waits. The two failure modes
are not symmetric. A recyclable that is never returned is only an allocation, which GC reclaims. A recyclable
returned while still readable is silent data corruption. **Design rule: a pooled object may leak, but must never
be recycled early.**

**Decisions.**

- **D1 — interface (kzen-auto-jvm only).** `Recyclable` is deliberately not `AutoCloseable`, so the ledger and
  `LentElement` never adopt it. Its state is one `AtomicInteger`: the hold count plus a `FORFEITED` bit.
  `hold()` increments. `release()` decrements, and at zero, unless forfeited, pushes the object to its pool.
  `forfeit()` sets the bit; from then on the object never returns to a pool and is an ordinary GC'd value.
  Underflow throws by name. In tests, a generation stamp is bumped on recycle and checked on read.
- **D2 — finding a recyclable cheaply.** `(value.access as? RecyclableAccess)?.recyclable` is one interface
  check on the access. The pooled object (or its pool slot's access) implements `RecyclableAccess`. `Bytes` is
  its own `ValueAccess`, and a WR7 row's kzen-auto-jvm wrapper access works the same way. `DataValue.withMetadata`,
  `payload()` and navigation share the access (kzen-lib `DataValue`), so a value re-wrapped with new metadata
  (Formula's metadata-only output) is still found. The check runs before the ledger path and costs less than it.
  The ledger's `closeableRoot` (`RunOwnershipLedger.kt:114-129`) reads `value.contract`, which allocates under
  metadata, and then does a map lookup and a CHM lookup.
- **D3 — channel.** In `Producer.send` (`JobChannel.kt:315-327`), a recyclable gets `hold()`. A preallocated
  per-object hold token (a `ValueLease` whose `release()` decrements) goes into the existing `pendingLeases`
  slot. Other values take the ledger path as today. **No flush:** the flush-at-once condition becomes "a ledger
  lease was taken", so recyclables batch normally. The recyclable path works even when the channel's `ownership`
  is not bound. Because the token reuses the lease slot, every existing release path already covers recyclables
  with no new code (release table below). One invariant keeps the two mechanisms disjoint: a pooled object owns
  its bytes / chars and is never a view over another value, so it never has ledger owners. Tests assert this.
- **D4 — drive loops.** Today `CallbackLeases.transferring` (`objects/job/worker/CallbackLeases.kt:20-29`) takes
  the callback hold through `holdForCallback` → `ledger.retain`, then releases the channel's hold. For a
  recyclable, that would return `ValueLease.none` and release the object **before** the callback runs. The
  change: when the channel lease is a recyclable token, the callback lease **is** the token. This is a transfer
  with no extra count. `holdingLease`'s `finally` releases it on success, failure and cancellation alike.
  `CallbackLeases.holding` (used by expanding transforms) is unchanged: the channel hold stays until
  `ExpandingTransformWorker.kt:176-177`. Net cost per element is one atomic increment at `send` and one decrement
  after the callback.
- **D5 — keeping a value forfeits it instead of holding or copying.** Wherever a value may outlive its callback
  inside code the framework cannot see, the recyclable is forfeited:
  - `EngineJobControl.retain` (`exec/job/EngineJobControl.kt:249-257`) forfeits and returns `ValueLease.none`.
    Sort already handles an inactive lease.
  - `EngineJobControl.snapshot` (`:289-303`) forfeits and returns the value itself, as it already does for an
    unowned value.
  - `JobDataValues.boundary` / `boundaryNode` (`objects/job/value/JobDataValues.kt:141`, `:172-209`) forfeit when
    the access is recyclable, because they hand out an opaque native root (e.g. `Bytes`) by identity. Records
    already leave as a `LinkedHashMap` copy.
  - The two ledger `inherit` sites (`FormulaWorker.kt:117`, `JavaTransformWorker.kt:100`) forfeit the input when
    the output is non-scalar and its access differs from the input's, since the expression or plugin may have
    returned or embedded the receiver. A metadata-only output shares the access and is held by its own `send`.
  - The raw consumer paths (`receive` `:440`, `iterator` `:449`, `receiveBatch` `:430`) forfeit at hand-out. Raw
    consumers are untrusted, and none exists in tree or in kzen-sample.

  Forfeit is never worse than no pooling. It leaves no release obligation and needs no copy routine per pooled
  type. Holding instead would leave the pool's size bounded only by what keepers choose to keep.
- **D6 — pool.** Each pool is owned by the producing Worker instance. Acquire runs on the producer's coroutine;
  release may run on any thread.
  - Structure: an intrusive Treiber stack, with a `next` field in the pooled object. Releasers push with CAS.
    The single consumer (the producer) drains the stack with `getAndSet(null)` into a private free list.
  - Both paths are allocation-free. There is no ABA problem: there is one consumer, and a free object (count
    zero) cannot be pushed twice.
  - Happens-before chain: the consumer's last read precedes its volatile `release` decrement, which precedes the
    CAS push (release), which precedes the producer's `getAndSet` (acquire). The producer's own writes reach the
    consumer through the kotlinx `Channel` hand-off.
  - When the pool is empty, it allocates; it never waits. An acquired object has count 0 and is private to the
    producer until `send`. One that is never sent is simply garbage.
  - A pool slot may cache its `DataValue` and re-make it only when the metadata changes. Metadata is immutable
    and never pooled.
  - This replaces the proposal's "array-backed" wording. The intrusive stack is equally allocation-free and
    needs no capacity decision.
- **D7 — migration.** Carryover transfers holds and never recycles (master plan rule 3).
  - Buffered and parked elements keep their tokens through `drainBuffered` (`JobChannel.kt:213-253`) →
    `JobCarryover` → `preload` (`:194`).
  - An expanding transform's active batch carries its remaining channel holds (`ExpandingTransformWorker.kt:219-233`).
  - The new consumer releases each token exactly once, as it does for ledger leases.
  - A carried object released after its producing Worker was torn down goes back to that Worker's pool. That
    pool is unreachable, so the object is collected. The new instance allocates afresh: a one-time cost per
    edit, and safe.
  - Migration drops old channels without a release pass (`exec/job/JobRun.kt:157-161`), so nothing is released
    twice.
- **D8 — kzen-lib: no change.** `DataValue` and `ValueAccess` are used as they are. The interface, tokens, pools
  and the channel / drive-loop / control changes all live in kzen-auto-jvm. `kzen-auto-plugin`'s `FlatFileRecord`
  API is unchanged; WR7 wraps it.

**Release points.** There is one token per channel slot, and it is released at most once. Every row below
already exists for ledger leases.

| Loop / event | Where the token is released |
|---|---|
| Transform / Sink, success or callback failure | `holdingLease`'s `finally`, after D4's transfer |
| Transform, `requestCompletion` (Take) or `DownstreamClosed` | `abandon` → `ReceivedBatch.releaseRemaining` (`TransformWorker.kt:155-160`, `:171-176`); dispatched slots are already released |
| Transform / Sink, failure mid-batch | The remainder is not released. It leaks and is never recycled (teardown drops the batch). |
| Expanding transform | `batch.channelLease(index)?.release()` after the expansion (`ExpandingTransformWorker.kt:176-177`); `DownstreamClosed` → `releaseRemaining` (`:141-149`); `ExpansionState.close` (`:255-266`) |
| Producer flush fails | `DownstreamClosed` / any other `Throwable` → `batch.releaseLeases` (`JobChannel.kt:353`, `:361`) |
| Cancellation | No release (`CancellationException`, `JobChannel.kt:330-368`); teardown leaks the value or carryover transfers it |
| Consumer closes | `closeConsumer` releases raw and buffered tokens (`JobChannel.kt:411-427`) |
| Removed channel at migration | Not released: `JobRun` drops a carryover with no matching channel (`exec/job/JobRun.kt` ~:146–160), so a recyclable there leaks (safe); ledger-owned values close at teardown. `ChannelCarryover.release` exists but has no caller (WR2 finding) |
| Raw paths | Forfeited at hand-out (D5), so `releaseRaw` (`:507`) only decrements |
| Source with no consumer | `SourceWorker.kt:37-56` swallows `DownstreamClosed`; buffered elements leak with the channel |

**Retention audit.** Does each Worker keep a value past its callback?

| Worker | Keeps? | Covered by |
|---|---|---|
| `FilterWorker` | No. The expression's result is only a truthiness. | — |
| `ValueSetFilterWorker` | No. It renders copies. | — |
| `TakeWorker` | No. It forwards, then calls `requestCompletion`. | abandon releases the remainder |
| `PreviewWorker` | No. `PreviewCapture` keeps detached `PreviewNode` copies; an opaque native shows "unavailable"; migration state is copies. | — |
| `SummaryWorker` | No. It renders strings into builders. | — |
| `PivotWorker` | No. `PivotBuilder.add` reads through a flyweight; a stale reference is kept but never read again; H2 copies. | — |
| `ExploreWorker` | No. `IndexedCsvTable.add` writes into its buffer. | — |
| `CsvWriterWorker`, `ExportWriterWorker` | No. They write inside `runBlockingIo` within the callback; `WriterColumns` rows are callback-scoped. | — |
| `PathProjectionWorker` | No. It makes text copies. | — |
| `WriteWorker` | No. It consumes `Content` in the callback; `Written` is immutable. | WR4 constraint below |
| `FormulaWorker`, metadata-only | The output shares the access and is sent while the input is held. | D2 / D3 |
| `FormulaWorker`, payload | **Silently**: the expression may return or embed the receiver. | D5 inherit forfeit |
| `SortWorker` | Yes, through `retain`. | D5 forfeit |
| `ResultSinkWorker` | Yes, through `snapshot`; `progress` reads `kept` / `keptAll` later. | D5 forfeit |
| `RunWorker` | **Silently**: `boundary(element)` goes to a child Logic, which may keep it or return it. | D5 boundary forfeit |
| `JavaTransformWorker` (incl. all kzen-sample workers) | **Silently**: `boundary` hands a native to plugin code, which may stash it. | D5 boundary + inherit forfeit |
| `ParseWorker`, `ExtractWorker` | Yes, the input across its expansion, under the channel hold; `itemMetadata` is immutable. | D4 holding variant |
| `FileSourceWorker`, `FormulaSourceWorker`, `LogicSourceWorker` / `ReadWorker` / inline data, the two legacy sources | No channel input. | — |
| Trace / inspector | The Job publishes only progress maps (copies). There is no live inspector (`TraceAliasState` is unused). A child Script / Flow snapshots synchronously (`ScriptRunContext.kt:587`, `FlowRun.kt:731`), after `boundary` has already forfeited. | — |
| Lazy rendering | `WorkerBase.publish` / `progress` run outside callbacks over Worker state, which holds only copies or forfeited values. | — |

`objects/job/value/JobValueTransfer.kt` (with `TraceAliasState` and `JobValueSender` / `Delivery`) has no
production or test caller. It is dead code and needs no answer.

**Steady state and §7 Q2.** Because keeping a value forfeits it, the pool never holds more objects than the peak
in-flight count. Channel capacities bound that count, so no idle cap is needed (§7). In-flight is more than one
channel's capacity × batch size: a recyclable that passes through a chain of transforms sharing its access
(metadata-only Formula) is in flight on every channel it crosses. With the defaults (`capacity: 0`,
`batchSize: 1024`, `job-jvm.yaml:25-26`), each hop holds roughly a producer batch, a consumer batch and the
callback in hand. An optional large ceiling would only guard against misuse.

**Contradictions with the proposal.**

- **DM6's in-place append no longer exists.** `RecordOutputBuilder`, `FormulaValueTransformer` and `RecordOverlay`
  were deleted in kzen-auto `767d1894` (VM1–VM3, 2026-09-24). Formula now shares the access for metadata-only
  outputs (D2) and lifts a new value for payload transforms (D5 forfeit). If an in-place builder comes back, a
  count of exactly 1 held by the current callback is a cheap proof of exclusivity.
- **`retain` and `snapshot` forfeit** instead of taking a hold or making a copy (D5).
- **No idle cap** (above), and an intrusive stack instead of an array-backed structure (D6).
- The proposal's "steady state = channel capacity × batch size" undercounts chains (above).

**Constraints on later sessions.**

- WR4: `Write` must finish copying a chunk's bytes inside the callback. No async write may keep a reference.
- WR3 / WR7: `Bytes` keeps its buffer `internal`, so runtime-compiled expressions cannot reach it.
- WR7: a row's access is a wrapper, so `JobDataValues.record()` (`:111-115`) takes its copy path, not the
  `FlatFileRecord` fast path. Pivot / Explore / Export must be measured on that path.
- A future Worker that keeps a value must go through `retain` / `snapshot` / `boundary`, as the SPI already
  requires (kzen-auto-common `JobControl.kt:149-167`).

**Tests (WR2).** A test recyclable carrying the generation stamp, plus a pool that counts objects created and
outstanding, covering:

- Filter, Formula metadata-only and payload, Take early close (remainder released), Sort (forfeited, outputs
  intact), Preview, Result keep first / last / all, Run with a child that returns its input, and JavaTransform.
- Failure mid-batch in Sink and in Transform: leaks, never recycles early. Cancellation.
- Live-edit migration with values buffered in a channel, in a parked flush, and in an expanding transform's
  batch. Holds are carried, the old pool becomes garbage, and nothing is released twice.
- The `closeConsumer` and `DownstreamClosed` paths. Underflow throws by name.
- In steady state, the pool's created count stays ≤ peak in-flight.
- Unowned and ledger-owned values are unaffected: the ownership suites under `exec/job/ownership/` stay green.
- An Epsilon run showing that WR2 adds no allocation per element.

**Risks.**

- **The token is not idempotent.** It is a shared preallocated lease, unlike `OwnedNative`'s per-lease
  `AtomicBoolean` (`OwnedNative.kt:109-122`), so a double release on any path is silent corruption. Mitigations:
  - The audit above shows each slot is released once: abandon releases only undispatched slots; the callback
    releases its own; migration drops old channels and cancels the old producer without a release; the
    expanding transform marks a slot dispatched before `:177` releases it.
  - Underflow detection.
  - The test generation stamp.
- A future view wrapper or Worker could keep a value silently, outside `retain` / `snapshot` / `boundary`.
- Forfeit removes reuse for Result(last) and payload Formulas. That equals today's allocation; it is no worse.
- Existing per-element framework allocations (`CallbackLeases` suspend lambdas, a `Pull` per item, `Batch`
  copies) remain. They belong to J5b.

**For the user's decision.**

1. Forfeit (rather than hold or copy) at `retain`, `snapshot`, `boundary` and the inherit sites.
2. Forfeit on the raw receive paths.
3. Whether Result(last) should get a hold-and-swap later (only if a measurement justifies it).
4. One shared non-idempotent token per object, or an allocated idempotent lease per hop.
5. Whether the generation stamp runs in test mode only.

### 4.7 Parse allocation (WR6, WR7)

**WR6 — allocate less, no reuse.** One file's rows share everything that does not change per row:

- `Parser.readRecord` writes field characters into one reusable character buffer with field end offsets
  (`FlatFileRecord`'s own layout); offsets for error messages stay in a reusable `LongArray`, not a `LongRange`
  per field.
- Per-field decode validates in place and records nulls in a reusable flag array; the text is not re-copied.
- `FlatRecordHeader` and the null-aware access shape are made once per file (per projection plan), not per row.
- `DataReadCore.message` computes its column mapping once per file and copies character ranges into the target
  record, instead of building a `List<String>`.
- Per row remains: the `FlatFileRecord` (copied from the buffer, as `prototype()` does), its null flags, and the
  `DataValue`.

**WR7 — reuse rows.** The reader fills pooled rows through WR2's mechanism. A pool slot holds the
`FlatFileRecord`, its null flags and its `DataValue`; the value with metadata is re-made only when the metadata
changes (once per file). The access is a kzen-auto-jvm wrapper, as `NullAwareFlatRecordAccess` already is, so
`kzen-auto-plugin`'s `FlatFileRecord` API does not change.

## 5. Phases

Each row: implement, focused tests, full `cd ../kzen-auto && ./gradlew build`, as-built in §9.

### WR1 — delimited write capability

- `ConfiguredRecordFormat.writerCapabilityIdentity` (common), `ConfiguredFormatDetail.writable` for the catalog.
- `RecordWriterCapability` registry (JVM) and the delimited encoder (§4.3): characters into a reusable buffer,
  then one `CharsetEncoder` pass into reusable bytes, as Report's `CharsetExportEncoder` does over
  `DataRecordBuffer` (reuse that buffer type if it fits).
- **Tests:** round trip over the delimited reader's dialect matrix (delimiters, quote / escape, CRLF, BOM,
  charsets, null token, embedded delimiter / quote / newline); refusals by name; `ConfiguredCsv` output
  byte-identical to `CsvExportFormatter` over the same rows; no allocation per record (a bounded
  Epsilon-GC run, or an allocation counter over a fixed buffer).

### WR2 — recyclable values (design first)

- Write §4.6's full design (the audit and the three questions); the user reviews it; then implement the
  interface, holds at the channel / drive-loop / `retain` / `snapshot` / carryover points, the growing pool, and
  the test generation stamp.
- **Tests:** a test recyclable through Filter, Formula (metadata-only output and a payload transform's forfeit), Take (early close), Sort (`retain`),
  Preview, Result, a failure mid-batch, cancellation, and a live-edit migration with values in flight; no
  use-after-recycle; pool size bounded by in-flight count; unowned values unaffected (the ledger's fast path).

### WR3 — `Bytes` and `Format`

- `Bytes`, its pool, the `Format` archetype in `job-worker.yaml` and its Worker (§4.4).
- **Tests:** header from the contract under combined columns (two files with different columns); grouping by a
  constant, by `${parent.name}`, by a column; empty stream emits nothing; a format refusal surfaces by name.
  `Format`'s own steady-state allocation is the pass criterion (R4).

### WR4 — `Write` over `Bytes`

- `WriteWorker` dispatch on its input type before Run; the run state machine (§4.5); validation error naming
  `Format`.
- **Benchmark** (moved from WR3, which has no `Write` over `Bytes` to finish S4 with): add scenario **S4** to
  `JobReportBenchmark`: S3's Job with `Format(ConfiguredCsv) → Write(none)` in place of `Export`, asserting
  byte-identical output to S3's Report; record wall time and Epsilon bytes/row next to S3.
- **Tests:** two files → one output; per-source outputs; a returning `name` refused; `existing` fail / replace /
  skip per output; gzip; failure mid-output deletes the temporary; cancellation; `Written` per output;
  `File → Parse → Write` now fails validation before Run with the message above.

### WR5 — UI and browser verification

- `FormatTool` under Transforms in `job-js.yaml`; the format picker (`SelectDataFormatEditor`) filtered to
  writable formats for `Format`; name template editor with its placeholders.
- **Browser:** on a spare port, the user's case — two `measurements-*.txt` files, `Parse` combining columns,
  `Format(CSV)`, `Write(gz)` — and the output read back by a second Job. Also `Format(TSV)` per source file.
- Docs: `kzen-auto/AGENTS.md` / `docs/architecture.md` — the two ways bytes travel (§4.1) and the boundary rule
  (§4.2).

### WR6 — Parse allocates less

- §4.7 WR6 list, in `ConfiguredDelimitedReader` and `DataReadCore.message`.
- **Measure** Epsilon bytes/row on S3's `File → Parse` path before and after, and S4's wall time; record both.
- **Tests:** the delimited reader suite unchanged and green; error positions still exact.

### WR7 — reuse rows

- §4.7 WR7 on WR2's mechanism.
- **Gate:** proceed only if WR6's table shows per-row allocation still convicts (J5b's rule); otherwise record
  the measurement and close the row.
- **Tests:** WR2's suite with real rows, including Formula's outputs and Sort; S1–S4 outputs unchanged;
  bytes/row recorded.

### Follow-ups (user-approved 2026-10-07, from WR4–WR6's findings)

**WR8 — live edit keeps the open output** (§7 Q5). `Write` migrates its open output, ended names / target paths
and counters across a compatible edit; `Format` migrates its last name so it does not repeat the header; an
incompatible edit — `Write`'s directory, name or compression; `Format`'s format or columns — ends the open output
cleanly (published as written so far, or discarded — decide by what `existing` and atomic publication imply, and
record it). Tests: WR4's `aLiveEditRestartsTheOpenOutput` becomes a well-formed-output assertion (one header, every
row once); an incompatible edit on each side; migration with chunks in flight (no use after recycle).

**WR9 — per-row allocation found by WR6's profile.** (a) `FormatChunker.chunk` rebuilds chunk metadata per record
(`ValueMetadata.of(DataOverlay.record(…))`, ≈ 9.6 KB per input row in S4) — build the contract once and reuse it,
re-creating only what a record actually changes; (b) `JobDataValues.boundaryNode` catches an exception per row from
`FlatRecordValueAccess.native` → `invalid()` — make the non-native case a normal return, not a throw; (c)
`CharacterInput.consumePrefix` allocations per record with `commentPrefix`; (d) `FlatRecordHeader.indexOf`
allocating a `FieldId` per lookup; (e) `ParseWorker`'s per-row `withMetadata`. Measure S3 / S4 Epsilon slopes before
and after, as WR6.

**WR10 — Automatic reads a small file's header.** `Parse(Automatic)` read a 3-row `measurements-1.txt` as
headerless (`c0, c1, c2`) while reporting "Detected: CSV · UTF-8"; explicit CSV is correct. Find why header
detection fails on a small sample and fix it without regressing headerless detection; also correct the stale
"Default" comment on `SelectDataFormatEditor` in `job-js.yaml`.

**WR11 — metadata shapes: contract work once per shape, not per row** (user-approved 2026-10-08, from WR9's
profile). *Problem:* a row's metadata values are new per row but its contract is the same for a whole file, and
kzen-lib re-derives and re-validates that contract per row — ≈ 40% of S4's sampled allocation after WR9 (≈ 6–7
KB/row). Sites: (1) `FormulaWorker.kt:107` — `DataOverlay.record` builds three validated `DataContract`s per row
(`DataOverlay.contract`: kept fields, `withFields`, reordered), each copying its maps and walking the type in
`validateNativeMetadata`; plus `requireDistinct` / `toSet` / `associateBy`, a `LinkedHashMap` of bindings with a
`Lazy` per base field (`bindingsOf`), eager `OverlayAccess.nodes` / `tokens`; then `ValueMetadata.of` →
`MetadataContract.of` (another walk and a validated `DataContract`). (2) `ChunkMetadata.Shape.metadata` — the
contract is shared since WR9, but `ValueMetadata`'s constructor always runs `MetadataContract.of(access.contract(root))`.
(3) `ValueMetadata.combine` caches per instance, so a new instance per row misses for any reader of `value.contract`.
*Fix (kzen-lib, then kzen-auto):* a prepared `DataOverlay` shape (base metadata contract + field ids / contracts)
computing the composed `DataContract` and `MetadataContract` once and producing per-row metadata as only an overlay
access over positional bindings (no `Lazy` map; `OverlayAccess` state created on first navigation); a `ValueMetadata`
factory taking a precomputed `MetadataContract`, with the combine cache moved to an object the shape owns;
`ValueMetadata.of(record)` unchanged for one-off callers. `FormulaWorker` keeps one shape, rebuilt when the input
metadata contract changes (identity, then equality); `ChunkMetadata.Shape` passes its `MetadataContract` through.
*Risks:* public kzen-lib API, republished to Maven Local (kzen-auto's `jvmMain` resolves kzen-lib from there; no
version bump); the precomputed-contract factory is trusted, so keep it narrow and assert equality in tests.
*Fallback* if the API change is unwelcome: single-entry identity caches inside `DataOverlay.contract` /
`MetadataContract.of`. *Measure* S3 / S4 Epsilon slopes before and after (as WR6); allocation pins for a Formula row
with fresh metadata and a chunk with fresh parent metadata.

**WR12 — cold-start Preview truncation** (user-approved 2026-10-08, found by the flaky-test fix). *Problem:* on a
freshly started server the first Preview row can show "Preview limit reached" or "N more omitted": `PreviewCapture`
gives each item a 50 ms wall-clock budget, and the first structural read of a native's class spends it in
kotlin-reflect's first-use initialization. Flow trace snapshots (`FlowRun.snapshotMessage`, 100 ms) and Script trace
displays (`ScriptRunContext.displayOf`, 100 ms) have the same exposure. The flaky-test fix made the budgets
injectable for content tests (`PreviewWorker.captureNanos`, `FlowRun.snapshotMillis`), which hides the bug in tests.
*Fix:* keep one-time per-class setup out of the timed region — the budget bounds traversing a value, not preparing a
class's reader — for all three sites, preferably in one shared place. *Tests:* a deterministic cold-class case (a
class whose first structural read is slow) previews in full while a genuinely large value is still cut at its
budget; then decide whether the test seams are still needed (remove them if the content tests pass under load
without them).

**WR13 — thread-safe native type resolution** (user-approved 2026-10-08, found in WR12). *Problem:* kzen-lib's
`DefaultNativeTypeResolver` keeps `descriptionCache` / `resolutionCache` in plain `mutableMapOf` / `IdentityHashMap`,
but `JobDataValues.adapters` is one process-wide registry used from concurrent Worker threads, so concurrent misses
can corrupt the maps (lost entries, infinite loops on resize, inconsistent reads). *Fix:* audit every mutable cache
reachable from the shared registry (`DefaultNativeTypeResolver`, `DefaultDataAdapterRegistry`, WR12's
`NativeClasses`, `NativePropertyPlans`, `BeanShape`, any `by lazy` / memo maps) and make each safe for concurrent
use without a global lock on the hot path (`ClassValue`, `ConcurrentHashMap` with identity-keyed wrappers where
identity matters, or immutable copy-on-write snapshots), keeping WR12's `ReadPreparation.prepare` accounting intact.
*Tests:* a multi-threaded stress test resolving many fresh types concurrently against one registry (results equal to
single-threaded resolution, no exceptions), run on the old code first to show it can fail.

**WR14 — shared readers of one native value** (user-approved 2026-10-08, found in WR13). *Problem:* kzen-lib's
`NativeObjectValueAccess` (node table, per-node field / element / entry maps) and `TaggedUnionValueAccess` intern
nodes lazily without synchronization. Today each such value appears to be read by one thread at a time, but a value
can reach several readers at once — fan-out to several consumers, live inspectors (`JobTransferConditions`), and
reads through WR11's `OverlayAccess` to a native base — and two threads interning the same node can corrupt the
table or hand out different node ids for one path. *Fix:* make lazy interning safe for concurrent readers without a
lock on the hot read path (publish-once node slots, or `ConcurrentHashMap` with compute-outside-then-`putIfAbsent`
as in WR13), keeping a node's id stable once any reader has seen it; first confirm which carriers really can be
shared, and document the threading contract on `DataValueAccess` either way. *Tests:* gated deterministic tests
forcing two readers into the same first read, plus a multi-threaded stress read of one value equal to a
single-threaded read; run on the old code first to show it can fail. Re-check the Epsilon bytes/row slope (S3, S4)
— the read path is per row.

**WR15 — mutually recursive types** (user-approved 2026-10-08, found in WR13). *Problem:* lifting two types that
refer to each other (Java records `Right(String, List<Left>)` / `Left(String, List<Right>)`) overflows the stack
single-threaded: `DataTypeAlgebra.accepts` (`DataTypeAlgebra.kt:112`) expands a named reference against an inline
record forever, because its guard records only reference-against-reference pairs. *Fix:* make the guard
coinductive over every (expected, actual) pair in which either side is a named reference — assume acceptance for a
pair already in progress — and audit the other recursive walks over definitions (`isAssignable`, validation,
`DataContract` equality / hashing, describe) for the same gap. *Tests:* the record pair above lifts and validates;
mutual recursion through a list, a map and a nullable field; a genuinely incompatible recursive pair is still
rejected, not accepted by the guard.

**WR16 — dynamic-expression class loaders stay releasable** (user-approved 2026-10-08, from WR13's finding 3).
*Problem:* `CachedKotlinCompiler` gives each compiled expression its own `URLClassLoader` in a size-capped cache
that closes the loader on eviction, so expression code is meant to be releasable; plugin loaders, by contrast, load
once and stay until a project restart (by design). The process-wide `JobDataValues.adapters` registry's
`DefaultNativeTypeResolver` defeats this: `descriptionCache` (keyed by `KType`) and `resolutionCache` (keyed by the
value's class loader) hold strong references for the process's life, so lifting a value whose class an expression
or script defines (anonymous object, lambda, script-declared class) pins that class and its loader after eviction —
a Metaspace leak (found by reading, not yet reproduced). *Fix:* first reproduce it; then key the caches so an entry
dies with its class loader — per-class `ClassValue` (as WR12's `NativeClasses` / `BeanShape` already do) or weak
keys — without changing WR13's concurrency guarantees or adding a lock or allocation to the hot hit path; audit the
other process-wide caches reachable from the registry (adapters' `exactByClass`, `JobDataValues.flatHeaders`, WR12's
per-class plans) for the same retention. *Tests:* a value of a class defined in a throwaway `URLClassLoader` is lifted
and described, the loader is dropped, and a `WeakReference` to it clears after GC (fails on the old code); a plugin-
or application-loaded class still hits the cache; WR13's concurrency tests stay green.

## 6. Measurement

`JobReportBenchmark` (`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/job/bench/`), `benchJob` and
`benchJob -PbenchEpsilon` (bounded 250K rows). J5a's table is the reference. Throughput is still dominated by the
per-record path J5b targets (J5a: S3 Job 33.2 s vs Report 1.7 s per 1M rows), so WR judges allocation by
bytes/row and GC counts, and treats wall time as a secondary record.

## 7. Open questions

1. **`nullToken` round trip** (WR1): how the reader treats a quoted value equal to the null token decides whether
   the writer quotes it or refuses it.
2. **Pool idle cap** (WR2): recommendation is none. Keeping a value forfeits it (§4.6 D5), so the pool never holds
   more than the peak in-flight count. At most, add a large defensive ceiling.
3. **Chunk coalescing** (after WR3): whether one record per chunk measures as a cost worth the checkpoint
   interaction.
4. ~~**`skipLeadingLines` on write**~~ — **settled 2026-10-07 (user):** the encoder writes that many empty lines
   after the BOM and before the header, so such a format round-trips.
5. ~~**Live edit mid-output**~~ (found in WR4): a restarted `Write` drops its temporary, but chunks still in flight
   from the old `Format` start the output again and the restarted `Format` repeats the header, so the published
   file is malformed. Proposal: `Write` migrates its open output, ended names and counters across a compatible
   edit, `Format` migrates its last name so it does not repeat the header, and an incompatible edit (directory /
   name / compression; `Format`'s format or columns) ends the output. **Settled 2026-10-07 (user): accepted as proposed** — WR8.

## 8. Tracker

- [x] WR1 — delimited write capability (2026-10-07)
- [x] WR2 — recyclable values (design first) (2026-10-07)
- [x] WR3 — `Bytes` and `Format` (2026-10-07)
- [x] WR4 — `Write` over `Bytes` (2026-10-07)
- [x] WR5 — UI and browser verification (2026-10-07)
- [x] WR6 — Parse allocates less (2026-10-07)
- [x] WR7 — reuse rows (measurement-gated) — closed by the gate 2026-10-07, no reuse (§9 WR6)
- [x] WR8 — live edit keeps the open output (§7 Q5) (2026-10-07)
- [x] WR9 — per-row allocation found by WR6's profile (2026-10-08)
- [x] WR10 — Automatic reads a small file's header (2026-10-08)
- [x] WR11 — metadata shapes: contract work once per shape, not per row (2026-10-08)
- [x] WR12 — cold-start Preview truncation (2026-10-08)
- [x] WR13 — thread-safe native type resolution (2026-10-08)
- [ ] WR14 — shared readers of one native value
- [ ] WR15 — mutually recursive types
- [ ] WR16 — dynamic-expression class loaders stay releasable

## 9. As-built

### WR1 — delimited write capability (2026-10-07)

Full `./gradlew build` green (`--rerun-tasks`, 7m24s). One unrelated flake on the first run:
`OwnedRouteTest.sortRetainsUntilItsOwnEmissionAndTheSinkStillSeesEveryElementOpen` (`:91`), green 3/3 in isolation
and in the rerun; load-sensitive, worth watching.

- **API** (kzen-auto-jvm `server/data/write/`): `RecordCells` (size, `isNull(i)`, `text(i): CharSequence`, a view
  valid until the next call, never asked for a null cell); `RecordEncoder.encodeHeader / encodeRecord(cells,
  output: DataRecordBuffer)` appending to `output.bytes` from `bytesLength`, appending nothing on failure;
  `RecordWriterCapability.encoder(format, columns)`; `RecordWriterCapabilityRegistry.withBuiltInWriters()` /
  `writerFor(format)`, a `@Service` via `KzenAutoContext`; `ConfiguredDelimitedWriterCapability` +
  `DelimitedRecordEncoder`. `ConfiguredRecordFormat.writerCapabilityIdentity` (default null);
  `ConfiguredFormatDetail.writable` (default false, older values decode). The SPI stays in kzen-auto-jvm, no
  ServiceLoader yet.
- **Creating the encoder is the pre-Run check:** config, columns vs schema (by name when the header is present, in
  order when absent), BOM support, and that the charset encodes delimiter / quote / CR / LF / BOM.
- **§7 Q1 settled: refuse by name.** The reader compares `raw.text == nullToken` whether quoted or not, so quoting
  cannot protect a value equal to the token. A null is written as the token only for a nullable schema column with
  a token; otherwise, and for a non-null value equal to the token, the encoder fails naming the column.
- **Deviations from §4.3:** `bom: detect` also writes a BOM (the reader's detect requires one); BOMs only for
  UTF-8 / UTF-16BE / UTF-16LE; with `trimming: unquoted` a value with edge whitespace is quoted; a line that would
  read as a comment has its first field quoted (fails by name if quoting cannot help); commons-csv's extra quoting
  cases (empty first field, leading `#`, last character ≤ space) apply to every delimited format, which is what
  makes `ConfiguredCsv` byte-identical to `CsvExportFormatter` + UTF-8. `skipLeadingLines` was ignored at first;
  per the user it now writes that many empty lines before the header (§7 Q4). Known gap: a Latin-1 first field whose
  bytes look like a BOM.
- **Tests:** `DelimitedRecordEncoderTest` (14: dialect-matrix round trip through the real reader, refusals with
  unchanged output, CSV parity with Report, `encodingARecordIntoAReusedBufferAllocatesNothing` — 3,736 bytes fixed
  over 200k records), `RecordWriterCapabilityRegistryTest` (2),
  `DataSourceActionsTest.catalogMarksTheDelimitedFormatsWritable`, `ConfiguredFormatDetailTest` (+1).
- **For WR3:** create the encoder when the Worker binds its input contract so refusals surface before Run; call
  `encodeHeader` at the start of every output (the BOM is written there); adapt projected columns to `RecordCells`
  without allocation (`DataState.Null` → `isNull`, a reused `CharSequence` view over `FlatFileRecord`, numbers into
  a reused `StringBuilder`); `Bytes` can wrap a `DataRecordBuffer`'s byte side; wrap encoder errors with the record
  index.

### WR2 — recyclable values (2026-10-07)

Full `./gradlew build` green on the third run; the first two failed only load-sensitive timing tests
(`JobDesignTimeTypeTest` "time limit reached", `OwnershipBoundaryTest.formulaPreviewReleasesNestedOwnedValuesAndKeeps
CalculatedContent` against the 50 ms `PreviewCapture` budget), green alone and with every ownership / channel /
migration / recyclable suite; a baseline run of the parent commit also failed a timing test
(`ExtractWorkerTest.writeCopyingOneLargeEntryIsNotReportedAsStalled`). The added suite load may make the Preview
budget miss more often — watch it.

- **API** (kzen-auto-jvm `objects/job/value/recycle/`): `abstract class Recyclable(pool)` — one `AtomicInteger`
  (holds + forfeited bit), `hold` / `release` (underflow fails by name) / `forfeit`, a shared non-idempotent
  `Token: ValueLease`, a volatile `generation` bumped per recycle (checked only by the test access);
  `Recyclable.of(value)` / `forfeit(value)` / `forfeitDerived(output, input)`; `interface RecyclableAccess:
  ValueAccess`; `RecyclablePool<T>(create)` — intrusive Treiber stack, producer-only `acquire`, grows when empty.
- **Landed:** `JobChannel.Producer.send` holds and stores the token in `pendingLeases` without flushing (bound or
  unbound); raw `receiveBatch` / `receive` / `iterator` forfeit at hand-out; `CallbackLeases.transferring` moves the
  token over as the callback lease; `EngineJobControl.retain` and `snapshot` forfeit; `JobDataValues.boundary`
  forfeits; `forfeitDerived` at `FormulaWorker` and `JavaTransformWorker`'s inherit sites.
- **Deviation — expression reads do not forfeit.** Generated accessors read through `JobDataValues.boundary`, which
  would have forfeited every record a Filter or Formula expression touched. A non-forfeiting
  `JobDataValues.callbackObject` now serves `JobExpressionValues` and `native()`; what an expression returns that
  could carry the record leaves through `forfeitDerived`. `boundary` stays conservative (any recyclable access).
- **Findings:** a removed channel's carryover is dropped, not released (release table corrected above); a
  `closeConsumer` resumes a parked flush normally after draining and releasing it; elements still in a producer's
  pending list at `DownstreamClosed` leak with the channel.
- **Tests:** `RecyclableRouteTest` (18 routes; every one asserts no read after recycle and no ledger owners —
  Filter / Formula metadata / scalar payload recycle, list payload / Sort / Result last|all / Run / JavaTransform
  forfeit, Take recycles the abandoned remainder, failures mid-batch leak the remainder, cancellation recycles
  nothing, 160 objects created for 20,000 acquired, two live-edit migrations with values in flight),
  `JobChannelRecyclableTest` (9), `RecyclableTest` (6), `RecyclablePoolTest` (2, incl. a 4-thread stress),
  `RecyclableAllocationTest` (2: a pool cycle allocates 0 bytes; pooled through a channel is no worse than ordinary).
- **Docs:** kzen-auto `docs/architecture.md` § Job "Recyclable values (WR2)"; `AGENTS.md` gotcha "Pooled values
  (WR2) must not be kept silently".
- **For WR3 / WR7:** the pooled object extends `Recyclable` and implements `RecyclableAccess` (`recyclable = this`),
  owns its storage (never a view, so never ledger-owned), caches one `DataValue` per slot, and is acquired only on
  the producer's coroutine; `native()` / `callbackObject` hand a `Bytes` out by identity, so `Write` copies inside the
  callback; release exactly once per channel slot.

### WR3 — `Bytes` and `Format` (2026-10-07)

Full `./gradlew build` green (7m24s, 1210 tests, 1 skipped). The first full run failed only the known flake
`OwnershipBoundaryTest.formulaPreviewReleasesNestedOwnedValuesAndKeepsCalculatedContent` ("Preview limit reached"),
green 3/3 in isolation.

- **API** (kzen-auto-jvm `objects/job/worker/`): `content/Bytes` — opaque native (`length()`, `writeTo(OutputStream)`,
  `internal buffer()`), no bean getters so it describes as Opaque; `content/PooledBytes` — the pool slot, both the
  `Recyclable` and its `RecyclableAccess`, native `bytes` by identity, one `DataValue` cached per metadata identity;
  `content/FileNameTemplate` — `Write`'s name grammar, extracted and shared; `format/FormatWorker`, `FormatChunker`
  (writer + column spec + header + encoder, built once for validation and again at run start), `FormatCells`
  (`RecordCells` over flat records in place), `FormatName`. `data/read/FlatRecordBacked` lets
  `ProjectedRecordValueAccess` and `NullAwareFlatRecordAccess` expose their `FlatFileRecord`. `WriterColumns` gains
  `header(contract)` / `pathValues(element, contract)`.
- **`Format` archetype** (`job-worker.yaml`): `input`, `output`, `format` (default `ConfiguredCsv`,
  `SelectDataFormatEditor`), `name` (default `output${extension}`), `columns` (`WriterColumnSpec`), `selfLocation`.
  Chunk metadata `{name, parent}`; for Parse rows the file name is `${parent.name}` in the template and
  `parent.parent.name` on the chunk.
- **Refusals:** before Run (the chunker's message is the step's validation error — non-writable format, columns vs
  schema, unknown placeholder), again at run start, and per record as "Record N: …".
- **Deviations from §4.4:** composition — `Recyclable.of(chunk)` is the `PooledBytes` slot, not `Bytes` (public
  getters on `Bytes` would describe it as a record); an absent superset cell writes an empty field (as the reader
  leaves it), not Export's `<missing>`; placeholders have no `this.` / `meta.` prefixes — a single segment is a
  payload column first, then a metadata path; path columns allocate through `PathRowEvaluator` (payload columns read
  in place). A live edit restarts the Worker (`WorkerBase` default), so the first chunk after an edit repeats the
  header. S4 moved to WR4.
- **Tests:** `FormatWorkerTest` (8: superset header from the contract; grouping by constant, `${parent.name}`, column;
  empty stream; non-writable and schema refusals at validation and run start; "Record 2:"; 20k records round-trip
  with no use after recycle, pool created 1024 chunks), `FormatAllocationTest` (0 bytes over 200k records — flat,
  projected with an absent field, name from column + metadata), `PooledBytesTest`; test sink `BytesSinkWorker`; 7
  fixtures in `test/job/format/`.
- **Docs:** kzen-auto `docs/architecture.md` "Bytes and Format (WR3)".
- **Note (CC-06):** `content/` now holds 12 files plus `tar/`; a `bytes/` split is a later option.
- **For WR4:** copy each chunk inside the callback, never keep the `Bytes`; an output starts where `name` changes and
  its first chunk already holds the header; no records → no chunks; Format does not refuse an empty or returning
  name — Write must; Write's own `${extension}` is the compression suffix, so `output.csv.gz` is expected.

### WR4 — `Write` over `Bytes` (2026-10-07)

Full `./gradlew build` green (4m58s; `:kzen-auto-jvm:test` 1226 tests, 0 failed, 1 skipped); no flake this time.
Interrupted once by a machine restart mid-benchmark; resumed from the tree.

- **Dispatch:** the input lane type is checked at validation (`payloadFlow`) and in `onStart`: a root native of
  class `Content` or `Bytes` picks the path; anything else fails with `WriteWorker.inputRequirement` (*Write writes
  files or bytes; to write rows, add Format before it*). A `Dynamic` lane is decided by its first value.
- **Bytes path:** the output name is the chunk's metadata `name` (cached per metadata identity); a change of name
  ends the open output (close, atomic move, one `Written` carrying the run's first-chunk metadata). Destination
  from `Write`'s own template on the first chunk. `existing`: `fail` fails before a temporary exists, `skip` opens
  a stream-less output and counts the run in `skipped`, `replace` replaces atomically. Each chunk is appended with
  `bytes.writeTo(stream)` in `runBlockingIo` inside the callback; the open output is assigned inside the offload so
  a cancel winning the return dispatch still reaches `onClose`, which deletes the temporary. The `Content` path is
  unchanged except that its `existing` / publish / emit code is shared.
- **Refusals (fail the run, by name):** a returning name (*'x.csv' was already written in this run; sort by what
  the name is built from first*); two names resolving to one file (ended outputs tracked by target path); a missing
  or empty name (with gzip it would publish a hidden `.gz`).
- **Deviation — live edit:** §4.5's "restarts the open output, as `Export` does" does not yield a well-formed file
  for `Bytes` (§7 Q5). Reproduced by `aLiveEditRestartsTheOpenOutput` (20k rows: 1,024 rows, a header at line
  1,025, then the rest); the test pins only the tail, one `Written` and no leftover temporary; KDoc and
  `docs/architecture.md` state the gap.
- **Benchmark S4** (byte-identical to the Report export, asserted; also pinned by
  `JobBenchmarkSmokeTest.formatAndWriteMatchReport`). Normal GC, 1M rows:

  | Scenario | Implementation | Median ms | Spread ms | GC count/ms |
  |---|---|---:|---:|---:|
  | S3 export | Job (`Export`) | 25,548.8 | 24,447.8–25,845.5 | 81/162 |
  | S3 export | Report | 607.4 | 577.3–671.7 | 5/46 |
  | S4 format-write | Job (`Format → Write`) | 34,868.4 | 30,036.5–35,690.1 | 110/292 |
  | S4 format-write | Report | 778.6 | 683.5–826.2 | 6/43 |

  Epsilon at 1M rows exhausts the 16 GB heap, so bytes/row is a slope over 25k / 50k / 100k single runs (S3 and S4
  in separate JVMs at 100k): S3 Job ≈ 29.7 KB/row, S4 Job ≈ 39.0 KB/row (fixed ≈ 140 MB each), Report ≈ 2.0 KB/row.
  Under Epsilon at 100k S4's wall time matches S3's (3,627.8 vs 3,746.2 ms), so the 1M gap is GC from the extra
  ≈ 9.3 KB/row. `Format`'s own encoding allocates 0 B/record, so the extra is the added hop (per-record `{name,
  parent}` metadata, channel, drive loop, a `runBlockingIo` per chunk) — unprofiled; WR6/WR7 should split it out,
  and chunk coalescing (§7 Q3) is the obvious lever.
- **Tests:** `WriteWorkerTest` (15: two files → one output; per-source outputs with one `Written` each; gzip;
  returning name; two names → one file; empty name; `existing` fail / replace / skip; failure mid-output deletes the
  temporary; cancellation publishes nothing; live edit; `File → Parse → Write` refused before Run with the exact
  message; `File → Parse → Format(CSV) → Write` reads back as the same rows, with quotes, commas and newlines; 20k
  chunks against the generation stamp with 0 used after recycle); test Worker `ChunkStampWorker`; 5 fixtures in
  `test/job/write/`; `bench-job-format.yaml`.
- **Docs:** kzen-auto `docs/architecture.md` "Write over Bytes (WR4)"; no AGENTS.md text claimed `Content` only.
- **For WR5:** `Write`'s `FileNameTemplateEditor` help describes file metadata only — for `Bytes`, `${name}` is
  the chunk's name and record metadata sits under `${parent.…}`; default names stack (`output${extension}` in
  `Format` + `${name}${extension}` in `Write` → `output.csv.gz`); per-source `${parent.name}` keeps the source
  extension (`measurements-1.txt`) and no placeholder strips it; the `Parse → Write` refusal shows on the card
  through ordinary validation; progress keys stay `written` / `skipped`, counting outputs; avoid live edits during
  the browser check (§7 Q5).

### WR5 — UI and browser verification (2026-10-07)

Full `./gradlew build` green (2m28s; 1226 JVM tests, 0 failed); no flake.

- **Palette:** `FormatTool` under `JobGroup_Transforms` in `job-js.yaml`, delegating to `Format`.
- **Writable filter:** `Format`'s `format` attribute declares `writable: true` in its `meta`; `DataFormatEditor`
  reads it from attribute metadata (as `multiline`), and `DataFormatOptions.writableFormats(catalog, current)` keeps
  formats with `ConfiguredFormatDetail.writable`, plus the current value if it cannot write (the field still shows
  what the notation says). `Parse` declares nothing and lists every format.
- **Name help:** new `meta` key `columnPlaceholders: true` on `Format`'s `name` offers the payload's single-segment
  columns. Menu groups are now "Columns", "This value", "From parent" / "From parent → parent", "This Worker"
  (replacing "This file" / "Written"). `Write`'s `name` description explains `${name}` for files vs bytes and
  `${parent.parent.name}` as the source file after Parse; `Format`'s explains that consecutive equal names are one
  output (fixed name, `${parent.name}` per source, a column per value — sort by it first).
- **Browser** (own jar on port 8097, data under `$TEMP`, since deleted): FORMAT in the Transforms ribbon;
  `File → Parse → Write` shows the exact refusal on the card; `Format`'s picker offers CSV / Pipe / Semicolon / TSV
  while `Parse` lists all; both name menus as above. The user's case — two `measurements-*.txt` → `Parse(CSV,
  combine all)` → `Format(CSV)` → `Write(gz)` — finished with `written=1`; `output.csv.gz` held the 4 combined
  columns and 5 rows (`"14,1"` quoted); a second Job `File → Parse(Automatic) → Preview` read it back. Per-source
  `Format(TSV, ${parent.name}${extension})` wrote one file per source, each with its header. Re-running hit
  `existing: fail` by name, as expected. Screenshots for the first four checks; the rest confirmed from page text
  and the files on disk. No live edit exercised (§7 Q5).
- **Tests:** `FileNameTemplateEditorTest` (3, new), `DataFormatOptionsTest` (+1).
- **Docs:** kzen-auto `AGENTS.md` gotcha "Records reach a file only through `Format → Write`", pointing at the
  WR3 / WR4 paragraphs of `docs/architecture.md` (which already cover §4.1 and §4.2).
- **Findings, not fixed:** `Parse(Automatic)` read a 3-row `measurements-1.txt` without its header (`c0, c1, c2`)
  while reporting "Detected: CSV · UTF-8" — header detection on a small sample; explicit CSV is correct. The
  `SelectDataFormatEditor` comment in `job-js.yaml` says blank reads as a "Default" option that
  `DataFormatOptions` no longer offers. Project-defined writable formats need `writable` in their catalogue entry or
  `Format`'s picker hides them.

### WR6 — Parse allocates less (2026-10-07)

`./gradlew build -x :kzen-auto-jvm:test` green; `:kzen-auto-jvm:test` 1230 tests, 1 failed — the known flake
`OwnershipBoundaryTest > formulaPreviewReleasesNestedOwnedValuesAndKeepsCalculatedContent` (`expected:<2> but
was:<1>`), 11/11 when the class reran alone.

- **§4.7, every item landed:** (1) a private `RawRecord` in the parser — one `CharArray` + `IntArray` of field
  ends in `FlatFileRecord`'s layout, cleared per record, trimmed in place; the parser's local functions became
  private members (closures over mutable locals allocated `Ref` boxes per call); `RawField`, `DecodedField`, the
  per-record `StringBuilder` and field `List` are gone. (2) Error spans as start/end pairs in a reused `LongArray`; a
  `LongRange` only for a message. (3) Text and Boolean cells validated in the buffer and copied straight into a
  presized record; only numeric kinds build a `String` (canonical form); the null-flag array only for a row with a
  null; null token and scalar type looked up once per file. (4) One `FlatRecordHeader` and number scratch per
  file; `DelimitedRecord` is itself the null-aware access (replacing `NullAwareFlatRecordAccess`), still a wrapper so
  `JobDataValues.native` is unchanged; `populateCaches` stays eager (lazy would race under fan-out). (5) New
  `RecordProjection` (kzen-auto-jvm `objects/job/worker/data/`) plans the column mapping once per file —
  pass-through or not, cell mapping, header, shared Present states — and copies character ranges for text-like
  kinds; `DataReadCore.projection(previous, …)` reuses the plan while cursor shape, baseline and attributes are the
  same objects; `emitNext` takes it, `Parse` and `Read` keep one each; `DataReadCore.message` stays as a one-off
  wrapper; `JobDataValues.projectedRecord(header, record, states)` overload.
- **Left per row:** the `FlatFileRecord` and its 4 arrays, the `DelimitedRecord`, the `DataValue`, null flags only
  when a null is present.
- **Measurements** (Epsilon slope = (total at 100k − total at 25k) / 75k, one JVM per point; focused = this
  thread's allocated bytes, 50k rows × 12 columns, min of 3 after 3 warm-ups):

  | Measure | Before | After | Change |
  |---|---:|---:|---:|
  | Focused Parse, own shape (B/row) | 6,528.1 | 559.0 | −91% |
  | Focused Parse, superset projection (B/row) | 13,359.7 | 1,149.5 | −91% |
  | S3 Job Epsilon slope (B/row) | ≈ 30,141 | ≈ 23,959 | −6.2 KB (−20.5%) |
  | S4 Job Epsilon slope (B/row) | ≈ 38,708 | ≈ 32,298 | −6.4 KB (−16.6%) |
  | Report Epsilon at 25k / 50k / 100k (unchanged code) | 5,310 / 3,745 / 2,835 | same | — |
  | S3 1M wall, median (spread) | 22,364 ms (22,359–22,480) | 19,148 ms (17,679–22,488) | ≈ −14% |
  | S4 1M wall, median (spread) | 22,705 ms (21,983–24,129) | 24,655 ms (19,568–43,617) | noise |

  Wall time on this machine was unreliable during these runs (Report's own 1M swung 600–1,870 ms); the Epsilon
  slopes are the result. JFR on S3: `ConfiguredDelimitedReader.read` fell from 16.7% of sampled allocation to 1.8%;
  89% of the rest of Parse is the `FlatFileRecord` and its arrays.
- **WR7 gate — closed, no reuse.** Pooling rows could save only the row copy, ≈ 0.56 KB of S3's ≈ 24 KB/row
  (≈ 2.3%). The per-row cost now lies downstream (JFR after: `FormulaWorker.onElement` ≈ 32%,
  `JobDataValues.boundaryNode` ≈ 19%, `ExportWriter` ≈ 7.6%), which row reuse would not move — J5b's rule does not
  convict Parse.
- **S4's extra ≈ 9.3 KB/row attributed:** `FormatChunker.chunk` rebuilds `chunkMetadata` for every record
  (`FormatChunker.kt:94`), because Formula gives each row fresh metadata so the identity check never hits; each
  rebuild runs `ValueMetadata.of(DataOverlay.record(null, fields))`, constructing and validating a `DataContract`
  — ≈ 19–20 KB per formatted record, ≈ 9.6 KB per input row at S3's 50% filter. `FormatWorker.onElement` is 22% of
  S4's allocation, 92.6% of it that line. Not fixed.
- **Other findings, not fixed:** `JobDataValues.boundaryNode` catches an exception per row thrown by
  `FlatRecordValueAccess.native` via `invalid()` (`fillInStackTrace` alone was 13.3% of S3's allocation before);
  `CharacterInput.consumePrefix` allocates an `ArrayList` and a `ReadCharacter` per record when `commentPrefix` is
  set; `FlatRecordHeader.indexOf` allocates a `FieldId` per `field()` lookup; `ParseWorker`'s `withMetadata`
  allocates a `DataValue` per row. None touches J5b.
- **Tests:** new `ConfiguredDelimitedReaderPositionTest` (2 — exact error spans for typed, syntax and width
  failures; green on the old code first) and `ConfiguredDelimitedReaderAllocationTest` (2 — budgets 1,000 / 2,000
  B/row, which the old code's 6,528 / 13,360 would fail); `ConfiguredDelimitedReaderTest` (15) unchanged and green;
  `DataReadCoreTest` (26, two `emitNext` call sites updated); `JobBenchmarkSmokeTest` S1–S4 outputs unchanged.
- **Docs:** none needed — the reused buffer is private to the reader and callers still get an independent row; the
  one-`RecordProjection`-per-Worker rule is in its KDoc.

### WR8 — live edit keeps the open output (2026-10-07)

Full `./gradlew build` green (8m39s; 1239 kzen-auto-jvm tests, 0 failed, 1 skipped); no flake.

- **Compatibility rule.** `Write` (Bytes path): an edit to `directory`, `name` or `compression` (together the
  `Placement`, compared by equality) is incompatible; `existing` and everything else is compatible (`existing` was
  applied when the output began and takes effect from the next one). `Format`: compatibility is an encoding
  `Digest` over format, columns and the header the input contract gives — slightly beyond "format or columns", since
  an upstream change that alters the header changes the bytes too. `Format`'s `name` template is compatible: names
  resolve per record, so a new name simply ends the old output (published whole) and begins another.
- **"Ends" means discard, on both sides.** Publication is atomic and whole; publishing a cut-off output would leave
  the rest of it to collide with its own target (refused as an ended name, failed under `existing=fail`,
  overwritten under `replace`, dropped under `skip`). Discarding restarts the output from the records after the
  edit, `existing` checked at its start, published once at its end — as `Export` under J9.
- **Coordination travels in the data.** A `Format` edit: the first chunk after an incompatible edit is marked
  `restartsOutput`; `Write` discards what it holds of that output and starts again from that chunk, which carries the
  new header. A `Write` edit: `Write` alone — its open output remembers the header bytes of its first chunk
  (`headerLength`); after an incompatible edit it discards and records a `Restart` with that name and header, written
  ahead of the next continuation chunk of that name unless the chunk carries its own. The `Content` path is unchanged
  (`captureMigrationState` returns null, so it restarts as before).
- **API:** `Bytes.mark(headerLength, restartsOutput)` / `headerLength()` / `restartsOutput()` / `copyHeader()`
  (internal); `FormatChunker(encoding: Digest)` with `openName()` / `resume(name)` / `restart()`, marking every chunk
  without allocating; `FormatWorker` carries digest, open name and `received`, surviving a second edit until a record
  is chunked; `WriteWorker` gains `Restart`, `Placement`, `Carried` (`AutoCloseable`), `OpenOutput.header` /
  `replace` / `discard()`, keeps `${time}` across an edit.
- **Tests:** `WriteWorkerTest` 21 — `aLiveEditToExistingKeepsTheOpenOutput` (output equals input: one header, every
  row once, one `Written`); Format name edited to the same / a different resolution (each file whole, one header
  each); incompatible on the `Write` side (compression → only `output.csv.gz`, one header, an unbroken run after the
  edit) and on the `Format` side (columns → new header; TSV → only `output.tsv`, one `Written`);
  `chunksCarriedAcrossALiveEditAreWrittenWhileHeldAndNeverAfterRecycle` (chunks in flight at the edit, 0 unstamped,
  0 used after recycle); no `.part` left in any live-edit test. Also green: `FormatWorkerTest`,
  `FormatAllocationTest`, `PooledBytesTest`, `JobMigrationTest`, `RecyclableRouteTest`, `ExtractMigrationTest`,
  `JobBenchmarkSmokeTest`.
- **Docs:** kzen-auto `docs/architecture.md` "Write over Bytes (WR4)" — the gap sentence replaced by "Live edit
  (WR8)".
- **Not covered:** another producer, or several, feeding one `Write`; an edit that removes a channel drops its
  in-flight chunks (pre-existing — e.g. inserting a Worker between `Format` and `Write` mid-run); no test removes
  `Write` mid-run (the engine closes `Carried`, discarding); a `Write`-side discard runs blocking IO inside
  `loadMigrationState` (as `ReadWorker` already does); the `Content` path still resets counters and `${time}` on an
  edit.

### WR9 — per-row allocation found by WR6's profile (2026-10-08)

`./gradlew build -x :kzen-auto-jvm:test` green; `:kzen-auto-jvm:test` 1250 tests, 0 failed, 1 skipped.

- **(a) `FormatChunker`:** new internal `ChunkMetadata` (`objects/job/worker/format/`), a value access reading
  exactly like `DataOverlay.record(null, [name, parent])` (same contract, fields, failures, snapshot); its contract
  is built once per parent contract (`ChunkMetadata.Shape`, reused while equal), the name value once per output
  name. 14,341 → 3,711 B per record with fresh parent metadata (budget 6,000).
- **(b) `JobDataValues.boundaryNode`:** asks for the native only when the contract declares a root native or the
  type is Opaque / Dynamic / Reference; the try/catch stays for a declared native that refuses. Every `ValueAccess`
  in the tree throws on `native` without a declared root native, so behaviour is unchanged;
  `FlatRecordValueAccess.native` itself is unchanged. `native()` / `scalarNativeProjection` read `payloadContract`,
  not the per-row combined `contract`. 6,192 → 414 B per flat-record read (budget 1,000).
- **(c) `CharacterInput.consumePrefix`:** a primitive replay stack with reused scratch; `ReadCharacter` gone. +72.0
  → +0.0 B/row with a comment prefix (budget 8.0, fails on the old class).
- **(d) `FlatRecordHeader.indexOf(field: FieldId)`:** additive public overload in kzen-auto-plugin; the old
  `indexOf(name, occurrence)` delegates. No consumer calls `indexOf`; not published to Maven Local (not needed for
  the build; external plugins see it after the next `:kzen-auto-plugin:publishToMavenLocal`).
- **(e) `ParseWorker`'s `withMetadata`: not changed** — removing it means the public `DataCursor` attaching
  metadata itself (kzen-auto-common API change) for ≈ 32 B/row, ≈ 0.2%.
- **In passing:** `RunOwnershipLedger.closeableRoot` / `inherit` read `value.type` / `payloadContract` instead of
  building the combined `contract` per row; Formula's `Emitter.send` share 6.3% → 0.1%.
- **Epsilon slope** (as WR6): S3 Job ≈ 23,736 → ≈ 17,759 B/row (−25%); S4 Job ≈ 32,502 → ≈ 16,964 B/row (−48%);
  Report unchanged. S4 now allocates less than S3 (S3 ends in `ExportWriter`, ≈ 13% building a `FlatFileRecord` per
  row).
- **Wall time — machine state, not code.** Normal GC, 1M × 3, after: S3 Job 57,296 ms (57,181–58,525; GC 41/492),
  S4 Job 54,135 ms (54,088–57,293; GC 20/550), Report 1.7–1.9 s — 2–3× WR6's numbers. Isolated the same day: an A/B
  of HEAD (`c97d82ea`, pre-WR) against the live tree, run alternately on the same machine state (S3, 200k rows, 3
  runs + warm-up), put the live tree's Job **18–23% faster** (11.7–12.2 s vs 14.4–15.3 s) with Report equal. Both,
  and unchanged code, ran 2.3–4× slower than the evening before: the CPU has been capped at ≈ 2 GHz (`% Processor
  Performance` 81–85%, firmware max 205%) since an AC unplug / replug at 9:19 PM local, below the OS (`% Performance
  Limit` 100). Re-measure wall time once the machine runs at full clock.
- **What dominates now (S4 JFR):** kzen-lib contract construction — `DataContract.<init>` 24.5%, `walk` 30.8%,
  `ValueMetadata.<init>` / `MetadataContract.of` 21.4%, `validateNativeMetadata` 20.4% (inclusive). By site:
  `FormulaWorker` line 107 (`DataOverlay.record` + `ValueMetadata.of`, 26%) and `ChunkMetadata.Shape.metadata` →
  `ValueMetadata.<init>` (13.6%). `boundaryNode` 15.3% → 1.7%; `fillInStackTrace` gone (was 11.8%).
- **Root-cause follow-up (kzen-lib, needs a publish):** `ValueMetadata` accepting a precomputed metadata contract
  (or caching one per contract instance), and a reusable `DataOverlay` shape with a precomputed contract — would
  remove most of Formula line 107 and the rest of Format's per-record cost. Chunk coalescing (§7 Q3) remains the
  other lever.
- **Tests:** `JobDataValuesTest` (+5, incl. `aFlatRecordWithoutANativeIsReadWithoutFailing`), `ChunkMetadataTest`
  (4, new), `FormatAllocationTest.freshParentMetadataReusesTheChunkContract`,
  `ConfiguredDelimitedReaderAllocationTest.aCommentPrefixCostsNothingPerRow` — each allocation pin fails on the old
  code.

### WR10 — Automatic reads a small file's header (2026-10-08)

`./gradlew build -x :kzen-auto-jvm:test` green; `:kzen-auto-jvm:test` 1258 tests, 0 failed, 1 skipped.

- **Root cause** (`DelimitedProbe.kt` `hasHeaderEvidence` / `classify`, rule 3 of the detection analysis §7.5):
  `classify` tried `BigInteger` first, so `14` and `12.5` were different classes and a small mixed numeric column
  never counted as stable; and only Boolean and numbers were classes, so a date column gave no evidence. In
  `measurements-1.txt` the temperature column mixed whole and decimal values (and held the quoted `"14,1"`), the date
  column did not count, the station column is text — no evidence, so row one stayed data (`c0, c1, c2`) while the
  format still read "Detected: CSV · UTF-8". `measurements-2.txt` (whole-number humidity) was already detected.
- **Fix:** classes are Boolean, **Number** (anything `BigDecimal` accepts) and **ISO date/time** (`LocalDate`,
  `LocalDateTime`, `OffsetDateTime`); rules 1–2 unchanged, so a row one holding a number or date still never
  qualifies as a header. **Default without evidence unchanged:** row one stays data under positional labels — the
  documented "retention over guessing" (§7.5, §4.2), pinned by `allTextTableRetainsRowOneWithPositionalLabels`;
  `.csv` / `.tsv` extensions already keep the format's `header: present`. Analysis §7.5 rule 3 updated to match.
- **Also:** the `SelectDataFormatEditor` comment in `job-js.yaml` now describes the actual picker (no blank
  choice; Automatic is a catalogue format; an unoffered saved value stays listed as "not offered by this server").
- **Tests:** `DelimitedProbeTest` +6 (header over 1 / 2 / 3 data rows; whole + decimal in one column; ISO date,
  date-time, offset date-time; a date column deciding when the numeric column holds `"14,1"`; small headerless
  files; mixed columns giving no evidence), 4 of them failing before the fix; new `ParseWorkerAutomaticTest` (2:
  before Run — no error, columns `station, date, temperature, humidity`, Detected `CSV · UTF-8` per file; the run —
  5 combined rows, `"14,1"` one value), both failing on the old probe; fixture `test/job/content/parse-automatic-test.yaml`.
  The detection cache (`SuccessfulFormatResolutionCache`) is in-memory, so nothing stored needs invalidating.
- **Still read as data under Automatic (by design, rule 2):** labels with edge spaces (`station, date`) or symbols
  (`temp (°C)`, `humidity%`).

### WR12 — cold-start Preview truncation (2026-10-08)

kzen-lib `./gradlew build publishToMavenLocal` green (JVM + browser JS; same version, no bump); kzen-auto `build -x
:kzen-auto-jvm:test` green, `:kzen-auto-jvm:test` 1260 tests, 0 failed, 1 skipped.

- **Root cause (kzen-lib):** the structural reader prepares each class lazily on its first read, inside the timed
  traversal — `NativeObjectValueAccess.kt` (`NativePropertyPlans.computeValue`: `declaredMemberProperties`,
  `primaryConstructor`, `isAccessible`, `BeanShape`; `NativeTypeTokens` → `starProjectedType` per new child) and
  `DefaultDataAdapterRegistry.kt` (re-lifting a Dynamic / listing child: `value::class.isData`, `starProjectedType`,
  `DefaultNativeTypeResolver.describe(KType)` on a miss) — while both budget clocks were plain wall time from the
  capture's start (`PreviewCapture.Writer.started`, kzen-auto; `DataSnapshot`'s `SnapshotWriter.started` /
  `checkBounds`, serving `FlowRun.snapshotMessage` and `ScriptRunContext.displayOf`). Fresh JVM: first snapshot of a
  fresh native 39 ms wall, 27 ms of it class setup; ≈ 1–3 ms per later fresh class.
- **Fix:** kzen-lib `exec/data/value/budget/` — `ReadPreparation.prepare { }` runs one-time per-type setup and adds
  its time to a per-thread total (nested counted once, correct on throw; new `platformThreadLocal` common / jvm /
  js); `ReadBudget(maximum)` is the one shared clock, `exhausted()` = wall time since start minus that thread's setup
  time since. Inside `prepare`: `NativePropertyPlans`, `BeanShape`, `DefaultNativeTypeResolver.describe` misses, and
  a new `NativeClasses` per-class cache (star-projected type, token, `isData`) replacing `NativeTypeTokens` and the
  registry's per-lift reflection. `DataSnapshot` (Flow, Script) and kzen-auto `PreviewCapture.Writer` use
  `ReadBudget`; budget values unchanged.
- **Tests:** kzen-lib `ReadBudgetTest` (common, JVM + JS), `DataSnapshotTest.durationLimitChargesReadingButNotTypePreparation`
  (150 ms setup inside a 50 ms limit completes; the same delay outside setup is rejected), `NativeObjectValueAccessTest`
  (fresh classes charge setup; a second read charges zero); kzen-auto `PreviewCaptureTest`
  `preparingATypesReaderIsNotChargedToTheTimeBudget` and `slowReadingIsStillCutAtTheTimeBudget` (a 150 ms getter is
  still cut). The cold class is made deterministic by fake readers that delay inside `ReadPreparation.prepare`.
- **Seams kept** (`PreviewWorker.captureNanos`, `FlowRun.snapshotMillis`), comments corrected: with them removed,
  the content tests still truncated under 24 CPU hogs in 4 of 4 completed runs; logged at exhaustion — wall 50–68
  ms, CPU 0–31 ms, setup 0–10 ms — i.e. the thread waiting for a CPU, inherent to a wall-clock budget.
- **Findings, not fixed:** `DefaultNativeTypeResolver.descriptionCache` / `resolutionCache` are plain
  `mutableMapOf` / `IdentityHashMap` while `JobDataValues.adapters` is one process-wide registry used from
  concurrent Worker threads — a data race; first-ever snapshot in a JVM still pays ≈ 16 ms of non-per-class code
  loading (kotlin-reflect's own ≈ 400–480 ms startup normally happens earlier, at lift); wall-clock budgets still
  cut Previews on a CPU-starved machine (thread CPU time would not bound blocking getters and ticks at 15.6 ms on
  Windows — a design choice); `ScriptRunContext.displayOf` inlines `maximumDurationMillis = 100` (CC-01).

### WR11 — metadata shapes (2026-10-08)

kzen-lib `./gradlew build` green (JS `MetadataShapeTest` 9/9) and republished to Maven Local (all four artifacts,
0.30.0-SNAPSHOT, no bump); kzen-auto `build -x :kzen-auto-jvm:test` green, `:kzen-auto-jvm:test` 1262 tests, 0
failed, 1 skipped; kzen-project compiles unchanged.

- **API (kzen-lib `exec/data/value/overlay/`):** public `MetadataShape(base: MetadataContract?, fields:
  List<Pair<FieldId, DataContract>>)` with `fields`, `contract`, `fits(base, values)`, `metadata(base, values)`;
  internal `OverlayLayout` (composed contract, ids, positions, which value sets each) and `OverlayAccess` (reads by
  position, interning state created lazily under `platformSynchronized`). `ValueMetadata` holds its contract and the
  single-entry combine cache in a shared `internal class Contracts`; `internal fun shaped(access, root, contracts)` is
  the trusted factory, called only by `MetadataShape.metadata` after checking the base's contract and each value's
  `payloadContract` against the shape (identity, then equality) and the count — so records of one shape share the
  combined contract (pinned with `assertSame`). The public `ValueMetadata(access, root)` and `ValueMetadata.of` are
  unchanged. `DataOverlay.record` now runs through `OverlayLayout` (no per-row `LinkedHashMap` / `Lazy`), though it
  still builds its contract.
- **Mismatch fails by name** (`invalidContract`: base / count / field value does not fit) rather than falling back,
  so a stale shape cannot silently bring the per-row cost back; callers check `fits` and rebuild. Contract errors
  (duplicates, opaque or native members, non-record base) surface when the shape is built.
- **kzen-auto:** `FormulaWorker` keeps one shape (calculated-field contracts built once per compile), rebuilt when it
  no longer `fits`; `ChunkMetadata` is now `shape(parent)` / `name(name)` / `values(name, parent)` over a
  `MetadataShape` that `FormatChunker` keeps. Not converted (once per file or unit): `FileValues.metadata`,
  `ParseWorker.itemMetadata`, `ReadWorker.unitValue`, test / benchmark `withMetadataFields`.
- **`LiteralDataValues.lift`** reuses `expected` as the literal's contract when it carries nothing beyond structure
  and constraints, so the shape's identity check hits. As delivered the condition omitted `nativeByPath`, which would
  have carried an expected root native or specific opaque classes onto a plain literal (the old path builds only
  `kotlin.Any` for opaque members); corrected in review to require `nativeByPath.isEmpty()`, making reuse exactly the
  case where the old construction is equal. After the correction: kzen-lib `jvmTest` green and republished; kzen-auto
  Formula / Format / chunk / allocation / benchmark-smoke tests (50) green; full kzen-auto suite to rerun with WR13.
- **Epsilon slope** (as WR6, two passes each, noise ≈ ±60–90 B/row): S3 ≈ 17,700 → ≈ 5,850 B/row (−67%); S4 ≈
  17,280 → ≈ 4,070 B/row (−76%); Report unchanged. Wall time indicative only (CPU capped).
- **Allocation pins** (each fails on the old code): kzen-lib `MetadataShapeAllocationTest` 175 B/record (budget
  400; old compose ≈ 13.7–15.5 KB); `FormulaWorkerAllocationTest` 1,351 B/row (budget 2,000; old 14,944);
  `FormatAllocationTest` fresh equal-contract parent 551 B (budget tightened 6,000 → 1,000; was 3,711) and fresh
  parent of one shape 312 B (budget 500, new). WR3's steady state still 0 B.
- **What dominates now** (JFR, S3 / S4 at 100k): Parse's `FlatFileRecord` construction and growth ≈ 25–40%;
  coroutine / IO plumbing (`RunEngine.blocking`, drive loops, `Emitter.send`, leases) ≈ 15%; Formula's native
  projection ≈ 4–6%; `DataContract.equals` / `hashCode` ≈ 4% (they allocate through `constraintSets`, from
  `ColumnProjectionDescriptor.from`). Metadata composition no longer appears near the top.
- **Findings, not fixed:** `DataContract.equals` / `hashCode` allocate per call; `LiteralDataValues.lift` always runs
  `inferType`, even with `expected`; `DataOverlay` could move into `value/overlay` (CC-15); the public
  `ValueMetadata(access, root)` constructor has no kzen-auto callers left.

### WR13 — thread-safe native type resolution (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 434, jsBrowserTest 384, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (0.30.0-SNAPSHOT, no bump); kzen-auto `build -x :kzen-auto-jvm:test` green,
`:kzen-auto-jvm:test` 1262 tests, 0 failed, 1 skipped — the first full run after WR11's `lift` correction; kzen-project
compiles.

- **Fix, one file** (`DefaultNativeTypeResolver`): `descriptionCache` → `ConcurrentHashMap`, a miss computed
  outside the map and stored with `putIfAbsent`, every caller getting the stored instance (so WR11's identity-first
  `fits` stays reliable); `resolutionCache`'s outer loader map copy-on-write (`@Volatile`, loader identity), a
  `ConcurrentHashMap` per loader, same miss pattern; `released` `@Volatile`, set before `close()` clears. No lock is
  held while describing or resolving and no `computeIfAbsent`, so re-entry (custom describers, `resolveCustom`, a
  loader's `loadClass`) cannot deadlock; the only lock copies the small loader map when a loader is first seen. Hits
  take no lock and allocate nothing. WR12's `ReadPreparation.prepare` still wraps description.
- **Audit, safe as-is:** `DefaultDataAdapterRegistry` (immutable, delegates); `NativeClasses` / `NativePropertyPlans`
  / `BeanShape` (`ClassValue`, no same-key recursion); `ReadPreparation` (thread-local); `DataContract` lazies
  (synchronized `by lazy`, acyclic); `ValueMetadata.Contracts.combined` (final-field publication — a race only
  recomputes); `OverlayAccess` own state (locked, lock order follows construction); `OverlayLayout` /
  `MetadataShape` (construction-only); kzen-auto `JobDataValues.flatHeaders`, `ColumnProjection.defaultCache`
  (non-recursive `computeIfAbsent`), `FlowRun.nativeTypeResolver` (per run).
- **Tests** (`NativeTypeResolverConcurrencyTest`, kzen-lib jvmTest): two gated, deterministic — concurrent misses of
  one type share one description; concurrent resolutions in a new loader share one result (both would also time out
  if a lock were held while computing); and a stress test — 28 runtime-compiled Java types (enum, self-recursive
  record, mutually recursive pair, nested records with collections and maps, beans) × 12 fresh loaders × 3 rounds,
  8 threads describing / resolving / lifting / snapshotting through one registry, compared with a single-threaded
  run, one description and resolution instance per (loader, type), 120 s hang guard. Old code: gated tests fail
  `assertSame`; stress 6 / 6 failed (59–80 of 336 keys with more than one result). New code: 8 / 8 passed.
- **Findings, not fixed:** (1) `NativeObjectValueAccess` (node table, per-node field / element / entry maps) and
  `TaggedUnionValueAccess` intern nodes lazily without synchronization — today each such value appears to be read by
  one thread at a time, but fan-out and live inspectors (`JobTransferConditions`) and reads through WR11's
  `OverlayAccess` to a native base are unprotected if shared readers are intended; (2) mutually recursive types
  overflow the stack single-threaded — `DataTypeAlgebra.accepts` (`DataTypeAlgebra.kt:112`) expands a named
  reference against an inline record forever, its guard recording only reference-against-reference pairs
  (reproduced lifting Java records `Right(String, List<Left>)` / `Left(String, List<Right>)`); (3) the process-wide
  resolver never evicts, retaining plugin / script class loaders and `KType`s for the process's life. (1) and (2)
  queued as WR14 / WR15, (3)'s dynamic-loader part as WR16. On (3) the user settled 2026-10-08: plugin class loaders load once and stay until a project
  restart, by design; dynamic-expression loaders must stay releasable, otherwise memory leaks.
