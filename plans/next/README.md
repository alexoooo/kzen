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
> Sprint 2's, one layer up. Current cases: `context-and-resource.md`, `context-moved-ownership.md`,
> `nested-frame-move-to.md`, `detached-download-content.md`.
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
| `context-and-resource.md` | CTX — first-class context + slot-owned resources | — (standalone: design + elaboration in one document) | 28 | **LANDED 2026-07-29** — all three sessions; see its § As-built for the deviations. Same-day second pass replaced the inert-by-omission notation design with `by: Nominal` weak references + a kzen-lib inferMetadata hardening (§ As-built addendum). ⚠️ Standalone ⇒ **do not delete**; it is the only record of a breaking change's design. Held here until Sprint 3 closes, then archived to the sprint README's directory as an as-built record. **Partially superseded by CTX2** (nearest-slot binding → explicit export chain) |
| `nested-frame-move-to.md` | XC-N — nested-frame move-to (Set Next Statement inside a sub-Script) | — (standalone: design + elaboration in one document) | 30–32 | ✅ **LANDED 2026-07-30** — three sessions; read **§13 and §14** for the deviations. **Filed as a DEFECT, not an extension** (§10.2): no spec asserted the root-frame restriction, and `Execution.moveTarget`'s KDoc anticipated the opposite. ⚠️ **§5 is superseded by §14.1** — the user's manual smoke (row 32) found the loop-transit parking rationale was **false**: the walk already resumed mid-iteration, with a passing regression test on the identical shape, so loop-hosted *transit* shipped and only loop-body *targets* stay parked. That smoke also found two client defects XC-N1 itself introduced (rejections rendered on the *parent* document; the drag handle painted valid against a guaranteed refusal) — 634 green tests had not caught either. ⚠️ Standalone ⇒ archive, don't delete |
| `script-implicit-result.md` | SIR — Script implicit result (`ResultStep` always ends the Script) | — (standalone: design + elaboration in one document) | 46 | ✅ **LANDED 2026-08-06** — all three sessions in one pass, each on a green full `kzen-auto` build; read **§10 As-built** for the deviations. Added 2026-08-05 on direct user request. §1.1 is the only record of why the first draft's "any `ResultStep` exempts the implicit type check" suppression was **rejected** — a nested Result is a conditional early return, so the fall-through path still owes the declared type. Blast radius was pinned by scanning all 48 `is: ResultStep` occurrences, and **that scan shape was the plan's one real miss**: a fixture with *no* Result step also inverted, invisible to a scan keyed on the construct being changed. Two facts worth carrying forward: `ScriptValueReferences` must seed the implicit terminal or a trailing root loop silently returns `[]`, and a dangling `is:` degrades to no-super rather than throwing, so a notation test can pass **vacuously**. ⚠️ Standalone ⇒ archive, don't delete |
| `expression-code-editor.md` | XCE — expression code editor (highlighting, inline errors, completion) | — (standalone: design + elaboration in one document) | 47 | Added 2026-08-06 on direct user request. **3 sessions (A lexer token stream + `KotlinCodeArea` overlay / B error positions end to end / C completion + docs + smoke).** §1.1–§1.3 are the only record of three rejections: CodeMirror 6 (npm + `external` + no Kotlin mode), `KotlinSyntaxValidator` as the primary position source (syntax errors only, and it costs plugin-SPI constructor surface), and client-side unknown-identifier flagging (misfires on locals). Gate **B.0 answered POPULATED** 2026-08-06 — K2 carries `ScriptDiagnostic.location` for parse errors too, so the SPI-costing fallback is off the table. ✅ **LANDED 2026-08-06** — all three sessions, each on a green full `kzen-auto` build, plus the C.5 browser smoke (every row verified by DOM inspection, not by eye). Read **§10** for the deviations. **The plan's own headline case was the thing it got wrong**: `1.. 5x` reports an offset equal to `code.length`, an index that belongs to no token, so the marker rendered *nothing* until an end-of-text branch was added — and the caret-anchor for completion hit the identical edge, so one contract subtlety bit two independent features. Two more corrections worth carrying: the staleness rule as written is necessary but **not sufficient** (`refresh` clears `loaded` without clearing the validation, while the new notation is already published, so buffer equality alone leaves a whole round trip where the offset describes stale text), and the C.5 collapse/expand row **asserts a baseline that never existed** — a collapsed card has never rendered validation message text. The §9 sweep came back zero-documents-changed, and the reason is structural rather than lucky: K2's cascade artefact always lands outside the user's region, so first-in-region and `errors.last()` coincide on every real document. **§10.6 is an out-of-plan defect fix** made on user request: the lexer tested for digits with the Unicode-aware `Char.isDigit()` while advancing only over ASCII identifier parts, so a single `١` pasted into the field hung the browser tab in an infinite loop — pre-existing at `HEAD`, but this feature re-lexes on every keystroke. **§10.7 is user feedback on the shipped field**, and it is the one defect the DOM-measured smoke was structurally unable to see: the textarea's glyphs are transparent but *the browser's own spelling squiggle is not*, so Chrome was underlining every identifier absent from its dictionary in red wavy — the marker's exact colour and style — on expressions with no error at all. Fixed both ways (`spellcheck="false"` via a new `htmlInputSlotProps` bridge; marker now solid 2px, since a red wave *is* the platform's misspelling convention). ⚠ Standalone ⇒ archive, don't delete |
| `detached-download-content.md` | DDC — detached download content shape | — (standalone: design + elaboration in one document) | 48 | Added 2026-08-17 on direct user request, from the `ExecutionDownloadResult` TODO. **S — one session, `kzen-auto-jvm` only.** Sealed `ExecutionDownloadContent` (`OfFile` / `OfWriter`) replacing the bare `InputStream`, plus deletion of the orphaned `DetachedDownloadExecutor`. §1.1 is the only record of four rejections — notably that the TODO's own suggestion (kotlinx-io in `commonMain`) is **factually the right KMP answer but the wrong change**, because the type never crosses a platform boundary. ⚠ Carries a **measure-first gate** (§4.2): the change trades away `PivotBuilder`'s producer/consumer overlap, and the before/after export numbers are recorded either way. ⚠ Also carries a **standing build decision** (§5.1, user-approved 2026-08-17 — the first draft advised against it): `ktor-server-test-host` enters as a test-scope dependency and the repo gets its **first route-level tests**. Near-zero entry cost — `Application.ktorMain` is already public and already takes the context, so no production code moves. Scope held to the two download routes; the other 22 (notably the SSE stream) are §6 backlog. ✅ **LANDED 2026-08-17** — one session on a green full `kzen-auto` build; read **§7 As-built** for the deviations. Both gates resolved and **both went against the plan's own text**: §4.2's measure-first came back ~17% *faster* serial (3123 ms vs 3754 ms over a 200k-row pivot), so no overlap was reintroduced; and §4.1's "no `Content-Length` however it was produced" is **conditionally false** — `LocalFileContent` advertises an exact length and only `install(Compression)` drops it, and only for a client that offered an encoding, so `OfFile` bought an observable property the plan predicted it would not (§4.1 corrected in place). **The plan's one real miss is a reachability assumption**: §5's route test for `GET /action/download` "on a completed Report" is unsatisfiable, because `AutoConventions.serverAllowed` excludes `test/` and the only concrete Reports live in `test/` or the user's `main/` — and the same gap makes the §2.1 pre-commit guard unreachable from either real route, so it is a backstop with no naturally-occurring caller. Both were resolved by a technique that is the session's most reusable output: `KzenAutoConfig(moduleRoot = <temp dir>)` scopes `GradleLocator` to a temp tree while `ClasspathNotationMedia(exclude = main/)` still supplies the archetypes, so a test can drop a `@Reflect` fixture action into `main/` **in temp** — inside `serverAllowed`, served by `ReflectiveClassMirror` — and reach any detached route hermetically, with no Report, no run, and no input files. ⚠ **§5.3's manual smoke is the one item NOT done** — it needs a browser and the user's own data; the `OfFile` branch was instead verified on a real Netty socket (isolated temp work root, port 8099), leaving the **`OfWriter` branch over the wire** genuinely unsmoked. ⚠ Standalone ⇒ archive, don't delete |
| `context-moved-ownership.md` | CTX2 — context signature with an explicit export chain | — (standalone: design + elaboration in one document) | 29 | Follow-on to CTX, replaces its ownership model: explicit `context.exports` export signature, bind-time export-chain climb, `context.slots` retired, requires-not-provided becomes a blocking error. **3 sessions (A kzen-lib engine+spec / B analysis+runtime+notation+fixtures / C UI+docs+smoke).** §4.6.1 (`main/Script.yaml`) resolved 2026-07-29: delete it. **LANDED 2026-07-29** — all three sessions; see its § As-built for the deviations. ⚠️ Standalone ⇒ archive, don't delete — its §1.1 is the only record of why consumption inference was rejected |

## Closed and removed from here

- **CX1–CX8** (rows 33–40) — the context generalization arc, **closed 2026-08-03**. Its elaboration was
  deleted per the rule above; `../2026-07-31_context-improvements.md` is the permanent record, and its
  §8 As-built is where each phase's deviations live. **CX8 was a design gate and it did not license the
  lift it was gating** — `context` does *not* move onto `Logic`, because the four Logic flavours have
  three different frame topologies (§3 J's verdict table). Its output was master-plan rows **41–44**;
  all four landed by 2026-08-03 (43 in its engine half only, `◪`), and row 44 produced **row 45** in
  turn. What is still open: **43a** (Job document-level signature — unblocked, a near-copy of row 41),
  **43b** (Worker read path, needs a new `JobControl` member) and **45** (three quiet hosted-Report
  defects). None blocks anything else.
  ⚠ **Four facts a later reader is most likely to need, none of them findable from the code alone:**
  (1) a *plain-name* reference does not resolve to a user's `main.contexts/<Name>` declaration from
  another document — the object-path form `main.contexts/<Name>` is what lands in notation, fully
  qualified as the fallback; (2) **only the source side of `RunStep.contexts` is rename-tracked** — a
  notation map key is a raw string at every layer of kzen-lib and no command renames one, so the callee
  side is mitigated by a loud error + warning (CX doc §3 E.1, corrected in place); (3) the raw string
  hatch (`resource` / `resourceValue` / `releaseResource`) is an un-deprecated, documented public
  contract, strict to write and permissive to address; (4) **the engine's binding model is specified for
  a sequential host chain only, and the way out is a `contextBarrier` on the host call, not a check** —
  a caller hosting children concurrently declares each one export-opaque (opaque to outward writes,
  transparent to inward reads), which is what `JobRun` now does per Worker; `RunEngineParallelBindingTest`
  (kzen-lib) pins both sides, since the barrier is opt-in and the two ⚠ hazards remain exactly what
  UNBARRIERED concurrent hosting still does. Detection was rejected on purpose: a frame cannot see its own
  scheduling context, so any detect-and-fail rule would be schedule-dependent.

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
