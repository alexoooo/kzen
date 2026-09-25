# Values, metadata and design-time types — constituent plan (VM)

> **Status: complete — VM1–VM3 landed 2026-09-24 (as-builts in §8).** Written with the user
> after using a `File → Extract` Job in the editor.
>
> **Relation to other documents:**
> - **Reverses** [files and items](../analysis/2026-09-18_job-files-and-items.md) §1/§3 ("`File` only selects
>   files … the read is implicit"). Reading becomes an explicit `Parse` Worker.
> - **Relaxes** the DS6 invariant in [job data source](../analysis/2026-08-20_job-data-source.md) §6.1/§13, that no
>   definition walk touches the filesystem. Design-time reads become allowed, but only through one bounded,
>   cached, evidence-recording service (§5).
> - **Extends the unified data model** ([data-model](data-model/README.md)) with value metadata (§4). kzen-lib
>   changes are published before kzen-auto consumes them.
>
> The [master ledger](2026-07-25_master-plan.md) owns sequencing (rows VM1–VM3). Each row first writes its design
> as a section of this plan for the user's review, and only then implements it. Each landed row appends its
> as-built under §8.

## 1. Symptoms (observed)
1. **A Worker's output type changes when you add a Worker *below* it.** `File` over `data.tar.gz` shows
   `{name, size, modified, kind}`. Adding `Extract` below it turns that into `DataUnit`, an internal structure
   whose "technical details" list JVM fields.
2. **One thing, several unrelated shapes.** A file's facts, an archive's listing, and an archive member's fields
   are different types. Similar facts get different names (`modified` vs `modifiedEpochMillis`, `link` vs
   `symlink`).
3. **Reading is not uniform.** A top-level file is read by `File`, with its format detected. An archive member is
   read by `Read part`, whose format defaults to CSV. The same CSV is handled differently depending on where it
   came from.
4. **Information about an item is lost or mangled.** Values that describe where an item came from (its file name,
   or values pulled out of the name such as `year`) survive only by being merged into the item's columns
   (`attributes: columns`). That only works for tables; for any other kind of data they are dropped.
5. **Types are unknown until Run.** A plain CSV's columns, or anything after `Read part`, show as unknown until a
   run. Filters and formulas can't be checked against them. The ways to look at data before a run are manual
   buttons in a few editors, backed by copies of the server logic kept in the browser.

## 2. Root causes
- **A. Workers have mixed, implicit responsibilities.** `File` both selects and reads. Which one it does is
  decided by its neighbour (`emit: auto`), not by its own settings.
- **B. A value has no notion of payload vs metadata.** A value is a single piece of data. There is no place for
  values that describe it without being part of it, so they must be merged into the payload or discarded.
  Formula's `formula` columns and `carry` are record-only workarounds for the same gap.
- **C. Design-time types come only from declarations.** Validation never looks at data. So a type that depends on
  the data (CSV columns) can't exist before a run, and ad-hoc workarounds grew around that gap.
- **D. Internal representations leak into user-facing types.** `DataUnit` is shown to users; nothing presents a
  file simply as a file.

## 3. Definitions and requirements

### Definitions
- **Value** = **payload** + **metadata**, like a message's payload and headers.
  - The **payload** is the data itself, of any type: a row, a document, a number, a file's content.
  - The **metadata** is typed values that describe the whole value: where it came from, values derived from its
    name or container, values computed about it. It belongs to a whole value, never to a part inside one.
  - It is part of the unified data model (`DataContract` / `DataValue` in kzen-lib), not a Job-specific type.
    Flow, Script and Report values can carry metadata too.
- **Worker**: one purpose. Its output type is determined by its own configuration, its input type, and (for data
  it reads) that data. Never by what comes after it.
- **Design time**: before Run, while editing. **Run time**: while executing.

### Requirements
- **R1 — single-purpose Workers.**
  - Selecting data and interpreting data are separate Workers.
  - `File` selects files and produces one value per file: metadata = the file's facts (including Name-pattern
    captures), payload = its content.
  - Interpreting content (CSV, text, archive listing…) is a separate Worker, `Parse`, which owns the format. It
    behaves the same whatever produced the content: a file, an archive member, or something else later.
- **R2 — any data.**
  - Nothing in the general mechanisms may assume files or tables; files are just one source of payloads.
  - `Read` (DataSource reference) and `Logic source` keep producing whatever they produce.
