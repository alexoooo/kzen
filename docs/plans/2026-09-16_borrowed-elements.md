# Borrowed elements over flat Job pipelines — constituent plan (BE)

> **Status: open — written 2026-09-16.** Supersedes the content streaming spike plan
> (`2026-09-15_content-streaming-spike.md`, deleted the same day; it was never committed, so its as-builts are
> preserved in [Appendix A](#appendix-a-what-the-spike-built-and-found) here).
> Design authority: [content streaming and containers](../analysis/2026-09-15_content-streaming-and-containers.md)
> for `Content`, lifetimes, containers and output semantics (§4, §5, §7, §12). **This plan amends its §6**:
> the structural scope (§6.1–§6.3), the scope-compatible contract (§6.2), the flat-notation fold (§6.5) and
> the §10 rejection of a per-channel lease are replaced by the cursor-owned release protocol in §3 below.
> The [master ledger](2026-07-25_master-plan.md) owns sequencing (rows BE1–BE5).
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
| `EntryScope` (+ body) | `Entries` (`CursorSourceWorker`) — superseded in BE5 by `File (emit: units) → Extract` | `Extract` (`ExpandingTransformWorker` + `BorrowingSource`, `CursorLending`): `input`, `members` glob, `output`; emits `Entry`; Transforms ribbon group; the file selection is `File`'s |
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

### BE5 — one file selector: `Extract`

**Why.** The user's verdict on the BE1–BE4 `Entries` card: a confusingly named Source with two bare text
boxes and no file browser — and the design point, *there should be one file selector, not one per downstream
purpose*. Selecting files is `File`'s job; what happens to them is downstream. The 2026-09-15 analysis (§7,
§8 "A directory of archives") already had this shape.

**Anchors.** `worker/CursorSourceWorker.kt` (the lending loop to factor out), `worker/ExpandingTransformWorker.kt`,
`worker/BorrowingSource.kt`, `content/EntriesWorker.kt` (delete), `content/tar/TarGzEntryCursor.kt`,
`data/ReadPartWorker.kt` (the `DataUnit` / `Entry` dual-input precedent), `job-worker.yaml`, `job-js.yaml`,
the 22 `entries-*` fixtures and three test classes.

**Work.**

1. `CursorLending`: the lend / await-release loop, `SourceIngress` adoption, `DetachedCursor` capture / adopt
   and the two refusals, moved out of `CursorSourceWorker` (same API, same strings) and shared.
2. `Extract` = `ExpandingTransformWorker` + `BorrowingSource`: per input element open one `.tar.gz` (a
   `DataUnit` from `File` / `Read` in units mode, or an `Entry` for a nested archive) and lend its members;
   `members` globs; static `Entry` output lane; lane check names the fix when the upstream is a known non-file
   type. `Entries`, its archetype and ribbon tool deleted; `ExtractTool` under Transforms; no client change.
3. Fixtures and tests ported (`File(units) → Extract → …`); new rows: two archives with ``,
   nested `Extract → Extract`, Items-mode hint, static lane error.
4. Docs: architecture blockquote, this plan (§3.8 note, tracker, as-built), the master ledger.

**Verification.** JVM gate (`*content*`, `*Migration*`, `*JobValidatorTest*`, `*JobRun*`), JS compile, jar;
browser on a spare port: `File → Extract → Write → Result` over two archives, Advanced → Emit: Units,
`members: *.csv`, `name: ${parent.name}/${name}${extension}`; per-card progress, files on disk, and the
Emit hint when Items.

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
| BE1 | The protocol, `Entries`, `Write` | ☑ 2026-09-16 |
| BE2 | `Read part` over content, `Take`, close propagation | ☑ 2026-09-16 |
| BE3 | Migration generalized | ☑ 2026-09-16 |
| BE4 | UI removal, browser verification, docs | ☑ 2026-09-16 |
| BE5 | One file selector: `Extract` | ☑ 2026-09-17 |

### As-built BE1 (2026-09-16)

**Built.** The protocol of §3.1–§3.3 over the E9 ledger, and the two flat Workers, in `kzen-auto` (staged, not
committed):

- `LentElement: AutoCloseable { lentName(); lender() }` (`worker/LentElement.kt`, new) is the marker; `Entry`
  implements it (`close()` → `Content.release()`, a new default no-op that `TarEntryContent` overrides with its
  invalidation — the old `internal invalidate()`). No `CursorBorrowed` / `EntryRelease` / authority holder
  were needed: the run's `OwnedNative` for the entry is the token, its last hold's release its close.
- `BorrowingSource { lending(); awaitingRelease() }` (renamed from `ScopeBoundary`, moved to `worker/`).
  `CursorSourceWorker` implements it: after sending a `LentElement` (the channel flushes an owned element at
  once, so nothing waits for siblings) it releases its producer hold, suspends on
  `OwnedNative.awaitClosed()` (new `CompletableDeferred` under the entry's lock, completed in `closeOnce`),
  then checkpoints, then pulls. `lending()` / `awaitingRelease()` / `lentElementName()` are read from other
  threads (volatile). A `DownstreamClosedException` from the send ends the source without draining.
- Retention refused by name: `EngineJobControl.retain` and `yieldResult` throw
  `"<worker> cannot keep entry 'x': it is borrowed from 'archive' and is only valid until the source advances.
  Snapshot it, read it, or write it."` when any owner's native is a `LentElement`. The framework's own
  per-callback hold moved to `RunOwnershipControl.holdForCallback` (no refusal), which `CallbackLeases` uses.
- `Entries` (`content/EntriesWorker.kt`, from `EntryScopeWorker`): a `CursorSourceWorker` over one
  `TarGzEntryCursor`; `entries` globs reselect on adoption; `path` is the cursor configuration key; progress
  `entries / skipped / entry`. `Write` (`content/WriteWorker.kt`, from `ContentWriter`): a `TransformWorker`
  emitting `Written`; totals / `captureState` / `loadState` removed. `ReadEntry` (`content/ReadEntryWorker.kt`,
  from `ScopeReadPart`): an `ExpandingTransformWorker` over an `Entry`, an **interim** archetype that BE2
  folds into `ReadPart`. `EntryGlob` moved to `content/`; `ScopeMigrationKey` stays (keyed on `EntriesWorker`).
- `JobRun`: draining keyed on `BorrowingSource.lending()`; the deadlock monitor gets
  `awaitingRelease = { borrowingSources.count { it.awaitingRelease() } }` (new `JobDeadlockMonitor` parameter,
  added to the blocked sum).
- Pulled forward from BE2 (needed to keep the ported CS2 rows green): `SourceWorker.drive`,
  `CursorSourceWorker.produce` and `ExpandingTransformWorker.drive` complete normally on
  `DownstreamClosedException` (the expanding Worker releases its active batch and closes its input on the
  consumer side). `TransformWorker` already did.
- Migration: `DetachedCursor` carries the lent element's name; `loadMigrationState` refuses
  `"Source was interrupted inside entry 'x'; a live edit applies only between elements."` **without closing the
  detached cursor** — the ledger owns it and closes it at teardown; closing it in the refusal invalidated the
  entry under its holder, whose "was released" failure then won the race and hid the refusal.
- Deleted: `ScopeBodyWorker`, `BodyEmitter`, `ScopeFilter`, `ScopeTake`, `DetachedScope` (was inside
  `EntryScopeWorker`), the `body` attribute, `content-test-bodies.yaml`, the `EntryScopeWorkerDisplay` object
  entry in `job-js.yaml` (its Kotlin files go in BE4). Notation: `Entries`, `Write`, `ReadEntry` archetypes in
  `job-worker.yaml`; `EntriesTool` (Sources), `ReadEntryTool` (Transforms), `WriteTool` (Sinks) in
  `job-js.yaml`. `docs/architecture.md` Job blockquote and the `js-architecture.md` §7 preface updated.
- Tests: `ContentScopeHarness` → `ContentTestHarness`; `EntryScopeWorkerTest` → `EntriesWorkerTest`,
  `ScopeReadPartTest` → `ReadEntryWorkerTest`, `ScopeMigrationTest` → `EntriesMigrationTest`; `TestBodies` →
  `TestWorkers` (`StashingWorker`, `HoldingWorker`, `FailingWorker`, `BlockingWorker`, `LabelsWorker`, all
  `TransformWorker`s declared in `content-test-workers.yaml`); every `scope-*.yaml` fixture → `entries-*.yaml`,
  flat (`Archive: is: Entries` → `Filter` / `Write` / `ReadEntry` / `TakeWorker` / test Worker → `collect`);
  new `entries-formula-test.yaml` for the §10 deadlock case. kzen-lib's YAML parser accepts only empty inline
  collections, so `entries:` lists are block lists.

**§5 answers.**

1. **The monitor needed to know.** A source parked in `awaitClosed()` is suspended on a `Deferred`, not on a
   channel op, so it is invisible to `blockedCount()`; without the `awaitingRelease()` term the
   `withoutConsumerCloseTheEngineReportsTheCompletedTakeAsADeadlock` row hung (the reader blocked on its send
   and the source awaiting release: blocked 1 < active 2). With it the verdict fires as before. For the
   refused-retention row the monitor never speaks: the refusal fails the run at the first entry.
2. **No.** Every hold the wait saw was the channel's or a callback's (the stall report names holders; in the
   Formula row it names `Formula: 1` — the callback hold during Kotlin script compilation, ~2 s — and the
   source's cursor). The one surprise was in the test, not the protocol: `HoldingWorker` retains → the run
   fails → the source, released by the failed callback, may pull one more header (never opened) before the
   cancel reaches it, so the retention row now allows 1..2 pulled / 0 opened, as the take-in row already did.

**Verification.** `./gradlew :kzen-auto-jvm:test --tests "*content*"`: 46 tests green (16 `EntriesWorkerTest`,
6 `ReadEntryWorkerTest`, 5 `EntriesMigrationTest`, plus the pre-existing content-store tests). All CS1 §12 rows
flat, plus the Formula (§10) row: `Entries → Formula(label = name + "!") → LabelsWorker` completes with the four
entries invalidated in order. Wider gate (`*Migration*`, `*JobRun*`, `*JobChannel*`, `*LogicController*`,
`*JobDeadlockMonitor*`, `*FormulaStepTest`, `*Worker*`): 248 tests, one failure —
`JobRunWorkerTest.perUnitChildBindsNamedDateAndYieldsOrderedFingerprintedRefs`, a `ClassCastException`
(`SingletonList` → `String`) in the child's `flatDate` argument expression, in `RunWorker` / Formula code this
session did not touch; it fails identically on a clean HEAD worktree, so it is pre-existing. `:kzen-auto-js:compileKotlinJs` green.

**Blocker to know about.** The test corpus loads the user's `notation/main/` documents, and the untracked
`notation/main/Job-5.yaml` (`is: EntryScope`) no longer resolves, which fails every definition-loading test at
`TargetSpecCreator`'s autowired list. The suite was run with a throwaway `EntryScope: is: Entries` alias in
`job-worker.yaml`, removed before hand-off; the document itself was not touched (user document).

**BE2 inherits.** `ReadEntry` to fold into `ReadPart` (§3.8); `Take` already flat (`TakeWorker`, kept); close
propagation is done in the three drive loops (item 2 of BE2 is only the sink loop, if anything remains);
`entries-take-*` / `entries-write-take` fixtures already exercise ten-or-eleven (§5 item 3: the take-in row
measured 10 written / 10 opened / 10–11 pulled).

### As-built BE2 (2026-09-16)

**Built.** `Read part` over an `Entry`, the CS2 rows ported flat, and the interim `ReadEntry` gone, in
`kzen-auto` (staged, not committed):

- `ReadPartWorker.onElement` takes an [Entry] as well as a `DataUnit`: `readEntry` opens the entry's bytes
  under `runBlockingIo`, hands them to `ContentDataOpener.openContent` with a synthetic `DataPart` (ref
  `<archive>!<entry>`, role `main`, fingerprint identity `tech.kzen.auto/archive-entry-v1` over archive / entry /
  size / modified, read spec from the new `format` attribute), establishes the shape baseline (`strict`: first
  entry fixes it, later must match; a declared schema fixes it up front) and emits through `DataReadCore.emitNext`
  — the same lifted literal records a file produces, independent of the entry. The reader is closed at the end
  of the entry (`close` on completion, `closeFallback` on failure or `DownstreamClosedException`), never carried
  across a migration (`onExpansionClose` also drops it; the source refuses an edit inside a lent element anyway).
  `payloadFlow` accepts a non-null `Entry` native type next to the opaque `DataUnit`. The `DataUnit` / `DataPart`
  path is untouched.
- `format: ConfiguredRecordFormat` on `ReadPartWorker` (non-null; a nullable object reference would need a
  custom definer), default `configured-delimited-format.yaml#ConfiguredCsv`, `SelectDataFormatEditor` in
  notation; it applies to content elements only — a unit's parts carry their own resolved read specs.
- Deleted: `ReadEntryWorker` (`content/`), the `ReadEntry` archetype in `job-worker.yaml`, `ReadEntryTool` in
  `job-js.yaml`. Consumer-side close (§3.7) was already in the three drive loops from BE1; `SinkWorker` has no
  output, so nothing to add.
- Tests: `ReadEntryWorkerTest` → `EntriesReadPartTest` (the CS2 rows, flat, over `is: ReadPartWorker` with
  `format: main.formats/csv`: `entries-read-test`, `entries-read-sort-test`, `entries-take-out-test`,
  `entries-migrate-summary-test`); new `file-take-test.yaml` + `ContentTestHarness.prepareBigFile` for the
  inherited `File → Take(10)` row; `ReadPartWorkerTest`'s helper passes `ConfiguredDelimitedTestFormats.csv()`.
  `docs/architecture.md` Job blockquote extended.

**§5 answers.**

3. **Ten written, ten opened, ten or eleven pulled.** `Entries → Take(10) → Write` (take-in row): 11 headers
   pulled, 10 opened, 10 written; the eleventh header is pulled before the take's completion reaches the source
   and is never opened. `Entries → Write → Take(10)` (write-take row): 11 written, 12 pulled — the take closes
   after its tenth element, the `Write` in flight finishes its eleventh, and the source's last pull is a header
   only. An eleventh file is therefore possible only with a Worker between `Take` and the source, never from the
   take itself.
4. **Yes, four things.** Beyond `openContent`: a `format` attribute (the read spec a `DataPart` otherwise carries),
   the synthetic `DataPart` / fingerprint above, `payloadFlow` acceptance of the `Entry` native class, and a
   second cursor field (`entryCursor`) so the fallback close at expansion close reaches an open entry reader. No
   ledger, ownership or channel change was needed: the rows are ordinary lifted literals and the entry's
   release is the reader's close.

**Verification.** `./gradlew :kzen-auto-jvm:test --tests "*content*" "*ReadPart*" "*JobRunWorkerTest"
"*JobDeadlockMonitor*"`: 79 tests, one failure — the pre-existing
`JobRunWorkerTest.perUnitChildBindsNamedDateAndYieldsOrderedFingerprintedRefs` (BE1 report; identical on a
clean HEAD worktree). Rows: `Entries(bar.csv) → Read part → Result` equals `File → Read → Result` on the
extracted file; `Entries → Read part → Take(10)` over a 2 000 000-row entry: 10 taken, 1 207 ms, no drain,
cursor closed once; `Entries → Read part → Sort → Result` green; `File → Take(10)` over a 2 000 000-row file:
10 taken, 1 145 ms, completes cleanly. Wider gate (`*Worker*`, `*Migration*`, `*JobRun*`, `*JobChannel*`,
`*LogicController*`): 231 tests, the same single pre-existing failure. `:kzen-auto-jvm:compileTestKotlin` and `:kzen-auto-js:compileKotlinJs` green.

**Blocker, still.** The untracked user document `notation/main/Job-5.yaml` (`is: EntryScope`) fails every
definition-loading test; the suites ran with the same throwaway `EntryScope: is: Entries` alias in
`job-worker.yaml` as BE1, removed before hand-off. The document was not touched.

**BE3 inherits.** §5 item 5 (`cursorConfigurationKey` per `CursorSourceWorker` subclass); `ScopeMigrationKey`
still keyed on `EntriesWorker`; `DetachedCursor` / `loadMigrationState` refusal-by-name is the only lent-element
migration rule so far, and the entry reader in `ReadPartWorker` is deliberately not migration state.

### As-built BE3 (2026-09-16)

**Built.** The pre-detach refusal generalized from the `Entries` archive path to every source's selection, in
`kzen-auto` (staged, not committed):

- `WorkerBase.migrationKey(graphNotation, location): Any?` (default null) is the rule: the part of a Worker's
  NOTATION its run-scoped state was opened over. It is read from notation, not from the instance, so the
  RUNNING instance evaluates both its own definition and the edited one (same stable id, possibly renamed)
  — the extension rule of `payloadFlow`: no general layer learns a Worker type. `migrationKeyOf` (companion)
  builds the usual key, the named attributes' notations (`firstAttribute`, inherited ones included; kzen-lib's
  attribute notations are data classes, so the comparison is structural).
- Implementations: `EntriesWorker` (`path`), `FileSourceWorker` (`directory`, `filter`, `files`, `format`,
  `groupPattern`, `missing`), `ReadWorker` (`source`; an edit inside the same data source is still judged by
  the definition digest on adoption, which restarts the read from a fresh manifest, as before).
- `JobLogic` keeps one live handle, `LiveWorkers` (new, `exec/job/`): the Workers of the runs hosted from the
  definition, by stable id, registered by `JobRun` once instantiated and withdrawn when the run ends
  (including at its own migration barrier — the rebuilt run registers its own). `refuseMigration(edited)`
  walks them, locates the edited counterpart through the compile-time `workerStableIds` (replacing
  `scopeKeys`), and refuses `"Source selection of <name> changed. Start a new run to apply it."` on the first
  differing key. Without a live run there is nothing to refuse. `JobRun`'s constructor is `internal` (it takes
  the registry). `ScopeMigrationKey` and the `content/scope/` package are gone.
- `CursorSourceWorker.cursorConfigurationKey()` and the *interrupted inside entry* refusal stay as the
  belt-and-braces on adoption (§4 BE3 item 2); the entry reader in `ReadPartWorker` is not migration state.
- Tests: the CS3 rows were already flat in `EntriesMigrationTest` (BE1); its path-refusal row now asserts
  `null` before the run, the refusal and the compatible edit's `null` from the paused live run, `null` again
  after the run. New `FileSourceMigrationTest` + `file-migrate-test.yaml` (`File(big.csv) → Summary → Result`,
  100 000 rows): a `files` edit is refused by name from the paused run, the sink edit is compatible, the run
  completes with every row counted once. `ContentTestHarness.prepareCsvFile(name, rows)`.
  `docs/architecture.md` Job blockquote updated; `ServerLogicController`'s comment generalized.

**§5 answer 5.** `EntriesWorker` is the only `CursorSourceWorker` subclass, and the only one with a
`cursorConfigurationKey` (`path`). The `File` / `Read` sources are `ReadWorker`s, not cursor sources: their
adoption rule is the instance-side definition digest (`compatibilityKey`, restart on mismatch), so they did
not get the pre-detach refusal "for free" from `cursorConfigurationKey` as §3.6 assumed — they got it from
the notation-level `migrationKey`, which is why the hook lives on `WorkerBase` rather than
`CursorSourceWorker`. Nothing else needed a key.

**Verification.** `./gradlew :kzen-auto-jvm:test --tests "*Migration*" "*content*"`: green (5
`EntriesMigrationTest` rows incl. the §5-item-3 rows, `FileSourceMigrationTest`, the BE1/BE2 content
suites). Wider gate (`*Worker*`, `*Migration*`, `*JobRun*`, `*JobChannel*`, `*LogicController*`, `*Logic*`):
266 tests, the same single pre-existing failure. JVM main + test compile green; no JS change.

**Blocker, still.** `notation/main/Job-5.yaml` (`is: EntryScope`, untracked user document) — same throwaway
alias for the test runs, removed before hand-off, document untouched.

**BE4 inherits.** UI removal (`ScopeBodyEditor`, `EntryScopeWorkerDisplay`, `EntryScopeTool` in `job-js.yaml`),
browser verification, and the `docs/architecture.md` / `js-architecture.md` passes; nothing from BE3 changes
the client. A nested Job (hosted by a `RunWorker` inside a Script) is still not judged pre-detach — the
controller asks only the root `JobLogic`, as before.

### As-built BE4 (2026-09-16)

**Built.** The client side of the scope model is gone and the borrowed-elements Workers are verified end to end
in a real browser (`kzen-auto`, staged, not committed):

- Deleted `kzen-auto-js` `job/edit/ScopeBodyEditor.kt` and `job/display/EntryScopeWorkerDisplay.kt`; nothing
  else referenced them (`AddNameForm` stays — Formula / Sort / ValueSet editors share it;
  `PluginController.renderScopeBody` is the plugin scope, unrelated). `job-js.yaml` already carried
  `EntriesTool` under `JobGroup_Sources`, `ReadPartTool` under Transforms and `WriteTool` under Sinks from
  BE1; no `EntryScope*` object remains anywhere outside the untracked user document (below).
  `./gradlew :kzen-auto-jvm:jar` (which compiles the JS bundle) is green after the deletions.
- `docs/js-architecture.md` §7: the subsection *Nested-object list attributes: host the editor from a
  `display:`, not an `editor:`* is removed — it documented the deleted body editor; the general rule it
  stated no longer has an instance in the tree. `docs/architecture.md`'s Job section carried the
  borrowed-elements paragraph since BE1–BE3; unchanged in BE4.
- `WriteWorker`'s class doc no longer claims that a Job ending in `Write` needs no sink (finding below).

**Browser walk-through.** Own server: the built jar on port 8097, `--module.root` / `--work.root` pointed at a
scratch project under `%TEMP%\kzen-be4` whose `data/input.tar.gz` holds `part1..4.csv` (`id,name` + two rows
each) and a `readme.txt`. Two Jobs built from the ribbon into the gaps, each saved by the client as an
order-driven document (no Channel objects, no port references):

```yaml
# main/Job.yaml — Entries → Filter → Read part → Take → Result
main:
  is: Job
  results:
    main:
      class: kotlin.Any
      generics: []
      nullable: false

main.workers/Entries:
  is: Entries
  path: C:/Users/ostro/AppData/Local/Temp/kzen-be4/data/input.tar.gz
  entries:
    - '*.csv'

main.workers/Filter:
  is: FilterWorker
  where: name != "part3.csv"

main.workers/Read part:
  is: ReadPartWorker

main.workers/Take:
  is: TakeWorker
  count: 3

main.workers/Result:
  is: ResultSinkWorker
```

Run: Entries `entries=4 skipped=1 Done`, Filter `seen=4 kept=3 Done`, Read part `units=2 emitted=5 Done`,
Take `taken=3 Done`, Result `collected=3 Done`, value `{id=2, name=alpha2}` — the third record overall
(part1's two rows, then part2's first), so `Take` closed its input after the third record, `Read part` never
opened `part4.csv` (two units, five emitted: part2 was drained after the close), and the lanes between the
cards read `Entry (Record)` → `Entry (Record)` → `Dynamic` → `Dynamic`.

```yaml
# main/Job-1.yaml — Entries → Write → Result
main:
  is: Job
  results:
    main:
      class: kotlin.Any
      generics: []
      nullable: false

main.workers/Entries:
  is: Entries
  path: C:/Users/ostro/AppData/Local/Temp/kzen-be4/data/input.tar.gz
  entries:
    - '*.csv'

main.workers/Write:
  is: Write
  directory: C:/Users/ostro/AppData/Local/Temp/kzen-be4/data/out

main.workers/Result:
  is: ResultSinkWorker
```

Run: Entries `entries=4 skipped=1 Done`, Write `written=4 skipped=0 Done`, Result `collected=4 Done`, value
the `Written` record of `part4.csv.gz`. On disk `data/out/part1.csv.gz` … `part4.csv.gz` (54 bytes each)
decompress to the original three lines of each part. The `Write` card offers `Coding` (gzip / none) and
`Existing` (fail / replace / skip) as selects; `Read part`'s `Format` picker is the BE1 one.

Client behaviour worth knowing for the next walk-through: while a Job's trailing Worker is a Transform (a
card just dropped, its downstream not yet placed) the pipes show *Loading…* and the server logs a transient
*Missing <empty>* on the open output; placing the next card and reloading the page clears it. A `Result`
card also needs a result declared in the Job signature (`Result ⊕`, type Any) before the Job validates.

