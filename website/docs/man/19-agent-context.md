---
slug: agent-context
title: Agent context
order: 19
aliases:
  - agents
  - AGENTS.md
  - CLAUDE.md
  - context files
  - project instructions
---

# Agent context

Agent context files are Markdown instructions loaded into zi's prompt input.

Use them for durable project facts: commands, invariants, local style, forbidden actions, and where evidence lives. Keep them true. Stale context is worse than no context; it fails with confidence.

## Files

zi looks for these names:

```text
AGENTS.md
CLAUDE.md
```

`AGENTS.md` wins when both exist in the same directory.

## User context

User-wide context lives in the agent directory:

```text
~/.zi/agent/AGENTS.md
~/.zi/agent/CLAUDE.md
```

Use this for personal operating rules that apply everywhere.

## Project context

Project context lives in the project tree, not under `<project>/.zi/`:

```text
<project>/AGENTS.md
<project>/CLAUDE.md
```

zi walks from the current working directory up through its ancestors and loads context files it finds. Parent instructions come before child instructions. More local files therefore get the last word.

Example:

```text
repo/
├─ AGENTS.md
└─ crates/
   └─ tui/
      └─ AGENTS.md
```

Starting zi in `repo/crates/tui` loads the repo context, then the `crates/tui` context.

## What belongs here

Good context:

- build and test commands
- project-specific terminology
- architectural constraints
- safety rules
- links to deeper docs
- short examples of house style

Bad context:

- long tutorials
- secrets
- wishful policy
- stale TODO lists
- instructions that only one tool understands

If the instruction is reusable craft, make a [Skill](skills.html). If it needs behavior, make an [Extension](extensions.html). If it is just a knob, make it [Settings](settings.html).

## Extra agent paths

Extensions may add extra agent-context directories through resource extension paths. zi reads `.md` files directly inside those directories.

For normal use, prefer `AGENTS.md` in the repo. It is visible to humans, grep, review, and blame. That is the point.
