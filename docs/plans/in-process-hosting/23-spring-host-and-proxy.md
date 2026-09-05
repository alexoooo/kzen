# HS23 — Spring host workspaces, lifecycle and streaming proxy

> Status: not started. One implementation session. Prerequisites: HS02 host gates, HS10, HS18 and HS22.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.3 and §9 G1–G7.

## Outcome and anchors

New sibling kzen-sample-embed-spring; umbrella settings.gradle.kts; sample host build/config/lifecycle/proxy.

## Work

1. Scaffold the Java 25 plain-jar Maven host using HS02's verified dependency/packaging choices. Add it as an umbrella include like the Maven sample; create an AGENTS.md with reproducible build/run/verification commands.
2. Initialize one KzenAutoRuntime, then configured workspaces with distinct module/work roots and per-context CIO loopback servers. Wire startup rollback across already created workspaces if a later one fails.
3. Implement the Spring MVC proxy at /kzen/{workspace}/** and a small workspace/portlet page. Preserve request bodies, query/path semantics, status, redirects, compression and streaming using the established header rules.
4. Use SmartLifecycle to stop/await each server, close/join its context, then release its claim. Do not close the process-global extension universe or install kzen's process-exit/headless behavior.
5. Let Spring own logging/backend configuration; suppress misleading managed log storage. Resolve any HS02 resource/logging defects necessary for the library use, with standalone logging behavior verified.

## Verification and exit criteria

From the packaged plain jars on JDK 25, open two prefixed UIs, request assets, run a fixture Job, stream SSE incrementally, cancel a request and verify proxy resources close. Test failure during second-workspace construction and server binding; every previously acquired context/root must be released safely. Stop one workspace while the other remains usable.

## Handoff

Record exact packaging, host config, ports, paths and shutdown proof. No real memory-governed host services are claimed until HS24.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
