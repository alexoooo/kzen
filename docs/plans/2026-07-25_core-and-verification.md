# Core graph performance + accumulated verification debt (C1–C4)

> **Status: planned.** Collects the small, independent close-out items that outlived Sprint 2's
> per-domain plans: the one remaining graph phase (measurement-gated), the manual browser smoke
> that ten headless sessions accumulated, and two housekeeping verdicts. Successor to the open
> tails of `sprint-2/2026-07-16_graph-improvements.md` and
> `sprint-2/2026-07-16_trace-payload-improvements.md`. Executor: **Opus-class, one phase per
> session** — except C2, which **needs the user at a browser**.
>
> Phase IDs are new (C1–C4) because this document merges tails from two plans; the original IDs
> (G4, TP2, G5a) are given per phase so cross-references still resolve.
>
> **Progress tracker** (update as phases land):
> - [ ] C1 — measure per-keystroke define cost (**gate**; record the number either way) — was G4's gate
> - [ ] C2 — consolidated manual smoke debt (**needs the user at a browser**)
> - [ ] C3 — incremental define, per-object definition cache — was G4 (**only if C1 convicts**)
> - [ ] C4 — housekeeping verdicts: TP2 closure, `NotationCodec` adoption follow-up (was G5a)

## Landed context — what these phases stand on

- **G1–G2 ✓ (Sprint 1)** — digest-keyed definition cache, patched `coalesce`, Kahn leveling (G1);
  closure content digest, `baselineNotations` retired (G2). **G1 is precisely what makes C1 a real
  gate**: it already collapsed per-command defines to one per notation version, so the remaining
  per-keystroke cost may well be acceptable.
- **G3, G5, G6, G7 ✓ 2026-07-19** — scoped instantiation + instance caching; `NotationCodec` +
  notation-driven `isLogic`; the structured failure surface (`transitiveFailures`,
  `GraphInstanceAttempt`); reducer decomposition + format-preserving deparse.
- **Document digest now covers pruned members + member order ✓ 2026-07-23** (kzen-lib
  `GraphDefinition.transitiveDigest`). This changed cache-key behaviour in the exact area C3 would
  extend — **C1's measurement must be taken on current `main`, not compared against an older
  number.**
- **`DirectGraphStore` hardening ✓ 2026-07-23** — landed with the validation digest handshake. C3's
  `DefinitionCache` would be owned by this same class; re-read it before designing.
- **TP1, TP3, TP4 ✓ 2026-07-16** — compression, trace binaries by handle, structural version.

---

## Phase C1 — measure per-keystroke define cost (the gate)

**This phase produces a number, not a feature.** It is the gate the graph plan attached to G4 and
upheld through two sprints; keep it honest.

**Goal:** know what a one-attribute edit actually costs on a large project, post-G1 and post the
2026-07-23 digest change, so C3 is built on evidence or dropped on evidence.

**Steps:**
1. Build (or reuse) a large-notation fixture — enough objects and cross-document inheritance that
   `ObjectDefiner.define` over the whole graph is measurable. The bundled `main/` notation plus a
   generated bulk document is fine; do not ship the generated fixture.
2. Instrument `GraphDefiner.tryDefine` with a counting/timing wrapper (test-only hook, not a
   production counter) and drive a realistic edit stream: single-attribute upserts at typing
   cadence through `DirectGraphStore`.
3. Record: defines per edit, wall-clock per edit, and the share attributable to definers that would
   be *uncacheable* under C3's design (graph-scanning and scaffolding-allocating definers — see
   C3's survey).
4. **Record the result in this plan's tracker line either way**, with the fixture size and the
   machine. If the cost is not user-perceptible, mark C3 **dropped with evidence** and close it.

**Verification:** the number exists in the tracker line; the instrumentation is removed or left as
a disabled test hook, not left in the hot path.

**Size:** micro-session.

---

## Phase C2 — consolidated manual smoke debt (needs the user)

