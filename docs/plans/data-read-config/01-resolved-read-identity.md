# DR1 — resolved-read identity, reader capability and wire

> **Status: not started. One session.** Authority: configurable flat-data reading §§1, 4.2 (vocabulary only),
> 4.7, 5, 10.4; project-data analysis ST16; review-1 §§3.1–3.3, 4.1.

## Scope and outcome

Introduce the identity layer and the runtime contract that makes it executable: the immutable `ResolvedReadSpec`
envelope (reader capability identity + content codings + capability-owned `ReaderConfig`), the
`DelimitedReadConfig` member set, the reader capability/registry contract (§4.7), the canonical `ExecutionValue`
config wire (FR16), the fingerprint-handshake semantics (FR17), canonical digests, and the combined part identity
`role + canonical ref + content fingerprint + resolved-read digest` used by manifests, the schema cache and
migration.

Only content capabilities with an implemented consumer ship: `SequentialBytes` plus a test-only unknown
capability identity for the mismatch path (FR21) — no `Ranges`/`Rows` types or methods.

Per the analysis transition rule (§5.1), this session includes the **minimum opener integration** that makes the
resolved snapshot canonical immediately: today's coordinate-string `format`/`encoding` members of `DataPart` and
their digest are replaced, not shadowed. No additive dual identity survives the session.

## Implementation

1. Re-read the analysis §§4.7, 5 and the current `DataPart`/`DataOpenerLookup`/schema-cache implementation;
   confirm which sibling owns each surface — **including which module owns the reader-capability SPI** (analysis
   §13 q2): if `kzen-auto-plugin`, the `:kzen-auto-plugin:publishToMavenLocal` rule applies from this session on.
   Record the decision here.
2. Define `ResolvedReadSpec`, `ReaderConfig`, `DelimitedReadConfig` (framing, dialect incl. header-mapping
   policy, header, characters, schema snapshot, typed decode with per-field overrides keyed by field path) and
   `ReaderCapabilityIdentity` as immutable values. Identity is a logical name qualified by an owning
   namespace/plugin coordinate plus a capability-supplied compatibility token — never a runtime class name.
3. Define the runtime reader capability contract and registry (§4.7): identity/version, config
   decode/validate/canonicalize, canonical config digest, required content capability, bounded inspection, and
   cursor opening over an acquired handle. Registration collisions fail loudly at registration. The generic
   composition root's orchestration is defined here even though the full stack arrives in DR3/DR4.
4. Implement the canonical `ExecutionValue` wire (FR16): generic envelope (identity, codings, canonical config
   data, digest) understood without loading the reader implementation; the capability decodes/validates into its
   runtime config; run state holds the validated snapshot, resolved once.
5. Keep content fingerprint and resolved-read digest as distinct identities (§5.2): local fingerprint starts as
   canonical ref id + size + modified time, documented as a weak freshness token, never a content digest.
   `DataPart` carries the expected fingerprint; the expected-versus-observed comparison executes in DR3 when
   acquisition exists, but its semantics and carriage are settled here.
6. Replace `DataPart` identity (§5.1): the envelope replaces the coordinate-string `format`/`encoding` members
   and `DataPart.digest()`; the opener consumes the resolved snapshot; nothing re-resolves the mutable reference
   mid-run.
7. Add migration-compatibility predicate: live-cursor adoption requires equal part identity **and** equal
   resolved-read digest (§5.3).

## Proof and exit

- §10.4 identity tests: starting from one cached identity, changing exactly one dimension (fingerprint,
  dialect, header-mapping policy, schema field, typed policy or per-field override, coding, charset/BOM/malformed
  policy) misses the cache and rejects cursor adoption; re-resolving an unchanged graph with shuffled notation
  map order retains the key.
- Digest is stable across processes/platforms for the same canonical `ExecutionValue` data.
- Registry tests: capability resolved by identity without a `when` over reader names; duplicate registration
  fails at registration; an unknown reader identity fails with a diagnostic before any content work.
- A plugin-shaped test `ReaderConfig` subtype rides the envelope wire and round-trips through
  encode → digest → decode → validate without any common-code knowledge of its type.
- Opener integration green: existing reader behaviour unchanged through the replaced identity; no shadow
  `format`/`encoding` path remains.
- Full build of every touched sibling.
