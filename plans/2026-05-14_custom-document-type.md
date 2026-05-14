# Plan — Add `CustomDocument` document type (raw-YAML editor)

## Context

kzen-auto currently supports 7 document archetypes (`Sequence`, `Graph`, `Feature`, `DataFormat`, `ObjectRegistry`, `Report`, `Plugin`), each with a typed schema and a structured editor in the JS frontend. Every document has the shape:

```yaml
main:
  is: <ArchetypeName>
  <attributes>
```

There is no way to define **arbitrary object definitions** in a document — you can only fill in the schema dictated by the archetype's `meta:` block.

This plan adds an eighth archetype, `CustomDocument`, whose body is a free-form set of object definitions edited as raw YAML. The `main` object is fixed (`main: { is: CustomDocument }`) so the document keeps its identity; everything *below* `main` is user-authored YAML that will be parsed back into the notation graph and re-published to all observers (other clients, the definition layer, etc.).

This unlocks: defining ad-hoc helper objects, prototyping new SPI implementations without scaffolding a typed editor, and giving power users an escape hatch when the structured editors don't fit.

### Design decisions (locked in)

| Question | Decision |
|---|---|
| Name | **`CustomDocument`** |
| Save model | **Explicit Save button** (Ctrl+S as alt) — no autosave, parse-time errors live in the editor until the user fixes them |
| Schema policy | **No archetype-locking anywhere — power tool, trust the user.** The notation layer is unconstrained; errors surface at the definition layer on next reload. The server endpoint just parses and dispatches; the JS controller shows the full document and lets the user edit any of it, including `main`. |
| Editor library | **Plain `<textarea>` for v1.** Syntax highlighting is a follow-up. Keeps the bundle change at zero and the migration story clean. |
| What the editor shows | **Full document, including `main`.** No strip/reassemble. The user can change `main.is`, break the archetype marker, or delete `main` entirely — they own the consequences. |

## High-level approach

1. Declare `CustomDocument` as a new archetype in `common-document.yaml`. Add a minimal `CustomDocument` Kotlin class in `kzen-auto-jvm`.
2. Add a new bulk-edit notation command, `SetDocumentObjectsCommand`, in `kzen-lib` — it replaces a document's full `DocumentObjectNotation` atomically. This is the only way the raw editor can publish its edits without issuing dozens of per-attribute commands.
3. Add a REST endpoint in `kzen-auto-jvm` that takes the full document YAML, parses it via `YamlNotationParser.parseDocumentObjects`, and dispatches `SetDocumentObjectsCommand`. No archetype or schema validation in the handler — it's a generic "set document objects" RPC.
4. Add the corresponding `RestClient` method on the JS side.
5. Build a minimal `YamlEditor` Kotlin/JS component (textarea + line gutter + error display) under `objects/document/common/edit/`.
6. Build `CustomDocumentController` (the JS `DocumentController`) that loads the current document, deparses it with `YamlNotationParser.unparseDocument`, hosts the editor showing the full document YAML (including `main`), and wires Save.
7. Register the controller via `auto-js/document/custom-js.yaml` and regenerate `KzenAutoJsModule.kt`.
8. Polish, tests, and AGENTS.md update.

The work is sequenced so every step is independently buildable and testable.

## Critical files (existing) referenced by the plan

