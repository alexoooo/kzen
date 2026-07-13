# Graph* (Notation / Definition / Instance) improvements — phased plan

> **Status: planned.** Written 2026-07-05 from a design review of the kzen-lib Graph stack
> (`GraphNotation → NotationMetadataReader → GraphStructure → GraphDefiner → GraphDefinition →
> GraphCreator → GraphInstance`, plus the CQRS store) and of how kzen-auto consumes it. Executor:
> **Opus 4.8 xhigh, one phase per session.** Each phase is self-contained: goal, design decisions
> (already made — do not re-litigate), concrete steps with file anchors, and verification. Phases
> are ordered by dependency; do not start a phase whose prerequisite is unchecked.
>
> Companion plan: `2026-07-05_logic-engine-improvements.md` (independent; the two plans touch
> disjoint code except `ServerLogicController`, where Graph phase 2 deletes the
> `baselineNotations` apparatus — coordinate if both are in flight).
>
> **Progress tracker** (update as phases land):
> - [x] Phase 1 — definition caching + hot-path correctness (kzen-lib only) ✓ 2026-07-12
> - [ ] Phase 2 — closure content digest (retire `baselineNotations` notation-compare)
> - [ ] Phase 3 — scoped instantiation + instance caching (Flow per-vertex, detached actions)
> - [ ] Phase 4 — incremental define (per-object definition cache, opt-in SPI)
> - [ ] Phase 5 — declarative notation binding + notation-driven logic marker
> - [ ] Phase 6 — error surface (`GraphInstanceAttempt`, structured definition failures)
> - [ ] Phase 7 — reducer decomposition + format-preserving deparse

## Context — what the review found

The three-layer contract (Notation = syntax, Definition = typed, Instance = runtime, all keyed by
`ObjectLocation`; CQRS mutation log; content addressing via `Digest`) is sound and should not be
restructured. The meta-circular bootstrap (2 hand-seeded objects in `GraphDefiner.bootstrapObjects`
define the whole definer/creator tower declared in `kzen-base.yaml`), the environment-free /
cacheable definition split (`GraphEnvironment` only enters at create time), the persistent
insertion-ordered collections, and the incremental per-object metadata cache
(`NotationMetadataReader`, dependency-digest-keyed) are the crown jewels — every phase must
preserve them. The weaknesses are in **caching, scoping, and ergonomics around** that contract:

1. **Definition is recomputed whole per command.** `DirectGraphStore.graphDefinition()`
   (`kzen-lib-common/.../service/store/DirectGraphStore.kt:152-170`) runs `GraphDefiner.tryDefine`
   fresh on every call; `publishSuccess` calls it after **every** command, and a semantic command
   computes it **again** on the old notation inside `applyInPlace` (:200-203). Notation parsing and
   metadata are digest-cached; the definition is not (literal TODO at `LocalGraphStore.kt:49`).
   On the client this runs per keystroke (twice under mirroring — local apply + digest-mismatch
   refresh); every observer receives the full fresh `GraphDefinitionAttempt`.
2. **Derived views go cold per edit.** Every command yields a fresh `GraphNotation`, whose lazy
   `coalesce` re-flattens all objects (`GraphNotation.kt:37-43`) and whose
   `inheritanceChainCache` restarts empty. The persistent-model deltas themselves are cheap and
   properly shared; the cost is concentrated in these derived views.
3. **Whole-graph instantiation where one object is needed.** `FlowRun.createInstance`
   (`kzen-auto-jvm/.../server/exec/flow/FlowRun.kt:434-441`) runs
   `createGraph(filterTransitive(documentPath))` **per vertex execution** — O(iterations ×
   vertices²) constructions per run. `ModelDetachedExecutor` / `ModelTaskRepository`
   (`ModelDetachedExecutor.kt:35-41`, `ModelTaskRepository.kt:129-136`) build the **entire
   server-allowed project graph per REST call** (every Report panel action) and discard it.
4. **No value semantics for definitions.** Two builds of the same notation are never
   definition-equal because some definers embed freshly-allocated mutable scaffolding (Flow's
   `MutableFlowOutput` etc.), so `ServerLogicController` maintains a hand-rolled
   `baselineNotations` / `closureNotations` notation-map compare per drive
   (`ServerLogicController.kt:745-790`, rationale comment :110-115).
