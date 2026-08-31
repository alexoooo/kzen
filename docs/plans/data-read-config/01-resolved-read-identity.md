# DR1 — resolved-read identity and capability model

> **Status: not started. One session.** Authority: configurable flat-data reading §§1, 4.2 (vocabulary only),
> 5, 10.4; project-data analysis ST16.

## Scope and outcome

Introduce the identity layer without changing active reader behaviour: the immutable `ResolvedReadSpec`
envelope (reader capability identity + content codings + capability-owned `ReaderConfig`), the
`DelimitedReadConfig` member set, the content-capability vocabulary (`SequentialBytes`, `Ranges`, `Rows` as
declared requirements), canonical digests, and the combined part identity
`role + canonical ref + content fingerprint + resolved-read digest` used by manifests, the schema cache and
migration.

The current opener keeps running unmodified; this session only adds the value model, digest rules and their
tests, plus the `DataPart` carriage decision.

## Implementation

1. Re-read the analysis §5 and the current `DataPart`/`DataOpenerLookup`/schema-cache implementation; confirm
   which sibling owns each surface before editing.
2. Define `ResolvedReadSpec`, `ReaderConfig`, `DelimitedReadConfig` (framing, dialect, header, characters,
   schema snapshot, typed decode) and `ReaderCapabilityIdentity` as immutable values. Settle the identity's
   canonical wire form and compatibility/version token (analysis §13 q2) — capability-supplied, never a runtime
   class name.
3. Implement the canonical digest: every member included, independent of map insertion order where order is not
   semantic; the reader digests its own config, the envelope combines.
4. Keep content fingerprint and resolved-read digest as distinct identities (§5.2): local fingerprint may start
   as canonical ref id + size + modified time; the vocabulary leaves room for provider-opaque tokens.
5. Decide and implement `DataPart` carriage (§5.1): embedded canonical snapshot, or reference plus resolved
   definition digest with the snapshot in run state. Either way, nothing re-resolves the mutable reference
   mid-run, replacing today's coordinate-string-only `DataPart.digest()`.
6. Add migration-compatibility predicate: live-cursor adoption requires equal part identity **and** equal
   resolved-read digest (§5.3).

## Proof and exit

- §10.4 identity tests: starting from one cached identity, changing exactly one dimension (fingerprint,
  dialect, schema field, typed policy, coding, charset/BOM/malformed policy) misses the cache and rejects
  cursor adoption; re-resolving an unchanged graph with shuffled notation map order retains the key.
- Digest is stable across processes/platforms for the same snapshot.
- Full build of every touched sibling; zero behaviour change in existing reader tests.
