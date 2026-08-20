# DA1 — JCEF engine spike (closes gate D1) — implementation plan

> **Status:** generated 2026-07-19; the live constituent plan is now
> `../2026-07-25_desktop-and-hosting.md` (ledger row 15). Ratified decisions PRE-MADE (do not
> re-litigate): JCEF via **jcefmaven** as primary engine, **NOT KCEF** (archived 2025-10-28);
> **Electron** fallback per gate D1; **native tabs**; the spike drives the **real** app. Shell
> anchors verified against kzen-shell @ master (0.30.0-SNAPSHOT, working tree clean). jcefmaven
> facts pinned **2026-07-19** from Maven Central metadata + GitHub releases (URLs in
> § Pre-resolved questions).
>
> **Re-validated 2026-07-25 — this plan aged well.** It is kzen-shell-only, so none of the Job /
> client / `RestHandler` churn touches it. Two small things:
> - **SH2, SH3 and SH4 have since landed** (2026-07-21). The "SH2 untouched" reasoning below still
>   holds — the spike is a separate subproject and a separate process — but `DesktopUi` now also
>   carries `showBindFailure`, and `kzenShellInit` a `FreePortUtil.isTcpPortFree` pre-flight. Both
>   are marked for deletion by **DA5**, not by this spike. Expect the pre-flight to complain if you
>   boot a second shell on 8080 during measurement.
> - **Re-check the pinned jcefmaven version before starting** (`146.0.10`, pinned 2026-07-19) — a
>   newer release may exist, and the natives-artifact size is a D2 decision input, so measure what
>   you actually use.
> Executor: one S session, high information. Spike lives on a branch in kzen-shell; **nothing
> merges to master**; the deliverable is the closed D1 gate (verdict + measurements written
> into the DA plan) plus the retained spike branch.

## Scope & goal

Convert the one unproven assumption of the desktop-app plan — **jcefmaven Chromium natives
hosted by a JDK 26 JVM, driving the real kzen UI** — into a measured go/no-go:

1. Stand up a minimal Swing window with one windowed `CefBrowser` on temurin-26.0.1, natives
   supplied as Maven dependency artifacts (no first-run download) — this also produces gate
   D2's bundled-size input.
2. Point it at a separately-booted, packaged-style kzen-shell and exercise the full DA1
   step-2 checklist: devtools, SecurityGate pass-through, SSE push, trace-binary blob URLs,
   clipboard, keyboard shortcuts, downloads, focus.
3. Proto-tabs: two `CefBrowser` views side by side — isolation, per-view memory, focus.
4. Measure: natives size (jar + extracted), cold-start time, RSS with 3 views, spike-JVM
   heap/native memory (feeds DA2's shell-heap decision — shell is `-Xmx64m` today).
5. Record the verdict + measurements into `../2026-07-25_desktop-and-hosting.md`, closing
   gate D1 (go = JCEF; hard failure → one mitigation round → else Electron fallback).

## Dependencies & coordination

- **Gates DA2+**: no DA2–DA5 work starts until this spike closes D1 (master-plan rule 7).
  Otherwise DA is independent of every other track.
- **SH2 untouched**: the spike does **not** modify `DesktopUi` (or any shell source) — it is a
  separate Gradle subproject and a separate OS process. **SH2 landed 2026-07-21**, so the
  bind-failure pane now exists; DA5 deletes it along with the port pre-flight. Nothing for this
  spike to do about either.
- **Feeds DA3**: any JVM flags the spike needs (`--enable-native-access`, `--add-opens`, CEF
  switches) become jpackage launcher args — record them verbatim in the verdict.
- **Feeds D2**: the natives-artifact jar size + extracted `jcef-bundle` size are the
  bundled-vs-download decision inputs — record both.
- **Feeds DA2**: observed spike-JVM heap/native memory → the shell `-Xmx` raise; the
  hidden-view `visibilitychange` probe (Phase 5, optional) → DA2's SSE-economy check.

## Current-state findings (verified 2026-07-19)

**Shell layout** (`C:\Users\ostro\IdeaProjects\kzen-shell`):

- **Single-module Gradle project**: `settings.gradle.kts` is one line
  (`rootProject.name = "kzen-shell"`) — adding a subproject is a 1-line `include()` plus a
  directory; the root build applies `kotlin("jvm") version kotlinVersion` (2.4.0), toolchain
  **26** (`buildSrc/src/main/kotlin/Dependencies.kt`: `jvmToolchainVersion = 26`,
  `jvmTargetVersion = "26"`, Ktor 3.5.1).
- **Jar naming**: `archiveFileName = "kzen-$version.jar"` → the built shell jar is
  `build/libs/kzen-0.30.0-SNAPSHOT.jar` (note: `AGENTS.md`'s run example says
  `kzen-shell-0.30.0-SNAPSHOT.jar` — **stale**, follow the build file). Manifest `Class-Path`
  points at the sibling `dependencies/` dir populated by `copyDependencies` — one reason the
  spike must NOT add jcefmaven to the root project's dependencies (it would leak ~100 MB into
  every dist zip and the manifest).