**Finding — `Write` still needs a sink (deviation from §3.8).** `Entries → Write` alone does not start:
*Unable to compile main/Job-1.yaml#main: Missing <empty> in main/Job-1.yaml#main.workers/Write*. `Write` is
a `TransformWorker` with a required `output: ChannelOutput`; channel synthesis wires only adjacent pairs, so
a trailing Transform's output stays empty and the definition fails. The §3.8 line "a Job whose last Worker
is `Write` needs no sink" was never implemented in BE1 — every BE1 test wires `Write → Result` — and doing
it is an engine feature, not a UI removal: an unread trailing channel would fill to `capacity` and block, so
a terminal output needs either an optional `ChannelOutput` on `TransformWorker` or a synthesized discarding
sink. Not built in BE4; the doc claim is withdrawn from `WriteWorker` and the walk-through used
`Entries → Write → Result`. Recorded here as the open item for the plan-close.

**Verification.** Jar build (JS + JVM compile) green; browser runs above; the BE3 test gate is unchanged
(no JVM source changed beyond the `WriteWorker` comment). Server stopped and the tab closed afterwards; the
scratch project stays under `%TEMP%`.

**Blocker, still.** `notation/main/Job-5.yaml` (`is: EntryScope`, untracked user document) is left as is;
it no longer loads against this tree (no `EntryScope` archetype) and needs the user's decision.

