# DR8a — resolution contracts, discovery and optional capabilities

> **Status: complete — landed 2026-09-03.** Authority: automatic data-format detection §§2–3, 5.1–5.4, 6, 7.3 and 14. Requires the
> completed DR1–DR7 configurable-reading arc. This session changes contracts and registry behaviour but does not
> change the File-source default or perform content detection.

## Outcome

Establish the common wire models and the server-side discovery boundary used by every later session. A configured
format can resolve contextually, installed formats expose contributed hint/candidate metadata through one
graph-backed registry, a reader may optionally probe an in-memory sample, and a format may optionally materialize
an authored override. Existing CSV/TSV formats still resolve exactly as they do before this session.

## Preflight and current anchors

Re-read the authority and inspect these live seams before editing:

- `kzen-auto-common/.../data/format/ConfiguredRecordFormat.kt` — fixed `resolvedRead(ref)` contract;
- `kzen-auto-common/.../data/model/DataResolveResult.kt`, `DataModelKeys.kt` and their common codec tests;
- `kzen-auto-common/.../data/file/FileSelectionEntry.kt` — the persisted format/encoding shape that must remain;
- `kzen-auto-plugin/.../api/data/ReaderCapability.kt` and `ReaderInspectionRequest.kt`;
- `kzen-auto-jvm/.../data/read/ReaderCapabilityRegistry.kt`;
- `kzen-auto-jvm/.../objects/datasource/DataSourceActions.kt` — current ad-hoc format enumeration; and
- `kzen-auto-jvm/.../objects/datasource/format/ConfiguredDelimitedFormat.kt` plus its notation archetype.

Record any anchor movement in the As-built section rather than preserving stale wrapper APIs.

## Implementation

1. Add common immutable models for a format-resolution request and result. The request carries `DataContext`,
   `DataRef`, expected fingerprint, normalized provider/filename hints and optional explicit encoding. The result
   carries the concrete `ResolvedReadSpec` plus the resolution detail required by analysis §5.3: ref, optional
   concrete format reference, display label, explicit/automatic selection, override/extension/content/fallback
   basis, reason and optional warning.
2. Extend `DataResolveResult` with a default-empty ordered resolution-detail collection. Update both
   `ExecutionValue` and kotlinx-serialization forms so an older payload with no member decodes to empty. Keep the
   details out of `DataPart.digest()`; the concrete resolved spec remains semantic execution identity.
3. Add `ConfiguredRecordFormat.resolve(request)` as the canonical suspendable operation. With no encoding override,
   its default delegates to the current fixed `resolvedRead(ref)` result. With an override, the default fails as
   unsupported; character-based formats such as configured delimited and Plain text override the operation and
   rebuild their own typed config. Generic code never rewrites opaque `ExecutionValue`. Retain `resolvedRead(ref)`
   only as the release-local compatibility seam, deprecate it, and route no new production caller through it.
4. Define common hint metadata with normalized exact extensions/media hints and the three explicit classes:
   structured family, generic text, and semantic text. Structured metadata names a contributed family identity;
   compatibility is many-to-many, allowing comma and semicolon candidates to accept the same `.csv` family.
   Unknown/absent is represented by missing metadata, not a catch-all registered candidate.
5. Define detection-candidate metadata around a concrete configured format: stable format reference, format digest,
   exact extensions, compatible structured families and its fixed candidate `ResolvedReadSpec`. `Automatic` is
   explicitly ineligible. Candidate-set canonicalization is by stable identity/digest, independent of registry
   iteration order.
6. Add optional `ReaderProbeCapability` in `kzen-auto-plugin`, separate from `ReaderCapability`. Its request receives
   candidate config, normalized hints, bounded post-coding raw bytes, the policy-permitted strict character views,
   end-of-input knowledge and policy limits. It receives no provider handle and no generic record count. Its result
   distinguishes no-match, content-strong and extension-validated, may return a canonicalized config, and carries
   concise evidence or an expected rejection. Unexpected exceptions remain exceptions.
7. Add optional `FormatAuthoringCapability` and a neutral common materialization request/result. It converts a
   capability-owned canonical config plus an optional observed `RecordSchema` into validated notation bodies and
   editor metadata; it does not write a graph. A format without it remains detectable and selectable, while Make
   explicit/Lock columns report that authoring is unavailable.
