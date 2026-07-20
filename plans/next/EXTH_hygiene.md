# EXT-H — extensibility cluster hygiene (S1–S10 −S7) — implementation plan

> **✅ DONE 2026-07-20.** All nine S-items landed in one session. Trackers ticked in
> `../2026-07-06_custom-plugin-extensibility-analysis.md` (Settled findings + C7) and
> `../2026-07-16_master-plan.md` (Sprint-2 filler list). Verification: full `./gradlew build`
> green in kzen-auto — jvm test suite (incl. `FormulaStepTest`, `ScriptValidationCacheTest` whose
> registry digest component was refactored, and the `ScriptNotationTest` family) plus
> kzen-auto-common commonTest on **both** JVM and ChromeHeadless. Manual browser smoke (the
> Verification § matrix) is **not** done — it needs the user at the browser.
>
> **Deviations from the plan as written:**
> 1. **7c fixture** — the plan had `CustomViewModelBuilderTest` read the bundled `main/Custom.yaml`.
>    It can't: `AutoTestUtils.readNotation()` constructs its `ClasspathNotationMedia` with
>    `exclude = listOf(AutoConventions.autoMainDocumentNesting)`, so `main/` is invisible to every
>    test. Replaced with self-contained `notation/test/custom-view-model-test.yaml` +
>    `custom-prototype-elsewhere-test.yaml` — which also matches 7f's own stated rationale (S10 and
>    future curation can't break the pins). Consequence: the curated `Custom.yaml` of step 8 is
>    **not** covered by any automated test; the boot check in Verification § 5 is its only gate.
> 2. **7f is half-red — a real finding, handled per the C7 protocol.** Object rename is green.
>    Document rename is **broken for Custom exports** and the test is committed `@Ignore`d: kzen-lib's
>    `NotationReducerRefactor.adjustReferencesForRenamedDocument` only rewrites references to a
>    document's *root* objects (its own comment says so), and Custom exports are nested under
>    `main.objects/`. No kzen-lib fix attempted. Recorded under C7 in the analysis.
> 3. **7f caller fixture shape** — the plan specified an `abstract: true` holder for the
>    cross-document reference. That silently never rewrites: `locateReferences` walks object
>    *definitions*, and abstract objects have none. Replaced with the real production shape — a
>    `RunStep` whose `instructions` holds the location, exactly what `SelectLogicEditor` writes.
> 4. **7c edit choice** — "unrelated object edit" uses `abstract` rather than `named`. Changing
>    `named` provably does *not* change the model, because `CustomObjectInfo` derives only metadata,
>    abstract/tags, and export membership. The plan's assertion would have failed on correct code.
> 5. **Two extra pins added** while writing 7c/7d (`modelListsDocumentObjectsWithoutMain`,
>    `viewPathsHidesRootMain`) — cheap, and they anchor the projection contract the rest assume.
>
> Everything else landed as specified, including the note-only `@Synchronized`+`runBlocking` comment
> and the conservative S2 assignment placement (pinned by `incompleteDefinerCacheKeepsRetrying`).
>
> ---
>
> *(Original plan below, as written 2026-07-19.)*

> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-06_custom-plugin-extensibility-analysis.md` § "Settled findings — plan-ready now"
> (S1–S6, S8–S10; **S7 superseded** by `2026-07-14_attribute-editor-improvements.md` phase 1 —
> excluded). Master-plan slot: "EXT hygiene (S1–S10 minus S7) — one opportunistic session"
> (Sprint-2 filler, prerequisite-free; `2026-07-16_master-plan.md:124`). **D1–D7 remain
> unratified and are untouched** — nothing here depends on or preempts them (including R4's
> `IntRange` dedup, which belongs to D4). Every anchor verified 2026-07-19 against kzen-auto
> HEAD `ceb699d0` (kzen-lib `3d2ef97` referenced read-only — no kzen-lib change in this
> session). The analysis (2026-07-06) is the oldest source doc in the batch; drift found and
> absorbed below: the Custom client moved to a `view/` subpackage with an anchor-based
> drag-reorder rewrite, `GraphDefiner`/`GraphCreator` became kzen-lib `object`s (kills the
> spy-based test design S2 might have suggested), and kzen-auto-common commonTest +
> kzen-auto-jvm test harnesses (`AutoTestUtils`, `ScriptValidationCacheTest`,
> `NotationReducer.applySemantic`) now provide everything S9 needs. **All nine S-items still
> exist** — none was fixed by the Sprint-2 work (SER2–SER5, Y, G5, G7, TP1/TP3/TP4). One
> session.

## Scope & goal

Execute the settled hygiene findings for the Customize cluster (Custom / Plugin /
ObjectRegistry / DataFormat), each independently landable, ordered trivial-first with tests
beside their fixes and docs last:

1. **S1** — delete the `+"[foo bbb]"` debug artifact from the Custom object card.
2. **S3** — fix the `"Name found"` → `"Not found"` exception message.
3. **S2** — make `PluginReportDefinitionRepository`'s dead `cachedStructureDigest` fast-path
   live (assignment after refresh), with a regression test pinning hit + invalidation +
   retry-on-incomplete semantics.
4. **S6 (leak half only)** — stop the Custom task runner's orphan 1 s `pollLoop` after
   unmount via an explicit `dispose()`. Result **persistence** stays out (D6 unratified).
5. **S5** — cache `ObjectRegistryDocument.scan` behind a registry-content digest
   (`ScriptValidationCache` idiom), sharing the digest helper with that cache's key.
6. **S4** — move the per-render `listPrototypes` full-graph scan and the mid-render
   `clientStateGlobal.current()` reach out of `CustomView.render` into
   `CustomViewModel.Builder`, recomputed per notation event, preserving the Builder's
   reference-stability contract.
7. **S9** — first tests for the cluster: P3 cache pin (with S2), R3 cache pin (with S5),
   `CustomViewModel.Builder` reference stability, drag-drop view-index→doc-index translation,
   `ClassListSpec`/`FieldFormatSpec` notation round-trips, C7 exports-rename pin. Includes a
   small testability move of three pure jsMain model files to kzen-auto-common.
8. **S10** — replace the bundled `Custom.yaml` dev scratchpad with a curated minimal sample
   (notation content only; the `Adhoc*` classes stay in `src/main` untouched).
9. **S8** — docs refresh: architecture.md § 6 (Custom `main.logic`/`CustomGlobal`; registry
   row), § 7 (upload claim), js-architecture.md § 3 (custom/ "no sub-stores" exception).

Zero kzen-lib changes; zero `kzen-auto-plugin` changes (so no `publishToMavenLocal` needed).

## Dependencies & coordination

- **Prerequisite-free filler** (master plan `:120-124`); hard-independent of every other
  `plans/next/` item.
- **AE1 seam (`next/AE1_retire-old-fork.md`)**: AE1 owns the `PluginController` port off
  `AttributePathValueEditorOld` (the superseded S7) including the `valueType = long` fix and
  the whole-`ClientState` storage cleanup. **Do not touch `PluginController.kt` here.** S3 is
  server-side (`PluginReportDefinitionRepository.kt`) — no file overlap.
- **File safety**: `kzen-auto-jvm/src/main/resources/notation/main/Custom.yaml` is the
  **in-repo bundled overlay resource** — explicitly editable per the analysis (C2/S10 note:
  "editable as part of a ratified cleanup"). The protection in AGENTS.md applies to *runtime
  working* `notation/main/` directories and to the **sibling files** in this same resources
  directory (`Script*.yaml`, `Job*.yaml`, `Report.yaml`, `FizzBuzz/`, `Action Target/`, …),
  which double as the developer's dev-server working documents. Edit **only** `Custom.yaml`
  there; never delete/move/overwrite anything else under any `notation/main/`.
- **Docs staged last** so line references in S8's edits don't shift under the session's own
  code steps.
- kzen-shell / kzen-launcher / kzen-project: no action; nothing here changes wire or SPI
  surfaces.

## Current-state findings — per-S-item verification

| Item | Analysis anchor | Verified 2026-07-19 | Drift |
|---|---|---|---|
| S1 | `CustomObject.kt:181` | **Exists** — `+"[foo bbb]"` at `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/custom/view/obj/CustomObject.kt:181` (between the detached body and the task body) | File moved to `view/obj/` subpackage; line number coincidentally identical |
| S2 | `PluginReportDefinitionRepository.kt:41,50` | **Exists** — `private var cachedStructureDigest: Digest = Digest.missing` declared `:41`, compared `:50`, **never assigned**; per-plugin digest checks `:65-75`; deep path `tryDefine` + `createGraph` `:77-85` (`kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/plugin/PluginReportDefinitionRepository.kt`) | None in this file. **Environment drift**: kzen-lib `GraphDefiner` and `GraphCreator` are now `object`s (`kzen-lib-common/.../service/context/GraphDefiner.kt:30`, `GraphCreator.kt:15`) — they cannot be spied/subclassed, which dictates the test seam below. `GraphStructure.digest()` is memoized per instance (`GraphStructure.kt:42-53`) |
| S3 | `:214` | **Exists** — `?: throw IllegalArgumentException("Name found: $coordinate")` at `PluginReportDefinitionRepository.kt:214` (in `define`) | None |
| S4 | `CustomView.kt:61-67` | **Exists** — `props.clientStateGlobal.current()?.graphStructure()` at `view/CustomView.kt:61-62`, `CustomConventions.listPrototypes(graphStructure.graphNotation)` per render at `:67`. Builder contract at `view/CustomViewModel.kt:12-15` (comment) + `:39-69` (per-entry reuse when data-class-equal; whole-model reuse when equal). Builder invoked from `CustomController.onCustomState` (`CustomController.kt:146-155`), which only fires when `CustomState` changed (`CustomStore.updateIfChanged`, `model/CustomStore.kt:122-128`) | Client moved under `view/`; `listPrototypes` sole call site confirmed (`CustomView.kt:67`); `CustomConventions.listPrototypes` at `kzen-auto-common/.../custom/CustomConventions.kt:56-63` is an all-objects `directAttribute` probe |
| S5 | `ObjectRegistryDocument.scan` | **Exists** — `scan()` re-filters all documents and calls `reflect()` → `Class.forName` per registered class per invocation (`kzen-auto-jvm/.../server/objects/registry/ObjectRegistryDocument.kt:26-39,42-53`). Sole caller: `ScriptValidator.validate` (`.../script/ScriptValidator.kt:50`) | **Severity softened but real**: both validation call sites now ride `ScriptValidationCache` (editor detached path `ScriptValidator.kt:158-173`; run-compile path per the cache's KDoc), so `scan` runs only on validation-cache **miss** — but every miss (any closure edit, any distinct document) re-reflects every registered class, and a stale entry re-constructs `ClassNotFoundException` each time. The digest idiom to copy sits at `ScriptValidationCache.digestKey:74-86` (registry loop) |
| S6 | `CustomObjectTask.kt:86-97` | **Exists** — `pollLoop` at `view/obj/CustomObjectTask.kt:86-97` polls at 1 s (`taskPollIntervalMillis`, `:34`) while the task is active, with no unmount guard. Runners live in `CustomObject` component fields (`CustomObject.kt:49-72`); `CustomObject` has **no** `componentWillUnmount`. `CustomObjectDetachedRunner` (`CustomObjectDetached.kt:26-66`) has no loop — only the task runner leaks | File split (`CustomObjectTask.kt` / `CustomObjectDetached.kt`); line range identical |
| S8 | docs § 6 / § 7 / js § 3 | **All three passages stale** (details below) | `docs/architecture.md:287` additionally still says view mode is "persisted via `CustomGlobal`" — that global no longer exists (replaced by `DocumentBridge`/`CustomStoreKey`); `:247` plugin table row also claims "Upload" |
| S9 | zero tests for the cluster | **Confirmed** — no test file touches custom/plugin/registry/data (full test inventory swept). Harnesses now available: `AutoTestUtils` (jvm, reads full bundled+test notation), `ScriptValidationCacheTest` (edit-via-`NotationReducer.applyStructural` idiom), kzen-lib `RenameObjectRefactorTest` (`applySemantic` idiom), kzen-auto-common commonTest (runs JVM + ChromeHeadless; codec-test idiom `FilterSpecCodecTest`), kzen-auto-jvm test resources `notation/test/*.yaml` picked up by `AutoTestUtils.readNotation()` | kzen-auto-js *has* a `jsTest` source set but only a placeholder (`ClientTest.kt` asserts 42==42) — treat it as no net; don't build one this session |
| S10 | bundled `Custom.yaml` scratch | **Exists verbatim** — `foooxxxxxx`, `xxxxs`, duplicate `AdhocDetached`/`AdhocDetached1`/`AdhocTask`/`AdhocTask1` (`kzen-auto-jvm/src/main/resources/notation/main/Custom.yaml`). The `server.objects.custom.test.Adhoc*` fixtures **are still the only prototypes in a fresh install**: `grep "is: Prototype"` over bundled notation hits only `Custom.yaml:2,20` (the `Prototype` marker archetype itself is `common-document.yaml:398`). The `Adhoc*` classes are referenced **only** from `Custom.yaml` (repo-wide grep) — renaming/tidying notation objects cannot collide with the `@Reflect`-in-src/main constraint: **classes stay; only notation content changes** (confirmed) | None |

Other verified context used below: `exports` meta `{is: List, of: ObjectLocation, by: Nominal}`
at `common-document.yaml:390-395` (analysis said 391-396 — 1-line drift); exports entries
written as `objectPath.asString()` scalars at `CustomViewStore.kt:204`; `SelectLogicEditor`
writes cross-document references as `ScalarAttributeNotation(objectLocation.asString())`
(`script/display/edit/SelectLogicEditor.kt:236-244`) and consumes
`customDocumentExportedLogic` at `:129`; `SelectObjectEditor` consumes `customDocumentExports`
at `edit/SelectObjectEditor.kt:142`. The drag-reorder translation the analysis cited at
`CustomViewStore.kt:119-146` was **rewritten** since (anchor-based): now `onDrop` `:111-146` +
`isFilteredFromView` `:149-151` + `anchorAfterMove` `:154-159`, with the shared
`computeDropIndex` in jsMain `common/dragdrop/`.

## Pre-resolved questions

1. **S2 — where exactly does the assignment go?** Capture
   `val structureDigest = graphStructure.digest()` once at the top of
   `refreshCacheIfRequired()`; compare against `cachedStructureDigest`; assign
   `cachedStructureDigest = structureDigest` **only at the two points where the definer cache
   is complete** — the existing `:73-75` early return, and the end of the method behind a
   recheck of the same condition (`metadataByDefinerCache.keys == pluginObjectLocations`).
   Rationale: an *incomplete* cache (a plugin whose jar is missing → `jarClassLoader()` null →
   `continue` at `:94-95` without caching; or a plugin whose definition failed) must keep
   retrying on later calls — today's accidental behavior, and the only path by which a jar
   that appears on disk *without a notation change* ever gets picked up. Assigning
   unconditionally would silently freeze such a plugin out until the next notation edit.
2. **S2 — test seam.** Black-box observation is impossible: the fast path still calls
   `graphStore.graphStructure()` (needed for the digest), and the deep path's only externally
   visible collaborators are the kzen-lib singletons `GraphDefiner`/`GraphCreator` (now
   `object`s — not mockable). Decision: add an `internal var refreshCount: Int = 0; private set`
   incremented immediately after the top-level fast-path check (i.e., counts full-refresh
   executions). Kotlin `internal` is visible to the module's own test compilation; no public
   API change. Documented as a test seam in a comment.
3. **S2 — `@Synchronized` + `runBlocking`**: **note-only**, per the analysis's parenthetical
   and this brief. All five public methods hold the monitor across
   `runBlocking { graphStore.graphStructure() }` on request threads — pre-existing, correct,
   potentially slow under contention. Add one code comment flagging it; rework belongs to the
   post-ratification plugin phase (D2/P4 territory). Not trivially safe to change (lock
   granularity interacts with the two-level cache), so out.
4. **S4 — where does the Builder run so it's "recomputed per notation event"?**
   `CustomController.onCustomState` (the current Builder call site) fires only when
   `CustomState` changed — a prototype added in *another* document changes `graphStructure`
   but not this document's notation, so the picker would go stale. Decision: move the Builder
   **into `CustomStore`** and run it in `onClientState` (which fires on every
   `ClientStateGlobal` publish = every notation event while mounted), carrying the result on
   `CustomState` as a derived `viewModel` field. Equality does the rest: the Builder returns
   the previous instance when nothing changed, so `updateIfChanged` suppresses no-op
   publishes. Net effect vs today: the picker (and per-object infos, which read inherited
   metadata) now also refresh on cross-document changes — strictly less stale, and the
   full-graph scan runs once per notation event instead of once per render.
5. **S5 — cache home and key.** A notation-digest-keyed memo in the `ObjectRegistryDocument`
   companion (Caffeine, `maximumSize(10)` — same dependency `ScriptValidationCache` already
   uses in this module). Key: a new shared helper
   `ObjectRegistryConventions.scanDigest(graphNotation)` digesting, for each
   `isObjectRegistry` document sorted by path, the path + sorted class names — extracted from
   (and then reused by) `ScriptValidationCache.digestKey:74-86` so the two can't drift.
   Caching the *scan result* under a process-static companion is sound for the same reason
   that cache's KDoc already records: classpath availability of a declared class is
   process-static, so `(registry class lists) → scan` is a pure function of the key within a
   JVM. The `scan()` signature is unchanged (still a companion function — its caller
   `ScriptValidator.validate` is itself a companion static; threading a service through would
   touch the run-compile path for no gain).
6. **S6 — guard shape.** Explicit `dispose()` (a `disposed` flag checked in `pollLoop`'s
   condition and after each `delay`), called from a new `CustomObject.componentWillUnmount`.
   Rejected alternative: stopping when `observers.isEmpty()` — it overloads observer
   semantics and ties the poll's lifetime to header/body mount incidentals. `cancel()` is
   deliberately **not** called on unmount: the server-side task is fire-and-forget by design;
   only the client poll stops. The detached runner needs nothing (single request, no loop).
7. **S9 — where do client-logic tests live?** kzen-auto-js has no real JS test net (placeholder
   only) and this session doesn't build one. Instead: (a) **move** the three pure,
   React-free jsMain model files (`CustomObjectInfo`, `CustomViewModel`,
   `CustomViewExports`) to kzen-auto-common `commonMain` — verified they import only kzen-lib
   common types + `CustomConventions`, no `@Reflect` (KSP untouched); (b) **extract** the
   drag-drop view-index→doc-index translation from `CustomViewStore.onDrop` into a pure
   common function; (c) test the Builder from **kzen-auto-jvm src/test** (precedent:
   `ScriptDependencyAnalysisTest` tests common classes from the jvm module, and
   `AutoTestUtils.readNotation()` supplies a real `GraphStructure` cheaply), and the
   translation + spec codecs from **kzen-auto-common commonTest** (runs on JVM *and*
   ChromeHeadless). C7 and the two cache pins are jvm-only by nature.
8. **S9/C7 — rename-pin mechanics.** kzen-lib's
   `NotationReducer().applySemantic(graphDefinitionAttempt, RenameObjectRefactorCommand(loc, newName))`
   returns a `NotationTransition` with Nominal references rewritten
   (`NotationCommand.kt:267,273`; idiom: kzen-lib
   `kzen-lib-jvm/src/test/.../RenameObjectRefactorTest.kt`, which asserts rewritten reference
   attributes after rename). The kzen-auto test drives the same API over a self-contained
   fixture document pair (below) using `AutoTestUtils.readNotation()` +
   `graphDefinitionAttempt()`. Assertions are locate-based (parse the scalar, `coalesce.locate`)
   rather than string-format-based, so they don't encode the reference serialization.
9. **S10 — content bar.** Minimal per the analysis: the two Adhoc runners renamed/tidied with
   real descriptions; no new classes, no new prototype library. Descriptions ride as YAML
   comments (always safe) **plus** `description:` attributes on the **abstract** prototype
   objects only (abstract objects are never defined/instantiated, so an extra attribute can't
   break definition; `description` is already an `AutoConventions`-managed attribute —
   `AutoConventions.kt:35,53` — so it's hidden from the per-object attribute editors).
   Post-Y quoting rule respected: any scalar containing `:` must be quoted (`YamlParser`
   treats unquoted `a:b` as a nested map — AGENTS gotcha); the drafted content quotes all
   description strings defensively.

## Step-by-step implementation

Each step is independently landable; land in this order for reviewability. Stage each new
file via explicit `git add <path>` as soon as written (stage only, never commit).

### Step 1 — S1: delete the debug artifact (one line)

`kzen-auto-js/.../custom/view/obj/CustomObject.kt:181`: delete the `+"[foo bbb]"` line
(and the blank-line padding if it leaves a double gap).

### Step 2 — S3: fix the exception message (one word)

`kzen-auto-jvm/.../plugin/PluginReportDefinitionRepository.kt:214`:
`"Name found: $coordinate"` → `"Not found: $coordinate"`.

### Step 3 — S2: live cache fast-path + regression test

In `PluginReportDefinitionRepository.refreshCacheIfRequired()`:

```kotlin
private fun refreshCacheIfRequired() {
    val graphStructure = runBlocking {
        graphStore.graphStructure()        // NB: held under @Synchronized on request threads (pre-existing)
    }
    val structureDigest = graphStructure.digest()
    if (cachedStructureDigest == structureDigest) {
        return
    }
    refreshCount++                         // internal test seam: counts full refreshes

    // ... existing body unchanged ...

    if (metadataByDefinerCache.keys == pluginObjectLocations) {
        cachedStructureDigest = structureDigest      // NEW — complete via per-plugin caches
        return
    }

    // ... existing deep path (tryDefine / createGraph / jar loads) unchanged ...

    if (metadataByDefinerCache.keys == pluginObjectLocations) {
        cachedStructureDigest = structureDigest      // NEW — complete after refresh
    }

    // existing metadataByCoordinateCache rebuild unchanged
}
```

Plus `internal var refreshCount: Int = 0; private set` with a comment naming it a test seam,
and the note-only comment on `@Synchronized`+`runBlocking` (pre-resolved Q3). Test: step 7a.

### Step 4 — S6: dispose the task poll on unmount

`CustomObjectTask.kt` (`CustomObjectTaskRunner`):

```kotlin
private var disposed = false

fun dispose() {
    disposed = true
}

private suspend fun pollLoop() {
    while (!disposed && isActiveState(taskModel?.state)) {
        delay(taskPollIntervalMillis)
        if (disposed) {
            break
        }
        // ... existing body unchanged ...
    }
}
```

`CustomObject.kt`: add

```kotlin
override fun componentWillUnmount() {
    taskRunner?.dispose()
}
```

(No change to `CustomObjectDetachedRunner` — no loop. A disposed runner's in-flight `run()`
continuation may still call `notifyObservers()` once against an empty observer set —
harmless.) Verified by the smoke matrix (no unit net for jsMain; the runner's poll requires
a live task repository anyway).

### Step 5 — S5: digest-keyed scan cache + shared digest helper

1. `kzen-auto-common/.../registry/ObjectRegistryConventions.kt` — add:

```kotlin
/**
 * Content digest of every object-registry document's declared class list (document path +
 * sorted class names, documents sorted by path). Shared by ScriptValidationCache's key and
 * ObjectRegistryDocument's scan cache so the two can't drift. Classpath availability of a
 * declared class is process-static, so this notation-level digest fully keys a scan.
 */