- **R3 — one data model.** No Job-specific data type. Metadata lives in the unified model, so snapshots,
  serialization and other document types get it for free.
- **R4 — metadata travels.**
  - A Worker that transforms a value's payload keeps its metadata.
  - Workers can add metadata; e.g. a Formula adds computed values as metadata.
  - A Worker that produces several values from one chains its input's metadata as `parent`, e.g. row → archive
    member → archive file.
  - Metadata can be used downstream (filter, compute, name outputs) and is typed, whatever the payload's type.
  - **No leaks.** Metadata is plain data only (scalars, records, lists), never native handles or closeable
    resources. A `parent` link holds the parent's metadata, never its payload. So a row never keeps its file's
    content alive, a borrowed archive member's metadata stays valid after the member is released, and values
    derived from the same input share one metadata instance rather than each holding a copy.
- **R5 — types before Run, wherever the data is reachable.**
  - When a type depends on data that exists at design time, the editor shows it before Run, e.g. a CSV's columns
    under `Parse`, and expressions over them are checked.
  - A data-derived type is labelled as such, e.g. "inferred from 41 of 256 files".
  - Looking at data at design time is bounded in time and size, reused when unchanged, refreshed when the data
    changes, and never holds up editing.
  - It is one general capability, not per-editor buttons.
- **R6 — design time and run time agree.**
  - A run either honours the type shown at design time, or stops and names the value that doesn't fit.
  - Changes to data during a run don't change the types the running Workers were built against.
- **R7 — user-facing types speak the domain.** A file looks like a file: its metadata plus an opaque content.
  Internal structures and JVM details are not shown by default.
- **No backward compatibility.** Saved notation is development and test material only. Old Jobs may show errors
  or behave differently; fixtures are updated only where tests need them.

### Non-goals (for now)
- Automatically inserting `Parse` after `File`.
- Grouping several values together (e.g. a data file with its sidecar). It would be a general transform later;
  nothing groups files today, since "Name pattern" only extracts values from names.
- Showing sample rows at design time. It is a natural extension of R5, but not required.
- Design-time types through `Extract` (archive members). Allowed by the model; it can come later.

## 4. Solution shape: value metadata (VM1)
- **Data model.** A value's contract gains a metadata part next to its structural type, and a value exposes its
  metadata as another value.
  - Consumers that only care about the payload are unaffected. Job channels keep carrying plain `DataValue`s.
  - This was preferred over two alternatives:
    - Nesting as a record `{payload, metadata}` can't be told apart from user data.
    - A new `DataType` variant would force every type switch to handle it.
- **The overlay view.** The lazy view that composes a value without copying (`RecordOverlay` in kzen-auto) moves
  to kzen-lib as the way a payload and its metadata are paired.
- **Job rules** follow from R4:
  - Sources set metadata.
  - Transforms keep it.
  - Expanding Workers chain it as `parent`.
- **Formula is: keep or replace the payload, and add metadata.**
  - `formula` entries become metadata fields.
  - A replaced payload keeps its metadata.
  - `carry` has no remaining purpose.
- **Sinks choose how a value is flattened.** A CSV writer has a column selection. By default it takes the
  payload's top-level properties. The user can add metadata fields or nested paths as further columns.
  `attributes: columns` goes away.
- **Expressions see every facet through one type-safe scope.**
  - The payload is `this`, with its members available by bare name.
  - Metadata fields are host properties, available by bare name, e.g. `year` and `parent.name`.
  - Names resolve innermost first: payload, then metadata, then Job parameters.
  - Qualified forms always resolve unambiguously: `this.name` for the payload, `meta.name` for the metadata.
    Validation warns when a bare name is shadowed.

## 5. Solution shape: File / Parse (VM2) and design-time reading (VM3)
- **VM2, from R1 and cause A.**
  - `emit: auto`, the "file consumer" marker and the whole-file format lose their reason to exist on `File`.
  - The format moves to `Parse`, and `Read part` becomes `Parse`.
  - `File` and `Extract` produce the same kind of value, file metadata plus content, which the editor presents in
    those terms (R7).
  - Lending depends on the content's lifetime, not on the value's type, so local files can be sorted and
    retained.
