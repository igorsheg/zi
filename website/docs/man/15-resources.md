---
slug: resources
title: Know where Zi stores things
order: 15
aliases:
  - paths
  - resource discovery
  - agent dir
  - project config
---

# Know where Zi stores things

Zi has two places to look for files.

```text
global:  ~/.zi/agent/
project: <repo>/.zi/
```

Global files are yours. Project files belong to the repo.

## Global files

```text
~/.zi/agent/
├─ auth.json
├─ settings.json
├─ sessions/
├─ skills/
├─ SYSTEM.md
└─ APPEND_SYSTEM.md
```

Use this for personal defaults, credentials, sessions, and skills you want everywhere.

Move it for one run with:

```sh
ZI_CODING_AGENT_DIR=/tmp/zi-agent zi
```

## Project files

```text
<repo>/.zi/
├─ settings.json
├─ skills/
├─ SYSTEM.md
└─ APPEND_SYSTEM.md
```

Use this for behavior that should travel with the codebase.

A good rule of thumb:

```text
Only you need it?          ~/.zi/agent/
Everyone on the repo does? <repo>/.zi/
```

## Sessions

Zi stores session history under the global agent directory:

```text
~/.zi/agent/sessions/
```

Sessions are grouped by cwd and stored as JSONL. This is what makes `--continue`, `--resume`, and `--session` work.

The session file is the durable record. The TUI is just one way to view and steer it.

## Context files live outside .zi

Zi also reads:

```text
AGENTS.md
CLAUDE.md
```

Those files usually live at the repo root, not under `.zi/`.

Use them for instructions a future agent should see immediately when it enters the repo.

## When to use which file

`settings.json`
: Provider, model, compaction, and retry defaults.

`skills/`
: Task-specific workflows the model can load on demand.

`SYSTEM.md`
: Replace Zi's system prompt.

`APPEND_SYSTEM.md`
: Add instructions to Zi's system prompt.

`AGENTS.md`
: Explain how this repo works.

`auth.json`
: Stored auth. Zi writes this; you usually should not.