- **Dist pipeline**: `distJars` / `distWindows` (neither wired into `build`);
  `generateWindowsLaunchers` bakes `-XX:+UseShenandoahGC -Xmx64m` into `kzen.bat` /
  `kzen-cmd.bat`; `generateReleaseConfig` writes a `kzen-shell.properties` pointing at the
  GitHub release URL derived from `version` with `-SNAPSHOT` stripped → **a dev-built
  distWindows zip would try to download an unreleased `v0.30.0` launcher and fail** — this
  decides the "packaged-style boot" question below.
- **Dev config** (repo root `kzen-shell.properties`, read from CWD): `launcher.zip=
  ../kzen-launcher/kzen-launcher-jvm/build/dist/kzen-launcher-0.30.0-SNAPSHOT.zip`,
  `launcher.dir=../work/kzen-launcher/...` — `file://` sources re-extract on every boot.
- **DesktopUi** (`ui/DesktopUi.kt`): Nimbus Swing status window + tray, `EXIT_ON_CLOSE`,
  opens the **system browser** via `Desktop.browse` in `onLoaded()` — expect a stray browser
  tab to open when the shell boots during the spike; close/ignore it (it doubles as the
  real-browser baseline).
- **SecurityGate** (`security/SecurityGate.kt`): Host allow-list `{localhost, 127.0.0.1}` +
  `Sec-Fetch-Site ∈ {same-origin, same-site, none}` (absent passes); protected paths
  `/shell/project/start|stop` additionally reject cross-site *navigations*. A CEF view
  navigated top-level to `http://localhost:8080` is same-origin for everything after — the
  checklist verifies this empirically (CEF 146 sends the same fetch-metadata headers Chrome
  does). Denials log as `Denied GET <path> - <reason>` in the shell log — that's the
  observable.
- **SSE relay**: `KzenShellContext.httpClient` (CIO) has `requestTimeoutMillis = INFINITE`,
  `socketTimeoutMillis = 60_000` — the `/logic/events` relay fix, pinned by
  `ProxyHttpClientTimeoutTest`. Nothing to change; the spike just proves CEF's `EventSource`
  rides it.
- ⚠️ **`MainJarProcess.startProcess` resolves the child `java` from
  `System.getProperty("java.home")`** — children inherit the **shell's** JVM. The DA plan's
  mitigation sentence ("pin the shell process alone to a JBR-compatible JDK — children stay
  on 26 since they're separate JVMs") is **not true as the code stands**: a shell pinned to
  JDK 21 would spawn children on 21, and the launcher/project jars are class-file v70
  (Java 26) → `UnsupportedClassVersionError`. The spike itself is immune (spike JVM ≠ shell
  JVM), but if the mitigation round ever becomes the shipping shape, the shell needs a small
  child-java-home override first — see § Verification.
- **`.gitignore`** (`work/ .idea/ .gradle/ build/ logs/ .directory`) does not cover a CEF
  install dir → the spike module carries its own `.gitignore` for `jcef-bundle/`.
- **JDKs on this machine** (`~\.jdks`): `temurin-26.0.1` (spike runtime — verified memory
  note), `temurin-21.0.11` (mitigation round — JBR tracks JDK 21), `temurin-25` (Gradle
  daemon JVM per `RELEASING.md` prerequisites — buildSrc embedded-Kotlin constraint).

## Pre-resolved questions

### 1. Spike shape: branch `spike/jcef` + new subproject `jcef-spike`; spike process ≠ shell process

- **Branch** `spike/jcef` in kzen-shell. Branch-only changes: `settings.gradle.kts` gains
  `include("jcef-spike")`; new directory `jcef-spike/` (own `build.gradle.kts`, `.gitignore`,
  one Kotlin main). **Zero edits to shell sources or the root `build.gradle.kts`** — the root
  jar/dist tasks can't pick up jcefmaven by accident, and SH2's territory is untouched.
- **The spike is a separate OS process** that points at a separately-booted real shell. This
  is deliberate: the embedded view's product position is "just another browser client" (DA
  plan § 5 — same server, same URLs), so the highest-fidelity spike *is* an external client.
  It also means the shell keeps its exact packaged flags (`-Xmx64m`) while the spike JVM's
  memory is measured in isolation — precisely the DA2 heap input.
- Rejected: spike code in the shell's `src/main` (leaks dependency into `runtimeClasspath` →
  manifest `Class-Path` + dist zips; risks accidental merge); a standalone scratch repo
  (loses the Gradle toolchain/buildSrc setup and the "lives in kzen-shell" ratified decision).

### 2. jcefmaven coordinates & facts (pinned 2026-07-19)

- **Latest version: `me.friwi:jcefmaven:146.0.10`** — released 2026-05-05 (Maven Central
  `maven-metadata.xml` lastUpdated `20260505070316`; GitHub release same date). Maps to
  **CEF `146.0.10+g8219561+chromium-146.0.7680.179`**, JCEF commit `d3de827`. Prior
  releases: 143.0.14, 141.0.10, 135.0.20.
  - https://github.com/jcefmaven/jcefmaven/releases
  - https://repo1.maven.org/maven2/me/friwi/jcefmaven/maven-metadata.xml
