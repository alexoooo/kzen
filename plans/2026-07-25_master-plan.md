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

Execution-ready elaborations for the independent items live under `plans/next/` — see its README.

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
| 28 | **CTX** — context + slot-owned resources | First-class `Context` notation objects, engine slots replace `ResourceScope`, provides/requires validation + UI, `ResourceClosePolicy` → 3 values | — (standalone) | `next/context-and-resource` | ☐ |

**~28 sessions.** Rows 1–8 are the strategic spine and the bulk of the value; rows 9–14 unblock
third-party extensibility; rows 15–19 ship the desktop app; the rest are close-out.

### What to run right now

Row 1 (**J3a**). If a change of pace is wanted, rows **20 (SH5)**, **23 (C1)**, **21 (FL5)** and
**15 (DA1)** are all independent and can be taken at any point. Rows **9 (E1)** and **25 (C2)**
need the user present — schedule them rather than waiting for a gap.

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

### XC (execution control) — COMPLETE, one v2 extension parked

Move-to-step + continue/break/return all landed. **v2 extension (not scheduled):** loop-body jump
targets via S5's `LoopCursor` carry (v1 rejects targets inside `rerun` branches).

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
