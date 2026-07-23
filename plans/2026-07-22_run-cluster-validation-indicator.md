# Flavour-agnostic document validity + revalidation indicator in the run cluster

## Context

Editing a `FormulaStep`'s `code` (or any attribute that drives server-side type inference) silently
kicks off an async re-validation on the server — the detached `ScriptValidator` recompiles the
expression and reflects the inferred `KType` (`FormulaStep.definition` → `ExpressionReturnTypeInference`).
Today the UI gives **no** signal that this is happening; the stale type chip just sits there until the
new one arrives, and the 1 s commit debounce makes it feel like "nothing happens" when you type.

The goal is a visual "revalidating" indicator, and — more importantly — the **run-control cluster**
should *know* the validation state so it can **disable Run when the document is invalid**, done
**flavour-agnostically** (Script / Job / Flow / Report), and the indicator should turn on **immediately
on keystroke**, stay on through commit + server revalidation, and clear when settled.

The run cluster is the indicator surface (not per-card).

## What exists today (confirmed)

- **Run cluster** = `objects/ribbon/HeaderRunController.kt` — one global instance in the ribbon
  (`HeaderController.renderRunNavigation`), gates Run for all four paradigms via
  `runnable = isLogic && DefinitionErrors.runBlocker(graphDefinitionAttempt, mainLocation) == null`.
  Its only validity inputs are `AutoConventions.isLogic` + graph-definition failures. It observes only
  `ClientStateGlobal` and **cannot reach any per-document store**.
- **`DefinitionErrors.runBlocker`** (`util/DefinitionErrors.kt`) — the existing flavour-agnostic gate,
  graph-definition-based, mirrors the server's `filterTransitive(root)`. Stays as-is; new work is additive.
- **Paradigm validation (siloed, not consumed by the run cluster):**
  - Script: `ScriptValidationStore.refresh()` sets `ScriptValidationState.loaded=false`, hits detached
    `ScriptValidator`, produces `ScriptValidation` = `Map<ObjectPath, StepValidation>`; `loaded` exists
    but is unused by any indicator. Triggered from `ScriptStore.onClientState` on `documentNotationChanged`.
  - Job: `JobValidationStore.fetch()` → `JobValidation` = `Map<ObjectPath, StepValidation>`, held in
    `JobController.state.workerValidations`; no loading flag.
  - Flow: `FlowStructureValidator.validate(...)` (commonMain, **synchronous**, computed in
    `FlowController` render) → `List<String>` findings; banner only, never disables Run.
  - Report: `ReportState.notationError: String?` (+ `OutputStatus`); banner + reset FAB; no per-node validation.
  - Shared unit: `objects/document/logic/StepValidation.kt` = `(typeMetadata, errorMessage)` —
    so **"invalid" = any `StepValidation.errorMessage != null`** is a clean predicate for Script/Job.
- **Edit-pending is NOT observable today.** The unsaved buffer (`value != serverValue`) is local React
  state; the shared debounce (`AttributeCommitter` → `DebouncedSubmitter` → `lodash.debounce`, 1 s) exposes
  no `pending()`; `MirroredGraphStore` publishes only commit *completion* (success/failure/refresh), never
  "apply started". So immediacy must be synthesized at the committer layer.

## Design

### A flavour-agnostic push-based global

New `LogicValidationGlobal` under `service/logic/` (beside `ClientLogicGlobal`, which the run cluster
already consumes). Per document it combines **two orthogonal input channels** into one derived summary:

```kotlin
// INPUTS — two channels, so edit-pending and validation never race (see below):
fun editActivity(documentPath: DocumentPath, committerToken: Any, pending: Boolean)
    // per-document SET of active committer tokens — one document has many editor instances,
    // so a boolean can't survive two overlapping edits
fun validation(documentPath: DocumentPath, inFlight: Boolean, invalidReason: String?)
    // the paradigm's channel: async (re)validation state + first validation error

// OUTPUT — derived, read by consumers via summaryFor(documentPath):
data class LogicValidationSummary(
    val busy: Boolean,          // = editPending.isNotEmpty() || validationInFlight
    val invalidReason: String?  // → disables Run (null = valid/unknown)
)
interface Observer { fun onLogicValidation(documentPath: DocumentPath) }
```

