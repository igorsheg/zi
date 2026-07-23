---
slug: cli
title: Choose a run mode
order: 10
---

# Choose a run mode

The first question is not which flag to use. It is who Zi is talking to.

- You, in a terminal? Use interactive mode.
- A shell script? Use text mode.
- A log parser? Use JSON mode.

## Interactive

```sh
zi
zi "fix the failing build"
```

Interactive mode is the default when stdin and stdout are terminals. It opens the TUI, streams assistant text and tool calls, keeps the prompt focused, and lets you run slash commands such as `/login`, `/model`, `/settings`, `/compact`, `/new`, and `/resume`.

## Text

```sh
zi -p "write a commit message for the staged diff"
zi --mode text "summarize this file"
printf 'Summarize stdin' | zi
```

Text mode runs prompts in order and prints the final assistant text. Piped stdin becomes the first prompt and positional arguments follow.

Use text mode for shell workflows where progress events would be noise.

## JSON

```sh
zi --mode json "inspect this repo"
```

JSON mode emits UTF-8 JSONL. The first line is a session header; later lines are source-ordered session events. Human diagnostics use stderr, so stdout remains parseable.

Use JSON mode when another program wants progress, tool calls, retry, compaction, and settlement records.

## Continue work

```sh
zi --continue
```

Continue the newest saved session for the current cwd.

```sh
zi --resume path/to/session.jsonl
```

Strictly resume an existing journal file. In the TUI, `/resume` opens the bounded current-project session picker.

```sh
zi --no-session "one disposable prompt"
```

Run without writing a persistent session.

## Model overrides

```sh
zi --model provider/model-id --api-key "$KEY" "try this once"
```

`--api-key` is memory-only. It authenticates the selected provider for this process and is never written to `auth.json`.

## Reference

```text
zi [options] [prompt ...]

-p, --print                 Print the final response and exit
    --mode text             Print the final response and exit
    --mode json             Emit header-first JSONL session events
    --cwd path              Set the effective working directory
    --model provider/model  Select a model
    --api-key key           Use a memory-only provider API key
-r, --resume file           Resume a session file
-c, --continue              Continue the most recent session
    --no-session            Do not persist the session
-h, --help                  Show help
-V, --version               Show the Zi version
```

RPC mode is not available yet.