| Layer | Path | Why |
|---|---|---|
| Notation model | `../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/structure/notation/DocumentNotation.kt` | The data type we're replacing wholesale per-document |
| Commands | `../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/structure/notation/cqrs/NotationCommand.kt` | Hierarchy to extend with `SetDocumentObjectsCommand` |
| Events | `../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/structure/notation/cqrs/NotationEvent.kt` | Add matching `SetDocumentObjectsEvent` |
| Reducer | `../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/notation/NotationReducer.kt` | Wire the command's reduce case |
| YAML parse/deparse | `../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/parse/YamlNotationParser.kt` (`parseDocumentObjects` line 18, `unparseDocument` line 110) | Reuse on both server and client; **deparser does NOT preserve comments** — accept this for v1 |
| Notation conventions | `../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/notation/NotationConventions.kt` | `mainObjectPath`, `isAttributeName` for the main-preserved validator |
| Archetype catalogue | `../kzen-auto/kzen-auto-jvm/src/main/resources/notation/auto-common/common-document.yaml` | Add `CustomDocument` archetype entry |
| Doc archetype helper | `../kzen-auto/kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/DocumentArchetype.kt` | Pattern for the new `CustomDocument` server class |
| Existing simple server doc | `../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/plugin/PluginDocument.kt` (use as a template) | |
| Doc-type controller dispatch | `../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/StageController.kt:217-229` | No changes needed — dispatch is reflection-based |
| Sidebar "New" menu | `../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/sidebar/SidebarFolder.kt:410-442` | No changes — auto-picks up the new archetype from notation |
| `DocumentController` interface | `../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/DocumentController.kt` | Three methods to implement: `archetypeLocation`, `header`, `body` |
| Template simple controller | `../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/plugin/PluginController.kt` | Closest pattern to copy |
| Codegen module | `../kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/codegen/KzenAutoJsModule.kt` (banner: "automatically generated by ModuleReflectionGenerator") | Must be regenerated after adding `custom-js.yaml`; find `ModuleReflectionGenerator` and run it |
| REST endpoint inventory | `../kzen-auto/kzen-auto-jvm/src/main/kotlin/.../RestHandler.kt` (`applyCommand` at line ~752) | Add a new handler method following the existing pattern |
| API path/param constants | `../kzen-lib/kzen-lib-common/src/commonMain/kotlin/.../api/CommonRestApi.kt` (search for `apply-` prefixed endpoint names) | Add new path + param keys |
| JS REST client | `../kzen-auto/kzen-auto-js/src/jsMain/kotlin/.../service/rest/RestClient.kt` | Add new method mirroring the new endpoint |

## Steps (one per session)

### Step 1 — Archetype declaration + minimal server class

**Goal:** `CustomDocument` shows up in the sidebar "New …" menu, creating one writes a valid YAML file, and opening it falls back to `StageController`'s "Document: CustomDocument" placeholder (because no JS controller is registered yet — that's expected for this step).

**Edits:**
- `kzen-auto/kzen-auto-jvm/src/main/resources/notation/auto-common/common-document.yaml` — append a `CustomDocument` entry following the pattern of `Plugin` (the simplest existing archetype). Set `title: "Custom"`, `icon: Code` (Iconify icon name).
- `kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/custom/CustomDocument.kt` — new file. Empty class extending `DocumentArchetype`. No fields, no behavior. Matches `class:` in the YAML.

