# HS11 — Java-friendly reader and cursor-source adapters

> Status: not started. One implementation session. Prerequisites: HS10.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §6 C; extensibility plan E2 Java SPI.

## Outcome and anchors

kzen-auto-plugin ReaderCapability; kzen-auto-jvm SourceWorker and JobControl.runBlockingIo. Resolve actual module boundaries before adding classes.

## Work

1. Add BlockingReaderCapability with ordinary Java openBlocking/inspectBlocking methods and one suspend bridge. Exercise the real Kotlin/Java ABI from javac rather than a Kotlin subclass.
2. Add the cursor-driven source base: Java returns an iterator; framework code owns open/pulls, conversion, checkpoints, batching and close. Place the Worker base beside SourceWorker if it depends on JVM implementation classes; do not add a reverse dependency from the public plugin module to kzen-auto-jvm.
3. Route blocking operations through the existing engine offload mechanism. Implement cancellation-safe cursor acquisition/cleanup across the dispatcher handoff, including failures before a cursor reaches its caller.
4. Define iterator/container identity-close behavior and the migration hook to integrate with HS17. This session does not claim support for owned items until E9's integration is complete.
5. Add the minimal Java transform bridge required by the analytical sample: ordinary per-element and completion callbacks return output iterators; the framework performs suspend emission. TransformWorker's existing callbacks are suspend, so the source adapter alone does not cover this case. Integrate returned iterator closure and E9 ownership with the same framework rules, not a Java Continuation shim.
6. Publish the public SPI and any required JVM artifacts at current versions before rebuilding a Java fixture.

## Verification and exit criteria

A Java-only fixture implements the reader, cursor source and transform/completion callbacks without Continuation, suspend emitter calls or Kotlin source. Verify interrupted open/pull, completion/failure closure, iterator/container identity and existing scalar-source behavior. Add a latch test for cancellation after successful cursor acquisition but before suspended delivery.

## Handoff

Record where each adapter lives and the Java dependency coordinates. HS17 adds the shared E9 item/stream ownership path; HS21 migrates cities and ITCH readers.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
