# Terminal interactive-mode architecture

OpenZi's `InteractiveMode` is a terminal-specific application over the reusable `AgentSession` business boundary.

## Pi ownership model

Pi's `packages/coding-agent/src/modes/interactive/interactive-mode.ts` imports `pi-tui`, constructs the TUI/editor, and directly uses terminal message, tool, selector, footer, and dialog components. Its print and RPC modes are separate adapters over the session/runtime boundary.

The architectural lesson is that `AgentSession` is reusable; terminal interaction state is not. OpenZi keeps the terminal code in `packages/tui` because it has a dedicated frontend workspace, but preserves Pi's ownership boundary.

## Dependency boundary

```text
packages/coding-agent
  AgentSession, managers, tools, shared policy
       ^
       |
packages/tui
  terminal InteractiveMode, Nano Stores, imperative OpenTUI
       ^
       |
packages/cli
  runtime construction and mode selection
```

- `coding-agent` imports neither `@openzi/tui` nor `@opentui/core`.
- `tui` consumes coding-agent public APIs and `@opentui/core`.
- Future print/RPC modes consume `AgentSession` without loading OpenTUI.
- A future web client receives its own application owner rather than terminal state.

## Owner graph

```text
AgentSession
  -> InteractiveMode
      -> InteractiveCommands
      -> InteractiveStore
      -> SessionScreen
          -> TranscriptView + TranscriptStore
              -> message and tool renderables
          -> PromptView + PromptStore
              -> Composer + slash completion
              -> ModelSelectorView + PickerList
```

| Owner                 | Lifetime             | State and resources                                                                                    |
| --------------------- | -------------------- | ------------------------------------------------------------------------------------------------------ |
| `runTui`              | one terminal run     | renderer, signals, terminal title, abort deadline                                                      |
| `InteractiveMode`     | one terminal mode    | root subtree, syntax style, current screen, focus, replacement, command aggregate, disposal            |
| `InteractiveCommands` | one terminal mode    | descriptor aggregation, completion policy, invocation parsing into closed built-in intents             |
| `InteractiveStore`    | one terminal mode    | session binding/generation, stale-event rejection, bounded active tools, prompt/queue/abort delegation |
| `PromptStore`         | one prompt component | feedback, images, active completion, selector transitions, bounded async operation identity            |
| `TranscriptStore`     | one transcript       | following versus detached navigation and unseen-output state                                           |
| imperative component  | one renderable tree  | native children, subscriptions, input/mouse handlers, explicit destruction                             |

The mode is cohesive, not monolithic: stores split mutable families by invariant and lifetime, while `InteractiveMode` owns their composition.

## Source layout

```text
packages/tui/src/
  interactive/
    interactive-mode.ts
    interactive-commands.ts
    model-selector.ts
    run.ts
    stores/
      interactive.ts
      prompt.ts
      transcript.ts
    components/
      session-screen.ts
      prompt.ts
      model-selector.ts
      transcript.ts
      message.ts
      tool-block.ts
  components/
    composer.ts
    picker-list.ts
  glyphs.ts
  theme.ts
```

Root `components/` contains domain-free terminal mechanics. `interactive/components/` may render coding-agent types but does not own coding-agent policy.

Do not add a global store registry, generic action bus, universal frontend mode, or view-model corridor.

## Interactive store

`InteractiveStore` is the mode's application-state owner:

```ts
interface InteractiveStore {
  readonly $state: ReadableAtom<InteractiveState>
  readonly $generation: ReadableAtom<number>
  readonly $promptRevision: ReadableAtom<number>
  readonly $transcriptRevision: ReadableAtom<number>
  readonly $activeTools: ReadableAtom<ReadonlyMap<string, ActiveTool>>
  getSession(): AgentSession
  replaceSession(session: AgentSession): void
  submit(submission: PromptSubmission): Promise<void>
  restoreQueuedInputs(): QueuedInputs
  abortAndRestoreQueuedInputs(): AbortedQueuedInputs
  abort(): Promise<void>
  dispose(): void
}
```

It retains a current session reference for identity and replacement but does not copy messages, model, queues, or persistence state. Session events update only terminal revisions and bounded transient tool presentation. Events from a replaced session are rejected.

