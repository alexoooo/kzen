# Job data sources — review of the design and the DS plans

**Date:** 2026-08-23 · **Status:** dispositions applied to the design record and DS plans. The design record is
[`2026-08-20_job-data-source.md`](./2026-08-20_job-data-source.md) and the execution layer is
`docs/plans/next/DS0`–`DS8`. This file records the review and its disposition; the owning rationale is in
the design record. Claims were checked against `kzen-auto` at review time; per CC-20 no line numbers are
cited.

## Verdict

The design's core is coherent. The core commitments — resolution and reading are
effects owned by workers, refs are plain paths until a provider needs otherwise, a plain pull cursor the
worker drives, the manifest carried rather than re-resolved, source and opener split — each *removed*
machinery rather than adding it, and none of them should be re-opened.

F1, F9, F10 and F12 would fail or corrupt the arc's own acceptance behavior as written. F11 is a direct
model/reader contradiction. The remaining findings simplify the API or plan shape before code makes
them expensive.

---

## F1 — the per-unit output path was unfunded, and three fixtures depended on it

**Severity: blocking for DS5, DS7 and DS8.**

DS5's child-Job fixture, DS7's fixture and DS8's acceptance fixture wrote per-unit output:

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

**Disposition: applied in DS7.** `RunWorker.arguments` maps child parameter names to Kotlin expressions
evaluated against the incoming message with the existing formula-expression scope. The incoming value
still binds the first child parameter; expressions supply additional parameters by name through the named
`host(instructions, arguments: TupleValue)` overload. The dated shape binds
`date: attributes["date"]`; the child declares `date: String`; writers resolve `${date}` from
`control.parameter("date")` in `onStart`. This is generic Logic call binding, not a `DataUnit` branch in
`RunWorker`. DS5 uses a fixed-path, single-unit boundary fixture; DS7 owns the binding and per-unit fixture;
DS8 reuses it for the full acceptance test.

## F2 — `PathPatternSubstitution` duplicates a shipped helper

DS8 step 3 plans "one `PathPatternSubstitution` in commonMain, used by the writers and available to a
source". `OutputExportSpec.resolvePattern` already **is** that helper: it lives in commonMain, it does
`${…}` replacement over a fixed vocabulary, and `ExportWriterWorker` already calls it through
`resolvePath`. Writing a second one is a straight CC-12 duplication, and it would leave two substitution
dialects on two writers.

**Disposition: applied in DS7.** Extract one neutral commonMain `PathPatternSubstitution` primitive.
`OutputExportSpec` retains ownership of Report's sanitization and reserved vocabulary but delegates the
actual replacement; the Job writers add scalar Job parameters. Unknown placeholders fail clearly. This
avoids both a copied implementation and an accidental widening of Report-specific semantics.

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

**Disposition: applied.** Move `staticShape(role)` to `DataSource`. `ReadWorker` holds its source and asks it
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

**Disposition: applied.** v1 `DataContext` is `argument(name)` + `blocking(block)`. DS7 adds only the
named `JobControl.host` overload needed by generic `RunWorker` binding; `DataContext.host` lands in DS8
with its first caller, `LogicDataSource`. `contextValue` lands with the first stateful source, together
with the `JobControl` accessor it needs. This is safe to defer precisely because third parties *consume* `DataContext` rather than
implement it — the implementations are ours — so adding members later is source-compatible for every
`DataSource` / `DataOpener` author. Two fewer stubs, and the Context-borrow model (§4) is documented
rather than half-built.

## F5 — `mergeSchemas` has a poor name, but strictness is semantic

The original finding overstated the case. Superset prevents silent loss, but `strict` is a real data
contract: it rejects an unexpected added or removed column instead of accepting schema drift. Its lower
pre-scan cost is a consequence, not its meaning.

**Disposition: corrected.** Keep both behaviors, default to `superset`, and rename the attribute
`schemaMode: strict | superset`. The name describes the policy without implying that `strict` is a kind
of merge.

## F6 — DS2 carries a mechanical package move that belongs in DS0

DS0 already is the import-only session, with an explicit quality gate ("any file with a non-import hunk is
a mistake"). DS2's Step 3 moves the input plumbing (`FlatDataSource`, `ReportInputChain`,
`ReportHeaderReader`, `FileListingAction`, `ColumnListingAction`, `ReportDefinitionRepository`) to
`server/data/` — the same kind of change, bundled into a session that also lands the SPI, two
implementations, a cursor, a lookup, a detached action, notation, conventions and a spike.

**Disposition: applied.** Fold the pure move into DS0 and keep only the `FileListingAction.scanInfo`
blocking-core split in DS2 — that one is behaviour-adjacent and belongs with its consumer. DS2 is the
largest session in the arc and this is free relief with no design consequence.

## F7 — DS1b's registry escape hatch cannot be tested

DS1b keeps `ObjectRegistry` as a widening hatch for classes the `isNameable` predicate rejects as false
negatives. Its own test 6 concedes it cannot demonstrate one: *"a Java class whose `visibility` reflects
null, if one exists on the test classpath; otherwise a test double where the predicate is stubbed."*

A widening hatch with no reachable case is either evidence the predicate is right and the hatch is dead
code, or evidence the predicate is wrong. A stubbed-predicate test proves neither.

