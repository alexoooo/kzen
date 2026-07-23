# Validation digest handshake + DirectGraphStore hardening

**Status:** implemented 2026-07-23 (manual smoke §6 still pending)
**Repos:** `kzen-lib` (DirectGraphStore hardening) and `kzen-auto` (digest handshake). Build order matters — kzen-lib first.
**Motivating bug:** editing a Script Formula step's code leaves the UI showing a validation result for
the WRONG code revision — good code (`1..1301`) displaying a stale "Expecting an element" error, and
previously bad code displaying green. Must be fixed generically for all fetch-validated flavours
(Script, Job today; any future one), rock solid but simple.

---

## 1. Context — the three remaining race windows

The 2026-07-23 document-digest plan (pruned members + member order) IS implemented and correct —
verified in `kzen-lib-common/.../model/definition/GraphDefinition.kt` `transitiveDigest(documentPath)`
(lines ~146-160). It fixed *cache-key blindness*. The remaining bug is about *which notation snapshot a
validation observes*, and it has three independent windows (all traced in code):

1. **The validation fetch races the edit commit.** `MirroredGraphStore.apply`
   (`kzen-lib-common/.../service/store/MirroredGraphStore.kt:87-146`) runs the remote apply and the
   local apply **concurrently**; the local branch's `publishSuccess` (line ~111) fires the
   `ClientStateGlobal` → `onClientState` cascade — which triggers
   `ScriptStore.refreshValidationAsync` / `JobController.refreshValidationIfNeeded` — **before**
   `remoteDigestAsync.await()` (line ~124) completes the server write. So the validation GET can be
   served from **pre-commit** server notation: the server (correctly, per its own state) returns the
   old code's error, and the client displays it against the new code. There is no post-remote publish
   on the success path (`onStoreRefresh` fires only in the digest-divergence repair, line ~137), so
   "trigger the refresh after remote apply" would mean new kzen-lib publish semantics for every
   observer — rejected in favour of retry-on-mismatch below.

2. **The fetched result is applied unguarded.** `ScriptValidationStore.refresh()`
   (`kzen-auto-js/.../objects/document/script/valid/ScriptValidationStore.kt:30-48`) writes
   `scriptValidation` into `ScriptState` with no staleness check — the `validationEpoch` in
   `ScriptStore.refreshValidationAsync` (`.../script/model/ScriptStore.kt:197-225`) guards only the
   `LogicValidationGlobal` busy/settle channel, not the state write the step cards render
   (`ScriptStepDisplayBase.onScriptState` → `ScriptStepDisplayDefault.renderValidation` /
   `StepHeader` error badge). Job has the identical shape: `JobController.refreshValidationIfNeeded`
   (`.../job/JobController.kt:364-407`) does `setState { workerValidations = validation }` at ~390-394
   **before** its epoch check at ~396. Two overlapping fetches completing out of order last-writer-win.

3. **No revision correlation.** Neither the request (`performDetached` sends only
   `paramHostDocumentPath`) nor the response (`ScriptValidation` / `JobValidation` — bare maps of
   `StepValidation`) identifies the notation revision the result was computed against. The client
   cannot detect staleness even in principle.

Flow (`FlowController.refreshStructureFindingsIfNeeded`) and Report validate synchronously client-side
from the same state they render — no fetch, no windows, no changes needed.

Additionally, the exploration found a genuine server-side concurrency bug (user opted to include the
fix): `DirectGraphStore` (`kzen-lib-common/.../service/store/DirectGraphStore.kt`) shares
unsynchronized, non-volatile cache fields across concurrent Netty request threads, and both cache
fills assign the digest *before* computing the value across suspension points — see §3.

## 2. Design

**Digest handshake, checked at one shared choke point, plus store-level serialization on the server.**

