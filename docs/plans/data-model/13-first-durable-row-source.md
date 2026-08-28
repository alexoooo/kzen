# DM13 — first durable row source, constraints, and measured lifetime

> **Status: design-gated; do not execute until the project-data store/provider is chosen. One session only after the
> database plan is execution-ready.** Authority: unified data model §§4.4, 6.2, 9, 14.5 step 8, open questions 3
> and 6; project-data analysis owns providers, storage, transactions, and migrations.

## Gate and outcome

Choose the first real provider/query source and its write/read lifecycle. This session turns DM5's fake typed row
into a real row-backed `ValueAccess`, introduces only the scalar/metadata/constraint vocabulary that provider
actually requires, and decides retention from measured cursor behaviour. It does not design the durable store or
graph integration.

## Implementation

1. Measure row reuse, driver getter cost, batch retention, cursor advance/close, cancellation, Job queueing,
   migration, hosted results, and root post-settlement access. Record copy-per-row versus borrowed-row cost.
2. If copying meets the performance gate, preserve v1 reachability and add no lease API. If it does not, stop for a
   reviewed lifecycle subdesign covering owner identity, retain/release leases, at-most-once transfer, synchronous
   traversal, hosted results, batching, migration, and expiry diagnostics. A bare `Owned|Detached` enum is rejected.
3. Implement the provider row backing with typed primitive reads, stable shared descriptors, explicit transactions
   for mutation, and no write-through through `ValueAccess`.
4. Add `LocalDateTime` as a distinct scalar if the provider exposes timestamp-without-timezone. Never coerce it to
   `Instant`; preserve offsets/precision as representation metadata.
5. Resolve open question 3 with the smallest container that the provider needs for precision/scale, enum symbols,
   temporal precision, provider IDs/aliases, affinities, and migration round-trip. Access shape stays in `DataType`;
   validation restrictions and representation details stay beside `DataContract`.
6. Add decimal precision/scale validation without parameterizing `ScalarKind.Decimal`. Reopen enum identity only if
   the selected carried schema requires it for union/default semantics; otherwise keep enum as text plus symbols.
7. Integrate query shape/cursor through the existing source protocol and the one-value Job path. Store writes remain
   explicit repository/transaction commands.

## Proof and exit

- Read identical typed rows from fake and real backings; cover null/absent, precision/scale, local date-time versus
  instant, enum symbols if used, provider metadata round-trip, and transaction isolation from read access.
- Prove emitted values remain readable for the chosen lifetime across real Job cadence, or prove the reviewed lease
  protocol across every lifecycle named above.
- Benchmark primitive reads, per-row allocation, copy/borrow strategy, and end-to-end throughput against DM7.
- Run provider integration tests in an isolated temp database, then full owning sibling builds in publication order.
- Exit with open questions 3/6 and the lifetime verdict recorded in the project-data authority, not duplicated here.

## Explicitly still deferred

Richer `WireValue`, graph provenance/exposure/stable references, recursive named types, nested unions, universal
invalid values, and graph creation from rows remain separate consumer-driven designs. This session does not make
them incidental dependencies.
