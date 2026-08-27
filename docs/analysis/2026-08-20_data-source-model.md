# Data source model — values, resolution, shape and opening

> **Status: design contract; shape correction pending.** The value and source/opener portions were delivered by
> DS0–DS8. The original `DataShape.Tabular | Payload` sum is rejected here: it confuses semantic structure with
> the current Job carrier. The authoritative shape contract is one recursive `DataType` inside an observation
> envelope; the existing implementation must be brought to that contract. The Job adapter, UI, execution
> semantics and complete chronological landing record live
> in [`2026-08-20_job-data-source.md`](2026-08-20_job-data-source.md). The
> [`structural-data analysis`](2026-08-26_database.md) assumes the source value/protocol boundary here and owns
> the recursive type algebra and its runtime access contract.

## 1. Boundary

The data-source model answers four questions without depending on a Job lane or Worker:

| Concern | Question | Contract |
|---|---|---|
| Query | What does the caller want? | Source-specific notation attributes; there is no universal `DataQuery` type |
| Resolve | What does that name now? | `DataSource.resolve(context)` → `DataResolveResult` |
| Describe | What shape can be promised or observed? | `DataSource.staticShape(role)` and `DataOpener.inspectShape(context, part)` → `DataShapeResult` |
| Open | What values does one resolved part contain? | `DataOpener.open(context, part)` → `DataCursor` |

The split is reusable by Job, a detached inspector, a database query source, an API source or another execution
paradigm. Job owns how manifests and cursor items enter lanes, how they migrate, and how output refs cross a child
run. Those concerns remain in the Job document.

The model generalizes Report's useful core rather than inventing a parallel container. Report already kept a
resolved dataset as an ordered list of self-describing items and separated location from parse format. The new
model widens one nullable group to text attributes, one location to ordered role-labelled parts, and edit-time-
only resolution to a callable source.

