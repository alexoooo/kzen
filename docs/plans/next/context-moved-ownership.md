# CTX2 — context signature with an explicit export chain

> **Standalone plan** (design + elaboration in one document, like `context-and-resource.md` — the
> "Constituent plan" column reads `—`, so on landing archive it as an as-built record, do not
> delete). Direct follow-on to CTX (landed 2026-07-29): it **replaces** CTX's nearest-ancestor-slot
> ownership model. Anchors captured and spot-verified 2026-07-29 against kzen-lib `338bd08` /
> kzen-auto `5b25e660` — re-verify before editing (standing rule in `README.md`).
>
> **Design history — this document is the only record.** A first draft (2026-07-29) resolved pickup
> by *consumption inference* (Rust NLL-style) with a `context.owns` pin as the override, and moved
> registrations at settle time. It was rejected the same day in review; §1 records why, because the
> reasoning is the interesting part and nothing else preserves it. A second review pass (same day)
> applied three changes: the signature key is `context.exports`, not `context.provides` (§2, §8 row
> (e)); the legacy-`slots` delete-only chip was dropped in favour of generic unrecognized-key
> preservation plus a warning line (§5.1); and §4.6.1 was resolved — delete `main/Script.yaml`.
>
> Executor: Opus-class. **Three sessions**: A = kzen-lib engine + spec, B = analysis + runtime +
> validation + fixtures **+ shipped-notation migration** (kzen-auto), C = UI + docs + sweep.
> Session boundaries are hard build gates: A ends with kzen-lib green **and published to
> mavenLocal**, B ends with kzen-auto green (which includes `SelfTestContextDeclarationsTest` — the
> notation migration therefore cannot be deferred to C), C ends with the smoke check.

## 1. Why (design rationale)

Under CTX, a step's provided resource (browser, SUT process) binds to the nearest ancestor document
declaring a `context.slots` entry — at **any** depth, tunneling through non-declaring intermediates
— falling back to the opening document. Three consequences the user rejected as a fundamental gap:

- The **opener has no scope control**: any provide is capturable by any ancestor's slot; a
  sub-script cannot keep a resource private.
- The step-header badge ("bound to: a calling document") is an **unverified claim** — computed only
  from the opening document's own slots; the editor cannot see callers.
- An unowned escaping provide **silently dies** at the sub-script's settle; the only diagnostic is
  an advisory amber warning at the RunStep call site.

The replacement inverts the direction of the declaration. **Ownership is offered by the provider,
not claimed by an ancestor**: a document declares `context.exports` to export what it opens, and a
provide it does not export is private to its own frame. Ownership travels exactly as far as an
unbroken chain of `exports` declarations carries it, and no further.

### 1.1 Consumption inference: considered and rejected

The first draft inferred pickup from consumption — a caller took ownership of a callee's export iff
a later step consumed it (required it, released it, re-exported it) or a `context.owns` pin said so.
Rejected for four reasons, in descending weight:

1. **The Rust analogy argues the other way.** NLL governs *borrow* lifetimes; Rust deliberately does
   **not** infer drop timing from last use — a value with a destructor drops at end of scope, and
   `let _ = f();` still holds the returned value to the end of the enclosing scope. "Callee exports
   ⇒ caller owns ⇒ dropped at the caller's settle unless the caller re-exports" *is* the Rust rule.
2. **The pin existed to patch the inference.** `context.owns` was needed because inference cannot
   see implicit consumption (a SUT driven only through browser-URL steps). Remove the inference and
   the pin's canonical justification evaporates — under an explicit chain the SUT is exported, the
   root does not re-export, and it rests at the root with nothing to declare. Textbook accidental
   complexity.
3. **It bought almost nothing.** Both models give the *same* owner on every well-declared case. They
   differ only in how long an exported-but-unwanted resource lingers (one frame), and the draft's
   own decision 3 says provided-but-never-consumed warrants no diagnostic at all.
4. **The cost was concentrated in the worst places**: a conservative loop rule the draft itself
   flagged as easy to get subtly wrong, a leniency asymmetry feeding a now-*blocking* error, a
   `pickups` channel threaded through `Execution.host` → `ScriptRunContext` → `ScriptRunStructure`,
   and a mandatory whole-graph memo because the badge computation moved onto the per-keystroke path.

The draft also resolved ownership by **moving registrations at settle time**. With the chain fully
explicit, resolving at **bind time** is strictly better: it is one inverted walk in `registerResource`
(`disposeResources`, `host` and `runSteps` all stay untouched), it keeps the CTX rule that the
existing migration machinery already implements (registrations lifted by their *owner's* stable id),
and it removes the settle-time model's two accepted costs — a re-providing loop peaking at two live
resources, and an exported resource being invisible to a concurrently-hosted sibling until its
provider settles.

**Kept from the draft verbatim** (user decisions, not to be re-litigated):

- **Export is an explicit signature.** A document declares `context.exports`; an un-exported step
  provide is private — a value only moves out if you `return` it.
- **Strictness inversion.** Required-but-not-provided = blocking ERROR (Run disabled);
  provided-but-never-consumed = fine, **no** diagnostic.

## 2. The model

A document's **context signature** (edited in the top-right signature stack next to Parameters and
Result):

