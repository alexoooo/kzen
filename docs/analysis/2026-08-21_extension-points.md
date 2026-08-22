# Extension points — third-party objects, UI without recompiling, design-time lifetime

> **Status: design exploration.** Written 2026-08-21 from the design conversation that revised
> [`2026-08-20_job-data-source.md`](2026-08-20_job-data-source.md). These three concerns surfaced
> there but are not about data sources — they are about how *any* third-party object gets into a
> project, how it gets a UI, and what owns resources it needs outside a run. Nothing here is
> scheduled. Decisions are marked **[decided]** / **[open]** as in the sibling doc; per CC-20 no line
> numbers are cited.

## 1. Third-party objects arrive as dynamically loaded jars + yaml **[decided]**

The need is general: define arbitrary Custom objects and include them from third-party libraries,
loaded at project startup, with a project reload to pick up a change. A data source is just one kind
of such object (sibling doc §4.1); a `DataSource`-specific SPI would be the wrong level.

The server side already has every hook:

- **Classes.** `@Reflect` objects are instantiated through the compile-time registry
  (`ReflectionRegistry.global`, populated by `kzen-lib-reflect-ksp`), but `GlobalMirror.register(delegate)`
  appends a fallback `ClassMirror`, consulted only on misses. A plugin jar compiled with
  `kzen-lib-reflect-ksp` carries its own `ModuleReflection`; at project startup the jar is opened on a
  `URLClassLoader` whose parent is `ClassLoaderUtils.dynamicParentClassLoader()` (the `PluginDocument`
  precedent for `ReportDefiner` formats), its module reflection is registered as a delegate, and its
  objects become constructible like any first-party archetype.
- **Notation.** The jar's yaml archetypes join the project's notation the same way the built-in
  `notation/auto-*` resources do. Capability-based classification (CC-17) means nothing in the app
  needs to know the new class names — a plugin source is found the way a first-party one is.
- **Lifetime.** Load at project startup; **reload the project to change**. Hot-swapping classloaders
  under live runs is not worth its complexity, and "reload" is also the natural close event for
  design-time resources (§3).

What this does *not* solve is the UI for such objects — §2.

### 1.1 Things to keep straight when building it

- The expression compiler (`CalculatedColumnEval`, `ClassLoaderUtils.dynamicParentClassLoader()`)
  must see plugin classes for objects-in-expression-scope to type-check against them — the same
  classloader threading the format-plugin path already does.
- `GlobalMirror`'s ordering rule — generated registrations shadow fallbacks — means a plugin cannot
  override a first-party class name. Good; state it.
- Re-registering the same delegate is a no-op, but a *new* `URLClassLoader` on reload is a new
  delegate; the old one must be removed, or the mirror chain grows per reload. `GlobalMirror` has no
  `unregister` today.

## 2. UI extension without recompiling the frontend

The frontend is a Kotlin/JS bundle (esbuild); attribute editors are `@Reflect` wrapper objects in the
JS registry, dispatched by the `editor:` metadata name through `AttributeWrapperLookup` →
`AttributeEditorManager`'s autowired `List<AttributeEditor>`. That name-dispatch is the seam; the
question is how a third party supplies what the name resolves to without rebuilding the bundle.

### 2.1 Table stakes: generic editors + a standard detached query protocol **[decided]**

**UI extension is a server-side thing by default.** A third-party object declares its attributes with
metadata (`is:`, enum `values:`, list / map / struct shape, "browse", "options from the object") and a
small vocabulary of **generic client editors** renders them: text, select, toggle, list, map, struct,
path-with-browse, pick-from-served-options. Anything dynamic — option lists, browse trees, previews,
validation — the object answers through a **standard detached protocol** (`options(attribute, prefix)`,
`browse(attribute, path)`, `preview()`, `validate()`), and one generic client component talks to it.
The plugin author writes zero JS; the UI grows by adding behaviour to the *server* object.

This already exists in embryo and is the kzen-native answer: `SelectValuesEditor` renders from
`values:`; `MultiFileInputEditor` browses through the generic `/file-listing` route; the data-source
card's resolve-preview / columns chrome calls the object as a `DetachedAction`. Generalizing that
vocabulary is what makes *first-party* objects cheap too.

### 2.2 Table stakes, second tier: server-described forms **[decided]**

When the metadata vocabulary would otherwise have to grow unreasonably, the object returns a **form
description** (fields, groups, types, conditional visibility) through the same detached protocol, and
one generic renderer draws it. Same zero-JS property as §2.1; use it only where §2.1 strains.

### 2.3 Escape hatch: Web Components **[decided]**

For a genuinely rich custom editor, the plugin jar ships a JS bundle the server serves under the
project's path prefix; the client loads it at startup and the bundle calls
`customElements.define('kzen-<plugin>-editor', …)`. The host renders `<kzen-<plugin>-editor>` with the
attribute notation as properties and listens for a `commit` event; `editor:` names the element, so the
notation contract is unchanged and `AttributeEditorManager` needs only a "custom element by name"
fallback.

Why Web Components rather than the alternatives:

- **vs. a dynamically loaded React editor.** Same "dynamically loaded JS", but through a platform API
  — no exposing the host's React instance, no `@JsExport` editor contract to version, no
  kotlin-wrappers coupling for plugin authors. Isolation and trust are the same (same document).
