# DM5 — adapter registry and three-backing vertical proof

> **Status: ready after DM2–DM4 and J5a baseline. One implementation session spanning kzen-lib then kzen-auto.**
> Authority: unified data model §§6.1, 7, 7.2–7.4, 14.3, 14.5 step 3, and foundation-gate items 1, 6, and 7.

## Outcome

The same typed record reads identically from literal, native data-class, flat-record, and fake typed-row backings.
Adapter selection is deterministic, native identity is preserved, flat reads allocate no per-field wrapper, and the
direct `FlatFileRecord : ValueAccess` design survives only if it wins the required measurement.

## Preconditions and coordination

- Land or pull forward master-ledger J5a before changing the carrier; capture current Job throughput/allocation and
  preserve its raw results. Do not claim the five-percent gate without a before baseline.
- Re-read both sibling `AGENTS.md` files. Start from published DM4 kzen-lib artifacts.
- Inspect `FlatFileRecord`, `FlatFileRecordField`, parser fill/copy/exchange/clear paths, `FlatView`,
  `CsvRecordReader`, and plugin/sample-plugin build files. The kzen-auto guide's “stable dependency-free SPI” text is
  explicitly superseded by the design and must be corrected in the landing change.

## Implementation

1. In kzen-lib jvmMain, implement `DataAdapter`, `DataAdapterRegistry`, native-object access plans, and built-ins for
   primitives, lists, arrays, maps, Kotlin data classes, and Java records. Cache property access plans; never invoke
   arbitrary public getters.
2. Exact class registrations (class identity) run before built-ins; ordered capability fallbacks run after them.
   Detect duplicate exact registrations at registry construction. `describe` and `lift` must agree.
3. Refuse automatic `Iterable`, `Sequence`, `Iterator`, and `Set`. Stop recursive data-class description at opaque.
   Runtime-only empty/dynamic collections carry no invented native metadata.
4. Add a fake typed-row backing in kzen-lib JVM tests and prove it uses the same `ValueAccess` operations without
   introducing JDBC or leases.
5. In kzen-auto-plugin, add the JVM kzen-lib-common dependency. Prototype both direct
   `FlatFileRecord : ValueAccess` (record carries shared header) and `FlatRecordAccess(header, record)` against the
   J5a harness. Cover clear/copy/clone/exchange header semantics and primitive caches.
6. Keep direct implementation only if median throughput/allocation beats the wrapper and passes the allocation pin;
   otherwise retain the wrapper and record that the proposal's acceptable implementation won by evidence. Delete
   the losing path in the same session.
7. Make parser-produced records self-contained/strongly held so rows remain readable after cursor advance/close.
   Add a hosted-child result lifetime test in kzen-lib or the first kzen-auto integration seam.
8. Update sample plugin and SPI docs/build ordering. New reader output may use `DataValue`; do not cut Job yet.

## Proof and build order

- One fixture contract/value is traversed identically from literal, data class, direct-or-wrapper flat record, and
  fake typed row. A native consumer gets the exact original data-class reference.
- Cover registry precedence/conflicts/fallback order, `describe`/`lift`, recursive/cyclic/opaque cases, publication
  mutation failure, native collection heterogeneity, and snapshot rejection without `toString()`.
- Record direct-vs-wrapper median and allocation numbers and the chosen implementation in an as-built table.
- Build/publish `../kzen-lib` first. Then from `../kzen-auto`, run plugin tests, relevant JVM tests, full
  `./gradlew build`, and `./gradlew :kzen-auto-plugin:publishToMavenLocal`. Rebuild `../kzen-sample-plugin` and the
  standalone downstream plugin consumer if present.

## Exit criteria

- Foundation-gate items 1, 6, and 7 are proven; no eager row-to-map conversion exists.
- Every new file is explicitly staged in its owning sibling; no version bump.
