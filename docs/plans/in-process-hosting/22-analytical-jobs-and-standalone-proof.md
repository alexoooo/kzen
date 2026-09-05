# HS22 — Analytical Workers, bundled Jobs and standalone plugin proof

> Status: not started. One implementation session. Prerequisites: HS21, HS12 and HS20.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.2 sample routes; E2/E3 complete acceptance.

## Outcome and anchors

Sample adapter Workers and notation; kzen-project standalone test home; compatibility kit.

## Work

1. Add thin Java analytical Workers over core book/lifecycle logic using HS11's ordinary-Java transform/completion bridge. Keep domain-specific folds in the core; a cursor-source base is for sources, not a substitute for a transform's input contract.
2. Bundle ItchDay file/reader analysis, canonical store-backed SymbolDay expression analysis, raw-reader ingestion as a separately named demonstration, and an object-graph projection/export Job.
3. Keep streaming raw-analysis state and materialized SymbolDay routes explicit. Reuse core algorithms without retaining two real full-day representations merely to compare results. The unrestricted plain expression route keeps its unlimited budget.
4. Run the compatibility kit against the actual plugin directory in an isolated standalone kzen-project home. Also test the same contributions on the application classpath in a separate JVM, preserving one runtime per process.
5. Verify Java reflection and Kotlin/KSP fixture acceptance, notation origins, two-plugin expression identity and diagnostics from E2/E3. Record any deferred checks rather than marking their phases complete prematurely.

## Verification and exit criteria

On the synthetic fixture, compare raw reader and store-backed expression routes with independently expected per-symbol counts/shares; verify book/lifecycle results separately. Check pre-run shape and path picker, closed-item results, folder and plugin-zero parity, no kzen source customization and no leaks. Smoke the actual bundled UI on an agent-owned server.

## Handoff

Close E2 and E3 only when their full authoritative matrices and HS12/HS21 tails pass. The third, host-object equality route is HS24/HS25.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
