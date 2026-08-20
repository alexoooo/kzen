# kzen umbrella — AI agent guide

Guidance for AI agents working in the kzen composite-build umbrella.

## Repository purpose

This is a **Gradle composite-build umbrella** with no source of its own. `settings.gradle.kts` pulls in seven sibling directories under `..` via `includeBuild` — five with Kotlin source, plus two artifact-only includes:

- `../kzen-lib` — context-management core + execution abstractions (Logic/Task/Trace, `ObjectStableMapper`) (Kotlin Multiplatform: common/jvm/js) → [docs](../kzen-lib/AGENTS.md), [architecture concept map](../kzen-lib/docs/architecture.md)
- `../kzen-auto` — robotic process / office automation (KMP + React JS frontend, Ktor JVM backend, plugin module, blackbox e2e self-test subproject) → [docs](../kzen-auto/AGENTS.md), [architecture](../kzen-auto/docs/architecture.md)
- `../kzen-project` — office automation project (KMP) → [docs](../kzen-project/AGENTS.md)
- `../kzen-launcher` — UI for selecting / launching a project (KMP) → [docs](../kzen-launcher/AGENTS.md)
- `../kzen-shell` — JVM-only desktop shell that boots the launcher and reverse-proxies child processes → [docs](../kzen-shell/AGENTS.md)
- `../kzen-repo` (forked-artifact mirror, no Kotlin source) and `../kzen-sample-plugin` (Maven sample, no Gradle source) are also `includeBuild`d but contain nothing to bump
- `../kzen-proj` lives alongside and is NOT in the composite — it is the interactive launcher's default project home (`--project.home`, CWD-relative `../kzen-proj`); a kzen-shell-spawned launcher is pointed at `work/kzen-proj` instead

Cloning just `kzen` is not enough — every sibling listed above must exist at `../<name>` for Gradle to resolve the build. The point of the composite is to let changes in `kzen-lib` flow into `kzen-auto`/`kzen-project`/`kzen-launcher`/`kzen-shell` without going through Maven Local.

## Coding standards

Before finalizing any code change, review it against @docs/CODING_STANDARDS.md.

## Build & run

**Working directory matters.** Gradle resolves *artifact substitutions* from the umbrella or from any included build alike, but *task addressing* does not: anything that actually compiles or tests must be invoked from the sibling's own directory. The wrapper is Gradle 9.6.1; the Kotlin/Java toolchain compiles to Java 26, and the Gradle JVM (`JAVA_HOME` / IDE Gradle JVM) must be ≥ 25 — buildSrc targets Java 25 bytecode. JDK 25 and 26 both work as the Gradle JVM (verified with `--no-daemon help` on temurin-26.0.2).

```powershell
# Build one sibling for real — from ITS OWN directory (see the build-addressing gotcha below)
cd ../kzen-auto;   ./gradlew build
cd ../kzen-lib;    ./gradlew build

# kzen-shell is single-module, so its root task IS the whole build and works from the umbrella
./gradlew :kzen-shell:build

# Run an included build's JVM main jar (after `./gradlew jar` in that build)
java -jar ../kzen-auto/kzen-auto-jvm/build/libs/kzen-auto-jvm-*.jar
java -jar ../kzen-shell/build/libs/kzen-shell-*.jar
```

**Gotcha — there is no "build everything" from the umbrella, and the two obvious attempts both exit 0 without compiling anything.**

- `./gradlew build` from `kzen/` — the umbrella root has no `build.gradle.kts`, so no `build` task exists; task-name abbreviation silently matches `:buildEnvironment`, which prints a dependency report and reports `BUILD SUCCESSFUL`. Nothing compiles, no test runs — it *looks* like a green full build.
- `./gradlew :kzen-auto:build` from `kzen/` — reaches only the included build's *root project* lifecycle tasks (which hold no source); the `-common`/`-jvm`/`-js` subprojects are never reached. Same for `:kzen-lib:`, `:kzen-project:`, `:kzen-launcher:`. `:kzen-shell:build` is the one honest case (single-module).

Do this instead: `cd ../<sibling> && ./gradlew build`. To cover several siblings, run them in sequence; there is no aggregate.