fun scanDigest(graphNotation: GraphNotation): Digest {
    return Digest.build {
        for ((path, documentNotation) in
                graphNotation.documents.map.entries.sortedBy { it.key.asString() }) {
            if (! isObjectRegistry(documentNotation)) {
                continue
            }
            addDigestible(path)
            val classNames = classesSpec(documentNotation)?.classNames
                ?: continue
            for (className in classNames.map { it.asString() }.sorted()) {
                addUtf8(className)
            }
        }
    }
}
```

2. `ScriptValidationCache.digestKey` (`kzen-auto-jvm/.../script/ScriptValidationCache.kt:74-86`):
   replace the inline registry loop with
   `addDigestible(ObjectRegistryConventions.scanDigest(graphDefinition.graphStructure.graphNotation))`.
   (Key *values* change; the cache is in-memory, entries simply recompute once.)

3. `ObjectRegistryDocument` companion (`kzen-auto-jvm/.../registry/ObjectRegistryDocument.kt`):

```kotlin
// Scan result is a pure function of (registry class lists × process classpath); classpath is
// process-static, so a small companion memo keyed by the registry-content digest is sound.
private val scanCache: Cache<Digest, ObjectRegistryScan> = Caffeine.newBuilder()
    .maximumSize(10)
    .build()

