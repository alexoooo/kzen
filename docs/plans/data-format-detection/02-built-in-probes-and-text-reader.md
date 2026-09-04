# DR8b — bounded detector, delimited probes and Plain text

> **Status: complete — landed 2026-09-03.** Authority: automatic data-format detection §§4.1–4.2, 5.2, 6, 7.1–7.6, 9 and 12.1–12.3.
> Requires DR8a. This session makes detection executable in isolation but does not yet change `FileDataSource`.

## Outcome

Implement one bounded resolver over one acquired sample, with built-in CSV, TSV, semicolon, pipe and authored
delimited candidates plus a Plain-text reader. Candidate probes reuse the production parser, own their logical
record boundaries, and implement the conservative strength/header rules. Existing explicit configured-delimited
reads stay strict and behaviourally stable except for the newly authored skip/comment controls and improved header
diagnostics.

## Preflight and current anchors

- `kzen-auto-jvm/.../data/content/SequentialContentStack.kt`, coding and character packages;
- `kzen-auto-jvm/.../data/read/ReaderExecutionPolicies.kt`;
- `kzen-auto-jvm/.../data/read/delimited/ConfiguredDelimitedReader.kt` and capability;
- `kzen-auto-common/.../data/read/DelimitedReadConfig.kt`, `DelimitedDialectSpec.kt`, header and character specs;
- `kzen-auto-jvm/.../objects/datasource/format/ConfiguredDelimitedFormat.kt` and
  `configured-delimited-format.yaml`; and
- existing configured-reader, content-stack, fake-provider and lifetime tests from DR3–DR5.

## Implementation

1. Implement `AutomaticFormatResolver` around the DR8a registry and cache. It performs raw prefix inspection,
   determines content coding, opens at most the bounded post-coding sample, creates only policy-authorized strict
   character views, invokes eligible probes, ranks strengths deterministically and returns a concrete spec plus
   provenance. It never reopens per candidate.
2. Preserve coding rules: gzip magic is authoritative; `.gz` without magic fails; the preceding extension remains
   the format hint; ZIP/other containers are rejected as unsupported. If the content stack needs a second handle
   after magic inspection, the resolver owns, bounds and closes it on success, failure and cancellation.
3. Implement character selection in this order: explicit strict encoding; supported BOM with explicit agreement;
   strict UTF-8; then strict Windows-1252 only for structured-family or generic-text hints. Reject replacement,
   undefined Windows-1252 bytes, NUL and disallowed controls. The fallback always records an inferred-encoding
   warning. Extensionless invalid UTF-8 does not try Windows-1252.
4. Extend `DelimitedReadConfig`/canonical wire and `ConfiguredDelimitedFormat` with `skipLeadingLines` and
   `commentPrefix`. Decode older configs with `0`/absent defaults. Validate a non-negative line count and an exact
   non-empty prefix when present. Include both in canonical identity.
5. Apply leading-line skip before header/record parsing and recognize comments only at the beginning of a logical
   record outside quotes. Preserve strict width and syntax. Count skipped physical lines/comments for trace and
   provenance; never activate either in response to a parse failure. Do not add padding, truncation, footer or
   malformed-record recovery.
6. Tighten header errors before constructing `FieldId`: empty labels report one-based column; duplicates,
   missing/extra labels and width errors retain dedicated source/record/column diagnostics. Expected parser
   validation failures become candidate rejection evidence only inside a probe boundary.
7. Add a delimited probe mode that drives the same framing/tokenization/header/schema/typed-decode machinery as
   execution. It ignores only a final logical record cut by the byte boundary, treats a contained syntax failure
   as rejection, and considers at most 100 complete logical records itself. A quoted newline is data; no generic
   physical-line pre-split is introduced.
8. Implement strength rules: content-only needs at least two consistent multi-column complete records; one-column
   parsing is no evidence; exact structured extension may validate a header-only/one-record file; declared
   schema/header/typed constraints remain authoritative. Equal strongest specs return ambiguity rather than using
   registration order.
