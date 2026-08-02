# CX — context generalization: a design-space exploration

> **Status: ratified design exploration; §5 is the execution sequence, while Phase 8 remains a gate.**
> Written 2026-07-31, two days after CTX and
> CTX2 landed, on the user's first sustained use of the feature. Its job is to map the space and
> **argue for a position on each axis**, so that the sessions it spawns start from settled intent
> rather than re-deriving it. Anchors captured against kzen-auto `3639ffb5` / kzen-lib `9be12e7` —
> **re-locate by symbol, not by line number** (standing rule; the 2026-07-22 `RestHandler` split is
> the cautionary case).
>
> **Revised 2026-07-31 after review — see §1.1 (P9).** The first draft treated scoped disposal as a
> *kind of* Context. It is not: ambient binding and scoped disposal are orthogonal features that
> compose. The correction invalidated four verdicts — C2 (`Resource` / `Value` archetypes), N3 (step
> verb `opens:`), the borrow mechanism in §3 E, and the phase list — all of which are recorded as
> withdrawn in §6 rather than deleted, because the draft's failure mode is instructive.
>
> **Decisions the user took before drafting**, not to be re-litigated: the shipped CTX2 notation may
> be **reshaped freely** provided each proposal is marked additive vs breaking; user-authored
> contexts live in a **new "Contexts" document type**; naming and auto-wire depth were delegated to
> this document to argue and recommend.
>
> **Revised again 2026-07-31, second review pass — historical; superseded by the fourth.** Walking the
> user's "open a browser, bind it, use it, let scope close it" scenario first exposed the anonymous-
> disposal/export hazard and the two-`bind`s collision. That pass tried to contain the hazard with a
> partial provenance check and closer idempotence; the fourth pass rejects both as safety boundaries
> and defers the decomposed managed-resource form until provenance is structural (§3 C.6).
>
> **Third pass, same day.** Walking "two browsers at once, plus a generic driver" narrowed
> `RunStep.contexts` to a **declaration** source (§3 E.1 — the step-location form does not survive a
> second hop), reframed §3 J as the enabler for ***parallel*** multi-instance work, and added §4.7.
> §3 K records what keeps a future static flow overlay possible — explicitly **not** planned.
>
> **Fourth pass, 2026-08-01 — semantic hardening after review.** The prior draft still used
> "identity" for three different things (the nominal declaration, its value type and its engine key),
> made declared qualifiers exact in analysis while keeping exports family-wide at runtime, collapsed
> a missing binding with a present `null`, and described call-site binding as a normal child-frame
> `bind` even though the host API has no way to install one before the child runs. This pass separates
> those layers (§3 A), introduces exact-vs-family export selectors and presence-preserving lookup
> (§3 A.3), replaces the speculative 2 × 2 lifecycle account with an event table (§3 C.4), defers
> cross-step managed-resource handoff until disposal provenance is structural (§3 C.6), and makes
> `RunStep.contexts` atomic child bootstrap data with explicit type and migration rules (§3 E). The
> user ratified the nominal auto-wire verdict (§3 B) and N4 naming (§3 G) in requesting this pass;
> §3 J is narrowed from a pre-approved lift to a parallel-flavour design gate.
>
> **Concurrent ≠ parallel, and this document conflated them once already.** Two live browser sessions
> driven by interleaved steps *is* concurrency, and a Script does it today; what a Script cannot do is
> drive them in **parallel**, which is a Job. The first version of §3 J said "a Script cannot drive
> two browsers concurrently" — which would send an author to a Job for something they already have.
> Both words appear throughout; each is meant literally.
>
> **Relationship to prior art.** CTX (`next/context-and-resource.md`) and CTX2
> (`next/context-moved-ownership.md`) remain the authority on ownership direction — provider-offered
> export chains and bind-time resting frames. This pass refines two details they could not express:
> declared qualifiers export exactly rather than through an unconditional family wildcard, and the
> three settlement policies are specified by an event table rather than described as one disposal
> axis. The fused `resource(…)` primitive becomes a binding plus an optional attached disposal, with
> the composed form reproducing today's behavior. CTX2 §1.1's rejection of consumption inference is
> **reaffirmed and generalized** in §3 F.
>
> Executor: Opus-class, one session per phase (§5). Phase 1 is independent of every verdict below
> and can ship immediately.

## 1. What is actually wrong

The model works. The complaint is that it is **too narrow and too opaque** — and one of the four
symptoms is a plain defect.

