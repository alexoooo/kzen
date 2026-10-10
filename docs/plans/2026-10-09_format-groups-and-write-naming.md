# Format groups and Write naming — constituent plan (FG)

> **Status: landed 2026-10-09 (FG1–FG3); see §8.** Written with the user after running the two-file combine that
> WR5 verified (`File → Parse → Format(CSV) → Write(gz)`) and reading its cards. Reviewed the same day for
> needless complexity and shortcuts; six changes folded in (no transitional protocol, `""` as the ungrouped group,
> per-output encoder state, `format` carries only its extension, template parts from the Kotlin parser, Windows
> reserved names).
>
> **Relation to other documents:**
> - **Extends** [format-and-write](2026-10-07_format-and-write.md) (WR). WR's chain stays (`Format` turns records
>   into `Bytes`, `Write` puts `Bytes` in files). This plan replaces WR §4.2's output boundary (*consecutive equal
>   `name`*) with groups, and replaces both `${…}` name templates with Kotlin. WR8's live-edit rules carry over
>   to several open outputs.
> - **Uses** the Job expression compiler (`JobExpressionCompiler`, shared by Filter, Formula and Formula source)
>   and the Kotlin parser `KotlinSyntaxValidator` already runs (`KtPsiFactory`). No new expression mechanism.
>
> The [master ledger](2026-07-25_master-plan.md) owns sequencing (rows FG1–FG3). Each landed row appends its
> as-built under §8.

## 1. Symptoms (observed)

1. **Two fields called "Name", one per Worker.** `Format`'s `name` (default `output${extension}`) decides which
   records go into which output. `Write`'s `name` (default `${name}${extension}`) is the file's name, and by
   default it only passes `Format`'s through. To control the file name a user must understand that the two
   chain together.
2. **Help text in paragraphs.** Each `name` carries a paragraph-long description (`job-worker.yaml`, `Format` and
   `Write`) explaining placeholders that the insert menu already lists. They make up for the confusing pair of
   fields from symptom 1.
3. **Grouping only works on sorted input.** Records with the same name must arrive together. A name that comes
   back after another fails the run (*sort by what the name is built from first*).
4. **No footer.** `RecordEncoder` has `encodeHeader` and `encodeRecord`, nothing after an output's last record,
   so a format that closes its output (a JSON array, an XML root) cannot be written.
5. **Progress looks stalled.** While `Parse` was on the second file, `Format` showed nothing and `Write` showed
   `written=0 skipped=0`. Both were working: `FormatWorker` publishes no progress, and `Write`'s `written` counts
   only finished files, and a single output finishes only at end of stream. Both render through
   `WorkerDisplayDefault`'s generic `key=value` line.
6. **The extension is tangled.** `Format`'s `${extension}` is the format's extension; `Write`'s is the
   compression suffix. Together they give the right default (`output.csv.gz`), but each field has an
   `${extension}` that means something different.
7. **File names and folders share one string.** Whatever a placeholder resolves to is placed into the path
   as-is. A value containing `/` creates a folder or fails the stay-inside-the-directory check, and nothing on
   the card says which.

## 2. Root causes

- **A. `Format` names files.** The output's identity is a file-name string chosen upstream of the Worker that
  owns files, so naming is split across two Workers (symptoms 1, 2, 6).
- **B. The boundary is "the name changed".** An output is a run of consecutive chunks with the same name, so
  `Write` can hold only one output open, and `Format` cannot tell an output's end from a pause in it
  (symptoms 3, 4).
- **C. A one-off template language.** `FileNameTemplate` / `FormatName` are a small `${dotted.path}` grammar
  beside the Kotlin expressions every other Job field uses, so a name cannot do anything a path cannot
  (lower-case, a substring, a fallback).
- **D. No Format/Write display.** Only workers with their own display (`ParseWorkerDisplay` et al.) show progress
  in words.

## 3. Requirements

From the user (2026-10-09):

- **R1 — `Format` groups, `Write` names.** `Format` has a **Group by** Kotlin expression. Each group is one
  output, framed once: header before its first record, footer after its last. Each chunk carries the group and the
  format as metadata. `Format` has no name field.
