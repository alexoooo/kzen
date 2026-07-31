# CX — context generalization: a design-space exploration

> **Status: design exploration, not an execution plan.** Written 2026-07-31, two days after CTX and
> CTX2 landed, on the user's first sustained use of the feature. Its job is to map the space and
> **argue for a position on each axis**, so that the sessions it spawns start from settled intent
> rather than re-deriving it. Anchors captured against kzen-auto `3639ffb5` / kzen-lib `9be12e7` —
> **re-locate by symbol, not by line number** (standing rule; the 2026-07-22 `RestHandler` split is
> the cautionary case).
>
> **Decisions the user took before drafting**, not to be re-litigated: the shipped CTX2 notation may
> be **reshaped freely** provided each proposal is marked additive vs breaking; user-authored
> contexts live in a **new "Contexts" document type**; naming and auto-wire depth were delegated to
> this document to argue and recommend.
>
> **Prior art this supersedes nothing of.** CTX (`next/context-and-resource.md`) and CTX2
> (`next/context-moved-ownership.md`) remain the authority on *ownership* — the export chain, close
> policies, bind-time resolution. Nothing here touches that model; §3 E is the only proposal that
> goes near it, and it is designed to need **zero** engine change. CTX2 §1.1's rejection of
> consumption inference is **reaffirmed and generalized** in §3 F.
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

## 2. The reframe

One sentence carries the whole proposal:

> **A Context is a typed, optionally-qualified ambient binding.**

Everything the user asked for falls out of taking that literally instead of treating `class:` as a
comment.

| Today | Reframed | Break? |
|---|---|---|
| `key:` — free string, global namespace, aliasing warned about | identity is **`(type, qualifier?)`**; `key` demoted to an optional **interop alias**, defaulting to the qualified class name | breaking |
| `class:` — documentation, read by one helper | the primary identity component, and a real `TypeMetadata` (generics, nullable) rather than a bare string | breaking |
| qualifier — runtime only | first-class notation attribute. **Declared** qualifiers get exact-key analysis; **computed** ones keep today's family granularity | additive |
| every provided thing is a closable resource with a `closePolicy` | **`Resource`** (closePolicy, releasable) vs **`Value`** (plain, no disposal), both `is: Context` | breaking |
| declared in framework YAML by whoever can write YAML | declared in a **Contexts document** — *plus* anywhere, discovery unchanged | additive |
| provided only by plugin-authored steps | plus a generic **Provide / Use / Release** step triad | additive |
| a callee reads whatever is ambient | plus **call-site binding** on `RunStep` — the caller supplies the callee's ambient dependency per call | additive |

Read the user's own examples against that table. *"A String that's qualified with some tag"* is a
`Value` whose type is `kotlin.String` and whose qualifier is the tag — one declaration, no code.
*"Two SUTs in parallel"* is either two declared qualifiers (statically distinct) or one call-site
binding per call (dynamically distinct). Neither needs a new mechanism; both need the mechanism that
already exists to become **declarable**.

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

#### A.3 · A domain type for the resource key

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
data class ResourceFamily(val value: String) {
    init {
        require(value.isNotEmpty()) { "Empty resource family" }
        require(! value.contains(ResourceKey.qualifierDelimiter)) {
            "Resource family must not contain '${ResourceKey.qualifierDelimiter}': $value"
        }
    }
    override fun toString() = value
}

