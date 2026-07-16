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
      -> InteractiveKeybindings
      -> InteractiveStore
      -> SessionScreen
          -> TranscriptView + TranscriptStore
              -> message and tool renderables
          -> PromptView + PromptStore
              -> Composer
              -> PickerStack + PickerStackView
                  -> PickerList
```

| Owner                    | Lifetime             | State and resources                                                                                    |
| ------------------------ | -------------------- | ------------------------------------------------------------------------------------------------------ |
| `runTui`                 | one terminal run     | close state, renderer, signals, terminal title, settlement deadline                                    |
| `InteractiveMode`        | one terminal mode    | root subtree, syntax style, current screen, focus, replacement, clear/exit gesture, commands, disposal |
| `InteractiveCommands`    | one terminal mode    | descriptor aggregation, completion policy, invocation parsing into closed built-in intents             |
| `InteractiveKeybindings` | one terminal mode    | semantic IDs, effective overrides, matching, hints, conflicts, closed prompt/transcript actions        |
| `InteractiveStore`       | one terminal mode    | session binding/generation, stale-event rejection, bounded active tools, prompt and Escape delegation  |
| `PromptStore`            | one prompt component | feedback, images, typed workflows, input-edit requests, bounded async operation identity               |
| `PickerStack`            | one prompt component | nested frames, top-frame selection/filtering, suspended parent filters, push/pop transitions           |
| `TranscriptStore`        | one transcript       | following versus detached navigation and unseen-output state                                           |
| imperative component     | one renderable tree  | native children, subscriptions, input/mouse handlers, explicit destruction                             |

The mode is cohesive, not monolithic: stores split mutable families by invariant and lifetime, while `InteractiveMode` owns their composition.

## Source layout

```text
packages/tui/src/
  interactive/
    interactive-mode.ts
    interactive-store.ts
    interactive-commands.ts
    interactive-keybindings.ts
    screen.ts
    run.ts
    prompt/
      state.ts
      store.ts
      view.ts
      frames.ts
      model-choices.ts
      picker.ts
      picker-view.ts
      feedback-view.ts
      queue-view.ts
    transcript/
      navigation.ts
      view.ts
      message-view.ts
      tool-view.ts
  components/
    cell-text.ts
    composer.ts
    picker-list.ts
  glyphs.ts
  theme.ts
```

The `prompt/` and `transcript/` directories keep each terminal feature's state owner, renderables, and pure presentation builders together. Root `components/` contains mechanics with no coding-agent policy.

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
  dispose(): void
}
```

It retains a current session reference for identity and replacement but does not copy messages, model, queues, or persistence state. Session events update only terminal revisions and bounded transient tool presentation. Events from a replaced session are rejected.

`InteractiveCommands` consumes command descriptors from coding-agent owners, supplies terminal completion candidates, and parses invocation strings into a closed built-in intent union. `InteractiveKeybindings` owns the closed terminal action catalog, default and effective keys, descriptions, override conflicts, display hints, and OpenTUI-event translation. It is immutable and contains no handlers. `PromptStore` never contains command syntax, descriptor metadata, or physical key policy. Its private controller keeps mutable resources as explicit fields, delegates session operations through `InteractiveStore`, and owns feedback, retained images, typed command/model/authentication/settings workflows, bounded operation identity, and revisioned one-shot composer edit requests. Active workflows carry the admitted session identity; input secrecy is derived from the authentication state rather than mirrored beside it. Cancellation, disposal, supersession, and session replacement reject stale completion.

`PickerStack` owns open/closed state, ordered frames, selected rows, suspended parent filters, and filtering of only the top frame. The active filter is always passed from the native composer; it is not copied into the stack. Pushing captures the parent filter on the child frame, and popping returns it for restoration. `PickerStackView` renders only the top frame beneath the composer and owns no input. `TranscriptStore` owns the closed following/detached/unseen union; native scroll offsets and selection remain in OpenTUI.

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

Durable transcript messages are appended without rebuilding existing renderables. Streaming and active-tool tails are transient and reconcile independently of committed roots. The planned stable-tail reconciliation and bounded presentation window are specified in [TUI hot-path and scaling implementation spec](tui-performance-implementation-spec.md), together with performance evidence, the OpenTUI keymap adoption trigger, owner-driven loading rules, and the custom-renderable threshold.

## State placement

