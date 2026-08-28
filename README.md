# Zi

Zi is a from-scratch Zig 0.16 rewrite of [hax](https://github.com/OleksandrChekhovskyi/hax).
The rewrite currently contains provider-independent conversation and agent-loop
components, provider wire adapters, a bounded cancellable libcurl HTTP/SSE transport,
persistent sessions, synchronous tools, and normal-buffer interactive and one-shot CLIs.

## Build

Zi requires Zig 0.16 and libcurl 7.84 or newer development headers. libcurl
must include asynchronous DNS and thread-safe global initialization support.
`pkg-config` is used when available, with a normal system-library fallback. On
Ubuntu, install `pkg-config` and `libcurl4-openssl-dev`. On macOS, the SDK
libcurl works without `pkg-config`; Homebrew users can also install `curl` and
`pkg-config` and expose the Homebrew curl `.pc` file through
`PKG_CONFIG_PATH`.

```sh
zig build
zig build test
```

The binary is written to `zig-out/bin/zi`. Native builds link the system libcurl.
Static libcurl linking is not supported. Cross compilation needs a target
libcurl sysroot and matching pkg-config metadata.

## Usage

```sh
./zig-out/bin/zi --help
./zig-out/bin/zi --version
./zig-out/bin/zi
./zig-out/bin/zi --print "Summarize this repository"
```

Interactive output stays in the terminal's normal buffer. On a TTY, Markdown
rendering is enabled by default and follows the configured theme, tint, and
display-width policy. Tool calls show bounded head or head/tail previews, while
read calls collapse to one-line breadcrumbs. Set `HAX_SHOW_REASONING=1` to show
provider reasoning in dim italic text. Piped output remains plain.

## Mock provider

The internal mock provider exercises dispatch and rendering without an LLM:

```sh
HAX_PROVIDER=mock ./zig-out/bin/zi
HAX_PROVIDER=mock HAX_MOCK_SCRIPT=scripts/mock/layout.txt ./zig-out/bin/zi
```

With `HAX_MOCK_SCRIPT` (`providers.mock.script`), each request consumes one
scripted turn: `text`, `reasoning`, `space`, `tool <name> <json>`, `delay <ms>`,
`usage in=N out=M [cached=K] [cache_write=W] [cache_write_1h=H] [cost=D]`, and
`end-turn`; a final turn may end at EOF. `\n`, `\t`, and `\\` escapes decode in
text, and `{{CWD}}` expands to the working directory. Without a script, the
provider answers heuristically: a backtick-quoted command in the user message
becomes a `bash` (or `read`) tool call when that tool is available, otherwise
the message is echoed. Script fixtures live under `scripts/mock/`. Mock runs
skip session recording by default (`no_session=auto`).
