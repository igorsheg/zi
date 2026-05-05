# DOOM extension example

Play DOOM in a zi extension surface.

This is intentionally split in two:

- `doom.lua` is the zi extension. It opens a host-owned `halfblock_rgb` surface, starts a helper job, and forwards focused surface keyboard input to helper stdin.
- `helper/zi-doom-helper.js` owns the DOOM engine. It loads the `doomgeneric` WebAssembly build, ticks at ~35 FPS, converts DOOM's framebuffer into terminal half-block cells, and streams those cells over stdout using zi's `zi-cell-frame-v1` protocol.

The frame protocol is:

```text
CELLS <cols> <rows> <byte_len>\n<fg_rgb bg_rgb cells>
```

## Run

From the zi repository:

```sh
zi --extension ./examples/extensions/doom/doom.lua
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
- shifted `WASD`: run
- `F`: fire
- `Space`: use/open
- number keys: weapons
- `Q`: quit the helper and close the surface
- `Esc`: return focus to zi's editor

## Files

- `doom.lua`: extension entrypoint
- `helper/zi-doom-helper.js`: executable helper job
- `doom/build/doom.js` and `doom/build/doom.wasm`: prebuilt doomgeneric engine from the pi DOOM overlay example
- `doom/doomgeneric_pi.c` and `doom/build.sh`: source/build notes for the WASM engine

## What this demonstrates

- Lua extensions can orchestrate native/host jobs without owning rendering internals.
- zi can decode a continuous binary stdout stream and publish interactive surfaces.
- High-frequency UI can be composed out of small APIs: `surface_open`, `surface_frame`, `surface_input`, and `zi.job`.
- Helpers can precompute terminal-ready `halfblock_rgb` frames so zi applies cells directly instead of resampling RGBA every render.
