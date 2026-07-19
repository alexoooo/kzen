# Desktop-app distribution — embedded tabbed shell + native installers (DA1–DA6)

> **Status: planned; engine choice gated.** The direction (an embedded-Chromium tabbed window
> inside kzen-shell, packaged with jpackage) is ratified; the concrete engine (JCEF via
> jcefmaven, fallback Electron) is **decision gate D1**, closed by the DA1 spike before any
> DA2+ work starts. Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is
> self-contained: benefit, design decisions, steps with file anchors, verification.
>
> Ratified product decisions (2026-07-18, user):
> 1. **Native tabs in the desktop shell** — one embedded browser view per tab, mapping onto the
>    existing `/<name>/` prefix routing. Plain-browser users keep normal browser tabs.
> 2. **Footprint:** 300–400 MB installed is acceptable; same-engine-on-all-OSes consistency
>    outweighs disk.
> 3. **Open-source only** as primary; commercial (JxBrowser) recorded as de-risking fallback.
>
> **Progress tracker** (update as phases land):
> - [ ] DA1 — engine spike: jcefmaven on JDK 26 against the live shell (closes gate D1)
> - [ ] DA2 — tabbed shell window (DesktopUi → tab strip + per-project browser views)
> - [ ] DA3 — jpackage Windows installer (app-image + MSI/EXE)
> - [ ] DA4 — Linux bundle (deb/rpm, AppImage consideration)
> - [ ] DA5 — polish: single-instance UX, window-state persistence, branding
> - [ ] DA6 — macOS (dmg/pkg + signing) — **deferred, explicitly parked**

## 1. Context & motivation

kzen should feel like a standard desktop app: launch it and a self-contained window with the UI
appears — no dependency on the user having (or fumbling into) a separate browser. Browser-like
**tabs** are the one browser feature worth keeping in that window: the launcher plus one tab per
open project, exactly how a multi-project session is used in a browser today. Plain-browser
access must be retained (the packaged app is also a local web server; remote use, if ever,
stays a browser concern).

What ships today (`docs/RELEASING.md`, kzen-shell): a Windows-only zip (~170 MB) bundling a
full Temurin JDK and two generated `.bat` launchers. `kzen.bat` runs `javaw -jar` on the shell,
which shows a **Swing status window** (`kzen-shell/src/main/kotlin/tech/kzen/shell/ui/DesktopUi.kt`
— its own text admits "this is not the main UI window"), binds Ktor on `127.0.0.1:8080`, spawns
the launcher/projects as child JVMs behind a prefix reverse proxy, and opens the **default
system browser** via `Desktop.getDesktop().browse("http://localhost:8080")`. So the "app" a
user perceives is whatever browser happens to be the default, with kzen as one more tab in it.

There is no existing embedding/installer work anywhere in the kzen repos (verified 2026-07-18:
zero hits for Electron/Tauri/JCEF/CEF/webview/jpackage/jlink/installer across all repos) — this
plan is greenfield, but it is an **evolution of kzen-shell**, not a rewrite: the shell already
owns a desktop window, a tray icon, child-process lifecycle, and the single loopback front door.

## 2. Current state & inherited contracts

Facts any embedding approach must respect (file anchors in kzen-shell unless noted):

- **Loopback-only cleartext HTTP is ratified.** `embeddedServer(Netty, port, host = "127.0.0.1")`
  (`KzenShellMain.kt`); HTTPS/auth/remote serving are explicitly out of scope per
  `2026-07-16_shell-launcher-improvements.md` § Out of scope. The embedded renderer therefore
  loads `http://localhost:8080/...` — not `file://`, not a custom app scheme.
- **`SecurityGate`** (`security/SecurityGate.kt`, duplicated in the launcher): Host allow-list
  `{localhost, 127.0.0.1}` + fetch-metadata gate (`Sec-Fetch-Site` ∈ same-origin/same-site/none;
  null passes). An embedded view that **navigates top-level to localhost** is same-origin for
  everything thereafter — no gate changes needed. A wrapper that framed localhost content from a
  packaged `app://` origin would 403 on the mutating endpoints — ruled out by construction.
