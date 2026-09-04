# Third-party extensibility — plugin registration, plugin UX, Custom power, plain-object data (E1–E9)

> **Status: E1 ratified 2026-09-04; E2/E3 re-elaborated; E7/E8/E9 added; review 1 of the hosting
> analysis folded in the same day (`docs/analysis/2026-09-03_in-process-hosting_review-1.md`).** Promotes
> `sprint-2/2026-07-06_custom-plugin-extensibility-analysis.md` from analysis to plan format, and
> **merges in the open tail of `sprint-2/2026-07-18_reflection-improvements.md`** — R5 *is* the
> reflection half of D1, so they are one arc, not two plans. Executor: **Opus-class, one phase per
> session**.
>
> **The E1 decision session happened on 2026-09-04**, driven by
> `docs/analysis/2026-09-03_in-process-hosting.md` §6a (a Spring host embedding kzen, and a substantive
> `kzen-sample-plugin` over NASDAQ ITCH order-level data — both of which need a plugin system that is
> *general and simple*). Its verdicts are the as-built in Phase E1 below; E2 and E3 were rewritten to
> them, E5 turned out moot, and three phases the session surfaced were added: **E7** (plain Java classes
> as typed data — no annotations, no wrappers), **E8** (object-graph paths in a Job) and **E9**
> (closeable streams and items — the user's memory-arena requirement). Review 1 corrected E2's first
> re-elaboration on one point that matters: the plugin universe is **process-global**, not per context.
>
> **Progress tracker** (update as phases land):
> - [x] E1 — ratification: D1–D7 + gate R5-G — **ratified 2026-09-04 (user); verdicts below**
> - [ ] E2 — plugin = classloader: one process-global `KzenAutoRuntime` (loaders, mirrors, discovery, expression classpath) initialized once before any context; directory discovery; `ServiceLoader` + mirror + notation per loader; Java-friendly SPI adapters (**was R5 + D1 + D2**)
> - [ ] E3 — plugin UX: `PluginDocument` as the *discovery-based* diagnostics view, `--plugin.root=`, listing from cache, plugin compatibility test kit (**D3 = not now, do not preclude**)
> - [ ] E4 — Custom power: prototype metadata (C4), per-tag affordance registry (C6), run-result persistence (D6), the C7 document-rename gap
> - [x] E5 — ObjectRegistry disposition (D4) — **moot; `ObjectRegistryScan` left the tree during the Job data-source work. Closes with a doc grep**
> - [x] E6 — DataSchema gate (D5) — **absorbed by DS6 on 2026-08-24; real consumer landed**
> - [ ] E7 — plain-object data shape (D9): ordinary classes by convention, enums, `Set`, design-time shape through the adapter registry, per-class token cache, recursive type references
> - [ ] E8 — object-graph paths: path-projection / unnest Worker + design-time path picker
> - [ ] E9 — closeable streams and items: `AutoCloseable` honoured on every stream type (incl. `java.util.stream.Stream`) and on individual elements, with defined close timing across channels, migration, cancel and failure
> - [x] **R6 — client-plugin verdict: CLOSED, no session required.** A separately-compiled Kotlin/JS
>   bundle does not share class identity with the host bundle (two copies of kzen-lib-common ⇒
>   `instanceof`, sealed hierarchies and registry-typed lookups all fail), so "load another bundle
>   that calls `register()`" cannot work regardless of loader mechanics. Verdict: **declarative-first**
>   — generic attribute editors + notation-driven `display:`/archetype markers. Already recorded in
>   the reflection plan (Phase R6) and EXT D7; C6's per-tag card registry is the in-tree seam that
>   keeps the door open.

## The strategic finding (do not re-litigate)

**The extension ceiling is `ReflectionRegistry`, not notation.** Notation is already open — a
third party can declare archetypes, documents and attributes freely. What they cannot do is
contribute a *class* the graph can instantiate, because construction goes through the
KSP-generated, compile-time-fixed reflection registry. Everything in this plan follows from
closing that gap.

## Landed context — what E2–E8 stand on

- **EXT hygiene S1–S10 (−S7) ✓ 2026-07-20.** All nine items plus the cluster's **first tests**
  (`PluginReportDefinitionRepositoryTest`, `ObjectRegistryScanCacheTest`, `CustomViewModelBuilderTest`,
  `CustomExportsRenameTest` in kzen-auto-jvm; `CustomViewReorderTest`, `ClassListSpecTest`,
  `FieldFormatSpecTest` in kzen-auto-common commonTest so they also run on ChromeHeadless). Two
  deviations that matter downstream: the drop translation was extracted into a testable common
  `CustomViewReorder` (with `CustomObjectInfo` / `CustomViewModel` / `CustomViewExports` moved to
  kzen-auto-common alongside it), and `CustomStore.onClientState` — not the controller — hosts the
  view-model Builder, so a prototype added in *another* document reaches the picker.
- **R1 ✓ 2026-07-20 — JVM reflective fallback mirror.** `GlobalMirror.register` chain +
  `ReflectiveClassMirror` in kzen-lib-jvm, wired into both kzen-auto bootstraps. **This reshapes D1:
  pure-Java plugins need no KSP at all.** Contingency C1 fired, so the KSP processor now skips
  Java-origin declarations.
- **R2 ✓ 2026-07-20** — five hand-written test `ModuleReflection`s deleted; fixtures now `@Reflect`
  served by the R1 mirror. **This is a working precedent for exactly the pure-Java plugin case D1
  has to decide.** `ScriptStepTestModule` was kept as the hand-implementable-contract proof.
- **R3 ✓, R4 ✓ 2026-07-20** — processor hardening; `@Service` FQN boot validation. R4 matters to E2:
  it runs at boot and will extend to plugin modules for free once they register.
- **`@Service` / `GraphEnvironment` construction-time DI** — kzen-lib injects runtime services into
  `@Reflect` constructor params from a `GraphEnvironment` threaded through `createGraph`. Registered
  plugin classes resolve from the same environment.

**Gotcha carried from R2 (will bite E2):** KSP2 **does** process kzen-auto-jvm's test source set —
a second `ModuleReflection` there shadowed the main one and silently dropped all 74 production
registrations, so `kspTestKotlin` is disabled in `kzen-auto-jvm/build.gradle.kts`. When E2 adds a
Kotlin test plugin with its own KSP module, keep it in a **separate module**, not in kzen-auto's
test source set. Grep the test log for `Serving … by JVM reflection` — only fixtures may appear.

---

## Phase E1 — ratification ✓ 2026-09-04 (as-built)

**Decided with the user on 2026-09-04**, in the design conversation recorded in
`docs/analysis/2026-09-03_in-process-hosting.md` §6a. The user's framing that shaped every verdict:
*two tiers, both wanted* — (1) a plugin **implements kzen SPI interfaces** (reader / data source, step,
Worker) as the ergonomic route; (2) **standard Java code never written for kzen** is usable too, less
ergonomically and with a wrapper only if the author *wants* one. And: Job replaces Report; nothing new
is built for the Report paradigm.

| ID | Decision | **Verdict** |
|---|---|---|
| **D1** | Plugin module registration | **Yes.** A plugin contributes notation-instantiable classes with zero kzen-source edits. **KSP is never required** — third-party logic may be Java, which has no KSP; a plugin that *does* ship a KSP `ModuleReflection` may get extra ergonomics, never a different capability. Registration is per classloader: reflective mirror + `ServiceLoader` + bundled notation (E2). |
| **R5-G** | Loader lifecycle | **Boot-time pinned, restart to upgrade.** The Windows jar-lock objection dissolves: a loaded jar is never replaced in place, so the `.use{}` / `System.gc()` dance goes away with the ephemeral loaders. |
| **D2** | Isolation unit | **One `URLClassLoader` per plugin directory** (a *set* of related jars — shading stops being required). No plugin-to-plugin dependency for now. |
| **D3** | JAR upload | **Not now** — no concrete need. Install = a directory under the plugin root (or a Maven/Gradle dependency when embedded). **Do not preclude upload**: the loader contract is "a directory", so an upload can later materialize a jar set into one without touching anything else. |
| **D4** | `ObjectRegistry` disposition | **Moot.** `ObjectRegistryScan` and the document type are no longer in the tree (removed during the Job data-source work, commit "Job: data source progress"). E5 closes with a doc grep. |
| **D5** | `DataFormat` disposition | Already absorbed by DS6 (E6). |
| **D6** | Custom run-result persistence | Unchanged recommendation (store keyed by stable id) — still E4's call; not discussed. |
| **D7** | Plugin custom client UI | **Out of scope.** Declarative editors only (R6 verdict stands). |
| **D8** | *(proposed, then dropped)* manifest allow-list for plain classes | **Dropped.** The expression Workers already do this: `FormulaSourceWorker` evaluates a Kotlin expression, classifies it on the compiler's inferred type, and streams an `Iterable` / `Sequence` / `Iterator`; `FormulaWorker` / `FilterWorker` give the per-element case. `ItchReader(Path.of(file))` is a source today, with the same security posture as every existing expression. The only work is threading the plugin loader into the expression compiler (E2). |
| **D9** | Plain-object data shape | **Yes, and without wrappers.** Records / data classes / `List` / `Map` / a rich scalar set already lift to typed, recursively-described, lazily-navigated `DataValue`s (kzen-lib-jvm `DefaultDataAdapterRegistry`, `DefaultNativeTypeResolver`, `NativeObjectValueAccess`). Remaining, all E7: ordinary classes by JavaBeans convention; enums; `Set`; design-time shape through the adapter registry (today the editor sees a record-typed stream as Opaque); per-class native-token cache; recursive type references. **Reflection is already once per class**, not per row (`NativePropertyPlans`). |
| **D10** | App classloader as plugin zero | **Implementation rule for E2**, not a decision: one discovery code path over every loader, the application loader included, so a Maven-dependency plugin (embedded host) and a folder plugin (standalone) behave identically. |
| **new** | Java-friendly SPI | `ReaderCapability.open` / `inspect` and `SourceWorker.produce` are `suspend`; a Java author should not have to implement a `Continuation` signature. **Add `BlockingReaderCapability` and a blocking `SourceWorker` variant to `kzen-auto-plugin`** (E2). |
| **new** | Object-graph paths | Runtime navigation is lazy and arbitrary-depth already; what is missing is a **path-projection / unnest Worker** (paths → columns, nested list → one row per element) plus a design-time path picker (E8). |
| **new** | `kzen-sample-plugin` | Keep the world-cities logic as the *simple* case beside ITCH's complex one, **re-cut as a `BlockingReaderCapability` (Job-only)**; `ReportDefiner` support is not carried forward. |

**Verification:** this table; E2–E8 below are written to it.

---

## Phase E2 — plugin = classloader (D1 + D2 + D10 + R5, re-elaborated 2026-09-04)

**Risk: medium.** The lifecycle risk the first draft carried (classloader pinning vs the Windows
jar-lock) is gone with R5-G; what remains is the runtime / context split and the discovery rules — the
expression-classpath threading turned out to be one function (below).

**Goal:** a plugin — a directory of jars, or the application classpath itself — contributes readers,
`@Reflect` objects (Job Workers, Script steps, Flow vertices, Custom prototypes) and notation, with zero
kzen-source edits and no KSP. Plugin *UX* is E3.

**The one concept.** A plugin **is** a classloader — more precisely, *a plugin installation scope is one
classloader* (review 1). Discovery runs the *same* three channels over every loader, the application
loader included (D10):

1. **`ServiceLoader`** for SPI capabilities: `ReaderCapability` (with its `ReaderProbeCapability` /
   `FormatAuthoringCapability` faces), already discovered this way from the context classloader by
   `ReaderCapabilityRegistry.withConfiguredReaders()` — extend to iterate every plugin loader, and
   **de-duplicate by declaring loader** (`ServiceLoader.stream()` filtered on
   `provider.type().classLoader === loader`), since a child loader's `ServiceLoader` also yields every
   parent provider. `ReportDefiner` is **not** discovered from plugins any more (Job replaces Report);
   the built-in definer repository is untouched.
2. **A `ReflectiveClassMirror(loader)` registered on `GlobalMirror`** per plugin loader — the class's own
   KDoc already says *"one instance per ClassLoader: a host with plugin loaders registers one mirror per
   loader"*. `@Reflect` classes (Java with `javac -parameters`, or Kotlin) become constructible;
   `@Service` parameters resolve from the `GraphEnvironment`. **The mirror is lazy**, so R4's boot
   validation (`ServiceEnvironmentValidation` iterates `ReflectionRegistry.global` — the generated
   registry only) does *not* cover plugin classes; a malformed class or a missing `@Service` surfaces when
   notation first references it, and E3's view shows it then (review 1's reduced promise). A Kotlin
   plugin *may* ship a KSP `ModuleReflection`, but a folder plugin cannot "call `register()`" on its own:
   the rule is a `ServiceLoader` provider for `ModuleReflection`, registered before the mirror so the
   generated path wins for the same class name. It gains nothing a Java plugin cannot do.
