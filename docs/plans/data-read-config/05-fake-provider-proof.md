# DR5 — fake object-store provider proof

> **Status: complete — landed 2026-09-01.** Authority: configurable flat-data reading §§4.2, 10.1. Requires DR4.
> Production S3 (credentials, retries, pagination, browser) stays deferred.

## Scope and outcome

A test fake object-store provider proves the reader stack is provider-neutral: the same configured delimited
reader, unchanged, consumes plain and gzip objects behind opaque bucket/key-like ids. The neutrality is pinned
architecturally as well as behaviourally. This is a full reader/provider **conformance suite**, not the first
proof that a sourced ref can open — DR3's minimal in-memory provider already proved lookup, fingerprint
handshake and acquisition cancellation (analysis §11 step 5).

## Implementation

1. Implement the fake provider intentionally unlike the local one at its boundary (§4.2): opaque ids, an object
   fingerprint, bytes held behind the provider API, a sourced-ref `DataSourceId` resolution path. If a test
   passes only by converting an id to a temporary `Path`, the contract is not proven — that is the failure
   condition to design against.
2. Run the DR4 reader suite over fake-provider refs: plain and gzip, same configured format and schema,
   asserting values and contract identical to the local runs, and that the provider contains no gzip branch.
   Repeat the highly-compressible expanded-byte-limit and inspection-timeout cases through the fake provider so
   operational policy is proven above provider dispatch, not only on local files.
3. Capability mismatch: a reader requiring the test-only unknown capability (FR21) over the fake provider's
   sequential-only content fails before parser construction, naming required and available capabilities.
4. Cancellation and lifetime over the fake provider: both §9 races, close-counting at the provider handle.
   Fingerprint handshake over the fake provider: an object whose observed fingerprint changed after resolution
   is rejected, never cached or parsed.
5. Pin the architecture: a focused dependency/package test asserting production parsing code imports no
   filesystem or provider SDK type (§10.1).

## Proof and exit

- Full §10.1 matrix green: local plain, local gzip, fake plain, fake gzip converge on identical typed output;
  capability mismatch fails early with diagnostics; expanded-byte/timeout failures and close behaviour are
  provider-independent.
- The dependency pin test fails when a filesystem/SDK import is introduced into parsing code (verified by a
  deliberate temporary violation during the session, then reverted).
- Full build of every touched sibling.

## As-built — 2026-09-01

The test fake object store exposes opaque object identifiers, fingerprints and sequential bytes without
materializing a temporary filesystem path. The unchanged configured reader runs over local and fake-provider
plain/gzip content. Provider code contains no compression branch; coding and policy enforcement remain above
provider dispatch.

Conformance coverage includes fingerprint mutation, capability mismatch before parser construction,
expanded-byte and inspection limits, acquisition/pull cancellation and exact close counts. A production-source
neutrality test searches for forbidden filesystem and provider-SDK dependencies. Production S3 remains
intentionally deferred. The fake-provider matrix and final full build are green; closing evidence is in DR7.
