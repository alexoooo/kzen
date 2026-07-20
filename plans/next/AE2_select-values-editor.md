# AE2 — SelectClosePolicyEditor → SelectValuesEditor — implementation plan

> **✅ DONE 2026-07-20.** Landed in one session exactly as planned (all 8 steps, no deviations).
> Trackers ticked in `../2026-07-14_attribute-editor-improvements.md` (Phase 2, carries the
> as-built note) and `../2026-07-16_master-plan.md` (Sprint-2 filler list). Verification: full
> `./gradlew build` green in kzen-auto (incl. `:kzen-auto-js:build` — KSP regenerated
> `KzenAutoJsModule` without the deleted wrapper — and `:kzen-auto-jvm:test`); residue grep for
> `SelectClosePolicy` clean across kzen-auto; the yaml confirmed UTF-8 **without BOM** and
> strict-decodable. Beyond the plan's gates, a throwaway `NotationMetadataReader` probe (written,
> run, then deleted — no new test persisted, per the Tests section) proved the load-bearing risk
> empirically: `BrowserOpenStep.closePolicy`'s merged `attributeMetadataNotation` is
> `[by, editor, values, is]` with `editor = SelectValuesEditor` and all 7 labels in enum order,
> em-dashes intact — i.e. `values:` **does** ride the `meta.ref` inheritance path, which was the
> point of the phase. Q4's correction confirmed against the shipped code path (label will render
> **"ClosePolicy"**). **Still owed:** the browser smoke (steps 1–7 of Verification: visual render,
> selection round-trip to `closePolicy: run`, no-echo-write mtime check, ResultStep/ControlStep
> regression) and `:kzen-auto-test:selfTest` — both need the user.
>
> **Status (original): ready to execute.** Generated 2026-07-19 from
> `2026-07-14_attribute-editor-improvements.md` **Phase 2**. Decisions pre-made in the
> constituent plan (D7 label change; raw-string-compare delta) — do not re-litigate. Every
> anchor re-verified against current kzen-auto master (`ceb699d0`) and kzen-lib source on
> 2026-07-19. Two findings beyond the constituent plan: (1) **D7's predicted label string is
> wrong** — `formattedLabel` does not split camelCase, so the label renders **"ClosePolicy"**,
> not "Close Policy" (decision's substance — accept the standard label — stands; see
> Pre-resolved Q4); (2) the post-Y YamlParser was audited — the sketched double-quoted labels
> parse cleanly as-is, and quoting is belt-and-braces rather than a hard requirement (Q2).
> One session, small.

## Scope & goal

Delete the one hardcoded-enum editor — `SelectClosePolicyEditor` (166 lines) — by moving its
seven option labels into a `values:` map on the type-level `ResourceClosePolicy` notation
object and pointing its `editor:` marker at the generic, notation-driven `SelectValuesEditor`.
This proves the declarative-enum mechanism **through the `meta.ref` inheritance path**
specifically — the attribute-level `values:` path is already live twice (ResultStep `then`,
ControlStep `action`), and `editor:` already rides the ref path today, so the only genuinely
new combination is `values:` riding ref. Plus: remove the dead JS registration and update four
comment-only references to the deleted class. No feature work; one user-visible surface (the
close-policy dropdown on `ScopedResource` steps, i.e. BrowserOpenStep and the test harness's
StartKzenAutoStep).

## Dependencies & coordination

- **Prerequisite-free** — master plan lists AE2 as a Sprint-2 filler
  (`2026-07-16_master-plan.md:120–123`); independent of AE1 (disjoint files) and of phases
  3–5 (this editor is not an `AttributeCommitter` adopter and not in the select-of-reference
  family — it writes immediately, no debounce).
- **Single-repo change (kzen-auto only).** kzen-lib is read-only here — `ResourceClosePolicy`,
  `NotationMetadataReader`, and `YamlParser` were verified, none change.
- **Downstream**: `../kzen-project` grepped for `SelectClosePolicy` — zero references. The
  only notation marker anywhere is `script-jvm.yaml:19` (whole-repo grep confirmed).
- **KSP atomicity**: deleting the `@Reflect` `Wrapper` regenerates `KzenAutoJsModule`
  automatically, but the `script-js.yaml` registration must be removed in the same change-set
  or client boot fails on a missing class (constituent-plan ground rule).

## Current-state findings (anchors verified 2026-07-19)

