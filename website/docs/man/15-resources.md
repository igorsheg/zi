---
slug: resources
title: Resource discovery
order: 15
aliases:
  - resources
  - resource roots
  - discovery
  - config
  - configuration
  - runtime roots
  - user config
  - project config
---

# Resource discovery

zi loads user and project resources from small directories on disk.

Use resource locations when you want zi to learn local habits: extensions, Lua modules, prompts, skills, themes, and agent context files.

## Default locations

User resources live under the agent directory:

```text
~/.zi/agent/
```

Set `ZI_CODING_AGENT_DIR` to move that directory for a run or environment.

Project resources live under the current project:

```text
<project>/.zi/
```

Settings files use the same scopes:

```text
~/.zi/agent/settings.json
<project>/.zi/settings.json
```

## Default layout

The user and project locations use this layout:

```text
<root>/
├─ extensions/
├─ lua/
├─ prompts/
├─ skills/
├─ themes/
└─ settings.json
```

`extensions/`
: Lua extension entrypoints. See [Extensions](extensions.html).

`lua/`
: Shared Lua modules that extensions can `require`.

`prompts/`
: Prompt templates and slash-command prompt files.

`skills/`
: Skill directories.

`themes/`
: Theme JSON files.

A root does not need every directory. Create only the directories you use.

Agent context files are loaded differently: zi reads `AGENTS.md` or `CLAUDE.md` from the user agent directory and from the current project path and its ancestors.

## Common installs

User-wide extension:

```text
~/.zi/agent/extensions/notify.lua
```

Project extension:

```text
<project>/.zi/extensions/project-tools.lua
```

User-wide theme:

```text
~/.zi/agent/themes/my-theme.json
```

Project skill:

```text
<project>/.zi/skills/debugging/SKILL.md
```

Project prompt:

```text
<project>/.zi/prompts/release.md
```

User-wide agent context:

```text
~/.zi/agent/AGENTS.md
```

Project agent context:

```text
<project>/AGENTS.md
<project>/CLAUDE.md
```

## Settings paths

`settings.json` can add extra resource locations.

```json
{
  "extensions": ["../zi-extensions"],
  "skills": ["../zi-skills"],
  "prompts": ["../zi-prompts"],
  "themes": ["../zi-themes"],
  "packages": ["../zi-extension-package"]
}
```

Relative paths are resolved from the current project for direct path settings. Package paths are resolved from the settings scope that declares them: user packages from `~/.zi/agent/`, project packages from `<project>/.zi/`.

A package is another extension resource root. Use one when you want to share a bundle containing one or more extensions and their private or shared Lua modules.

Extension packages may also be filtered:

```json
{
  "packages": [
    {
      "source": "../team-zi",
      "extensions": ["code-review"]
    }
  ]
}
```

The settings schema accepts future package filters for other resource kinds, but the current loader applies packages to extension discovery.

## Precedence

Resource precedence is intentionally simple, but each resource kind owns its collision rules.

Extension roots are ordered by source:

```text
explicit > user > project > builtin
```

Within one root, discovery is lexical. Most duplicate extension registrations are first claimant wins. Slash commands keep duplicate names callable through resolved names.

Prompts, skills, and themes also load from user and project locations, plus direct paths from settings. Agent context files load from `AGENTS.md` or `CLAUDE.md` in the user agent directory and project ancestors. Resource-specific pages should document file formats and naming rules; this page documents where the files come from.

## Dynamic discovery

The extension API names a `resources_discover` aggregate event for resource folders. Current startup discovery is static: user/project locations, settings paths, extension packages, and extension `after/` roots.

Prefer those static locations today. When dynamic discovery is wired into a workflow, keep it boring:

- return folders, not policy
- use stable absolute or project-relative paths
- document visible effects in the extension or package README

The event name is listed in [API](api.html#events).