3. **Bundled notation.** `ClasspathNotationMedia` scans `notation/**` on the *context* classloader; make
   the loader set explicit (one scan per plugin loader, merged) so a folder plugin's
   `notation/auto-jvm/<plugin>/…` archetypes, ribbon tools and ready-made documents are discovered
   exactly as kzen-project's bundled samples are. Same `AutoConventions.serverAllowed` prefixes.

**Process-level runtime, not per-context loaders (review 1 — corrects the first re-elaboration).** The
extension universe is already process-global: `GlobalMirror.register(ReflectiveClassMirror.global)` runs
once in `KzenAutoContext`'s companion `init`, `ReflectionRegistry.global` is static, and
`ClassLoaderUtils.dynamicParentClassLoader()` is static. Per-context plugin loaders registering mirrors on
that global would register N copies for N contexts. So introduce a small **`KzenAutoRuntime`** (one per
JVM): plugin loaders, mirrors, reader discovery, notation loader set, expression classpath — initialized
**exactly once, before any context**, from `--plugin.root=` (default `<module root>/plugins`) by
`KzenAutoMain`, or by an embedding host with its own directories; a second initialization with a
*conflicting* configuration fails fast (CC-08), an identical one is a no-op so `forTest()` and the
many-contexts-per-JVM test suite keep working. Each subdirectory is one `URLClassLoader` over its
`*.jar`s in **deterministic order** (directories sorted by name, jars sorted by name), parent
kzen-auto-jvm's loader; never closed; restart to upgrade. Duplicate plugin ids, reader identities,
`@Reflect` class names across loaders and notation paths are **boot errors**; a broken plugin fails *its*
scope with a named diagnostic and does not hide the others. The runtime owns the list (`PluginScopes`:
the app loader + one per directory, each with id / version / path / status) that E3 renders. An optional
`META-INF/kzen/plugin.yaml` carries `id`, `version` and a **kzen plugin-SPI compatibility version or
range** (a boot-time compatibility error beats a later linkage failure) — metadata, never a class
allow-list; nothing in it is required. `META-INF/kzen/plugins.yaml` (the `ReportDefiner` class list) is
retired. A context is created *against* the runtime and owns only graph, host services, work roots,
controller and server.

