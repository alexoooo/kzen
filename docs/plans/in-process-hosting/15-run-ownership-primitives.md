# HS15 — E9 ownership ledger and native lifetime primitives

> Status: not started. One implementation session. Prerequisites: HS01; refresh current DataValue and JobControl APIs. Serialize with HS13/HS14 where files overlap.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E9 identity, owner sets, Borrowed and teardown contracts.

## Outcome and anchors

JobControl/JobRun, JobDataValues; kzen-lib native value access; kzen-auto-plugin Borrowed.

## Work

1. Add the per-run identity ledger with named leases and a process-wide weak identity registry for owned-by-run/closed states. Lift remains run-blind. One native can belong to only one run for its lifetime.
2. Implement owner-set propagation and Borrowed semantics, including a borrowed closeable child versus a newly owned derivative. Lease transfer cannot hit zero between holders; a child's cleanup needing its parent happens while that parent remains live.
3. Add retain/release and named use-after-close guards with thread-safe adoption/closure and idempotent cleanup claims. Strong references must leave closed ledger entries; weak registry bookkeeping must not pin the graph.
4. Implement best-effort close-all with processing failure primary and close failures suppressed, using the JobRun post-join teardown seam. Keep these primitives additive until transport and source boundaries are wired.
5. Create reusable close-counting/cross-run/throwing-close fixtures for later sessions. Do not claim route-wide E9 support from primitive unit tests.

## Verification and exit criteria

Test identity through multiple wrappers, competing-run adoption, closed tombstones, owner-set close ordering, Borrowed suppression, concurrent final releases and cleanup failure precedence. Check weak bookkeeping permits collection. Existing unowned-value behavior must remain intact.

## Handoff

HS16 integrates channels/Worker loops; HS17 integrates streams and acquisition. E9 is not complete or externally advertised until HS18.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