**The editor being deleted** —
`kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/script/display/edit/SelectClosePolicyEditor.kt`:
- `optionLabel` **:62–85** — the seven labels, carried verbatim into the YAML below (checked
  char-for-char against source).
- Hydration parses via case-tolerant `ResourceClosePolicy.parse` inside `runCatching`
  (:114–115); an unparseable value leaves `state.policy` null and `render` bails (:146–147) —
  i.e. today an odd value renders *nothing*.
- Write-only-on-real-change discipline (:128–141) — no `componentDidUpdate` write, so mount
  hydration never echoes a no-op command. `SelectValuesEditor` has the identical discipline
  (its :122–136), so the no-echo smoke check must still pass.
- Hardcoded label `"Close policy"` (:160).

**The replacement** — same directory, `SelectValuesEditor.kt` (already registered at
`script-js.yaml:163–165`; already live for ResultStep/ControlStep):
- Reads options from `attributeMetadataNotation.get(valuesAttributePath.toNesting())` where
  `valuesAttributePath = AttributePath.parse("values")` (:68, :91–98); label fallback = key
  when a map entry isn't a string (:103).
- Selection is a **raw string compare** against the stored value (:157); write is the option
  key verbatim (:125–136) — same keys the old editor wrote (`newPolicy.key`).
- Label = `CommonEditUtils.formattedLabel(AttributePath.ofName(attributeName))` (:155).
- Options `Map` preserves notation order (`associate` over the persistent map’s entries), so
  YAML order = dropdown order.

**The single marker + type-level object** —
`kzen-auto-jvm/src/main/resources/notation/auto-jvm/script/script-jvm.yaml`:
- `ResourceClosePolicy` **:13–19** (explanatory comment :10–12); `editor:
  SelectClosePolicyEditor` at **:19** — the sole marker in existence.
- `ResourceClosePolicyDefiner` :21–22; `ScopedResource` mix-in :27–31 (`closePolicy: auto`
  body default + `meta: closePolicy: ResourceClosePolicy`).
- Existing `values:` precedents: ResultStep `meta.then` **:153–159** and ControlStep
  `meta.action` **:395–401** — both `editor: SelectValuesEditor` + double-quoted labels.
- Consumers of `ScopedResource`: `BrowserOpenStep` :407–416; kzen-auto-test's
  `StartKzenAutoStep` (`kzen-auto-test/src/main/resources/notation/auto-jvm/script-test.yaml:2–22`).

**JS registration to remove** —
`kzen-auto-jvm/src/main/resources/notation/auto-js/document/script-js.yaml` **:153–155**
(`SelectClosePolicyEditor:` / `is: AttributeEditor` / `class: …$Wrapper`), between
`TargetSpecEditor` (:143–150) and `SelectEnclosingLoopEditor` (:158–160), separated by
two-blank-line gaps.

