# Format and Write: records to bytes as a chain of Workers — constituent plan (WR)

> **Status: planned 2026-10-07; WR1–WR6 landed 2026-10-07; WR7 closed by its gate; follow-ups WR8–WR10 landed; WR11–WR26 landed.** Written with the user after combining two flat files in a Job
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

**WR17 — one definition per class, whichever is described first** (user-approved 2026-10-08, WR15 finding 1).
*Problem:* the native describer names only a class that recurs while it is still open and inlines the rest, so for
`X(a: Y?)` / `Y(x: X?, y: Y?)` describe(X) and describe(Y) carry different `def[Y]`. Assignability accepts the pair
(WR15), but `DataContract.withFields` / `DataOverlay.contract` throw a false "Conflicting carried definition 'Y'",
and equality-keyed caches (`compiledForContract`, `MetadataShape.fits`, `conformExpected`'s fast path) miss.
*Fix:* make the definition of a class canonical — independent of the entry point — in `DefaultNativeTypeResolver`
(e.g. name every class on a cycle, computed per strongly connected component, or describe each recursive class
from its own root and reuse that definition), keeping WR13's concurrency and WR16's releasability; fall back to a
mutual-assignability conflict test in `withFields` only if canonical definitions prove impossible. *Tests:* the
`X` / `Y` pair described from either side yields equal definitions; carrying fields from both into one contract
succeeds; self- and mutual recursion from WR15 unchanged.

**WR18 — run-time tokens of generic collections** (user-approved 2026-10-08, WR15 finding 2). *Problem:*
`resolver.isAssignable(describe(T), lift(t))` on native tokens rejects any `T` with a non-empty generic collection
field — even non-recursive `Box(items: List<String>)` — because the run-time token is star-projected while the
design-time one carries arguments. *Fix:* compare a star-projected run-time token against an argument-bearing
expected one by checking the elements present (the structural contract already does), or give the run-time node the
expected argument when its contents conform; decide which with the callers of native-token acceptance (Opaque
`lift`, `FlowRun`'s check). *Tests:* `Box(items: List<String>)`, nested and map-valued generics, and a genuinely
mismatched element still rejected.

**WR19 — recursive metadata in Formula compilation** (user-approved 2026-10-08, WR15 finding 3). *Problem:*
kzen-auto's `JobExpressionCompiler.metadataClasses` (`visit`) recurses through `expanded()` with no guard, so a
recursive metadata contract would overflow (found by reading). *Fix:* reproduce, then guard the walk by definition id
(a recursive definition maps to one generated class referenced from itself). *Tests:* a Formula over a value whose
metadata is recursive compiles and evaluates `meta[...]` through two levels.

**WR20 — definition natives through runtime contracts** (user-approved 2026-10-08, WR15 finding 4). *Problem:*
`DefaultDataAdapterRegistry.runtimeContract`'s listing and non-empty-mapping paths drop `definitionNatives`, so
navigating a recursive value with opaque members past one expansion may fail (found by reasoning). *Fix:* reproduce,
then carry `definitionNatives` (and definitions) through every runtime-contract path, as the empty-mapping path now
does after WR15. *Tests:* a recursive value with an opaque member at depth ≥ 2, lifted as a list element and as a map
value, navigates and validates.

**WR21 — empty collections into typed inputs** (user-approved 2026-10-08, WR18 finding 3). *Problem:* a Flow
input typed with a collection (`of: {is: List, of: String}`, likewise Set / Map) rejects an **empty** run argument:
lifted without an expected contract, an empty collection becomes `Listing(Dynamic?)` (or `Mapping(Dynamic, Dynamic?)`)
and the type algebra has no bottom element type, so `Listing(Dynamic?)` is not assignable to `Listing(Text)`.
*Fix:* reproduce through `FlowRun.validatePort`, then let an empty run-time collection be accepted by any collection
type of the same kind — e.g. an explicit empty / bottom element type for collections lifted empty, or an
emptiness-aware rule in the run-time acceptance — without loosening design-time assignability (a design-time
`List<Dynamic?>` must still not satisfy `List<Text>`). Check every other place an empty collection meets an expected
contract (`conformExpected`, Opaque lift, `JobDataValues.lift` with an expected contract, WR15's empty-mapping path).
*Tests:* empty List / Set / Map into typed Flow inputs (kzen-auto `FlowTypedPortTest`), a non-empty mismatched one
still rejected, design-time assignability unchanged.

**WR22 — run-time arrays keep their element type** (user-approved 2026-10-08, WR18 finding 4). *Problem:* a
run-time array lifts as `Listing(Dynamic?)` because the component type is dropped, so a record such as
`Coded(codes: Array<String>)` fails when its field is lifted against the described contract. *Fix:* reproduce, then
derive the element contract from the array's component class (`String[]` → `Listing(Text)`, object arrays of a
described class → that class's contract, primitive arrays per the existing refusal / scalar rules), consistent with
how the describer treats `Array<T>` at design time. *Tests:* `Coded(codes: Array<String>)` lifts, validates and
navigates; nested arrays; an array of a recursive class; an empty array.

**WR23 — contract equality without allocation** (user-approved 2026-10-08, found by the S4 allocation bisect).
*Problem:* `DataContract.equals` / `hashCode` allocate on every call — `equals` builds two `constraintSets` maps
through `mapValues` even when both contracts carry no constraints. Per-row contract lookups pay it:
`ColumnProjectionDescriptor.from`'s `computeIfAbsent` cache keyed by contract (Filter's `ValueSetFilterWorker`,
`FormulaWorker`), ≈ 100–170 B/row sampled in both S3 and S4, plus every resolver resolution hit (WR16 finding 1).
*Fix:* make `equals` / `hashCode` allocation-free on the common path — identity first, compare `constraintsByPath`
directly when both are empty or sizes differ, build order-insensitive sets only when it matters (or cache a
normalized form / the hash once per contract, contracts being immutable) — and check identity before the per-row
cache lookups where the same contract instance recurs. Equality semantics must not change. *Tests:* equality /
hash unchanged across constraint orderings and definitions (existing contract tests plus new ones); an allocation
test that a hit on an equal-but-not-identical contract allocates nothing; Epsilon slope A/B for S3 and S4 against
a worktree of the previous state in the same session, 6+ passes per side (per the bisect's noise rules).

**WR24 — test work roots left in the temp directory** (user-approved 2026-10-08, found in WR23). *Problem:* a full
`:kzen-auto-jvm:test` run leaves `kzen-auto-test-work*` directories in `%TEMP%` (23 accumulated so far, some empty,
some holding `code-cache` / `index` / `build`). `KzenAutoContext.forTest()` creates one per test context and
`close()` deletes it best-effort, so a leftover means either a test context that is never closed, or a delete that
fails silently (on Windows, typically a file still open — a jar held by an unclosed `URLClassLoader`, an index or
log handle). *Fix:* find which tests leave roots and why (log the creating test and the swallowed delete failure);
close every test context (shared fixtures / `@AfterAll`, or a test-scoped registry that closes stragglers), and
release whatever handle blocks deletion at its owner rather than retrying the delete. Don't delete the existing
leftovers from the user's `%TEMP%` — report them. *Tests:* a full suite run leaves no new `kzen-auto-test-work*`
directory; a guard (e.g. a JUnit extension or a shutdown check in test mode) that names a test context left open.

**WR25 — kit verify leaves its temp module root** (user-approved 2026-10-08, WR24 finding 3). *Problem:* production
code — `PluginCompatibilityKit.verify` creates a `kzen-kit-module*` temp module root and never deletes it, so every
plugin verify (and `CompatibilityKitBootTest`) leaves one in the temp directory (109 accumulated). *Fix:* the verify
owns the root: delete it when verification ends (success or failure), after closing whatever holds files in it (the
module's `URLClassLoader`, scopes); log a failed delete rather than failing verification. *Tests:* a verify — passing
and failing — leaves no `kzen-kit-module*` directory.

**WR26 — tests clean up their temp files** (user-approved 2026-10-08, WR24 finding 2). *Problem:* besides the
work roots WR24 fixed, a full `:kzen-auto-jvm:test` run leaves ≈ 59 temp entries (`file-source-*`,
`read-worker-file-cache*`, `universe*`, `schema-cache-*`, …), `pluginUniverseTest` ≈ 35 (`module*`, `universe*`,
`work-*`, `kit-verify*`), and kzen-lib's JVM tests (`kzen-native-types-*`, `kzen-bean-shape-*`, `kzen-recursive-*`,
`origin*`, `aggregate*`) and the kzen-auto-test self-test (`kzen-sut-*`) leave more. *Fix:* each test deletes what it
creates (JUnit `TemporaryFolder` / `@TempDir`-style ownership, `use {}` / `finally`), releasing open handles first;
fix any main-code owner that leaks on a test's behalf at the owner, as WR25 does. Not by redirecting the test temp
directory, which would hide leaks. *Tests:* before/after temp-directory listings for each suite show no new entries;
extend WR24's guard only if a cheap general check exists.

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
- [x] WR14 — shared readers of one native value (2026-10-08)
- [x] WR15 — mutually recursive types (2026-10-08)
- [x] WR16 — dynamic-expression class loaders stay releasable (2026-10-08)
- [x] WR17 — one definition per class, whichever is described first (2026-10-08)
- [x] WR18 — run-time tokens of generic collections (2026-10-08)
- [x] WR19 — recursive metadata in Formula compilation (2026-10-08)
- [x] WR20 — definition natives through runtime contracts (2026-10-08)
- [x] WR21 — empty collections into typed inputs (2026-10-08)
- [x] WR22 — run-time arrays keep their element type (2026-10-08)
- [x] WR23 — contract equality without allocation (2026-10-08)
- [x] WR24 — test work roots left in the temp directory (2026-10-08)
- [x] WR25 — kit verify leaves its temp module root (2026-10-08)
- [x] WR26 — tests clean up their temp files (2026-10-08)

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

### WR14 — shared readers of one native value (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 443, jsBrowserTest 384, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1262 tests, 0 failed, 1 skipped; kzen-project
compiles (`kzen-project-common:compileKotlinJvm`, `kzen-project-jvm:compileKotlin`).

- **Which carriers really are shared** (read from kzen-auto's Job runtime): (a) a run's parameter inputs — every
  Worker gets the same `execution.inputs` bindings (`JobRun.kt:317`) and Workers run concurrently on the RunEngine
  pool, reading them through `EngineJobControl.parameter` → `JobDataValues.boundary`; native-backed when a hosted
  child Job (Script, Flow, `RunWorker`) passes native arguments; (b) metadata attached to many values — Parse's
  `itemMetadata` (every row of a file), Extract's archive parent metadata (`FileValues.metadata`),
  `PathProjectionWorker` (one element's metadata on N rows), `FormatChunker`'s chunk metadata — read at once by
  Formula `meta[...]`, Format and Write's `FileNameTemplate` on different Workers; an `OverlayAccess` over literals and
  sometimes native children. Handed off one reader at a time only: settled results, Flow, Script, Preview, Sort.
  `JobTransferConditions` (the "live inspectors" of the problem) has no callers, and fan-out (J6) is not built.
- **Fix, kzen-lib** (`NativeObjectValueAccess`, `TaggedUnionValueAccess`): a node's token stays its index into a
  `@Volatile` table array, written under the view's lock and replaced by a doubled copy when full, so a reader holding
  a token finds its entry in whichever table it sees. Each node's three child maps become one `ConcurrentHashMap`
  keyed by field id, index or mapping key (a node is one of record / listing / mapping), created only for a non-null
  structural node. A hit is a map `get` plus a volatile read — no lock, no allocation. A miss reads the native (user
  getters) outside any lock, then takes the lock only to re-check and store, so every reader of one child gets the
  node stored first and the loser's entry is dropped. `TaggedUnionValueAccess` does the same for delegate → token
  (`ConcurrentHashMap`, check, then lock and re-check). A dense table over a lock-free append because tokens are
  indexes and a miss happens once per node; the unreachable "Union node has no selected backing position" error
  folds into "requires the selected union node". Scalar leaves no longer allocate three empty maps.
- **Contract** (KDoc on `ValueAccess`, the interface the plan calls `DataValueAccess`): safe for concurrent readers;
  lazy nodes give every reader of one child the same node and keep their meaning once handed out; a value reaches
  another thread through a happens-before edge; the backing object must not change while shared, and a native's
  getters run on whichever thread reads.
- **Audit, safe as-is:** `LiteralValueAccess` (built up front, immutable); `OverlayAccess` (own interning under
  `platformSynchronized`); `NodeEntry.setSnapshot` (synchronized `by lazy`); kzen-auto `FlatRecordValueAccess`
  (`FlatFileRecord`, `DelimitedRecord`), `RecordProjection`'s projected access and `PooledBytes` (fixed tokens, no
  lazy nodes) — no kzen-auto change.
- **Tests** (`NativeValueAccessConcurrencyTest`, kzen-lib jvmTest, new): five gated, deterministic — two readers
  inside one first read of a field, an element, a mapping entry, a field through an expected union, and an element
  through an overlay over a native base, released in arrival order (the later resumes only after the earlier
  finished), asserting one node, also for a later read; four stress — one value (native, union over native, union
  over a literal, overlay over native) × 8 threads × 100 fresh rounds, walks rotated per thread, each walk equal to a
  single-threaded one, one token per path across threads, no token shared by two paths, 120 s hang guard. Old code:
  9 / 9 failed in each of 3 runs (stress in round 0 — "Data node N does not belong to this native backing", NPE,
  "field is valid only for record nodes", divergent content); a first gate releasing both racers at once let the old
  code pass 1–2 of 8 per run (a lost list append can hand both the same index), hence the ordered gate. New code: 9 /
  9 passed in each of 3 runs; stress ≈ 1.5–4 s each, gated < 0.4 s.
- **Epsilon slope** (as WR6, two passes, one JVM per point): S3 ≈ 5,815 / 5,907 B/row (WR11 ≈ 5,850); S4 ≈ 3,777 /
  3,986 B/row (WR11 ≈ 4,070); Report unchanged. No regression: both within the passes' spread (≈ ±100 B/row), and a
  hit now allocates nothing while a scalar leaf drops its three empty maps. Wall time indicative only (CPU capped).
- **Findings, not fixed:** (1) `OverlayAccess` takes its monitor on hit paths (`plainBaseFieldNode`, `nestedBound`)
  and holds it while calling a native base's `field` (user getters) — correct, but shared metadata serializes its
  readers; lock-free needs common atomics (expect / actual); (2) `FlatFileRecord.cachedHash` can be seen before its
  hash is written if a row were shared (Jobs don't share rows); (3) Explore / Pivot comments claim single-threaded
  access that `WorkerBase.kt:78` contradicts (tables, not `DataValue`s); (4) `JobTransferConditions` and its
  sender / delivery / claim classes are dead code; (5) pre-existing "No cast needed" warning at
  `DefaultDataAdapterRegistry.kt:142`.

### WR15 — mutually recursive types (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 450, jsBrowserTest 389, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1262 tests, 0 failed, 1 skipped, and
`:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`).

- **Why it overflowed:** the native describer names only a class that recurs on its open stack and inlines the
  partner, so the contract rooted at `Right` holds `def[Right]` with `Left` inline, while the run-time contract of a
  nested `Left` (rooted at `Left`) holds `def[Left]` with `Right` inline. The two unroll the cycle out of phase, so
  the comparison only ever meets reference-against-inline pairs, which the old guard never recorded.
- **Fix** (`DataTypeAlgebra`): every (expected, actual) pair with a reference on either side goes through one
  `acceptsReference`. Each side expands through its own table (`Definitions.expected` / `.actual`; the same id may
  name different types in each), and a pair of references missing either definition stays nominal as before. The
  pair is recorded in a private `Assumptions` log, keyed by value, before its expansions are compared: met again
  while in progress it is accepted (the coinductive rule), and it stays accepted once its comparison succeeds. On
  failure everything recorded since the pair started is dropped, because such a pair can have succeeded only through
  an assumption now known to be false; a failed union branch therefore leaves nothing behind for the next branch,
  and the verdict stays the conjunction of every check (a mismatch after the recursive field still rejects). It ends
  because contracts hold finitely many such pairs and every unbounded walk expands a reference infinitely often.
  That relies on contractiveness, which `DataContract` now enforces: a definition must not reach itself through
  union variants alone (`Loop = Loop? | Text` describes no value, and the coinductive rule would accept anything for
  it). The log is created at the first reference, so a comparison that meets none allocates one small object where
  the old code allocated an empty `LinkedHashSet`.
- **Fix** (`DefaultDataAdapterRegistry.runtimeMappingContract`): an empty map lifted against an expected mapping
  kept the expected shape but dropped its definitions, so an out-of-phase reference inside it could not be expanded
  (validation failed at an empty `Map<String, MappedLeft>`). It now keeps them, as a non-empty map's contract does.
- **Audit, safe as-is:** `NativeTypeResolver`'s `resolvedAcceptance` (recurses through union variants only, finite
  given contractiveness; delegates to the fixed algebra; `replaceOpaque` stops at references); `DataContract`
  equality, hash, digest, `walk`, `typeAt`, `references` / `unresolvedReferences` (references are leaves); describe
  (the open-class guard); `LiteralDataValues` (`inferType` keeps an open list; build / decode follow the value and
  expand one level); `selectVariant` (no definitions); `DataValueAlgebra.validate` (follows the value, one
  `isAssignable` per node); `DataSnapshot` (identity cycle guard); `MetadataShape`, `OverlayLayout`, `DataOverlay`
  (no recursive type walks); `DataTypeExecutionValue`, `join` (finite); nothing in `jsMain`.
- **Tests:** `DataTypeAlgebraTest` — mutual recursion out of phase through a list, a map and a nullable field (both
  directions, and against a required field); self-recursion out of phase (`Chain` against an unrolled chain, both
  ways); an incompatible recursive pair (a partner's field after the recursive one differs) still rejected; an
  assumption made inside a failed union branch does not decide a later branch. `DataContractReferenceTest` — a
  definition reaching itself through union variants, directly or through another union, is invalid; through a
  listing it is valid. `RecursiveContractTest` — runtime-compiled Java records `Right(String, List<Left>)` /
  `Left(String, List<Right>)` lift, snapshot and validate, a nested `Left` lifts against its enclosing contract's
  child and validates against both contracts, and the resolved enclosing contract accepts `Left`'s description;
  Kotlin pairs through a list, a map and a nullable field lift, snapshot and validate.
  `NativeTypeResolverConcurrencyTest` — the WR13 stress test now also lifts the mutual pair. Old code: 7 of 25
  failed — `StackOverflowError` in both algebra recursion tests (`DataTypeAlgebra.kt:112`), both lift tests and the
  stress test; the failed-branch test wrongly accepted; the contractiveness test threw nothing. New code: all pass.
- **Epsilon slope** (as WR6, two passes, one JVM per point): S3 ≈ 5,933 / 5,931 B/row (WR14 ≈ 5,815 / 5,907, WR11 ≈ 5,850); S4 ≈ 3,961 / 3,782 B/row (WR14 ≈ 3,777 / 3,986, WR11 ≈ 4,070); Report unchanged. No regression: S3 sits within the noise band (≈ ±100 B/row) above WR11, the passes agree to within 2 B/row, and S4 lies inside WR14's spread; a comparison that meets no reference now allocates one small object instead of a `LinkedHashSet`. Wall time indicative only (CPU capped).
- **Findings, not fixed:** (1) definitions are not canonical per describing root: for `X(a: Y?)` /
  `Y(x: X?, y: Y?)`, describe(X) and describe(Y) give different `def[Y]`. Assignability accepts them now, but
  `DataContract.withFields` / `DataOverlay.contract` throws a false "Conflicting carried definition 'Y'" (confirmed
  by a probe), and equality-keyed caches and `conformExpected`'s equality fast path miss. Fix options: canonical
  definitions in the describer, or a mutual-assignability conflict test in `withFields`. (2)
  `NativeTypeResolver.isAssignable(describe(T), lift(t))` on native tokens rejects any `T` with a non-empty generic
  collection field (`java.util.ImmutableCollections.List12<*>` is not assignable to `List<Right>`; likewise a
  non-recursive `Box(items: List<String>)`), because the run-time token is star-projected; the test compares resolved
  contracts instead. (3) kzen-auto `JobExpressionCompiler.metadataClasses` (`visit`) recurses through `expanded()`
  child records without a guard, so a recursive metadata contract (e.g. Formula calculated metadata from a recursive
  native) would overflow; found by reading, not reproduced. (4) `runtimeContract`'s list and non-empty map paths
  drop `definitionNatives`, so navigating a list of recursive values past one expansion of a definition with opaque
  members may fail; found by reasoning, not reproduced. (5) pre-existing "No cast needed" warning at
  `DefaultDataAdapterRegistry.kt:142`.

### WR16 — dynamic-expression class loaders stay releasable (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 456, jsBrowserTest 389, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1262 tests, 0 failed, 1 skipped, and
`:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`).

- **Reproduced:** `NativeTypeResolverCacheTest` compiles Java fixtures into a throwaway `URLClassLoader`, describes
  `List<Item>`, lifts and snapshots a record and a bean through a `DefaultDataAdapterRegistry`, drops the loader and
  waits for a `WeakReference` to it to clear. On the old code it never clears (30 s timeout), nor does it for an
  opaque value lifted against a contract naming its class, while the harness's control (a loader classes were only
  loaded from) is collected; kotlin-reflect itself does not pin the loader.
- **Fix** (`DefaultNativeTypeResolver`): an entry lives where it cannot outlive the loaders its key names. A key
  naming only classes of a *lasting* loader (the resolver's own loader, its parents, the bootstrap) stays in the
  resolver's own maps, which `close` clears. Any other key is *anchored* in a per-class `ClassValue` map: a
  description on the class its type names from the youngest other loader (the one whose parent chain holds every
  other loader the type names), a resolution on its owner class. Everything an entry holds was reached through the
  anchor's loader or that loader's parents, which the anchor keeps alive anyway, so the entry dies with the anchor's
  loader: no value reaches back to a key (the `WeakHashMap`-value trap), and anchoring on the youngest class rather
  than, say, `List` avoids the `ClassValue`-on-a-parent-class trap. A type over loaders on unrelated chains (neither
  keeps the other alive) or naming a type parameter is not cached, only computed. WR13's guarantees are unchanged: a
  miss computes outside any lock and stores with `putIfAbsent`, the first stored result wins. The hit path is a walk
  of the type's classifier and arguments (plain field reads) and one `ClassValue.get` or array index, with no lock;
  the copy-on-write `IdentityHashMap` of per-loader resolution maps and its lock are gone.
- **API change** (kzen-lib, not `kzen-auto-plugin`): `NativeTypeResolver.resolve(contract, owner)` takes the owner
  `Class<*>` instead of its `ClassLoader`, because a loader cannot anchor an entry (it has no `ClassValue`, and a
  weak loader-keyed map leaks through its values). Callers moved: `DefaultDataAdapterRegistry.lift`'s Opaque path,
  `resolveCustom`, and kzen-auto `FlowRun.validatePort` (the port object's class). A kzen-auto jar built against the
  old signature fails with `NoSuchMethodError` on the new kzen-lib, so the two publish together.
- **Audit, safe as-is:** `NativeClasses`, `BeanShape`, `NativePropertyPlans` (static `ClassValue`s whose values reach
  only the class and its member types, i.e. already anchored); the registry's `exactByClass` / fallbacks (immutable,
  from constructor arguments; `JobDataValues` passes none); `JobDataValues.flatHeaders` and
  `ColumnProjectionDescriptor.defaultCache` (keyed by header listings / contracts, which hold names, never a
  `Class`); `NativeIdentityRegistry.global` (weak references); `JobExpressionCompiler` (no cache of its own; its
  `describe(inferredType)` goes through the fixed resolver); `CachedKotlinCompiler` (closes the loader on eviction);
  `ScriptKotlinCompiler.classloaderClasspaths` (weak loader keys, `File` values);
  `RunOwnershipLedger.closeableByClass` (per run, class names); `ReadPreparation` (a thread-local tally). The path
  from an evicted expression to the registry holds nothing after the fix.
- **Tests:** `NativeTypeResolverCacheTest` (new, 6): the loader of a described and lifted record / bean is
  collectable; likewise of an opaque value lifted against its own native, and of a directly resolved owner; a type
  over sibling loaders (`Map<kept.Item, dropped.Item>`) describes as opaque and keeps neither alive; application,
  `List<String>` and live-loader types and resolutions return the same cached instance (application and `String`
  owners share one map); describe hits allocate nothing and a resolve hit allocates no more than a contract-keyed
  `ConcurrentHashMap.get` (minimum of three measured rounds, after warm-up). `NativeTypeResolverConcurrencyTest`'s
  gated loader now defines its own copy of the owner class (a resolution anchors on a class, not a loader);
  `DefaultNativeTypeResolverTest` and `RecursiveContractTest` moved to class owners. Old code: the
  described-and-lifted and opaque tests time out with the loader reachable; the other four need the new signature, so
  a mutation stands in (anchoring unrelated chains on their first class and keeping resolutions in a lasting map
  fails the opaque, resolved-owner and sibling tests). New code: all pass; WR13 / WR14 / WR15 tests green. No
  kzen-auto-level test: evicting a compiled expression needs the code cache's delete path or 10,000 entries, and what
  K2 infers for an expression-declared type is not stable ground; the kzen-lib tests cover the same registry path
  with an equivalent throwaway loader.
- **Epsilon slope** (as WR6, two passes, one JVM per point): S3 ≈ 5,904 / 5,817 B/row (WR15 ≈ 5,933 / 5,931); S4 ≈
  3,834 / 3,819 B/row (WR15 ≈ 3,961 / 3,782); Report ≈ 1,952 unchanged. No regression: both inside the noise band (≈
  ±100 B/row).
- **Findings, not fixed:** (1) `DataContract.hashCode` / `equals` allocate per call (through `constraintSets`), so
  every resolution hit allocates that much, before and after (the allocation test subtracts it). (2)
  `describe(Pair<A, B>)`, or of any class with a type-parameter member, throws "Native nullability at <root> (true)
  does not agree with structural nullability (false)": `unresolvedKType` makes the member non-null while
  `toMetadata()` writes `anyNullable`; met while writing the sibling-loader test, which uses `Map` instead. (3)
  Unbounded growth, not class retention: `JobDataValues.flatHeaders` per distinct header listing,
  `ColumnProjectionDescriptor.defaultCache` per distinct contract, and `NativeIdentityRegistry.global`'s emptied
  identity-hash buckets (never removed). (4) A dropped resolver's `ClassValue` entries on anchored classes outside
  its lasting loaders (plugin classes) linger until the JDK expunges them on a later `ClassValue` access to that
  class; `FlowRun` makes one resolver per run, so a plugin port class may carry a few dead entries between runs. (5)
  Five jvmTest suites each carry their own javac-to-a-temp-dir helper, now including `NativeTypeResolverCacheTest`'s.

### WR17 — one definition per class, whichever is described first (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 458, jsBrowserTest 389, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1262 tests, 0 failed, 1 skipped, and
`:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`).

- **Reproduced:** for `Outer(inner: Inner?)` / `Inner(outer: Outer?, self: Inner?)`, describe(Outer) defined
  `Inner` from the unrolling inside Outer (`outer` a reference to Outer) while describe(Inner) defined it from Inner
  itself (`outer` an inline Outer), and `withFields` of the two lifted values threw "Conflicting carried definition".
- **Fix, one file** (`DefaultNativeTypeResolver`): a definition is its class's own description — unrolled from that
  class alone, up to each class's first recurrence, exactly what describing the class as a root gives. An unrolling
  is recorded as the definition only when no class is open around it (the root, or a class reached through
  collections only); after the root walk, `defineReferenced` describes every still-undefined referenced class from
  itself in the same session, until the references of the new definitions are defined too. A definition depends
  only on the class's declared members (never on the type arguments it was reached with), so it is canonical per
  class and per resolver configuration, and any two contracts carrying it agree, structurally and in
  `definitionNatives`. Chosen over naming every class of a strongly connected component: that turns a recursive
  class's every non-root occurrence into a reference, which changes the shape of non-recursive roots holding one
  (`Holder(chain: Chain)`) and moves their constraints and paths behind a reference. The `withFields` equality test
  stays; no mutual-assignability fallback was needed.
- **Effect on existing contracts:** the structural tree, natives, constraints and tokens of every description are
  unchanged — only definitions of non-root classes change, and only where the old unrolling stopped at a class open
  around it (the `Outer` / `Inner` shape). Non-recursive types, self-recursion, and WR15's pairs (only the root
  recurs, so its one definition is the root) describe exactly as before. Nothing persists native-described
  contracts: `JobLaneDescriptor`'s digests are in memory, and the decoded contracts (reader configuration,
  `DataShape` over the wire) never come from the native describer. The work is on a description cache miss only,
  inside `ReadPreparation`, with no lock and no new cache: WR13's concurrency and WR16's anchoring are untouched,
  and the per-row lift path is not touched (no Epsilon run).
