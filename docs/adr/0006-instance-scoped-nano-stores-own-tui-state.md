# Instance-scoped Nano Stores own TUI state

> Amended by [ADR 0007](0007-terminal-interactive-mode-over-agent-session.md) and [ADR 0008](0008-composer-owned-picker-stack.md): Nano Stores belong only to the terminal mode, and below-composer choice state has a dedicated stack owner.

Zi uses Nano Stores for mutable terminal application and presentation state. Stores are concrete instances created by one `InteractiveMode`, not module-global singletons.

The terminal client creates:

```ts
createInteractiveStore(session)
createPromptStore(interactive)
createPickerStack()
createTranscriptStore()
```

- `InteractiveStore` owns the current session subscription and generation, rejects stale events, bounds transient tool presentation, and exposes narrow prompt/transcript revision streams.
- `PromptStore` owns feedback, retained images, typed command/model workflows, and cursor-targeted one-shot composer edit requests. It receives typed edits or command intents from the mode-owned `SlashController` and delegates prompt, queue, catalog, and mutation operations through `InteractiveStore` to `AgentSession`.
- `PickerStack` owns nested picker frames, selected rows, suspended parent filters, and top-frame filtering. It receives the active composer filter as an operation argument and owns no input.
- `TranscriptStore` owns follow/detached/unseen terminal navigation.

`AgentSession` remains authoritative for messages, model, thinking level, queues, persistence, provider work, and run lifecycle. TUI stores may retain a session reference for identity but may not mirror durable state.

Writable atoms are private. Components observe readable atoms and request domain-named operations. Mutually exclusive states remain direct discriminated unions in one coherent atom rather than independent boolean atoms.

There are no exported mutable module singletons. A capability with an independently meaningful invariant or lifetime gets a sibling owner rather than fields in a growing root atom. Stores call concrete owners directly; there is no registry, action bus, or generic payload protocol.

Stores use explicit disposal. Nano Stores `onMount()` is reserved for resources whose lifetime genuinely follows observation; delayed listener cleanup may not govern the primary session subscription or native terminal resources.

Imperative components update their owned renderables and release every subscription and native handler in `destroy()`. Textarea contents, cursor/focus, scroll offsets, selection, and renderer lifetime remain OpenTUI-owned.

Pure transitions are tested without a renderer. OpenTUI fixtures verify that stores and native resources follow the same state.
