# SH2 — child exit detection, surfaced to the UI — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-16_shell-launcher-improvements.md` **Phase 2** (decisions pre-made there — onExit
> callbacks not polling; tombstones; `exitCode` on the wire; file+ring-buffer output tee;
> bind-failure pane; state-machine tests — do not re-litigate). Every anchor verified against
> current kzen-shell / kzen-launcher master on 2026-07-19; the post-SER4/SER5 wire drift is
> resolved below (both status DTOs are now kotlinx `@Serializable`; the additive fields follow
> the established nullable-with-`= null`-default convention). Master-plan **coordination rule
> 11** honoured: DA work has not started, so SH2 builds its bind-failure pane per plan, cheap
> and self-contained, with the DA5-replaces-it note in § Dependencies. One session, S-M,
> medium risk (Windows process/thread edge cases — see § Risks).

## Scope & goal

A crashed project child today stays listed RUNNING forever (its pages 503 with no explanation;
recovery = manual stop-then-start), child stdout exists only as `println(">> …")` console echo
(unrecoverable in packaged/`javaw` mode), and a second launch of the shell hangs on
"Loading..." with a console-only bind stack trace. After this phase:

- a child death flips the launcher UI to an **"exited (code n)"** chip within a poll tick,
  with **Restart** (no stop needed) and **Dismiss** (clears the tombstone);
- a **boot failure** carries the child's last output lines in the status payload the UI shows;
- `logs/<name>.log` holds each child's full stdout+stderr (truncated per start, ~10 MB cap),
  alongside the shell's own logback `logs/run.log`;
- launching the shell twice shows a **"Cannot start — port busy / already running?"** pane in
  the Swing frame instead of a hung loader.

Two repos: **kzen-shell** (registries, process, main, DesktopUi, tests) and **kzen-launcher**
(common DTO, JS store/UI, dev ShellSimulator). No kzen-lib, kzen-auto, or kzen-project changes.

## Dependencies & coordination

- **Prerequisite-free**; B4 stage opener (`2026-07-16_master-plan.md:163–167`). SH3/SH4/SH5
  follow independently.
- **Master rule 11 (DA5 ↔ SH2)** (`2026-07-16_master-plan.md:225–229`): DA1 spike has not run,
  so SH2 ships its bind-failure pane in today's Swing `DesktopUi`. Keep it self-contained (one
  new `DesktopUi` pane + one port-preflight helper + the `KzenShellMain` wiring) so **DA5 can
  later delete it cleanly** in favour of focus-existing-window single-instance behaviour.
  Leave a one-line `// DA5 replaces this pane with single-instance focus` comment at the pane.
- **Ships-together contract**: shell and launcher zips always release together, so the new
  `RunningState.EXITED` enum value and the additive fields are safe. In the **dev loop** a
  mixed pairing (old launcher JS + new shell) would fail to decode `"state":"exited"` — build
  both sides in this session (see § Risks).
