# runtime ownership

zi runs on explicit ownership rules.

## threads

- **agent thread** — owns lua, extension registries, session state, and extension execution
- **tui thread** — owns presentation and local ui state

## boundaries

- **request queue** — tui → agent mutation and work
- **run controls** — `abort` plus queued steering/follow-up while a run is active
- **published snapshots** — agent-owned semantic state for render-speed reads

mailboxes are owner boundaries, not product APIs.
if the tui needs work, enqueue a request.
if it needs to render, consume a snapshot.
if an extension needs ui or long-lived state, it goes through host-owned primitives, not direct tui → lua reach-through.

## ownership rule

anything that crosses threads must be fully owned for that crossing.
borrowed slices and live lua objects do not cross mailboxes.

## why this matters for extensions

extension v2 must fit this mailbox/snapshot model. see [conversation state](./conversation-state.md), [agent events and transport boundaries](./agent-events-and-transport-boundaries.md), [extensions](./extensions.md), [extensions lifecycle](./extensions-lifecycle.md), [extension events](./extensions-events.md), [retained objects](./extensions-retained-objects.md), [tools](./extensions-tools.md), [jobs/subagents](./extensions-jobs-subagents.md), [ui contract](./extensions-ui-contract.md), [state rebinding](./extensions-state-rebinding.md), [providers](./extensions-providers.md), [commands/flags/actions](./extensions-commands-flags-actions.md), the [conformance matrix](./extensions-conformance-matrix.md), the [cutover boundaries](./extensions-cutover-boundaries.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).
