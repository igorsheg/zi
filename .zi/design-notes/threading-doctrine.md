# Threading & Allocator Ownership Doctrine

> Epic: **zi-wub** — Threading & allocator ownership refactor (neovim-style)
> Read this before touching any task in the epic. It is prescriptive, not descriptive.

## What this document is

The shared model the next session must operate under while landing `zi-wub`. It encodes:

1. the target architecture and why
2. the invariants each phase must preserve
3. the sequencing rules (what you may NOT do, even if it looks faster)
4. the traps the oracle already flagged

If this document and a bead description disagree, **this document wins**. File a follow-up to reconcile them.

## Why we're doing this

Two crashes in one session exposed that zi's threading model is held together by luck:

1. **lua_newthread on the wrong state.** A host C function running inside coroutine A called `Coroutine.init(parent_main_L)` to spawn a helper coroutine for the render hook. `lua_newthread` mutated main L's stack while A was the current thread — next `lua_resume` walked corrupted memory and died in `luaH_getshortstr`. Band-aided with `Coroutine.initFrom(parent, from_L)` that takes the currently-executing L explicitly.

2. **ArenaAllocator raced across threads.** `main.zig` handed one `ArenaAllocator` to both the agent thread and the TUI thread. Agent thread cloned partial results into the event queue while TUI thread cloned them again into the transcript — concurrent allocs corrupted arena state, later alloc returned a misaligned pointer, `allocBytesWithAlignment` panicked. Band-aided with `std.heap.ThreadSafeAllocator` wrapping the arena.

Both band-aids work. Neither addresses the underlying issue: **zi has no single-owner model for the resources that matter.** Every feature we add (extensions, sub-agent spawn, slash commands, render hooks) multiplies the unclear cases. This epic removes the ambiguity once.

## The target model

```
  ┌──────────────────────────────────────────────────────────┐
  │              ROOT GPA (thread-safe by design)            │
  └──────────────────────────────────────────────────────────┘
        │                   │                   │
        ▼                   ▼                   ▼
  ┌──────────┐        ┌───────────┐       ┌──────────────┐
  │ TUI arena│        │AGENT arena│       │ msg_allocator│
  │ TUI thr  │        │ agent thr │       │ (GPA direct, │
  │  only    │        │   only    │       │  thread-safe)│
  └────┬─────┘        └─────┬─────┘       └──────┬───────┘
       │                    │                    │
       ▼                    ▼                    ▼
  widgets, layout,    lua_State,            UiEvent,
  transcript state,   session_store,        AgentRequest,
  component scratch,  ca.agent.state,       EventQueue/
  render of           all tool exec,        RequestQueue
  published           extension runner,     BACKING STORAGE
  snapshots           spawn child procs     + payloads
```

**One rule, applied to every resource: exactly one owning thread for its entire lifetime.** No "usually X, sometimes Y with a mutex." Ownership is a design choice, not a runtime check.

### Owner assignments (frozen)

| Resource | Owner thread | Notes |
|---|---|---|
| `lua_State` | agent | first-touch claim → explicit bind (phase 2) |
| `ExtensionRunner` | agent | co-owned with lua_State |
| `session_store` | agent | `/resume` requests enqueue, agent loads |
| `ca.agent.state` (model, messages) | agent | `/model` requests enqueue |
| `tools`, `render_registry`, ext registries | agent | writes are agent-only; TUI reads snapshots |
| `transcript` | TUI | receives events, does NOT call back into agent |
| components, overlays, editor | TUI | render reads snapshots only |
| `pending_renders` map | cross-thread via `pending_renders_mutex` | producer: agent; consumer: TUI (snapshot handoff, bounded critical section) |
| `EventQueue` (agent → TUI) | storage: `msg_allocator`; push: agent; consume: TUI | already works, needs allocator fix (phase 3) |
| `AgentRequest` queue (TUI → agent) | storage: `msg_allocator`; push: TUI; consume: agent | new in phase 4 |

### Cross-thread communication (the only two channels)

```
   TUI thread                             agent thread
   ──────────                             ────────────

   enqueue AgentRequest  ─────────────▶   drain RequestQueue
   (/resume, /model,                      run the mutation
    run_slash_command,                    publish result via
    login_*)                              EventQueue

   drain EventQueue      ◀─────────────   push UiEvent
   apply to widgets                       (from agent loop callback,
   repaint                                 from ext runner, from
                                            login thread via its
                                            own push path)
```

That's it. No third channel. No shortcut for "this is fast, let's just do it directly." The moment you write `self.ca.agent.state.model = ...` from the TUI thread, you've broken the doctrine.

