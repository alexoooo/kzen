# Automatic data-format detection and safe text fallback

> **Status: proposed.** This analysis extends
> [`2026-08-29_data-reading.md`](2026-08-29_data-reading.md) after the configured reader arc landed on
> 2026-09-01. It preserves that design's provider-neutral content stack, immutable resolved-read identity,
> bounded inspection, typed `DataContract` / `DataValue` boundary and strict configured formats. It supersedes
> only the blanket exclusion of automatic format and header detection: inference is permitted inside the explicit
> `Automatic` authoring mode under the conservative rules below. A user-selected concrete format is never guessed,
> repaired or silently reinterpreted.

## 1. Problem definition

### 1.1 The immediate failure

The File worker currently gives every selection the inherited `ConfiguredCsv` format unless the user opens
Advanced and chooses something else. The file browser accepts arbitrary files, but neither the selection row nor
the collapsed card communicates that CSV has been chosen.

A representative failure is a Markdown file whose first byte is a newline. The configured CSV reader uses
`header: present`, so the first physical record becomes the header. That record contains one empty field;
`ConfiguredDelimitedReader` passes the empty label into `FieldId`, and the Worker fails with:

```text
Data: Field name must not be empty
```

The exception is internally accurate, but the user did not choose CSV, did not say the file had a header, and is
not told which assumption produced the error. Removing the first blank line only postpones the mismatch: later
Markdown lines may contain commas or quotes and fail CSV width or syntax rules. Improving this one exception would
therefore leave the product defect intact.

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

- a normal CSV or TSV opens as a table with no extra authoring;
- common semicolon- and pipe-delimited data is recognized from a bounded sample;
- Markdown, logs and ordinary text open as a one-column line stream;
- a mixed selection resolves each file independently;
- the UI exposes each choice and its evidence before a run;
- an unusual case can be corrected per file without changing the other files; and
- binary, undecodable or genuinely ambiguous input stops with a useful next action.

The safe fallback is therefore **plain text lines**, not an arbitrary structured parser. Falling back preserves
the source text and makes no field-boundary claim beyond line framing. It is safe only after the bytes have been
classified as decodable text.

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

Resolution follows this precedence:

1. a per-file format or encoding override;
2. an explicitly selected source-level concrete format;
3. a validated exact-extension candidate in `Automatic` mode;
4. a unique strong content match among installed detectable formats;
5. a plain-text-lines result for valid text; or
6. an actionable failure for binary, undecodable, timed-out or otherwise unsafe input.

`Automatic` remains the authored value after detection. Detection never sends a notation command. The UI shows
the concrete result, basis and warning per file, and permits an explicit per-file override.

## 3. Product invariants

1. **Explicit means strict.** A concrete user-selected format never falls back to another reader. Its syntax,
   header, schema and decode failures remain failures.
2. **Automatic means explainable.** Every successful automatic resolution identifies the concrete format and
   whether extension, content or fallback selected it.
3. **Fallback is loss-minimizing.** Valid unrecognized text becomes lines; binary-looking or undecodable content
   does not become guessed text.
4. **Resolution is per part.** A source may contain CSV, TSV and text parts; existing `strict` / `superset` schema
   policy decides whether their resulting contracts can share a lane.
5. **Detection is bounded.** Probe cost is independent of total file size and observes the same cancellation,
   fingerprint and expanded-byte controls as inspection.
6. **Execution is deterministic.** The manifest carries the concrete reader config and coding chain; the opener
   never reruns detection.
7. **Detection is open-ended.** A new format opts into a probe capability. Generic code never compares a reader,
   format or extension against a closed concrete-type list.
8. **No background edits.** Selecting or inspecting a file updates transient resolution state only. Manual
   overrides are the only persisted changes.

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
| Plain text | One `line: Text` field per physical line | Known text extensions and universal text fallback |

Authored configured-delimited formats participate when their reader exposes probing. A schema-bearing authored
format may win only when its declared header/schema and sampled values validate; detection never weakens or
rewrites that declaration.

Plain text recognizes `.txt`, `.md` and `.log` as direct extension matches. Other valid text reaches the same
reader only after no structured candidate wins. A rejected structured hint produces a warning; an ordinary known
text extension does not.

### 4.2 Examples

| Input | Automatic result | User-visible explanation |
|---|---|---|
| `orders.csv` with a valid first-row header | CSV | `Automatic → CSV · .csv and sample validated` |
| `orders.csv` with inconsistent widths | Plain text | Warning that the CSV hint failed and lines were preserved |
| Extensionless `a;b\n1;2` | Semicolon-delimited | Content match; first row treated as a header under §7.4 |
| Extensionless `Alice;Toronto\nBob;Ottawa` | Semicolon-delimited with `c0`, `c1` | Header evidence was insufficient, so row one was retained |
| `README.md` beginning with a blank line | Plain text | `Automatic → Plain text · .md`; blank first line is emitted |
| UTF-16LE text with a BOM | Matching text/structured reader | Encoding shown as UTF-16LE |
| Invalid UTF-8 without a supported BOM | Failure | Choose an encoding or a binary-capable reader |
| Content containing NUL/binary evidence | Failure | No compatible text reader; choose/install a format |

