# Job data source design — review

**Date:** 2026-08-23

**Status:** Design review — **applied 2026-08-23.** The disposition of every point below is recorded in the analysis doc's [§15 third-pass record](./2026-08-20_job-data-source.md#15-third-pass-review-2026-08-23--what-changed-and-why) (C10–C15, D6–D12) and the DS plans were recut accordingly. Points adopted: the four blocking contradictions, the order/equality digest, plain file refs with `DataSourceId` deferred, `DataShape` with static/inspected split and a cache service, one generic resolve action with `DataResolveResult`, the `DataSources` document deferred, expressions out of the read path, named host arguments, DS1b's registry wording. Points **not** adopted, with the reason in §15: the suspend `DataCursor.next()` (a plain pull reader the worker drives was chosen — O20); a persisted artifact registry (v1 refs are plain paths; same-run composition is the contract — §7.1); "structural references conflict with policy" (the policy is object-as-*data* → nominal; a collaborator is structural — what was missing was the delete case, now C15). Note: the file links in this review originally pointed at non-existent paths (`model/runtime/JobControl.kt`, `plugin/api/worker/CsvReaderWorker.kt`) with line numbers; they were corrected to the real locations below and the line numbers dropped (CC-20). The substance was verified against the tree regardless.

**Reviewed:** [job data source analysis](./2026-08-20_job-data-source.md) and plans [DS0](../plans/next/DS0_schema-vocabulary-move.md), [DS1](../plans/next/DS1_data-model.md), [DS1b](../plans/next/DS1b_inference-visibility.md), [DS2](../plans/next/DS2_data-source-and-file-source.md), [DS3](../plans/next/DS3_read-worker.md), [DS4](../plans/next/DS4_sources-editing-surface.md), [DS5](../plans/next/DS5_read-part-worker.md) (at review time `DS5_expand-and-expression-scope.md`), [DS6](../plans/next/DS6_design-time-schema.md), [DS7](../plans/next/DS7_writer-data-ref.md), and [DS8](../plans/next/DS8_logic-data-source.md) — all as they stood on 2026-08-21b, before the recut.

## Executive assessment

The central design makes sense. It has a strong value model, a good separation between selecting data and reading it, and a plausible path from a simple file chooser to reusable and non-file sources.

I would not execute the DS plans as currently written, however. The main issue is not a missing implementation detail: the proposed expression-facing read path conflicts with the existing suspend-based execution model. Several later plans then add adapters, blocking bridges, schema caches, and special expression helpers to preserve that path. Removing data access from ordinary expression evaluation produces a smaller design while retaining the important goals.

The recommended core is:

- sources resolve references asynchronously;
- openers and cursors perform reads asynchronously;
- workers own all effects, resource lifetime, cancellation, and quiescence;
- expressions may manipulate already-materialized values, but do not initiate source I/O;
- schemas distinguish tabular structure from Kotlin payload type;
- manifests describe a selection unless they also carry enough information to reproduce and validate the selected bytes.

## What is already strong

The following choices should be preserved:

- **DataManifest → ordered DataUnit → ordered DataPart** is a useful domain vocabulary. It handles the trivial one-file case without preventing grouped inputs such as a main file plus attachments.
- **Source and format are orthogonal.** A local file, remote object, database query, and user-authored resolver should converge on the same downstream reading contract without becoming the same abstraction.
- **Selection belongs on the source object.** It should not remain frozen worker configuration. This enables reusable sources, chooser UI, refresh, and inspection.
- **A generic ReadWorker is the correct user-facing center.** Source, reader, and sink form a comprehensible three-card trivial job.
- **Resolve once per run and carry the manifest through execution.** Re-resolving a source at each consumer would introduce drift and repeated I/O.
- **Do not walk payloads to discover types.** Schema discovery must be explicit metadata or bounded inspection, not an accidental full read.
- **Heterogeneous input needs an explicit policy.** Failing loudly or deliberately computing a superset is better than silently corrupting downstream assumptions.
- **A DataSources document analogous to Contexts is useful.** It gives shared sources a visible home and supports reuse across jobs.
- **A user-authored LogicDataSource is worth having.** It is a natural escape hatch for sources whose manifest is computed from domain logic.

## Blocking contradictions

### 1. The proposed DataScope cannot implement its contract

The analysis proposes non-suspend DataSource operations backed by DataScope.blocking and DataScope.host. The actual JobControl operations are suspend functions:

- `JobControl.runBlockingIo` — [`JobControl.kt`](../../../kzen-auto/kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/paradigm/job/control/JobControl.kt)
- `JobControl.host` — same file

Although runBlockingIo accepts a non-suspend lambda, calling runBlockingIo is itself suspend. A non-suspend DataScope method therefore cannot simply delegate to either operation. This invalidates the assumed bridge in DS2, the ordinary Sequence read path in DS3, and the host-backed LogicDataSource in DS8.

The clean correction is to make source resolution and reads suspend operations. They are effects and should be represented as such.

### 2. The proposed sales.units() expression is absent and unsafe

The planned source SPI exposes units(scope), while DS5 shows expressions such as:

    sales.units()

There is no parameterless adapter in the plans that supplies the scope. More importantly, such an adapter would conceal source resolution that may perform file, network, or host I/O inside ordinary generated expression code.

This is the wrong execution boundary even if an adapter can technically be added. It makes cancellation, progress accounting, quiescence, and resource ownership implicit.

### 3. Sequence cannot safely represent an I/O-backed item stream

DS3 treats DataItems as Sequence and says iteration performs ordinary I/O. The existing CSV reader demonstrates why this does not fit: each read currently enters the job's blocking-I/O machinery in [`CsvReaderWorker`](../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/CsvReaderWorker.kt) (`control.runBlockingIo { reader.readRecord() }` per record).

Sequence.next cannot suspend. Hiding blocking inside it either:

- bypasses the job's I/O accounting and cancellation model;
- repeatedly creates blocking bridges;
- or forces the caller to know that an apparently ordinary sequence is effectful.

The worker should own iteration over a suspend cursor. Plain Sequence should remain an in-memory abstraction.

### 4. DS8's host-argument examples are inconsistent

One DS8 example models from and to as separate script parameters, while another sends one map as the first positional argument. These are not the same call shape.

The direct fix is a named host overload that preserves TupleValue:

    suspend fun host(
        instructions: ObjectLocation,
        arguments: TupleValue
    ): TupleValue

The existing single-input overload can remain as a convenience. Execution.host already operates on TupleValue, so flattening named arguments into a synthetic map is unnecessary.

## Value-model issues to settle before DS1

### Ordered maps conflict with equality and digest semantics

DS1 describes part order as significant, uses Map, and expects order-sensitive digests. Kotlin Map equality is order-insensitive. Two DataUnit values could therefore compare equal while producing different digests.

Choose one invariant:

- If order is semantic, use an explicitly ordered, order-sensitive representation, such as a list of role/part entries or a dedicated ordered collection with matching equality.
- If order is presentation only, retain Map equality and canonicalize the digest by sorting entries.

For role-addressed parts, presentation-only order is probably sufficient. Unit order in DataManifest is clearly semantic and should remain list-based.

### A resolved manifest is not necessarily reproducible

A manifest containing paths, roles, and inferred format is a stable selection description, but not a stable snapshot of the data. If format or encoding remains null, or if files can change after resolution, later reads may decode different content.

The terminology and contract should distinguish:

- **selection manifest:** what was selected, in what order;
- **reproducible manifest:** the effective reader choices and enough fingerprint information to detect changed content.

A reproducible file part would normally capture effective format and encoding plus a fingerprint such as size, modification time, and preferably a content digest where the cost is acceptable. The opener should define whether it validates those values.

### File references need not be provider-bound

For a normal file, path plus effective format and encoding is enough for a shared file opener. Requiring every file reference to retain its FileDataSource ID creates identity coupling without adding read capability.

Provider identity is valuable for references that cannot be opened without provider configuration, such as JDBC, authenticated APIs, or object stores. A practical rule is:

- provider/source ID is optional for self-contained references;
- provider/source ID is required for provider-bound references;
- duplicate IDs are an error, not first-match behavior;
- blank or derived IDs are not durable for persisted references.

If references survive beyond one run, consider carrying a provider-definition or configuration digest so a changed source with the same ID can be detected.

## Schema needs two explicit concepts

The plans mix two meanings of schema:

1. tabular fields, such as CSV headers and field types;
2. the Kotlin TypeMetadata of each emitted payload object.

A field map is not a single payload item type. Treating both as DataSchema makes reader APIs and downstream inference ambiguous.

A clearer vocabulary is:

    sealed interface DataShape {
        data class Tabular(
            val fields: List<DataField>
        ) : DataShape

        data class Object(
            val type: TypeMetadata
        ) : DataShape
    }

    data class DataField(
        val name: String,
        val type: TypeMetadata? = null
    )

