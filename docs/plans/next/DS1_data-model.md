# DS1 — data-source value model + lowering — implementation plan

> **Status: ready to execute.** Session 1 of the **DS** arc (Job data sources). Rationale is
> **[`../../analysis/2026-08-20_job-data-source.md`](../../analysis/2026-08-20_job-data-source.md)**
> (§3 value types, §3.3–3.5 decisions, §7.2 lowering) plus
> [`../../analysis/2026-08-21_extension-points.md`](../../analysis/2026-08-21_extension-points.md);
> decisions are pre-made there — do not re-litigate. Constituent plan: **—** (the analysis doc is the
> permanent design record, so this file **is deleted on landing**; its as-built note goes into the
> analysis doc **§14 As-built**). Anchors verified 2026-08-21. **Revised 2026-08-21b** by the
> second-pass review (§13). Sized **S–M**; **kzen-auto-common only** (commonMain + commonTest), kzen-lib
> untouched. Ledger row 50.
>
> **Arc map** (one file per session, each independently useful): **DS0** schema vocabulary move →
> DS1 model → **DS1b** inference visibility fix → DS2 `DataSource` + `DataScope` + `FileDataSource` →
> DS3 `ReadWorker` → DS4 sources editing surface → DS5 `ExpandWorker` + objects in expression scope →
> DS6 design-time schema → DS7 writer yields `DataRef` → DS8 `LogicDataSource` + the dated example.
> DS0–DS4 are the "capture the idea of a data source, generally and ergonomically" ask; DS5–DS6
> complete the expert and design-time surfaces; DS7–DS8 are the ETL port. **DS supersedes J3**
> (`J3_report-subsumption-a.md`): DS2's `FileDataSource.items` over format plugins replaces
> `PluginReaderWorker` (J3a) and DS6 absorbs the column pre-scan / `JobUpstreamSchema` fallback (J3b).
>
> **What changed in the 2026-08-21b revision:** `DataRef.source` is a **minted durable `DataSourceId`**,
> not an `ObjectStableId` (§3.3, correction C9) — so the `ObjectStableIdSerializer` this plan previously
> called for is **gone**; the package moves from `paradigm/data/model` to `common/data/model` (DS0's
> new root); and the model gains the small construction-helper family that a user-authored source
> (§4.4) needs to mint units from an expression.

## Scope & goal

The §3.2 value types, in `kzen-auto-common` `commonMain`, with everything a value needs to cross the
seams the later sessions use: digest (resume compare, cache keys), `ExecutionValue` lowering (detached
results, traces, run arguments), kotlinx `@Serializable` (REST DTOs for the DS4 card preview),
`DataLocation` ⇄ `DataRef` interop (the trivial case stays as cheap as today), and expression-friendly
construction. Nothing consumes them yet; **the tests are the exercise**, and DS2 builds on them
unchanged.

```kotlin
// package tech.kzen.auto.common.data.model   (new package under DS0's common/data/ root — CC-15 cluster)
value class DataRole(val name: String)                          // "main", "reference", … ; DataRole.main
value class DataSourceId(val value: String)                     // a source object's MINTED durable identity
data class DataRef(source: DataSourceId?, id: String, attributes: Map<String, String>): Digestible
data class DataPart(role: DataRole, ref: DataRef, format: CommonPluginCoordinate?, encoding: CommonDataEncodingSpec?): Digestible
data class DataUnit(attributes: Map<String, String>, parts: List<DataPart>): Digestible   // partsOf(role), part(role) single-or-throw
data class DataManifest(units: List<DataUnit>): Digestible
```

`DataRef.source` is a **`DataSourceId`** — a UUID minted into the source object's own notation at insert
and never rewritten by rename or move (analysis §3.3 **[decided 2026-08-21b]**). It is **not** an
`ObjectLocation` (not rewritten by refactors when it sits inside a value, so it dangles on rename) and
**not** an `ObjectStableId` (`ObjectStableMapper` is an in-memory, session-scoped map whose ids *are*
location strings, so a renamed source's persisted ref is dead after a restart — which is exactly the
case DS7 creates when a writer yields a ref as a run result).

**This session mints nothing.** It defines the id type and its lowering; the `id: ""` attribute on the
`DataSource` archetype and the editor's mint-on-insert are **DS2** and **DS4**.

## Dependencies & coordination

- **DS0 must have landed** — the `common/data/` root exists and `HeaderListing` lives at
  `common/data/schema/`. The model types do not reference `HeaderListing`, but they share the root and
  DS2's SPI will.
