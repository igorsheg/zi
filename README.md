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

For persistent customization, Zi loads `$HOME/.zi/agent/SYSTEM.md` as the composed prompt base and `$HOME/.zi/agent/APPEND_SYSTEM.md` as appended rules. Pass `--approve` or `-a` to let `$CWD/.zi/SYSTEM.md` and `$CWD/.zi/APPEND_SYSTEM.md` shadow their global counterparts for one launch. `--no-approve` or `-na` explicitly ignores project prompt files. Automatic project prompt trust remains closed in print mode, and launch overrides are not persisted. Resumed sessions resolve project files from their stored working directory.

Explicit `--rules` takes precedence over project and global `APPEND_SYSTEM.md` files while retaining the highest-precedence `SYSTEM.md` base. Prompt files must be regular UTF-8 text without NUL bytes and may not exceed 1 MiB each.

Zi also loads one context file from the global agent directory and from each ancestor of the effective working directory. `AGENTS.md` takes precedence over `CLAUDE.md` in each directory, and files are applied from global and broadest scope to the working directory. Context files must be regular UTF-8 text without NUL bytes. Each file is limited to 64 KiB, with a 128 KiB aggregate limit. An explicit system-prompt replacement is verbatim and bypasses prompt and context file discovery.

Run `./zig-out/bin/zi --help` for the current command surface. Interactive, JSON, and RPC modes are not available yet.