fun scan(graphNotation: GraphNotation): ObjectRegistryScan {
    val key = ObjectRegistryConventions.scanDigest(graphNotation)
    return scanCache.get(key) { computeScan(graphNotation) }
}
```

with `computeScan` = the current `scan` body (`:27-38`) unchanged (including the
`reflect(it).error == null` filter). Test: step 7b.

### Step 6 — S9-prep + S4: relocate pure view-model files, then move the prototype scan

**6a — testability move (S9-prep).** Move, package-renaming only (no logic change):

| From (jsMain, `tech.kzen.auto.client.objects.document.custom.…`) | To (kzen-auto-common commonMain, `tech.kzen.auto.common.objects.document.custom.model`) |
|---|---|
| `view/obj/CustomObjectInfo.kt` | `CustomObjectInfo.kt` |
| `view/CustomViewExports.kt` (incl. `CustomViewExportsState`) | `CustomViewExports.kt` |
| `view/CustomViewModel.kt` | `CustomViewModel.kt` |

All three verified React-free (kzen-lib common types + `CustomConventions` only; no
`@Reflect`, so KSP/module registration is untouched). Update imports in the jsMain consumers:
`CustomView.kt`, `CustomViewStore.kt`, `CustomController.kt`, `CustomObject.kt`,
`CustomObjectHeader.kt`, `CustomObjectTask.kt`/`CustomObjectDetached.kt` (whichever reference
`CustomObjectInfo`) — compiler-guided, mechanical.

Also extract the drop translation (S9 target): new commonMain file
`tech.kzen.auto.common.objects.document.custom.model.CustomViewReorder`:

```kotlin
object CustomViewReorder {
    data class DropShift(val sourcePath: ObjectPath, val newDocPosition: Int)