**Gotcha — composite task addressing.** The umbrella does not flatten included builds' subprojects into its own project tree, so `./gradlew :kzen-lib-common:publishToMavenLocal` from `kzen/` fails with "project not found". Subproject tasks (`:kzen-lib-common:publishToMavenLocal`, `:kzen-launcher-jvm:jar`) must run from the sibling's own directory. The aggregating root-level form (`./gradlew :kzen-lib:publishToMavenLocal`) also fails — the kzen-lib root has no `maven-publish` plugin, only its four subprojects do. Pattern: `cd ../kzen-lib && ./gradlew publishToMavenLocal`.

**Gotcha — Java 26 toolchain vs PATH `java`.** Gradle compiles with the JDK 26 toolchain (auto-detected from `~/.jdks`; `org.gradle.java.installations.auto-download=false`, so JDK 26 must be installed) regardless of PATH, but `java -jar <built>.jar` uses whatever `java` is first on `PATH` (often Java 8 on this machine → `UnsupportedClassVersionError: class file version 70.0`). Run with an explicit Java 26: `& "C:/Users/ostro/.jdks/temurin-26.0.2/bin/java" -jar build/libs/...jar` — **check `~/.jdks` for the actual patch version before copying that path**, it moves with each JDK update and a stale one fails as a bare `No such file or directory` (exit 127), not as a Java error. A Gradle JVM of ≤ 24 fails to resolve `:buildSrc` (its bytecode targets 25) — the symptom is the misleading `e: build.gradle.kts:2: Unresolved reference 'kotlinVersion'` at configuration time (buildSrc's constants can't load on the older JVM, so every constant the root script reads is "unresolved"); fix the JVM, not the script.

**Gotcha — KMP variant-suffix coords route through mavenLocal, not the composite.** kzen-auto-common, kzen-project-common, etc. declare deps with variant-suffix coords (`tech.kzen.lib:kzen-lib-common-jvm` / `-js`) in jvmMain/jsMain alongside the plain root coord (`kzen-lib-common`) in commonMain. Automatic composite substitution matches by *project name*, so the root coord substitutes to the included project, but the variant-suffix coords resolve from mavenLocal. So the composite's "changes flow without Maven Local" promise only holds for `commonMain`; jvmMain/jsMain consume mavenLocal artifacts, and the cross-sibling version pins (`kzenLibVersion` in kzen-auto's `Dependencies.kt`, `kzenLibVersion`/`kzenAutoVersion` in kzen-project's) must match what mavenLocal actually has published. After bumping any sibling's `version`, run `publishToMavenLocal` for all its subprojects (kzen-lib: `-common`, `-jvm`, `-js`, **`-reflect-ksp`** — kzen-project consumes the KSP processor artifact too) before building any consumer. Builds stay green with no klib collisions as long as versions match — Gradle treats the composite project and the same-version mavenLocal artifact as the same module.

Do not add explicit `dependencySubstitution` rules to route the variant-suffix coords through the composite — CLI builds compile but IntelliJ flags Provided-scope unresolved-reference errors across kzen-auto/kzen-project source. The cleaner long-term fix is dropping variant-suffix coords in consumers in favour of the root coord (Gradle metadata + KMP plugin pick the variant per source set), an invasive source-side change.

**Gotcha — KGP NPM coordination from kzen-auto's perspective.** `:kzen-auto:kotlinNpmInstall` from the umbrella fails (`Included build 'kzen-lib' not found in build 'kzen-auto'`) because kzen-auto's `settings.gradle.kts` deliberately does not `includeBuild("../kzen-lib")` — see the IntelliJ gotcha below. Workaround: `cd ../kzen-auto && ./gradlew kotlinNpmInstall`.

**Gotcha — IntelliJ run/debug of a KMP-consuming JVM main is incompatible with composite-includes of KMP libraries.** When a KMP module is reached via `includeBuild` across a KMP source-set boundary (e.g. `kzen-auto-common/jvmMain` → `kzen-lib-common-jvm`), IntelliJ's Gradle model assigns the cross-build source-set output **Provided scope** — on the compile classpath but excluded from the runtime classpath — so any IDE-launched JVM main depending on the included build fails at launch with `NoClassDefFoundError`, even though Gradle itself resolves the composite correctly. No IDE-side workaround is known (run-config tweaks, cache invalidation, and `kotlin.mpp.import.enableKgpDependencyResolution=false` were all tried). The bug also reproduces in standalone kzen-auto if its own `settings.gradle.kts` adds `includeBuild("../kzen-lib")` — so don't add it.

