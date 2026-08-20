# Host context & dependency injection — situation and options

*Capture date: 2026-06-02 · Model: Opus 4.8 (xhigh) · Scope: kzen-lib, kzen-auto (jvm + js)*

This is an analysis report, not a change. It maps how "host context" / dependency injection
works today across kzen-lib and kzen-auto, names the problems, lays out the realistic options
with their trade-offs and long-term implications, and ends with a recommended phased direction.

---

## 1. Why this report

The recent **pause-on-error** feature surfaced `KzenAutoContext.global()` — a process-global
mutable singleton that graph-instantiated objects reached for, because the kzen-lib graph has no
way to hand a freshly-built object the runtime services (compilers, stores, the web-driver
holder, …) it needs. That global was subsequently **eliminated**: kzen-lib's `Logic.execute`
gained a `logicHost: LogicHost` parameter, kzen-auto's `DetachedAction.execute` gained a
`context: DetachedActionContext` parameter, four narrow **role interfaces** were introduced
(`ScriptLogicHost`, `ReportDocumentServices`, `ScriptValidatorContext`, `LogicTraceContext`), and
the per-step services were threaded through two **context bags** (`ScriptExecutionContext`,
`ScriptDefinitionContext`). That removed the shared mutable state — a real improvement — but the
*carrier* it left behind (empty marker interfaces downcast to role interfaces, plus ad-hoc service
fields bolted onto the context bags) is itself ad-hoc and convoluted.

The goal here is to step back, *before more features pile onto that shape*, and find a clean,
scalable way to do dependency injection on **two levels** — the hand-coded application graph
(`KzenAutoContext`/`ClientContext`) **and** the objects kzen-lib instantiates dynamically from
notation — that works **uniformly on the browser and the server**.

---

## 2. The situation today

### 2.1 Two fundamentally different kinds of dependency

Everything in this report turns on this distinction:

1. **Notation-defined, object→object dependencies.** kzen-lib already does this well. An object's
   constructor parameters are matched **by name** against a KSP-generated `ReflectionRegistry`
   (`GlobalMirror.constructorArgumentNames` / `create`). Each parameter resolves to an
   `AttributeDefinition` — `Value`, `Reference`, `List`, or `Map`. A `Reference` is resolved
   **topologically** against the partially-built graph: `GraphCreator.createGraph` orders objects
   into construction levels so that a referenced object exists before the object that needs it, and
   `DefinitionAttributeCreator` pulls the already-built instance out of `partialGraphInstance`
   (`kzen-lib-common/.../objects/base/DefinitionAttributeCreator.kt:44-60`).

2. **Runtime / ambient services** — `CachedKotlinCompiler`, `WebDriverContext`, `NotationMedia`,
   the graph store, report repositories, the logic-trace store, and so on. These are **not
   declarable in YAML** (they are stateful, process- or run-scoped, platform-specific). kzen-lib
   has **no channel to inject them at construction**: `GraphCreator.createGraph(graphDefinition)`
   takes only the definition — no host, no environment
   (`kzen-lib-common/.../service/context/GraphCreator.kt:33-66`). So today they are injected at
   **`execute()` time** and threaded downward by hand.

The friction this report addresses is entirely about category (2).

### 2.2 Server — `kzen-auto-jvm`

- **`KzenAutoContext`** (`server/context/KzenAutoContext.kt`) is the hand-wired composition root:
  ~30 service fields constructed inline, now declaring the four role interfaces in its supertype
  list (`AutoCloseable, ScriptLogicHost, ReportDocumentServices, ScriptValidatorContext,
  LogicTraceContext`). Its **`init()` is a separate method** (`KzenAutoContext.kt:178-192`): it
  registers four graph-store observers and pre-warms `objectStableMapper` over every notation
  location, all inside a `runBlocking`. `init()` is **not** called by the constructor — it is
  invoked explicitly in `KzenAutoMain.kzenAutoInit` right after `KzenAutoContext(config)`
  (`server/KzenAutoMain.kt`, ~line 53-55).

- **Two execute-time framework markers** carry the host through the single-slot hooks where
  heterogeneous consumers share one parameter:
  - `LogicHost` — empty interface in kzen-lib (`exec/logic/Logic.kt`), passed to `Logic.execute`.
  - `DetachedActionContext` — empty interface in kzen-auto-common
    (`paradigm/detached/DetachedAction.kt`), passed to `DetachedAction.execute`.
  Each implementor **downcasts** the marker to the role interface it needs, e.g.
  `ScriptDocument.execute` does `val services = logicHost as ScriptLogicHost` and then reads five
  services off it to build a `ScriptExecution`.

