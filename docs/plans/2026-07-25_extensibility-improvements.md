# Third-party extensibility — plugin registration, plugin UX, Custom power, plain-object data (E1–E8)

> **Status: E1 ratified 2026-09-04; E2/E3 re-elaborated; E7/E8 added.** Promotes
> `sprint-2/2026-07-06_custom-plugin-extensibility-analysis.md` from analysis to plan format, and
> **merges in the open tail of `sprint-2/2026-07-18_reflection-improvements.md`** — R5 *is* the
> reflection half of D1, so they are one arc, not two plans. Executor: **Opus-class, one phase per
> session**.
>
> **The E1 decision session happened on 2026-09-04**, driven by
> `docs/analysis/2026-09-03_in-process-hosting.md` §6a (a Spring host embedding kzen, and a substantive
> `kzen-sample-plugin` over NASDAQ ITCH order-level data — both of which need a plugin system that is
> *general and simple*). Its verdicts are the as-built in Phase E1 below; E2 and E3 were rewritten to
> them, E5 turned out moot, and two phases the session surfaced were added: **E7** (plain Java classes
> as typed data — no annotations, no wrappers) and **E8** (object-graph paths in a Job).
>
> **Progress tracker** (update as phases land):
> - [x] E1 — ratification: D1–D7 + gate R5-G — **ratified 2026-09-04 (user); verdicts below**
> - [ ] E2 — plugin = classloader: directory discovery, `ServiceLoader` + mirror + notation per loader, expression-compiler loader threading, Java-friendly SPI adapters (**was R5 + D1 + D2**)
> - [ ] E3 — plugin UX: `PluginDocument` as the diagnostics view, `--plugin.root=`, listing from cache, per-contribution diagnostics (**D3 = not now, do not preclude**)
> - [ ] E4 — Custom power: prototype metadata (C4), per-tag affordance registry (C6), run-result persistence (D6), the C7 document-rename gap
> - [x] E5 — ObjectRegistry disposition (D4) — **moot; `ObjectRegistryScan` left the tree during the Job data-source work. Closes with a doc grep**
> - [x] E6 — DataSchema gate (D5) — **absorbed by DS6 on 2026-08-24; real consumer landed**
> - [ ] E7 — plain-object data shape (D9): ordinary classes by convention, enums, `Set`, design-time shape through the adapter registry, per-class token cache, recursive type references
> - [ ] E8 — object-graph paths: path-projection / unnest Worker + design-time path picker
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
jar-lock) is gone with R5-G; what remains is *threading one more classloader* through every place that
currently assumes kzen-auto-jvm's own.

**Goal:** a plugin — a directory of jars, or the application classpath itself — contributes readers,
`@Reflect` objects (Job Workers, Script steps, Flow vertices, Custom prototypes) and notation, with zero
kzen-source edits and no KSP. Plugin *UX* is E3.

**The one concept.** A plugin **is** a classloader. Discovery runs the *same* three channels over every
loader, the application loader included (D10):

1. **`ServiceLoader`** for SPI capabilities: `ReaderCapability` (with its `ReaderProbeCapability` /
   `FormatAuthoringCapability` faces), already discovered this way from the context classloader by
   `ReaderCapabilityRegistry.withConfiguredReaders()` — extend to iterate every plugin loader.
   `ReportDefiner` is **not** discovered from plugins any more (Job replaces Report); the built-in
   definer repository is untouched.
2. **A `ReflectiveClassMirror(loader)` registered on `GlobalMirror`** per plugin loader — the class's own
   KDoc already says *"one instance per ClassLoader: a host with plugin loaders registers one mirror per
   loader"*. `@Reflect` classes (Java with `javac -parameters`, or Kotlin) become constructible;
   `@Service` parameters resolve from the `GraphEnvironment`; **R4's boot validation covers them for
   free** provided plugin load precedes it. A Kotlin plugin *may* additionally ship a KSP
   `ModuleReflection` and call `register()`; it gains nothing a Java plugin cannot do — it is only the
   generated-vs-reflective difference kzen-auto's own modules already have.
3. **Bundled notation.** `ClasspathNotationMedia` scans `notation/**` on the *context* classloader; make
   the loader set explicit (one scan per plugin loader, merged) so a folder plugin's
   `notation/auto-jvm/<plugin>/…` archetypes, ribbon tools and ready-made documents are discovered
   exactly as kzen-project's bundled samples are. Same `AutoConventions.serverAllowed` prefixes.

**Discovery and lifecycle.** `KzenAutoConfig.pluginRoot: Path` (CLI `--plugin.root=`, default
`<module root>/plugins`); each subdirectory is one `URLClassLoader` over its `*.jar`s, parent
kzen-auto-jvm's loader (`ClassLoaderUtils.dynamicParentClassLoader()`), created **once at context
creation**, before `ServiceEnvironmentValidation`; never closed; restart to upgrade. A context owns the
list (`PluginClassLoaders`: the app loader + one per directory, each with id / version / path), and that
is what E3 renders. An optional `META-INF/kzen/plugin.yaml` carries `id` and `version` for diagnostics;
nothing in it is required. `META-INF/kzen/plugins.yaml` (the `ReportDefiner` class list) is retired.

