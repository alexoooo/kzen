# DR5 — fake object-store provider proof

> **Status: not started. One session.** Authority: configurable flat-data reading §§4.2, 10.1. Requires DR4.
> Production S3 (credentials, retries, pagination, browser) stays deferred.

## Scope and outcome

A test fake object-store provider proves the reader stack is provider-neutral: the same configured delimited
reader, unchanged, consumes plain and gzip objects behind opaque bucket/key-like ids. The neutrality is pinned
architecturally as well as behaviourally.

## Implementation

1. Implement the fake provider intentionally unlike the local one at its boundary (§4.2): opaque ids, an object
   fingerprint, bytes held behind the provider API, a sourced-ref `DataSourceId` resolution path. If a test
   passes only by converting an id to a temporary `Path`, the contract is not proven — that is the failure
   condition to design against.
2. Run the DR4 reader suite over fake-provider refs: plain and gzip, same configured format and schema,
   asserting values and contract identical to the local runs, and that the provider contains no gzip branch.
3. Capability mismatch: a sequential-requiring reader over a range-only fake handle fails before parser
   construction, naming required and available capabilities.
4. Cancellation and lifetime over the fake provider: both §9 races, close-counting at the provider handle.
5. Pin the architecture: a focused dependency/package test asserting production parsing code imports no
   filesystem or provider SDK type (§10.1).

## Proof and exit

- Full §10.1 matrix green: local plain, local gzip, fake plain, fake gzip converge on identical typed output;
  capability mismatch fails early with diagnostics.
- The dependency pin test fails when a filesystem/SDK import is introduced into parsing code (verified by a
  deliberate temporary violation during the session, then reverted).
- Full build of every touched sibling.
