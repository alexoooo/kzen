# Sprint 1 — consolidated record (closed 2026-07-16)

Historical archive of the plan documents whose work landed in Sprint 1 (2026-07-10 →
2026-07-16, on groundwork going back to 2026-07-05). **Nothing here is needed for future
work**: every still-open item, decision, dependency edge, and gotcha was carried into the
fresh documents at `kzen/docs/plans/` (see `2026-07-16_master-plan.md` for the full live set and
its "Deferred & resolved" section for the sprint-1 knowledge that still matters). This
directory exists for as-built detail and history; it can be deleted without losing anything
load-bearing.

> The individual plan bodies referenced below were deleted from the working tree (this README is
> the surviving record). Recover any of them from git history:
> `git log --oneline -- plans/sprint-1` then `git show <commit>:plans/sprint-1/<file>`.

## What landed, per plan

| Plan (archived file) | Landed | Headline as-builts / reversals |
|---|---|---|
| `2026-07-05_logic-engine-improvements.md` (E) | E1–E5, E7 ✓; **E6 deferred** | Engine hot path + pause-overrides-stepping (E1); `checkpoint(at:)` + engine-owned position (E2); breakpoints — run-to dropped as subsumed (E3); trace served by projecting the retained engine, `LogicTraceStore` retired, `emit(retain:)` shipped (E4); SSE push + epoch/sequence versioning — **the real cost driver was `LogicStatus.time`, a wall clock 8 client sites keyed re-fetch on**, retired pre-push; publish throttled 1 s; found + fixed the kzen-shell CIO client's missing `HttpTimeout` (15 s truncation of every proxied response) (E5); `Execution.blocking { }`, typed capture, structured failure/`nodeOutcome` (E7). E6 (multi-run) deferred with groundwork verified — condensed into the new master plan. |
| `2026-07-10_execution-control.md` (XC) | XC1–XC5 ✓ — **complete** | Continue/break/return as **completion signals, not exceptions** (zero kzen-lib change); move-to-step as a flavour-owned self-migration through the migrate barrier (`Repositionable`); skip-set + `Skipped` state + outcome-set surgery via `ScriptJumpAnalysis`; draggable next-to-run arrow. v2 loop-body jump targets parked (master plan). |
| `2026-07-06_target-improvements.md` (FE) | FE1–FE7 ✓ — **complete** | Vision core 338→56 ms; DPI-scaling root cause (4K @150%: two pixel spaces); NCC tolerant matching calibrated (Normal 0.8 — the drift fixture scores 0.850); open target-type SPI proven by `CssSelectorTarget` with zero shared-code edits; **FE7 gate: browser-first stands**, desktop actuation parked. Manual smoke of FE3/FE5/FE6 UI still pending a live session (master plan "smoke debt"). |
| `2026-07-06_script-improvements.md` (S) | S1–S5, S7 ✓; S6 ✓→**reverted**; S8 → carried | Expression engine: classloader caching + real reflective type inference — `ScriptKotlinCompiler` must stay `open` (S1); resources survive live edit via engine-carried values (S2); linked-document live edit `LinkedLogicDocuments` (S3); digest-keyed validation cache (S4); mid-loop resume with live-iterator cursors + invocation-identity engine fixes + per-iteration trace reset (S5); **S6 (nesting-aware step-over/out) reverted after live use — frame-only is the settled semantic**; transient emits for *all* Script traces (S7). S8 → `2026-07-16_script-client-sweep.md`. |
| `2026-07-05_graph-improvements.md` (G) | G1–G2 ✓; G3–G7 → carried | Digest-keyed definition cache + patched `coalesce` + Kahn leveling (G1); closure content digest, `baselineNotations` retired (G2). Remainder → `2026-07-16_graph-improvements.md`. |
| `2026-07-06_job-improvements.md` (J) | J1 ✓; J2–J9 → carried | Bounded progress-teaser wire contract + Pivot teaser bug fixed (J1). Remainder (J7 rescoped: outcome chips were delivered by E7; Job `retain=false` adoption still pending) → `2026-07-16_job-improvements.md`, which also carries the retired 2026-06-23 build plan's appendix. |
| `2026-07-06_flow-improvements.md` (FL) | FL1–FL2 ✓; FL3–FL6 → carried | Structure-core test harness + lint + **revised optional-input readiness rule** (FizzBuzz regression same-day) (FL1); graph instance per run, non-fatal + throttled tracing (checkpoint-gap pause proxy), `FlowMessageInspector` defused (FL2). Remainder → `2026-07-16_flow-improvements.md`. |
| `2026-07-06_shell-launcher-project-improvements.md` (SH) | SH1 ✓; SH2–SH5 → carried | Trust-boundary hardening: `SecurityGate` fetch-metadata + Host gate, trust-all TLS removed, name validation, first kzen-shell tests (SH1). The SSE-through-proxy consumer arrived with E5 — CIO timeout fix recorded here too. Remainder → `2026-07-16_shell-launcher-improvements.md`. |
| `2026-07-13_serialization-improvements.md` (SER) | SER1 ✓; SER2–SER5 → carried | Launcher codec convergence — kotlinx both sides, Jackson 2 off the launcher server, `ktor-serialization-kotlinx-json` proven (SER1). Remainder (with the inverted E5 edge: SER4 now migrates the shipped SSE payload) → `2026-07-16_serialization-improvements.md`. |
| `2026-07-10_master-plan.md` | Stages 0–4 executed | The Sprint-1 sequencing meta-plan (stages, hot-seam rules, dependency map). Superseded by `2026-07-16_master-plan.md` (Sprint 2 + backlog). |

## Cross-cutting discoveries worth remembering (all recorded in live docs)

- **The wall-clock finding** (E5): the polling cost was never the poll — it was a per-call
  `time = now()` that made every response look new. Now: epoch + sequence versioning,
  `traceVersion()` keying, throttled publish (kzen-auto `docs/architecture.md` §3).
- **The CIO timeout finding** (E5/SH): kzen-shell's proxy client silently truncated *any*
  proxied response slower than 15 s — invisible in the dev loop; pinned by
  `ProxyHttpClientTimeoutTest`.
- **Signals, not exceptions** (XC4): control flow as pending completion signals dodges the
  `recoverable` catch-all; a signal never coexists with a park.
- **S6's revert**: stepping semantics are UX, not just engine rules — nesting-aware limits
  broke real workflows; frame-only stands.
- **J7 × E7 overlap**: per-worker outcome chips arrived via the engine's structured-failure
  work, not the Job plan — re-scoped during this consolidation.
- The 10 MB inline-screenshot trace responses (→ TP plan), the `LogicStatus` structural
  version (→ TP4), and the E6 multi-run friction list (→ master plan) are the three biggest
  carried-forward items.

## Where the live work is now

All open work lives flat in `kzen/docs/plans/`:
`2026-07-16_master-plan.md` (start here) · graph · serialization · trace-payload · yaml-parser
· job · flow · script-client-sweep · shell-launcher · attribute-editor ·
custom-plugin-extensibility-analysis (awaiting D1–D7 ratification).