**Metadata-inheritance path traced** (kzen-lib
`kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/metadata/NotationMetadataReader.kt`):
`ScopedResource.meta.closePolicy` is the scalar `ResourceClosePolicy` →
`readAttribute` (:272–347) takes it as the attribute's inheritance parent (:277–287), resolves
`refAttributeMap = resolveMetadataRef(…)` which reads the type object's `meta.ref` map
(:435–442; `NotationConventions.refAttributePath` = `meta.ref`, `NotationConventions.kt:68–69`),
then merges `refAttributeMap.map.putAll(directAttributeMap.map)` (:296 — direct-over-ref;
direct is empty here since the meta entry is a scalar) and augments `is:` (:297–305). The
merged map **is** `AttributeMetadata.attributeMetadataNotation` (:342–346) — the exact map
`AttributeEditorManager` queries for `editor:` (`AttributeEditorManager.kt:39, :84–91`) and
`SelectValuesEditor` queries for `values:` (:91–98). Since `editor:` demonstrably reaches the
manager through this path today (it's how the bespoke editor gets selected), `values:` placed
beside it lands in the same merged map. Cache invalidation is sound: `metadataDigest` folds
the type object's whole `meta` map digest (:168–174), so adding `values:` invalidates the
per-object metadata cache. Type resolution is unaffected — `readAttributeType` reads only
`is:`/`class:`/`nullable`/`of` from the merged map (:350–404), ignoring `values` (precedent:
ResultStep's meta map already carries `values` beside `is: String`).

**Host + definer unaffected**: `ScriptStepDisplayDefault` iterates
`objectMetadata.attributes.map` (:508–520, inherited attributes included) and renders each
through `attributeEditorManager` (:625–632) — no per-attribute special-casing; grep for
`closePolicy` in kzen-auto-js: zero hits. `ResourceClosePolicyDefiner` (kzen-auto-common,
:28–36) reads only the graph-notation scalar via `firstAttribute` — the ref-map contents are
invisible to it; definition behaviour is byte-identical.

**kzen-lib `ResourceClosePolicy` keys** (`kzen-lib-common/.../exec/logic/ResourceClosePolicy.kt:17–35`):
`auto`, `manual`, `keepOnFailure`, **`parent`** (enum constant `ParentDocument` — the plan's
flag confirmed: key is `parent`, not `parentDocument`), `parentKeepOnFailure`, `run`,
`runKeepOnFailure`. `parse` is case-insensitive (:39–44).

**Comment-only references to the deleted class** (whole-repo grep — these are ALL remaining
mentions after the code/yaml changes):
- `SelectValuesEditor.kt:39` ("cf. the bespoke SelectClosePolicyEditor") and `:124` ("same
  discipline as SelectClosePolicyEditor");
- `job/JobChannelNumberField.kt:72` ("Like SelectClosePolicyEditor it writes ONLY on a real
  user change");
- `kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/exec/script/test/OpenResourceTestStep.kt:17–20`
  ("the mix-in's `SelectClosePolicyEditor` binding drags a JS-only `AttributeEditorManager`
  reference…" — the rationale survives verbatim with the new name, since `SelectValuesEditor`
  is equally JS-only).
- `docs/` — zero mentions (grep confirmed).

**UTF-8 path** (the labels introduce the first non-ASCII characters — em-dashes — into any
bundled notation file; grep found zero today): `ClasspathNotationMedia.readDocument` uses
`URL.readText()` (UTF-8 default; kzen-lib-jvm :83–97), `FileNotationMedia:347` uses
`String(bytes, Charsets.UTF_8)`, `IoUtils.utf8Decode` is UTF-8 on both platforms, and the
browser's `Response.text()` always decodes UTF-8. End-to-end safe; the smoke test rendering
the labels is the proof.

## Pre-resolved questions

**Q1 — enum keys.** Seven, verified against kzen-lib source (above). YAML entries ordered in
enum-declaration order so the dropdown order is identical to today's
`ResourceClosePolicy.entries` order.

**Q2 — YAML quoting audit (post-Y parser, kzen-lib `util/yaml/YamlParser.kt`).**
- Map keys (`auto` … `runKeepOnFailure`): pure letters — bare-safe (`isBareStartChar`
  :767–769, `matchBareEntry` :603–641). No quoting.
- Label values: none contains `:`, `#`, `"`, `\`, or a leading indicator character. Under the
  post-Y parser an unquoted inline value routes through `parseBareRestOfLine` (:411–426) —
  rest-of-line **literal**, mutated only by trailing-` #comment` and trailing-whitespace
  stripping — so **all seven labels would parse correctly even bare**. (The old "unquoted
  `a:b` nests as a map" hazard from AGENTS is obsolete for inline values post-Y — see the
  parser's own comment at :375–376: `test: a: b` is the scalar `a: b` — and no label contains
  a colon anyway.) Em-dash, `;`, `,`, `(`, `)`, `/` are all literal in both bare and
  double-quoted modes (`unescapeDouble` :789–829 special-cases only backslash; none present).
- **Decision: double-quote all seven anyway** — matches the constituent plan's sketch and the
  two live `values:` precedents in the same file, is strict-YAML-1.2-safe for external
  tooling, and guards a future label edit introducing ` #` (which would silently truncate a
  bare scalar). No `\u` escaping needed: escaping is an unparse concern and this bundled file
  is never unparsed (`ClasspathNotationMedia.isReadOnly` :34–36; user documents carry only
  the bare `closePolicy: auto|run|…` scalar values, all bare-safe).

**Q3 — final ready-to-paste YAML** (replaces `script-jvm.yaml:13–19`; keys bare, labels
double-quoted, enum order; `values:` at indent 6 **under `ref:`**, entries at indent 8):

```yaml
ResourceClosePolicy:
  abstract: true
  class: tech.kzen.lib.common.exec.logic.ResourceClosePolicy
  meta:
    ref:
      by: ResourceClosePolicyDefiner
      editor: SelectValuesEditor
      values:
        auto: "Auto — close when the run finishes (success, failure, or cancel)"
        manual: "Manual — keep open; only an explicit close step disposes it"
        keepOnFailure: "Keep on failure — close on success/cancel, keep on a failed run to inspect"
        parent: "Parent — close when the calling Script (one level up) finishes"
        parentKeepOnFailure: "Parent, keep on failure — close when the caller finishes, keep if it failed"
        run: "Run — close when the whole run finishes"
        runKeepOnFailure: "Run, keep on failure — close at run end, keep if the run failed"
```

**Q4 — D7 correction: the label renders "ClosePolicy", not "Close Policy".**
`CommonEditUtils.formattedLabel` (:35–58) title-cases the first character and then joins
`Regex("\\w+")` matches — which splits on non-word characters only, never on camel humps —
so `closePolicy` → `"ClosePolicy"`. D7's substance (drop the hardcoded `"Close policy"` and
accept the standard `formattedLabel` output) stands unchanged; only the predicted string in
the constituent plan was wrong. `"ClosePolicy"` is consistent with every other camelCase
attribute label in the app (e.g. `screenshotDelayMilliseconds` → "ScreenshotDelayMilliseconds"
under `DefaultAttributeEditor`). Teaching `formattedLabel` to split camel humps would change
labels app-wide — out of scope (see Out of scope); flag the cosmetic outcome to the user at
landing time.

**Q5 — behaviour deltas** (first two accepted in the constituent plan; third newly observed,
strictly an improvement):
1. Label `"Close policy"` → `"ClosePolicy"` (D7, as corrected in Q4).
2. Raw-string compare: a hand-typed odd-case value (`AUTO`) shows unselected instead of
   being case-normalized by `ResourceClosePolicy.parse` — accepted power-tool semantics.
   (The JVM definer still parses case-insensitively, so such a value *runs* fine either way.)
3. An unparseable stored value (`bogus`): old editor rendered nothing at all (silent); new
   editor renders the dropdown with nothing selected — louder, and still writes only on a
   real user change.

## Step-by-step implementation

1. **`script-jvm.yaml`** — replace :19 (`editor: SelectClosePolicyEditor` →
   `editor: SelectValuesEditor`) and insert the `values:` block per Q3. Keep the comment at
   :10–12; optionally amend its tail ("rendered as a labelled dropdown by the editor") to
   "rendered as a labelled dropdown by SelectValuesEditor from the `values:` map". Ensure the
   file stays UTF-8 without BOM (first non-ASCII content in bundled notation).
2. **Delete** `kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/objects/document/script/display/edit/SelectClosePolicyEditor.kt`.
3. **`script-js.yaml`** — remove the :153–155 registration block plus one adjacent
   blank-line pair, preserving the file's two-blank-line separation between
   `TargetSpecEditor` and `SelectEnclosingLoopEditor`.
4. **Comment updates** (mechanical, no behaviour):
   - `SelectValuesEditor.kt:39` — drop/replace the "(cf. the bespoke SelectClosePolicyEditor)"
     aside (e.g. "…with no per-enum Kotlin (replaced the bespoke close-policy editor)").
   - `SelectValuesEditor.kt:124` — "same discipline as SelectClosePolicyEditor" → e.g. "same
     discipline the bespoke close-policy editor established".
   - `JobChannelNumberField.kt:72` — "Like SelectClosePolicyEditor" → "Like SelectValuesEditor".
   - `OpenResourceTestStep.kt:18` — "the mix-in's `SelectClosePolicyEditor` binding" → "the
     mix-in's `SelectValuesEditor` binding" (rest of the rationale unchanged — still true).
5. **Build gates**: `./gradlew :kzen-auto-js:build -x test` (KSP regenerates
   `KzenAutoJsModule` without the deleted wrapper), then full `./gradlew build`.
6. **Residue grep**: `SelectClosePolicyEditor` over kzen-auto — expect zero hits (steps 1–4
   cover every current mention; docs have none).
7. **Constituent plan tracker**: tick Phase 2 in
   `kzen/plans/2026-07-14_attribute-editor-improvements.md` (✓ + date + as-built note: label
   renders "ClosePolicy" — D7's "Close Policy" prediction corrected; `values:` proven through
   the ref-map path).
8. **Git**: no new files (edits + one deletion — the deletion shows in the tracked diff;
   stage explicit paths only, never commit).

## Tests

- **No new automated tests.** The JS client has no component unit tests (repo baseline), and
  the `values:`-map mechanism is already exercised by two live usages; kzen-lib's existing
  YamlParser tests cover the quoting rules (kzen-lib untouched).
- **Existing tests stay green unchanged**: `ScriptExtensibilityTest` +
  `OpenResourceTestStep` deliberately use a plain-String `closePolicy` (comment-only edit);
  `ResourceClosePolicyDefiner`'s behaviour is byte-identical (reads only the scalar).
- Full `./gradlew build` runs the JVM suites over the modified notation resources — a
  malformed `values:` block would fail definition-time loading in any notation-booting test.

## Verification

Build gates (step 5), then:

**Manual smoke** (`./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch`; respect file
safety — create a scratch document rather than editing the user's, and only delete what this
session created):
1. Create a **new scratch Script document** via the sidebar; insert a **BrowserOpenStep**
   from the palette; expand it.
2. Dropdown renders with label **"ClosePolicy"** and exactly **7 options** whose texts match
   Q3 verbatim (em-dashes render correctly — this also proves the UTF-8 path).
3. Default **`auto` pre-selected** ("Auto — close when the run finishes…") — inherited from
   `ScopedResource`'s `closePolicy: auto` body default.
4. Change to e.g. "Run — close when the whole run finishes" → **read-only inspect** the
   scratch document's yaml under `notation/main/`: `closePolicy: run` (bare scalar, key not
   label). Change back to Auto.
5. **No echo write on mount**: note the scratch document file's `LastWriteTime`
   (`(Get-Item <path>).LastWriteTime`), hard-refresh the browser, re-read mtime — unchanged
   (the no-`componentDidUpdate`-write discipline).
6. **Shared-editor regression**: a ResultStep's `then` dropdown and a ControlStep's `action`
   dropdown still render and select correctly (same `SelectValuesEditor` code path).
7. Delete the scratch document (created this session — allowed).

**End-to-end**: `./gradlew :kzen-auto-test:selfTest` — boots tester + SUT JVMs over the
modified `script-jvm.yaml` (and `script-test.yaml`'s `ScopedResource`-inheriting
StartKzenAutoStep), drives browser-open scripts end-to-end; proves definition
(`ResourceClosePolicyDefiner`) and disposal wiring are unaffected.

## Risks & gotchas

- **Indentation is load-bearing**: `values:` must sit **inside `ref:`** (indent 6, entries at
  8). Mis-indented to `meta:` level (indent 4) it would be read as metadata for an *attribute
  named `values`* on the type object — silently absent from the closePolicy merged map, and
  the dropdown would render empty-handed (editor returns null options → renders nothing).
- **Stale marker behaviour**: any notation still saying `editor: SelectClosePolicyEditor`
  after this lands renders "[Attribute editor not found: SelectClosePolicyEditor]"
  (`AttributeEditorManager:88–109` — the Default fallback applies only when the `editor:` key
  is absent, not when it dangles). Verified zero such markers in kzen-auto, kzen-auto-test,
  and kzen-project; user documents carry values, not markers. Loud, not silent, if a
  third-party project pinned it.
- **Direct-over-ref merge**: if some future step overrides `meta: closePolicy:` with a map
  containing its own `values:`/`editor:`, the attribute-level entries win (:296) — correct
  and intended; no current step does.
- **Encoding**: the em-dash labels are the first non-ASCII bytes in bundled notation. The
  read path is UTF-8 end-to-end (verified above), but the editing tool must save UTF-8
  without BOM.
- **KSP/yaml atomicity** (steps 2+3 together) — a registered class that no longer exists
  fails client boot.
- **D7 cosmetic surprise**: report the "ClosePolicy" (not "Close Policy") rendering to the
  user when landing — it's the documented standard-label outcome, but the constituent plan
  promised a prettier string.

## Out of scope

- **`formattedLabel` camel-hump splitting** ("ClosePolicy" → "Close Policy") — a shared-code
  change altering every default attribute label app-wide; if wanted, it's a separate one-line
  decision for the user, not an AE2 rider.
- **Renaming any registered editor object**, incl. `SelectValuesEditor` itself (constituent
  plan's standing exclusion — the `editor:` string contract).
- **Migrating `OpenResourceTestStep` to the `ScopedResource` mix-in** — its plain-String
  workaround exists because the mix-in's `editor:` binding names a JS-only object; AE2 swaps
  the name but not the constraint.
- Phases 3–6 seams (`AttributeCommitter`, PathValue merge, select-of-reference base) — this
  editor is neither an adopter nor a family member.
