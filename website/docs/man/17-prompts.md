---
slug: prompts
title: Prompts
order: 17
aliases:
  - prompt
  - prompt templates
  - slash prompt
---

# Prompts

A prompt is a Markdown template loaded from disk and made available by name.

Use prompts for repeated asks: release notes, handoff notes, review checklists, issue summaries. If the behavior needs state, tools, or UI, write an extension instead.

## Locations

zi loads prompt files from:

```text
~/.zi/agent/prompts/
<project>/.zi/prompts/
```

Extra prompt paths may be listed in `settings.json`:

```json
{
  "prompts": ["../zi-prompts", "../one-off/release.md"]
}
```

A prompt path may be a directory or a single `.md` file. Directory loading is shallow: zi reads `.md` files directly inside that directory.

See [Resource discovery](resources.html) for path rules.

## Names

The prompt name is the Markdown filename without `.md`.

```text
prompts/
├─ release.md       # release
└─ handoff.md       # handoff
```

Names are the handle users and zi use to find the prompt. Rename carefully.

## Content

A prompt file is plain Markdown:

```md
Write release notes for this change.

Include:

- user-visible changes
- migration notes
- known risks

Keep it short. Link to evidence when possible.
```

Keep prompts specific. A prompt should ask for one thing and make the expected shape visible.

## Collisions

The first prompt with a name wins. Later prompts with the same name are skipped and reported as collisions.

Prefer project prompts for project language. Prefer user prompts for personal habits. If a prompt grows conditionals and side effects, it has become an extension wearing a hat.
