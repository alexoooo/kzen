# DM12 — first structured reader and tape backing

> **Status: consumer-gated; do not execute until one concrete reader/format is selected. One session once gated.**
> Authority: unified data model §§6.1, 7.4, 11.5, 14.5 step 7; project-data analysis retains reader policy ST11,
> ST17, and ST20.

## Gate and outcome

Select exactly one first structured format and document its boundedness, carried-schema support, duplicate-name
rules, union tags, and decode-error policy. JSON is the default recommendation because it exercises record/mapping/
listing/scalar and untagged `List<String> | String` without forcing the deferred constraint layer. If the chosen
format requires recursive named schemas, enum identity, or a richer wire grammar, stop and re-scope instead of
smuggling those features into this session.

The result is a streaming structural-tape `ValueAccess` whose emitted `DataValue`s obey reachability, concrete
runtime typing under dynamic shapes, and the chosen reader policies.

## Implementation

1. Re-read the project-data analysis and current `DataSource`/`DataOpener`/`DataCursor` implementation; record the
   chosen reader and policy decisions in its owning document.
2. Measure parser slot/tape retention under actual cursor advance, batching, close, cancellation, and migration.
   Copy/detach before emission if needed; do not introduce leases unless the source measurably cannot meet the v1
   reachability rule at acceptable cost.
3. Implement one tape-backed `ValueAccess` with stable shared contracts and position tokens. It must be tree-shaped
   unless it exposes an explicit identity capability designed here.
4. Resolve shape by the declared/carried/provider/inferred/runtime ladder. Every present runtime node reports a
   concrete type; heterogeneous inference joins to `Dynamic`, never an inferred union.
5. Apply ST17 decode policy before emitting values, with source/unit/record/path diagnostics. Do not add a universal
   `Invalid` state.
6. Decode declared unions: untagged encodings use unique selection and construct one union root; external tags map to
   `VariantId` then call `validateVariant`. No first-match selection or discriminator layout in `DataType`.
7. Integrate through the existing source opener and Job path without a format-specific carrier.

## Proof and exit

- Traverse equivalent literal/tape/native records identically; cover dynamic concrete nodes, sample coverage,
  malformed input policy, duplicate fields, union selection/ambiguity/external tag, bounds, cancellation, and values
  read after cursor close.
- Benchmark against eager tree materialization and record retained bytes/allocations. Reject eager universal copying
  unless the measured source is bounded and the product explicitly chooses it.
- Run focused reader/source/Job tests and full kzen-auto build.
- Exit with no retention API unless the measurement forced a separately reviewed lease design.
