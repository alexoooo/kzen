# DS8 — `LogicDataSource` + the dated-path example — implementation plan

> **Status: ready to execute.** Session 8 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§4.4** (authoring a source without Kotlin — resolve-only), §4 (`DataContext.host` with named
> arguments — O13), §1 (parameterized resolution, multi-part units), §3.4 (flat list of self-describing
> units), §4.2–4.3 (source/format axes; self-opening plain refs), §5.6 (child Logic per unit), §8.1
> (resolve once), O16. Constituent plan: **—** (analysis doc
> is the record; delete on landing, as-built → analysis **§13**). Depends on **DS2, DS3, DS5, DS7**.
> Anchors verified 2026-08-21.
> Sized **S–M**; kzen-auto-common + kzen-auto-jvm + yaml + one notation example. Ledger
> row 58. **Closes the arc.**

## Scope & goal

Ship the extension point, and use the dated case to prove it:

```
LogicDataSource(
  instructions: <Script | Flow | Job>     # the resolution logic; main result: List<DataUnit>
  arguments:    [from, to]                # names forwarded from DataContext.argument(name), BY NAME
)
    resolve(context) = context.host(instructions, TupleValue(arguments.map { it to context.argument(it) }))
                         .mainComponentValue() as List<DataUnit>  → DataResolveResult
    // no open / describe: the refs it mints are plain; FileDataOpener reads them (DS2)
```

- **A user authors resolution in the product.** Tracing, stepping, breakpoints and pause-on-error come
  free — `JobControl.host` already does exactly this for `RunWorker`.
- **The parts it mints are plain refs** (`source == null`, O4), so opening needs no Kotlin and no new
  SPI: `FileDataOpener`, built in DS2, reads them through the same `DataOpenerLookup` every reader uses.
- **The fused single-object shape stays available** for JDBC and friends (a source that also implements
  `DataOpener`), where resolution and reading genuinely share a connection (§4.4). This session adds an
  option; it removes nothing.
- **The dated case becomes a shipped example Script**, not a ninth Kotlin class — see Pre-resolved 1 for
  why it is expected to be a *one-step* Script.

## Dependencies & coordination

- **DS2** — `DataSource` / the initial `DataContext`, `FileDataOpener` / `DataOpenerLookup`,
  `DataSourceConventions`. **DS3** — `ReadWorker` (`emit: units` is the no-code way to get the unit lane)
  and `WorkerDataContext`. **DS5** — `ReadPartWorker` (the child Job's reader). **DS7** — the named
  `JobControl.host` overload, generic `RunWorker.arguments`, writer parameter substitution and the writer half of
  the round-trip.
- **DS1's construction helpers are what make the Script expression readable** (`DataUnit.of`,
  `DataPart.ofPath`). **DS1b's visibility predicate is what makes them nameable** from a Script
  expression at all — without it `DataUnit` is not in scope's type vocabulary. Both are hard
  prerequisites for the example, not just for the plan's prose.
- **`${…}` substitution and per-unit binding landed in DS7.** The outer `RunWorker.arguments` binds
  `date: attributes["date"]`; the child writer resolves `${date}` from that named Job parameter through
  the shared helper. This session only reuses the mechanism.
- **Reference data as a lookup** (§5.7 `LookupWorker`) is *not* built; the `reference` role is read by a
  second `ReadPartWorker` inside the child Job in the fixture — the idiom the docs teach (§5.6 b).

## Current-state findings (anchors verified 2026-08-21)

- **Named `JobControl.host` landed in DS7.** This session adds `DataContext.host` with its first caller:
  `WorkerDataContext` delegates to that overload, while `DesignDataContext` throws the explicit
  requires-a-run failure below.
- **Design-time hosting does not exist cheaply.** `ServerLogicController` is the *interactive* run
  controller (submit / status / one visible run); driving it from a detached card action would collide
  with the user's own run. So `DesignDataContext.host` throws (this session), and this source's card says so via
  `DataSourceActions` returning the failure text.
- **`ParameterBinding` / `JobParameters`** — typed parameters (String / Boolean / Int / Long / Double
  defaults; a `DataUnit` parameter arrives as a run argument, `ParameterDefaultDefiner` is not involved).
  A Script's declared parameters are matched **by name** against the tuple's component names.
- **Script's result shape** — `ResultStep` is `return`: it always ends the Script and yields its value
  (the SIR change, landed 2026-08-06). So a resolution Script is literally *one step*.
- **`kotlinx-datetime 0.8.0`** is on the classpath (toolchain pins); `java.time.LocalDate` is also
  available to a JVM-side expression. Both are public and therefore nameable after DS1b. Calendar dates
  only — never instants, no zone logic.
