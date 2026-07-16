# Script client sweep (S8) — hot paths, display dedup, notation-driven branches

> **Status: planned.** Successor to `sprint-1/2026-07-06_script-improvements.md` (Sprint 1:
> S1–S7 landed — S6 landed then was reverted by user decision; S8, the client sweep, is the one
> open phase and is carried here, split into separately-executable sub-phases). Executor:
> **Opus 4.8 xhigh, one (sub-)phase per session** — 8a+8d or 8b+8c pair comfortably into one
> session each if momentum allows. kzen-auto-js only.
>
> Companion plans: `2026-07-14_attribute-editor-improvements.md` (**AE5 supersedes** the
> rename-echo mixin and the `SelectLogicEditor` RPureComponent TODO; **prefer AE3+AE5 before
> 8b** — master-plan hot-seam rule); `2026-07-16_trace-payload-improvements.md` (**TP2/TP3
> touch `ScriptProgressStore` too** — whichever of 8a and TP2/TP3 runs second, skim the other's
> as-built first to avoid colliding); `2026-07-16_master-plan.md` (sequencing).
>
> **Progress tracker** (update as phases land):
> - [ ] 8a — hot paths (`ScriptDependencyAnalysis` memo, timeline append, incremental representatives)
> - [ ] 8b — display/editor dedup (`ScriptStepDisplayBase`, scope helper, buildGroups)
> - [ ] 8c — notation-driven branch discovery (removes the SwitchStep blocker)
> - [ ] 8d — hygiene (`StepRowRefRegistry` scoping, TODOs, deprecated-archetype check)

## Landed context (Sprint 1) — the Script plan this sweep closes out

