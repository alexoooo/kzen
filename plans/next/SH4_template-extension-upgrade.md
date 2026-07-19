# SH4 — kzen-project template: extension point + project upgrade path — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from
> `../2026-07-16_shell-launcher-improvements.md` Phase 4 (the sole design authority — decisions
> there are pre-made and are NOT re-litigated here; this document elaborates them into an
> execution-ready plan verified against current code). Master-plan slot: Stage B4
> (`../2026-07-16_master-plan.md`). All anchors re-verified 2026-07-19 against kzen-project,
> kzen-launcher, kzen-shell (read-only), kzen-auto, and kzen-lib working trees; drift since the
> constituent plan was written is called out in § Current-state findings. Executor: one session,
> **M** size. Two independent halves — (A) kzen-project extension point, (B) launcher upgrade
> path — which share only the docs step; they can be executed in either order within the session.

## Scope & goal

**A — extension point (kzen-project + nothing else):** make "add your own `@Reflect` class to
the template" actually work out of the box. Since the 2026-06-21 KSP migration, kzen-project has
zero `@Reflect` classes, KSP emits no `ModuleReflection` objects (deliberately —
`ReflectSymbolProcessor.kt:42` suppresses empty modules), and the mains correctly register
nothing. A downstream user who adds an `@Reflect` class gets a generated module that nothing
registers → runtime `IllegalArgumentException` with no hint why. Fix is the pre-made package
deal: sample `@Reflect` objects (which make the generated modules non-empty) + the registration
calls in both mains + a server test that instantiates a sample through the notation path. The
samples double as living "how to extend" documentation.

**B — upgrade path (kzen-launcher + wire DTOs):** created projects are frozen at their
creation-day jar (`kzen-launcher/AGENTS.md:67` documents this as a design property — that doc
changes here). Add an Upgrade action: replace `main.jar` + `dependencies/` in the project home
from a selected archetype zip, preserving everything else (`notation/`, `work/`, `logs/`, user
files). Split archetype identity into name + version (`ArchetypeInfo.version`), record
`archetype` + `version` on `ProjectInfo` at create/upgrade (imports get `unknown`), offer latest
version per name in New Project, offer newer-than-recorded versions via an Upgrade button,
refuse when running, allow downgrade with a warning.

## Dependencies & coordination

- **SH2 / SH3 have NOT landed** (both still open in `plans/next/`). SH4 is independent of both,
  but note: SH3 will convert `ProjectRepo`/`ArchetypeRepo` to load-once + atomic persist and
  make the project home injectable. SH4's repo changes below are expressed against the current
  read-modify-write shape; if SH3 lands first, carry the same fields/methods into the in-memory
  shape mechanically. SH4 deliberately makes `ProjectRepo`'s metadata path constructor-injectable
  (needed for its own tests) — SH3 keeps that.
- **SH5** (docs-to-truth sweep) runs after; SH4 still does its own docs in-session per house rule.
- **R plan / EXT-D1 (NOT ratified):** SH4 is the *static* cousin of R5's dynamic plugin-shipped
  `ModuleReflection` registration — independent code paths, no ordering constraint
  (`../2026-07-18_reflection-improvements.md` header; master plan rule 10). The extension-point
  docs written here must tell the **static** story (compile-time KSP + explicit `register()` in
  the mains) and mention the dynamic plugin cousin only as a **pending decision** (EXT D1 / R5),
  not as an available mechanism.
