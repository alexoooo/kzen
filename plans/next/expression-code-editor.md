# XCE — expression code editor (highlighting, inline errors, completion)

> **Standalone plan** (design + elaboration in one document, like `script-implicit-result.md` — the
> "Constituent plan" column reads `—`, so on landing **archive it as an as-built record, do not
> delete**). Not a phase of any constituent plan: it is a client-surface change to the Script
> flavour's Kotlin expression editor plus the server plumbing it needs, requested directly by the
> user on **2026-08-06**.
>
> Anchors captured 2026-08-06 against kzen-auto `dc69c2d1` / umbrella `dd0660d`. Re-verify before
> editing (standing rule in `README.md`).
>
> Executor: Opus-class. **Three sessions**, boundaries are hard build gates:
> **A** = lexer token stream + the `KotlinCodeArea` overlay component (syntax highlighting), ends with
> kzen-auto green; **B** = compiler error positions plumbed end to end + the inline error marker, ends
> green; **C** = auto-complete + docs + the manual smoke of all three.
>
> **Filing (do this before Session A):** add ledger row **47** to `../2026-07-25_master-plan.md` and a
> row to this directory's `README.md` § *The live set* (`Constituent plan` = `—`, standalone).
>
> ⚠ **kzen-auto has uncommitted user WIP at plan time**: `notation/main/Script.yaml` (modified) and
> `notation/main/Contexts.yaml` (untracked). Neither is touched by this plan — **do not touch them**
> (AGENTS.md § File safety). Stage every **new** file this plan creates by explicit path
> (`git -C ../kzen-auto add -- <path>`), never `git add -A`.

---

## 1. Why (design rationale — this document is the only record)

The `Code` field on a Formula step is a bare MUI multiline `TextField`
(`KotlinExpressionEditor.renderTextField`, `kzen-auto-js/…/script/display/edit/KotlinExpressionEditor.kt:422-443`).
Its validation error is rendered by the **card**, not the field — a plain `div` below the whole expanded
body (`ScriptStepDisplayDefault.renderValidation:620-636`). Typing `1.. 5x` yields
`Error: Expecting an element` with no indication of *where*, in an undifferentiated wall of text.

Two structural facts decided the shape of this plan:

- **A complete Kotlin lexer already runs in the browser.** `KotlinExpressionAnalyzer`
  (`kzen-auto-common/…/util/KotlinExpressionAnalyzer.kt`, 389 lines, commonMain) scans line and nestable
  block comments, normal and raw strings, `$id` / `${…}` template interpolation, char literals,
  back-ticked identifiers, member selectors, numeric literals and hard keywords — correctly, with tests.
  It then throws all of that away and returns only identifier references. Syntax highlighting is
  *stop discarding the tokens*, not a new lexer.
- **Error positions are computed and then deliberately destroyed.**
  `ScriptKotlinCompiler.formatError:36-46` renders the diagnostic with `withLocation = false`;
  `KotlinCompilerError` (`KotlinCompilerResult.kt:9`) carries only a `String`; `StepValidation`
  (commonMain wire model) carries only `errorMessage: String?`. Nothing between the compiler and the
  browser can say where an error is. Inline errors are blocked on plumbing, not on UI.

### 1.1 Rejected: CodeMirror 6 (or any editor library)

Would give gutter, lint squiggles with tooltips and an autocomplete widget for free. Rejected on four
grounds, the user concurring: ~6 new npm packages into a tree that currently declares **six** total
(`kzen-auto-js/build.gradle.kts:73-85`) and has a documented supply-chain-pin maintenance burden
(umbrella AGENTS.md § *npm supply-chain alerts*); a full set of Kotlin/JS `external` declarations to
write and re-validate on every wrappers bump (the 2026.x breakage catalogue in
`kzen-auto/docs/js-architecture.md` is the precedent); `useCommonJs()` is load-bearing and constrains
module format; and **no official CM6 Kotlin mode exists** — it would run the legacy `clike` mode, which
is strictly worse than the exact lexer already in `commonMain`. The overlay technique costs one
component and no dependencies.

### 1.2 Rejected: `KotlinSyntaxValidator` as the primary position source

`KotlinSyntaxValidator.validate` (`kzen-auto-jvm/…/service/compile/KotlinSyntaxValidator.kt:63-97`)
already computes an exact **user-relative** offset — its probe prefix is newline-preserving precisely so
offsets are not shifted — and then flattens it into a rendered `"description\nline\ncaret"` string. It is
the tempting shortcut, and it was rejected as the *primary* source for two reasons: it sees **syntax
errors only** (its own KDoc: "a clean parse does not promise the expression compiles"), so unresolved
references and type mismatches — the errors an author hits *after* the code parses — would still have no
position; and wiring it into the Script path means adding an `@Service` constructor parameter to
`FormulaStep`, `ResultStep`, `BindStep`, `DisposeAtSettleStep`, `DoWhileStep` and `ForEachStep`, which is
**plugin SPI surface** that downstream steps compile against.

It survives as the **fallback** if gate B.0 fails. See §5.

### 1.3 Rejected: flagging unknown identifiers client-side as errors

Tempting given the client already knows the in-scope names, and it would need no server work at all. It
misfires on locals: `val x = 1; x + 1` is a perfectly good expression whose `x` resolves to nothing
in-scope, and the analyzer's own KDoc states semantic shadowing is out of its reach. What ships instead
is the inverse and is false-positive-free: identifiers that **are** known in-scope names get a distinct
"resolved reference" colour. An unknown name is simply not decorated — a hint, never a claim.

---

## 2. What ships

| Behaviour | Session |
|---|---|
| Kotlin syntax colouring: comments, strings (incl. template interiors), char literals, numbers, keywords, identifiers, member selectors | A |
| In-scope step/binding names painted as resolved references | A |
| Monospace text, MUI outlined chrome and floating `Code` label unchanged | A |
| Compiler error position carried from `ScriptDiagnostic` to the browser, through the durable compile cache | B |
| Wavy underline at the offending token; message under the field in `pre-wrap`, no longer on the card | B |
| Marker withheld while the buffer differs from what the server validated | B |
| Caret-anchored completion over in-scope step/binding names, with their types | C |

**Not in scope, deliberately:** member completion after `.` (needs type resolution the client does not
have); the Report/Job formula editors (`FormulaItemController`, `FormulaMapRow` — different validation
path, different completion source; the component is built reusable so they can adopt it later); and
`IfBranch.condition` inline markers (see §8).

---

## 3. The position contract, end to end

