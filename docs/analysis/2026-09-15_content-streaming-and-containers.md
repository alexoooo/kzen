# Content streaming and containers: files as first-class Job elements

> **Status: proposed, ready for a spike** (§14). Reviewed three times on 2026-09-15; every amendment is
> folded in, the review files are retired, and the revision history is in Appendix A. Drawing-board design, written without regard to implementation cost or
> compatibility with the landed Worker set; where it coincides with what exists (`DataRef`, `DataPart`,
> `ContentCodingSpec`, `SequentialByteContent`, the E9 ownership ledger, `RunWorker`, `ReadPartWorker`) that is
> noted. Builds on [data reading](2026-08-29_data-reading.md), the
> [unified data model](2026-08-27_data-model.md) and the [Job data source](2026-08-20_job-data-source.md)
> analysis.

## 1. Decision in one page

**A file is a value.** Introduce `Content` — a finite, sequentially readable byte content with a descriptor and
a declared lifetime — as a declared native capability in the data model (a scalar kind in kzen-lib's type
language is deferred until its ownership, snapshot and expression semantics are proven, §13.1). An archive
entry, a file on disk, an object in a bucket, an HTTP body and a spooled copy are all `Content`. A Job element
that represents a file is an ordinary record whose fields are the file's metadata plus one `Content` field:

```text
Entry { name: Text, size: Integer?, modified: Timestamp?, content: Content }
```

**Containers yield entries; codings transform bytes.** A container (tar, zip) is content that holds named
entries; a directory or object-store prefix is an entry source that is not itself content. A coding (gzip,
zstd) is a transparent byte-to-byte transform and is bidirectional — the same registry entry decodes on read
and encodes on write. `foo.tar.gz` is `container: tar` over `coding: gzip`, never "two codings". What a cursor
can do with its entries is **negotiated at open** from the format, the source's capabilities and the decoding
chain (§5.2), and yields one of three lifetime classes for the entries (§4.2).

**Cursor-borrowed content is scoped, not streamed across channels.** An entry from a sequential container
(tar, streaming zip) is valid only while the cursor is positioned on it. Rather than teaching every channel a
completion-acknowledged transfer, the design borrows the entry for the lifetime of a **body**: an
`EntryScope` Worker pulls one entry, runs its body over it inline, and advances only when the body has
finished. Nothing leaves the scope except values that are independent of the entry by contract, or content
that was explicitly materialized (`Spool`) or published (`ContentWriter`). The scope boundary is the single
validation point (§6). For the streaming pipeline (source → filter → write, or source → reader → independent
rows) bounded RAM and no whole-entry materialization follow by construction, and the user configures nothing.
The scope bounds the *borrowed content's* lifetime; it does not bound a downstream `Sort`, a collected result
or arbitrary Worker state, which remain governed by their own budgets.

**The flat notation stays.** `ContainerSource → Filter → ContentWriter` remains the authoring model. Over an
indexed container (local zip, directory) entries are reopenable and the graph runs as an ordinary Job. Over a
sequential container the compiler folds the downstream linear segment into the scope body up to the first
output that is independent of the borrowed entry (a metadata projection, a spool, a published file), and
validation rejects a graph it cannot fold with a message naming the `Spool` that would make it legal. Only Workers that declare the scope-compatible contract (§6.2) can be folded; the fold is
decided statically wherever borrowed entries are *possible*, because scoping is always correct and only
sometimes unnecessary (§6.5). Scoped execution internally, flat notation externally.

**Chunking is transport, never an element.** Chunked byte records leak transport into notation and make every
generic Worker wrong or meaningless over the lane. A bounded pipe of blocks may exist *inside* a content
handle to overlap inflate with deflate across threads; it is off by default until measured (§6.6).

The motivating task — read `data.tar.gz`, keep `*.txt`, write each as `C:/out/<name>.gz` — is two notation
objects with no code:

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

- **No whole-entry materialization and no redundant full pass.** The bytes of an entry are inflated once and
  deflated once. No entry is written to RAM or scratch in full on the way through, and the archive is read
  once. (Bounded, constant-size internal buffers — a decoder's window, an encoder's block, a pipe — are not
  what this constraint is about; "zero copies" would over-promise.)
- **Bounded RAM.** Memory use is a function of buffer sizes and Job-wide budgets, not of entry size, entry
  count or archive size.
- **Efficient.** The unavoidable work is one inflate pass over the whole archive (tar has no index; every entry
  must be inflated to reach the next) and one deflate pass over the selected bytes.

### 2.2 What is actually missing

The Job paradigm is record-centric: a channel carries a `DataValue`, Workers project columns or bind natives, a
sink writes rows. Nothing in it says "this element *is a file*". Three specific gaps:

1. **No value kind for streamed bytes.** `Binary` is a `ByteArray` — bounded, copied on lift, inlined into
   snapshots. A file-sized content cannot be a `Binary`. A `DataRef` is an *address* of persistently
   addressable content, which an entry positioned inside a single-pass stream does not have.
