# Shell / Launcher / Project (hosting & distribution trio) improvements — remaining phases (SH2–SH5)

> **Status: planned.** Successor to `sprint-1/2026-07-06_shell-launcher-project-improvements.md`
> (Sprint 1: SH1 trust-boundary hardening landed; earlier 0.29.x work — proxy rework, bounded
> start, registry state machine, adaptive polling, dist pipeline, zip-slip guard — had already
> pruned the original plan). This document carries SH2–SH5 forward, complete and
> self-contained. Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is
> self-contained: benefit, design decisions (already made — do not re-litigate), concrete steps
> with file anchors, and verification. Phases are ordered by priority and are independent
> unless noted (SH5 last — it's the docs-to-truth sweep over whatever 2–4 changed). Phase IDs
> are stable across the sprint reorganization.
>
> **Progress tracker** (update as phases land):
> - [x] Phase 2 — child exit detection, surfaced to the UI (shell + launcher UI) — **landed 2026-07-21**
> - [ ] Phase 3 — registry durability + explicit project home (launcher, + shell spawn arg)
> - [ ] Phase 4 — kzen-project template: extension point + project upgrade path
> - [ ] Phase 5 — hygiene + conditional-GET 304s (all three, + kzen-auto one-liner)

## Landed context (Sprint 1)

**SH1 ✓ 2026-07-10 — trust-boundary hardening.** `SecurityGate` (fetch-metadata + Host gate)
duplicated in `tech.kzen.shell.security` and `tech.kzen.launcher.server.security`, installed
ahead of routing in both `ktorMain`s; cross-site top-level navigations also rejected for the
known mutating paths (`/shell/project/start|stop`, launcher `/rs/command/*`) — proxied
kzen-auto GET command endpoints remain the accepted residual. `trustBadCertificate()` deleted
from both DownloadServices; `ProxyHandler.start` requires `main.jar` inside the given home;
`ProjectNameValidation` gates create + rename (single segment, ≤128, reserved routing/device
names) with 400 semantics; **first tests added to kzen-shell** (`kotlin("test")` +
ktor-server-test-host) — SH2's state-machine tests build on that scaffolding.

**SSE through the proxy (resolved 2026-07-15, via logic-engine E5).** The `/logic/events`
consumer arrived; the body relay needed **no change** (`ProxyHandler.handle` already streams
via `respondBytesWriter` + `copyTo`, forwards `text/event-stream` and `Cache-Control`,
re-frames chunked, and `SecurityGate` passes a same-origin `EventSource`). What it missed:
**the shared CIO client had no `HttpTimeout`, so CIO's default `requestTimeout = 15000`
truncated every proxied response at 15 s** — a wall-clock cap on the whole call context, and
CIO's SSE/upgrade exemptions all miss because the proxy forwards via a plain `prepareRequest`.
Fixed in `KzenShellContext` (`INFINITE_TIMEOUT_MS` + a finite 60 s **socket** timeout as the
real liveness check), pinned by `ProxyHttpClientTimeoutTest`. This was never SSE-specific: the
same cap silently truncated any proxied download slower than 15 s, invisible in the dev loop
(which reaches kzen-auto directly).

## Out of scope (decided — don't re-litigate)

- **WebSocket pass-through**: no consumer needs it. Still a small follow-on if one ever does
  (`ProxyHandler` + a Ktor `webSocket("{...}")` route, plus dropping `Upgrade` from the
  stripped hop-by-hop set), not a rewrite.
- **Merging the launcher into the shell**: rejected — the shell stays a tiny, stable kernel that
  ~never needs re-releasing while the launcher UI evolves and updates by artifact download. The
  split *is* the update mechanism.
- **Remote / multi-machine serving, HTTPS, auth tokens**: the loopback-only contract stays; SH1
  hardened *within* it. Remote serving would be a new front door, not a loosening of this one.
- **Replacing YAML registries with a database**: file-first is the kzen ethos and the scale is
  tens of entries; phase 3 makes the files safe, not different.

## Phase 2 — child exit detection, surfaced to the UI

> **✅ Landed 2026-07-21** as elaborated in `plans/next/SH2_child-exit-detection.md` (see its
> as-built note). Every design decision below held; the one refinement worth carrying forward is
> that both exit callbacks use `thenAcceptAsync` rather than `thenAccept`, keeping them off the
> JVM's process-reaper thread. Browser-side smoke of the launcher UI is outstanding manual debt.

**Benefit:** a crashed project (the exact failure process-per-project isolation exists to
contain) stays listed as RUNNING forever — its pages return 503 with no explanation and recovery
needs a manual stop-then-start; child stdout goes to `println(">> …")` (MainJarProcess), so in
packaged mode a crash's stack trace is unrecoverable. After this phase: a death flips the UI to
"exited (code n)" within a poll tick, restart is one click, boot failures return the child's last
output lines in the error payload, and `logs/<name>.log` holds the full trace. The 0.29.x
groundwork (bounded start, registry state machine, adaptive polling) makes this phase small —
it is the missing second half of failure containment.

**Design decisions (made):**
- **`Process.onExit()` callbacks, not polling**: on registration, `ProcessRegistry` attaches
  `process.onExit().thenAccept { … }` which unregisters, records a **tombstone**
  `{name, exitCode, exitedAt}` in a bounded map, and logs. `ProjectRegistry` folds the exit event
  into its existing state machine (exited entry with exit code; tombstone cleared on next
  successful start of that name) so restart becomes just "start again". Delete the
  `TODO: automatic un-registration` at ProcessRegistry.kt:44.
- **`exitCode` added to the status wire shape** (`RunningProjectStatus` gains an optional
  `exitCode`; additive change — shell and launcher zips always ship together).
- **Child output goes to a file + ring buffer**: the drain thread (MainJarProcess) tees each line
  to `logs/<name>.log` (truncate on each start, cap ~10MB) and into an in-memory ring buffer
  (last ~100 lines) surfaced in start-failure payloads. Keep the `>> ` console echo for dev runs.
- **Shell bind failure is a first-class UX path**: if Netty can't bind the port (typically a
  second launch of the app), show the error in the `DesktopUi` frame ("already running? port
  busy?") instead of a hung "Loading…" window with a console-only stack trace.
- **State-machine tests** (on SH1's test scaffolding): JUnit coverage of the
  ProcessRegistry/ProjectRegistry state machines using trivial stub processes
  (`cmd /c exit 3`-style), including: exit → tombstone → list shows exited → restart clears;
  start-timeout path; concurrent duplicate start.

**Steps:**
1. `ProcessRegistry`: onExit wiring + tombstones + status exposure.
2. `ProjectRegistry`: fold exit events into the state machine; `exitCode` in `list()`.
3. `MainJarProcess`: drain → tee + ring buffer; expose `recentOutput(): List<String>`.
4. `RunningProjectStatus` + launcher client parsing: additive `exitCode` / exited state.
5. Launcher UI: exited chip with exit code + Restart action in `ProjectRunning` (the chip
   infrastructure from 0.29.x is already there); Dismiss clears the tombstone.
6. `KzenShellMain`/`DesktopUi`: bind-failure pane.
7. Tests per decision.

**Verification:** start a project, `taskkill /F` its JVM → within a poll tick the UI shows
exited with code; Restart works without a stop; break a project (rename its main.jar) → start
fails within the deadline with the child's output in the response; `logs/<name>.log` exists and
caps; launching the shell twice shows the bind-failure pane, not a hung loader.

## Phase 3 — registry durability + explicit project home

**Benefit:** 0.29.x made concurrent registry access routine (parallel start/stop + status
polling), but every launcher repo mutation is an unsynchronized whole-file read-modify-write with
a plain `Files.write` (ProjectRepo / ArchetypeRepo) — two concurrent commands can lose an update,
and a crash mid-write corrupts `kzen-projects.yaml`, i.e. the user's project list. The registry
*location* is CWD-relative (`Paths.get("../kzen-proj")`, LauncherEnvironment.kt), so IDE-run and
shell-run launchers silently see different project sets — a recurring "where did my projects go"
papercut.

**Design decisions (made):**
- **In-memory repos with atomic persistence**: `ProjectRepo`/`ArchetypeRepo` load YAML once at
  construction into a `@Synchronized`-guarded map; every mutation persists via
  write-temp-file + `Files.move(…, ATOMIC_MOVE, REPLACE_EXISTING)` (the pattern the artifact
  side already uses). File format and location unchanged — hand-editability preserved. Read
  endpoints stop doing disk I/O per request.
- **Explicit project home**: launcher accepts `--project.home=<absolute>`; kzen-shell passes
  `<shell work root>/kzen-proj` when spawning it (`KzenShellContext.start` builds the arg).
  Interactive fallback stays `../kzen-proj` for compatibility with existing dev registries.
  `LauncherEnvironment` object → constructor-injected path in `KzenLauncherContext`.

**Steps:**
1. Repos: load-once + atomic persist + synchronization; migration-free (same file shape).
2. `--project.home` plumbing (launcher config parse + shell spawn arg); AGENTS notes.
3. Concurrency test: parallel create/rename/delete via coroutines against a test repo instance —
   no lost updates, file always parseable.

**Verification:** hand-edit the YAML while stopped → reflected on relaunch; two rapid creates
both persist; shell-spawned and IDE-run launchers pointed at the same `--project.home` see the
same projects.

## Phase 4 — kzen-project template: extension point + project upgrade path

**Premise:** kzen-project's 2026-06-21 KSP migration left zero `@Reflect` classes, so KSP emits
no modules and the mains correctly register nothing — empty modules must NOT be re-added on
their own. The extension point is still broken for downstream users, though: adding an
`@Reflect` class to the template (its entire purpose) generates a module that nothing registers
→ runtime instantiation failure with no hint why. The fix is a package deal: a sample
`@Reflect` object (which makes the generated modules non-empty) plus the registration calls
plus a test.

**Benefit (registration):** extending the template with your own logic actually works out of the
box, and the sample object doubles as living "how to add your own object" documentation.
**Benefit (upgrade):** created projects are frozen at their creation-day jar forever; with 0.29.1
shipped and 0.30.0 coming, a real user's projects can't receive any fix without manual file
surgery. Upgrade = replace runtime, keep data.

**Design decisions (made):**
- **Sample + registration + test land together**: a minimal `@Reflect` sample object in
  `kzen-project-common`; `KzenProjectMain` registers `KzenProjectCommonModule` +
  `KzenProjectJvmModule` before `kzenAutoInit` (`ReflectionRegistry` is additive; kzen-auto's own
  registrations happen inside `KzenAutoContext.create`); JS `Main` registers
  `KzenProjectCommonModule` + `KzenProjectJsModule` before delegating to
  `tech.kzen.auto.client.main()` (mirror kzen-auto's own JS module sequencing; the commented-out
  registration block in `Main.kt` shows the old shape). A server test instantiates the sample
  through the notation path.
- **Upgrade = replace runtime, keep data.** Launcher gains an Upgrade action per project:
  replaces `main.jar` + `dependencies/` in the project home from a selected archetype,
  **preserving everything else** (`notation/`, `work/`, `logs/`, user files). Extract archetype
  to staging, copy only `main.jar` + `dependencies/`. Refuse when the project is running (UI
  already filters running projects from the manage list; on Windows an in-use jar fails the copy
  anyway — surface that cleanly). Downgrade allowed, with a warning.
- **Archetype identity splits name from version**: `ArchetypeInfo` gains a `version` field
  (registry YAML additive; 0.29.x already parses the version out of the zip filename for the
  new-project selector display — formalize that into the field). `ProjectInfo` records
  `archetype` + `version` at create/upgrade time (additive YAML fields; imports get `unknown`).
  The New Project screen offers the latest version per name; the Upgrade action offers versions
  newer than the project's recorded one.
- Docs: update kzen-project AGENTS.md/README extension-point sections when this lands (the
  2026-07-10 doc pass already brought them to current no-registration truth).
- Related decision awaiting elsewhere: the extensibility analysis's **D1** (plugin-shipped
  `ModuleReflection` registration in kzen-auto) is the *dynamic* cousin of this static
  extension point — independent code paths, no ordering constraint, but read its decision
  before writing the extension-point docs so the story is told consistently.

**Steps:** registration calls + sample object + test; `ProjectCreator.upgrade`;
archetype/project version fields + parsing; launcher REST (`…/command/project/upgrade`) + client
API + UI (Upgrade button appears when a newer archetype version exists); docs.

**Verification:** template test instantiates the sample object via notation on JVM; JS bundle
boot logs its module registration; create project at 0.29.1 → publish a newer archetype →
Upgrade → project boots on the new jar with old notation intact.

## Phase 5 — hygiene + conditional-GET 304s

**Benefit (304s):** all three servers send `Cache-Control: no-cache` so browsers revalidate on
every load, but none installs Ktor's `ConditionalHeaders`, so every revalidation is answered with
a full 200 — the multi-MB kzen-auto JS bundle re-transfers through the proxy on every page load.
The proxy side (done in 0.29.x) already forwards validators faithfully both ways; a one-line
`install(ConditionalHeaders)` per server turns those revalidations into 304s.
**Benefit (rest):** dead Spring-era files and commented imports actively mislead every future
reader (human and AI); the `main`-alias attribute scan recomputes a path on every proxied request
and carries its own TODO; a failed delete's error message can vanish when an unrelated success
fires; diagnosing a wrong-launcher-version boot requires reading source.

**Items:**
1. **`install(ConditionalHeaders)`** in kzen-auto's `KzenAutoMain` (covers kzen-project
   transitively) and the launcher's `ktorMain`; verify 304s in DevTools through the proxy.
   (TP1 — response compression, trace-payload plan — touches the same `KzenAutoMain` install
   block; land in either order, they compose.)
