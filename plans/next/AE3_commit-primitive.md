# AE3 — shared commit primitive + field-local error capture — implementation plan

> **✅ DONE 2026-07-20.** Landed in one session, all 9 commits as planned; every anchor in this
> document was still accurate at execution time and all three drift flags held exactly as
> described. Trackers ticked in `../2026-07-14_attribute-editor-improvements.md` (Phase 3, carries
> the as-built note), `../2026-07-16_master-plan.md` (Stage B1 + rule 4 + roadmap block) and
> `README.md` here. AE1/AE2 having landed since this was written changed nothing in the blast
> radius except the residue arithmetic: `AttributePathValueEditorOld` is already gone, and
> `ClientLogicGlobal`'s third site is a `throttle`, not a `debounce` — so the post-phase
> `lodash.debounce` residue is **7** non-adopter sites plus the kernel (4 Report-seam + 2
> `ClientLogicGlobal` + `AttributePathValueEditor`), and `// TODO: handle error` is down to the
> single `AttributePathValueEditor:252` that AE4 deletes.
>
> Deviations from the letter of this plan, both simplifications:
> - `TargetSpecEditor`'s `submitDebounceMillis` companion const was **deleted** rather than passed
>   as `delayMillis` — it duplicated `DebouncedSubmitter.defaultDelayMillis` (Q10's intent).
> - `JobChannelNumberField` got a two-line private `applyCommand(command)` wrapper around
>   `CommonEditUtils.applyCommand` + `setState`, instead of inlining that pair at both call sites.
>
> Q6 resolved on the happy path: MUI's `InputLabel` binding **does** expose `error`, so no
> `NamedColor.red` fallback was needed. Verification: full `./gradlew build` green in kzen-auto,
> zero compiler warnings on a `--rerun-tasks` recompile; the 5 new `AttributeCommitterTest` cases
> pass under ChromeHeadless (`:kzen-auto-js:jsTest`), covering success ordering, remote failure,
> the message-less `toString()` fallback, null-pending, and the explicit-value overload. **The
> manual browser matrix in § Verification is still owed — it needs the user.**

> **Status: superseded by the note above.** Generated 2026-07-19 from
> `2026-07-14_attribute-editor-improvements.md` **Phase 3**. Decisions pre-made in the
> constituent plan (esp. D3 — `onCommitted`/`onChange` on successful apply only — and D4 —
> global banner stays authoritative, `onError` is additive; no `suppressErrorDisplay`) — do not
> re-litigate. Every anchor below re-verified against current kzen-auto master (`ceb699d0`,
> clean tree) on 2026-07-19. The post-plan landings (SER2–SER5, Y, G5, G7, TP1/TP3/TP4) did
> **not** touch any file in this phase's blast radius — the drift found (three adopters whose
> shape deviates from the constituent plan's table, § Drift flags) is editor-feature evolution
> from the FE/XC arcs, already in place when the AE plan was written but under-described by its
> one-line table. One session; 9 commits (primitive first, then one adopter per commit).

All client paths below are under
`kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/` unless said otherwise.

## Scope & goal

One implementation of the copied `lodash.debounce(1000)` + flush-on-blur/unmount +
`CommonEditUtils.editCommand` → `mirroredGraphStore.apply` + `// TODO: handle error` idiom,
as two plain classes under `objects/document/common/edit/` (no `@Reflect`, no notation object,
no yaml — nothing in this phase touches notation or KSP):

- **`DebouncedSubmitter`** — the debounce + flush kernel, usable without command plumbing.
- **`AttributeCommitter`** — kernel + `editCommand` + `apply` + error capture + D3 ordering.
- plus one shared `suspend` helper `CommonEditUtils.applyCommand(store, command): String?`
  (apply + error-message extraction) that both `AttributeCommitter` and the one
  command-shape-irregular adopter (`JobChannelNumberField`) use.

Eight adopters shed their copies mechanically, one per commit; six of the seven `// TODO:
handle error` sites in live code disappear (the seventh is `AttributePathValueEditor`, deleted
by AE4). Field-local feedback: a failed apply turns the field's MUI `error` state on where the
editor has a field to turn red; the global banner keeps showing the message (D4).

**Behaviour deltas (all pre-accepted):** D3 — `onChange` consumers (Report refresh triggers,
see inventory in § Risks) no longer fire after a *failed* write (correct: nothing changed);
error state on a field is new, additive.

## Dependencies & coordination

- **Master plan Stage B1 opener**: AE3 → AE4 → AE5 spine (`2026-07-16_master-plan.md:144–148`);
  rule 4 (`:210–211`): AE3+AE5 precede S8b and J8.4 — no action now, those run later.
- **AE1 / AE2 have NOT landed** (verified: `flow/edit/AttributePathValueEditorOld.kt` still
  exists; `SelectClosePolicyEditor.kt` still exists; AE plan tracker all unchecked). AE3 is
  independent of both, in either order:
  - If AE1 lands first, `PluginController` becomes a `TextAttributeEditor` consumer
    (`onChange = { loadInfo() }` — D3's named delta). If AE3 lands first, AE1's migration
    target already carries the committer. Props contract unchanged either way — no conflict.
  - `AttributePathValueEditorOld.kt` (debounce at :114, TODO at :242) is **not** an AE3
    adopter — AE1 deletes it. Likewise `common/AttributePathValueEditor.kt` (debounce :133–137,
    TODO :252, flush comment :325–328) is **not** touched — AE4 deletes it.
- **Single repo, single module**: kzen-auto-js only. No kzen-lib change, no notation change,
  no server change, no publishToMavenLocal.
- Git hygiene: stage each new file by explicit path as soon as written; stage only, never
  commit unless asked (umbrella rule). "One adopter per commit" below refers to logical
  commits the user makes — prepare each as a clean staged increment.

## Current-state findings

### Shared plumbing (shapes verified)

| Piece | Anchor | Shape |
|---|---|---|
| `lodash.debounce` binding | `wrap/lodash.kt:19–22, :36–42` | `debounce(fn: () -> Unit, millis: Int): FunctionWithDebounce`; `FunctionWithDebounce.apply() / cancel() / flush()` |
| `async` helper | `util/ajaxUtil.kt:135` | `fun <T> async(x: suspend () -> T): Promise<T>` — `startCoroutine`, i.e. runs synchronously to the first suspension. This is what makes `flush()` sequence a pending write ahead of the next user command |
| `CommonEditUtils.editCommand` | `objects/document/common/edit/CommonEditUtils.kt:12–32` | empty nesting → `UpsertAttributeCommand(loc, path.attribute, notation)`; else `UpdateInAttributeCommand(loc, path, notation)`; returns `StructuralNotationCommand` |
| `MirroredGraphStore.apply` | kzen-lib `service/store/MirroredGraphStore.kt:87–146` | `suspend fun apply(command: NotationCommand, attachment = empty): MirroredGraphResult`; local+remote run in parallel `async` blocks; failures also fan out via `publishFailure` → banner |
| `MirroredGraphError` | kzen-lib `service/store/MirroredGraphResult.kt:9–12` | `data class MirroredGraphError(val error: Throwable, val remote: Boolean)`; sibling `MirroredGraphSuccess(event, refreshed)` |
| Established extraction idiom | e.g. `report/analysis/model/ReportAnalysisStore.kt:127`, `custom/view/CustomViewStore.kt:68` | `(result as? MirroredGraphError)?.error?.message` — ~15 Report-store sites; CustomViewStore adds the `?: error.toString()` null-message fallback we adopt |
| Global banner | `objects/ProjectController.kt:330–346` (observer), `:617–630` (render) | any non-suppressed `onCommandFailure` → red "Command error: …" banner; `suppressErrorDisplay` attachment (`:119–126`) used only by `DataFormatFieldAdd:94`, `ObjectRegistryEdit:87`, `ObjectRegistryAdd:107` — none of the AE3 adopters. D4: the new primitive passes **no** attachment |
| `AttributeEditorProps` | `objects/document/common/attribute/AttributeEditorProps.kt:10–16` | `objectLocation`, `attributeName`, `clientStateGlobal`, `mirroredGraphStore` — **no `onChange`** (so the two manager-hosted adopters have no `onCommitted` consumer) |
| `muiAutocompleteField` | `wrap/select/MuiAutocompleteField.kt:53–69` | no `error` param today; renders an inner `TextField.create` at :126–151 → additive `error: Boolean = false` pass-through is a 3-line change (commit 6) |
| jsTest infra | `kzen-auto-js/src/jsTest/.../ClientTest.kt` (placeholder), `build.gradle.kts:29` (browser runner), jsTest deps = `kotlin("test")` only | Promise-returning test pattern (per the commented `AsyncTest.kt` template) works without new deps; kzen-lib's `MapNotationMedia` harness (template: kzen-lib `server/store/DirectGraphStoreCacheTest.kt:25–28`) is commonMain, available via `kzen-lib-js` |

Name check: no `DebouncedSubmitter` / `AttributeCommitter` exists anywhere in kzen-auto — clean.

### Per-adopter audit (anchors verified 2026-07-19)

`lodash.debounce` full inventory in jsMain (15 sites): the 6 adopter sites below + the 2
phase-external editors (`AttributePathValueEditor:133` → AE4, `AttributePathValueEditorOld:114`
→ AE1) + 4 Report-seam sites that **stay** (`FormulaItemController:55`,
`InputSelectedGroupController:49`, `InputBrowserFilterController:50`, `ReportStore:208`
refreshDebounce) + 3 transport sites in `ClientLogicGlobal` (:156 throttle, :357, :361) that
are not editors. Nothing unaccounted.

| # | Adopter | Debounce | Flush wirings | Commit body & guards | Error today | onChange ordering |
|---|---|---|---|---|---|---|
| 1 | `common/edit/TextAttributeEditor.kt` | :64–68, 1000 ms | onBlur :175 (race comment :173–174) AND unmount :109–111 | `submitEdit` :124–134: `ScalarAttributeNotation(state.value)` → editCommand → apply; no no-op guard (re-typing same text re-writes) | `// TODO` :130; `error = props.invalid` :182 | `props.onChange?.invoke(value)` :133, after apply, unconditional |
| 2 | `common/edit/MultiTextAttributeEditor.kt` | :58–62, 1000 ms | onBlur :160 (comment :158–159) AND unmount :87–89 | `submitEdit` :111–132: dedup-if-`props.unique` → `ListAttributeNotation` → editCommand → apply | `// TODO` :128; `error = props.invalid` :163 | `onChange(adjustedValues)` :131, unconditional |
| 3 | `script/display/edit/KotlinExpressionEditor.kt` | :104–108, 1_000 ms | onBlur :396 (comment :394–395) AND unmount :144 ("Flush (not cancel)" comment :143) | debounced `onSubmitEdit` :264–271: bail null buffer, **no-op guard `current == state.serverValue`**; `submitValue` :274–281: **Scalar** → editCommand → apply. **Immediate path** `insertReference` :319–323: `cancel()` then `async { submitValue(newValue) }` — value passed **explicitly**, deliberately not read from just-set React state | none (no TODO, fire-and-forget) | no onChange prop (manager-hosted); server echo re-hydrates via `onClientState` :158–187 (hydration-never-submits discipline :174–177) |
| 4 | `script/display/edit/TargetSpecEditor.kt` | :106–108, const :101, 1000 ms | unmount :197–201; **blur is delegated**: `onEditCommit = { submitDebounce.flush() }` :327 through `TargetValueEditorContext` (:133, doc "Flush a pending debounced edit (blur)") → fragment wires `onBlur = { context.onEditCommit() }` `TargetTypeDisplay.kt:110` | `editAttributeCommand` :249–283: bail null `typeName`, build `MapAttributeNotation` {type, value?} preserving foreign keys (e.g. `policy:`) read from `state.clientState` :264–275, direct `UpsertAttributeCommand` :279–282 (≡ editCommand at `AttributePath.ofName`). Trigger matrix in `componentDidUpdate` :150–186: hydration echo-suppressed via `initialized` :155–161; type-change immediate iff valueless type :163–169; value: `renaming` clear :171–175 / `immediateWrite` :176–181 / debounced :183. `onTypeChange` **cancels** pending :286–295 | none | no onChange prop |
| 5 | `common/edit/BooleanAttributeEditor.kt` | **none** — immediate | n/a (nothing pending) | `submitEditAsync` :45–53 guard `props.value == newValue`; `submitEdit` :56–66: Scalar → editCommand → apply. Bare `State` (no state interface) | `// TODO` :62; **no** error display (Switch) | `onChange(newValue)` :65, unconditional |
| 6 | `common/edit/SelectAttributeEditor.kt` | **none** — immediate | n/a | `submitEditAsync` :46–54 guard `props.value == newValue`; `submitEdit` :57–67 | `// TODO` :63; `invalid` prop declared :31 but **never rendered** (muiAutocompleteField has no error param) | `onChange(value)` :66, unconditional |
| 7 | `job/JobChannelNumberField.kt` | :100–104, 1000 ms | onBlur :236 AND unmount :93–96 | `submitEdit` :161–183: trim → cleared ⇒ `RemoveInAttributeCommand` iff overridden ∧ nested (:165–173); `toIntOrNull` canonicalize, bail unparseable / unchanged (:175–180); `writeCommand` :189–207 picks `UpsertAttributeCommand` / `UpdateInAttributeCommand` / `InsertMapEntryInAttributeCommand` by path shape + own-notation presence. **Not expressible as `pendingNotation` → `editCommand`** (nested-no-entry needs InsertMapEntry; clear needs Remove) | none; no error display | no onChange prop; hydration-never-echoes discipline (comment :159, gate :138–141) |
| 8 | `job/edit/FormulaMapRow.kt` | :56–60, 1_000 ms | onBlur :131 (comment :129–130) AND unmount :87–89 | `onSubmitEdit` :70–75: no-op guard `state.value == props.formula`, then **delegates to `props.onUpdate`** — no command of its own (parent `FormulaMapEditor.applyUpdate` :155–160 applies `FormulaSpec.updateFormulaCommand`, fire-and-forget) | n/a (parent's seam) | n/a |
| — | `common/AttributePathValueEditor.kt` | :133–137 | :328/:352/:389 + unmount :100 | **SKIP** — deleted in AE4 | `// TODO` :252 | — |

### Drift flags (vs the constituent plan's adopter table)

1. **`KotlinExpressionEditor` is scalar-shaped, not map-shaped.** The plan row says "its
   map-shaped submit body becomes the `pendingNotation` lambda" — the current submit is a plain
   `ScalarAttributeNotation` via `editCommand` (:274–281); the map-shaped description matches
   `TargetSpecEditor`. Also under-described: the file grew the step-reference insert machinery
   (popover + canvas pick session + caret splice) with an **explicit-value immediate write**
   (:319–323) that must NOT become a read-state-at-commit-time path (§ Pre-resolved Q1) and a
   `serverValue` no-op guard that must survive as a null-return from `pendingNotation`.
2. **`TargetSpecEditor`'s blur flush is delegated** through `TargetValueEditorContext.onEditCommit`
   to the per-type fragments (`TargetTypeDisplay.kt:110`) — the plan's "keep both wirings" rule is
   satisfied by keeping that context lambda's contract identical (only its body changes to
   `committer.flush()`). The `TargetValueEditorContext` SPI itself is untouched.
3. **`JobChannelNumberField` is NOT "same swap as Text".** Its commit picks between four command
   shapes (`Remove`/`Upsert`/`UpdateIn`/`InsertMapEntry`) that `editCommand` cannot express
   (`editCommand`'s nested branch always emits `UpdateInAttributeCommand`, which is wrong when
   no entry exists yet — that's exactly why `writeCommand` exists). Resolution in § Pre-resolved
   Q4: it adopts `DebouncedSubmitter` + `CommonEditUtils.applyCommand`, keeping `writeCommand`.
4. Non-drift confirmations: Text/MultiText anchors match the plan's table exactly (:64–68/:124–134
   and :58–62/:111–132); `FormulaMapRow` matches its kernel-only description; Boolean/Select
   match "immediate, no debounce". `SelectValuesEditor` (:125–136, immediate fire-and-forget,
   no TODO) is **not** in the adopter list and stays out (future opportunistic adopter — noted
   in § Out of scope).

## Pre-resolved questions

1. **`commitNow` gets an explicit-value overload `commitNow(notation: AttributeNotation)`.**
   The sketch's note "also callable directly by immediate-submit editors" is realized as an
   overload because the immediate callers' values are *not yet readable from React state* at
   call time: `insertReference` deliberately passes `newValue` (setState in the same tick may
   not have flushed), and Boolean/Select take the value from the toggle/select event while
   `props.value` still holds the old value. Reading `pendingNotation()` there would commit
   stale state. The no-arg `commitNow()` (debounce/flush path) reads `pendingNotation()` at
   commit time and bails on null, exactly per the sketch.
2. **The apply + error-extraction core lives in `CommonEditUtils.applyCommand`**, not inside
   `AttributeCommitter` — so `JobChannelNumberField` (whose commands bypass `editCommand`)
   shares the single error-extraction implementation instead of hand-rolling a fourth copy.
   `AttributeCommitter.commitNow` delegates to it. Signature:
   `suspend fun applyCommand(graphStore: MirroredGraphStore, command: NotationCommand): String?`
   — null on success.
3. **Failure must never yield a null message**: `Throwable.message` can be null, and
   `onError(null)` means success — so extraction is `error.message ?: error.toString()`
   (the `CustomViewStore.kt:68` idiom). This is a genuine correctness point, not style.
4. **`JobChannelNumberField` = kernel + `applyCommand`, not the full committer** (drift flag 3).
   It keeps `submitEdit`/`writeCommand` verbatim, swaps the debounce for `DebouncedSubmitter`,
   and routes each of its two `mirroredGraphStore.apply(...)` calls through
   `CommonEditUtils.applyCommand`, feeding a new `errorMessage` state → TextField `error`.
   Dedupe goals (one debounce kernel, one error extraction) are met without forcing the
   notation-shaped API onto a command-shaped editor.
5. **`muiAutocompleteField` gains an additive `error: Boolean = false` param** (commit 6):
   set `this.error = error` on the inner `TextField.create` (:127–133 region). Default false —
   all ~10 existing call sites unaffected. Without it, Select's "uniform error capture" (plan
   table) would be dead state with no display; with it, `SelectAttributeEditor` renders
   `error = props.invalid || state.errorMessage != null`, incidentally activating its
   declared-but-never-rendered `invalid` prop (currently no consumer sets it — safe).
6. **Boolean's display = `error` on `InputLabel`** (`error = state.errorMessage != null`).
   MUI's InputLabel API has `error: bool`; if the kotlin-wrappers binding unexpectedly lacks
   it, fall back to a conditional `sx { color = NamedColor.red }` (NamedColor already imported
   there). One-line either way; compile decides.
7. **`TargetSpecEditor` and `KotlinExpressionEditor` get no `onCommitted`** —
   `AttributeEditorProps` has no `onChange` (verified :10–16); TargetSpec also gets no
   `onError` display seam of its own (its value row belongs to the type fragments; extending
   `TargetValueEditorContext` is an SPI change — out of scope), so TargetSpec passes
   `onError = null` and its adoption is pure plumbing dedupe. KotlinExpression *does* own a
   TextField (`renderTextField` :379–398) and wires `error = state.errorMessage != null`.
8. **No-op guards stay where they live today**: Boolean/Select keep the `props.value == newValue`
   guard before calling the committer; KotlinExpression's `serverValue` guard becomes a null
   return from `pendingNotation`; FormulaMapRow's `state.value == props.formula` guard stays in
   its submit lambda; JobChannelNumberField's canonicalize/no-change bails stay in `submitEdit`.
   Text/MultiText had no guard and gain none (unchanged behaviour).
9. **D4 verified**: the new primitive passes no attachment (banner fires for every adopter
   failure, as today); the `suppressErrorDisplay` attachment's only three callers are
   non-adopters.
10. **Delay stays 1000 ms for every adopter** (all six debounced sites are 1000 today);
    `DebouncedSubmitter` defaults it (`defaultDelayMillis = 1000`) so adopters pass nothing.
11. **Lambda-props are mandatory, not stylistic**: every `AttributeCommitter` constructor arg
    that touches props/state is a lambda read at commit time. Capturing `props.mirroredGraphStore`
    (the value) at construction would pin the first render's props across the component's life.

## Step-by-step implementation

### Commit 1 — the primitive (2 new files + 1 helper + test)

**New `objects/document/common/edit/DebouncedSubmitter.kt`**
(package `tech.kzen.auto.client.objects.document.common.edit`):

```kotlin
import tech.kzen.auto.client.util.async
import tech.kzen.auto.client.wrap.FunctionWithDebounce
import tech.kzen.auto.client.wrap.lodash

/**
 * Debounce + flush kernel for editor commits (usable without command plumbing).
 *
 * Debounce-race invariant (documented behaviour): wire [flush] to BOTH onBlur and
 * componentWillUnmount, so a pending edit is committed before a following separate command
 * (e.g. a step rename) rather than racing it.
 */
class DebouncedSubmitter(
    delayMillis: Int = defaultDelayMillis,
    private val submit: suspend () -> Unit
) {
    companion object {
        const val defaultDelayMillis = 1000
    }

    // NB: async {} stays INSIDE the debounced lambda — lodash flush() then starts the submit
    // coroutine synchronously (util.async is startCoroutine: runs to the first suspension),
    // which is what sequences a flushed write ahead of the caller's next command.
    private val debounce: FunctionWithDebounce = lodash.debounce({
        async {
            submit()
        }
    }, delayMillis)

    fun schedule() { debounce.apply() }
    fun flush() { debounce.flush() }
    fun cancel() { debounce.cancel() }
}
```

**`CommonEditUtils` addition** (same file as `editCommand`):

```kotlin
/**
 * Apply [command]; null on success, else a non-null field-local error message
 * (message ?: toString() — never null on failure, since onError(null) means success).
 * The failure also reaches the global banner via the store's publishFailure (D4:
 * additive field feedback, banner authoritative; no suppressErrorDisplay attachment).
 */
suspend fun applyCommand(
    graphStore: MirroredGraphStore,
    command: NotationCommand
): String? {
    val result = graphStore.apply(command)
    val error = (result as? MirroredGraphError)?.error
        ?: return null
    return error.message ?: error.toString()
}
```

(new imports: `NotationCommand`, `MirroredGraphStore`, `MirroredGraphError`.)

**New `objects/document/common/edit/AttributeCommitter.kt`**:

```kotlin
/**
 * The shared commit pipeline: pendingNotation → CommonEditUtils.editCommand → apply →
 * error extraction → onError, then onCommitted on success only (D3), after apply
 * (onChange-ordering rule). Constructor args are lambdas so props/state are read at
 * commit time, never captured at construction.
 */
class AttributeCommitter(
    private val graphStore: () -> MirroredGraphStore,
    private val objectLocation: () -> ObjectLocation,
    private val attributePath: () -> AttributePath,
    private val pendingNotation: () -> AttributeNotation?,   // null = nothing to commit
    private val onCommitted: ((AttributeNotation) -> Unit)? = null,
    private val onError: ((String?) -> Unit)? = null,        // null message = success
    delayMillis: Int = DebouncedSubmitter.defaultDelayMillis
) {
    private val submitter = DebouncedSubmitter(delayMillis) { commitNow() }

    fun schedule() { submitter.schedule() }
    fun flush() { submitter.flush() }      // wire to onBlur AND componentWillUnmount
    fun cancel() { submitter.cancel() }

    /** Debounced/flush path: read the pending value at commit time; bail on null. */
    suspend fun commitNow() {
        val notation = pendingNotation()
            ?: return
        commitNow(notation)
    }

    /** Immediate-submit path (event-carried values: Boolean/Select toggles,
     *  KotlinExpression's insert) — the caller passes the value explicitly because
     *  React state written in the same tick may not be readable yet. */
    suspend fun commitNow(notation: AttributeNotation) {
        val command = CommonEditUtils.editCommand(objectLocation(), attributePath(), notation)
        val errorMessage = CommonEditUtils.applyCommand(graphStore(), command)
        onError?.invoke(errorMessage)
        if (errorMessage == null) {
            onCommitted?.invoke(notation)
        }
    }
}
```

**Test** — see § Tests (`jsTest/.../AttributeCommitterTest.kt`, same commit).

Stage all new files by explicit path. Build gate: `./gradlew :kzen-auto-js:build -x test`.

### Commit 2 — `FormulaMapRow` (kernel only — lowest risk, single consumer)

Replace :56–60 with
`private val submitter = DebouncedSubmitter { onSubmitEdit() }`
(make `onSubmitEdit` `suspend`, or keep it non-suspend — the lambda accepts either; keep the
`state.value == props.formula` guard verbatim). `onValueChange` :82 → `submitter.schedule()`;
unmount :88 and onBlur :131 → `submitter.flush()` (keep both comments). Drop the
`FunctionWithDebounce`/`lodash`/`async` imports (add
`tech.kzen.auto.client.objects.document.common.edit.DebouncedSubmitter`). **No further
restructure** — it delegates to `props.onUpdate`, not a command; the parent
`FormulaMapEditor.applyUpdate` (:155–160) stays fire-and-forget (Report-subsumption seam,
J2–J4/J9).

### Commit 3 — `TextAttributeEditor` (proves the full committer + error wiring)

- `TextAttributeEditorState` (:44–46): add `var errorMessage: String?`.
- Replace `submitDebounce` (:64–68) with:
  ```kotlin
  private val committer = AttributeCommitter(
      graphStore = { props.mirroredGraphStore },
      objectLocation = { props.objectLocation },
      attributePath = { props.attributePath },
      pendingNotation = { ScalarAttributeNotation(state.value) },
      onCommitted = { props.onChange?.invoke((it as ScalarAttributeNotation).value) },
      onError = { message -> setState { errorMessage = message } })
  ```
- Delete `submitEdit` (:124–134, incl. the TODO). `onValueChange` :120 →
  `committer.schedule()`; unmount :110 → `committer.flush()`; onBlur :175 →
  `committer.flush()` (keep the race comment :173–174).
- Render :182: `error = props.invalid || state.errorMessage != null`.
- Import diff: drop `tech.kzen.auto.client.util.async` (now unused); `wrap.*` already covers
  `setState`; the committer is same-package.

### Commit 4 — `MultiTextAttributeEditor`

Same swap (:58–62 / :111–132), with the dedup moved into the lambda:

```kotlin
pendingNotation = {
    val adjustedValues =
        if (props.unique) { state.value.toSet().toList() }
        else { state.value }
    ListAttributeNotation(adjustedValues
        .map { ScalarAttributeNotation(it) }
        .toPersistentList())
},
onCommitted = { notation ->
    props.onChange?.invoke((notation as ListAttributeNotation).values.map { it.asString()!! })
}
```

(extracting the committed values from the notation reproduces today's exact `adjustedValues`
payload, immune to state moving on during the suspended apply). State + `errorMessage`;
`error` :163 → `props.invalid || state.errorMessage != null` — this is `AnalysisFlatController`'s
live `invalid` wiring (:240, :279), preserved by the `||`. Unmount :88 / onBlur :160 →
`committer.flush()`.

### Commit 5 — `BooleanAttributeEditor` (immediate path)

- New `external interface BooleanAttributeEditorState: State { var errorMessage: String? }`;
  class becomes `RPureComponent<BooleanAttributeEditorProps, BooleanAttributeEditorState>`.
- Committer with `pendingNotation = { null }` (documented: no debounced path — schedule/flush
  never called), `onCommitted = { props.onChange?.invoke((it as ScalarAttributeNotation).value.toBoolean()) }`,
  `onError = { message -> setState { errorMessage = message } }`.
- `submitEditAsync` (:45–53) keeps its `props.value == newValue` guard; body becomes
  `async { committer.commitNow(ScalarAttributeNotation(newValue.toString())) }`. Delete
  `submitEdit` (:56–66, incl. TODO).
- Render: `InputLabel` gains `error = state.errorMessage != null` (fallback per Q6).

### Commit 6 — `SelectAttributeEditor` (immediate path + widget rider)

- `wrap/select/MuiAutocompleteField.kt`: add `error: Boolean = false` param to
  `muiAutocompleteField` (:53–69) and `this.error = error` inside `renderInput`'s
  `TextField.create` (:127+). Additive; no other call site changes.
- Editor: same shape as commit 5 (`SelectAttributeEditorState` with `errorMessage`;
  guard kept in `submitEditAsync` :46–54; `commitNow(ScalarAttributeNotation(newValue))`;
  `onCommitted` → `props.onChange`); render passes
  `error = props.invalid || state.errorMessage != null` to `muiAutocompleteField`.

### Commit 7 — `JobChannelNumberField` (kernel + shared error extraction)

- Replace :100–104 with `private val submitter = DebouncedSubmitter { submitEdit() }`.
  `onValueChange` :155 → `submitter.schedule()`; unmount :95 / onBlur :236 →
  `submitter.flush()` (keep comments).
- `submitEdit` (:161–183) and `writeCommand` (:189–207) stay verbatim **except** the two
  applies:
  ```kotlin
  val errorMessage = CommonEditUtils.applyCommand(props.mirroredGraphStore, /* Remove... or writeCommand(...) */)
  setState { this.errorMessage = errorMessage }
  ```
  (state gains `var errorMessage: String?`; the parse-bail / no-change early returns leave it
  untouched — error only updates when a command is actually applied).
- TextField render (:214–237): add `error = state.errorMessage != null`.
- Import `CommonEditUtils` + `DebouncedSubmitter`; drop `lodash`/`FunctionWithDebounce`/`async`
  if now unused.

### Commit 8 — `KotlinExpressionEditor`

- State: add `var errorMessage: String?`.
- Replace :104–108 with:
  ```kotlin
  private val committer = AttributeCommitter(
      graphStore = { props.mirroredGraphStore },
      objectLocation = { props.objectLocation },
      attributePath = { AttributePath.ofName(props.attributeName) },
      pendingNotation = {
          state.value
              ?.takeIf { it != state.serverValue }   // the :264-271 no-op guard, as null
              ?.let { ScalarAttributeNotation(it) }
      },
      onError = { message -> setState { errorMessage = message } })
  ```
- Delete `onSubmitEdit` (:264–271) + `submitValue` (:274–281). `onValueChange` :260 →
  `committer.schedule()`; unmount :144 → `committer.flush()` (keep "Flush (not cancel)"
  comment); onBlur :396 → `committer.flush()` (keep comment).
- `insertReference` (:319–323): `committer.cancel()` then
  `async { committer.commitNow(ScalarAttributeNotation(newValue)) }` — **explicit value, per
  Q1; do not route through the pendingNotation read** (state set one line earlier may not be
  visible yet; also the serverValue guard must not suppress this write).
- `renderTextField` TextField: add `error = state.errorMessage != null`.
- Hydration discipline untouched: `onClientState` (:158–187) still never submits.

### Commit 9 — `TargetSpecEditor` (most delicate — last)

- Replace :106–108 with a committer whose `pendingNotation` is the current
  `editAttributeCommand` body minus the apply (:249–277): bail null `typeName`; build the
  `MapAttributeNotation` {typeSegment, valueSegment?} + foreign-key preservation from
  `state.clientState`; return it. `attributePath = { AttributePath.ofName(props.attributeName) }`
  — `editCommand` with empty nesting emits exactly today's direct
  `UpsertAttributeCommand(objectLocation, attributeName, notation)` (:279–282). `onCommitted` /
  `onError` = null (Q7).
- Mechanical call-site swaps, triggers untouched: `editAttributeCommandAsync()` at :167 and
  :180 → `async { committer.commitNow() }` (both run from `componentDidUpdate`, state already
  committed — the pendingNotation read is safe there); `submitDebounce.apply()` :183 →
  `committer.schedule()`; `onTypeChange`'s cancel :289 → `committer.cancel()` (keep its
  comment); unmount :200 → `committer.flush()`; `onEditCommit = { committer.flush() }` :327
  (context contract + `TargetTypeDisplay.kt:110` unchanged).