**Working policy:**
- For run/debug of `KzenAutoMain`, `BackendDevelopment`, `FrontendDevelopment`, `KzenProjectMain`, `KzenLauncherMain`, `KzenShellMain` — open the relevant sibling as its OWN IntelliJ project, not via the umbrella. Standalone resolution comes from mavenLocal at the version `Dependencies.kt` asks for; no composite involved, so no Provided-scope mapping.
- The umbrella IntelliJ project is for cross-sibling reads/greps, multi-sibling refactors, and composite dependency resolution. It is not for IDE-launched run/debug, and not where you run a real build — compile/test from each sibling's own directory.
- Do not add `includeBuild("../kzen-lib")` (or any other KMP sibling) to a sibling's own `settings.gradle.kts` solely to enable umbrella workflows — it breaks that sibling's standalone run/debug. Accept the KGP NPM coordination consequence (workaround above).

### Per-included-build dev loops

Each sibling's AGENTS.md documents its own dev loop; the recurring pattern for `kzen-auto`, `kzen-project`, `kzen-launcher` is two terminals — one for live JVM reload, one for live JS reload. See [`../kzen-auto/AGENTS.md`](../kzen-auto/AGENTS.md) (also covers the opt-in `:kzen-auto-test:selfTest` e2e suite), [`../kzen-launcher/AGENTS.md`](../kzen-launcher/AGENTS.md), [`../kzen-project/AGENTS.md`](../kzen-project/AGENTS.md).

End-user runtime entry point is `tech.kzen.shell.KzenShellMainKt`, which boots Ktor on `127.0.0.1:8080` and opens the desktop UI.

## Toolchain pins (read them from each `buildSrc/src/main/kotlin/Dependencies.kt`)

Kotlin and the JVM baseline are pinned identically in all five included builds — bump them together. The remaining pins live only in the sibling(s) that use the library; the values below are a convenience snapshot, `Dependencies.kt` is authoritative.

- Kotlin `2.4.0`, KSP (`com.google.devtools.ksp`) `2.3.9` (kzen-lib, kzen-auto, kzen-project), Ktor `3.5.1` (kzen-auto, kzen-launcher, kzen-shell), JVM toolchain & target `26`
- Jackson 3.x **YAML only** (`tools.jackson.core:jackson-databind:3.2.0` + `tools.jackson.dataformat:jackson-dataformat-yaml:3.2.0`) — used solely by kzen-launcher's `ProjectRepo` for the `kzen-projects.yaml` registry; note the `tools.jackson` group, not legacy `com.fasterxml.jackson`. kzen-auto and kzen-shell are Jackson-free.
- kotlinx-serialization-json `1.9.0` (`kotlin("plugin.serialization")` version = `kotlinVersion`) — the single structured-wire JSON codec; every server serves JSON via kotlinx (Ktor `json()` ContentNegotiation). Applied in the `-common` modules of kzen-launcher, kzen-lib, and kzen-auto, plus kzen-auto-jvm/-js, kzen-launcher-js, and kzen-shell.
- Logback `1.5.37`, kotlinx-coroutines `1.11.0`, Guava `33.6.0-jre`, kotlinx-datetime `0.8.0`, Selenium `4.46.0`, WebDriverManager `6.3.4`, Commons IO `2.22.0`, JUnit Jupiter `6.1.1`, zero-allocation-hashing `2026.0`
- Kotlin/JS frontends use `org.jetbrains.kotlin-wrappers:kotlin-wrappers-catalog` at **`2026.7.1`**, declared in the `settings.gradle.kts` of kzen-auto, kzen-launcher, and kzen-project (kzen-lib pulls wrappers transitively); exposed as the `kotlinWrappers` version catalog. Two load-bearing constraints: `useCommonJs()` must stay (`@mui/icons-material` is CommonJS-packaged and breaks under ESM resolution), and the launcher's `muiIconsVersion` must match the `@mui/material` version the wrappers BOM resolves (currently `9.2.0` — re-check `kzen-launcher/kotlin-js-store/yarn.lock` on any wrappers bump). The `wrap/React.kt` migration template and the full 2026.x breakage catalogue live in [`../kzen-auto/docs/js-architecture.md`](../kzen-auto/docs/js-architecture.md) § React DSL wrapper layer.

