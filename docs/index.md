---
slug: intro
title: Start here
order: 0
---

# Start here

Zi is a coding agent you can build with.

It runs in your repository, keeps the work visible, and gives the model a small set of tools for reading, editing, writing, and running commands. Start with a concrete task, watch the tool calls, then resume the session when the work continues.

## Install

```sh
npm install -g @with-zi/zi
zi --version
```

The npm package installs the native executable for your platform. There is no install-time downloader.

## First run

Open Zi in a project:

```sh
zi
```

A fresh terminal can start without credentials. Use `/login`, then `/model` if Zi asks you to choose an authenticated model.

Ask for something concrete:

```text
explain how tests are organized in this repo
```

Zi works best when you ask for a small, inspectable piece of real work and let the session build context over time.

## The core loop

1. Start Zi in the repository.
2. Ask for a small task.
3. Watch the tool calls and transcript.
4. Steer or interrupt when needed.
5. Resume the session later.
6. Move repeated instructions into `AGENTS.md`, a prompt, or a skill.

That last step is the important one. Zi gets better when you stop retyping instructions and start teaching the repository.

## Interactive controls

- `Enter` sends a prompt. During an active turn it queues steering input; `Alt+Enter` queues a follow-up.
- `Ctrl+Enter` interrupts only the active parent turn and sends the current draft immediately. Existing queues, background commands, and subagents continue.
- `Esc` cancels the active parent turn and restores queued input to the composer.
- `Ctrl+C` clears a non-empty draft. Zi shows `Ctrl+Z` recovery guidance, and undo restores text and image markers together.

## What to read next

- [CLI](cli.md) — choose interactive, text, JSON, or RPC mode.
- [Authentication](authentication.md) — configure providers and models.
- [Settings](settings.md) — set defaults for models, queues, retry, and compaction.
- [Resources](resources.md) — see where Zi stores state and discovers configuration.
- [Prompts](prompts.md) — add reusable slash prompts or system instructions.
- [Skills](skills.md) — teach Zi reusable workflows.
- [Extensions](extensions.md) — add trusted commands, tools, state, and orchestration.
- [Code Mode](code-mode.md) — understand generated JavaScript, persistent memory, and local authority.
- [Work plans](work-plans.md) — track bounded session work from planning through verification.
- [Subagents](subagents.md) — define reusable delegated roles.
- [Operation outcomes](operation-outcomes.md) — consume canonical durable terminal operation records.
- [JSON events](json-events.md) — consume a finite run as JSONL.
- [RPC](rpc.md) — control a long-lived Zi process.
- [Notifications](notifications.md) — use the terminal client's notification API.
