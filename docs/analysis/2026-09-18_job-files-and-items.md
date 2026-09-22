# Files and items: how file selection, archives, rows and plug-ins fit together in a Job

> **Status: steps 1–3 of §9 landed 2026-09-18 (see the as-built under §9); the rest is exploratory.** It was prompted by a usability failure
> on 2026-09-18 — `File(data.tar.gz) → Preview` fails with *"No installed format reads … set the File source's
> Emit to Units"* — and by the broader question of how the Job paradigm's file-level and row-level use cases
> compose. Builds on [content streaming and containers](2026-09-15_content-streaming-and-containers.md) and the
> [borrowed elements plan](../plans/2026-09-16_borrowed-elements.md). Code facts were checked against the tree
> on 2026-09-18; anything marked *unpinned* has no test or run behind it.

## 1. Decision in one page

**Two kinds of element flow through a Job.**

- A **file** — named bytes. On disk it is a `DataUnit`; inside an archive it is an `Entry`. To the user these
  are one thing.
- An **item** — a row, an ITCH message, a plug-in object. Anything that is not a file.

**Workers are verbs, classified by what they take and give.**

| signature | Workers | Unix analogue |
|---|---|---|
| files → files | `Extract` (archive → members), `Write` (store / compress), `Filter` on name or size | `tar -x`, `gzip`, `find` |
| files → items | reading; the *format* decides what the items are — CSV → rows, ITCH → messages, tar → table of contents | `cat`, `tar -t` |
| items → items | `Filter`, `Formula`, `Sort`, `Take`, `Summary`, plug-in analytics | `grep`, `awk`, `sort`, `head` |
| items → files | `CSV Writer`, `Export` | `>` |
| anything → screen | `Preview`, `Result` | the terminal |

**`File` only selects files. What they become is decided by what is connected next.** A file consumer
(`Extract`, `Write`) receives files; everything else receives items and the read is implicit. The `Emit`
switch leaves the card. In Unix the user writes `cat` themselves; here the connection infers it, because
making every CSV job start `File → Read → …` taxes the common case.

**Reading an archive yields its table of contents**, exactly as reading a CSV yields rows. So
`File(data.tar.gz) → Preview` lists the members with no other step, and `Extract` remains the explicit verb
for going *inside*.

**One output or one per input is an output-naming question, not a nesting question.** Items carry their
origin; sinks name outputs by pattern. The design stays flat (borrowed elements §3).

Most of this is a re-reading of what is already built. §2 marks what works, §3–§7 cover the gaps, §9 stages
the work.

## 2. The use cases, against today's tree

| # | want | pipeline | today |
|---|---|---|---|
| 1 | several CSVs, work on the rows | `File → Filter → … → Result` | **works** |
| 2 | one report from many files | same; files read in selection order into one stream | **works** |
| 3 | one output per input file | parent Job `File(units) → Run(child Job)`; child `Formula source → Read part → CSV Writer(path: ${param})` | **works, heavy** — pinned by `job-per-unit-test.yaml` + `job-per-unit-child-test.yaml`; needs two documents and `Emit: Units` (§5) |
| 4 | CSVs as whole files, compress elsewhere | `File → Write` | **gap** — `Write` accepts only `Entry` and fails at run time with *"Write expects an Entry; received …DataUnit"* (`WriteWorker.kt:111-114`); it has no static lane check either (§6) |
| 5 | see what is inside a tar / tar.gz | `File → Preview` | **fails** — the error that prompted this note (§4) |
| 5′ | same, the long way | `File(Emit: Units) → Extract → Preview` | *unpinned* — mechanically sound (`Preview` captures eagerly and retains nothing) but no fixture runs it; the row would carry two noise columns, `content` = "Opaque value" and `parent` = "3 fields" |
| 6 | extract members, re-compress each | `File(Emit: Units) → Extract → Write` | **works with the hidden switch** — `extract-write-test.yaml` |
| 7 | the one CSV inside an archive → pivot | `File(Emit: Units) → Extract → Read part → Summary` | **works with the hidden switch** — `extract-read-test.yaml`, `extract-migrate-summary-test.yaml` |
| 8 | ad-hoc processing (ITCH → index → graph → analysis) | plug-in format and/or plug-in source Worker + plug-in transforms | **works** (§7) |