The API should also separate pure knowledge from effectful inspection:

    fun staticShape(role: DataRole?): DataShape? = null

    suspend fun inspectShape(
        context: DataContext,
        part: DataPart
    ): DataShape? = null

This resolves another plan mismatch: DS3 asks for a payload type before reading, while DS6 often cannot inspect a header until a concrete DataPart exists at runtime. Static shape can be available before resolution; inspected shape is necessarily part-specific and effectful.

Schema caching should be a separate service or policy keyed by the concrete part fingerprint and reader configuration. HeaderListingReader can then be an adapter over inspected tabular shape rather than an independent schema system.

## A simpler execution architecture

The smallest coherent model keeps effects in workers and separates selection from opening:

    interface DataSource {
        suspend fun resolve(
            context: DataContext
        ): DataManifest
    }

    interface DataOpener {
        suspend fun open(
            context: DataContext,
            part: DataPart
        ): DataCursor

        fun staticShape(
            role: DataRole?
        ): DataShape? = null

        suspend fun inspectShape(
            context: DataContext,
            part: DataPart
        ): DataShape? = null
    }

    interface DataCursor : AutoCloseable {
        val shape: DataShape?

        suspend fun next(): Any?
    }

A concrete object may implement both DataSource and DataOpener, but the contracts should not force that combination.

Examples:

- FileDataSource resolves a chooser or file specification into provider-independent file parts; a shared file opener reads them.
- LogicDataSource resolves a manifest through host execution and does not need to be an opener.
- JdbcDataSource may implement both because its references are meaningful only with the connection/provider configuration.

DataCursor.next being suspend keeps every read inside the execution model. The owning worker can reliably manage:

- cursor close in finally;
- cancellation;
- quiescence and blocking-I/O accounting;
- progress and cadence;
- schema inspection or validation;
- migration behavior;
- source/unit/part stamps on emitted values.

### Two workers cover the important cases

The first worker is the normal entry point:

    ReadWorker(source, emit = items | units)

It resolves once, opens parts as needed, and either emits decoded items or passes DataUnit values downstream.

The second supports grouped and nested data:

    ReadPartWorker(input = DataUnit, role = "main")

It opens one selected part from an already-resolved unit. This provides composition such as processing a main document and its attachments without letting expressions initiate source I/O.

A generic ExpandWorker can still exist for in-memory Iterable, Iterator, or Sequence values. It is independently useful, but it should not be required by the data-source design and should not be the bridge for effectful reading.

## UI and graph-model gaps

### Resolve capability must be explicit

The generic source card assumes every DataSource exposes resolve as a DetachedAction, but the proposed source contract does not guarantee that. Either:

- make interactive resolution an explicit capability implemented by chooser-capable sources; or
- route resolution through a generic controller/service that operates on a DataSource.

The second option avoids putting UI action mechanics into every source implementation.

### Define the resolve result once

DS2 mentions a manifest plus skipped-count information, while DS4 decodes a bare DataManifest. Use one contract, for example:

    data class DataResolveResult(
        val manifest: DataManifest,
        val diagnostics: List<DataDiagnostic>
    )

Diagnostics can represent skipped files, unsupported extensions, duplicate roles, warnings, or partial inspection failures without changing the manifest model.

### A DataSources document needs full authoring support

Adding the document itself is not enough. DS4 describes source cards primarily through JobController, leaving shared sources at risk of becoming raw notation that cannot be authored through the same UI.

The design should specify:

- a DataSources controller or common object-authoring controller;
- insert, rename, delete, and duplicate-ID behavior;
- how a Job selects a local versus shared source;
- how aliases appear in expression or card scopes;
- how references update when a source is renamed.

### ID validation needs a graph-wide owner

Duplicate DataSource IDs cannot be validated reliably by whichever worker happens to build a registry first. Define whether uniqueness is:

- document-local;
- project-wide;
- or qualified by document/object path.

Then enforce it in the graph/notation validation layer and surface it before execution.

### Structural references conflict with current object-as-data policy

The plans propose structural DataSourceRef values, while the kzen-auto guide describes object-as-data references as nominal. Structural references may be the correct choice because they are real runtime dependencies rather than arbitrary object values, but this is a policy change.

The plans should explicitly reconcile the exception and test deletion, duplication, rename, and serialization behavior—not only the happy-path rename.

### Shared-source expression visibility is unspecified

