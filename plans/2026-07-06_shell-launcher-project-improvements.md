# Shell / Launcher / Project (hosting & distribution trio) improvements — phased plan

> **Status: planned.** Written 2026-07-06 from a design review of the three repos that expose
> kzen-auto to end users: **kzen-shell** (desktop composition root: process manager + single-port
> reverse proxy), **kzen-launcher** (project selector UI: archetype/project registry, first child
> process), and **kzen-project** (the blank product template a spawned project actually runs).
> Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is self-contained: goal, design
> decisions (already made — do not re-litigate), concrete steps with file anchors, and
> verification. Phases are ordered by priority; only phase 5's UI half depends on phase 2's status
> shape.
>
> Companion plans: `2026-07-05_logic-engine-improvements.md`, `2026-07-05_graph-improvements.md`,
> `2026-07-06_script-improvements.md`, `2026-07-06_job-improvements.md`. Zero overlap — those
> cover what runs *inside* a project process; this plan covers how processes are spawned, proxied,
> secured, configured, distributed, and upgraded.
>
> **Progress tracker** (update as phases land):
> - [ ] Phase 1 — proxy rework: async, header-faithful, correct error semantics (kzen-shell)
> - [ ] Phase 2 — child liveness: exit detection, bounded start, status surface (kzen-shell)
> - [ ] Phase 3 — trust-boundary hardening: fetch-metadata gate, TLS, path validation (shell + launcher)
> - [ ] Phase 4 — configuration + distribution pipeline: no hard-coded URLs, Gradle dist zips (all three)
> - [ ] Phase 5 — registry robustness + status in the UI (kzen-launcher, + shell coordination)
> - [ ] Phase 6 — kzen-project template: module registration fix + project upgrade path
> - [ ] Phase 7 — hygiene sweep: dead code, naming, docs (all three)

## Context — what the review found

Total surface is small (~1.6k lines shell, ~3.5k launcher, ~0.1k project) and the **architecture
is right and should be kept**:

- **The name-prefix routing contract** — `/<process-name>/<subpath>` forwarded to whichever child
  registered `<process-name>` — is a genuinely good single-port design. Children already honour it
  from the other side by deriving their base URL from the browser path
  (kzen-auto `ClientContext.kt:54`, launcher `ajaxUtil.kt:14`
  `window.location.pathname.substringBeforeLast("/")`), so any child UI works at any prefix with
  zero configuration. From the browser everything is one origin on one port — which also means the
  shell is the **single ingress** where cross-cutting policy (security, caching, logging) can live.
- **The managed-child lifeline** (`--managed.lifeline=stdin` + `SHUTDOWN` sentinel + EOF +
  `--parent.pid` watchdog, MainJarProcess.kt:78-96, KzenLauncherMain.kt:47-75, mirrored in
  KzenAutoMain) is an OS-agnostic graceful-lifecycle contract that solves the Windows
  hookless-`TerminateProcess` problem properly. Its deliberate per-child duplication (launcher
  depends on neither kzen-lib nor kzen-auto) is the correct coupling trade-off.
- **Process-per-project isolation** delivers the stated failure-containment goal (an OOM kills one
  project), and every child binds `127.0.0.1` (KzenAutoMain.kt:96, KzenLauncherMain config), so
  nothing is reachable except through the shell.
