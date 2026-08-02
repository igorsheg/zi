# Terminal interactive-mode architecture

Zi's `InteractiveMode` is a terminal-specific application over the reusable `AgentSession` business boundary.

## Pi ownership model

Pi's `packages/coding-agent/src/modes/interactive/interactive-mode.ts` imports `pi-tui`, constructs the TUI/editor, and directly uses terminal message, tool, selector, footer, and dialog components. Its print and RPC modes are separate adapters over the session/runtime boundary.

The architectural lesson is that `AgentSession` is reusable; terminal interaction state is not. Zi keeps the terminal code in `packages/tui` because it has a dedicated frontend workspace, but preserves Pi's ownership boundary.

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

- `coding-agent` imports neither `@with-zi/tui` nor `@opentui/core`.
- `tui` consumes coding-agent public APIs and `@opentui/core`.
- Future print/RPC modes consume `AgentSession` without loading OpenTUI.
- A future web client receives its own application owner rather than terminal state.

## Owner graph

```text
AgentSession
  -> InteractiveMode
      -> SlashController
      -> InteractiveKeybindings
      -> SelectionCopyController
      -> InteractiveStore
      -> NotificationCenter + BuiltInNotificationPresenter
      -> SessionScreen
          -> TranscriptView + TranscriptStore
              -> spacing-neutral message sequences
                  -> TranscriptItemView owners
          -> PromptView + PromptStore
              -> SessionGreeterView
              -> AuthCeremonyView
              -> FileCompletionController
              -> Composer
              -> PickerStack + PickerStackView
                  -> PickerList
```

| Owner                          | Lifetime             | State and resources                                                                                    |
| ------------------------------ | -------------------- | ------------------------------------------------------------------------------------------------------ |
| `runTui`                       | one terminal run     | close state, renderer, signals, terminal title, settlement deadline                                    |
| `InteractiveMode`              | one terminal mode    | root subtree, syntax style, current screen, focus, replacement, clear/exit gesture, commands, disposal |
| `SlashController`              | one terminal mode    | bounded descriptor aggregation, fuzzy completion, safe input edits, and closed built-in intents        |
| `InteractiveKeybindings`       | one terminal mode    | semantic IDs, effective overrides, matching, hints, conflicts, closed prompt/transcript actions        |
| `InteractiveStore`             | one terminal mode    | session binding/generation, stale-event rejection, bounded active tools, prompt and Escape delegation  |
| `NotificationCenter`           | one terminal mode    | keyed notices, claimed groups, history, expiry, surface, renderer lifecycle                            |
| `BuiltInNotificationPresenter` | one terminal mode    | narrow Zi-owned notice projection into the bounded `zi.system` group                                   |
| `SystemClipboardReader`        | one terminal mode    | bounded platform subprocesses for explicit local image/text clipboard reads                            |
| `SystemClipboardWriter`        | one terminal mode    | bounded native and OSC 52 text delivery with remote-aware routing                                      |
| `SelectionCopyController`      | one terminal mode    | explicit copy-key precedence, one replaceable write, stale completion, selection clearing, disposal    |
| `PromptStore`                  | one prompt component | active images, typed workflows, input-edit requests, autocomplete arbitration                          |
| `SessionGreeterView`           | one prompt component | retained greeting renderables and derived hidden, compact, or full presentation                        |
| `FileCompletionController`     | one prompt component | parsed `@` context, debounce, active/latest request, bounded result, dismissal, stale rejection        |
| `Composer`                     | one prompt component | native text/editing, atomic paste/image extmarks, range replacement, bounded session-history browsing  |
| `PickerStack`                  | one prompt component | nested frames, top-frame selection/filtering, suspended parent filters, push/pop transitions           |
| `TranscriptStore`              | one transcript       | following versus detached navigation and unseen-output state                                           |
| `TranscriptView`               | one transcript       | retained message projection, keyed tool placement, bounded item ordering and eviction                  |
| `TranscriptItemView`           | one visual item      | native subtree, concrete updates and exactly one trailing transcript gap                               |
| imperative component           | one renderable tree  | native children, subscriptions, input/mouse handlers, explicit destruction                             |