The user's code is inserted **verbatim and contiguously** into the generated wrapper
(`StepExpressionCompiler.generate:56-116` — `$code` sits at column 0 of its own line in both the probe and
forced-return templates), so a generated-source position maps back to the expression by subtraction —
*provided the generator states where it put the code instead of the reader guessing*.

```
ScriptDiagnostic.location (line, col in generated source)
  └─ ScriptKotlinCompiler       → absolute offset in sourceText, minus KotlinCode.userCodeRegion.offset
       └─ KotlinCompilerError(error, userCodeOffset)         ← already user-relative here
            └─ CachedKotlinCompiler err.txt  "#kzen-offset:<n>\n<message>"   ← durable, back-compatible
                 └─ ScriptStepDefinition(returnValueDefinition, validationError, errorOffset)
                      └─ StepValidation(typeMetadata, errorMessage, warningMessage, errorOffset)
                           └─ MapExecutionValue over /action/detached
                                └─ KotlinExpressionEditor state → KotlinCodeArea errorRange
```

Two invariants that keep this honest:

- **The offset is user-relative the moment it leaves `ScriptKotlinCompiler`.** The cache key is a digest
  of the generated `sourceText` (`KotlinCode.signature():19-23`), which fully determines the user-code
  region — so a cached offset is valid for every later hit on that signature, and no consumer ever needs
  the generated source.
- **A position that does not land inside the user's region is dropped, not clamped.** An error in the
  generated accessors or the wrapper is a real error the user must see, but pointing a caret at their
  text for it would be a lie. Message only. (`KotlinSyntaxValidator:79-81` clamps because its probe
  *cannot* error outside; here it can.)

---

## 4. Session A — lexer token stream + the `KotlinCodeArea` overlay

Ends with a syntax-highlighted expression field. No server change, no behaviour change to errors — A is
independently shippable and is the visible half of the feature.

### A.1 commonMain: emit tokens from the single existing scan

1. `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/util/KotlinExpressionAnalyzer.kt` —
   add, beside `IdentifierReference` (`:24-28`):

```kotlin
enum class TokenKind {
    Whitespace, Comment, StringLiteral, CharLiteral, Number, Keyword, Identifier, Member, Operator }

data class Token(val start: Int, val endExclusive: Int, val kind: TokenKind)
```

2. Refactor `scanCode:81-161` and `scanString:166-217` to emit `Token`s into a sink, and add
   `fun tokens(code: String): List<Token>`. **Derive `identifierReferences:70-76` from that same scan**
   (`kind == Identifier`) — the file's KDoc (`:19-21`) already commits to one scan so the derived views
   "agree by construction"; extend that contract rather than adding a second scanner that can drift from
   `renameIdentifier`.

   Kind assignment follows the existing branches one-for-one:
   - `:89` whitespace → `Whitespace`; `:92-96` line/block comment → `Comment`; `:103` char literal →
     `CharLiteral`; `:130` number → `Number`.
   - `:117-128` identifier → `Keyword` when in `hardKeywords:35-38`, `Member` when `afterMemberSelector`,
     else `Identifier`.
   - `:108-115` back-ticked → `Identifier`, keeping today's span (back-ticks **included**) and content
     (back-ticks **excluded**) — `IdentifierReference` semantics must not shift.
   - `:140-158` `..` / `.` / `::` / catch-all → `Operator`.

3. **String templates keep contiguity by chunking.** A `StringLiteral` token runs up to and including the
   `$` (`:199`) or `${` (`:193`), then the interpolated code's own tokens are emitted, then `StringLiteral`
   resumes. This is exactly what keeps template-interior identifier references derivable from the token
   list — a single `StringLiteral` spanning the whole literal would break the derivation in step 2.

4. **Behaviour of `referencedIdentifiers:42-44` and `renameIdentifier:52-67` must not change.** They are
   load-bearing for rename refactoring (`KzenAutoCodeReferenceRewriter`) and the dependency gutter
   (`ScriptDependencyAnalysis:121-131`).

5. `kzen-auto-common/src/commonTest/…/util/KotlinExpressionAnalyzerTest.kt` (18 tests today, CC-13) —
   **all existing assertions must pass untouched**; add:
   - a property assertion over every existing fixture string: tokens are ascending, non-empty, and cover
     exactly `0 until code.length` (contiguity is what the renderer relies on);
   - `identifierReferences(code)` equals the `Identifier`-kind tokens' spans, for the same fixtures;
   - kind spot-checks for the constructs the existing tests already cover by name — nested block comment,
     raw-string template, back-tick, `1..Count` range (`:26-59`), safe call / callable reference,
     hard keyword, `0xFF`.

### A.2 The `KotlinCodeArea` component

6. **New** `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/common/edit/KotlinCodeArea.kt`
   — presentational only, no store coupling. `YamlEditor.kt` in the same package is the in-tree precedent
   for a hand-rolled editing surface; `RPureComponent` per house style.

```kotlin
external interface KotlinCodeAreaProps: Props {
    var value: String
    var onChange: (String) -> Unit
    var onBlur: (() -> Unit)?
    var label: String
    var disabled: Boolean
    var textAreaRef: RefObject<HTMLTextAreaElement>

    var errorMessage: String?          // Session B
    var errorRange: IntRange?          // Session B — null while the buffer is ahead of the server
    var knownIdentifiers: Set<String>  // painted as resolved references

    var completions: List<CodeCompletion>                              // Session C
    var onReplaceRange: ((Int, Int, String) -> Unit)?                  // Session C
}

data class CodeCompletion(val insertText: String, val label: String, val detail: String?)
```

```
div (position: relative)                     ← already exists, KotlinExpressionEditor.kt:382-387
  TextField(multiline, outlined, small, label, error)     ← MUI chrome unchanged
      textarea: monospace, color transparent, caretColor visible
  pre.backdrop  (absolute, pointer-events: none, aria-hidden)   ← the coloured spans
  completion list (absolute + ClickAwayListener)                ← Session C
```

7. **Backdrop alignment is measured, never hardcoded.** In `componentDidUpdate` and from a `ResizeObserver`
   on the textarea, copy `fontFamily / fontSize / lineHeight / letterSpacing / tabSize / whiteSpace /
   wordBreak` off `getComputedStyle(textarea)` and set the backdrop's `left / top / width / height` from
   `offsetLeft / offsetTop / clientWidth / clientHeight`. MUI puts the padding on `.MuiInputBase-root`, not
   on the textarea, so the textarea's own offsets already land the backdrop correctly — and a measured
   contract survives MUI version churn, which a hardcoded padding table would not (see the MUI 9 slotProps
   migration in `client/wrap/React.kt:102-120`). Monospace is set on the textarea via `inputSlotProps`
   (`React.kt:105-111`), and the backdrop copies whatever it resolves to rather than restating it.