- **VM3, from R5/R6 and cause C.**
  - Validation may look at data, but only through one bounded, cached service that records what it looked at,
    so it knows when to refresh.
  - A lane can offer a small sample of the values it would carry, and a Worker like `Parse` types itself from
    that sample. Nothing in it is file-specific (R2).
  - A run keeps the types it was validated with, and fits values to them or fails by name.
  - The browser-side copies of the shape logic are retired once validation carries data-derived types.

## 6. Open questions (answered 2026-09-24 as defaults, when the user asked to implement the whole plan)
1. **Data changed after validation.** A run validates again at its start, and fails by name if something no
   longer fits. A validation that read data is reused only while every piece of data it looked at rechecks
   unchanged, so a run over changed files re-types before it starts. An expression that no longer compiles
   against the new type fails the run by name when its Worker starts. Once started, a run keeps its types: a
   part that doesn't fit them fails by name (R6).
2. **Limits.** At most 256 values of any one lane. The editor's pass has a 2.5 s deadline; a run's revalidation
   has 30 s. The value limit is a fixed bound, labelled in the provenance ("Inferred from 256 of 900 values"). A
   pass the deadline cuts short is partial: the editor shows "Reading data…", asks again after a second, and reads
   on from what was already inspected.

## 7. Phases

| Phase | Scope | Status |
|---|---|---|
| **VM1** | Value metadata in the unified data model (kzen-lib) and its Job rules, Formula, expressions and sinks (§4) | ☑ 2026-09-24 |
| **VM2** | `File` selects only; `Parse`; one file value for `File` and `Extract` (§5) | ☑ 2026-09-24 |
| **VM3** | Design-time reading and run-time agreement (§5, §6) | ☑ 2026-09-24 |

## 8. As-builts

The user asked for the whole plan in one go (2026-09-24), which overrode the per-phase design reviews. Each phase's
design is its §4/§5 shape as refined below.

### VM1 — value metadata (2026-09-24)
- **kzen-lib** (0.30.0-SNAPSHOT). `DataContract.metadata` and `DataValue.metadata` hold the metadata part.
  `payload()` and `withMetadata` split and pair a value; snapshots and the wire format carry it.
  All three sides are typed so metadata cannot nest. `DataValue.metadata` is a `ValueMetadata`,
  `DataContract.metadata` a `MetadataContract` and `DataSnapshot.metadata` a `MetadataSnapshot`, not another
  `DataValue` / `DataContract` / `DataSnapshot`. None has a metadata slot, and a `MetadataContract` has no
  native metadata either: it is a `DataType.Record` with its definitions and constraints. What the types cannot
  express fails by name when one is built: a nullable record or an opaque member, and (through the `of`
  factories) a contract or record that carries native metadata or metadata of its own. `ValueMetadata.value`,
  `MetadataContract.contract` and `MetadataSnapshot.snapshot` read each as a plain record. The wire format is
  unchanged.
- **The overlay moved to kzen-lib as `DataOverlay`**, which also adds metadata fields (`withMetadataFields`)
  without copying.
- **Job rules.** Transforms keep the metadata. Expanding Workers (`Parse`, `Extract`) set it to `{parent}`, the
  input's metadata. Sources set it: file facts, Name-pattern values, and a `Read` unit's attributes.
- **Formula.** Each `formula` entry becomes a metadata field. A separate `payload` expression replaces the payload.
  The output keeps the incoming metadata. `carry` and its editor are gone.
- **Expressions.** One scope, innermost first: the payload (`this`, its members bare, `payload` as an alias), then
  metadata (fields bare, `meta.x`, nested `parent.name`), then Job parameters. A bare name that an inner facet
  shadows is reported as a warning. `meta["name"]` reads a field by name at the expression boundary.
