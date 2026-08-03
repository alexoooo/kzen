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
> **Progress (2026-08-02): CX1 ✅ · CX2 ✅ · CX3 ✅ · CX4 ✅ · CX5 ✅ · CX6a ✅ · CX6b ✅ · CX7–CX8
> outstanding = THREE sessions.** Every landed phase is gated green and recorded in the CX document's §8
> As-built — **read that section and the CX document's §5.1 before starting anything below.** CX7 still
> carries a mandatory seam (§CX7 below gives the entry anchors; the CX document's §5.1 gives the rationale
> and the fallback seams).
>
> **Session order from here:** CX7a *(kzen-lib)* → CX7b → CX8.
>
> **From CX6b, four facts CX7 depends on:** (1) the typed bind surface is `StepExecution.bindContext` in two
> overloads — `(value, qualifier?)` binds with no disposal, `(value, closePolicy, qualifier?, closer)`
> attaches one; `provideContext` is gone, and the rename was verified not to be an SPI break because
> `kzen-auto-plugin` contains no `StepExecution`. (2) `disposeAtSettle(policy, closer)` exposes
> `Execution.onSettle` to a step. (3) **kzen-lib was already published once during CX6b** — attribute
> `meta:` inherited most-distant-ancestor-wins, the opposite of attribute values, so no subtype could refine
> an inherited attribute; `NotationMetadataReader.readObjectImpl` now keeps the closest declaration. So
> mavenLocal already holds a `0.30.0-SNAPSHOT` newer than any tag, and CX7a's publish is the *second*, not
> the first. (4) `BindStep` skips its static class check when inference yields `Any`, because
> `ExpressionReturnTypeInference` approximates unmarked — CX7b's source→target assignability faces the same
> trap and should reuse that reasoning rather than re-derive it.
>
> **From CX5, one fact the remaining sessions need:** a user's Context now lives at
> `main.contexts/<Name>` in a Contexts document, and **a plain-name reference does not resolve to it
> from another document** — resolution is relative to the referring document, and every first-party
> Context is a *root-level* object, which is why the terse form has always worked until now. What
> lands in notation is the **object-path form** `main.contexts/<Name>`
> (`toReference().crop(retainPath = false)`, which drops the document path but keeps the nesting that
> disambiguates); the fully-qualified form is the fallback. Mint references the way
> `ContextSignatureEditor.referenceNameOf` does. Pinned by
> `ContextsDocumentTest.aPlainNameDoesNotResolveAcrossDocumentsButTheObjectPathDoes`, which asserts all
> three forms, and confirmed by a browser smoke.
>
> Engine surface the remaining phases consume (moved by CX2/CX3 — several sections below still
> describe the pre-CX3 shape):
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
>   sweep is still outstanding** — CX4's notation change touched only the five `is: Context`
>   declarations, so the two phases did NOT collide and CX6 gets the fixtures to itself.

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
consumer, against the standing "elaborate reality, not prediction" rule.) **Both documents are now
corrected**, and that boundary became CX7's session seam (CX doc §5.1).

### 0.1 Second anchor pass (2026-08-02, before CX5) — four findings that resize the remaining work

Measured against the live tree after CX4 landed. All four are folded into the CX document at the point
of the argument; repeated here because they change what a *session* does.

5. **`ObjectRegistry` and `ParameterBinding` are two different document shapes, and CX5 needs the
   second.** ObjectRegistry/DataFormat carry a **spec payload** — the whole list is one attribute on
   one object, parsed by an `AttributeDefiner`, entries are `AttributeNotation`s with **no
   `ObjectLocation`**. `ParameterBinding` and `main.steps/` are **nested objects** (`by: NestedList`),
   each with a real `ObjectLocation`. A Context declaration *must* be the second: `resolveOrNull` goes
   through `graphNotation.coalesce` (objects only), `renameObjectRefactor` asserts its target is in
   `coalesce.map` (so the command is not even constructible for a list item — `ContextRenameTest`
   would be unwritable), and `allContexts` iterates `coalesce.map.keys` (so a spec entry never reaches
   the picker). **Net effect: CX5 is *smaller* than the plan implies** — no spec class, no definer, no
   ser/de, and add/remove/reorder/rename/edit all have working call sites. See §CX5.