- **Prefix routing**: `/<process-name>/<subpath>` proxied to the child registered under that
  name (`proxy/ProxyHandler.kt`); `/main/` = launcher; children derive their base URL from
  `window.location.pathname` and work at any prefix. **A tab is therefore just a URL**:
  `http://localhost:8080/main/` (launcher) or `http://localhost:8080/<project>/`. The tab model
  maps 1:1 onto what already exists.
- **Stable-kernel update model**: the shell is a tiny (~never re-released) kernel; the launcher
  UI and project runtimes update by artifact download (`repo/ArtifactInstaller.kt`). This is
  load-bearing for the update story in § 6.
- **Dist pipeline**: `:kzen-shell:distWindows` (`build.gradle.kts`) + `ProvisionAdoptiumJdk`
  (`buildSrc/src/main/kotlin/dist/` — Adoptium API fetch, SHA-256-verified, cached; OS/arch
  parameters already exist). Linux/mac bundles are already named as future work in
  `docs/RELEASING.md` § Known limitations.
- **Reserved names** `main` and `shell`; **Windows file locks** on a running project's
  `main.jar`; **`-Xmx64m`** shell/launcher heaps (the shell heap will need raising when it
  hosts a browser engine — the Chromium renderer processes are outside the JVM heap, but the
  JNI bridge and image buffers are not free).
- **Second launch fails to bind 8080** — currently a hung "Loading…" window; SH2 (shell plan
  phase 2) already plans a bind-failure pane. DA5 upgrades this to proper single-instance
  behaviour (see coordination note in § 8).

## 3. Requirements

