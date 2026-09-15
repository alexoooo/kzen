# Content streaming and containers: files as first-class Job elements

> **Status: proposed.** Drawing-board design, written without regard to implementation cost or compatibility
> with the landed Worker set. Where it coincides with what exists (`DataRef`, `DataPart`, `ContentCodingSpec`,
> `SequentialByteContent`, the E9 ownership ledger, `ReadPartWorker`) that is noted, but the existing shape was
> not a design input. Builds on [data reading](2026-08-29_data-reading.md) (content providers, coding chain,
> ownership stack), the [unified data model](2026-08-27_data-model.md) (type language, native backings,
> snapshots) and the [Job data source](2026-08-20_job-data-source.md) analysis (units, parts, writers that yield
> refs).

## 1. Decision in one page

**A file is a value.** Introduce `Content` — a finite, sequentially readable byte content with a descriptor —
as a scalar kind in the data type language, next to `Binary` (bytes in memory). An archive entry, a file on
disk, an object in a bucket and an HTTP body are all `Content`. A Job element that represents a file is an
ordinary record whose fields are the file's metadata plus one `Content` field:

```text
Entry { name: Text, size: Integer?, modified: Timestamp?, content: Content }
```

**Containers yield entries; codings transform bytes.** A container (tar, zip, a directory) is content that
holds named entries. A coding (gzip, zstd) is a transparent byte-to-byte transform and is bidirectional — the
same registry entry decodes on read and encodes on write. `foo.tar.gz` is `container: tar` over `coding: gzip`,
never "two codings". Containers split into **indexed** (zip, directory, object-store prefix — entries are
enumerable and independently openable) and **sequential** (tar, tar.gz, concatenated streams — entries are
reachable only in order, in one pass). Both produce the same `Entry` element; only the access class differs.

**Transient content has handoff semantics.** Content from a sequential container is valid only while the
container is positioned on it. Such an element is *positional*: the producer's send does not complete until
every holder of the element has released it. A lane carrying transient content therefore runs as a rendezvous
regardless of channel capacity — no copy, no buffering, constant RAM — and the user configures nothing.
Keeping a transient element past the callback that delivered it (a Sort, a Result, a fan-out) requires an
explicit **spool** to durable content, whose memory / scratch-file cost is visible in notation.

**Chunking is transport, never an element.** The user's unit of work is the file. Chunked byte records
(`{name, offset, bytes, last}`) leak the transport into the notation, make every generic Worker (Filter,
Formula, Sort, Preview, the tabular readers) either wrong or meaningless over the lane, and invent a
`last`-flag protocol between Workers. A bounded pipe of chunks may exist *inside* a content handle to overlap
inflate with deflate across threads; it is invisible to Workers and to notation (§6.3).

The motivating task — read `data.tar.gz`, keep `*.txt`, write each as `C:/out/<name>.gz` — is then two
notation objects with no code:

```yaml
Archive:
  is: ContainerSource
  path: C:/in/data.tar.gz
  entries: "*.txt"
Write:
  is: ContentWriter
  directory: C:/out
  coding: gzip
```

and the same `ContentWriter` writes plain copies, the same `Entries` transform reads entries out of a stream of
archives, and `ReadPart` parses a CSV entry straight out of a tar.gz without extracting it (§8).

## 2. Problem statement

### 2.1 The immediate task

Given a `.tar.gz`, select the entries whose names match a pattern and write each selected entry, individually
gzip-compressed, into a target directory: `foo.txt`, `bar.csv`, `baz.txt` in the archive with filter `*.txt`
yields `C:/out/foo.txt.gz` and `C:/out/baz.txt.gz`. Constraints:

- **No redundant copies.** The bytes of an entry are inflated once, deflated once, and touched by nothing else.
  In particular no entry is materialized whole, in RAM or on disk, on the way through.
- **Bounded RAM.** Memory use is a function of buffer sizes, not of entry size, entry count or archive size.
- **Efficient.** The unavoidable work is one inflate pass over the whole archive (tar has no index; every entry
  must be inflated to reach the next) and one deflate pass over the selected bytes. Anything beyond that is
  overhead to be justified.