**Expression-compiler threading (the D8 enabler).** `FormulaSourceWorker`, `FormulaWorker`,
`FilterWorker`, `RunWorker`, `CsvWriterWorker`, `ExportWriterWorker`, `JobValidator`,
`ReportDocument` / `ReportRun` and `PluginDocument` all take `ClassLoaderUtils.dynamicParentClassLoader()`
directly. Route them through the context-owned composite (a parent-last-over-plugins loader, or the
plugin loaders as additional classpath entries — `ScriptKotlinCompiler` derives its classpath from the
loader it is handed via `classpathFromClassloader`, so a `URLClassLoader` chain works unchanged). After
this, `ItchReader(Path.of(file))` from a folder plugin compiles in an expression. Keep
`dynamicParentClassLoader()` as the *parent*, not the composite — its comment about Spring Boot's
`LaunchedURLClassLoader` is one more reason the in-process host uses plain jars.

**Java-friendly SPI.** `kzen-auto-plugin` gains `BlockingReaderCapability` (abstract; non-suspend
`openBlocking` / `inspectBlocking`, the `suspend` pair implemented once on top) and a blocking
`SourceWorker` variant (`produceBlocking(emit, control)` — check first that `Emitter.send` and
`JobControl.checkpoint` have non-suspend or `runBlockingIo`-wrapped forms a Java caller can use).

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
- `cd ../kzen-lib && ./gradlew build`, `cd ../kzen-auto && ./gradlew build`, `mvn verify` in the sample
  plugin, kzen-project `SampleExtensionTest` extended with the folder case.

---

## Phase E3 — plugin UX (D3 = not now, re-elaborated 2026-09-04)

**Goal:** a user can see what is installed, what it contributed, and what failed — without reading a
log. Installation itself stays a filesystem / dependency act (D3).

**Items:**
1. **`PluginDocument` becomes the read-only view** of the context's `PluginClassLoaders`: one row per
   loader (id, version, directory or "application classpath"), and under it every contribution —
   readers with their identities and probe / authoring faces, `@Reflect` classes the mirror served,
   notation documents merged — plus every **failure**, named: a jar that would not open, a
   `ServiceLoader` provider whose constructor threw, a `@Reflect` class the mirror reports as
   `Malformed` (no `-parameters`, ambiguous constructors), a `@Service` type missing from the
   environment, a notation document rejected by the `serverAllowed` filter. The `jarPath` attribute is
   retired with the loading it drove.
2. **Listing served from the context**, computed once at load and re-read on request — never
   re-scanned per request (the analysis's P4). The `System.gc()` jar-unlock nudge goes with the
   ephemeral loaders.
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
rewritten against `PluginClassLoaders`.

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
   lift and `isRefusedAutomaticType`; `Sequence` / `Iterator` stay refused as *values*. **XS.**
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
| E2 — plugin = classloader | kzen-lib-jvm (mirror per loader) + kzen-auto + kzen-auto-plugin + sample plugin | L | medium | HS Java 25 baseline (the sample plugin cannot run otherwise) |
| E3 — plugin UX | kzen-auto (jvm + js) + docs | M | low | E2 |
| E4 — Custom power + C7 | kzen-lib + kzen-auto | M | low-medium | C7 independent |
| E5 — registry disposition | docs only | XS | none | — |
| E6 — DataSchema gate | absorbed by DS6 | complete | none | DS6 |
| E7 — plain-object data shape | kzen-lib-jvm (+ one `DataType` change in common) + kzen-auto | M | medium (item 5 touches the shared sealed type) | — (item 6 needs nothing from E2) |
| E8 — object-graph paths | kzen-auto (jvm + js) | M | medium | E7 |

**E2 → E3** and **E7 → E8** are two independent spines; E2 and E7 can run in parallel (they share no
files — E2 is loaders and discovery, E7 is the value model). The `kzen-sample-plugin` rewrite in the
in-process-hosting analysis rides on E2 (folder install, `BlockingReaderCapability`) and E7 (the ITCH
records' columns at design time); its object-graph Job rides on E8. **E4's C7 half is independent of
everything** and remains the highest-value single item outside the spines.

## Verification baseline for the cluster

Per the analysis: `./gradlew build` (all modules, KSP regen included), plus `:kzen-auto-jvm:test`
for the Script tests that transit `ObjectRegistryScan` (`FormulaStepTest` — also the Kotlin
type-inference canary, see `kzen-auto/AGENTS.md`), plus a manual `FrontendDevelopment` smoke of each
of the four Customize-group documents. `selfTest` does not drive these document types directly — it
is a broad regression net only (mind the stale-tester-on-18081 footgun). **Plugin-path changes need a
manual check with `../kzen-sample-plugin` built and registered via a Plugin document.**
