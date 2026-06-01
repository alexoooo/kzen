# Kotlin/JS build speedup — webpack → esbuild

**Date:** 2026-05-31 · **Status:** Implemented & verified across kzen-launcher, kzen-auto, kzen-project.

## Problem & constraints

The JS-bearing siblings (`kzen-lib`, `kzen-auto`, `kzen-project`, `kzen-launcher`) bundled their
Kotlin/JS output with the Kotlin Gradle Plugin's built-in **webpack 5** integration. Both the dev inner
loop and clean/production builds were slow. Goal: make **both** faster, stay **OS-agnostic**
(Windows + Linux), no version bumps of Kotlin / kotlin-wrappers / MUI.

## Phase 0 — measurements (the empirical core)

From-scratch production build, per-task (Kotlin build report, `--rerun-tasks --no-build-cache`):

| Task | kzen-launcher | kzen-auto |
|---|---|---|
| **`jsBrowserProductionWebpack`** | **28.5 s (52%)** | **31.8 s (36%)** |
| `compileProductionExecutableKotlinJs` | 8.6 s | 20.2 s |
| `compileKotlinJs` klibs (common + js) | 7.3 s | 21.6 s |
| `compileTestDevelopmentExecutableKotlinJs` (excludable) | 10.5 s | 13.5 s |

Findings that drove the design:
1. **Webpack bundling is the single largest task** (28–32 s) — not the ~15% generic Kotlin/JS guidance
   predicts. So replacing the bundler is worthwhile.
2. **The "clean build" pain is `kotlinNpmInstall`** (≈28 s yarn reinstall after `clean`), a clean-only
   cost — node_modules persists across normal builds, so not worth optimizing.
3. **The dev loop builds the *production* executable** (full DCE, ~18–20 s, non-incremental) on every
   save. The **development** executable (no DCE) recompiles in ~2 s. → the dev bottleneck is the wrong
   executable, not the bundler.
4. `kotlin.incremental.js.ir` makes the per-module klib compile incremental, but the whole-program
   executable IR link is inherently non-incremental — avoided by using the dev executable, not a flag.

## Solution (implemented)

**A. `kotlin.incremental.js.ir=true`** — added to all four siblings' `gradle.properties`. Makes the klib
compile incremental (a 1-line change recompiles only the changed file).

**B. webpack → esbuild bundler.** esbuild bundles the Kotlin/JS per-module CommonJS output directly, in
~1 s vs webpack's ~28–32 s. esbuild ships per-platform native binaries via npm (the `@esbuild/<os>-<arch>`
optional dependency), so it stays Windows/Linux/macOS agnostic. A `jsEsbuildBundle` Gradle `Exec` task
(in each `<sibling>-js/build.gradle.kts`) resolves the OS-correct esbuild binary, bundles the entry
(`build/js/packages/<root>-<module>/kotlin/<root>-<module>.js`) to
`build/dist/js/productionExecutable/<module>.js`, minified in production and unminified for the dev
executable. The `<sibling>-jvm` `ProcessResources` was repointed from the webpack task to this output.
The production webpack tasks are disabled.

The task **`dependsOn` `kotlinNpmInstall`** (alongside the compileSync). esbuild resolves the bare
imports in the Kotlin/JS output (`react`, `react-dom/client`, `lodash`, `@mui/*`, …) from
`build/js/node_modules`, but the Kotlin→JS compile only *emits* `require()` calls — it doesn't need the
modules present, so the compileSync tasks don't depend on `kotlinNpmInstall`. Without this explicit edge,
a clean build can run esbuild against an empty `node_modules` and fail with `Could not resolve "react"`
(and one per remaining bare import). webpack's bundle task carried this dependency implicitly; the swap
had to re-add it.

**C. kzen-auto `require.context` → static icon registry.** `materialIcons.kt` resolved arbitrary MUI icon
names at runtime via `js("require.context('@mui/icons-material', ...)")` — a webpack-only API that bundled
the *entire* icon set (thousands of modules, the bulk of the bundle), and which esbuild cannot express. It
now **deep-imports only the referenced icons** (`@JsModule("@mui/icons-material/<Name>")`) into a static
`iconRegistry` map; unknown names fall back to `Texture` (the pre-require.context behaviour). The ~67
referenced names were scanned from notation YAML `icon:` fields + literal `iconByName/iconType` calls and
verified to exist in the package (a non-existent deep import fails the build). kzen-project and
kzen-auto-common ship no notation icons of their own, so there is no cross-module regression; only external
plugins introducing custom icon names would get Texture.

**Dev loop (the development-executable switch).** The dev loop now bundles the **development** executable
(no DCE) via esbuild. New command (launcher & auto):
```
./gradlew -t :kzen-launcher-js:jsEsbuildBundle -PjsWatch     # was: -t :kzen-launcher-js:build ... -PjsWatch
./gradlew -t :kzen-auto-js:jsEsbuildBundle -PjsWatch
```
`assemble` is deliberately NOT wired to `jsEsbuildBundle` (it builds both executables, whose compileSync
tasks share an output dir → ambiguous esbuild input). kzen-project's dev loop is unchanged — it still uses
webpack-dev-server (`:kzen-project-js:run`), which works because require.context is gone; only its
production bundle moved to esbuild.