- **`FileDataOpener` / `DataOpenerLookup`** (DS2) — open + parse + `Tabular` shape + skip + close, over a
  plain `DataRef` whose id is a path. This session is its second customer, which is what building it
  as a shared opener was for.

## Pre-resolved questions

1. **The dated example is one Script step, and that is the demo.** A date range → units is a single
   Kotlin expression, so no loop or accumulator is needed:

   ```kotlin
   // Script `Dated Sales`, parameters: from: String, to: String; one Result step:
   generateSequence(LocalDate.parse(from)) { it.plusDays(1) }
       .takeWhile { it <= LocalDate.parse(to) }
       .map { date ->
           DataUnit.of(
               mapOf("date" to date.toString()),
               listOf(
                   DataPart.ofPath(DataRole.main,        "C:/data/sales/$date/main.csv"),
                   DataPart.ofPath(DataRole("reference"), "C:/data/ref/$date.csv")))
       }
       .toList()
   ```

   ⚠ **This expression is the session's real gate.** If it does not compile — because a helper is
   missing, a type is not nameable, or the Script parameter scope does not reach it — fix *that*, and if
   the fix is not small, fall back to Pre-resolved 6.
2. **How arguments reach the logic — named, and only named.** `LogicDataSource` declares
   `arguments: List<String>`; `resolve` builds `TupleValue(arguments.map { TupleComponentValue(it,
   context.argument(it)) })` and calls `context.host(instructions, tuple)`. The Script declares parameters
   with those **same names** (`from`, `to` in the example) — one convention, no map, no positional
   special case. A declared argument the Script does not declare, or vice versa, is a clear run
   failure naming both lists (CC-08).
3. **Return contract.** `mainComponentValue()` must be a `List<DataUnit>` (or an `Iterable` of them);
   anything else fails with a message naming the actual type and the expected one (CC-08). A null or
   empty result is a legal empty manifest, not an error. Diagnostics: none in v1 (the Script decides for
   itself what to include — Pre-resolved 5).
