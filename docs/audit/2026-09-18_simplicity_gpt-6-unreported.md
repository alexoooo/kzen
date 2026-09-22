# Simplicity audit — Kzen, 2026-09-18

**Purpose:** reduce non-essential complexity, including complexity caused by product promises, not just implementation choices. Existing capabilities, compatibility, platform choices, and previously deliberate designs are open to challenge. **Changes made:** this report and its reproduction script only; no application fixes.

**Attribution:** Codex / GPT-6. The session does not expose its reasoning-effort setting. The filename deliberately records `unreported`; the requested filename metadata was not supplied, and no effort tier has been guessed.

## 1. Verdict

Kzen's largest simplification opportunity is to stop making every layer preserve every other layer's flexibility. A document is simultaneously editable notation, an inherited object model, an executable dependency graph, a source of generated constructors, a client component registry, and the identity of a live computation. Editing that document can trigger local execution of commands, remote execution of commands, validation, identity remapping, recompilation, migration, ownership transfer, and UI reconstruction. Many individual mechanisms are reasonable. Their composition is expensive.

The strongest directions are:

1. **One authority for committed edits.** Keep responsive local drafts, but commit through the server and publish an acknowledged revision. Remove the parallel local/remote command executions and their compensating read gates where possible.
2. **An immutable definition per run.** Edits affect the next run. Preserve pause, cancellation, and inspection, but reconsider transparent live migration, especially for concurrent Jobs and borrowed resources.
3. **Fewer execution contracts.** Retire the unused built-in Task lane; converge Report and Flow implementation where semantics permit. Preserve distinct user interfaces without automatically preserving distinct execution engines.
4. **A smaller declarative surface.** Keep user-authored workflows declarative. Question using the same reflective graph machinery to construct ordinary application UI and services.
5. **One first-party build graph and one application distribution.** Separate user data from immutable runtime versions. Treat third-party/plugin builds as the place to test publication boundaries.

These are recommendations to validate, not measured savings or authorization to remove functionality. Some would deliberately change the product. The experiments below identify what could falsify each recommendation.

Four isolated probes reproduced defects in current source: duplicate stable identities after rename/name reuse, local state surviving a rejected remote edit, dropped callbacks after a settlement subscriber throws, and durable compilation errors surviving a compiler/cache-instance change. Build-input and upgrade-recovery defects were established by source inspection. Fix these independently of architectural decisions.

## 2. Scope, baseline, and confidence

### Source inventory

Inventory taken at approximately **2026-09-18 21:47 America/Toronto**, using `git ls-files -co --exclude-standard`, deduplicating paths and skipping missing files. Counts include physical blank/comment lines. Kotlin/Java under `buildSrc` and `.kts` files count as build logic; `kzen-auto-test` counts as test infrastructure. XML, YAML, Markdown, scripts, lockfiles, binaries, and generated/ignored output are outside these line totals.

| Repository | HEAD | Main files / lines | Test files / lines | Build files / lines |
|---|---|---:|---:|---:|
| kzen | e05c365 | — | — | 1 / 10 |
| kzen-lib | 1826426 | 284 / 28,645 | 144 / 15,883 | 8 / 356 |
| kzen-auto | 4dfbd5c3 | 1,124 / 131,631 | 370 / 51,706 | 9 / 956 |
| kzen-project | 2a5b584 | 5 / 294 | 1 / 161 | 7 / 472 |
| kzen-launcher | f2831aa | 40 / 4,813 | 7 / 917 | 7 / 454 |
| kzen-shell | b1f3c48 | 19 / 2,406 | 10 / 1,015 | 5 / 418 |
| kzen-sample-plugin | f233333 | 69 / 7,109 | 20 / 2,734 | Maven, excluded |
| kzen-sample-embed-spring | b29ddf7 | 37 / 2,958 | 9 / 2,338 | 2 / 80 |
| kzen-repo | fd9630d | Artifact mirror; no Kotlin/Java source | — | — |

The worktree was **not frozen**. The file/format/archive work in kzen-auto changed during this audit. Umbrella analysis/plan documents were already edited, the sample plugin had staged-then-deleted legacy adapter files, and `notation/main/Job-1.yaml` was user work. Those are not cleanup candidates. Recommendations about the changing file model are explicitly provisional. HEADs identify the base, not every byte reviewed.

### Coverage and limits

| Area | Inspection performed | Limits |
|---|---|---|
| Build/publication/distribution | All sibling inventory; settings, dependency declarations, JS bundlers, sample Maven/Gradle boundaries, release procedure | No clean-machine build or IDE import experiment |
| Graph/notation/reflection | Architecture, graph stores, reducers and metadata entry points, mapper, parser contract, KSP processor | No full YAML conformance audit or exhaustive reducer proof |
| Execution | Engine state/migration/history paths, controller migration decisions, Job hosting/ownership/deadlock, Flow/Report execution entry points, Task repository | No scheduler stress suite; no external plugin census |
| Data | Value/type contracts, native-access boundary, schema/compiler caches, source/cursor lending, sample budget and analytical core boundaries | No new throughput or heap benchmark; active file-model changes not judged as finished work |
| Client | Composition root, mirror/REST/gates, global observers, representative Report and file-selection state, React compatibility layer, validation | No browser interaction smoke; not every component read in full |
| Desktop/embedding | Shell startup/process/install paths, launcher project upgrade/registry, workspace lifecycle, proxy, catalog | No destructive upgrade or real-project boot |
| Tests/docs | Test inventories, targeted tests for inspected mechanisms, August audit corrections/remediation, master ledger, guides and relevant as-builts | Coverage counts are not coverage percentages; historical reports are not fresh test results |
| Artifact mirror | README, build/release role, source inventory | No binary provenance or advisory audit |

This is a broad architectural and targeted source audit, **not a claim that every one of roughly 255,000 source/test/build lines was manually read**. No area is exempt because it is deliberate or previously approved. Uninspected individual branches and unmeasured performance claims remain gaps, not implicit clearances.

Findings distinguish **reproduced**, **source-established**, and **hypothesis**. Effort labels are relative: **S** local change; **M** several collaborating units; **L** cross-subsystem migration; **XL** product/architecture change. Priority is value/risk, not file length. No unmeasured line-saving or speedup estimates are presented.

## 3. Defects and immediate simplifications

### F01 — Parallel edit execution creates divergent committed state

**High priority; reproduced; M repair / L simplification.** [MirroredGraphStore.apply][mirror] launches local and remote applies independently. The local branch publishes success before remote acknowledgment. A remote failure returns `MirroredGraphError` without refreshing or undoing the successful local change. Refresh happens only on a successful digest mismatch. [ProjectController][project-controller] can display a command error, but that does not restore the graph; most mutation callers do not reconcile it themselves.

The probe rejects a remote create and observes the document still present in local media. It tests the store contract, not a particular HTTP failure. A transient failure after the server committed is a second ambiguity: blindly retrying a non-idempotent command is not a safe general repair.

