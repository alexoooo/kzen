# CX — context generalization: a design-space exploration

> **Status: design exploration, not an execution plan.** Written 2026-07-31, two days after CTX and
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
> **Revised again 2026-07-31, second review pass — see §3 C.6.** Walking the user's "open a browser,
> bind it, use it, let scope close it" scenario through the split found that it works and is
> *inexpressible today*, corrected a wrong claim that the decomposed form loses explicit close (it
> does not — closing is a method call on a handle, not a registry operation), and surfaced the one
> genuine cost: a binding whose disposal is anonymous must not be exported. Also folded in: closer
> idempotence as a load-bearing invariant (C.1), a second independent derivation of C.4, and the
> `bind` API collision (§3 G).
>
> **Third pass, same day.** Walking "two browsers at once, plus a generic driver" narrowed
> `RunStep.contexts` to a **declaration** source (§3 E.1 — the step-location form does not survive a
> second hop), reframed §3 J as the enabler for ***parallel*** multi-instance work, and added §4.7.
> §3 K records what keeps a future static flow overlay possible — explicitly **not** planned.
>
> **Concurrent ≠ parallel, and this document conflated them once already.** Two live browser sessions
> driven by interleaved steps *is* concurrency, and a Script does it today; what a Script cannot do is
> drive them in **parallel**, which is a Job. The first version of §3 J said "a Script cannot drive
> two browsers concurrently" — which would send an author to a Job for something they already have.
> Both words appear throughout; each is meant literally.
>
> **Prior art this supersedes nothing of *semantically*.** CTX (`next/context-and-resource.md`) and
> CTX2 (`next/context-moved-ownership.md`) remain the authority on *ownership* — the export chain,
> close policies, bind-time resolution — and every rule they state survives here. What changes is the
> **shape of the primitive that implements them** (§3 C, Phase 2): one fused `resource(…)` call
> becomes a binding plus an optional attached disposal, with the composed form reproducing today's
> behaviour exactly. CTX2 §1.1's rejection of consumption inference is **reaffirmed and generalized**
> in §3 F.
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
| **P7** | **Identity is a hand-written global string.** `key` is free-form and globally namespaced; the aliasing hazard is carried deliberately and surfaced as a warning. `class:` is the *actual* type of the thing, and it is consulted by exactly one code path — the reified `contextDescriptor<T>()` disambiguator. The field that *is* the identity is treated as documentation. | `common-document.yaml` `Context`; `StepExecution.contextDescriptor` |
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
| `key:` — free string, global namespace, aliasing warned about | identity is **`(type, qualifier?)`**; `key` demoted to an optional **interop alias**, defaulting to the qualified class name | breaking |
| `class:` — documentation, read by one helper | the primary identity component, and a real `TypeMetadata` (generics, nullable) rather than a bare string | breaking |
| qualifier — runtime only | first-class notation attribute. **Declared** qualifiers get exact-key analysis; **computed** ones keep today's family granularity | additive |
| **one primitive registers a disposal that may carry a value** | **two primitives: `bind` (naming, scope) and `onSettle` (teardown, no key). A managed resource is their composition** | breaking |
| a Context declaration implies a lifecycle | **a Context declaration has no lifecycle axis at all** — disposal is a claim a *step* makes about the value it produced | breaking |
| declared in framework YAML by whoever can write YAML | declared in a **Contexts document** — *plus* anywhere, discovery unchanged | additive |
| provided only by plugin-authored steps | plus a generic **Bind / Use / Release** step triad | additive |
| a callee reads whatever is ambient | plus **call-site binding** on `RunStep` — the caller supplies the callee's ambient dependency per call | additive |

Read the original examples against that table. *"A String qualified with some tag"* is one
declaration whose type is `kotlin.String` and whose qualifier is the tag — no code, **and no
pretence that it is disposable**. *"Two SUTs in parallel"* is either two declared qualifiers
(statically distinct) or one call-site binding per call (dynamically distinct). And a temp file that
must be deleted at frame settle but that nobody ever reads becomes expressible for the first time —
it needs no name, so it takes no key.

## 3. The axes

### A · Identity — what makes two declarations the same slot

| | Option | Verdict |
|---|---|---|
| A1 | Free-string `key`, globally namespaced (today) | superseded |
| A2 | Type alone | ✗ — the user rejected it in the brief, correctly: two databases have one type |
| A3 | **`(type, qualifier?)`, with `key` as an optional interop alias defaulting to the class name** | **✅** |
| A4 | The declaring object's `ObjectLocation` — a per-document key space | ✗ |

**Why A3.** It closes P7 and P6 together, and it is the smallest change that makes "anything can be
provided" true without inventing a namespace. Defaulting `key` to the qualified class name means a
new declaration collides with nothing but another declaration of the same type and tag — the
aliasing hazard `common-document.yaml` currently documents-and-carries becomes *impossible by
default* while staying *available on request*, which is what framework contexts need (`browser`,
`sut` are short keys precisely so the raw `openResource("browser")` escape hatch interoperates).

**Why not A4**, even though it would make collisions structurally impossible: logic-spec §6 makes
the global key namespace load-bearing — *"an export declaration, a typed opening step, and a raw
call all naming `sut` refer to one resource… that is exactly what makes the typed and raw surfaces
interoperate"*. A per-document key space severs that, and the raw surface is the plugin escape
hatch. A3 gets 90% of A4's safety with none of its cost.

**Cost of A3.** The family/qualifier split (`key` before `':'`) is what the runtime gate reasons
about. With a class-name default, `kotlin.String:greeting` has family `kotlin.String`, so a family
gate answers "is *some* String open" — useless. That is not a regression (it is the same
documented family-granularity limitation as `sut`), but it means **the gate must prefer exact-key
matching whenever both sides are declared**, and fall back to family only when a qualifier is
computed. The analysis half is Phase 2.

#### A.1 · Strings do not go away — their management is outsourced

The obvious objection to all of this is that Scala implicits, Kotlin context receivers and DI
containers are *type*-based while kzen is *string*-based, so kzen is doing something categorically
looser. That reading does not survive contact with the reference systems.