- **Sinks.** `CsvWriterWorker` has a `columns` selection (`WriterColumnSpec`). `*` (the default) takes the payload's
  top-level columns; a path such as `meta.name`, `instrument.symbol` or `{path, as}` adds a column.
  `attributes: columns` is gone. The CSV and Export writers edit it in `WriterColumnsEditor`. It shares
  `ContractPathPicker` with the Paths editor, and that picker now offers `meta` (the metadata's fields) as a last
  root. Adding the first path to an empty list writes `*` before it, so the payload's columns stay.

### VM2 — `File` selects, `Parse` reads (2026-09-24)
- **`File` reads nothing.** Each value is the file's `FileContent` (opaque), with metadata
  `{name, path, size, modified, kind}` plus Name-pattern values (`FileValues`). `size` is non-null. `emit: auto`,
  `JobReadEmit` and the `FileConsumer` marker are gone. `WholeFileFormat` remains only as `File`'s internal "read
  nothing" format for its listing. `FileSelectionConfig` holds the selection attributes shared by `File` and
  `FileDataSource`.
- **`Read part` became `Parse`, which owns `format`.** It reads a selected file (automatic detection samples the
  file), content read once (an archive member: the format is picked by the member's name via `FilenameDetection`,
  and fails by name when no format claims it), or a `DataUnit`'s parts. Its items' metadata is `{parent}`.
- **`Extract`** takes a file value and lends its members as the same kind of value, with the archive as `parent`.
- **`Read` and `Logic source` keep an explicit `emit: items | units`.** A unit's attributes become the unit value's
  metadata, readable as `meta["name"]`. A writer names per-unit output through `meta.parent.date`.
- **Temporal values** parse at the expression boundary, not in the file value.
- **Preview** shows a value's metadata, including `meta.parent`.

### VM3 — types before Run (2026-09-24)
- **One reading service.** `DesignReader` (kzen-auto-jvm `server/data/design/`) is the only way validation looks at
  data. Each pass gets a `DesignReadSession` bounded by a `DesignReadBudget` (§6.2). The session records each read
  as `DesignEvidence`: what was looked at, plus a digest recheck. Part shapes and resolved read specs are cached
  by content fingerprint across passes. Nothing in it is file-specific (R2).
- **Lane samples.** `JobLaneDescriptor.sample` (`JobLaneSample`) holds up to 256 of the values a lane would carry,
  plus the total.
  - `File` offers the files it selects. `Read` in units mode offers its data source's units.
  - A Worker that forwards its input unchanged forwards the sample. So a filter widens the sample (the type is
    read from values it might drop) and never narrows it.
  - Content read once is passed over.
  - A source that needs logic to resolve (`LogicSource`) offers no sample.
- **Typing from data.** `Parse`, and `Read` in items mode, type themselves through `DesignShapeInference`, merging
  by their `schemaMode` exactly as a run does (`DataReadCore.planShape`). `StepValidation` gained `provenance`
  ("Inferred from N of M values") and `partial`. The editor shows the provenance beside the type and a partial
  step as "Reading data…". `JobController` asks again one second after a partial validation.
- **Caching and revalidation.** `JobValidationCache` reuses a validation only while its evidence rechecks
  unchanged, and never a partial one. The editor's pass and the run's revalidation share entries. A run
  revalidates with the 30 s budget.
- **Run-time agreement.** `JobRun` passes each Worker its validated output contract (`JobControl.outputContract()`).
  `Parse` and `Read` hold every part to it (`DataReadCore.fitShape`):
  - Parts that match exactly, or superset parts whose fields are all in the validated type with the same
    contracts, are projected onto it.
  - Otherwise the run fails by name: "… has fields outside the type validated before the run: c; validate the Job
    again", or "… lacks fields …".
  - This holds for declared and inferred types alike. A run whose revalidation was itself cut short has no
    validated type and reads as before.
- **The browser's copies are retired.**
  - `ReadShapeProjection`, the inspected-source branch of `JobUpstreamSchema`, `DataSourceResolveStore` and
    `DataSourceInspectionDisplay` are deleted, along with the four `DataSourceConventions.shape*AttributeName`
    constants.
  - Sort, Pivot and Value-set editors read the upstream Worker's validated contract off `JobValidationChannel`,
    after a live Summary. `Read`'s source view shows the Worker's validated type, and "Create editable schema"
    starts from a type inferred from data.
  - `DataSourceShapeStore` remains only for the explicit per-file "Lock columns" action in the file selection
    editor, which authors a format and does not type the Job.
- **Tests.** `DesignReadSessionTest` (evidence, deadline, cache reuse), `ParseWorkerTest` and `ReadWorkerTest`
  (inference, partial, fail-by-name), and `JobDesignTimeTypeTest`. The last one runs end to end: `File → Parse →
  Filter` typed from two CSVs, a run, and a run failing by name after a file was removed.
- **Known limit.** The folder filter is a substring match ("`.csv`"), although its field description suggests
  `*.csv`. This predates VM and is left unchanged.
