# Feature (visual action targets) improvements — phased plan

> **Rename note (2026-07-12):** the Feature concept was renamed to **Target** as the umbrella for
> element targeting (visual today; CSS/XPath/relational expressions planned). Old names in this
> document map as: archetype `Feature` → `Target` (UI title "Action Target" → "Target");
> `FeatureDocument` → `TargetDocument`; packages `…document.feature` → `…document.target` and
> `…server.objects.feature` → `…server.objects.target`; `FeatureController` → `TargetController`;
> `VisionService` → `TargetLocator` (moved to `server.service.target` — it dispatches all
> TargetSpec kinds). `service.vision` keeps `TemplateMatcher`/`RgbGrid`/`VisionUtils` as the
> visual-strategy engine. In the step editor, the type dropdown is labelled "Target Type" and the
> visual document selector "Target". Body text below predates the rename.

> **Status: planned.** Written 2026-07-06 from a design review of the Feature document type — the
> visual action-target manager for point-and-click RPA — across all three layers: common
> (`FeatureDocument` / `TargetSpec` / `TargetSpecDefiner` / `TargetSpecCreator`), server
> (`VisionUtils` / `RgbGrid` / `ScreenshotTaker` + the five `Browser*Step` consumers), and the JS
> client (`FeatureController` / `CropperWrapper` / `TargetSpecEditor` / `TargetAttributeView`).
> Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is self-contained: goal, design
> decisions (already made — do not re-litigate), concrete steps with file anchors, and
> verification. Phases are ordered by priority; only phase 3 has a soft prerequisite (2), and
> phase 6 is a **decision gate**, not a build order.
>
> All phases are **kzen-auto only** (no kzen-lib changes) — no publishToMavenLocal round-trips
> needed.
>
> Companion plans: `2026-07-06_script-improvements.md` (phase 2 there — browser resource survival
> across live edit — is what makes "capture from the active run's browser" reliable here) and
> `2026-07-06_job-improvements.md` (headless mode; phase 2 here must degrade gracefully in it).
>
> **Progress tracker** (update as phases land):
> - [x] Phase 1 — vision core hardening: tests + benchmark, matcher perf, DOM-mutation fix, definition robustness
>   (landed 2026-07-12; as-built: pure matcher extracted as `TemplateMatcher` — the plan's sanctioned
>   alternative — so the test is `TemplateMatcherTest` (+ `RgbGridTest`) rather than "VisionUtilsTest";
>   `VisionUtils` retains only `xpathEscape`; `Result` nested in `VisionService`; benchmark: 338 ms → 56 ms
>   on the common-colour pathological case. 1f riders: `onClientState`'s `TargetType.valueOf` also made
>   tolerant (malformed notation degrades to the existing early return instead of crashing the render);
>   `onTypeChange` cancels the pending text debounce — cancel, not flush, because `onBlur` already flushes
>   genuine pending text before a dropdown click, and a flush at switch time races the value-clearing
>   `setState`, emitting exactly the value-less map 1f suppresses.)
> - [ ] Phase 2 — same-pipeline capture: browser-sourced patches, desktop capture demoted + delay timer, headless grace
> - [ ] Phase 3 — locate-now preview in the editor + match diagnostics + documented technique boundary
> - [ ] Phase 4 — tolerant matching: NCC scores + thresholds + per-crop metadata sidecar (labels, offsets)
> - [ ] Phase 5 — open target-type set: locator SPI + registry, match policy, browser-step dedup
> - [ ] Phase 6 — decision gate: desktop actuation (ActionSurface) or park desktop capture

## Context — what the review found

The **integration skeleton is right and every phase preserves it**:

- **Crops as digested document resources.** PNGs live beside `~main.yaml`, listed in
  `resources.digests` — git-visible, served over the existing `/resource` REST path, digests give
  free cache keys and change detection. Best part of the design; nothing here changes it.
- **`target:` as structured notation.** The attribute-level wiring is already registry-driven:
  `TargetSpec` declares `by: TargetSpecDefiner / creator: TargetSpecCreator /
  editor: TargetSpecEditor` in notation (common-action.yaml:27-34), and the editor/view are
  resolved through the shared attribute-editor machinery, not hardcoded into Script.