Repository order in the KMP consumers' subprojects (kzen-auto, kzen-launcher, kzen-project) matters: `mavenCentral()` first, then JetBrains Space mirrors for kotlin-wrappers / kotlinx-html, then `https://raw.githubusercontent.com/alexoooo/kzen-repo/master/artifacts` for forked artifacts, then `mavenLocal()` last. kzen-lib and kzen-shell use only `mavenCentral()` + `mavenLocal()`.

## Toolchain bumps

When bumping Kotlin (even patch versions):

- Each JS-bearing sibling (`kzen-lib`, `kzen-auto`, `kzen-project`, `kzen-launcher`) needs `./gradlew kotlinUpgradeYarnLock` run *before* checks/distribution tasks — otherwise `:kotlinStoreYarnLock` fails because resolved transitive JS dependencies shifted. Commit the 4 regenerated `kotlin-js-store/yarn.lock` files alongside the bump.
- `:kzen-auto-plugin:publishToMavenLocal` must run before any non-composite consumer picks up the new bytecode — external plugins compiled against the previous Kotlin, and any standalone (non-umbrella) build of `kzen-project`.
- Recommended verification order: `kzen-lib` → `kzen-auto` (with `:kzen-auto-plugin:publishToMavenLocal` first) → `kzen-project` ‖ `kzen-launcher` → `kzen-shell`.
- Run `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest"` explicitly — the canary for `FormulaStep`'s type inference, which reads the compiler's inferred `KType` via kotlin-reflect (see `../kzen-auto/AGENTS.md` Gotchas). An inference regression surfaces as a wrong inferred type, not a hard build failure.
- Re-validate the **npm supply-chain pin block** in each JS sibling's `-js` build script (see below) — a stale pin can hold a package *below* what the newer KGP wants.

### npm supply-chain alerts (Dependabot)

Every npm Dependabot alert on these repos comes from `kotlin-js-store/yarn.lock`, which is KGP's own JS toolchain — karma/mocha (browser tests) plus webpack/webpack-dev-server/source-map-loader (bundling). **None of it ships**: kzen-auto, kzen-project and kzen-launcher bundle with esbuild, and kzen-lib publishes a library. Dependabot nevertheless labels every one `scope: runtime`, because scope is read from a `package.json` manifest and only the lockfile is committed — the real dev/runtime split lives in the generated `build/js/packages/*/package.json`. Judge reachability from those, not from the alert's scope field.

**Refreshing the lock actually resolves most advisories, but `kotlinUpgradeYarnLock` alone will not do it.** That task only copies `build/js/yarn.lock` over the stored one, and `kotlinRestoreYarnLock` seeds `build/js/` from the stored lock beforehand (`YarnPluginApplier` guards it with `onlyIf { lockFile.exists() }`); yarn 1 then keeps every locked version that still satisfies its range. The lock is *reconciled*, never *upgraded*. To force a fresh resolve of every range, delete both copies first — from the sibling's own directory:

```powershell
Remove-Item kotlin-js-store/yarn.lock
Remove-Item build/js/yarn.lock -ErrorAction SilentlyContinue
./gradlew kotlinNpmInstall
./gradlew kotlinUpgradeYarnLock
```

This also floats caret-ranged *runtime* packages (`react`, `@emotion/*`, `@popperjs/core`), so smoke-test a frontend afterwards. `@mui/material` is an exact pin from the wrappers BOM and will not move. **`jsEsbuildBundle` declares only the Kotlin compileSync dir as its input, not `node_modules`** — so after an npm-only change it stays UP-TO-DATE and a plain `build` re-jars the *old* bundle. Force it (`./gradlew :<sibling>-js:jsEsbuildBundle --rerun`) before smoke-testing, or the test is a false green. The same blind spot applies to `jsBrowserTest`: `--rerun` it, or karma reports UP-TO-DATE without touching the refreshed tree.

What a refresh cannot reach is pinned in the `=== npm supply-chain pins ===` block in each `-js` build script: `versions.webpack` / `versions.webpackDevServer` for KGP's own exact devDependency pins, and `yarn.resolution(...)` for transitives whose parent pins a vulnerable range (`serialize-javascript`, `diff`, `uuid`). Verify CJS API compatibility against the *actual* consumer before adding a resolution — forcing a major can break it silently. `brace-expansion` is the standing counter-example: its advisories carry a flat `<= 5.0.7` range that numerically sweeps in the fixed 2.x maintenance line, and 5.x cannot be forced because its CJS build exports a named `expand` where minimatch/glob call the module as a bare function.

