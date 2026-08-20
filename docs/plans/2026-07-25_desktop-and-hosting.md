# Desktop app + hosting trio — installers, tabbed shell, hosting hygiene (SH5, DA1–DA6)

> **Status: planned; engine choice gated.** Merges the open tail of
> `sprint-2/2026-07-16_shell-launcher-improvements.md` (SH5) with the whole of
> `sprint-2/2026-07-18_desktop-app-distribution.md` (DA1–DA6, nothing started). They belong
> together: both own the shell/launcher/project trio's user-facing surface, and **DA5 explicitly
> replaces the bind-failure pane SH2 shipped**. Executor: **Opus-class, one phase per session.**
> Each phase is self-contained: benefit, design decisions (already made — do not re-litigate),
> steps with file anchors, verification. Phase IDs are stable across the sprint reorganization.
>
> The direction — an embedded-Chromium tabbed window inside kzen-shell, packaged with jpackage —
> is **ratified**. The concrete engine (JCEF via jcefmaven; fallback Electron) is **decision gate
> D1, closed by the DA1 spike before any DA2+ work starts.**
>
> Ratified product decisions (2026-07-18, user) — do not re-open:
> 1. **Native tabs in the desktop shell** — one embedded browser view per tab, mapping onto the
>    existing `/<name>/` prefix routing. Plain-browser users keep normal browser tabs.
> 2. **Footprint:** 300–400 MB installed is acceptable; same-engine-on-all-OSes consistency
>    outweighs disk.
> 3. **Open-source only** as primary; commercial (JxBrowser) recorded as de-risking fallback only.
>
> **Progress tracker** (update as phases land):
> - [ ] SH5 — hosting hygiene + conditional-GET 304s (all three servers, + kzen-auto one-liner)
> - [ ] DA1 — engine spike: jcefmaven on JDK 26 against the live shell (**closes gate D1**)
> - [ ] DA2 — tabbed shell window (`DesktopUi` → tab strip + per-project browser views)
> - [ ] DA3 — jpackage Windows installer (app-image + MSI/EXE)
> - [ ] DA4 — Linux bundle (deb/rpm, AppImage consideration)
> - [ ] DA5 — polish: single-instance UX, window-state persistence, branding
> - [ ] DA6 — macOS (dmg/pkg + signing) — **deferred, explicitly parked**

## Landed context — what these phases stand on

**SH1 ✓ (Sprint 1) — trust-boundary hardening.** `SecurityGate` (fetch-metadata + Host gate)
duplicated in `tech.kzen.shell.security` and `tech.kzen.launcher.server.security`, installed ahead
of routing in both `ktorMain`s; `trustBadCertificate()` deleted; `ProxyHandler.start` requires
`main.jar` inside the given home; `ProjectNameValidation` gates create + rename. **First tests
added to kzen-shell** — SH2's state-machine tests built on that scaffolding, and DA's will too.

**SH2 ✓ 2026-07-21 — child exit detection.** Children self-reap via stdin-EOF + a `parent.onExit`
watchdog; exits surface in the launcher UI with restart. Both exit callbacks use `thenAcceptAsync`,
and the exited-restart test syncs on the tombstone because the two callbacks race by microseconds.
**It also shipped `DesktopUi.showBindFailure` plus a `FreePortUtil.isTcpPortFree` pre-flight in
`kzenShellInit`, marked at the pane for deletion — DA5 replaces both.**

**SH3 ✓ 2026-07-21 — registry durability + `--project.home`.** Rescoped to `ProjectRepo` only
(`ArchetypeRepo` was already directory-scan + atomic). SH2's `MainJarProcess` seam merged cleanly;
`programArgs` threaded only through the launcher-spawn path.

