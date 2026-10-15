# Resources — one application-wide policy (problem definition)

Status: problem definition only, for the user's review. No design or code yet. Facts below were checked in the code
on 2026-10-14; `file:line` references are to that tree.

## 1. The problem

Kzen runs user logic (Script, Flow, Job, and Jobs hosted inside Scripts) that holds things which must be released:
a browser, a spawned process, an open stream, a host object that holds native memory (the ITCH symbol-day batch,
whose close returns memory to the host's budget). Today two unrelated mechanisms release them, with different
rules, and neither covers every case:

- **The engine's scoped disposal** (kzen-lib) releases what a *frame* registered, when that frame settles.
- **The Job's value ledger** (kzen-auto) releases closeable *values* that pass between Workers, when the Job run
  ends. It knows nothing of the engine's registry, and nothing else uses it.

The result is that the same object is handled differently depending on where it appears. Concretely:

1. A Job closes every closeable value it owns **before** it returns its result to the caller
   (`kzen-auto-jvm/.../exec/job/JobRun.kt:363-365`, then `:368`). So a Job cannot return a live resource. To get
   around this, the Result Worker deep-copies every owned element into plain data (`ResultSinkWorker.kt:110`,
   `EngineJobControl.snapshot`, kzen-lib `DataSnapshot`). That cannot work: an arbitrary object graph may be backed
   by native handles, and there is no safe way to copy it. The copy also has invented caps (`SnapshotPolicy`) and
   rejects shared values as cycles.
2. A closeable value that a Script, Flow or Logic step returns as its value is not tracked at all. Only what a
   step implementation explicitly registers with the engine is ever closed (no closing code under `exec/script` or
   `exec/flow`).
3. The Job adds rules nobody asked for: a process-wide `NativeIdentityRegistry.global` that refuses an object a
   second run takes over, shared by every project in the JVM.
4. Nothing shows the user what holds a resource or when it will close. The Job's only view of it is a "stalled"
   warning on a 2 s timer (`JobOwnershipReport`).

The user's direction (2026-10-14): "we need to have a standardized and unified policy for closeable (resource)
handling, what we have now which is Job-only auto-closing is definitely broken. in general I don't want any ad-hoc
hacks anywhere, 100% of everything must be a well thought out and deliberately designed general and simple
application-wide mechanism".

## 2. Requirements, in the user's words

- **R1. The point of a Resource is safe disposal, and it is separate from passing values around.** "disposal of
  resources has absolutely nothing to do with context passing -- they must work together but are orthogonal
  features. the point of a Resource is safe disposal, and one of the things that can be passed around is a
  resource, but a resource can be created/used/disposed or whatever without every coming in contact with the
  Context system" (2026-07-31 13:14).
- **R2. The user controls a resource's scope.** "obviously the user should have control about the scope of a
  resource" (2026-07-29 15:17). Example: a browser opened by "Open Kzen and Browser" must stay open "for the
  duration of the test -- which starts one level above" (2026-07-03 19:14). Also a top-level browser and a
  separate one per sub-script (logic-spec §6).
- **R3. Closing is idempotent.** "it's a requirement for resources that disposal (calling close) should be
  idempotent" (2026-07-31 14:55).
- **R4. Automatic cleanup works across steps.** Open a browser configured to close at end of scope, pass it on,
  use it in a later step, "and then the script ends and the browser closes (automatic cleanup, no
  BrowserCloseStep)" (2026-07-31 14:29).
- **R5. Resource use is visible without running.** "does this design allow us to identify all resource usage and
  how they are interconnected? ... show overlay resource flow information overtop of the document dependency DAG
  ... without running the Logic?" (2026-07-31 15:03).
- **R6. Streams and individual data items can be closeable, and their lifetime is tracked.** "if the stream is
  Iterable or Iterator, it also needs to support AutoCloseable. and even individual data items will need to
  support AutoCloseable -- that's how the global memory limit is enforced at the host" (2026-09-04 12:13); "if
  there is a closeable item, we need to track its lifetime" (2026-09-04 13:21).
- **R7. A result is handed over live, never copied.** "isn't the run still active when the caller of the Job
  receives the output of the Job? ... there's no physical way to safely copy an arbitrary object graph (which can
  have native resource handles backing it)" (2026-10-14).
- **R8. One policy for every document type.** Script, Flow, Job and any Logic follow the same rules (2026-10-14).
- **R9. One or many projects per JVM.** "we need to support running one Kzen project per process, or multiple
  Kzen projects in one JVM process" (2026-10-14), so no process-wide registries.
- **R10. No invented limits, no unrequested modes** (standing principles).

## 3. What exists today