- **The launcher is a clean small app**: shared `CommonRestApi` path constants, file-based YAML
  registries (fits kzen's file-first ethos), a simple three-component React UI, and the
  kotlin-wrappers migration template that kzen-auto later reused.

The weaknesses cluster into six groups — note the asymmetry: the *design* is sound, but the
*implementation* is the oldest code in the ecosystem (Spring-era relics still commented in place)
and has never had the scrutiny the KMP siblings got.

1. **The proxy is the weakest component in the whole platform.** Every proxied request does
   blocking I/O on a Ktor/Netty coroutine handler (`HttpURLConnection` for GET at
   ProxyHandler.kt:147-154; synchronous `HttpClient.send` for POST/PUT at :249) — and POST/PUT
   builds a **fresh `java.net.http.HttpClient` per request** (:248). Header fidelity is poor in
   both directions: requests forward only `Accept` (GET, :149-152) or only `Content-Type`
   (POST/PUT, :34-35, :242-245), so conditional-GET validators (`If-None-Match` /
   `If-Modified-Since`), `Accept-Encoding`, `Range`, and cookies are all silently dropped — **a
   child can never answer 304, so the multi-MB kzen-auto JS bundle re-transfers uncompressed on
   every page load**. Responses collapse multi-valued headers into a `Map<String, String>`
   (:164-172, last value wins — `Set-Cookie` and friends lost). Error semantics are opaque: any
   exception → 400 with the raw message (:199-207, :269-274), so a crashed child reads as "Bad
   Request"; a dead launcher NPEs (`findByAttribute(...)!!`, ProcessRegistry.kt:78-80) into a Ktor
   500. Only GET/PUT/POST are routed at all (KzenShellMain.kt:101-112); DELETE/PATCH/HEAD/OPTIONS
   404 before reaching the handler's own dead 400 branch (ProxyHandler.kt:133-137). And no
   WebSocket/SSE pass-through exists — an inherent limitation that quietly pins the entire
   platform (kzen-auto's poll-based Logic status included) to request/response.
2. **Lifecycle without liveness.** The shell spawns children but never notices them die —
   ProcessRegistry.kt:44 carries the TODO. A project that OOMs (the very failure the process split
   is for) stays in `ProjectRegistry`/`ProcessRegistry`: the UI still lists it as running, its
   proxy requests surface as 400s, and restart requires a manual stop-then-start. Worse,
   `/shell/project/start` blocks its handler until the child answers HTTP 200 — with **no
   timeout** (`ProcessAwaitUtil.waitUntilAvailable`, :25-32 infinite 250ms poll): a child that
   fails to bind wedges that start forever (Guava-cache loader lock, ProjectRegistry.kt:47-49,
   also blocks any retry of the same name). `stop` blocks up to 15s+15s (MainJarProcess.kt:125-144)
   on the event loop. Child stdout goes to `println(">> …")` (:99-114) — lost in packaged mode; a
   crash's stack trace isn't captured anywhere the user (or the UI) can see.
3. **The trust boundary runs through the browser, unguarded.** All state-changing endpoints are
   GETs with no Host/Origin/fetch-metadata checks: shell `start`/`stop` (KzenShellMain.kt:92-99),
   launcher `create`/`delete`/`rename`/`import` (KzenLauncherMain.kt:256-279). Any web page the
   user visits can fire `<img src="http://localhost:8080/…">` — cross-site GETs reach: recursive
   project deletion (`ProjectRepo.delete` → `deleteRecursively()`, ProjectRepo.kt:88-97),
   **spawning an arbitrary jar already on disk** (`/shell/project/start?location=<any path>` —
   the browser supplies the jar path, ClientShellRestApi.kt:27-35 → ProxyHandler.kt:40-47), and
   every proxied kzen-auto command endpoint (file writes, Script execution = code execution). DNS
   rebinding extends the same to remote attackers. Compounding it: both DownloadServices install a
   **JVM-global trust-all `SSLSocketFactory` + hostname verifier**
   (shell DownloadService.kt:23-39, launcher copy :21-37) while downloading *executable jars*;
   `ProjectCreator.unzip` has no zip-slip guard (ProjectCreator.kt:89-110 — the shell's
   `ArtifactRepo.newFile` :86-94 has one, the launcher's copy doesn't); project names are
   unvalidated path segments (`projectHome.resolve(name)`, ProjectCreator.kt:46; rename via
   `resolveSibling`, ProjectRepo.kt:106) — `..\..\x` escapes, and the reserved names `main` /
   `shell` collide with the routing contract; and the UI's Delete button destroys a project's
   documents with **no confirmation** (ProjectItem.kt:75-77).
4. **State is fragmented and its persistence is fragile.** Three stores describe one concept:
   the launcher's `kzen-projects.yaml` (what exists), the shell's in-memory registries (what
   runs), the launcher's `kzen-archetypes.yaml` (what can be created) — stitched together only in
   the browser. Every launcher repo operation re-reads and re-writes the whole YAML file with no
   synchronization (ProjectRepo.kt:170-194, :148-159) — concurrent commands lose updates, and a
   crash mid-`Files.write` corrupts the registry (no temp+atomic-move). The registry *location* is
   CWD-relative (`Paths.get("../kzen-proj")`, LauncherEnvironment.kt:8), so interactive runs and
   shell-managed runs silently see different project sets. Standalone launcher runs hit its own
   `/shell/project` fallback which returns **random dummy data** (RestHandler.kt:20-34). And
   `ArtifactRepo.downloadIfAbsent` (:24-48) creates the target dir before downloading — a failed
   download leaves a half-populated dir that passes the `Files.exists` check forever after.
5. **Release and distribution are hand-cranked.** Absolute developer-machine `file:///` URLs +
   versions are hard-coded in two mains (KzenShellMain.kt:43-46, KzenLauncherMain.kt:167-171);
   the `kzen-launcher-<v>.zip` / `kzen-project-<v>.zip` payloads are hand-assembled (rename fat
   jar to `main.jar`, bundle `dependencies/`, zip) with no Gradle task; a release touches five
   `version =` lines plus two code constants. And **created projects are frozen at their
   archetype's jar forever** — there is no upgrade path that carries a project's `notation/`
   forward onto a newer kzen-project build, which will bite the moment any real user exists.
6. **The kzen-project template's extension point is broken.** KSP generates
   `KzenProjectCommonModule` / `KzenProjectJvmModule` / `KzenProjectJsModule` (ksp args in all
   three build.gradle.kts), but **nothing registers them**: `KzenProjectMain.kt:12-15` just
   delegates to `kzenAutoInit`/`kzenAutoMain`, and the JS `Main.kt:4-8` has registration commented
   out. A downstream user adding an `@Reflect` class to the template — the entire point of the
   template — gets a runtime instantiation failure. (kzen-project/AGENTS.md's claim that the main
   "registers KzenProjectCommonModule + KzenProjectJvmModule" is stale/aspirational.)

Rating in one line: **shell = right design, weakest implementation (C+); launcher = adequate but
aging (B−); project = correctly minimal but with its one job broken (incomplete).** Nothing needs
restructuring; everything needs finishing.

## Covered elsewhere / deliberately out of scope

Covered by companion plans: everything inside a project process (Logic engine, graph, Script,
Job, Report). This plan never touches kzen-auto behaviour except (phase 1 verification) confirming
its static routes emit cache validators.

Deliberately out of scope, with the reasoning recorded so it isn't re-litigated:

- **WebSocket / SSE pass-through.** Would unlock push and remove kzen-auto's polling, but every
  current consumer is poll-based by design and works. Revisit only when a consumer actually needs
  push; the landing site is `ProxyHandler` + a Ktor `webSocket("{...}")` route. Phase 1's move to
  the Ktor client makes this a small follow-on rather than a rewrite.
- **Merging the launcher into the shell.** Tempting (removes one process, the `main` alias, and a
  zip download), but rejected: the shell must stay a tiny, stable kernel that ~never needs
  re-releasing, while the launcher UI evolves with the product and updates by artifact download.
  The split is the update mechanism.
- **Remote / multi-machine serving, HTTPS, auth tokens.** The loopback-only contract stays; phase
  3 hardens *within* that contract (cross-site attacks arriving through the local browser). If
  remote serving ever happens it is a new front door, not a loosening of this one.
- **Native packaging (jpackage / bundled JRE).** Real future item for end-user distribution
  (today's zip requires a modern JVM on PATH), but orthogonal to correctness; note in phase 4's
  as-built for a future plan.
- **Replacing YAML registries with a database.** File-first is the kzen ethos and the scale is
  tens of entries; phase 5 makes the files safe, not different.

## Phase 1 — proxy rework: async, header-faithful, correct error semantics

**Goal:** the proxy stops blocking event-loop threads, passes headers faithfully both ways, and
tells the truth about failures. This is the largest UX/perf lever in the trio: conditional GETs
alone turn every post-first page load from a multi-MB transfer into 304s.

**Design decisions (made):**
- **Use the Ktor HTTP client (CIO engine)**, one shared instance in `KzenShellContext`, closed in
  `close()`. Rationale: coroutine-native (no `Dispatchers.IO` juggling), streams request and
  response bodies as channels, one HTTP idiom across the codebase. Alternative considered and
  rejected: shared `java.net.http.HttpClient` + `sendAsync` — workable but needs jdk8-coroutines
  interop and manual streaming glue. Add `io.ktor:ktor-client-cio` to kzen-shell deps.
- **Redirects pass through** (`followRedirects = false`): children emit relative `Location`s
  (e.g. launcher `respondRedirect(indexFileName)`), which the browser resolves under the prefix
  correctly. The current behaviour (HttpURLConnection silently following) hides redirects and is
  wrong-in-principle even if harmless today.
- **Header policy flips from allowlist to hop-by-hop blocklist**, both directions. Forward all
  request headers except `Host`, `Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade`,
  `Proxy-*`, `Content-Length` (recomputed); forward all response headers except the same set
  (Ktor's `HttpHeaders.isUnsafe` already guards the response side at KzenShellMain.kt:121-128 —
  keep that, but preserve **multi-valued** headers by carrying `List<String>` per name, replacing
  the lossy `Map<String, String>` in `ProxyResult`).
- **All methods route through one generic handler**: replace the four routes at
  KzenShellMain.kt:101-112 with a single `route("{...}") { handle { … } }` covering
  GET/HEAD/POST/PUT/DELETE/PATCH/OPTIONS; `ProxyHandler` builds the upstream call from
  `request.httpMethod` generically (body only for methods that have one).
- **Error semantics:** unknown name → 404 (unchanged); upstream connect-refused/reset → **503**
  with a small JSON body `{"error": "process-unavailable", "name": …}`; other upstream I/O
  failure → **502** with `{"error": "proxy-failure", …}`. No more blanket 400-with-message. The
  `main`-alias resolution failure (launcher dead) must return 503, not NPE — replace
  `findByAttribute(...)!!` with a null check (full fix for the alias itself in phase 7).
- `ProxyResult` becomes either a thin wrapper over the Ktor client response (statement: proxy
  handler responds via `call.respondBytesWriter` copying the response channel) or is deleted in
  favour of direct streaming inside the handler — prefer deletion; the type only exists because of
  the Spring-era split.

**Steps:**
1. Add ktor-client-cio dep; construct shared client in `KzenShellContext`; wire `close()`.
2. Rewrite `ProxyHandler.handle` as a suspend function taking `ApplicationCall`: name resolution
   (keep the URI-decode of the first segment and the 404-on-no-subpath rule,
   ProxyHandler.kt:78-108), generic upstream request build (method, filtered headers, streamed
   body via `call.receiveChannel()` for methods with bodies), streamed response copy (status,
   filtered multi-value headers, `bodyAsChannel()` → `respondBytesWriter`).
3. Collapse KzenShellMain's four proxy routes into the single all-methods route; delete the
   per-route `routeProxy` header-copy glue (:116-137) in favour of the handler doing it.
4. Delete the dead duplicate `headerMap()` (ProxyHandler.kt:211-222), the commented Spring blocks
   in the file, and the now-unused `ProxyResult` if step 2 removed it.
5. Error mapping per the decision; add slf4j warn logs with child name + cause (currently
   exceptions are swallowed into response bodies with no server-side trace).
6. **Cross-repo check (kzen-auto, small):** confirm `staticResources`/the JS-bundle route emit
   `ETag`/`Last-Modified` when served by `KzenAutoMain` production mode; if not, enable Ktor's
   conditional-headers support there (one-line `install(ConditionalHeaders)`) so the forwarded
   validators actually produce 304s. Same check for the launcher's own static route
   (KzenLauncherMain.kt:233).

**Verification:** run shell + launcher + one project; DevTools network tab: second load of
`/main/index.html` and of a project's JS bundle shows 304s and `content-encoding: gzip` (if the
child compresses); screenshot upload (multipart PUT through the proxy) still works; kill a project
process manually → browsing it yields 503 JSON, not 400/500; `curl -X DELETE` to a child path
reaches the child (kzen-auto currently has none — expect its 404, not the shell's). Load test
sanity: 50 concurrent GETs through the proxy while a start is in progress don't starve.

## Phase 2 — child liveness: exit detection, bounded start, status surface

**Goal:** the failure-containment story gets its missing second half — failure *detection*. The
shell notices child exit, reports it, recovers registry state, and never wedges on a bad start.

**Design decisions (made):**
- **`Process.onExit()` callbacks, not polling**: on registration, `ProcessRegistry.start` attaches
  `process.onExit().thenAccept { … }` which (a) unregisters, (b) records a **tombstone**
  `{name, exitCode, exitedAt}` in a bounded map, (c) logs. `ProjectRegistry` subscribes the same
  way (or exposes its own callback) so a dead project leaves the running set automatically —
  restart becomes just "start again".
- **`/shell/project` returns structured status**: `[{name, state: "running"|"exited", port,
  exitCode?}]` — running entries from the registry, exited ones from tombstones (tombstone cleared
  on next successful start of that name). This is a breaking wire change; `ClientShellRestApi` and
  the UI update in the same release (they always ship together — the launcher zip is versioned
  with the shell pin). UI rendering of the new shape lands in phase 5; this phase keeps the UI
  compiling by mapping state=="running" to the old list.
- **Start becomes bounded and off-loop**: `waitUntilAvailable` gains a deadline (default 90s,
  properties-overridable) and a poll that also checks `process.isAlive` — a child that exits
  during boot fails fast with the exit code and the **last ~100 lines of its output** (see next
  decision). On timeout: `kill()` the half-started child, clear registry state, respond 500 with a
  structured message. The API stays synchronous (the UI's modal spinner is fine for a desktop
  app), but the handler runs the whole start on `Dispatchers.IO` so no Netty worker is pinned.
  Replace the Guava loading-cache with a plain `ConcurrentHashMap` + per-name in-flight guard —
  the cache's only job was dedup, and its loader-exception wrapping obscures errors.
- **Child output goes to a file + ring buffer**: the drain thread (MainJarProcess.kt:99-114) tees
  each line to `logs/<name>.log` (truncate on each start, cap ~10MB) and into an in-memory ring
  buffer (last 100 lines) exposed for error reporting. Keep the `>> ` console echo for dev runs.
- **Shell bind failure is a first-class UX path**: if Netty can't bind the port, show the error in
  the `DesktopUi` frame ("already running? port busy?") instead of dying with a console stack
  trace after the Swing window said "Loading...". Detect by attempting the bind before
  `DesktopUi.show()`'s loading pane claims progress, or catch and swap the pane.

**Steps:**
1. `ProcessRegistry`: add onExit wiring + tombstones + `statusSnapshot()`; delete the :44 TODO.
2. `ProjectRegistry`: swap Guava cache → map + in-flight guard; expose
   `list(): List<ProjectStatus>` including tombstones; `stop` on an exited name just clears the
   tombstone.
3. `ProcessAwaitUtil`: deadline + isAlive parameter; return a sealed outcome (Available /
   ExitedEarly(code) / TimedOut) instead of looping forever.
4. `MainJarProcess`: drain→tee+ring; expose `recentOutput(): List<String>`; `kill()` already
   graceful-first — unchanged.
5. `ProxyHandler.start/stop/list` (the `/shell/*` service methods): wire the above; move start
   onto `Dispatchers.IO`; structured error payloads including `recentOutput` on boot failure.
6. `KzenShellMain`/`DesktopUi`: bind-failure pane.
7. Tests: kzen-shell currently has **zero tests** — add JUnit coverage for
   ProcessRegistry/ProjectRegistry state machines using a stub `ProcessBuilder` (spawn
   `cmd /c exit 3` / `java -version`-style trivial processes), including: exit → tombstone → list
   shows exited → restart clears; start-timeout path; concurrent duplicate start.

**Verification:** start a project, `taskkill /F` its JVM → within a beat `/shell/project` reports
exited with code; start it again without a stop; break a project (rename its main.jar) → start
fails within the deadline with the child's output in the response; `logs/<name>.log` exists and
caps.

## Phase 3 — trust-boundary hardening

**Goal:** a malicious web page in the user's browser (or a DNS-rebinding attacker) can no longer
delete projects, spawn jars, or drive automation through the loopback port; TLS-off downloads and
path-traversal foot-guns are closed. The shell gate protects **every child uniformly** because the
shell is the only ingress.

**Design decisions (made):**
- **Fetch-metadata + Host gate at the shell**, as a Ktor plugin/interceptor applied before
  routing: reject (403) any request whose `Host` isn't `localhost[:port]` / `127.0.0.1[:port]`
  (kills DNS rebinding), and any request bearing `Sec-Fetch-Site` other than `same-origin` /
  `same-site` / `none` (kills cross-site GET/POST from pages; every modern browser sends it;
  requests without the header — curl, same-machine tools — pass, which is the accepted residual
  risk on a single-user desktop). Top-level navigations (`Sec-Fetch-Mode: navigate` to GET `/…`)
  stay allowed so external links into the app still work — but mutating shell endpoints and
  proxied non-GETs are never navigations. The same gate is duplicated (small, dependency-free) in
  the launcher for standalone dev runs.
- **No auth token, no CORS machinery** — fetch-metadata is sufficient for the loopback threat
  model and adds zero UX friction. Recorded as the deliberate choice; a token only returns if
  remote serving ever does.
- **`start` stops trusting the browser for executable paths as defense-in-depth** (the gate
  already blocks cross-site): shell requires `location` to (a) resolve to an existing file named
  exactly `main.jar`, (b) live under the projects root it passes to the launcher (see phase 5's
  `--project.home`) *or* under a path the user explicitly imported — since the shell doesn't see
  the launcher registry, enforce (a) plus normalize-and-log, and record (b) as completed by the
  phase 5 registry unification if pursued. Keep it proportionate; the gate is the real fix.
- **Delete `trustBadCertificate()` from both repos** (shell DownloadService.kt:23-39, launcher
  copy). GitHub releases and any sane artifact host have valid chains; a corporate-MITM user can
  add `-Djavax.net.ssl.trustStore` themselves — document in README. The TODO has been carrying
  this since the Spring era.
- **Zip-slip guard in `ProjectCreator.unzip`**: port the shell's `ArtifactRepo.newFile`
  canonical-path check (:86-94) verbatim.
- **Server-side project-name validation** in `RestHandler.createProject`/`renameProject`: single
  path segment (no `/` `\` `..`), not empty, ≤128 chars, not a reserved routing name
  (`main`, `shell`), no Windows-reserved device names (CON, NUL, …). Reject → 400 with message
  (the UI already surfaces ErrorBus messages).
- **UI confirm dialog on Delete** (MUI `Dialog`, "Delete <name>? This permanently removes its
  files."), and Delete gets `color = error` styling to stop looking like Rename's sibling.
  (Remove — registry-only — keeps no dialog.)
- Mutating endpoints **stay GET** — the gate is the protection; migrating the wire to POST across
  client+server is churn with no additional security and is noted as optional hygiene only.

**Steps:**
1. Shell: `securityGate()` interceptor + unit tests (header matrices); apply in `ktorMain`.
2. Launcher: same gate (copied, ~30 lines) in its `ktorMain`.
3. Shell `ProxyHandler.start`: location validation per decision.
4. Both DownloadServices: delete trust-all; delete the `init` call sites
   (KzenShellContext.kt:35-37, KzenLauncherContext.init KzenLauncherMain.kt:147-150); README note.
5. `ProjectCreator`: zip-slip guard; name validation helper in launcher-jvm used by create+rename.
6. UI: confirm dialog in `ProjectItem` (delete flows through a `confirmingDelete` state).
7. Regression: `curl -H "Sec-Fetch-Site: cross-site" http://localhost:8080/shell/project/stop?name=x`
   → 403; `curl -H "Host: evil.test:8080" …` → 403; plain browser use unaffected end-to-end.

**Verification:** e2e smoke behind the gate (create → start → use kzen-auto UI through proxy →
stop → rename → delete-with-dialog); a hand-written `<img src>` CSRF page no longer triggers
stop/delete; `create?name=..%2Fpwn` → 400; archetype download over https still works with real
certificate validation.

## Phase 4 — configuration + distribution pipeline

**Goal:** a release stops requiring editing two source files on the developer's machine, and the
zips build themselves. `git clone` + documented steps must produce a working `kzen-<v>.zip` on any
machine.

**Design decisions (made):**
- **Externalize the shell's launcher-artifact source**: resolution order = CLI args
  (`--launcher.dir=`, `--launcher.zip=`) → `kzen-shell.properties` beside the jar (if present) →
  **built-in default** pointing at the GitHub releases URL templated from a generated version
  constant. The current dev workflow (local `file:///…/build/libs/….zip`) moves into a checked-in
  `kzen-shell.properties.dev` example / IDE run-config args, not source code. Same treatment for
  the launcher's default archetype (KzenLauncherMain.kt:167-171): args/properties override, GitHub
  default.
- **Version constants are generated, not typed**: each of shell/launcher gets a
  `processResources`-expanded `version.properties` (from the Gradle `version`) read at boot; the
  default URLs and the expected unpack dir name derive from it. Release then touches only the five
  `version =` lines the umbrella doc already mandates.
- **Gradle `dist` tasks replace hand-zipping**: in `kzen-launcher-jvm` and `kzen-project-jvm`, a
  `Zip` task (`dist`) depending on `jar` + `copyDependencies` that packages
  `main.jar` (renamed from the module jar) + `dependencies/` into
  `build/dist/<name>-<version>.zip` — exactly the layout `MainJarRunner`/`ProjectCreator` expect
  (the thin-jar `Class-Path: dependencies/…` manifest already matches, kzen-shell
  build.gradle.kts:65-84 pattern). kzen-shell gets `dist` producing `kzen-<version>.zip`
  (shell jar + `dependencies/` + `kzen.bat`/`kzen.sh` + optionally the launcher zip pre-seeded
  under `work/` for offline first-run — include it; first-run-offline is worth the size).
- Not wired into `build` — `dist` is invoked explicitly; document in each AGENTS.md and the
  umbrella release checklist (which currently documents the hand process — rewrite that section).
- **Atomic artifact acquisition**: `ArtifactRepo.downloadIfAbsent` downloads to
  `<path>.download/` staging, extracts there, **verifies `main.jar` exists**, then
  `Files.move(staging, path, ATOMIC_MOVE)` (fallback non-atomic move on cross-store). Presence
  check becomes "dir exists **and** contains main.jar" so historical half-states self-heal. Wrap
  `extractZip`'s streams in `use {}` (currently leaks on exception, ArtifactRepo.kt:53-84).

**Steps:**
1. Shell: properties loading (args > file > defaults), generated version constant, delete the
   hard-coded block at KzenShellMain.kt:41-47; `KzenShellProperties` becomes non-nullable with
   real defaults (dropping the vestigial `port: Int = 80`).
2. Launcher: same for the default archetype; `KzenProperties.Archetype` populated from
   config/defaults rather than inline code.
3. The three `dist` tasks; local end-to-end: `dist` all three → run shell jar from an empty scratch
   dir with `--launcher.zip=file:///<built zip>` → full stack boots.
4. Umbrella AGENTS.md “Versioning”/release-checklist rewrite; sibling AGENTS gotchas about
   hard-coded paths deleted (they become wrong).
5. ArtifactRepo atomicity + verification + stream hygiene.

**Verification:** fresh-machine simulation (rename `work/`, run packaged zip offline with the
seeded launcher) boots to the launcher UI; corrupting a download mid-way (kill during extract)
self-heals on next boot; release dry-run follows only the checklist.

## Phase 5 — registry robustness + status in the UI

**Goal:** the launcher's registries survive concurrency and crashes, live in an explicit location,
and the UI reflects real process state (including deaths detected in phase 2).

**Design decisions (made):**
- **In-memory repos with atomic persistence**: `ProjectRepo`/`ArchetypeRepo` load YAML once at
  construction into a `@Synchronized`-guarded map; every mutation persists via
  write-temp-file + `Files.move(…, ATOMIC_MOVE, REPLACE_EXISTING)`. File format and location
  unchanged (hand-editability preserved). Read endpoints stop doing disk I/O per request.
- **Explicit project home**: launcher accepts `--project.home=<absolute>`; kzen-shell passes
  `<shell work root>/kzen-proj` when spawning it (KzenShellContext.start builds the arg).
  Interactive fallback stays `../kzen-proj` for compatibility with existing dev registries.
  `LauncherEnvironment` object → constructor-injected path (kept as a value in
  `KzenLauncherContext`).
- **The `/shell/project` standalone fallback returns an empty list** (delete
  `runningProjectsDummy`, RestHandler.kt:20-34); the UI, on seeing the shell endpoints 404/fail on
  `start`, shows its normal error banner. The same-path trick (launcher serves the path only when
  not behind the shell) is kept deliberately — document it with a comment; it's the standalone
  detector.
- **UI adopts phase 2's status shape + light polling**: `ProjectRunning` renders state chips
  (running → link + Stop; exited → "exited (code n)" + Restart + Dismiss); `ProjectLauncher` polls
  `/shell/project` every 5s while the tab is visible (`document.visibilityState` guard) so deaths
  and out-of-band changes appear without manual refresh. The three initial fetches at
  ProjectLauncher.kt:98-136 run concurrently (they're independent) instead of sequentially.
- Rename/JVM-args editing of a *running* project remains prevented only by the UI filter (running
  projects are excluded from the Available list, ManageProjectsScreen.kt:112-115) — with polling
  keeping that filter honest, that's acceptable; a server-side guard would need launcher→shell
  coupling that isn't worth it. Recorded as a known limitation.

**Steps:**
1. Repos: load-once + atomic persist + synchronization; migration-free (same file shape).
2. `--project.home` plumbing (launcher config parse + shell spawn arg); AGENTS notes.
3. Delete dummy; standalone empty list.
4. Client: `ClientShellRestApi` parses the structured status; `ProjectRunning`/`ProjectItem`
   UI per decision; polling in `ProjectLauncher` (typed status DTO in kzen-launcher-common).
5. Concurrency test: parallel create/rename/delete via coroutines against a test repo instance —
   no lost updates, file always parseable.

**Verification:** kill a running project's JVM → UI flips it to "exited" within a poll tick;
restart from the chip; hand-edit the YAML while stopped → reflected on relaunch; two rapid
creates both persist.

## Phase 6 — kzen-project template: module registration fix + project upgrade path

**Goal:** the template's extension point actually works, and existing projects can ride platform
upgrades instead of being frozen at their creation-day jar.

**Design decisions (made):**
- **Register the generated modules in both mains**: `KzenProjectMain` calls
  `KzenProjectCommonModule.register()` + `KzenProjectJvmModule.register()` before `kzenAutoInit`
  (`ReflectionRegistry` is additive; kzen-auto's own registrations happen inside
  `KzenAutoContext.create`). JS `Main` registers `KzenProjectCommonModule` + `KzenProjectJsModule`
  before delegating to `tech.kzen.auto.client.main()` — mirror however kzen-auto's `ClientContext`
  sequences its own JS module registration. Prove it with a minimal `@Reflect` sample object in
  `kzen-project-common` (doubles as living documentation of "how to add your own object") and a
  `ServerTest` that instantiates it through the notation path.
- **Upgrade = replace runtime, keep data.** Launcher gains an Upgrade action per project: replaces
  `main.jar` + `dependencies/` in the project home from a selected archetype, **preserving
  everything else** (`notation/`, `work/`, `logs/`, user files). Implementation:
  `ProjectCreator.upgrade(home, archetype)` extracts jar-archetype → overwrite main.jar; for
  zip archetypes, extract to staging and copy only `main.jar` + `dependencies/`. Refuse when the
  project is running (UI already filters; server double-checks nothing holds main.jar — on
  Windows an in-use jar fails the copy anyway, surface that cleanly).
- **Archetype identity splits name from version**: `ArchetypeInfo` gains a `version` field
  (registry YAML additive; older entries parse version out of the trailing `-<semver>` in the
  name where present). `init()`'s install-if-absent keying moves to (name, version), so a platform
  bump adds a new *version* of "Automation and Reporting" rather than a forever-growing list of
  version-suffixed names (KzenLauncherMain.kt:167 currently bakes the version into the name). The
  New Project screen offers the latest version per name; the Upgrade action offers versions newer
  than the project's recorded one — which requires recording `archetype` + `version` in
  `ProjectInfo` at create/upgrade time (additive YAML fields; imports get `unknown`).
- Docs: fix kzen-project README's `KzenProjectApp` → `KzenProjectMain`; rewrite the stale
  AGENTS.md registration claim; document the sample `@Reflect` object as the extension tutorial.

**Steps:** registration calls + sample object + test; `ProjectCreator.upgrade`; archetype/project
version fields + parsing; launcher REST (`…/command/project/upgrade`) + client API + UI (Upgrade
button appears when a newer archetype version exists); docs.

**Verification:** template test instantiates the sample object via notation on JVM; JS bundle
boot logs its module registration; create project at v0.29.1 → publish a v0.29.2 archetype →
Upgrade → project boots on new jar with old notation intact; downgrade prevented (or allowed with
warning — allowed, warn).

## Phase 7 — hygiene sweep: dead code, naming, docs

**Goal:** remove the Spring-era fossils and the small warts that mislead every future reader, and
bring the three AGENTS.md files back to truth. Low risk, do last (earlier phases delete some of
this incidentally — skip what's already gone).

1. **Delete dead files** (verify zero references first): shell `proxy/ProxyApi.kt`,
   `context/WebfluxConfig.kt`, `run/LauncherRunner.kt` (all fully commented), `model/ProjectModel.kt`
   (unused), `process/GradleRunner.kt` + `GradleProcess.kt` and `ProjectRegistry`'s commented
   Gradle-build path + its now-unused companion constants (`buildCommand`, `libsPath`,
   `gradleMainJarPrefix/Suffix`).
2. **Excise commented Spring residue** inside live files (ProxyHandler, ProjectRegistry,
   KzenShellProperties, ProjectCreator header, Pages, etc.) — the `//import org.springframework…`
   blocks actively mislead about what the code does.
3. **Register the launcher under the literal name `main`**: `KzenShellContext.start` registers
   with name `"main"` (keeping the unpack-dir as an attribute), deleting the per-request
   location-recompute + attribute scan in `ProxyHandler.handle` (:90-106) and the `TODO:
   centralize this logic`. The `/shell/project` list already excludes it (separate registry).
4. **Small client cleanups**: `ErrorBus.onSuccess` clearing any error on any success (a failed
   delete's message vanishes when an unrelated poll succeeds) → clear only via explicit dismiss +
   replace-on-new-error; launcher `Tabs.asDynamic().onChange` (ProjectLauncher.kt:245) — re-check
   against current kotlin-wrappers for a typed `onChange`; drop the `delay(1)` spinner hack
   (ProjectList.kt:61) if the phase-2 IO-dispatch start makes it moot.
5. **Docs to truth**: shell/launcher/umbrella AGENTS.md — remove hard-coded-path gotchas
   (phase 4), add the security gate, the status endpoint shape, `dist` tasks, `--project.home`,
   the lifeline contract pointer; kzen-project AGENTS/README fixes if phase 6 didn't land them.
6. **Consistent boot logging**: shell logs resolved config (port, launcher source, work dir) at
   startup — today diagnosing a wrong-launcher-version boot requires reading source.

**Verification:** `./gradlew build` green across the trio from the umbrella; grep confirms no
`springframework` tokens remain; fresh end-to-end run from packaged zip unchanged.

## Sizing

| Phase | Size | Risk | Depends on |
|---|---|---|---|
| 1 — proxy rework | M | Medium (wire behaviour under everything) | — |
| 2 — child liveness | M | Medium (process/thread edge cases, Windows) | — |
| 3 — trust hardening | M | Low-Medium (gate false-positives) | 1 (error semantics) preferred |
| 4 — config + dist | M | Low | — |
| 5 — registry + UI status | M | Low | 2 (status shape) |
| 6 — template + upgrade | M | Low-Medium (upgrade semantics) | 4 (dist zips to test with) preferred |
| 7 — hygiene | S | Low | best last |

## Appendix — contracts and gotchas to preserve

- **`main.jar` rename convention**: `ProjectCreator.create` names the runnable jar `main.jar`
  (ProjectCreator.kt:62); `MainJarRunner`/`ProjectRegistry.locateJar` and phase 4's `dist` layout
  all depend on it. Change nowhere or everywhere.
- **Prefix-agnostic children**: every child UI derives its base from
  `window.location.pathname.substringBeforeLast("/")` (launcher ajaxUtil.kt:14, kzen-auto
  ClientContext.kt:54) and serves relative asset URLs. Any new child UI must do the same; the
  proxy never rewrites bodies.
- **The lifeline contract** (`--managed.lifeline=stdin`, `SHUTDOWN` sentinel, stdin EOF,
  `--parent.pid` watchdog) is implemented three times by design (shell spawner
  MainJarProcess.kt:78-96; launcher KzenLauncherMain.kt:47-75; kzen-auto KzenAutoMain). Changing
  the sentinel or flags means touching all three + kzen-project transitively.
- **`/shell/project` same-path trick**: the launcher serves that path itself
  (KzenLauncherMain.kt:282-285) and is only reachable there when *not* behind the shell — it's the
  standalone detector. Phase 5 keeps the trick (empty list) — don't "fix" it into a 404.
- **Ktor unsafe headers**: response header copy must keep skipping `HttpHeaders.isUnsafe`
  (Content-Length/Transfer-Encoding) — Ktor throws if set manually
  (KzenShellMain.kt:121-128 predates phase 1 but the rule survives it).
- **Launcher heap is pinned small on purpose** (`-Xmx64m`, KzenShellContext.kt:51) — it's a
  registry + static file server. If the launcher ever OOMs, grow deliberately, don't inherit
  project-sized args.
- **Reserved names**: `main` (launcher alias) and `shell` (first-class endpoints) are
  unreachable as project names; phase 3 rejects them at create/rename. FreePortUtil's
  check-then-bind race is accepted (children fail fast; phase 2's bounded start surfaces it).
- **Windows file locks**: a running project's `main.jar` cannot be moved/overwritten — rename,
  delete, and upgrade must only ever apply to stopped projects (UI filter + phase 6 server check).
- **kotlin-wrappers scaffolding**: `kzen-launcher-js/wrap/React.kt` is the migration *template*
  for the ecosystem (see launcher AGENTS.md) — don't refactor it casually; kzen-auto's copy must
  stay in lockstep.
