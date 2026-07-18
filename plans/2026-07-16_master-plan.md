# kzen improvement epic — master plan v2 (Sprint 2 + backlog)

> **Status: meta-plan.** Written 2026-07-16 at the close of **Sprint 1** (see
> `sprint-1/README.md` for the consolidated record of what landed: E1–E7, XC1–XC5, FE1–FE7,
> S1–S7, G1–G2, J1, FL1–FL2, SH1, SER1). This document decides **when** — each constituent plan
> remains the sole authority for **how** (goals, design decisions, file anchors, verification).
> Executor: **Opus 4.8 xhigh, one constituent-plan phase per session**, picked from Sprint 2
> first, then the backlog stages.
>
> Maintenance rule: when a phase lands, tick it in its own plan's tracker (as every plan already
> requires) **and** strike it here. Backlog stages are mutually independent — reorder freely; do
> not reorder within a track (T/W/N chains) without re-checking the dependency rules. Constituent
> plans do not point back here (one-way reference, no churn).
>
> This document is **self-contained**: everything still relevant from Sprint 1 (deferred items,
> resolved gates, carried knowledge) is condensed in § Deferred & resolved below — the sprint-1
> directory can be deleted without losing anything needed going forward.

## Constituent plans (the live set)

| ID | Document | Scope | Open phases | Notes |
|---|---|---|---|---|
| G | `2026-07-16_graph-improvements.md` | Notation→Definition→Instance stack (kzen-lib) | G3–G7 | G4 measurement-gated; G7b after Y |
| SER | `2026-07-16_serialization-improvements.md` | Wire serialization (kotlinx convergence) | ✅ **COMPLETE 2026-07-18** | SER2–SER5 all landed; Jackson gone from kzen-auto + kzen-shell (launcher YAML only) |
| TP | `2026-07-16_trace-payload-improvements.md` | Trace payload + transport efficiency | TP1, TP3, TP4 (TP2 = optional stopgap, default skip) | realizes E5's two parked items |
| Y | `2026-07-10_yaml-parser-strings-and-comments.md` | YamlParser bare strings/comments/`\|-` | W1–W8 (~2 sessions) | **before G7b** |
| J | `2026-07-16_job-improvements.md` | Job flavour + Report subsumption | J2–J9 | J7 rescoped post-E7 |
| FL | `2026-07-16_flow-improvements.md` | Flow flavour | FL3–FL6 | FL6 = decision gate |
| S8 | `2026-07-16_script-client-sweep.md` | Script client sweep | S8a–S8d | 8b prefers AE3+AE5 first |
| AE | `2026-07-14_attribute-editor-improvements.md` | kzen-auto-js editor consolidation | AE1–AE6 | AE6 optional |
| SH | `2026-07-16_shell-launcher-improvements.md` | Shell/launcher/project trio | SH2–SH5 | SH5 last (docs-to-truth) |
| EXT | `2026-07-06_custom-plugin-extensibility-analysis.md` | Custom/Plugin/Registry/DataFormat | hygiene S1–S10 (−S7) + decisions D1–D7 | **needs ratification session** |

~45 sessions total at one phase per session (G:5, SER:4, TP:3, Y:2, J:8, FL:3+gate, S8:2–4,
AE:5–6, SH:4, EXT:1 decision + ~5, gates 0–2).

## Sprint 2 — general-purpose platform first

Sprint 2 front-loads the changes that benefit **everything** (transport, wire format, notation
format, graph ergonomics) over per-flavour features. Three tracks, mutually independent —
interleave freely; the chains inside each track are ordered.

### Track T — trace & transport (3 sessions)