1. **Self-contained tabbed window**: launching the app shows the kzen UI directly; tabs =
   pinned launcher tab + one per open project; per-tab engine isolation (a hung project page
   doesn't freeze the window).
2. **Plain-browser access retained**: the loopback server stays reachable; "Open in browser"
   affordance kept. Remote use stays browser-only and **out of scope** (loopback contract
   ratified; remote = the user's own tunnel, e.g. SSH port-forward).
3. **Windows + Linux** first-class; **macOS deferred** (DA6, parked — signing/notarization cost
   is real and the user base isn't there yet).
4. **Same rendering engine on every OS** (ratified: consistency > footprint) — the UI is a
   large Kotlin/JS React SPA with SSE, blob URLs, and screenshot-heavy traces; per-OS engine
   divergence would triple the QA surface.
5. **Open-source components only** as primaries.
6. **Installed footprint ≤ ~400 MB** (today's zip is ~170 MB; Chromium adds ~150–250 MB).
7. Standard-app ergonomics over time: real installer, Start-menu/desktop entries, app icon,
   clean uninstall. Auto-update is **not** a v1 requirement (§ 6).

## 4. Options survey (2026)

### 4.1 The two tab layers — and why native tabs

- **In-page tabs**: a same-origin tab-frame SPA served by the shell, hosting each project in an
  iframe. Would give tabs to plain-browser users too — but it is a new web-UI surface (a fourth
  client codebase), iframes complicate focus/history/downloads/fullscreen, and every project
  shares one renderer process. **Not chosen** (ratified): plain-browser users already have
  tabs — their browser's.
- **Native tabs** *(chosen)*: the desktop window owns a tab strip; each tab is an independent
  embedded browser view pointed at one `/<name>/` URL. Real per-tab process isolation (Chromium
  gives one renderer per view), zero new web code, zero server changes.

### 4.2 Candidate matrix

| Option | Engine (Win/Linux/mac) | Native tabs | Bundle Δ | JVM integration | Auto-update | Health 2026 | Verdict |
|---|---|---|---|---|---|---|---|
| **JCEF via jcefmaven** + jpackage | Bundled Chromium, identical on all 3 | Yes — one `CefBrowser` per tab | Chromium ~150–250 MB (one runtime total) | **In-process** — no sidecar, shell lifecycle unchanged | None built-in (see § 6) | JetBrains-backed (IntelliJ's embedded browser); jcefmaven active | **Recommended** |
| **Electron** + JVM sidecar | Bundled Chromium ×3 | Yes — `WebContentsView` + `BaseWindow` (BrowserView removed in v30) | ~150–200 MB + JRE (~200–270 total, two runtimes) | Spawn/health-check/kill child JVM from JS main process (proven pattern: s2progger/electron-jvm) | Turnkey (electron-builder/updater) | Excellent | **Fallback** if DA1 fails |
| **Tauri 2** + JVM sidecar | WebView2 / **WebKitGTK** / WKWebView | Multi-webview still behind `unstable` Cargo flag | ~5–10 MB shell + JRE | `externalBin` per target triple; no first-class JRE story; Rust glue | Good (signed updater plugin) | Healthy | Rejected: Linux WebKitGTK liability (blank windows, NVIDIA/WebGL, env-var workarounds) + unstable tabs + engine divergence |
| **JxBrowser** (TeamDev) | Bundled Chromium ×3 | Yes (you build the strip) | Chromium + JRE | In-process, supported | Vendor-agnostic | Commercial | De-risking fallback only (open-source-only ratified) |
| webview_java / webviewko | OS webviews (WebKitGTK on Linux) | No — single view | few MB | In-JVM | None | Thin | Rejected: no tabs, WebKitGTK |
| Neutralino | OS webviews | No | ~2 MB | None (JS-oriented) | Limited | Niche | Rejected: no JVM fit |
| Chrome/Edge `--app=` | User's installed browser | No | ~0 | Launch URL only | n/a | n/a | Rejected as product (depends on user's browser); noted as zero-cost fallback affordance |
| PWA install | User's Chromium/Edge | No (single window) | ~0 | Web manifest only | Web-native | n/a | Possible free **complement** later; not the app |
| Servo (0.1.0, 2026-04) | Rust engine | Not yet (multi-webview landing) | small | No JVM bindings | None | Early | Watch; revisit in years, not now |

Notes pinned during research (2026-07-18):
- **KCEF (Kotlin CEF wrapper) was archived 2025-10-28** — do not depend on it (this also clouds
  `compose-webview-multiplatform`'s desktop backend). Use **jcefmaven directly**
  (https://github.com/jcefmaven/jcefmaven); natives can be **bundled as dependency artifacts**
  (skipping its default first-run download) — that's the D2 decision.
- JetBrains ships JCEF inside the **JetBrains Runtime (`jbr_jcef`)**, which tracks **JDK 21**;
  kzen targets **JDK 26**. jcefmaven's standalone CEF natives are JDK-version-tolerant in
  principle, but **Java 26 compatibility is unproven → the DA1 spike's first question**.
- Electron `WebContentsView` docs: https://www.electronjs.org/docs/latest/api/browser-window;
  Tauri sidecar: https://v2.tauri.app/develop/sidecar/; Tauri Linux graphics issues:
  https://v2.tauri.app/develop/debug/linux-graphics/; jpackage: JEP 392
  (https://openjdk.org/jeps/392); JCEF: https://github.com/JetBrains/jcef.

## 5. Recommendation & architecture sketch

**JCEF (via jcefmaven) embedded in kzen-shell, packaged with jpackage.**

Why it wins for kzen specifically:
- **One runtime, one process tree, no glue.** Everything the shell already does — spawn
  children, proxy, tray, shutdown hook — stays exactly as is; the browser lives in the same JVM
  as the proxy. Electron/Tauri would add a second orchestrator in another language whose whole
  job is to reimplement lifecycle the shell already owns.
- **Same Chromium on Windows/Linux/mac** — requirement 4, which eliminates Tauri.
- **It is the IntelliJ stack** — the one embedded-JVM-Chromium path with a decade of
  production hardening behind it, and this team lives in IntelliJ.
- The shell's Swing window is already there; JCEF's Swing integration (`CefBrowser.getUIComponent()`
  → a `Component` in a container) means DA2 is a content-pane replacement, not a new app.

Sketch:

```
kzen.exe (jpackage app-image, bundled jlink runtime)
 └─ kzen-shell JVM ── Ktor proxy @ 127.0.0.1:8080 ──▶ child JVMs (launcher, projects)
     └─ Swing JFrame (DesktopUi v2)
         ├─ tab strip (Swing)                        ← per-tab close/switch; + button = launcher
         ├─ tab 0 (pinned): CefBrowser → http://localhost:8080/main/
         ├─ tab 1: CefBrowser → http://localhost:8080/<projectA>/
         ├─ tab n: CefBrowser → http://localhost:8080/<projectB>/
         └─ [Open in browser] → Desktop.browse (retained)
 └─ CEF helper processes (Chromium's own, managed by JCEF)
```

- Every view navigates top-level to loopback ⇒ same-origin ⇒ SecurityGate untouched.
- Browser mode unchanged: same server, same URLs; the window is just another client.
- The ~6-connections-per-origin budget documented in kzen-auto `docs/architecture.md` § 3
  applies to the embedded engine the same way (one Chromium network stack across tabs) — the
  existing visibility-gated SSE design already handles multi-tab economy; DA2 verifies it.

## 6. Update story (why no auto-updater in v1)

jpackage deliberately has no update mechanism (JEP 392). For kzen this is mitigated by the
existing **stable-kernel split**: the heavy native artifact (shell + JCEF + runtime) is the part
that ~never changes, while the launcher UI and project runtimes — where actual development
happens — already update via artifact download (and SH4 adds the project-upgrade path). A new
installer is only needed when the shell/engine itself moves. If that cadence ever becomes
painful, bolt on a third-party updater (jreleaser / velopack / install4j-style) as a follow-on —
explicitly out of v1 scope.

## 7. Decision gates

- **D1 — engine ratification (closes after DA1).** Ship JCEF if the spike passes its exit
  criteria; else fall back to **Electron + JVM sidecar** (accepting two runtimes and JS glue;
  the DA2–DA5 phase structure survives, with DA2's window work moving into an Electron main
  process and DA3/DA4 moving to electron-builder).
- **D2 — Chromium natives: bundled vs first-run download.** Bundled = bigger installer,
  offline-correct, one SHA-verified supply chain (matches how the JDK is provisioned today).
  First-run download = smaller installer but deepens the existing "not offline-first"
  limitation and adds a failure mode at first launch. **Recommendation: bundled** (footprint is
  ratified as acceptable). Decide at DA3 with real measured sizes from DA1.
- **D3 — tab-close semantics.** Closing a project's tab: (a) just closes the view (project JVM
  keeps running; reopenable instantly from the launcher tab; stop remains an explicit launcher
  action), or (b) stops the project. **Recommendation: (a)** — matches today's browser-tab
  behaviour (closing a tab never kills the server) and keeps tab UI decoupled from
  `ProjectRegistry` state transitions. Decide during DA2 review.

## 8. Phases

### DA1 — engine spike (gates D1)

**Benefit:** converts the one unproven assumption — jcefmaven natives on **JDK 26**, driving
the real kzen UI — into a measured yes/no before any integration work.

**Design decisions (made):**
- Spike lives in a scratch module/branch in kzen-shell (not merged as-is); jcefmaven latest,
  natives via its Maven artifacts (also measures D2's bundled-size input).
- Drive the **real** app: boot the packaged-style shell, point one `CefBrowser` at
  `http://localhost:8080`, create a project, run a Script with screenshots.

**Steps:**
1. Scratch Swing window + jcefmaven init on temurin-26; record any JVM flags / module opens
   needed (`--add-opens` etc.) — these become jpackage launcher args in DA3.
2. Load the launcher UI; exercise: SecurityGate pass-through (no 403s), SSE (`/logic/events`
   push, not poll-fallback), blob URLs (`/logic/trace-binary` screenshots), clipboard,
   keyboard shortcuts, downloads (`/action/download`), devtools toggle.
3. Two views side by side (proto-tabs): isolation, memory per view, focus handling.
4. Measure: natives size on disk, cold-start time, RSS with 3 views.
5. Write the go/no-go verdict + measurements into this doc (close D1).

**Verification:** the checklist in step 2 all green on Windows = go. Any hard failure
(JNI crash on 26, SSE broken, input broken) → record, attempt one mitigation round (e.g. pin
the shell process alone to a JBR-compatible JDK — children stay on 26 since they're separate
JVMs), then fall back to Electron per D1.

### DA2 — tabbed shell window

**Benefit:** the actual product change — launching kzen shows kzen, with tabs.

**Design decisions (made):**
- `DesktopUi` evolves in place (same window, tray, EXIT_ON_CLOSE semantics): loading pane →
  becomes the window's transient state; ready pane → replaced by tab strip + browser views.
- Tab 0 = launcher (`/main/`), pinned, not closable. New tabs open from project navigation:
  intercept top-level navigations to `/<project>/…` in the launcher view (JCEF life-span/
  request handler) and route them to a new/existing tab — the launcher web UI needs **no
  change** (prefix-agnostic contract holds).
- Tab-close per D3 (recommendation: view-only close).
- "Open in browser" button retained on the tab strip (per-tab: opens that tab's current URL
  via `Desktop.browse`).
- Shell heap raised from `-Xmx64m` to a measured value from DA1 (browser host ≠ 64 MB shell);
  child heaps unchanged.
- Keep a `--no-window` / headless flag preserving today's behaviour (status window + system
  browser) as a fallback and for the selfTest harness.

**Steps:** JCEF init/shutdown in `KzenShellMain`/`KzenShellContext` lifecycle; `DesktopUi` v2
(tab strip component, view container, per-tab `CefBrowser`); navigation-intercept handler;
tray/window close behaviour audit; heap + flag plumbing; AGENTS.md updates.

**Verification:** launch → window shows launcher directly; create + open project → new tab;
run a Script with screenshots in one tab while another tab stays responsive; close/reopen
project tab (per D3); "Open in browser" lands on the same URL signed-in to nothing (no auth to
lose); second window instance not spawned (see DA5); `--no-window` reproduces today's flow.

### DA3 — jpackage Windows installer

**Benefit:** double-click install, Start-menu entry, icon, clean uninstall — replaces
zip + `.bat`.

**Design decisions (made):**
- `jpackage` app-image + MSI (and/or EXE) from a new `:kzen-shell:packageWindows` task; jlink-
  trimmed runtime replaces the full bundled JDK (the `ProvisionAdoptiumJdk` machinery remains
  for the transition; retire `distWindows` only after one release ships both).
- **Children run on the same bundled runtime** (`System.getProperty("java.home")` resolution in
  `MainJarProcess` already does this) — verify the jlinked image carries the modules the
  launcher/project jars need, or fall back to bundling the full JDK inside the app-image
  (footprint permitting).
- Chromium natives per D2 (recommendation: bundled into the app-image).
- Per-OS build reality: jpackage cannot cross-compile — Windows installer builds on Windows
  (WiX required), Linux on Linux. Document in RELEASING.md.

**Steps:** Gradle jpackage wiring (tool-provider API or exec); launcher args from DA1
(`--add-opens` etc.); icon/branding assets; RELEASING.md rewrite; smoke the installed app from
`Program Files` (paths with spaces, per-user work dir — confirm `work/`/`logs/` land in a
writable per-user location, not the install dir).

**Verification:** clean Windows VM: install MSI → Start-menu launch → full end-to-end (create
project, run script) → uninstall leaves user data (per-user dirs) but removes the app.

### DA4 — Linux bundle

**Benefit:** first-class Linux — currently zero Linux distribution exists.

**Design decisions (made):** same jpackage pipeline → deb + rpm (`packageLinux`); evaluate
AppImage as a portable third artifact (community tooling, not jpackage); JCEF Linux natives via
jcefmaven (same Chromium — this is the payoff of the engine choice); tray behaviour differs on
Linux (AppIndicator vs SystemTray) — degrade gracefully to no-tray.

**Steps:** `packageLinux` task; CI-or-manual build recipe on a Linux machine; smoke on one
mainstream distro (Ubuntu LTS) + one non-Debian (Fedora) if feasible.

**Verification:** install deb on Ubuntu → launch from app menu → end-to-end run → uninstall.

### DA5 — polish

**Benefit:** the ergonomics that make it feel like an app rather than a wrapped server.

**Items:**
1. **Single-instance behaviour**: second launch focuses the existing window instead of a
   bind-failure pane (detect 8080 bound by a live shell — e.g. a `GET /shell/…` liveness probe —
   then activate window and exit). ⚠️ Coordinate with **SH2**, which plans a bind-failure pane
   in today's `DesktopUi`: whichever lands second adapts (if DA2+ is in, SH2's pane becomes
   this focus-existing-window path).
2. Window state persistence (bounds, maximized, open tabs restored to their URLs) in the shell
   work dir.
3. Branding: icon set, window title per active tab, taskbar identity.
4. Keyboard: Ctrl+Tab / Ctrl+W / Ctrl+T-style tab navigation (respecting D3 semantics).

**Verification:** relaunch restores layout; double-launch focuses; shortcuts work.

### DA6 — macOS (deferred, parked)

dmg/pkg via the same jpackage pipeline + JCEF mac natives; requires Apple Developer signing +
notarization (cost + infra). **Do not schedule** until there is a mac user; reopen trigger:
one real macOS request. Recorded so the engine choice (JCEF has mac natives) keeps the door open.

## 9. Risks & open questions

| Risk | Exposure | Mitigation |
|---|---|---|
| jcefmaven natives fail on JDK 26 | Blocks the whole recommendation | DA1 spike first; shell-only JDK pin fallback (children unaffected); Electron fallback (D1) |
| jcefmaven maintenance cadence (Chromium security patches lag upstream CEF) | Slow-burn | Track releases; the loopback-only content (own UI, no arbitrary web) shrinks the attack surface materially; JxBrowser exists if it ever stalls |
| Chromium + JRE footprint | ~2× today's zip | Ratified acceptable (≤ ~400 MB); jlink trims the JRE side |
| Per-OS installer builds (no cross-compile) | Release friction | Windows stays the primary local build; Linux via CI runner or a one-off VM recipe (DA4) |
| Swing ↔ CEF focus/IME quirks | UX papercuts | Known-territory (IntelliJ ships this); DA1 checklist covers input explicitly |
| Shell stops being "tiny" (kernel bloat vs stable-kernel philosophy) | Update-model tension | The *jar* stays tiny and rarely-changing; the heavy natives are inert platform payload — same as the bundled JDK today. § 6 keeps UI-update flow through artifact download |

## 10. Out of scope (decided — don't re-litigate)

- **Remote serving / HTTPS / auth** — loopback-only contract stays (shell-launcher plan);
  remote use = plain browser over the user's own tunnel.
- **In-page tab frame** (iframe shell) — rejected in favour of native tabs (§ 4.1).
- **PWA manifest** — possible zero-cost complement for browser users later; not part of DA.
- **Auto-updater tooling** (jreleaser/velopack/…) — revisit only if post-DA4 release cadence
  hurts (§ 6).
- **Commercial engines** (JxBrowser, Ultralight) — fallback notes only.
- **Compose/KCEF UI layer** — KCEF archived; the Swing window is already there. Reconsider only
  if `DesktopUi` v2 outgrows Swing.

## 11. Sizing

| Phase | Size | Risk |
|---|---|---|
| DA1 — spike | S | High-information (that's the point) |
| DA2 — tabbed window | M | Medium (JCEF lifecycle + input edge cases) |
| DA3 — Windows installer | M | Medium (jpackage + jlink + paths/permissions) |
| DA4 — Linux bundle | S-M | Medium (env diversity) |
| DA5 — polish | S | Low |
| DA6 — macOS | M | Deferred |