## Render paint stays push-snapshot

**Important correction to the original plan.** The oracle caught this: transcript paint is **already** push-based via `pending_renders`. The agent thread precomputes a `LuaRenderState`, stashes it through `runner.stashPendingRender(id, ...)`, and the TUI drains via `runner.takePendingRender(id)` during paint. No lua is called from the TUI thread during render.

This pattern is correct. **Do not** replace it with a synchronous TUI→agent render RPC. Do not add a `render_tool` variant to `AgentRequest`. Phase 4 task `zi-wub.18` is an **audit** task — verify no paint-path code violates this, then move on.

The same shape applies to any future hot-path UI data:

```
   agent thread                 TUI thread
   ────────────                 ──────────

   compute immutable     ──▶    read latest snapshot
   snapshot                     render without
   publish via mutex-            reentering agent
   protected pointer
   swap
```

The command-catalog snapshot (zi-wub.19) is the other example: when extensions start registering slash commands, the agent thread publishes a frozen `CommandSnapshot` and the TUI runs fuzzy filter against it locally. **Never** per-keystroke RPC into lua.

Rules of thumb for "is this a snapshot or a request?":

- **Snapshot**: TUI needs to read data to render/filter. Frequent reads, occasional writes. Pointer-swap with a mutex is fine; seqlock/RCU are over-engineering unless you measure contention.
- **Request**: TUI needs agent to DO something (mutate state, run code, perform I/O). Always a queue entry, never a direct call.

## Sequencing rules (MUST)

The phases are ordered for a reason. Violating the order will either break the build, pin the wrong owner, or mask bugs.

### R1. Audit before hardening

Phase 1 (audit + soft tracing) must complete before phase 2 (hard assert). The current `assertOnLuaThread` uses **first-touch cmpxchg** to claim ownership — if you flip it to panic before every violator is fixed, the first TUI-thread lua call will claim TUI as owner and the real agent thread will panic later. You'll spend an hour chasing your tail.

Correct order:
1. catalog every lua touch site (`zi-wub.1`)
2. add soft tracing that logs (never panics) when a second thread shows up (`zi-wub.3`)
3. run a typical session, collect violations
4. fix the violations by routing through `AgentRequest` or pending_renders
5. only then add `bindLuaOwnerThread` and flip the assert (`zi-wub.5`, `.6`, `.7`)

### R2. msg_allocator before everything else in phase 3

`zi-wub.8` (introduce msg_allocator) is the foundation for:
- `zi-wub.9` (EventQueue backing storage)
- `zi-wub.10` (convertAgentEvent clones)
- `zi-wub.14` (AgentRequest queue storage)
- `zi-wub.17` (login callbacks via event_queue)

Do not start the dependent tasks before `.8` lands. The dependency edges in beads enforce this.

### R3. Queue STORAGE, not just payloads

When migrating a queue to `msg_allocator`, you MUST migrate:

- the `ArrayListUnmanaged.items` backing storage (it reallocates on `append`)
- any key tables or scratch structures the queue holds internally
- the payloads the queue carries
- the free path the consumer uses

If any of these still touches the shared arena, you still have the race. Oracle found this specifically in `EventQueue.push` at `interactive.zig:63-105`.

### R4. Do not remove the ThreadSafeAllocator band-aid until phase 3 is fully landed

`zi-wub.13` depends on `.9, .10, .11, .12` for a reason. Remove the wrapper only after every cross-thread allocation has moved to `msg_allocator` and every per-thread alloc has moved to its own arena. Premature removal reintroduces the original crash.

### R5. Agent event loop (phase 4 as originally written) is NOT in this epic

Folding `zi.spawn` child stdio into an agent event loop, killing the anthropic watchdog thread, and so on — these are filed as `zi-gqw` (epic) + `zi-gqn` + `zi-rgw` and are **deferred**. The agent currently has no explicit event loop at all (see `src/agent/loop.zig:91-217`), it's a straight-line `stream → tools → repeat` function. Introducing a real poll/kqueue multiplexer is a separate project with its own blast radius.

**Do not** pull the event-loop work into `zi-wub`, even if it looks adjacent. That epic gets its own session.

## What the oracle pushed back on (and the corrections)

The original 5-step plan had several mistakes. Summarizing so the next session doesn't re-invent them:

| Original claim | Reality | Correction |
|---|---|---|
| "Route TUI→lua calls through a request queue, including render" | Render is already push-snapshot via pending_renders | Queue is for state-mutating requests only |
| "Step 4: fold spawn into agent event loop" | There is no agent event loop to fold into | Separate epic, deferred |
| "Step 5: delete the lua mutex" | There is no lua mutex — only stale comments | Reframed as "delete stale comments/docs" (zi-wub.20) |
| "Harden assertOnLuaThread early" | First-touch claim will pin wrong owner | Audit first, bind explicitly, then panic (R1) |
| "Payloads via GPA" | Queue backing storage also needs it | R3 above |
| "agent owns lua and allocators, tui owns widgets — done" | `/resume`, `/model`, login callbacks all violate this | In scope, phase 4 (.15, .16, .17) |

## Traps to avoid

### Trap 1: "I'll just fix the crash locally"
Every time you add a mutex, an atomic, or a `ThreadSafeAllocator` wrap, ask: **am I encoding ownership, or defending against its absence?** The former is fine. The latter is a band-aid and belongs on a follow-up ticket, not in a phase task.

### Trap 2: "This path is single-threaded, I don't need the ceremony"
Maybe today. Not tomorrow. The extension system will let users register tools that touch every resource zi has. If the convention is "sometimes we go through the queue, sometimes we don't," extension authors will guess wrong. Pick the queue.

### Trap 3: "Let me refactor the agent loop while I'm here"
Don't. The agent loop is `zi-gqw`'s job. Touching it from inside `zi-wub` will balloon the blast radius and you'll have a 2000-line diff nobody can review. If a phase task wants to change agent loop semantics, stop and file a bead.

### Trap 4: "The TUI needs this data *right now*"
No it doesn't. It needs *a value*. Use the last published snapshot. If that snapshot is stale, publish a new one from the agent thread. The TUI is a render loop, not a query engine.

### Trap 5: "I can skip the audit, I know where the lua calls are"
You don't. The oracle found `login_thread` callbacks mutating `status_text` and `tui.dirty` from a third thread that nobody was tracking. Write the audit doc. It takes 30 minutes and it's the difference between a clean refactor and whack-a-mole.

## Verification at each phase

| Phase | Verification |
|---|---|
| 1 | audit docs exist under `.zi/design-notes/`; soft tracing emits log warnings in a session that exercises the Task tool |
| 2 | `bindLuaOwnerThread` called before first lua API call; `assertOnLuaThread` panics in Debug if called from non-agent thread; full Task tool run is clean |
| 3 | `zig build` clean; Task tool run with multi-step subtask + follow-up prompt doesn't crash; `main.zig` no longer wraps arena in `ThreadSafeAllocator` |
| 4 | `/resume`, `/model`, login progress all flow through queues; grep for direct mutations from TUI to agent state finds none |
| 5 | grep for "lua mutex" returns nothing (outside this doctrine); AGENTS.md contains the new invariants |
| Epic | `zi-wub.23` acceptance test: Task tool stress run (many partials + follow-up prompt) under Debug + ReleaseSafe, no crash |

## Files you will touch (rough map)

- `src/main.zig` — phases 3, 5 (allocator setup)
- `src/tui/interactive.zig` — phases 2, 3, 4 (owner bind, allocator wiring, request queue, /resume, /model, login)
- `src/tui/transcript.zig` — phase 3 (setPartialResult allocator), phase 4 (snapshot verify)
- `src/extensions/runner.zig` — phase 2 (bindLuaOwnerThread, assert hardening)
- `src/extensions/lua_runtime.zig` — no changes expected (initFrom already landed)
- `src/extensions/lua_tool.zig` — no changes expected (current_L threading already landed)
- `src/extensions/api.zig` — phase 1 audit only
- `src/agent/agent.zig`, `src/agent/loop.zig` — phase 4 (receive AgentRequest drain)
- `src/coding_agent.zig` — phase 4 (route /resume, /model through request path)
- `AGENTS.md` — phase 5

## When to consult the oracle

- **Before phase 1 ends**: confirm the audit findings are complete before flipping to hard assert
- **During phase 2**: if you find a lua touch site that doesn't cleanly route through AgentRequest or pending_renders, escalate
- **During phase 3**: before removing the ThreadSafeAllocator band-aid, confirm every cross-thread alloc path has been migrated
- **During phase 4**: if the AgentRequest drain integrates awkwardly with the existing agent loop (it's a straight-line function, not a dispatch loop), escalate — you may be stepping into `zi-gqw` territory and should stop

## Closing

This epic is a finite, bounded refactor. It's big but it's bounded. If the scope starts to drift toward "while I'm here, let me also…", file a new bead and stay in the lane. The whole point is to stop playing whack-a-mole — that includes resisting the temptation to whack a fifth mole while you're fixing the first four.
