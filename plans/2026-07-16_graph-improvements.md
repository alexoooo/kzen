# Graph* (Notation / Definition / Instance) improvements — remaining phases (G3–G7)

> **Status: planned.** Successor to `sprint-1/2026-07-05_graph-improvements.md` (Sprint 1: G1–G2
> landed; this document carries the open tail G3–G7 forward, complete and self-contained —
> nothing here depends on the sprint-1 copy). Executor: **Opus 4.8 xhigh, one phase per
> session.** Each phase is self-contained: goal, design decisions (already made — do not
> re-litigate), concrete steps with file anchors, and verification. Phase IDs are stable across
> the sprint reorganization (G3 here = G3 everywhere).
>
> Companion plans: `2026-07-10_yaml-parser-strings-and-comments.md` (**must land before G7b** —
> shared `unparseDocument` touch-points; its one-time format churn precedes byte-identical
> segment preservation); `2026-07-16_master-plan.md` (sequencing).
>
> **Progress tracker** (update as phases land):
> - [x] Phase 3 — scoped instantiation + instance caching (Flow per-vertex, detached actions) —
>   **done 2026-07-19** (3a rescoped to survey-pin + measurement; 3b + 3c as planned)
> - [ ] Phase 4 — incremental define (per-object definition cache, opt-in SPI) — **gated on
>   measurement** (see phase header)
> - [x] Phase 5 — declarative notation binding + notation-driven logic marker — **done 2026-07-19**
>   (5b's marker already landed under CC-17 → reduced to a doc fix; 5a = NotationCodec layer + FilterSpec/PivotSpec port)
> - [ ] Phase 6 — error surface (`GraphInstanceAttempt`, structured definition failures)
> - [x] Phase 7 — reducer decomposition + format-preserving deparse (7b after the yaml plan) — **done 2026-07-19**

## Landed context (Sprint 1) — what G3–G7 can rely on

- **G1 ✓ 2026-07-12 — definition caching + hot-path correctness.** One `tryDefine` per notation
  version: `DirectGraphStore` holds a digest-keyed `GraphDefinitionAttempt` cache (the semantic
  command's old-notation define is a cache hit); `coalesce` is patched across edits (untouched
  documents keep object identity); `GraphCreator.constructionLevels` is Kahn leveling (O(V+E));
  create-time ambiguity and deep definer levels get named errors; `ReflectionRegistry` is
  synchronized via `platformSynchronized` expect/actual. Notable as-built fact: create-time
  ambiguity is only reachable via global-host resolution (host-document filtering either
  disambiguates or empties to the unsatisfied-set diagnostic).
- **G2 ✓ 2026-07-13 — closure content digest.** `GraphDefinition.transitiveClosure(locations)`
  and `transitiveDigest(documentPath | locations)` exist (ordered combine over closure members'
  notation digests; missing/synthesized members digest as null deterministically).
  `ServerLogicController`'s `baselineNotations`/`closureNotations` notation-map compare is
  retired — migration detection is a single `Digest` compare, since widened by script-plan S3
  (`LinkedLogicDocuments`) to span weakly-linked logic documents. `GraphDefinitionTransitiveTest`
  (kzen-lib-jvm) pins the digest semantics. **G3's caches key off these digests.**

The three-layer contract review context (crown jewels: meta-circular bootstrap, environment-free
cacheable definitions, persistent insertion-ordered collections, incremental metadata cache,
graceful degradation on broken notation) is unchanged from the original review — preserve all of
it. The still-open weaknesses this document addresses:

1. **Whole-graph instantiation where one object is needed** (→ G3). `FlowRun.createInstance`
   (`kzen-auto-jvm/.../server/exec/flow/FlowRun.kt:434-441`) builds
   `filterTransitive(documentPath)` per vertex execution; `ModelDetachedExecutor` /
   `ModelTaskRepository` (`ModelDetachedExecutor.kt:31-56`, `ModelTaskRepository.kt:129-136`)
   build the entire server-allowed project graph per REST call and discard it.
2. **Define is whole-graph per notation version** (→ G4, now that G1 made it once-per-version).
   A one-attribute edit still re-runs every definer.
3. **Boilerplate at the binding layer** (→ G5a). ~15 hand-written `AttributeDefiner` objects in
   kzen-auto (9 report specs — `FilterSpec.kt:124-147`, `PivotSpec.kt:183-205`, … — plus
   data/registry/target/script) each repeat fetch-cast-wrap plumbing around a hand-walked
   `ofNotation`; read path and write path can drift.
4. **Hardcoded logic-document check** (→ G5b). `AutoConventions.isLogic` is an OR over document
   types — the gotcha that bit Job M1; a god-object violation.
5. **Error surfacing is reconstructive** (→ G6). A failed definition drops out of
   `transitiveSuccessful`; consumers see `"Missing: <doc>#main"` at use time.
   `// TODO: add GraphInstanceAttempt` at `ModelTaskRepository.kt:134`.
6. **Deparse is full and lossy** (→ G7). `YamlNotationParser.unparseDocument(notation,
   previousDocument)` ignores the template (`YamlNotationParser.kt:110-130`) — any command
   touching a document strips its comments/formatting.

**Deliberately out of scope** (decided; do not re-open inside a phase):
- Typed scalar notation (numbers/bools stay strings parsed on demand) — breaking, low leverage.
- Command-taxonomy consolidation — wire-visible churn without user-facing gain.
- Changing reference-resolution *semantics* (host-document scoping stays; the `TODO: reverse
  breadth first search` in `ObjectLocationSet.kt:58` stays a TODO).
- First-class synthesized objects (Job's `JobChannelSynthesis`): revisit after G4 makes the
  redefine cheap; the current approach is correct, just costly.
- Multi-tenant / cross-process graph stores.

## Ground rules for every phase

- **Docs lead.** There is no `graph-spec.md`; `kzen-lib/docs/architecture.md` is the reference —
  update the relevant section in the same session as any behaviour/API change (and
  `kzen-auto/docs/architecture.md` §2/§4 where store/consumption behaviour changes).
- **SPI compatibility is additive-only.** `ObjectDefiner` / `ObjectCreator` / `AttributeDefiner`
  / `AttributeCreator` are implemented by kzen-auto, kzen-project, and third parties. New SPI
  methods get default implementations; never change existing signatures.
- **Preserve the crown jewels** (above): meta-circular bootstrap, pure/cacheable definitions,
  persistent insertion-ordered collections, incremental metadata cache, graceful degradation on
  broken notation (dangling `is:` → root / `Any`; startup must survive).
- **No flavour-specific code in general layers** — the standing god-object rule. Graph-layer
  changes must not special-case Script/Flow/Job/Report; extension is via SPI + notation.
- **Dev loop**: kzen-auto consumes kzen-lib from **mavenLocal**. After any kzen-lib change:
  `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`. Open kzen-auto as its own IntelliJ project (not via the umbrella).
- **Verification baseline** (every phase): kzen-lib `./gradlew :kzen-lib-common:jvmTest
  :kzen-lib-jvm:test` (notation suites: `StructuralNotationTest`, `AddObjectTest`,
  `RenameObjectTest`, `SetDocumentObjectsTest`, `MultipleInheritanceTest`,
  `YamlNotationParserTest`, `YamlParseTest`/`YamlUnparseTest`, `PersistentMap/List/SetTest`,
  `ObjectStableMapperTest`, `GraphDefinitionTransitiveTest`; jvm: `AutowiredTest`, `LocateTest`,
  `NestedClassTest`, `ServiceInjectionTest`, `CodeReferenceRewriterHookTest`, `RunEngineTest`).
  Then kzen-auto `./gradlew :kzen-auto-jvm:test` (Job suite + `FormulaStepTest`). UI-facing
  phases: `./gradlew :kzen-auto-test:selfTest` (opt-in, opens Chrome), plus a manual
  `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` smoke.
- Mark the phase checkbox in this file's tracker when done, and append a short "as-built" note
  to the phase section if the implementation deviated.

---

## Phase 3 — Scoped instantiation + instance caching

**Goal:** stop building whole-project or whole-document instance graphs to obtain one object.
The two hot spots: Flow's per-vertex rebuild and the detached/task executors' per-REST-call
full-graph build. Depends on G2's digest keys (met).

### 3a. Flow: per-vertex closure instead of per-document

`FlowRun.createInstance` (`FlowRun.kt:434-441`) and `retrace` (:394-406) build
`filterTransitive(documentPath)`. First cut: `filterTransitive(vertexLocation)` — the vertex's
closure is itself plus its definer-allocated channel scaffolding (per the FlowWiring design,
vertices do not strongly reference each other; message passing goes through `ActiveVertexModel`,
and each execution gets fresh channels by design — the code comment at :434-436). **In-phase
survey step (mandatory):** confirm via `FlowWiring` / vertex definers that no vertex closure
pulls in sibling vertices; if any edge type does (e.g. `RunLogicVertex` children), measure whether
the closure is still ≪ document and accept, or fall through to the next bullet.
Cache the per-vertex filtered `GraphDefinition` in `FlowRun` (keyed by vertex location; the
definition is fixed for the run — invalidated on migrate when `graphDefinition` is replaced).

**Deferred unless 3a-first-cut proves insufficient:** a kzen-lib
`GraphCreator.createObject(location, graphDefinition, environment, baseInstance: GraphInstance)`
single-object API (build one object + its unbuilt strong deps on top of an existing partial
graph). Only implement if the per-vertex closure measurement still shows waste. Record the
measurement in the as-built note either way.

### 3b. Detached/task executors: scope + digest-keyed cache

`ModelDetachedExecutor.execute`/`executeDownload` (`ModelDetachedExecutor.kt:31-56, 59-75`) and
`ModelTaskRepository.submit` (:129-136):

1. Scope: `filterTransitive(actionLocation)` instead of `filterDefinitions(serverAllowed)` —
   from O(project) to O(action closure). `serverAllowed` filtering still applies first (never
   instantiate client-only objects server-side): filter, then closure.
2. Cache: a small `GraphInstanceCache` in kzen-auto (`server/service/exec/`), keyed by
   `transitiveDigest(actionLocation)` (G2), holding the created `GraphInstance` per action
   location. Per call: recompute the digest (cheap — memoized notation digests), hit ⇒ reuse
   instance, miss ⇒ rebuild and replace. **In-phase survey step (mandatory):** verify every
   `DetachedAction` / `DetachedDownloadAction` / `ManagedTask` implementation treats instance
   fields as immutable config (the per-request statelessness the REST layer already implies).
   Any stateful one found either gets fixed or the cache keys it out (opt-out by archetype
   attribute, not by class `when`). Document the statelessness contract on `DetachedAction`.
3. `ModelTaskRepository` keeps its `// TODO: add GraphInstanceAttempt` for phase 6.

### 3c. `GraphEnvironment` provider registration

`MapGraphEnvironment` gains `put(className, provider: () -> Any)` with memoized first-resolve
(additive; existing eager `put` stays). Then `KzenAutoContext` and `ClientContext` register
providers directly and stop passing `() -> GraphEnvironment` thunks into
`ServerLogicController` / `ModelDetachedExecutor` / `ModelTaskRepository` — the constructor
parameter becomes plain `GraphEnvironment`. Deletes the deferred-provider cycle-break and its
rationale comments on both sides.

### Verification

Baseline + selfTest (Flow FizzBuzz exercises per-vertex execution; Script sub-run exercises
compile). Manual: Report input/output panel actions (detached hot path) — behaviour unchanged,
server log timing before/after worth capturing in the as-built note. Job suite for 3c (env
threading through `EngineJobControl`).

### As-built (2026-07-19)

**3a — rescoped to survey-pin + measurement, no production change.** The premise no longer held:
`FlowRun` builds **one** graph per run (`FlowRun.kt:113-116`) and every vertex execution / retrace
reads that single `runInstance` — the per-execution rebuild 3a targeted was already eliminated by
the engine-rewrite era Flow work, and per-vertex closures would now be a *de-optimization* for a
full run (N `createGraph` calls each re-paying the bootstrap tower vs one over the same objects).
The mandatory survey confirmed per-vertex closures **are** self-contained: channels are define-time
`ValueAttributeDefinition`s (`FlowWiring.define`), sibling vertices connect by grid geometry not
references (`EdgesDefiner` emits value `EdgeDescriptor`s), and `RunLogicVertex.instructions` is
`by: Nominal` → weak → excluded from `references()`. `FlowVertexClosureTest` (new) pins that
invariant and creates each vertex standalone. **Measurement** on `test/flow-run-test.yaml`
(3 vertices incl. a `RunLogic`): per-vertex closure = **3** definitions vs document-scoped = **6**
— a real but modest ratio at this size, consistent with the rescope. The kzen-lib
`GraphCreator.createObject` single-object API **stays deferred**.

**3b — landed as planned, with one cache-key refinement.** `GraphInstanceCache`
(`kzen-auto-jvm/.../server/service/exec/`) takes the already-`serverAllowed`-filtered definition,
scopes with `filterTransitive(actionLocation)`, and reuses the located `ObjectInstance`
(access-ordered LRU, `maxEntries = 32`). The key is **not** bare `transitiveDigest`: an inheritance
ancestor is not in `references()`, so editing a user-editable prototype (a Custom-document
archetype) would change the merged definition without bumping the closure digest. The key therefore
folds in each closure member's inheritance-chain notation digests. `GraphInstanceCacheTest` case
`inheritanceAncestorEditRebuilds` pins this — verified to fail when the chain contribution is
removed. **Statelessness survey: all 10 implementations are stateless** (all-`val` config/services,
no `var`/mutable collection/stored handle), so none needs the opt-out; the archetype attribute
`instanceCaching: "false"` (read via inheritance-walking `firstAttribute`) ships anyway as the
third-party escape hatch, exercised by the `FreshActionArchetype` fixture. The contract is now kdoc
on `DetachedAction`, `DetachedDownloadAction` and kzen-lib `ManagedTask`, including the newly
reachable "same instance may serve concurrent requests". `ModelTaskRepository`'s
`// TODO: add GraphInstanceAttempt` is preserved.

**3c — landed, with drift corrections.** kzen-lib `GraphEnvironmentBuilder.put(className, provider)`
+ `MapGraphEnvironment.ServiceProvider` (`by lazy`) added; `KzenAutoContext.graphEnvironment` is now
an eager `val` declared mid-constructor, with the two below-it members (`logicTrace`,
`serverLogicController`) registered as providers; `ServerLogicController` / `ModelDetachedExecutor` /
`ModelTaskRepository` take a plain `GraphEnvironment`. Drift vs the plan: **`ClientContext` never
took a thunk** (its env is `by lazy`, passed directly to `createGraph`) — no client change; the
**plugin repo was never a thunk site** either (it takes no environment at all and already scopes
with `filterTransitive` + its own digest cache) — the stale sentence in kzen-auto
`docs/architecture.md` §4 was corrected; and one *dead* fourth thunk site the plan didn't list,
`kzen-auto-common/.../service/GraphInstanceCreator.kt` (zero references anywhere), was **deleted**.
kzen-lib's `docs/architecture.md` gained its first `@Service` / `GraphEnvironment` paragraph.

**Test-coverage deviation.** The planned `ModelDetachedExecutorTest` fixture could not live in
`test/` notation: `AutoConventions.serverAllowed` covers only `kzen/`, `auto-common/`, `auto-jvm/`,
`main/`, so a `test/`-nested action is filtered out before the executor ever sees it. The test
instead drives the real executor over the production `ScriptValidator` (`auto-jvm/script/…`) — the
same "impossible before 3b" coverage, since the whole-graph build was unsatisfiable in the test
environment — plus a not-found case pinning that the guard precedes `transitiveDigest`'s `require`.
The offline `GraphInstanceCacheTest` still uses the new `test/detached-cache-test.yaml` fixture
(it passes definitions directly, no policy filter). The optional `ManagedTask` parity case was
skipped for the same nesting reason.

**Not yet done: the manual before/after timing.** The `/action/detached` browser-Network
measurement and the three-family smoke (ScriptValidator / ScreenshotTaker / PluginDocument) need
the user at the browser — outstanding, tracked with the master plan's manual smoke debt. The
permanent `logger.debug("built {} - {} of {} definitions in {}us", …)` line inside
`GraphInstanceCache` is in place to capture the scoping ratio when that run happens.

---

## Phase 4 — Incremental define (per-object definition cache) — **riskiest phase, measurement-gated**

**Gate (master-plan push-back, upheld):** G1 already collapsed per-command defines to one per
notation version. Before starting this phase, **measure the per-keystroke define cost on a large
project**; execute G4 only if it still hurts. Record the measurement either way (in this file's
tracker line if skipped).

**Goal:** a one-attribute edit re-runs `ObjectDefiner.define` only for the changed object and
objects whose declared dependencies changed — not all N. Mirrors the proven
`NotationMetadataReader` design (per-object dependency digest → `DigestCache`).

**Design decisions:**
- **Opt-in via new SPI methods with `null` defaults** (additive-only rule):
  `ObjectDefiner.dependencyDigest(objectLocation, graphStructure): Digest?` and
  `AttributeDefiner.dependencyDigest(objectLocation, attributeName, graphStructure): Digest?`.
  `null` ⇒ uncacheable ⇒ redefine every time (today's behaviour). Third-party definers keep
  working unchanged.
- `AttributeObjectDefiner` (the default for everything inheriting `Object`) implements it:
  digest over the object's merged notation along its inheritance chain + its `ObjectMetadata`
  digest + each attribute definer's own `dependencyDigest` (recursing the opt-in; any `null`
  attribute definer makes the whole object uncacheable). `StructuralAttributeDefiner` /
  `WeakAttributeDefiner` / `SelfAttributeDefiner` digest their local inputs;
  `AutowiredAttributeDefiner` / `ParentChildAttributeDefiner` / `NestedListAttributeDefiner`
  scan the graph — first cut: return `null` (objects using them are few; measure), with a
  follow-up option of an is-membership index digest. Flow's channel-allocating definers return
  `null` by nature (fresh scaffolding per define is their contract).
- `GraphDefiner.tryDefine` gains an optional `DefinitionCache` parameter
  (`DigestCache<ObjectDefinition>`, sized like the metadata cache); `DirectGraphStore` owns one
  instance. Cache lookup happens per object inside the level loop before invoking the definer;
  a hit still participates in `closedDefinitions` normally. **The definer/creator instance
  tower (`definerAndRelatedInstances`) is NOT cached** — it's tiny (the meta objects) and
  rebuilding it per tryDefine keeps bootstrap semantics untouched.
- **Mandatory survey-first step:** inventory every `ObjectDefiner`/`AttributeDefiner`
  implementation in kzen-lib, kzen-auto, and kzen-project; classify each as
  local-deps / graph-scanning / scaffolding-allocating; record the table in the as-built note.
  Only then wire `dependencyDigest` implementations.

### Verification

Full baseline both repos + selfTest. Add an instrumented test (counting definer wrapper or a
test-only hook): two-document graph, edit an attribute in document A, assert zero `define` calls
for document B's cacheable objects and a correct redefine when B inherits from the edited object
(the dependency digest must catch cross-document inheritance — reuse
`NotationMetadataReader.metadataDependencies`' dependency-walk pattern). Also assert edits to
`meta:` and to `is:` invalidate dependents. This phase must not land without those tests.

---

## Phase 5 — Declarative notation binding + notation-driven logic marker

**Goal:** delete the hand-written spec-binding boilerplate and the hardcoded logic-document
check — the two ergonomics gaps that force kzen-auto edits where notation/SPI should suffice.
Prerequisite-free (independent of G3/G4).

### 5a. `NotationCodec` combinator layer

New in kzen-lib-common (`service/binding/` or similar): a small combinator API
`NotationCodec<T>` with `parse(AttributeNotation): T` / `unparse(T): AttributeNotation` and
combinators (`scalar`, `int`, `boolean`, `enum`, `list(codec)`, `map(codec)`, `field`/`nested`
with defaults). Plus a generic `CodecAttributeDefiner<T>(codec)` that does the
fetch-merge-cast-wrap plumbing currently copy-pasted per spec, and (optional, same pattern) a
`CodecAttributeCreator`. Port **`FilterSpec` and `PivotSpec`** as the reference conversions
(their `ofNotation` + `Definer` objects collapse into codec declarations; the write-path command
builders reuse `unparse`, eliminating read/write drift). Remaining ~13 definers are follow-up
adoption, not this phase — but the phase's as-built note should list them as candidates.
KSP-generated codecs are explicitly **out**: the combinator layer must carry its weight
hand-written first.

### 5b. Notation-driven "runnable logic" marker

`AutoConventions.isLogic` (`kzen-auto-common/.../util/AutoConventions.kt:81-89`) is a hardcoded
OR over document types (the documented gotcha that bit Job M1): a new logic document type isn't
runnable until shared code is edited — a god-object violation. Change: archetypes declare a
marker in notation (decide in-phase: an `ObjectTag` — metadata already supports `tags:` — or
inheritance from a common `LogicDocument` notation object; prefer the tag, it doesn't disturb
`is:` hierarchies), `isLogic` becomes a tag/inheritance query via `GraphNotation`/`GraphMetadata`
(add a small `GraphNotation.inheritsFrom(location, ancestor)` helper regardless — Kotlin-side
consumers keep hand-rolling that scan). Server `LogicCompiler`'s interface check stays the
authoritative runtime guard; the notation marker is the UI-gating twin. Update the
architecture-doc gotcha (kzen-auto `docs/architecture.md` §1 "Making a new logic document
runnable in the UI") to describe the new mechanism. Tag Script/Flow/Report/Job archetypes.

### Verification

Baseline + report UI smoke (filter/pivot editing round-trips — codec parity with the old
`ofNotation` verified by unit tests comparing outputs over the existing notation fixtures).
selfTest covers ribbon gating (Script/Job run controls present); manually confirm a Flow document
still shows Run controls.

### As-built (2026-07-19)

- **5b was already done — reduced to a doc fix (user decision: "doc fix only").** The plan's premise
  (a hardcoded `isScript || isFlow || isReport || isJob` OR in `AutoConventions.isLogic`) no longer held:
  `isLogic(graphNotation, documentPath)` already tests the `main` archetype's inheritance chain for a
  common `Logic` marker (`ObjectName("Logic")`), every logic archetype declares `is: [Document, Logic]`
  in `common-document.yaml`, and the server twin is the `LogicDocument` interface (guarded by
  `LogicCompiler`'s `as? LogicDocument`). This landed earlier under **CC-17**. So the notation-marker
  design the plan proposed already exists. **The `GraphNotation.inheritsFrom` helper was NOT added**
  (user chose doc-only) — the ~7 hand-rolled `inheritanceChain(x).any { it.objectPath.name == … }`
  scan sites stay as-is; a future cleanup can still add it. Only change: corrected the stale
  `kzen-auto/docs/architecture.md` § 1 gotcha to describe the actual mechanism (no umbrella duplicate found).
- **5a — as designed, with placement decided.** New `NotationCodec<T>` (`parse`/`unparse`) + combinator
  library `NotationCodecs` (`scalar`/`boolean`/`int`/`long`/`double`, `scalarMapped`, reified `enum`,
  `list`/`set`/`map`, `record` + `field`/`fieldOrNull`/`recordOf` + `xmap`) in **new package
  `kzen-lib-common/.../model/structure/notation/codec/`** (chosen over the plan's tentative
  `service/binding/` — the codec depends only on `AttributeNotation` model types, no service coupling).
  Generic `abstract class CodecAttributeDefiner<T>(codec, inheritanceMerge)` in
  `kzen-lib-common/.../objects/general/` — abstract, so no `@Reflect` / no `kzen-base.yaml` entry.
- **Ported FilterSpec (`inheritanceMerge = false`, verbatim `firstAttribute`) and PivotSpec
  (`inheritanceMerge = true`, `mergeAttribute`)** plus their nested specs (ColumnFilterSpec,
  PivotValueTableSpec, PivotValueColumnSpec). Each spec's `Definer` collapsed from a ~20-line
  `object … : AttributeDefiner { override define … }` to `object Definer: CodecAttributeDefiner<Spec>(codec, …)`
  (kept `@Reflect`; **zero notation YAML change** — `FilterSpecDefiner`/`PivotSpecDefiner`'s
  `class: …$Definer` still resolve). `ofNotation` (still consumed client-side by ValueSetFilterEditor /
  PivotSpecEditor, and by AnalysisSpec.Definer for the Report host) now delegates to `codec.parse`;
  `ColumnFilterSpec.emptyNotation` now derives from `codec.unparse(empty)` (single source of truth for
  the `{type, values}` layout). PivotSpec's `rows` dedup (`HeaderListing` uniqueness) preserved via
  `.distinct()`. `PivotValueTableSpec.ofRequest`/`asRequest` (the separate RequestParams wire) left
  hand-written. Minor intentional improvement: the base reads via the nullable `firstAttribute(path)` /
  `mergeAttribute` overloads → graceful `AttributeDefinitionFailure` instead of the prior by-name throw
  when the attribute is wholly absent (never happens in practice — archetypes default `filter`/`pivot`).
- **Follow-up (documented, not this phase):** ~13 codec-portable definers remain — report
  `SortSpec`/`PreviewSpec`/`FormulaSpec`/`OutputExportSpec`/`OutputSpec`/`AnalysisSpec`/`InputSpec`,
  plus `FieldFormatListSpec`/`ClassListSpec`/`ResourceClosePolicyDefiner`/`ResultSignatureDefiner`/
  `TypeMetadataDefiner`/`ParameterDefaultDefiner`. Not codec-portable (structural / registry / metadata
  dispatch): `TargetSpecDefiner`, `ChannelTypeDefiner`, `FlowWiring`, `EdgesDefiner`.
- **Tests / verification (all green):** `NotationCodecTest` (kzen-lib commonTest — every combinator +
  order preservation + field defaults + xmap); `FilterSpecCodecTest` + `PivotSpecCodecTest` (kzen-auto
  commonTest — parse+unparse against hand-built fixtures, empty-template parity, rows dedup).
  `:kzen-lib-common:jvmTest`+`jsTest` + `:kzen-lib-jvm:test`, `publishToMavenLocal`, then (with
  `--refresh-dependencies`) `:kzen-auto-common:jvmTest`+`jsTest` + `:kzen-auto-jvm:test` (Job suite drives
  both definers via `job-worker.yaml`'s `is: FilterSpec`/`is: PivotSpec`) + the `kzen-auto-js` bundle
  (client `ofNotation` callers still bind). **Manual report filter/pivot round-trip smoke still owed**
  (browser session — folded into the standing smoke-debt item).

---

## Phase 6 — Error surface (structured definition/creation failures)

**Goal:** a failed object stops surfacing as `"Missing: <location>"` at use time; consumers get
the failure origin without reconstructing it. Prerequisite-free; light session.

- kzen-lib: add `GraphInstanceAttempt` (mirror of `GraphDefinitionAttempt`: successful instances
  + per-location creation failures) and a `GraphCreator.tryCreateGraph` returning it (existing
  `createGraph` delegates and throws on failure — additive). Resolves the
  `ModelTaskRepository.kt:134` TODO.
- Enrich `ObjectDefinitionFailure` usage: definer failures already carry `attributeErrors` —
  ensure `AttributeObjectDefiner` populates per-attribute causes (which attribute, which
  reference, resolved-against-what) instead of one flattened message string.
- Improve locate errors: `ObjectLocationMap.locate` / `Locator.locate`
  (`ObjectLocationMap.kt:37-51`, `ObjectLocationSet.kt:73-87`) currently dump every document
  path in the graph into the message; change to the reference, the host, and near-miss
  candidates (same name elsewhere / same document different nesting).
- kzen-auto: simplify `DefinitionErrors` (client) to consume the structured failures directly;
  `ReportState`'s `!!` unwraps get a guarded path that reports the originating failure.

### Verification

Baseline; add kzen-lib tests: an object with a dangling strong reference produces a definition
failure naming the attribute and reference; a creator throwing produces a `GraphInstanceAttempt`
failure rather than aborting the graph. kzen-auto: break a report document's notation (blank
required reference) and confirm the UI names the object/attribute instead of "Missing: main".

---

## Phase 7 — Reducer decomposition + format-preserving deparse

**Goal:** hygiene with one user-visible payoff — comments and formatting survive edits to
*other* objects in the same document. **7b requires the yaml-parser plan
(`2026-07-10_yaml-parser-strings-and-comments.md`) to have landed first** (hot-seam rule: its
one-time output churn — bare strings, `|-` block scalars — must precede byte-identical segment
preservation, so 7b's per-object equality operates on the new stable format). 7a is
prerequisite-free.

### 7a. Reducer decomposition (mechanical, no behaviour change)

`NotationReducer` (1885 lines, ~45 handlers): extract the copy-pasted 6-step attribute-edit
skeleton — in particular the **re-merge-inherited-value-before-local-edit invariant**
(`NotationReducer.kt:533-541` and its ~11 clones) — into one shared private helper; then split
the class body into focused internal files (document/object/attribute/refactor command groups)
keeping the public `applyStructural`/`applySemantic` dispatch and the `StructuralBuffer`
composition pattern exactly as-is. Pure refactor: the notation test suites are the safety net.

### 7b. Template-respecting deparse (object-level granularity)

Implement what the `NotationParser.unparseDocument(notation, previousDocument)` signature always
promised (`YamlNotationParser.kt:110-130` currently ignores the template): split
`previousDocument` into per-object text segments (top-level keys — the parser's own document
structure), and for each object in the new notation whose parsed form equals the previous
document's parsed form for that key, **emit the previous text segment byte-identical** (preserving
its comments/blank lines/formatting); re-serialize only changed/added objects; preserve leading
document comments before the first object. Comments *inside* a changed object are still lost —
accepted first cut, document it. Effect: a command touching object A no longer strips comments
from objects B/C in the same document, and unchanged-document writes stay no-ops
(`writeIfRequired`'s `updatedBody != previousBody` check becomes meaningfully stable for
hand-formatted files). Update the now-accurate `DirectGraphStore.writeCopy` comment. Extend
`YamlUnparseTest` + a `DirectGraphStore`-level round-trip test with a commented fixture.

### Verification

Baseline (notation suites are the core safety net for both halves); kzen-auto raw-editor smoke:
hand-comment a document, edit a *different* object via the structured UI, confirm the comment
survives on disk; `SetDocumentObjectsCommand` (raw save) still round-trips.

### As-built (2026-07-19)

- **7a — full split (the conservative split was landed first, then extended to the full one when the
  user asked why the file was still large; the "deferred" note below is superseded).** Every command
  handler is now a pure top-level function in a sibling file, and `NotationReducer.kt` is a ~230-line
  dispatch facade holding only the class (`applyStructural` delegates to a top-level dispatcher;
  `applySemantic`'s `when` threads `codeReferenceRewriters` into `renameObjectRefactor`), the top-level
  `internal class StructuralBuffer`, and the top-level `internal fun applyStructuralCommand` (the
  structural `when`). The moves, all same-package so the `when` branches call them unchanged:
  stateless handlers → `NotationReducer{Documents,Objects,Attributes,Resources}.kt`; composite-attribute
  group D (`shiftInAttribute`/`addObjectAtAttribute`/`insertObjectInListAttribute`/`removeObjectInAttribute`)
  → `NotationReducerComposite.kt`; the refactor + reference-analysis cluster (group E) →
  `NotationReducerRefactor.kt`. The two enablers: `StructuralBuffer` had to become a top-level
  `internal class` (was `private inner`) so top-level handlers can construct it, which in turn required
  the structural dispatcher to be a top-level `internal fun` (verified instance-independent — it never
  consults `codeReferenceRewriters`); the class's public `applyStructural` is now a one-line delegate.
  **The visibility cost the plan feared didn't materialize:** because the whole E cluster moved as a
  unit into one file, only its four dispatched entry points (`renameObjectRefactor`,
  `relocateObjectTreeRefactor`, `relocateDocumentRefactor`, `relocateFolderRefactor`) are `internal`;
  every reference-analysis helper stays file-`private`. `renameObjectRefactor` gained a
  `codeReferenceRewriters: List<CodeReferenceRewriter>` parameter (the only group-E user of instance
  state), threaded by `applySemantic`. The re-merge invariant is the single `remergeAttributeThenEdit`
  top-level helper (consumed by the 5 nested-attribute edits; STEP 1 document lookup stays at each call
  site so differing throw idioms `!!` vs `?: throw` are preserved verbatim; the edit lambda returns
  `Pair<ObjectNotation, NotationEvent>` so two insert sites build their event from post-merge locals).
  The 3-arg path helper `renameNestedObject` was renamed `renamedNestedObjectPath` (removing the
  overload with the moved 2-arg command handler). All notation suites + kzen-auto's ~10
  `NotationReducer().applyStructural` test callers pass unchanged.
- **7b — as designed.** `unparseDocument` now honours `previousDocument`: `splitPreviousDocument`
  segments the template by column-0 non-blank non-`#` boundary lines (each object carries its own
  leading blank/comment run; leading document comments are the prefix), parses each segment
  individually (single source of truth; empty-body/malformed segments skip), and reconstruction
  emits the byte-identical (blank-edge-trimmed) segment for unchanged objects else house-serializes.
  `houseSerializeObject` extracts the old per-object loop, reused by the full-serialize fast/fallback
  path. Everything is wrapped in a try/catch → full serialization. `DirectGraphStore.writeCopy`'s
  now-accurate comment updated.
- **Tests:** 5 new `YamlNotationParserTest` cases (preserve-unchanged-comment, leading-comment,
  blank normalization, comment-inside-changed-object lost, unmatched-template fallback) + 1
  `RepositoryTest` store round-trip (edit A through the store, assert B's comment survives on disk).
  **The disk-level folder-relocate `writeCopy` test was deferred** — it needs a writable copy of the
  archetype fixture graph for reference resolution (heavy harness); `writeCopy` uses the identical
  `unparseDocument(objects, template)` path already covered by the parser + store tests, and
  `RenameFolderRefactorTest` covers the reference-rewrite that makes objects differ.
- **Verification (all green):** `:kzen-lib-common:jvmTest`+`jsTest`, `:kzen-lib-jvm:test` (one
  unrelated flaky `RunEngineTest.migrateConcurrentChildren…` passed on isolated re-run),
  `publishToMavenLocal`, then `:kzen-auto-jvm:test --refresh-dependencies` (Job suite + FormulaStep +
  JS bundle). Docs: kzen-lib `docs/architecture.md` CQRS § (reducer file organization +
  format-preserving deparse). **Manual raw-editor smoke still owed** (browser session).

---

## Sizing and sequencing

| Phase | Size | Risk | Depends on |
|---|---|---|---|
| 3 | one session | medium (statelessness survey) | G2 ✓ (digest keys) |
| 4 | one full session | **high** (invalidation correctness) | G1 ✓ + measurement gate |
| 5 | one session | low-medium (codec design taste) | — |
| 6 | one session (light) | low | — |
| 7 | one session (7b is the bulk) | medium (parser edge cases) | 7b: yaml-parser plan first |

Phases 5/6/7 are independent of 3/4 and of each other; reorder freely if priorities shift.
If a session runs long, land the kzen-lib half first (publishToMavenLocal keeps kzen-auto
buildable) and note the split in the tracker.
