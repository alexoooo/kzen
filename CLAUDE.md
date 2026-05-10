# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a **Gradle composite-build umbrella** that has no source of its own. `settings.gradle.kts` pulls in seven sibling directories under `..` via `includeBuild` — five with Kotlin source, plus two artifact-only includes:

- `../kzen-lib` — context-management core (Kotlin Multiplatform: common/jvm/js)
- `../kzen-auto` — robotic process / office automation (KMP + React JS frontend, Ktor JVM backend, plugin module)
- `../kzen-project` — office automation project (KMP)
- `../kzen-launcher` — UI for selecting / launching a project (KMP)
- `../kzen-shell` — JVM-only desktop shell that boots the launcher and reverse-proxies child processes
- `../kzen-repo` (forked-artifact mirror, no Kotlin source) and `../kzen-sample-plugin` (Maven sample, no Gradle source) are also `includeBuild`d but contain nothing to bump
- `../kzen-proj` (legacy directory) lives alongside and is NOT in the composite

Cloning just `kzen` is not enough — every sibling listed above must exist at `../<name>` for Gradle to resolve the build. The point of the composite is to let changes in `kzen-lib` flow into `kzen-auto`/`kzen-project`/`kzen-launcher`/`kzen-shell` without going through Maven Local.

## Build & run

All commands assume the working directory is `C:\Users\ostro\IdeaProjects\kzen` (or any of the included builds — Gradle resolves *artifact substitutions* either way; *task addressing* does NOT — see the gotcha below). The wrapper is Gradle 9.2.1 on Java 25.

```powershell
# Build everything (delegates into all five included builds)
./gradlew build

# Build one included build only — root-project tasks of the included build
./gradlew :kzen-auto:build
./gradlew :kzen-shell:build

# Run an included build's JVM main jar (after `./gradlew jar` in that build)
java -jar ../kzen-auto/kzen-auto-jvm/build/libs/kzen-auto-jvm-*.jar
java -jar ../kzen-shell/build/libs/kzen-shell-0.29.1-SNAPSHOT.jar
```

**Gotcha — composite task addressing.** From the umbrella, `./gradlew :kzen-lib:<task>` reaches the *root project* of the included `kzen-lib` build, but the umbrella does NOT flatten included builds' subprojects into its own project tree. So `./gradlew :kzen-lib-common:publishToMavenLocal` from `kzen/` fails with "project 'kzen-lib-common' not found in root project 'kzen'". To run subproject tasks (e.g. `:kzen-lib-common:publishToMavenLocal`, `:kzen-launcher-jvm:jar`), `cd` into the sibling and invoke its own `./gradlew`. The aggregating root-level task (`./gradlew :kzen-lib:publishToMavenLocal`) also fails because the kzen-lib root has no `maven-publish` plugin — only the three subprojects do. Pattern: `cd ../kzen-lib && ./gradlew publishToMavenLocal`.