| Order | Phase | Why |
|---|---|---|
| ~~T1~~ | ~~**TP1** response compression~~ ✅ **DONE 2026-07-16** | ~~25–40 % off all JSON transfer~~ — landed; runtime-verified (gzip engages, SSE excluded); proxy relays unchanged. Dev-loop smoke debt: proxy-through-browser, `selfTest`, HAR delta |
| ~~T2~~ | ~~**TP3** trace binaries by handle~~ ✅ **DONE 2026-07-16** | ~~kills the base64 tax on the ~11 MB incremental history + the ~10 MB settle re-download (TP2 skipped — TP3 subsumes it)~~ — landed; `BinaryHandleExecutionValue` wire type + `/logic/trace-binary` blob endpoint (both-store resolver), single `pngUrl` choke point; headless-verified (compile/test green, blob 404s cleanly). Dev-loop smoke debt: FizzBuzz no-base64 + one-fetch render, proxy relay, `selfTest`, HAR delta |
| ~~T3~~ | ~~**TP4** structural version on `LogicStatus`~~ ✅ **DONE 2026-07-16** | ~~exact structural re-fetch; restores per-emit frame animation E5 traded away~~ — landed; server-computed `structureVersion` (lazy in `status()`, unfiltered node-id-set + runState + epoch signature), `traced`/`lookupRunExecutions` now gate on it (client `structureVersion()` reads it verbatim, `traceVersion()` = `structureVersion\|sequence`); descent-into-child animation restored for free. Headless-verified (`:kzen-auto-jvm:test` incl. extended observer test + `:kzen-auto-js:compileKotlinJs` green). SER4 carries the string-Long field mechanically. Dev-loop smoke debt: FizzBuzz HAR (~46→~15-17 for traced/run-executions), descent-repaint animation, `selfTest` |

### Track W — wire serialization (4 sessions)