5. **Correctness cliffs in resolution/creation.** `GraphCreator.tryLocate` hits
   `TODO("More than one candidate not supported yet")` (`GraphCreator.kt:199`); the definer
   fixed point guards convergence with `check(levelCount < 16) { "too deep" }`
   (`GraphDefiner.kt:101`); `constructionLevels` is scan-until-satisfied — O(n²·E) for deep
   dependency chains (`GraphCreator.kt:73-141`); `ReflectionRegistry.global` is a mutable
   process singleton with a `TODO: make threadsafe`.
6. **Deparse is full and lossy.** `YamlNotationParser.unparseDocument(notation, previousDocument)`
   ignores `previousDocument` entirely (`YamlNotationParser.kt:110-130`) — any command touching a
   document strips its comments/formatting; the "unparse template for a minimal diff" comment in
   `DirectGraphStore.writeCopy` (:288-297) describes a design that was never implemented.
7. **Boilerplate at the binding layer.** ~15 hand-written `AttributeDefiner` objects in kzen-auto
   (9 report specs — `FilterSpec.kt:124-147`, `PivotSpec.kt:183-205`, … — plus data/registry/
   feature/script) each repeat the same fetch-cast-wrap plumbing around a hand-walked
   `ofNotation`; read path (`ofNotation`) and write path (command builders) can drift.
8. **Error surfacing is reconstructive.** A failed object definition silently drops out of
   `transitiveSuccessful`; consumers see `"Missing: <doc>#main"` at use time, and kzen-auto's
   `DefinitionErrors` + `!!` guards reconstruct what failed. `// TODO: add GraphInstanceAttempt
   for error reporting` at `ModelTaskRepository.kt:134`.

**Deliberately out of scope** (decided; do not re-open inside a phase):
- Typed scalar notation (numbers/bools stay strings parsed on demand) — breaking, low leverage.
- Command-taxonomy consolidation (batch/singular near-duplicates, thin resource commands) —
  wire-visible churn without user-facing gain.
- Changing reference-resolution *semantics* (host-document scoping stays; the `TODO: reverse
  breadth first search` in `ObjectLocationSet.kt:58` stays a TODO). Ambiguity gets a clean error
  (phase 1), not new resolution rules.
