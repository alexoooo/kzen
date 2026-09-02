# DR7 — acceptance and performance gate

> **Status: complete — landed 2026-09-01.** Authority: configurable flat-data reading §§10, 11 step 7. Requires
> DR1–DR6. The arc's closing gate: no optimization (pools, leases, buffering changes) may be introduced before
> this session's measurements exist.

## Scope and outcome

Run the complete acceptance surface — fixture matrices, full sibling builds, and the opt-in external
100,000-row canary — and record the throughput/memory baseline that any future optimization must beat.

## Implementation

1. Sweep the checked-in fixture matrices from all prior sessions in one run: composition/neutrality including
   stale-fingerprint rejection and gzip integrity (§10.1), character decoding (§10.2), framing/tokenization
   including record-syntax failures, complete budget cases (expanded bytes, record/field characters, field count,
   inspection records/bytes/timeout) and Decimal precision (§10.3, §9.1), semantic and operational
   identity/migration/cache behaviour (§10.4), lifetime (§10.5), Job/UI/expression propagation (§10.6).
2. Build the generic canary harness (§10.7): path/ref, configured format, expected row count and optional
   performance threshold arrive as test arguments; production dependencies see only an ordinary local source,
   resolved format and record schema. Absence of the external file skips only the labelled canary — it must not
   green ordinary reader tests by skipping them.
3. Run the canary against the external measurements file: exactly 100,000 records, exactly the two
   user-authored fields, typed access to the numeric field, correct final record and harness-chosen
   aggregate/checksum, bounded streaming memory.
4. Record throughput against the current flat-reader/Job baseline (J5a lineage), measured separately for
   parsing and for Job end-to-end so a regression can be assigned to the reader, typed projection or lane
   machinery, and settle the acceptable regression threshold (analysis §13 q6) with the user. Only a measured
   shortfall opens an optimization follow-up; it is scoped and reviewed separately, not folded into this
   session.
5. Final §12 rejection sweep across the arc's whole diff, and full builds of every sibling the arc touched
   (kzen-lib first with `publishToMavenLocal` if it changed, then kzen-auto, then dependents).

## Proof and exit

- All fixture matrices green in CI without the external file present.
- Canonical-wire vectors are green on JVM and JS: unordered map insertion changes no digest, ordered list changes
  do; operational-policy changes preserve semantic read identity but reject cursor adoption or inspection-cache
  reuse as applicable.
- Canary invocation green with the file present; measurements and the agreed threshold appended to this file
  as the as-built record.
- Master ledger and this arc's tracker updated; arc closes per the README lifecycle.

## As-built — 2026-09-01

A generic opt-in `dataReadCanary` JavaExec harness was added. Its input path, delimiter/dialect, header policy,
declared fields, expected row count, final record, checksum, warmups/runs, heap ceiling and optional performance
thresholds are supplied externally. Absence of the file produces a labelled skip without skipping ordinary
tests.

Independent preflight and the configured harness established for
`C:\~\data\measurements-100000.txt`:

- size: 1,379,295 bytes;
- exactly 100,000 headerless semicolon-delimited records;
- declared fields: `city: Text`, `measurement: Decimal`;
- final record: `["Karachi", "25.4"]`;
- exact Decimal aggregate: `1783037.8`;
- raw-text FNV-1a-64: `0f26b70a5bda4cd3d`;
- typed canonical FNV-1a-64: `5c873a88ffc9ecbb`.

The distinction between the two checksums is intentional: Java `BigDecimal.stripTrailingZeros().toString()`
canonicalizes values such as `30.0` as `3E+1`. The harness verifies the typed canonical stream; an independent
Java calculation reproduced its checksum before the measured rerun.

With one warmup and three measured runs under the default 1 GiB heap ceiling:

| Scope | Median | Spread | Throughput | Median heap delta | Median peak heap growth | Median GC |
|---|---:|---:|---:|---:|---:|---:|
| Configured reader | 81.5 ms | 79.9–111.3 ms | 1,226,257 rows/s | 22,546,936 bytes | 82,837,504 bytes | 1 collection / 2 ms |
| Job end-to-end | 178.2 ms | 169.3–268.7 ms | 561,093 rows/s | -99,175,808 bytes | 60,207,744 bytes | 2 collections / 3 ms |

The negative Job heap delta reflects collection between the before/after observations; peak growth is the
useful bounded-memory observation. No pooling, leasing or optimization was introduced before measurement.

### Closing evidence

- `kzen-lib` full build: 918 tests, zero failures; `publishToMavenLocal` green.
- `kzen-auto` full build after the final adversarial fix: 1,721 tests, zero failures, one intentional skip; all common/JVM/JS/plugin/test modules
  included.
- Dynamic-expression adversarial regression gate: 45 tests, zero failures, covering real Filter/Formula workers
  under a declared Dynamic lane and concrete Record `key`/`key("amount")` coexistence.
- Explicit `:kzen-auto-jvm:test --tests "*FormulaStepTest"`: 10 tests, zero failures.
- Current `kzen-auto` `publishToMavenLocal`: green.
- Standalone dependent `kzen-project` build: seven tests, zero failures, one intentional skip.
- External canary: green with 100,000 typed records, final record, checksum and exact aggregate verified.
- Adversarial review findings remediated; legacy/provider-neutrality/domain rejection sweeps and staged/unstaged
  `git diff --check` are clean. Protected user notation files were not modified.
- User-agreed maximum acceptable throughput regression: **20%**. Against the captured baselines this enforces
  floors of 981,005.6 rows/s for the configured reader and 448,874.4 rows/s for Job end-to-end (operationally,
  981,006 and 448,875 whole rows/s).
- Threshold-enforced confirmation run: configured reader 1,091,721 rows/s; Job end-to-end 628,485 rows/s;
  canary passed with the 100,000-row count, final record, typed checksum and exact aggregate unchanged.
