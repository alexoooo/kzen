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
| **J** | `2026-07-25_job-improvements.md` | Job flavour + Report subsumption; its pre-DM `JobMessage` contract is superseded by DM7c before the remaining carrier-sensitive phases execute | J4–J9 |
| **DM** | `data-model/README.md` | Unified data model — type/value/binding foundation and per-flavour cutovers | DM1–DM11 (DM12/DM13 gated) |
| **DR** | `data-read-config/README.md` | Configurable, provider-neutral data reading — layered content/coding/character/reader composition, configured formats, typed contracts through Job/UI | DR1–DR7 |
| **DR8** | `data-format-detection/README.md` | Automatic per-file format detection, safe text fallback, explicit correction/pinning and bounded source resolution | DR8a–DR8f |
| **E** | `2026-07-25_extensibility-improvements.md` | Plugin = classloader (process-global `KzenAutoRuntime`), plugin UX, Custom power, plain-object data shape, object-graph paths, closeable streams and items; absorbs reflection R5/R6. **E1 ratified 2026-09-04; reviews 1 and 2 of the hosting analysis folded in** | E2–E4, E7–E9 |
| **DA/SH** | `2026-07-25_desktop-and-hosting.md` | Desktop app distribution + the hosting trio's hygiene tail | SH5, DA1–DA5 (DA6 parked) |
| **FL** | `2026-07-25_flow-improvements.md` | Flow flavour | FL5, FL6 |
| **C** | `2026-07-25_core-and-verification.md` | Graph perf tail + accumulated verification debt | C1–C4 |
| **CX** | `2026-07-31_context-improvements.md` | Context generalization — a **design-space exploration**, added mid-sprint on the first sustained use of CTX/CTX2 | CX1–CX8 |

Detailed elaborations and their current ready/blocked status live under `docs/plans/next/` — see its README.

**CX is the odd one out**: it began as a *design-space exploration*, not a phase list with pre-made
decisions. Its §3 records a verdict per axis with the argument for it. The user reviewed and ratified
the nominal auto-wire verdict and N4 naming on **2026-08-01**, together with a semantic-hardening pass
that split declaration/type/address identity, exact-vs-family exports, present-null lookup, one-shot
disposal and atomic call-site bootstrap. CX8 is deliberately still a design gate for parallel flavours.

## Session ledger

**One row per session.** Table order is execution order, while the `#` column is a stable identifier rather than a
renumbered sequence. J5a and the unified-data-model cutover through DM11 are complete; the remaining active spine
is a DataValue-aware J5b, J4, and J9. Consumer/design-gated DM rows are listed but do not become executable merely
by appearing above unrelated work. Rows marked *pull-forward* remain independent unless they touch the same Job
files as the active spine. Status legend: `☐` open; `☑` landed; `◪` partially landed; `⊘` superseded or closed
without execution; `◇` gated and not schedulable until its named gate opens.