- **Context bags.** `ScriptExecutionContext` and `ScriptDefinitionContext` are threaded into every
  script step, and now carry the ad-hoc services alongside the genuine execution state:
  `ScriptExecutionContext` holds `cachedKotlinCompiler`, `webDriverContext`, `notationMedia`;
  `ScriptDefinitionContext` holds `cachedKotlinCompiler`. Steps reach in and pull the service off
  the bag — `FormulaStep` reads `scriptExecutionContext.cachedKotlinCompiler`, the `Browser*Step`
  family read `scriptExecutionContext.webDriverContext` (and `notationMedia` for vision-targeted
  steps).

So a single new service that one step needs has to be: added to `KzenAutoContext`, exposed on a
role interface, accepted by `ScriptExecution`'s constructor, stored on the relevant context bag(s),
and finally read by the step. Five edit sites for one dependency.

### 2.3 Client — `kzen-auto-js`

- **`ClientContext`** is a Kotlin **`object` singleton** (`client/service/ClientContext.kt`),
  reached **statically** as `ClientContext.<service>` from anywhere in the React tree. There is no
  React Context provider and no props drilling; document-scoped stores use a `*Global` WeakRef
  variant of the same idea (e.g. `CustomGlobal`). It has its own `init()` (synchronous, registers
  reflection modules) and `initAsync()` (post-load wiring of observers).

- The client **executes no `Logic`/`DetachedAction` locally** — every detached action and every
  imperative-logic command is proxied to the server over REST (`ClientRestApi.performDetached`,
  `ClientLogicGlobal.*` → `logicStartAndRun`/`logicPause`/…), and the client polls status. Its DI
  surface is therefore only the **UI-side `@Reflect` wrappers** (React component wrappers built
  from the client graph), which reach services through the `ClientContext` global.

- There is **no shared context abstraction** between the two sides. `KzenAutoContext` (a class,
  injected explicitly) and `ClientContext` (an object, reached globally) are entirely separate
  shapes that happen to hold some of the same kzen-lib services (`graphCreator`, `notationReducer`,
  `objectStableMapper`). Only `objectStableMapper` is genuinely shared *data* (server seeds it; the
  client pulls a snapshot at startup).

### 2.4 Tests — e.g. `ScriptExecutionPauseOnErrorTest`

Two concrete smells, both visible in the test as written:

- It constructs a **dummy `KzenAutoConfig`** (`jsModuleName`, `port = 0`, `host`) purely to satisfy
  the `KzenAutoContext` constructor, even though nothing in the test uses any of those values.
- `setUp` builds a **full `KzenAutoContext`** (which boots the Kotlin compiler wrapper, the report
  work pool, the web-driver holder, and the stable-id pre-warm) and then `newExecution()`
  **hand-constructs `ScriptExecution` with a 10-argument constructor**, wiring
  `context.objectStableMapper, context.graphCreator, context.cachedKotlinCompiler,
  context.webDriverContext, context.notationMedia` by hand. This bypasses the live
  `ScriptDocument.execute → Logic` path — the test exercises `ScriptExecution` directly rather than
  the way production reaches it, which is exactly the "no shortcuts, run the live logic" property
  the user wants tests to have.

### 2.5 The one kzen-lib seam that the options hinge on

kzen-lib's construction is already **pluggable per attribute**. `AttributeObjectCreator` resolves
each constructor parameter via an `AttributeCreator`, defaulting to `DefinitionAttributeCreator`
but honouring a per-attribute `creatorReference` taken from notation metadata
(`AttributeObjectCreator.kt:42-55`; the reference is read in `NotationMetadataReader`). In other
words, **a custom `AttributeCreator` is already a first-class extension point** for "how is this
constructor parameter produced." The catch: `AttributeCreator.create(...)` is handed
`(objectLocation, attributeName, graphStructure, objectDefinition, partialGraphInstance)` — **no
runtime host** — and `GraphCreator` is a stateless `object`. So construction-time service injection
is *reachable* via this seam, but only if a host/environment is threaded through
`GraphCreator.createGraph → ObjectCreator.create → AttributeCreator.create`.

---

## 3. The core problems (named, so the options can be scored)

- **P1 — O(N) edits per new service.** One new step dependency means edits to the context root, a
  role interface, `ScriptExecution`'s constructor, both context bags, and the step.
- **P2 — Not third-party-extensible.** A plugin step or action cannot introduce its own context
  element without modifying core interfaces and context-bag classes it doesn't own.
