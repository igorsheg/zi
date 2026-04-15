# Runtime ownership

zi runs on explicit ownership rules.

## Threads

Two long-lived threads matter:
- **TUI** — owns widgets, overlays, editor state, transcript rendering
- **agent** — owns agent state, session state, Lua, extensions, tool orchestration

Short-lived helper threads may exist, but they publish through the same channels instead of mutating foreign state directly.

## Two channels, no third

Cross-thread communication uses two long-lived mailbox-backed owner channels:
- **request queue**: TUI -> agent owner inbox for mutations, work, and I/O
- **event queue**: agent/helper -> TUI for published results and UI events

Mailbox wakeups are **coalesced readiness**, not per-message credits. One wake means "this mailbox became readable or terminal"; the consumer drains until empty.

The agent side is a long-lived owner loop: the agent thread blocks on the request inbox wake fd, drains queued work, dispatches it on the owner thread, and shuts down after an ordered terminal request or once a transport-closed inbox has been fully drained.

## Run-scoped control surfaces

Two controls intentionally stay outside the main request inbox because a prompt can already be in flight when they matter:

- **abort** — must become observable even while the owner is blocked in provider I/O or tool execution
- **queued steering / follow-up** — must remain enqueueable and snapshot-visible while a run is active, but only need to be consumed at the loop's steering/follow-up poll points

These are not ad hoc side queues hanging off agent internals.
They are explicit runtime primitives with narrower semantics than the owner inbox:

- **abort** is a dedicated interrupt latch (`AbortSignal`)
- **run control** is a dedicated queued-message boundary for steering/follow-up plus snapshot reads

Why they are separate from the request queue:
- a normal owner request only runs when the owner loop returns to inbox dispatch
- steering/follow-up must be accepted during an in-flight run, before that dispatch boundary returns
- unlike abort, they do not justify arbitrary concurrent mutation — only run-scoped queued user messages and their snapshots

If the TUI needs the agent to do something outside those narrow run controls, enqueue a request.
If the TUI only needs to read data to render or filter, consume a published snapshot.

For shutdown semantics, distinguish two planes:
- **ordered termination** — an explicit terminal request that runs in FIFO order with earlier work
- **transport close** — stop future sends and wake an idle consumer; already-queued work may still drain

## Snapshot vs request

Use a **snapshot** when the TUI needs local reads at render speed.
Use a **request** when the agent must mutate state, run code, or touch I/O.

Never turn per-keystroke UI behavior into RPC into Lua or agent internals.

## Semantic snapshots, not projections

When a mailbox boundary publishes read-oriented state, prefer an authoritative semantic snapshot over a lossy transport projection tailored to one consumer.

The producer owns authoritative domain state.
The consumer owns local reconstruction.

In practice:
- publish the semantic fields the producer actually owns
- let the consumer rebuild transcript/editor/render/cache state locally
- avoid pre-rendered rows, chip strings, or other view-specific payloads as the default cross-thread contract

Current zi examples follow this rule:
- status updates cross as a semantic snapshot of model, thinking level, and context numbers; the TUI formats and lays out its own chips
- session resume crosses as an owned message snapshot; the TUI rebuilds transcript items and editor history from it

Why this rule exists:
- semantic snapshots stay aligned with the producer's real contract
- consumer-specific projections drift when new UI-visible semantics appear
- drift creates pressure for shared-state reads, ad hoc parallel payloads, or "just this one" ownership exceptions

## Short-lived helper threads

Helpers are allowed, but they do not get their own ownership exception.

Two helper shapes are valid:

- **one-shot publisher** — a helper does blocking work and publishes owned results into an existing mailbox-backed owner channel, usually the event queue. This is the right shape for flows like login or future background discovery where the helper must report progress or completion back to the TUI without mutating TUI state directly.
- **private joined helper** — a helper exists only to support one owner's local operation, such as a watchdog, timeout killer, or stdout/stderr reader. It does not create a product-level message boundary and is joined before the operation returns.

Use a dedicated mailbox or owned loop for a helper only when that helper becomes a real long-lived owner boundary with its own queue policy, shutdown semantics, or observability needs. Do not wrap one-shot helpers in faux actors just for symmetry.

The split stays the same:
- mailbox messages for cross-owner mutation/work
- snapshots for render-speed reads
- one-shot helper publication for temporary background work that reports back through an existing owner channel

## Ownership table

| Resource family | Owner |
|---|---|
| Lua state, extension runner, registries | agent |
| session store and agent state | agent |
| transcript widgets, overlays, editor, components | TUI |
| cross-thread queue storage and payloads | `msg_allocator` |
| published snapshots | produced by agent as semantic state, consumed by TUI for local reconstruction |

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
- treating one consumer's temporary render model as the default cross-thread payload

## Practical test

When adding a feature, ask three questions:
1. who owns this resource for its whole lifetime?
2. is this normal owner work (request), a run-scoped control, or a snapshot read?
3. if it is a snapshot, is it authoritative semantic state, and which consumer reconstructs local view state from it?

If those answers are unclear, the design is not done.
