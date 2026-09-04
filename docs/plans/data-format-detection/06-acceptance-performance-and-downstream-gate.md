# DR8f — acceptance, performance and downstream gate

> **Status: complete — landed 2026-09-03.** Authority: automatic data-format detection §§3, 6, 9–12 and the settled decisions in §14.
> Requires DR8a–DR8e. This is the closing session and the only session that owns arc-wide measurement/publication.

## Outcome

Run the full behavioural, extensibility, lifetime, scale and performance matrix; fix only defects needed to satisfy
the authority; publish the changed SPI; rebuild known consumers; and record the final as-built result. The arc
closes only with bounded cold detection and unchanged warm streaming performance within the existing 20% gate.

## Preflight

1. Re-read `../kzen-auto/AGENTS.md`, `docs/CODING_STANDARDS.md`, this README and all five completed session As-built
   sections. Recheck the authority's deferred list so test-driven scope creep does not add repair or workbook
   features.
2. Inspect all touched repositories with `git status --short`. Preserve user notation and unrelated WIP. If the
   sample plugin or kzen-project has its own `AGENTS.md`, read it before building or changing anything there.
3. Inventory production branches over concrete format/reader names. The only concrete knowledge should be inside
   built-in capability implementations and notation registrations, never Automatic, File source, shared UI or
   source reconciliation.

## Acceptance matrix

1. **Selection/fallback:** leading-blank Markdown, Markdown table, ordinary `.txt`/`.log`, TSV `.txt`, regional and
   malformed `.csv`, explicit malformed CSV, empty text, hinted Windows-1252, explicit strict encoding,
   extensionless invalid UTF-8, undefined CP1252 bytes and binary controls.
2. **Structured detection:** extension header retention, extensionless comma/tab/semicolon/pipe, header-only hint
   requirement, type-contrast header inference, all-text row-one retention, declared schema validation and strongest
   ties under unhinted versus structured-family policy.
3. **Coding/bounds/lifetime:** plain/gzip equivalent specs apart from coding, gzip magic/suffix disagreement, BOM
   agreement/conflict, truncated final sample versus contained syntax error, candidate-owned logical records,
   per-part byte/record/time limits, cancellation at acquisition/decode/probe and close on every failure.
4. **Cache:** warm zero-read hit; invalidation by fingerprint, hints, candidate set/digest, probe compatibility and
   policy; canonical candidate ordering; no cached operational failure.
5. **Source/Job:** heterogeneous per-part specs, `superset` and `strict`, per-file overrides, provenance wire,
   runtime fresh-fingerprint detection, captured-manifest migration and no detection in cursor opening.
6. **UI/authoring:** row epochs and states, unavailable persisted choices, contributed editor selection,
   delimiter/header/encoding/skip/comment materialization, source-local isolation, Make explicit semantics, Lock
   columns drift rejection and graph round-trip.
7. **Extensibility:** one test-only reader/format contributes candidate metadata and a probe without generic code
   edits; a second contributes an override editor; a third detects without authoring and gets the correct disabled
   actions. Unknown/duplicate identities fail at their declared boundaries.

## Scale and performance proof

1. Instrument cold detection separately from execution. Record bytes, complete logical records considered,
   acquisitions, elapsed time and cache state for representative CSV, regional CSV and Plain text.
2. Prove per-part defaults as hard ceilings: 256 KiB decoded sample, 100 complete logical records per candidate and
   two seconds including acquisition/decode.
3. Resolve a synthetic cold directory with delayed/counting providers and prove at most four acquisitions in
   parallel, at most 256 cold parts, at most 64 MiB decoded samples and at most 15 seconds. Exercise each limit
   independently, verify no partial manifest, and verify no majority-derived specs.
4. Re-run DR7's generic external 100,000-row canary from `../kzen-auto`. Record cold detection separately, then run
   the configured-reader and Job end-to-end warm measurements. Enforce the agreed floors of 981,006 reader rows/s
   and 448,875 Job rows/s (20% below DR7 baselines) unless the measurement protocol itself has changed; any protocol
   change requires an explained comparable baseline before judging regression.
5. If a threshold fails, localize it to acquisition/detection, parser or Job before changing code. Add no pooling,
   leases or buffering optimization without a measured cause and a separately reviewable diff.

## Build and publication gate

Run from each sibling's own directory, never from the umbrella:

1. focused common JVM/JS, plugin, JVM reader/source/action/Job and JS store/component tests;
2. `cd ../kzen-auto; .\gradlew.bat :kzen-auto-jvm:test --tests "*FormulaStepTest"` as the toolchain canary;
3. full `cd ../kzen-auto; .\gradlew.bat build`;
4. `cd ../kzen-auto; .\gradlew.bat publishToMavenLocal` because the plugin SPI changed;
5. the sample plugin's full Maven test/build, including `SampleExtensionTest`; and
6. full standalone `cd ../kzen-project; .\gradlew.bat build` against the newly published kzen-auto artifacts.

