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

**Also note:** consolidating sibling helpers *you just wrote in this changeset* is not drive-by — see CC-12. Drive-by means cleaning up code that *predates* the current change.


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


## CC-12 — Same-changeset sibling duplicates

**Two functions written in the same changeset whose bodies are mostly identical, differing only in 1-3 parameterizable values, should be consolidated into one.**

"No premature abstraction" defends against speculative future generalization. Two siblings written together are not speculative — both callers exist, both shapes are known, and the cost of the second body is a copy-paste maintenance burden from the moment it's committed.

The honest test: if I changed a shared CSS rule (e.g. `width = stepDependencyLaneWidth`) in one helper, would I have to change it in the other to keep them consistent? If yes, they aren't two helpers — they're one helper with two call shapes.

Don't:
```kotlin
private fun ChildrenBuilder.sourceMarker() {
    div {
        css {
            position = Position.absolute
            bottom = 0.px
            left = 50.pct
            marginLeft = stepDependencyMarkerHalfMarginNeg
            width = stepDependencyMarkerSize
            height = stepDependencyMarkerSize
            borderRadius = 50.pct
            borderStyle = LineStyle.solid
            borderWidth = stepDependencyMarkerBorderWidth
            borderColor = stepDependencyTrunkColor
            backgroundColor = NamedColor.white
            boxSizing = BoxSizing.borderBox
        }
    }
}

private fun ChildrenBuilder.targetMarker() {
    div {
        css {
            position = Position.absolute
            top = 0.px
            left = 50.pct
            marginLeft = stepDependencyMarkerHalfMarginNeg
            width = stepDependencyMarkerSize
            height = stepDependencyMarkerSize
            borderRadius = 50.pct
            backgroundColor = stepDependencyTrunkColor
            boxSizing = BoxSizing.borderBox
        }
    }
}
```

Do:
```kotlin
private enum class MarkerKind { Source, Target }

private fun ChildrenBuilder.dependencyMarker(kind: MarkerKind) {
    div {
        css {
            position = Position.absolute
            when (kind) {
                MarkerKind.Source -> bottom = 0.px
                MarkerKind.Target -> top = 0.px
            }
            left = 50.pct
            marginLeft = stepDependencyMarkerHalfMarginNeg
            width = stepDependencyMarkerSize
            height = stepDependencyMarkerSize
            borderRadius = 50.pct
            boxSizing = BoxSizing.borderBox
            when (kind) {
                MarkerKind.Source -> {
                    borderStyle = LineStyle.solid
                    borderWidth = stepDependencyMarkerBorderWidth
                    borderColor = stepDependencyTrunkColor
                    backgroundColor = NamedColor.white
                }
                MarkerKind.Target -> {
                    backgroundColor = stepDependencyTrunkColor
                }
            }
        }
    }
}
```

**Threshold.** If the bodies are ≥70% the same and the differences fit in 1-3 parameters, consolidate. Below that, keep them separate — the shared scaffold isn't load-bearing enough to factor out.

**Same-changeset means same-changeset.** This rule does NOT override CC-07 for *pre-existing* near-duplicates discovered in adjacent code. If you find a duplicate that predates your work, surface it as a follow-up — don't fold it into the current diff. The exception is precisely: code you yourself just wrote.

**Why:** "Premature" describes time, not similarity — and two siblings shipped together are not premature. The guidance "three similar lines is better than a premature abstraction" is about *line-level* repetition inside a single function (`a += 1; b += 1; c += 1`), not about whole sibling functions with the same scaffold. Function-level duplication committed in the same change forces every future edit to walk both copies, and silently rewards drift.


## CC-13 — Test colocation

**Tests live in the same Gradle project and the same package as the code they cover.** A unit `Foo` in `:some-module` under package `tech.kzen.x.y` is tested by `FooTest` in `:some-module`'s test source set, under the same package `tech.kzen.x.y`.

For Kotlin Multiplatform modules, prefer `commonTest` when the test only needs commonMain APIs. Drop to `jvmTest` only when the test legitimately requires JVM-only facilities (file I/O, JDK reflection, JVM-specific libraries).

When the code under test exposes only a `suspend` entry point that the test doesn't actually need to suspend on, factor out a synchronous helper and have the suspend entry point delegate to it — so the test can live in commonTest without pulling in coroutine test infrastructure. This is a productive refactor, not a workaround.