## Architecture

### kzen-shell — runtime composition root

`kzen-shell` is the desktop entry point and the only piece a packaged user actually launches: a single-port reverse proxy (Ktor on `127.0.0.1:8080`) that downloads and spawns the launcher and user-launched projects as child JVM processes, routing `/<process-name>/<subpath>` to each. Key invariant: the URL space `/<process-name>/...` is the routing contract — the launcher and any spawned project must serve their UIs as if mounted at that prefix. Full architecture: [`../kzen-shell/AGENTS.md`](../kzen-shell/AGENTS.md).

### Multiplatform structure (kzen-lib / kzen-auto / kzen-project / kzen-launcher)

Each is a Gradle multi-module project built around a common three-module core:

- `<name>-common` — Kotlin Multiplatform with `commonMain`, `jvmMain`, `jsMain`, `commonTest`. Shared models and APIs.
- `<name>-jvm` — JVM-only Ktor server. Exposes `tech.kzen.<name>.server.dev.{BackendDevelopment,FrontendDevelopment}` for IDE-launched dev mode.
- `<name>-js` — Kotlin/JS browser frontend. Bundled with **esbuild** (`jsEsbuildBundle` task) for kzen-auto, kzen-launcher, and kzen-project's production bundle; the production webpack tasks are disabled. `-PjsWatch` builds the development executable (no DCE) unminified for the dev loop. kzen-project's dev loop still uses webpack-dev-server (`:kzen-project-js:run`).

Beyond the core: `kzen-lib` also has `kzen-lib-reflect-ksp` (the `@Reflect` KSP processor, a real publish target consumed by kzen-project); `kzen-auto` also has `kzen-auto-plugin` (the SPI module downstream plugins compile against) and `kzen-auto-test` (e2e self-test harness).

`kzen-shell` is the odd one out: pure JVM, single-module, lives at `src/main/kotlin/tech/kzen/shell/`.

For foundational concepts shared across all KMP siblings (the Notation → Definition → Instance three-layer model, CQRS, suffix conventions), see [`../kzen-lib/docs/architecture.md`](../kzen-lib/docs/architecture.md).

### Versioning & releases

- `kzen-shell`, `kzen-lib`, `kzen-auto`, `kzen-project`, `kzen-launcher` all share a single version, a **coordinated release train** — bump them together, and only on explicit request (CC-14 in [`docs/CODING_STANDARDS.md`](docs/CODING_STANDARDS.md)).
- **Cutting a release is a documented step-by-step procedure: [`docs/RELEASING.md`](docs/RELEASING.md)** — the version-bump surface, `publishToMavenLocal` order, `dist` builds (including the `main.jar` + `dependencies/` zip layout), GitHub releases via `gh`, the Maven mirror, and where the operator must act. Follow it rather than improvising.
- Artifact sources are externalized to config (no machine paths in source): the shell's launcher source is `kzen-shell.properties` (`launcher.zip`, `--launcher.zip=` override); the launcher's project-archetype candidates are `kzen-launcher-jvm/src/main/resources/kzen-launcher.properties` (`archetype.project.N`). `file://` sources are re-acquired on every boot (automatic dev pickup); `https` release sources install once.
- Every app identifies its running build: a `generateBuildInfo` task in each `-jvm` build (plus kzen-shell's) writes a module-specific `<module>-build.properties` (`version=` + ISO-8601 `timestamp=`) into a generated-resources srcDir, re-stamped every build. The names are module-specific because kzen-project-jvm carries kzen-auto-jvm.jar on its runtime classpath — a shared name would collide. `BuildInfo.load` (one copy in kzen-auto `server.context`, deliberately duplicated in kzen-launcher + kzen-shell, which share no module) threads `"<version> (built <timestamp>)"` into a `<meta name="kzen-build">` tag that each frontend surfaces as the logo hover; kzen-shell has no UI and logs it at startup instead. (Gradle Kotlin DSL note: inside a `build.gradle.kts`, a fully-qualified `java.time.*` reference fails to compile — `java` resolves to the Java plugin's extension accessor — so `import` the classes and use simple names.)

## Working with this repo from AI agents

