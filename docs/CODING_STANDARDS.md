# Coding standards

Review every code change against these rules before finalizing.
They capture common failure modes — especially in AI-generated code, where each of these patterns is a recurring offender.

Each rule has an ID (`CC-NN`) so a reviewer can cite "violates CC-04" in a code review or commit.


## CC-01 — Magic constant

**Don't inline unexplained literals. Bind them to a named val that spells out the unit and intent.**

Don't:
```kotlin
delay(500)
```

Do:
```kotlin
val statusRefreshMillis = 500
// ...
delay(statusRefreshMillis)
```

**Why:** A bare `500` forces the reader to guess units (ms? seconds? rows?) and intent (refresh? timeout? backoff?). A named binding makes both obvious at the call site.


## CC-02 — Comments

**Default to no comments. Add one only when the *why* is non-obvious; never restate the *what*.**

Don't restate what the next line does:
```kotlin
// Increment the counter
counter += 1
```

Don't reference the current task, PR, or caller — those notes belong in the commit message and rot in the source tree:
```kotlin
// Added for ticket FOO-123 — handles the new partial-result case from issue #456
```

Do explain non-obvious why:
```kotlin
// MUI 7.3.x packages icons as CommonJS; switching to ESM breaks every icon import.
useCommonJs()
```

**Why:** Well-named identifiers say *what* the code does. A comment adds value only when it captures a hidden constraint, a workaround for a specific bug, a non-trivial invariant, or behaviour that would surprise a reader.


## CC-03 — Scalability of code

**Each new feature or extensibility point should cost one line at the same depth — not a new wrapper layer.**

Don't introduce a new wrapper per concern:
```kotlin
headerWrapper2 {
    headerWrapper1 {
        header(
            headerExtra = {
                button1()
                button2()
            }
        ) {}
    }
}
```

Use a single composition slot instead:
```kotlin
header(
    headerExtra = { headerBuilder: ChildrenBuilder ->
        with (headerBuilder) {
            button1()
            button2()
//          button3() — adding a button is one line at the same depth
        }
    }
) {}
```

**Why:** Every new header concern (a side panel, a badge, an extra menu) in the bad pattern adds a `headerWrapperN` layer that has to re-thread the outer slots through. Indentation depth and signature surface grow per addition, so the per-feature cost is more than one line. The amount, nesting, and complexity of code should be linear with the amount of functionality.


## CC-04 — Coherence of related concepts

**A feature should be removable in one delete (one file or one package tree).**

Code should either be general, or belong to a single particular feature — never both.
If a screen has 4 sections, the screen itself just delegates to the four subsections; it doesn't carry feature-specific branches.
A little supporting code in other places is acceptable, but the removability test ("what would it take to delete this feature?") is the target.

**Why:** When general code paths carry feature-specific special cases, deleting the feature becomes a cross-tree archaeology project, and the general code becomes the place where every feature's quirks pile up.


## CC-05 — Single-purpose code paths

**Every piece of code does one thing. Never overload a generic code path with ad-hoc feature-specific logic, even when it's locally convenient.**

Request handlers parse and dispatch — they never silently rewrite the payload to "help" the caller.
Generic commands and reducers stay generic; feature-specific guards live at the boundary that knows the feature.

**Red flag — generic name + feature-specific literal in the body = overload.**
If the function or endpoint is named generically (`setDocumentObjects`, `applyCommand`, `processRequest`) and the body branches on a specific feature name (`if (type == "CustomDocument") ...`), stop.
Either rename the unit to the feature it actually serves, or move the branch out to the caller that owns that type.

When fixing one instance, re-read the whole function — overloads cluster, and missing the sibling instance is the common failure mode.

**Same shape — generic predicate with a feature-specific clause stitched in.**
Adding "one more `||` clause" to a generic predicate is the same anti-pattern with friendlier-looking syntax.

Don't:
```kotlin
// AutoConventions.kt — generic, document-type-agnostic
fun isManaged(attributeName: AttributeName): Boolean {
    return attributeName == iconAttributeName ||
        attributeName == titleAttributeName ||
        attributeName == ScriptConventions.summaryAttributeName   // ← script-specific in auto-level code
}
```

Do — compose at the layer that owns the concept:
```kotlin
// AutoConventions.kt — stays generic
fun isManaged(attributeName: AttributeName): Boolean {
    return attributeName == iconAttributeName ||
        attributeName == titleAttributeName
}

// ScriptConventions.kt — script layer wraps the generic with its own additions
fun isManaged(attributeName: AttributeName): Boolean {
    return AutoConventions.isManaged(attributeName) ||
        attributeName == summaryAttributeName
}
```

