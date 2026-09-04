# Automatic data-format detection and safe text fallback

> **Status: proposed.** This analysis extends
> [`2026-08-29_data-reading.md`](2026-08-29_data-reading.md) after the configured reader arc landed on
> 2026-09-01. It preserves that design's provider-neutral content stack, immutable resolved-read identity,
> bounded inspection, typed `DataContract` / `DataValue` boundary and strict configured formats. It supersedes
> only the blanket exclusion of automatic format and header detection: inference is permitted inside the explicit
> `Automatic` authoring mode under the conservative rules below. A user-selected concrete format is never guessed,
> repaired or silently reinterpreted. This revision incorporates the accepted findings and resolves the disputed
> points from the completed review pass.

## 1. Problem definition

### 1.1 The immediate failure

The File worker currently gives every selection the inherited `ConfiguredCsv` format unless the user opens
Advanced and chooses something else. The file browser accepts arbitrary files, but neither the selection row nor
the collapsed card communicates that CSV has been chosen.

A representative regression is a Markdown file whose first byte is a newline. The configured CSV reader uses
`header: present`, so the first physical record becomes the header. That record contains one empty field;
`ConfiguredDelimitedReader` passes the empty label into `FieldId`, and the Worker fails with:

```text
Data: Field name must not be empty
```