- **SH5 coordination**: docs-to-truth (AGENTS.md updates for exit surfacing / status shape) is
  SH5 item 7 — do **not** do an AGENTS sweep here. Two notes to carry to SH5: (a) kzen-shell
  `AGENTS.md:68` already claims `logs/` holds "shell + child-process stdout/stderr" — SH2 makes
  that true (today only the shell's logback writes there); (b) the SH5 dead-file list has
  drifted — `proxy/ProxyApi.kt`, `context/WebfluxConfig.kt`, `run/LauncherRunner.kt`,
  `model/ProjectModel.kt`, `process/GradleRunner.kt`, `process/GradleProcess.kt` are **already
  gone** from kzen-shell (verified by glob 2026-07-19). (c) SH5 item 4 will re-register the
  launcher under the literal name `main`, which will rename its tee file to `logs/main.log` —
  no action here.
- **Contracts honoured** (constituent plan § Contracts): `main.jar` rename convention
  untouched; stdin lifeline untouched (`MainJarProcess.kt:91–95` spawn flags, `:160–175`
  graceful kill); proxy client timeout contract untouched.

## Current-state findings (anchors verified 2026-07-19)

### ProcessRegistry — kzen-shell `src/main/kotlin/tech/kzen/shell/registry/ProcessRegistry.kt`

Flat `name → Info(name, process: Process, attributes)` map (`:15`, `:109–112`), every method
`@Synchronized` on the registry instance. `start(name, processBuilder, attributes)` (`:20–40`)
checks `!closed` and name-uniqueness (`check(!processes.containsKey(name)) { "already
started" }` `:27`), spawns, registers. **The `TODO: automatic un-registration (e.g. by
polling)` is exactly at `:44`**, above `unregister(name)` (`:45–49`); `unregister(process)`
(`:52–60`) is find-by-identity, idempotent (returns silently when absent). `close()`
(`:91–105`) sets `closed`, closes each child's stdin (lifeline EOF → graceful self-reap),
clears the map. **No exit detection anywhere** — the only `isAlive` in the repo is
`ProcessAwaitUtil.awaitAvailable:36`. No tombstones, no listener/callback surface.

### ProjectRegistry — `registry/ProjectRegistry.kt` (the state machine to fold into)

- States (`:32–37`): `STARTING("starting")`, `RUNNING("running")`, `STOPPING("stopping")`,
  `FAILED("failed")` — the `wire` string is what `list()` emits.
- `Entry` (`:44–52`): mutable `state` + `process: MainJarProcess?`, **guarded by the entry's
  monitor** for the start/stop hand-off; `sequence` renders `list()` newest-first (`:74–78`,
  `RunningProjectStatus(it.name, it.state.wire)` at `:77`). Entries in a `ConcurrentHashMap`
  (`:56`); background work on a cached daemon executor `kzen-project-lifecycle` (`:60–62`).
- `start()` (`:84–102`): `entries.compute` — existing non-FAILED entry ⇒ no-op; **FAILED is
  the only replaced state today** (`existing.state != ProjectState.FAILED` `:88`); a fresh
  Entry gets a new sequence (comment `:72–73` already anticipates "FAILED->restart … jumps to
  the top"). Spawn happens async in `runStart` (`:105–137`): catch `Throwable` ⇒ FAILED (or
  remove if a stop raced in, `:112–119`); success ⇒ under `synchronized(entry)` set `process`,
  flip to RUNNING unless STOPPING raced (`:124–130`), in which case kill+remove (`:133–136`).
- `stop()` (`:160–191`), under `synchronized(entry)`: RUNNING ⇒ STOPPING + background kill +
  remove; STARTING ⇒ flag STOPPING (runStart kills on completion); STOPPING ⇒ no-op;
  **FAILED ⇒ remove — this is already the UI "Dismiss"** (`:184–186`).
- Constructor takes only `mainJarRunner` (`:20–22`) — it does **not** hold `ProcessRegistry`
  today (needed for dismiss-clears-tombstone; see step 2).
- Lock order observed: entry monitor is taken alone; ProcessRegistry's monitor is only ever
  taken from *inside* `MainJarProcess` calls made **outside** any entry-synchronized block
  (`startImpl` `:140–144` and the executor kill lambda `:169–172` run unsynchronized). **No
  existing path nests the two monitors — the new code must preserve that invariant.**

### MainJarProcess / MainJarRunner — `process/`

- `MainJarProcess.start` (`:38–62`): `startProcess` (spawn + register, `:66–109`) →
  `startDrain` (`:112–127`) → `ProcessAwaitUtil.awaitAvailable(port, process, 120s)` (`:53`,
  timeout const `:22`; await polls HTTP 200 every 250 ms, returns false on child death or
  deadline — `ProcessAwaitUtil.kt:29–44`) → not ready ⇒ `kill()` then
  `throw IllegalStateException("Project '$name' did not become available on port $port")`
  (`:54–59`). **The child's output is discarded at this point — nothing captures it.**
- `startProcess`: `$javaHome/bin/java [jvmArgs] -jar <jar> --server.port=<port>
  --managed.lifeline=stdin --parent.pid=<pid>`, `directory(home)`,
  **`.redirectErrorStream(true)`** (`:101`) — stderr already merges into the drained stream,
  so the tee captures crash traces with no extra work. Attributes: `port`, `location`
  (`:103–105`).
- **The drain thread** (`:112–127`): `reader.readLine()` loop, **`println(">> $line")` at
  `:120`** — the console echo the plan keeps. No buffer, no file.
- `kill()` (`:138–157`): stdin `SHUTDOWN` sentinel + close → `waitFor(15s)` → `destroy()` →
  `destroyForcibly()` → `await()` (`:178–182`: `waitFor` + **`drain.join()`** +
  `unregister(process)`). Important consequence: **after `kill()` returns, the drain has fully
  consumed the child's output** — a ring-buffer snapshot taken then is complete.
- `MainJarRunner` (`MainJarRunner.kt:7–31`): thin pass-through, constructed once in
  `KzenShellContext:27`; 4-arg overload (launcher, `KzenShellContext.start:87`) and 6-arg
  (projects, `ProjectRegistry.startImpl:143`).

### Wire shape after SER5 (the expected drift — confirmed)

- Shell `model/RunningProjectStatus.kt:9–13`: kotlinx **`@Serializable data class
  RunningProjectStatus(name: String, state: String)`** — Jackson is gone. Served by
  `ktorMain`'s `ContentNegotiation { json() }` (`KzenShellMain.kt:71–76`; the comment there
  names this exact DTO). Ktor's `DefaultJson` has `encodeDefaults = true`, so a
  `val exitCode: Int? = null` field **will be emitted as an explicit `"exitCode":null`** —
  harmless (see client below).
- Launcher common `dto/RunningProject.kt:10–34`: kotlinx `@Serializable
  RunningProject(name, state: RunningState)` + `enum RunningState` with
  **`@SerialName("starting"|"running"|"stopping"|"failed")`** — the wire strings match the
  shell's `ProjectState.wire` by shape, not shared code (comment `:7–9`).
- Client parse path: `ClientShellRestApi.runningProjects()/runningProjectsSilent()`
  (`ClientShellRestApi.kt:14–24`) → `clientJson.decodeFromString`, where
  **`clientJson = Json { ignoreUnknownKeys = true }`** (`ajaxUtil.kt:17–19`). So old-launcher
  tolerance for new fields is already in place; missing fields fall to defaults.
- **Optional-field convention** (per SER work, verified in siblings): nullable **with**
  `= null` default — `StorageAreaInfo.budgetBytes: Long? = null` (kzen-auto),
  `StepTrace.note: String? = null`, `KzenLauncherConfig.parentPid: Long? = null`. The new
  fields follow it exactly (present-or-absent both decode; old servers/new clients and new
  servers/old clients both work).

### Launcher UI (the 0.29.x chip infrastructure — found)

- `components/manage/ProjectRunning.kt`: per-row flex layout `renderProjectRow` (`:108–154`) —
  name/link (`renderName` `:157–168`, link only when RUNNING), spinner for
  STARTING/STOPPING (`:129–137`), **status `Chip`** (`renderStatusChip` `:171–182`,
  `statusLabel` `:185–192`, `statusColor` `:195–202` — MUI `Chip`, `ChipColor.error` for
  FAILED), then a `when(state)` action column (`:141–152`): RUNNING ⇒ Stop, FAILED ⇒ Dismiss
  (both via `renderActionButton` `:205–225` → `onStop` `:57–63` → `shellRestApi.stopProject` +
  `LauncherStore.invalidateRunning()` — comment `:56` confirms stop==dismiss).
- `state/LauncherStore.kt`: adaptive poll (`startPolling` `:178–214`) — wakes every 0.5 s,
  fetches every tick while `isTransitioning()` (`:224–228`: **STARTING/STOPPING only** —
  EXITED must stay steady-state), else every 5 s. `startProject(detail)` (`:154–171`) is the
  optimistic-start path (pendingStartNames + `mergePendingStarts` `:246–257`, which builds
  synthetic `RunningProject(it, RunningState.STARTING)` rows — compiles unchanged with the
  new optional fields). `invalidateRunning()` (`:141–145`) is the immediate post-action
  refresh. **Restart inputs** (`path`, `jvmArgs`) live in `ProjectDetail`
  (`dto/ProjectDetail.kt:8–18`), available as `LauncherStore.projects`.
