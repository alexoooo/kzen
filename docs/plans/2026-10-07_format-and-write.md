# Format and Write: records to bytes as a chain of Workers — constituent plan (WR)

> **Status: planned 2026-10-07; WR1–WR7 open.** Written with the user after combining two flat files in a Job
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

> WR2 replaces this section with its full design for the user's review before implementing. What follows is the
> problem statement and the proposal it starts from.

**Need.** A pooled object (a `Bytes` buffer, later a row) may return to its producer's pool only when nothing can
still read it: not the channel, not the consuming callback, not a Worker that kept it, not migration carryover,
not a value derived from it in place (Formula's exclusive append, DM6).

**Proposal.**

- A small interface for pooled objects, deliberately **not** `AutoCloseable` (so the ledger never adopts them):
  an atomic hold count and a release that returns the object to its pool at zero.
- **Holds follow the existing protocol's points, without the ledger.** The channel's `send` takes a hold before
  the sender lets go (`JobChannel.kt:315`, the same "never touches zero mid-hop" order); the framework drive loop
  releases after the consuming callback; `JobControl.retain` takes one for a Worker that keeps the value (its
  contract already requires that, or a copy); `snapshot` copies; carryover keeps its holds and transfers them.
  Unlike an owned element, a recyclable element **batches normally**: the flush-at-once rule exists for elements
  whose release a producer may wait on, and the pool never waits.
- **The pool grows instead of waiting** when empty, so a Worker that keeps many values (Sort) just takes them out
  of circulation; an idle cap bounds what the pool keeps afterwards. Steady state is the number in flight
  (channel capacity × batch size, plus the callback in hand), as Report's ring is its size. The return path is
  allocation-free (an array-backed structure, not a linked queue).
- **The hold is on the pooled object, not on a `DataValue`**, so a value derived in place (Formula appending to
  the same backing) is covered: its `send` holds before the input's callback hold is released.
- **Safety net in tests:** a generation stamp, checked on read, turns a use-after-recycle into a named failure.

**What WR2 must establish:**

1. A retention audit of every Worker (`CsvWriterWorker`, `ExploreWorker`, `ExportWriterWorker`, `ExtractWorker`,
   `FileSourceWorker`, `FilterWorker`, `FormulaSourceWorker`, `FormulaWorker`, `LogicSourceWorker`,
   `ParseWorker`, `PathProjectionWorker`, `PivotWorker`, `PreviewWorker`, `ResultSinkWorker`, `RunWorker`,
   `SortWorker`, `SummaryWorker`, `TakeWorker`, `ValueSetFilterWorker`, `WriteWorker`, and the two legacy
   sources): which keep a value past the callback, and whether through `retain` / `snapshot` or a copy. Today
   only `SortWorker` calls `retain` and only `ResultSinkWorker` calls `snapshot`. `RunWorker` (a value passed to
   a child Logic) and trace snapshots need explicit answers.
2. Where the drive loops' callback release lives for each loop (source / transform / expanding / sink) and that
   it runs on failure and cancellation.
3. Whether any of this needs kzen-lib (expected: no; holds key on kzen-auto objects).

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
- **Tests:** a test recyclable through Filter, Formula (in-place append), Take (early close), Sort (`retain`),
  Preview, Result, a failure mid-batch, cancellation, and a live-edit migration with values in flight; no
  use-after-recycle; pool size bounded by in-flight count; unowned values unaffected (the ledger's fast path).

### WR3 — `Bytes` and `Format`

- `Bytes`, its pool, the `Format` archetype in `job-worker.yaml` and its Worker (§4.4).
- **Tests:** header from the contract under combined columns (two files with different columns); grouping by a
  constant, by `${parent.name}`, by a column; empty stream emits nothing; a format refusal surfaces by name.
- **Benchmark:** add scenario **S4** to `JobReportBenchmark`: S3's Job with `Format(ConfiguredCsv) → Write(none)`
  in place of `Export`, asserting byte-identical output to S3's Report; record wall time and Epsilon bytes/row
  next to S3. `Format`'s own steady-state allocation is the pass criterion (R4).

### WR4 — `Write` over `Bytes`

- `WriteWorker` dispatch on its input type before Run; the run state machine (§4.5); validation error naming
  `Format`.
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
- **Tests:** WR2's suite with real rows, including Formula's in-place append and Sort; S1–S4 outputs unchanged;
  bytes/row recorded.

## 6. Measurement

`JobReportBenchmark` (`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/job/bench/`), `benchJob` and
`benchJob -PbenchEpsilon` (bounded 250K rows). J5a's table is the reference. Throughput is still dominated by the
per-record path J5b targets (J5a: S3 Job 33.2 s vs Report 1.7 s per 1M rows), so WR judges allocation by
bytes/row and GC counts, and treats wall time as a secondary record.

## 7. Open questions

1. **`nullToken` round trip** (WR1): how the reader treats a quoted value equal to the null token decides whether
   the writer quotes it or refuses it.
2. **Pool idle cap** (WR2): a fixed count, or proportional to channel capacity.
3. **Chunk coalescing** (after WR3): whether one record per chunk measures as a cost worth the checkpoint
   interaction.

## 8. Tracker

- [ ] WR1 — delimited write capability
- [ ] WR2 — recyclable values (design first)
- [ ] WR3 — `Bytes` and `Format`
- [ ] WR4 — `Write` over `Bytes`
- [ ] WR5 — UI and browser verification
- [ ] WR6 — Parse allocates less
- [ ] WR7 — reuse rows (measurement-gated)

## 9. As-built

*(Appended per row as it lands.)*