data class ResourceKey(val family: ResourceFamily, val qualifier: String?) {
    companion object {
        const val qualifierDelimiter = ':'
        fun of(family: String, qualifier: String? = null): ResourceKey
        fun parse(asString: String): ResourceKey       // splits on the FIRST delimiter
    }
    fun asString(): String =
        qualifier?.let { "${family.value}$qualifierDelimiter$it" } ?: family.value
}
```

giving:

```kotlin
fun declareExport(family: ResourceFamily)
fun resource(key: ResourceKey, policy: ClosePolicy, value: Any? = null, closer: () -> Unit)
fun resourceValue(key: ResourceKey): Any?
fun hasResourceInFamily(family: ResourceFamily): Boolean
fun releaseResource(key: ResourceKey)
```

**Why `ResourceFamily` is a separate type is the part that actually pays.**
`hasResourceInFamily(family: String)` today happily accepts a fully-qualified key and then never
matches — a **silent always-false**, with no diagnostic anywhere. A distinct type converts that
class of bug into a compile error, for free. That single call site justifies the change on its own;
everything else is tidiness.

**Sub-decision to confirm: `declareExport` takes a `ResourceFamily`.** CTX2 settled that exports are
family-granular, and `ScriptLogic` already passes `ContextDescriptor.key` (a family) — but the engine
KDoc says a registration matches "the exact key **or** the family", so an exact-key export is a
tolerated, untested path. Typing the parameter as `ResourceFamily` *tightens* the contract to what is
actually used and documented. Confirm rather than assume.

**Shape fork, recorded.** A single `data class ResourceKey(val value: String)` with derived
`family` / `qualifier` accessors would be terser and keep the wire form string-identical — but it
cannot make `hasResourceInFamily` unmistakable, which is the whole point. Take the two-type version.

**Scope: mechanical, and a behaviour-preserving refactor.** Five `Execution` methods, their
`RunEngine` implementations plus `NodeRuntime.exports`, and on the kzen-auto side
`StepExecution.openResource` / `resource` / `releaseResource`, `ScriptRunContext.resourceKeyOf`,
`ScriptLogic`'s declare-and-gate calls and `JobRun`'s `"job-scratch"`. Roughly 30 call sites, **no
semantic change** — which makes it a *de-risking precursor* to Phase 2 rather than a cost: it gives
the family/qualifier split one owner before the analysis starts depending on it. It is a **kzen-lib**
change, so `publishToMavenLocal` gates the kzen-auto half (§5).

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

### C · Lifecycle — resource vs value

| | Option | Verdict |
|---|---|---|
| C1 | Uniform: every Context is a closable resource with a `closePolicy` (today) | superseded |
| C2 | **Two concrete archetypes: `Resource` (closePolicy, releasable) and `Value` (plain), both `is: Context`** | **✅** |
| C3 | One archetype with a `closable: true` flag | ✗ — same information, worse affordance |

**Why C2.** The UI difference is the entire point. A String tagged `greeting` must not present a
three-way close-policy dropdown, must not offer a Release step, and must not be reachable by a
"nothing released this" diagnostic — because an unreleased Value is not a leak. C3 encodes the same
fact but leaves every consumer to branch on it; C2 lets the archetype select the editor, which is
how kzen expresses kind-distinctions everywhere else (`IfBranch` is not a `ScriptStep`;
`ParameterBinding` is). It also gives `ContextProvider` a natural split: `closePolicy` belongs on the
Resource-opening mix-in only.

### D · Provision — how a value gets into the scope

| | Option | Verdict |
|---|---|---|
| D1 | Step archetypes pin `provides:` (today) | keep — it is right for typed plugin steps |
| D2 | **A generic `ProvideStep`**: `opens:` (Context picker) · `value` (a reference to a prior step, or a Kotlin expression as `FormulaStep` does) · `qualifier` (optional) · `closePolicy` (Resource only) | **✅** |
| D3 | **A generic `UseContextStep`** — reads a Context into the value graph so `FormulaStep` / `DisplayValueStep` can consume it by reference | **✅** |
| D4 | **A generic `ReleaseStep`** — the Resource counterpart | **✅** |
| D5 | A document-level "provides to descendants" declaration, with no step | ✗ — nothing to bind; the value has to come from somewhere |

**Why the triad, and why it is small.** P5 showed the notation already permits an instance-level
`provides:`. So D2 is a step class, an archetype, and a picker — and `BrowserGetStep` is already
D3-for-browsers, so D3 is a generalization of shipped code, not new machinery. The picker is a
`SelectContextEditor`: a sibling of the existing `SelectObjectEditor` sourced from
`ContextConventions.allContexts` rather than from local objects + Custom-document exports (which is
why the existing one cannot be reused as-is — framework Contexts are neither).

Together the triad is what makes contexts usable **without writing a plugin**, which is the actual
distance between "a fixed set of three" and "anything can be provided".

**One runtime addition worth taking with it:** a `ProvideStep` should check the value against the
declared type and fail with a named message. The static half is feasible too — Script steps already
carry inferred types through `ScriptStepDefinition` — but it is a Phase-4 stretch, not a gate.

### E · Call-site binding — the parallel-SUT answer

| | Option | Verdict |
|---|---|---|
| E1 | Thread a qualifier through step parameters; family-granular gate (today) | keep as the dynamic escape hatch |
| E2 | **`RunStep.contexts` — a per-call binding map**: `contexts: {SutContext: main.steps/Start A}` | **✅** |
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
private handle **shadows** the caller-held one"*. So a call-site binding is a **borrow**: register
the named value on the *child* frame with a **no-op closer** and policy `auto`. The child's settle
removes the borrow and runs the no-op; the owner's registration, wherever the export chain rested
it, is untouched. **No engine change.**

**Two consequences to state rather than discover.**

- A `Release` step *inside* the callee finds the borrow first and removes it, without closing the
  underlying resource. That reads as "stop borrowing", which is defensible — but it is a semantic
  choice and belongs in the spec, not in an implementation detail.
- The analysis must count a call-site binding as satisfying the callee's `context.requires`, or
  every parameterized call site lights up red. `LogicContextAnalysis.analyzeRunStep` is already the
  cross-document rule and is where this lands.

### F · Inference

| | Option | Verdict |
|---|---|---|
| F1 | None; everything explicit (today) | superseded in ergonomics only |
| F2 | **Quick-fix affordances** — one-click chips that write the declaration | **✅** |
| F3 | Silent inference of the document signature from its steps | ✗ |
| F4 | **Single-attribute derivation** — for the generic steps, the one `opens:` / `uses:` attribute *is* the declaration; nothing is written twice | **✅** |

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
| **N3** | **Requires / Provides** | **opens** · requires · releases | one rename: step `provides:` → `opens:` |
| N4 | Requires / Provides | binds · uses · releases | three renames + an archetype rename |

**Recommend N3 — and move the precision from the label to the chip.** The **Provides** row renders
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

## 4. Worked examples

### 4.1 "A String qualified with some tag"

The user's own example, end to end, with no Kotlin written.

```yaml
# Contexts.yaml — the new document type
main:
  is: Contexts