- Do **not** touch the `initialized` / `renaming` / `immediateWrite` guard matrix (:150–186) —
  the committer replaces the transport, never the triggers. Delete
  `editAttributeCommandAsync`/`editAttributeCommand` (:242–283).

After commit 9: grep jsMain for `lodash.debounce` — expect exactly the 9 non-adopter sites
listed in the audit intro (4 Report-seam + 3 ClientLogicGlobal + PathValue + PathValueOld);
grep `TODO: handle error` — expect only `AttributePathValueEditor(:252)` + `Old(:242)`.

## Tests

**`kzen-auto-js/src/jsTest/kotlin/tech/kzen/auto/client/objects/document/common/edit/AttributeCommitterTest.kt`**
(commit 1). The harness is cheap — kzen-lib's `DirectGraphStoreCacheTest.kt:25–28` is the
wiring template, all parts commonMain (available via `kzen-lib-js`):

- Local store: `DirectGraphStore(MapNotationMedia(), YamlNotationParser(),
  NotationMetadataReader(), GraphDefiner, NotationReducer())`, media seeded with
  `main.yaml` = `A:\n  hello: "a"`.
- Fake `RemoteGraphStore` (one-method interface, kzen-lib `RemoteGraphStore.kt:7–9`):
  *success* variant applies the command to a twin `DirectGraphStore` over an identically
  seeded media and returns its `digest()` (mirrors the real topology, exercises the clean
  `MirroredGraphSuccess` branch); *failure* variant throws (`MirroredGraphStore.apply` checks
  `remoteError` first — no digest needed).
