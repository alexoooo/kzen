# HS03 — Plain Java core, ITCH reader and synthetic oracle

> Status: not started. One implementation session. Prerequisites: HS01.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §4 and §5.2.

## Outcome and anchors

kzen-sample-plugin/pom.xml and its Java sample sources; create core and adapter Maven modules.

## Work

1. Read the sample's local guide if present. Split the Maven project into a zero-kzen Java core and a thin adapter. Preserve the cities sample logic for HS21; do not retire its existing entry point until the replacement is runnable.
2. Read the official ITCH 5.0 specification. Implement strict length-prefixed framing over raw/gzip input, closeable iteration and a sealed message-record family. Keep wire decoding separate from analytical state.
3. Add a seeded synthetic writer and independently specified expected events/results: equal timestamps, multiple locates, locate-zero events, execution-with-price/printability, replacements, full/partial fills, cancels/deletes, non-displayed/cross trades and breaks.
4. Define the named comparison result precisely as a fixture metric (per-symbol trade-event count and shares, correcting eligible prior events for breaks). Record whether non-printable executions count; use the analysis's all-E/C/P/Q event metric consistently, without calling it official exchange volume.
5. Cover truncation, bad lengths, unknown message types, invalid references and failed opening without leaking handles. Read the Nasdaq download terms for D2; never add real feed data to git.

## Verification and exit criteria

Run Maven core tests on Java 25. Prove the core dependency tree has no kzen artifact. Golden expected bytes/events must supplement writer-reader round trips so a shared encoding bug cannot pass. Demonstrate streaming decode with bounded live wire objects.

## Handoff

Record module/artifact names and parser policy. The core and fixture unlock HS04; reader adapters remain HS21.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
