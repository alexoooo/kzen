# DR4 — configured delimited reader and atomic CSV/TSV cutover

> **Status: not started. One session.** Authority: configurable flat-data reading §§4.5–4.6, 6.3, 10.3.
> Requires DR1 (identity), DR2 (`RecordSchema`, prototypes), DR3 (content stack).

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
2. Implement the parser: framing and field tokenization share one state machine (quoted newline is field
   content; no `readLine()` pre-split). Strict width and unique field identity are the defaults; any tolerant
   projection is named and diagnostic-producing.
3. Header policies per the §4.5 table: header row consumed as metadata and validated against a declaration when
   present; headerless typed input requires a declared schema; positional labels remain the honest Text/dynamic
   fallback. No automatic header guessing.
4. Typed decoding (§4.6): declared semantic types produce typed accessors; decode options start with the
   null-token rule and locale-free numeric parsing, format-level defaults with per-field overrides, all
   digested. Settle the v1 malformed-value surface (analysis §13 q4): `fail-part` is mandatory and default;
   ship `skip-record` only with a counted diagnostic, otherwise notation rejects it — no no-op policy values.
   Failures carry source, unit, record index, field path and offending span, at the reader boundary.
5. Cursor `shape` is the resolved observation with honest provenance; runtime records are checked against the
   declared contract, never silently replacing it.
6. Atomic cutover: retire `CsvReaderWorker`/`MultiFileReaderWorker` as product surface, migrate built-in CSV/TSV
   coordinates and existing fixtures/notation to configured instances in the same session. No dual mode.

## Proof and exit

- §10.3 framing/tokenization matrix, including the checked-in generic headerless fixture (quoted delimiter,
  quoted newline, escaped quote, empty field, final-no-newline, CRLF/LF, wrong width, malformed typed value).
  Gzip fixtures generated deterministically from the checked-in plain bytes.
- End-to-end: local plain and local gzip through source → content → coding → characters → configured reader
  yield identical typed values and contract.
- The immediate tier works: selecting an ordinary `.csv` with no authored schema reads via the built-in
  configured instance with observed header labels and an honest Text/dynamic contract.
- §12 rejection sweep on the diff (no provider branches, no `Path` in reader APIs, no domain-named symbols).
- Full builds of every touched sibling, all pre-existing reader consumers green on the configured instances.