    /** View list = doc object list minus the root `main` object. */
    fun viewPaths(allDocPaths: List<ObjectPath>): List<ObjectPath>

    /**
     * Translate a reorder expressed in view indices (source, and the post-drop view index
     * already computed by the caller from target/dropAfter) into the ShiftObjectCommand's
     * doc-index position. Null when out of range or a no-op.
     */
    fun dropShift(allDocPaths: List<ObjectPath>, sourceViewIndex: Int, newViewIndex: Int): DropShift?
}
```

— bodies lifted verbatim from `CustomViewStore.onDrop:121-141` + `isFilteredFromView:149-151`
+ `anchorAfterMove:154-159`. `CustomViewStore.onDrop` becomes: compute `newViewIndex` via the
jsMain `computeDropIndex` (stays where it is — other documents share it), call
`CustomViewReorder.dropShift`, dispatch `ShiftObjectCommand` if non-null. Behavior identical.

**6b — S4 proper.** With the files in place:

1. `CustomViewModel` gains `val prototypes: List<ObjectLocation>`; `Builder.update` computes
   `CustomConventions.listPrototypes(graphStructure.graphNotation)` and passes it into the
   candidate model. The existing `prev == next → return prev` whole-model reuse (and the
   per-entry reuse) is untouched — data-class equality now also covers the prototypes list,
   so reference stability is preserved exactly as the contract comment (`:12-15`) requires:
   unchanged content ⇒ previous instance returned ⇒ `RPureComponent` shallow-compare bails.
2. `CustomState` (`model/CustomState.kt`) gains `val viewModel: CustomViewModel? = null` and
   `fun withViewModel(viewModel: CustomViewModel?) = if (viewModel === this.viewModel) this else copy(viewModel = viewModel)`.
3. `CustomStore` gains `private val viewModelBuilder = CustomViewModel.Builder()`; at the end
   of `onClientState` (before `updateIfChanged`):

   ```kotlin
   val viewModel = viewModelBuilder.update(
       documentPath, serverNotation, clientState.graphStructure())
   updateIfChanged(nextState.withViewModel(viewModel))
   ```

   (Non-custom documents early-return before this point via `CustomState.tryFor` — the
   Builder never runs for other document types.)
4. `CustomController`: delete its `viewModelBuilder` field, the
   `clientStateGlobal.current()` reach in `onCustomState` (`:146-155` becomes a plain
   `setState { this.customState = customState }`), and the `customViewModel` state field —
   the view model rides `customState.viewModel`.
5. `CustomView`: delete the `clientStateGlobal` prop and the `:61-67` block; read
   `props.customState.viewModel` (early-return when null) and pass
   `viewModel.prototypes` to `CustomCreate`. Delete the now-unused `customViewModel` prop.
   `CustomController.render` stops passing `clientStateGlobal` to `CustomView` (it keeps its
   own — the store needs it).

Result: no mid-render global reach, no per-render graph scan; scan runs once per notation
event and only publishes when its output changed. Test: step 7c.

### Step 7 — S9: the test suite

**7a — `PluginReportDefinitionRepositoryTest`** —
`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/objects/plugin/PluginReportDefinitionRepositoryTest.kt`.
Harness: a small `FakeGraphStore : LocalGraphStore` (5 members; `graphStructure()` returns a
settable `GraphStructure` built via `AutoTestUtils.readNotation()` +
`AutoTestUtils.graphMetadata()`; `graphDefinition()` throws — unused by the metadata paths;
`observe`/`unobserve` no-op). Repository constructed with the fake + the `GraphDefiner`/
`GraphCreator` singletons. Notation edits via the `ScriptValidationCacheTest` idiom
(`NotationReducer().applyStructural(notation, UpsertAttributeCommand(...))`). Tests:

1. `secondCallWithUnchangedNotationSkipsRefresh` — no plugin documents in the base notation ⇒
   definer cache trivially complete; `listMetadata()` twice ⇒ `refreshCount == 1` (pins the
   fix; fails with 2 on current code).
2. `notationEditInvalidates` — swap the fake's structure for an edited one (any attribute
   upsert), call again ⇒ `refreshCount == 2`.
3. `incompleteDefinerCacheKeepsRetrying` — base notation + the new fixture
   `kzen-auto-jvm/src/test/resources/notation/test/plugin-cache-test.yaml`:

   ```yaml
   main:
     is: Plugin
     jarPath: "C:/nonexistent/plugin-cache-test.jar"
   ```

   (definition succeeds — bad path is runtime-only; `jarClassLoader()` → null → definer cache
   stays incomplete). `contains(someCoordinate)` twice ⇒ `refreshCount == 2` — pins the
   conservative assignment placement (retry semantics preserved).

**7b — `ObjectRegistryScanCacheTest`** —
`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/objects/registry/ObjectRegistryScanCacheTest.kt`:

1. `repeatedScanReturnsCachedInstance` — `scan(n)` twice over equal notation ⇒ `assertSame`
   (digest-keyed hit; `assertSame` works across *equal but distinct* `GraphNotation`
   instances too — that's the point of the digest key).
2. `registryEditRecomputes` — edit the bundled registry document's `classes` list (idiom:
   `ScriptValidationCacheTest.registryDocumentEditRecomputes`, which upserts
   `auto-jvm/registry/registry-jvm.yaml` `main.classes`) ⇒ `assertNotSame` + new content
   (e.g. added `kotlin.ranges.CharRange` present).
3. `unrelatedEditStaysCached` — upsert in a non-registry document ⇒ `assertSame`.
4. `unresolvableClassStillFilteredThroughCache` — add `no.such.Class` to the registry list ⇒
   scan excludes it (pins the `reflect().error == null` filter through the cached path).

**7c — `CustomViewModelBuilderTest`** —
`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/common/objects/document/custom/model/CustomViewModelBuilderTest.kt`
(jvm module testing a common class — `ScriptDependencyAnalysisTest` precedent). Fixture: the
real bundled `main/Custom.yaml` document via `AutoTestUtils.readNotation()` (bonus: exercises
the S10 curated content and its prototypes/tags end-to-end):

1. `unchangedInputsReturnSameInstance` — `update(...)` twice with the same notation ⇒
   `assertSame` (whole-model reuse).
2. `unrelatedObjectEditReusesSiblingEntries` — upsert one object's attribute ⇒ new model, but
   the *untouched* objects' `Entry` instances are `assertSame` to the previous model's
   (per-entry reuse — the reference-stability contract).
3. `prototypesListedAndStableAcrossNoOp` (post-6b) — `prototypes` contains the curated
   prototype locations; a same-content update keeps `assertSame` on the model.
4. `prototypeAddedElsewhereChangesModel` (post-6b) — add an `is: Prototype` object in a
   *different* document ⇒ new model instance with the location included (pins the S4
   cross-document refresh).

**7d — `CustomViewReorderTest`** —
`kzen-auto-common/src/commonTest/kotlin/tech/kzen/auto/common/objects/document/custom/model/CustomViewReorderTest.kt`
(pure list logic, runs JVM + ChromeHeadless). Hand-built `ObjectPath` lists with the root
`main` interleaved at various positions; cases: move down past one sibling, move up, move to
end (anchor null ⇒ `allDocPaths.size - 1`), move to start, source==dest no-op ⇒ null,
out-of-range indices ⇒ null, and the doc-index arithmetic when `main` sits *between* the
source and anchor (the off-by-one the translation exists to prevent).

**7e — spec round-trips (commonTest, `FilterSpecCodecTest` idiom)**:

- `kzen-auto-common/src/commonTest/.../registry/spec/ClassListSpecTest.kt` —
  `ofAttributeNotation` over a hand-built `ListAttributeNotation` (incl. empty list);
  `addCommand`/`removeCommand` produce the expected
  `InsertListItemInAttributeCommand`/`RemoveListItemInAttributeCommand` shapes against
  `ObjectRegistryConventions.classesAttributePath`. (No unparse exists — parse-only pin.)
- `kzen-auto-common/src/commonTest/.../data/spec/FieldFormatSpecTest.kt` — full round-trip
  `ofNotation(asNotation(spec)) == spec` for: simple class, nullable, nested generics
  (`Map<String, List<Int?>>`-shaped `TypeMetadata`); `FieldFormatListSpec.ofAttributeNotation`
  over a two-field map; `FieldFormatListSpec.addCommand` shape with `FieldFormatSpec.any`.

**7f — C7 exports-rename pin** —
`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/common/objects/document/custom/CustomExportsRenameTest.kt`
+ two self-contained fixtures (deliberately **not** referencing `main/Custom.yaml` objects, so
S10 can't break them):

`kzen-auto-jvm/src/test/resources/notation/test/custom-exports-rename-test.yaml`:

```yaml
main:
  is: CustomDocument
  exports:
    - "main.objects/Exported"