- **Server**: each validator echoes the digest of the host `DocumentNotation` its result was computed
  against, riding in the existing `ExecutionSuccess.detail` slot (`kzen-lib-common/.../exec/ExecutionResult.kt:98-131`
  — `withDetail(...)`, already round-tripped by `toJsonCollection`/`fromJsonCollection` and the kotlinx
  serializer, and decoded intact by `ClientRestApi.performDetached`, `ClientRestApi.kt:510-519`).
  **No change to `ScriptValidation`/`JobValidation` models, serialization, or the caches** — the echo
  is per-request, taken from the same snapshot the cache key and compute used.
- **Client**: a shared helper performs the fetch and applies the result **only if the echoed digest
  equals the current local host-document digest**, otherwise retries (100 ms, cap 10). This single gate
  closes windows 1 and 2 at once: a pre-commit server answer mismatches and is retried; an out-of-order
  older response mismatches and is discarded. `DocumentNotation.digest()` is cached, `Digestible`,
  common code (`DocumentNotation.kt:187-202`); client/server digests converge by the MirroredGraphStore
  mirror invariant (byte-level media convergence ⇒ parsed-structure convergence — parser and reducer
  are common code). If they ever *don't* converge, the retry cap surfaces a visible error instead of
  silently sticking.
- **Convergence guarantee for the retry loop**: `MirroredGraphStore.apply` completes the remote write
  before returning, so the server catches up within a retry or two; and every subsequent local notation
  change re-arms a fresh refresh whose epoch supersedes the old loop (the existing `validationEpoch`
  machinery is kept exactly for that plus the busy-channel settle).
- **Busy indicator**: armed synchronously at arm time (existing behaviour), settled only after the
  fetch loop returns and the epoch check passes — stays lit across retries, no flicker, cannot stick
  (every exit path either reaches the settle or is superseded by a newer arm that owns it).
- **Missing echo (`NullExecutionValue` detail) ⇒ apply unconditionally** — graceful default for any
  detached action that doesn't adopt the echo, and for version skew.
- **No request-side digest**: a pre-commit server compute is in practice a cache hit (that notation was
  validated just before the edit), so the "wasted" compute costs nothing; request-side staleness
  signalling would add API surface for near-zero gain.
- **kzen-lib hardening** (§3): a `Mutex` serializes `apply()` against the read paths and establishes
  happens-before for the cache fields; the compute-then-assign fix removes the torn digest/value
  pairing that is reachable even single-threaded (suspension points inside the fill).

## 3. kzen-lib — `DirectGraphStore` hardening

File: `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/store/DirectGraphStore.kt`

Two defects:

- **No synchronization.** `apply()` → `applyInPlace()` is a read-modify-write spanning several
  suspension points (scan → reduce → write, lines ~198-231) with no lock; `graphNotation()` /
  `graphDefinition()` run concurrently on other Netty threads (`KzenAutoContext` wires ONE store
  instance into both `NotationCommandHandler` and `ModelDetachedExecutor`/`DetachedActionHandler`,
  each entered via `runBlocking` on request threads). The four cache `var`s
  (`graphNotationCacheDigest`/`graphNotationCache`/`graphDefinitionCacheDigest`/`graphDefinitionCache`,
  lines 33-38) are plain non-volatile — no happens-before edge at all. (`FileNotationMedia` is per-op
  `@Synchronized`, so the *media* layer is coherent; the store layer above it is not.)
- **Digest-before-value cache fills.** `graphNotation(notationScan)` (96-105) assigns
  `graphNotationCacheDigest = digest` and only *then* computes `graphNotationImpl(...)` — which
  **suspends** (media reads) — before assigning `graphNotationCache`. A caller interleaving in that
  gap sees a matching digest paired with the stale (or null → NPE) cache value. Same shape in
  `cachedGraphDefinition` (167-179).

### 3.1 Changes (exact)

Add imports `kotlinx.coroutines.sync.Mutex`, `kotlinx.coroutines.sync.withLock` and a field:

```kotlin
    // Serializes apply() against the notation/definition read paths (one store instance is shared
    // across concurrent server request threads) and establishes happens-before for the cache fields.
    // Non-reentrant: public entry points lock, private helpers assume the lock is held, and observer
    // callbacks run OUTSIDE it so an observer reading back through graphDefinition() cannot deadlock.
    private val mutex = Mutex()
```

`observe()` — read under lock, call back outside it:

```kotlin
    override suspend fun observe(observer: LocalGraphStore.Observer) {
        observers.add(observer)
        val graphDefinition = mutex.withLock { graphDefinitionLocked() }
        observer.onStoreRefresh(graphDefinition)
    }
```

`apply()` — fold `publishSuccess` in; compute event + post-apply definition atomically, notify outside:

```kotlin
    suspend fun apply(
        command: NotationCommand,
        attachment: LocalGraphStore.Attachment = LocalGraphStore.Attachment.empty
    ): NotationEvent {
        val (notationEvent, graphDefinition) = mutex.withLock {
            val event = applyInPlace(command)
            event to graphDefinitionLocked()
        }
        for (observer in observers) {
            observer.onCommandSuccess(notationEvent, graphDefinition, attachment)
        }
        return notationEvent
    }
```

Delete the now-unused private `publishSuccess`. **Check `publishFailure` / `publishRefresh` call
sites** — as of the current file neither appears to be called from anywhere; if confirmed uncalled,
leave them (dead-code cleanup is out of this plan's scope) *unless* one of them is reached from
elsewhere, in which case restructure it the same way (compute under lock, notify outside).

Public read paths lock; the private fill helpers assume the lock and get the compute-then-assign fix
(rename the private `graphNotation(notationScan)` overload to make the contract explicit):

```kotlin
    override suspend fun graphNotation(): GraphNotation {
        return mutex.withLock { graphNotationLocked(notationMedia.scan()) }
    }


    private suspend fun graphNotationLocked(notationScan: NotationScan): GraphNotation {
        val digest = notationScan.digest()
        val cached = graphNotationCache
        if (cached != null && graphNotationCacheDigest == digest) {
            return cached
        }
        // Compute BEFORE assigning: graphNotationImpl suspends (media reads), and a digest assigned
        // ahead of its value lets an interleaving caller pair the new digest with the stale value.
        val computed = graphNotationImpl(notationScan)
        graphNotationCacheDigest = digest
        graphNotationCache = computed
        return computed
    }
```

```kotlin
    override suspend fun graphDefinition(): GraphDefinitionAttempt {
        return mutex.withLock { graphDefinitionLocked() }
    }


    private suspend fun graphDefinitionLocked(): GraphDefinitionAttempt {
        return cachedGraphDefinition(graphNotationLocked(notationMedia.scan()))
    }


    private fun cachedGraphDefinition(
        graphNotation: GraphNotation
    ): GraphDefinitionAttempt {
        val digest = graphNotation.digest()
        val cached = graphDefinitionCache
        if (cached != null && graphDefinitionCacheDigest == digest) {
            return cached
        }
        val graphStructure = graphStructure(graphNotation)
        val computed = graphDefiner.tryDefine(graphStructure)
        graphDefinitionCacheDigest = digest
        graphDefinitionCache = computed
        return computed
    }
```

(Keep the existing "One tryDefine per notation version" doc comment on `cachedGraphDefinition`.)

- `graphStructure()` — unchanged: it composes the (now-locked) public `graphNotation()` with the pure
  `graphStructure(graphNotation)` metadata read; no cache fields touched.
- `applyInPlace()` and its callees — unchanged bodies; they already use the private helpers and now run
  under the `apply()` lock. Update its internal call from `graphNotation(notationScan)` to
  `graphNotationLocked(notationScan)`.
- `digest()` — wrap in `mutex.withLock { ... }` for uniformity (a consistent read point after applies).
- `refresh()` — becomes `suspend` and locks:

```kotlin
    suspend fun refresh() {
        mutex.withLock {
            notationMedia.invalidate()
            graphNotationCacheDigest = null
            graphNotationCache = null
            graphDefinitionCacheDigest = null
            graphDefinitionCache = null
        }
    }
```

  Call sites verified: `MirroredGraphStore.kt:136` (divergence repair — already in a suspend context)
  and `kzen-lib-jvm` test `DirectGraphStoreCacheTest.kt:87` (inside `runBlocking`). No other callers in
  kzen-lib, kzen-auto, kzen-project, kzen-launcher, or kzen-shell (grepped — `DirectGraphStore` is only
  referenced from kzen-lib and kzen-auto).
- The `observers` set mutation (`observe`/`unobserve`) stays as-is — pre-existing behaviour, JS/client
  driven; out of scope.

Behaviour-preserving for single-threaded JS (serializing overlapping coroutines is exactly the point —
the torn-fill fix removes a real JS hazard too, since the fill suspends mid-way).

### 3.2 kzen-lib test — concurrency stress case

Extend `kzen-lib-jvm/src/test/kotlin/tech/kzen/lib/server/store/DirectGraphStoreCacheTest.kt`
(existing fixture: `MapNotationMedia` + `newStore(media)`; JUnit 4 `org.junit.Test`; the three existing
tests must keep passing unchanged — note the `Refresh clears the definition cache` test already calls
`store.refresh()` inside `runBlocking`, so the suspend change compiles as-is):

```kotlin
    @Test
    fun `Concurrent applies and definition reads stay coherent`() {
        val media = MapNotationMedia()
        val store = newStore(media)

        runBlocking {
            media.writeDocument(mainPath, "A:\n  hello: \"a\"\n")
            store.graphDefinition()
        }

        // One writer toggling A<->B through apply(), several readers pulling graphDefinition() —
        // every returned attempt must be internally consistent (exactly one object, named A or B).
        // Pre-hardening this crashes/flakes (torn digest/value pairing, unsynchronized media access);
        // post-hardening the mutex serializes all store-mediated access.
        val iterations = 200
        val failures = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()

        val writer = kotlin.concurrent.thread {
            try {
                runBlocking {
                    repeat(iterations) { i ->
                        val from = if (i % 2 == 0) "A" else "B"
                        val to = if (i % 2 == 0) "B" else "A"
                        store.apply(RenameObjectCommand(
                            ObjectLocation(mainPath, ObjectPath.parse(from)),
                            ObjectName(to)))
                    }
                }
            } catch (t: Throwable) { failures.add(t) }
        }
        val readers = (0 until 4).map {
            kotlin.concurrent.thread {
                try {
                    runBlocking {
                        repeat(iterations) {
                            val attempt = store.graphDefinition()
                            val names = attempt.graphStructure.graphNotation
                                .documents[mainPath]!!.objects.notations.map.keys
                            check(names.size == 1 && names.single().name.value in setOf("A", "B")) {
                                "torn read: $names"
                            }
                        }
                    }
                } catch (t: Throwable) { failures.add(t) }
            }
        }
        writer.join(); readers.forEach { it.join() }
        assertTrue(failures.isEmpty(), failures.joinToString { it.message ?: it.toString() })
    }
```

(Adjust the `names.single().name.value` accessor chain to the actual `ObjectPath`/`ObjectName` API when
implementing; the point is the invariant, not the exact accessor. Add needed imports.)

## 4. kzen-auto — digest handshake

All paths relative to the kzen-auto repo (`cd ../kzen-auto`).

### 4.1 New file: shared echo codec (kzen-auto-common)

`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/logic/ValidationDigestEcho.kt`
(the package of the shared `StepValidation` — flavour-agnostic home):

```kotlin
package tech.kzen.auto.common.objects.document.logic

import tech.kzen.lib.common.exec.ExecutionValue
import tech.kzen.lib.common.exec.TextExecutionValue
import tech.kzen.lib.common.model.structure.notation.DocumentNotation
import tech.kzen.lib.common.util.digest.Digest


/**
 * The digest handshake between a server-side document validator and its client store: the validator
 *  echoes (in ExecutionSuccess.detail) the digest of the host DocumentNotation its result was
 *  computed against; the client applies the result only when the echo matches its current local
 *  notation. Required because a commit's local apply publishes (triggering the validation fetch)
 *  before the remote write lands — the fetch can be served from pre-commit server notation — and
 *  detached responses can arrive out of order. An absent echo (Null detail) means a non-adopting
 *  action: apply unconditionally.
 */
object ValidationDigestEcho {
    fun detail(documentNotation: DocumentNotation): ExecutionValue {
        return TextExecutionValue(documentNotation.digest().asString())
    }


    fun ofDetail(detail: ExecutionValue): Digest? {
        return (detail as? TextExecutionValue)?.let { Digest.parse(it.value) }
    }
}
```

### 4.2 Server: echo from both validators

`kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/script/ScriptValidator.kt` — `execute()`
(currently 146-176). After the `graphStore.graphDefinition()` read, resolve the host document from the
**same snapshot** (so cache hits echo consistently with the key/compute), and attach the echo:

```kotlin
        val graphDefinitionAttempt = graphStore.graphDefinition()

        val documentNotation = graphDefinitionAttempt.graphStructure.graphNotation.documents[documentPath]
            ?: return ExecutionResult.failure("Document not found: $documentPath")

        // ... existing scriptValidationCache block UNCHANGED ...

        return ExecutionSuccess.ofValue(scriptValidation.asExecutionValue())
            .withDetail(ValidationDigestEcho.detail(documentNotation))
```

(Behaviour tightening: a missing document becomes an explicit failure instead of an exception inside
`validate()` — only reachable mid-delete/navigation.)

`kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/JobValidator.kt` — `execute()`
(currently 124-151): identical shape (`graphDefinitionAttempt.graphStructure.graphNotation.documents[documentPath]`
guard + `.withDetail(...)` on the return). No cache changes in either validator.

**Transport check (read, don't assume):** the client decodes via
`clientJson.decodeFromString<ExecutionResult>` → `ExecutionResultSerializer`/`ExecutionSuccessSerializer`
(kzen-lib `exec/`), while the server responds via `toJsonCollection`. `toJsonCollection`/`fromJsonCollection`
verifiably carry `detailKey`; confirm `ExecutionSuccessSerializer` also carries `detail` (it should —
`ExecutionSuccess.fromJsonCollection` hard-requires the key). The round-trip test in §5.2 pins both.

### 4.3 New file: shared client fetch-until-current helper (kzen-auto-js)

`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/common/valid/ServerValidationFetch.kt`
— new `common/valid` package (sibling of `common/edit`; a function-level helper with DI-by-lambda, the
`DebouncedSubmitter` precedent — deliberately NOT a store base class, two adopters):

```kotlin
package tech.kzen.auto.client.objects.document.common.valid

import kotlinx.coroutines.delay
import tech.kzen.auto.common.objects.document.logic.ValidationDigestEcho
import tech.kzen.lib.common.exec.ExecutionFailure
import tech.kzen.lib.common.exec.ExecutionResult
import tech.kzen.lib.common.exec.ExecutionSuccess
import tech.kzen.lib.common.exec.MapExecutionValue
import tech.kzen.lib.common.util.digest.Digest


/**
 * Fetches a server-side document validation until its ValidationDigestEcho matches the caller's
 *  current local host-document digest. The single staleness gate for fetch-validated flavours
 *  (Script, Job): a fetch launched off the LOCAL commit publish can be served from pre-commit server
 *  notation (MirroredGraphStore applies local and remote concurrently), and overlapping responses can
 *  land out of order — either way the echo mismatches and the result is retried/discarded instead of
 *  applied. Convergence: the remote write completes shortly after (apply awaits it), and any newer
 *  local edit re-arms a refresh that supersedes this one via [currentDigest] returning null.
 */
object ServerValidationFetch {
    private const val staleRetryDelayMillis = 100  // remote apply is a local file write; one retry usually lands
    private const val staleRetryLimit = 10


    sealed interface Outcome<out T> {
        data class Current<T>(val value: T): Outcome<T>
        data class Failed(val errorMessage: String): Outcome<Nothing>
        data object Superseded: Outcome<Nothing>
    }


    /**
     * [currentDigest] the caller's CURRENT local host-DocumentNotation digest; null = this refresh no
     *  longer owns the outcome (superseded epoch / store unmounted) — abort silently.
     * [perform] one detached validator call. [parse] flavour-specific value decoding.
     */
    suspend fun <T> fetchCurrent(
        currentDigest: () -> Digest?,
        perform: suspend () -> ExecutionResult,
        parse: (MapExecutionValue) -> T
    ): Outcome<T> {
        repeat(staleRetryLimit) { attempt ->
            if (attempt > 0) {
                delay(staleRetryDelayMillis.toLong())
            }
            currentDigest()
                ?: return Outcome.Superseded

            when (val result = perform()) {
                is ExecutionFailure ->
                    return Outcome.Failed(result.errorMessage)

                is ExecutionSuccess -> {
                    // Compare at APPLICATION time (post-response), not launch time; the JS event loop
                    // guarantees no interleave between this check and the caller's state write.
                    val localDigest = currentDigest()
                        ?: return Outcome.Superseded
                    val echoed = ValidationDigestEcho.ofDetail(result.detail)
                    if (echoed == null || echoed == localDigest) {
                        return Outcome.Current(parse(result.value as MapExecutionValue))
                    }
                }
            }
        }
        return Outcome.Failed("Validation did not converge with the edited document")
    }
}
```

### 4.4 Script adoption

`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/script/valid/ScriptValidationStore.kt`
— `refresh()` gains the digest lambda and routes through the helper; `validationQuery` and the
`ClientResult`/`ClientSuccess`/`ClientError` plumbing lose their reason to exist — delete them and
their imports:

```kotlin
    suspend fun refresh(currentDigest: () -> Digest?) {
        scriptStore.updateValidation {
            it.copy(loaded = false)
        }

        val mainLocation = scriptStore.mainLocation()

        val outcome = ServerValidationFetch.fetchCurrent(
            currentDigest = currentDigest,
            perform = {
                scriptStore.restClient.performDetached(
                    ScriptConventions.scriptValidatorLocation,
                    CommonRestApi.paramHostDocumentPath to mainLocation.documentPath.asString())
            },
            parse = { ScriptValidation.ofExecutionValue(it) })

        when (outcome) {
            is ServerValidationFetch.Outcome.Current ->
                scriptStore.updateValidation {
                    it.copy(scriptValidation = outcome.value, loaded = true)
                }

            is ServerValidationFetch.Outcome.Failed ->
                scriptStore.update { state -> state
                    .withGlobalError(outcome.errorMessage)
                    .withValidation {
                        it.copy(scriptValidation = null, loaded = true)
                    }
                }

            ServerValidationFetch.Outcome.Superseded -> {}
        }
    }
```

`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/script/model/ScriptStore.kt`
— `refreshValidationAsync()` (197-225). The refresh is armed on **every** own-document notation change
(`onClientState` reference compare, 152-173), so the digest captured at arm time IS the current local
digest until a newer arm supersedes this epoch — no state re-read machinery needed:

```kotlin
    private fun refreshValidationAsync() {
        // Only ever called after updateIfChanged(nextState) set `state`. Mark the validation channel
        // in-flight SYNCHRONOUSLY (before the yield below) ... [keep existing comment]
        val currentState = state
            ?: return
        val documentPath = currentState.mainLocation.documentPath
        val epoch = ++validationEpoch
        logicValidationGlobal.validation(documentPath, inFlight = true, invalidReason = currentValidationReason())

        // Armed on every notation change, so the arm-time digest IS the current local digest until a
        // newer arm supersedes this epoch (which the lambda signals by returning null).
        val expectedDigest = currentState.documentNotation.digest()

        async {
            delay(refreshYieldMillis)
            if (epoch != validationEpoch || state == null) {
                return@async
            }
            validationStore.refresh {
                if (epoch != validationEpoch || state == null) null else expectedDigest
            }

            if (epoch != validationEpoch || state == null) {
                // Superseded while the fetch was in flight ... [keep existing comment]
                return@async
            }

            logicValidationGlobal.validation(
                documentPath, inFlight = false, invalidReason = currentValidationReason())
        }
    }
```

Extend the `validationEpoch` doc comment (189-193): the epoch guards the busy channel AND aborts the
fetch loop; the digest gate (in `ServerValidationFetch`) guards state application.

### 4.5 Job adoption (fixes the unguarded setState)

`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/job/JobValidationStore.kt`:

```kotlin
    suspend fun fetch(documentPath: DocumentPath, currentDigest: () -> Digest?): JobValidation? {
        val outcome = ServerValidationFetch.fetchCurrent(
            currentDigest = currentDigest,
            perform = {
                restClient.performDetached(
                    JobConventions.jobValidatorLocation,
                    CommonRestApi.paramHostDocumentPath to documentPath.asString())
            },
            parse = { JobValidation.ofExecutionValue(it) })

        return (outcome as? ServerValidationFetch.Outcome.Current)?.value
    }
```

Null keeps the class-doc's "failed fetch leaves chips standing" behaviour — and stale/superseded now
also correctly yield null instead of being applied. Update the class doc comment accordingly (one
clause about the digest gate). Delete the now-unused `ExecutionFailure`/`ExecutionSuccess`/
`MapExecutionValue` imports.

`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/job/JobController.kt`
— `refreshValidationIfNeeded` (364-407): the method already holds the fresh `documentNotation` (the
arm condition IS its reference change), so capture the digest at arm:

```kotlin
        val epoch = ++validationEpoch
        props.logicValidationGlobal.validation(
            documentPath, inFlight = true, invalidReason = jobValidationReason(state.workerValidations))

        val expectedDigest = documentNotation.digest()

        async {
            val validation = jobValidationStore.fetch(documentPath) {
                if (epoch != validationEpoch) null else expectedDigest
            }
            // ... rest of the async block UNCHANGED (value-equality gate, epoch-guarded settle) ...
```

The `setState { workerValidations = validation }` write now only ever receives a digest-matched (or
null) value; prior values are already read outside the lambda (write-only setState rule) — keep that.

## 5. Tests

### 5.1 `kzen-auto-js/src/jsTest/kotlin/tech/kzen/auto/client/objects/document/common/valid/ServerValidationFetchTest.kt` (NEW)

Follow the `DebouncedSubmitterTest` async pattern (`= async { ... }` bodies). Fixtures: digests via
`Digest.ofUtf8("v1")` / `("v2")`; responses hand-built as
`ExecutionSuccess(MapExecutionValue(mapOf()), TextExecutionValue(digest.asString()))`; `perform`
lambdas increment a counter and pop from a scripted response list; `parse = { it }`. Cases:

1. matched echo → `Outcome.Current`, exactly 1 perform.
2. stale echo then matching echo → retries, applies the second (2 performs) — **pins the core bug**.
3. always-stale → `Outcome.Failed` after exactly `staleRetryLimit` performs; the stale value is never
   surfaced as `Current`.
4. `currentDigest` returns null after the first response → `Outcome.Superseded`, no further performs.
5. missing echo (`NullExecutionValue` detail) → applies unconditionally (compat).
6. `ExecutionFailure` → `Outcome.Failed` immediately (1 perform, no retry).

### 5.2 `kzen-auto-common/src/commonTest/kotlin/tech/kzen/auto/common/objects/document/logic/ValidationDigestEchoTest.kt` (NEW)

Landed in `commonTest` rather than kzen-auto-jvm: the test needs only commonMain APIs, so CC-13 puts it
beside the code it covers, and it runs on both JVM and JS. Build a small
`DocumentNotation` via `YamlNotationParser().parseDocumentObjects(...)` + `DocumentNotation(objects, null)`:

- `ofDetail(detail(documentNotation))` equals `documentNotation.digest()`.
- `ofDetail(NullExecutionValue)` is null.
- Round-trip through `ExecutionSuccess.toJsonCollection()` → `ExecutionResult.fromJsonCollection` AND
  through the kotlinx serializer (`Json.encodeToString` / `decodeFromString` of `ExecutionResult`) —
  the echo must survive both transports (server responds via json collection; client decodes via the
  serializer).

### 5.3 kzen-lib — `DirectGraphStoreCacheTest` stress case (§3.2)

Existing three tests must pass unchanged; add the concurrency case.

No e2e (per standing policy — this is pure logic, covered by fast unit tests + the manual smoke).

## 6. Ordering & verification

kzen-lib changes gate kzen-auto (variant-suffix coords route kzen-auto's jvm/js source sets through
mavenLocal). Same version, republish in place — **no version bump**.

```powershell
$env:JAVA_HOME = "$env:USERPROFILE\.jdks\temurin-25.0.3"   # CLI gradle needs the Java 25 daemon

# 1. kzen-lib: hardening + stress test
cd ../kzen-lib
./gradlew build
./gradlew publishToMavenLocal

# 2. kzen-auto: echo + handshake
cd ../kzen-auto
./gradlew :kzen-auto-js:compileKotlinJs      # fast JS gate after the sweep
./gradlew :kzen-auto-jvm:test
./gradlew :kzen-auto-js:jsTest
./gradlew build                              # full module build (multi-minute)
```

kzen-project / kzen-launcher / kzen-shell don't reference `DirectGraphStore` (grepped) and the only
signature change (`refresh()` → suspend) has no callers there — rebuilding them is optional (skip
unless asked).

**Manual smoke** (dev loop per kzen-auto AGENTS.md: `BackendDevelopment` in IDE +
`./gradlew -t :kzen-auto-js:jsEsbuildBundle -PjsWatch`):

- Script-2.yaml Formula step: type bad→good (`1..130x` → `1..1301`) and good→bad at various speeds,
  blur mid-debounce, rapid-fire edits — the step error, red (!) badge, and run-cluster indicator must
  always converge to the truth of the current code; no stale error sticking on good code, no green on
  bad code.
- Job Formula Source code field: same drill (the JobController path).
- Busy indicator: pulses through the debounce + fetch (+ any retries) and settles once — no flicker,
  no stuck-busy.

## 7. Coding-standards reminders (repeated user feedback)

- Review the final diff against `kzen/docs/CODING_STANDARDS.md`.
- No space after `!` (`!failures.isEmpty()` style).
- Comments state constraints/rationale, not narration; NO "changed from X" commentary.
- Delete code that lost its reason: `ScriptValidationStore.validationQuery` + `ClientResult` imports;
  `DirectGraphStore.publishSuccess`; unused imports in `JobValidationStore`.
- kzen-auto-js `setState` lambdas are write-only — read prior values outside the lambda.
- Stage (never commit) each NEW file by explicit path in the repo it lives in:
  - `git -C ../kzen-auto add -- kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/logic/ValidationDigestEcho.kt`
  - `git -C ../kzen-auto add -- kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/common/valid/ServerValidationFetch.kt`
  - `git -C ../kzen-auto add -- kzen-auto-js/src/jsTest/kotlin/tech/kzen/auto/client/objects/document/common/valid/ServerValidationFetchTest.kt`
  - `git -C ../kzen-auto add -- kzen-auto-common/src/commonTest/kotlin/tech/kzen/auto/common/objects/document/logic/ValidationDigestEchoTest.kt`
  - (kzen-lib has no new files — the stress test extends an existing tracked file.)
  - This plan itself: `git -C ../kzen add -- plans/2026-07-23_validation-digest-handshake.md` (kzen repo).