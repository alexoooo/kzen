# HS02 — Plain-jar Spring compatibility gates

> Status: not started. One implementation session. Prerequisites: HS01.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §9 G1–G7.

## Outcome and anchors

A session-owned temporary Maven project; existing KzenAutoContext, Application.ktorMain, ClasspathNotationMedia, ReflectiveClassMirror and reader SPI.

## Work

1. Verify current official Spring compatibility documentation and select a GA compatible with Java 25. Build plain jars with copy-dependencies and manifest Class-Path, not nested Boot jars.
2. Check Maven dependency convergence for Spring, Kotlin, Ktor/CIO, Netty, Guava and logging. Record exact dependency decisions; do not silently suppress convergence failures.
3. Start one existing context via create + ktorMain on a spare loopback port. Load a tiny Java @Reflect fixture with -parameters, a Kotlin glue fixture accepting a Java service type through an available test environment seam, reader service metadata and bundled notation. Distinguish seams not yet publicly available from classpath failures.
4. Exercise the real Spring MVC StreamingResponseBody proxy: root/asset prefix, redirects, compressed responses and delayed SSE chunks. Inspect bundled logback.xml and actual JS resource/module naming. Try SseEmitter only if the stream proof fails.
5. Keep the spike independent of production edits. Preserve small reproducible configuration and results in this file; remove only temporary files created by this session.

## Verification and exit criteria

Give each G1–G7 an explicit pass/fail/deferred result with evidence. A missing future host-service builder can leave the public-API portion of G5 deferred to HS24; a class-loading failure cannot be waved through. Record timestamps for received SSE chunks rather than relying on a final response body.

## Handoff

Host implementation HS23 is gated on these answers. Unresolved Java service injection is owned explicitly by HS24. A failed gate narrows/revises its dependent plan; it does not authorize a new embedding architecture.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
