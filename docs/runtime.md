# Runtime ownership

zi runs on explicit ownership rules.

## Threads

Two long-lived threads matter:
- **TUI** — owns widgets, overlays, editor state, transcript rendering
- **agent** — owns agent state, session state, Lua, extensions, tool orchestration

Short-lived helper threads may exist, but they publish through the same channels instead of mutating foreign state directly.

## Two channels, no third

Cross-thread communication uses only two mailbox-backed channels:
- **request queue**: TUI -> agent for mutations, work, and I/O
- **event queue**: agent/helper -> TUI for published results and UI events

The one deliberate non-mailbox primitive is **run-scoped cancellation**:
- the owner creates an `AbortSignal` for one in-flight run
- foreign threads may latch abort through that dedicated controller
- downstream provider/tool/helper code observes the signal cooperatively

This is not a third general-purpose queue. It exists because abort must be observable while a run is already blocked inside provider I/O or tool execution, where waiting for the next request-drain boundary would be too late.

If the TUI needs the agent to do something, enqueue a request.
If the TUI only needs to read data to render or filter, consume a published snapshot.

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
2. is this a snapshot read or a mutation request?
3. if it is a snapshot, is it authoritative semantic state, and which consumer reconstructs local view state from it?

If those answers are unclear, the design is not done.