- **Tests:** `DefaultNativeTypeResolverTest.aRecursiveClassHasOneDefinitionWhicheverTypeIsDescribedFirst` — Outer
  and Inner described in either order (fresh resolvers) give equal contracts and the same `Inner` definition and
  natives, Outer's root unrolls as before, each definition equals its class's own description; `Ping` / `Pong`, each
  recurring in the other's own description, carry equal definition maps (exercises `defineReferenced`'s closure); a
  non-recursive `Holder(outer, inner)` carries the union of both. `RecursiveContractTest` — values lifted from
  either side compose into one record through `withFields`, `DataOverlay.contract` and `DataOverlay.record`, which
  validates and navigates two levels through each field. Old code: both fail (`Inner`'s definition differs; "Conflicting
  carried definition"). New code: pass; WR13–WR16 tests unchanged and green.
- **Findings, not fixed:** (1) `conformExpected`'s equality fast path still misses for a nested recursive value
  lifted against its enclosing contract's child: the root unrolling depends on where a class sits, and `child`
  keeps all the parent's definitions, so such a pair is equal only after assignability (correct, slower) — making it
  hit needs references at every non-root recursive occurrence plus definition pruning in `child`, a contract-shape
  change. (2) `DataSnapshot.capture` of a composed record (`DataOverlay.record`) whose fields are native-backed is
  rejected ("A composed record does not support native access"): `containerIdentity` asks the overlay root for its
  native because the contract has native metadata somewhere below, not at the root; not specific to recursion, met
  while writing the composition test. (3) The map describer describes a key and value before refusing a non-scalar
  key as opaque, so a recursive class met only in the discarded value still becomes a carried (unused) definition.

### WR18 — run-time tokens of generic collections (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 462, jsBrowserTest 389, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1266 tests (1262 + 4 new), 0 failed, 1 skipped,
and `:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`).