| # | Session | Delivers | Plan · phase | Elab | Status |
|---|---|---|---|---|---|
| 1 | **J3a** — pluggable input formats | ~~`PluginReaderWorker` bridging the plugin SPI + `encoding` on native readers~~ **SUPERSEDED 2026-08-21 by DS2/DS3** (rows 52–53): the plugin-format read lives in the shared `FileDataOpener`, `encoding` in `DataPart.encoding` | J · P3 steps 1,4 | `next/J3` | ⊘ |
| 2 | **J3b** — design-time services | ~~Column pre-scan route + `JobUpstreamSchema` fallback on `WorkerLane` + `SortSpecEditor` dropdown~~ **SUPERSEDED 2026-08-21 by DS6** (row 56): `DataSourceActions action=shape` prefers the source's static declaration and falls back to the opener's bounded `inspectShape`; `JobUpstreamSchema` gains a provider list | J · P3 steps 2,3 | `next/J3` | ⊘ |
| 5 | **J5a** — benchmark baseline | Harness + Report-vs-Job results table, incl. the `FlatView` allocation row | J · P5 session A | `next/J5` | ☑ 2026-08-28 |
| DM1 | **DM1** — structural type contract | Common structural type vocabulary, invariants, algebra, lowering, and digests | data-model · DM1 | `data-model/01-type-contract-and-algebra.md` | ☑ 2026-08-28 |
| DM2 | **DM2** — JVM native resolution | `KType` mapping, loader-local native tokens, and resolved assignability | data-model · DM2 | `data-model/02-jvm-native-types-and-resolution.md` | ☑ 2026-08-28 |
| DM3 | **DM3** — shape/schema cutover | Observation envelope, typed declared schemas, non-null cursor shape, and explicit internal legacy item-kind bridge | data-model · DM3 | `data-model/03-shape-and-schema-cutover.md` | ☑ 2026-08-28 |
| DM4 | **DM4** — values/snapshots/validation | `DataValue`, literal/native access, bounded snapshots, and deep validation. **☑ LANDED 2026-08-28** — one backing-local inline-long node API supports table and direct encodings; the literal allocation pin, bounded immutable snapshots, exact JVM scalar projection, and explicit deep validation are green. See the plan's As-built. | data-model · DM4 | `data-model/04-values-snapshots-and-validation.md` | ☑ 2026-08-28 |
| DM5 | **DM5** — adapter/backing proof | Adapter registry plus literal/native/flat/fake-row proof and plugin classpath verdict. **☑ LANDED 2026-08-28** — deterministic adapters, the direct flat backing, loader identity, lifetime checks, and downstream sample/project consumers are green; see the measured As-built verdict. | data-model · DM5 | `data-model/05-adapters-and-three-backing-proof.md` | ☑ 2026-08-28 |
| DM6 | **DM6** — projection/builders | Column projection, exclusive transfer proof, and output builders. **☑ LANDED 2026-08-28** — projection policy and exclusive-transfer/open-builder verdicts are executable; flat/native eight-append measurements and the full build are green. | data-model · DM6 | `data-model/06-job-projection-and-exclusive-builders.md` | ☑ 2026-08-28 |
| DM7a | **DM7a** — lane contract/façade | Contract-backed static lanes and a green single-authority static façade. **☑ LANDED 2026-08-28** — the descriptor is the sole contract authority, the temporary `WorkerLane` view is derived, cache identities are separated, and the full kzen-auto build is green. | data-model · DM7a | `data-model/07a-job-lane-contract-and-bridge.md` | ☑ 2026-08-28 |
| DM7b | **DM7b** — value producers/workers | Runtime bridge, DataValue channels, source producers, and column Workers; delete the cursor item-kind bridge. **☑ LANDED 2026-08-28** — all Job transport/cursors/sources carry `DataValue`, ordinary column Workers bind projections directly, cursor carrier-history dispatch is deleted, and the full kzen-auto build is green. | data-model · DM7b | `data-model/07b-job-value-producers-and-workers.md` | ☑ 2026-08-28 |
| DM7c | **DM7c** — carrier deletion/gate | Formula/sinks/hosts cutover, foundation benchmark gate, then legacy carrier deletion. **☑ LANDED 2026-08-28** — one `DataValue` carrier, explicit Formula carry/boundaries, legacy carrier/lane façades deleted, downstream builds green, and S1 at 25,634.5 ms versus the 25,774.9 ms baseline. | data-model · DM7c | `data-model/07c-job-carrier-deletion-and-foundation-gate.md` | ☑ 2026-08-28 |
| DM8 | **DM8** — binding inventory/model | Reconcile all Logic signatures, settle Report as no-output, and add binding vocabulary. **☑ LANDED 2026-08-28** — frozen schemas/bindings, defaults/origins/sensitivity, concurrent strict output settlement, Report's honest empty output, and the complete host/signature disposition inventory are green. | data-model · DM8 | `data-model/08-binding-inventory-and-binding-model.md` | ☑ 2026-08-28 |
| DM9a | **DM9a** — core binding engine | Additive kzen-lib binding-native engine with tuple bridge retained. **☑ LANDED 2026-08-28** — engine storage, validation, hosting, and output settlement are binding-native; the single temporary tuple edge preserves unchanged consumers and standalone kzen-auto compilation is green. | data-model · DM9a | `data-model/09a-core-binding-engine-and-bridge.md` | ☑ 2026-08-28 |
| DM9b | **DM9b** — auto binding migration | All kzen-auto flavours, Job hosts, and data-source callers are binding-native; focused/full builds and publication passed. | data-model · DM9b | `data-model/09b-auto-binding-migration.md` | ☑ 2026-08-28 |
| DM9c | **DM9c** — tuple deletion/proof | Canonical binding API promoted, tuple/bridge surface deleted, and all direct/release-train downstream builds passed. | data-model · DM9c | `data-model/09c-tuple-deletion-and-downstream-proof.md` | ☑ 2026-08-28 |
| DM10 | **DM10** — Script boundary | Recorded results/replay/migration/handoffs carry DataValue; native projection, snapshots, Formula canary, and full suite passed. | data-model · DM10 | `data-model/10-script-generic-boundary-cutover.md` | ☑ 2026-08-28 |
| DM11 | **DM11** — Flow boundary/gate | Contracted ports and DataValue messages/migration landed; consolidated foundation/binding/Script/Flow and downstream gates passed. | data-model · DM11 | `data-model/11-flow-generic-boundary-cutover.md` | ☑ 2026-08-28 |
| 6 | **J5b** — DataValue perf fixes + headless | **Revalidate after DM11:** retain IO/headless goals, but rewrite stale `JobMessage`/`FlatView` pooling and batching assumptions against the landed `DataValue` carrier before implementation | J · P5 session B | `next/J5` | ☐ |
| 3 | **J4** — Report subsumption B | After J5b: `groupBy` export parity, summary/Explore offline persistence, composed A/B gate, Report frozen | J · P4 | — | ☐ |
| 4 | **J9** — file-backed carry-forward | After J4: writer append cursor, Pivot store carry, Explore append, `resumed` progress key | J · P9 | — | ☐ |
| 7 | **J7** — interactivity remainder | `retain=false` progress emits, deadlock precision, channel occupancy | J · P7 | `next/J7` | ☐ |
| 8 | **J8** — Job client sweep + hygiene | Consumed-subset `JobController`, editor dedup, doc debt | J · P8 | — | ☐ |
| DM12 | **DM12** — first structured reader | Consumer-gated tape-backed reader; not scheduled until a selected reader needs it | data-model · DM12 | `data-model/12-first-structured-reader.md` | ◇ |
| DM13 | **DM13** — first durable row | Provider/design-gated row backing, constraints, and measured lifetime; not scheduled yet | data-model · DM13 | `data-model/13-first-durable-row-source.md` | ◇ |
| DR1 | **DR1** — resolved-read identity — **☑ LANDED 2026-09-01** | `ResolvedReadSpec`/`ReaderConfig` snapshot, capability vocabulary, digests, cache/migration identity; no behaviour change | DR · DR1 | `data-read-config/01-resolved-read-identity.md` | ☑ 2026-09-01 |
| DR2 | **DR2** — schema capability + Custom discovery — **☑ LANDED 2026-09-01** | `RecordSchema` extracted from its document wrapper; capability/inheritance-based prototype discovery (coordinate with E4) | DR · DR2 | `data-read-config/02-schema-capability-and-custom-discovery.md` | ☑ 2026-09-01 |
| DR3 | **DR3** — sequential content stack — **☑ LANDED 2026-09-01** | Provider-neutral sequential handles, explicit gzip/identity coding, character decoding, lifetime/cancellation proof | DR · DR3 | `data-read-config/03-sequential-content-stack.md` | ☑ 2026-09-01 |
| DR4 | **DR4** — configured delimited reader — **☑ LANDED 2026-09-01** | Configured framing/dialect/header/schema with typed emission; atomic CSV/TSV cutover to configured instances | DR · DR4 | `data-read-config/04-configured-delimited-reader.md` | ☑ 2026-09-01 |
| DR5 | **DR5** — fake-provider proof — **☑ LANDED 2026-09-01** | Fake object-store provider runs the full reader suite; architectural neutrality pin | DR · DR5 | `data-read-config/05-fake-provider-proof.md` | ☑ 2026-09-01 |
| DR6 | **DR6** — Job/UI/expression cutover — **☑ LANDED 2026-09-01** | Full `DataContract` through validation, cards/connectors, typed expressions; selection UI with schema drafts | DR · DR6 | `data-read-config/06-job-ui-expression-cutover.md` | ☑ 2026-09-01 |
| DR7 | **DR7** — acceptance/performance gate — **☑ LANDED 2026-09-01** | Fixture matrices, full sibling builds, opt-in 100k canary baseline and threshold | DR · DR7 | `data-read-config/07-acceptance-and-performance-gate.md` | ☑ 2026-09-01 |
| DR8a | **DR8a** — detection contracts + optional SPIs — **☑ LANDED 2026-09-03** | Common resolution/provenance/policy models, contextual format resolution, probe/authoring capabilities, graph-backed registry and cache identity | DR8 · DR8a | `data-format-detection/01-resolution-contracts-and-probe-spi.md` | ☑ 2026-09-03 |
| DR8b | **DR8b** — built-in probes + Plain text — **☑ LANDED 2026-09-03** | Bounded shared detector, delimited candidates/header inference, strict skip/comment config and Plain-text reader | DR8 · DR8b | `data-format-detection/02-built-in-probes-and-text-reader.md` | ☑ 2026-09-03 |
| DR8c | **DR8c** — Automatic source cutover — **☑ LANDED 2026-09-03** | Per-file overrides, concrete manifests/provenance, aggregate budgets and File-source default switch | DR8 · DR8c | `data-format-detection/03-automatic-source-integration.md` | ☑ 2026-09-03 |
| DR8d | **DR8d** — selection preview + correction UI — **☑ LANDED 2026-09-03** | Row resolution/epochs/presentation, contributed editor host and source-local corrected formats | DR8 · DR8d | `data-format-detection/04-selection-resolution-and-correction-ui.md` | ☑ 2026-09-03 |
| DR8e | **DR8e** — explicit format + locked columns — **☑ LANDED 2026-09-03** | Make explicit, Lock columns, authored schema/format materialization and drift proof | DR8 · DR8e | `data-format-detection/05-explicit-format-and-column-locking.md` | ☑ 2026-09-03 |
| DR8f | **DR8f** — acceptance/performance/downstream gate — **☑ LANDED 2026-09-03** | Full matrix, aggregate/performance measurements, SPI publication, sample plugin and standalone project builds | DR8 · DR8f | `data-format-detection/06-acceptance-performance-and-downstream-gate.md` | ☑ 2026-09-03 |
| 9 | **E1** — extensibility ratification | **Ratified 2026-09-04 with the user**, driven by `docs/analysis/2026-09-03_in-process-hosting.md` §6a: D1 yes (no KSP required), R5-G boot-pinned, D2 per plugin directory, D3 not now (do not preclude), D4 moot, D7 out of scope, D8 dropped (expression Workers already do it), D9 yes without wrappers, plus Java-friendly SPI adapters. Verdict table is the E plan's Phase E1 as-built | E · E1 | — | ☑ |
| 10 | **E2** — plugin = classloader | One **process-global `KzenAutoRuntime`** (initialized once before any context; conflicting re-init fails fast) owning one `URLClassLoader` per `plugins/<name>/` jar set (`--plugin.root=`, deterministic order, duplicate ids / readers / notation paths are boot errors, per-scope failure isolation), app loader as plugin zero; per loader: `ServiceLoader` readers de-duplicated by declaring loader and bundled notation; **one `ReflectiveClassMirror` over the runtime's aggregate delegating loader** (lazy — no boot validation promise; a `@Reflect` name in two scopes is a resolution-time ambiguity, review 2); `dynamicParentClassLoader()` returns that aggregate (zero call-site changes for loading) and `ScriptKotlinCompiler` receives the explicit plugin-jar union (review 2: `classpathFromClassloader` cannot see through a delegating loader); plugin `@Service` needs validated **per context** and surfaced as "unavailable in this workspace", never blocking (review 2); the runtime claims live work roots, a duplicate fails fast (review 2); `BlockingReaderCapability` + **cursor-driven** `SourceWorker` in `kzen-auto-plugin`; `Class<?>`-keyed `KzenAutoHost` builder for Java hosts; optional manifest with SPI-compatibility version; `plugins.yaml` / plugin `ReportDefiner` discovery retired. Verified pure-Java from a folder (sample plugin, unshaded) **and** as a dependency **and** Kotlin+KSP, plus the two-plugin expression / identity / ambiguity gate and a reusable plugin compatibility test kit. **L; needs the HS Java 25 baseline first** | E · E2 | — | ☐ |
| 11 | **E3** — plugin UX | `PluginDocument` becomes the read-only, **discovery-based** diagnostics view of the runtime's plugin scopes (explicit-protocol contributions, classes the mirror actually resolved, named failures — no exhaustive class inventory), listing from cached state, `--plugin.root=` CLI, docs rewritten to plugin = loader; upload deliberately not precluded. **M** | E · E3 | — | ☐ |
| 12 | **E4** — Custom power + C7 | The document-rename nested-exports gap (kzen-lib), prototype metadata, per-tag registry, result persistence | E · E4 | — | ☐ |
| 13 | **E5** — registry disposition | ~~Execute D4; migrate `FormulaStep` whitelist sourcing~~ **MOOT 2026-09-04** — `ObjectRegistryScan` left the tree during the Job data-source work; a doc grep is all that remains | E · E5 | — | ⊘ |
| 14 | **E6** — DataSchema gate | ~~Execute D5 (park until a field/type-schema consumer exists)~~ **ABSORBED 2026-08-24 by DS6** (row 56): the shipped document is now `DataSchema`, consumed structurally by `FileDataSource.staticShape`, with declared types retained for future typed-lane work | E · E6 | — | ⊘ |
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
| 27 | **J6** — fan-out topology | `TeeWorker` + list-typed channel ports — **demand-driven after DM7c; implement through DM6/DM7c's explicit alias/copy rule only when a real flow needs it** | J · P6 | `next/J6` | ☐ |
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
| 43 | **CX11** — Job worker context capability | **The engine decision is made and landed (2026-08-03); the feature it gates is not.** The user chose **worker frames export-opaque by construction** over hard-error-on-collision (schedule-dependent diagnosis — the same document would pass or fail run to run) and per-frame-merge (needs a merge vocabulary and an answer for disposing N values in one slot), on the stated grounds that concurrent context is better kept deterministic and reopenable later. Landed as a **context barrier** on `Execution.host(contextBarrier=)`: opaque to outward writes, transparent to inward reads, passed by `JobRun` on every Worker. Both row-40 hazards are now structurally unreachable for a Job rather than merely documented. **What remains is two smaller, independent pieces, neither claimed:** *(a)* a **Job document-level signature** — now unblocked and a near-copy of row 41's Flow work, since the Job ROOT is an ordinary sequential frame and only Worker frames are barriered; *(b)* a **Worker read path** — a Worker still never sees its own `Execution` (`WorkerLogic` holds it, but the authored `Worker` SPI gets only `JobControl`, which has no binding member), so reading ambient context from a Worker needs a new `JobControl` member. Worker-level *publishing* is now foreclosed by design, not merely unbuilt | CX · 3 J verdict | — | ◪ |
| 44 | **Report hostability invariant** | **Resolved 2026-08-03 in the direction opposite to the row's framing: there was no invariant to enforce — the two KDoc comments asserting one were simply wrong, and are corrected.** Every Logic document is hostable, Report included; that is a design point, and `LogicCompiler`'s deliberate absence of a flavour `when` is its expression. Row 40 filed this as "an unenforced invariant"; the enforcement was never missing, the claim was. Verified rather than asserted: `ReportHostedTest` drives a Script → `RunStep` → Report end to end and reads the materialized table back (3 rows), the run dir's mtimes confirming the pipeline actually re-ran rather than a stale artefact being read. `SelectLogicEditor`'s `isLogic` predicate was right all along and is untouched | CX · 8 (Phase 8) | — | ☑ |
| 45 | **Hosted-Report top-level assumptions** | Found by row 44's fixture, three places where a Report still assumes it is the run root. Execution is unaffected in all three — a hosted Report runs correctly to completion — so each fails quietly rather than loudly, which is what makes them worth a row. **(a) UI request addressing:** `ReportRun` registers its preview/summary handler on its OWN node via `Execution.onRequest`, while the client addresses the run's ROOT frame (`logicRunInfo.frame.executionId`), so a hosted Report's online output info and summary previews silently answer nothing. **(b) Run-dir identity:** the run dir is stamped with the compiling run's `LogicRunExecutionId`, which when hosted is the HOST's identity, so offline progress correlation points at the wrong frame. **(c) Output signature mismatch:** `ReportLogicCompiler` declares `TupleDefinition.ofMain(LogicType.string)` while `ReportRun.run` returns `TupleValue.empty` — so a hosted Report's `main` is null and a caller declaring `nullable: false` fails the cast *after* the report has run correctly. **Decision 2026-08-28: Report declares no output; remove the false `main` declaration.** A future Report return value needs its own explicit type and consumer. (a) remains the substantial client+server change | — | — | ☐ |
| 46 | **SIR** — Script implicit result | **Language-semantics change to the Script flavour, on direct user request (2026-08-05).** A `ResultStep` is `return` — it always ends the Script, and the per-step `then: keepRunning \| endScript` dropdown ceases to exist; a Script that simply ends yields its **last root step's** value, the way an `IfStep` returns its taken branch's terminal and a `ForEachStep` collects its body's. Root steps after a root-level Result are unreachable (warning, never gates Run); an implicit terminal that is Unit or wrong-typed is an error, uniformly — a **nested** Result grants no exemption, because it is a *conditional* early return and the fall-through path still owes the declared type (the plan's §1.1 is the only record of why the first draft's suppression was rejected). **3 sessions (A semantics+runtime / B validation / C client chip + smoke)**, each a green full build. Blast radius pinned by scanning all 48 `is: ResultStep` occurrences: 4 fixtures inverted, 2 documents newly failed and were migrated. **☑ LANDED 2026-08-06** — see the plan's §10 As-built: the scan-by-construct missed a fifth inverted fixture (one with *no* Result step), `ScriptValueReferences` had to seed the implicit terminal or a trailing root loop silently returned `[]`, and `notation/main/**` turned out not to be served from the jar at all | — (standalone) | `next/script-implicit-result` | ☑ |