The engine can already do nearly all of it. What fails is the surface: a hidden switch with internal
vocabulary (5′, 6, 7), one missing input type (4), one missing format (5), and a heavy idiom (3).

## 3. `File` only selects; the connection decides

### 3.1 Why `Emit` exists

Nobody designed it as a user-facing choice. The content-streaming analysis specified automatic container
detection (§5.2, §7: `container: auto`), the borrowed-elements plan deferred it (§3.10), and BE5 then found
that an archive could not even stay in a `File` selection — detection runs per file at manifest time in every
mode. `UndetectedFormat` and the *"set Emit to Units"* hint were the minimal patch
(`FileDataSource.kt:219-258`, `ConfiguredDataOpener.kt:153-159`). The plan's own follow-up list already reads
*"promote it, or select Units automatically when the downstream is `Extract`"* — unowned.

### 3.2 Proposal: `emit: auto`, resolved from the adjacent consumer

Add a third value, make it the default, and take the attribute off the card. `auto` resolves to `units` when
the adjacent downstream Worker consumes files, and to `items` otherwise. `items` / `units` stay valid in
notation as an explicit override.

**Where to resolve it.** A Worker cannot see its consumers today: `JobLaneContext` carries the graph structure
but it is the saved, pre-synthesis one (ports blank), and `JobValidator` folds lanes strictly downstream
(`JobValidator.kt:80-108`). Two candidate seams:

- **Channel synthesis (recommended).** `JobChannelDerivation.derive` already computes every
  `Connection(upstreamWorker, …, downstreamWorker, …)` and `JobChannelSynthesis` already rewrites an in-memory
  run-copy of the notation. Resolving `emit: auto` there is one more deterministic rewrite, visible to both
  the validator and the run, with no new Worker capability.
- **At insert time in the editor.** Inserting `Extract` or `Write` after a `File` writes `emit: units` into the
  notation. Simple and explicit, but it leaves stale state when the user later deletes or reorders the
  consumer, and it does nothing for hand-written notation.

**How a Worker declares "I consume files".** A notation-level marker on the archetype (for example
`consumes: files` on `Extract`, `Write`, `Read part`, `Run`), read by the synthesis step. Plug-in Workers opt in
the same way; no class-name list in shared code.

### 3.3 Consequences to settle

- **`Preview` and `Result` accept anything.** Under `auto` they get items. That is the intuitive reading
  ("show me what's in these files") and it is what makes case 5 work once §4 lands.
- **Fan-out does not exist yet** — one channel has one consuming view; fan-in is first-class, fan-out is
  marked "until J6" in `ReadWorker.kt:48`. So "two consumers that disagree" cannot arise today. When J6
  lands, the rule should be: disagreement is a validation error naming both consumers.
- **Manual wiring.** `derive` pairs only adjacent Workers with open ports. A manually wired `File` has no
  derived connection; `auto` then falls back to `items` and the explicit override is the escape hatch.
- **Live edits.** `emit` is part of `ReadWorker`'s `compatibilityKey`, so inserting an `Extract` after a
  running `File` restarts the read. That is already true of flipping the switch by hand.

### 3.4 The choice lives in the format picker (added after review, 2026-09-18)

Every file has a ladder of interpretations, most specific first, and the most specific is the default:

