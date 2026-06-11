# Vaxis TUI migration

Zi is moving TUI substrate/infra/primitives to vendored libvaxis. Zi keeps product state and policy.

## Target shape

```text
src/tui/
  product/
    App.zig                  command/effect owner and product state
    input.zig                small Zi input vocabulary adapted from vaxis.Event
    wrap.zig                 product wrapping via Vaxis unicode/gwidth
    chrome.zig               product-specific chrome strings/helpers
    composer.zig             bounded composer state and cursor policy
    transcript.zig           bounded resident transcript/tool state
    transcript_projection.zig
    markdown_projection.zig
    frame.zig                Zi layout drawn to Vaxis windows
    theme.zig                vaxis.Style/vaxis.Color
    status_area.zig
    surface.zig
    slots.zig
    vaxis_terminal_loop.zig  only terminal loop
    vaxis_smoke_test.zig     tests through Vaxis screen
  root.zig
```

Deleted by the end:

```text
src/tui/substrate/*
src/tui/infra/*
src/tui/primitive/* or only a tiny product-owned wrap helper if still earned
src/tui/product/loop.zig
src/tui/product/terminal_loop.zig
src/tui/product/vscreen_harness.zig
src/tui/product/render_smoke.zig
```

## Invariants

- Vaxis owns raw mode, terminal setup/shutdown, input byte parsing, screen cells, diff/render, and terminal primitive encodings.
- Zi owns transcript/composer/session product state, command validation, effects, and adapter policy.
- `ProductApp.apply(Command) -> ?Effect` remains the only product mutation path.
- Operational input is sanitized/dropped/reported; it never tears down the owner loop.
- Tests assert through Vaxis native screen/cells, not Zi's old renderer.

## Work plan

### 1. Input cut

Status: done

- Add `src/tui/product/input.zig`.
- Adapt `vaxis.Event` / `vaxis.Key` to a tiny Zi product input vocabulary.
- Make `App.zig`, `keys.zig`, and `surface.zig` consume product input.
- Make `vaxis_terminal_loop.zig` use Vaxis parser/loop or direct Vaxis event adaptation.
- Delete dependency on `src/tui/substrate/input.zig` from product code.

### 2. Loop/infra cut

Status: done

- Make `vaxis_terminal_loop.zig` the sole terminal loop.
- Remove old `product/loop.zig`, `product/terminal_loop.zig`, `vscreen_harness.zig`, `render_smoke.zig` exports.
- Delete `src/tui/infra/*` after no imports remain.
- Delete `src/tui/substrate/*` after no imports remain.

### 3. Style cut

Status: done

- Product theme/rendering now use Vaxis styles/colors.
- Vaxis renderer no longer converts Zi styles/colors.
- `src/tui/primitive/style.zig` and `src/tui/primitive/color.zig` are deleted.

- Change `theme.zig` to store `vaxis.Style` and `vaxis.Color` directly.
- Update frame/status/shimmer to use Vaxis style/color.
- Remove `vaxis_renderer` style conversion.
- Delete `primitive/style.zig` and `primitive/color.zig`.

### 4. Text/chrome cut

Status: done

- Product wrapping lives in `src/tui/product/wrap.zig` and uses Vaxis unicode/gwidth.
- Product chrome lives in `src/tui/product/chrome.zig`.
- `src/tui/primitive/*` is deleted.

- Replace `primitive.text` uses with Vaxis unicode/gwidth or a product-owned wrap helper.
- Replace border/chrome drawing with Vaxis `Window.child(.{ .border = ... })` where it fits.
- Move any remaining product-specific chrome strings into product projection modules.
- Delete `primitive/chrome.zig` and `primitive/rect.zig`.

## Validation gates

Run before marking a cut done:

```sh
zig build test
zig build
zig fmt --check src
```
