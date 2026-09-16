# Borrowed elements over flat Job pipelines — constituent plan (BE)

> **Status: open — written 2026-09-16.** Supersedes the content streaming spike plan
> (`2026-09-15_content-streaming-spike.md`, deleted the same day; it was never committed, so its as-builts are
> preserved in [Appendix A](#appendix-a-what-the-spike-built-and-found) here).
> Design authority: [content streaming and containers](../analysis/2026-09-15_content-streaming-and-containers.md)
> for `Content`, lifetimes, containers and output semantics (§4, §5, §7, §12). **This plan amends its §6**:
> the structural scope (§6.1–§6.3), the scope-compatible contract (§6.2), the flat-notation fold (§6.5) and
> the §10 rejection of a per-channel lease are replaced by the cursor-owned release protocol in §3 below.
> The [master ledger](2026-07-25_master-plan.md) owns sequencing (rows BE1–BE4).
> Executor: one session per row; each session appends its as-built under §8.

## 1. Decision

**There is one kind of data processor in a Job: the Worker. Borrowed content flows through ordinary
channels between ordinary Workers, and the *source that lent it* waits for every borrower to finish before it
advances.** No nested body, no `ScopeBodyWorker`, no scope-folding compiler, no second UI for placing steps.

Concretely:

- `EntryScope` (a Worker with a nested `body`) becomes `Entries`: a plain `CursorSourceWorker` over a tar.gz
  that emits `Entry` elements whose `content` is *borrowed* — valid until the cursor advances.
- The cursor advances only when the run's ownership ledger shows no hold on the current entry other than the
  source's own (*advance-on-release*). That is the whole ordering guarantee the nested body provided.
- `ScopeFilter`, `ScopeTake`, `ScopeReadPart`, `ContentWriter` collapse into the existing `FilterWorker`,
  `TakeWorker`, `ReadPartWorker` (taught to open a `Content` element) and a `Write` content sink.
- A Worker that would keep a borrowed element past its callback is refused by name at the point of retention,
  not discovered as a hang.
- The Job stage stays flat. The ribbon, gap picker, drag reorder and cards are unchanged; the body editor and
  the per-type display go away.

A user whose pipeline never borrows anything sees nothing new. A user reading a tar.gz writes
`Entries → Filter → Read part → Take → Summary` exactly as they would write `File → Filter → …`.

## 2. Why

**What the nested body actually bought.** A tar.gz is one sequential stream, so entry N+1 cannot open until
N is consumed and N's bytes are only valid until the cursor moves. The spike made that structural: everything
touching entry N ran to completion inside the scope, and the scope exit refused anything still referencing
the entry. That is the only property the body added. Resource *closing* — cancel-safe acquisition, one
close on completion / failure / cancel, run-end teardown — is already the ledger's job (`SourceIngress`,
`OpenedStream`, `RunOwnershipLedger`, `WorkerBase.onClose`) and every Worker gets it, ITCH reading included.

**What it cost.** A second Worker vocabulary with no channels, no cards, no progress, no ribbon placement
(the ribbon cannot insert into a body), duplicated `Filter` / `Take`, a bespoke body editor, a planned
compiler pass to fold flat notation into scopes with its own validation messages, `onEntryEnd` /
`captureState` / `loadState` lifecycle hooks, and a `DetachedScope` migration path parallel to
`CursorSourceWorker`'s.

**Why the flat protocol is safe where the analysis's first draft was not.** The analysis (§6 intro, §10)
rejected a *per-channel handoff lease* because a `send` that waits for every hold on the element waits for
the sending Worker's own callback hold, which cannot release until the send returns — a deadlock under
`Archive → Formula → Writer`. The protocol here never waits inside a send. Channels carry borrowed elements
exactly as they carry anything else (they already take a channel lease per element and hand it to the
consumer's per-callback hold — E9). Only the **cursor** waits, after its own flush, on *all other* holds of
the entry token clearing. A Formula's callback hold releases when its callback returns, which it does once its
send has been accepted; the derived value it sent inherits the entry's owners and is held by the next
Worker's callback in turn; the chain unwinds; the cursor advances. The analysis itself noted that "a
cursor-owned completion token would fix the deadlock"; the spike's `EntryRelease` token is that token, and
the ledger's `OwnedNative.holds()` is the wait condition the spike already checked — as a post-hoc assertion
rather than a wait.

**§6.2's `Take` ambiguity disappears.** Flat, `Entries → Take(10)` takes ten entries and
`Entries → Read part → Take(10)` takes ten rows; there is no fold to make "ten per entry" a possible reading.
A per-entry take is a *keyed* take, a generally useful transform and a separate item (§7).

## 3. Design

### 3.1 Borrowed element

A borrowed element is a `DataValue` whose ledger owners include an **entry token** (`EntryRelease` today: an
`AutoCloseable` whose `close()` invalidates the entry's `Content`, adopted under the source's holder). Values
derived from it by Workers inherit the owners (`RunOwnershipLedger.inherit`, as today), so "borrowed" follows
the data through Formula, Filter and any passthrough without per-Worker declarations. A value with no
owners — a lifted literal row out of `Read part`, a `Written` record, a snapshot — is independent and leaves
the borrowed regime for good. That is §6.3's independence-by-ownership rule applied at *every* channel
instead of at one scope exit, which the channel lease machinery already does.

### 3.2 Advance-on-release (the protocol)

For a source whose elements are `CursorBorrowed` (`ContentLifetime` on the element's `Content`):

1. Pull the next element under `runBlockingIo`; adopt its token; attach owners; emit.
2. **Flush immediately** — a borrowed element never waits in the emitter's batch buffer for siblings (the
   emitter forces batch 1 for owned-by-token elements; the channel's configured `batchSize` is for
   independent elements and is not a user concern here).
3. **Await release**: suspend until `owned.holds()` minus the source's own authority hold is empty. This is the
   spike's post-hoc check turned into the wait. It runs *outside* `checkpoint()` (draining, §3.5).
4. Release the token (invalidates the content), then `checkpoint()`, then advance the cursor.

Downstream close (`DownstreamClosedException`) received at step 2 ends the source without draining, as the
spike's `EntryScopeWorker` does; the token is still released in order.

**Throughput** is one entry in flight across the pipeline — exactly the spike's synchronous body. Workers
downstream of the borrowed element still run on their own coroutines, so `Read part → Summary` overlaps
reading with counting per batch of rows, as CS2 measured.

### 3.3 Retention is refused, not awaited

The wait in §3.2 step 3 must only ever wait on *callback* holds (which return) and *channel* holds (which
the consumer's callback converts and returns). Any longer hold would hang the source. So:

- `JobControl.retain(value)` on a value whose owners include an entry token **fails by name**: *"`<worker>`
  cannot keep entry '`<name>`': it is borrowed from `<source>` and is only valid until the next entry.
  Snapshot it, read it, or write it."* `Sort`, `Summary`-with-retention and any accumulator therefore fail at
  the first borrowed element, not as a deadlock 200 ms later.
- `yieldResult` already refuses owned natives (`EngineJobControl`); the message gains the same wording.
- A Worker that stashes the value *without* a lease and reads it later hits the invalidated content and fails
  naming the entry (CS1's handle-invalidation test, unchanged).
- The deadlock monitor treats a source suspended in *await release* as blocked like any parked send, so a
  hold the ledger cannot attribute (a bug, not a user error) still surfaces as the existing deadlock failure
  naming the holders (`describeLive`).

### 3.4 Channel policy

Nothing for the user to set. A channel carrying borrowed elements effectively runs at batch 1 because the
source flushes per element and waits; `capacity` is irrelevant for the same reason. The channel card's
`batchSize` / `capacity` keep meaning what they mean for independent elements downstream of `Read part`.

### 3.5 Quiescence and draining (CS3, kept)

`ScopeBoundary.insideEntry()` becomes `BorrowingSource.lending()` — true from emit until release. `JobRun`'s
per-Worker gate (`EngineJobControl.draining`) and `JobChannelTopology.upstreamWorkers` are unchanged in
substance: a Worker downstream of a lending source keeps draining instead of parking, and the source itself
never parks while lending. A pause therefore lands between entries, never inside one — the CS3 rule, with
the entry boundary now defined by the token's lifetime rather than by a body's return.

### 3.6 Migration (CS3, generalized)

`Entries` is a `CursorSourceWorker`, so it uses the standard `captureMigrationState` / `loadMigrationState`
(detach the `OpenedStream`, adopt it). `DetachedScope`, body state capture and `loadState` go. The pre-detach
refusal (`ScopeMigrationKey` → `JobLogic.refuseMigration`) becomes the general
`cursorConfigurationKey()` of every `CursorSourceWorker`, so `File` / `Read` sources also refuse a
path-changing edit *before* detaching (closing CS3's "inherited" item). `TarGzEntryCursor.reselect` stays
for an `entries:` edit applied from the next header.

### 3.7 Downstream close (CS2, completed)

Consumer-side close propagates through `TransformWorker` today. BE2 adds it to `SourceWorker`,
`CursorSourceWorker`, `ExpandingTransformWorker` and `SinkWorker` drive loops (CS2's inherited item), so a
`Take` downstream of *any* source ends the run cleanly rather than as a deadlock.

### 3.8 Workers after the change

| Spike | After | Notes |
|---|---|---|
| `EntryScope` (+ body) | `Entries` (`CursorSourceWorker`) | `path`, `entries` glob, `output`; emits `Entry`; Sources ribbon group |
| `ScopeFilter` | `FilterWorker` | already compiles a predicate over the element contract; `Entry` is a bean shape |
| `ScopeTake` | `TakeWorker` | already exists (CS2) |
| `ScopeReadPart` | `ReadPartWorker` | accepts a `Content`-bearing element (via `ContentDataOpener.openContent`) as well as a `DataPart`; declared schema; first entry fixes the shape |
| `ContentWriter` | `Write` (`TransformWorker`) | same `directory` / `name` / `coding` / `existing`, atomic publication, emits `Written` (independent); a Job whose last Worker is `Write` needs no sink |
| `ScopeBodyWorker`, `BodyEmitter`, `ScopeBoundary`, `DetachedScope`, `ScopeMigrationKey` | deleted / generalized per §3.5–3.6 | |

The `content/` substrate (`Content`, `ContentDescriptor`, `ContentLifetime`, `Entry`, `Written`,
`TarGzEntryCursor`, `TarEntryContent`, `EntryGlob`) stays as built.

### 3.9 UI

Deletions only: `ScopeBodyEditor`, `EntryScopeWorkerDisplay`, the `display:` line and `body` meta, the
`AddNameForm` picker. `EntriesTool` sits in Sources. Optional later polish: the pipe out of a lending source
could carry a small "per entry" annotation until the first independent Worker; not in this plan.

### 3.10 What stays out

The `Spool`, Job-wide budgets, `container: auto`, zip, `access:` negotiation, `Content` in the plugin SPI
(analysis §2 non-goals) — unchanged. A keyed `Take` (§2) is noted, not built.

## 4. Sessions

### BE1 — the protocol, `Entries`, `Write`

**Anchors.** `EntryScopeWorker.kt` (`deliver`, `leave`, the hold check), `CursorSourceWorker.kt`,
`SourceIngress.kt`, `OpenedStream.kt`, `RunOwnershipLedger.kt` / `OwnedNative.holds()`, `CallbackLeases.kt`,
`Emitter.kt`, `EngineJobControl.kt` (`retain`, `yieldResult`, `draining`), `JobRun.kt` (scope gating),
`JobDeadlockMonitor.kt`, `ContentWriter.kt`, `job-worker.yaml`, `EntryScopeWorkerTest.kt`,
`ContentScopeHarness.kt`, `TestBodies.kt`.

**Work.**

1. `BorrowingSource` (rename of `ScopeBoundary`; `lending()`), and in `CursorSourceWorker` the
   advance-on-release loop of §3.2 for elements whose `Content` is `CursorBorrowed`: adopt token → emit →
   forced flush → await release → release → checkpoint → advance. Reuse `EntryRelease` and the
   `#scope`-style authority holder.
2. `Entries` = `EntryScopeWorker` reduced to a `CursorSourceWorker` (`open` returns the `TarGzEntryCursor`;
   `elementContract` is the `Entry` contract; progress keys `entries / skipped / emitted / closed`).
3. Retention refusal (§3.3) in `EngineJobControl.retain` and the `yieldResult` wording; the deadlock monitor
   counts a source awaiting release as blocked.
4. `Write` = `ContentWriter` as a `TransformWorker` (`onElement` writes and emits `Written`); remove
   `onEntryEnd` / `captureState` / `loadState`.
5. `JobRun` gating keyed on `BorrowingSource`; `JobChannelTopology` unchanged.
6. Delete `ScopeBodyWorker`, `BodyEmitter`, `ScopeFilter`, `ScopeTake`, `DetachedScope`, the `body` attribute,
   `content-test-bodies.yaml`. Port the CS1 tests to flat notation (`Entries → Filter → Write`, and the
   stashing / holding / failing / blocking bodies become test *Workers*).

**Verification** (CS1's §12 rows, flat): byte identity; one open / one close per selected entry, zero opens for
dropped entries, archive closed once on completion, on downstream failure, on cancel mid-read; stashed content
read after release fails naming the entry; a test Worker calling `retain` on an `Entry` fails naming the
Worker, the entry and the source *before* the cursor advances (one entry produced); `../escape.txt`,
`existing:` variants, injected finalization failure as CS1; **`Entries → Formula(name = name + "!") → Write`**
completes (the §10 deadlock case); live heap flat across 100 MiB and 1 GiB.

**Exit.** Green, plus the as-built answers: did the wait ever see a hold other than callback / channel holds,
and what the deadlock monitor reported for the refused-retention case.

### BE2 — `Read part` over content, `Take`, close propagation

**Anchors.** `ReadPartWorker.kt`, `ContentDataOpener.kt`, `DataOpenerLookup.kt`, `TakeWorker.kt`,
`SourceWorker.kt`, `CursorSourceWorker.kt`, `ExpandingTransformWorker.kt`, `SinkWorker.kt`,
`JobChannel.kt`, `ScopeReadPartTest.kt`.

**Work.**

1. `ReadPartWorker.onElement` accepts an element carrying `Content` (the `Entry` shape's `content` field)
   and opens it through `ContentDataOpener.openContent` with the declared schema; the first entry fixes the
   item shape, later entries must match (CS2 behaviour). A `DataPart` element keeps today's path. Rows are
   lifted literals — independent — so the entry is released as soon as the reader closes.
2. Consumer-side close in the remaining drive loops (§3.7). `Entries` upstream of `Take` ends without
   draining and closes the cursor once.
3. Delete `ScopeReadPart`; port CS2's tests to `Entries → Read part → …`.

**Verification** (CS2 rows, flat): `Entries(bar.csv) → Read part → Result` equals `File → …` over the
extracted file; `Entries → Read part → Take(10)` over 2 M rows completes within about a second, ten rows, no
drain, cursor closed once; `Entries → Take(10) → Write` writes exactly ten files and opens no eleventh entry
(the source learns of the close on the flush that follows the tenth — record whether it is ten or eleven,
CS2 measured eleven for the body-`Write` ordering); `Entries → Read part → Sort → Result` succeeds (rows are
independent); `File → Take(10)` (a plain source upstream of a take) completes cleanly — the CS2 inherited case.

### BE3 — migration generalized

**Anchors.** `CursorSourceWorker.captureMigrationState` / `loadMigrationState`, `ScopeMigrationKey.kt`,
`JobLogic.kt` / `JobLogicCompiler.kt` (`scopeKeys`, `refuseMigration`), `ServerLogicController.kt`,
`ScopeMigrationTest.kt`.

**Work.**

1. Replace `ScopeMigrationKey` with a key computed from every `CursorSourceWorker`'s
   `cursorConfigurationKey()` (from notation, before detach); `JobLogic.refuseMigration` compares by stable
   id as today. `File` / `Read` sources get pre-detach refusal for free.
2. `Entries.loadMigrationState` keeps the belt-and-braces path check and the *interrupted inside entry*
   refusal (impossible once §3.5 gating holds, kept as the guard).
3. Port CS3's tests: `Write.coding: gzip → none` mid-run (edit lands between entries; earlier files `.gz`,
   later plain; one cursor, no re-open); `entries:` edit applies from the next header; `path` edit refused
   by name with the cursor's close count still zero; `Entries → Read part → Summary` at `capacity: 1`,
   pause mid-entry, count equals row count after migrate; with `drainingEnabled = false` the run fails
   naming the interrupted entry.

**Verification.** The above, plus a `File` source's `path` edit refused before detach.

### BE4 — UI removal, browser verification, docs

**Anchors.** `kzen-auto-js` `job/edit/ScopeBodyEditor.kt`, `job/display/EntryScopeWorkerDisplay.kt`,
`job-js.yaml` (`EntryScopeWorkerDisplay`, `EntryScopeTool`), `job-worker.yaml`, kzen-auto
`docs/architecture.md` (Job blockquote sentences on `EngineJobControl.draining`, `JobChannelTopology`,
`ScopeMigrationKey`), `docs/js-architecture.md` § 7 ("Nested-object list attributes" — remove).

**Work.**

1. Delete the two JS files and their notation; `EntriesTool` in `JobGroup_Sources`; `Write` in Sinks with its
   `coding` / `existing` select editors; `Read part`'s `format` picker already exists.
2. Verify in a real browser on a spare port (never the user's 8080 / 18081): place `Entries → Filter →
   Read part → Take → Result` from the ribbon into the gaps, run, see per-card progress and status, confirm
   outputs on disk; then `Entries → Write` with no sink.
3. Docs: architecture.md Job section gains one paragraph on borrowed elements (§3.1–3.3, the refusal rule);
   js-architecture.md § 7 note removed; this plan's tracker and the master ledger ticked.

**Verification.** The browser walk-through recorded in the as-built with the saved `Job.yaml`.

## 5. Unknowns to answer in the as-builts

1. Does `JobDeadlockMonitor` need to know about *await release*, or does a suspended wait already count as
   blocked for it (BE1)?
2. Does the wait ever observe a hold that is neither a callback hold nor a channel lease (BE1)? If yes, name
   the holder — it is either a bug or a case for the refusal rule.
3. `Entries → Take(10) → Write` ordering: ten or eleven files (BE2)?
4. Did `ReadPartWorker` need anything beyond `openContent` to take a `Content` element (BE2)?
5. Which `CursorSourceWorker` subclasses have a meaningful `cursorConfigurationKey` today, and which needed
   one (BE3)?

## 6. Rules for execution

- Work in `kzen-auto`; build from its own directory (`cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test
  --tests "*content*"` as the fast gate; `./gradlew :kzen-auto-js:compileKotlinJs` for BE4; full
  `./gradlew build` before declaring a session landed). No kzen-lib edit is expected.
- Stage every new file by explicit path in the sibling repo; never commit unless asked.
- Never touch the user's running dev servers (`127.0.0.1:8080`, `18081`).
- Each session appends an **As-built** under §8: what was built, the §5 answers, which verification rows are
  green, what the next session inherits. Tick the tracker and the master-ledger row.
- Review against `docs/CODING_STANDARDS.md` (CC-01 no magic constants; ≤ 120 columns).

## 7. Follow-ups outside this plan

- Keyed `Take` (first N per key, e.g. per entry) as an ordinary transform.
- "Per entry" annotation on the pipe out of a lending source (§3.9).
- UI surfacing of a refused live edit (currently the log and a rejected move); the *"applying edit after
  entry"* wait message (needs a pause-pending signal from `Execution`).
- `coding` / access in the cursor configuration key.
- A lone Worker with no downstream is never instantiated (blank output port; pre-existing).

## 8. Tracker and as-builts

| ID | Session | Status |
|---|---|---|
| BE1 | The protocol, `Entries`, `Write` | ☐ |
| BE2 | `Read part` over content, `Take`, close propagation | ☐ |
| BE3 | Migration generalized | ☐ |
| BE4 | UI removal, browser verification, docs | ☐ |

## Appendix A. What the spike built and found

The content streaming spike (CS1–CS3, all landed 2026-09-15, plus a Job UI pass on 2026-09-16; staged in
kzen-auto, never committed) proved the analysis's lifecycle rules in running code before this plan replaced
its *structure*. Everything below is still in the tree at the time of writing and is the starting point for
BE1–BE4. Numbers are as measured then.

### A.1 Substrate (kept as is)

Package `kzen-auto-jvm/.../server/objects/job/worker/content/`:

- `Content` (functions only, so kzen-lib's `BeanShape` treats it as opaque and the record inherits owners),
  `ContentDescriptor`, `ContentLifetime { CursorBorrowed, SingleUse, Reopenable }`, `Entry` (plain class →
  bean record; `size` is a non-null `Long` because the first `Filter` over `size > 8` failed on a nullable
  receiver; `modifiedEpochMillis` stays nullable), `Written { name, ref: DataRef, size }`.
- `tar/TarGzEntryCursor` (`Iterator<Entry>` + `AutoCloseable` over commons-compress; header selection via
  `scope/EntryGlob`, `*`/`?` within a segment, `**` across; `reselect(select)` applies a new selection from
  the next header without rewinding; closes without draining) and `tar/TarEntryContent` (`CursorBorrowed`;
  one open per entry; `invalidate()` makes a later `open` / `read` fail naming the entry; closing the handle
  never closes the archive). Test seam: companion `@Volatile TarGzEntryCursor.observer` (open / close counts).
- `scope/ContentWriter`: temp file in the target directory → MiGz gzip with `ExportCompression`'s parameters
  or plain → finalize → `ATOMIC_MOVE` (`REPLACE_EXISTING` only under `existing: replace`;
  `AtomicMoveNotSupported` fails naming the directory); containment rejects `/`-rooted, drive-lettered,
  `.` / `..` and empty segments; name interpolation `${name}`, `${size}`, `${kind}`,
  `${modifiedEpochMillis}`, `${parent.name}`, `${extension}`, anything else fails naming the placeholder;
  `coding: gzip | none`, `existing: fail | replace | skip`. Test seam: `ContentWriter.encoderInterceptor`.
- `data/ContentDataOpener.openContent(part, bytes)` on `ConfiguredDataOpener` via
  `DataOpenerLookup.contentOpener()`: the ordinary opener stack from the coding wrap down
  (`ContentCodingStack.wrap`, `OpenedReaderByteInput` stamped with the part's expected fingerprint,
  `capability.open`, `OwnedReaderDataCursor`), skipping only the provider lookup, descriptor capability check
  and fingerprint comparison. `DataReadCore` needed nothing (it already takes a `DataCursor`). The runtime
  part is a `DataPart` whose ref is the display-only `<archive>!<entry>`; fingerprint
  `tech.kzen.auto/archive-entry-v1` over archive, entry, size, modified.
- `ContentScopeHarness` (test): run / start over a fresh `KzenAutoContext.forTest()`, `compile` /
  `engine` / `fresh`, `workerProgress(engine, worker, key)`, notation `edit(...)`, archive fixtures
  (`prepare`, `writeArchive`, `writeLargeArchive`, `prepareCsvArchive(name, rows)` with a `rows.txt` marker,
  `KZEN_CONTENT_SPIKE_ROWS` / `KZEN_CONTENT_SPIKE_MIB` overrides), `collected(outcome)`.

### A.2 Engine changes (kept, generalized by §3)

- **Downstream closed vs paused (CS2's central finding).** The engine did not distinguish them: `JobChannel`
  closed only from the producer side, a consumer returning early left its producer parked on a full channel,
  and `JobDeadlockMonitor` failed the run ("all workers blocked on channels with no progress") about 200 ms
  after a `Take` completed. Added `DownstreamClosedException` (not a failure: a Worker ending on it settles
  normally), `FrameworkChannelInput.closeConsumer()` implemented by `JobChannel.Input` (`channel.close(cause)`
  resumes a parked producer with the cause; releases outstanding and buffered leases), `Producer.send` /
  `flush` raising it, `TransformWorker.requestCompletion()` and closure propagation upstream one Worker at a
  time (releasing the active batch's undispatched remainder, skipping `onComplete`), `TakeWorker`. Test seam:
  `JobChannel.consumerCloseEnabled`. Not done for `SourceWorker` / `CursorSourceWorker` /
  `ExpandingTransformWorker` / `SinkWorker` (BE2).
- **Draining (CS3's central finding).** `RunEngine.pause()` parks every `checkpoint()`, so with
  `Archive → ReadPart → Summary` over `capacity: 1` the run quiesced *inside* an entry. Added
  `EngineJobControl(draining: () -> Boolean)`: `checkpoint()` returns without parking while draining
  (seam `drainingEnabled`); `JobRun` computes per Worker the `ScopeBoundary`s upstream of it (plus itself)
  through `JobChannelTopology.upstreamWorkers` (the real one-way topology from the synthesized definition's
  filled ports — `JobChannelDerivation` reports only order-driven pairs, so a manually wired sink was missed
  until the draining test found it) and gates on `any { insideEntry() }`. No kzen-lib edit was needed.
- **Pre-detach refusal.** The migration protocol has no hook between "edit requested" and "capture taken".
  Added `ScopeMigrationKey(scope, path)` computed from notation, collected by `JobLogicCompiler` into
  `JobLogic.scopeKeys`, and `JobLogic.refuseMigration(edited)`; `ServerLogicController` (`liveLogic`,
  `pendingMigration`, `moveToAttempt`) refuses after compiling the edit and before touching the engine,
  leaves the baseline digest untouched, logs *"Live edit refused for <root>: <reason>"* and returns the
  reason as a rejected move. `CursorSourceWorker` still detaches first and fails on load (BE3).
- `EngineJobControl.yieldResult` refuses a value with run-owned natives (E9; pre-existing, reused).

### A.3 The scope itself (replaced by §3)

`EntryScopeWorker` extended `WorkerBase` with its own drive: cursor via `SourceIngress.openStream`;
per entry adopt an `EntryRelease` token under a `#scope` holder, attach its owners to the lifted `Entry`, run
the body chain under `CallbackLeases.holding`, call every body's `onEntryEnd`, then **check** that no holder
other than the scope held the token (fail by entry name before advancing), release. The last body emitter
(`leave`) refused any element whose owners included the token, flushed at the channel batch size, and was
the only checkpoint. `ScopeBodyWorker` (`onStart` / `onElement` / `onEntryEnd` / `onComplete` /
`captureState` / `loadState`) instances were nested objects under `body` (`is: List, of: ScopeBodyWorker,
by: NestedList` → `List<ObjectLocation>` resolved via `WorkerDefinitionContext.resolve`; no channel ports;
ignored by channel synthesis and `JobValidator`). `ScopeTake` threw `DownstreamClosedException` from inside
the chain. Migration detached the cursor and counters into a `DetachedScope`; `loadMigrationState` refused a
path mismatch or an interrupted entry by name and rebuilt body instances from the edited notation.

### A.4 Findings that carry over

- Re-entering compiled body objects per entry needed nothing from the engine (no child frame). Ten thousand
  small entries: 10.4 s wall, about 1.0 ms per entry, dominated by NTFS temp-create / write / atomic-move,
  not by re-entry.
- The release check only ever saw the body's own callback holds; task registration and entry-end flushing
  were never needed for release. This is the evidence that §3.2's wait is a wait on callback and channel
  holds only.
- Live heap: 46 MiB at 100 MiB and 47 MiB at 1 GiB (run setup, not the entry), asserted `< 64 MiB`.
- `Archive → ReadPart → Take(10)` over 2 M rows: ten rows, about 0.9–1.3 s wall, entry not drained, cursor
  closed once. `Archive → [Take(10)] → Write`: ten files, no eleventh opened. `Archive → [Write] → Take(10)`:
  **eleven** files and eleven entries opened — the closure is only observable on send, and the eleventh entry
  had already been published; needs a send-free "is my output closed" probe to be ten, and even then races.
- Rows out of the reader are lifted literals with no owner: `Sort` and `Summary` retain them freely.
- Cancellation inside a blocking read lands `Outcome.Cancelled` through `runBlockingIo`
  (`runInterruptible`) with the cursor closed once and no drain.
- `ScopeReadPart` needed no open-cursor migration adoption: its reader closes at entry end and a pause never
  lands inside an entry once the source is gated.
- kzen's YAML parser rejects inline non-empty lists (`entries: ["*.txt"]`); fixtures use block lists.
  `SortSpec` keys in notation are `"<index>|<name>"`. A `ConfiguredRecordFormat` on a Worker is an ordinary
  object reference, so `Read part` can share `main.formats/csv` with a `File` source.
- Build state at the end of CS3: full `./gradlew build` 1112 JVM tests, one failure —
  `JobRunWorkerTest.perUnitChildBindsNamedDateAndYieldsOrderedFingerprintedRefs`, pre-existing (fails with
  the spike stashed), not investigated.

### A.5 Job UI pass (2026-09-16; removed by BE4)

`EntryScope` got `display: EntryScopeWorkerDisplay` wrapping `WorkerDisplayDefault` with `body` hidden and a
`ScopeBodyEditor` (add via an `AddNameForm` picker of the `of:` type's concrete descendants, per-item
attribute editors through the `AttributeEditorManager`, move up / down via `ObjectTreeReorder` +
`ShiftObjectTreeCommand`, remove). Hosted from a display rather than an `editor:` because an
`AttributeEditor` taking the manager closes a reference cycle through the manager's autowired editor list.
`ContentWriter.coding` / `existing` got `SelectValuesEditor`, `ScopeReadPart.format`
`SelectDataFormatEditor`; `EntryScopeTool` moved to Sources. Verified end to end in a browser. Two
observations: a lone Worker with no downstream is never instantiated (blank output port, pre-existing); and
`JobController.insertionDocumentIndex` inserted after a Worker's own index rather than after its nested
subtree (moot once Job has no nested objects).
