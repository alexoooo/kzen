# Serialization improvements — survey + phased cleanup plan

> **Status: planned.** Written 2026-07-13 from a full serialization survey across the five source
> siblings (kzen-lib, kzen-auto, kzen-project, kzen-launcher, kzen-shell). Executor:
> **Opus 4.8 xhigh, one phase per session.** Each phase is self-contained: goal, design decisions
> (already made — do not re-litigate, except at the phase 3 gate), concrete steps with file
> anchors, and verification. Phases are ordered by dependency; do not start a phase whose
> prerequisite is unchecked.
>
> Related plans: `2026-07-10_yaml-parser-strings-and-comments.md` (Y) owns the notation YAML
> format — this plan does not touch `YamlParser`/`YamlNotationParser`. Logic-engine plan E5
> (SSE push) will define a push wire format — phase 4 here makes the trace/status DTOs
> kotlinx-ready, which E5 should reuse (note added there is NOT required; one-way reference).
>
> **Progress tracker** (update as phases land):
> - [ ] Phase 1 — kzen-launcher codec convergence (kotlinx both sides)
> - [ ] Phase 2 — wire-codec classification + kotlinx.serialization foundation (kzen-lib/kzen-auto)
> - [ ] Phase 3 — first endpoint-family migration (storage/file-listing/output) + **payoff gate**
> - [ ] Phase 4 — logic/task/trace/detached family (gated on phase 3's verdict)
> - [ ] Phase 5 — ContentNegotiation flip + Jackson slimming + hygiene sweep

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
   streaming "serializer" (`Digest.Sink`, :194-613) plus three encodings for three consumers:
   `_`-joined base-32 `asString()`/`parse()` (:708/:128, REST), 16-byte big-endian
   `toByteArray()`/`fromBytes` (:719/:41, binary stores), and the sink streaming form (hashing).
   Int-quadruple representation is deliberate (JS can't round-trip `Long` through JSON — comment
   :6-7). This is a crown jewel of the content-addressing design; not a duplication problem.
3. **Binary report stores** (kzen-auto-jvm `.../report/exec/...`: `FileOffsetStore`,
   `FileDigestIndex`, `MmapBitArray`, `FileIndexedTextStore`, `FileValueStatisticsStore`) —
   bespoke `ByteBuffer`/`RandomAccessFile`/mmap formats, performance-driven, self-contained.
4. **Scalar wire responses as `text/plain`** — all ~40 notation commands return
   `Digest.asString()` as text; logic control verbs return enum `.name`; the `notation` query
   returns raw document YAML (`KzenAutoMain.kt:342-346`). Symmetric `asString()`/`parse()`
   value objects (`DocumentPath`, `ObjectLocation`, `AttributePath`, …) are good value-object
   serialization. No JSON-ification wanted.
5. **Request encoding** — GET query params with a size-triggered PUT-form fallback
   (`ClientRestApi.getOrPut`, `getSizeLimit = 1024`, :47/:913-926, paired with each command's
   `put(...)` twin server-side), raw-byte POST for resources. Works; churn would be
   wire-visible for no gain.
6. **kzen-shell's proxy** — streams bytes untouched (`ProxyHandler.handle` :114-216); correctly
   does zero (de)serialization of proxied traffic.
7. **`kzen-projects.yaml` via Jackson-YAML** (`kzen-launcher-jvm/.../project/ProjectRepo.kt:29`)
   — the only YAML-library usage anywhere. Deliberately NOT migrated to the hand-rolled
   `YamlParser`: existing user registry files were written with standard YAML escaping, and the
   hand-rolled parser's non-standard bare-scalar unescaping would corrupt Windows paths
   (`\d` throws). Also kzen-launcher has **no kzen-lib dependency** (verified:
   `kzen-launcher-jvm/build.gradle.kts` deps) and should not gain one for this.

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
  envelope with base64 `Binary`, stringified `Long`, and a `json` primitive-subtree fast-path
  (:203-246 / :84-145) — carries its own header TODO (:11) pointing at kotlinx `JsonElement`.

This is exactly the boilerplate a KMP serialization compiler plugin generates: symmetric,
type-checked, in `commonMain`. kotlinx.serialization is already proven in-stack (launcher
client). The layer is not *wrong* — it works and is KMP-symmetric by construction — but it is
~35 classes of drift-prone hand mapping that exists only because no common-code codec was
adopted when it was written.

**P2 — split-brain codecs and a hidden second Jackson.**

- **kzen-launcher**: the server serializes with Ktor `jackson()` (`KzenLauncherMain.kt:262-264`)
  — partly reflecting data classes, partly ad-hoc hand-built maps
  (`server/api/RestHandler.kt:26-40` duplicates the `ProjectDetail` DTO shape) — while the
  client deserializes with **kotlinx.serialization** (`clientJson` in
  `client/api/ajaxUtil.kt:17-19`, `@Serializable` DTOs in `kzen-launcher-common/.../dto/`,
  `@SerialName("args")` papering over the one key mismatch). Two codec stacks for one wire.
  The common module already applies `kotlin("plugin.serialization")` and `api`-exports
  `kotlinx-serialization-json`; `ktor-serialization-kotlinx-json` is already present as a
  commented-out dependency (`kzen-launcher-jvm/build.gradle.kts:41`) — the convergence was
  started and never finished.
- **Two Jackson generations run in every server.** Verified from the resolved POM:
  `io.ktor:ktor-serialization-jackson` 3.5.1 depends on **legacy Jackson 2**
  (`com.fasterxml.jackson.core:jackson-databind` + `com.fasterxml…jackson-module-kotlin`), while
  the direct mappers are pinned Jackson 3 (`tools.jackson…:3.2.0`). So the AGENTS.md "use
  `tools.jackson`, not legacy" pin covers only the four hand-built mappers
  (`IconCollectionHandler.kt:23`, `ProxyHandler.kt:37`, `TesterClient.kt:47`,
  `ProjectRepo.kt:29`); the actual REST wire serializer in kzen-auto, kzen-launcher, and
  kzen-shell is Jackson 2, dragged in transitively. Every server classpath carries both.

### Minor warts (swept up in phases, not phases of their own)

- `Parameters.getParam/getParamList/getParamOrNull` trio copy-pasted across
  `kzen-auto RestHandler.kt:1337-1369`, `kzen-launcher server/api/RestHandler.kt:93-131`,
  `kzen-shell ProxyHandler.kt:268-296`. **Accepted duplication**: no shared JVM module exists
  across the three (launcher and shell have no kzen-lib dependency) and adding a dep edge for
  three 10-line helpers is worse than the copies.
- `JsonMapper.builder().build()` construction duplicated (IconCollectionHandler, ProxyHandler);
  `ObjectMapper(YAMLFactory…)` constructor style in ProjectRepo differs from the builder style
  elsewhere. Cosmetic.
- `jackson-module-kotlin` (tools.jackson) is declared in kzen-auto-jvm and kzen-shell purely as
  a databind carrier — no source there imports `tools.jackson.module`; only kzen-auto-test's
  `TesterClient` registers `kotlinModule()`.

### Direction decision

Adopt **kotlinx.serialization as the single structured-wire codec**, phased and gated:

- It is the only codec that can live in `commonMain` and generate both sides — the root cause
  of P1 is that no such codec was adopted, so both ends are hand-written (per the standing
  fix-root-cause rule; the alternative of "keep the map protocol but centralize helpers" keeps
  the drift class of bugs and the stringly typing).
- The launcher already half-adopted it; finishing that (phase 1) is small, self-contained, and
  proves the server-side Ktor integration before kzen-auto is touched.
- The wire is same-release-only (the client JS bundle is served by the same server; the
  siblings are a coordinated release train), so wire-format changes are safe. **Persisted**
  forms are not — phase 2 includes a mandatory check for any `toJsonCollection` output that
  lands on disk.
- The end state also removes Jackson 2 from every server (ContentNegotiation flips to
  kotlinx-json), collapsing the two-generation duality; remaining Jackson 3 usage shrinks to
  the two tree-model sites that genuinely want a JSON/YAML tree API (or to zero in kzen-auto if
  phase 5's `JsonElement` port lands).
- **The phase 3 gate keeps this honest**: after one real endpoint family migrates end-to-end,
  measure net LOC, migration effort per class, and subjective wire-contract clarity. If the
  payoff is not clearly there, stop after phase 3 — phases 1–3 are each self-justifying, and
  the remaining codecs are no worse off. No change for the sake of change.

**Deliberately out of scope** (decided; do not re-open inside a phase):

- `YamlParser` / `YamlNotationParser` / notation format (plan Y owns it).
- `Digest` encodings and `Digestible` (identity, not wire; crown jewel).
- Binary report stores (bespoke by design).
- The request side: query params + PUT-form fallback, raw-YAML notation params, raw-byte
  resource POST, `text/plain` scalar responses — all stay exactly as they are.
- `ProjectRepo`'s Jackson-YAML (user-file compatibility + no kzen-lib dep in launcher).
- WebSocket/SSE (logic-engine plan E5 owns push transport).
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
  (`kzen-lib`: `:kzen-lib-common:jvmTest :kzen-lib-jvm:test`; `kzen-auto`:
  `:kzen-auto-jvm:test`), plus a manual dev-loop smoke of the migrated endpoints. UI-facing
  phases: `./gradlew :kzen-auto-test:selfTest` (opt-in; beware a stale tester JVM on 18081).
  Launcher phases: boot `FrontendDevelopmentKt` headless and curl the migrated routes
  (see the launcher headless-verify procedure).
- Mark the phase checkbox in this file's tracker when done, and append a short "as-built" note
  if the implementation deviated.

---

## Phase 1 — kzen-launcher codec convergence

**Goal:** one codec stack (kotlinx.serialization) on both sides of the launcher wire; Jackson 2
gone from the launcher server; the ad-hoc map/DTO duplication gone. Small, self-contained,
and the proving ground for `ktor-serialization-kotlinx-json` before kzen-auto adopts it.

### Steps

1. `kzen-launcher-jvm/build.gradle.kts`: swap `ktor-serialization-jackson` (:42) for the
   already-commented `ktor-serialization-kotlinx-json` (:41). Keep
   `jackson-dataformat-yaml`/`jackson-module-kotlin` (:34-35) — `ProjectRepo` still needs the
   YAML tree API (out of scope above); consider narrowing `jackson-module-kotlin` →
   `tools.jackson.core:jackson-databind` since no Kotlin-module feature is used (ProjectRepo is
   tree-only).
2. `KzenLauncherMain.kt:262-264`: `jackson()` → `json()` (`io.ktor.serialization.kotlinx.json`).
3. Make every `call.respond(...)` payload `@Serializable`:
   - `ArchetypeDetail` (:338-346) — move/confirm as a `@Serializable` DTO in
     `kzen-launcher-common/.../dto/` beside `ProjectDetail`.
   - `RestHandler.listProjects()` (`server/api/RestHandler.kt:26-40`) — delete the hand-built
     `List<Map<String, Any>>` and return the existing `ProjectDetail` DTO (the `args` key is
     already bridged by `@SerialName("args")`; with the server now emitting the DTO the
     annotation becomes the single source of the wire name — keep it).
   - `respondCommand`'s error body (:378-389) — a tiny `@Serializable` `ErrorMessage(message)`
     (or `buildJsonObject`); client error-parse in `ajaxUtil.kt:52-61` stays manual (it must
     tolerate non-JSON proxy error pages).
   - Dev `ShellSimulator.Status` (:26) → `@Serializable` (update its "Serialized by Jackson"
     comment).
4. Client side: no behavioural change expected (it already decodes with `clientJson`); verify
   `ignoreUnknownKeys` still covers everything and delete any now-dead key constants in
   `CommonRestApi` that existed only for the hand-built maps.

### Verification

`cd kzen-launcher && ./gradlew build`. Headless smoke: boot `FrontendDevelopmentKt`, curl
`/rs/...` list/create/rename/args/remove routes and the dev shell-simulator routes; then a
browser pass (list, create from archetype, rename, jvm-args edit, delete). Confirm the
launcher works through kzen-shell (proxy pass-through unchanged).

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
   revert nothing (phases 1–3 stand on their own), and strike phases 4–5 from the tracker
   with a dated note.

### Verification

kzen-auto baseline + manual Report input/output panel smoke (file listing, storage summary,
output preview/export — the migrated surface). selfTest.

---

## Phase 4 — logic / task / trace / detached family

**Goal:** the remaining structured wire — the run/trace/task/detached surface — on kotlinx;
the sentinel warts gone.

### Steps (order within the phase is free)

- `TaskModel`, `TaskProgress` (`kzen-lib-common/.../exec/task/model/`),
  `LogicStatus`/`LogicRunInfo`/`LogicRunExecutionInfo`/`LogicRunFrameInfo` (recursive tree),
  `LogicTraceEvent`/`LogicTraceEntry`/`LogicTraceQuery`/`LogicTracePath`,
  `ExecutionResult`/`ExecutionRequest` wire call sites (2d serializers),
  `ObjectStableMapper` snapshot, and the flow visual models
  (`VisualFlowModel`/`VisualVertexModel`/`VisualVertexTransition`) — per the 2a table:
  wire-only codecs are deleted after migration; value-tree-feeding ones keep `toCollection`
  for that path and note the dual role in a comment.
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
polling surface); manual dev-loop pass over run controls, trace display, detached actions
(Report panel), and a task-based flow. kzen-lib publishToMavenLocal round-trip.

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
   comment); `ProxyHandler.respondProxyError` (:246-254) builds its `{error, name}` body via
   `buildJsonObject`; drop both `jackson-module-kotlin` (`build.gradle.kts:36`) and
   `ktor-serialization-jackson` (:45). kzen-shell ends Jackson-free.
4. **kzen-launcher**: narrow ProjectRepo's dependency per phase 1's note if not already done.
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
| 1 | small session | low (half-done already; launcher-local) | — |
| 2 | one session | low (additive; no wire change) | — |
| 3 | one session | low-medium (first real migration; gated) | 2 |
| 4 | one full session | medium (trace/status surface is wide; dual-purpose codecs) | 3 gate = yes |
| 5 | one session | low (mechanical flips; wide but shallow) | 4 (auto/test parts); 1 (launcher part) |

Phase 1 is independent of everything and can run any time. Phases 2–5 are a strict chain.
If the phase 3 gate says stop, phase 5's launcher/shell items (3 and 4) can still run as a
standalone micro-session (shell's two endpoints don't depend on the kzen-auto migration), and
the kzen-auto items are dropped.

Registered in `2026-07-10_master-plan.md` as **SER** (2026-07-13): phase 1 is stage 0 session
0.7; phases 2–5 are an interleavable track in stage 7, with a soft edge SER4-before-E5 (E5's
push format should reuse the kotlinx trace/status DTOs).