- **R2 — Real grouping.** Records of a group may arrive anywhere in the stream. When Group by is set, a choice of
  how outputs end:
  - **at the end** (default): every group's output stays open until end of stream, so a group may return any
    number of times; each output is closed and published at the end;
  - **when the group changes**: for input arriving one group at a time; each output is closed and published as
    soon as the next group starts, and a group that returns fails the run.
  No format-specific tricks (gzip concatenation and the like): an output's stream stays open until its group is
  done.
- **R3 — No limits the user did not ask for.** No cap on open groups. A Job that opens more than the machine can
  hold fails with what the OS or JVM says, as a program would.
- **R4 — Footers, format-agnostic.** The encoder gets a footer hook. How an output ends is decided by the mode in
  R2. An expression for "this group is done" is out of scope until a use case needs it.
- **R5 — Ungrouped means an empty group.** Without Group by there is one output and the group is `""`. A default
  name must make sense for data that does not come from a file.
- **R6 — Kotlin, everywhere.** Group by and `Write`'s naming are Kotlin, compiled by `JobExpressionCompiler`, with
  the same scope as Filter and Formula (payload, metadata, Job parameters). Write's name fields are Kotlin string
  templates (settled 2026-10-09).
- **R7 — The extension is untangled.** Separate parts (the format's extension, the compression's), and an
  `extension` that combines them into the usual choice (`.csv.gz`, `.csv`) and is the default.
- **R8 — Folder, sub-folder, file.** `Write` separates the directory, an optional sub-folder, and the file name,
  so what creates a folder is visible on the card. Every value inserted into a name is sanitized. The default is
  simple; the expressions allow anything else.
- **R9 — Progress in words.** `Format` and `Write` say what they are doing while they do it, including when a live
  edit discarded output (§4.3).
- **R10 — No paragraphs of help text.** Remove the two `name` descriptions; check the other Job Worker help lines
  the same way.

**Non-goals.** Zip and other container compression (later; a container can have only one entry open at a time,
so it will only support "when the group changes"). An end-of-group expression. Changes to `Export` / `CSV Writer`.
Changes to the `Content` path beyond naming.

## 4. Design

### 4.1 Chunks carry their output

A group is exactly one output within a run (a returning group rejoins its open output, or fails the run under
`change`), so `Write` routes each chunk by its `group`, a `String`. Ungrouped, every chunk's group is `""`: one
output, by the same path.

What the group cannot say is when an output ends: under interleaving a different group no longer means the
previous one is done, and only `Format` knows (end of stream or group change, by its mode). So `Format` sets one
more mark on the chunk, as WR8's `headerLength` and `restartsOutput` already are:

- **`endsOutput`** — set on the chunk that holds the output's footer (possibly zero bytes, as CSV's is). `Write`
  closes and publishes that output when it arrives. Every output gets exactly one.

`Write` therefore holds a map from group to an open file and needs no mode of its own. At end of input, an output
still open without its `endsOutput` mark is a protocol error, reported by name. WR4's ended-target check stays:
two groups resolving to the same file fail the run by name. No records, no output (WR §4.2).

Chunk metadata becomes `{group, format, parent}`:

- `group` — the Group by result, a `String`; `""` without Group by.
- `format` — `{extension}`, the configured format's first extension without the dot (`csv`). Only what something
  reads; more fields when something needs them.
- `parent` — the record's metadata, as today. The footer chunk holds no record; it reuses the metadata object of
  its output's previous chunk. Nothing reads it (`Write` names an output and builds its `Written` from the first
  chunk), so this only keeps the chunk contract uniform and costs no allocation.

### 4.2 Framing

One encoder per `Format`, as today; what one output needs to remember is a separate, explicit object:

- `RecordEncoder.openOutput(): RecordOutputState` — the state of one output (e.g. "no record written yet", for a
  format that separates records). A format with none returns one shared stateless instance, so the delimited
  encoder allocates nothing per output.