The two-channel split is load-bearing, not a nicety: with a single `publish(documentPath, summary)` the
committer and the paradigm are two writers to one `busy` field, and last-writer-wins races follow
directly (keystroke B lands mid-validation of keystroke A → A's validation completes → the paradigm's
`busy=false` stomps B's pending edit and the spinner drops early). With split channels, committers know
nothing about validation, paradigms know nothing about edit-pending, and the race is structurally
impossible.

The output abstraction stays at the summary level (`busy` + `reason`), NOT at
`StepValidation`/mechanism level — that is what makes it flavour-agnostic across heterogeneous
validators. State is keyed by `DocumentPath` and consumers filter on the current path, so a stale
publisher from a previously-focused document cannot leak. A paradigm that never publishes (e.g. a
3rd-party plugin paradigm that mixes in `Logic` per CC-17) degrades to "unknown → runnable", same as
today.

Hygiene inside the global:
- **No-op publish guard** (broadcast-store rule): value-compare a document's derived summary before
  notifying — keystroke-frequency `editActivity` calls where `busy` is already true must not fan out.
- **Prune on document-gone**: summaries keyed by `DocumentPath` outlive deletion/rename (rename orphans
  the old key). Harmless for correctness (consumers filter on current path), but drop entries whose
  document no longer exists in notation to keep the map tidy.

### Consumer — the run cluster (`HeaderRunController`)

- Take `logicValidationGlobal` as a new prop; observe it (mount/unmount) alongside `ClientStateGlobal`.
- New state: `busy: Boolean`, `validationBlockReason: String?`, read via `summaryFor(currentDocumentPath)`.
  `onLogicValidation(documentPath)` carries the path so the consumer can filter without re-reading;
  ignore publishes for other documents, and null-guard the edge where a publish arrives before the
  first `onClientState` has set `mainObjectLocation`. Compare against current state before `setState`
  (it's an `RPureComponent`, but a `busy=true → busy=true` publish shouldn't even reach React).
- Fold into the gate: `runnable = isLogic && runBlocker == null && validationBlockReason == null`;
  the disabled tooltip prefers `runBlockReason ?: validationBlockReason ?: "…not runnable"`.
  (Definition failures remain fresh/synchronous; the paradigm `validationBlockReason` is additive.)
- Render a small **busy indicator** when `busy` (MUI `CircularProgress` ~16 px, tooltip "Revalidating…"),
  placed in the control cluster (e.g. row 2, left of the divider). `busy` **indicates only — it does not
  disable Run**; only a known `invalidReason` disables (confirmed decision).

### Publishers — one per paradigm (staged)

- **Script** — inject `logicValidationGlobal` (`@Service`) into `ScriptController.Wrapper` → `ScriptStore`.
  Call `validation(path, inFlight=true, …)` whenever a revalidation is scheduled — BOTH the
  `documentNotationChanged` branch AND the `initial` (mount) branch of `onClientState` call
  `refreshValidationAsync()`, so both must publish (synchronously, so there is no flicker gap before
  `refresh()` runs); on `ScriptValidationStore.refresh()` completion call `validation(path, false,
  stepValidations.values.firstNotNullOfOrNull { it.errorMessage })`. On the fetch-failure path
  (`ClientError`, `scriptValidation=null`) the reason computes to null → Run enabled on *unknown*
  validity — a deliberate decision matching the "null = valid/unknown" semantics (the global error
  banner carries the fetch failure), not an accident.
- **Job** — same pattern via `JobController` + `JobValidationStore` over `workerValidations`.
- **Flow** — `FlowController` computes `FlowStructureValidator` findings today, but inside
  `renderStructureFindings` (the render path) — publishing from there would `setState` on
  `HeaderRunController` mid-render (React "cannot update a component while rendering" violation).
  **Move the findings computation to the state-derivation path** (FlowController's client-state
  observer), publish `validation(path, false, findings.firstOrNull())` there, and have render reuse
  the computed findings. Synchronous, so `inFlight` is always false. This also **fixes the current
  gap** where a structurally-broken Flow shows Run enabled.
- **Report** — publish `invalidReason = ReportState.notationError`; `inFlight` from `formulaLoading`.

### Immediacy — instrument the shared commit pipeline

- `AttributeCommitter` (`objects/document/common/edit/AttributeCommitter.kt`) gains an **optional
  (default-null)** `logicValidationGlobal` constructor param and reports edit-activity for its document
  (path from `objectLocation().documentPath`, itself as the committer token): `schedule()` → mark
  pending; settle → clear. This lights up **the instant a key is pressed**, before the 1 s debounce,
  then the paradigm's validation `inFlight` takes over — one continuous busy window.
- **The clear is internal to the committer, on every exit path** — never delegated to the caller-owned
  `onCommitted`/`onError` callbacks (both optional):
  - `commitNow()` settle (success AND error), wrapped around the commit itself;
  - the `pendingNotation() == null` early return in `commitNow()` (otherwise busy sticks forever);
  - `cancel()` (discards the pending commit, so the pending mark must go with it);
  - flush-on-unmount already routes through `flush()` → `commitNow()`, so it's covered by the first.
- **Scope: wire only `KotlinExpressionEditor` initially** (optionally `TextAttributeEditor` within
  Script) — that fully covers the motivating FormulaStep scenario. Editors receive services via props
  (the `mirroredGraphStore` precedent), so wiring ALL committer-based editors means threading the
  global through ~9 editor Props interfaces plus ~19 render call sites across 11 files (including
  `DefaultAttributeEditor`'s dispatcher and the Report/Job spec editors) — broaden opportunistically
  later, not in this pass. The optional param is what keeps unwired construction sites untouched.
- Non-committer edit paths (delete, drag, breakpoint) commit immediately (no debounce gap) and their
  post-commit window is covered by the paradigm's revalidation `inFlight`, so they need no
  instrumentation. Report's formula editor uses its own debounce → its immediacy is deferred (covered
  coarsely by `formulaLoading`); acceptable, outside the FormulaStep scenario — and consistent with
  the scoped wiring above.

## Files

**Create**
- `kzen-auto-js/.../client/service/logic/LogicValidationGlobal.kt` — the global, `Observer`, summary.

**Modify**
- `client/service/ClientContext.kt` — construct + expose `logicValidationGlobal`, and register it in
  `graphEnvironment` (ClassName-keyed) for `@Service` injection.
- `client/objects/ribbon/HeaderRunController.kt` + `HeaderController.kt` — new prop, observe, gate + spinner.
- `client/objects/document/script/{ScriptController.kt, model/ScriptStore.kt, valid/ScriptValidationStore.kt}` — Script publisher.
- `client/objects/document/job/{JobController.kt, JobValidationStore.kt}` — Job publisher.
- `client/objects/document/flow/FlowController.kt` — Flow publisher; move the findings computation out
  of `renderStructureFindings` into the state-derivation path (render reuses it).
- `client/objects/document/report/{ReportController.kt or run store}` — Report publisher.
- `client/objects/document/common/edit/AttributeCommitter.kt` — optional edit-pending param + internal
  clear on every exit path; wire from `script/display/edit/KotlinExpressionEditor.kt` only (see scope
  note above — other construction sites untouched).

**Reuse (no new logic):** `StepValidation.errorMessage`, `FlowStructureValidator.validate`,
`ReportState.notationError`/`formulaLoading`, `DefinitionErrors.runBlocker`, MUI `CircularProgress`.

## Staging (each stage shippable)

1. **Core** — `LogicValidationGlobal` (two input channels, derived summary, no-op guard) +
   `ClientContext` + `HeaderRunController`/`HeaderController` consumption (disable-on-invalid + busy
   spinner) + **Script** publisher. Delivers the FormulaStep scenario end-to-end (minus keystroke
   immediacy).
2. **Breadth** — Job, Flow (findings moved out of render), Report publishers (flavour-agnostic
   disable-on-invalid everywhere; fixes the Flow "broken flow, Run enabled" gap).
3. **Immediacy** — `AttributeCommitter` instrumentation (optional param, internal clear on every exit
   path), wired from `KotlinExpressionEditor` so `busy` fires on keystroke in the FormulaStep scenario;
   broader editor wiring deferred.

## Confirmed decisions

- **`busy` indicates but does NOT disable Run** — only a known `invalidReason` (or definition failure)
  disables. While revalidating, the last-known `invalidReason` may briefly lag the newest edit; the
  server still gates the actual run, and synchronous definition-failure blocking stays fresh. (Chosen over
  the stricter "disable while busy", which would grey Run out on every debounced keystroke.)
- **Deliver all three stages** (core+Script → Job/Flow/Report → typing immediacy).

## Verification

- Fast compile gate: `cd ../kzen-auto && ./gradlew :kzen-auto-js:compileKotlinJs`.
- Dev loop (`BackendDevelopment` + `FrontendDevelopment` + `-t :kzen-auto-js:jsEsbuildBundle -PjsWatch`):
  - **Script**: break a FormulaStep (`1 +`) → Run disables with the compile error as tooltip; type in a
    formula → busy spinner appears immediately, persists through revalidation, clears when settled; the
    type chip updates.
  - **Overlapping edit** (the two-channel race): type, wait for the commit, then type again while the
    first revalidation is still in flight → the spinner must stay on continuously until the second
    edit's revalidation settles (no early drop when the first validation completes).
  - **Job**: broken Worker expression → Run disables; editing shows busy.
  - **Flow**: introduce a structural error → Run now disables (previously stayed enabled).
  - **Report**: trigger a `notationError` → Run disables.
- Keep the server-side `FormulaStepTest` canary green (unrelated but the type-inference guard).