**Plan-close notes.** All four sessions are ticked. Open items: the trailing-`Write` sink (above); a nested
Job hosted by a `RunWorker` inside a Script is still not judged pre-detach (BE3); `Job-5.yaml`.

### As-built BE5 (2026-09-17)

**Built.** One file selector. The `Entries` Source is deleted and archive extraction is a Transform below the
`File` selector (`kzen-auto`, staged, not committed):

- `ExtractWorker` (`content/ExtractWorker.kt`): an `ExpandingTransformWorker` that is also a `BorrowingSource`.
  Per input element it opens one `.tar.gz` and lends each member downstream as an `Entry`, advancing only when
  the member's last hold is released. Input: a `DataUnit` (a `File` or `Read` source with Emit set to Units;
  the path is the single `main` part's `DataRef`) or an `Entry` (a nested archive, opened from the entry's
  borrowed content through `SequentialByteContentInputStream` while the enclosing member is held). Output lane:
  the static `Entry` contract. `members:` globs apply at the header (`TarGzEntryCursor.reselect`, so a live
  edit applies from the next member). Progress: `archives`, `archive`, `entries`, `skipped`, `entry`.
- `CursorLending` (`worker/CursorLending.kt`): the lend / await-release loop, `SourceIngress` adoption,
  `DetachedCursor` capture / adopt and both refusals, factored out of `CursorSourceWorker` (now a thin shell
  with the same protected API and error strings) and reused by `Extract` (`drain`, `capture`, `adopt`,
  `restoreDelivered`). `DownstreamClosedException` propagates out of `drain`; the source base swallows it,
  `Extract` lets `ExpandingTransformWorker.drive` release the batch and close its input.