**Expression-compiler classpath (the D8 enabler) — simpler than threading.** `FormulaSourceWorker`,
`FormulaWorker`, `FilterWorker`, `RunWorker`, `CsvWriterWorker`, `ExportWriterWorker`, `JobValidator`,
`ReportDocument` / `ReportRun` and `PluginDocument` all take `ClassLoaderUtils.dynamicParentClassLoader()`
directly. Because the loader set is process-global, that function can simply return the runtime's
**composite loader** (kzen-auto-jvm's loader as parent, then each plugin loader in order —
`ScriptKotlinCompiler` derives its classpath from the loader it is handed via `classpathFromClassloader`,
so a `URLClassLoader` chain works unchanged); **zero call-site changes**. Class identity is preserved — a
compiled script's loader delegates to the *same* plugin loader that served the mirror, never a second
copy; a name present in two plugins is a boot error above, so first-wins never silently applies. The
Spring Boot `LaunchedURLClassLoader` comment stays as the reason the in-process host uses plain jars.
After this, `ItchReader(Path.of(file))` from a folder plugin compiles in an expression.

**Java-friendly SPI (shape per review 1).** `kzen-auto-plugin` gains `BlockingReaderCapability`
(abstract; non-suspend `openBlocking` / `inspectBlocking`, the `suspend` pair implemented once on top)
and a **cursor-driven `SourceWorker`**: the Java subclass implements one non-suspend
`open(control): Iterator<T>` (closed if `AutoCloseable`); kzen owns the pulls (through
`JobControl.runBlockingIo`, so a pull that blocks on the host's memory arena stays visible to quiescence
detection), batching, checkpoints, cancellation and close. Checked: `Emitter.send` and
`JobControl.checkpoint` are `suspend` with no non-suspend forms, so the earlier "blocking
`produce(emit, control)`" cannot be written from Java. Close semantics for the cursor and its items are
E9's; this phase only wires the hook.

