# DR2 — schema capability and Custom discovery

> **Status: complete — landed 2026-09-01.** Authority: configurable flat-data reading §6; unified data model
> (DataContract as the only field model). Independent of DR1/DR3; must land before DR4. Coordinate with the E4
> master-ledger row if it lands first — both touch Custom prototype machinery.

## Scope and outcome

Extract the reusable record-schema capability from its document wrapper and make Custom prototype discovery
capability-based, so schema, configured-format and source prototypes are discoverable and creatable without
concrete-name checks or duplicated implementation metadata.

## Implementation

1. Split `DataSchemaDocument` (§6.1): a `RecordSchema` capability exposing `contract(): DataContract`, an
   `AuthoredRecordSchema` implementation, and the document as an optional wrapper delegating to it. The ordered
   field model stays `DataContract(DataType.Record(...))` — no parallel `ColumnType` model. `RecordSchema` is
   purely semantic: per-field decode overrides live in the reader config keyed by field path (§4.6, FR18), never
   in the schema.
2. Repoint dependents at the capability, not the wrapper: configured formats, sources that declare a result,
   and shape inspection consume `RecordSchema`; a Custom document can contain an `AuthoredRecordSchema`
   directly.
3. Replace `CustomConventions.listPrototypes`'s direct `is`-text comparison with inheritance/capability
   discovery (§6.2): a candidate is creatable through its inheritance chain (`Prototype` may remain the base
   archetype supplying `CustomCreatable`) and contributes one or more capabilities (`RecordSchema`,
   `ConfiguredRecordFormat`, `DataSource`).
4. Move implementation/editor metadata to the capability archetype; a creatable prototype inherits it and
   supplies only author-facing defaults. Creating an instance copies configuration, never `class`, definer,
   creator or editor metadata.
5. Group/filter the "Add" catalogue by contributed capability while keeping one generic creation mechanism — a
   new capability is one metadata declaration at its owning archetype, not a branch in `CustomCreate`. Generic
   catalogue code must not import or enumerate `RecordSchema`/`ConfiguredRecordFormat`/`DataSource` as a closed
   set: it discovers a contributed creation descriptor/category (label, implementation/editor metadata, creation
   defaults) from inherited graph metadata (§6.2).

## Proof and exit

- A test-only third-party `RecordSchema` subtype appears in the catalogue and creates a working instance
  without any edit to `CustomConventions` (pins the anti-regression from analysis §12: no direct-name checks).
- A completely new test-only capability/category (not a `RecordSchema` subtype) appears with its own grouping,
  metadata and creation defaults without any edit to `CustomConventions` or `CustomCreate` — proving open-ended
  category discovery, not just subtype inheritance.
- The existing dedicated schema document still resolves and serves `shape()` through delegation; existing
  notation is migrated in place (design stage — no compatibility shim).
- Instances created from prototypes carry copied configuration only; inherited metadata verified by inspection
  of the created notation.
- Full build of every touched sibling.

## As-built — 2026-09-01

`RecordSchema` is now the reusable semantic capability and `AuthoredRecordSchema` its editable implementation;
`DataSchemaDocument` remains a delegating document wrapper. Contracts use the existing ordered `DataContract`
record model, while reader-specific decode overrides remain in `DelimitedReadConfig`.

Custom creation moved to inherited creation descriptors and defaults. Catalogue grouping and instance creation
no longer enumerate concrete schema, source or format names; instances copy author-facing configuration while
implementation, definer, creator and editor metadata remain inherited. Tests cover both a third-party schema
subtype and an unrelated test-only capability/category without changes to generic creation code.

`ConfiguredRecordFormat` is the generic capability marker used by file-source discovery and consumption, so
those paths do not depend on `ConfiguredDelimitedFormat`. Focused schema/Custom tests and the final sibling build
are green; closing totals are recorded in DR7.
