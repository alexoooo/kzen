# Content streaming and containers — review 1

Review of [Content streaming and containers: files as first-class Job elements](2026-09-15_content-streaming-and-containers.md), captured 2026-09-15.

## Overall assessment

The problem is real, and the central direction is sound: files should be elements, with streamed content behind a handle. Separating containers from compression and keeping byte chunks below the Worker interface are good decisions.

Keep that foundation, but revise the access model and handoff semantics before accepting this as an implementation design. The document understates those changes as “one scalar kind, one element shape, one channel rule.” Borrowed content is a first-class execution concern, with consequences for ownership propagation, validation, migration and serialization.

## What to keep

- **`Entry { metadata, content }`** gives Filter, Formula, readers and writers a useful shared vocabulary.
- **Containers enumerate entries; codecs transform bytes.** That distinction makes nested archives easier to reason about.
- **Explicit spooling** makes a potentially large storage cost visible.
- **Descriptor-only previews** avoid accidentally reading gigabytes to render a card.
- **One implementation behind `ContainerSource` and `Entries`** is a sensible ergonomic split.

The motivating tar.gz → selected individual gzip files is a good acceptance case. It exposes a real lifetime problem that ordinary resource cleanup does not solve.

## 1. Separate access, lifetime and persistence

The biggest architectural objection is that `Durable | Transient` combines too many guarantees:

| Property | Question |
|---|---|
| Lifetime | Does this survive advancing the parent cursor? |
| Repeatability | Can it be opened again? |
| Concurrency | Can two readers open it simultaneously? |
| Seekability | Can byte ranges be accessed? |
| Persistence | Can another run resolve it? |
| Consistency | Will another open return the same bytes? |

These properties do not always travel together:

- An HTTP body can be single-use without depending on a container's position.
- A scratch-backed spool can be reopenable within a Job but disappear when that Job ends.
- A file reference needs a consistency policy; having an address does not itself guarantee stable bytes.
- A decoded stream can be recreated from a reopenable compressed source even though each opened stream is sequential.

Distinguish at least single-use, reopenable and cursor-borrowed content, and treat persistent addressability separately. These should represent distinct guarantees, not necessarily another mutually exclusive enum. Seekability can remain an optional capability.

Replace the claim that durable content is always convertible to a `DataRef` with:

> Persistently addressable content exposes a reference; other content can be explicitly published to obtain one.

This gives `Spool` and `ContentWriter` distinct responsibilities: temporary materialization versus publishing an output. A spool's lifetime and cleanup owner must be explicit before permitting it to escape as a Job result.

## 2. Define a precise handoff protocol

The required invariant is correct:

> The cursor cannot advance while downstream still depends on its current entry.

But “send waits for every hold” can deadlock if applied literally. Consider:

```text
Archive → Formula → Writer
```

Formula holds the input during its callback. If Formula's output send waits for every hold on that content to disappear, it waits for its own callback hold, which cannot disappear until that send returns. The source's own producer lease creates a similar issue.

Prefer a cursor-owned entry-completion token. Ordinary forwarding transfers or adds downstream dependencies; the cursor alone waits for completion before advancing. Precisely define which holds count toward completion, excluding the cursor's authority to manage the entry.

A rendezvous channel acknowledges receipt. This design needs acknowledgement of finished use, which is stronger.

Add a state machine covering the entry lifecycle, for example:

```text
offered → opened → consumed/discarded → released → cursor may advance
```

The full protocol must include failure, cancellation, never-opened entries and partially read entries. Closing an entry view needs an explicit contract: finish or discard that entry without inadvertently closing the whole archive.

## 3. Let metadata shed the content dependency

This pipeline should work without spooling:

```text
Archive → project { name, size } → Sort → Result
```

It retains metadata, not file bytes.

The current [RunOwnershipLedger](../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/exec/job/ownership/RunOwnershipLedger.kt), in `inherit`, conservatively gives a derived non-scalar value all its parent's owners. Under the proposal, a metadata record could remain positional and become impossible to retain.

Conversely, the ledger excludes scalars from ownership inheritance and closeable-root discovery. Making `Content` a scalar means those fast paths must change.

Distinguish explicitly between:

- Outputs that still reference borrowed content.
- Outputs whose data is independent of the input.

For known structural projections, the framework may be able to establish that distinction. Arbitrary native expressions need a conservative fallback or an explicit operation that produces independent data.

The same consideration applies to parsed CSV rows: independently materialized rows should not unnecessarily retain the archive entry.

“Existing Workers unchanged” is too strong. Their user-facing behavior can stay familiar, but ownership propagation needs work.

## 4. Negotiate capabilities when opening a container

The document partly recognizes source-dependent access with `zip.gz`, but the API still puts `access` on `ContainerFormat`.

Prefer:

```text
format + source capabilities + decoding → opened cursor capabilities
```