8. Replace `DataSourceActions.fileFormats()`'s literal marker scan with one `ConfiguredRecordFormatRegistry` service
   backed by the current graph definition/instances. It resolves coordinates, lists catalog entries, supplies
   hint/candidate/editor metadata, and reports definition failures with the same graph diagnostics used elsewhere.
   `DataSourceActions`, later `FileDataSource`, and later authoring actions all depend on this service.
9. Extend `ReaderCapabilityRegistry` to index the optional probe interface by reader compatibility identity and the
   optional authoring interface by its declared identity. Duplicate registrations fail at construction. Runtime
   reader discovery remains unchanged for capabilities that implement neither extension.
10. Define named detection policy and cache-key/value models. The default per-part policy is 256 KiB decoded bytes,
    100 candidate-owned complete logical records and two seconds. Its digest includes hint classification and the
    ordered encoding fallback list. The key additionally includes canonical ref hint identity, expected/observed
    fingerprint, normalized hints, canonical candidate reference/digest set and probe compatibility identities.
11. Add the bounded successful-result cache shell with explicit non-cacheable result categories. Do not acquire
    content or implement candidate ranking here; DR8b fills the service behind these contracts.

## Proof and exit

- Common codec tests cover new and legacy `DataResolveResult` payloads, all provenance variants, optional warning,
  and the fact that detail changes do not change `DataPart.digest()`.
- Contextual resolution of existing CSV/TSV formats is byte-for-byte/digest-equivalent to their fixed result,
  including gzip selection and explicit UTF-8 behaviour.
- Registry tests prove graph-discovered formats replace the literal marker scan, abstract/hidden formats remain
  excluded, unavailable persisted coordinates remain diagnosable, and duplicate optional capabilities fail.
- A test-only reader exposes probing without changing generic registry code. A second reader with no probe remains
  runnable and simply cannot become an Automatic candidate.
- Cache-key tests vary one dimension at a time: fingerprint, extension/media hint, candidate digest/set, probe
  compatibility and policy digest all miss; candidate enumeration order does not.
- Focused common JVM/JS codec tests, plugin tests, registry/action JVM tests, and the full `../kzen-auto` build pass.
- No File-source notation default, parser behaviour, or production selection behaviour changes in this session.

## Handoff to DR8b

DR8b receives stable request/result types, discovery, candidate enumeration, optional capability lookup and cache
identity. It must not revise these to smuggle parser-specific fields into generic models.

## As-built

- Added immutable resolution request/result, provenance, normalized hint, detection policy, budget, candidate
  identity and cache-key models. `DataResolveResult` now carries ordered resolution details in both wire forms while
  keeping them outside `DataPart` execution identity; legacy payloads decode with an empty collection.
- Made contextual `ConfiguredRecordFormat.resolve` the canonical suspendable API and retained the fixed call as a
  deprecated compatibility seam. Encoding overrides are accepted only by formats that can rebuild and validate
  their own typed configuration.
- Added optional `ReaderProbeCapability` and `FormatAuthoringCapability` plugin SPIs. Reader registration indexes
  the optional capabilities independently and rejects duplicate compatibility identities.
- Replaced literal format scans with `ConfiguredRecordFormatRegistry`. It discovers graph-backed catalog entries,
  candidates, hints, editor metadata and authoring availability; exact and unique semantic coordinates are stable,
  while ambiguous matches fail. Strict programmatic formats may resolve only when there is no graph match and never
  enter discovery.
- Cache identity includes canonical ref/fingerprint, normalized hints, explicit encoding, policy, probe identities
  and the complete candidate metadata digest. The final audit corrected an early implementation that hashed only
  the format body.
- Later sessions extended these contracts without format-name branches: per-file eligibility, materialization
  intent, locked-column provenance, full `ResolvedReadSpec` authoring input and passive detection observation.

Validation included common serialization/digest tests, plugin tests, reader-registry tests, configured-format
resolution tests and detached action tests. The closing full build exercised the final contracts as part of 1,851
tests with zero failures.
