# Job data sources — review of the design and the DS plans

**Date:** 2026-08-23 · **Status:** findings, **not applied.** The design record is
[`2026-08-20_job-data-source.md`](./2026-08-20_job-data-source.md) and the execution layer is
`docs/plans/next/DS0`–`DS8`; both currently describe the design *as planned*, and everything below is a
change I think should be made to them. Each finding states what breaks or what it costs, the evidence in
the tree, and a recommendation. Claims were checked against `kzen-auto` at review time; per CC-20 no line
numbers are cited.

## Verdict

The design is coherent and the sequencing is sound. The core commitments — resolution and reading are
effects owned by workers, refs are plain paths until a provider needs otherwise, a plain pull cursor the
worker drives, the manifest carried rather than re-resolved, source and opener split — each *removed*
machinery rather than adding it, and none of them should be re-opened.

One finding below will actually fail as written (F1, the arc's own acceptance fixture). The rest are
places where the plans carry more surface than the design needs, and are worth taking before DS2 starts
because they are cheaper now than after there is code.

---

## F1 — the per-unit output path is unfunded, and the acceptance test depends on it

**Severity: blocking for DS7 and DS8.**

DS7's fixture and DS8's acceptance fixture both write per-unit output:

```
ExportWriterWorker(path: "out/${date}.csv", result: output)
CsvWriterWorker(path: "out/${date}.csv", result: output)
```

and then assert three distinct output files, one per day. Nothing produces that behaviour:

- `CsvWriterWorker` performs **no substitution at all** — `onStart` opens
  `Files.newBufferedWriter(toFilePath(path))` on the raw attribute string.
- `ExportWriterWorker` resolves `${…}` through `OutputExportSpec.resolvePattern`, whose vocabulary is
  `${report}` / `${group}` / `${time}` / `${extension}`. Its own KDoc records that `${group}` is **empty**
  for a Job export ("a Job export is a single stream → a single file"). `${date}` is not a placeholder it
  knows, so it survives into the filename literally.
- Both resolve the path in `onStart`, **before any record arrives** — so even if `${date}` were wired to a
  record column, the value would not exist yet.
- Nothing carries a unit attribute to a writer. `attributes: columns` (DS3) puts the attribute on the
  *records*, not anywhere the writer reads; the child Job's only parameter is `unit: DataUnit`; and
  `JobControl.host(instructions, input)` binds `input` as the child's **first declared parameter**, so
  `RunWorker` cannot pass a second one.

As written, the three child runs all write one file and DS8 test 5 fails. Since DS8 test 5 is the arc's
acceptance test — it is what proves DS1 through DS7 compose — this is not a fixture detail.

**Recommendation.** Fund it as one mechanism rather than a fixture workaround: give `RunWorker` an
`arguments:` mapping (unit attributes → named child parameters) built on the **named
`host(instructions, arguments: TupleValue)` overload DS8 already adds**, and let path substitution resolve
`${name}` against `control.parameter(name)`. The child then declares `date: String`, the overload earns
its keep twice, and per-unit output — which any ETL port wants — becomes a first-class capability instead
of an accident of the fixture. Alternative if that is too much: defer per-unit paths, have the child write
to one path and the outer collect refs, and say so in §7.1 — but that weakens the worked shape the design
is built around. Either way, decide it at the top of DS7, not inside it.

## F2 — `PathPatternSubstitution` duplicates a shipped helper

DS8 step 3 plans "one `PathPatternSubstitution` in commonMain, used by the writers and available to a
source". `OutputExportSpec.resolvePattern` already **is** that helper: it lives in commonMain, it does
`${…}` replacement over a fixed vocabulary, and `ExportWriterWorker` already calls it through
`resolvePath`. Writing a second one is a straight CC-12 duplication, and it would leave two substitution
dialects on two writers.

**Recommendation.** Generalize the existing helper (it needs a wider vocabulary for F1 regardless) and
give it a neutral home — it currently sits in `common/objects/document/report/spec/output/`, which is the
same layering inversion §10 is already correcting. Do not write a new one.

## F3 — `staticShape` is on the wrong interface, and DS6 pays for it

`DataOpener.staticShape(role)` has no implementation that can answer it:

- `FileDataOpener.staticShape` returns null in DS2 and **still returns null in DS6** (its own Pre-resolved
  3 says so).
- The actual supply is a schema document declared on the **source** (§6.3).
- `DataOpenerLookup` dispatches on a **ref**, but the walk has no ref — so DS6 bolts on a second entry
  point with a different key, `DataOpenerLookup.staticShape(source, role)`, and spends a paragraph
  explaining that it consults the source when there is one and returns null otherwise.

So the walk-facing call is declared on the one participant that never answers it, and reached through a
lookup keyed on something the walk does not have.

**Recommendation.** Move `staticShape(role)` to `DataSource`. `ReadWorker` holds its source and asks it
directly; `ReadPartWorker` has no source and stays statically unknown — which DS6 already concedes as the
honest v1 answer. That removes one SPI member from `DataOpener`, the whole second lookup entry point, and
the asymmetry note. `DataOpener` is left with exactly what an opener does: `open` and `inspectShape`.

## F4 — `DataContext` ships two members nothing implements

Of the four members, two are inert for the entire arc:

- `contextValue(key)` returns null in `DesignDataContext` (DS2 Pre-resolved 3) and DS3 Pre-resolved 5
  explicitly permits shipping it as a null stub — "if it is more than a few lines, defer it with a `null`
  return". It cannot be more than a stub: **`JobControl` has no Context read**, so a real implementation
  means adding an accessor to `JobControl` for a feature no source in the arc uses.
- `host(...)` throws in `DesignDataContext` and throws in `WorkerDataContext` until DS8 wires it.

**Recommendation.** v1 `DataContext` is `argument(name)` + `blocking(block)`. `host` lands in DS8 with its
only caller; `contextValue` lands with the first stateful source, together with the `JobControl` accessor
it needs. This is safe to defer precisely because third parties *consume* `DataContext` rather than
implement it — the implementations are ours — so adding members later is source-compatible for every
`DataSource` / `DataOpener` author. Two fewer stubs, and the Context-borrow model (§4) is documented
rather than half-built.

## F5 — `mergeSchemas` is a cost knob wearing a semantics name

DS6 adds `mergeSchemas: strict | superset` to both readers and flips the default to `superset`. But the
stated reason for failing loudly (§5.3: `SummaryWorker` fixes its columns from the first record and
`CsvWriterWorker` writes the header from the first batch, so mixed headers lose data *silently*) is
exactly what superset fixes. Once superset exists, `strict` has no semantic user.

What `strict` actually buys is skipping **one bounded read per part at resolve time** — DS6's own
Pre-resolved 7 flags this as a real cost on a 100-file selection.

**Recommendation.** Either name it for what it is (a pre-scan cost switch) or drop it and always
normalize. This matters beyond tidiness because it is the fifth attribute on the card the design promises
as "three cards, no code": `source`, `emit`, `role`, `attributes`, `mergeSchemas`.

## F6 — DS2 carries a mechanical package move that belongs in DS0

DS0 already is the import-only session, with an explicit quality gate ("any file with a non-import hunk is
a mistake"). DS2's Step 3 moves the input plumbing (`FlatDataSource`, `ReportInputChain`,
`ReportHeaderReader`, `FileListingAction`, `ColumnListingAction`, `ReportDefinitionRepository`) to
`server/data/` — the same kind of change, bundled into a session that also lands the SPI, two
implementations, a cursor, a lookup, a detached action, notation, conventions and a spike.

**Recommendation.** Fold the pure move into DS0 and keep only the `FileListingAction.scanInfo`
blocking-core split in DS2 — that one is behaviour-adjacent and belongs with its consumer. DS2 is the
largest session in the arc and this is free relief with no design consequence.

## F7 — DS1b's registry escape hatch cannot be tested

DS1b keeps `ObjectRegistry` as a widening hatch for classes the `isNameable` predicate rejects as false
negatives. Its own test 6 concedes it cannot demonstrate one: *"a Java class whose `visibility` reflects
null, if one exists on the test classpath; otherwise a test double where the predicate is stubbed."*

A widening hatch with no reachable case is either evidence the predicate is right and the hatch is dead
code, or evidence the predicate is wrong. A stubbed-predicate test proves neither.

**Recommendation.** This is O17 and it is the user's call, so make the call rather than shipping the
ambiguity: if no real false negative can be produced, retire `ObjectRegistry` and its `ObjectRegistryScan`
threading in the same session that replaces the whitelist. If one can, test it for real and keep the
document. Either outcome is clean; carrying an untestable hatch is not.

## F8 — naming and a small dispatch smell

- **`DataShape.Object`.** It is the only name in the new vocabulary that is not self-describing, it reads
  badly beside `Any` in JVM code, and it invites confusion with `java.lang.Object` and Kotlin's `object`
  keyword. `Typed(type)` pairs naturally with `Tabular(header)`. Cheap now, annoying later.
- **`DataSourceActions` with an `action=` parameter** is a string-dispatched mini-router, with an
  unknown-action failure path to write and test. Two single-purpose detached objects would drop that
  branch entirely. Low stakes — the generic-action decision itself (a source carries no UI protocol) is
  right and should stand — but worth a moment before DS2 writes the dispatch.

---

## Checked and sound — do not re-open

These were verified against the tree and the reasoning holds:

- **The SPI is `suspend` because it must be.** `JobControl.runBlockingIo` and `JobControl.host` are both
  suspend; a non-suspend source method cannot reach either without `runBlocking` (holds an engine thread)
  or an outer wrap (which makes `blocking` identity and `host` unreachable).
- **The cursor is a plain pull reader.** `CsvRecordReader` is the shipped precedent and the KDoc says so.
  A `Sequence` doing I/O in `next()` runs on the fixed engine thread; a suspend `next()` would capture a
  context that is stale after a live-edit migrate.
- **Expressions never initiate source I/O.** Nothing in the tree lets an expression name a notation object
  (`CalculatedColumnEval.generate` emits column and parameter accessors only), and the effect has no owner
  for the handle, the position, cancellation or quiescence.
- **Plain refs, `DataSourceId` deferred.** A file needs no provider to be read, and nothing in the v1 arc
  exercises minting, the id→location scan, or duplicate validation.
- **The manifest is carried, not re-resolved**, with the guard on the source's definition digest.
- **Heterogeneous headers fail loudly in v1**, for the downstream reason rather than a reader reason.
- **Run-time instances come from the run graph, not `GraphInstanceCache`** — the cache filters by
  `serverAllowed` and the run does not, so they can disagree, and a cached instance is outside the run's
  frame where the Context borrow cannot reach it.
- **`ResultSinkWorker` keeps `first` / `last` today**, so `keep: all` really is new work (O2).
- **`DataUnit` will type as `Any` without DS1b** — `visibleBuiltins` is eleven entries and the shipped
  registry holds one, `kotlin.ranges.IntRange`.

## Disposition by plan

| Plan | Findings that touch it |
|---|---|
| DS0 | F6 — takes the input-plumbing move |
| DS1 | — |
| DS1b | F7 — decide O17 rather than shipping an untestable hatch |
| DS2 | F3 (SPI shape), F4 (`DataContext` members), F6 (drop Step 3), F8 (action dispatch) |
| DS3 | F5 (knob count), F8 (`DataShape.Object`) |
| DS4 | — |
| DS5 | F3 (static shape for a source-less reader becomes simply "unknown") |
| DS6 | F3 (no second lookup entry point), F5 (`mergeSchemas`) |
| DS7 | **F1** — settle the output path before writing the fixture; F2 |
| DS8 | **F1** (acceptance test), F2 (`PathPatternSubstitution`), F4 (`host` lands here) |