**Build discipline:** `:kzen-auto-plugin:publishToMavenLocal` before any non-composite consumer —
`../kzen-sample-plugin` above all. Any Kotlin *test* plugin lives in a **separate module** (the KSP2
test-source-set gotcha in Landed context).

**Verification — the acceptance criterion, exercised both ways:**
- **Pure Java, from a folder:** `../kzen-sample-plugin` (Java, Maven, `copy-dependencies`, *no shading*)
  installed as `plugins/kzen-sample-plugin/*.jar` under a kzen-project home contributes (a) the
  world-cities `BlockingReaderCapability` + probe — a `.txt.gz` selected in a File worker is detected and
  reads with the right columns; (b) an `@Reflect` Worker with a `@Service` parameter, found by its
  archetype's `is:` (CC-17) and usable from the ribbon; (c) a bundled document that runs. Zero kzen
  edits; `ReflectiveClassMirror` logs `Serving … by JVM reflection` for (b).
- **Kotlin with KSP, as a module:** a separate test-plugin module shipping a `ModuleReflection`, proving
  the generated path still wins over the mirror for the same class name.
- **Plugin zero:** the same sample plugin as a *Gradle dependency* of kzen-project-jvm (no folder)
  contributes identically — this is the embedded-host case.
- **Expression route:** a Job whose source expression constructs a plugin class and returns an
  `Iterable` of a Java record streams typed rows.
- **Determinism and isolation:** two plugin directories, one with an unopenable jar — the other still
  contributes and the runtime lists the failure by name; a duplicate reader identity across two
  directories is a boot error; a parent-loader provider is counted once; a second runtime
  initialization with a different root fails fast, an identical one is a no-op.
- **Plugin compatibility test kit (review 1):** a reusable entry point in `kzen-auto-plugin`'s test
  fixtures that takes a plugin directory and verifies loader creation, reader discovery, notation
  discovery, reflective construction, expression visibility, duplicate detection and expected
  diagnostics. The checks above are its first client; third-party authors get the same loop.
- `cd ../kzen-lib && ./gradlew build`, `cd ../kzen-auto && ./gradlew build`, `mvn verify` in the sample
  plugin, kzen-project `SampleExtensionTest` extended with the folder case.

---

## Phase E3 — plugin UX (D3 = not now, re-elaborated 2026-09-04)

**Goal:** a user can see what is installed, what it contributed, and what failed — without reading a
log. Installation itself stays a filesystem / dependency act (D3).