- `ManageProjectsScreen.kt:46–52`: the Available list hides any name present in the running
  section (**any** state) — so an exited project is only actionable from the Running section;
  Restart must live there (it does).
- Icons: `wrap/materialIcons.kt` has `PlayArrowIcon` (`:48–51`) — use it for Restart;
  `RemoveCircleOutlinedIcon` stays for Dismiss. `buttonIcon` helper already used at `:221`.
- **Dev simulator**: `kzen-launcher-jvm/.../server/dev/ShellSimulator.kt` stands in for
  `/shell/project[/start|/stop]` when `simulateShell` (FrontendDevelopment `:21`); routes at
  `KzenLauncherMain.kt:311–334`. Name containing `"fail"` ⇒ FAILED (`:35`, `:75`). It
  constructs `RunningProject(it.key, it.value.state)` (`:55`) — compiles unchanged; extend it
  to simulate exits (step 4) so the new UI is drivable without a real shell.

### Shell main / DesktopUi (bind path)

- `KzenShellMain.main` (`:22–35`): `kzenShellInit` (properties → `DesktopUi.setPort/show` →
  context + shutdown hook, `:39–58`) → **`context.start()`** (downloads + spawns the launcher
  child, `KzenShellContext.kt:76–88`) → `embeddedServer(Netty, port, "127.0.0.1") { ktorMain;
  kzenShellStarted() }.start(wait = true)`. `kzenShellStarted` → `DesktopUi.onLoaded()`
  (`:61–63`). **Ktor runs application modules before/around the engine bind**, so on a busy
  port the second instance may already have flipped the pane to "Ready" and opened the browser
  (pointing at the healthy first instance) before `start(wait = true)` throws — and because
  the Swing EDT is non-daemon, the JVM then **hangs** with a stale window and a console-only
  `BindException`. Worse, `context.start()` has already spawned a **second launcher child**.
  This is the exact failure mode the pane must replace; it dictates a pre-flight check
  *before* `context.start()` plus a catch backstop (step 6).
- `ui/DesktopUi.kt`: singleton object; `show()` (`:42–52`) builds the frame with
  `loadingPane()` (`:163–189`, the "Loading..." + indeterminate bar); `onLoaded()` (`:55–68`)
  swaps in `loadedPane()` (`:95–160`) and opens the browser; helpers `doc()` (`:192–196`),
  `logo()` (`:199–203`); frame `EXIT_ON_CLOSE` (`:227`); tray icon (`:245–292`). All pane
  swaps go through `SwingUtilities.invokeLater` — the new failure pane follows the same shape.
- `util/FreePortUtil.kt` exists (allocates child ports) — natural home for the pre-flight
  helper. Port default 8080, `--server.port=` override (`KzenShellProperties.kt:52–58`).
- `logs/` resolution: **CWD-relative** — logback `LOG_DIR` property is the bare `logs`
  (`src/main/resources/logback.xml:2`), and the dist launchers `cd /d "%~dp0"`
  (`build.gradle.kts:171–181`), so CWD = dist root in packaged mode, repo root in dev. The
  child tee uses the same `Paths.get("logs")` so shell and child logs co-locate, matching
  `AGENTS.md:68`.

### Test scaffolding (SH1)

`build.gradle.kts:50–51`: `kotlin("test")` + `ktor-server-test-host`. Existing tests:
`SecurityGateTest`, `SecurityGateKtorTest` (the `testApplication { … }` style),
`ArtifactInstallerTest`, `ProxyHttpClientTimeoutTest`. Plain-JVM module — `src/test/java`
compiles by default under the Gradle JVM plugin (used for the dependency-free stub main,
step 7). Launcher common has a near-empty `commonTest/CommonTest.kt` (JS-safe test-name
caveat noted there: no backtick names in anything that runs on JS).

## Pre-resolved questions

1. **Wire shape of the additive fields.** `RunningProjectStatus` (shell) and `RunningProject`
   (launcher) both gain `val exitCode: Int? = null` and `val recentOutput: List<String>? =
   null` — nullable-with-default per the SER convention (see findings). `RunningState` gains
   `@SerialName("exited") EXITED`; `ProjectState` gains `EXITED("exited")`. `recentOutput`
   carries the child's last output lines for FAILED (boot failure) and EXITED (crash tail);
   for non-spawn failures (e.g. corrupt state) it degrades to the exception message as a
   single line. ~100 lines × a few KB per poll for a (rare, steady-state) failed/exited row is
   fine on loopback.
2. **How ProjectRegistry learns of the exit.** Two *independent* `onExit` consumers, no shared
   listener plumbing: (a) `ProcessRegistry.start` attaches its own
   `process.onExit().thenAcceptAsync { … }` for **every** child (launcher included) —
   unregister + tombstone + log; (b) `ProjectRegistry.runStart` attaches a second callback via
   a new `MainJarProcess.onExit(callback)` for the **project fold-in** (Entry → EXITED).
   `Process.onExit()` returns a fresh `CompletableFuture` per call; multiple consumers are
   supported by the JDK. `thenAcceptAsync` (default = commonPool) is deliberate: it keeps the
   callbacks **off the process-reaper thread** (small stack, must never block) and off
   whatever thread completed the future.
3. **Tombstone ownership + clearing.** Tombstones (`{name, exitCode, exitedAt}`) live in
   `ProcessRegistry` (bounded LinkedHashMap, cap 100) as the process-level record — the wire
   `exitCode` comes from the ProjectRegistry `Entry` (single source for the UI), so there is
   no dual-read. Clearing: automatically on re-registration of the same name
   (`ProcessRegistry.start` = "next successful start"), and explicitly on Dismiss
   (`ProjectRegistry.stop` EXITED branch → `processRegistry.clearTombstone(name)` —
   ProjectRegistry gains the `processRegistry` constructor param; `KzenShellContext:29` is the
   only construction site to touch besides tests).
