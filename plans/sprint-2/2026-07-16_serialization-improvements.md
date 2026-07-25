# Serialization improvements — remaining phases (SER2–SER5)

> **Status: planned.** Successor to `sprint-1/2026-07-13_serialization-improvements.md`
> (Sprint 1: SER1 landed; this document carries the open chain SER2–SER5 forward, complete and
> self-contained). Executor: **Opus 4.8 xhigh, one phase per session.** Each phase is
> self-contained: goal, design decisions (already made — do not re-litigate, except at the
> phase 3 gate), concrete steps with file anchors, and verification. Phases are a strict chain:
> SER2 → SER3 (gate) → SER4 → SER5. Phase IDs are stable across the sprint reorganization.
>
> Related plans: `2026-07-10_yaml-parser-strings-and-comments.md` (Y) owns the notation YAML
> format — this plan does not touch `YamlParser`/`YamlNotationParser`.
> `2026-07-16_trace-payload-improvements.md` (TP): **TP4 adds a `structureVersion` field to
> `LogicStatus`** — the same DTO SER4 migrates; whichever lands second adapts (a one-line field
> on the migrated DTO, or a one-key addition to the legacy codec). TP3's binary-handle entry
> shape rides the trace-event codecs SER4 migrates — same rule.
> `2026-07-16_master-plan.md` (sequencing).
>
> **Progress tracker** (update as phases land):
> - [x] Phase 2 — wire-codec classification + kotlinx.serialization foundation (kzen-lib/kzen-auto) ✓ 2026-07-16 (as-built note at end)
> - [x] Phase 3 — first endpoint-family migration (storage/file-listing) + **payoff gate** ✓ 2026-07-17 — **GATE VERDICT: PROCEED** (as-built + verdict at end)
> - [x] Phase 4 — logic/task/trace/detached family ✓ 2026-07-17 (as-built note at end)
> - [x] Phase 5 — ContentNegotiation flip + Jackson slimming + hygiene sweep ✓ 2026-07-18 (as-built note at end) — **SER track COMPLETE**

## Landed context (Sprint 1)

**SER1 ✓ 2026-07-13 — kzen-launcher codec convergence.** One codec stack (kotlinx.serialization)
on both sides of the launcher wire; `ktor-serialization-jackson` swapped for
`ktor-serialization-kotlinx-json` and `jackson()` → `json()` in `KzenLauncherMain`; Jackson 2 is
gone from the launcher server (Jackson 3 YAML remains only in `ProjectRepo`, narrowed to
`tools.jackson.core:jackson-databind`). Key as-built facts SER2+ can rely on:
- **`ktor-serialization-kotlinx-json` is proven in-stack server-side** — the point of running
  SER1 first.
- kzen-launcher-jvm needed **no serialization plugin** (all DTOs already `@Serializable` in
  kzen-launcher-common); `RestHandler.listProjects()` returns `List<ProjectDetail>`;
  `ShellSimulator.Status` was deleted in favour of the common `RunningProject` DTO;
  `respondCommand` error bodies use `buildJsonObject`.

**Timeline note — the E5 soft edge inverted.** The original plan recorded "SER4 before E5 (E5's
push format should reuse the kotlinx trace/status DTOs)". E5 landed first (2026-07-15): the SSE
`/logic/events` stream sends the **byte-identical `LogicStatus` payload the GET returns**, encoded
by the existing hand-written codec. Consequence for SER4: it migrates the already-shipped push
payload along with the GET — one migration covers both, since they share one encode call path.
No extra work, but SER4's verification must include the SSE stream (not just the poll).

## Context — what the survey found

Serialization in the ecosystem is not one mechanism but **eight**, most of them deliberate and
sound. The inventory, with an explicit keep/fix verdict per mechanism:

### Sound — keep as-is (do not "unify" these)

1. **Notation YAML** — the hand-rolled `YamlParser`
   (`kzen-lib-common/.../util/yaml/YamlParser.kt`) + `YamlNotationParser`
   (`.../service/parse/YamlNotationParser.kt`). Hand-rolled because it must run identically in
   `commonMain` on JVM and JS; no KMP YAML library dependency is acceptable. Owned by plan Y;
   out of scope here entirely.
