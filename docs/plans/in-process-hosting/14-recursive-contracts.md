# HS14 — Recursive object contracts across JVM and JS

> Status: not started. One implementation session. Prerequisites: HS13.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E7 item 5; landed data-model contracts.

## Outcome and anchors

kzen-lib-common DataType/DataContract and their serialization, validation, algebra/digests; JVM resolver; kzen-auto contract consumers.

## Work

1. Add finite named type references/definitions as specified by E7. Audit every exhaustive DataType consumer and wire serializer before editing the hierarchy; update semantics, not just compiler branches.
2. Resolve self/mutual recursion lazily and preserve deterministic equality/digests. Keep loader-local native identity separate from a structural reference name; test same-name classes in separate scopes.
3. Ensure structural snapshot/deep validation remains bounded and reports cycles/limits rather than recursing forever. Native graph navigation remains on demand.
4. Carry definitions to the browser and expression design-time contract path. Represent collapsed recursive nodes without eagerly expanding them.
5. Publish kzen-lib, then rebuild consumers from their own directories; no release-train version bump.

## Verification and exit criteria

Test self/mutual recursion, recursive collections, serialization round trip, deterministic contract identity and bounded malformed/unresolved-reference errors. JVM and JS compile/tests must cover the new variant. A cold editor can traverse a recursive shape without running the source.

## Handoff

E7 closes when HS13 and HS14 proofs pass. HS19/HS20 own projection and the interactive picker, rather than treating a recursive schema as a finished UI.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