| | Finding | Anchor |
|---|---|---|
| **P1** | **Defect: the abstract base leaks into the picker.** `ContextConventions.allContexts` maps every graph object through `descriptorOrNull` → `isContext`, which tests `graphNotation.inheritanceChain(location)` for membership of `Context`. `buildInheritanceChain` adds *the object itself* first (`builder.add(objectLocation)` before recursing into parents), so the archetype matches its own filter. That is the meaningless third option in the dropdown, and it is why the concept reads as broken before anyone has understood it. | `ContextConventions.isContext` / `allContexts`; `GraphNotation.buildInheritanceChain` |
| **P2** | The picker renders `descriptor.label()` and nothing else. `ContextDescriptor` already carries `description` and `valueClass`, both read from notation and both discarded. So "SUT" and "Browser" arrive with no explanation of what they *are*. | `ContextSignatureEditor.renderPicker`; `ContextDescriptor` |
| **P3** | **One row multiplexes two orthogonal contracts through a Role dropdown.** Parameters owns a row; Result owns a row; the document's inbound and outbound context contracts share one, behind a modal choice you must make *before* you can name the thing you want. | `ContextSignatureEditor` companion `roleOptions`; `ScriptController.renderSignature` |
| **P4** | **No in-app authoring surface.** Discovery is genuinely open — `allContexts` is a graph scan with no enum anywhere — but every shipped Context lives in framework YAML (`script-jvm.yaml`, `script-test.yaml`), and `Context` is not a `Prototype`, so the Custom document's structured editor cannot reach it either. The set is not fixed in code; it is fixed by *who can write YAML*. | `script-jvm.yaml` `BrowserContext`; `script-test.yaml` `SutContext`; `CustomConventions.listPrototypes` |
| **P5** | **Nothing inside a Script can provide anything.** `provides:` is pinned on step archetypes (`BrowserOpenStep`, `StartKzenAutoStep`), so a value a `FormulaStep` computed cannot enter the ambient scope. Note what this is *not*: `ContextProvider.provides` is already `nullable`, `by: Nominal`, defaulting `""`, so a per-instance choice is **already legal notation**. There is simply no step that exposes it. | `script-jvm.yaml` `ContextProvider` |
| **P6** | **Qualifiers are runtime-only.** `StepExecution.provideContext(…, qualifier)`, `contextValue(…, qualifier)`, `releaseContext(…, qualifier)`, the engine key `"$key:$qualifier"` and the family gate `hasResourceInFamily` are all shipped and working. Notation, static analysis and UI are entirely blind to them. So "two SUTs in parallel" is expressible only by threading a qualifier through step parameters, unanalyzed and invisible. | `StepExecution.provideContext`; `ScriptRunContext.resourceKeyOf`; logic-spec §6 |
| **P7** | **The runtime address is a hand-written global string, while the declaration's type is barely enforced.** `key` is free-form and globally namespaced; the aliasing hazard is carried deliberately and surfaced as a warning. `class:` is the value contract, but only the reified `contextDescriptor<T>()` disambiguator consults it. The nominal object, value contract and engine address are three real layers currently described as one "identity". | `common-document.yaml` `Context`; `StepExecution.contextDescriptor` |
| **P8** | **Only `Script` declares `context`** — not `Logic`. CTX2 recorded this as an accepted consequence (a resource opened inside a hosted Flow/Job is permanently private, because the climb consults each frame's own declarations and those flavours have none). Under a general ambient-value mechanism it stops being a corner case. | `common-document.yaml` `Script.context`; CTX2 §2 |

**P1 and P2 are shippable defects.** Fix them independently of everything below — they are the
difference between "this concept is broken" and "this concept is narrow", and only the second is
worth a design document.

### 1.1 · P9 — the structural finding: two features wearing one name

The seven above are symptoms. This one is the shape of the thing, and it was identified in review
after the first draft of this document had already built on top of the confusion.

**Ambient binding and scoped disposal are orthogonal features.** The point of a Resource is safe
teardown; the point of a Context is that descendants can find a value by name. A resource can be
created, used and disposed without ever touching the Context system — and *any* object can travel
the Context system whether or not it needs disposing: a String, an Int, a domain object, a browser
handle. The two must **compose**, and they are not the same feature.

kzen fuses them, and the engine signature is the proof:

```kotlin
fun resource(key: String, policy: ClosePolicy, value: Any? = null, closer: () -> Unit)
```

**`value` is optional.** The primitive's own declaration concedes that it is a *disposal
registration that may incidentally carry a value*. The consequences are exactly symmetrical, and
both are bad:

- **To get frame-scoped teardown for something nobody reads** — a temp file, a lock, a spawned
  helper — you must invent a **globally-namespaced key** purely to obtain a `finally`.
- **To pass a String down a subtree** you must pretend it is disposable: a policy that means nothing
  and a no-op closer.

It propagates outward from there. `ContextProvider` fuses `provides` and `closePolicy` into one
mix-in, so a step cannot have either half alone. `ResourceClosePolicy`'s own notation comment defines
the *owner* in terms of `context.exports` — disposal semantics specified by a scoping mechanism. And
the engine calls the whole subsystem "Resources" (logic-spec §6) while notation calls it "Context".

**Why they fused, which is worth stating because it is not an accident.** Handing ownership of
something upward requires that someone up there be able to *name* it. So the moment a resource must
outlive its opener, it needs a key — and disposal gets dragged into the naming namespace. That is a
real dependency in one direction only, and §3 C turns it into a stated rule rather than a fusion.

This finding rewrites §2, §3 C, §3 D, §3 E, §3 G and §5. It is why C2 (a `Resource` / `Value`
archetype split) was **withdrawn**: two skins on one mechanism is the same error one level down.

## 2. The reframe

Two sentences carry the whole proposal, and the second is the one P9 forced:

> **A Context is a typed, optionally-qualified ambient binding.**
>
> **A Resource is a closer registered against a frame. It is not a kind of Context.**

Everything asked for falls out of taking the first literally instead of treating `class:` as a
comment, and of refusing to let the second hide inside it.

| Today | Reframed | Break? |
|---|---|---|
| `key:` — free string, global namespace, aliasing warned about | the **runtime address family**; optional interop alias, otherwise derived from the canonical full `TypeMetadata` | breaking |
| `class:` — documentation, read by one helper | `type: TypeMetadata` — the binding's value contract, deliberately **not** its nominal identity | breaking |
| Context object / type / engine key described interchangeably as "identity" | three explicit layers: **nominal declaration** (`ObjectLocation`) · **value contract** (`TypeMetadata`) · **runtime address** (`ContextKey`) | clarification |
| qualifier — runtime only | first-class notation attribute. **Declared** qualifiers resolve and export by exact key; **computed** qualifiers use an unqualified declaration and family selectors | additive |
| **one primitive registers a disposal that may carry a value** | **two primitives: `bind` (naming, scope) and `onSettle` (teardown, no key). A managed resource is their composition** | breaking |
| a Context declaration implies a lifecycle | **a Context declaration has no lifecycle axis at all** — disposal is a claim a *step* makes about the value it produced | breaking |
| `resourceValue(key): Any?` — missing and present-null collapse | presence-preserving exact lookup (`BindingLookup`) plus an explicit family-presence query | breaking |
| declared in framework YAML by whoever can write YAML | declared in a **Contexts document** — *plus* anywhere, discovery unchanged | additive |
| provided only by plugin-authored steps | plus a generic **Bind / Use / Release** step triad | additive |
| a callee reads whatever is ambient | plus **call-site binding** on `RunStep` — the caller supplies the callee's ambient dependency per call | additive |

Read the original examples against that table. *"A String qualified with some tag"* is one nominal
declaration whose value contract is `kotlin.String` and whose runtime address is the derived String
family plus the tag — no code, **and no pretence that it is disposable**. *"Two SUTs in parallel"*
is either two declared qualifiers (statically distinct) or one call-site binding per call
(dynamically distinct). And a temp file that must be deleted at frame settle but that nobody ever
reads becomes expressible for the first time — it needs no name, so it takes no key.

## 3. The axes

### A · Identity — separate the symbol, contract and runtime address

The earlier draft asked one question — "what makes two declarations the same slot?" — and then used
the answer for three different layers. They need names of their own:

| Layer | Domain value | Meaning |
|---|---|---|
| **Declaration identity** | `ObjectLocation` | The nominal symbol notation references. Rename-refactor, dangling tolerance, title/icon/description and picker identity live here. Two declarations are two authoring concepts even when they deliberately interoperate at runtime. |
| **Value contract** | `TypeMetadata` | What may be bound: class, generics and nullability. It filters editors and drives static/runtime conformance checks. It is not a lookup key. |
| **Runtime address** | `ContextKey(family, qualifier?)` | Where the frame registry stores the value. The family defaults from the canonical **full** `TypeMetadata`; an explicit `key:` replaces the family as a stable raw/plugin interop alias. |

That yields the revised option table:

| | Option | Verdict |
|---|---|---|
| A1 | Free-string `key` is declaration identity, value contract and runtime address (today) | superseded |
| A2 | Type alone is identity | ✗ — two databases can share one type, and B1 remains nominal |
| A3 | `(type, qualifier?)` is called the identity, with `key` overriding it | ✗ — neither the nominal layer nor the overrideable runtime layer actually obeys that claim |
| A4 | `ObjectLocation` is also the engine key, with no public alias | ✗ — structurally safe, but severs the raw/typed interop logic-spec §6 makes load-bearing |
| A5 | **Nominal declaration + typed value contract + separately-derived runtime address** | **✅** |

**Why A5.** B1 says a consumer names a Context object, so that object is the authoring identity.
Calling `(type, qualifier)` the identity while keeping nominal references would make the same concept
structural in prose and nominal in the actual graph. An explicit `key:` then broke the claim a second
time by changing what aliases at runtime. A5 does not remove either useful behavior; it gives each a
name that stays true.

The default family is derived from a canonical qualified rendering of the **whole** `TypeMetadata`,
not merely `className`: nested generic arguments and nullability participate. Therefore
`List<String>` and `List<Int>` do not silently share a default address. Framework and plugin Contexts
that promise raw interop keep explicit short aliases (`browser`, `sut`, `db`). Ordinary user notation
types no key at all.

Two declarations may still resolve to the same exact `ContextKey`: either they have the same default
type + qualifier or they deliberately share an explicit alias. They remain distinct nominal symbols
but are runtime aliases, and the graph-wide exact-key warning says so. This is no longer described as
an identity paradox; it is the explicit interop escape hatch.

#### A.1 · Strings do not go away — their management is outsourced

Scala implicits, Kotlin context receivers and DI containers do not eliminate runtime keys. Ask any
of them for two databases and they manufacture a nominal discriminator: a tagged type, wrapper type
or qualifier annotation. A DI registry still keys a map on `(Class, Annotation)`; it merely derives
the address rather than asking every consumer to type it.

A kzen Context declaration is the corresponding nominal entity, `TypeMetadata` is its representation
contract, and `ContextKey` is the derived registry address. The benefit is not a paradigm change. It
is that ordinary notation delegates string bookkeeping to the type model and the declaration picker,
while the few raw/plugin boundaries that genuinely need a public string declare one deliberately.

#### A.2 · Three tiers of string, and only one is authored routinely

| Tier | Example | Who manages it | Rule |
|---|---|---|---|
| **1 · Runtime family** | canonical `kotlin.String`, or explicit `browser` | derived from full `TypeMetadata`; explicit only at an interop boundary | Duplicate **exact keys** warn graph-wide; same family with different declared qualifiers is legitimate |
| **2 · Declared qualifier** | `primary` / `reporting` | one Context declaration per member, selected nominally | Never typed at a use site |
| **3 · Computed qualifier** | tenant id inside a loop | inherently dynamic | Allowed only with an **unqualified** declaration; runtime gate/export is family-granular |
| *(escape hatch)* | raw `openResource("browser")` | hand-managed, deliberately | Stable public string is its job |

An ordinary author picks a Context object. Rename-refactor propagates and a typo becomes a dangling
reference rather than a silent miss. The only routine free string left is a computed map-like key,
which no static declaration system can enumerate honestly.

#### A.3 · Domain types, exact-vs-family export and presence-preserving lookup

The key belongs to **binding**, not disposal. `Execution` is otherwise a codebase of identifier
wrappers, yet its resource surface accepts structured strings and re-parses them ad hoc. Introduce
the house-shaped `ContextFamily` and `ContextKey` types (data classes, validated constructor,
companion parser; not `@JvmInline`). Both family and qualifier are non-empty and may not contain the
qualifier delimiter.

Two more domain types close semantic holes the prior draft left open:

```kotlin
sealed interface ExportSelector {
    data class Exact(val key: ContextKey): ExportSelector
    data class Family(val family: ContextFamily): ExportSelector
}

sealed interface BindingLookup {
    data object Missing: BindingLookup
    data class Present(val value: Any?): BindingLookup
}
```

`ExportSelector` is necessary because declared qualifiers and computed qualifiers have different
knowledge. A qualified declaration exports `Exact(key)`; an unqualified declaration that admits a
computed qualifier exports `Family(family)`. Without that distinction, notation could say "export
Browser A", analysis would credit only A, and a family-wide engine declaration would silently carry
Browser B too. Exact-vs-family is one semantic all three layers now share.

`BindingLookup` is necessary because a `TypeMetadata(nullable = true)` Context may validly bind
`null`. `bound(key): Any?` cannot distinguish that from no binding. The exact presence gate is also
what a declared qualifier should use; family presence remains only for the computed-qualifier path.

The resulting engine surface is:

```kotlin
fun declareExport(selector: ExportSelector)
fun bind(key: ContextKey, value: Any?, disposal: FrameDisposal? = null)
fun binding(key: ContextKey): BindingLookup
fun hasBinding(key: ContextKey): Boolean
fun hasBindingInFamily(family: ContextFamily): Boolean
fun releaseBinding(key: ContextKey) // removes the nearest binding; runs attached disposal at most once

fun onSettle(policy: SettleDisposalPolicy, closer: () -> Unit) // anonymous; no key
```

`ContextFamily` remains a distinct type because `hasResourceInFamily(family: String)` today accepts
a fully-qualified key and silently returns false. `ExportSelector` replaces the previous proposal to
make `declareExport` family-only; tightening it that way would have invalidated exact declared
qualifiers before they shipped.

**Resolution rule.** A Context descriptor with a declared qualifier always resolves to that exact
key. Passing an additional runtime qualifier with it is an error, not an override or concatenation.
A computed runtime qualifier is legal only against an unqualified declaration and resolves within
its family. This removes the otherwise-undefined "declared plus computed qualifier" combination.

**Scope.** The `Execution` methods and `RunEngine` registries; `NodeRuntime.exports` becomes a set of
selectors; `StepExecution`'s raw and typed surfaces; `ScriptRunContext.resourceKeyOf`; Script
declare-and-gate calls; `JobRun`'s `job-scratch`; and the migration carrier. Phase 2 keeps deprecated
composed adapters long enough to migrate kzen-auto in the same release train, then removes them only
after the composed behavior is covered by the old resource tests.

#### A.4 · Declared qualifiers should be pickable, not free text

Each statically distinct member is its own Context declaration sharing a family alias where raw or
family operations need one. `Primary Db` and `Reporting Db` are therefore nominal picker entries,
not values in a second qualifier enum. The declaration carries `qualifier:` once; `binds:` / `uses:`
references never carry it.

Free-text qualifiers survive only for the tier-3 computed case and require an unqualified Context
declaration. Static analysis and runtime gates use the exact key for declared members and the family
only for computed members. This is one rule at every layer, not an exact static fiction over a
family-wide runtime.

### B · Addressing — the "auto-wire" question

This is the sharpest fork in the document, so it gets the most argument.

| | Option |
|---|---|
| B1 | **Nominal** — a consumer references the Context *object*: `requires: [BrowserContext]` (today) |
| B2 | **Structural** — a consumer names a shape: `requires: [{type: org.openqa.selenium…RemoteWebDriver, qualifier: main}]`, resolved to the unique matching declaration; ambiguity is an error listing the qualified alternatives |

**Verdict: B1 stays primary. B2 is deferred with a recorded reopening trigger** — a third-party step
that must not name a first-party Context.

Four reasons, in descending weight.

1. **Notation has no class hierarchy.** `NotationMetadataReader` reads `class:` as an opaque string;
   `GraphNotation` models inheritance between *notation objects*, not between JVM classes. So
   structural matching in `commonMain` — which is where the analysis and the editor both live — can
   only ever be **exact-class**. A plugin declaring `type: WebDriver` would silently fail to match a
   Context declaring `RemoteWebDriver`, which is the single most likely thing a plugin author would
   write. Fixing it with server-side reflection would make the server's analysis disagree with the
   client's, and a validation surface that disagrees with itself is worse than either half.
2. **The precedent already in the tree argues the same way.**
   `StepExecution.contextDescriptor<T>()` *is* structural resolution — by `valueClass`, exact-match
   — and it works because it is **scoped to the step's own declared set**. Structural resolution is
   sound as a *disambiguator within a declaration*, and shaky as a *global lookup*. B2 is the second
   thing; the shipped helper is the first.
3. **Nominal buys things structural cannot.** `by: Nominal` weak references give rename-refactor
   propagation (rename `BrowserContext` and every `requires` follows — there is a regression test,
   `ContextRenameTest`), dangling-tolerance (a broken reference degrades to a validation message
   instead of failing the referring object's definition), and a place to hang `icon` / `title` /
   `description` so the picker and the chips can be legible. Structural buys decoupling, and only
   decoupling.
4. **Axis A now makes the layering explicit.** The Context object is the nominal symbol and
   `TypeMetadata` is its value contract. B2 would make the contract a second, global addressing
   mechanism alongside the symbol, with weaker subtype knowledge and none of the symbol's refactor
   behavior. That is a real paradigm addition, not a cheaper spelling of B1.

**Ship the cheap middle instead.** Where a consumer has a declared type constraint, the **editor**
filters picker candidates by it — the affordance B2 was reaching for, with none of the resolution
semantics. Exact `TypeMetadata` matches are available in `commonMain`; assignable-but-not-equal
matches remain visible and are verified server-side by the existing Kotlin-compiler-backed
`TypeAssignability`. That is editor guidance and validation, not an addressing mode.

### C · Lifecycle — and why it is not an axis of Context at all

| | Option | Verdict |
|---|---|---|
| C1 | Uniform: every Context is a closable resource with a `closePolicy` (today) | ✗ — the P9 conflation |
| C2 | Two concrete archetypes, `Resource` and `Value`, both `is: Context` | ✗ **withdrawn** — two skins on one mechanism is the same error one level down |
| C3 | One archetype with a `closable: true` flag | ✗ — same fusion, expressed as a boolean |
| C4 | **Disposal is a separate feature. `Context` carries no lifecycle attribute; a step declares teardown for the value it produced, independently of whether it binds it** | **✅** |

**Why C4.** C2 was drafted before P9 and is wrong for the reason P9 gives: it keeps *every* disposal
routed through the naming namespace and *every* binding carrying a lifecycle slot, and merely varies
the editor. Under C4 the two features exist separately and compose in one stated place.

#### C.1 · The two primitives

**Context — ambient binding.** *What values are in scope here, under what name and type?*
Bind at a frame; reads walk self → parent → … → root; one binding per key per frame, so a nearer
binding shadows a farther one; re-binding supersedes. Exact lookup preserves the difference between
`Missing` and `Present(null)`. **No disposal semantics whatsoever.** Every §6 property that is about
*finding* a value survives here unchanged.

**Resource — scoped disposal.** *What must be torn down, and when?* Register a closer against a
frame with a policy; it runs when that frame settles. **No key, no namespace, no lookup** — anonymous
is the common case and is currently inexpressible.

```kotlin
// Ambient binding. `disposal` is the deliberate managed-binding composition — C.2.
fun bind(key: ContextKey, value: Any?, disposal: FrameDisposal? = null)
fun binding(key: ContextKey): BindingLookup
fun hasBinding(key: ContextKey): Boolean
fun hasBindingInFamily(family: ContextFamily): Boolean
fun declareExport(selector: ExportSelector)
fun releaseBinding(key: ContextKey)

// Scoped disposal, standalone: frame-local, anonymous, no key.
fun onSettle(policy: SettleDisposalPolicy, closer: () -> Unit)
```

`FrameDisposal` carries the one-shot closer plus the managed-binding settlement choice parsed from
notation (`Auto`, `Manual`, `KeepOnFailure`). The awkward fact that `Manual` is a promotion action
rather than a disposal policy is contained in that domain type and spelled out by C.4; anonymous
`onSettle` uses the smaller two-valued `SettleDisposalPolicy`.

Three call shapes, where today there is one:

```kotlin
execution.bind(basePathKey, "C:/work/inbox")                    // a value, not pretending to close
execution.onSettle(SettleDisposalPolicy.Auto) { tempFile.delete() } // a finally, not pretending to be named
execution.bind(browserKey, driver, FrameDisposal.auto { driver.quit() }) // both, deliberately
```

**`onSettle` takes only `Auto` and `KeepOnFailure`.** `manual` needs a named binding to promote and is
therefore not an anonymous-disposal policy — C.4.

**At-most-once is an engine guarantee, not a plugin aspiration.** `FrameDisposal` owns a one-shot
state transition under the engine lock. Supersession, explicit `releaseBinding` and frame settle all
invoke the same `disposeOnce`; only the winner calls third-party code. A closer must still capture its
own handle rather than resolve by name, and should tolerate the *external resource* already being
gone, but the engine never deliberately invokes one registration twice. Swallowing a second failure
after performing a side effect is not a substitute for this invariant.

An anonymous `onSettle` registration is likewise invoked at most once by the engine. It has no
generic early-release operation because it has no name; a use case needing early release is a managed
binding or, in future, an explicit lease (§3 C.6).

#### C.2 · The composition rule, enforced by API shape rather than by discipline

When a bound value is *also* a resource, its disposal must be owned **at or above** its binding
frame — otherwise a descendant can read a handle that has already been closed. Making `disposal` a
**parameter of `bind`** rather than a separate call makes that structural: an attached disposal
cannot be given a frame different from the binding's, because it is never independently placed.

Rebinding the same key releases the displaced managed binding through `disposeOnce` before the new
one becomes observable outside the lock. Releasing an unmanaged binding only removes the name;
releasing a managed one also runs its attached disposal exactly once. That is why the user-facing
verb remains `ReleaseStep`, not `UnbindStep` (§3 D).

This is what the fused engine already guarantees for managed resources. The split adds the two
standalone forms without weakening the composed one.

#### C.3 · Which feature owns the export chain — Context, and this makes it cleaner

`declareExport` decides **which frame a binding lands on**. That is a *scoping* question, so it
belongs to Context; disposal inherits the resting frame as a consequence of C.2 rather than as a
definition. A qualified declaration contributes `ExportSelector.Exact`; an unqualified declaration
used with computed qualifiers contributes `ExportSelector.Family`. The export climb and the static
analysis consume the same selector, so one declared member never moves its siblings accidentally.
Two things improve:

- `declareExport`'s contract stops mentioning ownership or disposal at all — "a binding of this
  family made here or below climbs past this frame" — and the Rust analogy gets *better*, not worse:
  a return move is about where a value lives, and drop follows.
- **Anonymous disposal has no export chain, ever.** It is always frame-local. That is exactly P9's
  "why they fused" turned into a rule: *ownership transfer requires a binding, because handing
  upward something nobody can name is meaningless.* If you want a closer to outlive its frame, give
  the value a name — and then the existing chain carries it.

#### C.4 · `manual` is a managed-binding settlement action, not an anonymous close policy

The previous pass called `manual` "`auto` + `survives`" and drew a 2 × 2. That is elegant and false at
the root: a surviving binding has no later frame whose automatic settle fires, so the disposal axis
is masked rather than independent. Encode the real state machine instead of forcing it into a product.

Keep `auto` / `manual` / `keepOnFailure` as the notation surface for a **managed binding**, and make
the engine behavior explicit:

| Event | `auto` | `manual` | `keepOnFailure` |
|---|---|---|---|
| Same-key rebind | release displaced binding + dispose once | same | same |
| Explicit `releaseBinding` | remove + dispose once | remove + dispose once | remove + dispose once |
| Non-root success/cancel | remove + dispose once | promote binding + disposal one frame | remove + dispose once |
| Non-root failure | remove + dispose once | promote binding + disposal one frame | retain binding + disposal on failed frame |
| Root success/cancel | remove + dispose once | retain without invoking disposal — forgotten-close behavior | remove + dispose once |
| Root failure | remove + dispose once | retain without invoking disposal | retain binding + disposal on failed root |
| Live-edit migration | carry with the stable owner; do not settle | same | same |

"Retain" must be real: the registration remains available to the run's inspection/explicit cleanup
surface. If Phase 3 finds that a terminal frame is compacted such that nothing can inspect or release
it, either add that surface or rename the policy; silently dropping the registration while keeping
the external process alive is a leak, not inspection.

For anonymous `onSettle`, only the two meaningful rows exist: `Auto` disposes on every terminal
outcome; `KeepOnFailure` disposes on success/cancel and retains on failure. There is no `Manual`
because no key exists for a later step to release.

#### C.5 · What this deletes

`ContextProvider` — which today fuses `provides` and `closePolicy` — splits into two mix-ins a step
composes as needed: **`ContextBinder`** (`binds:`) and **`ResourceOwner`** (`closePolicy:`).
`BrowserOpenStep` takes both; a step that binds a String takes only the first; a step that deletes a
temp file at settle takes only the second and declares no Context at all.

#### C.6 · Cross-step managed-resource handoff is deferred until provenance is structural

The previous pass proposed: one step opens a browser and registers anonymous disposal; another step
binds the ordinary driver value; a third uses it. That is mechanically possible and semantically
unsafe. If the binding exports, it climbs while the closer stays behind. A direct static guard can
spot `BindStep.value -> ResourceOwner`, but an expression step can launder the same handle and the
guard becomes advisory. A design whose safety depends on provenance must carry provenance.

**Do not ship that form in this arc.** The supported compositions are:

- `bind(key, plainValue)` — an unmanaged ambient value or explicit borrow;
- `onSettle(policy) { … }` — anonymous frame cleanup, with no value advertised for later binding;
- `bind(key, resource, FrameDisposal { … })` — a managed binding whose name and disposal move together.

`BrowserOpenStep` therefore stays fused as `ContextBinder + ResourceOwner`. No first-party
resource-only opener returns an ordinary handle for a later generic `BindStep`, and Phase 6 contains
no partial "do not export this direct source" guard presented as a safety boundary.

**Reopening trigger:** a real need to assemble a managed resource across steps. The required concept
is an explicit lease/managed-value token carrying both the value and a one-shot disposal handle
through the value graph. `BindStep` could then adopt the token structurally and transfer its disposal
with the binding. Reference-identity adoption (`onSettle(subject)` and search by `===`) remains
rejected as action at a distance.

### D · Provision — how a value gets into the scope

| | Option | Verdict |
|---|---|---|
| D1 | Step archetypes pin `provides:` (today; `binds:` after N4) | keep — it is right for typed plugin steps |
| D2 | **A generic `BindStep`**: `binds:` (Context picker) · `value` (a reference to a prior step, or a Kotlin expression as `FormulaStep` does) · `qualifier` (optional) | **✅** |
| D3 | **A generic `UseContextStep`** — reads a Context into the value graph so `FormulaStep` / `DisplayValueStep` can consume it by reference | **✅** |
| D4 | **A generic `ReleaseStep`** — removes the nearest binding and invokes its attached `FrameDisposal` at most once; for a plain/borrowed binding there is no disposal, so it is simply removed | **✅** |
| D5 | A document-level "provides to descendants" declaration, with no step | ✗ — nothing to bind; the value has to come from somewhere |

**Why the triad, and why it is small.** P5 showed the notation already permits an instance-level
`provides:`. So D2 is a step class, an archetype, and a picker — and `BrowserGetStep` is already
D3-for-browsers, so D3 is a generalization of shipped code, not new machinery. The picker is a
`SelectContextEditor`: a sibling of the existing `SelectObjectEditor` sourced from
`ContextConventions.allContexts` rather than from local objects + Custom-document exports (which is
why the existing one cannot be reused as-is — framework Contexts are neither).

Together the triad is what makes contexts usable **without writing a plugin**, which is the actual
distance between "a fixed set of three" and "anything can be provided".

**Note what C4 removed from D2.** The draft gave `BindStep` a `closePolicy` shown conditionally on
the Context being a `Resource`. It has none: binding a value says nothing about disposing it. A step
that wants both composes the two mix-ins (§3 C.5) and declares both — and a plain `BindStep` for a
String, an Int or a domain object never sees a close-policy control, not because the editor hides it
but because there is nothing to hide.

**A fourth generic step falls out, and it is new capability rather than generalization:** a
**`DisposeAtSettleStep`** wrapping `onSettle` — "delete this file / kill this process when the owning
frame finishes", with no Context, no key and no namespace entry. Currently inexpressible at any
price short of inventing a global key. Small, and the clearest single demonstration that the split
is real.

**Type is a contract on every typed binding surface, not only on `BindStep`.** Centralize the check in
the typed `StepExecution.bindContext` path used by generic and plugin-authored binders; the raw
`Execution.bind(ContextKey, Any?)` surface remains the deliberate unchecked escape hatch. Where a
source step exposes `TypeMetadata`, compare the full types statically/server-side with the existing
compiler-backed `TypeAssignability`. At runtime, validate nullability and the reified/raw class of the
actual value. JVM erasure means an arbitrary `List<*>` cannot prove its element types by inspection,
so do not claim that runtime checking validates nested generics; full generic conformance comes from
source metadata where available.

Skip the centralized check and a `String` bound to `BrowserContext` surfaces as a
`ClassCastException` inside `BrowserTargetStep`, several steps away from the mistake that caused it.
Treat conformance as part of the typed Context API, not polish on one generic step.

**Keep `BrowserOpenStep` fused.** It stays
`is: [ScriptStep, ContextBinder, ResourceOwner]` with one
`bind(key, driver, disposal)` call. That is the safe form for export and explicit release. The
decomposed resource-only opener is deferred by C.6 until the value graph can carry a managed-value
token; Phase 6 must not quietly reintroduce it as ordinary `Any?` plumbing.

### E · Call-site binding — the parallel-SUT answer

| | Option | Verdict |
|---|---|---|
| E1 | Thread a qualifier through step parameters; family-granular gate (today) | keep as the dynamic escape hatch |
| E2 | **`RunStep.contexts` — a per-call binding map**: `contexts: {SutContext: Sut A}`, mapping a callee slot to a Context declared in the caller's scope (source form settled in E.1) | **✅** |
| E3 | Call-site *qualifier* override rather than value override | folded into E2 |

**This is the highest-expressiveness item in the document.** It is conceptually small and requires
one real engine extension; it is not an ordinary `bind` call the caller can already make.

It is Kotlin's `with(…)` shape: the caller supplies the callee's ambient dependency **per call**, and
the sub-script stays entirely unaware — it declares `context: {requires: [SutContext]}` and is run
twice against two different SUTs without being edited. That is what "two SUTs in parallel" actually
needs, and no amount of qualifier plumbing gets there, because the qualifier would have to be
threaded through every step of the callee.

logic-spec §6 already supplies the lookup semantics: one binding per key per frame; reads walk self →
parent → … → root; a child-local binding shadows the caller's address. The missing capability is
**atomic child bootstrap**. `Execution.host` currently creates a `NodeRuntime` and immediately runs
the child; the caller never receives the child's `Execution`, so it cannot safely call `bind` between
those operations.

Extend the host boundary instead:

```kotlin
data class InitialBinding(val key: ContextKey, val value: Any?)

suspend fun host(
    stableId: ObjectStableId,
    child: Logic,
    inputs: TupleValue = TupleValue.empty,
    callerStableId: ObjectStableId? = null,
    retainTrace: Boolean = true,
    initialBindings: List<InitialBinding> = listOf()
): TupleValue
```

The engine installs all initial bindings on the new node under the same lock that publishes the
node, before `Logic.run` can observe it. They are plain borrowed bindings with no disposal. On a
live-edit rebuild they are reconstructed from the caller's **current** source bindings; they are not
migration-owned resources. Any locally-owned binding adopted for the rebuilt child keeps its prior
stable owner and supersedes a same-key bootstrap value, matching same-frame rebind semantics. Own
fixtures must pin that ordering.

The no-op closer from the first draft disappears: a borrow is genuinely `bind(key, value)` with no
disposal. That corroborates the Context/Resource split, but it does not make the host change free.

**Consequences to state rather than discover.**

- A `Release` step *inside* the callee finds the borrow first and unbinds it. Because the borrow
  carries no disposal, nothing is closed — "stop borrowing", exactly and without ambiguity. Under
  the fused model this had to be argued; under the split it is what the types say.
- The analysis must count a call-site binding as satisfying the callee's `context.requires`, or
  every parameterized call site lights up red. `LogicContextAnalysis.analyzeRunStep` is already the
  cross-document rule and is where this lands.
- Resolving the source uses `BindingLookup`: `Missing` is a named RunStep failure, while
  `Present(null)` is accepted only when the target Context is nullable.
- Source `TypeMetadata` must be assignable to target `TypeMetadata`. Exact checks and editor filtering
  run in common code; the existing server-side `TypeAssignability` admits real subtypes such as
  `RemoteWebDriver -> WebDriver`; the runtime target check remains definitive for values whose source
  type is unknown. Nested generics are checked from metadata, not by inspecting erased runtime values.
- A borrow does **not** transfer or extend ownership. Structured `host` guarantees the caller frame
  outlives the child, which is sufficient for sequential Script calls. A future parallel flavour must
  forbid or coordinate a sibling explicitly releasing the source while another child borrows it;
  Phase 8 owns that gate rather than pretending a copied reference is a lifetime proof.

#### E.1 · What the map's *source* side names — and why the draft's answer does not generalize

`contexts: {<callee slot>: <source>}`. The target is settled: a Context the **callee** declares. The
source was written as a **step location** (`main.steps/Start A`) and that is too narrow.

| | Source | Verdict |
|---|---|---|
| E-s1 | A step in the caller — "pass whatever that step bound" | ✗ as the primary form |
| E-s2 | **A Context declaration in the caller's scope** — "wire my `Browser A` into your `Browser`" | **✅** |

**The argument is compositional, and one hop hides it.** At depth one the caller always has a local
step that produced the value, so E-s1 looks sufficient. At depth two it stops being true: the value
the caller wants to forward may have arrived through its *own* caller's `contexts:` binding, or down
an export chain from a document it never names. **There is no local step to point at**, and E-s1 has
nothing to write. E-s2 has the ordinary answer, because a declaration is exactly the thing that is in
scope regardless of how the value got there.

E-s2 is also the better shape for everything else in this document: it is a `by: Nominal` weak
reference like every other Context reference (rename propagation, dangling tolerance), it is
resolvable by the same picker, and the static analysis reads one kind of edge instead of two.

**Keep E-s1 as sugar, not as the model.** "Pass what this step bound" is the concrete thing an author
means while building the first call site, and the editor can offer it — resolving it to the
declaration that step `binds:` at write time, so the notation stores E-s2. If a step binds a Context
under a qualifier, the sugar resolves to *that* declaration (§4.3's shape), which is why the two
mechanisms compose without either knowing about the other.

**The asymmetry is the feature.** The caller's world may hold two qualified declarations while the
callee's holds one unqualified slot; `contexts:` is a **mapping between namespaces**, not a shared
name. At runtime the source is read by its caller key and installed under the target's callee key;
the two keys need not match. That is what lets a generic sub-script stay generic — see §4.7.

### F · Inference

| | Option | Verdict |
|---|---|---|
| F1 | None; everything explicit (today) | superseded in ergonomics only |
| F2 | **Quick-fix affordances** — one-click chips that write the declaration | **✅** |
| F3 | Silent inference of the document signature from its steps | ✗ |
| F4 | **Single-attribute derivation** — for the generic steps, the one `binds:` / `uses:` attribute *is* the declaration; nothing is written twice | **✅** |

**The through-line, stated once and applied everywhere: inference is an affordance, never a
semantic.** CTX2 §1.1 rejected consumption inference for *ownership*; the same reasoning covers the
requires side, and one argument is decisive on its own — **`context.requires` is an assertion about
a caller**, and no analysis of this document can verify it. A signature you did not write is a
signature you cannot rely on.

What that leaves is pure usability, and it is worth taking. `LogicContextAnalysis.remedyFor` already
computes the fix for an unsatisfied `requires` and puts it in the error message; making it a button
costs a callback. Likewise, at a `RunStep` whose callee exports something the caller neither consumes
nor re-exports, offer "export it too?" — an **offer**, not a warning, because CTX2 settled that
provided-and-unconsumed draws no diagnostic and that verdict stands.

### G · Naming (delegated to this document)

**The trap first**, because it is why the obvious answer is wrong. A document signature carries two
outward facts —

1. *"a caller must already have supplied X"* (`context.requires`), and
2. *"what I open under X is handed to my caller"* (`context.exports`)

— while a **third** fact has no surface at all: *"I open X and keep it; my descendants can read it"*.
Label row 2 "Provides" naively and a reader takes it to mean fact 3, which is precisely backwards.
`Exports` is precise for exactly that reason, and CTX2 §8(e) chose it deliberately over `provides`.

| | Doc rows | Step verbs | Notation change |
|---|---|---|---|
| N1 | Needs / Exports | provides · requires · releases | none — UI split only |
| N2 | Requires / Provides | provides · requires · releases | `exports` → `provides`; **re-collides** with the step verb |
| N3 | Requires / Provides | opens · requires · releases | one rename: step `provides:` → `opens:` |
| **N4** | **Requires / Provides** | **binds · uses · releases** | three renames, plus `ContextProvider` → `ContextBinder` + `ResourceOwner` |

> **The verdict moved from N3 to N4, and P9 is why.** N3 chose `opens:` — which is **resource
> vocabulary applied to a binding**. A step that binds a String opens nothing. Once disposal is a
> separate feature the step verb must describe *putting a value in scope*, and `binds:` is the word
> that survives contact with a String, an Int, a domain object and a browser handle alike. The
> archetype split (§3 C.5) then carries the resource half under its own name, so nothing is lost.
>
> The second rename is worth stating separately: step `requires:` → **`uses:`**. A *document*
> `requires` something **from its caller**; a *step* `uses` whatever is in scope. Those are different
> claims, and giving them one word is the same overload the whole section exists to remove — so
> having argued it for `provides`, this document should not exempt itself. Document rows keep
> `context.requires` / `context.exports` unchanged.
>
> `releases:` keeps its name because the operation now does what the word promises: it removes the
> nearest binding and invokes any attached one-shot disposal. On a plain or call-site borrowed value
> there is no disposal, so release degenerates safely to unbind. If implementation ever chooses a
> remove-without-dispose operation instead, that separate operation must be named `unbind` and must
> not hide behind `ReleaseStep`.

**Keep N3's central move regardless — the precision goes on the chip, not the label.** The
**Provides** row renders two chip variants: solid-filled + an **Exported** arrow/badge for what is
handed to the caller (`context.exports`), plain-outlined + a **Private** badge for what is bound here
and kept private (derived from the document's own steps — `LogicContextAnalysis.ownStepProvides`,
currently `private` and needing to become `internal`). Do not encode the distinction in fill color
alone; tooltip and accessible text name it.

That resolves the trap without giving up the word. One word at the row level, precision at the chip
level — which is exactly how the step header already works, where
`StepHeader.renderContextDeclarations` distinguishes four claims by skin under no label at all. The
user gets the vocabulary they asked for; `exports` keeps its precise meaning where precision matters
(notation, spec, engine); the step verb becomes the concrete physical thing a step does; and
**"what does this script set up?" gets an answer for the first time.**

Keep the engine's `declareExport` unrenamed — engine vocabulary, not user-facing, and the ownership
semantic really is an export.

**Resolve one collision here rather than carry it.** `StepExecution` already has a
`bind(location, value)` that records a **step value** into the value graph
(`ScriptRunContext.kt:194` — re-locate by symbol). Adding `Execution.bind(key, value)` puts two
unrelated `bind`s on types that a single object implements. Rename the value-graph operation to
**`recordValue`**, which is already what its private `ScriptRunContext` counterpart is called. The
notation verb `binds:` and the engine verb `bind` then name the same ambient action, while recording a
step outcome has its own verb. This is cheap in Phase 4 and needlessly confusing forever afterwards.

**If notation churn is unwanted, N1 is the honest fallback**: split the rows, keep every word. It
delivers P3 alone and leaves the vocabulary confusion in place.

### H · UI shape

| | Option | Verdict |
|---|---|---|
| H1 | **Four floating rows**: Parameters · Result · Requires · Provides. The Role dropdown disappears, because each row's ⊕ adds into *its* role | **✅ now** |
| H2 | A unified collapsible **Signature panel** — one summary chip that expands into a form | **follow-on** |
| H3 | Two rows with chips grouped by role inside each | ✗ — keeps the ambiguity it was meant to remove |

**H1 now** because it is exactly what was asked, and because it costs almost nothing: the existing
`ObjectScopedComponent` base, the `ClientStateGlobal.Observer` wiring, the whole-map `UpsertAttributeCommand`
write path with its unrecognized-key carry-through, and the `StageErrorIndicator.reservedRowEm` offset
rhythm all survive unchanged. The load-bearing constraint also survives: each editor is emitted
**unconditionally** from `ScriptController.renderSignature`, so the step subtree's child index never
shifts.

**H2 recorded as the follow-on**, with an explicit trigger: the screenshot already shows a cramped
stack, H1 adds a fourth row to it, and the moment per-entry configuration arrives (a qualifier
override, a default, a call-site binding summary) four absolute floats stop scaling. Do not build H2
speculatively; build it when Phase 5 or 6 makes a row need more than a chip.

### I · Authoring — the Contexts document

Decided by the user; what remains is *what a declaration is*.

Model the document on **`ObjectRegistry`** — the closest precedent in the tree: a `Customize`-group
`is: Document` archetype holding a list of declarations, with a server document class and a
`DocumentController` registered in `*-js.yaml`. `DataFormat` is the same shape.

**The sub-fork that matters:**

- **I-a — keep `Context` abstract** (today's shape). Every declaration must carry `abstract: true`
  or `GraphCreator` tries to instantiate the `class:` it names. That is the exact trap CTX's as-built
  addendum records having hit, and pushing it onto an editor that writes declarations means the
  editor must remember to write `abstract: true` forever.
- **I-b — make a Context declaration a concrete object** carrying `type: TypeMetadata`, `qualifier`,
  and its presentation fields. **✅**

**Why I-b.** It reuses `TypeMetadataDefiner` and the type picker that `LogicSignatureEditor` /
`LogicTypeOptions` already provide, so `List<String>` tagged `rows` is expressible on day one and
participates in static source/target checks. Runtime inspection remains erased as §3 D states. It
removes the abstract hazard entirely. And it makes a
declaration the same shape as a `ParameterBinding`: a nested object with an `ObjectLocation`, so it
gets rename-refactor, reordering and per-entry editing from machinery that already exists. Discovery
is untouched (`inheritanceChain` still contains `Context`) and so are the weak-reference reads, so
`LogicContextConventions` and `LogicContextAnalysis` retain their nominal edges while gaining the
separate type-contract and runtime-key derivation from §3 A.

**The Contexts document is *an* authoring surface, not the only home.** Shipped contexts stay in
`script-jvm.yaml` / `script-test.yaml`; plugin contexts stay in plugin notation; the graph scan finds
all of them. What the document adds is a place a *user* can put one, and a form to write it with.

**Closing the loop on P4:** the picker gains a **"New context…"** entry that creates the declaration
in the project's Contexts document, creating the document on first use. That is the whole distance
between "the set is open in principle" and "the set is open in practice".

### J · Reach — a design gate before lifting `context` onto `Logic`

`context` and its `meta:` currently sit on `Script`. Moving them mechanically to `Logic` would make
Flow, Job and Report *appear* to carry the same contract, but their frame topologies are not the same.
Do not pre-commit the implementation before looking at each real executor.

Two syntactic checks are already favorable. `AutoConventions.isLogic` tests inheritance-chain
membership and is unaffected by `Logic` gaining attributes. The "`Logic` must not be `is: Document`"
constraint is about the sidebar's `AutowiredNominal` direct-`is` match and is likewise unaffected.
The semantic questions are the gate:

- Does the signature belong to the flavour's document root, to each worker/vertex invocation, or to
  both?
- Which frame receives a call-site `InitialBinding`, and can that frame ever outlive its owner?
- Are worker-local exact bindings isolated, and what does a family export mean across worker frames?
- What happens when one parallel sibling calls `ReleaseStep` while another still borrows the source?
- If several workers bind into a shared parent, is last-writer-wins intentional? The engine lock
  prevents a JVM memory race; it does not make the semantic winner deterministic or desirable.

Those questions may produce a common `Logic.context`, or may split into a root signature plus a
worker-level capability. Phase 8 decides that from the real Flow/Job/Report implementations and
writes the fixtures; implementation becomes a separately estimated follow-up after the verdict.

**Keep the two words apart, because they answer differently.** *Concurrent* means several resources
are live and making progress; *parallel* means several drivers execute simultaneously.

- **Concurrent multi-instance work is already a Script shape**, and needs nothing from J. Two
  browsers both hold live sessions while sequential steps interleave between them — §4.7.
- **Parallel driving is not.** Script has no fork and a `RunStep` awaits its child. Parallelism lives
  in Job, whose workers do not yet have a settled Context ownership or borrow model.

So J is the **gate** for the parallel case, not its implementation. Reading "a Script cannot drive
two browsers concurrently" would send an author to a Job unnecessarily; reading "move one attribute
and Jobs are safe" would make the opposite mistake.

### K · Space held for a static flow overlay (future work — deliberately not planned)

A resource-flow view overlaid on the document DAG rooted at a Logic document, computed **without
running it**, was raised and explicitly deferred. Nothing here schedules it. What follows is the
short list of properties that make it possible, recorded **so a later phase does not close the door
without noticing**.

- **The document signature is the abstraction boundary.** A DAG walk composes `context.requires` /
  `context.exports`, so it never needs to descend into a callee — including one whose steps come from
  a plugin. Any change that makes a document's contract depend on its internals breaks this.
- **The call edge is already static.** `ScriptConventions.hostedDocumentPath` resolves a RunStep's
  `instructions:` to a `DocumentPath` through `graphNotation.coalesce`.
- **The whole graph is the analysis input, on both platforms.** `LogicContextAnalysis.analyze` takes
  a `GraphNotation`; `canProvide` already reads a *hosted* document's exports and the signature editor
  renders that client-side. The one-level-deep limit is a stated cost decision — *"accepted rather
  than paid for with a whole-graph traversal"* — not a data limitation.
- **C.5's split is what makes the picture legible.** Binding and ownership are different graph
  shapes (one binding, many readers · one resource, one disposal point). While `ContextProvider`
  fuses them, any single diagram is a superposition of two questions. `ContextBinder` /
  `ResourceOwner` as separate predicates give two toggleable layers.
- **E.1's declaration-source keeps the edge set homogeneous.** One kind of reference to resolve
  rather than two.
- **C.6 keeps the ownership layer honest.** The arc does not draw a named edge from an anonymous
  disposal to an ordinary value, because no structural provenance exists yet. A future managed-value
  token would add that edge explicitly rather than asking the overlay to infer it from step adjacency.

Four things such a view could never resolve statically, which is a **presentation** requirement, not
a blocker: computed qualifiers (logic-spec §6 permits them, which is why the runtime gate is
family-granular), control flow (a bind inside an `If` branch or loop body is *possible*, and a loop
re-binds and supersedes per iteration), genuinely anonymous disposal (no name, by construction —
§3 C.4), and raw engine calls from plugin code (the raw/typed interop §6 makes load-bearing). The
sharp risk is that **a diagram reads as complete** in a way today's per-step warnings do not, so an
unsound picture would mislead more than unsound text.

**A cheap thing to take now that only exists because of this question:** give `DisposeAtSettleStep` an
optional human **label** (`"temp file cleanup"`) — a display string, not a key, introducing no
namespace and no lookup. It turns the disposal layer from unrenderable into readable, and it costs
one attribute.

## 4. Worked examples

### 4.1 "A String qualified with some tag"

The user's own example, end to end, with no Kotlin written.

```yaml
# Contexts.yaml — the new document type
main:
  is: Contexts

main.contexts/Greeting:
  is: Context
  type: { class: kotlin.String, generics: [], nullable: false }
  qualifier: greeting
  title: "Greeting"
  icon: "material-symbols:label"
  description: "The salutation the report header uses"
```

**Note what is absent, and that it is the point of §3 C.** No `Value` archetype (C2 was withdrawn),
no `closePolicy`, no lifecycle field of any kind. A Context declaration says *what this slot is
called and what type it holds*, and nothing about teardown — so a String needs no fiction to travel
through it.

Provider — computes a value and binds it, then hands it to its caller:

```yaml
main:
  is: Script
  context:
    exports: [Greeting]

main.steps/Compute:
  is: FormulaStep
  code: '"Hello, " + name'

main.steps/Publish:
  is: BindStep
  binds: Greeting
  value: main.steps/Compute
```

Consumer — declares the need, reads it into the value graph, uses it like any other step value:

```yaml
main:
  is: Script
  context:
    requires: [Greeting]

main.steps/Read:
  is: UseContextStep
  uses: Greeting

main.steps/Show:
  is: DisplayValueStep
  text: main.steps/Read
```

No `key` anywhere: `Greeting` is the nominal declaration, `kotlin.String` is its value contract, and
the runtime address defaults to `kotlin.String:greeting`.

### 4.2 Two SUTs, one unmodified test — call-site binding

*("In parallel" is the user's framing and the motivating case; the mechanism is per-call rebinding,
and the two calls run sequentially — §3 J on why a Script cannot do otherwise.)*

```yaml
main:
  is: Script

main.steps/Start A:
  is: StartKzenAutoStep
  binds: Sut A

main.steps/Start B:
  is: StartKzenAutoStep
  binds: Sut B

main.steps/Test A:
  is: RunStep
  instructions: "main/Login Test.yaml#main"
  contexts: { SutContext: Sut A }        # source is a DECLARATION — §3 E.1

main.steps/Test B:
  is: RunStep
  instructions: "main/Login Test.yaml#main"
  contexts: { SutContext: Sut B }
```

where `Sut A` / `Sut B` are two declarations sharing the `sut` family (§4.3's shape) that the two
`Start` steps bind. The editor may offer "pass what `main.steps/Start A` bound" as sugar and store
the declaration — §3 E.1.

At each RunStep the source is resolved first. The engine then creates the child frame and installs
the value under the callee's `SutContext` key **before** `Login Test` begins. The source and target
declarations may have different keys and qualifiers; their types must be assignable, and a missing
source is attributed to this RunStep rather than surfacing later inside the callee.

And `Login Test.yaml` is **unmodified and unaware**:

```yaml
main:
  is: Script
  context:
    requires: [SutContext]
```

### 4.3 Two databases — declared qualifiers

Statically distinct, so they are two declarations rather than two call-site bindings:

```yaml
main.contexts/Primary Db:
  is: Context
  type: { class: java.sql.Connection }
  key: db
  qualifier: primary

main.contexts/Reporting Db:
  is: Context
  type: { class: java.sql.Connection }
  key: db
  qualifier: reporting
```

A `Connection` does need closing — but that is declared by the **step that opens it**
(`is: [ScriptStep, ContextBinder, ResourceOwner]`, with its own `closePolicy`), never by the
declaration. Two consequences worth seeing side by side: the same declaration can be bound by one
step that owns the connection and by another that merely borrows one it was handed; and the
declarations above are byte-identical in shape to `Greeting` in §4.1, which is a `String`.

Two chips, two distinct `requires`, **exact-key analysis and exact runtime gates** because both
qualifiers are declared. The shared `db` family is used only by a computed-qualifier consumer or a
deliberate family export. Exporting `Primary Db` produces `ExportSelector.Exact(db:primary)` and
does not carry `Reporting Db`. Sharing a family with different qualifiers is legitimate; sharing the
same exact key is the alias the warning reports.

### 4.4 Browser and SUT — structurally unchanged

The shipped `FizzBuzz` / `Open Kzen and Browser` notation keeps its shape; only the verbs move
(`provides:` → `binds:`, `requires:` → `uses:` at the **step** level; document rows unchanged).
`BrowserOpenStep` composes both mix-ins and keeps its `closePolicy` exactly as today. Include the
before/after as the compatibility proof.

### 4.5 A base path passed *down* a subtree — and why no export appears

The most common shape, and the one the fused model made hardest to reason about. An outer Script
sets a filesystem base path; everything it runs reads it.

```yaml
# outer Script — declares NOTHING, because the binding rests right here
main:
  is: Script

main.steps/Set Base Path:
  is: BindStep
  binds: Base Path
  value: '"C:/work/inbox"'

main.steps/Process:
  is: RunStep
  instructions: "main/Process Folder.yaml#main"
```

```yaml
# Process Folder.yaml
main:
  is: Script
  context:
    requires: [Base Path]

main.steps/Base Path:
  is: UseContextStep
  uses: Base Path

main.steps/Show:
  is: DisplayValueStep
  text: main.steps/Base Path
```

**No `exports` anywhere, and the reason is directional, not lifecycle-based.** Exports moves a
binding *upward*; here the binding already rests at the outer frame, and reads walk self → parent →
… → root, so every descendant sees it. Exports would enter only if the *callee* computed the path
and the caller needed it afterwards. Getting this right by reasoning about *disposal* — "a String
has nothing to close, so it needs no export" — reaches the correct answer through the P9 confusion
and will mislead on the next case.

**Two honest notes.**

- **Every document on the path declares one line.** An intermediate Script that merely hosts a
  requiring Script, never touching the path, still needs `context: {requires: [Base Path]}` — the
  analysis is local plus one level deep at each RunStep. So "ambient" here means *declared once per
  document*, not *invisible*. That is a deliberate trade (each document stays independently
  analyzable, with its contract written down), but it should not be oversold.
- **At one or two hops, a Script parameter is the better tool.** Context earns its keep when a value
  is read deep in a tree that mostly does not care about it. Say so in the UI copy, or every value
  in the system will end up ambient.

### 4.6 The three safe compositions — and the deferred fourth

The split deliberately supports three shapes.

**Plain ambient value:** §4.1's `BindStep` publishes a String with no disposal.

**Anonymous cleanup:** a step may own frame cleanup without publishing a value:

```yaml
main.steps/Start helper:
  is: StartHelperStep       # is: [ScriptStep, ResourceOwner], no ContextBinder
  closePolicy: auto         # onSettle(Auto) { helper.stop() }
```

The helper exists for its side effect and is stopped at settle. No key or Context is invented merely
to obtain a `finally`.

**Managed ambient resource:** the shipped browser opener keeps binding and disposal attached:

```yaml
main.steps/Open Browser:
  is: BrowserOpenStep       # is: [ScriptStep, ContextBinder, ResourceOwner]
  binds: BrowserContext
  closePolicy: auto         # bind(browserKey, driver, FrameDisposal { driver.quit() })
```

An explicit `BrowserCloseStep` calls `releaseBinding(browserKey)`, which removes the name and invokes
that same one-shot disposal. Frame settle later has nothing left to invoke. Export carries binding and
disposal together.

**Deferred:** `OpenBrowserStep` returning an ordinary driver followed by a separate `BindStep`. The
value graph would have forgotten which disposal owns the driver; export could move the name without
the closer, and a partial direct-source check would miss laundering through an expression. This form
waits for the managed-value/lease token in §3 C.6. The engine split is justified by the three safe
forms above and does not need an unsafe fourth to prove itself.

### 4.7 Two browsers at once, plus one generic driver that works with either

The example that exercises the most of this document at once, and the one that shows the two
addressing mechanisms are for **different problems** rather than competing.

Two declarations sharing the `browser` family — statically distinct instances, so they are
declarations, not call-site bindings (§4.3's rule):

```yaml
main.contexts/Browser A:
  is: Context
  type: { class: org.openqa.selenium.remote.RemoteWebDriver }
  key: browser
  qualifier: a

main.contexts/Browser B:
  is: Context
  type: { class: org.openqa.selenium.remote.RemoteWebDriver }
  key: browser
  qualifier: b
```

The driving Script opens both and works them **interleaved**:

```yaml
main.steps/Open A:
  is: BrowserOpenStep
  binds: Browser A          # instance-level `binds:` — P5 showed the notation already permits this
  closePolicy: auto

main.steps/Open B:
  is: BrowserOpenStep
  binds: Browser B
  closePolicy: auto

main.steps/Click Send in A:
  is: BrowserClickStep
  uses: Browser A

main.steps/Check Inbox in B:
  is: BrowserClickStep
  uses: Browser B
```

Both registrations are live on the same frame at once — different exact keys, and logic-spec §6's
"one registration per key **per frame**" is per key. No step carries a qualifier attribute: the
qualifier lives on the declaration, which is exactly what makes `uses:` a pickable nominal reference
instead of a string to get right.

**Now the generic driver.** It declares **one unqualified slot** and knows nothing about A or B:

```yaml
# Drive.yaml
main:
  is: Script
  context:
    requires: [Browser]

main.steps/Go:
  is: BrowserOpenUrlStep
  uses: Browser
```

and the caller wires it per call:

```yaml
main.steps/Drive A:
  is: RunStep
  instructions: "main/Drive.yaml#main"
  contexts: { Browser: Browser A }

main.steps/Drive B:
  is: RunStep
  instructions: "main/Drive.yaml#main"
  contexts: { Browser: Browser B }
```

**The asymmetry is the whole trick, and §3 E.1 is what permits it.** The caller's namespace holds two
qualified declarations; the callee's holds one unqualified slot; `contexts:` maps between them. The
callee reads `Browser` argument-free and never learns a qualifier existed — so it is reusable against
a single-browser caller with no `contexts:` entry at all, unchanged. Each map entry becomes an atomic
`InitialBinding` under the callee key, not a mutation of the caller's registration.

**This is genuinely concurrent**, and worth being precise about because the sequential spine invites
the wrong conclusion: both browsers hold live sessions throughout — pages loading, timers firing,
requests in flight — and the steps interleave between them. What the Script does **not** do is drive
them *in parallel*; it has no fork construct, so exactly one step is executing at any moment (§3 J).
For a two-browser test that is almost always the wanted shape, and it needs nothing from the rest of
this document beyond the two declarations above.

## 5. Phasing

Eight phases, each a ledger row. **Phase 1 depends on no verdict above** — ship it first regardless
of what happens to the rest.

The fourth review pass makes the old "Phase 2 may need splitting" seam mandatory. Address algebra
(exact/family selectors, present-null lookup, compatibility adapters) is independently testable from
the registry/lifecycle split. Combining them would ask one session to change the vocabulary, storage,
migration and settlement semantics at once. Phases 2–3 are both kzen-lib; Phase 3 is the prerequisite
for the generic steps and call-site bootstrap.

| # | Phase | Size | Content | Break? |
|---|---|---|---|---|
| 1 | **Defects & the row split** | S | P1 filter; picker shows type + description; Requires / Provides rows replace the Role dropdown; the Provides row renders private opens read-only (`ownStepProvides` → `internal`) | no |
| 2 | **Address algebra (kzen-lib)** | M | `ContextKey` / `ContextFamily`, `ExportSelector.Exact/Family`, `BindingLookup.Missing/Present`; exact and family presence APIs; qualified-export tests; present-null tests; typed overloads with deprecated composed adapters so current callers stay green. No registry split yet. Ends published to mavenLocal | additive API |
| 3 | **Binding / disposal split (kzen-lib)** | **L** | Separate binding and disposal registries; `bind` / `binding` / `releaseBinding` + keyless `onSettle`; one-shot `FrameDisposal`; managed-binding settlement state table from C.4; supersession, explicit release, root/manual, failed retention and migration fixtures; export climb on bindings; logic-spec §6 split. Composed adapters reproduce today's observable behavior before removal. Ends published to mavenLocal | **yes** (API) |
| 4 | **Declarations and addressing (kzen-auto)** | M | `Context` → concrete nominal declaration with `type: TypeMetadata`, `qualifier`, optional interop `key`, no lifecycle; canonical full-type default family; `ContextDescriptor.valueClass` → `type`; declared-vs-computed qualifier exclusivity; exact-key analysis/gates and exact alias warnings; typed bind conformance centralized; `StepExecution.bind(location, value)` → `recordValue` | **yes** |
| 5 | **Authoring** | M | `Contexts` archetype + document + controller + ribbon/sidebar, on the `ObjectRegistry` template; picker "New context…" | no |
| 6 | **The step vocabulary** | M | `BindStep` / `UseContextStep` / `ReleaseStep` / `DisposeAtSettleStep`; `SelectContextEditor`; `ContextProvider` → `ContextBinder` + `ResourceOwner`; `ReleaseStep` invokes attached disposal once; runtime raw-class/nullability check plus full metadata checks where a source type exists. Carries `provides:` → `binds:` and step `requires:` → `uses:`. No cross-step resource opener and no partial export guard presented as safety | **yes** |
| 7 | **Call-site binding** | M | `RunStep.contexts` with declaration source and step-source editor sugar; `Execution.host(initialBindings=…)` installs borrows atomically before child run; missing-vs-null and source→target assignability; migration ordering fixtures; `analyzeRunStep` credits the map; spec addendum | **yes** (host API) |
| 8 | **Reach gate** | design | Inspect real Flow / Job / Report frame topologies; decide root-vs-worker signatures, borrow lifetime, release conflicts and shared-parent writes; record verdict + fixtures/implementation plan. **Does not lift `context` onto `Logic` by assumption**; implementation receives a separately estimated ledger row | no implementation pre-approved |

Each phase's gate is `cd ../kzen-auto && ./gradlew build` — **never `./gradlew build` from the
umbrella**, which abbreviation-matches `:buildEnvironment` and exits 0 having compiled nothing.
**Phases 2 and 3 are the only kzen-lib work in the arc**; each gate is
`cd ../kzen-lib && ./gradlew build` followed by `publishToMavenLocal` (all subprojects), because
kzen-auto's `jvmMain` / `jsMain` resolve variant-suffix coordinates from mavenLocal rather than
through the composite. Phases 4–7 are kzen-auto. Phase 8 is a design session whose verification plan
comes from the verdict rather than a preselected build command.

## 6. Decision log — rejected and deferred

| | Item | Verdict | Reason |
|---|---|---|---|
| (a) | Global structural addressing (`requires: {type: …}`) | **deferred** | Exact-class only in `commonMain` — notation has no class hierarchy. Reopening trigger: a third-party step that must not name a first-party Context. §3 B |
| (b) | `ObjectLocation` as the **only** runtime key, with no public alias | **rejected** | Severs the raw/typed interop logic-spec §6 makes load-bearing. The declaration remains the nominal authoring identity; runtime address is a separate derived/aliased layer. §3 A |
| (c) | Silent inference of the document signature | **rejected** | `context.requires` is an assertion about a *caller*; no local analysis can verify it. Generalizes CTX2 §1.1. §3 F |
| (d) | Object-backed `context` entries (a nested object per declaration, `ParameterBinding`-style) | **rejected** | The map form is terse and hand-writable, which logic-spec values. Revisit only if per-*use* configuration appears — and it should not, since statically-distinct qualifiers belong on the Context declaration (§4.3) and dynamically-distinct ones belong at the call site (§4.2) |
| (e) | Custom Document as the authoring surface | **superseded** | The user chose a dedicated document type. Recorded because it was the first idea and the shapes really are similar — a `Prototype` and a Context declaration are both "an abstract archetype with a `class:`" |
| (f) | Renaming `Context` itself (to `Ambient` / `Binding` / `Slot` / `Capability`) | **rejected** | The word aligns with Kotlin `context(…)` receivers, which the spec leans on deliberately. The confusion in the screenshot is P1 (a defect) and P2 (missing description), not the noun |
| (g) | Renaming the engine's `declareExport` | **rejected** | Engine vocabulary, not user-facing, and the ownership semantic genuinely is an export. §3 G |
| (h) | `ContextKey` as a **single** wrapper over the whole `"family:qualifier"` string | **rejected** | Terser and wire-identical, but it cannot make the family parameter unmistakable — and closing that silent always-false is the entire justification for the change. Two types (`ContextKey` + `ContextFamily`). §3 A.3 |
| (i) | Enumerating legal qualifier values on a Context family | **rejected** | Each statically distinct member is already its own nominal declaration; the ordinary Context picker covers it. Computed qualifiers remain the dynamic escape hatch. §3 A.4 |
| (j) | Treating "type-based like Scala/DI" as a paradigm change | **rejected framing** | Those systems also have a nominal symbol, a value type and a runtime registry address. A5 names the same three layers and delegates default address bookkeeping without pretending type is the authoring identity. §3 A.1 |
| (k) | `Resource` / `Value` as two archetypes of `Context` (draft verdict C2) | **withdrawn** | Two skins on one mechanism — the P9 conflation one level down. It would still route every disposal through the naming namespace and hang a lifecycle slot on every binding. Replaced by C4: `Context` carries no lifecycle axis, and disposal is a separate primitive. §1.1, §3 C |
| (l) | Step verb `opens:` (draft verdict N3) | **withdrawn** | Resource vocabulary applied to a binding — a step that binds a String opens nothing. `binds:` survives contact with String, Int, domain object and browser handle alike. §3 G |
| (m) | Anonymous disposal participating in the export chain | **rejected** | Transferring ownership of something nobody can name is meaningless. `onSettle` is always frame-local; a closer that must outlive its frame belongs to a *binding*, and the existing chain then carries it. This is also the standing explanation for why the two features fused in the first place. §3 C.3 |
| (n) | Modeling `ResourceClosePolicy` as a clean 2 × 2 (disposal × binding lifetime) | **rejected framing** | `manual` masks automatic disposal at the root rather than composing independently with it. Keep the three notation values and implement the explicit event/state table. §3 C.4 |
| (o) | `onSettle(policy, subject)` + reference-identity disposal adoption at `bind` | **rejected** | Ties ownership transfer to `===` action at a distance. Reopening trigger is handled by a managed-value/lease token carrying provenance structurally. §3 C.6 |
| (p) | Deliberately invoking one disposal registration twice and relying on closer idempotence | **rejected** | The engine owns an at-most-once `FrameDisposal`. Closers still tolerate an externally-gone resource defensively, but swallowed exceptions do not make repeated side effects safe. §3 C.1 |
| (q) | Decomposing `BrowserOpenStep` into an ordinary-handle `OpenBrowserStep` + `BindStep` in this arc | **deferred** | The value graph loses disposal provenance, so export can move the handle without its closer and a partial source check is unsound. `BrowserOpenStep` stays fused. Reopen with an explicit managed-value/lease model. §3 C.6 |
| (r) | `RunStep.contexts` sourcing from a **step location** (the draft's form) | **narrowed to sugar** | Does not generalize past one hop: at depth two the value being forwarded may have arrived via the caller's own `contexts:` binding or an export chain, and no local step produced it. A Context declaration is in scope regardless of provenance, is a `by: Nominal` weak reference like every other Context reference, and gives the analysis one edge kind instead of two. The editor may still offer "pass what this step bound" and store the declaration. §3 E.1 |
| (s) | A per-step `qualifier:` attribute for addressing one of several live instances | **rejected** | Two declarations sharing a `key` express it with no new mechanism, and `uses:` stays a pickable nominal reference rather than a string to get right. The runtime qualifier parameter remains as the dynamic escape hatch (E1). §4.7, §3 A.4 |
| (t) | A static resource-flow overlay over the document DAG | **future work, not planned** | Raised and deferred by the user. §3 K records only the properties that keep it possible, so a later phase does not close the door unknowingly |
| (u) | `declareExport(ContextFamily)` only | **rejected** | Makes a declared exact qualifier family-wide at runtime while analysis credits one member. Use `ExportSelector.Exact/Family`. §3 A.3 |
| (v) | `bound(key): Any?` as the complete lookup API | **rejected** | Collapses missing with a valid present-null binding. Use `BindingLookup` plus exact/family presence queries. §3 A.3 |
| (w) | Lifting `context` onto `Logic` before inspecting flavour frame topology | **rejected as a pre-commitment** | Syntactically small, semantically unresolved for worker isolation, borrow lifetime, parallel release and shared-parent writes. Phase 8 is a design gate. §3 J |
| (x) | Keeping both unrelated `StepExecution.bind(location, value)` and `Execution.bind(key, value)` | **rejected** | Rename the value-graph operation to `recordValue`; notation `binds:` and engine `bind` then name the same ambient action. §3 G |

## 7. Risks

- **Phase 3 is the biggest implementation risk.** Splitting the fused registry touches supersession,
  exact/family export climb, the `manual` promotion cascade, failed retention and live-edit migration.
  Phase 2 deliberately lands the address/lookup algebra first, and the composed adapters plus the
  existing `RunEngineTest` resource suite are the compatibility oracle.
- **Phases 2 and 3 cross the repo boundary.** A kzen-lib change not published to mavenLocal produces
  a kzen-auto build that compiles against the composite and fails against variant-suffix coordinates.
  Publish after each phase; verify Phase 3's artifacts before starting Phase 4.
- **Phase 4 is breaking** across the shipped notation plus the ~20 fixtures in
  `kzen-auto-jvm/src/test/resources/notation/test/script/context/`. `SelfTestContextDeclarationsTest`
  asserts the whole `notation/main/**` self-test suite carries zero findings and runs on every
  `build`, so the migration cannot be deferred past the session that starts it.
- **Phase 6's two verb renames land in the same files Phase 4 rewrote.** Sequence them adjacently or
  accept a second sweep of the same notation.
- **The settlement table exposes behavior the old enum prose hid.** In particular, root/manual and
  failed `keepOnFailure` must remain inspectable/releasable rather than merely leaking an external
  handle after the registry entry disappears. Pin every table cell with tests before deleting the old
  fused implementation.
- **The canonical full-type family renderer is a wire contract.** Its qualified names, generic
  nesting and nullability must render identically on JVM and JS; never reuse `toSimple()`, whose
  imports/display concerns are different. Explicit interop aliases remain stable regardless of this
  renderer.
- **Exact-vs-family selectors must stay aligned across notation, analysis and engine.** A regression
  that turns `Exact(db:primary)` into `Family(db)` is an ownership leak, not merely a permissive gate.
  Give the two-database export case an end-to-end fixture.
- **At-most-once disposal is structural.** `FrameDisposal` must guard supersession, explicit release
  and settle through one state transition; `runCatching` around third-party code remains error
  containment, never deduplication.
- **Cross-step managed handoff is intentionally absent.** Do not reintroduce it through a convenient
  `Any?` return or describe a direct-source warning as sound. Raw plugin code can always violate a
  high-level contract; the first-party vocabulary should not make the unsafe form look supported.
- **Phase 7 changes the host API and migration bootstrap ordering.** Initial bindings must be atomic,
  reconstructed from current caller state, distinguish missing from null and validate source→target
  assignability. A migrated local binding colliding with bootstrap needs an explicit fixture.
- **Phase 8 is a gate, not a small refactor.** Parallel Job workers introduce logical write/release
  conflicts even though `RunEngine` serializes map mutation under a lock. Do not schedule the
  `Logic.context` implementation until the gate records root-vs-worker ownership and borrow rules.
- **P1 and P2 are hostage to nothing.** If this document stalls in review, ship them anyway.
- **A process note.** P9 was found in review *after* a full draft had been built on top of the
  confusion, and it invalidated four verdicts (C2, N3, the borrow mechanism, the phase list). The
  draft's own §3 E is the tell: it required a no-op-closer workaround, which is what a fused
  primitive looks like from the outside. **A design that needs a sentinel value to express the
  ordinary case is reporting a conflation.** The fourth pass adds three companion heuristics: a
  nullable map API must represent presence separately; a static exact claim must not compile to a
  runtime wildcard; and ownership safety that depends on provenance must carry provenance.

## 8. As-built

*(To be filled per phase, in descending order of interest, with the gates that ran green.)*