- `encodeHeader(state, output)`, `encodeRecord(state, cells, output)`, `encodeFooter(state, output)`. The
  delimited encoder's footer is empty.

`Format` keeps one `RecordOutputState` per open group. Memory per group is what the format needs to remember,
not a copy of its buffers.

### 4.3 `Format`

Attributes: `input`, `output`, `format`, `columns` (unchanged), `groupBy` (Kotlin `String` expression, blank = no
grouping), `groupEnd` (`end` | `change`, shown only when `groupBy` is set; default `end`). `name` is removed.

- Per record: the group key is `groupBy`'s value, or the constant `""` when blank (no expression evaluated, so
  WR3's 0 B/record in `FormatAllocationTest` still holds). Compare with the previous record's key first (the
  common case), else look it up in the open groups (key → output state). A new key opens an output and encodes
  its header.
  - `end`: all footers in `onComplete`, in the order the groups opened.
  - `change`: on a key change, the previous group's footer chunk is emitted before the new group's first chunk. A
    key seen before fails the run: *Group 'x' came back after 'y'; set "Write each file" to "At the end", or sort
    by the group first.* Ended keys are kept for that check.
- `groupBy` is compiled once per input contract, as Filter's `where` is.
- **Live edit** (WR8 extended): the carried state is the open groups (key, output state) with the encoding
  digest, and the ended keys. An edit that keeps the digest *and* `groupBy` / `groupEnd` resumes every open group.
  Any other edit restarts every open group: the next chunk of each is marked `restartsOutput`, and `Write`
  discards what it held of it (WR8's "ends means discard").
  - **Reach of a discard.** Records before the edit are not read again, so a discarded output holds only what
    follows the edit. With one output (WR8) that was the file so far; under `end` it is every open group's file
    so far. The rule is unchanged; its reach grows.
  - **The user is told.** `Write` records each discard (when, how many outputs) in its progress, and its card
    says so (§4.5). Nothing is discarded silently.

### 4.4 `Write` naming

Attributes: `input`, `output`, `directory` (unchanged), `folder` (new, blank = none), `name`, `compression`,
`existing`.

- **`name` and `folder` are Kotlin string templates.** The field holds the body of a Kotlin raw string template:
  `${group}${extension}`, `$time` and `${parent.name}` are today's syntax and valid Kotlin, while
  `${group.lowercase()}` now works too. A body containing `"""` is a validation error. Compiled through
  `JobExpressionCompiler` against `Write`'s input contract (the metadata is in scope), once per contract, then
  evaluated once per output (at its first chunk), never per chunk.
- **Template parts come from the Kotlin parser** (`KtPsiFactory`, as `KotlinSyntaxValidator` uses): the string
  template's literal entries and its `$name` / `${…}` entries, exactly, whatever the expressions contain. The
  generated code passes each entry's value through the sanitizer; literal text is kept as typed and checked
  before Run.
- **`Write`'s own values** enter the expression scope as bindings beside the Job's parameters:
  - `compression`: `gz` or empty;
  - `extension`: for Bytes, `.` + `format.extension`, then `.` + compression when there is one; for Content, the
    compression suffix only, since the file's name already has its extension;
  - `time`: when the run started (`yyyyMMddTHHmmss`), as today.
- **Defaults.** A blank `name` resolves by input type, and the card shows the effective default as the field's
  placeholder:
  - Content: `${name}${extension}`;
  - Bytes: `${group.ifEmpty { "output" }}${extension}` — one rule, grouped or not.
- **Paths are made safe by one rule.** Each inserted value has `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|` and
  control characters replaced with `_`. Literal text is never rewritten: a literal `/` in `folder` separates
  folders; in `name` it is a validation error pointing at Sub-folder; any other of those characters typed
  literally is a validation error naming it. Every resulting segment (each folder, and the name) then has
  trailing dots and spaces trimmed, and a segment whose stem is a Windows reserved name (`CON`, `PRN`, `AUX`,
  `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`, any case, any extension) gets a `_` prefix. Empty, `.` or `..` fails the
  run by name. The same rule on every OS, so a Job written on one runs on another. The
  must-stay-inside-the-directory check remains as a backstop.

### 4.5 Progress

Progress keys live in a common conventions object (as `JobReadConventions` holds Parse's), and each Worker gets
a display, as `ParseWorkerDisplay` does, so neither renders through the generic `key=value` line:

- `Format`: records in, bytes out, and when grouped, groups open / done (*12,345 records · 3.1 MB · 4 groups*).
- `Write`: the file it is writing (or how many are open), bytes written to disk so far through a counting
  stream, files published, and skipped only when nonzero (*output.csv.gz · 18.4 MB*, then *1 file · 42.2 MB*).
  After a live edit discarded output: *An edit at 11:02 restarted 3 files; records before it are not in them.*

### 4.6 Cards

- `Format`: Format, Group by (Kotlin field with the insert menu and the inferred type, as Formula shows), then
  "Write each file" (*At the end* / *When the group changes*) only when Group by is set, then Columns.
- `Write`: Directory, Sub-folder, File name (insert menu; effective default as placeholder), Compression, If the
  file exists.
- `FileNameTemplateEditor`'s insert menu inserts Kotlin template references (`${group}`, `${parent.name}`,
  `${extension}`); its "This Worker" group lists `Write`'s bindings.
- No `description` on either name. Check every `description` / help line on Job Workers and their editors
  (`job-worker.yaml`, `WriterColumnsEditor`'s "every payload column (the default)"); keep only what a label,
  placeholder or menu hint cannot say, and list what was removed in the as-built.

## 5. Phases

Each row: implement, focused tests, full `cd ../kzen-auto && ./gradlew build`, as-built in §8. Notation:
update the test fixtures; for the user's own Jobs under `kzen-auto-jvm/src/main/resources/notation/main/`
(`Job.yaml`, `Job-1.yaml`), list what changes and ask before editing.

No row builds anything a later row replaces.

### FG1 — progress in words

- §4.5: `FormatWorker.progress`, `WriteWorker` bytes-so-far, open-file and discard progress; conventions object;
  `FormatWorkerDisplay`, `WriteWorkerDisplay` in `job-js.yaml`. The discard notice covers today's WR8 discard of
  the single output too.
- **Tests:** progress values over a two-output run (mid-output and finished); a live edit that discards reports
  it; JS display formatting.
- **Browser:** the user's two-file combine on a spare port — both cards move while `Parse` reads the second
  file.

### FG2 — `Format` groups, `Write` names

One row, because the two sides are coupled: `Format`'s name carries the extension that `Write`'s combined
`extension` adds, so landing either half alone would need a temporary change to the other.

- §4.1–§4.3: `endsOutput`, the footer hook with per-output state, `groupBy` / `groupEnd`, chunk metadata
  `{group, format, parent}`, `name` removed; `Write` holds a map of open outputs by group and publishes on
  `endsOutput`; WR8 live edit over several open groups.
- §4.4: string-template expressions for `name` and the new `folder` via the Kotlin parser, `Write`'s bindings,
  the safe-path rule, defaults by input type, for Content and Bytes.
- Delete `FileNameTemplate`, `FormatName` and their tests.
- **Tests — Format:** ungrouped two files → one output (header once, footer once); grouped by column on unsorted
  input under `end` → one file per value, each whole; same under `change` with sorted input publishes each file
  before the next group's records arrive; returning group under `change` fails with the message above; grouped
  by `parent.name` reproduces per-source output; a test encoder with a non-empty footer and per-output state
  across interleaved groups (one footer per output, after its last record); a missing `endsOutput` reported by
  name; live edit compatible (resumes all) and incompatible (restarts all, no partial file published, discard
  reported); WR3 / WR4 / WR8 suites green in what they assert about files; `FormatAllocationTest` still
  0 B/record ungrouped. **Measure:** grouped `Format` bytes/record (Epsilon, as WR6), recorded, not gated.
- **Tests — Write naming:** every `extract-*` and `write-*` fixture unchanged in output (fixtures with a
  `Format` name moved to Group by); values with `/`, `:`, trailing dots, and `CON` / `nul.csv` made safe in a name
  and in a folder segment; literal `/` in `folder` makes folders, in `name` is a validation error; a literal `:`
  is a validation error; `..` refused; a `}` or `/` inside a `${…}` expression's string literal parsed correctly;
  an expression error is the card's validation error before Run; `$time` across a live edit (as WR8 keeps it).

### FG3 — cards and help text

- §4.6, and `Job.yaml` / `Job-1.yaml` per the notation rule above.
- **Browser:** the user's case (ungrouped → `output.csv.gz`); Group by `parent.name` → one file per source;
  Group by a column with "When the group changes" on unsorted input shows the returning-group error on the card
  at run; Sub-folder `${group}` with a value containing `/`.
- **Docs:** kzen-auto `docs/architecture.md` (WR3 / WR4 paragraphs: groups and the end mark replace names) and
  the `AGENTS.md` gotcha "Records reach a file only through `Format → Write`".

## 6. Open questions

1. ~~**Card wording** for `groupEnd` (FG3)~~ — resolved in FG3: "Write each file: At the end / When the group
   changes" as written, with a menu hint on each.

## 7. Tracker

- [x] FG1 — progress in words (2026-10-09)
- [x] FG2 — `Format` groups, `Write` names (2026-10-09)
- [x] FG3 — cards and help text (2026-10-09)

## 8. As-built

### FG1 — progress in words (2026-10-09)

kzen-auto `./gradlew build` green (13 min), browser tests included.

- **Conventions:** `JobOutputConventions` (kzen-auto-common) holds the progress keys of both Workers, read by
  their cards out of the opaque progress map, as `JobReadConventions` does for Parse.
- **`Format`:** `progress` reports records encoded and bytes encoded (header included).
- **`Write`:** reports files published, skipped, bytes on disk (published files plus open outputs, through a
  `CountingOutputStream` below the encoder, so gzip counts compressed bytes), how many outputs are open, the open
  file's name while exactly one is, and `discards`: one `{at, outputs}` entry per live edit that discarded open
  outputs (WR8's single-output discard included).
- **Displays:** `FormatWorkerDisplay` and `WriteWorkerDisplay` (`job-js.yaml`) render through
  `OutputProgressText`: *12,345 records · 3.1 MB*; *output.csv.gz · 18.3 MB*, then *1 file · 42.2 MB*;
  *2 files · 3 open · 2 kB · 1 skipped*; and per discard *An edit at 11:02 restarted 3 files; records before it are
  not in them.*, at the browser's local time.
- **Tests:** `FormatWorkerTest` (records and bytes match what reached the sink); `WriteWorkerTest` (paused
  mid-output: one open, its name, bytes on disk, nothing published; at the end: one file, its size, no open name,
  no discards; a compression edit reports one discard of one output); `OutputProgressTextTest` (wording, plurals,
  local time).
- **Finding:** the first discard formatter used kotlinx-datetime's `TimeZone.currentSystemDefault()`; under karma
  it hangs ChromeHeadless (cause not pursued), so the browser test task never finished. `kotlin.js.Date` gives the
  browser's local time directly.
- **Browser** (the user's two-file combine, `File → Parse → Format(CSV) → Write(gz)`, on port 18093 from a scratch
  project): while Parse read the second file (b.csv at 30%), Format showed *2,495,328 records · 44.9 MB* and Write
  *output.csv.gz · 14.8 MB*, both moving; at the end Format *4,500,000 records · 84.5 MB* and Write
  *1 file · 27.3 MB*.

### FG2 — `Format` groups, `Write` names (2026-10-09)

kzen-auto `./gradlew build` green (13 min), browser tests included.

- **Chunk protocol** (`Bytes`): besides `headerLength`, a chunk is marked `endsOutput` (it holds the output's
  footer, zero bytes for CSV) or `discardsOutput`. Metadata `{group, format: {extension}, parent}` (`ChunkMetadata`,
  whose `shape` is cached per parent contract); the footer chunk reuses its output's last metadata.
- **Framing:** `RecordEncoder.openOutput(): RecordOutputState` (`RecordOutputState.Stateless`, shared, for a format
  that remembers nothing) and `encodeHeader` / `encodeRecord` / `encodeFooter`, each taking the output's state.
  The delimited encoder is stateless and its footer empty.
- **`Format`:** `groupBy` is compiled by `JobExpressionCompiler` against the input contract, once per contract;
  the group is the value's text (`toString()`, so a null is `"null"`). Blank evaluates nothing: every record's group
  is the constant `""`. `FormatGroups` holds the open outputs in the order they opened (key → state, last
  metadata), the ended keys, the last group (checked first) and the done count; `FormatChunker.chunk(record,
  ordinal, out)` adds one chunk, or under `change` the previous group's footer chunk first. A returning group under
  `change` fails with *Group 'x' came back after 'y'; set "Write each file" to "At the end", or sort by the group
  first*. The encoding digest covers format, columns, header, `groupBy` and `groupEnd`; a live edit that keeps it
  resumes every open output, any other gives each up.
- **`Write`:** `folder` and `name` are Kotlin raw string templates (`WritePathTemplate`). The parts come from
  `KotlinSyntaxValidator.rawStringTemplate` (the PSI entries of `val probe = """…"""`; `"""` in a body is refused);
  the generated template passes each inserted expression through `WritePathTemplate.inserted`, which applies
  §4.4's character rule; literal text is checked before Run (a `/` in File name: *File name: '/' would make a
  folder; put folders in Sub-folder*). Then per segment: trailing dots and spaces trimmed, a device-name stem
  prefixed with `_`, and empty / `.` / `..` failing the run: *File name resolved to '…'; '…' cannot name a file*.
  `compression`, `extension` and `time` are text bindings that take the place of a Job parameter of the same name.
  Defaults: Content `${name}${extension}`, Bytes `${group.ifEmpty { "output" }}${extension}`. Open outputs are a
  map by group; each is published on its `endsOutput`. Two groups resolving to one file fail with *'merged.csv' is
  written by group 'a.csv' and again by group 'b.csv'*. Input ending with an output still open fails with *Input
  ended before the end of 'x.csv'; its producer marks the end of each output*. Live edit (WR8 over many outputs):
  an edit to `directory` / `folder` / `name` / `compression` discards every open output; each starts again with its
  group's next chunk, behind the header its first chunk had. Each discard is counted in progress (FG1).
- **Deleted:** `FileNameTemplate` and `FormatName`. Their cases lived in `WriteWorkerTest` and
  `FormatAllocationTest`, rewritten below. The JS editor's stale reference to the `FileNameTemplate` grammar goes
  in FG3 with the editor.
- **Notation:** `job-worker.yaml`: Write gains `folder` (Sub-folder) and a blank `name` (File name), both with the
  placeholders `extension`, `compression` and `time` and no description. Format loses `name` and gains `groupBy`
  (Group by) and `groupEnd` (Write each file: *At the end* / *When the group changes*). Fixtures: Format names
  became Group by (`format-column`: `group`); Write names that held a `/` were split into Sub-folder + File name
  (`extract-inner`, `extract-two`, `extract-nested`, `extract-time`). New: `write-unended.yaml`,
  `ChunkEndDropWorker` (a test pass-through that drops end chunks), and `bench-job-format-grouped.yaml`. The user's
  `Job.yaml` (Format with defaults) and `Job-1.yaml` (`${name}_${time}${extension}`, valid Kotlin over Content)
  need no change.
- **Tests:**
  - `FormatChunkerTest`: a test encoder with per-output state and a non-empty footer, over interleaved groups:
    one footer per output, after its last record. Under `change`, each footer comes before the next group's first
    record, and a returning group fails.
  - `FormatWorkerTest`: unsorted groups → one whole output each, ended at the end; `change` on sorted input; the
    returning group fails the run; grouped by `parent.name` follows the source; a Group by that does not compile
    is refused before Run; group progress.
  - `FormatAllocationTest`: still 0 B/record ungrouped.
  - `ChunkMetadataTest` (rewritten).
  - `WriteWorkerTest`:
    - groups in any order → whole files; `change` → each file whole as it ends; a returning group fails;
    - two groups → one file refused; an empty name refused; a missing end reported by name;
    - inserted `/`, `:`, trailing dots, `CON` and `nul.csv` made safe in a folder and a name; a literal `/` in
      Sub-folder makes folders, in File name is refused before Run; a literal `:` refused; `..` fails by name;
    - a `}` and a `/` inside an expression's string literal parsed as part of it; a compile error is the Worker's
      validation error;
    - `$time` unchanged across a live edit;
    - grouped live edits: `existing` keeps every open output; Format's columns and Write's compression each
      discard both open outputs, report the discard, and publish only the rows after the edit;
    - WR3 / WR4 / WR8 cases kept (gzip's `Written` name is now `output.csv.gz`; chunk counts include the footer
      chunk).
  - `ExtractWorkerTest`: see the first finding.
- **Measured** (Epsilon slope as WR6, one pass, one JVM per point, not gated): S4 `job-format-write`
  ≈ 3,829 B/row, the new `job-format-grouped` (S4 grouped by `cat`, four files) ≈ 4,397 B/row, Report ≈ 2,010.
  Grouping costs ≈ 570 B/record (the expression's evaluation and its text), above one pass's ≈ 250 B/row noise.
  The four grouped files together are the ungrouped file plus three headers (checked by the benchmark).
- **Findings and deviations:**
  1. **§4.4 vs the FG2 test line.** Sanitizing every inserted value (R8) changes two `extract-*` outputs, which the
     test line expected unchanged. Under `${path}`, the member `sub/data.bin` now writes `sub_data.bin.gz`, and
     `../escape.txt` writes `.._escape.txt.gz` inside the directory instead of failing the run. §4.4's rule was
     followed. If an archive's folders should come out as folders, the alternative is to let an inserted `/` split
     folders in Sub-folder only.
  2. **Discard as its own chunk.** §4.3 marks the group's *next* chunk `restartsOutput`. Built instead: a zero-byte
     `discardsOutput` chunk per open output at the edit, so `Write` drops it at once even if its group never comes
     back. A returning group then starts a new output with the new header.
  3. **Write's own edit restarts behind the old header.** The header is right for any format. The records after it
     are right only for a format whose per-output state after the header is its initial state, as the delimited
     encoder's is. A future format with per-output state would need `Format` to restart the output instead. No
     such format exists yet.
  4. A compile error inside `${…}` can quote the generated `WritePathTemplate.inserted(…)` call around the
     expression.

### FG3 — cards and help text (2026-10-09)

kzen-auto `./gradlew build` green (11 min), browser tests included — after fixing flaky test timeouts. The first
two builds were red on timing guards only: `ScriptNestedMoveToTest` (*Run did not reach Paused (was Stepping)*,
also on the committed `HEAD`) and `OwnedSourceRouteTest` (*the source never evaluated its stream*). Each wait
had 5–30 s to cover a run that can compile Kotlin on its way (a cold FormulaStep step took 56 s). Every wait for
something a test expects now uses one hang guard, `hangGuardMillis` (`server/util/HangGuard.kt`, 120 s); the
per-class copies (`runTimeoutMillis`, `latchTimeoutSeconds`, `waitSeconds`, …) are gone, and the kzen-auto
`AGENTS.md` rule names it. Deadlines that are themselves the assertion (the stall warning, a close that must not
happen) keep theirs.

- **One Kotlin field editor.** `FileNameTemplateEditor` became `KotlinFieldEditor` (renamed, rewritten), registered
  in `job-js.yaml` and chosen per attribute by `editor: KotlinFieldEditor` in `job-worker.yaml`: Format's Group by,
  Write's Sub-folder and File name. `meta: template: true` (Sub-folder, File name) makes it a string template, so an
  insert is `${ref}`; otherwise (Group by) it inserts the bare reference. The insert menu lists the input's columns
  (top-level scalars), then its metadata's scalar paths to depth 3 grouped by level (*From parent*: `parent.name`,
  `parent.path`, …), then the Worker's own placeholders (*This Worker*). References are named as
  `JobExpressionCompiler` names properties (`ExpressionUtils.escapeKotlinVariableName`, so `` `max temp` ``); a
  metadata root that shares a column's name is offered as `meta.<name>`, and a root metadata field named `meta` is
  left out (the qualifier hides it). The old `columnPlaceholders` flag and the editor's own grammar check went with
  it.
- **Validation details for a field.** `JobFieldConventions` (kzen-auto-common) keys two facts in a Worker's
  `StepValidation.details`: `<attr>.default` (what a blank field stands for) and `<attr>.type` (the expression's
  `DataContract`, as its execution value). `WriteWorker` gives File name's default once the input lane is known
  (`${name}${extension}` or `${group.ifEmpty { "output" }}${extension}`), shown as the field's placeholder under a
  raised label; `FormatWorker` gives Group by's type, shown under the field (*Text*, as Formula shows its type).
- **Format card.** `FormatWorkerDisplay` observes the notation and hides "Write each file" until Group by holds a
  value (`WorkerDisplayDefault.hiddenAttributes`, as `ParseWorkerDisplay` does).
- **Help text.** Removed: Parse's `role` description (the field only shows when parts apply) and Columns'
  "(the default)" (`WriterColumnsEditor`). Added: menu hints on Write each file — *At the end*: "Each group's file
  stays open until the input ends"; *When the group changes*: "For input sorted by the group: a group that comes back
  stops the run". Kept, as saying what a label cannot: the menu hints of Compression, If the file exists, Parse's
  schema mode and emit. Neither name carries a description.
- **Docs:** kzen-auto `docs/architecture.md` "Bytes and Format" and "Write over Bytes" rewritten for groups,
  `endsOutput`, the templates, the safe-path rule, the defaults and the live edit's `discardsOutput` chunk; the
  `AGENTS.md` gotcha "Records reach a file only through `Format → Write`" rewritten (Group by, `KotlinFieldEditor`,
  `template: true`, `JobFieldConventions`).
- **Notation:** the user's `Job.yaml` and `Job-1.yaml` need no change (see FG2).
- **Tests:** `KotlinFieldEditorTest` (columns, then metadata by level, then the Worker's own; a metadata field named
  as a column is reached through `meta.`; a template inserts inside braces); `FormatWorkerTest`: Group by gives its
  type before Run (`parent.name` → Text; blank gives none); `WriteWorkerTest`: a blank File name stands for the
  Bytes default before Run.
- **Browser** (scratch project on port 18094; `a.csv` and `b.csv`, 1,000 rows each, cities `c0`–`c2` interleaved):
  - Ungrouped: File name shows `${group.ifEmpty { "output" }}${extension}`; Write each file hidden. Run: Format
    *2,000 records · 22.9 kB*, Write *1 file · 4.9 kB* → `output.csv.gz`.
  - Group by from the insert menu (*Columns* `id`, `city`, `value`; *From parent* `parent.name`, `.path`, `.size`,
    `.modified`): inserting `parent.name` shows *Text* below the field and brings Write each file back; clearing it
    hides it again. Run: Format *… · 2 groups*, Write *2 files · 9.6 kB* → `a.csv.csv.gz`, `b.csv.csv.gz`.
  - Group by `city`, When the group changes, unsorted input: the run fails at *Record 4: Group 'c0' came back after
    'c2'; set "Write each file" to "At the end", or sort by the group first*; no file published.
  - Group by `"x/" + city`, Sub-folder `${group}`: `x_c0/x_c0.csv.gz`, `x_c1/…`, `x_c2/…` — an inserted `/` is
    made safe (FG2 finding 1).
  - The last two ran through `/logic/startRun` after the browser extension stopped capturing the page.
- **Findings:**
  1. Grouped by `parent.name`, the default name gives `a.csv.csv.gz`: the group is the source's file name and the
     default adds the format's extension. As planned; a user who wants `a.csv.gz` writes File name
     `${group.substringBeforeLast('.')}${extension}`.
  2. The insert button is aligned with the field's top, so the type shown below the field does not push it down.
