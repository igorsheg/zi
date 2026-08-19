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

Set `OPENAI_API_KEY` or pass `--api-key`. Explicit CLI credentials take precedence over credentials stored in `$HOME/.zi/agent/auth.json` and the environment.

Continue the most recent session for the current directory:

```sh
./zig-out/bin/zi --print --continue "What should we do next?"
```

Use `--session PATH` to continue an exact journal from `$HOME/.zi/agent/sessions`. A resumed session uses its stored working directory and model unless `--provider` and `--model` override the model.

Append rules to Zi's default system prompt for one launch:

```sh
./zig-out/bin/zi --print --rules "Prefer focused tests." "Fix the failing test"
```

`--append-system-prompt` is an alias for `--rules`. Use `--system-prompt` or `--system-prompt-override` to replace the default prompt verbatim. Append and replacement options cannot be combined.

For persistent customization, Zi loads `$HOME/.zi/agent/SYSTEM.md` as the composed prompt base and `$HOME/.zi/agent/APPEND_SYSTEM.md` as appended rules. An explicit replacement bypasses both files. Explicit `--rules` replaces `APPEND_SYSTEM.md` for that launch while retaining `SYSTEM.md` as the base. Files must be regular UTF-8 text without NUL bytes and may not exceed 1 MiB each.

Run `./zig-out/bin/zi --help` for the current command surface. Interactive, JSON, and RPC modes are not available yet.