| Key | Status | Meaning |
|---|---|---|
| `context.requires` | kept | Ambient context parameters a caller must supply. Reads stay ambient — engine read-walk self→root unchanged (Kotlin `context(...)` receivers). |
| `context.exports` | **new** | Contexts this document **exports** to its caller: offered ownership, like a Rust return move. A step provide whose Context is not listed is **private**: bound to this document's frame, disposed at its settle per closePolicy. |
| `context.slots` | **removed** | No longer has any effect. Detected and reported as a deprecation warning, and surfaced as a warning line in the signature editor so it is visible rather than silently inert. Deliberately **not** auto-migrated to `exports`: `slots` was a *capture* declaration on the consumer, `exports` is an *offer* on the provider — they sit on opposite documents, so a mechanical rewrite would move the wrong thing. |

**Ownership resolution — a bind-time export-chain climb.** A registration starts at the frame that
opened it and climbs while **that frame** declares an export matching the key (exactly, or by
family), stopping at the first frame that does not, or at the root. So:

- nothing exported ⇒ the resource is owned and disposed exactly where it was opened (private by
  default — the CTX behaviour for undeclared usage, now also the behaviour for *un-exported* usage);
- one hop per `exports` declaration, and every hop is a declaration someone wrote;
- the resting frame is the furthest document that *chose* to receive it, which is precisely the
  frame whose settle disposes it.

`closePolicy` (auto/manual/keepOnFailure) is **unchanged**: it travels with the registration and
applies at the frame where the registration rests. Manual's hand-up cascade stays as the orthogonal
escape hatch — now the *only* way an un-exported resource outlives its provider.

**Severities.** Blocking errors: a step whose `requires` is unsatisfied by (document
`context.requires` ∪ prior provides ∪ prior callee exports ∪ prior manual-reach); a RunStep whose
callee's `context.requires` is unsatisfied at the call site. CTX's escaping-provide advisory warning
is **deleted** — private-by-default makes it noise on a legitimate pattern. Its diagnostic value is
preserved more precisely: when a requires-error fires and an earlier callee provides that Context
*without exporting it*, the error names that document and the fix. Kept warnings: dangling context
references, shared-key alias reports. New warnings: `context.exports` declares X but nothing in the
document can provide it; legacy `context.slots` present.

**Pre-made implementation decisions** (do not re-open):

- **The signature key is `context.exports`** (role label "Exports"), not `provides`: step-level
  `provides` (`ContextProvider`) already means *opening* a resource into the run, and everything
  else in the model — the spec, `declareExport`, the error messages — says export. One word, one
  meaning; the lost `requires`/`provides` rhyme is accepted. §8 row (e).
- **Exports are family-granular** (`ContextDescriptor.key`, i.e. the part before `':'`), matching
  today's slot matching: a `sut` export carries `sut:main` / `sut:other` as independent
  registrations.
- **Same-key collision runs the displaced closer** (supersession) — **already landed, 2026-07-29**,
  ahead of this plan and independently of it: `registerResource` used to do `resources[key] = …`,
  dropping the prior registration without closing it, so a loop that re-provided leaked one resource
  per iteration. Shipped with its closer contract (a closer disposes the handle it *captured*, never
  re-resolves by name), the `StartKzenAutoStep` fix that contract required, logic-spec §6, and two
  engine regression tests. CTX2 depends on it — it is what keeps the live-resource count at one when
  a loop re-provides — but must not re-implement it. Re-verify it is present before starting §3.1.
- **No server-side Run refusal** — parity with compile errors, which also gate client-side only;
  the runtime gates are the server's backstop.
- **Non-Script Logic flavours cannot export**, and this now falls out of the mechanism rather than
  needing a special case: the climb consults each frame's own declarations, and only `Script`
  declares `context` (`common-document.yaml:135,147` — not `Logic`, `Flow`, `Job` or `Report`). A
  RunStep can target any Logic document, so a resource opened inside a hosted Flow/Job is
  permanently private — a behaviour change vs CTX (a caller's slot could capture it). Recorded as a
  §8 decision-log row rather than lifting `context` onto `Logic`; revisit if a real Flow/Job
  provider appears. Same reasoning covers kzen-auto's `JobRun` `"job-scratch"` (kzen-auto
  `JobRun.kt:174`): a raw self-bound `execution.resource` on a node that never exports, unaffected.
- **Ownership stays fixed at bind time** (the CTX rule, logic-spec ~L481-483, unchanged). Editing a
  `provides` declaration affects subsequent opens only; an already-bound registration is lifted
  across the migrate barrier keyed by its owner's stable id and re-adopted there.

## 3. Session A — kzen-lib engine + spec

### 3.1 Engine

`RunEngine.kt` (kzen-lib-jvm `.../server/exec/engine/RunEngine.kt`) — four edits, all local, and the
line anchors below predate the 2026-07-29 supersession change (§2), which grew `registerResource`
by a few lines; re-locate by symbol, not by number:

- `NodeRuntime.declaredSlots` (L117) → `val exports = LinkedHashSet<String>()`; rewrite the
  L112-117 comment (still deliberately **not** lifted at the migrate barrier — the rebuilt tree
  re-runs each `Logic.run`, which re-declares).
