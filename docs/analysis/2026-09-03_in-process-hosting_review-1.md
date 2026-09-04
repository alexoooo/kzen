# Review 1 — in-process hosting and market-data plugin analysis

> **Reviewed:** `2026-09-03_in-process-hosting.md`, as read 2026-09-04.
> **Scope:** design review only. This file does not amend the analysis or the extensibility plan.

## Overall verdict

The problem statement makes sense, the motivating constraints are substantive rather than synthetic, and the
solution is pointed in the right direction. In particular, the analysis correctly distinguishes two paths into
a Job:

- a portable plugin contribution, such as an ITCH reader or analysis Worker; and
- a live object supplied by an embedding host through `GraphEnvironment` / `@Service`.

Those paths overlap usefully without being redundant. The first proves third-party extensibility; the second
proves incremental migration of an existing application whose domain model must remain resident in the host
heap. Comparing their results over the same fixture is a strong integration assertion.

NASDAQ ITCH 5.0 is also a good motivating domain. It is real, stateful, ordered, large enough to expose memory
and throughput behaviour, and rich enough to make object graphs, lifecycle analysis and book reconstruction
meaningful. A seeded fixture in the same binary format plus an optional real-day pressure run is the right data
policy.

I would proceed to the proposed gates and planning after tightening the points below. None changes the central
direction.

## Problem framing

“Kzen is designed process-per-project” is slightly stronger than the code warrants. The composition root is
already instance-based; what the current deployment obtains from process isolation is safe ownership of a few
remaining process-wide and CWD-relative facilities. A more precise framing is:

> Kzen's default deployment uses one process per project. Supporting several contexts in a foreign JVM requires
> making workspace state context-owned while deliberately keeping the extension universe process-global.

It is worth treating the work as three independently testable outcomes:

1. Several isolated `KzenAutoContext`s can run in one JVM.
2. Selected live host objects can enter Jobs ergonomically.
3. A third-party jar set can contribute server-side code and notation without kzen source edits.

The Spring/ITCH sample can demonstrate all three, but the acceptance criteria should remain distinct so that a
successful sample does not conceal an accidental coupling between them.

The trust model should also be stated plainly: Kzen expressions execute arbitrary code. In-process hosting and
plugins preserve that model; they do not create a sandbox. The security boundary is whether a user is permitted
to run Kzen on the machine, not which POJO getters happen to be visible.

## Global extension scope

The plugin/reflection universe should be global and externally managed. These are complementary properties:

- **Global scope:** all `KzenAutoContext`s in a JVM see the same application classes, plugin classloaders,
  reflective mirrors and extension types.
- **External management:** the embedding application or deployment chooses the application dependencies and
  plugin directories before Kzen is initialized.
- **Pinned lifetime:** plugin loaders and registrations live until JVM exit. There is no hot replacement or
  attempted class unloading.

This suggests process-level plugin bootstrap rather than a different `pluginRoot` owned by each context. The
first initialization establishes the global plugin universe; a later attempt to initialize it with a conflicting
configuration should fail fast. Workspace contexts may still own their graph, host service instances, storage,
controller state and internal server.

The boot sequence should therefore be explicit:

```text
host/application classpath + configured plugin directories
    → initialize the one global extension universe
    → create N workspace contexts against it
```

There should be no close/reload protocol for plugin classloaders. Restarting the JVM is the upgrade operation.

## Diagnostics promise

The diagnostics promise should be smaller than the current E3 wording implies. `ReflectiveClassMirror` resolves
a class lazily when kzen is given its name; without an index or an exhaustive classpath scan, kzen cannot list
every dormant `@Reflect` class or pre-validate all of its `@Service` declarations.

That is acceptable. `PluginDocument` only needs to show:

- the installed plugin scopes: id, version and source directory or application classpath;
- contributions discovered through explicit protocols, such as `ServiceLoader` readers and notation resources;
- `@Reflect` classes the mirror has actually been asked to resolve; and
- failures encountered while loading or using those contributions.

An unreferenced class is not expected to appear. A malformed reflective class or missing host service appears
after notation or another operation references it. Requests read cached discovery/diagnostic state and never
trigger a classpath-wide rescan.

Generated registrations can retain their existing boot-time service validation. The same completeness should
not be promised for lazy reflective plugins. This reduced promise avoids adding a class index or scanner solely
for a diagnostics screen.

## In-process hosting shape

One `KzenAutoContext` and one loopback Ktor server per workspace is a pragmatic first integration. It preserves
the existing HTTP/UI contract and keeps Spring out of kzen. The extra local HTTP hop is a reasonable price for
avoiding a Ktor/Spring servlet integration project.

The host should own:

- workspace configuration and Spring lifecycle;
- loopback port allocation and reverse proxying;
- its existing global synchronization / memory-governance mechanism; and
- the SLF4J backend and logging configuration.

Kzen does not need an admission concept or knowledge of the host's semaphore. The Spring sample can apply the
host's existing synchronization around Kzen-triggered work. Any bookkeeping needed to integrate that mechanism
is host implementation, not a new kzen extension seam.

Similarly, a per-context `logDir` is not a meaningful embedding boundary if the host owns one process-wide
logging backend. Kzen should log through SLF4J; the standalone distribution and embedding host each supply their
own logging configuration. `workRoot`, by contrast, must be context-owned because caches, scratch and persistent
Job output require workspace isolation.

The multi-context test should cover more than two successful starts. It should demonstrate that one context's
boot sweep, output cleanup, notation edit, run cancellation and shutdown cannot affect the other context's work
or state.

## Host-model exposure

`KzenAutoHost.services`, merged into each context's `GraphEnvironment` with collision checks, is a clean generic
seam. A host-specific `@Reflect` `SourceWorker` with an `@Service TradeRepository` proves that live objects can be
analyzed without kzen knowing Spring or the market-data domain.

There are two reasonable ergonomic tiers:

1. **Code-oriented integration:** bind a service by its declared type and write a thin Worker. This is explicit,
   statically typed and sufficient for the first sample.
2. **Named host data:** optionally bind a named iterable/cursor plus its declared item type, allowing a generic
   Host Source Worker to expose it without one Worker class per repository.

The second tier is a useful future expansion if “ergonomic” is intended to mean that a host developer should not
write adapter code for each collection. It should not block the basic `KzenAutoHost` seam. It is also the smallest
concrete version of the deferred `ProviderDataSource` idea; the full design-time provider hierarchy can remain
deferred.

Type-only service keys are consistent with the current `@Service` mechanism. If a host eventually needs two
instances under the same interface, named/qualified bindings would be a separate extension rather than a reason
to complicate the first API.

## Plugin mechanism

“A plugin is a classloader” is a productive simplification, more precisely understood as “a plugin installation
scope is one classloader.” A directory containing a related jar set is the right installation unit, and treating
the application classloader as plugin zero makes dependency-based embedding and folder-based standalone use
follow the same contribution path.

The three contribution channels are coherent:

- `ServiceLoader` for explicit capability SPIs;
- a reflective mirror for notation-instantiable server classes; and
- bundled notation for archetypes, tools and ready-made documents.

Implementation planning should make the following deterministic:

- plugin-directory and jar ordering;
- duplicate plugin ids, reader identities, class names and notation paths;
- parent `ServiceLoader` providers not being counted once for every child loader;
- the exact loader visible to compiled expressions, preserving class identity rather than loading a second copy;
  and
- failure isolation, so one broken contribution does not hide diagnostics for unrelated plugin scopes.

The optional manifest should probably also carry a kzen/plugin-SPI compatibility version or range. A boot-time
compatibility error is much better than a later linkage failure. This is independent of contribution discovery;
the manifest remains metadata, not a class allow-list.

The statement that an optional KSP `ModuleReflection` may participate also needs an explicit discovery rule if
it is retained. A folder plugin cannot merely “call `register()`” unless a bootstrap protocol causes that call.
The simplest first contract may be that folder plugins use JVM reflection, while generated registration remains
an application/build-time optimization.

## Java-friendly and plain-object support

The two-tier model is right:

- a plugin may implement kzen SPIs for first-class reader/Worker/editor behaviour; and
- ordinary Java code can be called by expressions and have its values lifted without depending on kzen.

POJO support should be automatic, not an allow-listed or security-gated facility. The implementation still needs
deterministic conventions for inherited properties, getter-versus-field collisions, `getX` versus `isX`, excluded
methods such as `getClass`, nullability defaults, and getter failures. Those are data-contract and error-reporting
rules, not trust boundaries.

The proposed `BlockingReaderCapability` is appropriate. For the blocking `SourceWorker` variant, a Java-friendly
cursor/iterator hook may fit the framework better than asking Java code to drive a suspend-aware emitter: Java
opens a cursor and kzen owns pulls, batching, checkpoints, cancellation and close. This can be decided from the
smallest implementation that preserves current `SourceWorker` semantics.

Two details deserve explicit tests:

- A top-level `Set` is an `Iterable`, but `FormulaSourceWorker` migration assumes stable reevaluation order when
  it skips an already-emitted prefix. Either top-level sets need a stable-order rule or they should not be treated
  as resumable streams.
- An expression-created iterator over a file needs a defined close path on completion, cancellation and failure.
  The first-class `ReaderCapability` route already has `DataCursor.close`; it should remain the pressure-run path
  unless expression sources gain equivalent resource ownership.

