# SH3 — registry durability + explicit project home — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-16_shell-launcher-improvements.md` **Phase 3** (`:102–131`); master plan Stage B4
> (`2026-07-16_master-plan.md:163–167`, `:327`) — SH3 is independent of SH2/SH4. Decisions
> pre-made in the constituent plan (in-memory repos + temp-file/ATOMIC_MOVE persistence, file
> format/location-on-disk unchanged; `--project.home` explicit path with `../kzen-proj`
> interactive fallback; `LauncherEnvironment` → constructor injection) — do not re-litigate.
> Anchors verified against kzen-launcher `2257bae` and kzen-shell `b02c957` on 2026-07-19; one
> scope drift called out below (ArchetypeRepo no longer has a YAML registry). Two repos touched:
> **kzen-launcher** (primary) + **kzen-shell** (spawn arg). Small session.

## Scope & goal

1. **Registry durability (launcher).** `ProjectRepo` — the `kzen-projects.yaml` registry, i.e.
   the user's project list — currently re-reads the whole file on every call and persists every
   mutation as an unsynchronized whole-file read-modify-write with a plain `Files.write`
   (`ProjectRepo.kt:166`). Two concurrent commands can lose an update; a crash mid-write
   corrupts the file. After this phase: load-once in-memory snapshot, `@Synchronized` mutations,
   each persist via write-temp + `ATOMIC_MOVE`. File format and on-disk location unchanged —
   hand-editability preserved with **reflected-on-relaunch** semantics (live hand-edits while
   the launcher runs are deliberately NOT picked up, and are overwritten by the next mutation).
2. **Explicit project home (launcher + shell).** The registry root is CWD-relative
   (`LauncherEnvironment.kt:8` — `Paths.get("../kzen-proj")`), so IDE-run and shell-spawned
   launchers silently see different project sets. After this phase: the launcher accepts
   `--project.home=<path>`; kzen-shell passes `<shell work root>/kzen-proj` when spawning;
   interactive fallback stays `../kzen-proj`. `LauncherEnvironment` is deleted; the path is
   constructor-injected into `ProjectRepo` / `ProjectCreator` / `ArchetypeRepo`.

## Dependencies & coordination

- **Independent of SH2/SH4** (master plan Stage B4). One seam with SH2: both phases touch
  `MainJarProcess.start`/`startProcess` (SH2 for output tee + failure payloads, SH3 for a new
  `programArgs` parameter). The changes are additive and compose in either order; if SH2 landed
  first, re-verify `MainJarProcess.kt` line anchors before editing.
- **SER posture — Jackson stays.** SER4/SER5 removed Jackson from kzen-auto/kzen-shell; the
  launcher's `ProjectRepo` Jackson-3 YAML (`tools.jackson.*`, `ProjectRepo.kt:9–14`, deps at
  `kzen-launcher-jvm/build.gradle.kts:34–37`) is **deliberately kept** — pre-decided in
  `2026-07-16_serialization-improvements.md:76–80` (standard YAML escaping protects existing
  Windows-path registries; the launcher must not gain a kzen-lib dependency). Umbrella
  `kzen/AGENTS.md:74` documents this; SH3 keeps it true.
- **SH5** does the broader docs-to-truth sweep later; SH3 still makes its own AGENTS notes
  (listed in step 7) per the constituent plan's step 2.
- Shell and launcher zips ship together (coordinated release train) — the new spawn arg needs no
  compatibility shim: an old launcher receiving `--project.home=` would ignore it (prefix-scan
  arg parsing), and the new launcher without the arg falls back to `../kzen-proj`.

## Current-state findings (anchors verified 2026-07-19)

### Drift from the constituent plan

