# DR3 — sequential content stack

> **Status: not started. One session.** Authority: configurable flat-data reading §§4.2–4.4, 9, 10.2, 10.5.
> Requires DR1's capability vocabulary.

## Scope and outcome

Resolve opaque refs to provider-neutral byte capabilities and wrap them with explicit content coding and
character decoding, with the ownership/close/cancellation rules proven by close-counting tests. After this
session, local plain and local gzip bytes reach a charset-decoded character stream through one composition,
with no filesystem type visible above the local provider.

## Implementation

1. Settle handle placement (analysis §13 q1): provider-neutral `SequentialByteContent` (and the range
   vocabulary as a declared-but-unimplemented capability) in common code as small byte interfaces, or JVM
   wrappers over channels — decide from actual consumer placement and record the choice here.
2. Implement `DataContentProvider` + `DataContentDescriptor` (§4.2) and `DataContentProviderLookup`: plain refs
   go to the local provider, sourced refs resolve their durable `DataSourceId`, unknown providers fail with a
   source diagnostic before any reader work. Unsupported access fails before parser construction.
3. Rework the local path: `FileDataOpener`'s ref→`DataLocation` conversion and the hard-coded
   `FileFlatDataSource` become the local provider's private interior; gzip inference moves out of
   `FileFlatDataStream`.
4. Content coding (§4.3): explicit `none`/`gzip` wrappers over provider bytes; hints (extension, magic bytes)
   may preselect during resolution but the resolved spec is authoritative by open time. ZIP is explicitly not a
   coding.
5. Character decoding (§4.4): charset, BOM policy with the four-rule deterministic precedence, malformed-input
   policy (`REPORT`/fail default; replacement only when explicitly authored). Settle the BOM option names and
   generic UTF-16 no-BOM behaviour (analysis §13 q3). Failures carry source/part and byte offset. The decoder
   is a contract, not necessarily a physical `Reader` — fusion with byte-level tokenization stays eligible.
6. Ownership (§9): construction transfers outward only on success; close is outside-in exactly once; failed
   construction closes acquired inner layers and suppresses secondary close failures; both cancellation races
   covered (acquiring side closes a never-returned handle).

## Proof and exit

- §10.2 character matrix: no-BOM, permitted BOM, UTF-16 BOM endianness, explicit-endian/BOM conflict, malformed
  fail with offset, malformed replace observable with a differing resolved-spec digest.
- §10.5 lifetime subset: success, exhaustion, early close, failure, cancellation during acquisition and during
  pull — close count exactly one per acquired resource at every layer, order outside-in, no finalizer reliance.
- Local plain and local gzip produce identical character streams for identical semantic content.
- Full build of every touched sibling; existing reader behaviour unchanged (the configured reader arrives in
  DR4).
