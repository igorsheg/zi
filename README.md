# Zi

Zi is a from-scratch Zig 0.16 rewrite of [hax](https://github.com/OleksandrChekhovskyi/hax).
The rewrite currently contains provider-independent conversation and agent-loop
components, provider wire adapters, a bounded cancellable libcurl HTTP/SSE transport,
and a bootstrap CLI.

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
```

Interactive and one-shot agent runs are not implemented yet.
