# HS20 — Design-time object-graph path picker

> Status: not started. One implementation session. Prerequisites: HS19.
> Read [the arc rules](README.md) before execution. Design authority: Extensibility plan E8 picker and E7 recursive shape.

## Outcome and anchors

kzen-auto-js generic attribute editors, upstream contract traversal, path Worker notation.

## Work

1. Add the declarative path editor over the upstream contract. Offer scalar leaves, list/map unnesting and aliases through the established generic editor contribution mechanism.
2. Render recursive references collapsed and expand only on demand; do not execute the source or call getters to populate the picker.
3. Show output names and validation errors from the authoritative runtime binding rules. Preserve saved path entries on editing/reopen and handle an upstream shape change with a named invalid path.
4. Use ordinary plugin object contracts, with no plugin-provided JavaScript and no ITCH-specific picker code.

## Verification and exit criteria

Compile JVM/JS and browser-test a recursive fixture contract: expand an order/execution back-reference, select paths, rename an output, save/reopen, encounter a duplicate name and an upstream invalidation. Verify the editor's offered leaves match the runtime contract and the Job executes the chosen paths.

## Handoff

E8 closes after runtime/UI checks pass. Publish/rebuild the frontend resources needed by standalone and embedded sample verification.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Not executed.