**Items:**
1. **`PluginDocument` becomes the read-only view** of the runtime's `PluginScopes`: one row per scope
   (id, version, SPI-compatibility, directory or "application classpath", status), and under it every
   contribution **discovered through an explicit protocol** — readers with their identities and probe /
   authoring faces, notation documents merged — plus the `@Reflect` classes the mirror has *actually
   been asked to resolve*, and every **failure**, named: a jar that would not open, a `ServiceLoader`
   provider whose constructor threw, a `@Reflect` class the mirror reported `Malformed` (no
   `-parameters`, ambiguous constructors), a `@Service` type missing from the environment, a notation
   document rejected by the `serverAllowed` filter, an SPI-version mismatch. **The promise is
   deliberately smaller than "everything in the jar" (review 1):** the mirror is lazy, so an
   unreferenced class does not appear, and a malformed one appears after notation references it. No
   class index or classpath scan exists solely for this screen. The `jarPath` attribute is retired with
   the loading it drove.
2. **Listing served from the runtime's cached state**, computed at initialization and appended to as
   the mirror resolves classes — never re-scanned per request (the analysis's P4). The `System.gc()`
   jar-unlock nudge goes with the ephemeral loaders.
3. **`--plugin.root=`** surfaced in `KzenAutoConfig`'s CLI parsing beside `--module.root=`; the
   kzen-launcher / kzen-shell child command lines pass it through unchanged (verify they do not need
   to — the default is under the module root).
4. **Do not preclude upload.** Keep the directory contract and the load-once lifecycle; a later
   "upload a jar set" is then "write files into a new plugin directory + show restart-to-apply".
   Nothing in this phase may assume the loader set is authored only by hand.
5. **Docs:** kzen-auto `docs/architecture.md` §8 rewritten from the JAR-path / `ReportDefiner` model to
   plugin = loader; `../kzen-sample-plugin/README.md` rewritten around the folder install and the
   two-tier story; umbrella `AGENTS.md` plugin-publish gotcha re-checked.

**Verification:** with the sample plugin installed, the Plugin document lists its loader, its reader,
its Worker and its documents; delete `-parameters` from the plugin build and the document names the
class and the reason; remove a jar the plugin needs and the loader row shows the failure without taking
the other plugins down. `PluginReportDefinitionRepositoryTest` is retired with the class it tests, or
rewritten against `PluginScopes`.

---

## Phase E4 — Custom power (C4, C6, D6) + the C7 document-rename gap

*D6 was not discussed at the 2026-09-04 E1 session — the recommendation (store keyed by stable id) stands as this phase's working design; C4/C6/C7 are settled findings and can proceed independently.*

**C7 is the one substantive defect in this plan and is worth doing first.**

- **C7 — document rename dangles nested exports (kzen-lib).** `RenameDocumentRefactorCommand`'s
  reference rewriting covers only **root** objects, so renaming a Custom document dangles every
  cross-document reference to its (nested) exports. The regression test is **already committed,
  `@Ignore`d**: `kzen-auto-jvm/src/test/.../custom/CustomExportsRenameTest.kt:71`. The fix is in
  kzen-lib (`NotationReducer` + `NotationCommand`, with `RenameDocumentRefactorTest` in
  kzen-lib-jvm as the natural home for a lib-level regression). **Landing it = removing that
  `@Ignore`.** Note the related known limitation: a rename refactor does **not** cascade to a
  directory's children — that is a separate, deliberate gap; do not conflate them.
  Requires `publishToMavenLocal` before kzen-auto picks up the fix.
- **C4 — prototype metadata for the picker.** Prototypes currently present as bare names; carry a
  `description:` (the bundled `Custom.yaml` sample already demonstrates the shape after S10) into the
  picker UI.
- **C6 — per-tag affordance registry seam.** The in-tree seam that keeps D7's future open: a
  registry mapping a notation-declared tag to a card affordance, so a plugin can pick an existing
  affordance declaratively instead of shipping JS.
- **D6 — run-result persistence** per E1's verdict (recommended: a store keyed by stable id, so
  results survive navigation; no server change).

**Verification:** `CustomExportsRenameTest` un-`@Ignore`d and green, plus the kzen-lib-level test;
`./gradlew build` in kzen-lib then kzen-auto; manual Custom-document pass (add-from-prototype,
toggle export, run detached + task, Raw round-trip, navigate away and back).

---

## Phase E5 — ObjectRegistry disposition (D4) — moot (2026-09-04)

`ObjectRegistryScan`, its cache test and the document type are no longer in the tree (last touched by
"Job: data source progress"); `FormulaStep`'s whitelist sourcing went with them. What remains is a doc
grep for `ObjectRegistry` across the umbrella and sibling docs, removing stale mentions. No session.

---

## Phase E7 — plain-object data shape (D9)

**Goal:** a plain Java or Kotlin class — never written for kzen, no annotations, no wrapper — is a typed,
shape-aware value in a Job, at design time as well as at run time.

**What already exists (kzen-lib-jvm, verified 2026-09-04):** `DefaultDataAdapterRegistry` treats Java
records and Kotlin data classes as built-in; `DefaultNativeTypeResolver` describes them as
`DataType.Record` with one typed `DataField` per component, recursively (nested records nest; a cycle
degrades to Opaque), `List` → Listing, `Map` → Mapping, scalars for every integer width,
`BigInteger` / `BigDecimal`, `String`, `ByteArray`, `LocalDate` / `LocalTime` / `Instant` / `Duration`,
`UUID`; `NativeObjectValueAccess` navigates lazily and reads through `NativePropertyPlans`, which
caches one reader plan **per class**. An explicit `ExactDataAdapter` / `CapabilityDataAdapter` SPI covers
anything else.

