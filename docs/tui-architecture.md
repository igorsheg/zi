# TUI architecture

OpenZi's TUI is a direct OpenTUI React frontend for `AgentSession`. Its architecture follows the owners and lifetimes in this codebase and delegates terminal mechanics to OpenTUI. Pi interactive mode defines product behavior; Zi supplies the default visual direction.

## Reference roles

| Reference                  | Role                                                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| OpenTUI React              | Renderer, layout, focus, input, selection, dimensions, and scrolling                                                                  |
| React                      | Component composition and scoped frontend state                                                                                       |
| Pi interactive mode        | Editor, keybinding, queue, command, selector, session-flow, and lifecycle behavior                                                    |
| OpenCode                   | Proven OpenTUI patterns worth evaluating, especially direct rendering, deep prompts, scoped providers, overlays, and renderer cleanup |
| Zi                         | Default palette, glyphs, spacing, and overall visual appearance                                                                       |
| React composition patterns | API review guidance after concrete reuse appears                                                                                      |

OpenZi ports Pi interactive behavior capability by capability without recreating Pi's imperative TUI component system. It also does not copy OpenCode's Solid context graph, SDK/HTTP synchronization layer, command framework, or plugin slots. Zi defines neither behavior nor architecture.

## Stack-native render path

```text
runTui
  -> OpenTUI renderer
  -> React root
      -> App
          -> ThemeProvider
          -> SessionProvider
              -> SessionScreen
                  -> Transcript
                      -> message and tool presentation
                  -> Prompt
                      -> working/error status and textarea
          -> overlays (when the first overlay feature arrives)
```

- OpenTUI owns terminal mode, cell rendering, flex layout, clipping, focus, selection, input decoding, scroll mechanics, and terminal dimensions.
- React owns component composition and ephemeral state scoped to a component lifetime.
- `AgentSession` owns session policy, durable messages, active work, queues, cancellation, persistence, model, and thinking level.
- Components render these owners directly. There is no frame model, row plan, frontend transcript, event bus, view-model layer, or generic widget tree.

## Owners and lifetimes

| Owner               | Mutable responsibility                                                                    | Lifetime                 |
| ------------------- | ----------------------------------------------------------------------------------------- | ------------------------ |
| `runTui`            | OpenTUI renderer, React root, process signals, terminal title, and ordered teardown       | Interactive process mode |
| `App`               | One pre-created session and terminal-sized application composition                        | Mounted React root       |
| `ThemeProvider`     | Active immutable semantic theme and native Markdown syntax style                          | App                      |
| `SessionProvider`   | One `AgentSession` subscription and bounded transient tool-execution presentation         | Mounted session          |
| `Transcript`        | Session scrollbox and later follow-tail, viewport position, and unseen-output interaction | Session screen           |
| `Prompt`            | Textarea, focus, submission, local errors, and working status                             | Session screen           |
| Future overlay host | Overlay stack and focus restoration                                                       | App                      |

Ownership follows mutable state and resource lifetime, not visual rectangles. A component that only renders props is not described as an owner.

`SessionProvider` does not copy session messages. Pi tool lifecycle events include transient progress that is not a durable message, so the provider retains only a bounded collection of active tool presentation. Session messages remain direct reads from `AgentSession`.

## Component taxonomy

### Screens

A screen composes one product mode and owns its top-level layout. `SessionScreen` currently arranges the scrollable transcript and prompt. P0 constructs exactly one session before mounting `App`; add routing only when a second independently navigable screen exists.

### Stateful product components

A stateful product component owns a cohesive interaction:

- `Transcript` owns scrolling behavior because scroll position, follow-tail, unseen output, selection, and the scrollbox reference evolve together.
- `Prompt` owns editing behavior because draft text, history, completion, attachments, shell mode, submission, and focus share one textarea.

These components should be deep. Splitting their behavior across pass-through wrappers would distribute one state machine without reducing complexity.

### Presentation components

Message variants and tool blocks turn concrete domain values into OpenTUI elements. Prefer explicit variants such as user, assistant, command tool, generic tool, and compaction presentation over boolean prop combinations. Assistant text uses OpenTUI's native Markdown renderable rather than a frontend parser or ANSI cache.

