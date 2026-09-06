# HS23 — Spring host workspaces, lifecycle and streaming proxy

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS02 host gates, HS10, HS18 and HS22.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.3 and §9 G1–G7.

## Outcome and anchors

New sibling kzen-sample-embed-spring; umbrella settings.gradle.kts; sample host build/config/lifecycle/proxy.

## Work

1. Scaffold the Java 25 plain-jar Maven host using HS02's verified dependency/packaging choices. Add it as an umbrella include like the Maven sample; create an AGENTS.md with reproducible build/run/verification commands.
2. Initialize one KzenAutoRuntime, then configured workspaces with distinct module/work roots and per-context CIO loopback servers. Wire startup rollback across already created workspaces if a later one fails.
3. Implement the Spring MVC proxy at /kzen/{workspace}/** and a small workspace/portlet page. Preserve request bodies, query/path semantics, status, redirects, compression and streaming using the established header rules.
4. Use SmartLifecycle to stop/await each server, close/join its context, then release its claim. Do not close the process-global extension universe or install kzen's process-exit/headless behavior.
5. Let Spring own logging/backend configuration; suppress misleading managed log storage. Resolve any HS02 resource/logging defects necessary for the library use, with standalone logging behavior verified.

## Verification and exit criteria

From the packaged plain jars on JDK 25, open two prefixed UIs, request assets, run a fixture Job, stream SSE incrementally, cancel a request and verify proxy resources close. Test failure during second-workspace construction and server binding; every previously acquired context/root must be released safely. Stop one workspace while the other remains usable.

## Handoff

Record exact packaging, host config, ports, paths and shutdown proof. No real memory-governed host services are claimed until HS24.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 as the new sibling `../kzen-sample-embed-spring` (a Maven Spring Boot project, Java 25, plain
jars), an `includeBuild` in the umbrella's `settings.gradle.kts` beside the Maven sample, its own `AGENTS.md` and
`README.md`, and one line in the umbrella `AGENTS.md`. No kzen source changed for it; nothing installs kzen's
process-exit or headless behaviour; the process-global extension universe is never closed.

**Packaging and build (Work 1).** HS02's verified choices, verbatim: `spring-boot-starter-parent` **4.1.1 as the
parent** (a BOM import ignores the overrides) with `kotlin.version=2.4.0`, `kotlin-coroutines.version=1.11.0`,
`kotlin-serialization.version=1.11.0`, `selenium.version=4.46.0`, `junit-jupiter.version=6.1.1` (Boot's 6.0.3 is
not in the offline repository) and `dependencyManagement` pins for the conflicts inside kzen-auto-jvm's tree
(guava 33.6.0-jre, error_prone 2.49.0, commons-io 2.22.0, annotations 23.0.0, kotlinx-io 0.9.0);
`spring-boot-starter-webmvc`, `kzen-auto-jvm` + `kzen-auto-common-jvm` (declared explicitly: runtime scope in the
published POM), `ktor-server-cio-jvm` 3.5.1, and the sample's `kzen-sample-adapter` + `kzen-sample-core` as
ordinary dependencies — plugin zero, the embedded way in. No `spring-boot-maven-plugin`: `copy-dependencies` →
`target/lib/` (169 jars) and a `Class-Path` + `Main-Class` manifest; `-parameters`. Build: `mvn -o -B verify`
after kzen-lib / kzen-auto `publishToMavenLocal` and the sample's `mvn -o -B install`.

**Workspaces and lifecycle (Work 2, 4).** `kzen.home`, `kzen.plugin-root`, `kzen.workspaces[]{name, port,
work-root}` (`KzenHostProperties`, records, validated). `KzenWorkspaces` is a `SmartLifecycle` (phase 0: before
Boot's web server on the way up, after it on the way down): `KzenAutoRuntime.initialize` once with the configured
plugin root, then each `KzenWorkspace` in order — `KzenAutoContext.create(KzenAutoConfig(jsModuleName =
"kzen-auto-js", port, "127.0.0.1", moduleRoot = <home>/<name>, workRoot = <home>/<name>/work, hostServices,
manageLogs = false))` followed by `embeddedServer(CIO, port, host) { ktorMain(context) }.start(false)` (from Java
through Ktor's suspend-module overload). A later workspace's failure stops the started ones in reverse (server
then context) and logs `Rolled back workspace '<name>'` before the failure propagates; a server bind failure
closes the context it was for. `stop()` is `server.stop(1 s, 5 s)` then `context.close()` (cancel and join the
run, release the claim), reporting `work root released` or `stays claimed`; `stopWorkspace(name)` does the same
for one. The runtime is never closed. Logging is the host's (`logback.xml`, console; Boot would otherwise pick
`kzen-auto-jvm.jar!/logback.xml` — HS02 G4) and kzen's managed `logs/` area is off.

**Proxy and page (Work 3).** `KzenProxyController`: `@RequestMapping("/kzen/{workspace}/**")` as a **void
handler writing `HttpServletResponse`** — JDK `HttpClient` (HTTP/1.1, `Redirect.NEVER`,
`BodyHandlers.ofInputStream`), method / path / query preserved, the request body forwarded as a stream, status
and headers relayed under kzen-shell's rules (`ProxyHeaders`: hop-by-hop + `Host` / `Content-Length` / `Expect`
dropped both ways, `Proxy-*` dropped, `Content-Encoding` and `Location` relayed as is), the body copied in 8 KiB
chunks with `out.flush()` and `response.flushBuffer()` per chunk; a client that leaves ends the loop at the next
write and closes the upstream; live copies and disconnects are counted (`/kzen-host/stats`). `HostController`:
`/` is the portlet page (a link per workspace), `/kzen-host/workspaces`, `DELETE /kzen-host/workspaces/{name}`,
`POST /kzen-host/shutdown` (a Windows child gets no SIGTERM: `SpringApplication.exit` off the request thread).
**A defect HS02 had not noticed:** Boot's `FormContentFilter` consumed a `PUT` form body into request parameters
before the proxy read the stream, so kzen's `PUT /notation-batch` answered `{}` through the proxy (HS02 recorded
that `{}` as a pass) and the UI showed "Missing document"; `spring.mvc.formcontent.filter.enabled=false` — a
proxy relays bytes — and the body arrives. Synchronous relay confirmed: the first SSE line of `/logic/events`
arrives at once; `StreamingResponseBody` is not used anywhere (Work 5's logging point is the `logback.xml` above).

**Verification.** `HostPackagedIT` (`integration-test` phase, the packaged jar in child JVMs on free ports, a
fixture Job `(1..3) → Preview` written into the trading workspace's notation): 5 tests, 0 failures in 19.6 s — portlet page and both prefixed UIs (302 → `index.html` relayed, `index.html` 200, the bundle relayed gzip and inflating past 500 KB, an upstream 404 relayed, an unknown workspace 503); the `PUT /notation-batch` body relayed; the fixture run started through the proxy, the first SSE line within the 5 s bound (in practice at once), the upstream stream closed after the client left (`activeStreams` 0, `clientDisconnects` ≥ 1); `risk` stopped while `trading` served and its port freed; two failing boots in their own JVMs — a shared work root (`Rolled back workspace 'trading'`, `work root released`, the failure naming the root) and a shared port (`server did not start on 127.0.0.1:<port>`, rollback, the port free) — each exiting non-zero; graceful exit through `/kzen-host/shutdown` with exit code 0 and `Workspace 'trading' stopped; work root released`. Manually, the packaged
jar on 18280 with workspaces on 18281 / 18282 (temp home under `%TEMP%\kzen-hs\hs23-home`, never the user's
servers): `Plugin universe pinned … folder scopes=0`, `2 workspace(s) started`, `Tomcat started on port 18280`;
`/` listed both; `/kzen/trading/` → `302 location: index.html` relayed unfollowed; `index.html` 200 for both;
the JS bundle with `Accept-Encoding: gzip` → `content-encoding: gzip`, 823 218 bytes on the wire; `/scan` listed
`main/Fixture.yaml`; an upstream 404 relayed; an unknown workspace 503; `GET /logic/startRun?path=…&object=main`
→ 200 with the run id, status `Running` then `active: null`; `curl -N /logic/events` printed
`data: {"epoch":"0",…}` immediately and after the client left `activeStreams` went 1 → 0 with
`clientDisconnects` 1 (the upstream closed at kzen's next heartbeat); `DELETE /kzen-host/workspaces/risk` → 200,
`Workspace 'risk' stopped; work root released`, `/kzen/risk/` 503 while `/kzen/trading/` 200 and port 18282
free; in the browser through the proxy the `kzen/trading` UI loaded the document, ran it (`emitted=3`, preview
3 rows, live status through the relayed SSE); `POST /kzen-host/shutdown` → Tomcat's graceful shutdown, then
`Workspace 'trading' stopped; work root released`, `'risk'` likewise, every port free. New files staged by
explicit path in the new sibling's repository (`git init`); the umbrella's `settings.gradle.kts` and `AGENTS.md`
edited.

**Handoff.** Packaging: `target/kzen-sample-embed-spring-0.0.1-SNAPSHOT.jar` + `target/lib/`; run `java -jar` from
any cwd with `--kzen.home=` (default `kzen-home/`), `--server.port=` (18280), workspace ports 18281 / 18282 in
`application.yaml` (override the whole list on the command line: an indexed override of one field drops the
yaml's other fields). No host services are registered yet (`KzenAutoHost.empty`); HS24 adds the governed
`SymbolDayLoader`. HS10's still-unwritten "run blocking in a callback while `close()`" ordering test stays
open — this session exercised cancel → join → release only through completed runs. The IT stops the host
through `/kzen-host/shutdown` rather than a signal (Windows).