### 4.3 Overrides

The File selection's existing `format` and `encoding` keys become effective per-file overrides. Their serialized
shape remains compatible with saved notation. The row editor offers only formats and encodings served by the
current graph/server; persisted values that are no longer installed remain visible as unavailable rather than
being discarded.

An override applies to one selected file and bypasses only the corresponding automatic choice. A source-level
concrete format still applies to every entry without an override. Clearing an override returns that file to the
source-level policy.

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

The probe request contains:

- the canonical candidate config;
- normalized filename extension and available media/provider hints;
- decoded sample bytes or characters;
- whether the sample reached end of input;
- the count of complete records available to judge; and
- the detection policy limits.

The result contains:

- `no-match`, `content-strong` or `extension-validated` strength;
- the concrete canonical reader config to use, including any permitted automatic header decision;
- concise evidence suitable for user-facing resolution details; and
- a rejection explanation when an extension candidate fails validation.

Probe strength is an ordering rule, not an uncalibrated percentage displayed as certainty. If two different
specifications tie at the strongest available level, the service does not pick by registration order. Valid text
falls back to lines with an ambiguity warning; non-text fails.

Configured formats opt into an autowired detection-candidate capability. `Automatic` itself is not a candidate,
so the candidate graph cannot recurse. A third-party format becomes detectable by contributing its configured
format marker and a reader that implements `ReaderProbeCapability`; source, Job and client code remain unchanged.

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
change therefore forces detection again.

Timeout, cancellation, read-limit, fingerprint mismatch and provider-acquisition failures are never cached.
Deterministic successful fallback may be cached because its key contains both content identity and the complete
candidate set.

## 6. Bounded probing

The default detection policy is:

- at most 256 KiB of decoded content;
- at most 100 complete records; and
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

## 7. Detection rules

### 7.1 Content coding

Automatic resolution examines raw prefix bytes before character decoding:

- gzip magic bytes are authoritative for gzip;
- a `.gz` suffix without gzip magic is a format-resolution error rather than an identity decode attempt;
- after removing `.gz`, the preceding extension remains available as the record-format hint; and
- other archive/container formats are not opened implicitly.

ZIP remains deferred because selecting an entry is a source/part decision, not record-format detection.

### 7.2 Character encoding and text safety

A supported BOM selects UTF-8, UTF-16BE or UTF-16LE and must agree with an explicit override. Without a BOM,
Automatic uses strict UTF-8. It does not guess legacy code pages from byte frequency. A user may choose another
served encoding per file.

Decoded content is binary-looking when it contains NUL or disallowed control characters beyond ordinary tab,
form-feed and line separators. Binary-looking or undecodable input cannot use the line fallback. The error names
the evidence and offers format/encoding selection; it does not expose implementation class names.

### 7.3 Delimited structure

A content-only delimited candidate is strong only when:

- at least two complete records were sampled;
- each has the same field count greater than one;
- quote/escape/framing syntax is valid for every complete record;
- empty fields are valid under the candidate policy; and
- any declared schema and typed decoding validate.

One-column parsing is never evidence of a delimiter because nearly every text file would match. An exact extension
may validate a header-only or one-record file, but a contained syntax/schema error rejects it. Comma, tab,
semicolon and pipe are ordinary configured candidates, not special cases in the detection service.

### 7.4 Header decision

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

