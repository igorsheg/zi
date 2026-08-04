---
slug: resources
title: Know where Zi stores things
order: 40
---

# Know where Zi stores things

Zi has one global agent directory and one project directory for the effective working directory:

```text
global:  $HOME/.zi/agent/
project: <cwd>/.zi/
```

For Agent Skills interoperability, Zi also discovers `$HOME/.agents/skills/` and trusted `.agents/skills/` directories from the working directory to the repository boundary.

Global configuration is personal. Project configuration travels with the repository and is admitted only after project trust is resolved.

## Global files

```text
$HOME/.zi/agent/
├─ auth.json
├─ settings.json
├─ trust.json
├─ sessions/
├─ extensions/
├─ prompts/
├─ skills/
├─ subagents/
├─ AGENTS.md
├─ SYSTEM.md
└─ APPEND_SYSTEM.md
```

Use this for credentials, personal defaults, sessions, and behavior you want everywhere.

## Project files

```text
<cwd>/.zi/
├─ settings.json
├─ extensions/
├─ prompts/
├─ skills/
├─ subagents/
├─ SYSTEM.md
└─ APPEND_SYSTEM.md
```

Use this for behavior that should travel with the repository.

```text
Only you need it?           $HOME/.zi/agent/
Everyone on the repository? <cwd>/.zi/
```

Interactive mode asks before loading protected project configuration, including ancestor `.agents/skills/`. Text, JSON, and RPC modes never prompt and exclude unresolved project configuration.

## Sessions

Zi stores durable sessions beneath:

```text
$HOME/.zi/agent/sessions/
```

Sessions are partitioned by canonical working directory. `--continue` chooses the newest saved session for the current directory. `/resume` opens the bounded current-project session picker. A resumed session rebuilds settings, resources, credentials, and storage from the working directory saved in its journal header.

## Context files

Zi reads repository context from:

```text
AGENTS.md
CLAUDE.md
```

It checks from the filesystem root to the effective working directory, plus global `$HOME/.zi/agent/AGENTS.md`. Use these files for instructions that should apply every time Zi works in that tree.

## Additional resource paths

Global and project settings can add extension, skill, and prompt files or directories through typed arrays. These sources are additive and retain their settings scope. See [Settings](settings.md#resource-paths).

## Resource directories

`extensions/`
: Trusted TypeScript modules that register commands, tools, lifecycle behavior, durable state, or subagent profiles. See [Extensions](extensions.md).

`prompts/`
: Markdown prompt templates that become slash commands. See [Prompts](prompts.md).

`skills/`
: Markdown workflows the model can load when relevant. See [Skills](skills.md).

`subagents/`
: Markdown profiles for reusable delegated roles. See [Subagents](subagents.md).

`SYSTEM.md`
: Replace Zi's default system prompt.

`APPEND_SYSTEM.md`
: Add instructions after Zi's default system prompt.

`auth.json`
: Stored provider credentials. Zi writes this; you usually should not.

`trust.json`
: Saved project-configuration decisions keyed by canonical working directory. Zi writes this; you usually should not.
