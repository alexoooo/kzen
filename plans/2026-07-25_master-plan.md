# kzen improvement epic — master plan v3 (Sprint 3)

> **Status: meta-plan.** Written 2026-07-25 at the close of **Sprint 2** (see
> `sprint-2/README.md` for the consolidated record of what landed — 48 sessions, one line each).
> This document decides **when**; each constituent plan remains the sole authority for **how**
> (goals, design decisions, file anchors, verification). Executor: **Opus-class, one session per
> ledger row.**
>
> **Maintenance rule:** when a session lands, tick it in its own plan's tracker (as every plan
> already requires) **and** set its Status here. Constituent plans do not point back here (one-way
> reference, no churn).
>
> **This document is self-contained**: everything still relevant from Sprints 1–2 (deferred items,
> resolved gates, carried knowledge) is condensed in § Deferred & resolved. The `sprint-1/` and
> `sprint-2/` directories can be deleted without losing anything needed going forward.

## Constituent plans (the live set)

| ID | Document | Scope | Open phases |
|---|---|---|---|
| **J** | `2026-07-25_job-improvements.md` | Job flavour + Report subsumption; carries the `JobMessage` element-model contract | J3–J9 |
| **E** | `2026-07-25_extensibility-improvements.md` | Plugin registration, plugin UX, Custom power; absorbs reflection R5/R6 | E1–E6 |
| **DA/SH** | `2026-07-25_desktop-and-hosting.md` | Desktop app distribution + the hosting trio's hygiene tail | SH5, DA1–DA5 (DA6 parked) |
| **FL** | `2026-07-25_flow-improvements.md` | Flow flavour | FL5, FL6 |
| **C** | `2026-07-25_core-and-verification.md` | Graph perf tail + accumulated verification debt | C1–C4 |
| **CX** | `2026-07-31_context-improvements.md` | Context generalization — a **design-space exploration**, added mid-sprint on the first sustained use of CTX/CTX2 | CX1–CX8 |

Execution-ready elaborations for the independent items live under `plans/next/` — see its README.

**CX is the odd one out**: it began as a *design-space exploration*, not a phase list with pre-made
decisions. Its §3 records a verdict per axis with the argument for it. The user reviewed and ratified
the nominal auto-wire verdict and N4 naming on **2026-08-01**, together with a semantic-hardening pass
that split declaration/type/address identity, exact-vs-family exports, present-null lookup, one-shot
disposal and atomic call-site bootstrap. CX8 is deliberately still a design gate for parallel flavours.

## Session ledger

**One row per session.** Ordered for execution: the **Job/Report subsumption spine leads**, then
extensibility, then desktop, then the remainder. Rows marked *pull-forward* are independent of
everything above them and can be taken any time a change of pace helps.