| file | most specific | fallback |
|---|---|---|
| `a.csv` | rows | whole file |
| `data.tar.gz` | listing of inner files (§4) | whole file |
| `one.csv.tar.gz` (a single file inside) | rows of the inner file | listing → whole file |
| `photo.jpg` | — | whole file (today's *Undetected*) |

The ladder **is** the **File format** picker, with one more option: **"Whole file (don't read)"**. So `emit`
is not a separate concept at all — `emit: units` is the *whole file* format. Consequences:

- the read is already visible where the user looks (the card's *"Automatic → CSV"* line), so nothing needs
  drawing on the connector;
- *Whole file* is a choice for the **whole source**, not per file (decided 2026-09-18): the source-level
  picker offers it, the per-file override (CSV vs TSV vs …) does not. Every file from one `File` source is
  then the same kind of element, so a lane never mixes rows and files;
- an unclaimed file stops being an error state: it settles on the *whole file* rung, which is what
  `UndetectedFormat` already means;
- *Automatic* still takes the adjacent consumer into account (§3.2): in front of `Write` or `Extract` it
  settles on *whole file*. The picker is where that is shown and overridden;
- going *inside* an archive stays `Extract` — that is no longer an interpretation of the selected file.

What remains of the mixed case: under *Automatic*, a selection holding both readable and unclaimed files
(`a.csv` + `photo.jpg`). The source reads, so the unclaimed file is an error naming it, with the two ways out:
remove it, or set the source to *Whole file*.

## 4. Reading an archive yields its table of contents

A tar listing is an ordinary record format and fits the existing extension seam with no change to `File`,
`Extract` or `Preview`:

- a `ConfiguredRecordFormat` in notation ("Archive listing", extensions `tar`, `tgz`), discovered by
  `ConfiguredRecordFormatRegistry` like the CSV family;
- a `ReaderCapability` whose cursor walks tar headers and yields one record per member — `name`, `size`,
  `modified`, `kind` — skipping the bodies;
- a `ReaderProbeCapability` returning `ReaderProbeStrength.ContentSignature` on `ustar` at offset 257. The
  probe sample for a `.tar.gz` is **already gunzipped** (`DetectionSampleAcquirer.kt:67-85`), so gzip needs
  nothing extra, and `commons-compress` is on the classpath.

`ConfiguredFormatExtensibilityTest` is the worked example of a contributed format winning on a content
signature; its pin *"binary that no format claims fails as not-text"* (:126-139) stays true — tar simply
stops being unclaimed. `UndetectedFormat` remains for everything still unclaimed (images, zip until it is
supported), and its wording moves to §8.

The listing is rows, not `Entry` values: it carries no `content`, so it can be sorted, kept in a `Result` and
exported, none of which a lent `Entry` allows. `tar -t` versus `tar -x`.

**The alternative considered** — `File` lends the members itself, so an archive's *items* are its entries —
makes `File(tar) → Read part → Summary` one step shorter but pulls the lending machinery into `File`, reverses
BE5's "one selector; what happens to files is downstream", and makes the listing un-retainable. Not
recommended.

## 5. One output, or one per input

Today: both row writers open their single file in `onStart`, before any row exists
(`CsvWriterWorker.kt:66-74`, `ExportWriterWorker.kt:99-106`; the Job export hard-wires `${group}` empty), so
no writer can split by row content. The working idiom is case 3's parent/child Job pair. It is general —
the child Job can do anything per file — but it is two documents for what users think of as one setting.

Two gaps stand between that and a flat `File → … → CSV Writer(path: out/${file}.csv)`:

1. **Origin does not travel with items.** `Attributes: As columns` prepends the unit's attributes, and for a
   `File` source those are only the `groupPattern` regex captures (`FileDataSource.kt:267-289`) — there is no
   built-in file-name or path column, and the option is silently inert on `Read part`'s `Entry` path
   (`ReadPartWorker.kt:246,253`). Proposal: every file contributes standard origin attributes (`file`,
   `path`, and for a member `archive`), with `groupPattern` captures added on top.
2. **Row writers cannot route.** Decided 2026-09-18: the destination is a **routing expression evaluated per
   row** — by input file (`out/${file}.csv`), by a value inside the data (`out/${symbol}/${date}.csv`), or any
   expression over the row and the Job parameters. A destination that references no row field is constant and
   keeps today's single-file behaviour. The writer holds one open file per distinct destination. Open files: by
   default **one**, and a destination that would need re-opening is an error (so input grouped by destination
   just works, and interleaved input fails clearly); the user can raise the limit. Details deferred until a
   concrete use case asks for them: the writer's result becoming a list of written files instead of one;
   whether the routing fields are also written as columns or dropped; and one expression language shared with
   `Formula` rather than a second `${…}` dialect (`Write`, `CSV Writer` and `Export` each have their own
   today).

A per-source `Summary` / pivot is the same idea on the items → items side: group by the origin column. No
nested scope is needed for any of it. The parent/child idiom stays for genuinely per-file *pipelines*.

## 6. `DataUnit` and `Entry` are one concept

| | `DataUnit` (on disk) | `Entry` (in an archive) |
|---|---|---|
| identity | parts with `DataRef` + resolved read spec, attributes | `name`, `size`, `modifiedEpochMillis`, `kind`, `parent` |
| bytes | re-openable by path | `content`, cursor-borrowed, one open, invalid once the source advances |
| accepted by `Extract` | yes | yes |
| accepted by `Read part` | yes (uses the unit's own format) | yes (uses the Worker's `format`, default CSV) |
| accepted by `Write` | **no** | yes |
| in `Preview` | one opaque value | a row with two noise columns |

The lifetime difference is real and must stay in the engine. The *surface* difference need not:

- `Write` should accept a `DataUnit` (case 4), and gain the static `payloadFlow` check its two siblings have.
  Its name pattern reads `Entry` fields only (`WriteWorker.kt:204-214`); a common descriptor (`name`, `size`,
  `modified`, `parent`) serves both.
- `Read part` detects format for a `DataUnit` but defaults to CSV for an `Entry`. A member deserves the same
  automatic detection; the bytes are sequential, so detection must work from the head of the one open stream.
- `Preview` over a files lane should show the descriptor columns and drop `content` / `parent`.
- User-facing name: **file**, everywhere. "Unit", "Entry" and "part" stay internal.

Whether the two classes merge in code is an implementation question for later; the list above is what the user
needs.

## 7. Plug-ins

Both seams exist and the ITCH work exercises both:

- **"What is inside this kind of file" is a format.** `kzen-sample-plugin` ships `ItchReaderCapability` +
  `ItchFormat`, registered through `ServiceLoader`, detected by content probe, gzip handled by the host. With
  it installed, `File(day.itch.gz) → …` yields typed message rows — the same slot the tar listing takes.
- **Anything else is a Worker.** `kzen-sample-embed-spring` defines `ItchSourceWorker`, a source over a host
  catalog service that downloads, indexes into a derived store and emits `DatedSymbolDay` batches; the
  analytics (`DatedTradeVolumeWorker`, `DatedOrdersWorker`, …) are plug-in transforms. The market-state graph
  is a core computation those Workers call, not a Worker itself.

The model in §1 places them without special cases: the ITCH source is a plug-in *source of items*; its
transforms are items → items. A plug-in Worker that wants whole files declares it the same way `Extract` does
(§3.2). The rule of thumb for authors: a **format** when the file's contents are a stream of records; a
**Worker** when there is state, preparation or a service behind it.

## 8. Vocabulary

The target reader has never seen the source. Proposed surface wording for the `File` card:

| today | proposed label | help line |
|---|---|---|
| Emit: Items / Units | *(removed; becomes the "Whole file" format, §3.4)* | |
| Format: Automatic | **File format** — Automatic / CSV / … / **Whole file (don't read)** | How to read the files. Automatic works it out from each file. Whole file passes them on unread, to copy or compress. |
| Missing | **If a file is missing** | Stop / Skip it |
| Directory + Filter | **Folder** / **Name filter** | Select every file in a folder whose name matches, instead of picking files one by one. |
| GroupPattern | **Label files by name** | A pattern over the file name; what it captures becomes a column on every row from that file. |
| Attributes: Ignore / As columns | **File labels** | Leave out / Add as columns |
| SchemaMode: Ordered superset / Strict | **When files have different columns** | Combine them / Stop |
| Role | **Part** *(hide unless a unit has more than one role)* | |

Status and error lines:

- *"Automatic → Undetected · text fallback"* → **"Not a readable format — can be passed on whole"**; with §4,
  an archive reads **"Automatic → Archive listing · file contents"**.
- The opener's refusal drops the `Emit` hint: **"data.tar.gz isn't a format this can read row by row. Add
  Extract to open it, or Write to copy it."**
- The *"Format Detection:"* prefix is not written anywhere: `ExceptionUtils.message` in kzen-lib derives it
  from the exception class name (`FormatDetectionException` → "Format Detection") for every paradigm. Changing
  it is a kzen-lib-wide decision (four call sites: `RunEngine`, `ExecutionResult`, `FlowRun`,
  `ScriptRunContext`); an opt-out for exceptions that carry a user-ready message is the narrow fix.

Mechanism, client and notation only:

- `meta.<attr>` is stored verbatim with no key whitelist (`NotationMetadataReader.readAttribute`), so
  `label:` and `description:` need no kzen-lib change — the same way `editor:` and `values:` are read today.
- `CommonEditUtils.formattedLabel` is the single origin of every label; its word split is a no-op on
  camelCase, hence "SchemaMode". Read `label:` first, and split camelCase as the fallback so every card
  improves at once.
- `description:` renders as a dim line in `AttributeEditorManager.render`, which already owns the per-field
  message slot. Per-option help reuses `SelectOption.detail`, which `MuiAutocompleteField` already renders
  and `SelectValuesEditor` does not yet feed.
- A declarative `advanced: true` replaces `FileSourceWorkerDisplay`'s all-or-nothing disclosure, so a card can
  keep its two or three everyday fields in the body.

## 9. Staged path

Each step stands alone and none forecloses the rest.

| step | what | touches | risk |
|---|---|---|---|
| 1 | tar listing format (§4) → case 5 works | new format + reader + probe in kzen-auto-jvm, notation, one test pin | low — existing seam |
| 2 | `emit: auto` via synthesis + `consumes: files` marker (§3) → cases 6, 7 lose the switch | `JobChannelSynthesis`, `ReadWorker`, archetype notation, fixtures | medium — new rewrite in the synthesis path |
| 3 | labels, help lines, `advanced:` (§8) | kzen-auto-js + notation | low |
| 4 | `Write` accepts a disk file, static lane check (§6) → case 4 | `WriteWorker` | low |
| 5 | standard origin attributes; `Preview` of a files lane (§5.1, §6) | `FileDataSource`, `ReadPartWorker`, `PreviewCapture` | low–medium |
| 6 | row writers route by origin (§5.2) → case 3 becomes flat | `CsvWriterWorker`, `ExportWriterWorker` | medium — open-file bound, result semantics |
| later | format detection for members; zip; first-class fan-out (J6) | | |

Steps 1–3 are the ones that answer the 2026-09-18 failure.

**As built (2026-09-18, kzen-auto).** Step 1: `ArchiveListingFormat` + `ArchiveListingReaderCapability`
(content-detected tar / tar.gz, one row per member: name, size, modified, kind) — pinned by `ArchiveListingTest`.
Step 2 differs from the table: no synthesis rewrite. `emit` defaults to `auto` and `JobReadEmit.effective` — one
common rule shared by `ReadWorker` and the client's column projection — settles it from
`JobChannelDerivation.consumerOf` and the `FileConsumer` marker archetype (`Extract`, `Read part`). `Write` is
**not** marked, because it still refuses a disk file (step 4). "Whole file (don't read)" is the `WholeFile`
format (`readsContent = false`), source-wide only — refused as a per-file override — pinned by
`WholeFileFormatTest`; `ExtractWorkerTest.fileLeftOnAutomaticHandsExtractTheArchiveWhole` replaces the old
"Emit to Units" pin. The `emit` field is hidden on the File card; it stays a notation override. No archive is
scanned by default: reading a single inner file through its archive remains an explicit `Extract → Read part`.
Step 3: `meta.<attr>.label` / `.description` / `.details`, applied to the File fields; `advanced:` was not
needed (the card already folds them under Advanced). No rename of Extract / Write.

## 10. Open questions

1. ~~Is implicit reading acceptable, or should it show on the canvas?~~ **Resolved (§3.4):** the read is the
   file's format, shown and overridden on the `File` card.
2. ~~`Preview` directly after `File`: items or a file listing?~~ **Resolved (§3.4):** the file's contents by
   default — rows for a CSV, inner-file info for an archive — with *Whole file* as the opt-out, chosen for
   the whole source.
3. ~~A single-member archive.~~ **Resolved (2026-09-18):** the same ladder (§3.4) — inner rows by default,
   listing and whole file selectable. Implementation cost to weigh: tar has no index, so *Automatic* can only
   know "exactly one file inside" by scanning the whole archive when the file is selected (a full
   decompression pass for a large `.tar.gz`). The explicit rung ("rows of the file inside") needs no scan and
   fails at run time if a second file turns up. **Decided: no scan by default** — *Automatic* settles on the
   listing for every archive; reading through a single inner file is the explicit rung.
4. ~~Where does "per input" belong?~~ **Resolved (2026-09-18):** on the writers, as a per-row destination
   routing expression (§5). The parent/child idiom stays for per-file *pipelines*.
5. ~~Naming.~~ **Resolved (2026-09-18):** `Extract` and `Write` keep their names.
6. ~~Zip.~~ **Resolved (2026-09-18):** on request, not scheduled.
