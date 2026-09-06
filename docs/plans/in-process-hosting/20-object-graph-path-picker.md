# HS20 — Design-time object-graph path picker

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS19.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E8 picker and E7 recursive shape.

## Outcome and anchors

kzen-auto-js generic attribute editors, upstream contract traversal, path Worker notation.

## Work

1. Add the declarative path editor over the upstream contract. Offer scalar leaves, list/map unnesting and aliases through the established generic editor contribution mechanism.
2. Render recursive references collapsed and expand only on demand; do not execute the source or call getters to populate the picker.
3. Show output names and validation errors from the authoritative runtime binding rules. Preserve saved path entries on editing/reopen and handle an upstream shape change with a named invalid path.
4. Use ordinary plugin object contracts, with no plugin-provided JavaScript and no ITCH-specific picker code.

## Verification and exit criteria

Compile JVM/JS and browser-test a recursive fixture contract: expand an order/execution back-reference, select paths, rename an output, save/reopen, encounter a duplicate name and an upstream invalidation. Verify the editor's offered leaves match the runtime contract and the Job executes the chosen paths.

## Handoff

E8 closes after runtime/UI checks pass. Publish/rebuild the frontend resources needed by standalone and embedded sample verification.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-auto (`kzen-auto-common` path model, `kzen-auto-js` editor + bridge channel,
notation) and kzen-lib (two contract fixes the browser check surfaced). kzen-lib rebuilt and published first;
kzen-auto built (whole suite, JVM and JS), published, kzen-project rebuilt from its own directory. No
release-train version changed. **E8 closes here** (runtime HS19, authoring HS20).

**The editor (Work 1, 4).** `PathProjectionEditor` (`kzen-auto-js`, `editor: PathProjectionEditor` on the
`paths` metadata, registered in `job-js.yaml`) is an ordinary `AttributeEditor` contribution — no plugin JS,
no model-name checks. It renders the chosen entries (`PathProjectionEntryRow`: path → output name, a
debounced alias field, remove) above a tree of what the upstream contract offers: `ContractPathTree`
(kzen-auto-common) lists a record's fields, a list or map field opens into its `[*]` element (a scalar
element is itself the leaf; a map's entry offers `key` / `value`), scalar leaves are added with a click,
non-scalar leaves (opaque values) are shown but not selectable. Edits apply the canonical builders added
to `PathProjectionSpec` (`addCommand`, `removeCommand`, `aliasCommand` — a bare path string, or a
`{path, as}` map when aliased), so the notation is exactly what the runtime reads.

**Recursion and provenance (Work 2).** The tree is derived one level at a time through `PathBinding.resolve`,
so a recursive reference is a collapsed `↻ <definition>` node until it is opened, and the occurrence it opens
into is collapsed again; nothing executes the source — the upstream contract is the Job's server-side
validation (`JobValidator`'s static walk), read off the new `JobValidationChannel` bridge channel that
`JobController` publishes into on each fetch (the `JobSummaryStore` precedent, since attribute editors render
under the generic manager with only objectLocation + attributeName), with the upstream Worker derived from the
saved wiring (`JobChannelDerivation`).

**Names, errors, persistence (Work 3).** Output names and errors come from `PathBinding.bind` — the same code
the runtime binds with — so the editor and the run agree: a duplicate output name is reported on the later
entry naming the earlier path and the alias remedy; an upstream shape change makes a saved entry a named
invalid path ("no field 'x'; available: …"); the Worker card shows the flat output contract as soon as the
entries bind. Entries persist as notation and reopen unchanged.

**Two kzen-lib defects found by the browser check, fixed.** (1) A recursive definition carried its type but not
its members' native metadata, so expanding a reference whose definition has an opaque member (`TypeToken.
componentType.rawType`) threw "Opaque path … requires native metadata" inside the validator — `DataContract`
now carries `definitionNatives` (recorded by the resolver's describe session, applied on `child` / `expanded`,
in the codec and identity); (2) the contract-level structural assignability rejected an opaque expected member
against an opaque actual one, which a value described one level deeper than its static contract (a private
subclass such as `TypeToken.of(...)`'s) always hits — the contract overload now accepts opaque for opaque
(the native identity stays the resolver's token check; the bare type overload keeps rejecting, as its test
pins), and a referenced definition gets the same relaxation in the resolver's acceptance.
`RecursiveContractTest` gained the recursive-with-opaque-member case; the kzen-lib suite is green.

**Verification.** Compile: kzen-auto-common JVM + JS, kzen-auto-js. `PathBindingTest` (4) and
`ContractPathTreeTest` (2) on JVM and JS. Browser (my own instance on port 18090, a temp module and work
root, the built jar with the bundle; a Job `FormulaSource → Paths → Preview` whose source returns
`TypeToken<String>`, a recursive Guava class): the card showed the fields with their kinds and the recursive
`componentType` collapsed as `↻ com.google.common.reflect.TypeToken`; expanding it showed the occurrence's
fields with the next `componentType` collapsed again; adding `array` produced the entry `array → array`, the
card's contract became `Record · 1 field` and flowed to the Preview; adding the nested `componentType.array`
and aliasing it `array` reported "output name 'array' collides with array; give one of them an alias" and the
card an Error; aliasing it `inner` cleared the error (`→ inner`, `Record · 2 fields`); the saved document
held `paths: [array, {path: componentType.array, as: inner}]` and reopened unchanged. Running the Job produced
`array=false, inner=null`; editing the source to return a plain `String` showed the upstream invalidation naming
the now-invalid paths. The whole `kzen-auto-jvm` suite: 1059 tests, 0 failures (19m57s); kzen-lib published;
kzen-project build green (1m20s). Full `./gradlew build` + `publishToMavenLocal` of kzen-auto, then
kzen-project `./gradlew build`. New files staged by explicit path: `ContractPathTree` + test,
`JobValidationChannel`, `PathProjectionEditor`, `PathProjectionEntryRow`.

**Caveats.** The picker offers what the static walk knows: a dynamic upstream shows "paths bind at run
time" and no tree. The entry rows are not reorderable (order is add order; remove and re-add to move one).
