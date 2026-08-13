---
slug: prompts
title: Add prompts and system instructions
order: 50
---

# Add prompts and system instructions

You keep pasting the same review instruction into the composer, or the same commit rules, at the start of every session. Put the instruction in a file once and invoke it by name.

Zi has two prompt customizations:

- prompt templates for repeatable slash commands;
- system prompt files for changing the assistant's base instructions.

Start with a prompt template or `APPEND_SYSTEM.md`. Replace the full system prompt only when you intend to own all base instructions.

## Prompt templates

Create Markdown files in:

```text
$HOME/.zi/agent/prompts/
<cwd>/.zi/prompts/
```

Additional files or directories can be listed in the [`prompts` settings array](settings.md#resource-paths). Project settings paths load first, and only when project configuration is [trusted](vocabulary.md). Global settings paths load before `$HOME/.zi/agent/prompts/`.

A file named `review.md` creates `/review`:

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

Expansion is single-pass. If no template matches, Zi leaves the slash command text unchanged.

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

This replaces the default prompt. A custom `SYSTEM.md` owns its product-documentation policy as well as its tool instructions, so use it only when you want complete control.

## Precedence

Project resources precede global resources with the same name. That lets a trusted repository set stricter behavior without changing your global setup.

Use `AGENTS.md` for rules that always matter, a [skill](skills.md) for instructions the model should load when relevant, and an [extension](extensions.md) for executable behavior.