Before modifying an included sibling repository, read that sibling's `AGENTS.md` completely. Do not assume that an agent started from the umbrella has automatically loaded a sibling's guide; treat it as required local context.

### File safety — never delete files outside your work stream

Treat the working tree as the user's. Never delete, move, or overwrite a file that isn't an explicit part of the task you were asked to do — even if it is uncommitted, untracked, or `.gitignore`d. "Not in a commit" does not mean "disposable": the user keeps real working documents and run artifacts in the tree before committing (e.g. user-authored Scripts/Reports and screenshots under a sibling's `notation/main/`, often `git add`ed but not yet committed).

- Scope every deletion to paths *you* created this session, or to known build-output dirs (`build/`, JS klib/incremental caches); verify the exact resolved path before any `Remove-Item -Recurse` / `rm -rf`.
- A `clean` targets the narrowest build subdir — never a `src/`, `resources/`, or any other working tree.
- If a stray or in-the-way file seems to block the task, surface it and ask — do not clear it unilaterally.

Other working notes:

- Editing source: navigate into the relevant sibling directory (`cd ../kzen-auto` etc.) — the files under `kzen/` itself are only Gradle glue and `.gitignore`d build artifacts.
- Build from the sibling you changed: `cd ../<sibling> && ./gradlew build` (multi-minute — scope it to what you touched, e.g. `./gradlew :kzen-auto-js:compileKotlinJs` for a fast JS gate).
- Logs from running launcher/project processes land under each sibling's `logs/` directory, not under `kzen/`.
- The user's own dev servers are usually running — kzen-auto on `127.0.0.1:8080` (`BackendDevelopment`) and often an interactive tester on `18081`. Never kill, restart, or reuse them: boot your own instance on a spare port for any verification (per-sibling recipes in each AGENTS.md's Headless verification section), and before stopping any JVM verify its command line is one you started. If a port you need is occupied, surface the owning PID and ask — a squatter may well be the user's own process.

### Stage new files you create

When a task has you create a **new** file (source, test, notation, doc), `git add` it as soon as it's written — **stage only, never commit** unless the user explicitly asks. This keeps new files visible in the changeset rather than lingering as untracked `??` entries (edited tracked files already show in the diff and need no action).

- Stage by **explicit path**, never `git add -A` / `git add .` / `git add <dir>` — a blanket add sweeps up the user's unrelated untracked and WIP files (the tree routinely holds staged-then-deleted `AD` entries and untracked working documents — see *File safety*). Run `git status --short` first and add only the paths *you* created this session.
- The file belongs to the **sibling repo it lives in**, not the umbrella — target that repo: `git -C ../kzen-auto add -- <path>`.

### Audit directory convention

The `docs/audit/` directory holds long-form analysis reports (e.g. build-warning classifications). Layout rules:

- **One markdown file per audit**, named `yyyy-mm-dd_<topic>_<model>-<effort>.md`. The date is the *capture* date, not the cleanup/edit date. The model token is either dotted-version style (`4.7` for Opus 4.7) or codename style (`fable`); the effort tier is the reasoning effort, `x`-prefixed where applicable — e.g. `4.7-xhigh`, `fable-high`. Do not guess the slug from training-time defaults; if uncertain, ask once.
- **Reusable scripts live in `docs/audit/script/`**, not at the audit root. They resolve I/O paths via `Split-Path -Parent $PSScriptRoot` so outputs land in `docs/audit/` regardless of script depth.
- **Intermediate data is transient.** Scripts capture into `docs/audit/raw/` and parse into `docs/audit/parsed.tsv`; both must be deleted as the last step of finalizing an audit. Only the MD persists.

### Plans directory convention

Long-form work plans live in `docs/plans/` (when the user says "the plan" without a path, look here). Tiers: `docs/plans/<yyyy-mm-dd>_*.md` are the live constituent plans, and the session ledger in `docs/plans/2026-07-25_master-plan.md` is the sequencing source of truth — start there; each ledger row points at its constituent plan. `docs/plans/next/` holds execution-ready elaborations of specific phases (lifecycle rules in its README: when a phase lands, tick the constituent plan's tracker AND the master ledger, then delete the elaboration file — never the constituent plan). `docs/plans/sprint-*/` are closed archives: only each sprint's README survives as the as-built record; plan bodies are recoverable via `git show`.