### 2.2 What is actually missing

The Job paradigm is record-centric: a channel carries a `DataValue`, Workers project columns or bind natives, a
sink writes rows. Nothing in it says "this element *is a file*". Three specific gaps:

1. **No value kind for streamed bytes.** `Binary` is a `ByteArray` — bounded, copied on lift, inlined into
   snapshots. A file-sized content cannot be a `Binary` without violating the RAM constraint. A `DataRef` is an
   *address* of durable content, which an entry positioned inside a single-pass stream does not have.
2. **No notion of a container whose entries are only reachable in order.** The data-source model assumes a
   manifest is resolvable up front and each `DataPart` is independently openable ([data reading
   §4.2](2026-08-29_data-reading.md#42-content-access-resolves-refs-to-capabilities)). A tar.gz satisfies
   neither: enumerating it is a full pass, and opening entry *k* independently is a re-scan of entries 1..k.
   That analysis already flagged ZIP as a container, not a coding, and deferred an "archive source"; tar makes
   the sequential case unavoidable.
3. **No channel semantics for a value that is only valid until its producer advances.** The E9 ownership ledger
   knows *who holds* a native and closes it after the last release; it does not stop the producer from pulling
   the next item while the current one is still being read. With channel capacity or batch size above one, a
   lazy tar-entry stream sent as an element is invalidated by the source's next pull before the consumer reads
   it. The general problem is a lane whose elements alias one underlying single-pass stream.

### 2.3 Why this is worth a bigger change

The tar.gz task is the first instance of a class: files as elements. The same model covers a directory of
archives, an object-store listing, an HTTP download, "unzip these and re-compress those", "parse the CSV inside
this tarball", "tar up the outputs of a Job", and a Script step that hands a file to a Job. Solving the instance
with a purpose-built pair of chunk Workers leaves every one of those as a fresh special case. Solving the class
adds one scalar kind, one element shape and one channel rule, and every existing Worker composes with it.

## 3. Design principles

- **The user's unit is the file.** Whatever crosses a channel in this feature is an entry: one element per
  file, with metadata the user can filter on and content the user can hand to a reader or a writer. Transport
  concerns (chunks, buffers, threads) never surface in notation, cards or expressions.
- **One content model on both sides.** Reading and writing use the same `Content` value and the same coding
  registry. A writer is the dual of a source, not a separate vocabulary.
- **Cost is explicit; safety is automatic.** Anything that costs memory or disk in proportion to data size
  (spooling, collecting) is a visible notation object or attribute. Anything that would be *incorrect* without
  care (buffering a transient element) is prevented by the framework, not by the user remembering a rule.
- **Access class is a property of the container, not of the Worker.** A Worker asks for entries; whether they
  come from an index or a sequential pass is decided by the container capability, and the lane's semantics
  (durable vs transient) follow from that automatically and are shown on the card.
- **Reuse the existing seams by generalizing them, not by wrapping them.** `DataPart` learns to carry content
  it already addresses; the coding chain learns to encode; the ownership ledger learns one more lease kind.

## 4. The `Content` value

### 4.1 Type

`ScalarKind.Content` joins the scalar kinds in kzen-lib's type language. Its structural meaning is "a finite
byte sequence read by reference". It differs from `Binary` in three ways: it is never inlined into a snapshot or
a trace (its snapshot is its descriptor), it may be larger than memory, and it is read through a handle that
the ownership ledger closes. A field of type `Content` in a record contract renders on a card as a content badge
(name, size, coding, access class) rather than a value.

### 4.2 Value

```kotlin
interface Content {
    val descriptor: ContentDescriptor          // name, length?, modified?, mediaTypeHint?, codingHint?, fingerprint?
    val access: ContentAccess                  // Durable | Transient
    fun open(): SequentialByteContent          // provider-neutral read(buffer, offset, length): Int + close
}

enum class ContentAccess { Durable, Transient }
```

- **Durable** content may be opened any number of times, concurrently, from any thread, and its bytes are stable
  under its fingerprint. A local file, an object-store object, an indexed-archive entry and a spooled copy are
  durable. A durable content is convertible to a `DataRef` and back through the content-provider lookup; a
  `DataRef` is precisely *the address of durable content*, which is why the existing `DataRef` / provider model
  stays as it is.
- **Transient** content may be opened **once**, only while its producer holds position on it, and only by the
  element's current holder. A sequential-archive entry, an HTTP response body, a decoded stream from a
  non-seekable source are transient. Transient content cannot become a `DataRef`; it must be spooled or
  consumed. Its descriptor is complete (a tar header carries name, size, modified) even though the bytes are
  not yet read, so filtering and routing by metadata never touch the stream.

`SequentialByteContent` already has this signature in kzen-auto-jvm; it moves to the common data model (its
contract has no JVM types) so that `Content` is expressible in `commonMain` and in the plugin SPI.

### 4.3 Where `Content` appears

- **`DataPart.content`** — a part is *role + content + resolved read spec*. Today it is role + ref + spec and
  resolves the ref through the opener; with content on the part, the opener chain (coding → character decoder →
  configured reader) opens `part.content` directly. A durable part's content is provider-backed and still
  fingerprinted; a transient part's content is whatever the container handed out. `ReadPartWorker` and every
  configured reader therefore work over archive entries with no change to their own logic.
- **`Entry` records** — the element shape emitted by container Workers (§5.3). `entry.content` is the part
  content for a single-role unit; a Formula can build a `DataUnit` around it when roles matter.
- **Job parameters and results** — a Job may declare a parameter of type `Content` (a Script step hands a file
  to a Job); a result of type `Content` must be durable (a transient content is refused by `yieldResult` exactly
  as an owned native is today).
- **Snapshots, traces and previews** — always the descriptor, never bytes. A `Preview` over an entry lane shows
  name, size and access class; a byte-level peek is a separate, explicitly bounded action.

## 5. Containers and codings

### 5.1 Codings are bidirectional byte transforms

`ContentCodingSpec` keeps its identity + config + digest shape. The registry behind it becomes:

```kotlin
interface ContentCodec {
    val identity: String                                   // "gzip", "zstd", "bzip2", "xz"
    fun decode(bytes: SequentialByteContent, config, control): SequentialByteContent
    fun encode(sink: ByteSink, config, control): ByteSink  // absent for decode-only codecs
    fun extension(config): String                          // ".gz"
    fun sniff(head: ByteArray): Boolean                    // magic-byte probe for `auto`
}
```

Plugins register codecs by inheritance capability, the same way readers are discovered. The chain type stays a
list, and the validated depth stays what real cases need (one coding; `tar.gz` is not two). The encoder side
carries the parallel-block gzip that Report's export already uses, so a `ContentWriter` with `coding: gzip`
produces the same bytes as a Report export with `compression: gz`.

### 5.2 Containers have an access class

```kotlin
interface ContainerFormat {
    val identity: String                                   // "tar", "zip", "directory"
    val access: ContentAccess                              // what its entries are
    fun sniff(head: ByteArray, descriptor: ContentDescriptor): Boolean
    fun openEntries(content: Content, selection: EntrySelection, control): EntryCursor
}

interface EntryCursor: Iterator<Entry>, AutoCloseable    // Entry.content.access == format.access
```

- **Indexed** (`zip`, `directory`, an object-store prefix): `openEntries` may read a central directory or a
  listing and hand out durable entries in any order. The same format also backs a `DataSource` — an indexed
  container *is* a resolvable manifest — so design-time browsing, part pickers and `ReadWorker` work over it.
- **Sequential** (`tar`, and any container reached through a non-seekable coding): `openEntries` walks the
  stream. Each entry is transient; advancing the cursor (or closing it) ends the previous entry. There is no
  manifest and the picker offers no listing; an explicit "scan" preview may enumerate names at the cost of one
  pass, clearly labelled.

A `zip` inside a `gzip` (rare, but `foo.zip.gz` exists) is indexed by format but sequential by reach; the
cursor's access class is the *weaker* of the format's and the coding chain's. This is what "access class is a
property of the container, not the Worker" means in practice.

### 5.3 The `Entry` element

```text
Entry {
  name: Text                 // path inside the container, forward slashes
  size: Integer?             // from the header when known
  modified: Timestamp?
  kind: Text                 // "file" | "directory" | "symlink" — directories and links are emitted only on request
  content: Content
}
```

`Entry` is a record with a declared contract, so the design-time payload walk shows its fields, `Filter` and
`Formula` bind them by name, and a Worker written in Kotlin sees a plain object. Container-specific metadata
(mode bits, owner, zip comment) is a nested `attributes: Map<Text, Text>` — present, never load-bearing.

### 5.4 Resolution and identity

`container: auto` and `coding: auto` are resolved at open time from descriptor hints (extension, media type,
provider coding hint) and magic bytes, and the resolved answer is recorded in the Worker's resolved spec and
digest, following [data reading §4.3](2026-08-29_data-reading.md#43-content-coding-wraps-byte-capabilities):
hints propose, the resolved spec decides, and a renamed file cannot silently change interpretation across a
migration.

## 6. Channel semantics for transient content

This is the part of the design that makes "no copies, bounded RAM" true *by construction* rather than by
convention.

### 6.1 Positional elements and the handoff lease

An element whose value transitively contains transient content is **positional**. The E9 ledger gains a lease
kind, the *handoff lease*: when a source sends a positional element, the send suspends until every hold on that
element has been released — the channel's hold, each downstream callback's hold, and any hold taken through
`retain` (which for transient content is refused, §6.2). Only then does the producer's `pull` for the next item
run. Consequences:

- A lane carrying positional elements runs as a **rendezvous**: at most one entry is in flight between the
  container cursor and whichever Worker is consuming it, regardless of the channel's configured capacity and
  batch size. The card shows "sequential: one entry in flight" so the behaviour is not a surprise.
- **No copy is ever made.** The consumer reads `entry.content` on its own thread; the read pulls through the
  container's decode stack (tar → gzip → provider bytes), which is safe because the producer is parked in its
  send and nothing else touches the stack.
- **Ordinary Workers need no change.** `Filter` that rejects an entry simply lets go of it; its hold releases,
  the source advances, the entry's bytes are inflated-and-discarded by the cursor's skip. `Formula` that returns
  a record derived from the entry inherits the entry's holds (E9 item 3) and so keeps the position until *its*
  output is released. `ContentWriter` reads the content inside `onElement` and is done. A `TransformWorker` that
  suspends mid-callback under backpressure (an owned element flushes at send) still holds the entry, so the
  source still waits — correct, at the cost of pipeline depth, which is inherent to single-pass input.
- **Fan-out is refused at validation** for a positional lane (two consumers cannot both read a once-only
  stream), with the message naming the spool that would make it legal. This composes with the planned J6
  fan-out: a fan-out over a durable lane is fine.

### 6.2 Retention requires spooling

`JobControl.retain` on a value containing transient content fails by name: *"Sort holds entry 'foo.txt' past
its callback; its content is sequential (tar). Insert a Spool before Sort, or spool inside the Worker."* Spooling
converts transient to durable:

```kotlin
fun Content.spool(policy: SpoolPolicy, control: JobControl): Content   // Durable
data class SpoolPolicy(val memoryBudget: Long, val scratch: Boolean)   // RAM up to budget, then scratchDir()
```

A `Spool` Worker exposes the same policy in notation for users who want an accumulator (Sort, ResultSink
`keep: all`, Pivot over entries) downstream of a sequential container. It is deliberately a separate object:
the cost it introduces — memory proportional to the largest spooled entry, scratch disk proportional to the
retained set — is exactly the cost the constraints in §2.1 forbid by default, and putting it in the notation
is what keeps the default honest.

`snapshot` of a transient content is its descriptor. A Result that wants bytes wants a `DataRef`, which is what
`ContentWriter` yields after it has written.

### 6.3 Where chunks live

Overlap of inflate (source side) and deflate (writer side) across two threads is the one form of pipeline
parallelism a sequential archive admits. It needs a bounded buffer between the two, and that buffer *is* a copy
— one buffer's worth, constant, not proportional to anything. The design places it inside the transient content
handle: `open()` on a positional element may return a pipe that a reader thread fills from the decode stack, with
a fixed ring of blocks (default four 128 KiB blocks, a Job-wide `content.pipe` setting). Workers, notation and
contracts never see it. Whether the pipe is on or off changes throughput, never semantics — which is the test
that a concern is transport and belongs below the value boundary.

The per-output parallelism (block-parallel gzip on the write side) is likewise inside the encoder; the writer
Worker writes to a stream.

### 6.4 Live edit and migration

The container cursor is a closeable stream, so the existing rule applies: it is detached across a live edit and
adopted by the replacement instance, never re-opened. Because a positional lane is a rendezvous, at most one
entry is in flight at the edit boundary and it is inside a callback, so quiescence waits for that callback as
today; there is no buffered remainder to carry. `ContentWriter` keeps the file-sink restart default (re-resolve
path, re-truncate the *current* file); entries already finalized are durable outputs and are not rewritten. An
edited `entries:` pattern applies from the next entry onward — the cursor does not rewind — and the card says so.

## 7. Workers

All four are thin over the model above. Names are proposals; the shapes are the point.

| Worker | Role | Attributes | Emits |
|---|---|---|---|
| `ContainerSource` | Source | `path` (or `content` expression), `container: auto / tar / zip / …`, `coding: auto / none / gzip / …`, `entries` (glob list), `kinds: files / all` | `Entry` |
| `Entries` | Expanding transform | same as above, minus `path`; input is an element with a `Content` field (an `Entry`, a `DataUnit` part, a `DataRef` record) | `Entry` |
| `ContentWriter` | Transform (output optional) | `directory`, `name: "${name}${extension}"` pattern, `coding: none / gzip / …`, `existing: fail / replace / skip`, `result` | `Written { name, ref: DataRef, size }` per entry |
| `Spool` | Transform | `memory` budget, `scratch: true / false` | same element, content now durable |

- `ContainerSource` / `Entries` are one core with two entry points, the `ReadWorker` / `ReadPartWorker`
  precedent: a literal path for the common case, a transform for "a stream of archives". `entries` is applied
  at the header, before an element exists, so a non-matching entry costs one skip and no rendezvous. A `Filter`
  after the source is equally correct, just slower, and remains the way to filter on anything but the name.
- `ContentWriter` emits one `Written` record per entry rather than yielding a single result, because the
  natural result of writing N files is N refs; `ResultSink keep: all` collects them, and this is the shape the
  Job data-source analysis assigned to J4 (widening a writer's single-container result). An unconnected output
  makes it a sink. Finalization order is unchanged: encode-close, stat, then emit the ref.
- The dual of `ContainerSource` — a `ContainerWriter` that packs incoming entries into one tar.gz or zip — uses
  the same `Entry` shape and encoder registry and needs nothing further from the model. It is out of scope here
  and listed to show the model closes.

## 8. Worked notation

The motivating task:

```yaml
main:
  is: Job

  Archive:
    is: ContainerSource
    path: C:/in/data.tar.gz          # container: auto → tar; coding: auto → gzip
    entries: ["*.txt"]

  Write:
    is: ContentWriter
    directory: C:/out
    coding: gzip                     # name defaults to "${name}${extension}" → foo.txt.gz, baz.txt.gz
```

Filter on something other than the name, and keep a manifest of what was written:

```yaml
  Archive:
    is: ContainerSource
    path: C:/in/data.tar.gz
  Large:
    is: Filter
    where: name.endsWith(".txt") && (size ?: 0) > 1_000_000
  Write:
    is: ContentWriter
    directory: C:/out
    coding: gzip
  Manifest:
    is: ResultSink
    result: written
    keep: all
```

Parse a CSV entry straight out of the archive, never extracting it:

```yaml
  Archive:
    is: ContainerSource
    path: C:/in/data.tar.gz
    entries: ["bar.csv"]
  Rows:
    is: ReadPart                     # opens entry.content through coding → charset → configured reader
    format: SalesCsv
  Total:
    is: Summary
```

A directory of archives:

```yaml
  Archives:
    is: FileSource
    directory: C:/in
    filter: "*.tar.gz"
    emit: units
  Entries:
    is: Entries
    entries: ["*.txt"]
  Write:
    is: ContentWriter
    directory: C:/out
    name: "${unit.name}/${name}${extension}"
    coding: gzip
```

## 9. Is chunked writing the most ergonomic way? No.

The question deserves a direct answer because chunk elements are the *obvious* way to make a single-pass stream
fit a buffered channel, and they do satisfy the RAM constraint. They fail on ergonomics and on composition:

| | Chunk elements `{name, offset, bytes, last}` | Entry elements with `Content` |
|---|---|---|
| What the user sees on the card | a byte-slice record with a protocol flag | a file: name, size, content badge |
| One file is | N elements, with a `last` that every consumer must honour | one element |
| `Filter` | sees N chunks per file; a mistake drops a file's tail | filters files |
| `Formula` / `Sort` / `Summary` / `Preview` | meaningless or corrupting over the lane | work on metadata; retention needs an explicit `Spool` |
| Tabular readers (`ReadPart`) | cannot consume it | parse the entry directly |
| A plugin Worker | must reassemble chunks by name and flag | receives a file |
| The no-copy constraint | one copy per chunk, by design, in the user's model | zero copies; a bounded pipe *may* exist below the value boundary |
| Parallelism | consumer overlaps producer by construction | same overlap, via the pipe, when enabled |
| Vocabulary added | a chunk record type and a `last` convention | one scalar kind, one element shape, one channel rule |

Chunking is the right *transport*: it is how bytes should cross a thread boundary. It is the wrong *element*: it
is not what the user is reasoning about, and it does not compose with anything already in the paradigm.

## 10. Alternatives considered

- **Tar as a `DataSource` with a manifest.** Matches the indexed-container story and the data-reading analysis's
  deferred "archive source", but a tar manifest is a full pass and each independently opened part is a re-scan:
  O(n²) I/O and a decode stack per part. Kept for indexed containers, rejected for sequential ones; the
  access-class split (§5.2) is what lets both share the `Entry` shape.
- **Always spool entries to scratch.** Simple, safe with any channel capacity, and compatible with every
  accumulator. It writes every selected byte to disk once before it is read again — exactly the redundant copy
  the constraints forbid. Retained as the explicit `Spool`, never the default.
- **Lazy `InputStream` as an owned native under E9 alone.** The ledger closes it correctly but does not stop the
  producer from advancing; with capacity or batch size above one the stream is invalidated before it is read.
  Correct only with a rule the user must remember. The handoff lease (§6.1) is that rule made structural.
- **Pull-based channels for this lane.** Equivalent to the rendezvous the handoff lease produces, at the cost of
  a second channel discipline in the engine. Rejected as redundant.
- **A single Kotlin Script step (open → filter → gzip-write in one loop).** The zero-copy minimum, and a fine
  fallback for a one-off. It composes with nothing — no Filter, no ReadPart, no Written refs, no live progress —
  and each variant of the task is new code. The Job model above reaches the same byte path with notation.
- **`Binary` chunks lifted as literals.** Lifting a `ByteArray` literal copies it (`copyOf` on lift) and inlines
  it into snapshots and traces; wrong for anything file-sized.

## 11. Consequences if accepted

- **kzen-lib** — `ScalarKind.Content`; `ValueAccess` gains a content accessor returning a handle, not bytes;
  snapshot policy treats `Content` as descriptor-only; `SequentialByteContent` (or its minimal equivalent)
  becomes a common-code interface so `Content` is expressible without JVM types.
- **kzen-auto-common** — `Content`, `ContentDescriptor`, `ContentAccess`, `Entry`, `SpoolPolicy`;
  `DataPart.content` alongside the ref it addresses; `ContentCodingSpec` unchanged, its registry bidirectional.
- **kzen-auto-plugin** — `ContentCodec` and `ContainerFormat` as SPI capabilities; `Entry` and `Content`
  reachable from a plugin Worker without server types.
- **kzen-auto-jvm** — codec and container registries (tar and zip over commons-compress, which is already on
  the classpath; gzip encode over the existing parallel-block writer); the four Workers; provider-backed durable
  `Content` in `DataContentProvider`; opener chain reads `part.content`; ledger gains the handoff lease and the
  transient-retention refusal; validation gains the positional fan-out rule; the card layer gains the content
  badge and the "sequential: one entry in flight" marker.
- **Existing Workers** — unchanged in code; `Filter`, `Formula`, `ReadPart`, `ResultSink`, `Preview`, `Run`
  compose with entry lanes by the rules above. `ExportWriter` and `CsvWriter` gain nothing and lose nothing; a
  later step may make `ExportWriter` a `ContentWriter` over a formatted content, which is the direction the
  symmetry points.
- **Report** — untouched. The parallel gzip encoder is shared, as it already is with `ExportWriter`.

## 12. Acceptance

- **Bounded RAM.** A synthetic 10 GiB tar.gz of ten thousand entries, filtered to half, written as `.gz` under a
  256 MiB heap cap, with the pipe on and off. Peak heap is flat across archive sizes.
- **No redundant copy.** Bytes read from the provider equal the archive size; bytes written equal the sum of the
  encoded outputs; no scratch file is created unless a `Spool` is in the graph.
- **Byte identity.** Each output decompresses to the entry `tar xzf` produces; each `.gz` is byte-identical to
  Report's `compression: gz` over the same bytes.
- **Ownership.** One open and one close per selected entry; zero opens for skipped entries; the cursor closes
  exactly once on completion, failure, cancellation and rejected migration; close-counting wrappers at every
  layer.
- **Semantics.** `Sort` after `ContainerSource` fails by name at validation; with `Spool` between them it runs.
  Fan-out over a positional lane fails at validation; over `Spool` it runs. `Filter` rejecting every entry
  produces no output files and no handoff waits.
- **Composition.** `ReadPart` over a CSV entry in a tar.gz yields the same rows and the same `DataContract` as
  `ReadPart` over the extracted file. `Entries` over `FileSource(emit: units)` processes a directory of archives.
- **Live edit.** Editing `entries:` mid-run continues from the next entry without re-reading; the finalized
  outputs before the edit are untouched.
- **Access class.** `zip` on a local file yields durable entries and a working design-time listing; `zip.gz`
  yields transient entries and no listing.

## 13. Open questions

1. Should `Content` be a scalar kind in kzen-lib, or a kzen-auto native type with a declared contract? The
   scalar kind is proposed because a Script parameter or Flow port typed `Content` should be checkable without
   kzen-auto's value registry; the cost is one accessor on `ValueAccess` whose only common-code obligation is
   "a handle with read and close".
2. Directory as an indexed container: does `FileSource(emit: units)` become `ContainerSource(container:
   directory)`? The model says yes; whether the notation should is a naming question.
3. Default for `content.pipe`: on (throughput) or off (fewer threads, simpler traces)? Proposed on, with the
   block count visible in the run's ownership report.
4. Whether `ContentWriter`'s `name` pattern should accept a Kotlin expression (`name.replace('/', '_')`) in
   addition to `${…}` substitution, given `Formula` can rewrite `name` upstream at no cost.
