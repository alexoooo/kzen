# HS19 — Object-graph path projection and unnesting

> Status: not started. One implementation session. Prerequisites: HS14 and HS18 (owned-object acceptance).
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

Not executed.
