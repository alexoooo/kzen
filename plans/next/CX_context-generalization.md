# CX — context generalization: execution elaboration (CX1–CX8)

> **Execution layer only.** The constituent plan `../2026-07-31_context-improvements.md` (the "CX
> document") is the sole authority on design rationale; every verdict referenced here (§3 A–K, §6
> decision log) is pre-made and is not re-argued. Master-plan ledger rows 33–40. Executor:
> Opus-class, one session per phase. When a phase lands: tick the ledger row, append to the CX
> document's §8 As-built, and when the whole arc closes **delete this file** (constituent plan
> exists — this is not a standalone).
>
> **Anchors verified 2026-08-02** against the live tree (kzen-lib + kzen-auto, post-CTX2/XC-N).
> Re-locate by symbol, not line number. Four factual corrections to the CX document found during
> verification, recorded in §0 below — none invalidates a design verdict.
>
> **Progress (2026-08-02): CX1 ✅ · CX2 ✅ · CX3 ✅ · CX4 ✅ · CX5–CX8 outstanding.** All four landed phases
> are gated green and recorded in the CX document's §8 As-built (read those before CX4 — CX2/CX3
> moved the engine surface CX4 consumes, and several sections below still describe the pre-CX3
> shape). Concretely, what a CX4 session must re-anchor on:
> - `Execution` now carries `declareExport(ExportSelector)` / `bind(ContextKey, value, FrameDisposal?)` /
>   `binding` / `hasBinding` / `hasBindingInFamily` / `releaseBinding` / `onSettle(SettleDisposalPolicy, closer)`.
>   The string forms (`declareExport(String)`, `resource`, `resourceValue`, `hasResourceInFamily`,
>   `releaseResource`) are all `@Deprecated` but behaviour-preserving — the deprecation warnings in a
>   kzen-auto build ARE the CX4/CX6 migration worklist.
> - New packages: kzen-lib-common `exec/engine/context/` (`ContextKey`, `ContextFamily`,
>   `ExportSelector`, `BindingLookup`, `RetainedBinding`) and `exec/engine/disposal/`
>   (`FrameDisposal`, `SettleDisposalPolicy`).
> - **`releaseResource` ≠ `releaseBinding`** — the first removes without disposing, the second
>   disposes once. CX6 must drop `BrowserCloseStep`'s own `quit()` when it migrates.
> - Only **four** YAML files declare `is: Context` (`auto-jvm/script/script-jvm.yaml`,
>   `test/script/context/script-context-alias-test.yaml`,
>   `test/script/engine/script-step-test-archetypes.yaml`, kzen-auto-test's `auto-jvm/script-test.yaml`).
>   The "~24 fixtures" figure counts fixtures that *use* contexts, which is CX6's sweep, not CX4's.
> - CX4 shipped `ContextDeclaration` (kzen-auto-common, `@Reflect`), `ContextAddressing` (the canonical
>   full-type family renderer + `ContextKey` derivation, pinned by a commonTest that runs on JVM and JS),
>   `ContextDescriptor.type: TypeMetadata` + `qualifier`, exact-vs-family gates and exports, centralized
>   runtime bind conformance, and `StepExecution.bind` → `recordValue`. **CX6's `binds:` / `uses:` verb
>   sweep over the ~24 fixtures is still outstanding** — CX4's notation change touched only the five
>   `is: Context` declarations, so the two phases did NOT collide and CX6 gets the fixtures to itself.

## 0. Anchor-verification corrections to the CX document (2026-08-02)

1. **`hasResourceInFamily` precision** (CX doc §3 A.3): a fully-qualified argument does not
   universally return false. `RunEngine.hasResourceInFamily` builds `"$family:"` as a prefix, so
   passing `"sut:main"` degrades to an exact-key check — **true** iff a registration exists under
   exactly `"sut:main"`, silently **false** for the bare family or a sibling qualifier. The
   motivation for a distinct `ContextFamily` type stands (the parameter is mistakable); the failure
   mode is "silently stops being a family gate", not "always false". logic-spec §6 documents the
   family-granularity as intentional.
2. **Fixture count and module** (CX doc §7): `kzen-auto-jvm/src/test/resources/notation/test/script/context/`
   holds **24** `script-context-*.yaml` fixtures, and `SelfTestContextDeclarationsTest` lives in
   **kzen-auto-test** (`src/test/kotlin/tech/kzen/auto/test/`), not kzen-auto-jvm.
3. **`LogicContextAnalysis.analyze`** takes `(graphNotation, documentPath)` — two parameters, not
   one (affects only the §3 K prose, nothing scheduled).
4. **The `Context` archetype declares no `class:` attribute** (`common-document.yaml` — it declares
   `key`, `title`, `icon`, `description` only). `class:` arrives on each *concrete* declaration
   (`BrowserContext`, `SutContext`), where it doubles as kzen's built-in instantiation key — which
   is precisely the I-a abstract-hazard. This strengthens I-b but changes CX4's mechanics: the
   migration must **repoint** `class:` (archetype-level, to the new declaration class) and **move**
   the value contract into `type:`, not merely rename an attribute.

**One resolved inconsistency.** CX doc §5 prose says "Phases 2 and 3 are the only kzen-lib work in
the arc", but the Phase 7 row itself changes `Execution.host` — kzen-lib. The phase row is the
authority: **CX7 is cross-repo** (kzen-lib host extension → build + `publishToMavenLocal` → then
kzen-auto). Recorded here so the session doesn't rediscover it. (The alternative — pre-landing
`host(initialBindings)` in CX3 — was considered and rejected: it would front-load an API without its
consumer, against the standing "elaborate reality, not prediction" rule.)