4. **Distinguishing crash from deliberate stop.** The fold-in callback flips
   EXITED **only when the entry is still RUNNING** (under `synchronized(entry)`); STOPPING
   means the stop path owns removal — no tombstone-driven UI state. Likewise
   `ProcessRegistry`'s exit callback no-ops after `closed` (shutdown kills every child;
   recording those as crashes would be noise).
5. **Where the ring buffer is snapshotted.** For a **boot failure**, `MainJarProcess.start`'s
   not-ready path already runs `kill()` → `await()` → `drain.join()` before throwing, so the
   ring is complete — the new `MainJarProcessStartException` carries the snapshot (plus the
   boot-time exit code when the child died on its own, captured **before** `kill()`). For a
   **crash while RUNNING**, no join is needed: `list()` reads
   `entry.process.recentOutput()` lazily at query time — by the first poll tick after the
   exit, the drain has long since consumed the EOF tail. This avoids any blocking work in the
   exit callbacks.
6. **Log-cap mechanism.** Simple byte-count cutoff, no rotation: a small `LineLogTee` class
   counts UTF-8 bytes written; on crossing 10 MB it writes one `[log cap reached; further
   output not written]` marker and stops writing (console echo + ring buffer continue).
   Truncate-per-start = open with `CREATE` + `TRUNCATE_EXISTING`. Extracting the tee into its
   own class makes the cap unit-testable without spawning processes.
7. **Restart, client-side.** Restart = "start again" (the server replaces FAILED/EXITED
   entries with a fresh attempt, fresh sequence ⇒ jumps to top — the machinery from 0.29.x).
   A new `LauncherStore.restartProject(name)` looks up the `ProjectDetail` by name and calls
   `shellRestApi.startProject(...)` + immediate `publishRunning(...)` refresh — deliberately
   **not** the optimistic `pendingStartNames` path: the name is already present in the list
   (as exited), so `mergePendingStarts` would drop the synthetic row anyway; the immediate
   refresh + 0.5 s transitional poll give feedback within one round trip. Restart is hidden
   when no matching `ProjectDetail` exists (project deleted while it was running) — only
   Dismiss shows then.
8. **Stub processes, portably.** Not `cmd /c` (Windows-only): a **dependency-free Java** stub
   main (`src/test/java`, pure JDK — no kotlin-stdlib on the child's classpath to worry
   about), spawned two ways: (a) directly via `java -cp <stub classes dir> …Stub args…` for
   ProcessRegistry-level tests; (b) packaged by the test fixture into a real `main.jar`
   (JarOutputStream: manifest `Main-Class` + the stub `.class` files copied off the test
   classpath) for full end-to-end ProjectRegistry tests through the real
   `MainJarRunner`/`MainJarProcess`/HTTP-readiness path. Behaviour (serve HTTP / die after N
   ms / exit code / lines to print) configured by a `stub-config.properties` the fixture
   writes into the project home (= child CWD); the `--server.port=<n>` arg is read for the
   HTTP mode. Details in § Tests.
9. **Testability seams** (smallest possible): `MainJarRunner` gains constructor params
   `logDir: Path = Paths.get("logs")` and `readinessTimeout: Duration =
   Duration.ofSeconds(120)`, threaded into `MainJarProcess.start` (the 120 s const moves out
   of the companion). Production call sites are unchanged (defaults); tests pass a temp dir +
   ~5 s. No interfaces, no open-classing, no mocking.
10. **Bind failure: pre-flight + backstop.** Pre-flight (`FreePortUtil.isTcpPortFree(port)`,
    a loopback `ServerSocket` bind probe with `reuseAddress` left false — on Windows,
    SO_REUSEADDR would mask the conflict) runs **before `context.start()`**, so a second
    instance never downloads/spawns a second launcher child; on failure it shows the pane
    and returns without building the context. The try/catch around `start(wait = true)`
    (walking the cause chain for `BindException`) remains as the TOCTOU backstop; it calls
    `context.close()` (reaps the just-spawned launcher) before showing the same pane.
11. **What FAILED gains beyond today.** `exitCode` when the child died during boot, and
    `recentOutput` — e.g. java's `Error: Invalid or corrupt jarfile …` (stderr is already
    merged by `redirectErrorStream(true)`), rendered under the row. Note the *missing*-jar
    case never reaches the async path from the UI: `ProxyHandler.start:93–94` already 400s
    synchronously (`"main.jar not found in: …"` → ErrorBus banner). The async payload matters
    for the corrupt-jar / crash-during-boot / readiness-timeout cases.

## Step-by-step implementation

### Step 1 — `ProcessRegistry`: onExit wiring + tombstones + exposure

`registry/ProcessRegistry.kt`:

1. Add nested `data class Tombstone(val name: String, val exitCode: Int, val exitedAt:
   Instant)` and a bounded insertion-ordered map:
   ```kotlin
   private val tombstones = object: LinkedHashMap<String, Tombstone>() {
       override fun removeEldestEntry(eldest: Map.Entry<String, Tombstone>) = size > maxTombstones
   }
   ```
   with `maxTombstones: Int = 100` as a constructor parameter (default; tests may shrink it).
