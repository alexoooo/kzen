# Document digest must cover pruned (undefined) members and member order

**Status:** planned (not started)
**Repos:** `kzen-lib` (the fix + tests), `kzen-auto` (regression test + doc-comment touch-ups). No client (JS) changes.
**Motivating bug:** a Job document's validation never re-runs after an edit — fixing a Formula Source
expression from `1..100x` to `1 .. 5` leaves the old "Expecting an element" error on the Worker card
(and the run cluster's invalid state) until the server restarts.

---

## 1. Context — the observed bug and its evidence chain

Reproduced 2026-07-23 against the live dev server (`127.0.0.1:8080`), document `main/Job-1.yaml`:

1. The edit **did** commit: on-disk notation reads `code: 1 .. 6`.
2. A fresh call to the validator —
   `GET /action/detached?path=auto-jvm/job/job-jvm.yaml&object=JobValidator&host=main/Job-1.yaml` —
   still returned `error: "Expecting an element"` for `main.workers/Formula Source`.
3. The durable Kotlin compile cache (`kzen-auto/work/code-cache/`) had **no**
   `Column_Formula_Source_*` entry newer than the previous day, and both existing entries were
   *successes* (`success.txt`, no `err.txt`). So `1 .. 5` / `1 .. 6` were never compiled at all —
   the error string is the boot-time `1..100x` result replayed from `JobValidationCache`.

The client side is **not** involved: `JobController.refreshValidationIfNeeded` correctly refetches on
every notation change (reference-compare of `DocumentNotation`); it just keeps receiving the stale
server answer. Do not touch the JS side.

## 2. Root cause

`JobValidator.execute` (kzen-auto-jvm `objects/job/JobValidator.kt`) keys its cache with

```
LogicValidationDigest.documentClosureKey(documentPath, graphDefinitionAttempt.transitiveSuccessful)
```

which bottoms out in kzen-lib's `GraphDefinition.transitiveDigest(documentPath)`
(`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/definition/GraphDefinition.kt`).
That overload seeds the digest from

```kotlin
private fun documentObjectLocations(documentPath: DocumentPath): List<ObjectLocation> {
    return objectDefinitions.map.keys.filter { it.documentPath == documentPath }
}
```

— i.e. **only objects that successfully defined**. But every Job Worker is *always pruned* from
`transitiveSuccessful`: Worker channel ports are blank in saved notation by design (channels are
synthesized in-memory by `JobChannelSynthesis`), and `GraphDefinitionAttempt.transitiveSuccessful`
drops any object with a required empty reference. So for a Job document the digest covers only
`main` and its archetype closure — none of the Workers' notation (including the `code:` attribute)
enters the key. Editing a Worker's expression, or adding/removing/reordering Workers (each a separate
nested object notation), produces the **same digest**, and the cache serves the first-ever computed
`JobValidation` forever. Only a server restart (empty cache) recomputes — which is why the error was
"correctly identified" on first load.

The same digest has **three consumers**, all currently blind to Job Worker edits:

| Consumer | Path | Consequence of the blindness |
|---|---|---|
| `JobValidationCache` | kzen-auto-jvm `objects/job/JobValidationCache.kt` (editor's `JobValidator.execute` + run path `JobRun`) | stale validation errors/types in the editor; stale inferred payload types threaded into a run's Worker controls |
| `ScriptValidationCache` | kzen-auto-jvm `objects/script/ScriptValidationCache.kt` | *not* affected in practice — script steps define successfully, so they are inside the digest (this is why Script never showed the bug) |
| Live-edit migration signal | kzen-auto-jvm `service/impl/ServerLogicController.kt` — `LinkedLogicDocuments.transitiveDigest` at `start()` (baseline), `pendingMigration`, `moveTo` | editing a Job Worker while a run is paused does not trigger `RunEngine.migrate` — the edit is silently ignored on resume/step |

`LinkedLogicDocuments.transitiveDigest` (kzen-auto-jvm `service/impl/LinkedLogicDocuments.kt`) is just
a sorted combine of `graphDefinition.transitiveDigest(documentPath)` over the root document plus its
linked callee documents, so fixing the kzen-lib overload fixes all three consumers at once —
including callee Jobs reached through a `RunWorker` link.

### A second, sibling gap: member order

The content combine inside `transitiveDigest` is **sorted by location string** (deliberately, for
determinism), and a pure reorder (`ShiftObjectTreeCommand` — Worker drag/drop, Script step shift)
changes no member's own notation. So even for fully-defined documents the digest is blind to
reorders — yet order is semantic: Job channel derivation is order-driven, and Script steps derive
their order from document position. A Worker drag on a paused run today neither re-keys validation
nor triggers migration. Same root idea (the digest under-covers the document), so this plan fixes
both in the same place.

## 3. Design

**Fix in kzen-lib, in the `documentPath` overload of `GraphDefinition.transitiveDigest`.** The
document-scoped digest becomes three components in one `Digest.build`:

1. the document's notated members **in document order** (the order/membership signal — covers
   reorder, add, remove);
