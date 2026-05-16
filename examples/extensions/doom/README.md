# DOOM extension example

Play DOOM in a zi v4 UI overlay with a retained `surface` node.

This is intentionally split in two:

- `init.lua` is the zi extension. It renders an overlay with a retained `surface` node, starts a helper job, and forwards v4 UI key events to helper stdin.
- `helper/zi-doom-helper.js` owns the DOOM engine. It loads the `doomgeneric` WebAssembly build, ticks at ~35 FPS, converts DOOM's framebuffer into terminal half-block cells, and streams those cells over stdout using zi's `zi-halfblock-rgb-v1` protocol.

The frame protocol is:

```text
HALFBLOCK <cols> <rows> <byte_len>\n<fg_rgb bg_rgb cells>
```

## Run

From the zi repository:

```sh
zi --extension ./examples/extensions/doom
```

Then run:

```text
/doom
```

On first run the helper downloads the shareware `doom1.wad` into this directory. You can also provide a WAD explicitly:

```text
/doom /absolute/path/to/doom1.wad
```

## Controls

- arrows or `WASD`: move
- `F`: fire
- `Space`: use/open
- `Q` or `Esc`: quit the helper and close the overlay

## Files

- `init.lua`: extension entrypoint
- `helper/zi-doom-helper.js`: executable helper job
- `doom/build/doom.js` and `doom/build/doom.wasm`: prebuilt doomgeneric engine from the pi DOOM overlay example
- `doom/doomgeneric_pi.c` and `doom/build.sh`: source/build notes for the WASM engine

## What this demonstrates

- Lua extensions can orchestrate native/host jobs without owning rendering internals.
- zi can decode a continuous binary stdout stream and publish frames into v4 UI nodes.
- High-frequency UI can be composed out of `ctx.ui.view.set`, `ctx.ui.surface.frame`, v4 `ui` events, and `ctx.process`.
- Helpers can stream `zi-halfblock-rgb-v1` records for zi to publish into UI frame nodes.