2. In `start()` (`:20–40`): after the existing checks, `tombstones.remove(name)` (a fresh
   registration supersedes the previous death record — the "cleared on next successful
   start"), and after `processBuilder.start()` attach:
   ```kotlin
   process.onExit().thenAcceptAsync { exited -> onProcessExit(name, process, exited.exitValue()) }
   ```
3. New `@Synchronized private fun onProcessExit(name, process, exitCode)`: if `closed`,
   return (shutdown reaping is not a crash); if `processes[name]?.process === process`,
   remove it and record `Tombstone(name, exitCode, Instant.now())`; log
   `info("Process '{}' exited with code {}", name, exitCode)`. The identity check makes the
   callback a no-op when a restart already replaced the name (the old process was
   unregistered by `kill()`→`await()` anyway — both unregister paths are idempotent; keep
   both).
4. **Delete the `TODO: automatic un-registration (e.g. by polling)` at `:44`** — this is it.
5. Expose `@Synchronized fun tombstone(name: String): Tombstone?` and
   `@Synchronized fun clearTombstone(name: String)`.
6. Concurrency invariant to keep (comment it on the class): the ProcessRegistry monitor is a
   **leaf** — never call out to ProjectRegistry/MainJarProcess while holding it, and exit
   callbacks run via `thenAcceptAsync` (never on the reaper thread, never while holding an
   entry monitor).

### Step 2 — `ProjectRegistry`: fold exits into the state machine

`registry/ProjectRegistry.kt`:

1. Constructor: `class ProjectRegistry(private val mainJarRunner: MainJarRunner, private val
   processRegistry: ProcessRegistry)`. Update `KzenShellContext:29` to
   `ProjectRegistry(mainJarRunner, processRegistry)`.
2. `ProjectState` (`:32–37`): add `EXITED("exited")` (doc: child died while RUNNING; terminal
   like FAILED — restart replaces, stop dismisses).
3. `Entry` (`:44–52`): add `var exitCode: Int? = null` and
   `var failureOutput: List<String>? = null` (both written under the entry monitor).
4. `start()` (`:88`): replace-condition becomes
   `existing.state != ProjectState.FAILED && existing.state != ProjectState.EXITED` (both
   terminal states restartable; the newest-first comment at `:71–73` already describes the
   resulting jump-to-top).
5. `runStart` (`:105–137`):
   - **Failure path** (`:110–120`): before the state flip, harvest detail —
     `if (e is MainJarProcessStartException) { entry.exitCode = e.exitCode;
     entry.failureOutput = e.recentOutput }` else
     `entry.failureOutput = e.message?.let { listOf(it) }` — inside the existing
     `synchronized(entry)` block.
   - **Success path**: after the RUNNING flip (and only when `!stopRequested`), attach the
     fold-in: `process.onExit { code -> onChildExit(entry, code) }`. If the child already
     exited, the callback fires immediately (still async) and correctly lands EXITED.
6. New `private fun onChildExit(entry: Entry, exitCode: Int)`:
   ```kotlin
   synchronized(entry) {
       if (entry.state != ProjectState.RUNNING) { return }   // STOPPING/replaced: stop path owns it
       entry.state = ProjectState.EXITED
       entry.exitCode = exitCode
   }
   logger.warn("Project '{}' exited with code {}", entry.name, exitCode)
   ```
   Do **not** touch ProcessRegistry here (its own callback handles unregister+tombstone) —
   preserves the no-nesting lock invariant.
7. `list()` (`:74–78`): map the new fields —
   ```kotlin
   .map {
       val recentOutput = when (it.state) {
           ProjectState.FAILED -> it.failureOutput
           ProjectState.EXITED -> it.process?.recentOutput()
           else -> null
       }
       RunningProjectStatus(it.name, it.state.wire, it.exitCode, recentOutput)
   }
   ```
   (Reads tolerate slight staleness, per the existing `:41–43` comment; `recentOutput()` is a
   synchronized snapshot — see step 3.)
8. `stop()` (`:160–191`): add the branch
   `ProjectState.EXITED -> { entries.remove(name, entry); processRegistry.clearTombstone(name) }`
   — Dismiss clears the tombstone. (Take the ProcessRegistry monitor *after* leaving… it is
   inside `synchronized(entry)` here — acceptable only if nothing ever takes the monitors in
   the reverse order; to keep the invariant airtight, hoist the `clearTombstone` call to just
   after the `synchronized(entry)` block, gated on a local `dismissedExited` flag.)

### Step 3 — `MainJarProcess`: ring buffer + log tee + failure payload

`process/` package:

1. New `process/LineLogTee.kt` — small class: `LineLogTee(path: Path, capBytes: Long =
   10L * 1024 * 1024)`; `fun appendLine(line: String)`; `fun close()`. Opens lazily on first
   line (`Files.createDirectories(parent)`; `CREATE` + `TRUNCATE_EXISTING` + `WRITE`;
   UTF-8 `BufferedWriter`), writes line + `\n`, **flushes per line** (a crashing child's last
   lines must survive a shell hard-death; volume is low), counts bytes; over cap ⇒ write the
   marker line, close, and go inert. Any `IOException` (locked file, disk full) ⇒ warn once,
   go inert — echo + ring buffer are unaffected.
2. New `process/MainJarProcessStartException.kt`:
   `class MainJarProcessStartException(message: String, val exitCode: Int?, val recentOutput:
   List<String>): IllegalStateException(message)`.
3. `MainJarProcess`:
   - Instance state: `private val recentLines = ArrayDeque<String>()` (companion
     `recentOutputLines = 100`); `fun recentOutput(): List<String>` =
     `synchronized(recentLines) { recentLines.toList() }`;
     `fun onExit(callback: (Int) -> Unit)` =
     `process.onExit().thenAcceptAsync { callback(it.exitValue()) }`.
   - `startDrain` (`:112–127`) becomes instance-scoped (or takes the buffer + tee): per line —
     **keep `println(">> $line")`** (`:120`), append to ring
     (`synchronized(recentLines) { if (size == cap) removeFirst(); addLast(line) }`), and
     `tee.appendLine(line)`; on EOF, `tee.close()` in a `finally`.
   - Companion `start(...)` signature gains `logDir: Path` and
     `readinessTimeout: Duration` params (the `:22` const becomes the default value); tee path
     = `logDir.resolve("$name.log")` (names are safe: project names are SH1-validated single
     segments; the launcher name is a version dir name).
   - Not-ready path (`:54–59`): capture **before** killing —
     `val bootExitCode = if (!process.isAlive) process.exitValue() else null` — then `kill()`
     (which joins the drain, completing the ring), then
     `throw MainJarProcessStartException("Project '$name' did not become available on port
     $port", bootExitCode, mainJarProcess.recentOutput())`.
4. `MainJarRunner`: constructor
   `(processRegistry, logDir: Path = Paths.get("logs"), readinessTimeout: Duration =
   Duration.ofSeconds(120))`, both threaded through the two `start` overloads.
   `KzenShellContext` call sites unchanged. The launcher child (4-arg overload) gets the same
   tee for free — `logs/kzen-launcher-<v>.log`.

### Step 4 — wire DTOs + dev simulator

1. Shell `model/RunningProjectStatus.kt`: add `val exitCode: Int? = null` and
   `val recentOutput: List<String>? = null`; extend the doc comment (state values now include
   `"exited"`; fields populated for failed/exited entries; kotlinx per SER5).
2. Launcher common `dto/RunningProject.kt`: mirror the two fields on `RunningProject`; add
   `@SerialName("exited") EXITED` to `RunningState` (doc: child died while running; terminal;
   Restart or Dismiss).
3. Launcher dev `ShellSimulator.kt`: (a) mirror the terminal-state semantics — the
   `start()` replace-condition (`:64`) becomes
   `existing.state != RunningState.FAILED && existing.state != RunningState.EXITED`, and
   `stop()`'s immediate-dismiss branch (`:91–94`) also matches EXITED; (b) add an exit
   trigger: a name containing `"exit"` reaches RUNNING then, ~5 s later, flips to
   EXITED with `exitCode = 3` and a couple of canned `recentOutput` lines (extend `Entry` with
   the two fields; `list():55` passes them through). Keeps the whole SH2 UI drivable from
   `FrontendDevelopment` with no shell.

### Step 5 — launcher UI: exited chip, Restart, Dismiss, failure detail

1. `state/LauncherStore.kt`: add
   ```kotlin
   fun restartProject(name: String) {
       val detail = projects?.find { it.name == name } ?: return
       launchUiAction {
           shellRestApi.startProject(detail.name, detail.path, detail.jvmArgs)
           publishRunning(shellRestApi.runningProjects())
       }
   }
   ```
   (No optimistic row — pre-resolved question 7.) `isTransitioning` (`:224–228`) is
   deliberately unchanged: EXITED is steady-state, idle cadence.
2. `components/manage/ProjectRunning.kt`:
   - `renderStatusChip` takes the `RunningProject` (not just state) so the label can be
     `"exited (${exitCode})"` (plain `"exited"` when the code is null); `statusLabel` /
     `statusColor` gain EXITED — `ChipColor.error` (a crash is an error; boot-failed vs
     crashed is already distinguished by the label).
   - Action `when` (`:141–152`): `RunningState.EXITED ->` render **Restart**
     (`PlayArrowIcon`, enabled only when `LauncherStore.projects` has the name — otherwise
     omit) calling a new `onRestart(name)` → `LauncherStore.restartProject(name)`, then
     **Dismiss** (existing `renderActionButton(name, "Dismiss",
     RemoveCircleOutlinedIcon::class)` → `onStop`, which server-side removes the entry and
     clears the tombstone).
   - `renderName` (`:157–168`): EXITED is not proxyable — plain text (no change needed;
     link is RUNNING-only already).
   - Detail lines: after the flex row, when `state == FAILED || state == EXITED` and
     `recentOutput?.isNotEmpty() == true`, render a monospace block (small font,
     `whiteSpace = pre-wrap`, `maxHeight ≈ 10.em`, `overflow = auto`, subtle background) with
     the lines joined by newlines. Always visible — a failed/exited row is exactly when the
     user needs the trace; no toggle machinery.
3. No `ClientShellRestApi` / `ajaxUtil` changes — decode is shape-driven and tolerant.

### Step 6 — bind-failure pane (`KzenShellMain` + `DesktopUi` + `FreePortUtil`)

1. `util/FreePortUtil.kt`: add
   ```kotlin
   fun isTcpPortFree(port: Int): Boolean =
       try { ServerSocket().use { it.bind(InetSocketAddress("127.0.0.1", port)) }; true }
       catch (e: IOException) { false }
   ```
   (Leave `reuseAddress` unset/false — on Windows SO_REUSEADDR would mask a live listener.)
2. `KzenShellMain`:
   - `kzenShellInit` returns `KzenShellContext?`: after `KzenShellProperties.load` and
     `DesktopUi.setPort`, pre-flight — if `!FreePortUtil.isTcpPortFree(properties.port)`:
     `logger.error("Port {} already in use — is Kzen already running?", properties.port)`;
     `DesktopUi.showBindFailure(properties.port)`; return `null` (no launcher
     download/spawn, no shutdown hook, no Ktor). `main` becomes
     `val context = kzenShellInit(args) ?: return` — the Swing EDT keeps the JVM alive to
     show the pane.
   - Backstop: wrap `.start(wait = true)` in try/catch; walk the cause chain for
     `java.net.BindException`; on match — `logger.error`, `context.close()` (reaps the
     just-spawned launcher child), `DesktopUi.showBindFailure(context.properties.port)`, and
     swallow (frame stays up); otherwise rethrow.
3. `ui/DesktopUi.kt`: add `fun showBindFailure(port: Int)` — `SwingUtilities.invokeLater`;
   create the frame via the existing `createAndShowUi()` if `show()` hasn't run (pre-flight
   path calls it after `show()`, but be defensive); set title `"$title - Cannot start"`; swap
   in a new `bindFailurePane(port)` built from the existing `logo()`/`doc()` helpers:
   heading **"Cannot start"**; lines — "Port $port on 127.0.0.1 is already in use.",
   "Kzen may already be running — check your browser tabs and the system tray.",
   "If another app owns the port, start Kzen with --server.port=<other>."; buttons — **"Open
   in browser"** (reuses `openInBrowser()` — the healthy first instance is at the same URL)
   and **"Exit"** (`exitProcess(1)`). Mark the pane
   `// DA5 replaces this pane with single-instance focus-existing-window behaviour.`

