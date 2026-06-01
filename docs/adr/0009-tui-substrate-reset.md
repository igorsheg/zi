# adr 0009: reset tui work to substrate primitives

status: accepted

date: 2026-06-01

supersedes:

- adr 0006 for current implementation. The one-owner product TUI was useful as
  a spike, but it pulled substrate work into transcript and composer semantics.
- adr 0008 for current implementation. The staging principle remains correct,
  but the first concrete step is lower than transcript-shaped primitives.

## context

The TUI spike proved libvaxis and zio can support an interactive frontend, but
the implementation moved too quickly into Zi product concepts:

```text
App
Composer
Transcript
assistant/user/tool/system rows
prompt submission effects
agent session event application
```

Those are product semantics. They are not the substrate. Continuing from that
shape would make the lower layer depend on product choices before we have
tested text, input, viewport, frame, terminal, and event-pump primitives.

The goal is not to build a generic TUI framework. libvaxis already owns terminal
mechanism and several lower-level text/rendering primitives. Zi should own only
the missing substrate primitives needed to make future product work
straightforward and bounded.

Before adding any custom TUI primitive, first check whether libvaxis already
provides the mechanism at the right layer. If it does, use libvaxis directly or
through a thin Zi ownership boundary. A custom implementation is allowed only
when libvaxis does not provide the primitive, the libvaxis primitive imports
unwanted product/widget policy, or Zi needs a bounded runtime ownership boundary
that libvaxis cannot own.

## decision

`src/tui` is reset to low-level primitives only. Each primitive must either be a
thin boundary around libvaxis/zio ownership or a small mechanism that libvaxis
does not provide in the needed ownership shape:

```text
terminal.zig
  libvaxis lifecycle, alternate screen, resize, event loop boundary

event_pump.zig
  zio-backed bounded terminal event queue

input.zig
  vaxis key -> semantic-free input intent

text.zig
  only helpers that compose libvaxis grapheme/width APIs without becoming a
  second text engine

input_buffer.zig
  bounded editable UTF-8 byte buffer with cursor movement, kept only if
  libvaxis widgets would import unwanted widget/product policy

viewport.zig
  deferred unless a product-independent owner proves it is needed

frame.zig
  deferred unless libvaxis windows are insufficient for deterministic tests
```

The current `coding_agent.tui_mode` product entrypoint is intentionally disabled
with `error.TuiProductNotBuilt`. It will be rebuilt after the substrate is
stable enough that product code does not need to invent terminal event, text, or
input-buffer mechanics inline.

## invariants

- `src/tui` must not import `agent`, `ai`, `coding_agent`, session, provider,
  tool, persistence, auth, or model-selection modules.
- substrate modules must not mention transcript, composer, assistant, user,
  tool, system, prompt, model, or session concepts.
- every queue, buffer, and loop has a named bound.
- libvaxis remains the terminal mechanism; Zi does not wrap it into a second UI
  framework.
- libvaxis primitives are preferred over Zi-owned equivalents. Custom Zi
  primitives must document why libvaxis is insufficient at that boundary.
- future product code may compose substrate primitives, but substrate primitives
  do not know product policy.

## rejected alternatives

- keep the product TUI alive while gradually extracting primitives. This kept
  product names in the lowest layer and made every extraction negotiate with
  live product behavior.
- build generic `BufferStore`, `ViewStore`, `SurfaceStack`, or `SlotRegistry`
  now. Those are extension/product architecture, not the lowest substrate.
- reimplement libvaxis text wrapping, window geometry, widgets, or rendering
  helpers without proving that the libvaxis primitive is the wrong ownership
  boundary.
- vendor OpenTUI or Zag as Zi's TUI architecture. They remain references for
  design discipline, not port targets.