2. **Delete dead files** (verify zero references first): shell `proxy/ProxyApi.kt`,
   `context/WebfluxConfig.kt`, `run/LauncherRunner.kt`, `model/ProjectModel.kt`,
   `process/GradleRunner.kt`, `process/GradleProcess.kt`, and `ProjectRegistry`'s commented
   Gradle-build remnants if any survive.
3. **Excise commented Spring residue** in live files (launcher ProjectCreator.kt:3, :23).
4. **Register the launcher under the literal name `main`**: `KzenShellContext.start` registers
   with name `"main"` (keeping the unpack-dir as an attribute), deleting the per-request
   location-recompute + attribute scan in `ProxyHandler.handle` and its `TODO: centralize this
   logic`. The `/shell/project` list already excludes it (separate registry).
5. **Small client cleanups**: `ErrorBus.onSuccess` clearing any error on any success → clear only
   via explicit dismiss + replace-on-new-error; launcher `Tabs.asDynamic().onChange`
   (ProjectLauncher.kt:171) — re-check current kotlin-wrappers for a typed `onChange`.
6. **Consistent boot logging**: shell logs resolved config (port, launcher source, work dir) at
   startup, alongside the existing build-info line.
7. **Docs-to-truth sweep**: bring shell/launcher AGENTS.md in line with whatever phases 2–4
   changed (exit surfacing, status shape, `--project.home`, upgrade action).

