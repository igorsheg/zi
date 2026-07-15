# Architecture

## Fixed references

| Source                      | Role                                                     |
| --------------------------- | -------------------------------------------------------- |
| `pi-ai` and `pi-agent-core` | Runtime dependencies                                     |
| `pi-coding-agent`           | Coding-agent architecture and product-behavior reference |
| Pi interactive mode         | Terminal interaction behavior and ownership reference    |
| `@opentui/core`             | Terminal implementation                                  |
| OpenCode                    | Proven OpenTUI patterns worth evaluating                 |

OpenZi recreates `pi-coding-agent`; it does not depend on it. Parity includes `AgentSession`, session/services construction, settings, model and resource owners, tools, extensions, and interactive/print/RPC modes—not only visible features.

Pi's `interactive-mode.ts` directly imports `pi-tui`, constructs terminal components, and delegates coding-agent policy to `AgentSession`. Print and RPC modes operate independently over the session/runtime boundary. OpenZi follows that separation: `AgentSession` is reusable core policy; interactive mode is a terminal application.

## Workspaces

```text
packages/
  coding-agent/   AgentSession, managers, tools, shared policy, non-terminal modes
  tui/            terminal-specific interactive mode and imperative OpenTUI
  cli/            runtime construction, argument parsing, mode selection
```

Dependencies point inward:

```text
cli -> tui -> coding-agent
cli -> coding-agent
```

- `coding-agent` never imports a frontend.
- `tui` consumes coding-agent public APIs and owns terminal behavior and native interaction state.
- `cli` dynamically loads the selected mode and reports its result.
- Future web clients consume `AgentSession`, concrete managers, or RPC; they do not inherit terminal interaction state.
- There is no `shared`, `common`, universal mode facade, generic UI model, or event bus.
- A new package requires an independently meaningful lifecycle or public use case.

## State and transition architecture

Stateful behavior follows [ADR 0004](adr/0004-explicit-state-and-transitions.md): one owner holds concrete data and resources, admits operations from the current state, and applies explicit transitions. The same discipline applies inside an `AgentSession`, TUI store, imperative component, tool invocation, or process lifecycle.

Mutually exclusive modes use direct discriminated unions with domain fields:

```ts
type PickerState =
  { type: "closed" } | { type: "model"; query: string } | { type: "thinking-level"; selected: ThinkingLevel }
```

Do not replace this with coordinated flags, generic payload envelopes, or optional fields that permit impossible combinations. Closed unions are handled exhaustively. Persisted, provider, process, and other open input is validated before an owner transitions on it.

The owner also owns temporal correctness. It records admission before starting an effect, bounds the effect, and applies completion only to the operation that started it. Cancellation, settlement, queue limits, stale results, and resource cleanup are modeled and tested with their owner.

## Coding-agent architecture

```text
createAgentSession(services, session options)
  -> AgentSession
      -> pi-agent-core Agent
      -> SessionManager
      -> SettingsManager
      -> ModelRegistry
      -> ResourceLoader
      -> tool definitions
      -> later: compaction, retry, extensions
```

### `AgentSession`

`AgentSession` is the policy spine shared by application modes. It owns:

- one Pi `Agent`;
- persistence of completed messages;
- model and thinking-level changes;
- steering and follow-up queues;
- active-run admission, cancellation, and settlement;
- later, retry, compaction, branch, bash, and extension policy.

It exposes Pi agent events plus session-level events. Application modes subscribe; they do not control the provider loop or persist messages themselves.

### Managers and services

- `SessionManager` owns one append-only JSONL session tree and its leaf.
- `SettingsManager` owns resolved settings and eventually global/project layering.
- `ModelRegistry` wraps `pi-ai` model discovery and authentication.
- `ResourceLoader` owns context files, prompts, skills, and later extensions/themes.
- `createAgentSession` wires these owners to a Pi `Agent`.

These are concrete owners, not speculative dependency-injection interfaces.

### Tools

Tools belong in `coding-agent`. Each invocation owns cancellation, timeout, output limits, and cleanup. Initial parity order is `read`, `bash`, `edit`, `write`, then `grep`, `find`, and `ls`.

## Application modes

Modes are adapters over `AgentSession`, not one universal abstraction.

- Terminal `InteractiveMode` lives in `packages/tui` because it owns OpenTUI resources and terminal semantics.
- Future print mode belongs in `packages/coding-agent` and owns one-shot output policy.
- Future JSON/RPC mode belongs in `packages/coding-agent` and owns its protocol.

If terminal and web clients later duplicate concrete command or session-flow policy, that policy moves into `AgentSession` or a dedicated coding-agent owner. OpenZi does not anticipate that reuse with a forwarding facade.

## Imperative terminal mode

```text
AgentSession
  -> InteractiveMode
      -> InteractiveCommands
      -> InteractiveStore
      -> SessionScreen
          -> TranscriptView + TranscriptStore
          -> PromptView + PromptStore
              -> Composer
              -> PickerStack + PickerStackView
                  -> PickerList
```

`InteractiveMode` owns the root renderable subtree, current session binding, session replacement, syntax-style lifetime, prompt-focus preservation, terminal disposal, and `InteractiveCommands`. Coding-agent owners supply command descriptors; `InteractiveCommands` assembles terminal completion and parses built-in invocations into closed intents.

`InteractiveStore` owns the session subscription, generation, bounded transient tools, submissions, queue restoration, and abort delegation. `PromptStore` owns terminal feedback, retained images, typed command/model workflows, and one-shot composer edit requests. `PickerStack` owns nested frames, selection, suspended parent filters, and filtering of only the active frame. `PickerStackView` renders that frame below the always-mounted composer and owns no input. `TranscriptStore` owns follow/detached/unseen navigation. Durable messages, model, queues, persistence, and activity remain direct `AgentSession` reads.

Imperative components subscribe to readable Nano Stores and update only their owned renderables. Durable transcript message renderables are appended rather than rebuilt, preserving native selection and detached scrolling. The composer textarea is the sole prompt/filter input and remains focused while picker frames change. Textarea contents, cursor, focus, viewport, and selection remain OpenTUI-owned.

## Resource shutdown

1. the terminal mode stops accepting input and disposes subscriptions/renderables;
2. `runTui` aborts and awaits the `AgentSession` with a deadline;
3. `runTui` clears the title and destroys OpenTUI;
4. the CLI disposes the `AgentSession` it created.

Each step is idempotent and bounded where it waits.

## Code shape

The codebase optimizes for legibility and local reasoning:

- concrete modules before frameworks;
- narrow public exports;
- one owner for each mutable state family;
- direct calls before buses, adapters, or generic protocols;
- explicit domain states instead of flag combinations;
- exhaustive closed unions;
- validation at external, persisted, provider, and process boundaries;
- comments only for invariants, trade-offs, and provenance;
- no speculative extension points;
- no package or file split justified only by line count.

“Scalable” means a future capability has an obvious owner and path, not that every operation passes through another abstraction.
