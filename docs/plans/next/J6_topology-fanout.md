# J6 — topology: fan-out + non-linear ergonomics — implementation plan

> **Status: demand-driven after DM7c; requires re-elaboration before execution.** Generated 2026-07-19 by elaborating
> `../2026-07-25_job-improvements.md` **Phase 6** against current code. Stable design decisions are
> PRE-MADE there (TeeWorker, not multi-reader channels; no 2D canvas); the element-copy mechanism is superseded by
> DM6/DM7c and must be re-elaborated. Every original anchor below was re-verified
> 2026-07-19 (post SER2–SER5 / Y / G5 / G7 / TP1 / TP3 / TP4): the four headline anchors are
> **unchanged**, and the real drift found is in *test* land and one API-naming trap (see
> Current-state findings).
>
> ## ⚠️ 2026-08-28 carrier supersession
>
> DM7c deletes `JobMessage`, `FlatView`, and the payload/flat-specific copy mechanism described below. Preserve the
> `TeeWorker`, list-port, single-reader, and UI decisions, but re-elaborate element forwarding from DM6/DM7c's
> `DataValue` exclusive-transfer and alias/copy rules when demand opens J6. No carrier-specific snippet in this file
> is executable after DM7c.
>
> ## ⚠️ Re-validated 2026-07-25 — the copy rule changed shape
>
> Written **before** the typed `JobMessage` element model (landed 2026-07-22). The pre-made
> decision survives in spirit but its *mechanism simplifies*, because **every element crossing a
> Job channel is now a `JobMessage`** — there is no longer a mixed element lane to type-test.
>
> | Was | Now |
> |---|---|
> | `element is DataRecord` runtime check, copy or share accordingly | **no check** — every element is a `JobMessage`; copy the flat part **if present**, share the payload by reference |
> | `DataRecord(element.header, element.record.prototype())` | `JobMessage(element.payload, element.flat?.let { FlatView(it.header, it.record.prototype()) })` — `FlatView(var header, val record)`; the header stays **shared by reference**, which is still correct |
> | `of: DataRecord` on a typed tee port | `of:` now describes the **payload** type; the `DataRecord` type object no longer exists. A tee over the pure-flat lane declares no `of:` |
> | `DataRecord.kt` kdoc (ownership contract) | same contract, now in `JobMessage`'s kdoc |
>
> **Payload sharing is safe and deliberate**: forwarding one payload reference to n outputs matches
> receiver-ownership as long as no consumer mutates the payload object itself (consumers mutate the
> *flat* part, which is what gets copied). Record that assumption in the `TeeWorker` kdoc.
>
> Also re-check `ChannelTypeDefiner` before touching it — the typed-flow work (`TypeAssignability`,
> `WorkerLane`, `WorkerBase.payloadFlow`) reshaped its neighbourhood after this was written. And
> `SelectChannelEditor` now sits on `SelectReferenceEditorBase` (AE5, landed 2026-07-20) —
> **extend it, don't fork it.**
>
> ⚠️ **PRIORITY — DEMAND-DRIVEN AFTER DM7c.** Per the master plan
> (`../2026-07-25_master-plan.md`, ledger row 27), execute J6 only when fan-out demand materializes. It is not a filler
> during DM1–DM7c because it touches the same channel ownership surface; nothing in the active spine depends on it.
>
> Executor: one session, Opus-class. Repo: `kzen-auto` (no kzen-lib changes required — verified).
> All paths below are relative to `C:\Users\ostro\IdeaProjects\kzen-auto` unless prefixed.

---

## Scope & goal

Make branching (fan-out) dataflows **expressible without weakening the single-reader guarantee**
and **legible in the ordered-card UI**:

1. The wiring layer (creator + type-definer) learns **list-typed channel-port attributes** —
   dispatching on attribute *type*, never on any Worker class.
2. A built-in **`TeeWorker`** (one input, `outputs: List<ChannelOutput>`) forwards every element to
   every output, deep-copying each message's **flat part**, passing payloads by reference.
3. Client: the channel-select editor gains a **list mode** (add/remove rows), and **manual
   connections render as labelled chips on both endpoint cards**, derived from the same notation
   `JobChannelDerivation` reads. Auto-wire behaviour is byte-for-byte unchanged.
4. **Deadlock-monitor sanity** for tee topologies: a stalled (orphan) branch backpressures through
   the tee and the monitor fires.

Fan-in already works (multi-producer close tracking); worker-to-worker duplex stays manual and
documented. The extension rule is inviolable: no `TeeWorker` (or any Worker-type) knowledge may
appear in `JobRun` / `WorkerLogic` / `EngineJobControl` / `JobChannelDerivation` / synthesis /
`ChannelTypeDefiner` / `JobChannelCreator` / any client general layer.

## Dependencies & coordination

- **Hard prerequisites: none.** All infrastructure exists (verified — see findings F5).
- ~~**AE plan: AE5 has NOT landed**~~ — **CORRECTED 2026-07-25: the whole AE arc (AE1–AE6) landed
  2026-07-20.** `SelectReferenceEditorBase`, `AttributeCommitter`, `DebouncedSubmitter` and
  `AttributeWrapperLookup` all exist, and `SelectChannelEditor` **already sits on
  `SelectReferenceEditorBase`**. Step 3a therefore **extends the migrated editor** — the list-mode
  design below (metadata-type detection, whole-list write, "(auto)" option) transfers unchanged;
  only the commit/observe plumbing follows the shared primitives instead of the old bespoke ones.
  Note the commit path also reports edit-pending through `DocumentEditActivity` (2026-07-23) —
  keep that wiring intact. **Do not introduce a parallel commit path.**
