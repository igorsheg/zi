# Architecture

## Fixed references

| Source                      | Role                                                     |
| --------------------------- | -------------------------------------------------------- |
| `pi-ai` and `pi-agent-core` | Runtime dependencies                                     |
| `pi-coding-agent`           | Coding-agent architecture and product-behavior reference |
| Pi interactive mode         | TUI behavior reference                                   |
| OpenTUI React               | Frontend architecture and terminal implementation        |
| OpenCode                    | Proven OpenTUI application patterns worth evaluating     |
| Zi                          | Visual styling reference                                 |

OpenZi recreates `pi-coding-agent`; it does not depend on it. Parity includes the recognizable upper-layer architecture—`AgentSession`, session/services construction, settings, model and resource owners, tools, extensions, and interactive/print/RPC modes—not only a checklist of visible features. Pi's interactive mode defines observable TUI behavior, while its imperative component implementation and `pi-tui` do not define OpenZi's frontend architecture.

Zi supplies the default visual direction. It does not dictate input semantics, state types, components, or modules.

OpenCode demonstrates useful frontend patterns: route-level screens, scoped providers, direct domain rendering, deep prompt ownership, OpenTUI scroll containers, overlays, and scoped renderer cleanup. OpenZi uses those ideas with React and an in-process session rather than copying Solid or an unnecessary SDK/HTTP synchronization layer. The concrete frontend owners, component rules, and semantic styling contract are defined in [`tui-architecture.md`](tui-architecture.md).

## Workspaces

```text
packages/
  coding-agent/   Pi coding-agent parity and product policy
  tui/            OpenTUI React frontend
  cli/            process entrypoint and mode composition
```

Dependency direction is one-way:

```text
cli -> tui -> coding-agent -> pi-agent-core + pi-ai
  \-----------------------> coding-agent
```

- `coding-agent` never imports a frontend.
- `tui` uses only `coding-agent`'s public API; Pi types needed by frontends are re-exported there.
- `cli` composes concrete modes and owns process exit behavior.
- There is no `shared`, `common`, `utils`, generic UI model, event bus, or internal RPC package.
- A fourth package needs an independently meaningful lifecycle or public use case. Reuse alone is insufficient.

## State and transition architecture

Stateful behavior follows [ADR 0004](adr/0004-explicit-state-and-transitions.md): one owner holds concrete data and resources, admits operations from the current state, and applies explicit transitions. The same discipline applies inside an `AgentSession`, React component, reducer, tool invocation, or process lifecycle; it does not require one universal mechanism.

Mutually exclusive modes use direct discriminated unions with domain fields:

```ts
type PickerState =
  { type: "closed" } | { type: "model"; query: string } | { type: "thinking-level"; selected: ThinkingLevel }
```

Do not replace this with coordinated flags, a generic `{ type, payload }` builder, or optional fields that permit impossible combinations. Independent binary facts may remain booleans. Closed state and event unions are handled exhaustively; persisted, provider, process, and other open input is validated before an owner transitions on it.

The owner also owns temporal correctness. It records admission before starting an effect, bounds the effect, and applies completion only to the operation that started it. Cancellation, failure, settlement, queue limits, and stale results are states or transitions to model and test, not incidental branches distributed among consumers. React renders owner state and requests operations; it does not mirror the machine in a view model or encode its rules across effects.

## Coding-agent architecture

The target shape follows Pi:

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

`AgentSession` is the policy spine shared by all modes. It owns:

- one Pi `Agent`;
- persistence of completed messages;
- model and thinking-level changes;
- steering and follow-up queues;
- active-run admission, cancellation, and settlement;
- later, retry, compaction, branch, bash, and extension policy.

It exposes Pi agent events plus session-level events. Frontends subscribe; they do not control the provider loop or persist messages themselves.

### Managers and services

- `SessionManager` owns one append-only JSONL session tree and its leaf.
- `SettingsManager` owns resolved settings and eventually global/project layering.
- `ModelRegistry` wraps `pi-ai` model discovery and authentication.
- `ResourceLoader` owns context files, prompts, skills, and later extensions/themes.
- `createAgentSession` wires these owners to a Pi `Agent`.

These are concrete product owners, not generic dependency-injection interfaces. Introduce an interface only when there are two real implementations or a consumer-owned testing boundary.

### Tools

Tools belong in `coding-agent`. Each tool owns the resources of one invocation and must make cancellation, timeout, output limits, and cleanup visible. Initial parity order is `read`, `bash`, `edit`, `write`, then `grep`, `find`, and `ls`.

## Frontend architecture

The React tree starts from product concepts rather than a universal view model:

```text
runTui
  -> OpenTUI alternate-screen renderer
      -> App
          -> ThemeProvider
              -> SessionProvider
                  -> SessionScreen
                      -> Transcript scrollbox
                          -> message/part/tool components
                      -> Prompt
          -> overlays (later: dialog, toast, permission, question)
```

P0 `App` requires one already-created `AgentSession`; model resolution and diagnostics happen before the renderer starts. `SessionProvider` subscribes React to that session and retains only bounded transient tool presentation. `Transcript` reads durable and streaming messages directly from `AgentSession`. There is no duplicate transcript store, `TuiSnapshot`, or event-to-view-model corridor.

`Prompt` is intentionally deep. It may own textarea state, autocomplete, history, attachments, shell mode, command dispatch, and picker anchoring because those behaviors share one editor and focus model. Splitting it into pass-through components would make it harder to reason about.

When multiple sessions and partial hydration arrive, a normalized cache keyed by session/message/part may become justified. It should be introduced by that requirement, not in anticipation of it.

OpenTUI owns terminal mode, rendering, focus, width, scrolling mechanics, selection, and input decoding. React owns component composition and scoped frontend state. `AgentSession` owns coding-agent policy.

## Resource shutdown

Shutdown order is explicit:

1. stop accepting frontend actions;
2. abort active session work;
3. await session settlement;
4. dispose session subscriptions/resources;
5. unmount React and destroy OpenTUI;
6. let the CLI print any epilogue and exit.

Renderer destruction restores the title and terminal on normal exit, signal, and error paths. Session settlement has a bounded shutdown deadline.

## Code shape

The codebase optimizes for legibility and local reasoning:

- concrete modules before frameworks;
- narrow public exports;
- one owner for each mutable state family;
- direct calls before commands, buses, adapters, or protocols;
- explicit domain states and owned transitions instead of flag combinations;
- exhaustive closed unions instead of defensive impossible-state branches;
- validation at external, persisted, provider, and process boundaries;
- comments only for invariants, trade-offs, and upstream provenance;
- no JSDoc that restates a name or type;
- no speculative configuration or extension points;
- no package or file split whose only justification is line count.

“Scalable” means a future feature has an obvious owner and path through the system, not that every operation passes through an abstraction. More code is not more robust: avoid verbose AI-generated ceremony, redundant guards, narrated comments, and catch-and-rethrow layers that add no decision.

## First vertical slice

The first complete turn now:

1. registers built-in providers through `pi-ai`;
2. resolves an authenticated model with explicit diagnostics;
3. runs `read`, `bash`, `edit`, and `write` with bounded output and cancellation;
4. creates or resumes an append-only JSONL session;
5. builds `AgentSession` through services;
6. streams assistant, thinking, and tool state directly into React/OpenTUI components;
7. settles the session before terminal teardown;
8. verifies the headless and OpenTUI prompt paths with Pi's faux provider.

Parity continues one vertical capability at a time from this working path.