main.contexts/Greeting:
  is: Value
  type: { class: kotlin.String, generics: [], nullable: false }
  qualifier: greeting
  title: "Greeting"
  icon: "material-symbols:label"
  description: "The salutation the report header uses"
```

Provider — computes a value and publishes it, then hands it to its caller:

```yaml
main:
  is: Script
  context:
    exports: [Greeting]

main.steps/Compute:
  is: FormulaStep
  code: '"Hello, " + name'

main.steps/Publish:
  is: ProvideStep
  opens: Greeting
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

### 4.2 Two SUTs in parallel — call-site binding

```yaml
main:
  is: Script

main.steps/Start A:
  is: StartKzenAutoStep
  opens: SutContext
  qualifier: a

main.steps/Start B:
  is: StartKzenAutoStep
  opens: SutContext
  qualifier: b

main.steps/Test A:
  is: RunStep
  instructions: "main/Login Test.yaml#main"
  contexts: { SutContext: main.steps/Start A }

main.steps/Test B:
  is: RunStep
  instructions: "main/Login Test.yaml#main"
  contexts: { SutContext: main.steps/Start B }
```

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
  is: Resource
  type: { class: java.sql.Connection }
  key: db
  qualifier: primary

main.contexts/Reporting Db:
  is: Resource
  type: { class: java.sql.Connection }
  key: db
  qualifier: reporting