**Verification:** `./gradlew build` green across the trio from the umbrella; grep confirms no
`springframework` tokens remain; DevTools shows 304s on second load of `/main/…` and a project's
JS bundle through the proxy; fresh end-to-end run from packaged zip unchanged.

## Sizing

| Phase | Size | Risk |
|---|---|---|
| 2 — exit detection | S-M | Medium (process/thread edge cases, Windows) |
| 3 — registry durability | S | Low |
| 4 — template + upgrade | M | Low-Medium (upgrade semantics) |
| 5 — hygiene + 304s | S | Low |

## Contracts the remaining phases depend on

- **Reserved names**: `main` (launcher alias) and `shell` (first-class endpoints) are unreachable
  as project names; SH1 rejects them at create/rename.
- **Windows file locks**: a running project's `main.jar` cannot be moved/overwritten — rename,
  delete, and upgrade must only ever apply to stopped projects (UI filter + phase 4 server check).
- The `main.jar` rename convention, lifeline contract, prefix-agnostic child rule, and
  dist/properties resolution are documented in the sibling AGENTS.md files and
  `../docs/RELEASING.md` — change nowhere or everywhere.
- The kzen-shell proxy client's timeout contract (infinite request, 60 s socket) is load-bearing
  for SSE and slow downloads — pinned by `ProxyHttpClientTimeoutTest`; don't "clean it up".
