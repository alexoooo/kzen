# Review 1: automatic data-format detection and safe text fallback

> **Status: review.** Assessment of [`2026-09-02_data-format-detection.md`](2026-09-02_data-format-detection.md)
> against the product goal stated for the Job data-selection experience: a "swiss army knife" that makes easy
> things easy, lets moderate complexity be handled from the UI, and leaves high complexity to contributed code.
> Grounded in the current `ConfiguredRecordFormat`, `FileDataSource` and `FileSelectionEditor` code and in the
> settled decisions of [`2026-08-29_data-reading.md`](2026-08-29_data-reading.md).

## 1. Overall assessment

The problem is real and correctly diagnosed. The File source stamps an invisible `ConfiguredCsv` default on every
selection, the selection row and card do not show it, and a parser-level failure (`Field name must not be empty`)
is reported as though the user had configured CSV. The analysis is right that narrow fixes (skip blank records,
filename-only detection, try-until-no-throw) would improve the incident and leave the product defect intact.

The resolution architecture should ship largely as written:

- the split between **explicit means strict** and **automatic means explainable** is the right axis;
- **per-part resolution** with reconciliation through the existing `strict` / `superset` schema policy is right;
- **provenance outside `DataPart.digest()`** keeps migration and cache identity semantic;
- an **optional `ReaderProbeCapability`** beside `ReaderCapability` is consistent with the plugin story and avoids
  concrete-name dispatch; and
- **detection completes before `DataPart` construction** so the opener and the streaming cursor are unchanged.

The pushback below is on the product rules inside that architecture. Several are tuned for principled purity
rather than for the office files a swiss-army knife will actually meet, and the middle "customize via UI" tier
has a gap where the everyday mess of real CSV lives.

## 2. Pushback

### 2.1 Strict UTF-8 with no legacy fallback fails the most common office file

§7.2 decodes with strict UTF-8 when no BOM is present and refuses to guess legacy code pages. Excel on Windows
still exports plain "CSV" as Windows-1252 unless the user explicitly picks "CSV UTF-8". One accented name in an
ordinary export therefore stops with "choose an encoding", on the file type the immediate tier exists to serve.

Windows-1252 decoding is lossless and reversible: every byte maps to one character, so nothing is discarded and
the original bytes are recoverable. That is exactly the loss-minimizing property §1.3 and FD7 use to justify the
plain-text-lines fallback. The same principle should apply here:

1. strict UTF-8 first;
2. on the first malformed sequence, Windows-1252 with a visible warning and the encoding shown in the row; and
3. never byte-frequency guessing of any other code page.

This is not probabilistic charset detection, which stays deferred. It is one deterministic fallback with one
deterministic warning, mirroring the text fallback.

### 2.2 Known text extensions short-circuit content probing

§4.1 makes `.txt`, `.md` and `.log` direct plain-text matches. Precedence rule 3 (validated exact-extension
candidate) then beats rule 4 (content match), so a tab-delimited `data.txt` export opens as one column of lines.
Tab-delimited `.txt` is a very common export shape.

A known text extension should suppress the fallback *warning*, not skip the structured probes. Concretely: run
the structured candidates as usual; if one is strong, use it; otherwise resolve to Plain text with no warning
because the extension said text. The precedence list needs `.txt`-class extensions to be a weak hint rather than
a validated candidate.

### 2.3 Falling a malformed `.csv` back to lines goes the wrong direction

§4.2 resolves `orders.csv` with inconsistent widths to Plain text with a warning. The user named it CSV. Turning it
into a `Record(line: Text)` contract quietly changes what every downstream Worker sees, and a per-row warning is
easy to miss once the Job has many sources.

For an extension hint that fails validation, the useful outcome is a diagnostic naming the row and the expected
versus observed width, with the corrective dials (§2.4) one click away. Lines fallback should be reserved for
input with no structured hint at all. This also removes the odd asymmetry in the current text: an explicit CSV
selection fails strictly, but a `.csv` extension in Automatic mode silently becomes something else.

### 2.4 The middle tier has a hole where real CSV mess lives

§11.2 defers "a universal quarantine or malformed-record recovery system" wholesale, and skip-lines is never
mentioned. Yet the everyday moderate cases are precisely:

- preamble lines before the header (Excel exports, instrument logs, bank statements);
- footer, total or notes rows after the data;
- ragged rows from trailing commas or a notes column that is usually empty; and
- comment lines with a fixed prefix such as `#`.

None of these needs a universal quarantine subsystem. A few dials on the configured delimited format cover most
of it:

| Dial | Values | Note |
|---|---|---|
| Skip leading lines | integer | Header row is read after the skip |
| Comment prefix | optional string | Lines starting with it are ignored |
| Ragged-row policy | `fail` / `pad` / `truncate` | `fail` remains the strict default |
| Malformed-record policy | `fail` / `skip` | Already contemplated by FR18 and open question 4 of the data-reading analysis; `skip` reports a count |