**Recommendation:** make the server authoritative for accepted revisions; retain local form drafts and pending indicators. Serialize commits per client, return the accepted revision/change, and update the committed mirror from that result. On an uncertain transport outcome, resynchronize before retrying. If optimistic graph mutation is retained, it needs an explicit pending-command/reconciliation model; a digest comparison alone is insufficient.

**What can disappear:** dual reducer execution on the common path, remote-write settlement plumbing, and some validation retries. **Cost:** an acknowledgment interval before dependent committed-state actions; offline editing would require a separate design. **Experiment:** delayed/rejected/response-lost edits, two rapid noncommutative edits, observer-triggered validation, and two clients. Measure typing-to-render and commit-to-validation latency before deciding whether speculation is necessary. Keep cross-client revision checks even if local speculation disappears.

### F02 — Stable IDs collide after rename and reuse of the original name

**High priority; reproduced; M.** [ObjectStableMapper.objectStableId][mapper] mints `ObjectStableId(objectLocation.asString())`. Rename preserves that ID at the new location. Looking up a new object at the old location then mints the same ID and overwrites the reverse mapping. Both live locations return one ID; the renamed object's reverse lookup returns the new object. The `removedIds` mechanism does not address this case because a rename is not a removal.

The existing [mapper tests][mapper-tests] cover rename, swaps, deletion, and seeding, but not **rename A→B, then create a distinct A**. A snapshot of the broken bimap cannot represent both objects. This can contaminate migration, breakpoints, traces, and any client state keyed by stable ID.

**Recommendation:** allocate identity independently of location, with an explicit server-authoritative allocation/seed protocol. A local random/counter patch on both sides would introduce a different divergence. Decide whether identity must survive process restart; if yes, persist it rather than reconstructing it from names. Test object/document/folder rename followed by reuse, delete/recreate, snapshot/seed, and old trace resolution. This is a necessary repair even if live migration is later removed.

### F03 — Durable compilation cache ignores the compilation environment

**High priority; reproduced cache behavior; M.** [KotlinCode.signature][kotlin-code] includes class name and source digest. [CachedKotlinCompiler.tryCompile][compiler-cache] reuses `err.txt` or `success.txt` from that key. It includes no compiler version, plugin-universe fingerprint, or dependency ABI/content fingerprint. A process-stable parent loader explains in-memory reuse, but does not make persistent results valid across restarts and upgrades.

The probe writes an error through one compiler, constructs another cache instance over the same work root with a different compiler, and confirms the second compiler is never called. It is an isolated cache test, not a full plugin-upgrade reproduction. Consequences include a formerly missing plugin remaining a compilation error after installation, and potentially stale generated bytecode after dependency changes.

**Recommendation:** namespace durable results by a compilation-environment fingerprint, or invalidate the durable namespace on runtime/plugin changes. Stop promising indefinite compatibility for derived error-cache entries. Validate negative→valid compilation after plugin installation, same-source compilation after dependency changes, interrupted compilation, and concurrent requests. Preserve the existing interruption handling and per-signature locking.

### F04 — A failed settlement callback discards unrelated callbacks

**Medium priority; reproduced; S.** [RemoteApplyGate.drain][gate] copies and clears all callbacks before `forEach`. If the first throws, remaining callbacks are lost permanently. Because `ClientRestGraphStore.apply` calls `gate.end()` from `finally`, a callback failure can also make a successfully applied server mutation look like a failed write.

**Recommendation:** isolate subscriber failures and report them separately from the mutation result; run every queued subscriber. Prefer deleting this gate through F01 to making it a second asynchronous framework. Existing [gate tests][gate-tests] cover nested writes and reentrancy, but not subscriber exceptions. The probe compiles the platform-neutral implementation on JVM; browser-specific scheduling was not exercised.

### F05 — In-place project upgrade is exception-safe, not process-crash-safe

**High priority; source-established failure window; M repair / L redesign.** [ProjectCreator.swapUpgradeIntoPlace][project-creator] moves `main.jar` to `.old`, then moves dependencies, then installs replacements. Its catches handle an exception in the same process. A process exit between these operations leaves `main.jar` absent or jar/dependencies from different versions. A subsequent `upgrade` first requires `main.jar` to exist, so one interrupted state fails before recovery. [Upgrade tests][upgrade-tests] exercise success, locked files, and leftover backups, but their residue fixture starts with a valid main jar.

**Recommendation:** install complete immutable runtime directories and select one version through a small recoverable registry/pointer update. Keep user data outside those directories. If retaining the current layout, add a startup recovery state machine before preconditions and retain backups until recovery is decided. Test process termination after each filesystem transition. Do not describe a sequence of renames as a transaction merely because individual moves are atomic. The launcher and shell need not share identical installers, but they need the same recovery guarantees.

### F06 — JS bundling does not fully declare its inputs and outputs

**High priority; source-established and already documented; S–M.** The [auto][auto-js-build], [launcher][launcher-js-build], and [project][project-js-build] esbuild tasks declare the Kotlin output directory but omit the resolved npm tree/lock as an input. `dependsOn(kotlinNpmInstall)` orders tasks; it does not describe bundle content. All three request source maps while declaring only the `.js` output; production also requests external legal comments. Missing ancillary outputs therefore do not independently invalidate the task.

The [embedded frontend][embed-build] already includes `build/js/yarn.lock` as an input: a useful local precedent, although a lockfile alone does not cover arbitrary manual changes in `node_modules` or all tool/config changes.

**Recommendation:** one tested bundling convention declaring the resolved dependency identity, tool/config identity, mode, and all emitted artifacts. Prefer a generated directory output where appropriate. Validate npm-only change, deleted map/license file, dev↔production change, and dependency-module-only change. Do not keep `--rerun` as the permanent correctness mechanism. Gradle's [incremental-build documentation](https://docs.gradle.org/current/userguide/incremental_build.html) explains that up-to-date behavior depends on declared inputs and outputs.

### F07 — JVM arguments are split as whitespace, not arguments

**Medium priority; source-established; S–M.** [MainJarProcess.startProcess][main-process] uses `jvmArgs.trim().split(Regex("\\s+"))`. A value such as `-Dlabel="two words"` becomes two arguments with literal quote fragments. `ProcessBuilder` does not need shell quoting when given an argument list; introducing a shell would add complexity and risk.

**Recommendation:** store structured argument tokens, or parse the existing text with one explicitly defined quoting grammar at its boundary. Preserve backward compatibility by parsing existing plain strings. Test spaces in property values and paths, escaped quotes, and empty arguments. This was not launched against a user project.

## 4. Product and execution assumptions

### F08 — Transparent live migration has an unusually large semantic cost

**Highest strategic leverage; evidence high, preferred alternative a hypothesis; XL.** [RunEngine.migrate][engine] captures state, lifts resources, cancels/joins the old tree, rebuilds nodes, adopts captures and retired frames, filters removed identities, and preserves history. [ServerLogicController][logic-controller] adds transitive-digest tracking, recompilation, move-to self-migration, and fallback to the old definition. [JobRun][job-run] carries buffered channels and the ownership ledger. [CursorLending][cursor-lending] detaches live cursors and prefetched items. These are distinct manifestations of one product promise.