| # | Session | Delivers | Plan · phase | Elab | Status |
|---|---|---|---|---|---|
| 1 | **J3a** — pluggable input formats | `PluginReaderWorker` bridging the plugin SPI + `encoding` on native readers | J · P3 steps 1,4 | `next/J3` | ☐ |
| 2 | **J3b** — design-time services | Column pre-scan route + `JobUpstreamSchema` fallback on `WorkerLane` + `SortSpecEditor` dropdown | J · P3 steps 2,3 | `next/J3` | ☐ |
| 3 | **J4** — Report subsumption B | `groupBy` export parity, summary/Explore offline persistence, composed A/B gate, Report frozen | J · P4 | — | ☐ |
| 4 | **J9** — file-backed carry-forward | Writer append cursor, Pivot store carry, Explore append, `resumed` progress key | J · P9 | — | ☐ |
| 5 | **J5a** — benchmark baseline | Harness + Report-vs-Job results table, incl. the `FlatView` allocation row | J · P5 session A | `next/J5` | ☐ |
| 6 | **J5b** — perf fixes + headless | IO batching, the benchmark-gated reuse ceiling, headless run mode | J · P5 session B | `next/J5` | ☐ |
| 7 | **J7** — interactivity remainder | `retain=false` progress emits, deadlock precision, channel occupancy | J · P7 | `next/J7` | ☐ |
| 8 | **J8** — Job client sweep + hygiene | Consumed-subset `JobController`, editor dedup, doc debt | J · P8 | — | ☐ |
| 9 | **E1** — extensibility ratification | Verdicts on D1–D6 + gate R5-G — **needs the user**; unblocks rows 10–14 | E · E1 | — | ☐ |
| 10 | **E2** — plugin module registration | Plugin-shipped `ModuleReflection` + pure-Java path via the R1 mirror (**was R5**) | E · E2 | — | ☐ |
| 11 | **E3** — plugin UX | Per-document classloader isolation, JAR upload, cached listing, per-definer diagnostics | E · E3 | — | ☐ |
| 12 | **E4** — Custom power + C7 | The document-rename nested-exports gap (kzen-lib), prototype metadata, per-tag registry, result persistence | E · E4 | — | ☐ |
| 13 | **E5** — registry disposition | Execute D4; migrate `FormulaStep` whitelist sourcing | E · E5 | — | ☐ |
| 14 | **E6** — DataFormat gate | Execute D5 (likely park + record the reopening trigger) — XS, can ride along with row 13 | E · E6 | — | ☐ |
| 15 | **DA1** — JCEF spike | jcefmaven on JDK 26 against the live shell — **closes engine gate D1**; gates rows 16–19 | DA · DA1 | `next/DA1` | ☐ |
| 16 | **DA2** — tabbed shell window | `DesktopUi` v2: tab strip + per-project embedded browser views | DA · DA2 | — | ☐ |
| 17 | **DA3** — Windows installer | jpackage app-image + MSI, jlink runtime, `RELEASING.md` rewrite | DA · DA3 | — | ☐ |
| 18 | **DA4** — Linux bundle | deb + rpm via the same pipeline; AppImage evaluated | DA · DA4 | — | ☐ |
| 19 | **DA5** — desktop polish | Single-instance focus (deletes SH2's bind-failure pane), window state, branding, shortcuts | DA · DA5 | — | ☐ |
| 20 | **SH5** — hosting hygiene + 304s | `ConditionalHeaders` × 3 servers, dead-Spring deletion, `main`-alias registration — *pull-forward, cheapest win here* | DA/SH · SH5 | — | ☐ |
| 21 | **FL5** — Flow editing UX | Move commands, auto-pipe routing tool, row/column shifting — *pull-forward* | FL · FL5 | — | ☐ |
| 22 | **FL6** — Flow expressiveness gate | Decide multi-output / pipe crossing / nested-loop semantics, then build or document | FL · FL6 | — | ☐ |
| 23 | **C1** — define-cost measurement | The per-keystroke number that gates row 24 — micro-session, *pull-forward* | C · C1 | — | ☐ |
| 24 | **C3** — incremental define | Per-object definition cache — **only if row 23 convicts**; drop with evidence otherwise | C · C3 | — | ☐ |
| 25 | **C2** — manual smoke debt | The consolidated browser checklist from ~15 headless sessions — **needs the user** | C · C2 | — | ☐ |
| 26 | **C4** — housekeeping verdicts | TP2 formally closed, `NotationCodec` adoption follow-up — XS, rides along with anything | C · C4 | — | ☐ |
| 27 | **J6** — fan-out topology | `TeeWorker` + list-typed channel ports — **demand-driven; pull only when a real flow needs it** | J · P6 | `next/J6` | ☐ |
| 28 | **CTX** — context + slot-owned resources | First-class `Context` notation objects, engine slots replace `ResourceScope`, provides/requires/releases validation + UI, `ResourceClosePolicy` → 3 values — **3 sessions (A engine+runtime / B validation+notation sweep / C UI+docs)** | — (standalone) | `next/context-and-resource` | ☑ 2026-07-29 |
| 29 | **CTX2** — export-chain ownership | Replaces CTX's nearest-slot binding: `context.exports` export signature (un-exported provides are private), bind-time export-chain climb, `context.slots` retired, requires-not-provided → blocking error — **3 sessions (A kzen-lib engine+spec / B analysis+runtime+notation+fixtures / C UI+docs+smoke)** | — (standalone) | `next/context-moved-ownership` | ☑ 2026-07-29 |
| 30 | **XC-N a** — frame-addressed move target (kzen-lib) | `MoveTarget` (id + call-site path) replaces the tree-wide broadcast, `Execution.moveDescendCallSite`, per-node suffix assignment, `logic-spec` §4/§5 + `Repositionable` + `Execution.host` KDoc. **DEFECT fix, part 1** — see § XC. As-built additions: `Repositionable.canDescendThrough` (keeps the driver flavour-agnostic) and a transit-frame `position` write in `RunEngine.host` | — (standalone) | `next/nested-frame-move-to` | ☑ 2026-07-30 |
| 31 | **XC-N b** — nested-frame move-to (kzen-auto) | Controller gates on the *addressed frame* (liveness / addressability / loop-body / descent capability), transit-frame descend in `ScriptRunContext.restore`, client drag in any live frame, 9 new fixtures. **DEFECT fix, part 2** — straight-line + `If`-nested shapes; ~~loop-hosted waits on the parked loop-body extension~~ **loop-hosted transit shipped in row 32** | — (standalone) | `next/nested-frame-move-to` | ☑ 2026-07-30 |
| 32 | **XC-N c** — post-smoke defect fix (kzen-auto) | The user's §9 manual smoke on `FizzBuzz Script Loop` found XC-N1 silently doing nothing. Three defects: **(a)** loop-hosted *transit* was refused on a **false** rationale — the walk already resumes mid-iteration, so `isDescendableCallSite` split off `plan` and dropped the `rerun` clause (targets keep it); **(b)** control errors were attributed to the run-root document, so nested rejections rendered on the *parent* — `controlAsync` now takes an explicit `documentPath`; **(c)** the drag handle painted valid against a guaranteed refusal — the margin now evaluates the whole frame spine. Plus rejection **reasons** end-to-end (`LogicControlReply` / `RepositionDiagnostic` / `MoveToRefusal` / `ScriptJumpRefusal`), kzen-lib untouched. See `next/nested-frame-move-to` §14 | — (standalone) | `next/nested-frame-move-to` | ☑ 2026-07-30 |
| 33 | **CX1** — context defects + the row split | `allContexts` no longer returns the abstract base (**defect** — `inheritanceChain` includes self, so `Context` matches its own filter); picker shows type + description; **Requires / Provides rows replace the Role dropdown**; exported/private chips have explicit badges and accessible text. **Depends on no design verdict** | CX · CX1 | `next/CX` | ☑ |
| 34 | **CX2** — address algebra (kzen-lib) | `ContextKey` / `ContextFamily`, `ExportSelector.Exact/Family`, `BindingLookup.Missing/Present`, exact + family gates, qualified-export and present-null tests; typed overloads retain deprecated composed adapters. Ends green and published to mavenLocal | CX · CX2 | `next/CX` | ☑ |
| 35 | **CX3** — binding/disposal split (kzen-lib) | **The arc's structural change and biggest implementation risk.** Separate binding/disposal registries; `bind` / `binding` / `releaseBinding` + keyless `onSettle`; one-shot `FrameDisposal`; explicit settlement state table (including root/manual and failed retention); export climb on bindings; migration fixtures; composed form proves parity. Ends published to mavenLocal | CX · CX3 | `next/CX` | ☑ |
| 36 | **CX4** — declarations and addressing | Context becomes a concrete **nominal declaration** with `type: TypeMetadata` value contract, qualifier and optional interop key; canonical full-type default family; exact declared qualifiers vs family computed qualifiers; centralized typed-bind conformance; value-graph `bind` → `recordValue`. **Breaking** across shipped notation + ~20 fixtures | CX · CX4 | `next/CX` | ☑ |
| 37 | **CX5** — the Contexts document | New `Contexts` archetype + document + controller + ribbon/sidebar — **chrome** on the `ObjectRegistry` template, **payload** as `by: NestedList` nested objects (a spec payload has no `ObjectLocation`, so it cannot carry a nominal declaration — CX §3 I correction); list UI from `LogicSignatureEditor`; picker gains "New context…" writing into it. **1 session** — landed as 5 files + 1 test; a new document type needs **zero** registration points | CX · CX5 | `next/CX` | ☑ |
| 38 | **CX6** — the step vocabulary | **2 sessions (A vocabulary / B steps).** **A** — `ContextProvider` → `ContextBinder` + `ResourceOwner`; `provides:` → `binds:`, step `requires:` → `uses:` (~14 files, only 3 notation instance sites); migrate kzen-auto off the deprecated kzen-lib adapters — **☑ 38a landed 2026-08-02**; the two levels now differ in symbol *and* string, so a cross-level misread cannot compile, and `BrowserOpenStep` turned out to carry the same double-teardown the plan named only for `BrowserCloseStep`. **B** — `BindStep` / `UseContextStep` / `ReleaseStep` / `DisposeAtSettleStep` + `SelectContextEditor`; release invokes attached disposal once. No unsafe cross-step managed-resource handoff without a lease token — **☑ 38b landed 2026-08-02**; needed an unplanned **kzen-lib** fix (attribute `meta:` inherited most-distant-ancestor-wins, the opposite of values, so no subtype could refine an inherited attribute — the Context picker would have been inert on all four steps) | CX · CX6 | `next/CX` | ☑ |
| 39 | **CX7** — atomic call-site context binding | **2 sessions, split at the repo boundary (forced by mavenLocal).** **A (kzen-lib) ✅ 2026-08-02** — `Execution.host(initialBindings=…)` installs borrows before child run; migration ordering fixtures; spec addendum; the raw-string-surface verdict *(option (i), narrowed: `resource`/`resourceValue`/`releaseResource` un-deprecated as the supported raw interop layer, `declareExport(String)`/`hasResourceInFamily(String)` still deprecated)*. **B (kzen-auto) ✅ 2026-08-02** — `RunStep.contexts` maps callee slot to caller declaration; missing-vs-null and source→target assignability; `RunStepContextsEditor`; analysis credits the binding. Needed no `StepExecution` signature change (the run context reads the map off the running step, as it already does for `binds`), and found that only the SOURCE side can be rename-tracked — a notation map key is a raw string at every layer and no command renames one, so the callee side is mitigated by a loud error + warning rather than propagation | CX · CX7 | `next/CX` | ☑ |
| 40 | **CX8** — parallel-flavour reach gate | Inspect real Flow/Job/Report frame topologies; decide root-vs-worker signatures, borrow lifetime, sibling release and shared-parent write semantics. Records verdict + fixtures/implementation plan; **does not assume `context` simply lifts onto `Logic`** | CX · CX8 | — | ☑ |
| 41 | **CX9** — Flow context signature | Verdict-licensed by row 40: a Flow is **one frame for the whole DAG walk** (a vertex is a checkpoint, not a frame), so it takes the Script treatment unchanged — `context` on the `Flow` archetype, `declareExport` + requires gate in `FlowLogic.run`, `LogicContextAnalysis` wired into the Flow validator, `ContextSignatureEditor` mounted in `FlowController`, and `contexts:` on the `FlowLogicHost` vertex. **No new engine semantics.** M rather than S because `FlowRun.kt:221` passes neither `callerStableId` nor `initialBindings` today and must start supplying both. **⚠ RESCOPED at execution (user's call) — "the Script treatment unchanged" was false**: Flow vertices are *root* ObjectPaths, so `ScriptTree.read` yields an empty tree and `analyze` silently reports nothing; and a DAG has no linear "before", so the availability walk would need a fan-in join policy nothing in the arc decided. Landed as **document signature + call site only** — a Flow declares no per-vertex `binds`/`uses`/`releases`, so it requires, relays and supplies but never opens, and no DAG analysis is needed. See CX §8 Phase 9 | CX · 3 J verdict | — | ☑ |
| 42 | **CX10** — bootstrap/export ownership defect (kzen-lib) | **Defect in shipped code**, found by row 40 and independent of it: a callee declaring an export covering a key it was bootstrapped with binds *past* the borrow — `host` installs the bootstrap on the callee's frame, a later `bind` routes through `exportOwnerOf` which now climbs past it, so the value rests on the caller while the borrow shadows it and the callee **cannot see what it just bound**. Reachable from `RunStep.contexts` as shipped; `ExportSelector.Family` widens it to every qualifier. Behaviour pinned today by `RunEngineParallelBindingTest`; the fix flips that fixture's ⚠ assertion and re-publishes to mavenLocal | CX · 3 J verdict | — | ☑ |
| 43 | **CX11** — Job worker context capability | **Explicitly withheld by row 40's verdict — not licensed, and the row's first step is the engine decision, not the feature.** Two blockers, both structural: (a) concurrent siblings exporting one family collapse into a single slot on the Job frame, where the second bind closes the first's live resource underneath it and the loser silently reads its sibling's handle — the spec is *silent* on parallel frames and the engine lock does not make the winner deterministic; (b) a Worker is a **nested object, not a document**, and never sees its own `Execution` (`WorkerLogic` hands it only a `JobControl`, which has no binding member), so there is nowhere for a signature to attach and no read path. Decide first among: worker frames export-opaque by construction · concurrent same-key bind into a shared ancestor a hard error · per-frame isolation with an explicit merge. Then size the feature | CX · 3 J verdict | — | ☐ |
| 44 | **Report hostability invariant** | Found in passing by row 40, and a **Logic-composition defect, not a context one**: `ReportLogic`'s KDoc states a Report is "always top-level (never hosted)", but `ReportDocument` implements `LogicDocument`, `LogicCompiler` only *comments* the exception, and `SelectLogicEditor` offers any document passing `AutoConventions.isLogic` — which a Report does. A `RunStep` can be pointed at a Report today. Either enforce the invariant at both the picker and the compiler, or decide Report is hostable and give it the frame semantics that implies | CX · 8 (Phase 8) | — | ☐ |

**~40 sessions.** Rows 1–8 are the strategic spine and the bulk of the value; rows 9–14 unblock
third-party extensibility; rows 15–19 ship the desktop app; the rest are close-out. Rows 30–32 are
a **defect fix**, not new scope — sequence them by how much the broken affordance is costing, not
by position in this table. Rows 33–40 (**CX**) are the context arc's third/fourth pass, added
2026-07-31 and hardened 2026-08-01 on the first sustained use of CTX/CTX2 — row 33 is partly a defect
fix and independent; rows 34–35 establish the engine substrate for rows 36, 38 and 39.
A split row in progress carries `◪` with the landed half named, because one `☐`/`☑` cannot say "half".
**Rows 33–39 landed 2026-08-02, row 40 on 2026-08-03 — the CX arc is closed.** Row 39 was cross-repo and
split at the repo boundary: 39a (kzen-lib) published to mavenLocal with its artifacts verified on disk
(`InitialBinding.class` present, `Execution.host` carrying `List<InitialBinding>`), which is what 39b then
compiled against; note row 38b had already published kzen-lib once (an unforeseen metadata-inheritance fix),
so 39a's was the second such publish and mavenLocal holds a `0.30.0-SNAPSHOT` well ahead of the last tagged
one. With 39b in, the arc's headline capability is real and smoked end to end: one unedited sub-Script, run
twice against two different subjects, wired per call. Row 40 was the design gate, and it **did not** license
the lift it was gating: `context` does not go onto `Logic`, because the four flavours have three different
answers — see CX §3 J's verdict table. Its output is rows 41–44 below.

**Rows 41–44 are row 40's output, and they are not a block.** They differ in kind and should be sequenced
separately, not as a unit: **42 is a defect in shipped code** and the only one with a standing cost —
sequence it by that; **41 is the licensed feature** and the cheapest real capability left in the arc; **44 is
an adjacent defect** found in passing, small and independent; **43 is withheld**, and its first step is an
engine decision about concurrent frames that nothing else waits on. Nothing depends on 43, and a Job author
is no worse off than before the arc started.

**Row 42 landed 2026-08-03** — the defect is fixed and re-published to mavenLocal, so nothing in the tree is
running the broken supersede any more. The fix turned out to need a *path* walk rather than a single-frame
clear (an intermediate frame on the export chain can hold the shadowing borrow), and it was falsified before
being trusted: removing the one call fails exactly the two regression fixtures and leaves the three
concurrency characterizations green.

**Row 41 landed 2026-08-03**, rescoped — see its cell. The rescope is the useful record: row 40's gate proved
the Job case needed an engine decision, but it did *not* re-derive Script's analysis internals, so row 41
inherited an assumption ("takes the Script treatment unchanged") that the anchor pass falsified in three
independent ways. Both gates were doing their job; the second one caught what the first could not see.

**Next up: rows 43 and 44 remain, neither claimed.** Row 44 is small and independent; row 43 is still withheld
pending an engine decision about concurrent frames, and nothing waits on it. With 41 and 42 in, the CX arc's
follow-on work is down to one defect and one deliberately-open design question.

### What to run right now

Row 1 (**J3a**). If a change of pace is wanted, rows **20 (SH5)**, **23 (C1)**, **21 (FL5)** and
**15 (DA1)** are all independent and can be taken at any point. Rows **9 (E1)** and **25 (C2)**
need the user present — schedule them rather than waiting for a gap.

Rows **30–32 (XC-N)** are independent of everything above and are a **defect fix** — a shipped verb
that does not do what its spec says. Row 30 must precede row 31 (kzen-lib → `publishToMavenLocal` →
kzen-auto); row 32 is the post-smoke follow-up and is kzen-auto-only. **All three are done** — what
remains is the user's re-smoke, which needs a dev-server restart.

Row **33 (CX1)** is the other genuinely-independent pull-forward: it carries a real defect (the
Context picker offers the abstract base, because `inheritanceChain` includes the object itself) plus
the Requires/Provides split, and it depends on **no** design verdict in the CX document. The user
reviewed and ratified the document's nominal auto-wire and N4 naming verdicts on 2026-08-01, so the
rest of the arc no longer waits on review. **Rows 34 → 35 are the kzen-lib substrate**; row 35 gates
rows 36, 38 and 39. Row 40 remains a design gate by intent, not because it awaits document approval.

## Dependency rules (the live ones)

1. **J3 → J4 → J9** — the spine; J9 touches the same Explore/Export code J4 reshapes.
2. **J8 after J3** — it consumes phase 3's editor/schema fallback.
3. **The element model's phase 4 executes inside J5** — benchmark first; build reuse only where the
   benchmark convicts allocation. **Hard constraint: migration carryover (`JobChannel.drainBuffered`)
   captures live messages, so a pool must transfer ownership, never recycle.**
4. **J6 is demand-driven** and blocks nothing.
5. **E1 ratification before E2–E6.** E4's **C7 half is the exception** — the document-rename gap is a
   settled finding with an `@Ignore`d test already committed, and can run any time.
6. **E2 (was R5) needs `publishToMavenLocal` discipline** for `kzen-auto-plugin`, and any Kotlin test
   plugin must live in a **separate module** — KSP2 processes kzen-auto-jvm's test source set, which
   is why `kspTestKotlin` is disabled there.
7. **DA1 gates DA2+** (engine gate D1). **DA5 replaces SH2's bind-failure pane** —
   `DesktopUi.showBindFailure` + the `FreePortUtil.isTcpPortFree` pre-flight are both marked for
   deletion there; don't leave two paths.
8. **SH5 item 7 (docs-to-truth) prefers to run after DA5**, since DA2–DA5 churn the same surface.
   Ship SH5 items 1–6 immediately; fold item 7 into DA5.
9. **C1 gates C3** — measure per-keystroke define cost first and **record the number either way.**
   Take the measurement on current `main`: the 2026-07-23 document-digest change moved this
   neighbourhood.
10. **FL6 after FL3** — satisfied (FL3 landed 2026-07-21), so the gate is open.
11. **R6 is closed, no session** — the client-plugin verdict is recorded in the E plan's tracker.
12. **TP2 is closed, no session** — superseded by TP3, which landed 2026-07-16. Formalized in C4.
13. **CX1 is independent; CX2 → CX3 → CX4 is the engine/declaration spine.** CX5 needs CX4; CX6
    needs CX3+CX4; CX7 needs CX3+CX4 and should follow CX6 to avoid a second notation sweep. CX8 is
    a design gate after CX7, not authorization to lift `context` mechanically onto every Logic flavour.

## Carried over from Sprint 2

**What shipped.** The general-purpose platform work landed in full: transport is byte-efficient
(gzip, binary-by-handle, exact structural re-fetch), there is **one JSON codec per process**
(Jackson survives only in launcher YAML), comments and formatting survive notation edits, failures
name their origin instead of "Missing: main", and detached actions build only their own closure.
On that substrate the flavours advanced hard — the Job signature became a typed element model
(`JobMessage` payloads with inferred types flowing through the graph), Flow got its vertex
capability SPI, the client converged onto one commit primitive and one select base, and the
platform trio gained child-exit detection, atomic registries and a project upgrade path. A
flavour-agnostic validation indicator arrived late in the sprint and closed a real correctness bug
(validation results shown for the wrong code revision).

**What it left owed**, and where it now lives:
- **Manual browser smoke from ~15 headless sessions** → ledger row 25 (C · C2), consolidated by
  surface into one runnable checklist. This includes the never-run §6 smoke of the validation-digest
  handshake, recovered from a deleted plan.
- **G4's measurement gate**, still honest after two sprints → rows 23–24.
- **The whole DA arc**, planned 2026-07-18 and never started → rows 15–19.
- **EXT D1–D6**, awaiting ratification since 2026-07-06 → row 9.

**Full per-session record:** `sprint-2/README.md`. It also records four arcs that landed **without
a surviving plan** — the validation indicator, the digest handshake, the document-digest fix and the
`RestHandler` split — recovered from git so the work is not invisible.

**A process note worth keeping.** Three plans were *deleted* rather than archived on 2026-07-23,
taking their deferred scope and pending manual smoke with them, and the `RestHandler` split silently
invalidated line anchors in four unexecuted plans. **Convert a completed plan into an as-built record
in the sprint archive; delete only the elaborations under `plans/next/`.**

## Deferred & resolved (self-contained)

### E6 — multiple concurrent runs: DEFERRED (2026-07-16, still deferred)

Not needed yet; a readiness review confirmed **nothing precludes it**, and the migration surface
stayed concentrated in `ServerLogicController` as intended. Already multi-run-ready: the engine core
has no process-global singletons; `runId` is a first-class key on every verb; per-run flags live on
`LogicState`; `LogicRunInfo` is runId-addressed.

**Design decisions made (reuse when reviving):** `stateOrNull` → `LinkedHashMap<LogicRunId, LogicState>`;
`start()` stops refusing while a run exists; **one driving executor per run** (a shared executor
would serialize unrelated runs and break per-dispatcher `awaitQuiescent` counting); wire
`LogicStatus.active` single→list; retention = active runs + the most-recent settled run **per root
document**; per-run thread budget via a `RunEngine` constructor default the controller lowers to
~`max(2, cores/2)` — **not** a shared dispatcher; client `ClientLogicGlobal` re-keys state per root
document (the widest client audit — do it after any client-global additions have settled).

**Six friction points a future E6 must handle:**
1. The `anyRunActive` eviction gate in `KzenAutoContext` must become "no run active at all".
2. Content-addressed work dirs are **not** runId-partitioned (`JobWorkPool.workerOutputDir` is
   notation-keyed; `ReportWorkPool.resolveRunDir` content-keyed) — decide partition-by-runId vs
   forbid concurrent same-document runs.
3. The original design bullet predates E5's wire reshaping (epoch/sequence, SSE) — re-derive the wire
   shape.
4. Re-check `kzen-lib/docs/logic-spec.md` §2 against reality when reviving.
5. The per-run thread-budget config hook doesn't exist yet.
6. The `CachedKotlinCompiler` race E6 earmarked is **already fixed** (per-signature `Striped.lock` +
   Caffeine, 2026-07-11). A *second* `CachedKotlinCompiler` bug was fixed 2026-07-22: a compile
   interrupted mid-flight persisted a spurious error to the durable `code-cache`, permanently
   poisoning that expression until the work dir was cleared.

Also engine-adjacent, known and accepted: concurrently-live children of the *same* document (possible
in Job) still alias by stable id at the migration barrier.

### E5 residuals

- **Step budget** (`Run.step(mode, count)`) deferred — no consumer (the 750 ms auto-step dwell is
  hardcoded; no speed UI). Revive only with a driving UI.
- **Live-view delta fetch** descoped to sequence-gating — deltas would need engine-side reset
  tombstones (`resetEmitted` clears live values a delta pass would miss and ghost).
- **E4 residual** (low impact): the engine keeps `log` events of compacted `retainTrace=false` frames
  in history.

### Script S6 — REVERTED (settled semantics)

Nesting-aware step-over/out landed 2026-07-12 and was reverted 2026-07-13 after live use:
auto-step-over blasted a whole ForEach in one tick and step-out exited just the branch.
**Frame-only step-over/out is the settled semantic** (classic debugger: skips calls/frames, not loop
bodies). The ForEach iteration-counter trace detail (`"$item (i of n)"`) stays. **Do not resurrect
nesting-aware limits without a new UX design.**

### XC (execution control) — NOT complete: one defect open, one v2 extension parked

Move-to-step + continue/break/return all landed. Corrected 2026-07-30 (was recorded here as
"COMPLETE"), on the finding in `next/nested-frame-move-to.md`:

- **DEFECT — move-to is gated to the run-root frame** (ledger rows 30–31). Dragging the next-to-run
  arrow inside a sub-Script does nothing: the glyph renders inert and *indistinguishable from the
  "run is executing" state*. **No spec asserts this restriction** — `logic-spec.md` §4,
  `kzen-auto/docs/architecture.md` and `Execution.moveTarget`'s own KDoc all describe move-to
  frame-agnostically, and the KDoc says outright that "the root and hosted children may all read it".
  Breakpoints already work nested and step into/over/out already cross frames, so move-to is the one
  execution-control verb that is not frame-agnostic. The gate lives only in code, labelled "v1".
  **Do not document this as a limitation** — it is an unfinished implementation, not a boundary.
- **A second, independent defect in the same feature — FIXED 2026-07-30.** A backward jump past a
  completed RunStep did not discard the abandoned sub-Script invocation's migration capture, so the
  re-hosted child replay-short-circuited and handed back stale values. One line in
  `ScriptRunContext.restore` + `ScriptMoveToTest` coverage; full `kzen-auto-jvm` suite green.
- **v2 extension (genuinely parked, not a defect):** loop-body jump targets via S5's `LoopCursor`
  carry (v1 rejects targets inside `rerun` branches — a documented, deliberate exclusion with an
  explicit rejection path). This is what blocks the loop-hosted shape of the defect above, which is
  why row 31 covers only the straight-line / `If`-nested shapes.

### Target (FE) — COMPLETE, gates closed

All seven phases landed 2026-07-12. **FE7 verdict: browser-first stands** — desktop capture is a
capture-source convenience only; `ScreenshotTaker` is the future desktop hook and the locator SPI's
driver-typed context is the retype seam; reopen only if desktop RPA becomes near-term. FE4's
live-browser capture source was skipped (the trace film strip covers the workflow) — now feasible if
wanted, since S2 (engine-carried browser handle) landed.

### EXT-D5 (DataFormat) — parked pending ratification

Endorsed: park/retire until a consumer exists — *"redesigning a schema document before a consumer
exists is how it got here."* Reopen trigger: a real consumer for field/type schemas. Formalized at
ledger row 14.

### Rename refactor — known limitation

A rename refactor does **not** cascade to a directory's children: `RenameDocumentRefactorCommand`
copies only the marker document, so renaming a non-empty folder orphans its contents. Separate from
the C7 nested-exports gap (ledger row 12) — don't conflate them.

## Verification

Docs-only meta-plan: no build/test verification. Per-phase verification lives in each constituent
plan and is unchanged by this document.