- First-class synthesized objects (Job's `JobChannelSynthesis` augment-then-redefine): revisit
  after phase 4 makes the redefine cheap; the current approach is correct, just costly.
- Multi-tenant / cross-process graph stores.

## Ground rules for every phase

- **Docs lead.** There is no `graph-spec.md`; `kzen-lib/docs/architecture.md` is the reference —
  update the relevant section in the same session as any behaviour/API change (and
  `kzen-auto/docs/architecture.md` §2/§4 where store/consumption behaviour changes).
- **SPI compatibility is additive-only.** `ObjectDefiner` / `ObjectCreator` /
  `AttributeDefiner` / `AttributeCreator` are implemented by kzen-auto, kzen-project, and
  third parties. New SPI methods get default implementations; never change existing signatures.
  (`kzen-auto-plugin` doesn't re-export the Graph SPI, but kzen-project consumes it directly.)
- **Preserve the crown jewels** (Context above): meta-circular bootstrap, pure/cacheable
  definitions, persistent insertion-ordered collections, incremental metadata cache, graceful
  degradation on broken notation (dangling `is:` → root / `Any`; startup must survive).
- **No flavour-specific code in general layers** — the standing god-object rule. Graph-layer
  changes must not special-case Script/Flow/Job/Report; extension is via SPI + notation.
- **Dev loop**: kzen-auto consumes kzen-lib from **mavenLocal**. After any kzen-lib change:
  `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`. Open kzen-auto as its own IntelliJ project (not via the umbrella).
- **Verification baseline** (every phase): kzen-lib `./gradlew :kzen-lib-common:jvmTest
  :kzen-lib-jvm:test` (notation suites: `StructuralNotationTest`, `AddObjectTest`,
  `RenameObjectTest`, `SetDocumentObjectsTest`, `MultipleInheritanceTest`,
  `YamlNotationParserTest`, `YamlParseTest`/`YamlUnparseTest`, `PersistentMap/List/SetTest`,
  `ObjectStableMapperTest`; jvm: `AutowiredTest`, `LocateTest`, `NestedClassTest`,
  `ServiceInjectionTest`, `CodeReferenceRewriterHookTest`, `RunEngineTest`). Then kzen-auto
  `./gradlew :kzen-auto-jvm:test` (Job suite + `FormulaStepTest`). UI-facing phases:
  `./gradlew :kzen-auto-test:selfTest` (opt-in, opens Chrome; **beware a stale tester JVM on
  port 18081 — kill it first**), plus a manual
  `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` smoke.
- Mark the phase checkbox in this file's tracker when done, and append a short "as-built" note
  to the phase section if the implementation deviated.

---

## Phase 1 — Definition caching + hot-path correctness (kzen-lib only)

**Goal:** one `tryDefine` per notation version instead of 2–3 per command; derived notation views
survive edits; the known correctness cliffs get real errors. No SPI or contract change.

**Why first:** every later phase (closure digests, instance caches, incremental define) keys off
"definition per notation version is canonical and cheap to reach".

### 1a. Digest-keyed definition cache in `DirectGraphStore`

Add `graphDefinitionCacheDigest: Digest?` / `graphDefinitionCache: GraphDefinitionAttempt?`
beside the existing `graphNotationCache` (`DirectGraphStore.kt:33-35`), keyed by
`graphNotation.digest()`. Route both `graphDefinition()` paths (:152-170) and the semantic-command
define in `applyInPlace` (:200-203) through it. Effect: the old-notation define inside a semantic
command becomes a cache hit (it was computed at the previous publish), `observe()` and
`publishRefresh()` become hits, and `MirroredGraphStore`'s refresh path stops paying a second full
define. Also resolve the `LocalGraphStore.kt:49` TODO (decide: keep name `graphDefinition`,
document that it is cached). `refresh()` (:377-381) must clear the new slots.

Note `GraphDefinitionAttempt.transitiveSuccessful` is a lazy `val` — caching the attempt instance
also makes that O(n²)-worst-case pruning run at most once per notation version.

### 1b. Patch `coalesce` across edits

`GraphNotation.withNewDocument` / `withModifiedDocument` / `withoutDocument`
(`GraphNotation.kt:295-331`) currently return instances whose `coalesce` lazily re-flattens all
documents. Change: when `this.coalesce` is already materialized, seed the new instance's
`coalesce` by patching — remove the old document's expanded entries, add the new document's
(`DocumentNotation.expand` is per-document) — via persistent-map ops, O(document size · log n).
Implement with a private constructor/factory taking a pre-seeded coalesce; keep the lazy full
flatten as the cold path. **Do not** carry over `inheritanceChainCache` (chains can cross
documents through by-name resolution; correctness over cleverness — chains are cheap relative to
define). Add a test: modify one document in a two-document graph, assert `coalesce` object
identity is preserved for the untouched document's entries.

### 1c. Kahn's algorithm for `GraphCreator.constructionLevels`

Replace the scan-until-satisfied loop (`GraphCreator.kt:73-141`) with indegree-tracked topological
leveling: build the edge map once from `definition.references()` (resolving each reference once
via the locator), then peel zero-indegree levels. Preserve observable semantics: nullable empty
references don't create edges (current `findSatisfied` logic :123-129), level membership stays
deterministic (insertion order within a level), and the unsatisfiable case still reports via
`findUnsatisfied`-quality diagnostics (keep or improve `UnsatisfiedSet`). This turns O(n²·E)
worst-case leveling into O(V+E).

### 1d. Correctness cliffs

- `GraphCreator.tryLocate` (:178-200): ambiguous multi-candidate resolution currently throws
  `TODO(...)`. Change to `IllegalArgumentException` naming the reference, host, and all
  candidates (definition-time ambiguity already surfaces as a definer failure; this is the
  create-time counterpart).
- `GraphDefiner.tryDefine` (:99-101): replace `check(levelCount < 16) { "too deep" }` with a
  named constant and an error listing the still-open locations and which definer each is waiting
  on (the data is at hand in the loop).
- Delete dead state: `levelErrors` (`GraphDefiner.kt:95` — populated, cleared, never read),
  the commented `levelPartial` block (:185-187), the commented `locateOptional` variants in
  `ObjectLocationMap.kt:54-87`.
- `ReflectionRegistry` (`reflect/ReflectionRegistry.kt`): resolve the `TODO: make threadsafe` —
  registration happens at module-register time, reads afterward; either synchronize both or
  document + enforce a freeze-after-boot (prefer a simple synchronized map; contention is nil).

### Verification

Baseline suites. Add: a `DirectGraphStore` test asserting the same `GraphDefinitionAttempt`
instance is returned for an unchanged notation and a fresh one after a command; the 1b identity
test; a `GraphCreator` test for the ambiguity error and one exercising a deep (>16-object) linear
dependency chain through define+create (guards both 1c and the old level-cap assumption — note
the definer's level count is meta-tower depth, so 16 stays plenty *there*; the new error message
is what's being tested). Rebuild kzen-auto against the published lib; run its baseline.

**As-built (2026-07-12).** Landed as specified, with three notes. (1) *Create-time ambiguity is
only reachable via global-host resolution* (the creator lookup in `createGraph`'s main loop):
`Locator.locateAll`'s host-document filter either disambiguates a location-hosted reference or
empties it to null (→ the unsatisfied-set error), so the plan's "same name in two documents,
referenced from a third" scenario surfaces as a clean unsatisfied diagnostic, not ambiguity.
`GraphCreatorTest` pins the ambiguity error by shadowing `AttributeObjectCreator` in a user
document (shadow's own creator path-qualified to dodge a self-edge). (2) `ReflectionRegistry` is
commonMain where `synchronized` doesn't exist — added `tech.kzen.lib.platform.platformSynchronized`
expect/actual (JVM = `synchronized`, JS = direct invoke). (3) Kahn leveling resolves references
once against the full location set (deterministic) instead of incrementally against closed-so-far;
level membership and in-level ordering are preserved (ordinal sort).

---

## Phase 2 — Closure content digest (retire the notation-map compare)

**Goal:** a cheap, canonical answer to "did the transitive closure of X change?" so consumers
compare one `Digest` instead of materializing and deep-comparing notation maps.

**Design decision — digest the notation closure, not the definitions.** Definitions cannot be
value-compared (they embed definer-allocated runtime scaffolding — the documented reason at
`ServerLogicController.kt:110-115`), and forcing definers to stop allocating (Flow's channel
holders) is a behaviour change deferred to phase 3's instantiation work. `ObjectNotation` is
`Digestible` with a memoized digest that survives structural sharing, so a closure digest over
notations is both cheap and exactly the invariant the consumer wants ("same source ⇒ same
compiled behaviour", the same reasoning `closureNotations` encodes today).

### Steps

1. kzen-lib: add to `GraphDefinition` (`model/definition/GraphDefinition.kt`):
   `fun transitiveClosure(locations): Set<ObjectLocation>` (extract the BFS out of
   `filterTransitive` :55-100 so closure computation and filtering share one implementation) and
   `fun transitiveDigest(documentPath | locations): Digest` — an **ordered** combine (sort by
   location string for determinism) over each closure member's `(location digest, ObjectNotation
   digest)` pairs, pulling notations from `graphStructure.graphNotation.coalesce`. Document: the
   digest covers the notation the definitions were derived from, not the definitions.
2. kzen-auto: replace `ServerLogicController.baselineNotations` / `closureNotations`
   (`ServerLogicController.kt:745-790` + the `LogicState` field + rationale comments :110-115)
   with a single `baselineClosureDigest: Digest` computed at compile/migrate time and compared
   per drive via `transitiveDigest(documentPath)`. Keep behaviour identical: digest inequality ⇒
   pending migration.
3. Check `JobLogicCompiler` / `JobChannelSynthesis` migrate-tick usage — if it re-synthesizes to
   compare, key it off the same closure digest.
4. Docs: kzen-lib architecture doc gains a paragraph on closure digests; kzen-auto architecture
   §"pendingMigration" note updated.
5. Downstream coordination: script-plan phase 3 later widens this same signal to weakly-linked
   logic documents, and the move-to plan (`2026-07-10_execution-control.md`) updates the same
   baseline at `moveTo` — both work in the digest domain once this phase lands (notes added in
   those plans).

### Verification

Baseline suites; kzen-auto Job migration tests (`JobMigrationTest`) and a manual live-edit
smoke: start a Script run, edit an unrelated document (no migrate), edit the running document
(migrate fires) — same behaviour as before, now via digest.

---

## Phase 3 — Scoped instantiation + instance caching

**Goal:** stop building whole-project or whole-document instance graphs to obtain one object.
The two hot spots: Flow's per-vertex rebuild and the detached/task executors' per-REST-call
full-graph build.

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
graph). Design sketch stays in this plan; only implement if the per-vertex closure measurement
still shows waste. Record the measurement in the as-built note either way.

### 3b. Detached/task executors: scope + digest-keyed cache

`ModelDetachedExecutor.execute`/`executeDownload` (`ModelDetachedExecutor.kt:31-56, 59-75`) and
`ModelTaskRepository.submit` (:129-136):

1. Scope: `filterTransitive(actionLocation)` instead of `filterDefinitions(serverAllowed)` —
   from O(project) to O(action closure). `serverAllowed` filtering still applies first (never
   instantiate client-only objects server-side): filter, then closure.
2. Cache: a small `GraphInstanceCache` in kzen-auto (`server/service/exec/`), keyed by
   `transitiveDigest(actionLocation)` (phase 2), holding the created `GraphInstance` per action
   location. Per call: recompute the digest (cheap — memoized notation digests), hit ⇒ reuse
   instance, miss ⇒ rebuild and replace. **In-phase survey step (mandatory):** verify every
   `DetachedAction` / `DetachedDownloadAction` / `ManagedTask` implementation treats instance
   fields as immutable config (the per-request statelessness the REST layer already implies).
   Any stateful one found either gets fixed or the cache keys it out (opt-out by archetype
   attribute, not by class `when`). Document the statelessness contract on `DetachedAction`.
3. `ModelTaskRepository` keeps its `// TODO: add GraphInstanceAttempt` for phase 6.

### 3c. `GraphEnvironment` provider registration

`MapGraphEnvironment` gains `put(className, provider: () -> Any)` with memoized first-resolve
(additive; existing eager `put` stays). Then `KzenAutoContext` (:112-113, :152-199) and
`ClientContext` (:110-122) register providers directly and stop passing `() -> GraphEnvironment`
thunks into `ServerLogicController` / `ModelDetachedExecutor` / `ModelTaskRepository` — the
constructor parameter becomes plain `GraphEnvironment`. Deletes the deferred-provider
cycle-break and its rationale comments on both sides.

### Verification

Baseline + selfTest (Flow FizzBuzz exercises per-vertex execution; Script sub-run exercises
compile). Manual: Report input/output panel actions (detached hot path) — behaviour unchanged,
server log timing before/after worth capturing in the as-built note. Job suite for 3c (env
threading through `EngineJobControl`).

---

## Phase 4 — Incremental define (per-object definition cache) — **riskiest phase**

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
consumers keep hand-rolling that scan). Server `LogicCompiler`'s `LogicDocument` interface check
stays the authoritative runtime guard; the notation marker is the UI-gating twin. Update the
architecture-doc gotcha to describe the new mechanism. Tag Script/Flow/Report/Job archetypes.

### Verification

Baseline + report UI smoke (filter/pivot editing round-trips — codec parity with the old
`ofNotation` verified by unit tests comparing outputs over the existing notation fixtures).
selfTest covers ribbon gating (Script/Job run controls present); manually confirm a Flow document
still shows Run controls.

---

## Phase 6 — Error surface (structured definition/creation failures)

**Goal:** a failed object stops surfacing as `"Missing: <location>"` at use time; consumers get
the failure origin without reconstructing it.

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
*other* objects in the same document.

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

**Coordinate with `2026-07-10_yaml-parser-strings-and-comments.md`** (same touch-points:
`YamlNotationParser.unparseDocument`, the unparse emitters): land that parser/emitter rework
*first* — its one-time output churn (values re-emitting bare/`|-`) should precede byte-identical
segment preservation, so 7b's per-object equality operates on the new stable format.

### Verification

Baseline (notation suites are the core safety net for both halves); kzen-auto raw-editor smoke:
hand-comment a document, edit a *different* object via the structured UI, confirm the comment
survives on disk; `SetDocumentObjectsCommand` (raw save) still round-trips.

---

## Sizing and sequencing

| Phase | Size | Risk | Depends on |
|---|---|---|---|
| 1 | one session | low (cache + mechanical) | — |
| 2 | one session (small) | low | 1 (cheap definition reach helps, not required) |
| 3 | one session | medium (statelessness survey) | 2 (digest keys) |
| 4 | one full session | **high** (invalidation correctness) | 1 |
| 5 | one session | low-medium (codec design taste) | — |
| 6 | one session (light) | low | — |
| 7 | one session (7b is the bulk) | medium (parser edge cases) | — |

Phases 5/6/7 are independent of 1–4 and of each other; reorder freely if priorities shift.
If a session runs long, land the kzen-lib half first (publishToMavenLocal keeps kzen-auto
buildable) and note the split in the tracker.