The exception is internally accurate, but the user did not choose CSV, did not say the file had a header, and is
not told which assumption produced the error. Removing the first blank line only postpones the mismatch: later
Markdown lines may contain commas or quotes and fail CSV width or syntax rules. Improving this one exception would
therefore leave the product defect intact. The same defect reaches more ordinary office inputs in less obvious
forms: an Excel-exported CSV may use a regional semicolon delimiter or a legacy Windows encoding, a tabular
`.txt` export may be TSV, and a log may be either line-oriented text or consistently delimited records. These are
the priority cases; Microsoft documents both the [regional CSV separator](https://support.microsoft.com/en-US/Excel/get-started/import-or-export-text-txt-or-csv-files)
and [tab-delimited `.txt` export](https://support.microsoft.com/en-us/excel/save-a-workbook-to-text-format-txt-or-csv).
The Markdown incident remains the smallest fixture that proves the invisible default is gone.

### 1.2 The product mismatch

kzen's intended product gradient is:

| Use | Expected experience |
|---|---|
| Ordinary file manipulation | Select data and get a useful preview without understanding parser configuration |
| Repeatable typed work | Select or author an explicit format and schema, then fail strictly on drift |
| Heavy data / CEP | Stream bounded-memory values with stable contracts, deterministic identity and backpressure |
| Specialized formats | Contribute capabilities without adding branches to generic source or Job code |

The runtime foundation already supports the last three properties, but the immediate tier is incomplete. A
generic file chooser followed by an invisible CSV default is neither automatic nor explicit: it guesses without
evidence, then reports the chosen parser's low-level failure as though the user had configured it.

This creates four related problems:

1. **Wrong default.** File extension, media hints and content are ignored when the source chooses its reader.
2. **Unsafe recovery.** There is no lossless representation for valid text that is not confidently tabular.
3. **Poor explainability.** The UI does not show what was detected, why, or how to override it.
4. **Mixed-input friction.** The selected-file model already carries per-file format and encoding values, but the
   server ignores them, so one exceptional file requires a separate source.

### 1.3 What “simple stuff should just work” means

It does not mean every byte sequence must be forced through the parser with the highest score. That would turn
convenience into silent data corruption. It means:

- a normal CSV or TSV opens as a table with no extra authoring, including a regional semicolon `.csv`;
- a tab-delimited `.txt` export is recognized while ordinary `.txt` remains lines;
- a likely Windows-1252 office export can open with an explicit warning instead of mojibake or replacement;
- common semicolon- and pipe-delimited data is recognized from a bounded sample;
- Markdown, ordinary text and non-tabular logs open as a one-column line stream;
- a mixed selection resolves each file independently;
- the UI exposes each choice and its evidence before a run;
- an unusual case can be corrected per file without changing the other files; and
- binary, undecodable or structurally claimed ambiguous input stops with a useful next action.

The safe record-format fallback is therefore **plain text lines**, not an arbitrary structured parser. Falling back preserves
the source text and makes no field-boundary claim beyond line framing. It is safe only after the bytes have been
classified as decodable text under a known or deliberately selected character encoding. Choosing a legacy
encoding is a separate, potentially lossy inference and is never justified merely by the fact that some decoder
can map the bytes.

### 1.4 Why narrow fixes are insufficient

The following changes would improve the incident but not solve the product problem:

- skipping leading blank records would silently discard real data and still parse Markdown as CSV;
- deriving the format from the filename alone would fail on renamed, extensionless and mislabeled files;
- trying delimiters until one parser does not throw would accept many one-column false positives;
- silently treating every failure as lines would hide malformed data when the user explicitly selected CSV;
- detecting during every cursor open would put inference on the hot path and weaken migration/cache identity; and
- hard-coding CSV/TSV/Text branches in `FileDataSource` would close the extension point to plugin readers.

The correction must make automatic selection an explicit capability with bounded evidence, a deterministic
result and visible provenance.

## 2. Decision

Add `Automatic` as the default File-source format. It resolves each file independently during source resolution,
using content fingerprints, provider hints and a bounded decoded sample. The outcome is a concrete immutable
`ResolvedReadSpec`; execution uses that concrete reader directly and performs no detection.

Resolution first applies a per-file override, then an explicitly selected source-level concrete format. Both are
strict. `Automatic` then classifies filename/media hints as structured-family, generic-text, semantic-text or
absent and combines that evidence with the installed probes:

| Evidence in `Automatic` | Outcome |
|---|---|
| Semantic text hint such as `.md` | Plain text without structured probing |
| Structured-family hint and one compatible structured candidate | That candidate, with any dialect deviation explained |
| Structured-family hint and a contained syntax/schema/width failure, with no compatible structured candidate | Actionable failure; never lines |
| Structured-family hint and an unresolved strongest tie | Actionable ambiguity; never registration-order choice or lines |
| Generic text hint and one unique strong structured match | That structured candidate |
| Generic text hint and no strong structured match | Plain text without warning |
| No format hint and one unique strong structured match | That structured candidate |
| No format hint and no strong structured match | Plain text with fallback provenance when the bytes are valid text |
| Binary, undecodable, timed-out or budget-exhausted input | Actionable failure |

A `.csv` hint identifies a delimited-data family rather than proving comma specifically: a validated semicolon
dialect may win with a warning because regional spreadsheet exports legitimately use it. A generic `.txt` or
`.log` hint does not suppress structured probing. A semantic `.md` hint is authoritative because probing a
Markdown table as pipe-delimited data would discard the surrounding document meaning.

`Automatic` remains the authored value after detection. Detection never sends a notation command. The UI shows
the concrete result, basis and warning per file, and permits an explicit per-file override.

## 3. Product invariants

1. **Explicit means strict.** A concrete user-selected format never falls back to another reader. Its syntax,
   header, schema and decode failures remain failures.
2. **Automatic means explainable.** Every successful automatic resolution identifies the concrete format and
   whether extension, content or fallback selected it.
3. **Fallback is loss-minimizing.** Valid unrecognized text becomes lines. A structured-family hint that proves
   malformed or ambiguous does not silently change contract to lines, and binary-looking or undecodable content
   does not become guessed text.
4. **Resolution is per part.** A source may contain CSV, TSV and text parts; existing `strict` / `superset` schema
   policy decides whether their resulting contracts can share a lane.
5. **Detection is bounded.** Per-part and aggregate source probe cost are independent of total file size/count and
   observe the same cancellation, fingerprint and expanded-byte controls as inspection.
6. **Execution is deterministic.** The manifest carries the concrete reader config and coding chain; the opener
   never reruns detection.
7. **Detection is open-ended.** A new format opts into a probe capability. Generic code never compares a reader,
   format or extension against a closed concrete-type list.
8. **No background edits.** Selecting or inspecting a file updates transient resolution state only. Applying a
   correction, making a result explicit or locking its columns is an intentional notation command.

## 4. User-facing behaviour

### 4.1 Built-in formats

The initial catalogue contains:

| Format | Purpose | Automatic role |
|---|---|---|
| Automatic | Resolves a concrete format for every part | Default source selection |
| CSV | RFC-4180-style comma-delimited records | Extension-validated and content-detectable |
| TSV | Tab-delimited records | Extension-validated and content-detectable |
| Semicolon-delimited | Common regional/export format | Content-detectable; extensions may be authored |
| Pipe-delimited | Common interchange/log format | Content-detectable; extensions may be authored |
| Plain text | One `line: Text` field per physical line | Semantic text extensions, generic-text no-match and universal text fallback |

Authored configured-delimited formats participate when their reader exposes probing. A schema-bearing authored
format may win only when its declared header/schema and sampled values validate; detection never weakens or
rewrites that declaration.

Filename hints have different strength. `.md` is initially a semantic-text hint and resolves directly to Plain
text; this avoids mistaking a Markdown table for a pipe-delimited dataset. `.txt` and `.log` are generic-text
hints: structured candidates still probe them, and a no-match resolves to Plain text without a warning. `.csv`
and `.tsv` are structured-family hints: they must resolve to a compatible structured reader or fail. A `.csv`
may validate as comma- or semicolon-delimited; the latter result explains the regional-dialect deviation.

This classification belongs to contributed format metadata, not a filename `when` inside `Automatic`. A plugin
may contribute another semantic-text, generic-text or structured-family extension without editing the resolver.

### 4.2 Examples

| Input | Automatic result | User-visible explanation |
|---|---|---|
| `orders.csv` with a valid first-row header | CSV | `Automatic → CSV · .csv and sample validated` |
| Regional `orders.csv` containing `a;b\n1;2` | Semicolon-delimited | `.csv` identified delimited data; the sample validated `;` rather than `,` |
| `orders.csv` with inconsistent widths | Failure | Names the first sampled row whose width conflicts and offers the row controls |
| Extensionless `a;b\n1;2` | Semicolon-delimited | Content match; first row treated as a header under §7.5 |
| Extensionless `Alice;Toronto\nBob;Ottawa` | Semicolon-delimited with `c0`, `c1` | Header evidence was insufficient, so row one was retained |
| Tab-delimited `export.txt` | TSV | Strong content match despite the generic-text extension |
| `README.md` beginning with a blank line | Plain text | `Automatic → Plain text · .md`; blank first line is emitted |
| UTF-16LE text with a BOM | Matching text/structured reader | Encoding shown as UTF-16LE |
| Windows office `.csv` with invalid UTF-8 and valid Windows-1252 text | Matching structured reader | Warning and resolved Windows-1252 encoding shown |
| Extensionless invalid UTF-8 without a supported BOM | Failure | Choose an encoding or a binary-capable reader |
| Content containing NUL/binary evidence | Failure | No compatible text reader; choose/install a format |

### 4.3 Overrides and quick correction

The File selection's existing `format` and `encoding` keys become effective per-file overrides. Their serialized
shape remains compatible with saved notation. The row editor offers only formats and encodings served by the
current graph/server; persisted values that are no longer installed remain visible as unavailable rather than
being discarded.

An override applies to one selected file and bypasses only the corresponding automatic choice. A source-level
concrete format still applies to every entry without an override. Clearing an override returns that file to the
source-level policy.

The row's correction UI exposes the common immediate controls directly: format, delimiter, first-row-header and
encoding, plus skip-leading-lines and comment-prefix for configured delimited text. The generic file editor does
not own delimited fields. A format may contribute an override editor through a declared component marker; that
editor uses a companion authoring/materialization capability to return notation commands which the shared row host
applies. A third-party reader can therefore contribute different controls without adding a branch to
`FileSelectionEditor`.

`FileSelectionEntry` continues to persist a format coordinate and optional encoding, not reader-specific keys.
When the user applies delimiter/header/cleanup controls, the contributed editor explicitly materializes a
file-specific authored `ConfiguredRecordFormat` object and stores its coordinate in the entry. This preserves the
existing entry shape and canonical format object model. The command must not mutate a shared format used by other
entries; it creates or reuses a value-identical file-specific format. Clearing the override removes the reference
but does not silently delete an authored object.

The first configured-delimited correction surface includes:

| Control | Semantics |
|---|---|
| Delimiter | One explicit character; comma, tab, semicolon and pipe are convenient choices |
| First row is header | Toggles `present` versus positional labels; the preview shows whether row one is consumed |
| Encoding | Explicit served charset; selecting it disables automatic encoding fallback |
| Skip leading lines | Non-negative count of physical lines removed before record parsing; header selection follows the skip |
| Comment prefix | Exact prefix recognized only at the start of a new logical record outside quotes; skipped count is reported |

Width remains strict in this feature. Padding missing fields, truncating extra fields, dropping footer rows and
recovering/skipping malformed syntax all alter or discard data and require a separate configured-delimited cleanup
design with explicit diagnostics. In particular, an unterminated quoted field does not provide a reliable next
record boundary merely because a `skip` option exists.

### 4.4 Make explicit and lock columns

An automatically resolved row offers **Make explicit**. The action materializes the resolved reader, coding,
dialect, header and character-decoding choices as an authored format and assigns its coordinate/encoding as the
per-file override. Future runs no longer redetect the format, but a schema-free explicit format may still observe
different columns when the file is replaced.

**Lock columns** is the repeatability action. It performs or reuses bounded inspection, materializes the observed
record contract as a `RecordSchema`, attaches that schema to the explicit format and uses the reader's strict
header/width mapping. A later header, width or type drift then fails against an authored contract. The UI must not
claim that Make explicit alone protects the schema.

## 5. Resolution architecture

### 5.1 Boundary placement

Format resolution belongs between source selection and `DataPart` construction:

```text
selected ref + expected fingerprint + authored format/override
  -> bounded format resolution
  -> concrete ResolvedReadSpec + resolution provenance
  -> DataPart
  -> ordinary ConfiguredDataOpener
  -> streaming DataCursor<DataValue>
```

This placement preserves the existing execution boundary. `ConfiguredDataOpener` continues to resolve one reader
capability from the already-concrete spec, verify the expected fingerprint, assemble coding/content layers and
open the cursor. It does not know that an automatic choice occurred.

`ConfiguredRecordFormat` gains a canonical suspendable resolution operation that receives the data context, ref,
expected fingerprint and optional encoding override. A default implementation delegates to the existing fixed
`resolvedRead(ref)` behaviour so current concrete formats remain simple. The fixed method stays as a deprecated
compatibility seam for this release; all production source paths use the contextual operation. `Automatic`
overrides it and delegates to the detection service.

### 5.2 Detection capability

Add a separate optional `ReaderProbeCapability` beside `ReaderCapability` in the plugin SPI. This avoids changing
the runtime reader contract or introducing a `when` over known readers. A detectable configured format supplies a
fixed candidate `ResolvedReadSpec`; the detection service resolves its reader and invokes the probe capability
over the bounded sample.

The autowired candidate metadata declares its configured-format reference/digest, exact extensions and compatible
structured hint families. Hint metadata classifies an extension/media value as structured-family, generic-text or
semantic-text. More than one candidate may declare compatibility with one structured family: both comma and
semicolon candidates accept the `.csv` family, while the resolver remains unaware of their concrete identities.
These declarations, rather than registration order or reader names, determine which probes a hint admits.

The probe request contains:

- the canonical candidate config;
- normalized filename extension and available media/provider hints;
- bounded raw bytes after content coding and the character views permitted by the automatic character policy;
- whether the sample reached end of input;
- the detection policy limits.

One bounded byte acquisition supplies every candidate; trying a policy-authorized UTF-8/Windows-1252 character
view never reopens the source. The request does not claim a generic complete-record count. Logical record
boundaries depend on the candidate:
a newline inside a quoted CSV field is data while the same newline is a complete Plain-text record. Each probe
parses its independent in-memory view, ignores a boundary-truncated final logical record and considers at most the
policy's record limit. The service enforces acquisition bytes/time; the capability enforces logical-record count.

The result contains:

- `no-match`, `content-strong` or `extension-validated` strength;
- the concrete canonical reader config to use, including any permitted automatic header decision;
- concise evidence suitable for user-facing resolution details; and
- a rejection explanation when an extension candidate fails validation.

Probe strength is an ordering rule, not an uncalibrated percentage displayed as certainty. If two different
specifications tie at the strongest available level, the service does not pick by registration order. With no
structured-family hint, valid text falls back to lines with an ambiguity warning. With a structured-family hint,
the tie is an actionable ambiguity failure because changing the contract to lines would contradict the hint.

Configured formats opt into an autowired detection-candidate capability. `Automatic` itself is not a candidate,
so the candidate graph cannot recurse. A third-party format becomes detectable by contributing its configured
format marker and a reader that implements `ReaderProbeCapability`; source, Job and client code remain unchanged.

Quick correction and pinning are a second optional capability, not part of probing. A
`FormatAuthoringCapability` converts a capability-owned canonical reader config and optional observed schema into
authored format/schema notation. Its client editor is selected through the format's declared override-editor
marker. Built-in delimited and Plain-text formats implement it; a detectable third-party format without one still
supports Automatic and the ordinary format picker, while its Make explicit/Lock columns actions are unavailable
with an explanation.

### 5.3 Resolution result and provenance

Add a common per-part resolution model containing:

```text
ref
concrete format reference when one exists
display label
selection: explicit | automatic
basis: override | extension | content | fallback
reason
optional warning
```

`DataResolveResult` carries these details beside its manifest and diagnostics. They are presentation/provenance,
not semantic input, so they do not enter `DataPart.digest()`. The concrete `ResolvedReadSpec` already provides the
semantic identity used by execution, schema caching and migration.

The resolution detail may offer the candidate's concrete format reference and enough canonical materialization
input for its contributed editor. It is not itself notation and cannot be written into the existing per-file
`format` string. Make explicit and Lock columns create authored format/schema objects, then persist their
coordinates through ordinary notation commands.

The new collection defaults to empty when decoding an older response so existing custom `DataSource`
implementations remain source-compatible while they are rebuilt. Built-in sources populate one result per part.

### 5.4 Detection cache

Cache a successful detection by:

```text
canonical ref hint identity
+ observed/expected content fingerprint
+ normalized extension/media hints
+ candidate reference and digest set
+ reader probe compatibility identities
+ detection-policy digest
```

The cache value is the concrete spec plus its resolution detail. Candidate order is non-semantic; the candidate
set is canonicalized before hashing. A content change, configured-format edit, installed detector change or policy
change therefore forces detection again. The policy digest includes the extension-hint classification and the
ordered automatic character-encoding fallbacks; changing either may change the result.

Timeout, cancellation, read-limit, fingerprint mismatch and provider-acquisition failures are never cached.
Deterministic successful fallback may be cached because its key contains both content identity and the complete
candidate set.

## 6. Bounded probing

The default detection policy is:

- at most 256 KiB of decoded content;
- at most 100 complete logical records per candidate; and
- at most two seconds, including acquisition and decoding.

These are named policy values with a digest, not literals scattered through readers. Detection reads one bounded
sample and gives each candidate an independent in-memory view; it never reopens the full source per candidate.
When gzip decoding requires a fresh provider handle after raw magic inspection, that second bounded acquisition is
owned and closed by the detection service and is covered by the cache.

If the byte bound cuts through a final record, probes may use only the complete prefix. A truncated quoted record
at the sample boundary is “insufficient evidence,” not malformed source. A syntax error wholly contained inside a
complete sampled record is a real rejection. Reaching a policy bound without enough evidence produces a clear
“choose a format or inspect with a larger policy” failure rather than a low-confidence structured guess.

Cold detection adds bounded setup work. A warm resolution performs no content acquisition. The subsequently
opened cursor uses the existing streaming path and retains its current memory, backpressure, cancellation and
migration behaviour, which is the property required by large-file and CEP workloads.

### 6.1 Aggregate source budget

A per-file bound is not a source bound. Resolving a cold directory scan of thousands of files must not perform
thousands of serial two-second probes. The default aggregate policy permits:

- at most four cold acquisitions in parallel;
- at most 256 cold parts;
- at most 64 MiB of decoded samples; and
- at most 15 seconds of source-resolution wall time.

Cache hits do not consume cold-part or sample-byte allowance. Concurrency is bounded independently of the totals
so a provider cannot be flooded. These are named operational policy values, measured before implementation is
declared complete and adjustable without changing semantic `DataPart` identity; their policy identity still gates
cache/adoption where the existing operational-budget rules require it.

Budget exhaustion fails the source resolution rather than returning a partial manifest. The diagnostic reports
how many files were resolved and offers three corrective actions: narrow the directory filter, choose a concrete
source-level format so probing is unnecessary, or raise the detection policy. Automatic never probes a sample of
the directory and applies a majority result to the rest: that would violate per-part evidence and could silently
misread a heterogeneous minority.

## 7. Detection rules

### 7.1 Content coding

Automatic resolution examines raw prefix bytes before character decoding:

- gzip magic bytes are authoritative for gzip;
- a `.gz` suffix without gzip magic is a format-resolution error rather than an identity decode attempt;
- after removing `.gz`, the preceding extension remains available as the record-format hint; and
- other archive/container formats are not opened implicitly.

ZIP remains deferred because selecting an entry is a source/part decision, not record-format detection.

### 7.2 Character encoding and text safety

A supported BOM selects UTF-8, UTF-16BE or UTF-16LE and must agree with an explicit override. An explicit encoding
always decodes strictly and never falls through to another charset. Without a BOM or override, Automatic first
uses strict UTF-8.

The default Windows-office compatibility policy permits one deterministic second attempt with Windows-1252 only
for a structured-family or generic-text filename/media hint. The attempt must decode without replacement, pass
the text-safety check below and, for structured input, validate through the winning reader probe. Its result always
shows `Windows-1252` and a warning that the encoding was inferred. Extensionless invalid UTF-8 still fails and
asks the user to choose an encoding.

This is a pragmatic compatibility rule, not proof of encoding and not a universal lossless fallback. Different
legacy code pages assign different characters to the same upper bytes, and the published Windows-1252 mapping has
[undefined byte positions](https://unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1252.TXT). Automatic does
not try ISO-8859 variants, system-default encoding or byte-frequency charset detection. The ordered fallback list
is detection policy so a deployment can remove or replace the Windows-specific rule without reader branches.

Decoded content is binary-looking when it contains NUL or disallowed control characters beyond ordinary tab,
form-feed and line separators. Binary-looking or undecodable input cannot use the line fallback. The error names
the evidence and offers format/encoding selection; it does not expose implementation class names.

### 7.3 Filename and media hints

Hint classification is capability metadata and participates in the detection-policy/cache digest:

- **structured family** says the producer claims structured data but may leave dialect choice open (`.csv`) or
  narrow it (`.tsv`);
- **generic text** says a text reader is credible but permits stronger structured content evidence (`.txt`,
  `.log`);
- **semantic text** names a document whose delimiters may be syntax rather than fields (`.md`); and
- **absent/unknown** contributes no format preference.

An exact structured candidate rejection does not prevent another candidate in the same credible family from
winning. This is how a semicolon-delimited `.csv` succeeds. If none wins, a contained syntax/schema/width defect is
a failure rather than a lines fallback. Semantic-text content is not structurally probed in v1; the user can
explicitly choose a structured format when a Markdown-named file is intentionally tabular.

### 7.4 Delimited structure

A content-only delimited candidate is strong only when:

- at least two complete records were sampled;
- each has the same field count greater than one;
- quote/escape/framing syntax is valid for every complete record;
- empty fields are valid under the candidate policy; and
- any declared schema and typed decoding validate.

One-column parsing is never evidence of a delimiter because nearly every text file would match. An exact extension
may validate a header-only or one-record file, but a contained syntax/schema error rejects it. Comma, tab,
semicolon and pipe are ordinary configured candidates, not special cases in the detection service.

### 7.5 Header decision

An extension-selected CSV, TSV or authored format keeps its configured header policy. This preserves the familiar
first-row-header behaviour for ordinary `.csv` / `.tsv` selection and keeps authored declarations authoritative.

A schema-free, content-only delimited match consumes row one as a header only when:

1. every first-row value is non-empty and unique;
2. every value is an identifier-like label (`[A-Za-z_][A-Za-z0-9 _.-]*`); and
3. at least one column has a stable Boolean, integer or decimal classification in subsequent non-empty rows while
   its first-row value does not have that classification.

Otherwise the resolved config uses positional labels (`c0`, `c1`, …) and emits the first row as data. All-text
tables therefore prefer retention over guessing. A user who knows row one is a header can select or author the
concrete header-bearing format.

A schema-bearing content-only candidate must validate its own declared mapping; it is rejected rather than
converted to a positional schema.

### 7.6 Plain-text-lines reader

The plain-text reader emits a stable `Record(line: Text)` contract. It recognizes LF, CRLF and lone-CR framing,
removes the record separator, preserves empty lines and emits a final unterminated line. Empty input emits zero
records under the same stable contract.

It has no delimiter or quote semantics. Record/field length, expanded-byte, timeout and cancellation policies still
apply, so an arbitrarily long unterminated line cannot grow without bound.

## 8. UI flow

### 8.1 Selection-time resolution

Adding or replacing a selected file starts automatic resolution immediately. A detached action accepts the file
location, authored format reference and optional per-file overrides, resolves through the same detection service
used by `FileDataSource`, and returns the common resolution model. The server result is authoritative; the client
does not duplicate detection rules.

Requests use per-row epochs. Removing a file, changing an override or selecting a newer listing invalidates an
older in-flight result so stale detection cannot repaint the row.

### 8.2 Presentation

The selected-file row shows a compact result:

```text
README.md    Automatic → Plain text    .md
orders.csv   Automatic → CSV           extension + sample
regional.csv Automatic → Semicolon     warning: regional delimiter inferred
legacy.csv   Automatic → CSV           warning: Windows-1252 inferred
```

Details exposes the full path, resolved encoding, evidence/rejection text, the format-contributed correction
controls and Make explicit / Lock columns actions. Warnings use product language and state the consequence, for
example:

```text
The .csv file uses semicolons, so it will be read as semicolon-delimited data.
Make this explicit to keep that choice for future files.
```

A malformed structured hint is a failure rather than a warning/fallback:

```text
Row 14 has 5 fields; earlier rows have 4.
Adjust the delimiter or header settings, or explicitly choose Plain text.
```

A binary/encoding/ambiguity failure likewise remains inline on the affected row and at Worker execution. It
identifies the file and offers the same controls. The user never has to infer that `FieldId` or a reader capability
caused the failure.

### 8.3 Runtime authority

Selection-time detection is preview, not persisted truth. A run resolves the source against the current
fingerprint and reuses the cache only when the full key matches. The resulting manifest is captured in Worker
migration state as it is today, so a resumed run does not change formats midway through execution.

## 9. Error semantics

The configured delimited reader validates empty header labels before constructing `FieldId`. A concrete-format
failure reports the source, record and one-based column, for example:

```text
The first row contains an empty column name at column 1.
Add a name, use positional labels, or choose Plain text.
```

Duplicate, missing and extra labels retain their dedicated header-mapping category and equally actionable copy.
Automatic probing converts a candidate's expected validation failure into rejection evidence; unexpected runtime
exceptions still fail fast and are not reclassified as “no match.”

Fallback and inferred-encoding/dialect warnings are carried as resolution provenance, not logged-only server
warnings. A structured-family rejection or tie, and operational failures (acquisition, fingerprint, timeout,
per-source budget and cancellation), remain failures and never become a text fallback.

Skip-leading-lines and comment-prefix are explicit reader configuration. Their skipped counts are surfaced in
trace/UI. They never activate as automatic recovery after a probe failure. Width and malformed-syntax policies
remain strict in this feature.

## 10. Mixed files, schemas and downstream processing

Every selected entry produces its own concrete `DataPart`. The current Read worker then inspects those parts and
applies its existing schema policy:

- `superset` combines compatible record fields in stable order and preserves per-part absence;
- `strict` requires equal contracts and rejects a heterogeneous selection; and
- incompatible scalar/record or typed conflicts remain failures.

Detection does not coerce formats toward a common lane merely to make reconciliation pass. A CSV contract and a
`Record(line: Text)` contract are honest inputs to the same existing combination rule. Users can split workers or
set overrides when strict homogeneity is required.

## 11. Scope and non-goals

### 11.1 Included

- Automatic as the File-source default;
- per-file resolution and overrides;
- CSV, TSV, semicolon, pipe and authored configured-delimited probing;
- plain-text-lines reader and fallback;
- structured-family, generic-text and semantic-text hint classification;
- gzip/BOM/strict-UTF-8 detection plus the constrained, warned Windows-1252 office fallback;
- open reader-probe capability;
- format-contributed per-file correction for delimiter, header, encoding, leading-line skip and comment prefix;
- Make explicit and Lock columns actions through authored format/schema objects;
- selection-time UX, runtime cache and aggregate source budget;
- actionable header and detection errors; and
- performance/resource/migration proof.

### 11.2 Deferred

- JSON and NDJSON structural readers;
- Parquet/range access;
- JDBC/native rows;
- ZIP entry browsing;
- spreadsheet workbook readers and sheet selection (`.xlsx` first; legacy `.xls` and `.ods` later);
- probabilistic legacy-charset detection;
- inference of semantic field types without an authored schema;
- whole-dataset validation before a streaming run; and
- padding/truncating ragged rows, footer removal, malformed-syntax skipping and a universal quarantine system.

Those features should become additional reader/content capabilities. They must not accumulate as branches inside
Automatic or the delimited parser.

Although `.xlsx` is ZIP-based, its workbook relationships, shared strings and sheet selection make it a workbook
container capability rather than an implicit generic ZIP decoder. A future workbook source/browser resolves each
selected sheet as a part; Automatic does not choose a sheet or feed workbook entries to the delimited reader.

## 12. Acceptance matrix

### 12.1 Selection and fallback

- A leading-blank-line Markdown fixture resolves to Plain text and emits the blank line plus all following lines.
- A Markdown table remains Plain text rather than becoming pipe-delimited.
- Ordinary `.txt` and `.log` inputs resolve to Plain text without a fallback warning, while a tab-delimited `.txt`
  resolves to TSV from content evidence.
- A semicolon-delimited `.csv` resolves structurally with a regional-dialect warning.
- A malformed `.csv` fails with the sampled row and expected/observed width instead of falling back to lines.
- The same malformed input under explicit CSV fails with a header/syntax/width diagnostic and never falls back.
- Empty text resolves to Plain text and yields zero records.
- A hinted Windows-1252 office fixture resolves with a visible inferred-encoding warning; an explicit encoding is
  strict and does not fall through.
- Extensionless invalid UTF-8, undefined Windows-1252 bytes and binary-looking input fail with format/encoding
  guidance.

### 12.2 Structured detection

- Valid CSV and TSV extensions retain first-row headers.
- Extensionless comma, tab, semicolon and pipe data require consistent multi-column records.
- Strong type contrast permits a content-only header; all-text ambiguity retains row one under positional labels.
- Header-only structured input requires an extension/configured hint.
- Equal-strength structured candidates never use registration order: unhinted valid text falls back with an
  ambiguity warning, while a structured-family hint fails as ambiguous.
- A test-only detectable format and reader probe are contributed without editing generic detection/source/UI code.
- A test-only format-contributed override editor mounts without editing the shared file-selection UI.

### 12.3 Coding, limits and lifetime

- Plain and gzip forms resolve to equivalent record specs apart from the coding chain.
- Gzip magic, misleading `.gz`, UTF BOM agreement/conflict, strict explicit encoding and constrained legacy
  fallback are covered.
- Partial final sampled records are ignored as evidence; contained syntax errors reject a candidate.
- Each probe computes its own logical-record boundaries; a generic physical-line count is not supplied as truth.
- Byte, record and time bounds, cancellation during acquisition/decode/probe, and close-on-every-failure are pinned.
- Warm cache hits perform no content read; all key members invalidate; operational failures are not cached.

### 12.4 Job and UI

- Mixed CSV/TSV/text inputs carry different concrete specs and exercise both `superset` and `strict` behaviour.
- A per-file format/encoding override affects only that file and survives notation round-trip.
- Selection starts detection, stale responses are ignored, and Automatic remains authored after success.
- Rows distinguish loading, resolved, warning and failure states and expose the corrective controls.
- Applying delimiter/header/skip/comment controls materializes a file-specific authored format and never mutates
  another entry's shared format.
- Make explicit freezes reader choices but does not claim schema stability; Lock columns authors a schema and
  rejects later drift.
- Worker migration retains its captured manifest; a fingerprint change in a fresh run detects again.

### 12.5 Performance and builds

- Record cold detection time/bytes separately from execution throughput.
- Re-run the 100,000-row data-read canary; warm end-to-end throughput stays within the existing 20% regression
  gate, and cold detection stays within its hard 256 KiB / 100-record / two-second bounds.
- A cold directory scan proves four-acquisition concurrency and the 256-part / 64-MiB / 15-second aggregate
  limits; exhaustion returns no partial manifest and no majority-derived specs.
- Run the focused common, JVM and JS tests, then the full kzen-auto build from `../kzen-auto`.
- Because the probe interface is in `kzen-auto-plugin`, publish kzen-auto locally and rebuild
  `kzen-sample-plugin` plus standalone kzen-project, including `SampleExtensionTest`.

## 13. Implementation sequence

1. **Reader and detection foundation.** Add resolution/provenance models, hint metadata, the optional probe SPI,
   character/detection policy and cache, candidate-owned logical-record counting, delimited probe mode, built-in
   candidate formats, the line reader, header validation and focused JVM tests. Extend configured-delimited
   identity with skip-leading-lines and comment-prefix while leaving width/syntax recovery strict. End with
   existing explicit formats behaviourally unchanged and the automatic resolver green in isolation.
2. **Source integration.** Make contextual format resolution canonical, add Automatic, resolve each selected or
   scanned file before `DataPart` construction under the aggregate source budget, activate per-file
   format/encoding overrides, and pin manifest, digest, cache and migration behaviour. Change the File-source
   inherited default only after this boundary is green so existing implicit `.csv` fixtures continue to resolve
   as CSV.
3. **Client customization and gate.** Add the selection-time action/store, row presentation, contributed override
   editor, authored-format materialization, Make explicit and Lock columns. Cover stale requests, shared-format
   isolation and error states; run the canary and full downstream build chain. Update the data-reading authority
   and plan tracker as DR8 when the implementation lands.

Each boundary ends with one canonical runtime path. There is no long-lived alternate Auto opener and no second
parser.

## 14. Settled decisions

| # | Decision | Answer |
|---|---|---|
| FD1 | Default | `Automatic` for File sources |
| FD2 | Record-format fallback | Valid unrecognized text becomes `Record(line: Text)`; structured-family conflicts, binary and undecodable input fail |
| FD3 | Multi-file policy | Detect each file independently; reconcile through existing schema mode |
| FD4 | Initial formats | Flat text only: CSV/TSV/semicolon/pipe/custom delimited plus lines |
| FD5 | Header policy | Extension formats keep policy; content-only headers require strong type-contrast evidence |
| FD6 | Persistence | Keep Automatic authored; concrete results remain fingerprint-keyed runtime/design state |
| FD7 | Low-confidence UX | Unhinted/generic valid text may continue as lines; a structured-family conflict or tie fails |
| FD8 | Overrides | Format and encoding remain per-file fields; reader controls materialize an authored format through a contributed editor |
| FD9 | Detection timing | Probe on selection and again authoritatively at resolution, sharing one cache |
| FD10 | Extensibility | Optional reader probe plus detectable-format capability; no concrete-name dispatch |
| FD11 | Hot path | Detection completes before `DataPart`; execution opens only the concrete reader |
| FD12 | Versioning | No coordinated release-train version bump as part of implementation |
| FD13 | Hint classes | Structured-family, generic-text and semantic-text hints have different fallback rules; metadata is contributed |
| FD14 | Legacy encoding | Strict UTF-8 first; hinted office/text input may use a strict, warned, policy-owned Windows-1252 fallback |
| FD15 | Directory scale | Bounded concurrency plus aggregate part/byte/time budgets; never extrapolate a majority result |
| FD16 | Repeatability | Make explicit freezes reader choices; Lock columns additionally authors the observed schema |
| FD17 | Delimited cleanup | Leading-line skip and record-boundary comment prefix ship; ragged/footer/syntax recovery remains deferred |
