# architecture

zi has two long-lived owners:

- **agent** — owns agent state, session state, tool orchestration, lua, and extension registries
- **tui** — owns widgets, editor state, focus, overlays, rendering, and other local presentation state

## cross-owner rule

the tui renders published semantic state. it does not reach into agent-owned internals or call lua directly.

across that boundary:
- mutation and work go through owner mailboxes
- run-scoped controls stay narrow (`abort` plus queued steering/follow-up)
- render-speed reads use authoritative snapshots

this is the runtime shape extension v2 must fit. see [runtime](./runtime.md), [conversation state](./conversation-state.md), [agent events and transport boundaries](./agent-events-and-transport-boundaries.md), [extensions](./extensions.md), the [conformance matrix](./extensions-conformance-matrix.md), the [cutover boundaries](./extensions-cutover-boundaries.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).
