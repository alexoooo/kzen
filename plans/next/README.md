# plans/next — execution elaborations for the independent backlog

> Detailed, execution-ready elaborations of individual constituent-plan phases: anchors refreshed,
> "check first" questions pre-resolved. **The constituent plans remain the authority on design
> rationale**; these documents are the execution layer. Executor: Opus-class, one plan per session.
>
> Source of truth for sequencing: `../2026-07-25_master-plan.md`. When a plan here lands, tick the
> tracker in its constituent plan **and** set the Status in the master-plan ledger; then **delete
> the file here.** (Do not delete the *constituent* plan — convert it to an as-built record in the
> sprint archive. Sprint 2 lost three plans' worth of deferred scope by deleting the wrong layer.)
>
> **Exception — standalone plans.** The delete rule assumes a constituent plan holds the design
> rationale. A file here whose "Constituent plan" column reads `—` has none: it *is* the rationale,
> so archive it to the sprint as an as-built record instead of deleting it. Same failure mode as
> Sprint 2's, one layer up. `context-and-resource.md` is the only current case.
>
> **All five were re-validated 2026-07-25** against the post-Sprint-2 codebase — they were written
> 2026-07-19, before J2, before the typed element model, and before the `RestHandler` split, so
> every one of them had stale anchors. See each file's re-validation note.

## The live set

| Plan | Item | Constituent plan | Ledger row | Notes |
|---|---|---|---|---|
| `J3_report-subsumption-a.md` | J3 — pluggable input formats + design-time services | job · P3 | 1–2 | Sized **L with a split point**: steps 1+4 (reader + charset) ship independently of steps 2+3 (design-time services). Two steps were already rescoped down at plan time — the file-browse route and the sync driver exist |
| `J5_perf-headless.md` | J5 — benchmark-first perf + headless mode | job · P5 | 5–6 | **Session A = steps 1–3, Session B = steps 4–8.** Also executes the element model's phase-4 reuse gate. Carries a pre-recorded rescope: the headless serve-gate as literally specified is unsatisfiable (finding F5) — headless stamps synthesized duplex channels non-external instead |
| `J7_interactivity-remainder.md` | J7 — retain=false, deadlock precision, occupancy | job · P7 | 7 | Five lettered items with verdicts pre-resolved. Item (a) `retain=false` is **extractable as a micro-session**; item (d)'s client half is the deferrable tail |
| `J6_topology-fanout.md` | J6 — TeeWorker + list ports | job · P6 | 27 | ⚠️ **DEMAND-DRIVEN — lowest priority.** The J3→J4→J9 spine must not wait on it, and nothing depends on it |
| `DA1_jcef-spike.md` | DA1 — JCEF engine spike | desktop-and-hosting · DA1 | 15 | **Closes engine gate D1; gates DA2–DA5.** Scratch branch only — nothing merges as-is |
| `context-and-resource.md` | CTX — first-class context + slot-owned resources | — (standalone: design + elaboration in one document) | 28 | **LANDED 2026-07-29** — all three sessions; see its § As-built for the deviations. Same-day second pass replaced the inert-by-omission notation design with `by: Nominal` weak references + a kzen-lib inferMetadata hardening (§ As-built addendum). ⚠️ Standalone ⇒ **do not delete**; it is the only record of a breaking change's design. Held here until Sprint 3 closes, then archived to the sprint README's directory as an as-built record. **Partially superseded by CTX2** (nearest-slot binding → moved ownership) |
| `context-moved-ownership.md` | CTX2 — context signature with an explicit export chain | — (standalone: design + elaboration in one document) | 29 | Follow-on to CTX, replaces its ownership model: explicit `context.exports` export signature, bind-time export-chain climb, `context.slots` retired, requires-not-provided becomes a blocking error. **3 sessions (A kzen-lib engine+spec / B analysis+runtime+notation+fixtures / C UI+docs+smoke).** §4.6.1 (`main/Script.yaml`) resolved 2026-07-29: delete it. ⚠️ Standalone ⇒ archive, don't delete — its §1.1 is the only record of why consumption inference was rejected |

## Not elaborated — and why

Behind another item, or better planned once their prerequisite lands (so they elaborate reality
rather than a prediction):

- **J4** (after J3), **J9** (after J4 — same files), **J8** (after J3)
- **E2–E6** — all behind the **E1 ratification session**, which is the user's call and reshapes
  them. E4's C7 half is the exception: settled finding, `@Ignore`d test already committed, runnable
  any time
- **DA2–DA5** — behind the DA1 spike closing gate D1; DA6 (macOS) deferred outright
- **SH5, FL5, FL6, C1–C4** — each is a single self-contained phase already carrying its own steps
  and anchors in its constituent plan; a separate elaboration would just duplicate it

Needs the user, not an autonomous session:

- **E1** — the extensibility ratification (D1–D6 + gate R5-G). The plan holds the recommendations
- **C2** — the consolidated manual smoke debt; the checklist lives in
  `../2026-07-25_core-and-verification.md`

Gated, deliberately not pre-planned so the gate stays honest:

- **C1 → C3** — measure per-keystroke define cost first, build only if it still hurts, record the
  number either way

## Standing rules for every implementation session

- The constituent plan's decisions are pre-made; these documents elaborate, never override.
- **Re-verify anchors before editing.** If a sibling has landed since a plan was written, re-check
  the overlap areas (each plan's "Dependencies & coordination" section names the known seams). The
  2026-07-22 `RestHandler` split is the cautionary case — it deleted a 1303-line file that four
  plans were still anchored on, silently.
- Tick trackers (constituent plan + master-plan ledger row) when a phase lands; append as-built
  notes on deviation.
- Build from the sibling's own directory (`cd ../kzen-auto && ./gradlew …`). **Never `./gradlew build`
  from the umbrella** — it abbreviation-matches `buildEnvironment` and exits 0 having compiled
  nothing.
