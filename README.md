```
░▀▀█░▀█▀
░▄▀░░░█░
░▀▀▀░▀▀▀
```

A coding agent you can build with.

## Build

Zi requires the Zig version pinned in `build.zig.zon`.

```sh
zig build
```

The binary is written to `zig-out/bin/zi`.

## Usage

Run one or more prompts in print mode:

```sh
./zig-out/bin/zi --print --provider openai --model gpt-5.6-sol "Explain this repository"
```

Set `OPENAI_API_KEY` or pass `--api-key`. Explicit CLI credentials take precedence over stored credentials and the environment.

Sign in to OpenAI Codex with a browser or device code:

```sh
./zig-out/bin/zi auth login openai-codex --method browser
./zig-out/bin/zi auth login openai-codex --method device-code
```

Credentials are stored in `$HOME/.zi/agent/auth.json`. Sign out with:

```sh
./zig-out/bin/zi auth logout openai-codex
```

Run `./zig-out/bin/zi --help` for the current command surface. Interactive, JSON, and RPC modes are not available yet.
