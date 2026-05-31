# adr 0002: own the tui runtime and expose buffer-oriented extension surfaces

status: accepted

date: 2026-05-30

## context

zi will have a first-class terminal ui and a lua extension system with behavioral parity goals inspired by `.references/pi-mono`.

pi-mono's extension system is powerful enough to affect both agent behavior and ui behavior:

- register tools, commands, shortcuts, cli flags, providers, and message renderers.
- intercept input, context, agent lifecycle, provider request/response, tool call, and tool result events.
- drive ui primitives such as selectors, confirmations, inputs, editors, notifications, status lines, widgets, custom headers/footers, custom editors, overlays, autocomplete, and raw terminal input.
- inject user/custom messages during active runs with explicit delivery semantics.

zi should support that level of product capability, but pi-mono is a behavioral reference, not a port target. zi's tui will not be a pi-mono-style editor sandwich with `render() => string[]` widgets. zi should support full viewport ownership, retained ui state, z-index/surface ordering, explicit layout and positioning, and a lua api that feels closer to neovim's buffer-oriented extension model.

the terminal substrate decision is also open between:

- vendoring only the core terminal/rendering engine from opentui.
- vendoring libvaxis.

in both cases, zi intends to own the semantic ui layer above the terminal substrate.

## decision

zi will build a zi-owned retained tui runtime over a low-level terminal/rendering substrate. the preferred substrate is libvaxis, subject to a compatibility spike with the project's zig 0.16 toolchain. opentui remains a fallback reference if libvaxis fails the spike or lacks required terminal behavior.

the tui architecture will be buffer-oriented:

```text
+----------------------+       +------------------------+
| AgentSessionRuntime |       | lua extensions         |
| Host / sdk          |       |                        |
|                      |       | - commands             |
| - commands           |       | - keymaps              |
| - public events      |       | - event handlers       |
+----------+-----------+       | - buffer/view actions  |
           |                   +-----------+------------+
           | AgentSessionEvent             |
           v                               |
+----------+-------------------------------v------------+
| zi tui runtime                                          |
|                                                         |
| - BufferStore       durable/semi-durable content models |
| - ViewStore         presentation over buffers           |
| - SurfaceTree       layout, z-index, focus, overlays    |
| - CommandRegistry   actions and keymap dispatch         |
| - AgentBridge       agent events -> buffers/read model  |
| - LuaBridge         lua -> commands/buffers/views       |
+-------------------------+-------------------------------+
                          |
                          | terminal adapter
                          v
+-------------------------+-------------------------------+
| terminal substrate                                      |
|                                                         |
| libvaxis preferred: input, resize, cells, styles,       |
| terminal capabilities, alternate screen, rendering.     |
+---------------------------------------------------------+
```

lua extensions will target zi concepts, not terminal cells:

```text
buffers
views
surfaces
commands
keymaps
events
actions
```

raw terminal rendering is not part of the default extension api. if custom drawing is needed later, it must be added as an explicit bounded capability owned by the tui runtime.

## lessons from zag

zag is the closest positive reference for zi's tui and lua direction. its public README describes "the window system is the platform" and says splits, focus, and buffers are primitives, with everything above that intended as a plugin. its implementation backs that up:

- `src/Buffer.zig` uses a small ptr/vtable buffer interface with stable id, name, and monotonically increasing content version.
- `src/Layout.zig` keeps geometry in a binary split tree and separates tiled leaves from z-ordered floating panes.
- `src/WindowManager.zig` owns pane lifecycle and pane-local draft state while borrowing terminal/screen/compositor and lua engine dependencies.
- `src/Compositor.zig` draws buffers into the screen from layout leaves, reserves prompt/status rows, and renders floats last so higher z-order wins.
- `src/lua/bindings/buffer.zig` exposes lua buffer handles, validates stale handles, and rejects operations that do not match the concrete buffer kind.
- `src/Hooks.zig` models hook payloads as typed variants with explicit rewrite slots and round-trip requests for agent-thread work that must run on the main lua thread.
- `src/lua/hook_registry.zig` adds hook budgets and re-entry guards so plugin callbacks cannot recurse or run without bounds.
- `src/lua/AsyncRuntime.zig`, `LuaIoPool.zig`, and `LuaCompletionQueue.zig` keep lua single-threaded while blocking work runs in a fixed worker pool and returns through a bounded completion queue.

zi should steal these shapes:

```text
Buffer = stable id + content version + type-specific capabilities
View = projection over a buffer, owns presentation state such as scroll/cursor
Layout/SurfaceTree = geometry and z-order, not session or agent lifecycle
TuiRuntime/WindowManager = owner of pane/surface lifecycle and focus
LuaBridge = validates handles and marshals requests to owner mutation sites
HookDispatcher = typed payloads, explicit rewrites, re-entry caps, time budgets
AsyncLuaRuntime = fixed worker pool -> bounded completion queue -> main-thread drain
```

zi should not copy zag wholesale. zag's implementation is a product, not a library, and it carries its own modal editing, provider, session, and pane assumptions. zi should borrow the ownership boundaries and capability shapes, not the whole control flow.