```

Two chips, two distinct `requires`, **exact-key** analysis (both qualifiers are declared) — and one
family, `db`, so a family-granular runtime gate still answers "is *some* database open" exactly as it
does today. Sharing a `key` with *different* qualifiers is the legitimate case; sharing a key *and*
qualifier is the alias the warning should be reporting, and after Phase 2 it reports exactly that
rather than firing on this.

### 4.4 Browser and SUT — unchanged

The shipped `FizzBuzz` / `Open Kzen and Browser` notation is untouched except for the single verb
rename (`provides:` → `opens:`). Include the before/after in the document as the compatibility proof.

## 5. Phasing

Six phases, each a ledger row. **Phase 1 depends on no verdict above** — ship it first regardless of
what happens to the rest.

| # | Phase | Size | Content | Break? |
|---|---|---|---|---|
| 1 | **Defects & the row split** | S | P1 filter; picker shows type + description; Requires / Provides rows replace the Role dropdown; the Provides row renders private opens read-only (`ownStepProvides` → `internal`) | no |
| 2 | **Identity** | M | **Two sessions, hard gate between.** *A (kzen-lib):* `ResourceKey` / `ResourceFamily` replace `key: String` across `Execution` + `RunEngine` — behaviour-preserving refactor (§3 A.3), ends with kzen-lib green **and published to mavenLocal**. *B (kzen-auto):* `Context` → concrete declaration with `type: TypeMetadata` + `qualifier`; `ContextDescriptor.valueClass` → `type`; `contextDescriptor<T>()` compares `type.className`; exact-key analysis for declared qualifiers; the alias warning becomes correct; qualified members are separate declarations sharing a `key` (§3 A.4) | **yes** |
| 3 | **Authoring** | M | `Contexts` archetype + document + controller + ribbon/sidebar, on the `ObjectRegistry` template; picker "New context…" | no |
| 4 | **Provision** | M | `ProvideStep` / `UseContextStep` / `ReleaseStep`; `SelectContextEditor`; `Resource` vs `Value` split; runtime type check on provide. Carries the `provides:` → `opens:` rename | **yes** |
| 5 | **Call-site binding** | M | `RunStep.contexts`; borrowed registration (no-op closer, no engine change); `analyzeRunStep` credits the binding; spec §6 addendum | no |
| 6 | **Reach & polish** | S | `context` lifted onto `Logic`; quick-fix inference chips | behaviour |

Each phase's gate is `cd ../kzen-auto && ./gradlew build` — **never `./gradlew build` from the
umbrella**, which abbreviation-matches `:buildEnvironment` and exits 0 having compiled nothing.
**Phase 2A is the only kzen-lib work in the arc**; its gate is `cd ../kzen-lib && ./gradlew build`
followed by `publishToMavenLocal` (all subprojects), because kzen-auto's `jvmMain` / `jsMain` resolve
variant-suffix coordinates from mavenLocal rather than through the composite. Every other phase is
kzen-auto-only.

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
| (h) | `ResourceKey` as a **single** wrapper over the whole `"family:qualifier"` string | **rejected** | Terser and wire-identical, but it cannot make `hasResourceInFamily` unmistakable — and closing that silent always-false is the entire justification for the change. Two types (`ResourceKey` + `ResourceFamily`). §3 A.3 |
| (i) | Enumerating legal qualifier values on a Context family | **rejected** | A second, weaker kind of identity underneath the first. Each qualified member is its own declaration sharing a `key` instead — no new mechanism, and the ordinary Context picker already covers it. §3 A.4 |
| (j) | Treating "type-based like Scala/DI" as a paradigm change | **rejected framing** | Those systems manufacture nominal entities for the same job (opaque/tagged types, custom qualifier annotations), and DI containers key their registries on `(Class, Annotation)` as runtime data. A Context object *is* kzen's newtype; A3 delegates string bookkeeping to the package namespace rather than eliminating it. §3 A.1 |

## 7. Risks

- **Phase 2 is breaking** across the shipped notation plus the ~20 fixtures in
  `kzen-auto-jvm/src/test/resources/notation/test/script/context/`. `SelfTestContextDeclarationsTest`
  asserts the whole `notation/main/**` self-test suite carries zero findings and runs on every
  `build`, so the migration cannot be deferred past the session that starts it.
- **Phase 4's Resource/Value split touches every shipped Context.** Mechanical, but it lands in the
  same files Phase 2 rewrote — sequence them adjacently or accept a second sweep.
- **Phase 2A crosses the repo boundary**, and it is the only phase that does. A kzen-lib change that
  is not published to mavenLocal produces a kzen-auto build that compiles against the composite and
  *fails* against the variant-suffix coordinates — verify the publish before starting 2B, not after.
  Mitigating factor: 2A is behaviour-preserving, so `RunEngineTest` plus the existing context suites
  are a complete gate.
- **Phase 5's borrow semantics are new spec surface.** The mechanism needs no engine change, but
  release-in-child and analysis credit are both decisions, and both belong in logic-spec §6 before
  the code lands, not after.
- **Phase 6 changes export-chain termination for Flow / Job / Report** — a behaviour change CTX2
  deliberately deferred. Own fixtures, own step.
- **P1 and P2 are hostage to nothing.** If this document stalls in review, ship them anyway.

## 8. As-built

*(To be filled per phase, in descending order of interest, with the gates that ran green.)*