6. **CX6's rename is ~14 files with only 3 notation instance sites**, not a 24-fixture sweep —
   everything else inherits from an archetype. The risk moved from volume to a name collision:
   `LogicContextConventions.requiresSegment` (document, unchanged) and `.requiresAttributeName` (step,
   → `uses`) are **both the string `"requires"` today**, and 17 documents carry document-level
   `context.requires` decoys. Full site list in §CX6a.
7. **No Kotlin code writes a step-level `provides:` / `requires:` / `releases:`** — they are
   archetype-authored data only, and the only notation-mutating context code is
   `ContextSignatureEditor.writeContext` (document-level). So CX6a needs **no migration or upsert code
   on the step side**; it is a rename plus its readers.
8. **CX7's "remove the deprecated surface" is a decision, not a deletion.** Seven deprecated call sites
   remain in kzen-auto, but three of them *implement* `StepExecution`'s raw string API
   (`openResource` / `resource` / `releaseResource`), which logic-spec §6 makes load-bearing for
   raw/typed interop. `ContextKey.parse` is deliberately strict, so routing the raw hatch through it
   turns "returns null" into "throws" for a malformed plugin key. CX7a chooses explicitly — see §CX7a.

## Dependency spine

```
CX1 ✅ (independent, pull-forward)
CX2 ✅ → CX3 ✅          (kzen-lib substrate; published)
CX4 ✅
   ├─→ CX5 ✅           (additive; was independent of CX6 — see below)
   └─→ CX6a → CX6b      (6a: rename + mix-in split + adapter migration
                         6b: the generic step quartet + SelectContextEditor)
CX6b → CX7a (kzen-lib) → CX7b (kzen-auto)
CX7b → CX8              (design gate; no implementation pre-approved)
```

**Five sessions remain**, in that order. Two edges are worth stating because they are weaker or
stronger than they look:

- **CX5 ∥ CX6 are genuinely independent** and could run in either order. CX5 is listed first only
  because it is additive and gives CX6b's `SelectContextEditor` a user-authored declaration to pick.
  *(The original "run CX6 adjacent to CX4 — same YAML files" advice is **withdrawn**: the measurement
  in §0.1 finding 6 showed the two file sets are disjoint. There is no second sweep to avoid.)*
- **The two hard edges into CX7 land on different halves.** `CX6a → CX7a`, because CX7a's
  deprecated-surface verdict cannot be taken until CX6a has migrated the callers and shown what is
  left. `CX6b → CX7b`, because CX7's whole point is that a caller supplies a callee's ambient
  dependency, and the §4.2 / §4.7 fixtures have nothing to demonstrate that against until generic
  bind/use steps exist. **`CX6b → CX7a` is *not* an edge** — CX7a is pure kzen-lib and could run
  earlier; it is sequenced fourth only because CX7b follows it immediately and does need CX6b.
- **CX7a → CX7b is hard for an unrelated reason** — mavenLocal, not semantics.

Master-plan dependency rule 13 says the same. Every kzen-auto gate is
`cd ../kzen-auto && ./gradlew build`; every kzen-lib gate is
`cd ../kzen-lib && ./gradlew build` **then `publishToMavenLocal` for all subprojects** (kzen-auto's
jvmMain/jsMain resolve variant-suffix coordinates from mavenLocal). Never `./gradlew build` from the
umbrella.

---

## CX1 ✅ LANDED 2026-08-02 — context defects + the row split (kzen-auto · S · no design dependency)

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

## CX2 ✅ LANDED 2026-08-02 — address algebra (kzen-lib · M · additive)

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

## CX3 ✅ LANDED 2026-08-02 — binding / disposal split (kzen-lib · L · **was the arc's structural risk**)

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

## CX4 ✅ LANDED 2026-08-02 — declarations and addressing (kzen-auto · M · breaking)

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

## CX5 ✅ LANDED 2026-08-02 — the Contexts document (kzen-auto · M · additive)

> **Shipped as five files plus one test**, gated green with `cd ../kzen-auto && ./gradlew build`. The
> `by: NestedList` payload call was correct and the phase came in smaller than drafted; the deviations
> (no `ContextsConventions`, a one-line document class, and the cross-document reference form) are in
> the CX document's §8 As-built · Phase 5. What follows is the entry plan as written, kept for the
> record.

