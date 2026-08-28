# Data-model plans — review findings (2026-08-28)

> **Scope: the plan files DM1–DM13 only.** The design in
> [`docs/analysis/2026-08-27_data-model.md`](../../analysis/2026-08-27_data-model.md) is not re-litigated here;
> every item below is about sequencing, sizing, anchors or conventions in the plans themselves. Anchors are class /
> file / section names (CC-20). Each finding names the plan it applies to and a proposed disposition; the
> disposition is a recommendation until the user settles it.

## 1. DM3 deletes a load-bearing runtime dispatch before its replacement exists

**Plans:** DM3, DM7.

`DataShape.Tabular | Payload` is not only a wire / inspection classification; today it is the runtime dispatch that
tells data consumers whether cursor items are `FlatFileRecord`s or payloads, and it is what `WorkerLane` is built
from:

- `FileDataCursor.shape` is typed `DataShape.Tabular`, and `DataCursor`'s KDoc states the contract: "a tabular
  shape means every item is a `FlatFileRecord` under that header".
- `DataReadCore` casts `cursorShape as? DataShape.Tabular` in its shape-plan, superset-union and header-derivation
  paths, and branches `is DataShape.Payload` / `is DataShape.Tabular` for display.
- `ReadWorker` branches `is DataShape.Payload` to build a `WorkerLaneAttempt`.
- `ColumnListingAction` and `FileDataOpener` produce / consume `DataShape.Tabular` directly.

DM3 step 3 deletes the two cases and step 7 allows "a temporary adapter for the still-legacy `WorkerLane` only
where compilation requires it", while its preconditions leave `DataCursor`'s item type, `JobMessage` and
`WorkerLane` untouched until DM7. The new `DataContract` cannot carry the flat-vs-payload distinction — a CSV row
promises no native facet (design §4.1 table) — so after DM3 there is no way for `DataReadCore` / `ReadWorker` to
know whether an item is a `FlatFileRecord` without a bridge the plan does not specify.

**Disposition options:**

- (a) Make DM3 additive: land the observation envelope and the typed `DataSchemaDocument.shape()` beside the
  existing cases, keep `Tabular | Payload` alive as the cursor item-kind bridge, and move the deletion of the two
  cases (and the `rg "DataShape\.(Tabular|Payload)"` exit criterion) to DM7 step 7; or