**SH4 ✓ 2026-07-21 — kzen-project extension point + upgrade path.** `ProjectCreator.upgrade`,
archetype/version tracking, `VersionNumbers`, Upgrade UI. **Three** samples (one per source set,
forced by empty-module suppression); the JS sample **did** need build-file edits (kotlin-wrappers on
kzen-project-js's compile classpath).

**The proxy's timeout contract is load-bearing** (E5/SH): the shared CIO client has an infinite
request timeout + a finite 60 s **socket** timeout as the real liveness check, pinned by
`ProxyHttpClientTimeoutTest`. It exists because CIO's default 15 s `requestTimeout` silently
truncated *every* proxied response slower than 15 s — invisible in the dev loop. **Don't "clean it
up"**, and don't let jpackage/JCEF work perturb it.

**TP1 ✓ 2026-07-16** — `install(Compression)` already occupies `KzenAutoMain.ktorMain`'s install
block. SH5's `ConditionalHeaders` install goes **alongside** it; the old "land in either order" note
is resolved.

## Contracts every phase here must honour

- **Reserved names**: `main` (launcher alias) and `shell` (first-class endpoints) are unreachable as
  project names; SH1 rejects them at create/rename.
- **Windows file locks**: a running project's `main.jar` cannot be moved or overwritten — rename,
  delete and upgrade only ever apply to **stopped** projects.
- **Prefix-agnostic children**: the launcher and every project serve their UI as if mounted at
  `/<process-name>/`. This is what lets DA2 intercept navigations without touching the launcher web
  UI at all.
- **Loopback-only cleartext HTTP is ratified**, so the embedded renderer loads
  `http://localhost:8080/...` — **not** `file://`, not a custom scheme. `SecurityGate`'s Host
  allow-list + fetch-metadata gate must keep passing.
- The `main.jar` rename convention, lifeline contract and dist/properties resolution are documented
  in the sibling `AGENTS.md` files and `../docs/RELEASING.md` — **change nowhere or everywhere.**

---

## Phase SH5 — hosting hygiene + conditional-GET 304s

**Independent of the whole DA arc — run it any time.** Its item 7 (docs-to-truth) is the exception:
see the note at the end.

**Benefit (304s):** all three servers send `Cache-Control: no-cache` so browsers revalidate on every
load, but none installs Ktor's `ConditionalHeaders`, so every revalidation is answered with a full
200 — **the multi-MB kzen-auto JS bundle re-transfers through the proxy on every page load.** The
proxy side (done in 0.29.x) already forwards validators faithfully both ways; a one-line install per
server turns those revalidations into 304s.

**Benefit (rest):** dead Spring-era files and commented imports actively mislead every future reader
(human and AI); the `main`-alias attribute scan recomputes a path on every proxied request and
carries its own TODO; a failed delete's error message can vanish when an unrelated success fires;
diagnosing a wrong-launcher-version boot requires reading source.

**Items:**
1. **`install(ConditionalHeaders)`** in kzen-auto's `KzenAutoMain` (covers kzen-project
   transitively) and the launcher's `ktorMain` — beside the existing `Compression` install. Verify
   304s in DevTools **through the proxy**.
2. **Delete dead files** (verify zero references first): shell `proxy/ProxyApi.kt`,
   `context/WebfluxConfig.kt`, `run/LauncherRunner.kt`, `model/ProjectModel.kt`,
   `process/GradleRunner.kt`, `process/GradleProcess.kt`, and `ProjectRegistry`'s commented
   Gradle-build remnants if any survive.
3. **Excise commented Spring residue** in live files (launcher `ProjectCreator.kt`).
4. **Register the launcher under the literal name `main`**: `KzenShellContext.start` registers with
   name `"main"` (keeping the unpack-dir as an attribute), deleting the per-request
   location-recompute + attribute scan in `ProxyHandler.handle` and its `TODO: centralize this
   logic`. The `/shell/project` list already excludes it (separate registry).
5. **Small client cleanups**: `ErrorBus.onSuccess` clearing any error on any success → clear only via
   explicit dismiss + replace-on-new-error; launcher `Tabs.asDynamic().onChange` in
   `ProjectLauncher.kt` — **re-check current kotlin-wrappers (now 2026.7.1) for a typed `onChange`**
   before assuming the dynamic cast is still needed.
6. **Consistent boot logging**: the shell logs resolved config (port, launcher source, work dir) at
   startup, alongside the existing build-info line.