> **Read §0.1 finding 5 first.** The CX document originally named `ObjectRegistry` *and*
> `ParameterBinding` as one template. They are two different shapes and only one can work here.
> **Chrome from `ObjectRegistry`; payload as nested objects; list UI from `LogicSignatureEditor`.**

**Entry anchors (verified 2026-08-02).**

| Layer | Copy from | At |
|---|---|---|
| Archetype block | `ObjectRegistry` | `auto-common/common-document.yaml` (`abstract: true`, `is: Document`, `group: "Customize"`) |
| Server document class | `ObjectRegistryDocument` | `kzen-auto-jvm .../server/objects/registry/` |
| Conventions (`isContexts`) | `ObjectRegistryConventions` | `kzen-auto-common .../document/registry/` — the `isX` pattern is ~10 lines |
| Controller + registration | `ObjectRegistryController` + `registry-js.yaml` | `kzen-auto-js .../document/registry/`; sidebar/create-menu is autowired `of: Document` via `project-js.yaml` |
| **Payload shape** | **`ParameterBinding`** — `meta: {contexts: {is: List, of: Context, by: NestedList}}` | `common-document.yaml` `Script.meta.parameters` is the exact precedent |
| **List UI** | **`LogicSignatureEditor`** | already edits a `type: TypeMetadata` map and wires rename-as-refactor, drag-reorder and delete |

**What must be written:** the archetype block, a thin `DocumentArchetype` subclass, a small
`ContextsConventions`, the JS controller + `*-js.yaml` registration, and the list UI. **No spec class,
no `AttributeDefiner`, no notation ser/de** — the `Context` archetype already exists and is already
correct after CX4, and existing declarations (`BrowserContext`, `SutContext`) already have the target
shape.

**Machinery that comes for free** (all with working kzen-auto call sites — do not reimplement):
`AddObjectCommand` at a computed index · `RemoveObjectCommand` · `ShiftObjectTreeCommand` (reorder) ·
`RenameObjectRefactorCommand` · `UpsertAttributeCommand` (per-entry edit). One caveat from
`docs/architecture.md`: add must be `AddObjectCommand`, **not** `AddObjectAtAttributeCommand`, which
writes a stray scalar back.