2. **No notion of a container whose entries are only reachable in order.** The data-source model assumes a
   manifest is resolvable up front and each `DataPart` is independently openable ([data reading
   §4.2](2026-08-29_data-reading.md#42-content-access-resolves-refs-to-capabilities)). A tar.gz satisfies
   neither: enumerating it is a full pass, and opening entry *k* independently is a re-scan of entries 1..k.
   That analysis flagged ZIP as a container and deferred an "archive source"; tar makes the sequential case
   unavoidable.
3. **No lifetime discipline for a value that is only valid until its producer advances.** The E9 ownership
   ledger knows *who holds* a native and closes it after the last release; it does not stop the producer from
   pulling the next item while the current one is still being read, and with channel capacity or batch size
   above one a lazy tar-entry stream is invalidated before it is consumed. Borrowed content is a first-class
   execution concern with consequences for ownership propagation, validation, migration and serialization —
   not "one channel rule".

### 2.3 Why this is worth a bigger change

The tar.gz task is the first instance of a class: files as elements. The same model covers a directory of
archives, an object-store listing, an HTTP download, "unzip these and re-compress those", "parse the CSV inside
this tarball", "tar up the outputs of a Job", and a Script step that hands a file to a Job. Solving the instance
with a purpose-built pair of chunk Workers leaves every one of those as a fresh special case.

## 3. Design principles

- **The user's unit is the file.** Whatever crosses a channel in this feature is an entry: one element per
  file, with metadata the user can filter on and content the user can hand to a reader or a writer. Transport
  concerns never surface in notation, cards or expressions.
- **One content model on both sides.** Reading and writing use the same `Content` value and the same coding
  registry. A writer is the dual of a source.
- **Lifetime is structural.** A borrowed entry lives exactly as long as the scope that borrowed it. That is a
  boundary the compiler can see and validation can check, rather than a protocol every channel must honour.
- **Cost is explicit; safety is automatic.** Anything that costs memory or disk in proportion to data size
  (spooling, collecting) is a visible notation object, under a Job-wide budget. Anything that would be
  *incorrect* without care (retaining a borrowed entry) is rejected statically where provable and at run time
  otherwise.
- **Capabilities are negotiated, not declared by the Worker.** What a cursor can do with its entries follows
  from the format, the source and the decoding chain, is recorded in the resolved spec, and is shown on the
  card.
- **Serialized descriptions and runtime handles are different types.** Nothing that is persisted or digested
  carries a live stream. Live-edit migration has two distinct mechanisms and they are named separately:
  *serialized migration state* (specs, counters, configuration keys) never carries a stream; *in-process
  resource adoption* (`captureMigrationState` / `loadMigrationState` handing a detached cursor to the
  replacement instance) transfers live resources by design, inside one JVM, and never crosses a
  serialization boundary.

## 4. The `Content` value

### 4.1 Type

`Content` is a declared native capability in kzen-auto's data model: a record contract may carry a field of
type `Content`, the value registry lifts and describes it, snapshot policy treats it as descriptor-only, and
expressions see it as an opaque object with a descriptor and an `open()`. It is never inlined into a snapshot
or a trace, may be larger than memory, and is read through a handle the ownership ledger closes. A field of
type `Content` renders on a card as a content badge (name, size, coding, lifetime class) rather than a value.
Promotion to a kzen-lib scalar kind is an open question (§13.1), taken once ownership, snapshot and expression
semantics have been proven on the native form.

### 4.2 Lifetime classes and capabilities

```kotlin
interface Content {
    val descriptor: ContentDescriptor      // name, length?, modified?, mediaTypeHint?, codingHint?, fingerprint?
    val lifetime: ContentLifetime          // CursorBorrowed | SingleUse | Reopenable
    val reference: DataRef?                // present when persistently addressable by another run
    val capabilities: Set<ContentCapability>   // e.g. Seekable; open-ended, only declared with a consumer
    fun open(): SequentialByteContent      // provider-neutral read(buffer, offset, length): Int + close
}
```

Three lifetime classes, deliberately not six orthogonal flags:

| Lifetime | Survives cursor advance | Reopenable | Concurrent opens | Examples |
|---|---|---|---|---|
| **CursorBorrowed** | no | no | no | tar entry, streaming-zip entry, entry behind a non-seekable coding |
| **SingleUse** | yes | no | no | HTTP body, stdin, a decoded stream over a single-use source |
| **Reopenable** | yes | yes | yes | local file, object-store object, indexed-zip entry, a spool |

Persistent addressability is a separate property: `reference` is non-null when another run can resolve the
content (a local file, an object, a published output). A spool is `Reopenable` within its Job and has no
`reference`; its lifetime and cleanup owner is the run's scratch scope. Review 1's other questions are
answered as follows: *consistency* is the existing expected-versus-observed fingerprint handshake on open
([data reading §5.2](2026-08-29_data-reading.md#52-content-fingerprint-and-read-spec-fingerprint-are-different-identities));
*seekability* is an optional capability, and its one consumer today is container negotiation (§5.2: zip
negotiates `Indexed` only over a `Seekable` source).

> Persistently addressable content exposes a reference; other content can be explicitly published
> (`ContentWriter`) to obtain one.

**Lifetime and ownership are distinct.** Every `Content` has an owner in the ledger regardless of class: a
`Reopenable` indexed-zip entry holds a named lease on the shared archive native (§5.2), a `SingleUse` HTTP
body is owned by whoever acquired it, a `CursorBorrowed` entry is owned by its scope. *Reopenable* says the
bytes can be read again while the owner keeps it open; it does not say the content outlives its owner.

**Retention rules by class.** `CursorBorrowed` content cannot become a `DataRef` and cannot be retained past
its scope; it must be consumed within the scope, spooled, or published. `SingleUse` content *could* be
retained by exclusive ownership transfer (one consumer, later), since single-use limits the number of reads,
not the lifetime; **v1 nevertheless rejects `retain` on `SingleUse`** as a deliberate restriction that keeps
the retention check to one rule ("only `Reopenable` may be retained"), not as an inherent consequence of the
class. `Reopenable` content may be retained and buffered freely under the ledger.

A borrowed entry's descriptor is available **to the extent the format supplies it** before the bytes are read:
a tar header carries name, size and modified; streaming zip may not know the size until the entry has been
read (§5.2). Filtering and routing on the fields that are present never touch the stream.

`SequentialByteContent` already has this signature in kzen-auto-jvm; it moves to the common data model (its
contract has no JVM types) so that `Content` is expressible in `commonMain` and in the plugin SPI.

### 4.3 Specification, runtime part, snapshot

Three distinct types, because today's `DataPart` is serializable and digestible and a borrowed stream cannot
round-trip through it:

| Type | Carries | Where it lives |
|---|---|---|
| **Part specification** (`DataPart`, unchanged) | role, `DataRef`, expected fingerprint, resolved read spec | manifests, migration state, digests |
| **Readable part** (`ReadablePart`, new) | role, acquired `Content`, resolved read spec | runtime only; what the opener chain consumes |
| **Content snapshot** (`ContentDescriptor` + lifetime + `reference?`) | descriptive information; replayable only when `reference` is set | traces, previews, results |

A `DataPart` becomes a `ReadablePart` by acquiring its ref through the content-provider lookup; a container
cursor produces `ReadablePart`s directly. The opener chain (coding → character decoder → configured reader)
takes a `ReadablePart`, so `ReadPart` and every configured reader work over archive entries with no change to
their own logic. **Inspection must not consume the only open:** the schema-superset path that inspects parts
before opening them is valid over `Reopenable` content only; over `CursorBorrowed` or `SingleUse` content the
reader must use a declared schema, a bounded replay buffer at the head of the stream, or inspect within the
same reader session. Validation reports which of these applies.

### 4.4 Where `Content` appears

- **`Entry` records** — the element shape emitted by container Workers (§5.3).
- **`ReadablePart.content`** — what the readers open (§4.3).
- **Job parameters and results** — a Job may declare a parameter of type `Content`; a result of type `Content`
  **must carry a `reference`** (a borrowed, single-use or spooled content is refused by `yieldResult` exactly
  as an owned native is today). This is the v1 rule: a spool that should be a result is published through
  `ContentWriter` first. Letting a reference-free spool escape under a longer-lived scratch scope is a later
  capability (§13.5), not a v1 exception.
- **Snapshots, traces and previews** — always the snapshot form. A `Preview` over an entry lane shows name,
  size and lifetime; a byte-level peek is a separate, explicitly bounded action.

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
    val preservesSeek: Boolean                             // false for every stream codec today
}
```

Plugins register codecs by inheritance capability, the same way readers are discovered. The chain type stays a
list, and the validated depth stays what real cases need. The encoder side carries the parallel-block gzip that
Report's export already uses, so `ContentWriter` with `coding: gzip` produces the same bytes as a Report export
with `compression: gz`.

### 5.2 Container capabilities are negotiated at open

```kotlin
interface ContainerFormat {
    val identity: String                                   // "tar", "zip"
    fun sniff(head: ByteArray, descriptor: ContentDescriptor): Boolean
    fun negotiate(source: Content, codings: List<ContentCodingSpec>): ContainerAccess
    fun openEntries(content: Content, access: ContainerAccess, selection: EntrySelection, control): EntryCursor
}

sealed interface ContainerAccess {
    data class Indexed(val entryLifetime = Reopenable): ContainerAccess     // central directory / listing available
    data class Streaming(val limitations: Set<StreamingLimitation>): ContainerAccess  // entries CursorBorrowed
    data class Unsupported(val reason: String): ContainerAccess
}

interface EntryCursor: Iterator<Entry>, AutoCloseable
```

`negotiate` combines the format with what the source and codings allow:

```text
format + source capabilities (Reopenable? Seekable?) + decoding chain (preservesSeek?) → ContainerAccess
```

- **tar** always negotiates `Streaming` (there is no index). Its entries are `CursorBorrowed`.
- **zip** over a `Reopenable` + `Seekable` source with no stream coding negotiates `Indexed`: the central
  directory is read, entries are `Reopenable`, and the same format backs a `DataSource` so design-time
  browsing, part pickers and `ReadWorker` work over it. **An indexed entry's owner is the archive.** Each
  entry handle takes a named lease on the shared archive native in the ledger (holds are keyed by native
  identity with named leases today); the archive closes after the cursor *and* the last entry lease release,
  so an entry buffered in a channel or retained by a later consumer stays readable after the listing cursor
  has advanced or finished. It does not survive the run: the same rule as any owned native. Re-opening the
  archive independently per entry is not used, since it would need its own identity check and would
  multiply file handles. **zip** behind a stream coding (`foo.zip.gz`) or a
  non-seekable source negotiates `Streaming` **with documented limitations** — Commons Compress's streaming
  ZIP differs from indexed ZIP in central-directory membership, duplicate names, missing metadata and
  initially unknown sizes ([Commons Compress ZIP](https://commons.apache.org/proper/commons-compress/zip)).
  The design does not promise that streaming ZIP is "indexed ZIP with slower access". The Worker's
  `access:` attribute chooses among `streaming` (accept the limitations, listed on the card), `spool`
  (materialize the archive to scratch, then index it — cost visible, under budget) or `strict` (reject
  `Unsupported`/`Streaming` for this format). Default `streaming` for tar (its only option), `strict` for zip.
- A **directory** or an object-store prefix is an *entry source*, not content: it implements `EntryCursor`
  over a listing, with `Reopenable` entries, and is what `FileSource(emit: units)` already is in spirit. It is
  not forced into `Content`.

The negotiated access is recorded in the Worker's resolved spec and digest, following the data-reading rule:
hints (extension, media type, magic bytes) propose, the resolved spec decides, and a renamed file cannot
silently change interpretation across a migration.

### 5.3 The `Entry` element

```text
Entry {
  name: Text                 // path inside the container, forward slashes, normalized (§7.1)
  size: Integer?             // from the header when known; null under streaming-zip limitations
  modified: Timestamp?
  kind: Text                 // "file" | "directory" | "symlink" — directories and links are emitted only on request
  content: Content
  parent: ContentDescriptor  // the container this entry came from (name, length?, reference?) — never its content
  attributes: Map<Text, Text>   // container-specific metadata (mode, owner, comment) — present, never load-bearing
}
```

`parent` is how `Entries` preserves input context: it is the descriptor of the archive the entry was read
from, set by `ContainerSource` (the `path`) and `Entries` (the input element's `Content` descriptor) alike,
so `${parent.name}` in a writer template works for both. It is a descriptor, not a `Content`, so an `Entry`
never carries a second borrowed handle and nesting (`Entries` over `Entries`) chains descriptors, not
streams.

`Entry` is a record with a declared contract, so the design-time payload walk shows its fields, `Filter` and
`Formula` bind them by name, and a Worker written in Kotlin sees a plain object.

## 6. Scoped execution for borrowed content

This section replaces the earlier per-channel "handoff lease". That rule, applied literally, deadlocks: holds
are keyed by native identity, a Formula output inherits its input's owners and so shares the native, and a
send that waits for every hold on the native waits for the Formula's own callback hold, which cannot release
until the send returns. The invariant it wanted is still the right one — *the cursor cannot advance while
anything downstream still depends on its current entry* — and it is enforced structurally instead.

### 6.1 `EntryScope`: borrow one entry for the lifetime of a body

An `EntryScope` is a Worker that owns both the cursor and a body:

```text
EntryScope(cursor, body):
  for entry in cursor:                     # pull happens here, and only here
      run body over entry, inline          # body sees exactly one element; borrowed until body completes
      release entry                        # cursor may now advance
```

- The body is a hosted linear segment of Workers (the same hosting `RunWorker` uses through `control.host`),
  run inline on the scope's frame with a single element as its source. It is **not** a full child `JobRun`
  per entry: a Job of a million small entries must not pay a run build, a trace root and a progress spine per
  entry. The body is compiled once, instantiated once, and re-entered per entry with the entry as its input;
  its Workers' `onStart` / `onComplete` are per scope, not per entry (an "end of entry" boundary is delivered
  as a distinct callback for Workers that need it, e.g. a writer finalizing its file).
- The entry's lifecycle is explicit:

  ```text
  offered → opened? → consumed | closed-early | discarded → released → cursor advances
                                          ↘ aborted (cancellation / failure) → cursor closed
  ```

  *offered*: header read, `Entry` constructed, no bytes read. *opened*: the body called `content.open()`
  (at most once). *consumed*: the body read to end. *closed-early*: the body closed the handle with bytes
  remaining — the entry view is invalidated and the cursor skips the rest before advancing (over tar.gz that
  is inflate-and-discard, unavoidable but cheaper than deflate). *discarded*: the body finished without
  opening, or a `Filter` rejected it — the cursor skips the bytes. *released*: the end-of-entry callback has
  run on every body Worker, every task the body registered against the entry has been joined or cancelled,
  and every ledger hold on the entry other than the scope's own authority hold is gone. Only then does the
  cursor advance. A callback returning is *not* release: a retained buffer or a background task still using
  the entry keeps the scope from advancing.
- **Normal early close is not cancellation.** *Cancellation or failure* aborts: the entry view is closed,
  blocked reads (including a pipe's reader thread) are interrupted, and the cursor and archive are closed
  without draining the remaining bytes of the entry or the archive. A body failure aborts the entry and fails
  the scope. Closing an entry view during normal iteration never closes the parent archive; abort always can.
- Because pull and body are one Worker, no channel sits between the cursor and the first consumer, so no
  channel capacity can pull ahead. Ordinary channel semantics are untouched; the scope itself, its
  end-of-entry boundary, the fold pass and the migration coordination (§6.7) are a substantial execution
  feature.

### 6.2 Scope-compatible Workers: an explicit contract

Being linear is not enough to fold a Worker into a scope. Re-entering a compiled Worker per entry must
preserve its observable behaviour, and `Archive → Take(10) → Write` shows the ambiguity: does `Take` stop
after ten archive entries, or ten per entry? The answer is fixed by a contract every foldable Worker declares:

- **The body is one continuous stream, gated per entry.** A Worker inside the scope sees the same sequence
  of elements it would see outside it, one entry at a time. `Take(10)` counts archive entries. `onStart` and
  `onComplete` are per scope; counters, running totals and any other *scalar* state survive the entry boundary.
- **One lifetime rule for entry-dependent state.** Entry-dependent state — the entry, its content handle, any
  value derived from the bytes — may survive a callback's return only in two places: a **scope-owned buffer**
  (a per-entry buffer the Worker declares to the scope, flushed at `onEntryEnd`) or a **registered task** (a
  thread or coroutine the Worker registered with the scope, joined or cancelled at release). All such state is
  gone before the entry boundary completes. Outside those two places, a Worker retains nothing entry-dependent
  after `onElement` returns except in an output that is independent by contract (§6.3). This is the same
  discipline `JavaTransformWorker.independentOutputs()` expresses today, made a declared capability.
- **End of entry is not end of input.** The scope delivers an `onEntryEnd` callback before release. A Worker
  that buffers per entry (a writer finalizing its file, a reader closing its parser) flushes and drops its
  scope-owned buffers there; `onComplete` still means end of the whole input. Batching inside the body never
  spans an entry: a batch is flushed at `onEntryEnd`.
- **Task registration is a trusted obligation.** The ledger sees holds, not references: it detects a tracked
  hold that outlives release, but it cannot discover a raw reference captured by plugin code. So registration
  is a Worker obligation, not a runtime-enforced one, and the runtime adds the check it *can* make: every
  borrowed handle is **invalidated at release**, so a later `open()` or `read()` from a straggling task fails
  by name (*"entry 'foo.txt' of 'Archive' was released"*) rather than reading the next entry's bytes.
- **Early termination inside the body propagates to the cursor.** A body Worker that completes early (`Take`
  reaching its count, a `Filter` with `until:`) completes the scope: the current entry is closed-early,
  downstream Workers in the body receive `onComplete`, and the cursor is closed without reading further.
- **Downstream completion propagates upstream immediately.** Completion from *outside* the scope — a consumer
  of the scope's output finishing, as in `Archive → ReadPart → Take(10)` after ten rows — does **not** wait
  for an entry boundary: waiting would block the scope's next send on a closed channel or silently discard
  the rest of a huge entry. The scope aborts its active entry and closes the cursor without draining, exactly
  as cancellation does (§6.1). An entry whose output was in flight (a `ContentWriter` halfway through its
  eleventh file) is aborted, its temporary removed, nothing published. This differs from migration (§6.7),
  which waits for a boundary because work continues afterwards — and it means the engine's signal to the scope
  must distinguish *downstream closed* from *downstream paused*.

**Conservative default.** Only Workers that declare the contract are folded. In v1 that set is `Filter`,
`Formula`, `PathProjection` and the column projections, `Take`, `ReadPart`, `Entries`, `Spool` and
`ContentWriter`. Any other Worker on a borrowed lane is rejected at validation by name, with the same message
as an accumulator: insert a `Spool` or project the fields you need. This replaces classifying arbitrary
Workers: the compiler never has to decide whether an undeclared Worker happens to be safe.

### 6.3 What may leave the scope

The scope boundary is the single validation point. A value produced inside the body may cross it if and only
if one of the following holds:

1. **Independent by contract and by ownership.** Its declared contract contains no `Content` field and no
   opaque native, **and** the value owns its data: it is backed by lifted literal storage, or by immutable
   storage whose lifetime does not depend on the entry. Shape alone is not enough — a `DataValue` is a
   read-only *view* over an access and a root node, not owned storage, so a record whose fields are all
   scalar could still be a view over a reader's reusable row buffer and observe later mutations. A literal
   lift copies (that is why `Binary` copies on lift); a native-backed view is an opaque native and inherits.
   So the classification is: lifted literal with an independent contract → independent; anything
   native-backed → inherited unless the Worker's output declaration promises ownership (`independentOutputs()`
   is that promise today, and stays the explicit escape). A metadata projection `{name, size}`, a summary,
   parsed CSV rows lifted from the reader, a `Written` record — all cross freely, so `Archive → project
   {name, size} → Sort → Result` validates and runs with no spool. This refines the ledger's conservative
   `inherit` ("a derived non-scalar value gets all its parent's owners") exactly at the lifted-literal case.
2. **Materialized.** A `Spool` converted the content to `Reopenable` under the Job's budget (§6.4).
3. **Published.** A `ContentWriter` wrote it and emitted a `Written` record with a `reference` (§7).

Anything else — a `Sort`, a `ResultSink`, a fan-out, a `Pivot` over a lane still carrying borrowed content —
fails at validation by name: *"Sort retains 'Archive' entries past their scope; the entry content is
cursor-borrowed (tar). Insert a Spool, or project the fields you need."*

**Which uncertain outputs are admitted, and which rejected.** The compiler and the runtime guard divide the
untyped cases as follows. An output whose contract the payload walk *can* type (every projection, every
reader, a `Formula` whose expression the walk types) is classified statically and either crosses or is
rejected before execution. An output the walk *cannot* type — a `Formula` returning a native expression
result, a plugin Worker without a declared contract — is **admitted as inherited**: it stays inside the scope
and may flow to a scope-compatible consumer, but it may not cross the boundary to a retaining Worker; that
combination is rejected before execution like any other borrowed lane. The runtime `retain` guard therefore
covers exactly one case: an admitted, inherited value reaching a `retain` call *inside* a scope-compatible
Worker's own callback (a plugin Worker that stashes what it was given). `retain` on a `CursorBorrowed` or
`SingleUse` value fails by name there. Nothing untyped is admitted past the scope boundary on the hope that
the guard catches it.

### 6.4 `Spool` and Job-wide budgets

```kotlin
fun Content.spool(control: JobControl): Content    // Reopenable, no reference, owned by the run's scratch scope
```

A `Spool` Worker exposes it in notation. A per-spool memory limit does not bound a retained collection —
thousands of small spools can all stay in RAM — so budgets are **Job-wide**: `main.budget.spoolMemory`,
`main.budget.scratch`, `main.budget.pipes`, `main.budget.encoderBuffers`, each with a default and each
enforced by the run, with the ownership report showing current use. A spool that would exceed the memory
budget spills to scratch; one that would exceed scratch fails the run by name. Spool cleanup is owned by the
run's scratch scope and happens at run end, or earlier when the last hold releases.

### 6.5 The flat notation compiles to scopes

Access is negotiated when content is *opened* (§5.2), and `Entries` over a stream of archives negotiates once
per archive, so the fold cannot depend on the negotiated result without recompiling the downstream graph
mid-run. The policy is therefore:

> **Compile a scope wherever borrowed entries are possible; runtime negotiation selects an
> already-validated execution mode.**

Scoping is always correct and only sometimes unnecessary: a scope over `Reopenable` entries processes them
one at a time through the body, which is slower than an ordinary buffered channel but never wrong. So the
compiler:

1. Treats every container Worker as scope-owning unless its access is **statically `Indexed`**: an explicit
   `container: zip` (no `auto`), `access: strict`, a `path` source (Reopenable and Seekable by construction)
   and no stream coding. Only that combination is compiled unscoped, and only there may channels buffer
   entries and fan-out be legal. `container: auto`, any `Entries` over mixed inputs, and any stream coding
   compile to a scope.
2. Walks downstream along the single open output, absorbing scope-compatible Workers (§6.2) into the body
   while the lane still carries the content or a value derived from it, and stops at the first Worker whose
   output is independent by contract, materialized, or published — that Worker is the last in the body, and
   its output is what leaves the scope onto an ordinary channel.
3. Rejects the graph if the walk meets a Worker that does not declare the contract, a fan-out, or an
   accumulator, naming the fix. Rejection is at validation, before any input is opened and before any
   output exists; there is no "earlier archives already produced output" case.

At run time the negotiated access then only picks the entry lifetime within the compiled scope (`Reopenable`
under `Indexed`, `CursorBorrowed` under `Streaming`) and lists the streaming limitations on the card. The
card marks the scope: *"sequential: entries processed one at a time through Write"*. Whether v1 should ship
with the unscoped indexed mode at all, or scope every container Worker and add the unscoped path later, is an
open question (§13.6).

`EntryScope` is also a first-class archetype with an explicit body for users who want the boundary visible in
notation (`select:` + nested Workers, mirroring `ForEachStep` in Script). The flat form is sugar over it.

### 6.6 Where chunks live

Overlap of inflate (cursor side) and deflate (writer side) across two threads is the one form of pipeline
parallelism a sequential archive admits. It needs a bounded buffer between the two, and that buffer is a copy —
one buffer's worth, constant. The design places it inside the borrowed content handle: `open()` may return a
pipe filled by a reader thread from the decode stack, with a fixed ring of blocks counted against
`budget.pipes`. Workers, notation and contracts never see it. **Default off** until measurement establishes
the throughput gain against the thread and budget cost; the switch is Job-wide. Whether the pipe is on or off
changes throughput, never semantics — the test that a concern is transport and belongs below the value
boundary. Block-parallel gzip on the write side is likewise inside the encoder.

### 6.7 Live edit at entry boundaries

Migration is at **entry boundaries**: a live edit that touches a scope is applied after the current entry's
body completes, and the current output is finished under its original configuration. One entry may be large
(a nested archive, a CSV expanding to millions of rows), so an edit may wait; the run reports *"applying edit
after entry 'big.csv'"* rather than pretending the wait is short. An edited `entries:` pattern applies from
the next entry onward — the cursor does not rewind. Mid-entry adoption (carrying cursor, entry dependency,
decoder, reader and pipe together, as `ExpandingTransformWorker` does for its active batch) is a separate
later capability, not assumed here.

**Downstream must keep draining.** Reporting the scope quiescent only between entries is not enough on its
own. In `Archive → ReadPart → Summary`, `ReadPart` is in the scope and sends independent rows out of it; if
`Summary` pauses for the edit while the scope is still finishing a large CSV entry, the bounded output channel
fills, the scope cannot reach its boundary, and the edit never applies. The rule:

> Every consumer downstream of an active scope keeps draining until that scope reaches its entry boundary;
> quiescence is taken upstream-first.

Concretely, the engine's quiescence pass asks scopes to reach a boundary before it asks their downstream
consumers to pause; a consumer whose upstream includes an active scope is held in a *draining* state, in
which it processes elements but does not yet checkpoint, until the scope reports its boundary. This is the
entry-boundary counterpart of the checkpoint-inside-expansion that `ExpandingTransformWorker` does today, and
it is the reason §6.1 calls the migration coordination an engine feature rather than a Worker detail.

**Cursor adoption has a compatibility condition, checked before anything is detached.** The cursor is a
closeable stream and is detached and adopted across the edit, never re-opened, following
`CursorSourceWorker`'s detach-and-adopt. A configuration key guards adoption: the key is the resolved source,
container format, decoding chain and access mode. The key of the *edited* notation is computed from the new
definition alone, so compatibility is validated **before** any resource is detached or closed. An edit that
changes only body Workers, `entries:` or the writer's attributes is compatible and adopts the open cursor. An
edit that changes the key is refused by name — *"Source selection changed. Start a new run to apply it."* —
and the running graph and its cursor are preserved: the run continues under the old notation. This is a
deliberate improvement over `CursorSourceWorker` today, which detaches first and discovers the mismatch in
`loadMigrationState`, where the only option left is to close the cursor and fail the instance; for a
single-pass source that turns a refused edit into a lost run.

## 7. Workers

| Worker | Role | Attributes | Emits |
|---|---|---|---|
| `ContainerSource` | Source (scope-owning when access is streaming) | `path` (or `content` expression), `container: auto / tar / zip`, `coding: auto / none / gzip / …`, `access: streaming / spool / strict`, `entries` (glob list), `kinds: files / all` | `Entry` |
| `Entries` | Expanding transform (same) | as above minus `path`; input is an element with a `Content` field (an `Entry`, a `ReadablePart`, a `DataRef` record) | `Entry` |
| `EntryScope` | Explicit scope with body | `select`, nested body Workers | whatever the body's last Worker emits, if it may leave the scope |
| `ContentWriter` | Transform (output optional) | `directory`, `name` (field interpolation only, default `"${name}${extension}"`), `coding`, `existing: fail / replace / skip`, `result` | `Written { name, ref: DataRef, size }` |
| `Spool` | Transform | none beyond the Job budget | same element, content now `Reopenable` |

- `ContainerSource` / `Entries` are one core with two entry points (the `ReadWorker` / `ReadPartWorker`
  precedent). `entries` is applied at the header, before an element exists, so a non-matching entry costs one
  skip. A `Filter` inside the scope is equally correct and is the way to filter on anything but the name.
  Nested `Entries` (an archive of archives) nests scopes.
- `ContentWriter` emits one `Written` record per entry rather than yielding one result, because the natural
  result of writing N files is N refs; `ResultSink keep: all` collects them outside the scope, which is the
  shape the Job data-source analysis assigned to J4. An unconnected output makes it a sink.
- `name:` is **simple field interpolation**, not an expression language: `${field}` substitutes a field of the
  input element (including nested fields such as `${parent.name}`), plus `${extension}` for the coding's
  suffix. Anything else — conditionals, string functions — is a `Formula` upstream inside the scope that
  rewrites `name`, at no cost. This is the distinction §13.4 defers: interpolation is v1, expressions are not.

### 7.1 Output semantics

- **Path containment.** An entry name is normalized (forward slashes, no `.`/`..` segments, no drive or root)
  and must resolve inside `directory`; a name that escapes fails by name (the zip-slip class). Absolute names
  and names with a leading `/` are rejected, not silently relativized.
- **Collisions.** Duplicate entry names within one archive, and case-only collisions on a case-insensitive
  filesystem, are governed by `existing:`; `fail` is the default, and the failure names both entries.
- **Publication.** The writer opens a temporary destination in the target directory, streams through the
  encoder, finalizes the encoder, closes, then publishes by **atomic move** (`ATOMIC_MOVE`, with
  `REPLACE_EXISTING` under `existing: replace`). **v1 requires the atomic operation**: a target directory
  whose filesystem cannot provide it fails at the first publication by name, naming the directory, rather
  than falling back to a weaker copy-then-delete whose interruption semantics would have to be specified
  separately. No extra byte copy is introduced. `Written` is emitted only after successful publication; a
  failure during encoder finalization leaves no published file and the temporary is removed. A failed
  `existing: replace` preserves the previously published destination, which the atomic replace gives
  directly. A partially written temporary from a cancelled or aborted run is removed by the run's teardown.

## 8. Worked notation

The motivating task:

```yaml
main:
  is: Job

  Archive:
    is: ContainerSource
    path: C:/in/data.tar.gz          # container: auto → tar; coding: auto → gzip; access → streaming
    entries: ["*.txt"]

  Write:
    is: ContentWriter
    directory: C:/out
    coding: gzip                     # name defaults to "${name}${extension}" → foo.txt.gz, baz.txt.gz
```

Compiles to: scope over `Archive`, body = `Write`; `Written` leaves the scope with nowhere to go, so the
writer acts as a sink.

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

Body = `Large`, `Write`; `Written` is independent by contract and crosses to `Manifest` on an ordinary channel.

Metadata only, sorted — no spool needed:

```yaml
  Archive:
    is: ContainerSource
    path: C:/in/data.tar.gz
  Names:
    is: PathProjection
    paths: [name, size]
  BySize:
    is: Sort
    by: size
```

Body = `Names`; its output has no `Content` field, so `BySize` runs outside the scope.

Parse a CSV entry straight out of the archive, never extracting it:

```yaml
  Archive:
    is: ContainerSource
    path: C:/in/data.tar.gz
    entries: ["bar.csv"]
  Rows:
    is: ReadPart                     # declared schema (SalesCsv), so no inspection open is needed
    format: SalesCsv
  Total:
    is: Summary
```

Body = `Rows`; scalar rows leave the scope; `Total` accumulates outside it.

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
    name: "${parent.name}/${name}${extension}"
    coding: gzip
```

`Archives` yields `Reopenable` units on an ordinary channel; each `Entries` open negotiates streaming and
scopes `Write`.

## 9. Is chunked writing the most ergonomic way? No.

Chunk elements `{name, offset, bytes, last}` are the *obvious* way to make a single-pass stream fit a buffered
channel, and they do satisfy the RAM constraint. They fail on ergonomics and on composition:

| | Chunk elements | Entry elements with `Content` in a scope |
|---|---|---|
| What the user sees on the card | a byte-slice record with a protocol flag | a file: name, size, content badge |
| One file is | N elements, with a `last` every consumer must honour | one element |
| `Filter` | sees N chunks per file; a mistake drops a file's tail | filters files |
| `Formula` / `Sort` / `Summary` / `Preview` | meaningless or corrupting over the lane | work on metadata; retention of bytes needs an explicit `Spool` |
| Tabular readers (`ReadPart`) | cannot consume it | parse the entry directly |
| A plugin Worker | must reassemble chunks by name and flag | receives a file |
| Materialization | none, but one copy per chunk in the user's model | none; a bounded pipe *may* exist below the value boundary |
| Vocabulary added | a chunk record type and a `last` convention | one value type, one element shape, one scope construct |

Chunking is the right *transport*: it is how bytes should cross a thread boundary. It is the wrong *element*.

## 10. Alternatives considered

- **Per-channel handoff lease (this document's first draft).** Send waits for every hold on the element; the
  lane becomes a rendezvous. Deadlocks under `Archive → Formula → Writer` because holds are per native and the
  Formula's own callback hold is among those waited for; and turns every channel into a potential
  completion-acknowledged transfer. A cursor-owned completion token would fix the deadlock but still spreads
  the lifetime discipline over every channel. Replaced by the structural scope (§6).
- **Tar as a `DataSource` with a manifest.** A tar manifest is a full pass and each independently opened part
  is a re-scan: O(n²) I/O. Kept for indexed containers, rejected for streaming ones.
- **Always spool entries to scratch.** Safe with any channel capacity; writes every selected byte to disk once
  before it is read again — the whole-entry materialization the constraints forbid. Retained as the explicit
  `Spool` and as `access: spool` for archives that need indexed access.
- **Lazy `InputStream` as an owned native under E9 alone.** Closes correctly but does not stop the producer
  advancing. Correct only with a rule the user must remember.
- **Full child `JobRun` per entry (`Entries → RunWorker`).** Gives the scope for free with today's machinery,
  but a channel still sits between `Entries` and `RunWorker` and pulls ahead by batch size, and a run build per
  entry is too heavy for many small entries. The inline body in §6.1 is this idea with the channel removed and
  the per-entry cost amortized.
- **A single Kotlin Script step.** The zero-copy minimum and a fine fallback for a one-off; composes with
  nothing.
- **`Binary` chunks lifted as literals.** Copied on lift and inlined into snapshots; wrong for anything
  file-sized.
- **Exposing every access property as an independent flag** (lifetime, repeatability, concurrency,
  seekability, persistence, consistency — the six questions review 1 said the guarantees must answer). Each
  is answered in §4.2, but as six independent flags on the type they would multiply the validation matrix
  with no consumer for most cells. Bounded to three lifetime classes, a separate `reference`, and an optional
  capability set, which is the shape review 1 itself recommended.
- **Classifying arbitrary Workers for scope folding.** Deciding from the payload walk alone whether an
  undeclared Worker is safe inside a scope cannot see retained buffers, batching or background tasks.
  Replaced by the declared scope-compatible contract (§6.2) with a conservative default.
- **Folding on negotiated access.** Would require recompiling the downstream graph per opened archive.
  Replaced by the static "scope wherever borrowed entries are possible" rule (§6.5).
- **Quiescing a scope mid-entry with a parked send.** The engine can carry an in-flight batch across a
  migration today, so a scope could report quiescent while parked on its outgoing send with the live entry
  detached. It would let an edit apply sooner, but the replacement body Worker would have to adopt a
  half-consumed entry and a half-written output — the mid-entry migration review 1 warned against. Replaced
  by the upstream-first drain rule (§6.7).

## 11. Consequences if accepted

- **kzen-auto-common** — `Content`, `ContentDescriptor`, `ContentLifetime`, `ContentCapability`, `Entry` (with `parent`),
  `ReadablePart`; `DataPart` unchanged; `ContentCodingSpec` unchanged, its registry bidirectional;
  `SequentialByteContent` moved here from kzen-auto-jvm.
- **kzen-auto-plugin** — `ContentCodec`, `ContainerFormat`, `ContainerAccess` as SPI capabilities; `Entry`
  and `Content` reachable from a plugin Worker without server types.
- **kzen-auto-jvm** — codec and container registries (tar and zip over commons-compress, already on the
  classpath; gzip encode over the existing parallel-block writer); `EntryScope` execution (inline hosted body,
  per-entry lifecycle with `onEntryEnd`, task registration and join, entry-boundary quiescence with
  upstream-first draining in the engine's quiescence pass, cursor configuration key); the scope-compatible
  Worker capability and its declaration on the v1 set; the static scope-folding compiler pass and its validation; the
  contract-based independence rule refining the ledger's `inherit`; Job-wide budgets in the run and the
  ownership report; the five Workers; the readers' inspection strategy over non-reopenable content; content
  badge and scope marker on cards.
- **Existing Workers** — user-facing behaviour is unchanged, but ownership propagation is not: `Formula`,
  `PathProjection` and the column projections gain contract-based independence; `Sort`, `Pivot`, `ResultSink`
  gain the static retention check; `ReadPart` takes a `ReadablePart` and gains the inspection strategy;
  `FileSource(emit: units)` shares the entry-source machinery but keeps its name and its non-content directory
  model.
- **kzen-lib** — nothing in v1. A `Content` scalar kind is deferred (§13.1).
- **Report** — untouched; the parallel gzip encoder is shared, as it already is with `ExportWriter`.

## 12. Acceptance

- **Bounded RAM.** A synthetic 10 GiB tar.gz of ten thousand entries, filtered to half, written as `.gz` under a
  256 MiB heap cap, pipe off and on. **Peak live memory** is flat across archive and entry sizes; allocation
  volume per entry is measured separately as a performance figure, not gated, since reading a large entry may
  legitimately allocate repeatedly while retaining constant memory.
- **No whole-entry materialization, no redundant full pass.** The archive is read once (provider byte count
  equals archive size); no scratch file is created unless a `Spool` or `access: spool` is in the graph.
- **Byte identity.** Each output decompresses to the entry `tar xzf` produces; each `.gz` is byte-identical to
  Report's `compression: gz` over the same bytes.
- **Ownership.** One open and one close per selected entry; zero opens for skipped entries; the cursor closes
  exactly once on completion, failure, cancellation and rejected migration; close-counting wrappers at every
  layer.
- **Scope semantics.** Forwarding through `Archive → Formula → Filter → Write` runs without deadlock.
  `Archive → PathProjection{name,size} → Sort` runs with no spool. `Archive → Sort` fails at validation by
  name; with `Spool` it runs. Fan-out inside a scope fails at validation; over `Spool` it runs. `Filter`
  rejecting every entry produces no output files and no opens. Nested `Entries` (tar of tars) nests scopes.
  An untyped Formula output on a borrowed lane feeding a retaining Worker is rejected before execution; an
  admitted inherited value that a scope-compatible plugin Worker tries to `retain` inside its callback fails
  by name at run time.
- **Scope-compatible contract.** `Archive → Take(10) → Write` writes exactly ten files and closes the cursor;
  no eleventh entry is delivered to the body or opened (the decoder may have read ahead into its own
  buffer, which is not an entry-semantics violation). `Archive → ReadPart → Take(10)` over a huge CSV entry
  completes promptly after ten rows: the scope aborts the entry and closes the cursor without draining, and
  the run does not block on the closed channel. `Archive → Write → Take(10)` publishes exactly ten files and
  leaves no temporary for the aborted eleventh. A Worker that does not declare the contract on a borrowed
  lane fails at validation by name. The violations the runtime can detect are named precisely: a tracked
  ledger hold on the entry that outlives release fails the scope before the cursor advances; a straggling
  task reading through a released handle fails by name at that `open()` / `read()`; a raw reference held
  without a ledger hold and never touched again is *not* detectable and is the Worker's obligation. Running
  totals in a folded Worker are per scope, not reset per entry.
- **Lifecycle edges.** Early close after a partial read invalidates the entry view, skips the rest of the
  entry and advances, without closing the archive; cancellation while a pipe is blocked interrupts the read,
  closes the entry view, then the cursor and archive, without draining, never leaking a thread; failure
  during encoder finalization publishes nothing and removes the temporary.
- **Mixed inputs.** `Entries` over a directory holding both a local zip and a tar.gz runs every archive
  through the same compiled scope; the zip's entries are `Reopenable` and the tar's `CursorBorrowed`, with the
  card showing each archive's negotiated access. The same graph followed by `Sort` on the entry lane fails at
  validation before any archive is opened.
- **Budgets.** Thousands of small retained spools are bounded by the Job-wide spool budget and spill to scratch;
  exceeding scratch fails by name.
- **Output semantics.** An entry named `../x` fails by name; duplicate and case-only collisions obey
  `existing:`. Every publication is an atomic move: no partially written file is ever visible under its final
  name, and a failed `existing: replace` leaves the previously published file intact. A target directory whose
  filesystem cannot provide atomic move fails at the first publication by name; there is no weaker fallback to
  test.
- **Composition.** `ReadPart` over a CSV entry in a tar.gz yields the same rows and the same `DataContract` as
  `ReadPart` over the extracted file, using a declared schema. `Entries` over `FileSource(emit: units)`
  processes a directory of archives.
- **Live edit.** An edit during a large entry is applied after that entry, with the wait reported; outputs
  finalized before the edit are untouched; the cursor is not re-opened. `Archive → ReadPart → Summary` with a
  large CSV entry, a bounded output channel and an edit that touches `Summary` reaches the entry boundary and
  applies the edit: `Summary` drains until the scope reports its boundary. An edit that changes `path`,
  `container`, `coding` or `access` is refused by name *before* anything is detached, and the run continues
  unchanged with its cursor intact: the entries after the refused edit are still delivered.
- **Access negotiation.** A local `zip` negotiates `Indexed` with a working design-time listing; `zip.gz`
  negotiates `Streaming` under `access: streaming` with its limitations listed on the card, spools under
  `access: spool`, and is rejected under `access: strict`.

## 13. Open questions

1. **When does `Content` become a kzen-lib scalar kind?** Start as a declared native capability in kzen-auto
   and establish ownership, snapshot and expression semantics first. Promote once a Script parameter or Flow
   port typed `Content` needs to be checkable without kzen-auto's value registry; the promotion is one accessor
   on `ValueAccess` whose only common-code obligation is "a handle with read and close".
2. **Inline body versus hosted child run.** §6.1 specifies an inline re-entered body to avoid per-entry run
   cost. Whether that is a new hosting mode in the engine or a specialization of `control.host` with a shared
   frame is an implementation question; the observable contract (one element per entry, per-scope
   `onStart`/`onComplete`, an end-of-entry callback) is fixed here.
3. **Pipe default.** Off. Turn on Job-wide once measurement shows the inflate/deflate overlap pays for its
   thread and budget cost on realistic archives.
4. **Name expressions in `ContentWriter`.** Simple `${field}` interpolation is v1 (§7); a general expression
   language in `name:` is not — `Formula` rewrites `name` upstream inside the scope at no cost. Revisit only
   with concrete authoring evidence.
5. **Scratch lifetime for spooled results.** v1 requires a result of type `Content` to carry a `reference`
   (§4.4). Whether a spool may later be a Job result when the Job is hosted (`RunWorker`, a Script step)
   depends on the caller's scratch scope outliving its use; that run-level policy is to be decided alongside
   the hosting-scratch rules, not per Worker.
6. **Ship the unscoped indexed mode in v1?** §6.5 keeps an unscoped path for statically `Indexed` containers
   so that fan-out and buffered channels over local-zip entries are legal. Scoping every container Worker in
   v1 would remove a whole execution mode from the first cut at the cost of serial processing over indexed
   archives; the design-time listing and `DataSource` path over zip is unaffected either way. Lean towards
   scoping everything first and adding the unscoped path when a fan-out case asks for it.
7. **Exclusive transfer of `SingleUse` content.** §4.2 rejects `retain` on `SingleUse` as a v1 restriction.
   A single-holder transfer through the ledger would let an HTTP body be handed to a later consumer without a
   spool; add it when a case needs it.

## 14. Next step: a spike, not more architecture

The architecture has been through three review rounds and the remaining risk is whether the lifecycle rules
work *together* in a running pipeline, which no further document revision can show. Before automatic scope
folding, the compiler pass, cards, budgets or the plugin SPI, build a small explicit implementation that
exercises the three hardest execution assumptions in order:

1. **Explicit `EntryScope` over tar.gz, with `Filter` and `ContentWriter`.** Exercises the inline re-entered
   body, the entry lifecycle (offered / opened / consumed / closed-early / discarded / released), handle
   invalidation at release, the ledger's refined `inherit`, atomic publication and byte identity with Report's
   gzip. The motivating task, end to end, with the scope written by hand in notation.
2. **`ReadPart` inside the scope with downstream early termination.** `Archive → ReadPart → Take(10)` over a
   large CSV entry. Exercises independent-by-ownership rows leaving the scope, `ReadablePart` over a borrowed
   entry with a declared schema, and downstream completion aborting the active entry without draining or
   blocking — including the engine distinguishing *downstream closed* from *downstream paused*.
3. **Migration under backpressure.** `Archive → ReadPart → Summary` with a bounded output channel and an edit
   to `Summary` during a large entry. Exercises upstream-first draining, entry-boundary quiescence, the
   configuration key validated before detach, and cursor adoption.

Each spike is judged against the corresponding rows of §12. If all three run, the flat-notation compiler
(§6.5) is a mechanical addition over a proven execution model; if one fails, the failure tells us which rule
in §6 is wrong before it has been generalized.

## Appendix A. Revision history

- **Draft** (2026-09-15). `Content` as a new scalar kind with `Durable | Transient` lifetime; a per-channel
  handoff lease ("send waits for every hold"); chunking rejected; existing Workers claimed unchanged.
- **Review 1** (2026-09-15). Lifetime bounded to three
  classes with persistent addressability separate (the review proposed the classes; its six properties were
  the questions to answer, not a type design); the handoff lease replaced by the structural `EntryScope`
  after the review showed it deadlocks; outputs shed borrowed content by contract; entry-boundary live edit;
  `DataPart` (serializable) split from `ReadablePart` (runtime); container access negotiated at open with
  streaming-zip limitations; output semantics, Job-wide budgets, expanded acceptance; "zero copies" reworded.
- **Review 2** (2026-09-15). Scope-compatible Worker
  contract with a conservative declared set (§6.2); static "scope wherever borrowed entries are possible"
  fold with negotiation selecting a validated mode (§6.5); upstream-first draining for migration and a cursor
  configuration key (§6.7); reopenable entries own a lease on the archive, `retain(SingleUse)` a v1
  restriction (§4.2, §5.2); early close distinguished from cancellation (§6.1); seekability's consumer named,
  descriptor completeness qualified, results must carry a reference, `name:` is interpolation only, peak live
  memory and split publication acceptance.
- **Review 3** (2026-09-15). Compatibility validated
  before detach so a refused edit preserves the run (§6.7); serialized migration state distinguished from
  in-process resource adoption (§3); downstream completion aborts immediately rather than waiting for a
  boundary (§6.2); one lifetime rule for entry-dependent state, task registration a trusted obligation,
  handles invalidated at release (§6.2); independence requires owned data, not just a scalar-shaped contract
  (§6.3); untyped outputs admitted-as-inherited versus rejected made explicit (§6.3); atomic move required in
  v1 with no fallback (§7.1); `Entry.parent` for input context (§5.3); memory claim scoped to the streaming
  pipeline (§1); `Take(10)` acceptance in terms of delivery, not inflation (§12); status set to "ready for a
  spike" with the spike order in §14.