**Items (kzen-lib-jvm unless noted):**
1. **Ordinary classes by convention.** Extend the resolver's `isRecord` / `isData` branch and
   `NativePropertyPlans.create` (today: *"limited to Kotlin data classes and Java records"*) with the
   JavaBeans shape: public no-arg `getX()` / `isX()` and public fields are fields; order = declaration
   order then alphabetical (reflection guarantees neither — state the rule); nullability from
   `@Nullable` / `@NonNull` (JSpecify and JetBrains) when present, otherwise every reference-typed field
   is optional; `getClass` excluded; superclass properties included; a getter that throws is a
   `DataAccessException` naming the field, not a run crash. **S.**
2. **Enums → `ScalarKind.Text`** (the constant name), in both describe and lift. **XS.**
3. **`Set` accepted as an unordered Listing** (iteration order, documented as unstable) in describe,
   lift and `isRefusedAutomaticType`; `Sequence` / `Iterator` stay refused as *values*. A *top-level*
   `Set` returned by an expression source is **not a resumable stream** — E9 item 1 (review 1). **XS.**
4. **Per-class native-token cache.** `nativeToken` computes `it::class.starProjectedType` for every child
   value; cache the `KType` per `Class`. **XS**, then measure (P1 in the analysis) on a real ITCH day.
5. **Recursive type references.** A recursive class model (`Order.executions[].order`) currently
   describes the recursive occurrence as Opaque, which stops a *design-time* path there. Add a named
   type reference to the contract so a picker can descend on demand while the description stays finite.
   **This touches `DataType` in kzen-lib-common** (shared with JS) — coordinate with the data-model
   plan's owner rows before changing the sealed hierarchy; a `Reference(name)` variant plus a
   definitions map on `DataContract` is the least invasive shape. **M.**
6. **Design-time shape in kzen-auto.** `JobExpressionCompiler.compile` derives the inferred type's
   contract through the common `TypeMetadata.toDataContract()` (scalars, List, Map only), so a
   record-typed stream is Opaque to the editor while run time lifts it as a Record. On the JVM, describe
   the inferred `KType` through the adapter registry instead (`JobDataValues` already owns one) — the
   editor's worker card and payload-type walk then show the class's columns before the first run. **S.**

**Verification:** kzen-lib `DefaultDataAdapterRegistryTest` extended for each of 1–5 (a POJO with
getters and public fields, an enum field, a `Set` field, a self-referential class); kzen-auto: a Job
whose source expression returns `List<SomePojo>` shows typed columns in the worker card *before* running
and produces them when run; `cd ../kzen-lib && ./gradlew build` → `publishToMavenLocal` →
`cd ../kzen-auto && ./gradlew build`.

---

## Phase E8 — object-graph paths: projection / unnest Worker + path picker

**Goal:** report over an object graph without code — pick paths, get columns, explode nested lists.

Filter and Formula already see the whole native object in Kotlin (`it.executions.sumOf { e -> e.qty }`
works today), but aggregate and the CSV / export writers need **flat columns**. Add:
1. A **path-projection Worker**: notation lists paths over the incoming record contract
   (`instrument.symbol`, `executions[*].price`, `executions[*].trade.venue`); the output contract is a
   flat Record of those leaves; a `[*]` segment **unnests** — one output row per element, the other
   columns repeated; several `[*]` on the same list share one iteration, on different lists produce
   the cross product (state the rule; reject ambiguous mixes at validation). Reads through
   `ValueAccess.field` / `element` / `entry`, so it is lazy and allocation-light. **M.**
2. A **design-time path picker**: the attribute editor walks the upstream contract (E7's recursive
   references make that finite) and offers leaves and `[*]` lists; generic-editor vocabulary per
   `2026-08-21_extension-points.md` §2.1 — no plugin JS. **S–M.**

**Verification:** a Job over the sample plugin's ITCH domain (`Order` → `Execution` → `Trade`) projects
`symbol, executions[*].price, executions[*].qty` → aggregate by symbol → CSV, with the sum equal to a
direct Kotlin fold over the same objects; the picker offers exactly the leaves the contract has.

---

## Phase E9 — closeable streams and items (resource-owning data)

**Goal:** a stream that owns a resource, and an *item* that owns a resource, are closed by the framework
at a defined moment — on every route into a Job. **Why it is a user requirement (2026-09-04):** the
in-process host enforces its global memory limit *through item lifetimes* — a market-data day is indexed
and grouped by symbol, each symbol-day is loaded as a batch that consumes the memory arena, and closing
it releases the arena. kzen needs no admission concept as long as it honours `AutoCloseable` with
defined timing; without this phase it would hold the arena until the run ends.

