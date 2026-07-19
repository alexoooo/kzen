# AE1 — retire the flow/edit/*Old.kt fork — implementation plan

> **Status: ready to execute.** Generated 2026-07-19 from
> `2026-07-14_attribute-editor-improvements.md` **Phase 1** (which owns this item — supersedes
> EXT-S7 and the old Flow-plan FL5 bullet). Decisions pre-made in the constituent plan — do not
> re-litigate. Every anchor below re-verified against current kzen-auto master (`ceb699d0`) on
> 2026-07-19; drift from the constituent plan is called out inline (one snippet fix, one
> yaml-line-range fix). One session, small.

## Scope & goal

Delete the 5-file pre-refactor editor stack under
`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/flow/edit/` plus its
3-object notation registration block in `common-js.yaml`, after migrating the single live
consumer — `PluginController.renderPathEditor` — to the modern `TextAttributeEditor`. Pure
consolidation; the only user-visible surface is the Plugin document's jar-path field, which must
keep its exact behaviour (debounced persist + listing refresh) and gains flush-on-blur.

## Dependencies & coordination

- **Prerequisite-free** — master plan lists AE1 as a Sprint-2 filler ("any time",
  `2026-07-16_master-plan.md:120–123`).
- **Master-plan rule 5** (`:212–213`): AE1 must precede FL5's cleanup scope. FL5 is not being
  run yet — no action, just don't let FL5 start first.
- **Phase 3 (AE3) coordination**: AE3 later replaces `TextAttributeEditor`'s internal debounce
  with `AttributeCommitter`. That is internal to the editor — this migration's call-site contract
  (props) is unaffected. Deliberately migrate to `TextAttributeEditor`, **not**
  `AttributePathValueEditor` (Phase 4 deletes it — routing through it would be throwaway;
  pre-made decision).
- Single-repo change (kzen-auto only). kzen-lib untouched. `../kzen-project` grepped for
  `EditorOld|ManagerOld` — zero references; no downstream coordination.

## Current-state findings (anchors verified 2026-07-19)

**The 5 Old files** — all exist under
`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/flow/edit/`, and they are
the **entire content** of that package (directory empties on deletion):

| File | Notes |
|---|---|
| `AttributeEditorOld.kt` | abstract `ReactWrapper<AttributeEditorPropsOld>` base (:8–10); no `@Reflect` |
| `AttributeEditorPropsOld.kt` | props interface (clientState pushed via props — the old style) |
| `AttributeEditorManagerOld.kt` | `@Reflect` `Wrapper` autowiring `List<AttributeEditorOld>` (:33–45); **no host anywhere** — dead registration confirmed by whole-repo grep |
| `AttributePathValueEditorOld.kt` | the one live-consumed class; no `@Reflect` wrapper (used directly via `::class.react`) |
| `DefaultAttributeEditorOld.kt` | `@Reflect` `Wrapper` (:52–65); references `AttributePathValueEditorOld` via `createRef` (:48) + `isValue` (:138) |

**Consumer census** (grep `EditorOld|ManagerOld|PropsOld` over all of kzen-auto): the 5 files
themselves, `common-js.yaml`, `docs/js-architecture.md:311` (historical §7 inventory —
expected residue, stays), and exactly **one live code consumer**:
`plugin/PluginController.kt:13` (import) + `:211–227` (`renderPathEditor` renders
`AttributePathValueEditorOld`). The 5 files form a closed dependency cluster — nothing else in
any source set, test, or notation references them.

**Notation registration** —
`kzen-auto-jvm/src/main/resources/notation/auto-js/document/common-js.yaml`. The Old block is
**:57–81** (constituent plan said :60–78 — minor drift): section divider `#####…` at :57,
`AttributeEditorManagerOld` :60–66, `AttributeEditorOld` :68–74, `DefaultAttributeEditorOld`
:76–78, trailing blank lines to :81 (EOF). The keep-side of the file ends with
`ReferenceLinkAttributeView` (:52–54). Note there is an earlier divider at :28 (editors vs
views) — that one stays. `AttributePathValueEditorOld` has no yaml entry (never registered).

**PluginController current state** (`plugin/PluginController.kt`):
- Observes `ClientStateGlobal` (:128–135), holds `state.clientState` (:149–154); `render`
  guards on `clientState` + `tryMainLocation` (:193–198) before calling
  `renderPathEditor(mainObjectLocation, clientState)` (:205).
- `renderPathEditor` (:211–227) passes `labelOverride = "Plugin Jar File Path"`, `clientState`,
  `objectLocation`, `attributePath = PluginConventions.jarPathAttributeName.asAttributePath()`,
  `valueType = TypeMetadata.long` (the known latent oddity — moot after migration),
  `mirroredGraphStore`, `onChange = { loadInfo() }`.
