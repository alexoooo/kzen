# DR3 — sequential content stack

> **Status: not started. One session.** Authority: configurable flat-data reading §§4.2–4.4, 9, 10.2, 10.5.
> Requires DR1's capability vocabulary.

## Scope and outcome

Resolve opaque refs to provider-neutral byte capabilities and wrap them with explicit content coding and
character decoding, with the ownership/close/cancellation rules proven by close-counting tests. After this
session, local plain and local gzip bytes reach a charset-decoded character stream through one composition,
with no filesystem type visible above the local provider — and a **minimal opaque in-memory provider** proves
provider lookup, fingerprint verification and acquisition cancellation before the configured reader (DR4)
depends on the stack (analysis §11 step 3). Expanded-byte and inspection byte/timeout budgets prevent gzip
expansion and unbounded content sampling; the inspection record bound and parser-specific record/field limits are
enforced when the reader arrives in DR4. The full fake-object-store conformance matrix stays in DR5.

## Implementation

1. Settle handle placement (analysis §13 q1): provider-neutral `SequentialByteContent` in common code as small
   byte interfaces, or JVM wrappers over channels — decide from actual consumer placement and record the choice
   here. Only `SequentialBytes` ships (FR21); the mismatch path uses DR1's test-only unknown capability.
2. Implement `DataContentProvider` + `DataContentDescriptor` (§4.2) and `DataContentProviderLookup`: plain refs
   go to the local provider, sourced refs resolve their durable `DataSourceId`, unknown providers fail with a
   source diagnostic before any reader work. Unsupported access fails before parser construction.
3. Execute the fingerprint handshake (FR17): acquisition returns a handle bound to an observed fingerprint or
   version; the composition root compares against `DataPart`'s expected fingerprint before parser work; mismatch
   fails with a source diagnostic and is never cached. For local files, open the handle and validate attributes
   against the resolved fingerprint.
4. Rework the local path: `FileDataOpener`'s ref→`DataLocation` conversion and the hard-coded
   `FileFlatDataSource` become the local provider's private interior; gzip inference moves out of
   `FileFlatDataStream`.
5. Implement the minimal opaque in-memory provider and sourced ref: opaque ids, bytes and fingerprint behind
   the provider API, exercising lookup, handshake and acquisition cancellation through the same composition.
6. Content coding (§4.3): explicit `none`/`gzip` wrappers over provider bytes; hints (extension, magic bytes)
   may preselect during resolution but the resolved spec is authoritative by open time. ZIP is explicitly not a
   coding. Gzip integrity is deterministic (§9.1): truncated/corrupt streams fail with a content-coding
   diagnostic; trailing bytes after the stream are an error. Cancellation is checked inside decompression, not
   only at record boundaries. Count bytes emitted after content decoding and fail at the effective expanded-byte
   limit before passing excess data outward.
7. Character decoding (§4.4): charset, BOM policy with the four-rule deterministic precedence, malformed-input
   policy (`REPORT`/fail default; replacement only when explicitly authored). Settle the BOM option names and
   generic UTF-16 no-BOM behaviour (analysis §13 q3). Failures carry source/part and byte offset. The decoder
   is a contract, not necessarily a physical `Reader` — fusion with byte-level tokenization stays eligible.
8. Operational policy (§9.1, DR1 seam): carry effective full-read and inspection limits through the composition
   root without adding them to `ResolvedReadSpec`; this layer enforces expanded bytes and elapsed timeout, while
   exposing the inspection record bound for DR4's reader. Policy digest gates cursor adoption/inspection cache as
   defined in DR1; limit/timeout failures are never cached.
9. Ownership (§9): construction transfers outward only on success; close is outside-in exactly once; failed
   construction closes acquired inner layers and suppresses secondary close failures; both cancellation races
   covered (acquiring side closes a never-returned handle).

## Proof and exit

- §10.2 character matrix: no-BOM, permitted BOM, UTF-16 BOM endianness, explicit-endian/BOM conflict, malformed
  fail with offset, malformed replace observable with a differing resolved-spec digest.
- §10.5 lifetime subset: success, exhaustion, early close, failure, cancellation during acquisition and during
  pull — close count exactly one per acquired resource at every layer, order outside-in, no finalizer reliance.
- Local plain and local gzip produce identical character streams for identical semantic content.
- Handshake tests: a local file mutated between resolve and open is rejected with a source diagnostic, never
  cached or parsed (§10.1 stale-fingerprint row); the in-memory provider proves the same over an opaque sourced
  ref, plus acquisition cancellation.
- Gzip integrity: truncated stream and trailing-data fixtures fail deterministically.
- A highly compressible fixture exceeds the expanded-byte limit inside content decoding, closes every acquired
  layer exactly once and is not cached. Raising only that limit retains semantic read identity but cannot adopt the
  old cursor.
- Inspection expanded-byte/configured-timeout changes miss the inspection cache; timeout cancellation is observed
  during acquisition, decompression and pull rather than only between records, and yields no partial successful
  inspection. DR4 adds the record-bound proof.
- Full build of every touched sibling; existing reader behaviour unchanged (the configured reader arrives in
  DR4).
