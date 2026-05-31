# Kotlin/JS build speedup — investigation & measurements

**Date:** 2026-05-31 · **Status:** Phase 0 + low-risk Phase 1 applied & measured; bundler/dev-loop decision pending.

## Problem & constraints

The four JS-bearing siblings (`kzen-lib`, `kzen-auto`, `kzen-project`, `kzen-launcher`) bundle Kotlin/JS
with the Kotlin Gradle Plugin's built-in **webpack 5** integration. Both the `-PjsWatch` dev inner loop
and clean/production builds feel slow. Goal: make **both** faster, stay **OS-agnostic** (Windows + Linux),
no version bumps of Kotlin / kotlin-wrappers / MUI.

## Architecture facts that constrain the options

- **Dist contract:** each `<sibling>-jvm` `ProcessResources` copies the JS subproject's
  `jsBrowserDistribution` / `jsBrowserProductionWebpack` output into `resources/static/`; the dev entry
  points (`tech.kzen.<sibling>.server.dev.FrontendDevelopment`) serve
  `build/dist/js/productionExecutable/<module>.js`. Any bundler change must keep that output contract.
- **kzen-auto webpack lock-in:** `kzen-auto-js/.../wrap/material/materialIcons.kt` resolves arbitrary MUI
  icon names at runtime via `js("require.context('@mui/icons-material', ...)")` — a **webpack-only** API
  (no esbuild/Vite/Rollup equivalent). Only 9 dynamic `iconByName(...)` call sites exist, fed by notation
  YAML `icon:` fields → the dynamic name set is build-time enumerable.
- **kzen-launcher is clean** (`@file:JsModule` static icon import — bundler-agnostic); **kzen-project**
  re-bundles `kzen-auto-js` so it inherits the lock-in; **kzen-lib** has no bundle.
- `useCommonJs()` is load-bearing (MUI icons break under ESM resolution).

## Phase 0 measurements (the empirical core)

Method: `kotlin.build.report.output=file` + Gradle `--profile`; from-scratch numbers via
`--rerun-tasks --no-build-cache`. Machine: Windows 11, Gradle 9.5.0, daemon JVM 21, compile toolchain JVM 25.

### From-scratch production build — per-task (Kotlin build report)

**kzen-launcher** (total Kotlin-task time 55.2s; bundle 7.0 MB):

| Task | Time | % |
|---|---|---|
| `jsBrowserProductionWebpack` | **28.48 s** | **51.6%** |
| `compileTestDevelopmentExecutableKotlinJs` (excludable) | 10.48 s | 19.0% |
| `compileProductionExecutableKotlinJs` | 8.58 s | 15.6% |
| `compileKotlinJs` (common klib) | 3.68 s | 6.7% |
| `compileKotlinJs` (js klib) | 3.59 s | 6.5% |

**kzen-auto** (total Kotlin-task time 87.6s; bundle 7.6 MB):

| Task | Time | % |
|---|---|---|
| `jsBrowserProductionWebpack` | **31.79 s** | **36.3%** |
| `compileProductionExecutableKotlinJs` | 20.23 s | 23.1% |
| `compileTestDevelopmentExecutableKotlinJs` (excludable) | 13.53 s | 15.4% |
| `compileKotlinJs` (common klib) | 10.89 s | 12.4% |
| `compileKotlinJs` (js klib) | 10.75 s | 12.3% |

**Conclusion #1 — webpack is a top-tier cost (not ~15% as generic Kotlin/JS reports claim).** It is the
single largest task on both (52% / 36%; 28–32s of pure bundling). So the bundler IS worth attacking — the
opposite of the going-in assumption.

### Clean build (warm Gradle cache)

kzen-launcher clean `build` = 35s, of which **`kotlinNpmInstall` = 27.9s** (yarn reinstall after `clean`
wiped `build/js/node_modules`). Compile + webpack were served from the Gradle build cache (~0.1s each).

**Conclusion #2 — the "clean build" pain is yarn reinstall, a clean-only cost.** node_modules persists
across normal builds, so this is not a per-build concern; don't optimize it.

### Dev inner-loop recompile (1-line source change), kzen-launcher

| Path | Compile time |
|---|---|
| **Production** executable (what the dev loop builds today) | **~18.7 s** — whole-program IR link + DCE, **non-incremental every save** |
| **Development** executable + `kotlin.incremental.js.ir` | **~2.4 s** — klib 0.73s (incremental) + dev-exec link 0.93s |

