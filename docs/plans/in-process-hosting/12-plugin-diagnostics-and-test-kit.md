# HS12 — Plugin diagnostics and compatibility test kit

> Status: complete 2026-09-05 (E3 phase completion pending HS21/HS22). One implementation session. Prerequisites: HS11; external sample replay follows in HS22.
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

Executed 2026-09-05 across kzen-auto-common, kzen-auto-jvm, kzen-auto-js, kzen-lib-common (one fix) and the
docs of kzen-auto, kzen-sample-plugin and the umbrella.

**Plugin document (Work 1, 2).** `PluginDocument` is now a read-only view served from cached runtime state:
`PluginUniverseView.scopes(runtime, pluginAvailability)` projects `KzenAutoRuntime.scopes` / `contributions`
(immutable since boot), `PluginDiagnostics` (append-only) and `PluginAvailability.known()` (append-only) into
`PluginScopeDetail` rows (kzen-auto-common: id, version, SPI, directory, jars, loaded/failure, readers as
`namespace.name@compatibility`, documents with exact origin, generated modules, resolved classes with
`available` / `unavailable (needs @Service X)` / `unresolvable (reason)`, shadowed and ambiguous names, named
failures). A read never rescans a jar, instantiates a provider or calls `System.gc()` (the old nudge went with the
ephemeral loaders; `CompatibilityKitBootTest` asserts two reads are equal and the reader provider's constructor
count is unchanged). `KzenAutoRuntime` and `PluginAvailability` are exposed to `@Service` parameters. The
client (`PluginController`) renders one card per scope with captions explaining availability *in this workspace*;
kzen's own bundled notation is one count line on the application card. **Lazy class learning is now wired**
(a gap left by HS09): `PluginAvailability` observes the graph store and, on boot and after every successful
command / refresh, resolves each `class` the notation names that a folder scope defines and kzen's generated
registry does not serve — so a notation edit first naming a reflective plugin Worker shows up in that
context's view only (asserted in `CompatibilityKitBootTest` with a `CreateDocumentCommand`). **Legacy
installer kept, explicitly pending HS21:** the `jarPath` attribute and `plugins.yaml` / `ReportDefiner` loading
moved out of the document into `LegacyPluginJar` (read straight from notation), `PluginReportDefinitionRepository`
no longer instantiates documents through the graph (constructor is now `(graphStore)`), and a diagnostics-only
Plugin document (blank `jarPath`, the new default) is cached as "nothing to load" instead of retrying every call.
There is one folder installer; the jar-path path is Report-input-only and labelled as retiring in the UI.
*(Closed in HS21: `LegacyPluginJar`, `PluginReportDefinitionRepository`, `MultiDefinitionRepository`, the
`jarPath` attribute and its editor are deleted; Reports take the host's built-in definers only.)*

**kzen-lib fix found by the browser check.** A document naming a class the mirror cannot serve (defined by two
folders, or malformed) threw `IllegalArgumentException` out of `AttributeObjectDefiner.define` and killed the
whole graph definition — the server would not boot. `AttributeObjectDefiner` now returns that object's named
definition failure (`Class cannot be served: …`); kzen-lib republished to mavenLocal (all JVM tests green).

**Compatibility kit (Work 3).** `tech.kzen.auto.server.context.runtime.kit.PluginCompatibilityKit` (kzen-auto-jvm
main, nothing added to the SPI's dependency graph) with `KitExpectations` (loaded/failed scopes, boot-error
substrings, readers, documents, available/unavailable classes, ambiguous/shadowed names, expression-identity
classes) and `KitReport` (the same `PluginScopeDetail` rows the document shows, `problems`, `toMarkdown()`).
`inspect(root, expectations)` is pure — discovery, contributions, exact-origin notation, service needs through a
local mirror, duplicates, shadowing and ambiguity by jar-index probes, no runtime pinning, loaders closed
after — so healthy and boot-error universes run in one JVM. `verify(root, expectations)` pins the runtime,
creates a standalone context (temp module + work root), resolves the expected classes through the real
availability view and proves expression identity by compiling `<fqcn>::class.java` against the plugin classpath
and comparing it with the aggregate loader's `Class`. `main(<root> [--verify])` prints Markdown, exit 1 on
unmet expectations. Tests: `PluginCompatibilityKitTest` (ordinary: a five-scope universe with all expectation
kinds met, five named unmet expectations, and a duplicate-id + SPI-mismatch universe expected and unexpected),
`CompatibilityKitBootTest` and `KitVerifyBootErrorBootTest` (forked, one universe per JVM; the latter proves a
failed verify leaves the runtime unpinned).

**Docs (Work 4).** kzen-auto `docs/architecture.md` §8 rewritten from the jar-path / `ReportDefiner` model to
plugin = class loader (folder install, `--plugin.root=`, manifest, startup pinning, protocols and duplicate
rules, aggregate loading, per-context availability, the document, the kit, Java-first adapters);
`../kzen-sample-plugin/README.md` rewritten around the two-tier layout, folder install and the kit; kzen-auto
`AGENTS.md` gained the plugin-universe and work-root gotchas (incl. the demo-universe export). `--plugin.root=`
is parsed by `KzenAutoConfig` beside `--module.root=`; kzen-launcher / kzen-shell child command lines need no
pass-through (the default is `plugins/` under the module root or cwd). Upload and plugin-provided JS stay
deferred; nothing assumes the loader set is hand-authored.

**Browser check (Work 5, Verification).** `KZEN_UNIVERSE_EXPORT` + `PluginUniverseExportTest` wrote the demo
universe (alpha: reader, bundled document, generated module, a class needing `fixture.alpha.Repo`; dup-one /
dup-two defining one name; shadow carrying an application class; broken: corrupt jar); the built jar was booted
on port 18090 with `--plugin.root=`, a temp `--module.root=` and `--work.root=` (never the user's servers or
home), with a Plugin document and a probe Script naming the unavailable, ambiguous and shadowed classes. The
page showed: `application loaded`; `alpha loaded` with its reader, document (jar origin), generated module,
`AlphaGen available`, `NeedsRepo unavailable — needs @Service fixture.alpha.Repo`; `broken failed — unopenable
jar broken.jar: zip END header not found`; `dup-one` / `dup-two` each with `Same cannot be served — defined by 2
plugin scopes` and the `Ambiguous` line; `shadow` with the `Shadowed — the application copy is used` line. The
only document errors were the probe fixtures' missing `icon`/`title` attributes. Repeated page reads hit the
cached projection (see the boot test).

**Pending checks, as the handoff requires:** E3's phase completes only after HS21 retires `jarPath` /
`LegacyPluginJar` / `PluginReportDefinitionRepository` with the cities Job replacement, and after HS22 runs the
kit against the external sample. Full `./gradlew build` of kzen-auto green after the changes; kzen-project
rebuilt against the republished artifacts. New files staged by explicit path.
