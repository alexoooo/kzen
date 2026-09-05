# HS08 — Provider descriptors and exact-origin notation

> Status: not started. One implementation session. Prerequisites: HS07.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E2 discovery and hosting gate G10.

## Outcome and anchors

ReaderCapabilityRegistry; kzen-lib-jvm ClasspathNotationMedia; runtime scope descriptors; KSP ModuleReflection provider integration.

## Work

1. Discover ServiceLoader capabilities per scope and deduplicate inherited providers by their declaring loader. Keep descriptors in the runtime and instantiate reader capabilities separately per context.
2. Validate reader identity duplicates globally. Provider construction/metadata failures retain the failing origin; document the cheap-construction expectation.
3. Add exact-origin notation scanning/reading: own jar URLs for each folder, application scanned separately, exact resource URL retained through reads. Duplicate logical documents report both origins and fail boot.
4. Preserve generated plugin reflection contributions with their scope via explicit provider registration; do not flatten them into kzen's eagerly validated global registry.
5. Merge notation through existing server-allowed prefixes and preserve standalone bundled resources. Publish changed kzen-lib modules before testing kzen-auto.

## Verification and exit criteria

G10: two folders do not rediscover application notation; a folder/application logical-path collision fails with both origins; noncolliding folder bytes equal the actual jar entry. Also prove parent providers count once, reader duplicates fail, and two contexts receive distinct provider instances.

## Handoff

Record exact scan/read APIs and fixture task commands. Discovery is ready for HS09; E2 remains incomplete.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