Ask any of them for two databases. Scala: you manufacture `Db[Primary]` / `Db[Reporting]`, or opaque
types, or tagged types. Kotlin context receivers: two wrapper classes. Guice / Spring / CDI:
`(Type, Qualifier)` — and every one of those style guides tells you to prefer a **custom qualifier
annotation** over `@Named("primary")`, precisely because the string is unchecked. In all three, the
discriminator that is not the type is a **nominal entity you invent**.

A kzen `Context` object already is that entity — **it is kzen's newtype.** `class:` is its
representation type and `key` is its runtime tag. And a DI container keys its registry on
`(Class, Annotation)` **as runtime data**, because a container is a map and maps need keys; it
merely *derives* the key instead of asking the author to type it.

So moving kzen's identity from `key` to `class` does not escape strings: `class: kotlin.String` is a
string too, and `GraphNotation` carries no subtype relation over it (§3 B). What A3 buys is that the
string is managed by **the JVM package namespace, the compiler and the build** rather than by the
author's memory. That is the entirety of its value, and it is enough — but it should be argued as a
delegation of bookkeeping, not sold as a change of paradigm.

#### A.2 · Three tiers of string, and only one is a problem

| Tier | Example | Who manages it | Risk today |
|---|---|---|---|
| **1 · Context identity** | `key: browser` | should be **derived** from `class` + `qualifier` (A3) | **Real** — two plugins both choosing `db` silently share one registration, and it is warned about only when both land in the same graph |
| **2 · Declared qualifier** | `primary` / `reporting` | enumerable at authoring time → should be **pickable** (A.4) | **Moderate** — free text, no picker, no check |
| **3 · Computed qualifier** | a tenant id inside a loop | inherently dynamic | **None** — this is `map["tenant-$id"]`, and nothing statically checks a map key in any language. The family-granular gate is the honest limit, and logic-spec §6 already says so |
| *(escape hatch)* | raw `openResource("browser")` | hand-managed, deliberately | by design — being a stable public string **is its job** (§3 A, "why not A4") |

Note what is missing from that table: **an author of ordinary notation types no string at all.** They
pick a Context from a picker; the reference is nominal, rename-refactor propagates, and a typo is a
dangling-reference warning rather than a silent miss. Tier 1 is the only authored string, once per
declaration — which is exactly why deriving it (A3) closes the only real exposure.

#### A.3 · A domain type for the context key

> **Sharpened by P9.** The key belongs to **binding**, not to disposal — so it is a `ContextKey`,
> and the disposal primitive (`onSettle`) carries no key at all. The split narrows this type's
> surface rather than widening it: five string-taking methods become four typed ones plus one that
> needs no identifier.

`Execution` is the conspicuous odd one out in a codebase where **every** identifier is a wrapper —
`ObjectName`, `AttributeName`, `ClassName`, `DocumentPath`, `ObjectPath`, `ObjectStableId`,
`TupleComponentName` — and then five methods take a bare `key: String`.

The string is structured (`"<family>[:<qualifier>]"`), and that structure is **re-derived ad hoc in
at least three places**: `RunEngine.exportOwnerOf` (exact-or-family match), `RunEngine.hasResourceInFamily`
(prefix split) and `ScriptRunContext.resourceKeyOf` (concatenation). Nothing enforces that a family
contains no `':'`.

Proposal — two types in `tech.kzen.lib.common.exec.engine`, alongside `ClosePolicy`, in the house
shape (`data class` over a `String`, `init { require(…) }`, companion `parse` + delimiter constant;
**not** `@JvmInline`, matching `ObjectName` / `AttributeName`):

```kotlin
data class ContextFamily(val value: String) {
    init {
        require(value.isNotEmpty()) { "Empty context family" }
        require(! value.contains(ContextKey.qualifierDelimiter)) {
            "Context family must not contain '${ContextKey.qualifierDelimiter}': $value"
        }
    }
    override fun toString() = value
}

data class ContextKey(val family: ContextFamily, val qualifier: String?) {
    companion object {
        const val qualifierDelimiter = ':'
        fun of(family: String, qualifier: String? = null): ContextKey
        fun parse(asString: String): ContextKey        // splits on the FIRST delimiter
    }
    fun asString(): String =
        qualifier?.let { "${family.value}$qualifierDelimiter$it" } ?: family.value
}
```

giving the §3 C.1 surface, fully typed:

```kotlin
fun declareExport(family: ContextFamily)
fun bind(key: ContextKey, value: Any?, disposal: FrameDisposal? = null)
fun bound(key: ContextKey): Any?
fun unbind(key: ContextKey)
fun hasBindingInFamily(family: ContextFamily): Boolean

fun onSettle(policy: ClosePolicy, closer: () -> Unit)      // no key — see §3 C.3
```

**Why `ContextFamily` is a separate type is the part that actually pays.**
`hasResourceInFamily(family: String)` today happily accepts a fully-qualified key and then never
matches — a **silent always-false**, with no diagnostic anywhere. A distinct type converts that
class of bug into a compile error, for free. That single call site justifies the change on its own;
everything else is tidiness.

**Sub-decision to confirm: `declareExport` takes a `ContextFamily`.** CTX2 settled that exports are
family-granular, and `ScriptLogic` already passes `ContextDescriptor.key` (a family) — but the engine
KDoc says a registration matches "the exact key **or** the family", so an exact-key export is a
tolerated, untested path. Typing the parameter as `ContextFamily` *tightens* the contract to what is
actually used and documented. Confirm rather than assume.

**Shape fork, recorded.** A single `data class ContextKey(val value: String)` with derived
`family` / `qualifier` accessors would be terser and keep the wire form string-identical — but it
cannot make the family parameter unmistakable, which is the whole point. Take the two-type version.