- `slotOwnerOf` (~L1139-1150) → `exportOwnerOf`, the same walk with the condition inverted:

  ```kotlin
  // Must hold lock. The furthest frame on [nodeId]'s self → parent → … → root chain reachable through an
  // UNBROKEN chain of export declarations: climb while the CURRENT frame declares an export matching [key]
  // (exactly, or by family before the first ':'). The first frame that does not export is where the
  // registration rests — so a provide nothing exports stays on the opening frame, private by construction,
  // and a frame of a flavour that never calls [declareExport] ends every chain that reaches it. An actively
  // running node's ancestors are always still live, so the walk never dangles.
  private fun exportOwnerOf(nodeId: NodeId, key: String): NodeId {
      val family = key.substringBefore(':')
      var current = nodeId
      while (true) {
          val runtime = nodes[current] ?: return current
          if (key !in runtime.exports && family !in runtime.exports) {
              return current
          }
          current = runtime.parentId ?: return current
      }
  }
  ```

- `registerResource`: **one word changes** — `slotOwnerOf` → `exportOwnerOf`. The supersession half
  (capturing the displaced registration and running its closer off-lock) landed 2026-07-29; leave it
  alone.

- `declareSlot` (L1127-1131) → `declareExport`, unchanged body against the renamed set.

**Untouched, and that is the point**: `disposeResources` (~L1026-1058, Manual hand-up intact),
`host` (~L804-823), `settleNode`, the migrate lift/re-adopt/orphan-sweep path (~L557-566, ~L632-652),
and the three read walks (`resourceValueFor`, `hasResourceInFamily`, `releaseResource`, L1164-1210),
which keep working because the resting frame is always on the opener's self→root chain.

`Execution.kt` (kzen-lib-common `.../exec/engine/Execution.kt`, §6 block ~L131-185):

- `declareSlot` → `declareExport(family: String)`, KDoc rewritten for the offer-upward semantics
  (declare at `Logic.run` start, before hosting children and before any local step opens; idempotent;
  re-declared free on a migrate rebuild).
- `resource` KDoc (~L145-160): owner is now "the furthest frame reachable through an unbroken chain
  of `declareExport` declarations, falling back to THIS node when it exports nothing". The
  supersession rule and closer contract are already in this KDoc — do not restate them.
- `host` signature unchanged.

`ResourceClosePolicy.kt` KDoc (kzen-lib-common `.../exec/logic/`): the owner is now "the furthest
document on the export chain", not "the nearest declaring slot".

### 3.2 Spec

`kzen-lib/docs/logic-spec.md` §6 (~L461-548): rewrite "Ownership is declared by the owner" into
"Ownership is offered by the provider and travels the export chain". Points that must survive the
rewrite:

