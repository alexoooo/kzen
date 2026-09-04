# Review 2 — revised in-process hosting analysis

> **Status: design review only, 2026-09-04.** This reviews the revised
> `2026-09-03_in-process-hosting.md` after review 1 and the subsequent functional clarifications. It does
> not amend that analysis or the extensibility plan.

## Overall verdict

The revised problem statement and overall architecture make sense. The principal decisions now form a
coherent design:

- one externally configured, process-global, startup-pinned extension universe;
- context-owned workspace state and work roots;
- host-owned synchronization, memory governance and logging;
- automatic POJO support under kzen's existing trusted-code model;
- one loopback Ktor server per embedded workspace;
- NASDAQ ITCH as the substantive domain;
- a plain Java market-data core with a thin kzen adapter; and
- discovery-based plugin diagnostics rather than an exhaustive class inventory.

I would not reopen those decisions.

The document is ready to become an execution plan, and the Java-baseline work plus the proposed spike can
begin. I would not yet hand E2 and E9 to an implementer as fully specified phases. Three contracts still
need a design decision, and several smaller contracts should be made explicit before implementation.

## 1. Closeable-item ownership is not implementable exactly as described

E9 currently combines three claims:

1. the framework releases an item when a consumer "moves past" it;
2. no Worker cooperation is required; and
3. accumulating Workers may retain owned items, with the ledger identifying those Workers as holders.

Those claims cannot all hold. Current transform and sink Workers consume physical batches through
`receiveBatch()`, rather than exclusively through the proposed element-iterator hook. More importantly,
an accumulating Worker such as `SortWorker` stores the `DataValue` in an ordinary collection. The runtime
cannot observe that Java/Kotlin reference being retained.

The ownership contract therefore needs one of two shapes.

### Recommended: explicit retention beyond a callback

- Emitting an `AutoCloseable` item transfers its ownership to the run. A borrowed/shared closeable must be
  copied, wrapped with an explicit non-owning adapter, or otherwise kept out of this route.
- `onElement` receives a borrowed value whose implicit lease lasts through that callback.
- Sending the value, or an owned derivative of it, acquires the downstream reference before the callback's
  implicit reference is released.
- A Worker that retains the value beyond `onElement` explicitly acquires a lease identifying that Worker
  and releases it when finished.
- Built-in accumulators either use that lease or materialize the fields they need into an unowned value.
- Final release closes the native exactly once; cancellation, failure and teardown release all outstanding
  leases best-effort.

This gives the ledger enough information to name actual holders in diagnostics. The framework-owned base
loops can implement the ordinary streaming case without burdening ordinary Worker authors; only retention
beyond the callback requires cooperation.

### Simpler alternative: prohibit retention

The Worker contract could instead prohibit retaining an owned value beyond `onElement`, requiring every
accumulator to materialize an unowned copy immediately. In that design the proposed accumulating-Worker
stall and holder diagnostics should be removed, because owned elements would never legitimately remain
held by an accumulator.

Whichever shape is chosen, the specification should describe `receiveBatch()` and migration carryover
directly. An element-iterator-only description does not match the current Worker substrate.

The ownership tests should also cover:

- the same native object emitted to two output channels;
- the same native identity encountered again after it has been closed;
- failure from `close()` while other outstanding elements still need closing;
- an owned derivative returned from a Formula;
- an accumulator retaining across live-edit migration; and
- a borrowed host object that must not be closed accidentally.

## 2. Multi-plugin expression visibility needs a concrete classloader design

The plugin design creates one sibling `URLClassLoader` per plugin directory. The expression section then
says to hand "the plugin loader" to the compiler, but a workspace expression has no owning plugin and may
reference classes from more than one plugin.

A standard classloader has only one parent. A flat `URLClassLoader` over all plugin jars is not an aggregate
view of the per-plugin loaders: it defines second copies of their classes and can break identity between a
value constructed through a plugin mirror and the type used by a compiled expression.

The design should choose one of these explicitly:

1. **One flat, process-global plugin loader.** This is the simplest implementation, but gives up the
   ratified per-directory loader boundary.
2. **Per-directory loaders plus an aggregate delegating loader.** The aggregate resolves a requested class
   through the actual defining plugin loader and returns that loader's `Class`, never defining another
   copy. The Kotlin compiler receives the explicit union of the plugin jar paths as its compilation
   classpath rather than relying solely on `classpathFromClassloader` to discover them.

If the per-directory decision stands, the second option is the coherent one. Its lazy resolution can also
report an ambiguity when two plugin scopes define the same requested public class name, without performing
an exhaustive boot scan.

Add a gate for this mechanism. Its acceptance test should:

- compile one expression that references types from two plugin directories;
- pass into that expression an instance created by a plugin's reflective mirror;
- perform an identity-sensitive cast or method call successfully; and
- report an ambiguity rather than choosing the first scope when the requested class exists in two scopes.

## 3. Lazy reflection contradicts boot-time duplicate detection