- **Uniqueness enforcement as the default** (VisionUtils.kt:111-118) — failing loudly on an
  ambiguous visual match is the right RPA-safety default. The problem is it's the *only* policy.
- **The bit-exact cropper** (`CropperWrapper.getCroppedCanvas`, CropperWrapper.kt:76-117 — affine
  collapse + `imageSmoothingEnabled = false`) — careful work, required *because* matching is
  exact; phase 4 relaxes the constraint it serves but the exact fast path keeps using it.

The weaknesses live in five clusters:

1. **Capture pipeline ≠ match pipeline — the central reliability flaw.** The editor captures the
   **server's desktop screen** (`ScreenshotTaker` → AWT `Robot`, default monitor only,
   ScreenshotTaker.kt:23-32), but runtime matching runs against **Selenium's viewport screenshot**
   (`driver.getScreenshotAs`, VisionUtils.kt:104-106). Exact pixel equality across two different
   pixel pipelines (OS compositor readback vs Chrome's internal compositor) holds only when the
   SUT browser renders on the same machine, same monitor, 100% DPI, no browser zoom, target
   visible in the viewport. It breaks silently under DPI scaling, headless browsers, remote
   WebDriver, or a scrolled page. Side effects: opening a Feature doc screenshots *whatever is on
   the user's screen* (implicitly, on mount — FeatureController.kt:141-145, :160-164), the
   screenshot includes the kzen-auto UI itself with no delay timer to alt-tab away, and a headless
   server throws from `Robot` with the editor stuck on "&lt;taking screenshot&gt;" forever (the
   failure branch of `doRequestScreenshot` is silently dropped, FeatureController.kt:216-225).
2. **Exact equality with no scores, no tolerance, no diagnostics.** `matches()`
   (VisionUtils.kt:203-226) is all-or-nothing per pixel; every environmental delta (ClearType
   settings, theme, one-pixel text-layout shift) is a hard miss reported as bare "Target not
   found" — no best-candidate score, no per-crop breakdown. And the first feedback that a Feature
   works at all is a script failing at runtime: there is **no locate-preview in the editor**.
3. **Match semantics are underspecified.** N crops are OR'd alternates (`locateAll` unions all,
   VisionUtils.kt:162-184) and uniqueness is enforced **across the union** — two alternates that
   both match is a hard error, though alternates existing is presumably why the user added them.
   No ordinal selection, no best-match, no click offset (always patch centre), no per-crop labels
   (bare timestamp filenames, FeatureController.kt:277) or thresholds. Inconsistently,
   `TextTarget` silently takes the *first* match (VisionUtils.kt:50-61) while Visual demands
   uniqueness.
4. **The target-type set is closed — the god-object shape, applied to targets.** Adding one
   target type (CSS selector, ARIA role, OCR text) touches: `TargetType` enum (TargetType.kt),
   sealed `TargetSpec` (TargetSpec.kt), `TargetSpecDefiner`'s `when` (TargetSpecDefiner.kt:53-84),
   `TargetSpecCreator`'s `when` (TargetSpecCreator.kt:39-64), `VisionUtils.locateElement`'s `when`
   (VisionUtils.kt:41-76), `TargetSpecEditor` (`when` + labels, TargetSpecEditor.kt:335-362), and
   `TargetAttributeView` (`when` + labels, TargetAttributeView.kt:95-113, :159-178) — seven sites,
   three modules. A third-party module cannot add a target type at all. This is exactly the
   pattern `WorkerDisplayManager` / `StepDisplayManager` / `AttributeEditorManager` exist to avoid.