2. the sorted content combine over the union of
   - the transitive closure of the document's **defined** members (exactly today's behaviour), and
   - **every object notated in the document**, defined or not (covers pruned-member edits).

Properties of this design:

- **General**: any flavour whose document carries pruned-by-design members (Job Workers today,
  anything similar tomorrow) or position-derived semantics (Job channels, Script steps) gets a
  content-correct digest; no flavour-specific code anywhere.
- **Digest values change for all documents** (the ordered-members preamble is new). That is safe:
  nothing persists these digests — `ScriptValidationCache` / `JobValidationCache` are in-memory
  Caffeine caches, `ServerLogicController.baselineClosureDigest` is in-memory per run, and the
  durable `code-cache` on disk keys on `KotlinCode.signature()`, a different digest entirely.
- **Semantics preserved elsewhere**: the `Collection<ObjectLocation>` overload (used per-object by
  kzen-auto's `GraphInstanceCache`) and `filterTransitive` / `documentObjectLocations` (which feed
  instantiation and MUST stay defined-only) are not changed.
- **Known accepted limit**: a pruned member contributes only its *own* notation, not its archetype
  chain (its references cannot be walked without a definition). Worker archetypes live in classpath
  notation (`auto-jvm/job/job-worker.yaml` etc.), which is immutable in a running process, so this
  loses nothing today. Note it in the KDoc.

### Alternatives rejected

- *Fix only in kzen-auto's `LogicValidationDigest`* (add raw document-notation digests there): covers
  the two validation caches but leaves `ServerLogicController`'s migration baseline blind — it calls
  `LinkedLogicDocuments.transitiveDigest` directly. Fixing the shared primitive covers everything and
  keeps the "key semantics cannot drift" contract between the Script and Job caches.
- *Key the Job cache on the synthesized definition* (where Workers define): would require running
  `JobChannelSynthesis` before every cache lookup — the synthesis skip is the point of the cache.

## 4. Changes

### 4.1 kzen-lib — `GraphDefinition.kt`

File: `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/definition/GraphDefinition.kt`

Replace the two `transitiveDigest` functions (keep `documentObjectLocations` as-is — it still serves
`filterTransitive(documentPath)`):

```kotlin
    //-----------------------------------------------------------------------------------------------------------------
    /**
     * Content digest of the transitive closure's source notation: an ordered combine (sorted by
     *  location string) over each closure member's location and [ObjectNotation] digest, pulled from
     *  the coalesced graph notation. Covers the notation the definitions were derived from, NOT the
     *  definitions themselves (definitions can embed definer-allocated runtime scaffolding with
     *  identity equality) — same source notation implies same compiled behaviour, so digest equality
     *  answers "would recompiling this closure change anything?"
     */
    fun transitiveDigest(objectLocations: Collection<ObjectLocation>): Digest {
        return notationDigest(transitiveClosure(objectLocations))
    }


    /**
     * Document-scoped digest, covering everything document-level semantics can depend on:
     *  the document's notated members IN DOCUMENT ORDER (order is semantic — Job channel derivation
     *  and Script steps are position-driven, while the content combine below is deliberately
     *  order-independent), then the content combine ([transitiveDigest]) over the defined members'
     *  closure WIDENED by every notated member, defined or not. On a pruned (undefined-by-design)
     *  member — e.g. a Job Worker, whose blank channel ports drop it from a transitive-successful
     *  definition — the closure alone is blind to edits, which is exactly what a validation cache or
     *  live-edit signal keyed on this digest must see. A pruned member contributes only its own
     *  notation (its references cannot be walked without a definition); its archetype chain is
     *  classpath notation, static per process.
     */
    fun transitiveDigest(documentPath: DocumentPath): Digest {
        val notatedMembers = graphStructure.graphNotation.documents[documentPath]
            ?.objects?.notations?.map?.keys
            ?.map { ObjectLocation(documentPath, it) }
            ?: listOf()
        val definedMembers = notatedMembers.filter { it in objectDefinitions }
        val widened = transitiveClosure(definedMembers) + notatedMembers

        return Digest.build {
            for (location in notatedMembers) {
                addDigestible(location)
            }
            addDigestible(notationDigest(widened))
        }
    }


    private fun notationDigest(objectLocations: Set<ObjectLocation>): Digest {
        val coalesce = graphStructure.graphNotation.coalesce

        return Digest.build {
            for (location in objectLocations.sortedBy { it.asString() }) {
                addDigestible(location)
                addDigestibleNullable(coalesce[location])
            }
        }
    }
```

Notes for the implementer:

- Member order comes from `documents[documentPath].objects.notations.map` — the document's own
  ordered map (the same source `DocumentNotation.indexOf` positions read), not from `coalesce`
  iteration order. Adjust the accessor chain to the actual `DocumentNotation` API if it differs
  (see `JobController.insertArchetypeAt`, which reads `documentNotation.objects.notations.map.keys`).
- `it in objectDefinitions` works — `ObjectLocationMap` supports `contains` (see the existing
  `require(objectLocation in objectDefinitions)` inside `transitiveClosure`).
- `transitiveClosure(definedMembers) + notatedMembers` is `Set + List → Set`; ordering inside the
  content combine is imposed by the sort in `notationDigest`.
- `Digest` is itself `Digestible` (`LinkedLogicDocuments` already does
  `addDigestible(graphDefinition.transitiveDigest(documentPath))`), so nesting `notationDigest`'s
  result is fine.
- `coalesce[location]` is never null for a notated member; keep `addDigestibleNullable` (it also
  serves closure members, same as today).
- A nonexistent/empty document degrades to an empty member list — deterministic, no throw.
- `transitiveClosure` can still throw on a non-closed definition (e.g. called on `successful()`
  rather than `transitiveSuccessful` mid-edit) — unchanged; kzen-auto's
  `LogicValidationDigest.documentClosureKey` already catches and falls back to uncached compute.
- `documentObjectLocations` stays exactly as-is — it still serves `filterTransitive(documentPath)`,
  whose defined-only semantics MUST NOT change (it feeds instantiation).

### 4.2 kzen-lib — `docs/architecture.md`

Line ~81, the **Closure content digest** bullet: extend it with one sentence, e.g.

> The document-path form additionally digests the document's member list *in document order* and
> every object *notated* in the document, defined or not — a reorder, or an edit to a
> pruned-by-design member (a Job Worker with blank channel ports), must still invalidate validation
> caches and the live-edit migration signal.

### 4.3 kzen-lib — `GraphDefinitionTransitiveTest.kt`

File: `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/GraphDefinitionTransitiveTest.kt`

Extend the existing fixture with a pruned member. An object whose reference cannot be resolved is
pruned from `transitiveSuccessful` (same mechanism as a blank required reference — see
`GraphDefinitionAttempt.transitiveSuccessful`), so:

```kotlin
    private fun mainDocumentWithPruned(prunedTarget: String = "Missing"): DocumentNotation {
        return document("""
            Root:
              is: PlusOperation
              addends:
                - Dependency

            Dependency:
              is: DoubleValue
              value: 1.0

            Pruned:
              is: PlusOperation
              addends:
                - $prunedTarget
        """.trimIndent())
    }
```

New tests (keep the existing four unchanged — they must keep passing):

```kotlin
    @Test
    fun `Editing a pruned member changes the digest`() {
        val baseline = definition(main = mainDocumentWithPruned())

        // Precondition: the fixture member really is pruned from the transitive-successful definition.
        val prunedLocation = ObjectLocation(mainPath, ObjectPath.parse("Pruned"))
        assertFalse(prunedLocation in baseline.objectDefinitions)

        assertNotEquals(
            baseline.transitiveDigest(mainPath),
            definition(main = mainDocumentWithPruned(prunedTarget = "AlsoMissing"))
                .transitiveDigest(mainPath))
    }


    @Test
    fun `Pruned member in another document preserves the digest`() {
        // The widening is document-scoped: an unrelated document's pruned member is not in this key.
        val withPrunedOther = document("""
            Other:
              is: DoubleValue
              value: 2.0

            Pruned:
              is: PlusOperation
              addends:
                - Missing
        """.trimIndent())

        assertEquals(
            definition().transitiveDigest(mainPath),
            definition(other = withPrunedOther).transitiveDigest(mainPath))
    }


    @Test
    fun `Reordering document members changes the digest`() {
        // Order is semantic (position-driven steps / order-driven Job channels), and the content
        // combine is deliberately order-independent — the ordered-members component must catch it.
        val reordered = document("""
            Dependency:
              is: DoubleValue
              value: 1.0

            Root:
              is: PlusOperation
              addends:
                - Dependency
        """.trimIndent())

        assertNotEquals(
            definition().transitiveDigest(mainPath),
            definition(main = reordered).transitiveDigest(mainPath))
    }
```

(`mainDocument()` declares `Root` before `Dependency`, so `reordered` is the same two notations in
swapped document order. Imports to add: `ObjectLocation`, `ObjectPath`, `assertFalse`.)

The three existing digest tests (`Same notation digests equal across independent builds`,
`Editing a closure member changes the digest`, `Editing an object outside the closure preserves the
digest`) must keep passing unchanged — they pin determinism and scoping, which the new components
must not break.

