---
slug: intro
title: Start here
order: 0
---

# Start here

You ask an agent for a change. It edits six files, runs something, and reports success. Now you are reading a diff, trying to reconstruct what it actually did — and deciding how much of the part you did not watch you are willing to trust.

Zi is a coding agent built the other way around. It runs in your repository, shows every tool call as it happens, writes the session to disk, and puts a hard limit on everything it retains. Work in Zi stays visible, bounded, and resumable.

Not unconditionally. A `--no-session` run is ephemeral by design and resumes nothing. Subagent children are never persisted; only their evidence reaches the parent journal. Where Zi cannot keep that promise, the guide for that feature says so.

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
- `/copy` copies the latest committed assistant message to the clipboard as its Markdown source, excluding thinking and tool calls. An in-progress streaming message is not included.

## Choose your level

Most of what people want from a coding agent is a customization, not a code change. Zi has one for every level, and the cheapest one that works is the right one:

```text
A rule that always applies?           AGENTS.md
Instructions for one kind of task?    a skill
A command you invoke by name?         a prompt template
The same flags on every run?          settings
Behavior Zi must execute?             an extension
Another application driving Zi?       RPC
A different interaction model?        your own client
```

Work down that list rather than up. Each rung costs more to maintain than the one above it, and a surprising amount of what people reach for an extension to do is a skill that nobody wrote down.

## The manual

Start with [Know the vocabulary](vocabulary.md) if the later pages read as jargon; ten words carry most of this manual.

### Run it

- [Choose a run mode](cli.md) — interactive, text, JSON, or RPC, plus how one invocation resolves.
- [Authenticate and choose a model](authentication.md) — providers, credentials, and model selection.
- [Set defaults](settings.md) — persist models, queues, retry, compaction, and resource paths.
- [Know where Zi stores things](resources.md) — the global and project directories, and project trust.

### Teach it

- [Add prompts and system instructions](prompts.md) — slash commands and base-prompt policy.
- [Stop repeating instructions](skills.md) — reusable workflows the model loads when they apply.

### Watch it work

- [Work plans](work-plans.md) — the ordered checklist Zi keeps for non-trivial work.
- [Code Mode](code-mode.md) — the `code` tool, its authority, and its memory.

### Build on it

- [Extensions](extensions.md) — trusted TypeScript that adds commands, tools, state, and profiles.
- [Delegate with subagents](subagents.md) — reusable delegated roles and their orchestration tools.
- [JSON event stream](json-events.md) — consume one finite run as JSONL.
- [RPC protocol](rpc.md) — drive and observe a long-lived Zi process.
- [Terminal notifications](notifications.md) — the reference client's own notification surface.

Read the tier you need. Every page assumes you arrived from a real problem, states what Zi does about it, and then tells you where the mechanism stops — because work you cannot see, bound, or resume is work you cannot trust.
