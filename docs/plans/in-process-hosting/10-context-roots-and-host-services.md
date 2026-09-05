# HS10 — Context-owned work roots, host services and shutdown

> Status: not started. One implementation session. Prerequisites: HS09.
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

Not executed.