4. **Design-time `resolve`.** Through `DataSourceActions`, `DesignDataContext.host` throws and the action
   returns an `ExecutionFailure` whose message says *why* ("resolving this source runs its logic, which
   needs a run"). The DS4 card renders it as text. **Do not** wire a hidden run behind the card — §6.2's
   discipline, and it would collide with the interactive controller. Follow-up if it is wanted: an
   explicit "Resolve (runs the logic)" affordance on a dedicated route, planned separately.
5. **Missing files** — `missing: skip | fail` is the *file source's* knob (DS2). A resolution Script
   decides for itself, in the expression, whether to filter absent paths; the shipped example filters
   with a comment showing both. Do **not** add a `missing:` attribute to `LogicDataSource` — its query is
   arbitrary code, and a knob that only sometimes applies is worse than none.
6. **Fallback: a Kotlin `DatedPathDataSource`** (O16). If Pre-resolved 1's expression cannot be made to
   work in a session, ship the Kotlin source instead — `pattern` / `parts` / `from` / `to` / `step` /
   `missing` (resolve-only, plain refs) — and record `LogicDataSource`
   as the remainder. That is a worse outcome (a ninth class, and the extension point unproven), so spend
   the session's risk budget on the gate first.
7. **Does a written output become readable?** Out of scope. A `LogicDataSource` whose logic returns refs
   to previously written paths does it trivially, with no new feature — note it as the answer if asked
   (DS7 Pre-resolved 8 points here).
8. **Fingerprints.** The Script mints refs without `size` / `modified`; the opener reads them fine and
   DS6's cache simply does not cache them (no fingerprint → no cache). A later helper
   (`DataPart.ofPathStamped`) could stat the file from the Script — not now.

## Step-by-step implementation

1. **Gate first (Pre-resolved 1).** Write the Script by hand in a temp project and compile it. If it
   compiles, everything below is straightforward; if not, the session's shape is decided by what broke.
2. **`DataContext.host`** (common API + jvm implementations): `WorkerDataContext` delegates to DS7's
   named `JobControl.host`; `DesignDataContext` throws the explicit requires-a-run failure.
3. **`LogicDataSource`** (jvm, `…/server/objects/datasource/`, `@Reflect`, **`DataSource` only**):
   `instructions: {is: ObjectLocation, nullable: true, by: Nominal, editor: SelectLogicEditor, summary:
   ReferenceLinkAttributeView}` (the `RunWorker.instructions` shape verbatim), `arguments: []`, plus the
   declared-schema attribute DS6 added to every source. `resolve` per Pre-resolved 2–3.
4. **Notation + ribbon**: the archetype in `data-source-jvm.yaml` (body defaults for every attribute);
   a `LogicDataSourceTool` in `JobGroup_Data`; the `editor:` key and its registration together (`SelectLogicEditor` already exists and is
   registered, so this one is free).
5. **The shipped example**: a `Dated Sales` Script under the test notation, and — **only if the user
   wants it discoverable** — as a project archetype candidate. Ship it as a *fixture* by default; a
   shipped user-visible example is a separate call.
6. **Fixture: the ETL round-trip** over a temp tree of `2026-01-01..03/main.csv` + `ref/<date>.csv`.

## Tests

1. **`LogicDataSourceTest`** (jvm) — with a fake `DataContext` whose `host` records the tuple and returns
   a canned `TupleValue`: `resolve` forwards the declared `arguments` **by name** as tuple components; a
   non-list main result fails naming the actual type; an empty result is an empty manifest; the refs it
   mints are plain and **`FileDataOpener` reads one identically to a `FileDataSource`-minted ref over the
   same file** (the shared-opener pin — one test that both sources' refs read identically).
2. **`DataSourceActionsTest`** addition — `action=resolve` on a `LogicDataSource` returns the "requires a
   run" failure with a message a user can act on, not a stack trace.
3. **`JobDatedEtlNotationTest`** (jvm, engine-level) — the §7.1 worked shape end to end:
   outer Job (`parameters: from, to`; `sources/dated: LogicDataSource`) → `ReadWorker(source: dated,
   emit: units)` → `RunWorker(arguments: {date: 'attributes["date"]'})` over a per-day child Job whose
   parameters are `unit: DataUnit, date: String` → child: `FormulaSourceWorker("unit")` →
   `ReadPartWorker(role: main, attributes: columns)` and a second `ReadPartWorker(role: reference)`, a
   `FormulaWorker` or two, `ExportWriterWorker(path: "out/${date}.csv", result: main)` with the child's
   declared `results: {main: DataRef}` → outer
   `ResultSinkWorker(keep: all)` collects three `DataRef`s. Assert: three child runs, three output
   files, each equal to the per-day transform of its input. **This is the arc's acceptance test** — it
   exercises DS1 (model), DS1b (types), DS2 (SPI + opener), DS3 (reader), DS5 (`ReadPartWorker` + child
   self-opening), DS7 (yield) and this session at once, with **no expression opening anything**.
4. **The example Script itself** compiles and returns three units for a three-day window — the
   Pre-resolved 1 gate, as a permanent regression.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test :kzen-auto-common:jvmTest :kzen-auto-common:jsTest
   :kzen-auto-js:compileKotlinJs`.
2. Browser smoke: insert a **Logic** source, pick the `Dated Sales` Script, fill `arguments: [from, to]`;
   **Resolve** shows the "requires a run" message (the honest one, not an error); a `Read (units)` →
   `Run` (child Job) → Summary of the child's output over a 3-day window; then edit one line of the
   Script and re-run to show that a source is now *authored*, not compiled.
3. As-built → analysis **§13**, including: the Pre-resolved 1 gate's outcome, whether the shipped
   example became user-visible, and the O12 note (this source holds no connection, so the
   `DesignSession` question stays open for the first JDBC/API source).
   **Close the arc:** analysis §12's build order gets its as-built ticks and the doc's status line
   changes from "design exploration" to "landed — see §13".

## Risks & gotchas

- **The gate is real.** Pre-resolved 1 is the difference between "a user can author a source" and "we
  shipped one more class". Do it first, and let it decide the session.
- **Named, not positional, not a map.** One convention — names — and the Script declares the same
  names. Do not "also support" a positional map: two call shapes is how the mismatch starts.
- **No design-time resolve** — and no hidden run behind the card. The card's message is the feature.
- **Timezone** — dates are calendar dates (`LocalDate`), never instants; no zone logic anywhere, in the
  source, the example, or the fixture.
- **Do not let this source grow a "lookup" feature** — reference data as a lookup is `LookupWorker`
  (§5.7), demand-driven.
- **Do not give this source an `open`.** Its refs are plain and `FileDataOpener` reads them; if it turns
  out the opener does not fit, that is a finding about DS2's opener, not a reason for a second reader.
- **Do not mint a `DataSourceId`** for it — it is not provider-bound (O15).

## Out of scope (this session)

- JDBC / HTTP / S3 sources (each forces O12, a `DataOpener` implementation, `DataSourceId` minting, and
  the extension-points §2.1 editor vocabulary).
- A design-time run route for resolution previews — named as a follow-up, planned separately.
- `LookupWorker`, role fan-out (J6), column types, Report retirement (J4), the `DataSources` document
  (O21).
