# DR4 — configured delimited reader and atomic CSV/TSV cutover

> **Status: not started. One session — or two at the green boundary below (review-1 §4.4).** Authority:
> configurable flat-data reading §§4.5–4.7, 6.3, 9.1, 10.3. Requires DR1 (identity/capability), DR2
> (`RecordSchema`, prototypes), DR3 (content stack).
>
> If one session proves unsafe, split at: (a) an inactive but fully tested configured parser/typed-value
> implementation (observable tests, no second user-visible mode); then (b) configured-format archetypes,
> built-in CSV/TSV instances and the atomic product cutover. The cutover itself stays atomic.

## Scope and outcome

One Custom-authored configured delimited format — framing, dialect, header policy, schema reference, typed
decode — replaces the hard-coded CSV/TSV product surface atomically. The reader emits typed
`FlatFileRecord`-backed `DataValue`s under one `DataContract` through the existing `DataCursor` lane. CSV and
TSV become built-in configured instances so the immediate tier (§1.1) stays one selection.

## Implementation

1. Define the `ConfiguredDelimitedFormat` archetype (creatable per DR2) composing `DelimitedReadConfig`:
   delimiter, quote, escape convention, record separator, empty-field semantics, trimming, header policy
   (present / absent / infer-positional-labels), schema reference, typed-decode policy. Validate the
   one-character delimiter at notation definition, never truncate silently.
2. Register the reader as a DR1 capability: the registry resolves it by identity and the generic composition
   root opens it — no direct wiring, no `when` over reader names (§4.7).
3. Implement the parser: framing and field tokenization share one state machine (quoted newline is field
   content; no `readLine()` pre-split). Strict width and unique field identity are the defaults; any tolerant
   projection is named and diagnostic-producing. Record-syntax failures are their own diagnostic category
   (§4.5): unterminated quote at end of input, quote inside an unquoted field, characters after a closing
   quote, bare CR/mixed separators; empty input is zero records; trimming applies to unquoted values only
   unless configured.
4. Budgets (§9.1): maximum record size and maximum field size fail with record index and configured limit;
   cancellation is checked inside long records. Budgets are execution policy — outside the digest, failures
   never cached.
5. Header policies per the §4.5 table: header row consumed as metadata; a declared read uses name-based mapping
   with exact set equality (reordering permitted, ordinals resolved at open; missing/extra/duplicate labels
   fail naming the labels; tolerant variants are named policy values, all digested); headerless typed input
   requires a declared schema; positional labels remain the fallback for an undeclared read, whose contract is
   an observed `Record` of Text fields. No automatic header guessing.
6. Typed decoding (§4.6): declared semantic types produce typed accessors; decode options start with the
   null-token rule and locale-free numeric parsing, format-level defaults with per-field overrides owned by
   `DelimitedReadConfig` keyed by field path (FR18), all digested. The v1 kind matrix is Text, bounded
   integers, Floating, Decimal, Boolean; a schema containing an unsupported kind is rejected at format
   resolution, before content opens. Decimal validates and stores canonical exact decimal text (FR19 reader
   side); no `Double` on the reader path. Settle the v1 malformed-value surface (analysis §13 q4): `fail-part`
   is mandatory and default; ship `skip-record` only with a counted diagnostic, otherwise notation rejects it —
   no no-op policy values. Failures carry source, unit, record index, field path and offending span, at the
   reader boundary.
7. Cursor `shape` is the resolved observation with honest provenance; runtime records are checked against the
   declared contract, never silently replacing it.
8. Atomic cutover: retire `CsvReaderWorker`/`MultiFileReaderWorker` as product surface, migrate built-in CSV/TSV
   coordinates and existing fixtures/notation to configured instances in the same session. No dual mode.

## Proof and exit

- §10.3 framing/tokenization matrix, including the checked-in generic headerless fixture (quoted delimiter,
  quoted newline, escaped quote, empty field, final-no-newline, CRLF/LF, wrong width, malformed typed value)
  plus the record-syntax failures, header-mapping cases (reordered / missing / extra / duplicate labels),
  oversized record/field budget cases, and Decimal values a `Double` round-trip would corrupt.
  Gzip fixtures generated deterministically from the checked-in plain bytes.
- End-to-end: local plain and local gzip through source → content → coding → characters → configured reader
  yield identical typed values and contract.
- The immediate tier works: selecting an ordinary `.csv` with no authored schema reads via the built-in
  configured instance with observed header labels and a contract that is an observed `Record` of Text fields
  (`Dynamic` only where structure is genuinely unknown).
- §12 rejection sweep on the diff (no provider branches, no `Path` in reader APIs, no domain-named symbols).
- Full builds of every touched sibling, all pre-existing reader consumers green on the configured instances.
