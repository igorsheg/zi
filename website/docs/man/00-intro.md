---
slug: intro
title: Start here
order: 0
---

# Start here

Zi is a coding agent you can build with.

It runs in your repo, keeps the work visible, and gives the model a small set of tools: read, bash, edit, and write. Start with a prompt, watch the tool calls, then resume the thread later when the work continues.

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

1. Start Zi in the repo.
2. Ask for a small task.
3. Watch the tool calls and transcript.
4. Steer or interrupt when needed.
5. Resume the session later.
6. Move repeated instructions into `AGENTS.md` or a skill.

That last step is the important one. Zi gets better when you stop retyping instructions and start teaching the repo.

## What to read next

- [CLI](cli.html) — choose interactive, text, or JSON mode
- [Authentication](authentication.html) — configure providers and models
- [Settings](settings.html) — set defaults for model, thinking, queues, retry, and compaction
- [Resources](resources.html) — see where Zi stores state and discovers instructions
- [Skills](skills.html) — teach Zi reusable workflows
- [Prompts](prompts.html) — add reusable slash prompts or system prompt overrides
- [JSON events](json-events.html) — consume Zi from another program