- **Who hit it:** of the callers of native-token acceptance, only kzen-auto `FlowRun.validatePort` met it. A Flow
  vertex input typed in notation with a collection (`meta: input: {is: RequiredInput, of: {is: List, of: String}}`,
  likewise `Set` / `Map`) rejected every native-backed message ("Flow input 'input' is incompatible: Native type
  java.util.Arrays.ArrayList<*> is not assignable to kotlin.collections.List<kotlin.String> at <root>"), and an
  empty collection or null member inside a typed message threw instead of answering. No in-tree notation (kzen-auto,
  kzen-project, kzen-sample) declares a typed port, so only third-party / user vertices were affected.
  `DefaultDataAdapterRegistry.lift`'s Opaque path compares the root token only and a collection never lifts as
  Opaque, so it is not affected (a generic opaque class is; finding 2). `selectVariant` / `validateVariant` have
  test callers only.
- **Fix, comparison-time** (`DefaultNativeTypeResolver`; `DataType.typeAt` in `DataContract.kt` made `internal`):
  - *Run-time values* (`isAssignable(expected, DataValue)` over `JvmNativeValueAccess`): the expected tokens are
    checked against the objects the value holds at the expected paths (`heldAcceptance`), whatever native metadata
    the value's own contract carries, so the outcome does not depend on how the value was lifted. Each collection is
    sampled at its first element or entry, as `describe(value)` already did; below a null, in an empty collection or
    in an inactive variant nothing is held, so nothing is checked; a null satisfies only a nullable token. An object
    that does not conform as its parent lifts it (a heap-polluted element, a null Java record component) answers
    `Rejected` with the lift's problem instead of throwing.
  - *Erased collections:* where a strict subtype check fails at a built-in collection (`List` / `Set` / `Map` /
    array classifier on a `Listing` / `Mapping` node of the expected contract), a held token that is star-projected
    (`ArrayList<*>`), or any held empty collection (`EmptyMap` is a `Map<Any?, Nothing>`), is compared by class
    only — its elements are checked at their own paths. Resolved actuals (`describe(value)` into `selectVariant` /
    `validateVariant` / `isAssignable`) get the same rule for star-projected tokens; ancestor coverage stays strict.
  - The class check compares boxed classes: a held `Integer` against a declared `Int` element token failed on the
    primitive `int` (reachable only once nested tokens are compared at all).
  - Chosen over giving the run-time node the expected argument when its contents conform: that resolves a `KType`
    on the lift (per row), states an argument the JVM object does not carry, and still fails for a value lifted
    without the expected contract (a Flow message is lifted against its source's own contract). The comparison-time
    rule touches only acceptance.
- **Erasure kept honest:** a `List<Any>` holding Strings is accepted at run time (the JVM cannot tell it from a
  `List<String>`; what it holds decides), while design-time `describe(List<Any>)` vs `List<String>` stays rejected;
  `MutableList<CharSequence>` vs `MutableList<String>` stays rejected (no star projection); a mismatched element
  (`List<Token>` holding `OtherToken`, a nested `Map<String, List<Token>>`, `Set<Token>`) is rejected by its own
  token, a mismatched scalar (`List<String>` of Ints, `Map<String, List<Int>>` of Strings) by the structural
  contract. `describe(value)` now reaches its nodes through the same walk and throws one "holds no native object"
  message where it threw three (code unchanged).
- **Cost:** one walk from the root per expected token, each step lifting the child as navigation always has —
  bounded by the token count, not the collection size; full-collection checking was not adopted (finding 1). The
  per-row Opaque lift shares only the strict check, unchanged on success. **Epsilon slope** (as WR6, two passes, one
  JVM per point): S3 ≈ 5,861 / 5,855 B/row (WR16 ≈ 5,904 / 5,817); S4 ≈ 3,873 / 3,873 B/row (WR16 ≈ 3,834 /
  3,819); Report ≈ 2,007 (unchanged code). No regression: both inside the noise band (≈ ±100 B/row).
- **Tests:** `DefaultNativeTypeResolverTest` (4 new): `Box(items: List<String>)`, `Grouped(List<List<String>>)`,
  `Indexed(Map<String, List<Int>>)`, `Maybe(List<String>?)`, `Tokens(Set<Token>)`, `List<String>`,
  `Map<String, List<Int>>`, `List<Token>` and a `MutableList<out Token>` holding a subclass accepted at run time;
  empty and nested-empty collections, a null member and a null nullable root accepted; mismatched elements, a
  heap-polluted `Box` and a null Java record component rejected; a union of `List<String>` / `List<Token>` selects
  and validates by its run-time contents. kzen-auto `FlowTypedPortTest` (new, 4) with `TypedPassVertex` and two
  fixtures: a `List<String>` port and a `Map<String, List<Int>>` port accept matching run arguments and fail the
  vertex for mismatched ones. Old code: `Box` rejected at `/field:items` (the run-time token message above); `Box`
  with an empty list threw "Empty listing has no runtime element token"; the polluted `Box` threw
  `DataAccessException` out of `isAssignable`; the union answered `NoMatch`; both accepting Flow tests failed the
  run with "Flow input 'input' is incompatible: Native type … is not assignable … at <root>"; the rejecting tests
  already passed (everything was rejected). New code: all pass.
- **Findings, not fixed:** (1) Sampling the first element leaves a gap: a structurally uniform collection whose
  later elements hold another class (`listOf(Token(), OtherToken())` lifted untyped, element contract `Opaque`) is
  checked natively at element 0 only. Checking every element is O(n) per listing and O(n²) per mapping through
  `ValueAccess` (`entry` / `keyAt` scan); on `FlowRun` that is per message, not per row. (2) A generic opaque class
  is still rejected by the Opaque lift (`Optional<String>` expected vs `Optional<*>` held): its argument has no path
  to check, so accepting it would be a decision, not a fix. (3) An empty collection lifted without an expected
  contract is `Listing(Dynamic?)` / `Mapping(Dynamic, Dynamic?)`, which no typed listing accepts structurally, so a
  typed Flow port still rejects an empty run argument ("Actual type Listing(element=Dynamic(nullable=true)) is not
  assignable to expected type Listing(element=Scalar(kind=Text))"); a different cause (the structural algebra has no
  bottom element type). (4) A run-time array lifts as `Listing(Dynamic?)` (`NativeClasses.starProjectedType` drops
  the reified component), so `Coded(codes: Array<String>)` fails as its field is lifted against `Listing(Text)`.
  (5) `resolve(contract, owner)` cannot load Kotlin-mapped names (`kotlin.CharSequence`), so a contract naming one
  fails to resolve. (6) WR16 finding 2 (`describe(Pair<A, B>)`) has a different root cause (`unresolvedKType`
  nullability vs `toMetadata()`'s `anyNullable`), not fixed. (7) A design-time star projection passes the erased
  rule too: `describe(MutableList<*>)` is accepted where `MutableList<Any?>` is expected (its element is `Dynamic`,
  so nothing narrower is ever accepted). (8) `describe(value)` is no longer used by `isAssignable`; it remains public
  API for resolved-contract callers.

### WR19 — recursive metadata in Formula compilation (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 463, jsBrowserTest 390, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1272 tests (1266 + 6 new), 0 failed, 1 skipped,
`FormulaStepTest` canary 10 / 10, and `:kzen-auto-js:compileKotlinJs` green; kzen-project compiles
(`kzen-project-common:compileKotlinJvm`, `kzen-project-jvm:compileKotlin`).

- **Reproduced** with metadata `origin: Node`, `Node(name: String, parent: Node?)`, a plain-data contract with one
  definition. Metadata can never hold a native (`MetadataContract` refuses native metadata), so a native recursive
  class reaches metadata only as such a contract. `JobExpressionCompiler.generate` overflowed in
  `metadataClasses$visit` (≈ 1,010 frames per trace, each `child` building a fresh `DataContract`), both at design
  time (`FormulaWorker.payloadFlow`) and at run time (`compileFormulas`). Every `JobExpressionCompiler` caller
  (Formula, Formula source, Filter, Run) shares the walk. The run-time path was blocked by a second gap at first:
  `LiteralDataValues.lift` dropped the expected contract's definitions, so a literal over a recursive contract failed
  at its first reference ("Type reference 'test.Node' has no definition in this contract"). No in-tree producer could
  build a recursive plain-data value.
- **Fix** (kzen-auto `JobExpressionCompiler.metadataClasses`): a field whose own type is a `Reference` maps its
  definition id to one generated class. The mapping is recorded before the class's fields are visited, so a later
  occurrence reuses the class: the definition's own recursive field, or another definition's field. The walk ends
  because every unbounded path through a contract crosses reference fields, and each id is visited once. A class
  depends only on its definition; a property's nullability comes from the field that references it. For `Node` the
  generated source is `class Meta0` (the root, `val origin: Meta1 get() = Meta1(…)`) and `class Meta1(private val
  node: DataValue?)`, whose `val parent: Meta1? get() = JobExpressionValues.metadataRecord(node, "parent", 0,
  true)?.let { Meta1(it) }` names its own class. Kotlin compiles a self-referential nested class as is. Mutual
  recursion gives one class per definition. An inline record still gets a class of its own, so non-recursive
  metadata generates byte-identical source; an inline unrolling of a definition, if a contract had one, would add
  one class.
- **Fix** (kzen-lib `LiteralDataValues.lift`): a literal lifted against an expected contract keeps that contract's
  definitions, as WR15 made `runtimeMappingContract` keep them. The branch that reuses `expected` (which Formula's
  calculated scalars take per row) is untouched.
- **Compile cache key:** `KotlinCode.signature()` digests the source. Generation is deterministic: a wire-decoded
  copy of the recursive contract generates the same signature (test), and a non-recursive `parent.parent.name`
  contract's signature is the same before and after (`JobExpression_names_y43jns3jvou7o25e5wvpzjehoi`).
- **Audit, safe as-is:** `JobExpressionValues` (`metadataField` / `metadataKeyed` / `metadataRecord`, `keyed`,
  `projected`: one step per call); `JobDataValues.boundaryNode`, which `meta["x"]` returns for a record (follows the
  value, and literal values are acyclic); `accessors` and `ColumnProjectionDescriptor.create` / `select` (one level,
  or path-driven); `metadataNames` / `shadowWarnings` (root only); `unsupportedBoundary` (references are leaves);
  editor side: `ContractPathTree` and `PathBinding.resolve` (expanded one level per request, or path-driven),
  `ContractTreeNode` (expands on click), `DataContractPresentation` (no recursion), `FileNameTemplateEditor.scalarPaths`
  (bounded by `maximumDepth = 3`); server `FileNameTemplate` (path-driven), `PreviewCapture` (value-driven, with
  depth). No other gap found.
- **Tests:** `JobExpressionCompilerTest` (4 new): recursive metadata generates two classes, `Meta1` referring to
  itself, with a stable signature across a wire round trip; a Formula over it compiles and evaluates typed and keyed
  reads through two levels and past the end (`origin.name`, `origin.parent?.name`, `meta.origin.parent?.parent?.name`,
  `origin.parent?.parent?.get("name")` → `"c/b/a/a/-"`); mutually recursive `File` / `Folder` gives one class per
  definition and compiles; nested non-recursive records keep a class each. `FormulaWorkerContractTest` (2 new):
  design-time `payloadFlow` keeps the `origin` reference and its definition and types the calculated field as
  `Text`; at run time a Formula reads a grandparent through recursive metadata (`"a"`, and `"none"` one level short).
  kzen-lib `DataValueTest` (1 new): a literal lifted against a recursive contract keeps its definitions, validates,
  navigates three levels, and rejects a mismatched nested value. Old code: all five recursive kzen-auto tests overflow
  (`StackOverflowError`, run against the fixed kzen-lib so the run-time literal can be built; against the old one the
  run-time test fails earlier, at the literal); the non-recursive test passes on both. The kzen-lib test fails on the
  old lift ("no definition"). New code: all pass.
- **Allocation:** the per-row path is unchanged (both fixes run at compile or contract-building time, and Formula's
  per-row literal lift takes the untouched reuse branch), so no Epsilon run.
- **Findings, not fixed:** (1) A metadata field named `node` fails to compile ("Overload resolution ambiguity
  between candidates: val node: DataValue? / val node: …Meta1"). The cause is the generated metadata class's
  constructor property `node`, not recursion; met while writing the tests, which use `origin`. Renaming the property
  changes every metadata-bearing expression's source, so each recompiles once. (2) `FileNameTemplateEditor`'s
  `maximumDepth` comment says a metadata record is "never cyclic"; a recursive definition makes it so, but the bound
  still holds. (3) Before the `lift` fix, a recursive plain-data value could only come from a custom `ValueAccess`;
  `DataSnapshot` / `MetadataSnapshot` carry a bare `DataType` without definitions, not examined further.

### WR20 — definition natives through runtime contracts (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 465, jsBrowserTest 390, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1272 tests, 0 failed, 1 skipped, and
`:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`).

- **Reproduced, through contract walks rather than navigation:** `Held(name, handle: AtomicInteger?, children:
  List<Held>)` and a map-valued `MappedHeld`. Reading the value never failed: `NativeObjectValueAccess` lifts every
  present record from its own class, whose description carries the definition natives, so the handle (its object
  and native token) is read at any depth on the old code too, and snapshots behave (refused only for the opaque
  handle; a handle-free copy completes). What failed was any walk over a *collection's* runtime contract past one
  expansion: the listing (List / Set) and non-empty mapping contracts were built without `definitionNatives`, so
  expanding the element's `Held` reference built a child contract whose opaque `handle` had no native metadata
  ("Opaque path /field:handle#0 requires native metadata"). `DataValueAlgebra.validate` walks the value's root
  contract beside the value, so a list, set or map of `Held` — untyped or lifted against its description — failed
  validation at `[0]/children`, already at depth 1 and even when that inner collection was empty. A record lifted
  directly validated (its root contract is its own description), but the contract of its `children` node did not
  reach past one more expansion; for `MappedHeld` the empty-mapping path, which WR15 made keep definitions, still
  dropped the definition natives, so `child(MappingValue)` of an empty `children` threw. Same path, not recursive: an
  empty `Map<String, AtomicInteger>` lifted against its own description threw at the lift ("Opaque path
  /mapping-value requires native metadata"), because the empty-mapping path dropped the expected native metadata
  that an empty listing keeps.
- **Fix, one file** (`DefaultDataAdapterRegistry`): the listing and non-empty mapping contracts carry the joined
  element / value contract's `definitionNatives` plus the expected contract's, as they already did definitions; the
  empty-mapping path keeps the expected contract's native metadata, definitions and definition natives (what the
  non-empty path's guided natives give). A collection lifted against its description now equals it (`List<Held>`,
  `Set<Held>`, `Map<String, MappedHeld>`, and the empty opaque list and map), so `conformExpected`'s equality fast
  path hits where it missed before.
- **Audit, safe as-is:** `joinedRuntimeContract` (carried both already); the record, data class, bean, enum and
  scalar paths (the resolver's whole description); the null and Opaque paths (the expected contract itself); arrays
  (described by type, WR22); `conformExpected` (returns the actual, or a `TaggedUnionValueAccess` whose selected
  contract is the expected union's `child`); `validateAdapterResult` (the adapter's own contract, then
  `conformExpected`); `childValue` / `actualChildContract` (the lift's contract, or the expected child for an
  opaque); `DataContract.child` / `expanded` / `withMetadata` (pass both maps), `withFields` (merges them,
  conflict-checked); `DataOverlay.contract` (the base's, then `withFields`); `MetadataContract` (refuses
  definition natives).
- **Tests:** `RecursiveContractTest` (2 new): `Held` lifted directly, as a list and as a set element (untyped and
  against `List<Held>` / `Set<Held>`), and `MappedHeld` directly and as a map value (untyped and against
  `Map<String, MappedHeld>`): three levels down, the handle reads as its object with an `AtomicInteger` native token;
  the value's contract and each `children` node's contract reach the handle's native metadata past one more
  expansion; a typed lift equals its expected contract; the value validates against its own and the expected
  contract; the snapshot is refused only as `snapshotOpaque`, a handle-free copy completes.
  `DefaultDataAdapterRegistryTest.expectedNativeCollectionMetadataSurvivesRuntimeShapeInference` (extended): an
  empty list and an empty map of an opaque class lifted against their descriptions equal them. Old code: both
  recursive tests fail ("Opaque path /field:handle#0 requires native metadata", in every variant, the directly lifted
  record included through its `children` node's contract), and the registry test fails at the empty map's lift. New
  code: all pass; WR15 / WR17 recursion and the non-recursive tests unchanged and green.
- **Epsilon slope** (as WR6, two passes, one JVM per point): S3 ≈ 5,907 / 5,884 B/row (WR18 ≈ 5,861 / 5,855); S4 ≈
  3,728 / 3,820 B/row (WR18 ≈ 3,873 / 3,873); Report ≈ 1,954 (unchanged code). No regression: both inside the noise
  band (≈ ±100 B/row); a collection lift gains one map merge.
- **Findings, not fixed:** (1) `ResolvedDataContract.child` rebases only the parent's tokens while
  `DataContract.child` adds an expanded reference's definition natives, so a resolved union whose variant is a
  reference to a definition with native members would fail "Native token paths must exactly match metadata paths";
  found by reading — the native describer emits no unions (a sealed class describes as Opaque), so only a custom
  adapter's contract could reach it. (2) `LiteralDataValues.lift` refuses an expected contract with root native
  metadata but silently drops its `definitionNatives`, so a literal against a contract whose definitions hold opaque
  members would fail at expansion instead of being refused up front; no producer known. (3) An empty mapping lifted
  against an expected one still keeps none of its constraints, where an empty listing keeps its element's; only
  contract equality differs.

### WR21 — empty collections into typed inputs (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 475, jsBrowserTest 398, `kzen-lib-jvm` 204, `kzen-lib-js` 1; 0
failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1276 tests (1272 + 4 new), 0 failed, 1 skipped,
and `:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`).

- **Reproduced** through `FlowRun.validatePort` (kzen-auto `FlowTypedPortTest`). Each of these failed the run:
  - an empty `ArrayList<String>` / `emptyList()` into a `List<String>` port ("Flow input 'input' is incompatible:
    Actual type Listing(element=Dynamic(nullable=true)) is not assignable to expected type
    Listing(element=Scalar(kind=Text))");
  - an empty `LinkedHashMap` / `emptyMap()` into a `Map<String, List<Int>>` port (`Mapping(Dynamic, Dynamic?)`);
  - beyond the root, `mapOf("a" to emptyList<Int>(), "b" to listOf(1))`, whose values join to `Listing(Dynamic?)`.
    So a nested empty collection failed the value holding it.
- **Where else an empty collection meets an expected contract.** These rejected the same way and are fixed by the
  same rule:
  - `DefaultDataAdapterRegistry.conformExpected`, which re-lifts an already-lifted `DataValue` against an expected
    contract (`JobDataValues.lift` of a value, an adapter's result);
  - `validateBindingValue`, behind `DataBindings.bind` and `ProducedBindingsBuilder` (Job, Script and Flow child
    inputs and outputs, and a Worker's `yieldResult` binding a value lifted untyped);
  - `DataValueAlgebra.validate`, which starts with the same check.

  These are safe as-is:
  - A raw native lifted against the expected contract. `runtimeContract` takes an empty list's or set's element from
    the expected contract, and WR15 / WR20's empty-mapping path returns the expected contract. That covers Script step
    results, Script and Flow child inputs, outputs and results (`boundary(...)` re-lifts against the definition
    contract), `JobDataValues.lift` of a native, and `ResultSinkWorker`.
  - The Opaque lift: WR18's erased rule already accepts any held empty collection.
  - Flow signatures, which are `Dynamic`.
- **Fix: run-time acceptance** (kzen-lib `DataValueAlgebra.isAssignable(expected, value)`, new, commonMain).
  - The contract comparison runs first. Where it rejects, what the value holds decides:
    - a listing, through each element it holds (none when it is empty);
    - a mapping, through each entry where the keys agree (any key when it is empty);
    - a record, field by field, in order and with DataTypeAlgebra's optional rules;
    - an expected union, by any of its variants;
    - a null, by the expected nullability.
  - Every other node keeps its contract's verdict (scalar, opaque, `Dynamic`), and so does each node's own
    nullability. Metadata is checked the same way.
  - A rejection is still the contract comparison's, so the messages are unchanged.
  - **Callers:**
    - `validate`;
    - `DefaultNativeTypeResolver.isAssignable(ResolvedDataContract, DataValue)`, in its structural part and in
      `heldAcceptance`'s union branch;
    - `conformExpected`;
    - `validateBindingValue`, through an internal `holdsStructurally`. It compares types only, as that check always
      did, so an opaque type never accepts another.
  - **`validate`'s constraint walk** follows the value's own contract, which is `Dynamic` where the held elements
    disagree. A test caught the gap. At a `Dynamic` node the walk now continues through the node's own contract when
    the expectation declares constraints below it, so a constraint on a held element is still enforced.
- **Chosen over a bottom element type** (`Listing(Nothing)` for a collection lifted empty):
  - A new `DataType` variant reaches the wire codec, JS, the UI's contract presentation and every exhaustive `when`.
  - Element joins would have to treat it as an identity to cover the nested case.
  - At design time it would be a type no signature can state.

  The run-time rule touches only acceptance; `DataType` and `DataTypeAlgebra` are untouched.
- **Design-time unchanged.** These are still rejected, at contract level and type level (tests):
  - `Listing(Dynamic?)` vs `Listing(Text)`;
  - `Mapping(Dynamic, Dynamic?)` vs a typed mapping;
  - `describe(List<Any?>)` vs `List<String>`.
- **Beyond strict emptiness,** consistent with WR18's "what it holds decides":
  - A non-empty collection whose declared element is wider than what it holds (a heterogeneous join widened to
    `Dynamic`) is accepted by its elements' own contracts.
  - A null held where the expectation allows null is accepted.
  - A mismatched element is still rejected, with or without empty siblings.
- **Cost:**
  - The walk runs only where the contract comparison rejects, i.e. where the old code threw.
  - An accepted value takes the same comparison and returns, so the per-row path is unchanged on success
    (`conformExpected` gains one call frame). No Epsilon run.
  - The walk is O(n) per listing and O(n²) per mapping through `keyAt` / `entry`, as `validate` already is.
- **Tests (new code: all pass):**
  - **kzen-lib `DataValueAlgebraTest`** (new, 7):
    - an empty list and map are accepted by typed collections of their kind; the other kind and a scalar are
      rejected;
    - design-time rejections are unchanged;
    - a nested empty collection beside conforming siblings is accepted in a list, a map and a record field;
    - these are rejected with the contract comparison's message: mismatched elements beside empty ones, a null
      element, a wrong key kind, a missing record field;
    - a null nullable listing is accepted;
    - `validate` accepts an empty list and enforces a nested `SymbolSet` on held elements;
    - metadata holding an empty list is accepted.
  - **`DataBindingsTest`** (1 new): an empty list binds to `Listing(Text)` through `bind` and
    `ProducedBindingsBuilder`; `listOf(1)` still fails `incompatibleType`.
  - **`DefaultNativeTypeResolverTest`** (1 new):
    - Accepted, lifted untyped:
      - `List<String>` and `List<String>?` ← `emptyList()` / `ArrayList()`;
      - `Set<Token>` ← `emptySet()` / `HashSet()`;
      - `Map<String, List<Int>>` ← `emptyMap()` / `LinkedHashMap()` / `mapOf("a" to emptyList(), "b" to listOf(1))`;
      - `List<List<String>>` ← `listOf(emptyList(), listOf("a"))`.
    - Rejected: the other kind, and mismatched siblings of an empty collection.
    - Design-time rejections are unchanged.
  - **`DefaultDataAdapterRegistryTest`** (1 new): a lifted empty list conforms to `Listing(Text)` as is; `listOf(1)`
    and an empty map are refused.
  - **kzen-auto `FlowTypedPortTest`** (4 new): an empty list, an empty map, and empty lists beside int lists are
    accepted; string lists beside an empty one are rejected.
- **Old code:**
  - kzen-auto, against the published WR20 kzen-lib: the three accepting tests failed with the messages above. A
    fourth test, for a `Set<String>` port, also failed and was dropped (finding 1). The rejecting tests passed.
  - kzen-lib, with the two new functions neutered to the old contract comparison: 8 of the 10 new tests fail
    (`DataValueAlgebraTest` 5, plus the `DataBindingsTest`, `DefaultNativeTypeResolverTest` and
    `DefaultDataAdapterRegistryTest` tests). The design-time and still-rejected tests pass.
- **Findings, not fixed:**
  1. **A `Set`-typed Flow port rejects every set, empty or not.**
     - Cause: `TypeMetadata.toDataContract` maps only `List` / `Array` / `MutableList` and `Map` / `MutableMap` to
       collections, so `Set` / `MutableSet` become `Opaque` (old run: "…not assignable to expected type
       Opaque(nullable=false)").
     - By reading, a Script or binding typed `Set<…>` likewise fails its Opaque lift.
     - Adding `Set` to that collection branch would change the design-time contract and UI of every `Set`-typed
       signature, so it needs a decision.
     - The resolver path (`describe(Set<…>)`) already treats a set as a listing and is covered.
  2. **An expected union is still selected by type.** `conformExpected`'s union branch and
     `LiteralDataValues.buildInferredUnion` use `selectVariant`, so an untyped empty collection into a union contract
     still answers `NoMatch`.
  3. **`validateBindingValue`'s native-presence check is unchanged.** An untyped empty list bound where the definition
     requires element natives (`List<SomeOpaqueClass>`) still fails with "requires native metadata at
     [ListingElement]".
  4. **`BindingDefinition`'s default-snapshot check stays type-level**, because a snapshot carries a bare `DataType`.
  5. **`FlowRun.edgeValue` checks a vertex's `DataValue` output type-level** (`DataTypeAlgebra.isAssignable` on
     `structural`). Only a third-party vertex that emits an untyped empty `DataValue` into a typed output could hit
     this.
  6. **A cyclic native object under a rejecting contract** could make the walk recurse, as `validate` can.

### WR22 — run-time arrays keep their element type (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 481 (475 + 6 new), jsBrowserTest 398, `kzen-lib-jvm` 204,
`kzen-lib-js` 1; 0 failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1276 tests, 0 failed, 1 skipped,
and `:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`). No kzen-auto change.

- **Reproduced in kzen-lib; WR21 masks part of it.** Lifting `Coded(codes: Array<String>)` and reading its codes
  succeed, and so does the snapshot; the resolver's run-time `isAssignable` accepts the value (WR18 / WR21's held
  walk). What fails is the array node's contract: `runtimeContract` described an array by its class's star
  projection (`Array<*>`), so it lifted as `Listing(Dynamic?)` (root metadata `kotlin.Array<kotlin.Any?>`), where the
  described field is `Listing(Text)`. As a result:
  - `DataValueAlgebra.validate` rejects `Coded` against its description, and even against its own contract
    ("Node type Listing(element=Dynamic(nullable=true)) is not assignable to Listing(element=Scalar(Text))" at
    `/field:codes`), because `validateNode`'s per-node check is contract-level (finding 4). The same for a recursive
    class's array of children and a Java record's `String[]` / `JavaReading[]` components;
  - an untyped array lifts as `Listing(Dynamic?)`, unequal to `describe(Array<String>)`;
  - a typed array lift misses `conformExpected`'s equality fast path and takes WR21's O(n) walk;
  - an expected union with a typed listing variant answers NoMatch ("No variant in Union(…) accepts actual").

  No kzen-auto production caller of `validate` was found, so no kzen-auto-level failure was reproduced.
- **Fix** (kzen-lib `NativeClasses.heldType`, used by `runtimeContract`'s described branch in place of the star
  projection): an object array's type is its component class reified, as the describer reads a declared `Array<T>`:
  - `String[]` → `Array<String>` → `Listing(Text)`; `String[][]` → `Array<Array<String>>`;
  - `Tree[]` → `Array<Tree>`, with WR17 / WR20's definitions and definition natives;
  - `int[][]` → `Array<IntArray>` → `Listing(Listing(Int32))`.

  Other classes keep the star projection; primitive arrays keep the describer's rules (`IntArray` a listing of
  scalars, `ByteArray` Binary, `CharArray` Opaque). The Opaque, adapter and mapping paths are unchanged.
  - **Element nullability from what is held.** The JVM lets any element be null, so each nesting level is nullable
    where an array of that level holds a null (`arrayOf("a", null)` is `Array<String?>`, `arrayOf(arrayOf("a"), null)`
    is `Array<Array<String>?>`), as a collection's elements are typed by what it holds. A null held against a
    non-null `Array<String>` is rejected (`incompatibleType`), consistent with WR18's Java-record rule.
  - **Element-type honesty kept:** the component class decides, not the content, so `arrayOf<Any>("a")` stays
    `Listing(Dynamic)` and is still rejected by `Array<String>` (WR18's erased-token rule: `Object[]` is no
    `String[]`).
  - **Tokens stay star-projected** (`Array<*>`): arrays are invariant in Kotlin, so an exact `Array<String?>` token
    would reject a declared `Array<String>`; WR18's class comparison already decides.
  - **WR16 anchoring:** `heldType` builds the type from the value's own `Class` objects, and the per-class facts
    (the two flat-array types, with non-null and with nullable elements) live in the `ClassValue`, so an expression
    loader's component class is cached on that loader's class and stays releasable (`NativeTypeResolverCacheTest`
    now describes and lifts a record holding `Item[]` and `Item[][]` from a collectable loader).
- **Tests (new code: all pass):**
  - **`DefaultDataAdapterRegistryTest`** (5 new):
    - `Coded` with codes and empty: the field's contract equals the described child, the codes read, it validates
      against its description and its own contract, the snapshot completes; the Java record `JavaCoded(String[],
      JavaReading[])` (new fixture) likewise; untyped, typed and empty `Array<String>` lifts equal
      `describe(Array<String>)`; an expected union selects its `Listing(Text)` variant;
    - nested arrays and held nulls, level by level (`Grid(Array<Array<String>>)`, `Sparse(Array<String?>)`, an array
      holding an empty array, nulls at each level), and a null into `Array<String>` rejected;
    - a recursive `Tree(name, children: Array<Tree>)` three levels deep, directly and as `Array<Tree>`: contracts equal
      their descriptions; it validates, snapshots and navigates;
    - `Array<Any>` holding Strings stays `Listing(Dynamic)`, `Array<CharSequence>` lifts as its own description, and
      `arrayOf<Any>("a", 1)` is rejected by `Array<String>`;
    - primitive arrays keep their scalar / Binary / Opaque rules, `Array<IntArray>` included.
  - **`DefaultNativeTypeResolverTest`** (1 new): run-time `isAssignable` accepts `Coded`, `Array<String?>` holding a
    null, nested arrays and a `SubToken[]` as `Array<Token>`; it rejects `Object[]` holding Strings, a null into
    `Array<String>`, `String[]` into `Array<Int>`, and an unrelated element class.
  - **`NativeTypeResolverCacheTest`** (extended): the collectable-loader fixture gains `release.Coded(Item[] items,
    Item[][] grid)`.
- **Old code** (the one `runtimeContract` line reverted): all 5 new registry tests fail (contract equality or
  `validate`; the union assertion, probed separately, with NoMatch). The resolver and cache tests pass, as WR18 /
  WR21 already accepted arrays by what they hold.
- **Epsilon slope** (as WR6, two passes, one JVM per point): S3 ≈ 5,936 / 5,692 B/row; S4 ≈ 3,941 / 3,952 (two more
  passes: 3,960 / 3,971); Report ≈ 2,010 / 1,958. S4 sits ≈ 170 above WR20's ≈ 3,770, so a baseline was taken with
  only the WR22 line reverted and republished: S4 ≈ 3,924 / 3,943. WR22 adds nothing measurable (a non-array allocates
  nothing new: one cached-facts read and a class check); the S4 shift predates it (finding 6).
- **Findings, not fixed:**
  1. `describe(value: DataValue)` throws "Value holds no native object at /listing-element" for an empty array, as
     it already did for an empty list lifted against a typed contract; no downstream caller.
  2. An `Array<Pair<…>>` now throws at lift ("Native nullability at <root> (true) does not agree…", WR16 finding 2),
     as a `List<Pair<…>>` already did; before, it threw only when an element was navigated.
  3. An array whose component is abstract or an interface without a description (`Array<Number>`) now lifts as
     `Listing(Opaque)`, its design-time description, where it lifted as `Listing(Dynamic?)` with scalar-readable
     elements. Consistent with the describer, but a behaviour change for any caller reading such elements as
     scalars; needs a decision if one exists.
  4. `DataValueAlgebra.validateNode`'s nested per-node check is contract-level, not WR21's run-time rule; arrays no
     longer reach it, but other `Dynamic`-joined nodes can.
  5. A nested object array's held type is built per lift (`createType` per level; only flat arrays are cached per
     class), and every array lift scans its elements for nulls (O(n), as the list join already is).
  6. S4's Epsilon slope rose from ≈ 3,770 (WR20) to ≈ 3,930 before WR22, most likely in WR21, which shipped without
     a measurement; not bisected.

### S4 allocation bisect (2026-10-08)

*Question:* WR22's finding 6 — S4's Epsilon slope read ≈ 3,941–3,971 B/row after WR22 (≈ 3,924 / 3,943 with WR22's
line reverted) against ≈ 3,770 after WR20 (3,728 / 3,820). Real, and if so which phase?

- **Method.** A/B of the two committed states, each in its own scratch worktree under `$TEMP`: *old* = kzen-lib
  `8807fac` + kzen-auto `725b75d1` (after WR13, before WR14–WR22), *new* = kzen-lib `1836acf` + kzen-auto `8ae589b5`
  (HEAD). Each state's kzen-lib was published to Maven Local, its kzen-auto `:kzen-auto-jvm:testClasses` compiled
  against it, and the two kzen-lib jars on the test runtime classpath copied aside, so both states then ran straight
  from `java` with no republishing between points: the `benchJob -PbenchEpsilon` JVM (`-XX:+UseEpsilonGC -Xmx16g`,
  JDK 25.0.4.1), `-DbenchScenarios=S4`, `-DbenchRows=25000` / `100000`, default 1 warm-up + 3 runs. The benchmark
  (identical in both states) got one scratch line printing every run's heap delta, not only the median's. Six
  passes, one JVM per point, old and new interleaved and their order alternated per pass; slope = (total at 100k −
  total at 25k) / 75k, from the mean of each JVM's 3 runs (the as-builts' reading, the run of median wall time, in
  brackets).

  | Pass | Old (B/row) | New (B/row) |
  |---|---:|---:|
  | 1 | 3,829 [3,884] | 4,025 [4,017] |
  | 2 | 3,998 [4,004] | 3,734 [3,721] |
  | 3 | 3,901 [3,860] | 3,914 [3,908] |
  | 4 | 3,901 [3,868] | 3,902 [3,959] |
  | 5 | 3,834 [3,822] | 3,795 [3,678] |
  | 6 | 3,955 [3,926] | 3,951 [3,880] |
  | Mean (sd) | **3,903 (66)** [3,894 (64)] | **3,887 (106)** [3,861 (134)] |

  Totals per run, all 18 per state: at 100k old 502.5 MB (sd 6.6, 491.7–517.9), new 502.0 MB (sd 7.7, 488.9–512.9);
  at 25k old 209.8 MB (sd 4.0), new 210.5 MB (sd 3.5).
- **Verdict: no regression.** New − old = −16 B/row (−33 by median run), standard error ≈ 50; a real +170 would sit
  ≈ 3.5 σ away. The WR13 state itself measures ≈ 3,900, so WR20's 3,728 / 3,820 were low draws and WR22's
  3,941–3,971 ordinary ones; every S4 pass recorded from WR11 to WR22 (3,728–4,070) lies inside one distribution
  of ≈ 3,900 ± 130. WR21 needs no fix; finding 6 of WR22 is closed.
- **JFR cross-check** (one JVM per state at 100k, `jdk.ObjectAllocationSample#throttle=3000/s`, ≈ 6,700 samples on
  the engine threads each): the engine threads (the per-row path) differ by +69 of ≈ 5.9 KB per row, inside the
  sampling noise (unchanged code such as `FlatFileRecord.<init>`'s `long[]` reads 81 vs 143 B/row between the two
  JVMs). No per-row allocation site appears or disappears in WR14–WR22's code. The one site present only in the new
  JVM (`PersistentMap.entries` iterator → `Maps.immutableEntry`) is graph definition at each run's setup
  (`AttributeObjectDefiner.define`, `ObjectLocationMap.filterDocumentNestings`), code WR14–WR22 did not touch: a
  fixed cost per run that cancels in the slope, scalar-replaced in one JVM and not in the other.
- **The noise, for future thresholds.** It is per JVM, not per run: one JVM's three runs agree to a few MB, while two
  JVMs of identical code differ by up to ≈ 20 MB at 100k. The JFR samples point at JIT outcomes (escape analysis of
  per-row temporaries, e.g. `DataContract.equals`'s `constraintSets` maps read 65 vs 123 B/row) and at continuation
  allocations that depend on thread interleaving (`Emitter.send`, `TransformWorker.drive`), plus Epsilon's TLAB tails
  in the heap-used reading. One pass's slope has sd ≈ 65–135 B/row (range ≈ 350); a two-pass mean ≈ ± 70, so two
  two-pass means differ by ≈ 100 B/row (1 σ) by chance, and a 170 B/row gap between phases is < 2 σ. Rules:
  - Do not compare against a past phase's recorded number. Measure A/B in one session against a worktree of the
    previous state (both published to Maven Local in turn, classpaths frozen as above), interleaved.
  - A shift of ≈ 100 B/row needs ≈ 6–8 passes per side to clear 2 σ; with 2 passes per side, treat anything under
    ≈ 250 B/row as noise. Read the mean of each JVM's runs, not the median-wall run.
  - A longer span shrinks the per-row noise (25k → 250k, the `-PbenchEpsilon` default, divides it over 225k rows
    instead of 75k; ≈ 5 GB per JVM at 250k, inside the 16 GB heap) — expected to roughly halve it, not measured.
  - For attribution, JFR at this sampling rate resolves ≈ ± 50 B/row per site at best; a suspected site needs a
    focused allocation test (as WR6), not a slope.
- **Finding, not fixed (pre-existing, both states):** `JobDataValues.projection` → `ColumnProjectionDescriptor.from`'s
  `ConcurrentHashMap.computeIfAbsent` compares each row's contract by `DataContract.equals`, which builds two
  `constraintSets` maps (`mapValues` allocates even when empty) per comparison; `ValueSetFilterWorker` and
  `FormulaWorker` each pay it per row (≈ 100–170 B/row sampled, S3 and S4 alike). Comparing `constraintsByPath`
  directly when both are empty (or sizes differ) before building sets, or keying the cache by identity first, would
  remove it.
- **Restored:** HEAD republished from the user's trees (kzen-lib `publishToMavenLocal`, kzen-auto `publishToMavenLocal
  -x test`; every jar re-stamped, the kzen-lib JVM jars byte-equal to the tree's builds); scratch worktrees removed
  and pruned; kzen-lib and kzen-auto trees clean.

### WR23 — contract equality without allocation (2026-10-08)

kzen-lib `./gradlew build` green (common jvmTest 488 (481 + 7 new), jsBrowserTest 402 (398 + 4 new), `kzen-lib-jvm`
204, `kzen-lib-js` 1; 0 failed) and republished (no bump); kzen-auto `:kzen-auto-jvm:test` 1276 tests, 0 failed,
1 skipped, and `:kzen-auto-js:compileKotlinJs` green; kzen-project compiles (`kzen-project-common:compileKotlinJvm`,
`kzen-project-jvm:compileKotlin`). No kzen-auto change.

- **Fix** (kzen-lib `DataContract`; the `constraintSets` getter is gone):
  - `equals` stays identity first, then compares part by part; an empty map is compared by `isEmpty` alone (a JVM
    map's `equals` / `hashCode` iterate `entrySet()`, which allocates even when empty), a non-empty one as a map;
  - constraints compare per path without building sets: equal map sizes, then for each path the other side's list of
    the same size containing all of them;
  - `hashCode` is computed once and cached with `String.hashCode`'s racy single-check idiom (`cachedHash` plus a
    `hashIsZero` flag, each written alone, no synchronization); an empty part hashes 0 without iterating, and the
    constraints hash as the map of sets they were (per path, path hash xor the sum of its constraints' hashes).
- **Semantics unchanged.** Every map is still compared as a map (an empty one equals only an empty one). Constraints
  remain a map of sets: validation admits at most one constraint per kind per path and equal constraints share a
  kind, so a list never repeats and equal size plus `containsAll` is set equality; equal map sizes plus each path
  present is equal key sets. The hash value is bit-identical to the old one (an empty map hashes 0, a set the sum of
  its elements). Caching is sound because a contract is immutable: its maps are defensive copies, `DataType`,
  `TypeMetadata` (copies its generics), `ClassName`, `ScalarKind`, `SymbolSet` and `MetadataContract` are immutable,
  and `DataContract` is final.
- **Per-row lookups: no caller change needed.** Kotlin's `==` / `!=` go through `equals`, which already starts with
  `this === other`, so `FormulaWorker` / `FilterWorker` / `RunWorker.compiledForContract`, `MetadataShape.fits`
  (explicitly `!==` first) and `conformExpected`'s fast path already check identity first. The contract-keyed
  `ConcurrentHashMap`s (`ColumnProjectionDescriptor.from`'s `computeIfAbsent`, reached from `ValueSetFilterWorker`,
  `FormulaWorker` and `PivotWorker` through `JobDataValues.projection`; `WriterColumns` / `PathProjectionWorker`
  `boundFor`; the resolver's `lastingResolutions` / `anchoredResolutions`) check identity only after `hashCode`,
  which was the allocating part and is now cached. `JobDataValues.flatHeaders` is keyed by `HeaderListing` (cached
  digest), not a contract. `DataType.Record` / `SingletonList` equality measured 0 B under C2, so `DataType` is
  unchanged.
- **Tests:**
  - **`DataContractEqualityTest`** (commonTest, 4 new, JVM and JS): equal parts in any insertion order (and an
    `ofExecutionValue` round trip) are equal with equal hashes; each of 11 single-part variants (structure, a native,
    a missing native, a definition, a definition native, a missing definition native, symbol order, a missing
    constraint, no constraints, no metadata, metadata constraints) is unequal; a 15-contract matrix agrees pairwise
    with a reference built on `mapValues { it.value.toSet() }`, hashes included (a child equals the same contract
    built directly; an empty constraint list is no constraint); metadata contracts compare by their contract.
  - **`DataContractAllocationTest`** (jvmTest, 3 new), over a parsed row (8 Text fields, metadata `parent{name,
    path}`) and a native record (natives at the root and each field): comparing two equal, distinct contracts; the
    first hash of freshly built contracts; a contract-keyed `ConcurrentHashMap` `get` and `computeIfAbsent` on an
    equal, distinct contract. Each under 1 B per operation (min of 3 rounds of 50,000 after warm-up).
  - **`NativeTypeResolverCacheTest.cacheHitsAllocateNothing`** now asserts a resolve hit directly, no longer
    subtracting a contract-keyed map lookup's cost.
- **Old code** (kzen-lib `1836acf` in a scratch worktree, the new tests copied in): the equality tests pass; all 3
  allocation tests fail: per comparison 240 B (parsed row) / 152 B (native record), per first hash 224 / 112, per
  map `get` 416 / 240; the tightened resolve hit fails at 168 B per hit. **New code:** 0 B in all of them.
- **Epsilon slope A/B** (per the bisect's rules, one session): *old* = kzen-lib `1836acf`, *new* = the working tree;
  both against one kzen-auto `8ae589b5` worktree's `:kzen-auto-jvm:testClasses` classpath, frozen per state (the two
  kzen-lib jars swapped), run straight from `java` (`-XX:+UseEpsilonGC -Xmx16g`, JDK 25.0.4.1), `-DbenchRows=25000`
  / `100000`, 1 warm-up + 3 runs; six passes, order alternated per pass, 48 JVMs; slope from each JVM's mean (median
  wall-time run in brackets).

  | Pass | S3 old | S3 new | S4 old | S4 new |
  |---|---:|---:|---:|---:|
  | 1 | 5,650 [5,630] | 5,360 [5,375] | 3,860 [3,859] | 3,691 [3,737] |
  | 2 | 5,870 [5,968] | 5,289 [5,296] | 3,878 [3,911] | 3,714 [3,777] |
  | 3 | 5,919 [6,110] | 5,377 [5,376] | 3,918 [3,933] | 3,608 [3,655] |
  | 4 | 5,833 [5,825] | 5,358 [5,341] | 3,896 [3,946] | 3,609 [3,620] |
  | 5 | 5,847 [5,834] | 5,324 [5,406] | 3,906 [3,982] | 3,631 [3,626] |
  | 6 | 5,889 [5,885] | 5,466 [5,450] | 3,932 [4,066] | 3,652 [3,650] |
  | Mean (sd) | **5,835 (95)** | **5,362 (60)** | **3,898 (26)** | **3,651 (44)** |

  - S3: new − old = **−472 B/row, SE 46** (≈ 10 σ). Totals per run (18 per state): at 25k 258.6 → 245.7 MB, at 100k
    696.2 → 647.9 MB.
  - S4: new − old = **−247 B/row, SE 21** (≈ 12 σ). At 25k 211.4 → 203.5 MB, at 100k 503.8 → 477.3 MB.
  - Report (same JVMs, a control): S3's 1,988 → 2,006 (+18, SE 11), S4's 2,006 → 2,011 (+4, SE 3); unchanged.
  - Both gains exceed the bisect's ≈ 100–170 B/row JFR sample, S3's most; per site not attributed.
- **Findings, not fixed:**
  1. Two equal, distinct contracts with non-empty maps still compare them through `Map.equals`, whose iterators
     measured 0 B under C2 (escape analysis), not guaranteed under another JIT outcome.
  2. `DataType` / `TypeMetadata` hashes are not cached; only the contract's is, so a freshly built contract walks its
     structure once on its first hash.
  3. The `:kzen-auto-jvm:test` run left two empty `kzen-auto-test-work*` dirs in `%TEMP%` (older ones from earlier
     dates exist too): a `forTest()` context some test does not close; not traced.
  4. WR16 finding 3 (the resolver's unbounded contract-keyed caches) stands.
- **Restored:** kzen-lib republished from the user's tree with WR23 (the published jars byte-equal to `build/libs`);
  kzen-auto unchanged, Maven Local holding its HEAD build; scratch worktrees removed and pruned.

### WR24 — test work roots left in the temp directory (2026-10-08)

kzen-auto `:kzen-auto-jvm:test` 1276 tests, 0 failed, 1 skipped (12m34s on a loaded machine; the instrumented
diagnosis run of the same suite took 3m53s, the guard adds one stack capture per `forTest()` context, ≈ 490 per run);
`:kzen-auto-jvm:pluginUniverseTest` 8 green; kzen-auto republished (`publishToMavenLocal -x test`, no bump); kzen-project
compiles (`kzen-project-common:compileKotlinJvm`, `kzen-project-jvm:compileKotlin`). No common code changed.

- **Diagnosis.** Temporary instrumentation in `KzenAutoContext` recorded each `forTest()` root with its creating stack,
  dropped it on `close()`, logged every swallowed delete failure and any root still on disk after close, and listed
  the roots still open at JVM exit; an init script pointed the test JVMs' `java.io.tmpdir` at a scratch directory, so
  everything the suite left behind was attributable to it. Six forks, 492 contexts: 490 closed and deleted, **no
  delete failed**; **2 never closed**, `FlowTypedPortTest.listPortAcceptsAnEmptyList` and `mapPortAcceptsAnEmptyMap`
  (WR21). Each runs its flow twice, and `engineFor` reassigned the `lateinit` context, so `@AfterTest` closed only the
  second; the first one's root stays empty because the flow writes nothing to it. That is the pair of empty dirs
  every full run has left since WR21 (2026-10-08 16:22 onward in `%TEMP%`).
- **Held handles: not reproduced.** The shared `kzen-auto-test-code-cache` root was deleted by its shutdown hook in
  every run here. The user's older leftovers that hold files (9 code-cache roots with `JobExpression_*` jars, 3 work
  roots from 2026-10-07 with `index` / `build`) fit a JVM that exited while a loader or an index handle was still
  open (a single-class or interrupted run, or an earlier state of the code); nothing in the current suite does it.
- **Fix.** `FlowTypedPortTest.engineFor` creates the test's context once and reuses it for the second run.
- **Guard.** `TestContextLeakGuard` (kzen-auto-jvm `server.context`, internal): `forTest()` registers its work root
  with the creating frames (test framework, reflection and coroutine frames dropped, so the helper and the test
  method show), `close()` removes it, and a shutdown hook logs every root still open at JVM exit. kzen-auto-jvm's
  build sets `kzen.test.unclosedContextReportDir` (`build/unclosed-test-contexts/<task>`) on every `Test` task: the
  hook writes its report there, the task clears the directory first and fails in `doLast` when a report exists,
  naming each root and its creator. Keyed by work root, not by context, so a leaked context is not kept reachable.
  Production contexts never touch it; elsewhere (IDE runs, kzen-project's tests) it only logs. Checked against the
  unfixed test: `--tests "*FlowTypedPortTest"` failed with both roots named by
  `FlowTypedPortTest.engineFor ← runFlowResult ← listPortAcceptsAnEmptyList` / `… ← mapPortAcceptsAnEmptyMap`. The
  swallowed delete failure was already logged at warn (`deleteTemporaryWorkRoot`); unchanged.
- **`%TEMP%` before / after a full run:** 32 `kzen-auto-test-*` dirs before and after, no new `kzen*` entry. The
  user's pre-existing leftovers are untouched: 444 `kzen*` dirs (≈ 1.2 MB), among them 23 `kzen-auto-test-work*`
  (20 holding no files, ≈ 5 KB in all), 9 `kzen-auto-test-code-cache*` (≈ 450 KB), 109 `kzen-kit-module*` (≈ 700 KB). Leftovers of
  this phase's own runs were recorded and deleted (verified by creation time and name).
- **Findings, not fixed:**
  1. The same reassignment (`context = KzenAutoContext.forTest()` inside a helper, closed by `@AfterTest`) is in
     about 20 other classes (`FlowNotationTest`, `FlowCapabilityTest`, `JobDeadlockTest`, `JobNotationTest`,
     `JobElementModelTest`, …): sound while each test calls the helper once; the guard now fails a second call.
  2. The suite still leaves 59 temp entries per run under other prefixes, from tests that create a temp file or dir
     and never delete it: `file-source-*` (20), `read-worker-file-cache*` (9), `universe*` (8), `schema-cache-*` (5),
     `inspection-*` (4), `shape-*` (3), `column-listing*` (2), `cached-kotlin-compiler-storage-test*` (2), and single
     ones; `pluginUniverseTest` leaves about 35 more (`module*`, `universe*`, `work-*`, `kit-verify*`). Pointing the
     test tasks' `java.io.tmpdir` into `build/` would contain them all, but hides rather than fixes; a decision.
  3. `PluginCompatibilityKit.verify` (main code) never deletes its `kzen-kit-module*` module root: one per verify,
     from `CompatibilityKitBootTest` in `pluginUniverseTest` and from every kit verify of a plugin.
  4. kzen-lib's jvmTest leaves `kzen-native-types-*`, `kzen-bean-shape-*`, `kzen-recursive-*`, `origin*` and
     `aggregate*` per run; the kzen-auto-test self-test leaves `kzen-sut-*`. Outside `:kzen-auto-jvm:test`.

### WR25 — kit verify leaves its temp module root (2026-10-08)

Landed with WR26, which carries the runs: `pluginUniverseTest` 8 green, `:kzen-auto-jvm:test` 1276 tests, 0 failed,
1 skipped; kzen-auto republished (`publishToMavenLocal -x test`, no bump); kzen-project compiles.

- **Fix.** `PluginCompatibilityKit.verify` deletes its `kzen-kit-module*` module root in a `finally`. It runs after an
  inner `finally` has closed the verification context that holds files in the root, so a verify that passes, fails
  or throws ends the same way. The delete goes through `WorkUtils.deleteDirThrowing`. If it fails, the root is logged
  at warn and the verify does not fail. Nothing returned refers to the root: the `KitReport` carries scope, class and
  document rows, all taken from the pinned universe.
- **Same file, `inspect`.** Inspect pins nothing, so it owns the scopes' class loaders. Until now it closed them only
  on the success path, after building the rows. A boot error in contribution discovery left the plugin jars open
  until garbage collection, and on Windows an open jar cannot be deleted or replaced. Inspect now closes the loaders
  in a `finally` through the new `PluginScopes.closeFolderLoaders()`. That function is internal and only for a
  universe that is not pinned. The rows are now built in a new `inspectScopes`.
- **Test.** `CompatibilityKitBootTest` records the `kzen-kit-module*` entries of `java.io.tmpdir` before its passing
  verify and checks for the same set afterwards. It checks again after a second verify that fails because an expected
  class is missing. Before the fix it failed on the first comparison.
- **Production impact.** Each kit verify of a plugin left one module root in the system temp directory for good. The
  user's `%TEMP%` holds 109 of them (≈ 700 KB). Now none are left.

### WR26 — tests clean up their temp files (2026-10-08)

Results:
- kzen-auto: `:kzen-auto-jvm:test` 1276 tests, 0 failed, 1 skipped, and `:kzen-auto-jvm:pluginUniverseTest` 8 green
  (11m15s together on a loaded machine). Republished with `publishToMavenLocal -x test`.
- kzen-lib: `build publishToMavenLocal --rerun-tasks` green in 1m27s (jvmTest 488, jvm test 204, js 402 + 1 skipped).
- kzen-project compiles (`kzen-project-common:compileKotlinJvm`, `kzen-project-jvm:compileKotlin`), and kzen-auto-test
  compiles (main and test).
- The self-test was not run, because it drives a non-headless Chrome.
- No version bump, and no common code changed.

- **Attribution.** WR24's method: a Gradle init script pointed each test task's `java.io.tmpdir` at its own scratch
  directory for one diagnostic run (`--no-configuration-cache -I …`). Every leftover then belonged to one suite, and
  each name was traced to the test that creates it. Baseline leftovers per suite:

  | Suite | Leftovers |
  |---|---|
  | `:kzen-auto-jvm:test` | 59 |
  | `pluginUniverseTest` | 35 |
  | kzen-lib `jvmTest` | 4 |
  | `kzen-lib-jvm:test` | 7 |

  - `:kzen-auto-jvm:test`. Most leftovers are temp dirs and files that the `WorkUtils.temporary` and
    `Files.createTempDirectory` callers create and never delete:
    - `file-source-*`, `shape-*`, `invalid-delimiter-quote` and `2026-08-sales` (22, `FileDataSourceTest` and
      `FileDataSourceFormatBudgetTest`)
    - `read-worker-file-cache` (9, `ReadWorkerFileIntegrationTest`, one schema cache per instance)
    - `schema-cache-*` (5, `SchemaCacheTest`)
    - `inspection-*` and `*-reader-spi` (7, `ReaderCapabilityRegistryTest` and `SequentialContentStackTest`)
    - `column-listing*` (2)
    - `kit` and `kit-boot` (`PluginCompatibilityKitTest`)

    Two groups also **held open files**, so even a delete would have failed on Windows:
    - `universe*` (8, `PluginScopeDiscoveryTest` and `PluginContributionDiscoveryTest`): the discovered scopes'
      `URLClassLoader`s keep their jars open.
    - `cached-kotlin-compiler-storage-test*` (2): the compiler's loaded entries keep their jars open.
  - `pluginUniverseTest`. Every boot test leaves its `module*`, `universe*`, `work-*` and `kit-verify*` dirs, and the
    kit leaves its own `kzen-kit-module*` (WR25). These dirs hold the pinned universe's jars, which stay open for the
    JVM's life for two reasons:
    - The scope loaders keep them open.
    - The standing Kotlin compiler environment is deliberately never disposed. Its `FastJarFileSystem` keeps every
      jar an expression compiled against memory-mapped.

    Closing the loaders alone still failed the delete in `CompatibilityKitBootTest` and
    `AggregateExpressionBootTest`.
  - kzen-lib:
    - `kzen-native-types-*`, `kzen-recursive-*` and `kzen-bean-shape-*` are the compiled-class dirs of
      `DefaultNativeTypeResolverTest`, `RecursiveContractTest` and `PlainObjectShapeTest`.
    - `origin*` (`OriginNotationMediaTest`) and `aggregate*` (`AggregateClassLoaderTest`) also held their jars.
      `OriginNotationMedia` read each document through a cached `jar:` connection. That parks the jar in the JDK's
      process-wide jar file cache for good, so the jar stayed open after its loader was closed.
  - Self-test (by reading only, not run):
    - The 45 empty `kzen-sut-*` dirs in `%TEMP%` date from 2026-05-24 to 2026-07-28. SUT runs on 2026-08-06, 07 and
      13 left none, which fits the identity-checked `removeAndClose` of 2026-07-29. Not reproduced.
    - The live leak is the SUT's work root. The SUT runs with its temp dir as its cwd, so the standalone default
      `../work` resolved to `%TEMP%\work`. That dir is shared by every SUT of every run and never deleted; it holds
      102 code-cache dirs since 2026-05-24.
- **Main-code owners fixed, with production impact.**
  1. `PluginCompatibilityKit.verify` and `inspect`: see WR25.
  2. `KzenAutoRuntime.initialize`: if contribution discovery failed, the scope loaders it had just opened were never
     released. Scope discovery opens jars lazily, so its own boot errors hold none. In production, an embedding host
     that failed to boot over a bad plugin folder could not replace those jars on Windows until GC. The loaders are
     now closed before the error is rethrown.
  3. `OriginNotationMedia` (kzen-lib) now reads with `useCaches = false`. In production, every plugin scope's
     bundled-notation jar was held twice for the life of the process. That was harmless to a pinned universe, but the
     hold outlived the closed loaders of kit `inspect` and of failed boots. Now only the loaders hold the jars.
  4. kzen-auto-test: `StartKzenAutoStep` starts the SUT with `--work.root=<temp dir>/work`, so the work root is
     deleted with the temp dir; `KzenAutoProcess.startFromJar` gained `args` for this. `KzenAutoSubprocessRegistry`
     now prints a failed temp-dir delete instead of swallowing it. The cost: there is no warm code cache across SUT
     runs, so SUT expressions compile cold.
- **Test fixes.**
  - JUnit 4 classes own their temp files through
    `@get:Rule val temp = TemporaryFolder.builder().assureDeletion().build()`: `FileDataSourceTest`,
    `FileDataSourceFormatBudgetTest`, `ColumnListingActionTest`, `SchemaCacheTest`, `ReaderCapabilityRegistryTest`,
    `SequentialContentStackTest`, `PluginCompatibilityKitTest`, `PluginScopeDiscoveryTest` and
    `PluginContributionDiscoveryTest`. If the delete fails, the test fails.
  - The two discovery tests close every `PluginScopes` they discovered in `@After`, which runs before the rule
    deletes.
  - `CachedKotlinCompilerStorageTest` calls `releaseLoaded()` on each compiler, then `WorkUtils.deleteDirThrowing`.
  - `ReadWorkerFileIntegrationTest` deletes its cache root in `@After`.
  - The eight boot tests use the new test-side `BootTemporaryFolder`. Before deleting, it closes the pinned
    universe's folder loaders and empties the compiler environment's open-jar cache (`cleanOpenFilesCache()`). That
    is safe because each boot class has a JVM of its own (`forkEvery = 1`).
  - kzen-lib's tests delete in `@AfterTest` or `finally`, using `kotlin.test` as its guide requires.
- **Guard.** There is no suite-level diff of the temp directory. Forks run in parallel over one shared
  `java.io.tmpdir`, and the user's own processes write there too, so such a check would be flaky. The guard is per
  test instead: `assureDeletion()` fails any test whose files cannot be deleted, which is how the held-handle cases
  above were found. The durable rule is in kzen-auto's and kzen-lib's AGENTS.md.
- **`%TEMP%` before / after.**
  - Redirected run after the fix: all four suite directories are **empty** (kzen-auto 0 + 0, kzen-lib 0 + 0).
  - Unredirected run over the user's real `%TEMP%` (kzen-lib `jvmTest` + `jvm:test`, then kzen-auto `test` +
    `pluginUniverseTest`, all with `--rerun`): 451 `kzen*` entries before and 451 after, with no new entry from any
    suite.
  - The only new names were zero-byte GUID `*.tmp` files and a `foundation-coordinate-*` dir, and most of them were
    already gone again. They come from processes outside the test JVMs: the redirected runs catch everything a test
    JVM writes, and they stayed empty.
  - The user's pre-existing leftovers are untouched.
- **Findings, not fixed:**
  1. kzen-lib's `jsBrowserTest` (KGP's karma + webpack) leaves a `_karma_webpack_*` dir of 4–8 MB per run. The user's
     `%TEMP%` holds 1662 of them. This is KGP tooling, outside the JVM suites. This phase's own full kzen-lib build
     added two of them and a `chrome_chrome_url_fetcher_*` dir, which were not deleted here.
  2. The standing Kotlin compiler environment keeps every jar an expression compiled against memory-mapped for the
     life of the process. That is consistent with a pinned universe ("restart to upgrade"). Code-cache jars were
     deleted fine.
  3. `WorkUtils.temporary(name)` is main code that only tests used. The tests no longer use it; it is left in place.
  4. The WR25 check lists the whole system temp directory (≈ 24k entries on this machine) twice per verify. That is
     fine for one boot test.
  5. The 45 old `kzen-sut-*` dirs and `%TEMP%\work` belong to the user and were left as they are.
- **Follow-up (2026-10-09, user-approved): findings 1 and 4 fixed.**
  - Finding 1: karma-webpack defaults `output.path` to a fresh `os.tmpdir()/_karma_webpack_<random>` that nothing
    deletes. A `karma.config.d/webpack-output.js` in every module that runs browser tests (`kzen-lib-common`,
    `kzen-lib-js`, `kzen-auto-common`, `kzen-auto-js`, `kzen-launcher-common`) points it at
    `build/js/packages/<module>-test/karma-webpack`, emptied at the start of each run. All five `jsBrowserTest
    --rerun` runs pass and add no `%TEMP%` entry. kzen-project has no browser tests and has no copy.
  - Finding 4: `PluginCompatibilityKit.verify` gained an internal overload that takes the temporary parent.
    `CompatibilityKitBootTest` passes its own folder and asserts it is empty after a passing and a failing verify.
    `pluginUniverseTest` 8 green.
  - With the user's approval, 1664 old `_karma_webpack_*` dirs (≈ 317 MB) and 109 old `kzen-kit-module*` dirs were
    deleted from `%TEMP%`.