Shape is semantic, not a reflection of Job's storage. Its type is the recursive `DataType` specified by the
[structural-data analysis](2026-08-26_database.md#5-the-model--one-recursive-type-language). A record may be
projected to a tabular header, and a nominal value may be structurally reflected to a record, but `Tabular` and
`Payload` are not competing kinds of shape. The current code's sum of those names is an implementation defect,
not a model boundary or an accepted intermediate design.

## 2. Value model

```kotlin
value class DataSourceId(val value: String)

data class DataRef(
    val source: DataSourceId?,
    val id: String,
    val attributes: Map<String, String> = emptyMap()
): Digestible

data class DataPart(
    val role: DataRole,
    val ref: DataRef,
    val format: CommonPluginCoordinate?,
    val encoding: CommonDataEncodingSpec?
): Digestible

data class DataUnit(
    val attributes: Map<String, String>,
    val parts: List<DataPart>
): Digestible

data class DataManifest(
    val units: List<DataUnit>
): Digestible

data class DataResolveResult(
    val manifest: DataManifest,
    val diagnostics: List<DataDiagnostic>
)
```

### 2.1 `DataRef` is opaque, and plain refs are first-class

`DataLocation` is too narrow for a database query, authenticated API cursor or object-store key. `DataRef.id` is
therefore an opaque canonical string: stable, digestible, displayable, and unchanged through notation and
`ExecutionValue` lowering. Only the appropriate opener interprets it.

`source == null` is the first-class, self-contained form. A path plus effective format and encoding contains
everything the shared `FileDataOpener` needs, so every ref delivered by DS0–DS8 is plain. `DataLocation` converts
to and from that form without a registry, identity lookup or rename coupling. A sourced ref reaching the current
lookup fails clearly because provider-bound resolution has not landed.

A future JDBC, authenticated API or object-store source will mint a durable `DataSourceId` into its own notation
and place it in `DataRef.source`. It cannot use an `ObjectLocation`, which dangles after rename when embedded in a
value, or an `ObjectStableId`, whose mapping is process-scoped rather than durable. Minting, id→source lookup and
duplicate validation land with the first provider-bound source rather than speculatively.

`DataRef.attributes` carries addressing extras and fingerprints. File resolution reserves `size` and `modified`;
both must be present for `fingerprintOrNull()` to return a value. A content digest is deliberately absent because
it would require a full read during resolution.

### 2.2 Units and parts are ordered, self-describing values

`DataManifest.units` and `DataUnit.parts` are ordered lists because cursor positions, reproducible resolution and
multi-file concatenation all depend on stable order. A map keyed by a composite group would make order implicit
and require equality, hash, digest and wire semantics for the key before the container was usable.

A unit carries the values that identify the work together with its ordered parts. Each part carries its role, ref
and decoding hints. `partsOf(role)` is the ordered multi-part accessor; `part(role)` means exactly one and fails
otherwise. Units do not nest: a source flattens nested provider structure while resolving.

A flat list also composes directly with execution systems. One unit can become one lane element, one function
argument or one trace value without introducing an out-of-band grouped container.

### 2.3 Attributes are text-canonical

`DataUnit.attributes` and `DataRef.attributes` are `Map<String, String>`. This gives stable equality, simple
notation/wire lowering, direct path substitution and the same conversion-at-expression boundary as existing flat
records. Typed attributes belong with the structural column-type model, not this source-selection layer.

Implementations preserve insertion order for presentation, but order is not semantic. Map equality is order-
insensitive, so digests sort keys. `DataUnit.parts`, by contrast, are semantically ordered and digest in order.

## 3. Source and opener protocol

```kotlin
interface DataSource {
    suspend fun resolve(context: DataContext): DataResolveResult

    fun staticShape(role: DataRole?): DataShapeResult = DataShapeResult.Unavailable

    fun definitionDependencies(): List<ObjectLocation> = emptyList()
}

interface DataOpener {
    suspend fun open(context: DataContext, part: DataPart): DataCursor

    suspend fun inspectShape(context: DataContext, part: DataPart): DataShapeResult =
        DataShapeResult.Unavailable
}

interface DataCursor: Iterator<Any?>, AutoCloseable {
    val shape: DataShape
}

interface DataContext {
    fun argument(name: String): Any?

    suspend fun host(instructions: ObjectLocation, arguments: TupleValue): TupleValue {
        throw UnsupportedOperationException("Hosting data-source logic requires an active run")
    }

    suspend fun <R> blocking(block: () -> R): R
}

sealed interface DataShapeResult {
    data object Unavailable: DataShapeResult
    data class Observed(val shape: DataShape): DataShapeResult
}

data class DataShape(
    val itemType: DataType,
    val provenance: ShapeProvenance,
    val stability: ShapeStability,
    val diagnostics: List<SchemaDiagnostic>
)
```

`DataType` is one recursive language: scalar, record, mapping, listing, tagged union, nominal and dynamic.
Its full field identity, presence, scalar and projection rules belong to the structural-data contract; the source
protocol depends only on the fact that there is one semantic item type, never parallel tabular/payload cases.

`definitionDependencies()` names weak definition references whose content affects resolution but is not already
in the source's structural closure. `LogicDataSource` returns its hosted instructions so an edit changes a
reader's migration-compatibility digest; sources with no extra dependency retain the empty default.

### 3.1 Suspend effects, plain cursor

`resolve`, `open` and `inspectShape` are suspend because the context exposes suspend-only run hosting and counted
blocking. Making them synchronous would force either `runBlocking` on an engine thread or an outer blanket
offload that makes nested blocking and hosting unavailable.

The cursor is deliberately not suspend and is not a `Sequence`. It is a plain pull reader whose owner drives each
potentially blocking operation through its current `DataContext`/run control. This keeps third-party cursor
implementations simple and prevents the handle from capturing a control that becomes stale after live migration.
The owner may batch pulls later if profiling justifies it.

Cursor ownership is explicit: exhaustion and normal completion close it, failure/cancellation closes it through
the owner, and migration may transfer the live handle exactly once. `DataCursor.shape` describes every emitted
item using the same semantic type language. The item's backing and access implementation are separate concerns;
a reader never class-switches on an opener or on a shape variant to decide what the data means.

### 3.2 Resolution and opening stay separate

Every source resolves, but only provider-bound refs need their originating provider to open them. A file source
implements only `DataSource`; `FileDataOpener` reads any plain path ref, including refs produced by
`LogicDataSource`. A future JDBC source may implement `DataSource` and `DataOpener` on one object because query
resolution and cursor opening share a connection.

`DataOpenerLookup` is the single dispatch seam owned by a reader: a plain ref selects the shared file opener; a
sourced ref will select its provider when durable provider resolution lands. No `ParameterDataSource` is needed:
a passed `DataUnit` already contains self-opening parts.

Location and parsing remain orthogonal extension axes. `DataSource` answers where the values are and what a query
names; the existing `ReportDefiner`/`DataFramer` plugin seam answers how file-shaped bytes become values.
`DataPart.format` joins those axes without hardcoding a format into the source protocol.

### 3.3 Context capabilities and resource ownership

The landed context supports named arguments, authored-Logic hosting and counted blocking. Runtime hosting
delegates to the same named `JobControl.host` contract used by Job composition. The default rejects design-time
hosting because no active run exists, so `LogicDataSource.resolve` is deliberately runtime-only.

Sources borrow resources; they do not own them. A future JDBC/API source should obtain a caller-owned connection
through a `DataContext.contextValue` capability added with that first consumer. At run time the engine Context
registry already owns creation, ancestor visibility and declared close policy. `JobControl` does not yet expose a
Context read, and shipping a null stub before a stateful source exists would add no behaviour.

At design time the first stateful source decides whether request-scoped open/close is sufficient or the explicit
`DesignSession` proposed by the extension-points analysis is required. This is the only open ownership decision
in the landed source protocol.

### 3.4 Notation objects and authored sources

A source is a notation-discovered capability, never a source-specific plugin registry or a `DetachedAction`.
Third-party archetypes are loaded through the general reflection/module mechanism and classified by inheritance
capability rather than concrete class name. Source-specific configuration stays in ordinary attributes.

`DataSourceActions` is the generic detached dispatcher. `resolve` instantiates the named source and lowers its
manifest; `shape` prefers `source.staticShape(part.role)` and otherwise performs bounded opener inspection;
`fileFormats` describes the server's installed file formats and encodings without instantiating a source. Action
names are constants and unknown actions fail explicitly.

`LogicDataSource` proves that resolving a source need not require Kotlin. It hosts a Script, Flow or Job with
named arguments, requires an eager `Iterable<DataUnit>` main result, and returns those units unchanged. Its refs
are plain, so the shared file opener reads them. Missing/null main means an empty manifest; lazy streams, scalars
and mixed element types fail clearly.

## 4. Shape and schema

### 4.1 One semantic shape, independent of representation

`DataShape` answers **what one item is**. It does not answer whether Job currently stores that item in
`JobMessage.flat`, `JobMessage.payload`, a database row, a structural tape or a native object. Those are backing
and access choices. Encoding them as `Tabular | Payload` creates a false choice: a typed database row and a
Kotlin data class with readable properties can both expose record-shaped access even though their physical
carriers differ.

There is consequently no `Both` case. `Tabular` disappears as a type category: it is a projection of
`DataType.Record` under an explicit field-naming policy. `Payload` also disappears as a category: a native value
is `DataType.Nominal`, and reflecting its accessible properties yields a `Record` view on demand. Scalar,
listing, mapping, union and dynamic values remain in the same language. One item has one semantic type; consumers
request the view and access operations they support.

`DataSource.staticShape(role)` is answerable from compiled notation alone and may never perform I/O. It is the
only source-shape operation safe for a definition/type walk. A declared `DataSchema` supplies it.

`DataOpener.inspectShape(context, part)` may perform one bounded operation over a concrete resolved part: a CSV
header, `LIMIT 0`, or an equivalent provider report. It returns `Unavailable` when the opener cannot answer
cheaply. Neither resolving a source nor consulting a runtime cache belongs in the definition walk.

The result distinguishes `Unavailable` from an observed dynamic type. `Unavailable` means no observation was
made; `Observed(DataShape(itemType = Dynamic, ...))` means the source can execute but its member structure is not
known statically. Conflating those states would make honest dynamic data indistinguishable from failed or
unsupported inspection.

Provenance, stability and diagnostics remain properties of the observation, not cases in the type language.
A declaration is the contract; a carried/provider-reported/inferred observation may validate or refine what is
known, but does not silently replace a conflicting declaration.

The current Job UI reachability is an adapter concern: the detached action and client stores exist, but inline
File/Logic Worker cards expose no Resolve/Columns trigger. See the Job document's design-time section.

### 4.2 Fingerprinted schema cache

`SchemaCache` keys a fully resolved file inspection by `(ref.id, format, encoding, size, modified)`. A ref without
both fingerprint values is inspected but never cached; corrupt persisted entries are misses; writes replace
atomically; managed-storage deletion invalidates memory.

This fixes the pre-DS6 `ColumnListingAction` identity, which omitted size and modification time and could return
stale columns after a file edit. Report and source inspection now share the same cache identity. Cache access is a
runtime/editor optimization, not an SPI member or a type-walk input.

### 4.3 `DataSchema` declares a typed record

The pre-arc `DataFormat` document already described field name → `TypeMetadata`, but nothing consumed it and its
name collided with parse-format vocabulary. DS6 renamed it to `DataSchema` and made it the nullable strong
structural declaration on `FileDataSource`.

`DataSchema` projects every ordered field, including its type and field identity, into `DataType.Record`. It must
not discard the types and publish only labels. A legacy flat consumer may explicitly project a compatible record
to `HeaderListing`, but that lossy view is local to the consumer and never becomes the source's shape.

The current implementation still drops those types when constructing `DataShape.Tabular`. That behaviour is the
specific code defect to remove; it is not retained as a compatibility rule.

## 5. Boundaries and snapshot semantics

### 5.1 Canonical lowering

`DataRef`, `DataPart`, `DataUnit`, `DataManifest` and `DataResolveResult` have strict canonical `ExecutionValue`
and kotlinx-serialization forms. Text-canonical attributes make the representation a mechanical map/list tree
rather than a bespoke codec. `DataShapeResult`, `DataShape` and `DataType` require the same canonical wire and
digest semantics when the recursive type owner's open module-boundary decision is resolved; the rejected
`Tabular | Payload` wire form is not the target contract.

`DataRef.source` lowers as a nullable `DataSourceId` string. `ExecutionValue.ofArbitrary` does not discover these
domain conversions, so a boundary lowering a result tuple must call the model's `asExecutionValue()` explicitly.

### 5.2 A manifest is a point-in-time snapshot

Dynamic resolution must happen once for an execution consumer: two directory scans during one run can name
different files. The resolved manifest, diagnostics and stamped fingerprints together record what the consumer
was given. A manifest digest canonicalizes attribute keys and includes ordered units/parts and ref fingerprints.

How a consumer carries, traces or migrates that snapshot is outside the model. Job's `ReadWorker` carries the
manifest and live cursor across compatible edits and traces a fresh resolution once; another execution paradigm
may choose a different lifecycle while preserving the point-in-time contract.

### 5.3 Same-run values are not a result registry

A plain `DataRef` can cross a Logic boundary in process and remain durable because its id is a path. That does not
create cross-run result persistence: `OutcomeTrace` does not retain an arbitrary success tuple, and no results
registry with naming/retention exists. The consumer that wants to persist a ref chooses where to store it.

## 6. Naming and packages

`Data*` avoids the codebase's two existing Resource vocabularies and aligns with `DataLocation`, `DataFramer` and
`DataEncodingSpec`. `DataSource` is the resolve capability; JVM `FlatDataSource` is the lower byte-stream seam.
Their reciprocal KDocs disambiguate them. `DataContext` is the per-call environment through which source code
reaches arguments, hosting and blocking; it is not a kzen Context declaration.

`format` means the parse coordinate. The field/type declaration is `DataSchema`.

The package layout reflects the boundary:

- `common/data/model/` — refs, parts, units, manifests and diagnostics;
- `common/data/api/` — source, opener, cursor and context contracts;
- the neutral structural-data owner — `DataType`, `DataShape`, observation metadata and field identity;
- `common/data/schema/` — legacy header projection until its consumers move to structural access;
- `common/data/file/` and `common/data/format/` — reusable source configuration values;
- `server/data/` — file opening, input plumbing, opener lookup and schema cache;
- `server/objects/datasource/` — notation source implementations and detached actions.

Job adapters live separately under `server/objects/job/worker/data/` and the corresponding client Job packages.

## 7. Decisions register

| # | Decision | Current answer |
|---|---|---|
| DM1 | Fixed `DataQuery` type? | No. Query configuration is source-specific notation |
| DM2 | Plain refs first-class? | Yes; every landed ref is plain |
| DM3 | Unit/part container shape? | Ordered self-describing lists; no maps or nested units |
| DM4 | Attribute value type/order? | Text-canonical; insertion order is presentation-only and digest order is sorted |
| DM5 | Source and opener one interface? | No. Every source resolves; only provider-bound refs require their provider to open |
| DM6 | Definition-time source/opener I/O? | Never. Only `staticShape(role)` participates in the walk |
| DM7 | Cursor shape? | Plain pull reader owned and offloaded by its consumer |
| DM8 | Static shape owner? | `DataSource`; bounded concrete inspection belongs to `DataOpener`; both return explicit observed/unavailable results |
| DM9 | Shape cases? | No representation cases. `DataShape` contains one recursive semantic `itemType`; `Tabular` is a record projection and `Payload` is not a shape category |
| DM10 | Schema cache identity? | Effective ref/format/encoding plus complete size/modified fingerprint; otherwise do not cache |
| DM11 | Durable provider identity? | `DataSourceId`, minted and resolved only with the first provider-bound source |
| DM12 | Stateful source ownership? | Borrow caller-owned resources; design-time lifetime remains open until the first stateful source |
| DM13 | Authored resolution? | `LogicDataSource` with named hosting and eager `Iterable<DataUnit>` result |
| DM14 | Cross-run results registry? | Deferred; same-run `DataRef` composition does not imply persistence |

## 8. As-built provenance

- **DS0** moved the neutral header and input plumbing out of Report-owned packages.
- **DS1** landed the value types, digests, strict wire/lowering forms, fingerprints and construction helpers. It
  also landed `DataShape.Tabular | Payload`; the 2026-08-27 review rejected that sum because it models Job's
  carrier rather than data semantics. The corrected §4 contract is authoritative and its code migration remains
  to land.
- **DS2** landed the suspend SPI, file source/opener/cursor, opener lookup, detached actions and file-selection
  model.
- **DS6** separated declared from inspected shape, renamed/consumed `DataSchema`, and replaced the stale Report
  column-cache identity. Its labels-only schema projection is part of the same pending correction.
- **DS8** added runtime hosting to `DataContext` and proved authored resolution through `LogicDataSource`.

The complete verification counts, implementation surprises and Job-facing outcomes remain in the Job document's
as-built ledger so the DS arc has one chronological record.