## Object graphs and path projection

The E7/E8 direction is valuable. Plain records, data classes and POJOs becoming typed Job values is what makes the
host model genuinely usable. A projection/unnest Worker is also a better generic boundary than teaching every
aggregate or writer to understand nested graphs.

The path semantics should be settled before implementation:

- recursive type references stay finite in the contract and appear as an explicit cycle/reference in the picker;
- empty and null collection behaviour is defined;
- multiple unnests over the same collection share an iteration;
- unrelated collections do not silently create a Cartesian product unless that operation is explicit; and
- expansion is bounded or at least diagnosed, because nested collections can multiply output dramatically.

These are generic data semantics and should be tested with a smaller neutral object graph as well as ITCH.

## Market-data sample

ITCH should remain the motivating example. The plain Java portion should preserve a distinction between:

- decoded wire messages;
- reconstructed order lifecycle;
- reconstructed book state and snapshots; and
- flattened reporting projections.

Avoid making one wide nullable record the only representation of all message kinds. A normalized row projection
is useful for generic Jobs, but the plain library should retain the event distinctions needed for correct replay
and book reconstruction.

It would strengthen the “neither side customized” claim to make the plain Java market-data core a separate Maven
module with no kzen dependency, with the kzen reader/Workers/notation in a thin adapter module. The Spring sample
can consume the core normally and receive the adapter transitively or explicitly. A build-level dependency
boundary is a stronger proof than a package convention inside one artifact.

Keep the book reconstruction in the plain Java library and expose it through thin stateful plugin Workers. A
generic “fold by key” Worker should wait for a second real use case: ordering, migration, state eviction, spilling
and checkpoint semantics make it substantially larger than the market example initially suggests.

Use the seeded fixture for exact three-path agreement. Measure the real day separately for throughput and memory
pressure, avoiding a benchmark that accidentally keeps duplicate full-day representations alive merely to prove
equality.

## Additional ideas

### Process runtime as an explicit concept

The global/local split may be clearer if implementation introduces a small process-level runtime or bootstrap
object:

```text
KzenAutoRuntime (one per JVM)
    plugin loaders, reflection and extension discovery

KzenAutoContext (one per workspace)
    graph, services, work roots, controller and handlers
```

It need not become a large public façade. Its value is making “initialize global extensions exactly once before
contexts” an enforceable invariant rather than an ordering convention spread across companion objects.

### Plugin compatibility test kit

A reusable compatibility test could accept a plugin directory and verify loader creation, reader discovery,
notation discovery, reflective construction, expression visibility, duplicate detection and expected diagnostics.
That would give third-party plugin authors a much faster feedback loop than discovering incompatibility inside a
full project.

### Stable sample boundaries

Use separate acceptance tests for:

- plugin capability in standalone kzen;
- host-object access in the Spring embedding;
- two-workspace isolation;
- equality across the reader, plain-library expression and live-host-object routes; and
- the real-data pressure measurement.

This prevents the end-to-end sample from becoming one large test whose success is difficult to interpret.

## Direct answers to the remaining design questions

**Q4 — stateful Workers or generic Workers:** keep the stateful market analysis in plugin Workers backed by the
plain Java library. Do not add a generic keyed fold until another domain demonstrates the same need.

**Q5 — sample name:** `kzen-sample-embed-spring` is explicit and consistent with the purpose. The name is not an
architectural issue; retaining the user's proposed name avoids another round of terminology.

## Editorial inconsistencies to reconcile before promoting this to a plan

The analysis currently contains a few conclusions from different drafting passes:

- §5.2 still calls the world-cities disposition open, while §7 records it as decided.
- §6a.2 says plugin `ReportDefiner` moves to `ServiceLoader`, while the later decision retires plugin Report
  support in favour of Job.
- The manifest allow-list is still named in the candidate phase outline even though D8 was dropped.
- §6a.4 is phrased as awaiting ratification although its table is marked ratified.
- §11 says Q3 and Q6–Q8 are open even though they are decided or moot.

These do not undermine the design, but they should be normalized when the analysis is next revised so the
ratified extensibility plan remains the unambiguous source of truth.

## Recommendation

Proceed with the Java 25 gate and a narrow embedding spike. Before turning the remaining work into phases, record
four contracts explicitly:

1. one externally configured, JVM-global, startup-pinned extension universe;
2. context-owned workspace state and work roots;
3. host-owned synchronization and logging, with no Spring concepts in kzen; and
4. discovery-based diagnostics, not exhaustive class inventory or reflective boot validation.

With those clarifications, the proposed architecture is cohesive and the ITCH/Spring example is a credible way
to prove it.