- **J7 removes the `externallyServing` early-return**
  (JobDeadlockMonitor.kt:70-73). Step 4's fixtures deliberately contain **no serve / external
  channels**, so `externallyServing == false` and the monitor is armed under BOTH the current
  blanket-suppression behaviour and J7's precise behaviour — the tests are valid before and after
  J7 and assume nothing about which landed first. (Contrast: the existing
  `job-migration-carryover-test.yaml` fixture *uses* an unserved `external: true` channel as a
  suppression trick — do not copy that trick into J6 fixtures; J7 will have to revisit it there.)
- **J2** (ParameterSource/ResultSink) adds new port-carrying Workers but only scalar ports —
  orthogonal. **J8** items 2/6 touch `JobServeChannelResolver` / `ChannelTypeDefiner` scan scoping —
  orthogonal (this phase keeps the definer's whole-graph scan shape, see Out of scope).

## Current-state findings (anchors verified 2026-07-19)

**F1 — headline anchors: zero drift.** Despite SER/Y/G/TP landings since 2026-07-16:
- `JobChannelDerivation.derive` auto-wire pairing loop:
  `kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/objects/document/job/JobChannelDerivation.kt:84-93`
  (exactly as cited in the constituent plan). Port classification `readWorkerPorts`: lines 104-128
  (`JobChannelPorts.kindOf(attributeMetadata.type)` at 112, `continue` on null); open-port rule
  `isOpenPort` (blank OR dangling-reference reclaim): lines 137-152.
- `JobChannelCreator` type dispatch `when (attributeClassName)`:
  `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/JobChannelCreator.kt:94-111`;
  the scalar-only cast `as? ReferenceAttributeDefinition` that the list case must generalize:
  lines 78-81.
- `ChannelTypeDefiner.compatible` (exact-match + `Any` wildcard):
  `kzen-auto-common/.../objects/document/job/ChannelTypeDefiner.kt:192-197`. Port scan: lines
  127-160 — **scalar-only today**: line 139-141 `as? ScalarAttributeNotation ?: continue` silently
  skips a list port. Single-reader check: 173-177. Failure surface:
  `AttributeDefinitionAttempt.failure` on the *channel's* `elementType` attribute (kdoc lines 40-45).
- `JobDeadlockMonitor.start` externally-serving early-return:
  `kzen-auto-jvm/.../server/exec/job/JobDeadlockMonitor.kt:69-76` (return at 70-73). Verdict:
  `blocked >= active` sustained over `graceThreshold = 4` polls × 50 ms (lines 85-113).
  `JobChannel.blockedCount` (endpoints suspended in a channel op): JobChannel.kt:94-96, bracketed by
  `tracked` (101-109).

**F2 — API-naming trap (constituent-plan text is wrong on the mechanism, right on the decision).**
`FlatFileRecord` (`kzen-auto-plugin/src/main/java/tech/kzen/auto/plugin/model/record/FlatFileRecord.java`)
has THREE copy-flavoured methods:
- `clone(FlatFileRecord that)` — lines 547-558 — **SHALLOW array adoption** (`fieldContents =
  that.fieldContents`; aliases the backing arrays). Using this in the Tee would be exactly the
  shared-mutable-state bug the deep-copy decision exists to prevent.
- `copy(FlatFileRecord that)` — lines 496-514 — deep content copy into an existing instance.
- `prototype()` — lines 561-565 — allocates a fresh record and `copy`s into it: **this is the
  deep-copy call the Tee must use.** The pre-made decision ("Tee deep-copies the flat part") stands;
  cite `prototype()`, never `clone`.
`FlatView` (`kzen-auto-jvm/.../server/objects/job/worker/FlatView.kt`) pairs the record
with a **shared, immutable** `HeaderListing` (`val values: List<...>` — HeaderListing.kt:7-9), so
the tee shares the header reference and deep-copies only the record. The hazard is real:
`FormulaWorker.onElement` **mutates the received record in place** (`record.addAll(formulaValues)`,
FormulaWorker.kt:72-80) under the ownership-transfer contract (`JobMessage` kdoc) — a by-reference
tee would let one branch's Formula corrupt the sibling branch.

**F3 — test drift: `JobChannelTypingTest` was DELETED in the engine rewrite** (commit `4bc9bcf2`
"new Logic progress", 147 lines), leaving three fixtures orphaned with no consuming test:
`kzen-auto-jvm/src/test/resources/notation/test/job-typed-channel-test.yaml`,
`job-channel-type-mismatch-test.yaml`, `job-channel-multi-consumer-test.yaml` (each still comments
"See JobChannelTypingTest"). The deleted test's definition-failure assertions
(`AutoTestUtils.graphDefinitionAttempt(AutoTestUtils.readNotation())` →
`attempt.failures[channelLocation].attributeErrors[AttributeName("elementType")]`) are
engine-independent and revivable verbatim (`AutoTestUtils.readNotation` / `graphDefinitionAttempt`
still exist — AutoTestUtils.kt:38, 78). Step 4 revives the class (minus the old happy-path run test,
whose engine harness died with `continueOrStart`; JobNotationTest covers that) and adds the list
cases.

**F4 — the client currently cannot author ANY manual wire.**
`WorkerDisplayDefault.renderAttributeEditors`
(`kzen-auto-js/.../objects/document/job/display/WorkerDisplayDefault.kt:287-304`) **skips every
scalar channel port** (`JobChannelPorts.isChannelPort(attributeMetadata.type)` → skip: ports are
"order-managed"). `SelectChannelEditor` exists and is registered (job-js.yaml:69-71) but nothing
renders it. Channel objects ARE ribbon-insertable (job-js.yaml:242-257 `ChannelTool` /
`DuplexChannelTool` → nest under `channels`, JobController.kt:363-369) but render nowhere in the
stage. Consequence: without step 3c below, a tee's *branch inputs* (scalar `input` ports on the
downstream workers) could not be pointed at the tee's output channels from the UI at all, and the
whole phase would be authorable only through hand-edited YAML. Step 3c closes this with a minimal,
notation-gated un-hiding (the one place this plan goes beyond the constituent text — rationale
there).

