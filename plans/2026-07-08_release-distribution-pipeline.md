# Release / distribution pipeline — proposal (Phase 4, full)

> **Status: COMPLETE.** Release half executed in the 0.29.1 cut; the remaining item B (download
> atomicity), the `KzenShellProperties` tidy (D), and SPA cache-busting all landed in the 0.30.0
> cleanup (2026-07-10). Only optional offline pre-seeding (C) is deferred — see the status section below.
> Written 2026-07-08 after implementing the *local-dev slice* of the
> shell/launcher/project distribution rework (see "Already landed" below). This document records the
> discoveries from that work and specifies the remaining, release-oriented half so it can be picked
> up later. It refines — and stays subordinate to — Phase 4 of
> `2026-07-06_shell-launcher-project-improvements.md` (that plan's progress tracker remains the
> umbrella index; tick its Phase 4 box only when *this* document is fully executed).

## Status after the 0.29.1 release (2026-07-10)

The release half was executed while cutting **0.29.1**; `docs/RELEASING.md` is now the authoritative
runbook. Outcome per item:

- **A — Release config delivery: DONE.** The shell `dist` bundles a generated release
  `kzen-shell.properties` (`generateReleaseConfig`; version derived from the Gradle `version`, no source
  literal). Minor/mooted leftovers: read *beside the jar* — the generated `kzen.bat`/`kzen-cmd.bat` do
  `cd /d "%~dp0"`, so CWD is already the extract dir; a louder "no launcher source configured" error is a
  nice-to-have.
- **B — `ArtifactRepo` atomicity / verification / stream hygiene: DONE (0.30.0 cleanup).** The shell
  `ArtifactRepo` now stages the download+extract in a sibling `<path>.staging/`, verifies `main.jar`,
  drops `archive.zip`, then atomically swaps into place (so a crash mid-extract never leaves a
  half-populated target, and presence keys on `main.jar` — self-healing even for `https`). Streams are
  `use {}`-wrapped and the mis-scoped logger is fixed. The launcher's `ProjectCreator` gained the missing
  zip-slip guard, closes its `ZipInputStream`, and creates atomically via staging; `ArchetypeRepo.install`
  downloads to a `.part` file then atomic-moves. (TLS-verification hardening stays with source-plan
  Phase 3.)
- **C — Runnable / offline-first: core DONE and exceeded; offline pre-seeding deferred by decision.** The
  `.bat` launchers shipped, and we went *beyond* the plan by bundling a full **Temurin JDK**
  (`ProvisionAdoptiumJdk` — the plan only suggested guarding for a PATH JVM), so no local Java is needed.
  **Pre-seeding the launcher zip under `work/`** for a fully-offline first run is **deferred** (first boot
  downloads launcher+project from GitHub; the JDK is already bundled, so this only saves the first
  network round-trip and costs archive size). `kzen.sh`/Linux + macOS bundles remain deferred (Windows-only).