No version bump is part of this arc. A consumer failure caused by a real SPI incompatibility is fixed before close;
an unrelated pre-existing failure is recorded with evidence and surfaced rather than hidden.

## Final review and close

- Run `git diff --check` in every touched repository and review all code against CC-01–CC-17. Pay special attention
  to generic-name/concrete-format branches, replacement decoding, silent fallback, cache-key omissions and
  background notation writes.
- Confirm no production source, fixture or symbol embeds the external canary path/domain.
- Append exact test counts, measurement tables, changed thresholds and deviations under `As-built` in this file.
- Mark DR8a–DR8f complete in this directory's README and in the master ledger. Update the data-reading architecture
  authority only where the implementation changed a lasting contract.
- The arc is complete only when `Automatic` is the shipped File default, every manifest is concrete, all requested
  corrective actions are intentional, and every deferred format/recovery feature remains deferred.

## As-built

The acceptance matrix is implemented across focused common, plugin, JVM and JS suites. The final additions cover
selection/fallback and encoding safety, structured ranking, gzip/BOM disagreement, sample truncation, cancellation
and close behavior, all cache dimensions, heterogeneous strict/superset sources, per-file overrides, provenance,
migration, contributed probing/editor/non-authoring cases, authoring isolation and explicit/locked drift.

Cold detection has an optional no-op observer; normal runtime produces no logging. A contributed probe reports
complete logical records synchronously, and the built-in probe shares one hard allowance across all framing and
character-view attempts. Observer failures cannot change resolution behavior.

| Scenario | Phase | Decoded bytes | Acquisition codings | Complete records by candidate | Elapsed | Cache state |
|---|---:|---:|---|---|---:|---|
| Comma CSV | cold | 25 | identity | CSV 3; semicolon 3 | 198.030 ms | Cold |
| Comma CSV | warm | 0 | none | none | 17.436 ms | WarmBeforeAcquisition |
| Regional semicolon CSV | cold | 25 | identity + gzip | CSV 3; semicolon 3 | 30.346 ms | Cold |
| Regional semicolon CSV | warm | 0 | none | none | 13.236 ms | WarmBeforeAcquisition |
| Plain text | cold | 27 | identity | CSV 2; pipe 2; semicolon 2; TSV 2 | 25.140 ms | Cold |
| Plain text | warm | 0 | none | none | 11.470 ms | WarmBeforeAcquisition |

Synthetic source tests independently exercised four concurrent acquisitions, 256 cold parts, 64 MiB decoded bytes
and the 15-second deadline through injected smaller policies. Every exhaustion failed the whole resolution, closed
started handles and produced neither partial manifests nor majority-derived specs. Per-part tests pin 256 KiB,
100 complete logical records across all attempts and two seconds including acquisition/decode.

The unchanged DR7 external 100,000-row protocol passed with these final measurements:

| Path | Median | Range | Throughput | Required floor | Heap delta | Peak growth | GC |
|---|---:|---:|---:|---:|---:|---:|---:|
| Configured reader | 96.9 ms | 81.4–98.7 ms | 1,032,270 rows/s | 981,006 rows/s | 25,729,608 B | 92,274,688 B | 1 / 2 ms |
| Job end to end | 194.6 ms | 192.8–247.5 ms | 513,918 rows/s | 448,875 rows/s | 92,552,088 B | 136,592,280 B | 1 / 1 ms |

The canary read 100,000 rows with checksum `5c873a88ffc9ecbb` and aggregate `decimal:1783037.8`. Its configured
reader path is intentionally pre-resolved, so the separate observer table above owns cold-detection measurement.
No threshold or protocol changed.

Final gates:

- focused observer/probe/cache tests: 13/13; focused common/plugin gate: green;
- final post-preview-fix `../kzen-auto` build: 1,851 tests, zero failures/errors, one existing skip, 5m32s;
- FormulaStep canary: 10/10;
- `publishToMavenLocal`: green after the final plugin SPI change;
- sample plugin `clean verify`: green, eight Java sources, dependency convergence green, no test sources;
- standalone `SampleExtensionTest`: 3/3; full `../kzen-project` build: green; both consumer trees stayed clean;
- isolated packaged-client graph/DOM/console/editor-registration check: green on port 18197; and
- `git diff --check` and the final concrete-name/cache/fallback/cursor-write/canary-path audit: clean.

The first integration build exposed three compatibility assumptions that were fixed before the final gate: cached
scripts needed the old six-argument delimited-config constructor, a RunWorker-only fixture needed an explicit CSV
selection, and programmatic strict formats needed a zero-graph-match preflight path. No release version changed, and
JSON/NDJSON, columnar/workbook formats, probabilistic charset detection and repair/quarantine behavior remain
deferred.
