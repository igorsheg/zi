---
slug: agent-context
title: Teach Zi your repo
order: 19
aliases:
  - AGENTS.md
  - CLAUDE.md
  - project context
---

# Teach Zi your repo

Agents waste time when they have to rediscover the same rules every session.

Put the rules in the repo.

Zi reads:

```text
AGENTS.md
CLAUDE.md
```

Use them for instructions that should be true every time Zi works in this codebase.

## What belongs here

Good context answers questions the agent would otherwise guess:

- How do I build this?
- How do I test it?
- Which files are generated?
- Which directories own which behavior?
- What should never import what?
- What does "done" mean?

Example:

~~~markdown
# Agent rules

Before claiming a code change is done, run:

```sh
zig build test
zig build
zig fmt --check src
```

Do not edit `src/ai/models.generated.zig` by hand. Run `zig build generate-models`.
~~~

## What does not belong here

Avoid vague taste:

```text
Write clean code.
```

Prefer operational rules:

```text
Keep path policy in `src/coding_agent/paths.zig`. Do not hardcode `.zi` elsewhere.
```

The second one changes behavior. The first one mostly spends tokens.

## Global and project context

Use global context for your personal defaults:

```text
~/.zi/agent/AGENTS.md
```

Use project context for repo-specific rules:

```text
<repo>/AGENTS.md
```

Zi also checks parent directories. In a monorepo, a root `AGENTS.md` can set broad rules and a nested one can add local rules.

## A good first AGENTS.md

Start small:

```markdown
# Agent rules

## Build

Run `zig build test` before claiming done.

## Style

Prefer small changes. Do not add dependencies without asking.

## Generated files

Do not edit generated files by hand.
```

Then add rules only when you catch yourself repeating them.