**Recommendation:** prototype immutable execution snapshots first for Job. Edit freely while a run executes; an explicit new run adopts the edits. Keep pause, cancellation, inspection, and bounded debug traces. Consider retaining live editing only for interactive Script if observed usage justifies it. Do not replace migration with silent replay of external side effects.

**What can disappear:** Job carryover, cursor detachment/adoption for edits, identity-based resource resurrection, and many pause/drain interactions. **Sacrifice:** correcting a running long computation without restarting. **Disproof experiment:** use a long expensive source and an interactive browser Script; measure lost work and whether restart/resume-at-durable-boundary is acceptable. If not, constrain migration to explicit resumable operators rather than every arbitrary resource.

An immediate UX issue remains regardless: `pendingMigration` logs a refused Job migration and resumes the prior definition; its comment explicitly says client surfacing is not built. Users need a visible distinction between **saved definition** and **running definition**. Tests should assert that distinction for a changed source selection and a compile failure.

### F09 — Four Logic flavours need not imply four complete runtime ecosystems

**High strategic leverage; hypothesis; XL.** [FlowRun][flow-run] executes its own vertex model; [ReportInputPipeline][report-pipeline] maintains a Disruptor-based pipeline and Report-specific input/output machinery; Job has Workers/channels; Script has sequential control. Sharing `Execution` is useful but does not eliminate parallel validators, editors, preview protocols, schemas, and migration adapters.

**Recommendation:** retain Script for imperative interaction and Job for streaming computation as the candidate core. Evaluate compiling the supported Report subset into Job, retaining Report as a view if useful. Evaluate lowering Flow's synchronous DAG to a constrained execution plan rather than another full runtime. Do not force all four into a base class: that preserves the semantic inventory and adds indirection.

**Gate:** characterize Report filters/formulas/grouping/export, Flow scheduling/state, error ordering, and preview behavior; compare representative large-data throughput and allocations. Remove a runtime only after parity or an explicit capability cut. The August Report→Job follow-up is relevant, but its existence is not proof that today's Job already covers Report.

### F10 — Task is a separate execution lane without a built-in product consumer

**High confidence candidate; M; breaking extension change.** The cross-repository search found framework wiring, serializers/UI, and `AdhocTask`/its notation example; no substantive built-in Task feature. This agrees with the current [architecture][auto-architecture]. It is therefore a real extension contract, not dead code.

**Recommendation:** retire Task from the default product, or require a named external consumer before continuing its maintenance. If a simpler background operation is needed, use a small explicit job API; do not automatically force a Task into the current one-active-Logic-run restriction.

An incidental source defect reinforces the cost: [ModelTaskRepository.documentDeleted/documentRenamed][task-repository] uses `find` and returns after the first terminated match, so active and additional terminated tasks for the same document can be skipped. `submit` allows multiple IDs, and `lookupActive` returns a set. If Task stays, test completed+active and multiple-active runs during rename/delete; repair all affected entries rather than one. If Task goes, delete its routes, DTOs, UI, repository, fixtures, and documentation together after checking external consumers.

### F11 — Borrowed streaming elements couple dataflow to global pause semantics

**High leverage; hypothesis; L–XL.** [BorrowingSource][borrowing] requires downstream Workers to keep draining while an element is lent, even when a pause is requested. [CursorLending][cursor-lending], [RunOwnershipLedger][ownership], channel holds, and [JobDeadlockMonitor][deadlock] coordinate when a source may advance. This is necessary under the current promise: arbitrary asynchronous consumers can retain objects backed by a mutable cursor.

**Recommendation:** offer a simpler default lane: pull-based/fused source-transform-sink segments, or independently owned values at asynchronous boundaries. Keep borrowed zero-copy delivery as an explicit specialized mode. Materialize once at the boundary where retention is required, subject to budget; do not copy every large native object indiscriminately.

**Sacrifice:** less unconstrained parallelism or additional copies/spill I/O. **Experiment:** archive entry→read→filter→writer, plus branching and an accumulator under a tight budget. Compare throughput, retained bytes, pause/cancel behavior, and number of ownership states. Preserve the current lease checks until the replacement demonstrates equivalent release behavior.

### F12 — Structural/native introspection is more general than many operators need

**Medium–high leverage; hypothesis; L.** [DataType][data-type] supports scalars, records with repeated field occurrences, mappings, listings, unions, opaque/dynamic values, and recursive references. [ValueAccess][value-access] exposes structural navigation and native access; `DefaultNativeTypeResolver` is an 802-line reflective adapter. This buys genuine lazy access and host-object integration. Replacing it with `Map<String, Any?>` would discard important contracts and can allocate per row.

**Recommendation:** make a small explicit set of supported boundary forms the normal authoring API: scalar/record rows, a stream, and an opaque native handle with declared adapters. Reserve deep bean/recursive inference for callers that request it. Keep the internal value algebra where operators actually need it; remove duplicate or inferred authoring paths only after counting real consumers.

**Gate:** preserve duplicate-column identity, absent vs null, lazy row projection, recursive/cyclic native cases that are genuinely used, Java plugin records, and snapshots of owned values. Measure cold schema inspection and hot row allocation. The existing unified `DataValue` carrier is an asset; another universal value wrapper would move complexity rather than remove it.

### F13 — Trace and schema retention need explicit bounds

**Medium–high priority; source-established growth, impact unmeasured; M.** [RunEngine][engine] stores an append-only `ArrayList<TraceEvent>`; `emit` can retain and `log` appends. No history eviction was found in that class. [RunEngineLogicTrace][trace] projects that history and resolves binaries from retained state; putting handles on the wire does not evict the original bytes. [SchemaCache][schema-cache] has an unbounded `ConcurrentHashMap`; entries are removed by explicit invalidation, not a capacity policy.

**Recommendation:** bound retained history and in-memory schema state explicitly. Let diagnostic history be a ring/window or spill artifact with a visible truncation marker. Keep current live state separate from historical retention. Limit schema memory independently of durable cache storage.

**Cost:** the full film strip may no longer be available forever. **Validation:** long screenshot/log loops, many changing file fingerprints, active-run inspection, eviction while queried, and clear/shutdown. Do not claim an observed OOM: this audit established growth paths, not a measured failure threshold. The compiler's existing bounded in-memory cache is counter-evidence to any blanket claim that all caches are unbounded.

## 5. Authoring, client, and extensibility

### F14 — The declarative object graph is also an application composition framework

**High strategic leverage; hypothesis; XL.** [ClientContext][client-context] constructs a local notation/metadata/definition stack, registers generated modules, seeds stable IDs, and builds a `GraphEnvironment` whose service registrations use fully qualified class-name strings. [KzenAutoContext][auto-context] does the server-side equivalent. An extension author can need a Kotlin/Java declaration, `@Reflect`, generated or reflective registration, notation metadata, a constructor-compatible attribute declaration, and a UI marker to make one feature available.