The mode is cohesive, not monolithic: stores split mutable families by invariant and lifetime, while `InteractiveMode` owns their composition.

## Source layout

```text
packages/tui/src/
  interactive/
    interactive-mode.ts
    interactive-store.ts
    notifications.ts
    built-in-notifications.ts
    clipboard.ts
    selection-copy.ts
    slash-controller.ts
    fuzzy-match.ts
    interactive-keybindings.ts
    screen.ts
    run.ts
    prompt/
      state.ts
      store.ts
      view.ts
      file-completion.ts
      frames.ts
      greeter-view.ts
      model-choices.ts
      picker.ts
      picker-view.ts
      auth-ceremony-view.ts
      queue-view.ts
    transcript/
      item.ts
      navigation.ts
      view.ts
      message-view.ts
      tool-view.ts
  components/
    cell-text.ts
    composer.ts
    composer-history-replacement.ts
    composer-range-replacement.ts
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

`SlashController` consumes command descriptors from coding-agent owners, retains at most one current-session catalog projection, derives fuzzy terminal candidates from the current native text and cursor, and resolves selection into a range-safe input edit or a closed built-in intent. It retains no active query, open state, or selection; the mode's session generation invalidates its immutable catalog projection. `FileCompletionController` separately owns the asynchronous `@` interaction: bounded display-offset parsing, debounce, one active and one latest request, stale/session/context validation, token-scoped dismissal, quiet exact/unmatched contexts, and the current bounded result. `PromptView` captures only native before/after-cursor ranges and the following-newline fact from the current logical line, so ordinary editor notifications never build a whole-draft grapheme map. The controller delegates filesystem work to the current `AgentSession`, projects ranked rows into `PickerStack`, and emits only a revisioned range edit after membership validation; it retains neither draft text nor a project catalog. `InteractiveKeybindings` owns the closed terminal action catalog, default and effective keys, descriptions, override conflicts, display hints, and OpenTUI-event translation. It is immutable and contains no handlers. `PromptStore` never contains command syntax, descriptor metadata, replacement ranges, or physical key policy. Its private controller keeps mutable resources as explicit fields, delegates session operations through `InteractiveStore`, and owns retained images, typed command/model/authentication/settings workflows, bounded operation identity, and revisioned one-shot composer edit requests. One-line progress and outcomes are projected through narrow `BuiltInNoticeActions`; `NotificationCenter` owns the resulting items. Active workflows carry the admitted session identity; input secrecy is derived from the authentication state rather than mirrored beside it. Cancellation, disposal, supersession, and session replacement reject stale completion.

`SessionManager` derives at most 100 eligible user-prompt references from its complete append-only journal and serves stable latest/older lookup through `AgentSession`. Compaction changes provider context, not this projection. `Composer` consumes that narrow source and owns an `idle | browsing` zipper containing only visited entry IDs; native replace/undo/redo owns recalled text, the pre-browse draft, cursor, and extmark restoration. A version-pinned OpenTUI 0.4.5 adapter uses a fixed `2 * 100 + 1` native-slot pool because that release's default `replaceText()` exhausts an unreclaimed 255-slot registry. A completed browse remains quarantined while redo references it; the next browse uses a spare replacement to clear redo before recycling those slots. Abandoned or ordinarily undone/redone browse slots stay pinned until external editor reset clears native history, while stable entry-ID mappings let unchanged catalog entries reuse those pinned slots. No TUI store copies the history catalog.

`SessionGreeterView` retains one three-line mark immediately above Composer plus one blank separator row. `PromptView` derives its hidden, compact, or full presentation from current-session message emptiness, terminal dimensions, and picker visibility, and includes the occupied rows in the same fixed-row budget used for prompt-owned contextual rows. It stays visible while an ordinary draft is edited, yields while a picker is open, and hides on constrained terminals. Once the first message commits, it returns only with a new empty session. It owns no store, timer, animation, or copied session state. The sibling-above-prompt placement follows OpenCode Home, while the constrained-terminal tiers follow Grok Build without importing either product's route, scrollback-card, or animation machinery.

`PickerStack` owns open/closed state, ordered frames, selected rows, suspended parent filters, filtering of only the top frame, and an optional preferred total frame height. The active filter is always passed from the native composer; it is not copied into the stack. Pushing captures the parent filter on the child frame, and popping returns it for restoration. `PromptView` owns the picker subscription because it alone computes available terminal height. `PickerStackView` renders only the top frame beneath the composer and owns no input or subscription. Project-file results use a preferred seven-row outer frame; rescoring and directory continuation keep prior rows mounted but visibly disabled until current rows replace them atomically, while initial loading, exact-file, and unmatched contexts render no frame. Optional footer chrome leaves six list rows inside the same total height. `PickerList` retains at most ten visible row renderables keyed by row ID within the active frame scope, preserving overlapping rows and selected row IDs across result replacement when possible, while resetting identity when the frame ID changes. `TranscriptStore` owns the closed following/detached/unseen union; native scroll offsets and selection remain in OpenTUI.

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

Durable transcript messages are appended without rebuilding existing renderables. Streaming and active-tool tails are transient and reconcile independently of committed roots. A transcript item owns one native root, concrete update operations, destruction, and exactly one trailing blank row; assistant-message roots are spacing-neutral sequence owners because one persisted message may contain thinking, Markdown, and tool items. The narrow item contract and lifecycle-colored transparent tool grammar are specified in [Transcript item and tool chrome implementation spec](transcript-item-presentation-implementation-spec.md). Stable-tail reconciliation and bounded presentation are specified in [TUI hot-path and scaling implementation spec](tui-performance-implementation-spec.md), together with performance evidence, the OpenTUI keymap adoption trigger, owner-driven loading rules, and the custom-renderable threshold.

## State placement

| State                                                                           | Owner                              |
| ------------------------------------------------------------------------------- | ---------------------------------- |
| Messages, model, thinking level, queues, shell tasks, persistence, run activity | `AgentSession`                     |
| Bounded full-journal prompt-history reference projection                        | `SessionManager`                   |
| Current session binding and generation                                          | `InteractiveStore`                 |
| Semantic terminal bindings, resolved keys, hints, conflicts                     | `InteractiveKeybindings`           |
| Transient tools and terminal render revisions                                   | `InteractiveStore`                 |
| Typed prompt workflow and one-shot input edits                                  | `PromptStore`                      |
| One-line workflow notices, keyed lifetime, and history                          | `NotificationCenter`               |
| Provider, compaction, retry, and cancellation activity label                    | `PromptView`, derived from session |
| File-completion debounce, request/context identity, dismissal, bounded result   | `FileCompletionController`         |
| Project file enumeration, ranking, cancellation, cwd/process bounds             | coding-agent `ProjectFileSearch`   |
| Picker frames, selection, suspended parent filters                              | `PickerStack`                      |
| Active picker filter text, cursor, focus, paste markers/payloads, undo          | composer `TextareaRenderable`      |
| Idle/browsing history zipper with bounded visited entry IDs                     | `Composer`                         |
| Follow/detached/unseen transcript navigation                                    | `TranscriptStore`                  |
| Scroll offset, viewport, selection                                              | OpenTUI renderables                |
| Pending native callback generations                                             | component owning the resource      |
| Local clipboard read subprocesses and input bounds                              | `SystemClipboardReader`            |
| Native/OSC 52 clipboard delivery and output bounds                              | `SystemClipboardWriter`            |
| Copy admission, in-flight cancellation, and exact-selection completion          | `SelectionCopyController`          |
| Renderer, signals, terminal title, close state, settlement deadline             | `runTui`                           |
| Semantic clear/exit gesture, syntax style, root renderable                      | `InteractiveMode`                  |

There is no module-global mutable application state.

## Input and lifecycle

Global key handlers ask `InteractiveKeybindings` for a closed semantic action and prevent default before editor handling only when terminal product semantics claim the key. Conditional history actions leave the original event unconsumed for ordinary native textarea movement. `SelectionCopyController` is installed before screen handlers, so a delivered Cmd+C or Ctrl+C copies a non-empty native selection without clearing the composer or cancelling a picker; selecting text alone never writes the clipboard. Semantic history Previous/Next defaults to Up/Down only for an idle prompt without a picker. PromptView asks Composer whether history policy intercepts the key; selection and interior wrapped/multiline rows return `native_fallthrough`, so the focused OpenTUI textarea receives the original event, while cursor snaps and history transitions are consumed. At the first or last complete-buffer visual row, Composer traverses stable current-session journal IDs without wrapping. Before browsing, a horizontal cursor on a boundary line snaps to the buffer edge; while browsing, reaching that visual line traverses immediately, matching Pi. Down beyond the newest visited prompt restores the exact native draft, while ordinary edits or external replacement end browsing. OpenTUI owns bracketed-paste parsing and textarea editing; `PromptView` normalizes and bounds the delivered text event, while the semantic clipboard action asks the injected `ClipboardReader` for local image data or text fallback. `Composer` keeps Pi-compatible large-paste and image labels as atomic virtual extmarks, retains at most 32 compact text payloads or 4 MiB before falling back to full insertion, expands exact text payloads for submission, strips visual image labels from submitted text, and reports native image-marker deletion/undo. `PromptStore` admits and remains authoritative for active image attachments against the current model, MIME signature, count, encoded-byte, operation, and session bounds. Committed user messages derive inline `[image #N]` transcript labels from authoritative image content parts; those labels remain presentation-only and never enter model text. Successful selection copy clears only the unchanged native selection; failed, cancelled, and stale writes preserve it. The bounded writer attempts local native delivery and OpenTUI's terminal-aware OSC 52 route, skips remote-host native clipboards over SSH, and reports failure through `BuiltInNotificationPresenter`. Selection copy and picker back take precedence over the exit gesture and reset any earlier arm. Otherwise `InteractiveMode` owns `ready | armed { pressedAt }`: the first effective `app.clear` action—Ctrl+C by default—clears the composer and arms Pi's 500 ms window, while the second requests exit. Ctrl+D requests exit only from an empty composer; Escape cancels an active run and restores detached queued input. Ctrl+G resolves through the semantic catalog: an active foreground task requests the `AgentSession` foreground-to-background transition; otherwise an idle prompt opens the external editor. `InteractiveMode` owns that editor's private temporary file, inherited-stdio child, and OpenTUI suspend/resume lease; successful exit replaces Composer's expanded native draft while stale completion is ignored. The TUI never reaches a session-shell child process or copies the shell task registry. The composer remains mounted and focused during command completion, nested picker navigation, model selection, and transcript selection. Programmatic input edits carry an explicit cursor target. Ordinary replacements target the end; slash completion targets the inserted command boundary; file completion replaces only the parsed full token through one owned native undo point while preserving non-intersecting paste/image extmarks. The Composer-local OpenTUI 0.4.5 adapter uses `replaceTextOwned()` plus the pinned extmark snapshot primitive, so repeated file completions do not consume the native JavaScript replacement registry. Transcript navigation preserves detached intent across output and resize. Queued native callbacks validate their target before applying.

`InteractiveMode.dispose()` releases stores, subscriptions, handlers, syntax resources, and renderables. `runTui` owns a `running | closing | closed` transition, renderer and signal resources, terminal title, and settlement deadline. The first close request disposes terminal input, asks `AgentSession` to discard queued work and abort, and restores the terminal immediately. Settlement is awaited afterward with a deadline. Concurrent interactive, signal, and renderer-destroy requests share that completion. Shutdown errors propagate after terminal restoration, and only the CLI disposes the session it created.

## Commands and selectors

Pi does not have one universal command registry. Built-in descriptors live in coding-agent's slash-command catalog, extension registrations live in `ExtensionRunner`, and prompt/skill commands live with session resources. Terminal `InteractiveMode` assembles those sources for completion and parses/dispatches terminal built-ins. Editor code owns completion mechanics only.

Zi mirrors this ownership. Coding-agent owns `builtinSlashCommands`, while the current `AgentSession` derives prompt-template and `skill:<name>` descriptors from its immutable resources. Mode-owned `SlashController` gives built-ins deterministic precedence, invalidates its bounded catalog projection by session generation, fuzzy-ranks command names, and parses only built-in text into closed intents. Tab completion replaces only the current command token and preserves surrounding input; Enter derives a typed built-in intent from that same completed text, preserving existing arguments, or returns the same safe resource edit. Resource invocations remain raw until `AgentSession` expands them before admission. `PromptStore` turns built-in intents into picker frames and interprets selected row IDs without parsing command syntax or manipulating replacement ranges. For `/model`, `AgentSession` owns catalog configuration and model mutation. `PickerStack` owns nested navigation and top-frame filtering; `PickerStackView` owns selector renderables; the composer remains the only input. `PromptView`, `Composer`, `PickerStackView`, and `PickerList` know neither command names nor invocation syntax. Async selector effects record operation identity and admit completion only when identity, session, and active workflow still match.

Project-file completion is deliberately not part of the slash descriptor aggregate. Coding-agent `ProjectFileSearch` streams bounded Git output or performs a bounded ignore-aware fallback walk rooted at `ZiPaths.cwd`; nested ignore files use inherited directory-scoped matchers, and a subtree is skipped if its ignore policy is unreadable or exceeds admission bounds; it returns at most 20 client-neutral path/kind values and retains no index. TUI `FileCompletionController` parses ordinary textual `@path` references and uses the same picker mechanics, with command-name completion taking precedence. It separates a valid file-completion context from picker visibility: exact unquoted files and refinements append-only in both raw and canonical matcher text remain quiet; slash backspaces and normalization boundaries re-search. Escape suppresses one whole token, and useful result sets rescore inside one retained frame. Accepted references remain prompt text and cause no file read, provider part, or persistence schema change.

## Testing

- Coding-agent behavior is tested at `AgentSession` boundaries.
- Store transitions run without a renderer; picker-stack tests fix top-only filtering, wrapped selection, nested push/pop, and parent-filter restoration.
- TUI fixtures instantiate `InteractiveMode` over `@opentui/core/testing`.
- Keybinding fixtures fix default semantic resolution, normalized overrides, disablement, metadata, hints, conflicts, and real prompt/picker/transcript/history remapping.
- Composer-history fixtures fix bounded full-journal lookup, visual boundaries, stable-ID traversal, draft/extmark restoration, picker precedence, and session replacement.
- Project-file fixtures fix cwd-bound Git/walk search, ignore and symlink policy, ranking, cancellation, parser/formatter display offsets, latest-query transitions, native range undo/extmark preservation, and real below-composer Enter/Tab/Escape behavior.
- Fixtures drive real input, focus, resize, native selection, session replacement, and rendering.
- Lifecycle fixtures drive double Ctrl+C, Ctrl+D, Escape, concurrent SIGHUP/renderer destruction, queued-work disposal, settlement, failure propagation, title cleanup, and session-ownership boundaries.

## Growth rules

1. Determine whether behavior is coding-agent policy or terminal behavior.
2. Put reusable coding-agent policy in `AgentSession` or a concrete manager.
3. Put terminal-only state and resources in the TUI owner with the matching lifetime.
4. Keep explicit states, bounds, stale-operation checks, and disposal with their owner.
5. Move a primitive to root `components/` only when it is domain-free.
6. Extract shared policy only after another real mode or client duplicates it.