- `TarGzEntryCursor` gained a stream constructor (`parent: ContentDescriptor, bytes: InputStream`); the path
  constructor delegates to it.
- Notation: `Extract` archetype (`input`, `members`, `output`; title "Extract") replaces `Entries` in
  `job-worker.yaml`; `ExtractTool` under `JobGroup_Transforms` replaces `EntriesTool` in `job-js.yaml`. No
  client source change: the generic `WorkerDisplayDefault` card renders *Members (one per line)*.
- Tests: the 22 `entries-*` fixtures ported to `extract-*` (`File(units) → Extract → …`), the three test
  classes renamed (`ExtractWorkerTest`, `ExtractReadPartTest`, `ExtractMigrationTest`); the `path` refusal row
  became a `files` edit on the `File` Worker (same by-name refusal, `FileSourceWorker.migrationKey`), the
  `entries` row a `members` edit on `Extract`. New rows: two selected archives flow in selection order, the
  first cursor closed before the second opens, `Write name: "${parent.name}/${name}${extension}"` splits them;
  nested `Extract → Extract → Write` unpacks an archive inside an archive; a `File` left in Items mode fails at
  run time with the Units hint; a typed non-file lane upstream of `Extract` is a static validation error
  (`JobValidatorTest.extractRejectsKnownNonFileInputWithTheUnitsHint`).

