# zi beta explicit systems baseline

## System rule

Complexity compounds. Simple is good. Complex is evil.

This branch removes the accidental-complexity owners first. New behavior must be rebuilt only after ownership, event movement, bounds, time, shutdown, and seam contracts are explicit.

## Removed owners

- `src/coding_agent/`
- `src/tui/`

These directories mixed policy, transport, UI, extension execution, session control, auth, resources, and tool authority. Their dynamic behavior was larger than their static structure could explain.

## Retained owners

- `src/agent/` owns agent conversation/runtime state and agent event policy.
- `src/ai/` owns provider/model request and response shapes.
- `src/session/` owns persisted session artifacts.
- `src/runtime/` owns process-level runtime primitives.
- `src/diff/`, `src/image/`, `src/json/`, `src/lib/`, `src/search/` remain supporting mechanisms.

## Mandatory constraints for rebuild

- One mutable state owner per subsystem.
- Cross-owner communication uses data events, not broad owner pointers.
- Every queue has capacity, overflow behavior, and close behavior.
- Time advances only in named owner loops or schedulers.
- Background completion returns to an owner-owned drain site.
- Terminal/UI writes have one side-effect authority.
- Tool execution authority is narrow and explicit.
- Shutdown order is part of every subsystem contract.
- Contracts fail at compile time or construction time where possible.

## First stabilization target

Solidify `agent`, `ai`, and `session` before reintroducing CLI, TUI, extensions, auth, resources, or tools.

The first useful artifact is not a UI. It is a small core that can prove:

```text
input event -> agent owner -> ai request -> ai completion event -> session append
```

with explicit ownership, bounded work, and deterministic shutdown.