# DS0 — data-layer package moves out of Report — implementation plan

> **Status: ready to execute.** Session 0 of the **DS** arc (Job data sources). Rationale
> **[`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md) §10**
> ("Package layering — Job must stop reaching into Report"). Constituent plan: **—** (the
> analysis doc is the permanent design record, so this file **is deleted on landing**; its as-built note
> goes into the analysis doc **§13**). Anchors verified 2026-08-21. Sized **M**; **mechanical,
> import-only, zero behaviour change**. Ledger row 49.
>
> **Why it goes first.** DS1 introduces `DataShape.Tabular(header: HeaderListing)` in a data-domain package that
> would otherwise `import tech.kzen.auto.common.objects.document.report.listing.HeaderListing` — a
> flavour-neutral package depending on Report's *document* package. Doing the move after DS1–DS6 means
> re-touching every new file. Doing it first costs one mechanical commit.

## Scope & goal

Perform the arc's two mechanical package moves before new consumers are written. First, move exactly
three files out of Report's document package into a new data domain:

| From | To |
|---|---|
| `common/objects/document/report/listing/HeaderListing.kt` | `common/data/schema/HeaderListing.kt` |
| `common/objects/document/report/listing/HeaderLabel.kt` | `common/data/schema/HeaderLabel.kt` |
| `common/objects/document/report/listing/HeaderLabelMap.kt` | `common/data/schema/HeaderLabelMap.kt` |

New package: `tech.kzen.auto.common.data.schema`, under a **new top-level `common/data/`** that the rest
of the arc fills in (`data/model/` in DS1, `data/api/` + `data/file/` in DS2).

Second, move the existing input plumbing from `server/objects/report/…` into `server/data/…`:

- `FlatDataSource` / `FileFlatDataSource` / `FlatDataStream` / `FlatDataLocation`;
- `ReportInputChain` / `ReportHeaderReader`;
- `FileListingAction` / `ColumnListingAction`;
- `ReportDefinitionRepository`.

This session changes packages and imports only. The `FileListingAction.scanInfoBlocking` extraction is
behavioral and remains in DS2 with its first source-side consumer.

**Why a new top-level `data/` rather than `paradigm/data/`.** `paradigm/` holds
`{detached, flow, job, logic}` — *execution paradigms*. A schema vocabulary and a data model are not
paradigms. `common/data/` is the honest home, and it is where `util/data/` (`DataLocation`,
`DataLocationInfo`, `FilePath`) would eventually belong too — **not moved here**: it is location
arithmetic used by everything including Report, its move buys the DS arc nothing, and mixing it in
would turn a mechanical commit into a judgement call.

## Dependencies & coordination

- **No prerequisite.** Nothing in the arc has been built yet.
- **Blocks DS1 and DS2** — both declare types that reference the moved vocabulary or plumbing.
- **Report is the biggest consumer and is not otherwise touched.** This is an import rewrite; no Report
  source logic, notation, or behaviour changes.
- **Stage nothing new by hand** beyond the moved files: use `git -C ../kzen-auto mv` so history
  follows, then `git -C ../kzen-auto add -- <explicit new paths>` only if the mv did not stage them.
  Never `git add -A`.

## Current-state findings (anchors verified 2026-08-21)

- **The three types are self-contained.** `HeaderListing` imports only
  `tech.kzen.lib.common.util.digest.{Digest, Digestible}`; `HeaderLabel` and `HeaderLabelMap` are
  likewise kzen-lib-only. Nothing in them references Report.
- **Import counts** (`kzen-auto`, excluding `build/`): `HeaderListing` 64 files, `HeaderLabel` 28,
  `HeaderLabelMap` 3. Union is ~70 files across `kzen-auto-common` (9), `kzen-auto-js` (16) and
  `kzen-auto-jvm` (45).
- **What stays behind, and why.** The `report/listing/` package also holds `FilteredHeaderListing`
  (a filter-UI projection over `HeaderLabelMap`), `AnalysisColumnInfo`, `InputBrowserInfo`,
  `InputDataInfo`, `InputSelectedInfo`. All five are Report-document concepts — Report's browse listing
  and filter surfaces — and none is referenced by the DS arc. Leave them; `FilteredHeaderListing` simply
  gains an import.
- **Job's remaining Report coupling is much wider** — `kzen-auto-jvm`'s `job/` packages import ~25
  distinct Report types (`CalculatedColumnEval`, `ColumnValue`, `PivotBuilder`, the export formatters,
  the spec classes…). **That is not this session.** The expression engine and everything
  pivot/export/filter stay put and are J-arc business.
- **No notation references these classes.** They are values, not archetypes — checked: no `class:` key
  in `notation/**` names them. So no yaml changes, and no user `main/` document can break.

## Pre-resolved questions

1. **Package name** — `tech.kzen.auto.common.data.schema`. Not `paradigm/data/schema` (see Scope), not
   `common/schema` (the arc needs a `data` root anyway for DS1/DS2).
2. **Move or type-alias?** Move. A `typealias` left behind in the old package would keep both names
   alive and guarantee the split persists; the point is to end the dependency, not to soften it.
3. **Does `HeaderListing` belong in `kzen-auto-plugin` instead?** No. The plugin SPI's record type is
   `FlatFileRecord` (already in `kzen-auto-plugin`), and headers reach plugins through
   `FlatDataHeaderDefinition`. Promoting `HeaderListing` to the published plugin artifact would add a
   cross-repo publish step to a mechanical commit — **out of scope**, and record it as a later question
   only if a plugin author actually needs it.
4. **Do the js and jvm planes both need touching?** Yes — the schema imports live in all three modules;
   the input plumbing is JVM-only. Verify with a full build, not a grep.

## Step-by-step implementation

### Step 1 — move

`git -C ../kzen-auto mv` the three files into
`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/data/schema/`, then rewrite the `package`
line in each. Prefer IntelliJ's *Move Class* refactor over hand-editing: it rewrites every import in all
three modules in one pass and it is the whole point of doing this mechanically.

### Step 2 — sweep

`grep -rn "objects.document.report.listing.Header" --include=*.kt` across `kzen-auto` (excluding
`build/`) must come back empty. A wildcard `import …report.listing.*` would survive the refactor
silently — grep for that form too.

### Step 3 — input-plumbing move

`git mv` the input-plumbing files listed in Scope into focused packages under `server/data/`, rewrite
their package/import declarations, and update Report's consumers. Do not change method bodies or split
`scanInfo` here.

### Step 4 — KDoc

One sentence on `HeaderListing`: that it is the flavour-neutral column vocabulary shared by Report, the
Job workers and the DS data sources, and that Report's remaining `listing/` types are Report's own. No
other doc changes; the arc's rationale lives in the analysis doc (CC-20).

## Tests

There are none to add — this session changes no behaviour. The existing suites **are** the test, and the
point of the session is that they are untouched apart from imports.

## Verification

1. `cd ../kzen-auto && ./gradlew build` — the full build, on purpose: this is the one session where a
   scoped compile would miss the point. All three planes compile and every existing suite is green.
2. `git -C ../kzen-auto diff --stat` — the diff should contain moves plus package/import churn.
   **Any method-body hunk is a mistake** and must be justified or reverted; that
   review is the session's real quality gate.
3. `./gradlew :kzen-auto-js:compileKotlinJs` and the AGENTS "client-graph boot check" — a moved class is
   not a `@Reflect` wrapper, so the client graph cannot break, but the boot check is cheap insurance
   against an unrelated stale bundle.
4. As-built note → analysis doc **§13**; tick ledger row 49; delete this file.

## Risks & gotchas

- **Wildcard imports.** IntelliJ collapses imports past a threshold; a `report.listing.*` wildcard is
  rewritten correctly by the refactor but is invisible to a grep for the specific class name. Grep for
  the package, not the type.
- **Do not widen either move.** `FilteredHeaderListing` will *look* like it belongs with the others. It is
  Report's filter projection, nothing in the DS arc uses it, and moving it drags `report/spec/filter`
  behind it. Resist; note it in the as-built if it keeps coming up.
- **Do not "tidy" other Report imports while in there.** Job's ~25 other Report imports are real
  coupling and deserve a considered plan, not a drive-by (feedback: surface scope expansion as a
  decision, don't take it).
- **Umbrella build trap** (AGENTS): `./gradlew build` from `kzen/` abbreviation-matches
  `:buildEnvironment` and exits 0 having compiled nothing. Build from `../kzen-auto`.

## Out of scope (this session)

- `util/data/` (`DataLocation` and friends) — stays where it is.
- The behavioral `FileListingAction.scanInfoBlocking` extraction — **DS2**, where it has a consumer.
- `CalculatedColumnEval` / `ColumnValue`, and everything pivot / export / filter — J-arc.
- Any behaviour change whatsoever.
