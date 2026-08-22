# DS7 — writers yield a `DataRef`; `ResultSinkWorker keep: all` — implementation plan

> **Status: ready to execute.** Session 7 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§7.1** (data flows out as well as in; the worked outer/inner shape), O2 (`keep: all`), §8.1 (the
> resolved manifest as run record), §3.3 (why the yielded ref survives a rename **and** a restart).
> Constituent plan: **—** (analysis doc is the record; delete on landing, as-built → analysis **§14**).
> Depends on **DS1, DS3, DS5**. Anchors verified 2026-08-21. **Revised 2026-08-21b** by the second-pass
> review (§13 C7, C9). Sized **M**; kzen-auto-jvm + yaml. Ledger row 57. This closes the composition
> loop: "invoke a Job for a specific input, then take the output file".

## Scope & goal

1. **Writers yield what they wrote.** `ExportWriterWorker` (and `CsvWriterWorker`) gain an optional
   `result: <component name>` — blank = yield nothing (today's behaviour); set = at `onComplete`, yield a
   `DataRef` (one container) or a `DataUnit` (several containers under a grouping, one part per
   container, group attributes on the unit) **into the Job's declared `results` component** via
   `JobControl.yieldResult` — the `ResultSinkWorker` contract, so `JobSignatureCapability`'s
   `results` map is still the single signature source.
2. **`ResultSinkWorker keep: all`** (O2) — collect every element into a `List` result in addition to
   `first` / `last`; the constant-memory claim no longer holds for `all`, which the KDoc states.
3. **Published manifest** — `ReadWorker` (DS3) publishes the resolved manifest into its trace at
   resolve time (one event, the lowered `DataManifest`) so a run records what it actually read (§8.1
   observability / reproducibility). Small, and it belongs with "data out".
4. **End-to-end acceptance**: the §7.1 worked shape as a notation fixture — outer Job resolves units,
   `RunWorker` hosts a per-unit child Job that reads, transforms, writes and yields its `DataRef`; the
   outer `ResultSinkWorker(keep: all)` collects one ref per unit.

## Dependencies & coordination

- **DS5 landed** (`ExpandWorker`, `items(...)` helpers, objects in scope) — the child Job reads
  `items(unit.part("main"))`. DS3's `ReadWorker` is used for the simpler variant and owns item 3.
- **DS1's `DataSourceId` is what makes this session's output durable.** A yielded `DataRef` is
  persisted — it is a run result a caller may store and feed to another Job days later. With the
  previous draft's `ObjectStableId` it would have resolved only until the process restarted after a
  rename (§3.3, C9). Nothing extra to build here; just do not reintroduce a location or a stable id.
- **J4 (`groupBy` on `ExportWriterWorker`)** is the sibling change on the same worker: if J4 lands
  first, the grouped case yields a `DataUnit` whose parts map 1:1 to J4's groups; if this lands first,
  J4 adds the grouping and the yield already knows how to describe several containers. Coordinate in
  the as-built — **same file, sequence them, don't interleave**.
- **J9 (file-backed carry-forward)** — a writer that migrates mid-run must still yield the right ref(s)
  at completion; the yield happens at `onComplete` on the *final* instance, so no new migration state.
- **`ExecutionValue` lowering** (DS1) is what lets the yielded `DataRef` cross the Logic boundary as a
  typed result (`TypeAssignability` probes declared vs inferred — declare the component `DataRef`).
  ⚠ It must also **type** as one: `DataRef` reaches a lane's `payloadType` through
  `ExpressionReturnTypeInference`, so **DS1b** is what stops it flattening to `Any` in the declared-vs-
  inferred check.

## Current-state findings (anchors verified 2026-08-21)

- **Results plumbing**: `JobControl.yieldResult(component, value)`; `JobResultCollector` gathers yields
  per run (last-write-wins) into the `TupleValue` the run returns; `ResultSinkWorker` (`keep: first|last`,
  `result: String` blank = main) validates the declared component in `payloadFlow`
  (`JobSignatureCapability.isResultSink` — a marker in the inheritance chain, capability-based).
  `results: {}` on the `Job` archetype (`common-document.yaml`); `ResultSignatureDefiner.parse`.
- **Writers**: `ExportWriterWorker` writes to a path attribute (`DataLocationGroup.empty` pinned today —
  J4's seam), `CsvWriterWorker` a plain path; neither yields. `WorkerFilePath` resolves paths.
- **`RunWorker`** binds the incoming element to the child's first parameter and emits the child's
  **main** result as a payload (`result.mainComponentValue()`).
- **Trace**: `LogicParameterTrace.emitAll` and the worker progress path (`JobConventions.workerProgressPath`)
  are the two existing per-run record channels; the manifest goes on the worker's trace as one event
  (not progress — progress is a rolling teaser, capped at `progressTeaserRowCount`).
- **Tests**: `ResultSinkWorkerTest`, `ExportWriterWorkerTest`, `JobRunWorkerTest`, `JobSignatureTest`,
  `notation/test/job/run/` + `signature/` fixtures.

## Pre-resolved questions

1. **Yield shape** — one container → `DataRef(source = null, id = path, attributes = {})` (a plain
   path: O4, first-class); several → `DataUnit(attributes = group attributes, parts = one `main` part
   per container, ordered as written)`. The writer knows which at `onComplete`.
2. **Yield target** — the Job's declared `results` component named by the writer's `result:` attribute
   (blank = no yield). The writer is thereby a *second kind of sink* without becoming a `ResultSink`
   archetype; `JobSignatureCapability.isResultSink` stays a marker check — add a second marker
   `ResultYielder` to the chain of writers that can yield, so the validator can check the declared
   component for both kinds without naming either class (CC-17).
3. **`keep: all`** — a `List<Any?>`; `payloadFlow` publishes `List<elementType>`. Memory is unbounded by
   construction; the KDoc and the `values:` dropdown label say so ("All (keeps every element in memory)").
4. **Manifest on the trace** — `ReadWorker` emits the lowered `DataManifest` once, at resolve, on its
   own node, capped to a teaser if very large (count + first N units), **full digest always**. That
   digest is `DataManifest`'s one surviving consumer: the resume guard it was originally built for was
   retired when the reader started carrying its manifest instead of re-resolving (§8.1, C7). Say so in
   the KDoc so nobody "restores" a comparison that no longer has a counterpart.
5. **Why the ref is a plain path** — a written file is not a `DataSource`; do not mint an id for it. A
   later "outputs are readable as a source" feature is a *source's* job (DS8's `LogicDataSource` can
   resolve a written path trivially), not the writer's.

## Step-by-step implementation

1. `ResultSinkWorker keep: all` + `values:` entry + `payloadFlow` type + tests.
2. Writer yield: `result:` attribute on `ExportWriterWorker` / `CsvWriterWorker` (+ meta), `onComplete`
   yields per Pre-resolved 1; `ResultYielder` marker archetype in `common-job.yaml` and the validator's
   declared-component check extended to it (one function, two markers).
3. `ReadWorker` manifest trace event.
4. Fixture `notation/test/job/run/job-per-unit-test.yaml` (+ the child Job document): the §7.1 shape
   with a `FileDataSource` over three files; outer `ResultSinkWorker(keep: all, result: outputs)`;
   declared `results: {outputs: List<DataRef>}` on the outer, `{output: DataRef}` on the child.

## Tests

1. **`ResultSinkWorkerTest`** — `keep: all` collects in order; `first`/`last` unchanged; type published.
2. **`ExportWriterWorkerTest` / new `CsvWriterWorkerTest`** — with `result` set, the yielded value is a
   `DataRef` whose `id` is the written path and whose `source` is **null**; with grouping (if J4 present)
   a `DataUnit`; blank `result` yields nothing; declared-component mismatch is a validation error
   (`JobValidatorTest`).
3. **`JobPerUnitNotationTest`** (jvm, engine-level) — the fixture runs to `Outcome.Success`; the outer
   run's `outputs` result lowers to three `DataRef`s, each pointing at an existing file whose content
   equals the per-day transform of its input; the child's trace shows three runs.
4. **`ReadWorkerTest`** addition — the manifest trace event is emitted once, carries the resolved digest,
   and is teased (not truncated silently) for a large manifest.
5. **Durability regression** — a yielded `DataRef` for a *sourced* input unit (not the written output)
   round-trips through `ExecutionValue` and still resolves via `DataSourceResolver` after the source
   object is **renamed**. This is the C9 pin, and it belongs here because this is the session that first
   persists a ref outside a run.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test` — the above + `exec/job` + `objects/job` nets.
2. Headless: run the fixture's outer Job through the logic REST route and read the result tuple back
   (JSON) — three refs.
3. As-built → analysis **§14**; tick row 57; delete this file.

## Risks & gotchas

- **`last-write-wins` in `JobResultCollector`** — a writer yielding the same component as a
  `ResultSinkWorker` is a conflict the validator must flag (two yielders, one component).
- **`RunWorker` emits the child's *main* result** — the child must declare its yielded ref as `main`
  (or the outer must read a named component — not supported by `RunWorker` today; keep to `main` and
  record the limitation).
- **Paths are plain refs** — do not mint a `DataSourceId` for a written file (Pre-resolved 5).
- **Do not restore a manifest-digest resume guard.** It has no counterpart since the reader carries its
  manifest (C7); the digest here is a *record*, not a comparison.
- **`DataRef` must type as `DataRef`** on the boundary check — that needs DS1b (§5.5a). If the declared-
  vs-inferred check passes suspiciously easily, confirm it is not passing because both sides are `Any`.

## Out of scope (this session)

- `groupBy` on the writer (J4). Role fan-out + `LookupWorker` (demand-driven). A "Job outputs" browser.
- Making a written output readable as a source — DS8 territory, and only if a real pipeline asks.