**Deviation — `File` had to change (undetected files).** The plan assumed units mode over an archive already
worked ("sniffs as gzip, falls back to plain text without error"). It did not: automatic detection runs per
file at manifest time in every mode, and a `.tar.gz` fails as *Input contains NUL and appears to be binary*
before any Worker runs. The resolver's rule (binary that no format claims fails as not-text; pinned by
`ConfiguredFormatExtensibilityTest`) is kept. The change is in `FileDataSource.resolveInput`: under automatic
selection with no per-row encoding, a `Resolution`-category detection failure resolves to
`UndetectedFormat` — an opaque `ResolvedReadSpec` (reader `tech.kzen.auto/undetected/1`) carrying the
detector's reason; the row shows *Automatic → Undetected* with a warning. `ConfiguredDataOpener.resolve` is the
one choke point: any reader asked to open such a part is refused with the detector's words plus the hint *To
pass the file on whole (to Extract), set the File source's Emit to Units*. So the selection survives, whole-file
consumers never need a reader, and Items mode over an archive fails where it used to, at the first read, with
the same message and the fix attached. Timeout / acquisition failures still fail the selection.

**Deviation — the static Emit hint is partial.** `Extract.payloadFlow` errors when the upstream lane is a
known non-`DataUnit` / non-`Entry` type. A `File` in Items mode over an undeclared file publishes an *unknown*
lane (`ReadWorker.payloadFlow`, no design-time IO), and `JobLaneContext` does not name the upstream Worker, so
the card validates clean and the hint arrives at run time (above). Confirmed in the browser: with Emit set to
Items the `Extract` card shows no error; running fails on the `File` card with the message above.