DS5 discusses expressions over sources nested in the current Job. A source in the shared DataSources document needs an accessor or aliasing rule if expressions are expected to name it. If effectful source operations are removed from expressions, this problem becomes much smaller: cards need object references, while expressions only see materialized outputs.

## Across-run references are not yet designed

DS7 covers nested in-process composition well: a writer can emit a reference that another worker in the same execution opens. It does not yet provide a reference that a future independent run can discover and consume.

Current execution outcomes do not automatically preserve arbitrary domain values:

- successful TupleValue results are deliberately omitted from [`OutcomeTrace`](../../../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/exec/engine/OutcomeTrace.kt);
- [`ExecutionValue.ofArbitrary`](../../../kzen-lib/kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/exec/ExecutionValue.kt) handles scalar, list, and map shapes, not a DataRef domain object;
- adding an asExecutionValue helper does not make TupleValue serialization invoke it automatically.

The design should distinguish:

- **nested composition:** pass a DataRef directly between workers in one execution;
- **persisted artifact result:** register a durable reference in an artifact/result store that later runs can query.

A DataSourceId alone does not persist an output reference. Persisted results also need retention, naming/versioning, authorization, validation, and cleanup policies. This capability should be optional and later than the same-run model.

## DS1b correction

DS1b identifies a real generated-code nameability problem, but the planned registry exception is too permissive. If ObjectRegistry can force an internal class through the nameability guard, generated code in another module still cannot import or reference that class.

The predicate should reflect Kotlin language visibility, including enclosing declarations. Registry presence may establish semantic registration, but it cannot override source-level accessibility.

This is useful infrastructure work, but it is independent of the core source/read design and should not block early value-model prototyping.

## Recommended recut

The current sequence can be simplified to six core phases:

1. **Value model and invariants**
   - DataManifest, DataUnit, DataPart, DataRef;
   - order/equality/digest decision;
   - provider-bound versus self-contained reference semantics;
   - selection versus reproducibility contract;
   - DataShape vocabulary.

2. **Suspend source/read runtime**
   - DataSource, DataOpener, DataCursor;
   - FileDataSource and shared file opener;
   - ReadWorker with items or units output;
   - cancellation, close, and quiescence tests.

3. **Chooser and authoring UI**
   - source cards;
   - interactive resolve capability;
   - DataSources document and controller;
   - graph-wide ID validation;
   - local/shared source references.

4. **Schema inspection**
   - static versus inspected shape;
   - cache policy and fingerprints;
   - heterogeneous-input policy;
   - superset behavior where deliberately enabled.

5. **Composition**
   - named host arguments via TupleValue;
   - LogicDataSource;
   - ReadPartWorker for grouped units.

6. **Outputs**
   - writer-produced DataRef for same-run composition;
   - optional persisted artifact registry as a separate feature.

DS0 remains an optional mechanical vocabulary move. DS1b remains an independent compiler/code-generation correction. ExpandWorker remains an independent in-memory utility.

## Plan-by-plan impact

| Plan | Recommendation |
|---|---|
| DS0 | Keep if the vocabulary move reduces later churn; it is not architecturally significant by itself. |
| DS1 | Keep, after resolving order/equality/digest, provider identity, reproducibility, and shape terminology. |
| DS1b | Keep independent; remove any registry exception that permits inaccessible Kotlin types. |
| DS2 | Rewrite around suspend resolution and the source/opener/cursor split. |
| DS3 | Keep the generic reader goal; replace Sequence-backed I/O with a suspend cursor owned by the worker. |
| DS4 | Keep; add a real DataSources authoring path, one resolve-result contract, and graph-wide ID validation. |
| DS5 | Remove from the critical path. Keep ExpandWorker only as a generic in-memory utility. |
| DS6 | Reshape around DataShape and separate static shape, part inspection, and caching. |
| DS7 | Clarify same-execution references versus persisted artifacts; implement the former first. |
| DS8 | Keep; use named TupleValue host arguments and suspend source resolution rather than a blocking expression bridge. |

## Final position

The foundational idea is good: explicit data references, reusable sources, a generic reader, chooser UI, grouped manifests, and user-authored source logic can make Job substantially more capable than the current Report-oriented path.

The main pushback is against treating source resolution and reading as ordinary expression operations. They are effects. Keeping them in workers removes the largest contradiction, reduces the number of bridge abstractions, and preserves the execution engine's existing guarantees. With that change—and with the value, schema, identity, and persistence contracts made explicit—the design is coherent and worth pursuing.