### 4.4 kzen-auto — `LinkedLogicDocumentsTest.kt` regression test

File: `kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/service/impl/LinkedLogicDocumentsTest.kt`

The existing `test/job-run-host-test.yaml` fixture (a Job whose Workers all have blank ports —
`main.workers/source` is a `FormulaSourceWorker` with `code: "(1..3)"`) is exactly the real shape.
Add, next to `signalSeesCalleeEditsButIgnoresUnlinkedDocumentEdits`:

```kotlin
    // Job Workers are pruned from transitiveSuccessful (blank channel ports by design), yet editing one
    // must change the Job's signal — it keys the validation caches AND the live-edit migration compare.
    @Test
    fun signalSeesJobWorkerEdits() {
        val baseNotation = AutoTestUtils.readNotation()
        val baseline = jobSignalDigest(baseNotation)

        val workerEdited = edit(
            baseNotation,
            ObjectLocation(jobRunHost, ObjectPath.parse("main.workers/source")),
            "code", "(1..4)")
        assertNotEquals(baseline, jobSignalDigest(workerEdited),
            "Job Worker edit must change the Job's signal digest")
    }


    private fun jobSignalDigest(graphNotation: GraphNotation): Digest {
        val attempt = AutoTestUtils.graphDefinitionAttempt(graphNotation)
        return LinkedLogicDocuments.transitiveDigest(
            attempt.transitiveSuccessful, attempt.graphStructure, jobRunHost)
    }
```

This test **fails on current code** (that is the point) and passes with the kzen-lib fix. No fixture
file changes needed — the edit is applied in-memory via the file's existing `edit(...)` helper.

### 4.5 kzen-auto — doc-comment touch-ups (no behaviour)

- `objects/logic/LogicValidationDigest.kt` class doc: after "the root document's transitive
  closure", note that the document-scoped digest also covers the document's pruned members (Job
  Workers) and member order, citing `GraphDefinition.transitiveDigest(documentPath)`.
- `objects/job/JobValidationCache.kt` class doc: the parenthetical about key coverage can gain
  "including the Workers themselves, which are pruned from the definition but digested from
  notation". Keep it to one clause.

## 5. Build & verification

Order matters (variant-suffix coords route kzen-auto's jvm/js source sets through mavenLocal — see
the umbrella AGENTS.md gotcha). Same version, republish in place — **no version bump**.

```powershell
$env:JAVA_HOME = "$env:USERPROFILE\.jdks\temurin-25.0.3"   # CLI gradle needs the Java 25 daemon

# 1. kzen-lib: compile + all tests (new GraphDefinitionTransitiveTest cases live in kzen-lib-jvm)
cd ../kzen-lib
./gradlew build

# 2. Republish so kzen-auto's jvmMain/jsMain resolve the fixed bytecode
./gradlew publishToMavenLocal

# 3. kzen-auto: the regression test + the full jvm suite (covers JobValidator, JobRunWorkerTest,
#    Job migration/carryover tests — behaviour now changes: worker edits trigger migrate)
cd ../kzen-auto
./gradlew :kzen-auto-jvm:test --tests "*LinkedLogicDocumentsTest"
./gradlew build
```

kzen-project / kzen-launcher / kzen-shell also consume kzen-lib but nothing in this change touches
API surface; rebuilding them is optional (skip unless asked).

**Manual end-to-end check** (the original repro): restart the dev backend, open `main/Job-1.yaml`
with a broken Formula Source expression → error shows; fix the expression → within the debounce +
fetch cycle the error clears and the Worker card shows the inferred type. Cross-check that a fresh
`Column_Formula_Source_*` directory appeared under `kzen-auto/work/code-cache/` (proof the compile
actually re-ran). Optionally verify by REST:
`curl "http://127.0.0.1:8080/action/detached?path=auto-jvm/job/job-jvm.yaml&object=JobValidator&host=main/Job-1.yaml"`.

## 6. Out of scope / notes

- **No client changes.** The JS refetch logic (JobController epoch/busy work from
  `2026-07-22_validation-edit-activity-unification.md`) is correct and untouched. Its refetch
  trigger (own-document `DocumentNotation` reference change) already fires on worker edits,
  add/remove, and reorder — the server just now answers correctly.
- **Behaviour change to be aware of:** editing (or reordering) a Job Worker while a run is paused
  now (correctly) triggers live-edit migration on resume/step — previously it was silently ignored.
  The Job carryover machinery (`JobRun` channel drain/preload, `FormulaSourceWorker` cursor guard)
  was built for exactly this; the existing gated-worker migration tests in kzen-auto-jvm are the
  safety net. The same applies to pure Script step reorders (position-derived steps).
- Staging: the only new file is this plan (stage in the `kzen` repo). All code changes modify
  existing tracked files in `kzen-lib` / `kzen-auto`. Never commit — stage only.
