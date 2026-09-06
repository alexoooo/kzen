# HS02 — Plain-jar Spring compatibility gates

> Status: complete 2026-09-04 (as-built below; G5's public-API half deferred to HS24 as allowed). Prerequisites: HS01.
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

Executed 2026-09-04 in a throwaway Maven project under `%TEMP%\kzen-hs\spring-spike` (deleted afterwards; everything
needed to reproduce it is below). JDK `temurin-25.0.4.1`, Maven 3.9.9 (from `~/.m2/wrapper`), kzen artifacts
`0.30.0-SNAPSHOT` from Maven Local as published by HS01. No production file was edited.

| Gate | Result | Evidence |
|---|---|---|
| G1 | **pass** | Spring Boot **4.1.1** (latest GA on Maven Central; 4.2.0-M1 is a milestone). Boot 4 states first-class Java 25 support. Plain jars: `spring-boot-starter-parent` **as parent** (see G2), no `spring-boot-maven-plugin`, `maven-dependency-plugin:copy-dependencies` → `target/lib/`, `maven-jar-plugin` manifest `Class-Path: lib/…` + `Main-Class`. `java -jar` on 25.0.4.1 boots Tomcat 11.0.24 + one `KzenAutoContext` + one CIO server in 2.8 s (17 s process, mostly the Kotlin compiler classes on a cold jar set). |
| G2 | **pass, with explicit pins** | `DependencyConvergence` passes only after pinning. A BOM `import` does **not** honour the importer's properties, so `kotlin.version=2.4.0` was silently ignored and the tree came out at Boot's Kotlin 2.3.21; the starter *parent* is required for property overrides. Pins: `kotlin.version=2.4.0`, `kotlin-coroutines.version=1.11.0`, `kotlin-serialization.version=1.11.0` (what kzen-auto's Gradle build actually resolves; its declared 1.9.0 is upgraded by Ktor), `selenium.version=4.46.0` (Boot pins 4.43.0, a downgrade of kzen's pin), plus `dependencyManagement` for conflicts *inside* kzen-auto-jvm's own tree that Gradle resolves highest-wins and Maven does not: `guava 33.6.0-jre` (Selenium 33.5.0, docker-java 33.4.8), `error_prone_annotations 2.49.0`, `commons-io 2.22.0`, `org.jetbrains:annotations 23.0.0`, `kotlinx-io-core-jvm`/`-bytestring-jvm 0.9.0` (Ktor 3.5.1 vs serialization-io's 0.6.0). Accepted BOM-side movement: logback 1.5.37→**1.5.38**, slf4j 2.0.18 (equal), netty 4.2.15→**4.2.17** (inert: Ktor runs on CIO; `ktor-server-netty` stays on the classpath as kzen-auto-jvm's runtime dep), jspecify 1.0.0→1.0.1. Two Jackson generations arrive from Boot (`com.fasterxml… 2.21.5`, `tools.jackson… 3.1.5`); kzen uses neither. 167 runtime jars. `kzen-auto-common-jvm` had to be declared explicitly: kzen-auto-jvm publishes it at **runtime** scope, and the reader SPI's `DataCursor`/`ReaderConfig` types live there. |
| G3 | **pass** | `context.notationMedia.scan()` from the host-created context: 33 documents, including kzen's own `auto-jvm/job/job-jvm.yaml` and the spike jar's `auto-jvm/spike/spike-jvm.yaml`; the latter read back through the proxy byte-for-byte. |
| G4 | **defect confirmed** | Spring Boot's `LogbackLoggingSystem` picked up **kzen-auto-jvm.jar!/logback.xml** (the host's log lines carry kzen's pattern) and created `logs/run.log` under the host's CWD. A library consumer inherits kzen's file appender unless it ships its own `logback.xml`/`logback-spring.xml`. The JS bundle resource is `static/kzen-auto-js.js` (+ `.map`, `.LEGAL.txt`) inside kzen-auto-jvm.jar, served for `jsModuleName = "kzen-auto-js"`. The `kzen-build` meta is empty unless the host passes `BuildInfo.load("/kzen-auto-build.properties")` into `KzenAutoConfig`. `WorkUtils.sibling` put `../work/code-cache` beside the host's CWD. |
| G5 | **classpath half pass; public-API half deferred to HS24** | `ReflectiveClassMirror(appLoader)` resolved a **Java** `@Reflect` class compiled with `-parameters` (`args=[label, repository]`, `services={repository=spike.SpikeRepository}`, `create(...)` returned a working instance; log line `Serving spike.SpikeJavaWorker by JVM reflection`) and a **Kotlin** glue class declaring `@Service repository: SpikeRepository` (a Java interface) identically. Injecting that service into a *context* needs `KzenAutoHost` (HS10), which does not exist yet: `GraphEnvironment` is built inside `KzenAutoContext`. Deferred as allowed; not a classpath failure. |
| G6 | **pass** | `META-INF/services/tech.kzen.auto.plugin.api.data.ReaderCapability` in the host jar; `context.readerCapabilityRegistry.resolve(identity)` returned `spike.SpikeReaderCapability` loaded by the app class loader (the context was created on Spring's main thread, TCCL = app loader). |
| G7 | **fail for `StreamingResponseBody`; pass with synchronous servlet streaming and `ResponseBodyEmitter`** | Measured with `curl -N` and per-line arrival stamps. A Tomcat-only probe writing three flushed lines 2 s apart through `StreamingResponseBody` delivered **all three at 6.2 s** (only on completion); the same through a **synchronous** `HttpServletResponse` write + `flushBuffer()` arrived at 361 / 2299 / 4319 ms, and through `ResponseBodyEmitter` (what `SseEmitter` is built on) at 155 / 2132 / 4138 ms. Proxied kzen SSE (`/logic/events`) through the async variant: **0 bytes in 18 s** while the server-side copy loop had written 60 and 23 bytes (thread dump: parked in `HttpResponseInputStream.read`, headers never committed to the wire). Through the synchronous variant: first `data:` at **470 ms**, `event: ping` at **15486 ms** (kzen's 15 s heartbeat). Non-stream paths work through either variant: `/` → relayed `302 location: index.html` (not followed), `/index.html` 200, `static/kzen-auto-js.js` with `Accept-Encoding: gzip` → `content-encoding: gzip` relayed, body a valid gzip of 812 842 bytes → 3 030 380 decompressed, `/scan` JSON gzip relayed, `PUT /notation-batch` form body forwarded (`{}` answer), unknown path → 404 passthrough. Client disconnect mid-stream: the copy loop's next write (the 15 s ping) is absorbed by the socket buffer, the one after that fails and ends the loop; upstream closed within two heartbeats, no further writes 44 s later. |

**Shutdown ordering observed** (`SmartLifecycle.stop` → `server.stop(1000, 5000)` → `context.close()`): workspace closed in
1.03–1.09 s, then Boot's graceful Tomcat shutdown; process exit ≈ 2 s after the trigger. Nothing process-global was touched.

**Reproducible configuration**, the header rules and streaming shape HS23 must use:

```java
// Hop-by-hop + host/content-length/expect dropped both ways; JDK HttpClient HTTP_1_1, Redirect.NEVER,
// BodyHandlers.ofInputStream(); status + remaining headers relayed; body copied in 8 KiB chunks with
// out.flush() AND response.flushBuffer() per chunk, on the request thread (a void handler taking
// HttpServletResponse). Do NOT return StreamingResponseBody for /kzen/**: it buffers until completion.
@RequestMapping("/kzen/{workspace}/**")
public void proxy(@PathVariable String workspace, HttpServletRequest request, HttpServletResponse response) { … }
```

`application.properties`: `server.address=127.0.0.1`, `spring.mvc.async.request-timeout=-1` (only relevant to the async
variant; harmless). The host created the workspace's module root as `<home>/<ws>/src/main/resources/notation/main`, which
is what `GradleLocator(moduleRootOverride)` expects. Workspace = `KzenAutoContext.create(KzenAutoConfig(jsModuleName =
"kzen-auto-js", port, host = "127.0.0.1", moduleRoot))` + `embeddedServer(CIO, port, host) { ktorMain(context) }.start(false)`.

**Findings carried forward:** HS23 uses the synchronous servlet proxy; `SseEmitter` is not needed. HS10 must make the `logs`
managed area suppressible and HS23 must ship its own logback config (or the host inherits kzen's file appender). HS24 owns the
deferred half of G5. Consumers must declare `kzen-auto-common-jvm` themselves until those SPI types move or the POM scope
changes (surfaced, not changed). Temporary files removed: `%TEMP%\kzen-hs\spring-spike`, `spike-run`.
