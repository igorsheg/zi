---
slug: skills
title: Stop repeating instructions
order: 16
aliases:
  - skill
  - SKILL.md
---

# Stop repeating instructions

If you keep telling Zi the same thing, make it a skill.

A skill is a Markdown file Zi can discover, describe to the model, and load only when it is relevant.

Use skills for repeatable workflows:

- committing safely
- debugging flaky tests
- doing a strict review
- following a house style
- using a project-specific release process

## Skill or AGENTS.md?

Use `AGENTS.md` when the rule always applies.

Use a skill when the rule applies to one kind of task.

```text
Always run zig fmt before claiming done.      -> AGENTS.md
When asked to commit, stage files explicitly. -> skill
```

That split keeps the default prompt small while making specialized behavior available.

## Where skills live

```text
~/.zi/agent/skills/
<project>/.zi/skills/
```

Global skills are your personal toolkit. Project skills travel with the repo.

## The smallest useful skill

```text
.zi/skills/git/SKILL.md
```

```markdown
---
name: git
description: Use when the user asks to stage, commit, push, or inspect git state.
---
# git

Always run `git status` first.
Stage files explicitly. Never use `git add -A`.
Use conventional commits.
```

The description matters. It is the router. If the description is vague, the model will not know when to load it.

## How Zi uses skills

Zi does not paste every skill into every prompt.

It gives the model a list of skill names, descriptions, and file paths. When the task matches, the model reads the skill file.

That means you can have a useful skill library without turning every prompt into a handbook.

## Make skills sharp

A good skill has:

- a clear trigger
- a short process
- commands the agent can run
- rules that are easy to verify
- examples of bad and good behavior when useful

Avoid writing a philosophy essay. Write the thing you wish you did not have to repeat.

## Bounds

Zi loads at most 128 skills. Each skill file is capped at 256 KiB.

If you hit those limits, the problem is probably not Zi. It is that your skills have become docs.