### Step 7 — tests (per § Tests below)

## Tests

All in kzen-shell unless noted; scaffolding = SH1's `kotlin("test")` + JUnit assertions
(ktor-server-test-host not needed for these — no new routes).

**`src/test/java/tech/kzen/shell/testutil/ShellTestStub.java`** — dependency-free stub main
(pure JDK, so the generated jar needs no classpath). Reads `stub-config.properties` from CWD
if present, else key=value program args (args win). Keys: `serve` (open `ServerSocket` on the
`--server.port=<n>` arg; answer every accept with a minimal `HTTP/1.1 200 OK`),
`dieAfterMillis`, `exitCode` (default 0), `sleepMillis` (non-serve lifetime), `lineN` /
repeated `line=` (printed to stdout at startup; also print one line to **stderr** to pin the
`redirectErrorStream` merge). Watches stdin on a daemon thread: EOF or `SHUTDOWN` ⇒ exit 0
(honours the lifeline so test `kill()`s are fast).

**`src/test/kotlin/tech/kzen/shell/testutil/StubProjectFixture.kt`** — builds a temp project
home: `main.jar` via `JarOutputStream` (manifest `Main-Class: tech.kzen.shell.testutil.
ShellTestStub`; the `.class` file(s) copied from the test classpath — locate the classes dir
via `ShellTestStub::class.java.protectionDomain.codeSource.location`), plus
`stub-config.properties` per scenario. Variants: `serving(dieAfterMillis?, exitCode?)`,
`silent(sleepMillis)`, `corruptJar()` (garbage bytes). Also exposes
`stubCommand(vararg args)` → `listOf("$javaHome/bin/java", "-cp", <stub classes dir>,
"tech.kzen.shell.testutil.ShellTestStub", *args)` for registry-direct tests.

