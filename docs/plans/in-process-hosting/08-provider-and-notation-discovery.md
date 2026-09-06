# HS08 — Provider descriptors and exact-origin notation

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS07.
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

Executed 2026-09-05 across kzen-lib (published to mavenLocal first) and kzen-auto-jvm.

**kzen-lib.** `OriginNotationMedia` (kzen-lib-jvm) scans and reads notation over an explicit list of jar URLs
only — one null-parent `URLClassLoader` per URL, so a folder's scan never rediscovers application resources
inherited through its parent — and records the exact resource URL of every document it served (`origin(path)`).
`UnionNotationMedia` (kzen-lib-common) composes disjoint read-only medias. `GlobalMirror.registerAfterGlobalRegistry`
inserts a mirror behind the generated global registry so generated-first behaviour is preserved.
`ServiceAttributeCreator` names a missing `@Service` type ("is unavailable in this workspace: it needs
@Service X") instead of failing anonymously. Tests: `OriginNotationMediaTest`, `UnionNotationMediaTest`.

**Discovery (`PluginContributionDiscovery.discover(scopes)`, once at boot).** Per loaded scope:
1. `ServiceLoader<ReaderCapability>` **de-duplicated by declaring loader** — only providers whose class the scope's
   own loader defined count for that scope, so parent providers are counted once, on the application scope.
   Each provider is instantiated once to read its identity; a throwing constructor or unreadable identity is a
   named failure on that scope (`ScopeContributions.failures`, with the cause chain), not a boot error.
   Descriptors (`ReaderProviderDescriptor`: scope, provider class, identity, supplier) stay in the runtime;
   `ReaderCapabilityRegistry.forRuntime(runtime)` instantiates fresh capabilities per context. A duplicate
   identity across scopes is a boot error naming both scopes.
2. Bundled notation, exact-origin: folder scopes via `OriginNotationMedia` over their own jar URLs; the
   application scope via `ClasspathNotationMedia` over the application loader; both restricted to the existing
   server-allowed prefixes (`auto-main` excluded). A logical document path shipped by two origins is a boot error
   naming both origins. `KzenAutoRuntime.bundledNotation` is the union; `KzenAutoContext.readOnlyMedia` is
   `LiteralNotationMedia.filter(runtime.bundledNotation, fileMedia)`, so standalone bundled resources are preserved.
3. `ServiceLoader<ModuleReflection>`: a plugin's generated registrations are registered into a registry **owned by
   that scope** (`ScopeContributions.generatedRegistry`), never into `ReflectionRegistry.global`, so kzen's eager
   global validation is unaffected by a plugin whose services a workspace lacks.

**Verification.** `PluginContributionDiscoveryTest` (4 cases): two folders contribute their own notation, readers
and generated registry with exact origins and do not rediscover application notation (G10 first half); a folder
shipping an application document path fails boot naming both origins; noncolliding folder document bytes equal
the actual jar entry; duplicate reader identities across folders fail boot; a throwing provider is a named
failure on its scope only. `RuntimeContributionsBootTest` (forked): two contexts share descriptors but resolve
distinct capability instances, both see the folder document and the application's own, and the folder document's
bytes read back exactly. Commands: `./gradlew :kzen-auto-jvm:test --tests "tech.kzen.auto.server.context.runtime.*"`,
`./gradlew :kzen-auto-jvm:pluginUniverseTest`. kzen-lib published with `cd ../kzen-lib && ./gradlew publishToMavenLocal`
before the kzen-auto runs.