- **`ArchetypeRepo` is no longer a YAML registry.** The plan text ("ProjectRepo / ArchetypeRepo
  read-modify-write", `:106–108`) predates the 0.30.0 redesign: the archetype catalogue is now a
  **directory scan** of cached zips — no metadata file at all (`ArchetypeRepo.kt:14–19`; the
  legacy `kzen-archetypes.yaml` is actively deleted at `:117`, pinned by `ArchetypeRepoTest`
  `init cleans legacy metadata…`). Downloads already go to a `.part` sibling +
  `Files.move(…, ATOMIC_MOVE, REPLACE_EXISTING)` with a cross-store fallback
  (`moveIntoPlace`, `ArchetypeRepo.kt:133–142`). **So the durability work applies to
  `ProjectRepo` only**; `ArchetypeRepo` is touched solely for the `LauncherEnvironment` removal
  (its `archetypeHome` constructor default, `:27`).
- **The "artifact-side atomic-move pattern the plan cites" exists in three places** — copy any
  of them: `ArchetypeRepo.moveIntoPlace` (`:133–142`, file-level — the closest model),
  kzen-shell `ArtifactInstaller.swapIntoPlace` (`ArtifactInstaller.kt:205–223`, dir-level), and
  launcher `ProjectCreator.swapIntoPlace` (`ProjectCreator.kt:81–90`, dir-level).

### ProjectRepo — every mutation path and its I/O

`kzen-launcher-jvm/src/main/kotlin/tech/kzen/launcher/server/project/ProjectRepo.kt`:

| Member | Lines | Disk I/O today | Side effects besides the yaml |
|---|---|---|---|
| `read()` (private) | :178–202 | `Files.readAllBytes` per call; missing file → empty map | — |
| `write()` (private) | :156–167 | **plain `Files.write`** (:166); `createDirectories` only when file absent (:162–164) | — |
| `contains` / `list` / `all` / `get` | :39–62 | each calls `read()` → **disk read per request** | `get` error message says "Archetype not found" (:59) — copy-paste bug, fix in passing |
| `add(name, home)` | :66–78 | read + write | none (dup key → `ImmutableMap.builder` IAE; in practice pre-empted by `ProjectCreator.create`'s `check(!Files.exists(home))`) |
| `remove(name)` | :81–85 | read + write | registry-only removal |
| `delete(name)` | :88–105 | read + write | `deleteRecursively` of the project dir **before** the registry write; partial delete (Windows lock) → `IllegalStateException`, entry kept |
| `rename(name, newName)` | :108–127 | read + write | `Files.move` of the project dir **before** the registry write |
| `changeArguments(name, jvmArguments)` | :130–141 | read + write | none |
| companion | :22–35 | — | **`projectMetadata` is a companion-object static** built from `LauncherEnvironment.projectHome` (:26–27) — resolved at class-load against CWD; this static is the injection blocker. `parser` (:29–32, thread-safe `ObjectMapper`) can stay static. |

**No synchronization anywhere.** Callers: `RestHandler` only (`RestHandler.kt:51,59,65,71,81,89`
for mutations; `:28` `all()` for the list endpoint). `contains`/`list`/`get` are currently
uncalled. Ktor serves requests concurrently → the documented lost-update/corruption windows are
real. The shell never reads `kzen-projects.yaml` — it learns each project's location from the
start request's `location` parameter (`ProxyHandler.start`, `ProxyHandler.kt:84–97`), so the
registry file's only consumers are `ProjectRepo` itself and the user's editor.

`RestHandler.listProjects` also does a `Files.exists(path)` per project (`RestHandler.kt:33`) —
that is a deliberate per-request liveness signal ("exists" chip in the UI), **not** registry
I/O; keep it.

**File shape** (observed on disk, written by `unbind` `:170–174` / read by `bindInfo`
`:205–220`; keys `home` + `args`, the latter = `CommonRestApi.projectJvmArgs`,
`CommonRestApi.kt:28`):

```yaml
v28:
  home: "C:\\Users\\ostro\\IdeaProjects\\kzen-proj\\v28"
  args: ""
```

### Project-home resolution today (and on this machine)

- `LauncherEnvironment.kt:7–9`: `object LauncherEnvironment { val projectHome: Path =
  Paths.get("../kzen-proj") }`. References (complete): `ProjectRepo.kt:26`,
  `ProjectCreator.kt:57`, `ArchetypeRepo.kt:27`. Nothing else.
- **IDE/interactive run** (CWD = repo root): resolves to `C:\Users\ostro\IdeaProjects\kzen-proj`
  — exists, 4 projects. This is the "existing dev registries" the fallback must keep serving.
- **Shell-spawned run**: child CWD = the launcher unpack dir (`MainJarProcess.start` overload
  `:26–35` sets `home = location.parent`; dev `launcher.dir=../work/kzen-launcher/kzen-launcher-0.30.0-SNAPSHOT`,
  `kzen-shell.properties:14`; release `launcher.dir=work/kzen-launcher/kzen-launcher-<v>`,
  generated at `kzen-shell/build.gradle.kts:142`) → `../kzen-proj` resolves to
  `<work>/kzen-launcher/kzen-proj`. On this machine:
  `C:\Users\ostro\IdeaProjects\work\kzen-launcher\kzen-proj` — exists, 6 throwaway test
  projects. `C:\Users\ostro\IdeaProjects\work\kzen-proj` also exists (residue of an older
  layout; holds only a `kzen-archetypes` dir) — it becomes the new shell-passed home.
- Fresh homes self-create: `DownloadService.download` does `Files.createDirectories(destination.parent)`
  (`DownloadService.kt:21–22`) and the new `persist` keeps `createDirectories` — no explicit
  mkdir needed anywhere.

### Shell spawn-arg construction today

- `KzenShellContext.start` (`KzenShellContext.kt:76–88`): resolves `properties.path`, finds a
  free port, spawns `mainJarRunner.start(name, jarPath, freePort, "-Xmx64m")` (:87).
- `MainJarRunner.start` (`MainJarRunner.kt:10–30`, two overloads) → `MainJarProcess.start`
  (`MainJarProcess.kt:26–62`) → `startProcess` (`:66–109`) builds the command:
  jvmArgs before `-jar`, then `--server.port=$port` (:89), `--managed.lifeline=stdin` (:94),
  `--parent.pid=…` (:95). **There is no program-args pass-through** — that's the one shell-side
  mechanism to add. Command is a `List<String>` via `ProcessBuilder`, so paths with spaces need
  no quoting (existing `My New Project - …` homes prove this).
- `KzenShellProperties.load` (`KzenShellProperties.kt:37–49`) is the config pattern to extend:
  per-key `--arg` override > `kzen-shell.properties` (CWD) > default; `argValue` helper `:62–66`.
- Launcher arg parsing to mirror: `KzenLauncherConfig` companion prefix-scan (`lastOrNull`
  startsWith), `KzenLauncherMain.kt:106–141` (`readPort` / `readManagedLifeline` /
  `readParentPid`); wired in `buildContext` `:218–246`. `FrontendDevelopment.main` passes IDE
  args straight into `buildContext` (`FrontendDevelopment.kt:17–24`) — `--project.home` works in
  dev runs with zero extra code.

### Test infrastructure (launcher)

`kzen-launcher-jvm/src/test/kotlin/` exists with `ArchetypeRepoTest`, `SecurityGateTest`,
`ProjectNameValidationTest`, `ServerTest` (placeholder). Test deps: `kotlin("test")` only
(`build.gradle.kts:46`) — but Gradle's `testImplementation` extends `implementation`, so
`kotlinx-coroutines-core-jvm` (`:28`), Guava, and Jackson are all on the test classpath. **No
scaffolding needed** beyond copying `ArchetypeRepoTest`'s temp-dir pattern
(`ArchetypeRepoTest.kt:19–37`: `Files.createTempDirectory` + `@AfterTest`
`MoreFiles.deleteRecursively`). It already constructs `ArchetypeRepo` with an explicit
`archetypeHome` (:48), so making that parameter required breaks nothing.

## Pre-resolved questions

1. **Durability scope = `ProjectRepo` only** (drift above). `ArchetypeRepo` already has the
   atomic pattern and no registry file.
2. **The shell-passed value** = `<shell work root>/kzen-proj`, where the work root is the `work/`
   directory the properties already name: release `<install>/work/kzen-proj`, dev
   `../work/kzen-proj` (→ `C:\Users\ostro\IdeaProjects\work\kzen-proj`). **Mechanism: an
   explicit shell config key, no derivation magic** — `project.home` key + `--project.home=` arg
   in `KzenShellProperties` (same pattern as `launcher.dir`), default `work/kzen-proj`
   (CWD-relative, correct for the release layout where CWD = install dir); the checked-in dev
   `kzen-shell.properties` and the generated release config both state it explicitly.
   *Deliberately not* `<launcher.dir>/../kzen-proj`: user projects don't belong inside the
   launcher's artifact area (`work/kzen-launcher/` is a managed cache — the shell prunes stale
   snapshot siblings there at boot), and a parent-of-parent derivation misbehaves under a custom
   `--launcher.dir`. Consequence: the current dev-shell registry at
   `work\kzen-launcher\kzen-proj` (6 throwaway test projects) is orphaned — accepted; recover
   via the launcher's import command (or hand-move the yaml + dirs) if ever wanted. Packaged
   users are unaffected in practice: each shell release unzips to a fresh install dir with a
   fresh `work/` anyway.
3. **Interactive fallback** = `Paths.get("../kzen-proj")`, unchanged, applied in `buildContext`
   when no `--project.home` arg is present — IDE runs keep reading
   `IdeaProjects\kzen-proj` exactly as today.
4. **Repo shape**: `@Volatile private var projects: ImmutableMap<String, ProjectInfo>` snapshot
   loaded once at construction; **`@Synchronized` on mutators only** (reads return the volatile
   immutable snapshot — lock-free, always consistent). Mutators keep the existing
   copy-on-write `ImmutableMap` bodies almost verbatim: build `next`, **persist first, then
   publish** (`projects = next` only after the atomic move succeeds) — a failed persist leaves
   memory and disk consistent at the prior state and surfaces as the existing 500/409 semantics.
5. **Persist** = write bytes to sibling `kzen-projects.yaml.tmp`, then
   `Files.move(tmp, projectMetadata, ATOMIC_MOVE, REPLACE_EXISTING)` with the
   `AtomicMoveNotSupportedException` → plain `REPLACE_EXISTING` fallback, copied from
   `ArchetypeRepo.moveIntoPlace` (`:133–142`). Same-directory sibling ⇒ atomic on NTFS/ext4.
   `createDirectories(parent)` unconditionally before the temp write. Best-effort
   `deleteIfExists` of a stale `.tmp` at construction.
6. **Boot-time load failure fails the boot** (construction throws with the file path in the
   message). Today an unparseable file 500s per-request; after SH3 the only way the file becomes
   unparseable is a bad hand-edit, and loud-at-boot beats the alternative (starting empty would
   let the next mutation persist an empty registry over the user's file). No auto-repair, no
   backup-and-continue.
7. **Reflect-on-relaunch only**: hand-edits while the launcher runs are invisible to it and lost
   on the next mutation. Matches the constituent plan's verification, which only requires
   hand-edit-while-stopped → reflected on relaunch. Say so in a class-header comment and the
   AGENTS note.
8. **Two launcher processes sharing one home stay unsupported** (whole-file last-writer-wins;
   the file is at least always parseable now). Out of scope; noted in AGENTS.
9. **Filesystem side effects stay inside the monitor** in `delete`/`rename` (dir delete / move
   under `@Synchronized`, same operation order as today: filesystem op → persist → publish). A
   slow recursive delete blocks other registry mutations for its duration — accepted at this
   scale (tens of entries, rare ops).
10. **`KzenLauncherConfig` carries `projectHome: Path`** (default `Paths.get("../kzen-proj")`)
    so dev `copy()` flows and logging see it; repos receive it via constructor from
    `buildContext`. `KzenLauncherContext.init()` logs the resolved absolute home (the
    "where did my projects go" papercut wants one loud line; `ArchetypeRepo.init` already logs
    its derived `archetypeHome`, `:51`).

## Step-by-step implementation

### kzen-launcher

**1. `ProjectRepo` rework** (`…/server/project/ProjectRepo.kt`):
- Constructor: `class ProjectRepo(projectHome: Path)`; instance
  `private val projectMetadata = projectHome.resolve("kzen-projects.yaml")` (delete the
  companion static :26–27; keep `parser`, `homeProperty`, `logger` in the companion; add
  `private const val tempSuffix = ".tmp"`).
- Init: best-effort delete stale `.tmp`; `@Volatile private var projects = readFromDisk()`
  (current `read()` body unchanged, renamed; missing file → empty map; parse failure propagates
  with the metadata path wrapped into the message).
- Reads (`contains`/`list`/`all`/`get`): return from the `projects` snapshot, no disk. Fix the
  `get` message to "Project not found" (:59).
- Mutators (`add`/`remove`/`delete`/`rename`/`changeArguments` + `removeAndWrite` helper): mark
  `@Synchronized`; replace `val previous = read()` with `val previous = projects`; replace
  `write(next)` with `persist(next); projects = next`. Keep the existing filesystem side
  effects and their order in `delete`/`rename`.
- `persist(next)`: current `write()` body (Jackson `writeValueAsBytes` of the `unbind`
  transform — byte-identical output format) but writing to the `.tmp` sibling +
  atomic-move-with-fallback; `Files.createDirectories(projectMetadata.toAbsolutePath().parent)`
  unconditionally first.
- Class-header comment: load-once / atomic persist / hand-edits reflected on relaunch only /
  single-process assumption.

**2. `--project.home` parse** (`KzenLauncherMain.kt`):
- `KzenLauncherConfig` companion: `projectHomePrefix = "--project.home="` +
  `fun readProjectHome(args: Array<String>): Path?` (mirror `readParentPid`, `:135–141`;
  `Paths.get(value)`).
- `KzenLauncherConfig`: add `val projectHome: Path = Paths.get("../kzen-proj")`.
- `buildContext` (:218–246): compute
  `val projectHome = KzenLauncherConfig.readProjectHome(args) ?: Paths.get("../kzen-proj")`
  before the repos; pass `archetypeHome = projectHome.resolve("kzen-archetypes")` to
  `ArchetypeRepo`, `projectHome` to `ProjectRepo` and `ProjectCreator`; include
  `projectHome = projectHome` in the `KzenLauncherConfig` construction (:236–242).
- `KzenLauncherContext.init()` (:163–166): log
  `projectHome: <absolute normalized>` (add a logger to the file or log from `ArchetypeRepo`-style
  init; one line).

**3. Constructor injection, `LauncherEnvironment` deleted**:
- `ProjectCreator` (`ProjectCreator.kt:24–26`): add `private val projectHome: Path` parameter;
  `:57` becomes `projectHome.resolve(name)`. (Leave the commented Spring residue at `:3`/`:23`
  for SH5.)
- `ArchetypeRepo` (`:27`): make `archetypeHome: Path` a **required** parameter (drop the
  default — `ArchetypeRepoTest` already passes it explicitly).
- Delete `…/server/environment/LauncherEnvironment.kt` (grep confirms the three usages above are
  the only references; the `environment/` package empties).

### kzen-shell

**4. `KzenShellProperties`** (`KzenShellProperties.kt`): add `projectHome: String` field; keys
`project.home` / `--project.home=` following the `launcher.dir` pattern (:20–29, :40–43);
resolution `argValue(args, projectHomeArg) ?: properties.getProperty(projectHomeKey)
?: "work/kzen-proj"`.

**5. Spawn arg** :
- `MainJarProcess` (`MainJarProcess.kt`): add `programArgs: List<String> = listOf()` to both
  companion `start` overloads (:26–35, :38–62) and `startProcess` (:66–109); append each element
  after the lifeline args (:94–95). `MainJarRunner` (`MainJarRunner.kt:10–30`): thread the same
  optional parameter through both overloads. Project spawns are untouched (default).
- `KzenShellContext.start` (`KzenShellContext.kt:76–88`): build
  `val projectHome = Paths.get(properties.projectHome).toAbsolutePath().normalize()` and pass
  `programArgs = listOf("--project.home=$projectHome")` at :87.

**6. Config files**:
- `kzen-shell/kzen-shell.properties`: add `project.home=../work/kzen-proj` (+ one comment line:
  where the launcher keeps the project registry; passed to the launcher as `--project.home`),
  and `#project.home=work/kzen-proj` beside the commented release pair (:16–17).
- `build.gradle.kts` `generateReleaseConfig` (:131–145): append
  `"project.home=work/kzen-proj\n"` to the `writeText` (:139–142).

### Docs (step 7 — in scope per the constituent plan's step 2)

- `kzen-launcher/AGENTS.md`: **Entry points** table, `KzenLauncherMain` row (:21) — add
  `--project.home=<path>` (project registry root; default `../kzen-proj` relative to CWD;
  kzen-shell passes it explicitly). **Gotchas** — new bullet: registry semantics (in-memory
  load-once at boot; every mutation persists atomically via temp+`ATOMIC_MOVE`; hand-edit while
  stopped → reflected on relaunch; edits while running are ignored and overwritten; unparseable
  file fails the boot loudly; two processes on one home unsupported).
- `kzen-shell/AGENTS.md`: **Key directories** `KzenShellProperties` row (:51) — "Config:
  launcher dir, launcher zip URL, project home, port". **Gotchas** launcher-source bullet (:64)
  — mention the `project.home` key/arg (default `work/kzen-proj`) alongside `launcher.dir`.
  **End-to-end runtime** step 3 (:75) — spawn args now include `--project.home`.
- Umbrella `kzen/AGENTS.md:15` (`../kzen-proj` legacy-directory line): annotate that it is the
  interactive launcher's default project home; shell runs use `work/kzen-proj`. (One clause;
  SH5 owns anything bigger.)
- On landing: tick Phase 3 in `2026-07-16_shell-launcher-improvements.md:15`, strike SH3 in the
  master plan, update the memory index's shell-launcher entry, delete/mark this file per
  `plans/next/README.md`.

## Tests

New `ProjectRepoTest` at
`kzen-launcher-jvm/src/test/kotlin/tech/kzen/launcher/server/project/ProjectRepoTest.kt`
(temp-dir scaffolding copied from `ArchetypeRepoTest`; no build-script changes — kotlin.test +
coroutines already on the test classpath):

1. **Round-trip / relaunch reflection**: `add` two projects (one with `jvmArguments`) → fresh
   `ProjectRepo(projectHome)` sees both, `args` intact; file exists, no `.tmp` residue.
2. **File-shape compatibility (hand-editability)**: write the observed on-disk YAML literal
   (quoted `home` with escaped backslashes + `args`) by hand → fresh repo parses it; then one
   mutation → re-read yields standard shape with the hand-added entry preserved.
3. **Reflect-on-relaunch semantics**: construct repo; overwrite the yaml externally; assert the
   live instance still serves the old snapshot; a fresh instance serves the edit.
4. **Concurrency — no lost updates, file always parseable** (the phase's named test):
   `runBlocking` + `Dispatchers.Default`; seed phase creates real dirs for the entries that will
   be renamed (rename does `Files.move` of the home dir); then a parallel phase of disjoint-key
   ops — ~40 `add`, 10 `rename`, 10 `remove`, 10 `changeArguments` as `launch`ed coroutines →
   `joinAll`. Assert the exact expected key set + args values on the live repo **and** on a
   fresh instance (parseability + completeness); assert no `.tmp` left behind.
5. **Missing file** → empty registry; first `add` creates dirs + file (fresh temp home).
6. **Duplicate add** throws (existing `ImmutableMap.builder` IAE semantics preserved — import
   path's 400).

Run: `./gradlew :kzen-launcher-jvm:test` (also runs the existing three test classes — they must
stay green, especially `ArchetypeRepoTest` against the now-required `archetypeHome` parameter).

## Verification

1. **Builds**: `./gradlew build` in kzen-launcher and kzen-shell (JDK-26 toolchain per umbrella
   rules).
2. **Hand-edit while stopped → reflected on relaunch**: stop the launcher; edit
   `kzen-projects.yaml` (rename a key); relaunch; project list shows the edit.
3. **Two rapid creates both persist**: two quick create commands
   (`GET /rs/command/project/create?name=…&type=…` ×2, or two fast UI creates); both entries in
   the yaml and the list.
4. **Shell-spawned and IDE-run see the same projects**: run `KzenShellMain` (dev properties →
   launcher gets `--project.home=C:\…\IdeaProjects\work\kzen-proj`; boot log line shows it);
   create a project; stop the shell; run `FrontendDevelopment` with IDE program arg
   `--project.home=C:\Users\ostro\IdeaProjects\work\kzen-proj` — same list. (Sequentially, not
   concurrently — see pre-resolved Q8.)
5. **Interactive fallback unchanged**: run `FrontendDevelopment` with no arg → the existing
   `IdeaProjects\kzen-proj` registry (4 projects) lists as before.
6. **Release config**: after `./gradlew dist` in kzen-shell, the generated
   `build/dist-config/kzen-shell.properties` contains `project.home=work/kzen-proj`.

## Risks & gotchas

- **Shell-side registry relocation**: shell-spawned launchers move from the accidental
  `work/kzen-launcher/kzen-proj` to the explicit `work/kzen-proj`. Migration-free by decision —
  this machine's 6 orphaned test projects are recoverable via import; packaged upgrades already
  reset `work/` per install dir. Call it out in the landing notes.
- **Boot-fails-loud on unparseable yaml** is a behavior change (was per-request 500s). Until SH2
  lands, a shell-spawned launcher that dies at boot surfaces poorly (`>> ` console lines only) —
  acceptable: only a bad hand-edit triggers it, and dev-mode runs show the message directly.
- **`MainJarProcess`/`MainJarRunner` signature seam with SH2** — additive param; trivial merge,
  but re-verify anchors if SH2 landed first.
- **Don't migrate the YAML library** — Jackson-3 stays (SER decision; hand-rolled parser would
  corrupt `\d`-bearing Windows paths in existing files).
- **Keep `persist` before `projects = next`** — reversing the order reintroduces silent
  memory/disk divergence on write failure.
- **`rename`'s pre-existing hazard is unchanged**: dir moved, then persist — a persist failure
  leaves the registry pointing at the old home. Not worsened; not fixed (out of scope).
- **`listProjects`' per-entry `Files.exists`** (`RestHandler.kt:33`) is deliberate liveness UI —
  do not "optimize" it away as registry I/O.
- Windows `ATOMIC_MOVE` on a same-directory sibling is supported (NTFS); the cross-store
  fallback mirrors `ArchetypeRepo.moveIntoPlace` and should be kept verbatim.

## Out of scope

- SH2 (exit detection), SH4 (archetype `version` field, upgrade path), SH5 (hygiene: Spring
  residue in `ProjectCreator.kt:3,23`, dead files, 304s, `main`-alias registration).
- Any change to the yaml format, the `home`/`args` keys, or the YAML library.
- Automated migration/merge of existing registries between locations.
- Multi-process registry sharing (file locking, watch service); live reload of hand-edits.
- Client (kzen-launcher-js) changes — none required; the wire DTOs are untouched.
