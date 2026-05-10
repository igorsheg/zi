---
slug: intro
title: Zi
order: 0
aliases:
  - overview
  - start
  - getting started
  - about
---

# Zi

`zi` is a local coding agent harness.

It runs in your project, keeps a durable session log, and lets small Lua extensions teach it new habits.

Use it when you want agent work that you can inspect, resume, and change.

## Start

```sh
zi
zi "fix the failing build"
zi -p "write a commit message"
zi --mode json "inspect this project"
```

## What zi keeps

zi keeps sessions on disk as JSONL. The TUI, replay tools, compaction, and extensions all work from that record.

Disable this for a startup run with `--no-session`.

## What zi extends

Extensions can add:

- slash commands
- model-visible tools
- prompt/context hooks
- provider/model claims
- session notes and labels
- small UI surfaces
- delegated child zi runs

An extension is just Lua loaded from an extension root. No framework is required.

## Who this is for

These docs are for:

- people using zi
- people writing zi extensions
- zi itself, when asked to write an extension

When generating an extension, prefer the API documented here. Keep behavior small, named, and visible in the session.

Markdown pages live next to the HTML pages. If a link ends in `.html`, the matching `.md` page usually exists too.

## Pages

- [CLI](cli.html) — run modes, prompt inputs, sessions, flags
- [Settings](settings.html) — user/project configuration
- [Resource discovery](resources.html) — user/project roots, settings paths, packages
- [Extensions](extensions.html) — extension files, loading, lifecycle
- [API](api.html) — tools, commands, providers, events, jobs, JSON
- [Context](context.html) — `ctx.ui`, `ctx.editor`, `ctx.session`, `ctx.models`, `ctx.ai`
- [Guidance](guidance.html) — rules for useful extensions