| 47 | **XCE** — expression code editor | **Client-surface change to the Script flavour's Kotlin expression field plus the server plumbing it needs, on direct user request (2026-08-06).** Today the `Code` field is a bare MUI multiline `TextField` and its validation error is a plain `div` on the *card*, so `1.. 5x` yields "Expecting an element" with no indication of **where**. Two structural facts shaped it: a complete Kotlin lexer (`KotlinExpressionAnalyzer`, commonMain, 389 lines, tested) already runs in the browser and throws its tokens away — highlighting is *stop discarding them*, not a new lexer; and error positions are computed by the compiler and then deliberately destroyed (`formatError` renders `withLocation = false`, `KotlinCompilerError` carries only a `String`, `StepValidation` only an `errorMessage`). CodeMirror 6 was **rejected** (~6 npm packages into a tree declaring six, a full `external` surface to re-validate on every wrappers bump, `useCommonJs()` is load-bearing, and no official CM6 Kotlin mode exists — it would run `clike`, strictly worse than the exact lexer already in commonMain); a transparent-textarea overlay costs one component and no dependencies. Flagging unknown identifiers client-side was also rejected (misfires on locals); what ships is the false-positive-free inverse — in-scope names get a *resolved reference* colour, an unknown name is simply undecorated. **3 sessions (A lexer tokens + `KotlinCodeArea` overlay / B compiler error offsets end to end + inline marker / C completion + docs + smoke)**, each a green full build. Gate B.0 answered **POPULATED** before any of B was written — the K2 scripting compiler does carry `ScriptDiagnostic.location` for parse errors, so the `KotlinSyntaxValidator` pre-pass fallback (which would have added an `@Service` parameter to six **plugin-SPI** step classes) was not needed. **☑ LANDED 2026-08-06** — see the plan's §10 As-built. Three things a later reader will want: the plan's own headline case (`1.. 5x`) reports an offset equal to `code.length`, which belongs to **no** token, so both the error marker and the completion caret-anchor needed an explicit end-of-text branch — the same contract edge bit twice; the staleness rule as specified (buffer == server value) is **not sufficient**, because `refresh` clears `loaded` without clearing the validation while the new notation is already published, so the marker is additionally gated on `validationState.loaded`; and the §9 message-diff sweep came back **zero documents changed** (322 units, 8 errored, 0 differ) because K2's cascade artefact always lands *outside* the user's region, making first-in-region and `errors.last()` coincide on every real document. **One out-of-plan defect was fixed on user request (§10.6):** the lexer tested for a numeric literal with the Unicode-aware `Char.isDigit()` but advanced only over ASCII identifier parts, so a single non-ASCII digit (`١`, `१`, `１`) consumed nothing and looped forever — pre-existing at `HEAD` and reachable via the dependency gutter, but this feature re-lexes on every keystroke, so one paste would hang the browser tab. Fixed by giving the lexer a single ASCII notion of "digit" rather than guarding the loop. **User feedback on the shipped field produced a second follow-up (§10.7):** the marker had an impostor — a textarea's glyphs can be made transparent but *the browser's own spelling squiggle cannot*, so Chrome was drawing a red wavy underline under every identifier missing from its dictionary (`listOf`, most step names), in exactly the marker's colour and style, on expressions with no error. Invisible to the smoke because a UA spelling decoration has no DOM node and no computed style. Fixed on both sides: `spellcheck="false"` through a new `htmlInputSlotProps` bridge (MUI 9's `htmlInput` slot is the element; `slotProps.input` is the `InputBase` above it), and the marker changed from wavy to a solid 2px offset rule — a red wave *is* the platform's misspelling convention, so it was the wrong signifier regardless | — (standalone) | `next/expression-code-editor` | ☑ |

| 48 | **DDC** — detached download content shape | **Small server-side refactor on direct user request (2026-08-17)**, from the `TODO` on `ExecutionDownloadResult.kt:6` asking for the KMP equivalent of `InputStream`. The question turned out to be aimed at the wrong problem: `ExecutionDownloadResult` **never crosses a platform boundary** — the client's whole download contract is a URL (`linkDetachedDownload` / `linkJobDownload` → `<a href>`), so no `commonMain` or `jsMain` code names the type and a multiplatform move buys nothing. What the shape *is* costing is two live defects: `ByteStreams.copy` at `KzenAutoMain.kt:575`/`:589` **never closes the stream** (a `Files.newInputStream` handle released non-deterministically, and on Windows one that pins the file against deletion), and `PivotBuilder` must **invert itself push→pull** through a `PipedInputStream` + raw `Thread` because the type demands a pull. Meanwhile **two of three producers are literally a file on disk** and one resolves its path twice. Lands as a sealed `ExecutionDownloadContent` — `OfFile(Path)` (Ktor's `LocalFileContent` owns open/copy/close; nothing in our code holds a handle) and `OfWriter(suspend (OutputStream) -> Unit)` (deletes the pipe, the thread, and the silent mid-export thread death) — plus **deletion of the orphaned `DetachedDownloadExecutor`** (CC-10: one impl, zero interface-typed consumers; its twin has no interface at all — the common `DetachedExecutor` it once mirrored was deleted in `02716c30`). ~8 files, `kzen-auto-jvm` only. Its §1.1 is the only record of four rejections: `.use {}`-only (leaves the pipe and leaves ownership a rule to remember — **but is the correct descope if this is ever cut**), pure push (fuses acquire with transfer, so a missing table becomes a truncated 200 instead of a clean 500), `commonMain` + kotlinx-io (referenced **nowhere** in the umbrella except inside that TODO; would add a klib to the JS bundle for a type JS never touches, and move a notation `class:` FQN — the CC-21 surface the `FlowWiring` bug came from), and `BinaryExecutionValue` (materializes an unbounded table). ⚠ **Carries a measure-first gate (§4.2):** `OfWriter` gives up the pipe's genuine producer/consumer overlap, so the pivot export is timed before and after and **the numbers are recorded either way** — the prior is that a 1 KB pipe window with per-flush thread wakeups costs more than it wins, but that is a prediction, not a result. Also records what the change does **not** buy: no `Content-Length` or ranges, because `install(Compression)` gzips `text/csv` into a chunked response regardless and `PartialContent` is a separate uninstalled artifact. **Carries one standing decision beyond the refactor (§5.1, user-approved 2026-08-17, reversing the first draft's recommendation):** `ktor-server-test-host` enters `kzen-auto-jvm` as a **test-scope** dependency, giving the repo its **first route-level tests** — there are 24 routes and zero today, so the layer between unit tests and the `kzen-auto-test:selfTest` blackbox suite is empty. Entry cost is near zero because `Application.ktorMain` (`KzenAutoMain.kt:148`) is **already public and already takes the context**, so `testApplication` stands up the real plugin stack (ContentNegotiation / SSE / **Compression**) with **no production-code change**; `KzenAutoContext.forTest()` is likewise already proven. ⚠ Two boundaries recorded so this cannot sprawl: the test host runs an **in-process engine, not Netty**, so it proves the handler contract and *not* the wire (the manual smoke still earns its place), and **only the two download routes are covered here** — the other 22, notably the `/logic/events` SSE stream, are §6 backlog deserving their own row. One assertion is written specifically to convert §4.1 from argument into fact. **☑ LANDED 2026-08-17** — one session, green full `kzen-auto` build; see the plan's §7 As-built. **Both gates resolved against the plan's own prose.** §4.2: the pipe's overlap was a net *cost*, not a benefit — 200,000 pivot rows / 3.27 MB of CSV, median **3123 ms direct vs 3754 ms piped** (~17%, and understated, since both arms pay the same constant store-open inside the timed region), so no overlap is reintroduced. §4.1: **conditionally false as drafted** — `LocalFileContent` advertises an exact `Content-Length` and it is `install(Compression)` that drops it, only for a client that offered an encoding; `respondOutputStream` could never advertise one, so `OfFile` *did* buy an observable property the draft said it would not (browsers always negotiate, so the UI is unaffected). **The one real miss is a reachability assumption, and it cost two of the planned route tests:** `AutoConventions.serverAllowed` = {`kzen/`, `auto-common/`, `auto-jvm/`, `main/`} excludes `test/`, so `ModelDetachedExecutor` can never reach a `DetachedDownloadAction` in test notation — and the only concrete Report documents live in `test/` or the user's `main/`. The same gap makes the §2.1 pre-commit guard unreachable from either *real* route (both file producers guard upstream of it), so it is a genuine backstop with no naturally-occurring caller — worth knowing before someone deletes it as unreached. Both were recovered by the session's most reusable output: `KzenAutoConfig(moduleRoot = <temp dir>)` scopes `GradleLocator` to a temp tree while `ClasspathNotationMedia(exclude = main/)` still supplies the archetypes, so a test drops a `@Reflect` fixture action into `main/` **in temp** — inside `serverAllowed`, served by `ReflectiveClassMirror`, colliding with nothing — and reaches any detached route with no Report, no run and no input files. That is the lever the §6 route-coverage backlog should be built on. ⚠ **§5.3's manual smoke is the one item not done** (it needs a browser and the user's own documents); the `OfFile` branch was instead proven on a real Netty socket from an isolated temp work root, so what stays unsmoked is the **`OfWriter` branch over the wire** | — (standalone) | `next/detached-download-content` | ☑ |
| 49 | **DS0** — data-layer package moves out of Report | **DS arc prep** (`docs/analysis/2026-08-20_data-source-model.md` §6). Mechanical package/import work: move `HeaderListing` / `HeaderLabel` / `HeaderLabelMap` to `common/data/schema/`, and move the flat-input and listing plumbing row 52 consumes out of Report-owned packages. Method bodies do not change. **Must precede rows 50 and 52** so the new abstractions do not cement Report ownership. **M** | — (analysis) | `next/DS0` | ☑ 2026-08-23 |
| 50 | **DS1** — data-source value model + lowering | **Start of the DS arc (Job data sources), added 2026-08-21 on direct user request; reusable model rationale lives in `docs/analysis/2026-08-20_data-source-model.md` (+ `2026-08-21_extension-points.md`), while Job integration and the full chronological record live in `docs/analysis/2026-08-20_job-data-source.md` §13 — the `next/DS*` files are deleted on landing.** `DataRole` / `DataRef` / `DataPart` / `DataUnit` / `DataManifest` / `DataSourceId` / `DataResolveResult` / `DataShape` in kzen-auto-common with digest, `ExecutionValue` lowering, kotlinx wire form, `DataLocation` ⇄ `DataRef`, and the construction helpers a user-authored source needs. **`DataRef.source` is a nullable `DataSourceId` that nothing mints in this arc** — every v1 ref is a plain path (O15 — deferred to the first provider-bound source); attribute order presentation-only, digest sorts keys; reserved fingerprint keys `size` / `modified` (data-source model §4.2). **S–M, common only, no consumers yet** | — (analysis) | `next/DS1` | ☑ 2026-08-23 |
| 51 | **DS1b** — expression type visibility + registry retirement | **A standing bug the DS arc would trip over** (§5.5): `ExpressionReturnTypeInference.toTypeMetadata` erases any classifier outside an eleven-entry hardcoded `visibleBuiltins` and the one-entry `ObjectRegistry` down to `Any` — so a `DataUnit` on a lane would type as `Any`. Replace the whitelist with a **public-and-nameable predicate**, retire `ObjectRegistry` and its scan/cache/context plus UI/notation surface, and replace `isIterable` with **`isStreamType`** covering `Iterable \| Sequence \| Iterator` (O6). Independent of the arc and worth landing regardless; still a prerequisite for the typed unit lane (rows 53, 55). **M** | — (analysis) | `next/DS1b` | ☑ 2026-08-23 |
| 52 | **DS2** — the suspend runtime: `DataSource` / `DataOpener` / `DataCursor` / `DataContext`, `FileDataSource` + `FileDataOpener`, `DataSourceActions` | **`resolve` / `open` are `suspend`** and take a minimal `DataContext` (`argument` + `blocking` in this phase); **`DataSource` owns `resolve` plus optional notation-only `staticShape`, `DataOpener` owns runtime `open` plus bounded `inspectShape`**; `DataCursor` is a plain pull reader the worker drives inside `blocking`; `FileDataSource` resolves to **plain refs** with a stamped fingerprint and the shared `FileDataOpener` reads them; `DataOpenerLookup` maps plain refs to the file opener and fails clearly for unsupported sourced refs; **no id minting, no resolver, no `DataSources` document**; one generic `DataSourceActions` dispatcher with named action constants; the Job `sources:` branch + graph-wide discovery. Row 49 already moved the input plumbing. **Spike O14 first — blank, set, cross-document, and delete. M** | — (analysis) | `next/DS2` | ☑ 2026-08-23 |
| 53 | **DS3** — `ReadWorker` (source-generic declarative reader) | `source:` a **nullable nominal `ObjectReference`** preserved through construction and resolved against the compiled run snapshot (O14 fallback); `emit: items \| units` (O11), `role:`, **`attributes: ignore \| columns`** — unit attributes as leading columns, the `groupBy` parity path (O22); parts open via `DataOpenerLookup`; **every cursor call inside `blocking`** (pinned by an offload counter in the A/B); resolved manifest **carried** across migration with the open cursor detached and driven by the new control; `payloadFlow` comes directly from the resolved source's `staticShape(role)`. Heterogeneous item schemas **fail loudly** (§5.3); superset in row 56. Lifts the drain core (`DataReadCore`) for row 55 and uses `partsOf(role)` for the multi-part contract. Removes `CsvReaderWorker` / `MultiFileReaderWorker` from the ribbon (archetypes stay). A/B vs both old readers. **M–L** | — (analysis) | `next/DS3` | ☑ 2026-08-23 |
| 54 | **DS4** — source-worker editing surface | **Corrected twice after UI review:** no detached `Data sources` section, `Data` ribbon, or `DataSourceCard`. **File** / **Logic** are ordinary source Workers in the existing Sources ribbon: select the tool, choose a normal stage insertion gap, then edit a notation-selected Worker display in the one stage. File contributes `FileSourceWorkerDisplay`, which composes the ordinary card: the extracted `FileBrowser` presentation shared with Report (breadcrumb/search/folders-first metadata table/range selection/Add/Remove) rendered **inline and first** on Report's rule — pinned open while nothing is selected, behind a **Browser** toggle in the card header once something is (the toggle reaches the header through a `DocumentBridge` channel and `WorkerDisplayDefault`'s generic `headerRight` slot, never by widening the attribute-editor contract) — then the ordered selection below it as `FileSelectionTable`, sharing the browser's own frame, sticky header and palette (`FileTableStyles`) and offering check-then-act **Remove (n)** / **Up** / **Down** plus a **Details** toggle for the full path and per-file format overrides, with execution settings under **Advanced** (a launcher-button dialog was tried and rejected on 2026-08-24; the selection was brought up to the browser's presentation, and the toggle moved into the header, the same day). **Format** and **Encoding** are selects rather than free text — a Worker's defaults and each file's overrides both read the server's installed definitions through a `fileFormats` action answered before any source is resolved, cached once per document (2026-08-25). Chooser navigation persists separately from runtime directory-query fields — the `browser:` marker is declared once on `FileDataSourceConfig` and inherited — so removing the last explicit file, or merely browsing, cannot activate a directory scan. Both Workers reuse row 53's manifest/projection/cursor/migration engine over channel-free `FileDataSource` / `LogicDataSource` delegates and participate in ordinary ordering, drag/drop, channel synthesis, validation and progress. Pure DataSource objects + nominal `ReadWorker` remain available for authored cross-document use. Inline Workers omit detached Resolve/Columns chrome; declared schema reaches server validation and live Summary supplies downstream suggestions. **No id minting; no file/logic branch in `JobController`.** | — (analysis) | `next/DS4` | ☑ 2026-08-24 |
| 55 | **DS5** — `ReadPartWorker` + migration-safe 1:N transforms | Expressions never initiate source I/O, so a generic in-memory `ExpandWorker` remains demand-driven (O1). A distinct **`ExpandingTransformWorker`** owns the active input batch, current element, output cadence, and their migratable state; checkpointing within an expansion therefore cannot lose the current or remaining inputs. `ReadPartWorker` opens all `unit.partsOf(role)` in order through row 53's `DataReadCore`, and its subclass state carries the part/item cursor. The child-Logic fixture uses one unit and a fixed output path; the per-unit dated path moves to row 57. Needs rows 51, 53. **M** | — (analysis) | `next/DS5` | ☑ 2026-08-24 |
| 56 | **DS6** — design-time shape | `DataShape` (`Tabular` \| `Payload`); **`DataSource.staticShape(role)`** is notation-only and direct for the walk, while **`suspend DataOpener.inspectShape(context, part)`** is bounded runtime inspection. `DataSourceActions action=shape` tries them in that order, so a declaration wins without IO; a **`SchemaCache` service** keyed on the fingerprint row 52 stamps into the ref — **not** an SPI member and never consulted by the validation walk; the declared-schema route renames `DataFormat` to `DataSchema` (O18); **superset normalization** is selected by semantic `schemaMode: strict \| superset` on both readers (O19); `JobUpstreamSchema` provider list and `SortSpecEditor` dropdown. The corrected inline File/Logic Workers omit the removed detached Columns chrome; declared schema still feeds server validation and a live Summary feeds downstream editor suggestions. **No row preview** (§9). **Absorbs J3b. M–L** | — (analysis) | `next/DS6` | ☑ 2026-08-24 |
| 57 | **DS7** — writer refs, named child arguments, per-unit paths | Adds generic `RunWorker.arguments`, evaluated in the existing formula scope and bound to named child parameters, plus the named `JobControl.host` overload. Extracts neutral `PathPatternSubstitution`; writers resolve job parameters such as `${date}`. On successful completion a writer finalizes exactly once **before** it stats and yields its plain `DataRef`, including buffered/compressed output; `onClose` is the failure/cancellation fallback. Also adds `keep: all` (O2), manifest tracing, and the §7.1 outer/inner fixture. **Same-run composition only** — no persisted registry. ⚠ `ExecutionValue.ofArbitrary` does not lower a `DataRef`; wire `asExecutionValue()` at arbitrary result boundaries. Same file as J4's `groupBy` — sequence, don't interleave. **M–L** | — (analysis) | `next/DS7` | ☑ 2026-08-24 |
| 58 | **DS8** — `LogicDataSource` + dated-source example | (O16) Adds `DataContext.host` with its first caller and ships a **resolve-only** `LogicDataSource` whose `resolve` delegates to a user-authored **Script / Flow / Job** through row 57's named `JobControl.host` path, minting plain refs the shared `FileDataOpener` reads. Reuses row 57's argument binding and `PathPatternSubstitution`; it introduces no second binding or substitution mechanism. The dated case ships as a **one-step example Script**, and the arc acceptance fixture proves the outer/inner ETL round-trip with no expression I/O. Kotlin `DatedPathDataSource` stays in reserve if date iteration in a Script proves clumsy. **Closes the arc — flip the analysis doc's status to landed. S–M** | — (analysis) | `next/DS8` | ☑ 2026-08-24 |
| 59 | **E7** — plain-object data shape | **Added 2026-09-04 from the E1 session.** Ordinary Java classes by JavaBeans convention (no annotations, no wrapper), enums as text, `Set` as unordered Listing, per-class native-token cache, **recursive type references in `DataType` (touches kzen-lib-common — coordinate with DM)**, and design-time shape in `JobExpressionCompiler` through the adapter registry so a record-typed stream shows its columns before the first run. Records / data classes / List / Map / scalars already lift typed and navigate lazily. **M; independent of E2** | E · E7 | — | ☐ |
| 60 | **E8** — object-graph paths | Path-projection / unnest Worker (`instrument.symbol`, `executions[*].price` → flat columns, one row per element) + design-time path picker over the upstream contract. The one new Worker for reporting over an object graph without code. **M** | E · E8 | — | ☐ |
| 61 | **E9** — closeable streams and items | **Added 2026-09-04 (user requirement via review 1 of the hosting analysis).** `AutoCloseable` honoured on every expression stream type (`Iterable` / `Iterator` / `Sequence` + new `java.util.stream.Stream`) — closed on completion / cancel / failure, detached and re-adopted across live-edit migration instead of re-evaluated; and on **individual elements** — emitting an `AutoCloseable` transfers ownership to the run (a borrowed host object is wrapped); a per-run ledger keyed by native identity counts **leases with named holders** (review 2): a channel from `send` until the consumer's loop hands the element to `onElement`, the Worker implicitly for the duration of the callback (the framework loops consume batches via `receiveBatch()`, so this is where the release lives, per element), and an accumulator **explicitly** via `control.retain` — the only Worker cooperation, and only for retention; last release closes exactly once; owner propagation to navigation children and to non-scalar Formula / Filter outputs; flush-on-send for owned elements; carried unclosed through `drainBuffered` / `preload`; lease holder = Worker location so migration re-adoption is a no-op; all closed at teardown, a throwing `close()` does not stop the rest; post-close access a named error; and a stall diagnostic naming the exact accumulating Worker holding owned items (no validation rule — inherent complexity, surfaced not prevented). This is the mechanism behind the in-process host's memory arena (a symbol-day batch consumes the arena on open, releases on close); kzen needs no admission concept. **M–L; independent of E2 and E7** | E · E9 | — | ☐ |

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

