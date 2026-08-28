# DM1 — structural type contract and common algebra

> **Status: ready after plan ratification. One implementation session.** Authority:
> [`docs/analysis/2026-08-27_data-model.md`](../../analysis/2026-08-27_data-model.md) §§4, 4.2–4.7, 12.1,
> 14.5 step 1, and 15 “Semantic model.” This file sequences that contract; it does not restate or alter it.

## Outcome

`kzen-lib-common/commonMain` owns the frozen, client-visible structural vocabulary and a deterministic structural
algebra. Every type case has canonical `ExecutionValue` lowering, decoding, and digest behaviour. Native metadata
is aligned beside the structural tree and cannot affect structural equality or its digest.

## Preconditions and coordination

- Before code starts, add DM1–DM13 as rows in `docs/plans/2026-07-25_master-plan.md`; the current ledger predates
  this model. Do not silently execute this arc outside the ledger.
- Read `../kzen-lib/AGENTS.md` and `../kzen-lib/docs/architecture.md` in the execution session, then re-check all
  anchors below. No release-train version bump (CC-14).
- Package the new cluster under a dedicated `tech.kzen.lib.common.exec.data` subtree, split by `type`, `problem`,
  and `snapshot` as the cluster grows (CC-06/CC-15). Do not place the vocabulary in kzen-auto's existing
  `common/data` package.
- `ExecutionValue` remains the detached tree. Do not rename it or broaden its grammar in this session.

## Current anchors to re-verify

- `kzen-lib-common/.../exec/ExecutionValue.kt` and `ExecutionValueSerialization.kt` — existing tree, wire envelope,
  and digest precedent.
- `kzen-lib-common/.../model/structure/metadata/TypeMetadata.kt` — native metadata and current lowering.
- `kzen-lib-common/.../exec/logic/model/LogicType.kt` — current nominal declaration wrapper; not removed yet.
- `ExecutionValueTest`, `ExecutionValueSerializerTest`, and `TypeMetadataTest` — colocated test style.

## Implementation

1. Add validated, defensively copied identifiers and paths: `FieldId`, `VariantId`, `DataTypePath`, and
   `DataPathSegment`. Enforce non-empty names, contiguous duplicate-field occurrences, and path validity.
2. Add `ScalarKind`, `DataField`, `DataVariant`, and the sealed `DataType` cases exactly scoped to v1. Constructor
   checks reject nullable/dynamic mapping keys, empty or nested unions, duplicate variant IDs, and invalid record
   occurrences. Declare the full scalar vocabulary, but do not add constraints, enums, or `LocalDateTime`.
3. Add `DataContract(structural, nativeByPath)`. Validate that every metadata path exists, `Opaque` paths have
   metadata, `Dynamic` and mapping-key paths do not, and metadata nullability agrees with structure. Add cached
   child rebasing as a schema-time operation, not per access.
4. Implement canonical structural/declaration digests. Use `DataType` alone for structural identity and the full
   contract for declaration identity. Mutating constructor inputs after construction must change neither.
5. Implement `DataTypeAlgebra`: width-tolerant `isAssignable`, conservative associative/commutative/idempotent
   `join`, three-way union assignability, `selectVariant`, and `validateVariant`. Expected `Opaque` never succeeds
   structurally; a `Dynamic` requirement accepts concrete actuals, while a dynamic actual satisfies only dynamic.
6. Add canonical `DataType` lowering/decoding through `ExecutionValue`. Exact integers, decimals, temporal values,
   and UUIDs use canonical text interpreted under the type. This is the type grammar only; value snapshotting lands
   in DM4.
7. Add clear `DataProblem` codes for construction, compatibility, path, and union-selection failures. Diagnostics
   contain symbols/paths, never source line numbers.

## Proof

- Common tests cover every type case and constructor rejection; exact ordered record/union identity; optionality,
  nullability, width, scalar promotion, listing/mapping variance, dynamic direction, and opaque rejection.
- Property-style table tests prove `join(t,t) == t`, commutativity, associativity, and idempotence, including records
  and unions that must widen to `Dynamic`.
- Union tests cover all three assignability relations, `List<String> | String`, overlapping record widths,
  duplicate-contract variants, external tag validation, ambiguity, no match, root null, and nested-union rejection.
- Structural digest stays equal across contracts differing only in root or nested native metadata; declaration
  digest differs. Round-trip all type cases through `ExecutionValue`.
- Run from `../kzen-lib`: `./gradlew :kzen-lib-common:jvmTest :kzen-lib-js:jsTest`, then `./gradlew build`.

## Exit criteria

- No consumer has migrated and no legacy type is removed; this is an independently green type-only foundation.
- Public collections are frozen, every invariant has a test, and common code imports no JVM API.
- Record the final package/API names in this file's as-built section if they differ from the proposal's working
  names; later sessions update anchors to the as-built symbols.