**Disposition: retire it in DS1b.** No real false negative is available; a stubbed predicate does not
prove the hatch. Remove `ObjectRegistry`, `ObjectRegistryScan`, their cache and their context threading in
the same session that replaces the whitelist.

## F8 — naming and a small dispatch smell

- **`DataShape.Object`.** Rename it to `DataShape.Payload(type)`, matching the existing flat-versus-payload
  `JobMessage` / `WorkerLane` vocabulary. `Object` excludes scalar payloads conceptually and invites
  confusion with `java.lang.Object` and Kotlin's `object` keyword.
- **`DataSourceActions` with an `action=` parameter** is a string-dispatched mini-router, with an
  unknown-action failure path to write and test. Two single-purpose detached objects would drop that
  branch entirely. On balance, keep the one generic action object: two operations do not justify two
  registered objects and two well-known locations. Bind action names to constants and retain the explicit
  unknown-action failure.

---

## F9 — DS5 checkpoints after removing its input batch from the channel

**Severity: blocking for DS5.**

`TransformWorker.drive` receives a whole batch into a local variable and then calls `onElement`. DS5's
planned `Emitter.expandCadence` checkpoints inside `onElement` and claims the current unit will be
redelivered from `JobChannel.drainBuffered`. It cannot be: the current element and the rest of that batch
have already left the channel and exist only on the old coroutine stack. A migration at that checkpoint
loses them.

**Disposition: applied.** DS5 introduces `ExpandingTransformWorker`, a distinct 1:N execution base that
owns the active batch and element index as migratable fields. Its snapshot composes those with the
subclass's unit/part/item cursor. It flushes and checkpoints at output-batch cadence; after migration the
current element is replayed against the adopted cursor and the rest comes from the carried batch. The 1:1
`TransformWorker` invariant remains true.

## F10 — DS7 fingerprints writers before their containers are finalized

**Severity: blocking for DS7.**

`SinkWorker` calls `onComplete` before `WorkerBase` reaches `onClose`. Both writers close there, and the
export writer finalizes gzip/zip containers there. Yielding and statting the path in `onComplete` can
therefore publish an incomplete size/mtime and, for a compressed output, an unfinished container.

**Disposition: applied.** On successful completion each writer finalizes/closes idempotently, then stats
and yields. `onClose` calls the same idempotent finalizer as the failure/cancellation fallback. Tests pin
that the yielded fingerprint matches the bytes visible after completion, including compressed output.

## F11 — DS5 promises several same-role parts but calls the single-part accessor

DS1 deliberately defines `DataUnit.part(role)` as exactly-one-or-throw and `partsOf(role)` as the ordered
multi-part accessor. DS5's scope calls `unit.part(role)` while its own Pre-resolved 2 promises to read
several same-role parts in order.

**Disposition: applied.** Both readers select `partsOf(role)` and read the resulting parts in order. Zero
matches fails naming the role; a blank role selects the unit's sole distinct role and still permits several
parts carrying it.

## F12 — the child yields `output`, but `RunWorker` reads `main`

**Severity: blocking for DS7 and DS8.**

The worked child Job declared `results: output: DataRef`, while `RunWorker` emits
`result.mainComponentValue()`. A writer yielding `output` therefore completes successfully but the outer
lane receives null. Keeping a trailing `ResultSinkWorker(result: output)` does not fix that mismatch and
is redundant once the writer itself yields the ref.

**Disposition: applied.** The child declares `results: main: DataRef`; its writer explicitly uses
`result: main`; the redundant child `ResultSinkWorker` is removed. The outer sink may still use the named
`outputs` component because it is the final collector, not a value harvested by another `RunWorker`.

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
- **Run-time instances come from the run graph, not `GraphInstanceCache`** — the cache's callers filter
  by `serverAllowed` (the cache itself is policy-agnostic) and the run does not, so the two populations
  can disagree, and a cached instance is outside the run's frame where the Context borrow cannot reach
  it.
- **`ResultSinkWorker` keeps `first` / `last` today**, so `keep: all` really is new work (O2).
- **`DataUnit` will type as `Any` without DS1b** — `visibleBuiltins` is eleven entries and the shipped
  registry holds one, `kotlin.ranges.IntRange`.

## Disposition by plan

| Plan | Findings that touch it |
|---|---|
| DS0 | F6 — takes the input-plumbing move |
| DS1 | F8 — `DataShape.Payload` |
| DS1b | F7 — retire the untestable registry hatch |
| DS2 | F3 (SPI shape), F4 (`DataContext` members), F6 (drop Step 3), F8 (action dispatch) |
| DS3 | F8 (`DataShape.Payload`) |
| DS4 | — |
| DS5 | F1 (remove premature dated-path fixture), F3 (source-less static shape is unknown), **F9** (migration-safe expansion), F11 (`partsOf`) |
| DS6 | F3 (no second lookup entry point), F5 (`schemaMode`) |
| DS7 | **F1** (generic named arguments + per-unit path), F2 (shared substitution), **F10** (finalize before yield), **F12** (child yields `main`) |
| DS8 | F1 (reuse the funded mechanism), F4 (`DataContext.host` lands with its first caller), F12 (acceptance fixture reads `main`) |
