# HS07 — Process-global runtime and plugin scopes

> Status: not started. One implementation session. Prerequisites: HS01.
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

Not executed.