- **D — Config cleanup + docs: DONE.** `docs/RELEASING.md` written; umbrella + sibling `AGENTS.md`
  gotchas corrected; stale `application.yaml` **deleted (2026-07-10)**. `KzenShellProperties` is now
  non-nullable (`path`/`download` required, with a fail-fast `error()` in `load()` when the launcher
  source is unconfigured — subsuming item A's "louder error" nicety) and the misleading `port` default
  is reconciled to `8080`.

**Discovered during the release — SPA cache-busting: DONE (0.30.0 cleanup).** The frontends served
`static/<name>-js.js` at a fixed path with no cache directives, so a returning user on the same origin
got stale JS after an upgrade (looked like a release defect; was browser cache). Fixed by setting
`Cache-Control: no-cache` on the `static/` route in `KzenAutoMain` + `KzenLauncherMain` (kzen-project
inherits kzen-auto's server), forcing revalidation so an upgraded build is picked up on the next load.
Content-hashed immutable filenames were considered and deferred to a code note: switch to them only if
these frontends are ever served over the internet / a CDN (loopback-only today). See agent memory
`project-launcher-spa-cache-busting-gap`.

**Net remaining:** only optional **offline pre-seeding** (C), deferred by decision. Item **B** (download
atomicity), the **`KzenShellProperties`** tidy (D), and **SPA cache-busting** all landed in the 0.30.0
cleanup. Phase 4's release half is complete.

## Why

A release currently requires editing machine-specific absolute paths in two source files and
hand-assembling distribution zips (rename the fat/thin jar to `main.jar`, bundle `dependencies/`,
zip). `git clone` + documented steps must instead produce a working `kzen-<v>.zip` on any machine,
and a developer must be able to smoke-test the full stack without manual choreography. The
local-dev slice solved the *developer loop*; this document covers the *release*.

## Already landed (local-dev slice, 2026-07-08)

Implemented and building green (companion plan file: the approved slice plan). In short:

- **`dist` Zip tasks** in `kzen-launcher-jvm`, `kzen-project-jvm`, and `kzen-shell` build files —
  reuse the existing `copyDependencies` + `Class-Path` thin-jar and emit
  `build/dist/<name>-<version>.zip` as `main.jar` (launcher/project; the shell keeps its jar name)
  + `dependencies/` at the root. Not wired into `build`.
- **Externalized artifact sources, each owned by the right component.** The shell owns only the
  *launcher* source: `KzenShellProperties.load(args)` resolves it via **`--arg` >
  `kzen-shell.properties` (CWD)**, with no source-level default and no version literal in source
  (the version lives only in the config path/URL). The **launcher owns the *project archetype***
  (next bullet). Both machine-path blocks in `KzenShellMain.kt` and `KzenLauncherMain.kt` are gone.
- **A git-tracked `kzen-shell/kzen-shell.properties`** with a **relative** path to the launcher `dist`
  zip (no machine strings; never packaged, since it lives at the repo root not under `build/`).
- **Launcher-owned archetype config (candidate list).** The project-archetype source lives entirely
  in kzen-launcher — a bundled classpath resource `kzen-launcher.properties` listing candidates tried
  in order: `../kzen-project/.../dist/*.zip` (standalone run), `../../../kzen-project/.../dist/*.zip`
  (kzen-shell-spawned run, from the deeper `work/` CWD), then the GitHub release URL. A local path is
  used only if it resolves; otherwise the URL. **The shell has zero knowledge of archetypes.** This
  works because the two dev run-locations sit at fixed, known offsets from the shared parent dir, and
  the config is a classpath resource (readable regardless of working directory).
- **`file://` staleness fix (gates 1 & 2).** `ArtifactRepo.downloadIfAbsent` wipes-and-re-extracts
  when the source scheme is `file` (guarded to dirs that look like our own extraction);
  `ArchetypeRepo.init` removes-then-reinstalls a `file://` archetype. `https` sources stay
  once-only.

Confirmed decisions: **final releases → GitHub releases** (already the case); **SNAPSHOT dev →
local filesystem** (no SNAPSHOT uploads). **kzen-repo is a Maven *library* mirror, not the home for
distribution zips** — they were removed from it in 2018 ("hosted as github user content"). Do not
revive kzen-repo for zips.

## Key discoveries (design constraints for the rest)

1. **Three dir-existence "staleness" gates**, not one:
   - Shell → launcher: `ArtifactRepo.downloadIfAbsent` early-returns on `Files.exists(path)`.
   - Launcher → archetype: `ArchetypeRepo.init` skips when the name is already in the YAML index.
   - Archetype → project instance: `ProjectCreator.create`'s `check(!Files.exists(home))` — this
     one is **correct and kept**; a project is a saved document, frozen at creation.
   Gates 1 & 2 are handled for `file://` in the slice; the release half must keep them robust (see
   atomicity below).
2. **The universal on-disk contract is `main.jar` + `dependencies/` next to it**, driven by
   `java -jar main.jar` resolving the thin-jar manifest `Class-Path: dependencies/…`. Every producer
   already emits this shape into `build/libs/`; `dist` only repackages it. `MainJarProcess` launches
   children with `<java.home>/bin/java` (same JDK as the shell), so no PATH assumptions.
3. **`ProjectCreator` branches on artifact extension** (`ProjectCreator.kt:55-67`): `.zip` → unzip
   verbatim (must already contain `main.jar` + `dependencies/`); `.jar` → copy to `main.jar` (only
   self-contained for a *fat* jar). The `.zip` path is the one in use; keep emitting zips.
4. **The launcher's CWD is unstable** (its work dir, `../work/kzen-launcher/<v>/`) but its offset
   from the shared parent dir is *fixed and known*, so a candidate list of relative paths (one per
   run-location) plus a URL fallback — read from a bundled classpath resource — lets the launcher own
   its archetype source with **no shell involvement** (see "Already landed"). Phase 5's
   shell→launcher `--project.home=<absolute>` arg is unrelated to this.

## Remaining work (this proposal)

### A. Release config delivery (no source defaults, no version in source)

**Decision:** the version and artifact URLs live **only in `kzen-shell.properties`**, never in
source. There is deliberately no source-level default and no generated version constant — a
generated-`version.properties` pipeline was tried and rejected as over-complex for the payoff. A
release therefore *is* a config file with GitHub URLs; the open question is only how that release
config reaches a packaged shell:

- Simplest: **bundle a release `kzen-shell.properties`** into the shell `dist` zip (item C), with the
  three keys pointing at the GitHub-release URLs for the version being cut. The shell reads it from
  the CWD/next-to-jar on first run. A release then edits one config file (the version appears once,
  in those URLs) plus the five Gradle `version =` lines.
- Alternative: keep the shell zip config-free and require the user/installer to drop a
  `kzen-shell.properties` beside the jar. More flexible, less turnkey.
- Either way, extend `readPropertiesFile()` to also look **beside the jar** (not just CWD), so a
  packaged run from any working directory finds its config. (The slice reads CWD only.)
- Consider a clear startup error when no launcher source is configured (today `path!!` NPEs), so a
  missing/mislocated config fails loudly rather than cryptically.

### B. `ArtifactRepo` atomicity + verification + stream hygiene

Currently `downloadIfAbsent` extracts straight into the target and leaves `archive.zip` behind; a
crash mid-extract leaves a half-populated dir. Harden:

- Download/extract into a `<path>.staging/` dir, **verify `main.jar` exists**, then
  `Files.move(staging, path, ATOMIC_MOVE)` (fall back to a non-atomic recursive move across stores).
- Presence check becomes "dir exists **and** contains `main.jar`" so historical half-states
  self-heal even for `https` sources.
- Wrap the `ZipInputStream`/`OutputStream` in `use {}` (they currently leak on exception,
  `ArtifactRepo.kt` extract loop). Delete the leftover `archive.zip` after extract, or extract from
  the staging copy and drop the whole staging dir.
- Fix the mis-scoped logger (`LoggerFactory.getLogger(DownloadService::class.java)` in
  `ArtifactRepo`).
- Apply the same staging+verify to the launcher's `ArchetypeRepo`/`ProjectCreator` unzip
  (`ProjectCreator.unzip` also lacks a zip-slip guard — cross-reference source-plan Phase 3, which
  owns the security hardening).

### C. Shell distribution: runnable, offline-first

The slice's shell `dist` emits jar + `dependencies/` only. Make `kzen-<v>.zip` a real end-user
artifact:

- Add `kzen.bat` / `kzen.sh` launchers (`java -jar kzen-shell-<v>.jar`) into the zip root. Guard for
  a modern JVM on PATH (or note jpackage/bundled-JRE as a future item — source-plan §"out of
  scope").
- **Pre-seed the launcher** zip under `work/` inside the shell zip so first run works offline
  (source plan judged the size worth it). The shell already extracts `work/kzen-launcher/<v>/` on
  first boot; seeding just means the `file://`/download step is skipped when the dir is present.
- The shell zip should carry (or the installer should drop beside the jar) a release
  `kzen-shell.properties` with the launcher's GitHub URL — there is no built-in default (see item A).
  Pre-seeding the launcher zip under `work/` makes first run offline regardless.

### D. Config surface cleanup + docs

- Make `KzenShellProperties` non-nullable with real defaults; drop the vestigial `port: Int = 80`.
- Delete the stale Spring-era `kzen-launcher-jvm/src/main/resources/application.yaml` (unused; still
  carries an old machine path).
- Rewrite the umbrella `AGENTS.md` "Versioning"/release-checklist section (it currently documents
  the hand process) and delete the now-wrong "hard-coded launcher/project zip path" gotchas in the
  sibling `AGENTS.md` files.

## Verification (release half)

- **Fresh-machine simulation:** rename `work/`, run the packaged `kzen-<v>.zip` **offline** with the
  seeded launcher → boots to the launcher UI.
- **Self-heal:** kill the shell mid-extract → next boot completes cleanly (atomic staging).
- **Release dry-run:** bump the version, run the three `dist` tasks, publish to GitHub releases, then
  run the packaged shell with its release `kzen-shell.properties` (item A) → it downloads the launcher
  from GitHub, the launcher falls through its candidate list to the GitHub project URL, and the full
  stack boots. The dry-run follows only the rewritten checklist (no source edits).

## Ordering note

This is source-plan **Phase 4**, and the slice already pulled its dev-facing half forward ahead of
Phases 2–3. The release half (this document) is independent of Phases 2–3 except item B's overlap
with Phase 3's zip-slip/TLS hardening — coordinate there. Recommended execution order within this
doc: A → B → C → D.
