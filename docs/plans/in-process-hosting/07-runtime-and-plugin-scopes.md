# HS07 — Process-global runtime and plugin scopes

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS01.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E2: runtime, scope identity and test universes.

## Outcome and anchors

kzen-auto KzenAutoContext companion initialization, KzenAutoMain, ClassLoaderUtils and plugin loader helpers.

## Work

1. Refresh global reflection/loader initialization and introduce KzenAutoRuntime initialized before any context. Identical configuration is idempotent; conflicting configuration fails with both configurations identified.
2. Discover deterministic plugins/<name>/*.jar scopes with the application as reserved plugin zero. Pin loaders for process lifetime, parent-first; no unload/reset seam.
3. Resolve implicit directory ids and optional manifest id/version/SPI compatibility metadata. Implement duplicate-id and compatibility boot failures, per-scope malformed-jar diagnostics and a stable descriptor model.
4. Build one ordinary-test universe plus a dedicated forked-JVM task for incompatible boot universes. Use separate modules for Kotlin KSP fixtures.
5. Keep the no-folder standalone path working. Do not activate partially discovered folder contributions until the subsequent E2 sessions wire all consumers.

## Verification and exit criteria

Prove same/conflicting initialization, deterministic scope order, reserved/duplicate ids, malformed scope isolation, compatibility mismatch and multiple contexts using one runtime. Existing context tests remain green. Distinguish global boot errors from a failed individual scope.

## Handoff

E2 is partial. HS08 owns discovery; HS09 owns aggregate loading/compiler/availability; HS10–HS11 complete hosting/SPI seams. E2's external sample acceptance closes in HS22.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in `kzen-auto-jvm` (`tech.kzen.auto.server.context.runtime`) and `kzen-auto-plugin`.

**Runtime.** `KzenAutoRuntime` is the process-global, startup-pinned universe: `initialize(KzenAutoRuntimeConfig)`
pins it once under a lock; an equal (normalized, absolute-path) configuration is a no-op returning the same
instance, a differing one fails with `PluginBootException` naming both configurations. `currentOrDefault()` lets
the first `KzenAutoContext.create` pin the universe implicitly from `KzenAutoRuntimeConfig.default()` (system
property `kzen.plugin.root`, else standalone — the no-folder path is unchanged); `current()` is the named
failure before initialization. No unload or reset seam exists. `KzenAutoMain` now initializes the runtime
before the first context from `--plugin.root=` or, when present, `<moduleRoot|cwd>/plugins`.
`ClassLoaderUtils.applicationClassLoader()` is the reserved plugin-zero loader; `dynamicParentClassLoader()`
returns the runtime's aggregate (HS09).

**Scopes.** `PluginScopeDiscovery.discover(pluginRoot, applicationLoader)` is pure over the filesystem: the
application scope first, then one `PluginScope` per subdirectory of the root in name order over its `*.jar`
files in name order, each with one pinned, parent-first `URLClassLoader`. `PluginManifest` is the optional
`META-INF/kzen/plugin.yaml` (`id`, `version`, `spi`; unknown keys are errors; metadata only, never an
allow-list); the implicit id is the directory name. Per-scope faults (unopenable jar, two manifests, malformed
manifest, empty folder) leave that scope `FAILED` with a named diagnostic and no loader — `requireClassLoader()`
is the named failure — and never hide the others. Universe faults (duplicate ids, the reserved `application`
id, an `spi` other than `PluginSpiVersion.current = 1`) are reported together as one `PluginBootException`.
`PluginScopes` exposes `application`, `folders`, `loadedFolders` and `get(id)`; `PluginScopeId` is the value
type.

**Test universes.** `PluginUniverseBuilder` (test source) compiles Java fixtures with `javax.tools` at test time
into `plugins/<name>/*.jar` under a temp root, with `resource`, `manifest`, `bytes` and `corrupt` entries; no
checked-in fixture jars. Ordinary tests (`PluginScopeDiscoveryTest`, 5 cases) exercise discovery without
touching global state. Boot-level cases that must pin a universe live in
`tech.kzen.auto.server.context.runtime.boot`, excluded from `test` and run by the `pluginUniverseTest` task
(`forkEvery = 1`, wired into `check`): `RuntimeInitializationBootTest` (identical no-op, conflict names both),
`RuntimeDefaultThenConflictBootTest` (implicit default then a conflicting explicit initialize fails),
`RuntimeSharedByContextsBootTest` (three contexts share one runtime including its failed scope). Kotlin/KSP
fixture modules were not needed for this session's cases: the generated-registry path is covered with a
hand-written `ModuleReflection` fixture (HS08).

**Verification.** `./gradlew :kzen-auto-jvm:test --tests "tech.kzen.auto.server.context.runtime.*"` and
`:kzen-auto-jvm:pluginUniverseTest` green (details in the HS08–HS11 as-builts, which share the suites); the full
`./gradlew build` of kzen-auto stays green. Global boot errors (`PluginBootException`) are distinct from a
failed individual scope (`PluginScope.failure`). All new files staged by explicit path.
