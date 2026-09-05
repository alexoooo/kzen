# HS21 — ITCH and cities Job reader adapters

> Status: not started. One implementation session. Prerequisites: HS06, HS11, HS13 and HS18; HS12 diagnostics implementation available.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.2 adapter routes and §7 cities decision.

## Outcome and anchors

Sample adapter module; BlockingReaderCapability, ReaderProbeCapability, FormatAuthoringCapability and service metadata.

## Work

1. Implement the Java ITCH reader adapter over the core, including config decode/validate/canonicalize/encode, required content, bounded shape inspection, symbol/message/time filters and flat typed projection.
2. Add bounded probe/authoring support through existing automatic-format mechanisms. Compressed content must use the reader/content contract correctly; never infer binary framing from an extension alone.
3. Re-cut cities as the simple BlockingReaderCapability sample, retaining its useful parsing logic. Once this replacement runs, retire the sample ReportDefiner and the pending plugins.yaml/legacy loader path from HS12.
4. Package unshaded adapter/core/dependencies as an installable jar set, preserving META-INF/services and notation resources. Inspect current packaging rather than assuming the old sample still shades.
5. Confirm public Java implementation uses no Continuation signatures and the core still has no kzen imports/dependencies.

## Verification and exit criteria

Run reader contract/config tests and tiny binary fixtures through the actual File worker. Verify automatic detection, explicit configuration, malformed/truncated content, gzip handling, correct static columns and closure. Run cities through its new Job route before removing the old one.

## Handoff

Record install layout and sample commands. E2/E3 external acceptance is still HS22; no real data enters the repository.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