FixtureNamed:
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocNamed

FixtureNamedImpl:
  is: FixtureNamed
  class: tech.kzen.auto.server.objects.custom.test.AdhocNamedImpl
  name: "fixture"
  meta:
    name: String

FixturePrototype:
  is: Prototype
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocDetached
  meta:
    tags:
      - detached
      - logic
    named:
      is: FixtureNamed
      editor: SelectObjectEditor

main.objects/Exported:
  is: FixturePrototype
  named: FixtureNamedImpl
```

`.../notation/test/custom-exports-rename-caller-test.yaml` — one object with a scalar
attribute holding the exported object's full location string exactly as `SelectLogicEditor`
writes it (`objectLocation.asString()`), with meta `callee: {is: ObjectLocation}`; the object
is `abstract: true` so it needs no definable class. Test flow (idiom: kzen-lib
`RenameObjectRefactorTest` + `AutoTestUtils`):

1. Sanity: pre-rename, the exports entry and the caller scalar both
   `ObjectReference.parse(...)` + `coalesce.locate(...)` to `main.objects/Exported`, and
   `CustomConventions.customDocumentExportedLogic` returns it (logic tag present).
2. `NotationReducer().applySemantic(graphDefinitionAttempt, RenameObjectRefactorCommand(exportedLocation, ObjectName("Renamed")))`
   ⇒ in the transition notation: exports entry locates to `main.objects/Renamed`; caller
   scalar locates to it too; `customDocumentExportedLogic` still returns exactly it.
3. Document-rename variant: `RenameDocumentRefactorCommand` on the custom document ⇒ caller
   scalar locates to the renamed document's exported object; exports list (document-relative
   `objectPath.asString()` entries) still resolves.

If any leg is red, **do not silently fix in this session** — the pin's purpose is to surface
whether Nominal rewriting covers these shapes; a red leg is a finding to record in the
analysis (C7) with the test committed `@Ignore`d and the gap described. (Expectation per the
analysis: green.)

### Step 8 — S10: curated `Custom.yaml`

Replace the full content of `kzen-auto-jvm/src/main/resources/notation/main/Custom.yaml`
(and **nothing else** in that directory) with:

```yaml
# Bundled starter for the Custom document type: ad-hoc objects assembled from prototypes.
# Each prototype below is an abstract template offered by the "+ Add" picker; the
# main.objects/* entries are ready-to-run examples. See docs/architecture.md § 6.

main:
  is: CustomDocument

# Runs once when triggered and returns a greeting built from its `named` reference.
HelloAction:
  is: Prototype
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocDetached
  description: "Runs once and returns a greeting (detached execution)"
  meta:
    description: String
    tags:
      - detached
    named:
      is: Greeter
      editor: SelectObjectEditor