- **Windows x64 natives artifact** (bundling this as a dependency is what skips jcefmaven's
  default first-run GitHub download — README documents natives-as-dependencies; otherwise
  "natives will be downloaded and extracted on first run"):
  `me.friwi:jcef-natives-windows-amd64:jcef-d3de827+cef-146.0.10+g8219561+chromium-146.0.7680.179`
  (~100 MB class of artifact per README; exact size is a Phase 6 measurement).
  - https://repo1.maven.org/maven2/me/friwi/jcef-natives-windows-amd64/maven-metadata.xml
  - ⚠️ Metadata gotcha: that file's `<latest>`/`<release>` point at the **132.3.1-era** string
    (publish-order quirk) — always pin the **full explicit version string**, never rely on
    latest/`+` resolution.
- **JDK compatibility**: README says "Supports Java 8+"; the only documented `--add-opens`
  are **macOS-only** (`sun.awt` / `sun.lwawt` / `sun.lwawt.macosx`), and the
  `--add-exports` triple (`java.base/java.lang`, `java.desktop/sun.awt`,
  `java.desktop/sun.java2d`) is **OSR-mode-only** (jogamp). Windows **windowed** mode
  documents no flags. No JDK-25/26-specific issue is documented anywhere — that absence is
  exactly why this spike exists.
  - https://github.com/jcefmaven/jcefmaven (README)
- **JDK 24+ native-access restriction (JEP 472)** is the one *known* modern-JDK friction:
  since JDK 24 the default `--illegal-native-access=warn` warns when an unnamed module
  (jcefmaven loading `jcef.dll` via JNI) performs restricted native operations, and the
  default is slated to become `deny`. On temurin-26 assume **`--enable-native-access=
  ALL-UNNAMED`** is either required or at least silences the warning — Phase 3 runs once
  *without* it to record the actual behavior (warn vs deny), and the flag lands in DA3's
  launcher args.
  - https://openjdk.org/jeps/472
  - https://inside.java/2024/12/09/quality-heads-up/

### 3. Rendering mode: **windowed** (OSR off)

`createBrowser(url, /*isOffscreenRendered=*/false, /*isTransparent=*/false)` and
`cefSettings.windowless_rendering_enabled = false`. Reasons: native HWND child = native
Chromium input/IME/clipboard path and best rendering perf; **avoids jogamp entirely** — the
component with the worst modern-JDK track record (historical JDK 16/17 breakage; the
OSR-only `--add-exports`; `sun.misc.Unsafe` use that JDK 24+ JEP 498 also warns on); and it
matches the DA2 sketch (`getUIComponent()` into a Swing container) and IntelliJ's production
usage. Implication to note for DA2 (not a spike blocker): windowed CEF is a **heavyweight**
AWT component — Swing lightweight popups/menus/tooltips overlapping the view z-fight; the
spike's minimal chrome sidesteps this, DA2's tab strip must not overlap the view.

### 4. Spike JVM flags (initial set)

```
--enable-native-access=ALL-UNNAMED     # JEP 472 (record whether actually needed: run once without)
-XX:NativeMemoryTracking=summary      # measurement only (Phase 6 jcmd VM.native_memory); NOT a DA3 arg
```
No `--add-opens` initially (mac-only per README); no `--add-exports` (OSR-only). Add flags
only when an observed failure demands them, and record every addition verbatim — the final
flag set is a first-class spike output (DA3 jpackage `--java-options`).

### 5. "Packaged-style" shell boot = built jar + temurin-26 + the `.bat` args, from the repo root

**Not** the `distWindows` zip: its generated release config points at the unreleased
`v0.30.0` GitHub launcher URL (Current-state findings) — a dev-tree boot would fail the
launcher download. The faithful equivalent of `kzen-cmd.bat` (`jdk\bin\java.exe
-XX:+UseShenandoahGC -Xmx64m -jar kzen-<v>.jar`) using the dev `kzen-shell.properties`
(local `file://` launcher zip, re-extracted every boot) is:

```powershell
cd C:\Users\ostro\IdeaProjects\kzen-shell
& "C:\Users\ostro\.jdks\temurin-26.0.1\bin\java" -XX:+UseShenandoahGC -Xmx64m `
    -jar build\libs\kzen-0.30.0-SNAPSHOT.jar
```

Same JDK major, same GC, same heap, same properties-driven launcher acquisition, same child
spawning — everything the packaged app does except the `.bat` indirection and bundled-JDK
path.

### 6. Devtools observation: two channels, wired from the start

1. **Embedded devtools**: `browser.devTools` returns a `CefBrowser`; its `uiComponent` goes
   in its own `JFrame` behind a toolbar button. This is itself checklist item 1.
2. **Remote debugging backstop**: `cefSettings.remote_debugging_port = 9222` from the first
   run — if the embedded devtools is broken on 26, observe from real Chrome at
   `http://localhost:9222` instead (checklist items that need Network inspection stay
   executable either way; a broken embedded devtools alone is a FAIL on item 1 but not a
   spike abort).

