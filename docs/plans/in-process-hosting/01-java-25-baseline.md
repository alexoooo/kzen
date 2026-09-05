# HS01 — Java 25 baseline and local publication

> Status: not started. One implementation session. Prerequisites: None; this is the first implementation session.
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

Not executed.