**Goal:** clear the browser-only verification that ten headless sessions across Sprint 2 deferred.
Every item below was headless-verified at the server/compile level; what is owed is the visual
confirmation. **Organized by surface, not by originating plan**, so it runs as one dev-loop pass.

**Setup:** `BackendDevelopment` in the IDE + `./gradlew -t :kzen-auto-js:jsEsbuildBundle -PjsWatch`
(per `kzen-auto/AGENTS.md`). Have React DevTools installed; kzen-auto also ships react-scan in dev
(`Pages.kt`, dev-gated) as the accurate render overlay — prefer it over DevTools "highlight
updates", which lights up `shouldComponentUpdate` bail-outs too. Run the proxy items through
kzen-shell, not the bare backend.

### A — Script document (the largest cluster)

1. **Render scoping** (S8a/S8b): on a FizzBuzz-style Script, a per-step expand/collapse and a
   progress tick must **not** light up sibling branches; the film strip shows **no duplicate
   frames** after overlapping refreshes.
2. **Bodies and labels** (S8b): an If / ForEach / DoWhile body renders its condition/items editor,
   branch labels, and the ForEach **item-type** label.
3. **RunStep** (S8b): the expanded film strip keeps its groups/ordinals ("… #2"); the full-screen
   viewer's left/right order matches the visible strip.
4. **Scope offering** (S8b/S8c): a step-reference select and a RunStep argument select offer exactly
   the in-scope candidates (prior steps + parameters/loop items); a **DoWhile condition**'s insert
   picker offers the loop's **body steps** + bindings (the `scope: body` marker), while a
   **Formula**'s still offers predecessors + bindings.
5. **Branch discovery** (S8c): drag-drop into/out of `then`/`else`/loop bodies, and the dependency
   overlay + gutter lines (including a parameter → step edge and a cross-branch edge into an If
   branch), are unchanged.
6. **Default attribute editors** (AE4): a BrowserWrite step covers multiline `text` + Boolean
   `overwrite` + Double `delaySeconds`. Confirm the accepted D2 change that a **Boolean toggle
   persists immediately** rather than after 1 s.
7. **Reference selects** (AE5): If/ForEach/DoWhile condition & items selects; a fresh ControlStep
   inside nested loops pre-fills the innermost loop **and persists it**; the RunStep logic select
   **plus its launch button**.
8. **Debounce race** (AE4/AE6): type into a step text attribute → immediately rename the step. The
   edit must land **before** the rename in the yaml.
9. **Rename echo** (AE5): rename a referenced step, then a referenced document → the selects follow
   with **no** echo write (watch the yaml, read-only). Then edit a referenced attribute through the
   **raw editor** → the select updates **without** writing back.
10. **Validation convergence** (validation-digest handshake §6 — recovered from a deleted plan, never
    run): on a Formula step, type bad→good (`1..130x` → `1..1301`) and good→bad at various speeds,
    blur mid-debounce, rapid-fire edits. The step error, the red (!) badge and the run-cluster
    indicator must **always converge to the truth of the current code** — no stale error sticking on
    good code, no green on bad code. The busy indicator pulses through debounce + fetch and settles
    **once** — no flicker, no stuck-busy.
11. **Run gate** (G6): break a *reference* in a scratch Script → the run gate says
    `"Blocked by <step>: …"`, not the old generic line.
12. **Raw editor** (G7): edit a document through the raw editor and confirm comments and formatting
    survive the round-trip.

### B — Job document

1. **Worker card summary row** (AE6): `WorkerDisplayDefault`'s summary attributes render (worker
   bodies only render once a card is expanded, which is why headless never reached this).
2. **Default worker attributes** (AE4) and **channel selects across worker cards** (AE5).
3. **`MultiFileInputEditor`** (SER3): the only `listFiles` caller — browse a directory with a filter.
4. **Formula Source code field** (validation handshake §6): the same bad→good/good→bad drill as
   Script item 10, through the `JobController` path.
5. **Result card**: the kept value renders for `keep: last` and settles on the forced final publish.

### C — Flow document

