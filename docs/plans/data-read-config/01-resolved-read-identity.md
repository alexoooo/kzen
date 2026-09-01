# DR1 — resolved-read identity, reader capability and wire

> **Status: not started. One session.** Authority: configurable flat-data reading §§1, 4.2 (vocabulary only),
> 4.7, 5, 9.1, 10.4; project-data analysis ST16.

## Scope and outcome

Introduce the identity layer and the runtime contract that makes it executable: the immutable `ResolvedReadSpec`
envelope (reader capability identity + content codings + capability-owned `ReaderConfig`), the
`DelimitedReadConfig` member set, the reader capability/registry contract (§4.7), the canonical `ExecutionValue`
config wire and its explicit unordered-map/ordered-list contract (FR16/FR22), the fingerprint-handshake semantics
(FR17), canonical digests, and the combined part identity
`role + canonical ref + content fingerprint + resolved-read digest` used by manifests, the schema cache and
migration as their semantic base; inspection cache and live-cursor adoption additionally include their effective
operational-policy identity.

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
4. Implement the canonical `ExecutionValue` wire (FR16/FR22): generic envelope (identity, codings, canonical
   config data, digest) understood without loading the reader implementation; the capability
   decodes/validates/canonicalizes into its runtime config; run state holds the validated snapshot, resolved once.
   `MapExecutionValue` is used only for unordered named members, `ListExecutionValue` for every semantic sequence
   (including ordered key/value entries), and absent differs from explicit null. Serialization/display insertion
   order is never identity. Do not introduce `OrderedMapExecutionValue`: the repository-wide usage audit found no
   current keyed-and-ordered consumer.
5. Keep content fingerprint and resolved-read digest as distinct identities (§5.2): local fingerprint starts as
   canonical ref id + size + modified time, documented as a weak freshness token, never a content digest.
   `DataPart` carries the expected fingerprint; the expected-versus-observed comparison executes in DR3 when
   acquisition exists, but its semantics and carriage are settled here.
6. Replace `DataPart` identity (§5.1): the envelope replaces the coordinate-string `format`/`encoding` members
   and `DataPart.digest()`; the opener consumes the resolved snapshot; nothing re-resolves the mutable reference
   mid-run.
7. Define the operational-policy identity seam used by DR3/DR4 (§9.1): safety limits stay outside the semantic
   resolved-read digest, but effective run-policy equality gates live-cursor adoption and effective inspection
   policy participates in the inspection-cache key. Limit/timeout failures are never cached; policy identity uses
   the configured timeout duration, never a derived wall-clock deadline instant.
8. Add migration-compatibility predicate: live-cursor adoption requires equal part identity (which already
   includes the resolved-read digest) **and** equal effective run-policy identity (§5.3, §9.1).

## Proof and exit

- §10.4 identity tests: starting from one cached identity, changing exactly one dimension (fingerprint,
  dialect, header-mapping policy, schema field, typed policy or per-field override, coding, charset/BOM/malformed
  policy) misses the cache and rejects cursor adoption; re-resolving an unchanged graph with shuffled notation
  map order retains the key.
- Fixed common-test digest vectors run on JVM and JS: equivalent maps constructed in different insertion orders
  are equal and have equal digests; reversed lists have different digests; key/value changes differ; absent and
  explicit null differ. Capability canonicalization is idempotent (canonicalize → encode → decode → canonicalize).
- Operational-policy tests prove a limit-only change preserves semantic resolved-read identity but rejects cursor
  adoption; an inspection-policy change misses the inspection cache; a prior limit failure is not reused after a
  limit increase.
- Registry tests: capability resolved by identity without a `when` over reader names; duplicate registration
  fails at registration; an unknown reader identity fails with a diagnostic before any content work.
- A plugin-shaped test `ReaderConfig` subtype rides the envelope wire and round-trips through
  encode → digest → decode → validate without any common-code knowledge of its type.
- Opener integration green: existing reader behaviour unchanged through the replaced identity; no shadow
  `format`/`encoding` path remains.
- Full build of every touched sibling.