**`registry/ProcessRegistryTombstoneTest.kt`** (~4 tests, no jar needed — raw
`ProcessBuilder(stubCommand("exitCode=3", "line=boom"))`):
- exit ⇒ within timeout (poll ≤10 s): name unregistered, `tombstone(name).exitCode == 3`.
- `clearTombstone` ⇒ null.
- re-`start` under the same name ⇒ old tombstone auto-cleared.
- `close()` before exit ⇒ no tombstone recorded (shutdown reap is not a crash).

**`registry/ProjectRegistryStateMachineTest.kt`** — the phase's core. Per-test:
`ProcessRegistry()`, `MainJarRunner(processRegistry, logDir = temp/"logs", readinessTimeout =
Duration.ofSeconds(5))`, `ProjectRegistry(runner, processRegistry)`; helper
`awaitState(name, state, timeoutMs)` polling `list()`. Tear down via `stop` + registry
`close()`s. Scenarios (each spawns a real child JVM through the real spawn/readiness path —
budget ~1 s startup each):
1. **exit → tombstone → list shows exited → restart clears**: `serving(dieAfterMillis=1500,
   exitCode=3)` ⇒ STARTING → RUNNING → EXITED with `exitCode == 3` and non-empty
   `recentOutput` in `list()`; tombstone present; rewrite config to plain `serving()`,
   `start` again ⇒ RUNNING, `exitCode == null`, tombstone cleared.
2. **start failure captures output**: `corruptJar()` ⇒ FAILED within the deadline;
   `recentOutput` non-empty (java's `Error: Invalid or corrupt jarfile` — arrives via the
   merged stderr); ProcessRegistry empty.
3. **start-timeout (alive but silent)**: `silent(sleepMillis=60_000)` ⇒ FAILED after ~5 s;
   child reaped (`ProcessRegistry.contains == false`); `recentOutput` contains the stub's
   startup lines; `exitCode == null` (killed, not died).
4. **concurrent duplicate start**: two threads `start` the same name ⇒ exactly one `list()`
   entry, one registered process, reaches RUNNING; then `stop`.
5. **dismiss clears**: after (1)'s EXITED — `stop(name)` ⇒ gone from `list()`,
   `tombstone(name) == null`.

**`process/LineLogTeeTest.kt`** — pure file tests (no processes): lines land verbatim;
re-open truncates; a tiny `capBytes` (e.g. 64) stops output after the marker line; write
after an induced `IOException` is inert (delete the parent dir mid-test or use an invalid
path).

**`util/FreePortUtilTest.kt`** — `isTcpPortFree`: free ephemeral port ⇒ true; while a
`ServerSocket` holds it ⇒ false.

**kzen-launcher** `kzen-launcher-common/src/commonTest/kotlin/tech/kzen/launcher/common/dto/
RunningProjectSerializationTest.kt` (JS-safe method names — no backticks, per
`CommonTest.kt:7–8`): with `Json { ignoreUnknownKeys = true }` — decodes
`{"name":"x","state":"exited","exitCode":3,"recentOutput":["a","b"]}`; decodes the legacy
shape `{"name":"x","state":"running"}` to null defaults; decodes explicit
`"exitCode":null` (the Ktor `encodeDefaults = true` emission). Pins the cross-repo contract
on both JVM and JS.

Not tested automatically (deliberate): `DesktopUi` (Swing, headless CI) — only the
`isTcpPortFree` helper is; the launcher UI rendering (no component-test rig exists — manual
matrix + ShellSimulator cover it).

## Verification (manual matrix, after `./gradlew build` green in both repos)

Build/run: kzen-shell `./gradlew build` then run per its AGENTS (JDK 26:
`& "C:/Users/ostro/.jdks/temurin-26.0.1/bin/java" -jar build/libs/kzen-shell-0.30.0-SNAPSHOT.jar`);
launcher rebuilt first (`kzen-launcher ./gradlew build :kzen-launcher-jvm:dist`) so the
`file://` dev source re-extracts the new launcher on shell boot.