| State                                                               | Owner                         |
| ------------------------------------------------------------------- | ----------------------------- |
| Messages, model, thinking level, queues, persistence, run activity  | `AgentSession`                |
| Current session binding and generation                              | `InteractiveStore`            |
| Semantic terminal bindings, resolved keys, hints, conflicts         | `InteractiveKeybindings`      |
| Transient tools and terminal render revisions                       | `InteractiveStore`            |
| Prompt feedback, typed workflow, one-shot input edits               | `PromptStore`                 |
| Picker frames, selection, suspended parent filters                  | `PickerStack`                 |
| Active picker filter text, cursor, focus, paste, undo               | composer `TextareaRenderable` |
| Follow/detached/unseen transcript navigation                        | `TranscriptStore`             |
| Scroll offset, viewport, selection                                  | OpenTUI renderables           |
| Pending native callback generations                                 | component owning the resource |
| Renderer, signals, terminal title, close state, settlement deadline | `runTui`                      |
| Semantic clear/exit gesture, syntax style, root renderable          | `InteractiveMode`             |

There is no module-global mutable application state.

## Input and lifecycle

Global key handlers ask `InteractiveKeybindings` for a closed semantic action and prevent default before editor handling when terminal product semantics override native behavior. Native selection copy and picker back take precedence over the exit gesture and reset any earlier arm. Otherwise `InteractiveMode` owns `ready | armed { pressedAt }`: the first effective `app.clear` action—Ctrl+C by default—clears the composer and arms Pi's 500 ms window, while the second requests exit. Ctrl+D requests exit only from an empty composer; Escape cancels an active run and restores detached queued input. The composer remains mounted and focused during command completion, nested picker navigation, model selection, and transcript selection. Programmatic input edits always move the native cursor to the end. Transcript navigation preserves detached intent across output and resize. Queued native callbacks validate their target before applying.

`InteractiveMode.dispose()` releases stores, subscriptions, handlers, syntax resources, and renderables. `runTui` owns a `running | closing | closed` transition, renderer and signal resources, terminal title, and settlement deadline. The first close request disposes terminal input, asks `AgentSession` to discard queued work and abort, and restores the terminal immediately. Settlement is awaited afterward with a deadline. Concurrent interactive, signal, and renderer-destroy requests share that completion. Shutdown errors propagate after terminal restoration, and only the CLI disposes the session it created.

## Commands and selectors

Pi does not have one universal command registry. Built-in descriptors live in coding-agent's slash-command catalog, extension registrations live in `ExtensionRunner`, and prompt/skill commands live with session resources. Terminal `InteractiveMode` assembles those sources for completion and parses/dispatches terminal built-ins. Editor code owns completion mechanics only.

OpenZi mirrors this ownership. Coding-agent owns `builtinSlashCommands`, while the current `AgentSession` derives prompt-template and `skill:<name>` descriptors from its immutable resources. Mode-owned `InteractiveCommands` reads that current session on demand, gives built-ins deterministic precedence, assembles completion candidates, and parses only built-in text into closed intents. Resource invocations remain raw until `AgentSession` expands them before admission. `PromptStore` turns built-in intents into picker frames and interprets selected row IDs; selecting a resource command edits the composer instead of dispatching domain work in the TUI. For `/model`, `AgentSession` owns catalog configuration and model mutation. `PickerStack` owns nested navigation and top-frame filtering; `PickerStackView` owns selector renderables; the composer remains the only input. `PromptView`, `Composer`, `PickerStackView`, and `PickerList` know neither command names nor invocation syntax. Async selector effects record operation identity and admit completion only when identity, session, and active workflow still match.

## Testing

- Coding-agent behavior is tested at `AgentSession` boundaries.
- Store transitions run without a renderer; picker-stack tests fix top-only filtering, wrapped selection, nested push/pop, and parent-filter restoration.
- TUI fixtures instantiate `InteractiveMode` over `@opentui/core/testing`.
- Keybinding fixtures fix default semantic resolution, normalized overrides, disablement, metadata, hints, conflicts, and real prompt/picker/transcript remapping.
- Fixtures drive real input, focus, resize, native selection, session replacement, and rendering.
- Lifecycle fixtures drive double Ctrl+C, Ctrl+D, Escape, concurrent SIGHUP/renderer destruction, queued-work disposal, settlement, failure propagation, title cleanup, and session-ownership boundaries.

## Growth rules

1. Determine whether behavior is coding-agent policy or terminal behavior.
2. Put reusable coding-agent policy in `AgentSession` or a concrete manager.
3. Put terminal-only state and resources in the TUI owner with the matching lifetime.
4. Keep explicit states, bounds, stale-operation checks, and disposal with their owner.
5. Move a primitive to root `components/` only when it is domain-free.
6. Extract shared policy only after another real mode or client duplicates it.