7. **Docs-to-truth sweep**: bring shell/launcher `AGENTS.md` in line with what SH2–SH4 changed (exit
   surfacing, status shape, `--project.home`, upgrade action). ⚠️ **DA2–DA5 will churn this same
   surface again.** Either do item 7 now and accept a second pass after DA5, or defer item 7 alone
   until DA5 lands and ship items 1–6 immediately. **Recommended: ship 1–6 now** (the 304s win is
   free and the dead files mislead today), and fold item 7 into DA5's verification.

**Verification:** `./gradlew build` green across the trio (each from its own directory — the
umbrella cannot build); grep confirms no `springframework` tokens remain; DevTools shows 304s on a
second load of `/main/…` and of a project's JS bundle **through the proxy**; a fresh end-to-end run
from the packaged zip is unchanged.

**Size:** S. **Risk:** low.

---

## Phase DA1 — engine spike (closes gate D1)

**Benefit:** converts the one unproven assumption — jcefmaven natives on **JDK 26**, driving the
real kzen UI — into a measured yes/no before any integration work.

**Design decisions (made):**
- The spike lives in a **scratch module/branch in kzen-shell, not merged as-is**. jcefmaven latest;
  natives via its Maven artifacts (which also measures D2's bundled-size input).
- Drive the **real** app: boot the packaged-style shell, point one `CefBrowser` at
  `http://localhost:8080`, create a project, run a Script with screenshots.

**Steps:**
1. Scratch Swing window + jcefmaven init on temurin-26; record any JVM flags / module opens needed
   (`--add-opens` etc.) — **these become jpackage launcher args in DA3.**
2. Load the launcher UI; exercise: SecurityGate pass-through (no 403s), SSE (`/logic/events` push,
   not poll-fallback), blob URLs (`/logic/trace-binary` screenshots), clipboard, keyboard shortcuts,
   downloads (`/action/download`), devtools toggle.
3. Two views side by side (proto-tabs): isolation, memory per view, focus handling.
4. Measure: natives size on disk, cold-start time, RSS with 3 views.
5. **Write the go/no-go verdict + measurements into this document (closes D1).**

**Verification:** the step-2 checklist all green on Windows = go. Any hard failure (JNI crash on 26,
SSE broken, input broken) → record it, attempt **one** mitigation round (e.g. pin the shell process
alone to a JBR-compatible JDK — children stay on 26 since they are separate JVMs), then fall back to
Electron per D1.

**Note the current environment pins:** Gradle daemon on Java 25, toolchain/target Java 26, Gradle
9.6.1. Run built jars with an explicit Java 26 (`& "C:/Users/ostro/.jdks/temurin-26.0.1/bin/java"`) —
the PATH `java` is often Java 8 here.

**Size:** S, high-information. **Risk:** high-information by design.

---

## Phase DA2 — tabbed shell window

**Benefit:** the actual product change — launching kzen shows kzen, with tabs.

**Design decisions (made):**
- `DesktopUi` **evolves in place** (same window, tray, `EXIT_ON_CLOSE` semantics): the loading pane
  becomes the window's transient state; the ready pane is replaced by a tab strip + browser views.
- **Tab 0 = launcher (`/main/`), pinned, not closable.** New tabs open from project navigation:
  intercept top-level navigations to `/<project>/…` in the launcher view (JCEF life-span / request
  handler) and route them to a new or existing tab — **the launcher web UI needs no change**, because
  the prefix-agnostic contract holds.
- **Tab-close semantics — gate D3.** (a) closing a project tab just closes the view (the project JVM
  keeps running; reopenable instantly from the launcher tab; stop stays an explicit launcher action),
  or (b) it stops the project. **Recommendation: (a)** — it matches browser-tab behaviour and keeps
  the tab UI decoupled from `ProjectRegistry` state transitions. **Decide during DA2 review.**
- "Open in browser" retained on the tab strip (per-tab: opens that tab's current URL via
  `Desktop.browse`).
- Shell heap raised from `-Xmx64m` to a measured value from DA1 (a browser host is not a 64 MB
  shell); child heaps unchanged.
- Keep a `--no-window` flag preserving today's behaviour (status window + system browser) as a
  fallback and for the `selfTest` harness.

**Steps:** JCEF init/shutdown in the `KzenShellMain`/`KzenShellContext` lifecycle; `DesktopUi` v2
(tab strip component, view container, per-tab `CefBrowser`); navigation-intercept handler;
tray/window-close behaviour audit; heap + flag plumbing; `AGENTS.md` updates.

**Verification:** launch → the window shows the launcher directly; create + open a project → a new
tab; run a Script with screenshots in one tab while another stays responsive; close/reopen a project
tab (per D3); "Open in browser" lands on the same URL; no second window instance (see DA5);
`--no-window` reproduces today's flow. **Also confirm the ~6-connections-per-origin budget**
(kzen-auto `docs/architecture.md` §3) behaves across tabs — one Chromium network stack serves them
all, and the visibility-gated SSE design is what makes that economical.

**Size:** M. **Risk:** medium (JCEF lifecycle + input edge cases).

---

## Phase DA3 — jpackage Windows installer

**Benefit:** double-click install, Start-menu entry, icon, clean uninstall — replaces today's
Windows-only ~170 MB zip + two generated `.bat` launchers.

**Design decisions (made):**
- `jpackage` app-image + MSI (and/or EXE) from a new `:kzen-shell:packageWindows` task; a
  **jlink-trimmed runtime** replaces the full bundled JDK. The `ProvisionAdoptiumJdk` machinery
  remains for the transition; **retire `distWindows` only after one release ships both.**
- **Children run on the same bundled runtime** (`MainJarProcess` already resolves via
  `System.getProperty("java.home")`) — verify the jlinked image carries the modules the
  launcher/project jars need, or fall back to bundling the full JDK inside the app-image (footprint
  permitting).
- Chromium natives per **gate D2** — bundled vs first-run download. Bundled = bigger installer,
  offline-correct, one SHA-verified supply chain (matching how the JDK is provisioned today);
  first-run download = smaller installer but deepens the existing "not offline-first" limitation and
  adds a first-launch failure mode. **Recommendation: bundled** (footprint is ratified as
  acceptable). **Decide here, with real measured sizes from DA1.**
- **jpackage cannot cross-compile** — the Windows installer builds on Windows (WiX required), Linux
  on Linux. Document in `docs/RELEASING.md`.

**Steps:** Gradle jpackage wiring (tool-provider API or exec); launcher args from DA1
(`--add-opens` etc.); icon/branding assets; `RELEASING.md` rewrite; smoke the installed app from
`Program Files` — **paths with spaces, and confirm `work/`/`logs/` land in a writable per-user
location, not the install dir.**

**Verification:** on a clean Windows VM — install the MSI → Start-menu launch → full end-to-end
(create project, run a script) → uninstall leaves user data (per-user dirs) but removes the app.

**Size:** M. **Risk:** medium (jpackage + jlink + paths/permissions).

---

## Phase DA4 — Linux bundle

**Benefit:** first-class Linux — **zero Linux distribution exists today.**

**Design decisions (made):** the same jpackage pipeline → deb + rpm (`packageLinux`); evaluate
AppImage as a portable third artifact (community tooling, not jpackage); JCEF Linux natives via
jcefmaven — **the same Chromium, which is the payoff of the engine choice**; tray behaviour differs
on Linux (AppIndicator vs `SystemTray`), so degrade gracefully to no-tray.

**Steps:** `packageLinux` task; a CI-or-manual build recipe on a Linux machine; smoke on one
mainstream distro (Ubuntu LTS) plus one non-Debian (Fedora) if feasible.

**Verification:** install the deb on Ubuntu → launch from the app menu → end-to-end run → uninstall.

**Size:** S-M. **Risk:** medium (environment diversity).

---

## Phase DA5 — polish

**Benefit:** the ergonomics that make it feel like an app rather than a wrapped server.

**Items:**
1. **Single-instance behaviour** — a second launch **focuses the existing window** instead of showing
   a bind-failure pane: detect 8080 bound by a live shell (e.g. a `GET /shell/…` liveness probe),
   activate the window, exit. ⚠️ **This replaces both of SH2's artefacts** —
   `DesktopUi.showBindFailure` and the `FreePortUtil.isTcpPortFree` pre-flight in `kzenShellInit`,
   which SH2 already marked at the pane for deletion. **Delete them here; don't leave both paths.**
2. **Window state persistence** — bounds, maximized, open tabs restored to their URLs — in the shell
   work dir.
3. **Branding** — icon set, window title per active tab, taskbar identity.
4. **Keyboard** — Ctrl+Tab / Ctrl+W / Ctrl+T-style tab navigation, respecting D3's semantics.
5. **SH5 item 7 (docs-to-truth), if deferred** — bring shell/launcher `AGENTS.md` and
   `docs/RELEASING.md` in line with the final desktop reality in one pass rather than two.

**Verification:** relaunch restores layout; double-launch focuses the existing window; shortcuts
work; `showBindFailure` and the port pre-flight are gone with no dead references.

**Size:** S. **Risk:** low.

---

## Phase DA6 — macOS (deferred, parked)

dmg/pkg via the same jpackage pipeline + JCEF mac natives; requires Apple Developer signing +
notarization (cost + infra). **Do not schedule** until there is a mac user; reopen trigger: one real
macOS request. Recorded so the engine choice (JCEF has mac natives) keeps the door open.

---

## Risks & open questions

| Risk | Exposure | Mitigation |
|---|---|---|
| jcefmaven natives fail on JDK 26 | Blocks the whole recommendation | DA1 spike first; shell-only JDK pin fallback (children unaffected); Electron fallback (D1) |
| jcefmaven maintenance cadence (Chromium security patches lag upstream CEF) | Slow-burn | Track releases; loopback-only content (own UI, no arbitrary web) shrinks the attack surface materially; JxBrowser exists if it stalls |
| Chromium + JRE footprint | ~2× today's zip | Ratified acceptable (≤ ~400 MB); jlink trims the JRE side |
| Per-OS installer builds (no cross-compile) | Release friction | Windows stays the primary local build; Linux via CI runner or a one-off VM recipe (DA4) |
| Swing ↔ CEF focus/IME quirks | UX papercuts | Known territory (IntelliJ ships this); the DA1 checklist covers input explicitly |
| Shell stops being "tiny" (kernel-bloat vs stable-kernel philosophy) | Update-model tension | The *jar* stays tiny and rarely-changing; the heavy natives are inert platform payload, same as today's bundled JDK. UI updates keep flowing through artifact download, and SH4 added the project-upgrade path |

## Update story (why no auto-updater in v1)

jpackage deliberately has no update mechanism (JEP 392). For kzen this is mitigated by the existing
**stable-kernel split**: the heavy native artifact (shell + JCEF + runtime) ~never changes, while the
launcher UI and project runtimes — where development actually happens — already update via artifact
download, and SH4 added the project-upgrade path. A new installer is only needed when the
shell/engine itself moves. If that cadence ever becomes painful, bolt on a third-party updater
(jreleaser / velopack / install4j-style) as a follow-on — **explicitly out of v1 scope.**

## Out of scope (decided — don't re-litigate)

- **Remote serving / HTTPS / auth** — the loopback-only contract stays; remote use = a plain browser
  over the user's own tunnel.
- **In-page tab frame** (iframe shell) — rejected in favour of native tabs.
- **PWA manifest** — a possible zero-cost complement for browser users later; not part of DA.
- **Auto-updater tooling** — revisit only if post-DA4 release cadence hurts.
- **Commercial engines** (JxBrowser, Ultralight) — fallback notes only.
- **Compose/KCEF UI layer** — KCEF is archived; the Swing window is already there. Reconsider only if
  `DesktopUi` v2 outgrows Swing.
- **WebSocket pass-through, merging the launcher into the shell, DB-backed registries** — carried
  forward from the shell/launcher plan's out-of-scope list.

## Sizing

| Phase | Size | Risk | Depends on |
|---|---|---|---|
| SH5 — hygiene + 304s | S | Low | — (item 7 prefers after DA5) |
| DA1 — spike | S | High-information (that's the point) | — |
| DA2 — tabbed window | M | Medium | DA1 (gate D1) |
| DA3 — Windows installer | M | Medium | DA2 |
| DA4 — Linux bundle | S-M | Medium | DA3 |
| DA5 — polish | S | Low | DA2 |

**DA1 gates DA2+.** SH5 is independent of the entire arc and is the cheapest win here.