### 3.1 Engine scoped disposal (kzen-lib) — designed with the user, 2026-06 to 2026-08

Specified in `kzen-lib/docs/logic-spec.md` §6. One registry with three entry points, all routed to the same engine
operation (`kzen-lib-jvm/.../exec/engine/RunEngine.kt:1831-1843`):

- `Execution.bind(key, value, disposal)`: a named binding with a teardown (a "managed binding");
- `Execution.resource(key, policy, value, closer)`: the raw-string form of the same thing;
- `Execution.onSettle(policy, closer)`: an anonymous teardown for the current frame.

Its rules:
- Policies `auto` / `manual` / `keepOnFailure` (`ResourceClosePolicy.kt`), with a settlement table.
- Disposal happens at most once, enforced by the engine.
- Ownership climbs the documents that declare `context.exports` for the key, and rests on the first that does not.
- Registrations survive live edits.

Users:
- Script steps: `BrowserOpenStep.kt:58` (`bindContext` with a close policy), `ScriptRunContext.kt:294`
  (`openResource`), `:264` (`disposeAtSettle`).
- The Job's own plumbing: `JobRun.kt:172` (`onSettle`), `JobWorkPool`.

Observations:
- A resource's name, scope and owner are expressed through the context system (`context.exports`, keys). This is
  where R1's "orthogonal" may not hold; it needs checking against R1.
- It is frame-scoped. It has no notion of a value that several concurrent consumers hold and that should close
  when the last one is done.

### 3.2 Job value ledger (kzen-auto) — built 2026-09 for in-process hosting (plans `in-process-hosting/15-18`)

- `RunOwnershipLedger` adopts any `AutoCloseable` value:
  - when a source pulls it (`SourceIngress.kt:60-95`);
  - when it is sent through a channel (`hold`).

  Each holder takes a lease, and the value closes when the last lease is released. Anything left closes at run
  end, before the result is returned (§1.1).
- `NativeIdentityRegistry.global`: process-wide, one run per object ever, and an error on reads after close (§1.3).
- `Borrowed`: a marker a host wraps around objects it manages itself, so the run never closes them.
- Result boundary: `ResultSinkWorker` snapshots owned elements, and `EngineJobControl.yieldResult` refuses an owned
  value.
- `JobOwnershipReport`: names the holders when the run stalls.
- Related lifetime mechanism: pooled `Recyclable` values (Format → Write buffers), forfeited at the snapshot.

None of this uses the engine registry, and none of it applies outside a Job.

## 4. What is wrong, as gaps against the requirements

| Gap | Requirement |
|---|---|
| Two mechanisms with different scopes (frame vs. value) and different rules | R8 |
| A Job closes owned values before its caller receives the result; the copy workaround cannot work | R7 |
| Closeable values returned by Script/Flow/Logic steps are not tracked | R4, R6, R8 |
| Resource scope and identity ride the context system | R1 (to check) |
| Process-wide registry of objects | R9 |
| Snapshot caps; 2 s stall timer | R10 |
| Nothing shows resource flow before running | R5 |

## 5. Questions the design must answer

1. **What is a resource?** Is it any `AutoCloseable` value, wherever it appears (a step's value, a stream, an item,
   a Result)? Or only something registered explicitly? A host object the host manages itself (`Borrowed` today)
   must not be closed by kzen. How is that expressed?
2. **Who owns it and when does it close?** One rule must cover:
   - a browser that lives for a test one level up (R2);
   - a per-item batch that closes when its last consumer is done (R6).

   Are these the same rule (ownership by scope, with values handed between owners), or two policies of one
   mechanism?
3. **How does ownership cross a boundary?** Step → step, Worker → Worker, Job → caller (R7), and document →
   document. At each one, is the hand-over a transfer (the receiver now owns it) or a loan (the giver still owns it)?
4. **How does the user set the scope (R2), and what is the default?** Today the scope is declared through
   `context.exports`. Should resource scope have its own declaration (R1)?
5. **What must be visible before running (R5),** and what during a run (who holds what, why it hasn't closed)?
6. **What does the engine guarantee?** At-most-once close (R3) is there today. What else: close order (child before
   parent), close after a failure, close on cancel, behaviour on a live edit?
7. **What is deleted?** The candidates:
   - the Job ledger as a separate mechanism;
   - `NativeIdentityRegistry`;
   - the Result snapshot and `SnapshotPolicy`'s role at that boundary;
   - the stall timer;
   - whichever engine entry points the design makes redundant.

## 6. Out of scope here

- The design itself. It follows once this definition is agreed.
- `Recyclable` buffer pooling, unless the design decides it is the same concept.
- Report (legacy code).
- kzen-sample changes, beyond what a removed API forces.