### 7.5 Plain-text-lines reader

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
legacy.dat   Automatic → Plain text    warning
```

Details exposes the full path, resolved encoding, evidence/rejection text and per-file Format/Encoding controls.
Warnings use product language and state the consequence, for example:

```text
The .csv hint did not form consistent records, so the file will be read as plain text lines.
Choose CSV to require CSV validation, or select another format.
```

A binary/encoding failure remains inline on the affected row and at Worker execution. It identifies the file and
offers the same controls. The user never has to infer that `FieldId` or a reader capability caused the failure.

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

Fallback warnings are carried as resolution provenance, not logged-only server warnings. Operational failures
(acquisition, fingerprint, timeout, budget and cancellation) remain failures and never become a text fallback.

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
- gzip/BOM/strict-UTF-8 detection;
- open reader-probe capability;
- selection-time UX and runtime cache;
- actionable header and detection errors; and
- performance/resource/migration proof.

### 11.2 Deferred

- JSON and NDJSON structural readers;
- Parquet/range access;
- JDBC/native rows;
- ZIP entry browsing;
- probabilistic legacy-charset detection;
- inference of semantic field types without an authored schema;
- whole-dataset validation before a streaming run; and
- a universal quarantine or malformed-record recovery system.

Those features should become additional reader/content capabilities. They must not accumulate as branches inside
Automatic or the delimited parser.

## 12. Acceptance matrix

### 12.1 Selection and fallback

- A leading-blank-line Markdown fixture resolves to Plain text and emits the blank line plus all following lines.
- Known `.txt`, `.md` and `.log` inputs resolve without a fallback warning.
- A malformed `.csv` falls back to lines with a visible rejected-hint warning in Automatic mode.
- The same malformed input under explicit CSV fails with a header/syntax/width diagnostic and never falls back.
- Empty text resolves to Plain text and yields zero records.
- Binary-looking and invalid-UTF-8 inputs fail with format/encoding guidance.

### 12.2 Structured detection

- Valid CSV and TSV extensions retain first-row headers.
- Extensionless comma, tab, semicolon and pipe data require consistent multi-column records.
- Strong type contrast permits a content-only header; all-text ambiguity retains row one under positional labels.
- Header-only structured input requires an extension/configured hint.
- Equal-strength structured candidates do not use registration order; valid text falls back with an ambiguity
  warning.
- A test-only detectable format and reader probe are contributed without editing generic detection/source/UI code.

### 12.3 Coding, limits and lifetime

- Plain and gzip forms resolve to equivalent record specs apart from the coding chain.
- Gzip magic, misleading `.gz`, UTF BOM agreement/conflict and explicit encoding override are covered.
- Partial final sampled records are ignored as evidence; contained syntax errors reject a candidate.
- Byte, record and time bounds, cancellation during acquisition/decode/probe, and close-on-every-failure are pinned.
- Warm cache hits perform no content read; all key members invalidate; operational failures are not cached.

### 12.4 Job and UI

- Mixed CSV/TSV/text inputs carry different concrete specs and exercise both `superset` and `strict` behaviour.
- A per-file format/encoding override affects only that file and survives notation round-trip.
- Selection starts detection, stale responses are ignored, and Automatic remains authored after success.
- Rows distinguish loading, resolved, warning and failure states and expose the corrective controls.
- Worker migration retains its captured manifest; a fingerprint change in a fresh run detects again.

### 12.5 Performance and builds

- Record cold detection time/bytes separately from execution throughput.
- Re-run the 100,000-row data-read canary; warm end-to-end throughput stays within the existing 20% regression
  gate, and cold detection stays within its hard 256 KiB / 100-record / two-second bounds.
- Run the focused common, JVM and JS tests, then the full kzen-auto build from `../kzen-auto`.
- Because the probe interface is in `kzen-auto-plugin`, publish kzen-auto locally and rebuild
  `kzen-sample-plugin` plus standalone kzen-project, including `SampleExtensionTest`.

## 13. Implementation sequence

1. **Reader and detection foundation.** Add resolution/provenance models, the optional probe SPI, detection policy
   and cache, delimited probe mode, built-in candidate formats, the line reader, header validation and focused JVM
   tests. End with explicit formats unchanged and the automatic resolver green in isolation.
2. **Source integration.** Make contextual format resolution canonical, add Automatic, resolve each selected or
   scanned file before `DataPart` construction, activate per-file format/encoding overrides, and pin manifest,
   digest, cache and migration behaviour. Change the File-source inherited default only after this boundary is
   green so existing implicit `.csv` fixtures continue to resolve as CSV.
3. **Client integration and gate.** Add the selection-time action/store, row presentation and override controls;
   cover stale requests and error states; run the canary and full downstream build chain. Update the data-reading
   authority and plan tracker as DR8 when the implementation lands.

Each boundary ends with one canonical runtime path. There is no long-lived alternate Auto opener and no second
parser.

## 14. Settled decisions

| # | Decision | Answer |
|---|---|---|
| FD1 | Default | `Automatic` for File sources |
| FD2 | Fallback | Valid unrecognized text becomes `Record(line: Text)`; binary/undecodable input fails |
| FD3 | Multi-file policy | Detect each file independently; reconcile through existing schema mode |
| FD4 | Initial formats | Flat text only: CSV/TSV/semicolon/pipe/custom delimited plus lines |
| FD5 | Header policy | Extension formats keep policy; content-only headers require strong type-contrast evidence |
| FD6 | Persistence | Keep Automatic authored; concrete results remain fingerprint-keyed runtime/design state |
| FD7 | Low-confidence UX | Continue as lines with a visible warning |
| FD8 | Overrides | Format and encoding may be set per file |
| FD9 | Detection timing | Probe on selection and again authoritatively at resolution, sharing one cache |
| FD10 | Extensibility | Optional reader probe plus detectable-format capability; no concrete-name dispatch |
| FD11 | Hot path | Detection completes before `DataPart`; execution opens only the concrete reader |
| FD12 | Versioning | No coordinated release-train version bump as part of implementation |