Presentation components may own bounded formatting policy, such as a tool output preview. They do not subscribe to sessions, schedule work, or mutate coding-agent state.

### UI infrastructure

Infrastructure exists only for repeated cross-screen mechanism with a real lifetime:

- theme resolution;
- later, overlay focus restoration;
- later, toast timeout ownership;
- later, clipboard integration.

Do not create wrappers around `<box>` or `<text>` that merely forward styling props. There is no `Widget`, `Region`, `Surface`, generic provider contract, or component registry.

## Theme and styling

`Theme` contains semantic terminal color roles. The initial `ziTheme` implements the accepted Zi palette. Components consume it through `useTheme()`; application colors are not scattered through component files.

Styling has three layers:

1. **Semantic theme roles** — application and content surfaces, text hierarchy, statuses, borders, Markdown, and diffs.
2. **Glyph vocabulary** — shared structural symbols such as tool rails and selection markers.
3. **Component geometry** — padding, margins, borders, wrapping, and visible-output caps remain with the component whose UI contract they express.

Geometry is intentionally not hidden behind a global spacing scale. Terminal layout is cell-based and local values such as transcript rhythm or prompt expansion are easier to understand beside the responsible component.

P0 has one immutable built-in theme. Theme discovery, persistence, terminal-palette derivation, and a theme picker require their own later capabilities; the current context does not imply those systems already exist.

## React composition policy

Use React composition to keep concrete owners cohesive, not to turn the TUI into a component library.

- Keep providers specific: `ThemeProvider`, `SessionProvider`, and later an overlay provider.
- Do not introduce a generic `{ state, actions, meta }` context while there is one session and one prompt implementation.
- Do not make `Prompt` a compound component until at least two real prompt compositions need shared pieces.
- Use children for structural composition, as `AppSurface` does; use explicit components such as `CommandToolBlock` when behavior differs.
- Prefer children when a component genuinely accepts content composition; do not add `renderX` callbacks speculatively.
- Add explicit variants when one component starts accumulating incompatible mode booleans.
- Use React 19 `use()` and ref props; do not add `forwardRef` compatibility layers.

The composition-patterns guidance is a review lens, not the source architecture.

## Interactive-mode parity

The behavior of `pi-coding-agent` interactive mode is characterized at the user-observable boundary. Fixtures may specify:

- initial session and settings state;
- an input or key sequence;
- resulting session actions and state transitions;
- focus, editor contents, queue contents, or selector state;
- visible lifecycle semantics such as working, retry, compaction, cancellation, and errors.

The source behavior lives under the pinned `pi-coding-agent/src/modes/interactive/` implementation and its tests. OpenZi reproduces that behavior through React and OpenTUI; a fixture may not require Pi component classes, `render(width): string[]`, manual invalidation, or `pi-tui` containers.

## Zi visual target

Zi-derived fixtures cover the default palette, glyphs, spacing, and representative terminal frames. They do not define keybindings, queue semantics, focus transitions, commands, or selector behavior.

OpenTUI may provide its native wrapping, clipping, selection, and layout behavior unless a visual acceptance fixture demonstrates a mismatch.

## Growth rules

- Add one capability through its concrete owner and visible acceptance test.
- Add an overlay host with the first picker or dialog, not before.
- Keep transcript rendering direct until multiple sessions with partial hydration create real pressure for a normalized cache.
- Keep frontend collections bounded. Active tools, completion candidates, queue echoes, toasts, and overlay depth require explicit policies when introduced.
- Extract a module when it contains cohesive mechanism behind a narrower interface, not to reduce file length.
- If a proposed abstraction mirrors `AgentSession`, OpenTUI layout, or React state, delete it and render the owner directly.

## P0 acceptance scope

The P0 TUI architecture is established when:

- renderer and shutdown ownership are explicit;
- theme values and glyphs are centralized;
- `SessionProvider` is the only session subscription boundary;
- `Transcript` owns the scrollbox;
- `Prompt` owns textarea interaction;
- concrete message, Markdown, and tool presentation use semantic styling;
- normal and constrained terminal fixtures exercise the real OpenTUI path.

Finishing P0 then means porting the remaining Pi interactive behavior in scope and iterating on the rendered visual fixtures. Neither requires another architecture layer.
