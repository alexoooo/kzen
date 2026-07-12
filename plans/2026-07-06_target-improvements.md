# Target (element targeting) improvements — phased plan

> **Rename note (2026-07-12):** the Feature concept was renamed to **Target** as the umbrella for
> element targeting (visual today; CSS/XPath/relational expressions planned). Old names in this
> document map as: archetype `Feature` → `Target` (UI title "Action Target" → "Target");
> `FeatureDocument` → `TargetDocument`; packages `…document.feature` → `…document.target` and
> `…server.objects.feature` → `…server.objects.target`; `FeatureController` → `TargetController`;
> `VisionService` → `TargetLocator` (moved to `server.service.target` — it dispatches all
> TargetSpec kinds). `service.vision` keeps `TemplateMatcher`/`RgbGrid`/`VisionUtils` as the
> visual-strategy engine. In the step editor, the type dropdown is labelled "Target Type" and the
> visual document selector "Target". The review section below predates the rename; phases have
> been updated. This file itself was renamed from `2026-07-06_feature-improvements.md`.

> **Status: COMPLETE 2026-07-12** — all seven phases landed (see the tracker's as-built notes;
> manual smoke of phases 3/5/6 UI surfaces pending user). Originally restructured 2026-07-12
> after a field bug report and a UI redesign
> decision (both recorded in the field-report section below). Written 2026-07-06 from a design
> review of the Target document type — the visual action-target manager for point-and-click RPA —
> across all three layers: common (`TargetDocument` / `TargetSpec` / `TargetSpecDefiner` /
> `TargetSpecCreator`), server (`TargetLocator` / `TemplateMatcher` / `RgbGrid` /
> `ScreenshotTaker` + the five `Browser*Step` consumers), and the JS client (`TargetController` /
> `CropperWrapper` / `TargetSpecEditor` / `TargetAttributeView`).
> Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is self-contained: goal, design
> decisions (already made — do not re-litigate), concrete steps with file anchors, and
> verification. Phases are ordered by priority; phase 7 is a **decision gate**, not a build order.
>
> All phases are **kzen-auto only** (no kzen-lib changes) — no publishToMavenLocal round-trips
> needed.
>
> Companion plans: `2026-07-06_script-improvements.md` (phase 2 there — browser resource survival
> across live edit — is what makes "capture from the active run's browser" reliable here) and
> `2026-07-06_job-improvements.md` (headless mode; phase 4 here must degrade gracefully in it).
>
> **Renumbering note (2026-07-12):** old FE2 (same-pipeline capture) and old FE3 (locate-preview)
> merged into the new **FE4** (the user's View/Add redesign is exactly their union); old FE4
> (tolerant matching) → **FE5**; old FE5 (SPI) → **FE6**; old FE6 (gate) → **FE7**. New FE2 (bug:
> correct clicking) and FE3 (step-editor polish) come from the 2026-07-12 field report.
> Cross-references elsewhere (master plan, `TemplateMatcherTest` kdoc) updated in lockstep.
>
> **Progress tracker** (update as phases land):
> - [x] Phase 1 — vision core hardening: tests + benchmark, matcher perf, DOM-mutation fix, definition robustness
>   (landed 2026-07-12; as-built: pure matcher extracted as `TemplateMatcher` — the plan's sanctioned
>   alternative — so the test is `TemplateMatcherTest` (+ `RgbGridTest`) rather than "VisionUtilsTest";
>   `VisionUtils` retains only `xpathEscape`; `Result` nested in the service; benchmark: 338 ms → 56 ms
>   on the common-colour pathological case. 1f riders: `onClientState`'s `TargetType.valueOf` also made
>   tolerant (malformed notation degrades to the existing early return instead of crashing the render);
>   `onTypeChange` cancels the pending text debounce — cancel, not flush, because `onBlur` already flushes
>   genuine pending text before a dropdown click, and a flush at switch time races the value-clearing
>   `setState`, emitting exactly the value-less map 1f suppresses.)
> - [x] Phase 2 — correct clicking: root-cause the exact-match regression, exclude self-matches, enrich diagnostics
>   (landed 2026-07-12; **2b verdict**: the machine runs a 4K display at **150% scaling** (3840 physical /
>   2560 logical), which creates two pixel spaces. AWT `Robot` (UI Screen capture) captures at PHYSICAL
>   resolution and exact-matches fresh Robot screenshots — demonstrated live in the new View screen. The
>   user's `exact-screenshot.png` (Windows Screenshot tool → MSPaint) landed in LOGICAL space: glyph
>   footprint 12x8 vs 18x11 in the Robot crop, exactly 1.5x apart — it can never exact-match either
>   pipeline. Selenium's browser screenshot is also physical-scale (DPR 1.5) but Chrome rasterizes fonts
>   differently than the desktop compositor (the phase-1 rasterization-drift fixture, 19x12 vs 18x11), so
>   desktop-captured crops exact-match only desktop screenshots and browser-captured crops only browser
>   screenshots. Same-machine desktop capture IS pixel-exact within its own pipeline — the Screen source
>   stays first-class; cross-pipeline crops are phase 5's job (its pyramid includes 1.5). No code
>   regression found; "used to work" was within-pipeline matching. As-built deltas: (1) success-path
>   diagnostics ride a new `StepTrace.note` field (wire-additive) + `StepExecution.traceNote` — NOT inside
>   `traceDetail` — because the detail slot is single-value and binary-typed across ~8 client consumers
>   (film strip, thumbnails); note renders as a subdued "Note" section in the step display. (2) The click
>   path now uses `locateAllByCrop` (returns `CropMatches` with crop dimensions) with a per-crop
>   diagnostic cap of 8; flat `locateAll` deleted (no remaining callers). Errors name each crop, its
>   dimensions, match locations, and screenshot dimensions; message builders are pure companion functions
>   with unit tests. (3) Self-match exclusion: `TargetDocument.previewDataAttribute`
>   (`data-kzen-target-preview`) marks TargetAttributeView's preview img, TargetView's crop thumbnails +
>   screenshot overlay, and TargetAdd's capture surface; the locator drops candidates inside a marked
>   ancestor via `closest()`, uniqueness applies to survivors, exclusions are counted in errors/notes.
>   selfTest green with exclusion active (Plus Circle click unaffected — its preview renders in the
>   tester viewport but the marker now excludes it deterministically regardless of visibility).
>   User's Script correct-click: pending crop recapture via the Browser source (both existing crops are
>   desktop-space; the browser screenshot needs a browser-pipeline crop) or phase 5 tolerance.)
> - [x] Phase 3 — step-editor polish: value-field label overlap + navigate-to-Target link icon
>   (landed 2026-07-12; both value rows (textual + visual select) get a 0.75em top margin clearing the
>   MUI floating-label overhang; the Visual select is now a flex row (grow/minWidth-0) with an
>   open-in-new IconButton ("Open the selected target", disabled with no selection) mirroring
>   SelectLogicEditor; `TargetSpecEditor.Wrapper` gained `@Service navigationGlobal` via a new
>   `TargetSpecEditorProps`. Manual smoke pending user.)
> - [x] Phase 4 — Target screen View/Add split + locate overlay + capture sources
>   (landed 2026-07-12, pulled ahead of phases 2/3 as a visual debugging aid for phase 2; as-built
>   deltas: (1) sections are ROUTED — `?section=view|add` hash param, tabs are real `<a href>`
>   anchors via `NavigationRoute` (Ctrl+Click opens a tab, refresh keeps the page; absent param →
>   View when crops exist else Add, never written back); (2) `TargetLocateAction` does NOT capture —
>   it locates crops in a client-POSTed screenshot PNG (body) and returns dimensions + per-crop
>   rects (`TargetLocateResult` wire model in common), so display and matching share bytes by
>   construction and phase 5's tolerance slider can re-locate without recapture;
>   (3) per-crop matching is a new `TargetLocator.locateAllByCrop` (no uniqueness/limit) — the
>   click path's limited `locateAll` untouched; (4) capture sources: Screen (0/3/10 s client-side
>   delay) + Browser (latest traced run via `LogicTraceEndpoint` actionTraced→mostRecent→lookupRun,
>   thumbnail strip, auto-selects newest); the live-browser stretch source was SKIPPED — the trace
>   strip covers the workflow, revisit after script plan phase 2; (5) riders landed: MIME typo
>   fixed in TargetController AND StepImage.pngUrl (`data:image/png`), `capturedDataUrl`
>   intermission removed (Save jumps to View via `parameterize`), ScreenshotTaker headless grace
>   (HeadlessException/AWTError → clean failure, rendered inline — no more eternal
>   "&lt;taking screenshot&gt;"). Overlay boxes are percentage-positioned divs (of screenshot
>   natural size from the locate response) — no resize listeners. Tolerance-control slot marked in
>   `TargetView`. Tests: `TargetLocatorTest` (crop-keyed matches over `MapNotationMedia`),
>   `TargetLocateActionTest` (wire round-trip); `:kzen-auto-jvm:test` + selfTest green.
>   Manual smoke pending user.)
> - [x] Phase 5 — tolerant matching: NCC scores + per-document tolerance + multi-scale
>   (landed 2026-07-12; hand-rolled zero-mean grayscale NCC in `TemplateMatcher.locateScored`
>   (BT.601 luma, integral-image window mean/variance with a flat-window skip, per-origin
>   correlation, NMS within half-a-crop), exact `locate` untouched. **Calibration**: the
>   rasterization-drift fixture scores 0.850 at (374, 518) — exactly the plan's prediction — so the
>   presets are Exact 1.0 / Strict 0.9 / **Normal 0.8** / Loose 0.7 (the plan's nominal 0.85 Normal
>   would have missed the 0.84997 real-world case by a hair; recalibrated). Multi-scale pyramid
>   `[1.0, 1.1, 0.9, 1.25, 0.8, 0.75, 1.5, 0.67]` (bilinear, includes phase 2's 1.5 verdict case),
>   nearest-to-1 first with **stop-at-first-matching-scale** — deliberate deviation from
>   scan-all + cross-scale NMS: NCC isn't comparable across window sizes (smaller windows score
>   higher on less evidence), so a small-scale false positive could outrank a true match; the
>   below-threshold `best` diagnostic likewise reports the crop at its OWN scale. Per-document
>   `tolerance:` scalar on the main object parsed by `TargetDocument.tolerance` (absent or ≥1.0 =
>   exact-only; extra notation attributes are inert to definition, like archetype `title`/`icon`).
>   `TargetLocator.locateAllByCrop` runs exact first, falls back to scored per crop; `CropMatches`
>   carries scored matches (exact = score/scale 1.0) + `bestRejected`; wire model restructured
>   (`TargetCropMatches{matches, closest}`, `TargetMatchRect` + score/scale). Errors/notes report
>   scores and "closest 0.91 at [x, y]". View: tolerance select (presets + Custom passthrough,
>   writes UpsertAttribute on the main object — "Exact" writes `tolerance: 1` since no
>   whole-attribute-removal command exists; command success auto re-locates), score labels on crop
>   rows and overlay boxes (score + ×scale chip above each box). New scored-path benchmark: flat
>   1920x1080 in <5 s budget (measured ~50 ms; drift fixture full-pyramid miss ~1 s at 1070x634).
>   Tests: drift found-at-Normal/rejected-at-Strict-with-best, noise-perturbed found+threshold
>   honoured, 1.25x found via pyramid (per-pixel LCG texture — a smooth gradient self-matches
>   across neighbouring scales and can't test scale selection), NMS spacing, tolerance-less docs
>   bit-identical, both benchmarks. `:kzen-auto-jvm:test` + selfTest green. Manual smoke pending:
>   drop the user's Target to Normal in View — the desktop crop's box should light up with its
>   score against a browser screenshot.)
> - [x] Phase 6 — open target-type set: locator SPI + registry, match policy, browser-step dedup
>   (landed 2026-07-12; `TargetType` enum DELETED, `TargetSpec` is an interface with a `policy` val
>   (default Unique), per-type classes carry policy. **Key as-built deviation — the define side is
>   notation-declarative, not handler code**: a definer object cannot take an autowired instance
>   list (GraphDefiner instantiates definers mid-definition via a path that only awaits
>   creatorDependencies, so the handler instances don't exist yet — the whole test suite crashed
>   with "Missing: TargetSpecDefiner - FocusTargetType" until restructured; fixing that ordering is
>   a kzen-lib change, out of scope). So each `is: TargetSpecType` object declares `typeName:` +
>   `valueKind: none|text|reference` (the three shapes the definition layer offers) which
>   `TargetSpecDefiner` reads straight from notation, while the object's `class:` (a
>   `TargetSpecType` subclass, `createSpec` only) autowires into `TargetSpecCreator` (creators ARE
>   safe — instantiated by GraphCreator, which orders references correctly). Server:
>   `TargetTypeLocator` SPI (canLocate/locate with the service as context), four built-in locator
>   objects, `TargetLocator.register()` for third parties, dispatch `when` gone. Client:
>   `TargetTypeDisplay` SPI (dropdown label + value row + collapsed summary + a
>   `summaryDependencies` hook preserving render-scoping), four fragments, TargetSpecEditor /
>   TargetAttributeView are thin type-agnostic hosts (editor preserves foreign keys like `policy:`
>   across rewrites; rename-tracking generalized to any reference-parsable value). Gotcha pinned:
>   the `TargetTypeDisplay` archetype needs `meta: objectLocation: {is: ObjectLocation, by: Self}`
>   or the CLIENT graph fails at boot with a blank UI (diagnosed via headless-Chrome console dump;
>   selfTest's symptom was every Text click "not found"). Match policy: `policy: unique (default) |
>   first | nth (+index) | best` on the target map, `TargetLocator.selectByPolicy` uniform across
>   types (Text/Xpath now findElements + policy — the silent first-match is gone; Visual orders
>   candidates (y,x), Best by score; Focus inherently single). Migrated 3 tester targets to
>   `policy: first` (two `label/..//textarea` xpaths — MUI multiline renders a hidden autosize
>   shadow textarea, so those were NEVER unique — and Text "Result" which also matches the added
>   step's card). Browser-step dedup: `BrowserTargetStep` base (locate → note → act → screenshot);
>   Click/Submit/Focus/Write/Read supply only `act` (Click keeps the input[type=submit] fold).
>   Third-party proof: `CssSelectorTarget` + spec-type + locator entirely in the test source set
>   (hand-registered per the ScriptStepTestModule convention) + `target-extensibility-test.yaml`;
>   `TargetExtensibilityTest` defines/creates through the real notation machinery and locates
>   through `register()` with zero shared-file edits. The synthetic type's JS fragment was skipped
>   (JVM test can't exercise it; the client seam is the same autowire mechanism). No policy editor
>   UI (notation-editable only — not user-requested). architecture.md §6 gained the target-SPI
>   paragraph; AGENTS.md has no god-object gotcha to update. `:kzen-auto-jvm:test` +
>   `:kzen-auto-js:compileKotlinJs` + selfTest green. Post-landing fix 2026-07-12: `unique`
>   counted candidates across crops, so 3 crops agreeing on the same element read as ambiguity
>   ("More than one target found ... all at [~78, ~618]"). A document's crops are alternative
>   appearances of ONE target — `TargetLocator.collapseByElement` now collapses candidates that
>   resolve to the same DOM element before `selectByPolicy` (null-element matches stay distinct);
>   the success note reports agreement ("(3 crops agree)"). The View preview mirrors this with
>   geometry (`TargetLocateResult.distinctTargetCount`, overlap-clustering — the preview has no
>   DOM, e.g. desktop capture): "N matches agree on one target — uniquely located". Also fixed
>   the Browser (latest run) source: browser screenshots ride step traces as the `detail` binary,
>   but the client filtered for top-level `BinaryExecutionValue` and always found nothing — now
>   `StepTrace.ofExecutionValueOrNull(value)?.detail` (works only for runs traced since the last
>   run/restart: `ServerLogicController.start` calls `logicTraceStore.clearAll()`).)
> - [x] Phase 7 — decision gate: desktop actuation (ActionSurface) or park desktop capture
>   (resolved 2026-07-12 as **Branch B — browser-first stands**, recorded in
>   kzen-auto/docs/architecture.md §6 (target paragraph): desktop capture is a capture-source
>   convenience, `ScreenshotTaker` is the future hook, the locator SPI's driver-typed context is
>   the retype seam. Rationale: no concrete desktop-automation need exists; branch A is
>   medium-high risk (input injection, focus stealing, OS permissions) with no user demand;
>   B is fully reversible. NB: chosen autonomously as the plan's low-risk default — re-open the
>   gate if desktop RPA becomes near-term.)

## Context — what the review found (2026-07-06; pre-rename names, pre-FE1 anchors)

The **integration skeleton is right and every phase preserves it**:

- **Crops as digested document resources.** PNGs live beside `~main.yaml`, listed in
  `resources.digests` — git-visible, served over the existing `/resource` REST path, digests give
  free cache keys and change detection. Best part of the design; nothing here changes it.
- **`target:` as structured notation.** The attribute-level wiring is already registry-driven:
  `TargetSpec` declares `by: TargetSpecDefiner / creator: TargetSpecCreator /
  editor: TargetSpecEditor` in notation (common-action.yaml:27-34), and the editor/view are
  resolved through the shared attribute-editor machinery, not hardcoded into Script.
- **Uniqueness enforcement as the default** — failing loudly on an ambiguous visual match is the
  right RPA-safety default. The problem is it's the *only* policy (see phase 6).
- **The bit-exact cropper** (`CropperWrapper.getCroppedCanvas`, CropperWrapper.kt:76-117 — affine
  collapse + `imageSmoothingEnabled = false`) — careful work, required *because* matching is
  exact; phase 5 relaxes the constraint it serves but the exact fast path keeps using it.

The weaknesses live in five clusters:

1. **Capture pipeline ≠ match pipeline — the central reliability flaw.** The editor captures the
   **server's desktop screen** (`ScreenshotTaker` → AWT `Robot`, default monitor only), but
   runtime matching runs against **Selenium's viewport screenshot** (`driver.getScreenshotAs`).
   Exact pixel equality across two different pixel pipelines (OS compositor readback vs Chrome's
   internal compositor) holds only when the SUT browser renders on the same machine, same monitor,
   100% DPI, no browser zoom, target visible in the viewport. It breaks silently under DPI
   scaling, headless browsers, remote WebDriver, or a scrolled page. Side effects: opening a
   Target doc screenshots *whatever is on the user's screen* (implicitly, on mount), and a
   headless server throws from `Robot` with the editor stuck on "&lt;taking screenshot&gt;"
   forever (the failure branch of `doRequestScreenshot` is silently dropped).
   **2026-07-12 addendum:** the field report below sharpens this — the divergence bit in practice
   on the machine where it "should" be exact; phase 2 root-causes the specific delta before
   phase 4 redesigns capture.
2. **Exact equality with no scores, no tolerance, no diagnostics.** Matching is all-or-nothing per
   pixel; every environmental delta (ClearType settings, theme, one-pixel text-layout shift) is a
   hard miss reported as bare "Target not found" — no best-candidate score, no per-crop breakdown.
   And the first feedback that a Target works at all is a script failing at runtime: there is
   **no locate-preview in the editor**.
3. **Match semantics are underspecified.** N crops are OR'd alternates (`locateAll` unions all)
   and uniqueness is enforced **across the union** — two alternates that both match is a hard
   error, though alternates existing is presumably why the user added them. No ordinal selection,
   no best-match, no click offset (always patch centre), no per-crop labels (bare timestamp
   filenames) or thresholds. Inconsistently, `TextTarget` silently takes the *first* match while
   Visual demands uniqueness.
4. **The target-type set is closed — the god-object shape, applied to targets.** Adding one
   target type (CSS selector, ARIA role, OCR text) touches: `TargetType` enum, sealed
   `TargetSpec`, `TargetSpecDefiner`'s `when`, `TargetSpecCreator`'s `when`, the locate dispatch
   `when` (now TargetLocator.kt:72-106), `TargetSpecEditor` (`when` + labels), and
   `TargetAttributeView` (`when` + labels) — seven sites, three modules. A third-party module
   cannot add a target type at all. This is exactly the pattern `WorkerDisplayManager` /
   `StepDisplayManager` / `AttributeEditorManager` exist to avoid.
5. **The vision core is unengineered.** ~~Per-pixel `getRGB`, degenerate scan, `runBlocking`
   re-decode per run, random-CSS-class DOM mutation, wrong scale correction, `valueOf` crashes,
   value-less upserts mid-edit, zero tests.~~ **Fixed by phase 1** (see the tracker as-built
   note); kept here for the record.

Desktop RPA is currently **aspirational**: capture is desktop-based but there is no desktop
actuation (no Robot click/type steps; the only `locateAll` consumer is Selenium-bound). The
halfway state is the worst of both — phase 4 resolves the capture side, phase 7 is the explicit
decision on the actuation side.

**Covered elsewhere — do not re-do here:** browser-resource survival across live edit (script
plan phase 2 — phase 4 here reads the active run's browser through whatever that phase settles);
headless server mode itself (job plan — phase 4 here only ensures Target degrades gracefully
inside it); client render-scoping discipline (script plan phase 8 — Target's client surface is
small; apply the conventions, don't re-derive them).

**Deliberately out of scope** (decided; do not re-open inside a phase):
- **Recording mode** (watch the user click and generate steps) — the long-term point-and-click
  vision; needs its own analysis and probably a browser extension or CDP event tap. Not here.
- OCR / accessibility-tree / ML-embedding target types — become *possible* third-party locators
  after phase 6; none are built in this plan.
- Full-page capture + scroll orchestration (CDP `captureBeyondViewport`, auto-`scrollIntoView`
  search) — documented as a boundary in phase 4; revisit only if below-the-fold targets bite in
  practice.
- OpenCV/JavaCPP or any native dependency. Phase 5 hand-rolls NCC; **BoofCV (pure-JVM,
  Apache-2.0) is the sanctioned fallback** if the hand-rolled matcher proves finicky — record the
  swap in the as-built note.
- Piercing iframes / shadow DOM from `elementFromPoint` (documented boundary, phase 4).
- Multi-monitor selection — only if phase 7 chooses branch A.
- ~~Multi-scale matching (DPR drift).~~ **Un-deferred 2026-07-12** — the user explicitly wants
  matching to survive monitor-scale and theme changes; now part of phase 5.
- ~~Renaming `Feature`/`feature` packages to match the "Action Target" UI title.~~ Done 2026-07-12
  (see the rename note at the top): standardized on **Target** as the umbrella name, ahead of this
  plan's schedule, once the concept's future scope (selectors, surfaces, visual expressions) made
  the name decidable.

## Field report 2026-07-12 — what broke, what we established, what the user decided

**User-observed** (their working doc: `kzen-auto-jvm/src/main/resources/notation/main/Script.yaml`
+ `main/Action Target/~main.yaml` with two crops — `20260712_084617_375.png`, desktop-captured via
the UI, and `browser-pipeline.png`, cut from a run's own trace screenshot):

- A straight **run completes but clicks the wrong element**: instead of the intended sidebar
  icon, it clicks the Click step's own target preview thumbnail (expanding it).
- **Manual step-through fails** at the same step, while straight run "works" (wrongly) — the
  divergence itself is a symptom.
- The desktop-captured crop no longer exact-matches, though it is captured on the same computer
  with the same settings and screen scaling. **The user 100% confirms this used to work** —
  treat that as fact; the job is to find the specific delta, not to re-assert "it was a
  coincidence".

**Established from code** (mechanics, verified 2026-07-12):

- The Script automates the kzen-auto UI itself: `Browse to URL` →
  `http://localhost:8080/index.html#main/Script.yaml` — the automated Chrome renders **the very
  Script document being run**, including the Click step's target preview.
- `TargetAttributeView.renderVisual` (TargetAttributeView.kt:202-210) renders the target
  document's **first crop** (:119-121 `digests.keys.firstOrNull()`) as an `img` capped at
  `maxHeight 2em` — an icon-sized crop (under ~32 px) renders at **natural size**, i.e. the
  screenshot contains a pixel-exact copy of crop #1 *by construction*. That is what the run
  clicked: the union across both crops found exactly one exact match — the preview of itself.
- Corollary: **neither crop currently matches the real sidebar icon** — the desktop-captured one
  is pinned as rasterization drift by the phase-1 fixture
  (`TemplateMatcherTest.rasterizationDriftFindsNoExactMatch`: 19x12 vs 18x11 glyph footprint),
  and `browser-pipeline.png` (which *did* match when it was cut from a trace screenshot in the
  2026-07-12 debugging session) has since stopped matching — root cause unknown (phase 2).
- Run-vs-step divergence is plausibly run-state rendering: the automated browser shows the same
  document with **live run state** (broadcast to all clients), so paused-at-step pixels ≠
  mid-run pixels (step highlight, ribbon, expansion). To be confirmed with phase-2 diagnostics.

**User decisions** (do not re-litigate):

1. Same-machine/same-settings UI capture **must match pixel-for-pixel exactly** — restore that.
2. Separately, **proper fuzzy matching** is wanted for cross-environment drift (different monitor
   scale, desktop/browser theme), with a user-selectable **tolerance level on the Target**
   (per document, not per crop).
3. Step editor: the value select's floating label overlaps the field above — add spacing; the
   Target selector gets an **open-in-new link icon** to navigate to the selected document
   (pattern: the Run Step's script selector).
4. The Target document screen splits into two sections — **View** (screenshot overlaid with
   bounding boxes of each crop's matches; live preview at the current tolerance; the tolerance
   control lives here) and **Add** (the existing screenshot + crop capture; no overlays). Both
   show a screenshot on load and have a refresh button. Default section: View when the document
   has crops, otherwise Add.

## Ground rules for every phase

- **No target-type-specific code in shared layers** — the whole point of phase 6, but phases 2–5
  must not make it worse (new behaviour hangs off the existing `when`s only where a `when` already
  exists, and moves into the registry in phase 6).
- **Crops stay pure PNG resources.** Metadata goes in notation (phase 5's document-level
  tolerance attribute), never encoded into filenames or pixel data.
- **Dev loop:** kzen-auto only. `./gradlew -t :kzen-auto-jvm:classes` + IDE `BackendDevelopment`
  for server phases; `./gradlew -t :kzen-auto-js:jsEsbuildBundle -PjsWatch` + IDE
  `FrontendDevelopment` for editor phases.
- **Verification baseline (every phase):** `./gradlew :kzen-auto-jvm:test` (includes
  `TemplateMatcherTest`/`RgbGridTest` from phase 1); `./gradlew :kzen-auto-test:selfTest` — it
  exercises a real Visual target end-to-end (`FizzBuzz/Loop/Insert Range.yaml:10-14` clicks
  `Actions/Plus Circle` by template match) plus Text and Xpath targets throughout. **Beware a
  stale tester JVM on port 18081 — kill it first.** Editor phases add a manual
  `frontendDevelopment` smoke.
- The user's working docs (`notation/main/Script.yaml`, `notation/main/Action Target/`) are the
  live repro — read them, run them, but **never stage or clean them**.
- Mark the phase checkbox in this file's tracker when done; append an as-built note on deviation.

---

## Phase 1 — Vision core hardening: tests, perf, DOM-mutation fix, definition robustness

**Landed 2026-07-12** — see the tracker entry for the as-built summary. (Original section body
removed on restructure; the tests and anchors it introduced are cited from the later phases.)

---

## Phase 2 — Correct clicking: regression root-cause, self-match exclusion, diagnostics

**Goal:** the user's Script clicks the intended sidebar icon again — on straight run *and* on
manual step-through — and every locate failure explains itself. This phase is a bug hunt with
instrumentation first, fixes second; it ends with a written verdict on why desktop capture
stopped exact-matching. kzen-auto-jvm + a small js change.

### 2a. Diagnostics first (pulled forward from old phase 3)

- **Runtime error enrichment** in `TargetLocator.locateElement(TargetDocument, …)`
  (TargetLocator.kt:112-138): "Target not found" and "More than one target found" gain per-crop
  detail — which crops matched where (resource filename → rects), crop and screenshot dimensions.
  (Phase 5 adds best-candidate scores to the not-found case.)
- **Success-path trace detail:** which crop matched and the matched rect ride along in the step's
  `traceDetail` beside the existing screenshot, so a wrong-click run is diagnosable from its
  trace after the fact.
- Lift `uniqueMatchLimit = 2` early-stop (TargetLocator.kt:33, :120-121) to a small diagnostic
  cap (e.g. 8) so the error can *list* the ambiguity — and so 2c has candidates to filter.
  Uniqueness semantics unchanged: >1 surviving match is still an error.

### 2b. Root-cause the exact-match regression — verdict required

Treat "it used to work" as fact and find the delta. Hypotheses, each cheap to falsify with 2a's
diagnostics plus a scratch comparison (byte-compare crop pixels against the run's own trace
screenshot at the expected region; write throwaway comparisons under the scratchpad, not the
repo):

1. **Rendering scale mismatch** — the automated Chrome renders at a different effective scale
   than the user's on-screen browser: check `devicePixelRatio` + `window.innerWidth` vs
   screenshot dimensions in the automated browser (2a already surfaces dimensions), vs the same
   in the user's browser. Windows display scaling and per-monitor DPR are the suspects.
2. **Different binary** — WebDriverManager 6.3.4 may provision Chrome-for-Testing while the user
   captures from their own installed browser; different builds rasterize fonts differently.
   Check `Capabilities.browserVersion` vs the user's `chrome://version`.
3. **Browser zoom** — non-100% zoom in the browser the user captured from.
4. **UI churn since capture** — for `browser-pipeline.png` specifically (cut from the same
   Selenium pipeline, worked earlier the same day, stopped): the rename rebuilt the JS bundle and
   run-state rendering differs between paused and running (the step-vs-run divergence). Compare
   the crop against a *fresh* trace screenshot pixel-by-pixel to see what moved: layout shift,
   selection/hover state, ClearType phase.
5. **Dependency-bump fallout** — Selenium 4.45 / Chrome auto-update around 2026-07-07 changing
   screenshot or rasterization behaviour. Only if 1–4 come up empty.

**Deliverable:** an as-built note stating the mechanism precisely, and whether same-machine
desktop capture *can* be pixel-exact here (this decides how prominent the desktop source is in
phase 4). If a genuine code regression surfaces (matcher, decode, screenshot handling), fix it
in this phase with a pinned test.

### 2c. Self-match exclusion — automation UI is never a match

Any script that drives the kzen-auto UI itself can see its own target previews; that must be
well-defined, not a wrong click.

- Client: preview/crop `img`s get a marker attribute `data-kzen-target-preview` —
  `TargetAttributeView.renderVisual` (TargetAttributeView.kt:202-210), `TargetController`'s
  crop list (TargetController.kt:311-327), and the cropper/screenshot surfaces
  (TargetController.kt:479-503) which display screenshots that may themselves contain matches.
- Server: `TargetLocator.locateElement(TargetDocument, …)` resolves each candidate rect via the
  existing `elementFromPoint` mapping (TargetLocator.kt:193-228) and drops candidates whose
  element sits inside a marked ancestor
  (`executeScript("return arguments[0].closest('[data-kzen-target-preview]') != null", element)`).
  Uniqueness applies to the survivors; excluded candidates are reported in 2a's detail
  ("2 matches, 1 excluded as kzen target preview").
- External SUTs are unaffected (no markers in foreign DOMs); the extra `executeScript` runs only
  for the handful of candidates the diagnostic cap allows.
- Optional defence-in-depth (implementer's judgment): render the attribute-view preview at a
  deliberately non-natural scale so it can't be pixel-identical in the first place — do NOT rely
  on this alone (browser rescale can still round-trip small images); the marker is authoritative.

### 2d. Exit criteria

With 2b's verdict applied (recapture the crop through whichever source 2b proves exact — at
minimum, a crop cut from a fresh trace screenshot must work again):

- The user's `Script.yaml` clicks the real sidebar icon on straight run **and** on step-through.
- A deliberately stale crop produces a not-found error that names each crop and its match count.
- selfTest green — note: FizzBuzz's Plus Circle click also runs against the kzen-auto UI; confirm
  the exclusion doesn't disturb it, and explain (in the as-built) why it never tripped the
  self-match before (likely: its preview sits outside the viewport in the tester's window).
- `:kzen-auto-jvm:test` green; new unit coverage for whatever pure logic 2b/2c produced (the
  Selenium-coupled exclusion is covered by selfTest + manual).

---

## Phase 3 — Step-editor polish: field spacing + navigate-to-Target link

**Goal:** the two user-reported editor annoyances are gone. Small session, kzen-auto-js only;
can ride along with phase 2 if that session has room.

- **Label overlap.** `renderVisualSelect` (TargetSpecEditor.kt:392-412) emits
  `muiAutocompleteField` with no vertical gap below the Target Type field; MUI's outlined
  floating label overhangs the field's top border by half a line and collides with the field
  above. Wrap the value row in a `div` with a top margin (match the stacked-field spacing used
  elsewhere in the step editors; ~0.75–1 em). Check `renderTextual` (TargetSpecEditor.kt:374-389)
  at the same time — same stack, same overhang geometry — and apply the same gap if it presents.
- **Link icon.** Mirror the Run Step selector (SelectLogicEditor.kt:262-300): flex row —
  the select in a `flexGrow 1 / minWidth 0` div, then an `IconButton` with
  `material-symbols:open-in-new`, `title = "Open the selected target"`, disabled while
  `state.targetLocation == null`, onClick navigating to the selected document the same way
  `SelectLogicEditor.onNavigateToSelected` does. `TargetSpecEditor.Wrapper` gains
  `@Service navigationGlobal: NavigationGlobal` (KSP regenerates the module; never hand-edit
  generated files).

**Verify:** manual `frontendDevelopment` smoke — no overlap on a Visual and a Text target; link
disabled with nothing selected; link opens the Target document. `:kzen-auto-js:compileKotlinJs`.

---

## Phase 4 — Target screen: View/Add split + locate overlay + capture sources

**Goal:** the Target document screen becomes two sections — **View** (how do my patches match,
live) and **Add** (capture a new patch) — and capture can come from the **same pixel pipeline
matching uses**. Merges old FE2 (same-pipeline capture) and old FE3 (locate-now preview), which
the redesign unifies. kzen-auto-jvm + kzen-auto-js.

### Design decisions (user-specified 2026-07-12 + carried over)

- **Two sections, one screen** (`TargetController` render split; tabs or toggle — implementer's
  choice, keep it simple and consistent with existing UI chrome):
  - **View — existing captured patches.** A screenshot overlaid with bounding boxes of every
    crop's matches — a live preview of how the captured patches would match right now.
    Per-crop result lines (`browser-pipeline.png — 1 match`, `20260712_084617_375.png — no
    match`, `… — 4 matches (would fail uniqueness)`). Overlay = absolutely positioned divs over
    the scaled `img` (scale factor = displayed/natural size; no canvas needed). The existing
    crop list (thumbnails + delete) folds into this section. **The tolerance control lives here**
    once phase 5 lands; until then the section runs exact matching (leave the control's slot).
  - **Add — capture a new patch.** The existing screenshot + `CropperWrapper` + Save flow
    (TargetController.kt:259-285, :479-503), without overlays of existing crops.
  - **Default section:** View when the document has ≥1 crop, otherwise Add.
  - Both sections **load a screenshot on open** and have a **refresh button**. This supersedes
    old FE2's "stop auto-screenshotting on mount" decision (user decided otherwise) — but the
    load must not hang: keep old FE2's **headless grace** (`ScreenshotTaker.execute` catches
    `HeadlessException`/`AWTError` → `ExecutionFailure("Screen capture unavailable (headless
    server)")`; the controller renders failures inline — today only `ExecutionSuccess` is
    handled and failure strands "&lt;taking screenshot&gt;" forever, TargetController.kt:210-227).
- **Server locate endpoint.** New detached action `TargetLocateAction`
  (`server/objects/target/`, beside `ScreenshotTaker`): takes the Target document path (+ source
  selector) in the request params, produces a screenshot, runs `TargetLocator.locateAll` with
  **no uniqueness and no limit** (the preview's job is to show everything), returns the
  screenshot PNG (binary) + per-crop match rectangles and counts (detail value; + scores in
  phase 5). The **same screenshot bytes** serve display and matching — that is what keeps the
  boxes honest.
- **Capture/preview sources** (carried from old FE2; prominence per phase 2's verdict):
  1. **Browser (run screenshots)** — primary. Every `Browser*Step` already emits a full
     `driver.getScreenshotAs` PNG into the run trace; the client already fetches run-history
     binaries (`ScriptProgressStore` precedent). List the latest run's screenshots (thumbnail
     strip) and feed the selection to the cropper (Add) or the locate overlay (View). Pixels
     captured this way are **bit-identical by construction** to what matching sees.
  2. **Screen (desktop)** — the existing `ScreenshotTaker` path, with a **delay option**
     (0 / 3 / 10 s, client-side timer) so the user can alt-tab to the target app. Kept for
     future desktop RPA (phase 7) and non-SUT applications.
  3. **Stretch** (build only if the plumbing already suffices; otherwise flag for after script
     plan phase 2): "fresh screenshot from the active run's browser" via the `/logic/request`
     channel. The trace-screenshot source already covers the workflow.
- Editor hygiene riding along: fix the `data:png/png` MIME typo (TargetController.kt:219);
  remove the vestigial `capturedDataUrl` intermission (TargetController.kt:288-292, :336-346) —
  after Save the new crop simply appears in View.
- Screen-section state (which section, current screenshot, locate results, source choice) is
  per-document UI state in `TargetController`'s own component state — no new global.

**Verify:** manual `frontendDevelopment` smoke — doc with crops opens on View with boxes over a
fresh screenshot; empty doc opens on Add; refresh re-screenshots + re-locates; capture from a run
screenshot → Save → crop appears in View and its box lands where it was cut; desktop capture
with 3 s delay; simulated headless failure → inline message, no hang, Add still usable with the
browser source. selfTest green (its crops must keep matching). Unit test for
`TargetLocateAction`'s result shape over an injected synthetic screenshot (no Robot/Selenium).

---

## Phase 5 — Tolerant matching: NCC scores, per-document tolerance, multi-scale

**Goal:** matching survives antialiasing/theme/rendering noise — and, per the 2026-07-12
decision, **monitor-scale drift** — via score-based fallback with a user-selectable tolerance on
the Target document; "not found" reports how close the best candidate was. kzen-auto-jvm +
common + js (the View-section tolerance control).

### Design decisions

- **Exact match stays the fast path.** Score-based matching runs only when exact matching finds
  nothing (or when tolerance is explicitly below exact). The phase-1 benchmark bound must still
  hold for the exact path; add a second (more generous) bound for the NCC path.
- **Hand-rolled zero-mean grayscale NCC** in `TemplateMatcher` (no new dependency): luminance
  grid derived from `RgbGrid` once per image; integral images for windowed mean/variance; score
  candidate origins, return candidates above threshold as (rect, score), non-max-suppressed
  within a crop-sized neighbourhood. BoofCV is the sanctioned fallback — record in the as-built.
- **Per-document tolerance** (user decision — per Target, not per crop): a scalar attribute on
  the Target's `main` object, e.g. `tolerance: 0.85` (match score threshold, 1.0 = exact-only).
  Parsing lives in `TargetDocument` (it already holds `documentNotation`). **Absent = today's
  behaviour (exact-only)** — every existing Target doc remains valid and bit-identical in
  behaviour; the user opts into fuzziness per target.
  - **Calibration fixture:** `kzen-auto-jvm/src/test/resources/vision/
    rasterization-drift-{crop,screenshot}.png` — a real Target crop vs a separately captured
    screenshot of the same UI (exact match finds nothing — pinned by
    `TemplateMatcherTest.rasterizationDriftFindsNoExactMatch`). Best NCC measures **~0.85 at the
    true location** (also the global maximum). Turn this pair into the positive test and let it
    calibrate the UI's suggested tolerance levels (a slider or presets — e.g. Exact 1.0 /
    Strict 0.95 / Normal 0.85 / Loose 0.75 — decide against the fixture, record the choice).
- **Multi-scale matching — un-deferred** (user: different monitors use different scale; theme
  changes appearance). When tolerance < 1.0, additionally score the crop rescaled at a small
  pyramid of common DPR ratios (e.g. 0.67, 0.75, 0.8, 0.9, 1.1, 1.25, 1.5; bilinear); NMS across
  scales; a match reports its scale in diagnostics. Skipped entirely at exact tolerance. Keep the
  pyramid a constant in `TemplateMatcher` — not user-configurable until someone asks.
- **View-section integration (phase 4's screen):** the tolerance control (View section) edits the
  document attribute via the normal notation command path, and the locate overlay re-runs live —
  boxes annotated with scores (`0.91`) and scale when ≠ 1.0. `TargetLocateAction` passes
  tolerance through to `TargetLocator`.
- **Diagnostics:** not-found errors (and the View overlay) report the best candidate:
  `best score 0.91 at [412, 300] (tolerance 0.95) for crop "browser-pipeline.png"`.
- **Deferred, not dead:** per-crop metadata sidecar (labels, per-crop thresholds, click offsets)
  from the original phase-4 design — park until a concrete need; per-document tolerance is what
  the user asked for. Multi-crop semantics beyond OR-union stay in phase 6 (match policy).

**Verify:** unit tests — the rasterization-drift pair is found at (374, 518) at Normal tolerance
and rejected at exact; NCC finds a noise-perturbed patch exact misses and rejects it below
threshold; a 1.25×-rescaled patch is found via the pyramid; NMS collapses adjacent hits;
tolerance-less docs behave exactly as before; both benchmark bounds hold. selfTest (exact fast
path — bit-identical behaviour). Manual — drop the user's Target to Normal tolerance in View and
watch the desktop-captured crop's box light up with its score.

---

## Phase 6 — Open target-type set: locator SPI + registry, match policy, step dedup

**Goal:** adding a target type requires **zero shared-code edits** — the same contract Workers,
Steps, and Vertices already honour — and match policy becomes explicit and uniform. All three
modules; the largest phase.

### Design decisions

- **Common — dissolve the closed hierarchy.** `TargetSpec` becomes an interface; each type
  (`FocusTarget`, `TextTarget`, `XpathTarget`, `VisualTarget`) is an `@Reflect` class registered
  as a notation archetype (`is: TargetSpec`-style marker objects in `common-action.yaml`,
  mirroring how Worker/Step archetypes work). Delete the `TargetType` enum. The `target:`
  notation keeps its `{type, value}` map shape for backward compatibility, with `type` now
  resolving to a registered type's simple name — **every existing user document keeps working
  with no migration**.
- **Definer/creator become dispatch, not switch.** `TargetSpecDefiner`/`TargetSpecCreator` keep
  their notation-declared role (common-action.yaml) but resolve `type` against an autowired
  list of small per-type handlers (`TargetSpecType`: name; define value-notation →
  `AttributeDefinition`; create definition → spec instance). The Visual handler keeps its
  `ReferenceAttributeDefinition` + `partialGraphInstance` resolution — reference-typed target
  values remain a supported shape for third parties.
- **Server — per-type locator SPI.** Naming note (post-rename): the service is already called
  `TargetLocator`, so the SPI takes a distinct name — `interface TargetTypeLocator {
  fun canLocate(spec: TargetSpec): Boolean; suspend fun locate(spec, driver, context): Result }`,
  autowired `List<TargetTypeLocator>` into the `TargetLocator` service; the dispatch `when`
  (TargetLocator.kt:72-106) dissolves into a registry lookup. Focus/Text/Xpath/Visual become four
  registered locators (Visual owns the template-match path, the phase-5 tolerance machinery, and
  phase 2's preview exclusion).
- **Client — per-type editor/view fragments** resolved from an autowired list (the
  `WorkerDisplayWrapper` pattern): each target type contributes its editor row (the text field,
  the Target dropdown + link icon, …) and its summary line; `TargetSpecEditor` and
  `TargetAttributeView` become thin hosts that resolve by type name. The hardcoded label `when`s
  move into the fragments.
- **Match policy, uniform across types**: optional `policy` key on the `target:` map —
  `unique` (default, today's Visual behaviour) | `first` | `nth` (with `index`) | `best`
  (score-ranked; Visual-meaningful via phase 5's scores, others treat as `first`). This **fixes
  the Text/Visual inconsistency** (TextTarget's silent first-match becomes an explicit `first` —
  decide at implementation whether to grandfather Text's default to `first` for compatibility
  with existing selfTest docs, or migrate the handful of test yamls; prefer the latter, it's a
  small grep).
- **Browser-step dedup**: the five steps repeat locate → error → act → screenshot → traceDetail
  (BrowserClickStep ≈ Write ≈ Read ≈ Submit ≈ Focus). Extract the shared frame (helper or base
  class in `step/browser/`) so a step supplies only its action lambda. Also fold
  `BrowserClickStep`'s inline `input[type=submit]` special case into the helper's click action.
- **Third-party proof**: add a synthetic `CssSelectorTarget` (+ locator + editor fragment) under
  `src/main` test-fixtures style — the same convention as Job's synthetic workers (KSP/`@Reflect`
  requires `src/main`) — and a test that registers and locates through it **without any edit to
  the shared definer/creator/editor/service files**. This is the phase's acceptance criterion.
- `TargetDocument.screenshotTakerLocation` hardcoding a JVM notation path in common — acceptable
  coupling (the client must address the detached action), but move it beside the other REST-ish
  constants it belongs with if a natural home appears while editing; do not build new plumbing
  for it.

**Verify:** the third-party-proof test; all four built-in types still locate (selfTest covers
Text/Xpath/Visual live; add a Focus-target step to a tester script if none exercises it);
`:kzen-auto-js:build`; manual — editor type switching, Target dropdown + link, policy `nth` on a
deliberately ambiguous text target. Update `docs/architecture.md` (target SPI paragraph) and the
AGENTS.md god-object gotcha to cite targets as a conforming example.

---

## Phase 7 — Decision gate: desktop actuation, or park desktop capture

**This phase starts with a decision, not code.** Target currently captures from the desktop but
can only act through Selenium. Choose:

- **Branch A — desktop RPA is near-term.** Build the surface abstraction:
  `ActionSurface { suspend fun capture(): RgbGrid; suspend fun act(point, action) }` with
  `BrowserSurface` (wraps the existing WebDriver capture + `elementFromPoint` + WebElement
  actions) and `ScreenSurface` (AWT `Robot` capture + `mouseMove`/`mousePress`/`keyPress`
  actuation), each owning its own coordinate mapping (DPR for browser; multi-monitor origin +
  OS scaling for screen — extend `ScreenshotTaker`'s single-device assumption). New Script steps
  (`ScreenClickStep`, `ScreenWriteStep`) target a Target document against the screen surface;
  the phase-6 locator context becomes the surface instead of a raw `RemoteWebDriver`. Sizing:
  a full session, medium-high risk (input injection, focus stealing, OS permission quirks —
  macOS screen-recording/accessibility prompts).
- **Branch B — browser-first stands.** No code beyond docs: state in `docs/architecture.md` that
  desktop capture is a capture-source convenience (phase 4) and `ScreenshotTaker` is the future
  hook; keep phase 6's locator context browser-typed. Re-open this gate when a concrete desktop
  automation need lands.

Either branch: record the decision and rationale here as the as-built note. Do **not** let
branch A's abstraction leak into phases 2–6 speculatively — phase 6's locator context is designed
to be *retypeable*, which is all the pre-work branch A needs.

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 1 — vision core hardening | auto-jvm (+1 js fix) | done 2026-07-12 | — | — |
| 2 — correct clicking (bug) | auto-jvm + small js | one session | low-medium (root-cause unknown) | — |
| 3 — step-editor polish | auto-js | small (can ride with 2) | low | — |
| 4 — View/Add split + capture sources | auto-jvm + js | one session | low-medium (editor rework) | 2 (source verdict) |
| 5 — tolerant matching + tolerance | auto-jvm + common + js | one session | medium (matcher math) | 1 (benchmark guard), 4 (View hosts the control) |
| 6 — open target-type set | all three | one full session | medium (wide but pattern-proven) | 5 recommended (policy `best` needs scores) |
| 7 — decision gate | docs or auto-jvm | decision + 0–1 session | n/a or medium-high | 6 (locator context) |

Phase 2 first — the user's working script is broken today and its verdict shapes phase 4's
source design. Phases 3 and 4 are the visible UX payoff; 5 delivers the requested fuzzy
matching; 6 is the architectural payoff and can slip without blocking 2–5; 7 is deliberately
last and may be a one-paragraph docs change. If a session runs long, phases 2 and 4 both split
cleanly at their lettered/bulleted sub-items — note the split in the tracker.
