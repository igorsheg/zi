---
slug: resources
title: Know where Zi stores things
order: 15
---

# Know where Zi stores things

Zi has one global agent directory and one project directory for the effective cwd.

```text
global:  $HOME/.zi/agent/
project: <cwd>/.zi/
```

`ZiPaths` owns these paths. Runtime services consume that value instead of joining `.zi` or rereading the process cwd themselves.

## Global files

```text
$HOME/.zi/agent/
├─ auth.json
├─ settings.json
├─ sessions/
├─ skills/
├─ prompts/
├─ AGENTS.md
├─ SYSTEM.md
└─ APPEND_SYSTEM.md
```

Use this for personal defaults, credentials, sessions, skills, prompts, and instructions you want everywhere.

## Project files

```text
<cwd>/.zi/
├─ settings.json
├─ skills/
├─ prompts/
├─ SYSTEM.md
└─ APPEND_SYSTEM.md
```

Use this for behavior that should travel with the repo.

A useful rule:

```text
Only you need it?          $HOME/.zi/agent/
Everyone on the repo does? <cwd>/.zi/
```

## Sessions

Zi stores durable sessions under:

```text
$HOME/.zi/agent/sessions/
```

Sessions are partitioned by canonical cwd. `--continue` chooses the newest saved session for the current cwd. `/resume` opens the bounded current-project session picker. A resumed session rebuilds settings, resources, credentials, and session storage from the cwd saved in the journal header.

## Context files

Zi also reads repo context from:

```text
AGENTS.md
CLAUDE.md
```

It checks from filesystem root to the effective cwd, plus global `AGENTS.md`. Use these files for instructions that should apply every time Zi works in that tree.

## Resource directories

`skills/`
: Markdown skills with names and descriptions. The model can read them when relevant.

`prompts/`
: Markdown prompt templates that become slash commands.

`SYSTEM.md`
: Replace Zi's default system prompt.

`APPEND_SYSTEM.md`
: Add instructions after Zi's default system prompt.

`auth.json`
: Stored provider credentials. Zi writes this; you usually should not.