This is what "customize via UI" should mean for this feature. Without it, the middle tier collapses to "pick a
different named format", which does not help with any of the cases above.

### 2.5 Correction should be one click, not "author a concrete format"

§7.4 will keep `name;city` as a data row for any all-text table, because the content-only header rule requires
type contrast. Retention over guessing is defensible. The remedy offered, "select or author the concrete
header-bearing format", is heavy for the most common correction a user will make.

The per-file override (§4.3) should expose the small dials directly: at minimum a "first row is header" toggle
and a delimiter choice, plus encoding. A format-identity picker alone means the user has to know that
"CSV without header" is a separate catalogue entry, or has to leave the Job to author one.

Semicolon and Pipe as named catalogue entries are fine as detection candidates, but the override UI should surface
them as a delimiter dial on one reader rather than as four unrelated formats.

## 3. Additions

### 3.1 A "pin" action from automatic to explicit

The resolution result already contains the concrete `ResolvedReadSpec`. A one-click "make this explicit" that
writes it as the per-file (or source-level) override is the bridge from the immediate tier to the repeatable typed
tier. It also protects a saved Job from a replaced file silently changing shape: with Automatic authored, a file
that is replaced by one of a different width changes the contract and breaks downstream expressions at run time,
with no authoring change to point at. FD6 (keep Automatic authored) is right as the default; pinning is the
explicit opt-out.

### 3.2 Aggregate detection cost for scanned directories

§6 bounds probe cost per file: 256 KiB, 100 records, two seconds. It does not bound cost per source. A directory
scan (`directory` + `filter` with no explicit `files`) of thousands of files pays a bounded read and up to the time
limit each, serially, inside `FileDataSource.resolve`. The first run on a large scan is unusable and the warm cache
does not help until it has been populated once.

State a source-level rule before implementation, for example: probe in parallel under a shared budget; or, for
scanned selections, probe the first N files and apply the majority result to the rest with a diagnostic naming the
files that were not probed. Either preserves per-part identity; the second trades some explainability for a
usable first run.

### 3.3 List `.xlsx` in the deferred scope

For office automation, Excel workbooks will be requested before TSV or pipe-delimited data. They fit the model as a
container with a sheet-selection part decision, the same shape as ZIP in §7.1. Naming that now keeps a future
contributor from bolting sheet handling onto the delimited reader or onto `Automatic`.

### 3.4 Reframe the motivating example

Markdown as lines is a rare Job input. The leading-blank-line Markdown incident is a fine regression fixture, but
as the problem statement it sets the wrong priorities. Leading with Excel-exported CSV (Windows-1252, ragged,
preamble), tab-delimited `.txt`, semicolon CSV from European locales, and log files (lines feeding a later regex
extraction) would make §2.1 through §2.4 above fall out of the problem definition.

## 4. Confirmed as-is

- The tie rule (equal-strength structured candidates never resolve by registration order) is sound.
- "One-column parsing is never evidence of a delimiter" is sound. A single-column extensionless file becoming
  lines is acceptable because the `.csv` case is covered by extension validation.
- Fingerprint-keyed cache with the canonicalized candidate set, and never caching operational failures, are right.
- Selection-time detection as preview with per-row epochs, and run-time resolution as authority, are right.
- Keeping `Automatic` out of the candidate set so the graph cannot recurse is right.
- The header-label validation before `FieldId` construction, with row and one-based column in the message, is the
  right fix for the original exception regardless of the rest.

## 5. Recommended changes before implementation

| # | Change | Affects |
|---|---|---|
| R1 | Windows-1252 as a deterministic, warned fallback after strict UTF-8 | §7.2, FD2, acceptance §12.1 |
| R2 | Known text extensions are a weak hint that suppresses the warning, not a candidate that skips probing | §4.1, §2 precedence |
| R3 | A `.csv`-class hint that fails validation reports the row and width mismatch instead of falling to lines | §4.2, §8.2, §9, acceptance §12.1 |
| R4 | Add skip-lines, comment prefix, ragged-row and malformed-record dials to the configured delimited format | §4.1, §11.1, FR18 |
| R5 | Per-file override exposes header toggle, delimiter and encoding, not only a format identity | §4.3, §8.2, FD8 |
| R6 | Add a "pin" action that materializes the resolved spec as an override | §4.3, §8, FD6 |
| R7 | State a source-level probe budget or sampling rule for scanned directories | §6, §5.4 |
| R8 | List `.xlsx` under deferred scope as a container/part decision | §11.2 |

R1 through R5 change the shape of the configured delimited format and the per-file override model, so they belong
in the design before sequence step 1 of §13 starts. R6 through R8 can land in the design now and be implemented in
sequence step 3 or later.
