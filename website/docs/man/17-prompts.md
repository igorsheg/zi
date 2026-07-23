---
slug: prompts
title: Add prompts and system instructions
order: 17
---

# Add prompts and system instructions

There are two prompt customizations:

- prompt templates for repeatable slash commands
- system prompt files for changing the assistant's base instructions

Start with prompt templates or `APPEND_SYSTEM.md`. Replace the full system prompt only when you want to own everything.

## Prompt templates

Create Markdown files in:

```text
$HOME/.zi/agent/prompts/
<cwd>/.zi/prompts/
```

A file named `review.md` creates `/review`.

```markdown
---
description: Review a diff for correctness and risk.
argument-hint: [path]
---

Review $ARGUMENTS.
Focus on correctness, tests, and unintended behavior changes.
```

Arguments preserve Pi-compatible quoting. These forms are available:

`$ARGUMENTS`
: All arguments as one string.

`$@`
: Alias for all arguments.

`$1`, `$2`
: Positional arguments.

`${1:-default}`
: Positional argument with a default.

`${@:2}`
: Arguments from position 2 onward.

`${@:2:3}`
: Three arguments starting at position 2.

Prompt expansion is single-pass. If no template matches, Zi leaves the slash command text alone.

## Append to the system prompt

Create:

```text
$HOME/.zi/agent/APPEND_SYSTEM.md
<cwd>/.zi/APPEND_SYSTEM.md
```

Example:

```markdown
# Extra rules

- Prefer small patches.
- Ask before adding a dependency.
- If a command fails, show the exact command and failure.
```

Use this when Zi's default prompt is right but you need a few more rules.

## Replace the system prompt

Create:

```text
$HOME/.zi/agent/SYSTEM.md
<cwd>/.zi/SYSTEM.md
```

This replaces the default prompt.

Use it only when you want full control. A custom `SYSTEM.md` should still explain the available tools and how you expect the agent to use them.

## Project beats global

Project resources win over global resources with the same name. That lets a repo set stricter behavior without changing your global setup.

If a rule always matters for the repo, prefer `AGENTS.md`. If it only matters for one workflow, prefer a skill or prompt template.
