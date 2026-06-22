---
slug: prompts
title: Change the system prompt
order: 17
aliases:
  - SYSTEM.md
  - APPEND_SYSTEM.md
  - system prompt
---

# Change the system prompt

Most of the time, you should not replace Zi's system prompt.

Zi's default prompt wires in the tools, repo context, skills, date, and cwd. If you replace it, you own all of that.

So start with append.

## Add instructions

Create:

```text
~/.zi/agent/APPEND_SYSTEM.md
<repo>/.zi/APPEND_SYSTEM.md
```

Example:

```markdown
# Extra rules

- Prefer small patches.
- Ask before adding a dependency.
- If a command fails, show the exact command and failure.
```

Use this when Zi's default prompt is right, but you need a few more rules.

## Replace everything

Create:

```text
~/.zi/agent/SYSTEM.md
<repo>/.zi/SYSTEM.md
```

This replaces the default prompt.

Use it only when you want full control over the model's instructions. A custom `SYSTEM.md` should still explain the available tools and how you expect the agent to use them.

## Project beats global

For both files, project scope wins over global scope.

```text
<repo>/.zi/APPEND_SYSTEM.md
```

beats:

```text
~/.zi/agent/APPEND_SYSTEM.md
```

That lets a repo set stricter behavior without changing your global setup.

## Prompt or context?

Use `AGENTS.md` for repo knowledge:

```text
Run `zig build test` before claiming done.
```

Use `APPEND_SYSTEM.md` for assistant behavior:

```text
When a validation command fails, summarize the failure before proposing a fix.
```

If you are unsure, choose `AGENTS.md`. It is easier for future maintainers to find.

## Keep it short

A system prompt is not a wiki.

If a rule only matters for one workflow, make it a [skill](skills.html). If a rule always matters for the repo, put it in `AGENTS.md`. Use prompt files for behavior that truly belongs at the system level.