**Rows 41–44 were row 40's output, and they were not a block.** They differed in kind and were sequenced
separately rather than as a unit: **42 was a defect in shipped code** and the only one with a standing cost;
**41 was the licensed feature**; **44 was an adjacent defect** found in passing; **43 was withheld** pending an
engine decision about concurrent frames. All four have since landed (43 in its engine half), and row 45 is
row 44's own output. The pattern held throughout: each row's gate found something the previous gate could not
see, which is the argument for sequencing them separately rather than batching.

**Row 42 landed 2026-08-03** — the defect is fixed and re-published to mavenLocal, so nothing in the tree is
running the broken supersede any more. The fix turned out to need a *path* walk rather than a single-frame
clear (an intermediate frame on the export chain can hold the shadowing borrow), and it was falsified before
being trusted: removing the one call fails exactly the two regression fixtures and leaves the three
concurrency characterizations green.

**Row 41 landed 2026-08-03**, rescoped — see its cell. The rescope is the useful record: row 40's gate proved
the Job case needed an engine decision, but it did *not* re-derive Script's analysis internals, so row 41
inherited an assumption ("takes the Script treatment unchanged") that the anchor pass falsified in three
independent ways. Both gates were doing their job; the second one caught what the first could not see.

**Rows 43 and 44 were both decided by the user on 2026-08-03, and both landed the same day** — 43's engine
half, 44 in full. Two things about them are worth carrying forward, because neither is visible from the
resulting diff:

- **Row 43's decision buys determinism by removing expressiveness, deliberately.** Under the barrier, a
  concurrent sibling cannot hand a resource to a peer or to its shared parent — a barriered flavour can only
  open what it also closes. That is the conservative floor, chosen so the alternatives stay available: a merge
  policy can be added later without invalidating anything built on top of it, whereas shipping last-writer-wins
  and tightening it afterwards could not. The two ⚠ hazard fixtures are deliberately KEPT green and unchanged,
  because the barrier is opt-in and unbarriered concurrent hosting still does exactly what they record.
- **Row 44 inverted its own premise.** It was filed as "an unenforced invariant" — the natural reading of a
  KDoc that says a thing and code that does not check it. The user's ruling was that the *invariant* was the
  error: every Logic document is hostable by design. So the fix was to delete two claims rather than add two
  guards, and the row is a reminder that "code disagrees with comment" does not tell you which one is wrong.
  A fixture settled it, not a reading — and the first version of that fixture failed, which is how row 45's
  output-signature mismatch surfaced.

**Independent CX follow-ups: rows 43a/43b and 45, none claimed.** Row 43's remainder is two small independent pieces (a Job
document-level signature, which is a near-copy of row 41's Flow work and unblocked; and a Worker read path
needing a new `JobControl` member). Row 45 is three quiet hosted-Report defects, of which (a) — the UI request
addressing — is the only substantial one. Nothing in the CX arc blocks anything else any more.