**Verify:**
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:classes`
- Start `BackendDevelopment` + `FrontendDevelopment` (or just run the standard kzen-auto dev loop), check the sidebar shows "New Custom..."; create one; open the produced `.kzen.yaml` on disk and confirm contents are `main:\n  is: CustomDocument\n`.

**Risk:** None significant — purely additive.

---

### Step 2 — `SetDocumentObjectsCommand` in kzen-lib — **DONE**

**Goal:** A new structural command that replaces a document's entire `DocumentObjectNotation` atomically, with a matching event. Unit-tested.

**Edits made:**
- `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/structure/notation/cqrs/NotationCommand.kt` — added `data class SetDocumentObjectsCommand(val documentPath, val documentObjectNotation): StructuralNotationCommand()`.
- `.../cqrs/NotationEvent.kt` — added `data class SetDocumentObjectsEvent(documentPath, documentObjectNotation): SingularNotationEvent()` (note: the existing event hierarchy uses `SingularNotationEvent`/`CompoundNotationEvent`, not a `StructuralNotationEvent` — the plan's draft name was off).
- `.../structure/notation/DocumentNotation.kt` — added `withObjects(objects)` helper (copy, preserves `resources`).
- `.../service/notation/NotationReducer.kt` — new `setDocumentObjects` private fn + `when`-arm in `applyStructural`.
- `kzen-lib-common/src/commonTest/kotlin/tech/kzen/lib/common/notation/SetDocumentObjectsTest.kt` — replace happy path, `main: { is: CustomDocument }` round-trip, `resources` preservation for directory documents, rejection of unknown document path.
- Verified `:kzen-lib-common:jvmTest` (new + existing) green, `:compileKotlinJs` green, `publishToMavenLocal` succeeded for all three subprojects, downstream `:kzen-auto-jvm:compileKotlin` green against the new snapshot.

**Edits (all in `../kzen-lib`):**
- `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/structure/notation/cqrs/NotationCommand.kt` — add `data class SetDocumentObjectsCommand(val documentPath: DocumentPath, val objects: DocumentObjectNotation): StructuralNotationCommand()`.
- `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/model/structure/notation/cqrs/NotationEvent.kt` — add `data class SetDocumentObjectsEvent(val documentPath: DocumentPath, val objects: DocumentObjectNotation): StructuralNotationEvent()`.
- `kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/notation/NotationReducer.kt`:
  - extend the `applyStructural` `when` block with a branch for the new command
  - implementation: `check(state.documents.map.containsKey(command.documentPath))`, then `state.withModifiedDocument(command.documentPath, currentDoc.withObjects(command.objects))` — preserving `resources` from the existing `DocumentNotation`.
  - If `DocumentNotation` doesn't have a `withObjects` helper, add one (immutable copy with new `objects`, same `resources`).
- Unit test in `kzen-lib-common/src/commonTest/kotlin/.../NotationReducerTest.kt` (or wherever existing reducer tests live — Grep for `NotationReducerTest`). Cover: replace happy path, non-existent document path, preservation of `resources` for directory documents.

**Verify:**
- `cd ../kzen-lib && ./gradlew :kzen-lib-common:allTests`
- `cd ../kzen-lib && ./gradlew publishToMavenLocal` (so kzen-auto sees the new snapshot — required by the cross-sibling variant-coord rule from kzen umbrella AGENTS.md).

**Risk:** kzen-lib also drives kzen-project; verify `cd ../kzen-project && ./gradlew build` doesn't regress (the new command is additive).

---

### Step 3 — REST endpoint for raw-YAML save — **DONE**

**Goal:** A new POST endpoint that takes raw YAML for the non-`main` portion of a CustomDocument, prepends the synthetic `main` block, parses+validates, and dispatches `SetDocumentObjectsCommand`. Testable via curl/HTTP.

**Edits made:**
- `kzen-auto-common/.../api/CommonRestApi.kt` (note: lives in kzen-auto-common, not kzen-lib as the plan draft said) — added `commandDocumentSetObjects = "/command/document/set-objects"` and `paramRawObjectsYaml = "raw-objects-yaml"`.
- `kzen-auto-jvm/.../server/api/RestHandler.kt` — new `setDocumentObjects(parameters): String`. Reads `paramDocumentPath` and parses `paramRawObjectsYaml` via `yamlNotationParser.parseDocumentObjects`, then dispatches `SetDocumentObjectsCommand` through `applyCommand` (digest response, same as all other handlers). **No archetype check, no `main` check — generic "set document objects" RPC.** Parser errors bubble up as `IllegalArgumentException` → 400 via the route's try/catch.
- `kzen-auto-jvm/.../server/KzenAutoMain.kt` — `put(CommonRestApi.commandDocumentSetObjects)` route in `routeNotationCommands`, wraps the call in try/catch IllegalArgumentException → 400 with the message (parser errors, missing main, wrong archetype, missing params all bubble through `IllegalArgumentException`).
- Verified `:kzen-auto-jvm:compileKotlin` green and `:kzen-auto-common:compileKotlinJs` green.

**Edits:**
- `kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/api/CommonRestApi.kt` — add path constant `applySetDocumentObjects = "apply-set-document-objects"` and a `paramRawObjectsYaml` parameter key. Place near similar `apply-*` constants for consistency.
- `kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/api/RestHandler.kt`:
  - register a route for the new path
  - handler: extract `documentPath` and `rawObjectsYaml` params, construct full YAML = `"main:\n  is: CustomDocument\n\n" + rawObjectsYaml`, parse via `YamlNotationParser().parseDocumentObjects(full)`, build `SetDocumentObjectsCommand`, call `applyCommand(command)`.
  - Validation order: (1) the parsed `DocumentObjectNotation` must contain `mainObjectPath`; (2) its `is:` attribute must be `CustomDocument`; (3) only then dispatch. Surface parse errors as 400 with the message.
- (Defer JS-side client method to Step 4.)

**Verify:**
- Build kzen-auto-jvm: `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:jar`
- Hand-craft a curl POST from a `.http` scratch (place under `$env:TEMP`, not in the repo per the no-root-scratch-files rule) and confirm a known-good YAML body saves; confirm a body with broken indentation returns a clean 400.

**Risk:** Cache invalidation in `FileNotationMedia` — the existing write path handles this for all other commands, so reusing the same `applyCommand` path should inherit the behavior. Worth a quick read of `FileNotationMedia.writeDocument` to confirm.

---

### Step 4 — JS `RestClient` method + YAML deparse helper — **DONE**

**Goal:** Frontend can call the new endpoint. Helper to format the current notation as YAML text for display.

**Edits made:**
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/rest/ClientRestApi.kt` (note: the file is `ClientRestApi.kt`, not `RestClient.kt` as the plan draft said) — added `suspend fun setDocumentObjects(documentPath, unparsedDocumentObjects): Digest`. Returns `Digest` to match every other `command*` method in the class (the plan draft's `NotationEvent` return type was wrong — peers return `Digest`). Placed right after `deleteDocument` to keep document-level commands grouped. Uses `getOrPutDigest` which auto-switches to `httpPutForm` once the URL would exceed the 1024-char `getSizeLimit` — full-document YAML payloads will be PUT-as-form, matching the server route added in Step 3.
- No separate deparse helper needed — `YamlNotationParser().unparseDocument(...)` is already in commonMain, and per the (c) decision Step 6 will pass the full document YAML through verbatim (no main-block stripping).
- Verified `:kzen-auto-js:compileKotlinJs --rerun-tasks` BUILD SUCCESSFUL.

**Risk acknowledged for follow-up:** `unparseDocument` ignores its `previousDocument` parameter (see parser source); comments and key order from the on-disk file are not preserved through the deparse-edit-parse round trip. **Accept for v1.** Surface in editor help text in Step 6.

---

### Step 5 — `YamlEditor` widget (plain textarea) — **DONE**

**Goal:** A reusable React component: `value: String`, `onChange: (String) -> Unit`, `error: String?`, `disabled: Boolean`. Monospace font, line-height matched to a left-side line gutter (CSS, not a real editor). Used by `CustomDocumentController` in Step 6 — could be reused later for resource editing.

**Edits made:**
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/common/edit/YamlEditor.kt` — new file. Pure controlled `RPureComponent<YamlEditorProps, State>` (no internal state, parent owns `value`). Raw `<textarea>` (not MUI `TextField`) so we can put a sibling line-number `<div>` next to it; MUI's wrapper structure would have made the gutter awkward. Flex row: gutter div + textarea. Styled with `FontFamily.monospace`, `WhiteSpace.pre`, `tabSize = 2`, 1.4em line-height shared by gutter and textarea so the numbers stay aligned. Error block below the editor (red border + faint red fill, `preWrap` so multi-line server messages stay readable) rendered only when `props.error != null`.
- Notes for Step 6 / Step 8: (a) gutter does NOT scroll-sync with the textarea — fine for typical small CustomDocument files; scroll-sync is in Step 8 polish. (b) Cast `as HTMLTextAreaElement` was unnecessary for the raw element's onChange (compiler warning); the React-wrappers typing is precise on the HTML element directly. (c) No `disabled` styling beyond `disabled` attribute itself — the textarea greys out via browser default.
- Verified `:kzen-auto-js:compileKotlinJs` BUILD SUCCESSFUL, no warnings.

---

### Step 6 — `CustomDocumentController` (the `DocumentController` impl) — **DONE**

**Edits made:**
- `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/custom/CustomConventions.kt` — new file. Mirrors `PluginConventions` exactly: `fun isCustomDocument(documentNotation): Boolean` checking `main.is == "CustomDocument"`. **Plan correction:** plan said put this in `kzen-auto-js`, but all 5 peer `*Conventions` classes (Plugin, DataFormat, ObjectRegistry, Report, Sequence) live in `kzen-auto-common`. Following peer pattern.
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/custom/CustomDocumentController.kt` — new file. Shape mirrors `PluginController`: outer `Wrapper` class (`@Reflect`, holds archetype, returns `DocumentController` interface methods); inner React `RPureComponent` that's a `ClientStateGlobal.Observer`. State: `clientState`, `loadedFor: DocumentPath?`, `editorValue`, `savedValue`, `saving`, `lastError`. Header is empty; body renders Save button + "unsaved changes" indicator + `YamlEditor`.
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/rest/ClientRestGraphStore.kt` — added arm for `SetDocumentObjectsCommand` that calls `notationParser.unparseDocument(...)` then `restClient.setDocumentObjects(...)`.

**Plan correction — save flow:** plan said "direct `restClient.setDocumentObjects` → observer chain flows new state in". This is wrong: I traced through `MirroredGraphStore` and `ClientStateGlobal` — observers fire *only* when `mirroredGraphStore.apply()` runs (which the direct REST call would bypass). Direct REST would leave the local graph stale until next page reload, breaking the multi-tab scenario and post-save state refresh.

**Actual save flow:**
1. Controller parses user YAML client-side via `notationParser.parseDocumentObjects` (catches parse errors locally — surface in editor before any network).
2. Builds `SetDocumentObjectsCommand(documentPath, parsedNotation)`.
3. `ClientContext.mirroredGraphStore.apply(command)` — applies locally (NotationReducer arm from Step 2), AND remotely (newly added `ClientRestGraphStore` arm dispatches to the Step 3 REST endpoint).
4. On `MirroredGraphSuccess`: set `serverNotation = parsed` only. **Do NOT touch `editorValue`** — the user's formatting (whitespace, key order, comment placement) is preserved.
5. On `MirroredGraphError`: surface `error.message` in the editor; leave editor content untouched so user can fix and retry.
6. The observer chain (`ClientStateGlobal` → `onClientState` → `syncFromClientState`) still fires after `apply()` — handles cross-tab updates and document-switch resets.

**"Modified" detection is semantic, not textual.** State holds `serverNotation: DocumentObjectNotation?` (the last-known parsed server state), not a `savedValue: String`. `isEditorModified()` parses the current `editorValue` and compares structurally to `serverNotation`. This means:
- After a successful save: `parse(editorValue) == serverNotation` → modified=false, even though the user's text isn't byte-equal to `deparse(serverNotation)`.
- Whitespace and key-order edits don't trigger spurious "modified".
- Unparseable text counts as modified (Save remains enabled; click → surfaces parse error).

**Earlier (wrong) approach** considered: force-set `editorValue = deparse(parsed)` on save success to make string comparison work. Rejected — that would silently overwrite the user's formatting choices the instant they hit Save, which is hostile UX for a power-tool YAML editor.

**Document-switch / external-update logic in `syncFromClientState`:**
- Initial load OR new documentPath → set `editorValue = deparse(newServerNotation)` and `serverNotation = newServerNotation`.
- Same documentPath, server notation unchanged → no-op.
- Same documentPath, server notation changed externally, AND user has no pending edits (`!isEditorModified()`) → refresh both `editorValue` and `serverNotation` from the new server state. Safe because user has nothing to lose.
- Same documentPath, server notation changed externally, user HAS pending edits → update `serverNotation` only. User's text stays in the editor; the "modified" comparison now reflects the new server truth (and if their edits happen to match the new server state, the flag clears). Per [[surface-scope-expansion]]: trusting the user means if they then click Save, their edits *will* overwrite the other client's changes — power-tool semantics, option (c).

**Verified:** `:kzen-auto-js:compileKotlinJs`, `:kzen-auto-common:compileKotlinJvm`, `:kzen-auto-jvm:compileKotlin` all BUILD SUCCESSFUL.

---

### Step 6 (original plan text) — for historical reference

**Goal:** Mount the YamlEditor for the open CustomDocument, load its body, show a Save button + an unsaved-changes indicator, call Step 4's RestClient method on save.

**Edits:**
- `kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/custom/CustomDocumentController.kt` — new file. Copy the shape of `PluginController.kt` (`Wrapper` class with `@Reflect`, `archetypeLocation/header/body`, `RPureComponent`, `ClientStateGlobal.Observer`). State holds: `clientState`, `editorValue: String`, `savedValue: String`, `lastError: String?`, `saving: Boolean`. Logic:
  - On `onClientState`: if the active document is a CustomDocument and `editorValue == savedValue` (no pending edits), regenerate `savedValue` from the new notation by deparsing the *full* `DocumentObjectNotation` (no stripping — main stays visible) and set `editorValue = savedValue`. If there are pending edits, only update `savedValue` — do NOT touch `editorValue`.
  - Render: header with a Save button (disabled when `editorValue == savedValue` or `saving == true`), an "unsaved changes" indicator when they differ, and the `YamlEditor` in the body with `error = lastError`.
  - Save flow: `setState { saving = true }` → `ClientContext.restClient.setDocumentObjects(documentPath, editorValue)` → on success, the LocalGraphStore observer chain will flow the new state in via `onClientState`; on failure, `setState { saving = false; lastError = message }`.
- `kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/custom/CustomConventions.kt` — small helper with `fun isCustomDocument(notation: DocumentNotation): Boolean` (check `main`'s `is:` == `CustomDocument`). Used only for the controller's "should I activate?" check, NOT enforced on save.

**Verify:**
- Manual end-to-end in the dev loop: create a CustomDocument, type some object definitions, Save, reload the page, confirm content persists.
- Save with broken YAML — confirm the error appears and the editor is not reset.

**Risk:** None of the previously-drafted "strip the leading `main:` block" complexity — option (c) trust-the-user means the editor shows the full doc and the controller passes it through verbatim.

---

### Step 7 — Register the JS controller and end-to-end smoke — **DONE (codegen portion)**

**Edits made:**
- `kzen-auto-jvm/src/main/resources/notation/auto-js/document/custom-js.yaml` — new file. Standard `is: DocumentController`, `class: tech.kzen.auto.client.objects.document.custom.CustomDocumentController$Wrapper`, `archetype: CustomDocument`.
- `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/codegen/KzenAutoJsModule.kt` — regenerated. New `reflectionRegistry.put(..."CustomDocumentController$Wrapper", listOf("archetype")) { args -> CustomDocumentController.Wrapper(args[0] as ObjectLocation) }` block at line ~61.

**How codegen was invoked:** `KzenAutoJsCodegen.main` lives in `kzen-auto-jvm/src/test/kotlin` but has no registered Gradle task. Used a one-off `--init-script` (in `$env:TEMP`, deleted after) that registered a transient `JavaExec` task `:kzen-auto-jvm:runJsCodegen` against `sourceSets["test"].runtimeClasspath` with `workingDir = rootProject.rootDir` (because `KzenAutoJsCodegen` uses a relative `Paths.get("kzen-auto-js/src/jsMain/kotlin")`). Init script content (for future reference, NOT committed):
```kotlin
import org.gradle.api.tasks.SourceSetContainer
allprojects { afterEvaluate { if (name == "kzen-auto-jvm") {
    val sourceSets = extensions.getByName("sourceSets") as SourceSetContainer
    tasks.register<JavaExec>("runJsCodegen") {
        mainClass.set("tech.kzen.auto.server.codegen.KzenAutoJsCodegen")
        classpath = sourceSets["test"].runtimeClasspath
        workingDir = rootProject.rootDir
    }
}}}
```
Worth considering for Step 8: register `runJsCodegen` / `runJvmCodegen` / `runCommonCodegen` as permanent tasks in `kzen-auto-jvm/build.gradle.kts` so future agents don't need the init-script trick. Out of scope here.

**Follow-up done (2026-05-14):** the four `runCommonCodegen` / `runJsCodegen` / `runJvmCodegen` / `runAllCodegen` JavaExec tasks are now registered in `kzen-auto-jvm/build.gradle.kts` (group `codegen`). `docs/architecture.md § 8` and `docs/js-architecture.md` table updated to point at these tasks instead of saying "no Gradle task wired — invoke it manually." Verified `:kzen-auto-jvm:runJsCodegen` BUILD SUCCESSFUL.

**Verified:** `:kzen-auto-js:compileKotlinJs` BUILD SUCCESSFUL after regeneration.

**Pending (deferred to next session):** Full kzen-auto `./gradlew build` plus manual end-to-end smoke in dev mode: create a CustomDocument, confirm `StageController` mounts `CustomDocumentController`, type sample object definitions, Save, reload, confirm persistence; also confirm Report/Plugin docs still render.

---

### Step 8 — Polish, error UX, docs — **PARTIAL DONE**

**Done (2026-05-14):**
- `YamlEditor` — Ctrl/Cmd+S triggers Save via new `onSave: (() -> Unit)?` prop, and the line-number gutter scrolls in lockstep with the textarea via a `RefObject<HTMLDivElement>` + `onScroll` mirroring `scrollTop` (gutter gets `overflow: Overflow.hidden` so programmatic scroll works without a visible scrollbar). Save shortcut is gated by `! disabled` and a `! shiftKey && ! altKey` modifier check to avoid stealing Ctrl+Shift+S etc.
- `CustomDocumentController` — passes `onSave = ::onSave` through to YamlEditor, and `onSave()` now early-returns when `! isEditorModified()` so spamming Ctrl+S after a save doesn't issue redundant command round trips.
- `kzen-auto/AGENTS.md` — `objects/document/` row in the key-directories table now points at `custom/` and the `SetDocumentObjectsCommand` semantics, cross-linking to architecture.md § 6.
- `kzen-auto/docs/architecture.md § 6` — added `custom/` row to the document-types table and a new "`CustomDocument` — raw-YAML escape hatch" subsection documenting parse/save flow, power-tool semantics (no archetype/schema enforcement), and the comment/key-order non-preservation caveat.
- `kzen-auto/docs/js-architecture.md § 3` — added a paragraph explaining that `custom/` is the exception to the document folder convention (no sub-stores, no `model/`), with the editor widget under `common/edit/` and the controller under `custom/`.

**Deferred (out of v1):**
- Surface parse-error line numbers — `YamlParser` throws `IllegalArgumentException` with a character index in the error message but no structured line/column, and there's no public API to convert. Would require either a YamlParser refactor or a post-hoc helper that scans the document to convert offset → (line, col). Skip for v1; current error block shows the raw parser message which is usually enough.
- "Unsaved changes" indicator in the document title bar — `header()` in `DocumentController` is dead code (StageController only invokes `body()`), so the existing in-body "unsaved changes" span is already the right placement. No header-level dot/suffix added.
- Server-side parse-error wire format with line numbers — gated on the parser refactor above. Saves go via `mirroredGraphStore.apply(SetDocumentObjectsCommand)` which surfaces errors through the existing `MirroredGraphError` channel; no new error format introduced.

**Optional follow-ups (do NOT ship in this plan):**
- CodeMirror 6 syntax highlighting (would unblock proper YAML/Kzen highlighting + native gutter, but adds an NPM dep).
- Live validation while typing (debounce, parse, surface error block before save).
- Comment & key-order preservation in `YamlNotationParser.unparseDocument` (currently ignores the `previousDocument` parameter).

**Original goal text (for reference):**
Real-world readiness.

**Edits / tasks:**
- Editor: line-number gutter syncs with scroll, Ctrl+S handler triggers Save.
- Error display: when the server rejects with a parse error, surface the line number in the error message (the existing YamlParser throws with a position; expose it through the REST handler's error response).
- "Unsaved changes" indicator in the header (e.g., a `•` next to the title, or "(modified)" suffix).
- `kzen-auto/AGENTS.md` — add a short subsection under doc-type catalogue describing CustomDocument, its YAML shape, and the `SetDocumentObjectsCommand` it uses.
- `kzen-auto/docs/architecture.md` or `js-architecture.md` — mention the new command and editor pattern if those docs catalogue per-type editors.
- If `ModuleReflectionGenerator` was punted in Step 7, run it cleanly here and remove the `// MANUAL EDIT` marker.
- Optional follow-up tickets (do NOT ship in this plan): CodeMirror 6 syntax highlighting; live validation pre-save; comment preservation in deparser.

**Verify:**
- Re-run full kzen-auto build.
- Cross-sibling smoke: `cd ../kzen-project && ./gradlew build` (CustomDocument only lives in kzen-auto, so kzen-project should be unaffected — confirm).

---

## Verification (across the whole change)

End-to-end test scenarios to walk through manually after Step 7:

1. **Create**: sidebar → "New Custom..." → file appears on disk with `main:\n  is: CustomDocument\n`.
2. **Edit + Save**: open the new doc, paste a sample object like:
   ```yaml
   MyHelper:
     class: java.lang.String
   ```
   Save. Reload the page. Confirm content is still there.
3. **Parse error**: type intentionally broken YAML (`foo: [unclosed`). Save. Confirm a red error block appears and the editor still holds the bad text.
4. **Other doc types unaffected**: open a `Report` doc, confirm it renders normally; open `Plugin`, same.
5. **No archetype enforcement (power-tool semantics)**: with curl, send a save body that changes `main.is` to `Report` or omits `main` entirely. Server accepts; on next reload the document either changes type or surfaces a definition-layer error. This is intentional — the user owns the consequences.
6. **Two clients**: open the same CustomDocument in two browser tabs. Save in tab A. Confirm tab B's editor updates to the new content (assuming no unsaved edits in tab B).
7. **No regression in kzen-project**: `cd ../kzen-project && ./gradlew build` passes.

Automated:
- `cd ../kzen-lib && ./gradlew :kzen-lib-common:allTests` — new `SetDocumentObjectsCommand` reducer tests pass.
- `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test --tests "*FormulaStepTest"` — the canary from kzen umbrella AGENTS.md (toolchain-bump check; should be unaffected, but cheap).

## Open items / future work (explicitly out of scope)

- **Syntax highlighting** — defer to follow-up; v1 ships with a plain textarea.
- **Comment preservation** — the YAML deparser rebuilds from notation and drops comments. Documented limitation for v1.
- **Schema-level constraints on the freeform objects** — none for now; errors surface at the definition layer (when something else tries to reference an object that doesn't define). Future: a "Validate" button that runs the definition pipeline and surfaces issues without saving.
- **References from other documents to objects defined in a CustomDocument** — should "just work" because they all flow into the same `GraphNotation`; worth an explicit test once the dust settles.
- **Resources** — `CustomDocument` is a file document (no `directory: true`), so no resource attachments. Revisit if users want them.