**What exists:** `DataCursor` is `Iterator<DataValue> + AutoCloseable`, and `DataReadCore` /
`ReadWorker` already close it on settle and **detach / re-adopt it across a live-edit migration**
(`DetachedCursor`, adoption identity). `FormulaSourceWorker` closes nothing, and resumes a live edit by
re-evaluating the expression and skipping the delivered prefix (review 1). Channels move `DataValue`s in
batches (`JobChannel`, `batchSize`), and `drainBuffered` / `preload` carry in-flight elements across a
migration. No `DataValue` has a lifecycle today.

**Items (kzen-auto-jvm unless noted):**
1. **Streams.** Add `java.util.stream.Stream` as a fourth stream type in `ExpressionReturnTypeInference`
   (`Files.lines(...)`-style Java APIs become sources in one change). For `Iterable` / `Iterator` /
   `Sequence` / `Stream`: close the iterator, then the stream object, whichever is `AutoCloseable`, on
   completion, cancellation and failure. A **closeable stream is detached and re-adopted across
   migration** exactly like `DataReadCore`'s cursor — never re-evaluated-and-skipped (that would open the
   resource twice); a non-closeable stream keeps skip-resume; a top-level `Set` is **not resumable**
   (restart on edit — its order is not stable). **S–M.**
2. **Closeable elements — the ledger.** One `CloseableLedger` per run, keyed by the *native object's
   identity* (`IdentityHashMap`; wrappers can be recreated, the resource cannot). An entry is created
   when `JobDataValues.lift` sees an `AutoCloseable` native, and every `DataValue` lifted from it carries
   an **owner handle**. Ownership is a **reference count over channel hand-offs**:
   - `ChannelOutput.send` of an owned value: **+1 per channel** (a Worker with two outputs counts twice;
     fan-in producers each count their own send);
   - the consumer **moves past the element**: **−1**. Not when the element *leaves* the channel
     (`receive` — the Worker has not read it yet) but when the Worker is **done with it**, which the
     framework observes as the Worker pulling the *next* element, or `hasNext` returning false at
     end-of-stream. Implemented inside the channel's consumer endpoint (`ChannelInput`'s iterator
     decrements the element it returned previously on each `next()`), so no Worker cooperation is
     needed; per element, not per batch, so the close follows the consumer's cursor;
   - zero → `close()`, entry removed; a later read through `NativeObjectValueAccess` (kzen-lib-jvm) is a
     named `DataAccessException`, never a silent read;
   - `drainBuffered` / `preload`: **unchanged** — the ledger is per run, not per graph instance, and a
     carried element is still "in a channel";
   - run teardown, cancel, failure: every outstanding entry closed, best-effort (every close attempted,
     first exception rethrown after all).

   One hop, spelled out — source → channel A → Worker X → channel B → writer:

   | Step | Count |
   |---|---|
   | source sends the item to A | 1 |
   | X receives it from A | 1 (no change) |
   | X sends it, or a non-scalar derivative, to B | 2 |
   | X pulls its next element from A | 1 |
   | writer receives it from B and writes it | 1 (no change) |
   | writer pulls its next element from B, or hits end-of-stream | 0 → `close()` |

   Had X emitted only a scalar, step 3 would not count and the close would fire at step 4, right after X
   moved on. The single assumption is item 7's contract: a Worker does not hold the element after pulling
   the next one. **M.**
3. **Aliasing — owner propagation (the real design question).** A count on the top-level element is not
   enough: a Formula returning `it.orders` hands downstream a `List` that *lives inside* the owned object,
   and a fresh lift would give it no owner, so the parent would close while a child is in flight. Two
   rules: (a) **navigation inherits** — a child produced through `ValueAccess.field` / `element` / `entry`
   carries the parent's owner (free: children are created from the parent lazily); (b) **expression
   outputs inherit conservatively** — for the per-element Kotlin Workers (Formula, Filter) a
   **non-scalar output inherits the input's owner** (the expression may have returned anything reachable
   from its input); scalars never inherit [decided 2026-09-04, user]. Workers that construct fresh values
   by design — aggregate, path projection (E8), the writers — produce unowned outputs. Erring this way
   keeps an item alive slightly longer and never closes it early. **S.**
4. **Flush on send.** A producer holds elements in `pending` until the batch is full; with an arena
   behind the source, item 1 would sit unflushed while the source blocks loading item 2 on a permit that
   only item 1's close can release — a deadlock the framework would have caused. So an owned element
   **flushes immediately on send**; the open-item bound is then tight: at most one in flight per hop plus
   what each stage is currently processing. Document that bound as the arena capacity a host must
   provide. **XS.**
5. **Accumulating Workers — help the user debug, do not add rules [decided 2026-09-04, user].** Sort,
   Pivot and Summary buffer the whole stream until end-of-stream; owned elements flowing into one stay
   open until the source finishes, and a day larger than the arena then blocks the source on a permit
   only the accumulator's completion would release. That is inherent to native resources in a pipeline,
   not incidental complexity, so no validation rule: the ledger instead **surfaces its state** — open-item
   count and the Worker(s) currently holding each item in the run's progress publication, and a stall
   diagnostic (source parked in `runBlockingIo` while owned items are held by an accumulating Worker)
   naming the holder in the log and the run status. **S.**