1. **Crash surfacing**: start a project from the launcher UI; find its JVM
   (`Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object { $_.CommandLine
   -like '*main.jar*server.port*' }`) and `taskkill /F /PID <pid>` ⇒ within a poll tick
   (≤5 s idle cadence) the row shows the **exited (1)** chip + Restart + Dismiss; the crash
   tail renders under the row; `logs/<name>.log` (under the shell's CWD) holds the full
   output.
2. **Restart without stop**: click Restart ⇒ row flips to starting (top of list) → running;
   the project's pages proxy again; chip's exit code gone.
3. **Dismiss clears**: crash again, click Dismiss ⇒ row gone;
   `curl http://localhost:8080/shell/project` shows no entry (tombstone cleared — restart
   from Available works normally).
4. **Boot failure payload**: stop the project; **corrupt** its `main.jar` (replace with a
   text file — do *not* just rename: a missing jar is caught synchronously by
   `ProxyHandler.start`'s 400 and never exercises the async path); Run ⇒ FAILED within the
   readiness deadline, with `Invalid or corrupt jarfile` lines under the row. (Also confirm
   the rename variant still yields the immediate error banner — unchanged SH1-era behaviour.)
   Restore the jar; Run ⇒ running.
5. **Log truncate/cap**: `logs/<name>.log` truncates on each start (restart, check first line
   is fresh); cap is pinned by `LineLogTeeTest` (manual 10 MB reproduction not required).
6. **Double launch**: with the shell running, launch it again (same port) ⇒ the second
   instance shows the **Cannot start** pane (no hung "Loading...", no browser hijack, and —
   via pre-flight — no second launcher child in Task Manager); "Open in browser" lands on the
   healthy first instance; Exit closes the second instance; the first is unaffected.
7. **Dev simulator**: `FrontendDevelopment` (launcher standalone) — create/start a project
   named e.g. `demo-exit` ⇒ starting → running → exited (3) with canned output ⇒ Restart and
   Dismiss both behave; a `-fail` name still shows the FAILED flow.
8. **Regression sweep**: normal start/stop of a healthy project; stop-while-starting; page
   refresh mid-transition (poll re-syncs); shell exit closes children (lifeline unchanged).

## Risks & gotchas (Windows process/thread edge cases)

- **Process-reaper thread**: `Process.onExit()` completes on the JVM's small-stack reaper
  thread. Every continuation in this phase uses `thenAcceptAsync` (commonPool) — never
  `thenAccept` — and the callbacks stay short and non-blocking (no `drain.join()`, no
  `waitFor`). Ring-buffer snapshots for EXITED are read lazily in `list()` instead (the drain
  is done by then), and the boot-failure snapshot is taken after `kill()` already joined the
  drain on the lifecycle thread.
- **Lock ordering**: the ProjectRegistry entry monitor and the ProcessRegistry monitor must
  never nest (today they don't). New code keeps ProcessRegistry calls outside
  `synchronized(entry)` blocks (see step 2.8's hoist) and keeps `onProcessExit` /
  `onChildExit` single-monitor.
- **Deliberate stop vs crash**: the EXITED flip is gated on `state == RUNNING` under the
  entry monitor; STOPPING (user stop, stop-during-boot) and shutdown (`closed` gate in
  ProcessRegistry) never surface as crashes. `destroyForcibly`/taskkill on Windows reports
  exit code 1 — the UI shows it verbatim, which is fine ("exited (1)").
- **Immediate exit race**: a child that dies before `onExit` is attached still fires the
  callback (CompletableFuture already complete ⇒ async-dispatched immediately); both
  attachment sites tolerate it.
- **Windows file locks on the tee**: restart truncates `logs/<name>.log`. The previous
  drain's writer closes at EOF (which precedes EXITED-restartability), so a conflict is a
  narrow race; if `TRUNCATE_EXISTING` does throw (`FileAlreadyBeingUsedException`-style),
  `LineLogTee` goes inert for that run with a warn — output still reaches console + ring.
  Accepted failure mode; do not add retry loops.
- **Long/odd output lines**: the drain is line-based (`readLine`); a child emitting one giant
  line (no newline) buffers unbounded in the reader as today — unchanged behaviour, out of
  scope. The 100-line ring bounds wire payloads regardless.
- **Ktor module-vs-bind ordering**: the "Ready" pane / browser-open may fire before the bind
  fails (module runs first). The pre-flight makes that path near-unreachable; the backstop
  still repaints to the failure pane afterwards. Don't rely on the backstop alone.
- **Mixed dev versions**: an old launcher bundle decoding `"state":"exited"` throws in
  `clientJson` (unknown **enum value** is not an unknown *key*) — the silent poll logs and
  retries, but the running list freezes. Rebuild launcher + shell together (packaged releases
  ship together by contract).
- **Enum/wire duplication**: `ProjectState.wire` (shell) and `@SerialName` (launcher) must
  both say `"exited"` — pinned by the commonTest decode test + eyeball; there is no shared
  code between the repos by design.
- **commonPool usage**: callbacks are tiny (map ops + logging); no risk of starving the pool.
  Do not move them onto the ProjectRegistry lifecycle executor — that executor may be
  saturated by a blocking `kill()` during shutdown.

## Out of scope (don't drift into)

- **AGENTS.md / docs sweep** — SH5 item 7 (carry the three notes in § Dependencies).
- **Single-instance focus / second-launch UX beyond the pane** — DA5 (rule 11).
- **Registry durability, `--project.home`** — SH3.
- **Tombstone persistence across shell restarts** — in-memory only; a shell restart clears
  exited rows (children die with the shell via the lifeline anyway).
- **Log rotation / retention** for child logs — truncate-per-start + cap only (the shell's
  own logback rotation is untouched).
- **Launcher-child death UI** — the launcher's exit is recorded (tombstone + log + auto
  unregister ⇒ the existing 503 `process-unavailable` on `/main/…`), but no new UI: there is
  no surviving UI to show it in. Anything more is a shell-hardening topic for later.
- **WebSocket pass-through, ErrorBus behaviour changes** (`ErrorBus.onSuccess` clearing is
  SH5 item 5), **`main`-alias centralization** (SH5 item 4).