9. Implement content-only header inference exactly as analysis §7.5. Require unique non-empty identifier-like row
   one plus stable Boolean/integer/decimal contrast below it. Otherwise emit row one and use `c0`, `c1`, … . An
   extension-selected candidate keeps its configured header policy; a schema-bearing candidate never weakens it.
10. Add built-in semicolon and pipe configured instances and detection metadata. CSV's structured family admits
    comma and semicolon; TSV remains appropriately narrow. Authored configured-delimited formats participate only
    when their full declaration validates.
11. Add `PlainTextReaderCapability` and configured format. It emits stable `Record(line: Text)`, supports LF/CRLF/
    lone CR, preserves blank lines, emits the final unterminated line and emits zero rows for empty input. Apply
    expanded-byte, record/field length, timeout and cancellation limits to arbitrarily long lines.
12. Register `.md` as semantic text and `.txt`/`.log` as generic text through format metadata. Semantic hints select
    Plain text before structured probing. Generic hints still probe and select Plain text without warning when no
    structure wins. Unknown/absent valid text uses fallback provenance; structured-family rejection/tie fails.

## Proof and exit

- Fixture matrix covers ordinary/regional/malformed CSV, TSV `.txt`, extensionless comma/tab/semicolon/pipe,
  header-only structured input, all-text header ambiguity, strong type contrast, quoted newlines and partial final
  sampled records.
- Markdown with a leading blank line and Markdown tables resolve to Plain text; line-reader tests prove exact blank,
  separator and final-line behaviour.
- BOM agreement/conflict, misleading gzip suffix, gzip/plain equivalence, UTF-8, constrained Windows-1252,
  undefined bytes, NUL/control and explicit-encoding strictness are green.
- Parser tests cover skip/header ordering, comments only at logical record boundaries, skipped counts, empty header
  labels before `FieldId`, and unchanged strict width/syntax failures.
- Instrumented fake input proves one shared acquisition, per-candidate record counting, byte/time/cancellation
  bounds and close on every exit. Warm cache hits read zero bytes; operational failures are absent from the cache.
- A contributed test-only delimiter candidate is selected without edits to resolver branches.
- Focused plugin/common/JVM tests and the full `../kzen-auto` build pass. Existing explicit CSV/TSV integration
  remains green and the File-source default is still CSV.

## Handoff to DR8c

The detector is callable with an explicit ref, fingerprint, source-level format and optional overrides, and returns
only concrete execution state plus common provenance. DR8c integrates that operation before `DataPart` creation.

## As-built

- Implemented `AutomaticFormatResolver` with one bounded sample-acquisition flow, strict decoding, contributed candidate
  probing, deterministic strongest-result selection, structured-hint failures and safe Plain-text fallback.
- Added CSV, TSV, semicolon and pipe configured instances. `DelimitedProbe` reuses the production parser, preserves
  all-text row one, applies conservative type-contrast header inference, distinguishes exact extensions from family
  hints and enforces one shared 100-complete-record allowance across every framing/character-view attempt.
- Added strict UTF-8/BOM handling, constrained Windows-1252 fallback, binary-control rejection, gzip magic
  authority, `.gz` disagreement failure, mixed-case suffix handling and ZIP rejection. Cancellation and every
  acquisition/decode/probe failure close their handles and remain uncached.
- Extended delimited configuration and parsing with explicit nonnegative `skipLeadingLines` and optional exact
  comment prefix. Width, header and malformed-record diagnostics retain logical record/column context. The legacy
  six-argument `DelimitedReadConfig` constructor remains binary compatible for cached compiled scripts.
- Added the Plain-text reader and format with stable `Record(line: Text)` output, LF/CRLF/lone-CR support, blank-line
  preservation and correct final-line behavior. Semantic text hints select it directly; unhinted valid text reaches
  it only after structured candidates fail or tie.

The initial focused detector/reader suite passed in 46 seconds, with a separate cancellation gate in 13 seconds.
The final ceiling, decoder, acquisition, cache and measurement suites passed again before the full build.