- **P3 — Two DI vocabularies, plus a cast-y seam.** Hand-wired application DI and graph-instantiated
  objects use different mechanisms, and the bridge between them is an empty marker downcast — no
  compile-time guarantee that the host actually is the role the implementor casts to.
- **P4 — Client/server divergence.** A global `object` on one side, an explicitly-passed class on
  the other, with no common abstraction — so the two patterns drift independently.
- **P5 — Test ergonomics.** Heavy setup, an unnecessary config object, and a low-level entry point
  that bypasses the live logic path.
- **P6 — `init()` is a separable, forgettable side-effect step**, distinct from construction.

---

## 4. Options

Each option below is described by its mechanism, the problems it fixes, its pros/cons, and its
long-term implications.

### Option A — Typed service registry / "environment" carried through the seams

**Mechanism.** Introduce one carrier — call it `HostContext` (or `Environment`) — in
kzen-lib `commonMain`: a typed `Key<T>` → service map with typed accessor helpers. It *replaces*
the two empty markers and the four role interfaces as the thing passed to `Logic.execute` and
`DetachedAction.execute`. The step context bags collapse their ad-hoc service fields down to a
single `host` reference; a step does `host[WebDriverKey]` instead of `context.webDriverContext`.
Both `KzenAutoContext` and `ClientContext` *are* a `HostContext` (populate the map at construction).
Third parties register their own keys without touching any core class.

- **Fixes:** P1, P2, P3, P4 — and it is what makes the P5 test helper trivial (the test context is
  just another `HostContext`).
- **Pros:** small and mechanical; stays entirely within the current *execute-time* injection model,
  so the risk surface is bounded; pure Kotlin, so it is KMP-friendly and unifies client and server
  under one type.
- **Cons:** lookups are **runtime** — a missing key is a runtime error, not a compile error
  (mitigate with required/optional typed accessors and a boot-time presence check); it sacrifices
  the "this consumer needs exactly X, and the compiler enforces it" self-documentation the role
  interfaces give (mitigate by keeping thin typed *views* over the map); and, most importantly, **a
  registry is a service locator** — structurally the same ambient-lookup shape as the `global()`
  we just removed, only typed and passed by hand rather than reached statically.
- **Long-term:** this is the conventional "context object" pattern. It scales to any number of
  services and leaves kzen-lib's construction model untouched. Its ceiling is exactly its floor:
  it never makes objects *declare* their dependencies, it only makes the bag they reach into
  uniform and extensible.

### Option B — Construction-time injection via kzen-lib's `AttributeCreator` seam

**Mechanism.** Thread a host/environment through construction:
`GraphCreator.createGraph(definition, host)` → `ObjectCreator.create(..., host)` →
`AttributeCreator.create(..., host)`. Add a service-injecting `AttributeCreator` — selected by an
annotation on the constructor parameter (or by notation, as `creatorReference` already allows) —
that resolves that parameter from the host's registry instead of from notation. Then `FormulaStep`
simply declares `cachedKotlinCompiler: CachedKotlinCompiler` as a constructor parameter, and
kzen-lib wires it at build time. **The context bags and the downcasts disappear** for those
services: an object that needs a compiler just *has* a compiler field.

- **Fixes:** P1, P2, P3 most completely for the instantiated-object tier (steps, documents,
  actions).
- **Pros:** this is the "real DI" end-state. Adding a third-party dependency is "declare a
  constructor parameter + register a service" — nothing else. The graph is already re-created per
  run/request (`ModelDetachedExecutor` and `LogicExecutionFacadeImpl.open` both call
  `graphCreator.createGraph(...)` afresh), so per-run service binding is natural and matches today's
  lifetime. Objects become honestly self-describing about their dependencies — aligned with the
  "single-purpose code, each object declares exactly what it needs" preference.
- **Cons:** **invasive kzen-lib change.** Every `createGraph` call site and the entire creator chain
  must carry the host; the stateless `object GraphCreator` gains a parameter (and the
  bootstrap-objects machinery must tolerate it). It expands kzen-lib's contract from "fully
  declarative from YAML" to "YAML + ambient host," which must be handled carefully so injected
  services never leak into digests or notation persistence. And it introduces a way to hide global
  state inside constructors if overused.
- **Long-term:** kzen-lib becomes a genuine DI container with **two resolution sources** —
  notation references and host services. That is powerful and is the principled answer, but it is a
  real semantic expansion of the library's identity, not a local tidy-up.

### Option C — Adopt a DI library (Koin / kotlin-inject) for the application graph