**Conclusion #3 — the dev loop's bottleneck is the wrong executable.** The current dev loop
(`jsBrowserProductionWebpack` in dev *mode*) compiles the **production** executable, paying full DCE
(~18–20s) on every keystroke-save. The **development** executable skips DCE and (with incremental klibs)
recompiles in ~2.4s — an ~8× dev-loop win. The project uses production-webpack-in-dev-mode per the
AGENTS TODO "remove once browserDevelopmentWebpack works in continuous mode", so the dev bundler path is
the thing that needs fixing — which is exactly where a fast esbuild dev-bundle helps.

**Conclusion #4 — `kotlin.incremental.js.ir` works for klibs but not the executable link.** The
whole-program executable IR link is inherently non-incremental in Kotlin/JS; incremental only helps the
per-module klib compiles. The executable cost is avoided by using the development executable (no DCE), not
by an incremental flag.

## Applied changes (low-risk, reversible) + results

### 1a — esbuild as webpack's minimizer (replaces Terser in production)

`webpack.config.d/webpack-config.js` adds, for production mode only, an `EsbuildPlugin` minimizer; the
`esbuild-loader` npm dep is pinned in each `buildSrc/.../Dependencies.kt` (`esbuildLoaderVersion = "4.3.0"`).
esbuild ships per-platform binaries via npm → stays Windows/Linux agnostic.

| Sibling | webpack (Terser) | webpack (esbuild) | Δ | bundle size |
|---|---|---|---|---|
| kzen-launcher | 28.48 s | **14.86 s** | **−48%** | 7.0 → 7.3 MB (+4%) |
| kzen-auto | 31.79 s | **22.13 s** | **−30%** | 7.6 → 7.9 MB (+4%) |

Applied to: **launcher ✓, auto ✓** (auto's build succeeded — confirms esbuild minify is compatible with
the `require.context` MUI bundle). **kzen-project: pending** (deferred to avoid yarn.lock churn before the
bundler decision). Trade-off: esbuild minifies slightly less aggressively than Terser (+4% bundle size) —
acceptable for halving/thirding the bundle time. Fully reversible (delete the fragment block + dep).

### 1b — `kotlin.incremental.js.ir=true`

Added to all four siblings' `gradle.properties`. Makes the per-module klib compile incremental (verified:
a 1-line change recompiles only the changed file, klib 3.4s → 0.7s). No effect on the executable link.

## Decision pending (the remaining, larger work)

The data reshapes the cost/benefit vs the original plan. Two non-overlapping levers remain:

- **Dev loop:** switch the dev loop to the **development executable** (Conclusion #3) — ~8× win, but the
  dev bundler path (`browserDevelopmentWebpack` continuous mode) needs fixing/replacing. Medium effort,
  touches the daily workflow.
- **Production bundling:** a full **esbuild-as-bundler** swap could shave the remaining ~15–22s webpack
  bundling, but requires the **kzen-auto `require.context` → static icon registry rewrite** (esbuild has no
  `require.context`). High effort/risk; kzen-project unblocks for free afterwards.

The esbuild minifier (1a) already captures a large share of the production win at near-zero risk, so the
full bundler swap is now optional rather than necessary. See the conversation for the go/no-go decision.

## Reversibility

| Change | Revert |
|---|---|
| esbuild minifier | delete the `if (productionMode)` block in each `webpack.config.d/webpack-config.js` + the `esbuild-loader` dep + `esbuildLoaderVersion`; re-run `kotlinUpgradeYarnLock` |
| `kotlin.incremental.js.ir` | remove the line from each `gradle.properties` |
| temporary profiling keys | remove the `# --- TEMPORARY profiling ---` block from each `gradle.properties` (do before committing) |

## TODO before committing

- Remove the temporary `kotlin.build.report.*` profiling block from all four `gradle.properties`.
- Functional smoke: run `FrontendDevelopment` for launcher + auto; confirm UI renders and (auto) dynamic
  MUI icons still resolve under the esbuild-minified bundle.
- Apply 1a to kzen-project (with `kotlinUpgradeYarnLock`) if keeping the minifier approach.
- Commit the regenerated `kotlin-js-store/yarn.lock` files alongside the dep change.
