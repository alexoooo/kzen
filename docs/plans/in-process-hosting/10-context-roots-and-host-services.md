# HS10 — Context-owned work roots, host services and shutdown

> Status: complete 2026-09-05 (one test noted partial). One implementation session. Prerequisites: HS09.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §3 and extensibility plan E2 host/root contracts.

## Outcome and anchors

KzenAutoConfig, KzenAutoContext.create/close, WorkUtils, JobWorkPool, ServerLogicController.close, KzenAutoMain and storage registration.

## Work

1. Add configurable workRoot with a standalone default; make every workspace work path and per-context signature instance-owned. Trace scratch, persisted Worker output, compiler/cache storage and cleanup paths, not only JobWorkPool.
2. Create root, resolve toRealPath, then atomically claim it on the runtime before any sweep. Duplicate roots fail; construction rollback releases the claim. Audit overlapping cleanup paths as well as equal roots so configured storage cannot erase another live context.
3. Add immutable KzenAutoHost services and a Class<?>-keyed Java builder with assignability checks. Merge after built-in services and fail on collisions; preserve interface registration for Java/Spring proxies.
4. Make close cancel and join active execution before claim release. The server owner stops/awaits its server first; standalone lifecycle and the future Spring adapter use this sequence. If shutdown cannot join, do not advertise the root as safely reusable.
5. Make the logs managed-storage area suppressible for a foreign host. Keep logging backend ownership with the host; do not introduce per-context logDir or process-global shutdown side effects.

## Verification and exit criteria

Use two isolated contexts: boot sweep, output cleanup, notation edit, cancellation and close in A leave B's files/state/run untouched. Test real-path aliases, duplicate claims, construction failure, service collisions/interface binding and claim reuse only after run join. Use a controlled active callback to prove shutdown ordering.

## Handoff

Record public builder/config API and lifecycle responsibilities. This covers E2's host/root slice; hosted integration is HS23–HS24.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 in kzen-auto-jvm (`KzenAutoConfig`, `KzenAutoContext`, `WorkUtils`, `WorkRootRegistry`,
`KzenAutoHost`, `ServerLogicController`, `ReportWorkPool`, `KzenAutoMain`).

**Work roots.** `KzenAutoConfig.workRoot` (`--work.root=`; null = the standalone default `../work`).
`WorkUtils` is instance-owned: `WorkUtils(base, signature)` with `sibling()` / `temporary(name)` /
`freshSignature(token)`; the signature (claim token + random) marks what *this* context wrote (Report output
info files read another context's mark as dead). Every work path — Job scratch (`JobWorkPool`), persisted
Worker output, the compiler cache and the schema cache — resolves through the context's own `WorkUtils`.
`KzenAutoContext.create` creates the root, `toRealPath()`s it and claims it on `runtime.workRoots`
(`WorkRootRegistry`) **before** any boot sweep; a root another live context holds, an alias of one, or one
nested inside / containing a held root (overlapping cleanup paths) fails by name; any failure after the claim
releases it (rollback). `close()` runs `ServerLogicController.closeAndJoin()` (cancel the active run and join
it, bounded at 10 s) and releases the claim only if the run joined, otherwise logs and keeps the root claimed;
`isWorkRootReleased()` reports which. The server owner stops its server before `close()` (standalone
`KzenAutoMain` shutdown hook; the Spring adapter follows the same order in HS23).

**Host services.** `KzenAutoHost` is immutable; `KzenAutoHost.builder().service(Class<T>, T)` (Java-keyed, with
`isInstance` assignability so a proxy can be registered under the interface a Worker declares) and the reified
Kotlin overload; a second registration of one type fails by name. `KzenAutoConfig.hostServices` is merged into
the `GraphEnvironment` **after** kzen's built-ins, so a key kzen already provides fails context creation by name
(and the claim is rolled back).

**Logs.** `KzenAutoConfig.manageLogs` (default true) gates the cwd-relative `logs/` managed-storage area; a
foreign host turns it off and keeps its own logging backend. No per-context `logDir`, no process-global shutdown
side effect was added.

**Verification, `WorkRootAndHostBootTest` (forked).** Two isolated contexts A and B: A's boot sweep and scratch
stay inside A's real-path root and B's marker file survives; duplicate, aliased (`..`-spelled) and nested roots
fail by name and leave no claim; distinct signatures; a plugin Worker needing a host service is `Unavailable`
in A and `Available` (and constructible, resolving the proxy through the Java interface) in a providing
context created afterwards, with A unaffected; a host key kzen provides fails creation by name and rolls back
the claim; the builder refuses a non-instance; the logs area is present only when managed; after close both
claims are released and the registry is empty. **Partial:** the "controlled active callback" shutdown-ordering
test (a run that blocks in a callback while `close()` is called, proving cancel → join → release) is not yet
written; `closeAndJoin()` implements the ordering and the unjoined case keeps the claim, but that path is
presently proven only by the joined case. Recorded here for HS23 (hosted lifecycle), which exercises the same
sequence under the Spring adapter. *(Closed in HS25: `HostIsolationIT.stoppingAWorkspaceWithARunActiveCancelsJoinsAndReleasesWhileTheOtherServes`
stops a workspace while a fifty-million-element run is active — cancel → join → `work root released`, no
`stays claimed` — with the other workspace serving throughout.)*
