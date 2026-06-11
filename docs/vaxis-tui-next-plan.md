# Vaxis TUI next plan

The first migration removed Zi's hand-rolled terminal substrate/infra/primitive layers. This plan tracks the next Vaxis-native cleanup.

## Invariants

- Vaxis owns terminal mechanism: tty setup, parsing, capability detection, cells, windows, borders, diff/render.
- Zi owns product policy: transcript, composer, commands/effects, session adapter mapping, bounded resident state.
- Keep Zi's owner loop explicit. Do not add a second mutation path through callbacks.
- Every queue/buffer has a named bound and policy.

## 1. Vaxis event loop integration

Status: done

Current state:
- `vaxis_terminal_loop.zig` uses `vaxis.Tty` and `vaxis.Loop(vaxis.Event)`.
- Vaxis owns the input reader thread, parser, event queue, and resize events.
- Zi owns the frame/session owner loop and drains Vaxis events once per frame.

Decision:
- Adopt `vaxis.Loop` for terminal input and resize.
- Keep Zi's frame/session owner loop as the only product mutation site.

Tasks:
- [x] Use `vaxis.Loop(vaxis.Event)` for input events.
- [x] Drain Vaxis events from Zi's frame loop.
- [x] Route Vaxis resize events through `ProductApp.apply(.resize)`.
- [ ] Add Vaxis-screen tests for escape-as-interrupt behavior.

## 2. Capability/query path

Status: pending

Current state:
- We enter alt screen and enable bracketed paste.
- We do not query terminal capabilities.

Target:
- Use Vaxis capability detection without violating Zi's owner loop.

Tasks:
- Decide whether startup can block briefly on `vx.queryTerminal(...)`.
- If blocking is acceptable, run query during `TerminalLoop.setup` with a small timeout.
- If not, implement custom query send + drain responses through the existing parser path.
- Enable useful detected features:
  - kitty keyboard when available
  - Unicode width mode when available
  - color capability where Vaxis supports it
- Add setup failure cleanup test/manual checklist.

## 3. Draw directly to Vaxis windows

Status: done

- `vaxis_renderer.zig` is deleted.
- `Frame.build` draws into Vaxis through a small product draw context backed by `vaxis.Vaxis`/`vaxis.Window`.

Target:
- `frame.zig`, `status_area.zig`, and `shimmer.zig` draw to `vaxis.Window` or small product drawing context directly.
- Delete `vaxis_renderer.zig`.

Tasks:
- [x] Introduce a minimal product draw context only if raw `vaxis.Window` is insufficient.
- [x] Convert `Frame.build` to accept/use Vaxis.
- [x] Delete `vaxis_renderer.zig`.
- [x] Delete renderer compatibility fields like `.next.width` from product drawing.
- [x] Convert status and shimmer helpers further toward Vaxis segments/window printing.
- [ ] Add coverage for cursor placement.

## 4. Use Vaxis windows and borders

Status: in progress

Progress:
- Composer border uses Vaxis `Window.child(.{ .border = ... })` through the temporary renderer adapter.
- Confirm modal border uses Vaxis `Window.child(.{ .border = ... })` through the temporary renderer adapter.

Current state:
- `product/chrome.zig` keeps glyph strings for tool chrome.

Target:
- Use `Window.child(.{ .border = ... })` for rectangular UI surfaces.

Tasks:
- [x] Convert composer border to Vaxis child window with rounded border.
- [x] Convert confirm modal border to Vaxis child window with rounded border.
- [ ] Keep product-specific tool open-block chrome only if Vaxis border API does not fit transcript streaming layout.
- Delete unused `product/chrome.zig` pieces after conversion.

## 5. Tests/manual checks

Status: pending

Add Vaxis-native tests for:
- composer text insertion and submit effect
- transcript append/wrap/scroll
- status slot rendering and shimmer non-crash
- tool block rendering/update
- confirm modal input/rendering
- split input escape behavior

Manual TTY check:

```sh
zig build run -- "hello"
```

Check:
- alt screen restores
- typing and enter submit
- escape interrupts
- ctrl-c clear/exit behavior
- paste does not auto-submit
- resize redraws