Don't:
- Park tests in a sibling JVM module just because that module already has a test scaffold (e.g. test utilities, real file fixtures). Move or duplicate the minimum scaffold needed instead.
- Put tests under a generic `notation/` or `util/` package when the production code they cover lives elsewhere. The package mismatch makes it hard to find the test from the code (and vice versa) and hides duplicate coverage.

**Why:** One-to-one colocation makes the test discoverable from the production file (and vice versa), keeps test refactors moving in lockstep with code refactors, and prevents tests from drifting into the "lives near a test utility" pattern that ages badly. When `FooTest.kt` is the sibling of `Foo.kt` in the same package, the inverse search ("what tests cover Foo?") is one keystroke.


## CC-14 — Don't bump release-train versions without an explicit ask

**The kzen siblings (`kzen-lib`, `kzen-auto`, `kzen-project`, `kzen-launcher`, `kzen-shell`) are coordinated as a single release train. Never change a `version =` line in a `build.gradle.kts` or a `kzenLibVersion` / `kzenAutoVersion` const in a sibling's `buildSrc/.../Dependencies.kt` as part of any other task.** The release lead bumps them all together, deliberately, when the train is ready.

This applies even when a change has user-facing surface that *would justify* a minor bump in isolation — package relocations, removed public APIs, new HTTP endpoints. Those land at the current SNAPSHOT version. The bump is its own step, on its own change, when the user asks.

**How to apply:**
- A refactor that moves symbols from kzen-auto to kzen-lib stays at the current SNAPSHOT for all siblings. Publish kzen-lib with the new contents at the same version; don't bump.
- A breaking signature change to a public type stays at the current SNAPSHOT. Don't bump even though semver would argue for it.
- If a refactor genuinely *can't* land without a bump (e.g. you need to publish two artifacts side by side at different versions for some staged migration), surface that as a question to the user before doing it.
- When in doubt, leave the version untouched.

**Why:** Versions encode promises to downstream consumers, not just to the build. Bumping in the middle of an unrelated task fragments the release-train cadence the user maintains across the umbrella, and the bump silently propagates into every sibling's `Dependencies.kt` and into mavenLocal — undoing it is a multi-sibling cleanup, not a single revert. The user has explicitly called this out: versions change only when they ask.


## CC-15 — One file per class; class clusters get their own package

**Each top-level class lives in its own file, named after the class — unless there's a specific reason to group them. When several classes form a unit, that unit gets its own package; don't leave the cluster sitting loose among unrelated siblings.**

Acceptable reasons to co-locate top-level classes in one file: a sealed hierarchy whose small variants are only meaningful through the parent, or a private type that is an implementation detail of the file's public class. "They're related" is not enough — related classes are exactly what a package expresses.

The package rule cuts both ways: a unit of related classes should be neither fused into one file nor scattered through a package that also holds other concerns. If the cluster has sibling classes outside the unit, the unit becomes a subpackage.

Don't:
```
service/context/
  GraphCreator.kt
  GraphDefiner.kt
  GraphEnvironment.kt    ← interface + MapGraphEnvironment + GraphEnvironmentBuilder in one file
```

Do:
```
service/context/
  GraphCreator.kt
  GraphDefiner.kt
  environment/
    GraphEnvironment.kt
    GraphEnvironmentBuilder.kt
    MapGraphEnvironment.kt
```

**Why:** File names are the first index a reader uses — a class hiding in a sibling's file is invisible to file-based navigation and search. A package boundary makes the unit's membership explicit (the unit is removable/relocatable as one subtree, per CC-04) and keeps each package focused (CC-06): one-file-per-class without the package boundary would just dilute the parent package instead.


## CC-16 — Never write IDE configuration files

**Never create or modify IDE-private configuration (`.idea/**`, `*.iml`, `workspace.xml`, run-configuration XML) — neither as a fix nor as a suggestion.** These files are machine-local, gitignored, and freely regenerated or discarded by the IDE; anything placed there does not survive git and silently evaporates.

The canonical home for launch/run setup is the build itself — a Gradle task (e.g. `:kzen-auto-test:runTester` with `workingDir`, `args`, system properties) — plus a documented command in the relevant AGENTS.md/README. If an IDE run configuration is convenient, the *user* creates it in the IDE; tooling and agents must not write the XML.

**Why:** IDE state files are not source. A "fix" written into `.idea/` is invisible to version control, unreviewable, lost on re-import/cache-invalidation, and absent on every other machine — it papers over a gap that should be closed in the build or the docs instead.
