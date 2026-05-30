# adr 0005: keep tui modules layered by dependency direction

status: accepted

date: 2026-05-31

## context

zi's tui must grow into a composable agent workspace with future lua extension support. without explicit module boundaries, `src/tui` will drift into a flat pile of data structs, rendering helpers, terminal details, and product behavior. that would make new features hard to reason about and easy to couple accidentally.

the goal is not to create a large framework now. the goal is to keep each new tui file in the lowest layer that explains it, with dependency direction enforced by review and tests.

## decision

zi's tui uses rings. dependencies point inward only:

```text
terminal substrate
  -> text/rendering core
  -> retained primitives
  -> components
  -> compositions
  -> app bridge
```

the rings mean:

```text
terminal substrate
  libvaxis lifecycle, raw terminal, input, resize, flush, pty tests, vscreen tests.

text/rendering core
  utf-8/grapheme/display-width helpers, wrapping, truncation, styled text, cell writers.

retained primitives
  Buffer, View, Surface, Slot, Action, Keymap, TuiCommand, TuiEvent.

components
  Composer, Transcript, Status, Header, CompletionMenu, Modal behavior.

compositions
  Built-in shell layouts and larger arrangements of components/primitives.

app bridge
  Owns mutation, dispatch, event application, frontend/agent bridging, and frame ownership.
```

`App` is the owner and dispatcher, not the place where every layout decision lives. composition modules may calculate ids and geometry, but `App` performs mutation.

## rules

- put a module in the lowest ring that can explain it.
- lower rings must not import higher rings.
- terminal substrate must not import product components or app state.
- retained primitives must not import app, coding_agent, agent, or ai.
- composition modules calculate layout; they do not mutate stores directly.
- app owns mutation and may import all inner rings.
- libvaxis windows are frame-local and must not be stored in retained state.
- test harness modules stay test infrastructure and must not become production terminal emulators.

## current mapping

current files map as:

```text
terminal/test substrate
  src/tui/substrate/terminal.zig
  src/tui/substrate/pty.zig
  src/tui/substrate/vscreen.zig
  src/tui/substrate/testing.zig

retained primitives
  src/tui/primitive/action.zig
  src/tui/primitive/buffer.zig
  src/tui/primitive/command.zig
  src/tui/primitive/event.zig
  src/tui/primitive/slot.zig
  src/tui/primitive/surface.zig
  src/tui/primitive/transcript.zig
  src/tui/primitive/view.zig

components
  src/tui/component/composer.zig
  src/tui/component/transcript_renderer.zig

compositions
  src/tui/composition/shell.zig

app bridge
  src/tui/bridge/app.zig
```

`src/tui/root.zig` re-exports the stable public module names. callers outside
`src/tui` should import through that root unless a test intentionally targets a
specific layer.

## non-goals

- do not create empty folders or speculative module trees.
- do not build a generic widget framework before zi needs one.
- do not expose libvaxis windows or raw terminal cells as the default extension api.
- do not make every feature own input, layout, and rendering.
- do not turn `vscreen.zig` into a full terminal emulator; use libghostty-vt or another proven dependency if full vt correctness becomes required.

## consequence

adding a feature should usually mean adding one of:

```text
new buffer kind
new view renderer
new surface composition
new slot contribution
new action
new read-model field
new transcript item kind
```

if a feature requires a private rendering path or direct terminal mutation, the design is suspect and must be justified by a separate ADR.
