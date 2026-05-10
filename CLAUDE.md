# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a **Gradle composite-build umbrella** that has no source of its own. `settings.gradle.kts` pulls in five sibling repositories under `..` via `includeBuild`:

- `../kzen-lib` — context-management core (Kotlin Multiplatform: common/jvm/js)
- `../kzen-auto` — robotic process / office automation (KMP + React JS frontend, Ktor JVM backend, plugin module)
- `../kzen-project` — office automation project (KMP)
- `../kzen-launcher` — UI for selecting / launching a project (KMP)
- `../kzen-shell` — JVM-only desktop shell that boots the launcher and reverse-proxies child processes
- `../kzen-sample-plugin`, `../kzen-proj`, `../kzen-repo` also live alongside but are NOT part of the composite

Cloning just `kzen` is not enough — every sibling listed above must exist at `../<name>` for Gradle to resolve the build. The point of the composite is to let changes in `kzen-lib` flow into `kzen-auto`/`kzen-project`/`kzen-launcher`/`kzen-shell` without going through Maven Local.

## Build & run

All commands assume the working directory is `C:\Users\ostro\IdeaProjects\kzen` (or any of the included builds — Gradle resolves substitutions either way). The wrapper is Gradle 9.3 on Java 25.

```powershell
# Build everything (delegates into all five included builds)
./gradlew build

# Build one included build only
./gradlew :kzen-auto:build
./gradlew :kzen-shell:build

# Run an included build's JVM main jar (after `./gradlew jar` in that build)
java -jar ../kzen-auto/kzen-auto-jvm/build/libs/kzen-auto-jvm-*.jar
java -jar ../kzen-shell/build/libs/kzen-shell-0.29.0.jar
```

### Per-included-build dev loops

Each sibling has its own README; the recurring pattern for `kzen-auto`, `kzen-project`, `kzen-launcher` is two terminals — one for live JVM reload, one for live JS reload:

- **kzen-auto** — `tech.kzen.auto.server.dev.BackendDevelopment` (IDE) + `./gradlew -t :kzen-auto-jvm:classes`; `tech.kzen.auto.server.dev.FrontendDevelopment` (IDE) + `./gradlew -t :kzen-auto-js:build -x test -PjsWatch`
- **kzen-launcher** — `tech.kzen.launcher.server.dev.FrontendDevelopment` (IDE) + `./gradlew -t :kzen-launcher-js:build -x test -PjsWatch`
- **kzen-project** — `KzenProjectApp` (IDE, `--server.port=8081`) + `./gradlew -t :kzen-project-js:run` (proxy on 8080 with webpack-served JS, everything else from 8081)

End-user runtime entry point is `tech.kzen.shell.KzenShellMainKt`, which boots Ktor on `127.0.0.1:8080` and opens the desktop UI.

## Toolchain pins (read these from each `buildSrc/src/main/kotlin/Dependencies.kt`)

All five included builds pin the same JVM/Kotlin baseline; if you bump one, bump all of them:

- Kotlin `2.3.0`, Ktor `3.3.3`, JVM toolchain & target `25`
- Jackson 3.x (`tools.jackson.module:jackson-module-kotlin:3.0.3`) — note the `tools.jackson` group, not the legacy `com.fasterxml.jackson` one
- Kotlin/JS frontends use `org.jetbrains.kotlin-wrappers:kotlin-wrappers-catalog:2025.12.11` (declared in each `settings.gradle.kts` of the JS-bearing builds, exposed as the `kotlinWrappers` version catalog)

Repository order in subprojects matters: `mavenCentral()` first, then JetBrains Space mirrors for kotlin-wrappers / kotlinx-html, then `https://raw.githubusercontent.com/alexoooo/kzen-repo/master/artifacts` for forked artifacts, then `mavenLocal()` last.

## Architecture

### kzen-shell — runtime composition root

`kzen-shell` is the desktop entry point and the only piece a packaged user actually launches. Its job is to **act as a single-port reverse proxy in front of multiple child JVM processes**:

1. `KzenShellMain.main` calls `kzenShellInit` → `KzenShellContext.start()` which downloads & unzips the launcher artifact (currently hard-coded to `file:///C:/Users/ostro/IdeaProjects/kzen-launcher/.../kzen-launcher-0.29.0.zip`) into `../work/kzen-launcher/...` if missing, then spawns it as `main.jar` on a free port.
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

- `kzen-shell` is `0.29.0` (release)
- `kzen-lib`, `kzen-auto`, `kzen-project` are `0.29.0-SNAPSHOT`
- `kzen-launcher` is `0.29.0` (release)

When cutting a release, bump all five `build.gradle.kts` `version =` lines together; the shell's hard-coded launcher zip path in `KzenShellMain.kt` (line ~44) must also be updated.

## Working with this repo from Claude

- Editing source: navigate into the relevant sibling directory (`cd ../kzen-auto` etc.) — the files under `kzen/` itself are only Gradle glue and `.gitignore`d build artifacts.
- The `build/` directory at this root only contains aggregated reports; nothing is compiled here directly.
- Don't run `./gradlew build` casually — the composite drags every sibling through compile + test + KMP JS bundling, which is a multi-minute operation. Prefer `./gradlew :<included-build>:<task>` when iterating.
- Logs from running launcher/project processes land under each sibling's `logs/` directory, not under `kzen/`.