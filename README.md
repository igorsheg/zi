```
░▀▀█░▀█▀
░▄▀░░░█░
░▀▀▀░▀▀▀
```

A coding agent you can build with.

This branch is the Zig rewrite of Zi. It is a native substrate, not a drop-in for the TypeScript product on `main`. There is no npm package, no TUI, and no extension host here yet.

Use pi as the behavioral specification. Use ZigAI and [fx](https://github.com/vercel-labs/fx) as Zig implementation models. Neither is copied.

## Build from source

Requires [Zig 0.16.0+](https://ziglang.org/download/).

```sh
git clone https://github.com/igorsheg/zi
cd zi
zig build
./zig-out/bin/zi
```

```sh
zig build test
zig fmt src/ tools/
```

`zig build` writes `./zig-out/bin/zi`. Use that binary, not an installed `zi` from `PATH`.

## What exists

- `src/ai`: provider-independent model substrate
- `src/agent`: streamed tool loop
- `src/coding_agent`: `AgentSession`, cwd tools, CLI core, journal, paths, model runtime

The binary currently starts and prints that the substrate is ready. Print-mode CLI lives in the library and is not yet the process entrypoint.

## Acknowledgments

Thank you to [Mario Zechner](https://github.com/badlogic) and [pi](https://github.com/earendil-works/pi) for the behavioral specification.

Thank you to [ZigAI](https://github.com/Kludex/zigai) and [fx](https://github.com/vercel-labs/fx) for Zig implementation patterns.

## License

MIT
