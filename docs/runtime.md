# Runtime ownership

zi runs on explicit ownership rules.

## Threads

Two long-lived threads matter:
- **TUI** — owns widgets, overlays, editor state, transcript rendering
- **agent** — owns agent state, session state, Lua, extensions, tool orchestration

Short-lived helper threads may exist, but they publish through the same channels instead of mutating foreign state directly.

## Two channels, no third

Cross-thread communication uses only:
- **request queue**: TUI -> agent for mutations, work, and I/O
- **event queue**: agent/helper -> TUI for published results and UI events

If the TUI needs the agent to do something, enqueue a request.
If the TUI only needs to read data to render or filter, consume a published snapshot.

## Snapshot vs request

Use a **snapshot** when the TUI needs local reads at render speed.
Use a **request** when the agent must mutate state, run code, or touch I/O.

Never turn per-keystroke UI behavior into RPC into Lua or agent internals.

## Ownership table

| Resource family | Owner |
|---|---|
| Lua state, extension runner, registries | agent |
| session store and agent state | agent |
| transcript widgets, overlays, editor, components | TUI |
| cross-thread queue storage and payloads | `msg_allocator` |
| published snapshots | produced by agent, consumed by TUI |

## Allocator rule

Anything that crosses threads must be fully owned for that crossing.

That includes:
- queue payloads
- queue backing storage
- strings and slices carried in events or requests

Half-migrations recreate races.

## Lifetime rule

Transient data belongs to the flow that defines its lifetime.
Components borrow it.
Thread boundaries deep-copy it.
Only stable immutable catalogs should be borrowed long-term.

## Anti-patterns

Avoid:
- direct TUI mutation of agent state
- calling Lua from the TUI thread
- borrowed slices crossing queues
- adding mutexes to compensate for unclear ownership
- making rendering depend on synchronous calls into agent-owned state

## Practical test

When adding a feature, ask two questions:
1. who owns this resource for its whole lifetime?
2. is this a snapshot read or a mutation request?

If those answers are unclear, the design is not done.