Script-side callers call `ScriptConventions.isManaged(...)`; non-script callers keep calling `AutoConventions.isManaged(...)`. The knowledge *`summary` is managed by scripts* lives next to the definition of `summary`, not at the layer above.

**Extra red flag — upward import.** If the generic side has to `import` the feature side to evaluate its own clause, the dependency direction is also inverted. Composition the other way (feature wraps generic) avoids the cycle and keeps the generic side reusable from any feature.

**Why:** Mixing concerns creates surprise — a caller sends one payload and a different payload reaches the domain layer, so tracing behaviour becomes "read every layer to see what got injected where" instead of "read one function". The predicate variant adds a second hazard: an upward import locks the generic layer to a specific feature, so the generic stops being reusable.


## CC-06 — Files in a package

**Keep packages focused. A few files per package is the target; 10+ is a smell that the package should be split.**

Example layout for a feature broken into related chunks:
```
<feature>/
  Controller.kt
  Header.kt
  model/
    State.kt
    Store.kt
  view/
    View.kt
  raw/
    Raw.kt
```

Packages should typically contain more than one file (a single-file package is anemic), though it's acceptable in particular situations.

**Why:** Browseability and feature locality. A package that has grown past ~10 files has usually accumulated several concerns that want to be sibling packages, not siblings inside one package.


## CC-07 — Drive-by refactoring and cleanup

**Refactorings are opt-in, not opt-out. Surface the find — don't act on it inline.**

Don't delete commented-out code, rename adjacent symbols, or "while I'm here" tidy in the same change.
Maybe the code was there for debugging and will be uncommented soon; maybe the symbol is used by something you haven't read yet.

Surface it as a discussion item or add it to the active plan instead.

**Why:** Adjacent cleanup expands the diff's scope, hides the actual fix from the reviewer, and makes the change harder to revert if the primary fix turns out to be wrong.

**Exception:** When a temporary comment or bad code (to be refactored) was added by an AI agent, it can be freely deleted as part of the scope of work. The "drive-by" nature implies that the refactoring/cleanup is not directly related to the current change set. 


## CC-08 — Fail-fast on unexpected code paths

**Make the code strict — fail early and loudly. Don't handle nulls when null indicates a logic error.**

Don't:
```kotlin
val failsafeInput = requiredInputValue ?: ""
```

Do:
```kotlin
val failsafeInput = requiredInputValue
    ?: error("Required input missing")
```

`requireNotNull(x) { "..." }` and `check(condition) { "..." }` are the assertion-style siblings.

**Why:** A silent fallback turns a logic error into a quiet wrong-result, which surfaces much later and far from the cause. Loud failure at the boundary keeps the bug close to the line that introduced it.


## CC-09 — Stub markers encode intent

**`TODO("...")` and `throw UnsupportedOperationException(...)` mean different things. Don't conflate them.**

- `throw UnsupportedOperationException(...)` = **permanent contract.** This op will never work for this implementation (e.g. `write` / `delete` / `copy` on a read-only `NotationMedia`).
- `TODO("...")` / `NotImplementedError` = **real gap.** The op *could* be implemented; it just isn't yet.

When auditing exception-throwing stubs on an interface implementation, separate by direction: read-side stubs are usually future-work (keep `TODO`); write/mutate stubs on a read-only impl are usually contract (keep `UOE`). Don't roll them up under a generic "exception cleanup" item.

**Why:** Flattening the two loses the "unfinished, not deliberate" signal a future maintainer needs.


## CC-10 — Justify every line

**Every line must answer "why is this here?" with a concrete observable behaviour. Code that produces no outcome different from the default is noise.**

The honest test: if I deleted this line, what would observably change?
If the answer is "nothing the user or a test would see" — it's not pulling its weight.

Delete on sight unless tied to a specific named failure mode:
- Defensive null checks at trusted internal boundaries
- `try/catch` blocks without a specific known thrown source
- "Future-proofing" abstractions with one caller
- Backwards-compat shims, re-exports, or `// removed X` placeholders for code you wrote in the same change

On every refactor, re-justify nearby code that referenced what just changed.
When the load-bearing piece is removed or rewritten, the scaffolding around it usually needs to go too — don't preserve it out of inertia.

Divergence from a peer pattern is a forcing function: if one handler in a block does something the others don't, either justify the divergence in the code or revert to the peer shape.

**Why:** Unjustified code costs review time, lies about what the system actually does, and survives the refactors that should have killed it.


## CC-11 — Kotlin style

**Negation operator has no space.** Write `!foo`, `!isEditorModified()`, `!modified`. Never `! foo`, `! isEditorModified()`, `! modified`.

This is the official Kotlin code style. Treat `!\s+` before any identifier in Kotlin as a hard error during self-review of a Kotlin diff — equivalent to a typo, not a stylistic choice.