8. Three details that otherwise look broken, each cheap:
   - **Selection.** A textarea's selection highlight paints *over* the backdrop, hiding the coloured text.
     Give the textarea a semi-transparent `::selection` background so it shows through.
   - **Trailing newline.** `<pre>` swallows a trailing `\n`; append a sentinel so a final empty line renders
     and the caret does not sit past the painted text.
   - **Scroll.** MUI multiline uses `TextareaAutosize`, so the field grows and normally never scrolls —
     but sync `scrollTop` / `scrollLeft` on `onScroll` anyway (three lines, mirrors `YamlEditor.kt:89-91`);
     it is the difference between "usually fine" and correct.

   Also select the **visible** textarea, not `TextareaAutosize`'s hidden `aria-hidden` shadow sibling —
   `props.textAreaRef` (MUI's `inputRef`) is the visible one, which is why the ref is threaded rather than
   the element queried.

9. Spans come from `KotlinExpressionAnalyzer.tokens(value)`; colours in a private `companion object`
   palette (CC-01), legible on the card's white fill. An `Identifier` whose content is in
   `props.knownIdentifiers` gets the resolved-reference colour (§1.3).

### A.3 Adopt in the Script expression editor

10. `KotlinExpressionEditor.renderTextField:422-443` — replace the bare `TextField` with `KotlinCodeArea`,
    threading `inputRef` → `textAreaRef`, `onChange` → `onChange`, `onBlur = { committer.flush() }`
    unchanged (its comment at `:437-438` states why it must stay), and `error = state.errorMessage != null`
    → `errorMessage`. `state.errorMessage` here is the **notation-write** failure (`:73-74`, set from
    `AttributeCommitter.onError` at `:129`), *not* validation — do not conflate them; validation arrives in
    Session B on separate state fields.
11. `knownIdentifiers` = `state.stepReferences` (`:216-248`, already computed for the Σ popover) mapped
    through `ExpressionUtils.identifierContent(ExpressionUtils.escapeKotlinVariableName(name))` — the
    canonical name↔identifier mapping the analyzer's KDoc (`:16-17`) names.

**Gate A:** `cd ../kzen-auto && ./gradlew build` green.

---

## 5. Session B — error positions end to end

Ends with a caret under the offending token. This session is where the compile stack changes shape, so its
gate is the full build plus the detached-action check in §9.

### B.0 Answer this before writing any of B

**Does the Kotlin scripting compiler populate `ScriptDiagnostic.location` for a *parse* error?** Resolution
errors certainly carry one; parse errors are the case the screenshot shows (`1.. 5x` → "Expecting an
element") and the whole session's value rests on it.

Check it directly and cheaply: boot your own instance (§9), point a Formula step at `1.. 5x`, and log the
diagnostics in `ScriptKotlinCompiler.compile:77` before touching anything else.

- **Populated** → proceed with B.1–B.9 as written.
- **Not populated** → fall back to §1.2: add a `KotlinSyntaxValidator` pre-pass. Accept the `@Service`
  parameter on the six step classes, run it *before* `tryCompile` (it also avoids invoking the slow
  compiler on code that cannot parse, and avoids writing a cache entry per broken intermediate), and keep
  B.2–B.9 unchanged — the transport is the same either way, only the producer differs. **Record which
  branch was taken in §10.**

### B.1 State where the user's code went

1. `kzen-auto-jvm/…/script/step/eval/StepExpressionCompiler.kt:56-116` — assemble the generated source as
   `header + code + footer` from explicit parts instead of one interpolated template (`:79-112`), for both
   the `probe` and forced-return forms, so the region is **computed, not searched**. `indexOf(code)` would
   be wrong for empty code and for code that also appears in an accessor name.
2. `kzen-auto-jvm/…/service/compile/KotlinCode.kt:10-13` — add
   `val userCodeRegion: UserCodeRegion? = null` with a nested `data class UserCodeRegion(val offset: Int, val length: Int)`
   (offset **and** length: §3's "drop, don't clamp" rule needs both bounds). Default `null` keeps every
   other construction site — `CalculatedColumnEval`, `TypeAssignability` — compiling untouched.
   `signature():19-23` digests `sourceText` only, so **the cache key does not move**.

### B.2 Stop discarding the location

3. `kzen-auto-jvm/…/service/compile/KotlinCompilerResult.kt:9` —
   `data class KotlinCompilerError(val error: String, val userCodeOffset: Int? = null)`.
4. `kzen-auto-jvm/…/service/compile/ScriptKotlinCompiler.kt:36-46` — replace `formatError` with a selector
   taking `kotlinCode`: map each ERROR diagnostic's `location.start` `(line, col)` to an absolute offset in
   `sourceText`, subtract `userCodeRegion.offset`, keep it only if it lands within `0..length`. Report the
   **first** diagnostic with an in-region position; fall back to today's `errors.last()` with no offset when
   none maps. Rendering stays `withLocation = false` — the position now travels structurally, and putting
   generated-source coordinates in user-facing prose would be worse than none.

   ⚠ **Intentional behaviour change:** which of several errors is shown can differ (first-with-position
   instead of unconditionally last). An inline caret must point at the earliest real problem, not at a
   cascade artefact. Call it out in the commit message and re-run the §9 sweep to see how many documents
   change message.

### B.3 The durable cache must round-trip it

5. `kzen-auto-jvm/…/service/compile/CachedKotlinCompiler.kt:91-109, 245-275` — `err.txt` gains an optional
   **first line** `#kzen-offset:<n>` (named `const` beside `errorFile`, CC-01), written only when a position
   exists. `readErrorFile` strips a recognised header and otherwise decodes `null`, so **every existing
   on-disk cache entry keeps working** — this is a user work directory (`work/code-cache/`), not a build
   artefact, and invalidating it would silently recompile the world.

   A header line rather than a suffix or a sidecar file because compiler messages are themselves
   multi-line; only the first line is safely reserved.

6. `tryCompile:197-242` returns `KotlinCompilerError?` instead of `String?`. The interrupt guard at
   `:264-272` (do not persist a cancellation-poisoned error) is unchanged and must stay.

### B.4 Call sites (10, all kzen-auto-jvm)

7. Forward the offset — these own the expression attribute, so the error is theirs:
   `FormulaStep.kt:64`, `ResultStep.kt:88`, `BindStep.kt:65`, `DisposeAtSettleStep.kt:57`,
   `DoWhileStep.kt:124`, `ForEachItemsExpression.kt:98`.
8. Use `.error` only, no offset: `StepExpressionSupport.kt:141-144` (a `check` message),
   `CalculatedColumnEval.kt:59-60` and `:104-106` (report path, out of scope — `cleanupErrorMessage` at
   `:75-80` is untouched), `IfStep.kt:187-191` (cross-object attribution, §8).
9. Unaffected: `TypeAssignability.kt:46` (`== null`), and `CachedKotlinCompilerStorageTest`'s
   `assertNull` calls at `:104, 116, 132, 145, 150, 171-176`.

### B.5 Through the validator to the wire

10. `kzen-auto-jvm/…/script/api/ScriptStepDefinition.kt` — add `val errorOffset: Int? = null`;
    `ForEachItemsExpression.Attempt.Invalid` gains the same and `ForEachStep` forwards it.
11. `kzen-auto-jvm/…/script/ScriptValidator.kt` — `validationIteration` passes
    `valueDefinition.errorOffset` into `StepValidation`. The later context-finding and result-finding
    merges only **append** text to `errorMessage` (`existing.copy(errorMessage = listOfNotNull(…).joinToString(" "))`),
    so the compile error stays first in the joined string and the offset stays valid. Preserve it through
    both `copy` calls — a `copy` that omits it keeps it, which is the desired default, but the
    `?: StepValidation(null, null)` fresh-entry branches must not invent one.
12. `kzen-auto-common/…/objects/document/logic/StepValidation.kt` — add `val errorOffset: Int? = null`,
    a fourth key, encoded via `ExecutionValue.of(errorOffset)` (an `Int` becomes `NumberExecutionValue`,
    `ExecutionValue.ofArbitrary`) and decoded **leniently** — absent → null — exactly as `warningMessage`
    already does (`:66-78`, and its comment states why: a payload written by a peer that predates the field
    must still decode). Decode as `(value as? NumberExecutionValue)?.value?.toInt()`.
13. Tests: extend `CachedKotlinCompilerStorageTest` for the `err.txt` round-trip — offset present, offset
    absent, and a **legacy file with no header**. Add a `StepValidation` encode/decode round-trip test
    beside the existing commonTest coverage if one exists, including the absent-key case.

### B.6 Render it inline

14. `KotlinExpressionEditor.onScriptState:216-248` — additionally read
    `scriptState.validationState.scriptValidation?.stepValidations?.get(props.objectLocation.objectPath)`
    into new state fields (`validationError`, `validationErrorOffset`). This is the identical lookup
    `ScriptStepDisplayBase.onScriptState:134-139` already performs; the editor is already a
    `ScriptStore.Observer`, so no new subscription is needed.
15. **Staleness rule — the load-bearing one.** Pass `errorRange` down **only when
    `state.value == state.serverValue`**, i.e. the buffer matches the notation the server validated.
    Mid-edit the message still shows but the caret is withheld: an offset computed against different text
    points at the wrong token, which is worse than pointing at nothing. `ExpressionValidationIndicator`
    (overlaid at `:393-405`) already covers the transient with its "validating…" pulse.
16. The marked span is `errorOffset` extended to the end of the token containing it
    (`KotlinExpressionAnalyzer.tokens`, Session A), falling back to a single character, and to a
    zero-width marker at end-of-text. Rendered in the backdrop as a wavy red underline with
    `textDecorationSkipInk: none`.
17. The message renders under the field **inside `KotlinCodeArea`**, `white-space: pre-wrap` in monospace
    — today's bare `div` (`ScriptStepDisplayDefault.kt:632-634`) collapses the newlines that compiler
    messages already contain. `FormulaItemController.kt:195-201` already uses a `pre` for exactly this
    reason; match it.
18. `ScriptStepDisplayDefault.renderValidation:620-636` — suppress the card-level line when the expanded
    body's editor is showing it, extending the existing `hasFieldDefinitionError` precedent at `:623-625`
    (same rationale: the field is saying the same thing, more specifically). Key it on the step having a
    `KotlinExpressionEditor` attribute; a collapsed card keeps today's behaviour, since no editor is
    mounted to show anything.

    Each expression-owning object has **exactly one** such attribute — verified across
    `notation/auto-jvm/script/script-jvm.yaml`: `FormulaStep.code:105`, `ResultStep.code:124`,
    `IfBranch.condition:262`, `ForEachStep.items:288`, `DoWhileStep.condition:321`, `BindStep.value:388`,
    `DisposeAtSettleStep.code:477` — so a step-level error attributes to a field unambiguously.

**Gate B:** `cd ../kzen-auto && ./gradlew build` green, plus the §9 detached-action check showing the
offset key on the wire.

---

## 6. Session C — auto-complete, docs, smoke

### C.1 Generalize the existing insertion path

1. `KotlinExpressionEditor.insertReference:329-361` → `replaceRange(start: Int, endExclusive: Int, text: String)`.
   The splice, the `committer.cancel()` + `commitNow(ScalarAttributeNotation(newValue))` immediate write
   (its comment at `:343-345` explains why an insertion must not wait out the keystroke debounce), and the
   `delay(1)` focus + `setSelectionRange` restore are **exactly** what a completion accept needs.
   `insertReference(stepLocation)` becomes `replaceRange(caret, caret, escaped)`. This is reuse, not new
   machinery — and it keeps the two insertion paths from drifting.

### C.2 The completion list

2. In `KotlinCodeArea`, compute the identifier prefix ending at the caret **from the token list**: open
   only when the token under the caret is `Identifier` (never `Member`, so `foo.` offers nothing) and ends
   exactly at the caret. `Ctrl+Space` forces it open with an empty prefix. Recompute on change and on
   caret movement (`onKeyUp`, `onClick`, `onSelect`).
3. **Position at the caret using the backdrop as the mirror**: render a zero-width `<span ref>` at the
   caret index in the backdrop and read its `offsetLeft / offsetTop / offsetHeight`. The measurement
   surface already exists with identical metrics **by construction** — no separate mirror div, no
   dependency, and it cannot drift from what the user sees. If the ref is unavailable, fall back to
   anchoring below the field.
4. Render an absolutely positioned list inside the same relative container, wrapped in `ClickAwayListener`
   with `mouseEvent = ClickAwayListenerMouseEvent.onMouseDown` — copy the pattern **and its rationale**
   from `StepReferenceController.renderPopover:100-140` (`:104-114` documents why `mousedown` rather than
   `click`; the same layout-shift-on-blur hazard applies here). Import `ClickAwayListener` from
   `client/wrap/material/clickAwayListener.kt`, not from `mui.material` — that wrapper exists because the
   generated binding is `undefined` at runtime.
5. **The list must not take focus.** Plain non-focusable rows, keyboard driven entirely from the textarea —
   a `MenuList`/`MenuItem` that steals focus would stop the user typing mid-completion and would fight the
   caret restore in C.1. `Paper` for elevation is fine.
6. Keys on the textarea's `onKeyDown`, **only while open** (the textarea must otherwise behave normally —
   Enter inserts a newline, Tab moves focus): Arrow Up/Down move the selection, Enter/Tab accept, Escape
   closes; `preventDefault` on those four.
7. Accept → `props.onReplaceRange(prefixStart, caret, insertText)` → C.1.

### C.3 Wire the Script editor's completion source

8. `KotlinExpressionEditor` — `completions` from `state.stepReferences` (`:216-248`), mapped to
   `insertText = ExpressionUtils.escapeKotlinVariableName(name)`, `label = name`,
   `detail = typeMetadata?.toSimple()` read from the `stepValidations` map Session B already put in state.
   Same source as the Σ "Insert step reference" popover (`:408-417`), so the two can never disagree about
   what is in scope — including the `scope: body` special case at `:225-239` for `DoWhileStep.condition`.

### C.4 Docs

9. `kzen-auto/docs/js-architecture.md` — a `KotlinCodeArea` section: the transparent-textarea overlay
   technique, the **measured** alignment contract (A.2 step 7) and why it is measured, the three gotchas
   (selection / trailing newline / scroll), and the backdrop's double duty as the caret-position mirror.
10. `kzen-auto/docs/architecture.md` — the expression-validation area (~`:165-184`): a validation error now
    carries a user-code offset end to end; note the §3 drop-don't-clamp rule and the `IfBranch` gap (§8).
11. `kzen-auto-common`'s `KotlinExpressionAnalyzer` KDoc (`:4-21`) — it currently describes itself as
    serving two consumers; add the third (highlighting) and restate the one-scan contract.

### C.5 Smoke (this session's real deliverable)

Manual, in a browser, against **your own** instance on a spare port (§9). JVM tests cannot catch a client
graph or rendering fault — `kzen-auto/AGENTS.md` § *Headless verification* is explicit that the client
graph is built in browser JS.

| Check | Expected |
|---|---|
| Formula step, `1.. 5x` | wavy underline at the offending token; message under the field; **nothing** on the card |
| Reference a real prior step | painted as a resolved reference |
| Reference a name that does not exist | caret from the **compile** error — proves B covers more than parse errors |
| Type a prefix of an in-scope step name | caret-anchored list; Enter inserts the escaped name; typing continues without re-clicking |
| `foo.` then a prefix | no list (member position) |
| Edit after an error | caret withheld, message still visible, "validating…" pulse, caret returns on settle |
| Multi-line expression, long lines | backdrop stays aligned; selection readable |
| Σ insert-step-reference button | unchanged (it shares `replaceRange` now) |
| Collapse/expand the card | error returns to the card when collapsed, no duplication when expanded |

**Gate C:** `cd ../kzen-auto && ./gradlew build` green + the table above.

---

## 7. Dependencies & coordination

- **Seam with the Report/Job formula editors.** `FormulaItemController`, `FormulaMapRow` and
  `MultiTextAttributeEditor` are untouched, but `CalculatedColumnEval` shares `CachedKotlinCompiler` — B.4
  step 8 is the whole of that contact, and `cleanupErrorMessage:75-80` (string surgery on the compiler
  message) must keep working against messages whose *selection* may now differ (B.2's first-vs-last change).
  Re-run the report formula tests, not just the script ones.
- **Seam with rename refactoring.** A.1 rewrites the scanner that `KzenAutoCodeReferenceRewriter` and
  `ScriptDependencyAnalysis:121-131` depend on. The existing 18 tests are the guard; they must pass
  unmodified, not be "updated to match".
- **Seam with the plugin SPI.** Nothing in B.4 changes a step's constructor — unless B.0 takes the fallback
  branch, which does. That is the fallback's real cost and why it is the fallback.
- **kzen-lib**: none. `ExecutionValue` is used as-is.
- Not affected by, and does not affect, any open ledger row.

---

## 8. Known frictions (accepted)

- **`IfBranch.condition` gets no inline caret.** `IfStep.definition:186-191` compiles its *branches'*
  conditions and reports `"Branch N: …"` against **itself**; the branch is a separate object with its own
  editor. Re-attributing an error across objects fights the validator's fixpoint
  (`validationIteration` writes `builder[objectPath]`, one entry per step). `IfStep` passes no offset and
  its behaviour is unchanged — highlighting and completion still work in that field, only the caret is
  absent. Reopening it means an `errorObjectPath` on `ScriptStepDefinition` and a fixpoint that can write
  a neighbour's entry; deliberately not attempted here.
- **A joined error shows one caret.** When a compile error is joined with a context or result finding
  (`ScriptValidator`), the full joined string renders and the caret points at the expression. The caret is
  right about the part it describes; the rest of the message has no position by nature.
- **Only the first error gets a caret.** Multiple diagnostics are not surfaced as multiple markers — one
  message, one caret, matching what the validator already transports (one `errorMessage` per step).
- **No member completion after `.`**, and no completion of Kotlin keywords or library functions. §2.
- **The backdrop is a second render of the text.** Every keystroke re-lexes and re-renders spans. Fine at
  expression scale (tens to hundreds of characters); it would not be at file scale, which is why this
  component is deliberately not offered as a general-purpose editor.

---

## 9. Verification

Run from `../kzen-auto` — **never `./gradlew build` from the umbrella**, it abbreviation-matches
`buildEnvironment` and exits 0 having compiled nothing.

```powershell
cd ../kzen-auto
./gradlew :kzen-auto-common:jvmTest --tests "*KotlinExpressionAnalyzerTest"   # Session A
./gradlew :kzen-auto-common:jsTest                                            # the lexer runs in the browser too
./gradlew :kzen-auto-js:compileKotlinJs                                       # fast client gate (A, B, C)
./gradlew :kzen-auto-jvm:test --tests "*CachedKotlinCompilerStorage*"         # Session B cache round-trip
./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest"                      # standing type-inference canary
./gradlew build                                                               # each session's gate
```

**Server-side position check, no UI** — boot your **own** instance on a spare port. The user's dev servers
are usually on `127.0.0.1:8080` (`BackendDevelopment`) and often `18081`; never kill or reuse them, and
before stopping any JVM verify its command line carries the `--server.port=` you chose
(`kzen-auto/AGENTS.md` § *Headless verification* has the throwaway-init-script classpath recipe).

```bash
curl -s -G http://127.0.0.1:8099/action/detached \
  --data-urlencode "path=auto-jvm/script/script-jvm.yaml" \
  --data-urlencode "object=ScriptValidator" \
  --data-urlencode "host=main/<a script with a broken Formula>.yaml"
```

The response's `StepValidation` map must carry the new offset key. Looping over `main/*.yaml` and diffing
error counts and messages against a pre-change baseline is the cheap regression sweep for B.2's
first-vs-last change — capture the baseline **before** starting Session B.

Client smoke: §6 C.5.

Review the finished change against `kzen/docs/CODING_STANDARDS.md` — CC-01 (colour and header constants),
CC-02 (comments say *why*), CC-04 (`UserCodeRegion` keeps offset and length together), CC-13 (test
colocation), CC-15 (one file per class).

---

## 10. As-built

*(Fill on landing: deviations per session; what the §9 message-diff sweep showed for B.2; what C.5's smoke
caught that the build did not. Then tick ledger row 47 and archive this file — standalone, do not delete.)*

### 10.1 Gate B.0 — answered 2026-08-06, **before** any of Session B was written

**Verdict: `POPULATED`.** The K2 scripting compiler carries `ScriptDiagnostic.location` for parse errors,
unresolved references and type mismatches alike, so **B.1–B.9 proceed as written and the §1.2
`KotlinSyntaxValidator` pre-pass fallback is not taken** — the six step classes keep their constructors and
no plugin-SPI surface moves.

Measured by replicating `ScriptKotlinCompiler`'s pipeline verbatim in a throwaway JVM test
(`StepExpressionCompiler.generateInferenceCode` → `ScriptJvmCompilerIsolated.compile` → inspect
`ResultWithDiagnostics.reports`), since `compile()` itself already collapses diagnostics to a string. Kotlin
2.4.0, K2 frontend. Five findings the implementation depends on:

- **`line` and `col` are both 1-based**, over `sourceText` exactly as passed to `toScriptSource()` — no
  implicit prologue. `offset = lineStartOffset(line - 1) + (col - 1)`. `location.end` is **exclusive**.
- **`Position.absolutePos` is always `null`.** There is no shortcut; B.2 must carry its own line-start index
  over `sourceText`.
- **A diagnostic can legitimately land outside the user's region.** `noSuchThing + 1` emits *two* errors: a
  "Cannot infer type for type parameter 'R'" on the generated wrapper line (`val probe = { run {`) *before*
  the real "Unresolved reference" on the user's line. This is exactly §3's drop-don't-clamp case, and it is
  also the concrete argument for B.2's first-with-position selection over today's `errors.last()`.
- **Parse errors point one-past-end-of-line** — `1.. 5x` reports col 7 of a 6-char line, i.e. the `\n`. So
  the in-region test must be inclusive at the top (`0..length`), which is what §3 and B.6 step 16's
  zero-width end-of-text marker already assume.
- **`sourcePath` is the constant `"__.kts"`** for every generated expression (from
  `KotlinCode.scriptClassName = "__"`) and is *not* a discriminator; `code` is `-1` on every diagnostic.
  Severity remains the only filter, and it already excludes the 3 unconditional DEBUG reports per compile.

### 10.2 Session A — as built

Landed as specified. `identifierReferences` is now **derived** from `tokens()`, and a differential fuzz
(exhaustive to length 4 over 17 hostile symbols, plus 400k random strings ≤ 30 chars) found **zero**
divergences from the pre-change implementation — so `renameIdentifier` and `referencedIdentifiers`, and with
them rename refactoring and the dependency gutter, are provably untouched. The contiguity contract was fuzzed
the same way (~600k exhaustive + 400k random): no gaps, overlaps, empty or out-of-order tokens. All 17
original test methods are byte-identical; 10 tests added, 27 green on both jvm and js.

Three deviations, each forced by the "must not shift `IdentifierReference` semantics" clause outranking the
plan's literal kind table:

- **A back-tick after a member selector emits `Member`, not `Identifier`.** Today `` a.`b` `` produces no
  `IdentifierReference`; tagging it `Identifier` would have injected a new reference through the derivation
  and changed `renameIdentifier`.
- **An unterminated `${` leaves no trailing literal chunk** — `"${x` runs the interior scan to end of input,
  so the final flush would emit a zero-width `StringLiteral` and violate coverage. Guarded, with a fixture.
- **The defensive `results.sortBy { it.start }` is gone.** Ascending order is now a documented hard contract
  asserted by a property test, so the sort was provably dead.

Whitespace also became a maximal run rather than one token per character, so a multi-line expression's
indentation is one span instead of dozens.

`KotlinCodeArea` deviated from the plan's diagram in one load-bearing way: **the backdrop is rendered
*before* the `TextField`, not after.** After would paint it over the caret. It also sets the transparent
text via `sx { "& .MuiInputBase-input" { … } }` rather than `inputSlotProps` (`slotProps.input` is the
InputBase, not the native element), and must additionally zero `-webkit-text-fill-color` — MUI fills a
*disabled* input through that property, which overrides `color` and would print a second grey copy of the
text over the backdrop. Scroll sync uses the native `onscroll` handler because React's `onScroll` does not
bubble and the native textarea's React props are unreachable without a `slotProps.htmlInput` wrapper.

### 10.3 Session B — as built

Landed as specified; **no step constructor changed and no plugin-SPI surface moved**. `StepExpressionCompiler`
generates **byte-identical** source to before (verified by reassembling both the old template and the new
`header + code + footer` for both the probe and forced-return forms, incl. empty and multi-line code), so the
region is `header.length` rather than a search — and the durable cache key not only did not move, every
existing `work/code-cache/` entry still *hits*. Confirmed empirically: a full suite run created zero new
signature directories.

**The §9 message-diff sweep: zero documents change message.** The plan's method (boot a pre-change server for
a baseline) was unnecessary — both selections are computable from the *same* diagnostics list in one compile,
so a throwaway harness swept the live `GraphNotation` (332 expression attributes across 109 documents; 322
compilation units; 314 clean, 8 errored) and reported both. In every real multi-diagnostic case the K2 cascade
artefact (`Cannot infer type for type parameter 'R'`, on the generated `val probe = { run {` line) comes
**first and out of region** while the real error comes **last and in region**, so first-in-region and
`errors.last()` coincide by construction. Divergence needs two or more diagnostics inside the *user's own*
text, which nothing in the corpus produces. A synthetic control confirms the rule is live rather than inert:
`noSuchA + noSuchB` selected `'noSuchB'` before and selects `'noSuchA'` now.

The only bundled document that errors at all is the user's live WIP `main/Script.yaml` (`' 1.. 5x'` — the
plan's own screenshot case). Everything else erroring is a deliberately-broken test fixture.

**The `CalculatedColumnEval` seam (§7) is structurally safe, not merely tested.** That path builds
`KotlinCode(mainClassName, code)` with `userCodeRegion` defaulting to **null**, and `selectError` guards on
non-null before doing anything new — so the Report/Job selection is byte-for-byte the pre-change behaviour and
`err.txt` gains no header there either. Only `StepExpressionCompiler` ever sets a region. Noted in passing:
`cleanupErrorMessage` is **vestigial** — `render(withLocation = false)` emits only the message text, and none
of its three probe substrings occurs in any real message; it is an identity function today.

Two client-side deviations in B.6, both defects the plan's text would have shipped:

- **The plan's own headline case rendered no marker.** `1.. 5x` yields `errorOffset == code.length`, and tokens
  cover exactly `0 until code.length` — so the offending index belongs to *no* token and the span splitter
  emitted nothing. An explicit end-of-text marker was added. Correspondingly, **step 16's "falling back to a
  single character" is unreachable**: the only in-range offset with no containing token *is* `code.length`, so
  that fallback and the end-of-text case are one branch.
- **Step 15's staleness rule is necessary but not sufficient.** `ScriptValidationStore.refresh` sets
  `loaded = false` but never clears `scriptValidation`, and `ScriptStore.onClientState` publishes the new
  notation — so `serverValue` catches up — *before* the refresh returns. For a whole server round trip
  `value == serverValue` while the offset still describes the previous text. The marker is additionally gated
  on `validationState.loaded`.

Also corrected: **step 18 over-scopes.** Only 4 of the 7 expression attributes route through
`ScriptStepDisplayDefault.renderValidation` (`FormulaStep`, `ResultStep`, `BindStep`, `DisposeAtSettleStep`);
`DoWhileStep`, `ForEachStep` and `IfStep`/`IfBranch` have their own displays that never call it, so the
card-level suppression is inert there. Detection is by attribute-metadata inspection
(`AttributeWrapperLookup.wrapperName(…, editorAttributePath) == ObjectName("KotlinExpressionEditor")`), not a
hardcoded step list, so a plugin step declaring the same editor is covered with no edit.

Finally, A.3's threading of `state.errorMessage` into `KotlinCodeArea.errorMessage` **conflated two different
errors** — that state field is the *notation-write* failure, whose message the global banner already carries,
and printing it under the field made it indistinguishable from a compile diagnostic. Split: `errorMessage` is
the validation message and is the only one printed; a new `invalid: Boolean` carries the write failure and
drives the outline only, matching the peer `TextAttributeEditor`.

### 10.4 Session C — as built

C.1's reuse worked exactly as §6 predicted: `insertReference` is now three lines delegating to
`replaceRange(start, endExclusive, text)`, so the Σ button and a completion accept share one splice, one
immediate `commitNow` and one caret restore, and cannot drift.

**§6 C.3's premise was false.** It says `detail` comes from "the `stepValidations` map Session B already put
in state" — Session B stored only *this* step's `validationError` / `validationErrorOffset` /
`validationLoaded`, never the map. The derivation was added; state grew by one field, and `detail` is real
(`stepValidations[path].typeMetadata.toSimple()`, dropping `Unit` to match `StepHeader`'s type-chip rule)
rather than invented.

Three refinements where a literal reading of §6 would have shipped something worse:

- **The completion list opens on a `Keyword` token too**, not only `Identifier`. A hard keyword is a
  legitimate *prefix* of a step name, so gating on `Identifier` alone makes the list flicker away at the `in`
  of `index`.
- **`Ctrl+Space` refuses in member position** rather than forcing an empty prefix unconditionally. The literal
  rule would offer step names at `foo.`, which §2 rules out. Member position is detected by walking the token
  list back over whitespace and comments to a `.` or `::`, mirroring the lexer's own `afterMemberSelector`, so
  `1..` (a range) still opens.
- **The caret anchor uses `getBoundingClientRect()` deltas, not `offsetLeft`/`offsetTop`.** `offsetTop` is
  measured inside the *scrolled* backdrop content and would drift by `scrollTop`.

The end-of-text gap from §10.3 **bit a second time**: the caret anchor span, like the error marker, needs an
explicit branch because a caret at `value.length` belongs to no token. Two independent features tripped on the
same contract edge — it is called out in `js-architecture.md` for that reason.

One hazard the plan did not foresee: **`Ctrl+Space`'s own keyup would immediately close the list**, because the
forced prefix is not one the caret rule reproduces. An instance flag set by any keydown the component acted on,
and cleared by its keyup, closes that hole.

`completions` was declared non-null in Session A but is `undefined` at runtime until a parent sets it (an
`external interface` has no defaults), so it was changed to `List<CodeCompletion>?` — matching
`onReplaceRange`'s nullability, since the two are one opt-in seam.

### 10.5 C.5 smoke — run 2026-08-06, all rows pass

Run against a **throwaway project** (a scratch copy with its own `main/Smoke.yaml`), not the repo's notation
— typing in the Code field writes to notation, and the repo tree holds the user's uncommitted WIP. Own
instance on **8097**; 8080/18081 were idle and **8099 was occupied by an unrelated user `node` process**
(`tools/serve.js`), left alone. Verified by DOM inspection rather than by eye, so each row below is a
measurement.

| Check | Result |
|---|---|
| Formula `1.. 5x` | marker wavy `rgb(211,47,47)` with `skip-ink: none` (**wavy superseded by §10.7 — the marker is now solid**), at the end-of-text glyph immediately after `5x`; message in a `<pre>` under the field; **exactly one** occurrence of the message in the DOM — nothing on the card |
| Real prior step referenced | `Count` painted `rgb(0, 98, 122)` — the resolved-reference colour |
| Name that does not exist | `Cou` → `Unresolved reference 'Cou'.` with the marker on **exactly** the `Cou` span — B covers more than parse errors |
| Prefix of an in-scope name | list opened at the caret showing `Count` + its `Int` detail; Enter inserted it; typing continued into `Count + 1` with no re-click |
| `foo.` then a prefix | no list — and `Ctrl+Space` also refuses in member position |
| Edit after an error | immediately after the keystroke: `decorated: []` with the **old** message still shown; after settle: marker on `Coux` and the message updated. The staleness rule behaves exactly as designed |
| Multi-line / long lines | wrapped to 2 lines; backdrop vs textarea `deltaLeft/deltaTop/deltaWidth/deltaHeight` all **0**, `scrollHeight` equal; list anchored on the second line |
| Σ insert-step-reference | offers the same in-scope set as completion; `1 + ` → `1 + Count`, caret restored to 9, textarea refocused |
| Collapse / expand | no duplication expanded; see the correction below |

Also confirmed: the `::selection` rule resolves to `rgba(51, 144, 255, 0.3)`, the textarea's `color` **and**
`-webkit-text-fill-color` are both fully transparent with `caretColor` at `rgba(0,0,0,0.87)`, the backdrop is
`aria-hidden` with `pointer-events: none` and byte-identical `font`/`line-height` to the textarea, and the
console is free of errors and exceptions.

**The plan's collapse/expand row asserts a baseline that never existed.** It expects the error to "return to
the card when collapsed" — a collapsed card renders **no** validation message text, and never did:
`git show HEAD:…/ScriptStepDisplayDefault.kt` has `renderValidation()` called only inside `if
(state.expanded)`. A collapsed card surfaces the error through the header badge, the red status border and
the document's "1 error" chip, all of which still work. Nothing regressed; the row's *expectation* was wrong.

### 10.6 Out-of-plan defect fixed on user request — the non-ASCII digit hang

Found by the adversarial review as a **pre-existing** hang (identical at `HEAD`), reported under CC-07 as
surfaced-not-acted, then **fixed on the user's explicit instruction** after the three sessions landed.

`scanCode` tested for a numeric literal with Kotlin's `Char.isDigit()`, which is **Unicode-aware** and accepts
every Nd-category digit — Arabic-Indic `١`, Devanagari `१`, fullwidth `１`. `skipNumber` then advances only
while `isIdentifierPart`, which is **ASCII-only**. So such a character entered the number branch, consumed
nothing, emitted a zero-width token and left the cursor where it was: an infinite loop. Pasting one character
into the Code field would hang the browser tab, because the editor re-lexes on every keystroke — and it also
violated Session A's own non-empty-token contract.

Fixed at the root rather than guarded: one private ASCII `isDigit` is now the lexer's single notion of a
digit, with `isIdentifierPart` defined in terms of it, so the two predicates cannot disagree again. A
non-ASCII digit falls through to the catch-all branch, which always advances one character — it lexes as an
unrecognized character, which is honest (Kotlin's own number literals are ASCII, and this lexer's identifier
model always was).

`isWhitespace()` was audited as the only other Unicode-aware predicate and is **safe** — it consumes `code[i]`
unconditionally, so it always advances, and Unicode-aware is the correct semantic there (a non-breaking space
really is whitespace).

Pinned by four new fixtures in the shared `codeFixtures` list — which means the existing contiguity,
non-empty and coverage property assertions now cover them — plus a focused test asserting a non-ASCII digit
lexes as `Operator`, terminates an ASCII number rather than stalling on it, and terminates an identifier
rather than extending it. 28 tests green on **both** jvm and js; the js run is the load-bearing one, since it
executes the very code path in a real browser. Note the blunt failure mode this class of bug has: before the
fix, adding those fixtures would have hung the test run rather than failing it.

Confirmed in the **running editor** as well, on a green full build, by driving React's real `onChange` (native
value setter + dispatched `input`, i.e. what a paste does) with `١`, `１２３`, `Count + ١`, `1١`, `a१` and
`٠x٥`. Every one returned in **0–60 ms** — the pre-fix behaviour was a non-terminating loop — the painted
backdrop reproduced the input verbatim in each case (so the contiguity contract holds with these characters
present), `Count` still lexed as a resolved reference beside them, and the console stayed free of errors.

Two environment notes for whoever runs this next: the `computer` tool's `zoom` action left a CDP
device-metrics override applied when it timed out (viewport collapsed to 551×71 at DPR 2) and the only
recovery was a fresh tab — prefer DOM inspection over `zoom`. `Page.captureScreenshot` also timed out
intermittently while the renderer was demonstrably alive (JS evaluated instantly); do not read a screenshot
timeout as a page freeze.

### 10.7 User feedback on the shipped field — the marker had an impostor

Reported 2026-08-06 from the user's own instance, with a screenshot of `listOf(1, 2, 2, 4, 5) + listOf(1)` —
a **valid** expression — showing a red wavy underline under each `listOf`. Three questions in one: why is
that red, can spellcheck be turned off, and can the marker be solid because it "looks like a spelling error".

They are one finding. **The textarea's glyphs are transparent, but the spelling squiggle the browser draws
under them is not** — `color` / `-webkit-text-fill-color` suppress text rendering, not decorations the UA
paints on the element. So Chrome was spell-checking code and underlining every identifier absent from its
dictionary (`listOf`, and most step names) in red wavy — *the same colour and style as this component's error
marker*, on a field with no error at all. Neither the §10.5 smoke nor any test could catch it: a UA spelling
decoration has no DOM presence and no computed style, and every smoke row was measured through the DOM.

Both halves fixed:

- **`spellcheck="false"` on the textarea**, through a new `htmlInputSlotProps` bridge in `wrap/React.kt`.
  MUI 9 removed the legacy `inputProps`, and `slotProps.input` is the `InputBase`, not the element — the
  element is the **`htmlInput`** slot, one level further down. (MUI's `TextareaAutosize` renders a *second*,
  shadow textarea for measurement, which does not get the attribute; it is `aria-hidden`, `readonly` and
  `visibility: hidden`, so it paints no squiggle.)
- **Marker is now solid**, 2px thick, `text-underline-offset: 2px`, keeping `skip-ink: none`. Wavy was the
  wrong signifier independent of the impostor: a red wave *is* the platform's misspelling convention, so it
  reads as "not in the dictionary" rather than "the compiler rejected this". The offset clears the descenders
  the continuous rule runs through. `textDecorationThickness` / `textUnderlineOffset` both take a plain
  `2.px` — `Length` reaches them via `LengthProperty`, so no `unsafeCast` is needed.

Re-verified in the browser on the rebuilt bundle: the Code textarea reports `spellcheck="false"`, the user's
own `listOf(...)` expression renders with **no** decoration anywhere, and both marker cases still land exactly
where they did — `Cou` of `listOf(1, 2) + Count.Cou` and the end-of-text glyph of ` 1.. 5x` — now measuring
`solid / 2px / 2px / rgb(211,47,47) / skip-ink none`.