The revised diagnostics promise correctly says that reflective classes are discovered only when notation
or another caller asks for them. The plugin discovery section still calls duplicate `@Reflect` class names
a boot error. Without a scan or index, boot does not know those names.

The consistent rule is:

- reader identities and notation paths are checked for duplicates at boot, because discovery enumerates
  them;
- generated/indexed reflection entries may be checked at registration time; and
- lazily reflected classes produce a resolution-time ambiguity error if more than one scope serves the
  requested name.

`GlobalMirror` currently uses first-match-wins fallback ordering, so E2 needs to replace that behavior for
the plugin mirrors. A lazy ambiguity should also become a named failure in `PluginDocument`, fitting the
reduced diagnostics promise exactly.

## 4. Global extensions versus per-context host services needs one rule

A plugin-supplied KSP `ModuleReflection` registers its classes into the global `ReflectionRegistry`.
`ServiceEnvironmentValidation` currently validates the service requirements of that global generated
registry when each context is created. This means a generated plugin Worker requiring `TradeRepository`
can prevent a context without that service from starting even if that context never references the Worker.
The equivalent reflection-only Worker instead fails lazily when referenced.

KSP should not silently change a plugin's service-admission semantics. Choose and document one rule:

- every context must supply every service required by every generated class in the global extension
  universe; or
- plugin-contributed classes, generated or reflective, validate their services when a context actually
  references them, while kzen's built-in generated registrations retain their current boot validation.

The second rule is more compatible with independently configured workspaces and with the reduced plugin
diagnostics promise. It requires the runtime to retain contribution origin instead of flattening every
plugin-generated registration indistinguishably into the built-in global registry.

## 5. Make the Java host API genuinely Java-friendly

`KzenAutoHost(services: Map<ClassName, Any>)` is a reasonable internal representation, but it is not the
most ergonomic public seam for an existing Java/Spring application. It requires callers to construct a
kzen name and manually keep it aligned with the interface declared by `@Service`.

Add a Java-facing facade or builder along these lines:

```java
KzenAutoHost host = KzenAutoHost.builder()
        .service(TradeRepository.class, tradeRepository)
        .service(OrderBookService.class, orderBookService)
        .build();
```

The implementation can convert `Class<?>` to `ClassName` internally. The explicit class key is important
for Spring proxies and for registering an implementation under the interface a Worker declares. Supplier
bindings can remain a later addition unless the host needs lazy or scoped beans immediately.

## 6. Fail fast on duplicate active work roots

Per-context `WorkUtils` and process signatures fix the accidental global root, but two simultaneously live
contexts configured with the same normalized `workRoot` would still be unsafe: either context's startup or
cleanup can inspect the other context's files.

Either the runtime should claim normalized active roots process-wide and reject a duplicate until the
owning context closes, or the host contract should require and validate uniqueness before constructing the
contexts. The two-workspace acceptance test should include this negative case.

## 7. Tighten the POJO convention

"Declaration order then alphabetical" is not a deterministic rule if reflection does not guarantee
declaration order. Specify a single stable property order, preferably lexical by final property name, and
define:

- getter versus public-field precedence;
- `getX()` versus boolean `isX()` precedence;
- most-derived override behavior;
- rejection or resolution of conflicting property types;
- exclusion of static, synthetic and bridge members; and
- the precise annotation locations used for nullability.

Using JavaBeans decapitalization semantics avoids surprises around names such as `getURL()`.

These are data-shape rules, not a security boundary. Ordinary POJOs should remain automatic as the analysis
now says.

## 8. Finish the path-projection semantics

Before E8 implementation, state:

- whether a null intermediate yields a null column, drops the output row, or is an error;
- whether an empty unnested list yields zero rows or one row with nulls;
- that wildcard paths into the same list share the same element rather than forming a self-product;
- that wildcards over different lists form the documented cross product; and
- how the picker presents a recursive type reference without expanding forever.

The proposed cross-product rule for independent lists is sound; these additions merely remove choices that
would otherwise be made accidentally in code.

## 9. Editorial cleanup

A final editing pass should fix these stale statements:

- the architecture diagram still places `MemoryGovernor` at the proxy, while §5.3 correctly places memory
  governance inside host-owned closeable objects;
- §6a says E1 "has been waiting" even though E1 is now ratified;
- §6 is titled as gaps needing a decision even though its entries are decided, superseded or moot; and
- the gates table still carries moot D1.

## Readiness conclusion

The problem statement is convincing, and the selected solution is the right overall shape. It is ready for
planning and for the Java 25 prerequisite plus the G1–G7 spike. Before E2/E9 implementation, settle:

1. explicit ownership/retention semantics;
2. the aggregate expression classloader and compilation classpath; and
3. lazy reflection ambiguity behavior.

The plugin-generated service-validation rule should be settled in the same pass. The Java host facade,
active-root uniqueness, POJO conventions and path semantics are smaller specifications that should be
written into their owning phases before coding begins.
