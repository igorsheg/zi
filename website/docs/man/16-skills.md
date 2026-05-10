---
slug: skills
title: Skills
order: 16
aliases:
  - skill
  - SKILL.md
  - skill commands
---

# Skills

A skill is a Markdown file that teaches zi when and how to do one kind of work.

Use a skill for reusable craft: debugging a Zig failure, shipping a change, reviewing a diff, using a house style. Keep it narrower than a handbook and clearer than a vibe.

## Locations

zi loads skills from:

```text
~/.zi/agent/skills/
<project>/.zi/skills/
```

Extra paths may be listed in `settings.json`:

```json
{
  "skills": ["../zi-skills"]
}
```

See [Resource discovery](resources.html) for path rules.

## File shapes

The usual shape is a directory with `SKILL.md`:

```text
skills/
└─ git/
   └─ SKILL.md
```

zi also accepts root-level Markdown files in a skill path:

```text
skills/
└─ commit-message.md
```

Discovery is recursive. Dot directories and `node_modules` are skipped. If a directory contains `SKILL.md`, that file represents the directory and zi does not keep looking below it.

## Frontmatter

```md
---
name: git
description: Stage explicit files, commit with a conventional message, and never force-push.
disable-model-invocation: false
---
# git

Use this when the user asks to commit, stage, push, split hunks, or manage worktrees.
```

`description`
: Required. Empty descriptions are ignored.

`name`
: Optional. Defaults to the parent directory name. If set, it should match the parent directory.

`disable-model-invocation`
: Optional boolean. Use `true` to keep the skill from being invoked by the model.

Skill names must be lowercase letters, digits, and single dashes. They cannot start or end with a dash. Keep them under 64 characters.

Descriptions should be short enough to scan. The loader warns above 1024 characters. That is already too long for a tired maintainer.

## Body

The body is instructions for zi and future agents. Write it like an operator note:

- what triggers the skill
- what to read first
- what commands are safe
- what commands are forbidden
- what output or artifact to produce

Prefer checklists and examples. Avoid hidden policy. If the skill needs code, make an extension.

## Collisions

The first loaded skill with a name wins. Later skills with the same name are skipped and reported as collisions.

Use distinct names. Boring names are good names.