**F5 — all list infrastructure already exists in kzen-lib; zero kzen-lib changes.** Verified:
- `StructuralAttributeDefiner.defineList` (kzen-lib-common `objects/base/StructuralAttributeDefiner.kt:125-151`):
  a `ListAttributeNotation` under metadata `is: List, of: <endpoint>` defines to
  `ListAttributeDefinition(values = [ReferenceAttributeDefinition, …])` — each non-primitive scalar
  element becomes a reference (defineScalar:116-121). Empty list → empty `ListAttributeDefinition`.
- Construction-order DAG **recurses into list elements**: `ObjectDefinition.traverseAttribute`
  (kzen-lib-common `model/definition/ObjectDefinition.kt:131-137`), so each referenced Channel
  constructs before the Worker — same guarantee the scalar ports enjoy.
- Attribute-level `creator:` selection is shape-agnostic (`AttributeObjectDefiner`:67-69 registers
  the creator per attribute; the creator receives the whole `AttributeDefinition`), so
  `creator: JobChannelCreator` on a list attribute routes the full `ListAttributeDefinition` to
  JobChannelCreator — the list case is implemented entirely inside that one object.
  (`DefinitionAttributeCreator.createDefinition`:65-68 is the in-tree precedent for recursing a
  list definition.)
- Nested generics ARE expressible in metadata: `NotationMetadataReader.readAttributeType` /
  `readAttributeTypeGenerics` (kzen-lib-common `service/metadata/NotationMetadataReader.kt:389-398,
  407-432`) accept `of:` as a scalar OR a map, recursively — so a third party can declare
  `outputs: {is: List, of: {is: ChannelOutput, of: <PayloadType>}}` for a *typed* tee port. The
  built-in Tee stays untyped (see step 2). `List` archetype: kzen-base.yaml:90-92
  (`class: kotlin.collections.List` = `ClassNames.kotlinList`). Precedent for `is: List` on a
  Worker: `MultiFileReaderWorker.paths` (job-worker.yaml:63-66).

**F6 — dangling references crash the compile, and list ports have no reclaim.**
`GraphDefinition.transitiveClosure` **throws** on an unresolvable reference (kzen-lib-common
`model/definition/GraphDefinition.kt:81-83`), reached via
`JobLogicCompiler.compile` → `filterTransitive(documentPath)` (JobLogicCompiler.kt:39-41). Scalar
manual wires dodge this via `isOpenPort`'s dangling-reclaim (a leftover reference to a deleted
Channel counts as *open* and synthesis re-points it — JobChannelDerivation.kt:131-152) — but that
reclaim cannot apply to a list element (there is no auto-wire to re-point it to). Unhandled, a user
deleting a Channel a tee output references turns the next run into an opaque
`IllegalArgumentException("Missing …")`. Step 1d adds a compile-time pre-check with an honest
message (and covers the pre-existing unpaired-scalar edge for free).

**F7 — everything downstream of the creator is already generic.** `JobRun` enumerates ALL
channels under `main.channels/` — manual and synthesized alike
(`JobChannelSynthesis.channelLocationsOf`, JobChannelSynthesis.kt:93-101) — indexes one-way channels
by stable id for **migration carryover** (JobRun.kt:106-135: `onCapture` → `drainBuffered`,
restore → `preload`) and sums their `blockedCount` for the **deadlock monitor** (JobRun.kt:158-171,
`externallyServing = externalClients.isNotEmpty()` at 166). So tee branch channels get lossless
migration carryover and deadlock accounting with **zero new code** — step 2c/4 only pin this with
tests. Close-on-last-producer is per-endpoint (`newProducer()` increments `openProducers`,
JobChannel.kt:78-90), so one `newProducer()` per list element makes fan-in counting correct by
construction.

**F8 — where the client reads the derivation** (for chips): `JobController.updateStageModel`
(JobController.kt:271-278) derives connections per `ClientState` publish and value-gates them into
state; the gold pipes render per gap (JobController.kt:592-602, 636-731); cards are
`JobObjectSlot` → `WorkerDisplayManager` → `WorkerDisplayDefault` (JobObjectSlot.kt:113-115).
Chips belong in `WorkerDisplayDefault` (generic, port-type-driven — the same place the outcome chip
renders, WorkerDisplayDefault.kt:158-160). The list-write precedent is
`MultiFileInputEditor.applyPaths` (MultiFileInputEditor.kt:201-209): rewrite the whole list via
`UpsertAttributeCommand` — robust for inherited-only (fresh palette insert) and materialized lists.

**F9 — test-fixture conventions** (for step 4): test-only Workers live in
`kzen-auto-jvm/src/test/kotlin/tech/kzen/auto/server/objects/job/worker/test/` with a hand-written
`ModuleReflection` (`GatedWorkerTestModule.kt` — no KSP in the test source set) and their archetypes
declared inline in the test fixture YAML (job-migration-carryover-test.yaml:12-43). The engine
harness is `RunEngine(jobLogic, stableId)` + `resume()/step()/awaitQuiescent()/migrate()/await()`
(JobDeadlockTest.kt:52-102, JobMigrationTest.kt:76-121, JobNotationTest.kt:59-81). J6's e2e tests
need **no new test Workers** — production workers + the existing Gated* fixtures suffice.

## Pre-resolved questions (from the phase spec, answered against code)

