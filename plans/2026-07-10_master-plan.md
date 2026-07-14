# kzen improvement epic — master plan (sequencing across all plan documents)

> **Status: meta-plan.** Written 2026-07-10 from a full review of the ten live plan documents in
> `kzen/plans/`. This document decides **when** — the constituent plan remains the sole authority
> for **how** (goals, design decisions, file anchors, verification). Executor: **Opus 4.8 xhigh,
> one constituent-plan phase per session**, picked from the current stage below.
>
> Maintenance rule: when a phase lands, tick it in its own plan's tracker (as every plan already
> requires) **and** strike it from the stage table here. If priorities shift, reorder stages 5–8
> freely (they are mutually independent — see "Parallelism"); do not reorder within stages 1–4
> without re-checking the dependency map. Constituent plans do not point back here (one-way
> reference, no churn).

## Constituent plans

| ID | Document | Scope | Phases | Status |
|---|---|---|---|---|
| E | `2026-07-05_logic-engine-improvements.md` | RunEngine core (kzen-lib) + controller/transport | E1–E7 | in progress (E1–E2 ✓ 2026-07-12) |
| G | `2026-07-05_graph-improvements.md` | Notation→Definition→Instance stack (kzen-lib) | G1–G7 | in progress (G1 ✓ 2026-07-12, G2 ✓ 2026-07-13) |
| S | `2026-07-06_script-improvements.md` | Script flavour, all layers | S1–S8 | in progress (S1 ✓ 2026-07-11, S2 ✓ 2026-07-13, S3 ✓ 2026-07-13, S4 ✓ 2026-07-13, S6 ✓ 2026-07-12 then reverted 2026-07-13) |
| J | `2026-07-06_job-improvements.md` | Job flavour + Report subsumption | J1–J9 | planned |
| FL | `2026-07-06_flow-improvements.md` | Flow flavour, all layers | FL1–FL6 | planned (FL6 = gate) |
| FE | `2026-07-06_target-improvements.md` | Target (element targeting) + vision | FE1–FE7 | in progress (FE1 ✓; restructured + renamed 2026-07-12; FE7 = gate) |
| SH | `2026-07-06_shell-launcher-project-improvements.md` | Shell/launcher/project trio | SH1–SH5 | pruned 2026-07-10 |
| EXT | `2026-07-06_custom-plugin-extensibility-analysis.md` | Custom/Plugin/Registry/DataFormat | S1–S10 + D1–D7 | **analysis — needs ratification** |
| Y | `2026-07-10_yaml-parser-strings-and-comments.md` | YamlParser bare strings/comments/`\|-` | W1–W8 (one arc) | proposed |
| XC | `2026-07-10_execution-control.md` | Move-to-step (Set Next Statement) | XC1–XC3 | planned |
| SER | `2026-07-13_serialization-improvements.md` | Wire serialization (kotlinx convergence) | SER1–SER5 | in progress (SER1 ✓ 2026-07-13; SER3 = gate) |

~63 sessions total at one phase per session (E:7, G:7, S:8, J:9, FL:6, FE:7, SH:5, XC:3, Y:~2,
SER:5, EXT: 1 decision + ~5, gates: 0–2). Stages below group them so the order is decided once,
here.

## Cross-plan dependency map (the real edges)

Hard edges (do not start the right side before the left is checked):

- E1 → E2 → E3; E2 → **XC1 → XC2 → XC3**; E2 → S6 (same `checkpoint` signature churn — land
  adjacently); E2 → E4 → E5 → E6.
- G1 → G2 → G3; G1 → G4. G2 before S3 and before XC2 *if* they are to work in the digest domain
  (notes added in those plans); otherwise they land against `closureNotations` and G2 migrates
  them.
- S2 → S5 (migration-state shape settles first). J3 → J4 → J9. FE2 → FE4 → FE5 → FE6; FE1 → FE5.
  (FE renumbered 2026-07-12: old FE2+FE3 merged into new FE4; new FE2 = correct-clicking bug,
  new FE3 = step-editor polish.)
- Y → G7 (shared `unparseDocument`; one-time format churn must precede byte-identical
  preservation — cross-refs added in both plans).