## Dependency spine

```
CX1 (independent, pull-forward)
CX2 → CX3 (kzen-lib substrate; publish after each)
CX3 → CX4 → CX5
CX3 + CX4 → CX6 (run adjacent to CX4 — same YAML files, avoid a second sweep)
CX6 → CX7 (cross-repo: kzen-lib host API first)
CX7 → CX8 (design gate; no implementation pre-approved)
```

Master-plan dependency rule 13 says the same. Every kzen-auto gate is
`cd ../kzen-auto && ./gradlew build`; every kzen-lib gate is
`cd ../kzen-lib && ./gradlew build` **then `publishToMavenLocal` for all subprojects** (kzen-auto's
jvmMain/jsMain resolve variant-suffix coordinates from mavenLocal). Never `./gradlew build` from the
umbrella.

---

## CX1 — context defects + the row split (kzen-auto · S · no design dependency)

Ships regardless of everything else. Three items.

### 1a. P1 — the abstract base leaks into the picker (defect)

`ContextConventions` (kzen-auto-common `.../objects/document/logic/context/ContextConventions.kt`):
`allContexts` maps `graphNotation.coalesce.map.keys` through `descriptorOrNull` → `isContext`, and
`isContext` tests `graphNotation.inheritanceChain(objectLocation).any { it.objectPath.name == contextObjectName }`.
kzen-lib's `buildInheritanceChain` adds the object itself first (`GraphNotation.kt`,
`builder.add(objectLocation)` before recursing; `dedupKeepLast` keeps self at index 0), so the
`Context` archetype matches its own filter.

**Fix:** make `isContext` a *proper-ancestor* test — membership in `inheritanceChain(...).drop(1)`
(safe because self is always index 0). **Check callers first**: if anything relies on
`isContext(Context archetype) == true` (validation paths, descriptor construction), fall back to
filtering the archetype in `allContexts` instead and say so in the as-built. Regression test beside
`ContextRenameTest` (kzen-auto-jvm `.../common/objects/document/logic/context/`): `allContexts` over
a graph containing the archetype + one concrete declaration returns only the declaration.

### 1b. P2 — picker shows type + description

