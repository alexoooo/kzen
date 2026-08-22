# DS8 — `LogicDataSource` + the dated-path example — implementation plan

> **Status: ready to execute.** Session 8 of the **DS** arc; rationale
> [`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)
> **§4.4** (authoring a source without Kotlin — the D5 design change), §1 (parameterized resolution,
> multi-part units), §3.4 (flat list of self-describing units), §4.2–4.3 (source/format axes;
> self-opening refs), §5.6 (child Logic per unit), §8.1 (resolve once), O16. Constituent plan: **—**
> (analysis doc is the record; delete on landing, as-built → analysis **§14**). Depends on **DS2, DS3,
> DS5** (DS7 for the full ETL round-trip). Anchors verified 2026-08-21. **Reframed 2026-08-21b** by the
> second-pass review — the previous plan was a hand-written Kotlin `DatedPathDataSource`. Sized **M**;
> kzen-auto-jvm + yaml + one notation example. Ledger row 58. **Closes the arc.**

## Scope & goal

Ship the extension point, and use the dated case to prove it:

```
LogicDataSource(
  instructions: <Script | Flow | Job>     # the resolution logic; main result: List<DataUnit>
  arguments:    [from, to]                # names forwarded from DataScope.argument(name)
)
    units(scope)        = scope.host(instructions, argumentMap).mainComponentValue() as List<DataUnit>
    items(scope, part)  = FlatFileItems over the ref (DS2's shared opener)
    schema / itemType   = the declared-schema route (DS6), else the shared opener's bounded read
```

- **A user authors resolution in the product.** Tracing, stepping, breakpoints and pause-on-error come
  free — `JobControl.host(instructions, input)` already does exactly this for `RunWorker`.
- **The parts it mints are plain refs** (`source == null`, O4), so opening needs no Kotlin and no new
  SPI: `FlatFileItems`, lifted in DS2, reads them.
- **The fused single-object shape stays available** for JDBC and friends, where resolution and reading
  genuinely share a connection (§4.4). This session adds an option; it removes nothing.
- **The dated case becomes a shipped example Script**, not a ninth Kotlin class — see Pre-resolved 1 for
  why it is expected to be a *one-step* Script.

## Dependencies & coordination

- **DS2** — `DataSource` / `DataScope` (including `host`), `FlatFileItems`, `DataSourceConventions`, the
  `DataSources` document. **DS3** — `ReadWorker` (`emit: units` is the no-code way to get the unit lane).
  **DS5** — `items(...)` in expressions and the child-Job self-opening path. **DS7** — the writer half of
  the round-trip.
- **DS1's construction helpers are what make the Script expression readable** (`DataUnit.of`,
  `DataPart.ofPath`). **DS1b's visibility predicate is what makes them nameable** from a Script
  expression at all — without it `DataUnit` is not in scope's type vocabulary. Both are hard
  prerequisites for the example, not just for the plan's prose.
- **`${…}` substitution** — unit attributes are text (§3.5), so a writer's `out/${date}.csv` is direct
  substitution; J4's `${group}` convention must use the **same** helper. One
  `PathPatternSubstitution` in commonMain, used by the writers and available to a source. (The dated
  *Script* does not need it — a Kotlin expression interpolates natively — but the writers do, and this is
  the session that has a reason to write it.)
- **Reference data as a lookup** (§5.7 `LookupWorker`) is *not* built; the `reference` role is read by a
  second `ExpandWorker` inside the child Job in the fixture — the idiom the docs teach (§5.6 b).

## Current-state findings (anchors verified 2026-08-21)

- **`JobControl.host(instructions: ObjectLocation, input: Any?): TupleValue`** binds `input` as the
  child's **first declared parameter** (the single-positional convention shared with a Script Run step
  and a Flow Run-Logic vertex) and returns its output tuple. `RunWorker` reads
  `result.mainComponentValue()`. **There is no named-argument form**, which is why Pre-resolved 2 passes
  a map.
- **Design-time hosting does not exist cheaply.** `ServerLogicController` is the *interactive* run
  controller (submit / status / one visible run); driving it from a detached card action would collide
  with the user's own run. So `DesignDataScope.host` throws (DS2), and this source's card says so.
- **`ParameterBinding` / `JobParameters`** — typed parameters (String / Boolean / Int / Long / Double
  defaults; a `DataUnit` parameter arrives as a run argument, `ParameterDefaultDefiner` is not involved).
- **Script's result shape** — `ResultStep` is `return`: it always ends the Script and yields its value
  (the SIR change, landed 2026-08-06). So a resolution Script is literally *one step*.
- **`kotlinx-datetime 0.8.0`** is on the classpath (toolchain pins); `java.time.LocalDate` is also
  available to a JVM-side expression. Both are public and therefore nameable after DS1b. Calendar dates
  only — never instants, no zone logic.
- **`FlatFileItems`** (DS2 step 4) — open + parse + `flatHeader` + skip + close + constrain-once, over a
  `DataRef` whose id is a path. This session is its second customer, which is what the DS2 lift was for.

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
2. **How arguments reach the logic.** `LogicDataSource` declares `arguments: List<String>`; `units`
   builds `LinkedHashMap(name → scope.argument(name))` and passes it as the single positional input. The
   logic declares **one** parameter (a `Map<String, Any?>`) — or, for the common two-argument case, the
   source may pass a single scalar when `arguments` has exactly one entry, so a one-parameter Script
   stays natural. Document both forms in the archetype KDoc; do not invent a named-argument protocol
   here (that is a `JobControl.host` change and belongs to whoever needs it).
3. **Return contract.** `mainComponentValue()` must be a `List<DataUnit>` (or an `Iterable` of them);
   anything else fails with a message naming the actual type and the expected one (CC-08). A null or
   empty result is a legal empty manifest, not an error.
4. **Design-time `resolve`.** `LogicDataSource`'s `DetachedAction` returns an `ExecutionFailure` whose
   message says *why* ("resolving this source runs its logic, which needs a run"). The DS4 card renders
   it as text. **Do not** wire a hidden run behind the card — §6.2's discipline, and it would collide
   with the interactive controller. Follow-up if it is wanted: an explicit "Resolve (runs the logic)"
   affordance on a dedicated route, planned separately.
5. **Missing files** — `missing: skip | fail` is the *file source's* knob (DS2). A resolution Script
   decides for itself, in the expression, whether to filter absent paths; the shipped example filters
   with a comment showing both. Do **not** add a `missing:` attribute to `LogicDataSource` — its query is
   arbitrary code, and a knob that only sometimes applies is worse than none.
6. **Fallback: a Kotlin `DatedPathDataSource`** (O16). If Pre-resolved 1's expression cannot be made to
   work in a session, ship the Kotlin source instead — `pattern` / `parts` / `from` / `to` / `step` /
   `missing` as the previous draft specified — and record `LogicDataSource` as the remainder. That is a
   worse outcome (a ninth class, and the extension point unproven), so spend the session's risk budget
   on the gate first.
7. **Does a written output become readable?** Out of scope. A `LogicDataSource` whose logic returns refs
   to previously written paths does it trivially, with no new feature — note it as the answer if asked
   (DS7 Pre-resolved 5 points here).

## Step-by-step implementation

1. **Gate first (Pre-resolved 1).** Write the Script by hand in a temp project and compile it. If it
   compiles, everything below is straightforward; if not, the session's shape is decided by what broke.
2. **`PathPatternSubstitution`** (commonMain; `${name}` over a `Map<String,String>`, unknown name → error
   naming it — CC-08) + adopt it in `ExportWriterWorker` / `CsvWriterWorker`'s path attributes so J4
   inherits one helper.
3. **`LogicDataSource`** (jvm, `…/server/objects/datasource/`, `@Reflect`, `DetachedAction`):
   `instructions: {is: ObjectLocation, nullable: true, by: Nominal, editor: SelectLogicEditor, summary:
   ReferenceLinkAttributeView}` (the `RunWorker.instructions` shape verbatim), `arguments: []`, plus the
   `id` and declared-schema attributes every source has. `units` per Pre-resolved 2–3; `items` /
   `schema` delegate to `FlatFileItems`; `itemType` from the declaration.
4. **Notation + ribbon**: the archetype in `data-source-jvm.yaml` (body defaults for every attribute);
   a `LogicDataSourceTool` in `JobGroup_Data`; the `editor:` key and its registration together (C5 —
   `SelectLogicEditor` already exists and is registered, so this one is free).
5. **The shipped example**: a `Dated Sales` Script under the test notation, and — **only if the user
   wants it discoverable** — as a project archetype candidate. Ship it as a *fixture* by default; a
   shipped user-visible example is a separate call.
6. **Fixture: the ETL round-trip** over a temp tree of `2026-01-01..03/main.csv` + `ref/<date>.csv`.

## Tests

1. **`PathPatternSubstitutionTest`** (commonTest) — substitution, unknown name error, `$` escapes,
   ordering irrelevance.
2. **`LogicDataSourceTest`** (jvm) — with a fake `DataScope` whose `host` returns a canned
   `TupleValue`: `units` forwards the declared `arguments` by name into the map; a single declared
   argument passes the scalar form; a non-list main result fails naming the actual type; an empty result
   is an empty manifest; `items(part)` over a plain ref equals `FileDataSource.items` over the same file
   (**the shared-opener pin** — one test that both sources read identically).
3. **`LogicDataSourceDetachedTest`** (jvm) — `action=resolve` returns the "requires a run" failure with
   a message a user can act on, not a stack trace.
4. **`JobDatedEtlNotationTest`** (jvm, engine-level) — the §7.1 worked shape end to end:
   outer Job (`parameters: from, to`) → `ReadWorker(source: dated, emit: units)` → `RunWorker` over a
   per-day child Job → child reads `items(unit.part("main"))`, a second `ExpandWorker` reads the
   `reference` role, a `FormulaWorker` stamps `date` from the unit, `ExportWriterWorker(path:
   "out/${date}.csv", result: output)` → outer `ResultSinkWorker(keep: all)` collects three `DataRef`s.
   Assert: three child runs, three output files, each equal to the per-day transform of its input.
   **This is the arc's acceptance test** — it exercises DS1 (model), DS1b (types), DS2 (SPI + opener),
   DS3 (reader), DS5 (expressions + child self-opening), DS7 (yield) and this session at once.
5. **A/B of the two routes** — the same `LogicDataSource` consumed by `ReadWorker(emit: units)` and by
   `FormulaSourceWorker("dated.units()")` yields the identical unit lane.
6. **The example Script itself** compiles and returns three units for a three-day window — the
   Pre-resolved 1 gate, as a permanent regression.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test :kzen-auto-common:jvmTest :kzen-auto-common:jsTest
   :kzen-auto-js:compileKotlinJs`.
2. Browser smoke: insert a **Logic** source, pick the `Dated Sales` Script, fill `arguments: [from, to]`;
   **Resolve** shows the "requires a run" message (the honest one, not an error); a `Read (units)` →
   `Run` (child Job) → Summary of the child's output over a 3-day window; then edit one line of the
   Script and re-run to show that a source is now *authored*, not compiled.
3. As-built → analysis **§14**, including: the Pre-resolved 1 gate's outcome, whether the shipped
   example became user-visible, and the O12 note (this source holds no connection, so the
   `DesignSession` question stays open for the first JDBC/API source).
   **Close the arc:** analysis §12's build order gets its as-built ticks and the doc's status line
   changes from "design exploration" to "landed — see §14".

## Risks & gotchas

- **The gate is real.** Pre-resolved 1 is the difference between "a user can author a source" and "we
  shipped one more class". Do it first, and let it decide the session.
- **`host` is single-positional** — do not quietly grow a named-argument protocol on `JobControl.host`
  to make this nicer. The map is the honest shape until someone else needs names too.
- **No design-time resolve** — and no hidden run behind the card. The card's message is the feature.
- **Timezone** — dates are calendar dates (`LocalDate`), never instants; no zone logic anywhere, in the
  source, the example, or the fixture.
- **Do not let this source grow a "lookup" feature** — reference data as a lookup is `LookupWorker`
  (§5.7), demand-driven.
- **Do not re-lift `FlatFileItems`** — DS2 already extracted it precisely so this session consumes it.
  If it turns out not to fit, that is a finding about DS2's extraction, not a reason for a second copy.

## Out of scope (this session)

- JDBC / HTTP / S3 sources (each forces O12 and the extension-points §2.1 editor vocabulary).
- A design-time run route for resolution previews — named as a follow-up, planned separately.
- `LookupWorker`, role fan-out (J6), column types, Report retirement (J4).
