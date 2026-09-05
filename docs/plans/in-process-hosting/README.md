# In-process hosting — constituent session plan

> Status: planned 2026-09-04; no implementation session has run.
> Design: [hosting analysis](../../analysis/2026-09-03_in-process-hosting.md).
> Existing generic contracts: [extensibility plan](../2026-07-25_extensibility-improvements.md).
> The [master ledger](../2026-07-25_master-plan.md) owns sequencing across arcs.
> Each numbered file owns one session's implementation and proof.

## Goal and authority

Deliver three independently tested outcomes: isolated kzen contexts in one JVM, ergonomic access to
live host objects, and a third-party jar set contributing code/notation without kzen source edits.
The substantive Java sample stores symbol message data off-heap and uses persistent heap structures
for book history and order lifecycles; Spring adds hosting and shared memory governance.

The hosting analysis owns this design, including its §5.2.1 memory/lifetime/leak-detection contract.
The E plan remains authoritative for E2/E3/E7/E8/E9; the sessions here elaborate that work, not a second
implementation of it. All acceptance criteria in those E phases still apply. E4 is outside this arc.
The analysis's old seven-step candidate outline is superseded by this tracker.

## Tracker

| ID | Session | Status |
|---|---|---|
| HS01 | [Java 25 baseline and local publication](01-java-25-baseline.md) | ☐ |
| HS02 | [Plain-jar Spring compatibility gates](02-spring-compatibility-spike.md) | ☐ |
| HS03 | [Plain Java core, ITCH reader and synthetic oracle](03-java-core-and-itch-reader.md) | ☐ |
| HS04 | [Persistent locate-partitioned derived store](04-locate-partitioned-store.md) | ☐ |
| HS05 | [Off-heap SymbolDay and persistent analytical graph](05-symbol-day-and-leak-detection.md) | ☐ |
| HS06 | [Early real-day storage and memory gate](06-early-memory-measurement.md) | ☐ |
| HS07 | [Process-global runtime and plugin scopes](07-runtime-and-plugin-scopes.md) | ☐ |
| HS08 | [Provider descriptors and exact-origin notation](08-provider-and-notation-discovery.md) | ☐ |
| HS09 | [Aggregate class loading, expressions and contextual availability](09-plugin-compilation-and-availability.md) | ☐ |
| HS10 | [Context-owned work roots, host services and shutdown](10-context-roots-and-host-services.md) | ☐ |
| HS11 | [Java-friendly reader and cursor-source adapters](11-java-blocking-adapters.md) | ☐ |
| HS12 | [Plugin diagnostics and compatibility test kit](12-plugin-diagnostics-and-test-kit.md) | ☐ |
| HS13 | [Plain-object shapes and expression inference](13-plain-object-shapes.md) | ☐ |
| HS14 | [Recursive object contracts across JVM and JS](14-recursive-contracts.md) | ☐ |
| HS15 | [E9 ownership ledger and native lifetime primitives](15-run-ownership-primitives.md) | ☐ |
| HS16 | [E9 leases through channels and Worker callbacks](16-channel-and-worker-ownership.md) | ☐ |
| HS17 | [E9 source acquisition, streams and live-edit migration](17-source-acquisition-and-migration.md) | ☐ |
| HS18 | [E9 result snapshots, diagnostics and acceptance](18-result-boundaries-and-ownership-gate.md) | ☐ |
| HS19 | [Object-graph path projection and unnesting](19-object-graph-projection.md) | ☐ |
| HS20 | [Design-time object-graph path picker](20-object-graph-path-picker.md) | ☐ |
| HS21 | [ITCH and cities Job reader adapters](21-sample-reader-adapters.md) | ☐ |
| HS22 | [Analytical Workers, bundled Jobs and standalone plugin proof](22-analytical-jobs-and-standalone-proof.md) | ☐ |
| HS23 | [Spring host workspaces, lifecycle and streaming proxy](23-spring-host-and-proxy.md) | ☐ |
| HS24 | [Live host objects and shared memory governance](24-host-objects-and-memory-governor.md) | ☐ |
| HS25 | [Integrated acceptance, real-day pressure and documentation](25-integrated-acceptance-and-docs.md) | ☐ |

## Execution order and gates

Default order is HS01 through HS25. Prerequisites in each session are the dependency edges, so an
independent session can proceed when a measurement or external gate is blocked. Independence is not
authorization to edit overlapping files concurrently. Revalidate anchors when earlier work lands.

- HS01 establishes the Java 25 baseline; HS02 resolves host compatibility before production hosting.
- HS03 → HS04 → HS05 → HS06 builds and measures the plain core before plugin/host integration.
  A failed P1-early gate blocks the heavy sample proof, not unrelated generic extensibility work.