**Scope.** Five `Execution` methods, their `RunEngine` implementations plus `NodeRuntime.exports`,
and on the kzen-auto side `StepExecution.openResource` / `resource` / `releaseResource`,
`ScriptRunContext.resourceKeyOf`, `ScriptLogic`'s declare-and-gate calls and `JobRun`'s
`"job-scratch"`. Roughly 30 call sites.

**Note the revised risk profile.** In the draft this was a behaviour-preserving rename and therefore
a free de-risking precursor. Under §3 C it lands inside an **API split**, which is a larger change —
though still additive in observable behaviour, since `bind(key, value, disposal)` reproduces exactly
what `resource(key, policy, value, closer)` does today and the two new affordances (bind-without-
disposal, dispose-without-key) have no existing callers to disturb. It is a **kzen-lib** change, so
`publishToMavenLocal` gates the kzen-auto half (§5).

#### A.4 · Declared qualifiers should be pickable, not free text

Under A3 the qualifier becomes notation, and left as free text it recreates tier 1's problem one
level down: `primary`, `Primary` and `prod` are three registrations and nothing says so. Two shapes:

- **(i)** enumerate the legal qualifier values on a Context family declaration, and have consumers
  pick from them — a new mechanism, a new editor;
- **(ii)** make each qualified member **its own Context declaration sharing a `key`** — the §4.3
  shape — so the picker is the ordinary Context picker and nothing new exists at all.

**Recommend (ii).** It needs no new mechanism, it is what §4.3 already draws, and it preserves a
single rule — *a Context object is a slot* — instead of introducing a second, weaker kind of
identity underneath the first. Concretely: `qualifier:` is authored on the **declaration** and never
typed at a use site. Free-text qualifiers survive only for the tier-3 computed case, where being a
runtime string is the entire point, and they reach the engine through the step-parameter path that
exists today.

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
4. **The user's own framing points here.** *"We can't quite do all context routing by Type, because
   we do want basic qualifier support."* Once identity is `(type, qualifier)` (axis A), the Context
   object *is* the type-plus-qualifier — B2 would be a second spelling of the same fact, not a new
   capability.

**Ship the cheap middle instead.** Where a consumer has a declared type constraint, the **editor**
filters picker candidates by it — the affordance B2 was reaching for, with none of the resolution
semantics. That is one predicate in `renderPicker`, not an addressing mode.

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
binding shadows a farther one; re-binding supersedes. **No lifetime semantics whatsoever.** Every §6
property that is about *finding* a value survives here unchanged.

**Resource — scoped disposal.** *What must be torn down, and when?* Register a closer against a
frame with a policy; it runs when that frame settles. **No key, no namespace, no lookup** — anonymous
is the common case and is currently inexpressible.

```kotlin
// Ambient binding. `disposal` is how the two compose — see C.2.
fun bind(key: ContextKey, value: Any?, disposal: FrameDisposal? = null)
fun bound(key: ContextKey): Any?
fun unbind(key: ContextKey)
fun hasBindingInFamily(family: ContextFamily): Boolean
fun declareExport(family: ContextFamily)

// Scoped disposal, standalone: frame-local, anonymous, no key.
fun onSettle(policy: ClosePolicy, closer: () -> Unit)
```

Three call shapes, where today there is one:

```kotlin
execution.bind(basePathKey, "C:/work/inbox")                    // a value, not pretending to close
execution.onSettle(ClosePolicy.auto) { tempFile.delete() }      // a finally, not pretending to be named
execution.bind(browserKey, driver, FrameDisposal(auto) { driver.quit() })   // both, deliberately
```

**`onSettle` takes only `auto` and `keepOnFailure`.** The third value is not a disposal policy at
all — C.4.

**Closers are idempotent by contract, and the decomposition leans on that.** logic-spec §6 already
puts two requirements on a closer: it must dispose the handle it *captured* rather than re-resolving
its target by name, and it **must tolerate running when the resource is already gone** — the engine
swallows a throwing or double-closing closer rather than preventing it. That is load-bearing here.
Once disposal can be anonymous there is no registration to deregister, so "close it explicitly, then
let the frame settle" runs the closer twice **by design** rather than by mistake. Under the contract
that is a no-op; without it the split would be unsound. Two consequences worth stating:

- The fused primitive's deregister-before-close discipline (`releaseResource` first, so the
  auto-disposer "won't fire a second time") was always an **optimization**, not a correctness
  requirement. Reading it as the latter is what made the decomposed form look lossy on first pass.
- The requirement currently lives only in prose about the fused call. **Restate it at the `onSettle`
  and `FrameDisposal` declaration sites**, where the next implementer will actually be standing.

#### C.2 · The composition rule, enforced by API shape rather than by discipline

When a bound value is *also* a resource, its disposal must be owned **at or above** its binding
frame — otherwise a descendant can read a handle that has already been closed. Making `disposal` a
**parameter of `bind`** rather than a separate call makes that structural: an attached disposal
cannot be given a frame different from the binding's, because it is never independently placed.

That is what the engine already does. It simply refuses to let you take either half alone.

#### C.3 · Which feature owns the export chain — Context, and this makes it cleaner

`declareExport` decides **which frame a binding lands on**. That is a *scoping* question, so it
belongs to Context; disposal inherits the resting frame as a consequence of C.2 rather than as a
definition. Two things improve:

- `declareExport`'s contract stops mentioning ownership or disposal at all — "a binding of this
  family made here or below climbs past this frame" — and the Rust analogy gets *better*, not worse:
  a return move is about where a value lives, and drop follows.
- **Anonymous disposal has no export chain, ever.** It is always frame-local. That is exactly P9's
  "why they fused" turned into a rule: *ownership transfer requires a binding, because handing
  upward something nobody can name is meaningless.* If you want a closer to outlive its frame, give
  the value a name — and then the existing chain carries it.

#### C.4 · `manual` is a binding-lifetime modifier, not a close policy

Follow the decomposition one step further and today's three-valued `ResourceClosePolicy` splits into
two independent axes:

| Axis | Values | Belongs to |
|---|---|---|
| Disposal | `auto` · `keepOnFailure` | Resource — does the closer run when the owning frame settles *in failure*? |
| Binding lifetime | `frame` · `survives` | Context — does the binding die with its resting frame, or cascade one level up? |