## lessons from pz

pz is less useful as a product architecture reference for zi's extension surface, but it is a strong reference for terminal and test discipline. its public README emphasizes a security-first Zig harness with interactive TUI, headless modes, zero-allocation hot path claims, PTY tests, mocks, policy, and audit. the source gives concrete patterns:

- `src/modes/tui/frame.zig` defines a small styled cell frame with explicit bounds errors, utf-8 validation, wide-character handling, and size-mismatch checks.
- `src/modes/tui/render.zig` diff-renders frame changes, enters/leaves terminal modes explicitly, and keeps renderer setup/cleanup paired.
- `src/modes/tui/vscreen.zig` provides a virtual terminal for snapshot tests by feeding ANSI and inspecting cells.
- `src/test/ansi_ast.zig` parses ANSI into a structured AST so tests assert terminal behavior without brittle raw-byte blobs.
- `src/test/pty_harness.zig` runs the real binary under a PTY with scripted input and environment control.
- `src/core/event_loop.zig` uses explicit bounds for events, timers, and fd handlers, and keeps wakeups explicit.

zi should steal these disciplines:

```text
terminal rendering is testable through a virtual screen and ansi ast
real-process tui behavior is tested through a pty harness
frame/cell writes validate utf-8 and bounds
renderer setup and cleanup are paired and covered
event-loop-like waits expose max event/timer/handler counts
render hot paths avoid steady-state allocation
```

zi should not copy pz's bespoke tui stack or security/audit policy into this ADR. those are separate product choices. the immediate lesson for the tui substrate is testability, explicit bounds, and cleanup discipline.

## lessons from prise

prise is a useful vaxis-native reference for building an application world above the terminal substrate. it is closer to zi's intended substrate direction than pz, and closer to zi's extension goals than a plain vaxis example, but it is still a product reference rather than a port target.

useful patterns:

- `src/Surface.zig` owns a double-buffered terminal surface with explicit dimensions, resize, dirty state, cursor state, colors, and selection state.
- `src/widget.zig` separates layout constraints, measured size, hit regions, split handles, surface resize collection, and rendering into vaxis windows.
- `src/action.zig` uses a typed action union with canonical string names and display names, giving keybinds and command palettes a stable protocol without stringly internal dispatch.
- `src/lua_event.zig` translates vaxis and product events into typed lua payloads rather than exposing raw parser details directly.
- `src/tui_test.zig` converts a vaxis screen to an ascii snapshot and builds test windows from virtual screens, making layout/render behavior cheap to assert.
- `src/redraw.zig` models renderer-facing updates as structured events instead of ad hoc terminal writes.

zi should steal these shapes:

```text
Surface = owned render target with dimensions, dirty bit, cursor/selection state
Widget/Layout = constraints -> size/position -> render into a provided window
Action = typed union + canonical name + display label
LuaEvent = typed product event payloads, not raw terminal internals
TuiTest = virtual screen -> ascii/structured assertions
RedrawEvent = data model for render changes when crossing a boundary
```

zi should not inherit prise's product assumptions such as terminal multiplexer policy, PTY/session lifecycle, or Lua owning the full layout tree by default. zi's agent session, buffers, views, and extension permissions must remain zi-owned.

## lessons from opentui

opentui is not zi's terminal substrate choice, but its zig core is a strong reference for text-buffer and editing discipline. the relevant files include `text-buffer.zig`, `edit-buffer.zig`, `text-buffer-segment.zig`, `text-buffer-iterators.zig`, `utf8.zig`, `grapheme.zig`, `link.zig`, `syntax-style.zig`, and the Unicode-heavy tests under `tests/`.

useful patterns:

- `TextBuffer` has a monotonic content epoch and per-view dirty flags. views can detect stale render caches even if a dirty flag was already cleared.
- text storage is not a plain string forever. opentui uses rope/segments, line iterators, wrap offsets, highlights, style spans, links, and grapheme-aware width calculations.
- editing behavior is separated from storage. `EditBuffer` owns cursor movement, insertion, deletion, undo/redo, word boundaries, and editable cursor metadata over a text buffer.
- text chunks can reference registered backing memory. this avoids copying large text through every layer and keeps render/edit structures compact.
- style spans and highlights are buffer/view data, not terminal-cell ownership.
- the UTF-8 and grapheme tests cover emoji, wide characters, combining marks, zero-width joiners, script transitions, wrapping, selection boundaries, and width-map validation.

zi should steal these shapes:

```text
Buffer.revision = monotonic content epoch
View.revision_seen = stale-cache detection, independent of dirty flags
TextBuffer = future segmented/rope-backed content engine behind the Buffer API
InputBuffer = editable prompt state over a text buffer, not the same type as chat history
TextMetrics = grapheme width, wrap, cursor movement, and selection boundary rules
StyleSpans = structured buffer annotations for markdown, diffs, search, diagnostics
BorrowedText = possible future memory registry for large tool output and diff hunks
```

