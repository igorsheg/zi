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
  -> product surfaces
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
  Buffer, View, Surface, Slot, Focus, Frame policy, grapheme helpers.

product surfaces
  Zi-specific surfaces such as Composer, Transcript, Status, Header, and
  transcript renderers. Reusable mechanics such as Frame, TextInput, Menu, or
  List should move to a future widget layer only after they exist as reused
  mechanics.

compositions
  Built-in shell layouts and larger arrangements of product surfaces/primitives.

app bridge
  Owns mutation, `TuiCommand`, `TuiEvent`, dispatch, event application,
  frontend/agent bridging, and frame ownership.
```

`App` is the owner and dispatcher, not the place where every layout decision lives. composition modules may calculate ids and geometry, but `App` performs mutation.

## rules

- put a module in the lowest ring that can explain it.
- lower rings must not import higher rings.
- terminal substrate must not import product surfaces or app state.
- retained primitives must not import app, coding_agent, agent, or ai.
- composition modules calculate layout; they do not mutate stores directly.
- app owns mutation and may import all inner rings.
- libvaxis windows are frame-local and must not be stored in retained state.
- primitives may use libvaxis unicode/width helpers, but not windows, terminal
  lifecycle, event loops, or raw cell mutation.
- test harness modules stay test infrastructure and must not become production terminal emulators.

## current mapping

current files map as:

```text
terminal/test substrate
  src/tui/substrate/terminal.zig
  src/tui/substrate/vscreen.zig
  src/tui/substrate/testing.zig
  src/tui/testing/pty.zig

retained primitives
  src/tui/primitive/buffer.zig
  src/tui/primitive/focus.zig
  src/tui/primitive/frame.zig
  src/tui/primitive/grapheme.zig
  src/tui/primitive/slot.zig
  src/tui/primitive/surface.zig
  src/tui/primitive/view.zig

product surfaces
  src/tui/product/composer.zig
  src/tui/product/transcript.zig
  src/tui/product/transcript_renderer.zig

compositions
  src/tui/composition/builtin.zig
  src/tui/composition/shell.zig

app bridge
  src/tui/bridge/agent_adapter.zig
  src/tui/bridge/app.zig
  src/tui/bridge/command.zig
  src/tui/bridge/event.zig
  src/tui/bridge/input_router.zig
  src/tui/bridge/read_model.zig
```

`src/tui/root.zig` re-exports only the intentionally small frontend-facing
surface: built-in composition ids, frame policy, and terminal setup. bridge
owners such as `App`, `input_router`, and `agent_adapter` are imported directly
by `coding_agent/tui_mode.zig` because they are integration points, not general
TUI API.

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