- Imports to retire with it: `:13` (`flow.edit.AttributePathValueEditorOld`) and `:26`
  (`TypeMetadata` — its only use is :219).

**`TextAttributeEditor` contract** (`common/edit/TextAttributeEditor.kt:23–41`) — all snippet
props confirmed: `objectLocation: ObjectLocation`, `attributePath: AttributePath`,
`value: Any`, `type: TextAttributeEditor.Type?` (null → `PlainText`, :144),
`labelOverride: String?`, `onChange: ((String) -> Unit)?` (fired after apply, :133),
`mirroredGraphStore: MirroredGraphStore`; plus optional `disabled`/`invalid`/`InputProps`
(safe to omit — undefined is falsy). It syncs from `props.value` in `componentDidUpdate`
(:77–89, only when the prop actually changed — so in-flight typing is not clobbered by an
unrelated re-render) and flushes its debounce on **blur** (:175) and **unmount** (:110).

**Snippet drift found — `firstAttribute` overloads** (kzen-lib `GraphNotation.kt`): the
`(ObjectLocation, AttributeName)` overload (:263–270) returns **non-null** and throws on
missing; only the `(ObjectLocation, AttributePath)` overload (:277–288) is nullable. The
constituent plan's snippet calls the `AttributeName` overload with `?.` — an
unnecessary-safe-call warning. Use the `AttributePath` overload (snippet below, adjusted).
`AttributeName.asAttributePath()` (kzen-lib `AttributeName.kt:30`) and
`AttributeNotation.asString(): String?` (`AttributeNotation.kt:12`) confirmed.

**Value resolution is safe**: the Plugin archetype declares `jarPath: "path/to/plugin.jar"` +
`meta: jarPath: String` (`auto-common/common-document.yaml:374–376`), so the inheritance-chain
lookup always resolves for any real Plugin document; the `?: ""` fallback is pure defense.

## Pre-resolved questions (from the constituent plan — do not reopen)

1. **Target editor = `TextAttributeEditor`**, not `AttributePathValueEditor` (Phase 4 deletes
   the latter).
2. **`onChange` signature delta accepted**: Old passed `AttributeNotation`, new passes
   `String`; PluginController ignores the argument (`{ loadInfo() }`) either way.
3. **Flush-on-blur is a behaviour gain, not a regression** — the Old editor flushed only on
   unmount (its public `suspend fun flush()` had no caller). The blur-race smoke below
   validates the new wiring.
4. **`valueType = TypeMetadata.long` oddity dies with the migration** (a jar path is a String;
   `long` rendered as a plain text field anyway).
5. Docs residue (`docs/js-architecture.md:311`, historical §7 inventory) **stays** — expected
   grep hit, not a cleanup target.

## Step-by-step implementation

All three steps are **one change** — the yaml block and the `@Reflect` classes must go together
or client boot fails (see Risks). No new files; KSP regenerates `KzenAutoJsModule` on build
with no manual codegen edit.

**1. Migrate `PluginController.renderPathEditor`** (`plugin/PluginController.kt`):

Replace :211–227 with:

```kotlin
private fun ChildrenBuilder.renderPathEditor(mainObjectLocation: ObjectLocation, clientState: ClientState) {
    val jarPathAttributePath = PluginConventions.jarPathAttributeName.asAttributePath()

    val jarPath = clientState
        .graphStructure()
        .graphNotation
        .firstAttribute(mainObjectLocation, jarPathAttributePath)
        ?.asString()
        ?: ""

    TextAttributeEditor::class.react {
        objectLocation = mainObjectLocation
        attributePath = jarPathAttributePath
        value = jarPath
        labelOverride = "Plugin Jar File Path"
        onChange = {
            loadInfo()
        }
        mirroredGraphStore = props.mirroredGraphStore
    }
}
```

Import changes: remove :13 (`…flow.edit.AttributePathValueEditorOld`) and :26
(`…metadata.TypeMetadata`); add
`import tech.kzen.auto.client.objects.document.common.edit.TextAttributeEditor`. (No `type =`
needed — null defaults to `PlainText`, matching the Old plain-text render.)

**2. Delete the 5 files** (the whole `flow/edit/` package — nothing else lives there):

- `…/objects/document/flow/edit/AttributeEditorOld.kt`
- `…/objects/document/flow/edit/AttributeEditorPropsOld.kt`
- `…/objects/document/flow/edit/AttributeEditorManagerOld.kt`
- `…/objects/document/flow/edit/AttributePathValueEditorOld.kt`
- `…/objects/document/flow/edit/DefaultAttributeEditorOld.kt`

Delete all 5 together — they cross-reference each other, so a partial delete is a compile error
(which the build gate would catch anyway). Remove the then-empty `flow/edit/` directory.