`InteractiveCommands` consumes command descriptors from coding-agent owners, supplies terminal completion candidates, and parses invocation strings into a closed built-in intent union. `PromptStore` never contains command syntax or descriptor metadata. It delegates session operations through `InteractiveStore` and owns feedback, retained images, active completion selection, and the closed composer/loading-models/model-selector/selecting-model workflow. Each async model operation captures its operation identity and session; cancellation, disposal, supersession, and session replacement reject stale completion. Live composer and model-search text remain native OpenTUI state and are passed into store operations rather than mirrored. `TranscriptStore` owns the closed following/detached/unseen union; native scroll offsets and selection remain in OpenTUI.

Writable atoms are private. One coherent atom owns one invariant family; “small stores” does not mean an atom per field.

## Imperative component contract

An imperative component owns one renderable subtree:

```ts
interface Composer {
  readonly root: BoxRenderable
  readonly input: TextareaRenderable
  update(geometry: ComposerGeometry, title: string, bottomTitle: string): void
  destroy(): void
}
```

The owner:

1. constructs children once where identity matters;
2. subscribes to the narrow state it renders;
3. mutates only its own renderables;
4. installs native handlers explicitly;
5. removes handlers and subscriptions before destroying its subtree.

Durable transcript messages are appended without rebuilding existing renderables. Streaming and active-tool tails are replaced independently, preserving native selection and detached scroll anchors.

## State placement

| State                                                              | Owner                         |
| ------------------------------------------------------------------ | ----------------------------- |
| Messages, model, thinking level, queues, persistence, run activity | `AgentSession`                |
| Current session binding and generation                             | `InteractiveStore`            |
| Transient tools and terminal render revisions                      | `InteractiveStore`            |
| Prompt feedback, slash completion, model-selector workflow         | `PromptStore`                 |
| Follow/detached/unseen transcript navigation                       | `TranscriptStore`             |
| Textarea text, cursor, focus, paste, undo                          | OpenTUI `TextareaRenderable`  |
| Scroll offset, viewport, selection                                 | OpenTUI renderables           |
| Pending native callback generations                                | component owning the resource |
| Renderer, signals, terminal title, shutdown deadline               | `runTui`                      |
| Syntax style and root renderable                                   | `InteractiveMode`             |

There is no module-global mutable application state.

## Input and lifecycle

Global key handlers prevent default before editor handling when terminal product semantics override native behavior. The prompt remains focused during transcript selection. Transcript navigation preserves detached intent across output and resize. Queued native callbacks validate their target before applying.

`InteractiveMode.dispose()` releases stores, subscriptions, handlers, syntax resources, and renderables. `runTui` owns renderer and signal resources, aborts the session during shutdown, and leaves final session disposal to the CLI that created it.

## Commands and selectors

Pi does not have one universal command registry. Built-in descriptors live in coding-agent's slash-command catalog, extension registrations live in `ExtensionRunner`, and prompt/skill commands live with session resources. Terminal `InteractiveMode` assembles those sources for completion and parses/dispatches terminal built-ins. Editor code owns completion mechanics only.

OpenZi mirrors this ownership. Coding-agent owns `builtinSlashCommands`. Mode-owned `InteractiveCommands` assembles completion candidates and parses built-in text into closed intents. `PromptStore` owns active completion and selector transitions after receiving an intent. For `/model`, `AgentSession` owns catalog configuration and model mutation; `ModelSelectorView` owns the native search input and selector renderables. `PromptView`, `Composer`, and `PickerList` know neither command names nor invocation syntax. Async selector effects record operation identity and admit completion only when identity, session, and active surface still match.

## Testing

- Coding-agent behavior is tested at `AgentSession` boundaries.
- Store transitions run without a renderer.
- TUI fixtures instantiate `InteractiveMode` over `@opentui/core/testing`.
- Fixtures drive real input, focus, resize, native selection, session replacement, and rendering.

## Growth rules

1. Determine whether behavior is coding-agent policy or terminal behavior.
2. Put reusable coding-agent policy in `AgentSession` or a concrete manager.
3. Put terminal-only state and resources in the TUI owner with the matching lifetime.
4. Keep explicit states, bounds, stale-operation checks, and disposal with their owner.
5. Move a primitive to root `components/` only when it is domain-free.
6. Extract shared policy only after another real mode or client duplicates it.
