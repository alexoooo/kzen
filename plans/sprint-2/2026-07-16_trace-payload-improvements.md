# Trace payload + transport efficiency — phased plan

> **Status: planned.** Written 2026-07-16 from a HAR capture of a `FizzBuzz.yaml` run (a
> browser-automation Script that screenshots each action): 193 requests over 50.6 s moving
> **21.5 MB**. The capture *confirmed* E5's request-count work is behaving exactly as designed
> (one long-lived `/logic/events` SSE stream ~50 s; only 5 `/logic/status` polls — the 10 s
> push-healthy cadence; ~46 publish cycles ≈ 0.9/s — the 1 s throttle; a working incremental
> history watermark, `since-sequence` 0→347). What it surfaced is a **byte-volume** axis E5 never
> targeted: screenshots serialized as inline base64 in trace JSON dominate the transfer. Executor:
> **Opus 4.8 xhigh, one phase per session.** Each phase is self-contained: goal, design decisions
> (already made — do not re-litigate), concrete steps with file anchors, and verification. Phases
> are ordered by value; all are largely independent (see the supersession/prereq notes).
>
> Companion plans (file names updated 2026-07-16 for the Sprint-1 consolidation):
> `sprint-1/2026-07-05_logic-engine-improvements.md` (E — the engine/transport below, complete;
> Phase 5's as-built "Still open" list is where findings #1/#3 and the pulled-in structural-version
> item were first parked — both now live HERE, as TP3/TP4; nothing in this plan depends on the
> sprint-1 copy), `2026-07-16_script-client-sweep.md` (S — 8a `ScriptProgressStore` hot paths sit
> next to this work; Script's S7 trace bounding landed in Sprint 1), and
> `2026-07-16_serialization-improvements.md` (SER — SER4 migrates the trace/status wire DTOs;
> soft-coordinate with TP3/TP4). See "Covered elsewhere" below; do not duplicate their items.
>
> **Progress tracker** (update as phases land):
> - [x] Phase 1 — HTTP response compression (Ktor `Compression`; exclude SSE + octet-stream) —
>   **DONE 2026-07-16.** `install(Compression)` in `KzenAutoMain.ktorMain` (gzip/deflate,
>   `minimumSize(1024)`, exclude `text/event-stream` + `application/octet-stream`) +
>   `ktor-server-compression` dep. Runtime-verified on the booted server: a real response gzips
>   (2.45 MB → 646 KB, ~74%); `/logic/events` carries no `Content-Encoding` and its status frame
>   still flushes immediately. kzen-shell proxy relays it end-to-end unchanged (code-verified: its
>   CIO client installs no `ContentEncoding` plugin, forwards `Accept-Encoding` up and
>   `Content-Encoding` back, byte-copies the body). Deferred to a dev-loop smoke pass:
>   proxy-through-browser render, `selfTest`, and the FizzBuzz HAR ~25–40% delta.
> - [ ] Phase 2 — thin post-settle trace fetch — **optional stopgap, default: skip** (superseded
>   by Phase 3; execute only if Phase 3 slips a release and the 10 MB settle fetch hurts now)
> - [x] Phase 3 — trace binaries by content-addressed handle (blob endpoint + immutable cache) —
>   **DONE 2026-07-16.** kzen-lib: new `BinaryHandleExecutionValue(run, hash, size, mime)` under a sealed
>   `BinaryValue` parent (chosen over nullable-bytes for compile-time byte-consumer safety), with a
>   `binary-handle` JSON branch + round-trip test. Server: `RunEngineLogicTrace.toWireValue` maps each
>   `BinaryExecutionValue` → handle at BOTH projection seams (`nodeEntries` live + `lookupRunHistory`),
>   hashed by `Digest.ofBytes(bytes).asString()`; new `lookupBinary(run, hash)` resolves bytes from the
>   union of live map + film-strip history; new first-class `/logic/trace-binary` route (octet-stream,
>   `Cache-Control: public, immutable`, 404 when non-retained/unknown — NOT via the JSON-only
>   `LogicTraceEndpoint`), wired through `RestHandler` (new `RunEngineLogicTrace` ctor dep). Client: the
>   single choke point `StepImage.pngUrl` accepts `BinaryValue` and builds the blob URL for a handle; ~20
>   `is BinaryExecutionValue` image gates widened to `BinaryValue`; the one byte-consumer the plan missed
>   (`TargetController` locate-from-trace) fetches the blob via `ClientRestApi.logicTraceBinaryBytes`.
>   Verified headless: kzen-lib publishToMavenLocal → kzen-auto `--refresh-dependencies`;
>   `:kzen-auto-jvm:test` + `:kzen-auto-js:compileKotlinJs` green; booted jar, blob route 404s cleanly
>   (our handler, not Ktor default) for a non-retained run + missing params. Deferred to a dev-loop smoke
>   pass (needs the browser): a FizzBuzz run showing no `iVBOR` base64 in `lookup-run*` JSON, each image
>   fetched once + browser-cached, film strip/thumbnails/fullscreen + TargetController locate render, proxy
>   relay, `selfTest`, HAR delta.
> - [x] Phase 4 — server-side structural version on `LogicStatus` (exact structural re-fetch) —
>   **DONE 2026-07-16.** kzen-lib: new `LogicStatus.structureVersion: Long` (top-level sibling of `epoch`,
>   string-encoded round-trip). kzen-auto-jvm: `ServerLogicController` computes it **lazily in
>   `@Synchronized status()`** by diffing a `StructureSignature(epoch, runId?, runState?, unfiltered
>   snapshot.root node-id set)` — no reactive bump sites (epoch rides in); threaded into all three `status()`
>   returns; `ServerLogicControllerStatusObserverTest` extended for monotonicity + **stability** (two reads of
>   an unchanged run are identical). kzen-auto-js: `structureVersion()` reads the server value verbatim,
>   `traceVersion()` = `structureVersion\|sequence`; `tracedDocuments()` memo + `ScriptProgressStore`'s
>   `lookupRunExecutions` fetch (cached) now gate on `structureVersion`. Descent-into-child (execution created)
>   bumps it → immediate publish → the E5 intra-step animation returns for free; the within-child raw-position
>   refinement was **deferred** (re-opens the throttle cost). Verified headless: kzen-lib `publishToMavenLocal`
>   → kzen-auto `--refresh-dependencies`; `:kzen-auto-jvm:test` (full suite) + `:kzen-auto-js:compileKotlinJs`
>   green. Deferred to a dev-loop smoke pass (needs the browser): re-capture the FizzBuzz HAR to confirm
>   `traced`/`lookup-run-executions` drop ~46→~15-17 and the descent repaints immediately (a plain Script still
>   throttled), + `selfTest`. **SER4 ↔ TP4:** TP4 landed first; SER4 adds this string-`Long` to the migrated
>   kotlinx DTO.

## Context — what the HAR showed

The 193-request / 21.5 MB capture broke down as: 185 `/action/detached` trace calls, 5
`/logic/status`, 1 `/logic/startRun`, 1 `/logic/events` (the SSE stream, ~50 s), 1 icon fetch. The
detached calls were the four documented per-publish trace queries plus one settle call:

| detached action | calls | total bytes | note |
|---|---|---|---|
| `lookup-run-history` | 46 | ~10.98 MB | correctly incremental (`since-sequence` advances); big because each delta carries new screenshots |
| `lookup-run` | **1** | **~10.48 MB** | a single whole-run merged snapshot fired **at settle**, re-embedding all 71 nodes' last screenshots |
| `lookup` | 45 | ~37 KB | per-execution live map — small |
| `lookup-run-executions` | 46 | ~49 KB | grows slowly; re-fetched every publish |
| `traced` | 46 | ~20 KB | ~never changes mid-run; re-fetched every publish |

Three findings, all **pre-existing and independent of E5** (the wall-clock bug E5 fixed had merely
masked them by making everything expensive):

1. **The ~10.48 MB post-settle `lookup-run`** duplicates screenshot bytes already streamed through
   the incremental history — pure re-download. → **Phase 2** (stopgap) / subsumed by **Phase 3**.
2. **No HTTP compression** — `Content-Encoding: null` on every response; base64-of-PNG and the JSON
   envelope ship raw over loopback. → **Phase 1**.
3. **Screenshots are inline base64** in the trace JSON, so even the correctly-incremental history
   moved ~11 MB; base64 adds a 33 % tax and every snapshot/delta that references a screenshot
   re-serializes its bytes. → **Phase 3**.

Findings #1 and #3 were already parked in E5's as-built "Still open" item 2 and the master plan's
trace-binary push-back, both routed here (the Script plan's trace-retention neighbourhood) *pending
a decision*. The decision is **taken 2026-07-16: reference trace binaries by handle** (Phase 3).
Phase 4 pulls in E5's other parked item (a server-side structural version on `LogicStatus`) so the
whole trace-network cleanup is planned in one place.

## Covered elsewhere (do not duplicate)

- **The request-count / SSE / throttle work is E5 and is done** — this plan does not touch the
  publish/poll/SSE machinery except where Phase 4 refines the throttle's *signal*. The floor E5 left
  (`lookup` + `lookupRunHistory` genuinely fresh per publish) is what Phase 4 makes exact.
- **`ScriptProgressStore` hot paths** (memoize `analyze`, stop re-sorting the timeline, incremental
  RunStep representatives) are **script-sweep 8a** (`2026-07-16_script-client-sweep.md`).
  Phases 2/3 touch the same file — whichever of 8a and TP2/TP3 runs second skims the other's
  as-built first.
- **Generic binary `ExecutionValue` serialization** stays base64 — Phase 3 is deliberately scoped to
  the LogicTrace projection only (see its decisions). The Target-doc `ScreenshotTaker` detached
  result keeps rendering inline.

## Ground rules for every phase

- Verification baseline: `:kzen-auto-jvm:test` + `:kzen-auto-js:compileKotlinJs` green, plus the
  phase's own manual/HAR check. A kzen-lib change ships via `publishToMavenLocal` → rebuild kzen-auto
  with `--refresh-dependencies`.
- Wire changes ship both sides in the same session (client + server), and update
  `kzen-auto/docs/architecture.md` §3/§5 where the REST surface or trace model changes.
- No flavour-specific logic in general layers (CLAUDE.md "god object" rule): the binary-handle
  representation (Phase 3) is general to *any* binary trace value, never screenshot-specific.
- Re-capture a FizzBuzz HAR as the empirical check — the numbers in Context are the before.

---

## Phase 1 — HTTP response compression

**Goal:** gzip/deflate the JSON + text trace/detached/logic-status responses, recovering most of
base64's 33 % expansion (deflate over base64 approaches the raw compressed-PNG size) and compressing
the JSON envelope — near-zero effort, and it helps all three progress stores (Script/Flow/Job), not
just Script. kzen-auto-jvm only; independent of the other phases.

**Prerequisite:** none.

### Design decisions

- **Dependency**: add `io.ktor:ktor-server-compression:$ktorVersion` to
  `kzen-auto-jvm/build.gradle.kts` (dependency block at lines 62-67). `ktorVersion = 3.5.1` is pinned
  in `buildSrc/src/main/kotlin/Dependencies.kt:12`.
- **Install site**: `install(Compression)` in `Application.ktorMain` (`KzenAutoMain.kt:136-148`),
  **after** `install(SSE)` (line 146) and **before** `routing { … }` (line 148). This is the single
  shared module both dev mains inherit (`BackendDevelopment.backendDevelopmentMain` and
  `FrontendDevelopment.frontendDevelopmentMain` both call `ktorMain`), so no dev-main edit is needed.
- **Exclude `text/event-stream`** — the `/logic/events` SSE (`sse(...)` in `routeLogic`,
  `KzenAutoMain.kt:265`) must never be buffered/compressed: compression would break incremental
  framing/flush and defeat the whole push design. Ktor's `Compression` matches by content type — use
  `excludeContentType(ContentType.Text.EventStream)`.
- **Exclude `application/octet-stream`** — the `resource` PNG route (`KzenAutoMain.kt:472-475`) serves
  already-compressed bytes; gzip there wastes CPU for ~0 gain. (Phase 3's blob endpoint also rides
  octet-stream, so this exclusion covers it too.)
- **`minimumSize(~1 KB)`** so the tiny `text/plain` control-verb responses (`logicCancel`/`logicStep*`
  etc. via `respondText`) aren't compressed. Compress `application/json` (the `lookupRun` / `lookup` /
  history detached bodies — the actual win) and larger `text/plain` / YAML `notation` responses.
- **Cross-repo risk — the kzen-shell proxy leg is a required test, not an afterthought.** The proxy
  relays via `respondBytesWriter` + `copyTo` and forwards headers (E5 as-built). Confirm it neither
  (a) auto-decompresses upstream — its shared CIO client's `ContentEncoding` plugin would strip
  `Content-Encoding` and deliver plaintext (correct but wasteful; if so, forward `Accept-Encoding` so
  compression is end-to-end, or leave it and accept the loss on the proxied leg only) — nor (b)
  corrupts the gzip byte-stream when it re-frames chunked. This is the same class of surprise E5 hit
  with the proxy's missing CIO `HttpTimeout`.

**Out of scope:** compressing the SSE stream, or app-level compression of already-compressed blobs.
No wire-format change — this is purely a transport encoding.

**Verify:** build; `curl -H 'Accept-Encoding: gzip'` a `lookupRun` detached call → `Content-Encoding:
gzip` with wire size ≪ content size; `curl` `/logic/events` → **no** `Content-Encoding`, stream and
15 s heartbeats still flow; a compressed detached response arrives intact through the kzen-shell proxy
and the browser renders; `selfTest`; re-capture a FizzBuzz HAR → the JSON detached calls' transfer
size drops ~25-40 %.

---

## Phase 2 — Thin post-settle trace fetch (stopgap)

**Goal:** eliminate the single ~10.48 MB `lookup-run` fired once at settle, which re-embeds every
node's last screenshot — bytes the client already holds from the incremental history. Small,
independently-shippable relief of the settle spike; **superseded by Phase 3**.

**Prerequisite:** none. Skip this phase entirely if going straight to Phase 3 (which makes the fetch
thin automatically).

### Design decisions

- **The switch** is `ScriptProgressStore.refresh()` (`ScriptProgressStore.kt:82-96`): with a live
  frame it calls the per-execution `lookupQuery` (small); on settle `activeFrame` goes null and it
  falls to the whole-run `lookupRunQuery` (query `/`, the ~10 MB payload with binaries).
- **Reconstruct-from-history is NOT sufficient**, so keep the snapshot fetch but make it binary-thin.
  Post-S7, Script step traces emit with `retain = false`, so per-path *non-binary* Done state/display
  lives only in the node live map, **not** in history — the `execution.log` film strip retains the
  screenshots but not the step-state snapshot. Dropping the fetch would blank each step's post-run
  Done state; dropping only the *binary* from it loses nothing (screenshots come from history).
- **Add an `excludeBinary` mode to the trace lookup.** `LogicTraceQuery`
  (`kzen-lib .../exec/logic/trace/model/LogicTraceQuery.kt`) today carries *only* a `prefix` — add an
  `excludeBinary: Boolean = false` flag (and fold it into `asString()`/parse). Honour it in
  `RunEngineLogicTrace.nodeEntries` / `filterAndRetain` (`RunEngineLogicTrace.kt:217,233`, reached
  from `lookupRun` at `:127`) by dropping `BinaryExecutionValue` details from the projected snapshot.
  Thread the flag through `LogicConventions` (a new param) and `LogicTraceEndpoint.actionLookupRun`
  (`LogicTraceEndpoint.kt:67`).
- **Client**: `ScriptProgressStore.lookupRunQuery` passes `excludeBinary = true` at settle. Per-step
  canvas thumbnails already fall back to the history-derived representative — `StepImageThumbnail`
  resolves its screenshot from `scriptState.progress.representativeFrame(...)` **or**
  `computeStepTraceInfo(...).trace?.detail` — so stripping the snapshot's detail is invisible; the
  film strip (`RunStepDisplay`, `PageScreenshots`) is history-sourced regardless.

**Out of scope:** thinning the live per-execution `lookup` (already ~800 B) or `lookupRunHistory`
(that carries the film strip by design — Phase 3 handles its bytes). No client render change beyond
the query flag — the existing history fallback already covers it.

**Verify:** re-capture the HAR → the settle `lookup-run` drops from ~10 MB to <100 KB; the post-run
canvas still shows each step's final screenshot and Done state; the film strip is intact; `selfTest`.

---

## Phase 3 — Trace binaries by content-addressed handle

**Goal:** stop embedding screenshot bytes as base64 in trace JSON. A binary trace value serializes as
a content-hash handle; a cacheable blob endpoint serves each unique image once (`immutable`). This
removes the base64 tax on the incremental history (~11 MB) **and** the settle re-download (subsumes
Phase 2), and makes each screenshot transfer exactly once regardless of how many snapshots/deltas
reference it. kzen-lib + kzen-auto-jvm + kzen-auto-js (trace wire change).

**Prerequisite:** none hard. Supersedes Phase 2; composes with Phase 1 (afterward the trace JSON has
little base64 left to compress, and the blob bytes ride the octet-stream exclusion).

### Design decisions

- **Scope to the LogicTrace wire, NOT global `ExecutionValue.toJsonCollection`.** The generic binary
  branch (`kzen-lib ExecutionValue.kt:233` encode / `:119` decode) also serves the Target-document
  `ScreenshotTaker` detached result that is rendered directly (`ScreenshotTaker.kt:38`) — leave it
  base64. The handle representation applies **only** where `RunEngineLogicTrace` projects trace
  values for the wire (`LogicTraceSnapshot.asCollection` → `LogicTraceEntry.toCollection`, and
  `LogicTraceEvent.toCollection` for history). Per the "no type-specific logic in general kzen code"
  rule, the handle is general to any binary trace value — not screenshot-specific.
- **Content address = the existing `Digest` primitive.** `BinaryExecutionValue` already implements
  `Digestible`, so `Digest.ofBytes(bytes)` (`kzen-lib util/digest/Digest.kt:87`) → `asString()` is a
  ready key — no new hashing, no crypto dependency. Precedent for exposing digests over REST:
  `RestHandler.scan()` already returns `resources.digests`.
- **Wire shape:** a binary trace entry serializes as `{type: binary-handle, hash, size, mime}` in
  place of `{type: binary, value: <base64>}`. The engine already retains the bytes (`node.live` and
  history `TraceEvent.value` in `RunEngine`); index them by hash so the blob endpoint can resolve.
- **Blob endpoint:** a new hash-addressed GET on the `/logic` surface — e.g.
  `LogicConventions.actionLookupBinary` → `/logic/trace-binary?run=<id>&hash=<hash>`, served by
  `LogicTraceEndpoint`, resolving via a new `RunEngineLogicTrace.lookupBinary(runId, hash): ByteArray?`
  — returning `application/octet-stream` with `Cache-Control: public, immutable` (a content hash is
  by definition immutable). Retained-run lifetime = trace lifetime (the retained engine is disposed on
  the next run's `start`, per architecture §3) — acceptable: a stale handle simply 404s and the
  thumbnail falls back to blank, same as any cleared trace.
- **Client render — one choke point.** `StepImage.pngUrl(screenshot)`
  (`kzen-auto-js .../script/display/image/StepImage.kt`) today returns `"data:image/png;base64,…"`.
  When the trace value is a handle, `pngUrl` builds the blob URL (`ClientContext.baseUrl` + the
  endpoint, so it rides the kzen-shell proxy prefix) — the browser fetches once and caches by the
  immutable URL. All renderers (`ScreenshotThumbnail`, `StepImageThumbnail`, `StepImageFullscreen`,
  `PageScreenshots`, `RunStepDisplay`) go through `pngUrl`, so this single change covers them.
- **Client parse:** the trace-side deserialization (the `LogicTraceEntry`/`LogicTraceEvent` binary
  branch, not the global `ExecutionValue.fromJsonCollection`) produces a handle-bearing value
  (hash + size + mime, no bytes) that `pngUrl` accepts. `computeRunStepRepresentative`
  (`ScriptProgressStore.kt:212`, `events.filter { it.value is BinaryExecutionValue }`) selects on the
  handle type instead.
- Flow and Job carry no binary trace values (their trace values are `VisualVertexModel` maps and a
  status+progress map respectively) — unaffected.

**Out of scope:** changing generic `ExecutionValue` binary serialization; a persistent (cross-run or
cross-JVM) blob store — the handle lives exactly as long as the retained run does.

**Verify:** re-capture the HAR → no base64 image data in any `lookup-run*` JSON (grep the response for
`iVBOR` → none); each unique screenshot fetched exactly once via the blob endpoint with `immutable`
cache headers; re-opening fullscreen hits browser cache (no new request); the film strip, per-step
thumbnails, and fullscreen all still render; the blob endpoint streams and caches through the
kzen-shell proxy; `selfTest`; total transfer for the same run drops from ~21 MB toward the raw PNG
volume fetched once (no 33 % base64 tax, no re-download).

---

## Phase 4 — Server-side structural version on `LogicStatus`

**Goal:** replace the client's coarse 1 s publish throttle with an *exact* signal — a controller
counter bumped only when the execution tree actually changes — so `traced` / `lookupRunExecutions`
re-fetch exactly when their answer changes (~15-17×/run) instead of riding the 1 s publish cadence
(~46×/run), and so `structureVersion` can include frame changes without defeating the throttle
(restoring the per-emit intra-step frame animation E5 traded away). The remaining per-publish floor
becomes `lookup` + `lookupRunHistory` alone. This is E5's parked "Still open" item 1, pulled in
2026-07-16. kzen-lib + kzen-auto-js (wire change).

**Prerequisite:** E5 (the SSE/publish/throttle machinery this refines; done 2026-07-15).

### Design decisions

- Add `structureVersion: Long` to `LogicStatus` (or `LogicRunInfo`), bumped by `ServerLogicController`
  **only** on genuine execution-tree changes — an execution created/destroyed, a run-state
  transition, a trace cleared — **never per emit**. Serialize as a **string** (the JS-`Long`
  round-trip convention already used by `epoch` and `LogicRunInfo.sequence`).
- Client `ClientLogicState.structureVersion()` reads the server value instead of deriving
  `epoch|runId|state` locally; `ClientLogicGlobal.publishStatus` keys immediate-publish on it, and the
  `traced` / `lookupRunExecutions` re-fetch gate directly on it (they change only when it changes).
- **Wire change on `LogicStatus`** → ship both sides in the session; **soft edge with SER4**, which
  migrates the trace/status DTOs to kotlinx — coordinate exactly as E5's payload did (reuse the codec;
  if SER4 has landed, add the field to the migrated DTO).
- With an exact structural signal available, fold frame position into `structureVersion` without
  marking a plain run structure-changing throughout — recovering the intermediate-frame repaint (a
  stepped-over `RunStep` descending into its child) that E5's frame-excluding `structureVersion`
  deliberately sacrificed.

**Out of scope:** any change to the trace *values* or the SSE transport itself — this is purely a
better *when-to-refetch* signal.

**Verify:** re-capture the HAR → `traced` and `lookup-run-executions` call counts drop to the
structural-change count (~15-17) from ~46; a stepped-over RunStep's intra-step frames animate per
emit again; `selfTest`; extend `ServerLogicControllerStatusObserverTest` for `structureVersion`
monotonicity (bumps on tree change, not on plain emits).

---

## Sizing and sequencing

| Phase | Layer | Size | Risk | Depends on |
|---|---|---|---|---|
| 1 — compression | auto-jvm | small session | low (the proxy leg is the only real risk) | — |
| 2 — thin settle fetch | kzen-lib + js | small session | low | — (superseded by 3) |
| 3 — binary-by-handle | kzen-lib + jvm + js | one full session | medium (wire + new endpoint) | — (supersedes 2) |
| 4 — structural version | kzen-lib + js | small session | low-medium (wire change) | E5; soft: SER4 |

Recommended order **TP1 → TP2 → TP3 → TP4**, but all are largely independent: TP1 is pure transport;
TP2 is a stopgap TP3 makes inert; TP4 needs only E5 (already done). If a session runs long on TP3,
land kzen-lib first (`publishToMavenLocal` keeps kzen-auto buildable) and note the split in the
tracker. Scheduled under the master plan's **Stage 4 (trace & transport)**.