## Step-by-step implementation

### Phase 0 — setup (branch, module, prerequisites)

1. `git -C C:\Users\ostro\IdeaProjects\kzen-shell checkout -b spike/jcef`
2. Edit `settings.gradle.kts`:
   ```kotlin
   rootProject.name = "kzen-shell"
   include("jcef-spike")
   ```
3. Create `jcef-spike/build.gradle.kts`:
   ```kotlin
   plugins {
       kotlin("jvm")    // version inherited from the root plugin classpath
   }

   repositories {
       mavenCentral()
   }

   kotlin {
       jvmToolchain(26)
   }

   dependencies {
       implementation("me.friwi:jcefmaven:146.0.10")
       runtimeOnly(
           "me.friwi:jcef-natives-windows-amd64:" +
           "jcef-d3de827+cef-146.0.10+g8219561+chromium-146.0.7680.179")
   }

   tasks.register<JavaExec>("runSpike") {
       group = "spike"
       description = "JCEF-on-JDK-26 spike window (DA1)"
       classpath = sourceSets.main.get().runtimeClasspath
       mainClass.set("tech.kzen.shell.spike.jcef.JcefSpikeMainKt")
       workingDir = projectDir                      // jcef-bundle/ extracts here (gitignored)
       jvmArgs(
           "--enable-native-access=ALL-UNNAMED",    // JEP 472 — Phase 3 records if required
           "-XX:NativeMemoryTracking=summary")      // Phase 6 measurement only
       args(providers.gradleProperty("spikeUrl").getOrElse("http://localhost:8080"))
   }
   ```
   (`JavaExec` picks up the module's JDK-26 toolchain launcher by default; if the daemon
   JVM leaks through — the spike prints `java.version` at startup — pin `javaLauncher`
   explicitly via `javaToolchains.launcherFor { }`.)
4. Create `jcef-spike/.gitignore`:
   ```
   jcef-bundle/
   ```
   (`build/` is already covered by the root `.gitignore`.)
5. Prerequisite check — the dev launcher zip the shell will boot from:
   `..\kzen-launcher\kzen-launcher-jvm\build\dist\kzen-launcher-0.30.0-SNAPSHOT.zip`.
   If absent: `cd ..\kzen-launcher && .\gradlew dist` (requires current kzen-lib/kzen-auto
   SNAPSHOTs in mavenLocal — normally already true on this machine).
6. Gradle daemon note: build with the usual Gradle JVM for this repo family
   (`JAVA_HOME` → `temurin-25`, per `RELEASING.md` prerequisites); the spike itself still
   *runs* on 26 via the toolchain launcher — that separation is the point.
7. Stage the new files by explicit path (`git add settings.gradle.kts
   jcef-spike/build.gradle.kts jcef-spike/.gitignore jcef-spike/src/...`). Commits happen on
   the spike branch only, with user approval — the branch is the spike's archive.

### Phase 1 — spike code