**Recommendation:** separate user document interpretation from application composition. Ordinary first-party screens and services should be assembled through explicit constructors/registrations. Keep a small feature descriptor registry for document types, editors, and plugin contributions. A workflow's typed intermediate representation can still be distinct from its syntax and runtime; abolishing all three layers would mix concerns.

**What can disappear:** graph construction and string-typed service binding for components that are never user-authored. **Sacrifice:** arbitrary UI/service composition through notation. **Experiment:** implement one existing editor contribution through an explicit descriptor, including a sample plugin display; compare files touched, registration failures, and customization actually lost. Do not merely wrap the current graph in a second registry.

### F15 — The client repeatedly copies authoritative state through observer layers

**High leverage; hypothesis with concrete maintenance evidence; L.** [ClientStateGlobal][client-state] combines graph, navigation, and run state, then manually scopes observer delivery to avoid deleted/renamed objects. [ReportStore][report-store] owns sub-stores and copies global values into another state. [FileSelectionEditor][file-editor] implements five observer interfaces and carries local selection drafts, listing state, format/resolution state, request epochs, mount guards, and derived presentation state. Its size is not the problem; the number of independently maintained state relationships is.

**Recommendation:** one immutable committed document snapshot plus narrowly owned asynchronous query state and local drafts. Derive render values rather than copying them into several mutable owners. Pilot function components and one subscription adapter in a complete subtree. React's [useSyncExternalStore](https://react.dev/reference/react/useSyncExternalStore) already defines subscription, cleanup, and snapshot reading for an external store; it is a candidate seam, not proof that every existing observer can be mechanically replaced.

**Gate:** rapid switching/rename/delete, late responses, unmount during commit, failed writes, and render counts on a large document. Delete the superseded store/observer layer in the pilot. A hook wrapping the same five observers with the same duplicated state is not a simplification. Preserve the August mount-race fixes until replacement behavior is tested.

### F16 — Reconsider the Kotlin/JS boundary after reducing shared execution

**Potentially high leverage; lower-confidence hypothesis; XL.** The current client runs graph semantics locally, so sharing Kotlin models/reducers has real value. It also requires KMP variants, KSP registrations, kotlin-wrappers coordination, [React compatibility shims][react-wrap], custom context/ref bridges, and build workarounds. The launcher pays much of this tooling cost for a small registry UI.

**Recommendation:** do not start with a frontend rewrite. First validate F01/F14/F15. If the client can become a renderer of typed server projections plus local drafts, compare that thin Kotlin/JS client with a small TypeScript implementation of one self-contained screen. Prefer the thinner existing client unless the alternative demonstrably removes more maintenance than migration adds.

**Sacrifice:** shared Kotlin implementation and existing Kotlin-based UI extension authoring. **Gate:** equivalent extension registration, payload typing, build/dev loop, browser interactions, and measured code/dependency surface. These alternatives are mutually exclusive for the chosen subtree; retaining two permanent frontend frameworks defeats the exercise.

### F17 — The custom YAML dialect is both persistence and a language product

**Medium–high leverage; hypothesis; L–XL.** [YamlParser][yaml-parser] is 1,117 lines, but size alone is not a finding. The [documented dialect][lib-architecture] has nonstandard bare-colon behavior, legacy quoting tolerance, inheritance, and format-preserving emission that still drops comments inside changed objects. Metadata adds another set of rules: attribute metadata replacement differs from type-reference metadata merging, and ordinary scalar absence is not the same as nullable references.

**Recommendation:** decide the authoring promise. If users hand-edit YAML, invest in a well-defined supported subset, parse diagnostics, and lossless edits or explicit formatting behavior. If the UI is authoritative, use a simpler canonical document representation with import/export at the edge. Separately consider flattening archetype inheritance at load/import time and replacing unrestricted multiple inheritance with explicit composition.

**Sacrifice:** some inherited/custom raw notation and formatting behavior. **Experiment:** round-trip real documents containing Windows paths, colons, quoted strings, comments, duplicate field names, and archetype overrides. Test semantic equivalence and review the textual diff. Never swap in a generic YAML parser and assume the language is unchanged; distinguish persistent documents from disposable caches.

### F18 — Full Kotlin expressions and the custom editor are optional product costs

**Medium–high leverage; hypothesis; L–XL.** [KotlinCode][kotlin-code], [CachedKotlinCompiler][compiler-cache], runtime loader integration, type inference, validation, and the custom `KotlinCodeArea` serve a full-language expression experience. The [JS architecture][js-architecture] documents substantial caret, selection, painting, completion, and wrapper behavior. This is much more than evaluating a formula.

**Recommendation:** keep full Kotlin for expert/extension use, but test whether common transformations can use a smaller explicit operator/field-expression surface and a simpler editor. Alternatively retain Kotlin but compare the custom editor with a maintained editor component in a bounded spike. Do not add a new expression language while permanently keeping every old authoring path unless users need both.

**Gate:** representative formulas, host-object access, diagnostics, rename behavior, cold compile latency, completion, paste, multiline selection, and accessibility/IME interaction. No claim is made that a regex parser or tiny evaluator can replace Kotlin semantics. The compiler can remain valuable even if most users no longer encounter it.

### F19 — Startup-pinned plugins may not need a process-global extension universe

**High leverage; hypothesis; L–XL.** [KzenAutoRuntime][runtime] pins one normalized configuration, registers mirrors globally, aggregates folder class loaders, and supplies compiler classpaths. It has no unload/reset; different plugin roots require another process. Discovery, contribution, ambiguity/shadowing diagnostics, availability, and the compatibility kit maintain this contract. The value of scopes is real, but hot reload is not a justification for this particular design because it is not offered.

**Recommendation:** compare two smaller, mutually exclusive directions: (a) one explicitly assembled application classpath per deployment, rejecting duplicates at startup; (b) an explicitly owned runtime/registry passed into contexts, with no global mirror mutation. Choose (a) if independently installed conflicting plugin dependencies are unnecessary; choose (b) if hosts need genuinely separate extension universes. Do not implement both as another matrix of modes.

**Sacrifice/tradeoff:** (a) loses folder-level loader separation and some coexistence; (b) adds explicit ownership/parameters and needs a real close contract. **Gate:** Java/Kotlin plugin identity, expression compilation identity, missing services, duplicate classes, two host contexts, shutdown, and a conflicting dependency fixture. Keep per-scope diagnostics if scopes remain; deleting their checks while keeping ambiguous loading is not simplification.

### F20 — The public SPI boundary leaks into the server implementation