1. **Dangling-pipe lint banner** (FL1) and **step/free-run FizzBuzz Flow Loop** (FL2).
2. **`RunLogic2` ribbon tool + arguments editor** round-trip (FL3).
3. **Error phase rendering + refetch scoping** (FL4).
4. **Run gate on a structurally-broken Flow**: Run must now be **disabled** (this was a real gap
   fixed by the 2026-07-22 validation indicator — confirm it visually).

### D — Report document (regression only — Report is frozen-in-place, not retired)

1. **Input browser** (SER3): reaches `DataLocationInfo` through the retained value-tree codec and
   must be **unchanged** — SER3's most likely over-deletion victim.
2. **Filter / pivot round-trip** (G5a): the `NotationCodec` port of FilterSpec/PivotSpec.
3. **Broken `main`** (G6): break it (e.g. `filter: ""`) and confirm there is **no**
   `window.alert("Observer error in ReportStore…")`; the `StageController` panel + `ProjectController`
   banner name `<doc>#main` and the offending attribute; a detached call against the broken doc
   answers `"… failed to define: …"` rather than `"Not found: …"`.
4. **Task-paradigm submit/query** (SER5).

### E — Ribbon / cross-document

1. **Storage manager** (SER3): open the panel → expand an area → check sizes/counts/`modified`/
   `active`, and especially the **delete button's enablement** (the `deletable` string→boolean flip)
   → delete a bundle.
2. **Go-to-error**: click an error in the stage indicator and confirm it navigates to the offending
   object slot.

### F — Transport (HAR captures, through the shell proxy)

1. **TP1**: proxy-through-browser render + the FizzBuzz HAR ~25–40 % transfer delta.
2. **TP3**: a FizzBuzz run shows **no `iVBOR` base64** in `lookup-run*` JSON; each image fetches
   **once** and hits the browser cache thereafter; film strip / thumbnails / fullscreen and
   `TargetController` locate-from-trace all still render.
3. **TP4**: the HAR shows ~46 → ~15–17 requests for traced/run-executions, and descent-into-child
   repaint animation is visible.
4. **SER5**: an SSE repaint on pause/settle **through the shell proxy** (the ContentNegotiation flip
   touched every server).
5. **G3**: before/after timing on `/action/detached` (the scoped-instantiation payoff).

### G — Shell / launcher (desktop UI, not the browser)

1. **SH2**: crashed-child surfacing + restart (the browser matrix items).
2. **SH3**: shell-spawn end-to-end with `--project.home`.
3. **SH4**: shell-spawn project **upgrade** end-to-end.

### H — Regression net

Run `cd ../kzen-auto && ./gradlew :kzen-auto-test:selfTest` once at the end. **Check who owns port
18081 first** — a `TesterMain` there is often the user's own dev instance; ask before killing it, or
`startRun` will 400 instantly (see `kzen-auto/AGENTS.md`).

**Verification:** every item above either ticked or recorded as a found defect with a follow-up.
Record the pass date in this plan's tracker line. **A found defect becomes its own plan item — do
not fix opportunistically mid-pass and lose the rest of the checklist.**

**Size:** one full session, with the user.

---

## Phase C3 — incremental define (per-object definition cache) — **only if C1 convicts**

**Do not start this phase without C1's number.** It is the riskiest change in the graph stack and
G1 may already have made it unnecessary.

**Goal:** a one-attribute edit re-runs `ObjectDefiner.define` only for the changed object and for
objects whose declared dependencies changed — not all N. Mirrors the proven `NotationMetadataReader`
design (per-object dependency digest → `DigestCache`).