~~**SER2**~~ ✅ **DONE 2026-07-16** (kotlinx foundation: build plumbing both repos, value-object +
`ExecutionValue`/`Result`/`Request` serializers, 2a classification survey — no wire change; as-built
in the SER plan) → ~~**SER3 (gate)**~~ ✅ **DONE 2026-07-17 — GATE VERDICT: PROCEED** →
~~**SER4**~~ ✅ **DONE 2026-07-17** (run/task DTOs kotlinx + `LogicStatus.active` sentinel-kill;
trace DTOs stay value-tree; RestHandler shed Jackson; `Ser4SpikeTest` deleted; selfTest + live boot
green — as-built in the SER plan) → ~~**SER5**~~ ✅ **DONE 2026-07-18 — TRACK COMPLETE**
(ContentNegotiation flipped to `json()`; the 4 raw-`Map` endpoints SER3/SER4 had left — `scan`,
`notation-batch`, `actionDetached`, `logicRequest` — migrated to typed DTOs; `IconCollectionHandler`
ported to kotlinx; `ClientJsonUtils` deleted; **Jackson removed from kzen-auto + kzen-shell**, surviving
only in kzen-launcher YAML. `respondJson` KEPT, not collapsed to `call.respond(dto)`, to preserve
buffered/gzip-clean output — see the SER plan's phase-5 as-built. Full suites + selfTest + live boot green).
SER4 also migrated the already-shipped SSE payload (the E5 soft edge inverted — see the SER plan's timeline
note).

**SER3 as-built, what SER4 must carry** (full detail in the SER plan's phase-3 as-built):
- The family was **3 wire DTOs, not the ~11 named** (`StorageAreaInfo`, `StorageBundleInfo`,
  `DataLocationInfo`) — the 2a table won. Verified live end-to-end (typed wire, gzip preserved, null
  `budget` omitted on real data); `:kzen-auto-common:jsTest` + `selfTest` green.
- **Do not extrapolate SER3's −43 LOC.** Bucket-conditional: wire-only ≈ **−25/class**, but **Bucket-C
  ≈ +17/class** (codec retained per phase 4's own text) plus ~+29 per new value-object serializer.
  SER4's list has several Bucket-C classes, so **its net LOC will be near zero — that is expected, not a
  failure.** SER4's justification is the sentinel-kill + typed contract + unblocking SER5's Jackson-2
  removal, never line count.
- **De-risked for SER4 by `Ser4SpikeTest`** (kzen-lib commonTest, test-only — *delete it when SER4 lands*):
  recursive `@Serializable` round-trips in KMP commonMain, and nullable-without-default → explicit JSON
  `null` (the `LogicStatus.active` sentinel-kill works). **Keep `Json` stock — `explicitNulls=false` would
  silently sabotage that.** Use kotlinx's built-in `LongAsStringSerializer` for `epoch`/`sequence`/
  `structureVersion`; plain numbers elsewhere (rule now in `kzen-auto/docs/architecture.md` § 3).
- `respondJson`/`serverJson` already exist in `KzenAutoMain` (not `RestHandler` — the plan's placement was
  wrong); `clientJson` in `kzen-auto-js/.../client/util/ajaxUtil.kt`. Serialization plugin now on
  `kzen-auto-{js,jvm}` too. **`ObjectStableMapper` has no `toCollection` — SER4 must invent one.**
- **Value-tree pilot rejected, with a standing blocker recorded** — the ~25 Bucket-B classes are off
  SER4/SER5's path entirely (they never reach Jackson), and `jsonElementToAny` collapses JSON numbers to
  `Double`, so a `Long` field would throw on decode. A future SER6, not a SER4 concern.
- **`Url` collapsed to a single value class — the root cause of two SER3-surfaced bugs, RESOLVED 2026-07-17.**
  SER3's serializer round-trip exposed `Url.equals` delegating to the wrapped platform type (JS reference
  identity → `Url.of(x) != Url.of(x)`; JVM equal-while-`digest()`-differs → broken digest-keyed caches), then
  a client/server **digest divergence** (JS's `org.w3c.dom.url.URL` normalizes unconditionally, `java.net.URI`
  doesn't, and rejects a space JS %-encodes). The first fix compared `toString()`; the second added a ~200-line
  `UrlCanonical` commonMain canonicalizer to reconcile the two parsers. On review the user questioned the whole
  edifice — and rightly: `Url` was an `expect class` wrapping **two** url parsers, and the divergence was
  self-inflicted. A call-site audit found `scheme`/`query` have **zero** production callers, `path`/`parse` one
  each. So `Url` is now a single ~145-line commonMain value class keyed on the verbatim location string, exactly
  like its sibling `FilePath` — `UrlCanonical` (208), both platform actuals (128 + 76), and `UrlCanonicalTest`
  (182, the "contract" that only existed to keep two parsers reconciled) all **deleted**. equals⟺digest now
  holds **by construction**. Net for the collapse **+250/−602 (−352)**; the two "fixes" plus the machinery they
  fixed all fell out once the wrong question was dropped. Behaviour change: no normalization (matches `FilePath`
  and pre-canonicalizer jvm), validation is a scheme check. **85/85 JVM + 85/85 JS**, `selfTest` green.
  *Lesson for SER4/SER5: when a shared abstraction needs a reconciliation layer between two platform backends,
  question the two backends before building the layer.*

### Track N — notation format + graph ergonomics (~7 sessions)

| Order | Phase | Why |
|---|---|---|
| N1–N2 | **Y** (W1–W8) | the notation format rework; **must precede G7b** (hot-seam rule); includes the mandatory legacy on-disk audit |
| N3 | **G7** reducer split + template-respecting deparse | comments/formatting survive edits — the user-visible payoff of Y |
| N4 | **G5** NotationCodec + notation-driven `isLogic` | deletes binding boilerplate; removes the hardcoded logic-document check (god-object fix) |
| N5 | **G6** error surface | failures name their origin instead of "Missing: main" |
| N6 | **G3** scoped instantiation + instance caching | detached-action hot path; Flow per-vertex closure |
| (N7) | **G4** incremental define | **only if the post-G1 measurement demands it** — measure first, record either way |

G5/G6/G7 are mutually independent — N3–N5 can reorder; G3 anywhere; G4 last and gated.

### Sprint-2 fillers (any time, prerequisite-free)

- **AE1** (Old-fork removal — also unblocks FL5's cleaned-up scope) and **AE2** (close-policy
  select migration).
- **EXT hygiene** (S1–S10 minus S7) — one opportunistic session.
- **Manual smoke debt session** (see § Deferred & resolved) — needs the user at the browser.

Sprint 2 exit: transport byte-efficient (compressed, binary-by-handle, exact re-fetch); one
JSON codec per process (or an honest gate verdict); comments survive edits; `isLogic`
notation-driven; failures self-describing; detached actions O(closure).

## Backlog stages (pull-forward friendly)

Mutually independent; interleave against Sprint 2 when a change of pace or a mavenLocal publish
wait makes it convenient.

### Stage B1 — client convergence (~7 sessions)

**AE3 → AE4 → AE5 (→ AE6 optional)**, then **S8a–S8d** (8b/8d shrink once AE5 is in; 8a can go
any time — fence with TP2/TP3 on `ScriptProgressStore`). Exit: one commit primitive, one
select-reference base, no whole-`ClientState` stores, notation-driven branch discovery
(SwitchStep unblocked).

### Stage B2 — Job: Report subsumption (~8 sessions)

The strategic spine is **J2 → J3 → J4 → J9**; J5 (benchmark-first + headless), J6 (fan-out,
demand-driven), J7 (interactivity remainder — retain=false adoption is its first, smallest
item and can run as a micro-session any time), J8 (client sweep — after J3, prefer after
AE3+AE5) slot around it. Exit: composed A/B gate green (same dataset through Report and Job —
identical bytes); Report frozen; headless = "the same Job minus observability".

### Stage B3 — Flow capability (~3 sessions + gate)

**FL3** (capability SPI — the third-party proof is the acceptance), **FL4** (client perf +
Error phase), **FL5** (editing UX; AE1 first). **FL6** is a decision gate (multi-output /
crossing / nested-loop semantics) — decisions first, possibly docs-only.

### Stage B4 — platform trio (4 sessions)

**SH2 → SH3 → SH4 → SH5** (SH5 last — docs-to-truth over whatever 2–4 changed). Exit: crashed
children surface + restart; registries atomic; template extension works out of the box; project
upgrade path; 304s through the proxy.

### Stage B5 — extensibility (1 decision session + ~5 build sessions)

1. **Decision session**: ratify EXT D1–D7 (recommendations in the analysis; D1 —
   plugin-shipped `ModuleReflection` registration — is the strategic one and reshapes D2–D4).
   Promote the analysis to `2026-07-XX_extensibility-improvements.md` in house plan format.
2. D1 implementation + plugin UX + Custom power + registry disposition per the promoted plan.
   (The hygiene phase may already have run as Sprint-2 filler.)

Exit: `../kzen-sample-plugin` contributes a working `@Reflect` step/prototype with zero
kzen-source edits.

## Dependency & coordination rules (the still-live ones)

1. **Y before G7b** — the yaml plan's one-time unparse churn must precede byte-identical
   object-segment preservation (cross-refs in both plans).
2. **SER2 → SER3 → SER4 → SER5** — strict chain; SER3 gate semantics as above.
3. **SER4 ↔ TP4** — both touch `LogicStatus`; whichever lands second adapts (one field / one
   key). **SER2d ↔ TP3** — TP3 **landed first (2026-07-16)**, so the migrated `ExecutionValue`
   serializer MUST round-trip the new `binary-handle` envelope `{type: binary-handle, run, hash,
   size, mime}` (kzen-lib `BinaryHandleExecutionValue`, a sibling of `binary` under the sealed
   `BinaryValue`) in addition to the existing `binary` (base64) shape.
4. **AE3+AE5 before S8b and before J8.4** — the shared editor primitives land once, in AE;
   the dedupe remainders build on them (hot-seam rule; notes in all three plans).
5. **AE1 before FL5's cleanup scope** — AE1 owns the `flow/edit/*Old.kt` arc; if FL5 arrives
   first, run AE1 as its own session first.
6. **S8a ↔ TP2/TP3** — same file (`ScriptProgressStore`); whichever runs second skims the
   other's as-built.
7. **J3 → J4 → J9**; **J8 after J3**.
8. **G4 measurement gate** — measure per-keystroke define cost post-G1 before building; record
   the number either way.
9. **FL6 after FL3** (capability interfaces are the pre-work); **FE gates closed** (see below).

## Deferred & resolved (carried from Sprint 1 — self-contained)

### E6 — multiple concurrent runs: DEFERRED 2026-07-16

Not needed yet; a readiness review confirmed **nothing precludes it** and the migration surface
stayed concentrated in `ServerLogicController` as intended (Sprint 1's hot-seam rule 1 held —
everything was written single-run; a future E6 migrates it once). Already multi-run-ready: the
engine core has no process-global singletons; `runId` is a first-class key on every verb;
per-run flags live on `LogicState`; `LogicRunInfo` is runId-addressed. **Design decisions made
(reuse when reviving):** `stateOrNull` → `LinkedHashMap<LogicRunId, LogicState>`; `start()`
stops refusing while a run exists; **one driving executor per run** (a shared executor would
serialize unrelated runs and break per-dispatcher `awaitQuiescent` quiescence counting); wire
`LogicStatus.active` single→list; retention = active runs + most-recent settled run **per root
document**; per-run thread budget via a `RunEngine` constructor default the controller lowers
to ~`max(2, cores/2)` — NOT a shared dispatcher; client `ClientLogicGlobal` re-keys state per
root document (the widest client audit — do it after any client-global additions have settled).
**Six friction points a future E6 must handle:**
1. The `anyRunActive` eviction gate at `KzenAutoContext.kt:255` must become "no run active at
   all".
2. Content-addressed work dirs are **not** runId-partitioned (`JobWorkPool.workerOutputDir`
   notation-keyed; `ReportWorkPool.resolveRunDir` content-keyed) — decide partition-by-runId vs
   forbid concurrent same-document runs.
3. The original design bullet predates E5's wire reshaping (epoch/sequence, SSE) — re-derive
   the wire shape.
4. logic-spec §2's residual note was stale (named the retired `LogicTraceStore`) — fixed in the
   2026-07-16 consolidation, but re-check §2 against reality when reviving.
5. The per-run thread-budget config hook doesn't exist yet.
6. The `CachedKotlinCompiler` race E6 earmarked is **already fixed** (per-signature
   `Striped.lock` + Caffeine, commit `09120a1e`, 2026-07-11).
Also engine-adjacent, known and accepted: concurrently-live children of the *same* document
(possible in Job) still alias by stable id at the migration barrier (S5 as-built; carried in
the Job plan's appendix).

### E5 residuals

- **Step budget** (`Run.step(mode, count)`) deferred — no consumer (750 ms auto-step dwell is
  hardcoded; no speed UI). Revive only with a driving UI.
- **Live-view delta fetch** descoped to sequence-gating — deltas would need engine-side reset
  tombstones (`resetEmitted` clears live values a delta pass would miss and ghost).
- **E4 residual** (low impact): the engine keeps `log` events of compacted `retainTrace=false`
  frames in history (`lookupRunHistory` includes them).

### Target (FE) — COMPLETE, gates closed

All seven phases landed 2026-07-12. **FE7 verdict: browser-first stands** — desktop capture is
a capture-source convenience only; `ScreenshotTaker` is the future desktop hook and the locator
SPI's driver-typed context is the retype seam; reopen only if desktop RPA becomes near-term.
**FE4's live-browser capture source was skipped** (the trace film strip covers the workflow) —
now feasible if wanted, since S2 (engine-carried browser handle) landed. FE2 left one user
action pending: recapture the correct-click crop via the Browser source (or rely on FE5
tolerance).

### Script S6 — REVERTED (settled semantics)

Nesting-aware step-over/out was landed 2026-07-12 and reverted 2026-07-13 after live use:
auto-step-over blasted a whole ForEach in one tick and step-out exited just the branch.
**Frame-only step-over/out is the settled semantic** (classic debugger: skips calls/frames,
not loop bodies). The ForEach iteration-counter trace detail (`"$item (i of n)"`) stays. Do not
resurrect nesting-aware limits without a new UX design.

### XC (execution control) — COMPLETE, one v2 extension parked

Move-to-step + continue/break/return all landed. **v2 extension (not scheduled):** loop-body
jump targets via S5's `LoopCursor` carry (v1 rejects targets inside `rerun` branches).

### Manual smoke debt (one session, needs the user)

Interactive browser passes that headless sessions couldn't run: FE3/FE5/FE6 UI surfaces
(step-editor polish, tolerance controls, target-type dropdown); XC3/XC5 (arrow drag, control
step editors); FL1's dangling-pipe lint banner + FL2's step/free-run FizzBuzz Flow Loop smoke.
**SER3 (2026-07-17)**: the ribbon **storage manager** (open panel → expand an area → check
sizes/counts/`modified`/`active` and especially the **delete button's enablement**, which is the
`deletable` string→boolean flip → delete a bundle); the **Job** document's `MultiFileInputEditor`
(the only `listFiles` caller — browse a directory with a filter); and a **regression check on the
Report input browser**, which reaches `DataLocationInfo` via the retained value-tree codec and must be
unchanged (SER3's most likely over-deletion victim). Server side is already curl-verified end-to-end.
**SER5 (2026-07-18)** adds to the same debt: an **SSE repaint on pause/settle through the shell proxy**
(the ContentNegotiation flip touched every server) plus a Report **Task-paradigm** submit/query — both
server-side wire is curl/selfTest-verified, only the visual confirmation is outstanding.
Bundle into one dev-loop session with the user present.

### EXT-D5 (DataFormat) — parked

Endorsed: park/retire until a consumer exists ("redesigning a schema document before a consumer
exists is how it got here"). Reopen trigger: a real consumer for field/type schemas.

## Sequence at a glance

```
Sprint 2   Track T:  TP1 → TP3 → TP4                      ─┐
           Track W:  ~~SER2~~ → ~~SER3(gate: PROCEED)~~ → ~~SER4~~ → ~~SER5~~ ✅ DONE   ├─ interleave freely
           Track N:  Y → G7 · G5 · G6 · G3 · (G4 if measured) ─┘
           Fillers:  AE1 · AE2 · EXT-hygiene · smoke-debt session
Backlog    B1: AE3 → AE4 → AE5 (→AE6) · S8a–d   (client convergence)
           B2: J2 → J3 → J4 → J9 · J5 · J6 · J7 · J8   (Report subsumption)
           B3: FL3 → FL4 → FL5 · FL6 gate       (Flow capability)
           B4: SH2 → SH3 → SH4 → SH5            (platform trio)
           B5: EXT ratify → D1 arc              (extensibility)
```

## Parallelism

One executor, so "parallel" means *interleavable without re-churn*:

- Sprint 2's three tracks are mutually independent; the fillers fit anywhere.
- Backlog stages B1–B5 are mutually independent and independent of Sprint 2 **except**: rules
  3–7 above (SER4↔TP4, AE→S8b/J8.4/FL5, S8a↔TP3, J-chain).
- Spines that must stay ordered: **SER2→3→4→5**, **Y→G7b**, **J2→J3→J4→J9**, **AE3→AE4→AE5**.

## Verification

Docs-only meta-plan: no build/test verification. Per-phase verification lives in each
constituent plan and is unchanged by this document.