There is also a correctness issue with the ZIP acceptance criterion. Streaming ZIP is not simply indexed ZIP with slower access: Apache documents differences involving central-directory membership, duplicate names, missing metadata and initially unknown sizes. See the [Commons Compress ZIP documentation](https://commons.apache.org/proper/commons-compress/zip).

Do not promise that arbitrary `zip.gz` transparently yields equivalent transient entries. The available options should be explicit:

- Use streaming ZIP with documented limitations.
- Spool to obtain indexed access.
- Reject archives that require unsupported access.

A directory or object-store prefix is an entry source, but not naturally a finite byte sequence. Let byte-backed archives and collection-backed sources share an entry interface without forcing directories into `Content`.

## 5. Revisit live editing at entry boundaries

“Only one entry in flight” does not imply migration is simple. That entry might be a huge file, a nested archive, or a CSV expansion producing millions of rows.

The current [ExpandingTransformWorker](../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/ExpandingTransformWorker.kt) explicitly checkpoints inside an element's expansion and migrates its active input and cursor.

Choose between:

- **Entry-boundary migration:** simpler, but edits may wait a long time.
- **Mid-entry migration:** carry the cursor, entry dependency, decoder, reader and any pipe together.

The writer's proposed “re-truncate the current file” default is particularly problematic. If the input is already halfway consumed and cannot rewind, restarting the output loses its prefix.

Initially, prefer entry-boundary edits and finish the current output under its original configuration. Mid-entry adoption can be a separate capability. Entry-boundary editing still needs to be reconciled explicitly with the engine's existing checkpoint and quiescence protocol.

## 6. Separate runtime handles from serialized descriptions

Today [DataPart](../../../kzen-auto/kzen-auto-common/src/commonMain/kotlin/tech/kzen/auto/common/data/model/DataPart.kt) is serializable and digestible. A borrowed stream cannot round-trip through that representation.

A descriptor snapshot is useful for inspection, but it is not a restorable `Content` value. Two descriptors can also describe different bytes.

Make the distinction explicit:

- **Part specification:** role, reference, fingerprint, resolved read configuration.
- **Runtime readable part:** role, acquired content, resolved read configuration.
- **Content snapshot:** descriptive information, with explicit replayability.

The reader can share one runtime opening path without requiring the persisted model to carry live handles.

Also, the current [ReadPartWorker](../../../kzen-auto/kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/objects/job/worker/data/ReadPartWorker.kt) accepts `DataUnit`, and its schema-superset path inspects parts before opening them. One-shot content needs an inspection strategy that does not consume the only open: declared schema, bounded replay buffering, or inspection within the same reader session.

## 7. Additional requirements

### Output semantics

Specify path containment, duplicate entry names, case collisions and partial-file behavior. These directly affect the motivating task of writing archive names into a directory.

Prefer writing to a temporary destination file, finalizing the encoder, then publishing by rename where supported. This need not add another full byte copy. Emit `Written` only after successful publication.

### Aggregate budgets

A memory limit per spool does not bound a retained collection: thousands of small spools can all stay in RAM. Require Job-wide accounting for spool memory, scratch space, active pipes and encoder buffers.

### Static validation and runtime guards

`Content` alone does not tell validation whether a value is positional. Automatic format detection, mixed archive inputs and arbitrary Formula outputs make this especially important.

Define how lifetime capabilities propagate through contracts. Reject known-invalid retention statically; retain runtime checks for cases that cannot be proven.

### Acceptance coverage

Add tests for:

- Forwarding through multiple Workers without deadlock.
- Metadata-only projection followed by Sort.
- Nested `Entries`.
- Early termination and partial reads.
- Cancellation while a pipe is blocked.
- Failure during encoder finalization.
- Thousands of small retained spools.
- Migration during a large entry.

Change “zero copies” to “no whole-entry materialization or redundant full pass.” The proposed byte counters prove external I/O volume, not absence of internal copying.

## 8. Alternative: scoped sub-Jobs

An alternative worth considering is an explicit scope per entry:

```text
ForEachEntry:
    select: "*.txt"
    body:
        WriteContent: gzip
```

Each entry is borrowed for the lifetime of its body. The body may filter, parse, transform or write; returning bytes beyond the scope requires explicit materialization.

This makes the lifetime boundary structural and avoids changing every channel into a potential completion-acknowledged transfer. The tradeoff is less freedom to compose arbitrary graphs across entry boundaries.

A hybrid could work well: scoped execution internally, the simple `ContainerSource → ContentWriter` notation externally, with validation permitting only transformations that preserve the scope.

## 9. Answers to the open questions

1. **Scalar or native capability:** start with a declared native `Content` capability before committing to a new scalar. Establish its ownership, snapshot and expression semantics first. A scalar may ultimately be justified, but it does not by itself solve those concerns.
2. **Directory naming:** keep `FileSource` as a convenient user-facing name while sharing entry-source machinery where useful. Avoid forcing a directory to masquerade as byte content.
3. **Pipe default:** off until measurements establish the benefit and aggregate resource cost. Introduce overlap as a measured transport optimization.
4. **Name expressions:** use Formula for complex naming initially. Avoid a second expression mechanism in `ContentWriter` unless concrete authoring needs justify it.

## Recommendation

Keep the product model and worked examples. Before implementation, rewrite the design around:

1. Separate access, lifetime and persistence capabilities.
2. Cursor-owned completion with deadlock-free forwarding.
3. Explicit ways for outputs to become independent of borrowed input.
4. A clear entry-boundary migration policy.
5. Separate runtime handles and serialized specifications.

The direction is sound. Treat borrowed content as a first-class execution concern, and the file-level abstraction can compose safely without hiding materialization costs.
