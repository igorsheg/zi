# Terminal interactive mode over AgentSession

Zi uses `@opentui/core` directly. `@opentui/react`, React, JSX, and `@nanostores/react` are not runtime or development dependencies.

Pi's architecture separates the reusable coding-agent session from environment-specific modes:

```text
AgentSession
  <- terminal InteractiveMode
  <- PrintMode
  <- RpcMode
```

Pi's `interactive-mode.ts` is intentionally terminal-specific: it imports `pi-tui`, constructs its editor and TUI, and directly uses terminal components. Print and RPC modes do not consume a frontend-neutral interactive facade; they operate on the session/runtime boundary.

Zi follows that ownership model while keeping the terminal mode in its dedicated frontend package:

```text
packages/coding-agent
  AgentSession, managers, tools, shared policy, future print/RPC modes
       ^
       |
packages/tui
  terminal InteractiveMode, Nano Stores, imperative OpenTUI components
       ^
       |
packages/cli
  runtime construction and mode selection
```

`AgentSession` is the shared client-independent API. `packages/tui/src/interactive/interactive-mode.ts` is the terminal application owner. It owns the current session binding, session replacement, renderer composition, prompt semantics, terminal commands/selectors, focus, and disposal. Its instance-scoped Nano Stores retain only terminal state; durable messages, model, queues, persistence, and provider work remain authoritative in `AgentSession`.

A future web client should consume `AgentSession`, a concrete shared manager, or RPC rather than reuse terminal interaction state. Shared command or session-flow policy is extracted only when a second real client proves that policy is duplicated.

Dependencies point from the terminal toward the coding-agent core:

```text
cli -> tui -> coding-agent
cli -> coding-agent
```

The CLI dynamically loads the selected mode so future print and JSON modes do not initialize OpenTUI.

This ADR supersedes ADR 0002's React choice and amends ADRs 0003, 0005, and 0006. Their explicit-state, instance-scope, no-mirroring, and owner-lifetime decisions remain in force.
