# HS12 — Plugin diagnostics and compatibility test kit

> Status: not started. One implementation session. Prerequisites: HS11; external sample replay follows in HS22.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E3; E2 discovered-contribution diagnostics.

## Outcome and anchors

PluginDocument and its client view, runtime descriptors/availability, plugin SPI test fixtures and build configuration.

## Work

1. Convert PluginDocument into a cached, read-only installed-scope/contribution view. Show discovered contributions, lazily resolved classes, contextual unavailability, shadowing and named failures; do not promise a full class inventory.
2. Retire the plugins.yaml/ReportDefiner loading mechanism once the cities Job replacement is available, or keep that retirement explicitly pending for HS21. Do not leave two competing folder installers.
3. Provide a reusable compatibility test-kit entry point callable against an external directory: loader/discovery, notation, Java reflection/service needs, expression identity, duplicates and expected diagnostics. Keep JVM implementation dependencies in test fixtures/test scope, not in the runtime SPI dependency graph.
4. Document folder installation, startup pinning, optional manifest metadata and --plugin.root. Upload and plugin-provided JS remain deferred.
5. Exercise the diagnostics UI with the constructed universe; actions and captions explain availability in the current workspace.

## Verification and exit criteria

Run kit against tiny fixtures, including boot-error cases in their own JVMs. Browser-check successful, failed and unavailable scopes plus app shadowing. Repeated page reads must not rescan jars, instantiate new providers or trigger System.gc().

## Handoff

E3 implementation is delivered, but mark its phase complete only after HS21 retirement and HS22 external-kit acceptance. Record those pending checks explicitly.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
