# Releasing kzen

This is the operator + AI-agent runbook for cutting a kzen release. It is designed to be executed
**with an AI agent** driving the mechanical steps (edits, Gradle, `gh`, file copies) while the operator
handles the irreducibly-human gates (deciding the version, authorizing pushes, creating releases,
eyeballing the running app). Every phase is tagged **[AI]** or **[OPERATOR]**; the gate table at the
end is the quick index of where *you* act.

> Worked example throughout uses `0.29.1` (the first release cut with this runbook). Substitute your
> `<VERSION>` where shown.

## What a release produces

**Two end-user app archives** (both attached to *one* GitHub release on the umbrella repo), plus the
launcher and project-archetype zips they pull at runtime, plus optionally the Maven libraries:

| Artifact | Built by | Published to |
|----------|----------|--------------|
| `kzen-<v>.zip` — turnkey **Windows** app: jars + bundled Temurin JDK + `.bat` launchers (no local Java needed) | `:kzen-shell:distWindows` | `github.com/alexoooo/kzen` Releases |
| `kzen-<v>-jars.zip` — JVM app for a bring-your-own-JDK user (jars only) | `:kzen-shell:distJars` | same `kzen` release |
| `kzen-launcher-<v>.zip` | `:kzen-launcher-jvm:dist` | `github.com/alexoooo/kzen-launcher` Releases |
| `kzen-project-<v>.zip` (project archetype) | `:kzen-project-jvm:dist` | `github.com/alexoooo/kzen-project` Releases |
| `tech.kzen.lib:*`, `tech.kzen.auto:*` (incl. `kzen-auto-plugin`) | `publishToMavenLocal` | `kzen-repo` mirror (for plugin authors) |

The launcher/project zips are the universal **`main.jar` + `dependencies/`** contract (a thin jar whose
manifest `Class-Path` points at the sibling `dependencies/`). The **shell** app archives instead nest
their content under a top-level `kzen-<v>/` folder and name the shell jar `kzen-<v>.jar`; the full
Windows zip adds a `jdk/` folder and the two launchers. Layouts:

```
kzen-<v>-jars.zip →  kzen-<v>/{ kzen-<v>.jar, dependencies/, kzen-shell.properties }
kzen-<v>.zip      →  kzen-<v>/{ kzen-<v>.jar, dependencies/, kzen-shell.properties, jdk/, kzen.bat, kzen-cmd.bat }
```

The **shell** is the composition root — it downloads the launcher zip, runs it as a child on a free port
(with the bundled JDK, via `java.home`), and reverse-proxies it on `127.0.0.1:8080`; the launcher in
turn downloads the project archetype zip. The wiring that makes a released app find its pieces:

- The shell reads **`kzen-shell.properties`** (`launcher.zip` URL) from its working dir. Both app
  archives **bundle** a release copy pointing at the launcher's GitHub URL (generated from `version`
  with `-SNAPSHOT` stripped, so the URL is always the release form).