`jcef-spike/src/main/kotlin/tech/kzen/shell/spike/jcef/JcefSpikeMain.kt` — sketch (adjust
signatures to the 146 API where the compiler says so; the shape is what's load-bearing):

```kotlin
package tech.kzen.shell.spike.jcef

import me.friwi.jcefmaven.CefAppBuilder
import me.friwi.jcefmaven.MavenCefAppHandlerAdapter
import me.friwi.jcefmaven.impl.progress.ConsoleProgressHandler
import org.cef.CefApp
import org.cef.CefClient
import org.cef.browser.CefBrowser
import org.cef.callback.CefBeforeDownloadCallback
import org.cef.callback.CefDownloadItem
import org.cef.handler.CefDownloadHandlerAdapter
import org.cef.handler.CefLoadHandlerAdapter
import java.awt.BorderLayout
import java.awt.KeyboardFocusManager
import java.awt.event.WindowAdapter
import java.awt.event.WindowEvent
import java.io.File
import javax.swing.*
import kotlin.system.exitProcess


private const val defaultUrl = "http://localhost:8080"

fun main(args: Array<String>) {
    val url = args.firstOrNull() ?: defaultUrl
    val t0 = System.nanoTime()
    fun ms() = (System.nanoTime() - t0) / 1_000_000
    println("spike pid=${ProcessHandle.current().pid()} jvm=${System.getProperty("java.version")}")

    // 1) CEF init — off the EDT; build() blocks until the native CefApp is up.
    //    Natives resolve from the classpath bundle (jcef-natives-windows-amd64) — the
    //    ConsoleProgressHandler output proves NO download happened (extract-only on first run).
    val builder = CefAppBuilder().apply {
        setInstallDir(File("jcef-bundle"))                    // extraction target (Phase 6 measurement)
        setProgressHandler(ConsoleProgressHandler())
        cefSettings.windowless_rendering_enabled = false      // windowed (pre-resolved Q3)
        cefSettings.remote_debugging_port = 9222              // devtools backstop (pre-resolved Q6)
        setAppHandler(object : MavenCefAppHandlerAdapter() {
            override fun stateHasChanged(state: CefApp.CefAppState) {
                if (state == CefApp.CefAppState.TERMINATED) {
                    exitProcess(0)
                }
            }
        })
        // Contingency knobs, only if the view stays blank: addJcefArgs("--disable-gpu",
        // "--disable-gpu-compositing") — record in the verdict if needed.
    }
    val cefApp: CefApp = builder.build()
    println("CefApp initialized: ${ms()} ms")

    // 2) One client; minimal handlers. Downloads NEED an explicit handler in embedded CEF —
    //    without one the checklist's download item silently no-ops; empty path + showDialog
    //    = native Save As. (DA2 must carry a real version of this — record in verdict.)
    val client: CefClient = cefApp.createClient()
    client.addDownloadHandler(object : CefDownloadHandlerAdapter() {
        override fun onBeforeDownload(
            browser: CefBrowser?, downloadItem: CefDownloadItem?,
            suggestedName: String?, callback: CefBeforeDownloadCallback?
        ) {
            println("download: $suggestedName")
            callback?.Continue("", true)
        }
    })
    client.addLoadHandler(object : CefLoadHandlerAdapter() {
        override fun onLoadEnd(browser: CefBrowser, frame: org.cef.browser.CefFrame, httpStatusCode: Int) {
            if (frame.isMain) {
                println("loaded ${browser.url} ($httpStatusCode): ${ms()} ms")
            }
        }
    })

    val browser: CefBrowser = client.createBrowser(url, false, false)

    // 3) Swing shell: toolbar (DevTools / Split / Focus probe) + the browser component.
    SwingUtilities.invokeLater {
        val frame = JFrame("kzen JCEF spike — JDK ${System.getProperty("java.version")}")
        val toolbar = JToolBar().apply { isFloatable = false }
        val center = JPanel(BorderLayout()).apply { add(browser.uiComponent, BorderLayout.CENTER) }

        toolbar.add(JButton("DevTools").apply { addActionListener {
            val devTools = browser.devTools
            JFrame("DevTools").apply {
                add(devTools.uiComponent)
                setSize(1100, 700)
                isVisible = true
            }
        } })
        toolbar.add(JButton("Split").apply { addActionListener {
            // Proto-tabs: second independent view beside the first (Phase 5).
            val second = client.createBrowser(defaultUrl, false, false)
            center.removeAll()
            center.add(
                JSplitPane(JSplitPane.HORIZONTAL_SPLIT, browser.uiComponent, second.uiComponent)
                    .apply { resizeWeight = 0.5 },
                BorderLayout.CENTER)
            center.revalidate()
        } })
        toolbar.add(JButton("Focus probe").apply {
            // A plain Swing focus target beside the heavyweight CEF component (checklist item 8).
            addActionListener { println("swing button clicked; focus owner = " +
                KeyboardFocusManager.getCurrentKeyboardFocusManager().focusOwner) }
        })

        frame.add(toolbar, BorderLayout.NORTH)
        frame.add(center, BorderLayout.CENTER)
        frame.defaultCloseOperation = WindowConstants.DO_NOTHING_ON_CLOSE
        frame.addWindowListener(object : WindowAdapter() {
            override fun windowClosing(e: WindowEvent) {
                // Shutdown path: dispose browsers/client, then CefApp; TERMINATED → exitProcess.
                client.dispose()
                CefApp.getInstance().dispose()
                frame.dispose()
            }
        })
        frame.setSize(1500, 950)
        frame.setLocationRelativeTo(null)
        frame.isVisible = true
        println("window visible: ${ms()} ms")
    }
}
```

Notes locked into the sketch:
- **Windowed, not OSR** (Q3) — `windowless_rendering_enabled = false` and OSR arg `false`.
  Focus/IME ride the native HWND; the "Focus probe" button is the Swing↔CEF focus exercise.
- **Shutdown**: dispose client → `CefApp.dispose()` → `TERMINATED` state → `exitProcess`.
  Success criterion: **no orphan `jcef_helper.exe`** processes after close (checked in
  Phase 5). If disposal hangs, record it — DA2's window-close path needs the answer.
- **Timing instrumentation** is printed inline (`CefApp initialized` / `loaded` /
  `window visible`) — these are Phase 6's cold-start numbers; no separate harness.

### Phase 2 — boot the real shell (packaged-style)

1. `cd C:\Users\ostro\IdeaProjects\kzen-shell && .\gradlew build` (if not current).
2. Boot per pre-resolved Q5 (temurin-26, `-XX:+UseShenandoahGC -Xmx64m`, repo root CWD).
3. Expect: status window "Ready: http://localhost:8080"; the **system browser also opens**
   (`DesktopUi.onLoaded`) — that tab is not part of the spike, but use it once: confirm the
   launcher UI loads in the real browser — this establishes the non-CEF baseline that every
   later in-view failure is compared against.
4. Leave the shell running for the whole session; its log (console + `logs/`) is the
   SecurityGate observable ("Denied …" lines).

### Phase 3 — first light + flag discovery

1. `cd C:\Users\ostro\IdeaProjects\kzen-shell && .\gradlew :jcef-spike:runSpike`
2. **First run, deliberately without `--enable-native-access`** (comment the jvmArg out):
   record whether JDK 26 warns (`WARNING: A restricted method … has been called`) or denies
   (hard failure) on the JNI library load — this single data point decides whether the flag
   is cosmetic or mandatory in DA3. Then restore the flag for all subsequent runs.
3. Expected on success: `ConsoleProgressHandler` shows **extract-only** (no download —
   proves the classpath-natives path works: D2 input); `CefApp initialized: N ms`; launcher
   UI renders in the window.
4. First-light failure triage (in order): blank white view → retry with
   `addJcefArgs("--disable-gpu")`; JVM crash (`EXCEPTION_ACCESS_VIOLATION` / JNI
   `hs_err_pid*.log`) or `CefInitializationException` → capture the log, go to the
   mitigation round (§ Verification); `UnsatisfiedLinkError` → check extraction-dir
   integrity, delete `jcef-bundle/`, re-extract, retry once.

### Phase 4 — checklist exercises (DA1 step 2, in order)

Ordering rationale: the observation instrument (devtools) comes first; everything after is
observed through it. All exercises run **inside the CEF view** against the live shell.

| # | Item | Procedure | PASS = |
|---|------|-----------|--------|
| 1 | **Devtools toggle** | Toolbar `DevTools` button → embedded devtools frame; open Network tab. Backstop: real Chrome → `http://localhost:9222`. | Devtools opens, Network records requests. (Embedded broken but 9222 works = FAIL on this item, note it, continue via 9222.) |
| 2 | **SecurityGate pass-through** | In the CEF launcher UI: create a project, then start it (drives `GET /shell/project/start` — a protected mutating endpoint — with `Sec-Fetch-Site: same-origin`). Then open the project and edit any attribute (kzen-auto `/command/attribute/upsert` through the proxy). | Project reaches RUNNING; attribute edit persists; devtools shows 200s (no 403); **zero `Denied` lines in the shell log**. |
| 3 | **SSE push** | In the project: open/create a Script (a few steps), run it. Devtools Network → `/logic/events` (type `eventstream`): messages arriving as the run steps. Cross-check the poll cadence: `/logic/status` requests spaced **~10 s** (push proven healthy), not 1.5 s (fallback). | EventStream frames visible; 10 s status cadence; stepping repaints promptly (no poll-lag feel). |
| 4 | **Blob URLs / trace-binary** | Script with browser steps (BrowserOpen + navigate/action — the steps emit screenshots into the trace). Run; open the step film strip. Devtools: `/logic/trace-binary?run=&hash=` 200s (`application/octet-stream`); thumbnails + fullscreen render (client turns fetched bytes into `blob:` URLs). | Screenshots visible in strip + fullscreen; trace-binary requests 200; no broken-image icons. |
| 5 | **Clipboard** | Copy text from a page element → paste into Windows Notepad (out). Copy from Notepad → paste into a text attribute editor (in). Ctrl+C/V/X inside an editor; right-click context menu shows working copy/paste. | All four directions work. |
| 6 | **Keyboard shortcuts** | Type in text editors (chars, arrows, Home/End, selection); **Ctrl+S in the Script Raw tab** (the page-level save handler must receive it — no CEF "save page" interference); Tab traversal inside the page. | Keys land in the page; Ctrl+S saves the document; no keys swallowed by Swing/CEF chrome. |
| 7 | **Downloads** | Trigger a `/action/download` response: a Report document's output download (create a minimal Report over a small CSV if none exists). Lightweight fallback if Report setup is disproportionate: from the devtools console, `location.href = <any Content-Disposition URL observed in the real-browser baseline>`. | `CefDownloadHandlerAdapter` fires (console `download: <name>`), native Save As appears, file lands on disk intact. Record explicitly: **DA2 must ship a download handler** (CEF has no default). |
| 8 | **Focus/IME** | Click Swing `Focus probe` button → click into a CEF text field → type immediately; alternate several times. If an IME is available, enter composed text. | No dead-focus state (clicks always restore typing); no focus ping-pong loops; composed input lands (if exercised). |

Every row gets PASS/FAIL + a one-line note in the verdict table (Phase 7).

### Phase 5 — proto-tabs (two views side by side)

1. Toolbar `Split` → second `CefBrowser` beside the first (launcher in view 2, project in
   view 1).
2. **Isolation**: in view 1's devtools console run `while(true){}` (renderer busy-loop).
   View 2 must stay fully interactive. Recover view 1 (close/recreate, or stop via
   devtools). Also inventory processes: Task Manager / `Get-Process jcef_helper` — expect
   multiple helper processes (≥ one renderer per view + GPU/network utility processes).
3. **Focus across views**: click a field in view 1, type; click a field in view 2, type;
   alternate — input always lands in the clicked view.
4. **Per-view memory**: RSS snapshot before and after adding the 3rd view (Phase 6
   procedure) → marginal cost per view.
5. **Optional (DA2 input, 5-min cap)**: hide one view (`uiComponent.isVisible = false` via a
   scratch toolbar action, or collapse the split) while a run executes in it; in remote
   devtools (9222) check whether the page saw `visibilitychange` and closed its
   `/logic/events` stream (kzen-auto's visibility-gated SSE). Record either way — DA2's
   tab-switch SSE economy depends on whether CEF propagates occlusion to hidden views.
6. **Shutdown check**: close the spike window → all `jcef_helper.exe` gone, spike JVM
   exits 0.

### Phase 6 — measurements

All on Windows, PowerShell; record exact numbers in the verdict table.

| Metric | How measured |
|---|---|
| Natives dependency jar size (D2 input) | `Get-ChildItem "$env:USERPROFILE\.gradle\caches\modules-2\files-2.1\me.friwi" -Recurse -Filter *.jar \| Sort-Object Length -Descending \| Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}}` — report the `jcef-natives-windows-amd64` jar (and the `jcefmaven` jar for completeness). |
| Extracted bundle size (D2 input) | `"{0:N1} MB" -f ((Get-ChildItem -Recurse jcef-spike\jcef-bundle \| Measure-Object Length -Sum).Sum/1MB)` |
| Cold start — first ever run | One-time extraction included: the `CefApp initialized` / `window visible` / `loaded` timestamps from the very first `runSpike` (Phase 3). Label "first-run (extract)". |
| Cold start — steady state | Re-run `runSpike` with `jcef-bundle/` present: same three timestamps. This is the number an installed app sees; run 3×, report the median. |
| RSS with 3 views | With shell + project running and 3 CEF views open (Split twice, or a scratch 3-view tweak): spike JVM (pid printed at startup) + all helpers: `Get-Process -Id <spikePid> \| Select-Object @{n='MB';e={[math]::Round($_.WorkingSet64/1MB,0)}}` and `Get-Process jcef_helper \| Measure-Object WorkingSet64 -Sum` → report spike-JVM RSS, helper-total RSS, helper count, grand total. Keep the shell (`-Xmx64m`) and child JVMs out of the sum but note them for context. |
| Marginal RSS per view | Grand-total delta across the 2-view → 3-view transition (settle ~30 s first). |
| Spike-JVM heap (DA2 `-Xmx` input) | `& "C:\Users\ostro\.jdks\temurin-26.0.1\bin\jcmd" <spikePid> GC.heap_info` (used/committed) plus `jcmd <spikePid> VM.native_memory summary` (NMT total — the JNI/browser-bridge native side the heap number misses). Take after the 3-view state + one run with screenshots. |

### Phase 7 — verdict recording (closes gate D1)

All edits in `C:\Users\ostro\IdeaProjects\kzen\docs\plans\2026-07-25_desktop-and-hosting.md`:

1. **Progress tracker** (top block): tick `- [x] DA1 … (closed <date>, <GO|NO-GO>)`.
2. **§ 7 D1 bullet**: append one line —
   `**CLOSED <date>: GO — JCEF ratified** (jcefmaven 146.0.10 / CEF 146.0.7680.179 on temurin-26.0.1; see DA1 results)` or
   `**CLOSED <date>: NO-GO — Electron fallback triggered** (<one-line reason>; mitigation round result: <…>)`.
3. **§ 8 DA1**: append a `**Results (<date>)**` subsection containing, in order:
   - *Environment*: Windows version, temurin-26.0.1 build string, jcefmaven `146.0.10`,
     natives `jcef-d3de827+cef-146.0.10+g8219561+chromium-146.0.7680.179`, spike branch
     name + commit hash.
   - *Flags required* (verbatim JVM args + any `addJcefArgs`, each annotated
     required/cosmetic — feeds DA3): including the Phase 3 `--enable-native-access`
     warn-vs-deny observation.
   - *Checklist table*: the 8 Phase-4 rows + Phase-5 proto-tab findings (isolation, focus,
     optional visibility probe), each PASS/FAIL + note.
   - *Measurements table*: the 7 Phase-6 rows.
   - *DA2 notes*: recommended shell `-Xmx` (from heap/NMT numbers); "download handler is
     mandatory"; heavyweight-overlap caveat; hidden-view visibility finding; and the
     **`MainJarProcess` java.home inheritance correction** (children inherit the shell JVM —
     the shell-JDK-pin mitigation needs a child-java-home override; only load-bearing if the
     mitigation shape ships).
   - *Mitigation record* (only if exercised — § Verification).
4. The spike branch `spike/jcef` is pushed/retained as-is (reference for DA2); **never
   merged**.

## Tests

n/a — this is a spike; **the Phase-4/5 checklist IS the test**, executed manually against
the live shell and recorded as the D1 verdict. No automated tests are added; no existing
tests are touched (`ProxyHttpClientTimeoutTest` already pins the SSE-relay behavior the
checklist re-proves end-to-end).

## Verification

- **GO criterion** (verbatim from the DA plan): the Phase-4 checklist **all green on
  Windows**. Proto-tab findings and measurements inform DA2/D2 but only a hard failure
  there (e.g. no per-view isolation) blocks — footprint numbers can't fail the gate
  (300–400 MB is ratified acceptable).
- **Hard failure** (JNI crash on 26, SSE broken, input broken) → **one mitigation round**:
  re-run the *spike JVM only* on `temurin-21.0.11` (JBR-compatible major — JetBrains ships
  JCEF on a JDK-21-tracking runtime), same natives, same checklist. The shell and children
  stay on 26 throughout (they're separate processes — the spike shape makes this free).
  - If 21 passes: verdict = **conditional GO** — JCEF with the shell process pinned to a
    JBR-era JDK. Record the prerequisite this creates: `MainJarProcess` resolves child java
    from the shell's `java.home`, so the shipping shell would need a child-java-home
    override (small shell change, scheduled into DA2, not done in the spike).
  - If 21 also fails (or the failure is engine-level, e.g. SSE/input broken regardless of
    JDK): verdict = **NO-GO → Electron fallback** per D1 (DA2's window work moves to an
    Electron main process; DA3/DA4 to electron-builder — per the DA plan § 7; no further
    elaboration here).
- **Baseline discipline**: any in-view misbehavior is first reproduced in the real-Chrome
  baseline (Phase 2 step 3) before being attributed to CEF — a shell/launcher regression
  must not close D1 falsely.
- Session hygiene: shell shut down via its window (children reaped through the stdin
  lifeline); no stray `jcef_helper.exe` left; `jcef-bundle/` and `work/` artifacts stay on
  disk (gitignored) for DA2.

## Risks & gotchas

- **jcefmaven's "Java 8+" claim predates JDK 24's integrity work.** JEP 472 native-access
  (warn today, deny slated) is the known friction; unknown unknowns on 26 are precisely the
  spike's subject. Run the Phase 3 with/without-flag experiment before judging any crash.
- **Natives metadata `latest` is wrong** (points at the 132.3.1-era string) — pin the full
  explicit version; a `+`-range or `latest.release` resolution would silently fetch a
  mismatched natives/CEF pair.
- **`MainJarProcess` java.home inheritance** invalidates the DA plan's "children stay on 26"
  mitigation sentence as written — the spike is immune (separate process), but the verdict
  must carry the correction (Phase 7).
- **Windowed CEF = heavyweight HWND**: Swing popups/tooltips overlapping the view z-fight;
  irrelevant to the spike's minimal chrome, load-bearing for DA2's tab-strip design.
- **OSR is the fallback-of-last-resort, not a mitigation**: it drags in jogamp
  (`--add-exports`, `sun.misc.Unsafe`, historically the worst modern-JDK actor). If windowed
  fundamentally fails on 26, prefer the JDK-21 mitigation round over OSR.
- **Embedded devtools may fail independently of the engine working** — that's why
  `remote_debugging_port = 9222` is set from the first run; don't let a devtools-only
  failure stall the checklist.
- **First-run vs steady-state conflation**: the one-time ~100 MB extraction (plus a possible
  Windows Defender scan of fresh `jcef_helper.exe`) makes run #1 an outlier — Phase 6
  separates the two cold-start numbers deliberately.
- **Shell auto-opens the system browser** at boot (`DesktopUi.onLoaded`) — expected noise,
  and it doubles as the baseline browser; don't mistake it for spike behavior.
- **Connection budget**: 3 views on one origin share Chromium's ~6-per-origin HTTP/1.1 pool
  exactly like 3 Chrome tabs; kzen's visibility-gated SSE already economizes — but only if
  hidden CEF views actually receive `visibilitychange` (Phase 5 optional probe; DA2 input).
- **In-memory profile**: `cache_path` is left unset → localStorage/UI prefs don't survive
  spike restarts. Fine for DA1; DA2 sets a real profile dir. Don't chase "settings not
  persisted" as a bug.
- **Gradle daemon JVM ≠ spike JVM**: build with the repo-standard daemon (Java 25 per
  `RELEASING.md`); the toolchain launches the spike on 26. If `runSpike` ever reports a
  non-26 `java.version` (printed at startup), pin `javaLauncher` explicitly.

## Out of scope (decided — don't drift into)

- **Any shell source change** — no `DesktopUi` edits (SH2's territory), no JCEF init in
  `KzenShellMain`/`KzenShellContext` (that's DA2), no `MainJarProcess` child-java override
  (recorded as a conditional DA2 prerequisite only).
- **Tab strip / navigation-intercept UX** — DA2. The spike's Split button is a probe, not a
  tab model.
- **jpackage / jlink / installers** — DA3/DA4. The spike only *records* the flags they'll
  need.
- **Linux/macOS natives** — DA4/DA6 (the same jcefmaven version pins them when needed).
- **Electron work** — the fallback is *triggered and recorded* here at most, never started.
- **kzen-auto/kzen-launcher changes** — the UI is exercised as-is; any UI bug found is
  reported, not fixed, in this session.
- **Merging `spike/jcef`** — the branch is reference material for DA2; DA2 starts clean.