Today's `manual` is `auto` + `survives`: the hand-up cascade is about the *binding* staying
reachable so a later sibling can close it; the closer itself is unchanged.

**A second, independent derivation lands in the same place.** Ask what `manual` would mean for an
anonymous `onSettle`: *"the engine will not dispose this; a step will."* But a step disposes by
**naming** — `releaseResource` today, `unbind` tomorrow — and an `onSettle` registration has no name
by construction. There is nobody to fire it manually and nothing to deregister. The value does not
merely go unused for anonymous disposal; it fails to typecheck as a concept. Two routes reach one
conclusion — the 2 × 2 above, and the observation that `manual` evaporates the instant you look at
disposal with no binding attached. `manual` is not a disposal policy.

**Recommendation: model two axes in the engine, keep the three-valued enum as the notation surface.**
`auto` / `manual` / `keepOnFailure` are the three useful points of the 2 × 2, the fourth
(`keepOnFailure` + `survives`) has no demonstrated use, and widening the notation would be churn
without a consumer. Record the 2 × 2 so the fourth point is a small change if a case appears.

#### C.5 · What this deletes

`ContextProvider` — which today fuses `provides` and `closePolicy` — splits into two mix-ins a step
composes as needed: **`ContextBinder`** (`binds:`) and **`ResourceOwner`** (`closePolicy:`).
`BrowserOpenStep` takes both; a step that binds a String takes only the first; a step that deletes a
temp file at settle takes only the second and declares no Context at all.

#### C.6 · Splitting the two across two steps — what it buys, and the one thing it cannot do

Separate primitives mean a step can own disposal **without** binding, and a *different* step can bind
the value it produced: an opening step registers `onSettle(auto) { … }` and returns the handle as its
ordinary step value; a generic `BindStep` names it; action steps read it; the frame settles and the
closer fires. Worked through in §4.6.

**This is inexpressible today**, and that is the point. `resource(key, policy, value, closer)`
demands the key and the closer in one call, so the step that opens *must* be the step that names. It
is a sharper demonstration of the split than `DisposeAtSettleStep`, because it exercises both
features at once rather than one in isolation.

**The mechanics check out against the tree.** `ScriptRunContext.stepValues` is a
`HashMap<ObjectStableId, Any?>` (`ScriptRunContext.kt:90` — re-locate by symbol), so a
`RemoteWebDriver` travels the value graph like any other value; and the trace path is safe, because
`displayOf` routes a step outcome through `TraceDisplay.truncatedToString` rather than
`ExecutionValue.ofArbitrary` — a non-serializable handle renders as a truncated `toString()` instead
of failing. The failure ordering is also *better* than today's: the closer is registered before any
binding exists, whereas today a throw between constructing the driver and calling `provideContext`
leaks the process.

**Two things that look like costs and are not.**

- **Explicit close still works.** A close step reads the handle through `uses:` and calls `quit()` on
  it. Closing a browser is a method call on an object, not a registry operation — and
  `BrowserCloseStep` is already exactly that shape (read the handle, quit it, then release).
  `releases:` unbinds the name, so later steps' gates fail as they should.
- **The settle-time closer then fires a second time**, since an anonymous registration cannot be
  deregistered the way `releaseResource` deregisters a fused one. Harmless — closers are idempotent
  by contract (C.1).

**The one real cost: a binding whose disposal is anonymous must not be exported.** The binding climbs
to the caller's frame; the frame-local closer does not; the caller is handed a handle that dies at
the callee's settle. The fused form cannot produce this, because value and closer are one
registration and climb together. So the decomposition **introduces a use-after-close that the fused
model structurally prevented** — the one place in this document where the split costs something real
rather than revealing a cost that was already there.

The resolution is to name the rule rather than patch it: **anonymous disposal cannot transfer,
therefore a binding paired with anonymous disposal cannot be exported.** That is C.3 read backwards.
The direct case is statically checkable — `BindStep.value` names a step location, and whether that
step is a `ResourceOwner` is right there in the notation — so the analysis can refuse the export and
say why. Indirect cases (the handle laundered through an expression step) stay a documented hazard;
see §7.

The alternative is recorded and **not** recommended: let `onSettle` take the value it disposes
(`onSettle(policy, subject) { … }`) and have `bind` adopt a frame-local disposal whose subject is
identity-equal to the bound value, so it climbs with the binding. More expressive, but it makes
ownership transfer depend on reference identity — action at a distance, for a case the fused
`bind(…, disposal)` already expresses perfectly. Decision (o).

### D · Provision — how a value gets into the scope

| | Option | Verdict |
|---|---|---|
| D1 | Step archetypes pin `provides:` (today) | keep — it is right for typed plugin steps |
| D2 | **A generic `BindStep`**: `binds:` (Context picker) · `value` (a reference to a prior step, or a Kotlin expression as `FormulaStep` does) · `qualifier` (optional) | **✅** |
| D3 | **A generic `UseContextStep`** — reads a Context into the value graph so `FormulaStep` / `DisplayValueStep` can consume it by reference | **✅** |
| D4 | **A generic `ReleaseStep`** — unbinds, and cancels any disposal *attached to that binding* (an anonymous `onSettle` is not attached to anything and survives — §3 C.6) | **✅** |
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

**One runtime addition worth taking with the triad:** `BindStep` must check the value against the
declared type and fail with a named message — and it is **runtime-only in the general case**, not a
static check deferred for convenience. The value graph is `HashMap<ObjectStableId, Any?>` and only
expression steps carry an inferred type through `ScriptStepDefinition`, so for most `value:` targets
there is nothing to compare against at design time. Skip the runtime check and a `String` bound to
`BrowserContext` surfaces as a `ClassCastException` inside `BrowserTargetStep`'s
`execution.context<RemoteWebDriver>()`, several steps away from the mistake that caused it. Treat it
as part of D2, not as polish.

