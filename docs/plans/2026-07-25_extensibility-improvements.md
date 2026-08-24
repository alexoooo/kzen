# Third-party extensibility — plugin registration, plugin UX, Custom power (E1–E6)

> **Status: ratification pending.** Promotes `sprint-2/2026-07-06_custom-plugin-extensibility-analysis.md`
> from analysis to plan format (as the Sprint-2 master plan called for), and **merges in the open
> tail of `sprint-2/2026-07-18_reflection-improvements.md`** — R5 *is* the reflection half of D1,
> so they are one arc, not two plans. Executor: **Opus-class, one phase per session**, except E1,
> which **needs the user** — it is a decision session, not a build session.
>
> **E1 gates E2–E5.** Those phases carry the analysis's recommendations as their working design and
> remain provisional until E1 ratifies. E6 was independently absorbed by DS6 once its real consumer
> arrived; do not start E2 before E1.
>
> **Progress tracker** (update as phases land):
> - [ ] E1 — ratification: D1–D6 + gate R5-G (**decision session; needs the user**)
> - [ ] E2 — plugin module registration (D1) + dynamic reflection (**was R5**)
> - [ ] E3 — plugin UX: isolation (D2), JAR upload (D3), listing from repository cache, per-definer diagnostics
> - [ ] E4 — Custom power: prototype metadata (C4), per-tag affordance registry (C6), run-result persistence (D6), the C7 document-rename gap
> - [ ] E5 — ObjectRegistry disposition (D4)
> - [x] E6 — DataSchema gate (D5) — **absorbed by DS6 on 2026-08-24; real consumer landed**
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

## Landed context — what E1–E6 stand on

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

## Phase E1 — ratification (decision session; needs the user)

**This session produces decisions, not code.** Work through each item, record the verdict and its
rationale **in this file** as the as-built, then unblock E2–E6.