### What to run right now

Re-elaborate and run **J5b** next against the landed `DataValue` carrier, then follow J4 and J9 in ledger order.
The in-process hosting question (a Spring host embedding N kzen workspaces, and a substantive
`kzen-sample-plugin` over real market data) is **back in analysis** — `docs/analysis/2026-09-03_in-process-hosting.md`;
nothing from it is scheduled until its open questions are answered.
If a change of pace is wanted, rows **20 (SH5)**, **23 (C1)**, **21 (FL5)** and **15 (DA1)** remain
independent only when their files do not collide with the active session. Row **25 (C2)** needs the user present — schedule it rather than waiting for a gap. Row 9 (E1) was
ratified on 2026-09-04; **rows 10 (E2), 59 (E7) and 61 (E9) are now open and independent of each other** —
E2 waits on the Java 25 baseline the in-process-hosting analysis calls for, E7 and E9 do not. E9 is the
one kzen change the host's memory governance actually depends on.

Rows **30–32 (XC-N)** are independent of everything above and are a **defect fix** — a shipped verb
that does not do what its spec says. Row 30 must precede row 31 (kzen-lib → `publishToMavenLocal` →
kzen-auto); row 32 is the post-smoke follow-up and is kzen-auto-only. **All three are done** — what
remains is the user's re-smoke, which needs a dev-server restart.