zi should not copy opentui's renderer, FFI-shaped API surface, event bus, or full rope implementation now. those are too much machinery for the current slice. the immediate commitment is to keep zi's public `Buffer` / `View` / `Surface` API stable enough that the internal buffer storage can later become segmented without changing lua or TUI callers.

## core invariants

```text
terminal substrate
  owns terminal protocol, input decoding, screen/cell rendering, resize, mouse.

zi tui runtime
  owns buffers, views, layout, z-index, focus, render scheduling, and command dispatch.

AgentSessionRuntimeHost
  owns session replacement, prompt runs, cancellation, and public event production.

lua extensions
  own extension-local state and request changes through explicit capabilities.
  they do not mutate terminal cells, host sessions, or renderer internals directly.
```

the frontend event boundary remains:

```text
AgentSessionEvent -> frontend/read model -> buffers/views -> render
```

extensions may observe events and request actions, but owners apply mutation at explicit drain/apply sites.

## why buffer-oriented

coding-agent tui state naturally consists of inspectable content streams and artifacts:

- transcript buffers for conversation and agent events.
- editable buffers for prompt composition.
- tool buffers for command/tool output.
- diff buffers for proposed or applied file edits.
- log buffers for diagnostics and runtime events.
- scratch buffers for extension-created temporary content.
- artifact buffers for markdown, json, code, images, or generated results.

a neovim-inspired buffer/view/action model gives extensions a powerful surface without granting renderer ownership. an extension can create a buffer, write lines or structured content, open a view, bind a key, or run a command. the tui runtime still owns layout, focus, redraw, and terminal safety.

## why not encode pi-mono widgets now

pi-mono exposes ui primitives such as status text, widgets above/below the editor, custom headers, custom footers, custom editors, and overlays. those are valid capabilities at the product level, but their exact shape is tied to pi-mono's tui architecture.

zi will not encode this prematurely in `src/coding_agent/frontend.zig`.

`frontend.zig` may contain renderer-neutral state such as:

```text
ReadModel
FrontendAction
AgentSessionEvent appliers
```

it must not define product-shaped contribution structs such as:

```text
WidgetContribution { lines, above_editor | below_editor }
StatusContribution
custom header/footer factories
terminal-cell drawing callbacks
```

those belong in the tui runtime or lua bridge after the terminal substrate and retained ui architecture are selected.

## substrate choice

prefer libvaxis because it is closer to a zig terminal mechanism:

```text
terminal capabilities
input events
resize events
screen/cell model
styles
alternate screen
rendering
```

this is the level zi wants to vendor. zi does not want to vendor app semantics, component semantics, layout semantics, or extension semantics.

opentui remains valuable as a reference and possible fallback, but its core exists as part of a larger opentui/opencode stack. if extracting only the terminal engine requires importing component/runtime assumptions, it is too high-level for zi's substrate layer.

## compatibility spike

before committing to vendoring libvaxis, zi must prove a bounded spike:

```text
vendor terminal substrate
build with zig 0.16
enter alternate screen
draw one full viewport
handle key input
handle resize
exit and deinit cleanly
```

the spike must expose the substrate through a zi-owned adapter, not directly to app code or future lua code:

```text
src/tui/substrate/terminal.zig
```

the spike must include a test adapter from the beginning:

```text
virtual screen or ansi ast parser
scripted input path
resize injection
cleanup assertion for terminal mode exit
```

## consequences

accepted:

- zi owns the tui semantic runtime.
- lua extension api targets buffers/views/actions, not terminal cells.
- libvaxis is the preferred terminal substrate pending spike verification.
- `coding_agent/frontend.zig` stays renderer-neutral.
- pi-mono extension behavior is a parity target, not an api or architecture copy target.
- zag's buffer/window/lua boundaries are the closest architecture reference.
- pz's terminal test harness and bounded renderer discipline are required quality references.
- prise's surface/action/widget/test vocabulary is a strong reference for zi-owned tui semantics over vaxis.
- opentui's text-buffer, edit-buffer, grapheme, dirty epoch, and style-span disciplines should inform zi's buffer internals.

rejected:

- building the first tui around pi-mono-style string widgets.
- exposing terminal cells as the primary lua extension api.
- letting the terminal substrate decide zi's layout, focus, surface, or extension model.
- encoding extension contribution structs before the retained tui runtime exists.
- copying zag's product stack or pz's bespoke tui stack wholesale.
- copying prise's terminal multiplexer or lua-owned product policy wholesale.
- copying opentui's renderer, FFI API, event bus, or rope implementation before zi needs them.
- accepting a terminal substrate spike without PTY or virtual-screen test hooks.

## open questions

- exact buffer content representation: lines, spans, rope, structured blocks, or mixed.
- whether views own scroll state or scroll state belongs to surfaces.
- how to bound buffer history and rendered viewport caches. answered by ADR 0004.
- whether custom extension surfaces are data-only or allow bounded callbacks.
- final substrate selection after the libvaxis spike.
- hook event taxonomy for zi's lua api.
- lua hook budget defaults and cancellation semantics.