5. **The vision core is unengineered.** `RgbGrid.ofImage` calls `BufferedImage.getRGB(x, y)` per
   pixel (RgbGrid.kt:18-21) — ~3.7M ColorModel-converting calls for a 2560×1440 screenshot, an
   order of magnitude slower than one bulk `getRGB`. `locate` (VisionUtils.kt:187-200) scans
   origins to `source.width/height` and rejects out-of-bounds inside `matches`, keeps scanning
   after a second match (already fatal), and degenerates toward O(W·H·w) when the crop's (0,0)
   pixel is a common colour — i.e. the white background of most UI crops. Every step run
   re-reads and re-decodes every crop PNG with `runBlocking` inside a suspend call chain
   (VisionUtils.kt:172-178) despite the digests sitting right there as cache keys.
   `getElementByRectangle` (VisionUtils.kt:129-159) injects a random CSS class **into the page
   under test** to re-find the element and the TODO at :153 admits cleanup doesn't work — the SUT's
   DOM is permanently mutated; Selenium's `executeScript` can return the element directly. The
   scale correction (VisionUtils.kt:137-140) divides *outer window* width by *viewport* screenshot
   width — wrong whenever scrollbars or window decorations matter. `TargetType.valueOf` throws on
   malformed notation instead of a definition failure (TargetSpecDefiner.kt:51), and switching
   target type in `TargetSpecEditor` immediately upserts a value-less `target:` map
   (TargetSpecEditor.kt:192-193 → :264-294), failing the document definition (and blocking the run
   ribbon) until the value is typed. **Zero unit tests** cover `locate`/`matches`/`RgbGrid` — pure
   functions, trivially testable — and no benchmark guards the matcher.

Desktop RPA is currently **aspirational**: capture is desktop-based but there is no desktop
actuation (no Robot click/type steps; the only `locateAll` consumer is Selenium-bound). The
halfway state is the worst of both — phase 2 resolves the capture side, phase 6 is the explicit
decision on the actuation side.

