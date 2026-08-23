# DS1 — data-source value model + lowering — implementation plan

> **Status: ready to execute.** Session 1 of the **DS** arc (Job data sources). Rationale is
> **[`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)**
> (§3 value types, §3.3–3.5 decisions, §4 `DataShape`, §7.2 lowering) plus
> [`../../analysis/2026-08-21_extension-points.md`](../../analysis/2026-08-21_extension-points.md);
> decisions are pre-made there — do not re-litigate. Constituent plan: **—** (the analysis doc is the
> permanent design record, so this file **is deleted on landing**; its as-built note goes into the
> analysis doc **§13 As-built**). Anchors verified 2026-08-21. Sized **S–M**; **kzen-auto-common
> only** (commonMain + commonTest), kzen-lib untouched. Ledger row 50.
>
> **Arc map** (one file per session, each independently useful): **DS0** schema vocabulary move →
> DS1 model → **DS1b** inference visibility fix → DS2 suspend runtime (`DataSource` / `DataOpener` /
> `DataCursor` / `DataContext`, `FileDataSource` + `FileDataOpener`, `DataSourceActions`) → DS3
> `ReadWorker` → DS4 sources editing surface → DS5 `ReadPartWorker` + migration-safe 1:N execution → DS6 design-time
> shape → DS7 writer refs + named child arguments + per-unit paths → DS8 `LogicDataSource` + the dated example.
> DS0–DS4 are the "capture the idea of a data source, generally and ergonomically" ask; DS5–DS6
> complete composition and the design-time surface; DS7–DS8 are the ETL port. **DS supersedes J3**
> (`J3_report-subsumption-a.md`): DS2's `FileDataOpener` over format plugins replaces
> `PluginReaderWorker` (J3a) and DS6 absorbs the column pre-scan / `JobUpstreamSchema` fallback (J3b).

## Scope & goal

The §3.2 value types, in `kzen-auto-common` `commonMain`, with everything a value needs to cross the
seams the later sessions use: digest (cache keys, trace record), `ExecutionValue` lowering (detached
results, traces, run arguments), kotlinx `@Serializable` (REST DTOs for the DS4 card preview),
`DataLocation` ⇄ `DataRef` interop (the trivial case stays as cheap as today), and expression-friendly
construction. Nothing consumes them yet; **the tests are the exercise**, and DS2 builds on them
unchanged.

```kotlin
// package tech.kzen.auto.common.data.model   (new package under DS0's common/data/ root — CC-15 cluster)
value class DataRole(val name: String)                          // "main", "reference", … ; DataRole.main
value class DataSourceId(val value: String)                     // a PROVIDER-BOUND source's durable identity — unminted in v1
data class DataRef(source: DataSourceId?, id: String, attributes: Map<String, String>): Digestible
data class DataPart(role: DataRole, ref: DataRef, format: CommonPluginCoordinate?, encoding: CommonDataEncodingSpec?): Digestible
data class DataUnit(attributes: Map<String, String>, parts: List<DataPart>): Digestible   // partsOf(role), part(role) single-or-throw
data class DataManifest(units: List<DataUnit>): Digestible
data class DataResolveResult(manifest: DataManifest, diagnostics: List<DataDiagnostic>)
data class DataDiagnostic(kind: String, message: String)        // text-canonical; `kind` is a plain open string (skipped, unsupported, …)

// package tech.kzen.auto.common.data.schema  (beside DS0's HeaderListing)
sealed interface DataShape { Tabular(header: HeaderListing); Payload(type: TypeMetadata) }
```

`DataRef.source` is a **`DataSourceId`** — a UUID that a *provider-bound* source (JDBC, authenticated
API) would mint into its own notation at insert and never rewrite (analysis §3.3). It is **not** an `ObjectLocation` (not rewritten by refactors when it sits inside a
value) and **not** an `ObjectStableId` (session-scoped). **This session — and this arc — mints nothing**
(§3.3): every ref a file or Logic source produces is *plain*
(`source == null`, id = path), and a plain ref is durable by construction. The type exists so the model
shape is final; the minting, the id→location scan and the duplicate-id validation land with the first
provider-bound source.

## Dependencies & coordination

- **DS0 must have landed** — the `common/data/` root exists and `HeaderListing` lives at
  `common/data/schema/`; `DataShape.Tabular` references it, which is why DS0 goes first.
- **Nothing else in the tree references these types yet.**
- **Package placement.** `tech.kzen.auto.common.data.model` for the value types, `…data.schema` for
  `DataShape`. **Not** `paradigm/data/model`: `paradigm/` holds `{detached, flow, job, logic}` —
  *execution paradigms* — and a value model is not one. **Not** `objects/document/report/…` — they are
  not Report's. **Not** `objects/document/data/` or `server/objects/data/` — both are taken by the existing
  `DataFormat` document (analysis §6.3 / §10). `util/data/` keeps `DataLocation` / `DataLocationGroup` /
  `DataLocationInfo` (location arithmetic — the interop target, not the model's home).
- **Naming is fixed** (analysis §10): `Data*`, never `Resource*`. Collision check:
  `DataRef`, `DataPart`, `DataUnit`, `DataManifest`, `DataRole`, `DataSourceId`, `DataShape`,
  `DataResolveResult`, `DataDiagnostic` are all free. ⚠ The *package* `data` is **not** free — see above.
- **Stage new files** with `git -C ../kzen-auto add -- <path>`; never commit, never `git add -A`.

## Current-state findings (anchors verified 2026-08-21)

- **Digest plane.** `tech.kzen.lib.common.util.digest.Digestible` / `Digest.Sink` — the precedent for a
  model value's digest is `FlatDataInfo.digest` (kzen-auto-jvm `…report/exec/input/model/data/`):
  `sink.addDigestible(...)`, `addUtf8Nullable(...)`. **Maps are digested in sorted-key order** — `Map` equality is order-insensitive, so the digest must be too.
- **`ExecutionValue` plane** (kzen-lib `…/exec/ExecutionValue.kt`): `MapExecutionValue`,
  `ListExecutionValue`, `TextExecutionValue`, `NullExecutionValue`; the `asCollection` / `ofCollection`
  pairs throughout (`LogicTraceSnapshot`, `LogicRunExecutionInfo`) are the shape to mirror. Lowering
  is a mechanical map/list form — no bespoke codec (analysis §7.2). ⚠ `ExecutionValue.ofArbitrary`
  lowers scalars / lists / maps only — a model object is **not** auto-lowered when it sits inside a
  `TupleValue`; callers must call `asExecutionValue()` explicitly (relevant to DS7).
- **Wire plane.** kotlinx-serialization is the single JSON codec (`WireDtoSerializerTest`, commonTest,
  runs under ChromeHeadless too). `DataLocation` is `@Serializable(with = DataLocationSerializer::class)`
  — a `KSerializer` whose wire form is the value's own canonical string; `DataLocationInfo` is a plain
  `@Serializable` DTO. **`DataSourceId` / `DataRole` are `value class`es over `String`**, so kotlinx
  serializes them as strings with no hand-written serializer. `TypeMetadata` (for `DataShape.Payload`)
  already has a wire form — check how `WorkerLane` / `JobValidation` DTOs carry it and reuse that.
- **Plugin coordinate / encoding.** `CommonPluginCoordinate` and `CommonDataEncodingSpec`
  (`…common/objects/document/plugin/model/`) already have canonical string forms used by
  `InputDataSpec` notation (`coordinate` key) — reuse those for both digest and wire.
- **Interop target.** `DataLocation.of(String)` / `asString()` (`…common/util/data/DataLocation.kt`);
  `DataLocationGroup(String?)` is what `DataUnit.attributes` generalizes. `DataLocationInfo(path, name,
  size: Long, modified: Instant, directory)` is where a file resolver gets the fingerprint it stamps.
- **`FlatDataInfo` is what this generalizes** — `DataLocationGroup(String?)` widened to an attribute map,
  one location widened to a role-keyed list (analysis §3.4). Read it before writing the digests.

## Pre-resolved questions

1. **`DataRole` shape** — a `value class` over `String`, with `DataRole.main`. Not an enum (roles are
   open — a third-party source may mint `reference`, `lookup`, …), not a bare `String` (CC-04: the role
   is a concept, and `partsOf(role)` reads wrong with a raw string).
2. **`DataSourceId` shape** — a `value class` over `String`. Opaque. Its KDoc must say, in two
   sentences: why it is not an `ObjectStableId` (session-scoped), and that **nothing mints one until a
   provider-bound source exists** — with the pointer to analysis §3.3. Both are re-litigable; the KDoc is
   where the next reader looks first.
3. **Nullability of `DataPart.format` / `encoding`** — nullable, meaning *opener default / infer*
   (analysis §3.2). Never `""`-as-null in the model; notation may use blank, the spec parse maps it.
4. **`DataRef` with `source == null`** — first-class (O4) and **the only kind this arc produces**.
   `DataRef.ofLocation(DataLocation)` and `DataRef.asLocationOrNull()` are the conversions;
   `asLocationOrNull` is null when `source != null` (a source-minted id is not a path, even if it looks
   like one).
5. **Attribute value type** — `Map<String, String>` (§3.5 **[decided]**); no typed attributes. Insertion
   order is **kept for display** (copy into a `LinkedHashMap`) but is **not semantic**: equality is
   `Map` equality and the digest sorts keys. Document both in the KDoc.
6. **Reserved fingerprint keys on `DataRef.attributes`** (§6.2) — `DataRef.sizeKey = "size"` and
   `DataRef.modifiedKey = "modified"` (ISO-8601 text) as constants on the companion (CC-01); a resolver
   *may* stamp them, nothing requires them, and `DataRef.fingerprintOrNull()` reads them back as a
   `(size, modified)` pair or null. No dedicated field — the map is already text-canonical and digested.
7. **Do units nest?** No (O5). `DataManifest` is a flat list; `DataPart.ref` is a ref, never a manifest.
8. **Construction helpers** — a small companion family so a user-authored source (DS8 `LogicDataSource`'s
   Script) can mint units without ceremony: `DataPart.ofPath(role, path)`, `DataUnit.of(vararg parts)`,
   `DataUnit.of(attributes, parts)`, `DataUnit.ofPath(path)`. Keep it small and additive; these are
   convenience over the constructors, never a second construction path with different validation.
9. **`DataShape`** — `sealed interface` in `common/data/schema/`: `Tabular(header: HeaderListing)`,
   `Payload(type: TypeMetadata)`. The name matches the existing flat-versus-payload Job vocabulary and
   includes scalar payloads; `Object` would not. Both `@Serializable` (a closed sealed hierarchy serializes with kotlinx's
   class discriminator; pin the JSON). Not `Digestible` — shapes are not part of a manifest.
10. **`DataResolveResult` / `DataDiagnostic`** — plain data classes, `@Serializable`, with
    `asExecutionValue` / `ofExecutionValue`. `DataDiagnostic.kind` is an open string (constants for the
    ones DS2 emits: `skipped`, `unsupported`); not an enum, so a third-party source can add kinds. Not
    `Digestible`.
11. **Does a cursor / SPI type live here?** No — DS2. The model is pure values.

## Step-by-step implementation

### Step 1 — model types (commonMain)

`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/data/model/` — one file per class (CC-15):
`DataRole.kt`, `DataSourceId.kt`, `DataRef.kt`, `DataPart.kt`, `DataUnit.kt`, `DataManifest.kt`,
`DataResolveResult.kt`, `DataDiagnostic.kt`; and `…/data/schema/DataShape.kt`. Each value:
`Digestible` where stated, `@Serializable`, KDoc stating the **one** thing the analysis decided about it
(ref plain-by-default and why `source` exists; unit = ordered parts with role on the part, attributes
order presentation-only; manifest = flat ordered list; shape = structure vs type), and the CC-20 pointer
to the analysis doc — the rationale is **not** repeated in KDoc.

Accessors that the later sessions need and that define the contract:
- `DataUnit.partsOf(role: DataRole): List<DataPart>`; `DataUnit.part(role): DataPart` (exactly one, else
  `IllegalStateException` naming the role and the count — CC-08).
- `DataUnit.isSingleRole: Boolean` (all parts share one role) — what `ReadWorker emit: items` keys on in
  DS3.
- `DataRef.display(): String` — `id` (the canonical string *is* the display; no second field);
  `DataRef.fingerprintOrNull()`.
- The Pre-resolved 8 construction helpers.

### Step 2 — `ExecutionValue` lowering

Companion `ofExecutionValue(value: ExecutionValue): T` + member `asExecutionValue(): ExecutionValue`
on each data class (including `DataResolveResult` / `DataDiagnostic` / `DataShape`), in the
`asCollection`/`ofCollection` style. Key names are constants in one place (`DataModelKeys` object in the
same package — CC-01), shared with the wire form. Text-canonical: `attributes` lowers to a
`MapExecutionValue` of `TextExecutionValue`; `source` to its id string or `NullExecutionValue`; `format` /
`encoding` to their canonical strings or null. `ofExecutionValue` is strict (CC-08): a missing required
key or wrong node type throws with the key name, never silently defaults.

### Step 3 — `DataLocation` interop

`DataRef.ofLocation(DataLocation)` (source null, id = `asString()`, attributes empty) and
`DataRef.asLocationOrNull(): DataLocation?`. Nothing on `DataLocation` itself changes.

### Step 4 — KDoc cross-references

`DataLocationGroup`'s KDoc gets one sentence: "generalized by `DataUnit.attributes` — see
`common/data/model`". That is the only edit to an existing file.

## Tests

All in `kzen-auto-common/src/commonTest/kotlin/tech/kzen/auto/common/data/` (run on **both** jvm
and js):

1. **`DataModelExecutionValueTest`** — each type round-trips `asExecutionValue` → `ofExecutionValue`
   equal; attribute **display order** survives (a 3-key `LinkedHashMap` in non-alphabetical order comes
   back in the same order); nullable `format` / `encoding` / `source` round-trip as null; a missing
   required key throws with the key in the message; `DataResolveResult` with two diagnostics round-trips;
   each `DataShape` variant round-trips.
2. **`DataModelSerializationTest`** — kotlinx JSON round-trip for `DataManifest` with two units, two
   roles, one sourced ref and one plain-path ref; **`DataSourceId` / `DataRole` encode as bare JSON
   strings** (the `value class` property — assert the JSON text, not just the round-trip); `DataShape`
   sealed discriminator pinned.
3. **`DataModelDigestTest`** — equal values ⇒ equal digests; **changing attribute *order* does NOT change
   the digest, and two units equal under `==` digest equal** (the row that catches an in-order digest); changing one attribute value changes it; `DataRef` with vs without `source` differ;
   a stamped fingerprint changes the ref's digest (a changed file is a different manifest).
4. **`DataRefLocationTest`** — `ofLocation(loc).asLocationOrNull() == loc`; a sourced ref's
   `asLocationOrNull()` is null; `id` of a plain ref equals `loc.asString()`; `fingerprintOrNull()` null
   when unstamped, the pair when stamped.
5. **`DataUnitTest`** — `partsOf` filters in order; `part(role)` throws on 0 and on 2, with the role and
   the count in the message; `isSingleRole` true for one-role/multi-part, false for two roles; the
   construction helpers produce exactly what the constructors would.

## Verification

1. `cd ../kzen-auto && ./gradlew :kzen-auto-common:jvmTest :kzen-auto-common:jsTest` — the new suites
   green on both planes (the js plane is what proves the `value class` serialization behaves in the
   browser).
2. `./gradlew :kzen-auto-js:compileKotlinJs` and `:kzen-auto-jvm:compileKotlin` — nothing downstream
   breaks (there are no consumers yet; this is a smoke that the common module still builds for both).
3. Append an as-built note to the analysis doc (`## 14. As-built`) and tick ledger row 50; delete this
   file (the README rule — the analysis doc is the record).

## Risks & gotchas

- **Don't reach for `ObjectLocation` or `ObjectStableId` "just for now".** The whole point of §3.3 is
  durable rename-safety; either would be lowered into the wire form and become a compatibility problem
  for DS2+. And don't *mint* a `DataSourceId` anywhere in this arc — the field is a reservation.
- **Order-preserving maps in JS.** Kotlin/JS `LinkedHashMap` preserves insertion order; `toMap()` on a
  `LinkedHashMap` returns an order-preserving map on both planes — test 1 pins it, don't assume. And
  the digest must **sort**, not iterate (test 3).
- **Keep the model free of JVM types.** `FlatFileRecord`, paths — none belong here. `HeaderListing` is
  commonMain (at `common/data/schema/` after DS0) and is referenced only by `DataShape.Tabular`.
- **`value class` + `@Serializable`** — a value class over `String` serializes as the underlying string,
  but only if it is not boxed at the use site. Test 2 asserts the JSON text for exactly this reason.
- **CC-20**: the analysis doc is the rationale's one home. KDoc links to it; it does not restate §3.4.

## Out of scope (this session)

- The `DataSource` / `DataOpener` / `DataCursor` / `DataContext` API and any implementation — **DS2**.
- Minting a `DataSourceId`, resolving one back to an object, duplicate-id validation — **deferred past
  the arc** (O15; with the first provider-bound source).
- Notation (yaml) for the model — none is needed: values are minted by sources and carried as run
  state / wire DTOs; the only notation is the *source object's* attributes (DS2/DS4).
- `WorkerLane` / `JobMessage` changes — none; a `DataUnit` is an ordinary payload. ⚠ It will not *type*
  as one until **DS1b** lands (analysis §5.5).
