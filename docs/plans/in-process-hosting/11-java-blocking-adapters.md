# HS11 — Java-friendly reader and cursor-source adapters

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS10.
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

Executed 2026-09-05. Module boundaries as resolved: the reader base is public SPI in **kzen-auto-plugin**
(`tech.kzen.auto.plugin.api.data.BlockingReaderCapability`); the Worker bases depend on JVM implementation
classes (`SourceWorker`, `TransformWorker`, `JobDataValues`) and live in **kzen-auto-jvm**
(`tech.kzen.auto.server.objects.job.worker.CursorSourceWorker`, `JavaTransformWorker`); no reverse dependency
from the plugin module was added. Java coordinates: `tech.kzen.auto:kzen-auto-plugin` for the reader,
`tech.kzen.auto:kzen-auto-jvm` for the Worker bases (both at the current train version, published to
mavenLocal with `:kzen-auto-plugin:publishToMavenLocal` before the fixture build).

**Adapters.**
- `BlockingReaderCapability`: implement `openBlocking(ReaderOpenRequest): DataCursor` and
  `inspectBlocking(ReaderInspectionRequest): DataShape`; the `suspend` pair is provided once. The bridge is a
  direct call: the framework already runs a reader's open/inspect/pulls where blocking is accounted for.
- `CursorSourceWorker`: the subclass's `open(control): Iterator<*>` returns an ordinary iterator; the framework
  owns every pull, lifting (`elementContract()` optional), batching, checkpoints, cancellation and close. Open
  and each pull run through `JobControl.runBlockingIo`. **Cancellation-safe acquisition:** a value produced inside
  the blocking body is captured before the body returns, so if cancellation wins the dispatch back to the
  coroutine the acquired cursor or item is closed rather than lost; a failing open leaves no cursor. A returned
  iterator that is `AutoCloseable` is closed exactly once on completion, failure or cancellation; an item the
  subclass hands out is the run's from that moment (identity-close). Live-edit migration detaches the open
  iterator to the replacement instance (`DetachedCursor.adopt()`, no re-open, no skip) and the engine closes a
  detached cursor whose instance was removed — the HS17 integration hook. Owned-item support is not claimed
  until E9 completes.
- `JavaTransformWorker`: `onElementBlocking(element, control): Iterator<*>?` sees the element's boundary object
  (`JobDataValues.boundary`) and returns outputs; `onCompleteBlocking(control)` adds trailing outputs; the
  framework runs both through `runBlockingIo`, lifts and emits (suspend) every output, and closes an
  `AutoCloseable` iterator once drained. No Continuation shim.

**Verification, `JavaAdaptersTest` with javac-compiled fixtures** (`src/test/java/.../javafixture`:
`JavaCountingSource extends CursorSourceWorker`, `JavaDoublingTransform extends JavaTransformWorker`,
`JavaBlockingReader extends BlockingReaderCapability`; notation `test/job/plugin/java-adapters-test.yaml`):
source → transform → collecting sink runs end to end (`0,0,1,2,2,4,total=3`), the closeable cursor is closed once
and every item created; a failing `open` is the run's `Outcome.Failed` with no cursor; a latch test cancels after
the first item is acquired inside the blocking body but before it is delivered — the acquired item and the cursor
are closed and nothing reaches the sink; the Java reader serves the suspend contract (open, pulls, inspect,
identity, encode/decode round trip). Existing scalar-source behaviour is covered by the unchanged Job suites in
the full build. Commands: `./gradlew :kzen-auto-jvm:test --tests "*JavaAdaptersTest"` and the full
`./gradlew build`; `compileTestJava` targets release 25 with `-parameters`.
