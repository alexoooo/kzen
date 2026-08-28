# Data-model plans — second review (2026-08-28)

> **Scope: the revision landed in commit `3d5de40` in response to [`review.md`](review.md).** Same rules as the
> first review: plan sequencing, sizing, anchors and conventions only; the design is not re-litigated. Part A
> records the disposition of each first-review finding; Part B lists what the revision introduced or left open.
> Anchors are class / file / section names (CC-20).

## A. Disposition of the first review

| # | Finding | Disposition | Where |
|---|---|---|---|
| 1 | DM3 deleted the `Tabular \| Payload` runtime dispatch before DM7 replaced the item type | **Resolved — option (b).** An explicit, internal `LegacyCursorItemKind` on the cursor/opener, confined to `DataReadCore` / `ReadWorker`, kept off the wire and client, with DM7b as sole deletion owner. The added `SchemaCache` poisoned-entry test and the `shape == null` inventory before making `DataCursor.shape` non-null both close gaps the first review named. | DM3 preconditions, steps 5 and 7, proof, exit; DM7b step 2 and exit |
| 2 | DM7 and DM9 were not one-session plans | **Resolved.** DM7 → DM7a (static lane + façade) / DM7b (channels, cursors, column Workers) / DM7c (Formula, sinks, hosts, gate, deletion); DM9 → DM9a (additive kzen-lib engine + tuple adapter) / DM9b (kzen-auto migration, bridge kept) / DM9c (deletion + downstream rebuild). Every session ends green at a named bridge, and DM7c runs the gate *before* deleting the façade, so the stop rule now has a real fallback. | `07a`–`07c`, `09a`–`09c`, README "Arc-wide stop rules" |
| 3 | J-arc collision named but not decided | **Resolved.** Ledger reordered: J5a → DM1–DM7c → DM8–DM11 → J5b (re-specified against `DataValue`) → J4 → J9; J6 demand-driven after DM7c; dependency rules 1–4 rewritten; `#` column declared a stable identifier. | `2026-07-25_master-plan.md` ledger and "Dependency rules"; README "Authoritative execution order" |
| 4 | No constituent plan / tracker for the arc; directory tier undocumented | **Partly resolved.** `README.md` now exists as the constituent plan (tracker, lifecycle, archive-not-delete rule, publication rule, stop rules). Two pieces are still missing — see B1 and B2. | `README.md` |
| 5a | Second `JobControl.host(ObjectLocation, Any?)` overload unlisted | **Resolved.** Named in DM8's inventory and migrated explicitly in DM9b step 2. | DM8 inventory step 1; DM9b step 2 |
| 5b | `IfStep.joinBranchTypes` unlisted as an existing join consumer | **Resolved.** DM10 step 1 inventories it; step 7 pins its rules and forbids silently replacing it with `DataTypeAlgebra.join`. | DM10 steps 1, 7 |
| 5c | `DataSchemaDocument.shape()` "parses then discards" overstated | **Resolved** in both the design (§2 bullet, §14.5 step 2, gate item 2) and DM3 step 4. | analysis §2, §14.5, §15; DM3 step 4 |
| 5d | Plugin-loader identity and transitive-dependency check-first | **Resolved.** DM5 verifies `ValueAccess` identity through `ClassLoaderHandle` / `dynamicParentClassLoader()` before taking the dependency, and records the *measured* classpath delta rather than a guessed list. | DM5 preconditions, step 5 |
| 5e | Nullable `DataCursor.shape` call sites unlisted | **Resolved.** DM3 step 5. | DM3 |
| 6 | Downstream blast radius (`SampleExtensionTest`, sample plugin) | **Resolved.** DM5 step 8 and proof; DM7c preconditions and step 3. | DM5, DM7c |

## B. Findings on the revised plans

### B1. The master plan's "Constituent plans (the live set)" table has no data-model row

The ledger rows say `data-model · DMx` in their "Plan · phase" column, but the live-set table — the one place
that maps a plan ID to its document and open phases — still lists only J, E, DA/SH, FL, C and CX. A reader
following the ledger's convention cannot resolve `data-model` to `docs/plans/data-model/README.md`. The J row's
scope text ("carries the `JobMessage` element-model contract") is also now a contract DM7c deletes.

**Disposition:** add a row `**DM** | data-model/README.md | Unified data model — type/value/binding foundation and
per-flavour cutovers | DM1–DM11 (DM12/DM13 gated)`, and amend the J row's scope to say its element-model contract is
superseded by the DM arc after DM7c.

### B2. `AGENTS.md`'s plans convention still describes three tiers

The umbrella guide's "Plans directory convention" names `docs/plans/<date>_*.md`, `docs/plans/next/` and
`docs/plans/sprint-*/`. `docs/plans/data-model/` — a directory holding a README-as-constituent-plan plus one
file per session — is a fourth shape, and its lifecycle (archive the whole directory with the sprint record; never
delete it as a `next/` elaboration) lives only inside the README. The first review asked for one line in
`AGENTS.md`; it was not added.