Two correctness requirements the `jsEsbuildBundle` task has to satisfy for the watch loop to actually
reflect edits — both were missing in the first cut and silently produced a stale screen:

1. **`devMode` must be read via `providers.gradleProperty("jsWatch").isPresent`, not
   `properties.containsKey("jsWatch")`.** The legacy `project.properties` map is *not* a tracked
   configuration-cache input, so once any non-watch run (e.g. the JVM jar build) stored a cache entry
   with `devMode=false`, every later `-PjsWatch` run reused it — bundling the minified *production*
   executable. The provider API is tracked, so toggling `-PjsWatch` now correctly invalidates the entry
   (`configuration cache cannot be reused because Gradle property 'jsWatch' has changed`).
2. **The task input must be `inputs.dir(<compileSync kotlin dir>)`, not `inputs.file(<entry>)`.** The
   compileSync output is one `.js` per Gradle module (`kotlin-kotlin-stdlib.js`,
   `<root>-<sibling>-common.js`, `kzen-lib-kzen-lib.js`, …); the entry only `require()`s them. With only
   the entry declared, a change in a *dependency* module (e.g. `kzen-auto-common`, `kzen-lib`) lands in a
   sibling file, the entry stays byte-identical, and the task wrongly reports UP-TO-DATE. Declaring the
   whole dir makes any Kotlin change re-bundle. Verified end-to-end under `-t … -PjsWatch`: a same-module
   edit *and* a cross-module `kzen-auto-common` edit both reach the served bundle.

## Results

| | before (webpack) | after (esbuild) |
|---|---|---|
| Production bundling, launcher | 28.5 s | **~1 s** |
| Production bundling, auto | 31.8 s | **~1–2 s** |
| Dev inner-loop rebuild (launcher, 1-line change) | ~18–28 s | **2.95 s** |
| Bundle size, **auto** | 7.9 MB | **2.37 MB (−70%)** |
| Bundle size, project | ~all-icons | 2.37 MB |
| Bundle size, launcher | 7.0 MB | 7.42 MB (+6%) |

(Launcher's size is unchanged in character — it never used require.context, so its size is MUI material +
React, not icons; esbuild minifies marginally less aggressively than Terser. kzen-auto's −70% is the
require.context icon set no longer being bundled.)

Verified: all three production bundles are valid JS (`node --check`); the launcher and kzen-auto servers
boot and serve the esbuild bundle over HTTP (`FrontendDevelopment`, 200 on page + bundle); MUI deep-import
`.default` resolves to real components.

## Files changed

- `*/gradle.properties` (×4) — `kotlin.incremental.js.ir=true`.
- `*/buildSrc/.../Dependencies.kt` — `esbuildVersion = "0.25.12"` (npm `esbuild`).
- `<sibling>-js/build.gradle.kts` (launcher, auto, project) — `npm("esbuild")` dep, `jsEsbuildBundle`
  task, disable webpack tasks.
- `<sibling>-jvm/build.gradle.kts` (launcher, auto, project) — repoint `ProcessResources` to esbuild.
- `kzen-auto-js/.../wrap/material/materialIcons.kt` — require.context → static deep-import registry.
- `kzen-auto-js/webpack.config.d/webpack-config.js` — dropped the require.context `@mui` alias.
- `kzen-auto/docs/js-architecture.md` §5 — updated the (already-stale) icon-resolution gotcha.
- `kotlin-js-store/yarn.lock` (×3) — regenerated for the esbuild dep.

## Follow-ups / notes

- **Definitive icon-render check:** run the e2e harness `cd ../kzen-auto && ./gradlew :kzen-auto-test:selfTest`
  (drives a real browser) to confirm dynamic notation icons render under the esbuild bundle.
- **Update dev-loop docs:** the umbrella + per-sibling AGENTS.md/README list `-t :<module>:build -PjsWatch`
  for launcher/auto — change to `-t :<module>:jsEsbuildBundle -PjsWatch`.
- **Adding a kzen-auto icon** now requires a `materialIcons.kt` registry entry (build fails on a
  non-existent icon; a missing-but-valid name renders as Texture). A Gradle codegen task could auto-scan
  notation YAML to prevent drift — deferred (the set is small/stable and codegen can't capture plugin icons).
- **kzen-project dev loop** remains on webpack-dev-server; could be migrated to an esbuild watch later.

## Reversibility

Per change: remove `kotlin.incremental.js.ir`; re-enable the webpack tasks (delete the `configureEach { enabled = false }`
blocks) and repoint `ProcessResources` back to `jsBrowserProductionWebpack`; revert `materialIcons.kt` and
restore the `@mui` alias. The esbuild dep and `jsEsbuildBundle` task can stay dormant if webpack is restored.