**Design decisions:**
- **Opt-in via new SPI methods with `null` defaults** (additive-only rule):
  `ObjectDefiner.dependencyDigest(objectLocation, graphStructure): Digest?` and
  `AttributeDefiner.dependencyDigest(objectLocation, attributeName, graphStructure): Digest?`.
  `null` ⇒ uncacheable ⇒ redefine every time (today's behaviour). Third-party definers keep working
  unchanged.
- `AttributeObjectDefiner` (the default for everything inheriting `Object`) implements it: a digest
  over the object's merged notation along its inheritance chain + its `ObjectMetadata` digest + each
  attribute definer's own `dependencyDigest` (recursing the opt-in; any `null` attribute definer
  makes the whole object uncacheable). `StructuralAttributeDefiner` / `WeakAttributeDefiner` /
  `SelfAttributeDefiner` digest their local inputs; `AutowiredAttributeDefiner` /
  `ParentChildAttributeDefiner` / `NestedListAttributeDefiner` scan the graph — **first cut: return
  `null`** (objects using them are few — C1's step 3 measured exactly this share), with a follow-up
  option of an is-membership index digest. Flow's channel-allocating definers and Job's
  `JobChannelSynthesis` return `null` by nature (fresh scaffolding per define is their contract).
- `GraphDefiner.tryDefine` gains an optional `DefinitionCache` parameter
  (`DigestCache<ObjectDefinition>`, sized like the metadata cache); `DirectGraphStore` owns one
  instance. Lookup happens per object inside the level loop before invoking the definer; a hit still
  participates in `closedDefinitions` normally. **The definer/creator instance tower
  (`definerAndRelatedInstances`) is NOT cached** — it is tiny (the meta objects) and rebuilding it
  per `tryDefine` keeps bootstrap semantics untouched.
- **Mandatory survey-first step:** inventory every `ObjectDefiner` / `AttributeDefiner`
  implementation in kzen-lib, kzen-auto and kzen-project; classify each as local-deps /
  graph-scanning / scaffolding-allocating; record the table in the as-built note. Only then wire
  `dependencyDigest` implementations.

**Verification:** full baseline both repos + `selfTest`. Add an instrumented test (counting definer
wrapper or a test-only hook): a two-document graph, edit an attribute in document A, assert **zero**
`define` calls for document B's cacheable objects and a correct redefine when B inherits from the
edited object (the dependency digest must catch cross-document inheritance — reuse
`NotationMetadataReader.metadataDependencies`' dependency-walk pattern). Also assert edits to `meta:`
and to `is:` invalidate dependents. **This phase must not land without those tests.** Re-run C1's
measurement afterwards and record the delta.

**Size:** L. **Risk: high** — it is the riskiest phase carried out of the graph plan.

---

## Phase C4 — housekeeping verdicts

Small, independent, can ride along with any other session.

1. **TP2 — formally closed as superseded.** The "thin post-settle trace fetch" stopgap existed only
   in case TP3 slipped a release. TP3 landed 2026-07-16 and makes the settle fetch thin
   automatically. Record the closure in `kzen-auto/docs/architecture.md` §3 if the transport section
   still implies an open item; otherwise this is a one-line verdict here. **No code.**
2. **`NotationCodec` adoption follow-up (was G5a).** G5 ported FilterSpec/PivotSpec and left
   **~13 codec-portable definers** as documented follow-up (report specs and friends). Survey them,
   port the ones that are mechanical, and record the ones that are not with the reason. Optional —
   pull only when touching those files anyway.
3. **`R6` — client-plugin verdict tick.** The verdict (declarative-first; separately-compiled
   Kotlin/JS bundles cannot share class identity with the host bundle) is already recorded in both
   the reflection plan and EXT D7. It needs no session; it is ticked in
   `2026-07-25_extensibility-improvements.md`. Listed here only so nobody re-plans it.

**Verification:** docs consistent; no behaviour change.

---

## Sizing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| C1 — define measurement | kzen-lib test | micro | none | — |
| C2 — manual smoke debt | browser + desktop | one session **with the user** | none (finds risk) | — |
| C3 — incremental define | kzen-lib (+ definer survey across all repos) | L | **high** | C1 convicting |
| C4 — housekeeping verdicts | docs (+ optional kzen-auto) | XS | none | — |

C1 → C3 is the only ordering constraint. C2 and C4 float freely.
