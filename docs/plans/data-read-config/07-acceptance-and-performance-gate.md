# DR7 — acceptance and performance gate

> **Status: not started. One session.** Authority: configurable flat-data reading §§10, 11 step 7. Requires
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