# Long-running background task: reports progress every second for a minute, stoppable.
CountingTask:
  is: Prototype
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocTask
  description: "Background task that reports progress every second (task execution)"
  meta:
    description: String
    tags:
      - task
    named:
      is: Greeter
      editor: SelectObjectEditor

# Marker for objects that can supply a name to the runners above.
Greeter:
  abstract: true
  class: tech.kzen.auto.server.objects.custom.test.AdhocNamed

# A concrete name provider the examples reference.
DefaultGreeter:
  is: Greeter
  class: tech.kzen.auto.server.objects.custom.test.AdhocNamedImpl
  name: "world"
  meta:
    name: String

main.objects/Hello:
  is: HelloAction
  named: DefaultGreeter

main.objects/Counter:
  is: CountingTask
  named: DefaultGreeter
```

Notes (all pre-verified): classes unchanged — `Adhoc*` stay in `src/main` under `@Reflect`
(the no-`kspTest` constraint is untouched; notation object names are free to change since
nothing else references them); prototypes remain the only two in a fresh install, now with
honest names; prototype-to-instance linking is by bare object name
(`AddObjectCommand.ofParent(..., prototype.objectPath.name)`, `CustomViewStore.kt:62`), which
keeps working because prototypes and instances share this document; `description:` sits only
on abstract objects (never defined) with `meta: description: String` following the
`common-document.yaml:73-78` precedent, and is `AutoConventions`-managed so it doesn't leak
into the per-object editors; all strings containing spaces/colons are quoted (post-Y parser
rule). The removed `AdhocNamed2`/duplicate-instance clutter is dev scratch, referenced
nowhere. Smoke (Verification) must confirm: both prototypes appear in "+ Add", both example
objects run, no definition errors on boot. **7c's Builder test reads this file — update its
expected prototype names in the same change.**

### Step 9 — S8: docs refresh (last)

Corrected wording *directions* (not final prose) per passage, all in kzen-auto:

1. `docs/architecture.md:248` (§ 6 table, `registry/` row) — replace "Browse / add custom
   objects from the library" with the truth: a JVM class-name whitelist consumed by
   `FormulaStep` type inference (Script expression typing); the document registers
   host-classpath class names, nothing more.
2. `docs/architecture.md:247` (`plugin/` row) — "Upload / register plugin JARs" → "Register
   plugin JARs (server filesystem path)".
3. `docs/architecture.md:287` (§ 6 Custom paragraph) — three corrections in one rewrite:
   view-mode persistence is via the `DocumentBridge`-shared store (`CustomStoreKey`), not the
   retired `CustomGlobal`; there is **no `main.logic` list** — reality is the `exports` list
   on `main` (`{is: List, of: ObjectLocation, by: Nominal}`, `common-document.yaml:390-395`,
   toggled per-object, feeding `SelectLogicEditor`/`SelectObjectEditor` cross-document
   references) plus `meta: tags:` (`detached`/`task`/`logic`) driving the per-object run
   affordances; and View mode edits object attributes via `AttributeEditorManager`. If step 6
   landed, also mention the view model (`CustomViewModel.Builder`, now in kzen-auto-common)
   computing per-object info + prototype list per notation event.
4. `docs/architecture.md:300` (§ 7 step 2) — "User uploads the JAR via the plugin document
   UI" → the truth: the user enters a **server filesystem path** to the JAR in the Plugin
   document (`jarPath` attribute; no browser upload — upload-as-resource is an open decision,
   D3).
5. `docs/js-architecture.md:195` (§ 3 exception paragraph) — rewrite: `custom/` **no longer
   is** the exception; it now follows the convention with `model/`
   (`CustomState`/`CustomStore`/`CustomStoreKey`) + `view/` (`CustomViewStore`, view
   components), header/body sharing one store via `DocumentBridge`, and the document-agnostic
   raw stack under `objects/document/common/raw/` for its Raw mode. Note the pure view-model
   pieces (`CustomObjectInfo`/`CustomViewModel`/`CustomViewExports`) living in
   kzen-auto-common for testability (post step 6a). The genuinely still-true bits (shared
   `YamlEditor` location, save-flow pointer to architecture § 6) carry over.
6. Optional, same spirit (analysis's "docs refresh alongside whichever work lands first"):
   `AGENTS.md`'s kzen-auto-js table line "`custom/` is the raw-YAML editor for
   `CustomDocument` …" — update to "hybrid structured + raw editor" with the same
   § 6 pointer. One sentence; skip if the session is running long.

## Tests

| Test class | Source set | Pins |
|---|---|---|
| `PluginReportDefinitionRepositoryTest` | kzen-auto-jvm `src/test` | S2: fast-path hit (refreshCount stays 1), notation-edit invalidation, incomplete-cache retry semantics |
| `ObjectRegistryScanCacheTest` | kzen-auto-jvm `src/test` | S5: cached-instance reuse (`assertSame`), registry-edit recompute, unrelated-edit hit, unresolvable-class filter through cache |
| `CustomViewModelBuilderTest` | kzen-auto-jvm `src/test` (common class) | S4/S9: whole-model + per-entry reference stability; prototypes listed; cross-document prototype refresh |
| `CustomViewReorderTest` | kzen-auto-common `commonTest` | S9: view-index→doc-index translation incl. `main`-offset arithmetic and no-op/out-of-range guards |
| `ClassListSpecTest` | kzen-auto-common `commonTest` | S9: notation parse + add/remove command shapes |
| `FieldFormatSpecTest` | kzen-auto-common `commonTest` | S9: `ofNotation`/`asNotation` round-trip incl. nested generics + nullability; list spec parse + add command |
| `CustomExportsRenameTest` (+2 yaml fixtures) | kzen-auto-jvm `src/test` | S9/C7: object rename + document rename keep exports list, cross-document reference, and `customDocumentExportedLogic` intact |

Existing tests that must stay green as regression net: `ScriptValidationCacheTest` (its
registry digest component is refactored in step 5), `FormulaStepTest` (transits
`ObjectRegistryScan` — also the Kotlin-diagnostic canary), the `ScriptNotationTest` family
(run-compile path transits the validation cache).

## Verification

Analysis baseline (`2026-07-06_…analysis.md` § Verification baseline), spelled out:

1. `./gradlew build` — all modules; KSP regen; kzen-auto-js compile catches every import
   update from step 6; kzen-auto-common commonTest runs on JVM and ChromeHeadless.
2. `./gradlew :kzen-auto-jvm:test` — includes all new jvm tests plus `FormulaStepTest`.
   (Cold-compile note from AGENTS: if `StepExpressionCompiler`'s generated shape were touched
   — it is not, here — clear `<workdir>/code-cache`; not applicable, listed for completeness.)
3. Manual smoke via `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`, all four
   Customize documents:

| Document | Smoke |
|---|---|
| **Custom** | Create from sidebar. "+ Add" shows exactly `HelloAction` + `CountingTask` (S10). Add one of each; edit the `named` attribute via its select; rename an object; drag-reorder (S9's translation refactor); toggle export glow; **run detached** (`Hello` result renders); **run task** (progress ticks ~1/s, Stop works); **S6 check**: start the task, navigate to another document, confirm in the browser network tab that `/task/query` polling stops within one interval; navigate back (result gone — expected, persistence is D6). Raw round-trip: toggle Raw, save unchanged, toggle back (comments in the bundled file will drop on a raw re-save — known, acceptable). **S4 check**: in a *second* Custom document add an object with `is: Prototype` via Raw; return to the first document — its "+ Add" picker lists the new prototype after the notation event, with no reload. |
| **Plugin** | Create from sidebar; enter a bogus `jarPath` → friendly "Please provide a valid plugin jar path" failure; if `../kzen-sample-plugin` is built, point at its jar → definers listed. (S2 fast path has no UI surface; it's pinned by test.) |
| **ObjectRegistry** | Create; add `kotlin.ranges.IntRange`; open a Script with a Formula step and confirm type inference still resolves (S5 cache transits `ScriptValidator`); edit the class list and confirm validation updates (cache invalidation, also pinned by test). |
| **Data (DataFormat)** | Create; add a field; edit its type; delete it. (Untouched this session — baseline regression only, per the analysis's four-document smoke.) |

4. No `selfTest` requirement (it doesn't drive these document types); run it only if touching
   anything unexpected. Mind the harness notes in `kzen-auto-test/AGENTS.md` if run.
5. Boot check for S10: fresh `frontendDevelopment` boot shows no definition errors for
   `main/Custom.yaml` objects (the `description:`-on-abstract choice is validated here; if a
   definition error appears, drop the `description:` attributes and keep comments only —
   pre-authorized fallback).

## Risks & gotchas

- **S2 assignment placement is semantics, not just a bug fix.** Assign-on-complete-only is
  deliberate (pre-resolved Q1): an unloadable jar keeps retrying per call exactly as today.
  Assigning unconditionally would freeze a later-appearing jar out until the next notation
  edit. The `incompleteDefinerCacheKeepsRetrying` test pins this so a future "simplification"
  can't regress it silently.
- **`runBlocking` under `@Synchronized`** (all five repository entry points) is pre-existing
  and *noted, not changed* — changing lock granularity interacts with both cache levels and
  belongs to the post-ratification plugin phase.
- **S4 changes when the prototype scan runs**: once per `ClientStateGlobal` publish while a
  Custom document is mounted (was: once per render, off a possibly-stale mid-render global
  read). `listPrototypes` is O(all objects) `directAttribute` probes — fine at this scale
  (the analysis's own call), and strictly better than per-render. The Builder's
  reference-return discipline is what keeps the extra runs publish-free; don't "simplify" it
  to always-new instances.
- **The step-6a move is compile-time-mechanical but wide** (~8 jsMain files' imports). It
  carries no behavior; if the session runs long it can be deferred *together with* tests
  7c/7d (they depend on it) — S4 itself does not strictly require the move, only the tests
  do. Everything else lands regardless.
- **Fixture `plugin-cache-test.yaml` joins the global test notation** read by
  `AutoTestUtils.readNotation()` (like every `notation/test/*.yaml`). It must stay
  definition-clean (bogus `jarPath` is runtime-only) so it can't perturb other tests; the
  rename fixtures are likewise self-contained (deliberately independent of `main/Custom.yaml`
  so S10 and future curation can't break them).
- **C7 red-leg protocol**: the rename pin is a *pin*, not a fix mandate — if Nominal
  rewriting misses a shape, record the finding (analysis C7), commit the test `@Ignore`d
  with the gap described, and do not attempt a kzen-lib fix in this session.
- **S10 file safety**: only `Custom.yaml` changes under
  `kzen-auto-jvm/src/main/resources/notation/main/`; the siblings there are the developer's
  dev-server working documents (frequently staged-but-uncommitted). If the dev server is
  running while this lands, its in-memory copy may rewrite `Custom.yaml` on the next edit
  through the UI — land this step with the dev server stopped.
- **Comments in the curated YAML survive on disk** but are dropped if a user later saves the
  document through Raw mode (parse → deparse; docs § 6 states this) — acceptable, the
  `description:` attributes carry the durable text.
- **Docs step last**: architecture.md/js-architecture.md line anchors cited here are valid at
  `ceb699d0`; they don't shift during this session (no earlier step edits those files), but
  re-grep before editing if any sibling plan landed in between.

## Out of scope (everything D1–D7, plus adjacent findings)

- **D1** plugin `ModuleReflection` registration (and its R5/R5-G reflection-plan
  counterpart); **D2** classloader isolation unit; **D3** JAR-as-document-resource upload
  (P2's *code* half — S8 only fixes the doc claim); **D4** ObjectRegistry disposition,
  including the redundant bundled `IntRange` registration cleanup (R4 — explicitly tied to
  D4 by the analysis); **D5** DataFormat disposition (F1–F3 untouched beyond the smoke
  baseline); **D6** Custom run-result persistence (S6 lands the leak half only); **D7**
  plugin custom client UI.
- **S7 / P7**: `PluginController` port off `AttributePathValueEditorOld`, the
  `valueType = long` fix, and its whole-`ClientState` storage — owned by AE1.
- C4 (prototype picker metadata), C5's logic-tag affordance asymmetry, C6 (per-tag card
  registry seam), P4 (serve the listing from the repository cache + per-definer
  diagnostics, `System.gc()` removal), P5 (loader chaining), R1's *rename* half (the
  document type keeps its name; only the doc description is corrected), R2 (plugin-classpath
  blindness).
- Any kzen-lib change; any `kzen-auto-plugin` change; any runtime `notation/main/` content.