**Then:** picker gains **"New context…"** — creates the declaration in the project's Contexts
document, creating the document on first use (CX doc §3 I — the whole distance between "open in
principle" and "open in practice"). Discovery is untouched: `allContexts` iterates `coalesce.map.keys`,
so a user's `main.contexts/Greeting` reaches the picker and the graph-wide duplicate-address check the
moment the document exists, with no registration step.

**Gate:** `cd ../kzen-auto && ./gradlew build` + spare-port smoke — create the document from the
ribbon, add a `kotlin.String` declaration with a qualifier, confirm it appears in the signature
picker, rename it and confirm a reference follows. End-to-end bind/read waits for CX6b.

**Detachable tail if the session runs long:** ship the document + declaration list first; **"New
context…" is the separable part**, being the only piece that reaches outside the new document.

---

## CX6 — the step vocabulary (kzen-auto · breaking) — **TWO SESSIONS**

**The seam:** 6a changes only things that already exist and ships no new user-facing capability; 6b
adds four steps and an editor. Merged, a failing smoke cannot be attributed — is the new `BindStep`
wrong, or did the rename miss a reader? Split, 6a's self-test canary fires on a half-done rename
before any new code exists to blame. 6b also *depends* on 6a: `BindStep` is
`is: [ScriptStep, ContextBinder]` with **no** `ResourceOwner`, which is the entire payoff of the C.5
split. **Do not split 6a further** — a half-renamed graph fails `SelfTestContextDeclarationsTest`, so
it has no green intermediate state.

### CX6a — vocabulary + mix-in split + adapter migration · **SESSION 2 of 6** — ✅ **LANDED 2026-08-02**

> Gated green; as-built in the CX document §8 Phase 6a. Kept here (rather than deleted) because CX6b runs
> next off the same section and needs the two-trap discussion below as background. Both traps held: the
> constants now differ in symbol *and* string, and the 17 document-level decoys were never touched.

Mechanical, ~14 files, **3 notation instance sites**. The risk is precision, not volume.

- **Mix-in split** (C.5): `ContextProvider` (`script-jvm.yaml`, `provides` + `closePolicy` fused) →
  `ContextBinder` (`binds:`, nullable `by: Nominal`, default `""`) + `ResourceOwner` (`closePolicy:`).
  Both inheritors — `BrowserOpenStep` (`script-jvm.yaml`) and `StartKzenAutoStep`
  (kzen-auto-test `script-test.yaml`) — take **both** halves, so **neither improves**; the split pays
  off for 6b's `BindStep` and for decoupling the reader in `ScriptStepDisplayDefault`, which today
  reads `closePolicy` **only when `providesContext != null`** — the fusion expressed in code. Expect
  6a to look like a no-op on first-party steps; that is correct, not a mistake.
- **Verb renames**: step `provides:` → `binds:`, step `requires:` → `uses:`. `releases:` keeps its
  name. **Document rows `context.requires` / `context.exports` are unchanged.**

**⚠ The two traps, both verified:**

1. **`LogicContextConventions` holds two constants that are both `"requires"` today** —
   `requiresSegment` (document-level `context.requires`, **unchanged**) and `requiresAttributeName`
   (step-level, **→ `uses`**). The rename splits them apart. The file's KDoc documents the shared
   reader and needs rewording too. This is the single most bug-prone spot in the job.
2. **17 documents carry document-level `context.requires`** that a naive grep-and-replace corrupts.
   **Discriminator: 2-space indent = step; 4-space under `context:` = document.**

**Sites (verified 2026-08-02).**

| Bucket | Where |
|---|---|
| Constants + KDoc | `LogicContextConventions` (`providesAttributeName`/`Path`, `requiresAttributeName`/`Path`, `isContextDeclaration`, `stepProvides`, `stepRequires`, `stepDeclaredContexts`, `stepContextReferences`) |
| Step-level readers | `LogicContextAnalysis` (availability walk, manual-reach walk, **and the user-visible labels `"Provides"` / `"Requires"` passed alongside the paths**) · `ScriptRunContext` · `ScriptStepDisplayDefault` · `ContextRenameTest` |
| Document-level readers — **exclude** | `ScriptLogic` · `ContextSignatureEditor` (**entire file is document-level**) · the `documentExports` badge reads in `ScriptStepDisplayDefault` |
| Archetype declarations | `common-document.yaml` (`ScriptStep`) · `script-jvm.yaml` (`ContextProvider` + the ~10 `Browser*Step`s) · `script-step-test-archetypes.yaml` · kzen-auto-test `script-test.yaml` |
| **Instance overrides — only 3** | `script-context-dangling-test.yaml` · `script-context-alias-test.yaml` · **`ContextRenameTest.kt`'s inline triple-quoted YAML** (invisible to YAML tooling — easiest to miss) |
| UI | `ScriptStepDisplayDefault` (reader) · `StepHeader.renderContextDeclarations` (renderer + 3 user-visible strings) |

**No migration/upsert code is needed on the step side** — no Kotlin anywhere *writes* a step-level
declaration; they are archetype-authored data only (§0.1 finding 7).

**Also in 6a — migrate kzen-auto off the deprecated composed kzen-lib adapters.** Seven call sites:
`JobRun` (`job-scratch`), `ScriptRunContext` ×4, `ScriptLogic`, and the `ReadResourceStep` test step.
**`ScriptRunContext.releaseContext` must switch to `releaseBinding` and `BrowserCloseStep` must drop
its own `quit()` as it does** — `releaseResource` removes *without* disposing, `releaseBinding`
disposes. Missing this double-tears-down the browser. **Leave `StepExecution`'s raw
`openResource`/`resource`/`releaseResource` alone** — that is a deliberate public contract, and CX7a
decides its fate (§0.1 finding 8).

**Gate:** `cd ../kzen-auto && ./gradlew build`. `SelfTestContextDeclarationsTest` is the canary — a
half-done rename fails it with a full finding list. Also re-run `*Context*` tests explicitly; expect
`ContextRenameTest`, `ScriptContextValidationTest` and `ScriptContextRuntimeTest` to need updating
(message assertions read the renamed labels). No smoke needed: nothing user-facing changes except
badge wording.

### CX6b — the generic step quartet + editor · **SESSION 3 of 6** — ✅ **LANDED 2026-08-02**

> Gated green, browser smoke included; as-built in the CX document §8 Phase 6b. All four steps plus
> `SelectContextEditor` shipped — the fallback seam was not needed. One thing this section did not predict:
> it required a **kzen-lib** fix (attribute `meta:` inheritance direction), so kzen-lib has already been
> published to mavenLocal once. The smoke confirmed the reference-minting warning below was worth making:
> picking a user Context writes `main.contexts/<Name>`, and picking a first-party one writes the bare name.

Additive. Depends on 6a's `ContextBinder`.

- `BindStep` — `binds:` (Context picker) · `value` (prior-step reference or Kotlin expression, the
  `FormulaStep` pattern) · optional computed `qualifier` (legal only against an unqualified
  declaration). **No `closePolicy` — there is nothing to hide** (C4). `is: [ScriptStep, ContextBinder]`.
- `UseContextStep` — reads a Context into the value graph; generalizes `BrowserGetStep`. Its result's
  `TypeMetadata` derives from the referenced declaration's `type:`.
- `ReleaseStep` — `releaseBinding`; invokes attached disposal at most once; a plain/borrowed binding
  degenerates to unbind. If a remove-without-dispose op is ever wanted it must be a separately-named
  `unbind`, **never hidden behind `ReleaseStep`** (§3 G).
- `DisposeAtSettleStep` — wraps `onSettle`; no Context, no key; optional human **label** attribute
  (display string, not a key — §3 K). The clearest single demonstration that the P9 split is real.
- `SelectContextEditor` — sibling of `SelectObjectEditor`, sourced from `ContextConventions.allContexts`
  (framework contexts are neither local objects nor Custom exports, which is why the existing editor
  cannot be reused as-is). ⚠ **Mint the reference the way `ContextSignatureEditor.referenceNameOf`
  does — `crop(retainPath = false)` first, fully-qualified as the fallback.** CX5 pinned that a *plain
  name* does not resolve to a user's `main.contexts/<Name>` declaration from another document
  (`ContextsDocumentTest.aPlainNameDoesNotResolveAcrossDocumentsButTheObjectPathDoes` asserts all three
  forms); the terse form has always worked only because every first-party Context is a root-level
  object in classpath notation. A step's `binds:` / `uses:` entry written by this editor will normally
  read `main.contexts/<Name>`, and any test fixture that hand-writes a plain name against a
  Contexts-document declaration will silently dangle.

**Deliberately absent** (C.6): no resource-only opener returning an ordinary handle, no partial
"direct-source" export guard presented as safety. `BrowserOpenStep` stays fused.

**Gate:** kzen-auto build + spare-port smoke of §4.6's three safe compositions — plain `BindStep`
String, `DisposeAtSettleStep` cleanup, fused browser open/release.

**Fallback seam if the session runs long:** ship `BindStep` + `UseContextStep` + `SelectContextEditor`
first (the read/write pair that justifies the editor), then `ReleaseStep` + `DisposeAtSettleStep` (the
disposal pair) as a tail.

---

## CX7 — call-site binding (cross-repo · breaking host API) — **TWO SESSIONS**

**The seam is the repo boundary, and it is forced, not chosen:** CX7b cannot compile until CX7a's
artifacts are in mavenLocal (kzen-auto's jvmMain/jsMain resolve variant-suffix coordinates from
mavenLocal, not through the composite). One session would mean a mid-session publish and a build of
two repos against a half-migrated API. **Do not split CX7a further** — the host-API change and its
migration-ordering fixtures are one semantic unit.

### CX7a — the host extension · **SESSION 4 of 6** (kzen-lib)

- `InitialBinding(key: ContextKey, value: Any?)`;
  `Execution.host(..., initialBindings: List<InitialBinding> = listOf())`.
- `RunEngine.host` installs all initial bindings on the new `NodeRuntime` **under the same lock that
  publishes the node** (verified: today the runtime is constructed, registered, lock released,
  `publish()`, then `runNode` — the install goes inside that locked window, before publication).
  Plain borrowed bindings, no disposal.
- **Live-edit rebuild ordering**: bootstrap bindings are reconstructed from the caller's *current*
  source bindings (not migration-owned); an adopted locally-owned binding keeps its prior stable owner
  and **supersedes** a same-key bootstrap value — pin the ordering with a migration fixture (§3 E).
- logic-spec addendum for the host extension.
- **The deprecated-surface verdict (§0.1 finding 8) — decide it here, explicitly.** After CX6a, the
  only remaining consumers of the deprecated string API are kzen-auto's *raw* hatch
  (`StepExecution.openResource` / `resource` / `releaseResource`), which logic-spec §6 makes
  load-bearing: *"a typed step opens the browser a raw step then drives."* `ContextKey.parse` is
  strict, so routing the hatch through it turns "returns null" into "throws" for a malformed plugin
  key. **Two admissible answers — pick one and record it in the as-built:** (i) keep a permissive
  string-keyed surface in kzen-lib, **un-deprecated and documented as the raw interop layer** (this is
  the recommendation — it names what the surface is for instead of leaving it looking like debt), or
  (ii) have kzen-auto's hatch parse defensively and absorb the strictness. **Do not simply delete it**
  — it is a public contract, and its callers are plugins the build cannot see.

**Gate:** `cd ../kzen-lib && ./gradlew build`, then `publishToMavenLocal` (all four subprojects),
then **verify the artifacts on disk before CX7b starts** (§7 risk 2), then
`cd ../kzen-auto && ./gradlew build` to prove the consumer is still green.

### CX7b — the call site · **SESSION 5 of 6** (kzen-auto)

- `RunStep.contexts` — map of callee declaration → caller declaration, both sides `by: Nominal` weak
  references (E-s2). Editor offers "pass what this step bound" as sugar and **stores the declaration**
  (resolve via the step's `binds:` at write time).
- Resolution at run: source read via `BindingLookup` — `Missing` is a named RunStep failure attributed
  to the RunStep; `Present(null)` accepted only for a nullable target. Source→target `TypeMetadata`
  assignability: exact in common code, `TypeAssignability` server-side for real subtypes, runtime
  target check definitive for unknown-source values.
- `LogicContextAnalysis.analyzeRunStep` credits a call-site binding as satisfying the callee's
  `context.requires` (already the cross-document rule; the map is a new satisfaction source).
- A `ReleaseStep` inside the callee finds the borrow first and unbinds — nothing closes (no disposal
  attached); a borrow transfers no ownership (sequential `host` guarantees the caller frame outlives
  the child; the parallel question belongs to CX8).
- Fixtures: §4.2 (two SUTs, unmodified callee) and §4.7 (two browsers + generic driver) end-to-end.

**Gate:** kzen-auto build + spare-port smoke of §4.7 — the asymmetric mapping, two qualified caller
declarations into one unqualified callee slot.

---

## CX8 — parallel-flavour reach gate · **SESSION 6 of 6** (design session, no implementation pre-approved)

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

- ~~**CX3 is the risk concentration**~~ — **discharged.** The composed-adapter parity gate held before
  any new test was written; the settlement table is pinned cell by cell (86 engine tests).
- **Repo-boundary discipline**: after every kzen-lib phase, publish all subprojects before touching
  kzen-auto; a missed publish produces a build that compiles in the composite and fails on
  variant-suffix coordinates. **Still live for CX7a → CX7b**, which is exactly why that seam exists.
- **Exact-vs-family alignment** is an ownership property: a regression turning `Exact(db:primary)`
  into `Family(db)` leaks a sibling's resource — the two-database export fixture is end-to-end for
  this reason. **Still live**: CX6b's `BindStep` qualifier and CX7b's source→target mapping both
  re-derive addresses.
- ~~**CX4 + CX6 touch the same notation files** — sequence adjacently~~ — **withdrawn, measured false.**
  CX4 touched the five `is: Context` declarations; CX6a touches the *step* archetypes. Disjoint sets,
  no second sweep, and **CX5/CX6 are free to run in either order** as a result.
- **CX6a's risk is a name collision, not volume** — `requiresSegment` vs `requiresAttributeName`, both
  `"requires"` today, plus 17 document-level decoys. See §CX6a.
- **CX7's deprecated-surface removal is a decision, not a deletion** — the raw string hatch is a
  documented public contract. See §0.1 finding 8 and §CX7a.
- **P1/P2 are hostage to nothing** — if any later phase stalls, CX1 has already shipped.