**Deviation — `Read part` refuses a mid-entry capture by name.** The `withoutDraining…` migration row exposed
that `ReadPartWorker` never captured its entry-read position: on replay it re-opened the single-open entry
stream and failed as *cursor-borrowed and was already opened*, racing the lender's own refusal for the run's
message. `ReadPartState` now carries `interruptedEntry`; a capture taken inside an entry is refused on load
(*Read part was interrupted inside entry 'X'; a live edit applies only between elements*), the same rule as
`CursorLending.adopt`.

**Browser walk-through** (jar on `127.0.0.1:8097`, scratch module root under `%TEMP%\be5-browser` with
`first.tar.gz` = `a1.csv`, `a2.txt` and `second.tar.gz` = `b1.csv`, `b2.csv`). The document was seeded on
disk; the cards rendered as `File ▸ Opaque` (file table with both rows, *Automatic → Undetected · text
fallback*), `Extract ▸ Entry (Record)` with *Members (one per line)*, `Write`, `Result`. Run: File
`units=2 emitted=2 Done`, Extract `archives=2 entries=3 skipped=1 Done`, Write `written=3 skipped=0 Done`,
Result `collected=3`; on disk `out/first.tar.gz/a1.csv.gz`, `out/second.tar.gz/b1.csv.gz`,
`out/second.tar.gz/b2.csv.gz`, contents intact. Without the `Result` card the run deadlocked after the first
member (Write's unread output; the BE4 finding, unchanged). Saved document:

```yaml
main:
  is: Job
  results:
    main: {class: kotlin.Any, generics: [], nullable: true}

main.channels/files: {is: Channel}
main.channels/entries: {is: Channel}
main.channels/written: {is: Channel}

main.workers/File:
  is: FileSourceWorker
  files:
    - location: C:/…/be5-browser/in/first.tar.gz
    - location: C:/…/be5-browser/in/second.tar.gz
  emit: units
  output: main.channels/files

main.workers/Extract:
  is: Extract
  input: main.channels/files
  members: ["*.csv"]
  output: main.channels/entries

main.workers/Write:
  is: Write
  input: main.channels/entries
  output: main.channels/written
  directory: C:/…/be5-browser/out
  name: "${parent.name}/${name}${extension}"

main.workers/Result:
  is: ResultSinkWorker
  input: main.channels/written
  keep: all
```

**Verification.** `:kzen-auto-jvm:test --tests "*content*" --tests "*Migration*" --tests "*JobValidatorTest*"
--tests "*JobRun*" --tests "*datasource*" --tests "*Format*" --tests "*Read*"`: 175 tests, the one
pre-existing `JobRunWorkerTest.perUnitChildBindsNamedDateAndYieldsOrderedFingerprintedRefs` failure only.
`:kzen-auto-js:compileKotlinJs` and `:kzen-auto-jvm:jar` green. Browser run above; my JVM stopped (command
line checked), tab closed. The user's `notation/main/Job-1.yaml` (`is: Entries`, untracked) was aliased to
`Extract` for the test runs only; the alias is removed and the document is untouched — it no longer loads.

**Follow-ups.** Trailing `Write` sink (BE4, still open); `Emit` sits under the `File` card's Advanced
disclosure — promote it, or select Units automatically when the downstream is `Extract`; the static hint
needs the upstream Worker in `JobLaneContext` (or `File` publishing an *undetected* lane in Items mode);
`TarGzEntryCursor` is gzip+tar only (`container:` / `coding:` from analysis §7 remain deferred); the file
table's *text fallback* caption for an undetected row is the generic basis label and could say *undetected*.
The `Emit` / vocabulary items are taken up in
[files and items](../analysis/2026-09-18_job-files-and-items.md) (§3, §8).

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