- HS07 → HS08 → HS09 → HS10 → HS11 → HS12 implements runtime, hosting seams and plugin diagnostics.
- HS13 → HS14 delivers E7. It is logically independent of loader work, but native access/contract
  files overlap ownership work; serialize those edits.
- HS15 → HS16 → HS17 → HS18 delivers E9. HS17 also needs the Java adapter from HS11.
  Primitive ownership code is not an end-to-end supported feature until the HS18 gate.
- HS19 → HS20 delivers E8 over E7 and completed ownership support.
- HS21 → HS22 proves the actual plugin; HS23 → HS24 adds Spring and host services; HS25 is final acceptance.

| Gate | Owning session | Required evidence |
|---|---|---|
| G8 | HS01 | Java 25 API/bytecode/runtime proof across the release train |
| G1–G7 | HS02; packaged confirmation HS23 | Spring GA, dependency convergence, resources/reflection/readers and real streamed SSE |
| G5 public host-service seam | HS24 if HS02 cannot exercise the future public builder | Java interface service injected into Kotlin glue through KzenAutoHost |
| D2 | HS03 | Vendor terms/source note before the real download |
| P1-early | HS06 | Core store/native/persistent-heap measurements and sizing verdict |
| G10 | HS08 | Exact-origin discovery and byte-identical reads with duplicate-origin errors |
| G9 | HS09 | Compiler/runtime class identity, ambiguity, app precedence and second-context proof |
| E2/E3 external acceptance | HS22 | Actual sample through the compatibility kit, folder and application classpath |
| P1-final | HS25 | Governed real-day pressure, native/heap/occupancy and leak evidence |

Gates are work to perform, not preconditions for writing this plan. A failed gate stays failed until
measured evidence changes it. No spike, build, download or production change was performed in planning.

## Extensibility phase ownership

| E phase | Session slices | Phase completion |
|---|---|---|
| E2 | HS07–HS11; external proof HS22 | HS22 after every E2 acceptance case passes |
| E3 | HS12; legacy retirement HS21; external kit HS22 | HS22 |
| E7 | HS13–HS14 | HS14 |
| E8 | HS19–HS20 | HS20 |
| E9 | HS15–HS18, using the HS11 cursor adapter | HS18 |

The old E master-ledger rows are decomposed into these session rows, not marked implemented.
Update the E phase tracker only at its completion point above. Record partial delivery in session
as-built notes so a later executor does not repeat work or mistake an API primitive for a supported route.

## Standing execution rules

1. Before changing a sibling, read its AGENTS.md completely and refresh named symbols against the
   live tree. Read docs/CODING_STANDARDS.md before finalizing code; do not change release-train versions.
2. Build/test from each sibling's own directory. Publish changed kzen-lib modules (including reflect-ksp)
   and kzen-auto SPI/runtime modules at current versions before non-composite consumers. Variant-suffix
   coordinates still use Maven Local. The Gradle JVM requirement is distinct from Java 25 runtime support.
3. For Maven modules use their own Maven reactor and actual wrapper/tool availability. Commands and
   dependency versions are verified during execution, not invented from this plan's capture date.
4. Keep kzen host-neutral, the core Java-only and free of kzen dependencies, and the host responsible
   for services, synchronization, budgets and logging. Expressions remain trusted arbitrary code.
5. The leak-detector requirement is interpreted as JDK Cleaner (the user's wording was “Closer”);
   a specific utility can be substituted if identified, preserving analysis §5.2.1. Cleaner is a
   diagnostic/fallback path, never normal permit circulation or proof that retained leases are absent.
6. Use dedicated temp homes/ports for verification. Never reuse, restart or kill the user's servers.
   Stop only processes whose command lines establish that the session started them.
7. No real feed file or large derived store is committed. Downloads/stores live in a durable area
   outside job/. Delete only session-owned temporary material or validated narrow build outputs.
8. Stage each new source/test/notation/doc by explicit path immediately; preserve unrelated WIP.
   Do not commit, publish a release or modify IDE-private settings as part of these sessions.
9. Each session records commands, results, deviations and remaining gates under As-built. Mark it
   complete here and in the master ledger only when its exit criteria pass. Keep every file:
   this is a constituent plan directory, not disposable docs/plans/next elaboration.

## Completion

HS25 must establish all three outcomes separately, three-path equality on the synthetic oracle,
real-day memory evidence and clean shutdown. Outstanding gates leave the affected session open.
Retargeting and republishing do not constitute a release; version bumps remain an explicit separate request.