**Covered elsewhere — do not re-do here:** browser-resource survival across live edit (script
plan phase 2 — phase 3 here reads the active run's browser through whatever that phase settles);
headless server mode itself (job plan — phase 2 here only ensures Feature degrades gracefully
inside it); client render-scoping discipline (script plan phase 8 — Feature's client surface is
small; apply the conventions, don't re-derive them).

**Deliberately out of scope** (decided; do not re-open inside a phase):
- **Recording mode** (watch the user click and generate steps) — the long-term point-and-click
  vision; needs its own analysis and probably a browser extension or CDP event tap. Not here.
- OCR / accessibility-tree / ML-embedding target types — become *possible* third-party locators
  after phase 5; none are built in this plan.
- Full-page capture + scroll orchestration (CDP `captureBeyondViewport`, auto-`scrollIntoView`
  search) — documented as a boundary in phase 3; revisit only if below-the-fold targets bite in
  practice.
- OpenCV/JavaCPP or any native dependency. Phase 4 hand-rolls NCC; **BoofCV (pure-JVM,
  Apache-2.0) is the sanctioned fallback** if the hand-rolled matcher proves finicky — record the
  swap in the as-built note.
- Piercing iframes / shadow DOM from `elementFromPoint` (documented boundary, phase 3).
- Multi-monitor selection — only if phase 6 chooses branch A.
- ~~Renaming `Feature`/`feature` packages to match the "Action Target" UI title.~~ Done 2026-07-12
  (see the rename note at the top): standardized on **Target** as the umbrella name, ahead of this
  plan's schedule, once the concept's future scope (selectors, surfaces, visual expressions) made
  the name decidable.

## Ground rules for every phase

- **No target-type-specific code in shared layers** — the whole point of phase 5, but phases 1–4
  must not make it worse (new behaviour hangs off the existing `when`s only where a `when` already
  exists, and moves into the registry in phase 5).
- **Crops stay pure PNG resources.** Metadata goes in notation (phase 4's sidecar attribute),
  never encoded into filenames or pixel data.
- **Dev loop:** kzen-auto only. `./gradlew -t :kzen-auto-jvm:classes` + IDE `BackendDevelopment`
  for server phases; `./gradlew :kzen-auto-jvm:frontendDevelopment -PjsWatch` for editor phases.
- **Verification baseline (every phase):** `./gradlew :kzen-auto-jvm:test` (includes the new
  `VisionUtilsTest` from phase 1 onward); `./gradlew :kzen-auto-test:selfTest` — it exercises a
  real Visual target end-to-end (`FizzBuzz/Loop/Insert Range.yaml:10-14` clicks
  `Actions/Plus Circle` by template match) plus Text and Xpath targets throughout. **Beware a
  stale tester JVM on port 18081 — kill it first.** Editor phases add a manual
  `frontendDevelopment` smoke.
- Mark the phase checkbox in this file's tracker when done; append an as-built note on deviation.

---

## Phase 1 — Vision core hardening: tests, perf, DOM-mutation fix, definition robustness

**Goal:** the matcher becomes tested, benchmarked, and an order of magnitude faster in its
constant factors; element resolution stops mutating the page under test; malformed/transient
notation stops throwing. Pure wins, no design change; kzen-auto-jvm + one small js fix.

### 1a. Tests and benchmark first

- New `VisionUtilsTest` (kzen-auto-jvm/src/test) over synthetic `BufferedImage`s: single match,
  no match, multiple matches, match at each corner and flush to the right/bottom edge, 1×1 crop,
  crop == source, crop larger than source. These pin behaviour before 1b/1c touch it.
- A micro-benchmark assert in a test (generous bound, like `FormulaStepTest`'s style): locate a
  32×32 crop in a synthetic 1920×1080 image dominated by the crop's background colour — the
  common-colour pathological case — completes well under a second. This is the regression canary
  for every matcher change in phases 1 and 4.

### 1b. `RgbGrid` — bulk read, flat storage

- Replace the per-pixel loop (RgbGrid.kt:18-21) with one bulk
  `image.getRGB(0, 0, width, height, null, 0, width)` into a **flat `IntArray`** with row stride;
  `get(x, y)` becomes `values[y * width + x]`. Drop the `Array<IntArray>` and the hand-written
  equals/hashCode (keep value semantics via the data-class over width/height + content — or make
  it a plain class; nothing depends on grid equality today).
- Alpha note: bulk `getRGB` returns ARGB like the per-pixel call — comparisons are unchanged.

### 1c. `locate` — bounds, early exit, rare-pixel probe

- Bound the scan loops to `source.width - target.width` / `source.height - target.height` and
  delete the out-of-bounds check inside `matches` (VisionUtils.kt:209-212).
- Early-exit the scan as soon as a **second** match is found *when the caller only needs
  uniqueness* — add a `limit: Int` parameter to `locate` (default unbounded; the unique path
  passes 2). Keep `locateAll`'s union semantics.
- **Rare-pixel probe:** one pass builds a coarse histogram of the screenshot (e.g. RGB
  quantized to 12 bits, `IntArray(4096)`); pick the crop pixel whose bucket is least frequent as
  the probe. The scan first compares only the probe pixel at its offset and runs the full window
  compare on probe hits. Exact-match semantics unchanged; kills the white-background degeneracy.
  (A crop that is *entirely* common-coloured still degenerates — acceptable, note in kdoc.)

### 1d. `VisionService` — decoded-crop cache, suspend, context-owned

- New `VisionService` registered in `KzenAutoContext` (constructor-wired like the other services;
  added to `graphEnvironment` so graph-instantiated steps can `@Service` it). It owns:
  - a bounded digest-keyed cache `Digest → RgbGrid` (`LinkedHashMap` LRU, ~64 entries — the
    digest comes free from `documentNotation.resources!!.digests`, VisionUtils.kt:168-172, so a
    re-captured crop can never serve stale pixels);
  - the moved `locateElement`/`locateAll`/`getElementByRectangle` entry points, with `locateAll`
    made **suspend** (delete the `runBlocking` at VisionUtils.kt:174-176 — every caller is already
    in a suspend chain via `ScriptStep.run`).
- The five browser steps (`BrowserClickStep.kt:37`, `BrowserWriteStep.kt:41`,
  `BrowserReadStep.kt:41`, `BrowserSubmitStep.kt:38`, `BrowserFocusStep.kt:38`) swap
  `@Service notationMedia` for `@Service visionService` (the service keeps `notationMedia`
  internally). No notation changes; KSP regenerates the module.
- `VisionUtils` keeps only the **pure** matching functions (`locate`, `matches`, `xpathEscape`) so
  1a's tests need no Selenium or context — or move those into a `TemplateMatcher` object the
  service delegates to; implementer's choice, keep pure-vs-effectful separation either way.

### 1e. Element resolution — no DOM mutation, honest scale

- Replace the random-class-name hack (VisionUtils.kt:142-156) with Selenium's native DOM-node
  return: `driver.executeScript("return document.elementFromPoint(arguments[0], arguments[1])",
  x, y) as WebElement`. Deletes the page mutation, the un-working cleanup TODO, and the second
  `findElement` round-trip.
- Replace the `window().size.width / screenshotWidth` ratio (VisionUtils.kt:137-140) with
  `executeScript("return window.devicePixelRatio")` — the actual CSS-px ↔ device-px factor. Guard:
  if the screenshot width ≠ round(viewport CSS width × DPR) (e.g. exotic driver), fall back to
  the screenshot-width ratio against `executeScript("return window.innerWidth")` (viewport, not
  outer window) and note it in the error message on failure.
- `elementFromPoint` can return null (point outside viewport after mapping) — surface a clear
  error instead of the current downstream NPE.

### 1f. Definition-layer robustness

- `TargetSpecDefiner`: `TargetType.valueOf(typeName)` (TargetSpecDefiner.kt:51) →
  `entries.find { it.name == typeName }` with `AttributeDefinitionAttempt.failure` on miss.
  Same for `TargetSpecCreator` (TargetSpecCreator.kt:34) — defensive `IllegalArgument` with a
  clear message is fine there (creator only runs after a successful definition).
- `TargetSpecEditor`: don't upsert an incomplete spec. On type change to Text/Xpath/Visual with a
  null value (TargetSpecEditor.kt:192-193, :297-303), hold the write until a value exists (the
  Focus type still writes immediately — it is complete with no value). This stops the transient
  definition failure that blocks the run ribbon mid-edit.

**Verify:** 1a's tests green before and after 1b/1c (behaviour pinned); benchmark bound holds;
`:kzen-auto-jvm:test`; selfTest (the Plus Circle visual click is the end-to-end proof, and 1e's
element-resolution swap is exercised by every Text/Xpath step in it); manual spot-check on a
scaled display (Windows 125/150%) that a visual click still lands.

---

## Phase 2 — Same-pipeline capture: browser-sourced patches

**Goal:** patches are captured from the **same pixel pipeline they will be matched against** —
the browser screenshot — making exact matching principled instead of coincidental. Desktop
capture stays as an explicit, secondary source with a delay timer, and degrades gracefully when
headless. kzen-auto-jvm + kzen-auto-js.

### Design decisions

- **The editor gains a source picker** with two sources:
  1. **Browser (run screenshots)** — the *primary* source. Every `Browser*Step` already emits a
     full `driver.getScreenshotAs` PNG into the run trace (`execution.traceDetail`,
     BrowserClickStep.kt:52-53); the client already knows how to fetch run history binaries
     (`ScriptProgressStore` precedent). The Feature editor lists the current/latest run's
     screenshots (thumbnail strip, most recent first) and feeds the selected one to the existing
     cropper. Pixels captured this way are **bit-identical by construction** to what
     `VisionUtils` will match against. No new server surface.
  2. **Screen (desktop)** — the existing `ScreenshotTaker` path, now explicit (a button, not a
     mount side effect) and with a **delay option** (0 / 3 / 10 s, client-side timer before the
     detached call) so the user can alt-tab to the target app. Kept for future desktop RPA
     (phase 6) and for capturing non-SUT applications.
- **Stretch (build only if the plumbing is already sufficient; otherwise flag for after script
  plan phase 2):** a "fresh browser screenshot" action that reaches the **active paused run's**
  browser resource and returns `getScreenshotAs` on demand — check whether the `/logic/request`
  channel (`CommonRestApi`) can route a request to the running logic's resource registry. If it
  needs new engine surface, don't build it here; the trace-screenshot source already covers the
  workflow (run the script to the state you want, pause, crop from the last step's screenshot).
- **Stop auto-screenshotting on mount.** Opening a Feature doc shows the existing crops and the
  source picker; nothing is captured until the user asks (removes the surprise/privacy issue and
  the headless hang). Delete the `requestingScreenshot` choreography across
  `componentDidMount`/`componentDidUpdate` (FeatureController.kt:141-169) in favour of a direct
  async call per user action.
- **Headless grace:** `ScreenshotTaker.execute` catches `HeadlessException`/`AWTError` and
  returns `ExecutionFailure("Screen capture unavailable (headless server)")`; the editor renders
  failures (today only `ExecutionSuccess` is handled, FeatureController.kt:216-225) as an inline
  message with the browser source still offered.
- Editor hygiene riding along: fix the `data:png/png` MIME typo (FeatureController.kt:219);
  remove the vestigial "Capture" button state (`capturedDataUrl` intermission,
  FeatureController.kt:288-292, :339-346) — after Save the new crop simply appears in the
  resource list.

**Verify:** manual `frontendDevelopment` smoke — capture a crop from a run screenshot, use it as
a Visual target, run: exact match succeeds; capture from desktop with 3 s delay; open the editor
under a headless-style failure (temporarily throw in `ScreenshotTaker`) → message, no hang.
selfTest still green (its crops were desktop-captured — they must keep matching, proving the
desktop path still works where it used to).

---

## Phase 3 — Locate-now preview + diagnostics + documented boundary

**Goal:** a Feature can be tested from the editor — the first feedback that a target matches is
no longer a script failure at runtime — and locate failures explain themselves. kzen-auto-jvm +
kzen-auto-js. Soft prerequisite: phase 2 (reuses its screenshot-source picker).

### Design decisions

- **New detached action `FeatureLocateAction`** (server, `objects/feature/` beside
  `ScreenshotTaker`): takes the Feature's document path (+ source selector) in the request
  params, produces a screenshot (per source: desktop, or — stretch, same caveat as phase 2 — the
  active run's browser), runs `VisionService.locateAll`, and returns a structured result: the
  screenshot PNG (binary) + per-crop match rectangles and counts (detail value). Uniqueness is
  **not** enforced here — the preview's job is to show everything that matches.
- **Editor "Locate" button**: renders the screenshot with rectangle overlays (absolutely
  positioned divs over the scaled `img` — scale factor = displayed/natural size; no canvas
  needed) and a per-crop result line: `crop 3 — 1 match`, `crop 1 — no match`,
  `crop 2 — 4 matches (would fail uniqueness)`.
- **Runtime error enrichment** (`VisionService.locateElement`): "Target not found" and "More than
  one target found" (VisionUtils.kt:112-118) gain per-crop detail — which crops matched where,
  sizes compared — so a failed run's trace explains *why*. (Phase 4 adds best-candidate scores to
  the not-found case.)
- **Documented boundary** — add a short section to `kzen-auto/docs/architecture.md` (or a
  `docs/feature.md` it links): Feature ≙ "Action Target" (UI title); matching is
  viewport-only (below-the-fold targets need the page scrolled into place first);
  resolution/theme-bound (a crop captured at one DPR/theme doesn't survive a change —
  phase 4 loosens but doesn't remove this); `elementFromPoint` semantics (topmost element wins —
  overlays intercept; a cross-iframe target resolves to the iframe element itself; shadow-DOM
  hosts resolve to the host). These are the technique's edges, not bugs.

**Verify:** manual — locate a known-good Feature against a run screenshot: rectangle lands on the
target; add a second copy of the patch to the page: two rectangles + the uniqueness warning;
locate a stale Feature: per-crop "no match" lines. Unit test for `FeatureLocateAction`'s result
shape over a synthetic screenshot source (inject the image, no Robot/Selenium). Baseline +
selfTest.

---

## Phase 4 — Tolerant matching: scores, thresholds, per-crop metadata

**Goal:** matching survives antialiasing/theme/rendering noise via score-based fallback with
per-crop thresholds; crops gain names and click offsets; "not found" reports how close the best
candidate was. kzen-auto-jvm + common + light js.

### Design decisions

- **Exact match stays the fast path.** Score-based matching runs only when exact matching finds
  nothing (or when the crop's threshold is explicitly < 1.0). The phase-1 benchmark bound must
  still hold for the exact path; add a second (more generous) bound for the NCC path.
- **Hand-rolled zero-mean grayscale NCC** in the pure matcher (no new dependency): luminance
  grid derived from `RgbGrid` once per image; integral images for windowed mean/variance; score
  every candidate origin, return candidates above threshold as (rect, score), non-max-suppressed
  within a crop-sized neighbourhood. Default threshold **0.95**, constant in `VisionService`.
  **Calibration fixture (added 2026-07-12):** `kzen-auto-jvm/src/test/resources/vision/
  rasterization-drift-{crop,screenshot}.png` — a real Action Target crop vs a separately captured
  desktop screenshot of the same UI (glyph rasterized 19x12 vs 18x11; exact match finds nothing —
  pinned by `TemplateMatcherTest.rasterizationDriftFindsNoExactMatch`). Best NCC measures ~0.85 at
  the true location, which is also the global maximum — **below the 0.95 default**. Turn this pair
  into the phase's positive test and re-examine the default (or lean on per-crop thresholds) with
  it in hand.
  If implementation proves finicky, BoofCV is the sanctioned fallback (see out-of-scope) —
  record in the as-built.
- **Per-crop metadata sidecar** — a `crops:` map attribute on the Feature's `main` object, keyed
  by resource filename:
  ```yaml
  main:
    is: Feature
    crops:
      20260617_213159_617.png:
        label: "add-step plus button"
        threshold: 0.9        # optional; omit = exact-then-default-NCC
        clickOffset: [18, 0]  # optional; px right/down from patch centre
  ```
  Absent entries mean today's behaviour — **all existing Feature docs remain valid unchanged**.
  Parsing lives in `FeatureDocument` (it already holds `documentNotation`; no new definer). The
  match pipeline applies threshold per crop; `getElementByRectangle` applies `clickOffset` after
  centre computation. `RemoveResourceCommand` handling in the editor also removes the crop's
  sidecar entry (single command sequence).
- **Editor**: label + threshold + offset editing per crop row (plain fields next to the existing
  delete button; labels render in the phase-3 locate results and in `TargetAttributeView`'s
  tooltip). Keep it minimal — no new sub-store; the controller already round-trips notation
  commands.
- **Diagnostics**: not-found errors (and phase 3's preview) report the best candidate:
  `best score 0.91 at [412, 300] (threshold 0.95) for crop "add-step plus button"`.
- Multi-scale matching (DPR drift) stays **out** — with phase 2, capture and match share a
  pipeline, so scale drift means the environment changed; the score/threshold reporting makes
  that visible instead of silently guessing. Revisit only with concrete need.

**Verify:** unit tests — NCC finds a Gaussian-noise-perturbed patch that exact matching misses,
rejects it below threshold, non-max suppression collapses adjacent hits, `clickOffset` shifts the
resolved point, sidecar-less docs behave exactly as before; both benchmark bounds hold; selfTest
(exact fast path — must be bit-identical in behaviour); manual — drop a crop's threshold and
watch the preview scores.

---

## Phase 5 — Open target-type set: locator SPI + registry, match policy, step dedup

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
  their notation-declared role (common-action.yaml:30-34) but resolve `type` against an autowired
  list of small per-type handlers (`TargetSpecType`: name; define value-notation →
  `AttributeDefinition`; create definition → spec instance). The Visual handler keeps its
  `ReferenceAttributeDefinition` + `partialGraphInstance` resolution (TargetSpecCreator.kt:53-63)
  — reference-typed target values remain a supported shape for third parties.
- **Server — `TargetLocator` SPI**: `interface TargetLocator { fun canLocate(spec: TargetSpec):
  Boolean; suspend fun locate(spec, driver, context): Result }`, autowired `List<TargetLocator>`
  into `VisionService`; `locateElement`'s `when` (VisionUtils.kt:41-76) dissolves into a registry
  lookup. Focus/Text/Xpath/Visual become four registered locators (Visual owns the template-match
  path and the phase-4 machinery).
- **Client — per-type editor/view fragments** resolved from an autowired list (the
  `WorkerDisplayWrapper` pattern): each target type contributes its editor row (the Text field,
  the Feature dropdown, …) and its summary line; `TargetSpecEditor` and `TargetAttributeView`
  become thin hosts that resolve by type name. The hardcoded label `when`s
  (TargetSpecEditor.kt:343-348, TargetAttributeView.kt:159-178) move into the fragments.
- **Match policy, uniform across types**: optional `policy` key on the `target:` map —
  `unique` (default, today's Visual behaviour) | `first` | `nth` (with `index`) | `best`
  (score-ranked; Visual-meaningful, others treat as `first`). This **fixes the Text/Visual
  inconsistency** (TextTarget's silent first-match, VisionUtils.kt:50-61, becomes an explicit
  `first` — decide at implementation whether to grandfather Text's default to `first` for
  compatibility with existing selfTest docs, or migrate the handful of test yamls; prefer the
  latter, it's a small grep).
- **Browser-step dedup**: the five steps repeat locate → error → act → screenshot → traceDetail
  (BrowserClickStep.kt:33-56 ≈ Write ≈ Read ≈ Submit ≈ Focus). Extract the shared frame (helper
  or base class in `step/browser/`) so a step supplies only its action lambda. Also fold
  `BrowserClickStep`'s inline `input[type=submit]` special case (:44-50) into the helper's click
  action.
- **Third-party proof**: add a synthetic `CssSelectorTarget` (+ locator + editor fragment) under
  `src/main` test-fixtures style — the same convention as Job's synthetic workers (KSP/`@Reflect`
  requires `src/main`) — and a test that registers and locates through it **without any edit to
  the shared definer/creator/editor/service files**. This is the phase's acceptance criterion.
- `FeatureDocument.screenshotTakerLocation` hardcoding a JVM notation path in common
  (FeatureDocument.kt:24-29) — acceptable coupling (the client must address the detached action),
  but move it beside the other REST-ish constants it belongs with if a natural home appears while
  editing; do not build new plumbing for it.

**Verify:** the third-party-proof test; all four built-in types still locate (selfTest covers
Text/Xpath/Visual live; add a Focus-target step to a tester script if none exercises it);
`:kzen-auto-js:build`; manual — editor type switching, Visual dropdown, policy `nth` on a
deliberately ambiguous text target. Update `docs/architecture.md` (target SPI paragraph) and the
AGENTS.md god-object gotcha to cite targets as a conforming example.

---

## Phase 6 — Decision gate: desktop actuation, or park desktop capture

**This phase starts with a decision, not code.** Feature currently captures from the desktop but
can only act through Selenium. Choose:

- **Branch A — desktop RPA is near-term.** Build the surface abstraction:
  `ActionSurface { suspend fun capture(): RgbGrid; suspend fun act(point, action) }` with
  `BrowserSurface` (wraps the existing WebDriver capture + `elementFromPoint` + WebElement
  actions) and `ScreenSurface` (AWT `Robot` capture + `mouseMove`/`mousePress`/`keyPress`
  actuation), each owning its own coordinate mapping (DPR for browser; multi-monitor origin +
  OS scaling for screen — extend `ScreenshotTaker`'s single-device assumption,
  ScreenshotTaker.kt:23-28). New Script steps (`ScreenClickStep`, `ScreenWriteStep`) target a
  Feature against the screen surface; `TargetLocator.locate` (phase 5) gains the surface as its
  context instead of a raw `RemoteWebDriver`. Sizing: a full session, medium-high risk (input
  injection, focus stealing, OS permission quirks — macOS screen-recording/accessibility
  prompts).
- **Branch B — browser-first stands.** No code beyond docs: state in `docs/architecture.md` that
  desktop capture is a capture-source convenience (phase 2) and `ScreenshotTaker` is the future
  hook; keep phase 5's locator context browser-typed. Re-open this gate when a concrete desktop
  automation need lands.

Either branch: record the decision and rationale here as the as-built note. Do **not** let
branch A's abstraction leak into phases 1–5 speculatively — phase 5's locator context is designed
to be *retypeable*, which is all the pre-work branch A needs.

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 1 — vision core hardening | auto-jvm (+1 js fix) | one session | low | — |
| 2 — same-pipeline capture | auto-jvm + js | one session | low-medium (editor rework) | — |
| 3 — locate-now preview | auto-jvm + js | small session | low | 2 (source picker) |
| 4 — tolerant matching | auto-jvm + common | one session | medium (matcher math) | 1 (benchmark guard) |
| 5 — open target-type set | all three | one full session | medium (wide but pattern-proven) | 4 recommended (policy `best` needs scores) |
| 6 — decision gate | docs or auto-jvm | decision + 0–1 session | n/a or medium-high | 5 (locator context) |

Phases 1–3 are the high-priority core (perf + the capture-pipeline flaw + the missing feedback
loop); 4 unlocks robustness; 5 is the architectural payoff and can slip without blocking 1–4;
6 is deliberately last and may be a one-paragraph docs change. If a session runs long, phases 1
and 2 both split cleanly at their lettered sub-items — note the split in the tracker.