**Mechanism.** Replace the hand-wired `KzenAutoContext` (and possibly `ClientContext`) with a DI
container. KMP-capable choices exist: Koin (runtime, multiplatform) or kotlin-inject / anvil
(compile-time, KSP, multiplatform).

- **Pros:** tidies construction order and lifecycle in the application graph — it would dissolve the
  `FileListingAction`↔`definitionRepository` ordering hazard and give `init()` a managed home (P6).
- **Cons:** it does **nothing** for the graph-instantiated objects, which are the actual pain
  (P1/P2) — those are built by kzen-lib's `GraphCreator`, not by any container. It adds a
  dependency and KMP friction, and it means two DI systems coexisting (the container for the app,
  kzen-lib for the notation graph).
- **Verdict:** can *complement* A or B later, but it is **not** a standalone answer to this brief
  and is not recommended on its own.

### Option D — Formalize the role-interface marker approach (status quo, tidied)

**Mechanism.** Keep the current shape but promote a common `HostContext` supertype into
`commonMain` with platform implementations, retain the narrow role interfaces, and add a client
mirror so both sides share the supertype.

- **Pros:** lowest effort and risk; service access stays **compile-time-checked**, and the role
  interfaces continue to document precisely what each consumer needs.
- **Cons:** still O(N) edits per service (P1); still not third-party-extensible (P2) without editing
  core interfaces.
- **Long-term:** perfectly fine if the service set stays small and stable and there is never a
  third-party plugin surface. It does not scale to a plugin ecosystem.

---

## 5. Cross-cutting concerns (apply under any option)

- **Client/server unification.** Whatever carrier is chosen should be defined in **`commonMain`**
  so that `ClientContext` and `KzenAutoContext` both implement it, and the client React wrappers
  resolve services *from it* rather than from the `ClientContext.<service>` global. This can be
  incremental — the global can remain the bootstrap holder while call sites migrate. Note the
  client's surface is much smaller (UI wrappers only; it never runs `Logic`/`DetachedAction`), so
  most of the carrier's payload is server-only and the client implementation can expose just the
  subset it actually uses.

- **`init()` → self-initializing construction (P6).** Replace the separate `init()` with a factory
  — `KzenAutoContext.create(config): KzenAutoContext` that constructs, wires the observers, and
  pre-warms before returning — or run `init()` at the very end of the constructor. Either removes
  the "construct, then remember to init" footgun; the factory form is cleaner given the `this`
  escape (the context passes `this` as host to `serverLogicController`/`detachedExecutor`) and the
  `runBlocking` currently inside `init()`.

- **Tests (P5).** Two moves, both independent of the DI direction:
  1. Make `KzenAutoConfig` optional/defaulted, or add a `KzenAutoContext.forTest()`, so a test that
     only runs in-process logic doesn't fabricate a config it ignores.
  2. Add a **high-level helper** that loads a document from YAML through the **real graph** and
     drives the live `Logic` path — i.e. locate the `ScriptDocument` in the instantiated graph and
     call `document.execute(host = testContext)` — instead of hand-building `ScriptExecution`. Under
     a unified carrier the test context simply *is* the host, so the helper is a few lines and the
     test exercises the maximum amount of production code with no shortcuts.

---

## 6. Recommendation (phased)

**State the tension honestly first.** The reason `global()` was worth removing is that it is an
ambient service locator. **Option A's registry is the same structural shape** — typed and passed
explicitly, but still "reach into a bag at the point of use." **Option B (construction injection)**
is the only option that matches the stronger ideal of *each object declaring exactly the
dependencies it needs*. The phasing below deliberately buys the cheap unification now without
foreclosing B, and guards A from quietly becoming `global()` reborn.