Rows **33–44 (CX)** are all landed as of 2026-08-03, row 43 in its engine half (`◪`). What is left of that
arc is **43a** (Job document-level signature — unblocked, near-copy of row 41), **43b** (Worker read path via
a new `JobControl` member), and **45** (three quiet hosted-Report defects). None of them blocks anything, and
none is claimed. Two verification debts also survive the arc and are the natural first items for whoever next
touches this area: the **Flow-stage browser smoke** from row 41 (the `FlowController` context panels are
compile-verified but were never rendered), and two CX6b coverage gaps (`SelectContextEditor.wireValue`'s
disambiguation branch untested; only `BindStep`'s picker driven end-to-end).

## Dependency rules (the live ones)

1. **J5b → J4 → J9** is the remaining active spine. J5a captured the untouched baseline and DM1–DM11 closed
   the carrier/flavour gates; J5b is re-specified against the landed carrier before J4/J9 reshape
   adjacent Report/Explore/export surfaces.
2. **Do not overlap J4/J9/J5b/J6/J7 with DM1–DM7c.** J7 directly changes `JobChannel`; its elaboration must be
   revalidated against the landed carrier. J8's older J3 dependency is already satisfied by DS2/DS3/DS6, but it
   still follows the ledger and any actual file collision serializes execution.
3. **J5b's old element-model sketch is not executable text after DM7c.** Preserve its IO batching, measured
   optimization, and headless-mode goals, but discard `JobMessage`/`FlatView` pooling assumptions. Any reuse under
   `DataValue` must be benchmark-convicted and obey the hard constraint that migration carryover
   (`JobChannel.drainBuffered`) transfers ownership of live values rather than recycling them.
4. **J6 is demand-driven after DM7c** and blocks nothing; it consumes the explicit alias/copy rule rather than
   inventing an earlier fan-out ownership model.
5. **E1 ratified 2026-09-04; E2 → E3, E7 → E8 and E9 are three independent spines.** E4's **C7 half is independent of all** — the document-rename gap is a
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
- **EXT D1–D6**, awaiting ratification since 2026-07-06 → row 9 — **ratified 2026-09-04**.

**Full per-session record:** `sprint-2/README.md`. It also records four arcs that landed **without
a surviving plan** — the validation indicator, the digest handshake, the document-digest fix and the
`RestHandler` split — recovered from git so the work is not invisible.

**A process note worth keeping.** Three plans were *deleted* rather than archived on 2026-07-23,
taking their deferred scope and pending manual smoke with them, and the `RestHandler` split silently
invalidated line anchors in four unexecuted plans. **Convert a completed plan into an as-built record
in the sprint archive; delete only the elaborations under `docs/plans/next/`.**

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

### EXT-D5 (DataSchema) — resolved by DS6 (2026-08-24)

The reopening trigger arrived: DS6 made the document the declared structural-shape supply consumed by
`FileDataSource.staticShape`. The shipped `DataFormat` vocabulary was renamed to `DataSchema`, its
field `TypeMetadata` is retained, and the source holds a nullable strong structural reference so source
and schema changes participate in validation invalidation. Ledger row 14 is absorbed by row 56; no
separate E6 session remains.

### Rename refactor — known limitation

A rename refactor does **not** cascade to a directory's children: `RenameDocumentRefactorCommand`
copies only the marker document, so renaming a non-empty folder orphans its contents. Separate from
the C7 nested-exports gap (ledger row 12) — don't conflate them.

## Verification

Docs-only meta-plan: no build/test verification. Per-phase verification lives in each constituent
plan and is unchanged by this document.