6. **Route independence.** The same ledger serves `DataCursor` items (`ReadWorker`), the cursor-driven
   Java `SourceWorker` (E2), host-object `@Service` sources and expression streams — one test fixture,
   four entry points. **S.**
7. **Worker contract, documented:** a Worker must not retain a closeable native beyond the element it
   is currently processing; anything it needs later it copies (a scalar carries no owner, so copying
   *is* projecting to scalars). Stated in `SourceWorker` / `TransformWorker` KDoc and in
   `architecture.md` §8.

**Self-regulation (why no admission logic is needed).** With flush-on-send, the host's `next()` blocks on
its own semaphore inside `runBlockingIo`, downstream stages keep draining and closing, and permits come
back; stage 2 processes batch N while the source loads N+1 if the arena has room for both, and simply
waits if not. The one unrecoverable case — a single item larger than the arena — is the host's to size.
Rejected alternatives: close when the source moves on (downstream still reads it); close on garbage
collection via `Cleaner` (the permit must come back promptly and deterministically).

**Verification:** a fixture `Iterable<AutoCloseable>` source counts opens / closes — equal after a
completed run, after cancel, after a failure mid-stream, and after a pause → edit-an-unrelated-worker →
continue migration (with no re-open); a top-level `Set` source restarts on edit; a `Stream` source closes
its `BaseStream`; a Filter → CSV lane closes each element exactly once after the writer moves past it;
a Formula returning `it.orders` (non-scalar) keeps the parent open until the consumer of *that* value
moves past it, while a Formula returning `it.symbol` (scalar) does not; a post-close field read names
the field; a fixture with a 2-permit arena and a Sort downstream stalls with the diagnostic naming the
Sort, and the same lane with a projection to scalars before the Sort completes. Sample plugin: the
`SymbolDay` route holds at most one item in flight per hop, measured (P1 in the analysis).

---

## Phase E6 — DataSchema gate (D5) — absorbed by DS6 (2026-08-24)

The reopening trigger arrived before E1: DS6 supplied the first real field/type-schema consumer.
`DataFormat` was renamed to `DataSchema` and is now the nullable strong structural declaration read by
`FileDataSource.staticShape`; its `TypeMetadata` survives for later typed-lane work. DS6's source/schema
closure tests, full JVM/JS gate and browser acceptance satisfy this phase, so no separate E6 execution
remains. D7 stays parked under the existing R6 verdict.

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| E1 — ratification | decision | **done 2026-09-04** | none | — |
| E2 — plugin = classloader | kzen-lib-jvm (mirror per loader) + kzen-auto (`KzenAutoRuntime`) + kzen-auto-plugin + sample plugin | L | medium | HS Java 25 baseline (the sample plugin cannot run otherwise) |
| E3 — plugin UX | kzen-auto (jvm + js) + docs | M | low | E2 |
| E4 — Custom power + C7 | kzen-lib + kzen-auto | M | low-medium | C7 independent |
| E5 — registry disposition | docs only | XS | none | — |
| E6 — DataSchema gate | absorbed by DS6 | complete | none | DS6 |
| E7 — plain-object data shape | kzen-lib-jvm (+ one `DataType` change in common) + kzen-auto | M | medium (item 5 touches the shared sealed type) | — (item 6 needs nothing from E2) |
| E8 — object-graph paths | kzen-auto (jvm + js) | M | medium | E7 |
| E9 — closeable streams and items | kzen-auto-jvm (channel ledger, `FormulaSourceWorker`, inference) + kzen-lib-jvm (post-close guard) | M–L | medium (touches `JobChannel` migration carryover) | — (E2's cursor hook is its second client, not a prerequisite) |

**E2 → E3** and **E7 → E8** are two independent spines, and **E9** is a third (it shares files with
neither — it is channel and source lifecycle). E2, E7 and E9 can run in parallel. The `kzen-sample-plugin`
rewrite in the in-process-hosting analysis rides on E2 (folder install, `BlockingReaderCapability`), E7
(the ITCH records' columns at design time) and E9 (the `SymbolDay` arena route); its object-graph Job
rides on E8. The in-process host's memory governance needs **only E9** from kzen. **E4's C7 half is independent of
everything** and remains the highest-value single item outside the spines.

## Verification baseline for the cluster

Per the analysis: `./gradlew build` (all modules, KSP regen included), plus `:kzen-auto-jvm:test`
for the Script tests that transit `ObjectRegistryScan` (`FormulaStepTest` — also the Kotlin
type-inference canary, see `kzen-auto/AGENTS.md`), plus a manual `FrontendDevelopment` smoke of each
of the four Customize-group documents. `selfTest` does not drive these document types directly — it
is a broad regression net only (mind the stale-tester-on-18081 footgun). **Plugin-path changes need a
manual check with `../kzen-sample-plugin` built and installed under `plugins/` (before E2 lands: registered
via a Plugin document).**
