# HS06 — Early real-day storage and memory gate

> Status: not started. One implementation session. Prerequisites: HS05; D2 download terms recorded in HS03.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §9 P1 and §5.2.1.

## Outcome and anchors

Sample core benchmark/measurement entry point, durable source/store area.

## Work

1. Download one selected Nasdaq day on demand outside git and job/. Record source/date/fingerprint, machine/JDK, heap limit and storage conditions.
2. Measure sequential decode and store build throughput, disk size and open writer bounds. Select representative and largest partitions from catalog counts; materialize one at a time.
3. Measure native allocation separately from peak heap, retained persistent history, active order-reference state and reconstruction temporaries. Record per-symbol replay and an actual historical query such as depth before trade.
4. Derive documented weight coefficients/headroom from evidence. Check the predicted largest item against the intended budget; exercise explicit oversized failure.
5. Repeat load/query/close enough times to expose native leakage and accumulating retained state. Confirm ordinary runs do not depend on Cleaner to return permits.
6. Adjust the core representation if the measured cost is impractical, and rerun only affected measurements. Record a failed or resource-limited measurement honestly; do not substitute extrapolation for a measured largest-symbol result.

## Verification and exit criteria

P1-early requires reproducible native/heap figures, estimate-versus-observation and an explicit proceed/revise verdict. Preserve only code and concise results; no real feed or giant raw profiling artifacts in git. A resource limitation gates the heavy sample/host proof, while independent generic E work can continue.

## Handoff

Record the chosen day, commands, results and multiplier here. HS21–HS25 use this baseline; P1-final is HS25.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
