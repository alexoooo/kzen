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

### Step 4 — JS `RestClient` method + YAML deparse helper

**Goal:** Frontend can call the new endpoint. Helper to format the current notation as YAML text for display.

**Edits (all in `../kzen-auto`):**
- `kzen-auto-js/src/jsMain/kotlin/.../service/rest/RestClient.kt` — add `suspend fun setDocumentObjects(documentPath: DocumentPath, rawObjectsYaml: String): NotationEvent` (or whatever the existing `apply*` methods return — match the pattern). Use `CommonRestApi.applySetDocumentObjects`.
- No separate helper file needed — `YamlNotationParser().unparseDocument(...)` is already in commonMain. The CustomDocumentController will deparse the current `DocumentObjectNotation` from `ClientState`, then strip the `main:` block from the resulting string for display.

**Verify:**
- Build: `cd ../kzen-auto && ./gradlew :kzen-auto-js:browserDevelopmentWebpack` (or whichever incremental task fits the dev loop). Build must succeed even though no controller calls the new method yet.

**Risk:** `unparseDocument` ignores its `previousDocument` parameter (see parser source); comments and key order from the on-disk file are not preserved through the deparse-edit-parse round trip. **Accept this for v1.** Document it in the editor's help text in Step 6.

---

### Step 5 — `YamlEditor` widget (plain textarea)

**Goal:** A reusable React component: `value: String`, `onChange: (String) -> Unit`, `error: String?`, `disabled: Boolean`. Monospace font, line-height matched to a left-side line gutter (CSS, not a real editor). Used by `CustomDocumentController` in Step 6 — could be reused later for resource editing.

**Edits:**
- `kzen-auto/kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/common/edit/YamlEditor.kt` — new file. `<textarea>` styled with `font-family: monospace`, `white-space: pre`, `tab-size: 2`. Line gutter via a side `<div>` rendered from `value.split('\\n').size`. Error block below the textarea (red, monospace) when `error != null`.

**Verify:**
- Visual test in isolation if time permits (drop into another doc's view temporarily, or have Step 6 be the visual smoke test). Don't ship a unit test for a textarea wrapper.

**Risk:** Unsaved-edit handling — when the user has typed in the editor and a notation refresh arrives from the server, the local edit must NOT be clobbered. Solution lives in Step 6 (controller-level "is editing" flag); the widget itself is dumb.

---

### Step 6 — `CustomDocumentController` (the `DocumentController` impl)

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

### Step 7 — Register the JS controller and end-to-end smoke

**Goal:** `StageController` finds `CustomDocumentController` via DI and renders it when a CustomDocument is open. UI bug-free.

**Edits:**
- `kzen-auto/kzen-auto-jvm/src/main/resources/notation/auto-js/document/custom-js.yaml` — new file, mirrors `plugin-js.yaml`:
  ```yaml
  CustomDocumentController:
    is: DocumentController
    class: tech.kzen.auto.client.objects.document.custom.CustomDocumentController$Wrapper
    archetype: CustomDocument
  ```
- Regenerate the codegen file. Find `ModuleReflectionGenerator` (Grep for the class name; it's referenced in the banner comment at the top of `KzenAutoJsModule.kt`) and run it — likely via a Gradle task or main method. Confirm the regenerated `KzenAutoJsModule.kt` now contains a `reflectionRegistry.put(..., "...CustomDocumentController$Wrapper", listOf("archetype")) { args -> CustomDocumentController.Wrapper(args[0] as ObjectLocation) }` block. **Commit the regenerated file.**

**Verify:**
- Full kzen-auto build: `cd ../kzen-auto && ./gradlew build` (warning: this also runs JS tests + bundling — multi-minute).
- Manual smoke: launch dev mode, sidebar shows "New Custom...", click it, the StageController now mounts `CustomDocumentController` instead of falling back to "Document: CustomDocument". Edit + Save round-trips.
- Confirm other doc types still work (open a `Report` doc — no regression).

**Risk:** If `ModuleReflectionGenerator` is hard to locate or run, fall back to **manually adding the entry** to `KzenAutoJsModule.kt` (it's source-controlled despite the banner). Mark it `// MANUAL EDIT` and revisit in Step 8.

---

### Step 8 — Polish, error UX, docs

**Goal:** Real-world readiness.

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