S1 (expression engine: loaded-class caching + reflective type inference), S2 (resources survive
live edit — engine-owned resource values), S3 (linked-document live edit —
`LinkedLogicDocuments`), S4 (validation once per notation version — `ScriptValidationCache`),
S5 (mid-loop migration resume — loop cursors carrying the live iterator, plus the
invocation-identity engine fixes and per-iteration trace reset), and S7 (trace bounding —
display truncation, referenced-aware loop collection, **all** Script emits transient) are done;
S6 (inline-branch stepping) was landed and then **reverted** — frame-only step-over/out is the
settled semantic (see the master plan's deferred/resolved section). Server-side Script is in
good shape; what remains is the client sweep below.

Relevant conventions already in force (do not re-derive): the render-scoping discipline —
`RPureComponent` + consumed-subset state + value-equal guards — is documented in
`kzen-auto/docs/js-architecture.md` §2, with the script displays as the reference
implementations. 8b *enforces* it structurally instead of relying on hand-copied guards.

**Goal of the sweep:** the per-publish client cost stops scaling with steps × branches; the
4-way copy-paste collapses; the SwitchStep blocker dissolves.

## Ground rules

- kzen-auto-js only; no server or wire changes.
- **Verification baseline (every sub-phase):** `:kzen-auto-js:build` + selfTest; manual with
  React DevTools "highlight updates": a per-step expand/collapse or a progress tick no longer
  lights up sibling branches; drag/drop, the dependency overlay, reference insertion,
  rename-while-open all behave as before. Fast run of a 40-step script stays smooth.
- Mark the sub-phase checkbox when done; append an as-built note on deviation.

---

## 8a. Hot paths

- **Memoize `ScriptDependencyAnalysis.analyze`** per (documentPath, notation identity): today it
  runs once per branch per `ClientStateGlobal` publish (ScriptBranchDisplay.kt:252-279) *plus*
  once per overlay remeasure rAF (ScriptDependencyOverlay.kt:214-227). Cache the result in
  `ScriptStore` (or a small keyed cache both consumers read), invalidated on
  `documentNotationChanged` — the store already computes that signal (ScriptStore.kt:96-169).
- **Stop re-sorting the accumulated timeline** per refresh (ScriptProgressStore.kt:125): history
  events arrive watermarked in sequence order — append and assert monotonic instead of
  `sortedBy` over the whole list.
- **Incremental RunStep representatives** (ScriptProgressStore.kt:204-223): fold the new events
  of this refresh into the previous per-RunStep representative map instead of re-scanning all
  binary events × all RunSteps.

**Coordination fence:** TP2/TP3 (trace-payload plan) modify `ScriptProgressStore`'s fetch shape
(binary-thin settle fetch / binary-by-handle). The changes are orthogonal (fetch shape vs
processing cost) but same-file — whichever runs second skims the other's as-built first.

## 8b. Display/editor dedup

*Prefer after AE3+AE5* (`2026-07-14_attribute-editor-improvements.md`) — their primitives shrink
this sub-phase's remainder.

- Extract the copy-pasted observer skip-guards and `Wrapper`/mount/unmount boilerplate
  (IfStepDisplay.kt:123-173 ≈ ForEachStepDisplay.kt:123-192 ≈ DoWhileStepDisplay.kt:129-179 ≈
  ScriptStepDisplayDefault.kt:211-240) into a shared base (`ScriptStepDisplayBase` extending
  `RPureComponent` with the consumed-slice state + value-equal guards from
  `ScriptStepObserverHelpers`) — this *enforces* the js-architecture.md render-scoping
  discipline instead of relying on hand-copied guards.
- Dedupe: predecessor/binding scope computation (SelectStepEditor.kt:152-166 ≈
  RunStepArgumentsEditor.kt:255-269 → one helper next to `ScriptTree` — this Script-specific
  candidate computation stays here and feeds the `selectOptions()` hook of AE5's
  `SelectReferenceEditorBase`); the screenshot `buildGroups` grouping (RunStepDisplay vs
  PageScreenshots — both marked "Mirrors").
- ~~The rename-echo dance (4 editors → a small shared mixin/helper)~~ — **superseded by AE5**
  (`SelectReferenceEditorBase`: hydrate / renaming-flag / echo-suppressed commit skeleton shared
  by SelectObject/Step/EnclosingLoop/Logic/Channel; candidate sources and crop policy stay
  per-editor). With AE5 landed, this bullet's remainder is only the scope helper + buildGroups.

## 8c. Notation-driven branch discovery

- `ScriptDependencyAnalysis.branchAttributeNames = ["steps", "then", "else"]`
  (ScriptDependencyAnalysis.kt:31-38) — replace with metadata discovery: a branch attribute is
  one whose metadata is `is: List, of: ScriptStep` (exactly how the archetypes declare them —
  script-jvm.yaml IfStep :305-312, ForEachStep :329-332). Same discovery serves
  `ScriptTree.read`'s child grouping if it is currently name-based — check and align. This
  removes the documented SwitchStep blocker and the `then`/`else`/`items`/`condition` string
  re-declarations scattered across display files (IfStepDisplay.kt:66-72,
  ForEachStepDisplay.kt:72, DoWhileStepDisplay.kt:70, KotlinExpressionEditor.kt:77) —
  centralize what remains into `ScriptConventions`.
  - **Note (post-XC4):** the *server/common* side already went notation-driven in Sprint 1 —
    `ScriptNestingAnalysis` (kzen-auto-common) reads loop membership from `meta.steps.rerun`,
    and `ScriptDependencyAnalysis.branchAttributeNames` was the shared function the XC work
    layered on (master-plan hot-seam rule 6). Check the current state of
    `branchAttributeNames`/`ScriptNestingAnalysis` first: the discovery mechanism may only need
    extending to the client's display-side string re-declarations rather than building from
    scratch. Record what was actually left to do.
- `KotlinExpressionEditor`'s hardcoded DoWhile-vs-Formula scope branch
  (KotlinExpressionEditor.kt:194-204) mirrors server scoping by attribute name — drive it from
  a notation marker on the attribute metadata (e.g. `scope: body` on DoWhile's `condition`),
  read by both the editor and (optionally) the server scope helpers, so client/server can't
  drift.

## 8d. Hygiene

- `StepRowRefRegistry` process-global singleton (StepRowRefRegistry.kt:10-11 "only one Script
  document open at a time") → scope through the existing per-document `DocumentBridge` context.
- Resolve the open TODOs: `ScriptStore.kt:203` (stateOrNull YAGNI) and `SelectLogicEditor.kt:118`
  (exclude self/descendant documents from callee suggestions — cheap DAG guard).
  `SelectLogicEditor.kt:59` (→ RPureComponent) is resolved by AE5's base migration — skip if
  AE5 has landed. Delete the commented debug line StepDisplayManager.kt:114.
- Grep-check the deprecated `ArgumentStep`/`ForEachItemStep` archetypes for user-notation
  references; retire them (+ their yaml) only if unreferenced, else leave with a dated comment.

---

## Sizing

| Sub-phase | Size | Risk | Depends on |
|---|---|---|---|
| 8a | small session | low | — (fence with TP2/TP3) |
| 8b | half session | low-medium | prefer AE3+AE5 first |
| 8c | half session | low | — (check post-XC4 state first) |
| 8d | small session | low | — |

All four are independent of each other and of everything else in Sprint 2 — safe filler
sessions. 8a is the one with measurable user-facing payoff (long-script publish cost); do it
first when in doubt.