- Tests are Promise-returning (`@Test fun x() = async { ... }` via `util/ajaxUtil.async` —
  the `AsyncTest.kt` template pattern; no new dependency). Cases:
  1. **Success ordering (D3)**: `commitNow()` with a pending Scalar → `onError(null)` invoked,
     then `onCommitted` with that notation; local store's `graphNotation()` shows the upsert.
  2. **Remote failure**: throwing fake → `onError` receives a non-null message (also pins the
     `message ?: toString()` fallback with a message-less `Throwable()`), `onCommitted` NOT
     invoked.
  3. **Null pending**: `pendingNotation = { null }` → no apply reaches either store, no
     callbacks.
  4. **Explicit overload**: `commitNow(notation)` commits even when `pendingNotation` returns
     null (the immediate-path contract).

If the browser-test harness fights back unexpectedly (it shouldn't — `:kzen-auto-js` has a
configured browser test target and kzen-auto-common's `WireDtoSerializerTest` precedent runs
under ChromeHeadless), descope to cases 2–4 or drop the file and note it in the tracker —
manual verification below is the phase's required gate either way; there are deliberately no
per-adopter component tests (no JS component-test infra, per the constituent plan's baseline).

## Verification

Per-commit: `./gradlew :kzen-auto-js:build -x test`. End of phase: full `./gradlew build`,
then `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` and the manual matrix below.
**All yaml inspections are read-only** (files under `notation/main/` are user documents —
never edit/revert/clean them).

1. **Debounce race** (the invariant): Script document → a step with a text attribute (e.g.
   BrowserOpenStep's url) → type a new value and *within 1 s* rename the step (its name
   editor) → open the document's yaml under `kzen-auto-jvm/src/main/resources/notation/main/`
   (read-only): the typed value must be present, under the **renamed** step (write sequenced
   before rename). Repeat once with unmount instead of blur: type, then immediately collapse
   the step / navigate away → value persisted.
2. **Report output fields still commit + refresh**: Report document → Output: change
   "Preview Start Row" / "Preview Row Count" (`OutputTableController:196/:220`) → after ~1 s
   the preview refreshes (`onPreviewRefresh` post-commit) and the value round-trips; Export
   path (`OutputExportController:123`) + the two Selects (:76/:100) likewise; Preview
   enabled toggle (`ReportPreviewController:208`) commits immediately and triggers
   `onRefresh`.
3. **`AnalysisFlatController` invalid wiring**: Report → Analysis (flat) → type an invalid
   regex (e.g. `[`) into Allow Patterns → field shows error state + message row (:240/:244),
   exactly as before (props.invalid path).
4. **Forced command failure → banner + field error**: open the same Script in two tabs;
   tab B: delete a step; tab A (stale panel, no cross-tab notation push): type into that
   step's text field → remote apply fails → global red "Command error: …" banner
   (`ProjectController:629`) AND the TextField shows the error outline (new). Repeat on a
   Job channel number field for the `applyCommand` path.
5. **Job channel fields** (`JobChannelNumberField`): worker card batchSize/capacity — type an
   override + blur immediately → lands in yaml; clear the field → override removed (revert to
   greyed inherited placeholder); Job-wide default (top-level) still always shows a value.
6. **KotlinExpression**: FormulaStep code — debounced typing persists; insert a step reference
   via the popover → immediate commit (check yaml without waiting 1 s); blur flush; a
   referenced-step rename still rewrites the expression without clobbering mid-edit typing.
7. **TargetSpec**: target step — switch to a valueless type → immediate write; switch to a
   text-valued type + type → debounced write carrying {type, value}; blur on the fragment's
   field flushes (`TargetTypeDisplay` onBlur); `policy:` key survives a rewrite; **no echo
   write on expand** (watch the document file's mtime while expanding a target step — the
   `initialized` gate must still suppress the hydration echo).
8. **Boolean/Select immediates**: toggling/selecting writes once, no echo on re-render
   (props.value guard); `onChange` refresh still fires on success.
9. `./gradlew :kzen-auto-test:selfTest` (opt-in; opens Chrome, drives browser-open scripts —
   covers Script text editing + TargetSpec end-to-end).

## Risks & gotchas

- **The debounce-race invariant, per adopter** — flush must stay wired to BOTH blur and
  unmount everywhere it is today: Text (:175/:110), MultiText (:160/:88), KotlinExpression
  (:396/:144), JobChannelNumberField (:236/:95), FormulaMapRow (:131/:88), TargetSpec
  (delegated blur `:327`→`TargetTypeDisplay:110`, unmount :200). Boolean/Select have no
  pending state — nothing to wire. Keep the explanatory comments at each site (they reference
  the invariant).
- **`async{}` must stay inside the debounced lambda** (`DebouncedSubmitter`). `flush()` relies
  on lodash invoking the wrapped fn synchronously and `util.async` running the suspend body to
  its first suspension — moving the coroutine launch outside (or introducing a dispatcher hop)
  would let a following command race the flushed write, silently breaking invariant checks
  that only fail under timing.
- **Stale-state hazard on immediate writes**: any path that commits in the same tick as a
  `setState` must pass the value explicitly (`commitNow(notation)`), never read
  `pendingNotation()` — `insertReference` and the Boolean/Select event handlers. The
  `componentDidUpdate`-triggered immediates in TargetSpec are the one place a state read *is*
  safe (state is committed by then) — that asymmetry is why both overloads exist.
- **Echo-write concerns**: the committer must introduce **zero** new write triggers.
  `pendingNotation` is only evaluated from schedule/flush/commitNow. Preserve untouched: the
  TargetSpec `initialized`/`renaming`/`immediateWrite` matrix (:150–186) and its
  `onTypeChange` cancel (:286–295 — a pending debounced write firing after the value fields
  clear would emit a value-less target map); KotlinExpression's hydration-never-submits rule
  (:174–177) and its serverValue guard (now a null `pendingNotation`); JobChannelNumberField's
  own-notation gate (:138–141) and write-only-on-real-change rule (:159); Boolean/Select
  `props.value` guards. A failed run of verification step 7's mtime check is the canary.
- **Error-message nullability**: `onError(null)` = success is the API contract — the
  `message ?: toString()` fallback (Q3) is load-bearing; a bare `?.error?.message` extraction
  would mis-signal success on message-less throwables.
- **D3 delta inventory** (onChange now success-only — all are "recompute after edit" hooks,
  so skipping them on a failed write is correct): Text — `OutputTableController:208/:230`
  (`onPreviewRefresh`), `ReportOutputController:362`, `OutputExportController:123`,
  `ExportSpecEditor:229` (+ `PluginController.loadInfo` once AE1 lands); MultiText —
  `AnalysisFlatController:236/:275`, `FilterItemController:392`, `ValueSetFilterEditor:665`;
  Boolean — `ReportPreviewController:219` (`onRefresh`); Select —
  `OutputExportController:76/:100`, `ExportSpecEditor:184/:207`.
- **Post-unmount `setState` from `onError`**: an unmount-flushed commit completes after the
  component is gone; the `onError` setState is then a silent no-op (React 18+ removed the
  unmounted-setState warning). No guard needed; do not "fix" by cancelling on unmount — that
  would drop the pending edit and break the invariant.
- **`RPureComponent` shallow-equal**: `errorMessage` is a String? state slice — safe; the
  committer itself is a stable instance field (not props/state) — no re-render implications.
- **Number-typed Text quirk (pre-existing, unchanged)**: `stateText` (:92–105) renders
  thousands-separated hydration values; `pendingNotation` submits `state.value` verbatim, same
  as today's `submitEdit`. Don't "improve" in this phase.
- **Don't drift into the Report seam**: `FormulaItemController:55`,
  `InputSelectedGroupController:49`, `InputBrowserFilterController:50`, `ReportStore:208`,
  and all Report/Job leaf-editor *consumers* (props contracts unchanged) stay untouched — they
  adopt the kernel when Report is subsumed (J2–J4/J9; Job plan phase 8 item 4).

## Out of scope

- **`AttributePathValueEditor`** (deleted in AE4) and **`AttributePathValueEditorOld` +
  `PluginController`** (AE1). Their debounce/TODO sites are the only ones that remain after
  commit 9 — expected residue.
- **Report controllers** — the explicit stay-untouched list: `FormulaItemController`,
  `InputSelectedGroupController`, `InputBrowserFilterController`, `ReportStore`
  (refreshDebounce), plus consumers `OutputExportController`, `OutputTableController`,
  `ReportOutputController`, `ReportPreviewController`, `FilterItemController`,
  `AnalysisFlatController`, and Job's `ExportSpecEditor` / `ValueSetFilterEditor` (consumers
  only — their rendered editors change internally, their code does not).
- **`SelectValuesEditor`** (:125–136 immediate fire-and-forget) — not in the pre-made adopter
  list; candidate for a one-line `commitNow` adoption in AE6 or opportunistically later.
- **The select-of-reference family** (`SelectObject`/`SelectStep`/`SelectLogic`/
  `SelectChannel`/`SelectEnclosingLoop` — componentDidUpdate-commit idiom) — AE5's shared
  base owns their commit path.
- **`TargetValueEditorContext` SPI changes** (e.g. an error field for fragments) and any
  per-fragment error display for TargetSpec.
- **`helperText` message display on fields** — the banner carries the message (D4); fields
  show only the error flag (no layout shift).
- **`FormulaMapRow` restructuring** beyond the kernel swap; **`ScriptStepReferenceStore`**
  machinery in KotlinExpressionEditor.
- Renaming registered editor objects; any `editor:` marker or `*-js.yaml` change (none in
  this phase).