- **Nothing else in the tree references these types yet.**
- **Package placement.** `tech.kzen.auto.common.data.model`. **Not** `paradigm/data/model` (the previous
  draft): `paradigm/` holds `{detached, flow, job, logic}` — *execution paradigms* — and a value model
  is not one. **Not** `objects/document/report/…` — they are not Report's. **Not**
  `objects/document/data/` or `server/objects/data/` — both are taken by the existing `DataFormat`
  document (analysis §6.3 / §10). `util/data/` keeps `DataLocation` / `DataLocationGroup` /
  `DataLocationInfo` (location arithmetic — the interop target, not the model's home).
- **Naming is fixed** (analysis §10): `Data*`, never `Resource*`. Collision check re-run 2026-08-21b:
  `DataRef`, `DataPart`, `DataUnit`, `DataManifest`, `DataRole`, `DataSourceId`, `DataSource`,
  `DataScope`, `DataItems` are all free. ⚠ The *package* `data` is **not** free — see above.
- **Stage new files** with `git -C ../kzen-auto add -- <path>`; never commit, never `git add -A`.

## Current-state findings (anchors verified 2026-08-21)

- **Digest plane.** `tech.kzen.lib.common.util.digest.Digestible` / `Digest.Sink` — the precedent for a
  model value's digest is `FlatDataInfo.digest` (kzen-auto-jvm `…report/exec/input/model/data/`):
  `sink.addDigestible(...)`, `addUtf8Nullable(...)`. Maps must be digested in **iteration order** with
  both key and value; the model's maps are `LinkedHashMap`-ordered by contract (§3.5).
- **`ExecutionValue` plane** (kzen-lib `…/exec/ExecutionValue.kt`): `MapExecutionValue`,
  `ListExecutionValue`, `TextExecutionValue`, `NullExecutionValue`; the `asCollection` / `ofCollection`
  pairs throughout (`LogicTraceSnapshot`, `LogicRunExecutionInfo`) are the shape to mirror. Lowering
  is a mechanical map/list form — no bespoke codec (analysis §7.2).
- **Wire plane.** kotlinx-serialization is the single JSON codec (`WireDtoSerializerTest`, commonTest,
  runs under ChromeHeadless too). `DataLocation` is `@Serializable(with = DataLocationSerializer::class)`
  — a `KSerializer` whose wire form is the value's own canonical string; `DataLocationInfo` is a plain
  `@Serializable` DTO. **`DataSourceId` is a `value class` over `String`**, so kotlinx serializes it as
  a string with no hand-written serializer — one of the reasons the id type is ours rather than
  kzen-lib's `ObjectStableId` (which is a plain data class with no serializer and would have needed
  one).
- **Plugin coordinate / encoding.** `CommonPluginCoordinate` and `CommonDataEncodingSpec`
  (`…common/objects/document/plugin/model/`) already have canonical string forms used by
  `InputDataSpec` notation (`coordinate` key) — reuse those for both digest and wire.
- **Interop target.** `DataLocation.of(String)` / `asString()` (`…common/util/data/DataLocation.kt`);
  `DataLocationGroup(String?)` is what `DataUnit.attributes` generalizes.
- **`FlatDataInfo` is what this generalizes** — `DataLocationGroup(String?)` widened to an attribute map,
  one location widened to a role-keyed list (analysis §3.4). Read it before writing the digests.

## Pre-resolved questions

1. **`DataRole` shape** — a `value class` over `String`, with `DataRole.main`. Not an enum (roles are
   open — a third-party source may mint `reference`, `lookup`, …), not a bare `String` (CC-04: the role
   is a concept, and `partsOf(role)` reads wrong with a raw string).
2. **`DataSourceId` shape** — a `value class` over `String`. Opaque to everything except the resolver
   (DS2) and the editor that mints it (DS4). Its KDoc must say **why it is not an `ObjectStableId`**, in
   one sentence, with the pointer to analysis §3.3 — this is the single most re-litigable decision in
   the arc.
3. **Nullability of `DataPart.format` / `encoding`** — nullable, meaning *source default / infer*
   (analysis §3.2). Never `""`-as-null in the model; notation may use blank, the spec parse maps it.
4. **`DataRef` with `source == null`** — first-class (O4): a plain path. `DataRef.ofLocation(DataLocation)`
   and `DataRef.asLocationOrNull()` are the conversions; `asLocationOrNull` is null when `source != null`
   (a source-minted id is not a path, even if it looks like one). This is also what makes DS8's
   `LogicDataSource` work without a new SPI: a user-authored source mints plain refs.
5. **Attribute value type** — `Map<String, String>` (§3.5 **[decided]**); no typed attributes. Insertion
   order is significant (digest + `${date}` substitution later); enforce `LinkedHashMap` in constructors
   by copying (`toMap()` preserves order for `LinkedHashMap` input — document it).
6. **Do units nest?** No (O5). `DataManifest` is a flat list; `DataPart.ref` is a ref, never a manifest.
7. **Construction helpers** — a small companion family so an expression (DS5) or a user-authored source
   (DS8 `LogicDataSource`) can mint units without ceremony: `DataPart.ofPath(role, path)`,
   `DataUnit.of(vararg parts)`, `DataUnit.of(attributes, parts)`, `DataUnit.ofPath(path)`. Keep it small
   and additive; these are convenience over the constructors, never a second construction path with
   different validation.
8. **Does `DataItems` live here?** No — DS2, with the rest of the SPI. It references `HeaderListing` and
   only makes sense beside `DataSource`.

## Step-by-step implementation

### Step 1 — model types (commonMain)

`kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/data/model/` — one file per class (CC-15):
`DataRole.kt`, `DataSourceId.kt`, `DataRef.kt`, `DataPart.kt`, `DataUnit.kt`, `DataManifest.kt`. Each
data class: `Digestible`, `@Serializable`, KDoc stating the **one** thing the analysis decided about it
(ref opaque + source-relative and why the id is durable; unit = ordered parts with role on the part;
manifest = flat ordered list), and the CC-20 pointer to the analysis doc — the rationale is **not**
repeated in KDoc.

Accessors that the later sessions need and that define the contract:
- `DataUnit.partsOf(role: DataRole): List<DataPart>`; `DataUnit.part(role): DataPart` (exactly one, else
  `IllegalStateException` naming the role and the count — CC-08).
- `DataUnit.isSingleRole: Boolean` (all parts share one role) — what `ReadWorker emit: items` keys on in
  DS3.
- `DataRef.display(): String` — `id` (the canonical string *is* the display; no second field).
- The Pre-resolved 7 construction helpers.

### Step 2 — `ExecutionValue` lowering

Companion `ofExecutionValue(value: ExecutionValue): T` + member `asExecutionValue(): ExecutionValue`
on each of the four data classes, in the `asCollection`/`ofCollection` style. Key names are constants
in one place (`DataModelKeys` object in the same package — CC-01), shared with the wire form.
Text-canonical: `attributes` lowers to a `MapExecutionValue` of `TextExecutionValue`; `source` to its
id string or `NullExecutionValue`; `format` / `encoding` to their canonical strings or null.
`ofExecutionValue` is strict (CC-08): a missing required key or wrong node type throws with the key
name, never silently defaults.

### Step 3 — `DataLocation` interop

`DataRef.ofLocation(DataLocation)` (source null, id = `asString()`, attributes empty) and
`DataRef.asLocationOrNull(): DataLocation?`. Nothing on `DataLocation` itself changes.

### Step 4 — KDoc cross-references

`DataLocationGroup`'s KDoc gets one sentence: "generalized by `DataUnit.attributes` — see
`common/data/model`". That is the only edit to an existing file.

## Tests

All in `kzen-auto-common/src/commonTest/kotlin/tech/kzen/auto/common/data/model/` (run on **both** jvm
and js):

1. **`DataModelExecutionValueTest`** — each type round-trips `asExecutionValue` → `ofExecutionValue`
   equal; attribute **order** survives (a 3-key `LinkedHashMap` in non-alphabetical order comes back in
   the same order); nullable `format` / `encoding` / `source` round-trip as null; a missing required key
   throws with the key in the message.
2. **`DataModelSerializationTest`** — kotlinx JSON round-trip for `DataManifest` with two units, two
   roles, one sourced ref and one plain-path ref; **`DataSourceId` encodes as a bare JSON string** (the
   `value class` property — assert the JSON text, not just the round-trip, or a future refactor to a
   data class would pass silently).
3. **`DataModelDigestTest`** — equal values ⇒ equal digests; changing attribute *order* changes the
   digest (order is load-bearing); changing one attribute value changes it; `DataRef` with vs without
   `source` differ; two refs differing only in `source` differ.
4. **`DataRefLocationTest`** — `ofLocation(loc).asLocationOrNull() == loc`; a sourced ref's
   `asLocationOrNull()` is null; `id` of a plain ref equals `loc.asString()`.
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
  for DS2+. If the minting mechanism feels heavy while writing DS1, that is expected — DS1 only defines
  the *type*.
- **Order-preserving maps in JS.** Kotlin/JS `LinkedHashMap` preserves insertion order; `toMap()` on a
  `LinkedHashMap` returns an order-preserving map on both planes — test 1 pins it, don't assume.
- **Keep the model free of JVM types and of schema.** `FlatFileRecord`, paths, `HeaderListing` — none
  belong here. `HeaderListing` is commonMain (at `common/data/schema/` after DS0) and is fine to
  *reference* from `DataSource.schema` in DS2, but the model types carry no schema.
- **`value class` + `@Serializable`** — a value class over `String` serializes as the underlying string,
  but only if it is not boxed at the use site. Test 2 asserts the JSON text for exactly this reason.
- **CC-20**: the analysis doc is the rationale's one home. KDoc links to it; it does not restate §3.4.

## Out of scope (this session)

- The `DataSource` / `DataScope` / `DataItems` API and any implementation — **DS2**.
- Minting a `DataSourceId` (the archetype's `id: ""` attribute, the editor's mint-on-insert, the
  duplicate-id validation) — **DS2** and **DS4**.
- Resolving a `DataSourceId` back to an object — **DS2** (`DataSourceResolver`, design-time and
  cross-boundary only; run-time access comes from the run graph, analysis §6.5).
- Notation (yaml) for the model — none is needed: values are minted by sources and carried as run
  state / wire DTOs; the only notation is the *source object's* attributes (DS2/DS4).
- `WorkerLane` / `JobMessage` changes — none; a `DataUnit` is an ordinary payload. ⚠ It will not *type*
  as one until **DS1b** lands (analysis §5.5a).
