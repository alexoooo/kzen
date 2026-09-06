# HS19 — Object-graph path projection and unnesting

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS14 and HS18 (owned-object acceptance).
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E8 runtime path/schema rules.

## Outcome and anchors

kzen-auto common path notation/contract models and JVM path-projection Worker; ValueAccess and generic Worker archetypes.

## Work

1. Implement path entries with optional as aliases; default names are full dotted paths with wildcards removed. Reject duplicate names and non-scalar leaves with the specified errors.
2. Bind paths against finite recursive contracts and navigate lazily through ValueAccess. Same-list wildcard paths share an iteration; independent lists form a cross product. Validate ambiguous mixes explicitly.
3. Preserve ordinary null-intermediate rows; null/empty unnested lists yield zero rows. Map [*] exposes key/value in entries order. Implement these distinctions in one binding/evaluation path.
4. Emit detached scalar columns under E9: the callback protects native reads, projected output does not retain SymbolDay or a persistent graph view. Copy any scalar backing that would otherwise alias native storage.
5. Register through normal Worker/archetype capability mechanisms, without concrete plugin/model-name checks.

## Verification and exit criteria

Test shared versus independent wildcards, nested recursion, null/empty distinction, map key/value paths, aliases/collisions and non-scalar rejection. Compare projected scalar aggregates with direct fixture folds. Close the source after projection and prove the rows remain valid without retaining its arena.

## Handoff

Runtime E8 is partial; HS20 delivers the authoring picker. Record notation and schema contract names.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-auto (`kzen-auto-common` path model + binding, `kzen-auto-jvm` Worker + evaluator,
notation, docs). kzen-auto built (whole suite, JVM and JS), published to mavenLocal, and kzen-project rebuilt
from its own directory. No release-train version changed.

**Notation and contract names (Work 1, 5).** Worker archetype `PathProjectionWorker` (`job-worker.yaml`,
title "Paths"; class `tech.kzen.auto.server.objects.job.worker.PathProjectionWorker`) with a `paths` attribute
of type `PathProjectionSpec` (`common-document.yaml`, defined by `PathProjectionSpecDefiner` =
`PathProjectionSpec$Definer`, the `SortSpec` pattern): an ordered list whose items are a path string or a
`{path: …, as: …}` map. Model in `tech.kzen.auto.common.objects.document.job.path` (commonMain, so the picker
shares it): `ProjectionPath` (`ProjectionPathSegment.Field` / `Wildcard`; `parse`, `asString`,
`defaultOutputName` = the field names joined with `.`, wildcards dropped), `PathProjectionEntry` (path +
optional alias → `outputName`), `PathProjectionSpec`, and the binding: `PathBinding.bind(spec, upstream)` →
`PathBindingResult` (`BoundPath` with `BoundStep`s `Field` / `Elements` / `Entries` / `Key` / `Value`, the
scalar leaf type and the `iterationKey`; the flat output `DataContract` of nullable scalars in entry order;
or every `PathBindingError`). Errors as specified: unknown field (lists the available ones), `[*]` on a
non-container, `key` / `value` misuse after a map's `[*]`, a non-scalar leaf ("use a Formula or Filter"), and
an output-name collision naming both paths and the alias remedy. Registration is the ordinary archetype +
attribute-type mechanism — no plugin or model-name checks anywhere (CC-17).

**Binding and evaluation (Work 2–3).** Binding walks the contract with `DataContract.child` /
`expanded()`, so a recursive reference (E7) is expanded one level per step and a recursive contract binds
finitely (`legs[*].legs[*].symbol` in the tests). `PathRowEvaluator` (jvm) navigates lazily through
`ValueAccess` (`field` / `element` / `entry` / `keyAt`, states checked before descending) over an iteration
tree keyed by wildcard prefix: paths sharing an iteration key iterate the same list / map together; distinct
keys form a cross product, a nested key iterating within its parent's element; a null or absent intermediate
yields null cells and keeps the row; an empty or null unnested list yields zero rows for the element it
belongs to (and so for the whole input element when the list is at the top); a map's `[*]` exposes `key` /
`value` in entries order. One binding/evaluation path serves the static walk (`payloadFlow` → the output
contract or the errors as the card's validation error) and the run (re-bound only when the element contract
differs from the static one, a dynamic lane).

**Detached rows under E9 (Work 4).** Every cell is rendered to text inside the callback and the row is
emitted as `JobDataValues.projectedRecord` (a `FlatFileRecord` with per-cell states) — a fresh record with no
native root, so a row never aliases the element's storage and inherits no owner; the owned upstream element
closes when the callback returns. `DataReadCore.scalarText` is the one scalar rendering the reader and the
projection share.

**Verification.** `PathBindingTest` (commonTest, 4: parsing and default names, lists / maps / recursion bound
finitely with nullable leaves and iteration keys, aliases and collisions, the rejection messages) — run on
JVM and JS; `PathProjectionWorkerTest` (jvm, 9): shared wildcards iterate together, independent wildcards
cross-product (2 × 3 = 6 rows), nested wildcards within the parent with an empty inner list yielding no rows
for that parent, null intermediate keeps the row, null / empty list yields zero rows while the element still
projects without that path, map key / value in entries order, aliases and collisions (static error and run
failure), non-scalar leaf rejected pointing at Formula, the static contract of nullable scalar leaves;
`PathProjectionRouteTest` (1, real run): owned orders → `symbol, executions[*].price, executions[*].qty` →
sink: one row per execution, the projected notional equals a direct fold over the same objects, every order
closed once after its projection, the rows readable afterwards. The whole `kzen-auto-jvm` suite: 1059 tests, 0 failures; full
`./gradlew build` + `publishToMavenLocal` of kzen-auto, then kzen-project `./gradlew build`. New files staged
by explicit path: the nine `path` model files and their test, `PathRowEvaluator`, `PathProjectionWorker`,
`PathProjectionWorkerTest`, `OwnedOrder`, `PathProjectionRouteTest`, `owned-projection-test.yaml`.
`docs/architecture.md` § 1 Job updated.

**Outstanding for HS20.** The `paths` attribute has no editor yet (the card renders it through the generic
editor's "type not supported" fallback); the picker and the notation command builders for the `paths` list
are HS20's. The E8 verification over the sample plugin's ITCH domain (`Order → Execution → Trade`) is
exercised here with an equivalent in-tree fixture; the external-sample run is HS22's.
