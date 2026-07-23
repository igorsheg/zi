---
slug: skills
title: Stop repeating instructions
order: 16
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
Always run bun run check before claiming done. -> AGENTS.md
When asked to commit, stage files explicitly.  -> skill
```

That split keeps the default prompt small while making specialized behavior available.

## Where skills live

```text
$HOME/.zi/agent/skills/
<cwd>/.zi/skills/
```

Project skills shadow global skills with the same name.

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

The description is the router. If it is vague, the model will not know when to load the skill.

## How Zi uses skills

Zi does not paste every skill into every prompt.

It gives the model a list of skill names, descriptions, and file paths. When the task matches, the model can read the skill file.

That means you can have a useful skill library without turning every prompt into a handbook.

## Keep skills sharp

A good skill has:

- a clear trigger
- a short process
- commands the agent can run
- rules that are easy to verify
- examples of bad and good behavior when useful

Avoid writing a philosophy essay. Write the thing you wish you did not have to repeat.
