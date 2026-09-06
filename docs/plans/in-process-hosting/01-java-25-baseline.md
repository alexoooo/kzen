# HS01 — Java 25 baseline and local publication

> Status: complete 2026-09-04 (as-built below). Prerequisites: None; this is the first implementation session.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §3 and §9 G8.

## Outcome and anchors

All five source-bearing siblings; each buildSrc/src/main/kotlin/Dependencies.kt, JVM/KMP build scripts and toolchain documentation.

## Work

1. Read each affected sibling's AGENTS.md and authoritative pins. Retarget emitted Java/Kotlin bytecode to 25 without changing Kotlin or any coordinated release version. Keep the installed newer toolchain if Java/Kotlin task target validation permits; otherwise align the toolchain deliberately and record why.
2. Configure Java compilation against the Java 25 API surface as well as class-file target. Inspect Kotlin JVM compilation's API baseline and prove execution on a real JDK 25; target bytecode alone cannot detect accidental Java 26 API calls.
3. Build/publish in dependency order: kzen-lib (including reflect-ksp), kzen-auto (including plugin), kzen-project, kzen-launcher, kzen-shell. Use each sibling's own directory and existing versions. Read docs/RELEASING.md for publication details, but do not cut a release.
4. Update affected toolchain instructions with the actual distinction between Gradle JVM, compile toolchain and supported runtime. Rebuild the existing Java sample against the refreshed artifacts.

## Verification and exit criteria

Run relevant JVM tests and application startup probes on JDK 25, inspect representative class-file versions, and run the FormulaStepTest canary. Complete each sibling's build; publish before its consumer, including variant-suffix artifacts. Confirm the existing Maven sample builds and loads on 25. G8 passes only with API/runtime evidence, not a successful umbrella build.

## Handoff

Record JDKs, targets, commands, artifact versions and any Java-26-only usages found. This unlocks HS02 and the plugin-runtime work.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-04. G8 passes on API, bytecode and runtime evidence.

**Decision — toolchain moved to JDK 25, not just the target.** `jvmTargetVersion = "25"`, `javaVersion = 25`,
`jvmToolchainVersion = 25` in all five `buildSrc/src/main/kotlin/Dependencies.kt`. Keeping a JDK 26 toolchain
with a 25 target would have satisfied KGP's target-consistency check, but Kotlin compiles against the toolchain's
class library, so a Java-26-only API call would compile silently; `-Xjdk-release=25` is an experimental flag.
Compiling on the installed `temurin-25.0.4.1` makes the Java 25 API the compile baseline for Java *and* Kotlin
and runs every Gradle `test` task on a real JDK 25. The Gradle JVM stays 26 (`JAVA_HOME`); buildSrc's own
25-pin in kzen-auto is unchanged (it is about the daemon JVM, comment reworded). No release-train version changed.
The kzen-lib KSP processor stays at its deliberate Java 17 target (class-file 61).

**Builds (each from its own directory, `--no-daemon`, all `BUILD SUCCESSFUL`, in dependency order):**

| Sibling | Command | Result |
|---|---|---|
| kzen-lib | `./gradlew build publishToMavenLocal` | 1m 53s; jvm + common jvmTest + jsBrowserTest green; `-common`, `-jvm`, `-js`, `-reflect-ksp` published |
| kzen-auto | `./gradlew :kzen-auto-plugin:publishToMavenLocal build publishToMavenLocal` | 8m 28s; 999 JVM tests, 0 failures; `FormulaStepTest` 10/10 green (canary) |
| kzen-project | `./gradlew build` | 1m 47s; 3 JVM tests green (no `maven-publish` in this sibling) |
| kzen-launcher | `./gradlew build` + `:kzen-launcher-jvm:dist` | 48s; dist zip built for the shell probe |
| kzen-shell | `./gradlew build` | 1m 11s |
| kzen-sample-plugin | `mvn -o clean package` (`JAVA_HOME` = temurin-25.0.4.1, Maven 3.9.9 from `~/.m2/wrapper`) | enforcer convergence passed; `javac [release 25]` |

**Class-file evidence** (`javap -v`, `major version`): kzen-lib-common-jvm 69, kzen-lib-jvm 69, kzen-lib-reflect-ksp 61
(intended), kzen-auto-jvm 69, kzen-auto-plugin 69, kzen-project-jvm 69, kzen-launcher-jvm 69, kzen-shell (`kzen-0.30.0-SNAPSHOT.jar`) 69,
kzen-sample-plugin 69, and the sample's copied `target/lib/kzen-auto-plugin-*.jar` 69.

**Runtime evidence on `temurin-25.0.4.1`** (`java -jar`, isolated temp homes under `%TEMP%\kzen-hs`, spare ports, every JVM stopped after
its command line was matched):
- kzen-auto-jvm from a copy of `kzen-auto-test/fixtures/empty-project`, `--server.port=18191`: `/index.html` 200 with
  `kzen-build` = `0.30.0-SNAPSHOT (built 2026-09-04T22:39:53-04:00)`, `/logic/status` JSON answered.
- kzen-shell `--server.port=18192 --launcher.zip=file:///…/kzen-launcher-0.30.0-SNAPSHOT.zip --launcher.dir=… --project.home=…`:
  extracted the launcher, spawned it with the JDK 25 `java`, `/main/index.html` 200 after 16 s, `/shell/project` → `[]`.
  Without `--launcher.dir=` the shell fails fast by name (it has no default) — a usable probe needs both args.
- kzen-sample-plugin: `Class.forName` + `newInstance` of `WorldCitiesPopProcessorDefiner` over `target/lib/*` on 25.0.4.1
  returned its `ReportDefinitionInfo`.
- Gradle: `javaToolchains` lists both Temurin 25 installs; test tasks execute on the toolchain JVM.

**Java-26-only usages found:** none — every module compiled against the JDK 25 class library without change.

**Docs updated:** umbrella `AGENTS.md` (three JVM roles: Gradle JVM ≥ 25, compile toolchain 25, runtime 25+; PATH gotcha;
pins snapshot), `docs/RELEASING.md` (prerequisites and the Phase 4 boot check), `kzen-lib/AGENTS.md`, `kzen-auto/AGENTS.md`
(headless-verification JDK and the buildSrc gotcha), `kzen-shell/AGENTS.md` (run command). The shell's `distWindows` now
provisions a Temurin 25 runtime because `ProvisionAdoptiumJdk.featureVersion` tracks `javaVersion` (not exercised here).

**Deviation to note:** the first launcher probe ran `FrontendDevelopmentKt` without `--project.home=`, so `ArchetypeRepo.init`
ran against the user's real `../kzen-proj` home for two seconds. It attempted one HTTPS download (404, no acquisition
succeeded, so no prune ran) and left no `.part` file; the archetype cache was verified byte-identical in listing afterwards.
Later probes used `--project.home=` under `%TEMP%`. The kzen-launcher AGENTS.md "shell-simulator surface" recipe should
say that `FrontendDevelopmentKt` also needs `--project.home=` — surfaced, not changed here (CC-07).

**Not done:** `kzen-shell distWindows` (JDK download) was not run; no release cut; nothing committed.
