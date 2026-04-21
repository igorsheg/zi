# extensions

extensions are a product surface.

zi's v2 work starts from one root decision: [extension system v2 is a nuclear cutover](./adr/extensions-v2-cutover.md).

## stance

v2 replaces v1. it is not a compatibility layer.
after cutover, zi exposes one public extension api.

that means:
- no legacy/v2 dual surface
- no direct tui → lua reach-through
- no exporting internal mailbox or snapshot transport as public api
- no preserving broken built-ins or host seams behind shims

the redesign must preserve or expand pi-mono-level extension capability.

## runtime fit

extensions run on the agent-owned lua runtime.
the host owns cross-thread transport, retained ui state, redraw cadence, and other long-lived runtime objects.
the tui renders published state; it does not execute extension code.

## follow-on docs

follow-on v2 contract docs define concrete seams — [runtime roots](./runtime-roots.md), [lifecycle/scheduler](./extensions-lifecycle.md), [events/interceptors](./extensions-events.md), [retained objects](./extensions-retained-objects.md), [tools](./extensions-tools.md), [jobs/subagents](./extensions-jobs-subagents.md), [ui contract](./extensions-ui-contract.md), [state rebinding](./extensions-state-rebinding.md), [providers](./extensions-providers.md), [commands/flags/actions](./extensions-commands-flags-actions.md), the [conformance matrix](./extensions-conformance-matrix.md), and [cutover boundaries](./extensions-cutover-boundaries.md) — while citing the root adr instead of reopening the cutover question.