- (b) keep DM3 as written but specify the bridge: an explicit, DM7-owned "items are flat records" fact on the
  cursor (or on the opener's result) that `DataReadCore` and `ReadWorker` dispatch on, named for deletion in DM7.

Either way DM3's exit criteria must say which. (a) is smaller and leaves no half-migrated dispatch.

## 2. DM7 and DM9 are not one-session plans

**Plans:** DM7, DM9 (and DM7's gate-failure rule).

Counted from the tree (production vs test Kotlin files, kzen-lib + kzen-auto + kzen-project):

| Symbol | prod files | test files |
|---|---|---|
| `JobMessage` | 29 | 24 |
| `WorkerLane` | 14 | 4 |
| `flatView(` | 11 | 1 |
| `TupleValue` | 30 | 31 |
| `TupleDefinition` | 36 | 14 |
| `RequiredInput` | 18 | 12 |

`TupleDefinition.ofMain(LogicType(...))` producers alone include `ReportLogicCompiler`, `ParameterBinding`,
`ForEachItemBinding`, `BindStep`, `UseContextStep`, `ForEachStep`, `IfStep`, `RunStep` and `BrowserReadStep`, plus
`JobControl`, `EngineJobControl`, `WorkerLogic`, `JobResultCollector`, `ScriptLogic` and `DataContext` on the
value side.

DM7's stop rule ("return to the last green bridge") assumes a green state exists mid-cutover; a single session
that runs out before the carrier is fully replaced leaves none. **Disposition:** split each into named sub-sessions
with a green bridge at every boundary, e.g. DM7a (lane contract + channel/batch element type, bridged),
DM7b (source producers + column Workers), DM7c (`FormulaWorker`, sinks, `RunWorker`, deletion + gate run); DM9a
(kzen-lib core interfaces + engine, tuple bridge kept), DM9b (kzen-auto `JobControl` / `DataContext` /
`LogicDataSource` / named host sites, bridge deleted). Record the split in the master ledger as separate rows.

## 3. The J-arc collision is named but not decided

**Plans:** DM5 (precondition), DM6 (collision control), DM7; master ledger rows 3–5 and 27.

- DM5 requires the J5a benchmark baseline before the carrier changes. In `2026-07-25_master-plan.md` J5a is row 5,
  *after* J4 (row 3) and J9 (row 4).
- DM6 freezes J4 / J9 / J6 while DM6–DM7 touch `FormulaWorker`, readers, writers, channels and element ownership.
  J4 (`groupBy` export, Explore/Summary persistence) and J9 (writer append cursor, Pivot/Explore carry) rewrite
  the same reader/writer/`ExportWriterWorker` files.

The plans say "freeze" and "land or pull forward J5a" but do not say in which order the ledger now runs.
**Disposition:** decide in the ledger, not per session: J5a pulled forward ahead of DM5; J4 and J9 sequenced
*after* DM7 (otherwise they are written against `JobMessage` / `FlatView` and rewritten by DM7); J6 stays
demand-driven and consumes DM7's alias/copy rule. Update rows 3–5 and DM1's "add DM1–DM13 rows" step accordingly.

## 4. `docs/plans/data-model/` is a tier the plans convention does not describe

**Plans:** all; `AGENTS.md` "Plans directory convention"; `docs/plans/next/README.md`.

The documented tiers are `docs/plans/<date>_*.md` (constituent plans — the design rationale and tracker),
`docs/plans/next/` (execution elaborations, deleted when landed) and `docs/plans/sprint-*/` (archives).
`docs/plans/data-model/DM*.md` are elaborations with **no constituent plan**: the analysis document is analysis
(explicitly "not an implementation contract"), and no file holds the tracker / as-built ledger. Under
`next/README.md`'s standalone rule such files must be archived, never deleted — Sprint 2 lost scope by deleting the
wrong layer.

**Disposition:** add `docs/plans/data-model/README.md` as the constituent plan for the arc (tracker per DM row,
as-built section pointers, ledger-row map, the J-arc ordering decision from §3), and add one line to `AGENTS.md`'s
plans convention naming `docs/plans/<arc>/` as a multi-session arc directory with a README as its constituent plan.
DM1's exit criterion "record the final package/API names in this file's as-built section" then has a home for the
arc-wide items too.

## 5. Anchors the plans miss or misstate

- **DM8 / DM9 — `JobControl.host` has two overloads.** DM9 lists `host(instructions, arguments: TupleValue)`; the
  interface also has `host(instructions, input: Any?)` (the DS7-era single-input form). DM8's inventory must list
  both and DM9 must migrate both.
- **DM10 — `IfStep.joinBranchTypes` is an existing `join` consumer.** It joins branch `TypeMetadata` nominally
  (same class and generics → nullable-or; `Unit` wins; otherwise `kotlin.Any`). It is not in DM10's anchor list.
  The conservative structural `join` widening differing records to `Dynamic` corresponds to today's `Any` fallback,
  so it is compatible, but DM10 should name it and pin the equivalence in `IfStep` tests.
- **DM3 — `DataSchemaDocument.shape()` never reads types.** It is
  `DataShape.Tabular(HeaderListing.ofUnique(fields.fields.keys.toList()))`; the design's "parses `TypeMetadata` then
  discards it" overstates it. Same conclusion (types are lost), but DM3 step 4's "preserve `TypeMetadata`" is a new
  read of `DataSchemaFieldListSpec`, not a removal of a discard.
- **DM5 — check-first on plugin loader identity.** `FlatFileRecord` implementing `ValueAccess` from inside a
  plugin loaded through `ClassLoaderHandle` / `ClassLoaderUtils.dynamicParentClassLoader()` only works if kzen-lib's
  `ValueAccess` resolves to the app loader's class in both places. Almost certainly true (kzen-auto-jvm is the
  parent), but DM5 should verify it before taking the dependency, and note that the plugin artifact now pulls
  kzen-lib-common-jvm's transitive dependencies (dexx, Guava, coroutines) into every plugin classpath — an
  accepted cost per design §14.3, but one to state in the plugin's `AGENTS.md` update.
- **DM3 — `DataCursor.shape` is nullable today** (`val shape: DataShape?`); DM3 step 5 makes it non-null. Every
  cursor implementation and `DataReadCore`'s "no shape" branch are in scope; the plan's anchor list names
  `DataCursor.shape` but not the null-handling call sites.

## 6. Blast radius outside kzen-auto

`TupleValue` / `JobMessage` / `FlatFileRecord` reach `kzen-project` only through
`kzen-project-jvm/src/test/.../SampleExtensionTest.kt`, and `kzen-sample-plugin` through three source files. DM7's
and DM9's "rebuild standalone kzen-project" steps are sufficient; DM5 step 8 should name `SampleExtensionTest`
explicitly so the sample-plugin rebuild is not the only downstream check.
