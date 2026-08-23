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

Start an interactive session from a terminal:

```sh
./zig-out/bin/zi --provider openai --model gpt-5.6-sol
```

Press Enter to submit. While a turn is running, new submissions queue as
follow-ups. Cursor movement, deletion, and wrapping treat Unicode grapheme
clusters as single characters. Press Escape to cancel the active turn, Ctrl-C
on an empty prompt to exit, or Ctrl-D on an empty idle prompt to exit. User
messages use a compact rail. Assistant prose and thinking render as separate
Markdown blocks in model response order. Settled lines appear progressively as
the response streams, and the visible transcript reflows after a resize. The UI
uses a compact inline region in the normal terminal buffer. It preserves shell
rows above that region, grows through native scrollback, and leaves the
transcript visible when Zi exits. Running tools appear in the footer with a
bounded action and target, such as `Reading src/main.zig`. Consecutive completed
tools form one compact group without dumping tool output.

When no authenticated model is available, interactive mode still opens a durable
session. Drafts remain intact until a model is available. Use
`/login PROVIDER [--device]` to log in without leaving the TUI. Use
`/model PROVIDER/MODEL` while idle to switch the same durable session and save
the selected model as the global default.

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

For persistent customization, Zi loads `$HOME/.zi/agent/SYSTEM.md` as the composed prompt base and `$HOME/.zi/agent/APPEND_SYSTEM.md` as appended rules. Save project trust with `zi trust allow [PATH]`, deny it with `zi trust deny [PATH]`, inspect the effective decision with `zi trust status [PATH]`, or delete the exact decision with `zi trust remove [PATH]`. The nearest saved directory or ancestor decision applies. With no saved decision, automatic trust remains closed.

Trusted `$CWD/.zi/SYSTEM.md` and `$CWD/.zi/APPEND_SYSTEM.md` files shadow their global counterparts. Pass `--approve` or `-a` to trust them for one launch, or `--no-approve` or `-na` to ignore them. Launch overrides are never persisted. Resumed sessions resolve saved trust and project files from their stored working directory. Zi manages saved decisions in the private `$HOME/.zi/agent/trust.json` store.

Explicit `--rules` takes precedence over project and global `APPEND_SYSTEM.md` files while retaining the highest-precedence `SYSTEM.md` base. Prompt files must be regular UTF-8 text without NUL bytes and may not exceed 1 MiB each.

Log in to an OAuth-backed provider with `./zig-out/bin/zi auth login openai-codex`. Add `--device` for the device-code ceremony. Zi prints provider-supplied browser or device instructions and stores a successful credential in `$HOME/.zi/agent/auth.json`.

Zi also loads one context file from the global agent directory and from each ancestor of the effective working directory. `AGENTS.md` takes precedence over `CLAUDE.md` in each directory, and files are applied from global and broadest scope to the working directory. Context files must be regular UTF-8 text without NUL bytes. Each file is limited to 64 KiB, with a 128 KiB aggregate limit. An explicit system-prompt replacement is verbatim and bypasses prompt and context file discovery.

Run `./zig-out/bin/zi --help` for the current command surface. JSON and RPC modes are not available yet.