| ID | Decision | Recommendation carried from the analysis |
|---|---|---|
| **D1** | Plugin module registration — adopt plugin-shipped KSP `ModuleReflection` + bundled archetype notation, registered at plugin load? | **Yes**, with **load-once-per-boot / restart-to-upgrade** lifecycle stated up front. Acceptance: the sample plugin contributes an `@Reflect` step/prototype with **zero kzen-source edits**. Reshapes D2–D4. |
| **R5-G** | Plugin classloader lifecycle. Today's loaders are deliberately **ephemeral** (`PluginDocument` / `PluginReportDefinitionRepository` open-and-close via `.use {}`, plus a `System.gc()` jar-unlock nudge, fresh loader per report run). Registering constructor lambdas into the process-global registry **pins the classloader for JVM life.** | **Pinned boot-time load + restart-to-upgrade**, with `.use{}` explicitly retired for registered plugins (the report-definer path may keep it until it too migrates). ⚠️ This interacts with the **Windows jar-lock behaviour the `.use{}` pattern existed for** — that is the real risk in the whole arc. Ratify **together with D1.** |
| **D2** | Isolation unit for multi-jar support. | Per-`PluginDocument` `URLClassLoader` (vs today's per-repository merge + cross-repo chaining). If D1 lands with boot-time loading, the loader set is fixed at boot and this simplifies further. |
| **D3** | JAR as document resource (upload UX). | Reuse `/command/resource/add` so the JAR lives in the document, vs keeping a server path with better validation. Interacts with D1 lifecycle — a resource edit implies restart-to-apply messaging in the UI. |
| **D4** | `ObjectRegistry` disposition. | (a) auto-derive the type-inference whitelist from D1-registered plugin modules + host introspection and **retire** the document type; (b) keep it as a manual "extra host-classpath types" escape hatch with an honest rename/description; (c) status quo + docs fix. **Recommend (a) if D1 lands, else (b).** Either way delete the redundant bundled `IntRange` registration. |
| **D5** | `DataFormat` disposition. | (a) consumer-first rework — pick the first real consumer (Report input `dataType`, Job channel `elementType`, or Script tuple/record types) and spec DataFormat as the dynamic record schema they reference; (b) **formally park/retire until that consumer is concrete — recommended**, with the consumer choice recorded as the reopening trigger. *"Redesigning a schema document before a consumer exists is how it got here."* |
| **D6** | Custom run-result persistence. | Keep transient component-held results (documented), move detached/task results into a store keyed by stable id (survives navigation), or full trace-store integration like Script/Flow. **Recommend the middle option** — cheap, matches user expectation, no server change. |
| **D7** | Plugin custom client UI. | **Already decided — park** (see the tracker's R6 entry). No discussion needed unless reopening. |

**Verification:** every row above has a recorded verdict; E2–E6's provisional markers are removed or
their phases rescoped/dropped accordingly.

---

## Phase E2 — plugin module registration + dynamic reflection (D1 + R5)

*Provisional until E1.* **Risk: high** (lifecycle change; classloader pinning vs the Windows
jar-lock behaviour).

**Goal:** a plugin JAR contributes notation-instantiable `@Reflect` classes — Script steps, Job
Workers, Flow vertices, Custom prototypes — with zero kzen-source edits. This is the reflection
mechanics; plugin *UX* is E3.

**Design decisions (updating EXT D1 by reference):**
- **Kotlin plugins:** the JAR ships its own KSP-generated `ModuleReflection` (the plugin build
  applies `kzen-lib-reflect-ksp` with its own `moduleClassName`), named in `META-INF/kzen/plugins.yaml`
  alongside/instead of definers. The server instantiates it from the plugin classloader and calls
  `register()` into `ReflectionRegistry.global` at plugin load. Archetype YAML ships as bundled
  notation in the JAR, merged via the existing classpath-overlay `ReadWriteNotationMedia`.
- **Java/Maven plugins (the actual `kzen-sample-plugin` shape): no KSP required at all.** With R1,
  `@Reflect`-annotated classes listed in `plugins.yaml` resolve through the reflective mirror — the
  mirror just needs to consult the plugin classloader (extend `ReflectiveClassMirror` with
  additional-classloader registration, or register a per-plugin-loader mirror instance at load). No
  classpath-scanning dependency; the `plugins.yaml` list stays the explicit manifest. **This removes
  D1's implicit Kotlin+KSP imposition on third parties.**
- Registered plugin classes' `@Service` params resolve from the same `GraphEnvironment`, so **R4's
  boot validation extends to plugin modules for free** — provided plugin load happens before it.
- Lifecycle per R5-G's ratified verdict.

**Build discipline:** `:kzen-auto-plugin:publishToMavenLocal` must run before any non-composite
consumer picks up new SPI bytecode — including `../kzen-sample-plugin`.

**Verification:** the acceptance criterion, exercised **both ways** — a Kotlin test plugin with a KSP
`ModuleReflection`, and the pure-Java `../kzen-sample-plugin` via the R1 reflective path — each
contributing a working `@Reflect` Script step / Custom prototype usable from notation with zero
kzen-source edits. Plus: `./gradlew build` both repos, and a manual check that a plugin JAR can still
be replaced after a restart (the jar-lock question).

---

## Phase E3 — plugin UX (D2, D3)

*Provisional until E1.*

**Goal:** make plugins installable and diagnosable by a user rather than by a filesystem.

**Items:**
1. **Isolation per D2** — per-`PluginDocument` `URLClassLoader` if ratified; if D1's boot-time
   loading landed, the loader set is fixed at boot, which simplifies the lifecycle considerably.
2. **JAR upload per D3** — reuse `/command/resource/add` so the JAR lives in the document. Add the
   restart-to-apply messaging the D1 lifecycle implies.
3. **Listing served from the repository cache** rather than recomputed per request (the analysis's
   P4). Note S2 already assigns `cachedStructureDigest` **only where the definer cache is complete**,
   so an unloadable jar keeps retrying — preserve that property.
4. **Per-definer diagnostics** — when a JAR loads but a definer fails, say which one and why, on the
   document, instead of failing the whole repository silently.

**Verification:** upload a JAR through the UI → its archetypes appear → a step/prototype from it is
insertable; break a definer in the JAR and confirm the diagnostic names it;
`PluginReportDefinitionRepositoryTest` extended.

---

## Phase E4 — Custom power (C4, C6, D6) + the C7 document-rename gap

*D6 provisional until E1; C4/C6/C7 are settled findings and can proceed independently.*

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

## Phase E5 — ObjectRegistry disposition (D4)

*Provisional until E1.* Execute the ratified option; migrate `FormulaStep`'s whitelist sourcing
accordingly, and delete the redundant bundled `IntRange` registration either way.

**Verification:** `:kzen-auto-jvm:test --tests "*FormulaStepTest"` — the type-inference canary — plus
`ObjectRegistryScanCacheTest`.

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
| E1 — ratification | decision | one session **with the user** | none | — |
| E2 — module registration + R5 | kzen-lib + kzen-auto + sample plugin | L | **high** | E1 |
| E3 — plugin UX | kzen-auto (jvm + js) | M | medium | E1, E2 |
| E4 — Custom power + C7 | kzen-lib + kzen-auto | M | low-medium | E1 (D6 only); C7 independent |
| E5 — registry disposition | kzen-auto | S | low | E1, E2 |
| E6 — DataSchema gate | absorbed by DS6 | complete | none | DS6 |

**E1 → E2 → E3/E5** is the spine. **E4's C7 half is independent of everything** — it can run any
time, including before E1, and is the highest-value single item outside the spine.

## Verification baseline for the cluster

Per the analysis: `./gradlew build` (all modules, KSP regen included), plus `:kzen-auto-jvm:test`
for the Script tests that transit `ObjectRegistryScan` (`FormulaStepTest` — also the Kotlin
type-inference canary, see `kzen-auto/AGENTS.md`), plus a manual `FrontendDevelopment` smoke of each
of the four Customize-group documents. `selfTest` does not drive these document types directly — it
is a broad regression net only (mind the stale-tester-on-18081 footgun). **Plugin-path changes need a
manual check with `../kzen-sample-plugin` built and registered via a Plugin document.**