| Question | Resolution |
|---|---|
| List-port dispatch point | Entirely inside `JobChannelCreator` (attribute-level `creator:` routing is shape-agnostic, F5). One `newProducer()` per `ChannelOutput` element; each list element is an independent endpoint; close-on-last-producer counts each (F7). |
| Kind detection for a list port | New `JobChannelPorts.listElementKindOf(type)`: `type.className == ClassNames.kotlinList && Kind.ofClassName(type.generics[0].className)`. `kindOf` itself stays null for `List` — which is precisely what keeps auto-wire (derivation) and the card's port-hiding untouched. |
| Type-check failure semantics | One bad list element fails the **channel's** definition (same `AttributeDefinitionAttempt.failure` on `elementType` as today), error labelled `worker.port[index]`. Concrete test in step 4 (revived `JobChannelTypingTest`). |
| Element type of a list element | `portType.generics[0].generics.getOrNull(0)` (the `of:` under the endpoint type); null/`Any` = wildcard, exactly like scalar ports (`compatible`, ChannelTypeDefiner.kt:192-197 — unchanged). |
| Deep-copy mechanism | `FlatFileRecord.prototype()` (NOT `clone` — F2). `JobMessage(element.payload, element.flat?.let { FlatView(it.header /* shared */, it.record.prototype()) })`. |
| Copy count | `outputs[0]` receives the original (ownership transfers as today); `outputs[1..n-1]` receive fresh copies, taken **before** any send. A **null flat part copies to null**, and the payload reference is shared to every output (pre-made decision, unchanged in substance). |
| Tee placement / registration | `src/main` + `@Reflect` (KSP main-source-set rule); archetype in job-worker.yaml; ribbon tool in job-js.yaml. |
| Palette-insert default for `outputs` | **`outputs: []` body default is load-bearing** — the list analogue of the appendix's empty-string gotcha. Without it a palette-inserted `is: TeeWorker` has a *missing* attribute → `StructuralAttributeDefiner` fails ("Unknown attribute") → the Worker silently drops from the graph. With `[]`, definition succeeds and the creator returns an empty endpoint list. |
| Empty `outputs` at run time | Valid: the tee drains its input and forwards to nobody (drop). Mid-edit-tolerant, documented in the kdoc. Not a definition error. |
| Dangling list element | No reclaim possible (F6): compile-time pre-check in `JobLogicCompiler` with a message naming worker/port/index; client list editor renders the entry flagged + removable. |
| Duplicate list elements (same channel twice) | Allowed; each is its own producer endpoint and (for flat-bearing messages) delivers an independent copy. Pinned by the close-counting e2e test. |
| Migration across both branches | Generic already (F7); pinned by the step-4 migration test, no product code. |
| Per-output `channels.<port>` knobs on the tee | **Do not apply.** That map only feeds *synthesis* of auto channels (JobChannelSynthesis.kt:119-129); list ports are manual-only, so batchSize/capacity are set on each manual Channel object itself (its own attributes). Note in the archetype comment. |
| Deadlock fixture validity vs J7 | No serve/external channels in any J6 fixture ⇒ monitor armed under both pre- and post-J7 behaviour (see Dependencies). |
| Where chips derive from | New pure `JobManualWires` in commonMain beside `JobChannelDerivation` — reads the identical notation surface (`JobChannelPorts` types + `firstAttribute` + `coalesce.locateOptional`), no new wire format, usable by server too if ever needed. |

## Step-by-step implementation

### Step 1 — wiring layer: list-typed channel ports (common + jvm)

**1a. `JobChannelPorts` (commonMain, JobChannelPorts.kt)** — add:

```kotlin
// The endpoint Kind of a List-typed channel-port attribute's ELEMENTS (metadata `is: List,
// of: <endpoint>`), or null when the attribute is not a list of channel endpoints. Deliberately
// separate from kindOf: a list port is never auto-wired (derivation) and never hidden as an
// order-managed port (the card renders its editor), so kindOf stays null for List.
fun listElementKindOf(type: TypeMetadata?): Kind? {
    type ?: return null
    if (type.className != ClassNames.kotlinList) { return null }
    val element = type.generics.getOrNull(0) ?: return null
    return Kind.ofClassName(element.className.asString())
}
```

(Import `ClassNames`; also add `fun isListChannelPort(type) = listElementKindOf(type) != null` for
the client call sites.) **No change to `kindOf`/`isChannelPort`** — that immutability is what keeps
`JobChannelDerivation` (auto-wire) and `WorkerDisplayDefault`'s scalar-port hiding untouched.
Update the class kdoc (the "single source of truth" contract now covers list ports; note
ChannelTypeDefiner's hot-loop constants copy, which 1c extends in kind).

**1b. `JobChannelCreator` (JobChannelCreator.kt)** — generalize `create`:

- Factor the current scalar body (lines 78-111) into
  `createEndpoint(kindClassName, elementDefinition: ReferenceAttributeDefinition, …): Any?`
  keeping every existing message byte-identical for the scalar path.
- Add the list case: when the attribute's metadata type is `List` (use
  `JobChannelPorts.listElementKindOf` on the metadata type; the endpoint class name is
  `type.generics[0].className`), expect `attributeDefinition as? ListAttributeDefinition` (else
  throw naming the attribute) and return
  `definition.values.mapIndexed { i, elem -> createEndpoint(…, elem as? ReferenceAttributeDefinition
  ?: throw …"$attributeName[$i]"…) }` — a `List<Any?>` of endpoint views, one **fresh
  `newProducer()` / `newClient()` per element** (per-element dispatch on the element kind, so a
  hypothetical `List<ChannelInput>` merge worker also works uniformly; no kind is special-cased).
  Empty list → `emptyList<Any?>()`.
- All four error messages for list elements carry the `[index]` suffix.
- Kdoc: extend the dispatch table with the list row; note close-on-last-producer counts each list
  element as an endpoint (JobChannel.kt:78-90).

**1c. `ChannelTypeDefiner` (ChannelTypeDefiner.kt)** — extend the port scan (lines 131-159):

- Keep the scalar branch verbatim. Add, per attribute: if the metadata type is a list-of-endpoint
  (companion gains `kotlin.collections.List` detection mirroring 1a — the class keeps its own
  constants per its kdoc), read the port notation as `ListAttributeNotation` and iterate elements
  with index: skip blank scalars; `locateOptional` each; if it resolves to `objectLocation` (this
  channel), add a `PortRef` labelled `"${worker}.${port}[$index]"` with
  `elementType = portType.generics[0].generics.getOrNull(0)`, classified consumer/producer by the
  *element* kind.
- No change to `compatible` (192-197), the mismatch message (185-189), or the single-reader check
  (173-177) — list-element consumers naturally count toward single-reader; list-element producers
  naturally join fan-in.
- Kdoc: one sentence on list ports ("each list element is an independent port; a single
  type-mismatched element fails the channel exactly like a scalar port").

**1d. Dangling-port compile pre-check (`JobLogicCompiler.kt`)** — after synthesis, before
`filterTransitive` (line 41): walk the document's workers' channel-port attributes in the
**augmented** notation (scalar ports post-synthesis are either filled or manual-valid; any remaining
non-blank scalar or list element that does not `locateOptional` to an existing object) → throw
`IllegalArgumentException` naming worker, port, index (if list), and the missing reference — e.g.
`"Tee.outputs[1] references missing channel: main.channels/branchB"` — instead of
`transitiveClosure`'s opaque `"Missing …"` (F6). Implement as a small private function
(`validatePortReferences(augmentedNotation, documentPath)`) reading via `JobChannelPorts` only —
no worker-type knowledge. (This also upgrades the pre-existing unpaired-dangling-scalar crash for
free; keep the check O(document).)

### Step 2 — `TeeWorker`

**2a. Class** — `kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/TeeWorker.kt`
(`src/main` — KSP/`@Reflect` rule):

```kotlin
@Reflect
class TeeWorker(
    private val input: ChannelInput<Any?>,
    private val outputs: List<ChannelOutput<Any?>>,
    selfLocation: ObjectLocation
): WorkerBase(selfLocation)
```

Extends `WorkerBase` directly (NOT `TransformWorker` — that base is one-output; the tee owns its
own drive loop, mirroring TransformWorker.kt:45-72's contract):

- `drive(control)`: `try { while (true) { control.checkpoint(); val batch =
  input.receiveBatch() ?: break; for (element in batch) { forward(element) }; outputs.forEach {
  it.flush() }; publish(control) } } finally { outputs.forEach { it.close() } }`.
  Checkpoint at the top with all outputs flushed and the previous batch fully consumed — the same
  strands-nothing invariant as TransformWorker (one step ≈ one input batch; a parked tee holds no
  element; a park mid-`flush` is captured per-producer by `drainBuffered`'s `inFlight` handling,
  JobChannel.kt:130-158).
- `forward(element)`: if `outputs.isEmpty()` return (drain-and-drop, documented). If
  **make the `n-1` copies first** — `JobMessage(element.payload, element.flat?.let {
  FlatView(it.header, it.record.prototype()) })` (F2; header shared by reference, payload shared by
  reference) — then `outputs[0].send(element)` (original, ownership transferred) and
  `outputs[i].send(copy_i)` for the rest. Any other element: `send(element)` to every output
  (by-reference — pre-made decision; kdoc documents that a mutable non-record element shared across
  branches is the composer's responsibility).
- Progress: count forwarded input elements; `progress(snapshot)` returns
  `mapOf(JobConventions.progressCountKey to count)` (the generic card renders `count=` rows;
  no new display component — `display: WorkerDisplayDefault` inherited from the `Worker` base,
  common-job.yaml:14).
- Migration: **no override** — the tee is stateless (`captureMigrationState` default null =
  restart-clean, WorkerBase.kt:98-102); in-flight elements live in the channels, which `JobRun`
  carries generically (F7). State this in the kdoc and pin with the step-4 test.
- Kdoc: the fan-out contract (single-reader preserved — fan-out is N channels, not N readers of
  one), deep-copy rationale (FormulaWorker's in-place mutation, F2), copy mechanism
  (`prototype()`, NOT the shallow `clone`), empty-outputs semantics, duplicate-outputs semantics.

**2b. Notation** — `job-worker.yaml` (append, alongside the other transforms):

```yaml
# Fan-out stage: forwards EVERY incoming element to EVERY output channel, preserving the
# single-reader rule (fan-out = one channel per branch, never a shared-drain channel). Each message's
# FLAT PART is DEEP-COPIED per extra output (FlatFileRecord.prototype; the shared header
# rides by reference) so a branch that mutates records in place (e.g. Formula) cannot corrupt its
# siblings; other element types pass by reference. `outputs` is a LIST of manual Channel
# references — list ports are never auto-wired; the branches' consuming Workers reference the same
# Channels in their input ports. The `outputs: []` body default is LOAD-BEARING (palette insert):
# without it the attribute is missing rather than empty and the Worker drops from the graph.
# NB: per-output `channels.<port>` knobs do NOT apply to list ports (that map only feeds
# auto-channel synthesis) — set batchSize/capacity on each referenced Channel object itself.
TeeWorker:
  abstract: true
  is: Worker
  title: "Tee"
  class: tech.kzen.auto.server.objects.job.worker.TeeWorker
  input: ""
  outputs: []
  meta:
    input:
      is: ChannelInput
      creator: JobChannelCreator
      editor: SelectChannelEditor
    outputs:
      is: List
      of: ChannelOutput
      creator: JobChannelCreator
      editor: SelectChannelEditor
    selfLocation:
      is: ObjectLocation
      by: Self