- **Phase 0 — now, cheap, no kzen-lib change.** Make context construction self-initializing (a
  factory; P6) and fix the test ergonomics (defaulted/optional config + the high-level "run a
  document through the live `Logic` path" helper; P5). This is pure win, independent of which DI
  direction is ultimately chosen, and it immediately makes the test surface representative.

- **Phase 1 — the carrier.** Adopt **Option A**: a typed `HostContext`/environment in `commonMain`,
  implemented by both `KzenAutoContext` and `ClientContext`. Replace the two empty markers and the
  four role interfaces with the single carrier, and collapse the ad-hoc context-bag service fields
  to one `host` reference. To honour the anti-global stance, **keep domain-scoped typed views** —
  thin per-domain accessors over the registry, in the spirit of the existing role interfaces —
  rather than exposing a flat god-bag, and add a boot-time key-presence validation so a missing
  service fails at startup, not deep in a run. This dissolves P1–P4 with bounded, mechanical risk.

- **Phase 2 — optional, earn it.** When registry-lookup ergonomics inside steps become the
  bottleneck (and especially once a real third-party plugin surface makes P2 acute), evolve the
  step subtree toward **Option B**: construction-time injection through the `AttributeCreator`
  seam, so steps declare their service constructor parameters and drop the bag lookups entirely.
  This is the larger kzen-lib investment and should be paid for by demonstrated need, not
  speculatively.

- **Not recommended standalone:** Option C (it can tidy application wiring later but doesn't touch
  the core problem). **Option D** is the do-minimum fallback if there is zero appetite for any
  `commonMain`/kzen-lib change.

The throughline: **Option A is the minimal change that makes the system extensible and unified;
Option B is the principled end-state and should be reached when its cost is justified by demand.**

---

## 7. Trade-off matrix

| | A: Registry / env | B: Ctor injection | C: DI library | D: Formalize markers |
|---|---|---|---|---|
| Fixes P1 (O(N) edits) | ✓ | ✓✓ | ✗ | ✗ |
| Fixes P2 (3rd-party extensible) | ✓ | ✓✓ | ✗ | ✗ |
| Fixes P3 (one DI vocabulary) | ✓ | ✓✓ | partial | partial |
| Fixes P4 (client/server unified) | ✓ | ✓ | ✗ | ✓ (if commonMain) |
| kzen-lib change required | none | **large** | none | small |
| Compile-time safety of access | runtime lookups | compile-time | compile-time | compile-time |
| Risk / reversibility | low / easy | high / harder | medium | low / easy |
| Aligns with anti-global ideal | weak (locator) | strong | n/a | medium |

---

## 8. Long-term implications

- **Pull vs push is the real fork.** Option A keeps services *pulled* at the use site (a locator);
  Option B *pushes* them into constructors (true DI). B is cleaner and self-documenting but couples
  kzen-lib to an ambient-host notion that it deliberately does not have today.
- **Safety vs extensibility.** Runtime-key lookups trade compile-time guarantees for open
  extension. Decide up front how much to mitigate — typed required/optional accessors, boot-time
  validation, domain-scoped sub-views — versus accepting "missing service = runtime failure."
- **One carrier, defined in `commonMain`.** Whatever is chosen must live in `commonMain` so client
  and server share it. The thing to avoid is inventing a *third* divergent context and ending up
  with three shapes instead of two.
- **Guard against a new god-object.** A flat registry is `global()` with a nicer hat. Scope keys by
  domain and prefer narrow typed views, so that the fix for shared mutable state does not quietly
  reintroduce the very ambient-lookup pattern it replaced.

---

## Appendix — primary sources (read first-hand for this report)

- `kzen-lib-common/.../exec/logic/Logic.kt` — `Logic.execute(..., logicHost)`, `interface LogicHost`
- `kzen-auto-common/.../paradigm/detached/DetachedAction.kt` — `execute(request, context)`, `interface DetachedActionContext`
- `kzen-lib-common/.../service/context/GraphCreator.kt` — `createGraph(graphDefinition)`, construction-level ordering
- `kzen-lib-common/.../objects/base/AttributeObjectCreator.kt`, `DefinitionAttributeCreator.kt`, `api/AttributeCreator.kt` — per-attribute creator seam
- `kzen-auto-jvm/.../server/context/KzenAutoContext.kt` — composition root, `init()`, role-interface supertypes
- `kzen-auto-jvm/.../server/context/{ScriptLogicHost,ReportDocumentServices,ScriptValidatorContext,LogicTraceContext}.kt`
- `kzen-auto-jvm/.../server/objects/script/ScriptExecution.kt`, `ScriptDocument.kt`, `model/{ScriptExecutionContext,ScriptDefinitionContext}.kt`
- `kzen-auto-jvm/.../server/objects/script/step/eval/FormulaStep.kt`, `step/browser/Browser*Step.kt`
- `kzen-auto-jvm/.../server/service/{compile/CachedKotlinCompiler.kt, webdriver/WebDriverContext.kt}`
- `kzen-auto-jvm/.../server/service/exec/ModelDetachedExecutor.kt`, `service/impl/LogicExecutionFacadeImpl.kt`
- `kzen-auto-js/.../client/service/ClientContext.kt`, `client/Main.kt`
- `kzen-auto-jvm/.../server/objects/script/ScriptExecutionPauseOnErrorTest.kt`
