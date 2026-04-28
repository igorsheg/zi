## cli model

zi chooses a run plan from explicit arguments. For extension authoring, see [extension purpose](extensions.html#extension-purpose); for API details, see [extension api: zi table](api.html#extension-api-zi-table).

Interactive mode is the default when no batch selector is present. Batch mode is explicit: use `-p`, `--print`, or `--mode`. Piped stdin alone does not force batch mode.

Session selectors (`--continue`, `--resume`, `--session`) are interactive-only. They cannot be combined with startup prompt inputs such as positional prompt text or `@file` arguments. Extension lifecycle/rebinding behavior is described in [extension lifecycle](extensions.html#extension-lifecycle).

## cli examples

`zi`
: Start interactive mode in the current project.

`zi "fix the failing build"`
: Start interactive mode with an initial prompt.

`zi @README.md "summarize this"`
: Start interactive mode with file content plus prompt text.

`zi -p "write a commit message"`
: Run batch text mode and print the final assistant text after completion.

`zi --mode text "write release notes"`
: Run explicit batch text mode.

`zi --mode json "inspect this project"`
: Run batch JSON mode. JSON output starts with a session header when persistence is enabled, then emits event lines.

`printf 'diff...' | zi -p @README.md "review this"`
: In explicit batch mode, merge stdin, `@file` content, and prompt text in that order.

`zi --continue`
: Resume the most recent session for this project.

`zi --resume`
: Open the interactive session picker.

`zi --session ./path/to/session.jsonl`
: Resume a specific session file.

`zi --list-models claude`
: List available models, optionally fuzzy-filtered by search text.

## cli options

`-p`, `--print`
: Select batch text mode. Prints the final assistant text only after completion.

`--mode <text|json>`
: Select explicit batch output mode. `text` emits final assistant text. `json` emits structured event lines.

`-c`, `--continue`
: Resume the most recent saved session for this project. Interactive-only.

`-r`, `--resume`
: Open the interactive session picker. Interactive-only.

`--session <path|id>`
: Resume a specific session by path or ID prefix. Interactive-only.

`--model <id>`
: Select a model by ID or pattern.

`--api-key <key>`
: Override provider API key for the run.

`--no-session`
: Disable session persistence for the startup session. In interactive mode, later `/resume` may enter a persisted session and `/new` starts a normal persisted session.

`--tools <filter>`
: Restrict the allowed tool set with a comma-separated filter.

`--append-system-prompt <text|path>`
: Append literal text or file contents to the system prompt.

`--list-models [search]`
: List available models. The optional positional value fuzzy-filters the model list.

`-h`, `--help`
: Show CLI help.

`-v`, `--version`
: Show the zi version.

## prompt inputs

Prompt input may come from:

- positional prompt text
- one or more `@file` arguments
- piped stdin, but only in explicit batch mode

Prompt assembly order in batch mode is:

```text
stdin + @file text + positional prompt
```

`@file` arguments are supported for interactive startup and explicit batch mode. Text files are inserted into the prompt. Image files are detected from file bytes; supported inline images attach to the model request and also contribute text references.

Empty or whitespace-only stdin is ignored. Empty `@file` inputs are skipped. Extensions that rewrite submitted input should use the [`input`](api.html#events) event; extensions that alter provider context should use [`context`](api.html#events) or [`before_provider_request`](api.html#events).