```

Untyped ports (no `of:` under `ChannelInput` / the list's `ChannelOutput`): the tee is
element-agnostic (the flat-part copy is a null check on `element.flat`, **no type test** — every
element is a `JobMessage`), and `compatible` treats the absent generic as a wildcard. A third party
wanting a *typed* tee declares the nested-map `of:` form (F5). — Also `job-js.yaml`: add
`TeeTool: {is: RibbonTool, parent: JobGroup_Transforms, delegate: TeeWorker}`.
Appendix-gotcha check: no `title:`-style additions to `Channel`/`DuplexChannel` archetypes are made
by this phase (they stay untouched).

**2c. Migration carryover across both branches** — no product code (F7); test-only (step 4).

### Step 3 — client: list-port editor + manual-connection chips

**3a. `SelectChannelEditor` list mode** (SelectChannelEditor.kt; registered job-js.yaml:69-71,
dispatched per attribute by `AttributeEditorManager` via `editor:` metadata —
AttributeEditorManager.kt:72-100):

- Detect mode from attribute metadata (via `props.clientStateGlobal` graph metadata):
  `JobChannelPorts.isListChannelPort(type)` → list mode; else today's scalar mode unchanged.
- List-mode state: `values: List<String>` (the current element references, read from the
  inheritance-resolved `ListAttributeNotation`; blank archetype default `[]` reads as empty).
- Render: one row per element — the existing `muiAutocompleteField` over the same
  `channelOptions` (one-way Channels of this document) + a remove IconButton; a trailing "add
  output" row (autocomplete that appends on select). An element whose reference no longer resolves
  (dangling, F6) renders its raw string flagged (error styling + tooltip "channel no longer
  exists — remove") and remains removable.
- Write: rewrite the whole list via
  `UpsertAttributeCommand(objectLocation, attributeName, ListAttributeNotation(values.map {
  ScalarAttributeNotation(it) }))` — the `MultiFileInputEditor.applyPaths` precedent (F8): robust
  for inherited-only vs materialized lists, trivial reorder later.
- AE5 adaptation note as in Dependencies.

**3b. Manual-connection chips** — new pure helper + generic card row:

- **`JobManualWires`** (new, commonMain
  `tech/kzen/auto/common/objects/document/job/JobManualWires.kt`, beside `JobChannelDerivation`):
  `data class Wire(worker: ObjectLocation, port: AttributeName, kind: JobChannelPorts.Kind,
  listIndex: Int?, channel: ObjectLocation)`;
  `fun derive(graphStructure, jobDocumentPath): List<Wire>` — for each worker under `workers`
  (same `directNestedObjectPaths` walk as JobChannelDerivation.kt:74-79), for each metadata
  attribute: scalar endpoint kind (`kindOf`) with a non-blank value that `locateOptional`-resolves
  to an existing object → Wire; list-of-endpoint (`listElementKindOf`) → one Wire per resolving
  non-blank element with its index. This is by construction the complement of `isOpenPort` over the
  identical notation surface — "derived from the same notation the derivation reads", no new wire
  format. Kdoc cross-links the two so they cannot drift silently.
- **`WorkerDisplayDefault`**: compute this worker's wires + per-channel peer names in
  `onClientState` (it already observes `ClientStateGlobal` for metadata,
  WorkerDisplayDefault.kt:108-124) into a small value type held in state behind a `==` guard
  (render-scoping conventions). Render a chips row between the header and the attribute editors:
  per wire, a compact gold-palette chip (`JobChannelDisplayStyle` colors, JobChannelDisplay.kt:27-41
  — one visual language for channels) — producer: `port → channelLeaf`, consumer:
  `channelLeaf → port`, list elements suffixed `[i]`; tooltip lists the peer workers on that
  channel ("also: Explore.input"). Chips are read-only labels (the editors below / step 3c edit).
  No Worker-type knowledge — driven purely by port metadata types.
- Per-type displays (Preview/Explore/Summary) inherit the row automatically (they wrap
  WorkerDisplayDefault via `bodyExtra`).

**3c. Scalar-port wiring affordance** — **the one elaboration beyond the constituent text**
(flagged; small): `WorkerDisplayDefault.renderAttributeEditors` currently hides all scalar channel
ports (F4), which would leave tee *branches* un-wirable in the UI. Change the skip rule to:
hide a scalar **one-way** port (`Kind.Input`/`Output`) only while the document declares **no**
manual one-way Channel objects (`directNestedObjectPaths(main, channels)` filtered to non-duplex —
reuse `JobConventions.isChannelArchetype` semantics via the object's `is:`); once the user has
inserted a Channel (the explicit "going non-linear" opt-in, already in the ribbon), each one-way
scalar port renders its `SelectChannelEditor` with a **"(auto)" option prepended** (value `""`,
writes a blank `ScalarAttributeNotation` → the port is open again and the order rule owns it —
`isOpenPort` semantics unchanged). Duplex ports (`Server`/`Client`) stay hidden always
(worker-to-worker duplex remains manual-and-documented per the pre-made decision; serve stays
auto-managed). A channel-free document is pixel-identical to today, and blank ports still auto-wire
— "auto-wire behaviour unchanged" holds.

**3d. Auto-wire pipes / gaps / `JobController`** — untouched. (List ports are invisible to
`JobChannelDerivation` by 1a's design; the pipe rendering keys off `connectionsByUpstream` only.)

### Step 4 — deadlock sanity + the test net

Product code: **none** (the monitor and `JobRun` are already generic — F1/F7). This step is
fixtures + tests; see Tests. The single behavioural assertion to design for: in
reader → tee → {drained branch, orphan branch}, backpressure freezes the whole pipeline into
channel-blocks (reader parked on `send` into the tee's input channel, tee parked mid-`flush` on the
orphan branch, branch sink parked on `receiveBatch`) → `blocked == active` sustained → verdict
(JobDeadlockMonitor.kt:85-113). Manual channels are in `streamChannels`, so their `blockedCount` is
already summed (JobRun.kt:106-117, 158-171).

## Tests

New fixtures under `kzen-auto-jvm/src/test/resources/notation/test/` (never under any
`notation/main/`); new/revived test classes under `kzen-auto-jvm/src/test/kotlin/`.

**T1. `JobChannelTypingTest` (revived — F3)** at
`tech/kzen/auto/server/objects/job/JobChannelTypingTest.kt`, definition-level only
(`AutoTestUtils.graphDefinitionAttempt`, no engine):
- `producerTypeMismatchFailsDefinition` / `multipleConsumersFailDefinition` — re-adopt the deleted
  assertions over the two existing orphaned fixtures (failure keyed on the channel location,
  `attributeErrors[elementType]` containing "carries" / "single-reader"). Update the fixtures' stale
  "RecordBatch" comments while there.
- **`listElementTypeMismatchFailsDefinition` (the spec'd concrete test)** — new fixture
  `job-tee-list-mismatch-test.yaml`: a `String`-typed channel (`elementType: {class: kotlin.String}`)
  referenced by a **typed** list port (a test-only archetype declaring
  `outputs: {is: List, of: {is: ChannelOutput, of: <PayloadType>}}` inline in the fixture — also pins
  F5's nested-`of:` metadata form) with two elements, one pointing at a compatible channel and one at
  the String channel. Assert: the String channel fails definition, error contains `outputs[` and
  "carries"; the compatible channel defines successfully (one bad element poisons only the channel it
  mis-feeds).
- `listElementConsumerCountsTowardSingleReader` — a `List`-of-`ChannelInput` element plus a scalar
  `input` draining the same channel → single-reader failure naming both labels.

**T2. `JobTeeTest` (new)** at `tech/kzen/auto/server/exec/job/JobTeeTest.kt`, engine harness per
F9:
- `teeForwardsToAllBranches` — fixture `job-tee-linear-test.yaml`: `CsvReaderWorker` → tee →
  manual channels `branchA`/`branchB` → two `CsvWriterWorker`s. `Outcome.Success`; both output
  files contain every input row; doubles as the healthy-tee no-false-deadlock-verdict case.
- `teeDeepCopyIsolatesBranchMutation` — fixture `job-tee-formula-test.yaml`: reader → tee →
  {branchA: `FormulaWorker` (appends a column, mutating records in place — F2) → writer A;
  branchB: writer B}. Assert writer B's file has exactly the original header/columns and writer A's
  has the appended column. Deterministic proof of the `prototype()` copy (without it this is a
  data race; with it branch B provably never sees the mutation). Order the tee's outputs so the
  **original** goes to the Formula branch — proving the copies, not the original, feed the others.
- `duplicateOutputsCountAsDistinctProducers` — fixture `job-tee-duplicate-test.yaml`: source →
  tee with `outputs: [chan, chan]` → one counting sink on `chan` (reuse
  `GatedCountingSinkWorker` ungated + `GatedSourceWorker`, registered via
  `GatedWorkerTestModule.register()` — F9). Assert the sink receives exactly `2 × total` and the
  run **completes** (EOF only after both endpoints close — close-on-last-producer counts each list
  element; a single shared endpoint would either under-count or hang).
- `teeMigrationCarriesBothBranches` — fixture `job-tee-migration-test.yaml`:
  `GatedSourceWorker` → tee → two small-capacity manual channels → two counting sinks.
  Drive with `step()`/`awaitQuiescent()` until elements sit buffered in both branch channels
  (JobMigrationTest.kt:98-105 pattern), edit a non-reader attribute (e.g. a sink's `note`),
  `migrate(editedLogic, paused = false)`, `await()`. Assert both sinks' totals `== sourceTotal`
  exactly (drop ⇒ shortfall, replay ⇒ overshoot — the JobMigrationTest exactness idiom). Pins F7
  with no fixture serve-channel trick (per the J7 note: **no external channels**; gated workers park
  on latches, which the monitor ignores — blocked < active).
- `teeOrphanBranchDeadlocks` **(the spec'd stalled-branch monitor test)** — fixture
  `job-tee-deadlock-test.yaml`: reader (real CSV, enough rows to overrun capacities) → tee →
  {`branchA` → CsvWriter sink; `branchB` **with no consumer** (the stalled branch)} — all
  channels small fixed capacity, batchSize 1. No serve/external channels anywhere. Assert
  `Outcome.Failed` with a message containing "deadlock" (JobDeadlockTest.kt:72-77 idiom).
  **J7 statement:** this test assumes only that the monitor is armed when no external channel
  exists — true today (blanket suppression doesn't trigger) and true after J7 (suppression removed)
  — valid both before and after.

**T3. Creator/derivation micro-coverage** (can live inside T1/T2 files): palette-shape fixture —
a document with `is: TeeWorker` and NO body `outputs` of its own (inheriting `[]`) defines
successfully and derivation still auto-wires reader→tee input while leaving the gap below the tee
unpaired (auto-wire unchanged; asserts on `JobChannelDerivation.derive` directly, it is pure).

**Client:** no JS unit harness for these editors exists; client verification is the manual pass
below plus the JS compile.

## Verification

1. `./gradlew :kzen-auto-jvm:test` — full jvm suite: the new T1–T3 plus the existing
   `exec/job` + `objects/job` safety net (JobNotationTest, JobMigrationTest, JobDeadlockTest,
   JobChannelDefaultTest, channel/worker suites) all green. No existing test may need edits —
   if one does, that is a regression in this phase's changes (the scalar paths must be
   byte-compatible).
2. `./gradlew build` — KSP regenerates `KzenAutoJvmModule` with the TeeWorker entry; JS compiles.
3. **Manual render check (Sample Job with a tee)** — `./gradlew
   :kzen-auto-jvm:frontendDevelopment -PjsWatch`, then in the browser **create a NEW Job document**
   (do NOT edit the user's existing `notation/main/Job*.yaml` working documents — file-safety rule):
   - Insert CSV Reader, Tee, Explore, Export from the ribbon; two Channels from the Channels group.
   - Tee card shows the `outputs` list editor: add both channels (rows appear; notation saves).
   - Explore/Export cards now render their `input` selectors (3c gate: manual channels exist);
     wire one branch each; chips appear on the tee AND on each branch card, peers in tooltips.
   - Reader→Tee gap still shows the auto gold pipe; gaps below the tee show none (auto-wire
     unchanged); drag/reorder and ribbon insert still behave.
   - Run: both branches fill (Explore browsable, Export file written); pause/edit/resume mid-run
     keeps both branch counts exact; delete one Channel → the tee row flags dangling, run start
     reports the 1d message naming `outputs[i]`.
4. Stage the new files per the git-hygiene rule (`git add` each new path explicitly; never commit).

## Risks & gotchas

- **`FlatFileRecord.clone` is a trap** (F2): shallow array adoption. The Tee must call
  `prototype()`. A reviewer seeing the constituent plan's "via FlatFileRecord.clone" text must not
  "correct" the code back to `clone`.
- **`outputs: []` body default is load-bearing** (palette insert — missing ≠ empty; the appendix
  gotcha in list form). Covered by T3.
- **Do not touch `Channel` / `DuplexChannel` archetypes** (no `title:`/inherited-definer
  attributes — the silent drop-every-channel failure; appendix gotcha). This phase adds nothing to
  them.
- **`kindOf` must keep returning null for `List`** — 1a adds a *separate* classifier. Folding list
  detection into `kindOf` would (a) make derivation treat the tee as having open outputs and
  perturb auto-wire, (b) hide the `outputs` editor via `WorkerDisplayDefault`'s port skip.
- **Copy-before-first-send in `forward`**: take the `n-1` prototypes before handing the original to
  `outputs[0].send` — after that call the tee no longer owns the element (send only buffers, but
  the ownership contract is the discipline that keeps this code safe under refactors).
- **Tee checkpoint placement**: exactly one `checkpoint()` per input batch at the top of the loop
  with all outputs flushed (the one-step ≈ one-batch contract; a mid-loop checkpoint would strand
  buffered output at a pause wavefront and break `drainBuffered`'s "pending provably empty"
  invariant, JobChannel.kt:38-40).
- **Deadlock fixture tuning**: capacities must be small and the input long enough that the orphan
  branch's backpressure reaches the reader; batchSize 1 makes the arithmetic exact (the
  carryover fixture's comment, job-migration-carryover-test.yaml:55-57, is the model). The 4×50 ms
  grace means the verdict needs a sustained stall — never assert on timing, only on the terminal
  `Outcome.Failed`.
- **Test workers have no KSP** (F9): any new test-only Worker needs hand-written
  `ModuleReflection` registration — prefer reusing `GatedSourceWorker`/`GatedCountingSinkWorker`.
  Production `TeeWorker` must live in `src/main` for `@Reflect`.
- **`ChannelTypeDefiner` scans the whole graph** (ChannelTypeDefiner.kt:127) — a known J8 hygiene
  item (scope to the document); replicate the current shape for the list branch, do not fix here
  (keeps this phase's diff reviewable and leaves J8's item intact).
- **Per-output `channels.<port>` knobs don't reach manual channels** — tee branch tuning happens on
  the Channel objects; the archetype comment (2b) forestalls the support question.
- **Deep copy is per-extra-output per-record** — the deliberate, measured-later cost (pre-made
  decision: correctness first; J5's benchmark harness is the follow-up venue if tee throughput
  matters).
- **3c's un-hiding gate**: keyed strictly on "document declares ≥ 1 manual one-way Channel" so the
  default linear UX is untouched; regression-watch the empty-Job and plain-linear-Job renders in
  the manual pass.

## Out of scope (decided — do not re-open)

- Multi-reader channels; any weakening of single-reader (fan-out is the Tee).
- A 2D node-and-edge canvas (ordered-card legibility only; canvas only if branching becomes common).
- Auto-wiring list ports / extending the order rule to branches (list ports are manual-only).
- Duplex (`DuplexChannel`) type-checking (ChannelTypeDefiner.kt:48-49 note stands; J8 decides) and
  any UI for worker-to-worker duplex wiring.
- Deadlock-monitor precision work (removing `externallyServing`, serve-scenario tests) — **J7**.
- `JobServeChannelResolver` de-hardcode, derivation memoization, defaults-from-notation,
  definer scan scoping — **J8**.
- Tee performance (copy cost measurement, arena/pooling) — **J5**'s benchmark-first pipeline.
- Typed-channel subtyping/variance (exact-match + `Any` stands until a real plugin hits it).
- `SelectReferenceEditorBase` migration of the channel editors — **AE5** (only the adaptation note
  here).