- SER2 → SER3 → SER4 → SER5 (strict chain; SER3 is a payoff gate — a "stop" verdict drops
  SER4 and SER5's kzen-auto items). SER1 is prerequisite-free; SER5's launcher/shell items
  need only SER1.
- E4 ships the `Execution.emit(retain:)` flag (added 2026-07-10); S7's transient emits and
  J1/J7's non-retained progress markers adopt it *after* E4.
- XC1–XC3 and S8 (client conventions) before **E6** (multi-run re-keys `ClientLogicState` per
  document — the widest client audit; everything client-global should exist by then so the audit
  covers it once).

Soft edges (recommended order, not blocking): SER4 before E5 (E5's push format should reuse the
kotlinx trace/status DTOs; if E5 runs first it lands on the map codecs and SER4 migrates them);
E3 before XC3 (shared per-step affordance home);
S8 before FL4 (S8 defines the render-scoping conventions FL4 applies); S2 before FE4's stretch
goal (live-browser capture); E3+E5 before J7's gated parts; J1 before J8 (constants), J3 before
J8 (editor fallback); FL1 before FL2 (tests as net); EXT-S7 coordinates with FL5 (whoever runs
first ports `PluginController` off the legacy editor).

## Hot seams — one rule each

Files/concepts touched by 3+ plans; the sequencing rules that prevent re-churn:

1. **`ServerLogicController`** — touched by E1a/E1f/E2/E4/E6, G2/G3c, S3, XC2c. Rule: **E6
   (multi-run map restructure) lands last** among these; everything else is written single-run
   and E6's audit migrates it once.
2. **`RunEngine.migrate` barrier** — extended by S2 (lifted resources), XC1 (moveTarget), split
   by E4 (shutdown/dispose). Rule: land S2 and XC1 **adjacently** (same code region, same test
   file), both before E4's lifecycle split.
3. **`ScriptRunContext.runSteps` checkpoint call site** — E2 (`at:`), S6 (`nestingDepth`), XC2
   (descend suppression). Rule: E2 → S6 → XC2, each a mechanical merge over the previous.
4. **The pendingMigration baseline signal** — E1f (dirty flag), G2 (digest replaces notation-map
   compare), S3 (widen to linked documents), XC2c (moveTo updates baseline). Rule: **G2 first**,
   then S3/XC2c work in the digest domain (adaptation notes added 2026-07-10).
5. **`YamlNotationParser.unparseDocument`** — Y (emitter rework) + G7b (template-respecting
   deparse). Rule: **Y first**.
6. **`ScriptDependencyAnalysis.branchAttributeNames`** — S8c (metadata discovery) + XC2a (jump
   analysis reuses the same seam). Rule: both sit behind one function; whichever lands first,
   the other reuses it (already noted in both plans).
7. **`logic-spec.md` §4/§5** — E2/E3/E5, S2/S6, XC1/XC2 all amend it. No ordering beyond the
   code ordering above; every plan already requires same-session spec updates.

## Review findings (2026-07-10)

Individually, all ten documents are sound: consistent house style (goal / pre-made decisions /
anchors / verification), honest risk labelling, and correct "covered elsewhere" fences — no
duplicated work was found between any two plans. Cross-document, these gaps were found and fixed:

1. **E4 lacked the transient-emit flag** that S7 explicitly says to record there and that J1/J7
   assume ("adopt the engine flag when it lands"). *Fixed: bullet added to E4.*
2. **Y × G7b were mutually invisible** despite sharing files and an ordering constraint.
   *Fixed: cross-refs both ways.*
3. **S3 was specified against `closureNotations`, which G2 deletes** — the two plans rewrite the
   same signal with no coordination note. *Fixed: digest-domain adaptation notes in S3 and G2.*
4. **XC referenced `baselineNotations`** by its pre-G2 name. *Fixed: parenthetical in XC
   decision 10.*
5. **The job plan claimed `2026-06-23_job-paradigm.md` "is retained"** — it was deleted from
   `plans/` in commit `ef0dbd4`. *Fixed: wording now says git-history-only, with the recovery
   command.*
6. **XC-vs-E6 ordering was nowhere stated** (XC3 binds to today's single-run
   `ClientLogicState`). *Resolved here: XC before E6 (hot-seam rule 1).*
7. **EXT ratification (D1–D7) was not scheduled anywhere.** *Resolved here: stage 9 opens with a
   decision session.*

Push-backs / judgement calls (recorded here, not edited into the plans):

- **SH1 is the single most urgent item in any plan** — a cross-site GET from any web page can
  delete projects, spawn arbitrary jars, and reach proxied Script execution (= RCE), plus
  trust-all TLS on executable downloads. It is buried as phase 1 of the trio plan; this epic
  runs it **first, before everything**.
- **G4 (incremental define) should be gated on measurement**, not scheduled by default: G1
  already collapses per-command defines to one per notation version, and G4 is the graph plan's
  own "riskiest" phase. Run G1+G2, measure the per-keystroke define cost on a large project, and
  execute G4 only if it still hurts. (The graph plan already allows reordering; this epic slots
  G4 last in stage 7 with that gate.)
- **J6 (fan-out/TeeWorker) is capability without a driving document** — keep it in stage 5 but
  treat it as demand-driven; J2→J3→J4→J9 (the Report-subsumption arc) is the strategic spine and
  should not wait on J6.
- **Y is the only plan without the house header** (no executor line, no tracker). Fine as-is for
  a ~2-session arc; add a tracker only if it splits across sessions.
- **EXT-D5 (DataFormat)**: endorse the analysis's own recommendation — park/retire until a
  consumer exists; do not let stage 9 turn into a schema-document redesign.

## The stages

Recommended spine: 0 → 1 → 2 → 3 → 4, with stages 5–8 interleavable against 2–4 whenever a
change of pace or a mavenLocal-publish wait makes it convenient (see Parallelism).

### Stage 0 — standalone urgent fixes (7 sessions)

All prerequisite-free; each is a user-facing correctness or security fix (SER1, added
2026-07-13, is the exception: a small self-contained hygiene win slotted here per priority
call). **SH1 first**, rest in any order.

| Session | Phase | Why here |
|---|---|---|
| ~~0.1~~ ✓ 2026-07-10 | **SH1** trust-boundary hardening | CSRF→delete/spawn/RCE + trust-all TLS; most urgent item in the epic |
| ~~0.2~~ ✓ 2026-07-11 | **J1** progress wire contract + bounding | fixes the live Pivot-teaser bug; stops history leak |
| ~~0.3~~ ✓ 2026-07-11 | **FL1** structure core tests + OptionalInput + lint | pins the untested load-bearing layer before FL2 |
| ~~0.4~~ ✓ 2026-07-11 | **FL2** run loop: instance-per-run + non-fatal tracing | kills the FlowMessageInspector run-killer + N×V rebuild |
| ~~0.5~~ ✓ 2026-07-11 | **S1** expression engine | classloader-per-iteration + diagnostic-text inference; highest value/risk in the script plan |
| ~~0.6~~ ✓ 2026-07-12 | **FE1** vision core hardening | tests + 10× matcher constants + DOM-mutation fix |
| ~~0.7~~ ✓ 2026-07-13 | **SER1** launcher codec convergence | finishes the half-done kotlinx migration; drops Jackson 2 from the launcher server; proves `ktor-serialization-kotlinx-json` before SER2–5 touch kzen-auto |

Exit: no cross-site reachability into the shell/launcher; Pivot card live; a Flow trace can
never kill a run; formula evaluation is O(map-lookup); the matcher is tested and benchmarked.

### Stage 1 — kzen-lib foundations (6 sessions)

The engine/graph phases everything else keys off. E and G interleave freely (disjoint code).

Order: **E1 → E2 (+ S6 immediately after) → E3**, and **G1 → G2** (any interleaving).

- ~~E1~~ ✓ 2026-07-12 — engine hot path + pause-overrides-stepping (+ E1f edit-dirty flag).
- ~~G1~~ ✓ 2026-07-12 — definition caching + correctness cliffs.
- ~~E2~~ ✓ 2026-07-12 — `checkpoint(at:)` + engine-owned position; retires `$next-step`. Unblocks XC and S6.
- ~~S6~~ ✓ 2026-07-12 — inline-branch stepping (`nestingDepth`) — rode directly on E2's signature
  churn (hot-seam rule 3), merged over the same call site. **REVERTED 2026-07-13** (user decision
  after live use): nesting-aware limits made auto-step-over blast a whole ForEach in one tick and
  step-out exit just the branch instead of the document. Step-over/out are frame-only again
  (classic debugger: step-over skips calls/frames, not loop bodies). The ForEach iteration-counter
  trace detail landed with S6 and stays. XC2 now merges over the simpler (E2-shaped) call site.
- ~~G2~~ ✓ 2026-07-13 — closure content digest; retires `baselineNotations` (hot-seam rule 4).
- ~~E3~~ ✓ 2026-07-13 — breakpoints (run-to dropped per user decision — breakpoints subsume it;
  also the "run up to a step" user ask: breakpoint + Run + remove).

Exit: positions on the wire; breakpoints usable (run-to = breakpoint + Run + remove); one
`tryDefine` per notation version; digest-based migration signal.

### Stage 2 — Script live-edit correctness (4 sessions)

The pause → edit → resume story. Order: **S2 → S3 → S5**; S4 anywhere in the stage.

- ~~S2~~ ✓ 2026-07-13 — resources survive migrate (fixed "edit quits the browser"; engine lifts
  registrations at the barrier + stores the handle value; `ScriptRunResources` deleted — hot-seam
  rule 2 pairs the migrate-barrier region with XC1 in the next stage).
- ~~S3~~ ✓ 2026-07-13 — linked-document live edit (digest-domain per the G2 note; also fixes Job
  `RunWorker` and Flow `RunLogic` callees generically — `LinkedLogicDocuments` widens the
  controller's digest signal, no kzen-lib change).
- ~~S4~~ ✓ 2026-07-13 — validation once per notation version (reused G2's digest via S3's
  `LinkedLogicDocuments` widened signal; registry-scan component added — see the S-plan as-built).
- S5 — mid-loop migration resume (loop cursors; also XC's v2 extension point).

Exit: browser survives any edit; callee edits migrate the caller; validation cached; loops
resume at their iteration.

### Stage 3 — execution control (3 sessions)

The VB "Set Next Statement" arc — the reason this review happened. Prereqs all met by stage 1
(E2 hard, E3 soft, S6 already merged at the checkpoint call site).

**XC1 → XC2 → XC3.** Land XC1 adjacent to S2's migrate work if the schedule allows (hot-seam
rule 2). XC3 joins whatever affordance home E3's UI created.

Exit: move-to-step works end-to-end — backward re-run, forward skip with `Skipped` display and
the `referencedValue` backstop, error-park escape.

### Stage 4 — trace & transport (5 sessions)

The engine back half. Order: **E4 → S7 → E5 → E6**; E7 anywhere after E1 (slot it here by
default, or use it as a filler session anytime).

- E4 — trace unification (riskiest engine phase; survey-first; now ships `emit(retain:)`).
- S7 — trace bounding + adopt transient emits (J-side adoption rides J7 or a micro-session).
- E5 — SSE push + incremental fetch + step budget.
- E6 — multiple concurrent runs (the client-global audit; last per hot-seam rule 1).
- E7 — `blocking { }`, typed capture, structured failure.

Exit: one trace store; sub-1.5 s UI updates; N concurrent runs; blocking third-party calls don't
starve the engine.

### Stage 5 — Job: Report subsumption (8 sessions)

Independent of stages 2–4 except where marked; interleave at will. The strategic arc is
**J2 → J3 → J4 → J9**; the rest slot around it.

- J2 — Job signature (parameters in, results out; composition centerpiece).
- J3 — pluggable input formats + design-time services.
- J4 — export parity + offline persistence + Report deprecation checklist.
- J9 — file-backed carry-forward (after J4; same files).
- J5 — benchmark + headless mode (anytime; benchmark-first).
- J6 — fan-out topology (demand-driven; see push-backs).
- J7 — per-worker outcomes + deadlock precision (gated parts want E3+E5 from stages 1/4).
- J8 — client sweep + hygiene (last; wants J1+J3).

Exit: composed A/B gate green (same dataset through Report and Job — identical bytes); Report
frozen; a headless run is "the same Job minus observability".

### Stage 6 — client convergence + Flow/Target capability (9 sessions; FE3 can ride with FE2)

- S8 — Script client sweep **first** (defines the render-scoping conventions; also delivers 8c's
  notation-driven branch discovery that XC2a shares).
- FL3 — vertex SPI capabilities (after FL2 from stage 0).
- FL4 — Flow client perf + error visibility (applies S8's conventions).
- FL5 — Flow editing UX (move/auto-pipe/shift; coordinate EXT-S7's `PluginController` port).
- FE2 — correct-clicking bug (live regression in the user's working Script — **pull forward out
  of stage order as needed**); FE3 — step-editor polish (small; can ride with FE2).
- FE4 → FE5 → FE6 — View/Add split + capture sources (the stretch goal benefits from S2 having
  landed in stage 2), then tolerant matching, then the open target-type SPI.

Exit: third-party proofs green on both SPIs (synthetic capability vertex; synthetic
`CssSelectorTarget`); no O(V²)/O(steps×branches) render paths left.

### Stage 7 — graph ergonomics + notation format + wire serialization (10 sessions)

- G3 — scoped instantiation + instance caching (pull earlier if Report-panel latency bites).
- G5 — codec layer + notation-driven `isLogic` marker.
- G6 — structured definition/creation error surface.
- **Y → G7** — yaml parser rework, then reducer split + template-respecting deparse (hot-seam
  rule 5).
- G4 — incremental define, **only if the post-G1 measurement demands it** (see push-backs).
- **SER2 → SER3 (gate) → SER4 → SER5** — kotlinx.serialization wire convergence in
  kzen-lib/kzen-auto (independent of the G/Y items; interleavable anywhere after SER1, but
  SER4 before E5 is the soft edge — pull the chain earlier if stage 4 approaches E5 first).
  A "stop" verdict at SER3 drops SER4 and shrinks SER5 to its launcher/shell items.

Exit: comments/formatting survive edits to other objects; one-object instantiation for detached
actions; failures name their origin; one JSON codec per process (Jackson 2 off every classpath).

### Stage 8 — platform trio remainder (4 sessions)

Fully independent track (different repos); interleave anywhere after SH1.

**SH2 → SH3 → SH4 → SH5** (SH5 last — it's the docs-to-truth sweep over whatever 1–4 changed).

Exit: crashed children surface + restart; registries atomic; template extension works
out-of-box; project upgrade path; 304s through the proxy.

### Stage 9 — extensibility (1 decision session + ~5 build sessions)

1. **Decision session**: ratify D1–D7 (recommendations are in the analysis; D1 —
   plugin-shipped `ModuleReflection` registration — is the strategic one and reshapes D2–D4).
   Promote the analysis to `2026-07-XX_extensibility-improvements.md` in house plan format.
2. Hygiene phase (EXT S1–S10) — plan-ready **now**; may run any time earlier as an opportunistic
   session (coordinate S7-item with FL5).
3. D1 implementation + plugin UX + Custom power + registry disposition per the promoted plan.

Exit: `../kzen-sample-plugin` contributes a working `@Reflect` step/prototype with zero
kzen-source edits.

### Stage 10 — decision gates (0–2 sessions)

Deliberately last, decisions-not-code first: **FL6** (multi-output / crossing / nested-loop
semantics), **FE7** (desktop actuation or park), and the EXT-D5 reopening trigger review. Each
may resolve as a docs-only session.

## Sequence at a glance

```
Stage 0  SH1 · J1 · FL1 · FL2 · S1 · FE1 · SER1    (independent; SH1 first)
Stage 1  E1 → E2 → S6 → E3   ∥   G1 → G2          (kzen-lib foundations)
Stage 2  S2 → S3 → S5   ·  S4                      (live-edit correctness)
Stage 3  XC1 → XC2 → XC3                           (move-to-step)
Stage 4  E4 → S7 → E5 → E6   ·  E7                 (trace & transport; E6 last)
Stage 5  J2 → J3 → J4 → J9   ·  J5 · J6 · J7 · J8  (Report subsumption)   ─┐
Stage 6  S8 → FL3 → FL4 → FL5 · FE2 → FE3 → FE4 → FE5 → FE6              ├─ interleave freely
Stage 7  G3 · G5 · G6 · Y → G7 · (G4 if measured) · SER2 → SER3 → SER4 → SER5 │ against 2–4 and
Stage 8  SH2 → SH3 → SH4 → SH5                                            ─┘  each other
Stage 9  EXT ratify → hygiene → D1 arc
Stage 10 FL6 · FE7 gates
```

## Parallelism

There is one executor, so "parallel" means *interleavable without re-churn*, not simultaneous:

- Stages 5 (Job), 6 (client/Flow/Target), 7 (graph tail), and 8 (trio) are mutually independent
  and independent of stages 2–4, **except**: J7's gated parts (E3/E5), S7↔E4 (retain flag),
  FL4←S8, FE4-stretch←S2, G3←G2, and SER4 soft-before E5. Use them as alternate tracks when an
  engine phase needs to settle or a mavenLocal publish round-trip makes a same-repo follow-up
  awkward.
- Anything in stage 0 and the EXT hygiene session are safe filler at any point.
- The spine that must stay ordered is: **E1 → E2 → {S6, E3, G2} → {S2/S3, XC1–3} → E4 → E5 → E6**.

## Verification

This is a docs-only meta-plan: no build/test verification. Per-phase verification lives in each
constituent plan and is unchanged by this document.