- The bundled `jdk/` is fetched automatically by `:distWindows` — the `ProvisionAdoptiumJdk` buildSrc
  task pulls the latest Temurin GA for the compile-target major from the Adoptium API, verifies its
  SHA-256, and caches it under `~/.gradle/caches/kzen-adoptium-jdk` (re-runs don't re-download).
- The launcher reads a **bundled classpath resource** `kzen-launcher.properties` whose
  `archetype.project.3` is the project's GitHub URL; local candidates `.1`/`.2` only resolve on a dev
  tree, so on an end-user machine `.3` wins automatically.

## Prerequisites [OPERATOR]

- **JDK 26** installed at `~/.jdks/temurin-26.*` (the Gradle toolchain target; `auto-download=false`).
- The Gradle daemon runs on **Java 25** — set `JAVA_HOME` to `~/.jdks/temurin-25.*` for CLI Gradle, or
  buildSrc fails with "Unresolved reference kotlinVersion".
- **`gh` CLI authenticated**: run `gh auth login` once (interactive — in a Claude Code session type
  `! gh auth login`). Confirm with `gh auth status`.
- All sibling repos present at `..\<name>` and working trees clean.

## Version model

Dev version is `X.Y.Z-SNAPSHOT`; a release **drops `-SNAPSHOT`** (→ `X.Y.Z`), is tagged **`vX.Y.Z`**, and
development then **reopens at the next `-SNAPSHOT`** (`X.Y.(Z+1)-SNAPSHOT`). The five siblings are a
**coordinated release train** — always bump them together (see `docs/CODING_STANDARDS.md`). GitHub
release URLs and tags use the bare version (`v0.29.1`, `kzen-launcher-0.29.1.zip`); Gradle/Maven
coordinates carry `-SNAPSHOT` only in dev.

The complete version-bearing surface is **8 locations** (nothing else needs editing to *release*):

| # | File | Symbol |
|---|------|--------|
| 1 | `kzen-lib\build.gradle.kts` | `version` (subprojects block) |
| 2 | `kzen-auto\build.gradle.kts` | `version` (allprojects block) |
| 3 | `kzen-auto\buildSrc\src\main\kotlin\Dependencies.kt` | `kzenLibVersion` |
| 4 | `kzen-project\build.gradle.kts` | `version` |
| 5 | `kzen-project\buildSrc\src\main\kotlin\Dependencies.kt` | `kzenLibVersion`, `kzenAutoVersion` |
| 6 | `kzen-launcher\build.gradle.kts` | `version` |
| 7 | `kzen-shell\build.gradle.kts` | `version` |

Two **`*.properties`** files also carry version strings but only the *dev-facing* candidates and a
*next-release* URL — they are **not** touched to release the current version (they are already prepared
for it), only when reopening development (Phase 8):
`kzen-launcher\...\resources\kzen-launcher.properties` and `kzen-shell\kzen-shell.properties`.

---

## Phase 0 — Decide & prepare [OPERATOR]

1. **Decide `<VERSION>`** (e.g. `0.29.1`) and the **next dev version** (e.g. `0.29.2-SNAPSHOT`). The base
   of the current `-SNAPSHOT` is the natural release; confirm the GitHub URLs already baked into the two
   `.properties` files target it (`v<VERSION>`).
2. `gh auth status` green (else `! gh auth login`).
3. `git -C ..\<repo> status` clean for kzen, kzen-lib, kzen-auto, kzen-project, kzen-launcher,
   kzen-shell, kzen-repo.

## Phase 1 — Bump versions [AI → OPERATOR reviews]

Edit the 8 locations above from `<VERSION>-SNAPSHOT` → `<VERSION>`. **[OPERATOR]** eyeball the diff — a
stray edit here silently breaks resolution.

## Phase 2 — Publish libraries to mavenLocal [AI]

Required before any dist build: KMP variant-suffix coords (`kzen-lib-common-jvm/-js`,
`kzen-auto-common-*`) always resolve from **mavenLocal**, and dist tasks run standalone (`cd` into the
sibling — the umbrella does not flatten subprojects). Order matters:

```powershell
cd ..\kzen-lib  ; .\gradlew publishToMavenLocal
cd ..\kzen-auto ; .\gradlew :kzen-auto-plugin:publishToMavenLocal   # gating step for downstream bytecode
cd ..\kzen-auto ; .\gradlew publishToMavenLocal
```

## Phase 3 — Build the dist zips [AI]

```powershell
cd ..\kzen-project  ; .\gradlew :kzen-project-jvm:dist   # -> kzen-project-jvm\build\dist\kzen-project-<v>.zip
cd ..\kzen-launcher ; .\gradlew :kzen-launcher-jvm:dist  # -> kzen-launcher-jvm\build\dist\kzen-launcher-<v>.zip
cd ..\kzen-shell    ; .\gradlew distJars distWindows     # -> build\dist\kzen-<v>-jars.zip + kzen-<v>.zip
```

`:distWindows` downloads + SHA-256-verifies the Temurin JDK on first run (~180 MB, then cached); the
resulting `kzen-<v>.zip` is ~170 MB.

## Phase 4 — Local artifact sanity [AI]

Cheap structural + standalone checks before anything is pushed:

- **launcher/project zips**: unzip and assert **`main.jar` + `dependencies\`**; the project zip also
  carries **`src\main\resources\notation\`**.
- **shell app zips**: both nest under `kzen-<VERSION>\`; the jars zip = `kzen-<VERSION>.jar` +
  `dependencies\` + `kzen-shell.properties` (whose `launcher.zip` is the `v<VERSION>` GitHub URL); the
  full zip additionally = `jdk\` + `kzen.bat` + `kzen-cmd.bat`. Confirm `jdk\bin\java.exe -version`
  reports the expected Temurin major, and the bats reference `jdk\bin\...` and `kzen-<VERSION>.jar`.
- Boot each `main.jar` (and the shell's `kzen-<VERSION>.jar`) standalone on a free port with **JDK 26**
  and confirm it serves HTTP:

```powershell
& "$env:USERPROFILE\.jdks\temurin-26.0.1\bin\java" -jar main.jar --server.port=8091
# then in another shell: curl http://127.0.0.1:8091/   (expect a response, not connection-refused)
```

Full end-to-end verification is Phase 6 (needs the GitHub uploads).

## Phase 5 — Commit, tag, publish to GitHub [OPERATOR authorizes → AI runs]

1. **Commit** the bump in each sibling and the umbrella docs. Stage **by explicit path only** (never
   `git add -A` — the tree may hold unrelated WIP):

   ```powershell
   git -C ..\kzen-lib      commit -m "release <VERSION>" -- build.gradle.kts
   git -C ..\kzen-auto     commit -m "release <VERSION>" -- build.gradle.kts buildSrc/src/main/kotlin/Dependencies.kt
   git -C ..\kzen-project  commit -m "release <VERSION>" -- build.gradle.kts buildSrc/src/main/kotlin/Dependencies.kt
   git -C ..\kzen-launcher commit -m "release <VERSION>" -- build.gradle.kts
   git -C ..\kzen-shell    commit -m "release <VERSION>" -- build.gradle.kts
   ```
   **[OPERATOR]** authorize `git push origin master` for each sibling (and the umbrella's docs branch).

2. **Release notes.** [AI] drafts grouped highlights (Script / Report / … / Work-in-progress — see any
   prior release body for the format) from commits across the siblings since the last release, into a
   `notes.md`. **[OPERATOR]** curates/approves the wording before it ships.

3. **Releases with assets** — `gh release create` makes the tag, release, and asset upload in one shot.
   The umbrella `kzen` release carries **both** app archives and the curated notes:

   ```powershell
   gh release create v<VERSION> --repo alexoooo/kzen-launcher --title "v<VERSION>" --notes "kzen <VERSION>" `
     ..\kzen-launcher\kzen-launcher-jvm\build\dist\kzen-launcher-<VERSION>.zip
   gh release create v<VERSION> --repo alexoooo/kzen-project  --title "v<VERSION>" --notes "kzen <VERSION>" `
     ..\kzen-project\kzen-project-jvm\build\dist\kzen-project-<VERSION>.zip
   gh release create v<VERSION> --repo alexoooo/kzen          --title "v<VERSION>" --notes-file notes.md `
     ..\kzen-shell\build\dist\kzen-<VERSION>.zip ..\kzen-shell\build\dist\kzen-<VERSION>-jars.zip
   ```
   **[OPERATOR]** approve each. *(Order tip: create the launcher & project releases before the shell
   release so their download URLs are live when someone runs the app.)*

   **Large-asset note:** the full `kzen-<VERSION>.zip` is ~170 MB and can overrun a foreground upload
   timeout. Upload it in the background (or expect a multi-minute upload). If `gh release create` times
   out mid-upload, the tag + release + any smaller asset are already created — finish the missing one with
   `gh release upload v<VERSION> --repo alexoooo/kzen --clobber ..\kzen-shell\build\dist\kzen-<VERSION>.zip`.

4. **Provenance tags** on the code repos with no downloadable asset:

   ```powershell
   gh release create v<VERSION> --repo alexoooo/kzen-lib   --title "v<VERSION>" --notes "kzen <VERSION>"
   gh release create v<VERSION> --repo alexoooo/kzen-auto  --title "v<VERSION>" --notes "kzen <VERSION>"
   gh release create v<VERSION> --repo alexoooo/kzen-shell --title "v<VERSION>" --notes "kzen <VERSION>"
   ```

## Phase 6 — Post-upload release dry-run [AI + OPERATOR]

The authoritative check — proves the artifacts work from GitHub, not the dev tree, **using only the
bundled JDK** (no Java on PATH). From a fresh scratch dir, unzip `kzen-<VERSION>.zip` and run the console
launcher from the extracted `kzen-<VERSION>\` folder:

```powershell
.\kzen-<VERSION>\kzen-cmd.bat     # or double-click kzen.bat for the windowless launch
```

Expected chain: shell reads the bundled `kzen-shell.properties` → downloads `kzen-launcher-<VERSION>.zip`
from GitHub into `work/` → runs the launcher (via the bundled `jdk\`) → launcher's baked
`archetype.project.3` downloads `kzen-project-<VERSION>.zip` from GitHub → the stack serves the launcher
UI on `127.0.0.1:8080`. **[OPERATOR]** open it, create a project, confirm the project process launches.
*(Headless option: drive `/shell/project` / `/shell/project/start` via curl instead of a browser.)*

> **First upgrade from a pre-0.30.0 build may need one hard-refresh.** The SPA route now sends
> `Cache-Control: no-cache`, so the browser revalidates the bundle each load and picks up an upgraded
> build automatically. A browser that cached the bundle from an *older* (pre-fix) build on this origin
> (e.g. `localhost:8080`) may serve it once more — symptom: an old archetype/label, or a create-time
> `Archetype not found`, while the server is correct (`curl …/main/rs/query/archetype` returns the right
> data). Fix: **Ctrl+Shift+R** once. Verify server-side headlessly before assuming a release defect.

## Phase 7 — Publish Maven libs to the mirror [AI copies/stages → OPERATOR authorizes push]

Only if the release includes the libraries (for external plugin authors). `kzen-repo` is a flat Maven-2
tree under `artifacts\` served raw from GitHub; entries are `publishToMavenLocal` outputs copied verbatim.

- Copy the new `<VERSION>` version dirs from `~\.m2\repository\tech\kzen\lib\**` and `…\auto\**` into the
  matching `..\kzen-repo\artifacts\tech\kzen\{lib,auto}\<module>\<VERSION>\`. The mirror tracks a **fixed
  module set** — copy exactly those already present, at the new version:
  - **lib (6):** `kzen-lib-common`, `-common-js`, `-common-jvm`, `kzen-lib-js`, `-js-js`, `kzen-lib-jvm`
  - **auto (7):** `kzen-auto-common`, `-common-js`, `-common-jvm`, `kzen-auto-js`, `-js-js`, `kzen-auto-jvm`, `kzen-auto-plugin`
  - **Do NOT** add `kzen-lib-reflect-ksp` (KSP processor — never mirrored; the sample plugin resolves
    only `kzen-auto-plugin`) or the deprecated `-common-metadata` (stopped at 0.21.0). Each dir has
    `.jar`, `.pom`, `.module`, `-sources.jar`, and for JS `.klib` (the KMP root also a
    `-kotlin-tooling-metadata.json`) — file sets already match the existing mirrored versions.
- **`maven-metadata-local.xml` is gitignored in `kzen-repo`** (`.gitignore`) — never committed; the
  mirror resolves purely by exact-version dirs (kzen deps are exact-pinned, no metadata lookup). There is
  **nothing to refresh** — skip it. (`publishToMavenLocal` regenerates a local copy; leave it ignored.)
- Stage the new `<VERSION>` dirs by explicit path and commit **per sibling**, matching the mirror's
  convention — `kzen-lib <VERSION>` then `kzen-auto <VERSION>` — then **[OPERATOR]** authorize push. (The
  LF→CRLF warnings on `.module`/`.pom`/`.json` are the usual autocrlf and harmless; jars/klibs are binary
  and copied byte-faithfully — spot-check one `md5sum` against `~\.m2` if unsure.)

Verify: from a clean local Maven cache, `kzen-sample-plugin` (`pom.xml` `kzen.version=<VERSION>`) resolves
`tech.kzen.auto:kzen-auto-plugin:<VERSION>` from the mirror.

## Phase 8 — Reopen development [AI → OPERATOR authorizes]

1. Bump the 8 version locations to the **next dev version** (`0.29.2-SNAPSHOT`).
2. Roll the dev-facing `.properties` strings the release didn't touch:
   - `kzen-launcher\...\resources\kzen-launcher.properties`: `archetype.project.1`/`.2` → next
     `-SNAPSHOT` project zip name; `.3` → next release URL (`v0.29.2/kzen-project-0.29.2.zip`).
   - `kzen-shell\kzen-shell.properties`: active `launcher.zip`/`.dir` → next `-SNAPSHOT`; the commented
     release lines → next `v0.29.2/…-0.29.2`.
3. Re-`publishToMavenLocal` kzen-lib + kzen-auto at the new `-SNAPSHOT` so dev builds resolve.
4. Commit "start 0.29.2-SNAPSHOT", **[OPERATOR]** authorize push.

---

## Operator gates (quick index)

| # | Gate | Phase |
|---|------|-------|
| 1 | Decide `<VERSION>` + next `-SNAPSHOT` | 0 |
| 2 | `gh auth login` (once) | 0 |
| 3 | Review the 8 bumped version lines | 1 |
| 4 | Curate/approve the release notes | 5 |
| 5 | Authorize `git push` for each sibling + umbrella | 5 |
| 6 | Approve each `gh release create` | 5 |
| 7 | Confirm the dry-run boots the app UI | 6 |
| 8 | Authorize `kzen-repo` mirror push | 7 |
| 9 | Authorize the `0.29.2-SNAPSHOT` reopen push | 8 |

Everything else — edits, `publishToMavenLocal`, `distJars`/`distWindows` (incl. the JDK download), artifact
checks, running `gh`, mirror copies — is AI-driven.

## Known limitations / future smoothing

Not blockers:

- **Windows only.** `:distWindows` is the only OS bundle. Linux (`.tar.gz` + `.sh` launchers) and macOS
  are future sibling tasks over the same `ProvisionAdoptiumJdk` + shared `distributionContent` (the
  `operatingSystem`/`architecture`/archive-type parameters already exist for it).
- **Not offline-first.** The JDK is bundled (so the app runs with no local Java), but first run still
  downloads the launcher and project-archetype zips from GitHub — network is needed the first time.
  Pre-seeding those under `work/` inside the zip would make first boot fully offline.

Resolved in 0.30.0 (formerly listed here): the runtime `ArtifactRepo`/`ArchetypeRepo` download+extract is
now atomically staged and verified (self-healing on a mid-extract crash), and the SPA route sends
`Cache-Control: no-cache` so an upgraded bundle is picked up without a hard-refresh.