`ContextSignatureEditor.renderPicker` (kzen-auto-js) builds options as
`value = descriptor.location.asString(); label = descriptor.label()` only, while `ContextDescriptor`
already carries `valueClass` and `description` — both read from notation, both discarded. Render the
value class (simple name, full name in tooltip) and description in the option row; MUI autocomplete
custom option rendering, same pattern the sidebar's document pickers use. `icon` is already used in
`renderChip` — reuse in the picker row. (CX4 later turns `valueClass` into `type: TypeMetadata`;
CX1 ships against today's string and CX4 sweeps this call site — noted there.)

### 1c. P3/H1 — Requires / Provides rows replace the Role dropdown

- Delete the companion `roleOptions` (Exports / "Needs") and the Role autocomplete; render **two**
  row instances of the editor, parameterized by role → attribute path (`context.requires` /
  `context.exports`).
- **Load-bearing constraint (verified):** `ScriptController.renderSignature` emits each editor
  unconditionally — the NB comment about child-index stability is explicit. Two rows must likewise
  be unconditional. Adjust the `StageErrorIndicator.reservedRowEm` offset for the extra row.
- Both rows write the same whole-map `context` attribute via `UpsertAttributeCommand` with
  unrecognized-key carry-through — each row upserts only its own key and must preserve the other's
  (the carry-through covers it; add a client-model test if one exists for the current editor,
  otherwise verify in the smoke).
- The Provides row also renders **private opens** read-only: `LogicContextAnalysis.ownStepProvides`
  is `private` → make it `internal`, and render its results as plain-outlined chips with a
  **Private** badge; `context.exports` entries render solid-filled with an **Exported** badge.
  Badges carry tooltip + accessible text — never fill-color alone (CX doc §3 G).

**Gate:** `cd ../kzen-auto && ./gradlew build`; fast JS gate during work
`:kzen-auto-js:compileKotlinJs`. Manual smoke on a **spare-port** instance (never the user's 8080
dev server): picker shows no abstract base, shows type/description; both rows add/remove
independently; a document using the old single-row data renders unchanged (notation format is
untouched — this phase is UI-only plus one visibility modifier).

---

## CX2 — address algebra (kzen-lib · M · additive)

Domain types + typed surfaces, **no registry split** — typed methods translate onto the existing
string-keyed registrations. Everything lands beside `Execution.kt` (kzen-lib-common
`.../exec/engine/`).

### 2a. Domain types (new file(s), same package)

- `ContextFamily`, `ContextKey(family, qualifier?)` — data classes, validated constructors
  (non-empty parts, no `:` delimiter inside either), companion parser, `asString()` rendering
  `"family"` / `"family:qualifier"` — **wire-identical** to today's strings. Not `@JvmInline`
  (CX doc §6 h: two types, so the family parameter is unmistakable).
- `ExportSelector.Exact(key)` / `.Family(family)` (sealed).
- `BindingLookup.Missing` / `.Present(value: Any?)` (sealed).

### 2b. Typed `Execution` surface (deprecated composed adapters keep callers green)

| New | Delegates from (deprecated, kept until CX4/CX6 migrate kzen-auto) |
|---|---|
| `declareExport(selector: ExportSelector)` | `declareExport(key: String)` → parse: has `:` → `Exact`, else `Family` |
| `binding(key: ContextKey): BindingLookup` | `resourceValue(key: String): Any?` (collapses `Missing`/`Present(null)` — that collapse is *why* it's deprecated) |
| `hasBinding(key: ContextKey)` | — (new: exact presence) |
| `hasBindingInFamily(family: ContextFamily)` | `hasResourceInFamily(family: String)` |

The string→selector parse in the adapter is behaviour-preserving: `exportOwnerOf`'s current
matching (`key in exports || key.substringBefore(':') in exports`) treats a declared `"sut"` as
family-wide and `"sut:a"` as exact — i.e. today's string set already encodes exact-vs-family
implicitly. Define `Family(f)` to match both the bare-family key and any qualifier in `f`
(equivalent to today), `Exact` to match equal keys only.

### 2c. Engine (`RunEngine.kt`, kzen-lib-jvm)

- `NodeRuntime.exports: LinkedHashSet<String>` → `LinkedHashSet<ExportSelector>`; comment about
  not lifting at the migrate barrier survives verbatim.
- `exportOwnerOf` re-expressed over selectors (same walk, same resting-frame rule).
- `hasResourceInFamily` impl gains the exact/family pair; the deprecated string entry point keeps
  its current observable behaviour (including the §0.1 degradation — do not "fix" the deprecated
  path; the typed path is the fix).
- `binding(key)` returns `Present(registration.value)` whenever a registration exists on the walk —
  presence is registration-existence, not value-non-nullness.

### 2d. Tests + spec

`RunEngineTest` resource section: qualified-export exact-vs-family (declared `Exact(db:primary)`
does not carry `db:reporting`; `Family(db)` carries both), present-null distinct from missing,
exact + family presence gates, parser round-trips and rejection cases. logic-spec §6 gets a short
additive note naming the typed surface; the full §6 rewrite belongs to CX3.

**Gate:** `cd ../kzen-lib && ./gradlew build`, `publishToMavenLocal` (all four subprojects — kzen-
project consumes `-reflect-ksp` too), then `cd ../kzen-auto && ./gradlew build` to prove the
deprecated adapters keep the consumer green (version pins unchanged — no version bump in this arc
unless the user asks; CC-14).

---

## CX3 — binding / disposal split (kzen-lib · L · **the arc's structural risk**)

The P9 split made real. Read CX doc §3 C in full before starting; the settlement table (§3 C.4) is
the specification.

### 3a. Registry split (`NodeRuntime`)

`resources: LinkedHashMap<String, Registration>` becomes:

- `bindings: LinkedHashMap<ContextKey, Binding>` — `Binding(value: Any?, disposal: FrameDisposal?)`;
- `settleDisposals: ArrayList<SettleRegistration>` — anonymous, `(policy: SettleDisposalPolicy, closer)`.

`FrameDisposal` carries the one-shot closer + the managed-binding settlement choice (`Auto` /
`Manual` / `KeepOnFailure`, parsed from notation). `SettleDisposalPolicy` is the two-valued
anonymous subset (`Auto` / `KeepOnFailure`) — `Manual` needs a name to promote, so it does not
exist for anonymous registrations.

### 3b. Primitives (`Execution` + engine impl)

```kotlin
fun bind(key: ContextKey, value: Any?, disposal: FrameDisposal? = null)
fun releaseBinding(key: ContextKey)   // removes nearest binding; runs attached disposal at most once
fun onSettle(policy: SettleDisposalPolicy, closer: () -> Unit)
```

- **At-most-once is structural**: `FrameDisposal` owns a one-shot state transition under the engine
  lock; supersession, `releaseBinding` and frame settle all route through the same `disposeOnce`,
  and only the winner invokes third-party code (closers still run off-lock, as the 2026-07-29
  supersession change already does — keep that discipline).
- Export climb operates on **bindings**; anonymous disposals never climb (CX doc §3 C.3 / §6 m) —
  they have no key, so `exportOwnerOf` is simply never consulted for them.
- The composed `resource(key, policy, value, closer)` adapter is re-implemented as
  `bind(parse(key), value, FrameDisposal(policy, closer))` and must reproduce today's observable
  behaviour **before** anything else changes — the existing `RunEngineTest` resource suite (~17
  tests, revised by CTX2) is the compatibility oracle and must stay green against the adapter.

### 3c. The settlement table is the test plan

Pin **every cell** of CX doc §3 C.4's event table with a fixture before deleting the fused
implementation: same-key rebind, explicit release, non-root success/cancel, non-root failure, root
success/cancel, root failure, live-edit migration — × `auto` / `manual` / `keepOnFailure`, plus the
two anonymous rows (`Auto`, `KeepOnFailure`). Existing behaviour to preserve where the table matches
today: `disposeResources`' Manual hand-up ("promote one frame"), keepOnFailure retention, the
migrate lift/re-adopt/orphan-sweep path (registrations lifted per owner stable id — bindings and
anonymous registrations both carry with the stable owner; do not settle at the barrier).

**"Retain" must be real** (root/`manual`, failed `keepOnFailure`): verify the terminal frame remains
inspectable/releasable through the run-inspection surface. If terminal-frame compaction makes that
false, either add the surface or record a policy rename in the as-built — silently dropping the
registration while the external process lives is a leak, not retention (CX doc §3 C.4 closing rule).

### 3d. Spec

logic-spec §6 splits into ambient binding (lookup walk, shadowing, one-per-key-per-frame,
present-null, export climb) and scoped disposal (settlement table, at-most-once, anonymity). Keep
the CTX2-era bullets that survive verbatim (supersession closer contract, two-live-registrations
coherence, migration §5 unchanged).

**Gate:** kzen-lib build + `publishToMavenLocal`; then `cd ../kzen-auto && ./gradlew build` —
kzen-auto still compiles against the deprecated composed adapters until CX4/CX6. **Verify the
mavenLocal artifacts exist before CX4 starts** (CX doc §7 risk 2).

---

## CX4 — declarations and addressing (kzen-auto · M · breaking)

**Re-verify anchors on entry** — CX2/CX3 will have moved the engine surface this phase consumes.
Sequence CX6 adjacent (same YAML files).

- **`Context` becomes a concrete nominal declaration** (I-b): archetype in `common-document.yaml`
  gains `class: <new declaration class>` (a `@Reflect` object holding the new attributes), plus
  `type:` (TypeMetadata — reuse `TypeMetadataDefiner` / the `LogicSignatureEditor` type-picker
  machinery), `qualifier: ""`, and `key:` demoted to *optional interop alias*. Per §0.4: today's
  concrete declarations carry `class:` as the **value** class — the migration moves that value into
  `type:` and drops `abstract: true` everywhere (`BrowserContext` in script-jvm.yaml, `SutContext`
  in script-test.yaml, all 24 fixtures, any `notation/main/**` user documents — sweep, don't
  enumerate from memory).
- `ContextDescriptor.valueClass: String?` → `type: TypeMetadata` (+ keep `description`, `icon`);
  sweep consumers including CX1's picker rendering and `StepExecution.contextDescriptor<T>()`
  (exact-match by class stays, now against `type.className`).
- **Canonical full-type family renderer** — commonMain utility rendering the *whole* `TypeMetadata`
  (nested generics + nullability); never `toSimple()`. It is a wire contract: identical output on
  JVM and JS, pinned by a commonTest that runs on both platforms (CX doc §7 risk 6).
- `ScriptRunContext.resourceKeyOf(descriptor, qualifier)` → `ContextKey` derivation: explicit
  `key:` alias wins, else derived family; **declared qualifier resolves exact; declared + computed
  qualifier is an error** (resolution rule, CX doc §3 A.3); computed qualifier legal only against
  an unqualified declaration.
- Exact-key analysis and gates: `LogicContextAnalysis` + Script declare-and-gate calls move to
  `ExportSelector` semantics — declared qualifiers analyzed and gated exact; graph-wide duplicate
  **exact-key** warning (same family + different declared qualifiers is legitimate).
- **Typed bind conformance centralized** in the typed `StepExecution` path (`bindContext` or
  equivalent): static/server-side full-type check via the existing `TypeAssignability` where source
  metadata exists; runtime raw-class + nullability check on the actual value; no claim of runtime
  nested-generic validation (erasure — CX doc §3 D).
- `StepExecution.bind(location, value)` → **`recordValue`** (the `ScriptRunContext` override at
  ~L194 already delegates to a private `recordValue` — promote the name outward, sweep callers).
  Frees the `bind` name for the ambient primitive (CX doc §3 G / §6 x).
- **Migration cannot be deferred past this session**: `SelfTestContextDeclarationsTest`
  (kzen-auto-test) asserts zero findings over `notation/main/**` on every build. Extend
  `ContextRenameTest` to the new attribute shapes.

**Gate:** `cd ../kzen-auto && ./gradlew build` (which runs the self-test suite), plus
`:kzen-auto-jvm:test --tests "*Context*"` explicitly during the loop.

---

## CX5 — the Contexts document (kzen-auto · M · additive)

On the **`ObjectRegistry` template** (verified: `common-document.yaml` archetype with
`is: Document`, `group: "Customize"`, server document class
`tech.kzen.auto.server.objects.registry.ObjectRegistryDocument`, controller registered in
`notation/auto-js/document/registry-js.yaml`; `DataFormat` is the same shape):

- `Contexts` archetype + server document class holding a list of Context declarations (each a
  nested concrete object per CX4 — same shape as a `ParameterBinding`, so rename/reorder/per-entry
  editing come from existing machinery).
- `ContextsController` (kzen-auto-js) + registration in a `*-js.yaml` + ribbon/sidebar entry.
- Picker gains **"New context…"**: creates the declaration in the project's Contexts document,
  creating the document on first use (CX doc §3 I — the whole distance between "open in principle"
  and "open in practice"). Discovery is untouched — the graph scan finds framework, plugin and
  document declarations alike.

**Gate:** kzen-auto build + spare-port smoke: create document from ribbon, add a `kotlin.String`
declaration with qualifier, see it in the picker, bind/read it end-to-end once CX6 lands (until
then, smoke declaration + picker only).

---

## CX6 — the step vocabulary (kzen-auto · M · breaking; run adjacent to CX4)

- **Mix-in split** (C.5): `ContextProvider` (script-jvm.yaml, `provides` + `closePolicy` fused) →
  `ContextBinder` (`binds:`, nullable `by: Nominal`, default `""`) + `ResourceOwner`
  (`closePolicy:`). `BrowserOpenStep` and `StartKzenAutoStep` take both; nothing else changes
  semantics.
- **Verb renames** across all shipped notation + fixtures: step `provides:` → `binds:`, step
  `requires:` → `uses:`. Document rows `context.requires` / `context.exports` unchanged.
- **The step quartet** (D2–D4 + the §3 K label):
  - `BindStep` — `binds:` (Context picker) · `value` (prior-step reference or Kotlin expression,
    the `FormulaStep` pattern) · optional computed `qualifier` (legal only against an unqualified
    declaration). **No closePolicy — there is nothing to hide** (C4).
  - `UseContextStep` — reads a Context into the value graph; generalizes `BrowserGetStep`. Its
    result's `TypeMetadata` derives from the referenced declaration's `type:`.
  - `ReleaseStep` — `releaseBinding`; invokes attached disposal at most once; plain/borrowed
    binding degenerates to unbind. If a remove-without-dispose op is ever wanted, it must be a
    separately-named `unbind`, never hidden behind `ReleaseStep` (§3 G).
  - `DisposeAtSettleStep` — wraps `onSettle`; no Context, no key; optional human **label**
    attribute (display string, not a key — §3 K).
- `SelectContextEditor` — sibling of `SelectObjectEditor`, sourced from
  `ContextConventions.allContexts` (framework contexts are neither local objects nor Custom
  exports, which is why the existing editor can't be reused as-is).
- **Deliberately absent** (C.6): no resource-only opener returning an ordinary handle, no partial
  "direct-source" export guard presented as safety. `BrowserOpenStep` stays fused.
- This is also where kzen-auto migrates off the deprecated composed kzen-lib adapters
  (`provideContext`/`resource` path → `bind` + `FrameDisposal`); once no caller remains, a small
  kzen-lib follow-up commit removes the deprecated surface (fold into CX7's kzen-lib visit).

**Gate:** kzen-auto build (self-test suite sweeps the renamed notation); spare-port smoke of §4.6's
three safe compositions: plain `BindStep` String, `DisposeAtSettleStep` cleanup, fused browser
open/release.

---

## CX7 — call-site binding (cross-repo · M · breaking host API)

**kzen-lib first** (see §0 — this phase is not kzen-auto-only):

- `InitialBinding(key: ContextKey, value: Any?)`; `Execution.host(..., initialBindings: List<InitialBinding> = listOf())`.
- `RunEngine.host` installs all initial bindings on the new `NodeRuntime` **under the same lock
  that publishes the node** (verified: today the runtime is constructed, registered, lock released,
  `publish()`, then `runNode` — the install goes inside that locked window, before publication).
  Plain borrowed bindings, no disposal.
- **Live-edit rebuild ordering**: bootstrap bindings are reconstructed from the caller's *current*
  source bindings (not migration-owned); an adopted locally-owned binding keeps its prior stable
  owner and **supersedes** a same-key bootstrap value — pin the ordering with a migration fixture
  (CX doc §3 E).
- Gate: kzen-lib build + `publishToMavenLocal`; also remove the CX2/CX3 deprecated adapters here if
  CX6 left no callers.

**Then kzen-auto:**

- `RunStep.contexts` — map of callee declaration → caller declaration, both sides `by: Nominal`
  weak references (E-s2). Editor offers "pass what this step bound" as sugar and **stores the
  declaration** (resolve via the step's `binds:` at write time).
- Resolution at run: source read via `BindingLookup` — `Missing` is a named RunStep failure
  attributed to the RunStep; `Present(null)` accepted only for a nullable target. Source→target
  `TypeMetadata` assignability: exact in common code, `TypeAssignability` server-side for real
  subtypes, runtime target check definitive for unknown-source values.
- `LogicContextAnalysis.analyzeRunStep` credits a call-site binding as satisfying the callee's
  `context.requires` (already the cross-document rule; the map is a new satisfaction source).
- A `ReleaseStep` inside the callee finds the borrow first and unbinds — nothing closes (no
  disposal attached); a borrow transfers no ownership (sequential `host` guarantees the caller
  frame outlives the child; the parallel question belongs to CX8).
- logic-spec addendum for the host extension.
- Fixtures: §4.2 (two SUTs, unmodified callee) and §4.7 (two browsers + generic driver) end-to-end.

**Gate:** kzen-lib publish verified, then kzen-auto build; spare-port smoke of §4.7 (the asymmetric
mapping — two qualified caller declarations into one unqualified callee slot).

---

## CX8 — parallel-flavour reach gate (design session, no implementation pre-approved)

Not an implementation session and not elaborated as one. Charter (CX doc §3 J):

- Inspect the **real** Flow / Job / Report executors' frame topologies (not the Script mental
  model).
- Answer, with fixtures where behaviour already exists: document-root vs per-worker signature
  placement; which frame receives a call-site `InitialBinding` and whether it can outlive its
  owner; worker-local exact-binding isolation and the meaning of a family export across worker
  frames; sibling `ReleaseStep` vs live borrow; last-writer-wins on shared-parent binds (the engine
  lock prevents the JVM race, not the semantic one).
- Output: a recorded verdict in the CX document + a separately-estimated ledger row for whatever
  implementation the verdict licenses. **Does not lift `context` onto `Logic` by assumption.**

Favourable syntactic facts already checked (CX doc §3 J): `AutoConventions.isLogic` is
inheritance-chain-based; the "`Logic` must not be `is: Document`" sidebar constraint is a
direct-`is` match — neither blocks `Logic` gaining attributes *if* the gate so decides.

---

## Standing risks carried from the CX document (§7) — the ones a session can trip on

- **CX3 is the risk concentration**: land the composed-adapter parity *first*, then split beneath
  it; the settlement table is the test plan, not documentation.
- **Repo-boundary discipline**: after every kzen-lib phase, publish all subprojects before touching
  kzen-auto; a missed publish produces a build that compiles in the composite and fails on
  variant-suffix coordinates.
- **Exact-vs-family alignment** is an ownership property: a regression turning `Exact(db:primary)`
  into `Family(db)` leaks a sibling's resource — the two-database export fixture is end-to-end for
  this reason.
- **CX4 + CX6 touch the same notation files** — sequence adjacently or accept a second sweep.
- **P1/P2 are hostage to nothing** — if any later phase stalls, CX1 has already shipped.
