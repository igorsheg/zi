---
slug: frontend
title: Frontends
order: 18
aliases:
  - tui
  - text mode
  - json mode
  - rpc mode
---

# Frontends

Zi has one session core and several ways to look at it.

That split matters. The TUI is not the session. JSON mode is not a different agent. RPC is not a second policy engine.

They are frontends over the same command/event/snapshot boundary.

## TUI

```sh
zi
```

The TUI is the default on a terminal. It is built on vendored libvaxis and owns terminal product state.

The TUI can show streamed assistant text, tool calls, status, session changes, and slash-command results. It does not import the coding-agent core directly; the concrete adapter lives outside `src/tui`.

## Text

```sh
zi -p "summarize this diff"
```

Text mode is for shell scripts and quick one-shot prompts. It prints final assistant text.

Use this when the answer is the artifact.

## JSON

```sh
zi --mode json "inspect this repo"
```

JSON mode emits public events as lines.

Use this when another tool wants progress, not just the final text.

## RPC

```sh
zi --mode rpc
```

RPC mode is for concrete frontends. It uses the typed client protocol over stdio.

Use this when you want to build a real integration instead of scraping terminal output.