**High confidence; M–L.** [kzen-auto-plugin's build][plugin-build] exposes `kzen-auto-common` and `kzen-lib-common-jvm`. The [sample adapter POM][adapter-pom] also needs `kzen-auto-jvm` at provided scope with all transitives excluded for Java Worker bases. Thus “compile against the SPI only” is not the actual Worker authoring contract. The [KSP processor][ksp] handles Kotlin classes while Java relies on a reflective route with annotation/constructor/parameter-name requirements.

**Recommendation:** define one supported authoring surface for readers/Workers and their data/lifecycle contracts. Put the author-facing bases behind that surface without pulling the server's internals into a plugin build. Prefer relocating/consolidating existing contracts over adding facade wrappers around every implementation. Consider explicit Java factories where reflection contributes only restrictions.

**Gate:** build the two real samples using only the advertised public dependencies, including a reader, a host-service-consuming Worker, and an output type. Inspect the published compile/runtime graph and ensure host classes have one identity. Do not repeat the old idea that the SPI can be dependency-free while simultaneously exposing the current Kzen value contract.

### F21 — File authoring risks exposing each internal resolution stage as a user concept

**Provisional; active work; M–L.** [FileSelectionEditor][file-editor], `FileResolutionStore`, `DataFormatStore`, schema/shape stores, configured format objects, and [FileDataSource][file-source] collaborate on selecting and reading files. The user-visible distinctions can grow to include files, units, parts, entries, emitted items, formats, and inspection policy. Some distinctions represent real lifetimes; others may be intermediate planning artifacts.

**Recommendation:** judge the complete workflow against a small vocabulary: select a source, choose how it is read, see its output shape. Keep source identity separate from its interpreted contents, but avoid separate user concepts for two handles with identical operations/lifetimes. Prefer explicit behavior where downstream-dependent “auto” choices would make rewiring silently change what a source emits.

The ongoing [files-and-items analysis][file-analysis] already challenges these assumptions. Do not duplicate its work or classify partially written `WholeFileFormat`/archive paths as finished defects. Re-audit after that change lands using plain files, selected archives, nested entries, whole-file values, ambiguous detection, overrides, schema preview, and downstream rewiring. Record which concepts users actually have to learn.

### F22 — Control flow encoded in error prose creates avoidable coupling

**High confidence; M.** [LogicConventions.isMissingError][logic-conventions] reconstructs strings to distinguish a gone run from other failures. Its comments explain why it cannot safely treat the engine's missing-request-handler text as equivalent. `ExecutionFailure` has no code for this distinction. Trace queries also route through a detached action with action-name/parameter conventions rather than a dedicated typed trace interface.

**Recommendation:** add a small machine-readable error classification where clients branch on failure, keeping the human message separate. Consolidate repetitive command transport around typed requests only after the authoritative-edit decision; do not replace readable endpoints with an untyped universal RPC bag. Review GET mutation routes as part of that transport change, preserving the existing security gates and explicit mutation intent.

**Gate:** vanished run vs absent handler, validation failure vs infrastructure failure, malformed requests, and older clients. Do not reopen the August dual-codec “migration tail” finding: JSON wire DTOs and execution value trees have different purposes, and the earlier report explicitly corrected that claim.

## 6. Deployment, build, and verification costs

### F23 — Separate launcher, shell, and project processes should earn their independence

**High strategic leverage; hypothesis; XL.** [KzenShellContext][shell-context] downloads and spawns a launcher, owns a proxy client, and coordinates project processes. [MainJarProcess][main-process] manages readiness and lifelines. The launcher's registry and installer manage a second application layer. The [shell guide][shell-guide] explicitly justifies the split as an independently updateable stable kernel; the coordinated release train is counter-evidence to assuming that independence is exercised in practice.

**Recommendation:** prototype one desktop control-plane application serving project selection and workspace UIs, using the existing per-context hosting seam. Keep process isolation for projects that need it, rather than mandating a separate launcher JVM. The more radical option is one process with several contexts, accepting shared failure and plugin-universe boundaries. These are alternatives, not two additional default launch modes.

**Sacrifice:** independent launcher replacement without replacing the control plane; one-process workspaces lose crash/heap/dependency isolation. **Gate:** offline startup, upgrades, two workspaces, long SSE/downloads, failed startup, hard parent exit, and one misbehaving project. If independent launcher releases are actually required, retain the split and document that release contract; a smaller process count is not worth losing a used guarantee.

### F24 — User projects carry copies of a runtime that could be selected by version

**High leverage; source-established duplication, alternative a hypothesis; L–XL.** [ProjectCreator][project-creator] puts `main.jar` and `dependencies/` inside each project and swaps them during upgrade. [kzen-project][project-guide] has only five main Kotlin files, largely entry points and extension examples, but pays for three source modules, KSP generation, packaging, and a separate development loop.

**Recommendation:** separate three things: user workspace data, immutable application runtime versions, and optional compiled extensions. A project registry can select a runtime version and data directory. The default project need not be a separately rebuilt copy of the application. Retain kzen-project as a clearly named extension template if that is its main remaining purpose.

**What can disappear:** repeated dependency payloads per project and much of in-place upgrade/rollback. **Sacrifice:** the current self-contained project-directory distribution contract. **Gate:** portable export/import, version selection, offline operation, custom extensions, rollback after failed boot, and data preservation. Combine this with F05; do not build a more elaborate mutable updater immediately before changing the layout.

### F25 — One release train is paying for several independent source builds

**High confidence structural cost; L.** The [umbrella settings][settings] includes eight sibling builds; first-party KMP consumers combine root and variant-suffix coordinates. The [auto common build][auto-common-build] is a concrete example. The guides document Maven Local refresh order, task-addressing traps, IDE Provided-scope behavior, and NPM coordination problems. These are operational complexity caused by boundaries, not Kotlin source requirements.

**Recommendation:** one first-party multi-project source build, ideally in one repository, with normal project dependencies and centralized release metadata. Keep a separately built Maven sample to verify the actual publication contract. Repository consolidation and build consolidation are separable; choose the build simplification first if moving history is disruptive.

**Sacrifice:** independent checkout/build/release of first-party siblings in their current form. **Gate:** fresh checkout, no pre-populated Maven Local, CLI builds, KSP, browser bundle, publication consumed externally, and IntelliJ run/debug. Do not add the explicitly problematic composite includes/substitutions as a shortcut. Until consolidation, add an honest verification entry point that invokes each sibling's real checks and fails if it only executes a dependency report.

### F26 — Repeated build policy and mirror conventions are manually synchronized infrastructure

**High confidence; M, partly dependent on F25.** The three production esbuild task bodies share OS/architecture selection and bundling policy. Kotlin/KSP/JVM/wrapper pins are repeated across first-party builds and the [embedded frontend][embed-build]. The [release procedure][releasing] requires coordinated edits, local publication, packaging, and artifact-mirror updates. [kzen-repo's README][mirror-readme] says only “artifact repository”; it does not establish a useful provenance/update contract for maintained forks.

**Recommendation:** one build convention for repeated task behavior, one release manifest for versions/artifact coordinates, and an explicit external-consumer verification step. Record each mirrored fork's upstream, patch reason, rebuild recipe, and retirement condition. Prefer removing a no-longer-needed fork to automating its indefinite upkeep; no fork is declared unnecessary by this audit.

**Gate:** the same convention must build auto, launcher, project, and the composed sample frontend with their intended differences. Model the JVM roles accurately, including the KSP processor's older bytecode target. Do not lower the runtime baseline casually: the sample analytical core uses modern native-memory facilities. No toolchain/version changes are part of this audit.

### F27 — Passing the convenient test command is not the same as release acceptance

**High confidence; M.** The umbrella's build task behavior is misleading by documented design; `pluginUniverseTest` is separate from ordinary JVM tests; browser self-tests are opt-in. The [sample adapter integration test][plugin-it] uses assumptions to skip when host jars are absent. A successful build can therefore omit the very integration boundary it appears to validate. The auto client has roughly 63k main lines and 2.5k test lines in the inventory; that is a test investment signal, not a coverage percentage.

**Recommendation:** one documented release-verification command with explicit suite results and no silent skip for required integration prerequisites. Keep the fast default development loop. Classify required, optional, and environment-dependent checks in executable configuration; a release run should fail if a required suite did not execute.

Use external browser automation for broad UI acceptance where it is simpler; retain a small self-hosted suite specifically to prove Kzen's own automation feature. Dogfooding every UI test couples diagnosis to two Kzen servers and the same execution engine. Before replacing the harness, compare one rename/edit/rejected-save scenario including setup and failure reporting. Do not bind visible Chrome startup to every local `build`.

### F28 — The examples demonstrate too much at once

**High confidence educational cost; M.** [kzen-sample-plugin][sample-readme] contains a substantial plain-Java analytical core, native memory, persistent order-book history, a derived store, readers, Workers, and benchmarks. The [Spring sample][embed-guide] adds catalog download/preparation, a host budget, reports, a Kotlin/JS frontend, and multiple workspaces. These are useful acceptance fixtures; they are a large first encounter with plugin/embedding APIs.

**Recommendation:** retain the market-data example as an advanced acceptance/benchmark project and provide one small canonical getting-started path using the existing world-cities reader and one simple host service. Avoid introducing another long-lived copy of the core. A new author should be able to identify the exact files required for one reader, one Worker, and one embedded workspace without understanding ITCH.

**Gate:** build the minimal path from published artifacts outside the composite and enumerate every required file. The core's separation from Kzen is good design and should remain. Reducing the tutorial surface is not an argument to remove the production-scale proof.

### F29 — Embedded HTTP is an adapter choice, not necessarily the core hosting API

**Medium leverage; hypothesis; L.** [KzenWorkspace][workspace] boots a loopback Ktor server per workspace. [KzenProxyController][embed-proxy] streams servlet requests to it and must manage headers, cancellation, flush behavior, and lifecycle. This reuses the browser API and preserves host independence, but “in-process” still includes an HTTP hop and a port per workspace.

**Recommendation:** keep the transport-neutral workspace/controller API as the ownership center. Evaluate mounting several workspace routes under one Ktor server where the host can do that; for a foreign servlet host, compare the existing proxy with a narrowly scoped adapter before promising a transport rewrite. Do not duplicate all routes directly in Spring just to remove sockets.

**Tradeoff:** removing the proxy may couple Kzen more tightly to the host web stack. **Gate:** concurrent workspaces, request cancellation, long-lived SSE, compression, host shutdown, unavailable workspace, and independent workspace stop. The existing packaged integration tests are valuable acceptance cases for this experiment.

## 7. Comments, documentation, and working conventions

### F30 — Explanatory history has regrown into the code

**High confidence; S per cluster.** Examples include `SER3`/`SER2` phase narration in the [JS][auto-js-build] and [common][auto-common-build] build scripts; commented imports in [ClientContext][client-context]; `E9 item` annotations and retired implementation comparisons in [JobRun][job-run]/[RunOwnershipLedger][ownership]; and historical formulations in [ReportStore][report-store]. FileSelectionEditor's class comment describes a rejected modal design. These require the reader to reconstruct a conversation or former implementation.

**Recommendation:** keep invariant/contract comments and short pointers to one canonical explanation; delete history narration and commented-out code in an explicitly scoped cleanup. Do not cut by comment ratio: ownership, cancellation, native memory, proxy streaming, and plugin contracts need precise explanations. Repeated descriptions of today's implementation should become identifiers/tests or one owning document, not several slightly different essays.

**Gate:** a reader of only current code can explain the invariant without following a deleted plan. Compare before/after for information loss, not just line count. This is a recurrence of an August finding, not evidence that the August cleanup never happened.

### F31 — Current instructions contain concrete contradictions and stale boundaries

**High confidence; S–M.** Verified examples:

| Document claim | Current evidence | Needed correction |
|---|---|---|
| Umbrella says `useCommonJs()` must remain across frontends | [auto JS][auto-js-build] and [embedded frontend][embed-build] use ES modules; project/launcher still have different wiring | Document the actual per-build boundary and icon dependency rationale |
| kzen-project says dynamic plugin-JAR module registration is pending | [KzenAutoRuntime.registerMirrors][runtime] and contribution discovery support scope-owned generated registrations | Describe what is shipped and distinguish server plugin registration from dynamic browser extension loading |
| Several guides call distribution jars “fat” | [release layout][releasing] and Gradle packaging use thin jars plus `dependencies/` | Use one canonical packaging term |
| auto-test prerequisite says JDK 26 toolchain | Authoritative [Dependencies.kt][auto-dependencies] says 25 | Separate Gradle JVM, compile/runtime baseline, and processor target |
| Master ledger has an `XC ... NOT complete` heading and defect text while its nearby record says the rows are done | [master ledger][master-plan] | Make current status unambiguous; retain history in as-built sections |
| Project upgrade is described as crash-safe | F05's multi-step replacement and missing-main precondition | Narrow the guarantee or implement recovery |

These matter because agents and developers follow guides as constraints. Stale “must stay” and “not available” statements prevent simplification or send work in the wrong direction. Fix current operational truth before adding more explanatory prose. Historical audit snapshots should stay historically accurate rather than being silently rewritten.

### F32 — Some coding rules can manufacture indirection when applied mechanically

**Policy hypothesis; M discussion, not a mass rewrite.** [Coding standards][standards] require small packages, generally one top-level class per file, generic capability-based dispatch, and marked deliberate duplication. Each has a useful aim. Applied as universal shape constraints, they can create one-method interfaces, tiny carrier packages, registry layers for a closed local set, and boilerplate whose primary behavior is satisfying the rule.

**Recommendation:** judge changes by the number of concepts, invariants, and places touched by a user-visible change. Permit small cohesive sealed families/carriers together. Require open extension dispatch at actual public plugin seams, not automatically inside every private closed implementation. Keep deliberate small duplication when extracting a common module would add coupling; reconsider the boundary itself when the duplicated unit is an installer or protocol.

**Gate:** take three real maintenance tasks and compare navigation/edit/test surface under the proposed rule exceptions. Never replace open plugin registration with hard-coded built-in names: that would break an actual product capability. No existing standard was overridden to modify application source in this audit.

### F33 — Plans and audits are becoming a second implementation to maintain

**High confidence maintenance pattern; M.** The [master ledger][master-plan], architecture prose, sibling guides, audit remediation records, and constituent plans often repeat status, invariants, and gotchas. The August audit's corrections demonstrate that an older confident claim can outlive its evidence. Recent ownership comments cite session/plan labels that are not useful API vocabulary.

**Recommendation:** one current contract per subsystem, one short operational guide per build, and a ledger containing status plus links. Preserve as-built decision records as history, but avoid copying their narrative into current code and guides. Every deferred item should name its reopening condition and owner/surface; every accepted complexity should name the user capability it buys.

**Gate:** select an invariant (for example cursor ownership or plugin initialization), find every statement of it, and ensure only one owns its full definition. Do not delete the constituent plans or user working documents; reduce repeated current claims through an explicit documentation task.

## 8. Complexity that currently earns its cost

This audit does not recommend deleting the following merely because they are intricate:

- **Memory admission and deterministic native release.** [HS25's recorded real-day proof][hs25] covers 268,744,780 messages and a 4 GiB shared budget, including blocked admission and eventual release. Those are historical measurements, not rerun here. They justify [MaterializationBudget][budget] and [WeightedBudget][weighted-budget]. F11 targets propagation complexity and the default execution model, not the existence of a budget.
- **The plain-Java analytical core boundary.** Its [Maven enforcer][core-pom] keeps Kzen/Kotlin out. Domain logic remains useful outside the framework; that is a substantive simplification.
- **Separate syntax, validated representation, and runtime state.** These answer different questions. F14 narrows where graph interpretation is used; it does not propose erasing type checking or instantiating invalid documents.
- **Open registration at real plugin boundaries.** Capability discovery and explicit diagnostics prevent silent exclusion of contributed behavior. A switch over built-in names would be shorter but wrong for that contract.
- **Atomic file replacement, work-root claims, cancellation/join ordering, and lifelines.** They protect real data and process ownership. Reduce them by removing a lifecycle boundary, not by deleting checks while retaining the boundary.
- **A single owner/lock for engine state and structured child lifetimes.** Splitting the engine into several independently locked services could increase complexity. First decide which semantics remain.
- **Lazy value access and bounded snapshots.** They avoid copying large/native values and distinguish absent/null/opaque cases. Full deep conversion at every hop is not automatically simpler in operation.
- **Existing specialized parsers, numeric routines, and template matching.** File length and loops are not evidence of excess. `FastDoubleMath` is not a candidate for a readability rewrite based on size; [TemplateMatcher][matcher] has explicit tradeoffs and tests. Benchmark a simpler alternative before removal.
- **The separate wire and execution-value representations.** The previous audit corrected its own claim that these were an unfinished serialization migration. Do not repeat that false positive.

## 9. Recommended smaller target and sequence

### Candidate target

One first-party source build produces a versioned runtime. A workspace is data plus a runtime/extension selection. The desktop control plane selects workspaces and optionally isolates execution in a child process. The server owns committed document revisions; clients render typed projections with local drafts. User workflows compile into an immutable execution plan. Script and streaming Job remain distinct where their semantics differ; other views lower into those plans where useful. Native resources cross explicit bounded ownership boundaries. Plugins contribute through a small authoring contract and an explicit deployment/runtime policy.

This is a candidate architecture, not a declaration that all current features fit it. F08, F09, F14, F16, F19, and F23 contain the capability cuts and disproof gates. In particular, a whole-client TypeScript rewrite, a full in-process desktop, and classpath-only plugins are **not prerequisites** for the smaller initial target.

### Order of work

| Order | Work | Why this order / acceptance |
|---|---|---|
| 1 | Repair F02 identity collision, F03 cache namespace, F04 callback isolation, F06 bundle inputs, F07 argument handling | Local correctness changes; regression cases below; no product redesign needed |
| 2 | Repair F01 failed-write reconciliation and F05 upgrade recovery; visibly distinguish saved/running definitions | Protect user state before larger simplification |
| 3 | Ratify Task retirement and immutable Job runs; characterize Report/Flow parity | Removes semantics that would otherwise be refactored twice |
| 4 | Pilot acknowledged server edits and one simplified client subtree | Determines how much KMP/client graph machinery is still necessary |
| 5 | Consolidate first-party build policy/build graph and runtime/data layout | Eliminates ongoing release/dev friction; validate external consumer separately |
| 6 | Evaluate execution lowering, explicit plugin runtime, restricted borrowed lane, and smaller authoring surface | Evidence-driven larger changes; one replacement per boundary |
| Continuous | Bound retention, repair current docs, shorten historical comments, improve required-suite reporting | Bounded tasks with direct operational value |

Do not count moving code into more files, adding a common base, or wrapping an existing abstraction as a complexity reduction by itself. For every accepted simplification, name the deleted state machine, contract, deployment mode, or synchronization obligation. Reject a proposal whose only measurable result is another permanent adapter layer.

## 10. Verification evidence and follow-up tests

### Executed probes

[Invoke-SimplicityProbes.ps1](script/Invoke-SimplicityProbes.ps1) compiles the audited mapper, mirror, settlement gate, compiler cache, and cache-key source from the **current checkout**. Supporting types come from existing kzen-lib/kzen-auto build jars. It neither launches the application nor edits a sibling repository. This is stronger than testing only stale compiled subjects, but it is not a clean source build of every dependency.

Executed with the installed Temurin 25.0.4.1:

```powershell
./docs/audit/script/Invoke-SimplicityProbes.ps1 -JavaHome C:/Users/ostro/.jdks/temurin-25.0.4.1
```

Observed output:

```text
IDENTITY: distinct objects share id=true; renamed reverse lookup correct=false
MIRROR: returned error=true; rejected document remains local=true
GATE: callback error escaped=true; second callback ever ran=false
COMPILER CACHE: new compiler called=false; old error reused=true
```

The script is diagnostic: success means the probe ran, not that these behaviors are correct. It prints observations and does not encode the defects as desirable regression expectations. It uses session-owned scratch files under `docs/audit/raw/` and removes them in `finally`. No raw measurements or parsed TSV are retained.

### Acceptance cases for repairs

| Finding | Required regression behavior |
|---|---|
| F01 | Rejected/uncertain write cannot silently become accepted local state; preserve the draft or show recovery; order rapid edits; detect revision conflicts |
| F02 | Rename then reuse at object/document/folder level yields distinct IDs; reverse lookup and snapshot/seed remain bijective; no trace/breakpoint transfer to a new object |
| F03 | Same source under a changed compiler/plugin environment recompiles, including negative-cache entries; unchanged environment retains cache benefits |
| F04 | All settlement subscribers are attempted; subscriber exceptions cannot masquerade as transport/commit failure |
| F05 | Terminate after each rename/install step and restart; a complete old or new runtime is recoverable, user data unchanged |
| F06 | npm-only/config/mode changes rebuild; deleting any declared generated artifact repairs it; correct bundle enters the JVM distribution |
| F07 | Whitespace/quotes/empty arguments round-trip to the child JVM as intended |
| F10 | If retained, deleting/renaming a document handles every active and completed Task for it |
| F13 | Long history and many schema fingerprints stay within explicit budgets; truncation/eviction is visible and does not corrupt live state |
| F27 | Required suite omitted or skipped makes release verification fail with its name |

No full Gradle/Maven builds, browser suite, clean-machine publication test, upgrade crash injection, or new performance benchmark were run. Application behavior was not modified, and such runs would not validate the unimplemented architectural alternatives. Source/link checks and isolated probes support the stated findings; the tables above define the remaining proof obligations.

### Revalidation of the August audit

The [2026-08-16 report][august-audit] is a historical baseline, not an outstanding issue list. This audit read its corrections and remediation sections. Examples checked against current source:

- `DataRecordBuffer.setFrame` now clears the opposite representation length; do not re-file the older latent defect.
- `LogicConventions.isMissingError` now deliberately handles only missing/replaced runs; F22 concerns the remaining message-based contract, not the removed stale branch.
- `RunEngine` has the logged closer helper; do not re-file all old silent closer catches.
- Schema/format consumption and plugin loading changed substantially since August; do not call DataFormat inert or assume the old Report-plugin mechanism is current.
- Mount guards and expanded tests exist; UI verification remains a concern, but the old “effectively untested” count and unguarded-site inventory are stale.
- Deliberate architecture is reopened because this audit explicitly questions product assumptions. That is different from reporting a deliberate design as an accidental bug.

## Evidence index

Links identify current source files and the symbols discussed above; line numbers are intentionally omitted because active work moves them.

[mirror]: ../../../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/store/MirroredGraphStore.kt
[mapper]: ../../../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/store/normal/ObjectStableMapper.kt
[mapper-tests]: ../../../kzen-lib/kzen-lib-common/src/commonTest/kotlin/tech/kzen/lib/common/service/store/normal/ObjectStableMapperTest.kt
[kotlin-code]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/compile/KotlinCode.kt
[compiler-cache]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/compile/CachedKotlinCompiler.kt
[gate]: ../../../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/rest/RemoteApplyGate.kt
[gate-tests]: ../../../kzen-auto/kzen-auto-js/src/jsTest/kotlin/tech/kzen/auto/client/service/rest/RemoteApplyGateTest.kt
[project-controller]: ../../../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/ProjectController.kt
[project-creator]: ../../../kzen-launcher/kzen-launcher-jvm/src/main/kotlin/tech/kzen/launcher/server/project/ProjectCreator.kt
[upgrade-tests]: ../../../kzen-launcher/kzen-launcher-jvm/src/test/kotlin/tech/kzen/launcher/server/project/ProjectCreatorUpgradeTest.kt
[auto-js-build]: ../../../kzen-auto/kzen-auto-js/build.gradle.kts
[launcher-js-build]: ../../../kzen-launcher/kzen-launcher-js/build.gradle.kts
[project-js-build]: ../../../kzen-project/kzen-project-js/build.gradle.kts
[embed-build]: ../../../kzen-sample-embed-spring/frontend/build.gradle.kts
[main-process]: ../../../kzen-shell/src/main/kotlin/tech/kzen/shell/process/MainJarProcess.kt
[engine]: ../../../kzen-lib/kzen-lib-jvm/src/main/kotlin/tech/kzen/lib/server/exec/engine/RunEngine.kt
[logic-controller]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/impl/ServerLogicController.kt
[job-run]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/job/JobRun.kt
[cursor-lending]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/CursorLending.kt
[flow-run]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/flow/FlowRun.kt
[report-pipeline]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/report/exec/ReportInputPipeline.kt
[auto-architecture]: ../../../kzen-auto/docs/architecture.md
[task-repository]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/exec/ModelTaskRepository.kt
[borrowing]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/BorrowingSource.kt
[ownership]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/job/ownership/RunOwnershipLedger.kt
[deadlock]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/job/JobDeadlockMonitor.kt
[data-type]: ../../../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/exec/data/type/DataType.kt
[value-access]: ../../../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/exec/data/value/ValueAccess.kt
[trace]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/RunEngineLogicTrace.kt
[schema-cache]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/data/SchemaCache.kt
[client-context]: ../../../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/ClientContext.kt
[auto-context]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/context/KzenAutoContext.kt
[client-state]: ../../../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/global/ClientStateGlobal.kt
[report-store]: ../../../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/report/model/ReportStore.kt
[file-editor]: ../../../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/job/edit/FileSelectionEditor.kt
[react-wrap]: ../../../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/wrap/React.kt
[yaml-parser]: ../../../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/util/yaml/YamlParser.kt
[lib-architecture]: ../../../kzen-lib/docs/architecture.md
[js-architecture]: ../../../kzen-auto/docs/js-architecture.md
[runtime]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/context/runtime/KzenAutoRuntime.kt
[plugin-build]: ../../../kzen-auto/kzen-auto-plugin/build.gradle.kts
[adapter-pom]: ../../../kzen-sample-plugin/kzen-sample-adapter/pom.xml
[ksp]: ../../../kzen-lib/kzen-lib-reflect-ksp/src/main/kotlin/tech/kzen/lib/reflect/ksp/ReflectSymbolProcessor.kt
[file-source]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/datasource/FileDataSource.kt
[file-analysis]: ../analysis/2026-09-18_job-files-and-items.md
[logic-conventions]: ../../../kzen-auto/kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/logic/LogicConventions.kt
[shell-context]: ../../../kzen-shell/src/main/kotlin/tech/kzen/shell/context/KzenShellContext.kt
[shell-guide]: ../../../kzen-shell/AGENTS.md
[project-guide]: ../../../kzen-project/AGENTS.md
[settings]: ../../settings.gradle.kts
[auto-common-build]: ../../../kzen-auto/kzen-auto-common/build.gradle.kts
[releasing]: ../RELEASING.md
[mirror-readme]: ../../../kzen-repo/README.md
[plugin-it]: ../../../kzen-sample-plugin/kzen-sample-adapter/src/test/java/tech/kzen/sample/plugin/PluginDirectoryIT.java
[sample-readme]: ../../../kzen-sample-plugin/README.md
[embed-guide]: ../../../kzen-sample-embed-spring/AGENTS.md
[workspace]: ../../../kzen-sample-embed-spring/src/main/java/tech/kzen/sample/embed/workspace/KzenWorkspace.java
[embed-proxy]: ../../../kzen-sample-embed-spring/src/main/java/tech/kzen/sample/embed/proxy/KzenProxyController.java
[auto-dependencies]: ../../../kzen-auto/buildSrc/src/main/kotlin/Dependencies.kt
[master-plan]: ../plans/2026-07-25_master-plan.md
[standards]: ../CODING_STANDARDS.md
[hs25]: ../plans/in-process-hosting/25-integrated-acceptance-and-docs.md
[budget]: ../../../kzen-sample-plugin/kzen-sample-core/src/main/java/tech/kzen/sample/itch/day/MaterializationBudget.java
[weighted-budget]: ../../../kzen-sample-embed-spring/src/main/java/tech/kzen/sample/embed/host/WeightedBudget.java
[core-pom]: ../../../kzen-sample-plugin/kzen-sample-core/pom.xml
[matcher]: ../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/vision/TemplateMatcher.kt
[august-audit]: 2026-08-16_complexity_fable-high.md