**Keep `BrowserOpenStep` fused.** C.6 makes the decomposed open → bind shape available, but the
shipped browser step should stay `is: [ScriptStep, ContextBinder, ResourceOwner]` with a single
`bind(key, driver, disposal)` call. That is the form that supports export — the sub-script that opens
the system under test and hands it up — and the only one for which `manual` means anything (C.4).
The decomposed form earns its place where a resource is opened and used **locally** and the
alternative is writing a plugin step purely to obtain a named binding.

### E · Call-site binding — the parallel-SUT answer

| | Option | Verdict |
|---|---|---|
| E1 | Thread a qualifier through step parameters; family-granular gate (today) | keep as the dynamic escape hatch |
| E2 | **`RunStep.contexts` — a per-call binding map**: `contexts: {SutContext: Sut A}`, mapping a callee slot to a Context declared in the caller's scope (source form settled in E.1) | **✅** |
| E3 | Call-site *qualifier* override rather than value override | folded into E2 |

**This is the highest-expressiveness item in the document**, and it is nearly free.

It is Kotlin's `with(…)` shape: the caller supplies the callee's ambient dependency **per call**, and
the sub-script stays entirely unaware — it declares `context: {requires: [SutContext]}` and is run
twice against two different SUTs without being edited. That is what "two SUTs in parallel" actually
needs, and no amount of qualifier plumbing gets there, because the qualifier would have to be
threaded through every step of the callee.

**Why it is nearly free.** logic-spec §6 already guarantees the three properties this needs:
*"One registration per key **per frame**, so two live ones under one key are coherent"*; reads walk
self → parent → … → root and stop at the first match; *"within the second child's subtree the
private handle **shadows** the caller-held one"*.

**And C4 is what makes it clean.** The draft described a borrow as "register on the child frame with
a **no-op closer** and policy `auto`" — a workaround forced by the fusion, since the only way to bind
was to register a disposal. Under §3 C a borrow is simply **`bind(key, value)` on the child frame
with no disposal attached**. Not a trick, not a sentinel closer: the plain form of the primitive.

That is worth flagging as corroboration in its own right. **A feature designed independently, before
the conflation was identified, needed a hack that the decomposition then deleted.** When removing a
conflation makes an unrelated design fall out for free, the conflation was real.

**Two consequences to state rather than discover.**

- A `Release` step *inside* the callee finds the borrow first and unbinds it. Because the borrow
  carries no disposal, nothing is closed — "stop borrowing", exactly and without ambiguity. Under
  the fused model this had to be argued; under the split it is what the types say.
- The analysis must count a call-site binding as satisfying the callee's `context.requires`, or
  every parameterized call site lights up red. `LogicContextAnalysis.analyzeRunStep` is already the
  cross-document rule and is where this lands.

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
name. That is what lets a generic sub-script stay generic — see §4.7.

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

**Keep N3's central move regardless — the precision goes on the chip, not the label.** The
**Provides** row renders
*two chip skins*: solid-filled for what is handed to the caller (`context.exports`), plain-outlined
and read-only for what is opened here and kept private (derived from the document's own steps —
`LogicContextAnalysis.ownStepProvides`, currently `private` and needing to become `internal`).

That resolves the trap without giving up the word. One word at the row level, precision at the chip
level — which is exactly how the step header already works, where
`StepHeader.renderContextDeclarations` distinguishes four claims by skin under no label at all. The
user gets the vocabulary they asked for; `exports` keeps its precise meaning where precision matters
(notation, spec, engine); the step verb becomes the concrete physical thing a step does; and
**"what does this script set up?" gets an answer for the first time.**

Keep the engine's `declareExport` unrenamed — engine vocabulary, not user-facing, and the ownership
semantic really is an export.

**One collision to walk into deliberately rather than discover.** `StepExecution` already has a
`bind(location, value)` that records a **step value** into the value graph
(`ScriptRunContext.kt:194` — re-locate by symbol). Adding `Execution.bind(key, value)` puts two
unrelated `bind`s on types that a single object implements. The parameter types differ, so it
compiles and overload resolution is unambiguous — the hazard is comprehension, and it is aggravated
by the notation verb `binds:` pointing at only one of them. Either accept it with a cross-referencing
comment at both declaration sites, or rename the value-graph one to **`recordValue`**, which is
already what its private counterpart on `ScriptRunContext` is called. Cheap at Phase 2, annoying
afterwards.

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
speculatively; build it when Phase 4 or 5 makes a row need more than a chip.

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
`LogicTypeOptions` already provide, which means **generics come free** — `List<String>` tagged
`rows` is expressible on day one. It removes the abstract hazard entirely. And it makes a
declaration the same shape as a `ParameterBinding`: a nested object with an `ObjectLocation`, so it
gets rename-refactor, reordering and per-entry editing from machinery that already exists. Discovery
is untouched (`inheritanceChain` still contains `Context`) and so are the weak-reference reads, so
`LogicContextConventions` and `LogicContextAnalysis` need only their `valueClass` → `type` rename.

**The Contexts document is *an* authoring surface, not the only home.** Shipped contexts stay in
`script-jvm.yaml` / `script-test.yaml`; plugin contexts stay in plugin notation; the graph scan finds
all of them. What the document adds is a place a *user* can put one, and a form to write it with.

**Closing the loop on P4:** the picker gains a **"New context…"** entry that creates the declaration
in the project's Contexts document, creating the document on first use. That is the whole distance
between "the set is open in principle" and "the set is open in practice".

### J · Reach — lift `context` onto `Logic`

`context` and its `meta:` currently sit on `Script`. Move them to `Logic`, so Flow, Job and Report
carry a context signature too.

Two things to check and one to flag. `AutoConventions.isLogic` tests inheritance-chain membership and
is unaffected by `Logic` gaining attributes. The "`Logic` must not be `is: Document`" constraint
(documented at length in `common-document.yaml`) is about the sidebar's `AutowiredNominal` direct-`is`
match and is likewise unaffected. **The flag:** those flavours can currently only *end* an export
chain, by accident of having nothing to declare; afterwards they can end it deliberately, or carry it.
That is a behaviour change CTX2 explicitly deferred, and it should land as its own step with its own
fixtures rather than riding along with something else.

