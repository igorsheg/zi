---
slug: cli
title: Choose a run mode
order: 10
aliases:
  - flags
  - options
  - print
  - json mode
  - rpc
---

# Choose a run mode

The first question is not "which flag do I need?"

It is: **who is Zi talking to?**

- You, in a terminal? Use interactive mode.
- A shell script? Use text mode.
- A log parser? Use JSON mode.
- A custom frontend? Use RPC mode.

## Interactive: when you are working with it

```sh
zi
zi "fix the failing build"
```

This opens the TUI. Use it when you want to watch the work happen, steer the session, switch models, resume sessions, or inspect tool calls.

No flag is needed when stdin is a TTY.

## Text: when you need one answer

```sh
zi -p "write a commit message for the staged diff"
zi --mode text "summarize this file"
```

Text mode runs one prompt and prints the final assistant text.

Use it for shell workflows where progress events would be noise.

## JSON: when progress matters

```sh
zi --mode json "inspect this repo"
```

JSON mode emits public events as lines. Use it when another program wants to see starts, updates, tool calls, finishes, and errors.

It is not terminal output with braces. It is the public event stream.

## RPC: when you are building a frontend

```sh
zi --mode rpc
```

RPC mode exposes Zi's typed stdio protocol.

Use this when you want to build an integration that submits commands, drains events, and owns its own UI.

## Continue work

Most useful agent work spans more than one prompt. Zi gives you three ways back in.

```sh
zi --continue
```

Continue the newest saved session for this cwd.

```sh
zi --resume
```

Open the session picker.

```sh
zi --session <path-or-id-prefix>
```

Resume a specific session.

Zi rejects conflicting resume flags. If you ask for two different sessions at once, it makes you choose.

## Authenticate Codex

```sh
zi auth login openai-codex
zi auth status openai-codex
zi auth logout openai-codex
```

Use these if you want Zi to use OpenAI Codex OAuth credentials instead of an environment-provided key.

## TUI slash commands

Inside the interactive session:

`/help`
: Show commands.

`/session`
: Show session info.

`/model`
: Select a model.

`/resume`
: Resume another session.

`/compact`
: Compact the session context.

## Reference

```text
zi [options] [prompt]

-p, --print              Run text mode and exit
--mode <text|json|rpc>   Select output mode
-r, --resume             Select a session to resume
--session <session>      Use a session file or id prefix
-c, --continue           Continue the newest session for this cwd
--version                Show zi version
-h, --help               Show help
```