- **SER4/SER5 drift check (done):** launcher YAML persistence is still Jackson 3
  (`tools.jackson.*` in `ProjectRepo.kt:9-13`) — as the master plan records ("Jackson … surviving
  only in kzen-launcher YAML"). The wire DTOs (`ArchetypeDetail`, `ProjectDetail`) are kotlinx
  `@Serializable` on both sides. New wire fields must carry kotlinx defaults (additive).
- **kzen-auto is read-only for this phase.** The bundled-notation nesting constraint (below)
  is worked *within*, not changed.
- **Build prerequisite:** kzen-project consumes kzen-auto from mavenLocal
  (`kzen-project/AGENTS.md:62`, buildSrc pin `kzenAutoVersion`). Before building kzen-project,
  ensure kzen-auto has been `publishToMavenLocal`'d at the pinned version.
- **Git hygiene:** stage every new file by explicit path as soon as written; never commit;
  never `git add -A`. Changes span kzen-project + kzen-launcher — run `git status` and stage in
  each. Never touch anything under any `notation/main/`.

## Current-state findings (verified 2026-07-19)

### kzen-project (extension point)

- **Mains register nothing.** `kzen-project-jvm/.../server/KzenProjectMain.kt:13-18` —
  `main` calls `kzenAutoInit(args, kzenProjectJsModuleName, BuildInfo.load(...))` then
  `kzenAutoMain(context)`; no registration.
  `kzen-project-js/.../client/Main.kt:3-9` — delegates to `tech.kzen.auto.client.main()`; the
  commented-out block at lines 4-6 is the **old pre-KSP shape**
  (`js("require('kzen-project-js.js')")` + `ModuleRegistry.add(...)`) — obsolete API, delete it;
  the new calls do not resemble it.
- **KSP config intact in all three build files** and will emit modules the moment a `@Reflect`
  class appears in the scanned source set:
  - `kzen-project-common/build.gradle.kts:76-96` — `kspCommonMainMetadata` +
    `arg("kzen.reflect.moduleClassName", "tech.kzen.project.common.codegen.KzenProjectCommonModule")`
    + the commonMain generated-srcDir/dependsOn wiring (same pattern as kzen-auto-common).
  - `kzen-project-jvm/build.gradle.kts:26,36-38` — `ksp(...)` +
    `tech.kzen.project.server.codegen.KzenProjectJvmModule`.
  - `kzen-project-js/build.gradle.kts:67-74` — `kspJs` +
    `tech.kzen.project.client.codegen.KzenProjectJsModule`. (kzen-auto-js uses the identical
    `kspJs` shape with **no** extra srcDir wiring — the KSP plugin wires JS-target output
    automatically; no build-file changes needed anywhere.)
- **Empty modules are suppressed by design**: kzen-lib `ReflectSymbolProcessor.kt:39-44`
  (`if (collected.isEmpty()) return`, with the comment explaining the test-classpath FQN
  collision it prevents). ⇒ **A registration call for a module compiles only if that module's
  source set has ≥ 1 `@Reflect` class.** The constituent plan's decision that `KzenProjectMain`
  registers Common **+ Jvm** and JS `Main` registers Common **+ Js** therefore *requires* a
  sample in each of the three source sets — one commonMain sample alone cannot satisfy it.
  Resolved in § Pre-resolved questions Q1.
- **Registration model** (mirror of kzen-auto): `ModuleReflection.register(reflectionRegistry =
  ReflectionRegistry.global)` (kzen-lib `ModuleReflection.kt:13`); registration is additive,
  last-write-wins, FQCN-keyed. kzen-auto's own registrations happen in companion `init` blocks —
  JVM: `KzenAutoContext.kt:71-75` (`KzenLibCommonModule` → `KzenAutoCommonModule` →
  `KzenAutoJvmModule`, triggered on first class touch inside `kzenAutoInit`, `KzenAutoMain.kt:93`);
  JS: `ClientContext.kt:38-42` (Lib → Common → `KzenAutoJsModule`, triggered by
  `ClientContext.create()` inside `tech.kzen.auto.client.main()`'s `window.onload`). Registering
  kzen-project's modules *before* delegating is required because graph creation happens inside
  the delegate; disjoint FQCNs make ordering vs. kzen-auto's own registrations immaterial.
- **Classpath notation discovery is automatic**: kzen-lib
  `ClasspathNotationMedia.scanPaths()` (kzen-lib-jvm `.../notation/ClasspathNotationMedia.kt:63-79`)
  does a Guava `ClassPath.from(loader).resources` scan for any classpath resource under
  `notation/` ending in the yaml suffix — **any jar on the classpath can contribute documents,
  zero kzen-auto edits**. `KzenAutoContext.kt:103-111` composes it (excluding `main/`) with
  `FileNotationMedia(GradleLocator)` via `LiteralNotationMedia.filter(classpath, file)` (file
  copy shadows an identical classpath doc — this is how dev-tree copies are reconciled).
- **BUT the instantiation choke points filter by fixed document-nesting sets**
  (`kzen-auto-common/.../util/AutoConventions.kt:21-30`):
  `serverAllowed = {kzen-base/, auto-common/, auto-jvm/, main/}` — applied in
  `GraphInstanceCreator.kt:22`, `ModelTaskRepository.kt:132`, `ModelDetachedExecutor.kt:38,66`;
  `clientUiAllowed = {kzen-base/, auto-common/, auto-js/}` — applied in kzen-auto-js
  `Main.kt:47`. ⇒ kzen-project's bundled read-only docs **must live under the `auto-common/` /
  `auto-jvm/` / `auto-js/` nestings** (subdirectories are fine — the filter is a
  `startsWith(nesting)` check). A dedicated `project-*` nesting would need a kzen-auto change —
  out of scope, flagged in § Risks and in the docs step.
- **Third-party Script step is a proven zero-shared-edit pattern**: kzen-auto's own acceptance
  test `kzen-auto-jvm/src/test/.../server/exec/script/ScriptExtensibilityTest.kt` runs
  `ShoutStep` — a step defined entirely in the test source set
  (`.../server/exec/script/test/`, registered by the hand-written `ScriptStepTestModule`) —
  through `LogicCompiler.compile(...)` + `RunEngine` with no compiler/when edits. Its notation
  fixture is the `test/`-nested `script-extensibility-test.yaml` + a separate archetype
  declaration doc (archetypes must be declared **once globally** — object names are graph-global
  in `coalesce`; a duplicate declaration is ambiguous). The step SPI lives in
  `kzen-auto-jvm/src/main/.../server/objects/script/api/` (main sources ⇒ available to
  kzen-project). Model the sample step verbatim on `ShoutStep`.
- **Step display selection is per-step notation** (`display:` attribute read by
  `StepDisplayManager.findDisplayWrapper`, kzen-auto-js `.../script/display/StepDisplayManager.kt:81-91`)
  — a third-party step **inherits the default display** (`ScriptStepDisplayDefault`) from the
  `ScriptStep` archetype chain and needs **no JS class** to render, run, park, and trace.
  A full custom `ScriptStepDisplay` is heavyweight (`ScriptStepDisplayDefault.kt` is 646 lines) —
  not sample material. The lightweight, real JS extension axis is the **collapsed-card
  `AttributeView`**: `ControlSummaryAttributeView.kt` (138 lines, self-contained; `@Reflect`
  `Wrapper(objectLocation, @Service clientStateGlobal): AttributeView`) is the model; it is
  selected by a tag on the step archetype's `meta` (see its header comment) and declared as an
  `is: AttributeView` object in `auto-js` notation
  (`kzen-auto-jvm/src/main/resources/notation/auto-js/document/script-js.yaml:169-186`).
- **Ribbon palette is notation-driven**: built-in steps appear via `is: RibbonTool` objects
  (`parent:` a Script `RibbonGroup`, `delegate:` the step archetype) declared in the `auto-js`
  docs; the shared `RibbonController` is document-agnostic. A bundled `RibbonTool` in
  kzen-project's own `auto-js/`-nested doc joins an existing group with zero kzen-auto edits.
  Title/icon come from the step archetype's `title:`/`icon:` notation (icons: any
  `"material-symbols:<name>"`, quoted — see kzen-auto `docs/js-architecture.md` §5).
- **Custom prototypes are graph-global**: `CustomConventions.listPrototypes(graphNotation)`
  discovers every object marked `is: Prototype` **anywhere in the graph** (kzen-auto
  `docs/architecture.md` §6) — a bundled `auto-common/`-nested prototype object appears in the
  Custom document's `+ Add` dropdown with zero kzen-auto edits. `Prototype` is a bare abstract
  marker; kzen-auto's own examples live in its `main/Custom.yaml` seed — mirror one of those for
  the `is:` chain / `meta` tag shape.
- **`KzenAutoContext.forTest()` is main-source and downstream-usable**
  (`KzenAutoContext.kt:85-88` → `create(KzenAutoConfig(jsModuleName = "kzen-auto-js"))`);
  `LogicCompiler` / `LogicCompilerServices` / `RunEngine` are likewise main-source. kzen-auto's
  `AutoTestUtils` is **test-source (not published)** — kzen-project's test reads notation from
  `context.graphStore` instead (or carries a trimmed local copy of the `AutoTestUtils` shape).
  A test-classpath resource under `notation/…` is picked up by the same `ClasspathNotationMedia`
  scan (the context classloader in tests includes test resources).
- **Seed notation is currently empty**: `kzen-project-jvm/src/main/resources/` tracks only
  `banner.txt`; the `notation/main/` dir on disk is empty and untracked. The `dist` task
  (`kzen-project-jvm/build.gradle.kts:125-133`) copies **the whole** `src/main/resources/notation`
  into the zip as the *disk* seed, with a comment warning that read-only docs belong on the
  classpath "or it would double-serve" — see step A5 for the required narrowing.
- kzen-project version `0.30.0-SNAPSHOT`; `KzenProjectMain` also passes its own
  `BuildInfo.load("/kzen-project-build.properties")` — registration calls go before that line's
  `kzenAutoInit` call.

### kzen-launcher (upgrade path)

- **No archetype registry YAML exists — drift from the constituent plan's wording.** The
  0.29.x redesign made the cache directory of zips the catalogue
  (`ArchetypeRepo.kt:14-19` header comment): `all()` (`ArchetypeRepo.kt:146-161`) scans
  `<projectHome>/kzen-archetypes/` for `kzen-project-*.zip`, keys each entry by the filename
  minus `.zip` (e.g. `kzen-project-0.29.1`), parses the version out of the filename
  (`versionOf`, `ArchetypeRepo.kt:193-197`) and today embeds it only in the *description
  string* (`"$descriptionBase - v${versionOf(artifact)}"`). Version sort: `versionKey` /
  `compareVersions` (`ArchetypeRepo.kt:200-227`) — numeric components + a trailing snapshot flag
  so `X-SNAPSHOT` sorts **above** the equal release; unparseable versions sort last but are
  still offered. So "formalize the filename parse into the field" means: add fields to the
  in-memory `ArchetypeInfo` (`ArchetypeInfo.kt:6-10`: currently `title, description, location`)
  — **no YAML anywhere on the archetype side**.
- **Project registry**: `kzen-projects.yaml`, Jackson 3, whole-file read/write
  (`ProjectRepo.kt`). `ProjectInfo` (`ProjectInfo.kt:6-9`): `home: Path`,
  `jvmArguments: String = ""`. `bindInfo` (`ProjectRepo.kt:205-220`) requires `home`, reads
  optional `args`. The metadata path is a **companion static**
  (`ProjectRepo.kt:26-27` → `LauncherEnvironment.projectHome.resolve("kzen-projects.yaml")`) —
  not injectable; SH4 tests need a constructor override (step B3).
  `get()`'s error message says "Archetype not found" (`ProjectRepo.kt:59`) — copy-paste bug,
  fix opportunistically.
- **Create flow**: `ProjectCreator.create` (`ProjectCreator.kt:54-78`) — sibling
  `.staging` dir, `extractGradle` → `unzip` with the 0.29.x **zip-slip guard**
  (`resolveEntry`, `ProjectCreator.kt:133-142`), `check(main.jar)` then atomic
  `swapIntoPlace` (`ProjectCreator.kt:81-90`, `ATOMIC_MOVE` with cross-store fallback).
  All of `unzip`/`resolveEntry`/`swapIntoPlace` are private and directly reusable by `upgrade`.
- **Running-project semantics**: the launcher **server has no channel to the shell** — running
  state is merged client-side only (`ClientShellRestApi` polling `/shell/project`;
  `ManageProjectsScreen.kt:45-53` filters projects with an active job out of the manage list, so
  a running project shows no manage-row actions at all). Server-side, the established pattern is
  the Windows lock probe: `ProjectRepo.delete` (`ProjectRepo.kt:88-105`) relies on
  `deleteRecursively` failing on a locked file and throws `IllegalStateException` ("is the
  project still running?") which `respondCommand` (`KzenLauncherMain.kt:376-395`) maps to
  **409 Conflict** with a JSON `message` the client surfaces via `ErrorBus`. Upgrade mirrors
  exactly this (constituent plan: "on Windows an in-use jar fails the copy anyway — surface
  that cleanly"). The child JVM (spawned by kzen-shell as `java -jar main.jar`; the shell
  re-resolves the jar from the project home on every start) holds `main.jar` open without
  `FILE_SHARE_DELETE`, so a rename/move of it fails on Windows while running. POSIX residual:
  no lock ⇒ an upgrade of a running project would succeed silently (process keeps old inodes) —
  same accepted residual as delete; the UI filter is the guard.
- **REST + security**: routes in `KzenLauncherMain.routeRest` (`KzenLauncherMain.kt:337-372`),
  paths in `CommonRestApi` (`kzen-launcher-common/.../api/CommonRestApi.kt:11-18` —
  `/rs/command/project/{create,import,remove,delete,rename,args}`), handler methods in launcher
  `RestHandler.kt`. **SecurityGate needs NO change**: it protects the whole `/rs/command/`
  prefix (`SecurityGate.kt:30,87` `path.startsWith(commandPathPrefix)`), so a new
  `/rs/command/project/upgrade` is covered automatically. (SH1's shell-side gate lists only
  `/shell/project/start|stop` literals — launcher command paths ride the same prefix rule in the
  shell's copy; verify nothing to add there — the shell gate also uses the `/rs/command/` prefix
  via the proxied path. If the shell copy turns out to match only its own literals, that is
  fine: the launcher's own gate still protects the route end-to-end.)
- **Wire DTOs (kotlinx, both sides)**: `ArchetypeDetail(name, title, description, location)`
  (`ArchetypeDetail.kt:7-12`; `name` is the create/upgrade `type` param — lookup is
  scan-keyed, never a path resolve, `ArchetypeRepo.kt:164-169`); `ProjectDetail(name, path,
  jvmArgs@SerialName("args"), exists)` (`ProjectDetail.kt:8-18`), filled in launcher
  `RestHandler.listProjects` (`RestHandler.kt:27-41`).
- **Client**: `ClientProjectRestApi` (thin GET wrappers, `ClientProjectRestApi.kt`);
  `ProjectItem` (`ProjectItem.kt`) renders per-row actions — the delete flow
  (`ProjectItem.kt:98-114`: fire → button spinner → Promise settle → clear) is the model for
  Upgrade; the confirm `Dialog` (`ProjectItem.kt:285-327`) is the model for the Upgrade dialog.
  Action callbacks thread `ProjectLauncher` (owns store + refresh) → `ManageProjectsScreen` →
  `ProjectList` → `ProjectItem`; archetypes are already loaded in the store for the New Project
  screen — thread them into the manage chain (step B7). `muiAutocompleteField`
  (`NewProjectScreen.kt:303-309`) is the version-select widget. `NewProjectScreen` currently
  shows **every** cached version as a separate entry (`renderTypeSelect`,
  `NewProjectScreen.kt:280-312`), defaulting to the first (= latest, server-sorted).
- **Dev verification**: `FrontendDevelopment` runs the launcher with `simulateShell = true`
  (in-memory `ShellSimulator` — fakes start/stop, spawns nothing), so the Upgrade UI is fully
  drivable in the dev loop; the lock-refusal path is NOT reproducible there (nothing holds the
  jar) — covered by the unit test + the end-to-end shell pass.
  `kzen-launcher.properties` currently: dev `file:` candidates pointing at
  `../kzen-project/kzen-project-jvm/build/dist/kzen-project-0.30.0-SNAPSHOT.zip` (re-acquired
  every boot) + released `kzen-project-0.29.1.zip` GitHub URL — so a dev boot caches **both**
  0.29.1 and 0.30.0-SNAPSHOT, which is exactly the create-old → upgrade-new fixture.
- Existing test scaffolding to model on: `ArchetypeRepoTest.kt` (temp-dir + real-file repo
  tests), `SecurityGateTest.kt`, `ProjectNameValidationTest.kt`; kotlin-test JUnit4.

## Pre-resolved questions

**Q1 — what are the samples? (resolves the constituent plan's internal gap).** The pre-made
decision requires `KzenProjectMain` to reference `KzenProjectJvmModule` and JS `Main` to
reference `KzenProjectJsModule`; those objects only exist if their source sets each contain a
`@Reflect` class (empty-module suppression, `ReflectSymbolProcessor.kt:42`). Therefore **three
minimal samples, one per source set, telling one coherent story** — each is the canonical
how-to for its extension axis:

1. **`SampleGreeting`** — kzen-project-common `commonMain`
   (`tech.kzen.project.common.objects.SampleGreeting`): a `@Reflect` class implementing
   kzen-auto-common's `DetachedAction` (one-shot request/response — the smallest executable
   paradigm), with a `message: String` constructor attribute; `execute` returns
   `ExecutionSuccess` of the message. Declared in bundled notation as an `is: Prototype`
   abstract object so it appears in the Custom document's `+ Add` dropdown. *Axis: shared
   (common) model/logic object + Custom prototype.* Makes `KzenProjectCommonModule` non-empty.
2. **`SampleUppercaseStep`** — kzen-project-jvm
   (`tech.kzen.project.server.objects.SampleUppercaseStep`): a Script step modeled **verbatim**
   on kzen-auto's `ShoutStep` (`kzen-auto-jvm/src/test/.../server/exec/script/test/`) — same SPI
   (`server/objects/script/api/`), same shape (reference an upstream step's value, return it
   uppercased), but `@Reflect`-annotated so the *real generated* `KzenProjectJvmModule` carries
   it. Declared as a step archetype + `RibbonTool` in bundled notation so it appears in the
   Script ribbon and runs with the **default** step display. *Axis: your own automation step,
   zero kzen-auto edits.* Makes `KzenProjectJvmModule` non-empty.
3. **`SampleUppercaseSummaryView`** — kzen-project-js
   (`tech.kzen.project.client.objects.SampleUppercaseSummaryView`): a collapsed-card
   `AttributeView` for the sample step's input attribute, modeled **verbatim** on
   `ControlSummaryAttributeView.kt` (138 lines — render e.g. `→ UPPERCASE(<referenced step>)`),
   wired by the archetype-`meta` view tag exactly as `ControlSummaryAttributeView` is on
   `ControlStep` (copy the tag shape from `script-jvm.yaml`'s ControlStep meta and the
   `is: AttributeView` declaration shape from `script-js.yaml:169-186`). *Axis: client-side
   display extension.* Makes `KzenProjectJsModule` non-empty.

Rationale: dependency-light (only kzen-auto APIs already on the classpath), each individually
small, and together they make all six pre-made registration calls compile and prove that a
downstream `@Reflect` class in **any** source set registers with zero further edits. The
samples are **load-bearing**: deleting all `@Reflect` classes from a module un-emits its
`ModuleReflection` and breaks the main's compile — documented in AGENTS (step A6).

**Q2 — where does bundled notation live?** In `kzen-project-jvm/src/main/resources/notation/`
(single home, mirroring kzen-auto), under the **existing allowed nestings** with a
`kzen-project/` subdirectory and globally-unique object names:

- `notation/auto-common/kzen-project/sample-common.yaml` — `SampleGreeting` prototype object
  (`is: Prototype` chain + `class:` + `message` default; mirror an existing prototype in
  kzen-auto's `main/Custom.yaml` seed for the exact shape/meta tags).
- `notation/auto-jvm/kzen-project/sample-jvm.yaml` — `SampleUppercaseStep` archetype (`is:`
  the same parent chain ShoutStep's test archetype uses; `title: "Uppercase (sample)"`,
  `icon: "material-symbols:text-fields"` (quoted!), `class:`, attribute metadata incl. the
  summary-view tag naming `SampleUppercaseSummaryView`).
- `notation/auto-js/kzen-project/sample-js.yaml` — the `is: AttributeView` object for
  `SampleUppercaseSummaryView` + the `is: RibbonTool` object (`parent:` the same Script ribbon
  group the built-in simple steps use — copy from `script-js.yaml`/`main-js.yaml`;
  `delegate: SampleUppercaseStep`).

Discovery is automatic (`ClasspathNotationMedia` full-classpath scan); the nesting choice is
forced by the fixed `serverAllowed`/`clientUiAllowed` sets (`AutoConventions.kt:21-30`) — this
namespace-sharing is deliberate and documented (§ Risks; docs step notes a dedicated
downstream nesting as a future kzen-auto/EXT item).

**Q3 — registration call sequences (exact).**

```kotlin
// KzenProjectMain.kt — BEFORE kzenAutoInit (graph creation happens inside it):
import tech.kzen.project.common.codegen.KzenProjectCommonModule
import tech.kzen.project.server.codegen.KzenProjectJvmModule
fun main(args: Array<String>) {
    KzenProjectCommonModule.register()
    KzenProjectJvmModule.register()
    val context = kzenAutoInit(args, kzenProjectJsModuleName, BuildInfo.load("/kzen-project-build.properties"))
    kzenAutoMain(context)
}

// kzen-project-js Main.kt — BEFORE delegating (ClientContext.create() runs in onload):
import tech.kzen.project.common.codegen.KzenProjectCommonModule
import tech.kzen.project.client.codegen.KzenProjectJsModule
fun main() {
    KzenProjectCommonModule.register()
    KzenProjectJsModule.register()
    console.log("kzen-project modules registered: KzenProjectCommonModule, KzenProjectJsModule")
    tech.kzen.auto.client.main()
}
```

Delete the obsolete commented `ModuleRegistry` block (`Main.kt:4-6`). The `console.log` is the
phase-verification "JS bundle boot logs its module registration" probe. Mirrors kzen-auto's own
sequencing (Lib → Common → platform) with the Lib/Auto registrations left to the delegate's
companion-`init`s; kzen-project registers only its own modules.

**Q4 — upgrade = which files, what sequence (crash-safe + lock-probing).**
`ProjectCreator.upgrade(home: Path, archetypeInfo: ArchetypeInfo)`:

1. `check(Files.exists(home))` and `check(Files.exists(home/main.jar))` (`IllegalArgumentException`
   → 400 if not a project home).
2. Extract the archetype zip into a sibling staging dir `<home>.upgrade` (pre-delete any
   leftover from a failed prior attempt, as `create` does for `.staging`), reusing the existing
   private `unzip` + zip-slip `resolveEntry`; `check(staging/main.jar exists)`.
3. Pre-clean any leftover `main.jar.old` / `dependencies.old` in home (best-effort; failure →
   `IllegalStateException` 409).
4. **Lock probe + backup**: `Files.move(home/main.jar → home/main.jar.old)` — on Windows this
   fails while the project is running (child JVM holds the jar) → catch `IOException`, clean
   staging, throw `IllegalStateException("Could not replace main.jar (is the project still
   running?): …")` → 409.
5. If `home/dependencies` exists: `Files.move(home/dependencies → home/dependencies.old)` (a
   directory rename — fails cleanly on Windows if any dep jar is open) — on failure roll back
   step 4 (`main.jar.old → main.jar`), clean staging, throw the same `IllegalStateException`.
6. `Files.move(staging/main.jar → home/main.jar)`; if `staging/dependencies` exists,
   `Files.move(staging/dependencies → home/dependencies)`. On failure roll both `.old` backups
   back and rethrow.
7. Best-effort delete: `main.jar.old`, `dependencies.old`, and the whole staging remainder
   (which still holds the archetype's seed `src/…/notation` etc. — deliberately **not** copied:
   "preserve everything else" means the user's `notation/`, `work/`, `logs/`, and any other
   file are never touched, and a newer archetype's seed docs are not imported). Log, don't fail,
   on residue (mirrors `ArchetypeRepo.deleteQuietly` rationale).

No version-ordering enforcement server-side (downgrade allowed by decision; the warning is
client-side). The caller (`RestHandler.upgradeProject`) records `archetype` + `version` in
`ProjectRepo` **after** a successful swap.

**Q5 — version model.**

- `ArchetypeInfo` gains `archetype: String` (base name, e.g. `kzen-project` — the repo's
  configured `archetypeName`) and `version: String` (from `versionOf(artifact)`, e.g. `0.29.1`,
  `0.30.0-SNAPSHOT`, or `custom` for an unparseable filename). Entry key (map key / `name` /
  `type` param) stays the full `kzen-project-<version>` string.
- `versionKey`/`compareVersions` move to kzen-launcher-common commonMain as
  `tech.kzen.launcher.common.util.VersionNumbers` (`compare(a, b): Int` keeping the exact
  current semantics incl. snapshot-above-equal-release and unparseable-last;
  `parses(v): Boolean`); `ArchetypeRepo` delegates; the JS client uses it for button gating,
  dialog ordering, and the downgrade warning. (KMP commonMain, pure Kotlin — fine.)
- `ProjectInfo` gains `archetype: String = "unknown"`, `version: String = "unknown"` (const
  `ProjectRepo.unknownValue = "unknown"`); YAML additive (`bindInfo` reads optional →
  default `unknown`; `unbind` always writes both). Recorded at create (from the resolved
  `ArchetypeInfo`) and at upgrade; `importProject` records `unknown`/`unknown`.
- Wire: `ArchetypeDetail` + `archetype: String = ""`, `version: String = ""`;
  `ProjectDetail` + `archetype: String = "unknown"`, `version: String = "unknown"` (kotlinx
  defaults ⇒ additive; launcher client+server ship as one artifact so no real skew window).
- **Latest-per-name selector rule (New Project)**: client-side in `NewProjectScreen` — group
  archetype entries by `archetype` base name; within a group keep only the first entry of the
  server-sorted (version-descending) list **among entries whose version parses**; entries with
  unparseable versions are always shown individually (never hide a cached artifact — the
  `kzen-project-custom.zip` case from `ArchetypeRepoTest`). Endpoint stays complete (Upgrade
  needs all versions).
- **Upgrade offering rule (per project row)**: candidates = archetype entries whose base name
  matches the project's recorded `archetype` (recorded `unknown` ⇒ all entries). Show the
  Upgrade button iff `recorded == unknown && candidates.nonEmpty`, or any candidate has
  `VersionNumbers.compare(candidate.version, recorded) > 0`, **or** (dev-reinstall clause)
  recorded ends with `-SNAPSHOT` and an equal-version candidate exists (a rebuilt snapshot zip
  is re-acquired each boot under the same version string — without this clause the upgrade path
  itself would be untestable in the dev loop). The dialog lists all candidates except the
  recorded version (plus the equal snapshot in the reinstall case), version-descending,
  defaulting to the newest; when the selection is not strictly newer than the recorded version
  (or recorded is `unknown`), show an inline warning ("Downgrade/reinstall — project data
  created by a newer version may not load; a backup of your project folder is recommended").

**Q6 — server test for the samples (kzen-project-jvm `src/test`).** One suite,
`SampleExtensionTest`, modeled on `ScriptExtensibilityTest` but registering the **real
generated** modules:

- Fixture: test-classpath docs `src/test/resources/notation/test/sample-step-test.yaml` (a
  minimal Script: a text-producing step + `SampleUppercaseStep` referencing it — copy the
  `script-extensibility-test.yaml` shape) and, if a concrete instance is needed for the
  detached case, `src/test/resources/notation/auto-common/kzen-project/sample-greeting-test.yaml`
  (an `is: SampleGreeting` concrete object — `auto-common/` so `serverAllowed` admits it).
- `@Test bundledDocsDiscoveredOnClasspath`: `KzenAutoContext.forTest()`; read the notation from
  `context.graphStore` (runBlocking) and assert the three bundled sample documents are present —
  pins the classpath-discovery + nesting choice.
- `@Test sampleGreetingExecutesThroughDetachedPath`:
  `KzenProjectCommonModule.register(); KzenProjectJvmModule.register()` (idempotent);
  `context.detachedExecutor.execute(<test instance location>, ExecutionRequest.empty)` →
  assert `ExecutionSuccess` with the message — this instantiates the sample through the full
  notation → definition → `GraphCreator` path (inside `ModelDetachedExecutor`, including the
  `serverAllowed` filter).
- `@Test sampleStepRunsInScript`: compile the test Script via `LogicCompiler.compile` +
  `RunEngine` exactly as `ScriptExtensibilityTest.runScript` does (graphNotation/definition
  from `context.graphStore`; `LogicCompilerServices` from the context's public fields) → assert
  the uppercased output. If harness friction appears (e.g. a `graphDefinitionAttempt` helper
  gap), fall back to asserting `GraphCreator` instantiation of the step object — the
  notation-path instantiation requirement is met either way; prefer the full run.

**Q7 — REST param names**: reuse `CommonRestApi.projectName` (`name`) +
`CommonRestApi.createProjectType` (`type`, carrying the archetype entry name) for
`/rs/command/project/upgrade` — same lookup-not-path-resolve safety as create
(`ArchetypeRepo.get`, `ArchetypeRepo.kt:164-169`).

## Step-by-step implementation

### Half A — kzen-project extension point

- **A1. Sample classes** (new files, one per source set — § Q1):
  `kzen-project-common/src/commonMain/kotlin/tech/kzen/project/common/objects/SampleGreeting.kt`;
  `kzen-project-jvm/src/main/kotlin/tech/kzen/project/server/objects/SampleUppercaseStep.kt`
  (model: ShoutStep);
  `kzen-project-js/src/jsMain/kotlin/tech/kzen/project/client/objects/SampleUppercaseSummaryView.kt`
  (model: `ControlSummaryAttributeView.kt`). Each `@Reflect`; generous KDoc — these ARE the
  living documentation ("to add your own X: copy this file, declare it in notation under …,
  KSP + the main's register() do the rest").
- **A2. Bundled notation** (new files under `kzen-project-jvm/src/main/resources/notation/` —
  § Q2): `auto-common/kzen-project/sample-common.yaml`, `auto-jvm/kzen-project/sample-jvm.yaml`,
  `auto-js/kzen-project/sample-js.yaml`. Copy `is:` chains / meta shapes from the named kzen-auto
  models; globally-unique object names (`SampleGreeting`, `SampleUppercaseStep`,
  `SampleUppercaseSummaryView`, `SampleUppercaseTool`); archetypes declared exactly once.
- **A3. Registration calls** in both mains per § Q3 (delete the obsolete commented block in JS
  `Main.kt:4-6`).
- **A4. Build check** — no build-file edits expected (§ findings); confirm
  `./gradlew build` emits all three `KzenProject*Module` objects under `build/generated/ksp/…`
  and the mains compile against them.
- **A5. Dist double-serve guard**: narrow the `dist` task's notation copy
  (`kzen-project-jvm/build.gradle.kts:132`) from `src/main/resources/notation` to
  `src/main/resources/notation/main` — the new `auto-*` docs are read-only classpath documents
  (inside `main.jar`) and must NOT also ship as loose disk seed (the build file's own comment:
  read-only on classpath "or it would double-serve"). The disk-seed line then copies nothing
  today (empty `main/`) — correct, and future seed docs go under `notation/main/`.
- **A6. Docs** (same session): kzen-project `AGENTS.md` — rewrite the Purpose line 5 ("currently
  contains no project-specific `@Reflect` objects"), the Entry-points table rows 21-22 ("no
  module registration"), Key-directories (add the three sample files + notation dir), and
  replace the line-63 gotcha with the new truth: extension point works; per-source-set rule
  ("a `@Reflect` class registers via that module's generated `KzenProject*Module`; the samples
  are load-bearing — an emptied module un-emits and breaks the main's compile"); bundled-notation
  nesting rule (`auto-common/`/`auto-jvm/`/`auto-js/` only, with why + the fixed-set anchor);
  dist seed-vs-classpath rule. kzen-project `README.md`: add/refresh the extension-point
  section telling the **static** story, with one sentence noting the *dynamic* plugin-JAR
  registration cousin is a pending decision (EXT D1 / reflection-plan R5) — do not present it
  as available.

### Half B — launcher upgrade path

- **B1. `VersionNumbers`** (new, kzen-launcher-common commonMain
  `tech/kzen/launcher/common/util/VersionNumbers.kt`) per § Q5; `ArchetypeRepo` delegates
  (delete its private `versionKey`/`compareVersions`, keep behavior byte-identical — the
  existing `ArchetypeRepoTest` ordering tests pin it).
- **B2. `ArchetypeInfo` + repo + DTO**: add `archetype`/`version` fields
  (`ArchetypeInfo.kt`), fill in `ArchetypeRepo.all()` (`ArchetypeRepo.kt:152-159`); add the
  two DTO fields (`ArchetypeDetail.kt`) and fill them in the `listArchetypes` route
  (`KzenLauncherMain.kt:340-348`).
- **B3. `ProjectInfo` + `ProjectRepo`**: fields with `unknown` defaults (`ProjectInfo.kt`);
  `bindInfo`/`unbind` additive YAML (`ProjectRepo.kt:170-220`); `add(name, home, archetype,
  version)`; new `recordArchetype(name, archetype, version)` (read-copy-write like
  `changeArguments`, `ProjectRepo.kt:130-141`); make the metadata path a constructor parameter
  defaulting to the current companion value (test injectability; SH3-compatible); fix the
  `get()` message (`ProjectRepo.kt:59`).
- **B4. `ProjectCreator.upgrade`** per § Q4 (staging/extract/lock-probe/backup-swap/rollback;
  reuse `unzip` + `resolveEntry` + the `.staging` pre-clean idiom).
- **B5. REST**: `CommonRestApi.upgradeProject = "${projectCommandPrefix}upgrade"`
  (`CommonRestApi.kt`); launcher `RestHandler.upgradeProject(parameters)` — resolve project
  (`projectRepo.get`), archetype (`archetypeRepo.get`), call
  `projectCreator.upgrade(info.home, archetypeInfo)`, then
  `projectRepo.recordArchetype(name, archetypeInfo.archetype, archetypeInfo.version)`; route in
  `routeRest` via `respondCommand` (400/409 mapping comes free, `KzenLauncherMain.kt:376-395`).
  SecurityGate: no change (prefix-covered — assert in the existing `SecurityGateTest` style
  that a cross-site navigation to the new path is denied, one test line).
- **B6. `ProjectDetail`** + `archetype`/`version`; fill in launcher `RestHandler.listProjects`
  (`RestHandler.kt:27-41`); `createProject` (`RestHandler.kt:44-52`) resolves the
  `ArchetypeInfo` once and passes base name + version to `projectRepo.add`; `importProject`
  passes `unknown`s.
- **B7. Client**: `ClientProjectRestApi.upgradeProject(name: String, type: String)` (mirror
  `createProject`); thread `archetypes` + an `onUpgrade: (ProjectDetail, String) -> Promise<Unit>`
  callback down `ProjectLauncher` → `ManageProjectsScreen` → `ProjectList` → `ProjectItem`
  (refresh-after-action lives where delete's does); `ProjectItem`: Upgrade button (visibility
  per § Q5's offering rule; spinner Promise pattern of `onDeleteConfirm`,
  `ProjectItem.kt:98-114`) + version dialog (`Dialog` model `ProjectItem.kt:285-327`;
  `muiAutocompleteField` for the version list; inline downgrade/reinstall warning; row shows
  the recorded `archetype`/`version` next to the path line so the state is visible).
- **B8. `NewProjectScreen`**: latest-per-name filter per § Q5 (grouping on the new `archetype`
  field; unparseable-version entries shown individually); default-selection logic
  (`init`/`componentDidUpdate`, `NewProjectScreen.kt:69-90`) unchanged (first entry of the
  filtered list).
- **B9. Docs**: kzen-launcher `AGENTS.md` — replace the line-67 gotcha ("A created project is
  frozen, not a cache") with the create+upgrade truth (staging swap, lock-probe 409, what
  upgrade replaces vs preserves, downgrade-with-warning, `unknown` for imports); update the
  Key-directories `project/` row and the `CommonRestApi` shared-contract note; add the
  archetype/version recording to the `kzen-projects.yaml` description. Tick the SH plan's
  Phase-4 tracker box and append an as-built note there (per the plan's own maintenance rule),
  including the ArchetypeInfo-not-YAML drift and the three-samples resolution.

## Tests

**kzen-project (`kzen-project-jvm/src/test`)** — `SampleExtensionTest` per § Q6 (three tests:
classpath discovery, detached execution of `SampleGreeting`, Script run of
`SampleUppercaseStep`), plus the two test notation fixtures. Keep the existing trivial
`ServerTest` as-is.

**kzen-launcher (`kzen-launcher-jvm/src/test` + commonTest)**:
- `VersionNumbersTest` (commonTest): ordering incl. snapshot-above-equal-release, unparseable
  handling, `compare` symmetry — port the expectations already pinned by `ArchetypeRepoTest`'s
  ordering test so the extraction is provably behavior-preserving.
- `ProjectCreatorUpgradeTest` (model: `ArchetypeRepoTest` temp-dir style; build archetype zips
  programmatically with `ZipOutputStream` — `main.jar` with distinguishable content,
  `dependencies/dep-<v>.jar`, a seed `src/main/resources/notation/main/Doc.yaml`):
  1. upgrade replaces `main.jar` + `dependencies/` (old dep gone, new present) and preserves
     user files (`notation/`, `logs/`, `work/`, a stray user file) and does NOT import the new
     archetype's seed notation;
  2. archetype zip missing `main.jar` → fails, home byte-identical (staging discarded);
  3. **Windows lock probe**: hold an open `InputStream` on `home/main.jar`, upgrade →
     `IllegalStateException`, then close and assert home unchanged (rollback) — guard the
     assertion body with `if (!System.getProperty("os.name").lowercase().contains("win")) return`;
  4. leftover `.old`/staging from a simulated failed attempt is cleaned on the next successful
     upgrade.
- `ProjectRepoTest` (new, using the injected metadata path): round-trip with
  `archetype`/`version`; legacy YAML without the fields binds to `unknown`;
  `recordArchetype` persists.
- `ArchetypeRepoTest`: extend the scan test to assert the new `archetype`/`version` fields.
- `SecurityGateTest`: one case for the upgrade path (cross-site navigation denied).

## Verification

1. **Builds**: `./gradlew build` in kzen-project (after confirming kzen-auto is published to
   mavenLocal at the pinned version) — proves KSP emitted all three modules (the mains'
   imports are the compile-time proof) — and in kzen-launcher; both test suites green.
2. **Template test**: `SampleExtensionTest` green (notation-path instantiation + run on JVM).
3. **JS boot log**: run the kzen-project dev loop (or `java -jar` the built jar) and confirm
   the browser console logs `kzen-project modules registered: …`; smoke: the Script ribbon
   shows "Uppercase (sample)", inserting + running it works with the default display and the
   collapsed summary view; a Custom document's `+ Add` lists `SampleGreeting`.
4. **Launcher dev loop** (`FrontendDevelopment`, simulateShell): manage list shows recorded
   archetype/version; Upgrade button appears per the offering rule; dialog versions + warning
   render; upgrade round-trips and the row's version updates (lock-refusal is NOT provable
   here — unit test 3 + step 5 cover it).
5. **End-to-end (shell)**: boot kzen-shell → launcher caches both the released `0.29.1` and
   the dev `0.30.0-SNAPSHOT` zips (current `kzen-launcher.properties` candidates) → create a
   project from **0.29.1**, start it, add/edit a document, stop → Upgrade to
   **0.30.0-SNAPSHOT** → project boots on the new jar (version hover text / build stamp) with
   the old notation intact; `kzen-projects.yaml` shows the new recorded version. Also: attempt
   Upgrade while the project is running by driving the REST route directly (the UI hides the
   row) → 409 with the "still running" message and the project unharmed.

## Risks & gotchas

- **Windows file locks are the enforcement mechanism, not just a failure mode.** The
  lock-probe ordering (jar first, then the dependencies directory rename) is what turns
  "running" into a clean 409 with zero partial state; keep the `.old`-backup + rollback
  sequence exactly — a naive delete-then-copy can partially delete `dependencies/` before
  hitting a locked jar. POSIX has no such lock: upgrading a running project there succeeds
  silently (old inodes keep serving) — accepted residual, same as delete's; the UI filter is
  the real guard. Document in AGENTS (B9).
- **Namespace sharing with kzen-auto.** Bundled docs must sit under `auto-common/`/`auto-jvm/`/
  `auto-js/` because `AutoConventions.serverAllowed`/`clientUiAllowed`
  (`AutoConventions.kt:21-30`) are fixed sets consulted at every instantiation choke point.
  Consequences: (a) object names are graph-global — the samples' names must never collide with
  kzen-auto's (the `Sample*` prefix); (b) archetypes are declared once globally; (c) a
  dedicated `project-*` nesting is a future kzen-auto/EXT change — record it in the docs, do
  not attempt it here.
- **The samples are load-bearing for compilation** (empty-module suppression). A future
  "cleanup" that deletes a module's last `@Reflect` class breaks that main's build with a
  missing-symbol error on the `register()` line — which is exactly the loud failure we want,
  but it must be documented (A6) so it reads as design, not accident.
- **Dev-tree double-serve**: with the sample docs in `kzen-project-jvm/src/main/resources/
  notation/auto-*`, a dev run's `FileNotationMedia` (GradleLocator sees `./src`) shadows the
  identical classpath copies via `LiteralNotationMedia.filter` (`KzenAutoContext.kt:107-111`) —
  same content, but the disk copy is technically writable in dev (kzen-auto lives with the same
  property for its own `auto-*` docs). The **dist** copy is the one that must be narrowed (A5)
  or the packaged product would serve the read-only docs writable from disk.
- **Snapshot version semantics**: `X-SNAPSHOT` sorts above the equal release `X`
  (deliberate, `ArchetypeRepo.kt:200-213`), so a snapshot counts as "newer" than its release in
  the upgrade offering — desirable in dev, mildly surprising in prod (a user with `0.30.0`
  would be offered `0.30.0-SNAPSHOT` if one were ever cached; in practice release machines
  never cache snapshots — `pruneStaleSnapshots` keeps only the current dev one).
- **`unknown` recorded versions** (imports, pre-SH4 projects): every existing project in a
  user's registry binds to `unknown` on first read after this lands — the Upgrade button will
  appear for all of them (by the § Q5 rule) with the warning dialog. That is the intended
  recovery path (it lets pre-SH4 projects adopt version tracking via one upgrade), but state
  it in the AGENTS note so it doesn't read as a regression.
- **SH3 collision**: if SH3 lands first, `ProjectRepo`/`LauncherEnvironment` anchors shift
  (in-memory repo, injected home). All B3 changes are field/method-level and carry over
  mechanically; do not re-introduce a static metadata path.
- **kzen-shell needs zero changes** (verified): it re-resolves `main.jar` from the project home
  on every start, so an upgraded project boots the new jar with no shell involvement; the
  launcher server has no shell channel, which is why refuse-when-running is UI-filter +
  lock-probe rather than an authoritative check.

## Out of scope (do not drift into)

- Widening/registering `serverAllowed`/`clientUiAllowed` nestings in kzen-auto (EXT candidate).
- Dynamic plugin-JAR `ModuleReflection` registration (EXT D1 / R5 — pending ratification;
  docs mention it only as pending).
- SH2 (exit detection), SH3 (registry durability/`--project.home`), SH5 (docs sweep beyond
  SH4's own files).
- Automatic upgrade of a *running* project, shell-side running-state API for the launcher,
  or any authoritative server-side running check.
- Migrating launcher YAML off Jackson 3, or any registry format change.
- Archetype seed-notation import/merge on upgrade (new-version seed docs are deliberately not
  copied into existing projects).
- A custom `ScriptStepDisplay` sample (646-line surface — the AttributeView is the right-sized
  JS axis); desktop/DA concerns.