**Keep the two words apart, because they answer differently.** *Concurrent* — several resources live
and making progress at once. *Parallel* — several **drivers** executing simultaneously.

- **Concurrent multi-instance work is already a Script shape**, and needs nothing from J. Two
  browsers both hold live sessions — pages loading, timers firing, requests in flight — regardless of
  where the sequential spine happens to be. Interleaved steps against two live sessions is genuine
  concurrency, and it is what a two-SUT test usually wants. §4.7.
- **Parallel driving is not.** A Script's control set is `If` / `DoWhile` / `ForEach` / `Run` /
  `Pause` / `Wait`, with no fork construct, and a `RunStep` awaits its child. Parallelism in
  kzen-auto lives in **Job** (`job-worker.yaml` — "the user-composable parallel data-processing
  stages"), and a Job worker has **no context signature today**, because `context` sits on `Script`.

So J is the enabler for the **parallel** case specifically. That is a narrower claim than the one
this section first made, and the narrowing matters: reading "a Script cannot drive two browsers
concurrently" would send an author to a Job for something a Script already does. J is still worth
doing on its own merits (Flow / Job / Report all gain a signature) — it is simply not what stands
between an author and two live browsers.

Two follow-on questions this raises and does **not** answer, deliberately: whether parallel workers
get sibling frames that can each hold a private binding of the same family (§6's "same key, my own
instance" says the frame model already supports it), and whether a worker may bind into a shared
parent frame concurrently — which is a data race the current single-threaded frame registry has never
had to consider. Both belong to whoever plans J, with a real Job in front of them.

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
- **C.6's provenance check has a second consumer.** `BindStep.value` naming a `ResourceOwner` step is
  what links an anonymous disposal back to the name it ends up under — the same analysis that powers
  the export refusal.

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

No `key` anywhere: identity is `(kotlin.String, greeting)` and the engine key defaults to
`kotlin.String:greeting`.

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

Two chips, two distinct `requires`, **exact-key** analysis (both qualifiers are declared) — and one
family, `db`, so a family-granular runtime gate still answers "is *some* database open" exactly as it
does today. Sharing a `key` with *different* qualifiers is the legitimate case; sharing a key *and*
qualifier is the alias the warning should be reporting, and after Phase 2 it reports exactly that
rather than firing on this.

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

### 4.6 Open, bind, use, auto-close — both primitives in one Script

The scenario that produced §3 C.6: a browser opened by one step, named by another, driven by a third,
closed by nobody.

```yaml
main:
  is: Script

main.steps/Open Browser:
  is: OpenBrowserStep        # is: [ScriptStep, ResourceOwner] — owns disposal, binds nothing
  closePolicy: auto          # onSettle(auto) { driver.quit() }, and returns the driver as its value

main.steps/Publish:
  is: BindStep
  binds: BrowserContext
  value: main.steps/Open Browser     # bind(key, driver) — no disposal argument

main.steps/Click Login:
  is: BrowserClickStep
  uses: BrowserContext
```

The frame settles, the closer runs, the browser quits — no close step anywhere. Note that neither
step is doing anything exotic: `Open Browser` is an ordinary step returning an ordinary value, and
`Publish` is the same `BindStep` that publishes the `String` in §4.1. **The only reason this cannot
be written today is that the engine primitive refuses to hand over either half alone.**

Adding an explicit `BrowserCloseStep` (`uses:` + `releases: BrowserContext`) mid-script is legal and
does close the browser there; the settle-time closer then runs against an already-quit driver and
does nothing, per §3 C.1.

What this Script must **not** do is declare `context: {exports: [BrowserContext]}` — §3 C.6. A Script
that needs to hand its browser upward uses the fused `BrowserOpenStep`, which is the shipped shape
and needs no change for this to work.

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

Both registrations are live on the same frame at once — different keys, and logic-spec §6's "one
registration per key **per frame**" is per *key*. No step carries a qualifier attribute: the
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
a single-browser caller with no `contexts:` entry at all, unchanged.

**This is genuinely concurrent**, and worth being precise about because the sequential spine invites
the wrong conclusion: both browsers hold live sessions throughout — pages loading, timers firing,
requests in flight — and the steps interleave between them. What the Script does **not** do is drive
them *in parallel*; it has no fork construct, so exactly one step is executing at any moment (§3 J).
For a two-browser test that is almost always the wanted shape, and it needs nothing from the rest of
this document beyond the two declarations above.

## 5. Phasing

Seven phases, each a ledger row. **Phase 1 depends on no verdict above** — ship it first regardless
of what happens to the rest.

P9 reshaped this section: the draft's Phase 2 bundled a kzen-lib rename with the kzen-auto identity
change as two sessions of one phase. The engine split is now large enough to stand alone, so it
becomes **Phase 2**, identity becomes **Phase 3**, and everything after shifts by one. Phase 2 is
also now a **prerequisite** rather than a convenience: Phases 5 and 6 both depend on being able to
bind without disposing.

| # | Phase | Size | Content | Break? |
|---|---|---|---|---|
| 1 | **Defects & the row split** | S | P1 filter; picker shows type + description; Requires / Provides rows replace the Role dropdown; the Provides row renders private opens read-only (`ownStepProvides` → `internal`) | no |
| 2 | **The split (kzen-lib)** | **L** | `Execution`'s fused `resource(…)` becomes `bind` / `bound` / `unbind` / `hasBindingInFamily` + a keyless `onSettle`; `ContextKey` / `ContextFamily` / `FrameDisposal` domain types; `RunEngine` keeps bindings and disposals in separate registries; the export climb moves to the binding side; logic-spec §6 splits in two; the closer-idempotence requirement is restated at the `onSettle` / `FrameDisposal` declaration sites (§3 C.1); the two-`bind`s rename decision is taken here (§3 G). **Additive in observable behaviour** — the composed form reproduces today's `resource(…)` exactly. Ends with kzen-lib green **and published to mavenLocal** | **yes** (API) |
| 3 | **Identity (kzen-auto)** | M | `Context` → concrete declaration with `type: TypeMetadata` + `qualifier` and **no lifecycle attribute**; `ContextDescriptor.valueClass` → `type`; `contextDescriptor<T>()` compares `type.className`; exact-key analysis for declared qualifiers; the alias warning becomes correct; qualified members are separate declarations sharing a `key` (§3 A.4) | **yes** |
| 4 | **Authoring** | M | `Contexts` archetype + document + controller + ribbon/sidebar, on the `ObjectRegistry` template; picker "New context…" | no |
| 5 | **The step vocabulary** | M | `BindStep` / `UseContextStep` / `ReleaseStep` / `DisposeAtSettleStep`; `SelectContextEditor`; `ContextProvider` → `ContextBinder` + `ResourceOwner`; runtime type check on bind (**runtime-only by nature — §3 D**); the partial analysis guard refusing `exports` of a `BindStep` fed by a same-frame `ResourceOwner` (§3 C.6). Carries the `provides:` → `binds:` and step `requires:` → `uses:` renames (§3 G) | **yes** |
| 6 | **Call-site binding** | M | `RunStep.contexts` — a plain `bind` with no disposal, now that Phase 2 makes that expressible; **declaration-sourced** (§3 E.1) with step-source offered as editor sugar; `analyzeRunStep` credits the binding; spec addendum | no |
| 7 | **Reach & polish** | S | `context` lifted onto `Logic` — **the enabler for *parallel* multi-instance work, since a Job worker has no context signature today**; the *concurrent* case already works in a Script (§3 J) | behaviour |

Each phase's gate is `cd ../kzen-auto && ./gradlew build` — **never `./gradlew build` from the
umbrella**, which abbreviation-matches `:buildEnvironment` and exits 0 having compiled nothing.
**Phase 2 is the only kzen-lib work in the arc**; its gate is `cd ../kzen-lib && ./gradlew build`
followed by `publishToMavenLocal` (all subprojects), because kzen-auto's `jvmMain` / `jsMain` resolve
variant-suffix coordinates from mavenLocal rather than through the composite. Every other phase is
kzen-auto-only.

**Phase 2 may need splitting once its anchors are re-verified.** A natural seam is (2a) the domain
types plus a mechanical rename, keeping the fused primitive, then (2b) the primitive split and the
registry separation. Decide at the start of the session against the real `RunEngine`, not here.

## 6. Decision log — rejected and deferred

| | Item | Verdict | Reason |
|---|---|---|---|
| (a) | Global structural addressing (`requires: {type: …}`) | **deferred** | Exact-class only in `commonMain` — notation has no class hierarchy. Reopening trigger: a third-party step that must not name a first-party Context. §3 B |
| (b) | Per-document key spaces | **rejected** | Severs the raw/typed interop logic-spec §6 makes load-bearing. §3 A |
| (c) | Silent inference of the document signature | **rejected** | `context.requires` is an assertion about a *caller*; no local analysis can verify it. Generalizes CTX2 §1.1. §3 F |
| (d) | Object-backed `context` entries (a nested object per declaration, `ParameterBinding`-style) | **rejected** | The map form is terse and hand-writable, which logic-spec values. Revisit only if per-*use* configuration appears — and it should not, since statically-distinct qualifiers belong on the Context declaration (§4.3) and dynamically-distinct ones belong at the call site (§4.2) |
| (e) | Custom Document as the authoring surface | **superseded** | The user chose a dedicated document type. Recorded because it was the first idea and the shapes really are similar — a `Prototype` and a Context declaration are both "an abstract archetype with a `class:`" |
| (f) | Renaming `Context` itself (to `Ambient` / `Binding` / `Slot` / `Capability`) | **rejected** | The word aligns with Kotlin `context(…)` receivers, which the spec leans on deliberately. The confusion in the screenshot is P1 (a defect) and P2 (missing description), not the noun |
| (g) | Renaming the engine's `declareExport` | **rejected** | Engine vocabulary, not user-facing, and the ownership semantic genuinely is an export. §3 G |
| (h) | `ContextKey` as a **single** wrapper over the whole `"family:qualifier"` string | **rejected** | Terser and wire-identical, but it cannot make the family parameter unmistakable — and closing that silent always-false is the entire justification for the change. Two types (`ContextKey` + `ContextFamily`). §3 A.3 |
| (i) | Enumerating legal qualifier values on a Context family | **rejected** | A second, weaker kind of identity underneath the first. Each qualified member is its own declaration sharing a `key` instead — no new mechanism, and the ordinary Context picker already covers it. §3 A.4 |
| (j) | Treating "type-based like Scala/DI" as a paradigm change | **rejected framing** | Those systems manufacture nominal entities for the same job (opaque/tagged types, custom qualifier annotations), and DI containers key their registries on `(Class, Annotation)` as runtime data. A Context object *is* kzen's newtype; A3 delegates string bookkeeping to the package namespace rather than eliminating it. §3 A.1 |
| (k) | `Resource` / `Value` as two archetypes of `Context` (draft verdict C2) | **withdrawn** | Two skins on one mechanism — the P9 conflation one level down. It would still route every disposal through the naming namespace and hang a lifecycle slot on every binding. Replaced by C4: `Context` carries no lifecycle axis, and disposal is a separate primitive. §1.1, §3 C |
| (l) | Step verb `opens:` (draft verdict N3) | **withdrawn** | Resource vocabulary applied to a binding — a step that binds a String opens nothing. `binds:` survives contact with String, Int, domain object and browser handle alike. §3 G |
| (m) | Anonymous disposal participating in the export chain | **rejected** | Transferring ownership of something nobody can name is meaningless. `onSettle` is always frame-local; a closer that must outlive its frame belongs to a *binding*, and the existing chain then carries it. This is also the standing explanation for why the two features fused in the first place. §3 C.3 |
| (n) | Widening `ResourceClosePolicy` to the full 2 × 2 (disposal × binding lifetime) | **deferred** | The engine should model two axes, but `auto` / `manual` / `keepOnFailure` are the three useful points and the fourth (`keepOnFailure` + `survives`) has no demonstrated use. Recorded so it is a small change if a case appears. §3 C.4 |
| (o) | `onSettle(policy, subject)` + identity-based disposal adoption at `bind` | **deferred** | Would make the decomposed open → bind shape exportable, but ties ownership transfer to reference identity — action at a distance, for a case the fused `bind(…, disposal)` already expresses exactly. Reopening trigger: a real need to export a resource assembled by two separate steps. §3 C.6 |
| (p) | Deregistering an anonymous disposal so an explicit close cannot double-fire | **rejected** | Unnecessary. logic-spec §6 already requires a closer to tolerate running when the resource is gone, and the engine swallows a double close rather than preventing it. The fused primitive's `releaseResource`-first discipline was an optimization, and mistaking it for a correctness requirement is what made the decomposed form look lossy on first reading. §3 C.1 |
| (q) | Decomposing the shipped `BrowserOpenStep` into `OpenBrowserStep` + `BindStep` | **rejected** | The decomposed form cannot export, and export is exactly what the shipped SUT sub-script notation relies on. `BrowserOpenStep` stays fused; the decomposed shape is for locally-scoped resources that would otherwise need a plugin. §3 D |
| (r) | `RunStep.contexts` sourcing from a **step location** (the draft's form) | **narrowed to sugar** | Does not generalize past one hop: at depth two the value being forwarded may have arrived via the caller's own `contexts:` binding or an export chain, and no local step produced it. A Context declaration is in scope regardless of provenance, is a `by: Nominal` weak reference like every other Context reference, and gives the analysis one edge kind instead of two. The editor may still offer "pass what this step bound" and store the declaration. §3 E.1 |
| (s) | A per-step `qualifier:` attribute for addressing one of several live instances | **rejected** | Two declarations sharing a `key` express it with no new mechanism, and `uses:` stays a pickable nominal reference rather than a string to get right. The runtime qualifier parameter remains as the dynamic escape hatch (E1). §4.7, §3 A.4 |
| (t) | A static resource-flow overlay over the document DAG | **future work, not planned** | Raised and deferred by the user. §3 K records only the properties that keep it possible, so a later phase does not close the door unknowingly |

## 7. Risks

- **Phase 2 is the biggest single risk in the arc, and P9 created it.** Splitting a fused engine
  primitive touches `RunEngine`'s registry, the export climb, `manual`'s hand-up cascade and the
  live-edit migration that lifts registrations by their owner's stable id. Mitigations: the composed
  form reproduces today's `resource(…)` exactly, so `RunEngineTest` plus the existing context suites
  are a real gate; and the seam noted in §5 lets it split in two if the session runs long.
- **Phase 2 crosses the repo boundary**, and it is the only phase that does. A kzen-lib change that
  is not published to mavenLocal produces a kzen-auto build that compiles against the composite and
  *fails* against the variant-suffix coordinates — verify the publish before starting Phase 3, not
  after.
- **Phase 3 is breaking** across the shipped notation plus the ~20 fixtures in
  `kzen-auto-jvm/src/test/resources/notation/test/script/context/`. `SelfTestContextDeclarationsTest`
  asserts the whole `notation/main/**` self-test suite carries zero findings and runs on every
  `build`, so the migration cannot be deferred past the session that starts it.
- **Phase 5's two verb renames land in the same files Phase 3 rewrote.** Sequence them adjacently or
  accept a second sweep of the same notation.
- **The three-value `ResourceClosePolicy` now spans two engine axes** (§3 C.4). The mapping is
  `manual` = `auto` + `survives`, and it must be written down where the enum is defined — otherwise
  the next reader re-derives the fusion from the notation surface.
- **The split introduces one new failure mode, and only one: exporting a binding whose disposal is
  anonymous** (§3 C.6). Everything else in this document removes a constraint; this adds one. The
  analysis guard catches `BindStep.value` pointing directly at a `ResourceOwner` step and **misses
  the same handle laundered through an expression step**. Ship it as a partial guard, document it as
  partial, and do not describe the decomposed form as safe to export.
- **Closer idempotence stops being a nicety and becomes structural** (§3 C.1). It is already required
  by logic-spec §6, but only stated in prose about the fused call; a plugin author writing a
  non-idempotent closer today gets away with it wherever an explicit close step deregisters first.
  Restate it at the `onSettle` / `FrameDisposal` declaration sites in the same change that creates
  them.
- **Two `bind`s after Phase 2** — `StepExecution.bind(location, value)` records a step value,
  `Execution.bind(key, value)` creates a binding, and the notation verb `binds:` names only the
  second (§3 G). Different parameter types, so the compiler is fine; the reader is not. Decide the
  rename at Phase 2 rather than when someone trips over it.
- **Phase 7 changes export-chain termination for Flow / Job / Report** — a behaviour change CTX2
  deliberately deferred. Own fixtures, own step. It also opens a question nothing in the arc answers:
  **parallel Job workers binding concurrently.** Sibling workers holding private bindings of one
  family is already the frame model's "same key, my own instance", but *concurrent writes into a
  shared parent frame* is a data race the single-threaded frame registry has never faced. Whoever
  plans Phase 7 must look at a real Job, not at this document.
- **P1 and P2 are hostage to nothing.** If this document stalls in review, ship them anyway.
- **A process note.** P9 was found in review *after* a full draft had been built on top of the
  confusion, and it invalidated four verdicts (C2, N3, the borrow mechanism, the phase list). The
  draft's own §3 E is the tell: it required a no-op-closer workaround, which is what a fused
  primitive looks like from the outside. **A design that needs a sentinel value to express the
  ordinary case is reporting a conflation** — worth carrying forward as a review heuristic.

## 8. As-built

*(To be filled per phase, in descending order of interest, with the gates that ran green.)*