**Disposition:** one sentence in `AGENTS.md`'s plans convention: `docs/plans/<arc>/` is a multi-session arc whose
`README.md` is the constituent plan and whose numbered files are its session elaborations; archive the directory,
do not delete it.

### B3. The `◇` status glyph is undefined

DM12 / DM13 use `◇` in both trackers. The master ledger's other glyphs (`☐`, `☑`, `⊘`, `◪`) are established by
use but there is no legend, and `◇` is new. The README tracker spells it out inline ("◇ consumer-gated") — the
ledger does not.

**Disposition:** define `◇ = gated, not schedulable until the named gate opens` once in the ledger preamble.

### B4. `docs/plans/next/` is now stale on J4 and J5

- `next/README.md` "Not elaborated — and why" still says J4 is "now after DS3 / DS6 / DS7"; the ledger now puts
  it after DM7c and J5b.
- `next/J5_perf-headless.md` still carries "Session A = steps 1–3, Session B = steps 4–8" with `JobMessage` /
  `FlatView` pooling and batch sketches. The ledger and README say J5b's carrier assumptions are stale after DM7c
  and must be rewritten before implementation — but the elaboration itself carries no re-validation note, and
  `next/README.md`'s own convention is that a stale elaboration gets one in its header (the 2026-07-25
  re-validation precedent).

**Disposition:** add the re-validation note to `J5_perf-headless.md`'s header (J5a executable as-is; J5b
blocked on DM7c and to be re-specified against `DataValue`), and update the J4 / J5 lines in `next/README.md`.

### B5. DM7a needs a *static* column projection that DM6 does not promise

DM7a step 3 keeps `WorkerLane` as a façade whose "payload/column accessors derive through native metadata and
`ColumnProjection`". Today `WorkerLane.consumerFlatColumns()` and `boundaryType()` are **static** — computed from
`TypeMetadata` during the `JobValidator` walk, before any value exists — and the editor's lane summaries and
expression compile-checks depend on that. DM6 step 1 defines "projection descriptors/access over `DataValue`", a
runtime operation; nothing in DM6 delivers a `DataContract → ordered columns` projection, and nothing states that
the static and runtime projections must agree.

**Disposition:** name the owner. Either DM6 step 1 explicitly delivers the contract-level projection (same rules:
record fields, scalar `value`, mapping key policy, duplicate labels) with a test that the static and value
projections of one contract agree, or DM7a step 1 owns it. DM7a's proof line "façade results change only when the
canonical contract changes" is the right test and should name the static projection it exercises.

### B6. DM9b states a binding rule for the positional host overload that the design does not

DM9b step 2: "any positional convenience delegates through the first declared binding". Design §10.2 / §11.1
specify named binding against the callee schema only; the positional `host(instructions, input: Any?)` form
(DS7 as-built) has no rule in the design, and today's positional callers (`RunStep` declares `LogicType.any`
main; `ForEachItemBinding`, `ParameterBinding` build single-`main` tuples) may or may not all mean "first
declared input". DM8's inventory is where that is learned; DM9b should implement what DM8 found, not assume it.

**Disposition:** add a "positional-call disposition" column to DM8's inventory table (every
`host(instructions, input: Any?)` caller and what its callee's first declared input actually is), and change DM9b
step 2 to "bind positional calls per the DM8 disposition" — if the inventory shows every callee is single-input
`main`, the first-declared rule is the as-built verdict, recorded there.

### B7. Minor anchor and wording items

- **DM3 anchor list.** `FileDataCursor.shape` is *typed* `DataShape.Tabular`, `FileDataOpener.inspectBlocking()`
  returns it, and `ColumnListingAction` casts the `SchemaCache` entry to it. `rg "DataShape"` will find them, but
  the "re-check" list names only the interfaces (`DataOpener.inspectShape`, `DataCursor.shape`); add the three
  concrete sites since they are where the return types change.
- **DM5 step 8** hard-codes "the three sample-plugin source paths"; the count will drift. Say "every
  `kzen-sample-plugin` source referencing `FlatFileRecord` / `ReportDefiner`".
- **DM7a step 4** introduces `LegacyJobElementView` in a session whose exit keeps channels and `JobMessage`
  unchanged, so it ends the session with no caller. That is acceptable as a bridge but should be stated in
  DM7a's exit ("built, tested against one `DataValue`, no production caller until DM7b") so a later cleanup pass
  does not remove it as dead code.
- **DM9c step 5** rebuilds kzen-launcher and kzen-shell; neither references tuple or Job types, so the rebuild is
  harmless but not a proof of anything. Keep or drop — but do not list it under "Proof".
- **README "Authoritative execution order" step 3** says "DM9 is split at publication boundaries" — fine, but
  DM9a's exit ("standalone kzen-auto compile against the published artifact without source edits") is the
  actual test of that split and deserves the pointer.

## C. Overall

The revision resolves every substantive first-review finding: the DM3 ordering defect is closed with an explicit
bridge, the two oversized sessions are split at real green points, the ledger now decides the J-arc order, and the
arc has a constituent plan. What remains is convention plumbing (B1–B4) and two small ownership ambiguities
(B5, B6) that are cheaper to settle in text now than at the DM6 / DM8 session boundary.
