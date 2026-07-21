# plans/next — detailed implementation plans for the independent backlog

> Generated 2026-07-19 by a batch of parallel planning sessions (one per work item), each
> elaborating its constituent plan's phase into an execution-ready document verified against the
> current code. **The constituent plans remain the authority on design rationale**; these
> documents are the execution elaboration — anchors refreshed, "check first" questions
> pre-resolved. Executor: Opus, one plan per session, any order (all items here are
> hard-independent of every other *remaining* backlog item).
>
> Source of truth for sequencing: `../2026-07-16_master-plan.md`. When a plan here lands, tick
> the tracker in its constituent plan (as always) and strike it in the master plan; then delete
> the plan file here (or mark it done at the top).

## The independent set (planned here)

| Plan | Item | Constituent plan | Notes |
|---|---|---|---|
| ~~`G3_scoped-instantiation.md`~~ ✅ **done 2026-07-19** | G3 — scoped instantiation + instance caching | graph | kzen-lib + kzen-auto; **3a rescoped** (premise already landed — test-pin + measurement only) |
| ~~`G6_error-surface.md`~~ ✅ **done 2026-07-19** | G6 — structured definition/creation failures | graph | landed post-G3; client bullet rescoped (see the constituent plan's as-built note) |
| `J2_job-signature.md` | J2 — Job parameters in / results out | job | spine opener (priority-first among J) |
| `J3_report-subsumption-a.md` | J3 — pluggable input formats + design-time services | job | no hard dep on J2 (per J plan header); **two steps rescoped down** (file-browse route + sync driver already exist) |
| `J5_perf-headless.md` | J5 — benchmark-first perf + headless mode | job | **serve-gate rescoped** (literal skip unsatisfiable; headless stamps synthesized duplex channels non-external instead) |
| `J6_topology-fanout.md` | J6 — TeeWorker + list ports | job | **demand-driven — lowest J priority** |
| `J7_interactivity-remainder.md` | J7 — retain=false, deadlock precision, occupancy | job | retain=false extractable as micro-session |
| ~~`FL3_vertex-capability-spi.md`~~ ✅ **done 2026-07-21** | FL3 — vertex capability SPI | flow | landed as planned; fixtures took the **reflective-mirror** path (R1 had landed) instead of `FlowVertexTestModule`, and got their own callee document so `LinkedLogicDocumentsTest` stays about the three production paradigms. FL6 gate unblocked |
| ~~`FL4_flow-client-perf-errors.md`~~ ✅ **done 2026-07-21** | FL4 — Flow client perf + Error phase | flow | landed as planned, post-FL3 (the `FlowRun` rebase was textual, as predicted). Both jvm `FlowRun` additions were required; the flaky fixture took the **reflective-mirror** path (R1) so no test module. Manual browser smoke is debt |
| ~~`S8a_script-hot-paths.md`~~ ✅ **done 2026-07-21** | S8a — Script client hot paths | script sweep | landed as planned; **four** analyze consumers share one `Component` extension (not four inlined lookups); browser smoke is manual debt |
| ~~`S8c_branch-discovery.md`~~ ✅ **done 2026-07-21** | S8c — notation-driven branch discovery | script sweep | landed as planned; the post-XC4 audit held exactly, so `ScriptTree`/nesting/jump needed no change. SwitchStep unblocked and test-proven |
| ~~`S8d_script-hygiene.md`~~ ✅ **done 2026-07-21** | S8d — Script client hygiene | script sweep | AE5 had already landed, so the conditional RPureComponent item was **skipped** (gate fired positive); `stateOrNull` **kept** per the elaboration's adjusted verdict. **S8 sweep now complete** |
| ~~`AE1_retire-old-fork.md`~~ ✅ **done 2026-07-19** | AE1 — delete flow/edit/*Old.kt fork | attribute-editor | landed as planned (yaml block was :57–81); FL5's scope now unblocked |
| ~~`AE2_select-values-editor.md`~~ ✅ **done 2026-07-20** | AE2 — SelectClosePolicy → SelectValues | attribute-editor | landed as planned; `values:` proven through the `meta.ref` path; label renders "ClosePolicy" (D7 prediction corrected) |
| ~~`AE3_commit-primitive.md`~~ ✅ **done 2026-07-20** | AE3 — shared commit primitive | attribute-editor | landed as planned, all 8 adopters; the elaboration's three drift flags all held. **AE4 unblocked** |
| `SH2_child-exit-detection.md` | SH2 — child exit detection + UI surfacing | shell/launcher | DA5 later replaces its bind-failure pane |
| `SH3_registry-durability.md` | SH3 — atomic registries + --project.home | shell/launcher | **rescoped to ProjectRepo only** (ArchetypeRepo already directory-scan + atomic) |
| `SH4_template-extension-upgrade.md` | SH4 — kzen-project extension point + upgrade | shell/launcher | static cousin of R5; no ordering constraint |
| ~~`R1_reflective-fallback-mirror.md`~~ ✅ **done 2026-07-20** | R1 — JVM reflective fallback mirror | reflection | landed as planned; **contingency C1 fired** — the KSP processor now skips Java-origin declarations. R2 and R5 unblocked |
| ~~`R3_processor-hardening.md`~~ ✅ **done 2026-07-20** | R3 — KSP processor hardening | reflection | landed; **local-class guard dropped** — KSP never surfaces local declarations (see the constituent plan's as-built note) |
| ~~`R4_service-fqn-validation.md`~~ ✅ **done 2026-07-20** | R4 — @Service FQN boot validation | reflection | landed as planned; G3c had already landed, so the "forces the lazy" caveat did not apply (`contains()` never forces providers) |
| ~~`EXTH_hygiene.md`~~ ✅ **done 2026-07-20** | EXT-H — extensibility hygiene S1–S10 (−S7) | extensibility analysis | D1–D7 untouched as planned; **C7 rename pin is half-red** — object rename green, document rename `@Ignore`d against a kzen-lib root-objects-only limitation (finding recorded under C7) |
| `DA1_jcef-spike.md` | DA1 — JCEF engine spike | desktop-app | closes gate D1; gates DA2+ |

## Excluded from this batch — and why

Behind another remaining item (plan them after their prerequisite lands, so they elaborate
reality rather than a prediction):

- **J4** (after J3), **J9** (after J4, same files), **J8** (after J3; prefer after AE3+AE5)
- **FL5** (AE1 first — master rule 5), **FL6** (decision gate; FL3 landed, so plannable now)
- **S8b** (AE3+AE5 first — master rule 4)
- **AE4** (AE3 landed 2026-07-20 — plannable now), **AE5** (after AE4), **AE6** (optional, after
  1–5 land smoothly)
- **SH5** (docs-to-truth over whatever SH2–SH4 changed)
- ~~**R2**~~ ✅ **done 2026-07-20** (executed straight from the constituent plan, no elaboration
  needed), **R5** (after the B5 ratification)
- **DA2–DA5** (after the DA1 spike closes gate D1; DA6 macOS deferred)

Gated or not implementable by an autonomous session:

- **G4** — measurement-gated by its own plan: measure per-keystroke define cost post-G1 first,
  build only if it still hurts. The measurement is cheap (micro-session); the graph plan holds
  the full design if the verdict is "build". Deliberately not pre-planned here so the gate stays
  honest.
- **EXT decision session (D1–D7 + R5-G)** — needs the user to ratify; the analysis doc holds the
  recommendations. After ratification, promote the analysis to a standard plan and then plan the
  D-arc build sessions.
- **Manual smoke debt** — needs the user at the browser; the checklist lives in the master plan
  § "Manual smoke debt (one session, needs the user)".
- **R6** — effectively already done: the client-plugin verdict is recorded in both the R plan
  (Phase R6) and EXT D7; only the R-plan tracker checkbox needs ticking. No session required.

## Suggested pick order (matches master-plan priorities)

Sprint-2 remainder (~~G6 → G3~~, both landed 2026-07-19) is done; fillers **~~AE1~~ · ~~AE2~~ ·
~~R1~~ · ~~R3~~ · ~~R4~~ · ~~EXT-H~~** are all landed, and **B1 is closed out** — the AE arc
(~~AE3 → AE4 → AE5 → AE6~~) and the whole Script sweep (~~S8a · S8b · S8c · S8d~~) are done. Then
backlog stage openers by appetite: **J2 → J3** (B2; J5/J7 slot around, J6 last), **~~FL3~~ ·
~~FL4~~** (B3 — FL5 and the FL6 gate are both plannable now), **SH2 · SH3 · SH4** (B4), **DA1** (B6).

## Standing rules for every implementation session

- The constituent plan's decisions are pre-made; these documents elaborate, never override.
- If a sibling from this directory has landed since a plan was written, re-verify its anchors in
  the overlap areas (each plan's "Dependencies & coordination" section names the known seams).
- Tick trackers (constituent plan + master plan) when a phase lands; append as-built notes on
  deviation.