- **vs. an iframe.** An iframe cannot size to content or join the host's layout (drag/drop reorder,
  focus traversal, scroll containment), **clips dropdowns / popovers at the frame edge**, shares no
  theming, costs a document per instance, and needs its own postMessage state protocol. A Web
  Component participates in layout, overflows normally, can share theme tokens via CSS variables, and
  costs nothing per instance. If a plugin truly needs iframe isolation, **the Web Component can wrap
  one** — the host never has to know.

Three things to get right regardless of mechanism:

1. **The host is the single writer.** The element never touches the graph store; it emits a `commit`
   (attribute path + notation) and the host applies the `UpsertAttributeCommand`. Otherwise undo /
   redo, debounced commits and the `MirroredGraphStore` live-update path break. Inbound, the host
   pushes notation changes (other clients, the same page) into the element as property updates.
2. **Serve under the project prefix.** Plugin assets go out through the kzen-auto server under the
   project's path, so they still work behind kzen-shell's `/<process-name>/…` reverse-proxy contract.
3. **Trust.** A plugin's JS runs in the host document; the same jar already runs in-process on the
   server, so trust is already granted — but say so, and keep the commit path the only write path so
   the blast radius of a misbehaving element is one attribute, not the store.

### 2.4 Where a first-party team lands

§2.1 for everything; §2.2 where a form needs structure the vocabulary lacks; §2.3 reserved for the rare
rich editor. A data source with five fields and a browse ships no JS at all.

## 3. Design-time resource lifetime — an explicit `DesignSession` context **[decided in shape, not scheduled]**

> **Reduced 2026-08-21b** by the second-pass review of the data-source design
> ([`2026-08-20_job-data-source.md`](2026-08-20_job-data-source.md) §4, §13 D4). The run-time half of
> this problem is **not open**: a source **borrows** a resource from the run's Context registry
> (`Execution.resource` / `resourceValue`, disposal by declared `ResourceClosePolicy`) and never holds
> one, so the object itself stays stateless — which `GraphInstanceCache` and per-run
> `GraphCreator.createGraph` both require anyway. What remains open is only the **design-time owner**,
> and it is reached through one seam (`DataScope.contextValue`), so **no source changes** when the
> session below arrives. That also means this is not on any critical path: v1 is request-scoped
> open/close inside a `DesignDataScope`.

Contexts (`openResource` / close policies / `context.exports`) are run-scoped because a run is the only
lifetime kzen has. Design-time calls — detached actions serving browse / preview / schema — go through
`GraphInstanceCache`, whose reuse contract is "stateless objects". A file source is stateless; a JDBC
or API source needing a connection has nowhere to borrow one from outside a run. That is the gap.

Not to be solved now, and **not** to be solved with implicit timeouts — an idle lease on its own is how
locks and half-open handles get tangled. The explicit model:

- **A `DesignSession` context with an explicit owner and lifetime** — owned by the project, opened
  lazily on first use, closed on project reload / shutdown. Plugin reload-on-change (§1) and
  "close all design-time resources" become the *same* event.
- **Single owner, borrow-not-own.** Detached actions never hold resources; they borrow from the
  session (`session.borrow(key) { … }`), and the session serializes access per resource (a per-key
  mutex). Concurrent detached calls from a chatty UI cannot deadlock each other or leak, because only
  one thing owns.
- **Reuse the run-Context vocabulary.** Same `Context` abstraction, different owner; the close policy is
  a *declared* attribute on the context object (`ResourceClosePolicy` precedent): `onSessionClose`
  default, `perRequest` for cheap things, and *optionally* `idle(N)` as a visible declared policy —
  never an implicit behaviour. This is not aspiration: the run side already works exactly this way, and
  the session is the same vocabulary with the project as owner instead of a frame.
- **Visible.** The session's open resources are listable and closable from the UI, like a connections
  panel. If it can hold a lock, it is on the screen.

Until it exists: detached calls open and close what they need (correct, just slow), and cards resolve
on demand — a button or a debounce, cached by query digest — never on every render.
`GraphInstanceCache`'s stateless rule survives unchanged either way, because the *object* stays
stateless and the session holds the state — which is the same borrow-not-own rule the run side already
enforces, so a source is written once and works in both.

## 4. Open items

| # | Item | Recommendation |
|---|---|---|
| E1 | `GlobalMirror` needs an `unregister` (or replace-by-key) for reload | Add it with the loader; keyed by plugin id |
| E2 | The exact detached protocol vocabulary for §2.1 (`options` / `browse` / `preview` / `validate`) | Start from what the file browser and the data-source card already need; grow by customer, not upfront |
| E3 | Host ↔ Web Component contract (properties in, `commit` event out, theme tokens) | Design once with §2.1's generic editors as the first *internal* customer, so first- and third-party editors speak the same contract |
| E4 | `DesignSession` — when | **Downgraded 2026-08-21b.** Not a gate on anything: run-time lifetime is solved by Contexts, and the design-time owner is behind one seam (`DataScope.contextValue`). Request-scoped open/close until a real stateful source makes the slowness hurt |