**Gotcha — Java 25 toolchain vs PATH `java`.** Gradle compiles with the JDK 25 toolchain regardless of your PATH, but `java -jar <built>.jar` uses whatever `java` is first on `PATH` (often Java 8 on this machine, which fails with `UnsupportedClassVersionError: class file version 69.0`). Run with an explicit Java 25: `& "C:/Users/ostro/.jdks/temurin-25.0.3/bin/java" -jar build/libs/...jar` (the user's IntelliJ-managed JDK pool lives at `~/.jdks/`).

**Gotcha — KMP variant-suffix coords route through mavenLocal, not the composite.** kzen-auto-common, kzen-project-common, etc. declare deps with variant-suffix coords (`tech.kzen.lib:kzen-lib-common-jvm` / `-js`) in jvmMain/jsMain alongside the plain root coord (`kzen-lib-common`) in commonMain. Gradle's automatic composite substitution matches by *project name*, so the root coord auto-substitutes to the included `:kzen-lib-common` project, but the variant-suffix coords do not — they resolve from mavenLocal. This means the umbrella's "kzen-lib changes flow into kzen-auto without going through Maven Local" promise only holds for `commonMain`; JVM and JS source sets still consume mavenLocal artifacts, so the cross-sibling version pins (next gotcha) MUST stay aligned with what mavenLocal actually has published. Builds remain green with no klib collisions as long as the versions match — Gradle treats the composite's `:kzen-lib-common` project and mavenLocal's `kzen-lib-common-{jvm,js}` at the same version as the same module.

**Tried-and-failed** workaround: explicit `dependencySubstitution { substitute(module("tech.kzen.lib:kzen-lib-common-jvm")).using(project(":kzen-lib-common")) }` (and similar for `-js`, `kzen-auto-common-{jvm,js}`) in this `settings.gradle.kts` to route variant-suffix coords through the composite as well. CLI builds compile, but IntelliJ flags Provided-scope unresolved-reference red underlines across kzen-auto/kzen-project source. The rules are currently commented out at the top of `settings.gradle.kts`; do not re-enable them without a fix for the IDE side. The cleaner long-term fix is to drop variant-suffix coords entirely in favour of the root coord (let Gradle metadata + KMP plugin pick the variant per source set), but that's an invasive source-side change in each consumer.

**Gotcha — KGP NPM coordination from kzen-auto's perspective.** When running KMP tasks inside kzen-auto (especially `kotlinNpmInstall` and prerequisite `…packageJson` tasks), KGP calls `gradle.includedBuild("kzen-lib")` to aggregate `package.json` files across cross-build deps. With kzen-auto's `settings.gradle.kts` deliberately NOT including kzen-lib (per the IntelliJ run/debug gotcha below), invoking `:kzen-auto:kotlinNpmInstall` from the umbrella fails with `Failed to query the value of task ':kzen-auto:kotlinNpmInstall' property 'packageJsonFiles'. > Included build 'kzen-lib' not found in build 'kzen-auto'.` Workaround: `cd ../kzen-auto && ./gradlew kotlinNpmInstall`. This is a deliberate trade-off — having `includeBuild("../kzen-lib")` in kzen-auto's settings would re-enable umbrella-side KGP NPM coordination, but breaks IntelliJ run/debug of `KzenAutoMain` even when kzen-auto is opened standalone.

**Gotcha — cross-sibling Maven version pins must match what mavenLocal has published.** `kzen-auto/buildSrc/.../Dependencies.kt`'s `kzenLibVersion` and `kzen-project/buildSrc/.../Dependencies.kt`'s `kzenAutoVersion` are at `0.29.1-SNAPSHOT`, matching the source version. Both umbrella *and* standalone sibling builds need this — the variant-suffix coord deps (jvmMain/jsMain) always route through mavenLocal regardless of composite (see previous gotcha), so a mismatch between the pinned version and what mavenLocal holds will fail resolution. After bumping any sibling's `version`, run `:publishToMavenLocal` for its three subprojects (`-common`, `-jvm`, `-js`) before building anything that depends on it, or the next consumer build will fail with "Could not find tech.kzen.lib:kzen-lib-common-jvm:&lt;new-version&gt;".

**Gotcha — IntelliJ run/debug of a KMP-consuming JVM main is incompatible with composite-includes of KMP libraries.** When a KMP module (e.g. `kzen-lib-common`) is reached via `includeBuild` from a consumer that depends on it across a KMP source-set boundary (e.g. `kzen-auto-common/jvmMain` depending on `kzen-lib-common-jvm`), IntelliJ's Gradle Tooling-API model assigns the cross-build source-set output **Provided scope** in the consumer's IDE module. Provided is on the compile classpath but excluded from the runtime classpath, so any IDE-launched JVM main that depends on classes from the included KMP build fails at launch with `NoClassDefFoundError`, even though `./gradlew dependencyInsight --configuration runtimeClasspath` correctly resolves the artifact through the composite. Tried and failed: Application run config + "Add provided to classpath", flipping IntelliJ's "Build and run using" between Gradle and IDEA, Invalidate Caches + Reload, `kotlin.mpp.import.enableKgpDependencyResolution=false` in `gradle.properties`. The bug also reproduces in standalone kzen-auto if its own `settings.gradle.kts` adds `includeBuild("../kzen-lib")` — so don't add it.

**Working policy:**
- For run/debug of `KzenAutoMain`, `BackendDevelopment`, `FrontendDevelopment`, `KzenProjectApp`, `KzenLauncherMain`, `KzenShellMain` — open the relevant sibling (`kzen-auto`, `kzen-project`, `kzen-launcher`, `kzen-shell`) as its OWN IntelliJ project, not via the umbrella. Standalone resolution comes from mavenLocal at the version `Dependencies.kt` asks for; no composite involved on the consumer side, so no Provided-scope mapping.
- The umbrella IntelliJ project is for: cross-sibling reads/greps, multi-sibling refactors driven by IntelliJ, and aggregate CLI builds (`./gradlew build`, `./gradlew :<sibling>:<root-task>`). It is NOT for IDE-launched JVM run/debug of KMP-consuming entry points.
- Do NOT add `includeBuild("../kzen-lib")` (or any other KMP sibling) to a sibling's own `settings.gradle.kts` solely to enable umbrella workflows — it breaks that sibling's own standalone run/debug. Accept the KGP NPM coordination consequence (workaround above).

### Per-included-build dev loops

Each sibling has its own README; the recurring pattern for `kzen-auto`, `kzen-project`, `kzen-launcher` is two terminals — one for live JVM reload, one for live JS reload:

- **kzen-auto** — `tech.kzen.auto.server.dev.BackendDevelopment` (IDE) + `./gradlew -t :kzen-auto-jvm:classes`; `tech.kzen.auto.server.dev.FrontendDevelopment` (IDE) + `./gradlew -t :kzen-auto-js:build -x test -PjsWatch`
- **kzen-launcher** — `tech.kzen.launcher.server.dev.FrontendDevelopment` (IDE) + `./gradlew -t :kzen-launcher-js:build -x test -PjsWatch`
- **kzen-project** — `KzenProjectApp` (IDE, `--server.port=8081`) + `./gradlew -t :kzen-project-js:run` (proxy on 8080 with webpack-served JS, everything else from 8081)

End-user runtime entry point is `tech.kzen.shell.KzenShellMainKt`, which boots Ktor on `127.0.0.1:8080` and opens the desktop UI.

## Toolchain pins (read these from each `buildSrc/src/main/kotlin/Dependencies.kt`)

All five included builds pin the same JVM/Kotlin baseline; if you bump one, bump all of them:

- Kotlin `2.3.21`, Ktor `3.4.3`, JVM toolchain & target `25`
- Jackson 3.x (`tools.jackson.module:jackson-module-kotlin:3.1.3`, `tools.jackson.dataformat:jackson-dataformat-yaml:3.1.3`) — note the `tools.jackson` group, not the legacy `com.fasterxml.jackson` one
- Logback `1.5.32`, kotlinx-coroutines `1.11.0`, Guava `33.6.0-jre`, kotlinx-datetime `0.8.0`, Selenium `4.41.0`, WebDriverManager `6.3.4`, Commons IO `2.22.0`
- Kotlin/JS frontends use `org.jetbrains.kotlin-wrappers:kotlin-wrappers-catalog:2025.12.11` (declared in `settings.gradle.kts` of `kzen-auto` and `kzen-launcher` only — `kzen-project` and `kzen-lib` pull wrappers transitively; exposed as the `kotlinWrappers` version catalog). **Bumping past `2026.2.11` requires migrating away from `kotlin-react-legacy` (removed in wrappers `2026.2.20`)** — `kzen-auto-js` and `kzen-launcher-js` use the legacy `RBuilder`/`RClass`/`RComponent` DSL across many files, so a wrappers upgrade is gated on that React DSL migration.

Repository order in subprojects matters: `mavenCentral()` first, then JetBrains Space mirrors for kotlin-wrappers / kotlinx-html, then `https://raw.githubusercontent.com/alexoooo/kzen-repo/master/artifacts` for forked artifacts, then `mavenLocal()` last.

## Toolchain bumps

When bumping Kotlin (even patch versions like `2.3.0` → `2.3.21`):

- Each JS-bearing sibling (`kzen-lib`, `kzen-auto`, `kzen-project`, `kzen-launcher`) needs `./gradlew kotlinUpgradeYarnLock` run *before* checks/distribution tasks — otherwise `:kotlinStoreYarnLock` fails because resolved transitive JS dependencies shifted. The 4 regenerated `kotlin-js-store/yarn.lock` files must be committed alongside the version bump.
- `:kzen-auto-plugin:publishToMavenLocal` must run before any non-composite consumer picks up the new bytecode — including external plugins compiled against the previous Kotlin and any standalone (per-repo, non-umbrella) build of `kzen-project`. Inside the composite umbrella Gradle substitutes the artifact so the published copy can lag, but in any other context `kzen-auto-plugin` is the gating step.
- Recommended verification order: `kzen-lib` → `kzen-auto` (with `:kzen-auto-plugin:publishToMavenLocal` first) → `kzen-project` ‖ `kzen-launcher` → `kzen-shell`.

## Architecture

### kzen-shell — runtime composition root

`kzen-shell` is the desktop entry point and the only piece a packaged user actually launches. Its job is to **act as a single-port reverse proxy in front of multiple child JVM processes**:

1. `KzenShellMain.main` calls `kzenShellInit` → `KzenShellContext.start()` which downloads & unzips the launcher artifact (currently hard-coded to `file:///C:/Users/ostro/IdeaProjects/kzen-launcher/.../kzen-launcher-0.29.1-SNAPSHOT.zip`) into `../work/kzen-launcher/...` if missing, then spawns it as `main.jar` on a free port.
2. Ktor binds `127.0.0.1:8080` and routes `/<name>/<subpath>` to the child process registered as `<name>` in `ProcessRegistry`. The literal name `main` is rewritten to whichever process was registered with `attributes["location"] == <launcherDir>/main.jar` — i.e. the launcher.
3. `/shell/project/start|stop` and `/shell/project` are the only first-class endpoints; everything else is a generic GET/PUT/POST proxy implemented in `ProxyHandler`.
4. `ProjectRegistry` (a Guava cache) tracks user-launched projects; each project is its own jar started by `MainJarRunner` on its own free port and reverse-proxied through the same name-prefix scheme.

Key invariant: the URL space `/<process-name>/...` is the routing contract — both the launcher and any spawned project must serve their own UIs as if mounted at that prefix.

### Multiplatform structure (kzen-lib / kzen-auto / kzen-project / kzen-launcher)

Each of these is a Gradle multi-module project with a fixed three-module shape:

- `<name>-common` — Kotlin Multiplatform with `commonMain`, `jvmMain`, `jsMain`, `commonTest`. Shared models and APIs.
- `<name>-jvm` — JVM-only Ktor server (uses Netty in 0.29). Exposes `tech.kzen.<name>.server.dev.{BackendDevelopment,FrontendDevelopment}` for IDE-launched dev mode.
- `<name>-js` — Kotlin/JS browser frontend, built with webpack (`-PjsWatch` enables watch mode).

`kzen-auto` additionally has `kzen-auto-plugin` — the SPI module that downstream plugins compile against.

`kzen-shell` is the odd one out: pure JVM, single-module, lives at `src/main/kotlin/tech/kzen/shell/`.

### Versioning

- `kzen-shell`, `kzen-lib`, `kzen-auto`, `kzen-project`, `kzen-launcher` are all `0.29.1-SNAPSHOT`

When cutting a release, bump all five `build.gradle.kts` `version =` lines together; the shell's hard-coded launcher zip path in `KzenShellMain.kt` (line ~44) and the launcher's hard-coded project zip path in `KzenLauncherMain.kt` (line ~99) must also be updated. Note: the launcher and project distribution zips (`kzen-launcher-<v>.zip`, `kzen-project-<v>.zip`) are NOT produced by any Gradle task — they're hand-zipped from the `<sibling>-jvm/build/libs/` outputs (rename the fat jar to `main.jar`, bundle with `dependencies/`).

## Working with this repo from Claude

- Editing source: navigate into the relevant sibling directory (`cd ../kzen-auto` etc.) — the files under `kzen/` itself are only Gradle glue and `.gitignore`d build artifacts.
- The `build/` directory at this root only contains aggregated reports; nothing is compiled here directly.
- Don't run `./gradlew build` casually — the composite drags every sibling through compile + test + KMP JS bundling, which is a multi-minute operation. Prefer `./gradlew :<included-build>:<task>` when the task lives on the included build's *root* project, or `cd ../<sibling> && ./gradlew <task>` when it lives on a *subproject* (the more common case — e.g. `publishToMavenLocal`, `:kzen-launcher-jvm:jar`).
- Logs from running launcher/project processes land under each sibling's `logs/` directory, not under `kzen/`.