- **Default = private**, and its consequence for the ~L495-501 first-class requirement ("own a
  resource at the top level **and** own a separate resource of the same kind per child"): under CTX
  a sub-script had to declare its own slot to avoid capture; under CTX2 it keeps its own instance by
  saying nothing.
- **Ownership is fixed at bind time** (~L481-483) — kept verbatim, now with the export chain as the
  resolution rule.
- The ~L516-524 "two orthogonal mechanisms" bullet: the export chain moves *ownership* at bind time;
  a Manual registration separately survives its resting frame's settle by handing up one level.
  Both may apply to one resource.
- **Supersession** and its closer contract are already spec'd (the bullet added 2026-07-29) — leave
  the paragraph, it needs no export-chain rewording.
- **Two live registrations under one key** are coherent (a caller holds a child's exported X while a
  second child's *private* X shadows it within that child's subtree via the read walk) — spec it,
  and cover it with a test.
- **Migration** (§5) is mechanically unchanged: registrations lifted per owner stable id
  (~L557-566), re-adopted (~L645-652), orphan sweep (~L632-639). Export declarations are not lifted;
  the rebuilt tree re-declares them.

§8 decision-log rows: (a) export-chain ownership supersedes nearest-declaring-slot (CTX) —
reference `kzen/docs/plans/next/context-and-resource.md` as the prior record, and note the intended
breaking change (undeclared consumers lose tunneled capture); (b) consumption inference considered
and rejected, with §1.1's reasoning compressed to two sentences; (c) supersession runs the displaced
closer, with the loop-leak motivation and the closer contract; (d) non-Script flavours cannot
export; (e) the signature key is `context.exports`, not `provides` — step-level `provides` already
means opening a resource, and the model's vocabulary is export throughout.

### 3.3 Session A tests — `RunEngineTest.kt` resource section (~L1715-2300, 17 tests)

Revise:

| Existing | Becomes |
|---|---|
| `declaredSlotOnParentOutlivesTheOpeningChildAndDisposesAtTheSlotOwnersSettle` (L1715) | child **exports**, parent does not → rests at parent |
| `rootDeclaredSlotOwnsAResourceOpenedAtDepthTwo` (L1748) | leaf **and** mid export, root does not → rests at root |
| `nearestDeclaringAncestorWinsOverAFurtherOne` (L1786) | **inverted**: leaf exports, mid does NOT, root does → rests at **mid**; the chain stops at the first non-exporting frame |
| `undeclaredKeyFallsBackToTheOpeningNode` (L1822) | kept + renamed: an un-exported provide is private to the opening node |
| `aSlotOwnsEveryQualifiedKeyInItsFamilyIndependently` (L1852) | family-granular exports carry `sut:a` / `sut:b` independently |
| `hasResourceInFamilyMatchesTheFamilyButNotTheQualifier` (L1887) | unchanged |
| `keepOnFailure…SlotOwners…` ×2 (L1926, L1953) | resting-frame outcome, not the opener's |
| `declareSlotIsIdempotent` (L1978) | `declareExportIsIdempotent` |
| `manualHandsUpPastItsSlotOwnerAtThatOwnersSettle` (L2078) | Manual on the chain's resting frame still hands up at that frame's settle; the two mechanisms compose |
| `releaseResourceFromDescendantRemovesSlotOwnedRegistration` (L2225) | …`RemovesAnExportedRegistration` |
| `migrateReDeclaresSlotsAndKeepsTheLiftedResourceOnItsOwner` (L2258) | `migrateReDeclaresExports…`, same assertion |

New:

- Exporting root self-binds (no parent — the chain terminates).
- Bind-time rule: declaring an export *after* a descendant already registered does not re-home the
  existing registration; only subsequent opens climb.
- Same-key shadowing: a private child registration shadows the caller-held one within the child's
  subtree; both closers fire at their respective frames' settles.
- Release from a descendant of the resting frame (chain-owned registration, deregistered from below).

Already present, and worth re-reading before touching the section — they encode behaviour the export
chain must preserve: `reRegisteringAKeyDisposesTheRegistrationItDisplaces` and
`reProvidingInALoopKeepsOneLiveRegistrationAndDisposesEachPredecessor` (the latter's root currently
`declareSlot`s the key so every iteration collides; under CTX2 the *child* declares the export
instead — same collision, same assertions).

**Gate**: `cd ../kzen-lib && ./gradlew build && ./gradlew publishToMavenLocal` (all subprojects —
kzen-auto's jvmMain/jsMain variant-suffix coords resolve from mavenLocal at the same version).

## 4. Session B — analysis, runtime, validation, fixtures, notation migration (kzen-auto)

### 4.1 Conventions (`kzen-auto-common .../logic/context/LogicContextConventions.kt`)

- Add `exportsSegment` / `documentExportsAttributePath` and the reader `documentExports`
  mirroring `documentSlots` (L71-73, retired). Retain `slotsSegment` / `slotsAttributePath` and a
  `legacyDocumentSlotReferences` reader used **only** by the deprecation warning (analysis + the
  editor's warning line — §5.1).
- Update the file KDoc (L14-34): the document declares `context: { exports: [...], requires: [...] }`.
- `isContextDeclaration` (L61) already hides the whole `context` attribute from the body editor — no
  change.

No name collision to manage: `providesAttributeName` / `providesAttributePath` (L46-47) remain the
**step-level** `provides`, and the document-level key is deliberately `exports` (§2), so
`documentExportsAttributePath` sits alongside `documentRequiresAttributePath` without overloading.

### 4.2 Analysis (`LogicContextAnalysis.kt`, rewritten in place)

Still pure-notation commonMain, so the JS editor, the JVM validator and the JVM spine share one
implementation. The result type splits severity and nothing else:

```kotlin
data class LogicContextFindings(
    val errors: Map<ObjectPath, String>,     // blocking (incl. main-keyed document-level)
    val warnings: Map<ObjectPath, String>    // advisory (incl. main-keyed document-level)
)

fun analyze(graphNotation: GraphNotation, documentPath: DocumentPath): LogicContextFindings
```

**There is no resolution object, no pickup map and no engine-facing output.** The engine learns
about exports from `ScriptLogic` reading the document's own declaration; nothing about a caller
needs computing. That is the whole reason this session is small.

The existing `walk` / `visitStep` traversal (L82-161) is kept — availability accumulates in document
order, conditionals still add-but-never-remove (L149-156), which stays right for the same reason as
before. What changes:

1. **Availability at a RunStep** (replaces `analyzeRunStep`, L189-244). Hosting `H` adds:
   - `documentExports(H)` — H's *declared* export contract. This needs **no recursion**: if H
     exports X, H asserts it delivers X whether from its own step or a re-export of its own callee.
     Availability stays sound when *this* document re-exports X too: the registration then rests
     above this frame, but reads walk self→root, so later steps here still reach it.
   - `{X : some step of H provides X with closePolicy manual}` — today's `hostedProvides` manual flag
     (L253-273), **kept**, because Manual hand-up is real engine reach and dropping it would falsely
     error FormulaError-shaped documents. Deliberately **one level deep**, as today: a Manual
     resource opened two levels down with nothing declared is not modelled — the remedy is
     `exports`, and the KDoc says so.
2. **Errors** (both were warnings): a step `requires` X ∉ availability (L130-137); a RunStep whose
   callee's `documentRequires` X ∉ availability (L237-243). Message names the real remedies —
   declare `context.exports` on the providing document, or `context.requires` here when a caller
   genuinely supplies it. **Enrichment**: track `shadowed` — Contexts an earlier callee provides via
   its own steps but does not export (`ownStepProvides(H) − documentExports(H)`, the existing
   L253-273 scan)
   — and when an error fires for a shadowed Context, name the providing document: *"`<H>` provides it
   but does not export it — add it to that document's `context.exports`."* This is where the deleted
   escaping-provide warning's value goes: at the point of failure, not as standing noise. Compute
   `shadowed` lazily, only when an error is being produced.
3. **Warnings**: dangling + alias unchanged (`danglingAndAliasWarnings` L322-368 — the main-object
   branch at L358-360 checks `context.exports` and `context.requires`); **new**: `context.exports`
   declares X that this document cannot provide, where *can provide* =
   `{X : a step of this document provides X} ∪ ⋃_{RunStep→C} documentExports(C)` (one level, cycle-free
   by construction since a callee's contract is a declaration, not a walk; known false-negative to
   note in the KDoc — two documents each declaring an export backed only by a RunStep to the other
   both pass the one-level check; warning-severity, pathological authoring, accepted); **new**: legacy
   `context.slots` present — "no longer has any effect; declare `context.exports` on the document
   that provides the resource." **Deleted**: the escaping-provide branch (L215-235) and its
   three-reason escape test.
4. Expose `canProvide(graphNotation, documentPath)` and `legacySlotReferences(...)` as public
   helpers — Session C's signature editor renders both findings locally from the same
   implementation rather than growing a second copy or new validation plumbing.

**Caching is optional, not mandatory** (this is the load-bearing difference from the rejected draft).
Nothing on the per-keystroke path calls `analyze`: the step badges need one or two attribute reads
each (§5.1), and the signature editor scans only the open document. The validator keeps memoizing
via the existing digest-keyed `scriptValidationCache`. If profiling later shows the editor's
per-publish `canProvide` scan matters, a GraphNotation-identity memo is a drop-in — but do not build
it up front.

### 4.3 Runtime spine (kzen-auto-jvm)

`ScriptLogic.kt` (`run`, L62-65 — replaces the documentSlots loop). This is the **only** spine
change; `ScriptRunContext` and `ScriptLogicCompiler` are untouched.

```kotlin
// Contexts this document EXPORTS (logic-spec §6): declared BEFORE any step runs and before any child
// is hosted, so a provide anywhere below climbs through this frame when it is on an export chain.
for (export in LogicContextConventions.documentExports(
        structure.graphNotation, structure.scriptLocation.documentPath)) {
    execution.declareExport(export.key)
}

// Upfront gate: a document declaring `context.requires` cannot work without a caller that supplies it,
// so fail at run start rather than three steps in. Family-granular, and sound for the Script spine
// because a caller's provides always precede its RunStep positionally.
for (required in LogicContextConventions.documentRequires(
        structure.graphNotation, structure.scriptLocation.documentPath)) {
    check(execution.hasResourceInFamily(required.key)) {
        "Requires ${required.label()}: not provided by caller"
    }
}
```

Implementation check at this spot: `check {}` throws `IllegalStateException` out of `Logic.run` —
confirm it surfaces through the same failure channel as a step failure (run marked failed, message
visible in the UI), not as an unhandled engine error.

**Recorded behaviour change**: any document declaring `context.requires` becomes non-runnable
standalone — it fails immediately instead of at its first requiring step. That is correct (it could
never have succeeded) but it is user-visible for every FizzBuzz sub-script. Run is *not* disabled
client-side (the document is valid; it just needs a caller), so §5.1 extends the "Needs" chip
tooltip to say so.

**No other spine work.** The closer-contract fix `StartKzenAutoStep` needed (its closer used to
re-resolve the SUT by name, which supersession would have turned into "kill the replacement") landed
2026-07-29 with the supersession change, as did the `StepExecution` KDocs and the
`providerReadsBackItsOwnProvidesArgumentFree` expectation that had encoded the leak.

### 4.4 Validator severity plumbing (verified mechanism, 2026-07-29)

`StepValidation` already carries `errorMessage` vs `warningMessage`;
`ScriptStore.currentValidationErrors()` (kzen-auto-js `.../script/model/ScriptStore.kt:239-250`)
lifts every non-null `errorMessage` into `LogicValidationGlobal`, whose `invalidReason`
(`LogicValidationGlobal.kt:86`) disables Run in `HeaderRunController` (`HeaderRunController.kt:228`).
So `ScriptValidator.kt` (L107-111) replaces the warning-only merge: errors joined into
`errorMessage` (**joined**, not overwritten — a compile error may already be there), warnings as
today. Zero wire or JS gating changes.

`main`-keyed (document-level) **errors** already have a rendering surface and need no new work:
`StageController.validationLinesFor` (L264-270) maps every `ValidationErrorLine` — `main` included —
into `DefinitionErrors.Line`, rendered by `StageErrorIndicator` (L348-373). Document-level
**warnings** remain invisible on that channel (a pre-existing CTX gap), which is why §5.1 has the
signature editor compute and render its own two warnings locally rather than plumbing warnings
through the validation channel.

### 4.5 Notation comment/schema updates

- `common-document.yaml` (L130-135): rewrite the `context:` comment block — `exports` (export
  signature; un-exported provides are private) and `requires` (a caller must supply). The `context`
  map meta is open-keyed `is: Map, of: [String, {is: List, of: ObjectLocation}]` `by: Nominal`
  (L147-153), so the new key is covered by the existing weak-reference machinery including rename
  propagation; **verify** via the `ContextRenameTest` addition below.
- `script-jvm.yaml` (L15-17): rewrite the ResourceClosePolicy ownership comment (the owner is the
  furthest document on the export chain, falling back to the providing document). `ContextProvider`
  (L43-52) **unchanged** — no new step-level attribute exists (binding is signature-level), so no new
  definer, no SelectValuesEditor work, and `script-step-test-archetypes.yaml`'s
  plain-String-closePolicy rule needs nothing new.

### 4.6 Shipped-notation migration (kzen-auto-test `src/main/resources/notation/main/`)

Lives in Session B, not C: `SelfTestContextDeclarationsTest` runs on B's build gate and asserts over
`main/`, so B cannot be green without it. The whole surface is five files — verified 2026-07-29 that
`main/` contains exactly two provider documents (`FizzBuzz/Open Kzen and Browser.yaml`,
`FormulaError/Open Kzen and Browser.yaml`) and two `slots` declarations.

| File | Change |
|---|---|
| `FizzBuzz/Open Kzen and Browser.yaml` | Add `context: {exports: [SutContext, BrowserContext]}` on `main`. The SUT is `auto`, the browser `keepOnFailure`; both now climb to the root, which is what the root's slots used to do. |
| `FizzBuzz/FizzBuzz.yaml` | Drop `context.slots` entirely — it declares nothing and owns both by being the first non-exporting frame above the provider. Rewrite the header comment as the model's teaching example: *the provider offers, the root receives by saying nothing.* |
| `FormulaError/Open Kzen and Browser.yaml` | Add `context: {exports: [SutContext]}`. The browser stays `closePolicy: manual` with **no export** — deliberate coverage of the orthogonal hand-up; say so in the comment. |
| `FormulaError/FormulaError.yaml` | Drop `context.slots`. Rewrite the comment to explain the deliberate asymmetry with the line above. |
| `Script.yaml` | **Delete** — §4.6.1, resolved 2026-07-29. |
| `FizzBuzz/*`, `Actions/Insert Last.yaml` | `context.requires` consumers unchanged. |

Sanity trace to confirm before editing: FizzBuzz root hosts the provider first, so both resources
climb to the root at bind time; `Build Item` / `Build Loop` / `Run` read them off the root frame via
the ancestor walk; `Close Browser and Kzen` releases both; the browser's `keepOnFailure` keys off
the **root's** outcome, matching today. FormulaError: the SUT climbs to the root; the browser is
private to the provider and reaches the root by Manual hand-up at the provider's settle, so
`Run and Read Error.yaml`'s `requires: [BrowserContext]` (verified: BrowserContext only) is satisfied
by the analysis's manual-reach rule.

#### 4.6.1 `main/Script.yaml` — resolved (user decision, 2026-07-29 plan review): delete it

`SelfTestContextDeclarationsTest` (L28-32) tolerates exactly one warning, on `main/Script.yaml`, and
its comment states the resolution deliberately: *"Silencing it would mean weakening the analysis or
lying in the notation; leaving it is the documented resolution."* Under the strictness inversion that
warning becomes a blocking error, so it had to be resolved — and the obvious fix (declare
`context.requires: [BrowserContext]`) **asserts a caller that does not exist**: verified 2026-07-29
that nothing references `main/Script.yaml` (`SmokeSelfTest` drives only `FizzBuzz.yaml` and
`FormulaError.yaml`; the only mention in code is the tolerated-warning set itself). It is a bare
harness around `Actions/Insert Last.yaml`.

**Decision: delete `main/Script.yaml` and the expected-warning set with it.** Nothing runs it; the
library script it wraps is exercised through FizzBuzz, and the prior tolerated-warning call it
memorialized stays recorded in git history and in this section. Alternatives considered and passed
over: making it genuinely runnable (its own `Open Kzen and Browser` RunStep — effort nothing needs)
and keeping a findings-allowance in the test (a mechanism kept alive solely to remember a decision
the new severity model retires). After the deletion the test asserts **zero findings** over `main/`.

### 4.7 Session B tests

- **`ScriptContextValidationTest.kt`** (+ the 16 `script-context-*.yaml` fixtures):
  `unsatisfiedRequiresWarns` → `…Errors`; `unslottedCrossDocumentProvideWarnsAndIsNotAvailable` →
  replaced by *un-exported hosted provide is silent at the RunStep and the downstream consumer
  errors, with the error naming the providing document*; `aCallerDeclaredSlotSilencesBothWarnings` →
  *the callee's `context.exports` silences both*; `manualProvideEscapesWithoutASlot` → kept (manual
  reach, no error); `hostedRequiresWarnsOnTheCallersRunStep` → errors. New: export makes a Context
  available after the RunStep and not before (positional); a re-export chain across two documents;
  `context.exports` declaring a Context nothing in the document can provide → warning; legacy
  `context.slots` → deprecation warning **and no ownership effect** (a document with `slots` and no
  callee `exports` errors at its consumer); the manual-reach rule is one level deep (two levels ⇒
  error, with the `exports` remedy named).
- **`ScriptContextRuntimeTest.kt`**: `typedProvideInsideHostedDocumentReachesTheCallersSlot` (~L124)
  → callee exports, caller receives; new: an un-exported provide is disposed at the child's settle
  and unreadable afterwards; the upfront `documentRequires` gate fails a direct run.
- **`ScriptExtensibilityTest.kt`** (L74-114): `script-resource-parent-scope-test.yaml` — the child
  gains `context.exports`; the parent needs **no** declaration (it consumes via raw keys, and is the
  first non-exporting frame). `script-resource-run-scope-test.yaml` — mid gains `context.exports`
  so the chain reaches the root; assertions unchanged. Extend `openResourceSurvivesLiveEditMigration`
  with an exported resource: the lifted registration stays on its resting frame across the barrier
  and disposes there.
- **`ContextRenameTest.kt`** (L75, L94): `documentSlots` → `documentExports`; add a rename of a
  Context named in `context.exports`.

**Gate**: `cd ../kzen-auto && ./gradlew build` — green including `SelfTestContextDeclarationsTest`
asserting zero findings over `main/` (§4.6.1).

## 5. Session C — UI, docs, sweep

### 5.1 UI (kzen-auto-js)

Every badge below is computed from **one or two notation attribute reads**. There is no graph walk on
the publish path and no memo — that is a direct consequence of dropping inference, and it is worth
keeping true.

- **`ScriptStepDisplayDefault.kt`** (`onClientStateExtra`, L241-302): replace
  `providesBoundToDocument` (L271-275) with `providesExported: Boolean?` — is the step's provided
  Context in `documentExports(stepLocation.documentPath)`? For a RunStep, add
  `hostedExports: List<ContextDescriptor>?` (`documentExports(hostedPath)`) and
  `hostedExportsContinuingUp: List<ContextDescriptor>?` (those also in this document's own
  `documentExports`). The value-compare guard (L280-290) and the `setState` block (L292-301) gain
  the new fields.
- **`StepHeader.kt`** (`renderContextDeclarations`, L425-469): the provides badge tooltip becomes a
  *verified* state instead of the current unverifiable "bound to: a calling document" —
  **Private**: "private to this document — disposed when it settles"; **Exported**: "exported — the
  calling document takes ownership (and passes it further up if it exports it too)". RunStep badges
  surface hosted exports: "hosted document exports X — owned here / passed further up by this
  document's own exports".
- **`ContextSignatureEditor.kt`** (`.../common/signature/`): two roles, "Exports"
  (`context.exports`) and "Needs" (`context.requires`) — `roleOptions` (L108-116) relabelled,
  `slotRoleValue` → `exportsRoleValue`, state `slots`/`addingSlot` → `exports`/`addingExports`,
  `onPick`'s mutual exclusion (L207-213) and `onRemove` (L220-232) retargeted, `writeContext`
  (L270-289) writing `exports` + `requires`. Three additions:
  - **Unrecognized-key preservation**: `writeContext` carries every `context.*` key it does not
    recognize through verbatim — generic, not slots-specific, so the editor never eats a key it
    doesn't understand and the next signature addition gets the property for free. Legacy `slots`
    is just one such key: no delete-only chip, no dedicated rendering; the user cleans it up by
    hand-editing the YAML. Do not auto-convert (§2).
  - **The two document-level warnings**, computed locally via §4.2's public helpers — the
    declared-but-unprovidable warning rendered on the offending Exports chip, the legacy-`slots`
    deprecation as a plain warning line in the editor. This is the only surface document-level
    warnings have (§4.4).
  - The "Needs" chip tooltip gains the standalone-run consequence: *"…a caller must already have
    provided it, so running this document directly fails immediately."*
- Fast gate: `cd ../kzen-auto && ./gradlew :kzen-auto-js:compileKotlinJs`.

### 5.2 Docs + sweep

- `kzen-auto/docs/architecture.md` (~L377-384 region): rewrite the ownership paragraph.
- KDoc sweeps: `LogicContextConventions`, `LogicContextAnalysis`, `ScriptRunContext` (L270-274's
  "nearest enclosing document that declared a slot"), `StepExecution` context section
  (`openResource` L206-208 — add the closer contract).
- Grep **all siblings** for `context.slots` / `documentSlots` / `declareSlot` / `slotOwner` /
  "bound to: a calling document" stragglers, comments included.
- Update `context-and-resource.md`'s As-built section: "superseded in part by CTX2 (this plan) —
  nearest-slot binding replaced by an explicit export chain".
- Record as durable guidance (architecture.md, near the plugin-step docs): **a plugin step that opens
  a run-scoped resource should mix in `ContextProvider`** — otherwise its consumers cannot be
  statically satisfied and every caller needs a `context.requires` that is a half-truth.

### 5.3 Smoke verification

Boot a fresh instance on a **spare port** (never the user's 8080/18081 dev servers; verify any JVM
you stop is one you started). Open `FizzBuzz/Open Kzen and Browser.yaml`: the signature shows two
Exports chips and "Start SUT" shows the verified **Exported** badge. Open `FizzBuzz.yaml`: the
RunStep for it reports the two hosted exports as owned here. Make an artificial unmet-requires edit
and confirm Run greys out with the error on the step; revert.

## 6. Risks

- **Strictness false positives.** Consumption invisible to the analysis (raw-key `openResource`,
  plugin steps without `requires`) now errors instead of ambering. Two escape hatches, and they are
  the honest ones: declare `context.exports` on the providing document — viable when the step's archetype
  mixes in `ContextProvider` (`script-jvm.yaml:43-52`), which is why §5.2 records the plugin
  guidance — or `context.requires` here when a caller genuinely supplies it. There is deliberately
  **no** third hatch that manufactures availability: the rejected draft's `context.owns` could not do
  it either (a bare pin seeded nothing), and adding one would convert a static error into a silent
  runtime one.
- **Provider-side privacy is an intended breaking change**: an undeclared consumer's resource may now
  be disposed earlier than under tunneling. Spec §8 decision-log row (a).
- **Supersession's closer contract** (landed 2026-07-29, see §2) is a standing edge for any new
  provider step: a closer that re-resolves its target by name is actively wrong, not merely leaky.
  Documented in `Execution.resource`, `StepExecution.provideContext` / `openResource` and logic-spec
  §6; regressed by two engine tests. Nothing for CTX2 to do beyond not regressing it — but a
  reviewer of §4.6's notation should still confirm no *new* provider step is introduced without it.
- **Manual reach is modelled one level deep only** (§4.2 rule 1) — matching today's behaviour and
  today's `hostedProvides`, but now feeding a blocking error rather than a warning. A two-level
  Manual chain that works at run time will error statically. Accepted: the remedy (`exports`) is the
  behaviour we want anyway, the error names it, and FormulaError is the only shipped case and is
  one level.
- **`main/Script.yaml` (§4.6.1) — resolved** (user decision, 2026-07-29): delete it and the
  expected-warning set; the B gate asserts zero findings. No longer an open item.
- **Two live registrations under one key** — coherent but new; spec §6 + engine test.
- **Deferred, not planned**: whether a callee's `releases` should remove availability in the caller
  after that RunStep (mirroring L152-156's top-level rule). It would catch a consumer placed after a
  Close RunStep, but it is new strictness feeding a now-blocking error; separate decision.

## 7. As-built (2026-07-29)

All three sessions landed as specified. Gates: kzen-lib `build` + `publishToMavenLocal` green (66
`RunEngineTest` tests, every new export-chain test passing first try); kzen-auto `build` green (622
JVM tests, `SelfTestContextDeclarationsTest` asserting **zero** findings over `main/`); smoke check
done on a spare port (18099).

Deviations and resolutions, in descending interest:

- **§4.3's open verification item resolves positively.** The upfront `check {}` gate's
  `IllegalStateException` is caught by `RunEngine`'s `catch (e: Throwable) → Outcome.Failed(...)`, so
  a standalone run of a `context.requires` document is marked failed with
  `"Illegal State: Requires <X>: not provided by caller"` on the same channel as a step failure — not
  an unhandled engine error. Pinned by `documentRequiresGateFailsTheRunBeforeAnyStep`.
- **`isRunStep` / `hostedDocumentPath` moved from `LogicContextAnalysis` to `ScriptConventions`.**
  §5.1's RunStep badges need the same caller→callee resolution the analysis does; duplicating it
  would have been a same-changeset duplicate (CC-12), and `ScriptConventions` is the narrowest object
  that owns `RunStep` and `instructions`.
- **§4.2's `shadowed` map is built from the scan rule 1 already performs**, not deferred to the error
  path: `ownStepProvides(H)` runs at every RunStep anyway (the manual-reach rule needs it), so
  recording the un-exported subset costs a map insert. Named `unexportedProvides` in the code, since
  "shadowed" collides with the spec's two-live-registrations shadowing.
- **The generic remedy names all three fixes**, not two. §4.7's "two levels ⇒ error with the `exports`
  remedy named" is unreachable through the enriched branch — at two levels the one-level scan sees no
  provider to name — so the fallback string itself lists adding a step, adding to a callee's
  `context.exports`, and declaring `context.requires` here.
- **`LogicContextFindings` is its own file** (CC-15), with an `empty` constant the tests assert
  against; it deliberately carries no `isEmpty()` helper, since nothing needed one.
- **The `script-context-warn-*` fixtures dropped the `warn-` prefix.** Under the severity inversion
  four of the eight assert errors, so the old name claimed the wrong severity.
- **Known cosmetic consequence of §6's raw-key risk, in-tree**: `script-resource-*-test.yaml` open
  through the raw string API (`OpenResourceTestStep`), so `canProvide` cannot see the provide and
  their `context.exports` declarations carry the declared-but-unbackable warning. Warning-severity,
  nothing gates on it, and the raw open is the point of those fixtures — but it is exactly the shape
  the §5.2 plugin guidance (`ContextProvider` mix-in) exists to prevent. Left as-is deliberately;
  making the archetype declare `provides` would change what the fixtures pin.
- **`js-architecture.md`'s badge inventory was widened** from three skins to four (the RunStep
  hosted-export chip is filled + dotted), since the change made the existing sentence incomplete.