2. **`Digest` / `Digestible`** (`kzen-lib-common/.../util/digest/Digest.kt`) — the hash-only
   streaming "serializer" (`Digest.Sink`) plus three encodings for three consumers:
   `_`-joined base-32 `asString()`/`parse()` (REST), 16-byte big-endian
   `toByteArray()`/`fromBytes` (binary stores), and the sink streaming form (hashing).
   Int-quadruple representation is deliberate (JS can't round-trip `Long` through JSON). This is
   a crown jewel of the content-addressing design; not a duplication problem.
3. **Binary report stores** (kzen-auto-jvm `.../report/exec/...`: `FileOffsetStore`,
   `FileDigestIndex`, `MmapBitArray`, `FileIndexedTextStore`, `FileValueStatisticsStore`) —
   bespoke `ByteBuffer`/`RandomAccessFile`/mmap formats, performance-driven, self-contained.
4. **Scalar wire responses as `text/plain`** — all ~40 notation commands return
   `Digest.asString()` as text; logic control verbs return enum `.name`; the `notation` query
   returns raw document YAML (`KzenAutoMain.kt:342-346`). Symmetric `asString()`/`parse()`
   value objects (`DocumentPath`, `ObjectLocation`, `AttributePath`, …) are good value-object
   serialization. No JSON-ification wanted.
5. **Request encoding** — GET query params with a size-triggered PUT-form fallback
   (`ClientRestApi.getOrPut`, `getSizeLimit = 1024`, paired with each command's `put(...)` twin
   server-side), raw-byte POST for resources. Works; churn would be wire-visible for no gain.
6. **kzen-shell's proxy** — streams bytes untouched (`ProxyHandler.handle`); correctly does zero
   (de)serialization of proxied traffic.
7. **`kzen-projects.yaml` via Jackson-YAML** (`kzen-launcher-jvm/.../project/ProjectRepo.kt:29`)
   — the only YAML-library usage anywhere. Deliberately NOT migrated to the hand-rolled
   `YamlParser`: existing user registry files were written with standard YAML escaping, and the
   hand-rolled parser's non-standard bare-scalar unescaping would corrupt Windows paths
   (`\d` throws). Also kzen-launcher has **no kzen-lib dependency** and should not gain one.

### The two genuine problems

**P1 — kzen-auto's wire codec layer is hand-maintained on both ends with nothing enforcing
symmetry.** The dominant structured-response mechanism is:

- Server: hand-written `toCollection()` / `toJsonCollection()` companions build
  `Map<String, Any?>` (e.g. `RestHandler.kt:975,991,1006,1101` and `:926,1052,1065,1078,1183`),
  which Ktor's `jackson()` ContentNegotiation (`KzenAutoMain.kt:134-136`) then serializes —
  Jackson is used only as a dumb Map→bytes step.
- Client: `JSON.parse` → `ClientJsonUtils.toMap/toList` (a manual dynamic-object walker,
  `kzen-lib-js/.../client/ClientJsonUtils.kt:19-53`) → hand-written `ofCollection()` /
  `fromJsonCollection()` companions.
- The contract is upheld solely by hand-matched string-key constants in **~35 codec-pair
  classes** across kzen-lib-common (`LogicStatus`, `LogicRunInfo`, `LogicRunFrameInfo`,
  `LogicTraceEvent/Entry/Query`, `TaskModel`, `TaskProgress`, `ExecutionResult/Request`, …)
  and kzen-auto-common (`StorageAreaInfo`, `StorageBundleInfo`, `DataLocationInfo`,
  `OutputInfo`, `TableSummary`, `ColumnSummary`, `VisualFlowModel`, `VisualVertexModel`, …).
- Everything is stringly-typed (numbers/booleans/longs `.toString()`'d and re-parsed), and
  sentinel warts have crept in: `LogicStatus` encodes "no active run" as the literal string
  `"null"` (`LogicStatus.kt:33-37`) — both sides honour it by hand.
- `ExecutionValue` (`kzen-lib-common/.../exec/ExecutionValue.kt`) — the tagged `{type, value}`
  envelope with base64 `Binary`, stringified `Long`, and a `json` primitive-subtree fast-path —
  carries its own header TODO (:11) pointing at kotlinx `JsonElement`.

This is exactly the boilerplate a KMP serialization compiler plugin generates: symmetric,
type-checked, in `commonMain`. kotlinx.serialization is already proven in-stack (launcher, both
sides, post-SER1). The layer is not *wrong* — it works and is KMP-symmetric by construction —
but it is ~35 classes of drift-prone hand mapping that exists only because no common-code codec
was adopted when it was written.

**P2 — a hidden second Jackson.** Verified from the resolved POM:
`io.ktor:ktor-serialization-jackson` 3.5.1 depends on **legacy Jackson 2**
(`com.fasterxml.jackson.core:jackson-databind` + `…jackson-module-kotlin`), while the direct
mappers are pinned Jackson 3 (`tools.jackson…:3.2.0`). So the AGENTS.md "use `tools.jackson`,
not legacy" pin covers only the hand-built mappers (`IconCollectionHandler.kt:23`,
`ProxyHandler.kt:37`, `TesterClient.kt:47`, `ProjectRepo.kt:29`); the actual REST wire
serializer in kzen-auto and kzen-shell is Jackson 2, dragged in transitively. Those server
classpaths carry both generations. (The launcher half of P2 was fixed by SER1.)

### Minor warts (swept up in phases, not phases of their own)

- `Parameters.getParam/getParamList/getParamOrNull` trio copy-pasted across
  `kzen-auto RestHandler.kt:1337-1369`, `kzen-launcher server/api/RestHandler.kt`,
  `kzen-shell ProxyHandler.kt:268-296`. **Accepted duplication**: no shared JVM module exists
  across the three (launcher and shell have no kzen-lib dependency) and adding a dep edge for
  three 10-line helpers is worse than the copies.
- `JsonMapper.builder().build()` construction duplicated (IconCollectionHandler, ProxyHandler).
  Cosmetic.
- `jackson-module-kotlin` (tools.jackson) is declared in kzen-auto-jvm and kzen-shell purely as
  a databind carrier — no source there imports `tools.jackson.module`; only kzen-auto-test's
  `TesterClient` registers `kotlinModule()`.

### Direction decision

Adopt **kotlinx.serialization as the single structured-wire codec**, phased and gated:

- It is the only codec that can live in `commonMain` and generate both sides — the root cause
  of P1 is that no such codec was adopted, so both ends are hand-written (per the standing
  fix-root-cause rule; the alternative of "keep the map protocol but centralize helpers" keeps
  the drift class of bugs and the stringly typing).
- The launcher finished its adoption in SER1, proving the server-side Ktor integration before
  kzen-auto is touched.
- The wire is same-release-only (the client JS bundle is served by the same server; the
  siblings are a coordinated release train), so wire-format changes are safe. **Persisted**
  forms are not — phase 2 includes a mandatory check for any `toJsonCollection` output that
  lands on disk.
- The end state also removes Jackson 2 from every server (ContentNegotiation flips to
  kotlinx-json), collapsing the two-generation duality; remaining Jackson 3 usage shrinks to
  the tree-model sites that genuinely want a JSON/YAML tree API (or to zero in kzen-auto if
  phase 5's `JsonElement` port lands).
- **The phase 3 gate keeps this honest**: after one real endpoint family migrates end-to-end,
  measure net LOC, migration effort per class, and subjective wire-contract clarity. If the
  payoff is not clearly there, stop after phase 3 — phases 2–3 are each self-justifying, and
  the remaining codecs are no worse off. No change for the sake of change.

**Deliberately out of scope** (decided; do not re-open inside a phase):

- `YamlParser` / `YamlNotationParser` / notation format (plan Y owns it).
- `Digest` encodings and `Digestible` (identity, not wire; crown jewel).
- Binary report stores (bespoke by design).
- The request side: query params + PUT-form fallback, raw-YAML notation params, raw-byte
  resource POST, `text/plain` scalar responses — all stay exactly as they are.
- `ProjectRepo`'s Jackson-YAML (user-file compatibility + no kzen-lib dep in launcher).
- The SSE transport itself (landed with E5; SER4 migrates only the payload encoding).
- A shared cross-repo param-parsing helper (no acceptable dep edge).
- Replacing `ExecutionValue` as a domain type — it stays (it is also `Digestible` and a
  runtime value tree); only its *wire encoding* is wrapped in a `KSerializer`.

## Ground rules for every phase

- **Wire compatibility is same-release-only; persisted compatibility is forever.** Before
  changing or deleting any codec, confirm its output never lands on disk (search for callers
  writing `toCollection`/`toJsonCollection` results through any store/media). If one does,
  the on-disk format keeps the old codec (or gets an explicit migration) — record it in the
  as-built note.
- **Dual-purpose codecs must be classified before deletion.** Some `toCollection()` uses feed
  `ExecutionValue` trees (e.g. `ReportInputTrace` publishes
  `ExecutionValue.of(snapshot.toCollection())`), not the wire. Phase 2's classification table
  is the authority; a codec may end up with a `KSerializer` for the wire *and* a retained
  `toCollection` for the value-tree path.
- **kzen-lib SPI compatibility is additive-only**, as always.
- **Dev loop**: kzen-auto consumes kzen-lib from mavenLocal. After any kzen-lib change:
  `cd kzen-lib && ./gradlew publishToMavenLocal`, then build kzen-auto with
  `--refresh-dependencies`. Open siblings standalone in IntelliJ, not via the umbrella.
- **Verification baseline** (every phase): the affected sibling's full test suite
  (`kzen-lib`: `:kzen-lib-common:jvmTest :kzen-lib-common:jsTest :kzen-lib-jvm:test`; `kzen-auto`:
  `:kzen-auto-common:jvmTest :kzen-auto-common:jsTest :kzen-auto-jvm:test`), plus a manual dev-loop
  smoke of the migrated endpoints. UI-facing
  phases: `./gradlew :kzen-auto-test:selfTest` (opt-in). Launcher items: boot
  `FrontendDevelopmentKt` headless and curl the migrated routes.
  > ⚠️ **`jsTest`, not just `compileKotlinJs`.** These phases write *shared* codec code whose
  > behaviour — not just its compilability — diverges across platforms. SER2 verified with
  > `jvmTest` + `compileKotlinJs` and shipped a JS-only NaN bug (see the Phase 2 as-built);
  > SER3 caught two more (`Url.equals`, JS/JVM URL normalization) only by running `jsTest`.
  > Compiling the JS side proves nothing about the JS side.
- Mark the phase checkbox in this file's tracker when done, and append a short "as-built" note
  if the implementation deviated.

---

## Phase 2 — wire-codec classification + kotlinx foundation (kzen-lib + kzen-auto)

**Goal:** the infrastructure that lets endpoint families migrate mechanically, plus the
authoritative classification of every existing codec. **No wire behaviour changes in this
phase.**

### 2a. Classification survey (mandatory, first)

Inventory every `toCollection`/`ofCollection`/`fromCollection`/`toJsonCollection`/
`fromJsonCollection` companion across kzen-lib-common and kzen-auto-common (grep; ~35 classes).
Classify each as: **wire-only** / **value-tree-feeding** (result flows into `ExecutionValue`
or a trace/task store rather than a REST body) / **both** / **persisted** (output reaches disk
through any `NotationMedia`, task store, or report output file — this bucket must be
explicitly confirmed empty or listed). Record the table in this plan's as-built note; it
drives phases 3–4's per-class decisions.

### 2b. Build plumbing

- Add `kotlin("plugin.serialization")` and a `kotlinxSerializationVersion` pin to
  kzen-lib and kzen-auto (`buildSrc/.../Dependencies.kt` + the common modules' build files;
  mirror kzen-launcher-common's setup, including the `api(...)` export rationale comment).
  kzen-project follows only if/when its own modules need it (it reuses kzen-auto's server —
  likely nothing to do).
- Update the AGENTS.md toolchain-pin list (kotlinx-serialization joins the shared pins).

### 2c. Value-object serializers

Add delegating `KSerializer`s for the `asString()`/`parse()` value objects that appear inside
wire DTOs (`DocumentPath`, `ObjectLocation`, `ObjectPath`, `AttributePath`, `AttributeName`,
`AttributeNesting`, `Digest`, `LogicRunId`/`LogicExecutionId` if applicable, …) — each is a
5-line `String`-delegating serializer; put them beside the classes (kzen-lib-common) so
`@Serializable(with = …)` or a central `SerializersModule` can bind them. Prefer per-class
`@Serializable(with)` over a module: keeps notation local, no registry.

### 2d. `ExecutionValue` / `ExecutionResult` serializers

Custom `KSerializer<ExecutionValue>` that **preserves the existing `{type, value}` envelope
byte-for-byte** (including the `json` primitive-subtree fast-path, base64 `Binary`,
string-encoded `Long`) by round-tripping through the existing
`toJsonCollection`/`fromJsonCollection` lowered form → `JsonElement`. Rationale: the envelope
is consumed beyond a single endpoint (detached actions, logic requests, trace events) and may
be persisted (2a confirms); preserving it makes phase 4 a transport swap, not a format
migration. Resolve the `ExecutionValue.kt:11` TODO comment either way (implemented or
explicitly declined with reason). Same treatment for `ExecutionResult`/`ExecutionRequest`.
**TP3 coordination:** if TP3 (binary-by-handle) has landed, the LogicTrace projection emits a
`{type: binary-handle, hash, size, mime}` variant — the `KSerializer` must round-trip it like
any other envelope shape (it is projection-scoped, not a new `ExecutionValue` subtype; confirm
against TP3's as-built).

### Verification

Baseline suites in both repos (publishToMavenLocal round-trip). New unit tests: each value-object
serializer round-trips; `ExecutionValue` serializer output equals the legacy
`toJsonCollection` form over a fixture covering every variant (null/text/boolean/number/long/
binary/list/map/json-fast-path).

---

## Phase 3 — first endpoint family + payoff gate

**Goal:** one real endpoint family migrated end-to-end, codecs deleted, payoff measured.

**Family: storage / file-listing / output-info** — chosen because its DTOs are leaf-like,
wire-only (confirm against 2a), and numerous enough to be representative:
`StorageAreaInfo`, `StorageBundleInfo`, `DataLocationInfo`, `OutputInfo`, `OutputTableInfo`,
`OutputExportInfo`, `TableSummary`, `ColumnSummary`, `NominalValueSummary`,
`OpaqueValueSummary`, `HeaderListing` (adjust per the 2a table).

### Steps

1. Annotate the family `@Serializable` (using 2c's value-object serializers); fix stringly
   typing as you go (real `Int`/`Long`/`Boolean` fields on the wire — same-release rule makes
   this safe for wire-only codecs).
2. Server: the migrated handlers respond via
   `call.respondText(Json.encodeToString(dto), ContentType.Application.Json)` **during the
   transition** (a small `respondJson(dto)` extension in `RestHandler`), because Ktor's
   ContentNegotiation can't cleanly host two `application/json` serializers at once — the
   global `jackson()` install stays until phase 5 flips it.
3. Client: replace the family's `JSON.parse` + `ClientJsonUtils` + `ofCollection` call sites in
   `ClientRestApi` with `Json.decodeFromString<Dto>(response)` (shared `clientJson` instance
   with `ignoreUnknownKeys`, mirroring the launcher).
4. Delete the family's `toCollection`/`ofCollection` companions and their key constants.
5. **Gate (record the verdict in the tracker and as-built note):** net LOC delta, per-class
   migration effort, and whether the result is clearly more robust (typed fields, no key
   constants, no hand-walk). **Proceed to phase 4 only on a clear yes.** On a no: stop here,
   revert nothing (SER1–SER3 stand on their own), and strike phases 4–5 from the tracker
   with a dated note (phase 5's shell/launcher items survive as a standalone micro-session).

### Verification

kzen-auto baseline + manual Report input/output panel smoke (file listing, storage summary,
output preview/export — the migrated surface). selfTest.

---

## Phase 4 — logic / task / trace / detached family

**Goal:** the remaining structured wire — the run/trace/task/detached surface — on kotlinx;
the sentinel warts gone. **This migration covers the SSE push payload for free** (see the
timeline note above: `/logic/events` frames are encoded by the same call path as the
`/logic/status` GET), and must coordinate with TP4 if it has landed (`structureVersion` is then
one more field on the migrated `LogicStatus` DTO; both `Long`s serialize as strings per the
existing convention).

### Steps (order within the phase is free)

- `TaskModel`, `TaskProgress` (`kzen-lib-common/.../exec/task/model/`),
  `LogicStatus`/`LogicRunInfo`/`LogicRunExecutionInfo`/`LogicRunFrameInfo` (recursive tree),
  `LogicTraceEvent`/`LogicTraceEntry`/`LogicTraceQuery`/`LogicTracePath`,
  `ExecutionResult`/`ExecutionRequest` wire call sites (2d serializers),
  `ObjectStableMapper` snapshot, and the flow visual models
  (`VisualFlowModel`/`VisualVertexModel`/`VisualVertexTransition`) — per the 2a table:
  wire-only codecs are deleted after migration; value-tree-feeding ones keep `toCollection`
  for that path and note the dual role in a comment.
- Preserve the established **`Long`-as-string** convention (`LogicStatus.epoch`,
  `LogicRunInfo.sequence`, `LogicTraceEvent.sequence` — JS can't round-trip `Long` through
  JSON; see kzen-auto architecture §3).
- **Kill the `"null"` sentinel**: `LogicStatus.active` becomes a nullable field serialized as
  JSON null (`LogicStatus.kt:14-37`); both ends change together.
- kzen-auto-test `TesterClient` (:47, :182, :248): decode with kotlinx against the same DTOs;
  delete its hand-built Jackson mapper (the Ktor-client `jackson()` at :51 flips in phase 5
  with the server, or immediately if nothing negotiates by then).
- `ClientJsonUtils` (`kzen-lib-js`): after this phase, check remaining users; if only
  `ClientRestApi`'s deleted call sites used it, delete it (it is the JS-side manual walker
  that kotlinx replaces). If notation/scan paths still use it, keep and note.

### Verification

kzen-auto baseline + selfTest (Script run/pause/step, Job run, Report run — the trace/status
surface); manual dev-loop pass over run controls, trace display, detached actions (Report
panel), and a task-based flow. **SSE-specific check**: a run's push stream delivers and the UI
repaints on pause/settle (the frame payload changed encoder); confirm through the kzen-shell
proxy too. kzen-lib publishToMavenLocal round-trip.

---

## Phase 5 — ContentNegotiation flip + Jackson slimming + hygiene

**Goal:** one JSON codec per process; Jackson 2 off every classpath; leftover mapper
duplication gone.

### Steps

1. **kzen-auto**: with all structured responses now kotlinx-encoded, flip
   `KzenAutoMain.kt:134-136` from `jackson()` to `json()` and collapse phase 3's transitional
   `respondJson` helper back into plain `call.respond(dto)`. Remove
   `ktor-serialization-jackson` from `kzen-auto-jvm/build.gradle.kts:66` and
   `kzen-auto-test/build.gradle.kts:38` (and the Ktor-client `jackson()` in `TesterClient`).
2. **IconCollectionHandler** (`kzen-auto-jvm/.../api/IconCollectionHandler.kt`): port the
   `readTree`/`ObjectNode` subsetting to kotlinx `JsonElement`/`buildJsonObject` (pure
   tree-filtering; mechanical), then remove `jackson-module-kotlin` from
   `kzen-auto-jvm/build.gradle.kts:47` — kzen-auto ends Jackson-free. If the port turns out
   non-mechanical (streaming/perf concern on the large icon collection), keep Jackson 3 for
   this one handler with a narrowed `tools.jackson.core:jackson-databind` dependency and note it.
3. **kzen-shell**: flip `KzenShellMain.kt:71-73` to `json()` (two control endpoints:
   `RunningProjectStatus` list + a `Boolean` — make the DTO `@Serializable`, update its
   comment); `ProxyHandler.respondProxyError` builds its `{error, name}` body via
   `buildJsonObject`; drop both `jackson-module-kotlin` (`build.gradle.kts:36`) and
   `ktor-serialization-jackson` (:45). kzen-shell ends Jackson-free.
4. **kzen-launcher**: nothing left (SER1 already narrowed ProjectRepo's dependency).
   Launcher keeps Jackson 3 YAML only.
5. Docs: AGENTS.md toolchain pins — Jackson entry shrinks to the launcher-only YAML usage;
   kotlinx-serialization pin documented. Sweep the "Serialized by Jackson" comments.

### Verification

Full builds of kzen-auto, kzen-shell, kzen-launcher; selfTest; a shell-proxied end-to-end
session (launcher → create project → open → run a script) since ContentNegotiation changed in
every server. Icon smoke: sidebar/step icons render (the `/icon/{set}.json` subset endpoint).

---

## Sizing and sequencing

| Phase | Size | Risk | Depends on |
|---|---|---|---|
| 2 | one session | low (additive; no wire change) | — |
| 3 | one session | low-medium (first real migration; gated) | 2 |
| 4 | one full session | medium (trace/status surface is wide; dual-purpose codecs; SSE payload) | 3 gate = yes |
| 5 | one session | low (mechanical flips; wide but shallow) | 4 (auto/test parts) |

Phases 2–5 are a strict chain. If the phase 3 gate says stop, phase 5's shell items (step 3)
can still run as a standalone micro-session (shell's two endpoints don't depend on the
kzen-auto migration), and the kzen-auto items are dropped.

Registered in `2026-07-16_master-plan.md` as Sprint 2's **Track W** (wire serialization).
Coordination edges: **SER4 ↔ TP4** on `LogicStatus` (whichever lands second adapts) and
**SER2d ↔ TP3** on the binary-handle envelope shape.

---

## Phase 2 as-built (2026-07-16)

Landed exactly as planned; **no wire behaviour changed** (kzen-auto-jvm ContentNegotiation stays on
`jackson()` — the flip is SER5). The added serializers are inert until a DTO becomes `@Serializable`
in SER3/SER4. Verified end-to-end: `:kzen-lib-common:jvmTest` + `:kzen-lib-common:compileKotlinJs` +
`:kzen-lib-jvm:test` green; `publishToMavenLocal` → kzen-auto `--refresh-dependencies` build with
`:kzen-auto-common:compileKotlin{Jvm,Js}` + `:kzen-auto-jvm:test` + `:kzen-auto-js:compileKotlinJs`
+ JS bundle all green (the only warnings are pre-existing, in generated `KzenAutoJvmModule.kt` and an
unrelated test). KSP and the serialization compiler plugin coexist with no build wiring change.

### Follow-up fix (2026-07-17): JS-only NaN encoding bug — and the verification gap that shipped it

`ExecutionValueSerializerTest.everyVariantRoundTrips` + `nonFiniteNumberEncodesAsString` failed **on JS
only** with `JsonEncodingException: Unexpected special floating-point value NaN`, output
`{"type":"number","value":NaN}`. `anyToJsonElement` (`ExecutionValueSerialization.kt`) ordered its number
branches `is Int` → `is Long` → `is Double`, and only the `is Double` branch carried the non-finite →
string guard.

**Root cause — a Kotlin/JS type-check divergence, measured with a throwaway probe (since deleted):**

| value | JVM `is` match | JS `is` match |
|---|---|---|
| `NaN` / `±Infinity` / `3.14` / `0.0` | `Double` | **`Int`** |
| `42` | `Int` | `Int` |
| `5L` | `Long` | `Long` |

On Kotlin/JS every `Double` **is** a JS `number`, so `is Int` matches *all* of them — `is Int` above
`is Double` makes the `is Double` branch **unreachable on JS**. NaN therefore skipped the guard, reached
`JsonPrimitive(Int)`, and produced a bare `NaN` token — invalid JSON. On JVM the boxed `java.lang.Double`
matched `is Double` correctly, so the guard worked and the bug was invisible.

**Fix:** dispatch on the *value*, not the static number type — `is Long` (the one numeric check that means
the same thing on both platforms, since JS `Long` is a real class) above `is Number` + `toDouble()` +
`isFinite()`. This mirrors `ExecutionValue.ofArbitrary`'s long-standing shape in the same file. **Wire-neutral
for finite numbers on both platforms**, so no other test moved: 158/158 green on `jvmTest` *and*
`jsBrowserTest`. The two pre-existing tests were already the right regression tests — nothing ran them.

**Audited the same hazard elsewhere:** `YamlNode.ofObject` has the same `is Int`-before-`is Double`
ordering but every numeric branch has an identical body (`YamlString(value.toString())`), so the shadowing
is harmless there — left alone. `fromJsonCollection` / `fromJsonPrimitiveCollection`'s `is Double` branches
are fed only by `jsonElementToAny`, which always yields `Double` — also fine.

**Process lesson (baseline updated above):** SER2's verification was `jvmTest` + `compileKotlinJs`. A KMP
codec phase's *whole risk* is behavioural divergence between platforms, and compiling the JS side proves
nothing about it. `jsTest` is now in the standing baseline. Note the pattern: **every cross-platform defect
this track has found — this NaN bug, SER3's `Url.equals`, SER3's URL normalization — was invisible to
`jvmTest` and surfaced by `jsTest`.** SER4 migrates `LogicStatus` / `TaskModel` / recursive
`LogicRunFrameInfo` in shared code; run both.

### Decisions

- **`ExecutionValue.kt:11` TODO — DECLINED** (comment updated in place). The kotlinx codec wraps the
  existing `toJsonCollection()`/`fromJsonCollection()` lowering rather than re-expressing the tree on
  `JsonElement`, so the envelope is byte-identical and `ExecutionValue` stays a plain `Digestible`
  runtime tree. That lowering remains the single source of truth.
- **Plumbing added to BOTH repos** (2b). All SER2 serializers live in kzen-lib-common; kzen-auto-common
  got the plugin+dep purely as forward-provisioning for SER3's DTO family (no serializer written there
  yet). Pin `kotlinxSerializationVersion = "1.9.0"` (launcher's), root `plugins { kotlin("plugin.serialization")
  version kotlinVersion apply false }`, `-common` plugin (no version) + `api(kotlinx-serialization-json)`.
  Umbrella `AGENTS.md` toolchain-pin list updated (new kotlinx-serialization bullet, also records the
  launcher's SER1 adoption which was previously unlisted).
- **Binding = per-class `@Serializable(with = …Serializer::class)`**, serializer object beside each class
  (no `SerializersModule`), so SER3/SER4 DTOs reference these types with zero per-field annotation.
- **2c gotchas honoured**: value objects serialize through `asString()`/`parse()` (AttributeName escapes
  `.`; Digest is the 4-part radix-32 string), NOT raw fields. `LogicRunId`/`LogicExecutionId` have no
  `asString()`/`parse()` → delegate through `.value`. `RequestParams` added (member of `ExecutionRequest`);
  its `parse("")` throws (pre-existing), so empty is untested and never round-trips.
- **2d non-finite edge**: the `Any→JsonElement` bridge emits non-finite doubles (`Infinity`/`NaN`) as JSON
  *strings*, which the existing `fromJsonCollection` number branch already accepts ("// NB: handle
  Infinity"). This is valid JSON (a strict improvement over Jackson's non-standard `NaN`/`Infinity`
  tokens), reachable only in the untested non-finite case. All JSON numbers decode to `Double` (what
  `fromJsonCollection` and the `json` fast-path expect; `size` reads via `as Number`, so Double is safe).

### 2a classification survey (the authoritative table)

Two serialization planes: **wire** (`RestHandler` returns a raw Map/List that `ClientRestApi` parses via
`X.ofCollection`) and **value-tree** (server wraps the codec map in `ExecutionValue.of(x.toCollection())`,
carried through the trace/task/detached result, parsed client-side from the extracted `ExecutionValue`
in a *store/controller*, never `ClientRestApi`).

**Bucket A — wire-only** (kzen-lib-common unless noted): `LogicStatus`, `LogicRunInfo`,
`LogicRunFrameInfo` (recursive), `TaskModel`, `ExecutionRequest`, `ExecutionResult`
(+`ExecutionSuccess`/`ExecutionFailure`); `StorageAreaInfo`, `StorageBundleInfo` (kzen-auto-common).
Plus **`ObjectStableMapper`** snapshot — serialized *inline* in `RestHandler.objectStableMapperSnapshot()`;
**no `toCollection` method** on the class (SER4 must add one or serialize the map directly).

**Bucket B — value-tree-feeding**:
- kzen-lib: `LogicTraceEvent`, `LogicTraceEntry`, `LogicTraceSnapshot`, `LogicRunExecutionInfo`,
  `TaskProgress`, `OutcomeTrace` (one-way `toMap`, no parser); string codecs `LogicTracePath`,
  `LogicTraceQuery`.
- kzen-auto: `OutputInfo`, `OutputTableInfo`, `OutputExportInfo`, `OutputPreview`, `TableSummary`,
  `ColumnSummary`, `NominalValueSummary`, `OpaqueValueSummary`, `StatisticValueSummary`, `HeaderListing`,
  `FilteredHeaderListing`, `AnalysisColumnInfo`, `InputBrowserInfo`, `InputSelectedInfo`, `InputDataInfo`,
  `InputDataSpec`, `ReportDefinerDetail`, `ReportFileProgress`, `HeaderLabel` (string codec),
  `VisualVertexModel`, `VisualFlowModel`, `VisualVertexTransition`, `TargetLocateResult`
  (+`TargetCropMatches`, `TargetMatchRect`).
  *(The Phase-3/4 named lists undercounted; these extra classes are real — do not miss them.)*

**Bucket C — both**: `DataLocationInfo` (wire via `fileListing`; value-tree via
`InputBrowserInfo`/`InputDataInfo`); **`ExecutionValue`** — the keystone (wire content of every
`ExecutionResult` *and* the value-tree primitive nearly every Bucket-B class embeds).

**Bucket D — persisted**: **empty for the JSON-map codec family** — every call site is `RestHandler`
(wire) or `ExecutionValue.of(...)` (value-tree); the task store is in-memory; `NotationMedia` persists
YAML notation, not these DTOs. **Adjacent finding (record for SER3/SER4):** `NominalValueSummary`,
`OpaqueValueSummary`, `StatisticValueSummary` have a *separate* `toCsv`/`fromCsv` (`asCsv`/`ofCsv`) codec
that **is** the on-disk format (`ReportSummary.saveNominal/…` → `Files.writeString`). That CSV pair is
persisted-forever and must survive any later deletion of their JSON-map codec — distinct format (CSV),
not JSON map.

### Files changed

- **Build**: `{kzen-lib,kzen-auto}/buildSrc/.../Dependencies.kt`, `{kzen-lib,kzen-auto}/build.gradle.kts`,
  `{kzen-lib,kzen-auto}/{kzen-lib-common,kzen-auto-common}/build.gradle.kts`, umbrella `kzen/AGENTS.md`.
- **2c serializers + `@Serializable(with)`** (all kzen-lib-common `commonMain`): `DocumentPath`,
  `ObjectLocation`, `ObjectPath`, `AttributePath`, `AttributeName`, `AttributeNesting`, `Digest`,
  `RequestParams`, `LogicRunId`, `LogicExecutionId`.
- **2d**: new `exec/ExecutionValueSerialization.kt` (`ExecutionValue`/`Result`/`Request` serializers +
  `Any↔JsonElement` bridge); `@Serializable(with)` on `ExecutionValue`, `ExecutionResult`,
  `ExecutionRequest`.
- **Tests** (kzen-lib-common `commonTest`): `serialization/ValueObjectSerializerTest.kt`,
  `exec/ExecutionValueSerializerTest.kt` (full variant fixture incl. non-finite, long, binary,
  binary-handle, json fast-path, deep mix).

---

## Phase 3 as-built (2026-07-17) — **GATE VERDICT: PROCEED to SER4**

Landed. Migrated family, verification, and the gate verdict below. **kzen-lib production code unchanged**
(the 3 DTOs are kzen-auto-common; `Instant` is a kotlinx built-in) — so **no `publishToMavenLocal` and no
`--refresh-dependencies` were needed**. Only a test-only spike file was added to kzen-lib.

### Scope correction — the family is 3 classes, not the ~11 the phase-3 text names

The 2a table wins, as phase 3's own "(adjust per the 2a table)" anticipated. Re-derived from the server
rather than the prose — the **complete** structured-wire inventory of `RestHandler`:

| Line | Return | Phase |
|---|---|---|
| :935, :1061, :1226 | `ExecutionResult` | SER4 (kzen-lib; 2d serializer exists) |
| **:984** | `DataLocationInfo` | **SER3** |
| **:1000** | `StorageAreaInfo` | **SER3** |
| **:1015** | `StorageBundleInfo` | **SER3** |
| :1074, :1087 | `TaskModel` | SER4 |
| :1110 | `LogicStatus` | SER4 |

Everything else phase 3 named (`OutputInfo`, `TableSummary`, `HeaderListing`, …) is **Bucket B** — zero
`RestHandler` call sites; it flows `ExecutionValue.of(x.toCollection())` → a client *store*, never
`ClientRestApi`. **Bucket D re-confirmed empty** for these 3 (no store / `NotationMedia` / file write; the
`toCsv` persisted-forever twin belongs to the summary classes, not this family). Generated-source trap
(`HeaderListing.ofCollection` inside a Kotlin source string at `report/exec/calc/CalculatedColumnEval.kt:96`
— note that path anchor is stale in phase 4's text) checked for these 3: **no hits**.

### Decisions

- **`kotlin.time.Instant` needs no serializer.** kotlinx 1.9.0 ships `InstantSerializer`
  (`PrimitiveSerialDescriptor("kotlin.time.Instant", STRING)`, `toString()`/`Instant.parse`) — byte-identical
  to the old codec's form — and the Kotlin 2.4.0 plugin auto-resolves it. Verified by compile + green tests
  on both platforms. `DataLocationInfo.modified` is a bare `val modified: Instant`.
- **Stock `Json` on both ends; `explicitNulls` NOT touched.** `encodeDefaults=false` means a nullable
  property **with** a `= null` default is omitted (→ `StorageAreaInfo.budget` byte-identical to the legacy
  wire) while one **without** a default encodes as an explicit JSON null. **That second half is exactly
  SER4's `LogicStatus.active` sentinel-kill — setting `explicitNulls=false` globally would silently sabotage
  it.** Pinned by `storageAreaInfoOmitsNullBudget` + the SER4 spike, and confirmed live (see verification).
- **Long-on-the-wire → plain JSON numbers here** (user-ratified). The Long-as-string convention's *mechanism*
  is an artifact of the hand codec (`JSON.parse` → JS `Number` → can't be a `Long`); kotlinx's
  `AbstractJsonLexer.consumeNumericLiteral` accumulates digits straight into a `Long`, **on JS too** — proven
  empirically, not just by reading: `WireDtoSerializerTest` passes under **ChromeHeadless** with an
  epoch-millis fixture (1.75e12). These five Longs sit ~5000× below 2^53. SER4 keeps Long-as-string for the
  genuinely unbounded `LogicStatus.epoch`/`sequence`/`structureVersion` + `LogicTraceEvent.sequence` — via
  kotlinx's built-in **`LongAsStringSerializer`**, strictly better than a manual `.toString()`.
  `kzen-auto/docs/architecture.md` § 3 now states the refined rule rather than the old blanket one.
- **`respondJson` lives in `KzenAutoMain`, not `RestHandler`** (phase 3's step 2 is wrong about placement):
  `RestHandler` is a plain class with no `ApplicationCall`; every `call.respond` is in the route lambdas.
  SER4 reuses it there; SER5 deletes it.
- **`clientJson` lives in `kzen-auto-js/.../client/util/ajaxUtil.kt`**, mirroring the launcher. Deliberate:
  `ClientRestApi` imports `kotlin.js.Json` as the return type of its `getOrPutJson`/`postJson` helpers, so
  importing `kotlinx.serialization.json.Json` there would clash. `ClientRestApi` already star-imports that
  package, so it costs no new import.
- **Build: the serialization plugin was added to `kzen-auto-js` AND `kzen-auto-jvm`** — SER2 provisioned only
  the `-common` modules. Without it, `encodeToString`/`decodeFromString` fall back to runtime lookup and fail
  at **runtime**, not compile. No dependency lines needed (`kzen-auto-common`'s `api(...)` propagates).

### `DataLocationInfo` is dual-plane — codec RETAINED (the phase's main over-deletion trap)

`toCollection()`/`ofCollection()` + all 5 key constants **stay**: live value-tree callers at
`report/listing/InputBrowserInfo.kt:24,39` and `report/listing/InputDataInfo.kt:43,55`. It *looks* dead once
`ClientRestApi`'s wire call site goes, and IntelliJ's unused-heuristics won't flag it. A banner comment on the
class says so; test #7 (`dataLocationInfoWireFormMatchesLegacyForStableKeys`) pins `path`/`name`/`modified`
against drift between the two encodings, and documents that `size`/`dir` intentionally *do* diverge
(number/boolean on the wire, String in the map form — the planes never meet).

Also load-bearing and easy to break: **`DataLocationInfo`'s `init { check(...) }` survives decoding only
because no property has a default** — the plugin emits a synthetic bitmask constructor that bypasses `init`
as soon as one does. Pinned by `dataLocationInfoInitCheckSurvivesDecoding`.

### `Url.equals` — bug found during SER3, FIXED 2026-07-17 (follow-up session, same day)

Surfaced by SER3's serializer round-trip; **pre-existing, not a SER3 regression** (the old `ofCollection`
constructed `DataLocation` identically). Fixed on request as a scoped follow-up. One root cause, two symptoms:

**Root cause:** `Url` is a `Digestible` value object whose identity is its canonical string, but **both**
actuals delegated `equals`/`hashCode` to the wrapped platform type instead — unlike its sibling value object
`FilePath` (in the same `DataLocation`), whose `equals`/`hashCode`/`digest`/`toString` all agree on `location`.

| Platform | Wrapped | Symptom |
|---|---|---|
| `jsMain` | `org.w3c.dom.url.URL` (host object, **no** value equality) | `==` was reference identity → `Url.of(x) != Url.of(x)`; any JS `Set<Url>`/`Map<Url,_>` silently duplicated / always missed |
| `jvmMain` | `java.net.URI` (value equality, but case-insensitive scheme/host, no normalization) | could report **equal while `digest()` differed** (`"http://a"` vs `"HTTP://a"`, verified) — equal-but-different-digest breaks digest-keyed caches and dedup in a content-addressed system |

**Fix:** both actuals now compare `toString()` — the canonical string that `digest()` already hashes — so the
invariant `a == b` ⟺ `a.digest() == b.digest()` holds on every platform, matching `FilePath`. The identity
contract is stated on the `expect class` (commonMain) so a future actual can't re-introduce it.

**`UrlTest` gained the identity tests it never had** (it only ever asserted `toString()`/`scheme`/`path`/`query`
— which is precisely why both bugs survived): `equalsIsValueBased`, `equalsAgreesWithDigest`,
`distinctUrlsAreNotEqual`, `deduplicatesInASet`. SER3's `dataLocationRoundTrip` was restored to a full
value-equality `roundTrip()` for url-backed locations (it had been weakened to an `asString()` comparison).
Verified: full `kzen-auto-common` suite **82/82 on JVM and 82/82 on JS (ChromeHeadless)**, `:kzen-auto-jvm:test`,
`selfTest`.

### Url normalization — third finding, ALSO FIXED 2026-07-17 (same follow-up, on request)

**The problem:** JS's `org.w3c.dom.url.URL` implements WHATWG and **normalizes unconditionally on
construction**; `java.net.URI` (RFC 2396) normalizes nothing. So the *same input string* yielded a different
canonical form — and therefore a **different `Digest`** — on client vs server. Worse than the digest split:
`java.net.URI` **rejects** a literal space that JS %-encodes, so some urls were **valid on the client and
invalid on the server**. (Cache invalidation was explicitly waived by the user.)

**Measured, not assumed.** A temporary probe dumped both platforms' canonical form over a 27-row fixture table;
**9 rows diverged**. The divergence set was entirely "JS normalizes, JVM doesn't": scheme case (all schemes,
incl. opaque `jdbc:`), host case, default port (`:80`/`:443`), empty path → `/`, dot-segment resolution
(**special schemes only** — `jdbc:`'s opaque path is untouched by WHATWG, confirmed), Windows drive-letter
uppercase (`file:///c:/` → `file:///C:/`), and space → `%20`. The probe was deleted once it had done its job;
its fixture table lives on as `UrlCanonicalTest`.

**The fix — `UrlCanonical.canonicalize(raw)` in commonMain** (`kzen-auto-common/.../platform/UrlCanonical.kt`),
applied by **both** actuals in `of()`/`parse()` **before** the platform parser sees the string. Three properties
make this the right shape:
- **JVM converges toward JS, because JS's normalization can't be disabled** — that direction is forced.
- **Canonicalizing the INPUT rather than the output also converges validity** (JVM never sees the space).
- **One shared implementation ⇒ convergence is a property of the design, not a coincidence to maintain.**
  Both actuals derive their canonical string from the same code rather than from two parsers that happen to
  agree. It is idempotent over WHATWG's output, so applying it on JS too is a no-op that keeps the source
  single. (It also fixed the JS actual's `networkFile` prefix probe, which is a raw string test — `FILE:////x`
  only recognizes itself as a network file once the scheme is lowercased.)

**Deliberately NOT a full WHATWG implementation**: no IDNA/punycode, no percent-encoding normalization beyond
the space, no query/fragment rewriting — all measured to already agree, and re-encoding them would risk
double-encoding urls that currently work. Anything unlisted passes through untouched.

**`UrlCanonicalTest` (commonTest, 15 tests) is the contract** — it asserts exact canonical forms and runs on
**both** platforms, so it is what proves and keeps convergence; extend it rather than the prose. It also pins
the things that must NOT change (opaque `jdbc:` paths, the four-slash network-file form, query/fragment,
existing %-encodings, userinfo case, IPv6-literal-vs-port) and asserts no two distinct urls collapse.
`UrlTest.equalsAgreesWithDigest` asserts the equals⟺digest invariant as a **biconditional over pairs** rather
than a fixed verdict — *which* pairs are distinct was platform-dependent before this fix, and an earlier draft
that asserted "these two differ" duly failed on JS only.

**Verified:** re-running the probe post-fix gave **27/27 rows converged, 0 diverging** (from 9). Full
`kzen-auto-common` suite **97/97 on JVM and 97/97 on JS (ChromeHeadless)**; `:kzen-auto-jvm:test`; `selfTest`.
Blast radius is contained: `DataLocation.parse` is the only production caller of `Url.parse`, and it tries
`FilePath` first.

### Url — SUPERSEDED 2026-07-17 (same day): the whole expect/actual, and `UrlCanonical`, DELETED

The two fixes above were correct answers to the wrong question. The user pushed back on the ~200-line
canonicalizer — *"is there a dramatically simpler way? why is a whole URL parser required?"* — and it isn't.
`UrlCanonical` existed only to reconcile **two** platform url parsers we had chosen to wrap under one
`expect class Url` (`java.net.URI` on jvm, `org.w3c.dom.url.URL` on js). The divergence was self-inflicted:
one implementation has nothing to reconcile.

A production-call-site audit made the case decisive — `Url.scheme` and `Url.query` have **zero** production
callers; `Url.path` has one (`DataLocation.parent`, only `.isEmpty()`); `Url.parse` has one (the null gate in
`DataLocation.parse`, which tries `FilePath.parse` **first**). ~646 lines of expect/actual + canonicalizer +
both-platform contract test, to answer "is this a valid url?" and "is its path empty?".

**`Url` is now a single ~145-line `commonMain` value class** keyed on the verbatim `location` string — the
exact shape of its sibling `FilePath`, which never had a divergence problem because there has only ever been
one of it. Deleted: `commonMain/platform/UrlCanonical.kt` (208), `jsMain/platform/Url.kt` (128),
`jvmMain/platform/Url.kt` (76), `commonTest/platform/UrlCanonicalTest.kt` (182 — the "contract" existed only
to keep two parsers reconciled; with one parser there is nothing to keep in sync). The equals⟺digest invariant
now holds **by construction** (equals/hashCode/digest/toString all key on `location`), so the identity-contract
comment the expect class needed — which both actuals had violated — is gone too. The JVM-only, opt-in
`normalize()` survives as `jvmMain/platform/UrlJvm.kt`, mirroring `FilePathJvm.normalize()`; it is off the
identity path and never runs on js, so `java.net.URI` is unproblematic there.

What changed observably: **no normalization** (`http://X.com` ≠ `http://x.com`; matches `FilePath`, and matches
what the jvm did *before* the canonicalizer briefly existed — DataLocations are produced jvm-side), and
**validation is a scheme check, not a parse** (a bad url fails when opened, not when parsed). A one-char scheme
is rejected so a Windows drive is never mistaken for a url. `UrlTest` rewritten to pin the new behaviour
(verbatim location, space accepted not rejected, drive-is-not-a-url) and keep the equals⟺digest biconditional;
**85/85 on JVM and JS**, `:kzen-auto-jvm:test`, JS bundle, `selfTest` all green.

**Diffstat for the collapse: `+250 / −602` across the seven Url files** — i.e. the two "fixes" above plus the
machinery they fixed were together a net **−352 lines** once the wrong question was dropped. The lesson for
SER4/SER5 (recorded because it generalizes): when a shared abstraction needs a reconciliation layer between two
platform backends, question the two backends before building the layer. **The verification lesson stands
unchanged** — every defect here, including the ones that motivated the delete, was JS-visible only.

### Files changed

- **Build**: `kzen-auto-{js,jvm}/build.gradle.kts` (serialization plugin).
- **DTOs** (kzen-auto-common `commonMain`): `util/storage/StorageAreaInfo.kt`, `util/storage/StorageBundleInfo.kt`
  (full codec deletion), `util/data/DataLocationInfo.kt` (annotate; codec retained), `util/data/DataLocation.kt`
  (+`DataLocationSerializer` — the first 2c-style value-object serializer in kzen-auto-common; hand-written
  because the wire form is the canonical string, not the two-field structure).
- **Server**: `KzenAutoMain.kt` (`serverJson` + `respondJson`; `routeStorage`/`routeFileListing`),
  `api/RestHandler.kt` (typed returns; `.toCollection()` dropped).
- **Client**: `service/rest/ClientRestApi.kt` (3 rewrites), `client/util/ajaxUtil.kt` (`clientJson`).
- **Tests**: `kzen-auto-common/commonTest/.../serialization/WireDtoSerializerTest.kt` (12 tests);
  `kzen-lib-common/commonTest/.../serialization/Ser4SpikeTest.kt` (2 tests, **test-only, delete after SER4**).
- **Docs**: `kzen-auto/docs/architecture.md` § 3 (Long-on-the-wire rule).

### Verification (all green)

- `:kzen-auto-common:jvmTest` **and `:kzen-auto-common:jsTest`** (ChromeHeadless) — 12/12, 0 skipped.
  Running the JS half was decisive: it is what actually proves the Long-as-number decision on the platform the
  convention was about, and it is what surfaced the `Url.equals` asymmetry.
- `:kzen-lib-common:jvmTest` (spikes 2/2); `:kzen-auto-jvm:test`; `:kzen-auto-js:compileKotlinJs` + bundle.
- **Live headless boot + curl of all three migrated endpoints** (jar on temurin-26, port 18099):
  - `/storage/summary` → `"size":9651424`, `"bundles":812`, `"deletable":true` as real numbers/booleans, and
    `"budget":1073741824` **present on `code-cache` but absent on `report`/`index`** — the load-bearing
    null-omission confirmed on real data, not just in a fixture.
  - `/storage/bundles?area=report` → `"size":976`, `"modified":1783909526002` (epoch millis as a number),
    `"active":false`.
  - `/file-listing` → `path`/`name`/`modified` strings unchanged; `"size":992`, `"dir":true` now typed.
  - **`Content-Encoding: gzip` still engages** on `respondText` (TP1 preserved), and the un-migrated
    `/storage/delete` still answers `text/plain` under the same ContentNegotiation install — the two response
    paths coexist as designed.
- `:kzen-auto-test:selfTest` — run as a regression backstop; **honest caveat: it does not cover these
  endpoints** (grep of `kzen-auto-test/src` for `storage`/`file-listing`: zero hits). It only proves the client
  still boots with the new plugin wiring.
- **Manual dev-loop smoke NOT yet done** (headless session) — adds to the master plan's smoke debt:
  1. ribbon **storage manager** (`client/objects/ribbon/StorageManagerController.kt`, from `HeaderController.kt:282`)
     — open panel (`storageSummary`), expand an area (`storageBundleList`), check sizes/counts/`modified`/`active`
     and **the delete button's enablement** (that's `deletable`, the string→boolean flip); delete a bundle.
  2. `/file-listing` → the **Job** document's `MultiFileInputEditor.kt:254` — the *only* caller of `listFiles`
     (not the Report input browser, contra phase 3's verification note).
  3. **Regression: the Report input browser** (`report/input/browse/…`) — it gets `DataLocationInfo` via the
     **value-tree** plane and must be unchanged. Most likely victim of an over-deletion.

### THE GATE — verdict: **PROCEED to SER4**, with a resized expectation

**Measured** (`git diff --numstat`, per file; code-only aggregate strips comment/blank lines):

| Bucket | File | Net LOC |
|---|---|---|
| **Wire-only DTO** | `StorageAreaInfo.kt` | **−27** |
| **Wire-only DTO** | `StorageBundleInfo.kt` | **−22** |
| **Bucket-C DTO** | `DataLocationInfo.kt` | **+17** |
| **Bucket-C support** | `DataLocation.kt` (new serializer) | **+29** |
| **Call site** | `ClientRestApi.kt` | **−20** |
| | **Code-only aggregate** | **+60 / −103 = −43** |

**Effort/robustness:** ~0 surprises on the two storage DTOs — annotate, delete codec, done. The whole family
compiled and went green first try on JVM; the only red was the JS `Url.equals` find, which is a pre-existing
bug in a platform class, not a migration cost. Robustness is *clearly* better where it applies: typed fields,
no key constants, no `@Suppress("UNCHECKED_CAST")`, no hand-walk, and both ends generated from one declaration.

**Why proceed:** the wire-only rate is a solid **≈ −25 LOC/class** with near-zero effort and a real robustness
gain, and SER4's wire-only set (`LogicStatus`/`LogicRunInfo`/`LogicRunFrameInfo`, `TaskModel`,
`ObjectStableMapper`) is precisely that shape. The two SER4-specific unknowns this thin sample couldn't reach
were **de-risked directly** by `Ser4SpikeTest`: a recursive `@Serializable` round-trips in KMP commonMain, and
a nullable-without-default encodes as explicit JSON `null` (the sentinel-kill works). SER5's Jackson-2 removal
is unlocked only by finishing SER4.

**Read the −43 honestly — do NOT extrapolate it.** The sample is 3 flat leaf DTOs; **one of the three nets
positive**. The bucket-conditional rates are the real finding:
- **wire-only ≈ −25/class** (what SER4's set mostly is), but
- **Bucket-C ≈ +17/class, plus ~+29 for each new value-object serializer** — the codec is *retained* per
  phase 4's own step text, so the class only *gains* annotations and a warning banner.

SER4's list contains several Bucket-C classes (`TaskProgress`, `LogicTraceEvent`, `LogicTraceEntry`,
`LogicRunExecutionInfo`), so **SER4's net LOC will be materially worse than −43 — plausibly near zero.**
That is not a reason to stop: SER4's justification is the sentinel-kill, the type-checked contract, and
unblocking SER5's Jackson-2 removal — **not** line count. Anyone scoring SER4 on LOC alone will conclude
wrongly. Also carried: **`ObjectStableMapper` has no `toCollection` at all** — SER4 must invent one.

### Why no value-tree pilot (the standing answer — re-read before re-opening)

Considered and rejected; the premise that it would resize SER4/SER5 is **false**:
1. **Neither SER4 nor SER5 migrates that plane.** Phase 4's own text keeps `toCollection` for value-tree
   classes, and SER5 is untouched by it: Bucket-B maps **never reach Jackson** — they are lowered inside
   `ExecutionValue` and encoded by SER2's `ExecutionValueSerializer`, one layer *below* ContentNegotiation.
   Verified against the `RestHandler` return inventory above: `call.respond` only ever sees
   `Execution*`/`TaskModel`/`LogicStatus` + SER3's 3. The ~25 Bucket-B classes are off the critical path —
   a future **SER6**, not this gate.
2. **The seam has a real defect — the standing blocker.** An `ExecutionValue.ofSerializable(value, serializer)`
   needs `DTO → JsonElement → Any? → ExecutionValue`. The `Any?` step is SER2's `jsonElementToAny`, which by
   design **collapses every JSON number to `Double`**. So `OutputInfo.size: Long` would go
   `12345 → NumberExecutionValue(12345.0) → JsonPrimitive("12345.0") → decodeLong()` → **SerializationException**.
   Solve this first or don't open the question.
3. `ExecutionValue` is `Digestible` — changing how a DTO lowers into it changes **content-addressing digests**.
4. Blast radius: the bridge functions are `private` file-scoped; decode sites are scattered across
   stores/controllers, not one `ClientRestApi`; and the `CalculatedColumnEval` generated-source trap lives there.

---

## Phase 4 as-built (SER4 ✓ 2026-07-17)

**Direct-wire migrated (kotlinx `@Serializable`, hand codecs deleted):** `LogicStatus`, `LogicRunInfo`,
`LogicRunFrameInfo` (recursive), `LogicRunState`/`TaskState` (enums), `TaskModel`, `TaskId` (new
`TaskIdSerializer`, STRING). `epoch`/`structureVersion`/`sequence` ride the built-in `LongAsStringSerializer`;
`@SerialName` preserves the short keys (`location`/`execution`/`id`/`partial`/`result`). **The `"null"` string
sentinel on `LogicStatus.active` is dead** — it is now a nullable-without-default property, so stock `Json`
emits an explicit JSON null; verified live: no-run `/logic/status` → `{"epoch":"0","structureVersion":"1","active":null}`.

**The scope split was the crux, and it was NOT the phase text's literal list.** The trace-query surface
(`LogicTraceEvent`/`LogicTraceEntry`/`LogicTraceSnapshot`/`LogicRunExecutionInfo`, plus the flow visual models
and `TaskProgress`) does **not** ride the direct wire — it is wrapped in an `ExecutionValue` by the **detached**
`LogicTraceEndpoint` and rides SER2's `ExecutionValueSerializer`. So those kept `toCollection`/`ofCollection`
untouched and got a **dual-role comment only, NOT `@Serializable`** (annotating them would be inert and
misleading — they never hit a direct kotlinx codec). Only three families were genuinely direct-wire:
`LogicStatus`+tree, `TaskModel`, and the `ObjectStableMapper` snapshot (kept `Map<String,String>` on the wire).

**One non-obvious dependency:** `TaskModel.partialResult: ExecutionSuccess?` is the *concrete* subtype, not the
sealed `ExecutionResult` base, so it needed its own `ExecutionSuccessSerializer` (added beside SER2's three in
`ExecutionValueSerialization.kt`; `@Serializable(with=…)` on `ExecutionSuccess`). `finalResult: ExecutionResult?`
uses the base serializer automatically.

**Server:** `RestHandler.logicStatus()`/`taskSubmit`/`taskQuery`/`taskCancel` return typed DTOs; `logicStatusJson()`
+ the `JsonMapper` field were **deleted — RestHandler no longer imports Jackson**. `KzenAutoMain` routes use
`respondJson` (GET `/logic/status`, task, object-stable); the SSE `/logic/events` frame is
`serverJson.encodeToString(restHandler.logicStatus())` (same codec as the GET, byte-identical — encoded outside
the controller monitor). **Client:** `ClientRestApi` decodes via `clientJson` (`logicStatus`/`parseLogicStatusText`,
task*, stable snapshot); new `getOrPutOrNull` for the nullable task decodes; the old `Json`-arg `parseLogicStatus`
and the dead `getOrPutJsonOrNull` were removed. **`TesterClient`** (kzen-auto-test) dropped its Jackson mapper +
ktor `ContentNegotiation{jackson()}`: `status()` → typed `LogicStatus`, `detached()` → `Json.decodeFromString<ExecutionResult>`,
`isCompleted`/`isPaused` retyped (`active == null` / `active?.state == Paused`).

**Tests:** new `LogicWireDtoSerializerTest` (kzen-lib-common commonTest) pins round-trip + wire form (string Longs,
explicit-null sentinel-kill, recursive tree, `@SerialName` keys, omitted-`position`); `Ser4SpikeTest` **deleted**
(the real DTOs now pin the same behaviour).

**Verified:** `:kzen-lib-common:jvmTest`+`:jsTest` green (ChromeHeadless — the JS `Long` decode); publishToMavenLocal;
kzen-auto `:kzen-auto-common:jsTest` (SER3 still green), `:kzen-auto-jvm:test`, all-module compile; **`:kzen-auto-test:selfTest`
green** (drives the migrated `/logic/status` + detached trace through `TesterClient`); live headless boot confirmed the
`/logic/status` wire form. LOC net ≈ 0, exactly as the gate predicted.

**Left for SER5:** the manual dev-loop smoke SER3 already owed (ribbon storage manager, Job `MultiFileInputEditor`,
Report input browser) plus SER4's own (SSE repaint on pause/settle through the shell proxy; Report Task-paradigm
submit/query) — none block SER5's ContentNegotiation flip. The `ktor-serialization-jackson` dep in **kzen-auto-test**
is now unused (TesterClient stopped negotiating) — SER5 can drop it with the server-side Jackson removal.

---

## Phase 5 as-built (SER5 ✓ 2026-07-18) — **SER TRACK COMPLETE**

**The flip was NOT the mechanical one-liner the phase text implied.** Exploration found **four** `RestHandler`
methods still returning raw `Map`s through Jackson's reflective serializer, which `json()` cannot serialize
(no `Any?` serializer): `scan` (`Map<String, Any>`) and `notationBatch` (`Map<String, String>`) — **never in
any SER inventory** — plus `actionDetached` and `logicRequest`, both `ExecutionResult.toJsonCollection()`,
which SER3's table assigned to SER4 but **SER4 left undone**. All four had to migrate before the flip.

### Server (kzen-auto-jvm + one kzen-auto-common DTO)
- **New `NotationScanDocument`** (`kzen-auto-common/.../util/scan/`): `@Serializable data class(documentDigest:
  String, resources: Map<String,String>? = null)`, mirroring the `/scan` wire shape byte-for-byte. `resources
  = null` default is load-bearing (omit-on-null, same rule as `StorageAreaInfo.budget`); the client reads
  absent and explicit-null identically, so the omit is harmless (wire-only, same-release). Pinned by 3 new
  `WireDtoSerializerTest` cases.
- `RestHandler`: `scan(...)` → `Map<String, NotationScanDocument>` (builds the DTO instead of the inline
  nested `mapOf`); `actionDetached`/`logicRequest` → return `ExecutionResult` directly (dropped the trailing
  `.toJsonCollection()` — SER2's `ExecutionResultSerializer` reproduces that exact form); `notationBatch` kept
  its `Map<String,String>` return. RestHandler was already Jackson-free.
- `KzenAutoMain`: install flipped `jackson(streamBody=false)` → `json(serverJson)`; the 7 route sites
  (`scan`/`notationBatch`×2/`actionDetached`×3/`logicRequest`) now go through `respondJson`.

### The `respondJson`-vs-collapse decision — KEPT `respondJson`, did NOT collapse to `call.respond(dto)`
Phase 5's step 1 (and the in-code comment) called for collapsing `respondJson` into `call.respond(dto)` under
`json()`. **Deliberately not done.** `respondJson` pre-encodes via `respondText`, yielding a **buffered
`TextContent`** that `install(Compression)` gzips in place — which is exactly the property the retired
`streamBody=false` comment fought to preserve. Routing `call.respond(dto)` through the kotlinx converter risks
a streaming `WriteChannelContent` (the "Compressing a WriteChannelContent…" WARN + whole-body buffering).
`respondJson` is now documented as the **permanent** buffered JSON path (comment rewritten), and `json()` is
installed only so a future `call.respond(dto)` still resolves the kotlinx serializer. This is the approved
plan's sanctioned fallback, chosen up front rather than after a failed gzip check. (kzen-shell, which has **no**
Compression install, keeps its idiomatic `call.respond(list)` / `call.respond(boolean)` under `json()`.)

### IconCollectionHandler ported to kotlinx (kzen-auto-jvm fully Jackson-free)
Rewrote the ~95-line subset filter from the `tools.jackson` tree API (`readTree`/`ObjectNode`, mutated in
place) to kotlinx `JsonObject`/`buildJsonObject` (immutable — accumulate into `mutableMapOf`/`mutableListOf`,
freeze at the end). Same parse-once-and-cache semantics (`Json.parseToJsonElement` on the ~8 MB collection,
cached per set). Output via `JsonElement.toString()`; caller still `respondText`s the String. New
`IconCollectionHandlerTest` (fixture collection at `src/test/resources/icons/test-symbols.json`) covers direct
hit, alias-chain resolution, dead-end alias → `texture` fallback + `not_found`, unknown name, missing collection.

### Client (kzen-auto-js) + ClientJsonUtils removal (kzen-lib-js)
- `ClientRestApi`: the 5 call sites (`scanNotation`, `readNotationBatch`, `performDetached`×2, `logicRequest`)
  migrated from `getOrPutJson`/`postJson` + `ClientJsonUtils.toMap` + `fromJsonCollection`/hand-walk to
  `getOrPut`/`post` + `clientJson.decodeFromString<…>`. The now-orphaned `getOrPutJson`/`postJson` helpers and
  the `ClientJsonUtils` / `kotlin.js.Json` imports were deleted.
- **`ClientJsonUtils` (kzen-lib-js) + its jsTest deleted** — `ClientRestApi` was its last consumer anywhere in
  the ecosystem (grep-confirmed). kzen-lib round-trip: `publishToMavenLocal` → kzen-auto `--refresh-dependencies`.

### Jackson dependency removal
- **kzen-auto-jvm** `build.gradle.kts`: dropped `jackson-module-kotlin` + `ktor-serialization-jackson`,
  uncommented `ktor-serialization-kotlinx-json`.
- **kzen-auto-test** `build.gradle.kts`: dropped `jackson-module-kotlin`, `ktor-serialization-jackson`, and the
  now-dead `ktor-client-content-negotiation` (TesterClient was already Jackson-free — SER4). kotlinx-json
  arrives transitively via kzen-auto-common's `api(...)`.
- **`jacksonModuleKotlin` constant deleted** from kzen-auto `buildSrc/Dependencies.kt` (no references left).
- **kzen-shell** (Kotlin/JVM single-module, had no kotlinx setup): added `kotlin("plugin.serialization")` +
  `kotlinx-serialization-json` dep (new `kotlinxSerializationVersion` constant), uncommented
  `ktor-serialization-kotlinx-json`, dropped `jackson-module-kotlin` + `ktor-serialization-jackson` + the
  `jacksonModuleKotlin` constant. `KzenShellMain` install `jackson()` → `json()`; `RunningProjectStatus` gained
  `@Serializable`; `ProxyHandler.respondProxyError` rebuilt its `{error,name}` body with `buildJsonObject`
  (its own `JsonMapper` was independent of ContentNegotiation, so the flip alone wouldn't have removed it).
  **kzen-shell is now Jackson-free** (grep-clean). Proxied traffic is untouched byte-passthrough.
- **kzen-launcher** unchanged — keeps Jackson 3 YAML (`jackson-databind` + `jackson-dataformat-yaml`) for
  `ProjectRepo` only. This is now the ecosystem's sole Jackson.

### Docs
Umbrella `kzen/AGENTS.md`: Jackson pin shrunk to launcher-YAML-only; kotlinx-serialization pin extended to
kzen-shell (and notes every server now serves JSON via kotlinx). "Serialized by Jackson" comment on
`RunningProjectStatus` updated.

### Files changed
- **kzen-auto-common**: new `util/scan/NotationScanDocument.kt`; `serialization/WireDtoSerializerTest.kt` (+3).
- **kzen-auto-jvm**: `server/api/RestHandler.kt`, `server/KzenAutoMain.kt`, `server/api/IconCollectionHandler.kt`
  (full kotlinx rewrite), `build.gradle.kts`, `buildSrc/.../Dependencies.kt`; new
  `src/test/.../api/IconCollectionHandlerTest.kt` + `src/test/resources/icons/test-symbols.json`.
- **kzen-auto-js**: `client/service/rest/ClientRestApi.kt`.
- **kzen-auto-test**: `build.gradle.kts`.
- **kzen-lib-js**: deleted `client/ClientJsonUtils.kt` + `jsTest/.../client/ClientJsonUtilsTest.kt`.
- **kzen-shell**: `KzenShellMain.kt`, `proxy/ProxyHandler.kt`, `model/RunningProjectStatus.kt`,
  `build.gradle.kts`, `buildSrc/.../Dependencies.kt`.
- **Docs**: `kzen/AGENTS.md`, this tracker.

### Verification (all green, 2026-07-18)
- **kzen-lib**: `:kzen-lib-js:compileTestKotlinJs` + `publishToMavenLocal` — proves the `ClientJsonUtils`
  deletion compiles (its only consumer was the migrated `ClientRestApi`).
- **kzen-auto** (`--refresh-dependencies`): `:kzen-auto-common:jvmTest` **and `:jsTest` (ChromeHeadless)** —
  `WireDtoSerializerTest` 14/14 on **both** platforms (11 prior + 3 new `NotationScanDocument`, confirmed from
  the persisted report XMLs); `:kzen-auto-jvm:test` all green incl. the new `IconCollectionHandlerTest` (5/5);
  `:kzen-auto-js:compileKotlinJs` + `:jsEsbuildBundle`. **Two first-pass failures were test-assertion bugs in
  my own `IconCollectionHandlerTest`** (compared the fallback value against a `resultIcons["texture"]` key that
  was never requested → `NoSuchElementException`); the handler logic was correct — fixed by requesting `texture`
  alongside so the reference key exists; re-run green.
- **`:kzen-auto-test:selfTest`** green — drives the migrated `/action/detached` + `/logic/status` end-to-end
  through `TesterClient`'s kotlinx decode (typed `ExecutionResult` / `LogicStatus`).
- **Live headless boot** (jar on temurin-26, port 18099):
  - `/scan?fresh=true` → the new `NotationScanDocument` wire form; `resources` **omitted** for resource-less
    docs and **present** for `main/Action Target/~main.yaml` — the null-omission confirmed on real data.
  - `/notation-batch?path=main/Script.yaml` → `{path: yaml}` `Map<String,String>` (note: the path constant is
    `/notation-batch` and the param is `path`, not `/notation/batch?documentPath` — routing unchanged by SER5).
  - `/storage/summary` (SER3 regression) → real numbers/booleans, `budget` present on `code-cache`, absent
    elsewhere — intact under the flipped `json()` install.
  - `/icon/material-symbols.json?icons=home,texture,star` → correct subset — the kotlinx `IconCollectionHandler`
    port works live.
  - **gzip checkpoint (the reason `respondJson` was kept):** `Content-Encoding: gzip` engages on `/scan` and the
    multi-doc `/notation-batch`, and the boot log has **no "Compressing a WriteChannelContent" WARN**. The
    `respondText`-buffered path stays gzip-clean. (Small bodies < `minimumSize(1024)`, e.g. a 3-icon response,
    are correctly left uncompressed.)
- **kzen-shell**: `:test` green (compile + tests); grep-confirmed Jackson-free.
- **Manual dev-loop UI smoke NOT done in this headless session** — carried forward as smoke debt (same items
  SER3/SER4 owed): ribbon storage manager (sizes/counts/`deletable`-driven delete button), Job
  `MultiFileInputEditor` file listing, Report input browser (value-tree `DataLocationInfo`, must be unchanged),
  and an SSE repaint on pause/settle through the shell proxy. None are SER5-specific regressions (the wire is
  byte-compatible), but the visual confirmation remains outstanding.
