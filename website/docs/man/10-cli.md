# CLI

Run `zi` in a project.

No selector means interactive mode. Batch mode is explicit: use `-p`, `--print`, or `--mode`.

A pipe does not switch zi into batch mode by itself. That keeps accidental shell pipes from changing the run shape.

## Common commands

`zi`
: Start interactive mode in the current project.

`zi "fix the failing build"`
: Start interactive mode with an initial prompt.

`zi @README.md "summarize this"`
: Start interactive mode with file content plus prompt text.

`zi -p "write a commit message"`
: Run batch text mode. Print the final assistant text.

`zi --mode json "inspect this project"`
: Run batch JSON mode. Emits a session header, then event lines, when persistence is enabled.

`printf 'diff...' | zi -p @README.md "review this"`
: In batch mode, combine stdin, `@file` content, and prompt text.

`zi --continue`
: Resume the most recent session for this project.

`zi --resume`
: Open the session picker.

`zi --session ./path/to/session.jsonl`
: Resume a specific session file.

`zi --list-models claude`
: List models, optionally filtered.

## Options

`-p`, `--print`
: Batch text mode. Prints final assistant text after the run.

`--mode <text|json>`
: Explicit batch mode. `text` prints final text. `json` emits event lines.

`-c`, `--continue`
: Resume the latest saved session for this project. Interactive-only.

`-r`, `--resume`
: Open the session picker. Interactive-only.

`--session <path|id>`
: Resume a session by path or ID prefix. Interactive-only.

`--model <id>`
: Select a model by ID or pattern.

`--api-key <key>`
: Override the provider API key for this run.

`--no-session`
: Start without persistence. In interactive mode, later `/resume` may enter a persisted session and `/new` starts a normal persisted session.

`--tools <filter>`
: Restrict the tool set with a comma-separated filter.

`--append-system-prompt <text|path>`
: Append literal text or file contents to the system prompt.

`--list-models [search]`
: List available models. The optional value filters the list.

`-h`, `--help`
: Show help.

`-v`, `--version`
: Show version.

## Prompt inputs

Prompt input may come from:

- positional prompt text
- one or more `@file` arguments
- piped stdin, in explicit batch mode

Batch assembly order:

```text
stdin + @file text + positional prompt
```

`@file` works for interactive startup and batch mode. Text files are inserted into the prompt. Supported image files attach to the model request and add text references.

Empty stdin is ignored. Empty `@file` inputs are skipped.

Session selectors (`--continue`, `--resume`, `--session`) are interactive-only and cannot be combined with startup prompt text or `@file` arguments.