**3. Remove the Old block from `common-js.yaml`**
(`kzen-auto-jvm/src/main/resources/notation/auto-js/document/common-js.yaml`): delete **:57–81**
— the second `################` divider (:57) plus the `AttributeEditorManagerOld` (:60–66),
`AttributeEditorOld` (:68–74), and `DefaultAttributeEditorOld` (:76–78) objects and trailing
blanks. The file then ends after `ReferenceLinkAttributeView` (:52–54) with a trailing newline.
Do **not** touch the :28 divider or anything above it. (The copy under
`kzen-auto-jvm/build/resources/main/…` is build output — regenerated by `processResources`,
never hand-edited.)

**4. Update the progress tracker** in
`kzen/plans/2026-07-14_attribute-editor-improvements.md`: tick Phase 1 with date + a one-line
as-built note (yaml block was :57–81 not :60–78; snippet adjusted to the nullable
`AttributePath` overload of `firstAttribute`).

Git hygiene: no new files (nothing to stage); deletions/edits show in the diff. Stage only,
never commit unless asked.

## Tests

No test changes. No JVM/JS test references the Old classes (whole-repo grep); kzen-auto-js has
no component unit tests (per plan baseline) — the compile + boot + manual smoke below are the
gate. `:kzen-auto-test:selfTest` is **not** required for Phase 1 (constituent plan mandates it
after phases 2, 3, 5 only); optional if paranoid.

## Verification

1. **Build gate**: `./gradlew :kzen-auto-js:build -x test` (KSP regen + JS compile), then full
   `./gradlew build`.
2. **Residue grep**: `EditorOld|ManagerOld|PropsOld` over the repo (excluding `build/`) —
   expect exactly one hit: `docs/js-architecture.md:311` (historical inventory; stays).
3. **Boot check**: `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` → browser loads
   with a clean console (no missing-reflection / instantiation errors — proves the yaml + KSP
   registration removal is consistent), sidebar populates.
4. **Plugin-document smoke** (the migrated surface): open an existing Plugin document if one
   exists, else create a scratch one via the UI (leave user files under `notation/main/`
   strictly alone; inspect yaml read-only):
   - Jar-path field renders as before (label "Plugin Jar File Path", full-width small
     TextField), pre-filled from notation.
   - Type a change → ~1 s debounce → value persists (read-only inspect of the document yaml or
     page reload) and the definer listing refreshes (`loadInfo` — with a bogus path the listing
     error message updates, which proves `onChange` fired after the write).
   - **Blur-race check**: type a change → immediately click elsewhere → the pending edit lands
     at once (flush-on-blur) — confirm in the yaml.
5. **Dead-registration sanity**: open a Flow document and a Script document — vertices/steps
   render and their attribute editors work (confirms nothing silently depended on the Old
   autowire chain; expected no-op since `AttributeEditorManagerOld` had no host).

## Risks & gotchas

- **yaml/class atomicity**: deleting the `@Reflect` classes while the `common-js.yaml` entries
  remain breaks client boot (notation declares classes the regenerated `KzenAutoJsModule` no
  longer registers). The safe partial order is yaml-first (classes become dead code), but plan
  is one change; if splitting under duress, never classes-first.
- **Grep pattern completeness**: `EditorOld` alone misses `AttributeEditorPropsOld` (its name
  contains `EditorProps`, not `EditorOld`) — always use `EditorOld|ManagerOld|PropsOld`. Also
  `TextAttributeEditor::class.react` greps substring-match `MultiTextAttributeEditor` — don't
  miscount call sites.
- **Stale build output**: `kzen-auto-jvm/build/resources/main/notation/...` retains the old
  yaml until the next `processResources`; ignore `build/` in residue greps.
- **`firstAttribute` overload trap**: the `(ObjectLocation, AttributeName)` overload throws on
  missing; use the `(ObjectLocation, AttributePath)` overload + `?: ""` as in the snippet
  (also avoids the unnecessary-safe-call warning — the constituent plan's original snippet had
  this wrong).
- **Unmount-flush against a deleted document** (pre-existing, unchanged): if the Plugin
  document is deleted mid-debounce, the unmount flush fires a command that fails to the global
  banner — same behaviour as the Old editor; not in scope.
- **Fresh `onChange` lambda per render** defeats `RPureComponent`'s shallow-equal on
  `TextAttributeEditor` — identical to every existing call site (Report/Job controllers); not a
  regression, do not "fix" here (Phase 3/6 territory if ever).

## Out of scope

- Phases 2–6 of the constituent plan (SelectClosePolicy migration, `AttributeCommitter`,
  PathValue→Default merge, select-of-reference base, hygiene) — including any change to
  `TextAttributeEditor` internals.
- FL5 / Flow editing UX (this item merely unblocks its cleaned-up scope).
- Editing `docs/js-architecture.md` (the :311 mention is a deliberately-historical inventory).
- Anything under `notation/main/` (user working documents — read-only during smoke).
- Renaming/moving any surviving editor or registration.
