---
slug: skills
title: Stop repeating instructions
order: 60
---

# Stop repeating instructions

If you keep telling Zi the same thing, make it a skill.

A skill is a Markdown resource Zi can discover, describe to the model, and load only when its instructions are relevant. Use skills for repeatable workflows such as committing safely, debugging flaky tests, strict reviews, house style, or a project release process.

## Skill or AGENTS.md?

Use `AGENTS.md` when a rule always applies. Use a skill when it applies to one kind of task.

```text
Always run bun run check before claiming done. -> AGENTS.md
When asked to commit, stage files explicitly.  -> skill
```

That split keeps the base prompt small while making specialized behavior available.

## Locations and precedence

Global skills load from:

```text
$HOME/.zi/agent/skills/
```

Trusted project skills load from:

```text
<cwd>/.zi/skills/
```

Project skills precede global skills with the same name. Zi visits bounded resource trees, ignores hidden directories and `node_modules`, and honors resource ignore files. Run `/reload` after adding or changing a skill in an active interactive session.

A skill may be a root Markdown file such as `skills/review.md`, but a directory with `SKILL.md` is preferred when the skill includes supporting references, scripts, or examples:

```text
.zi/skills/review/
├─ SKILL.md
└─ checklist.md
```

Relative paths in skill instructions resolve from the directory containing `SKILL.md`.

## The smallest useful skill

```markdown
---
name: review
description: Review a change for correctness, regressions, and missing tests.
---

# Review

Inspect the diff and relevant tests. Report findings in severity order with exact file paths.
```

`description` is required and is the model-facing router. Make it state clearly when the skill applies. `name` is optional for a directory skill because it defaults to the directory containing `SKILL.md`. Set `name` explicitly in a root file such as `skills/review.md`.

Names use lowercase letters, numbers, and single hyphens. They cannot begin or end with a hyphen.

Set `disable-model-invocation: true` in frontmatter to hide a skill from the model-facing catalog while retaining explicit `/skill:<name>` invocation.

## How Zi uses skills

Zi gives the model a catalog containing each visible skill's name, description, and absolute file path. When a task matches, the model reads the complete skill file. Skill bodies do not occupy every prompt by default.

A user may invoke a skill explicitly:

```text
/skill:review review the current changes
```

Zi expands the skill body and appends the remaining arguments. Unknown skill commands pass through unchanged.

## Keep skills sharp

A useful skill has:

- a precise trigger in its description;
- a short, direct process;
- commands or tools the agent can use;
- rules with observable completion criteria;
- supporting files only when they make the workflow easier to follow.

Avoid a philosophy essay. Write the behavior you wish you did not have to repeat.

Start from [`examples/skills/review/SKILL.md`](../examples/skills/review/SKILL.md). Keep permanent repository policy in `AGENTS.md`, executable specialized behavior in an [extension](extensions.md), and static delegated roles in [subagent profiles](subagents.md).
